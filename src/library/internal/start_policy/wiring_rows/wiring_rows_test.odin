#+build !freestanding
package wiring_rows

import "base:intrinsics"
import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/start_list"
import "modus:contract/wide_grants"

// The lends of one test: the readers lent in order, and the lend that
// fails (from 1; 0: none). Each test runs on its own thread.
@(thread_local)
lent_readers: [start_list.WIRING_ROW_CAPACITY]int
@(thread_local)
lend_count: int
@(thread_local)
lend_failing: int

@(private = "file")
test_lend :: proc "contextless" (reader_row: int) -> (number: u32, status: op.Status) {
	lend_count += 1
	if lend_count == lend_failing {
		return 0, .No_Slot
	}
	lent_readers[lend_count - 1] = reader_row
	return u32(10 + lend_count), .Ok
}

@(private = "file")
lends_reset :: proc(failing: int) {
	lent_readers, lend_count, lend_failing = {}, 0, failing
}

// The terms of an audit space that keeps what leaves a server, the one kind
// that the border of a start list takes.
@(private = "file")
test_terms :: proc() -> [start_list.START_LIST_TERMS_BYTES]u8 {
	terms := wide_grants.Space_Terms{kind_word = i64(wide_grants.Collector_Space_Kind.Audit), bound_records = 300, forwarding_word = i64(wide_grants.Space_Forwarding.Keeps), record_size = 24}
	return transmute([start_list.START_LIST_TERMS_BYTES]u8)terms
}

// A list that the border takes: two readers, a writer whose three wiring
// rows go to them, the log among them, and a row with no wiring row.
@(private = "file")
wired_list :: proc(with_terms := false) -> (list: start_list.List) {
	rows: [4]start_list.Start_Row
	for name, index in ([4]string{"reader_one", "reader_two", "writer", "lone"}) {
		rows[index], _ = start_list.row_make(name, {}, .Not_Started, .Not_Needed)
	}
	child, started := u32(output.Wiring_End.Child), u32(output.Wiring_End.Started)
	record_output, log := u32(output.Writer_Stream.Record_Output), u32(output.Writer_Stream.Log)
	wirings := [3]start_list.Wiring_Row_Record {
		{writer_row = 3, wiring = {writer_end = child, writer_stream = record_output, writer_index = 1, reader_end = started, reader_handle = 1, reader_index = 1}},
		{writer_row = 3, wiring = {writer_end = child, writer_stream = record_output, writer_index = 2, reader_end = started, reader_handle = 2, reader_index = 1}},
		{writer_row = 3, wiring = {writer_end = child, writer_stream = log, reader_end = started, reader_handle = 1, reader_index = 2}},
	}
	if with_terms {
		// The second row carries the terms of an audit space of its reader.
		wirings[1].wiring.terms_count = start_list.START_LIST_TERMS_BYTES
		wirings[1].terms = test_terms()
	}
	bytes := make([]u8, start_list.list_size(4, 3), context.temp_allocator)
	_, written := start_list.list_write(rows[:], wirings[:], bytes)
	problem, _, _ := start_list.list_read(bytes, &list)
	assert(written && problem == .None)
	return
}

// expect_given_back checks that the page holds the way back of numbers: a
// list of no row, which the border of the root service refuses for its
// count of rows, with each number in its handles.
@(private = "file")
expect_given_back :: proc(t: ^testing.T, page: []u8, numbers: []u32, loc := #caller_location) {
	checked: output.Checked_Wiring_List
	refusal, ok := output.wiring_list_check(page, .Start, &checked)
	testing.expect(t, !ok, "the way back is a list that the root service takes", loc = loc)
	testing.expect_value(t, refusal, errors.error_make(.Bad_Value, .Wiring_Rows, 0, 0, output.WIRING_LIST_ROW_LIMIT), loc = loc)
	head: output.Wiring_List_Head
	intrinsics.mem_copy_non_overlapping(&head, raw_data(page), size_of(head))
	testing.expect_value(t, int(head.handle_count), len(numbers), loc = loc)
	for number, index in numbers {
		word: u32
		intrinsics.mem_copy_non_overlapping(&word, &page[size_of(output.Wiring_List_Head) + index * size_of(u32)], size_of(u32))
		testing.expect_value(t, word, number, loc = loc)
	}
}

// The start of a writer row, each refusal first. A reader that does not
// run: no lend, an untouched page. A first lend that fails: nothing to give
// back. A second lend that fails: the first number goes back. A list that
// does not fit its page after the lends: both numbers go back.
@(test)
a_writer_whose_wiring_fails_does_not_start :: proc(t: ^testing.T) {
	list := wired_list()
	page := make([]u8, PAGE_BYTES, context.temp_allocator)
	page[0] = 0xAA
	not_running := [4]bool{true, false, false, false}
	lends_reset(0)
	prepared := row_list_prepare(&list, 2, not_running[:], page, test_lend)
	testing.expect_value(t, prepared, Prepared{outcome = .Reader_Not_Running, reader_row = 2, status = .Ok})
	testing.expect_value(t, lend_count, 0)
	testing.expect_value(t, page[0], 0xAA)
	short_running := [1]bool{true}
	prepared = row_list_prepare(&list, 2, short_running[:], page, test_lend)
	testing.expect_value(t, prepared.outcome, Outcome.Reader_Not_Running)
	testing.expect_value(t, prepared.reader_row, 2)

	running := [4]bool{true, true, false, false}
	lends_reset(1)
	prepared = row_list_prepare(&list, 2, running[:], page, test_lend)
	testing.expect_value(t, prepared, Prepared{outcome = .Lend_Refused, reader_row = 1, status = .No_Slot, give_back = false})
	for value in page {
		testing.expect_value(t, value, 0)
	}

	lends_reset(2)
	prepared = row_list_prepare(&list, 2, running[:], page, test_lend)
	testing.expect_value(t, prepared, Prepared{outcome = .Lend_Refused, reader_row = 2, status = .No_Slot, give_back = true})
	expect_given_back(t, page, {11})

	// Room for the way back of two numbers, and not for the three rows.
	short_page := page[:output.wiring_terms_start(3, 2) - 1]
	lends_reset(0)
	prepared = row_list_prepare(&list, 2, running[:], short_page, test_lend)
	testing.expect_value(t, prepared, Prepared{outcome = .List_Not_Written, status = .Bad_Operation, give_back = true})
	expect_given_back(t, short_page, {11, 12})
}

// The writer of the list of a row: handles of another count than the
// readers, a reader of a row that is not among the readers, and a row
// with no wiring row each write no list.
@(test)
a_list_that_names_no_reader_is_not_written :: proc(t: ^testing.T) {
	list := wired_list()
	page := make([]u8, PAGE_BYTES, context.temp_allocator)
	two_readers := [2]int{0, 1}
	one_handle := [1]u32{11}
	rows, ok := list_of_row(&list, 2, two_readers[:], one_handle[:], page)
	testing.expect(t, !ok && rows == 0, "a list with a handle missing is written")
	one_reader := [1]int{0}
	rows, ok = list_of_row(&list, 2, one_reader[:], one_handle[:], page)
	testing.expect(t, !ok && rows == 0, "a list with a reader missing is written")
	rows, ok = list_of_row(&list, 3, nil, nil, page)
	testing.expect(t, !ok && rows == 0, "a row with no wiring row gives a list")
	for value in page {
		testing.expect_value(t, value, 0)
	}
	testing.expect(t, !row_has_wirings(&list, 3))
	testing.expect(t, !row_has_wirings(&list, 0))
	testing.expect(t, row_has_wirings(&list, 2))
}

// The successes last: a row with no wiring row starts with no list and no
// lend; the writer lends its two readers once each and gets its three
// rows, the log among them, as the border of the root service reads them.
@(test)
a_writer_gets_the_list_of_its_rows :: proc(t: ^testing.T) {
	list := wired_list()
	page := make([]u8, PAGE_BYTES, context.temp_allocator)
	running := [4]bool{true, true, false, false}
	lends_reset(0)
	prepared := row_list_prepare(&list, 3, running[:], page, test_lend)
	testing.expect_value(t, prepared, Prepared{outcome = .No_List, status = .Ok})
	testing.expect_value(t, lend_count, 0)

	prepared = row_list_prepare(&list, 2, running[:], page, test_lend)
	testing.expect_value(t, prepared, Prepared{outcome = .Listed, status = .Ok})
	testing.expect_value(t, lend_count, 2)
	testing.expect_value(t, lent_readers[0], 0)
	testing.expect_value(t, lent_readers[1], 1)
	checked: output.Checked_Wiring_List
	refusal, ok := output.wiring_list_check(page, .Start, &checked)
	testing.expectf(t, ok, "the root service refuses the list: %v", refusal)
	testing.expect_value(t, checked.row_count, 3)
	testing.expect_value(t, checked.handle_count, 2)
	testing.expect_value(t, checked.handles[0], 11)
	testing.expect_value(t, checked.handles[1], 12)
	for place, index in ([3]u32{1, 2, 1}) {
		testing.expect_value(t, checked.rows[index].writer_end, output.Wiring_End.Child)
		testing.expect_value(t, checked.rows[index].reader_end, output.Wiring_End.Started)
		testing.expect_value(t, checked.rows[index].reader_handle, place)
	}
	testing.expect_value(t, checked.rows[2].writer_stream, output.Writer_Stream.Log)
}

// A row with terms: the page holds its terms after the lent handles, at
// the place that its row names, and the border of the root service takes
// the list; the rows with no terms name none.
@(test)
the_terms_of_a_row_follow_the_handles :: proc(t: ^testing.T) {
	list := wired_list(with_terms = true)
	page := make([]u8, PAGE_BYTES, context.temp_allocator)
	running := [4]bool{true, true, false, false}
	lends_reset(0)
	prepared := row_list_prepare(&list, 2, running[:], page, test_lend)
	testing.expect_value(t, prepared, Prepared{outcome = .Listed, status = .Ok})
	checked: output.Checked_Wiring_List
	refusal, ok := output.wiring_list_check(page, .Start, &checked)
	testing.expectf(t, ok, "the root service refuses the list: %v", refusal)
	terms_at := output.wiring_terms_start(3, 2)
	testing.expect_value(t, checked.rows[1].terms_offset, u32(terms_at))
	testing.expect_value(t, checked.rows[1].terms_count, u32(start_list.START_LIST_TERMS_BYTES))
	testing.expect_value(t, checked.rows[0].terms_count, u32(0))
	testing.expect_value(t, checked.rows[2].terms_count, u32(0))
	expected := test_terms()
	testing.expect(t, string(page[terms_at:][:start_list.START_LIST_TERMS_BYTES]) == string(expected[:]), "the terms on the page differ from the terms of the row")
	// A page too small for the terms: no list, and both numbers go back.
	lends_reset(0)
	small := make([]u8, terms_at + start_list.START_LIST_TERMS_BYTES - 1, context.temp_allocator)
	prepared = row_list_prepare(&list, 2, running[:], small, test_lend)
	testing.expect_value(t, prepared.outcome, Outcome.List_Not_Written)
}
