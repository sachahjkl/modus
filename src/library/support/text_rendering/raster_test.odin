#+build !freestanding
package text_rendering

import "core:mem"
import "core:testing"
import "modus:support/vector_font"

// The tests of a hostile font: a font file made here, with the tables that
// vector_font.glyph_outline reads (hmtx, loca with long offsets, glyf), in
// place of the file of B612 in the state of the package. The measures of
// B612 stay: they give the frame.

@(private = "file")
Test_Point :: struct {
	x, y: i32, // In units of the font.
}

// test_font_of writes a font of simple glyphs: each glyph is a list of
// contours, each contour a list of points on the curve. Each step from one
// point to the next fits an i16, as the format needs.
@(private = "file")
test_font_of :: proc(glyphs: [][][]Test_Point) -> vector_font.Font_File {
	put_u16 :: proc(bytes: []u8, at: int, value: int) {
		bytes[at] = u8(value >> 8)
		bytes[at + 1] = u8(value)
	}
	put_u32 :: proc(bytes: []u8, at: int, value: int) {
		put_u16(bytes, at, value >> 16)
		put_u16(bytes, at + 2, value & 0xFFFF)
	}
	size_of_glyph :: proc(contours: [][]Test_Point) -> int {
		points := 0
		for contour in contours {
			points += len(contour)
		}
		// The header, the ends of the contours, the length of the
		// instructions, a flag and two steps of 16 bits for each point.
		return 10 + 2 * len(contours) + 2 + 5 * points
	}
	hmtx := 0
	loca := 4
	glyf := loca + 4 * (len(glyphs) + 1)
	total := 0
	for contours in glyphs {
		total += size_of_glyph(contours)
	}
	bytes := make([]u8, glyf + total)
	put_u16(bytes, hmtx, 1000)
	at := 0
	for contours, glyph in glyphs {
		put_u32(bytes, loca + 4 * glyph, at)
		data := bytes[glyf + at:]
		put_u16(data, 0, len(contours))
		place, last := 10, -1
		for contour in contours {
			last += len(contour)
			put_u16(data, place, last)
			place += 2
		}
		put_u16(data, place, 0) // No instruction.
		place += 2
		for contour in contours {
			for _ in contour {
				data[place] = 0x01 // On the curve; each step of 16 bits.
				place += 1
			}
		}
		for axis in 0 ..< 2 {
			previous: i32
			for contour in contours {
				for point in contour {
					value := axis == 0 ? point.x : point.y
					step := int(value - previous)
					assert(step >= -32768 && step <= 32767)
					put_u16(data, place, step & 0xFFFF)
					place += 2
					previous = value
				}
			}
		}
		at += size_of_glyph(contours)
	}
	put_u32(bytes, loca + 4 * len(glyphs), at)
	return {
		bytes              = bytes,
		units_per_em       = 1000,
		glyph_count        = len(glyphs),
		long_offsets       = true,
		horizontal_metrics = 1,
		hmtx               = {hmtx, 4},
		loca               = {loca, 4 * (len(glyphs) + 1)},
		glyf               = {glyf, len(bytes) - glyf},
	}
}

// rectangle gives one contour of a rectangle.
@(private = "file")
rectangle :: proc(left, bottom, right, top: i32) -> []Test_Point {
	contour := make([]Test_Point, 4)
	contour[0], contour[1], contour[2], contour[3] = {left, bottom}, {right, bottom}, {right, top}, {left, top}
	return contour
}

// far_contour gives one contour that goes from 0 to near far units across,
// in steps of the largest step of 16 bits, and back a little higher: 1 023
// points, at most the points of one glyph.
@(private = "file")
far_contour :: proc(direction: i32) -> []Test_Point {
	STEPS :: 511
	contour := make([]Test_Point, 2 * STEPS + 1)
	for index in 0 ..= STEPS {
		contour[index] = {direction * 32767 * i32(index), 0}
	}
	for index in 1 ..= STEPS {
		contour[STEPS + index] = {direction * 32767 * i32(STEPS - index), 10}
	}
	return contour
}

// Units of one third of a pixel across at the size of a line of 16
// pixels: a frame of 24 units for the cell of half the line, so a width
// in units is a width in thirds.
@(private = "file")
THIRD_FRAME :: 24

// The glyphs of the hostile font, by their index.
@(private = "file")
Test_Glyph :: enum {
	Columns_512, // 1 523 units: a work row of exactly WORK_COLUMN_LIMIT pixels.
	Columns_513, // 1 526 units: one pixel past it.
	Far_Right, // Points near 2^24 units across.
	Far_Left, // Points near -2^24 units across.
	Contours_128, // CONTOUR_LIMIT contours.
	Contours_129, // One contour past it.
	Past_The_Line, // A rectangle far above, below and left of the line.
}

@(private = "file")
test_font_open :: proc(t: ^testing.T) -> (font: vector_font.Font_File, words: []u64) {
	fonts := repository_fonts()
	_, words = outlines_open(t, fonts[:])
	glyphs: [Test_Glyph][][]Test_Point
	glyphs[.Columns_512] = make([][]Test_Point, 1)
	glyphs[.Columns_512][0] = rectangle(0, 0, 1523, 3)
	glyphs[.Columns_513] = make([][]Test_Point, 1)
	glyphs[.Columns_513][0] = rectangle(0, 0, 1526, 3)
	glyphs[.Far_Right] = make([][]Test_Point, 1)
	glyphs[.Far_Right][0] = far_contour(1)
	glyphs[.Far_Left] = make([][]Test_Point, 1)
	glyphs[.Far_Left][0] = far_contour(-1)
	for kind in ([2]Test_Glyph{.Contours_128, .Contours_129}) {
		count := kind == .Contours_128 ? CONTOUR_LIMIT : CONTOUR_LIMIT + 1
		glyphs[kind] = make([][]Test_Point, count)
		for &contour, index in glyphs[kind] {
			contour = make([]Test_Point, 2)
			contour[0], contour[1] = {i32(index), 0}, {i32(index), 100}
		}
	}
	glyphs[.Past_The_Line] = make([][]Test_Point, 1)
	// 16 000 units each side of the baseline: hundreds of rows past the
	// line at each size of the test, with each step inside 16 bits.
	glyphs[.Past_The_Line][0] = rectangle(-3000, -16000, 100, 16000)
	list := make([][][]Test_Point, len(Test_Glyph))
	for contours, kind in glyphs {
		list[int(kind)] = contours
	}
	font = test_font_of(list)
	for contours in list {
		for contour in contours {
			delete(contour)
		}
		delete(contours)
	}
	delete(list)
	state.fonts[.B612].file = font
	return font, words
}

// Cache_Picture: what a refused glyph must not change in the cache.
@(private = "file")
Cache_Picture :: struct {
	free_heads:  [ORDER_COUNT]u16,
	words_ready: bool,
	drawn:       u64,
}

@(private = "file")
cache_picture :: proc() -> Cache_Picture {
	cache := test_cache()
	return {free_heads = cache.free_heads, words_ready = cache.words_ready, drawn = counts().drawn}
}

// The width of a work row at its bound, at the size of a line of 16
// pixels, in a frame of one third for each unit: a glyph of exactly 512
// columns is drawn, kept, and its box is inside its row. A glyph of 513
// columns is refused; so is a glyph with points near 2^24 units on either
// side, whose places pass PLACE_LIMIT. A refused glyph takes no word and
// no run of the cache: it keeps one entry with no words, so it is not
// drawn again at each frame, and it counts once as refused.
@(test)
a_work_row_past_its_bound_is_refused :: proc(t: ^testing.T) {
	test_state_take()
	font, words := test_font_open(t)
	defer delete(words)
	defer delete(font.bytes)
	state.fonts[.B612].stated.advance = THIRD_FRAME
	frame_begin()
	job, problem := raster_begin(.Interface, .B612, int(Test_Glyph.Columns_512), TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, problem, Raster_Problem.None)
	testing.expect_value(t, job.columns, WORK_COLUMN_LIMIT)
	entry, _, source := private_glyph(.Interface, .B612, int(Test_Glyph.Columns_512), TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
	testing.expect(t, int(entry.width) <= WORK_COLUMN_LIMIT && entry.row_count > 0)
	for kind in ([3]Test_Glyph{.Columns_513, .Far_Right, .Far_Left}) {
		for size in ([2]int{TEXT_SIZE_OF_SCALE_ONE, TEXT_SIZE_LIMIT}) {
			_, refused := raster_begin(.Interface, .B612, int(kind), size, 0)
			testing.expectf(t, refused == .Refused, "%v at size %v: %v, expected Refused", kind, size, refused)
			before := cache_picture()
			refused_count := counts().refused
			_, glyph_words, glyph_source := private_glyph(.Interface, .B612, int(kind), size, 0)
			testing.expectf(t, glyph_source == .Missing && glyph_words == nil, "%v at size %v: no glyph", kind, size)
			testing.expect_value(t, counts().refused, refused_count + 1)
			testing.expect(t, cache_picture() == before)
			// Again: the entry with no words, and no second count.
			_, _, glyph_source = private_glyph(.Interface, .B612, int(kind), size, 0)
			testing.expect(t, glyph_source == .Missing && counts().refused == refused_count + 1)
		}
	}
}

// The contours of one outline at their bound: CONTOUR_LIMIT contours are
// read, one more is refused, with nothing drawn.
@(test)
the_contours_of_an_outline_at_their_bound :: proc(t: ^testing.T) {
	test_state_take()
	font, words := test_font_open(t)
	defer delete(words)
	defer delete(font.bytes)
	_, problem := glyph_raster(.Interface, .B612, int(Test_Glyph.Contours_128), TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, problem, Raster_Problem.None)
	before := cache_picture()
	_, problem = glyph_raster(.Interface, .B612, int(Test_Glyph.Contours_129), TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, problem, Raster_Problem.Refused)
	_, _, source := private_glyph(.Interface, .B612, int(Test_Glyph.Contours_129), TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, source, Glyph_Source.Missing)
	testing.expect(t, cache_picture() == before)
}

// Points far above, below and left of the line: the bands stay inside the
// rows of the line, the box of the ink is inside them, and its left side
// is left of the origin, inside an i16. The frame of B612 here.
@(test)
the_bands_stay_inside_the_line :: proc(t: ^testing.T) {
	test_state_take()
	font, words := test_font_open(t)
	defer delete(words)
	defer delete(font.bytes)
	for size in ([3]int{TEXT_SIZE_MINIMUM, TEXT_SIZE_OF_SCALE_ONE, 3 * TEXT_SIZE_OF_SCALE_ONE}) {
		job, problem := raster_begin(.Interface, .B612, int(Test_Glyph.Past_The_Line), size, 0)
		testing.expect_value(t, problem, Raster_Problem.None)
		testing.expectf(t, job.row_first == 0 && job.row_end == line_rows(size), "size %v: the rows %v to %v, the line %v", size, job.row_first, job.row_end, line_rows(size))
		for {
			first, rows, _ := band_next(&job)
			if rows == 0 {
				break
			}
			testing.expectf(t, first >= 0 && first + rows <= line_rows(size), "size %v: a band of %v rows at %v", size, rows, first)
		}
		testing.expect(t, !job.failed)
		box, raster_problem := glyph_raster(.Interface, .B612, int(Test_Glyph.Past_The_Line), size, 0)
		testing.expect_value(t, raster_problem, Raster_Problem.None)
		testing.expectf(t, box.first_row >= 0 && box.first_row + box.row_count <= line_rows(size) && box.row_count > 0, "size %v: the box %v", size, box)
		testing.expectf(t, box.left < 0 && box.left >= int(min(i16)), "size %v: the left side %v", size, box.left)
	}
}

// The edges of the bounds of a place and of a work row, as pure values:
// a place at PLACE_LIMIT on either side is inside it, one past it is not,
// nor the largest values of the type. A row whose columns reach an i16
// from the origin fits; one column past it on either side does not. A row
// of WORK_COLUMN_LIMIT columns fits, one more does not.
@(test)
the_edges_of_a_place_and_of_a_work_row :: proc(t: ^testing.T) {
	for place in ([4]i64{0, PLACE_LIMIT, -PLACE_LIMIT, 1}) {
		testing.expectf(t, place_within(place), "the place %v is inside the bound", place)
	}
	for place in ([4]i64{PLACE_LIMIT + 1, -PLACE_LIMIT - 1, max(i64), min(i64)}) {
		testing.expectf(t, !place_within(place), "the place %v is past the bound", place)
	}
	Row :: struct {
		low_x, high_x: i64,
		fits:          bool,
	}
	THIRD :: i64(SUBUNITS)
	rows := [?]Row {
		// 512 and 513 columns from the origin.
		{0, 1523 * THIRD, true},
		{0, 1526 * THIRD, false},
		// The left side at min(i16), and one pixel past it.
		{-98299 * THIRD, -98299 * THIRD + 10 * THIRD, true},
		{-98300 * THIRD, -98300 * THIRD + 10 * THIRD, false},
		// The right side at max(i16), and one pixel past it.
		{98299 * THIRD - 10 * THIRD, 98299 * THIRD, true},
		{98300 * THIRD - 10 * THIRD, 98300 * THIRD, false},
		// The bound of a place on either side: far past an i16.
		{PLACE_LIMIT - THIRD, PLACE_LIMIT, false},
		{-PLACE_LIMIT, -PLACE_LIMIT + THIRD, false},
	}
	for row in rows {
		columns, origin_column, fits := work_columns(row.low_x, row.high_x, 0)
		testing.expectf(t, fits == row.fits, "the points %v to %v: fits %v, expected %v", row.low_x, row.high_x, fits, row.fits)
		if fits {
			testing.expect(t, columns >= 1 && columns <= WORK_COLUMN_LIMIT)
			testing.expect(t, -origin_column >= int(min(i16)) && -origin_column + columns - 1 <= int(max(i16)))
		}
	}
}

// The glyph index of a key at its bound: 0xFFFF is keyed (the font has no
// such glyph, so the renderer refuses it once); 0x10000 is refused before
// any key, and changes no entry and no count, since its key would be the
// key of the glyph 0.
@(test)
a_glyph_index_past_16_bits_has_no_key :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	frame_begin()
	_, _, source := private_glyph(.Interface, .B612, GLYPH_INDEX_LIMIT, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, source, Glyph_Source.Missing)
	testing.expect_value(t, counts().refused, u64(1))
	testing.expect(t, entry_find(test_cache(), key_of(.Interface, .B612, GLYPH_INDEX_LIMIT, TEXT_SIZE_OF_SCALE_ONE, 0)) >= 0)
	used := test_cache().entries_used
	for index in ([3]int{GLYPH_INDEX_LIMIT + 1, -1, max(int)}) {
		_, _, refused := private_glyph(.Interface, .B612, index, TEXT_SIZE_OF_SCALE_ONE, 0)
		testing.expectf(t, refused == .Missing, "glyph %v: no glyph", index)
	}
	testing.expect_value(t, counts(), Private_Counts{refused = 1})
	testing.expect_value(t, test_cache().entries_used, used)
}

// Before a copy has its glyph memory, a glyph is Banded, the copy asks
// for the memory, and the small band gives, one row at a time, the words
// of the glyph that the glyph memory draws whole.
@(test)
the_small_band_gives_the_words_of_the_glyph_memory :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	OMEGA :: rune(0x03A9)
	cache_state = {}
	testing.expect(t, !memory_wanted())
	_, glyph_words, source := glyph(.Interface, OMEGA, 3 * TEXT_SIZE_OF_SCALE_ONE, 1)
	testing.expect(t, source == .Banded && glyph_words == nil)
	testing.expect(t, memory_wanted())
	testing.expect_value(t, counts().banded, u64(1))
	_, no_memory := glyph_raster(.Interface, .B612, 0, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, no_memory, Raster_Problem.No_Memory)
	job, started := glyph_bands(.Interface, OMEGA, 3 * TEXT_SIZE_OF_SCALE_ONE, 1)
	testing.expect(t, started)
	rows := make([]u32, job.columns * LINE_ROW_LIMIT)
	defer delete(rows)
	for {
		first, count, band_words := band_next(&job)
		if count == 0 {
			break
		}
		testing.expect_value(t, count, 1)
		copy(rows[first * job.columns:][:job.columns], band_words[:job.columns])
	}
	testing.expect(t, !job.failed)
	memory_reset_for_test()
	testing.expect(t, !memory_wanted())
	font, index := font_glyph_of(.Interface, OMEGA)
	box, problem := glyph_raster(.Interface, font, index, 3 * TEXT_SIZE_OF_SCALE_ONE, 1)
	testing.expect_value(t, problem, Raster_Problem.None)
	testing.expect_value(t, box.stride, job.columns)
	box_column := box.left + job.origin_column
	differ := 0
	for row in 0 ..< box.row_count {
		whole := test_words()[box.first_word + row * box.stride:][:box.width]
		banded := rows[(box.first_row + row) * job.columns + box_column:][:box.width]
		if mem.compare(mem.slice_to_bytes(whole), mem.slice_to_bytes(banded)) != 0 {
			differ += 1
		}
	}
	testing.expectf(t, differ == 0 && box.row_count > 0, "%v rows of the small band differ", differ)
}
