package machine

import "modus:contract/reference_screen"
import "modus:contract/scale_factor"
import "modus:graphics"
import "modus:text_rendering"

// The places of the scenarios at the scale of the desktop
// (src/md/features/desktop_to_browser.md, "The reference screen"). A step
// moves the pointer and presses in logical pixels: the compositor moves the
// pointer one logical pixel for each unit of a move of the mouse, and gives
// its place and the places of the windows and of the elements in logical
// pixels. A picture of the screen is in pixels of the screen: a step that
// reads a pixel of it turns its logical place into a pixel of the screen
// with screen_place_of_logical, by the rule of the drawing module.

// The scale of the desktop of a test machine: the default of the setting,
// which no scenario changes.
MACHINE_SCALE :: scale_factor.DEFAULT

// The reference screen in logical pixels at MACHINE_SCALE: the most
// logical pixels whose box on the screen is inside it
// (scale_factor.logical_screen). 1536 x 864 at 1.25.
LOGICAL_SCREEN_WIDTH :: (reference_screen.WIDTH * scale_factor.EIGHTHS_OF_ONE + scale_factor.EIGHTHS_OF_ONE / 2 - 1) / int(MACHINE_SCALE)
LOGICAL_SCREEN_HEIGHT :: (reference_screen.HEIGHT * scale_factor.EIGHTHS_OF_ONE + scale_factor.EIGHTHS_OF_ONE / 2 - 1) / int(MACHINE_SCALE)

// A logical place past this distance from the corner is no place of a
// scenario: the helper refuses it, and never wraps.
LOGICAL_PLACE_LIMIT :: 1 << 22

// screen_place_of_logical gives the pixel of the screen of a logical place
// at a scale: the edge of the logical pixel, rounded to the nearest pixel
// of the screen, a half up, as the drawing module rounds it. ok is false
// for a place past LOGICAL_PLACE_LIMIT on either side.
screen_place_of_logical :: proc(place: int, scale: scale_factor.Scale) -> (pixel: int, ok: bool) {
	if place < -LOGICAL_PLACE_LIMIT || place > LOGICAL_PLACE_LIMIT {
		return 0, false
	}
	return int(scale_factor.screen_pixel_of_logical_pixel(i32(place), scale)), true
}

// logical_place_of_screen gives the logical pixel that holds a pixel of the
// screen at a scale: the size of the screen that the compositor writes on
// its line, in the logical pixels of the places of a scenario.
logical_place_of_screen :: proc(pixel: int, scale: scale_factor.Scale) -> (place: int, ok: bool) {
	if pixel < -LOGICAL_PLACE_LIMIT || pixel > LOGICAL_PLACE_LIMIT {
		return 0, false
	}
	return int(scale_factor.logical_pixel_of_screen_pixel(i32(pixel), scale)), true
}

// Spleen_Cells: where the glyphs of Spleen 8x16 of a text of the cells at
// the body are on the screen at a scale that the setting takes. The cell of
// the body is half its size on the screen wide, a half up, and two widths
// high; Spleen draws at its scale 1 in the middle of the cell, as long as
// the cell is under 16 by 32 (each scale under 2).
Spleen_Cells :: struct {
	step:              int, // The pixels of the screen from one cell to the next.
	glyph_x, glyph_y:  int, // The glyph of 8 by 16 from the corner of its cell.
}

// spleen_cells_of gives the cells of a text of the body at a scale: 10 by
// 20 pixels at 1.25, with the glyph 1 pixel right and 2 down; 11 by 22 at
// 1.375.
spleen_cells_of :: proc(scale: scale_factor.Scale) -> Spleen_Cells {
	// The body is a line of the height of a cell of Spleen, 16 pixels.
	size := scale_factor.screen_text_size(u16(graphics.CELL_HEIGHT * text_rendering.SUBPIXEL), scale)
	step := text_rendering.cell_columns(size)
	return {step = step, glyph_x = (step - graphics.CELL_WIDTH) / 2, glyph_y = (2 * step - graphics.CELL_HEIGHT) / 2}
}
