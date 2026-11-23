#+build !freestanding
package chosen_values

import "core:testing"

// A record of nothing is the empty record: a principal who chose nothing.
@(test)
the_empty_record_holds_no_choice :: proc(t: ^testing.T) {
	record, problem := read_record(nil)
	testing.expect_value(t, problem, Record_Problem.None)
	testing.expect_value(t, record.count, 0)
	_, found := find(record, "font")
	testing.expect(t, !found)
}

// Each damaged record is refused whole, and no value is read from it.
@(test)
a_damaged_record_is_refused_whole :: proc(t: ^testing.T) {
	buffer: [HEADER_SIZE + 2 * ENTRY_SIZE]u8
	written, problem := write_record({}, {{name = "font", kind = .Choose, value = 1}, {name = "scale", kind = .Choose, value = 10}}, buffer[:])
	testing.expect_value(t, problem, Record_Problem.None)
	testing.expect_value(t, written, HEADER_SIZE + 2 * ENTRY_SIZE)
	good := buffer
	// Shorter than a header, at each length from 1.
	for length in 1 ..< HEADER_SIZE {
		_, short := read_record(good[:length])
		testing.expect_value(t, short, Record_Problem.Too_Short)
	}
	// Another magic: the record of another format.
	other := good
	other[0] ~= 1
	_, magic := read_record(other[:])
	testing.expect_value(t, magic, Record_Problem.Bad_Magic)
	// A reserved byte.
	reserved := good
	reserved[13] = 1
	_, reserved_problem := read_record(reserved[:])
	testing.expect_value(t, reserved_problem, Record_Problem.Reserved_Not_Zero)
	// A count one past the bytes, and the largest count.
	for count in ([?]u32{3, max(u32)}) {
		past := good
		past[8], past[9], past[10], past[11] = u8(count), u8(count >> 8), u8(count >> 16), u8(count >> 24)
		_, count_problem := read_record(past[:])
		testing.expect_value(t, count_problem, Record_Problem.Count_Past_Bytes)
	}
	// A record cut inside its last entry.
	_, cut := read_record(good[:len(good) - 1])
	testing.expect_value(t, cut, Record_Problem.Count_Past_Bytes)
	// An empty name, a capital letter, a byte after the zero, a first digit.
	for place in ([?]int{0, 1}) {
		bad := good
		bad[HEADER_SIZE + place] = 'F'
		_, name_problem := read_record(bad[:])
		testing.expect_value(t, name_problem, Record_Problem.Bad_Name)
	}
	empty := good
	empty[HEADER_SIZE] = 0
	_, empty_problem := read_record(empty[:])
	testing.expect_value(t, empty_problem, Record_Problem.Bad_Name)
	tail := good
	tail[HEADER_SIZE + NAME_SIZE - 1] = 'x'
	_, tail_problem := read_record(tail[:])
	testing.expect_value(t, tail_problem, Record_Problem.Bad_Name)
	digit := good
	digit[HEADER_SIZE] = '1'
	_, digit_problem := read_record(digit[:])
	testing.expect_value(t, digit_problem, Record_Problem.Bad_Name)
	// One name twice.
	twice := good
	copy(twice[HEADER_SIZE + ENTRY_SIZE:][:NAME_SIZE], twice[HEADER_SIZE:][:NAME_SIZE])
	_, twice_problem := read_record(twice[:])
	testing.expect_value(t, twice_problem, Record_Problem.Name_Twice)
	// The whole record reads.
	record, whole := read_record(good[:])
	testing.expect_value(t, whole, Record_Problem.None)
	value, found := find(record, "scale")
	testing.expect(t, found && value == 10)
}

// A change refuses a name that is not valid, a name twice and a result past
// the room, and then writes no record.
@(test)
a_change_that_breaks_the_record_is_refused :: proc(t: ^testing.T) {
	buffer: [HEADER_SIZE + ENTRY_SIZE]u8
	long := "a_name_of_thirty_two_bytes_exact"
	testing.expect_value(t, len(long), NAME_SIZE)
	for name in ([?]string{"", "Font", "1font", "font-size", long}) {
		_, problem := write_record({}, {{name = name, kind = .Choose, value = 1}}, buffer[:])
		testing.expect_value(t, problem, Record_Problem.Bad_Name)
	}
	_, unknown_kind := write_record({}, {{name = "font", kind = Change_Kind(9), value = 1}}, buffer[:])
	testing.expect_value(t, unknown_kind, Record_Problem.Bad_Name)
	_, twice := write_record({}, {{name = "font", kind = .Choose, value = 1}, {name = "font", kind = .Reset}}, buffer[:])
	testing.expect_value(t, twice, Record_Problem.Name_Twice)
	_, no_room := write_record({}, {{name = "font", kind = .Choose, value = 1}, {name = "scale", kind = .Choose, value = 2}}, buffer[:])
	testing.expect_value(t, no_room, Record_Problem.No_Room)
	_, no_header := write_record({}, {}, buffer[:HEADER_SIZE - 1])
	testing.expect_value(t, no_header, Record_Problem.No_Room)
	// Exactly the room of one entry.
	written, fits := write_record({}, {{name = "font", kind = .Choose, value = 1}}, buffer[:])
	testing.expect_value(t, fits, Record_Problem.None)
	testing.expect_value(t, written, len(buffer))
}

// A rewrite keeps each entry that it does not change, the names that the
// owner does not know too, in their place; a reset removes one entry; a
// choice of a new name comes last.
@(test)
a_rewrite_keeps_what_it_does_not_change :: proc(t: ^testing.T) {
	first: [HEADER_SIZE + 4 * ENTRY_SIZE]u8
	written, problem := write_record({}, {{name = "font", kind = .Choose, value = 1}, {name = "from_a_later_release", kind = .Choose, value = 77}, {name = "scale", kind = .Choose, value = 12}}, first[:])
	testing.expect_value(t, problem, Record_Problem.None)
	record, read_problem := read_record(first[:written])
	testing.expect_value(t, read_problem, Record_Problem.None)
	second: [HEADER_SIZE + 4 * ENTRY_SIZE]u8
	written, problem = write_record(record, {{name = "font", kind = .Reset}, {name = "scale", kind = .Choose, value = 14}, {name = "grid_fit", kind = .Choose, value = 1}}, second[:])
	testing.expect_value(t, problem, Record_Problem.None)
	after, after_problem := read_record(second[:written])
	testing.expect_value(t, after_problem, Record_Problem.None)
	testing.expect_value(t, after.count, 3)
	testing.expect_value(t, entry_name(after, 0), "from_a_later_release")
	testing.expect_value(t, entry_value(after, 0), u64(77))
	testing.expect_value(t, entry_name(after, 1), "scale")
	testing.expect_value(t, entry_value(after, 1), u64(14))
	testing.expect_value(t, entry_name(after, 2), "grid_fit")
	_, font_found := find(after, "font")
	testing.expect(t, !font_found)
	// A reset of a name that holds no choice changes nothing.
	third: [HEADER_SIZE + 4 * ENTRY_SIZE]u8
	written, problem = write_record(after, {{name = "appearance", kind = .Reset}}, third[:])
	testing.expect_value(t, problem, Record_Problem.None)
	testing.expect_value(t, written, HEADER_SIZE + 3 * ENTRY_SIZE)
}
