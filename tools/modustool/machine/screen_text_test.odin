package machine

import "core:testing"

import "modus:contract/font_characters"
import "modus:graphics"

// A text drawn in Spleen 8x16 into a picture of the tool is read back, and a
// cell with one pixel more is no glyph: the read never guesses.
@(test)
cells_of_spleen_are_read_back :: proc(t: ^testing.T) {
	WIDTH :: 200
	HEIGHT :: 64
	pixels := make([]u8, WIDTH * HEIGHT * 3, context.temp_allocator)
	background := [3]u8{10, 20, 30}
	ink := [3]u8{230, 230, 220}
	for place in 0 ..< WIDTH * HEIGHT {
		pixels[place * 3], pixels[place * 3 + 1], pixels[place * 3 + 2] = background[0], background[1], background[2]
	}
	text := "MZXW-6YTB 27"
	origin_x, origin_y := 20, 10
	for character, cell in transmute([]u8)text {
		index, _ := font_characters.character_index(rune(character))
		glyph := graphics.font[index]
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
	// A step under the width of a glyph is refused; the text drawn at a
	// step of 8 read at a step of 10 is no text.
	_, ok = cells_text(pixels, WIDTH, HEIGHT, origin_x, origin_y, len(text), graphics.CELL_WIDTH - 1)
	testing.expect(t, !ok)
	_, ok = cells_text(pixels, WIDTH, HEIGHT, origin_x, origin_y, len(text), graphics.CELL_WIDTH + 2)
	testing.expect(t, !ok)
	// The cells of the body at the scale of the machine: each glyph in
	// the middle of a wider cell, read at the step of the cell.
	cells := spleen_cells_of(MACHINE_SCALE)
	wide_text := "Q7"
	wide_y := origin_y + 20
	for character, cell in transmute([]u8)wide_text {
		index, _ := font_characters.character_index(rune(character))
		glyph := graphics.font[index]
		for row in 0 ..< graphics.CELL_HEIGHT {
			for column in 0 ..< graphics.CELL_WIDTH {
				if glyph[row] & (u8(0x80) >> uint(column)) != 0 {
					place := ((wide_y + row) * WIDTH + origin_x + cell * cells.step + column) * 3
					pixels[place], pixels[place + 1], pixels[place + 2] = ink[0], ink[1], ink[2]
				}
			}
		}
	}
	wide_read, wide_ok := cells_text(pixels, WIDTH, HEIGHT, origin_x, wide_y, len(wide_text), cells.step)
	testing.expect(t, wide_ok)
	testing.expect_value(t, wide_read, wide_text)
	// The mark of a step takes the text that was read.
	testing.expect_value(t, screen_text_expand("type {screen text} now", "ABCD", "WXYZ"), "type ABCD now")
	// The mark of the text before takes the text of the read before.
	testing.expect_value(t, screen_text_expand("type {screen text before} now", "ABCD", "WXYZ"), "type WXYZ now")
	testing.expect_value(t, screen_text_expand("{screen text before} {screen text}", "ABCD", "WXYZ"), "WXYZ ABCD")
}

// A second read keeps the first text as the text before, and the start of
// a part forgets both.
@(test)
the_text_before_is_the_text_of_the_read_before :: proc(t: ^testing.T) {
	part, other: Test_Part_Run
	screen_text_keep(&part, "FIRST")
	testing.expect_value(t, part.screen_text_kept, "FIRST")
	testing.expect_value(t, part.screen_text_before, "")
	screen_text_keep(&part, "SECOND")
	testing.expect_value(t, part.screen_text_kept, "SECOND")
	testing.expect_value(t, part.screen_text_before, "FIRST")
	// Another part that runs at the same time keeps nothing of this one.
	testing.expect_value(t, other.screen_text_kept, "")
	testing.expect_value(t, other.screen_text_before, "")
	screen_text_forget(&part)
	testing.expect_value(t, part.screen_text_kept, "")
	testing.expect_value(t, part.screen_text_before, "")
}

// A read with a blank cell at its start or its end is what the window
// showed before the element: the read goes on.
@(test)
a_text_with_a_blank_cell_at_an_end_does_not_fill_its_box :: proc(t: ^testing.T) {
	testing.expect(t, text_fills_its_box("4AUQ-MSA4"))
	testing.expect(t, text_fills_its_box("A B"))
	testing.expect(t, !text_fills_its_box(""))
	testing.expect(t, !text_fills_its_box("   "))
	testing.expect(t, !text_fills_its_box(" 4AUQ"))
	testing.expect(t, !text_fills_its_box("4AUQ "))
}
