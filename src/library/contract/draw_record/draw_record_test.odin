#+build !freestanding
package draw_record

import "core:testing"

// A record of each kind that the border reads, in a box of whole pixels.
// The other cases break one field of one of them.
@(private = "file")
sample_primitives :: proc() -> [11]Draw_Primitive {
	return [11]Draw_Primitive {
		Draw_Nothing{},
		Draw_Rectangle{color = 0xFF102030},
		Draw_Rectangle{color = 0xFF18212D, repetition = SAMPLE_PATTERN},
		Draw_Gradient{start_x = units_of_pixels(10), start_y = units_of_pixels(20) + 32, end_x = units_of_pixels(10), end_y = units_of_pixels(43) + 32, start_color = 0xFF101010, end_color = 0xFF202020},
		Draw_Gradient{start_x = units_of_pixels(10) + 5, start_y = units_of_pixels(25), end_x = units_of_pixels(90) + 7, end_y = units_of_pixels(40) + 1, start_color = 0xFF303030, end_color = 0x80404040},
		Draw_Text{origin_x = units_of_pixels(10), first = 3, count = 5, color = 0xFFABCDEF, scale = 2, weight = .Bold},
		Draw_Clip{},
		Draw_Picture{memory = 1, first = 7, stride = 40, generation = 9},
		Draw_Text_Grid{first = 8, count = 32, columns = 2},
		Draw_Line{start_x = units_of_pixels(2), start_y = units_of_pixels(3), end_x = units_of_pixels(20), end_y = units_of_pixels(-4), color = 0xFF708090, thickness = 3},
		Draw_Text{font = .Interface, first = 0, count = 4, color = 0xFFFFFFFF, origin_x = units_of_pixels(12) + UNITS_PER_PIXEL / 3, scale = 1, weight = .Regular},
	}
}

// The pattern of the grid of points of the background: cells of 2 pixels,
// one each 24 pixels, the first at 12 pixels of the surface.
SAMPLE_PATTERN :: Repetition {
	cell_x      = 12 * UNITS_PER_PIXEL,
	cell_y      = 12 * UNITS_PER_PIXEL,
	cell_width  = 2 * UNITS_PER_PIXEL,
	cell_height = 2 * UNITS_PER_PIXEL,
	step_x      = 24 * UNITS_PER_PIXEL,
	step_y      = 24 * UNITS_PER_PIXEL,
}

// An opaque color of the cases that test another field.
SAMPLE_COLOR :: Draw_Color(OPAQUE_ALPHA << ALPHA_SHIFT | 1)

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
	case .Gradient:
		// Each byte of the fields of a gradient is named.
		return {}, 0
	case .Text:
		return {{int(offset_of(Text_Fields, reserved)), size_of(Text_Fields{}.reserved)}, {}}, 1
	case .Picture:
		return {{int(offset_of(Picture_Fields, memory_reserved)), size_of(Picture_Fields{}.memory_reserved)}, {int(offset_of(Picture_Fields, reserved)), size_of(Picture_Fields{}.reserved)}}, 2
	case .Text_Grid:
		return {{int(offset_of(Text_Grid_Fields, reserved)), size_of(Text_Grid_Fields{}.reserved)}, {}}, 1
	case .Line:
		return {{int(offset_of(Line_Fields, reserved)), size_of(Line_Fields{}.reserved)}, {}}, 1
	}
	return {}, 0
}

// The words of the two kinds that left the format, the grid of points (6)
// and the folded gap (7), name no kind: a record of the form of version 11
// with one of them is refused, with each byte of its fields 0 and with
// the color that it held.
@(test)
read_refuses_the_words_of_the_kinds_that_left :: proc(t: ^testing.T) {
	POINT_GRID_WORD :: 6
	FOLDED_GAP_WORD :: 7
	words := [2]u8{POINT_GRID_WORD, FOLDED_GAP_WORD}
	for word in words {
		_, known := draw_kind_of_word(word)
		testing.expectf(t, !known, "the word %d names a kind", word)
		record := sample_record(Draw_Nothing{})
		record.kind = word
		primitive, problem := read(record)
		testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word %d: %v", word, problem)
		record.fields[0] = 0x2D
		record.fields[1] = 0x21
		record.fields[2] = 0x18
		primitive, problem = read(record)
		testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word %d with a color: %v", word, problem)
	}
}

// The words of the vertical (2) and the horizontal (3) gradient, which
// became one Gradient, name no kind: a record of the form of version 14,
// with two opaque colors and the rest 0, is refused with each word. The
// same bytes with the word of the Gradient are refused too: read as points,
// the two opaque colors are a first point at 0xFF000000 units on each axis
// (-2^24, inside the limit) and the zeros a second point at 0, a span of
// 2^24 units, past GRADIENT_SPAN_LIMIT.
@(test)
read_refuses_the_words_of_the_two_gradients :: proc(t: ^testing.T) {
	VERTICAL_GRADIENT_WORD :: 2
	HORIZONTAL_GRADIENT_WORD :: 3
	words := [2]u8{VERTICAL_GRADIENT_WORD, HORIZONTAL_GRADIENT_WORD}
	old_fields: [FIELDS_SIZE]u8
	old_fields[3], old_fields[7] = 0xFF, 0xFF
	for word in words {
		_, known := draw_kind_of_word(word)
		testing.expectf(t, !known, "the word %d names a kind", word)
		record := sample_record(Draw_Nothing{})
		record.kind = word
		record.fields = old_fields
		primitive, problem := read(record)
		testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word %d: %v", word, problem)
	}
	as_gradient := sample_record(Draw_Nothing{})
	as_gradient.kind = u8(Draw_Kind.Gradient)
	as_gradient.fields = old_fields
	primitive, problem := read(as_gradient)
	testing.expectf(t, problem == .Field_Past_Bound && primitive == nil, "the bytes of an old gradient as a Gradient: %v", problem)
	// The refusal is for the span: the points are inside the limit and
	// differ, and the same points one span apart are read.
	fields := transmute(Gradient_Fields)as_gradient.fields
	testing.expect_value(t, fields.start_x, i32(-1 << 24))
	testing.expect_value(t, fields.start_y, i32(-1 << 24))
	testing.expect(t, inside_coordinate_limit(fields.start_x) && fields.start_x != fields.end_x, "the old bytes are not two different points inside the limit")
	testing.expect(t, i64(fields.end_x) - i64(fields.start_x) > GRADIENT_SPAN_LIMIT * UNITS_PER_PIXEL, "the old bytes are not past the span")
	fields.end_x = fields.start_x + GRADIENT_SPAN_LIMIT * UNITS_PER_PIXEL
	fields.end_y = fields.start_y
	as_gradient.fields = transmute([FIELDS_SIZE]u8)fields
	_, within := read(as_gradient)
	testing.expectf(t, within == .None, "the old colors as points one span apart: %v", within)
}

// The two points of a gradient, each other field valid: equal points are
// refused, at each place, also with other colors; a span on one axis of
// GRADIENT_SPAN_LIMIT pixels is read and one unit more is refused, on each
// axis and in each direction; a point past COORDINATE_LIMIT is refused, at
// the limit it is read.
@(test)
read_refuses_the_points_of_a_gradient_out_of_their_bounds :: proc(t: ^testing.T) {
	colors := gradient_of_colors(opaque(0x0010_2030), opaque(0x00F0_E0D0))
	equal_places := [4]i32{0, 1, -COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT}
	for place in equal_places {
		gradient := colors
		gradient.start_x, gradient.start_y, gradient.end_x, gradient.end_y = place, place / 2, place, place / 2
		_, problem := read(sample_record(gradient))
		testing.expectf(t, problem == .Field_Past_Bound, "two equal points at %d: %v", place, problem)
	}
	SPAN :: GRADIENT_SPAN_LIMIT * UNITS_PER_PIXEL
	directions := [2]i32{1, -1}
	extras := [2]i32{0, 1}
	for axis in 0 ..< 2 {
		for direction in directions {
			for extra in extras {
				gradient := colors
				gradient.start_x, gradient.start_y = 0, 0
				gradient.end_x, gradient.end_y = 0, 0
				distance := direction * (SPAN + extra)
				if axis == 0 {
					gradient.end_x = distance
				} else {
					gradient.end_y = distance
				}
				_, problem := read(sample_record(gradient))
				expected := extra == 0 ? Problem.None : Problem.Field_Past_Bound
				testing.expectf(t, problem == expected, "a span of %d units on the axis %d: %v", distance, axis, problem)
			}
		}
	}
	limits := [4]i32{COORDINATE_UNIT_LIMIT, -COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT + 1, -COORDINATE_UNIT_LIMIT - 1}
	for limit, index in limits {
		gradient := colors
		gradient.start_x, gradient.start_y = limit, limit
		gradient.end_x, gradient.end_y = limit - (limit > 0 ? UNITS_PER_PIXEL : -UNITS_PER_PIXEL), limit
		_, problem := read(sample_record(gradient))
		expected := index < 2 ? Problem.None : Problem.Field_Past_Bound
		testing.expectf(t, problem == expected, "a point at %d: %v", limit, problem)
	}
	// The second point alone past the limit, one unit past it and at the
	// largest and the smallest i32, the first point inside: refused.
	past_ends := [4]i32{COORDINATE_UNIT_LIMIT + 1, -COORDINATE_UNIT_LIMIT - 1, max(i32), min(i32)}
	for end in past_ends {
		for axis in 0 ..< 2 {
			gradient := colors
			gradient.start_x, gradient.start_y = 0, 0
			gradient.end_x, gradient.end_y = 0, 0
			if axis == 0 {
				gradient.end_x = end
			} else {
				gradient.end_y = end
			}
			_, problem := read(sample_record(gradient))
			testing.expectf(t, problem == .Field_Past_Bound, "a second point at %d on the axis %d: %v", end, axis, problem)
		}
	}
	// The first point alone at the largest i32.
	largest := colors
	largest.start_x, largest.start_y, largest.end_x, largest.end_y = max(i32), 0, 0, 0
	_, problem := read(sample_record(largest))
	testing.expectf(t, problem == .Field_Past_Bound, "a first point at the largest i32: %v", problem)
}

// The level of a gradient: on an axis with the points at the centers of the
// first and the last of h lines, the line r has r * 255 / (h - 1), each r of
// each h from 2 to 300; before the first point it is 0 and past the second
// GRADIENT_LEVELS. At the far ends of the bounds, with the largest span and
// the farthest pixel, it equals the level computed in 128 bits: no product
// wraps.
@(test)
gradient_level_of_each_line_and_at_the_bounds :: proc(t: ^testing.T) {
	HALF :: UNITS_PER_PIXEL / 2
	wrong := 0
	for height in 2 ..= 300 {
		gradient := Draw_Gradient{start_x = 0, start_y = HALF, end_x = 0, end_y = i32(height - 1) * UNITS_PER_PIXEL + HALF}
		for line in 0 ..< height {
			level := gradient_level(gradient, 0, i64(line) * UNITS_PER_PIXEL + HALF)
			wrong += int(level != u32(line * 255 / (height - 1)))
		}
		wrong += int(gradient_level(gradient, 0, -1000 * UNITS_PER_PIXEL) != 0)
		wrong += int(gradient_level(gradient, 0, i64(height + 1000) * UNITS_PER_PIXEL) != GRADIENT_LEVELS)
	}
	testing.expect_value(t, wrong, 0)
	SPAN :: GRADIENT_SPAN_LIMIT * UNITS_PER_PIXEL
	extremes := [?]Draw_Gradient {
		{start_x = -COORDINATE_UNIT_LIMIT, start_y = -COORDINATE_UNIT_LIMIT, end_x = -COORDINATE_UNIT_LIMIT + SPAN, end_y = -COORDINATE_UNIT_LIMIT + SPAN},
		{start_x = COORDINATE_UNIT_LIMIT, start_y = COORDINATE_UNIT_LIMIT, end_x = COORDINATE_UNIT_LIMIT - SPAN, end_y = COORDINATE_UNIT_LIMIT - 7},
		{start_x = 0, start_y = 0, end_x = SPAN, end_y = -SPAN},
		{start_x = 3, start_y = 0, end_x = 2, end_y = 0},
	}
	places := [?]i64{-COORDINATE_UNIT_LIMIT, -COORDINATE_UNIT_LIMIT / 3, 0, 17, COORDINATE_UNIT_LIMIT / 2 + 5, COORDINATE_UNIT_LIMIT}
	for gradient, index in extremes {
		testing.expectf(t, gradient_line_valid(gradient), "the gradient %d is not valid", index)
		for x in places {
			for y in places {
				direction_x := i128(gradient.end_x) - i128(gradient.start_x)
				direction_y := i128(gradient.end_y) - i128(gradient.start_y)
				along := (i128(x) - i128(gradient.start_x)) * direction_x + (i128(y) - i128(gradient.start_y)) * direction_y
				length := direction_x * direction_x + direction_y * direction_y
				expected := along <= 0 ? 0 : along >= length ? GRADIENT_LEVELS : u32(along * GRADIENT_LEVELS / length)
				level := gradient_level(gradient, x, y)
				testing.expectf(t, level == expected, "the gradient %d at %d, %d: %d, not %d", index, x, y, level, expected)
			}
		}
	}
}

// The word of the kind Interface_Text (11), which became a Text with the
// interface font, names no kind: a record of the form of version 12 with
// it is refused, with its fields zero and with the fields of a text that
// the border reads as a Text.
@(test)
read_refuses_the_word_of_the_interface_text :: proc(t: ^testing.T) {
	INTERFACE_TEXT_WORD :: 11
	_, known := draw_kind_of_word(INTERFACE_TEXT_WORD)
	testing.expect(t, !known, "the word 11 names a kind")
	record := sample_record(Draw_Nothing{})
	record.kind = INTERFACE_TEXT_WORD
	primitive, problem := read(record)
	testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word 11: %v", problem)
	text := sample_record(Draw_Text{count = 4, color = 0xFFFFFFFF, origin_x = units_of_pixels(12) + UNITS_PER_PIXEL / 3, font = .Interface, scale = 1})
	_, problem = read(text)
	testing.expect_value(t, problem, Problem.None)
	text.kind = INTERFACE_TEXT_WORD
	primitive, problem = read(text)
	testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word 11 with the fields of a text: %v", problem)
}

// The font of a text: each word that names no font is refused, one past
// the largest and the largest word of the byte; then each font is read.
@(test)
read_refuses_a_font_that_names_no_member :: proc(t: ^testing.T) {
	refused := 0
	for word in 0 ..= u64(max(u8)) {
		record := sample_record(Draw_Text{count = 1, color = SAMPLE_COLOR, origin_x = units_of_pixels(10), scale = 1})
		fields := transmute(Text_Fields)record.fields
		fields.font = u8(word)
		record.fields = transmute([FIELDS_SIZE]u8)fields
		_, problem := read(record)
		if _, known := font_kind_of_word(u8(word)); known {
			testing.expectf(t, problem == .None, "the font %d: %v", word, problem)
			continue
		}
		testing.expectf(t, problem == .Field_Past_Bound, "the word %d names no font, and the border gives %v", word, problem)
		refused += 1
	}
	testing.expect_value(t, refused, int(max(u8)) + 1 - len(Font_Kind))
}

// The bounds that depend on the font: the font of the cells draws from a
// whole pixel and has no bound of bytes; the interface font draws from a
// third of a pixel and has at most INTERFACE_TEXT_LIMIT bytes.
@(test)
read_takes_the_bounds_of_each_font :: proc(t: ^testing.T) {
	left := units_of_pixels(10)
	third := i32(UNITS_PER_PIXEL / 3)
	_, problem := read(sample_record(Draw_Text{count = 1, color = SAMPLE_COLOR, origin_x = left + third, font = .Cells_8x16, scale = 1}))
	testing.expectf(t, problem == .Field_Past_Bound, "a text in the font of the cells on a third: %v", problem)
	_, problem = read(sample_record(Draw_Text{count = 1, color = SAMPLE_COLOR, origin_x = left + third, font = .Interface, scale = 1}))
	testing.expect_value(t, problem, Problem.None)
	_, problem = read(sample_record(Draw_Text{count = INTERFACE_TEXT_LIMIT + 1, color = SAMPLE_COLOR, origin_x = left, font = .Interface, scale = 1}))
	testing.expect_value(t, problem, Problem.Field_Past_Bound)
	_, problem = read(sample_record(Draw_Text{count = INTERFACE_TEXT_LIMIT + 1, color = SAMPLE_COLOR, origin_x = left, font = .Cells_8x16, scale = 1}))
	testing.expect_value(t, problem, Problem.None)
	_, problem = read(sample_record(Draw_Text{count = max(u32), color = SAMPLE_COLOR, origin_x = left + units_of_pixels(INK_MARGIN_LIMIT), font = .Cells_8x16, scale = 1}))
	testing.expect_value(t, problem, Problem.None)
	_, problem = read(sample_record(Draw_Text{count = 1, color = SAMPLE_COLOR, origin_x = left - UNITS_PER_PIXEL, font = .Cells_8x16, scale = 1}))
	testing.expect_value(t, problem, Problem.Field_Past_Bound)
	_, problem = read(sample_record(Draw_Text{count = 1, color = SAMPLE_COLOR, origin_x = left + units_of_pixels(INK_MARGIN_LIMIT + 1), font = .Cells_8x16, scale = 1}))
	testing.expect_value(t, problem, Problem.Field_Past_Bound)
}

// Each word that names no kind is refused: the words between the kinds,
// one past the largest kind and every word after it, up to the largest word
// of the byte.
@(test)
read_refuses_each_unknown_kind :: proc(t: ^testing.T) {
	refused, read_count := 0, 0
	for word in 0 ..= u64(max(u8)) {
		record := sample_record(Draw_Nothing{})
		record.kind = u8(word)
		if _, known := draw_kind_of_word(u8(word)); known {
			read_count += 1
			continue
		}
		primitive, problem := read(record)
		testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word %d names no kind, and the border gives %v", word, problem)
		refused += 1
	}
	testing.expect_value(t, read_count, len(Draw_Kind))
	testing.expect_value(t, refused, int(max(u8)) + 1 - len(Draw_Kind))
}

// The pattern of a Rectangle out of its bounds: one step at 0 and the other
// not, fields of a pattern with both steps at 0, a cell of 0, a cell larger
// than its step, a size or a place inside a pixel, a place past the limit.
// Then the bounds themselves are read.
@(test)
read_refuses_a_pattern_past_its_bounds :: proc(t: ^testing.T) {
	pixel :: UNITS_PER_PIXEL
	refused := [?]Repetition {
		{step_x = 24 * pixel, cell_width = 2 * pixel, cell_height = 2 * pixel},
		{step_y = 24 * pixel, cell_width = 2 * pixel, cell_height = 2 * pixel},
		{cell_x = pixel},
		{cell_width = pixel},
		{cell_x = 0, cell_y = 0, cell_width = 0, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_width = 25 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_width = 2 * pixel, cell_height = 25 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_width = 2 * pixel + 1, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel - 1, step_y = 24 * pixel},
		{cell_x = 1, cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_y = COORDINATE_UNIT_LIMIT + pixel, cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_x = min(i32), cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_width = max(u16), cell_height = 2 * pixel, step_x = max(u16), step_y = 24 * pixel},
		// The other axis and the other fields, one by one.
		{cell_width = 2 * pixel, cell_height = 2 * pixel + 1, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel - 1},
		{cell_y = 1, cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_width = 2 * pixel, cell_height = 0, step_x = 24 * pixel, step_y = 24 * pixel},
		// Both steps at 0, with one other field set.
		{cell_y = pixel},
		{cell_height = pixel},
		{step_x = pixel},
		// A place one pixel past each limit, and the largest place.
		{cell_x = COORDINATE_UNIT_LIMIT + pixel, cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_y = -COORDINATE_UNIT_LIMIT - pixel, cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		{cell_x = max(i32), cell_width = 2 * pixel, cell_height = 2 * pixel, step_x = 24 * pixel, step_y = 24 * pixel},
		// A step of 63 units under a cell of 1 pixel.
		{cell_width = pixel, cell_height = pixel, step_x = pixel - 1, step_y = 24 * pixel},
	}
	for pattern, index in refused {
		_, problem := read(sample_record(Draw_Rectangle{color = SAMPLE_COLOR, repetition = pattern}))
		testing.expectf(t, problem == .Field_Past_Bound, "the pattern %d: %v", index, problem)
	}
	largest := u16(max(u16) / pixel * pixel)
	accepted := [?]Repetition {
		SAMPLE_PATTERN,
		{cell_width = pixel, cell_height = pixel, step_x = pixel, step_y = pixel},
		{cell_x = -COORDINATE_UNIT_LIMIT, cell_y = COORDINATE_UNIT_LIMIT, cell_width = largest, cell_height = largest, step_x = largest, step_y = largest},
	}
	for pattern, index in accepted {
		_, problem := read(sample_record(Draw_Rectangle{color = SAMPLE_COLOR, repetition = pattern}))
		testing.expectf(t, problem == .None, "the pattern %d at its bounds: %v", index, problem)
	}
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

// The bytes of the fields that a kind with no reserved run names, field by
// field, each field starting where the one before it ends: FIELDS_SIZE
// when the fields fill the 24 bytes with no gap. 0 for a kind that has
// reserved runs.
@(private = "file")
named_bytes_of :: proc(kind: Draw_Kind) -> int {
	switch kind {
	case .Gradient:
		fields: Gradient_Fields
		ends := [6]int {
			int(offset_of(Gradient_Fields, start_x)) + size_of(fields.start_x),
			int(offset_of(Gradient_Fields, start_y)) + size_of(fields.start_y),
			int(offset_of(Gradient_Fields, end_x)) + size_of(fields.end_x),
			int(offset_of(Gradient_Fields, end_y)) + size_of(fields.end_y),
			int(offset_of(Gradient_Fields, start_color)) + size_of(fields.start_color),
			int(offset_of(Gradient_Fields, end_color)) + size_of(fields.end_color),
		}
		starts := [6]int {
			int(offset_of(Gradient_Fields, start_x)),
			int(offset_of(Gradient_Fields, start_y)),
			int(offset_of(Gradient_Fields, end_x)),
			int(offset_of(Gradient_Fields, end_y)),
			int(offset_of(Gradient_Fields, start_color)),
			int(offset_of(Gradient_Fields, end_color)),
		}
		named := 0
		for start, index in starts {
			if start != named {
				return named
			}
			named = ends[index]
		}
		return named
	case .None, .Rectangle, .Text, .Clip, .Picture, .Text_Grid, .Line:
	}
	return 0
}

// Each byte of the fields that the kind does not name is refused, for each
// kind, with the smallest and the largest value that is not 0. A kind with
// no such byte names each of the 24 bytes, with no gap.
@(test)
read_refuses_each_byte_that_the_kind_does_not_name :: proc(t: ^testing.T) {
	checked := 0
	for primitive in sample_primitives() {
		base := sample_record(primitive)
		runs, run_count := reserved_runs_of(sample_kind(base))
		if run_count == 0 {
			named := named_bytes_of(sample_kind(base))
			testing.expectf(t, named == FIELDS_SIZE, "%v has no reserved run, and its fields name %d of the %d bytes", sample_kind(base), named, FIELDS_SIZE)
			continue
		}
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
			record := record_of(Draw_Rectangle{color = SAMPLE_COLOR}, 0, box[0], box[1], box[2], box[3])
			_, problem := read(record)
			testing.expectf(t, problem == .Box_Past_Coordinate_Limit, "the edge %d is %d, and the border gives %v", side, value, problem)
		}
	}
}

// An edge that is not a whole pixel, one unit past a pixel, one unit before
// it and a third of a pixel, on each side of the box of each sample: a
// rectangle with no pattern and a gradient read it, each other kind and a
// rectangle with a pattern refuse it, each other field valid.
@(test)
read_takes_a_box_inside_a_pixel_for_a_rectangle_and_a_gradient :: proc(t: ^testing.T) {
	parts := [?]i32{1, UNITS_PER_PIXEL - 1, UNITS_PER_PIXEL / 3}
	samples := sample_primitives()
	for primitive in samples {
		whole := sample_record(primitive)
		_, problem_whole := read(whole)
		testing.expectf(t, problem_whole == .None, "the sample %v on whole pixels: %v", sample_kind(whole), problem_whole)
		inside := false
		switch value in primitive {
		case Draw_Rectangle:
			inside = value.repetition == (Repetition{})
		case Draw_Gradient:
			inside = true
		case Draw_Nothing, Draw_Clip, Draw_Text, Draw_Picture, Draw_Text_Grid, Draw_Line:
		}
		for part in parts {
			for side in 0 ..< 4 {
				record := whole
				// Each edge moves inward, so the box stays the right way.
				switch side {
				case 0:
					record.left += part
				case 1:
					record.top += part
				case 2:
					record.right -= part
				case 3:
					record.bottom -= part
				}
				_, problem := read(record)
				expected := inside ? Problem.None : Problem.Box_Not_On_Whole_Pixels
				testing.expectf(t, problem == expected, "the sample %v with the edge %d moved by %d units: %v", sample_kind(record), side, part, problem)
			}
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
		record := sample_record(Draw_Text{origin_x = units_of_pixels(10), first = 0, count = 1, color = SAMPLE_COLOR, scale = 1})
		fields := transmute(Text_Fields)record.fields
		fields.scale = scale
		record.fields = transmute([FIELDS_SIZE]u8)fields
		_, problem := read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "a text of scale %d: %v", scale, problem)
		record = sample_record(Draw_Text{font = .Interface, count = 1, color = SAMPLE_COLOR, origin_x = units_of_pixels(10), scale = 1})
		interface_fields := transmute(Text_Fields)record.fields
		interface_fields.scale = scale
		record.fields = transmute([FIELDS_SIZE]u8)interface_fields
		_, problem = read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "an interface text of scale %d: %v", scale, problem)
	}
	for weight in weights {
		record := sample_record(Draw_Text{origin_x = units_of_pixels(10), first = 0, count = 1, color = SAMPLE_COLOR, scale = 1})
		fields := transmute(Text_Fields)record.fields
		fields.weight = weight
		record.fields = transmute([FIELDS_SIZE]u8)fields
		_, problem := read(record)
		testing.expectf(t, problem == .Field_Past_Bound, "a text of weight %d: %v", weight, problem)
		record = sample_record(Draw_Text{font = .Interface, count = 1, color = SAMPLE_COLOR, origin_x = units_of_pixels(10), scale = 1})
		interface_fields := transmute(Text_Fields)record.fields
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
		record := sample_record(Draw_Text{font = .Interface, count = count, color = SAMPLE_COLOR, origin_x = units_of_pixels(10), scale = 1})
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
		record := sample_record(Draw_Text{font = .Interface, count = 1, color = SAMPLE_COLOR, origin_x = origin, scale = 1})
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
		record := sample_record(Draw_Line{color = SAMPLE_COLOR, thickness = thickness})
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
			record := sample_record(Draw_Line{start_x = coordinates[0], start_y = coordinates[1], end_x = coordinates[2], end_y = coordinates[3], color = SAMPLE_COLOR, thickness = 1})
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
		Draw_Text{origin_x = units_of_pixels(10), count = 1, color = SAMPLE_COLOR, scale = 1},
		Draw_Text{origin_x = units_of_pixels(10), count = 1, color = SAMPLE_COLOR, scale = TEXT_SCALE_LIMIT, weight = max(Font_Weight)},
		Draw_Text{font = .Interface, count = INTERFACE_TEXT_LIMIT, color = SAMPLE_COLOR, origin_x = units_of_pixels(10), scale = TEXT_SCALE_LIMIT},
		Draw_Text{font = .Interface, count = 0, color = SAMPLE_COLOR, origin_x = units_of_pixels(10 + INK_MARGIN_LIMIT) + UNITS_PER_PIXEL * 2 / 3, scale = 1, weight = .Bold},
		Draw_Line{start_x = units_of_pixels(-LINE_COORDINATE_LIMIT), start_y = units_of_pixels(LINE_COORDINATE_LIMIT), end_x = units_of_pixels(LINE_COORDINATE_LIMIT), end_y = units_of_pixels(-LINE_COORDINATE_LIMIT), color = SAMPLE_COLOR, thickness = LINE_THICKNESS_LIMIT},
		Draw_Line{color = SAMPLE_COLOR, thickness = 1},
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
		record := record_of(Draw_Rectangle{color = SAMPLE_COLOR}, 0, box[0], box[1], box[2], box[3])
		_, problem := read(record)
		testing.expectf(t, problem == .None, "the box %v: %v", box, problem)
	}
}

// Each kind comes back from its record: the record of what the border
// read is the same bytes, and the kind is the kind of the primitive.
@(test)
a_record_of_each_kind_comes_back_from_the_border :: proc(t: ^testing.T) {
	// The values 6 and 7 name no kind, so the array of the kinds is sparse.
	seen: #sparse[Draw_Kind]bool
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

// A gradient down the box of sample_record, whose other fields are valid:
// the cases give it their colors.
@(private = "file")
SAMPLE_GRADIENT :: Draw_Gradient {
	start_x = 10 * UNITS_PER_PIXEL,
	start_y = 20 * UNITS_PER_PIXEL + UNITS_PER_PIXEL / 2,
	end_x   = 10 * UNITS_PER_PIXEL,
	end_y   = 43 * UNITS_PER_PIXEL + UNITS_PER_PIXEL / 2,
}

@(private = "file")
gradient_of_colors :: proc(start, end: Draw_Color) -> Draw_Gradient {
	gradient := SAMPLE_GRADIENT
	gradient.start_color, gradient.end_color = start, end
	return gradient
}

// The records whose one color is the color given: a rectangle, a pattern,
// each end of a gradient with the other end transparent, and a text in
// each font.
@(private = "file")
records_of_one_color :: proc(color: Draw_Color) -> [6]Draw_Primitive {
	return [6]Draw_Primitive {
		Draw_Rectangle{color = color},
		Draw_Rectangle{color = color, repetition = SAMPLE_PATTERN},
		gradient_of_colors(color, 0),
		gradient_of_colors(0, color),
		Draw_Text{origin_x = units_of_pixels(10), count = 1, color = color, scale = 1},
		Draw_Text{font = .Interface, count = 1, color = color, origin_x = units_of_pixels(12), scale = 1},
	}
}

// The record whose color must be opaque: a line.
@(private = "file")
line_of_color :: proc(color: Draw_Color) -> Draw_Line {
	return Draw_Line{start_x = units_of_pixels(1), start_y = units_of_pixels(1), end_x = units_of_pixels(9), end_y = units_of_pixels(1), color = color, thickness = 1}
}

// A color with alpha 0 draws nothing whatever its channels, so its one form
// is 0: the border refuses the other forms, with the smallest and the
// largest channels, in each record of one color and in a gradient whose two
// ends have alpha 0. Two such records that draw nothing in one box then
// have the same bytes, but for a pattern.
@(test)
read_refuses_a_transparent_color_that_is_not_zero :: proc(t: ^testing.T) {
	channels := [3]u32{1, 0x0012_3456, CHANNELS_MASK}
	for value in channels {
		refused := records_of_one_color(Draw_Color(value))
		for primitive, index in refused {
			_, problem := read(sample_record(primitive))
			testing.expectf(t, problem == .Field_Past_Bound, "the color field %d of %08x: %v", index, value, problem)
		}
		both := gradient_of_colors(Draw_Color(value), Draw_Color(value))
		_, problem := read(sample_record(both))
		testing.expectf(t, problem == .Field_Past_Bound, "a gradient of two ends of alpha 0 and channels %06x: %v", value, problem)
	}
	// The one transparent color is read, each alpha from 1 to 255 with any
	// channels is read, and a gradient keeps the channels of an end of
	// alpha 0 when its other end is not transparent: they color the mix.
	alphas := [4]u8{1, 2, 254, OPAQUE_ALPHA}
	transparent := records_of_one_color(0)
	for primitive, index in transparent {
		_, problem := read(sample_record(primitive))
		testing.expectf(t, problem == .None, "the color field %d of 0: %v", index, problem)
	}
	for alpha in alphas {
		accepted := records_of_one_color(with_alpha(0x0012_3456, alpha))
		for primitive, index in accepted {
			_, problem := read(sample_record(primitive))
			testing.expectf(t, problem == .None, "the color field %d with alpha %d: %v", index, alpha, problem)
		}
	}
	fade := gradient_of_colors(Draw_Color(0x0012_3456), opaque(0x0012_3456))
	_, problem := read(sample_record(fade))
	testing.expect_value(t, problem, Problem.None)
}

// The color of a line is opaque: its squares overlap. Each other alpha is
// refused, 0 too.
@(test)
read_refuses_a_line_that_is_not_opaque :: proc(t: ^testing.T) {
	alphas := [4]u8{0, 1, 128, OPAQUE_ALPHA - 1}
	for alpha in alphas {
		_, problem := read(sample_record(line_of_color(Draw_Color(u32(alpha) << ALPHA_SHIFT | 0x0012_3456))))
		testing.expectf(t, problem == .Field_Past_Bound, "the line with alpha %d: %v", alpha, problem)
	}
	_, problem := read(sample_record(line_of_color(0)))
	testing.expectf(t, problem == .Field_Past_Bound, "the line with the color 0: %v", problem)
	{
		_, white := read(sample_record(line_of_color(opaque(CHANNELS_MASK))))
		testing.expectf(t, white == .None, "the line in opaque white: %v", white)
	}
}

// The word of the format of a picture names a member: one past the largest
// and the largest word are refused; each member is read and kept.
@(test)
read_refuses_a_picture_format_that_names_no_member :: proc(t: ^testing.T) {
	picture := sample_record(Draw_Picture{memory = 1, first = 7, stride = 40, generation = 9})
	fields := transmute(Picture_Fields)picture.fields
	words := [2]u8{u8(max(Picture_Format)) + 1, max(u8)}
	for word in words {
		fields.format = word
		picture.fields = transmute([FIELDS_SIZE]u8)fields
		primitive, problem := read(picture)
		testing.expectf(t, problem == .Field_Past_Bound && primitive == nil, "the format word %d: %v", word, problem)
	}
	for format in Picture_Format {
		primitive, problem := read(sample_record(Draw_Picture{memory = 1, format = format, first = 7, stride = 40, generation = 9}))
		read_picture, is_picture := primitive.(Draw_Picture)
		testing.expectf(t, problem == .None && is_picture && read_picture.format == format, "the format %v: %v", format, problem)
	}
}

// opaque and with_alpha give the forms that the border reads: with_alpha
// gives 0 for alpha 0, and neither reads the high byte of a color of a
// canvas.
@(test)
draw_colors_of_a_canvas_color :: proc(t: ^testing.T) {
	testing.expect_value(t, opaque(0x0012_3456), Draw_Color(0xFF12_3456))
	testing.expect_value(t, opaque(0xAB12_3456), Draw_Color(0xFF12_3456))
	testing.expect_value(t, with_alpha(0xAB12_3456, 0), Draw_Color(0))
	testing.expect_value(t, with_alpha(0xAB12_3456, 1), Draw_Color(0x0112_3456))
	testing.expect_value(t, with_alpha(0x0012_3456, OPAQUE_ALPHA), opaque(0x0012_3456))
	testing.expect_value(t, alpha_of(Draw_Color(0x8012_3456)), u8(0x80))
	testing.expect_value(t, channels_of(Draw_Color(0x8012_3456)), u32(0x0012_3456))
}

// An edge one unit past the limit, on each side: the limit is checked
// before the whole pixel.
@(test)
read_refuses_an_edge_one_unit_past_the_limit :: proc(t: ^testing.T) {
	for value in ([2]i32{COORDINATE_UNIT_LIMIT + 1, -COORDINATE_UNIT_LIMIT - 1}) {
		for side in 0 ..< 4 {
			box := [4]i32{-units_of_pixels(4), -units_of_pixels(4), units_of_pixels(4), units_of_pixels(4)}
			box[side] = value
			_, problem := read(record_of(Draw_Rectangle{color = SAMPLE_COLOR}, 0, box[0], box[1], box[2], box[3]))
			testing.expectf(t, problem == .Box_Past_Coordinate_Limit, "the edge %d at %d units: %v", side, value, problem)
		}
	}
}

// The widest box, from one limit to the other: its width and its height in
// units fit an i32, and are the two limits apart.
@(test)
the_widest_box_has_a_width_in_an_i32 :: proc(t: ^testing.T) {
	record := record_of(Draw_Rectangle{color = SAMPLE_COLOR}, 0, -COORDINATE_UNIT_LIMIT, -COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT)
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
	_, problem := read(sample_record(Draw_Text{font = .Interface, count = 1, color = SAMPLE_COLOR, origin_x = largest, scale = 1}))
	testing.expect_value(t, problem, Problem.None)
	_, problem = read(sample_record(Draw_Text{font = .Interface, count = 1, color = SAMPLE_COLOR, origin_x = largest + 1, scale = 1}))
	testing.expect_value(t, problem, Problem.Field_Past_Bound)
	// A box at -10 pixels and the origin two pixels and a third right of it.
	negative := record_of(Draw_Text{font = .Interface, count = 1, color = SAMPLE_COLOR, origin_x = units_of_pixels(-8) + UNITS_PER_PIXEL / 3, scale = 1}, 0, units_of_pixels(-10), units_of_pixels(-20), units_of_pixels(-2), units_of_pixels(-4))
	_, problem = read(negative)
	testing.expect_value(t, problem, Problem.None)
	off_third := record_of(Draw_Text{font = .Interface, count = 1, color = SAMPLE_COLOR, origin_x = units_of_pixels(-8) + 1, scale = 1}, 0, units_of_pixels(-10), units_of_pixels(-20), units_of_pixels(-2), units_of_pixels(-4))
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
	reserved_and_past := record_of(Draw_Rectangle{color = SAMPLE_COLOR}, 0, max(i32) - 63, 0, max(i32) - 63, 0)
	reserved_and_past.reserved[1] = 1
	past_and_inverted := record_of(Draw_Rectangle{color = SAMPLE_COLOR}, 0, COORDINATE_UNIT_LIMIT + UNITS_PER_PIXEL, 0, 0, units_of_pixels(1))
	inverted_and_inside := record_of(Draw_Rectangle{color = SAMPLE_COLOR}, 0, units_of_pixels(4) + 1, 0, 0, units_of_pixels(1))
	inside_and_field := record_of(Draw_Text{count = 1, color = SAMPLE_COLOR, scale = 0}, 0, 1, 0, units_of_pixels(4), units_of_pixels(4))
	field_reserved_and_bound := sample_record(Draw_Text{count = 1, color = SAMPLE_COLOR, scale = 0})
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
