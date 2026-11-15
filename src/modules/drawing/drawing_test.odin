#+build !freestanding
package drawing

import "modus:contract/errors"
import "modus:contract/glyph_cache"
import "core:log"
import "core:sync"
import "core:testing"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"
import "modus:support/vector_font"

// The text state of the graphics package and the text of the module are
// one for the test program, and the tests run on several threads: each
// test that draws holds this lock, so the proof of the same pixels changes
// the fonts with no other draw at that time.
@(private = "file")
draw_lock: sync.Mutex

@(private = "file")
records_to_read :: proc(table: ^interface.Draw_Table) -> system.Table_To_Read(interface.Draw_Record) {
	return {records = raw_data(table.records), count = u64(table.record_count), capacity = u64(len(table.records))}
}

@(private = "file")
text_to_read :: proc(table: ^interface.Draw_Table) -> system.Bytes_To_Read {
	return {bytes = raw_data(table.text), count = u64(table.text_count), capacity = u64(len(table.text))}
}

// A canvas whose stride times its height wraps, as a hostile caller gives
// it: the export refuses it with its error record, and draws nothing. So
// does a picture memory at an address that is not a multiple of 4.
@(test)
canvas_shape_that_wraps_is_refused :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	pixels: [16]u32
	records := [1]interface.Draw_Record{{kind = .Rectangle, x = 0, y = 0, width = 1, height = 4, first_color = 0xFFFFFF}}
	now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{}
	no_pictures := system.Bytes_To_Read{}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	refused: errors.Error_Record
	area := Canvas_Rectangle{width = 1, height = 4, stride = (1 << 62) + 1, right = 1, bottom = 4}
	testing.expect_value(t, execute_draw_table_9(&now, &text, &no_pictures, &bytes, &area, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Small))
	testing.expect_value(t, refused.argument, 4)
	area = {width = 1, height = 0, stride = 1, right = 1, bottom = 4}
	testing.expect_value(t, execute_draw_table_9(&now, &text, &no_pictures, &bytes, &area, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Value))
	testing.expect_value(t, refused.argument, 5)
	area = {width = 4, height = 4, stride = 1, right = 1, bottom = 4}
	testing.expect_value(t, execute_draw_table_9(&now, &text, &no_pictures, &bytes, &area, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Value))
	testing.expect(t, pixels == [16]u32{}, "a refused call draws nothing")
	// An address of the pixels that is not a multiple of 4.
	shifted := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0])[1:], count = 16, capacity = 16}
	area = {width = 1, height = 4, stride = 1, right = 1, bottom = 4}
	testing.expect_value(t, execute_draw_table_9(&now, &text, &no_pictures, &shifted, &area, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Address))
	testing.expect_value(t, refused.argument, 4)
	// An address of the picture memory that is not a multiple of 4.
	shifted_pictures := system.Bytes_To_Read{bytes = ([^]u8)(&pixels[0])[1:], count = 16, capacity = 16}
	area = {width = 1, height = 4, stride = 4, right = 1, bottom = 4}
	testing.expect_value(t, execute_draw_table_9(&now, &text, &shifted_pictures, &bytes, &area, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Bad_Address))
	testing.expect_value(t, refused.argument, 3)
	testing.expect(t, pixels == [16]u32{}, "a refused call draws nothing")
	// A good area, and no error record asked.
	testing.expect_value(t, execute_draw_table_9(&now, &text, &no_pictures, &bytes, &area, nil), 0)
	testing.expect_value(t, pixels[4], 0xFFFFFF)
}

// A text record that names bytes past the text table, and a count of
// records over the limit, as a hostile caller gives them: no fault; the
// record past the text differs, so its rectangle is damaged; the count is
// refused with its error record.
@(test)
hostile_records_are_refused :: proc(t: ^testing.T) {
	text_bytes := [4]u8{'a', 'b', 'c', 'd'}
	before_records := [1]interface.Draw_Record{{kind = .Text, x = 8, width = 8, height = 16, text_start = 2, text_count = 4}}
	now_records := [1]interface.Draw_Record{{kind = .Text, x = 8, width = 8, height = 16, text_start = 2, text_count = 4}}
	before := system.Table_To_Read(interface.Draw_Record){records = &before_records[0], count = 1, capacity = 1}
	now := system.Table_To_Read(interface.Draw_Record){records = &now_records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 4, capacity = 4}
	buffer: [8]Damage_Rectangle
	result := buffer[:]
	refused: errors.Error_Record
	testing.expect_value(t, damage_of_draw_table_9(&before, &text, &now, &text, &result, &refused), 1)
	testing.expect_value(t, buffer[0], Damage_Rectangle{8, 0, 16, 16})
	testing.expect_value(t, refused.kind, 0)
	// A buffer of no rectangle: the count of the full table, and no write.
	none := buffer[:0]
	buffer[0] = {}
	testing.expect_value(t, damage_of_draw_table_9(&before, &text, &now, &text, &none, &refused), 1)
	testing.expect_value(t, buffer[0], Damage_Rectangle{})
	now.count = 1 << 41
	testing.expect_value(t, damage_of_draw_table_9(&before, &text, &now, &text, &result, &refused), -1)
	testing.expect_value(t, refused.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, refused.argument, 3)
	now.count = 1
	long_text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 1 << 41, capacity = 4}
	testing.expect_value(t, damage_of_draw_table_9(&before, &long_text, &now, &text, &result, &refused), -1)
	testing.expect_value(t, refused.argument, 2)
}

// Interface_Text records of a hostile caller, through the exports: a range
// outside the text table, an origin of 3 thirds, an ink margin that would
// wrap, a scale of 0. Each draws nothing and makes no fault, and the first
// is damaged by the difference with an equal copy (a range outside its
// table is equal to no record). The good record draws.
@(test)
hostile_interface_text_records :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	text_bytes := [5]u8{'T', 'o', ' ', 'L', 'T'}
	text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 5, capacity = 5}
	good := interface.Draw_Record{kind = .Interface_Text, text_scale = 1, first_color = 0xFFFFFF, second_color = 2, width = 60, height = 16, text_count = 5}
	hostile := [?]interface.Draw_Record {
		{kind = .Interface_Text, text_scale = 1, first_color = 0xFFFFFF, second_color = 2, width = 60, height = 16, text_start = 3, text_count = 5},
		{kind = .Interface_Text, text_scale = 1, text_origin_thirds = 3, first_color = 0xFFFFFF, second_color = 2, width = 60, height = 16, text_count = 5},
		{kind = .Interface_Text, text_scale = 1, first_color = 0xFFFFFF, second_color = max(u32), width = 60, height = 16, text_count = 5},
		{kind = .Interface_Text, text_scale = 0, first_color = 0xFFFFFF, second_color = 2, width = 60, height = 16, text_count = 5},
	}
	pixels: [64 * 16]u32
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	area := Canvas_Rectangle{width = 64, height = 16, stride = 64, right = 64, bottom = 16}
	no_pictures := system.Bytes_To_Read{}
	for record, index in hostile {
		records := [1]interface.Draw_Record{record}
		now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 1, capacity = 1}
		pixels = {}
		testing.expect_value(t, execute_draw_table_9(&now, &text, &no_pictures, &bytes, &area, nil), 0)
		testing.expectf(t, pixels == [64 * 16]u32{}, "the hostile record %v draws", index)
		if index == 0 {
			buffer: [8]Damage_Rectangle
			result := buffer[:]
			testing.expect_value(t, damage_of_draw_table_9(&now, &text, &now, &text, &result, nil), 1)
		}
	}
	good_records := [1]interface.Draw_Record{good}
	good_table := system.Table_To_Read(interface.Draw_Record){records = &good_records[0], count = 1, capacity = 1}
	testing.expect_value(t, execute_draw_table_9(&good_table, &text, &no_pictures, &bytes, &area, nil), 0)
	testing.expect(t, pixels != [64 * 16]u32{}, "the good record draws")
}

// The fill of the area: with it, a rectangle with no record is the
// background; without it, the pixels stay. A Text_Grid record with no
// column and no cells draws nothing. A Picture record draws the pixels of
// the picture memory of the call, and nothing when it names a pixel past
// that memory or a picture memory other than 0, as a hostile caller can
// write it.
@(test)
fill_of_the_background_pictures_and_grids :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	pixels: [8 * 8]u32
	for &pixel in pixels {
		pixel = 0x123456
	}
	hostile := [3]interface.Draw_Record {
		{kind = .Picture, width = 8, height = 8, second_color = 8, text_start = 1},
		{kind = .Picture, kind_detail = 1, width = 8, height = 8, second_color = 8},
		{kind = .Picture, width = 8, height = 8, second_color = max(u32), text_start = max(u32)},
	}
	records := [4]interface.Draw_Record{hostile[0], hostile[1], hostile[2], {kind = .Text_Grid, width = 8, height = 8}}
	now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 4, capacity = 4}
	text := system.Bytes_To_Read{}
	picture_pixels: [8 * 8]u32
	for &pixel, index in picture_pixels {
		pixel = u32(index) + 1
	}
	picture_memory := system.Bytes_To_Read{bytes = ([^]u8)(&picture_pixels[0]), count = size_of(picture_pixels), capacity = size_of(picture_pixels)}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	area := Canvas_Rectangle{width = 8, height = 8, stride = 8, left = 2, top = 2, right = 6, bottom = 6}
	testing.expect_value(t, execute_draw_table_9(&now, &text, &picture_memory, &bytes, &area, nil), 0)
	for pixel in pixels {
		testing.expect_value(t, pixel, 0x123456)
	}
	area.fill_background, area.background = 1, 0xABCDEF
	testing.expect_value(t, execute_draw_table_9(&now, &text, &picture_memory, &bytes, &area, nil), 0)
	for pixel, index in pixels {
		x, y := index % 8, index / 8
		expected: u32 = 0x123456
		if x >= 2 && x < 6 && y >= 2 && y < 6 {
			expected = 0xABCDEF
		}
		testing.expect_value(t, pixel, expected)
	}
	// The good picture: the whole memory, in the rectangle of the area.
	records[0] = {kind = .Picture, width = 8, height = 8, second_color = 8, text_count = 1}
	testing.expect_value(t, execute_draw_table_9(&now, &text, &picture_memory, &bytes, &area, nil), 0)
	for pixel, index in pixels {
		x, y := index % 8, index / 8
		expected: u32 = 0x123456
		if x >= 2 && x < 6 && y >= 2 && y < 6 {
			expected = u32(index) + 1
		}
		testing.expect_value(t, pixel, expected)
	}
}

// The proof of the same pixels (docs/INTERFACE.md, section 7): the frames
// below are drawn two times, with the package as a window drew them before
// the module (the clear and the execution of a whole frame, then the
// difference and the draw of the damage), and through the two exports,
// with the argument forms of a caller. The damage rectangles are equal,
// and the two canvases are the same bytes after the whole frame and after
// the damage, in each font and each order of the stripes.

@(private = "file")
PROOF_WIDTH :: 400
@(private = "file")
PROOF_HEIGHT :: 240
// Three pixels more than the width: the pixels between two lines are not
// of the canvas, and no draw writes them.
@(private = "file")
PROOF_STRIDE :: PROOF_WIDTH + 3
@(private = "file")
PROOF_SEEDS :: 24
// The parts of a frame of build_proof_frame that a change can name.
@(private = "file")
PROOF_PARTS :: 35
@(private = "file")
GUARD_PIXEL :: 0xA5A5A5A5

// The picture memory of the frames of the proof: a pattern that differs at
// each pixel, so a picture at a wrong place or with a wrong stride shows.
@(private = "file")
PROOF_PICTURE_WIDTH :: 64
@(private = "file")
PROOF_PICTURE_HEIGHT :: 32
@(private = "file")
proof_picture_pixels: [PROOF_PICTURE_WIDTH * PROOF_PICTURE_HEIGHT]graphics.Color
@(private = "file")
proof_picture_memories: [1][]graphics.Color

@(private = "file")
Proof_Tables :: struct {
	records: [512]interface.Draw_Record,
	text:    [8192]u8,
}

// The generator of the tests: the same numbers on each host.
@(private = "file")
next_number :: proc(state: ^u32) -> int {
	state^ = state^ * 1664525 + 1013904223
	return int(state^ >> 8)
}

// pick gives the next number of the generator; for the part that changed,
// the number after it. The generator takes the same steps in both frames,
// so each other part is the same.
@(private = "file")
pick :: proc(state: ^u32, part: ^int, changed: int) -> int {
	number := next_number(state)
	if part^ == changed {
		number += 1
	}
	part^ += 1
	return number
}

// word and color give the next word and the next color of a frame.
@(private = "file")
word :: proc(list: []string, generator: ^u32, place: ^int, part_changed: int) -> string {
	return list[pick(generator, place, part_changed) % len(list)]
}

@(private = "file")
color :: proc(list: []graphics.Color, generator: ^u32, place: ^int, part_changed: int) -> graphics.Color {
	return list[pick(generator, place, part_changed) % len(list)]
}

// One frame with a record of each kind that the module draws: the
// elements of a window (a background with its grid of points, a card, a
// name with its value, a band, a cell, a bar, a large number), two
// pictures of one picture memory (the whole width of a part, and a part
// with a stride larger than its width), the two gradients, a folded gap, a
// line at an angle, an outline, a clip around two texts, the text of the
// cells at the three scales and in bold, and the text of the interface
// font at a third of a pixel, to the right, bold and at scale 2. The part
// `changed` differs from the frame with no change.
@(private = "file")
build_proof_frame :: proc(table: ^interface.Draw_Table, seed: u32, changed: int) {
	words := [?]string{"To", "LT", "Ty", "settings", "AVATAR", "Wave", "palette", "jj", "fill", "rings", "0O 1lI", "Monitor", "the clock", "W", "i", "{0}%e", "12:34:56"}
	colors := [?]graphics.Color{graphics.COLOR_TEXT, graphics.COLOR_DIM, graphics.COLOR_KERNEL, graphics.COLOR_PROGRAM, graphics.COLOR_MEMORY, graphics.COLOR_FAILED, graphics.COLOR_WHITE}
	state := seed
	part := 0
	interface.draw_table_clear(table)
	interface_state: interface.Interface_State
	input: interface.Input
	frame := interface.Frame{table = table, state = &interface_state, input = &input}
	interface.background(&frame, {0, 0, PROOF_WIDTH, PROOF_HEIGHT})
	memory := graphics.Canvas{pixels = raw_data(proof_picture_pixels[:]), width = PROOF_PICTURE_WIDTH, height = PROOF_PICTURE_HEIGHT, stride = PROOF_PICTURE_WIDTH}
	interface.draw_picture(table, 8, 214, graphics.view(memory, 0, 0, 40, 20), u32(pick(&state, &part, changed) % 3))
	interface.draw_picture(table, 52, 212, graphics.view(memory, pick(&state, &part, changed) % 16, pick(&state, &part, changed) % 8, 24, 20), 1)
	title := word(words[:], &state, &part, changed)
	caption := word(words[:], &state, &part, changed)
	content := interface.card(&frame, {8, 8, 236, 124}, title, caption, color(colors[:], &state, &part, changed))
	label := word(words[:], &state, &part, changed)
	value := word(words[:], &state, &part, changed)
	interface.label_value_line(&frame, {content.x, content.y, content.width, interface.TABLE_LINE}, label, value, color(colors[:], &state, &part, changed))
	interface.table_band(&frame, {content.x, content.y + 24, content.width, interface.TABLE_LINE}, pick(&state, &part, changed) % 2)
	cell := word(words[:], &state, &part, changed)
	interface.cell_text(&frame, {content.x, content.y + 24, content.width, interface.TABLE_LINE}, cell, color(colors[:], &state, &part, changed), pick(&state, &part, changed) % 2 == 0 ? .Left : .Right)
	interface.bar(&frame, {content.x, content.y + 56, content.width, 8}, u64(pick(&state, &part, changed) % 101), 100, color(colors[:], &state, &part, changed))
	interface.draw_vertical_gradient(table, 256, 8, 64, 40, color(colors[:], &state, &part, changed), graphics.COLOR_CARD_BOTTOM)
	interface.draw_horizontal_gradient(table, 256, 56, 136, 24, graphics.COLOR_TITLE, color(colors[:], &state, &part, changed))
	interface.draw_folded_gap(table, 328, 8, 40 + pick(&state, &part, changed) % 16, 16)
	interface.draw_line(table, 256 + pick(&state, &part, changed) % 100, 92, 384, 92 + pick(&state, &part, changed) % 36, 1 + pick(&state, &part, changed) % 4, color(colors[:], &state, &part, changed))
	interface.draw_outline(table, 250, 134, 144, 60, 2, color(colors[:], &state, &part, changed))
	// Two texts cut by a clip: the second passes the right edge of the clip.
	interface.draw_clip(table, 256, 138, 120, 52)
	medium := word(words[:], &state, &part, changed)
	interface.draw_text(table, 250 + pick(&state, &part, changed) % 30, 140, medium, color(colors[:], &state, &part, changed), interface.FONT_MEDIUM)
	bold := word(words[:], &state, &part, changed)
	interface.draw_text(table, 300, 174, bold, graphics.COLOR_TEXT, interface.FONT_BOLD)
	interface.draw_clip(table, 0, 0, 0, 0)
	large := word(words[:], &state, &part, changed)
	interface.draw_text(table, 8, 140, large[:min(len(large), 5)], color(colors[:], &state, &part, changed), interface.FONT_LARGE)
	// The interface font, when the table has it; else the font of the cells.
	first := word(words[:], &state, &part, changed)
	interface.draw_text(table, 8 + pick(&state, &part, changed) % 5, 196, first, color(colors[:], &state, &part, changed), {kind = .Interface})
	second := word(words[:], &state, &part, changed)
	interface.draw_text_right(table, 240, 196, second, graphics.COLOR_TEXT, {kind = .Interface, weight = .Bold})
	third := word(words[:], &state, &part, changed)
	interface.draw_text(table, 250, 204, third, color(colors[:], &state, &part, changed), {kind = .Interface, scale = 2})
}

// The glyph caches of the proof: the font of the cells (JetBrains Mono)
// and the two weights of the interface font (B612), built from the font
// files, in memory that the caller frees.
@(private = "file")
Proof_Fonts :: struct {
	cells:          glyph_cache.Cache,
	interface_font: display.Interface_Font,
	memory:         [3][]u64,
}

@(private = "file")
proof_fonts_build :: proc(t: ^testing.T) -> (fonts: Proof_Fonts) {
	render := new(vector_font.Render_Memory)
	defer free(render)
	{
		bytes := #load("../../../resources/fonts/jetbrains_mono.ttf")
		file, problem := vector_font.font_open(bytes)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		fonts.memory[0] = make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
		out := ([^]u8)(raw_data(fonts.memory[0]))[:vector_font.GLYPH_CACHE_LIMIT]
		size: int
		size, problem = vector_font.glyph_cache_build(&file, bytes, "jetbrains_mono", true, render, out)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		refused: glyph_cache.Problem
		fonts.cells, refused = glyph_cache.validate(out[:size])
		testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	}
	Weight :: struct {
		bytes:     []u8,
		name:      string,
		positions: []int,
	}
	regular_positions := [3]int{3, 1, 1}
	bold_positions := [1]int{3}
	weights := [2]Weight{{#load("../../../resources/fonts/b612.ttf"), "b612", regular_positions[:]}, {#load("../../../resources/fonts/b612_bold.ttf"), "b612_bold", bold_positions[:]}}
	for weight, index in weights {
		file, problem := vector_font.font_open(weight.bytes)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		fonts.memory[index + 1] = make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
		out := ([^]u8)(raw_data(fonts.memory[index + 1]))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
		size: int
		size, problem = vector_font.glyph_cache_build_proportional(&file, weight.bytes, weight.name, true, render, out, weight.positions)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		cache, refused := glyph_cache.validate(out[:size])
		testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
		if index == 0 {
			fonts.interface_font.regular = cache
		} else {
			fonts.interface_font.bold = cache
		}
	}
	return fonts
}

// One font state of a program: the setting of the font of the cells, the
// order of the stripes, and whether the program has the interface font.
@(private = "file")
Proof_Configuration :: struct {
	name:           string,
	font:           graphics.Text_Font,
	order:          graphics.Subpixel_Order,
	interface_font: bool,
}

// first_difference gives the index of the first pixel that differs, or -1.
@(private = "file")
first_difference :: proc(first, second: []u32) -> int {
	for pixel, index in first {
		if pixel != second[index] {
			return index
		}
	}
	return -1
}

// draw_through_the_exports draws rectangles of a table through the export,
// one call for each rectangle, with the fill of the background and the one
// picture memory of the table, as the window layer of the interface
// package calls it.
@(private = "file")
draw_through_the_exports :: proc(t: ^testing.T, table: ^interface.Draw_Table, pixels: []u32, rectangles: []Damage_Rectangle) {
	now, now_text := records_to_read(table), text_to_read(table)
	picture_memory: system.Bytes_To_Read
	if len(table.picture_memories) == 1 {
		size := u64(len(table.picture_memories[0]) * size_of(graphics.Color))
		picture_memory = {bytes = ([^]u8)(raw_data(table.picture_memories[0])), count = size, capacity = size}
	}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(raw_data(pixels)), count = u64(len(pixels) * size_of(u32)), capacity = u64(len(pixels) * size_of(u32))}
	for rectangle in rectangles {
		area := Canvas_Rectangle{width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE, fill_background = 1, background = i64(graphics.COLOR_BACKGROUND), left = rectangle.left, top = rectangle.top, right = rectangle.right, bottom = rectangle.bottom}
		refused: errors.Error_Record
		testing.expect_value(t, execute_draw_table_9(&now, &now_text, &picture_memory, &bytes, &area, &refused), 0)
		testing.expect_value(t, refused.kind, 0)
	}
}

@(test)
the_exports_draw_the_same_bytes_as_the_package :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	fonts := proof_fonts_build(t)
	// The fonts end before their memory: no later draw reads a freed cache.
	defer {
		program_text = {}
		graphics.text_state.has_cache = false
		graphics.text_state.has_bold_cache = false
		graphics.text_choice_set(.Vector, .Red_Green_Blue)
		for memory in fonts.memory {
			delete(memory)
		}
	}
	testing.expect_value(t, graphics.text_cache_use(fonts.cells).kind, glyph_cache.Problem_Kind.None)
	// The bold weight of the cells: the same cache serves, the proof is
	// about the path of the bold draw.
	testing.expect_value(t, graphics.text_bold_cache_use(fonts.cells).kind, glyph_cache.Problem_Kind.None)
	configurations := [?]Proof_Configuration {
		{"Spleen, no interface font", .Spleen, .Red_Green_Blue, false},
		{"the vector font, red green blue", .Vector, .Red_Green_Blue, false},
		{"the vector font, blue green red", .Vector, .Blue_Green_Red, false},
		{"the vector font, grayscale", .Vector, .None, false},
		{"the interface font, red green blue", .Vector, .Red_Green_Blue, true},
		{"the interface font, blue green red, over Spleen", .Spleen, .Blue_Green_Red, true},
		{"the interface font, grayscale", .Vector, .None, true},
	}
	before_memory := new(Proof_Tables)
	now_memory := new(Proof_Tables)
	defer free(before_memory)
	defer free(now_memory)
	package_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	export_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(package_pixels)
	defer delete(export_pixels)
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	for &pixel, index in proof_picture_pixels {
		pixel = graphics.Color(u32(index) * 0x010307 + 0x204060)
	}
	proof_picture_memories[0] = proof_picture_pixels[:]
	frames, damage_rectangles, text_records, picture_records := 0, 0, 0, 0
	for configuration in configurations {
		graphics.text_choice_set(configuration.font, configuration.order)
		// The module reads the interface font of the program in its own
		// data; the package reads it in the draw table.
		program_text = {loaded = true, interface_font = fonts.interface_font, interface_font_given = configuration.interface_font}
		font_of_tables: ^display.Interface_Font
		if configuration.interface_font {
			font_of_tables = &fonts.interface_font
		}
		for seed in 0 ..< u32(PROOF_SEEDS) {
			before := interface.Draw_Table{records = before_memory.records[:], text = before_memory.text[:], picture_memories = proof_picture_memories[:], interface_font = font_of_tables}
			now := interface.Draw_Table{records = now_memory.records[:], text = now_memory.text[:], picture_memories = proof_picture_memories[:], interface_font = font_of_tables}
			build_proof_frame(&before, seed * 7919 + 1, -1)
			build_proof_frame(&now, seed * 7919 + 1, int(seed) % PROOF_PARTS)
			if !testing.expectf(t, !before.full && !before.refused && !now.full && !now.refused, "%s, seed %v: a frame did not fit its tables", configuration.name, seed) {
				return
			}
			for record in now.records[:now.record_count] {
				text_records += int(interface.is_text_kind(record.kind))
				picture_records += int(record.kind == .Picture)
			}
			for &pixel, index in package_pixels {
				pixel = GUARD_PIXEL
				export_pixels[index] = GUARD_PIXEL
			}
			// The whole frame.
			graphics.clear(package_canvas, graphics.COLOR_BACKGROUND)
			interface.execute(&before, package_canvas)
			whole := [1]Damage_Rectangle{{0, 0, PROOF_WIDTH, PROOF_HEIGHT}}
			draw_through_the_exports(t, &before, export_pixels, whole[:])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%s, seed %v: the whole frame differs at x %v, y %v", configuration.name, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			// The damage: the rectangles, then the pixels.
			package_damage: interface.Damage
			interface.damage_by_difference(&before, &now, &package_damage)
			export_damage: [interface.DAMAGE_CAPACITY]Damage_Rectangle
			buffer := export_damage[:]
			before_records, before_text := records_to_read(&before), text_to_read(&before)
			now_records, now_text := records_to_read(&now), text_to_read(&now)
			refused: errors.Error_Record
			count := damage_of_draw_table_9(&before_records, &before_text, &now_records, &now_text, &buffer, &refused)
			if !testing.expect_value(t, count, i64(package_damage.count)) {
				return
			}
			for rectangle, index in package_damage.rectangles[:package_damage.count] {
				testing.expect_value(t, export_damage[index], Damage_Rectangle{i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)})
			}
			interface.draw_damage_on_surface(&now, package_canvas, package_damage.rectangles[:package_damage.count])
			draw_through_the_exports(t, &now, export_pixels, export_damage[:count])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%s, seed %v: the frame after the damage differs at x %v, y %v", configuration.name, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			// The pixels between two lines are of no canvas: nobody wrote them.
			for line in 0 ..< PROOF_HEIGHT {
				for column in PROOF_WIDTH ..< PROOF_STRIDE {
					testing.expect_value(t, export_pixels[line * PROOF_STRIDE + column], GUARD_PIXEL)
				}
			}
			// The damage was enough: the canvas is the canvas of a whole
			// frame of the table now.
			graphics.clear(package_canvas, graphics.COLOR_BACKGROUND)
			interface.execute(&now, package_canvas)
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%s, seed %v: the damage through the exports is not the whole frame at x %v, y %v", configuration.name, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			frames += 2
			damage_rectangles += int(count)
		}
	}
	// One frame must change something, and the frames must hold text: a
	// proof over empty frames proves nothing.
	testing.expect(t, damage_rectangles > 0, "no frame had damage")
	testing.expect(t, text_records > 0, "no frame had text")
	testing.expect(t, picture_records > 0, "no frame had a picture")
	log.infof("the exports and the package drew the same bytes: %v frames of %v x %v pixels in %v font states, %v damage rectangles, %v text records, %v picture records", frames, PROOF_WIDTH, PROOF_HEIGHT, len(configurations), damage_rectangles, text_records, picture_records)
}

// The proof of the same pixels for a text grid (src/md/api/text_grid.md):
// the frames of a terminal, with runs of one color, spaces in a run, empty
// cells at the end of a line, reverse cells, and a completion list of
// filled cells with its border drawn over the grid. The frame now changes
// some cells, and moves the cells in the text table with a status of
// another length. The package and the exports give the same damage
// rectangles and the same bytes of the canvas, in the font of the cells
// and in the vector font.

@(private = "file")
GRID_COLUMNS :: 40
@(private = "file")
GRID_ROWS :: 12

// The tables of a frame with a grid: the text table is words, so it starts
// at an address that is a multiple of 4, as the cells must.
@(private = "file")
Grid_Proof_Tables :: struct {
	records: [64]interface.Draw_Record,
	text:    [2048]u32,
}

@(private = "file")
grid_proof_table :: proc(memory: ^Grid_Proof_Tables) -> interface.Draw_Table {
	return {records = memory.records[:], text = ([^]u8)(&memory.text[0])[:len(memory.text) * 4]}
}

// grid_proof_cells fills the cells of a terminal from a seed.
@(private = "file")
grid_proof_cells :: proc(cells: []interface.Text_Grid_Cell, seed: u32) {
	state := seed
	colors := [?]graphics.Color{graphics.COLOR_TEXT, graphics.COLOR_DIM, graphics.COLOR_KERNEL, graphics.COLOR_PROGRAM, graphics.COLOR_WHITE}
	characters := "let x = 12; -- the line {0}%e Wave jj"
	for &cell, index in cells {
		row, column := index / GRID_COLUMNS, index % GRID_COLUMNS
		number := next_number(&state)
		cell = {character = characters[(column + row * 3 + number % 3) % len(characters)], color = colors[(column / 5 + row) % len(colors)]}
		if column >= 30 + row % 7 {
			cell.character = 0 // The end of a line.
		}
		if number % 29 == 0 {
			cell.reverse = true
		}
		if row >= 3 && row < 7 && column >= 10 && column < 26 {
			chosen := row == 4
			cell = {character = column < 20 ? characters[column % len(characters)] : 0, filled = true, color = chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT, background = chosen ? graphics.COLOR_CHOSEN : graphics.COLOR_CARD_TOP}
		}
	}
}

// build_grid_frame builds a frame of a terminal: a head with a status, the
// grid, and the border of the completion list after the grid.
@(private = "file")
build_grid_frame :: proc(table: ^interface.Draw_Table, cells: []interface.Text_Grid_Cell, status: string) {
	interface.draw_table_clear(table)
	interface.draw_rectangle(table, 0, 0, PROOF_WIDTH, 20, graphics.COLOR_CARD_TOP)
	interface.draw_text(table, 8, 2, status, graphics.COLOR_TEXT)
	interface.draw_text_grid(table, 8, 24, {cells = cells, columns = GRID_COLUMNS, rows = GRID_ROWS, stride = GRID_COLUMNS})
	interface.draw_outline(table, 8 + 10 * graphics.CELL_WIDTH - 1, 24 + 3 * graphics.CELL_HEIGHT - 1, 16 * graphics.CELL_WIDTH + 2, 4 * graphics.CELL_HEIGHT + 2, 1, graphics.COLOR_KERNEL)
}

@(test)
the_exports_draw_a_text_grid_as_the_package :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	fonts := proof_fonts_build(t)
	defer {
		program_text = {}
		graphics.text_state.has_cache = false
		graphics.text_state.has_bold_cache = false
		graphics.text_choice_set(.Vector, .Red_Green_Blue)
		for memory in fonts.memory {
			delete(memory)
		}
	}
	testing.expect_value(t, graphics.text_cache_use(fonts.cells).kind, glyph_cache.Problem_Kind.None)
	testing.expect_value(t, graphics.text_bold_cache_use(fonts.cells).kind, glyph_cache.Problem_Kind.None)
	fonts_of_the_cells := [2]graphics.Text_Font{.Spleen, .Vector}
	before_memory := new(Grid_Proof_Tables)
	now_memory := new(Grid_Proof_Tables)
	defer free(before_memory)
	defer free(now_memory)
	cells_before := make([]interface.Text_Grid_Cell, GRID_COLUMNS * GRID_ROWS)
	cells_now := make([]interface.Text_Grid_Cell, GRID_COLUMNS * GRID_ROWS)
	defer delete(cells_before)
	defer delete(cells_now)
	package_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	export_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(package_pixels)
	defer delete(export_pixels)
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	frames, damage_rectangles, grid_records := 0, 0, 0
	for font in fonts_of_the_cells {
		graphics.text_choice_set(font, .Red_Green_Blue)
		program_text = {loaded = true}
		for seed in 0 ..< u32(PROOF_SEEDS) {
			grid_proof_cells(cells_before, seed * 7919 + 1)
			copy(cells_now, cells_before)
			state := seed * 31 + 7
			for change in 0 ..< 1 + int(seed % 4) {
				index := next_number(&state) % len(cells_now)
				cells_now[index].character = u8('Q' + change)
				if seed % 5 == 0 {
					cells_now[index].reverse = !cells_now[index].reverse
				}
				if seed % 7 == 0 {
					cells_now[index].color = graphics.COLOR_FAILED
				}
			}
			before := grid_proof_table(before_memory)
			now := grid_proof_table(now_memory)
			build_grid_frame(&before, cells_before, "lines 1 to 12 of 40")
			// A status of 21 bytes in place of 19: the cells start at byte
			// 24 in place of byte 20 of the text table.
			build_grid_frame(&now, cells_now, seed % 2 == 0 ? "lines 1 to 12 of 40" : "held at lines 2 to 13")
			if !testing.expectf(t, !before.full && !before.refused && !now.full && !now.refused, "seed %v: a frame did not fit its tables", seed) {
				return
			}
			for record in now.records[:now.record_count] {
				grid_records += int(record.kind == .Text_Grid)
			}
			for &pixel, index in package_pixels {
				pixel = GUARD_PIXEL
				export_pixels[index] = GUARD_PIXEL
			}
			graphics.clear(package_canvas, graphics.COLOR_BACKGROUND)
			interface.execute(&before, package_canvas)
			whole := [1]Damage_Rectangle{{0, 0, PROOF_WIDTH, PROOF_HEIGHT}}
			draw_through_the_exports(t, &before, export_pixels, whole[:])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%v, seed %v: the whole grid differs at x %v, y %v", font, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			package_damage: interface.Damage
			interface.damage_by_difference(&before, &now, &package_damage)
			export_damage: [interface.DAMAGE_CAPACITY]Damage_Rectangle
			buffer := export_damage[:]
			before_records, before_text := records_to_read(&before), text_to_read(&before)
			now_records, now_text := records_to_read(&now), text_to_read(&now)
			refused: errors.Error_Record
			count := damage_of_draw_table_9(&before_records, &before_text, &now_records, &now_text, &buffer, &refused)
			if !testing.expect_value(t, count, i64(package_damage.count)) {
				return
			}
			for rectangle, index in package_damage.rectangles[:package_damage.count] {
				testing.expect_value(t, export_damage[index], Damage_Rectangle{i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)})
			}
			interface.draw_damage_on_surface(&now, package_canvas, package_damage.rectangles[:package_damage.count])
			draw_through_the_exports(t, &now, export_pixels, export_damage[:count])
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%v, seed %v: the grid after the damage differs at x %v, y %v", font, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			// The damage was enough: the canvas is the frame now drawn whole.
			graphics.clear(package_canvas, graphics.COLOR_BACKGROUND)
			interface.execute(&now, package_canvas)
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "%v, seed %v: the damage of the grid through the exports is not the whole frame at x %v, y %v", font, seed, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
			frames += 2
			damage_rectangles += int(count)
		}
	}
	testing.expect(t, damage_rectangles > 0, "no frame had damage")
	testing.expect(t, grid_records > 0, "no frame had a grid")
	log.infof("the exports and the package drew the same bytes for a text grid: %v frames of %v x %v cells in %v fonts of the cells, %v damage rectangles", frames, GRID_COLUMNS, GRID_ROWS, len(fonts_of_the_cells), damage_rectangles)
}

// The proof of the parts of a screen (src/md/api/picture.md, "The
// compositor: one call for each part"): windows that overlap, each with a
// frame, a title and a surface in a picture memory of its own, then a bar
// with a heron in one more memory, over a background picture. The package
// draws the whole table in each rectangle, with the list of all the
// memories, as the compositor did. The exports draw one part for each
// call, with the one memory of the part, as the compositor does now. The
// two canvases are the same bytes after each rectangle.

@(private = "file")
SURFACE_COUNT :: 4

// One part of the table of the screen: its records and its memory.
@(private = "file")
Screen_Proof_Part :: struct {
	first, count: int,
	memory:       []graphics.Color,
}

// build_screen_proof builds the table of a screen. in_parts: each Picture
// record names memory 0 of the list of its part, and parts gets the parts;
// else each record names its memory in the list of all the memories.
@(private = "file")
build_screen_proof :: proc(table: ^interface.Draw_Table, surfaces: []graphics.Canvas, memories: [][]graphics.Color, seed: int, in_parts: bool, parts: []Screen_Proof_Part) -> (part_count: int) {
	interface.draw_table_clear(table)
	one: [1][]graphics.Color
	for surface, index in surfaces {
		first := table.record_count
		x, y := 12 + index * 70 + seed % 13, 26 + index * 30 + seed % 7
		interface.draw_horizontal_gradient(table, x, y, surface.width + 4, 20, graphics.COLOR_TITLE, graphics.COLOR_CARD_TOP)
		interface.draw_rectangle(table, x, y + 20, 2, surface.height, graphics.COLOR_TITLE)
		interface.draw_rectangle(table, x + surface.width + 2, y + 20, 2, surface.height, graphics.COLOR_CARD_TOP)
		interface.draw_text(table, x + 4, y + 2, index % 2 == 0 ? "life" : "monitor", graphics.COLOR_WHITE)
		table.picture_memories = memories
		if in_parts {
			one[0] = memories[index]
			table.picture_memories = one[:]
		}
		interface.draw_picture(table, x + 2, y + 20, surface, 1)
		table.picture_memories = nil
		if in_parts {
			parts[part_count] = {first = first, count = table.record_count - first, memory = memories[index]}
			part_count += 1
		}
	}
	first := table.record_count
	interface.draw_vertical_gradient(table, 0, 0, PROOF_WIDTH, 23, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	interface.draw_rectangle(table, 0, 23, PROOF_WIDTH, 1, graphics.COLOR_TRACK)
	heron := memories[len(memories) - 1]
	table.picture_memories = memories
	if in_parts {
		one[0] = heron
		table.picture_memories = one[:]
	}
	interface.draw_picture(table, 4, 4, {pixels = raw_data(heron), width = 16, height = 16, stride = 16}, 1)
	table.picture_memories = nil
	interface.draw_text(table, PROOF_WIDTH - 72, 4, "12:34:56", graphics.COLOR_TEXT)
	if in_parts {
		parts[part_count] = {first = first, count = table.record_count - first, memory = heron}
		part_count += 1
	}
	return part_count
}

@(test)
the_parts_of_a_screen_draw_the_same_bytes_as_the_package :: proc(t: ^testing.T) {
	sync.mutex_lock(&draw_lock)
	defer sync.mutex_unlock(&draw_lock)
	defer {
		program_text = {}
		graphics.text_choice_set(.Vector, .Red_Green_Blue)
	}
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)
	program_text = {loaded = true}
	// Each surface in an allocation of its own, with a stride larger than
	// its width; the heron is the last memory.
	sizes := [SURFACE_COUNT][2]int{{64, 40}, {96, 56}, {48, 48}, {120, 32}}
	surfaces: [SURFACE_COUNT]graphics.Canvas
	memories: [SURFACE_COUNT + 1][]graphics.Color
	for size, index in sizes {
		stride := size[0] + 5
		memories[index] = make([]graphics.Color, stride * size[1])
		for &pixel, place in memories[index] {
			pixel = graphics.Color(u32(place) * 0x010307 + u32(index) * 0x305070)
		}
		surfaces[index] = {pixels = raw_data(memories[index]), width = size[0], height = size[1], stride = stride}
	}
	memories[SURFACE_COUNT] = make([]graphics.Color, 16 * 16)
	for &pixel, place in memories[SURFACE_COUNT] {
		pixel = graphics.Color(u32(place) * 0x0A0B0C)
	}
	defer {
		for memory in memories {
			delete(memory)
		}
	}
	background_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(background_pixels)
	for &pixel, place in background_pixels {
		pixel = u32(place % 24 < 2 ? graphics.COLOR_POINT : graphics.COLOR_BACKGROUND)
	}
	background := graphics.Canvas{pixels = raw_data(background_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	package_memory := new(Proof_Tables)
	parts_memory := new(Proof_Tables)
	defer free(package_memory)
	defer free(parts_memory)
	package_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	export_pixels := make([]u32, PROOF_STRIDE * PROOF_HEIGHT)
	defer delete(package_pixels)
	defer delete(export_pixels)
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	export_canvas := graphics.Canvas{pixels = raw_data(export_pixels), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(raw_data(export_pixels)), count = u64(len(export_pixels) * size_of(u32)), capacity = u64(len(export_pixels) * size_of(u32))}
	// The whole screen, a rectangle over three windows, a rectangle of the
	// bar, and slivers that cut a picture and a text.
	rectangles := [?]Damage_Rectangle{{0, 0, PROOF_WIDTH, PROOF_HEIGHT}, {50, 40, 170, 120}, {0, 0, 40, 30}, {130, 10, 260, 200}, {97, 0, 99, PROOF_HEIGHT}, {0, 61, PROOF_WIDTH, 64}}
	parts: [SURFACE_COUNT + 1]Screen_Proof_Part
	calls, picture_records := 0, 0
	for seed in 0 ..< PROOF_SEEDS {
		package_table := interface.Draw_Table{records = package_memory.records[:], text = package_memory.text[:]}
		parts_table := interface.Draw_Table{records = parts_memory.records[:], text = parts_memory.text[:]}
		_ = build_screen_proof(&package_table, surfaces[:], memories[:], seed, false, nil)
		part_count := build_screen_proof(&parts_table, surfaces[:], memories[:], seed, true, parts[:])
		if !testing.expectf(t, !package_table.refused && !parts_table.refused && !package_table.full && !parts_table.full, "seed %v: a screen did not fit its tables", seed) {
			return
		}
		testing.expect_value(t, part_count, SURFACE_COUNT + 1)
		for record in parts_table.records[:parts_table.record_count] {
			if record.kind == .Picture {
				picture_records += 1
				testing.expect_value(t, record.kind_detail, 0)
			}
		}
		package_table.picture_memories = memories[:]
		for &pixel, index in package_pixels {
			pixel = GUARD_PIXEL
			export_pixels[index] = GUARD_PIXEL
		}
		for rectangle in rectangles {
			area := interface.Rectangle{int(rectangle.left), int(rectangle.top), int(rectangle.right), int(rectangle.bottom)}
			width, height := area.right - area.left, area.bottom - area.top
			graphics.copy(graphics.view(package_canvas, area.left, area.top, width, height), -area.left, -area.top, background)
			interface.execute_in_rectangle(&package_table, package_canvas, area)
			graphics.copy(graphics.view(export_canvas, area.left, area.top, width, height), -area.left, -area.top, background)
			now_text := text_to_read(&parts_table)
			for part in parts[:part_count] {
				records := system.Table_To_Read(interface.Draw_Record){records = &parts_table.records[part.first], count = u64(part.count), capacity = u64(part.count)}
				memory_size := u64(len(part.memory) * size_of(graphics.Color))
				picture_memory := system.Bytes_To_Read{bytes = ([^]u8)(raw_data(part.memory)), count = memory_size, capacity = memory_size}
				shape := Canvas_Rectangle{width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_STRIDE, left = rectangle.left, top = rectangle.top, right = rectangle.right, bottom = rectangle.bottom}
				refused: errors.Error_Record
				testing.expect_value(t, execute_draw_table_9(&records, &now_text, &picture_memory, &bytes, &shape, &refused), 0)
				testing.expect_value(t, refused.kind, 0)
				calls += 1
			}
			if place := first_difference(package_pixels, export_pixels); !testing.expectf(t, place < 0, "seed %v, the rectangle %v: the parts differ from the package at x %v, y %v", seed, rectangle, place % PROOF_STRIDE, place / PROOF_STRIDE) {
				return
			}
		}
		for line in 0 ..< PROOF_HEIGHT {
			for column in PROOF_WIDTH ..< PROOF_STRIDE {
				testing.expect_value(t, export_pixels[line * PROOF_STRIDE + column], GUARD_PIXEL)
			}
		}
	}
	testing.expect(t, picture_records > 0, "no screen had a picture")
	log.infof("the parts of a screen drew the same bytes as the package: %v screens of %v surfaces and a heron, %v calls of the export", PROOF_SEEDS, SURFACE_COUNT, calls)
}
