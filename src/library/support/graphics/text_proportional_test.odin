#+build !freestanding
package graphics

import "modus:contract/glyph_cache"
import "core:sync"
import "core:testing"
import "modus:support/text_rendering"
import "modus:support/vector_font"

// The glyph cache of B612 Regular, three positions at scale 1 and one at
// the scales 2 and 3, in memory that the caller frees: the glyphs that the
// glyph caches of the boot image held, which the build of the same font
// file draws.
@(private = "file")
b612_cache_of :: proc(t: ^testing.T) -> (cache: glyph_cache.Cache, memory: []u64) {
	bytes := #load("../../../../resources/fonts/b612.ttf")
	font, problem := vector_font.font_open(bytes)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	render := new(vector_font.Render_Memory)
	defer free(render)
	memory = make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	file := ([^]u8)(raw_data(memory))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
	positions := [3]int{3, 1, 1}
	size: int
	size, problem = vector_font.glyph_cache_build_proportional(&font, bytes, "b612", true, render, file, positions[:])
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	refused: glyph_cache.Problem
	cache, refused = glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	return cache, memory
}

// cache_text_draw draws placed glyphs of character indices at scale 1
// from a glyph cache, as the text of the interface font drew them when the
// boot image held the caches: each glyph at the nearest of the positions
// of the scale, with the blend of the text of cells. The reference of the
// pixels of a text of a face.
@(private = "file")
cache_text_draw :: proc(cache: ^glyph_cache.Cache, square_root: ^[4096]u8, tables: ^Blend_Tables, canvas: Canvas, place: i64, y: int, placed: []text_rendering.Placed_Glyph) {
	position_count := int(cache.sizes[0].position_count)
	for glyph in placed {
		pixel, position := glyph_cache.position_of(place + i64(glyph.x), position_count)
		_, entry, found := glyph_cache.glyph_of_index(cache, int(glyph.glyph), 1, position)
		if !found {
			continue
		}
		glyph_words_draw(entry, raw_data(cache.words[entry.word_offset:]), square_root, tables, .Red_Green_Blue, canvas, int(pixel), y, DARK_TEXT)
	}
}

// A text of the face Interface draws the pixels of the same text from the
// glyph cache that the build of B612 draws, at each third of a pixel: its
// glyphs of character indices and its fallback glyphs both. First what
// draws the replacement glyph: each glyph with no outlines open, and a
// fallback glyph that no font of the chain has.
@(test)
a_text_of_a_face_draws_the_pixels_of_the_glyph_cache :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	defer text_rendering.state = {}
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	TEXT :: "Rag To é"
	square_root: [4096]u8
	square_root_table_fill(&square_root)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 96
	HEIGHT :: 16
	built_pixels, drawn_pixels: [WIDTH * HEIGHT]Color
	built := Canvas{pixels = raw_data(built_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	drawn := Canvas{pixels = raw_data(drawn_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	placed: [16]text_rendering.Placed_Glyph
	count: int
	fallback: [16]text_rendering.Placed_Glyph
	// The places from the font file; then, with no outlines, the
	// replacement glyph at the place of each glyph.
	measure_words := fallback_open_for_test(t)
	defer delete(measure_words)
	spacing, spacing_ok := text_rendering.spacing_of(.Interface, text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, spacing_ok)
	count, _, _ = text_rendering.shape(&spacing, transmute([]u8)string(TEXT), placed[:])
	text_rendering.state = {}
	fallback = placed
	replaced := placed
	index := 0
	for character in TEXT {
		fallback[index].glyph = text_rendering.FALLBACK_GLYPH_FIRST + u32(character)
		replaced[index].glyph = text_rendering.REPLACEMENT_GLYPH
		index += 1
	}
	for each in ([2][]text_rendering.Placed_Glyph{placed[:count], fallback[:count]}) {
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, built, 0, 0, replaced[:count], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
		text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, drawn, 0, 0, each, text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
		testing.expect(t, built_pixels == drawn_pixels)
	}
	// A character that no font has, Ж, as a fallback glyph: the
	// replacement glyph.
	words := fallback_open_for_test(t)
	defer delete(words)
	no_font := [1]text_rendering.Placed_Glyph{{glyph = text_rendering.FALLBACK_GLYPH_FIRST + 0x0416}}
	no_glyph := [1]text_rendering.Placed_Glyph{{glyph = text_rendering.REPLACEMENT_GLYPH}}
	clear(built, DARK_CARD_BOTTOM)
	clear(drawn, DARK_CARD_BOTTOM)
	text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, built, 0, 0, no_glyph[:], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
	text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, drawn, 0, 0, no_font[:], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
	testing.expect(t, built_pixels == drawn_pixels)
	// The face: the pixels of the glyph cache, at each third of a pixel.
	text_rendering.frame_begin()
	_, _, source := text_rendering.glyph(.Interface, 'R', text_rendering.size_of_scale(1), 0)
	testing.expectf(t, source == .Private_Cache, "R comes from %v", source)
	for fraction in ([3]i64{0, 21, 43}) {
		for each in ([2][]text_rendering.Placed_Glyph{placed[:count], fallback[:count]}) {
			clear(built, DARK_CARD_BOTTOM)
			clear(drawn, DARK_CARD_BOTTOM)
			cache_text_draw(&cache, &square_root, tables, built, 2 * glyph_cache.SUBPIXEL + fraction, 0, placed[:count])
			text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, drawn, 2 * glyph_cache.SUBPIXEL + fraction, 0, each, text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
			testing.expectf(t, built_pixels == drawn_pixels, "the place %v/64: the pixels of the glyph cache", fraction)
		}
	}
}

// A proportional face is not a face of the cells: its glyphs pass their
// cells. The text of cells refuses it and draws with Spleen, and the bold
// weight refuses it: the titles are the regular weight.
@(test)
a_proportional_face_is_not_a_face_of_cells :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	defer text_rendering.state = {}
	words := fallback_open_for_test(t)
	defer delete(words)
	saved := text_state
	defer text_state = saved
	text_faces_use(.Interface, .Interface_Bold)
	testing.expect_value(t, text_state.cell_face, text_rendering.Face.None)
	testing.expect_value(t, text_state.bold_face, text_rendering.Face.None)
	testing.expect(t, !text_vector_drawn())
	text_faces_use(.Cells_Without_Grid_Fit, .Cells_Bold)
	testing.expect_value(t, text_state.cell_face, text_rendering.Face.Cells_Without_Grid_Fit)
	testing.expect_value(t, text_state.bold_face, text_rendering.Face.Cells_Bold)
}

// The measure and the draw agree to the pixel: the ink of each of 200
// texts lies inside the box that text_width gives, widened by
// PROPORTIONAL_INK_MARGIN on each side, and inside its line. The texts and
// the places (a fraction of a pixel each) come from a generator with a
// fixed seed; the background is flat, so a pixel with ink is a pixel that
// changed.
@(test)
the_ink_lies_inside_the_measured_box :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	defer text_rendering.state = {}
	words := fallback_open_for_test(t)
	defer delete(words)
	spacing, spacing_ok := text_rendering.spacing_of(.Interface, text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, spacing_ok)
	square_root: [4096]u8
	square_root_table_fill(&square_root)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 512
	HEIGHT :: 48
	LINE_TOP :: 16
	pixels := make([]Color, WIDTH * HEIGHT)
	defer delete(pixels)
	canvas := Canvas{pixels = raw_data(pixels), width = WIDTH, height = HEIGHT, stride = WIDTH}
	state := u32(12345)
	next :: proc(generator: ^u32) -> u32 {
		generator^ = generator^ * 1664525 + 1013904223
		return generator^ >> 8
	}
	outside := 0
	for _ in 0 ..< 200 {
		characters: [40]u8
		count := 1 + int(next(&state) % 40)
		for index in 0 ..< count {
			characters[index] = u8(glyph_cache.ASCII_FIRST + next(&state) % glyph_cache.ASCII_COUNT)
		}
		placed: [40]text_rendering.Placed_Glyph
		_, width, ok := text_rendering.shape(&spacing, characters[:count], placed[:count])
		testing.expect(t, ok)
		place := i64(32 * 64) + i64(next(&state) % 64)
		for &pixel in pixels {
			pixel = DARK_CARD_BOTTOM
		}
		text_rendering.frame_begin()
		text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, canvas, place, LINE_TOP, placed[:count], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
		// The box in whole pixels: from the pixel of the origin to the pixel
		// of the end, widened by the margin.
		left := int(place / 64) - PROPORTIONAL_INK_MARGIN
		right := int((place + width + 63) / 64) + PROPORTIONAL_INK_MARGIN
		for row in 0 ..< HEIGHT {
			for column in 0 ..< WIDTH {
				if pixels[row * WIDTH + column] == DARK_CARD_BOTTOM {
					continue
				}
				if column < left || column >= right || row < LINE_TOP || row >= LINE_TOP + 16 {
					outside += 1
				}
			}
		}
	}
	testing.expectf(t, outside == 0, "%v pixels of ink are outside the measured box and its margin", outside)
}

// A text far outside the canvas, the sizes 0, 1, one under
// TEXT_SIZE_MINIMUM, one past TEXT_SIZE_LIMIT and a negative size, a face
// of cells and the face None, an alpha of 0, and a glyph past the character
// indices draw nothing, and do not fault.
@(test)
a_proportional_text_outside_its_limits :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	defer text_rendering.state = {}
	words := fallback_open_for_test(t)
	defer delete(words)
	square_root: [4096]u8
	square_root_table_fill(&square_root)
	tables := new(Blend_Tables)
	defer free(tables)
	pixels: [64 * 32]Color
	canvas := Canvas{pixels = raw_data(pixels[:]), width = 64, height = 32, stride = 64}
	placed := [3]text_rendering.Placed_Glyph{{glyph = 'A' - glyph_cache.ASCII_FIRST, x = 0}, {glyph = glyph_cache.CHARACTER_COUNT, x = 640}, {glyph = 'W' - glyph_cache.ASCII_FIRST, x = max(i32)}}
	places := [?]i64{-(1 << 40), 1 << 40, -64 * 70, 64 * 70}
	for place in places {
		text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, canvas, place, 0, placed[:], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
	}
	for size in ([5]int{0, 1, text_rendering.TEXT_SIZE_MINIMUM - 1, text_rendering.TEXT_SIZE_LIMIT + 1, -text_rendering.TEXT_SIZE_OF_SCALE_ONE}) {
		text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, canvas, 0, 0, placed[:], size, DARK_TEXT)
	}
	for face in ([2]text_rendering.Face{.Cells, .None}) {
		text_proportional_with(face, &square_root, tables, .Red_Green_Blue, canvas, 0, 0, placed[:], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
	}
	text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, canvas, 0, 0, placed[:], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT, 0)
	text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, canvas, 0, -1000, placed[:], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
	past := [1]text_rendering.Placed_Glyph{{glyph = glyph_cache.CHARACTER_COUNT, x = 0}}
	text_proportional_with(.Interface, &square_root, tables, .Red_Green_Blue, canvas, 0, 0, past[:], text_rendering.TEXT_SIZE_OF_SCALE_ONE, DARK_TEXT)
	for pixel in pixels {
		testing.expect_value(t, pixel, Color(0))
	}
}
