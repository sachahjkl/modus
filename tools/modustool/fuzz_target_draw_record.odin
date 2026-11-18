package modustool

import "core:mem"
import "modus:contract/draw_record"

// The fuzz target of the draw record (src/md/api/draw_table.md, "The
// record: a header and the fields of one kind"): the drawing module and the
// compositor read the records of a draw table that another body of code
// wrote, through one border. The input is records of 48 bytes, one after
// the other.

// fuzz_draw_record_execute: the border gives a problem of its enumeration;
// a record that it reads has a box that is not inverted, inside the limit,
// and on whole pixels but for a rectangle with no pattern and a gradient,
// a gradient with valid points, keeps the canonical rule of its colors
// (draw_color_problem),
// writes back to its own bytes, and keeps its bytes
// when its range moves to its own first byte; a record that it refuses
// changes no byte of the input.
fuzz_draw_record_execute :: proc(input: []u8) -> Fuzz_Verdict {
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
		case draw_record.Draw_Nothing, draw_record.Draw_Clip, draw_record.Draw_Text, draw_record.Draw_Picture, draw_record.Draw_Text_Grid, draw_record.Draw_Line:
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
		// A color that draws nothing has one form, and a line, whose
		// squares overlap, is opaque.
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
// alpha 0 whose color is not 0, a line that is not opaque.
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
	case draw_record.Draw_Line:
		if draw_record.alpha_of(value.color) != draw_record.OPAQUE_ALPHA {
			return "a line whose color is not opaque"
		}
	case draw_record.Draw_Nothing, draw_record.Draw_Clip, draw_record.Draw_Picture, draw_record.Draw_Text_Grid:
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
		draw_record.Draw_Text{first = 0, count = 4, color = draw_record.with_alpha(5, 128), scale = 1},
		draw_record.Draw_Text{first = 0, count = 4, color = opaque(5), scale = 1},
		draw_record.Draw_Clip{},
		// The grid of points: a pattern of cells of 2 pixels each 24 pixels.
		draw_record.Draw_Rectangle{color = opaque(6), repetition = {cell_x = pixel(12), cell_y = pixel(12), cell_width = 2 * draw_record.UNITS_PER_PIXEL, cell_height = 2 * draw_record.UNITS_PER_PIXEL, step_x = 24 * draw_record.UNITS_PER_PIXEL, step_y = 24 * draw_record.UNITS_PER_PIXEL}},
		draw_record.Draw_Picture{first = 0, stride = 16, generation = 1},
		draw_record.Draw_Text_Grid{first = 0, count = 32, columns = 2},
		draw_record.Draw_Line{start_x = pixel(1), start_y = pixel(1), end_x = pixel(9), end_y = pixel(5), color = opaque(9), thickness = 2},
		draw_record.Draw_Text{first = 0, count = 4, color = opaque(10), origin_x = pixel(2) + draw_record.UNITS_PER_PIXEL / 3, font = .Interface, scale = 1, weight = .Bold},
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
}

fuzz_draw_record_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	count := len(input) / draw_record.RECORD_SIZE
	if count > 0 {
		append(regions, Fuzz_Region{offset = 0, type = draw_record.Draw_Record, count = count})
	}
}
