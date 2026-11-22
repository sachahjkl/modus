// Full-screen direct framebuffer monospace grid renderer for modus:terminal
// (src/md/features/console_renderers.md, "Variant B: grid_terminal").
//
// Renders the typed console grid (Modus 24-bit theme colors, Lex syntax
// highlighting, block cursor, Status line, and interactive completion popup)
// directly onto a linear framebuffer via graphics.character (Spleen 8x16)
// with per-row dirty tracking — zero compositor, zero window chrome, and
// zero TrueType outline rasterization.
package grid_renderer

import "modus:graphics"
import terminal_records "modus:terminal"

GRID_COLUMNS_LIMIT :: terminal_records.COLUMNS_LIMIT
GRID_ROWS_LIMIT :: terminal_records.ROWS_LIMIT

Grid_Cell :: struct {
	character:  rune,
	foreground: graphics.Color,
	background: graphics.Color,
}

Grid_Screen :: struct {
	columns:       int,
	rows:          int,
	cells:         [GRID_ROWS_LIMIT][GRID_COLUMNS_LIMIT]Grid_Cell,
	dirty_rows:    [GRID_ROWS_LIMIT]bool,
	cursor_row:    int,
	cursor_col:    int,
	cursor_shown:  bool,
	popup_visible: bool,
	popup_top:     int,
	popup_bottom:  int,
}

grid_init :: proc "contextless" (screen: ^Grid_Screen, columns, rows: int, appearance: graphics.Appearance) {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	screen^ = {}
	screen.columns = clamp(columns, 1, GRID_COLUMNS_LIMIT)
	screen.rows = clamp(rows, 1, GRID_ROWS_LIMIT)
	for r in 0 ..< screen.rows {
		for c in 0 ..< screen.columns {
			screen.cells[r][c] = {character = ' ', foreground = palette.text, background = palette.background}
		}
		screen.dirty_rows[r] = true
	}
}

grid_cell_set :: proc "contextless" (screen: ^Grid_Screen, row, col: int, ch: rune, fg, bg: graphics.Color) {
	if row < 0 || row >= screen.rows || col < 0 || col >= screen.columns {
		return
	}
	cell := Grid_Cell{character = ch, foreground = fg, background = bg}
	if screen.cells[row][col] != cell {
		screen.cells[row][col] = cell
		screen.dirty_rows[row] = true
	}
}

grid_row_clear :: proc "contextless" (screen: ^Grid_Screen, row: int, appearance: graphics.Appearance) {
	if row < 0 || row >= screen.rows {
		return
	}
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	for c in 0 ..< screen.columns {
		grid_cell_set(screen, row, c, ' ', palette.text, palette.background)
	}
}

grid_tone_color :: proc "contextless" (tone: terminal_records.Tone, appearance: graphics.Appearance) -> graphics.Color {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	switch tone {
	case .Default:
		return palette.text
	case .Dim:
		return palette.dim
	case .Strong:
		return palette.text_strong
	case .Good:
		return palette.process
	case .Warning:
		return palette.boot_program
	case .Bad:
		return palette.failed
	case .Accent:
		return palette.chosen
	case .Number:
		return palette.memory
	}
	return palette.text
}

// grid_write_edit_line writes the Lex-highlighted edit line into row and
// updates the cursor location.
grid_write_edit_line :: proc "contextless" (
	screen: ^Grid_Screen,
	row: int,
	text: []u8,
	runs: ^terminal_records.Code_Runs,
	cursor_byte: u64,
	appearance: graphics.Appearance,
) {
	if row < 0 || row >= screen.rows {
		return
	}
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	grid_row_clear(screen, row, appearance)
	for i in 0 ..< min(len(text), screen.columns) {
		fg := palette.text
		if runs != nil {
			for r_idx in 0 ..< min(runs.count, terminal_records.CODE_RUN_LIMIT) {
				run := runs.runs[r_idx]
				if i >= int(run.start) && i < int(run.start) + int(run.length) {
					if kind, ok := terminal_records.code_kind_of(run.kind); ok && kind != .None {
						class := terminal_records.code_kind_classes[kind]
						if class != .None {
							fg = graphics.code_class_color(class, appearance)
						}
					}
					break
				}
			}
		}
		grid_cell_set(screen, row, i, rune(text[i]), fg, palette.background)
	}
	if screen.cursor_shown && screen.cursor_row >= 0 && screen.cursor_row < screen.rows {
		screen.dirty_rows[screen.cursor_row] = true
	}
	screen.cursor_shown = cursor_byte != terminal_records.NO_CURSOR
	screen.cursor_row = row
	screen.cursor_col = clamp(int(cursor_byte), 0, screen.columns - 1)
	screen.dirty_rows[row] = true
}

// grid_present_dirty blits only dirty rows (plus any active completion popup)
// directly onto the framebuffer canvas using Spleen 8x16 cells.
// Returns the number of rows blitted.
grid_present_dirty :: proc "contextless" (
	screen: ^Grid_Screen,
	canvas: graphics.Canvas,
	popup: ^terminal_records.List_Shown,
	anchor_row: int,
	appearance: graphics.Appearance,
) -> (blitted_rows: int) {
	if canvas.width < graphics.CELL_WIDTH || canvas.height < graphics.CELL_HEIGHT {
		return 0
	}
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	// If a popup was shown before and is now closed, mark its rows dirty to restore background.
	want_popup := popup != nil && popup.row_count > 0
	if screen.popup_visible && !want_popup {
		for r in max(screen.popup_top, 0) ..= min(screen.popup_bottom, screen.rows - 1) {
			screen.dirty_rows[r] = true
		}
		screen.popup_visible = false
	}

	for r in 0 ..< screen.rows {
		if !screen.dirty_rows[r] {
			continue
		}
		y := r * graphics.CELL_HEIGHT
		if y + graphics.CELL_HEIGHT > canvas.height {
			break
		}
		for c in 0 ..< screen.columns {
			x := c * graphics.CELL_WIDTH
			if x + graphics.CELL_WIDTH > canvas.width {
				break
			}
			cell := screen.cells[r][c]
			fg, bg := cell.foreground, cell.background
			if screen.cursor_shown && r == screen.cursor_row && c == screen.cursor_col {
				fg, bg = bg, palette.chosen
			}
			graphics.fill(canvas, x, y, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, bg)
			if cell.character != ' ' && cell.character != 0 {
				graphics.character(canvas, x, y, cell.character, fg)
			}
		}
		screen.dirty_rows[r] = false
		blitted_rows += 1
	}

	if want_popup {
		rows := min(popup.row_count, terminal_records.LIST_ROWS)
		box_col := clamp(popup.anchor, 0, max(screen.columns - 24, 0))
		box_cols := clamp(screen.columns - box_col, 20, 54)
		top_row := clamp(anchor_row + 1, 0, max(screen.rows - rows - 1, 0))
		px := box_col * graphics.CELL_WIDTH
		py := top_row * graphics.CELL_HEIGHT
		pw := min(box_cols * graphics.CELL_WIDTH, canvas.width - px)
		ph := min(rows * graphics.CELL_HEIGHT + 4, canvas.height - py)
		if pw > 8 && ph > 8 {
			graphics.fill(canvas, px, py, pw, ph, palette.card_bottom)
			graphics.outline(canvas, px, py, pw, ph, 1, palette.edge)
			for i in 0 ..< rows {
				row := &popup.rows[i]
				selected := i == popup.chosen
				ry := py + 2 + i * graphics.CELL_HEIGHT
				row_bg := selected ? palette.chosen : palette.card_bottom
				name_fg := selected ? graphics.COLOR_WHITE : palette.text_strong
				desc_fg := selected ? graphics.COLOR_WHITE : palette.dim
				graphics.fill(canvas, px + 1, ry, pw - 2, graphics.CELL_HEIGHT, row_bg)
				cx := px + 6
				name_len := min(row.name_length, row.length)
				for k in 0 ..< name_len {
					if cx + graphics.CELL_WIDTH > px + pw - 4 {
						break
					}
					graphics.character(canvas, cx, ry, rune(row.text[k]), name_fg)
					cx += graphics.CELL_WIDTH
				}
				cx += graphics.CELL_WIDTH
				for k in name_len ..< row.length {
					if cx + graphics.CELL_WIDTH > px + pw - 4 {
						break
					}
					graphics.character(canvas, cx, ry, rune(row.text[k]), desc_fg)
					cx += graphics.CELL_WIDTH
				}
			}
			screen.popup_visible = true
			screen.popup_top = top_row
			screen.popup_bottom = min(top_row + rows + 1, screen.rows - 1)
		}
	}
	return blitted_rows
}
