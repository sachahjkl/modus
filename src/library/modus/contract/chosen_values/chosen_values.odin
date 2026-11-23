// The kept record of chosen values (src/md/features/module_settings.md,
// "The precedence"): what the owner of settings keeps in its store. It holds
// the values that the principal chose, and only them: a setting that the
// principal did not set has no entry, so a later default of the plan or of
// the contract holds for it.
//
// Each entry is a name and a word. The name is the name of the field of the
// setting, so a contract that adds or moves a setting moves no kept value:
// no index is a key. The owner checks each word at its own border before it
// uses it; a word that its border refuses holds as no choice, and stays kept
// as it was.
//
// A rewrite copies each entry that it does not change, the names that the
// owner does not know too: a module of an earlier release that reads a
// record of a later one keeps the choices of the later one for its return.
// Nothing that the owner did not set is overwritten.
//
// The record is bytes of the caller: no count is fixed; the room of the
// caller bounds it. This package allocates no memory and calls no kernel
// operation.
package chosen_values

import "base:intrinsics"

// The bytes "CHOSEN01" and the size of the header: the magic, the count of
// the entries, and four bytes that are zero.
RECORD_MAGIC :: u64(0x3130_4E45_534F_4843)
HEADER_SIZE :: 16
// The bytes of the name of a setting, zero bytes after it: the longest name
// of a parameter of an export (module.NAME_SIZE).
NAME_SIZE :: 32
// One entry: the name, then the word in little-endian.
ENTRY_SIZE :: NAME_SIZE + 8

// Why a record or a change is refused. A refusal reads nothing more and
// writes nothing.
Record_Problem :: enum u8 {
	None             = 0,
	Too_Short        = 1, // Fewer bytes than a header.
	Bad_Magic        = 2, // The record is not a record of chosen values: its owner reads no value from it, and writes over it only when the principal changes a value.
	Reserved_Not_Zero = 3,
	Count_Past_Bytes = 4, // The count names more entries than the bytes hold.
	Bad_Name         = 5, // A name that is empty, longer than NAME_SIZE - 1, holds a byte that is not a small letter, a digit or '_', or has a byte after its first zero.
	Name_Twice       = 6, // Two entries with one name.
	No_Room          = 7, // The record after the change does not fit the bytes of the caller.
}

// The name of each problem, for a line of the log.
@(rodata)
RECORD_PROBLEM_NAMES := [Record_Problem]string {
	.None              = "none",
	.Too_Short         = "too short",
	.Bad_Magic         = "another format",
	.Reserved_Not_Zero = "reserved bytes",
	.Count_Past_Bytes  = "a count past its bytes",
	.Bad_Name          = "a name not valid",
	.Name_Twice        = "a name twice",
	.No_Room           = "no room",
}

// A change of one setting: a new chosen value, or a reset that makes it
// absent.
Change_Kind :: enum u8 {
	Choose = 1,
	Reset  = 2,
}

Change :: struct {
	name:  string,
	kind:  Change_Kind,
	value: u64, // With Choose.
}

// A record that read_record checked: its entries, in the bytes of the
// caller.
Record :: struct {
	entries: []u8,
	count:   int,
}

// name_valid says if a text is a name of a setting: 1 to NAME_SIZE - 1
// bytes, each a small letter, a digit or '_', the first a letter.
name_valid :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) >= NAME_SIZE {
		return false
	}
	for index in 0 ..< len(name) {
		character := name[index]
		letter := character >= 'a' && character <= 'z'
		digit := character >= '0' && character <= '9'
		if !(letter || (index > 0 && (digit || character == '_'))) {
			return false
		}
	}
	return true
}

@(private)
read_u64 :: proc "contextless" (bytes: []u8) -> u64 {
	value: u64
	for index in 0 ..< 8 {
		value |= u64(bytes[index]) << u64(index * 8)
	}
	return value
}

@(private)
write_u64 :: proc "contextless" (bytes: []u8, value: u64) {
	for index in 0 ..< 8 {
		bytes[index] = u8(value >> u64(index * 8))
	}
}

// entry_name gives the name of an entry of a checked record.
entry_name :: proc "contextless" (record: Record, index: int) -> string {
	entry := record.entries[index * ENTRY_SIZE:][:NAME_SIZE]
	length := 0
	for length < NAME_SIZE && entry[length] != 0 {
		length += 1
	}
	return string(entry[:length])
}

// entry_value gives the word of an entry of a checked record.
entry_value :: proc "contextless" (record: Record, index: int) -> u64 {
	return read_u64(record.entries[index * ENTRY_SIZE + NAME_SIZE:][:8])
}

// read_record checks the bytes of a kept record whole: its header, each
// name, and no name twice. An empty slice is the record of a principal who
// chose nothing. The caller gives bytes that it copied from the store, so no
// other party changes them while they are read.
read_record :: proc "contextless" (bytes: []u8) -> (record: Record, problem: Record_Problem) {
	if len(bytes) == 0 {
		return {}, .None
	}
	if len(bytes) < HEADER_SIZE {
		return {}, .Too_Short
	}
	if read_u64(bytes[0:8]) != RECORD_MAGIC {
		return {}, .Bad_Magic
	}
	count := u64(bytes[8]) | u64(bytes[9]) << 8 | u64(bytes[10]) << 16 | u64(bytes[11]) << 24
	if bytes[12] != 0 || bytes[13] != 0 || bytes[14] != 0 || bytes[15] != 0 {
		return {}, .Reserved_Not_Zero
	}
	if count > u64(len(bytes) - HEADER_SIZE) / ENTRY_SIZE {
		return {}, .Count_Past_Bytes
	}
	record = {entries = bytes[HEADER_SIZE:][:int(count) * ENTRY_SIZE], count = int(count)}
	for index in 0 ..< record.count {
		entry := record.entries[index * ENTRY_SIZE:][:NAME_SIZE]
		length := 0
		for length < NAME_SIZE && entry[length] != 0 {
			length += 1
		}
		for after in length ..< NAME_SIZE {
			if entry[after] != 0 {
				return {}, .Bad_Name
			}
		}
		if !name_valid(string(entry[:length])) {
			return {}, .Bad_Name
		}
		for earlier in 0 ..< index {
			if entry_name(record, earlier) == string(entry[:length]) {
				return {}, .Name_Twice
			}
		}
	}
	return record, .None
}

// find gives the chosen word of a name, or found false when the principal
// chose no value for it.
find :: proc "contextless" (record: Record, name: string) -> (value: u64, found: bool) {
	for index in 0 ..< record.count {
		if entry_name(record, index) == name {
			return entry_value(record, index), true
		}
	}
	return 0, false
}

// write_record writes into out the record that a checked record gives after
// the changes: each entry that no change names stays as it was, in its
// place, the names that the caller does not know too; a Choose replaces the
// word of its name or adds an entry at the end; a Reset removes the entry.
// A change with a name that is not valid, two changes of one name, or a
// result past the room of out is refused, and out is then not a record.
// The record and out are two places: out never holds the bytes of record.
write_record :: proc "contextless" (record: Record, changes: []Change, out: []u8) -> (written: int, problem: Record_Problem) {
	for change, index in changes {
		if !name_valid(change.name) || (change.kind != .Choose && change.kind != .Reset) {
			return 0, .Bad_Name
		}
		for earlier in 0 ..< index {
			if changes[earlier].name == change.name {
				return 0, .Name_Twice
			}
		}
	}
	if len(out) < HEADER_SIZE {
		return 0, .No_Room
	}
	place := HEADER_SIZE
	count := 0
	put :: proc "contextless" (out: []u8, place: ^int, name: string, value: u64) -> bool {
		if len(out) - place^ < ENTRY_SIZE {
			return false
		}
		entry := out[place^:][:ENTRY_SIZE]
		intrinsics.mem_zero(raw_data(entry), NAME_SIZE)
		copy(entry[:NAME_SIZE], name)
		write_u64(entry[NAME_SIZE:], value)
		place^ += ENTRY_SIZE
		return true
	}
	for index in 0 ..< record.count {
		name := entry_name(record, index)
		value := entry_value(record, index)
		kept := true
		for change in changes {
			if change.name == name {
				kept = change.kind == .Choose
				value = change.value
			}
		}
		if kept {
			if !put(out, &place, name, value) {
				return 0, .No_Room
			}
			count += 1
		}
	}
	for change in changes {
		if change.kind != .Choose {
			continue
		}
		if _, found := find(record, change.name); found {
			continue
		}
		if !put(out, &place, change.name, change.value) {
			return 0, .No_Room
		}
		count += 1
	}
	write_u64(out[0:8], RECORD_MAGIC)
	out[8], out[9], out[10], out[11] = u8(count), u8(count >> 8), u8(count >> 16), u8(count >> 24)
	out[12], out[13], out[14], out[15] = 0, 0, 0, 0
	return place, .None
}

// The layer that gives a value (src/md/features/module_settings.md, "The
// precedence"). A state export of an owner gives it for each setting. The
// values cross the call region, so they are stated.
Layer :: enum u8 {
	Contract_Default = 0,
	Plan_Default     = 1,
	Chosen           = 2,
	Locked           = 3,
}
