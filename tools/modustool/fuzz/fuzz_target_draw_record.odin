package fuzz

import "core:mem"
import "modus:contract/draw_record"

// The fuzz target of the draw record (src/md/api/draw_table.md, "The
// record: a header and the fields of one kind"): the drawing module and the
// compositor read the records of a draw table that another body of code
// wrote, through one border. The input is records of 48 bytes, one after
// the other; the same bytes are also read as the points of a path, 12
// bytes each, through the border of the points.

// fuzz_draw_record_execute: the border gives a problem of its enumeration;
// a record that it reads has a box that is not inverted, inside the limit,
// and on whole pixels but for a rectangle with no pattern and a gradient,
// a gradient with valid points, a path with valid fields, a text and a grid with a size in its bounds, keeps the
// canonical rule of its colors (draw_color_problem),
// writes back to its own bytes, and keeps its bytes
// when its range moves to its own first byte; a record that it refuses
// changes no byte of the input. Then the points (fuzz_path_points_problem),
// and the order of the clips of the records (fuzz_clip_order_problem).
fuzz_draw_record_execute :: proc(input: []u8) -> Fuzz_Verdict {
	if points_problem := fuzz_path_points_problem(input); points_problem != "" {
		return fuzz_broken(.Contract, "the points: %s", points_problem)
	}
	if order_problem := fuzz_clip_order_problem(input); order_problem != "" {
		return fuzz_broken(.Contract, "the order of the clips: %s", order_problem)
	}
	count := len(input) / draw_record.RECORD_SIZE
	for index in 0 ..< count {
		record: draw_record.Draw_Record
		mem.copy(&record, &input[index * draw_record.RECORD_SIZE], draw_record.RECORD_SIZE)
		kept := record
		primitive, problem := draw_record.read(record)
		if problem > max(draw_record.Problem) {
			return fuzz_broken(.Contract, "the record %d: read gives a problem out of its enumeration: %d", index, u8(problem))
		}
		if record != kept {
			return fuzz_broken(.Contract, "the record %d: read changed the record that it took", index)
		}
		if problem != .None {
			if primitive != nil {
				return fuzz_broken(.Contract, "the record %d: read refuses it with %v and gives a primitive", index, problem)
			}
			continue
		}
		if primitive == nil {
			return fuzz_broken(.Contract, "the record %d: read takes it and gives no primitive", index)
		}
		// Only a rectangle with no pattern and a gradient draw inside a
		// pixel; each other kind is on whole pixels.
		inside_a_pixel := false
		switch value in primitive {
		case draw_record.Draw_Rectangle:
			inside_a_pixel = value.repetition == (draw_record.Repetition{})
		case draw_record.Draw_Gradient:
			inside_a_pixel = true
			if !draw_record.gradient_line_valid(value) {
				return fuzz_broken(.Contract, "the record %d: read takes a gradient whose points are equal, past the limit or too far apart", index)
			}
		case draw_record.Draw_Path:
			if !draw_record.path_fields_valid(value) {
				return fuzz_broken(.Contract, "the record %d: read takes a path whose range or stroke is out of its bounds", index)
			}
		case draw_record.Draw_Clip_Pop:
			if record.left != 0 || record.top != 0 || record.right != 0 || record.bottom != 0 {
				return fuzz_broken(.Contract, "the record %d: read takes a pop of a clip whose box is not 0", index)
			}
		case draw_record.Draw_Text:
			if int(value.size) < draw_record.TEXT_SIZE_MINIMUM || int(value.size) > draw_record.TEXT_SIZE_LIMIT {
				return fuzz_broken(.Contract, "the record %d: read takes a text of size %d, out of its bounds", index, value.size)
			}
		case draw_record.Draw_Text_Grid:
			if int(value.size) < draw_record.TEXT_SIZE_MINIMUM || int(value.size) > draw_record.TEXT_SIZE_LIMIT {
				return fuzz_broken(.Contract, "the record %d: read takes a grid of size %d, out of its bounds", index, value.size)
			}
		case draw_record.Draw_Nothing, draw_record.Draw_Clip_Push, draw_record.Draw_Picture:
		}
		edges := [4]i32{record.left, record.top, record.right, record.bottom}
		for edge in edges {
			if !draw_record.inside_coordinate_limit(edge) || (!inside_a_pixel && !draw_record.on_whole_pixel(edge)) {
				return fuzz_broken(.Contract, "the record %d: read takes the edge %d, past the limit or inside a pixel", index, edge)
			}
		}
		if record.right < record.left || record.bottom < record.top {
			return fuzz_broken(.Contract, "the record %d: read takes the inverted box %d, %d, %d, %d", index, record.left, record.top, record.right, record.bottom)
		}
		// A color that draws nothing has one form, and no stroke has one
		// form.
		if color_problem := draw_color_problem(primitive); color_problem != "" {
			return fuzz_broken(.Contract, "the record %d: read takes %s", index, color_problem)
		}
		written := draw_record.record_of(primitive, record.element, record.left, record.top, record.right, record.bottom)
		if written != record {
			return fuzz_broken(.Round_Trip, "the record %d: the record of what read gave is other bytes", index)
		}
		if first, _, has_range := draw_record.byte_range_of(primitive); has_range {
			moved := draw_record.record_of(draw_record.with_byte_place(primitive, first), record.element, record.left, record.top, record.right, record.bottom)
			if moved != record {
				return fuzz_broken(.Round_Trip, "the record %d: a range moved to its own first byte is other bytes", index)
			}
		}
	}
	return FUZZ_PASSED
}

// draw_color_problem says how the colors of a primitive that the border read
// break the canonical rule, or "": a rectangle of alpha 0 whose color is not
// 0, a gradient whose two ends have alpha 0 and are not both 0, a text of
// alpha 0 whose color is not 0, a path whose fill or stroke has alpha 0 and
// is not 0, or whose stroke color and stroke width are not both 0 or both
// set.
draw_color_problem :: proc(primitive: draw_record.Draw_Primitive) -> string {
	transparent :: proc(color: draw_record.Draw_Color) -> bool {
		return draw_record.alpha_of(color) == 0
	}
	switch value in primitive {
	case draw_record.Draw_Rectangle:
		if transparent(value.color) && value.color != 0 {
			return "a rectangle of alpha 0 whose color is not 0"
		}
	case draw_record.Draw_Gradient:
		if transparent(value.start_color) && transparent(value.end_color) && (value.start_color != 0 || value.end_color != 0) {
			return "a gradient whose two ends have alpha 0 and are not both 0"
		}
	case draw_record.Draw_Text:
		if transparent(value.color) && value.color != 0 {
			return "a text of alpha 0 whose color is not 0"
		}
	case draw_record.Draw_Path:
		if (transparent(value.fill_color) && value.fill_color != 0) || (transparent(value.stroke_color) && value.stroke_color != 0) {
			return "a path with a color of alpha 0 that is not 0"
		}
		if (value.stroke_color == 0) != (value.stroke_width == 0) {
			return "a path whose stroke has a width and no color, or a color and no width"
		}
	case draw_record.Draw_Nothing, draw_record.Draw_Clip_Push, draw_record.Draw_Clip_Pop, draw_record.Draw_Picture, draw_record.Draw_Text_Grid:
	}
	return ""
}

// fuzz_clip_order_problem reads the input as records, and says how the
// border of the order of the clips breaks its rules, or "": a problem out of
// its enumeration, an index past the records, a change of a byte of the
// input, and a verdict other than a walk of the kind words that counts the
// pushes open and stops at the first fault: a pop with no push open, a push
// with CLIP_DEPTH_LIMIT open, or pushes open at the end, with the index of
// the outermost one.
fuzz_clip_order_problem :: proc(input: []u8) -> string {
	count := len(input) / draw_record.RECORD_SIZE
	records := make([]draw_record.Draw_Record, count, context.temp_allocator)
	if count > 0 {
		mem.copy(&records[0], &input[0], count * draw_record.RECORD_SIZE)
	}
	kept := make([]draw_record.Draw_Record, count, context.temp_allocator)
	copy(kept, records)
	problem, index := draw_record.clip_order_check(records)
	if problem > max(draw_record.Clip_Order_Problem) {
		return "a problem out of its enumeration"
	}
	for record, place in records {
		if record != kept[place] {
			return "the check changed a record"
		}
	}
	expected := draw_record.Clip_Order_Problem.None
	expected_index, depth, outermost := 0, 0, 0
	walk: for record, place in records {
		switch record.kind {
		case u8(draw_record.Draw_Kind.Clip_Push):
			if depth == draw_record.CLIP_DEPTH_LIMIT {
				expected, expected_index = .Push_Past_Depth_Limit, place
				break walk
			}
			if depth == 0 {
				outermost = place
			}
			depth += 1
		case u8(draw_record.Draw_Kind.Clip_Pop):
			if depth == 0 {
				expected, expected_index = .Pop_Without_Push, place
				break walk
			}
			depth -= 1
		}
	}
	if expected == .None && depth > 0 {
		expected, expected_index = .Push_Without_Pop, outermost
	}
	if problem != expected {
		return "a verdict other than the walk of the kind words"
	}
	if problem != .None && (index != expected_index || index >= count) {
		return "the index of another record"
	}
	return ""
}

// fuzz_path_points_problem reads the input as points of a path, as many as
// the border takes and one more, and says how the border of the points
// breaks its rules, or "": a problem out of its enumeration, a check with
// no copy that gives another problem, a refusal that gives a count; and for
// points that it reads, a first point that is not a Move, a command after
// another that the order forbids, a point past the limit, a Close whose
// place is not 0, a last point that ends no subpath, and a curve whose
// segments are not 1 to CURVE_SEGMENT_LIMIT, leave the box of its three
// points, or do not end at its end.
fuzz_path_points_problem :: proc(input: []u8) -> string {
	records: [draw_record.PATH_POINT_LIMIT + 1]draw_record.Path_Point_Record
	count := min(len(input) / draw_record.PATH_POINT_SIZE, len(records))
	if count > 0 {
		mem.copy(&records[0], &input[0], count * draw_record.PATH_POINT_SIZE)
	}
	points: [draw_record.PATH_POINT_LIMIT + 1]draw_record.Path_Point
	read_count, problem := draw_record.path_points_read(records[:count], points[:])
	if problem > max(draw_record.Path_Problem) {
		return "a problem out of its enumeration"
	}
	if draw_record.path_points_check(records[:count]) != problem {
		return "the check with no copy gives another problem than the read"
	}
	if problem != .None {
		return read_count == 0 ? "" : "a refusal that gives a count"
	}
	if read_count != count || count < 2 || count > draw_record.PATH_POINT_LIMIT {
		return "a read of a count of points out of its bounds"
	}
	if points[0].command != .Move {
		return "a path that does not start with a Move"
	}
	for point, index in points[:count] {
		if !draw_record.inside_coordinate_limit(point.x) || !draw_record.inside_coordinate_limit(point.y) {
			return "a point past the limit"
		}
		if point.command == .Close && (point.x != 0 || point.y != 0) {
			return "a Close whose place is not 0"
		}
		next: draw_record.Path_Command = .Move
		is_last := index + 1 == count
		if !is_last {
			next = points[index + 1].command
		}
		switch point.command {
		case .Move:
			if is_last || (next != .Line && next != .Curve_Control) {
				return "a Move with no segment after it"
			}
		case .Curve_Control:
			if is_last || next != .Line {
				return "a Curve_Control with no Line after it"
			}
			start := points[index - 1]
			if start.command == .Close {
				return "a curve that starts at a Close"
			}
			end := points[index + 1]
			segments := draw_record.curve_segment_count(start.x, start.y, point.x, point.y, end.x, end.y)
			if segments < 1 || segments > draw_record.CURVE_SEGMENT_LIMIT {
				return "a curve cut into a count of segments out of its bounds"
			}
			for step in 0 ..= segments {
				x, y := draw_record.curve_point(start.x, start.y, point.x, point.y, end.x, end.y, step, segments)
				if x < min(start.x, point.x, end.x) || x > max(start.x, point.x, end.x) || y < min(start.y, point.y, end.y) || y > max(start.y, point.y, end.y) {
					return "a point of a curve outside the box of its three points"
				}
				if step == segments && (x != end.x || y != end.y) {
					return "a curve whose last segment does not end at its end"
				}
			}
		case .Close:
			if points[index - 1].command != .Line || next != .Move {
				return "a Close out of its place"
			}
		case .Line:
		}
	}
	return ""
}

// One record of each kind, in a box of whole pixels, the forms of a color
// with alpha (a translucent rectangle, a gradient that fades to its color
// with alpha 0, a picture with alpha, a translucent text), and a rectangle
// and a gradient in a box inside the pixels.
fuzz_draw_record_seeds :: proc(seeds: ^[dynamic][]u8) {
	pixel :: draw_record.units_of_pixels
	opaque :: draw_record.opaque
	half :: draw_record.UNITS_PER_PIXEL / 2
	primitives := [?]draw_record.Draw_Primitive {
		draw_record.Draw_Nothing{},
		draw_record.Draw_Rectangle{color = opaque(0x00102030)},
		draw_record.Draw_Gradient{start_x = pixel(0), start_y = pixel(0) + half, end_x = pixel(0), end_y = pixel(15) + half, start_color = opaque(1), end_color = opaque(2)},
		draw_record.Draw_Gradient{start_x = pixel(0) + half, start_y = pixel(0), end_x = pixel(15) + half, end_y = pixel(0), start_color = opaque(3), end_color = opaque(4)},
		draw_record.Draw_Gradient{start_x = pixel(1), start_y = pixel(2) + 5, end_x = pixel(14) + 17, end_y = pixel(13), start_color = opaque(3), end_color = draw_record.with_alpha(4, 60)},
		draw_record.Draw_Text{first = 0, count = 4, color = draw_record.with_alpha(5, 128), size = 16 * draw_record.UNITS_PER_PIXEL},
		draw_record.Draw_Text{first = 0, count = 4, color = opaque(5), size = 16 * draw_record.UNITS_PER_PIXEL},
		draw_record.Draw_Clip_Push{},
		// The grid of points: a pattern of cells of 2 pixels each 24 pixels.
		draw_record.Draw_Rectangle{color = opaque(6), repetition = {cell_x = pixel(12), cell_y = pixel(12), cell_width = 2 * draw_record.UNITS_PER_PIXEL, cell_height = 2 * draw_record.UNITS_PER_PIXEL, step_x = 24 * draw_record.UNITS_PER_PIXEL, step_y = 24 * draw_record.UNITS_PER_PIXEL}},
		draw_record.Draw_Picture{first = 0, stride = 16, generation = 1},
		draw_record.Draw_Text_Grid{first = 0, count = 32, columns = 2, size = 16 * draw_record.UNITS_PER_PIXEL},
		draw_record.Draw_Path{first = 0, count = 5 * draw_record.PATH_POINT_SIZE, fill_color = draw_record.with_alpha(9, 128), stroke_color = opaque(9), stroke_width = 2 * draw_record.UNITS_PER_PIXEL},
		draw_record.Draw_Path{first = 4, count = 2 * draw_record.PATH_POINT_SIZE, fill_color = opaque(11)},
		draw_record.Draw_Text{first = 0, count = 4, color = opaque(10), origin_x = pixel(2) + draw_record.UNITS_PER_PIXEL / 3, font = .Interface, size = 16 * draw_record.UNITS_PER_PIXEL, weight = .Bold},
		draw_record.Draw_Rectangle{color = draw_record.with_alpha(0x00102030, 128)},
		draw_record.Draw_Gradient{start_x = pixel(0), start_y = pixel(0) + half, end_x = pixel(0), end_y = pixel(15) + half, start_color = draw_record.Draw_Color(0x00405060), end_color = opaque(0x00405060)},
		draw_record.Draw_Picture{format = .Straight_Alpha, first = 0, stride = 16, generation = 1},
	}
	// The boxes inside the pixels: a third and two thirds of a pixel.
	inside := [2]draw_record.Draw_Primitive {
		draw_record.Draw_Rectangle{color = draw_record.with_alpha(0x00102030, 200)},
		draw_record.Draw_Gradient{start_x = pixel(1), start_y = pixel(1), end_x = pixel(9), end_y = pixel(12) + 3, start_color = opaque(7), end_color = opaque(8)},
	}
	all := make([]u8, (len(primitives) + len(inside)) * draw_record.RECORD_SIZE)
	place := 0
	add :: proc(into_seeds: ^[dynamic][]u8, into_all: []u8, count: ^int, record: draw_record.Draw_Record) {
		record_copy := record
		mem.copy(&into_all[count^ * draw_record.RECORD_SIZE], &record_copy, draw_record.RECORD_SIZE)
		count^ += 1
		one := make([]u8, draw_record.RECORD_SIZE)
		mem.copy(&one[0], &record_copy, draw_record.RECORD_SIZE)
		append(into_seeds, one)
	}
	for primitive, index in primitives {
		add(seeds, all, &place, draw_record.record_of(primitive, u32(index), 0, 0, pixel(16), pixel(16)))
	}
	for primitive, index in inside {
		add(seeds, all, &place, draw_record.record_of(primitive, u32(len(primitives) + index), 21, pixel(1) + 42, pixel(15) + 21, pixel(14) + 43))
	}
	append(seeds, all)
	// The clips: a pop alone, and a push, a rectangle and a pop, in order.
	pop := draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0)
	one_pop := make([]u8, draw_record.RECORD_SIZE)
	mem.copy(&one_pop[0], &pop, draw_record.RECORD_SIZE)
	append(seeds, one_pop)
	nested := [3]draw_record.Draw_Record {
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, pixel(2), pixel(2), pixel(10), pixel(10)),
		draw_record.record_of(draw_record.Draw_Rectangle{color = opaque(12)}, 0, 0, 0, pixel(16), pixel(16)),
		pop,
	}
	in_order := make([]u8, len(nested) * draw_record.RECORD_SIZE)
	mem.copy(&in_order[0], &nested[0], len(in_order))
	append(seeds, in_order)
	// The points of a path that the border of the points reads: a subpath
	// with a line, a curve and a Close, then an open subpath of one line.
	path := [?]draw_record.Path_Point_Record {
		{command = u32(draw_record.Path_Command.Move), x = pixel(1), y = pixel(1)},
		{command = u32(draw_record.Path_Command.Line), x = pixel(9), y = pixel(1) + 5},
		{command = u32(draw_record.Path_Command.Curve_Control), x = pixel(30), y = pixel(-20)},
		{command = u32(draw_record.Path_Command.Line), x = pixel(5), y = pixel(12)},
		{command = u32(draw_record.Path_Command.Close)},
		{command = u32(draw_record.Path_Command.Move), x = -draw_record.COORDINATE_UNIT_LIMIT, y = draw_record.COORDINATE_UNIT_LIMIT},
		{command = u32(draw_record.Path_Command.Line), x = draw_record.COORDINATE_UNIT_LIMIT, y = -draw_record.COORDINATE_UNIT_LIMIT},
	}
	points := make([]u8, len(path) * draw_record.PATH_POINT_SIZE)
	mem.copy(&points[0], &path[0], len(points))
	append(seeds, points)
}

fuzz_draw_record_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	count := len(input) / draw_record.RECORD_SIZE
	if count > 0 {
		append(regions, Fuzz_Region{offset = 0, type = draw_record.Draw_Record, count = count})
	}
}
