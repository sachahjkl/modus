#+build !freestanding
package grid_renderer

import "core:testing"
import "modus:graphics"
import terminal_records "modus:terminal"

@(test)
grid_renderer_dirty_rows_and_tiny_canvas_bounds :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 40, 12, .Dark)

	// Zero / tiny canvas is refused cleanly with 0 rows blitted.
	empty := graphics.Canvas{pixels = nil, width = 0, height = 0, stride = 0}
	testing.expect_value(t, grid_present_dirty(screen, empty, nil, 0, .Dark), 0)

	pixels := make([]graphics.Color, 320 * 192)
	defer delete(pixels)
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = 320, height = 192, stride = 320}

	// First present blits all 12 rows; second present with no changes blits 0 rows.
	testing.expect_value(t, grid_present_dirty(screen, canvas, nil, 0, .Dark), 12)
	testing.expect_value(t, grid_present_dirty(screen, canvas, nil, 0, .Dark), 0)

	// Edit line marks only its row dirty and paints syntax-highlighted text + blue cursor.
	line := transmute([]u8)string("help()")
	runs := terminal_records.Code_Runs{
		count = 1,
		runs = {0 = {start = 0, length = 4, kind = u8(terminal_records.Code_Kind.Function)}},
	}
	grid_write_edit_line(screen, 3, line, &runs, 4, .Dark)
	testing.expect_value(t, grid_present_dirty(screen, canvas, nil, 3, .Dark), 1)
	palette := graphics.colors_for_contrast_mode(.Standard, true)
	// Cursor at row 3, col 4 has chosen blue background.
	cursor_pixel := pixels[(3 * graphics.CELL_HEIGHT + 1) * 320 + 4 * graphics.CELL_WIDTH + 1]
	testing.expect_value(t, cursor_pixel, palette.chosen)
}

@(test)
grid_renderer_completion_popup_overlays_and_restores_background :: proc(t: ^testing.T) {
	screen := new(Grid_Screen)
	defer free(screen)
	grid_init(screen, 40, 12, .Dark)
	pixels := make([]graphics.Color, 320 * 192)
	defer delete(pixels)
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = 320, height = 192, stride = 320}
	_ = grid_present_dirty(screen, canvas, nil, 0, .Dark)

	popup: terminal_records.List_Shown
	popup.row_count = 2
	popup.chosen = 0
	popup.anchor = 1
	copy(popup.rows[0].text[:], "startmodule")
	popup.rows[0].length = 11
	popup.rows[0].name_length = 5
	copy(popup.rows[1].text[:], "stopprocess")
	popup.rows[1].length = 11
	popup.rows[1].name_length = 4

	_ = grid_present_dirty(screen, canvas, &popup, 2, .Dark)
	testing.expect(t, screen.popup_visible)
	palette := graphics.colors_for_contrast_mode(.Standard, true)
	// Row 0 of popup (selected) sits at y = 3 * 16 + 2 = 50, x = 8 + 2 = 10 -> chosen blue.
	testing.expect_value(t, pixels[51 * 320 + 10], palette.chosen)

	// Closing popup marks covered rows dirty and restores surface background.
	empty_popup: terminal_records.List_Shown
	restored := grid_present_dirty(screen, canvas, &empty_popup, 2, .Dark)
	testing.expect(t, !screen.popup_visible && restored >= 2)
	testing.expect_value(t, pixels[51 * 320 + 10], palette.background)
}
