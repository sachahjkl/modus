#+build !freestanding
package draw_record

import "core:testing"

// A record of each kind that the border reads, in a box of whole pixels.
// The other cases break one field of one of them.
@(private = "file")
sample_primitives :: proc() -> [12]Draw_Primitive {
	return [12]Draw_Primitive {
		Draw_Nothing{},
		Draw_Rectangle{color = 0x00102030},
		Draw_Vertical_Gradient{top_color = 0x00101010, bottom_color = 0x00202020},
		Draw_Horizontal_Gradient{left_color = 0x00303030, right_color = 0x00404040},
		Draw_Text{first = 3, count = 5, color = 0x00ABCDEF, scale = 2, weight = .Bold},
		Draw_Clip{},
		Draw_Point_Grid{color = 0x0018212D},
		Draw_Folded_Gap{line_color = 0x00505050, track_color = 0x00606060},
		Draw_Picture{memory = 1, first = 7, stride = 40, generation = 9},
		Draw_Text_Grid{first = 8, count = 32, columns = 2},
		Draw_Line{start_x = units_of_pixels(2), start_y = units_of_pixels(3), end_x = units_of_pixels(20), end_y = units_of_pixels(-4), color = 0x00708090, thickness = 3},
		Draw_Interface_Text{first = 0, count = 4, color = 0x00FFFFFF, origin_x = units_of_pixels(12) + UNITS_PER_PIXEL / 3, scale = 1, weight = .Regular},
	}
}

@(private = "file")
sample_record :: proc(primitive: Draw_Primitive) -> Draw_Record {
	return record_of(primitive, 77, units_of_pixels(10), units_of_pixels(20), units_of_pixels(110), units_of_pixels(44))
}

// The kind of each sample, for the messages.
@(private = "file")
sample_kind :: proc(record: Draw_Record) -> Draw_Kind {
	kind, _ := draw_kind_of_word(record.kind)
	return kind
}

// The runs of bytes of the fields of each kind that the kind does not
// name, as offsets in the 24 bytes of the fields.
@(private = "file")
Reserved_Run :: struct {
	offset, size: int,
}

@(private = "file")
reserved_runs_of :: proc(kind: Draw_Kind) -> (runs: [2]Reserved_Run, count: int) {
	switch kind {
	case .None, .Clip:
		return {{0, FIELDS_SIZE}, {}}, 1
	case .Rectangle:
		return {{int(offset_of(Rectangle_Fields, reserved)), size_of(Rectangle_Fields{}.reserved)}, {}}, 1
	case .Vertical_Gradient:
		return {{int(offset_of(Vertical_Gradient_Fields, reserved)), size_of(Vertical_Gradient_Fields{}.reserved)}, {}}, 1
	case .Horizontal_Gradient:
		return {{int(offset_of(Horizontal_Gradient_Fields, reserved)), size_of(Horizontal_Gradient_Fields{}.reserved)}, {}}, 1
	case .Text:
		return {{int(offset_of(Text_Fields, reserved)), size_of(Text_Fields{}.reserved)}, {}}, 1
	case .Point_Grid:
		return {{int(offset_of(Point_Grid_Fields, reserved)), size_of(Point_Grid_Fields{}.reserved)}, {}}, 1
	case .Folded_Gap:
		return {{int(offset_of(Folded_Gap_Fields, reserved)), size_of(Folded_Gap_Fields{}.reserved)}, {}}, 1
	case .Picture:
		return {{int(offset_of(Picture_Fields, memory_reserved)), size_of(Picture_Fields{}.memory_reserved)}, {int(offset_of(Picture_Fields, reserved)), size_of(Picture_Fields{}.reserved)}}, 2
	case .Text_Grid:
		return {{int(offset_of(Text_Grid_Fields, reserved)), size_of(Text_Grid_Fields{}.reserved)}, {}}, 1
	case .Line:
		return {{int(offset_of(Line_Fields, reserved)), size_of(Line_Fields{}.reserved)}, {}}, 1
	case .Interface_Text:
		return {{int(offset_of(Interface_Text_Fields, reserved)), size_of(Interface_Text_Fields{}.reserved)}, {}}, 1
	}
	return {}, 0
}

// Each word that names no kind is refused: one past the largest kind and
// every word after it, up to the largest word of the byte.
@(test)
read_refuses_each_unknown_kind :: proc(t: ^testing.T) {
	refused := 0
	for word in u64(max(Draw_Kind)) + 1 ..= u64(max(u8)) {
		record := sample_record(Draw_Nothing{})
		record.kind = u8(word)
		primitive, problem := read(record)
		testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word %d names no kind, and the border gives %v", word, problem)
		refused += 1
	}
	testing.expect_value(t, refused, int(max(u8)) - int(max(Draw_Kind)))
}

// Each reserved byte of the header is refused, with the smallest and the
// largest value that is not 0, in a record of each kind.
@(test)
read_refuses_each_reserved_byte_of_the_header :: proc(t: ^testing.T) {
	for primitive in sample_primitives() {
		for index in 0 ..< len(Draw_Record{}.reserved) {
			for value in ([2]u8{1, max(u8)}) {
				record := sample_record(primitive)
				record.reserved[index] = value
				_, problem := read(record)
				testing.expectf(t, problem == .Reserved_Not_Zero, "%v: the reserved byte %d is %d, and the border gives %v", sample_kind(record), index, value, problem)
			}
		}
	}
}

// Each byte of the fields that the kind does not name is refused, for each
// kind, with the smallest and the largest value that is not 0.
@(test)
read_refuses_each_byte_that_the_kind_does_not_name :: proc(t: ^testing.T) {
	checked := 0
	for primitive in sample_primitives() {
		base := sample_record(primitive)
		runs, run_count := reserved_runs_of(sample_kind(base))
		testing.expectf(t, run_count > 0, "%v has no reserved run", sample_kind(base))
		for run in runs[:run_count] {
			for index in run.offset ..< run.offset + run.size {
				for value in ([2]u8{1, max(u8)}) {
					record := base
					record.fields[index] = value
					_, problem := read(record)
					testing.expectf(t, problem == .Reserved_Not_Zero, "%v: the byte %d of the fields is %d, and the border gives %v", sample_kind(record), index, value, problem)
					checked += 1
				}
			}
		}
	}
	testing.expect(t, checked > 0)
}

// A box whose right is left of its left, or whose bottom is above its top,
// by one pixel and by the most, is refused for each kind.
@(test)
read_refuses_an_inverted_box :: proc(t: ^testing.T) {
	for primitive in sample_primitives() {
		inverted := [?][4]i32 {
			{units_of_pixels(10), 0, units_of_pixels(9), units_of_pixels(5)},
			{0, units_of_pixels(10), units_of_pixels(5), units_of_pixels(9)},
			{COORDINATE_UNIT_LIMIT, 0, -COORDINATE_UNIT_LIMIT, units_of_pixels(1)},
			{0, COORDINATE_UNIT_LIMIT, units_of_pixels(1), -COORDINATE_UNIT_LIMIT},
		}
		for box in inverted {
			record := record_of(primitive, 0, box[0], box[1], box[2], box[3])
			_, problem := read(record)
			testing.expectf(t, problem == .Box_Inverted, "%v: the box %v, and the border gives %v", sample_kind(record), box, problem)
		}
	}
}

// An edge one pixel past the limit, and at the largest and the smallest
// value of an i32, is refused on each side.
@(test)
read_refuses_a_box_past_the_coordinate_limit :: proc(t: ^testing.T) {
	past := [?]i32{COORDINATE_UNIT_LIMIT + UNITS_PER_PIXEL, -COORDINATE_UNIT_LIMIT - UNITS_PER_PIXEL, max(i32) - (UNITS_PER_PIXEL - 1), min(i32)}
	for value in past {
		for side in 0 ..< 4 {
			box := [4]i32{0, 0, units_of_pixels(4), units_of_pixels(4)}
			box[side] = value
			record := record_of(Draw_Rectangle{color = 1}, 0, box[0], box[1], box[2], box[3])
			_, problem := read(record)
			testing.expectf(t, problem == .Box_Past_Coordinate_Limit, "the edge %d is %d, and the border gives %v", side, value, problem)
		}
	}
}

// An edge that is not a whole pixel is refused: one unit past a pixel, one
// unit before it, and a third of a pixel.
@(test)
read_refuses_a_box_inside_a_pixel :: proc(t: ^testing.T) {
	parts := [?]i32{1, UNITS_PER_PIXEL - 1, UNITS_PER_PIXEL / 3}
	for part in parts {
		for side in 0 ..< 4 {
			box := [4]i32{0, 0, units_of_pixels(4), units_of_pixels(4)}
			box[side] += part
			record := record_of(Draw_Rectangle{color = 1}, 0, box[0], box[1], box[2], box[3])
			_, problem := read(record)
			testing.expectf(t, problem == .Box_Not_On_Whole_Pixels, "the edge %d is %d units, and the border gives %v", side, box[side], problem)
		}
	}
}

// The scale and the weight of a text, one past each bound and at the
// largest value of the byte.
@(test)
read_refuses_a_text_past_its_bounds :: proc(t: ^testing.T) {
	scales := [?]u8{0, TEXT_SCALE_LIMIT + 1, max(u8)}
	weights := [?]u8{u8(max(Font_Weight)) + 1, max(u8)}
	for scale in scales {
		record := sample_record(Draw_Text{first = 0, count = 1, color = 1, scale = 1})
		fields := transmute(Text_Fields)record.fields
		fields.scale = scale
		record.fields = transmute([FIELDS_SIZE]u8)fields
		_, problem := read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "a text of scale %d: %v", scale, problem)
		record = sample_record(Draw_Interface_Text{count = 1, color = 1, origin_x = units_of_pixels(10), scale = 1})
		interface_fields := transmute(Interface_Text_Fields)record.fields
		interface_fields.scale = scale
		record.fields = transmute([FIELDS_SIZE]u8)interface_fields
		_, problem = read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "an interface text of scale %d: %v", scale, problem)
	}
	for weight in weights {
		record := sample_record(Draw_Text{first = 0, count = 1, color = 1, scale = 1})
		fields := transmute(Text_Fields)record.fields
		fields.weight = weight
		record.fields = transmute([FIELDS_SIZE]u8)fields
		_, problem := read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "a text of weight %d: %v", weight, problem)
		record = sample_record(Draw_Interface_Text{count = 1, color = 1, origin_x = units_of_pixels(10), scale = 1})
		interface_fields := transmute(Interface_Text_Fields)record.fields
		interface_fields.weight = weight
		record.fields = transmute([FIELDS_SIZE]u8)interface_fields
		_, problem = read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "an interface text of weight %d: %v", weight, problem)
	}
}

// The count and the origin of a text in the interface font. The box of the
// samples starts at the pixel 10.
@(test)
read_refuses_an_interface_text_past_its_bounds :: proc(t: ^testing.T) {
	counts := [?]u32{INTERFACE_TEXT_LIMIT + 1, max(u32)}
	for count in counts {
		record := sample_record(Draw_Interface_Text{count = count, color = 1, origin_x = units_of_pixels(10), scale = 1})
		_, problem := read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "an interface text of %d bytes: %v", count, problem)
	}
	left := units_of_pixels(10)
	origins := [?]i32 {
		left - UNITS_PER_PIXEL, // One pixel before the box.
		left - UNITS_PER_PIXEL / 3, // A third of a pixel before the box: on a third, and outside.
		left + i32(INK_MARGIN_LIMIT + 1) * UNITS_PER_PIXEL, // One pixel past the largest margin.
		left + 1, // Inside the margin, and not on a third.
		left + UNITS_PER_PIXEL / 3 + 1, // One unit past the first third.
		max(i32),
		min(i32),
	}
	for origin in origins {
		record := sample_record(Draw_Interface_Text{count = 1, color = 1, origin_x = origin, scale = 1})
		_, problem := read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "an interface text whose origin is %d units, for a box at %d: %v", origin, left, problem)
	}
}

// The thickness and each end of a line: 0, one past each bound, the
// largest values, and an end inside a pixel.
@(test)
read_refuses_a_line_past_its_bounds :: proc(t: ^testing.T) {
	thicknesses := [?]u8{0, LINE_THICKNESS_LIMIT + 1, max(u8)}
	for thickness in thicknesses {
		record := sample_record(Draw_Line{thickness = thickness})
		_, problem := read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "a line of thickness %d: %v", thickness, problem)
	}
	ends := [?]i32 {
		units_of_pixels(LINE_COORDINATE_LIMIT + 1),
		units_of_pixels(-LINE_COORDINATE_LIMIT - 1),
		1, // Inside a pixel.
		max(i32),
		min(i32),
	}
	for end in ends {
		for side in 0 ..< 4 {
			coordinates := [4]i32{}
			coordinates[side] = end
			record := sample_record(Draw_Line{start_x = coordinates[0], start_y = coordinates[1], end_x = coordinates[2], end_y = coordinates[3], thickness = 1})
			_, problem := read(record)
			testing.expectf(t, problem == .Field_Past_Bound, "a line whose coordinate %d is %d units: %v", side, end, problem)
		}
	}
}

// The edges that the border accepts: each bound itself. They come after
// the refusals.
@(test)
read_takes_each_bound :: proc(t: ^testing.T) {
	accepted := [?]Draw_Primitive {
		Draw_Text{count = 1, color = 1, scale = 1},
		Draw_Text{count = 1, color = 1, scale = TEXT_SCALE_LIMIT, weight = max(Font_Weight)},
		Draw_Interface_Text{count = INTERFACE_TEXT_LIMIT, color = 1, origin_x = units_of_pixels(10), scale = TEXT_SCALE_LIMIT},
		Draw_Interface_Text{count = 0, color = 1, origin_x = units_of_pixels(10 + INK_MARGIN_LIMIT) + UNITS_PER_PIXEL * 2 / 3, scale = 1, weight = .Bold},
		Draw_Line{start_x = units_of_pixels(-LINE_COORDINATE_LIMIT), start_y = units_of_pixels(LINE_COORDINATE_LIMIT), end_x = units_of_pixels(LINE_COORDINATE_LIMIT), end_y = units_of_pixels(-LINE_COORDINATE_LIMIT), thickness = LINE_THICKNESS_LIMIT},
		Draw_Line{thickness = 1},
	}
	for primitive in accepted {
		record := sample_record(primitive)
		_, problem := read(record)
		testing.expectf(t, problem == .None, "%v at its bound: %v", sample_kind(record), problem)
	}
	edges := [?][4]i32 {
		{-COORDINATE_UNIT_LIMIT, -COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT},
		{0, 0, 0, 0}, // An empty box: a record that draws nothing, and a Clip that ends the cut.
	}
	for box in edges {
		record := record_of(Draw_Rectangle{color = 1}, 0, box[0], box[1], box[2], box[3])
		_, problem := read(record)
		testing.expectf(t, problem == .None, "the box %v: %v", box, problem)
	}
}

// Each kind comes back from its record: the record of what the border
// read is the same bytes, and the kind is the kind of the primitive.
@(test)
a_record_of_each_kind_comes_back_from_the_border :: proc(t: ^testing.T) {
	seen: [Draw_Kind]bool
	for primitive in sample_primitives() {
		record := sample_record(primitive)
		kind, known := draw_kind_of_word(record.kind)
		testing.expect(t, known)
		seen[kind] = true
		read_back, problem := read(record)
		testing.expectf(t, problem == .None, "%v: %v", kind, problem)
		again := record_of(read_back, record.element, record.left, record.top, record.right, record.bottom)
		testing.expectf(t, again == record, "%v: the record of what the border read differs from the record", kind)
	}
	for kind in Draw_Kind {
		testing.expectf(t, seen[kind], "no sample of the kind %v", kind)
	}
	testing.expect_value(t, size_of(Draw_Record), RECORD_SIZE)
}

// A nil primitive is a record of zeros but its box: the kind None. The
// record of zeros is valid: it draws nothing.
@(test)
the_record_of_zeros_is_none :: proc(t: ^testing.T) {
	primitive, problem := read(Draw_Record{})
	testing.expect_value(t, problem, Problem.None)
	_, is_nothing := primitive.(Draw_Nothing)
	testing.expect(t, is_nothing)
	testing.expect(t, record_of(nil, 0, 0, 0, 0, 0) == Draw_Record{})
}

// The range of a text, of an interface text and of a grid moves to another
// first byte, and the other kinds have none.
@(test)
the_byte_place_of_each_kind :: proc(t: ^testing.T) {
	for primitive in sample_primitives() {
		first, count, has_range := byte_range_of(primitive)
		moved := with_byte_place(primitive, first + 100)
		moved_first, moved_count, moved_has_range := byte_range_of(moved)
		testing.expect_value(t, moved_has_range, has_range)
		testing.expect_value(t, moved_count, count)
		if has_range {
			testing.expect_value(t, moved_first, first + 100)
		} else {
			testing.expect(t, sample_record(moved) == sample_record(primitive))
		}
	}
}

// The place of a box in pixels, also for a negative place.
@(test)
pixels_of_a_place :: proc(t: ^testing.T) {
	testing.expect_value(t, pixels_floor(-1), -1)
	testing.expect_value(t, pixels_ceiling(-1), 0)
	testing.expect_value(t, pixels_floor(units_of_pixels(-3)), -3)
	testing.expect_value(t, pixels_ceiling(units_of_pixels(-3)), -3)
	testing.expect_value(t, pixels_floor(UNITS_PER_PIXEL + 1), 1)
	testing.expect_value(t, pixels_ceiling(UNITS_PER_PIXEL + 1), 2)
	testing.expect_value(t, pixels_floor(-COORDINATE_UNIT_LIMIT), -COORDINATE_LIMIT)
}

// Each color field of each kind with a high byte that is not 0, the
// smallest and the largest: the border refuses it, so a record that it
// reads is canonical.
@(test)
read_refuses_a_color_with_a_high_byte :: proc(t: ^testing.T) {
	colored :: proc(color: u32) -> [11]Draw_Primitive {
		line := Draw_Line{start_x = units_of_pixels(1), start_y = units_of_pixels(1), end_x = units_of_pixels(9), end_y = units_of_pixels(1), color = color, thickness = 1}
		return [11]Draw_Primitive {
			Draw_Rectangle{color = color},
			Draw_Vertical_Gradient{top_color = color},
			Draw_Vertical_Gradient{bottom_color = color},
			Draw_Horizontal_Gradient{left_color = color},
			Draw_Horizontal_Gradient{right_color = color},
			Draw_Text{count = 1, color = color, scale = 1},
			Draw_Point_Grid{color = color},
			Draw_Folded_Gap{line_color = color},
			Draw_Folded_Gap{track_color = color},
			line,
			Draw_Interface_Text{count = 1, color = color, origin_x = units_of_pixels(12), scale = 1},
		}
	}
	highs := [2]u32{0x0100_0000, 0xFF00_0000}
	for high in highs {
		refused := colored(high | 0x0012_3456)
		for primitive, index in refused {
			_, problem := read(sample_record(primitive))
			testing.expectf(t, problem == .Field_Past_Bound, "the color field %d with the high byte of %08x: %v", index, high, problem)
		}
	}
	// The same fields with a high byte of 0 are read.
	accepted := colored(0x00FF_FFFF)
	for primitive, index in accepted {
		_, problem := read(sample_record(primitive))
		testing.expectf(t, problem == .None, "the color field %d of 00FFFFFF: %v", index, problem)
	}
}

// An edge one unit past the limit, on each side: the limit is checked
// before the whole pixel.
@(test)
read_refuses_an_edge_one_unit_past_the_limit :: proc(t: ^testing.T) {
	for value in ([2]i32{COORDINATE_UNIT_LIMIT + 1, -COORDINATE_UNIT_LIMIT - 1}) {
		for side in 0 ..< 4 {
			box := [4]i32{-units_of_pixels(4), -units_of_pixels(4), units_of_pixels(4), units_of_pixels(4)}
			box[side] = value
			_, problem := read(record_of(Draw_Rectangle{color = 1}, 0, box[0], box[1], box[2], box[3]))
			testing.expectf(t, problem == .Box_Past_Coordinate_Limit, "the edge %d at %d units: %v", side, value, problem)
		}
	}
}

// The widest box, from one limit to the other: its width and its height in
// units fit an i32, and are the two limits apart.
@(test)
the_widest_box_has_a_width_in_an_i32 :: proc(t: ^testing.T) {
	record := record_of(Draw_Rectangle{color = 1}, 0, -COORDINATE_UNIT_LIMIT, -COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT)
	_, problem := read(record)
	testing.expect_value(t, problem, Problem.None)
	width: i32 = record.right - record.left
	height: i32 = record.bottom - record.top
	testing.expect_value(t, i64(width), 2 * i64(COORDINATE_UNIT_LIMIT))
	testing.expect_value(t, i64(height), 2 * i64(COORDINATE_UNIT_LIMIT))
	testing.expect(t, width > 0 && height > 0, "the width of the widest box wraps")
	// The ink margin past the right edge of the widest box still fits.
	testing.expect(t, i64(record.right) + i64(INK_MARGIN_LIMIT + 1) * UNITS_PER_PIXEL < i64(max(i32)))
}

// The origin of a text in the interface font: at the largest margin, a
// unit past it, and in a box at a negative place, where the part of a
// pixel is read on the two's complement.
@(test)
the_origin_of_an_interface_text_at_its_edges :: proc(t: ^testing.T) {
	left := units_of_pixels(10)
	largest := left + units_of_pixels(INK_MARGIN_LIMIT) + UNITS_PER_PIXEL * 2 / 3
	_, problem := read(sample_record(Draw_Interface_Text{count = 1, color = 1, origin_x = largest, scale = 1}))
	testing.expect_value(t, problem, Problem.None)
	_, problem = read(sample_record(Draw_Interface_Text{count = 1, color = 1, origin_x = largest + 1, scale = 1}))
	testing.expect_value(t, problem, Problem.Field_Past_Bound)
	// A box at -10 pixels and the origin two pixels and a third right of it.
	negative := record_of(Draw_Interface_Text{count = 1, color = 1, origin_x = units_of_pixels(-8) + UNITS_PER_PIXEL / 3, scale = 1}, 0, units_of_pixels(-10), units_of_pixels(-20), units_of_pixels(-2), units_of_pixels(-4))
	_, problem = read(negative)
	testing.expect_value(t, problem, Problem.None)
	off_third := record_of(Draw_Interface_Text{count = 1, color = 1, origin_x = units_of_pixels(-8) + 1, scale = 1}, 0, units_of_pixels(-10), units_of_pixels(-20), units_of_pixels(-2), units_of_pixels(-4))
	_, problem = read(off_third)
	testing.expect_value(t, problem, Problem.Field_Past_Bound)
}

// A record with two faults gives the problem of the first check: the kind,
// the reserved bytes of the header, the limit, the order of the edges, the
// whole pixels, then the fields of the kind, their reserved bytes before
// their bounds.
@(test)
read_states_the_order_of_its_checks :: proc(t: ^testing.T) {
	Case :: struct {
		record:   Draw_Record,
		expected: Problem,
	}
	unknown_and_reserved := sample_record(Draw_Nothing{})
	unknown_and_reserved.kind = u8(max(Draw_Kind)) + 1
	unknown_and_reserved.reserved[0] = 1
	reserved_and_past := record_of(Draw_Rectangle{color = 1}, 0, max(i32) - 63, 0, max(i32) - 63, 0)
	reserved_and_past.reserved[1] = 1
	past_and_inverted := record_of(Draw_Rectangle{color = 1}, 0, COORDINATE_UNIT_LIMIT + UNITS_PER_PIXEL, 0, 0, units_of_pixels(1))
	inverted_and_inside := record_of(Draw_Rectangle{color = 1}, 0, units_of_pixels(4) + 1, 0, 0, units_of_pixels(1))
	inside_and_field := record_of(Draw_Text{count = 1, color = 1, scale = 0}, 0, 1, 0, units_of_pixels(4), units_of_pixels(4))
	field_reserved_and_bound := sample_record(Draw_Text{count = 1, color = 1, scale = 0})
	field_reserved_and_bound.fields[FIELDS_SIZE - 1] = 1
	cases := [?]Case {
		{unknown_and_reserved, .Unknown_Kind},
		{reserved_and_past, .Reserved_Not_Zero},
		{past_and_inverted, .Box_Past_Coordinate_Limit},
		{inverted_and_inside, .Box_Inverted},
		{inside_and_field, .Box_Not_On_Whole_Pixels},
		{field_reserved_and_bound, .Reserved_Not_Zero},
	}
	for item, index in cases {
		_, problem := read(item.record)
		testing.expectf(t, problem == item.expected, "the case %d: %v, not %v", index, problem, item.expected)
	}
}
