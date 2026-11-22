#+build !freestanding
package output

import "core:testing"
import "modus:contract/errors"
import "modus:contract/module"

// The rows of these tests have two lent handles, and their terms start
// after a list of three rows and two handles.
@(private = "file")
HANDLE_COUNT :: 2
@(private = "file")
TERMS_START :: size_of(Wiring_List_Head) + 3 * size_of(Wiring) + HANDLE_COUNT * size_of(u32)
@(private = "file")
LIST_SIZE :: TERMS_START + 64

// A row that the border takes: a Started writer of its record output 1 to
// a Started reader of its record input 1.
@(private = "file")
good_row :: proc() -> Wiring {
	return {writer_end = u32(Wiring_End.Started), writer_handle = 1, writer_stream = u32(Writer_Stream.Record_Output), writer_index = 1, reader_end = u32(Wiring_End.Started), reader_handle = 2, reader_index = 1}
}

// expect_row_refused checks that a row is refused with Bad_Value of the
// unit Wiring_Rows, its field, its word and its number, and gives no row.
@(private = "file")
expect_row_refused :: proc(t: ^testing.T, row: Wiring, form: Wiring_List_Form, field: Wiring_Field, word: u64, loc := #caller_location) {
	checked, refusal, ok := wiring_row_check(row, 3, form, HANDLE_COUNT, TERMS_START, LIST_SIZE)
	testing.expectf(t, !ok, "the row %v is taken", row, loc = loc)
	testing.expectf(t, checked == Checked_Wiring{}, "a refused row gives %v", checked, loc = loc)
	testing.expectf(t, refusal.kind == i64(errors.Kind.Bad_Value) && refusal.unit == i64(errors.Unit.Wiring_Rows), "the refusal is %v", refusal, loc = loc)
	testing.expectf(t, refusal.argument == i64(field) && refusal.value == i64(min(word, 1 << 62)) && refusal.found == 3, "the refusal %v does not name the field %v, the word %d and the row 3", refusal, field, word, loc = loc)
}

// The end of the writer: 0, a word past the last member and the largest
// word name none; the asker never writes; a Wire has no child.
@(test)
a_writer_end_that_names_no_writer_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u32{0, u32(Wiring_End.Asker), u32(max(Wiring_End)) + 1, max(u32)}) {
		row := good_row()
		row.writer_end = word
		expect_row_refused(t, row, .Start, .Writer_End, u64(word))
	}
	row := good_row()
	row.writer_end, row.writer_handle = u32(Wiring_End.Child), 0
	expect_row_refused(t, row, .Wire, .Writer_End, u64(Wiring_End.Child))
}

// The handle places: 0 and one past the lent handles for a lent end, and a
// place for the child, which needs none.
@(test)
a_handle_place_out_of_the_lent_handles_is_refused :: proc(t: ^testing.T) {
	for place in ([?]u32{0, HANDLE_COUNT + 1, max(u32)}) {
		row := good_row()
		row.writer_handle = place
		expect_row_refused(t, row, .Start, .Writer_Handle, u64(place))
		row = good_row()
		row.reader_handle = place
		expect_row_refused(t, row, .Start, .Reader_Handle, u64(place))
	}
	row := good_row()
	row.writer_end = u32(Wiring_End.Child)
	expect_row_refused(t, row, .Start, .Writer_Handle, 1)
	row = good_row()
	row.reader_end = u32(Wiring_End.Asker)
	row.reader_index = 0
	expect_row_refused(t, row, .Start, .Reader_Handle, 2)
	// One lent handle at both ends is one process at both ends.
	row = good_row()
	row.reader_handle = 1
	expect_row_refused(t, row, .Start, .Reader_Handle, 1)
	// A connection is named by a number that is not 0, at each end; one
	// connection at both ends is one process at both ends.
	row = good_row()
	row.writer_end, row.writer_handle = u32(Wiring_End.Connected), 0
	expect_row_refused(t, row, .Wire, .Writer_Handle, 0)
	row = good_row()
	row.reader_end, row.reader_handle = u32(Wiring_End.Connected), 0
	expect_row_refused(t, row, .Wire, .Reader_Handle, 0)
	row = good_row()
	row.writer_end, row.writer_handle = u32(Wiring_End.Connected), max(u32)
	row.reader_end, row.reader_handle = u32(Wiring_End.Connected), max(u32)
	expect_row_refused(t, row, .Wire, .Reader_Handle, u64(max(u32)))
}

// The number of a connection is no place of the lent handles: one past
// the lent handles and the largest word are taken, and a number equal to
// the place of a Started end at the other end is no repeat, as the two
// name different things.
@(test)
a_connection_number_is_not_a_place_of_the_lent_handles :: proc(t: ^testing.T) {
	for number in ([?]u32{1, HANDLE_COUNT + 1, max(u32)}) {
		row := good_row()
		row.writer_end, row.writer_handle = u32(Wiring_End.Connected), number
		row.reader_handle = 1
		checked, refusal, ok := wiring_row_check(row, 1, .Wire, HANDLE_COUNT, TERMS_START, LIST_SIZE)
		testing.expectf(t, ok, "the connection number %d is refused: %v", number, refusal)
		testing.expect_value(t, checked.writer_handle, number)
		testing.expect_value(t, checked.writer_end, Wiring_End.Connected)
	}
}

// What the writer writes: 0 and words past the members; the log of a
// process that is not the child; an index for the log, and an index of 0 or
// past 16 bits for a record output.
@(test)
a_writer_stream_or_index_that_names_nothing_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u32{0, u32(max(Writer_Stream)) + 1, max(u32)}) {
		row := good_row()
		row.writer_stream = word
		expect_row_refused(t, row, .Start, .Writer_Stream, u64(word))
	}
	row := good_row()
	row.writer_stream, row.writer_index = u32(Writer_Stream.Log), 0
	expect_row_refused(t, row, .Start, .Writer_Stream, u64(Writer_Stream.Log))
	row = good_row()
	row.writer_end, row.writer_handle, row.writer_stream = u32(Wiring_End.Child), 0, u32(Writer_Stream.Log)
	expect_row_refused(t, row, .Start, .Writer_Index, 1)
	for index in ([?]u32{0, module.RECORD_STREAM_INDEX_MOST + 1, max(u32)}) {
		row = good_row()
		row.writer_index = index
		expect_row_refused(t, row, .Start, .Writer_Index, u64(index))
		row = good_row()
		row.reader_index = index
		expect_row_refused(t, row, .Start, .Reader_Index, u64(index))
	}
}

// The end of the reader: 0 and words past the members; the child in a
// Wire; the child at both ends; an index for the asker, which declares no
// record input.
@(test)
a_reader_end_that_names_no_reader_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u32{0, u32(max(Wiring_End)) + 1, max(u32)}) {
		row := good_row()
		row.reader_end = word
		expect_row_refused(t, row, .Start, .Reader_End, u64(word))
	}
	row := good_row()
	row.reader_end, row.reader_handle = u32(Wiring_End.Child), 0
	expect_row_refused(t, row, .Wire, .Reader_End, u64(Wiring_End.Child))
	row = good_row()
	row.writer_end, row.writer_handle = u32(Wiring_End.Child), 0
	row.reader_end, row.reader_handle = u32(Wiring_End.Child), 0
	expect_row_refused(t, row, .Start, .Reader_End, u64(Wiring_End.Child))
	row = good_row()
	row.reader_end, row.reader_handle = u32(Wiring_End.Asker), 0
	expect_row_refused(t, row, .Start, .Reader_Index, 1)
}

// The pace: one past the last member and the largest word. The capacity:
// below the least, between two powers of two, one past the most, the
// largest word.
@(test)
a_pace_or_capacity_out_of_its_range_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u32{u32(max(Wiring_Pace)) + 1, max(u32)}) {
		row := good_row()
		row.pace = word
		expect_row_refused(t, row, .Start, .Pace, u64(word))
	}
	for capacity in ([?]u32{1, WIRING_CAPACITY_LEAST / 2, WIRING_CAPACITY_LEAST - 1, WIRING_CAPACITY_LEAST + 1, 48, WIRING_CAPACITY_MOST + 1, WIRING_CAPACITY_MOST * 2, max(u32)}) {
		row := good_row()
		row.capacity = capacity
		expect_row_refused(t, row, .Start, .Capacity, u64(capacity))
	}
}

// The terms: an offset with no count and a count with no offset; a count
// past the largest record; terms over the lent handles, past the list, at
// the largest offset; terms for the asker, which takes none.
@(test)
wiring_terms_out_of_their_place_are_refused :: proc(t: ^testing.T) {
	row := good_row()
	row.terms_count = 8
	expect_row_refused(t, row, .Start, .Terms_Offset, 0)
	row = good_row()
	row.terms_offset = TERMS_START
	expect_row_refused(t, row, .Start, .Terms_Count, 0)
	row = good_row()
	row.terms_offset, row.terms_count = TERMS_START, module.RECORD_SIZE_LIMIT + 1
	expect_row_refused(t, row, .Start, .Terms_Count, module.RECORD_SIZE_LIMIT + 1)
	row = good_row()
	row.terms_offset, row.terms_count = TERMS_START - 1, 8
	expect_row_refused(t, row, .Start, .Terms_Offset, TERMS_START - 1)
	row = good_row()
	row.terms_offset, row.terms_count = LIST_SIZE - 7, 8
	expect_row_refused(t, row, .Start, .Terms_Offset, LIST_SIZE - 7)
	row = good_row()
	row.terms_offset, row.terms_count = max(u32), 8
	expect_row_refused(t, row, .Start, .Terms_Offset, u64(max(u32)))
	row = good_row()
	row.reader_end, row.reader_handle, row.reader_index = u32(Wiring_End.Asker), 0, 0
	row.terms_offset, row.terms_count = TERMS_START, 8
	expect_row_refused(t, row, .Start, .Terms_Count, 8)
}

// The condition: an offset with no count and a count with no offset; a
// count of one byte less and one byte more than its terms, and the largest
// count; a condition over the lent handles, one that ends one byte past the
// list, and the largest offset. Then a condition that ends at the last
// byte of the list, beside an asker reader, which a condition serves too.
@(private = "file")
CONDITION_LIST_SIZE :: TERMS_START + size_of(Condition_Terms)

@(private = "file")
expect_condition_refused :: proc(t: ^testing.T, row: Wiring, field: Wiring_Field, word: u64, loc := #caller_location) {
	checked, refusal, ok := wiring_row_check(row, 3, .Start, HANDLE_COUNT, TERMS_START, CONDITION_LIST_SIZE)
	testing.expectf(t, !ok && checked == Checked_Wiring{}, "the row %v is taken", row, loc = loc)
	testing.expectf(t, refusal.kind == i64(errors.Kind.Bad_Value) && refusal.unit == i64(errors.Unit.Wiring_Rows) && refusal.argument == i64(field) && refusal.value == i64(min(word, 1 << 62)) && refusal.found == 3, "the refusal is %v", refusal, loc = loc)
}

@(test)
a_condition_out_of_its_place_or_of_another_size_is_refused :: proc(t: ^testing.T) {
	refused :: expect_condition_refused
	list_size :: CONDITION_LIST_SIZE
	row := good_row()
	row.condition_count = size_of(Condition_Terms)
	refused(t, row, .Condition_Offset, 0)
	row = good_row()
	row.condition_offset = TERMS_START
	refused(t, row, .Condition_Count, 0)
	for count in ([?]u32{size_of(Condition_Terms) - 1, size_of(Condition_Terms) + 1, max(u32)}) {
		row = good_row()
		row.condition_offset, row.condition_count = TERMS_START, count
		refused(t, row, .Condition_Count, u64(count))
	}
	for offset in ([?]u32{TERMS_START - 1, TERMS_START + 1, max(u32)}) {
		row = good_row()
		row.condition_offset, row.condition_count = offset, size_of(Condition_Terms)
		refused(t, row, .Condition_Offset, u64(offset))
	}
	row = good_row()
	row.reader_end, row.reader_handle, row.reader_index = u32(Wiring_End.Asker), 0, 0
	row.condition_offset, row.condition_count = TERMS_START, size_of(Condition_Terms)
	checked, refusal, ok := wiring_row_check(row, 1, .Wire, HANDLE_COUNT, TERMS_START, list_size)
	testing.expectf(t, ok, "the condition at the end of the list is refused: %v", refusal)
	testing.expect_value(t, checked.condition_offset, u32(TERMS_START))
}

// The paired row of the row 3: the row itself, a later row and the
// largest word are no earlier row, and the record output `log` of the
// child pairs with nothing. The rows 1 and 2 are taken last, and the
// paired row comes through the border.
@(test)
a_paired_row_that_is_no_earlier_row_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u32{3, 4, max(u32)}) {
		row := good_row()
		row.paired_row = word
		expect_row_refused(t, row, .Start, .Paired_Row, u64(word))
	}
	log_row := good_row()
	log_row.writer_end, log_row.writer_handle, log_row.writer_stream, log_row.writer_index = u32(Wiring_End.Child), 0, u32(Writer_Stream.Log), 0
	log_row.paired_row = 1
	expect_row_refused(t, log_row, .Start, .Paired_Row, 1)
	// A Wire has one row: no row comes before it.
	wire_row := good_row()
	wire_row.paired_row = 1
	_, wire_refusal, wire_ok := wiring_row_check(wire_row, 1, .Wire, HANDLE_COUNT, TERMS_START, LIST_SIZE)
	testing.expect(t, !wire_ok)
	testing.expect_value(t, wire_refusal.argument, i64(Wiring_Field.Paired_Row))
	for word in ([?]u32{1, 2}) {
		row := good_row()
		row.paired_row = word
		checked, refusal, ok := wiring_row_check(row, 3, .Start, HANDLE_COUNT, TERMS_START, LIST_SIZE)
		testing.expectf(t, ok, "the paired row %d is refused: %v", word, refusal)
		testing.expect_value(t, checked.paired_row, word)
	}
}

// Each reserved word: 1 and the largest word.
@(test)
a_reserved_word_of_a_row_that_is_not_zero_is_refused :: proc(t: ^testing.T) {
	for index in 0 ..< len(Wiring{}.reserved) {
		for word in ([?]u32{1, max(u32)}) {
			row := good_row()
			row.reserved[index] = word
			expect_row_refused(t, row, .Start, .Reserved, u64(word))
		}
	}
}

// The rows that the border takes, last: the defaults, the edges of each
// range, the child at one end, the log of the child, the asker as the
// reader, and terms that end at the last byte of the list.
@(test)
the_border_takes_each_valid_row :: proc(t: ^testing.T) {
	Case :: struct {
		row:      Wiring,
		form:     Wiring_List_Form,
		capacity: u32,
	}
	cases := make([dynamic]Case, context.temp_allocator)
	append(&cases, Case{good_row(), .Wire, WIRING_CAPACITY_DEFAULT})
	edges := good_row()
	edges.writer_handle, edges.reader_handle = HANDLE_COUNT, 1
	edges.writer_index, edges.reader_index = module.RECORD_STREAM_INDEX_MOST, module.RECORD_STREAM_INDEX_MOST
	edges.pace, edges.capacity = u32(max(Wiring_Pace)), WIRING_CAPACITY_MOST
	edges.terms_offset, edges.terms_count = LIST_SIZE - 8, 8
	append(&cases, Case{edges, .Start, WIRING_CAPACITY_MOST})
	least := good_row()
	least.capacity = WIRING_CAPACITY_LEAST
	least.writer_end, least.writer_handle = u32(Wiring_End.Connected), HANDLE_COUNT + 1
	append(&cases, Case{least, .Wire, WIRING_CAPACITY_LEAST})
	log := good_row()
	log.writer_end, log.writer_handle, log.writer_stream, log.writer_index = u32(Wiring_End.Child), 0, u32(Writer_Stream.Log), 0
	append(&cases, Case{log, .Start, WIRING_CAPACITY_DEFAULT})
	asker := good_row()
	asker.reader_end, asker.reader_handle, asker.reader_index = u32(Wiring_End.Asker), 0, 0
	append(&cases, Case{asker, .Wire, WIRING_CAPACITY_DEFAULT})
	child_reader := good_row()
	child_reader.reader_end, child_reader.reader_handle = u32(Wiring_End.Child), 0
	append(&cases, Case{child_reader, .Start, WIRING_CAPACITY_DEFAULT})
	for item in cases {
		checked, refusal, ok := wiring_row_check(item.row, 1, item.form, HANDLE_COUNT, TERMS_START, LIST_SIZE)
		testing.expectf(t, ok, "the row %v is refused: %v", item.row, refusal)
		testing.expect_value(t, checked.capacity, item.capacity)
		testing.expect_value(t, u32(checked.writer_end), item.row.writer_end)
		testing.expect_value(t, u32(checked.reader_end), item.row.reader_end)
		testing.expect_value(t, checked.writer_index, item.row.writer_index)
		testing.expect_value(t, checked.reader_index, item.row.reader_index)
		testing.expect_value(t, checked.terms_offset, item.row.terms_offset)
		testing.expect_value(t, checked.terms_count, item.row.terms_count)
	}
}

// list_bytes gives the memory of a list of rows and handles, of size bytes.
@(private = "file")
list_bytes :: proc(rows: []Wiring, handles: []u32, size: int = LIST_SIZE) -> []u8 {
	bytes := make([]u8, size, context.temp_allocator)
	assert(wiring_list_write(bytes, rows, handles))
	return bytes
}

@(private = "file")
expect_list_refused :: proc(t: ^testing.T, bytes: []u8, form: Wiring_List_Form, unit: errors.Unit, found: i64, loc := #caller_location) {
	list: Checked_Wiring_List
	list.row_count = 99
	refusal, ok := wiring_list_check(bytes, form, &list)
	testing.expectf(t, !ok, "the list is taken", loc = loc)
	testing.expectf(t, list.row_count == 0 && list.handle_count == 0 && list.rows[0] == Checked_Wiring{}, "a refused list holds rows", loc = loc)
	testing.expectf(t, refusal.unit == i64(unit) && refusal.found == found, "the refusal %v is not of the unit %v and the row %d", refusal, unit, found, loc = loc)
}

// The list as a whole: its size, its head, its counts.
@(test)
a_list_out_of_its_bounds_is_refused :: proc(t: ^testing.T) {
	handles := [HANDLE_COUNT]u32{5, 6}
	rows := [1]Wiring{good_row()}
	expect_list_refused(t, nil, .Start, .Wiring_Rows, 0)
	expect_list_refused(t, make([]u8, size_of(Wiring_List_Head) - 1, context.temp_allocator), .Start, .Wiring_Rows, 0)
	expect_list_refused(t, make([]u8, WIRING_LIST_BYTES_MOST + 1, context.temp_allocator), .Start, .Wiring_Rows, 0)
	// A reserved word of the head.
	bytes := list_bytes(rows[:], handles[:])
	bytes[size_of(u32) * 2] = 1
	expect_list_refused(t, bytes, .Start, .Wiring_Rows, 0)
	// No row; past the rows of a list; two rows in a Wire.
	expect_list_refused(t, list_bytes(nil, handles[:]), .Start, .Wiring_Rows, 0)
	too_many := make([]u8, WIRING_LIST_BYTES_MOST, context.temp_allocator)
	(^Wiring_List_Head)(raw_data(too_many)).row_count = WIRING_LIST_ROW_LIMIT + 1
	expect_list_refused(t, too_many, .Start, .Wiring_Rows, 0)
	two := [2]Wiring{good_row(), good_row()}
	expect_list_refused(t, list_bytes(two[:], handles[:]), .Wire, .Wiring_Rows, 0)
	// Past the lent handles of a list.
	past_handles := list_bytes(rows[:], handles[:])
	(^Wiring_List_Head)(raw_data(past_handles)).handle_count = WIRING_LIST_HANDLE_LIMIT + 1
	expect_list_refused(t, past_handles, .Start, .Lent_Handles, 0)
	// The handles past the bytes of the copy: the head and one row fit, and
	// the head names two handles after them.
	short := list_bytes(rows[:], nil, size_of(Wiring_List_Head) + size_of(Wiring))
	(^Wiring_List_Head)(raw_data(short)).handle_count = HANDLE_COUNT
	expect_list_refused(t, short, .Start, .Bytes, 0)
}

// A refused row refuses the list with its number; two rows of the log of
// the child refuse the second.
@(test)
a_list_with_a_refused_row_is_refused_with_its_number :: proc(t: ^testing.T) {
	handles := [HANDLE_COUNT]u32{5, 6}
	bad := good_row()
	bad.pace = u32(max(Wiring_Pace)) + 1
	rows := [3]Wiring{good_row(), bad, good_row()}
	expect_list_refused(t, list_bytes(rows[:], handles[:]), .Start, .Wiring_Rows, 2)
	log := good_row()
	log.writer_end, log.writer_handle, log.writer_stream, log.writer_index = u32(Wiring_End.Child), 0, u32(Writer_Stream.Log), 0
	logs := [3]Wiring{log, good_row(), log}
	expect_list_refused(t, list_bytes(logs[:], handles[:]), .Start, .Wiring_Rows, 3)
}

// One handle number in two places of the lent handles is refused: next to
// each other, and the last place repeating the first.
@(test)
a_repeated_lent_handle_is_refused :: proc(t: ^testing.T) {
	rows := [1]Wiring{good_row()}
	for handles in ([?][3]u32{{5, 5, 6}, {5, 6, 5}, {max(u32), 1, max(u32)}}) {
		copied := handles
		bytes := list_bytes(rows[:], copied[:])
		list: Checked_Wiring_List
		refusal, ok := wiring_list_check(bytes, .Start, &list)
		testing.expectf(t, !ok, "the handles %v are taken", handles)
		testing.expect(t, refusal.unit == i64(errors.Unit.Lent_Handles) && refusal.kind == i64(errors.Kind.Bad_Value))
		testing.expect(t, list.row_count == 0 && list.handle_count == 0)
	}
}

// The lists that the border takes, last: a Wire of one row, and a Start of
// three rows with its handles and terms at the end of the list.
@(test)
the_border_takes_a_whole_list :: proc(t: ^testing.T) {
	handles := [HANDLE_COUNT]u32{5, max(u32)}
	one := [1]Wiring{good_row()}
	list: Checked_Wiring_List
	refusal, ok := wiring_list_check(list_bytes(one[:], handles[:]), .Wire, &list)
	testing.expectf(t, ok, "the Wire is refused: %v", refusal)
	testing.expect_value(t, list.row_count, 1)
	testing.expect_value(t, list.handle_count, HANDLE_COUNT)
	testing.expect_value(t, list.handles[1], max(u32))

	child := good_row()
	child.writer_end, child.writer_handle = u32(Wiring_End.Child), 0
	child.terms_offset, child.terms_count = LIST_SIZE - 16, 16
	rows := [3]Wiring{good_row(), child, good_row()}
	refusal, ok = wiring_list_check(list_bytes(rows[:], handles[:]), .Start, &list)
	testing.expectf(t, ok, "the Start is refused: %v", refusal)
	testing.expect_value(t, list.row_count, 3)
	testing.expect_value(t, list.rows[1].writer_end, Wiring_End.Child)
	testing.expect_value(t, list.rows[1].terms_count, 16)
	testing.expect_value(t, list.handles[0], 5)
	testing.expect_value(t, wiring_terms_start(3, HANDLE_COUNT), TERMS_START)
}
