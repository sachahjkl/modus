#+build !freestanding
package interface

import "core:slice"
import "core:testing"
import "modus:contract/draw_record"
import "modus:support/graphics"

// The canvas of the tests of a path: wider than one band of columns and
// higher than one band of rows, so that a path crosses the edges of the
// bands of the accumulation.
@(private = "file")
PATH_WIDTH :: 300
@(private = "file")
PATH_HEIGHT :: 40

// The rectangles of a damage that cut the canvas into parts, across the
// edges of the bands and inside them.
@(private = "file")
PATH_PARTS :: [5]Rectangle{{0, 0, 37, PATH_HEIGHT}, {37, 0, 257, 9}, {37, 9, 257, PATH_HEIGHT}, {257, 0, 258, PATH_HEIGHT}, {258, 0, PATH_WIDTH, PATH_HEIGHT}}

@(private = "file")
Path_Tables :: struct {
	records: [32]Draw_Record,
	text:    [(draw_record.PATH_POINT_LIMIT + 8) * draw_record.PATH_POINT_SIZE]u8,
}

@(private = "file")
path_table_of :: proc(memory: ^Path_Tables) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:]}
}

@(private = "file")
path_canvas_of :: proc(pixels: []graphics.Color) -> graphics.Canvas {
	return {pixels = raw_data(pixels), width = PATH_WIDTH, height = PATH_HEIGHT, stride = PATH_WIDTH}
}

// A background of many values, so a blend over it meets each channel.
@(private = "file")
path_background :: proc(pixels: []graphics.Color) {
	for &pixel, index in pixels {
		pixel = u32(index) * 0x2545F491 & 0x00FFFFFF
	}
}

// A place in units: a whole pixel and a part of a pixel in 1/64.
@(private = "file")
at :: proc(pixels: int, part: i32 = 0) -> i32 {
	return draw_record.units_of_pixels(pixels) + part
}

@(private = "file")
point :: proc(command: draw_record.Path_Command, x: i32 = 0, y: i32 = 0) -> Path_Point {
	return {command = command, x = x, y = y}
}

// drawn_whole_and_in_parts draws a table whole and in the parts of a
// damage, over one background, and gives both. The caller deletes them.
@(private = "file")
drawn_whole_and_in_parts :: proc(table: ^Draw_Table) -> (whole, parts: []graphics.Color) {
	whole = make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
	parts = make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
	path_background(whole)
	path_background(parts)
	execute(table, path_canvas_of(whole))
	rectangles := PATH_PARTS
	execute_in_rectangles(table, path_canvas_of(parts), rectangles[:])
	return
}

// A square path, in either direction, draws the pixels of a Rectangle of
// the same box: on whole pixels and inside the pixels, opaque and with
// alpha, whole and in parts. A pixel covered whole is the color; a pixel
// covered x by y units takes the alpha of the rectangle.
@(test)
a_square_path_draws_the_pixels_of_a_rectangle :: proc(t: ^testing.T) {
	_ = blend_table()
	boxes := [?][4]i32 {
		{at(10), at(5), at(60), at(30)},
		{at(10, 21), at(5, 40), at(60, 3), at(30, 63)},
		{at(250, 1), at(3, 1), at(262, 63), at(12, 2)},
		{at(100, 10), at(20, 10), at(100, 50), at(20, 30)},
	}
	colors := [?]Draw_Color{draw_record.opaque(0x00ABCDEF), draw_record.with_alpha(0x00102030, 128), draw_record.with_alpha(0x00FFFFFF, 1)}
	for box, box_index in boxes {
		for color in colors {
			for reverse in ([2]bool{false, true}) {
				rectangle_memory, path_memory := new(Path_Tables), new(Path_Tables)
				defer free(rectangle_memory)
				defer free(path_memory)
				rectangle_table, path_table := path_table_of(rectangle_memory), path_table_of(path_memory)
				draw_rectangle_in_units(&rectangle_table, box[0], box[1], box[2], box[3], color)
				corners := [5]Path_Point{point(.Move, box[0], box[1]), point(.Line, box[2], box[1]), point(.Line, box[2], box[3]), point(.Line, box[0], box[3]), point(.Close)}
				if reverse {
					corners = {point(.Move, box[0], box[1]), point(.Line, box[0], box[3]), point(.Line, box[2], box[3]), point(.Line, box[2], box[1]), point(.Close)}
				}
				draw_path(&path_table, corners[:], color, 0, 0)
				testing.expectf(t, path_table.record_count == 1 && !path_table.refused, "the box %d: the path is not written", box_index)
				expected, expected_parts := drawn_whole_and_in_parts(&rectangle_table)
				whole, parts := drawn_whole_and_in_parts(&path_table)
				testing.expectf(t, slice.equal(whole, expected), "the box %d, the color %08x, reverse %v: the path draws other pixels than the rectangle", box_index, u32(color), reverse)
				testing.expectf(t, slice.equal(parts, expected) && slice.equal(expected_parts, expected), "the box %d, the color %08x, reverse %v: the path in parts draws other pixels than the rectangle", box_index, u32(color), reverse)
				delete(expected)
				delete(expected_parts)
				delete(whole)
				delete(parts)
			}
		}
	}
}

// The nonzero rule. A star of five points drawn as one subpath that
// crosses itself has a center of winding 2: covered whole, so it is the
// color. Two squares in one direction that overlap are covered whole in
// the overlap, and a translucent fill blends there once, as outside it.
// Two squares in the two directions that overlap have a winding of 0 in
// the overlap: it is not covered.
@(test)
the_fill_follows_the_nonzero_rule :: proc(t: ^testing.T) {
	_ = blend_table()
	BACKGROUND :: graphics.Color(0x00203040)
	paint :: proc(table: ^Draw_Table) -> []graphics.Color {
		pixels := make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
		slice.fill(pixels, BACKGROUND)
		execute(table, path_canvas_of(pixels))
		return pixels
	}
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	// The five points of a star around (20, 20), each to the second one
	// after it.
	star := [6]Path_Point{point(.Move, at(20), at(2)), point(.Line, at(31), at(36)), point(.Line, at(2), at(14)), point(.Line, at(38), at(14)), point(.Line, at(9), at(36)), point(.Close)}
	draw_path(&table, star[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	pixels := paint(&table)
	testing.expectf(t, pixels[20 * PATH_WIDTH + 20] == 0x00FFFFFF, "the center of the star, of winding 2, is %06x", pixels[20 * PATH_WIDTH + 20])
	testing.expectf(t, pixels[1 * PATH_WIDTH + 2] == BACKGROUND, "a corner outside the star is drawn")
	delete(pixels)

	translucent := draw_record.with_alpha(0x00FFFFFF, 100)
	draw_table_clear(&table)
	same := [10]Path_Point {
		point(.Move, at(50), at(5)), point(.Line, at(90), at(5)), point(.Line, at(90), at(35)), point(.Line, at(50), at(35)), point(.Close),
		point(.Move, at(70), at(10)), point(.Line, at(110), at(10)), point(.Line, at(110), at(30)), point(.Line, at(70), at(30)), point(.Close),
	}
	draw_path(&table, same[:], translucent, 0, 0)
	pixels = paint(&table)
	inside_one, inside_both := pixels[20 * PATH_WIDTH + 60], pixels[20 * PATH_WIDTH + 80]
	testing.expectf(t, inside_one != BACKGROUND && inside_one == inside_both, "two squares of one direction: %06x outside the overlap, %06x in it", inside_one, inside_both)
	delete(pixels)

	draw_table_clear(&table)
	opposite := [10]Path_Point {
		point(.Move, at(50), at(5)), point(.Line, at(90), at(5)), point(.Line, at(90), at(35)), point(.Line, at(50), at(35)), point(.Close),
		point(.Move, at(70), at(10)), point(.Line, at(70), at(30)), point(.Line, at(110), at(30)), point(.Line, at(110), at(10)), point(.Close),
	}
	draw_path(&table, opposite[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	pixels = paint(&table)
	testing.expectf(t, pixels[20 * PATH_WIDTH + 80] == BACKGROUND, "the overlap of two squares of two directions is drawn: %06x", pixels[20 * PATH_WIDTH + 80])
	testing.expect_value(t, pixels[20 * PATH_WIDTH + 60], graphics.Color(0x00FFFFFF))
	testing.expect_value(t, pixels[20 * PATH_WIDTH + 100], graphics.Color(0x00FFFFFF))
	delete(pixels)
}

// A stroke blends once: on a translucent stroke of a closed path with
// sharp turns, a pixel inside a join and a pixel in the middle of a segment
// are the same color, the color over the background once.
@(test)
a_stroke_blends_once_at_its_joins :: proc(t: ^testing.T) {
	_ = blend_table()
	BACKGROUND :: graphics.Color(0x00203040)
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	color := draw_record.with_alpha(0x00F0E0D0, 90)
	corners := [5]Path_Point{point(.Move, at(20, 32), at(8, 32)), point(.Line, at(120, 32), at(8, 32)), point(.Line, at(70, 32), at(32, 32)), point(.Line, at(20, 32), at(8, 32)), point(.Close)}
	draw_path(&table, corners[:], 0, color, 6 * draw_record.UNITS_PER_PIXEL)
	pixels := make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
	defer delete(pixels)
	slice.fill(pixels, BACKGROUND)
	execute(&table, path_canvas_of(pixels))
	middle := pixels[8 * PATH_WIDTH + 70]
	join := pixels[8 * PATH_WIDTH + 22]
	testing.expectf(t, middle != BACKGROUND && middle == join, "the middle of a segment is %06x and a join is %06x", middle, join)
	// The far side of the closing join, and the inside of the triangle: the
	// stroke is a band, the inside is not drawn.
	testing.expect_value(t, pixels[16 * PATH_WIDTH + 70], BACKGROUND)
}

// One table of many paths (a star, a circle of eight curves, a wide stroke
// with closed and open subpaths, a translucent stroke over a fill) gives
// the same pixels drawn whole and in the parts of a damage that cut it
// across the bands.
@(test)
a_path_in_parts_is_the_path_drawn_whole :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	star := [6]Path_Point{point(.Move, at(20, 7), at(2, 50)), point(.Line, at(31, 1), at(36)), point(.Line, at(2), at(14, 33)), point(.Line, at(38, 60), at(14)), point(.Line, at(9, 5), at(36, 9)), point(.Close)}
	draw_path(&table, star[:], draw_record.with_alpha(0x00FF8000, 200), draw_record.opaque(0x00102030), 3 * draw_record.UNITS_PER_PIXEL / 2)
	// A circle of radius 16 around (256, 20) from eight quadratic curves.
	circle := circle_points(at(256, 13), at(20, 5), at(16))
	draw_path(&table, circle[:], draw_record.opaque(0x0040F040), draw_record.with_alpha(0x00000000, 160), 5 * draw_record.UNITS_PER_PIXEL)
	wide := [7]Path_Point{point(.Move, at(60), at(4)), point(.Line, at(230), at(36, 17)), point(.Line, at(140), at(2)), point(.Close), point(.Move, at(240), at(38)), point(.Curve_Control, at(300), at(-30)), point(.Line, at(299), at(39))}
	draw_path(&table, wide[:], draw_record.with_alpha(0x0000FFFF, 60), draw_record.with_alpha(0x00FF00FF, 128), 20 * draw_record.UNITS_PER_PIXEL + 7)
	testing.expectf(t, table.record_count == 3 && !table.refused && !table.full, "the paths are not written: %d records", table.record_count)
	whole, parts := drawn_whole_and_in_parts(&table)
	defer delete(whole)
	defer delete(parts)
	testing.expect(t, slice.equal(whole, parts), "the paths in parts differ from the paths drawn whole")
	// Other parts that do not overlap, over a fresh background: a band of
	// one row, a column of one pixel at the edge of a band of columns, and
	// the rest right of it. A translucent path drawn twice over one pixel
	// would blend twice, so no two parts share a pixel.
	thin := [3]Rectangle{{0, 17, 255, 18}, {255, 0, 256, PATH_HEIGHT}, {256, 0, PATH_WIDTH, PATH_HEIGHT}}
	fresh := make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
	defer delete(fresh)
	path_background(fresh)
	execute_in_rectangles(&table, path_canvas_of(fresh), thin[:])
	for rectangle in thin {
		for y in rectangle.top ..< rectangle.bottom {
			for x in rectangle.left ..< rectangle.right {
				if fresh[y * PATH_WIDTH + x] != whole[y * PATH_WIDTH + x] {
					testing.expectf(t, false, "the pixel (%d, %d) in a thin part differs from the whole", x, y)
					return
				}
			}
		}
	}
}

// circle_points gives a circle of eight quadratic curves around a center,
// each curve an eighth of a turn with its control point on the tangents of
// its ends: about 0.03 % of the radius from the circle.
@(private = "file")
circle_points :: proc(center_x, center_y, radius: i32) -> [18]Path_Point {
	// The cosine and the sine of each eighth of a turn, and of the control
	// point between two of them (the radius divided by the cosine of a
	// sixteenth of a turn), in 1/65536.
	ON :: [8][2]i64{{65536, 0}, {46341, 46341}, {0, 65536}, {-46341, 46341}, {-65536, 0}, {-46341, -46341}, {0, -65536}, {46341, -46341}}
	CONTROL :: [8][2]i64{{65536, 27146}, {27146, 65536}, {-27146, 65536}, {-65536, 27146}, {-65536, -27146}, {-27146, -65536}, {27146, -65536}, {65536, -27146}}
	on, control := ON, CONTROL
	place :: proc(center, radius: i32, part: i64) -> i32 {
		return center + i32(i64(radius) * part / 65536)
	}
	points: [18]Path_Point
	points[0] = point(.Move, place(center_x, radius, on[0][0]), place(center_y, radius, on[0][1]))
	for eighth in 0 ..< 8 {
		next := on[(eighth + 1) % 8]
		points[1 + eighth * 2] = point(.Curve_Control, place(center_x, radius, control[eighth][0]), place(center_y, radius, control[eighth][1]))
		points[2 + eighth * 2] = point(.Line, place(center_x, radius, next[0]), place(center_y, radius, next[1]))
	}
	points[17] = point(.Close)
	return points
}

// A path of one point, and a list of no point, are refused: no record, no
// byte of the text table, and refused set.
@(test)
a_path_of_one_point_is_refused :: proc(t: ^testing.T) {
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	one := [1]Path_Point{point(.Move, at(4), at(4))}
	draw_path(&table, one[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	testing.expect(t, table.refused && table.record_count == 0 && table.text_count == 0, "a path of one point is written")
	table.refused = false
	draw_path(&table, nil, draw_record.opaque(0x00FFFFFF), 0, 0)
	testing.expect(t, table.refused && table.record_count == 0 && table.text_count == 0, "a path of no point is written")
	// The record of a path of one point, written by hand, is refused by the
	// border.
	record := draw_record.record_of(draw_record.Draw_Path{count = draw_record.PATH_POINT_SIZE, fill_color = draw_record.opaque(1)}, 0, 0, 0, at(8), at(8))
	_, problem := draw_record.read(record)
	testing.expect_value(t, problem, draw_record.Problem.Field_Past_Bound)
}

// The points that the border of the points refuses are refused by
// draw_path too: a first point that is not a Move, a curve with no end, a
// command that names none, a point one unit past the limit. The table is as
// it was: no record and no byte.
@(test)
draw_path_refuses_the_points_that_the_border_refuses :: proc(t: ^testing.T) {
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	first_line := [2]Path_Point{point(.Line, at(1), at(1)), point(.Line, at(9), at(1))}
	open_curve := [2]Path_Point{point(.Move, at(1), at(1)), point(.Curve_Control, at(9), at(9))}
	unknown := [2]Path_Point{point(.Move, at(1), at(1)), {command = draw_record.Path_Command(9), x = at(9), y = at(9)}}
	past := [2]Path_Point{point(.Move, at(1), at(1)), point(.Line, draw_record.COORDINATE_UNIT_LIMIT + 1, at(1))}
	cases := [4][]Path_Point{first_line[:], open_curve[:], unknown[:], past[:]}
	for points, index in cases {
		draw_path(&table, points, draw_record.opaque(0x00FFFFFF), draw_record.opaque(0x00FFFFFF), draw_record.UNITS_PER_PIXEL)
		testing.expectf(t, table.refused && table.record_count == 0 && table.text_count == 0, "the case %d is written", index)
		table.refused = false
	}
	// A stroke one unit past its limit is refused; at the limit it is read.
	line := [2]Path_Point{point(.Move, at(1), at(1)), point(.Line, at(9), at(1))}
	draw_path(&table, line[:], 0, draw_record.opaque(0x00FFFFFF), draw_record.STROKE_WIDTH_UNIT_LIMIT + 1)
	testing.expect(t, table.refused && table.record_count == 0, "a stroke past its limit is written")
	table.refused = false
	draw_path(&table, line[:], 0, draw_record.opaque(0x00FFFFFF), draw_record.STROKE_WIDTH_UNIT_LIMIT)
	testing.expect(t, !table.refused && table.record_count == 1 && record_view(table.records[0]).read, "a stroke at its limit is not written")
}

// The bound of the points: PATH_POINT_LIMIT points are written and drawn,
// whole and in parts alike; one point more is refused, and the table is as
// it was.
@(test)
a_path_at_the_bound_of_its_points :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	points := make([]Path_Point, draw_record.PATH_POINT_LIMIT + 1)
	defer delete(points)
	points[0] = point(.Move, at(0), at(0))
	for index in 1 ..< len(points) {
		// A zigzag across the canvas, down and up each point.
		points[index] = point(.Line, i32(index) * at(PATH_WIDTH) / i32(len(points)), at(index % 2 == 0 ? 2 : PATH_HEIGHT - 2, 7))
	}
	draw_path(&table, points, 0, 0, 0)
	draw_path(&table, points[:len(points) - 1], draw_record.with_alpha(0x00FFFFFF, 90), draw_record.opaque(0x00102030), draw_record.UNITS_PER_PIXEL)
	testing.expectf(t, table.refused && table.record_count == 1, "one point past the bound: refused %v, %d records", table.refused, table.record_count)
	view := record_view(table.records[0])
	testing.expect_value(t, view.count, draw_record.PATH_POINT_LIMIT * draw_record.PATH_POINT_SIZE)
	whole, parts := drawn_whole_and_in_parts(&table)
	defer delete(whole)
	defer delete(parts)
	testing.expect(t, slice.equal(whole, parts), "the path of the most points in parts differs from the path drawn whole")
}

// The bound of the sums of the cells: 511 curves, the most that a path
// holds, each cut into its 16 segments, out and back on one row of the
// canvas, stroked 64 pixels wide, so that every band lies over the same
// pixels. The curves are on one line, so each band is a rectangle across
// the canvas and the result is known with no rasterizer: each pixel right
// of the first point is covered whole, the color, and each pixel left of
// it is the background. A sum of the cells that wrapped would give other
// pixels. Two forms: a control point inside the canvas, which keeps every
// segment over the canvas, and a control point at the coordinate limit,
// the largest bend, whose segments reach 2^22 pixels away.
@(test)
the_sums_of_a_stroke_of_the_most_curves_do_not_wrap :: proc(t: ^testing.T) {
	_ = blend_table()
	CURVES :: (draw_record.PATH_POINT_LIMIT - 1) / 2
	controls := [2]i32{at(150 + 64), draw_record.COORDINATE_UNIT_LIMIT}
	for control, form in controls {
		memory := new(Path_Tables)
		defer free(memory)
		table := path_table_of(memory)
		row := at(20)
		start, end := at(10), at(290)
		points := make([]Path_Point, 1 + 2 * CURVES)
		defer delete(points)
		points[0] = point(.Move, start, row)
		for curve in 0 ..< CURVES {
			points[1 + 2 * curve] = point(.Curve_Control, control, row)
			points[2 + 2 * curve] = point(.Line, curve % 2 == 0 ? end : start, row)
		}
		testing.expect_value(t, draw_record.curve_segment_count(start, row, control, row, end, row), draw_record.CURVE_SEGMENT_LIMIT)
		draw_path(&table, points, 0, draw_record.opaque(0x00FFFFFF), draw_record.STROKE_WIDTH_UNIT_LIMIT)
		testing.expectf(t, table.record_count == 1 && !table.refused, "the form %d: the path is not written", form)
		whole, parts := drawn_whole_and_in_parts(&table)
		defer delete(whole)
		defer delete(parts)
		background := make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
		defer delete(background)
		path_background(background)
		// The last point of the form inside the canvas ends at the last
		// point: right of it the canvas keeps its background.
		right := form == 0 ? 290 : PATH_WIDTH
		wrong := 0
		for y in 0 ..< PATH_HEIGHT {
			for x in 0 ..< PATH_WIDTH {
				index := y * PATH_WIDTH + x
				expected := x >= 10 && x < right ? graphics.Color(0x00FFFFFF) : background[index]
				wrong += int(whole[index] != expected) + int(parts[index] != expected)
			}
		}
		testing.expectf(t, wrong == 0, "the form %d: %d pixels are not the pixels of the bands", form, wrong)
	}
}

// A path with no area: a line out and back, filled, draws no pixel.
@(test)
a_path_with_no_area_draws_nothing :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	flat := [4]Path_Point{point(.Move, at(10, 5), at(10, 5)), point(.Line, at(200, 9), at(30, 1)), point(.Line, at(10, 5), at(10, 5)), point(.Close)}
	draw_path(&table, flat[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	testing.expect_value(t, table.record_count, 1)
	whole, parts := drawn_whole_and_in_parts(&table)
	defer delete(whole)
	defer delete(parts)
	expected := make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
	defer delete(expected)
	path_background(expected)
	testing.expect(t, slice.equal(whole, expected) && slice.equal(parts, expected), "a path with no area draws")
}

// A curve whose control point is at the coordinate limit: cut into its 16
// segments, drawn with no fault, whole and in parts alike, and only inside
// its box and the canvas.
@(test)
a_curve_with_a_far_control_point :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	far := [3]Path_Point{point(.Move, at(5), at(5)), point(.Curve_Control, draw_record.COORDINATE_UNIT_LIMIT, -draw_record.COORDINATE_UNIT_LIMIT), point(.Line, at(290), at(35))}
	draw_path(&table, far[:], draw_record.with_alpha(0x00FFFF00, 120), draw_record.opaque(0x00FF0000), 4 * draw_record.UNITS_PER_PIXEL)
	testing.expect(t, table.record_count == 1 && !table.refused, "the far curve is not written")
	whole, parts := drawn_whole_and_in_parts(&table)
	defer delete(whole)
	defer delete(parts)
	testing.expect(t, slice.equal(whole, parts), "the far curve in parts differs from the curve drawn whole")
}

// A stroke on the edges of the surface: a rectangle whose sides lie on the
// edges of the canvas, stroked 6 pixels wide. The half of the stroke inside
// the canvas is drawn, whole and in parts alike, and no pixel around the
// canvas, in the memory of its caller, changes.
@(test)
a_stroke_at_the_edge_of_the_surface :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	edges := [5]Path_Point{point(.Move, 0, 0), point(.Line, at(PATH_WIDTH), 0), point(.Line, at(PATH_WIDTH), at(PATH_HEIGHT)), point(.Line, 0, at(PATH_HEIGHT)), point(.Close)}
	draw_path(&table, edges[:], 0, draw_record.opaque(0x00FFFFFF), 6 * draw_record.UNITS_PER_PIXEL)
	// The canvas inside a larger memory, with a frame of 4 pixels around it.
	FRAME :: 4
	OUTER_WIDTH :: PATH_WIDTH + 2 * FRAME
	outer := make([]graphics.Color, OUTER_WIDTH * (PATH_HEIGHT + 2 * FRAME))
	defer delete(outer)
	slice.fill(outer, 0x00123456)
	canvas := graphics.Canvas{pixels = raw_data(outer[FRAME * OUTER_WIDTH + FRAME:]), width = PATH_WIDTH, height = PATH_HEIGHT, stride = OUTER_WIDTH}
	execute(&table, canvas)
	for y in 0 ..< PATH_HEIGHT + 2 * FRAME {
		for x in 0 ..< OUTER_WIDTH {
			inside := x >= FRAME && x < FRAME + PATH_WIDTH && y >= FRAME && y < FRAME + PATH_HEIGHT
			pixel := outer[y * OUTER_WIDTH + x]
			if !inside && pixel != 0x00123456 {
				testing.expectf(t, false, "the stroke wrote at (%d, %d), outside the canvas", x - FRAME, y - FRAME)
				return
			}
		}
	}
	// The three pixels inside each edge are covered whole; the fourth is not.
	for step in 0 ..< 3 {
		testing.expect_value(t, outer[(FRAME + step) * OUTER_WIDTH + FRAME + 100], graphics.Color(0x00FFFFFF))
		testing.expect_value(t, outer[(FRAME + 20) * OUTER_WIDTH + FRAME + PATH_WIDTH - 1 - step], graphics.Color(0x00FFFFFF))
	}
	testing.expect_value(t, outer[(FRAME + 3) * OUTER_WIDTH + FRAME + 100], graphics.Color(0x00123456))
	whole, parts := drawn_whole_and_in_parts(&table)
	defer delete(whole)
	defer delete(parts)
	testing.expect(t, slice.equal(whole, parts), "the stroke at the edges in parts differs from the stroke drawn whole")
}

// Points at COORDINATE_LIMIT: a square from one limit to the other covers
// each pixel of the canvas whole. One unit past the limit is refused.
@(test)
a_path_at_the_coordinate_limit :: proc(t: ^testing.T) {
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	L :: draw_record.COORDINATE_UNIT_LIMIT
	square := [5]Path_Point{point(.Move, -L, -L), point(.Line, L, -L), point(.Line, L, L), point(.Line, -L, L), point(.Close)}
	draw_path(&table, square[:], draw_record.opaque(0x00FEDCBA), 0, 0)
	testing.expect(t, table.record_count == 1 && !table.refused && record_view(table.records[0]).read, "the square at the limit is not written")
	whole, parts := drawn_whole_and_in_parts(&table)
	defer delete(whole)
	defer delete(parts)
	for pixel, index in whole {
		if pixel != 0x00FEDCBA || parts[index] != 0x00FEDCBA {
			testing.expectf(t, false, "the pixel %d of the canvas is not covered whole: %06x, %06x in parts", index, pixel, parts[index])
			return
		}
	}
	text_count := table.text_count
	square[2].x = L + 1
	draw_path(&table, square[:], draw_record.opaque(0x00FEDCBA), 0, 0)
	testing.expect(t, table.refused && table.record_count == 1 && table.text_count == text_count, "a square one unit past the limit is written")
}

// Records of a path that a caller wrote by hand, which name points that
// the table does not hold or that the border of the points refuses, draw
// nothing: a range past the text table, a range at an address that is not
// a multiple of 4, an unknown command and a curve with no end in the text
// table. Each such record changed from a valid one damages its box.
@(test)
a_path_record_written_by_hand_that_names_wrong_points_draws_nothing :: proc(t: ^testing.T) {
	_ = blend_table()
	memory := new(Path_Tables)
	defer free(memory)
	table := path_table_of(memory)
	square := [5]Path_Point{point(.Move, at(10), at(10)), point(.Line, at(30), at(10)), point(.Line, at(30), at(30)), point(.Line, at(10), at(30)), point(.Close)}
	draw_path(&table, square[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	valid := table.records[0]
	fields := transmute(draw_record.Path_Fields)valid.fields
	records := ([^]draw_record.Path_Point_Record)(&table.text[fields.first])[:5]
	past := fields
	past.first = u32(table.text_count)
	past_record := valid
	past_record.fields = transmute([draw_record.FIELDS_SIZE]u8)past
	empty := make([]graphics.Color, PATH_WIDTH * PATH_HEIGHT)
	defer delete(empty)
	path_background(empty)
	// Each draw of this test, whole and in parts, must give the background.
	draws_nothing :: proc(t: ^testing.T, table: ^Draw_Table, empty: []graphics.Color, what: string) {
		whole, parts := drawn_whole_and_in_parts(table)
		defer delete(whole)
		defer delete(parts)
		testing.expectf(t, slice.equal(whole, empty) && slice.equal(parts, empty), "%s draws", what)
	}
	valid_pixels, valid_parts := drawn_whole_and_in_parts(&table)
	testing.expect(t, !slice.equal(valid_pixels, empty), "the valid square draws nothing")
	delete(valid_pixels)
	delete(valid_parts)
	// The range past the text table.
	one := [1]Draw_Record{past_record}
	past_table := Draw_Table{records = one[:], record_count = 1, text = table.text, text_count = table.text_count}
	draws_nothing(t, &past_table, empty, "a path whose points are past the text table")
	// The text of the table moved by 2 bytes, with the same count: the range
	// is inside it, at an address that is not a multiple of 4.
	shifted_one := [1]Draw_Record{valid}
	shifted := Draw_Table{records = shifted_one[:], record_count = 1, text = table.text[2:], text_count = table.text_count}
	draws_nothing(t, &shifted, empty, "a path at an address that is not a multiple of 4")
	// An unknown command, then a curve with no end, in the text table.
	records[2].command = 0
	draws_nothing(t, &table, empty, "a path with an unknown command")
	records[2].command = u32(draw_record.Path_Command.Line)
	records[3].command = u32(draw_record.Path_Command.Curve_Control)
	records[4].command = u32(draw_record.Path_Command.Move)
	draws_nothing(t, &table, empty, "a path with a curve with no end")
	// The damage of the record whose range moved past its text table: its
	// box.
	before_one := [1]Draw_Record{valid}
	before := Draw_Table{records = before_one[:], record_count = 1, text = table.text, text_count = table.text_count}
	damage: Damage
	damage_by_difference(&before, &past_table, &damage)
	testing.expect(t, damage.count == 1 && damage.rectangles[0] == record_rectangle(valid), "the path that names points past its table does not damage its box")
}

// A path that moves to a place that the reader refuses, with the same
// points, draws other pixels, so the difference damages its box: the
// record at the first byte 4 and then 5 with the same bytes there, and the
// same record over a text table one byte further, whose bytes at its range
// are the same.
@(test)
a_path_whose_points_leave_their_alignment_is_damaged :: proc(t: ^testing.T) {
	before_memory, now_memory := new(Path_Tables), new(Path_Tables)
	defer free(before_memory)
	defer free(now_memory)
	before := path_table_of(before_memory)
	triangle := [4]Path_Point{point(.Move, at(10), at(10)), point(.Line, at(60, 3), at(12)), point(.Line, at(20), at(35)), point(.Close)}
	// Four bytes of text first, so the points start at the byte 4.
	draw_text(&before, 0, 0, "four", 0x00FFFFFF)
	draw_path(&before, triangle[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	testing.expect_value(t, before.record_count, 2)
	before.records[0] = before.records[1]
	before.record_count = 1
	valid := before.records[0]
	fields := transmute(draw_record.Path_Fields)valid.fields
	testing.expect_value(t, fields.first, u32(4))
	size := int(fields.count)

	// The first byte 5, with the same points at the byte 5 of the table now.
	moved := fields
	moved.first = 5
	moved_record := valid
	moved_record.fields = transmute([draw_record.FIELDS_SIZE]u8)moved
	copy(now_memory.text[5:][:size], before_memory.text[4:][:size])
	now_records := [1]Draw_Record{moved_record}
	now := Draw_Table{records = now_records[:], record_count = 1, text = now_memory.text[:], text_count = 5 + size}
	_, problem := draw_record.read(moved_record)
	testing.expect_value(t, problem, draw_record.Problem.Field_Past_Bound)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect(t, damage.count == 1 && damage.rectangles[0] == record_rectangle(valid), "a path moved to the first byte 5 damages nothing")

	// The same record, over a text table one byte further: its 48 bytes and
	// the bytes of its range are equal, and its points are at an address
	// off a multiple of 4.
	copy(now_memory.text[1:][:4 + size], before_memory.text[:4 + size])
	same_records := [1]Draw_Record{valid}
	shifted := Draw_Table{records = same_records[:], record_count = 1, text = now_memory.text[1:], text_count = 4 + size}
	damage = {}
	damage_by_difference(&before, &shifted, &damage)
	testing.expect(t, damage.count == 1 && damage.rectangles[0] == record_rectangle(valid), "a path over a text table one byte further damages nothing")

	// The control: the same record over a text table four bytes further is
	// equal, and damages nothing.
	copy(now_memory.text[4:][:4 + size], before_memory.text[:4 + size])
	aligned := Draw_Table{records = same_records[:], record_count = 1, text = now_memory.text[4:], text_count = 4 + size}
	damage = {}
	damage_by_difference(&before, &aligned, &damage)
	testing.expect_value(t, damage.count, 0)
}

// The difference of two frames: the same path at another place of the
// text table damages nothing; a moved point damages the box of the path.
@(test)
the_difference_compares_the_points_of_a_path :: proc(t: ^testing.T) {
	before_memory, now_memory := new(Path_Tables), new(Path_Tables)
	defer free(before_memory)
	defer free(now_memory)
	before, now := path_table_of(before_memory), path_table_of(now_memory)
	triangle := [4]Path_Point{point(.Move, at(10), at(10)), point(.Line, at(60, 3), at(12)), point(.Line, at(20), at(35)), point(.Close)}
	draw_path(&before, triangle[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	// A text first in the frame now, so the points start at another byte.
	draw_text(&now, 0, 0, "moved", 0x00FFFFFF)
	draw_path(&now, triangle[:], draw_record.opaque(0x00FFFFFF), 0, 0)
	testing.expect_value(t, now.record_count, 2)
	now.records[0] = now.records[1]
	now.record_count = 1
	testing.expect(t, record_view(before.records[0]).first != record_view(now.records[0]).first, "the points did not move in the text table")
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	// One point moves by one unit, inside the same box.
	fields := transmute(draw_record.Path_Fields)now.records[0].fields
	moved := ([^]draw_record.Path_Point_Record)(&now.text[fields.first])[:4]
	moved[2].x += 1
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect(t, damage.count == 1 && damage.rectangles[0] == record_rectangle(now.records[0]), "a moved point does not damage the box of the path")
}
