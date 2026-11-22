#+build !freestanding
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
