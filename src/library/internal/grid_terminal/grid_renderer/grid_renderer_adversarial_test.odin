#+build !freestanding
package grid_renderer

import "core:testing"
import "modus:contract/ring"
import "modus:display"
import "modus:graphics"
import terminal_records "modus:terminal"

@(private = "file")
test_canvas :: proc(columns, rows: int) -> (graphics.Canvas, []graphics.Color) {
	width, height := columns * graphics.CELL_WIDTH, rows * graphics.CELL_HEIGHT
	pixels := make([]graphics.Color, width * height)
	return {pixels = raw_data(pixels), width = width, height = height, stride = width}, pixels
}

// A canvas with no pixels, smaller than one cell, or whose stride is less
// than its width is refused: nothing is drawn, and the dirty rows stay
// dirty for the next present.
@(test)
grid_present_refuses_a_canvas_that_is_no_screen :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 20, 4, .Dark)
	pixels := make([]graphics.Color, 160 * 64)
	defer delete(pixels)
	refused := [?]graphics.Canvas {
		{pixels = nil, width = 160, height = 64, stride = 160},
		{pixels = raw_data(pixels), width = graphics.CELL_WIDTH - 1, height = 64, stride = 160},
		{pixels = raw_data(pixels), width = 160, height = graphics.CELL_HEIGHT - 1, stride = 160},
		{pixels = raw_data(pixels), width = 160, height = 64, stride = 159},
	}
	for canvas in refused {
		testing.expect_value(t, grid_present_dirty(screen, canvas, nil, 0, .Dark), 0)
	}
	for row in 0 ..< 4 {
		testing.expect(t, screen.dirty_rows[row])
	}
}

// The size of a grid is cut to [1, limit]; a cell set out of the grid,
// negative or one past the edge, changes nothing; a cell set to the same
// value marks no row dirty.
@(test)
grid_init_and_cell_set_keep_the_bounds :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	for size in ([?][4]int{{0, 0, 1, 1}, {-5, -5, 1, 1}, {GRID_COLUMNS_LIMIT + 1, GRID_ROWS_LIMIT + 1, GRID_COLUMNS_LIMIT, GRID_ROWS_LIMIT}, {max(int), max(int), GRID_COLUMNS_LIMIT, GRID_ROWS_LIMIT}}) {
		grid_init(screen, size[0], size[1], .Dark)
		testing.expect_value(t, screen.columns, size[2])
		testing.expect_value(t, screen.rows, size[3])
	}
	grid_init(screen, 10, 3, .Dark)
	screen.dirty_rows = {}
	before := screen.cells
	for place in ([?][2]int{{-1, 0}, {0, -1}, {3, 0}, {0, 10}, {max(int), max(int)}, {min(int), 0}}) {
		grid_cell_set(screen, place[0], place[1], 'x', 1, 2)
	}
	testing.expect(t, screen.cells == before)
	testing.expect(t, screen.dirty_rows == {})
	cell := screen.cells[1][2]
	grid_cell_set(screen, 1, 2, cell.character, cell.foreground, cell.background)
	testing.expect(t, !screen.dirty_rows[1])
	grid_cell_set(screen, 1, 2, 'y', cell.foreground, cell.background)
	testing.expect(t, screen.dirty_rows[1])
}

// The cursor of the edit line is cut to the last column, a word past the
// largest int included; NO_CURSOR shows none; an edit row out of the grid
// changes nothing.
@(test)
grid_edit_line_cuts_the_cursor :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 10, 3, .Dark)
	for cursor in ([?]u64{10, 1 << 63, max(u64) - 1}) {
		grid_write_edit_line(screen, 2, transmute([]u8)string("abc"), nil, cursor, .Dark)
		testing.expect(t, screen.cursor_shown)
		testing.expect_value(t, screen.cursor_col, 9)
	}
	grid_write_edit_line(screen, 2, transmute([]u8)string("abc"), nil, terminal_records.NO_CURSOR, .Dark)
	testing.expect(t, !screen.cursor_shown)
	before := screen^
	grid_write_edit_line(screen, 3, transmute([]u8)string("zzz"), nil, 0, .Dark)
	grid_write_edit_line(screen, -1, transmute([]u8)string("zzz"), nil, 0, .Dark)
	testing.expect(t, screen.cells == before.cells)
	testing.expect_value(t, screen.cursor_shown, before.cursor_shown)
}

// The output wraps at the last column and scrolls its rows up at a new
// line on the last row of the output, as a terminal does: the place of the
// output then waits on an empty last row. The edit line under it never
// moves. A place out of
// the output is moved into it. UTF-8 takes one cell for each character, and
// an invalid byte or a control character shows the replacement character.
@(test)
grid_output_wraps_and_scrolls_above_the_edit_line :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 4, 3, .Dark)
	grid_write_edit_line(screen, 2, transmute([]u8)string("edit"), nil, 0, .Dark)
	output: Grid_Output
	grid_write_output(screen, &output, transmute([]u8)string("abcdef"), 1, 2, true, 2, .Dark)
	// "abcd" on row 0, "ef" wrapped to row 1, then the end of the line
	// scrolled: "ef" is on row 0, and row 1 waits empty.
	testing.expect_value(t, screen.cells[0][0].character, 'e')
	testing.expect_value(t, screen.cells[1][0].character, ' ')
	testing.expect_value(t, output, Grid_Output{row = 1, column = 0})
	grid_write_output(screen, &output, transmute([]u8)string("gh"), 1, 2, false, 2, .Dark)
	testing.expect_value(t, screen.cells[0][0].character, 'e')
	testing.expect_value(t, screen.cells[1][0].character, 'g')
	testing.expect_value(t, output, Grid_Output{row = 1, column = 2})
	testing.expect_value(t, screen.cells[2][0].character, 'e')
	testing.expect_value(t, screen.cells[2][3].character, 't')
	output = {row = 99, column = -3}
	grid_write_output(screen, &output, transmute([]u8)string("é\x1b\xff"), 1, 2, false, 99, .Dark)
	testing.expect_value(t, output.row, 2)
	testing.expect_value(t, screen.cells[2][0].character, 'é')
	testing.expect_value(t, screen.cells[2][1].character, rune(0xFFFD))
	testing.expect_value(t, screen.cells[2][2].character, rune(0xFFFD))
	testing.expect_value(t, output.column, 3)
}

// A row whose name length is negative or past its text, or whose length is
// past its text, draws inside the box with no fault. A list that moves
// marks the rows under its last box dirty, so they are drawn again; a list
// that stays in place marks none.
@(test)
grid_popup_restores_the_rows_of_a_box_that_moved :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 40, 12, .Dark)
	canvas, pixels := test_canvas(40, 12)
	defer delete(pixels)
	_ = grid_present_dirty(screen, canvas, nil, 0, .Dark)
	popup: terminal_records.List_Shown
	popup.row_count = 3
	popup.chosen = 1
	popup.anchor = 2
	popup.rows[0].length = 5
	popup.rows[0].name_length = -9
	popup.rows[1].length = 1 << 40
	popup.rows[1].name_length = 3
	popup.rows[2].length = 4
	popup.rows[2].name_length = 1 << 40
	_ = grid_present_dirty(screen, canvas, &popup, 2, .Dark)
	testing.expect(t, screen.popup_visible)
	testing.expect_value(t, screen.popup_top, 3)
	testing.expect_value(t, grid_present_dirty(screen, canvas, &popup, 2, .Dark), 0)
	// The list moves down by two rows: its old rows 3 to 7 are drawn again.
	blitted := grid_present_dirty(screen, canvas, &popup, 4, .Dark)
	testing.expect_value(t, blitted, 5)
	testing.expect_value(t, screen.popup_top, 5)
	// The anchor of the list past the grid: the box stays on the grid.
	popup.anchor = 1 << 40
	_ = grid_present_dirty(screen, canvas, &popup, 1 << 40, .Dark)
	testing.expect(t, screen.popup_column + screen.popup_columns <= screen.columns)
	testing.expect(t, screen.popup_bottom < screen.rows)
}

// The border of the input ring: a press gives its key; a release, a
// pointer record, a word that names no input, a pressed word past 1, a
// code past KEY_CODE_MOST, a character past U+10FFFF or a surrogate, and a
// modifier bit that names no modifier give none.
@(test)
key_of_input_record_refuses_what_is_not_a_press :: proc(t: ^testing.T) {
	press := ring.Record{kind = u32(display.Input.Key), values = {0 = display.KEY_UP, 1 = 0, 2 = 1, 3 = display.MODIFIER_SHIFT}}
	key, ok := key_of_input_record(press)
	testing.expect(t, ok)
	testing.expect_value(t, key, terminal_records.Key{code = display.KEY_UP, modifiers = display.MODIFIER_SHIFT})
	letter := ring.Record{kind = u32(display.Input.Key), values = {0 = 0x10, 1 = 'q', 2 = 1}}
	key, ok = key_of_input_record(letter)
	testing.expect(t, ok && key.character == 'q' && key.code == 0x10)
	edge := ring.Record{kind = u32(display.Input.Key), values = {0 = KEY_CODE_MOST, 1 = 0x10FFFF, 2 = 1, 3 = KEY_MODIFIERS_KNOWN}}
	_, ok = key_of_input_record(edge)
	testing.expect(t, ok)

	refused := [?]ring.Record {
		{kind = u32(display.Input.None)},
		{kind = u32(display.Input.Pointer), values = {2 = 1}},
		{kind = u32(display.Input.Pointer_Absolute), values = {2 = 1}},
		{kind = u32(max(display.Input)) + 1, values = {2 = 1}},
		{kind = max(u32), values = {2 = 1}},
		{kind = u32(display.Input.Key), values = {0 = display.KEY_UP, 2 = 0}},
		{kind = u32(display.Input.Key), values = {0 = display.KEY_UP, 2 = 2}},
		{kind = u32(display.Input.Key), values = {0 = display.KEY_UP, 2 = max(u64)}},
		{kind = u32(display.Input.Key), values = {0 = KEY_CODE_MOST + 1, 2 = 1}},
		{kind = u32(display.Input.Key), values = {0 = max(u64), 2 = 1}},
		{kind = u32(display.Input.Key), values = {1 = 0x110000, 2 = 1}},
		{kind = u32(display.Input.Key), values = {1 = 0xD800, 2 = 1}},
		{kind = u32(display.Input.Key), values = {1 = 0xDFFF, 2 = 1}},
		{kind = u32(display.Input.Key), values = {1 = max(u64), 2 = 1}},
		{kind = u32(display.Input.Key), values = {1 = 'a', 2 = 1, 3 = 8}},
		{kind = u32(display.Input.Key), values = {1 = 'a', 2 = 1, 3 = max(u64)}},
	}
	for record in refused {
		_, refused_ok := key_of_input_record(record)
		testing.expectf(t, !refused_ok, "%v gives a key", record)
	}
}

// The scroll of the output moves only the rows of the output and marks
// them dirty; a last row past the grid is cut to it, and a negative one
// changes nothing.
@(test)
grid_scroll_up_keeps_the_rows_below :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 3, 4, .Dark)
	for row in 0 ..< 4 {
		grid_cell_set(screen, row, 0, rune('0' + row), 1, 2)
	}
	screen.dirty_rows = {}
	grid_scroll_up(screen, -1, .Dark)
	testing.expect(t, screen.dirty_rows == {})
	grid_scroll_up(screen, 2, .Dark)
	testing.expect_value(t, screen.cells[0][0].character, '1')
	testing.expect_value(t, screen.cells[1][0].character, '2')
	testing.expect_value(t, screen.cells[2][0].character, ' ')
	testing.expect_value(t, screen.cells[3][0].character, '3')
	testing.expect(t, screen.dirty_rows[0] && screen.dirty_rows[1] && screen.dirty_rows[2] && !screen.dirty_rows[3])
	grid_scroll_up(screen, max(int), .Dark)
	testing.expect_value(t, screen.cells[2][0].character, '3')
	testing.expect_value(t, screen.cells[3][0].character, ' ')
}

// The edit line takes one cell for each UTF-8 character, an invalid byte
// and a control character included as the replacement character; the
// runs color the cells of the bytes that they name, and the cursor is after
// each character that starts before its byte.
@(test)
grid_edit_line_takes_one_cell_for_each_utf8_character :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 10, 3, .Dark)
	text := transmute([]u8)string("é中😀a\x1b\xffb")
	runs := terminal_records.Code_Runs{count = 1, runs = {0 = {start = 2, length = 3, kind = u8(terminal_records.Code_Kind.Function)}}}
	// The byte 9 starts 'a': three characters are before it.
	grid_write_edit_line(screen, 1, text, &runs, 9, .Dark)
	expected := [?]rune{'é', '中', '😀', 'a', 0xFFFD, 0xFFFD, 'b', ' '}
	for character, cell in expected {
		testing.expectf(t, screen.cells[1][cell].character == character, "the cell %d holds %v", cell, screen.cells[1][cell].character)
	}
	testing.expect_value(t, screen.cursor_col, 3)
	// The run of bytes 2 to 4 is '中': its cell has the color of its kind.
	plain := screen.cells[1][0].foreground
	testing.expect(t, screen.cells[1][1].foreground != plain)
	testing.expect_value(t, screen.cells[1][2].foreground, plain)
	// A cursor inside a character is after it; a cursor past the text is at
	// its last column; at byte 0 it is at the first cell.
	grid_write_edit_line(screen, 1, text, nil, 3, .Dark)
	testing.expect_value(t, screen.cursor_col, 2)
	grid_write_edit_line(screen, 1, text, nil, 0, .Dark)
	testing.expect_value(t, screen.cursor_col, 0)
	grid_write_edit_line(screen, 1, transmute([]u8)string("中中"), nil, max(u64) - 1, .Dark)
	testing.expect_value(t, screen.cursor_col, 9)
}

// A list that did not change, over rows that were not drawn again, is not
// drawn again: a pixel of its box that a test changes stays changed. A List
// record, or a row under the box drawn again, draws it again.
@(test)
grid_popup_is_drawn_only_when_it_changed :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 40, 12, .Dark)
	canvas, pixels := test_canvas(40, 12)
	defer delete(pixels)
	popup: terminal_records.List_Shown
	popup.row_count = 2
	popup.chosen = 0
	copy(popup.rows[0].text[:], "start")
	popup.rows[0].length = 5
	popup.rows[0].name_length = 5
	_ = grid_present_dirty(screen, canvas, &popup, 2, .Dark)
	testing.expect(t, screen.popup_visible)
	// A pixel inside the chosen row of the box.
	place := (3 * graphics.CELL_HEIGHT + 3) * canvas.stride + 2 * graphics.CELL_WIDTH
	drawn := pixels[place]
	pixels[place] = 0x123456
	_ = grid_present_dirty(screen, canvas, &popup, 2, .Dark)
	testing.expect_value(t, pixels[place], graphics.Color(0x123456))
	grid_list_changed(screen)
	_ = grid_present_dirty(screen, canvas, &popup, 2, .Dark)
	testing.expect_value(t, pixels[place], drawn)
	testing.expect(t, !screen.list_changed)
	pixels[place] = 0x123456
	grid_cell_set(screen, 3, 30, 'z', 1, 2)
	_ = grid_present_dirty(screen, canvas, &popup, 2, .Dark)
	testing.expect_value(t, pixels[place], drawn)
}
