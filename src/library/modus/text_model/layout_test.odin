#+build !freestanding
#+build !modus
package text_model

import "core:testing"

@(private = "file")
text_with :: proc(bytes: string) -> ^Text {
	text := new(Text)
	if len(bytes) > 0 {
		problem := text_insert(text, transmute([]u8)bytes)
		assert(problem == .None)
	}
	return text
}

@(private = "file")
row_starts :: proc(layout: ^Layout, into: []i32) -> []i32 {
	count := min(layout.row_count, len(into))
	for index in 0 ..< count {
		into[index] = layout.rows[index].start
	}
	return into[:count]
}

@(test)
a_width_out_of_range_and_an_unknown_wrap_are_refused_and_keep_the_rows :: proc(t: ^testing.T) {
	text := text_with("one two three")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	testing.expect_value(t, layout_compute(layout, text, 9, .Word), Layout_Problem.None)
	row_count_before, second_row_before := layout.row_count, layout.rows[1]
	for columns in ([?]int{min(int), -1, 0, 1, COLUMNS_LEAST - 1, COLUMNS_LIMIT + 1, max(int)}) {
		testing.expect_value(t, layout_compute(layout, text, columns, .Word), Layout_Problem.Columns_Out_Of_Range)
		testing.expect_value(t, layout.row_count, row_count_before)
		testing.expect_value(t, layout.columns, 9)
	}
	testing.expect_value(t, layout_compute(layout, text, 9, Wrap(2)), Layout_Problem.Wrap_Unknown)
	testing.expect_value(t, layout_compute(layout, text, 9, Wrap(255)), Layout_Problem.Wrap_Unknown)
	testing.expect_value(t, layout.row_count, row_count_before)
	testing.expect_value(t, layout.rows[1], second_row_before)
	testing.expect_value(t, layout.wrap, Wrap.Word)
}

@(test)
the_least_and_the_largest_widths_are_taken :: proc(t: ^testing.T) {
	// A tab at the least width fills its row: each row holds one byte or
	// more, so no row is empty.
	text := text_with("\t\t\tab")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	testing.expect_value(t, layout_compute(layout, text, COLUMNS_LEAST, .Word), Layout_Problem.None)
	// Each tab fills a row; "ab" moves whole after the last tab.
	starts: [8]i32
	testing.expect_value(t, len(row_starts(layout, starts[:])), 4)
	testing.expect_value(t, layout.rows[1].start, i32(1))
	testing.expect_value(t, layout.rows[2].start, i32(2))
	testing.expect_value(t, layout.rows[3].start, i32(3))
	testing.expect_value(t, layout_compute(layout, text, COLUMNS_LIMIT, .Character), Layout_Problem.None)
	testing.expect_value(t, layout.row_count, 1)
	testing.expect_value(t, layout.columns, COLUMNS_LIMIT)
}

@(test)
a_word_that_does_not_fit_goes_whole_to_the_next_row :: proc(t: ^testing.T) {
	text := text_with("one two three")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, 9, .Word)
	starts: [8]i32
	testing.expect_value(t, len(row_starts(layout, starts[:])), 2)
	testing.expect_value(t, layout.rows[1], Row{start = 8, line = 0})
	// The first row ends at its last space: the caret there is before
	// the space, and the place after it is the first place of the next row.
	testing.expect_value(t, row_end(layout, text, 0), 7)
	testing.expect_value(t, row_of(layout, 8), 1)
	// The same text wrapped by character cuts the word.
	layout_compute(layout, text, 9, .Character)
	testing.expect_value(t, layout.rows[1], Row{start = 9, line = 0})
}

@(test)
a_space_that_does_not_fit_starts_the_next_row :: proc(t: ^testing.T) {
	text := text_with("hello world again")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, 11, .Word)
	testing.expect_value(t, layout.row_count, 2)
	testing.expect_value(t, layout.rows[1], Row{start = 11, line = 0})
}

@(test)
a_word_longer_than_a_row_is_cut_by_character :: proc(t: ^testing.T) {
	text := text_with("ab abcdefgh")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, 4, .Word)
	starts: [8]i32
	got := row_starts(layout, starts[:])
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[1], i32(3))
	testing.expect_value(t, got[2], i32(7))
}

@(test)
a_word_after_a_tab_moves_and_the_lines_keep_their_numbers :: proc(t: ^testing.T) {
	text := text_with("a\tb\nsecond line here")
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	layout_compute(layout, text, 6, .Word)
	// "a", a tab to the column 4, then "b" fits: one row. The second line
	// "second line here": "second" fills 6 cells, the space starts a row,
	// then " line " and "here".
	testing.expect_value(t, layout.line_count, 2)
	testing.expect_value(t, layout.rows[0], Row{start = 0, line = 0})
	testing.expect_value(t, layout.rows[1], Row{start = 4, line = 1})
	testing.expect_value(t, layout.rows[2], Row{start = 10, line = 1})
	testing.expect_value(t, layout.rows[3], Row{start = 16, line = 1})
	testing.expect_value(t, layout.row_count, 4)
	// Down from the first row of the second line keeps the goal column.
	text.caret, text.anchor = 6, 6
	caret_move(text, layout, .Down, false, 1)
	testing.expect_value(t, row_of(layout, text.caret), 2)
}

@(test)
the_rows_of_a_full_text_of_words_stay_in_their_capacity :: proc(t: ^testing.T) {
	text := new(Text)
	defer free(text)
	// The worst text for the rows: a space and a letter, again and again,
	// at the least width.
	pattern := " a"
	for text_length(text) + len(pattern) <= TEXT_CAPACITY {
		text_insert(text, transmute([]u8)pattern)
	}
	layout := new(Layout)
	defer free(layout)
	testing.expect_value(t, layout_compute(layout, text, COLUMNS_LEAST, .Word), Layout_Problem.None)
	testing.expect(t, layout.row_count <= ROW_CAPACITY)
	for row in 1 ..< layout.row_count {
		testing.expect(t, layout.rows[row].start > layout.rows[row - 1].start)
	}
}
