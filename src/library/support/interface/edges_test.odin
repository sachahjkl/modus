#+build !freestanding
package interface

import "core:slice"
import "core:testing"
import "modus:contract/draw_record"
import "modus:support/graphics"

// The edges inside a pixel and the gradient along any line
// (docs/INTERFACE.md, "2.1 Draw record"): each record is drawn whole and
// in the parts of a damage, and compared pixel by pixel with a reference
// that blends each pixel of the canvas alone, from the definitions: the
// part of the pixel inside the box, the level of its center on the line.

@(private = "file")
EDGES_WIDTH :: 61

@(private = "file")
EDGES_HEIGHT :: 37

// The rectangles of a damage that cut the canvas into parts.
@(private = "file")
EDGES_PARTS :: [4]Rectangle{{0, 0, 7, EDGES_HEIGHT}, {7, 0, 30, 11}, {7, 11, 30, EDGES_HEIGHT}, {30, 0, EDGES_WIDTH, EDGES_HEIGHT}}

@(private = "file")
Edges_Tables :: struct {
	records: [32]Draw_Record,
	text:    [64]u8,
}

@(private = "file")
edges_canvas_of :: proc(pixels: []graphics.Color) -> graphics.Canvas {
	return {pixels = raw_data(pixels), width = EDGES_WIDTH, height = EDGES_HEIGHT, stride = EDGES_WIDTH}
}

@(private = "file")
edges_background :: proc(pixels: []graphics.Color) {
	for &pixel, index in pixels {
		pixel = u32(index) * 0x2545F491 & 0x00FFFFFF
	}
}

// covered_units gives the units of the pixel `pixel` of one axis inside the
// edges start and end of a box, from 0 to UNITS_PER_PIXEL.
@(private = "file")
covered_units :: proc(start, end: i32, pixel: int) -> int {
	return max(0, min(int(end), (pixel + 1) * draw_record.UNITS_PER_PIXEL) - max(int(start), pixel * draw_record.UNITS_PER_PIXEL))
}

// pixel_reference blends one pixel of the canvas with a color whose alpha
// the part of the pixel inside a box scales: (alpha * x * y + 2048) >> 12.
@(private = "file")
pixel_reference :: proc(canvas: graphics.Canvas, record: Draw_Record, x, y: int, color: u32, square_root: ^[4096]u8) {
	covered_x := covered_units(record.left, record.right, x)
	covered_y := covered_units(record.top, record.bottom, y)
	alpha := ((color >> 24) * u32(covered_x) * u32(covered_y) + 2048) >> 12
	if alpha != 0 {
		graphics.blend_fill(canvas, x, y, 1, 1, alpha << 24 | color & 0x00FFFFFF, square_root)
	}
}

// records_reference draws the records of a table pixel by pixel, in order,
// each pixel cut to the canvas: a Rectangle with no pattern by its color,
// a Gradient by the mix at the level of the center of each pixel.
@(private = "file")
records_reference :: proc(canvas: graphics.Canvas, table: ^Draw_Table, square_root: ^[4096]u8) {
	HALF :: draw_record.UNITS_PER_PIXEL / 2
	for record in table.records[:table.record_count] {
		primitive, problem := draw_record.read(record)
		if problem != .None {
			continue
		}
		for y in 0 ..< canvas.height {
			for x in 0 ..< canvas.width {
				switch fields in primitive {
				case draw_record.Draw_Rectangle:
					pixel_reference(canvas, record, x, y, u32(fields.color), square_root)
				case draw_record.Draw_Gradient:
					level := draw_record.gradient_level(fields, i64(x) * draw_record.UNITS_PER_PIXEL + HALF, i64(y) * draw_record.UNITS_PER_PIXEL + HALF)
					pixel_reference(canvas, record, x, y, graphics.mix_with_alpha(u32(fields.start_color), u32(fields.end_color), level), square_root)
				case draw_record.Draw_Nothing, draw_record.Draw_Clip, draw_record.Draw_Text, draw_record.Draw_Picture, draw_record.Draw_Text_Grid, draw_record.Draw_Line:
					// The tests of this file draw rectangles and gradients only.
				}
			}
		}
	}
}

// draws_as_the_reference draws a table whole and in the parts of a damage
// over one background, and says if each gives the pixels of the reference.
@(private = "file")
draws_as_the_reference :: proc(table: ^Draw_Table) -> (whole_equal, parts_equal: bool) {
	square_root := blend_table()
	drawn := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	parts := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	expected := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	defer delete(drawn)
	defer delete(parts)
	defer delete(expected)
	edges_background(drawn)
	edges_background(parts)
	edges_background(expected)
	execute(table, edges_canvas_of(drawn))
	rectangles := EDGES_PARTS
	execute_in_rectangles(table, edges_canvas_of(parts), rectangles[:])
	records_reference(edges_canvas_of(expected), table, square_root)
	return slice.equal(drawn, expected), slice.equal(parts, expected)
}

// Rectangles in boxes inside the pixels: edges one unit and a third past a
// pixel, a box inside one pixel, a box thinner than a pixel across several,
// a box at a negative place and one past the canvas, in an opaque and a
// translucent color. Each gives the pixels of the reference whole and in
// parts; a box on whole pixels gives the pixels of a fill.
@(test)
rectangles_inside_the_pixels_draw_their_coverage :: proc(t: ^testing.T) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	Box :: struct {
		left, top, right, bottom: i32,
	}
	boxes := [?]Box {
		{3 * UNITS + 1, 2 * UNITS + 21, 20 * UNITS - 1, 9 * UNITS + 43},
		{30 * UNITS + 10, 4 * UNITS + 10, 30 * UNITS + 50, 4 * UNITS + 30},
		{5 * UNITS + 40, 20 * UNITS + 2, 40 * UNITS + 60, 20 * UNITS + 9},
		{-3 * UNITS - 17, -2 * UNITS - 5, 4 * UNITS + 33, 3 * UNITS + 1},
		{55 * UNITS + 3, 30 * UNITS + 63, 70 * UNITS + 5, 40 * UNITS + 1},
		{10 * UNITS, 25 * UNITS, 22 * UNITS, 31 * UNITS},
	}
	colors := [2]Draw_Color{draw_record.opaque(0x00C08040), draw_record.with_alpha(0x0020A0F0, 140)}
	for color in colors {
		memory := new(Edges_Tables)
		table := Draw_Table{records = memory.records[:], text = memory.text[:]}
		for box in boxes {
			draw_rectangle_in_units(&table, box.left, box.top, box.right, box.bottom, color)
		}
		testing.expect_value(t, table.record_count, len(boxes))
		testing.expect(t, !table.refused, "a box of the test is refused")
		whole, parts := draws_as_the_reference(&table)
		testing.expectf(t, whole, "the rectangles in %08x draw other pixels than the reference", u32(color))
		testing.expectf(t, parts, "the rectangles in %08x in parts draw other pixels than the reference", u32(color))
		free(memory)
	}
	// On whole pixels and opaque: the pixels of fill.
	memory := new(Edges_Tables)
	defer free(memory)
	table := Draw_Table{records = memory.records[:], text = memory.text[:]}
	draw_rectangle_in_units(&table, 2 * UNITS, 3 * UNITS, 40 * UNITS, 30 * UNITS, draw_record.opaque(0x00123456))
	drawn := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	expected := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	defer delete(drawn)
	defer delete(expected)
	edges_background(drawn)
	edges_background(expected)
	execute(&table, edges_canvas_of(drawn))
	graphics.fill(edges_canvas_of(expected), 2, 3, 38, 27, 0x00123456)
	testing.expect(t, slice.equal(drawn, expected), "a rectangle on whole pixels draws other pixels than fill")
}

// Gradients along a line, in boxes on whole pixels and inside the pixels:
// down, across, at an angle each way, with the points inside the box, past
// it, and on the edge of a pixel, opaque and with alpha. Each gives the
// pixels of the reference whole and in parts.
@(test)
gradients_along_a_line_draw_the_level_of_each_pixel :: proc(t: ^testing.T) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	memory := new(Edges_Tables)
	defer free(memory)
	table := Draw_Table{records = memory.records[:], text = memory.text[:]}
	start, end := draw_record.opaque(0x00FF2010), draw_record.with_alpha(0x001040FF, 90)
	draw_gradient(&table, 2 * UNITS, 1 * UNITS, 25 * UNITS, 16 * UNITS, 2 * UNITS + 32, 1 * UNITS + 32, 2 * UNITS + 32, 15 * UNITS + 32, start, end)
	draw_gradient(&table, 26 * UNITS + 13, 1 * UNITS + 50, 58 * UNITS + 7, 12 * UNITS + 20, 26 * UNITS, 0, 58 * UNITS, 0, end, start)
	draw_gradient(&table, -4 * UNITS, 17 * UNITS + 3, 30 * UNITS + 31, 36 * UNITS + 61, 0, 17 * UNITS, 30 * UNITS, 36 * UNITS, start, draw_record.opaque(0x0000FF00))
	draw_gradient(&table, 31 * UNITS + 1, 14 * UNITS, 64 * UNITS, 40 * UNITS, 60 * UNITS, 15 * UNITS + 7, 35 * UNITS + 3, 33 * UNITS, draw_record.with_alpha(0x00FFFFFF, 200), draw_record.Draw_Color(0x00FFFFFF))
	draw_gradient(&table, 20 * UNITS, 5 * UNITS, 40 * UNITS, 9 * UNITS, -100 * UNITS, -50 * UNITS, -90 * UNITS, -40 * UNITS, start, end)
	testing.expect_value(t, table.record_count, 5)
	testing.expect(t, !table.refused, "a gradient of the test is refused")
	whole, parts := draws_as_the_reference(&table)
	testing.expect(t, whole, "the gradients draw other pixels than the reference")
	testing.expect(t, parts, "the gradients in parts draw other pixels than the reference")
}

// The writers of the two axes: a gradient down keeps the pixels of the
// vertical gradient before it, the fill of the mix of each line at the
// level r * 255 / (h - 1), cut to the canvas. A gradient across mixes in
// the same steps of 1/255: each channel is within 1 of the row of
// graphics.gradient that the horizontal gradient drew before. A box of one
// line or one column is a rectangle of the first color.
@(test)
gradients_of_the_two_axes_keep_their_pixels :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Edges_Tables)
	defer free(memory)
	table := Draw_Table{records = memory.records[:], text = memory.text[:]}
	TOP, BOTTOM :: graphics.Color(0x00102030), graphics.Color(0x00F0E0D0)
	LEFT, RIGHT :: graphics.Color(0x00FF0000), graphics.Color(0x000000FF)
	draw_vertical_gradient(&table, -3, 20, 30, 25, TOP, BOTTOM)
	draw_horizontal_gradient(&table, 28, -5, 40, 20, LEFT, RIGHT)
	draw_vertical_gradient(&table, 5, 2, 10, 1, TOP, BOTTOM)
	draw_horizontal_gradient(&table, 20, 2, 1, 10, LEFT, RIGHT)
	testing.expect_value(t, table.record_count, 4)
	testing.expect_value(t, record_view(table.records[0]).axis, Gradient_Axis.Down)
	testing.expect_value(t, record_view(table.records[1]).axis, Gradient_Axis.Across)
	testing.expect_value(t, record_view(table.records[2]).kind, Draw_Kind.Rectangle)
	testing.expect_value(t, record_view(table.records[3]).kind, Draw_Kind.Rectangle)
	drawn := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	parts := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	expected := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	defer delete(drawn)
	defer delete(parts)
	defer delete(expected)
	edges_background(drawn)
	edges_background(parts)
	edges_background(expected)
	execute(&table, edges_canvas_of(drawn))
	rectangles := EDGES_PARTS
	execute_in_rectangles(&table, edges_canvas_of(parts), rectangles[:])
	canvas := edges_canvas_of(expected)
	for row in 0 ..< 25 {
		graphics.fill(canvas, -3, 20 + row, 30, 1, graphics.mix(TOP, BOTTOM, u32(row * 255 / 24)))
	}
	// The gradient across of before, to bound the difference.
	before: [40]graphics.Color
	graphics.gradient(before[:], LEFT, RIGHT, len(before), 0)
	for column in 0 ..< 40 {
		color := graphics.mix(LEFT, RIGHT, u32(column * 255 / 39))
		graphics.fill(canvas, 28 + column, -5, 1, 20, color)
		for shift in ([3]uint{0, 8, 16}) {
			new_channel, old_channel := int(color >> shift & 0xFF), int(before[column] >> shift & 0xFF)
			testing.expectf(t, abs(new_channel - old_channel) <= 1, "the column %d across differs by %d from before", column, new_channel - old_channel)
		}
	}
	graphics.fill(canvas, 5, 2, 10, 1, TOP)
	graphics.fill(canvas, 20, 2, 1, 10, LEFT)
	testing.expect(t, slice.equal(drawn, expected), "the gradients of the two axes draw other pixels")
	testing.expect(t, slice.equal(parts, expected), "the gradients of the two axes in parts draw other pixels")
}

// A rectangle inside the pixels that moves by one unit is another record:
// the difference damages the pixels of its two boxes, and the frame drawn
// in its damage, over the background, gives the pixels of the frame drawn
// whole. A box inside the pixels damages each pixel that it touches.
@(test)
a_rectangle_inside_the_pixels_that_moves_damages_its_pixels :: proc(t: ^testing.T) {
	_ = blend_table()
	UNITS :: draw_record.UNITS_PER_PIXEL
	before_memory := new(Edges_Tables)
	now_memory := new(Edges_Tables)
	defer free(before_memory)
	defer free(now_memory)
	before := Draw_Table{records = before_memory.records[:], text = before_memory.text[:]}
	now := Draw_Table{records = now_memory.records[:], text = now_memory.text[:]}
	color := draw_record.with_alpha(0x00FF0000, 180)
	draw_rectangle_in_units(&before, 10 * UNITS + 63, 5 * UNITS + 1, 20 * UNITS + 1, 9 * UNITS + 63, color)
	draw_rectangle_in_units(&now, 10 * UNITS + 64, 5 * UNITS + 1, 20 * UNITS + 2, 9 * UNITS + 63, color)
	testing.expect_value(t, record_rectangle(before.records[0]), Rectangle{10, 5, 21, 10})
	surface := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	whole := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	defer delete(surface)
	defer delete(whole)
	graphics.clear(edges_canvas_of(surface), graphics.colors.background)
	execute(&before, edges_canvas_of(surface))
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect(t, damage.count > 0, "a move by one unit damages nothing")
	draw_damage_on_surface(&now, edges_canvas_of(surface), damage.rectangles[:damage.count])
	graphics.clear(edges_canvas_of(whole), graphics.colors.background)
	execute(&now, edges_canvas_of(whole))
	testing.expect(t, slice.equal(surface, whole), "the frame drawn in its damage differs from the frame drawn whole")
}

// A box or a line of a gradient that the border refuses is not written,
// and sets refused: two equal points, points too far apart, a point past
// the limit. A rectangle past the limit too. A good one is written.
@(test)
the_writers_inside_the_pixels_refuse_what_the_border_refuses :: proc(t: ^testing.T) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	SPAN :: draw_record.GRADIENT_SPAN_LIMIT * UNITS
	color := draw_record.opaque(0x00808080)
	Line :: struct {
		start_x, start_y, end_x, end_y: i32,
	}
	refused := [?]Line{{5, 5, 5, 5}, {0, 0, SPAN + 1, 0}, {0, 0, 0, -SPAN - 1}, {draw_record.COORDINATE_UNIT_LIMIT + 1, 0, 0, 0}}
	for line, index in refused {
		memory := new(Edges_Tables)
		table := Draw_Table{records = memory.records[:], text = memory.text[:]}
		draw_gradient(&table, 0, 0, 10 * UNITS, 10 * UNITS, line.start_x, line.start_y, line.end_x, line.end_y, color, color)
		testing.expectf(t, table.record_count == 0 && table.refused, "the line %d is written", index)
		free(memory)
	}
	memory := new(Edges_Tables)
	defer free(memory)
	table := Draw_Table{records = memory.records[:], text = memory.text[:]}
	draw_rectangle_in_units(&table, 0, 0, draw_record.COORDINATE_UNIT_LIMIT + 1, 10, color)
	testing.expect(t, table.record_count == 0 && table.refused, "a rectangle past the limit is written")
	table.refused = false
	draw_gradient(&table, 0, 0, 10 * UNITS, 10 * UNITS, 0, 0, SPAN, -SPAN, color, color)
	testing.expect(t, table.record_count == 1 && !table.refused && record_view(table.records[0]).axis == .Slanted, "the gradient of the largest span is not written")
}

// A text with alpha: the record holds the color with its alpha, an alpha
// of 0 is the color 0 and draws nothing, an opaque text draws the pixels of
// draw_text, and a translucent text over a background draws the pixels of
// graphics.text_scaled with that alpha, which differ from the opaque ones.
@(test)
a_text_with_alpha_blends_its_ink :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Edges_Tables)
	defer free(memory)
	table := Draw_Table{records = memory.records[:], text = memory.text[:]}
	draw_text_with_alpha(&table, 3, 4, "Aa#", draw_record.with_alpha(0x00FFFFFF, 120))
	draw_text_with_alpha(&table, 3, 20, "Aa#", draw_record.with_alpha(0x00FFFFFF, 0))
	testing.expect_value(t, table.record_count, 2)
	testing.expect_value(t, record_view(table.records[0]).alpha, u8(120))
	view := record_view(table.records[1])
	testing.expect(t, view.read && view.color == 0 && view.alpha == 0, "a text of alpha 0 is not the color 0")
	drawn := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	expected := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	opaque := make([]graphics.Color, EDGES_WIDTH * EDGES_HEIGHT)
	defer delete(drawn)
	defer delete(expected)
	defer delete(opaque)
	edges_background(drawn)
	edges_background(expected)
	edges_background(opaque)
	execute(&table, edges_canvas_of(drawn))
	box := record_rectangle(table.records[0])
	graphics.text_scaled(graphics.view(edges_canvas_of(expected), box.left, box.top, box.right - box.left, box.bottom - box.top), 0, 0, "Aa#", 0x00FFFFFF, 1, 120)
	graphics.text_scaled(graphics.view(edges_canvas_of(opaque), box.left, box.top, box.right - box.left, box.bottom - box.top), 0, 0, "Aa#", 0x00FFFFFF, 1)
	testing.expect(t, slice.equal(drawn, expected), "a translucent text draws other pixels than text_scaled with its alpha")
	testing.expect(t, !slice.equal(drawn, opaque), "a translucent text draws the pixels of an opaque text")
}
