#+build !freestanding
package vector_font

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "modus:contract/glyph_cache"

// The cost of a glyph that a process draws for itself, past the glyph
// cache (src/md/features/glyphs_on_demand.md, "The measures"): the time of
// the renderer for one glyph at each scale, and the words that the glyph
// keeps. It prints measures and asserts nothing. It measures only when the
// environment sets MODUS_MEASURE_PRIVATE_GLYPHS, as it takes about 20 s:
//
//   MODUS_MEASURE_PRIVATE_GLYPHS=1 taskset -c 5 odin test src/library/support/vector_font -o:speed -collection:modus=src/library -define:ODIN_TEST_NAMES=vector_font.private_glyph_measure
//
// Each time is the least of many batches, so that an interruption of the
// host does not count. The fonts of the repository are subsets with no
// dense script. A dense outline is measured when the environment names a
// TrueType font with such characters: MODUS_MEASURE_DENSE_FONT, the path
// of a file or of a collection (its first face).

@(private = "file")
measure_b612 := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
measure_paper_mono := #load("../../../../resources/fonts/paper_mono.ttf")

@(private = "file")
MEASURE_BATCHES :: 200

// The bytes that the private cache keeps for each glyph beside its words:
// its key, its glyph entry, its advance, its place in the order of use and
// in the table.
@(private = "file")
MEASURE_ENTRY_BYTES :: 48

@(private = "file")
Measure_Sample :: struct {
	name:       string,
	font:       ^Font_File,
	measures:   Font_Measures,
	characters: []rune,
	cells:      bool, // Drawn into a cell, as a face of cells; else placed, as the interface font.
	grid_fit:   bool,
}

@(private = "file")
Measure_Result :: struct {
	least_nanoseconds: f64, // The least time of one glyph, over the batches.
	words:             int, // The words of the glyphs of one batch.
	widest_words:      int, // The words of the largest glyph.
	glyphs:            int, // The glyphs of one batch.
}

// measure_glyphs draws each character of a sample at one scale, each
// batch, and gives the least time of one glyph and the words that the
// glyphs keep: the box of the ink, as the cache keeps it.
@(private = "file")
measure_glyphs :: proc(sample: ^Measure_Sample, scale: int, memory: ^Render_Memory) -> (result: Measure_Result) {
	style := glyph_style_of(sample.measures, 8 * scale, 16 * scale, sample.grid_fit)
	least := max(i64)
	pixels: [CELL_WIDTH_LIMIT * CELL_HEIGHT_LIMIT]u32
	for batch in 0 ..< MEASURE_BATCHES {
		words, widest, glyphs := 0, 0, 0
		start := time.tick_now()
		for character in sample.characters {
			if sample.cells {
				if glyph_render(sample.font, sample.measures, style, character, memory, pixels[:]) != .None {
					continue
				}
				if batch == 0 {
					first, last := style.cell_height, -1
					for row in 0 ..< style.cell_height {
						for word in pixels[row * style.cell_width:][:style.cell_width] {
							if word != 0 {
								first, last = min(first, row), max(last, row)
							}
						}
					}
					count := last >= first ? (last - first + 1) * style.cell_width : 0
					words += count
					widest = max(widest, count)
				}
			} else {
				box, problem := glyph_render_placed(sample.font, sample.measures, style, character, 0, 1, memory)
				if problem != .None {
					continue
				}
				if batch == 0 {
					words += box.row_count * box.width
					widest = max(widest, box.row_count * box.width)
				}
			}
			glyphs += 1
		}
		least = min(least, time.duration_nanoseconds(time.tick_since(start)))
		if batch == 0 {
			result.words, result.widest_words, result.glyphs = words, widest, glyphs
		}
	}
	result.least_nanoseconds = f64(least) / f64(max(result.glyphs, 1))
	return result
}

@(private = "file")
measure_print :: proc(sample: ^Measure_Sample, memory: ^Render_Memory) {
	for scale in 1 ..= glyph_cache.SIZE_LIMIT {
		result := measure_glyphs(sample, scale, memory)
		mean_words := f64(result.words) / f64(max(result.glyphs, 1))
		mean_bytes := mean_words * 4 + MEASURE_ENTRY_BYTES
		fmt.printfln("vector_font: private glyph, %s, scale %v: %.0f ns for one glyph (the least of %v batches of %v glyphs); %.0f words on the mean, %v at most; %.0f bytes with its entry; a working set of 300: %.0f KiB, 3 000: %.0f KiB, 10 000: %.0f KiB", sample.name, scale, result.least_nanoseconds, MEASURE_BATCHES, result.glyphs, mean_words, result.widest_words, mean_bytes, 300 * mean_bytes / 1024, 3000 * mean_bytes / 1024, 10000 * mean_bytes / 1024)
	}
}

@(test)
private_glyph_measure :: proc(t: ^testing.T) {
	if os.get_env("MODUS_MEASURE_PRIVATE_GLYPHS", context.temp_allocator) == "" {
		return
	}
	memory := new(Render_Memory)
	defer free(memory)
	b612, problem := font_open(measure_b612)
	testing.expect_value(t, problem, Font_Problem.None)
	paper_mono: Font_File
	paper_mono, problem = font_open(measure_paper_mono)
	testing.expect_value(t, problem, Font_Problem.None)
	b612_measures, paper_measures: Font_Measures
	b612_measures, problem = font_measures(&b612, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	b612_measures, problem = proportional_measures(&b612, b612_measures)
	testing.expect_value(t, problem, Font_Problem.None)
	paper_measures, problem = font_measures(&paper_mono, memory)
	testing.expect_value(t, problem, Font_Problem.None)

	latin: [dynamic]rune
	defer delete(latin)
	for character in rune(0x21) ..= 0x7E {
		append(&latin, character)
	}
	greek: [dynamic]rune
	defer delete(greek)
	for character in rune(0x0391) ..= 0x03C9 {
		if _, missing := glyph_of(&b612, character); missing == .None {
			append(&greek, character)
		}
	}
	box: [dynamic]rune
	defer delete(box)
	for character in rune(0x2500) ..= 0x259F {
		append(&box, character)
	}
	samples := [?]Measure_Sample {
		{name = "Latin of B612, placed", font = &b612, measures = b612_measures, characters = latin[:], grid_fit = true},
		{name = "Greek of B612, placed", font = &b612, measures = b612_measures, characters = greek[:], grid_fit = true},
		{name = "Latin of Paper Mono, in cells", font = &paper_mono, measures = paper_measures, characters = latin[:], cells = true, grid_fit = true},
		{name = "box drawing of Paper Mono, in cells", font = &paper_mono, measures = paper_measures, characters = box[:], cells = true, grid_fit = true},
	}
	for &sample in samples {
		measure_print(&sample, memory)
	}

	path := os.get_env("MODUS_MEASURE_DENSE_FONT", context.temp_allocator)
	if path == "" {
		fmt.println("vector_font: private glyph, dense outlines: not measured; MODUS_MEASURE_DENSE_FONT names no font")
		return
	}
	bytes, error := os.read_entire_file(path, context.allocator)
	if error != nil {
		fmt.printfln("vector_font: private glyph, dense outlines: not measured; %s does not read", path)
		return
	}
	defer delete(bytes)
	directory: int
	directory, problem = collection_face_offset(bytes, 0)
	testing.expect_value(t, problem, Font_Problem.None)
	dense: Font_File
	dense, problem = font_open(bytes, directory)
	testing.expect_value(t, problem, Font_Problem.None)
	dense_measures: Font_Measures
	dense_measures, problem = font_measures(&dense, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	dense_measures, problem = proportional_measures(&dense, dense_measures)
	testing.expect_value(t, problem, Font_Problem.None)
	// The 500 ideographs from U+4E00 that the font has: the first block of
	// the unified ideographs, dense and of many contours.
	ideographs: [dynamic]rune
	defer delete(ideographs)
	points, most_points: int
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for character in rune(0x4E00) ..= 0x9FFF {
		glyph, missing := glyph_of(&dense, character)
		if missing != .None || glyph_outline(&dense, glyph, &outline) != .None {
			continue
		}
		points += outline.point_count
		most_points = max(most_points, outline.point_count)
		append(&ideographs, character)
		if len(ideographs) == 500 {
			break
		}
	}
	fmt.printfln("vector_font: private glyph, dense outlines: %v ideographs, %.0f points on the mean, %v at most", len(ideographs), f64(points) / f64(max(len(ideographs), 1)), most_points)
	dense_sample := Measure_Sample{name = "ideographs, placed", font = &dense, measures = dense_measures, characters = ideographs[:], grid_fit = true}
	measure_print(&dense_sample, memory)
}
