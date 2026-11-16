#+build !freestanding
package graphics

import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"
import "core:mem"
import "core:testing"
import "modus:support/text_shaping"
import "modus:support/vector_font"

// The glyph cache of B612 Regular, three positions at scale 1 and one at
// the scales 2 and 3, in memory that the caller frees.
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

// A text whose glyphs come from the demand cache draws the pixels of the
// same text from the glyph cache, at each third of a pixel: the font
// service draws with the renderer of the build. A glyph that the frame does
// not see yet draws the replacement glyph.
@(test)
a_text_on_demand_draws_the_pixels_of_the_glyph_cache :: proc(t: ^testing.T) {
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	render := new(vector_font.Render_Memory)
	defer free(render)
	demand_font, problem := vector_font.demand_font_open(#load("../../../../resources/fonts/b612.ttf"), true, render)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	bytes, allocation := mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	testing.expect(t, allocation == nil)
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	writer := demand_cache.writer_open(base, cache.header.font_hash, vector_font.RENDERER_VERSION, demand_font.flags)
	reader, matches := demand_cache.reader_of(base, &cache)
	testing.expect(t, matches)
	TEXT :: "Rag To é"
	for character in TEXT {
		place, search := demand_cache.place_find(&writer, character)
		if search != .Free {
			continue
		}
		entry, result := vector_font.demand_glyph_draw(&demand_font, &writer, character, render)
		testing.expect_value(t, result, vector_font.Demand_Result.Drawn)
		demand_cache.publish(&writer, place, character, entry)
	}
	demand_cache.reader_frame_begin(&reader)
	spacing, _ := text_shaping.spacing_of(&cache, 1)
	placed: [16]text_shaping.Placed_Glyph
	count, _, _ := text_shaping.shape(&spacing, transmute([]u8)string(TEXT), placed[:])
	// The same places, each glyph from the demand cache.
	on_demand := placed
	index := 0
	for character in TEXT {
		on_demand[index].glyph = text_shaping.DEMAND_GLYPH_FIRST + u32(character)
		index += 1
	}
	square_root: [4096]u8
	square_root_table_fill(&square_root)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 96
	HEIGHT :: 16
	built_pixels, demand_pixels: [WIDTH * HEIGHT]Color
	built := Canvas{pixels = raw_data(built_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	drawn := Canvas{pixels = raw_data(demand_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	for fraction in ([3]i64{0, 21, 43}) {
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, built, 2 * glyph_cache.SUBPIXEL + fraction, 0, placed[:count], 1, DARK_TEXT)
		text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, drawn, 2 * glyph_cache.SUBPIXEL + fraction, 0, on_demand[:count], 1, DARK_TEXT, &reader)
		testing.expectf(t, built_pixels == demand_pixels, "the place %v/64: the pixels of the glyph cache", fraction)
	}
	// A frame that began before the publication: the replacement glyph, as
	// a glyph that no font draws.
	reader.generation_limit = 1
	replaced := on_demand
	for &glyph in replaced[1:count] {
		glyph.glyph = text_shaping.REPLACEMENT_GLYPH
	}
	clear(built, DARK_CARD_BOTTOM)
	clear(drawn, DARK_CARD_BOTTOM)
	text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, built, 0, 0, replaced[:count], 1, DARK_TEXT, &reader)
	text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, drawn, 0, 0, on_demand[:count], 1, DARK_TEXT, &reader)
	testing.expect(t, built_pixels == demand_pixels)
}

// A valid cache of a proportional font is not a font of cells: the text of
// cells refuses it and draws with Spleen, and the bold weight refuses it.
@(test)
a_proportional_cache_is_not_a_font_of_cells :: proc(t: ^testing.T) {
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	saved := text_state
	defer text_state = saved
	text_state.has_cache = true
	problem := text_cache_use(cache)
	testing.expect_value(t, problem.kind, glyph_cache.Problem_Kind.Proportional)
	testing.expect(t, !text_state.has_cache)
	bold_problem := text_bold_cache_use(cache)
	testing.expect_value(t, bold_problem.kind, glyph_cache.Problem_Kind.Proportional)
	testing.expect(t, !text_state.has_bold_cache)
}

// The measure and the draw agree to the pixel: the ink of each of 200
// texts lies inside the box that text_width gives, widened by
// PROPORTIONAL_INK_MARGIN on each side, and inside its line. The texts and
// the places (a fraction of a pixel each) come from a generator with a
// fixed seed; the background is flat, so a pixel with ink is a pixel that
// changed.
@(test)
the_ink_lies_inside_the_measured_box :: proc(t: ^testing.T) {
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	spacing, spacing_ok := text_shaping.spacing_of(&cache, 1)
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
		placed: [40]text_shaping.Placed_Glyph
		_, width, ok := text_shaping.shape(&spacing, characters[:count], placed[:count])
		testing.expect(t, ok)
		place := i64(32 * 64) + i64(next(&state) % 64)
		for &pixel in pixels {
			pixel = DARK_CARD_BOTTOM
		}
		text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, place, LINE_TOP, placed[:count], 1, DARK_TEXT)
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

// A text far outside the canvas, a scale that the cache does not have, and
// a glyph past the characters of the cache draw nothing, and do not fault.
@(test)
a_proportional_text_outside_its_limits :: proc(t: ^testing.T) {
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	square_root: [4096]u8
	square_root_table_fill(&square_root)
	tables := new(Blend_Tables)
	defer free(tables)
	pixels: [64 * 32]Color
	canvas := Canvas{pixels = raw_data(pixels[:]), width = 64, height = 32, stride = 64}
	placed := [3]text_shaping.Placed_Glyph{{glyph = 'A' - glyph_cache.ASCII_FIRST, x = 0}, {glyph = glyph_cache.CHARACTER_COUNT, x = 640}, {glyph = 'W' - glyph_cache.ASCII_FIRST, x = max(i32)}}
	places := [?]i64{-(1 << 40), 1 << 40, -64 * 70, 64 * 70}
	for place in places {
		text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, place, 0, placed[:], 1, DARK_TEXT)
	}
	text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, 0, 0, placed[:], 4, DARK_TEXT)
	text_proportional_with(&cache, &square_root, tables, .Red_Green_Blue, canvas, 0, -1000, placed[:], 1, DARK_TEXT)
	for pixel in pixels {
		testing.expect_value(t, pixel, Color(0))
	}
}
