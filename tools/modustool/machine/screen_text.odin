package machine

import "core:fmt"
import "core:strings"
import "core:time"

import "modus:contract/font_characters"
import "modus:graphics"
import "modustool:build"
import "modustool:foundation"

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
// The mark that the text of the Screen_Text before the last one replaces:
// a recovery key that a new one replaced, which a later step types to show
// that it opens nothing new.
SCREEN_TEXT_BEFORE_MARK :: "{screen text before}"

// screen_text_keep keeps a text that a step Screen_Text read, and the text
// before it, in the run of the part: a later machine of the part types it.
screen_text_keep :: proc(part: ^Test_Part_Run, read: string) {
	delete(part.screen_text_before)
	part.screen_text_before = part.screen_text_kept
	part.screen_text_kept = strings.clone(read)
}

// screen_text_forget forgets the kept texts of a part: at its end, and at
// the start of a group of its machines that must not type a text of the
// group before.
screen_text_forget :: proc(part: ^Test_Part_Run) {
	delete(part.screen_text_kept)
	delete(part.screen_text_before)
	part.screen_text_kept = ""
	part.screen_text_before = ""
}

// screen_text_expand writes the kept text in place of each mark, and the
// text before it in place of each mark of that one. The two marks do not
// overlap: "{screen text}" ends where the other one goes on.
screen_text_expand :: proc(text: string, kept: string, before: string) -> string {
	result, _ := strings.replace_all(text, SCREEN_TEXT_MARK, kept, context.temp_allocator)
	result, _ = strings.replace_all(result, SCREEN_TEXT_BEFORE_MARK, before, context.temp_allocator)
	return result
}

// cells_text reads cells of Spleen 8x16 from the pixels of a picture, 3
// bytes each, line after line: count glyphs on one line, the first one at
// (x, y), each step pixels after the one before: a cell of the body at the
// scale of the desktop is wider than the glyph, which is in its middle
// (spleen_cells_of). The background is the color of the pixel just left of
// the first glyph. ok is false for a place out of the picture, a step
// under the width of a glyph, or a cell that is no glyph of the font.
cells_text :: proc(pixels: []u8, width, height: int, x, y: int, count: int, step: int = graphics.CELL_WIDTH) -> (text: string, ok: bool) {
	if x < 1 || y < 0 || count <= 0 || step < graphics.CELL_WIDTH || x + (count - 1) * step + graphics.CELL_WIDTH > width || y + graphics.CELL_HEIGHT > height || len(pixels) < width * height * 3 {
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
				if pixel(pixels, width, x + cell * step + column, y + row) != background {
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
				character, _ := font_characters.character_of_index(index)
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

// text_fills_its_box says if a text that cells_text read has no blank cell
// at its start and at its end: the text of an element whose box is as wide
// as its text, and not what the window showed there before the element.
text_fills_its_box :: proc(text: string) -> bool {
	return len(text) > 0 && text[0] != ' ' && text[len(text) - 1] != ' '
}

// screen_text_read reads the text of the element of a window: it waits for
// the element line that places the element, then takes settled pictures of
// the screen until the cells of the element read as a text that fills its
// box. The window must be in front.
screen_text_read :: proc(machine: ^Machine, owner, element: string, index: int) -> (text: string, ok: bool) {
	element_x, element_y, element_width, element_height: int
	found := Element_Line.Absent
	types: build.Element_Fact_Types
	typed := false
	for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
		element_x, element_y, element_width, element_height, found = element_place_read(machine, &types, &typed, owner, element)
		if found == .Placed {
			break
		}
		log_change_wait(machine)
	}
	if found != .Placed || element_height < graphics.CELL_HEIGHT {
		fmt.eprintfln("modustool: test failed: step %d: the element %s of %s is not placed as one line of text within %v", index + 1, element, owner, foundation.HANG_BOUND)
		return "", false
	}
	window_x, window_y, placed := window_place(machine, owner)
	if !placed {
		fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, owner)
		return "", false
	}
	// The places are logical pixels; the picture is pixels of the screen at
	// the scale of the machine. The surface of the window is copied at the
	// pixel of the screen of its corner, and the element is at its place
	// on the surface at the same scale; the glyph is in the middle of its
	// cell.
	cells := spleen_cells_of(MACHINE_SCALE)
	if cells.spleen_scale != 1 {
		// cells_text compares each glyph of Spleen at its scale 1.
		fmt.eprintfln("modustool: test failed: step %d: the scale of the machine draws Spleen at %d, and the read of a text takes only its scale 1", index + 1, cells.spleen_scale)
		return "", false
	}
	surface_x, _ := screen_place_of_logical(window_x + WINDOW_BORDER, MACHINE_SCALE)
	surface_y, _ := screen_place_of_logical(window_y + WINDOW_TITLE_HEIGHT, MACHINE_SCALE)
	in_surface_x, _ := screen_place_of_logical(element_x, MACHINE_SCALE)
	in_surface_y, _ := screen_place_of_logical(element_y, MACHINE_SCALE)
	x := surface_x + in_surface_x + cells.glyph_x
	y := surface_y + in_surface_y + cells.glyph_y
	// The element line comes from the layout of a frame, before its
	// picture reaches the screen. With no remote service, a settled screen
	// means only that two pictures in a row were the same, so a process that
	// is late to present gives a settled picture of its window before the
	// change. The read itself is the condition: the cells of the element
	// show a text of the font that fills its box, as a text element is as
	// wide as its text. The guide: docs/TOOLS.md, "How a step reads a text off the screen".
	read_start := time.now()
	for {
		dump := screen_dump_settled(machine, element) or_return
		read: bool
		text, read = cells_text(dump.pixels, dump.width, dump.height, x, y, element_width / graphics.CELL_WIDTH, cells.step)
		delete(dump.file)
		if read && text_fills_its_box(text) {
			break
		}
		if time.since(read_start) >= foundation.HANG_BOUND {
			fmt.eprintfln("modustool: test failed: step %d: the element %s of %s at %d,%d of the screen is not a text of Spleen 8x16 that fills its box within %v (set the font to spleen first)", index + 1, element, owner, x, y, foundation.HANG_BOUND)
			return "", false
		}
	}
	foundation.test_passed_print("the tool read the element %s of %s off the screen: %d characters", element, owner, len(text))
	return text, true
}
