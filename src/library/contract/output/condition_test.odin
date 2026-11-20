#+build !freestanding
package output

import "core:testing"
import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/value_kinds"

// The record of these tests, "Probe", of 128 bytes: a multiple of 8, the
// alignment of its Integer of 8 bytes, as module.record_type requires; the
// last 4 bytes are in no field.
//   1 serial  an unsigned Integer of 8 bytes at 0
//   2 delta   a signed Integer of 4 bytes at 8
//   3 level   a status of Log_Level, an unsigned Integer of 1 byte at 12
//   4 target  a Text of 16 bytes at 16
//   5 lent    a Handle at 32
//   6 head    a hash, Bytes of 8 bytes at 36
//   7 label   a Text of 80 bytes at 44: longer than the text of a condition
@(private = "file")
PROBE_SIZE :: 128
@(private = "file")
PROBE_FIELDS :: 7

@(private = "file")
condition_name_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
	offset = u32(len(table))
	append(table, text)
	return offset, u32(len(text))
}

@(private = "file")
condition_field_add :: proc(fields: ^[dynamic]module.Field, table: ^[dynamic]u8, field_name: string, offset: u32, type: module.Type, detail: u32, unsigned: bool, kind: value_kinds.Field_Kind = .Plain, which: value_kinds.Contract_Enum = .None) {
	name_offset, name_count := condition_name_add(table, field_name)
	append(fields, module.Field{name_offset = name_offset, name_count = name_count, offset = offset, type = u8(type), detail = detail, unsigned = unsigned, kind = u8(kind), contract_enum = u8(which)})
}

@(private = "file")
condition_table_add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, data: []u8, count, record_size: u32) {
	for len(file) % 8 != 0 {
		append(file, 0)
	}
	directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
	append(file, ..data)
}

@(private = "file")
condition_file :: proc() -> (file: []u8, description: module.Record) {
	strings_table := make([dynamic]u8, context.temp_allocator)
	append(&strings_table, 0)
	fields := make([dynamic]module.Field, context.temp_allocator)
	append(&fields, module.Field{})
	condition_field_add(&fields, &strings_table, "serial", 0, .Integer, 8, true)
	condition_field_add(&fields, &strings_table, "delta", 8, .Integer, 4, false)
	condition_field_add(&fields, &strings_table, "level", 12, .Integer, 1, true, .Status, .Log_Level)
	condition_field_add(&fields, &strings_table, "target", 16, .Text, 16, false)
	condition_field_add(&fields, &strings_table, "lent", 32, .Handle, 0, false)
	condition_field_add(&fields, &strings_table, "head", 36, .Bytes, 8, false, .Hash)
	condition_field_add(&fields, &strings_table, "label", 44, .Text, 80, false)
	record_offset, record_count := condition_name_add(&strings_table, "Probe")
	records := [2]module.Record{{}, {name_offset = record_offset, name_count = record_count, size = PROBE_SIZE, first_field = 1, field_count = PROBE_FIELDS}}
	bytes := make([dynamic]u8, size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry), context.temp_allocator)
	directory: [module.TABLE_COUNT]module.Table_Entry
	table_add :: condition_table_add
	table_add(&bytes, &directory, .Records, ([^]u8)(&records[0])[:size_of(records)], 2, size_of(module.Record))
	table_add(&bytes, &directory, .Fields, ([^]u8)(raw_data(fields))[:len(fields) * size_of(module.Field)], u32(len(fields)), size_of(module.Field))
	table_add(&bytes, &directory, .Strings, strings_table[:], u32(len(strings_table)), 1)
	(^module.Header)(&bytes[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^[module.TABLE_COUNT]module.Table_Entry)(&bytes[size_of(module.Header)])^ = directory
	described, ok := module.record_type(bytes[:], 1)
	assert(ok, "the record of the tests is read")
	return bytes[:], described
}

@(private = "file")
terms_bytes :: proc(terms: Condition_Terms) -> [size_of(Condition_Terms)]u8 {
	return transmute([size_of(Condition_Terms)]u8)terms
}

// integer_terms and text_terms give terms that the border takes, which a
// case then breaks.
@(private = "file")
integer_terms :: proc(field: u32, comparison: Condition_Comparison, integer: i64) -> Condition_Terms {
	return {field = field, comparison = u32(comparison), value_kind = u32(Condition_Value_Kind.Integer), integer = integer}
}

@(private = "file")
text_terms :: proc(text: string, comparison: Condition_Comparison = .Equal) -> Condition_Terms {
	terms := Condition_Terms{field = 4, comparison = u32(comparison), value_kind = u32(Condition_Value_Kind.Text)}
	terms.text_count = u32(copy(terms.text[:], text))
	return terms
}

// expect_terms_refused gives terms to the border of the root service and
// checks the refusal: Bad_Value of the unit Wiring_Terms, the field of the
// terms, the word and the limit, and no condition.
@(private = "file")
expect_terms_refused :: proc(t: ^testing.T, bytes: []u8, field: Condition_Terms_Field, word: i64, limit: i64, loc := #caller_location) {
	file, description := condition_file()
	condition, refusal, ok := writer_condition_of_terms(bytes, file, description)
	testing.expectf(t, !ok, "the terms are taken: %v", condition, loc = loc)
	testing.expectf(t, condition == Writer_Condition{}, "refused terms give the condition %v", condition, loc = loc)
	expected := errors.error_make(.Bad_Value, .Wiring_Terms, i64(field), word, limit)
	testing.expectf(t, refusal == expected, "the refusal is %v, not %v", refusal, expected, loc = loc)
}

@(private = "file")
expect_refused :: proc(t: ^testing.T, terms: Condition_Terms, field: Condition_Terms_Field, word: i64, limit: i64, loc := #caller_location) {
	bytes := terms_bytes(terms)
	expect_terms_refused(t, bytes[:], field, word, limit, loc)
}

// The size of the terms: none, one byte less and one byte more.
@(test)
terms_of_another_size_are_refused :: proc(t: ^testing.T) {
	bytes: [size_of(Condition_Terms) + 1]u8
	for size in ([?]int{0, 1, size_of(Condition_Terms) - 1, size_of(Condition_Terms) + 1}) {
		expect_terms_refused(t, bytes[:size], .Whole, i64(size), size_of(Condition_Terms))
	}
}

// Each reserved word, and the field: 0, one past the fields, the largest
// word; a Handle and Bytes, which the writer does not filter.
@(test)
a_field_that_names_no_field_or_that_is_not_filtered_is_refused :: proc(t: ^testing.T) {
	for index in 0 ..< len(Condition_Terms{}.reserved) {
		terms := integer_terms(1, .Equal, 0)
		terms.reserved[index] = 1
		expect_refused(t, terms, .Reserved, 1, 0)
	}
	for field in ([?]u32{0, PROBE_FIELDS + 1, max(u32)}) {
		expect_refused(t, integer_terms(field, .Equal, 0), .Field, i64(field), PROBE_FIELDS)
	}
	expect_refused(t, integer_terms(5, .Equal, 0), .Field, 5, PROBE_FIELDS)
	expect_refused(t, integer_terms(6, .Equal, 0), .Field, 6, PROBE_FIELDS)
}

// The operator and the kind of the value: 0, one past the last member, the
// largest word; a Text for an Integer and an Integer for a Text; an order
// on a Text and on a status, which the writer does not filter.
@(test)
an_operator_or_a_value_kind_that_the_writer_does_not_filter_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u32{0, u32(max(Condition_Comparison)) + 1, max(u32)}) {
		terms := integer_terms(1, .Equal, 0)
		terms.comparison = word
		expect_refused(t, terms, .Comparison, i64(word), i64(max(Condition_Comparison)))
	}
	for word in ([?]u32{0, u32(max(Condition_Value_Kind)) + 1, max(u32)}) {
		terms := integer_terms(1, .Equal, 0)
		terms.value_kind = word
		expect_refused(t, terms, .Value_Kind, i64(word), i64(max(Condition_Value_Kind)))
	}
	text_for_integer := text_terms("x")
	text_for_integer.field = 1
	expect_refused(t, text_for_integer, .Value_Kind, i64(Condition_Value_Kind.Text), i64(Condition_Value_Kind.Integer))
	integer_for_text := integer_terms(4, .Equal, 0)
	expect_refused(t, integer_for_text, .Value_Kind, i64(Condition_Value_Kind.Integer), i64(Condition_Value_Kind.Text))
	for comparison in ([?]Condition_Comparison{.Less, .Less_Or_Equal, .Greater, .Greater_Or_Equal}) {
		expect_refused(t, text_terms("a", comparison), .Comparison, i64(comparison), i64(Condition_Comparison.Not_Equal))
		expect_refused(t, integer_terms(3, comparison, 1), .Comparison, i64(comparison), i64(Condition_Comparison.Not_Equal))
	}
}

// An Integer: a text count or a text byte beside it, a negative value for
// an unsigned field of 1 byte, and values one past the edges of a signed
// field of 4 bytes and of a status of 1 byte. An unsigned field of 8 bytes
// takes each value as its bits: -1 is 2^64 - 1, the least Integer 2^63.
@(test)
an_integer_that_the_field_cannot_hold_is_refused :: proc(t: ^testing.T) {
	with_count := integer_terms(1, .Equal, 0)
	with_count.text_count = 1
	expect_refused(t, with_count, .Text_Count, 1, 0)
	with_byte := integer_terms(1, .Equal, 0)
	with_byte.text[63] = 1
	expect_refused(t, with_byte, .Text, 63, 0)
	expect_refused(t, integer_terms(3, .Not_Equal, -1), .Integer, -1, 0)
	expect_refused(t, integer_terms(3, .Not_Equal, min(i64)), .Integer, min(i64), 0)
	file, description := condition_file()
	for value in ([?]i64{-1, min(i64)}) {
		bytes := terms_bytes(integer_terms(1, .Greater_Or_Equal, value))
		condition, refusal, ok := writer_condition_of_terms(bytes[:], file, description)
		testing.expectf(t, ok && condition.integer == value, "the bits %x of an unsigned field of 8 bytes are refused: %v", u64(value), refusal)
	}
	expect_refused(t, integer_terms(2, .Equal, i64(max(i32)) + 1), .Integer, i64(max(i32)) + 1, i64(max(i32)))
	expect_refused(t, integer_terms(2, .Equal, i64(min(i32)) - 1), .Integer, i64(min(i32)) - 1, i64(max(i32)))
	expect_refused(t, integer_terms(3, .Equal, 256), .Integer, 256, 255)
}

// A Text: an Integer beside it, a count one past the field and one past
// the most, the largest count, a byte after the count, a zero byte inside
// it, a byte that is no UTF-8 and a control character.
@(test)
a_text_that_the_field_cannot_hold_is_refused :: proc(t: ^testing.T) {
	with_integer := text_terms("a")
	with_integer.integer = 1
	expect_refused(t, with_integer, .Integer, 1, 0)
	for count in ([?]u32{17, CONDITION_TEXT_BYTES_MOST + 1, max(u32)}) {
		terms := text_terms("a")
		terms.text_count = count
		expect_refused(t, terms, .Text_Count, i64(count), 16)
	}
	after := text_terms("a")
	after.text[5] = 'b'
	expect_refused(t, after, .Text, 5, 1)
	inside := text_terms("ab")
	inside.text[0] = 0
	expect_refused(t, inside, .Text, 0, 2)
	not_utf8 := text_terms("ab")
	not_utf8.text[1] = 0xFF
	expect_refused(t, not_utf8, .Text, 1, 2)
	control := text_terms("ab")
	control.text[1] = 0x01
	expect_refused(t, control, .Text, 1, 2)
}

// The terms that the border takes, last: each operator on an unsigned and
// a signed Integer at its edges, = and != on a status and on a Text of
// 16 bytes, and the place of each field in the condition.
@(test)
the_border_takes_each_valid_condition :: proc(t: ^testing.T) {
	file, description := condition_file()
	for comparison in Condition_Comparison {
		if comparison == .None {
			continue
		}
		cases := [?]Condition_Terms{integer_terms(1, comparison, 0), integer_terms(1, comparison, max(i64)), integer_terms(2, comparison, i64(min(i32))), integer_terms(2, comparison, i64(max(i32)))}
		for terms in cases {
			bytes := terms_bytes(terms)
			condition, refusal, ok := writer_condition_of_terms(bytes[:], file, description)
			testing.expectf(t, ok, "the terms %v are refused: %v", terms, refusal)
			testing.expect_value(t, condition.comparison, u32(comparison))
		}
	}
	status := terms_bytes(integer_terms(3, .Not_Equal, 255))
	condition, _, ok := writer_condition_of_terms(status[:], file, description)
	testing.expect(t, ok && condition.offset == 12 && condition.size == 1 && condition.field_type == u32(Condition_Field_Type.Unsigned))
	text := terms_bytes(text_terms("sixteen bytes ok"))
	condition, _, ok = writer_condition_of_terms(text[:], file, description)
	testing.expect(t, ok && condition.offset == 16 && condition.size == 16 && condition.field_type == u32(Condition_Field_Type.Text) && condition.text_count == 16)
	signed := terms_bytes(integer_terms(2, .Less, -3))
	condition, _, ok = writer_condition_of_terms(signed[:], file, description)
	testing.expect(t, ok && condition.offset == 8 && condition.size == 4 && condition.field_type == u32(Condition_Field_Type.Signed) && condition.integer == -3)
}

// A Text field longer than the text of a condition takes a count of 64,
// its most, and a count of 0, the empty text; a count of 65 is refused
// with the limit 64, not the size of the field.
@(test)
a_text_field_longer_than_the_text_of_a_condition_takes_its_most :: proc(t: ^testing.T) {
	file, description := condition_file()
	long := Condition_Terms{field = 7, comparison = u32(Condition_Comparison.Equal), value_kind = u32(Condition_Value_Kind.Text), text_count = CONDITION_TEXT_BYTES_MOST}
	for &value in long.text {
		value = 'a'
	}
	bytes := terms_bytes(long)
	condition, refusal, ok := writer_condition_of_terms(bytes[:], file, description)
	testing.expectf(t, ok && condition.size == 80 && condition.text_count == CONDITION_TEXT_BYTES_MOST, "a text of 64 bytes is refused: %v", refusal)
	empty := Condition_Terms{field = 7, comparison = u32(Condition_Comparison.Not_Equal), value_kind = u32(Condition_Value_Kind.Text)}
	empty_bytes := terms_bytes(empty)
	condition, refusal, ok = writer_condition_of_terms(empty_bytes[:], file, description)
	testing.expectf(t, ok && condition.text_count == 0, "the empty text is refused: %v", refusal)
	past := long
	past.text_count = CONDITION_TEXT_BYTES_MOST + 1
	expect_refused(t, past, .Text_Count, CONDITION_TEXT_BYTES_MOST + 1, CONDITION_TEXT_BYTES_MOST)
}

// expect_each_operator checks the test of each operator for a field whose
// value is below, at and above the value of the condition.
@(private = "file")
expect_each_operator :: proc(t: ^testing.T, condition: Checked_Condition, below, at, above: []u8, loc := #caller_location) {
	Case :: struct {
		comparison:          Condition_Comparison,
		below, at, above:    bool,
	}
	cases := [?]Case {
		{.Equal, false, true, false},
		{.Not_Equal, true, false, true},
		{.Less, true, false, false},
		{.Less_Or_Equal, true, true, false},
		{.Greater, false, false, true},
		{.Greater_Or_Equal, false, true, true},
	}
	for item in cases {
		tested := condition
		tested.comparison = item.comparison
		testing.expectf(t, writer_condition_holds(tested, below) == item.below && writer_condition_holds(tested, at) == item.at && writer_condition_holds(tested, above) == item.above, "%v is wrong below, at or above the value", item.comparison, loc = loc)
	}
}

// Each operator at the value and at one below and one above it: a signed
// field of 1 byte and of 2 bytes around a negative value, an unsigned
// field of 1 byte at 0xFF and below it, an unsigned field of 8 bytes past
// 2^63, a Text full to the end of its field with no zero byte, and a text
// of 0 bytes. A condition of None passes nothing.
@(test)
each_operator_holds_at_its_edges :: proc(t: ^testing.T) {
	// A signed field of 1 byte at 0, around -128 + 1.
	signed_byte := Checked_Condition{offset = 0, size = 1, field_type = .Signed, integer = -127}
	expect_each_operator(t, signed_byte, []u8{0x80}, []u8{0x81}, []u8{0x82})
	// A signed field of 2 bytes, little-endian, around -2.
	signed_word := Checked_Condition{offset = 0, size = 2, field_type = .Signed, integer = -2}
	expect_each_operator(t, signed_word, []u8{0xFD, 0xFF}, []u8{0xFE, 0xFF}, []u8{0xFF, 0xFF})
	// An unsigned field of 1 byte, around 0xFE: 0xFF above, with no sign.
	unsigned_byte := Checked_Condition{offset = 0, size = 1, field_type = .Unsigned, integer = 0xFE}
	expect_each_operator(t, unsigned_byte, []u8{0xFD}, []u8{0xFE}, []u8{0xFF})
	// An unsigned field of 8 bytes around 2^63, which the terms give as the
	// least Integer.
	unsigned_word := Checked_Condition{offset = 0, size = 8, field_type = .Unsigned, integer = min(i64)}
	expect_each_operator(t, unsigned_word, []u8{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F}, []u8{0, 0, 0, 0, 0, 0, 0, 0x80}, []u8{1, 0, 0, 0, 0, 0, 0, 0x80})
	// A Text of 4 bytes full to its end, with no zero byte, around "abcd".
	full := Checked_Condition{offset = 0, size = 4, field_type = .Text, text_count = 4}
	copy(full.text[:], "abcd")
	expect_each_operator(t, full, transmute([]u8)string("abcc"), transmute([]u8)string("abcd"), transmute([]u8)string("abce"))
	// The empty text: no field is below it; an empty field is equal, and a
	// field with a byte is past it.
	empty := Checked_Condition{offset = 0, size = 4, field_type = .Text, text_count = 0, comparison = .Equal}
	empty_field := []u8{0, 0, 0, 0}
	full_field := []u8{'a', 0, 0, 0}
	testing.expect(t, writer_condition_holds(empty, empty_field) && !writer_condition_holds(empty, full_field))
	empty.comparison = .Less
	testing.expect(t, !writer_condition_holds(empty, empty_field) && !writer_condition_holds(empty, full_field))
	empty.comparison = .Greater
	testing.expect(t, !writer_condition_holds(empty, empty_field) && writer_condition_holds(empty, full_field))
	none := Checked_Condition{offset = 0, size = 1, field_type = .Unsigned, comparison = .None}
	testing.expect(t, !writer_condition_holds(none, []u8{0}), "a condition of None passes")
}

@(private = "file")
condition_bytes :: proc(condition: Writer_Condition) -> [size_of(Writer_Condition)]u8 {
	return transmute([size_of(Writer_Condition)]u8)condition
}

// The border of the writer refuses a page smaller than the condition, a
// reserved word, a field type or an operator that names nothing, an
// Integer of 3 bytes, a field one byte past the record, a text count past
// its field and a text byte after the count. Then the condition that it
// takes.
@(test)
the_writer_refuses_a_condition_that_its_record_cannot_hold :: proc(t: ^testing.T) {
	good := Writer_Condition{offset = 8, size = 4, field_type = u32(Condition_Field_Type.Signed), comparison = u32(Condition_Comparison.Less), integer = -3}
	bytes := condition_bytes(good)
	_, ok := writer_condition_check(bytes[:size_of(Writer_Condition) - 1], PROBE_SIZE)
	testing.expect(t, !ok, "a short page is taken")
	changes := [?]proc(condition: ^Writer_Condition){
		proc(condition: ^Writer_Condition) {condition.reserved_0 = 1},
		proc(condition: ^Writer_Condition) {condition.reserved[7] = 1},
		proc(condition: ^Writer_Condition) {condition.field_type = 0},
		proc(condition: ^Writer_Condition) {condition.field_type = u32(max(Condition_Field_Type)) + 1},
		proc(condition: ^Writer_Condition) {condition.comparison = 0},
		proc(condition: ^Writer_Condition) {condition.comparison = max(u32)},
		proc(condition: ^Writer_Condition) {condition.size = 3},
		proc(condition: ^Writer_Condition) {condition.size = 0},
		proc(condition: ^Writer_Condition) {condition.offset = PROBE_SIZE - 3},
		proc(condition: ^Writer_Condition) {condition.offset = max(u32)},
		proc(condition: ^Writer_Condition) {condition.text_count = 1},
		proc(condition: ^Writer_Condition) {condition.field_type, condition.offset, condition.size, condition.text_count = u32(Condition_Field_Type.Text), 16, 4, 5},
		proc(condition: ^Writer_Condition) {condition.field_type, condition.offset, condition.size, condition.text_count, condition.text[2] = u32(Condition_Field_Type.Text), 16, 16, 1, 'x'},
	}
	for change, index in changes {
		broken := good
		change(&broken)
		broken_bytes := condition_bytes(broken)
		_, broken_ok := writer_condition_check(broken_bytes[:], PROBE_SIZE)
		testing.expectf(t, !broken_ok, "the change %d is taken", index)
	}
	checked, checked_ok := writer_condition_check(bytes[:], PROBE_SIZE)
	testing.expect(t, checked_ok && checked.field_type == .Signed && checked.comparison == .Less && checked.integer == -3)
}

// The test of a condition: a record too short passes nothing; a signed
// field compares with its sign, an unsigned one of 8 bytes as unsigned,
// a Text by its bytes up to its first zero byte, a prefix is not equal.
@(test)
a_condition_holds_by_the_value_of_its_field :: proc(t: ^testing.T) {
	record: [PROBE_SIZE]u8
	// delta = -5, serial = max(u64), target = "abc".
	for index in 0 ..< 8 {
		record[index] = 0xFF
	}
	record[8], record[9], record[10], record[11] = 0xFB, 0xFF, 0xFF, 0xFF
	copy(record[16:], "abc")
	less := Checked_Condition{offset = 8, size = 4, field_type = .Signed, comparison = .Less, integer = -3}
	testing.expect(t, !writer_condition_holds(less, record[:11]), "a record too short passes")
	testing.expect(t, writer_condition_holds(less, record[:]))
	less.integer = -5
	testing.expect(t, !writer_condition_holds(less, record[:]))
	greater := Checked_Condition{offset = 0, size = 8, field_type = .Unsigned, comparison = .Greater, integer = 1}
	testing.expect(t, writer_condition_holds(greater, record[:]), "the largest unsigned value is not greater than 1")
	equal := Checked_Condition{offset = 16, size = 16, field_type = .Text, comparison = .Equal, text_count = 3}
	copy(equal.text[:], "abc")
	testing.expect(t, writer_condition_holds(equal, record[:]))
	equal.text_count = 2
	testing.expect(t, !writer_condition_holds(equal, record[:]), "a prefix is equal")
	equal.comparison = .Not_Equal
	testing.expect(t, writer_condition_holds(equal, record[:]))
}

// The counts go into the head page of a ring and come back as they were;
// the counters of the queue keep their values.
@(test)
the_counts_of_the_writer_go_through_the_head_page :: proc(t: ^testing.T) {
	head: [512]u64
	head[0] = 7
	writer_counts_write(&head[0], {written = 3, discarded = max(u64), refused = 1, held = 5, rings_past_gap = 2})
	counts := writer_counts_read(&head[0])
	testing.expect(t, counts.written == 3 && counts.discarded == max(u64) && counts.refused == 1 && counts.held == 5 && counts.rings_past_gap == 2)
	testing.expect_value(t, head[0], 7)
	// The reserved words are written by no one: they read back as 0.
	testing.expect_value(t, counts.reserved, [3]u64{})
	words := (^[8]u64)(rawptr(uintptr(&head[0]) + WRITER_COUNTS_OFFSET))
	for index in 5 ..< 8 {
		testing.expect_value(t, words[index], 0)
	}
}

// A filtered ring takes a serial that moves forward by less than 2^31, and
// refuses one behind and one 2^31 ahead; a ring with no condition takes
// the next serial only.
@(test)
a_filtered_ring_takes_a_serial_that_moves_forward :: proc(t: ^testing.T) {
	state := Read_State{joined = true, next_serial = 10}
	testing.expect(t, serial_follows(&state, 10) && !serial_follows(&state, 11) && !serial_follows(&state, 9))
	state.filtered = true
	testing.expect(t, serial_follows(&state, 10) && serial_follows(&state, 11) && serial_follows(&state, 10 + SERIAL_FORWARD_MOST - 1))
	testing.expect(t, !serial_follows(&state, 9) && !serial_follows(&state, 10 + SERIAL_FORWARD_MOST))
	state.next_serial = max(u32)
	testing.expect(t, serial_follows(&state, 0), "the serial does not wrap")
	// The edges of the half: from 0, 2^31 - 1 ahead is taken and 2^31 is
	// not; from 2^31, 0 is 2^31 ahead and is refused; from the largest
	// serial, 2^31 - 1 ahead wraps and is taken.
	state.next_serial = 0
	testing.expect(t, serial_follows(&state, SERIAL_FORWARD_MOST - 1) && !serial_follows(&state, SERIAL_FORWARD_MOST))
	state.next_serial = SERIAL_FORWARD_MOST
	testing.expect(t, !serial_follows(&state, 0) && serial_follows(&state, SERIAL_FORWARD_MOST))
	// Variables: the sums wrap when the test runs, as the serials do.
	largest, half := max(u32), SERIAL_FORWARD_MOST
	state.next_serial = largest
	testing.expect(t, serial_follows(&state, largest + (half - 1)) && !serial_follows(&state, largest + half))
}

// What one ring does in the decision of a write: a ring that skips the
// record holds nothing, full as it may be, whatever its pace; the others
// as their room and their pace say. A write that every ring skips, beside
// a full ring of the pace Always_Holds_Writer, writes at once and counts a
// discarded record.
@(test)
a_ring_that_skips_the_record_holds_nothing :: proc(t: ^testing.T) {
	for pace in Wiring_Pace {
		for room in Ring_Room {
			testing.expect_value(t, ring_part_of(true, room, pace), Ring_Part.Skipped)
		}
	}
	testing.expect_value(t, ring_part_of(false, .Room, .Always_Holds_Writer), Ring_Part.Takes)
	testing.expect_value(t, ring_part_of(false, .Holds, .Always_Holds_Writer), Ring_Part.Holds_Always)
	testing.expect_value(t, ring_part_of(false, .Holds, .Writer_Chooses), Ring_Part.Holds_By_Choice)
	testing.expect_value(t, ring_part_of(false, .Refuses, .Never_Holds_Writer), Ring_Part.Refuses)
	testing.expect_value(t, ring_part_of(false, .Broken, .Writer_Chooses), Ring_Part.Broken)
	// Every ring skips: none holds, so the write writes, with no wait.
	part := ring_part_of(true, .Holds, .Always_Holds_Writer)
	testing.expect_value(t, write_step_of(part == .Holds_By_Choice, part == .Holds_Always, false), Write_Step.Write)
	before := Writer_Counts{written = 7, discarded = 2, refused = 1}
	after := counts_after_write(before, false)
	testing.expect(t, after.written == 7 && after.discarded == 3 && after.refused == 1)
	after = counts_after_write(before, true)
	testing.expect(t, after.written == 8 && after.discarded == 2 && after.refused == 1)
}
