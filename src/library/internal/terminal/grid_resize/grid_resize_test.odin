#+build !freestanding
package grid_resize

import "core:testing"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:terminal"

make_cell :: proc(ch: rune) -> interface.Text_Grid_Cell {
	return {character = ch, color = 0xFFFFFF}
}

@(test)
dimensions_from_pixels_refuses_edges_and_accepts_bounds :: proc(t: ^testing.T) {
	// Zero and negative cell sizes.
	for bad_cell in ([?]int{min(int), -16, -1, 0}) {
		c, r, err := grid_dimensions_from_pixels(640, 480, bad_cell, 16)
		testing.expectf(t, err == .Invalid_Cell_Size && c == 0 && r == 0, "cell_width=%d must fail", bad_cell)
		c, r, err = grid_dimensions_from_pixels(640, 480, 8, bad_cell)
		testing.expectf(t, err == .Invalid_Cell_Size && c == 0 && r == 0, "cell_height=%d must fail", bad_cell)
	}

	// Zero, negative, and oversized pixel sizes (0x0, negative, one past SURFACE_LIMIT, max(int)).
	for bad_px in ([?]int{min(int), -1, 0, display.SURFACE_LIMIT + 1, max(int)}) {
		c, r, err := grid_dimensions_from_pixels(bad_px, 16, 8, 16)
		testing.expectf(t, err == .Invalid_Pixels && c == 0 && r == 0, "pixel_width=%d must fail", bad_px)
		c, r, err = grid_dimensions_from_pixels(8, bad_px, 8, 16)
		testing.expectf(t, err == .Invalid_Pixels && c == 0 && r == 0, "pixel_height=%d must fail", bad_px)
	}
	{
		c, r, err := grid_dimensions_from_pixels(0, 0, 8, 16)
		testing.expect_value(t, err, Resize_Error.Invalid_Pixels)
		testing.expect_value(t, c, 0)
		testing.expect_value(t, r, 0)
	}

	// Below minimum (pixels smaller than 1 cell, or fewer than min_columns/min_rows).
	{
		c, r, err := grid_dimensions_from_pixels(7, 16, 8, 16)
		testing.expect_value(t, err, Resize_Error.Below_Minimum)
		testing.expect(t, c == 0 && r == 0)
		c, r, err = grid_dimensions_from_pixels(8, 15, 8, 16)
		testing.expect_value(t, err, Resize_Error.Below_Minimum)
		testing.expect(t, c == 0 && r == 0)
	}

	// Exact 1x1 minimum.
	{
		c, r, err := grid_dimensions_from_pixels(8, 16, 8, 16)
		testing.expect_value(t, err, Resize_Error.None)
		testing.expect_value(t, c, 1)
		testing.expect_value(t, r, 1)
	}

	// Exact maximum (COLUMNS_LIMIT x ROWS_LIMIT).
	{
		max_w := terminal.COLUMNS_LIMIT * graphics.CELL_WIDTH
		max_h := terminal.ROWS_LIMIT * graphics.CELL_HEIGHT
		c, r, err := grid_dimensions_from_pixels(max_w, max_h, graphics.CELL_WIDTH, graphics.CELL_HEIGHT)
		testing.expect_value(t, err, Resize_Error.None)
		testing.expect_value(t, c, terminal.COLUMNS_LIMIT)
		testing.expect_value(t, r, terminal.ROWS_LIMIT)

		// One column past max, one row past max.
		c, r, err = grid_dimensions_from_pixels(max_w + graphics.CELL_WIDTH, max_h, graphics.CELL_WIDTH, graphics.CELL_HEIGHT)
		testing.expect_value(t, err, Resize_Error.Above_Maximum)
		testing.expect(t, c == 0 && r == 0)

		c, r, err = grid_dimensions_from_pixels(max_w, max_h + graphics.CELL_HEIGHT, graphics.CELL_WIDTH, graphics.CELL_HEIGHT)
		testing.expect_value(t, err, Resize_Error.Above_Maximum)
		testing.expect(t, c == 0 && r == 0)
	}

	// Invalid bounds rejected.
	bad_bounds := [?]Grid_Bounds{
		{0, 10, 1, 10},
		{1, 10, 0, 10},
		{10, 5, 1, 10},
		{1, 10, 10, 5},
		{1, terminal.COLUMNS_LIMIT + 1, 1, 10},
		{1, 10, 1, terminal.ROWS_LIMIT + 1},
	}
	for b in bad_bounds {
		_, _, err := grid_dimensions_from_pixels(80, 80, 8, 16, b)
		testing.expect_value(t, err, Resize_Error.Invalid_Bounds)
	}
}

@(test)
grid_init_and_resize_refusals_do_not_corrupt_state :: proc(t: ^testing.T) {
	cells: [terminal.ROWS_LIMIT * terminal.COLUMNS_LIMIT]interface.Text_Grid_Cell
	grid: Resizable_Grid

	// Refused inits: nil grid, short buffer, small stride, out-of-range initial dims.
	testing.expect_value(t, grid_init(nil, cells[:], terminal.COLUMNS_LIMIT, 10, 5), Resize_Error.Invalid_Buffer)
	testing.expect_value(t, grid_init(&grid, cells[:100], terminal.COLUMNS_LIMIT, 10, 5), Resize_Error.Invalid_Buffer)
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT - 1, 10, 5), Resize_Error.Invalid_Buffer)
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, 0, 5), Resize_Error.Below_Minimum)
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, 5, 0), Resize_Error.Below_Minimum)
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, terminal.COLUMNS_LIMIT + 1, 5), Resize_Error.Above_Maximum)
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, 5, terminal.ROWS_LIMIT + 1), Resize_Error.Above_Maximum)

	// Valid init at 10x6.
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, 10, 6), Resize_Error.None)
	testing.expect(t, grid_cell_set(&grid, 3, 2, make_cell('Z')))
	testing.expect(t, grid_cursor_set(&grid, 7, 4))
	grid_damage_clear(&grid)

	// Adversarial resizes must fail without mutating dimensions, cursor, cells, or damage.
	bad_sizes := [?][2]int{
		{0, 0},
		{-5, 4},
		{4, -1},
		{0, 6},
		{10, 0},
		{terminal.COLUMNS_LIMIT + 1, 6},
		{10, terminal.ROWS_LIMIT + 1},
		{max(int), max(int)},
	}
	for s in bad_sizes {
		err := grid_resize_cells(&grid, s[0], s[1])
		testing.expectf(t, err != .None, "resize to %dx%d must fail", s[0], s[1])
		testing.expect_value(t, grid.columns, 10)
		testing.expect_value(t, grid.rows, 6)
		testing.expect_value(t, grid.cursor, Cursor{7, 4})
		testing.expect_value(t, grid.damage.dirty, false)
		c, ok := grid_cell_get(&grid, 3, 2)
		testing.expect(t, ok && c.character == 'Z')
	}

	// Pixel resize refusal also leaves grid untouched.
	testing.expect_value(t, grid_resize_pixels(&grid, 0, 0, 8, 16), Resize_Error.Invalid_Pixels)
	testing.expect_value(t, grid_resize_pixels(&grid, 80, 80, 0, 16), Resize_Error.Invalid_Cell_Size)
	testing.expect_value(t, grid.columns, 10)
	testing.expect_value(t, grid.rows, 6)
	testing.expect_value(t, grid.cursor, Cursor{7, 4})
}

@(test)
shrink_clamps_cursor_preserves_visible_and_clears_vacated_cells :: proc(t: ^testing.T) {
	cells: [terminal.ROWS_LIMIT * terminal.COLUMNS_LIMIT]interface.Text_Grid_Cell
	grid: Resizable_Grid
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, 12, 8), Resize_Error.None)

	// Populate row 0 with "ABCDEFGHIJKL" and row 5 with "012345".
	for i in 0 ..< 12 {
		testing.expect(t, grid_cell_set(&grid, i, 0, make_cell(rune('A' + i))))
	}
	for i in 0 ..< 6 {
		testing.expect(t, grid_cell_set(&grid, i, 5, make_cell(rune('0' + i))))
	}
	testing.expect(t, grid_cursor_set(&grid, 11, 7))
	grid_damage_clear(&grid)

	// Shrink below cursor to 5x3.
	testing.expect_value(t, grid_resize_cells(&grid, 5, 3), Resize_Error.None)
	testing.expect_value(t, grid.columns, 5)
	testing.expect_value(t, grid.rows, 3)
	// Cursor strictly clamped inside [0..4] x [0..2].
	testing.expect_value(t, grid.cursor, Cursor{4, 2})
	// Full redraw damage set for new bounds.
	testing.expect_value(t, grid.damage, Grid_Damage{dirty = true, full_redraw = true, left = 0, top = 0, right = 5, bottom = 3})

	// Visible content preserved on row 0 ("ABCDE").
	for i in 0 ..< 5 {
		c, ok := grid_cell_get(&grid, i, 0)
		testing.expect(t, ok && c.character == rune('A' + i))
	}
	// Out-of-bounds reads refused.
	_, oob_col := grid_cell_get(&grid, 5, 0)
	_, oob_row := grid_cell_get(&grid, 0, 3)
	testing.expect(t, !oob_col && !oob_row)

	// Grow back to 12x8: vacated cells must be blank (no ghost text from before shrink!).
	testing.expect_value(t, grid_resize_cells(&grid, 12, 8), Resize_Error.None)
	for i in 0 ..< 5 {
		c, ok := grid_cell_get(&grid, i, 0)
		testing.expect(t, ok && c.character == rune('A' + i))
	}
	for i in 5 ..< 12 {
		c, ok := grid_cell_get(&grid, i, 0)
		testing.expectf(t, ok && c.character == 0, "ghost character %v at col %d after grow", c.character, i)
	}
	for i in 0 ..< 6 {
		c, ok := grid_cell_get(&grid, i, 5)
		testing.expectf(t, ok && c.character == 0, "ghost character %v at row 5 col %d after grow", c.character, i)
	}
	// Cursor stays at (4, 2) on grow.
	testing.expect_value(t, grid.cursor, Cursor{4, 2})
}

@(test)
one_by_one_and_max_bounds_round_trip :: proc(t: ^testing.T) {
	cells: [terminal.ROWS_LIMIT * terminal.COLUMNS_LIMIT]interface.Text_Grid_Cell
	grid: Resizable_Grid
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, 1, 1), Resize_Error.None)
	testing.expect(t, grid_cell_set(&grid, 0, 0, make_cell('X')))
	testing.expect(t, !grid_cell_set(&grid, 1, 0, make_cell('Y')))
	testing.expect(t, !grid_cursor_set(&grid, 1, 0))
	testing.expect_value(t, grid.cursor, Cursor{0, 0})

	// Grow from 1x1 to exact max (COLUMNS_LIMIT x ROWS_LIMIT).
	testing.expect_value(t, grid_resize_cells(&grid, terminal.COLUMNS_LIMIT, terminal.ROWS_LIMIT), Resize_Error.None)
	c0, ok0 := grid_cell_get(&grid, 0, 0)
	testing.expect(t, ok0 && c0.character == 'X')
	testing.expect(t, grid_cell_set(&grid, terminal.COLUMNS_LIMIT - 1, terminal.ROWS_LIMIT - 1, make_cell('!')))
	testing.expect(t, grid_cursor_set(&grid, terminal.COLUMNS_LIMIT - 1, terminal.ROWS_LIMIT - 1))

	// Shrink back to 1x1: cell (0,0) survives, cursor clamps to (0,0).
	testing.expect_value(t, grid_resize_cells(&grid, 1, 1), Resize_Error.None)
	testing.expect_value(t, grid.cursor, Cursor{0, 0})
	c1, ok1 := grid_cell_get(&grid, 0, 0)
	testing.expect(t, ok1 && c1.character == 'X')

	// Text_Grid export reflects exact dimensions and stride.
	tg := grid_text_grid(&grid)
	testing.expect_value(t, tg.columns, 1)
	testing.expect_value(t, tg.rows, 1)
	testing.expect_value(t, tg.stride, terminal.COLUMNS_LIMIT)
}

@(test)
damage_tracking_and_window_chrome_helpers :: proc(t: ^testing.T) {
	cells: [terminal.ROWS_LIMIT * terminal.COLUMNS_LIMIT]interface.Text_Grid_Cell
	grid: Resizable_Grid
	testing.expect_value(t, grid_init(&grid, cells[:], terminal.COLUMNS_LIMIT, 20, 10), Resize_Error.None)
	grid_damage_clear(&grid)
	testing.expect_value(t, grid.damage.dirty, false)

	// Two separate cell writes produce their bounding damage rectangle.
	testing.expect(t, grid_cell_set(&grid, 2, 3, make_cell('a')))
	testing.expect(t, grid_cell_set(&grid, 6, 5, make_cell('b')))
	testing.expect_value(t, grid.damage, Grid_Damage{dirty = true, full_redraw = false, left = 2, top = 3, right = 7, bottom = 6})

	// Same-size resize preserves pending damage.
	testing.expect_value(t, grid_resize_cells(&grid, 20, 10), Resize_Error.None)
	testing.expect_value(t, grid.damage, Grid_Damage{dirty = true, full_redraw = false, left = 2, top = 3, right = 7, bottom = 6})

	// Window chrome helpers match terminal limits and reject undersized windows.
	chrome_w := 8 + 8 + interface.SCROLL_BAR_THICKNESS
	chrome_h := 8 + 8 + graphics.CELL_HEIGHT + 6
	limits, lim_ok := window_size_limits(chrome_w, chrome_h, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, TERMINAL_WINDOW_BOUNDS)
	testing.expect(t, lim_ok)
	testing.expect_value(t, limits.least_width, chrome_w + 40 * graphics.CELL_WIDTH)
	testing.expect_value(t, limits.least_height, chrome_h + 4 * graphics.CELL_HEIGHT)
	testing.expect_value(t, limits.largest_width, chrome_w + terminal.COLUMNS_LIMIT * graphics.CELL_WIDTH)
	testing.expect_value(t, limits.largest_height, chrome_h + terminal.ROWS_LIMIT * graphics.CELL_HEIGHT)

	cols, rows, err := grid_dimensions_from_window(limits.least_width, limits.least_height, chrome_w, chrome_h, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, TERMINAL_WINDOW_BOUNDS)
	testing.expect_value(t, err, Resize_Error.None)
	testing.expect_value(t, cols, 40)
	testing.expect_value(t, rows, 4)

	// One pixel narrower than minimum falls below 40 columns.
	_, _, err = grid_dimensions_from_window(limits.least_width - 1, limits.least_height, chrome_w, chrome_h, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, TERMINAL_WINDOW_BOUNDS)
	testing.expect_value(t, err, Resize_Error.Below_Minimum)

	// Window smaller than chrome is Invalid_Pixels.
	_, _, err = grid_dimensions_from_window(chrome_w, chrome_h, chrome_w, chrome_h, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, TERMINAL_WINDOW_BOUNDS)
	testing.expect_value(t, err, Resize_Error.Invalid_Pixels)
}
