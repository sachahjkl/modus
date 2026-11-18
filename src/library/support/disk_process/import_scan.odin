package disk_process

// The import scan: how the root service finds an import of a disk process
// that the boot image does not hold, by the hash of the bytes of a file of
// the store `module_files` (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// This file keeps the account of a scan: the entries that the list gave,
// the hashes that the imports want, and which entry to read next. The root
// service does the calls of the storage service and computes each hash; it
// trusts no name and no hash that the storage service gives. No allocator
// and no kernel operation: the host tests run each rule
// (import_scan_test.odin).

// The most objects of the root tree that one scan notes. The line of a
// refusal says when the store has more.
SCAN_ENTRY_CAPACITY :: 64

// The most hashes that one scan wants: the modules of the store that one
// disk process imports, at each level together.
SCAN_WANTED_CAPACITY :: 8

// The most levels of imports: the imports of the process are level 1,
// their imports level 2.
SCAN_DEPTH_LIMIT :: 4

// The most reads of one scan: each entry one time, and two reads more for
// each wanted hash. A storage service that gives other bytes at each read
// cannot make the scan last past it.
SCAN_READ_LIMIT :: SCAN_ENTRY_CAPACITY + 2 * SCAN_WANTED_CAPACITY

// One object of the root tree that the list gave.
Scan_Entry :: struct {
	name:        [NAME_LIMIT]u8,
	name_length: int,
	hash:        [HASH_SIZE]u8, // The BLAKE3 hash of the bytes of its last read.
	read:        bool, // Its bytes came whole once, or it was skipped.
	skipped:     bool, // Its bytes did not come: no object any more, no byte, or more than FILE_BYTES_LIMIT.
	kept:        bool, // Its bytes are the file of a wanted hash.
}

// One hash that an import names and the boot image does not hold.
Scan_Wanted :: struct {
	hash:     [HASH_SIZE]u8,
	importer: int, // The entry of the module that imports it; -1: the disk process.
	level:    int,
	found:    bool,
	entry:    int, // The entry whose bytes have the hash, when found.
}

// The account of one scan. The zero value is a scan with nothing wanted.
Import_Scan :: struct {
	entries:          [SCAN_ENTRY_CAPACITY]Scan_Entry,
	entry_count:      int,
	entries_left_out: bool, // The list gave more objects than SCAN_ENTRY_CAPACITY.
	wanted:           [SCAN_WANTED_CAPACITY]Scan_Wanted,
	wanted_count:     int,
	bound_passed:     bool, // A hash was not noted: more than SCAN_WANTED_CAPACITY hashes, or a level past SCAN_DEPTH_LIMIT.
	reads:            int, // The reads that ended: whole, or skipped.
}

// What scan_want did with a hash.
Want_Answer :: enum u8 {
	Added, // The scan wants it now.
	Present, // The scan wanted it already.
	Full, // No place: SCAN_WANTED_CAPACITY hashes are wanted.
	Too_Deep, // Its level passes SCAN_DEPTH_LIMIT.
	Zero, // A hash of zero bytes names no file.
}

// scan_want notes a hash that an import names and the boot image does not
// hold. importer is the entry of the module that imports it, or -1 for the
// disk process; level is 1 for an import of the disk process.
scan_want :: proc "contextless" (scan: ^Import_Scan, hash: [HASH_SIZE]u8, importer: int, level: int) -> Want_Answer {
	if hash == {} {
		return .Zero
	}
	for &item in scan.wanted[:scan.wanted_count] {
		if item.hash == hash {
			return .Present
		}
	}
	if level > SCAN_DEPTH_LIMIT {
		scan.bound_passed = true
		return .Too_Deep
	}
	if scan.wanted_count == len(scan.wanted) {
		scan.bound_passed = true
		return .Full
	}
	scan.wanted[scan.wanted_count] = {hash = hash, importer = importer, level = level, entry = -1}
	scan.wanted_count += 1
	return .Added
}

// scan_entry_add notes one entry of the list: an object of 1 byte to
// FILE_BYTES_LIMIT, as the list says, whose name can be the name of a disk
// process. It gives false for an entry that is not noted. The object
// grant_table has no name of a disk process, so it is never read as a
// module file.
scan_entry_add :: proc "contextless" (scan: ^Import_Scan, name: string, size: i64) -> bool {
	if problem, _ := name_problem(name); problem != .None || size < 1 || size > FILE_BYTES_LIMIT {
		return false
	}
	if scan.entry_count == len(scan.entries) {
		scan.entries_left_out = true
		return false
	}
	entry := &scan.entries[scan.entry_count]
	entry^ = {}
	entry.name_length = copy(entry.name[:], name)
	scan.entry_count += 1
	return true
}

// scan_entry_name gives the name of an entry.
scan_entry_name :: proc "contextless" (scan: ^Import_Scan, index: int) -> string {
	entry := &scan.entries[index]
	return string(entry.name[:entry.name_length])
}

// scan_missing gives the first wanted hash that has no bytes yet, or -1.
scan_missing :: proc "contextless" (scan: ^Import_Scan) -> int {
	for &item, index in scan.wanted[:scan.wanted_count] {
		if !item.found {
			return index
		}
	}
	return -1
}

// scan_next gives the entry to read next, or -1 when the scan ends: each
// wanted hash has its bytes, no entry is left to read, or the reads reached
// SCAN_READ_LIMIT. First each entry that was never read, in the order of
// the list; then an entry whose hash was wanted only after its read.
scan_next :: proc "contextless" (scan: ^Import_Scan) -> int {
	if scan_missing(scan) < 0 || scan.reads >= SCAN_READ_LIMIT {
		return -1
	}
	for &entry, index in scan.entries[:scan.entry_count] {
		if !entry.read {
			return index
		}
	}
	for &entry, index in scan.entries[:scan.entry_count] {
		if entry.kept || entry.skipped {
			continue
		}
		for &item in scan.wanted[:scan.wanted_count] {
			if !item.found && item.hash == entry.hash {
				return index
			}
		}
	}
	return -1
}

// scan_read_done notes the hash of the bytes of an entry that came whole.
// It gives the wanted hash that those bytes are, or -1: the caller keeps
// the bytes for the first, and frees them for the second.
scan_read_done :: proc "contextless" (scan: ^Import_Scan, index: int, hash: [HASH_SIZE]u8) -> int {
	scan.reads += 1
	entry := &scan.entries[index]
	entry.read = true
	entry.hash = hash
	for &item, wanted_index in scan.wanted[:scan.wanted_count] {
		if !item.found && item.hash == hash {
			item.found = true
			item.entry = index
			entry.kept = true
			return wanted_index
		}
	}
	return -1
}

// scan_skip notes an entry whose bytes did not come: the object is not
// there any more, it has no byte, or it passes FILE_BYTES_LIMIT. It is not
// read again.
scan_skip :: proc "contextless" (scan: ^Import_Scan, index: int) {
	scan.reads += 1
	entry := &scan.entries[index]
	entry.read = true
	entry.skipped = true
	entry.hash = {}
}
