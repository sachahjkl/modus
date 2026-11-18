package modustool

import "core:mem"
import "modus:contract/draw_record"

// The fuzz target of the draw record (src/md/api/draw_table.md, "The
// record: a header and the fields of one kind"): the drawing module and the
// compositor read the records of a draw table that another body of code
// wrote, through one border. The input is records of 48 bytes, one after
// the other.

// fuzz_draw_record_execute: the border gives a problem of its enumeration;
// a record that it reads has a box that is not inverted, inside the limit
// and on whole pixels, writes back to its own bytes, and keeps its bytes
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
		edges := [4]i32{record.left, record.top, record.right, record.bottom}
		for edge in edges {
			if !draw_record.inside_coordinate_limit(edge) || !draw_record.on_whole_pixel(edge) {
				return fuzz_broken(.Contract, "the record %d: read takes the edge %d, past the limit or inside a pixel", index, edge)
			}
		}
		if record.right < record.left || record.bottom < record.top {
			return fuzz_broken(.Contract, "the record %d: read takes the inverted box %d, %d, %d, %d", index, record.left, record.top, record.right, record.bottom)
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

// One record of each kind, in a box of whole pixels.
fuzz_draw_record_seeds :: proc(seeds: ^[dynamic][]u8) {
	pixel :: draw_record.units_of_pixels
	primitives := [?]draw_record.Draw_Primitive {
		draw_record.Draw_Nothing{},
		draw_record.Draw_Rectangle{color = 0x00102030},
		draw_record.Draw_Vertical_Gradient{top_color = 1, bottom_color = 2},
		draw_record.Draw_Horizontal_Gradient{left_color = 3, right_color = 4},
		draw_record.Draw_Text{first = 0, count = 4, color = 5, scale = 1},
		draw_record.Draw_Clip{},
		// The grid of points: a pattern of cells of 2 pixels each 24 pixels.
		draw_record.Draw_Rectangle{color = 6, repetition = {cell_x = pixel(12), cell_y = pixel(12), cell_width = 2 * draw_record.UNITS_PER_PIXEL, cell_height = 2 * draw_record.UNITS_PER_PIXEL, step_x = 24 * draw_record.UNITS_PER_PIXEL, step_y = 24 * draw_record.UNITS_PER_PIXEL}},
		draw_record.Draw_Picture{first = 0, stride = 16, generation = 1},
		draw_record.Draw_Text_Grid{first = 0, count = 32, columns = 2},
		draw_record.Draw_Line{start_x = pixel(1), start_y = pixel(1), end_x = pixel(9), end_y = pixel(5), color = 9, thickness = 2},
		draw_record.Draw_Text{first = 0, count = 4, color = 10, origin_x = pixel(2) + draw_record.UNITS_PER_PIXEL / 3, font = .Interface, scale = 1, weight = .Bold},
	}
	all := make([]u8, len(primitives) * draw_record.RECORD_SIZE)
	for primitive, index in primitives {
		record := draw_record.record_of(primitive, u32(index), 0, 0, pixel(16), pixel(16))
		mem.copy(&all[index * draw_record.RECORD_SIZE], &record, draw_record.RECORD_SIZE)
		one := make([]u8, draw_record.RECORD_SIZE)
		mem.copy(&one[0], &record, draw_record.RECORD_SIZE)
		append(seeds, one)
	}
	append(seeds, all)
}

fuzz_draw_record_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	count := len(input) / draw_record.RECORD_SIZE
	if count > 0 {
		append(regions, Fuzz_Region{offset = 0, type = draw_record.Draw_Record, count = count})
	}
}
