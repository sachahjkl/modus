#+build !freestanding
package graphics

import "core:mem"
import "core:sync"
import "core:testing"
import "modus:contract/font_outlines"
import "modus:contract/glyph_cache"
import "base:runtime"
import "modus:support/text_rendering"
import "modus:support/vector_font"

// The tests of this package that read or write the text state of the
// process (text_state, and the state and the private glyph cache of
// text_rendering) run one at a time: each state is one for the process, and
// the runner runs tests on several threads. A test that only reads it takes
// the lock too: a test that writes it would change it under the reader, and
// two drawers in one private cache break its lists of runs. Each test that
// opens the outlines sets the state back to zero at its end.
fallback_test_lock: sync.Mutex

// fallback_open_for_test opens the four font files of the resource of the
// boot image in a fallback state of all zero. The caller frees the words.
@(private = "file")
test_glyph_memory: ^text_rendering.Glyph_Memory

fallback_open_for_test :: proc(t: ^testing.T) -> (words: []u64) {
	fonts := [4]font_outlines.Font_Input {
		{"b612", #load("../../../../resources/fonts/b612.ttf")},
		{"b612_bold", #load("../../../../resources/fonts/b612_bold.ttf")},
		{"paper_mono", #load("../../../../resources/fonts/paper_mono.ttf")},
		{"paper_mono_semibold", #load("../../../../resources/fonts/paper_mono_semibold.ttf")},
	}
	size := font_outlines.resource_size(fonts[:])
	words = make([]u64, (size + 7) / 8)
	bytes := ([^]u8)(raw_data(words))[:size]
	_, written := font_outlines.resource_write(fonts[:], bytes)
	testing.expect(t, written)
	outlines, problem := font_outlines.validate(bytes)
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	text_rendering.state = {}
	// The glyph memory that a process reserves at its first glyph past the
	// glyph caches: all zero at each open. It comes from the heap of the
	// process, not from the allocator of the test: the runner frees all that
	// a test allocated at its end, and the next test would get the same
	// bytes while the package still draws into them.
	if test_glyph_memory == nil {
		test_glyph_memory = new(text_rendering.Glyph_Memory, runtime.heap_allocator())
	}
	mem.zero(test_glyph_memory, size_of(text_rendering.Glyph_Memory))
	text_rendering.cache_state = {}
	text_rendering.memory_give(test_glyph_memory)
	missing := text_rendering.open(&outlines)
	testing.expect_value(t, missing, text_rendering.Outline_Fonts{})
	return words
}

// cell_ink_count counts the pixels of a canvas that differ from the
// background: those inside the cell at (left, 0) of a scale, and those
// outside it.
@(private = "file")
cell_ink_count :: proc(pixels: []Color, width, left, scale: int) -> (inside, outside: int) {
	for pixel, index in pixels {
		if pixel == DARK_CARD_BOTTOM {
			continue
		}
		column, row := index % width, index / width
		if column >= left && column < left + CELL_WIDTH * scale && row < CELL_HEIGHT * scale {
			inside += 1
		} else {
			outside += 1
		}
	}
	return inside, outside
}

// A cell draws its glyph from the face of the cells, with the blend of
// each cell, into the private glyph cache of the process. First what draws
// the replacement glyph: no outlines open, a character that no font has,
// and the setting Spleen with a character that Spleen lacks. Then 'A' from
// the face of the cells gives the pixels of 'A' from a glyph cache that the
// build of the same font file draws, at each scale: the pixels of the
// glyph caches that left the boot image. Last, a box-drawing character of
// Paper Mono and a Greek letter of B612, the second font of the chain,
// each stay in their cell.
@(test)
a_cell_of_a_face_draws_the_pixels_of_the_glyph_cache :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	defer text_rendering.state = {}
	font_bytes := #load("../../../../resources/fonts/paper_mono.ttf")
	render := new(vector_font.Render_Memory)
	defer free(render)
	font, problem := vector_font.font_open(font_bytes)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	memory := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(memory)
	file := ([^]u8)(raw_data(memory))[:vector_font.GLYPH_CACHE_LIMIT]
	size: int
	size, problem = vector_font.glyph_cache_build(&font, font_bytes, "paper_mono", true, render, file)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	cache, refused := glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)

	saved := text_state
	defer text_state = saved
	text_state_start()
	WIDTH :: 3 * CELL_WIDTH * 3
	HEIGHT :: CELL_HEIGHT * 3
	built_pixels, fallback_pixels: [WIDTH * HEIGHT]Color
	built := Canvas{pixels = raw_data(built_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	drawn := Canvas{pixels = raw_data(fallback_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}

	// The replacement glyph: no outlines, no font for Ж, and Spleen.
	Case :: enum {
		No_Outlines,
		No_Font,
		Spleen,
	}
	for each in Case {
		text_choice_set(.Vector, .Red_Green_Blue)
		text := "─"
		words: []u64
		switch each {
		case .No_Outlines:
			text_rendering.state = {}
		case .No_Font:
			words = fallback_open_for_test(t)
			text = "Ж"
		case .Spleen:
			words = fallback_open_for_test(t)
			text_choice_set(.Spleen, .Red_Green_Blue)
		}
		text_faces_use(.Cells, .Cells_Bold)
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		character_replacement(built, CELL_WIDTH, 0, DARK_TEXT, 1)
		text_scaled(drawn, CELL_WIDTH, 0, text, DARK_TEXT, 1)
		testing.expectf(t, built_pixels == fallback_pixels, "%v: the replacement glyph", each)
		delete(words)
	}
	text_choice_set(.Vector, .Red_Green_Blue)

	// 'A' from the face of the cells and from the glyph cache of the build.
	words := fallback_open_for_test(t)
	defer delete(words)
	text_faces_use(.Cells, .Cells_Bold)
	text_rendering.frame_begin()
	testing.expect_value(t, cell_face(), text_rendering.Face.Cells)
	for scale in 1 ..= 3 {
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		character_vector_with(&cache, &text_state.square_root, &text_state.blend_tables, text_state.order, built, CELL_WIDTH * scale, 0, 'A', DARK_TEXT, scale)
		text_scaled(drawn, CELL_WIDTH * scale, 0, "A", DARK_TEXT, scale)
		_, _, source := text_rendering.glyph(.Cells, 'A', text_rendering.size_of_scale(scale), 0)
		testing.expect_value(t, source, text_rendering.Glyph_Source.Private_Cache)
		testing.expectf(t, built_pixels == fallback_pixels, "scale %v: the cell of the face has the pixels of the glyph cache", scale)
	}
	// A face that the outlines do not open, and a proportional face, are
	// not faces of the cells: the text is Spleen, and the titles the
	// regular weight.
	text_faces_use(.None, .Interface_Bold)
	testing.expect_value(t, text_state.cell_face, text_rendering.Face.None)
	testing.expect_value(t, text_state.bold_face, text_rendering.Face.None)
	testing.expect(t, !text_vector_drawn())
	text_faces_use(.Interface, .Cells_Bold)
	testing.expect_value(t, text_state.cell_face, text_rendering.Face.None)
	testing.expect_value(t, text_state.bold_face, text_rendering.Face.Cells_Bold)
	text_faces_use(.Cells, .Cells_Bold)

	// ═ of Paper Mono and α of B612: each from the private glyph cache, and
	// each in its cell.
	Cell_Case :: struct {
		text:      string,
		character: rune,
		font:      text_rendering.Outline_Font,
	}
	cell_cases := [2]Cell_Case{{"═", 0x2550, .Paper_Mono}, {"α", 0x03B1, .B612}}
	for each in cell_cases {
		for scale in 1 ..= 3 {
			text_rendering.frame_begin()
			clear(drawn, DARK_CARD_BOTTOM)
			text_scaled(drawn, CELL_WIDTH * scale, 0, each.text, DARK_TEXT, scale)
			_, _, source := text_rendering.glyph(.Cells, each.character, text_rendering.size_of_scale(scale), 0)
			testing.expectf(t, source == .Private_Cache, "%v at scale %v: from %v", each.text, scale, source)
			testing.expect_value(t, text_rendering.font_of(.Cells, each.character), each.font)
			ink, outside := cell_ink_count(fallback_pixels[:], WIDTH, CELL_WIDTH * scale, scale)
			testing.expectf(t, ink > 0 && outside == 0, "scale %v: %v has %v pixels of ink in its cell and %v outside", scale, each.text, ink, outside)
			// A change of the order of the stripes in the same frame: the
			// words do not depend on it, so the glyph is not drawn again.
			drawn_before := text_rendering.counts().drawn
			text_choice_set(.Vector, .Blue_Green_Red)
			clear(drawn, DARK_CARD_BOTTOM)
			text_scaled(drawn, CELL_WIDTH * scale, 0, each.text, DARK_TEXT, scale)
			text_choice_set(.Vector, .Red_Green_Blue)
			testing.expectf(t, text_rendering.counts().drawn == drawn_before, "scale %v: a change of the order of the stripes draws no glyph again", scale)
		}
	}
}
