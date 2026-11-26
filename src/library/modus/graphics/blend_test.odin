#+build !freestanding
#+build !modus
package graphics

import "core:testing"

// The blend gives round(source + destination * (255 - alpha) / 255) for
// each channel, for each alpha, each premultiplied source value and each
// destination value of a channel; the two other channels do not change it.
@(test)
blend_is_exact_for_each_channel_value :: proc(t: ^testing.T) {
	wrong := 0
	for alpha in u32(0) ..= 255 {
		for source in u32(0) ..= alpha {
			for destination in u32(0) ..= 255 {
				// The value in red, a constant in green, another in blue.
				pixel := [1]Color{destination << 16 | 0x40 << 8 | 0xC0}
				picture := [1]u32{alpha << 24 | source << 16 | (0x10 * alpha / 255) << 8 | alpha}
				blend_premultiplied_alpha({pixels = raw_data(pixel[:]), width = 1, height = 1, stride = 1}, 0, 0, {pixels = raw_data(picture[:]), width = 1, height = 1, stride = 1})
				expected := source + (destination * (255 - alpha) + 127) / 255
				if pixel[0] >> 16 != expected || pixel[0] >> 24 != 0 {
					wrong += 1
				}
				expected_blue := alpha + (0xC0 * (255 - alpha) + 127) / 255
				if pixel[0] & 0xFF != expected_blue {
					wrong += 1
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

// A canvas of SIDE by SIDE pixels with a frame of one pixel around it, each
// pixel a value of its own: a draw that writes outside the canvas changes
// the frame.
@(private = "file")
FRAMED_SIDE :: 21

@(private = "file")
framed_pixels :: proc(memory: ^[(FRAMED_SIDE + 2) * (FRAMED_SIDE + 2)]Color) -> Canvas {
	for &pixel, index in memory {
		pixel = u32(index) * 0x9E3779B1 & 0x00FFFFFF
	}
	return {pixels = raw_data(memory[FRAMED_SIDE + 2 + 1:]), width = FRAMED_SIDE, height = FRAMED_SIDE, stride = FRAMED_SIDE + 2}
}

// An opaque color draws the pixels of fill, and the color 0 and each color
// of alpha 0 draw nothing, at each place and size around the canvas, also
// out of it and with no size: blend_fill writes only inside the canvas.
@(test)
blend_fill_of_an_opaque_color_is_fill :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	places := [?]int{-30, -1, 0, 1, 7, FRAMED_SIDE - 1, FRAMED_SIDE, 40}
	sizes := [?]int{0, 1, 2, 63, 64, 65, 200}
	transparent := [3]u32{0, 0x00FFFFFF, 0x00123456}
	for x in places {
		for width in sizes {
			filled, blended: [(FRAMED_SIDE + 2) * (FRAMED_SIDE + 2)]Color
			fill(framed_pixels(&filled), x, x / 2, width, width / 3 + 1, 0x00ABCDEF)
			blend_fill(framed_pixels(&blended), x, x / 2, width, width / 3 + 1, 0xFFABCDEF, &table)
			testing.expectf(t, filled == blended, "an opaque color at %d of %d pixels draws other pixels than fill", x, width)
			for color in transparent {
				untouched, drawn: [(FRAMED_SIDE + 2) * (FRAMED_SIDE + 2)]Color
				framed_pixels(&untouched)
				blend_fill(framed_pixels(&drawn), x, x / 2, width, width / 3 + 1, color, &table)
				testing.expectf(t, untouched == drawn, "the color %08x at %d of %d pixels draws", color, x, width)
			}
		}
	}
}

// A width or a height of 0 or below draws nothing, for an opaque and a
// translucent color and for a source with alpha, at places inside and
// outside the canvas: no pixel of the canvas or of its frame changes.
@(test)
blend_of_a_negative_size_draws_nothing :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	source: [4]u32 = {0x80FFFFFF, 0xFF000000, 0x01020304, 0xFE808080}
	places := [3]int{-3, 0, 5}
	sizes := [?]int{0, -1, -2, -64, -65, -1000}
	colors := [2]u32{0xFFABCDEF, 0x80ABCDEF}
	for x in places {
		for size in sizes {
			for color in colors {
				untouched, wide, high: [(FRAMED_SIDE + 2) * (FRAMED_SIDE + 2)]Color
				framed_pixels(&untouched)
				blend_fill(framed_pixels(&wide), x, x, size, 4, color, &table)
				blend_fill(framed_pixels(&high), x, x, 4, size, color, &table)
				testing.expectf(t, wide == untouched, "the width %d at %d in %08x draws", size, x, color)
				testing.expectf(t, high == untouched, "the height %d at %d in %08x draws", size, x, color)
			}
			kept, copied_wide, copied_high: [(FRAMED_SIDE + 2) * (FRAMED_SIDE + 2)]Color
			framed_pixels(&kept)
			blend_copy(framed_pixels(&copied_wide), x, x, {pixels = raw_data(source[:]), width = size, height = 2, stride = 2}, &table)
			blend_copy(framed_pixels(&copied_high), x, x, {pixels = raw_data(source[:]), width = 2, height = size, stride = 2}, &table)
			testing.expectf(t, copied_wide == kept, "a source of width %d at %d draws", size, x)
			testing.expectf(t, copied_high == kept, "a source of height %d at %d draws", size, x)
		}
	}
}

// Each alpha from 1 to 254 over each value of a channel: blend_fill gives
// the rule, square_root[(d * d * (255 - a) + c * c * a) >> 12] for each
// channel with the high byte 0, inside the rectangle only, also in a span
// longer than the row of one color that it blends a part at a time.
@(test)
blend_fill_follows_the_rule :: proc(t: ^testing.T) {
	channel :: proc(table: ^[4096]u8, under, color, alpha: u32) -> u32 {
		return u32(table[(under * under * (255 - alpha) + color * color * alpha) >> 12])
	}
	table: [4096]u8
	square_root_table_fill(&table)
	WIDTH :: 256 + 70
	wrong := 0
	outside := 0
	colors := [3]u32{0x00000000, 0x00FF8001, 0x00FFFFFF}
	for alpha in u32(1) ..= 254 {
		for channels in colors {
			pixels: [3 * WIDTH]Color
			for column in 0 ..< WIDTH {
				value := u32(column % 256)
				for row in 0 ..< 3 {
					pixels[row * WIDTH + column] = 0xAB000000 | value << 16 | (255 - value) << 8 | value / 3
				}
			}
			before := pixels
			blend_fill({pixels = raw_data(pixels[:]), width = WIDTH, height = 3, stride = WIDTH}, 1, 1, WIDTH - 2, 1, alpha << 24 | channels, &table)
			for row in 0 ..< 3 {
				for column in 0 ..< WIDTH {
					index := row * WIDTH + column
					if row != 1 || column == 0 || column == WIDTH - 1 {
						outside += int(pixels[index] != before[index])
						continue
					}
					under := before[index]
					expected := channel(&table, under >> 16 & 0xFF, channels >> 16 & 0xFF, alpha) << 16 | channel(&table, under >> 8 & 0xFF, channels >> 8 & 0xFF, alpha) << 8 | channel(&table, under & 0xFF, channels & 0xFF, alpha)
					wrong += int(pixels[index] != expected)
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
	testing.expect_value(t, outside, 0)
}

// blend_copy blends each color of its source by the rule of blend_fill: a
// source of one color gives the pixels of blend_fill of that color, at each
// place around the canvas, and a source of stride 0 blends its one line
// into each line.
@(test)
blend_copy_is_blend_fill_for_one_color :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	SOURCE :: 5
	colors := [4]u32{0, 0x01000000, 0x80336699, 0xFF336699}
	places := [?]int{-6, -1, 0, 3, FRAMED_SIDE - 2, FRAMED_SIDE + 1}
	for color in colors {
		source: [SOURCE * SOURCE]u32
		for &value in source {
			value = color
		}
		for x in places {
			filled, copied, one_line: [(FRAMED_SIDE + 2) * (FRAMED_SIDE + 2)]Color
			blend_fill(framed_pixels(&filled), x, x + 1, SOURCE, SOURCE, color, &table)
			blend_copy(framed_pixels(&copied), x, x + 1, {pixels = raw_data(source[:]), width = SOURCE, height = SOURCE, stride = SOURCE}, &table)
			blend_copy(framed_pixels(&one_line), x, x + 1, {pixels = raw_data(source[:]), width = SOURCE, height = SOURCE, stride = 0}, &table)
			testing.expectf(t, filled == copied, "the color %08x at %d: blend_copy draws other pixels than blend_fill", color, x)
			testing.expectf(t, filled == one_line, "the color %08x at %d: a source of one line draws other pixels", color, x)
		}
	}
}

// The mixes with alpha: the alpha steps as a channel, and the red, the
// green and the blue are those of mix and gradient, at each level and each
// column, so two opaque ends give the colors of the opaque mixes.
@(test)
mixes_with_alpha_keep_the_mixes_of_the_channels :: proc(t: ^testing.T) {
	first, second := u32(0x10_20_30_40), u32(0xF0_E0_D0_C0)
	wrong := 0
	for level in u32(0) ..= 255 {
		mixed := mix_with_alpha(first, second, level)
		wrong += int(mixed & 0x00FFFFFF != mix(first, second, level))
		wrong += int(mixed >> 24 != (0x10 * (255 - level) + 0xF0 * level) / 255)
		wrong += int(mix_with_alpha(first | 0xFF000000, second | 0xFF000000, level) >> 24 != 255)
	}
	testing.expect_value(t, wrong, 0)
	TOTAL :: 300
	plain, with_alpha: [TOTAL]u32
	gradient(plain[:], first, second, TOTAL, 0)
	gradient_with_alpha(with_alpha[:], first, second, TOTAL, 0)
	testing.expect_value(t, with_alpha[0] >> 24, u32(0x10))
	testing.expect_value(t, with_alpha[TOTAL - 1] >> 24, u32(0xF0))
	for column in 0 ..< TOTAL {
		testing.expectf(t, with_alpha[column] & 0x00FFFFFF == plain[column], "the column %d: other channels than gradient", column)
		if column > 0 {
			testing.expectf(t, with_alpha[column] >> 24 >= with_alpha[column - 1] >> 24, "the column %d: the alpha goes back", column)
		}
	}
	// A part of the row from a column gives the same colors.
	part: [100]u32
	gradient_with_alpha(part[:], first, second, TOTAL, 150)
	for column in 0 ..< len(part) {
		testing.expectf(t, part[column] == with_alpha[150 + column], "the column %d of a part from 150", column)
	}
}

// A picture at each place around the canvas, also out of it: the blend
// writes only inside the canvas, and only where the picture is.
@(test)
blend_is_cut_to_the_canvas :: proc(t: ^testing.T) {
	SIDE :: 8
	PICTURE :: 3
	picture: [PICTURE * PICTURE]u32
	for &pixel in picture {
		pixel = 0xFF_FF_FF_FF
	}
	for y in -5 ..= SIDE + 2 {
		for x in -5 ..= SIDE + 2 {
			memory: [(SIDE + 2) * (SIDE + 2)]Color // A frame of one pixel around the canvas.
			canvas := Canvas{pixels = raw_data(memory[SIDE + 2 + 1:]), width = SIDE, height = SIDE, stride = SIDE + 2}
			blend_premultiplied_alpha(canvas, x, y, {pixels = raw_data(picture[:]), width = PICTURE, height = PICTURE, stride = PICTURE})
			for row in 0 ..< SIDE + 2 {
				for column in 0 ..< SIDE + 2 {
					inside_canvas := row >= 1 && row <= SIDE && column >= 1 && column <= SIDE
					canvas_x, canvas_y := column - 1, row - 1
					inside_picture := canvas_x >= x && canvas_x < x + PICTURE && canvas_y >= y && canvas_y < y + PICTURE
					expected := Color(inside_canvas && inside_picture ? 0xFFFFFF : 0)
					testing.expectf(t, memory[row * (SIDE + 2) + column] == expected, "picture at %d,%d: pixel %d,%d", x, y, column, row)
				}
			}
		}
	}
}
