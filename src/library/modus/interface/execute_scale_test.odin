#+build !freestanding
#+build !modus
package interface

import "core:testing"
import "modus:contract/draw_record"
import "modus:contract/scale_factor"
import "modus:graphics"

// The execution of a draw table at a scale factor (execute_scale.odin):
// each test tries to break the one rule of the edges, the parts of a
// damage, the refusals of the border and the cut of a clip.

@(private = "file")
SCALED_WIDTH :: 64

@(private = "file")
SCALED_HEIGHT :: 40

// A color that no record of these tests draws: a pixel that keeps it was
// drawn by no record.
@(private = "file")
UNTOUCHED :: graphics.Color(0x00123456)

@(private = "file")
RED :: draw_record.Draw_Color(0xFFE03020)

@(private = "file")
BLUE :: draw_record.Draw_Color(0xFF2040E0)

@(private = "file")
Scaled_Tables :: struct {
	records: [16]Draw_Record,
	text:    [256]u8, // After 16 records of 48 bytes: at a multiple of 4, as a path needs.
}

@(private = "file")
scaled_table_of :: proc(tables: ^Scaled_Tables, scale: scale_factor.Scale) -> Draw_Table {
	return {records = tables.records[:], text = tables.text[:], scale = scale}
}

@(private = "file")
record_add :: proc(table: ^Draw_Table, record: Draw_Record) {
	table.records[table.record_count] = record
	table.record_count += 1
}

// A box in whole logical pixels, in units.
@(private = "file")
box_record :: proc(primitive: draw_record.Draw_Primitive, left, top, right, bottom: int) -> Draw_Record {
	UNITS :: draw_record.UNITS_PER_PIXEL
	return draw_record.record_of(primitive, 0, i32(left * UNITS), i32(top * UNITS), i32(right * UNITS), i32(bottom * UNITS))
}

@(private = "file")
untouched_canvas :: proc(pixels: []graphics.Color) -> graphics.Canvas {
	for &pixel in pixels {
		pixel = UNTOUCHED
	}
	return {pixels = raw_data(pixels), width = SCALED_WIDTH, height = SCALED_HEIGHT, stride = SCALED_WIDTH}
}

@(private = "file")
scaled_test_start :: proc() {
	graphics.text_state_start()
	graphics.square_root_table_fill(&graphics.text_state.square_root)
}

// Two opaque rectangles that share an edge at a logical place that is not
// a multiple of 8 meet on the screen at the rounded edge: each pixel of the
// row takes one of the two colors, with no pixel of the background between
// them and no pixel of the first one past the edge. At 1.375 the edges 0, 3
// and 7 are the pixels 0, 4 and 10.
@(test)
two_rectangles_that_share_an_edge_meet_with_no_gap :: proc(t: ^testing.T) {
	scaled_test_start()
	for scale in scale_factor.Scale {
		tables: Scaled_Tables
		table := scaled_table_of(&tables, scale)
		record_add(&table, box_record(draw_record.Draw_Rectangle{color = RED}, 0, 0, 3, 2))
		record_add(&table, box_record(draw_record.Draw_Rectangle{color = BLUE}, 3, 0, 7, 2))
		pixels: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		canvas := untouched_canvas(pixels[:])
		execute(&table, canvas)
		shared := int(scale_factor.screen_pixel_of_logical_pixel(3, scale))
		end := int(scale_factor.screen_pixel_of_logical_pixel(7, scale))
		bottom := int(scale_factor.screen_pixel_of_logical_pixel(2, scale))
		if scale == .Eleven_Eighths {
			testing.expect_value(t, shared, 4)
			testing.expect_value(t, end, 10)
		}
		for y in 0 ..< SCALED_HEIGHT {
			for x in 0 ..< SCALED_WIDTH {
				expected := UNTOUCHED
				if y < bottom {
					switch {
					case x < shared:
						expected = draw_record.channels_of(RED)
					case x < end:
						expected = draw_record.channels_of(BLUE)
					}
				}
				testing.expectf(t, pixels[y * SCALED_WIDTH + x] == expected, "the pixel (%d, %d) at %d eighths is %x, not %x", x, y, u8(scale), pixels[y * SCALED_WIDTH + x], expected)
			}
		}
	}
}

// A line of 1 logical pixel at each place from 0 to 30 keeps at least one
// column of the screen, at each scale.
@(test)
a_line_of_one_logical_pixel_draws_at_least_one_column :: proc(t: ^testing.T) {
	scaled_test_start()
	for scale in scale_factor.Scale {
		for place in 0 ..< 30 {
			if int(scale_factor.screen_pixel_of_logical_pixel(i32(place + 1), scale)) > SCALED_WIDTH {
				break
			}
			tables: Scaled_Tables
			table := scaled_table_of(&tables, scale)
			record_add(&table, box_record(draw_record.Draw_Rectangle{color = RED}, place, 0, place + 1, 1))
			pixels: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
			execute(&table, untouched_canvas(pixels[:]))
			columns := 0
			for x in 0 ..< SCALED_WIDTH {
				if pixels[x] != UNTOUCHED {
					columns += 1
				}
			}
			testing.expectf(t, columns >= 1, "a line at the logical pixel %d at %d eighths drew %d columns", place, u8(scale), columns)
		}
	}
}

// A record that the border refuses draws nothing at a scale, as at no
// scale: a reserved byte that is not 0, and a box whose right edge is left
// of its left edge. A clip push that the border refuses is an empty clip:
// the rectangle under it draws nothing, and the rectangle after its pop
// draws.
@(test)
a_refused_record_draws_nothing_at_a_scale :: proc(t: ^testing.T) {
	scaled_test_start()
	for scale in scale_factor.Scale {
		tables: Scaled_Tables
		table := scaled_table_of(&tables, scale)
		reserved := box_record(draw_record.Draw_Rectangle{color = RED}, 0, 0, 10, 10)
		reserved.reserved[0] = 1
		record_add(&table, reserved)
		turned := box_record(draw_record.Draw_Rectangle{color = RED}, 10, 0, 2, 10)
		record_add(&table, turned)
		refused_push := box_record(draw_record.Draw_Clip_Push{}, 0, 0, 20, 20)
		refused_push.reserved[1] = 1
		record_add(&table, refused_push)
		record_add(&table, box_record(draw_record.Draw_Rectangle{color = RED}, 0, 0, 20, 20))
		record_add(&table, draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0))
		pixels: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		execute(&table, untouched_canvas(pixels[:]))
		for pixel, index in pixels {
			testing.expectf(t, pixel == UNTOUCHED, "the pixel %d at %d eighths changed: %x", index, u8(scale), pixel)
		}
		// The success case last: after the pop, a rectangle draws.
		record_add(&table, box_record(draw_record.Draw_Rectangle{color = BLUE}, 1, 1, 2, 2))
		execute(&table, untouched_canvas(pixels[:]))
		inside := int(scale_factor.screen_pixel_of_logical_pixel(1, scale))
		testing.expectf(t, pixels[inside * SCALED_WIDTH + inside] == draw_record.channels_of(BLUE), "the rectangle after the pop did not draw at %d eighths", u8(scale))
	}
}

// A clip cuts at its edges on the screen: a rectangle wider than its clip
// draws up to the rounded edge of the clip, and not one pixel past it.
@(test)
a_clip_cuts_at_its_edge_on_the_screen :: proc(t: ^testing.T) {
	scaled_test_start()
	for scale in scale_factor.Scale {
		tables: Scaled_Tables
		table := scaled_table_of(&tables, scale)
		record_add(&table, box_record(draw_record.Draw_Clip_Push{}, 3, 1, 13, 9))
		record_add(&table, box_record(draw_record.Draw_Rectangle{color = RED}, 0, 0, 30, 20))
		record_add(&table, draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0))
		pixels: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		execute(&table, untouched_canvas(pixels[:]))
		clip := scale_factor.screen_rectangle_of_logical_rectangle(3, 1, 13, 9, scale)
		for y in 0 ..< SCALED_HEIGHT {
			for x in 0 ..< SCALED_WIDTH {
				inside := i64(x) >= clip.left && i64(x) < clip.right && i64(y) >= clip.top && i64(y) < clip.bottom
				drawn := pixels[y * SCALED_WIDTH + x] != UNTOUCHED
				testing.expectf(t, inside == drawn, "the pixel (%d, %d) at %d eighths: inside the clip %v, drawn %v", x, y, u8(scale), inside, drawn)
			}
		}
	}
}

// A picture keeps its pixels: each pixel of the screen is the pixel of the
// logical pixel that holds it, also for a picture whose left edge is not a
// multiple of 8 logical pixels.
@(test)
a_picture_keeps_its_pixels_at_a_scale :: proc(t: ^testing.T) {
	scaled_test_start()
	PICTURE_WIDTH :: 7
	PICTURE_HEIGHT :: 5
	picture: [PICTURE_WIDTH * PICTURE_HEIGHT]graphics.Color
	for &pixel, index in picture {
		pixel = graphics.Color(index + 1) * 0x010307
	}
	memories := [1][]graphics.Color{picture[:]}
	for scale in scale_factor.Scale {
		tables: Scaled_Tables
		table := scaled_table_of(&tables, scale)
		table.picture_memories = memories[:]
		record_add(&table, box_record(draw_record.Draw_Picture{memory = 0, format = .Opaque, first = 0, stride = PICTURE_WIDTH, generation = 1}, 3, 2, 3 + PICTURE_WIDTH, 2 + PICTURE_HEIGHT))
		pixels: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		execute(&table, untouched_canvas(pixels[:]))
		box := scale_factor.screen_rectangle_of_logical_rectangle(3, 2, 3 + PICTURE_WIDTH, 2 + PICTURE_HEIGHT, scale)
		for y in 0 ..< SCALED_HEIGHT {
			for x in 0 ..< SCALED_WIDTH {
				expected := UNTOUCHED
				if i64(x) >= box.left && i64(x) < box.right && i64(y) >= box.top && i64(y) < box.bottom {
					column := int(scale_factor.logical_pixel_of_screen_pixel(i32(x), scale)) - 3
					line := int(scale_factor.logical_pixel_of_screen_pixel(i32(y), scale)) - 2
					expected = picture[line * PICTURE_WIDTH + column]
				}
				testing.expectf(t, pixels[y * SCALED_WIDTH + x] == expected, "the pixel (%d, %d) of the picture at %d eighths", x, y, u8(scale))
			}
		}
	}
}

// The cells of a pattern whose step is not a whole count of pixels of the
// screen never overlap and never lose a pixel: a pattern of cells of 1
// logical pixel each 2 draws, in each row of a cell, the columns of the
// even logical pixels and none of the odd ones.
@(test)
a_pattern_keeps_its_cells_apart_at_a_scale :: proc(t: ^testing.T) {
	scaled_test_start()
	UNITS :: draw_record.UNITS_PER_PIXEL
	for scale in scale_factor.Scale {
		tables: Scaled_Tables
		table := scaled_table_of(&tables, scale)
		pattern := draw_record.Repetition{cell_x = 0, cell_y = 0, cell_width = UNITS, cell_height = UNITS, step_x = 2 * UNITS, step_y = 2 * UNITS}
		record_add(&table, box_record(draw_record.Draw_Rectangle{color = RED, repetition = pattern}, 0, 0, 30, 20))
		pixels: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		execute(&table, untouched_canvas(pixels[:]))
		box := scale_factor.screen_rectangle_of_logical_rectangle(0, 0, 30, 20, scale)
		for y in 0 ..< SCALED_HEIGHT {
			for x in 0 ..< SCALED_WIDTH {
				column := scale_factor.logical_pixel_of_screen_pixel(i32(x), scale)
				line := scale_factor.logical_pixel_of_screen_pixel(i32(y), scale)
				inside := i64(x) < box.right && i64(y) < box.bottom
				expected := inside && column % 2 == 0 && line % 2 == 0
				drawn := pixels[y * SCALED_WIDTH + x] != UNTOUCHED
				testing.expectf(t, drawn == expected, "the pixel (%d, %d) of the pattern at %d eighths: drawn %v", x, y, u8(scale), drawn)
			}
		}
	}
}

// A table drawn whole and drawn in the parts of a damage give the same
// pixels at a scale: rectangles on edges inside a pixel, a gradient along
// a slanted line, a pattern and a path, each cut at the edges of the parts.
@(test)
a_scaled_table_drawn_in_parts_is_the_table_drawn_whole :: proc(t: ^testing.T) {
	scaled_test_start()
	UNITS :: draw_record.UNITS_PER_PIXEL
	parts := [4]Rectangle{{0, 0, 9, SCALED_HEIGHT}, {9, 0, 33, 13}, {9, 13, 33, SCALED_HEIGHT}, {33, 0, SCALED_WIDTH, SCALED_HEIGHT}}
	for scale in scale_factor.Scale {
		tables: Scaled_Tables
		table := scaled_table_of(&tables, scale)
		record_add(&table, draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.Draw_Color(0x80E03020)}, 0, 3 * UNITS + 17, UNITS + 40, 21 * UNITS + 5, 17 * UNITS + 63))
		record_add(&table, box_record(draw_record.Draw_Gradient{start_x = 2 * UNITS + 11, start_y = UNITS, end_x = 27 * UNITS, end_y = 19 * UNITS + 30, start_color = RED, end_color = draw_record.Draw_Color(0x402040E0)}, 1, 1, 29, 24))
		pattern := draw_record.Repetition{cell_x = UNITS, cell_y = 0, cell_width = UNITS, cell_height = 2 * UNITS, step_x = 3 * UNITS, step_y = 3 * UNITS}
		record_add(&table, box_record(draw_record.Draw_Rectangle{color = BLUE, repetition = pattern}, 5, 20, 40, 30))
		points := [4]draw_record.Path_Point_Record{{u32(draw_record.Path_Command.Move), 30 * UNITS + 7, 2 * UNITS}, {u32(draw_record.Path_Command.Line), 47 * UNITS, 9 * UNITS + 33}, {u32(draw_record.Path_Command.Line), 33 * UNITS, 27 * UNITS}, {u32(draw_record.Path_Command.Close), 0, 0}}
		point_bytes := transmute([size_of(points)]u8)points
		copy(tables.text[:], point_bytes[:])
		table.text_count = size_of(points)
		path := draw_record.Draw_Path{first = 0, count = size_of(points), fill_color = draw_record.Draw_Color(0xC020A040), stroke_color = RED, stroke_width = UNITS + 20}
		record_add(&table, box_record(path, 28, 0, 50, 30))
		whole: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		in_parts: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		execute(&table, untouched_canvas(whole[:]))
		execute_in_rectangles(&table, untouched_canvas(in_parts[:]), parts[:])
		changed := 0
		for pixel, index in whole {
			testing.expectf(t, pixel == in_parts[index], "the pixel %d at %d eighths: whole %x, in parts %x", index, u8(scale), pixel, in_parts[index])
			if pixel != UNTOUCHED {
				changed += 1
			}
		}
		testing.expectf(t, changed > 0, "the table drew nothing at %d eighths", u8(scale))
	}
}

// A text in the font of the cells draws its glyphs at the size times the
// scale, inside its box on the screen: no pixel of ink outside it, and some
// ink inside it.
@(test)
a_text_of_the_cells_draws_inside_its_box_on_the_screen :: proc(t: ^testing.T) {
	process_drawing_begin()
	scaled_test_start()
	UNITS :: draw_record.UNITS_PER_PIXEL
	for scale in scale_factor.Scale {
		tables: Scaled_Tables
		table := scaled_table_of(&tables, scale)
		copy(tables.text[:], "AB")
		table.text_count = 2
		text := draw_record.Draw_Text{first = 0, count = 2, color = RED, origin_x = 3 * UNITS, font = .Cells_8x16, weight = .Regular, size = 16 * UNITS}
		record_add(&table, box_record(text, 3, 1, 3 + 16, 1 + 16))
		pixels: [SCALED_WIDTH * SCALED_HEIGHT]graphics.Color
		execute(&table, untouched_canvas(pixels[:]))
		box := scale_factor.screen_rectangle_of_logical_rectangle(3, 1, 19, 17, scale)
		ink := 0
		for y in 0 ..< SCALED_HEIGHT {
			for x in 0 ..< SCALED_WIDTH {
				if pixels[y * SCALED_WIDTH + x] == UNTOUCHED {
					continue
				}
				inside := i64(x) >= box.left && i64(x) < box.right && i64(y) >= box.top && i64(y) < box.bottom
				testing.expectf(t, inside, "ink at (%d, %d), outside the box of the text at %d eighths", x, y, u8(scale))
				ink += 1
			}
		}
		testing.expectf(t, ink > 0, "the text drew no ink at %d eighths", u8(scale))
	}
}

// The damage at a scale: no count past the capacity is read, a negative
// count changes nothing, an edge past COORDINATE_LIMIT is kept at the
// limit and does not wrap, and each rectangle goes to the screen by the
// rule of each edge.
@(test)
a_damage_goes_to_the_screen_by_the_rule_of_each_edge :: proc(t: ^testing.T) {
	negative: Damage
	negative.count = -1
	negative.rectangles[0] = {1, 2, 3, 4}
	damage_at_scale(&negative, .Ten_Eighths)
	testing.expect_value(t, negative.rectangles[0], Rectangle{1, 2, 3, 4})

	past: Damage
	past.count = DAMAGE_CAPACITY + 1
	for &rectangle in past.rectangles {
		rectangle = {0, 0, 8, 8}
	}
	damage_at_scale(&past, .Ten_Eighths)
	for rectangle in past.rectangles {
		testing.expect_value(t, rectangle, Rectangle{0, 0, 10, 10})
	}

	largest: Damage
	largest.count = 1
	largest.rectangles[0] = {min(int), -COORDINATE_LIMIT - 1, COORDINATE_LIMIT + 1, max(int)}
	damage_at_scale(&largest, .Sixteen_Eighths)
	testing.expect_value(t, largest.rectangles[0], Rectangle{-2 * COORDINATE_LIMIT, -2 * COORDINATE_LIMIT, 2 * COORDINATE_LIMIT, 2 * COORDINATE_LIMIT})

	// The success case last: edges at 3 and 7 logical pixels at 1.375.
	shared: Damage
	shared.count = 2
	shared.rectangles[0] = {0, 0, 3, 2}
	shared.rectangles[1] = {3, 0, 7, 2}
	damage_at_scale(&shared, .Eleven_Eighths)
	testing.expect_value(t, shared.rectangles[0], Rectangle{0, 0, 4, 3})
	testing.expect_value(t, shared.rectangles[1], Rectangle{4, 0, 10, 3})
}
