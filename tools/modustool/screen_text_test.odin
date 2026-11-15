package modustool

import "core:testing"

import "modus:support/graphics"

// A text drawn in Spleen 8x16 into a picture of the tool is read back, and a
// cell with one pixel more is no glyph: the read never guesses.
@(test)
cells_of_spleen_are_read_back :: proc(t: ^testing.T) {
	WIDTH :: 200
	HEIGHT :: 40
	pixels := make([]u8, WIDTH * HEIGHT * 3, context.temp_allocator)
	background := [3]u8{10, 20, 30}
	ink := [3]u8{230, 230, 220}
	for place in 0 ..< WIDTH * HEIGHT {
		pixels[place * 3], pixels[place * 3 + 1], pixels[place * 3 + 2] = background[0], background[1], background[2]
	}
	text := "MZXW-6YTB 27"
	origin_x, origin_y := 20, 10
	for character, cell in transmute([]u8)text {
		glyph := graphics.font[int(character) - graphics.FONT_FIRST]
		for row in 0 ..< graphics.CELL_HEIGHT {
			for column in 0 ..< graphics.CELL_WIDTH {
				if glyph[row] & (u8(0x80) >> uint(column)) != 0 {
					place := ((origin_y + row) * WIDTH + origin_x + cell * graphics.CELL_WIDTH + column) * 3
					pixels[place], pixels[place + 1], pixels[place + 2] = ink[0], ink[1], ink[2]
				}
			}
		}
	}
	read, ok := cells_text(pixels, WIDTH, HEIGHT, origin_x, origin_y, len(text))
	testing.expect(t, ok)
	testing.expect_value(t, read, text)
	// One cell of the text, read from one pixel to the right: no glyph.
	_, ok = cells_text(pixels, WIDTH, HEIGHT, origin_x + 1, origin_y, 1)
	testing.expect(t, !ok)
	// A place past the picture.
	_, ok = cells_text(pixels, WIDTH, HEIGHT, WIDTH - 4, origin_y, 1)
	testing.expect(t, !ok)
	_, ok = cells_text(pixels, WIDTH, HEIGHT, 0, origin_y, 1)
	testing.expect(t, !ok)
	// The mark of a step takes the text that was read.
	testing.expect_value(t, screen_text_expand("type {screen text} now", "ABCD"), "type ABCD now")
}
