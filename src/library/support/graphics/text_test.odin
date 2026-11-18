#+build !freestanding
package graphics

import "modus:contract/glyph_cache"
import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"
import "modus:support/vector_font"

// The blend in linear light with a gamma of 2 (blend_coverage_row) against
// the curve of sRGB, for the text of the rules on a card: light text on a
// dark surface, the case of this system. The plain blend of the encoded
// values is the third column: the error that a blend with no gamma makes.
@(test)
blend_error_against_srgb :: proc(t: ^testing.T) {
	to_linear :: proc(value: u32) -> f64 {
		c := f64(value) / 255
		return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
	}
	to_encoded :: proc(linear: f64) -> f64 {
		return 255 * (linear <= 0.0031308 ? linear * 12.92 : 1.055 * math.pow(linear, 1 / 2.4) - 0.055)
	}
	table: [4096]u8
	square_root_table_fill(&table)
	Pair :: struct {
		front, back: Color,
	}
	pairs := [?]Pair{{DARK_TEXT, DARK_CARD_BOTTOM}, {DARK_DIM, DARK_BACKGROUND}, {DARK_PROGRAM, DARK_CARD_TOP}, {DARK_BACKGROUND, DARK_TEXT}}
	for pair in pairs {
		worst_gamma_two, worst_plain: f64
		for coverage in u32(0) ..= 255 {
			line: [1]Color = {pair.back}
			word := [1]u32{coverage << 24 | coverage << 16 | coverage << 8 | coverage}
			blend_coverage_row(raw_data(line[:]), raw_data(word[:]), 0, 1, pair.front, .Red_Green_Blue, &table)
			for shift in ([3]uint{16, 8, 0}) {
				front, back := pair.front >> shift & 0xFF, pair.back >> shift & 0xFF
				exact := to_encoded(to_linear(front) * f64(coverage) / 255 + to_linear(back) * (1 - f64(coverage) / 255))
				ours := f64(line[0] >> shift & 0xFF)
				plain := f64(back) + (f64(front) - f64(back)) * f64(coverage) / 255
				worst_gamma_two = max(worst_gamma_two, abs(ours - exact))
				worst_plain = max(worst_plain, abs(plain - exact))
			}
		}
		fmt.printfln("graphics: %06x over %06x: a gamma of 2 is at most %.1f levels from sRGB; a blend with no gamma, %.1f levels", pair.front, pair.back, worst_gamma_two, worst_plain)
		testing.expect(t, worst_gamma_two < 16)
	}
	// Coverage 0 keeps the pixel; coverage 255 on each stripe is the color.
	line := [2]Color{DARK_CARD_BOTTOM, DARK_CARD_BOTTOM}
	words := [2]u32{0, 0xFFFFFFFF}
	blend_coverage_row(raw_data(line[:]), raw_data(words[:]), 0, 2, DARK_TEXT, .Red_Green_Blue, &table)
	testing.expect_value(t, line[0], Color(DARK_CARD_BOTTOM))
	testing.expect_value(t, line[1], Color(DARK_TEXT))
	// The order blue, green, red takes the red coverage for the blue channel.
	line = {0, 0}
	words = {0x00FF0000, 0x00FF0000}
	blend_coverage_row(raw_data(line[:]), raw_data(words[:]), 0, 1, COLOR_WHITE, .Blue_Green_Red, &table)
	testing.expect_value(t, line[0], Color(0x0000FF))
}

// With no glyph cache, text draws Spleen 8x16, at each scale: the fallback.
// The text state is the zero state: no cache yet.
@(test)
text_without_cache_is_spleen :: proc(t: ^testing.T) {
	first, second: [24 * 48]Color
	a := Canvas{pixels = raw_data(first[:]), width = 24, height = 48, stride = 24}
	b := Canvas{pixels = raw_data(second[:]), width = 24, height = 48, stride = 24}
	text(a, 0, 0, "g", DARK_TEXT)
	character_spleen(b, 0, 0, 'g', DARK_TEXT)
	testing.expect(t, first == second)
	first, second = {}, {}
	text_scaled(a, 0, 0, "g", DARK_TEXT, 3)
	character_spleen_enlarged(b, 0, 0, 'g', DARK_TEXT, 3)
	testing.expect(t, first == second)
}

// A character of the Latin-1 Supplement and the euro sign draw their glyph
// of Spleen, not the replacement glyph; another character past U+00FF
// draws the replacement glyph.
// "été" takes three cells, one for each character.
@(test)
text_of_the_latin_supplement_is_drawn :: proc(t: ^testing.T) {
	drawn, glyph, replacement: [8 * 16]Color
	a := Canvas{pixels = raw_data(drawn[:]), width = 8, height = 16, stride = 8}
	b := Canvas{pixels = raw_data(glyph[:]), width = 8, height = 16, stride = 8}
	c := Canvas{pixels = raw_data(replacement[:]), width = 8, height = 16, stride = 8}
	testing.expect_value(t, text(a, 0, 0, "é", DARK_TEXT), CELL_WIDTH)
	character_spleen(b, 0, 0, 'é', DARK_TEXT)
	character_replacement(c, 0, 0, DARK_TEXT, 1)
	testing.expect(t, drawn == glyph)
	testing.expect(t, drawn != replacement)
	drawn = {}
	text(a, 0, 0, "ā", DARK_TEXT) // U+0101, past the Latin-1 Supplement.
	testing.expect(t, drawn == replacement)
	testing.expect_value(t, text_width("été"), 3 * CELL_WIDTH)
	for character in rune(glyph_cache.LATIN_FIRST) ..= glyph_cache.LATIN_LAST {
		testing.expect(t, cell_font_draws(character))
	}
	testing.expect(t, !cell_font_draws(glyph_cache.ASCII_LAST + 1))
	testing.expect(t, !cell_font_draws(glyph_cache.LATIN_FIRST - 1))
	// The euro sign, an added character, draws its glyph of Spleen: ink,
	// and not the replacement glyph.
	testing.expect(t, cell_font_draws(glyph_cache.EURO_SIGN))
	drawn, glyph = {}, {}
	testing.expect_value(t, text(a, 0, 0, "€", DARK_TEXT), CELL_WIDTH)
	character_spleen(b, 0, 0, glyph_cache.EURO_SIGN, DARK_TEXT)
	testing.expect(t, drawn == glyph)
	testing.expect(t, drawn != replacement)
	no_ink: [8 * 16]Color
	testing.expect(t, drawn != no_ink)
}

// The cost of one glyph from the glyph cache against one glyph of Spleen,
// on the host: the same order is the target (docs/FONTS.md, "Measures").
@(test)
glyph_draw_cost :: proc(t: ^testing.T) {
	bytes := #load("../../../../resources/fonts/jetbrains_mono.ttf")
	font, _ := vector_font.font_open(bytes)
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	out := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:vector_font.GLYPH_CACHE_LIMIT]
	size, problem := vector_font.glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, file)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	state: Text_State
	pixels: [64 * 48]Color
	canvas := Canvas{pixels = raw_data(pixels[:]), width = 64, height = 48, stride = 64}
	cache, _ := glyph_cache.validate(file[:size])
	square_root_table_fill(&state.square_root)
	sample := "Rag{0}%e"
	REPEAT :: 200_000
	start := time.tick_now()
	for index in 0 ..< REPEAT {
		character_vector_reference(&cache, &state.square_root, .Red_Green_Blue, canvas, 8, 8, rune(sample[index % len(sample)]), DARK_TEXT, 1)
	}
	vector := time.duration_nanoseconds(time.tick_since(start)) / REPEAT
	start = time.tick_now()
	for index in 0 ..< REPEAT {
		character_spleen(canvas, 8, 8, rune(sample[index % len(sample)]), DARK_TEXT)
	}
	spleen := time.duration_nanoseconds(time.tick_since(start)) / REPEAT
	fmt.printfln("graphics: one glyph on the host: from the glyph cache %v ns, Spleen 8x16 %v ns", vector, spleen)
}

// The fast blend gives the pixels of the reference blend, bit for bit, for
// each character at each scale, each order of the stripes, several colors,
// over a flat color, the gradient of a card, a gradient across, and noise.
@(test)
fast_blend_is_the_reference :: proc(t: ^testing.T) {
	bytes := #load("../../../../resources/fonts/jetbrains_mono.ttf")
	font, _ := vector_font.font_open(bytes)
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	out := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:vector_font.GLYPH_CACHE_LIMIT]
	size, _ := vector_font.glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, file)
	cache, _ := glyph_cache.validate(file[:size])
	table: [4096]u8
	square_root_table_fill(&table)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 24 * 96
	first := make([]Color, WIDTH * 48)
	second := make([]Color, WIDTH * 48)
	defer delete(first)
	defer delete(second)
	a := Canvas{pixels = raw_data(first), width = WIDTH, height = 48, stride = WIDTH}
	b := Canvas{pixels = raw_data(second), width = WIDTH, height = 48, stride = WIDTH}
	text_colors := [?]Color{DARK_TEXT, DARK_DIM, DARK_PROGRAM, DARK_BACKGROUND, COLOR_WHITE}
	differences := 0
	for background in Speed_Background {
		for order in Subpixel_Order {
			for color in text_colors {
				for scale in 1 ..= 3 {
					background_fill(a, background)
					background_fill(b, background)
					// Two passes: the second draws over the first, as a frame
					// drawn again, and over the tables made by the first.
					for _ in 0 ..< 2 {
						for character in 32 ..< 127 {
							x := (character - 32) * 8 * scale % (WIDTH - 24)
							character_vector_reference(&cache, &table, order, a, x, 0, rune(character), color, scale)
							character_vector_with(&cache, &table, tables, order, b, x, 0, rune(character), color, scale)
						}
					}
					for pixel, index in first {
						if pixel != second[index] {
							differences += 1
						}
					}
				}
			}
		}
	}
	testing.expectf(t, differences == 0, "the fast blend differs from the reference in %v pixels", differences)
	fmt.printfln("graphics: the fast blend and the reference: %v pixels differ; %v tables made", differences, tables.made)
}

// A text with alpha: the fast blend, its tables shared with the opaque
// colors of the same channels, gives the bytes of the reference blend with
// the same alpha, over each background, at each scale, for alphas at the
// edges. Alpha 0 draws nothing.
@(test)
fast_blend_with_alpha_is_the_reference :: proc(t: ^testing.T) {
	bytes := #load("../../../../resources/fonts/jetbrains_mono.ttf")
	font, _ := vector_font.font_open(bytes)
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	out := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:vector_font.GLYPH_CACHE_LIMIT]
	size, _ := vector_font.glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, file)
	cache, _ := glyph_cache.validate(file[:size])
	table: [4096]u8
	square_root_table_fill(&table)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 24 * 96
	first := make([]Color, WIDTH * 48)
	second := make([]Color, WIDTH * 48)
	untouched := make([]Color, WIDTH * 48)
	defer delete(first)
	defer delete(second)
	defer delete(untouched)
	a := Canvas{pixels = raw_data(first), width = WIDTH, height = 48, stride = WIDTH}
	b := Canvas{pixels = raw_data(second), width = WIDTH, height = 48, stride = WIDTH}
	alphas := [?]u32{1, 2, 128, 254}
	differences := 0
	for background in Speed_Background {
		for order in Subpixel_Order {
			for alpha in alphas {
				for scale in 1 ..= 3 {
					background_fill(a, background)
					background_fill(b, background)
					for character in 32 ..< 127 {
						x := (character - 32) * 8 * scale % (WIDTH - 24)
						character_vector_reference(&cache, &table, order, a, x, 0, rune(character), DARK_TEXT, scale, alpha)
						character_vector_with(&cache, &table, tables, order, b, x, 0, rune(character), DARK_TEXT, scale, alpha)
						// The opaque color of the same channels between, so
						// both share the tables.
						character_vector_with(&cache, &table, tables, order, b, x + 1, 24, rune(character), DARK_TEXT, scale)
						character_vector_reference(&cache, &table, order, a, x + 1, 24, rune(character), DARK_TEXT, scale)
					}
					for pixel, index in first {
						differences += int(pixel != second[index])
					}
				}
			}
		}
	}
	testing.expectf(t, differences == 0, "the fast blend with alpha differs from the reference in %v pixels", differences)
	background_fill(a, .Flat)
	copy(untouched, first)
	for character in 32 ..< 127 {
		character_vector_with(&cache, &table, tables, .Red_Green_Blue, a, (character - 32) * 8, 0, rune(character), DARK_TEXT, 1, 0)
	}
	testing.expect(t, slice_equal_colors(first, untouched), "a text of alpha 0 draws")
}

// The paths of a text that paint pixels, Spleen at scale 1, its enlarged
// form at scale 2 and 3, and the replacement box at each scale, with
// alpha: each pixel of ink is the blend of the color with that alpha over
// the pixel, once, and each other pixel stays; with no alpha they paint the
// pixels of before, the replacement box too, whose sides no longer overlap
// its bars. The test passes its own table, and changes no text state.
@(test)
painted_text_with_alpha_blends_each_pixel_once :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	WIDTH :: 80
	HEIGHT :: 60
	Path :: enum {
		Spleen,
		Spleen_Enlarged,
		Replacement,
	}
	Case :: struct {
		path:  Path,
		scale: int,
	}
	cases := [?]Case{{.Spleen, 1}, {.Spleen_Enlarged, 2}, {.Spleen_Enlarged, 3}, {.Replacement, 1}, {.Replacement, 3}}
	draw :: proc(path: Path, canvas: Canvas, scale: int, color: Color, alpha: u32, table: ^[4096]u8) {
		characters := [3]rune{'A', 'g', '#'}
		for character, index in characters {
			x := 3 + index * CELL_WIDTH * scale
			switch path {
			case .Spleen:
				character_spleen(canvas, x, 2, character, color, alpha, table)
			case .Spleen_Enlarged:
				character_spleen_enlarged(canvas, x, 2, character, color, scale, alpha, table)
			case .Replacement:
				character_replacement(canvas, x, 2, color, scale, alpha, table)
			}
		}
	}
	alphas := [3]u32{OPAQUE, 129, 1}
	for item in cases {
		for alpha in alphas {
			opaque_pixels, drawn, expected: [WIDTH * HEIGHT]Color
			for &pixel, index in opaque_pixels {
				pixel = u32(index) * 0x00010307 & 0x007F7F7F
			}
			drawn, expected = opaque_pixels, opaque_pixels
			background := opaque_pixels
			canvas_of :: proc(pixels: ^[WIDTH * HEIGHT]Color) -> Canvas {
				return {pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
			}
			// The ink: white over this background changes each pixel of ink,
			// for no channel of the background passes 0x7F.
			draw(item.path, canvas_of(&opaque_pixels), item.scale, 0x00FFFFFF, OPAQUE, &table)
			draw(item.path, canvas_of(&drawn), item.scale, 0x00C08040, alpha, &table)
			for index in 0 ..< WIDTH * HEIGHT {
				if opaque_pixels[index] == background[index] {
					continue
				}
				// A pixel of ink: the opaque white text wrote it.
				x, y := index % WIDTH, index / WIDTH
				blend_fill(canvas_of(&expected), x, y, 1, 1, alpha << 24 | 0x00C08040, &table)
			}
			testing.expectf(t, drawn == expected, "%v at scale %d with alpha %d: other pixels than one blend of each pixel of ink", item.path, item.scale, alpha)
		}
	}
	// The replacement box with no alpha: the pixels of the four bars of
	// before, which overlapped in the corners.
	before, now: [WIDTH * HEIGHT]Color
	canvas_before := Canvas{pixels = raw_data(before[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	for scale in 1 ..= 3 {
		left, top := 5 + 1 * scale, 4 + 3 * scale
		width, height := 6 * scale, 9 * scale
		fill(canvas_before, left, top, width, scale, 0x00ABCDEF)
		fill(canvas_before, left, top + height - scale, width, scale, 0x00ABCDEF)
		fill(canvas_before, left, top, scale, height, 0x00ABCDEF)
		fill(canvas_before, left + width - scale, top, scale, height, 0x00ABCDEF)
		character_replacement({pixels = raw_data(now[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}, 5, 4, 0x00ABCDEF, scale)
		testing.expectf(t, before == now, "the replacement box at scale %d draws other pixels", scale)
	}
}

// slice_equal_colors says if two runs of pixels are equal, pixel by pixel.
@(private = "file")
slice_equal_colors :: proc(first, second: []Color) -> bool {
	if len(first) != len(second) {
		return false
	}
	for pixel, index in first {
		if pixel != second[index] {
			return false
		}
	}
	return true
}
