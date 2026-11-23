// Pure freestanding terminal grid resize logic (src/md/features/window_resize.md).
//
// Computes exact (columns, rows) from pixel dimensions and font cell metrics
// under strict minimum and maximum bounds, resizes a caller-supplied cell
// buffer in place while preserving visible content and clearing vacated or
// newly exposed cells, clamps the cursor strictly inside the active grid,
// and maintains consistent dirty-damage tracking.
package grid_resize

import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:terminal"

// The limits of the terminal contract count cells of the font of the
// system: a cell of another size would give a maximized window a grid
// that does not cover it.
#assert(terminal.GRID_CELL_WIDTH == graphics.CELL_WIDTH && terminal.GRID_CELL_HEIGHT == graphics.CELL_HEIGHT)

// Inclusive minimum and maximum dimensions of a terminal grid, in cells.
Grid_Bounds :: struct {
	min_columns: int,
	max_columns: int,
	min_rows:    int,
	max_rows:    int,
}

// General bounds: at least 1x1 cell, up to the terminal contract limits.
DEFAULT_BOUNDS :: Grid_Bounds {
	min_columns = 1,
	max_columns = terminal.COLUMNS_LIMIT,
	min_rows    = 1,
	max_rows    = terminal.ROWS_LIMIT,
}

// Bounds for a standard terminal window.
TERMINAL_WINDOW_BOUNDS :: Grid_Bounds {
	min_columns = 40,
	max_columns = terminal.COLUMNS_LIMIT,
	min_rows    = 4,
	max_rows    = terminal.ROWS_LIMIT,
}

// Reason a grid initialization or resize request was refused.
Resize_Error :: enum u8 {
	None              = 0,
	Invalid_Cell_Size = 1,
	Invalid_Bounds    = 2,
	Invalid_Pixels    = 3,
	Below_Minimum     = 4,
	Above_Maximum     = 5,
	Invalid_Buffer    = 6,
}

// Cursor position inside the active grid, in 0-based cell coordinates.
Cursor :: struct {
	column: int,
	row:    int,
}

// Dirty cell region accumulated since the last draw.
// Coordinates are half-open: [left, right) x [top, bottom).
Grid_Damage :: struct {
	dirty:       bool,
	full_redraw: bool,
	left:        int,
	top:         int,
	right:       int,
	bottom:      int,
}

// Caller-backed terminal grid supporting atomic, zero-allocation resizes.
Resizable_Grid :: struct {
	cells:   []interface.Text_Grid_Cell,
	stride:  int,
	columns: int,
	rows:    int,
	bounds:  Grid_Bounds,
	cursor:  Cursor,
	damage:  Grid_Damage,
}

// bounds_valid checks that bounds are positive, ordered, and within the
// terminal contract limits.
bounds_valid :: proc "contextless" (bounds: Grid_Bounds) -> bool {
	if bounds.min_columns < 1 || bounds.min_rows < 1 {
		return false
	}
	if bounds.max_columns < bounds.min_columns || bounds.max_rows < bounds.min_rows {
		return false
	}
	if bounds.max_columns > terminal.COLUMNS_LIMIT || bounds.max_rows > terminal.ROWS_LIMIT {
		return false
	}
	return true
}

// grid_dimensions_from_pixels computes the exact (columns, rows) fitting
// inside pixel_width x pixel_height for a font cell of cell_width x
// cell_height pixels. Refuses zero, negative, or out-of-bound inputs without
// returning partial dimensions.
grid_dimensions_from_pixels :: proc "contextless" (
	pixel_width, pixel_height: int,
	cell_width, cell_height: int,
	bounds: Grid_Bounds = DEFAULT_BOUNDS,
) -> (columns, rows: int, err: Resize_Error) {
	if cell_width <= 0 || cell_height <= 0 {
		return 0, 0, .Invalid_Cell_Size
	}
	if !bounds_valid(bounds) {
		return 0, 0, .Invalid_Bounds
	}
	if pixel_width <= 0 || pixel_height <= 0 || pixel_width > display.SURFACE_LIMIT || pixel_height > display.SURFACE_LIMIT {
		return 0, 0, .Invalid_Pixels
	}
	cols := pixel_width / cell_width
	r := pixel_height / cell_height
	if cols < bounds.min_columns || r < bounds.min_rows {
		return 0, 0, .Below_Minimum
	}
	if cols > bounds.max_columns || r > bounds.max_rows {
		return 0, 0, .Above_Maximum
	}
	return cols, r, .None
}

// grid_dimensions_from_window subtracts fixed window chrome pixels before
// computing exact grid dimensions.
grid_dimensions_from_window :: proc "contextless" (
	window_width, window_height: int,
	chrome_width, chrome_height: int,
	cell_width, cell_height: int,
	bounds: Grid_Bounds = TERMINAL_WINDOW_BOUNDS,
) -> (columns, rows: int, err: Resize_Error) {
	if cell_width <= 0 || cell_height <= 0 {
		return 0, 0, .Invalid_Cell_Size
	}
	if !bounds_valid(bounds) {
		return 0, 0, .Invalid_Bounds
	}
	if chrome_width < 0 || chrome_height < 0 {
		return 0, 0, .Invalid_Pixels
	}
	if window_width <= chrome_width || window_height <= chrome_height {
		return 0, 0, .Invalid_Pixels
	}
	if window_width > display.SURFACE_LIMIT || window_height > display.SURFACE_LIMIT {
		return 0, 0, .Invalid_Pixels
	}
	return grid_dimensions_from_pixels(
		window_width - chrome_width,
		window_height - chrome_height,
		cell_width,
		cell_height,
		bounds,
	)
}

// window_size_limits derives display.Size_Limits matching the given chrome
// size, cell size, and grid bounds.
window_size_limits :: proc "contextless" (
	chrome_width, chrome_height: int,
	cell_width, cell_height: int,
	bounds: Grid_Bounds = TERMINAL_WINDOW_BOUNDS,
) -> (limits: display.Size_Limits, ok: bool) {
	if cell_width <= 0 || cell_height <= 0 || chrome_width < 0 || chrome_height < 0 || !bounds_valid(bounds) {
		return {}, false
	}
	// Guard against signed int overflow before multiplying or adding chrome.
	if bounds.max_columns > max(int) / cell_width || bounds.max_rows > max(int) / cell_height {
		return {}, false
	}
	min_text_w := bounds.min_columns * cell_width
	min_text_h := bounds.min_rows * cell_height
	max_text_w := bounds.max_columns * cell_width
	max_text_h := bounds.max_rows * cell_height
	if chrome_width > max(int) - max_text_w || chrome_height > max(int) - max_text_h {
		return {}, false
	}
	least_w := max(display.RESIZABLE_LEAST_WIDTH, chrome_width + min_text_w)
	least_h := max(display.RESIZABLE_LEAST_HEIGHT, chrome_height + min_text_h)
	largest_w := min(display.SURFACE_LIMIT, chrome_width + max_text_w)
	largest_h := min(display.SURFACE_LIMIT, chrome_height + max_text_h)
	if least_w > largest_w || least_h > largest_h {
		return {}, false
	}
	return display.Size_Limits{
		least_width    = least_w,
		least_height   = least_h,
		largest_width  = largest_w,
		largest_height = largest_h,
	}, true
}

// grid_buffer_valid checks that cells and stride hold the maximum grid
// without integer overflow.
@(private)
grid_buffer_valid :: proc "contextless" (cells: []interface.Text_Grid_Cell, stride: int, bounds: Grid_Bounds) -> bool {
	if !bounds_valid(bounds) || stride < bounds.max_columns {
		return false
	}
	if bounds.max_rows > max(int) / stride {
		return false
	}
	return len(cells) >= bounds.max_rows * stride
}

// grid_init binds a Resizable_Grid to a caller-supplied cell buffer.
// On refusal, grid is not modified.
grid_init :: proc "contextless" (
	grid: ^Resizable_Grid,
	cells: []interface.Text_Grid_Cell,
	stride: int,
	columns, rows: int,
	bounds: Grid_Bounds = DEFAULT_BOUNDS,
) -> Resize_Error {
	if grid == nil {
		return .Invalid_Buffer
	}
	if !bounds_valid(bounds) {
		return .Invalid_Bounds
	}
	if !grid_buffer_valid(cells, stride, bounds) {
		return .Invalid_Buffer
	}
	if columns < bounds.min_columns || rows < bounds.min_rows {
		return .Below_Minimum
	}
	if columns > bounds.max_columns || rows > bounds.max_rows {
		return .Above_Maximum
	}
	grid^ = {
		cells   = cells,
		stride  = stride,
		columns = columns,
		rows    = rows,
		bounds  = bounds,
		cursor  = {0, 0},
		damage  = {dirty = true, full_redraw = true, left = 0, top = 0, right = columns, bottom = rows},
	}
	return .None
}

// grid_cell_get reads a cell inside the active grid bounds.
grid_cell_get :: proc "contextless" (grid: ^Resizable_Grid, column, row: int) -> (cell: interface.Text_Grid_Cell, ok: bool) {
	if grid == nil || column < 0 || column >= grid.columns || row < 0 || row >= grid.rows {
		return {}, false
	}
	return grid.cells[row * grid.stride + column], true
}

// grid_cell_set writes a cell inside the active grid bounds and marks it dirty.
grid_cell_set :: proc "contextless" (grid: ^Resizable_Grid, column, row: int, cell: interface.Text_Grid_Cell) -> bool {
	if grid == nil || column < 0 || column >= grid.columns || row < 0 || row >= grid.rows {
		return false
	}
	grid.cells[row * grid.stride + column] = cell
	grid_damage_add(grid, column, row, column + 1, row + 1)
	return true
}

// grid_cursor_set sets the cursor inside the active grid bounds.
// Out-of-bounds coordinates are refused without modifying the cursor.
grid_cursor_set :: proc "contextless" (grid: ^Resizable_Grid, column, row: int) -> bool {
	if grid == nil || column < 0 || column >= grid.columns || row < 0 || row >= grid.rows {
		return false
	}
	grid.cursor = {column = column, row = row}
	return true
}

// grid_damage_add unions a half-open cell rectangle [left, right) x [top, bottom),
// clipped to the active grid, into grid.damage.
grid_damage_add :: proc "contextless" (grid: ^Resizable_Grid, left, top, right, bottom: int) {
	if grid == nil || grid.columns <= 0 || grid.rows <= 0 {
		return
	}
	l := clamp(left, 0, grid.columns)
	t := clamp(top, 0, grid.rows)
	r := clamp(right, 0, grid.columns)
	b := clamp(bottom, 0, grid.rows)
	if r <= l || b <= t {
		return
	}
	if !grid.damage.dirty {
		grid.damage = {dirty = true, full_redraw = false, left = l, top = t, right = r, bottom = b}
	} else {
		grid.damage.left = min(grid.damage.left, l)
		grid.damage.top = min(grid.damage.top, t)
		grid.damage.right = max(grid.damage.right, r)
		grid.damage.bottom = max(grid.damage.bottom, b)
	}
	if grid.damage.left == 0 && grid.damage.top == 0 && grid.damage.right == grid.columns && grid.damage.bottom == grid.rows {
		grid.damage.full_redraw = true
	}
}

// grid_damage_clear resets pending dirty damage after a draw consumes it.
grid_damage_clear :: proc "contextless" (grid: ^Resizable_Grid) {
	if grid != nil {
		grid.damage = {}
	}
}

// grid_resize_cells atomically resizes the grid to (new_columns, new_rows).
// Preserves all cells in the overlapping region [0, min(old, new)), clears
// vacated and newly exposed cells so stale content cannot reappear on a
// subsequent grow, clamps the cursor strictly inside the new bounds, and
// marks full-grid damage when dimensions change.
// On any error, the grid is left completely unchanged.
grid_resize_cells :: proc "contextless" (grid: ^Resizable_Grid, new_columns, new_rows: int) -> Resize_Error {
	if grid == nil {
		return .Invalid_Buffer
	}
	if !bounds_valid(grid.bounds) {
		return .Invalid_Bounds
	}
	if !grid_buffer_valid(grid.cells, grid.stride, grid.bounds) {
		return .Invalid_Buffer
	}
	if new_columns < grid.bounds.min_columns || new_rows < grid.bounds.min_rows {
		return .Below_Minimum
	}
	if new_columns > grid.bounds.max_columns || new_rows > grid.bounds.max_rows {
		return .Above_Maximum
	}
	old_columns := grid.columns
	old_rows := grid.rows
	if new_columns == old_columns && new_rows == old_rows {
		// Keep existing cells and damage intact; ensure cursor stays clamped.
		grid.cursor.column = clamp(grid.cursor.column, 0, new_columns - 1)
		grid.cursor.row = clamp(grid.cursor.row, 0, new_rows - 1)
		return .None
	}
	keep_rows := min(old_rows, new_rows)
	for r in 0 ..< keep_rows {
		row_base := r * grid.stride
		if new_columns > old_columns {
			for c in old_columns ..< new_columns {
				grid.cells[row_base + c] = {}
			}
		} else if new_columns < old_columns {
			for c in new_columns ..< old_columns {
				grid.cells[row_base + c] = {}
			}
		}
	}
	if new_rows > old_rows {
		for r in old_rows ..< new_rows {
			row_base := r * grid.stride
			for c in 0 ..< new_columns {
				grid.cells[row_base + c] = {}
			}
		}
	} else if new_rows < old_rows {
		for r in new_rows ..< old_rows {
			row_base := r * grid.stride
			for c in 0 ..< old_columns {
				grid.cells[row_base + c] = {}
			}
		}
	}
	grid.columns = new_columns
	grid.rows = new_rows
	grid.cursor.column = clamp(grid.cursor.column, 0, new_columns - 1)
	grid.cursor.row = clamp(grid.cursor.row, 0, new_rows - 1)
	grid.damage = {
		dirty       = true,
		full_redraw = true,
		left        = 0,
		top         = 0,
		right       = new_columns,
		bottom      = new_rows,
	}
	return .None
}

// grid_resize_pixels computes new cell dimensions from pixels and font cell
// size, then atomically resizes the grid. On refusal, nothing changes.
grid_resize_pixels :: proc "contextless" (
	grid: ^Resizable_Grid,
	pixel_width, pixel_height: int,
	cell_width, cell_height: int,
) -> Resize_Error {
	if grid == nil {
		return .Invalid_Buffer
	}
	new_columns, new_rows, err := grid_dimensions_from_pixels(pixel_width, pixel_height, cell_width, cell_height, grid.bounds)
	if err != .None {
		return err
	}
	return grid_resize_cells(grid, new_columns, new_rows)
}

// grid_text_grid returns an interface.Text_Grid view over the active region
// of grid.
grid_text_grid :: proc "contextless" (grid: ^Resizable_Grid) -> interface.Text_Grid {
	if grid == nil {
		return {}
	}
	return interface.Text_Grid{
		cells   = grid.cells,
		columns = grid.columns,
		rows    = grid.rows,
		stride  = grid.stride,
	}
}
