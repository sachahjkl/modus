package root

// The import scan of a disk program: the imports that the boot image does
// not hold are found in the store `programs` of the principal by the hash
// of their bytes (docs/MODULE_CONTRACT.md, "A program from a disk").
//
// The scan runs in the load of the program, after the check of its file
// and before its start, with the same connection, the same deadline and
// the same rules for each answer of the storage service. It lists the root
// tree, reads the bytes of each entry, computes their BLAKE3 hash, and
// keeps the bytes whose hash an import names. No name and no hash that the
// storage service gives decides what runs: a name only says which entry to
// read. The account of the scan and its bounds are in
// modus:support/disk_program (import_scan.odin).

import "modus:contract/blake3"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:support/disk_program"
import "modus:support/storage"
import "modus:support/system"

// One page of the list: its rows, and the bytes of their names.
LIST_PAGE_ROWS :: 16
LIST_NAME_SIZE :: 64 // The bytes of the name of an entry, at most, as the module file service reads it.
LIST_NAME_BYTES :: LIST_PAGE_ROWS * LIST_NAME_SIZE

// The most pages of one list. A storage service that gives the same page
// again cannot make the list last past it; the scan then notes that it
// left entries out.
LIST_PAGE_LIMIT :: 64

// What the import scan of the load that runs holds.
Disk_Imports :: struct {
	scan:         disk_program.Import_Scan,
	reading:      int, // The entry that is read; -1: none.
	rows:         [LIST_PAGE_ROWS]storage.Listed, // The rows of the last page: the call writes them here.
	names:        [LIST_NAME_BYTES]u8, // The names of those rows.
	after:        [LIST_NAME_SIZE]u8, // The name of the last entry that the list gave: the next page starts after it.
	after_length: int,
	pages:        int,
	read:         disk_program.Read, // The size of the entry that is read, and the bytes that came.
	memory:       system.Handle, // The memory of that entry, from the budget of the disk programs. 0: none.
	bytes:        []u8, // That memory, mapped.
	kept:         [disk_program.SCAN_WANTED_CAPACITY]system.Handle, // The memory of each file that the scan kept, at the place of its wanted hash.
	files:        [disk_program.SCAN_WANTED_CAPACITY]system.Source_File, // Those files, for the load source.
}

disk_imports: Disk_Imports

// disk_imports_files gives the files that the scan kept, for the load
// source of the program. The start comes only when each wanted hash has
// its file, so the files are the first wanted_count places.
disk_imports_files :: proc "contextless" () -> []system.Source_File {
	return disk_imports.files[:disk_imports.scan.wanted_count]
}

// disk_imports_begin notes the imports of the program file that the boot
// image does not hold. With none, the program starts as before; else the
// list of the store starts.
disk_imports_begin :: proc "contextless" (wait: ^system.Wait) {
	imports := &disk_imports
	imports^ = {}
	imports.reading = -1
	load := &disk_load
	name := string(load.name[:load.name_length])
	disk_imports_want(load.bytes, -1, 1)
	if imports.scan.bound_passed {
		disk_import_bound_refusal()
		return
	}
	if imports.scan.wanted_count == 0 {
		disk_load_start()
		return
	}
	system.log_in("programs", .Info, "root: ", system.Module_Name{name}, " imports ", u64(imports.scan.wanted_count), " modules that the boot image does not hold: the import scan reads the store ", disk_program.STORE_NAME, " to find them by the hash of their bytes")
	load.stage = .List
	if !disk_import_list_ask() {
		disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service took no call")
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_imports_want notes each import of a module file whose hash the boot
// image does not hold, and the module of a replacement of the machine for
// it: the loader reads both. importer is the entry of the module, or -1 for
// the program. A file that is not a valid module notes nothing: the loader
// refuses it with its own load error.
disk_imports_want :: proc "contextless" (file: []u8, importer: int, level: int) {
	if module.validate(file) != .None {
		return
	}
	source := load_source()
	for number in 1 ..< module.count(file, .Imports) {
		record, _ := module.record(file, .Imports, number, module.Import)
		disk_import_want_hash(record.hash, importer, level)
		for item in source.replacements {
			if item.from == record.hash {
				disk_import_want_hash(item.to, importer, level)
			}
		}
	}
}

// disk_import_want_hash notes one hash, if no module of the boot image has
// it: a module of the boot image wins over a file of the store.
disk_import_want_hash :: proc "contextless" (hash: [disk_program.HASH_SIZE]u8, importer: int, level: int) {
	if system.image_entry_of(image, hash) != nil {
		return
	}
	disk_program.scan_want(&disk_imports.scan, hash, importer, level)
}

// disk_import_replaced says if a replacement of the machine gives another
// module in place of a hash: the loader then walks the imports of the
// other module, and not of this one.
disk_import_replaced :: proc "contextless" (hash: [disk_program.HASH_SIZE]u8) -> bool {
	for item in load_source().replacements {
		if item.from == hash {
			return true
		}
	}
	return false
}

// disk_import_list_ask asks for the next page of the entries of the root
// tree, after the last name that the list gave.
disk_import_list_ask :: proc "contextless" () -> bool {
	load := &disk_load
	imports := &disk_imports
	load.arguments = {}
	load.arguments[0].integer = u64(storage.ROOT)
	load.arguments[1].text = imports.after[:imports.after_length]
	load.arguments[2].table = {records = ([^]u8)(&imports.rows)[:size_of(imports.rows)], count = 0}
	load.arguments[3].table = {records = imports.names[:], count = 0}
	load.argument_count = 4
	status: storage.Status
	load.sent, status = storage.call_send(&load.client, "list", load.arguments[:load.argument_count])
	return status == .Ok
}

// disk_import_ask sends one call of the storage service for the entry that
// the scan reads: its size, or its bytes from an offset.
disk_import_ask :: proc "contextless" (export: string, offset: u64, with_offset: bool) -> bool {
	load := &disk_load
	imports := &disk_imports
	entry := &imports.scan.entries[imports.reading]
	load.arguments = {}
	load.arguments[0].integer = u64(storage.ROOT)
	load.arguments[1].text = entry.name[:entry.name_length]
	load.argument_count = 2
	if with_offset {
		load.arguments[2].integer = offset
		load.argument_count = 3
	}
	status: storage.Status
	load.sent, status = storage.call_send(&load.client, export, load.arguments[:load.argument_count])
	return status == .Ok
}

// disk_import_list_answer notes the objects of one page, and asks for the
// next one. An empty page ends the list, and the reads start. The rows and
// the names are in the memory of this service: the call copied them, so
// the storage service cannot change them after their check.
disk_import_list_answer :: proc "contextless" (value: i64, wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	count := int(min(value, LIST_PAGE_ROWS))
	if count == 0 {
		disk_import_read_next(wait)
		return
	}
	for item in imports.rows[:count] {
		if item.name_offset < 0 || item.name_count <= 0 || item.name_count > LIST_NAME_SIZE || item.name_offset > LIST_NAME_BYTES - item.name_count {
			disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service listed an entry whose name is out of its page")
			return
		}
		entry_name := string(imports.names[item.name_offset:][:item.name_count])
		imports.after_length = copy(imports.after[:], entry_name)
		// The entry of the program holds the file that this load checked:
		// a module never imports itself.
		if item.kind == storage.ENTRY_OBJECT && entry_name != string(load.name[:load.name_length]) {
			disk_program.scan_entry_add(&imports.scan, entry_name, item.size)
		}
	}
	imports.pages += 1
	if imports.scan.entries_left_out || imports.pages >= LIST_PAGE_LIMIT {
		imports.scan.entries_left_out = true
		disk_import_read_next(wait)
		return
	}
	if !disk_import_list_ask() {
		disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service took no call")
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_import_read_next asks for the size of the next entry to read, or
// ends the scan: the program starts when each wanted hash has its file.
disk_import_read_next :: proc "contextless" (wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	index := disk_program.scan_next(&imports.scan)
	if index < 0 {
		imports.reading = -1
		if disk_program.scan_missing(&imports.scan) >= 0 {
			disk_import_missing_refusal()
			return
		}
		disk_load_start()
		return
	}
	imports.reading = index
	load.stage = .Import_Size
	if !disk_import_ask("size", 0, false) {
		disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service took no call")
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_import_entry_skip notes that the bytes of the entry that is read do
// not come, and reads the next one.
disk_import_entry_skip :: proc "contextless" (wait: ^system.Wait) {
	disk_import_memory_free()
	disk_program.scan_skip(&disk_imports.scan, disk_imports.reading)
	disk_import_read_next(wait)
}

// disk_import_size_answer makes the memory of the entry, from the budget
// of the disk programs, and asks for its first bytes. The size is checked
// one time, here, as the size of the program file is.
disk_import_size_answer :: proc "contextless" (value: i64, wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	size := u64(value)
	answer: disk_program.Size_Answer
	imports.read, answer = disk_program.read_begin(size)
	if answer != .Good {
		disk_import_entry_skip(wait)
		return
	}
	budget, status := disk_programs_budget_get()
	address: rawptr
	if status == .Ok {
		imports.memory, status = system.memory_create((size + system.PAGE_SIZE - 1) / system.PAGE_SIZE, budget)
	}
	if status == .Ok {
		address, status = system.memory_map(imports.memory)
	}
	if status != .Ok {
		entry_name := disk_program.scan_entry_name(&imports.scan, imports.reading)
		disk_import_refused(status, errors.Kind.Refused, "no memory in the budget of the disk programs for the ", size, " bytes of the file ", system.Module_Name{entry_name}, " of the store ", disk_program.STORE_NAME, ": status ", status)
		return
	}
	imports.bytes = ([^]u8)(address)[:size]
	load.stage = .Import_Bytes
	if !disk_import_ask("read_range", 0, true) {
		disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service took no call")
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_import_bytes_answer copies the bytes of one answer, as the load of
// the program file does. When the entry is whole, its hash is computed on
// the bytes that this service holds: bytes whose hash an import names are
// kept for the load source, and their imports are noted; the others are
// freed.
disk_import_bytes_answer :: proc "contextless" (text: []u8, wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	entry_name := disk_program.scan_entry_name(&imports.scan, imports.reading)
	count := u64(len(text))
	step := disk_program.read_step(&imports.read, count)
	switch step {
	case .More, .Complete:
		copy(imports.bytes[imports.read.received - count:][:count], text)
	case .No_Progress:
		disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service gave no byte at the byte ", imports.read.received, " of ", imports.read.size, " of the file ", system.Module_Name{entry_name})
		return
	case .Too_Many:
		disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service gave ", count, " bytes where the file ", system.Module_Name{entry_name}, " has ", imports.read.size - imports.read.received, " left")
		return
	}
	if step == .More {
		if !disk_import_ask("read_range", imports.read.received, true) {
			disk_import_refused(.Bad_State, errors.Kind.Refused, "the storage service took no call")
			return
		}
		system.wait_records(wait, &load.client.calls.completions)
		return
	}
	hash := blake3.hash(imports.bytes)
	wanted := disk_program.scan_read_done(&imports.scan, imports.reading, hash)
	if wanted < 0 {
		disk_import_memory_free()
		disk_import_read_next(wait)
		return
	}
	// The file stays mapped until the end of the load: the loader copies
	// it into the program.
	imports.kept[wanted] = imports.memory
	imports.files[wanted] = {hash = hash, bytes = imports.bytes, name = entry_name}
	imports.memory = 0
	imports.bytes = nil
	item := &imports.scan.wanted[wanted]
	name := string(load.name[:load.name_length])
	system.log_in("programs", .Info, "root: ", system.Module_Name{name}, ": the import ", system.Hash{hash[:]}, " of ", system.Module_Name{disk_import_importer_name(item.importer)}, " is the file ", system.Module_Name{entry_name}, " of the store ", disk_program.STORE_NAME, ", checked on its bytes")
	if !disk_import_replaced(hash) {
		disk_imports_want(imports.files[wanted].bytes, imports.reading, item.level + 1)
	}
	if imports.scan.bound_passed {
		disk_import_bound_refusal()
		return
	}
	disk_import_read_next(wait)
}

// disk_import_importer_name gives the name of an importer for the log: the
// program, or the entry of a file that the scan kept.
disk_import_importer_name :: proc "contextless" (importer: int) -> string {
	if importer < 0 {
		return string(disk_load.name[:disk_load.name_length])
	}
	return disk_program.scan_entry_name(&disk_imports.scan, importer)
}

// disk_import_missing_refusal ends the load: a wanted hash has no file of
// the store whose bytes have it. The line names the import and its
// importer.
disk_import_missing_refusal :: proc "contextless" () {
	imports := &disk_imports
	item := &imports.scan.wanted[disk_program.scan_missing(&imports.scan)]
	left_out := ""
	if imports.scan.entries_left_out {
		left_out = "; the store has more entries than the 64 that the scan notes"
	}
	disk_import_refused(.Bad_Handle, errors.Kind.Absent, system.Module_Name{disk_import_importer_name(item.importer)}, " imports ", system.Hash{item.hash[:]}, ", and no file of the boot image or of the store ", disk_program.STORE_NAME, " has bytes with this hash; the import scan read ", u64(imports.scan.reads), " files", left_out)
}

// disk_import_bound_refusal ends the load: the imports pass the bounds of
// the scan.
disk_import_bound_refusal :: proc "contextless" () {
	disk_import_refused(.No_Slot, errors.Kind.Full, "its imports outside the boot image pass the bounds of the import scan: ", u64(disk_program.SCAN_WANTED_CAPACITY), " modules of the store, ", u64(disk_program.SCAN_DEPTH_LIMIT), " levels")
}

// disk_import_refused ends the load with one line of the log, and the
// error record of the command with the kind of the refusal.
disk_import_refused :: proc "contextless" (status: system.Status, kind_of_error: errors.Kind, parts: ..system.Part) {
	name := string(disk_load.name[:disk_load.name_length])
	kind := u32(system.Root_Command.Start_From_Disk)
	disk_load_end(status, disk_refused(name, errors.ring_fail(kind, kind_of_error, .Modules, 2, 0, 0, i64(status)), ..parts))
}

// disk_import_memory_free frees the memory of the entry that is read.
disk_import_memory_free :: proc "contextless" () {
	imports := &disk_imports
	if imports.bytes != nil {
		system.memory_unmap(raw_data(imports.bytes))
	}
	if imports.memory != 0 {
		system.close(imports.memory)
	}
	imports.memory = 0
	imports.bytes = nil
}

// disk_imports_end gives back each memory of the scan: the entry that is
// read and each file that it kept. The end of each load calls it.
disk_imports_end :: proc "contextless" () {
	imports := &disk_imports
	disk_import_memory_free()
	for &memory, index in imports.kept {
		if memory == 0 {
			continue
		}
		if imports.files[index].bytes != nil {
			system.memory_unmap(raw_data(imports.files[index].bytes))
		}
		system.close(memory)
		memory = 0
	}
	imports^ = {}
	imports.reading = -1
}
