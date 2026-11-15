package modustool

import "core:fmt"
import "core:strings"
import "core:time"

import "modus:contract/glyph_cache"
import "modus:support/graphics"

// The read of a text off the screen (docs/TOOLS.md, "How a step reads a text off the screen"):
// a step Screen_Text reads the text of a named element of a window from a
// picture of the screen, and a later step types it with the mark
// SCREEN_TEXT_MARK. It is for a value that the machine shows and writes
// nowhere else: the recovery key of a machine key sealed by the TPM, which
// the log must never hold.
//
// The text must be drawn in Spleen 8x16, the bitmap font of the cells: the
// scenario sets the setting "font" to spleen before. Each cell of 8 by 16
// pixels is compared, pixel by pixel, with each glyph of the font: a pixel
// that is not the color of the background is ink. A cell that matches no
// glyph fails the read: the tool never guesses a character.

// The mark in the text of a step that the text of the last Screen_Text
// replaces.
SCREEN_TEXT_MARK :: "{screen text}"

// The text that the last step Screen_Text read, in one test part: a later
// machine of the part types it.
screen_text_kept: string

// screen_text_expand writes the kept text in place of each mark.
screen_text_expand :: proc(text: string, kept: string) -> string {
	result, _ := strings.replace_all(text, SCREEN_TEXT_MARK, kept, context.temp_allocator)
	return result
}

// cells_text reads cells of Spleen 8x16 from the pixels of a picture, 3
// bytes each, line after line: count cells from (x, y), on one line. The
// background is the color of the pixel just left of the first cell. ok is
// false for a place out of the picture, or a cell that is no glyph of the
// font.
cells_text :: proc(pixels: []u8, width, height: int, x, y: int, count: int) -> (text: string, ok: bool) {
	if x < 1 || y < 0 || count <= 0 || x + count * graphics.CELL_WIDTH > width || y + graphics.CELL_HEIGHT > height || len(pixels) < width * height * 3 {
		return "", false
	}
	pixel :: proc(picture: []u8, picture_width, column_x, row_y: int) -> [3]u8 {
		place := (row_y * picture_width + column_x) * 3
		return {picture[place], picture[place + 1], picture[place + 2]}
	}
	background := pixel(pixels, width, x - 1, y)
	builder := strings.builder_make(context.temp_allocator)
	for cell in 0 ..< count {
		rows: [graphics.CELL_HEIGHT]u8
		for row in 0 ..< graphics.CELL_HEIGHT {
			for column in 0 ..< graphics.CELL_WIDTH {
				if pixel(pixels, width, x + cell * graphics.CELL_WIDTH + column, y + row) != background {
					rows[row] |= u8(0x80) >> uint(column)
				}
			}
		}
		// The glyphs of ASCII come first, so a glyph that a character of
		// the Latin-1 Supplement shares (the space with no break draws as
		// the space) reads as its character of ASCII.
		found := false
		for glyph, index in graphics.font {
			if glyph == rows {
				character, _ := glyph_cache.character_of_index(index)
				strings.write_rune(&builder, character)
				found = true
				break
			}
		}
		if !found {
			return "", false
		}
	}
	return strings.to_string(builder), true
}

// screen_text_read reads the text of the element of a window: it waits for
// the element line that places the element, takes a settled picture of the
// screen, and reads the cells of the element. The window must be in front.
screen_text_read :: proc(machine: ^Machine, owner, element: string, index: int) -> (text: string, ok: bool) {
	element_x, element_y, element_width, element_height: int
	found := Element_Line.Absent
	for start := time.now(); time.since(start) < HANG_BOUND; {
		element_x, element_y, element_width, element_height, found = element_line_read(log_read(machine), owner, element)
		if found == .Placed {
			break
		}
		log_change_wait(machine)
	}
	if found != .Placed || element_height < graphics.CELL_HEIGHT {
		fmt.eprintfln("modustool: test failed: step %d: the element %s of %s is not placed as one line of text within %v", index + 1, element, owner, HANG_BOUND)
		return "", false
	}
	window_x, window_y, placed := window_place(machine, owner)
	if !placed {
		fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, owner)
		return "", false
	}
	dump := screen_dump_settled(machine, element) or_return
	defer delete(dump.file)
	x := window_x + WINDOW_BORDER + element_x
	y := window_y + WINDOW_TITLE_HEIGHT + element_y
	read: bool
	text, read = cells_text(dump.pixels, dump.width, dump.height, x, y, element_width / graphics.CELL_WIDTH)
	if !read {
		fmt.eprintfln("modustool: test failed: step %d: the element %s of %s at %d,%d of the screen is not a text of Spleen 8x16 (set the font to spleen first)", index + 1, element, owner, x, y)
		return "", false
	}
	test_passed_print("the tool read the element %s of %s off the screen: %d characters", element, owner, len(text))
	return text, true
}
