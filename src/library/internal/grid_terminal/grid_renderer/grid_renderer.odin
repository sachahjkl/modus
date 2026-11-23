// Full-screen direct framebuffer monospace grid renderer for modus:terminal
// (src/md/features/console_renderers.md, "Variant B: grid_terminal").
//
// Renders the typed console grid (Modus 24-bit theme colors, Lex syntax
// highlighting, block cursor, Status line, and interactive completion popup)
// directly onto a linear framebuffer via graphics.character (Spleen 8x16)
// with per-row dirty tracking — zero compositor, zero window chrome, and
// zero TrueType outline rasterization.
package grid_renderer

import "modus:contract/enum_word"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:display"
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
	popup_column:  int, // The first column of the box on the screen.
	popup_columns: int, // The columns of the box.
	list_changed:  bool, // A List record came since the box was drawn: the box is drawn again.
}

// grid_list_changed marks the completion list as changed: the next present
// draws its box again.
grid_list_changed :: proc "contextless" (screen: ^Grid_Screen) {
	screen.list_changed = true
}

// The place where the next output goes: a row of the output and a column.
Grid_Output :: struct {
	row:    int,
	column: int,
}

// The largest code of a key: a scan code of set 1 with KEY_EXTENDED.
KEY_CODE_MOST :: display.KEY_EXTENDED | 0xFF

// The modifier bits that a key record can hold.
KEY_MODIFIERS_KNOWN :: u64(display.MODIFIER_SHIFT | display.MODIFIER_CONTROL | display.MODIFIER_ALT)

// key_of_input_record is the border of a record of the input ring, which
// the input service writes and grid_terminal reads in place of the
// compositor: the key of a press. A record whose kind names no input, a
// pointer record, a release, a pressed word other than 0 and 1, a code past
// KEY_CODE_MOST, a character that is no code point or a surrogate, and a
// modifier bit that names no modifier give no key. It reads and changes no
// state.
key_of_input_record :: proc "contextless" (record: ring.Record) -> (key: terminal_records.Key, ok: bool) {
	kind := enum_word.member_of_word(display.Input, u64(record.kind)) or_return
	switch kind {
	case .None, .Pointer, .Pointer_Absolute:
		return {}, false
	case .Key:
	}
	code, character, pressed, modifiers := record.values[0], record.values[1], record.values[2], record.values[3]
	if pressed > 1 || code > KEY_CODE_MOST || character > text_encoding.CODE_POINT_LAST || (character >= 0xD800 && character <= 0xDFFF) || modifiers & ~KEY_MODIFIERS_KNOWN != 0 {
		return {}, false
	}
	if pressed == 0 {
		return {}, false
	}
	return {code = u32(code), character = rune(character), modifiers = u32(modifiers)}, true
}

// grid_scroll_up moves the rows 1 to last_row up by one row, and clears
// last_row: the rows below it, the edit line, stay. A last_row past the
// screen is cut to its last row; a negative one does nothing.
grid_scroll_up :: proc "contextless" (screen: ^Grid_Screen, last_row: int, appearance: graphics.Appearance) {
	last := min(last_row, screen.rows - 1)
	if last < 0 {
		return
	}
	for r in 0 ..< last {
		screen.cells[r] = screen.cells[r + 1]
		screen.dirty_rows[r] = true
	}
	grid_row_clear(screen, last, appearance)
	screen.dirty_rows[last] = true
}

// grid_output_new_line moves the output to the start of its next row; at
// the last row of the output, the output scrolls up.
grid_output_new_line :: proc "contextless" (screen: ^Grid_Screen, output: ^Grid_Output, output_rows: int, appearance: graphics.Appearance) {
	output.column = 0
	if output.row + 1 < output_rows {
		output.row += 1
	} else {
		grid_scroll_up(screen, output_rows - 1, appearance)
	}
}

// grid_write_output writes a run of output at the place of the output, one
// cell for each character: it wraps at the last column, and a new line at
// the last of the output_rows rows scrolls them up. An invalid sequence
// and a control character show the replacement character, as the terminal
// of the desktop shows them. output_rows is cut to the rows of the screen
// and is at least 1; a place out of the output is moved into it.
grid_write_output :: proc "contextless" (screen: ^Grid_Screen, output: ^Grid_Output, text: []u8, foreground, background: graphics.Color, end_line: bool, output_rows: int, appearance: graphics.Appearance) {
	rows := clamp(output_rows, 1, screen.rows)
	output.row = clamp(output.row, 0, rows - 1)
	output.column = clamp(output.column, 0, screen.columns)
	place := 0
	for place < len(text) {
		character, length, _ := text_encoding.character_decode(text, place)
		place += max(length, 1)
		if output.column >= screen.columns {
			grid_output_new_line(screen, output, rows, appearance)
		}
		grid_cell_set(screen, output.row, output.column, character, foreground, background)
		output.column += 1
	}
	if end_line {
		grid_output_new_line(screen, output, rows, appearance)
	}
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
	runs: []terminal_records.Code_Run,
	cursor_byte: u64,
	appearance: graphics.Appearance,
) {
	if row < 0 || row >= screen.rows {
		return
	}
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	grid_row_clear(screen, row, appearance)
	// One cell for each UTF-8 character; the runs and the cursor name
	// bytes, so each cell keeps the byte where its character starts.
	cursor_cell := 0
	cell := 0
	place := 0
	for place < len(text) && cell < screen.columns {
		character, length, _ := text_encoding.character_decode(text, place)
		length = max(length, 1)
		if cursor_byte != terminal_records.NO_CURSOR && u64(place) < cursor_byte {
			cursor_cell = cell + 1
		}
		i := place
		fg := palette.text
		for run in runs {
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
		grid_cell_set(screen, row, cell, character, fg, palette.background)
		place += length
		cell += 1
	}
	if screen.cursor_shown && screen.cursor_row >= 0 && screen.cursor_row < screen.rows {
		screen.dirty_rows[screen.cursor_row] = true
	}
	screen.cursor_shown = cursor_byte != terminal_records.NO_CURSOR
	screen.cursor_row = row
	// The cursor is after each character that starts before its byte, cut
	// to the last column: a word past the largest int never wraps.
	if cursor_byte != terminal_records.NO_CURSOR && cursor_byte > u64(len(text)) {
		cursor_cell = screen.columns
	}
	screen.cursor_col = clamp(cursor_cell, 0, screen.columns - 1)
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
	if canvas.pixels == nil || canvas.width < graphics.CELL_WIDTH || canvas.height < graphics.CELL_HEIGHT || canvas.stride < canvas.width {
		return 0
	}
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	want_popup := popup != nil && popup.row_count > 0
	// The box of the list this time: when it moved, shrank or closed, the
	// rows under the box of the last time are drawn again first.
	rows := 0
	box_col, box_cols, top_row := 0, 0, 0
	if want_popup {
		rows = min(popup.row_count, terminal_records.LIST_ROWS)
		box_col = clamp(popup.anchor, 0, max(screen.columns - 24, 0))
		box_cols = min(clamp(screen.columns - box_col, 20, 54), screen.columns - box_col)
		top_row = clamp(anchor_row + 1, 0, max(screen.rows - rows - 1, 0))
	}
	if screen.popup_visible {
		moved := !want_popup || top_row != screen.popup_top || min(top_row + rows + 1, screen.rows - 1) != screen.popup_bottom || box_col != screen.popup_column || box_cols != screen.popup_columns
		if moved {
			for r in max(screen.popup_top, 0) ..= min(screen.popup_bottom, screen.rows - 1) {
				screen.dirty_rows[r] = true
			}
			screen.popup_visible = false
		}
	}
	// The box is drawn again only when it is not on the screen, when the
	// list changed, or when a row under it is drawn again over it.
	draw_popup := want_popup && (!screen.popup_visible || screen.list_changed)
	if want_popup && !draw_popup {
		for r in max(top_row, 0) ..= min(top_row + rows + 1, screen.rows - 1) {
			draw_popup ||= screen.dirty_rows[r]
		}
	}
	screen.list_changed = false

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

	if draw_popup {
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
				length := clamp(row.length, 0, len(row.text))
				name_len := clamp(row.name_length, 0, length)
				for k in 0 ..< name_len {
					if cx + graphics.CELL_WIDTH > px + pw - 4 {
						break
					}
					graphics.character(canvas, cx, ry, rune(row.text[k]), name_fg)
					cx += graphics.CELL_WIDTH
				}
				cx += graphics.CELL_WIDTH
				for k in name_len ..< length {
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
			screen.popup_column = box_col
			screen.popup_columns = box_cols
		}
	}
	return blitted_rows
}
