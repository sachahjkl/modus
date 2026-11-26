#+build !freestanding
#+build !modus
package interface

import "base:runtime"
import "modus:contract/draw_record"
import "modus:contract/font_outlines"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "core:slice"
import "core:sync"
import "core:testing"
import "modus:display"
import "modus:graphics"
import "modus:text_rendering"

// The interface font of the tests: the faces B612 Regular and B612 Bold,
// from the font outlines that interface_outlines_open opened.
@(private = "file")
Test_Interface_Font :: struct {
	font: display.Interface_Font,
}

// The font outlines of the tests, opened once in the state of the text
// rendering of the process, with its glyph memory: a text in the interface
// font is measured from its font file, and its glyphs are drawn into the
// private glyph cache. No test of this package changes that state; the
// words and the memory stay for the run, as the open fonts and the cache
// read them, so they come from the heap of the process: the runner frees
// what a test allocated at its end.
@(private = "file")
interface_outlines_lock: sync.Mutex
@(private = "file")
interface_outlines_words: []u64

@(private = "file")
interface_outlines_open :: proc(t: ^testing.T) {
	sync.mutex_lock(&interface_outlines_lock)
	defer sync.mutex_unlock(&interface_outlines_lock)
	if interface_outlines_words != nil {
		return
	}
	fonts := [5]font_outlines.Font_Input {
		{"b612", #load("../../../../resources/fonts/b612.ttf")},
		{"b612_bold", #load("../../../../resources/fonts/b612_bold.ttf")},
		{"paper_mono", #load("../../../../resources/fonts/paper_mono.ttf")},
		{"paper_mono_semibold", #load("../../../../resources/fonts/paper_mono_semibold.ttf")},
		{"noto_sans", #load("../../../../resources/fonts/noto_sans.ttf")},
	}
	size := font_outlines.resource_size(fonts[:])
	interface_outlines_words = make([]u64, (size + 7) / 8, runtime.heap_allocator())
	bytes := ([^]u8)(raw_data(interface_outlines_words))[:size]
	_, written := font_outlines.resource_write(fonts[:], bytes)
	testing.expect(t, written)
	room := new(font_outlines.Record_Room, context.temp_allocator)
	outlines, problem := font_outlines.validate(bytes, room[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	text_rendering.memory_give(new(text_rendering.Glyph_Memory, runtime.heap_allocator()))
	missing := text_rendering.open(&outlines)
	testing.expect_value(t, missing, text_rendering.Outline_Fonts{})
}

@(private = "file")
test_interface_font :: proc(t: ^testing.T) -> (result: Test_Interface_Font) {
	interface_outlines_open(t)
	testing.expect(t, display.interface_faces_opened())
	result.font = display.INTERFACE_FONT
	return result
}

@(private = "file")
Font_Tables :: struct {
	records: [256]Draw_Record,
	text:    [4096]u8,
}

@(private = "file")
font_table_of :: proc(memory: ^Font_Tables, font: ^display.Interface_Font) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:], interface_font = font}
}

// The generator of the tests: the same numbers on each host.
@(private = "file")
next_number :: proc(state: ^u32) -> int {
	state^ = state^ * 1664525 + 1013904223
	return int(state^ >> 8)
}

@(private = "file")
WORDS :: [?]string{"To", "LT", "Ty", "settings", "AVATAR", "Wave", "palette", "jj", "fill", "rings", "0O 1lI", "Monitor", "the clock", "W", "i"}

// The parts of a frame of build_labels that a change can name.
@(private = "file")
LABEL_PARTS :: 17

// pick gives the next number of the generator; for the part that changed,
// the number after it, so that this part shows another word, place, weight
// or color. The generator takes the same steps in both frames, so each
// other part is the same.
@(private = "file")
pick :: proc(state: ^u32, part: ^int, changed: int) -> int {
	number := next_number(state)
	if part^ == changed {
		number += 1
	}
	part^ += 1
	return number
}

// One frame of labels in the interface font, side by side so that their
// ink margins overlap, with a label and a value, a button and a card, all
// from one seed; the part `changed` differs from the frame with no change.
@(private = "file")
build_labels :: proc(table: ^Draw_Table, seed: u32, changed: int) {
	words := WORDS
	state := seed
	part := 0
	draw_table_clear(table)
	draw_rectangle(table, 0, 0, 320, 200, graphics.colors.background)
	card_state := Interface_State{}
	card_input := Input{}
	frame := Frame{table = table, state = &card_state, input = &card_input}
	title := words[pick(&state, &part, changed) % len(words)]
	caption := words[pick(&state, &part, changed) % len(words)]
	card(&frame, {4, 4, 312, 72}, title, caption, graphics.colors.kernel, "12")
	x := 8
	for _ in 0 ..< 6 {
		chosen := pick(&state, &part, changed)
		word := words[chosen % len(words)]
		font := (chosen / 16) % 4 == 0 ? FONT_INTERFACE_BOLD : FONT_INTERFACE
		color := (chosen / 64) % 3 == 0 ? graphics.colors.dim : graphics.colors.text
		after := draw_text(table, x, 40, word, u32(color), font)
		// The next label starts at the end of this one, or 1 or 2 pixels
		// before it: their ink margins overlap.
		x = after - (chosen / 256) % 3
	}
	// Texts that end at a place: their origins are at a third of a pixel.
	for row in 0 ..< 3 {
		chosen := pick(&state, &part, changed)
		right := 200 + chosen % 7
		draw_text_right(table, right, 80 + row * 18, words[(chosen / 8) % len(words)], graphics.colors.text, FONT_INTERFACE)
		next := pick(&state, &part, changed)
		draw_text(table, right + 4 - next % 3, 80 + row * 18, words[(next / 4) % len(words)], graphics.colors.process, FONT_INTERFACE)
	}
	label := words[pick(&state, &part, changed) % len(words)]
	value := words[pick(&state, &part, changed) % len(words)]
	label_value_line(&frame, {8, 140, 300, 16}, label, value)
	button(&frame, {8, 164, 140, 24}, identity("press"), words[pick(&state, &part, changed) % len(words)])
	draw_text(table, 160, 168, words[pick(&state, &part, changed) % len(words)], graphics.colors.text, {kind = .Interface, size = graphics.TEXT_LARGE * TEXT_SIZE_UNITS})
}

// The damage of a frame in the interface font, drawn as a window draws it
// (each damage rectangle painted with the background, then each record
// that touches it drawn again, in order), gives the bytes of the whole
// frame: no stale pixel and no missing pixel, for 200 pairs of frames that
// differ in one part (or in none).
@(test)
damage_of_interface_text_equals_the_whole_frame :: proc(t: ^testing.T) {
	process_drawing_begin()
	font := test_interface_font(t)
	first, second := new(Font_Tables), new(Font_Tables)
	defer free(first)
	defer free(second)
	before, now := font_table_of(first, &font.font), font_table_of(second, &font.font)
	partial := make([]graphics.Color, 320 * 200)
	defer delete(partial)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	partial_canvas := graphics.Canvas{pixels = raw_data(partial), width = 320, height = 200, stride = 320}
	whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = 320, height = 200, stride = 320}
	differing_frames := 0
	interface_records := 0
	damaged_frames := 0
	for pair in 0 ..< 200 {
		// The two frames from one seed; in the second, one part changed
		// (the part LABEL_PARTS changes nothing: the same frame).
		seed := u32(pair * 7919 + 1)
		build_labels(&before, seed, LABEL_PARTS)
		build_labels(&now, seed, pair % (LABEL_PARTS + 1))
		for record in now.records[:now.record_count] {
			if is_interface_text(record) {
				interface_records += 1
			}
		}
		graphics.clear(partial_canvas, graphics.colors.background)
		execute(&before, partial_canvas)
		damage: Damage
		damage_by_difference(&before, &now, &damage)
		if damage.count > 0 {
			damaged_frames += 1
		}
		draw_damage_on_surface(&now, partial_canvas, damage.rectangles[:damage.count])
		graphics.clear(whole_canvas, graphics.colors.background)
		execute(&now, whole_canvas)
		if !slice.equal(partial, whole) {
			differing_frames += 1
		}
	}
	testing.expect(t, interface_records > 0, "the frames hold texts in the interface font")
	testing.expect(t, damaged_frames > 100, "most pairs of frames differ")
	testing.expectf(t, differing_frames == 0, "%v of 200 frames drawn in their damage differ from the whole frame", differing_frames)
}

// The box of the measure of a text record: its rectangle without its ink
// margin.
@(private = "file")
measured_box :: proc(record: Draw_Record) -> Rectangle {
	box := record_rectangle(record)
	if view := record_view(record); view.kind == .Text && view.font == .Interface {
		margin := ink_margin_of_view(view)
		box.left += margin
		box.right -= margin
	}
	return box
}

// The ink margin of a text in the interface font: from the left edge of
// its box to the pixel of its origin.
@(private = "file")
ink_margin_of_view :: proc(view: Record_View) -> int {
	return draw_record.pixels_floor(view.origin_x) - view.x
}

// A Text record in the interface font with any other fields, as a caller
// can write it by hand: the border has no say in its bytes.
@(private = "file")
interface_text_record_of :: proc(fields: draw_record.Text_Fields, left, top, right, bottom: i32) -> Draw_Record {
	in_font := fields
	in_font.font = u8(Font_Kind.Interface)
	in_font.color = u32(draw_record.opaque(fields.color))
	return {kind = u8(Draw_Kind.Text), left = left, top = top, right = right, bottom = bottom, fields = transmute([draw_record.FIELDS_SIZE]u8)in_font}
}

// No element lets a text pass its box, in the font of the cells and in
// the interface font: each element with texts too long for it, then each
// text record of its frame inside the area of the element. The large
// number of a card is not in the list: it is a value that the caller
// places, with no box.
@(test)
no_element_passes_its_box_in_either_font :: proc(t: ^testing.T) {
	process_drawing_begin()
	font := test_interface_font(t)
	LONG :: "a name far too long for its box, WWWWW MMMMM, and more text after it"
	Element_Case :: struct {
		name: string,
		area: Area,
		draw: proc(frame: ^Frame, area: Area),
	}
	cases := [?]Element_Case {
		{"card", {8, 8, 200, 80}, proc(frame: ^Frame, area: Area) {card(frame, area, LONG, LONG, graphics.colors.kernel, "12 345")}},
		{"label and value at the right", {8, 8, 200, 16}, proc(frame: ^Frame, area: Area) {label_value_line(frame, area, LONG, "1 234 567")}},
		{"label and value at a column", {8, 8, 200, 16}, proc(frame: ^Frame, area: Area) {label_value_line(frame, area, LONG, LONG, graphics.colors.text, 96)}},
		{"button", {8, 8, 120, 24}, proc(frame: ^Frame, area: Area) {button(frame, area, identity("button"), LONG)}},
		{"list", {8, 8, 160, 72}, proc(frame: ^Frame, area: Area) {
				names := [?]string{LONG, "WWWWWWWWWWWWWWWWWWWWWW", "short"}
				choice := 0
				list_with_choice(frame, area, identity("list"), names[:], &choice, {marked = "far", chosen_hint = "enter: start"})
			}},
		{"empty list", {8, 8, 120, 72}, proc(frame: ^Frame, area: Area) {
				choice := 0
				list_with_choice(frame, area, identity("empty"), nil, &choice, {empty_text = LONG})
			}},
		{"table header", {8, 8, 240, 24}, proc(frame: ^Frame, area: Area) {
				cells: [3]Area
				sizes := [3]Size{share(), characters(6), characters(6)}
				row_split(area, sizes[:], cells[:], 8)
				table_header(frame, cells[:], {LONG, LONG, "bytes"}, {.Left, .Right, .Right})
			}},
		{"cell text in the interface font", {8, 8, 100, 24}, proc(frame: ^Frame, area: Area) {cell_text(frame, area, LONG, graphics.colors.text, .Right, FONT_INTERFACE)}},
		{"cell text in the font of the cells", {8, 8, 100, 24}, proc(frame: ^Frame, area: Area) {cell_text(frame, area, LONG, graphics.colors.text)}},
		{"text input", {8, 8, 120, 24}, proc(frame: ^Frame, area: Area) {
				typed: [64]u8
				count := copy(typed[:], LONG)
				text_input(frame, area, identity("input"), typed[:], &count)
				empty := 0
				text_input(frame, area, identity("placeholder"), typed[:], &empty, LONG)
			}},
	}
	fonts := [2]^display.Interface_Font{nil, &font.font}
	for interface_font in fonts {
		for item in cases {
			memory := new(Font_Tables)
			defer free(memory)
			table := font_table_of(memory, interface_font)
			state: Interface_State
			input: Input
			frame := frame_begin(&table, &state, &input)
			item.draw(&frame, item.area)
			frame_end(&frame)
			for record in table.records[:table.record_count] {
				if !is_text_record(record) {
					continue
				}
				box := measured_box(record)
				inside := box.left >= item.area.x && box.right <= item.area.x + item.area.width && box.top >= item.area.y && box.bottom <= item.area.y + item.area.height
				testing.expectf(t, inside, "%s (interface font: %v): a text at %v passes the area %v", item.name, interface_font != nil, box, item.area)
				testing.expectf(t, !is_interface_text(record) || interface_font != nil, "%s: an interface text with no interface font", item.name)
			}
		}
	}
}

// A text in the interface font is measured and drawn in the font that the
// table has: with no interface font, or when the text is longer than the
// limit, it is a text of the font of the cells, measured as one.
@(test)
the_font_of_a_text_is_the_font_of_its_measure :: proc(t: ^testing.T) {
	process_drawing_begin()
	font := test_interface_font(t)
	with_font, without_font := new(Font_Tables), new(Font_Tables)
	defer free(with_font)
	defer free(without_font)
	table := font_table_of(with_font, &font.font)
	plain := font_table_of(without_font, nil)
	after := draw_text(&table, 10, 0, "To LT", graphics.colors.text, FONT_INTERFACE)
	first := record_view(table.records[0])
	testing.expect(t, is_interface_text(table.records[0]), "a text in the interface font")
	testing.expect_value(t, after, 10 + text_measured_width(&table, FONT_INTERFACE, "To LT"))
	margin := ink_margin_of_view(first)
	testing.expect_value(t, margin, graphics.PROPORTIONAL_INK_MARGIN)
	testing.expect_value(t, first.x, 10 - margin)
	testing.expect_value(t, first.origin_x, draw_record.units_of_pixels(10))
	plain_after := draw_text(&plain, 10, 0, "To LT", graphics.colors.text, FONT_INTERFACE)
	testing.expect(t, is_cells_text(plain.records[0]), "with no interface font, a text in the font of the cells")
	testing.expect_value(t, plain_after, 10 + 5 * graphics.CELL_WIDTH)
	long: [INTERFACE_TEXT_LIMIT + 1]u8
	for &byte in long {
		byte = 'a'
	}
	draw_text(&table, 0, 20, string(long[:]), graphics.colors.text, FONT_INTERFACE)
	testing.expect(t, is_cells_text(table.records[1]), "a text past the limit in the font of the cells")
	// A text that ends at a place: its origin is at a third of a pixel, and
	// its measured box ends at the place, rounded up.
	draw_text_right(&table, 100, 40, "Ty", graphics.colors.text, FONT_INTERFACE)
	record := table.records[2]
	view := record_view(record)
	testing.expect(t, view.read && draw_record.origin_valid(view.origin_x, record.left, u16(view.size)))
	testing.expect(t, view.x + view.width - ink_margin_of_view(view) <= 101)
	// The measure of many texts in one call gives the measures one by one.
	texts := [?]string{"To", "LT", "palette", "", "W"}
	widths: [len(texts)]int
	texts_measure(&table, FONT_INTERFACE, texts[:], widths[:])
	for text, index in texts {
		testing.expect_value(t, widths[index], text_measured_width(&table, FONT_INTERFACE, text))
		// A column is as wide as its text, with no round up.
		testing.expect_value(t, measured_size(&table, FONT_INTERFACE, text), pixels(widths[index]))
	}
	fitted := text_fit(&table, FONT_INTERFACE, "settings and more", 40)
	testing.expect(t, text_measured_width(&table, FONT_INTERFACE, fitted) <= 40 && len(fitted) < len("settings and more"))
}

// A Text record in the interface font that a caller wrote by hand: a range outside
// the text table, an origin inside a pixel and off a third, an origin past
// the largest ink margin or at the largest value, a scale of 0 or 4, a
// weight that names no member, a box past the coordinate limit: it draws
// nothing and makes no fault, and a record with a range outside its table
// is equal to no record.
@(test)
hostile_interface_text_records_draw_nothing :: proc(t: ^testing.T) {
	process_drawing_begin()
	font := test_interface_font(t)
	memory := new(Font_Tables)
	defer free(memory)
	table := font_table_of(memory, &font.font)
	copy(table.text[:], "To LT")
	table.text_count = 5
	Fields :: draw_record.Text_Fields
	// The box of 60 by 16 pixels at the corner, and the origin 2 pixels
	// inside it: the ink margin of the font.
	right, bottom := draw_record.units_of_pixels(60), draw_record.units_of_pixels(16)
	origin := draw_record.units_of_pixels(2)
	good := interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = origin, size = graphics.TEXT_BODY * TEXT_SIZE_UNITS}, 0, 0, right, bottom)
	hostile := [?]Draw_Record {
		interface_text_record_of(Fields{first = 3, count = 5, color = graphics.colors.text, origin_x = origin, size = graphics.TEXT_BODY * TEXT_SIZE_UNITS}, 0, 0, right, bottom),
		interface_text_record_of(Fields{first = max(u32), count = max(u32), color = graphics.colors.text, origin_x = origin, size = graphics.TEXT_BODY * TEXT_SIZE_UNITS}, 0, 0, right, bottom),
		interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = origin + 1, size = graphics.TEXT_BODY * TEXT_SIZE_UNITS}, 0, 0, right, bottom),
		interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = max(i32), size = graphics.TEXT_BODY * TEXT_SIZE_UNITS}, 0, 0, right, bottom),
		interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = draw_record.units_of_pixels(INK_MARGIN_LIMIT + 1), size = graphics.TEXT_BODY * TEXT_SIZE_UNITS}, 0, 0, right, bottom),
		interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = origin, size = 0}, 0, 0, right, bottom),
		interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = origin, size = draw_record.TEXT_SIZE_LIMIT + 1}, 0, 0, right, bottom),
		interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = origin, size = graphics.TEXT_BODY * TEXT_SIZE_UNITS, weight = u8(max(Font_Weight)) + 1}, 0, 0, right, bottom),
		interface_text_record_of(Fields{count = 5, color = graphics.colors.text, origin_x = origin, size = graphics.TEXT_BODY * TEXT_SIZE_UNITS}, max(i32) - 63, max(i32) - 63, max(i32) - 63, max(i32) - 63),
	}
	pixels: [64 * 16]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = 64, height = 16, stride = 64}
	for record, index in hostile {
		table.records[0] = record
		table.record_count = 1
		pixels = {}
		execute(&table, canvas)
		testing.expectf(t, pixels == [64 * 16]graphics.Color{}, "the hostile record %v draws", index)
	}
	// The good record draws.
	table.records[0] = good
	execute(&table, canvas)
	testing.expect(t, pixels != [64 * 16]graphics.Color{}, "the good record draws")
	// A range outside the table is equal to no record, so it is damaged.
	testing.expect(t, !records_equal(&table, hostile[0], &table, hostile[0]))
	testing.expect(t, records_equal(&table, good, &table, good))
}

// The rectangles of a damage that cut a canvas of 400 by 64 pixels into
// four parts, across the texts of the test below.
@(private = "file")
TEXT_PARTS :: [4]Rectangle{{0, 0, 37, 64}, {37, 0, 151, 30}, {37, 30, 151, 64}, {151, 0, 400, 64}}

// The old path of a text in the interface font: the shaping and the glyphs
// of the face of the interface font from the origin of the text, cut to
// the box of its record, as the kind Interface_Text drew it.
@(private = "file")
interface_text_reference :: proc(canvas: graphics.Canvas, box: Rectangle, origin: i64, text: string, font: Font, color: graphics.Color) {
	view := graphics.view(canvas, box.left, box.top, box.right - box.left, box.bottom - box.top)
	spacing, ok := interface_spacing_of(font)
	if !ok {
		return
	}
	placed: [INTERFACE_TEXT_LIMIT]text_rendering.Placed_Glyph
	count, _, _ := text_rendering.shape(&spacing, transmute([]u8)text, placed[:])
	graphics.text_proportional(view, origin - i64(box.left) * 64, 0, placed[:min(count, len(placed))], interface_face_of(font), font_text_size(font), color)
}

// The old path of a text in the font of the cells: the cells from the top
// left corner of the box of its record, cut to it and to the canvas, as the
// kind Text drew it. A view wider than the rest of its canvas would wrap the
// ink past the right edge onto the next line.
@(private = "file")
cells_text_reference :: proc(canvas: graphics.Canvas, x, y: int, text: string, font: Font, color: graphics.Color) {
	view := graphics.view(canvas, x, y, min(text_width(font, text), canvas.width - x), min(line_height(font), canvas.height - y))
	text_draw(view, 0, 0, text, color, font_text_size(font), font.weight)
}

// Each text drawn through the one Text record equals, pixel by pixel, the
// old path of its kind, whole and in the rectangles of a damage: in the
// interface font at each third of a pixel, and in the font of the cells,
// for several texts, each text size token and each weight.
@(test)
each_text_draws_the_pixels_of_its_old_kind :: proc(t: ^testing.T) {
	process_drawing_begin()
	font := test_interface_font(t)
	WIDTH :: 400
	HEIGHT :: 64
	texts := [?]string{"To LT", "settings and more", "W", "palette 42", "Ty"}
	weights := [2]Font_Weight{.Regular, .Bold}
	drawn := make([]graphics.Color, WIDTH * HEIGHT)
	parts := make([]graphics.Color, WIDTH * HEIGHT)
	expected := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(drawn)
	defer delete(parts)
	defer delete(expected)
	canvas_of :: proc(pixels: []graphics.Color) -> graphics.Canvas {
		return {pixels = raw_data(pixels), width = WIDTH, height = HEIGHT, stride = WIDTH}
	}
	clear_all :: proc(canvases: [3][]graphics.Color) {
		for pixels in canvases {
			for &pixel in pixels {
				pixel = 0
			}
		}
	}
	color := graphics.colors.text
	checked := 0
	tokens := [?]int{graphics.TEXT_CAPTION, graphics.TEXT_BODY, graphics.TEXT_HEADING, graphics.TEXT_LARGE, graphics.TEXT_LARGEST}
	for text in texts {
		for token in tokens {
			size := u16(token * TEXT_SIZE_UNITS)
			for weight in weights {
				for third in 0 ..< 3 {
					// The interface font, its origin at 20 pixels and a third.
					used := Font{kind = .Interface, size = size, weight = weight}
					memory := new(Font_Tables)
					table := font_table_of(memory, &font.font)
					place := i64(20) * 64 + i64(third) * 64 / 3
					interface_text_append(&table, place, 8, text, color, used, 0)
					if !testing.expectf(t, table.record_count == 1 && is_interface_text(table.records[0]), "%q at the third %d: no text in the interface font", text, third) {
						free(memory)
						continue
					}
					pixel, position := text_rendering.position_of(place, text_rendering.POSITION_LIMIT)
					origin := pixel * 64 + i64(position) * 64 / 3
					clear_all({drawn, parts, expected})
					execute(&table, canvas_of(drawn))
					rectangles := TEXT_PARTS
					execute_in_rectangles(&table, canvas_of(parts), rectangles[:])
					interface_text_reference(canvas_of(expected), record_rectangle(table.records[0]), origin, text, used, color)
					testing.expectf(t, slice.equal(drawn, expected), "%q, size %d, weight %v, third %d: the interface font draws other pixels", text, token, weight, third)
					testing.expectf(t, slice.equal(parts, expected), "%q, size %d, weight %v, third %d: the interface font in parts draws other pixels", text, token, weight, third)
					free(memory)
					// The font of the cells, at a whole pixel of each third.
					cells := Font{kind = .Cells_8x16, size = size, weight = weight}
					cells_memory := new(Font_Tables)
					cells_table := font_table_of(cells_memory, nil)
					x := 13 + third
					draw_text(&cells_table, x, 8, text, color, cells)
					if !testing.expectf(t, cells_table.record_count == 1 && is_cells_text(cells_table.records[0]), "%q: no text in the font of the cells", text) {
						free(cells_memory)
						continue
					}
					testing.expect_value(t, record_view(cells_table.records[0]).origin_x, draw_record.units_of_pixels(x))
					clear_all({drawn, parts, expected})
					execute(&cells_table, canvas_of(drawn))
					execute_in_rectangles(&cells_table, canvas_of(parts), rectangles[:])
					cells_text_reference(canvas_of(expected), x, 8, text, cells, color)
					testing.expectf(t, slice.equal(drawn, expected), "%q, size %d, weight %v: the font of the cells draws other pixels", text, token, weight)
					testing.expectf(t, slice.equal(parts, expected), "%q, size %d, weight %v: the font of the cells in parts draws other pixels", text, token, weight)
					free(cells_memory)
					checked += 1
				}
			}
		}
	}
	testing.expect_value(t, checked, len(texts) * len(tokens) * len(weights) * 3)
	// A text with no interface font in the table is drawn in the font of
	// the cells at the pixel of its origin, as the old kind drew it.
	memory := new(Font_Tables)
	defer free(memory)
	table := font_table_of(memory, &font.font)
	interface_text_append(&table, 20 * 64 + 21, 8, "To LT", color, {kind = .Interface}, 0)
	table.interface_font = nil
	clear_all({drawn, parts, expected})
	execute(&table, canvas_of(drawn))
	box := record_rectangle(table.records[0])
	view := graphics.view(canvas_of(expected), box.left, box.top, box.right - box.left, box.bottom - box.top)
	text_draw(view, 20 - box.left, 0, "To LT", color, font_text_size({}), .Regular)
	testing.expect(t, slice.equal(drawn, expected), "a text in the interface font with no font draws other pixels than the font of the cells")
}

// The caption of a card, in both fonts: at the caption size, on the
// baseline of the title, after the title with no overlap, and inside the
// band of the title, so that it never reaches the content under it. The
// title stays at the size of the body.
@(test)
the_caption_of_a_card_is_on_the_baseline_of_its_title :: proc(t: ^testing.T) {
	font := test_interface_font(t)
	CARD :: Area{8, 8, 400, 80}
	fonts := [2]^display.Interface_Font{nil, &font.font}
	for interface_font in fonts {
		memory := new(Font_Tables)
		defer free(memory)
		table := font_table_of(memory, interface_font)
		state: Interface_State
		input: Input
		frame := frame_begin(&table, &state, &input)
		content := card(&frame, CARD, "TITLE", "a caption", graphics.colors.kernel, "12")
		frame_end(&frame)
		title, caption: Draw_Record
		title_found, caption_found := false, false
		for record in table.records[:table.record_count] {
			text, _, is_text := text_of_record(&table, record)
			switch {
			case !is_text:
			case text == "TITLE":
				title, title_found = record, true
			case text == "a caption":
				caption, caption_found = record, true
			}
		}
		with_font := interface_font != nil
		testing.expectf(t, title_found && caption_found, "interface font %v: the card writes its title and its caption", with_font)
		title_view, caption_view := record_view(title), record_view(caption)
		testing.expect_value(t, title_view.size, BODY_TEXT_SIZE)
		testing.expect_value(t, caption_view.size, font_text_size(FONT_CAPTION))
		testing.expect_value(t, caption_view.y + baseline_of_font(&table, FONT_CAPTION), title_view.y + baseline_of_font(&table, FONT_INTERFACE_BOLD))
		testing.expectf(t, measured_box(caption).left >= measured_box(title).right, "interface font %v: the caption starts after the title", with_font)
		testing.expectf(t, caption_view.y >= CARD.y && caption_view.y + caption_view.height <= content.y, "interface font %v: the line of the caption, from %v, %v high, is above the content at %v", with_font, caption_view.y, caption_view.height, content.y)
	}
}

// A heading and a caption that are wider than their box go on more lines,
// in both fonts: each line at its size, one line under the line before,
// inside the box, with no byte lost but the spaces at a break; the height
// that the draw gives is the height of the measure. The edges come first:
// an empty text takes no height and writes no record, and a box of 0
// pixels or of 1 still ends, with one character on each line.
@(test)
a_heading_and_a_caption_wrap_in_their_box :: proc(t: ^testing.T) {
	font := test_interface_font(t)
	LONG :: "a text far too long for its box, WWWWW MMMMM, and more text after it"
	Wrapped :: struct {
		name:    string,
		font:    Font,
		draw:    proc "contextless" (frame: ^Frame, x, y, room: int, text: string) -> int,
		measure: proc "contextless" (table: ^Draw_Table, text: string, room: int) -> int,
	}
	cases := [2]Wrapped {
		{"heading", FONT_HEADING, proc "contextless" (frame: ^Frame, x, y, room: int, text: string) -> int {return draw_heading(frame, x, y, room, text, graphics.colors.text)}, heading_height},
		{"caption", FONT_CAPTION, draw_caption, caption_height},
	}
	non_space_bytes :: proc(text: string) -> (count: int) {
		for character in transmute([]u8)text {
			count += int(character != ' ')
		}
		return count
	}
	X :: 8
	Y :: 8
	fonts := [2]^display.Interface_Font{nil, &font.font}
	for interface_font in fonts {
		for item in cases {
			for room in ([?]int{0, 1, 120, 240}) {
				for text in ([?]string{"", LONG}) {
					memory := new(Font_Tables)
					defer free(memory)
					table := font_table_of(memory, interface_font)
					state: Interface_State
					input: Input
					frame := frame_begin(&table, &state, &input)
					height := item.draw(&frame, X, Y, room, text)
					frame_end(&frame)
					with_font := interface_font != nil
					testing.expectf(t, height == item.measure(&table, text, room), "%s, interface font %v, room %v: the draw takes %v, the measure %v", item.name, with_font, room, height, item.measure(&table, text, room))
					line := line_height(item.font)
					testing.expect_value(t, line, font_text_size(item.font) / TEXT_SIZE_UNITS)
					lines, bytes := 0, 0
					for record in table.records[:table.record_count] {
						shown, size, is_text := text_of_record(&table, record)
						if !is_text {
							continue
						}
						view := record_view(record)
						testing.expectf(t, size == font_text_size(item.font), "%s, interface font %v, room %v: a line at the size %v", item.name, with_font, room, size)
						testing.expectf(t, view.y == Y + lines * line, "%s, interface font %v, room %v: the line %v at %v, not under the line before", item.name, with_font, room, lines, view.y)
						box := measured_box(record)
						// A box narrower than one character holds one
						// character on each line, which passes it.
						if room >= 120 {
							testing.expectf(t, box.left >= X && box.right <= X + room, "%s, interface font %v, room %v: the line %q passes its box", item.name, with_font, room, shown)
						}
						lines += 1
						bytes += non_space_bytes(shown)
					}
					testing.expect_value(t, height, lines * line)
					testing.expectf(t, bytes == non_space_bytes(text), "%s, interface font %v, room %v: %v bytes of %v drawn", item.name, with_font, room, bytes, non_space_bytes(text))
					if text == LONG && room == 120 {
						testing.expectf(t, lines >= 2, "%s, interface font %v: a text wider than its box takes more lines", item.name, with_font)
					}
				}
			}
		}
	}
}

// The baseline of a font is the baseline of the face that draws it, at
// each size of the tokens; a font whose text the table draws in the font
// of the cells takes the baseline of the cells. A larger size never has
// a higher baseline, so a caption on the line of a title starts lower.
@(test)
the_baseline_of_a_font_follows_its_face :: proc(t: ^testing.T) {
	font := test_interface_font(t)
	memory := new(Font_Tables)
	defer free(memory)
	table := font_table_of(memory, &font.font)
	plain := font_table_of(memory, nil)
	tokens := [?]int{graphics.TEXT_CAPTION, graphics.TEXT_BODY, graphics.TEXT_HEADING, graphics.TEXT_LARGE, graphics.TEXT_LARGEST}
	previous := 0
	for token in tokens {
		interface_font := Font{kind = .Interface, size = u16(token * TEXT_SIZE_UNITS)}
		row, found := text_rendering.baseline_row(.Interface, token * TEXT_SIZE_UNITS)
		testing.expectf(t, found, "the size %v: B612 has a baseline", token)
		testing.expect_value(t, baseline_of_font(&table, interface_font), row)
		testing.expectf(t, row >= previous, "the size %v: the baseline %v is above %v of a smaller size", token, row, previous)
		previous = row
		// With no interface font in the table, the text is in the font of
		// the cells: its baseline.
		testing.expect_value(t, baseline_of_font(&plain, interface_font), baseline_of_font(&plain, Font{size = interface_font.size}))
	}
	testing.expect_value(t, text_top_on_baseline(&table, FONT_INTERFACE, 100, FONT_INTERFACE), 100)
	testing.expectf(t, text_top_on_baseline(&table, FONT_INTERFACE_BOLD, 100, FONT_CAPTION) >= 100, "a caption on the line of a title starts at its top or lower")
}

// The font of an interface text follows the settings page at each read,
// with no event Presentation between two reads: the case of a window
// that read the page before the boot pass of `settings` and made its
// surface after it, so that the compositor never told it. The setting
// `spleen` gives a text in the font of the cells, in Spleen; `vector`
// gives the interface font again; each change is told, and a read with no
// change is not. A page left in the middle of a change is refused and
// gives the defaults: the vector font. The record that draw_text appends
// is the record of the font in use, last.
@(test)
the_interface_text_follows_the_setting_of_the_font :: proc(t: ^testing.T) {
	process_drawing_begin()
	font := test_interface_font(t)
	saved_page := display.settings_page
	saved_font, saved_order := graphics.text_state.font, graphics.text_state.order
	saved_cells, saved_bold := graphics.text_state.cell_face, graphics.text_state.bold_face
	saved_appearance := graphics.appearance
	defer {
		display.settings_page = saved_page
		graphics.text_choice_set(saved_font, saved_order)
		graphics.text_state.cell_face, graphics.text_state.bold_face = saved_cells, saved_bold
		graphics.appearance_use(saved_appearance)
	}
	page := new(settings.Page)
	defer free(page)
	display.settings_page = page
	memory := new(Font_Tables)
	defer free(memory)
	table := font_table_of(memory, &font.font)
	// The state before the first read: the other font, so that the first
	// read is a change.
	graphics.text_choice_set(.Vector, .Red_Green_Blue)
	Case :: struct {
		font: settings.Font,
		kind: Font_Kind,
	}
	cases := [?]Case{{.Spleen, .Cells_8x16}, {.Vector, .Interface}, {.Spleen, .Cells_8x16}}
	for each in cases {
		settings.write(page, settings.Choice{font = each.font, scale = scale_factor.DEFAULT}, 0, .Dark)
		testing.expectf(t, display.text_settings_apply(), "%v: the change of the font is told", each.font)
		testing.expectf(t, !display.text_settings_apply(), "%v: a read with no change tells a change", each.font)
		testing.expect_value(t, font_in_use(&table, FONT_INTERFACE, 5).kind, each.kind)
		testing.expect_value(t, graphics.text_state.cell_face, text_rendering.Face.Cells)
	}
	// A page left in a change: the defaults, the vector font.
	page.change_count += 1
	testing.expect(t, display.text_settings_apply(), "a page left in a change: the defaults are a change from spleen")
	testing.expect_value(t, graphics.text_state.font, graphics.Text_Font.Vector)
	testing.expect_value(t, font_in_use(&table, FONT_INTERFACE, 5).kind, Font_Kind.Interface)
	// The record of a text: in the font of the cells with spleen, in the
	// interface font with vector.
	for each in cases[:2] {
		page.change_count = 0
		settings.write(page, settings.Choice{font = each.font, scale = scale_factor.DEFAULT}, 0, .Dark)
		_ = display.text_settings_apply()
		memory^ = {}
		table = font_table_of(memory, &font.font)
		draw_text(&table, 8, 8, "To LT", graphics.colors.text, FONT_INTERFACE)
		testing.expectf(t, table.record_count == 1 && is_interface_text(table.records[0]) == (each.kind == .Interface), "%v: the record of the text is not in the font in use", each.font)
	}
}

// With Spleen, a text of the cells at a scale draws each character in the
// cell that its measure gives it on the screen: the measure is in logical
// pixels (text_width), and the Spleen advance of the screen size is not
// that advance times the scale (8 at 1.25 for a cell of 10). The ink of
// " H" stays in the cell of its second character, and the ink of "H " in
// the cell of its first, at each scale: with the advance of the screen
// size, the H of " H" started 2 pixels inside the first cell at 1.25.
@(test)
spleen_at_a_scale_draws_each_character_in_its_measured_cell :: proc(t: ^testing.T) {
	process_drawing_begin()
	saved_font, saved_order := graphics.text_state.font, graphics.text_state.order
	defer graphics.text_choice_set(saved_font, saved_order)
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)
	UNITS :: draw_record.UNITS_PER_PIXEL
	WIDTH :: 64
	HEIGHT :: 48
	LEFT :: 3
	TOP :: 1
	// The font of the cells at the body: the zero Font.
	body := Font{}
	advance := text_width(body, "H")
	testing.expect_value(t, advance, graphics.CELL_WIDTH)
	texts := [2]string{" H", "H "}
	for scale in scale_factor.Scale {
		for text, inked in texts {
			records: [4]Draw_Record
			characters: [8]u8
			copy(characters[:], text)
			table := Draw_Table{records = records[:], text = characters[:], text_count = len(text), scale = scale}
			width := text_width(body, text)
			fields := draw_record.Draw_Text{first = 0, count = u32(len(text)), color = 0xFFFFFFFF, origin_x = LEFT * UNITS, font = .Cells_8x16, weight = .Regular, size = u16(font_text_size(body))}
			table.records[0] = draw_record.record_of(fields, 0, LEFT * UNITS, TOP * UNITS, i32((LEFT + width) * UNITS), (TOP + 2 * graphics.CELL_WIDTH) * UNITS)
			table.record_count = 1
			pixels: [WIDTH * HEIGHT]graphics.Color
			execute(&table, {pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH})
			// The cell of the character with ink: the second one of " H",
			// the first one of "H ".
			cell := 1 - inked
			cell_left := scale_factor.screen_pixel_of_logical_pixel(i32(LEFT + cell * advance), scale)
			cell_right := scale_factor.screen_pixel_of_logical_pixel(i32(LEFT + (cell + 1) * advance), scale)
			ink, outside := 0, 0
			for y in 0 ..< HEIGHT {
				for x in 0 ..< WIDTH {
					if pixels[y * WIDTH + x] == 0 {
						continue
					}
					ink += 1
					if i64(x) < cell_left || i64(x) >= cell_right {
						outside += 1
					}
				}
			}
			testing.expectf(t, ink > 0, "%q at %d eighths drew no ink", text, u8(scale))
			testing.expectf(t, outside == 0, "%q at %d eighths: %d pixels of ink outside the cell %d..%d of its character", text, u8(scale), outside, cell_left, cell_right)
		}
	}
}
