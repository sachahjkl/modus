// Structural, data, text-area, and overlay widgets for modus:interface
// (src/md/features/rich_widgets.md): draggable split-pane divider, sortable
// column-resizable multi-select data table, expandable tree view, multi-line
// text area, hover tooltip, and modal dialog.
// Every widget resolves colors from theme_current(frame) with zero heap allocation.
package interface

import "modus:contract/draw_record"
import "modus:display"
import "modus:graphics"

// Plan value: ratio bounds matching modus:layout.split_pane (10% .. 90% of 10 000).
SPLIT_RATIO_MIN :: 1_000
SPLIT_RATIO_MAX :: 9_000
SPLIT_RATIO_WHOLE :: 10_000
SPLIT_RATIO_DEFAULT :: 5_000

// Orientation of a split_pane_divider.
Split_Orientation :: enum u8 {
	Horizontal = 0, // Left and right panes separated by a vertical divider.
	Vertical   = 1, // Top and bottom panes separated by a horizontal divider.
}

// Caller-owned drag state for split_pane_divider.
Split_Drag_State :: struct {
	dragging:       bool,
	start_pointer:  int,
	start_ratio:    i32,
	last_click_ms:  u64,
}

// Sort direction of a data_table column.
Table_Sort_Order :: enum u8 {
	None       = 0,
	Ascending  = 1,
	Descending = 2,
}

// Plan value: column and row geometry constants for data_table and tree_view.
DATA_TABLE_MAX_COLUMNS :: 16
DATA_TABLE_HEADER_HEIGHT :: 26
DATA_TABLE_ROW_HEIGHT :: 24
DATA_TABLE_MIN_COL_WIDTH :: 44
DATA_TABLE_RESIZE_HIT :: 6

TREE_ROW_HEIGHT :: 24
TREE_INDENT_PX :: 16

// Caller-owned state for data_table (sort, scroll, column resize, multi-select anchor).
Data_Table_State :: struct {
	sort_column:      int,
	sort_order:       Table_Sort_Order,
	scroll_row:       int,
	active_row:       int,
	anchor_row:       int,
	resizing_col:     int, // -1 when not dragging a column boundary.
	resize_start_x:   int,
	resize_start_w:   int,
	resize_init_done: bool,
}

// Column definition for data_table. widths[i] is updated live during resize drags.
Data_Table_Column :: struct {
	title:     string,
	min_width: int,
	alignment: Alignment,
	sortable:  bool,
}

// Outcome of one data_table frame.
Data_Table_Result :: struct {
	sort_changed:      bool,
	selection_changed: bool,
	width_changed:     bool,
	activated_row:     int, // >= 0 on Enter or double-click on a row, else -1.
}

// One visible row of tree_view supplied by the caller.
Tree_Row :: struct {
	id:           u32,
	label:        string,
	detail:       string, // Optional dim text on the right (e.g. file size or count).
	depth:        int,
	has_children: bool,
	expanded:     bool,
}

// Caller-owned scroll and selection state for tree_view.
Tree_View_State :: struct {
	scroll_row: int,
	selected:   int,
}

// Outcome of one tree_view frame.
Tree_View_Result :: struct {
	selection_changed: bool,
	toggle_index:      int, // >= 0 when the user clicked a chevron or pressed Left/Right to toggle.
	activated_index:   int, // >= 0 on Enter or click on a leaf row.
}

// Caller-owned state for multi-line text_area.
Text_Area_State :: struct {
	caret:      int,
	scroll_row: int,
}

// Modal dialog outcome returned by modal_dialog_end.
Modal_Dialog_Result :: struct {
	closed:    bool, // Escape, close button, or scrim click.
	confirmed: bool, // Primary action button pressed.
	cancelled: bool, // Secondary cancel button pressed.
}

// split_pane_divider handles pointer drag, double-click 50/50 reset, and
// keyboard arrow stepping for a divider placed by modus:layout.split_pane.
// room is the total pixel span along orientation (excluding divider thickness).
split_pane_divider :: proc "contextless" (
	frame: ^Frame,
	divider: Area,
	element: Element_Identity,
	orientation: Split_Orientation,
	ratio: ^i32,
	room: int,
	state: ^Split_Drag_State,
) -> (result: Element_Result) {
	if frame == nil || ratio == nil || state == nil || divider.width <= 0 || divider.height <= 0 {
		return
	}
	ratio^ = clamp(ratio^, SPLIT_RATIO_MIN, SPLIT_RATIO_MAX)
	before := ratio^
	result = element_interact(frame, element, divider, .Button)
	hovered := result.under_pointer

	// Keyboard adjustment (5% per arrow press).
	if result.focused {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch key.code {
			case display.KEY_LEFT:
				if orientation == .Horizontal {
					ratio^ = clamp(ratio^ - 500, SPLIT_RATIO_MIN, SPLIT_RATIO_MAX)
					key.taken = true
				}
			case display.KEY_RIGHT:
				if orientation == .Horizontal {
					ratio^ = clamp(ratio^ + 500, SPLIT_RATIO_MIN, SPLIT_RATIO_MAX)
					key.taken = true
				}
			case display.KEY_UP:
				if orientation == .Vertical {
					ratio^ = clamp(ratio^ - 500, SPLIT_RATIO_MIN, SPLIT_RATIO_MAX)
					key.taken = true
				}
			case display.KEY_DOWN:
				if orientation == .Vertical {
					ratio^ = clamp(ratio^ + 500, SPLIT_RATIO_MIN, SPLIT_RATIO_MAX)
					key.taken = true
				}
			case display.KEY_HOME:
				ratio^ = SPLIT_RATIO_DEFAULT
				key.taken = true
			}
		}
	}

	pos := orientation == .Horizontal ? frame.input.pointer_x : frame.input.pointer_y
	if hovered && frame.input.pressed {
		// Double-click resets split to 50/50.
		if frame.time > 0 && state.last_click_ms > 0 && frame.time - state.last_click_ms <= 360 {
			ratio^ = SPLIT_RATIO_DEFAULT
			state.dragging = false
			state.last_click_ms = 0
		} else {
			state.dragging = true
			state.start_pointer = pos
			state.start_ratio = ratio^
			state.last_click_ms = frame.time
		}
	}
	if state.dragging {
		if !frame.input.button_held {
			state.dragging = false
		} else if room > 0 {
			delta := pos - state.start_pointer
			moved := i64(state.start_ratio) + i64(delta) * SPLIT_RATIO_WHOLE / i64(room)
			ratio^ = i32(clamp(moved, i64(SPLIT_RATIO_MIN), i64(SPLIT_RATIO_MAX)))
		}
	}

	table := frame.table
	theme := theme_current(frame)
	el := u32(element)
	active := state.dragging || hovered || result.focused
	bg := state.dragging ? theme.chosen : (hovered ? theme.track : theme.card_bottom)
	draw_rectangle(table, divider.x, divider.y, divider.width, divider.height, bg, el)

	// Center hairline + 3 machined grip dots.
	dot_col := state.dragging ? theme.text_on_chosen : (active ? theme.accent : theme.border_strong)
	if orientation == .Horizontal {
		cx := divider.x + divider.width / 2
		cy := divider.y + divider.height / 2
		draw_rectangle(table, cx, divider.y, 1, divider.height, active ? theme.accent : theme.divider, el)
		for offset in ([3]int{-8, 0, 8}) {
			draw_rectangle(table, cx - 1, cy + offset - 1, 3, 2, dot_col, el)
		}
	} else {
		cx := divider.x + divider.width / 2
		cy := divider.y + divider.height / 2
		draw_rectangle(table, divider.x, cy, divider.width, 1, active ? theme.accent : theme.divider, el)
		for offset in ([3]int{-8, 0, 8}) {
			draw_rectangle(table, cx + offset - 1, cy - 1, 2, 3, dot_col, el)
		}
	}
	result.changed = ratio^ != before
	if result.focused {
		draw_focus_ring(table, divider, el)
	}
	return
}

// data_table renders a reusable interactive table with clickable sortable
// column headers, draggable column-width dividers, single or multi-row
// selection (Ctrl+Click toggles, Shift+Click extends range), keyboard
// navigation, and an integrated vertical scroll bar.
// cells_flat holds row_count * len(columns) strings in row-major order.
data_table :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	columns: []Data_Table_Column,
	col_widths: []int,
	row_count: int,
	cells_flat: []string,
	selected_rows: []bool,
	state: ^Data_Table_State,
	multi_select := true,
) -> (result: Data_Table_Result) {
	result.activated_row = -1
	col_n := min(len(columns), min(len(col_widths), DATA_TABLE_MAX_COLUMNS))
	if frame == nil || state == nil || col_n <= 0 || area.width <= 0 || area.height <= DATA_TABLE_HEADER_HEIGHT {
		return
	}
	if !state.resize_init_done {
		state.resizing_col = -1
		state.resize_init_done = true
	}

	table := frame.table
	theme := theme_current(frame)
	el := u32(element)
	body_h := max(area.height - DATA_TABLE_HEADER_HEIGHT - 2, 0)
	visible_rows := max(body_h / DATA_TABLE_ROW_HEIGHT, 1)
	needs_scroll := row_count > visible_rows
	sb_w := needs_scroll ? SCROLL_BAR_THICKNESS : 0
	content_w := max(area.width - 2 - sb_w, 0)

	if row_count > 0 {
		state.active_row = clamp(state.active_row, 0, row_count - 1)
		state.anchor_row = clamp(state.anchor_row, 0, row_count - 1)
	} else {
		state.active_row = 0
		state.anchor_row = 0
	}
	max_scroll := max(row_count - visible_rows, 0)
	state.scroll_row = clamp(state.scroll_row, 0, max_scroll)

	// Outer frame.
	draw_rectangle(table, area.x, area.y, area.width, area.height, theme.recess, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, theme.border, el)

	// Column resize dragging (continuing an active drag).
	if state.resizing_col >= 0 && state.resizing_col < col_n {
		if !frame.input.button_held {
			state.resizing_col = -1
		} else {
			min_w := max(columns[state.resizing_col].min_width, DATA_TABLE_MIN_COL_WIDTH)
			new_w := clamp(state.resize_start_w + (frame.input.pointer_x - state.resize_start_x), min_w, max(content_w - 32, min_w))
			if new_w != col_widths[state.resizing_col] {
				col_widths[state.resizing_col] = new_w
				result.width_changed = true
			}
		}
	}

	// Draw header strip and handle column sort clicks / resize divider grabs.
	header_area := Area{area.x + 1, area.y + 1, content_w, DATA_TABLE_HEADER_HEIGHT}
	draw_vertical_gradient(table, header_area.x, header_area.y, header_area.width, header_area.height, theme.card_top, theme.card_bottom, el)
	draw_rectangle(table, header_area.x, header_area.y + header_area.height - 1, header_area.width, 1, theme.divider, el)

	col_x: [DATA_TABLE_MAX_COLUMNS]int
	col_w: [DATA_TABLE_MAX_COLUMNS]int
	cx := header_area.x
	for c in 0 ..< col_n {
		w := max(col_widths[c], max(columns[c].min_width, DATA_TABLE_MIN_COL_WIDTH))
		if c == col_n - 1 && cx + w < header_area.x + content_w {
			w = header_area.x + content_w - cx
		}
		col_x[c] = cx
		col_w[c] = w
		cx += w
	}

	draw_clip_push(table, header_area.x, header_area.y, header_area.width, header_area.height)
	for c in 0 ..< col_n {
		cell := Area{col_x[c], header_area.y, col_w[c], header_area.height}
		div_area := Area{cell.x + cell.width - DATA_TABLE_RESIZE_HIT / 2, header_area.y, DATA_TABLE_RESIZE_HIT, header_area.height}
		div_hot := c < col_n - 1 && frame.input.pointer_known && area_contains(div_area, frame.input.pointer_x, frame.input.pointer_y)
		if div_hot && frame.input.pressed {
			state.resizing_col = c
			state.resize_start_x = frame.input.pointer_x
			state.resize_start_w = col_widths[c]
			frame.input.pressed = false
		}
		col_hot := !div_hot && state.resizing_col < 0 && columns[c].sortable && frame.input.pointer_known && area_contains(cell, frame.input.pointer_x, frame.input.pointer_y)
		if col_hot && frame.input.pressed {
			if state.sort_column == c {
				switch state.sort_order {
				case .None:
					state.sort_order = .Ascending
				case .Ascending:
					state.sort_order = .Descending
				case .Descending:
					state.sort_order = .Ascending
				}
			} else {
				state.sort_column = c
				state.sort_order = .Ascending
			}
			result.sort_changed = true
			frame.input.pressed = false
		}
		if col_hot {
			draw_rectangle(table, cell.x, cell.y, cell.width, cell.height - 1, theme.track, el)
		}
		sorted_here := state.sort_column == c && state.sort_order != .None
		sort_room := sorted_here ? 14 : 0
		shown := text_fit(table, FONT_INTERFACE_BOLD, columns[c].title, max(cell.width - 12 - sort_room, 0))
		title_col := sorted_here ? theme.accent : (col_hot ? theme.text_strong : theme.text_dim)
		draw_text(table, cell.x + 6, cell.y + (cell.height - LINE) / 2, shown, title_col, FONT_INTERFACE_BOLD, el)
		if sorted_here {
			mark_x := cell.x + cell.width - 12
			mark_y := cell.y + cell.height / 2
			if state.sort_order == .Ascending {
				draw_line(table, mark_x - 3, mark_y + 2, mark_x, mark_y - 2, 1, theme.accent, el)
				draw_line(table, mark_x, mark_y - 2, mark_x + 3, mark_y + 2, 1, theme.accent, el)
			} else {
				draw_line(table, mark_x - 3, mark_y - 2, mark_x, mark_y + 2, 1, theme.accent, el)
				draw_line(table, mark_x, mark_y + 2, mark_x + 3, mark_y - 2, 1, theme.accent, el)
			}
		}
		if c < col_n - 1 {
			draw_rectangle(table, cell.x + cell.width - 1, cell.y + 4, 1, cell.height - 8, (div_hot || state.resizing_col == c) ? theme.accent : theme.divider, el)
		}
	}
	draw_clip_pop(table)

	// Body area interaction & keyboard navigation.
	body_area := Area{area.x + 1, header_area.y + header_area.height, content_w, body_h}
	interact := element_interact(frame, element, body_area, .List)
	if interact.under_pointer && frame.input.wheel != 0 && max_scroll > 0 {
		state.scroll_row = clamp(state.scroll_row + (frame.input.wheel > 0 ? 1 : -1), 0, max_scroll)
		frame.input.wheel = 0
	}
	if interact.focused && row_count > 0 {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			prev := state.active_row
			switch key.code {
			case display.KEY_UP:
				state.active_row = max(state.active_row - 1, 0)
				key.taken = true
			case display.KEY_DOWN:
				state.active_row = min(state.active_row + 1, row_count - 1)
				key.taken = true
			case display.KEY_HOME:
				state.active_row = 0
				key.taken = true
			case display.KEY_END:
				state.active_row = row_count - 1
				key.taken = true
			case display.KEY_ENTER:
				result.activated_row = state.active_row
				key.taken = true
			case display.KEY_SPACE:
				if multi_select && state.active_row < len(selected_rows) {
					selected_rows[state.active_row] = !selected_rows[state.active_row]
					result.selection_changed = true
					key.taken = true
				}
			}
			if state.active_row != prev {
				if state.active_row < state.scroll_row {
					state.scroll_row = state.active_row
				} else if state.active_row >= state.scroll_row + visible_rows {
					state.scroll_row = state.active_row - visible_rows + 1
				}
				if len(selected_rows) > 0 && key.modifiers & display.MODIFIER_CONTROL == 0 {
					for i in 0 ..< min(row_count, len(selected_rows)) {
						selected_rows[i] = false
					}
					if multi_select && key.modifiers & display.MODIFIER_SHIFT != 0 {
						lo := min(state.anchor_row, state.active_row)
						hi := max(state.anchor_row, state.active_row)
						for i in lo ..= min(hi, len(selected_rows) - 1) {
							selected_rows[i] = true
						}
					} else if state.active_row < len(selected_rows) {
						selected_rows[state.active_row] = true
						state.anchor_row = state.active_row
					}
					result.selection_changed = true
				}
			}
		}
	}

	// Render visible rows clipped to body_area.
	draw_clip_push(table, body_area.x, body_area.y, body_area.width, body_area.height)
	for r in 0 ..< visible_rows + 1 {
		row_idx := state.scroll_row + r
		if row_idx >= row_count {
			break
		}
		ry := body_area.y + r * DATA_TABLE_ROW_HEIGHT
		row_area := Area{body_area.x, ry, body_area.width, DATA_TABLE_ROW_HEIGHT}
		row_hot := frame.input.pointer_known && area_contains(body_area, frame.input.pointer_x, frame.input.pointer_y) && area_contains(row_area, frame.input.pointer_x, frame.input.pointer_y)
		if row_hot && frame.input.pressed {
			state.active_row = row_idx
			if len(selected_rows) > 0 && row_idx < len(selected_rows) {
				if multi_select {
					selected_rows[row_idx] = !selected_rows[row_idx]
					state.anchor_row = row_idx
				} else {
					for i in 0 ..< min(row_count, len(selected_rows)) {
						selected_rows[i] = false
					}
					selected_rows[row_idx] = true
					state.anchor_row = row_idx
				}
				result.selection_changed = true
			}
		}
		is_sel := row_idx < len(selected_rows) && selected_rows[row_idx]
		is_active := row_idx == state.active_row
		if is_sel {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.chosen, el)
		} else if row_hot {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.track, el)
		} else if row_idx % 2 == 1 {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.card_bottom, el)
		}
		if is_active && interact.focused {
			draw_rectangle(table, row_area.x, row_area.y + 2, 3, row_area.height - 4, is_sel ? theme.text_on_chosen : theme.accent, el)
		}
		text_col := is_sel ? theme.text_on_chosen : (row_hot ? theme.text_strong : theme.text)
		for c in 0 ..< col_n {
			cell_idx := row_idx * len(columns) + c
			if cell_idx >= len(cells_flat) {
				break
			}
			val := cells_flat[cell_idx]
			cell_box := Area{col_x[c] + 6, ry, max(col_w[c] - 12, 0), DATA_TABLE_ROW_HEIGHT}
			shown := text_fit(table, {}, val, cell_box.width)
			ty := ry + (DATA_TABLE_ROW_HEIGHT - LINE) / 2
			switch columns[c].alignment {
			case .Left:
				draw_text(table, cell_box.x, ty, shown, text_col, {}, el)
			case .Right:
				draw_text_right(table, cell_box.x + cell_box.width, ty, shown, text_col, {}, el)
			}
		}
	}
	draw_clip_pop(table)

	if needs_scroll {
		sb_area := Area{area.x + area.width - 1 - sb_w, body_area.y, sb_w, body_area.height}
		sb := scroll_bar(frame, sb_area, identity_in(element, "scroll"), .Vertical, {total = row_count, visible = visible_rows, first = state.scroll_row})
		if sb.changed {
			state.scroll_row = clamp(sb.first, 0, max_scroll)
		}
	}
	if interact.focused {
		draw_focus_ring(table, area, el)
	}
	return result
}

// tree_view renders a hierarchical expandable tree over caller-owned flat
// visible rows with indent guide rails, clickable chevrons, and Left/Right/Up/
// Down keyboard navigation.
tree_view :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	rows: []Tree_Row,
	state: ^Tree_View_State,
) -> (result: Tree_View_Result) {
	result.toggle_index = -1
	result.activated_index = -1
	if frame == nil || state == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	table := frame.table
	theme := theme_current(frame)
	el := u32(element)
	n := len(rows)

	inner_h := max(area.height - 2, 0)
	visible_rows := max(inner_h / TREE_ROW_HEIGHT, 1)
	needs_scroll := n > visible_rows
	sb_w := needs_scroll ? SCROLL_BAR_THICKNESS : 0
	content_w := max(area.width - 2 - sb_w, 0)
	max_scroll := max(n - visible_rows, 0)
	state.scroll_row = clamp(state.scroll_row, 0, max_scroll)
	if n > 0 {
		state.selected = clamp(state.selected, 0, n - 1)
	} else {
		state.selected = 0
	}

	draw_rectangle(table, area.x, area.y, area.width, area.height, theme.recess, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, theme.border, el)

	body := Area{area.x + 1, area.y + 1, content_w, inner_h}
	interact := element_interact(frame, element, body, .List)
	if interact.under_pointer && frame.input.wheel != 0 && max_scroll > 0 {
		state.scroll_row = clamp(state.scroll_row + (frame.input.wheel > 0 ? 1 : -1), 0, max_scroll)
		frame.input.wheel = 0
	}

	if interact.focused && n > 0 {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			prev := state.selected
			switch key.code {
			case display.KEY_UP:
				state.selected = max(state.selected - 1, 0)
				key.taken = true
			case display.KEY_DOWN:
				state.selected = min(state.selected + 1, n - 1)
				key.taken = true
			case display.KEY_HOME:
				state.selected = 0
				key.taken = true
			case display.KEY_END:
				state.selected = n - 1
				key.taken = true
			case display.KEY_RIGHT:
				cur := rows[state.selected]
				if cur.has_children && !cur.expanded {
					result.toggle_index = state.selected
				} else if cur.has_children && state.selected + 1 < n && rows[state.selected + 1].depth > cur.depth {
					state.selected += 1
				}
				key.taken = true
			case display.KEY_LEFT:
				cur := rows[state.selected]
				if cur.has_children && cur.expanded {
					result.toggle_index = state.selected
				} else if cur.depth > 0 {
					for p := state.selected - 1; p >= 0; p -= 1 {
						if rows[p].depth < cur.depth {
							state.selected = p
							break
						}
					}
				}
				key.taken = true
			case display.KEY_ENTER, display.KEY_SPACE:
				if rows[state.selected].has_children {
					result.toggle_index = state.selected
				} else {
					result.activated_index = state.selected
				}
				key.taken = true
			}
			if state.selected != prev {
				result.selection_changed = true
				if state.selected < state.scroll_row {
					state.scroll_row = state.selected
				} else if state.selected >= state.scroll_row + visible_rows {
					state.scroll_row = state.selected - visible_rows + 1
				}
			}
		}
	}

	draw_clip_push(table, body.x, body.y, body.width, body.height)
	for r in 0 ..< visible_rows + 1 {
		idx := state.scroll_row + r
		if idx >= n {
			break
		}
		row := rows[idx]
		ry := body.y + r * TREE_ROW_HEIGHT
		row_area := Area{body.x, ry, body.width, TREE_ROW_HEIGHT}
		row_hot := frame.input.pointer_known && area_contains(body, frame.input.pointer_x, frame.input.pointer_y) && area_contains(row_area, frame.input.pointer_x, frame.input.pointer_y)
		indent_x := body.x + 8 + max(row.depth, 0) * TREE_INDENT_PX
		chev_area := Area{indent_x - 2, ry, 18, TREE_ROW_HEIGHT}

		if row_hot && frame.input.pressed {
			if state.selected != idx {
				state.selected = idx
				result.selection_changed = true
			}
			if row.has_children && area_contains(chev_area, frame.input.pointer_x, frame.input.pointer_y) {
				result.toggle_index = idx
			} else if row.has_children {
				result.toggle_index = idx
			} else {
				result.activated_index = idx
			}
		}

		is_sel := idx == state.selected
		if is_sel {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.chosen, el)
		} else if row_hot {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.track, el)
		}

		// Vertical indent guide lines.
		for d in 0 ..< max(row.depth, 0) {
			gx := body.x + 14 + d * TREE_INDENT_PX
			draw_rectangle(table, gx, ry, 1, TREE_ROW_HEIGHT, is_sel ? graphics.shade(theme.chosen, 130) : theme.divider, el)
		}

		if row.has_children {
			cx := indent_x + 6
			cy := ry + TREE_ROW_HEIGHT / 2
			cc := is_sel ? theme.text_on_chosen : theme.accent
			if row.expanded {
				draw_line(table, cx - 3, cy - 2, cx, cy + 2, 1, cc, el)
				draw_line(table, cx, cy + 2, cx + 3, cy - 2, 1, cc, el)
			} else {
				draw_line(table, cx - 2, cy - 3, cx + 2, cy, 1, cc, el)
				draw_line(table, cx + 2, cy, cx - 2, cy + 3, 1, cc, el)
			}
		}

		detail_room := 0
		if row.detail != "" {
			detail_room = text_measured_width(table, FONT_CAPTION, row.detail) + 10
			draw_text_right(table, body.x + body.width - 8, ry + (TREE_ROW_HEIGHT - LINE) / 2 + 1, row.detail, is_sel ? theme.text_on_chosen : theme.text_dim, FONT_CAPTION, el)
		}
		label_x := indent_x + 18
		font := row.has_children ? FONT_INTERFACE_BOLD : FONT_INTERFACE
		shown := text_fit(table, font, row.label, max(body.x + body.width - label_x - detail_room - 6, 0))
		col := is_sel ? theme.text_on_chosen : (row_hot ? theme.text_strong : theme.text)
		draw_text(table, label_x, ry + (TREE_ROW_HEIGHT - LINE) / 2, shown, col, font, el)
	}
	draw_clip_pop(table)

	if needs_scroll {
		sb_area := Area{area.x + area.width - 1 - sb_w, body.y, sb_w, body.height}
		sb := scroll_bar(frame, sb_area, identity_in(element, "scroll"), .Vertical, {total = n, visible = visible_rows, first = state.scroll_row})
		if sb.changed {
			state.scroll_row = clamp(sb.first, 0, max_scroll)
		}
	}
	if interact.focused {
		draw_focus_ring(table, area, el)
	}
	return result
}

// text_area draws a reusable multi-line text input backed by caller-owned buf
// and count^ with optional line-number gutter, caret movement, Enter newline,
// Backspace/Delete, and vertical scroll bar.
text_area :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	buf: []u8,
	count: ^int,
	state: ^Text_Area_State,
	placeholder := "",
	line_numbers := true,
) -> (result: Element_Result) {
	if frame == nil || count == nil || state == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	count^ = clamp(count^, 0, len(buf))
	state.caret = clamp(state.caret, 0, count^)
	result = element_interact(frame, element, area, .Text_Input)
	table := frame.table
	theme := theme_current(frame)
	el := u32(element)

	// Split buffer into lines (bounded inline array; typical text_area holds < 256 lines).
	TEXT_AREA_MAX_LINES :: 256
	Line_Span :: struct {
		start, end: int,
	}
	lines: [TEXT_AREA_MAX_LINES]Line_Span
	line_count := 0
	rebuild_lines :: proc "contextless" (buf: []u8, n: int, out: []Line_Span) -> int {
		cnt := 0
		s := 0
		for i := 0; i < n && cnt < len(out); i += 1 {
			if buf[i] == '\n' {
				out[cnt] = {s, i}
				cnt += 1
				s = i + 1
			}
		}
		if cnt < len(out) {
			out[cnt] = {s, n}
			cnt += 1
		}
		return max(cnt, 1)
	}

	if result.focused {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch key.code {
			case display.KEY_LEFT:
				if state.caret > 0 {
					state.caret -= 1
				}
				key.taken = true
			case display.KEY_RIGHT:
				if state.caret < count^ {
					state.caret += 1
				}
				key.taken = true
			case display.KEY_UP, display.KEY_DOWN:
				line_count = rebuild_lines(buf, count^, lines[:])
				cur_ln := 0
				cur_col := 0
				for li in 0 ..< line_count {
					if state.caret >= lines[li].start && state.caret <= lines[li].end {
						cur_ln = li
						cur_col = state.caret - lines[li].start
						break
					}
				}
				target_ln := key.code == display.KEY_UP ? max(cur_ln - 1, 0) : min(cur_ln + 1, line_count - 1)
				state.caret = min(lines[target_ln].start + cur_col, lines[target_ln].end)
				key.taken = true
			case display.KEY_HOME:
				for state.caret > 0 && buf[state.caret - 1] != '\n' {
					state.caret -= 1
				}
				key.taken = true
			case display.KEY_END:
				for state.caret < count^ && buf[state.caret] != '\n' {
					state.caret += 1
				}
				key.taken = true
			case display.KEY_BACKSPACE:
				if state.caret > 0 && count^ > 0 {
					for j := state.caret - 1; j < count^ - 1; j += 1 {
						buf[j] = buf[j + 1]
					}
					count^ -= 1
					state.caret -= 1
					result.changed = true
				}
				key.taken = true
			case display.KEY_DELETE:
				if state.caret < count^ {
					for j := state.caret; j < count^ - 1; j += 1 {
						buf[j] = buf[j + 1]
					}
					count^ -= 1
					result.changed = true
				}
				key.taken = true
			case display.KEY_ENTER:
				if count^ < len(buf) {
					for j := count^; j > state.caret; j -= 1 {
						buf[j] = buf[j - 1]
					}
					buf[state.caret] = '\n'
					count^ += 1
					state.caret += 1
					result.changed = true
				}
				key.taken = true
			case:
				if key.character >= 0x20 && key.character < 0x7F && count^ < len(buf) {
					for j := count^; j > state.caret; j -= 1 {
						buf[j] = buf[j - 1]
					}
					buf[state.caret] = u8(key.character)
					count^ += 1
					state.caret += 1
					result.changed = true
					key.taken = true
				}
			}
		}
		// Clipboard copy of whole buffer.
		if frame.input.copy_asked && !frame.copy_given && count^ > 0 {
			frame.copied = buf[:count^]
			frame.copy_given = true
		}
	}

	line_count = rebuild_lines(buf, count^, lines[:])
	gutter_w := line_numbers ? 32 : 0
	line_h := LINE + 4
	inner_h := max(area.height - 8, line_h)
	visible_lines := max(inner_h / line_h, 1)
	needs_scroll := line_count > visible_lines
	sb_w := needs_scroll ? SCROLL_BAR_THICKNESS : 0
	max_scroll := max(line_count - visible_lines, 0)
	if result.under_pointer && frame.input.wheel != 0 && max_scroll > 0 {
		state.scroll_row = clamp(state.scroll_row + (frame.input.wheel > 0 ? 1 : -1), 0, max_scroll)
		frame.input.wheel = 0
	}
	state.scroll_row = clamp(state.scroll_row, 0, max_scroll)

	// Draw container.
	draw_rectangle(table, area.x, area.y, area.width, area.height, theme.recess, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, result.focused ? theme.accent : (result.under_pointer ? theme.border_strong : theme.border), el)
	if line_numbers {
		draw_rectangle(table, area.x + 1, area.y + 1, gutter_w, max(area.height - 2, 0), theme.card_bottom, el)
		draw_rectangle(table, area.x + 1 + gutter_w, area.y + 1, 1, max(area.height - 2, 0), theme.divider, el)
	}

	text_x := area.x + gutter_w + 8
	text_w := max(area.width - gutter_w - sb_w - 14, 0)
	draw_clip_push(table, area.x + 1, area.y + 1, max(area.width - 2 - sb_w, 0), max(area.height - 2, 0))
	if count^ == 0 && placeholder != "" && !result.focused {
		draw_text(table, text_x, area.y + 6, text_fit(table, FONT_INTERFACE, placeholder, text_w), theme.text_dim, FONT_INTERFACE, el)
	} else {
		for r in 0 ..< visible_lines + 1 {
			li := state.scroll_row + r
			if li >= line_count {
				break
			}
			ry := area.y + 4 + r * line_h
			if line_numbers {
				nb: Text_Builder
				text_put_number(&nb, u64(li + 1))
				draw_text_right(table, area.x + gutter_w - 4, ry + 2, text_of(&nb), theme.text_dim, {}, el)
			}
			span := lines[li]
			line_str := string(buf[span.start:span.end])
			draw_text(table, text_x, ry + 2, text_fit(table, {}, line_str, text_w), theme.text_strong, {}, el)
			// Caret beam when focused.
			if result.focused && state.caret >= span.start && state.caret <= span.end {
				prefix := string(buf[span.start:state.caret])
				cx := text_x + text_measured_width(table, {}, prefix)
				draw_rectangle(table, cx, ry + 1, 2, LINE + 2, theme.accent, el)
			}
			// Click places caret on this line.
			if frame.input.pressed && frame.input.pointer_known && area_contains({text_x - 4, ry, text_w + 8, line_h}, frame.input.pointer_x, frame.input.pointer_y) {
				rel_x := max(frame.input.pointer_x - text_x, 0)
				char_w := max(text_measured_width(table, {}, "M"), 8)
				col := clamp((rel_x + char_w / 2) / char_w, 0, span.end - span.start)
				state.caret = span.start + col
			}
		}
	}
	draw_clip_pop(table)

	if needs_scroll {
		sb_area := Area{area.x + area.width - 1 - sb_w, area.y + 1, sb_w, max(area.height - 2, 0)}
		sb := scroll_bar(frame, sb_area, identity_in(element, "scroll"), .Vertical, {total = line_count, visible = visible_lines, first = state.scroll_row})
		if sb.changed {
			state.scroll_row = clamp(sb.first, 0, max_scroll)
		}
	}
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return result
}

// tooltip_draw renders a floating tooltip clamped strictly inside [4, win_w-4]
// x [4, win_h-4], placed below anchor (or above when near the window bottom).
tooltip_draw :: proc "contextless" (frame: ^Frame, anchor: Area, text: string, win_w, win_h: int) {
	if frame == nil || text == "" {
		return
	}
	table := frame.table
	theme := theme_current(frame)
	tw := text_measured_width(table, FONT_CAPTION, text)
	w := min(tw + 16, max(win_w - 8, 40))
	h := 22
	x := anchor.x + (anchor.width - w) / 2
	if win_w > 0 {
		x = clamp(x, 4, max(win_w - 4 - w, 4))
	}
	y := anchor.y + anchor.height + 6
	if win_h > 0 && y + h > win_h - 4 {
		y = max(anchor.y - h - 6, 4)
	}
	el := u32(identity("tooltip"))
	draw_rectangle_with_alpha(table, x + 2, y + 2, w, h, draw_record.with_alpha(graphics.COLOR_BLACK, 120), el)
	draw_rectangle(table, x, y, w, h, theme.card_top, el)
	draw_outline(table, x, y, w, h, 1, theme.accent, el)
	draw_text(table, x + 8, y + 3, text_fit(table, FONT_CAPTION, text, max(w - 16, 0)), theme.text_strong, FONT_CAPTION, el)
}

// modal_dialog draws a dimmed scrim and a centered machined dialog card with a
// title, body text, and Cancel / Confirm buttons. Consumes background pointer
// and Escape events while open^ is true.
modal_dialog :: proc "contextless" (
	frame: ^Frame,
	win_w, win_h: int,
	element: Element_Identity,
	open: ^bool,
	title: string,
	body: string,
	confirm_label := "Confirm",
	cancel_label := "Cancel",
	danger := false,
) -> (result: Modal_Dialog_Result) {
	if frame == nil || open == nil || !open^ || win_w <= 0 || win_h <= 0 {
		return
	}
	table := frame.table
	theme := theme_current(frame)
	el := u32(element)

	card_w := clamp(win_w - 80, 280, 440)
	card_h := 168
	card_area := Area{(win_w - card_w) / 2, (win_h - card_h) / 2, card_w, card_h}

	// Keyboard Escape closes modal immediately.
	for &key in frame.input.keys[:frame.input.key_count] {
		if !key.taken && key.code == display.KEY_ESCAPE {
			open^ = false
			result.closed = true
			key.taken = true
			return
		}
	}

	// Translucent dark scrim across full window.
	draw_rectangle_with_alpha(table, 0, 0, win_w, win_h, draw_record.with_alpha(graphics.COLOR_BLACK, 150), el)

	// Click outside dialog closes modal.
	if frame.input.pressed && frame.input.pointer_known && !area_contains(card_area, frame.input.pointer_x, frame.input.pointer_y) {
		open^ = false
		result.closed = true
		frame.input.pressed = false
		return
	}

	// Dialog card with sharp shadow.
	draw_rectangle_with_alpha(table, card_area.x + 4, card_area.y + 4, card_area.width, card_area.height, draw_record.with_alpha(graphics.COLOR_BLACK, 140), el)
	draw_vertical_gradient(table, card_area.x, card_area.y, card_area.width, card_area.height, theme.card_top, theme.card_bottom, el)
	draw_outline(table, card_area.x, card_area.y, card_area.width, card_area.height, 1, danger ? theme.danger : theme.accent, el)

	// Header strip + close "x".
	draw_rectangle(table, card_area.x + 1, card_area.y + 1, card_area.width - 2, 34, theme.recess, el)
	draw_rectangle(table, card_area.x + 1, card_area.y + 35, card_area.width - 2, 1, theme.divider, el)
	draw_text(table, card_area.x + 14, card_area.y + 10, text_fit(table, FONT_INTERFACE_BOLD, title, max(card_area.width - 56, 0)), danger ? theme.danger : theme.accent, FONT_INTERFACE_BOLD, el)

	close_box := Area{card_area.x + card_area.width - 30, card_area.y + 6, 22, 22}
	if button_styled(frame, close_box, identity_in(element, "close"), "x", .Ghost).activated {
		open^ = false
		result.closed = true
	}

	// Body text wrapped in two simple lines when needed.
	body_w := max(card_area.width - 28, 40)
	line1 := text_fit(table, FONT_INTERFACE, body, body_w)
	draw_text(table, card_area.x + 14, card_area.y + 50, line1, theme.text, FONT_INTERFACE, el)
	if len(line1) < len(body) {
		rest := body[len(line1):]
		for len(rest) > 0 && rest[0] == ' ' {
			rest = rest[1:]
		}
		draw_text(table, card_area.x + 14, card_area.y + 72, text_fit(table, FONT_INTERFACE, rest, body_w), theme.text, FONT_INTERFACE, el)
	}

	// Footer action buttons.
	draw_rectangle(table, card_area.x + 1, card_area.y + card_area.height - 46, card_area.width - 2, 1, theme.divider, el)
	btn_y := card_area.y + card_area.height - 36
	confirm_w := max(text_measured_width(table, FONT_INTERFACE_BOLD, confirm_label) + 24, 88)
	cancel_w := max(text_measured_width(table, FONT_INTERFACE, cancel_label) + 24, 80)
	confirm_box := Area{card_area.x + card_area.width - 14 - confirm_w, btn_y, confirm_w, 26}
	cancel_box := Area{confirm_box.x - 8 - cancel_w, btn_y, cancel_w, 26}

	if button_styled(frame, cancel_box, identity_in(element, "cancel"), cancel_label, .Secondary).activated {
		open^ = false
		result.cancelled = true
	}
	if button_styled(frame, confirm_box, identity_in(element, "confirm"), confirm_label, danger ? .Danger : .Primary).activated {
		open^ = false
		result.confirmed = true
	}
	return result
}
