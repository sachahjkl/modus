// What the root service, the console and the modus tool agree on for a
// disk program: a program whose module file is an object of the store
// `programs` of the storage service, and not a file of the boot image
// (docs/MODULE_CONTRACT.md, "A program from a disk").
//
// No allocator and no kernel operation: the host tests run each procedure
// (disk_program_test.odin).
//
// The parts:
//
// - `STORE_NAME`, `STORE_BLOCKS_LIMIT`: the store of the module files.
//   `SERVICE_VALUE_PRINCIPAL`: the principal of the module file service,
//   whose private store it is.
//   `TABLE_OBJECT_NAME`: the object of that store that holds the
//   persisted disk grant table.
// - `name_problem`, `name_pack`, `name_unpack`: the name of a disk program,
//   in three values of a record of the root ring.
// - `hash_parse`, `hash_write`: the hash of the command, as 64 hexadecimal
//   digits.
// - `Read`, `read_begin`, `read_step`: the rules of the answers of the
//   storage service while the root service reads a file.
// - `Grant_Table`, `start_file`, `table_allow`, `table_disallow`,
//   `table_move`, `grant_by_command`, `table_encode`, `table_decode`: the
//   disk grant table of a principal, its nickname rule, and its persisted
//   form (grant_table.odin). `table_persistence_set`: its setting of
//   persistence. `table_key_of_machine_key`: the key of the tag of the
//   table of principal 0.
// - `PROGRAMS_BUDGET`, `LARGEST_BUDGET` (budget.odin): the one budget that
//   pays all disk programs, and the most that one of them gets.
// - `Import_Scan`, `scan_want`, `scan_entry_add`, `scan_next`,
//   `scan_read_done`, `scan_skip` (import_scan.odin): the account of the
//   import scan that finds an import of a disk program in the store
//   `programs` by the hash of its bytes, with its bounds.
//
// See [disk program](term:disk-program).
package disk_program

// The store whose root tree holds the module files: one entry for each
// program, its name the name of the program. For a named principal the
// root service adds the principal to this name, as for each store.
STORE_NAME :: "programs"

// The object of the root tree of the store `programs` that holds the
// persisted disk grant table of its principal (grant_table.odin). No disk
// program has this name.
TABLE_OBJECT_NAME :: "grant_table"

// The limit of blocks of the store `programs`, as the root service grants
// it and as the modus tool writes it: 16 MiB. The two numbers are one
// constant, so the grant of a read never differs from the limit on the
// disk.
STORE_BLOCKS_LIMIT :: 4096

// The bytes of the name of a disk program: three values of a record of
// the root ring, with a zero byte after it. The other four values of the
// record hold the hash.
NAME_LIMIT :: 23

// The most bytes of the module file of a disk program. The root service
// reads the file into memory of its own budget before it checks the hash:
// the limit bounds what a file of a disk takes from that budget.
FILE_BYTES_LIMIT :: 4 << 20

// The deadline of one load, from the command to the start of the program.
// It frees the one place of the load when the storage service gives no
// answer; it is not a measure of the disk.
LOAD_DEADLINE_MILLISECONDS :: 30_000

// The value of the context of the module file service, the program
// `programs`, that holds the number of its principal: its private store
// is the store `programs` of that principal, and it serves the callers
// that act for that principal only. The other values of 0 to 15 that a
// service with a store and an endpoint receives are 1, 2 and 3.
SERVICE_VALUE_PRINCIPAL :: 4

HASH_SIZE :: 32 // The bytes of a hash.
HASH_DIGITS :: 2 * HASH_SIZE // The hexadecimal digits of a hash.

// Why a text cannot be the name of a disk program: the result of
// `name_problem`.
Name_Problem :: enum u8 {
	None, // The name is valid.
	Empty, // The name has no byte.
	Too_Long, // More than NAME_LIMIT bytes.
	Bad_Byte, // A byte that is no visible character of ASCII, or a byte '/', or the name is "." or "..": no name of a program.
	Store_Name, // The name of the store of the module files: its private store would be that store.
	Table_Name, // The name of the object of the disk grant table in that store: the table would be read as a module file, and written over one.
}

// name_problem says why a text cannot be the name of a disk program, or
// None. The name is the name of an entry of a tree, so it follows the rule
// of such a name, and the name of a program, so it is ASCII; offset is the
// place of the byte of Bad_Byte.
name_problem :: proc "contextless" (name: string) -> (problem: Name_Problem, offset: int) {
	if len(name) == 0 {
		return .Empty, 0
	}
	if len(name) > NAME_LIMIT {
		return .Too_Long, 0
	}
	// The name of a program is an identifier of the system, as the name of
	// a module: visible characters of ASCII, which each layout types and
	// each log shows the same (src/md/data/text_encoding.md).
	for index in 0 ..< len(name) {
		if name[index] <= ' ' || name[index] > '~' || name[index] == '/' {
			return .Bad_Byte, index
		}
	}
	if name == "." || name == ".." {
		return .Bad_Byte, 0
	}
	if name == STORE_NAME {
		return .Store_Name, 0
	}
	if name == TABLE_OBJECT_NAME {
		return .Table_Name, 0
	}
	return .None, 0
}

// name_pack gives the three values of a name, as the command
// Start_From_Disk carries it. A name longer than NAME_LIMIT bytes is cut:
// the caller refuses it first (name_problem).
name_pack :: proc "contextless" (name: string) -> (values: [3]u64) {
	bytes: [NAME_LIMIT + 1]u8
	copy(bytes[:NAME_LIMIT], name)
	return transmute([3]u64)bytes
}

// name_unpack gives the bytes of a name from three values, and its length:
// the bytes before the first zero byte, NAME_LIMIT at most.
name_unpack :: proc "contextless" (values: [3]u64) -> (name: [NAME_LIMIT]u8, length: int) {
	bytes := transmute([NAME_LIMIT + 1]u8)values
	for length < NAME_LIMIT && bytes[length] != 0 {
		name[length] = bytes[length]
		length += 1
	}
	return
}

// hash_parse reads a hash from 64 hexadecimal digits, the first byte
// first, in lower case or in upper case. ok is false for another count of
// bytes or for a byte that is no digit.
hash_parse :: proc "contextless" (text: string) -> (hash: [HASH_SIZE]u8, ok: bool) {
	if len(text) != HASH_DIGITS {
		return {}, false
	}
	for index in 0 ..< HASH_SIZE {
		high, high_ok := digit_value(text[2 * index])
		low, low_ok := digit_value(text[2 * index + 1])
		if !high_ok || !low_ok {
			return {}, false
		}
		hash[index] = high << 4 | low
	}
	return hash, true
}

@(private)
digit_value :: proc "contextless" (digit: u8) -> (value: u8, ok: bool) {
	switch digit {
	case '0' ..= '9':
		return digit - '0', true
	case 'a' ..= 'f':
		return digit - 'a' + 10, true
	case 'A' ..= 'F':
		return digit - 'A' + 10, true
	}
	return 0, false
}

// hash_write writes a hash as 64 hexadecimal digits in lower case, the
// first byte first: the text that hash_parse reads.
hash_write :: proc "contextless" (out: ^[HASH_DIGITS]u8, hash: [HASH_SIZE]u8) {
	digits := "0123456789abcdef"
	for byte, index in hash {
		out[2 * index] = digits[byte >> 4]
		out[2 * index + 1] = digits[byte & 15]
	}
}

// The read of one file: the size that the storage service gave, and the
// bytes that came. The root service keeps one for the load that runs.
Read :: struct {
	size:     u64, // The bytes of the file.
	received: u64, // The bytes that came, from the start of the file.
}

// What the answer to the question of the size gives.
Size_Answer :: enum u8 {
	Good, // The file has 1 to FILE_BYTES_LIMIT bytes.
	Empty, // The object has no byte: no module.
	Too_Large, // More than FILE_BYTES_LIMIT bytes.
}

// read_begin starts the read of a file from the size that the storage
// service gave. The size is checked here, one time: no later answer
// changes it.
read_begin :: proc "contextless" (size: u64) -> (read: Read, answer: Size_Answer) {
	if size == 0 {
		return {}, .Empty
	}
	if size > FILE_BYTES_LIMIT {
		return {}, .Too_Large
	}
	return {size = size}, .Good
}

// What one answer with bytes gives.
Read_Step :: enum u8 {
	More, // The bytes are a part of the file: ask again from `received`.
	Complete, // The file is whole: check its hash.
	No_Progress, // The answer has no byte, and the file is not whole: the same question would get the same answer for ever.
	Too_Many, // The answer has more bytes than the file has left.
}

// read_step counts the bytes of one answer. The caller copies the bytes
// only for More and Complete: for those, the count is at most what the
// file has left. Each More adds one byte or more, so a read ends after at
// most `size` answers.
read_step :: proc "contextless" (read: ^Read, count: u64) -> Read_Step {
	if count > read.size - read.received {
		return .Too_Many
	}
	if count == 0 {
		return .No_Progress
	}
	read.received += count
	return read.received == read.size ? .Complete : .More
}
