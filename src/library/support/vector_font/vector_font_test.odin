#+build !freestanding
package vector_font

import "core:fmt"
import "modus:contract/font_characters"
import "core:testing"

@(private = "file")
font_bytes := #load("../../../../resources/fonts/dejavu_sans_mono.ttf")

@(test)
reads_the_font :: proc(t: ^testing.T) {
	font, problem := font_open(font_bytes)
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect_value(t, font.units_per_em, 2048)
	memory := new(Render_Memory)
	defer free(memory)
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for character in rune(33) ..= 126 {
		glyph, found := glyph_of(&font, character)
		testing.expectf(t, found == .None && glyph != 0, "%c has a glyph", character)
		testing.expectf(t, glyph_outline(&font, glyph, &outline) == .None && outline.point_count > 0, "%c has an outline", character)
		testing.expect_value(t, outline.advance, 1233) // A monospace font.
	}
	measures, measured := font_measures(&font, memory)
	testing.expect_value(t, measured, Font_Problem.None)
	testing.expect(t, measures.monospace)
}

// A file cut at any length, or with bytes changed, gives a problem and no
// fault: each read is checked. The glyphs that it reads are drawn too.
@(test)
hostile_files :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	pixels: [CELL_WIDTH_LIMIT * CELL_HEIGHT_LIMIT]u32
	measures := Font_Measures{advance = 1233, x_height = 1120, cap_height = 1493, top = 1901, bottom = -483, monospace = true}
	try :: proc(bytes: []u8, measures: Font_Measures, memory: ^Render_Memory, pixels: []u32) {
		font, problem := font_open(bytes)
		if problem != .None {
			return
		}
		_, _ = font_measures(&font, memory)
		for scale in 1 ..= 3 {
			style := glyph_style_of(measures, 8 * scale, 16 * scale, scale == 1)
			for character in rune(0) ..= 130 {
				_ = glyph_render(&font, measures, style, character, memory, pixels)
			}
		}
	}
	for length := 0; length < len(font_bytes); length += 211 {
		try(font_bytes[:length], measures, memory, pixels[:])
	}
	changed := make([]u8, len(font_bytes))
	defer delete(changed)
	for seed in 0 ..< 48 {
		copy(changed, font_bytes)
		state := u32(seed * 2654435761 + 1)
		for _ in 0 ..< 64 {
			state = state * 1664525 + 1013904223
			changed[int(state >> 8) % len(changed)] = u8(state >> 24)
		}
		try(changed, measures, memory, pixels[:])
	}
}

// A polygon in subunits; its area by the shoelace sum, in the units of
// coverage_sum (1 / FULL_PIXEL of a pixel: 2 for each square subunit).
@(private = "file")
polygon_add :: proc(target: ^Accumulation, points: [][2]i32) -> (area: i64) {
	for point, index in points {
		next := points[(index + 1) % len(points)]
		line_add(target, point.x, point.y, next.x, next.y)
		area += i64(point.x) * i64(next.y) - i64(next.x) * i64(point.y)
	}
	return abs(area) // Twice the area in square subunits.
}

// The sum of the coverage of a closed outline is its area: exact for edges
// that the cuts do not round (along the axes, at 45 degrees), within the
// rounding of the cut points for any other edge.
@(test)
coverage_is_the_area :: proc(t: ^testing.T) {
	cells: [(32 + 1) * 32]i32
	target, ok := accumulation_of(cells[:], 32, 32)
	testing.expect(t, ok)
	shapes := [][][2]i32 {
		{{300, 300}, {5000, 300}, {5000, 4000}, {300, 4000}}, // A rectangle at subunits that are not on a pixel.
		{{256, 256}, {2560, 256}, {256, 2560}}, // A triangle at 45 degrees.
		{{1000, 1000}, {3000, 3000}, {1000, 5000}}, // Two edges at 45 degrees, from a point inside a pixel.
		{{0, 0}, {8192, 0}, {8192, 8192}, {0, 8192}}, // The whole accumulation.
	}
	for shape in shapes {
		area := polygon_add(&target, shape)
		testing.expectf(t, abs(coverage_sum(&target)) == area, "a shape of %v: coverage %v, area %v", len(shape), coverage_sum(&target), area)
		scratch: [32 * 32]u8
		coverage_finish(&target, scratch[:])
	}
	worst: f64
	// Convex polygons (points on a circle): no crossing, the area compares.
	for count in 3 ..= 12 {
		points: [12][2]i32
		// The points of a regular polygon from a table of sines in 1/1024.
		SINES := [12][2]i32{{1024, 0}, {887, 512}, {512, 887}, {0, 1024}, {-512, 887}, {-887, 512}, {-1024, 0}, {-887, -512}, {-512, -887}, {0, -1024}, {512, -887}, {887, -512}}
		for index in 0 ..< count {
			direction := SINES[(index * 12) / count]
			points[index] = {4100 + direction.x * 3, 4000 + direction.y * 3}
		}
		area := polygon_add(&target, points[:count])
		sum := coverage_sum(&target)
		difference := f64(abs(abs(sum) - area)) / f64(area)
		worst = max(worst, difference)
		scratch: [32 * 32]u8
		coverage_finish(&target, scratch[:])
	}
	testing.expectf(t, worst < 0.0005, "a convex polygon: the coverage differs from the area by %v of the area", worst)
	fmt.printfln("vector_font: the coverage of a convex polygon differs from its area by at most %.6f of the area", worst)
}

// A vertical edge exactly on the right side of the last column, with a
// width of 1 and of 2: the accumulation has a cell for it, and each pixel
// is full. An outline that passes the sides is cut, and the coverage of the
// pixels inside stays exact.
@(test)
the_last_column :: proc(t: ^testing.T) {
	for width in 1 ..= 3 {
		cells: [(3 + 1) * 4]i32
		target, ok := accumulation_of(cells[:], width, 4)
		testing.expect(t, ok)
		right := i32(width * SUBUNITS_PER_PIXEL)
		_ = polygon_add(&target, {{0, 0}, {right, 0}, {right, 1024}, {0, 1024}})
		coverage: [3 * 4]u8
		coverage_finish(&target, coverage[:])
		for value in coverage[:width * 4] {
			testing.expectf(t, value == 255, "width %v: a pixel is %v, not full", width, value)
		}
		// Wider than the accumulation on both sides, and higher.
		_ = polygon_add(&target, {{-700, -300}, {right + 900, -300}, {right + 900, 1500}, {-700, 1500}})
		coverage_finish(&target, coverage[:])
		for value in coverage[:width * 4] {
			testing.expectf(t, value == 255, "width %v, an outline past the sides: a pixel is %v, not full", width, value)
		}
		// A vertical edge on the right side only: the pixel left of it is
		// full, nothing passes the end of a row.
		_ = polygon_add(&target, {{right - 128, 0}, {right, 0}, {right, 1024}, {right - 128, 1024}})
		coverage_finish(&target, coverage[:])
		testing.expect_value(t, coverage[width - 1], 128)
		// The accumulation is clear after a finish.
		for cell in cells[:(width + 1) * 4] {
			testing.expect_value(t, cell, 0)
		}
	}
}

// The filter: the fringe (the largest difference between two stripes of
// one pixel) and the spread (the thirds with more than 10 percent of ink)
// of each filter, on a stem of one pixel at the three places of a third.
@(test)
filters_measured :: proc(t: ^testing.T) {
	for filter in Stripe_Filter {
		fringe, spread, peak := 0, 0, 0
		for phase in 0 ..< 3 {
			thirds: [30]u8
			for index in 12 + phase ..< 15 + phase {
				thirds[index] = 255
			}
			out: [30]u8
			stripes_filter(thirds[:], out[:], filter)
			for pixel in 0 ..< 10 {
				values := out[3 * pixel:][:3]
				fringe = max(fringe, int(max(values[0], values[1], values[2])) - int(min(values[0], values[1], values[2])))
			}
			for value in out {
				if value > 25 {
					spread += 1
				}
				peak = max(peak, int(value))
			}
		}
		fmt.printfln("vector_font: filter %v: fringe %v of 255, %v thirds with ink for a stem of 3 thirds, peak %v", filter, fringe, spread / 3, peak)
	}
}

// golden_hashes_of draws the characters of ASCII of a font into cells
// with glyph_render at the scales 1, 2 and 3, with the grid fit, and gives
// the hash of each scale: for each character in the order of its character
// index, its first row with ink and its count of rows with ink, then the
// words of those rows. A glyph with no ink is the row 0 and no row. A
// hook can change one word of the cells before the hash.
@(private = "file")
golden_hashes_of :: proc(t: ^testing.T, bytes: []u8, change: proc(scale: int, character: rune, pixels: []u32) = nil) -> (hashes: [3]u64) {
	font, problem := font_open(bytes)
	testing.expect_value(t, problem, Font_Problem.None)
	memory := new(Render_Memory)
	defer free(memory)
	measures: Font_Measures
	measures, problem = font_measures(&font, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	pixels: [CELL_WIDTH_LIMIT * CELL_HEIGHT_LIMIT]u32
	for scale in 1 ..= 3 {
		style := glyph_style_of(measures, 8 * scale, 16 * scale, true)
		hash: u64 = 0xCBF2_9CE4_8422_2325
		for index in 0 ..< font_characters.ASCII_COUNT {
			character, _ := font_characters.character_of_index(index)
			testing.expect_value(t, glyph_render(&font, measures, style, character, memory, pixels[:]), Font_Problem.None)
			if change != nil {
				change(scale, character, pixels[:style.cell_width * style.cell_height])
			}
			first, last := style.cell_height, -1
			for row in 0 ..< style.cell_height {
				for word in pixels[row * style.cell_width:][:style.cell_width] {
					if word != 0 {
						first = min(first, row)
						last = max(last, row)
					}
				}
			}
			first_row, row_count := 0, 0
			if last >= first {
				first_row, row_count = first, last - first + 1
			}
			hash = (hash ~ u64(first_row) << 16 ~ u64(row_count)) * 0x0000_0100_0000_01B3
			for word in pixels[first_row * style.cell_width:][:row_count * style.cell_width] {
				hash = (hash ~ u64(word)) * 0x0000_0100_0000_01B3
			}
		}
		hashes[scale - 1] = hash
	}
	return hashes
}

// The cells of one fixed font, JetBrains Mono (a candidate, not the
// default: a test of the renderer must not change when the default
// changes): its words at each scale have a known hash, so that a change of
// the renderer is seen. A change that is wanted gives new hashes here and a
// new RENDERER_VERSION. A change of one word of one glyph changes the hash
// of its scale only; the same font drawn again gives the same hashes.
@(test)
golden_cells_of_a_candidate :: proc(t: ^testing.T) {
	bytes := #load("../../../../resources/fonts/jetbrains_mono.ttf")
	changed := golden_hashes_of(t, bytes, proc(scale: int, character: rune, pixels: []u32) {
		if scale == 2 && character == 'g' {
			pixels[len(pixels) / 2] ~= 1
		}
	})
	testing.expect(t, changed[0] == GOLDEN_HASHES[0] && changed[1] != GOLDEN_HASHES[1] && changed[2] == GOLDEN_HASHES[2], "one word of g at scale 2 changes the hash of the scale 2 only")
	hashes := golden_hashes_of(t, bytes)
	fmt.printfln("vector_font: the cells of jetbrains_mono, the hashes of its scales %16x %16x %16x", hashes[0], hashes[1], hashes[2])
	testing.expect_value(t, hashes, GOLDEN_HASHES)
	testing.expect_value(t, golden_hashes_of(t, bytes), hashes)
}

// The hashes of the words of the three scales of the cells of JetBrains
// Mono, renderer version 1: the hashes that its glyph cache had.
GOLDEN_HASHES :: [3]u64{0xae38c0ced203328f, 0xc47346a333a5063b, 0x8eb7b6620568c018}

// A vertical segment on the last column, and a coverage of width 1, write
// nothing outside their rows: the cell after the accumulation stays 0. The
// rasterizer in floating point that came before wrote there.
@(test)
segments_at_the_edges_stay_in_their_rows :: proc(t: ^testing.T) {
	cells: [(5 + 1) * 3 + 1]i32
	target, ok := accumulation_of(cells[:(5 + 1) * 3], 5, 3)
	testing.expect(t, ok)
	line_add(&target, 4 * SUBUNITS_PER_PIXEL, 0, 4 * SUBUNITS_PER_PIXEL, 3 * SUBUNITS_PER_PIXEL)
	line_add(&target, 5 * SUBUNITS_PER_PIXEL, 0, 5 * SUBUNITS_PER_PIXEL, 3 * SUBUNITS_PER_PIXEL)
	testing.expect_value(t, cells[(5 + 1) * 3], 0) // The cell after the last row is not touched.
	narrow_cells: [(1 + 1) * 3 + 1]i32
	narrow, narrow_ok := accumulation_of(narrow_cells[:(1 + 1) * 3], 1, 3)
	testing.expect(t, narrow_ok)
	line_add(&narrow, SUBUNITS_PER_PIXEL / 2, 0, SUBUNITS_PER_PIXEL / 2, 3 * SUBUNITS_PER_PIXEL)
	coverage: [3]u8
	coverage_finish(&narrow, coverage[:])
	testing.expect_value(t, narrow_cells[(1 + 1) * 3], 0)
}
