#+build !freestanding
package text_rendering

import "core:testing"
import "modus:support/vector_font"

@(private = "file")
candidate_file := #load("../../../../resources/fonts/jetbrains_mono.ttf")

// A candidate font opened as the font of the cells of a set of its own
// (font_file_open) draws through the faces of that set (glyph_bands_in).
// First what is refused: the font None, bytes that are no font (none, and
// the font cut short), and for the draw the face None, a face whose first
// font the set lacks, the sizes that size_check refuses, a position out of
// the face, and a character that the font lacks. Last, each character of
// ASCII of the face Cells at the sizes of the scales 1, 2 and 3 gives,
// row by row, the words that vector_font.glyph_render draws in a cell of
// the same font: the cells whose golden hash the tests of vector_font hold
// (golden_cells_of_a_candidate).
@(test)
a_candidate_font_draws_through_a_set :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	outline := outline_of(&outline_memory)

	refused: Font_Set
	testing.expect(t, font_file_open(&refused, .None, candidate_file, &outline) != .None)
	testing.expect(t, font_file_open(&refused, .Paper_Mono, nil, &outline) != .None)
	testing.expect(t, font_file_open(&refused, .Paper_Mono, candidate_file[:64], &outline) != .None)
	testing.expect(t, !refused.fonts[.Paper_Mono].opened)
	_, refused_started := glyph_bands_in(&refused, .Cells, 'A', TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect(t, !refused_started)

	set: Font_Set
	testing.expect_value(t, font_file_open(&set, .Paper_Mono, candidate_file, &outline), vector_font.Font_Problem.None)
	testing.expect(t, set.opened && set.fonts[.Paper_Mono].opened)
	for face in ([3]Face{.None, .Interface, .Cells_Bold}) {
		_, started := glyph_bands_in(&set, face, 'A', TEXT_SIZE_OF_SCALE_ONE, 0)
		testing.expectf(t, !started, "the face %v draws from a set without its first font", face)
	}
	for size in ([5]int{0, 1, TEXT_SIZE_MINIMUM - 1, TEXT_SIZE_LIMIT + 1, -TEXT_SIZE_OF_SCALE_ONE}) {
		_, started := glyph_bands_in(&set, .Cells, 'A', size, 0)
		testing.expectf(t, !started, "the size %v is refused", size)
	}
	for position in ([2]int{-1, 1}) {
		_, started := glyph_bands_in(&set, .Cells, 'A', TEXT_SIZE_OF_SCALE_ONE, position)
		testing.expectf(t, !started, "the position %v is refused", position)
	}
	_, lacks := glyph_bands_in(&set, .Cells, 0x0416, TEXT_SIZE_OF_SCALE_ONE, 0) // Ж: no Cyrillic in the subset.
	testing.expect(t, !lacks)

	file, problem := vector_font.font_open(candidate_file)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	render := new(vector_font.Render_Memory)
	defer free(render)
	measures: vector_font.Font_Measures
	measures, problem = vector_font.font_measures(&file, render)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	pixels: [vector_font.CELL_WIDTH_LIMIT * vector_font.CELL_HEIGHT_LIMIT]u32
	differences := 0
	for scale in 1 ..= 3 {
		style := vector_font.glyph_style_of(measures, 8 * scale, 16 * scale, true)
		for character in rune(33) ..= 126 {
			testing.expect_value(t, vector_font.glyph_render(&file, measures, style, character, render, pixels[:]), vector_font.Font_Problem.None)
			job, started := glyph_bands_in(&set, .Cells, character, size_of_scale(scale), 0)
			testing.expectf(t, started && job.columns == style.cell_width, "%c at scale %v: a cell of %v columns", character, scale, job.columns)
			drawn: [vector_font.CELL_WIDTH_LIMIT * vector_font.CELL_HEIGHT_LIMIT]u32
			for {
				first_row, row_count, band_words := band_next(&job)
				if row_count == 0 {
					break
				}
				for row in 0 ..< row_count {
					copy(drawn[(first_row + row) * style.cell_width:][:style.cell_width], band_words[row * job.columns:][:style.cell_width])
				}
			}
			for word, index in drawn[:style.cell_width * style.cell_height] {
				differences += int(word != pixels[index])
			}
		}
	}
	testing.expectf(t, differences == 0, "the cells of the candidate differ from glyph_render in %v words", differences)
}
