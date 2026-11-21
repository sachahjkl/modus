package interface

// The drawing of a Path record (src/md/api/draw_table.md, "The kinds"). The
// coverage of each pixel is its exact area, in integers: each line segment
// adds its signed area to the cells of an accumulation, and a prefix sum
// along each row gives the part of each pixel that the shape covers. It is
// the method of the glyphs (src/library/modus/vector_font, raster.odin),
// in 1/64 pixel and in 64 bits: the places of a path reach 2^30 units from
// the cut, past the i32 of the glyphs, and the accumulation covers one
// band of the cut at a time, so the pieces left and right of the band are
// cut there and not clamped.
//
// The pixels are the same in each cut. A piece of a segment in a row is
// cut at each column; the place of a cut is a function of the segment and
// of the line of the cut only, in the coordinates of the surface. So a
// band computes, for each of its pixels, the sum that one band over the
// whole box would compute, and a frame drawn in four damage rectangles
// gives the pixels of one draw.
//
// The memory: the points, copied once (PATH_POINT_LIMIT points of 12
// bytes, 12 KiB), the cells of one band (PATH_BAND_ROWS rows of
// PATH_BAND_COLUMNS + 1 cells of 4 bytes, 8 KiB) and one row of colors
// (1 KiB), all on the stack of the caller: no allocator, and the same
// memory whatever the size of the cut.

import "modus:contract/draw_record"
import "modus:contract/scale_factor"
import "modus:graphics"

// The rows and the columns of one band of the accumulation. Each segment of
// the path is walked once for each band: more rows walk fewer times and
// take more stack.
PATH_BAND_ROWS :: 8
PATH_BAND_COLUMNS :: 256

// The value of a cell for a pixel covered whole: a height of 64 units
// times twice a width of 64 units. An edge of the outline gives one piece
// to each row, and a piece adds at most this to the sums of its row.
@(private)
PATH_FULL_PIXEL :: draw_record.UNITS_PER_PIXEL * 2 * draw_record.UNITS_PER_PIXEL
@(private)
PATH_FULL_PIXEL_SHIFT :: 13

#assert(PATH_FULL_PIXEL == 1 << PATH_FULL_PIXEL_SHIFT)

// The most edges of the outline of one pass of a path, for the bound of
// the sums (src/md/api/draw_table.md, "The kinds"): the stroke of a curve
// gives the most edges for each point, 16 segments of 4 edges for its band
// and 3 for its join, over its 2 points: 56 for each point. A Line gives 7,
// a Close 10 (its band and the joins at its two ends), a Move none, and the
// fill gives at most 8 edges for each point and one more for each subpath.
@(private)
PATH_EDGE_LIMIT :: draw_record.CURVE_SEGMENT_LIMIT * (4 + 3) / 2 * draw_record.PATH_POINT_LIMIT

// Each sum of a row is at most the edges times a pixel covered whole, so
// the cells are i32 with no wrap.
#assert(PATH_EDGE_LIMIT * PATH_FULL_PIXEL < 1 << 31)

// The two passes of a path: the fill, then the stroke over it.
@(private)
Path_Pass :: enum u8 {
	Fill,
	Stroke,
}

// The accumulation of one band of the cut, in pixels of the surface.
@(private)
Path_Band :: struct {
	cells:       [PATH_BAND_ROWS][PATH_BAND_COLUMNS + 1]i32,
	top, bottom: int, // The rows of the band.
	left, right: int, // The columns of the band.
}

// path_draw draws a Path that the border read, cut to area, a rectangle of
// the surface that the view shows from its top left corner. A range of
// points outside the text table, at an address that is not a multiple of
// 4, or whose points the border of the points refuses, draws nothing. It is
// never inlined: its scratch of 21 KiB stays in its own frame, and the
// caller, which draws each other kind, keeps a small one.
@(private)
path_draw :: #force_no_inline proc "contextless" (table: ^Draw_Table, view: graphics.Canvas, area: Rectangle, path: draw_record.Draw_Path) {
	start, count := u64(path.first), u64(path.count)
	if count == 0 || start + count > u64(table.text_count) || start + count > u64(len(table.text)) {
		return
	}
	if (uintptr(raw_data(table.text)) + uintptr(start)) % align_of(draw_record.Path_Point_Record) != 0 {
		return
	}
	records := ([^]draw_record.Path_Point_Record)(&table.text[start])[:int(count / draw_record.PATH_POINT_SIZE)]
	points: [draw_record.PATH_POINT_LIMIT]draw_record.Path_Point = ---
	point_count, problem := draw_record.path_points_read(records, points[:])
	if problem != .None {
		return
	}
	stroke_width := i64(path.stroke_width)
	// At a scale, each point and the width go to the screen after the
	// border read them, each to the nearest unit: a point keeps its part of
	// a pixel, so a curve stays smooth. A point inside COORDINATE_LIMIT
	// stays inside 2^30 units at the scale 2, an i32.
	if scale, scaled := table.scale.?; scaled {
		for &point in points[:point_count] {
			point.x = i32(scale_factor.screen_place(point.x, scale))
			point.y = i32(scale_factor.screen_place(point.y, scale))
		}
		stroke_width = scale_factor.screen_place(i32(path.stroke_width), scale)
	}
	band: Path_Band = ---
	if path.fill_color != 0 {
		path_pass_draw(&band, view, area, points[:point_count], .Fill, 0, path.fill_color)
	}
	if path.stroke_color != 0 {
		path_pass_draw(&band, view, area, points[:point_count], .Stroke, stroke_width, path.stroke_color)
	}
}

// path_pass_draw draws one pass of a path, band by band: it clears the
// cells, adds each segment, then blends each row of the band with the
// alpha of the color times the coverage of each pixel, rounded to the
// nearest. A pixel covered whole takes the alpha of the color, so an
// opaque color writes its channels there; with a pixel covered x by y
// units, the alpha is (alpha * x * y + 2048) >> 12, the alpha of a
// Rectangle whose box covers that part of the pixel.
@(private)
path_pass_draw :: proc "contextless" (band: ^Path_Band, view: graphics.Canvas, area: Rectangle, points: []draw_record.Path_Point, pass: Path_Pass, width: i64, color: draw_record.Draw_Color) {
	alpha, channels := u32(draw_record.alpha_of(color)), draw_record.channels_of(color)
	row: [PATH_BAND_COLUMNS]u32 = ---
	for top := area.top; top < area.bottom; top += PATH_BAND_ROWS {
		bottom := min(top + PATH_BAND_ROWS, area.bottom)
		for left := area.left; left < area.right; left += PATH_BAND_COLUMNS {
			right := min(left + PATH_BAND_COLUMNS, area.right)
			columns := right - left
			band.top, band.bottom, band.left, band.right = top, bottom, left, right
			for line in 0 ..< bottom - top {
				for &cell in band.cells[line][:columns + 1] {
					cell = 0
				}
			}
			switch pass {
			case .Fill:
				path_fill_add(band, points)
			case .Stroke:
				path_stroke_add(band, points, width)
			}
			for line in 0 ..< bottom - top {
				sum: i32
				drawn := false
				for column in 0 ..< columns {
					sum += band.cells[line][column]
					covered := u32(min(abs(sum), PATH_FULL_PIXEL))
					part := (alpha * covered + PATH_FULL_PIXEL / 2) >> PATH_FULL_PIXEL_SHIFT
					row[column] = part << 24 | channels
					if part != 0 {
						drawn = true
					}
				}
				if drawn {
					graphics.blend_copy(view, left - area.left, top + line - area.top, {pixels = raw_data(row[:]), width = columns, height = 1, stride = columns}, &graphics.text_state.square_root)
				}
			}
		}
	}
}

// path_fill_add adds the outline of the fill: each segment of each
// subpath, each curve cut into its segments, and the segment that closes
// each subpath, a Close or not. The border of the points keeps a Line after
// each Curve_Control.
@(private)
path_fill_add :: proc "contextless" (band: ^Path_Band, points: []draw_record.Path_Point) {
	start_x, start_y, current_x, current_y: i64
	index := 0
	for index < len(points) {
		point := points[index]
		switch point.command {
		case .Move:
			band_line_add(band, current_x, current_y, start_x, start_y)
			start_x, start_y = i64(point.x), i64(point.y)
			current_x, current_y = start_x, start_y
		case .Line:
			band_line_add(band, current_x, current_y, i64(point.x), i64(point.y))
			current_x, current_y = i64(point.x), i64(point.y)
		case .Curve_Control:
			end := points[index + 1]
			count := draw_record.curve_segment_count(i32(current_x), i32(current_y), point.x, point.y, end.x, end.y)
			previous_x, previous_y := current_x, current_y
			for step in 1 ..= count {
				x, y := draw_record.curve_point(i32(current_x), i32(current_y), point.x, point.y, end.x, end.y, step, count)
				band_line_add(band, previous_x, previous_y, i64(x), i64(y))
				previous_x, previous_y = i64(x), i64(y)
			}
			current_x, current_y = i64(end.x), i64(end.y)
			index += 1
		case .Close:
			band_line_add(band, current_x, current_y, start_x, start_y)
			current_x, current_y = start_x, start_y
		}
		index += 1
	}
	band_line_add(band, current_x, current_y, start_x, start_y)
}

// The state of the stroke of one subpath, as its segments come.
@(private)
Stroke_State :: struct {
	band:                     ^Path_Band,
	width:                    i64, // In units.
	reach:                    i64, // The farthest that a point of the outline lies from its point of the path: half the width, and the rounding.
	start_x, start_y:         i64, // The Move of the subpath.
	current_x, current_y:     i64, // The end of the last segment.
	has_previous:             bool, // A segment of the subpath came.
	previous_x, previous_y:   i64, // The start of the last segment.
	first_end_x, first_end_y: i64, // The end of the first segment of the subpath.
}

// path_stroke_add adds the outline of the stroke: for each segment of each
// subpath, a band of the width along it with butt ends; at each point
// between two segments, a bevel join; and for a subpath that ends with a
// Close, the segment back to its Move and the joins at its two ends. A
// segment of no length has no direction: it is left out, and adds no join.
@(private)
path_stroke_add :: proc "contextless" (band: ^Path_Band, points: []draw_record.Path_Point, width: i64) {
	state := Stroke_State{band = band, width = width, reach = width / 2 + 2}
	index := 0
	for index < len(points) {
		point := points[index]
		switch point.command {
		case .Move:
			state.start_x, state.start_y = i64(point.x), i64(point.y)
			state.current_x, state.current_y = state.start_x, state.start_y
			state.has_previous = false
		case .Line:
			stroke_segment_add(&state, i64(point.x), i64(point.y))
		case .Curve_Control:
			end := points[index + 1]
			from_x, from_y := i32(state.current_x), i32(state.current_y)
			count := draw_record.curve_segment_count(from_x, from_y, point.x, point.y, end.x, end.y)
			for step in 1 ..= count {
				x, y := draw_record.curve_point(from_x, from_y, point.x, point.y, end.x, end.y, step, count)
				stroke_segment_add(&state, i64(x), i64(y))
			}
			index += 1
		case .Close:
			if state.has_previous {
				stroke_segment_add(&state, state.start_x, state.start_y)
				stroke_join_add(&state, state.previous_x, state.previous_y, state.start_x, state.start_y, state.first_end_x, state.first_end_y)
			}
			state.has_previous = false
		}
		index += 1
	}
}

// stroke_segment_add adds the band of one segment from the current point,
// and the join at the current point with the segment before it.
@(private)
stroke_segment_add :: proc "contextless" (state: ^Stroke_State, to_x, to_y: i64) {
	from_x, from_y := state.current_x, state.current_y
	if to_x == from_x && to_y == from_y {
		return
	}
	if near_band(state.band, min(from_x, to_x) - state.reach, min(from_y, to_y) - state.reach, max(from_y, to_y) + state.reach) {
		normal_x, normal_y := segment_normal(to_x - from_x, to_y - from_y, state.width)
		// The four corners in this order give each band one direction of
		// its area, whatever the direction of the segment: the band is the
		// segment turned a quarter, so the sum of overlapping bands never
		// cancels.
		corners := [4][2]i64{{from_x + normal_x, from_y + normal_y}, {to_x + normal_x, to_y + normal_y}, {to_x - normal_x, to_y - normal_y}, {from_x - normal_x, from_y - normal_y}}
		for corner, index in corners {
			next := corners[(index + 1) % 4]
			band_line_add(state.band, corner[0], corner[1], next[0], next[1])
		}
	}
	if state.has_previous {
		stroke_join_add(state, state.previous_x, state.previous_y, from_x, from_y, to_x, to_y)
	} else {
		state.first_end_x, state.first_end_y = to_x, to_y
	}
	state.has_previous = true
	state.previous_x, state.previous_y = from_x, from_y
	state.current_x, state.current_y = to_x, to_y
}

// stroke_join_add adds the bevel join at a point between the segment that
// comes from before and the segment that goes to after: the triangle
// between the point and the two outer corners of the two bands. Two
// segments on one line, in one direction or in the two, need no join.
@(private)
stroke_join_add :: proc "contextless" (state: ^Stroke_State, before_x, before_y, at_x, at_y, after_x, after_y: i64) {
	in_x, in_y := at_x - before_x, at_y - before_y
	out_x, out_y := after_x - at_x, after_y - at_y
	turn := in_x * out_y - in_y * out_x
	if turn == 0 || (in_x == 0 && in_y == 0) || (out_x == 0 && out_y == 0) {
		return
	}
	if !near_band(state.band, at_x - state.reach, at_y - state.reach, at_y + state.reach) {
		return
	}
	in_normal_x, in_normal_y := segment_normal(in_x, in_y, state.width)
	out_normal_x, out_normal_y := segment_normal(out_x, out_y, state.width)
	// The outer side of the turn is the side away from the way it turns.
	side: i64 = turn > 0 ? -1 : 1
	first_x, first_y := at_x + side * in_normal_x, at_y + side * in_normal_y
	second_x, second_y := at_x + side * out_normal_x, at_y + side * out_normal_y
	// The direction of the area of a band, for the triangle too.
	if (first_x - at_x) * (second_y - at_y) - (first_y - at_y) * (second_x - at_x) > 0 {
		first_x, first_y, second_x, second_y = second_x, second_y, first_x, first_y
	}
	band_line_add(state.band, at_x, at_y, first_x, first_y)
	band_line_add(state.band, first_x, first_y, second_x, second_y)
	band_line_add(state.band, second_x, second_y, at_x, at_y)
}

// near_band says if a part of the outline whose left edge, top and bottom
// are given, in units, can add to the band: a part that is all above it,
// all below it or all right of it adds nothing. A part left of the band
// adds its height to the first cell of each row, so it is never left out.
@(private)
near_band :: proc "contextless" (band: ^Path_Band, left, top, bottom: i64) -> bool {
	UNITS :: draw_record.UNITS_PER_PIXEL
	return bottom > i64(band.top) * UNITS && top < i64(band.bottom) * UNITS && left < i64(band.right) * UNITS
}

// segment_normal gives the vector a quarter turn from a direction, half a
// width long, each axis rounded to the nearest unit. The direction is
// first made longer by powers of 2 up to 2^29 units, so that the square
// root of its length keeps about 29 bits: the normal of a short segment is
// as exact as the normal of a long one. The squares then fit an i64, and a
// width of at most STROKE_WIDTH_UNIT_LIMIT times a coordinate fits too.
@(private)
segment_normal :: proc "contextless" (direction_x, direction_y, width: i64) -> (normal_x, normal_y: i64) {
	// A direction of no length has no normal; the loop below would not end.
	if direction_x == 0 && direction_y == 0 {
		return 0, 0
	}
	x, y := direction_x, direction_y
	for max(abs(x), abs(y)) < 1 << 29 {
		x, y = x * 2, y * 2
	}
	length := i64(square_root_floor(u64(x * x + y * y)))
	normal_x = draw_record.divide_rounded(-y * width, 2 * length)
	normal_y = draw_record.divide_rounded(x * width, 2 * length)
	return
}

// square_root_floor gives the largest integer whose square is at most the
// value, bit by bit: the length of a direction, for a writer that places
// points along a line.
square_root_floor :: proc "contextless" (value: u64) -> u64 {
	result: u64
	remaining := value
	bit: u64 = 1 << 62
	for bit > remaining {
		bit >>= 2
	}
	for bit != 0 {
		if remaining >= result + bit {
			remaining -= result + bit
			result = result >> 1 + bit
		} else {
			result >>= 1
		}
		bit >>= 2
	}
	return result
}

// band_line_add adds the signed area of one line segment, in units of the
// surface, to the band: the segment is cut at each row of the band, and
// each piece at each column (band_row_add). A segment with no height adds
// nothing: its area is in the segments that join it.
@(private)
band_line_add :: proc "contextless" (band: ^Path_Band, x0, y0, x1, y1: i64) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	if y0 == y1 {
		return
	}
	sign: i64 = 1
	from_x, from_y, to_x, to_y := x0, y0, x1, y1
	if from_y > to_y {
		sign = -1
		from_x, from_y, to_x, to_y = to_x, to_y, from_x, from_y
	}
	if to_y <= i64(band.top) * UNITS || from_y >= i64(band.bottom) * UNITS || min(from_x, to_x) >= i64(band.right) * UNITS {
		return
	}
	first_row := max(from_y >> draw_record.UNIT_SHIFT, i64(band.top))
	last_row := min((to_y - 1) >> draw_record.UNIT_SHIFT, i64(band.bottom - 1))
	for row in first_row ..= last_row {
		top := max(from_y, row * UNITS)
		bottom := min(to_y, (row + 1) * UNITS)
		if top >= bottom {
			continue
		}
		top_x := segment_x_at(from_x, from_y, to_x, to_y, top)
		bottom_x := segment_x_at(from_x, from_y, to_x, to_y, bottom)
		band_row_add(band, int(row) - band.top, top_x, top, bottom_x, bottom, sign)
	}
}

// segment_x_at gives the x of a segment at a y between its two ends, from
// its top end: a function of the segment and of y only.
@(private)
segment_x_at :: #force_inline proc "contextless" (from_x, from_y, to_x, to_y, y: i64) -> i64 {
	if y == from_y {
		return from_x
	}
	if y == to_y {
		return to_x
	}
	return from_x + draw_record.divide_rounded((to_x - from_x) * (y - from_y), to_y - from_y)
}

// piece_y_at gives the y of a piece at an x between its two ends, from its
// left end: a function of the piece and of x only.
@(private)
piece_y_at :: #force_inline proc "contextless" (left_x, left_y, right_x, right_y, x: i64) -> i64 {
	if x <= left_x {
		return left_y
	}
	if x >= right_x {
		return right_y
	}
	return left_y + draw_record.divide_rounded((right_y - left_y) * (x - left_x), right_x - left_x)
}

// band_row_add adds one piece of a segment inside one row of the band, from
// (top_x, top) to (bottom_x, bottom), top below bottom, with the sign of
// the direction of the segment. The part left of the band adds its height
// to the first cell, which the prefix sum carries to each pixel of the row;
// the part right of the band adds only to pixels past it, and is left out.
// Each cut at a column is the cut of the whole piece, so a band gives each
// of its pixels the sum of one band that holds the whole piece.
@(private)
band_row_add :: proc "contextless" (band: ^Path_Band, line: int, top_x, top, bottom_x, bottom, sign: i64) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	cells := band.cells[line][:]
	left_x, left_y, right_x, right_y := top_x, top, bottom_x, bottom
	if left_x > right_x {
		left_x, left_y, right_x, right_y = bottom_x, bottom, top_x, top
	}
	band_left, band_right := i64(band.left) * UNITS, i64(band.right) * UNITS
	if left_x >= band_right {
		return
	}
	from_x, from_y := left_x, left_y
	if left_x < band_left {
		cut_y := right_y
		if right_x > band_left {
			cut_y = piece_y_at(left_x, left_y, right_x, right_y, band_left)
		}
		cells[0] += i32(abs(cut_y - left_y) * sign * 2 * UNITS)
		if right_x <= band_left {
			return
		}
		from_x, from_y = band_left, cut_y
	}
	end_x, end_y := right_x, right_y
	if right_x > band_right {
		end_x, end_y = band_right, piece_y_at(left_x, left_y, right_x, right_y, band_right)
	}
	first_column := from_x >> draw_record.UNIT_SHIFT
	last_column := max((end_x - 1) >> draw_record.UNIT_SHIFT, first_column)
	for column in first_column ..= last_column {
		to_x, to_y := end_x, end_y
		if column != last_column {
			to_x = (column + 1) * UNITS
			to_y = piece_y_at(left_x, left_y, right_x, right_y, to_x)
		}
		height := abs(to_y - from_y) * sign
		start := column * UNITS
		sum := (from_x - start) + (to_x - start) // 0 to 2 * UNITS.
		index := int(column) - band.left
		cells[index] += i32(height * (2 * UNITS - sum))
		cells[index + 1] += i32(height * sum)
		from_x, from_y = to_x, to_y
	}
}
