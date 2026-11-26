#+build !freestanding
#+build !modus
package disk_process

import "core:testing"

// A name of a disk process is a name of an entry of a tree, of 23 bytes at
// most, and never the name of the store of the module files.
@(test)
names_that_are_refused :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:    string,
		problem: Name_Problem,
		offset:  int,
	} {
		{"visitor", .None, 0},
		{"a", .None, 0},
		{"twenty_three_bytes_long", .None, 0},
		{"", .Empty, 0},
		{"twenty_four_bytes_long__", .Too_Long, 0},
		{"a/b", .Bad_Byte, 1},
		{"a\x00b", .Bad_Byte, 1},
		{"a b", .Bad_Byte, 1}, // A name of a process has no space.
		{"café", .Bad_Byte, 3}, // A name of a process is ASCII.
		{".", .Bad_Byte, 0},
		{"..", .Bad_Byte, 0},
		{"module_files", .Store_Name, 0},
		{"grant_table", .Table_Name, 0},
	}
	for item in cases {
		problem, offset := name_problem(item.name)
		testing.expectf(t, problem == item.problem && offset == item.offset, "the name %q: %v at %d, expected %v at %d", item.name, problem, offset, item.problem, item.offset)
	}
	testing.expect_value(t, len("twenty_three_bytes_long"), NAME_LIMIT)
}

// The name of a debug object is the hash of its module in 64 digits of
// lower case: no nickname has it, and an upper case digit, a shorter
// name or a byte that is no digit is no such name.
@(test)
the_name_of_a_debug_object :: proc(t: ^testing.T) {
	hash: [HASH_SIZE]u8
	for &byte, index in hash {
		byte = u8(index * 11 + 3)
	}
	digits: [HASH_DIGITS]u8
	debug_object_name_write(&digits, hash)
	testing.expect(t, debug_object_name_is(string(digits[:])))
	parsed, ok := hash_parse(string(digits[:]))
	testing.expect(t, ok && parsed == hash)
	testing.expect(t, !debug_object_name_is(string(digits[:HASH_DIGITS - 1])))
	upper := digits
	upper[0] = 'A'
	testing.expect(t, !debug_object_name_is(string(upper[:])))
	other := digits
	other[5] = 'g'
	testing.expect(t, !debug_object_name_is(string(other[:])))
	for name in ([]string{"visitor", "twenty_three_bytes_long", "grant_table"}) {
		testing.expect(t, !debug_object_name_is(name))
	}
	// A debug object has its own limit, larger than the limit of a module
	// file.
	_, answer := read_begin(DEBUG_OBJECT_BYTES_LIMIT, DEBUG_OBJECT_BYTES_LIMIT)
	testing.expect_value(t, answer, Size_Answer.Good)
	_, answer = read_begin(DEBUG_OBJECT_BYTES_LIMIT + 1, DEBUG_OBJECT_BYTES_LIMIT)
	testing.expect_value(t, answer, Size_Answer.Too_Large)
	_, answer = read_begin(FILE_BYTES_LIMIT + 1)
	testing.expect_value(t, answer, Size_Answer.Too_Large)
}

// A name goes through three values of a record and comes back, with a zero
// byte after it whatever the values hold.
@(test)
a_name_through_three_values :: proc(t: ^testing.T) {
	for name in ([]string{"visitor", "a", "twenty_three_bytes_long"}) {
		bytes, length := name_unpack(name_pack(name))
		testing.expect_value(t, string(bytes[:length]), name)
	}
	// Values with no zero byte: the name ends at its limit.
	bytes, length := name_unpack({max(u64), max(u64), max(u64)})
	testing.expect_value(t, length, NAME_LIMIT)
	testing.expect_value(t, bytes[NAME_LIMIT - 1], u8(0xFF))
	// A name that is too long is cut at the limit, never past it.
	_, cut := name_unpack(name_pack("twenty_four_bytes_long__"))
	testing.expect_value(t, cut, NAME_LIMIT)
}

// A hash is 64 hexadecimal digits, the first byte first, and the text that
// hash_write gives is the text that hash_parse reads.
@(test)
a_hash_as_digits :: proc(t: ^testing.T) {
	hash: [HASH_SIZE]u8
	for &byte, index in hash {
		byte = u8(index * 7 + 1)
	}
	digits: [HASH_DIGITS]u8
	hash_write(&digits, hash)
	testing.expect_value(t, string(digits[:6]), "01080f")
	parsed, ok := hash_parse(string(digits[:]))
	testing.expect(t, ok)
	testing.expect(t, parsed == hash)
	// Upper case is the same hash.
	upper := digits
	for &digit in upper {
		if digit >= 'a' && digit <= 'f' {
			digit -= 'a' - 'A'
		}
	}
	parsed, ok = hash_parse(string(upper[:]))
	testing.expect(t, ok && parsed == hash)
	// One digit less, one more, and a byte that is no digit.
	_, ok = hash_parse(string(digits[:HASH_DIGITS - 1]))
	testing.expect(t, !ok)
	longer: [HASH_DIGITS + 1]u8
	copy(longer[:], digits[:])
	longer[HASH_DIGITS] = '0'
	_, ok = hash_parse(string(longer[:]))
	testing.expect(t, !ok)
	wrong := digits
	wrong[10] = 'g'
	_, ok = hash_parse(string(wrong[:]))
	testing.expect(t, !ok)
	_, ok = hash_parse("")
	testing.expect(t, !ok)
}

// The size of a file is checked one time, before any memory is made.
@(test)
the_size_of_a_file :: proc(t: ^testing.T) {
	read, answer := read_begin(0)
	testing.expect_value(t, answer, Size_Answer.Empty)
	read, answer = read_begin(FILE_BYTES_LIMIT + 1)
	testing.expect_value(t, answer, Size_Answer.Too_Large)
	read, answer = read_begin(max(u64))
	testing.expect_value(t, answer, Size_Answer.Too_Large)
	read, answer = read_begin(FILE_BYTES_LIMIT)
	testing.expect_value(t, answer, Size_Answer.Good)
	testing.expect_value(t, read.size, u64(FILE_BYTES_LIMIT))
	testing.expect_value(t, read.received, u64(0))
}

// A file comes in parts: each part adds bytes, and the last one makes the
// file whole.
@(test)
a_file_in_parts :: proc(t: ^testing.T) {
	read, _ := read_begin(100_000)
	testing.expect_value(t, read_step(&read, 65_536), Read_Step.More)
	testing.expect_value(t, read.received, u64(65_536))
	testing.expect_value(t, read_step(&read, 34_464), Read_Step.Complete)
	testing.expect_value(t, read.received, u64(100_000))
	one, _ := read_begin(1)
	testing.expect_value(t, read_step(&one, 1), Read_Step.Complete)
}

// A storage service that answers with no byte, or with more bytes than the
// file has left, ends the read: the count of what came does not change.
@(test)
answers_that_end_a_read :: proc(t: ^testing.T) {
	read, _ := read_begin(1000)
	testing.expect_value(t, read_step(&read, 0), Read_Step.No_Progress)
	testing.expect_value(t, read.received, u64(0))
	testing.expect_value(t, read_step(&read, 1001), Read_Step.Too_Many)
	testing.expect_value(t, read.received, u64(0))
	testing.expect_value(t, read_step(&read, 600), Read_Step.More)
	testing.expect_value(t, read_step(&read, 401), Read_Step.Too_Many)
	testing.expect_value(t, read_step(&read, max(u64)), Read_Step.Too_Many)
	testing.expect_value(t, read.received, u64(600))
	testing.expect_value(t, read_step(&read, 0), Read_Step.No_Progress)
}

// A read ends after at most as many answers as the file has bytes: each
// answer that is kept adds one byte or more.
@(test)
a_read_of_one_byte_at_a_time_ends :: proc(t: ^testing.T) {
	read, _ := read_begin(4096)
	answers := 0
	for {
		answers += 1
		step := read_step(&read, 1)
		if step == .Complete {
			break
		}
		if !testing.expect_value(t, step, Read_Step.More) {
			return
		}
	}
	testing.expect_value(t, answers, 4096)
}
