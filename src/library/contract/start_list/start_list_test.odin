#+build !freestanding
package start_list

import "base:intrinsics"
import "core:testing"

// A list of three rows that the border takes, and its bytes, for the cases
// that change one field.
@(private = "file")
three_rows :: proc() -> (rows: [3]Start_Row, bytes: [size_of(List_Header) + 3 * size_of(Row_Record)]u8) {
	first, first_made := row_make("input", {.Screen}, .Not_Started, .Not_Needed)
	second, second_made := row_make("console", {.Screen}, .Not_Started, .Needed, 2)
	third, third_made := row_make("date", {}, .Started_Anyway, .Not_Needed, RESTART_LIMIT)
	assert(first_made && second_made && third_made)
	rows = {first, second, third}
	_, written := list_write(rows[:], bytes[:])
	assert(written)
	return
}

// record_change copies the bytes of a list, changes one row with change,
// and gives the copy.
@(private = "file")
record_change :: proc(bytes: []u8, row: int, change: proc(record: ^Row_Record)) -> [size_of(List_Header) + 3 * size_of(Row_Record)]u8 {
	changed: [size_of(List_Header) + 3 * size_of(Row_Record)]u8
	copy(changed[:], bytes)
	record: Row_Record
	place := size_of(List_Header) + row * size_of(Row_Record)
	intrinsics.mem_copy_non_overlapping(&record, &changed[place], size_of(Row_Record))
	change(&record)
	intrinsics.mem_copy_non_overlapping(&changed[place], &record, size_of(Row_Record))
	return changed
}

// expect_refused reads bytes and checks the refusal: its problem, its row,
// and no row given.
@(private = "file")
expect_refused :: proc(t: ^testing.T, bytes: []u8, problem: List_Problem, place: int, loc := #caller_location) {
	rows: [ROW_CAPACITY]Start_Row
	count, read_problem, read_place := list_read(bytes, &rows)
	testing.expect_value(t, read_problem, problem, loc = loc)
	testing.expect_value(t, read_place, place, loc = loc)
	testing.expect_value(t, count, 0, loc = loc)
	testing.expect_value(t, rows, [ROW_CAPACITY]Start_Row{}, loc = loc)
}

// The header: no byte, one byte short of the header, another magic,
// version 0, one past the version, no row, one row past the capacity, the
// largest count, the rows that the header counts with one byte missing,
// and one byte after the rows. Each is refused whole.
@(test)
a_list_with_a_wrong_header_is_refused :: proc(t: ^testing.T) {
	_, bytes := three_rows()
	expect_refused(t, {}, .Too_Short, 0)
	expect_refused(t, bytes[:size_of(List_Header) - 1], .Too_Short, 0)
	header_change :: proc(bytes: []u8, change: proc(header: ^List_Header)) -> [size_of(List_Header) + 3 * size_of(Row_Record)]u8 {
		changed: [size_of(List_Header) + 3 * size_of(Row_Record)]u8
		copy(changed[:], bytes)
		header: List_Header
		intrinsics.mem_copy_non_overlapping(&header, &changed[0], size_of(List_Header))
		change(&header)
		intrinsics.mem_copy_non_overlapping(&changed[0], &header, size_of(List_Header))
		return changed
	}
	magic := header_change(bytes[:], proc(header: ^List_Header) {header.magic = LIST_MAGIC + 1})
	expect_refused(t, magic[:], .Wrong_Magic, 0)
	version_zero := header_change(bytes[:], proc(header: ^List_Header) {header.version = 0})
	expect_refused(t, version_zero[:], .Wrong_Version, 0)
	version_next := header_change(bytes[:], proc(header: ^List_Header) {header.version = LIST_VERSION + 1})
	expect_refused(t, version_next[:], .Wrong_Version, 0)
	no_row := header_change(bytes[:], proc(header: ^List_Header) {header.row_count = 0})
	expect_refused(t, no_row[:size_of(List_Header)], .No_Row, 0)
	too_many := header_change(bytes[:], proc(header: ^List_Header) {header.row_count = ROW_CAPACITY + 1})
	expect_refused(t, too_many[:], .Too_Many_Rows, 0)
	largest := header_change(bytes[:], proc(header: ^List_Header) {header.row_count = max(u32)})
	expect_refused(t, largest[:], .Too_Many_Rows, 0)
	expect_refused(t, bytes[:len(bytes) - 1], .Too_Short, 0)
	longer: [len(bytes) + 1]u8
	copy(longer[:], bytes[:])
	expect_refused(t, longer[:], .Bytes_After_Rows, 0)
}

// A row: a name of no byte, a name with a capital, a space or a byte past
// ASCII, a name of 32 bytes with no zero after it, a byte after the zero
// bytes, a bit of needs past the last part and the highest bit, a rule one
// past the last and the largest word, a mark one past Needed and the
// largest word, a reserved word that is not 0, one restart past the limit,
// and two rows of one module. The refusal names the row, and gives no row.
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
		{proc(record: ^Row_Record) {record.reserved = 1}, .Reserved_Not_Zero},
		{proc(record: ^Row_Record) {record.restart_count = RESTART_LIMIT + 1}, .Restarts_Past_Limit},
		{proc(record: ^Row_Record) {record.restart_count = max(u32)}, .Restarts_Past_Limit},
	}
	for case_of in cases {
		changed := record_change(bytes[:], 1, case_of.change)
		expect_refused(t, changed[:], case_of.problem, 1)
	}
	twice := record_change(bytes[:], 2, proc(record: ^Row_Record) {record.module_name = {}; copy(record.module_name[:], "input")})
	expect_refused(t, twice[:], .Name_Twice, 2)
}

// The writer of a row refuses a name that the border refuses: none, 32
// bytes, a capital, a dash.
@(test)
a_row_of_a_name_that_is_no_name_is_not_made :: proc(t: ^testing.T) {
	names := [?]string{"", "abcdefghijklmnopqrstuvwxyz012345", "Console", "start-policy"}
	for name in names {
		_, made := row_make(name, {}, .Not_Started, .Not_Needed)
		testing.expectf(t, !made, "the row of %q is made", name)
	}
	rows: [ROW_CAPACITY + 1]Start_Row
	output: [size_of(List_Header) + (ROW_CAPACITY + 1) * size_of(Row_Record)]u8
	_, written := list_write(rows[:], output[:])
	testing.expect(t, !written, "a list past the capacity is written")
	first, _ := row_make("input", {}, .Not_Started, .Not_Needed)
	one := [1]Start_Row{first}
	_, short_written := list_write(one[:], output[:size_of(List_Header) + size_of(Row_Record) - 1])
	testing.expect(t, !short_written, "a list is written into a room one byte short")
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
	for part in Machine_Part {
		parts, ok := parts_of_word(u64(1) << u64(part))
		testing.expect(t, ok)
		testing.expect_value(t, parts, Machine_Parts{part})
	}
}

// The lists that the border takes: one row, the capacity, the three rows,
// each with its fields as they were written. A rescue list needs a row
// with the mark Needed.
@(test)
a_written_list_reads_back :: proc(t: ^testing.T) {
	written, bytes := three_rows()
	rows: [ROW_CAPACITY]Start_Row
	count, problem, _ := list_read(bytes[:], &rows)
	testing.expect_value(t, problem, List_Problem.None)
	testing.expect_value(t, count, 3)
	for index in 0 ..< 3 {
		testing.expect_value(t, rows[index], written[index])
	}
	testing.expect_value(t, row_name(&rows[1]), "console")
	testing.expect(t, list_has_usable_row(rows[:count]))
	testing.expect(t, !list_has_usable_row(rows[:1]))
	full: [ROW_CAPACITY]Start_Row
	names: [ROW_CAPACITY][2]u8
	for &row, index in full {
		names[index] = {'a' + u8(index / 26), 'a' + u8(index % 26)}
		row, _ = row_make(string(names[index][:]), {}, .Not_Started, .Not_Needed)
	}
	output: [size_of(List_Header) + ROW_CAPACITY * size_of(Row_Record)]u8
	_, full_written := list_write(full[:], output[:])
	testing.expect(t, full_written)
	full_count, full_problem, _ := list_read(output[:], &rows)
	testing.expect_value(t, full_problem, List_Problem.None)
	testing.expect_value(t, full_count, ROW_CAPACITY)
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
