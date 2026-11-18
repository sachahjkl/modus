package fuzz

import "core:mem"
import "core:slice"
import "modus:contract/draw_record"
import "modus:support/graphics"
import "modus:support/interface"

// The fuzz target of the rasterizer of a path (src/md/api/draw_table.md,
// "The execution"): the fuzzed points become one Path record, drawn into a
// small canvas framed by guard pixels, whole and in damage rectangles that
// cut it across the bands of the accumulation. The arithmetic of Odin wraps
// with no fault, so a sum of the cells that passed its bound shows only in
// the pixels: as a pixel outside the box, or as a draw in parts that is not
// the draw whole.
//
// The input: 4 bytes of a header (the stroke width in units, u16; the
// alpha of the fill; the alpha of the stroke), then points of 12 bytes. Each
// coordinate becomes a place inside COORDINATE_LIMIT, near the canvas when
// the low bit of its command word is 1, else anywhere; the command is the
// word modulo 5, so the word 0 that names none comes too.

@(private = "file")
DRAW_PATH_WIDTH :: 264 // Past one band of columns, PATH_BAND_COLUMNS.
@(private = "file")
DRAW_PATH_HEIGHT :: 20 // Past two bands of rows, PATH_BAND_ROWS.
@(private = "file")
DRAW_PATH_FRAME :: 4 // The guard pixels around the canvas.
@(private = "file")
DRAW_PATH_HEADER :: 4
@(private = "file")
DRAW_PATH_GUARD :: graphics.Color(0x00A5_5A3C)

@(private = "file")
DRAW_PATH_PARTS :: [5]interface.Rectangle{{0, 0, 7, DRAW_PATH_HEIGHT}, {7, 0, 256, 9}, {7, 9, 256, DRAW_PATH_HEIGHT}, {256, 0, 257, DRAW_PATH_HEIGHT}, {257, 0, DRAW_PATH_WIDTH, DRAW_PATH_HEIGHT}}

@(private = "file")
draw_path_text_state_ready: bool

@(private = "file")
Draw_Path_Tables :: struct {
	records: [2]draw_record.Draw_Record,
	text:    [draw_record.PATH_POINT_LIMIT * draw_record.PATH_POINT_SIZE]u8,
}

fuzz_draw_path_execute :: proc(input: []u8) -> Fuzz_Verdict {
	if !draw_path_text_state_ready {
		graphics.text_state_start()
		draw_path_text_state_ready = true
	}
	if len(input) < DRAW_PATH_HEADER {
		return FUZZ_PASSED
	}
	width := i32(u16(input[0]) | u16(input[1]) << 8)
	fill := draw_record.with_alpha(0x0030_C060, input[2])
	stroke := draw_record.with_alpha(0x00F0_2080, input[3])
	count := min((len(input) - DRAW_PATH_HEADER) / draw_record.PATH_POINT_SIZE, draw_record.PATH_POINT_LIMIT)
	points := make([]interface.Path_Point, count, context.temp_allocator)
	for &point, index in points {
		words: [3]u32
		mem.copy(&words, &input[DRAW_PATH_HEADER + index * draw_record.PATH_POINT_SIZE], size_of(words))
		near := words[0] & 1 == 1
		// The word 0 names no command: the border gives the zero value,
		// which the writer of the path must refuse.
		command, _ := draw_record.path_command_of_word(words[0] % 5)
		point = {command = command, x = fuzz_draw_path_place(words[1], near), y = fuzz_draw_path_place(words[2], near)}
	}
	memory := new(Draw_Path_Tables, context.temp_allocator)
	table := interface.Draw_Table{records = memory.records[:], text = memory.text[:]}
	interface.draw_path(&table, points, fill, stroke, width)
	if table.record_count == 0 {
		return FUZZ_PASSED
	}
	whole := fuzz_draw_path_frame()
	parts := fuzz_draw_path_frame()
	interface.execute(&table, fuzz_draw_path_canvas(whole))
	rectangles := DRAW_PATH_PARTS
	interface.execute_in_rectangles(&table, fuzz_draw_path_canvas(parts), rectangles[:])
	box := interface.record_rectangle(table.records[0])
	OUTER_WIDTH :: DRAW_PATH_WIDTH + 2 * DRAW_PATH_FRAME
	for pixel, index in whole {
		x, y := index % OUTER_WIDTH - DRAW_PATH_FRAME, index / OUTER_WIDTH - DRAW_PATH_FRAME
		inside_canvas := x >= 0 && x < DRAW_PATH_WIDTH && y >= 0 && y < DRAW_PATH_HEIGHT
		inside_box := x >= box.left && x < box.right && y >= box.top && y < box.bottom
		if !inside_canvas || !inside_box {
			if pixel != DRAW_PATH_GUARD || parts[index] != DRAW_PATH_GUARD {
				return fuzz_broken(.Contract, "the path writes the pixel (%d, %d), outside the canvas or its box", x, y)
			}
		}
	}
	if !slice.equal(whole, parts) {
		return fuzz_broken(.Two_Readers, "the path drawn in damage rectangles differs from the path drawn whole")
	}
	return FUZZ_PASSED
}

// fuzz_draw_path_place gives a place inside COORDINATE_LIMIT from a word: near
// the canvas, within 64 pixels of it, or anywhere.
@(private = "file")
fuzz_draw_path_place :: proc(word: u32, near: bool) -> i32 {
	if near {
		return i32(word % u32((DRAW_PATH_WIDTH + 128) * draw_record.UNITS_PER_PIXEL)) - 64 * draw_record.UNITS_PER_PIXEL
	}
	return i32(word) >> 2
}

// fuzz_draw_path_frame gives the canvas and its frame of guard pixels, each
// pixel the guard color: the execution paints no background.
@(private = "file")
fuzz_draw_path_frame :: proc() -> []graphics.Color {
	pixels := make([]graphics.Color, (DRAW_PATH_WIDTH + 2 * DRAW_PATH_FRAME) * (DRAW_PATH_HEIGHT + 2 * DRAW_PATH_FRAME), context.temp_allocator)
	slice.fill(pixels, DRAW_PATH_GUARD)
	return pixels
}

@(private = "file")
fuzz_draw_path_canvas :: proc(pixels: []graphics.Color) -> graphics.Canvas {
	OUTER_WIDTH :: DRAW_PATH_WIDTH + 2 * DRAW_PATH_FRAME
	return {pixels = raw_data(pixels[DRAW_PATH_FRAME * OUTER_WIDTH + DRAW_PATH_FRAME:]), width = DRAW_PATH_WIDTH, height = DRAW_PATH_HEIGHT, stride = OUTER_WIDTH}
}

// A star with a stroke, a circle of curves, a wide stroke along the edge of
// a band, and the most curves of the largest bend in one row.
fuzz_draw_path_seeds :: proc(seeds: ^[dynamic][]u8) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	near :: proc(command: draw_record.Path_Command, x, y: int) -> [3]u32 {
		// The near form: the low bit of the word set, and the place from
		// -64 pixels.
		word := u32(command)
		if word & 1 == 0 {
			word += 5
		}
		return {word, u32((x + 64) * UNITS), u32((y + 64) * UNITS)}
	}
	far :: proc(command: draw_record.Path_Command, x, y: i32) -> [3]u32 {
		word := u32(command)
		if word & 1 == 1 {
			word += 5
		}
		return {word, u32(x) << 2, u32(y) << 2}
	}
	add :: proc(seeds: ^[dynamic][]u8, width: u16, fill_alpha, stroke_alpha: u8, points: [][3]u32) {
		seed := make([]u8, DRAW_PATH_HEADER + len(points) * draw_record.PATH_POINT_SIZE)
		seed[0], seed[1], seed[2], seed[3] = u8(width), u8(width >> 8), fill_alpha, stroke_alpha
		for point, index in points {
			copy_point := point
			mem.copy(&seed[DRAW_PATH_HEADER + index * draw_record.PATH_POINT_SIZE], &copy_point, size_of(copy_point))
		}
		append(seeds, seed)
	}
	star := [6][3]u32{near(.Move, 20, 1), near(.Line, 31, 18), near(.Line, 2, 7), near(.Line, 38, 7), near(.Line, 9, 18), near(.Close, 0, 0)}
	add(seeds, 3 * UNITS / 2, 200, 255, star[:])
	circle: [18][3]u32
	ON :: [8][2]int{{30, 0}, {21, 21}, {0, 30}, {-21, 21}, {-30, 0}, {-21, -21}, {0, -30}, {21, -21}}
	CONTROL :: [8][2]int{{30, 12}, {12, 30}, {-12, 30}, {-30, 12}, {-30, -12}, {-12, -30}, {12, -30}, {30, -12}}
	on, control := ON, CONTROL
	circle[0] = near(.Move, 250 + on[0][0], 10 + on[0][1] / 3)
	for eighth in 0 ..< 8 {
		next := on[(eighth + 1) % 8]
		circle[1 + eighth * 2] = near(.Curve_Control, 250 + control[eighth][0], 10 + control[eighth][1] / 3)
		circle[2 + eighth * 2] = near(.Line, 250 + next[0], 10 + next[1] / 3)
	}
	circle[17] = near(.Close, 0, 0)
	add(seeds, 5 * UNITS, 128, 160, circle[:])
	edge := [3][3]u32{near(.Move, 0, 8), near(.Line, 256, 8), near(.Line, 256, 19)}
	add(seeds, u16(draw_record.STROKE_WIDTH_UNIT_LIMIT), 0, 255, edge[:])
	most: [draw_record.PATH_POINT_LIMIT - 1][3]u32
	most[0] = far(.Move, 10 * UNITS, 10 * UNITS)
	for curve in 0 ..< (len(most) - 1) / 2 {
		most[1 + 2 * curve] = far(.Curve_Control, draw_record.COORDINATE_UNIT_LIMIT - UNITS, 10 * UNITS)
		most[2 + 2 * curve] = far(.Line, curve % 2 == 0 ? 250 * UNITS : 10 * UNITS, 10 * UNITS)
	}
	add(seeds, u16(draw_record.STROKE_WIDTH_UNIT_LIMIT), 90, 255, most[:])
}

fuzz_draw_path_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	count := (len(input) - min(len(input), DRAW_PATH_HEADER)) / draw_record.PATH_POINT_SIZE
	if count > 0 {
		append(regions, Fuzz_Region{offset = DRAW_PATH_HEADER, type = draw_record.Path_Point_Record, count = count})
	}
}
