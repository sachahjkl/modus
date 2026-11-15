#+build !freestanding
package terminal_records

import "core:testing"

// The form of a hint line for a width: the long form when it fits, the
// short form when the long one does not, each cut to the width.
@(test)
hint_form_for_each_width :: proc(t: ^testing.T) {
	Case :: struct {
		long_count, short_count, columns: int,
		form:                             Hint_Form,
		shown:                            int,
	}
	cases := [?]Case {
		{60, 30, 104, .Long, 60}, // The long form fits.
		{104, 30, 104, .Long, 104}, // It fits exactly.
		{105, 30, 104, .Short, 30}, // One cell too long: the short form.
		{120, 50, 40, .Short, 40}, // Both too long: the short form, cut.
		{120, 0, 40, .Long, 40}, // No short form: the long form, cut.
		{0, 0, 40, .Long, 0}, // No hint.
		{50, 20, -3, .Short, 0}, // A width under zero shows nothing.
	}
	for item, index in cases {
		form, shown := hint_form_choose(item.long_count, item.short_count, item.columns)
		testing.expectf(t, form == item.form && shown == item.shown, "case %d: %v %d cells, not %v %d cells", index, form, shown, item.form, item.shown)
	}
}

// A record takes the start of a text that ends after a whole character:
// "é" is two bytes, and a cut between them moves before it.
@(test)
a_record_cuts_after_a_whole_character :: proc(t: ^testing.T) {
	testing.expect_value(t, record_part("café", 10), 5)
	testing.expect_value(t, record_part("café", 4), 3)
	testing.expect_value(t, record_part("café", 5), 5)
	testing.expect_value(t, record_part("é", 1), 0)
	testing.expect_value(t, record_part("abc", 0), 0)
	// A long text of "é": each record of RUN_LIMIT bytes takes whole characters.
	// "a", then 128 times "é": the byte RUN_LIMIT - 1 is the first byte of
	// the last "é".
	long: [RUN_LIMIT + 1]u8
	long[0] = 'a'
	for index := 1; index + 1 < len(long); index += 2 {
		long[index], long[index + 1] = 0xC3, 0xA9
	}
	testing.expect_value(t, record_part(string(long[:]), RUN_LIMIT), RUN_LIMIT - 1)
}

// A List with no rows of its own shows empty rows, not the rows of the list
// before; the rows of a list are forgotten when the program stops; each
// value of the program is brought inside its array.
@(test)
list_rows_go_to_one_list :: proc(t: ^testing.T) {
	keeping: List_Keeping
	name := "monitor.count"
	list_keep_row(&keeping, {0 = 0, 1 = 7, 2 = 1}, transmute([]u8)name, nil)
	list_keep_show(&keeping, {0 = 1, 1 = 0, 3 = 1})
	testing.expect_value(t, keeping.shown.row_count, 1)
	testing.expect_value(t, string(keeping.shown.rows[0].text[:keeping.shown.rows[0].length]), "monitor.count")
	testing.expect_value(t, keeping.shown.rows[0].name_length, 7)
	testing.expect_value(t, keeping.shown.chosen, 0)

	// A List of 8 rows with no List_Row before it.
	list_keep_show(&keeping, {0 = 8, 1 = NO_CHOICE})
	testing.expect_value(t, keeping.shown.row_count, LIST_ROWS)
	for row, index in keeping.shown.rows {
		testing.expectf(t, row.length == 0, "row %d of the second list is empty, not a row of the list before", index)
	}
	testing.expect_value(t, keeping.shown.chosen, -1)
}

// A row keeps the icon that its program names; a number that names no icon
// is no icon; a row with no icon after a row with one has none.
@(test)
list_row_keeps_the_icon_of_its_kind :: proc(t: ^testing.T) {
	keeping: List_Keeping
	name := "monitor"
	list_keep_row(&keeping, {0 = 0, 1 = 7, 4 = u64(List_Icon.Module)}, transmute([]u8)name, nil)
	list_keep_row(&keeping, {0 = 1, 1 = 7, 4 = u64(max(List_Icon)) + 1}, transmute([]u8)name, nil)
	list_keep_row(&keeping, {0 = 2, 1 = 7, 4 = max(u64)}, transmute([]u8)name, nil)
	list_keep_show(&keeping, {0 = 3, 1 = NO_CHOICE})
	testing.expect_value(t, keeping.shown.rows[0].icon, List_Icon.Module)
	testing.expect_value(t, keeping.shown.rows[1].icon, List_Icon.None)
	testing.expect_value(t, keeping.shown.rows[2].icon, List_Icon.None)
	list_keep_row(&keeping, {0 = 0, 1 = 7}, transmute([]u8)name, nil)
	list_keep_show(&keeping, {0 = 1, 1 = NO_CHOICE})
	testing.expect_value(t, keeping.shown.rows[0].icon, List_Icon.None)
}

@(test)
list_values_of_a_hostile_program :: proc(t: ^testing.T) {
	keeping: List_Keeping
	long: [RUN_LIMIT + 50]u8
	list_keep_row(&keeping, {0 = LIST_ROWS}, long[:], nil) // A row past the rows: not kept.
	list_keep_row(&keeping, {0 = 2, 1 = 1_000_000}, long[:10], long[:20])
	testing.expect_value(t, keeping.next[2].length, 30)
	testing.expect_value(t, keeping.next[2].name_length, 30)
	list_keep_show(&keeping, {0 = 1_000, 1 = 1_000, 2 = max(u64), 3 = 5, 4 = max(u64)})
	testing.expect_value(t, keeping.shown.row_count, LIST_ROWS)
	testing.expect_value(t, keeping.shown.chosen, -1)
	testing.expect_value(t, keeping.shown.total, LIST_ROWS)
	testing.expect_value(t, keeping.shown.first, 0)
	testing.expect_value(t, keeping.shown.anchor, RUN_LIMIT)
	list_keep_forget(&keeping)
	testing.expect_value(t, keeping.shown.row_count, 0)
	testing.expect_value(t, keeping.shown.rows[2].length, 0)
}

// A line longer than a record ends with the cut mark; a line that fits is
// the same text.
@(test)
record_text_of_a_long_line :: proc(t: ^testing.T) {
	buffer: [RUN_LIMIT]u8
	testing.expect_value(t, record_text("a short line", &buffer), "a short line")
	long: [RUN_LIMIT + 44]u8
	for &b in long {
		b = 'x'
	}
	text := record_text(string(long[:]), &buffer)
	testing.expect_value(t, len(text), RUN_LIMIT)
	// 44 dropped, 21 bytes of mark: 235 bytes stay, 65 are missing.
	testing.expect_value(t, text[235:], "... and 65 bytes more")
}
