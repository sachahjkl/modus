#+build !freestanding
#+build !modus
package text_model

import "core:testing"

// The cells of a row in the tests of the wrap by character: the width of
// the rows of the editor.
COLUMNS :: 80

// A text and its layout are large: each test takes them from the heap.
@(private = "file")
text_of :: proc(bytes: string) -> ^Text {
	text := new(Text)
	if len(bytes) > 0 {
		problem := text_insert(text, transmute([]u8)bytes)
		assert(problem == .None)
	}
	return text
}

@(private = "file")
string_of :: proc(text: ^Text) -> string {
	return string(text_bytes(text))
}

@(test)
an_empty_text_refuses_each_removal_and_each_move_stays_at_zero :: proc(t: ^testing.T) {
	text := text_of("")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, COLUMNS, .Character)
	testing.expect_value(t, layout.row_count, 1)
	testing.expect_value(t, layout.line_count, 1)
	testing.expect(t, !text_delete_before(text))
	testing.expect(t, !text_delete_after(text))
	for motion in Motion {
		caret_move(text, layout, motion, true, 10)
		testing.expect_value(t, text.caret, 0)
		testing.expect_value(t, text.anchor, 0)
	}
	testing.expect_value(t, text_length(text), 0)
}

@(test)
an_insert_that_is_not_text_is_refused_and_changes_nothing :: proc(t: ^testing.T) {
	text := text_of("ab")
	defer free(text)
	selection_set(text, 0, 1) // "a" selected: a refused insert keeps it.
	refused := [?]string {
		"\x00", // A control character.
		"\r", // The carriage return is a control character too.
		"\x1b[2J", // An escape.
		"\x7f", // Delete.
		"\xc2\x85", // U+0085, a control character in two bytes.
		"\xff", // No UTF-8 at all.
		"\xc3", // A sequence cut short.
		"\xc0\xaf", // An overlong form.
		"\xed\xa0\x80", // A surrogate.
		"\xf4\x90\x80\x80", // Above U+10FFFF.
		"a\x80", // A lone continuation byte after a good character.
	}
	for bytes in refused {
		testing.expect_value(t, text_insert(text, transmute([]u8)bytes), Edit_Problem.Not_Text)
		testing.expect_value(t, string_of(text), "ab")
		testing.expect_value(t, text.anchor, 0)
		testing.expect_value(t, text.caret, 1)
	}
	testing.expect_value(t, text_insert(text, nil), Edit_Problem.Empty)
	testing.expect_value(t, text_insert_character(text, 0x1b), Edit_Problem.Not_Text)
	testing.expect_value(t, text_insert_character(text, 0xD800), Edit_Problem.Not_Text)
	testing.expect_value(t, text_insert_character(text, 0x110000), Edit_Problem.Not_Text)
	testing.expect_value(t, text_insert_character(text, -1), Edit_Problem.Not_Text)
	testing.expect_value(t, string_of(text), "ab")
	// The line end and the tab are text of the editor.
	testing.expect_value(t, text_insert_character(text, LINE_END), Edit_Problem.None)
	testing.expect_value(t, text_insert_character(text, TAB), Edit_Problem.None)
	testing.expect_value(t, string_of(text), "\n\tb")
}

@(test)
an_insert_past_the_capacity_is_refused_whole :: proc(t: ^testing.T) {
	text := new(Text)
	defer free(text)
	full := make([]u8, TEXT_CAPACITY - 1)
	defer delete(full)
	for &value in full {
		value = 'x'
	}
	testing.expect_value(t, text_insert(text, full), Edit_Problem.None)
	// One byte fits: the bound. A character of two bytes does not.
	testing.expect_value(t, text_insert_character(text, 'é'), Edit_Problem.Too_Long)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY - 1)
	testing.expect_value(t, text_insert_character(text, 'y'), Edit_Problem.None)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY)
	// One past the bound.
	testing.expect_value(t, text_insert_character(text, 'z'), Edit_Problem.Too_Long)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY)
	// A selection makes room: a replace of one byte by one byte fits.
	selection_set(text, 0, 1)
	testing.expect_value(t, text_insert_character(text, 'w'), Edit_Problem.None)
	testing.expect_value(t, byte_at(text, 0), u8('w'))
	testing.expect_value(t, text_length(text), TEXT_CAPACITY)
}

@(test)
the_caret_at_zero_and_at_the_end :: proc(t: ^testing.T) {
	text := text_of("héllo")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, COLUMNS, .Character)
	// The end: Right and Delete do nothing, Backspace removes the last
	// character whole.
	testing.expect_value(t, text.caret, 6)
	caret_move(text, layout, .Right, false, 1)
	testing.expect_value(t, text.caret, 6)
	testing.expect(t, !text_delete_after(text))
	testing.expect(t, text_delete_before(text))
	testing.expect_value(t, string_of(text), "héll")
	layout_compute(layout, text, COLUMNS, .Character)
	// Zero: Left and Backspace do nothing; Right steps over the two bytes
	// of é.
	caret_move(text, layout, .Text_Start, false, 1)
	testing.expect_value(t, text.caret, 0)
	caret_move(text, layout, .Left, false, 1)
	testing.expect_value(t, text.caret, 0)
	testing.expect(t, !text_delete_before(text))
	caret_move(text, layout, .Right, false, 1)
	caret_move(text, layout, .Right, false, 1)
	testing.expect_value(t, text.caret, 3)
	caret_move(text, layout, .Left, false, 1)
	testing.expect_value(t, text.caret, 1)
	testing.expect(t, text_delete_after(text))
	testing.expect_value(t, string_of(text), "hll")
	// An insert in the middle moves the gap, and keeps the rest.
	testing.expect_value(t, text_insert_character(text, 'e'), Edit_Problem.None)
	testing.expect_value(t, string_of(text), "hell")
	testing.expect_value(t, text.caret, 2)
}

@(test)
a_place_from_outside_is_clamped_and_never_inside_a_character :: proc(t: ^testing.T) {
	text := text_of("aé€")
	defer free(text)
	selection_set(text, -5, 1_000_000)
	testing.expect_value(t, text.anchor, 0)
	testing.expect_value(t, text.caret, text_length(text))
	// Inside é (bytes 1 and 2), and inside € (bytes 3, 4 and 5).
	selection_set(text, 2, 5)
	testing.expect_value(t, text.anchor, 1)
	testing.expect_value(t, text.caret, 3)
	selection_set(text, max(int), min(int))
	testing.expect_value(t, text.anchor, text_length(text))
	testing.expect_value(t, text.caret, 0)
}

@(test)
a_selection_across_lines_with_shift_then_a_typed_character_replaces_it :: proc(t: ^testing.T) {
	text := text_of("first line\nsecond line")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, COLUMNS, .Character)
	testing.expect_value(t, layout.line_count, 2)
	testing.expect_value(t, text.caret, 22)
	// Shift with Up: the anchor stays at the end, the caret goes to the
	// same column of the first line, which is shorter: its end.
	caret_move(text, layout, .Up, true, 1)
	testing.expect_value(t, text.caret, 10)
	testing.expect_value(t, text.anchor, 22)
	testing.expect_value(t, selection_count(text), 12)
	first, last := selection(text)
	testing.expect_value(t, layout.rows[row_of(layout, first)].line, 0)
	testing.expect_value(t, layout.rows[row_of(layout, last)].line, 1)
	// Down with Shift goes back to the goal column, 11, not to column 10.
	caret_move(text, layout, .Down, true, 1)
	testing.expect_value(t, text.caret, 22)
	testing.expect_value(t, selection_count(text), 0)
	caret_move(text, layout, .Up, true, 1)
	caret_move(text, layout, .Line_Start, true, 1)
	testing.expect_value(t, text.caret, 0)
	testing.expect_value(t, text_insert_character(text, 'X'), Edit_Problem.None)
	testing.expect_value(t, string_of(text), "X")
	testing.expect_value(t, text.caret, 1)
	testing.expect_value(t, selection_count(text), 0)
}

@(test)
left_and_right_with_a_selection_and_no_shift_go_to_its_ends :: proc(t: ^testing.T) {
	text := text_of("abcdef")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, COLUMNS, .Character)
	selection_set(text, 4, 1)
	caret_move(text, layout, .Right, false, 1)
	testing.expect_value(t, text.caret, 4)
	testing.expect_value(t, text.anchor, 4)
	selection_set(text, 4, 1)
	caret_move(text, layout, .Left, false, 1)
	testing.expect_value(t, text.caret, 1)
	testing.expect_value(t, text.anchor, 1)
	// Backspace and Delete with a selection remove it, and no more.
	selection_set(text, 1, 3)
	testing.expect(t, text_delete_before(text))
	testing.expect_value(t, string_of(text), "adef")
	selection_set(text, 3, 1)
	testing.expect(t, text_delete_after(text))
	testing.expect_value(t, string_of(text), "af")
	testing.expect_value(t, text.caret, 1)
}

@(test)
a_line_longer_than_the_window_goes_on_more_rows :: proc(t: ^testing.T) {
	text := new(Text)
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	long: [2 * COLUMNS + 3]u8
	for &value in long {
		value = 'x'
	}
	testing.expect_value(t, text_insert(text, long[:]), Edit_Problem.None)
	layout_compute(layout, text, COLUMNS, .Character)
	testing.expect_value(t, layout.row_count, 3)
	testing.expect_value(t, layout.line_count, 1)
	testing.expect_value(t, layout.rows[1], Row{start = COLUMNS, line = 0})
	testing.expect_value(t, layout.rows[2], Row{start = 2 * COLUMNS, line = 0})
	testing.expect(t, row_first_of_line(layout, 0))
	testing.expect(t, !row_first_of_line(layout, 1))
	// The place at a wrap is on the row after it, at column 0.
	testing.expect_value(t, row_of(layout, COLUMNS), 1)
	testing.expect_value(t, column_of(layout, text, 1, COLUMNS), 0)
	testing.expect_value(t, row_of(layout, COLUMNS - 1), 0)
	testing.expect_value(t, column_of(layout, text, 0, COLUMNS - 1), COLUMNS - 1)
	// The caret on a row that continues ends before its last character.
	testing.expect_value(t, row_end(layout, text, 0), COLUMNS - 1)
	testing.expect_value(t, place_at_column(layout, text, 0, COLUMNS + 50), COLUMNS - 1)
	testing.expect_value(t, place_at_column(layout, text, 0, -3), 0)
	// Home and End go to the ends of the line, not of the row.
	text.caret, text.anchor = COLUMNS + 5, COLUMNS + 5
	caret_move(text, layout, .Line_Start, false, 1)
	testing.expect_value(t, text.caret, 0)
	caret_move(text, layout, .Line_End, false, 1)
	testing.expect_value(t, text.caret, len(long))
	// A row of exactly COLUMNS cells then a line end: the caret before the
	// line end is on that row, at column COLUMNS.
	full := new(Text)
	defer free(full)
	testing.expect_value(t, text_insert(full, long[:COLUMNS]), Edit_Problem.None)
	testing.expect_value(t, text_insert_character(full, LINE_END), Edit_Problem.None)
	layout_compute(layout, full, COLUMNS, .Character)
	testing.expect_value(t, layout.row_count, 2)
	testing.expect_value(t, row_of(layout, COLUMNS), 0)
	testing.expect_value(t, column_of(layout, full, 0, COLUMNS), COLUMNS)
	testing.expect_value(t, row_end(layout, full, 0), COLUMNS)
}

@(test)
a_tab_goes_to_the_next_stop_and_never_past_the_row :: proc(t: ^testing.T) {
	text := new(Text)
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	testing.expect_value(t, text_insert(text, transmute([]u8)string("a\tb")), Edit_Problem.None)
	layout_compute(layout, text, COLUMNS, .Character)
	testing.expect_value(t, column_of(layout, text, 0, 2), TAB_WIDTH)
	// COLUMNS - 1 characters, then a tab: the tab takes the last cell, and
	// the next character is on a new row.
	wide := new(Text)
	defer free(wide)
	for _ in 0 ..< COLUMNS - 1 {
		text_insert_character(wide, 'x')
	}
	text_insert_character(wide, TAB)
	text_insert_character(wide, 'y')
	layout_compute(layout, wide, COLUMNS, .Character)
	testing.expect_value(t, layout.row_count, 2)
	testing.expect_value(t, int(layout.rows[1].start), COLUMNS)
}

@(test)
the_worst_text_for_the_rows_fits_their_capacity :: proc(t: ^testing.T) {
	// Only line ends: one row for each byte, and one more.
	text := new(Text)
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	ends := make([]u8, TEXT_CAPACITY)
	defer delete(ends)
	for &value in ends {
		value = LINE_END
	}
	testing.expect_value(t, text_insert(text, ends), Edit_Problem.None)
	layout_compute(layout, text, COLUMNS, .Character)
	testing.expect_value(t, layout.row_count, ROW_CAPACITY)
	testing.expect_value(t, layout.line_count, TEXT_CAPACITY + 1)
	testing.expect_value(t, row_of(layout, TEXT_CAPACITY), ROW_CAPACITY - 1)
	// Only tabs: each full row holds COLUMNS / TAB_WIDTH of them, and the
	// last row holds the rest.
	tabs := new(Text)
	defer free(tabs)
	for &value in ends {
		value = TAB
	}
	testing.expect_value(t, text_insert(tabs, ends), Edit_Problem.None)
	layout_compute(layout, tabs, COLUMNS, .Character)
	TABS_IN_A_ROW :: COLUMNS / TAB_WIDTH
	testing.expect_value(t, layout.row_count, (TEXT_CAPACITY + TABS_IN_A_ROW - 1) / TABS_IN_A_ROW)
	testing.expect_value(t, layout.line_count, 1)
}

@(test)
a_text_from_a_store_with_invalid_sequences_gets_the_replacement_character :: proc(t: ^testing.T) {
	target: [64]u8
	source := "a\xffb\x00c\r\n\td\xc3"
	count, replaced, problem := text_clean(transmute([]u8)source, target[:])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, replaced, 4)
	testing.expect_value(t, string(target[:count]), "a�b�c�\n\td�")
	testing.expect(t, text_valid(target[:count]))
	// A target with no room for the replacement refuses the whole text.
	small: [3]u8
	count, replaced, problem = text_clean(transmute([]u8)string("a\xff"), small[:])
	testing.expect_value(t, problem, Edit_Problem.Too_Long)
	testing.expect_value(t, count, 0)
	// An empty text is a text.
	count, replaced, problem = text_clean(nil, small[:])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, replaced, 0)
}

@(test)
a_whole_replace_refuses_what_is_not_text_and_puts_the_caret_after_the_change :: proc(t: ^testing.T) {
	text := text_of("first line\nsecond line")
	defer free(text)
	testing.expect_value(t, text_replace_whole(text, transmute([]u8)string("bad\x00")), Edit_Problem.Not_Text)
	testing.expect_value(t, string_of(text), "first line\nsecond line")
	// Undo of the last word: the caret at the end of what is left.
	testing.expect_value(t, text_replace_whole(text, transmute([]u8)string("first line\nsecond ")), Edit_Problem.None)
	testing.expect_value(t, text.caret, 18)
	// Redo: the caret after the word that came back.
	testing.expect_value(t, text_replace_whole(text, transmute([]u8)string("first line\nsecond line")), Edit_Problem.None)
	testing.expect_value(t, text.caret, 22)
	// A change in the middle: the caret after it, not at the end.
	testing.expect_value(t, text_replace_whole(text, transmute([]u8)string("first word\nsecond line")), Edit_Problem.None)
	testing.expect_value(t, text.caret, 10)
	// é to è: the bytes differ inside one character, the caret is after
	// the whole character, never inside it.
	accents := text_of("é")
	defer free(accents)
	testing.expect_value(t, text_replace_whole(accents, transmute([]u8)string("è")), Edit_Problem.None)
	testing.expect_value(t, accents.caret, 2)
	// To an empty text.
	testing.expect_value(t, text_replace_whole(accents, nil), Edit_Problem.None)
	testing.expect_value(t, accents.caret, 0)
	testing.expect_value(t, text_length(accents), 0)
}

@(test)
a_change_of_kind_and_a_word_end_end_a_group :: proc(t: ^testing.T) {
	testing.expect(t, !group_ends_before(.None, .Insert))
	testing.expect(t, !group_ends_before(.None, .Delete))
	testing.expect(t, !group_ends_before(.Insert, .Insert))
	testing.expect(t, group_ends_before(.Insert, .Delete))
	testing.expect(t, group_ends_before(.Delete, .Insert))
	testing.expect(t, character_ends_group(' '))
	testing.expect(t, character_ends_group(LINE_END))
	testing.expect(t, character_ends_group(TAB))
	testing.expect(t, !character_ends_group('a'))
}

@(test)
undo_past_the_first_change_is_refused_and_the_walk_does_not_move :: proc(t: ^testing.T) {
	walk: Version_Walk
	_, problem := walk_back(&walk, nil)
	testing.expect_value(t, problem, Walk_Problem.No_Version)
	// One version only: the first commit has nothing before it.
	_, problem = walk_back(&walk, {7})
	testing.expect_value(t, problem, Walk_Problem.No_Older_Version)
	_, problem = walk_forward(&walk)
	testing.expect_value(t, problem, Walk_Problem.No_Newer_Version)
	testing.expect_value(t, walk, Version_Walk{})
	// A list out of order, or with a generation below 1, is refused whole.
	_, problem = walk_back(&walk, {3, 5, 4})
	testing.expect_value(t, problem, Walk_Problem.Not_In_Order)
	_, problem = walk_back(&walk, {3, 3})
	testing.expect_value(t, problem, Walk_Problem.Not_In_Order)
	_, problem = walk_back(&walk, {0, 4})
	testing.expect_value(t, problem, Walk_Problem.Not_In_Order)
	_, problem = walk_back(&walk, {-2, 4})
	testing.expect_value(t, problem, Walk_Problem.Not_In_Order)
	testing.expect_value(t, walk, Version_Walk{})
}

@(test)
undo_and_redo_walk_the_versions_and_a_change_ends_the_redo :: proc(t: ^testing.T) {
	walk: Version_Walk
	// Four commits: 10, 11, 12, 13. Ctrl+Z from the current one.
	step, problem := walk_back(&walk, {10, 11, 12, 13})
	testing.expect_value(t, problem, Walk_Problem.None)
	testing.expect_value(t, step, Walk_Step{from = 13, to = 12})
	walk_went_back(&walk, step)
	// The restore made the commit 14, with the text of 12: the next Ctrl+Z
	// goes back from 12, not from 14.
	step, problem = walk_back(&walk, {10, 11, 12, 13, 14})
	testing.expect_value(t, step, Walk_Step{from = 12, to = 11})
	walk_went_back(&walk, step)
	// Ctrl+Y goes forward along the two steps, the newest first.
	step, problem = walk_forward(&walk)
	testing.expect_value(t, step, Walk_Step{from = 11, to = 12})
	walk_went_forward(&walk, step)
	step, problem = walk_forward(&walk)
	testing.expect_value(t, step, Walk_Step{from = 12, to = 13})
	walk_went_forward(&walk, step)
	_, problem = walk_forward(&walk)
	testing.expect_value(t, problem, Walk_Problem.No_Newer_Version)
	// Back to the first version, then one more is refused.
	for _ in 0 ..< 3 {
		step, problem = walk_back(&walk, {10, 11, 12, 13, 14, 15, 16})
		testing.expect_value(t, problem, Walk_Problem.None)
		walk_went_back(&walk, step)
	}
	testing.expect_value(t, walk.shown, 10)
	before := walk
	_, problem = walk_back(&walk, {10, 11, 12, 13, 14, 15, 16, 17, 18, 19})
	testing.expect_value(t, problem, Walk_Problem.No_Older_Version)
	testing.expect_value(t, walk, before)
	// A change: Ctrl+Y has nothing, and Ctrl+Z starts from the current one.
	walk_changed(&walk)
	_, problem = walk_forward(&walk)
	testing.expect_value(t, problem, Walk_Problem.No_Newer_Version)
	step, _ = walk_back(&walk, {10, 20, 21})
	testing.expect_value(t, step, Walk_Step{from = 21, to = 20})
}

@(test)
a_full_forward_list_forgets_its_oldest_step :: proc(t: ^testing.T) {
	walk: Version_Walk
	for index in 0 ..< WALK_FORWARD_CAPACITY + 2 {
		walk_went_back(&walk, {from = i64(1000 - index), to = i64(999 - index)})
	}
	testing.expect_value(t, walk.forward_count, WALK_FORWARD_CAPACITY)
	testing.expect_value(t, walk.forgotten, 2)
	testing.expect_value(t, walk.forward[0], i64(998))
	step, _ := walk_forward(&walk)
	testing.expect_value(t, step.to, i64(1000 - (WALK_FORWARD_CAPACITY + 1)))
}

// Simulated uncommitted-reservation arena for testing in-place growth and
// exact budget refusal in host tests.
@(private = "file")
Test_Reservation :: struct {
	backing:    []u8,
	committed:  int,
	budget_cap: int,
}

@(private = "file")
test_bytes_grow :: proc "contextless" (user_data: rawptr, current: []u8, minimum_bytes: int) -> (grown: []u8, ok: bool) {
	res := (^Test_Reservation)(user_data)
	if minimum_bytes > res.budget_cap || minimum_bytes > len(res.backing) {
		return nil, false
	}
	target := max(res.committed * 2, 4096)
	for target < minimum_bytes {
		target *= 2
	}
	target = min(target, res.budget_cap, len(res.backing))
	res.committed = target
	return res.backing[:target], true
}

@(private = "file")
test_rows_grow :: proc "contextless" (user_data: rawptr, current: []Row, minimum_rows: int) -> (grown: []Row, ok: bool) {
	res := (^Test_Reservation)(user_data)
	needed_bytes := minimum_rows * size_of(Row)
	if needed_bytes > res.budget_cap || needed_bytes > len(res.backing) {
		return nil, false
	}
	target_rows := max(len(current) * 2, 1024)
	for target_rows < minimum_rows {
		target_rows *= 2
	}
	max_rows := min(res.budget_cap, len(res.backing)) / size_of(Row)
	target_rows = min(target_rows, max_rows)
	res.committed = target_rows * size_of(Row)
	return ([^]Row)(raw_data(res.backing))[:target_rows], true
}

@(private = "file")
test_matches_grow :: proc "contextless" (user_data: rawptr, current: []i32, minimum_matches: int) -> (grown: []i32, ok: bool) {
	res := (^Test_Reservation)(user_data)
	needed_bytes := minimum_matches * size_of(i32)
	if needed_bytes > res.budget_cap || needed_bytes > len(res.backing) {
		return nil, false
	}
	target := max(len(current) * 2, 1024)
	for target < minimum_matches {
		target *= 2
	}
	max_items := min(res.budget_cap, len(res.backing)) / size_of(i32)
	target = min(target, max_items)
	res.committed = target * size_of(i32)
	return ([^]i32)(raw_data(res.backing))[:target], true
}

@(test)
caller_backed_text_handles_over_64kib_and_refuses_past_budget :: proc(t: ^testing.T) {
	BUDGET :: 160 * 1024
	backing := make([]u8, 256 * 1024)
	defer delete(backing)
	res := Test_Reservation{backing = backing, committed = 16 * 1024, budget_cap = BUDGET}

	text := new(Text)
	defer free(text)
	text_init_buffer(text, backing[:res.committed], test_bytes_grow, &res)

	// Insert 100 KiB (well past TEXT_CAPACITY = 32 KiB and > 64 KiB).
	chunk := make([]u8, 100 * 1024)
	defer delete(chunk)
	for i in 0 ..< len(chunk) {
		chunk[i] = i % 64 == 63 ? '\n' : u8('a' + (i % 26))
	}
	testing.expect_value(t, text_insert(text, chunk), Edit_Problem.None)
	testing.expect_value(t, text_length(text), 100 * 1024)

	// Move gap to the middle and insert another 40 KiB across the gap.
	selection_set(text, 50 * 1024, 50 * 1024)
	mid := make([]u8, 40 * 1024)
	defer delete(mid)
	for &b in mid {
		b = 'Z'
	}
	testing.expect_value(t, text_insert(text, mid), Edit_Problem.None)
	testing.expect_value(t, text_length(text), 140 * 1024)
	testing.expect_value(t, byte_at(text, 50 * 1024), u8('Z'))
	testing.expect_value(t, byte_at(text, 90 * 1024 - 1), u8('Z'))
	testing.expect_value(t, byte_at(text, 90 * 1024), chunk[50 * 1024])

	// Selection copy spanning the gap at >64 KiB offsets.
	selection_set(text, 50 * 1024 - 4, 90 * 1024 + 4)
	copied := make([]u8, 40 * 1024 + 8)
	defer delete(copied)
	n, cp := selection_copy(text, copied)
	testing.expect_value(t, cp, Edit_Problem.None)
	testing.expect_value(t, n, 40 * 1024 + 8)
	testing.expect_value(t, copied[4], u8('Z'))
	testing.expect_value(t, copied[len(copied) - 5], u8('Z'))

	// Exact budget bound succeeds; 1 byte past budget is refused without changing text or selection.
	remaining := BUDGET - text_length(text)
	fill := make([]u8, remaining)
	defer delete(fill)
	for &b in fill {
		b = 'q'
	}
	selection_set(text, text_length(text), text_length(text))
	testing.expect_value(t, text_insert(text, fill), Edit_Problem.None)
	testing.expect_value(t, text_length(text), BUDGET)

	selection_set(text, 10, 10)
	testing.expect_value(t, text_insert_character(text, 'x'), Edit_Problem.Too_Long)
	testing.expect_value(t, text_length(text), BUDGET)
	testing.expect_value(t, text.caret, 10)
	testing.expect_value(t, text.anchor, 10)

	// text_replace_whole past budget is refused and keeps previous text intact.
	too_big := make([]u8, BUDGET + 1)
	defer delete(too_big)
	for &b in too_big {
		b = 'b'
	}
	testing.expect_value(t, text_replace_whole(text, too_big), Edit_Problem.Too_Long)
	testing.expect_value(t, text_length(text), BUDGET)
}

@(test)
caller_backed_layout_and_search_handle_over_64kib_and_refuse_past_budget :: proc(t: ^testing.T) {
	// 70 000 newlines -> 70 001 display rows and 70 000 single-byte matches.
	COUNT :: 70_000
	text_backing := make([]u8, 128 * 1024)
	defer delete(text_backing)
	text_res := Test_Reservation{backing = text_backing, committed = 16 * 1024, budget_cap = 128 * 1024}
	text := new(Text)
	defer free(text)
	text_init_buffer(text, text_backing[:text_res.committed], test_bytes_grow, &text_res)

	lines := make([]u8, COUNT * 2)
	defer delete(lines)
	for i in 0 ..< COUNT {
		lines[i * 2] = 'a'
		lines[i * 2 + 1] = '\n'
	}
	// Grow text_res budget to hold 140 000 bytes.
	text_res.budget_cap = len(text_backing)
	// Use 256 KiB backing so 140 000 bytes fits.
	text_backing_big := make([]u8, 256 * 1024)
	defer delete(text_backing_big)
	text_res_big := Test_Reservation{backing = text_backing_big, committed = 16 * 1024, budget_cap = 256 * 1024}
	text_init_buffer(text, text_backing_big[:text_res_big.committed], test_bytes_grow, &text_res_big)
	testing.expect_value(t, text_insert(text, lines), Edit_Problem.None)
	testing.expect_value(t, text_length(text), COUNT * 2)

	// Layout with tight row budget refuses cleanly with Rows_Full.
	small_row_bytes := make([]u8, 4096 * size_of(Row))
	defer delete(small_row_bytes)
	small_row_res := Test_Reservation{backing = small_row_bytes, committed = 1024 * size_of(Row), budget_cap = 2048 * size_of(Row)}
	layout := new(Layout)
	defer free(layout)
	layout_init_buffer(layout, ([^]Row)(raw_data(small_row_bytes))[:1024], test_rows_grow, &small_row_res)
	testing.expect_value(t, layout_compute(layout, text, COLUMNS, .Character), Layout_Problem.Rows_Full)
	testing.expect_value(t, layout.row_count, 2048)

	// Layout with sufficient row budget computes all 70 001 rows.
	big_row_bytes := make([]u8, 80_000 * size_of(Row))
	defer delete(big_row_bytes)
	big_row_res := Test_Reservation{backing = big_row_bytes, committed = 1024 * size_of(Row), budget_cap = 80_000 * size_of(Row)}
	layout_init_buffer(layout, ([^]Row)(raw_data(big_row_bytes))[:1024], test_rows_grow, &big_row_res)
	testing.expect_value(t, layout_compute(layout, text, COLUMNS, .Character), Layout_Problem.None)
	testing.expect_value(t, layout.row_count, COUNT + 1)
	testing.expect_value(t, layout.line_count, COUNT + 1)
	testing.expect_value(t, row_of(layout, COUNT * 2), COUNT)

	// Search with tight match budget truncates cleanly without writing out of bounds.
	small_match_bytes := make([]u8, 1024 * size_of(i32))
	defer delete(small_match_bytes)
	small_match_res := Test_Reservation{backing = small_match_bytes, committed = 512 * size_of(i32), budget_cap = 1024 * size_of(i32)}
	search := new(Search)
	defer free(search)
	search_init_buffer(search, ([^]i32)(raw_data(small_match_bytes))[:512], test_matches_grow, &small_match_res)
	search_open(search, text)
	testing.expect_value(t, search_query_set(search, text, transmute([]u8)string("a")), Edit_Problem.None)
	testing.expect(t, search.matches_truncated)
	testing.expect_value(t, search.match_count, 1024)

	// Search with sufficient match budget finds all 70 000 matches.
	big_match_bytes := make([]u8, 80_000 * size_of(i32))
	defer delete(big_match_bytes)
	big_match_res := Test_Reservation{backing = big_match_bytes, committed = 1024 * size_of(i32), budget_cap = 80_000 * size_of(i32)}
	search_init_buffer(search, ([^]i32)(raw_data(big_match_bytes))[:1024], test_matches_grow, &big_match_res)
	search_open(search, text)
	testing.expect_value(t, search_query_set(search, text, transmute([]u8)string("a")), Edit_Problem.None)
	testing.expect(t, !search.matches_truncated)
	testing.expect_value(t, search.match_count, COUNT)
	testing.expect_value(t, search.matches[COUNT - 1], i32((COUNT - 1) * 2))
}

// The length that text_clean writes, known before the copy: each case gives
// the count of text_clean, and a target one byte short is refused whole.
@(test)
the_clean_length_is_the_count_of_the_clean_copy :: proc(t: ^testing.T) {
	cases := [?]string{"", "a", "a\nb\tc", "\xff", "\x00\x1b", "é\xc3", "\xed\xa0\x80x", "€€\x7f"}
	target: [64]u8
	for source in cases {
		bytes := transmute([]u8)source
		count, _, problem := text_clean(bytes, target[:])
		testing.expect_value(t, problem, Edit_Problem.None)
		testing.expect_value(t, text_clean_length(bytes), count)
		if count > 0 {
			short, _, short_problem := text_clean(bytes, target[:count - 1])
			testing.expect_value(t, short_problem, Edit_Problem.Too_Long)
			testing.expect_value(t, short, 0)
		}
	}
}

@(test)
inline_to_external_tier_crossing_and_counter :: proc(t: ^testing.T) {
	// Start with nil external buffer + grow callback (the edit/notes path):
	// documents up to TEXT_CAPACITY (32 KiB) stay on the inline fast path with
	// zero tier moves; 1 byte past TEXT_CAPACITY crosses to external_bytes and
	// increments tier_moves.
	BUDGET :: 128 * 1024
	backing := make([]u8, BUDGET)
	defer delete(backing)
	res := Test_Reservation{backing = backing, committed = 0, budget_cap = BUDGET}

	text := new(Text)
	defer free(text)
	text_init_buffer(text, nil, test_bytes_grow, &res)

	exact := make([]u8, TEXT_CAPACITY)
	defer delete(exact)
	for i in 0 ..< len(exact) {
		exact[i] = u8('a' + (i % 26))
	}
	testing.expect_value(t, text_insert(text, exact), Edit_Problem.None)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY)
	testing.expect_value(t, len(text.external_bytes), 0)
	testing.expect_value(t, text.tier_moves, u64(0))
	testing.expect_value(t, text_capacity(text), TEXT_CAPACITY)

	// Move gap to the middle while still on inline tier, then insert 1 byte to cross 32 KiB + 1.
	selection_set(text, 1000, 1000)
	testing.expect_value(t, text_insert_character(text, '!'), Edit_Problem.None)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY + 1)
	testing.expect(t, len(text.external_bytes) >= TEXT_CAPACITY + 1)
	testing.expect_value(t, text.tier_moves, u64(1))
	testing.expect_value(t, byte_at(text, 999), exact[999])
	testing.expect_value(t, byte_at(text, 1000), u8('!'))
	testing.expect_value(t, byte_at(text, 1001), exact[1000])
	testing.expect_value(t, byte_at(text, TEXT_CAPACITY), exact[TEXT_CAPACITY - 1])

	// Next tier growth: insert 64 KiB more to cross 64 KiB -> 128 KiB.
	extra := make([]u8, 64 * 1024)
	defer delete(extra)
	for &b in extra {
		b = 'K'
	}
	testing.expect_value(t, text_insert(text, extra), Edit_Problem.None)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY + 1 + 64 * 1024)
	testing.expect_value(t, text.tier_moves, u64(2))

	// Refusal past budget leaves text length and tier_moves unchanged.
	too_much := make([]u8, BUDGET)
	defer delete(too_much)
	for &b in too_much {
		b = 'x'
	}
	before_len := text_length(text)
	before_moves := text.tier_moves
	testing.expect_value(t, text_insert(text, too_much), Edit_Problem.Too_Long)
	testing.expect_value(t, text_length(text), before_len)
	testing.expect_value(t, text.tier_moves, before_moves)

	// Layout and Search start on inline tier and count their crossing past ROW_CAPACITY / MATCH_CAPACITY.
	lines_count :: TEXT_CAPACITY + 2
	lines := make([]u8, lines_count)
	defer delete(lines)
	for &b in lines {
		b = '\n'
	}
	testing.expect_value(t, text_replace_whole(text, lines), Edit_Problem.None)

	row_backing := make([]u8, 80_000 * size_of(Row))
	defer delete(row_backing)
	row_res := Test_Reservation{backing = row_backing, committed = 0, budget_cap = len(row_backing)}
	layout := new(Layout)
	defer free(layout)
	layout_init_buffer(layout, nil, test_rows_grow, &row_res)
	testing.expect_value(t, layout_compute(layout, text, COLUMNS, .Character), Layout_Problem.None)
	testing.expect_value(t, layout.row_count, lines_count + 1)
	testing.expect(t, layout.tier_moves >= 1)

	match_backing := make([]u8, 80_000 * size_of(i32))
	defer delete(match_backing)
	match_res := Test_Reservation{backing = match_backing, committed = 0, budget_cap = len(match_backing)}
	search := new(Search)
	defer free(search)
	search_init_buffer(search, nil, test_matches_grow, &match_res)
	search_open(search, text)
	for &b in lines {
		b = 'a'
	}
	testing.expect_value(t, text_replace_whole(text, lines), Edit_Problem.None)
	testing.expect_value(t, search_query_set(search, text, transmute([]u8)string("a")), Edit_Problem.None)
	testing.expect(t, !search.matches_truncated)
	testing.expect_value(t, search.match_count, lines_count)
	testing.expect(t, search.tier_moves >= 1)
}
