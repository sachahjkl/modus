package text_rendering

import "modus:support/vector_font"

// The rasterizer at any text size (src/md/features/text_rendering.md, "The
// rasterizer"): the exact area in integers of vector_font, its filter of
// five taps and its words 0xGGRRGGBB, with the frame of the face at the
// size.
//
// Two changes from the rasterizer of the glyph caches, and neither changes
// a word:
//
// - The work row is as wide as the glyph. The points of the outline give
//   the columns that the ink can touch (a quadratic curve stays inside its
//   control points), with the spread of the filter and one pixel more on
//   each side. The glyph moves by whole pixels into that row.
// - The rows are drawn in bands of BAND_ROWS rows: each band adds the whole
//   outline, moved up by whole rows, and keeps the pieces in its rows, so
//   the memory has a bound at any size.
//
// The outline keeps the placement of the rasterizer of the glyph caches,
// and each move is added to the ends of each segment, after the points of
// the outline and of its curves are computed (vector_font.Accumulation,
// move_x and move_y). A move of the placement itself changes words: the
// point between two points off the curve is a division by two that rounds
// toward zero, so a coordinate that becomes negative rounds the other way.
// A move of the segments by whole pixels moves each cut of the area by
// whole pixels, so each word is the word of the glyph caches.
//
// The ink of a glyph is cut to the rows of its line, as in a glyph cache:
// the box of a text record is its line.

BAND_ROWS :: 8 // The rows of one band of the accumulation.
// The widest work row, in pixels: the widest glyph of a line of
// TEXT_SIZE_LIMIT with the spread of the filter. A glyph wider than it is
// refused: its font is hostile.
WORK_COLUMN_LIMIT :: 512
STRIPE_MARGIN :: vector_font.STRIPE_MARGIN // The thirds on each side of a work row that the filter reads.
WORK_THIRDS_LIMIT :: 3 * WORK_COLUMN_LIMIT + 2 * STRIPE_MARGIN
LINE_ROW_LIMIT :: TEXT_SIZE_LIMIT / SUBPIXEL // The rows of the line of the largest size.
// The words of the largest glyph that is drawn whole: the largest block of
// the private glyph cache, a glyph of 128 by 128 pixels. A larger glyph is
// drawn band by band (Glyph_Source.Too_Large).
GLYPH_WORDS_LIMIT :: 16 * 1024
// The columns that the filter spreads ink past its third: two thirds.
FILTER_SPREAD_THIRDS :: 2
// The pixels of room past the spread of the filter on each side of a work
// row: no ink ever reaches a side of the row.
WORK_ROOM_PIXELS :: 1
SUBUNITS :: vector_font.SUBUNITS_PER_PIXEL
CONTOUR_LIMIT :: 128 // The contours of one outline.

// The memory of the rasterizer of this copy, apart from the state: a copy
// that only measures never names it, so its file does not carry it.
Raster_Memory :: struct {
	points:   [vector_font.POINT_LIMIT]vector_font.Outline_Point,
	contours: [CONTOUR_LIMIT]int,
	cells:    [(WORK_THIRDS_LIMIT + 1) * BAND_ROWS]i32,
	thirds:   [WORK_THIRDS_LIMIT * BAND_ROWS]u8,
	filtered: [WORK_THIRDS_LIMIT]u8,
	band:     [WORK_COLUMN_LIMIT * BAND_ROWS]u32, // The words of the rows of one band, a work row each.
	words:    [GLYPH_WORDS_LIMIT]u32, // The words of a whole glyph, a work row each, before its box is cut.
}

render_memory: Raster_Memory

// outline_memory gives an outline over the points of the render memory.
@(private)
outline_memory :: proc "contextless" (memory: ^Raster_Memory) -> vector_font.Outline {
	return {points = memory.points[:], contour_ends = memory.contours[:]}
}

// Raster_Job: the work on one glyph, band by band. Its outline is in the
// render memory, so one job runs at a time.
Raster_Job :: struct {
	placement:     vector_font.Placement,
	outline:       vector_font.Outline,
	baseline:      int, // The row of the baseline, from the top of the line.
	row_first:     int, // The first row of the line that the ink can touch.
	row_end:       int, // After the last one.
	next_row:      int, // The first row of the next band.
	columns:       int, // The pixels of the work row.
	origin_column: int, // The column of the whole pixel of the origin in the work row.
	move_x:        i64, // The subunits from the place of the placement to this work row, across.
	thirds:        int, // The thirds of the work row with its margins.
	proportional:  bool, // The box of the glyph is the box of its ink; else its cell.
	filter:        vector_font.Stripe_Filter,
}

// Raster_Box: the box of the ink of a glyph drawn whole, in the words of
// the render memory.
Raster_Box :: struct {
	first_row, row_count: int, // From the top of the line.
	left, width:          int, // left: from the whole pixel of the origin.
	first_word:           int, // In render_memory.words: the word of the top left corner of the box.
	stride:               int, // The words from one row to the next.
}

// Raster_Problem: why a glyph has no words.
Raster_Problem :: enum u8 {
	None,
	Refused, // The renderer refused the outline, or the glyph is wider than WORK_COLUMN_LIMIT: a hostile font.
	Too_Large, // The glyph passes GLYPH_WORDS_LIMIT: it is drawn band by band.
}

@(private)
floor_divide :: #force_inline proc "contextless" (value, by: i64) -> i64 {
	quotient := value / by
	if value % by < 0 {
		quotient -= 1
	}
	return quotient
}

@(private)
ceiling_divide :: #force_inline proc "contextless" (value, by: i64) -> i64 {
	return -floor_divide(-value, by)
}

// baseline_of gives the row of the baseline of a face at a size: the
// middle of the ink of the first font at the middle of the line, as
// vector_font.glyph_style_of places it in a cell of half the line, from 1
// to the rows of the line.
baseline_of :: proc "contextless" (frame: vector_font.Font_Measures, size: int) -> int {
	twice := i64(size) * (2 * i64(frame.advance) + i64(frame.top) + i64(frame.bottom))
	baseline := vector_font.divide_rounded(twice, 256 * i64(max(frame.advance, 1)))
	return int(clamp(baseline, 1, i64(line_rows(size))))
}

// placement_at gives the placement of the outlines of a font in a face at
// a size, in thirds of a pixel across, with the origin of the work row at
// the left of its margin: the placement of vector_font.placement_of for a
// cell of half the line. A cell of half the line is 2 * size subunits wide.
@(private)
placement_at :: proc "contextless" (measures: vector_font.Font_Measures, baseline, size: int, grid_fit: bool) -> vector_font.Placement {
	cell_subunits := 2 * i64(size)
	denominator := i64(max(measures.advance, 1))
	placement := vector_font.Placement {
		origin_x               = STRIPE_MARGIN * SUBUNITS,
		horizontal_numerator   = cell_subunits * 3,
		horizontal_denominator = denominator,
		origin_y               = i64(baseline) * SUBUNITS,
		vertical_numerator     = cell_subunits,
		vertical_denominator   = denominator,
		grid_fit               = grid_fit,
		x_height               = i64(measures.x_height),
		cap_height             = i64(measures.cap_height),
	}
	whole :: proc "contextless" (units, numerator, denominator: i64) -> i64 {
		return max(vector_font.divide_rounded(units * numerator, denominator * SUBUNITS), 1) * SUBUNITS
	}
	placement.x_height_place = whole(placement.x_height, cell_subunits, denominator)
	placement.cap_height_place = max(whole(placement.cap_height, cell_subunits, denominator), placement.x_height_place + SUBUNITS)
	return placement
}

// raster_begin reads the outline of a glyph of a font of the chain of a
// face, and places it at a size and a position across a pixel. The caller
// has checked the face, the size and the position.
raster_begin :: proc "contextless" (face: Face, font: Outline_Font, glyph_index, size, position: int) -> (job: Raster_Job, problem: Raster_Problem) {
	form := face_forms[face]
	memory := &render_memory
	job.outline = outline_memory(memory)
	if vector_font.glyph_outline(&state.fonts[font].file, glyph_index, &job.outline) != .None {
		return {}, .Refused
	}
	first := &state.fonts[form.primary]
	frame := form.proportional ? first.stated : first.own
	job.baseline = baseline_of(frame, size)
	job.placement = placement_at(measures_in_frame(face, font), job.baseline, size, form.grid_fit)
	job.proportional = form.proportional
	job.filter = .Five_Taps
	rows := line_rows(size)
	// The rows and the columns that the points reach, in subunits from the
	// origin of the glyph.
	low_x, high_x := i64(max(i32)), i64(min(i32))
	low_y, high_y := i64(max(i32)), i64(min(i32))
	for point in job.outline.points[:job.outline.point_count] {
		x := i64(vector_font.place_x(&job.placement, point.x)) - job.placement.origin_x
		y := i64(vector_font.place_y(&job.placement, point.y))
		low_x, high_x = min(low_x, x), max(high_x, x)
		low_y, high_y = min(low_y, y), max(high_y, y)
	}
	if job.outline.point_count == 0 {
		// No ink: a space. A band job of no rows.
		job.columns = form.proportional ? 1 : cell_columns(size)
		job.thirds = 3 * job.columns + 2 * STRIPE_MARGIN
		return job, .None
	}
	job.row_first = int(clamp(floor_divide(low_y, SUBUNITS), 0, i64(rows)))
	job.row_end = int(clamp(ceiling_divide(high_y, SUBUNITS), i64(job.row_first), i64(rows)))
	job.next_row = job.row_first
	if !form.proportional {
		// A glyph of cells is cut to its cell, as in a glyph cache.
		job.columns = cell_columns(size)
		job.origin_column = 0
	} else {
		shift := i64(position) * SUBUNITS // One third of a pixel for each position.
		left_third := floor_divide(low_x + shift, SUBUNITS) - FILTER_SPREAD_THIRDS
		right_third := ceiling_divide(high_x + shift, SUBUNITS) - 1 + FILTER_SPREAD_THIRDS
		left_pixel := floor_divide(left_third, 3) - WORK_ROOM_PIXELS
		right_pixel := floor_divide(right_third, 3) + WORK_ROOM_PIXELS
		if right_pixel - left_pixel + 1 > WORK_COLUMN_LIMIT {
			return {}, .Refused
		}
		job.columns = int(right_pixel - left_pixel + 1)
		job.origin_column = int(-left_pixel)
		// The placement of the rasterizer of the glyph caches, with its
		// origin at the column PLACED_ORIGIN_COLUMN of its row; the move to
		// the column of this row is added to each segment after its points
		// are computed (vector_font.Accumulation, move_x), so each point is
		// the point of the glyph caches.
		job.placement.origin_x += 3 * vector_font.PLACED_ORIGIN_COLUMN * SUBUNITS + shift
		job.move_x = 3 * i64(job.origin_column - vector_font.PLACED_ORIGIN_COLUMN) * SUBUNITS
	}
	if job.columns < 1 || job.columns > WORK_COLUMN_LIMIT {
		return {}, .Refused
	}
	job.thirds = 3 * job.columns + 2 * STRIPE_MARGIN
	return job, .None
}

// band_next draws the next band of a job into render_memory.band: its rows
// from first_row, each job.columns words. row_count is 0 after the last
// band.
band_next :: proc "contextless" (job: ^Raster_Job) -> (first_row, row_count: int, words: [^]u32) {
	if job.next_row >= job.row_end {
		return job.row_end, 0, nil
	}
	memory := &render_memory
	first_row = job.next_row
	row_count = min(BAND_ROWS, job.row_end - first_row)
	job.next_row += row_count
	target, ok := vector_font.accumulation_of(memory.cells[:], job.thirds, row_count)
	if !ok {
		return first_row, 0, nil
	}
	// The outline keeps the placement of the whole line; the band moves
	// each segment up by its first row after the points are computed.
	target.move_x = job.move_x
	target.move_y = -i64(first_row) * SUBUNITS
	vector_font.outline_add(&target, &job.outline, &job.placement)
	vector_font.coverage_finish(&target, memory.thirds[:])
	for row in 0 ..< row_count {
		thirds := memory.thirds[row * job.thirds:][:job.thirds]
		vector_font.stripes_filter(thirds, memory.filtered[:job.thirds], job.filter)
		out := memory.band[row * job.columns:][:job.columns]
		for column in 0 ..< job.columns {
			at := STRIPE_MARGIN + 3 * column
			red, green, blue := u32(memory.filtered[at]), u32(memory.filtered[at + 1]), u32(memory.filtered[at + 2])
			gray := (u32(thirds[at]) + u32(thirds[at + 1]) + u32(thirds[at + 2]) + 1) / 3
			out[column] = gray << 24 | red << 16 | green << 8 | blue
		}
	}
	return first_row, row_count, raw_data(memory.band[:])
}

// glyph_raster draws one glyph whole into render_memory.words and gives
// the box of its ink: a proportional glyph as the box of its ink, a glyph
// of cells cut to its cell with only its rows of ink. A glyph with no ink
// has a box of no rows.
glyph_raster :: proc "contextless" (face: Face, font: Outline_Font, glyph_index, size, position: int) -> (box: Raster_Box, problem: Raster_Problem) {
	job := raster_begin(face, font, glyph_index, size, position) or_return
	return job_raster(&job)
}

// job_raster draws the bands of a job into render_memory.words and cuts
// the box of its ink.
job_raster :: proc "contextless" (job: ^Raster_Job) -> (box: Raster_Box, problem: Raster_Problem) {
	memory := &render_memory
	if job.columns * (job.row_end - job.row_first) > GLYPH_WORDS_LIMIT {
		return {}, .Too_Large
	}
	first_row, last_row := job.row_end, -1
	first_column, last_column := job.columns, -1
	for {
		band_first, band_rows, band_words := band_next(job)
		if band_rows == 0 {
			break
		}
		for row in 0 ..< band_rows {
			source := band_words[row * job.columns:][:job.columns]
			line := band_first + row
			copy(memory.words[(line - job.row_first) * job.columns:][:job.columns], source)
			for word, column in source {
				if word != 0 {
					first_row = min(first_row, line)
					last_row = max(last_row, line)
					first_column = min(first_column, column)
					last_column = max(last_column, column)
				}
			}
		}
	}
	if last_row < 0 {
		return {}, .None // No ink.
	}
	if !job.proportional {
		first_column, last_column = 0, job.columns - 1
	}
	return {
			first_row = first_row,
			row_count = last_row - first_row + 1,
			left = first_column - job.origin_column,
			width = last_column - first_column + 1,
			first_word = (first_row - job.row_first) * job.columns + first_column,
			stride = job.columns,
		},
		.None
}

// glyph_bands starts the draw of a glyph band by band: a glyph that is too
// large to be drawn whole (Glyph_Source.Too_Large). The caller blends the
// rows of each band_next at the column -job.origin_column from the whole
// pixel of the origin, until a band has no rows. ok is false when glyph
// gives no glyph for the same arguments.
glyph_bands :: proc "contextless" (face: Face, character: rune, size, position: int) -> (job: Raster_Job, ok: bool) {
	if face == .None || size_check(size) != .None || position < 0 || position >= positions_of(face) {
		return {}, false
	}
	font, glyph_index := font_glyph_of(face, character)
	if font == .None {
		return {}, false
	}
	problem: Raster_Problem
	job, problem = raster_begin(face, font, glyph_index, size, position)
	return job, problem == .None
}
