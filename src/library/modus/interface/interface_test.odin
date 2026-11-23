#+build !freestanding
package interface

import "modus:contract/draw_record"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:display"
import "modus:graphics"
import "modus:kind_icons"
import "modus:text_rendering"
import "core:testing"

@(private = "file")
Tables :: struct {
	records: [256]Draw_Record,
	text:    [4096]u8,
}

@(private = "file")
table_of :: proc(memory: ^Tables) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:]}
}

// A window of a few elements, with one number that changes.
@(private = "file")
build_window :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, number: u64, moved: bool) {
	frame := frame_begin(table, state, input)
	background(&frame, {0, 0, 320, 200})
	content := card(&frame, {8, 8, 304, 184}, "CARD", "a caption", graphics.colors.kernel, "3")
	column := column_of(content)
	builder: Text_Builder
	label_value_line(&frame, column_take(&column, TABLE_LINE), "a number", number_text(&builder, number))
	bar(&frame, column_take(&column, 8), number, 100, graphics.colors.process)
	line := column_take(&column, TABLE_LINE)
	if moved {
		line.x += 8
	}
	button(&frame, line, identity("button"), "press")
	frame_end(&frame)
}

@(private = "file")
draw_whole :: proc(table: ^Draw_Table, pixels: []graphics.Color) {
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = 320, height = 200, stride = 320}
	graphics.clear(canvas, 0x123456)
	execute(table, canvas)
}

@(test)
row_split_fills_the_area :: proc(t: ^testing.T) {
	columns: [4]Area
	row_split({10, 0, 300, 24}, {pixels(40), characters(5), share(1), share(2)}, columns[:], 8)
	testing.expect_value(t, columns[0], Area{10, 0, 40, 24})
	testing.expect_value(t, columns[1], Area{58, 0, 40, 24})
	// What is left: 300 - 40 - 40 - 3 * 8 = 196; one third, then the rest.
	testing.expect_value(t, columns[2].width, 65)
	testing.expect_value(t, columns[3].width, 131)
	testing.expect_value(t, columns[3].x + columns[3].width, 310)
}

@(test)
column_gives_areas_down :: proc(t: ^testing.T) {
	column := column_of({0, 100, 50, 60}, 8)
	testing.expect_value(t, column_take(&column, 24), Area{0, 100, 50, 24})
	testing.expect_value(t, column_take(&column, 24), Area{0, 132, 50, 24})
	testing.expect_value(t, column_take(&column, 24), Area{0, 164, 50, 0}) // Past the bottom.
	testing.expect_value(t, column_rest(&column).height, 0)
}

@(test)
text_measure :: proc(t: ^testing.T) {
	testing.expect_value(t, text_width({}, "abc"), 24)
	testing.expect_value(t, text_width(FONT_LARGEST, "12"), 48)
	testing.expect_value(t, line_height(FONT_LARGE), 32)
	// The line of each font of a token is the token: a whole count of
	// pixels, so the elements under it start on a whole pixel.
	testing.expect_value(t, line_height(FONT_CAPTION), graphics.TEXT_CAPTION)
	testing.expect_value(t, line_height(FONT_CAPTION_CELLS), graphics.TEXT_CAPTION)
	// With no font outlines open, Spleen draws: a character of the caption
	// takes the 8 columns of its glyph, not the cell of 7.
	testing.expect_value(t, text_width(FONT_CAPTION_CELLS, "12"), 2 * graphics.CELL_WIDTH)
	testing.expect_value(t, line_height(FONT_HEADING), graphics.TEXT_HEADING)
	testing.expect_value(t, line_height(FONT_LARGE), graphics.TEXT_LARGE)
	testing.expect_value(t, line_height(FONT_LARGEST), graphics.TEXT_LARGEST)
}

// The one number of a card: a value, in the font of the cells, at the
// large size, and the x after it is the end of its cells.
@(test)
the_number_of_a_card_is_at_the_large_size :: proc(t: ^testing.T) {
	memory := new(Tables)
	defer free(memory)
	table := table_of(memory)
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	after := large_number(&frame, 10, 20, "12 345", graphics.colors.text)
	frame_end(&frame)
	testing.expect_value(t, after, 10 + 6 * graphics.TEXT_LARGE / 2)
	found := false
	for record in table.records[:table.record_count] {
		if shown, size, is_text := text_of_record(&table, record); is_text && shown == "12 345" {
			found = true
			view := record_view(record)
			testing.expect_value(t, size, graphics.TEXT_LARGE * TEXT_SIZE_UNITS)
			testing.expect_value(t, view.font, Font_Kind.Cells_8x16)
			testing.expect_value(t, view.y, 20)
			testing.expect_value(t, view.height, graphics.TEXT_LARGE)
		}
	}
	testing.expect(t, found, "the number has a record")
}

// The lines of a text, joined with one space where a line ended at a space,
// are the text: no byte is dropped. `joined` gets them.
@(private = "file")
wrapped_lines_joined :: proc(text: string, room: int, joined: ^[512]u8) -> (result: string, lines: int, widest: int) {
	count := 0
	rest := text
	for len(rest) > 0 {
		line: string
		before := rest
		line, rest = text_wrap_line(nil, {}, rest, room)
		widest = max(widest, text_width({}, line))
		count += copy(joined[count:], line)
		// The spaces that the break took are between the two lines.
		count += copy(joined[count:], before[len(line):len(before) - len(rest)])
		lines += 1
	}
	return string(joined[:count]), lines, widest
}

@(test)
a_text_that_fits_is_one_line :: proc(t: ^testing.T) {
	line, rest := text_wrap_line(nil, {}, "a short text", 12 * 8)
	testing.expect_value(t, line, "a short text")
	testing.expect_value(t, rest, "")
	testing.expect_value(t, text_wrapped_line_count(nil, {}, "a short text", 12 * 8), 1)
	testing.expect_value(t, text_wrapped_line_count(nil, {}, "", 80), 0)
}

@(test)
a_line_ends_at_the_last_space_that_fits :: proc(t: ^testing.T) {
	// 10 characters fit: "one two" and a part of "three".
	line, rest := text_wrap_line(nil, {}, "one two three four", 10 * 8)
	testing.expect_value(t, line, "one two")
	testing.expect_value(t, rest, "three four")
	// The space is the first character that does not fit.
	line, rest = text_wrap_line(nil, {}, "one two three", 7 * 8)
	testing.expect_value(t, line, "one two")
	testing.expect_value(t, rest, "three")
	// Several spaces at the break are in neither part.
	line, rest = text_wrap_line(nil, {}, "one two   three", 8 * 8)
	testing.expect_value(t, line, "one two")
	testing.expect_value(t, rest, "three")
	testing.expect_value(t, text_wrapped_line_count(nil, {}, "one two three four", 10 * 8), 2)
}

@(test)
a_path_longer_than_the_box_breaks_after_a_separator :: proc(t: ^testing.T) {
	PLACE :: "fault::three + 0x4 in fault (src/processes/fault/main.odin:15)"
	// 24 characters: the line ends at a space while the text has one.
	line, rest := text_wrap_line(nil, {}, PLACE, 24 * 8)
	testing.expect_value(t, line, "fault::three + 0x4 in")
	testing.expect_value(t, rest, "fault (src/processes/fault/main.odin:15)")
	// The path is one word of 33 characters: it breaks after a `/`.
	line, rest = text_wrap_line(nil, {}, "(src/processes/fault/main.odin:15)", 24 * 8)
	testing.expect_value(t, line, "(src/processes/fault/")
	testing.expect_value(t, rest, "main.odin:15)")
	// A name of the system breaks after a `_`.
	line, rest = text_wrap_line(nil, {}, "interface_through_module", 20 * 8)
	testing.expect_value(t, line, "interface_through_")
	testing.expect_value(t, rest, "module")
	// A word with no separator breaks at its last character that fits.
	line, rest = text_wrap_line(nil, {}, "0123456789abcdef", 10 * 8)
	testing.expect_value(t, line, "0123456789")
	testing.expect_value(t, rest, "abcdef")
}

@(test)
no_line_passes_its_box_and_no_byte_is_lost :: proc(t: ^testing.T) {
	TEXTS := [?]string {
		"page fault at fault::three + 0x4 in fault (src/processes/fault/main.odin:15), fault::two + 0x9 in fault (src/processes/fault/main.odin:20), fault::one + 0x9 in fault (src/processes/fault/main.odin:26), entry + 0x46 in fault (src/processes/fault/main.odin:60)",
		"keys: a note; up, down: its versions; enter: restore the version shown; tab: count 1000",
		"src/library/support/cryptography/_edwards25519/edwards25519_scalar_mul_base.odin",
		"interface_through_module",
		" a text that starts with a space",
		"a text that ends with spaces   ",
		"x",
	}
	for text in TEXTS {
		for columns in 1 ..= 130 {
			joined: [512]u8
			result, lines, widest := wrapped_lines_joined(text, columns * 8, &joined)
			testing.expectf(t, result == text, "%d columns: the lines hold the text %q, they hold %q", columns, text, result)
			testing.expectf(t, widest <= columns * 8, "%d columns: the widest line of %q has %d pixels", columns, text, widest)
			testing.expect_value(t, lines, text_wrapped_line_count(nil, {}, text, columns * 8))
			// A text that fits is one line, and a text that does not has more.
			testing.expectf(t, (lines == 1) == (len(text) <= columns) || text[len(text) - 1] == ' ', "%d columns: %d lines for %d characters", columns, lines, len(text))
		}
	}
}

@(test)
a_box_narrower_than_a_character_ends :: proc(t: ^testing.T) {
	// One character on each line: the loop of the lines ends.
	testing.expect_value(t, text_wrapped_line_count(nil, {}, "abc", 0), 3)
	testing.expect_value(t, text_wrapped_line_count(nil, {}, "abc", -40), 3)
	testing.expect_value(t, text_wrapped_line_count(nil, {}, "abc", 3), 3)
}

@(test)
draw_text_wrapped_places_each_line_under_the_line_before :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	TEXT :: "fault::three + 0x4 in fault (src/processes/fault/main.odin:15)"
	count := draw_text_wrapped(&table, 40, 100, 24 * 8, TEXT, graphics.colors.text)
	testing.expect_value(t, count, text_wrapped_line_count(&table, {}, TEXT, 24 * 8))
	testing.expect_value(t, count, 3)
	testing.expect_value(t, table.record_count, 3)
	for record, line in table.records[:table.record_count] {
		testing.expect_value(t, record_view(record).kind, Draw_Kind.Text)
		testing.expect_value(t, record_view(record).x, 40)
		testing.expect_value(t, record_view(record).y, 100 + line * graphics.CELL_HEIGHT)
		testing.expect(t, record_view(record).width <= 24 * 8, "a line stays in the box")
	}
	// At the large size a character is 16 pixels wide and a line 32 pixels high.
	table.record_count, table.text_count = 0, 0
	count = draw_text_wrapped(&table, 0, 0, 10 * 16, "one two three four", graphics.colors.text, FONT_LARGE)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, record_view(table.records[1]).y, 32)
}

// The text of a record of a table.
@(private = "file")
record_text :: proc(table: ^Draw_Table, record: Draw_Record) -> string {
	text, _, _ := text_of_record(table, record)
	return text
}

@(test)
label_value_lines_takes_the_lines_of_its_longest_text :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	frame := Frame{table = &table}
	// The value starts at 96: its box has 104 pixels, 13 characters; the
	// box of the label has 88 pixels, 11 characters.
	column := column_of({8, 8, 200, 200})
	count, drawn := label_value_lines(&frame, &column, "a name", "one two three four five", 96)
	testing.expect_value(t, count, 2)
	testing.expect(t, drawn)
	testing.expect_value(t, column.used, 2 * LINE)
	testing.expect_value(t, table.record_count, 3)
	testing.expect_value(t, record_text(&table, table.records[0]), "a name")
	testing.expect_value(t, record_text(&table, table.records[1]), "one two three")
	testing.expect_value(t, record_text(&table, table.records[2]), "four five")
	testing.expect_value(t, record_view(table.records[0]).x, 8)
	testing.expect_value(t, record_view(table.records[1]).x, 8 + 96)
	testing.expect_value(t, record_view(table.records[1]).y, 8)
	testing.expect_value(t, record_view(table.records[2]).y, 8 + LINE)
	for record in table.records[:table.record_count] {
		testing.expect(t, record_view(record).x + record_view(record).width <= 8 + 200, "a text stays in the column")
	}
	testing.expect(t, record_view(table.records[0]).x + record_view(table.records[0]).width <= 8 + 96 - 8, "the label stays before the value")

	// The next row starts under the two lines. A label longer than its
	// box has two lines too, and the value one.
	count, drawn = label_value_lines(&frame, &column, "a name of two lines", "short", 96)
	testing.expect_value(t, count, 2)
	testing.expect(t, drawn)
	testing.expect_value(t, record_view(table.records[3]).y, 8 + 2 * LINE)
	testing.expect_value(t, record_text(&table, table.records[3]), "a name of")
	testing.expect_value(t, record_text(&table, table.records[4]), "two lines")
	testing.expect_value(t, record_text(&table, table.records[5]), "short")
	testing.expect_value(t, column.used, 4 * LINE)

	// A row of a table: one line has the height of a line of a table, and
	// its text is in the middle of that height.
	before := table.record_count
	count, drawn = label_value_lines(&frame, &column, "name", "value", 96, graphics.colors.text, TABLE_LINE)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, column.used, 4 * LINE + TABLE_LINE)
	testing.expect_value(t, record_view(table.records[before]).y, 8 + 4 * LINE + (TABLE_LINE - LINE) / 2)
}

@(test)
a_row_past_the_bottom_of_its_column_is_not_drawn_in_part :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	frame := Frame{table = &table}
	// The column has room for one line; the value needs two.
	column := column_of({0, 0, 200, LINE + 4})
	count, drawn := label_value_lines(&frame, &column, "a name", "one two three four five", 96)
	testing.expect_value(t, count, 2)
	testing.expect(t, !drawn)
	testing.expect_value(t, table.record_count, 0)
	// A value of one line fits in a column of the same height.
	column = column_of({0, 0, 200, LINE + 4})
	count, drawn = label_value_lines(&frame, &column, "a name", "one two", 96)
	testing.expect_value(t, count, 1)
	testing.expect(t, drawn)
	testing.expect_value(t, table.record_count, 2)
}

@(test)
case_lines_has_a_band_as_high_as_its_answer :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	frame := Frame{table = &table}
	column := column_of({16, 0, 400, 200})
	// The answer has the box from 200 to 400: 25 characters.
	ANSWER :: "refused: the argument address, 10.0.2.2 port 9, is not the remote of the grant"
	count, drawn := case_lines(&frame, &column, 0, "UDP to 10.0.2.2 port 9", ANSWER, 200, graphics.colors.dim, graphics.colors.process)
	testing.expect(t, drawn)
	testing.expect_value(t, count, text_wrapped_line_count(&table, {}, ANSWER, 200))
	testing.expect(t, count >= 4)
	// The row push, then the band of the case at an even place: the whole
	// row, 8 pixels wider on each side.
	testing.expect_value(t, record_view(table.records[0]).kind, Draw_Kind.Element_Push)
	band := table.records[1]
	testing.expect(t, is_solid_rectangle(record_view(band)), "the band is a solid rectangle")
	testing.expect_value(t, record_view(band).x, 8)
	testing.expect_value(t, record_view(band).width, 416)
	testing.expect_value(t, record_view(band).height, TABLE_LINE + (count - 1) * LINE)
	testing.expect_value(t, column.used, record_view(band).height)
	// The row push/pop + two cell push/pops (6 semantic records), the band,
	// the text of the case, then each line of the answer.
	testing.expect_value(t, table.record_count, 8 + count)
	joined: [128]u8
	length := 0
	answer_lines := 0
	for record in table.records[:table.record_count] {
		view := record_view(record)
		if view.kind != .Text || view.x != 16 + 200 {
			continue
		}
		testing.expect(t, view.width <= 200, "a line of the answer stays in its box")
		if answer_lines > 0 {
			length += copy(joined[length:], " ")
		}
		length += copy(joined[length:], record_text(&table, record))
		answer_lines += 1
	}
	testing.expect_value(t, answer_lines, count)
	testing.expect_value(t, string(joined[:length]), ANSWER)
	// The case after it has no band, and starts under the band.
	before := table.record_count
	case_lines(&frame, &column, 1, "ARP", "answered", 200, graphics.colors.dim, graphics.colors.process)
	testing.expect_value(t, record_view(table.records[before]).kind, Draw_Kind.Element_Push)
	testing.expect_value(t, record_view(table.records[before + 1]).kind, Draw_Kind.Element_Push)
	testing.expect_value(t, record_view(table.records[before + 2]).kind, Draw_Kind.Text)
	testing.expect_value(t, record_view(table.records[before + 2]).y, record_view(band).height + (TABLE_LINE - LINE) / 2)
}

@(test)
cases_rest_line_counts_the_cases_with_no_room :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	frame := Frame{table = &table}
	cases_rest_line(&frame, {0, 0, 400, TABLE_LINE}, 0, "the log has each one")
	testing.expect_value(t, table.record_count, 0)
	cases_rest_line(&frame, {0, 0, 400, TABLE_LINE}, 3, "the log has each one")
	testing.expect_value(t, table.record_count, 1)
	testing.expect_value(t, record_text(&table, table.records[0]), "and 3 cases more: the log has each one")
}

@(test)
no_change_no_damage :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	state: Interface_State
	input: Input
	build_window(&before, &state, &input, 42, false)
	build_window(&now, &state, &input, 42, false)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	testing.expect(t, !now.full)
}

@(test)
one_number_damages_its_place :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	state: Interface_State
	input: Input
	build_window(&before, &state, &input, 42, false)
	build_window(&now, &state, &input, 57, false)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	// The number and the bar changed: two records each, near each other.
	testing.expect(t, damage.count >= 1)
	bounds := damage_bounds(&damage)
	testing.expect(t, bounds.right - bounds.left <= 288 && bounds.bottom - bounds.top <= 40, "the damage is the line of the number and the bar")
}

@(test)
text_at_another_place_is_equal :: proc(t: ^testing.T) {
	process_drawing_begin()
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_text(&before, 0, 0, "same", graphics.colors.text)
	draw_text(&now, 0, 30, "other", graphics.colors.text)
	draw_table_clear(&now)
	now.text_count = 7 // The text of the run starts at another place.
	draw_text(&now, 0, 0, "same", graphics.colors.text)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
}

// A frame drawn in its damage rectangles over the frame before is the same
// frame, pixel for pixel, as the frame drawn whole.
@(test)
damage_is_never_too_small :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	state: Interface_State
	input: Input
	cases := [?]struct {
		number_before, number_now: u64,
		moved:                     bool,
	}{{42, 57, false}, {0, 100, false}, {7, 7, true}, {99, 3, true}}
	for item in cases {
		build_window(&before, &state, &input, item.number_before, false)
		build_window(&now, &state, &input, item.number_now, item.moved)
		partial := make([]graphics.Color, 320 * 200)
		defer delete(partial)
		whole := make([]graphics.Color, 320 * 200)
		defer delete(whole)
		draw_whole(&before, partial)
		damage: Damage
		damage_by_difference(&before, &now, &damage)
		canvas := graphics.Canvas{pixels = raw_data(partial), width = 320, height = 200, stride = 320}
		execute_in_rectangles(&now, canvas, damage.rectangles[:damage.count])
		draw_whole(&now, whole)
		testing.expectf(t, same_pixels(partial, whole), "the frame in its damage differs from the whole frame: %v", item)
	}
}

@(test)
fewer_records_damage_the_rest :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_rectangle(&before, 0, 0, 10, 10, 1)
	draw_rectangle(&before, 50, 50, 10, 10, 2)
	draw_rectangle(&now, 0, 0, 10, 10, 1)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{50, 50, 60, 60})
}

@(test)
full_table_says_so :: proc(t: ^testing.T) {
	process_drawing_begin()
	records: [2]Draw_Record
	text: [4]u8
	table := Draw_Table{records = records[:], text = text[:]}
	draw_rectangle(&table, 0, 0, 1, 1, 0)
	draw_rectangle(&table, 0, 0, 1, 1, 0)
	testing.expect(t, !table.full)
	draw_rectangle(&table, 0, 0, 1, 1, 0)
	testing.expect(t, table.full)
	draw_table_clear(&table)
	draw_text(&table, 0, 0, "too long", 0)
	testing.expect(t, table.full)
}

@(private = "file")
key :: proc(input: ^Input, code: u32, character: rune = 0, modifiers: u32 = 0) {
	input_add(input, {kind = .Key, code = code, character = character, pressed = true, modifiers = modifiers})
}

@(private = "file")
two_buttons :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input) -> (first, second: Element_Result) {
	frame := frame_begin(table, state, input)
	first = button(&frame, {0, 0, 80, 24}, identity("first"), "first")
	second = button(&frame, {0, 32, 80, 24}, identity("second"), "second")
	frame_end(&frame)
	input_clear(input)
	return
}

@(test)
keyboard_moves_the_focus_and_presses :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	two_buttons(&table, &state, &input) // The first frame makes the order of the focus.
	key(&input, KEY_TAB)
	first, second := two_buttons(&table, &state, &input)
	testing.expect(t, first.focused && !second.focused, "Tab gives the focus to the first element")
	key(&input, KEY_TAB)
	key(&input, display.KEY_ENTER)
	first, second = two_buttons(&table, &state, &input)
	testing.expect(t, second.focused && second.activated && !first.activated, "Tab, then Enter presses the second")
	key(&input, KEY_TAB, 0, display.MODIFIER_SHIFT)
	key(&input, 0x39, ' ')
	first, second = two_buttons(&table, &state, &input)
	testing.expect(t, first.focused && first.activated, "Shift+Tab, then Space presses the first")
}

@(test)
pointer_presses_on_release :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	input_add(&input, {kind = .Pointer, x = 10, y = 40, buttons = display.BUTTON_LEFT})
	first, second := two_buttons(&table, &state, &input)
	testing.expect(t, second.under_pointer && !second.activated && second.focused, "the press gives the focus; no activation yet")
	input_add(&input, {kind = .Pointer, x = 12, y = 41, buttons = 0})
	first, second = two_buttons(&table, &state, &input)
	testing.expect(t, second.activated && !first.activated, "the release on the same element activates it")
}

@(test)
text_input_and_list :: proc(t: ^testing.T) {
	process_drawing_begin()
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	text: [8]u8
	count := 0
	choice := 0
	names := []string{"boot", "pages", "log"}
	build :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, text: []u8, count: ^int, names: []string, choice: ^int) -> (typed, listed: Element_Result) {
		frame := frame_begin(table, state, input)
		typed = text_input(&frame, {0, 0, 200, 24}, identity("input"), text, count, "type")
		listed = list_with_choice(&frame, {0, 32, 200, 72}, identity("list"), names, choice, {marked = string(text[:count^])})
		frame_end(&frame)
		input_clear(input)
		return
	}
	build(&table, &state, &input, text[:], &count, names, &choice)
	state.focus = identity("input")
	key(&input, 0x26, 'l')
	key(&input, 0x18, 'o')
	key(&input, 0x39, ' ')
	key(&input, display.KEY_BACKSPACE)
	typed, _ := build(&table, &state, &input, text[:], &count, names, &choice)
	testing.expect(t, typed.changed)
	testing.expect_value(t, string(text[:count]), "lo")
	key(&input, KEY_TAB)
	key(&input, display.KEY_DOWN)
	key(&input, display.KEY_DOWN)
	_, listed := build(&table, &state, &input, text[:], &count, names, &choice)
	testing.expect(t, listed.focused && listed.changed)
	testing.expect_value(t, choice, 2)
	key(&input, display.KEY_DOWN)
	key(&input, display.KEY_ENTER)
	_, listed = build(&table, &state, &input, text[:], &count, names, &choice)
	testing.expect_value(t, choice, 0) // From the last line to the first.
	testing.expect(t, listed.activated)
}

// The keys of one frame act in their order: Enter after "ls" activates the
// field with "ls", and the key after Enter is not taken: Enter taken
// before the characters of its frame would act on an empty field.
@(test)
text_input_keys_in_their_order :: proc(t: ^testing.T) {
	process_drawing_begin()
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	text: [8]u8
	count := 0
	state.focus = identity("input")
	key(&input, 0x26, 'l')
	key(&input, 0x1F, 's')
	key(&input, display.KEY_ENTER)
	key(&input, 0x2D, 'x')
	frame := frame_begin(&table, &state, &input)
	result := text_input(&frame, {0, 0, 200, 24}, identity("input"), text[:], &count)
	frame_end(&frame)
	testing.expect(t, result.activated)
	testing.expect_value(t, string(text[:count]), "ls")
	testing.expect(t, !input.keys[3].taken, "the key after Enter stays for the next element")
}

// A key of the layout of France types its character in UTF-8, Backspace
// removes it whole, and a character whose bytes do not fit is not typed.
@(test)
text_input_of_characters_outside_ascii :: proc(t: ^testing.T) {
	process_drawing_begin()
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	text: [4]u8
	count := 0
	state.focus = identity("input")
	type_keys :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, text: []u8, count: ^int) {
		frame := frame_begin(table, state, input)
		text_input(&frame, {0, 0, 200, 24}, identity("input"), text, count)
		frame_end(&frame)
		input_clear(input)
	}
	key(&input, 0x03, 'é')
	key(&input, 0x14, 't')
	key(&input, 0x03, 'é') // Two bytes in one free byte: not typed.
	type_keys(&table, &state, &input, text[:], &count)
	testing.expect_value(t, string(text[:count]), "ét")
	key(&input, display.KEY_BACKSPACE)
	key(&input, display.KEY_BACKSPACE)
	type_keys(&table, &state, &input, text[:], &count)
	testing.expect_value(t, count, 0)
}

// The input of a frame takes 16 keys; then it has no room, and the reader
// of the events leaves the next ones for the next frame: no key is lost.
@(test)
a_full_input_says_so :: proc(t: ^testing.T) {
	input: Input
	for index in 0 ..< KEY_CAPACITY {
		testing.expect(t, input_has_room(&input))
		testing.expect(t, input_add(&input, {kind = .Key, code = u32(0x10 + index), character = 'a', pressed = true}))
	}
	testing.expect(t, !input_has_room(&input))
	testing.expect(t, !input_add(&input, {kind = .Key, code = 0x30, character = 'b', pressed = true}))
	input_clear(&input)
	testing.expect(t, input_has_room(&input))
}

// partial_equals_whole draws the table before whole, then the table now in
// its damage only, and compares the result with the table now drawn whole.
@(private = "file")
partial_equals_whole :: proc(t: ^testing.T, before, now: ^Draw_Table, name: string) {
	partial := make([]graphics.Color, 320 * 200)
	defer delete(partial)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	draw_whole(before, partial)
	damage: Damage
	damage_by_difference(before, now, &damage)
	canvas := graphics.Canvas{pixels = raw_data(partial), width = 320, height = 200, stride = 320}
	execute_in_rectangles(now, canvas, damage.rectangles[:damage.count])
	draw_whole(now, whole)
	testing.expectf(t, same_pixels(partial, whole), "%s: the frame in its damage differs from the whole frame", name)
}

@(private = "file")
Case_Builder :: proc(table: ^Draw_Table, variant: int)

// Each kind of record and each path of the difference: a damage too small
// for one kind would leave old pixels on the screen.
@(test)
damage_is_never_too_small_for_each_kind :: proc(t: ^testing.T) {
	process_drawing_begin()
	cases := [?]struct {
		name:  string,
		build: Case_Builder,
	} {
		{"a clip that changes", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				draw_clip_push(table, 10, 10, variant == 0 ? 100 : 60, 50)
				draw_rectangle(table, 0, 0, 200, 100, graphics.colors.kernel)
				draw_clip_pop(table)
				draw_rectangle(table, 150, 150, 20, 20, graphics.colors.process)
			}},
		{"a nested clip that moves", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				draw_clip_push(table, 20, 20, 200, 120)
				draw_clip_push(table, 40 + variant * 30, 30, 300, 50)
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.kernel)
				draw_clip_pop(table)
				draw_rectangle(table, 0, 100, 320, 100, graphics.colors.memory)
				draw_clip_pop(table)
				draw_rectangle(table, 250, 150, 20, 20, graphics.colors.process)
			}},
		{"horizontal gradients", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				draw_horizontal_gradient(table, 5, 5, 300, 24, graphics.colors.title, variant == 0 ? graphics.colors.title_end : graphics.colors.failed)
				draw_horizontal_gradient(table, -40, 60, 700, 3, graphics.colors.text, graphics.colors.dim)
			}},
		{"text at the sizes of the body, the large and the largest", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				draw_text(table, 4, 4, variant == 0 ? "one" : "two", graphics.colors.text)
				draw_text(table, 4, 30, variant == 0 ? "12" : "13", graphics.colors.text, FONT_LARGE)
				draw_text(table, 4, 70, variant == 0 ? "45" : "46", graphics.colors.text, FONT_LARGEST)
			}},
		{"records outside the surface", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				draw_rectangle(table, -50 + variant * 7, -20, 80, 60, graphics.colors.memory)
				draw_rectangle(table, 300, 190 - variant * 3, 100, 100, graphics.colors.machine)
				draw_text(table, -12 + variant, 190, "edge", graphics.colors.text)
				draw_point_grid(table, -30, -30, 400, 300)
			}},
		{"a record of one line", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				draw_rectangle(table, 10, 100 + variant, 300, 1, graphics.colors.text)
				draw_vertical_gradient(table, 10, 120, 300, 1, graphics.colors.kernel, graphics.colors.failed)
			}},
		{"more than 8 rectangles of damage", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				for index in 0 ..< 12 {
					draw_rectangle(table, (index % 4) * 80 + 4, (index / 4) * 64 + 4, 10, 10, variant == 0 ? graphics.colors.kernel : graphics.Color(graphics.colors.process + u32(index)))
				}
			}},
		{"a table that is full", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
				for index in 0 ..< 400 {
					draw_rectangle(table, index % 300, (index * 7) % 190, 4, 4, graphics.Color(index * 977 + variant))
				}
			}},
	}
	for item in cases {
		first, second: Tables
		before, now := table_of(&first), table_of(&second)
		item.build(&before, 0)
		item.build(&now, 1)
		partial_equals_whole(t, &before, &now, item.name)
	}
	// The cases by their names, so that a case added to the list moves none.
	many_changes, full_table: Case_Builder
	for item in cases {
		switch item.name {
		case "more than 8 rectangles of damage":
			many_changes = item.build
		case "a table that is full":
			full_table = item.build
		}
	}
	testing.expect(t, many_changes != nil && full_table != nil)
	if many_changes == nil || full_table == nil {
		return
	}
	// The merge path: 12 changes far apart give at most 8 rectangles.
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	many_changes(&before, 0)
	many_changes(&now, 1)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect(t, damage.count <= DAMAGE_CAPACITY)
	// The full table: 256 records fit, the others are dropped, and it says so.
	full_table(&now, 1)
	testing.expect(t, now.full)
}

// More digits than a number can have: the table of digits must not be
// indexed before its start.
@(test)
number_with_many_digits :: proc(t: ^testing.T) {
	builder: Text_Builder
	testing.expect_value(t, number_text(&builder, 7, 25), "00000000000000000007")
}

// A negative height takes nothing: the next element must not go up.
@(test)
column_negative_height :: proc(t: ^testing.T) {
	column := column_of({0, 0, 50, 100})
	column_take(&column, 30)
	testing.expect_value(t, column_take(&column, -20).height, 0)
	testing.expect_value(t, column_take(&column, 10), Area{0, 30, 50, 10})
}

// Sizes that are negative, larger than the row, or so large that
// a product overflows.
@(test)
row_split_checks_its_sizes :: proc(t: ^testing.T) {
	columns: [3]Area
	row_split({0, 0, 100, 24}, {pixels(-40), share(1), pixels(30)}, columns[:])
	testing.expect_value(t, columns[0].width, 0)
	testing.expect_value(t, columns[1].width, 70)
	row_split({0, 0, 100, 24}, {pixels(300), share(1), characters(4)}, columns[:])
	for column in columns {
		testing.expect(t, column.width >= 0 && column.x + column.width <= 100, "each column is inside the row")
	}
	row_split({0, 0, 100, 24}, {share(max(int) / 2), share(max(int) / 2), share(-5)}, columns[:])
	total := 0
	for column in columns {
		testing.expect(t, column.width >= 0)
		total += column.width
	}
	testing.expect_value(t, total, 100)
}

// A press under the last line or on the bar of the list chooses
// nothing; a choice that the list cuts is reported as changed.
@(test)
list_press_and_cut_choice :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	names := []string{"a", "b", "c", "d", "e"}
	choice := 0
	// 3 lines of 24 and 10 pixels more: a press at y = 80 is under the last line.
	input_add(&input, {kind = .Pointer, x = 10, y = 80, buttons = display.BUTTON_LEFT})
	frame := frame_begin(&table, &state, &input)
	result := list_with_choice(&frame, {0, 0, 200, 82}, identity("list"), names, &choice)
	frame_end(&frame)
	testing.expect_value(t, choice, 0)
	testing.expect(t, !result.changed)
	// A press on the bar at the right chooses nothing.
	input_clear(&input)
	input_add(&input, {kind = .Pointer, x = 199, y = 30, buttons = 0})
	input_add(&input, {kind = .Pointer, x = 199, y = 30, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input)
	result = list_with_choice(&frame, {0, 0, 200, 82}, identity("list"), names, &choice)
	frame_end(&frame)
	testing.expect_value(t, choice, 0)
	// The list has fewer names than the choice: the choice is cut, and changed.
	choice = 4
	input_clear(&input)
	frame = frame_begin(&table, &state, &input)
	result = list_with_choice(&frame, {0, 0, 200, 82}, identity("list"), names[:2], &choice)
	frame_end(&frame)
	testing.expect_value(t, choice, 1)
	testing.expect(t, result.changed)
}

// Two elements with one identity in one frame are reported; a
// row number makes them two.
@(test)
identity_collision :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	button(&frame, {0, 0, 80, 24}, identity("delete"), "delete")
	button(&frame, {0, 32, 80, 24}, identity("delete"), "delete")
	testing.expect_value(t, frame.identity_collisions, 1)
	frame_end(&frame)
	frame = frame_begin(&table, &state, &input)
	button(&frame, {0, 0, 80, 24}, identity_with(identity("delete"), 0), "delete")
	button(&frame, {0, 32, 80, 24}, identity_with(identity("delete"), 1), "delete")
	testing.expect_value(t, frame.identity_collisions, 0)
	frame_end(&frame)
}

// A place past the i32 of a record is cut to it.
@(test)
coordinates_are_cut_to_i32 :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	draw_rectangle(&table, 1 << 40, -(1 << 40), 10, 10, 1)
	testing.expect_value(t, record_view(table.records[0]).x, COORDINATE_LIMIT - 1)
	testing.expect_value(t, record_view(table.records[0]).y, -COORDINATE_LIMIT)
}

// A record that the frame no longer has leaves no pixel, even
// when no record of the frame covers its place.
@(test)
a_gone_record_leaves_no_pixel :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_rectangle(&before, 0, 0, 10, 10, graphics.colors.background)
	draw_rectangle(&before, 50, 50, 20, 20, graphics.colors.failed)
	draw_rectangle(&now, 0, 0, 10, 10, graphics.colors.background)
	pixels := make([]graphics.Color, 320 * 200)
	defer delete(pixels)
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = 320, height = 200, stride = 320}
	graphics.clear(canvas, graphics.colors.background)
	execute(&before, canvas)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	draw_damage_on_surface(&now, canvas, damage.rectangles[:damage.count])
	testing.expect_value(t, pixels[60 * 320 + 60], graphics.colors.background)
}

// A picture record: the difference sees a new generation, and the frame in
// its damage equals the whole frame; a folded gap draws like the others.
@(test)
picture_and_folded_gap :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	cells: [16 * 8]graphics.Color
	for &cell, index in cells {
		cell = graphics.Color(index * 0x010203)
	}
	picture := graphics.Canvas{pixels = raw_data(cells[:]), width = 16, height = 8, stride = 16}
	memories := [][]graphics.Color{cells[:]}
	before.picture_memories, now.picture_memories = memories, memories
	draw_rectangle(&before, 0, 0, 320, 200, graphics.colors.background)
	draw_picture(&before, 40, 40, picture, 1)
	draw_folded_gap(&before, 100, 100, 40, 24)
	draw_rectangle(&now, 0, 0, 320, 200, graphics.colors.background)
	draw_picture(&now, 40, 40, picture, 2)
	draw_folded_gap(&now, 100, 100, 40, 24)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{40, 40, 56, 48})
	partial_equals_whole(t, &before, &now, "a picture")
	outside: [4]graphics.Color
	draw_picture(&now, 0, 0, {pixels = raw_data(outside[:]), width = 2, height = 2, stride = 2}, 1)
	testing.expect(t, now.refused && !now.full, "a picture outside each picture memory is refused, and the table is not full")
}

// A picture is a part of its picture memory: its record names the place
// of its first pixel and its stride, and draws those pixels. A picture
// whose last line passes the end of its memory is refused, and a record
// written by hand with a pixel past the memory draws nothing.
@(test)
picture_inside_its_picture_memory :: proc(t: ^testing.T) {
	memory: [8 * 6]graphics.Color
	for &pixel, index in memory {
		pixel = graphics.Color(index + 1)
	}
	memories := [][]graphics.Color{memory[:]}
	records: [4]Draw_Record
	table := Draw_Table{records = records[:], picture_memories = memories}
	whole := graphics.Canvas{pixels = raw_data(memory[:]), width = 8, height = 6, stride = 8}
	part := graphics.view(whole, 2, 3, 4, 2)
	draw_picture(&table, 0, 0, part, 7)
	testing.expect(t, !table.refused && table.record_count == 1, "a part of the memory is a picture")
	record := record_view(table.records[0])
	testing.expect_value(t, record.kind, Draw_Kind.Picture)
	testing.expect_value(t, record.memory, 0)
	testing.expect_value(t, record.first, 3 * 8 + 2)
	testing.expect_value(t, record.stride, 8)
	testing.expect_value(t, record.generation, 7)
	canvas_pixels: [4 * 2]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(canvas_pixels[:]), width = 4, height = 2, stride = 4}
	execute(&table, canvas)
	testing.expect_value(t, canvas_pixels[0], graphics.Color(3 * 8 + 2 + 1))
	testing.expect_value(t, canvas_pixels[7], graphics.Color(4 * 8 + 5 + 1))
	// One line more than the memory has.
	draw_picture(&table, 0, 0, graphics.Canvas{pixels = part.pixels, width = 4, height = 4, stride = 8}, 1)
	testing.expect(t, table.refused && table.record_count == 1, "a picture past the end of its memory is refused")
	// A record by hand: its last pixel is one past the memory.
	table.records[0] = draw_record.record_of(draw_record.Draw_Picture{first = 8 * 6 - 4 - 8 + 1, stride = 8}, 0, 0, 0, draw_record.units_of_pixels(4), draw_record.units_of_pixels(2))
	canvas_pixels = {}
	execute(&table, canvas)
	testing.expect(t, canvas_pixels == [4 * 2]graphics.Color{}, "a record past its picture memory draws nothing")
	// A record of a picture memory that the table does not have.
	table.records[0] = draw_record.record_of(draw_record.Draw_Picture{memory = 1, stride = 8}, 0, 0, 0, draw_record.units_of_pixels(4), draw_record.units_of_pixels(2))
	execute(&table, canvas)
	testing.expect(t, canvas_pixels == [4 * 2]graphics.Color{}, "a record of a missing picture memory draws nothing")
}

// A text record whose range is past its text table (a table from another
// process, through the interface module): the difference does not fault,
// and the record differs, so its rectangle is damaged.
@(test)
text_range_past_the_table_is_damaged :: proc(t: ^testing.T) {
	process_drawing_begin()
	text := [4]u8{'a', 'b', 'c', 'd'}
	text_record :: proc(first: u32) -> Draw_Record {
		return draw_record.record_of(draw_record.Draw_Text{first = first, count = 4, color = draw_record.opaque(0), origin_x = draw_record.units_of_pixels(8), size = BODY_TEXT_SIZE}, 0, draw_record.units_of_pixels(8), 0, draw_record.units_of_pixels(16), draw_record.units_of_pixels(16))
	}
	records := [1]Draw_Record{text_record(2)}
	before := Draw_Table{records = records[:], record_count = 1, text = text[:], text_count = 4}
	now := Draw_Table{records = records[:], record_count = 1, text = text[:], text_count = 4}
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{8, 0, 16, 16})
	// The same record inside its table: no damage.
	records[0] = text_record(0)
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
}

// A narrow card cuts its caption: no text record passes its right border.
@(test)
card_caption_stays_inside :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	card(&frame, {8, 8, 200, 100}, "SLOTS", "Process_Report and a long caption", graphics.colors.process, "34")
	for record in table.records[:table.record_count] {
		if view := record_view(record); view.kind == .Text {
			testing.expectf(t, view.x + view.width <= 8 + 200 - 16 + 1, "a text ends at %d, past the border", view.x + view.width)
		}
	}
}

// grid_text gives a text table for the cells of a grid: words, so that it
// starts at an address that is a multiple of 4, as a table with a grid must.
@(private = "file")
grid_text :: proc(words: []u32) -> []u8 {
	return ([^]u8)(raw_data(words))[:len(words) * 4]
}

// A grid where one cell changed damages that cell only; the copy of the
// text table keeps the cells; the cells are copied into the text table
// with no gap between two rows, at a place that is a multiple of 4.
@(test)
text_grid_damage_for_each_cell :: proc(t: ^testing.T) {
	process_drawing_begin()
	cells_now: [3 * 8]Text_Grid_Cell
	for &cell, index in cells_now {
		cell = {character = rune('a' + index % 26), color = 0xFFFFFF}
	}
	grid := Text_Grid{cells = cells_now[:], columns = 6, rows = 3, stride = 8}
	records_now, records_before: [4]Draw_Record
	words_now, words_before: [96]u32
	now := Draw_Table{records = records_now[:], text = grid_text(words_now[:])}
	before := Draw_Table{records = records_before[:], text = grid_text(words_before[:])}
	// A text of 3 bytes before the grid: the cells start at byte 4.
	draw_text(&now, 0, 0, "abc", 0xFFFFFF)
	draw_text_grid(&now, 10, 20, grid)
	testing.expect(t, now.record_count == 2 && !now.full && !now.refused)
	record := now.records[1]
	view := record_view(record)
	testing.expect_value(t, view.kind, Draw_Kind.Text_Grid)
	testing.expect_value(t, view.first, 4)
	testing.expect_value(t, view.count, 6 * 3 * size_of(Text_Grid_Cell))
	testing.expect_value(t, view.columns, 6)
	testing.expect_value(t, record_rectangle(record), Rectangle{10, 20, 10 + 6 * 8, 20 + 3 * 16})
	found, ok := grid_of(&now, record)
	testing.expect(t, ok, "the cells of the record are in the text table")
	testing.expect(t, found.columns == 6 && found.rows == 3 && found.stride == 6)
	testing.expect_value(t, found.cells[1 * 6 + 4], cells_now[1 * 8 + 4])
	testing.expect(t, draw_table_copy(&before, &now))
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	// One cell changed: the next frame copies the cells again.
	cells_now[1 * 8 + 4].character = 'Z'
	draw_table_clear(&now)
	draw_text(&now, 0, 0, "abc", 0xFFFFFF)
	draw_text_grid(&now, 10, 20, grid)
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{10 + 4 * 8, 20 + 16, 10 + 5 * 8, 20 + 32})
	// The cells past the columns of a row are not in the grid.
	damage = {}
	testing.expect(t, draw_table_copy(&before, &now))
	cells_now[7].character = 'Q'
	draw_table_clear(&now)
	draw_text(&now, 0, 0, "abc", 0xFFFFFF)
	draw_text_grid(&now, 10, 20, grid)
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	// The grid at another place in the text table: a longer text before
	// it moves the cells, and the same cells damage nothing.
	draw_table_clear(&now)
	draw_text(&now, 0, 0, "abcdefg", 0xFFFFFF)
	draw_text_grid(&now, 10, 20, grid)
	testing.expect_value(t, record_view(now.records[1]).first, 8)
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], record_rectangle(now.records[0]))
	// A table before with no room for the cells cannot keep a copy.
	small: [4]u32
	before.text = grid_text(small[:])
	testing.expect(t, !draw_table_copy(&before, &now))
	// A text table with no room for the cells: the table is full.
	little := Draw_Table{records = records_now[:], text = grid_text(small[:])}
	draw_text_grid(&little, 0, 0, grid)
	testing.expect(t, little.full && little.record_count == 0)
	// Cells fewer than the rows of the grid: no record.
	grid.rows = 4
	draw_table_clear(&now)
	draw_text_grid(&now, 0, 0, grid)
	testing.expect(t, now.refused && !now.full && now.record_count == 0)
	// A text table at an address that is not a multiple of 4: no record.
	grid.rows = 3
	shifted := Draw_Table{records = records_now[:], text = grid_text(words_now[:])[1:]}
	draw_text_grid(&shifted, 0, 0, grid)
	testing.expect(t, shifted.refused && shifted.record_count == 0)
}

// Text_Grid records of a hostile caller, with any bytes: no column, bytes
// that are not a whole count of rows, a range past the text table, a range
// that would wrap, a place that is not a multiple of 4. None names cells,
// none draws, and the difference damages each one whole.
@(test)
text_grid_records_of_a_hostile_caller :: proc(t: ^testing.T) {
	process_drawing_begin()
	words: [32]u32
	bytes := grid_text(words[:])
	table := Draw_Table{text = bytes, text_count = len(bytes)}
	grid_record :: proc(first, count, columns: u32) -> Draw_Record {
		return draw_record.record_of(draw_record.Draw_Text_Grid{first = first, count = count, columns = columns, size = BODY_TEXT_SIZE}, 0, 0, 0, draw_record.units_of_pixels(16), draw_record.units_of_pixels(16))
	}
	hostile := [?]Draw_Record {
		grid_record(0, 32, 0),
		grid_record(0, 33, 2),
		grid_record(112, 32, 2),
		grid_record(max(u32) - 3, 32, 2),
		grid_record(0, max(u32), max(u32)),
		grid_record(2, 32, 2),
	}
	pixels: [16 * 16]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = 16, height = 16, stride = 16}
	for &word in words {
		word = 0x41414141 // Each cell: a code point past U+10FFFF, which draws the replacement glyph, in a color.
	}
	for record, index in hostile {
		_, ok := grid_of(&table, record)
		testing.expectf(t, !ok, "the hostile record %d names cells", index)
		records := [1]Draw_Record{record}
		one := Draw_Table{records = records[:], record_count = 1, text = bytes, text_count = len(bytes)}
		pixels = {}
		execute(&one, canvas)
		testing.expectf(t, pixels == [16 * 16]graphics.Color{}, "the hostile record %d draws", index)
		damage: Damage
		damage_by_difference(&one, &one, &damage)
		testing.expectf(t, damage.count == 1 && damage.rectangles[0] == Rectangle{0, 0, 16, 16}, "the hostile record %d is not damaged whole", index)
	}
	// The good record over the same bytes: two cells of a row, one row.
	good := grid_record(0, 32, 2)
	found, ok := grid_of(&table, good)
	testing.expect(t, ok && found.rows == 1 && found.columns == 2)
}

// A grid draws its characters and its reverse cells, cut to the canvas.
@(test)
text_grid_draws_its_cells :: proc(t: ^testing.T) {
	pixels: [40 * 32]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = 40, height = 32, stride = 40}
	cells := [2 * 6]Text_Grid_Cell{}
	cells[0] = {character = '#', color = 0x00FF00}
	cells[7] = {character = ' ', reverse = true, color = 0xFF0000}
	cells[5] = {character = '#', color = 0x0000FF} // Past the canvas: cut.
	grid := Text_Grid{cells = cells[:], columns = 6, rows = 2, stride = 6}
	text_grid_draw(canvas, 0, 0, grid)
	green, red := 0, 0
	for pixel in pixels {
		green += int(pixel == 0x00FF00)
		red += int(pixel == 0xFF0000)
	}
	testing.expect(t, green > 0, "the character of the first cell is drawn")
	testing.expectf(t, red == graphics.CELL_WIDTH * graphics.CELL_HEIGHT, "the reverse cell fills its cell: %d pixels", red)
}

// Filled cells: each one is filled with its background, an empty one too,
// and its character has its own color on it.
@(test)
text_grid_draws_filled_cells :: proc(t: ^testing.T) {
	pixels: [40 * 16]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = 40, height = 16, stride = 40}
	cells := [5]Text_Grid_Cell{}
	cells[0] = {character = '#', filled = true, color = 0x00FF00, background = 0x000080}
	cells[1] = {character = 0, filled = true, color = 0x00FF00, background = 0x000080}
	cells[2] = {character = '#', filled = true, color = 0xFF0000, background = 0x000080}
	cells[3] = {character = ' ', filled = true, color = 0xFF0000, background = 0x804000}
	grid := Text_Grid{cells = cells[:], columns = 5, rows = 1, stride = 5}
	text_grid_draw(canvas, 0, 0, grid)
	green, red, blue, brown := 0, 0, 0, 0
	for pixel in pixels {
		green += int(pixel == 0x00FF00)
		red += int(pixel == 0xFF0000)
		blue += int(pixel == 0x000080)
		brown += int(pixel == 0x804000)
	}
	testing.expect(t, green > 0 && red > 0, "the characters of the filled cells are drawn in their colors")
	testing.expectf(t, blue > 2 * graphics.CELL_WIDTH * graphics.CELL_HEIGHT && blue < 3 * graphics.CELL_WIDTH * graphics.CELL_HEIGHT, "three cells have the blue background under two characters: %d pixels", blue)
	testing.expectf(t, brown == graphics.CELL_WIDTH * graphics.CELL_HEIGHT, "the filled space fills its cell: %d pixels", brown)
	testing.expect(t, pixels[4 * graphics.CELL_WIDTH] == 0, "the last cell is not filled")
}

// Two pictures: a frame draws what changed and what its own picture owes,
// and presents what changed, which is where the screen differs. After the
// frame, the other picture owes what changed.
@(test)
two_pictures_present_what_the_screen_shows :: proc(t: ^testing.T) {
	surface := Rectangle{0, 0, 40, 40}
	debts := Picture_Debts{known = {true, true}}
	damage_add(&debts.owed[0], {20, 20, 30, 30}) // The frame before changed this, in the picture 1.
	changed: Damage
	damage_add(&changed, {0, 0, 10, 10})
	draw, present: Damage
	damage_of_picture(&debts, 0, &changed, surface, &draw, &present)
	testing.expect_value(t, draw.count, 2)
	testing.expect_value(t, damage_bounds(&draw), Rectangle{0, 0, 30, 30})
	testing.expect_value(t, present.count, 1)
	testing.expect_value(t, present.rectangles[0], Rectangle{0, 0, 10, 10})
	picture_debts_after(&debts, 0, &changed, true)
	testing.expect_value(t, debts.owed[0].count, 0)
	testing.expect_value(t, debts.owed[1].count, 1)
	testing.expect_value(t, debts.owed[1].rectangles[0], Rectangle{0, 0, 10, 10})
	// A frame that changes nothing: its picture owes, the screen does not.
	// Nothing is presented, so the caller draws nothing.
	changed = {}
	damage_of_picture(&debts, 1, &changed, surface, &draw, &present)
	testing.expect_value(t, draw.count, 1)
	testing.expect_value(t, present.count, 0)
	// A Present that was lost: the picture that was drawn is not known,
	// and its next frame is the whole surface.
	damage_add(&changed, {0, 30, 5, 35})
	picture_debts_after(&debts, 1, &changed, false)
	damage_of_picture(&debts, 1, &changed, surface, &draw, &present)
	testing.expect_value(t, draw.count, 1)
	testing.expect_value(t, draw.rectangles[0], surface)
	testing.expect_value(t, present.count, 1)
	testing.expect_value(t, present.rectangles[0], Rectangle{0, 30, 5, 35})
}

// Two pictures and a screen, as display and the compositor do: each frame
// draws the changed rectangles and the debt of its own picture, presents a
// rectangle, and the screen takes that rectangle of the picture. After each
// frame the screen must be the frame drawn whole. The frames are those of
// the terminal: a grid that scrolls, bars of the graph that come and go, a
// thumb that moves. Some frames repeat the frame before, some lose their
// Present, and one frame in 50 has a new font: no picture is known.
@(test)
two_pictures_screen_is_each_frame :: proc(t: ^testing.T) {
	process_drawing_begin()
	WIDTH :: 120
	HEIGHT :: 120
	COLUMNS :: 12
	ROWS :: 5
	pictures: [2][WIDTH * HEIGHT]graphics.Color
	screen, whole: [WIDTH * HEIGHT]graphics.Color
	canvas_of :: proc(pixels: ^[WIDTH * HEIGHT]graphics.Color) -> graphics.Canvas {
		return {pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	}
	cells: [ROWS * COLUMNS]Text_Grid_Cell
	grid := Text_Grid{cells = cells[:], columns = COLUMNS, rows = ROWS, stride = COLUMNS}
	records_now, records_before: [64]Draw_Record
	// The texts and the cells of the grid, at an address that is a
	// multiple of 4.
	words_now, words_before: [512]u32
	now := Draw_Table{records = records_now[:], text = grid_text(words_now[:])}
	before := Draw_Table{records = records_before[:], text = grid_text(words_before[:])}
	surface := Rectangle{0, 0, WIDTH, HEIGHT}
	debts: Picture_Debts
	drawn := false // The table before is the last frame that was presented.
	picture := 0
	seed: u32 = 7
	presented_frames, lost_presents, frames_with_no_present := 0, 0, 0
	// Pixels that no frame draws: a picture that the rule takes for known
	// while it is not shows them.
	for &pixels in pictures {
		for &pixel in pixels {
			pixel = 0xFF00FF
		}
	}
	for frame in 0 ..< 400 {
		seed = seed * 1103515245 + 12345
		chance := int(seed >> 16) % 16
		// The frame: bars, the grid, a thumb. One frame in 16 is the frame
		// before again.
		step := frame
		if chance == 0 && frame > 0 {
			step = frame - 1
		}
		draw_table_clear(&now)
		bars := u32(step) * 2654435761
		for bar in 0 ..< 6 {
			draw_rectangle(&now, bar * 6, 0, 5, int(bars >> uint(bar * 3)) % 3 * 4, 0x30A050)
		}
		for &cell, index in cells {
			cell = {character = rune('a' + (index / COLUMNS + step * 3) % 26), reverse = (index + step) % 17 == 0, color = 0xE0E0E0}
			if (index + step) % 5 == 0 {
				cell.character = 0
			}
		}
		draw_text_grid(&now, 4, 16, grid)
		draw_rectangle(&now, 110, 16 + step * 7 % 60, 6, 13, 0x5080C0)
		draw_text(&now, 4, 100, step % 2 == 0 ? "line 12" : "line 3", 0xFFFFFF)
		if frame % 50 == 49 {
			debts = {} // A new font: draw_whole_window_next.
		}

		// The reference: the frame drawn whole.
		graphics.clear(canvas_of(&whole), graphics.colors.background)
		execute(&now, canvas_of(&whole))

		// The frame as window_frame_end draws it.
		changed: Damage
		if drawn && !before.full {
			damage_by_difference(&before, &now, &changed)
		} else {
			debts = {}
		}
		draw, present: Damage
		damage_of_picture(&debts, picture, &changed, surface, &draw, &present)
		if present.count == 0 {
			frames_with_no_present += 1
			testing.expectf(t, screen == whole, "frame %d: nothing is presented, and the screen is not the frame", frame)
			drawn = draw_table_copy(&before, &now)
			continue
		}
		draw_damage_on_surface(&now, canvas_of(&pictures[picture]), draw.rectangles[:draw.count])
		testing.expectf(t, pictures[picture] == whole, "frame %d: the picture %d is not the frame", frame, picture)
		// One Present in 16 is lost: the screen and the canvas stay.
		sent := chance != 1
		picture_debts_after(&debts, picture, &changed, sent)
		if !sent {
			lost_presents += 1
			drawn = false
			continue
		}
		presented_frames += 1
		bounds := intersection(damage_bounds(&present), surface)
		for y in bounds.top ..< bounds.bottom {
			for x in bounds.left ..< bounds.right {
				screen[y * WIDTH + x] = pictures[picture][y * WIDTH + x]
			}
		}
		if screen != whole {
			testing.expectf(t, false, "frame %d: the screen is not the frame", frame)
			return
		}
		drawn = draw_table_copy(&before, &now)
		testing.expect(t, drawn)
		picture = 1 - picture
	}
	// The run had each case.
	testing.expectf(t, presented_frames > 200 && lost_presents > 0 && frames_with_no_present > 0, "the run must have each case: %d frames presented, %d Present lost, %d frames with no Present", presented_frames, lost_presents, frames_with_no_present)
}

@(private = "file")
LINE_TEST_WIDTH :: 8
@(private = "file")
LINE_TEST_HEIGHT :: 6

// line_rows draws one line in a canvas of 8 x 6 pixels and compares each
// row with a row written by hand: '#' is a pixel of the line.
@(private = "file")
line_rows :: proc(t: ^testing.T, name: string, from_x, from_y, to_x, to_y, thickness: int, expected: [LINE_TEST_HEIGHT]string) {
	pixels: [LINE_TEST_WIDTH * LINE_TEST_HEIGHT]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = LINE_TEST_WIDTH, height = LINE_TEST_HEIGHT, stride = LINE_TEST_WIDTH}
	memory: Tables
	table := table_of(&memory)
	draw_line(&table, from_x, from_y, to_x, to_y, thickness, 0xFFFFFF)
	testing.expectf(t, table.record_count == 1, "%s: one record, not %d", name, table.record_count)
	execute(&table, canvas)
	for row in 0 ..< LINE_TEST_HEIGHT {
		found: [LINE_TEST_WIDTH]u8
		for column in 0 ..< LINE_TEST_WIDTH {
			found[column] = pixels[row * LINE_TEST_WIDTH + column] == 0xFFFFFF ? '#' : '.'
		}
		testing.expectf(t, string(found[:]) == expected[row], "%s, row %d: %s, not %s", name, row, string(found[:]), expected[row])
	}
}

// The pixels of a line across or down, against pixels written by hand: the
// stroke covers whole pixels, the squares of the line of before.
@(test)
line_pixels_by_hand :: proc(t: ^testing.T) {
	line_rows(t, "horizontal", 1, 1, 4, 1, 1, {
		"........",
		".####...",
		"........",
		"........",
		"........",
		"........",
	})
	line_rows(t, "vertical", 2, 0, 2, 3, 1, {
		"..#.....",
		"..#.....",
		"..#.....",
		"..#.....",
		"........",
		"........",
	})
	// A thickness of 3: a square of 3 x 3 around each point.
	line_rows(t, "thick", 1, 2, 4, 2, 3, {
		"........",
		"######..",
		"######..",
		"######..",
		"........",
		"........",
	})
	// An even thickness starts one pixel before the point.
	line_rows(t, "even thickness", 2, 2, 4, 2, 2, {
		"........",
		".####...",
		".####...",
		"........",
		"........",
		"........",
	})
	// Length 0: one square.
	line_rows(t, "length 0", 5, 4, 5, 4, 3, {
		"........",
		"........",
		"........",
		"....###.",
		"....###.",
		"....###.",
	})
}

// A line at an angle is a stroke with antialiased edges: on the diagonal
// of 1 pixel, each pixel of the diagonal is drawn and is not covered whole
// (its corners are past the half width of the stroke), and no pixel two
// columns or more from the diagonal is drawn. The record is one Path.
@(test)
line_at_an_angle_is_antialiased :: proc(t: ^testing.T) {
	_ = blend_table()
	pixels: [LINE_TEST_WIDTH * LINE_TEST_HEIGHT]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = LINE_TEST_WIDTH, height = LINE_TEST_HEIGHT, stride = LINE_TEST_WIDTH}
	memory: Tables
	table := table_of(&memory)
	draw_line(&table, 0, 0, 5, 5, 1, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 1)
	testing.expect_value(t, record_view(table.records[0]).kind, Draw_Kind.Path)
	execute(&table, canvas)
	for y in 0 ..< LINE_TEST_HEIGHT {
		for x in 0 ..< LINE_TEST_WIDTH {
			pixel := pixels[y * LINE_TEST_WIDTH + x]
			if abs(x - y) >= 2 {
				testing.expectf(t, pixel == 0, "the pixel (%d, %d), two columns from the diagonal, is %06x", x, y, pixel)
			}
		}
	}
	for step in 1 ..= 4 {
		pixel := pixels[step * LINE_TEST_WIDTH + step]
		testing.expectf(t, pixel != 0 && pixel != 0xFFFFFF, "the pixel (%d, %d) of the diagonal is %06x: not an antialiased edge", step, step, pixel)
	}
}

// A small generator of numbers for the tests: the same numbers at each run.
@(private = "file")
next_test_number :: proc(seed: ^u32, below: int) -> int {
	seed^ = seed^ * 1103515245 + 12345
	return int(seed^ >> 16) % below
}

// A line and its reverse are one record and draw the same pixels.
@(test)
line_and_its_reverse_are_one :: proc(t: ^testing.T) {
	_ = blend_table()
	SIDE :: 40
	seed: u32 = 11
	for round in 0 ..< 300 {
		from_x, from_y := next_test_number(&seed, 60) - 10, next_test_number(&seed, 60) - 10
		to_x, to_y := next_test_number(&seed, 60) - 10, next_test_number(&seed, 60) - 10
		thickness := 1 + next_test_number(&seed, 5)
		forward_memory, backward_memory: Tables
		forward, backward := table_of(&forward_memory), table_of(&backward_memory)
		draw_line(&forward, from_x, from_y, to_x, to_y, thickness, 0xFFFFFF)
		draw_line(&backward, to_x, to_y, from_x, from_y, thickness, 0xFFFFFF)
		testing.expectf(t, forward.records[0] == backward.records[0], "round %d: two records", round)
		forward_pixels, backward_pixels: [SIDE * SIDE]graphics.Color
		execute(&forward, {pixels = raw_data(forward_pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
		execute(&backward, {pixels = raw_data(backward_pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
		if forward_pixels != backward_pixels {
			testing.expectf(t, false, "round %d: (%d, %d) to (%d, %d) and its reverse differ", round, from_x, from_y, to_x, to_y)
			return
		}
	}
}

// When lines change, the damage holds each pixel that changed, and the
// surface drawn again in the damage is the new frame drawn whole.
@(test)
line_damage_holds_each_changed_pixel :: proc(t: ^testing.T) {
	_ = blend_table()
	SIDE :: 64
	seed: u32 = 5
	whole_canvas :: proc(pixels: ^[SIDE * SIDE]graphics.Color) -> graphics.Canvas {
		return {pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE}
	}
	for round in 0 ..< 200 {
		before_memory, now_memory: Tables
		before, now := table_of(&before_memory), table_of(&now_memory)
		both := [2]^Draw_Table{&before, &now}
		for table in both {
			for _ in 0 ..< 1 + next_test_number(&seed, 3) {
				draw_line(table, next_test_number(&seed, 100) - 18, next_test_number(&seed, 100) - 18, next_test_number(&seed, 100) - 18, next_test_number(&seed, 100) - 18, 1 + next_test_number(&seed, 6), graphics.Color(0x203040 + next_test_number(&seed, 3) * 0x402010))
			}
		}
		// Some rounds keep the first line: equal records damage nothing.
		if round % 3 == 0 {
			now.records[0] = before.records[0]
		}
		before_pixels, now_pixels: [SIDE * SIDE]graphics.Color
		graphics.clear(whole_canvas(&before_pixels), graphics.colors.background)
		execute(&before, whole_canvas(&before_pixels))
		graphics.clear(whole_canvas(&now_pixels), graphics.colors.background)
		execute(&now, whole_canvas(&now_pixels))
		damage: Damage
		damage_by_difference(&before, &now, &damage)
		for y in 0 ..< SIDE {
			for x in 0 ..< SIDE {
				if before_pixels[y * SIDE + x] == now_pixels[y * SIDE + x] {
					continue
				}
				inside := false
				for rectangle in damage.rectangles[:damage.count] {
					if x >= rectangle.left && x < rectangle.right && y >= rectangle.top && y < rectangle.bottom {
						inside = true
					}
				}
				if !inside {
					testing.expectf(t, false, "round %d: the pixel (%d, %d) changed outside the damage", round, x, y)
					return
				}
			}
		}
		draw_damage_on_surface(&now, whole_canvas(&before_pixels), damage.rectangles[:damage.count])
		testing.expectf(t, before_pixels == now_pixels, "round %d: the surface drawn in the damage is not the frame", round)
	}
}

// Hostile lines: refused, cut, or drawn with no pixel outside their place.
@(test)
line_hostile_values :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	// A thickness of 0 or less: no record.
	draw_line(&table, 0, 0, 10, 10, 0, 0xFFFFFF)
	draw_line(&table, 0, 0, 10, 10, -3, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 0)
	// An end one past the limit, or the smallest or the largest int: no
	// record, on each axis and at each end.
	past := [?]int{LINE_END_LIMIT + 1, -LINE_END_LIMIT - 1, min(int), max(int)}
	for value in past {
		draw_line(&table, value, 0, 4, 4, 1, 0xFFFFFF)
		draw_line(&table, 0, value, 4, 4, 1, 0xFFFFFF)
		draw_line(&table, 0, 0, value, 4, 1, 0xFFFFFF)
		draw_line(&table, 0, 0, 4, value, 1, 0xFFFFFF)
	}
	testing.expect_value(t, table.record_count, 0)
	testing.expect(t, !table.refused && !table.full, "a line past the limit is no record, and no fault of the table")
	// A thickness past the limit is cut to it.
	draw_line(&table, 0, 0, 10, 0, 1000, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 1)
	testing.expect_value(t, record_view(table.records[0]).stroke_width, STROKE_WIDTH_LIMIT * draw_record.UNITS_PER_PIXEL)
	// The ends at the limit, with the widest stroke: a record that the
	// border reads.
	draw_line(&table, -LINE_END_LIMIT, -LINE_END_LIMIT, LINE_END_LIMIT, LINE_END_LIMIT, STROKE_WIDTH_LIMIT, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 2)
	testing.expect(t, record_view(table.records[1]).read, "the line at the limit is refused by the border")

	SIDE :: 16
	pixels: [SIDE * SIDE]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE}
	draw_table_clear(&table)
	draw_line(&table, -LINE_END_LIMIT, 3, LINE_END_LIMIT, 3, 1, 0xFFFFFF)
	execute(&table, canvas)
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			testing.expectf(t, (pixels[y * SIDE + x] == 0xFFFFFF) == (y == 3), "the long line at (%d, %d)", x, y)
		}
	}

	// A line fully outside the canvas: no pixel, and its box holds its
	// squares.
	pixels = {}
	draw_table_clear(&table)
	draw_line(&table, -40, -40, -20, -10, 3, 0xFFFFFF)
	draw_line(&table, SIDE + 4, 0, SIDE + 30, SIDE, 3, 0xFFFFFF)
	execute(&table, canvas)
	testing.expect(t, pixels == [SIDE * SIDE]graphics.Color{}, "no pixel from a line outside")
	testing.expect(t, contains(record_rectangle(table.records[0]), Rectangle{-41, -41, -18, -8}), "the box of a line does not hold its squares")
}

// A picture record that names another picture of the table, with the same
// size and the same generation, is another thing to draw: it is damaged.
@(test)
picture_index_that_changes_is_damaged :: proc(t: ^testing.T) {
	picture_record :: proc(first: u32) -> Draw_Record {
		return draw_record.record_of(draw_record.Draw_Picture{first = first, stride = 16, generation = 7}, 0, draw_record.units_of_pixels(8), draw_record.units_of_pixels(8), draw_record.units_of_pixels(24), draw_record.units_of_pixels(24))
	}
	record_before := [1]Draw_Record{picture_record(0)}
	record_now := [1]Draw_Record{picture_record(1)}
	before := Draw_Table{records = record_before[:], record_count = 1}
	now := Draw_Table{records = record_now[:], record_count = 1}
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{8, 8, 24, 24})
	record_now[0] = picture_record(0)
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
}

// screen_after_damage draws the table before whole on a surface, then the
// table now in its damage only, as window_frame_end does, and says if the
// surface is the table now drawn whole.
@(private = "file")
screen_after_damage :: proc(before, now: ^Draw_Table) -> bool {
	surface := make([]graphics.Color, 320 * 200)
	defer delete(surface)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	canvas := graphics.Canvas{pixels = raw_data(surface), width = 320, height = 200, stride = 320}
	graphics.clear(canvas, graphics.colors.background)
	execute(before, canvas)
	damage: Damage
	damage_by_difference(before, now, &damage)
	draw_damage_on_surface(now, canvas, damage.rectangles[:damage.count])
	whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = 320, height = 200, stride = 320}
	graphics.clear(whole_canvas, graphics.colors.background)
	execute(now, whole_canvas)
	return same_pixels(surface, whole)
}

// Two tables, each with a text table that holds the cells of one grid; the
// cells of the caller, and the grid that describes them.
@(private = "file")
Grid_Tables :: struct {
	records_before, records_now: [8]Draw_Record,
	words_before, words_now:     [20 * 12 * 4 + 16]u32,
	cells:                       [20 * 12]Text_Grid_Cell,
	grid:                        Text_Grid,
	before, now:                 Draw_Table,
}

@(private = "file")
grid_tables_make :: proc(tables: ^Grid_Tables, columns, rows, stride: int) {
	for &cell, index in tables.cells {
		cell = {character = rune('A' + index % 26), reverse = index % 7 == 0, color = graphics.Color(0x406080 + index % 3 * 0x203010)}
	}
	tables.grid = {cells = tables.cells[:], columns = columns, rows = rows, stride = stride}
	tables.now = {records = tables.records_now[:], text = grid_text(tables.words_now[:])}
	tables.before = {records = tables.records_before[:], text = grid_text(tables.words_before[:])}
}

// The grid of the frame before is the copy of the text table that
// draw_table_copy keeps; the grid now changes its size, its stride, its
// place or some cells. In each case the surface drawn again in the damage
// is the frame drawn whole.
@(test)
grid_damage_for_each_change :: proc(t: ^testing.T) {
	process_drawing_begin()
	Change :: enum {
		Cells,
		Columns,
		Rows,
		Stride,
		Place,
	}
	for change in Change {
		tables: Grid_Tables
		grid_tables_make(&tables, 12, 6, 16)
		draw_text_grid(&tables.now, 20, 30, tables.grid)
		testing.expect(t, draw_table_copy(&tables.before, &tables.now), "the copy fits")
		copied, copied_ok := grid_of(&tables.before, tables.before.records[0])
		testing.expect(t, copied_ok && copied.columns == tables.grid.columns && copied.rows == tables.grid.rows, "the table before holds the cells")
		draw_table_clear(&tables.now)
		place_x := 20
		switch change {
		case .Cells:
			tables.cells[2 * 16 + 5].character = '#'
			tables.cells[4 * 16 + 11].reverse = !tables.cells[4 * 16 + 11].reverse
		case .Columns:
			tables.grid.columns = 9
		case .Rows:
			tables.grid.rows = 8
		case .Stride:
			tables.grid.stride = 13
		case .Place:
			place_x = 28
		}
		draw_text_grid(&tables.now, place_x, 30, tables.grid)
		testing.expect_value(t, tables.now.record_count, 1)
		testing.expectf(t, screen_after_damage(&tables.before, &tables.now), "%v: the surface drawn in the damage is not the frame", change)
	}
}

// A table before whose text holds fewer cells than the rows of its grid (a
// copy that a caller made by hand) is damaged whole: no cell is read past
// its end.
@(test)
grid_damage_with_too_few_cells_before :: proc(t: ^testing.T) {
	process_drawing_begin()
	tables: Grid_Tables
	grid_tables_make(&tables, 12, 6, 16)
	draw_text_grid(&tables.now, 20, 30, tables.grid)
	tables.records_before[0] = tables.records_now[0]
	tables.before.record_count = 1
	tables.before.text_count = 10 * size_of(Text_Grid_Cell)
	damage: Damage
	damage_by_difference(&tables.before, &tables.now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], record_rectangle(tables.records_now[0]))
	// A table before with no text: the same.
	tables.before.text = nil
	tables.before.text_count = 0
	damage = {}
	damage_by_difference(&tables.before, &tables.now, &damage)
	testing.expect_value(t, damage.rectangles[0], record_rectangle(tables.records_now[0]))
}

// A grid drawn in damage rectangles that cut its cells, at negative places
// and with rectangles smaller than a cell, gives the pixels of the whole
// frame.
@(test)
text_grid_in_rectangles_equals_whole :: proc(t: ^testing.T) {
	process_drawing_begin()
	tables: Grid_Tables
	grid_tables_make(&tables, 20, 12, 20)
	draw_text_grid(&tables.now, -13, -21, tables.grid)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	parts := make([]graphics.Color, 320 * 200)
	defer delete(parts)
	whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = 320, height = 200, stride = 320}
	parts_canvas := graphics.Canvas{pixels = raw_data(parts), width = 320, height = 200, stride = 320}
	graphics.clear(whole_canvas, graphics.colors.background)
	execute(&tables.now, whole_canvas)
	graphics.clear(parts_canvas, 0x123456)
	// Rectangles of 5 x 7 pixels, smaller than a cell, that cover the surface.
	for top := 0; top < 200; top += 7 {
		for left := 0; left < 320; left += 5 {
			rectangle := [1]Rectangle{{left, top, min(left + 5, 320), min(top + 7, 200)}}
			draw_damage_on_surface(&tables.now, parts_canvas, rectangle[:])
		}
	}
	testing.expect(t, same_pixels(whole, parts), "the grid drawn in rectangles is the whole frame")
}

// draw_table_copy with too little room gives false: the caller draws the
// next frame of that picture whole.
@(test)
draw_table_copy_with_too_little_room :: proc(t: ^testing.T) {
	process_drawing_begin()
	memory: Tables
	source := table_of(&memory)
	draw_rectangle(&source, 0, 0, 4, 4, 1)
	draw_text(&source, 0, 0, "twelve bytes", 1)
	few_records: [1]Draw_Record
	enough_text: [64]u8
	target := Draw_Table{records = few_records[:], text = enough_text[:]}
	testing.expect(t, !draw_table_copy(&target, &source), "two records do not fit in one")
	enough_records: [4]Draw_Record
	few_bytes: [4]u8
	target = {records = enough_records[:], text = few_bytes[:]}
	testing.expect(t, !draw_table_copy(&target, &source), "twelve bytes do not fit in four")
	target = {records = enough_records[:], text = enough_text[:]}
	testing.expect(t, draw_table_copy(&target, &source))
	testing.expect_value(t, target.record_count, 2)
}

// damage_add on random rectangles: at the end the rectangles are apart (no
// two touch), there are at most DAMAGE_CAPACITY, and they cover each
// rectangle that was added.
@(test)
damage_add_keeps_rectangles_apart_and_covers_each :: proc(t: ^testing.T) {
	seed: u32 = 23
	for round in 0 ..< 500 {
		damage: Damage
		added: [24]Rectangle
		count := 1 + next_test_number(&seed, len(added))
		for index in 0 ..< count {
			left, top := next_test_number(&seed, 300), next_test_number(&seed, 180)
			added[index] = {left, top, left + 1 + next_test_number(&seed, 40), top + 1 + next_test_number(&seed, 30)}
			damage_add(&damage, added[index])
		}
		testing.expect(t, damage.count <= DAMAGE_CAPACITY)
		for first in 0 ..< damage.count {
			for second in first + 1 ..< damage.count {
				a, b := damage.rectangles[first], damage.rectangles[second]
				apart := a.left > b.right || b.left > a.right || a.top > b.bottom || b.top > a.bottom
				if !apart {
					testing.expectf(t, false, "round %d: the rectangles %v and %v touch", round, a, b)
					return
				}
			}
		}
		for rectangle in added[:count] {
			covered := false
			for kept in damage.rectangles[:damage.count] {
				if kept.left <= rectangle.left && kept.top <= rectangle.top && kept.right >= rectangle.right && kept.bottom >= rectangle.bottom {
					covered = true
				}
			}
			if !covered {
				testing.expectf(t, false, "round %d: %v is not covered", round, rectangle)
				return
			}
		}
	}
}

// A push that becomes another kind of record at the same index, a pop that
// becomes a rectangle, and the inner of two clips that moves: each record
// whose cut changes is damaged, and the surface is the frame.
@(test)
clip_that_changes_kind :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_clip_push(&before, 10, 10, 60, 40)
	draw_rectangle(&before, 0, 0, 200, 100, graphics.colors.kernel)
	draw_clip_pop(&before)
	draw_rectangle(&now, 10, 10, 60, 40, graphics.colors.process)
	draw_rectangle(&now, 0, 0, 200, 100, graphics.colors.kernel)
	draw_rectangle(&now, 0, 0, 1, 1, graphics.colors.kernel)
	testing.expect(t, screen_after_damage(&before, &now), "a clip that becomes a rectangle")
	testing.expect(t, screen_after_damage(&now, &before), "a rectangle that becomes a clip")
	draw_table_clear(&before)
	draw_table_clear(&now)
	// The pop leaves early: the rectangle after it is no longer cut.
	draw_clip_push(&before, 0, 0, 100, 100)
	draw_rectangle(&before, 0, 0, 10, 10, graphics.colors.memory)
	draw_clip_pop(&before)
	draw_rectangle(&before, 0, 0, 320, 200, graphics.colors.kernel)
	draw_clip_push(&now, 0, 0, 100, 100)
	draw_clip_pop(&now)
	draw_rectangle(&now, 0, 0, 10, 10, graphics.colors.memory)
	draw_rectangle(&now, 0, 0, 320, 200, graphics.colors.kernel)
	testing.expect(t, screen_after_damage(&before, &now), "a pop that moves before a rectangle")
	testing.expect(t, screen_after_damage(&now, &before), "a pop that moves after a rectangle")
	draw_table_clear(&before)
	draw_table_clear(&now)
	draw_clip_push(&before, 0, 0, 100, 100)
	draw_clip_push(&before, 50, 50, 100, 100)
	draw_rectangle(&before, 0, 0, 320, 200, graphics.colors.kernel)
	draw_clip_pop(&before)
	draw_clip_pop(&before)
	draw_clip_push(&now, 0, 0, 100, 100)
	draw_clip_push(&now, 20, 20, 100, 100)
	draw_rectangle(&now, 0, 0, 320, 200, graphics.colors.kernel)
	draw_clip_pop(&now)
	draw_clip_pop(&now)
	testing.expect(t, screen_after_damage(&before, &now), "the second of two clips changes")
}

// The picture on the screen is not known: it can show a record that the
// frame now does not have, far from each changed rectangle. The present
// covers it, because it is the whole surface. The picture that the process
// draws is known, and draws its changed rectangle only.
@(test)
two_pictures_unknown_shown_picture_presents_all :: proc(t: ^testing.T) {
	surface := Rectangle{0, 0, 320, 200}
	debts := Picture_Debts{known = {true, false}}
	changed: Damage
	damage_add(&changed, {0, 0, 10, 10})
	draw, present: Damage
	damage_of_picture(&debts, 0, &changed, surface, &draw, &present)
	testing.expect_value(t, draw.count, 1)
	testing.expect_value(t, draw.rectangles[0], Rectangle{0, 0, 10, 10})
	testing.expect_value(t, present.count, 1)
	testing.expect_value(t, present.rectangles[0], surface)
	// No picture is known: the first frame of a window.
	debts = {}
	changed = {}
	damage_of_picture(&debts, 0, &changed, surface, &draw, &present)
	testing.expect_value(t, draw.rectangles[0], surface)
	testing.expect_value(t, present.rectangles[0], surface)
}

// Each edge of a record is cut to COORDINATE_LIMIT, then the size is the
// difference: a rectangle that covers the surface with places past the i32
// still covers it.
@(test)
coordinates_cut_by_their_edges :: proc(t: ^testing.T) {
	process_drawing_begin()
	memory: Tables
	table := table_of(&memory)
	draw_rectangle(&table, -3_000_000_000, -3_000_000_000, 5_000_000_000, 5_000_000_000, 1)
	area := record_rectangle(table.records[0])
	testing.expect(t, area.left <= 0 && area.top <= 0 && area.right >= 320 && area.bottom >= 200, "the rectangle still covers the surface")
	testing.expect(t, record_view(table.records[0]).read && record_view(table.records[0]).width > 0 && record_view(table.records[0]).height > 0)
	// No sum passes the int.
	draw_rectangle(&table, max(int) - 2, 0, max(int), 10, 1)
	area = record_rectangle(table.records[1])
	testing.expect_value(t, area.left, COORDINATE_LIMIT - 1)
	testing.expect_value(t, area.right, COORDINATE_LIMIT - 1)
	// A text whose origin is past the limit has no record: no surface
	// reaches it. At the limit, its origin is the left edge of its box.
	draw_text(&table, min(int) + 1, 0, "text", 1)
	draw_text(&table, -COORDINATE_LIMIT - 1, 0, "text", 1)
	draw_text(&table, COORDINATE_LIMIT, 0, "text", 1)
	testing.expect_value(t, table.record_count, 2)
	draw_text(&table, -COORDINATE_LIMIT, 0, "text", 1)
	testing.expect_value(t, record_view(table.records[2]).x, -COORDINATE_LIMIT)
	testing.expect_value(t, record_view(table.records[2]).origin_x, draw_record.units_of_pixels(-COORDINATE_LIMIT))
	// A rectangle inside the limit keeps its place and its size.
	draw_rectangle(&table, -7, 12, 30, 5, 1)
	testing.expect_value(t, record_rectangle(table.records[3]), Rectangle{-7, 12, 23, 17})
}

// Numbers of a grid that would wrap a product are refused, and the record
// is refused with no change of full.
@(test)
grid_numbers_that_wrap_are_refused :: proc(t: ^testing.T) {
	process_drawing_begin()
	cells: [16]Text_Grid_Cell
	wrapping := [?]Text_Grid {
		{cells = cells[:], columns = 4, rows = max(int) / 2, stride = 4},
		{cells = cells[:], columns = 4, rows = 3, stride = max(int) / 2 + 1},
		{cells = cells[:], columns = 4, rows = 2, stride = -4},
		{cells = cells[:], columns = 17, rows = 1, stride = 17},
		{cells = cells[:], columns = -1, rows = 1, stride = 4},
	}
	for grid, index in wrapping {
		testing.expectf(t, !grid_valid(grid), "grid %d is refused", index)
		testing.expectf(t, grid_size(grid) == 0, "grid %d has no size", index)
	}
	testing.expect(t, grid_valid({cells = cells[:], columns = 4, rows = 4, stride = 4}))
	testing.expect_value(t, grid_size({cells = cells[:], columns = 3, rows = 4, stride = 4}), 15)
	records: [2]Draw_Record
	words: [64]u32
	table := Draw_Table{records = records[:], text = grid_text(words[:])}
	draw_text_grid(&table, 0, 0, wrapping[0])
	testing.expect(t, table.refused && !table.full && table.record_count == 0)
}

// The procedures of window_frame_end itself, on a window in plain memory:
// the gate, the changes, the show. The test is the compositor: it takes
// the records of the ring of the window and copies the rectangle of each
// Present from the picture that the record names to a screen. After each
// Present that it takes, the screen must be the frame drawn whole.
//
// The frames: 12 squares apart, more than a damage holds. One square
// changes, or each one. Some frames find a compositor that did not take
// the picture before and are left out; some lose their Present to a full
// ring; some have more records than their table holds.
//
// The window is at the scale 1.375, whose edges round: its records and its
// damage are logical, its pictures and each Present are pixels of the
// screen, and a damage that missed a pixel of the screen shows.
@(test)
window_frame_end_shows_each_frame_whole :: proc(t: ^testing.T) {
	// Each Present starts a frame of the glyph cache of the process.
	process_drawing_begin()
	LOGICAL_SIZE :: 96
	SCALE :: scale_factor.Scale.Eleven_Eighths
	WIDTH :: (LOGICAL_SIZE * int(SCALE) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE
	HEIGHT :: WIDTH
	SQUARES :: 12
	Pixels :: [WIDTH * HEIGHT]graphics.Color
	pictures: [2]Pixels
	screen, whole, presented_whole: Pixels
	canvas_of :: proc(pixels: ^Pixels) -> graphics.Canvas {
		return {pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	}
	// Pixels that no frame draws: a picture that the rule takes for known
	// while it is not shows them.
	for &pixels in pictures {
		for &pixel in pixels {
			pixel = 0xFF00FF
		}
	}
	counters: ring.Counters
	ring_records: [8]ring.Record
	window: display.Window
	window.ring.commands = {counters = &counters, records = raw_data(ring_records[:]), mask = 7}
	window.pictures = {canvas_of(&pictures[0]), canvas_of(&pictures[1])}
	window.canvas = window.pictures[0]
	window.width, window.height = LOGICAL_SIZE, LOGICAL_SIZE
	window.rescale = {phase = .Steady, scale = SCALE, wanted = SCALE, serial = 1}
	testing.expect_value(t, WIDTH, int(scale_factor.screen_pixel_of_logical_pixel(LOGICAL_SIZE, SCALE)))
	records_now, records_before: [32]Draw_Record
	text_now, text_before: [64]u8
	drawing := window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	// The table is drawn at the scale of the window, as window_frame_begin
	// sets it; the reference below draws it whole at the same scale.
	drawing.now.scale = SCALE
	colors: [SQUARES]graphics.Color
	palette := [3]graphics.Color{0x30A050, 0x5080C0, 0xE0E0E0}
	seed: u32 = 11
	waits := false // A Present is in the ring: the compositor did not take it.
	presents_taken, left_out, lost, full_tables, wide_changes, one_square := 0, 0, 0, 0, 0, 0
	for frame in 0 ..< 800 {
		seed = seed * 1103515245 + 12345
		chance := int(seed >> 16) % 16
		// The compositor takes the records of the ring, unless it is late
		// for this frame.
		late := chance == 0 && waits
		if !late {
			for {
				record := ring.pop(&window.ring.commands) or_break
				if display.Command(record.kind) != .Present {
					continue
				}
				from := &pictures[int(record.values[0])]
				left, top, width, height := int(record.values[1]), int(record.values[2]), int(record.values[3]), int(record.values[4])
				if width == 0 {
					width, height = WIDTH - left, HEIGHT - top
				}
				for y in top ..< top + height {
					for x in left ..< left + width {
						screen[y * WIDTH + x] = from[y * WIDTH + x]
					}
				}
				presents_taken += 1
				if screen != presented_whole {
					testing.expectf(t, false, "frame %d: the screen is not the frame that the Present before it showed", frame)
					return
				}
			}
			waits = false
		}

		// The frame.
		changed_squares := 0
		if chance >= 12 {
			square := frame % SQUARES
			colors[square] = palette[(int(seed >> 8) + 1) % 3] == colors[square] ? palette[int(seed >> 8) % 3] : palette[(int(seed >> 8) + 1) % 3]
			changed_squares = 1
			one_square += 1
		} else {
			for &color, index in colors {
				next := palette[int(seed >> uint(index)) % 3]
				changed_squares += int(next != color)
				color = next
			}
		}
		if changed_squares > DAMAGE_CAPACITY {
			wide_changes += 1
		}
		draw_table_clear(&drawing.now)
		for color, index in colors {
			draw_rectangle(&drawing.now, index % 4 * 24 + 4, index / 4 * 24 + 4, 8, 8, color)
		}
		if chance == 2 {
			// More records than the table holds: the table is full.
			for _ in 0 ..< len(records_now) {
				draw_rectangle(&drawing.now, 90, 90, 2, 2, 0xFFFFFF)
			}
			testing.expect(t, drawing.now.full)
			full_tables += 1
		}
		graphics.clear(canvas_of(&whole), graphics.colors.background)
		execute(&drawing.now, canvas_of(&whole))

		if late {
			// The compositor did not take the picture before, and the
			// bound of the wait passed at an earlier frame.
			window.compositor_late = true
			testing.expectf(t, !window_frame_gate(&drawing, &window), "frame %d: the canvas is not free, and the frame is drawn", frame)
			testing.expect(t, drawing.late)
			left_out += 1
			continue
		}
		if chance == 1 {
			// A full ring: the Present of this frame is lost.
			for ring.push(&window.ring.commands, ring.Record{}) {
			}
		}
		if !window_frame_gate(&drawing, &window) {
			testing.expectf(t, false, "frame %d: the canvas is free, and the frame is left out", frame)
			return
		}
		changes := window_frame_changes(&drawing, &window)
		window_frame_show(&drawing, &window, &changes)
		if changes.present.count == 0 {
			testing.expectf(t, screen == whole, "frame %d: nothing is presented, and the screen is not the frame", frame)
			continue
		}
		testing.expectf(t, pictures[changes.picture] == whole, "frame %d: the picture %d is not the frame", frame, changes.picture)
		if chance == 1 {
			testing.expectf(t, !drawing.drawn && window.picture == changes.picture, "frame %d: a lost Present keeps the canvas, and the frame is not the last table", frame)
			lost += 1
			continue
		}
		testing.expectf(t, window.picture == 1 - changes.picture, "frame %d: a Present changes the canvas to the other picture", frame)
		waits = true
		presented_whole = whole
	}
	testing.expectf(t, presents_taken > 400 && left_out > 0 && lost > 0 && full_tables > 0 && wide_changes > 0 && one_square > 0, "the run must have each case: %d Present taken, %d frames left out, %d Present lost, %d full tables, %d frames with more changes than a damage holds, %d frames with one square", presents_taken, left_out, lost, full_tables, wide_changes, one_square)
}

// A new font makes the next frame of each picture whole: with two pictures,
// the second one must not keep text in the old font.
@(test)
whole_window_next_forgets_each_picture :: proc(t: ^testing.T) {
	drawing: Window_Drawing
	drawing.debts.known = {true, true}
	draw_whole_window_next(&drawing)
	testing.expect(t, !drawing.debts.known[0] && !drawing.debts.known[1])
}

// A change of the text settings that another reader took first (next_event
// applies the page before the frame does) still makes the next frame of
// each picture whole. A window whose frame saw no change kept the
// background of the old appearance wherever no record covers its surface.
@(test)
a_change_of_the_text_settings_read_elsewhere_draws_the_window_whole :: proc(t: ^testing.T) {
	saved := display.text_settings_generation
	defer display.text_settings_generation = saved

	// No change since the last frame: the pictures stay known.
	drawing: Window_Drawing
	display.text_settings_generation = 0
	drawing.debts.known = {true, true}
	testing.expect(t, !text_settings_follow(&drawing))
	testing.expect(t, drawing.debts.known[0] && drawing.debts.known[1])

	// One change, read before the frame: both pictures are drawn whole.
	display.text_settings_generation = 1
	testing.expect(t, text_settings_follow(&drawing))
	testing.expect(t, !drawing.debts.known[0] && !drawing.debts.known[1])
	testing.expect_value(t, drawing.text_settings_generation, u64(1))

	// The same change is followed once: the next frame keeps its pictures.
	drawing.debts.known = {true, true}
	testing.expect(t, !text_settings_follow(&drawing))
	testing.expect(t, drawing.debts.known[0] && drawing.debts.known[1])

	// Several changes between two frames are one whole frame.
	display.text_settings_generation = 5
	testing.expect(t, text_settings_follow(&drawing))
	testing.expect(t, !text_settings_follow(&drawing))

	// The number wraps past its largest value: a change is still a change.
	display.text_settings_generation = max(u64)
	testing.expect(t, text_settings_follow(&drawing))
	display.text_settings_generation += 1
	drawing.debts.known = {true, true}
	testing.expect(t, text_settings_follow(&drawing))
	testing.expect(t, !drawing.debts.known[0] && !drawing.debts.known[1])
}

// The records of a table as a list of their texts: has_text says if one
// record draws exactly this text.
@(private = "file")
has_text :: proc(table: ^Draw_Table, text: string) -> bool {
	for record in table.records[:table.record_count] {
		if found, _, is_text := text_of_record(table, record); is_text && found == text {
			return true
		}
	}
	return false
}

@(private = "file")
rectangles_of_color :: proc(table: ^Draw_Table, color: graphics.Color) -> (count: int, last: Draw_Record) {
	for record in table.records[:table.record_count] {
		if view := record_view(record); is_solid_rectangle(view) && view.color == color {
			count += 1
			last = record
		}
	}
	return
}

// rectangles_in_box counts the rectangles of one color that are whole
// inside a box, and their pixels.
@(private = "file")
rectangles_in_box :: proc(table: ^Draw_Table, color: graphics.Color, x, y, width, height: int) -> (count: int, pixels: int) {
	for record in table.records[:table.record_count] {
		view := record_view(record)
		if !is_solid_rectangle(view) || view.color != color {
			continue
		}
		if view.x >= x && view.y >= y && view.x + view.width <= x + width && view.y + view.height <= y + height {
			count += 1
			pixels += view.width * view.height
		}
	}
	return
}

// set_cells_of counts the cells of an icon.
@(private = "file")
set_cells_of :: proc(icon: ^kind_icons.Cells) -> (count: int) {
	for y in 0 ..< kind_icons.ICON_SIZE {
		for x in 0 ..< kind_icons.ICON_SIZE {
			count += kind_icons.cell_is_set(icon, x, y) ? 1 : 0
		}
	}
	return
}

// An icon of a kind is its cells, each one a square of whole pixels, at
// each cell size: every pixel of a set cell has the color, and no other
// pixel is drawn.
@(test)
kind_icon_is_its_cells_at_each_cell_size :: proc(t: ^testing.T) {
	SIDE :: 48
	LEFT :: 5
	TOP :: 7
	memory: Tables
	table := table_of(&memory)
	icons := [?]^kind_icons.Cells{kind_icons.cells_of_value_kind(.Command), kind_icons.cells_of_value_kind(.Variable), kind_icons.cells_of_desktop_kind(.Stop)}
	for icon in icons {
		for cell_size in 1 ..= 3 {
			draw_table_clear(&table)
			draw_kind_icon(&table, LEFT, TOP, icon, cell_size, graphics.colors.process)
			testing.expect(t, !table.full && table.record_count <= kind_icons.RECTANGLE_LIMIT)
			pixels: [SIDE * SIDE]graphics.Color
			execute(&table, {pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
			wrong := 0
			for y in 0 ..< SIDE {
				for x in 0 ..< SIDE {
					set := x >= LEFT && y >= TOP && kind_icons.cell_is_set(icon, (x - LEFT) / cell_size, (y - TOP) / cell_size)
					expected := set ? graphics.Color(graphics.colors.process) : graphics.Color(0)
					wrong += pixels[y * SIDE + x] == expected ? 0 : 1
				}
			}
			testing.expectf(t, wrong == 0, "an icon at the cell size %d: %d pixels are not its cells", cell_size, wrong)
		}
	}
	// No icon and no cell size: no record.
	draw_table_clear(&table)
	draw_kind_icon(&table, 0, 0, nil, 1, graphics.colors.process)
	draw_kind_icon(&table, 0, 0, icons[0], 0, graphics.colors.process)
	testing.expect_value(t, table.record_count, 0)
}

// A list of rows: a heading is a dim text with no icon; an entry has the
// icon of its kind, its name and its text at the right; the chosen row is
// filled, its icon is white, its hint takes the place of the text at the
// right, and a line of 2 pixels is under each run of matched characters.
@(test)
list_of_rows_draws_icons_matches_and_the_choice :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	window_icon := kind_icons.cells_of_desktop_kind(.Window)
	module_icon := kind_icons.cells_of_value_kind(.Module)
	rows := [?]List_Row {
		{kind = .Heading, name = "windows"},
		{name = "console", icon = window_icon, icon_color = graphics.colors.title, right_text = "window"},
		// The bytes 0, 1 and 3 matched: two runs.
		{name = "plasma", matched_places = 0b1011, icon = module_icon, icon_color = graphics.colors.process, right_text = "process"},
		{name = "paint", right_text = "process"},
	}
	icon_y :: proc(row: int) -> int {
		return row * TABLE_LINE + (TABLE_LINE - LIST_ROW_ICON_SIZE) / 2
	}
	frame := frame_begin(&table, &state, &input)
	shown := list_of_rows(&frame, {0, 0, 320, 96}, rows[:], {chosen = 2, chosen_hint = "enter: start", total = len(rows)})
	frame_end(&frame)
	testing.expect_value(t, shown, 4)
	testing.expect(t, has_text(&table, "windows") && has_text(&table, "console") && has_text(&table, "plasma") && has_text(&table, "paint"))
	// The chosen row: one fill of its whole line, its hint and not its kind.
	count, fill := rectangles_of_color(&table, graphics.colors.chosen)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, record_view(fill).y, 2 * TABLE_LINE)
	testing.expect_value(t, record_view(fill).width, 320)
	testing.expect_value(t, record_view(fill).height, TABLE_LINE)
	testing.expect(t, has_text(&table, "enter: start"))
	// The words at the right of the two rows that are not chosen.
	words := 0
	for record in table.records[:table.record_count] {
		if found, _, is_text := text_of_record(&table, record); is_text && found == "process" {
			words += 1
			view := record_view(record)
			testing.expect_value(t, view.color, graphics.colors.dim)
			testing.expect_value(t, view.x + view.width, 320 - LIST_ROW_RIGHT_MARGIN)
		}
	}
	testing.expect_value(t, words, 1)
	// The icons: the one of the row that is not chosen keeps its color,
	// and each of its cells is drawn once, in the box of 12 pixels before
	// the name; the one of the chosen row is white, and no rectangle has
	// its own color. A row with no icon draws none.
	pixels: int
	count, pixels = rectangles_in_box(&table, graphics.colors.title, LIST_ROW_ICON_X, icon_y(1), LIST_ROW_ICON_SIZE, LIST_ROW_ICON_SIZE)
	testing.expect_value(t, pixels, set_cells_of(window_icon))
	all_of_color, _ := rectangles_of_color(&table, graphics.colors.title)
	testing.expect_value(t, all_of_color, count)
	_, pixels = rectangles_in_box(&table, graphics.COLOR_WHITE, LIST_ROW_ICON_X, icon_y(2), LIST_ROW_ICON_SIZE, LIST_ROW_ICON_SIZE)
	testing.expect_value(t, pixels, set_cells_of(module_icon))
	count, _ = rectangles_of_color(&table, graphics.colors.process)
	testing.expect_value(t, count, 0)
	for record in table.records[:table.record_count] {
		if view := record_view(record); is_solid_rectangle(view) && view.y >= 3 * TABLE_LINE {
			testing.expectf(t, false, "a row with no icon has a rectangle at %d,%d", view.x, view.y)
		}
	}
	testing.expect(t, LIST_ROW_NAME_X >= LIST_ROW_ICON_X + LIST_ROW_ICON_SIZE + 8, "the name starts after the icon and a gap")
	// The lines under the matched runs of the chosen row are white, and
	// each run is one line: "pl" (2 cells) and "s" (1 cell).
	lines: [2]Draw_Record
	line_count := 0
	for record in table.records[:table.record_count] {
		if view := record_view(record); is_solid_rectangle(view) && view.height == 2 && view.y == 2 * TABLE_LINE + 20 {
			testing.expect_value(t, view.color, graphics.COLOR_WHITE)
			if line_count < len(lines) {
				lines[line_count] = record
			}
			line_count += 1
		}
	}
	testing.expect_value(t, line_count, 2)
	testing.expect_value(t, record_view(lines[0]).x, LIST_ROW_NAME_X)
	testing.expect_value(t, record_view(lines[0]).width, 2 * graphics.CELL_WIDTH)
	testing.expect_value(t, record_view(lines[1]).x, LIST_ROW_NAME_X + 3 * graphics.CELL_WIDTH)
	testing.expect_value(t, record_view(lines[1]).width, graphics.CELL_WIDTH)
	// An icon in the blue that the chosen blue is made from has no
	// contrast on its own chosen row: it is white there, as each icon is.
	frame = frame_begin(&table, &state, &input)
	list_of_rows(&frame, {0, 0, 320, 96}, rows[:], {chosen = 1, total = len(rows)})
	frame_end(&frame)
	count, _ = rectangles_of_color(&table, graphics.colors.chosen)
	testing.expect_value(t, count, 1) // The fill of the row.
	count, _ = rectangles_of_color(&table, graphics.colors.title)
	testing.expect_value(t, count, 0)
	_, pixels = rectangles_in_box(&table, graphics.COLOR_WHITE, LIST_ROW_ICON_X, icon_y(1), LIST_ROW_ICON_SIZE, LIST_ROW_ICON_SIZE)
	testing.expect_value(t, pixels, set_cells_of(window_icon))
	// The row of the question: the same white icon on the red of the act.
	frame = frame_begin(&table, &state, &input)
	list_of_rows(&frame, {0, 0, 320, 96}, rows[:], {chosen = 2, chosen_color = graphics.colors.stop_process, total = len(rows)})
	frame_end(&frame)
	_, pixels = rectangles_in_box(&table, graphics.COLOR_WHITE, LIST_ROW_ICON_X, icon_y(2), LIST_ROW_ICON_SIZE, LIST_ROW_ICON_SIZE)
	testing.expect_value(t, pixels, set_cells_of(module_icon))
	// With no choice, no row is filled, and a line under a match is in the accent.
	frame = frame_begin(&table, &state, &input)
	list_of_rows(&frame, {0, 0, 320, 96}, rows[:], {chosen = -1, total = len(rows)})
	frame_end(&frame)
	count, _ = rectangles_of_color(&table, graphics.colors.kernel)
	testing.expect_value(t, count, 2)
}

// A list of rows draws only the rows of its area, and shows a scroll bar
// at the right when the whole list has more rows.
@(test)
list_of_rows_draws_the_rows_of_its_area :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	rows: [8]List_Row
	for &row in rows {
		row = {name = "a row", right_text = "kind"}
	}
	frame := frame_begin(&table, &state, &input)
	shown := list_of_rows(&frame, {0, 0, 320, 3 * TABLE_LINE}, rows[:], {chosen = 0, first = 10, total = 40})
	frame_end(&frame)
	testing.expect_value(t, shown, 3)
	// The fill of the chosen row stops before the bar.
	count, fill := rectangles_of_color(&table, graphics.colors.chosen)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, record_view(fill).width, 320 - LIST_ROW_SCROLL_WIDTH)
	// The scroll bar: its track over the height of the rows, and its thumb
	// at the place of the rows shown (the element, with no input).
	bar_colors := graphics.scroll_bar_colors_dark
	bar_geometry := scroll_bar_geometry(3 * TABLE_LINE, LIST_ROW_SCROLL_WIDTH, {total = 40, visible = 3, first = 10})
	count, fill = rectangles_of_color(&table, bar_colors.track_border)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, record_view(fill).x, 320 - LIST_ROW_SCROLL_WIDTH)
	testing.expect_value(t, record_view(fill).height, 3 * TABLE_LINE)
	count, fill = rectangles_of_color(&table, bar_colors.thumb_border)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, record_view(fill).y, bar_geometry.thumb_start)
	testing.expect_value(t, record_view(fill).height, bar_geometry.thumb_length)
	// A name longer than its room is cut: no text passes the list.
	long := [?]List_Row{{name = "a name that is far longer than the room of a narrow list of rows", right_text = "kind"}}
	frame = frame_begin(&table, &state, &input)
	list_of_rows(&frame, {0, 0, 160, TABLE_LINE}, long[:], {chosen = -1, total = 1})
	frame_end(&frame)
	for record in table.records[:table.record_count] {
		view := record_view(record)
		testing.expect(t, view.x + view.width <= 160)
	}
}

// A text input line: the field reaches each edge of its area, the line of
// 2 pixels is its last 2 pixels, the caret stands at any place of the
// text at the scale of the text, and a long text shows the part that holds
// the caret.
@(test)
text_input_line_draws_a_caret_at_any_place :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	build :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, text: string, caret: int, scale: int) {
		frame := frame_begin(table, state, input)
		text_input_line(&frame, {32, 16, 320, 48}, text, caret, text_size_of_scale(scale), "type here")
		frame_end(&frame)
	}
	caret_of :: proc(table: ^Draw_Table) -> Draw_Record {
		for record in table.records[:table.record_count] {
			if view := record_view(record); is_solid_rectangle(view) && view.color == graphics.colors.title && view.height != 2 {
				return record
			}
		}
		return {}
	}
	rectangle_of :: proc(x, y, width, height: int, color: graphics.Color, element: u32) -> Draw_Record {
		return draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(color)}, element, draw_record.units_of_pixels(x), draw_record.units_of_pixels(y), draw_record.units_of_pixels(x + width), draw_record.units_of_pixels(y + height))
	}
	build(&table, &state, &input, "", 0, 2)
	// The element push, then the field and its line, from edge to edge.
	line_element := u32(identity("text_input_line"))
	testing.expect_value(t, record_view(table.records[0]).kind, Draw_Kind.Element_Push)
	testing.expect_value(t, table.records[1], rectangle_of(32, 16, 320, 46, graphics.colors.track, line_element))
	testing.expect_value(t, table.records[2], rectangle_of(32, 62, 320, 2, graphics.colors.title, line_element))
	testing.expect(t, has_text(&table, "type here"))
	caret := caret_of(&table)
	testing.expect_value(t, record_view(caret).x, 32 + TEXT_INPUT_LINE_MARGIN)
	testing.expect_value(t, record_view(caret).y, 16 + 8)
	testing.expect_value(t, record_view(caret).width, 4)
	testing.expect_value(t, record_view(caret).height, 32)
	// A caret inside the text, at scale 2: cells of 16 pixels.
	build(&table, &state, &input, "plasma", 2, 2)
	testing.expect(t, has_text(&table, "plasma") && !has_text(&table, "type here"))
	testing.expect_value(t, record_view(caret_of(&table)).x, 32 + TEXT_INPUT_LINE_MARGIN + 2 * 16)
	// At scale 1: cells of 8 pixels, a caret of 2 by 16.
	build(&table, &state, &input, "plasma", 6, 1)
	caret = caret_of(&table)
	testing.expect_value(t, record_view(caret).x, 32 + TEXT_INPUT_LINE_MARGIN + 6 * 8)
	testing.expect_value(t, record_view(caret).width, 2)
	testing.expect_value(t, record_view(caret).height, 16)
	// A caret past the text is at its end.
	build(&table, &state, &input, "ab", 9, 2)
	testing.expect_value(t, record_view(caret_of(&table)).x, 32 + TEXT_INPUT_LINE_MARGIN + 2 * 16)
	// A text longer than the field (17 cells at scale 2): with the caret at
	// its end, its end shows; with the caret at its start, its start.
	long := "abcdefghijklmnopqrstuvwxyz"
	build(&table, &state, &input, long, len(long), 2)
	testing.expect(t, has_text(&table, long[len(long) - 17:]))
	testing.expect_value(t, record_view(caret_of(&table)).x, 32 + TEXT_INPUT_LINE_MARGIN + 17 * 16)
	build(&table, &state, &input, long, 0, 2)
	testing.expect(t, has_text(&table, long[:17]))
	for record in table.records[:table.record_count] {
		view := record_view(record)
		if view.kind == .Element_Pop || view.kind == .Clip_Pop {
			continue
		}
		testing.expect(t, view.x >= 32 && view.x + view.width <= 32 + 320, "no record passes the field")
	}
	// A size that no record holds draws nothing and sets refused: 1, one
	// unit under the smallest size, one past the largest, the largest u16.
	for size in ([4]u16{1, draw_record.TEXT_SIZE_MINIMUM - 1, draw_record.TEXT_SIZE_LIMIT + 1, max(u16)}) {
		draw_table_clear(&table)
		frame := frame_begin(&table, &state, &input)
		text_input_line(&frame, {32, 16, 320, 48}, "plasma", 2, size, "type here")
		testing.expectf(t, table.record_count == 0 && table.refused, "an input line of size %d: %d records, refused %v", size, table.record_count, table.refused)
		frame_end(&frame)
	}
}

// A text of a size that no record holds is refused, in each font, with no
// record and no byte of text, and with refused set: 1, one unit under the
// smallest size, one past the largest, and the largest u16. A grid of such
// a size is refused the same way. Then the edges that are taken: the
// smallest and the largest size, and a caption. This test opens no font
// outlines, so Spleen draws: a character takes its glyph at its scale, 8
// pixels at the caption, where the cell of the size is 7.
@(test)
a_text_of_a_refused_size_is_not_written :: proc(t: ^testing.T) {
	process_drawing_begin()
	memory: Tables
	table := table_of(&memory)
	refused := [4]u16{1, draw_record.TEXT_SIZE_MINIMUM - 1, draw_record.TEXT_SIZE_LIMIT + 1, max(u16)}
	kinds := [2]Font_Kind{.Cells_8x16, .Interface}
	for size in refused {
		for kind in kinds {
			draw_table_clear(&table)
			end := draw_text(&table, 10, 4, "plasma", graphics.colors.text, {kind = kind, size = size})
			testing.expectf(t, end == 10 && table.record_count == 0 && table.text_count == 0 && table.refused, "a text of size %d in %v: written", size, kind)
			draw_table_clear(&table)
			draw_text_right(&table, 200, 4, "plasma", graphics.colors.text, {kind = kind, size = size})
			testing.expectf(t, table.record_count == 0 && table.text_count == 0 && table.refused, "a right text of size %d in %v: written", size, kind)
		}
		cells: [2]Text_Grid_Cell
		draw_table_clear(&table)
		draw_text_grid(&table, 0, 0, {cells = cells[:], columns = 2, rows = 1, stride = 2, size = size})
		testing.expectf(t, table.record_count == 0 && table.text_count == 0 && table.refused, "a grid of size %d: written", size)
	}
	taken := [3]u16{draw_record.TEXT_SIZE_MINIMUM, draw_record.TEXT_SIZE_LIMIT, graphics.TEXT_CAPTION * TEXT_SIZE_UNITS}
	for size in taken {
		draw_table_clear(&table)
		draw_text(&table, 10, 4, "ab", graphics.colors.text, {size = size})
		testing.expectf(t, table.record_count == 1 && !table.refused, "a text of size %d: not written", size)
		view := record_view(table.records[0])
		testing.expectf(t, view.read && view.size == int(size), "a text of size %d: the record holds %d", size, view.size)
		cell := text_rendering.cell_columns(int(size))
		advance := graphics.cell_advance(int(size))
		testing.expectf(t, view.width == 2 * advance && view.height == 2 * cell, "a text of size %d: a box of %d by %d", size, view.width, view.height)
	}
	draw_table_clear(&table)
	draw_text(&table, 10, 4, "ab", graphics.colors.text, {size = graphics.TEXT_CAPTION * TEXT_SIZE_UNITS})
	testing.expect_value(t, record_view(table.records[0]).width, 2 * graphics.CELL_WIDTH)
}

// The act names of a frame: the first element that names one keeps it, a
// name that is empty or too long is counted and kept nowhere, and a frame
// keeps display.ACT_NAME_SET_CAPACITY names at most. The window layer sends
// the set only when it differs from the set that the compositor has.
@(test)
the_act_names_of_a_frame :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	button(&frame, {0, 0, 96, 24}, identity("vector"), "vector")
	element_act_name(&frame, identity("vector"), "settings.set:font")
	button(&frame, {104, 0, 96, 24}, identity("spleen"), "spleen")
	element_act_name(&frame, identity("spleen"), "settings.set:font")
	element_act_name(&frame, identity("spleen"), "")
	element_act_name(&frame, identity("spleen"), "settings.set:a_name_of_33_bytes__")
	#assert(len("settings.set:a_name_of_33_bytes__") == display.ACT_NAME_CAPACITY + 1)
	testing.expect_value(t, frame.act_name_count, 1)
	testing.expect_value(t, frame.act_names[0].element, identity("vector"))
	testing.expect_value(t, frame.act_names_dropped, 2)
	names := [?]string{"strategy", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}
	#assert(len(names) == display.ACT_NAME_SET_CAPACITY)
	for name in names {
		element_act_name(&frame, identity(name), name)
	}
	testing.expect_value(t, frame.act_name_count, display.ACT_NAME_SET_CAPACITY)
	testing.expect_value(t, frame.act_names_dropped, 3)
	testing.expect_value(t, act_name_text(&frame.act_names[1]), "strategy")
	testing.expect_value(t, frame.act_names[1].hash, display.act_name_hash("strategy"))
	// The window layer: a set that the compositor does not have differs;
	// the same set in the same order does not.
	drawing: Window_Drawing
	testing.expect(t, act_names_differ(&drawing, &frame))
	for &name, index in frame.act_names[:frame.act_name_count] {
		drawing.act_names_sent[index] = name.hash
	}
	drawing.act_names_sent_count = frame.act_name_count
	drawing.act_names_sent_once = true
	testing.expect(t, !act_names_differ(&drawing, &frame))
	drawing.act_names_sent[2] = 1
	testing.expect(t, act_names_differ(&drawing, &frame))
	frame_end(&frame)
	testing.expect_value(t, state.act_name_count, display.ACT_NAME_SET_CAPACITY)
	// A frame with no act name leaves the state with none: go to finds no
	// element of a frame that is gone.
	empty := frame_begin(&table, &state, &input)
	frame_end(&empty)
	testing.expect_value(t, state.act_name_count, 0)
}

// Go to: the element of the last frame that named an act name takes the
// focus by its hash, and the next frame shows it. A hash that no element
// named changes nothing.
@(test)
the_focus_by_an_act_name :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	build :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input) -> (round_robin, eevdf: Element_Result) {
		frame := frame_begin(table, state, input)
		round_robin = button(&frame, {0, 0, 96, 24}, identity("round robin"), "round robin")
		eevdf = button(&frame, {104, 0, 96, 24}, identity("eevdf"), "eevdf")
		element_act_name(&frame, identity("eevdf"), "strategy")
		frame_end(&frame)
		return
	}
	state.focus = identity("round robin")
	build(&table, &state, &input)
	name, found := focus_by_act_name(&state, display.act_name_hash("grid fit"))
	testing.expect(t, !found && name == "")
	testing.expect_value(t, state.focus, identity("round robin"))
	name, found = focus_by_act_name(&state, display.act_name_hash("strategy"))
	testing.expect(t, found)
	testing.expect_value(t, name, "strategy")
	testing.expect_value(t, state.focus, identity("eevdf"))
	round_robin, eevdf := build(&table, &state, &input)
	testing.expect(t, eevdf.focused && !round_robin.focused)
}

// A record in a box of whole pixels, and the same record with a byte that
// its kind does not name, which the border refuses.
@(private = "file")
record_in_pixels :: proc(primitive: draw_record.Draw_Primitive, left, top, right, bottom: int) -> Draw_Record {
	return draw_record.record_of(primitive, 0, draw_record.units_of_pixels(left), draw_record.units_of_pixels(top), draw_record.units_of_pixels(right), draw_record.units_of_pixels(bottom))
}

@(private = "file")
refused_copy :: proc(record: Draw_Record) -> Draw_Record {
	refused := record
	refused.reserved[0] = 1
	return refused
}

// A refused record through the difference: it is equal to no record whose
// bytes differ, so both boxes are damaged; the same refused bytes in two
// frames draw nothing in both, and damage nothing.
@(test)
a_refused_record_damages_its_box :: proc(t: ^testing.T) {
	valid := record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF}, 0, 0, 10, 10)
	refused := refused_copy(record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF}, 50, 50, 60, 60))
	_, problem := draw_record.read(refused)
	testing.expect_value(t, problem, draw_record.Problem.Reserved_Not_Zero)
	before_records, now_records := [1]Draw_Record{valid}, [1]Draw_Record{refused}
	before := Draw_Table{records = before_records[:], record_count = 1}
	now := Draw_Table{records = now_records[:], record_count = 1}
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 2)
	testing.expect_value(t, damage.rectangles[0], Rectangle{0, 0, 10, 10})
	testing.expect_value(t, damage.rectangles[1], Rectangle{50, 50, 60, 60})
	// The same refused record in the two frames: no damage.
	before_records[0] = refused
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	// A refused record whose bytes differ from a refused record before:
	// both boxes.
	other := refused
	other.reserved[0] = 2
	before_records[0] = other
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{50, 50, 60, 60})
}

// The difference compares a text with the place of its bytes in the text
// table masked: the same text at another place damages nothing, and a text
// whose bytes, color or count changed damages its box. The interface text
// and the plain text take the same path.
@(test)
a_text_at_another_place_in_the_text_table_damages_nothing :: proc(t: ^testing.T) {
	process_drawing_begin()
	before_memory, now_memory: Tables
	before := table_of(&before_memory)
	now := table_of(&now_memory)
	draw_text(&before, 0, 0, "ab", 0xFFFFFF)
	draw_text(&before, 0, 40, "same", 0xFFFFFF)
	draw_text(&now, 0, 0, "abcdef", 0xFFFFFF)
	draw_text(&now, 0, 40, "same", 0xFFFFFF)
	testing.expect(t, record_view(before.records[1]).first != record_view(now.records[1]).first, "the second text is at another place")
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], damage_bounds_of_two(record_rectangle(before.records[0]), record_rectangle(now.records[0])))
	// The same place and count, other bytes: damaged.
	other_memory: Tables
	other := table_of(&other_memory)
	draw_text(&other, 0, 0, "abcdef", 0xFFFFFF)
	draw_text(&other, 0, 40, "sane", 0xFFFFFF)
	damage = {}
	damage_by_difference(&now, &other, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], record_rectangle(other.records[1]))
	// Another color at another place: damaged.
	colored_memory: Tables
	colored := table_of(&colored_memory)
	draw_text(&colored, 0, 0, "ab", 0xFFFFFF)
	draw_text(&colored, 0, 40, "same", 0x00FF00)
	damage = {}
	damage_by_difference(&now, &colored, &damage)
	testing.expect(t, damage.count >= 1, "a text of another color is damaged")
	found := false
	for index in 0 ..< damage.count {
		found ||= contains(damage.rectangles[index], record_rectangle(colored.records[1]))
	}
	testing.expect(t, found, "the box of the text of another color is in the damage")
}

@(private = "file")
damage_bounds_of_two :: proc(first, second: Rectangle) -> Rectangle {
	return {min(first.left, second.left), min(first.top, second.top), max(first.right, second.right), max(first.bottom, second.bottom)}
}

@(private = "file")
contains :: proc(outer, inner: Rectangle) -> bool {
	return outer.left <= inner.left && outer.top <= inner.top && outer.right >= inner.right && outer.bottom >= inner.bottom
}

// A line whose stroke becomes refused, a stroke color with a width of 0:
// its box is damaged, and it draws nothing.
@(test)
a_refused_line_damages_its_box_and_draws_nothing :: proc(t: ^testing.T) {
	memory: Tables
	before := table_of(&memory)
	draw_line(&before, 2, 2, 20, 2, 1, 0xFFFFFF)
	testing.expect_value(t, before.record_count, 1)
	line := before.records[0]
	fields := transmute(draw_record.Path_Fields)line.fields
	fields.stroke_width = 0
	refused := line
	refused.fields = transmute([draw_record.FIELDS_SIZE]u8)fields
	_, problem := draw_record.read(refused)
	testing.expect_value(t, problem, draw_record.Problem.Field_Past_Bound)
	now_records := [1]Draw_Record{refused}
	now := Draw_Table{records = now_records[:], record_count = 1, text = before.text, text_count = before.text_count}
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], record_rectangle(line))
	testing.expect_value(t, damage.rectangles[0], Rectangle{2, 2, 21, 3})
	pixels: [32 * 8]graphics.Color
	execute(&now, {pixels = raw_data(pixels[:]), width = 32, height = 8, stride = 32})
	testing.expect(t, pixels == [32 * 8]graphics.Color{}, "a refused line draws")
}

// A refused pop still ends its push, and a refused push is an empty clip:
// the records after the pop draw as before the push, and the records under
// the refused push draw nothing. The records still damage.
@(test)
a_refused_clip_keeps_the_cut :: proc(t: ^testing.T) {
	SIDE :: 32
	clip := record_in_pixels(draw_record.Draw_Clip_Push{}, 0, 0, 8, 8)
	refused_pop := refused_copy(record_in_pixels(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0))
	fill := record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF}, 0, 0, SIDE, SIDE)
	under := [3]Draw_Record{clip, fill, refused_pop}
	under_table := Draw_Table{records = under[:], record_count = 3}
	pixels: [SIDE * SIDE]graphics.Color
	execute(&under_table, {pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			testing.expectf(t, (pixels[y * SIDE + x] == 0xFFFFFF) == (x < 8 && y < 8), "the pixel (%d, %d) under a clip", x, y)
		}
	}
	// After the refused pop, the fill covers the whole canvas.
	after := [4]Draw_Record{clip, refused_pop, fill, {}}
	after_table := Draw_Table{records = after[:], record_count = 3}
	pixels = {}
	execute(&after_table, {pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
	testing.expect(t, pixels[(SIDE - 1) * SIDE + SIDE - 1] == 0xFFFFFF, "a refused pop does not end its push")
	// Under a refused push, nothing draws, and after its pop, the fill does.
	refused_push := refused_copy(clip)
	pop := record_in_pixels(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0)
	hidden := [4]Draw_Record{refused_push, fill, pop, record_in_pixels(draw_record.Draw_Rectangle{color = 0xFF00FF00}, 16, 16, 20, 20)}
	hidden_table := Draw_Table{records = hidden[:], record_count = 4}
	pixels = {}
	execute(&hidden_table, {pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			expected := graphics.Color(16 <= x && x < 20 && 16 <= y && y < 20 ? 0x00FF00 : 0)
			testing.expectf(t, pixels[y * SIDE + x] == expected, "the pixel (%d, %d) under a refused push", x, y)
		}
	}
	records := [3]Draw_Record{clip, refused_pop, fill}
	table := Draw_Table{records = records[:], record_count = 3}
	// A refused record alone draws nothing.
	refused_fill := [1]Draw_Record{refused_copy(fill)}
	alone := Draw_Table{records = refused_fill[:], record_count = 1}
	pixels = {}
	execute(&alone, {pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
	testing.expect(t, pixels == [SIDE * SIDE]graphics.Color{}, "a refused rectangle draws")
	// The same clips in two frames and a rectangle that changes: the
	// rectangle is damaged.
	changed := records
	changed[2] = record_in_pixels(draw_record.Draw_Rectangle{color = 0xFF00FF00}, 4, 4, 12, 12)
	now := Draw_Table{records = changed[:], record_count = 3}
	damage: Damage
	damage_by_difference(&table, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{0, 0, SIDE, SIDE})
	// A refused pop whose bytes change is still a pop: the order of the
	// clips is the same, and the rectangle that moves is damaged.
	moved := records
	moved[1].reserved[0] = 2
	moved[2] = record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF}, 20, 20, 24, 24)
	rest := Draw_Table{records = moved[:], record_count = 3}
	damage = {}
	damage_by_difference(&table, &rest, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{0, 0, SIDE, SIDE})
}

// Text_Grid records that grid_of refuses: no column, a first byte that is
// not a multiple of 4, bytes that are not a whole count of rows. And a
// Picture record of a picture memory past the list of the table.
@(test)
grid_of_and_picture_of_refuse_what_the_table_does_not_hold :: proc(t: ^testing.T) {
	process_drawing_begin()
	words: [32]u32
	table := Draw_Table{text = grid_text(words[:]), text_count = len(words) * 4}
	refused := [?]draw_record.Draw_Text_Grid {
		{first = 0, count = 32, columns = 0, size = BODY_TEXT_SIZE},
		{first = 2, count = 32, columns = 2, size = BODY_TEXT_SIZE},
		{first = 0, count = 32 + 16, columns = 2, size = BODY_TEXT_SIZE},
	}
	for fields, index in refused {
		_, ok := grid_of(&table, record_in_pixels(fields, 0, 0, 16, 16))
		testing.expectf(t, !ok, "the grid %d names cells", index)
	}
	// A grid of a size that the border refuses names no cells.
	for size in ([5]u16{0, 1, draw_record.TEXT_SIZE_MINIMUM - 1, draw_record.TEXT_SIZE_LIMIT + 1, max(u16)}) {
		_, read := grid_of(&table, record_in_pixels(draw_record.Draw_Text_Grid{first = 4, count = 32, columns = 2, size = size}, 0, 0, 16, 16))
		testing.expectf(t, !read, "a grid of size %d names cells", size)
	}
	_, ok := grid_of(&table, record_in_pixels(draw_record.Draw_Text_Grid{first = 4, count = 32, columns = 2, size = BODY_TEXT_SIZE}, 0, 0, 16, 16))
	testing.expect(t, ok, "a grid at a multiple of 4 is read")
	memory: [16]graphics.Color
	memories := [][]graphics.Color{memory[:]}
	pictures := Draw_Table{picture_memories = memories}
	for number in ([3]u8{1, 2, max(u8)}) {
		_, found := picture_of(&pictures, record_in_pixels(draw_record.Draw_Picture{memory = number, stride = 4}, 0, 0, 4, 4))
		testing.expectf(t, !found, "a picture of the memory %d, past a list of one", number)
	}
	_, found := picture_of(&pictures, record_in_pixels(draw_record.Draw_Picture{memory = 0, stride = 4}, 0, 0, 4, 4))
	testing.expect(t, found, "a picture of the memory 0 is read")
}

// The grid of points as the kind Point_Grid drew it, in version 11 of the
// record: a point at 12 + 24 k of the surface for each k from 0, cut to
// the area. The reference of the element.
@(private = "file")
point_grid_reference :: proc(canvas: graphics.Canvas, area: Rectangle, color: graphics.Color) {
	view := graphics.view(canvas, area.left, area.top, area.right - area.left, area.bottom - area.top)
	half := graphics.POINT_STEP / 2
	first_x := half + max(0, (area.left - half) / graphics.POINT_STEP - 1) * graphics.POINT_STEP
	first_y := half + max(0, (area.top - half) / graphics.POINT_STEP - 1) * graphics.POINT_STEP
	for point_y := first_y; point_y < area.bottom; point_y += graphics.POINT_STEP {
		for point_x := first_x; point_x < area.right; point_x += graphics.POINT_STEP {
			graphics.fill(view, point_x - area.left, point_y - area.top, graphics.POINT_SIZE, graphics.POINT_SIZE, color)
		}
	}
}

// The folded gap as the kind Folded_Gap drew it, in version 11 of the
// record: the track, then two lines from the given ends, cut to the gap.
@(private = "file")
folded_gap_reference :: proc(canvas: graphics.Canvas, x, y, width, height: int) {
	view := graphics.view(canvas, x, y, width, height)
	graphics.fill(view, 0, 0, width, height, graphics.colors.track)
	graphics.line(view, 2, height - 4, width - 4, 4, 1, graphics.colors.dim)
	graphics.line(view, 6, height - 4, width, 8, 1, graphics.colors.dim)
}

// folded_gap_lines_whole draws the two lines of the folded gap of before on
// the whole canvas, with no cut to the gap: the second line ends one pixel
// right of a narrow gap, so its cut pixels are still near the stroke.
@(private = "file")
folded_gap_lines_whole :: proc(canvas: graphics.Canvas, x, y, width, height: int) {
	graphics.line(canvas, x + 2, y + height - 4, x + width - 4, y + 4, 1, graphics.colors.dim)
	graphics.line(canvas, x + 6, y + height - 4, x + width, y + 8, 1, graphics.colors.dim)
}

// The grid of points is one Rectangle with a pattern, cut to its area, and
// draws the pixels of the kind that it replaced, in areas at each phase of
// the grid: at the corner, inside a step, on a point, across a point, and
// in a part of the surface only.
@(test)
the_grid_of_points_is_a_pattern_with_the_same_pixels :: proc(t: ^testing.T) {
	WIDTH :: 120
	HEIGHT :: 80
	areas := [?]Rectangle{{0, 0, WIDTH, HEIGHT}, {5, 7, 105, 57}, {11, 11, 14, 14}, {13, 13, 50, 40}, {12, 12, 13, 13}, {36, 0, 37, HEIGHT}, {0, 0, 0, 0}}
	for area, index in areas {
		memory: Tables
		table := table_of(&memory)
		draw_point_grid(&table, area.left, area.top, area.right - area.left, area.bottom - area.top)
		testing.expect_value(t, table.record_count, 1)
		view := record_view(table.records[0])
		testing.expect(t, view.read && view.kind == .Rectangle && view.repetition == POINT_GRID_PATTERN && view.color == graphics.colors.point)
		drawn, expected: [WIDTH * HEIGHT]graphics.Color
		canvas := graphics.Canvas{pixels = raw_data(drawn[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
		execute(&table, canvas)
		point_grid_reference({pixels = raw_data(expected[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}, area, graphics.colors.point)
		testing.expectf(t, drawn == expected, "the area %d, %v: the grid of points draws other pixels", index, area)
		// In each damage rectangle, the same pixels: the pattern is placed on
		// the surface, not on the rectangle.
		parts: [WIDTH * HEIGHT]graphics.Color
		part_canvas := graphics.Canvas{pixels = raw_data(parts[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
		rectangles := [?]Rectangle{{0, 0, 30, HEIGHT}, {30, 0, 61, 33}, {30, 33, 61, HEIGHT}, {61, 0, WIDTH, HEIGHT}}
		execute_in_rectangles(&table, part_canvas, rectangles[:])
		testing.expectf(t, parts == expected, "the area %d: the grid in parts differs from the whole grid", index)
	}
}

// The folded gap is a track and one path of its two lines, two records
// with the box of the gap, at each width from 6 pixels. The lines are
// antialiased strokes now: each pixel of the line of before is drawn, each
// drawn pixel is next to a pixel of the line of before, and nothing leaves
// the gap. The gap drawn in four damage rectangles is the gap drawn whole.
@(test)
the_folded_gap_is_two_records_near_the_pixels_of_before :: proc(t: ^testing.T) {
	_ = blend_table()
	WIDTH :: 80
	HEIGHT :: 40
	for width in 6 ..< 64 {
		for height in ([3]int{8, 16, 24}) {
			memory: Tables
			table := table_of(&memory)
			draw_folded_gap(&table, 7, 5, width, height)
			testing.expect_value(t, table.record_count, 2)
			for record in table.records[:table.record_count] {
				testing.expect_value(t, record_rectangle(record), Rectangle{7, 5, 7 + width, 5 + height})
			}
			testing.expect_value(t, record_view(table.records[0]).kind, Draw_Kind.Rectangle)
			testing.expect_value(t, record_view(table.records[1]).kind, Draw_Kind.Path)
			drawn, expected, parts, lines_whole: [WIDTH * HEIGHT]graphics.Color
			execute(&table, {pixels = raw_data(drawn[:]), width = WIDTH, height = HEIGHT, stride = WIDTH})
			folded_gap_reference({pixels = raw_data(expected[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}, 7, 5, width, height)
			folded_gap_lines_whole({pixels = raw_data(lines_whole[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}, 7, 5, width, height)
			rectangles := [4]Rectangle{{0, 0, 19, HEIGHT}, {19, 0, 30, 11}, {19, 11, 30, HEIGHT}, {30, 0, WIDTH, HEIGHT}}
			execute_in_rectangles(&table, {pixels = raw_data(parts[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}, rectangles[:])
			if parts != drawn {
				testing.expectf(t, false, "a folded gap of %d by %d in parts differs from the gap drawn whole", width, height)
				return
			}
			for y in 0 ..< HEIGHT {
				for x in 0 ..< WIDTH {
					inside := x >= 7 && x < 7 + width && y >= 5 && y < 5 + height
					pixel := drawn[y * WIDTH + x]
					if !inside {
						testing.expectf(t, pixel == 0, "a gap of %d by %d draws at (%d, %d), outside it", width, height, x, y)
						continue
					}
					before := expected[y * WIDTH + x]
					if before != graphics.colors.track && pixel == graphics.colors.track {
						testing.expectf(t, false, "a gap of %d by %d: the pixel (%d, %d) of the line of before is not drawn", width, height, x, y)
						return
					}
					if pixel != graphics.colors.track && !near_line_of_before(lines_whole[:], WIDTH, HEIGHT, x, y) {
						testing.expectf(t, false, "a gap of %d by %d: the pixel (%d, %d) is far from the line of before", width, height, x, y)
						return
					}
				}
			}
		}
	}
	// No size: no record.
	memory: Tables
	table := table_of(&memory)
	draw_folded_gap(&table, 7, 5, 0, 16)
	draw_folded_gap(&table, 7, 5, 16, -1)
	testing.expect_value(t, table.record_count, 0)
}

// near_line_of_before says if a pixel or one of its eight neighbours is a
// pixel of the lines of the folded gap of before: not the track.
@(private = "file")
near_line_of_before :: proc(expected: []graphics.Color, width, height, x, y: int) -> bool {
	for near_y in max(y - 1, 0) ..= min(y + 1, height - 1) {
		for near_x in max(x - 1, 0) ..= min(x + 1, width - 1) {
			pixel := expected[near_y * width + near_x]
			if pixel != graphics.colors.track && pixel != 0 {
				return true
			}
		}
	}
	return false
}

// One case of a pattern: its pattern in pixels, the area of its record in
// pixels of the surface, and the place of the point (0, 0) of the surface in
// the canvas, so an area can lie at negative places.
@(private = "file")
Pattern_Case :: struct {
	name:                                   string,
	cell_x, cell_y:                         i32, // In 1/64 pixel: a place can be at the limit.
	cell_width, cell_height, step_x, step_y: int, // In pixels.
	area:                                   Rectangle,
	origin_x, origin_y:                     int,
}

@(private = "file")
pattern_of_case :: proc(item: Pattern_Case) -> draw_record.Repetition {
	units :: draw_record.UNITS_PER_PIXEL
	return {cell_x = item.cell_x, cell_y = item.cell_y, cell_width = u16(item.cell_width * units), cell_height = u16(item.cell_height * units), step_x = u16(item.step_x * units), step_y = u16(item.step_y * units)}
}

// same_pixels says if two canvases of one size hold the same pixels.
@(private = "file")
same_pixels :: proc(first, second: []graphics.Color) -> bool {
	if len(first) != len(second) {
		return false
	}
	for pixel, index in first {
		if pixel != second[index] {
			return false
		}
	}
	return true
}

// The plain loop over each pixel of the area: a pixel is in the pattern
// when its place past the place of a cell, modulo the step, is inside the
// cell, on each axis. No span, no division of the execution.
@(private = "file")
pattern_reference :: proc(pixels: []graphics.Color, canvas_width: int, item: Pattern_Case, color: graphics.Color) {
	modulo :: proc(value, divisor: int) -> int {
		return ((value % divisor) + divisor) % divisor
	}
	cell_x, cell_y := draw_record.pixels_floor(item.cell_x), draw_record.pixels_floor(item.cell_y)
	for y in item.area.top ..< item.area.bottom {
		for x in item.area.left ..< item.area.right {
			if modulo(x - cell_x, item.step_x) < item.cell_width && modulo(y - cell_y, item.step_y) < item.cell_height {
				pixels[(y + item.origin_y) * canvas_width + x + item.origin_x] = color
			}
		}
	}
}

// The pattern drawn whole, and in damage rectangles that cut the area into
// four parts, equals the plain loop over the pixels, at the bounds of a
// pattern: a dense pattern, a cell of 1 pixel each 2 pixels, the largest
// step, a place at each limit, an area at negative places, an area whose
// first cell ends on its left edge, cells that touch across or down only,
// and a cell that crosses the damage rectangles.
@(test)
a_pattern_at_its_bounds_draws_the_pixels_of_the_plain_loop :: proc(t: ^testing.T) {
	pixel :: draw_record.UNITS_PER_PIXEL
	limit :: draw_record.COORDINATE_UNIT_LIMIT
	cases := [?]Pattern_Case {
		{"a dense pattern: cell and step of 1", 0, 0, 1, 1, 1, 1, {0, 0, 40, 30}, 0, 0},
		{"a cell of 1 each 2 pixels", pixel, 0, 1, 1, 2, 2, {0, 0, 40, 30}, 0, 0},
		{"the largest step", 5 * pixel, 2 * pixel, 3, 2, 1023, 1023, {0, 0, 1100, 6}, 0, 0},
		{"the place at the largest limit", limit, limit, 2, 3, 24, 24, {0, 0, 60, 50}, 0, 0},
		{"the place at the smallest limit", -limit, -limit, 2, 3, 24, 24, {0, 0, 60, 50}, 0, 0},
		{"an area at negative places", 3 * pixel, -5 * pixel, 4, 3, 9, 7, {-40, -30, 20, 25}, 40, 30},
		{"the first cell ends on the left edge", 13 * pixel, 13 * pixel, 3, 3, 10, 10, {6, 6, 50, 50}, 0, 0},
		{"cells that touch across", 0, pixel, 3, 2, 3, 5, {0, 0, 40, 30}, 0, 0},
		{"cells that touch down", pixel, 0, 2, 4, 5, 4, {0, 0, 40, 30}, 0, 0},
		{"a cell across the damage rectangles", 2 * pixel, 2 * pixel, 5, 5, 9, 7, {0, 0, 40, 30}, 0, 0},
	}
	COLOR :: graphics.Color(0x00C0FFEE)
	for item in cases {
		canvas_width := item.area.right + item.origin_x
		canvas_height := item.area.bottom + item.origin_y
		drawn := make([]graphics.Color, canvas_width * canvas_height)
		parts := make([]graphics.Color, canvas_width * canvas_height)
		expected := make([]graphics.Color, canvas_width * canvas_height)
		defer delete(drawn)
		defer delete(parts)
		defer delete(expected)
		records := [1]Draw_Record{record_in_pixels(draw_record.Draw_Rectangle{color = draw_record.opaque(COLOR), repetition = pattern_of_case(item)}, item.area.left, item.area.top, item.area.right, item.area.bottom)}
		_, problem := draw_record.read(records[0])
		testing.expectf(t, problem == .None, "%s: the border refuses the pattern: %v", item.name, problem)
		table := Draw_Table{records = records[:], record_count = 1}
		canvas := graphics.Canvas{pixels = raw_data(drawn), width = canvas_width, height = canvas_height, stride = canvas_width}
		execute(&table, canvas, item.origin_x, item.origin_y)
		pattern_reference(expected, canvas_width, item, COLOR)
		testing.expectf(t, same_pixels(drawn, expected), "%s: the pattern draws other pixels than the plain loop", item.name)
		// The area in four damage rectangles, whose edges cross cells.
		middle_x := item.area.left + (item.area.right - item.area.left) / 2 + 1
		middle_y := item.area.top + (item.area.bottom - item.area.top) / 2 + 1
		rectangles := [4]Rectangle {
			{item.area.left, item.area.top, middle_x, middle_y},
			{middle_x, item.area.top, item.area.right, middle_y},
			{item.area.left, middle_y, middle_x, item.area.bottom},
			{middle_x, middle_y, item.area.right, item.area.bottom},
		}
		part_canvas := graphics.Canvas{pixels = raw_data(parts), width = canvas_width, height = canvas_height, stride = canvas_width}
		execute_in_rectangles(&table, part_canvas, rectangles[:], item.origin_x, item.origin_y)
		testing.expectf(t, same_pixels(parts, expected), "%s: the pattern in damage rectangles differs from the plain loop", item.name)
	}
}

// A pattern that the border refuses (one step at 0 and the other not)
// draws nothing, and the difference damages its box.
@(test)
a_refused_pattern_draws_nothing_and_damages_its_box :: proc(t: ^testing.T) {
	pixel :: draw_record.UNITS_PER_PIXEL
	good := draw_record.Repetition{cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 8 * pixel, step_y = 8 * pixel}
	refused := good
	refused.step_y = 0
	before_records := [1]Draw_Record{record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF, repetition = good}, 4, 4, 36, 28)}
	now_records := [1]Draw_Record{record_in_pixels(draw_record.Draw_Rectangle{color = 0xFFFFFFFF, repetition = refused}, 4, 4, 36, 28)}
	_, problem := draw_record.read(now_records[0])
	testing.expect_value(t, problem, draw_record.Problem.Field_Past_Bound)
	before := Draw_Table{records = before_records[:], record_count = 1}
	now := Draw_Table{records = now_records[:], record_count = 1}
	pixels: [40 * 32]graphics.Color
	execute(&now, {pixels = raw_data(pixels[:]), width = 40, height = 32, stride = 40})
	testing.expect(t, pixels == [40 * 32]graphics.Color{}, "a refused pattern draws")
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{4, 4, 36, 28})
}
