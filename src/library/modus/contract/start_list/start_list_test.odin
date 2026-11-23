#+build !freestanding
package start_list

import "base:intrinsics"
import "core:testing"
import "modus:contract/errors"
import "modus:contract/memory_screen"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/wide_grants"

// A list of three start rows that the border takes, and its bytes, for the
// cases that change one field.
@(private = "file")
three_rows :: proc() -> (rows: [3]Start_Row, bytes: []u8) {
	first, first_made := row_make("input", {.Screen}, .Not_Started, .Not_Needed)
	second, second_made := row_make("console", {.Screen}, .Not_Started, .Needed, 2, 60)
	third, third_made := row_make("date", {}, .Started_Anyway, .Not_Needed, RESTART_LIMIT, max(u32))
	assert(first_made && second_made && third_made)
	rows = {first, second, third}
	bytes = make([]u8, list_size(3), context.temp_allocator)
	_, written := list_write(rows[:], nil, bytes)
	assert(written)
	return
}

// A wiring row of the record output index writer_index of the writer row
// writer (from 1) to the record input reader_index of the reader row reader
// (from 1).
@(private = "file")
wiring_row :: proc(writer: u32, writer_index: u32, reader: u32, reader_index: u32) -> Wiring_Row_Record {
	return {writer_row = writer, wiring = {writer_end = u32(output.Wiring_End.Child), writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = writer_index, reader_end = u32(output.Wiring_End.Started), reader_handle = reader, reader_index = reader_index}}
}

// The row of the record output log of the writer row writer.
@(private = "file")
log_row :: proc(writer: u32, reader: u32, reader_index: u32) -> Wiring_Row_Record {
	return {writer_row = writer, wiring = {writer_end = u32(output.Wiring_End.Child), writer_stream = u32(output.Writer_Stream.Log), reader_end = u32(output.Wiring_End.Started), reader_handle = reader, reader_index = reader_index}}
}

// A list that the border takes: two readers, then a writer whose three
// wiring rows go to them, the log among them, then a writer with none.
@(private = "file")
wired_rows :: proc() -> (rows: [4]Start_Row, wirings: [3]Wiring_Row_Record, bytes: []u8) {
	names := [4]string{"reader_one", "reader_two", "writer", "lone"}
	for name, index in names {
		made: bool
		rows[index], made = row_make(name, {}, .Not_Started, .Not_Needed)
		assert(made)
	}
	wirings = {wiring_row(3, 1, 1, 1), wiring_row(3, 2, 2, 1), log_row(3, 1, 2)}
	bytes = make([]u8, list_size(4, 3), context.temp_allocator)
	_, written := list_write(rows[:], wirings[:], bytes, 1)
	assert(written)
	return
}

// record_change copies the bytes of a list, changes one start row with
// change, and gives the copy.
@(private = "file")
record_change :: proc(bytes: []u8, row: int, change: proc(record: ^Row_Record)) -> []u8 {
	changed := make([]u8, len(bytes), context.temp_allocator)
	copy(changed, bytes)
	record: Row_Record
	place := size_of(List_Header) + row * size_of(Row_Record)
	intrinsics.mem_copy_non_overlapping(&record, &changed[place], size_of(Row_Record))
	change(&record)
	intrinsics.mem_copy_non_overlapping(&changed[place], &record, size_of(Row_Record))
	return changed
}

// wiring_change copies the bytes of a list of row_count start rows, sets
// its wiring row index to record, and gives the copy.
@(private = "file")
wiring_change :: proc(bytes: []u8, row_count: int, index: int, record: Wiring_Row_Record) -> []u8 {
	changed := make([]u8, len(bytes), context.temp_allocator)
	copy(changed, bytes)
	written := record
	intrinsics.mem_copy_non_overlapping(&changed[list_size(row_count) + index * size_of(Wiring_Row_Record)], &written, size_of(Wiring_Row_Record))
	return changed
}

// header_change copies the bytes of a list, changes its header, and gives
// the copy.
@(private = "file")
header_change :: proc(bytes: []u8, change: proc(header: ^List_Header)) -> []u8 {
	changed := make([]u8, len(bytes), context.temp_allocator)
	copy(changed, bytes)
	header: List_Header
	intrinsics.mem_copy_non_overlapping(&header, &changed[0], size_of(List_Header))
	change(&header)
	intrinsics.mem_copy_non_overlapping(&changed[0], &header, size_of(List_Header))
	return changed
}

// expect_refused reads bytes into a list that holds rows already and checks
// the refusal: its problem, its place, its error record, and a list with no
// row left.
@(private = "file")
expect_refused :: proc(t: ^testing.T, bytes: []u8, problem: List_Problem, place: int, refusal: errors.Error_Record = {}, loc := #caller_location) {
	list: List
	_, _, before := wired_rows()
	_, _, _ = list_read(before, &list, rows_place(before))
	assert(list.row_count == 4)
	read_problem, read_place, read_refusal := list_read(bytes, &list, rows_place(bytes))
	testing.expect_value(t, read_problem, problem, loc = loc)
	testing.expect_value(t, read_place, place, loc = loc)
	testing.expect_value(t, read_refusal, refusal, loc = loc)
	testing.expect_value(t, list.row_count, 0, loc = loc)
	testing.expect_value(t, list.wiring_count, 0, loc = loc)
	testing.expect_value(t, list.wiring_pages, u64(0), loc = loc)
}

// rows_place gives the place of the wiring rows of bytes, sized as a reader
// of the list sizes it (list_wiring_count).
@(private = "file")
rows_place :: proc(bytes: []u8) -> []Wiring_Row {
	return make([]Wiring_Row, list_wiring_count(bytes), context.temp_allocator)
}

// The header: no byte, one byte short of the header, another magic,
// version 0, the version before this one, one past the version, a reserved
// word, no row, one row past the capacity, the largest count, one wiring
// row past its capacity and the largest count, the rows that the header
// counts with one byte missing, and one byte after the rows. Each is
// refused whole.
@(test)
a_list_with_a_wrong_header_is_refused :: proc(t: ^testing.T) {
	_, bytes := three_rows()
	expect_refused(t, {}, .Too_Short, 0)
	expect_refused(t, bytes[:size_of(List_Header) - 1], .Too_Short, 0)
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.magic = LIST_MAGIC + 1}), .Wrong_Magic, 0)
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.version = 0}), .Wrong_Version, 0)
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.version = LIST_VERSION - 1}), .Wrong_Version, 0)
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.version = LIST_VERSION + 1}), .Wrong_Version, 0)
	// Pages of wirings with no wiring row.
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.wiring_pages = 1}), .Bad_Wiring_Pages, 0)
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.row_count = 0})[:size_of(List_Header)], .No_Row, 0)
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.row_count = ROW_CAPACITY + 1}), .Too_Many_Rows, 0)
	expect_refused(t, header_change(bytes, proc(header: ^List_Header) {header.row_count = max(u32)}), .Too_Many_Rows, 0)
	// Wiring rows that the header counts and the bytes do not hold: one,
	// nine, the largest count; the reader pays a place for none of them.
	for count in ([?]u32{1, 9, max(u32)}) {
		counted := header_change(bytes, proc(header: ^List_Header) {header.wiring_pages = 1})
		(^List_Header)(raw_data(counted)).wiring_count = count
		testing.expect_value(t, list_wiring_count(counted), 0)
		expect_refused(t, counted, .Too_Short, 0)
	}
	// Rows with no page.
	_, _, wired := wired_rows()
	expect_refused(t, header_change(wired, proc(header: ^List_Header) {header.wiring_pages = 0}), .Bad_Wiring_Pages, 0)
	// What the starter reads: the pages of the header, the audits, and no
	// fact of a list that is not whole.
	audits, wiring_pages, facts_ok := list_starter_facts(wired)
	testing.expect(t, facts_ok && audits == 0 && wiring_pages == 1, "the facts of the wired list")
	_, _, cut_ok := list_starter_facts(wired[:len(wired) - 1])
	testing.expect(t, !cut_ok, "a cut list gives facts")
	_, _, empty_ok := list_starter_facts(nil)
	testing.expect(t, !empty_ok, "no list gives facts")
	// No header: no row to place.
	testing.expect_value(t, list_wiring_count(wired[:size_of(List_Header) - 1]), 0)
	testing.expect_value(t, list_wiring_count(wired), 3)
	// A place of the reader one row short of the rows of the list.
	short_list: List
	short_problem, _, _ := list_read(wired, &short_list, rows_place(wired)[:2])
	testing.expect_value(t, short_problem, List_Problem.Too_Many_Wirings)
	expect_refused(t, bytes[:len(bytes) - 1], .Too_Short, 0)
	longer := make([]u8, len(bytes) + 1, context.temp_allocator)
	copy(longer, bytes)
	expect_refused(t, longer, .Bytes_After_Rows, 0)
}

// A start row: a name of no byte, a name with a capital, a space or a byte
// past ASCII, a name of 32 bytes with no zero after it, a byte after the
// zero bytes, a bit of needs past the last part and the highest bit, a
// rule one past the last and the largest word, a mark one past Needed and
// the largest word, one restart past the limit, and two rows of one
// module. The refusal names the row, and gives no row. A restart window on
// the row with no restart is refused at its row 0: 1 second and the
// largest word.
@(test)
a_row_with_a_wrong_word_is_refused :: proc(t: ^testing.T) {
	_, bytes := three_rows()
	cases := [?]struct {
		change:  proc(record: ^Row_Record),
		problem: List_Problem,
	} {
		{proc(record: ^Row_Record) {record.module_name = {}}, .Bad_Name},
		{proc(record: ^Row_Record) {record.module_name[0] = 'C'}, .Bad_Name},
		{proc(record: ^Row_Record) {record.module_name[1] = ' '}, .Bad_Name},
		{proc(record: ^Row_Record) {record.module_name[1] = 0xC3}, .Bad_Name},
		{proc(record: ^Row_Record) {for &character in record.module_name {character = 'a'}}, .Bad_Name},
		{proc(record: ^Row_Record) {record.module_name[MODULE_NAME_SIZE - 1] = 'a'}, .Bad_Name},
		{proc(record: ^Row_Record) {record.needs = u64(1) << (u64(max(Machine_Part)) + 1)}, .Unknown_Part},
		{proc(record: ^Row_Record) {record.needs = u64(1) << 63}, .Unknown_Part},
		{proc(record: ^Row_Record) {record.absent_rule = u32(max(Absent_Part_Rule)) + 1}, .Unknown_Rule},
		{proc(record: ^Row_Record) {record.absent_rule = max(u32)}, .Unknown_Rule},
		{proc(record: ^Row_Record) {record.usable_mark = u32(max(Usable_Mark)) + 1}, .Unknown_Mark},
		{proc(record: ^Row_Record) {record.usable_mark = max(u32)}, .Unknown_Mark},
		{proc(record: ^Row_Record) {record.restart_count = RESTART_LIMIT + 1}, .Restarts_Past_Limit},
		{proc(record: ^Row_Record) {record.restart_count = max(u32)}, .Restarts_Past_Limit},
	}
	for case_of in cases {
		expect_refused(t, record_change(bytes, 1, case_of.change), case_of.problem, 1)
	}
	expect_refused(t, record_change(bytes, 0, proc(record: ^Row_Record) {record.restart_window_seconds = 1}), .Window_Without_Restarts, 0)
	expect_refused(t, record_change(bytes, 0, proc(record: ^Row_Record) {record.restart_window_seconds = max(u32)}), .Window_Without_Restarts, 0)
	// The row with a window of 60 seconds, its restarts set to 0.
	expect_refused(t, record_change(bytes, 1, proc(record: ^Row_Record) {record.restart_count = 0}), .Window_Without_Restarts, 1)
	twice := record_change(bytes, 2, proc(record: ^Row_Record) {record.module_name = {}; copy(record.module_name[:], "input")})
	expect_refused(t, twice, .Name_Twice, 2)
}

// A wiring row, each change on the second one, at the place 1: a reserved
// word; a writer row of 0, one past the start rows and the largest word;
// what the border of a wiring refuses, with its error record (an end word
// that names no member, a reader row of 0 and one past the start rows, an
// index of 0, a capacity that is no power of two, terms and a condition,
// which a start list cannot lend, a reserved word of the wiring); an end
// that a start policy does not hold (a Connected writer, a Started writer
// with a Child reader, an Asker reader, a Connected reader); a row that
// loops; a writer before its reader; and a second row of the log of one
// writer. Each is refused whole.
@(test)
a_wiring_row_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	_, wirings, bytes := wired_rows()
	good := wirings[1]
	change :: proc(record: Wiring_Row_Record, edit: proc(record: ^Wiring_Row_Record)) -> Wiring_Row_Record {
		changed := record
		edit(&changed)
		return changed
	}
	refused :: proc(field: output.Wiring_Field, word: u64, largest: u64) -> errors.Error_Record {
		return errors.error_make(.Bad_Value, .Wiring_Rows, i64(field), i64(word), i64(largest), 2)
	}
	cases := [?]struct {
		record:  Wiring_Row_Record,
		problem: List_Problem,
		refusal: errors.Error_Record,
	} {
		{change(good, proc(record: ^Wiring_Row_Record) {record.reserved = 1}), .Reserved_Not_Zero, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.writer_row = 0}), .Wiring_Row_Unknown, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.writer_row = 5}), .Wiring_Row_Unknown, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.writer_row = max(u32)}), .Wiring_Row_Unknown, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.writer_end = 9}), .Wiring_Refused, refused(.Writer_End, 9, u64(output.Wiring_End.Connected))},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.reader_handle = 0}), .Wiring_Refused, refused(.Reader_Handle, 0, 4)},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.reader_handle = 5}), .Wiring_Refused, refused(.Reader_Handle, 5, 4)},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.writer_index = 0}), .Wiring_Refused, refused(.Writer_Index, 0, module.RECORD_STREAM_INDEX_MOST)},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.capacity = 33}), .Wiring_Refused, refused(.Capacity, 33, output.WIRING_CAPACITY_MOST)},
		// The terms: an offset, a count that is not the size of the terms, and
		// bytes of terms in a row with none.
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.terms_offset, record.wiring.terms_count = 64, 8}), .Bad_Terms, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.terms_offset, record.wiring.terms_count = 1, START_LIST_TERMS_BYTES}), .Bad_Terms, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.terms_count = START_LIST_TERMS_BYTES - 1}), .Bad_Terms, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.terms_count = START_LIST_TERMS_BYTES + 1}), .Bad_Terms, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.terms_count = max(u32)}), .Bad_Terms, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.terms[START_LIST_TERMS_BYTES - 1] = 1}), .Bad_Terms, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.condition_offset, record.wiring.condition_count = 64, size_of(output.Condition_Terms)}), .Wiring_Refused, refused(.Condition_Offset, 64, 0)},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.reserved[1] = 1}), .Wiring_Refused, refused(.Reserved, 1, 0)},
		// A pair names an earlier row that the output border takes, and the
		// start list refuses it whole.
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.paired_row = 1}), .Wiring_Refused, refused(.Paired_Row, 1, 0)},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.writer_end, record.wiring.writer_handle = u32(output.Wiring_End.Connected), 7}), .End_Not_Held, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.writer_end, record.wiring.writer_handle, record.wiring.reader_end, record.wiring.reader_handle = u32(output.Wiring_End.Started), 2, u32(output.Wiring_End.Child), 0}), .End_Not_Held, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.reader_end, record.wiring.reader_handle, record.wiring.reader_index = u32(output.Wiring_End.Asker), 0, 0}), .End_Not_Held, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.reader_end, record.wiring.reader_handle = u32(output.Wiring_End.Connected), 7}), .End_Not_Held, {}},
		// A row that loops: the writer row is its own reader.
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.reader_handle = 3}), .Wiring_Loops, {}},
		// A pair in the wrong order: the reader row comes after its writer.
		{change(good, proc(record: ^Wiring_Row_Record) {record.wiring.reader_handle = 4}), .Writer_Before_Reader, {}},
		{change(good, proc(record: ^Wiring_Row_Record) {record.writer_row, record.wiring.reader_handle = 1, 2}), .Writer_Before_Reader, {}},
	}
	for case_of in cases {
		expect_refused(t, wiring_change(bytes, 4, 1, case_of.record), case_of.problem, 1, case_of.refusal)
	}
	// The log of one writer twice: the third row joins the log of the first.
	expect_refused(t, wiring_change(bytes, 4, 0, log_row(3, 2, 1)), .Log_Wired_Twice, 2)
	// A writer row with one restart, then the most restarts: its first
	// wiring row is refused. A reader row with restarts is taken.
	expect_refused(t, record_change(bytes, 2, proc(record: ^Row_Record) {record.restart_count = 1}), .Writer_Restarts, 0)
	expect_refused(t, record_change(bytes, 2, proc(record: ^Row_Record) {record.restart_count = RESTART_LIMIT}), .Writer_Restarts, 0)
	list: List
	reader_restarts := record_change(bytes, 0, proc(record: ^Row_Record) {record.restart_count = RESTART_LIMIT})
	problem, _, _ := list_read(reader_restarts, &list, rows_place(reader_restarts))
	testing.expect_value(t, problem, List_Problem.None)
	// A list with no terms declares no audit.
	plain_list: List
	plain_problem, _, _ := list_read(bytes, &plain_list, rows_place(bytes))
	testing.expect_value(t, plain_problem, List_Problem.None)
	testing.expect_value(t, list_audit_count(&plain_list), 0)
	// Terms that name no audit that keeps what leaves a server: each field
	// at its edges, and bytes that are no terms.
	audit :: wide_grants.Space_Terms{kind_word = i64(wide_grants.Collector_Space_Kind.Audit), bound_records = 1, forwarding_word = i64(wide_grants.Space_Forwarding.Keeps), record_size = 1}
	bad_terms := [?]wide_grants.Space_Terms {
		{},
		{kind_word = i64(wide_grants.Collector_Space_Kind.Keep), bound_records = 1, forwarding_word = audit.forwarding_word, record_size = 1},
		{kind_word = 3, bound_records = 1, forwarding_word = audit.forwarding_word, record_size = 1},
		{kind_word = -1, bound_records = 1, forwarding_word = audit.forwarding_word, record_size = 1},
		{kind_word = audit.kind_word, bound_records = 1, forwarding_word = i64(wide_grants.Space_Forwarding.Forward), record_size = 1},
		{kind_word = audit.kind_word, bound_records = 1, forwarding_word = 0, record_size = 1},
		{kind_word = audit.kind_word, bound_records = 0, forwarding_word = audit.forwarding_word, record_size = 1},
		{kind_word = audit.kind_word, bound_records = -1, forwarding_word = audit.forwarding_word, record_size = 1},
		{kind_word = audit.kind_word, bound_records = wide_grants.SPACE_AUDIT_BOUND_MOST + 1, forwarding_word = audit.forwarding_word, record_size = 1},
		{kind_word = audit.kind_word, bound_records = max(i64), forwarding_word = audit.forwarding_word, record_size = 1},
		{kind_word = audit.kind_word, bound_records = 1, forwarding_word = audit.forwarding_word, record_size = 0},
		{kind_word = audit.kind_word, bound_records = 1, forwarding_word = audit.forwarding_word, record_size = wide_grants.SPACE_RECORD_BYTES_MOST + 1},
	}
	for terms in bad_terms {
		row := good
		row.wiring.terms_count = START_LIST_TERMS_BYTES
		row.terms = transmute([START_LIST_TERMS_BYTES]u8)terms
		expect_refused(t, wiring_change(bytes, 4, 1, row), .Bad_Terms, 1)
	}
	// A row with terms at each edge of their range: the list keeps them,
	// with their count.
	good_terms := [?]wide_grants.Space_Terms {
		audit,
		{kind_word = audit.kind_word, bound_records = wide_grants.SPACE_AUDIT_BOUND_MOST, forwarding_word = audit.forwarding_word, record_size = wide_grants.SPACE_RECORD_BYTES_MOST},
	}
	for terms in good_terms {
		with_terms := good
		with_terms.wiring.terms_count = START_LIST_TERMS_BYTES
		with_terms.terms = transmute([START_LIST_TERMS_BYTES]u8)terms
		problem, _, _ = list_read(wiring_change(bytes, 4, 1, with_terms), &list, rows_place(wiring_change(bytes, 4, 1, with_terms)))
		testing.expect_value(t, problem, List_Problem.None)
		testing.expect_value(t, list_audit_count(&list), 1)
		testing.expect_value(t, list.wirings[1].wiring.terms_count, u32(START_LIST_TERMS_BYTES))
		testing.expect_value(t, list.wirings[1].terms, with_terms.terms)
	}
}

// The writer of a list refuses more start rows or wiring rows than a list
// holds, and a room one byte short.
@(test)
a_list_past_its_room_is_not_written :: proc(t: ^testing.T) {
	names := [?]string{"", "abcdefghijklmnopqrstuvwxyz012345", "Console", "start-policy"}
	for name in names {
		_, made := row_make(name, {}, .Not_Started, .Not_Needed)
		testing.expectf(t, !made, "the row of %q is made", name)
	}
	rows: [ROW_CAPACITY + 1]Start_Row
	bytes := make([]u8, list_size(ROW_CAPACITY + 1, 2), context.temp_allocator)
	_, written := list_write(rows[:], nil, bytes)
	testing.expect(t, !written, "a list past the capacity is written")
	wirings: [2]Wiring_Row_Record
	first, _ := row_make("input", {}, .Not_Started, .Not_Needed)
	one := [1]Start_Row{first}
	_, short_written := list_write(one[:], nil, bytes[:list_size(1) - 1])
	testing.expect(t, !short_written, "a list is written into a room one byte short")
	_, short_wiring := list_write(one[:], wirings[:1], bytes[:list_size(1, 1) - 1])
	testing.expect(t, !short_wiring, "a list with a wiring row is written into a room one byte short")
}

// The pages of the wirings of a list. Refused first: record sizes of
// another count than the rows, and a record past the largest size. Then a
// list with no wiring row costs nothing, and the list of three rows costs
// the pages of the asker and of each row: the default ring of 64-byte
// compartments, a ring of 32 compartments, and the ring of the log.
@(test)
the_pages_of_the_wirings_of_a_list_are_counted :: proc(t: ^testing.T) {
	_, _, bytes := wired_rows()
	list: List
	list_read(bytes, &list, rows_place(bytes))
	sizes := [3]u32{56, 56, size_of(output.Log_Output_Record)}
	_, short_ok := wiring_pages_of_list(&list, sizes[:2])
	testing.expect(t, !short_ok, "the pages are counted with a size missing")
	too_large := [3]u32{56, module.RECORD_SIZE_LIMIT + 1, 56}
	_, large_ok := wiring_pages_of_list(&list, too_large[:])
	testing.expect(t, !large_ok, "the pages are counted for a record past the largest size")
	testing.expect_value(t, wiring_pages_of_row(0, module.RECORD_SIZE_LIMIT + 1), u64(0))
	_, plain := three_rows()
	plain_list: List
	list_read(plain, &plain_list, rows_place(plain))
	pages, ok := wiring_pages_of_list(&plain_list, nil)
	testing.expect(t, ok)
	testing.expect_value(t, pages, u64(0))

	list.wirings[1].wiring.capacity = 32
	pages, ok = wiring_pages_of_list(&list, sizes[:])
	testing.expect(t, ok)
	description_pages := u64(output.DESCRIPTION_FILE_BYTES_MOST / ring.PAGE_SIZE)
	// The asker, the place of the 3 rows in the memory of the start policy,
	// then each row.
	expected := u64(WIRING_PAGES_OF_THE_ASKER) + list_table_pages(3)
	expected += ring.compartment_pages(output.WIRING_CAPACITY_DEFAULT, 64) + 1 + description_pages
	expected += ring.compartment_pages(32, 64) + 1 + description_pages
	expected += ring.compartment_pages(output.WIRING_CAPACITY_DEFAULT, output.compartment_size(size_of(output.Log_Output_Record))) + 1 + description_pages
	testing.expect_value(t, pages, expected)
	testing.expect_value(t, wiring_pages_of_row(0, 56), ring.compartment_pages(256, 64) + 1 + description_pages)
	// The records before a list count the same pages; another count of
	// sizes, none.
	_, wired_records, _ := wired_rows()
	wired_records[1].wiring.capacity = 32
	record_pages, records_ok := wiring_pages_of_records(wired_records[:], sizes[:])
	testing.expect(t, records_ok && record_pages == expected, "the pages of the records differ from the pages of the list")
	_, short_ok = wiring_pages_of_records(wired_records[:], sizes[:2])
	testing.expect(t, !short_ok, "records with fewer sizes are counted")
	testing.expect_value(t, list_table_pages(0), u64(0))
	testing.expect_value(t, list_table_pages(1), u64(1))
}

// The names that the root service starts by a procedure of its own: no
// other name gives a procedure, the empty name first, then each name gives
// its own, and no two procedures have one name. The display is started by
// its role: the name of the module that holds it today gives no procedure.
@(test)
a_part_of_the_system_is_started_by_the_root_service :: proc(t: ^testing.T) {
	for name in ([?]string{"", "console", "wired_writer", "inputs", "input_", "Input", "compositor", "Display"}) {
		testing.expectf(t, root_procedure_of(name) == .None, "%q gives a procedure of the root service", name)
	}
	for procedure in Root_Procedure {
		if procedure == .None {
			continue
		}
		testing.expect_value(t, root_procedure_of(ROOT_PROCEDURE_NAMES[procedure]), procedure)
	}
	testing.expect_value(t, ROOT_PROCEDURE_NAMES[.Operation_Fuzzing], OPERATION_FUZZING_NAME)
}

// The machine parts page: another magic, another version, a reserved word,
// a bit past the last part, a screen bit with no size, a size with no
// screen bit, a width with no height. The pages that agree come last.
@(test)
a_machine_parts_page_that_disagrees_is_refused :: proc(t: ^testing.T) {
	page: Machine_Parts_Page
	refused := [?]Machine_Parts_Page {
		{magic = PARTS_PAGE_MAGIC + 1, version = PARTS_PAGE_VERSION},
		{magic = PARTS_PAGE_MAGIC, version = PARTS_PAGE_VERSION + 1},
		{magic = PARTS_PAGE_MAGIC, version = PARTS_PAGE_VERSION, reserved = 1},
		{magic = PARTS_PAGE_MAGIC, version = PARTS_PAGE_VERSION, present = u64(1) << (u64(max(Machine_Part)) + 1)},
		{magic = PARTS_PAGE_MAGIC, version = PARTS_PAGE_VERSION, present = transmute(u64)Machine_Parts{.Screen}},
		{magic = PARTS_PAGE_MAGIC, version = PARTS_PAGE_VERSION, screen_width = 1920, screen_height = 1080},
		{magic = PARTS_PAGE_MAGIC, version = PARTS_PAGE_VERSION, present = transmute(u64)Machine_Parts{.Screen}, screen_width = 1920},
	}
	for candidate in refused {
		page = candidate
		parts, width, height, ok := parts_page_read(&page)
		testing.expectf(t, !ok, "the page %v is taken", candidate)
		testing.expect_value(t, parts, Machine_Parts{})
		testing.expect_value(t, width, 0)
		testing.expect_value(t, height, 0)
	}
	parts_page_write(&page, {.Screen, .Tpm}, 1920, 1080)
	parts, width, height, ok := parts_page_read(&page)
	testing.expect(t, ok)
	testing.expect_value(t, parts, Machine_Parts{.Screen, .Tpm})
	testing.expect_value(t, width, 1920)
	testing.expect_value(t, height, 1080)
	parts_page_write(&page, {}, 0, 0)
	parts, _, _, ok = parts_page_read(&page)
	testing.expect(t, ok)
	testing.expect_value(t, parts, Machine_Parts{})
}

// The border of a word of parts: each bit past the last part is refused;
// each part alone and all of them read back.
@(test)
a_word_of_parts_past_the_last_part_is_refused :: proc(t: ^testing.T) {
	for bit in u64(max(Machine_Part)) + 1 ..< 64 {
		_, ok := parts_of_word(u64(1) << bit)
		testing.expectf(t, !ok, "the bit %d is taken", bit)
	}
	_, all_ok := parts_of_word(max(u64))
	testing.expect(t, !all_ok)
	// The first part of a set: the empty set gives Screen, then the lowest
	// member of each set.
	testing.expect_value(t, first_part({}), Machine_Part.Screen)
	testing.expect_value(t, first_part({.Tpm}), Machine_Part.Tpm)
	testing.expect_value(t, first_part({.Tpm, .Data_Disk, .Sound_Device}), Machine_Part.Data_Disk)
	for part in Machine_Part {
		parts, ok := parts_of_word(u64(1) << u64(part))
		testing.expect(t, ok)
		testing.expect_value(t, parts, Machine_Parts{part})
	}
}

// The lists that the border takes: the three rows, each with its fields as
// they were written; the capacity of start rows; the wired list with its
// rows from 0; and the capacity of wiring rows. A rescue list needs a row
// with the mark Needed.
@(test)
a_written_list_reads_back :: proc(t: ^testing.T) {
	written, bytes := three_rows()
	list: List
	problem, _, _ := list_read(bytes, &list, rows_place(bytes))
	testing.expect_value(t, problem, List_Problem.None)
	testing.expect_value(t, list.row_count, 3)
	testing.expect_value(t, list.wiring_count, 0)
	for index in 0 ..< 3 {
		testing.expect_value(t, list.rows[index], written[index])
	}
	testing.expect_value(t, row_name(&list.rows[1]), "console")
	testing.expect(t, list_has_usable_row(list.rows[:list.row_count]))
	testing.expect(t, !list_has_usable_row(list.rows[:1]))

	full: [ROW_CAPACITY]Start_Row
	names: [ROW_CAPACITY][2]u8
	for &row, index in full {
		names[index] = {'a' + u8(index / 26), 'a' + u8(index % 26)}
		row, _ = row_make(string(names[index][:]), {}, .Not_Started, .Not_Needed)
	}
	// The last row writes 20 wiring rows, each to an earlier row: a list
	// has no count of its wiring rows.
	WIRINGS :: 20
	wirings: [WIRINGS]Wiring_Row_Record
	for &record, index in wirings {
		record = wiring_row(ROW_CAPACITY, u32(index + 1), u32(index + 1), u32(index + 1))
	}
	full_bytes := make([]u8, list_size(ROW_CAPACITY, WIRINGS), context.temp_allocator)
	_, full_written := list_write(full[:], wirings[:], full_bytes, 7)
	testing.expect(t, full_written)
	full_problem, _, _ := list_read(full_bytes, &list, rows_place(full_bytes))
	testing.expect_value(t, full_problem, List_Problem.None)
	testing.expect_value(t, list.row_count, ROW_CAPACITY)
	testing.expect_value(t, list.wiring_count, WIRINGS)
	testing.expect_value(t, list.wiring_pages, u64(7))

	_, wired, wired_bytes := wired_rows()
	wired_problem, _, _ := list_read(wired_bytes, &list, rows_place(wired_bytes))
	testing.expect_value(t, wired_problem, List_Problem.None)
	testing.expect_value(t, list.row_count, 4)
	testing.expect_value(t, list.wiring_count, 3)
	for index in 0 ..< 3 {
		testing.expect_value(t, list.wirings[index].writer_row, 2)
		testing.expect_value(t, list.wirings[index].wiring, wired[index].wiring)
	}
	testing.expect_value(t, list.wirings[0].reader_row, 0)
	testing.expect_value(t, list.wirings[1].reader_row, 1)
	testing.expect_value(t, list.wirings[2].reader_row, 0)
}

// A row that stopped itself with Done finished its work, and one that
// stopped with Refused would get the same input: neither starts again. Each
// other stop restarts: a failure, a stop that a request asked, and each
// stop with no outcome (a fault, a holder, the end of the last thread).
@(test)
a_clean_stop_starts_no_restart :: proc(t: ^testing.T) {
	testing.expect(t, !stop_restarts(.Done), "a stop with Done restarts")
	testing.expect(t, !stop_restarts(.Refused), "a stop with Refused restarts")
	testing.expect(t, stop_restarts(.Failed), "a stop with Failed does not restart")
	testing.expect(t, stop_restarts(.Stopped_On_Request), "a stop with Stopped_On_Request does not restart")
	testing.expect(t, stop_restarts(.None), "a stop with no outcome does not restart")
}

// expect_take takes one restart and checks the decision and the count left.
@(private = "file")
expect_take :: proc(t: ^testing.T, window: ^Restart_Window, restart_count, window_seconds: u32, now: u64, allowed: bool, left: u32, loc := #caller_location) {
	taken, restarts_left := restart_window_take(window, restart_count, window_seconds, now)
	testing.expect_value(t, taken, allowed, loc = loc)
	testing.expect_value(t, restarts_left, left, loc = loc)
}

// The counts that the bound refuses first: 0 restarts, with and without a
// window, at the clock 0 and at the largest time; one past RESTART_LIMIT
// and the largest count. A refusal changes nothing.
@(test)
a_restart_past_its_count_is_refused :: proc(t: ^testing.T) {
	window: Restart_Window
	for seconds in ([?]u32{0, 1, 60, max(u32)}) {
		for now in ([?]u64{0, 1, max(u64)}) {
			expect_take(t, &window, 0, seconds, now, false, 0)
			expect_take(t, &window, RESTART_LIMIT + 1, seconds, now, false, 0)
			expect_take(t, &window, max(u32), seconds, now, false, 0)
		}
	}
	testing.expect(t, window == Restart_Window{}, "a refused restart changed the window")
}

// With no window the count holds for the whole run, and the time is not
// read: 1 restart then a refusal, whatever the time; 16 restarts with the
// counts 15 to 0 left, then a refusal; no time is kept.
@(test)
a_row_with_no_window_counts_the_whole_run :: proc(t: ^testing.T) {
	one: Restart_Window
	expect_take(t, &one, 1, 0, 0, true, 0)
	expect_take(t, &one, 1, 0, max(u64), false, 0)
	expect_take(t, &one, 1, 0, 0, false, 0)
	most: Restart_Window
	for index in u32(0) ..< RESTART_LIMIT {
		// A time that goes back and forth: the rule must not read it.
		expect_take(t, &most, RESTART_LIMIT, 0, index % 2 == 0 ? max(u64) : 0, true, RESTART_LIMIT - 1 - index)
	}
	expect_take(t, &most, RESTART_LIMIT, 0, max(u64), false, 0)
	testing.expect(t, most.times_milliseconds == [RESTART_LIMIT]u64{}, "a row with no window kept a time")
	testing.expect_value(t, most.taken, RESTART_LIMIT)
}

// A window of 60 seconds and 2 restarts, at the times 1000 and 2000: the
// third at window - 1 after the first is refused, at the window and one
// past it the first has left the window. A window that starts at the clock
// 0 keeps the same rule.
@(test)
a_restart_leaves_its_window_at_the_window :: proc(t: ^testing.T) {
	WINDOW :: u64(60_000)
	window: Restart_Window
	expect_take(t, &window, 2, 60, 1000, true, 1)
	expect_take(t, &window, 2, 60, 2000, true, 0)
	expect_take(t, &window, 2, 60, 1000 + WINDOW - 1, false, 0)
	expect_take(t, &window, 2, 60, 1000 + WINDOW, true, 0)
	expect_take(t, &window, 2, 60, 1000 + WINDOW + 1, false, 0)
	expect_take(t, &window, 2, 60, 2000 + WINDOW + 1, true, 0)

	from_zero: Restart_Window
	expect_take(t, &from_zero, 2, 60, 0, true, 1)
	expect_take(t, &from_zero, 2, 60, 0, true, 0)
	expect_take(t, &from_zero, 2, 60, 0, false, 0)
	expect_take(t, &from_zero, 2, 60, WINDOW - 1, false, 0)
	expect_take(t, &from_zero, 2, 60, WINDOW, true, 1)
	testing.expect_value(t, from_zero.taken, u32(1))
}

// A clock that goes back counts the kept restarts as of age 0: no
// subtraction wraps into a large age that would free the row. Times at the
// top of u64 and the largest window keep the rule.
@(test)
a_clock_that_goes_back_frees_no_restart :: proc(t: ^testing.T) {
	back: Restart_Window
	expect_take(t, &back, 1, 60, 100_000, true, 0)
	expect_take(t, &back, 1, 60, 50, false, 0)
	expect_take(t, &back, 1, 60, 0, false, 0)
	expect_take(t, &back, 1, 60, 160_000, true, 0)

	top: Restart_Window
	largest := u64(max(u32)) * 1000
	expect_take(t, &top, 1, max(u32), max(u64) - largest, true, 0)
	expect_take(t, &top, 1, max(u32), max(u64) - 1, false, 0)
	expect_take(t, &top, 1, max(u32), max(u64), true, 0)
}

// A holder that stops in a loop: 5 restarts in 60 seconds, 1 ms apart,
// then each stop of the next second is refused. A holder with a rare fault,
// once a week for a year, keeps its role with 1 restart in 60 seconds, and
// loses it at the second week with no window.
@(test)
a_loop_ends_and_a_rare_fault_does_not :: proc(t: ^testing.T) {
	loop: Restart_Window
	for index in u32(0) ..< 5 {
		expect_take(t, &loop, 5, 60, 10_000 + u64(index), true, 4 - index)
	}
	for now in u64(10_005) ..< 11_005 {
		taken, _ := restart_window_take(&loop, 5, 60, now)
		testing.expectf(t, !taken, "a restart in a loop at %d ms is taken", now)
	}
	WEEK :: u64(7 * 24 * 3600 * 1000)
	rare, whole: Restart_Window
	for week in u64(1) ..= 52 {
		expect_take(t, &rare, 1, 60, week * WEEK, true, 0)
		taken, _ := restart_window_take(&whole, 1, 0, 0)
		testing.expect_value(t, taken, week == 1)
	}
}

// The times turn around their table many times: with a window of 1
// second, 16 restarts at the start of each period of 2 seconds, then the
// 17th of the same period is refused. A window slides: in the next
// period, a restart of the last one still counts until its own age is the
// window.
@(test)
the_times_of_a_window_turn_around_their_table :: proc(t: ^testing.T) {
	window: Restart_Window
	for period in u64(0) ..< 100 {
		for index in u32(0) ..< RESTART_LIMIT {
			expect_take(t, &window, RESTART_LIMIT, 1, period * 2000 + u64(index), true, RESTART_LIMIT - 1 - index)
		}
		expect_take(t, &window, RESTART_LIMIT, 1, period * 2000 + 999, false, 0)
		// At 1000 ms the first restart of the period leaves, and only it.
		expect_take(t, &window, RESTART_LIMIT, 1, period * 2000 + 1000, true, 0)
		expect_take(t, &window, RESTART_LIMIT, 1, period * 2000 + 1000, false, 0)
		testing.expect(t, window.taken <= RESTART_LIMIT && window.first_index < RESTART_LIMIT)
	}
}

// The reads of the clock of the cases of row_stop_step, and the time that
// the clock gives.
@(private = "file")
clock_reads: int
@(private = "file")
clock_now: u64

@(private = "file")
clock_of_test :: proc "contextless" () -> u64 {
	clock_reads += 1
	return clock_now
}

// The steps of a stop. Done and Refused never restart and never read the
// clock: Silent with no restart, Not_Restarted with some. A row with no
// restart is Silent past its bound, unless it is needed. A needed row
// with 2 restarts and no window restarts twice, then escalates, and reads
// no clock. A row with a window reads the clock once at each stop that
// restarts or not, and restarts again when its window has passed.
@(test)
a_stop_takes_its_step :: proc(t: ^testing.T) {
	clock_reads, clock_now = 0, 0
	plain, _ := row_make("date", {}, .Not_Started, .Not_Needed)
	needed, _ := row_make("console", {}, .Not_Started, .Needed)
	counted, _ := row_make("console", {}, .Not_Started, .Needed, 2)
	windowed, _ := row_make("storage", {}, .Not_Started, .Not_Needed, 1, 60)
	window: Restart_Window
	for outcome in ([?]op.Stop_Outcome{.Done, .Refused}) {
		step, _ := row_stop_step(&plain, &window, outcome, clock_of_test)
		testing.expect_value(t, step, Row_Stop_Step.Silent)
		step, _ = row_stop_step(&windowed, &window, outcome, clock_of_test)
		testing.expect_value(t, step, Row_Stop_Step.Not_Restarted)
	}
	testing.expect_value(t, clock_reads, 0)
	testing.expect(t, window == Restart_Window{}, "a stop with no restart counted one")
	for outcome in ([?]op.Stop_Outcome{.None, .Failed, .Stopped_On_Request}) {
		step, _ := row_stop_step(&plain, &window, outcome, clock_of_test)
		testing.expect_value(t, step, Row_Stop_Step.Silent)
		step, _ = row_stop_step(&needed, &window, outcome, clock_of_test)
		testing.expect_value(t, step, Row_Stop_Step.Escalate)
	}
	counted_window: Restart_Window
	expected := [?]Row_Stop_Step{.Restarted, .Restarted, .Escalate, .Escalate}
	lefts := [?]u32{1, 0, 0, 0}
	for step_of, index in expected {
		step, left := row_stop_step(&counted, &counted_window, .Failed, clock_of_test)
		testing.expect_value(t, step, step_of)
		testing.expect_value(t, left, lefts[index])
	}
	testing.expect_value(t, clock_reads, 0)
	timed: Restart_Window
	clock_now = 5000
	step, _ := row_stop_step(&windowed, &timed, .Failed, clock_of_test)
	testing.expect_value(t, step, Row_Stop_Step.Restarted)
	clock_now = 5000 + 59_999
	step, _ = row_stop_step(&windowed, &timed, .None, clock_of_test)
	testing.expect_value(t, step, Row_Stop_Step.Past_Bound)
	clock_now = 5000 + 60_000
	step, _ = row_stop_step(&windowed, &timed, .None, clock_of_test)
	testing.expect_value(t, step, Row_Stop_Step.Restarted)
	testing.expect_value(t, clock_reads, 3)
}

// A list of a row display and a row console, with the size of a screen of
// memory on the row display, and its bytes.
@(private = "file")
display_rows :: proc(width, height: u32) -> (rows: [2]Start_Row, bytes: []u8) {
	display, display_made := row_make("display", {.Screen}, .Not_Started, .Not_Needed, 0, 0, width, height)
	console, console_made := row_make("console", {.Screen}, .Not_Started, .Needed)
	assert(display_made && console_made)
	rows = {display, console}
	bytes = make([]u8, list_size(2), context.temp_allocator)
	_, written := list_write(rows[:], nil, bytes)
	assert(written)
	return
}

// The size of a screen of memory at its edges: one side 0, one past each
// bound, the largest word, on the row display; any size on another row.
// Then 0 x 0, the least and the largest size, which the border takes.
@(test)
a_screen_of_memory_past_its_bounds_is_refused :: proc(t: ^testing.T) {
	_, bytes := display_rows(1920, 1080)
	refused_sizes := [?]proc(record: ^Row_Record) {
		proc(record: ^Row_Record) {record.screen_of_memory_width = 0},
		proc(record: ^Row_Record) {record.screen_of_memory_height = 0},
		proc(record: ^Row_Record) {record.screen_of_memory_width = memory_screen.MIN_WIDTH - 1},
		proc(record: ^Row_Record) {record.screen_of_memory_height = memory_screen.MIN_HEIGHT - 1},
		proc(record: ^Row_Record) {record.screen_of_memory_width = memory_screen.MAX_WIDTH + 1},
		proc(record: ^Row_Record) {record.screen_of_memory_height = memory_screen.MAX_HEIGHT + 1},
		proc(record: ^Row_Record) {record.screen_of_memory_width = max(u32)},
	}
	for change in refused_sizes {
		expect_refused(t, record_change(bytes, 0, change), .Screen_Size_Refused, 0)
	}
	expect_refused(t, record_change(bytes, 1, proc(record: ^Row_Record) {record.screen_of_memory_width, record.screen_of_memory_height = 1920, 1080}), .Screen_Size_Not_Display, 1)
	expect_refused(t, record_change(bytes, 1, proc(record: ^Row_Record) {record.screen_of_memory_height = 1}), .Screen_Size_Not_Display, 1)
	for size in ([?][2]u32{{0, 0}, {memory_screen.MIN_WIDTH, memory_screen.MIN_HEIGHT}, {memory_screen.MAX_WIDTH, memory_screen.MAX_HEIGHT}}) {
		_, sized := display_rows(size[0], size[1])
		list: List
		problem, _, _ := list_read(sized, &list, nil)
		testing.expectf(t, problem == .None, "%v was refused: %v", size, problem)
		width, height := screen_of_memory_of_list(&list)
		testing.expect(t, width == size[0] && height == size[1])
	}
}

// The rows see a screen on a machine with no screen only when the row
// display gives a size; the start of the row display carries the size only
// then. A machine with a screen keeps its parts, and its start carries no
// size.
@(test)
a_screen_of_memory_gives_the_rows_a_screen :: proc(t: ^testing.T) {
	_, sized := display_rows(1920, 1080)
	list: List
	problem, _, _ := list_read(sized, &list, nil)
	testing.expect(t, problem == .None)
	testing.expect_value(t, parts_for_rows(&list, {.Screen}), Machine_Parts{.Screen})
	width, height := row_screen_of_memory(&list, &list.rows[0])
	testing.expect(t, width == 0 && height == 0, "a machine with a screen got a screen of memory")
	testing.expect_value(t, parts_for_rows(&list, {.Network_Device}), Machine_Parts{.Network_Device, .Screen})
	width, height = row_screen_of_memory(&list, &list.rows[0])
	testing.expect(t, width == 1920 && height == 1080)
	width, height = row_screen_of_memory(&list, &list.rows[1])
	testing.expect(t, width == 0 && height == 0, "the row console carries a size")
	_, unsized := display_rows(0, 0)
	problem, _, _ = list_read(unsized, &list, nil)
	testing.expect(t, problem == .None)
	testing.expect_value(t, parts_for_rows(&list, {}), Machine_Parts{})
}
