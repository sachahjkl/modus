#+build !freestanding
package interface

import "core:slice"
import "core:sync"
import "core:testing"
import "modus:contract/draw_record"
import "modus:support/graphics"

// The colors with alpha of the draw records (docs/INTERFACE.md, "2.1 Draw
// record"): an opaque record draws the pixels of the drawing before alpha,
// a translucent record blends by the one rule in each cut, and a color that
// draws nothing has one form.

// The execution blends with the table of the text state, which a program
// fills once at its start: the tests of this program fill it once, before
// the first test that blends reads it, and no test writes it again. Each
// test file of the package that blends takes the table here: one fill.
blend_table_once: sync.Once

blend_table :: proc() -> ^[4096]u8 {
	sync.once_do(&blend_table_once, proc() {
		graphics.text_state_start()
	})
	return &graphics.text_state.square_root
}

@(private = "file")
ALPHA_WIDTH :: 70

@(private = "file")
ALPHA_HEIGHT :: 44

@(private = "file")
Alpha_Tables :: struct {
	records: [64]Draw_Record,
	text:    [256]u8,
}

@(private = "file")
alpha_table_of :: proc(memory: ^Alpha_Tables) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:]}
}

@(private = "file")
alpha_canvas_of :: proc(pixels: []graphics.Color) -> graphics.Canvas {
	return {pixels = raw_data(pixels), width = ALPHA_WIDTH, height = ALPHA_HEIGHT, stride = ALPHA_WIDTH}
}

// A background of many values, so a blend over it meets each channel.
@(private = "file")
alpha_background :: proc(pixels: []graphics.Color) {
	for &pixel, index in pixels {
		pixel = u32(index) * 0x9E3779B1 & 0x00FFFFFF
	}
}

// The rectangles of a damage that cut the canvas into parts, across each
// record of the tests.
@(private = "file")
ALPHA_PARTS :: [5]Rectangle{{0, 0, 9, ALPHA_HEIGHT}, {9, 0, 40, 13}, {9, 13, 40, ALPHA_HEIGHT}, {40, 0, 41, ALPHA_HEIGHT}, {41, 0, ALPHA_WIDTH, ALPHA_HEIGHT}}

// pattern_reference paints the cells of the grid of points in a box, cut to
// the canvas, pixel by pixel from the definition of the pattern: a cell of
// POINT_SIZE at POINT_STEP / 2 + n * POINT_STEP of the surface.
@(private = "file")
pattern_reference :: proc(canvas: graphics.Canvas, box: Rectangle, color: graphics.Color) {
	for y in max(box.top, 0) ..< min(box.bottom, canvas.height) {
		for x in max(box.left, 0) ..< min(box.right, canvas.width) {
			in_x := ((x - graphics.POINT_STEP / 2) % graphics.POINT_STEP + graphics.POINT_STEP) % graphics.POINT_STEP < graphics.POINT_SIZE
			in_y := ((y - graphics.POINT_STEP / 2) % graphics.POINT_STEP + graphics.POINT_STEP) % graphics.POINT_STEP < graphics.POINT_SIZE
			if in_x && in_y {
				canvas.pixels[y * canvas.stride + x] = color
			}
		}
	}
}

// Each record with opaque colors draws the pixels that the drawing before
// alpha gave: a rectangle is fill, a vertical gradient a fill of the mix of
// each line, a horizontal gradient the mix of each column, the grid of
// points its cells, a line the squares of graphics.line. Each record is
// partly outside the canvas, and each reference is cut to the canvas. The
// frame is drawn whole and in the parts of a damage.
@(test)
opaque_records_keep_their_pixels :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Alpha_Tables)
	defer free(memory)
	table := alpha_table_of(memory)
	draw_rectangle(&table, -5, -3, 20, 12, 0x00ABCDEF)
	draw_vertical_gradient(&table, 50, 30, 40, 30, 0x00102030, 0x00F0E0D0)
	draw_horizontal_gradient(&table, -10, 14, 75, 9, 0x00FF0000, 0x000000FF)
	draw_point_grid(&table, 2, 24, 80, 30)
	draw_line(&table, 3, 40, 66, 2, 3, 0x0000FF80)
	drawn := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	parts := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	expected := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	defer delete(drawn)
	defer delete(parts)
	defer delete(expected)
	alpha_background(drawn)
	alpha_background(parts)
	alpha_background(expected)
	execute(&table, alpha_canvas_of(drawn))
	rectangles := ALPHA_PARTS
	execute_in_rectangles(&table, alpha_canvas_of(parts), rectangles[:])
	canvas := alpha_canvas_of(expected)
	graphics.fill(canvas, -5, -3, 20, 12, 0x00ABCDEF)
	for row in 0 ..< 30 {
		graphics.fill(canvas, 50, 30 + row, 40, 1, graphics.mix(0x00102030, 0x00F0E0D0, u32(row * 255 / 29)))
	}
	// A gradient across is the mix of its column, at the level of the 1/255
	// steps, as a gradient down mixes its line.
	columns: [75]graphics.Color
	for &color, column in columns {
		color = graphics.mix(0x00FF0000, 0x000000FF, u32(column * 255 / (len(columns) - 1)))
	}
	for row in 14 ..< 23 {
		for column in 0 ..< len(columns) {
			x := column - 10
			if x >= 0 && x < ALPHA_WIDTH {
				expected[row * ALPHA_WIDTH + x] = columns[column]
			}
		}
	}
	pattern_reference(canvas, {2, 24, 82, 54}, graphics.colors.point)
	start_x, start_y, end_x, end_y := line_ends_in_order(3, 40, 66, 2)
	graphics.line(canvas, start_x, start_y, end_x, end_y, 3, 0x0000FF80)
	testing.expect(t, slice.equal(drawn, expected), "the opaque records draw other pixels than before alpha")
	testing.expect(t, slice.equal(parts, expected), "the opaque records in parts draw other pixels than before alpha")
}

// Records with alpha over the background and over an opaque rectangle: a
// translucent rectangle, a pattern, a fade of a gradient on each axis to
// its color with alpha 0, and a picture with alpha. The frame drawn whole,
// drawn in the parts of a damage, and the blends of graphics in the order
// of the records give the same pixels.
@(test)
translucent_records_blend_by_the_rule_in_each_cut :: proc(t: ^testing.T) {
	square_root := blend_table()
	memory := new(Alpha_Tables)
	defer free(memory)
	alpha_picture: [6 * 5]graphics.Color
	for &pixel, index in alpha_picture {
		alphas := [5]u32{0, 1, 128, 254, 255}
		pixel = alphas[index % len(alphas)] << 24 | u32(index) * 0x00071F3B & 0x00FFFFFF
	}
	pictures := [1][]graphics.Color{alpha_picture[:]}
	table := alpha_table_of(memory)
	table.picture_memories = pictures[:]
	PANEL :: 0x00204060
	SHADOW :: 0x00000000
	draw_rectangle(&table, 10, 5, 40, 30, PANEL)
	draw_rectangle_with_alpha(&table, 4, 2, 50, 20, draw_record.with_alpha(SHADOW, 96))
	draw_vertical_gradient_with_alpha(&table, 30, -4, 30, 40, draw_record.opaque(0x00FF8000), draw_record.Draw_Color(0x00FF8000))
	draw_horizontal_gradient_with_alpha(&table, -6, 30, 80, 10, draw_record.Draw_Color(0x0000FF00), draw_record.with_alpha(0x0000FF00, 200))
	record_append(&table, placed_record(draw_record.Draw_Rectangle{color = draw_record.with_alpha(0x00FFFFFF, 50), repetition = POINT_GRID_PATTERN}, 0, 0, 0, ALPHA_WIDTH, ALPHA_HEIGHT))
	draw_picture_with_alpha(&table, 60, 38, {pixels = raw_data(alpha_picture[:]), width = 6, height = 5, stride = 6}, 1)
	testing.expect_value(t, table.record_count, 6)
	for record in table.records[:table.record_count] {
		testing.expectf(t, record_view(record).read, "the border refuses the record %v", record_view(record).kind)
	}
	testing.expect_value(t, record_view(table.records[5]).format, Picture_Format.Straight_Alpha)
	drawn := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	parts := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	expected := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	defer delete(drawn)
	defer delete(parts)
	defer delete(expected)
	alpha_background(drawn)
	alpha_background(parts)
	alpha_background(expected)
	execute(&table, alpha_canvas_of(drawn))
	rectangles := ALPHA_PARTS
	execute_in_rectangles(&table, alpha_canvas_of(parts), rectangles[:])
	canvas := alpha_canvas_of(expected)
	graphics.fill(canvas, 10, 5, 40, 30, PANEL)
	graphics.blend_fill(canvas, 4, 2, 50, 20, 96 << 24 | SHADOW, square_root)
	for row in 0 ..< 40 {
		graphics.blend_fill(canvas, 30, -4 + row, 30, 1, graphics.mix_with_alpha(0xFFFF8000, 0x00FF8000, u32(row * 255 / 39)), square_root)
	}
	columns: [80]u32
	for &color, column in columns {
		color = graphics.mix_with_alpha(0x0000FF00, 0xC800FF00, u32(column * 255 / (len(columns) - 1)))
	}
	graphics.blend_copy(canvas, -6, 30, {pixels = raw_data(columns[:]), width = len(columns), height = 10, stride = 0}, square_root)
	for y in 0 ..< ALPHA_HEIGHT {
		for x in 0 ..< ALPHA_WIDTH {
			in_x := ((x - graphics.POINT_STEP / 2) % graphics.POINT_STEP + graphics.POINT_STEP) % graphics.POINT_STEP < graphics.POINT_SIZE
			in_y := ((y - graphics.POINT_STEP / 2) % graphics.POINT_STEP + graphics.POINT_STEP) % graphics.POINT_STEP < graphics.POINT_SIZE
			if in_x && in_y {
				graphics.blend_fill(canvas, x, y, 1, 1, 50 << 24 | 0x00FFFFFF, square_root)
			}
		}
	}
	graphics.blend_copy(canvas, 60, 38, {pixels = raw_data(alpha_picture[:]), width = 6, height = 5, stride = 6}, square_root)
	testing.expect(t, slice.equal(drawn, expected), "the translucent records draw other pixels than the blends")
	testing.expect(t, slice.equal(parts, expected), "the translucent records in parts draw other pixels than the blends")
	// The shadow over the panel is darker than the panel, and lighter than
	// black: it blends, it does not cover.
	under := expected[10 * ALPHA_WIDTH + 12]
	testing.expect(t, under != PANEL && under != SHADOW, "the shadow covers the panel or leaves it")
}

// A translucent rectangle that moves: the damage of the two frames, painted
// with the background and drawn again, gives the pixels of the new frame
// drawn whole. The blend reads the background that each cut paints first.
@(test)
a_translucent_rectangle_that_moves_damages_its_two_boxes :: proc(t: ^testing.T) {
	_ = blend_table()
	before_memory := new(Alpha_Tables)
	now_memory := new(Alpha_Tables)
	defer free(before_memory)
	defer free(now_memory)
	before := alpha_table_of(before_memory)
	now := alpha_table_of(now_memory)
	draw_rectangle(&before, 0, 0, ALPHA_WIDTH, 10, 0x00808080)
	draw_rectangle(&now, 0, 0, ALPHA_WIDTH, 10, 0x00808080)
	draw_rectangle_with_alpha(&before, 5, 4, 20, 20, draw_record.with_alpha(0x00FF0000, 128))
	draw_rectangle_with_alpha(&now, 30, 6, 20, 20, draw_record.with_alpha(0x00FF0000, 128))
	surface := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	whole := make([]graphics.Color, ALPHA_WIDTH * ALPHA_HEIGHT)
	defer delete(surface)
	defer delete(whole)
	graphics.clear(alpha_canvas_of(surface), graphics.colors.background)
	execute(&before, alpha_canvas_of(surface))
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect(t, damage.count > 0, "the move damages nothing")
	draw_damage_on_surface(&now, alpha_canvas_of(surface), damage.rectangles[:damage.count])
	graphics.clear(alpha_canvas_of(whole), graphics.colors.background)
	execute(&now, alpha_canvas_of(whole))
	testing.expect(t, slice.equal(surface, whole), "the frame drawn in its damage differs from the frame drawn whole")
}

// A color with alpha 0 draws nothing whatever its channels: the writers
// give it its one form, so two frames that draw the same pixels have the
// same bytes and damage nothing, and the border refuses a record written by
// hand in another form. The channels of one end of a gradient with alpha 0
// color the mix, so they stay.
@(test)
a_color_that_draws_nothing_has_one_form :: proc(t: ^testing.T) {
	before_memory := new(Alpha_Tables)
	now_memory := new(Alpha_Tables)
	defer free(before_memory)
	defer free(now_memory)
	before := alpha_table_of(before_memory)
	now := alpha_table_of(now_memory)
	draw_rectangle_with_alpha(&before, 1, 1, 8, 8, draw_record.Draw_Color(0x00FF0000))
	draw_rectangle_with_alpha(&now, 1, 1, 8, 8, draw_record.with_alpha(0x000000FF, 0))
	draw_vertical_gradient_with_alpha(&before, 1, 10, 8, 8, draw_record.Draw_Color(0x00123456), draw_record.Draw_Color(0x00654321))
	draw_vertical_gradient_with_alpha(&now, 1, 10, 8, 8, 0, 0)
	draw_horizontal_gradient_with_alpha(&before, 1, 20, 8, 8, draw_record.Draw_Color(0x00FFFFFF), draw_record.Draw_Color(1))
	draw_horizontal_gradient_with_alpha(&now, 1, 20, 8, 8, 0, 0)
	testing.expect_value(t, before.record_count, 3)
	for index in 0 ..< before.record_count {
		testing.expectf(t, before.records[index] == now.records[index], "the record %d: two colors that draw nothing have other bytes", index)
		testing.expectf(t, record_view(before.records[index]).read, "the record %d: the border refuses the record of the writer", index)
		testing.expectf(t, records_equal(&before, before.records[index], &now, now.records[index]), "the record %d: the difference finds a change", index)
	}
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	// Written by hand in another form, the border refuses it.
	by_hand := draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.Draw_Color(0x00FF0000)}, 0, 0, 0, draw_record.units_of_pixels(8), draw_record.units_of_pixels(8))
	testing.expect(t, !record_view(by_hand).read, "the border reads a color of alpha 0 that is not 0")
	// A fade keeps the channels of its end of alpha 0.
	fade_memory := new(Alpha_Tables)
	defer free(fade_memory)
	fade := alpha_table_of(fade_memory)
	draw_vertical_gradient_with_alpha(&fade, 1, 1, 8, 8, draw_record.opaque(0x00FF8000), draw_record.Draw_Color(0x00FF8000))
	view := record_view(fade.records[0])
	testing.expect(t, view.read && view.second_color == 0x00FF8000 && view.second_alpha == 0 && view.alpha == draw_record.OPAQUE_ALPHA, "the fade lost the channels of its end of alpha 0")
}
