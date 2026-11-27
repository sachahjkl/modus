package interface

import "modus:contract/accessibility"
import "modus:contract/text_encoding"
import "modus:display"
import "modus:graphics"
import "modus:kind_icons"

// The elements of the rules (docs/DESIGN.md, section 10). Each one appends
// draw records to the table of the frame; an element that takes input
// gives an Element_Result.
//
// The two fonts (docs/DESIGN.md, section 5; docs/FONTS.md, section 12.6):
// a text that names or explains (a title, a caption, a label, the name of a
// button, a line of a list, the title of a column) is in the interface
// font; a value (a number, a hash, a text that the input types, the count of
// a card, the cells of a table) is in the font of the cells, so values
// align by character. Each element measures a text in the font that draws
// it, and cuts it to its box: no text passes its element in either font.

// background draws the background of the rules on an area: one color and
// the grid of points.
// One run of matched characters of a name: its bytes, from the first byte
// of its first character to the end of its last one. A run with no byte
// ends the list.
Match_Run :: struct {
	start, end: int,
}
MATCH_RUN_CAPACITY :: 64 // The runs of 128 places at most: a matched place and a place that is not, in turn.

// matched_runs gives the runs of the matched characters of a name: bit n of
// places is the character that starts at the byte n. A run counts
// characters, not bytes: a matched é of two bytes is under both, and two
// matched characters side by side are one run whatever their bytes. A bit
// inside a character, or past the 128 bytes that places names, is no
// match.
matched_runs :: proc "contextless" (name: string, places: u128) -> (runs: [MATCH_RUN_CAPACITY]Match_Run) {
	count := 0
	in_run := false
	for place := 0; place < len(name) && place < 128; {
		_, length, _ := text_encoding.character_decode(transmute([]u8)name, place)
		if length == 0 {
			break
		}
		switch {
		case places & (u128(1) << uint(place)) == 0:
			in_run = false
		case in_run:
			runs[count - 1].end = place + length
		case count < MATCH_RUN_CAPACITY:
			runs[count] = {place, place + length}
			count += 1
			in_run = true
		}
		place += length
	}
	return
}

background :: proc "contextless" (frame: ^Frame, area: Area) {
	draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.colors.background)
	draw_point_grid(frame.table, area.x, area.y, area.width, area.height)
}

// card draws the frame of one subject (docs/DESIGN.md, section 3): a border
// of 1 pixel in its accent, the surface of a card, a bar of 4 x 16 pixels
// and the title in the accent, the caption of its record at the caption
// size in the dim color, on the baseline of the title, and a count at the
// right. It gives the area of its content.
card :: proc "contextless" (frame: ^Frame, area: Area, title, caption: string, accent: graphics.Color, count := "") -> Area {
	table := frame.table
	card_id := title != "" ? identity_in(identity("card"), title) : identity("card")
	draw_element_push(table, area, u32(card_id), .Group, {name = title, description = caption})
	defer draw_element_pop(table)
	border_top, border_bottom := graphics.card_border_colors(accent, graphics.appearance)
	draw_vertical_gradient(table, area.x, area.y, area.width, area.height, border_top, border_bottom, u32(card_id))
	draw_vertical_gradient(table, area.x + 1, area.y + 1, area.width - 2, area.height - 2, graphics.colors.card_top, graphics.colors.card_bottom, u32(card_id))
	title_top := area.y + 12
	draw_vertical_gradient(table, area.x + graphics.MARGIN, title_top, 4, 16, graphics.shade(accent, 130), accent, u32(card_id))
	// The title, then the caption, take the room before the count: a
	// narrow card cuts them, so they never run past the border.
	title_left := area.x + graphics.MARGIN + 12
	right := area.x + area.width - graphics.MARGIN
	if count != "" {
		right -= text_measured_width(table, {}, count) + 2 * graphics.GAP
	}
	shown_title := text_fit(table, FONT_INTERFACE_BOLD, title, right - title_left)
	heading_id := identity_in(card_id, "heading")
	draw_element_push(table, {title_left, title_top, max(right - title_left, 0), LINE}, u32(heading_id), .Heading, {level = 2, name = shown_title != title ? title : ""})
	after := draw_text(table, title_left, title_top, shown_title, accent, FONT_INTERFACE_BOLD, u32(heading_id))
	draw_element_pop(table)
	if count != "" {
		draw_text_right(table, area.x + area.width - graphics.MARGIN, title_top, count, graphics.colors.text, {}, u32(card_id))
	}
	caption_left := after + 2 * graphics.GAP
	caption_top := text_top_on_baseline(table, FONT_INTERFACE_BOLD, title_top, FONT_CAPTION)
	draw_text(table, caption_left, caption_top, text_fit(table, FONT_CAPTION, caption, right - caption_left), graphics.colors.dim, FONT_CAPTION, u32(card_id))
	return {area.x + graphics.MARGIN, area.y + graphics.TITLE, area.width - 2 * graphics.MARGIN, area.height - graphics.TITLE - graphics.GAP}
}

// label_value_line draws a name in the dim color and its value: at
// value_x from the left of the area, or at the right of the area (a number,
// docs/DESIGN.md section 5) when value_x is 0. With no value_color the
// value is in the text color of the appearance in force.
label_value_line :: proc "contextless" (frame: ^Frame, area: Area, label, value: string, value_color: Maybe(graphics.Color) = nil, value_x := 0) {
	shown_color := value_color.? or_else graphics.colors.text
	table := frame.table
	y := area.y + (area.height - LINE) / 2
	// The value, in the font of the cells, takes its room first; the label
	// takes what is left, with a gap of 8 pixels.
	value_room := value_x == 0 ? area.width : area.width - value_x
	shown_value := text_fit(table, {}, value, value_room)
	label_room := value_x == 0 ? area.width - text_measured_width(table, {}, shown_value) - 8 : value_x - 8
	draw_text(table, area.x, y, text_fit(table, FONT_INTERFACE, label, label_room), graphics.colors.dim, FONT_INTERFACE)
	if value_x == 0 {
		draw_text_right(table, area.x + area.width, y, shown_value, shown_color)
	} else {
		draw_text(table, area.x + value_x, y, shown_value, shown_color)
	}
}

// label_value_lines draws a name in the dim color and its value at value_x
// from the left of a column, each on the lines that it needs: the name in
// the box before value_x, the value in the box after it
// (draw_text_wrapped). It takes from the column the height of the longer of
// the two, and gives the count of its lines: a row of one line has the
// height `line`, as a row of label_value_line, and each more line adds the
// height of a line of text. label_value_line cuts a text to one line; this
// element is for a value that the reader has at no other place: a
// sentence, a path, a text of a measure. A row that is past the bottom of
// the column is not drawn: the caller gives the column the height of its
// rows, or counts the rows that it does not show.
label_value_lines :: proc "contextless" (frame: ^Frame, column: ^Column, label, value: string, value_x: int, value_color: Maybe(graphics.Color) = nil, line: int = LINE) -> (count: int, drawn: bool) {
	return two_texts_lines(frame, column, label, FONT_INTERFACE, graphics.colors.dim, value, value_color.? or_else graphics.colors.text, value_x, line, -1)
}

// case_lines draws one case of a table of cases: what a process asked, and
// at answer_x the answer that it got, both in the font of the cells and
// each on the lines that it needs, over a band on every second case (the
// band is 8 pixels wider than the column on each side). It takes its
// height from the column, as label_value_lines does. `drawn` is false for a
// case that is past the bottom of the column: nothing of it is drawn, and
// the caller counts it in the line that says how many cases the window
// does not show.
case_lines :: proc "contextless" (frame: ^Frame, column: ^Column, index: int, text, answer: string, answer_x: int, text_color, answer_color: graphics.Color, line: int = TABLE_LINE) -> (count: int, drawn: bool) {
	return two_texts_lines(frame, column, text, {}, text_color, answer, answer_color, answer_x, line, index)
}

// two_texts_lines is the row of label_value_lines and of case_lines: a
// first text in the box before second_x, a second text in the box from
// second_x to the right of the column, a row as high as the longer of the
// two. band_index: the place of the row in its table, for the band; -1: no
// band.
@(private)
two_texts_lines :: proc "contextless" (frame: ^Frame, column: ^Column, first: string, first_font: Font, first_color: graphics.Color, second: string, second_color: graphics.Color, second_x: int, line: int, band_index: int) -> (count: int, drawn: bool) {
	table := frame.table
	first_room := second_x - 8
	second_room := column.area.width - second_x
	count = max(text_wrapped_line_count(table, first_font, first, first_room), text_wrapped_line_count(table, {}, second, second_room), 1)
	height := line + (count - 1) * line_height({})
	area := column_take(column, height)
	if area.height < height {
		return count, false
	}
	if band_index >= 0 {
		row_id := identity_with(identity("case_row"), band_index)
		draw_element_push(table, area, u32(row_id), .Row, {row_index = u32(band_index + 1)})
		defer draw_element_pop(table)
		table_band(frame, {area.x - 8, area.y, area.width + 16, area.height}, band_index)
		y := area.y + (line - line_height({})) / 2
		first_cell_id := identity_in(row_id, "cell_1")
		draw_element_push(table, {area.x, area.y, max(first_room, 0), area.height}, u32(first_cell_id), .Cell, {column_index = 1})
		draw_text_wrapped(table, area.x, y, first_room, first, first_color, first_font)
		draw_element_pop(table)
		second_cell_id := identity_in(row_id, "cell_2")
		draw_element_push(table, {area.x + second_x, area.y, max(second_room, 0), area.height}, u32(second_cell_id), .Cell, {column_index = 2})
		draw_text_wrapped(table, area.x + second_x, y, second_room, second, second_color)
		draw_element_pop(table)
		return count, true
	}
	y := area.y + (line - line_height({})) / 2
	draw_text_wrapped(table, area.x, y, first_room, first, first_color, first_font)
	draw_text_wrapped(table, area.x + second_x, y, second_room, second, second_color)
	return count, true
}

// cases_rest_line draws, in an area of one line, the count of the cases
// that a table of cases did not show, and where the reader finds each of
// them. With a count of 0 it draws nothing.
cases_rest_line :: proc "contextless" (frame: ^Frame, area: Area, not_shown: int, where_they_are: string) {
	if not_shown <= 0 {
		return
	}
	builder: Text_Builder
	text_put(&builder, "and ")
	text_put_number(&builder, u64(not_shown))
	text_put(&builder, " cases more: ")
	text_put(&builder, where_they_are)
	draw_text_wrapped(frame.table, area.x, area.y + (area.height - line_height({})) / 2, area.width, text_of(&builder), graphics.colors.dim)
}

// table_band draws the band under a line of a table: every second line,
// from the first, has the surface of a card (docs/DESIGN.md, section 3).
table_band :: proc "contextless" (frame: ^Frame, area: Area, index: int) {
	if index % 2 == 0 {
		draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.colors.card_top)
	}
}

// Where a text sits in the width of a cell.
Alignment :: enum u8 {
	Left, // Names and texts.
	Right, // Numbers, with their unit.
}

// cell_text draws a text in a cell of a line, in the middle of its height,
// cut to the width of the cell. Its font is the font of the cells unless
// the caller names another: a cell of a table holds a value.
cell_text :: proc "contextless" (frame: ^Frame, cell: Area, text: string, color: graphics.Color, alignment: Alignment = .Left, font: Font = {}) {
	y := cell.y + (cell.height - line_height(font)) / 2
	shown := text_fit(frame.table, font, text, cell.width)
	if alignment == .Right {
		draw_text_right(frame.table, cell.x + cell.width, y, shown, color, font)
	} else {
		draw_text(frame.table, cell.x, y, shown, color, font)
	}
}

// table_header draws the titles of the columns of a table, in the dim color
// and the interface font: a title names its column.
table_header :: proc "contextless" (frame: ^Frame, cells: []Area, titles: []string, alignments: []Alignment = nil) {
	for title, index in titles[:min(len(titles), len(cells))] {
		cell_text(frame, cells[index], title, graphics.colors.dim, index < len(alignments) ? alignments[index] : .Left, FONT_INTERFACE)
	}
}

// bar draws a value against a maximum: the track, and the full part from
// 125 % of its color at the top to 78 % at the bottom (docs/DESIGN.md,
// section 3). A value above 0 has a full part of 2 pixels at least, and
// the full part never passes the track.
bar :: proc "contextless" (frame: ^Frame, area: Area, value, maximum: u64, color: graphics.Color) {
	draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.colors.track)
	// The product of a value and a width must not wrap: a value and its
	// maximum lose their low bits together until the maximum fits in 32
	// bits, and a width is under 2^20 pixels.
	shown, most := min(value, max(maximum, 1)), max(maximum, 1)
	for most >= 1 << 32 {
		shown, most = shown >> 1, most >> 1
	}
	full_width := int(shown * u64(clamp(area.width, 0, 1 << 20)) / most)
	if value > 0 {
		full_width = min(max(full_width, 2), area.width)
	}
	draw_vertical_gradient(frame.table, area.x, area.y, full_width, area.height, graphics.shade(color, 125), graphics.shade(color, 78))
}

BAR_WITH_VALUE_THICKNESS :: 10 // The height of the bar of bar_with_value, in the middle of its line.
BAR_WITH_VALUE_GAP :: 8 // From the end of the bar of bar_with_value to its value.

// bar_with_value draws a bar and its value on one line of a table: the bar
// takes bar_width pixels at the left of the area, BAR_WITH_VALUE_THICKNESS
// high in the middle of the line, and the value, in the font of the cells,
// takes the rest of the area after a gap. The value is cut to its room, so
// it never passes the area: the caller gives the area the width of the
// largest value that it shows. A bar wider than the area is cut to it.
bar_with_value :: proc "contextless" (frame: ^Frame, area: Area, bar_width: int, value, maximum: u64, color: graphics.Color) {
	builder: Text_Builder
	value_str := number_text(&builder, value)
	meter_id := identity_with(identity("meter"), area.y * 4096 + area.x)
	draw_element_push(frame.table, area, u32(meter_id), .Meter, {
		has_value_now     = true,
		value_now         = i64(min(value, u64(max(i64)))),
		has_value_minimum = true,
		value_minimum     = 0,
		has_value_maximum = true,
		value_maximum     = i64(min(maximum, u64(max(i64)))),
		value_text        = value_str,
	})
	defer draw_element_pop(frame.table)
	shown_width := clamp(bar_width, 0, max(area.width, 0))
	bar(frame, {area.x, area.y + (area.height - BAR_WITH_VALUE_THICKNESS) / 2, shown_width, BAR_WITH_VALUE_THICKNESS}, value, maximum, color)
	value_x := area.x + shown_width + BAR_WITH_VALUE_GAP
	cell_text(frame, {value_x, area.y, area.x + area.width - value_x, area.height}, value_str, graphics.colors.text)
}

// bar_parts draws parts of one total side by side on a track, each in its
// color: the width of a part is its count.
bar_parts :: proc "contextless" (frame: ^Frame, area: Area, counts: []u64, colors: []graphics.Color, total: u64) {
	draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.colors.track)
	x := area.x
	for count, index in counts[:min(len(counts), len(colors))] {
		width := int(count * u64(area.width) / max(total, 1))
		draw_vertical_gradient(frame.table, x, area.y, width, area.height, graphics.shade(colors[index], 125), graphics.shade(colors[index], 78))
		x += width
	}
}

// mark draws a square: a point or a mark of the rules.
mark :: proc "contextless" (frame: ^Frame, x, y, size: int, color: graphics.Color) {
	draw_rectangle(frame.table, x, y, size, size, color)
}

// large_number draws the one number of a card at the large text size
// (graphics.TEXT_LARGE), and gives the x after it. Its line is
// line_height(FONT_LARGE) high: a label under it starts there
// (draw_caption).
large_number :: proc "contextless" (frame: ^Frame, x, y: int, text: string, color: graphics.Color) -> int {
	return draw_text(frame.table, x, y, text, color, FONT_LARGE)
}

// draw_caption draws a caption (docs/DESIGN.md, "5. Text"): a label under
// a value, or the help line under an element, at the caption size in the
// dim color, in a box of `room` pixels whose top left corner is (x, y), on
// the lines that it needs (draw_text_wrapped). It gives the height that it
// took, which caption_height gives before the draw.
draw_caption :: proc "contextless" (frame: ^Frame, x, y, room: int, text: string) -> int {
	return draw_text_wrapped(frame.table, x, y, room, text, graphics.colors.dim, FONT_CAPTION) * line_height(FONT_CAPTION)
}

// caption_height gives the height of a caption in a box of `room` pixels:
// its lines times the line of the caption size.
caption_height :: proc "contextless" (table: ^Draw_Table, text: string, room: int) -> int {
	return text_wrapped_line_count(table, FONT_CAPTION, text, room) * line_height(FONT_CAPTION)
}

// draw_heading draws the title of a page at the heading size (docs/DESIGN.md,
// "5. Text"), in a box of `room` pixels whose top left corner is (x, y), on
// the lines that it needs: a title is never cut. It gives the height that
// it took, which heading_height gives before the draw.
draw_heading :: proc "contextless" (frame: ^Frame, x, y, room: int, text: string, color: graphics.Color) -> int {
	lines := text_wrapped_line_count(frame.table, FONT_HEADING, text, room)
	height := lines * line_height(FONT_HEADING)
	heading_id := text != "" ? identity_in(identity("heading"), text) : identity("heading")
	draw_element_push(frame.table, {x, y, max(room, 0), height}, u32(heading_id), .Heading, {level = 1})
	drawn := draw_text_wrapped(frame.table, x, y, room, text, color, FONT_HEADING) * line_height(FONT_HEADING)
	draw_element_pop(frame.table)
	return drawn
}

// heading_height gives the height of a heading in a box of `room` pixels:
// its lines times the line of the heading size.
heading_height :: proc "contextless" (table: ^Draw_Table, text: string, room: int) -> int {
	return text_wrapped_line_count(table, FONT_HEADING, text, room) * line_height(FONT_HEADING)
}

// The width of the outline of the element with the focus, in logical
// pixels (src/md/features/accessibility.md, "3. Keyboard access to
// everything"): 2 pixels, the least perimeter that WCAG 2.2, success
// criterion 2.4.13, asks.
FOCUS_RING_WIDTH :: 2

// focus_ring_area gives the box of the outline of the focus of an element:
// its area grown by FOCUS_RING_WIDTH on each side. The outline lies outside
// the area, so no fill of the element covers it. An area of a negative
// size counts as empty.
focus_ring_area :: proc "contextless" (area: Area) -> Area {
	return {area.x - FOCUS_RING_WIDTH, area.y - FOCUS_RING_WIDTH, max(area.width, 0) + 2 * FOCUS_RING_WIDTH, max(area.height, 0) + 2 * FOCUS_RING_WIDTH}
}

// draw_focus_ring draws the outline of the focus around an area, in the
// strong text: the one color that keeps 3 to 1 against each surface of
// each appearance (graphics, appearance_test.odin). The element draws it
// after its own records, so its fill never covers it; a layout keeps a gap
// of FOCUS_RING_WIDTH at least between two elements that take the focus,
// so no neighbour covers it either.
draw_focus_ring :: proc "contextless" (table: ^Draw_Table, area: Area, element: u32 = 0) {
	ring := focus_ring_area(area)
	draw_outline(table, ring.x, ring.y, ring.width, ring.height, FOCUS_RING_WIDTH, graphics.colors.text_strong, element)
}

// button draws a secondary button with machined surface depth, hover, pressed,
// selected/open, and focus ring feedback (rich_widgets.odin). Enter or Space
// with the focus, or a press and a release of the pointer on it, activate it.
// Its label is its element name (element_name).
button :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, label: string, open := false, toggle: accessibility.Toggle_State = .None) -> Element_Result {
	return button_styled(frame, area, element, label, .Secondary, open = open, toggle = toggle)
}

// The lines of a list whose names are measured in one call; the lines past
// it are measured one by one.
LIST_MEASURE_CAPACITY :: 64

// List_Options: what a list with a choice shows beside its names.
List_Options :: struct {
	marked:      string, // A line of 2 pixels is under this part of each name (a search).
	chosen_hint: string, // A text at the right of the chosen line ("enter: start").
	empty_text:  string, // The text of a list with no line.
	name:        string, // Accessible name of the listbox; defaults to "list" when empty.
}

// list_with_choice draws the lines of a list, the chosen line in blue, and
// a scroll bar at the right when the lines do not fit. With the focus, up
// and down move the choice; Enter, or a press on a line, activates it. The
// scroll bar, and the wheel over the list, move the choice, which the view
// follows. It gives changed when the choice changed. Its records are cut to
// its area by a clip, and by each clip open around it: an area shorter than
// one line shows the part of the line that it holds.
list_with_choice :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, names: []string, choice: ^int, options: List_Options = {}) -> Element_Result {
	result := element_interact(frame, element, area, .List)
	list_states := accessibility.Element_States{.Focusable}
	if result.focused {
		list_states += {.Focused}
	}
	draw_element_push(frame.table, area, u32(element), .List_Box, {
		states  = list_states,
		actions = {.Focus, .Press, .Increment, .Decrement},
		name    = options.name != "" ? options.name : "list",
	})
	defer draw_element_pop(frame.table)
	// The outline of the focus lies outside the area: it is drawn after the
	// clip of the lines closes, so the clip does not cut it.
	defer if result.focused {
		draw_focus_ring(frame.table, area, u32(element))
	}
	draw_clip_push(frame.table, area.x, area.y, area.width, area.height)
	defer draw_clip_pop(frame.table)
	rows := max(area.height / TABLE_LINE, 1)
	before := choice^
	if len(names) > 0 {
		choice^ = clamp(choice^, 0, len(names) - 1)
	}
	if result.focused {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken || len(names) == 0 {
				continue
			}
			switch key.code {
			case display.KEY_UP:
				choice^ = (choice^ + len(names) - 1) % len(names)
				key.taken = true
			case display.KEY_DOWN:
				choice^ = (choice^ + 1) % len(names)
				key.taken = true
			}
		}
	}
	first := max(choice^ - rows + 1, 0)
	// A press on a line chooses it.
	input := frame.input
	scroll_width := len(names) > rows ? SCROLL_BAR_THICKNESS : 0
	if scroll_width != 0 {
		// The view of this list follows its choice, so the scroll bar
		// moves the choice: to the last line of the view that it asks for.
		bar_area := Area{area.x + area.width - scroll_width, area.y, scroll_width, rows * TABLE_LINE}
		// The wheel over the lines moves the view too: the whole list is
		// the view of the bar.
		moved := scroll_bar(frame, bar_area, identity_in(element, "scroll bar"), .Vertical, {total = len(names), visible = rows, first = first}, {}, "", area, u32(element))
		if moved.changed {
			choice^ = min(moved.first + rows - 1, len(names) - 1)
			first = max(choice^ - rows + 1, 0)
		}
	}
	if result.under_pointer && input.pressed {
		// A press on a line that the list shows chooses it; a press under
		// the last line or on the bar at the right chooses nothing.
		row := (input.pointer_y - area.y) / TABLE_LINE
		line := first + row
		if row < rows && line < len(names) && input.pointer_x < area.x + area.width - scroll_width {
			choice^ = line
		}
		first = max(choice^ - rows + 1, 0)
	}
	result.changed = choice^ != before
	table := frame.table
	if len(names) == 0 && options.empty_text != "" {
		draw_text(table, area.x + 8, area.y + 4, text_fit(table, FONT_INTERFACE, options.empty_text, area.width - 16), graphics.colors.dim, FONT_INTERFACE)
	}
	// The names of the lines that the list shows, measured in one call.
	shown_count := max(min(len(names) - first, rows), 0)
	widths: [LIST_MEASURE_CAPACITY]int
	measured_count := min(shown_count, LIST_MEASURE_CAPACITY)
	if measured_count > 0 {
		texts_measure(table, FONT_INTERFACE, names[first:][:measured_count], widths[:measured_count])
	}
	line_width := area.width - scroll_width
	hint_width := options.chosen_hint != "" ? text_measured_width(table, FONT_INTERFACE, options.chosen_hint) : 0
	for row in 0 ..< shown_count {
		index := first + row
		y := area.y + row * TABLE_LINE
		chosen := index == choice^
		name_room := line_width - 16
		if chosen && options.chosen_hint != "" && hint_width <= line_width - 16 {
			name_room -= hint_width + 8
		}
		full_name := names[index]
		name := full_name
		if row >= measured_count || widths[row] > name_room {
			name = text_fit(table, FONT_INTERFACE, name, name_room)
		}
		option_id := identity_with(element, index)
		option_states := chosen ? accessibility.Element_States{.Selected} : accessibility.Element_States{}
		draw_element_push(table, {area.x, y, line_width, TABLE_LINE}, u32(option_id), .Option, {
			states          = option_states,
			actions         = {.Select},
			name            = name != full_name ? full_name : "",
			position_in_set = u32(index + 1),
			set_size        = u32(len(names)),
		})
		if chosen {
			draw_rectangle(table, area.x, y, line_width, TABLE_LINE, graphics.colors.chosen, u32(option_id))
			if options.chosen_hint != "" && hint_width <= line_width - 16 {
				draw_text_right(table, area.x + line_width - 8, y + 4, options.chosen_hint, graphics.COLOR_WHITE, FONT_INTERFACE, u32(option_id))
			}
		}
		draw_text(table, area.x + 8, y + 4, name, chosen ? graphics.COLOR_WHITE : graphics.colors.text, FONT_INTERFACE, u32(option_id))
		// The marked part, measured in the font of the name.
		if at := find_without_case(name, options.marked); len(options.marked) > 0 && at >= 0 {
			start := text_measured_width(table, FONT_INTERFACE, name[:at])
			end := text_measured_width(table, FONT_INTERFACE, name[:at + len(options.marked)])
			draw_rectangle(table, area.x + 8 + start, y + 20, end - start, 2, chosen ? graphics.COLOR_WHITE : graphics.colors.kernel, u32(option_id))
		}
		draw_element_pop(table)
	}
	return result
}

@(private)
text_is_word_byte :: proc "contextless" (b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b >= 0x80
}

@(private)
text_utf8_prev :: proc "contextless" (buf: []u8, pos: int) -> int {
	p := clamp(pos, 0, len(buf))
	if p == 0 {
		return 0
	}
	return text_encoding.complete_characters(buf[:p - 1])
}

@(private)
text_utf8_next :: proc "contextless" (buf: []u8, pos: int) -> int {
	p := clamp(pos, 0, len(buf))
	if p >= len(buf) {
		return len(buf)
	}
	_, length, _ := text_encoding.character_decode(buf, p)
	return min(p + max(length, 1), len(buf))
}

@(private)
text_word_prev :: proc "contextless" (buf: []u8, pos: int) -> int {
	p := clamp(pos, 0, len(buf))
	for p > 0 {
		prev := text_utf8_prev(buf, p)
		if text_is_word_byte(buf[prev]) {
			break
		}
		p = prev
	}
	for p > 0 {
		prev := text_utf8_prev(buf, p)
		if !text_is_word_byte(buf[prev]) {
			break
		}
		p = prev
	}
	return p
}

@(private)
text_word_next :: proc "contextless" (buf: []u8, pos: int) -> int {
	p := clamp(pos, 0, len(buf))
	for p < len(buf) && text_is_word_byte(buf[p]) {
		p = text_utf8_next(buf, p)
	}
	for p < len(buf) && !text_is_word_byte(buf[p]) {
		p = text_utf8_next(buf, p)
	}
	return p
}

@(private)
text_word_bounds :: proc "contextless" (buf: []u8, pos: int) -> (start, end: int) {
	p := clamp(pos, 0, len(buf))
	if len(buf) == 0 {
		return 0, 0
	}
	probe := p < len(buf) ? p : text_utf8_prev(buf, p)
	want_word := text_is_word_byte(buf[probe])
	start = probe
	for start > 0 {
		prev := text_utf8_prev(buf, start)
		if text_is_word_byte(buf[prev]) != want_word {
			break
		}
		start = prev
	}
	end = text_utf8_next(buf, probe)
	for end < len(buf) && text_is_word_byte(buf[end]) == want_word {
		end = text_utf8_next(buf, end)
	}
	return
}

@(private)
text_byte_of_char :: proc "contextless" (buf: []u8, char_index: int) -> int {
	p := 0
	for _ in 0 ..< max(char_index, 0) {
		if p >= len(buf) {
			break
		}
		_, length, _ := text_encoding.character_decode(buf, p)
		p += max(length, 1)
	}
	return min(p, len(buf))
}

@(private)
text_delete_range :: proc "contextless" (buf: []u8, count: ^int, a, b: int) {
	lo := clamp(min(a, b), 0, count^)
	hi := clamp(max(a, b), lo, count^)
	if hi <= lo {
		return
	}
	removed := hi - lo
	for i := hi; i < count^; i += 1 {
		buf[i - removed] = buf[i]
	}
	count^ -= removed
}

@(private)
text_insert_at :: proc "contextless" (buf: []u8, count: ^int, pos: int, data: []u8) -> (new_pos: int, ok: bool) {
	p := clamp(pos, 0, count^)
	if len(data) == 0 {
		return p, true
	}
	if count^ + len(data) > len(buf) {
		return p, false
	}
	for i := count^ - 1; i >= p; i -= 1 {
		buf[i + len(data)] = buf[i]
	}
	for i in 0 ..< len(data) {
		buf[p + i] = data[i]
	}
	count^ += len(data)
	return p + len(data), true
}

// text_input draws a single-line editable field with caret navigation
// (Left/Right/Home/End, Ctrl+Left/Right word jump), selection (Shift+arrows,
// Ctrl+A, click-drag, double-click word, triple-click all), Backspace/Delete
// (and Ctrl+Backspace/Delete word erase), Ctrl+U, and selection-aware
// clipboard copy/paste. Enter activates the field in key order; keys after
// Enter are left untouched.
text_input :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, text: []u8, count: ^int, placeholder := "", name := "", protected := false) -> Element_Result {
	result := element_interact(frame, element, area, .Text_Input)
	if placeholder != "" {
		element_name(frame, area, placeholder)
	}
	count^ = clamp(count^, 0, len(text))
	keep := max(area.width - 16 - 3, 0) / graphics.CELL_WIDTH
	state := frame.state

	// Synchronize or initialize transient caret and selection for the focused field.
	if result.focused {
		if state.text_edit_element != element {
			state.text_edit_element = element
			state.text_caret = count^
			state.text_anchor = count^
			state.text_dragging = false
		}
		state.text_caret = text_encoding.complete_characters(text[:clamp(state.text_caret, 0, count^)])
		state.text_anchor = text_encoding.complete_characters(text[:clamp(state.text_anchor, 0, count^)])

		// Pointer caret placement, drag selection, double-click word, triple-click all.
		cur_chars := text_encoding.character_count(text[:count^])
		caret_chars := text_encoding.character_count(text[:state.text_caret])
		view_first := cur_chars > keep && caret_chars > keep ? caret_chars - keep : 0
		if frame.input.pointer_known {
			rel_px := frame.input.pointer_x - (area.x + 8)
			hit_col := clamp((rel_px + graphics.CELL_WIDTH / 2) / graphics.CELL_WIDTH, 0, max(cur_chars - view_first, 0))
			hit_byte := text_byte_of_char(text[:count^], view_first + hit_col)
			if result.triple_clicked {
				state.text_anchor = 0
				state.text_caret = count^
				state.text_dragging = false
			} else if result.double_clicked {
				state.text_anchor, state.text_caret = text_word_bounds(text[:count^], hit_byte)
				state.text_dragging = false
			} else if result.under_pointer && frame.input.pressed {
				state.text_caret = hit_byte
				if frame.input.button_held {
					state.text_anchor = hit_byte
					state.text_dragging = true
				}
			} else if state.text_dragging && frame.input.button_held {
				state.text_caret = hit_byte
			}
		}
		if !frame.input.button_held {
			state.text_dragging = false
		}

		keys: for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			ctrl := key.modifiers & display.MODIFIER_CONTROL != 0
			shift := key.modifiers & display.MODIFIER_SHIFT != 0
			alt := key.modifiers & display.MODIFIER_ALT != 0
			sel_lo := min(state.text_anchor, state.text_caret)
			sel_hi := max(state.text_anchor, state.text_caret)
			has_sel := sel_hi > sel_lo
			switch {
			case key.code == display.KEY_ENTER:
				// The keys after Enter stay for what Enter starts.
				key.taken = true
				result.activated = true
				break keys
			case ctrl && !alt && (key.character == 'a' || key.character == 'A' || key.character == 0x01):
				key.taken = true
				state.text_anchor = 0
				state.text_caret = count^
			case ctrl && !alt && (key.character == 'u' || key.character == 'U' || key.character == 0x15):
				key.taken = true
				if has_sel {
					text_delete_range(text, count, sel_lo, sel_hi)
					state.text_caret = sel_lo
					state.text_anchor = sel_lo
					result.changed = true
				} else if state.text_caret > 0 {
					text_delete_range(text, count, 0, state.text_caret)
					state.text_caret = 0
					state.text_anchor = 0
					result.changed = true
				}
			case key.code == display.KEY_ESCAPE && has_sel:
				key.taken = true
				state.text_anchor = state.text_caret
			case key.code == display.KEY_LEFT:
				key.taken = true
				if ctrl {
					state.text_caret = text_word_prev(text[:count^], state.text_caret)
				} else if has_sel && !shift {
					state.text_caret = sel_lo
				} else {
					state.text_caret = text_utf8_prev(text[:count^], state.text_caret)
				}
				if !shift {
					state.text_anchor = state.text_caret
				}
			case key.code == display.KEY_RIGHT:
				key.taken = true
				if ctrl {
					state.text_caret = text_word_next(text[:count^], state.text_caret)
				} else if has_sel && !shift {
					state.text_caret = sel_hi
				} else {
					state.text_caret = text_utf8_next(text[:count^], state.text_caret)
				}
				if !shift {
					state.text_anchor = state.text_caret
				}
			case key.code == display.KEY_HOME:
				key.taken = true
				state.text_caret = 0
				if !shift {
					state.text_anchor = 0
				}
			case key.code == display.KEY_END:
				key.taken = true
				state.text_caret = count^
				if !shift {
					state.text_anchor = count^
				}
			case key.code == display.KEY_BACKSPACE:
				key.taken = true
				if has_sel {
					text_delete_range(text, count, sel_lo, sel_hi)
					state.text_caret = sel_lo
					state.text_anchor = sel_lo
					result.changed = true
				} else if state.text_caret > 0 {
					target := ctrl ? text_word_prev(text[:count^], state.text_caret) : text_utf8_prev(text[:count^], state.text_caret)
					text_delete_range(text, count, target, state.text_caret)
					state.text_caret = target
					state.text_anchor = target
					result.changed = true
				}
			case key.code == display.KEY_DELETE:
				key.taken = true
				if has_sel {
					text_delete_range(text, count, sel_lo, sel_hi)
					state.text_caret = sel_lo
					state.text_anchor = sel_lo
					result.changed = true
				} else if state.text_caret < count^ {
					target := ctrl ? text_word_next(text[:count^], state.text_caret) : text_utf8_next(text[:count^], state.text_caret)
					text_delete_range(text, count, state.text_caret, target)
					state.text_anchor = state.text_caret
					result.changed = true
				}
			case !ctrl && !alt && text_encoding.character_in_text(key.character):
				key.taken = true
				encoded: [4]u8
				if length := text_encoding.character_encode(key.character, encoded[:]); length > 0 {
					removed := has_sel ? (sel_hi - sel_lo) : 0
					if count^ - removed + length <= len(text) {
						if has_sel {
							text_delete_range(text, count, sel_lo, sel_hi)
							state.text_caret = sel_lo
						}
						if next_pos, ok := text_insert_at(text, count, state.text_caret, encoded[:length]); ok {
							state.text_caret = next_pos
							state.text_anchor = next_pos
							result.changed = true
						}
					}
				}
			}
		}
		// Clipboard (src/md/features/clipboard.md): copy takes the active
		// selection (or the whole text when empty); paste replaces any active
		// selection and inserts at the caret.
		sel_lo := min(state.text_anchor, state.text_caret)
		sel_hi := max(state.text_anchor, state.text_caret)
		if frame.input.copy_asked && !frame.copy_given {
			if !protected && sel_hi > sel_lo {
				frame.copied, frame.copy_given = text[sel_lo:sel_hi], true
			} else {
				frame.copied, frame.copy_given = text[:count^], true
			}
		}
		if frame.input.paste.kind == .Pasted && !frame.paste_taken && frame.input.paste_window != nil {
			frame.paste_taken = true
			if sel_hi == sel_lo && state.text_caret == count^ {
				if pasted, problem := display.paste_read(frame.input.paste_window, frame.input.paste, text[count^:]); problem == .None {
					count^ += pasted
					state.text_caret = count^
					state.text_anchor = count^
					result.changed = true
				}
			} else {
				// Inline capacity: fast stack buffer for mid-line or selection-replacing paste.
				paste_buf: [1024]u8
				if pasted, problem := display.paste_read(frame.input.paste_window, frame.input.paste, paste_buf[:]); problem == .None {
					removed := sel_hi - sel_lo
					if count^ - removed + pasted <= len(text) {
						if removed > 0 {
							text_delete_range(text, count, sel_lo, sel_hi)
							state.text_caret = sel_lo
						}
						if next_pos, ok := text_insert_at(text, count, state.text_caret, paste_buf[:pasted]); ok {
							state.text_caret = next_pos
							state.text_anchor = next_pos
							result.changed = true
						}
					}
				}
			}
		}
	}

	caret_byte := result.focused ? clamp(state.text_caret, 0, count^) : count^
	anchor_byte := result.focused ? clamp(state.text_anchor, 0, count^) : caret_byte
	sel_lo := min(anchor_byte, caret_byte)
	sel_hi := max(anchor_byte, caret_byte)
	caret_char := text_encoding.character_count(text[:caret_byte])

	table := frame.table
	states := accessibility.Element_States{.Focusable}
	if result.focused {
		states += {.Focused}
	}
	if protected {
		states += {.Protected}
	}
	actions := protected ? accessibility.Element_Actions{.Focus, .Press} : accessibility.Element_Actions{.Focus, .Press, .Insert_Text}
	draw_element_push(table, area, u32(element), .Text_Box, {
		states      = states,
		actions     = actions,
		name        = name,
		placeholder = placeholder,
		value_text  = protected ? "" : string(text[:count^]),
		has_caret   = !protected,
		caret       = protected ? 0 : u64(caret_char),
	})
	defer draw_element_pop(table)
	draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.track, u32(element))
	draw_rectangle(table, area.x, area.y + area.height - 2, area.width, 2, result.focused ? graphics.colors.title : graphics.colors.not_usable, u32(element))
	y := area.y + (area.height - LINE) / 2

	total_chars := text_encoding.character_count(text[:count^])
	first_char := total_chars > keep && caret_char > keep ? caret_char - keep : 0
	shown_end := min(first_char + keep, total_chars)
	first_byte := text_byte_of_char(text[:count^], first_char)
	end_byte := text_byte_of_char(text[:count^], shown_end)
	visible := string(text[first_byte:end_byte])

	if result.focused && sel_hi > sel_lo {
		vis_sel_lo := clamp(text_encoding.character_count(text[:sel_lo]), first_char, shown_end)
		vis_sel_hi := clamp(text_encoding.character_count(text[:sel_hi]), vis_sel_lo, shown_end)
		if vis_sel_hi > vis_sel_lo {
			draw_rectangle(table, area.x + 8 + (vis_sel_lo - first_char) * graphics.CELL_WIDTH, y, (vis_sel_hi - vis_sel_lo) * graphics.CELL_WIDTH, LINE, graphics.colors.chosen, u32(element))
		}
	}
	after := draw_text(table, area.x + 8, y, visible, graphics.colors.text_strong, {}, u32(element))
	if result.focused {
		caret_x := area.x + 8 + clamp(caret_char - first_char, 0, max(keep, 0)) * graphics.CELL_WIDTH
		draw_rectangle(table, caret_x + 1, y, 2, LINE, graphics.colors.title, u32(element))
	}
	if count^ == 0 && placeholder != "" {
		draw_text(table, after + 8, y, text_fit(table, FONT_INTERFACE, placeholder, area.x + area.width - 8 - (after + 8)), graphics.colors.dim, FONT_INTERFACE, u32(element))
	}
	if result.focused {
		draw_focus_ring(table, area, u32(element))
	}
	return result
}

// find_without_case gives the first place of part in name, or -1. The
// letters match without their case.
find_without_case :: proc "contextless" (name, part: string) -> int {
	lower :: proc "contextless" (character: u8) -> u8 {
		return character >= 'A' && character <= 'Z' ? character + 32 : character
	}
	for at in 0 ..= len(name) - len(part) {
		same := true
		for index in 0 ..< len(part) {
			if lower(name[at + index]) != lower(part[index]) {
				same = false
				break
			}
		}
		if same {
			return at
		}
	}
	return -1
}

// What a row of a list of rows is.
List_Row_Kind :: enum u8 {
	Entry, // A thing that the input can choose: an icon, a name, a text at the right.
	Heading, // A dim line that names the group of the rows under it. It is never the chosen row.
}

// One row of a list of rows (list_of_rows). The texts stay in the memory of
// the caller.
List_Row :: struct {
	kind:           List_Row_Kind, // An entry or the heading of a group.
	name:           string, // The name, in the interface font.
	matched_places: u128, // Bit n: the character that starts at the byte n of the name matched the search. A line of 2 pixels is under each such character.
	icon:           ^kind_icons.Cells, // The icon of the kind of the entry, before the name: its form says what the entry is. nil: no icon.
	icon_color:     graphics.Color, // The color of the icon on a row that is not chosen: the color of the kind, or of one fact of the entry.
	right_text:     string, // A dim text at the right of the row: what the entry is, in words.
	name_in_cells:  bool, // The name is code: it is in the font of the cells.
	name_color:     graphics.Color, // The color of the name on a row that is not chosen. 0: the text color.
	detail:         string, // A quiet text right after the name, in the font of the cells: the parameters and the result of a command, or the hash prefix of the file of a disk process. It is cut to its room.
}

// List_Rows_Options: what a list of rows shows beside its rows.
List_Rows_Options :: struct {
	chosen:       int, // The chosen row, as an index in the rows given; -1: none.
	chosen_color: graphics.Color, // The fill of the chosen row. 0: the chosen blue, graphics.colors.chosen.
	chosen_hint:  string, // On the chosen row, this text takes the place of right_text, in white ("enter: start").
	first:        int, // The index of the first row given in the whole list: the place of the thumb of the scroll bar at the right.
	total:        int, // The rows of the whole list. More than the rows of the area: a scroll bar at the right, which shows the place of the rows.
	// Not 0: the scroll bar takes the pointer, under this identity, and
	// `scrolled` gets what the pointer did. The caller owns the view: it
	// gives the rows from scrolled.first in its next frame. 0: the scroll
	// bar shows the place and takes no input.
	scroll_bar:   Element_Identity,
	scrolled:     ^Scroll_Bar_Result, // Where the list writes what the pointer did to its scroll bar. nil: the caller does not read it.
	scroll_bar_name: string, // The element name of the scroll bar that takes the pointer, for the names of its parts (scroll_bar). Empty: its parts have none.
	element:         Element_Identity, // Optional identity of the list container in the semantic tree.
	name:            string, // Optional accessible name of the list container.
}

LIST_ROW_ICON_X :: 16 // From the left of a row to its icon, and to the text of a heading.
LIST_ROW_ICON_SIZE :: kind_icons.ICON_SIZE // The side of the icon: one pixel for each cell.
LIST_ROW_NAME_X :: LIST_ROW_ICON_X + LIST_ROW_ICON_SIZE + 8 // From the left of a row to its name.
LIST_ROW_RIGHT_MARGIN :: 16 // From the text at the right to the right of a row.
LIST_ROW_SCROLL_WIDTH :: SCROLL_BAR_THICKNESS // The scroll bar at the right of a list that does not show each row.

#assert(LIST_ROW_ICON_SIZE <= LINE && (TABLE_LINE - LIST_ROW_ICON_SIZE) % 2 == 0)

// draw_kind_icon appends an icon of a kind (src/library/modus/kind_icons) whose top
// left corner is at (x, y): each cell is a square of cell_size pixels, so
// the icon is sharp at each size, and the records are the rectangles of
// the icon, at most kind_icons.RECTANGLE_LIMIT. An icon that is nil and a
// cell size under 1 draw nothing.
draw_kind_icon :: proc "contextless" (table: ^Draw_Table, x, y: int, icon: ^kind_icons.Cells, cell_size: int, color: graphics.Color, element: u32 = 0) {
	if icon == nil || cell_size < 1 {
		return
	}
	rectangles: [kind_icons.RECTANGLE_LIMIT]kind_icons.Cell_Rectangle
	count := kind_icons.rectangles_of(icon, &rectangles)
	for index in 0 ..< count {
		part := rectangles[index]
		draw_rectangle(table, x + int(part.x) * cell_size, y + int(part.y) * cell_size, int(part.width) * cell_size, int(part.height) * cell_size, color, element)
	}
}

// list_of_rows draws rows of 24 pixels: for each one the icon of its kind,
// a name with a line of 2 pixels under each matched character, a quiet
// detail after a name that is code, and a dim text at the right; the
// chosen row filled, with its icon and its text in white, and at its
// right its hint when the caller gives one, else the same text as the
// other rows. The caller owns the choice and gives only the rows that the
// area shows, so the work is the rows on the screen, not the rows of the
// list. The rows take no input; the scroll bar takes the pointer, and the
// wheel over the rows, when the caller names it
// (List_Rows_Options.scroll_bar). It gives the count of the
// rows that it drew. Its records are cut to its area by a clip, and by each
// clip open around it.
list_of_rows :: proc "contextless" (frame: ^Frame, area: Area, rows: []List_Row, options: List_Rows_Options) -> int {
	table := frame.table
	list_id := options.element != 0 ? options.element : identity("list_of_rows")
	list_role := options.chosen >= 0 ? accessibility.Element_Role.List_Box : accessibility.Element_Role.List
	draw_element_push(table, area, u32(list_id), list_role, {name = options.name})
	defer draw_element_pop(table)
	draw_clip_push(table, area.x, area.y, area.width, area.height)
	defer draw_clip_pop(table)
	shown_count := min(len(rows), area.height / TABLE_LINE, LIST_MEASURE_CAPACITY)
	visible_rows := area.height / TABLE_LINE
	scroll_width := options.total > visible_rows ? LIST_ROW_SCROLL_WIDTH : 0
	line_width := area.width - scroll_width
	chosen_color := options.chosen_color != 0 ? options.chosen_color : graphics.Color(graphics.colors.chosen)
	// The names of the rows, measured in one call.
	names: [LIST_MEASURE_CAPACITY]string
	widths: [LIST_MEASURE_CAPACITY]int
	for index in 0 ..< shown_count {
		names[index] = rows[index].name
	}
	if shown_count > 0 {
		texts_measure(table, FONT_INTERFACE, names[:shown_count], widths[:shown_count])
	}
	set_size := u32(max(options.total, len(rows)))
	for index in 0 ..< shown_count {
		row := rows[index]
		y := area.y + index * TABLE_LINE
		row_id := identity_with(list_id, options.first + index)
		if row.kind == .Heading {
			shown_heading := text_fit(table, FONT_INTERFACE, row.name, line_width - 2 * LIST_ROW_ICON_X)
			draw_element_push(table, {area.x, y, line_width, TABLE_LINE}, u32(row_id), .Heading, {level = 2, name = shown_heading != row.name ? row.name : ""})
			draw_text(table, area.x + LIST_ROW_ICON_X, y + 4, shown_heading, graphics.colors.dim, FONT_INTERFACE, u32(row_id))
			draw_element_pop(table)
			continue
		}
		chosen := index == options.chosen
		row_role := options.chosen >= 0 ? accessibility.Element_Role.Option : accessibility.Element_Role.List_Item
		draw_element_push(table, {area.x, y, line_width, TABLE_LINE}, u32(row_id), row_role, {
			states          = chosen ? {.Selected} : {},
			actions         = options.chosen >= 0 ? {.Select} : {},
			name            = row.name,
			description     = row.detail,
			position_in_set = u32(options.first + index + 1),
			set_size        = set_size,
		})
		if chosen {
			draw_rectangle(table, area.x, y, line_width, TABLE_LINE, chosen_color, u32(row_id))
		}
		// The icon of a chosen row is white, as its text is: no color of
		// the rules keeps the contrast of a graphic on each fill of a
		// chosen row.
		draw_kind_icon(table, area.x + LIST_ROW_ICON_X, y + (TABLE_LINE - LIST_ROW_ICON_SIZE) / 2, row.icon, 1, chosen ? graphics.COLOR_WHITE : row.icon_color, u32(row_id))
		// The text at the right takes its room first; the name takes the rest.
		right_text := chosen && options.chosen_hint != "" ? options.chosen_hint : row.right_text
		name_room := line_width - LIST_ROW_NAME_X - LIST_ROW_RIGHT_MARGIN
		if right_text != "" {
			right_width := text_measured_width(table, FONT_INTERFACE, right_text)
			if right_width <= name_room - 16 {
				draw_text_right(table, area.x + line_width - LIST_ROW_RIGHT_MARGIN, y + 4, right_text, chosen ? graphics.COLOR_WHITE : graphics.colors.dim, FONT_INTERFACE, u32(row_id))
				name_room -= right_width + 16
			}
		}
		name := row.name
		name_font := row.name_in_cells ? Font{} : FONT_INTERFACE
		name_width := row.name_in_cells ? text_width(name_font, name) : widths[index]
		if name_width > name_room {
			name = text_fit(table, name_font, name, name_room)
			name_width = text_measured_width(table, name_font, name)
		}
		name_x := area.x + LIST_ROW_NAME_X
		name_color := row.name_color != 0 ? row.name_color : graphics.Color(graphics.colors.text)
		draw_text(table, name_x, y + 4, name, chosen ? graphics.COLOR_WHITE : name_color, name_font, u32(row_id))
		if row.detail != "" {
			draw_text(table, name_x + name_width, y + 4, text_fit(table, {}, row.detail, name_room - name_width), chosen ? graphics.COLOR_WHITE : graphics.colors.dim, {}, u32(row_id))
		}
		// One line under each run of matched characters, measured in the
		// font of the name: at most one measure for each end of a run.
		for run in matched_runs(name, row.matched_places) {
			if run.end <= run.start {
				break
			}
			start_x := text_measured_width(table, name_font, name[:run.start])
			end_x := text_measured_width(table, name_font, name[:run.end])
			draw_rectangle(table, name_x + start_x, y + 20, end_x - start_x, 2, chosen ? graphics.COLOR_WHITE : graphics.colors.kernel, u32(row_id))
		}
		draw_element_pop(table)
	}
	if scroll_width != 0 && options.total > 0 {
		// The caller owns the choice and the view. A caller that names
		// the scroll bar gets what the pointer did to it; for another one
		// the bar shows the place of the rows, with no input.
		bar_length := visible_rows * TABLE_LINE
		bar_area := Area{area.x + area.width - scroll_width, area.y, scroll_width, bar_length}
		range := Scroll_Range{total = options.total, visible = visible_rows, first = options.first}
		if options.scroll_bar != 0 {
			// The rows are the view of the bar: the wheel over them moves it.
			moved := scroll_bar(frame, bar_area, options.scroll_bar, .Vertical, range, {}, options.scroll_bar_name, area, u32(list_id))
			if options.scrolled != nil {
				options.scrolled^ = moved
			}
		} else {
			scroll_bar_draw(table, bar_area, .Vertical, scroll_bar_geometry(bar_length, scroll_width, range))
		}
	}
	return shown_count
}

TEXT_INPUT_LINE_MARGIN :: 16 // From the left and the right of the field to its text.

// text_input_line draws a field of one line whose text has a caret at any
// place, at a text size in 1/64 pixel (the size of a Font: 0 is the body):
// the track, the line of 2 pixels in the blue of the title bar at its
// bottom, the text in white in the font of the cells, the caret (2 pixels
// wide for each cell of the body in a cell of the size, as high as the
// text), and the placeholder in the dim color when the text is empty. The
// field has no border: its fill reaches each edge of its area. A text
// longer than the field shows the part that holds the caret. It takes no
// input: the caller edits the line (src/library/modus/line_editor). A
// size that no record holds draws nothing and sets `refused`.
text_input_line :: proc "contextless" (frame: ^Frame, area: Area, text: string, caret: int, size: u16, placeholder := "", element: Element_Identity = 0, name := "", protected := false, selection_start := 0, selection_end := 0) {
	table := frame.table
	font := Font{size = size}
	if !font_size_valid(font) {
		table.refused = true
		return
	}
	cell_width := cell_width_of(font)
	text_height := line_height(font)
	caret_width := 2 * max(1, cell_width / graphics.CELL_WIDTH)
	bytes := transmute([]u8)text
	caret_place := text_encoding.character_count(bytes[:clamp(caret, 0, len(text))])
	el := element != 0 ? element : identity("text_input_line")
	states := accessibility.Element_States{.Focusable, .Focused}
	if protected {
		states += {.Protected}
	}
	actions := protected ? accessibility.Element_Actions{.Focus, .Press} : accessibility.Element_Actions{.Focus, .Press, .Insert_Text}
	draw_element_push(table, area, u32(el), .Text_Box, {
		states      = states,
		actions     = actions,
		name        = name,
		placeholder = placeholder,
		value_text  = protected ? "" : text,
		has_caret   = !protected,
		caret       = protected ? 0 : u64(caret_place),
	})
	defer draw_element_pop(table)
	draw_rectangle(table, area.x, area.y, area.width, area.height - 2, graphics.colors.track, u32(el))
	draw_rectangle(table, area.x, area.y + area.height - 2, area.width, 2, graphics.colors.title, u32(el))
	text_x := area.x + TEXT_INPUT_LINE_MARGIN
	text_y := area.y + (area.height - text_height) / 2
	fit := max((area.width - 2 * TEXT_INPUT_LINE_MARGIN - caret_width) / cell_width, 1)
	// The text is UTF-8: one cell for each character, so the caret and the
	// part that shows are counted in characters, and a part starts and
	// ends after a whole character.
	character_total := text_encoding.character_count(bytes)
	first := character_total > fit ? max(caret_place - fit, 0) : 0
	byte_of_character :: proc "contextless" (text_bytes: []u8, number: int) -> int {
		place := 0
		for _ in 0 ..< number {
			_, length, _ := text_encoding.character_decode(text_bytes, place)
			if length == 0 {
				break
			}
			place += length
		}
		return place
	}
	shown_end := min(first + fit, character_total)
	shown := text[byte_of_character(bytes, first):byte_of_character(bytes, shown_end)]
	// Selection highlight behind the caret and text when an active range overlaps the visible slice.
	sel_a := clamp(min(selection_start, selection_end), 0, len(text))
	sel_b := clamp(max(selection_start, selection_end), sel_a, len(text))
	if sel_b > sel_a {
		sel_first := clamp(text_encoding.character_count(bytes[:sel_a]), first, shown_end)
		sel_last := clamp(text_encoding.character_count(bytes[:sel_b]), sel_first, shown_end)
		if sel_last > sel_first {
			draw_rectangle(table, text_x + (sel_first - first) * cell_width, text_y, (sel_last - sel_first) * cell_width, text_height, graphics.colors.chosen, u32(el))
		}
	}
	// The caret first: a glyph beside it draws over its edge, not under it.
	draw_rectangle(table, text_x + (caret_place - first) * cell_width, text_y, caret_width, text_height, graphics.colors.title, u32(el))
	draw_text(table, text_x, text_y, shown, graphics.colors.text_strong, font, u32(el))
	if len(text) == 0 && placeholder != "" {
		placeholder_x := text_x + cell_width
		placeholder_font := Font{kind = .Interface, size = size}
		draw_text(table, placeholder_x, text_y, text_fit(table, placeholder_font, placeholder, area.x + area.width - TEXT_INPUT_LINE_MARGIN - placeholder_x), graphics.colors.dim, placeholder_font, u32(el))
	}
}
