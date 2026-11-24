// Responsive split-pane layout solver and pointer hit-testing for db_browser
// built on modus:layout (src/md/features/db_browser.md).
package db_browser_core

import box_layout "modus:layout"

// Plan values: default, minimum, and maximum logical window dimensions.
// Largest dimensions match db_browser's MODULE_BUDGET window surface size.
DEFAULT_WIDTH :: 1080
DEFAULT_HEIGHT :: 700
LEAST_WIDTH :: 720
LEAST_HEIGHT :: 440
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 960

// Plan values: minimum pane dimensions that guarantee zero overlapping or cut text.
SIDEBAR_MIN_WIDTH :: 224
RIGHT_MIN_WIDTH :: 400
EDITOR_MIN_HEIGHT :: 160
GRID_MIN_HEIGHT :: 160
DIVIDER_THICKNESS :: 4

// Plan values: chrome row and bar heights matching modus:interface defaults.
PANE_HEADING_HEIGHT :: 28
PANE_ROW_HEIGHT :: 24
EDITOR_HEADER_HEIGHT :: 24
GRID_HEADER_HEIGHT :: 28
GRID_ROW_HEIGHT :: 24
STATUS_HEIGHT :: 24
ACTION_BAR_HEIGHT :: 24
SCROLL_BAR_THICKNESS :: 17
PANE_PADDING :: 8

#assert(LEAST_WIDTH >= SIDEBAR_MIN_WIDTH + DIVIDER_THICKNESS + RIGHT_MIN_WIDTH)
#assert(LEAST_HEIGHT >= EDITOR_MIN_HEIGHT + DIVIDER_THICKNESS + GRID_MIN_HEIGHT + STATUS_HEIGHT + ACTION_BAR_HEIGHT)
#assert(DEFAULT_WIDTH >= LEAST_WIDTH && DEFAULT_WIDTH <= LARGEST_WIDTH)
#assert(DEFAULT_HEIGHT >= LEAST_HEIGHT && DEFAULT_HEIGHT <= LARGEST_HEIGHT)

// Split ratios in parts of box_layout.RATIO_WHOLE (10_000).
Split_Ratios :: struct {
	sidebar_ratio: i32,
	editor_ratio:  i32,
}

DEFAULT_SPLIT_RATIOS :: Split_Ratios {
	sidebar_ratio = 2300,
	editor_ratio  = 3400,
}

Window_Layout :: struct {
	content:         box_layout.Rect,
	sidebar:         box_layout.Rect,
	sidebar_tables:  box_layout.Rect,
	sidebar_columns: box_layout.Rect,
	sidebar_divider: box_layout.Rect,
	right_column:    box_layout.Rect,
	editor_pane:     box_layout.Rect,
	editor_header:   box_layout.Rect,
	editor_body:     box_layout.Rect,
	editor_scroll:   box_layout.Rect,
	editor_divider:  box_layout.Rect,
	grid_pane:       box_layout.Rect,
	grid_header:     box_layout.Rect,
	grid_body:       box_layout.Rect,
	grid_vscroll:    box_layout.Rect,
	grid_hscroll:    box_layout.Rect,
	grid_corner:     box_layout.Rect,
	status:          box_layout.Rect,
	status_left:     box_layout.Rect,
	status_right:    box_layout.Rect,
	action_bar:      box_layout.Rect,
}

// clamp_split_ratio clamps a split ratio so neither child falls below its minimum pixels.
clamp_split_ratio :: proc "contextless" (total_length, divider_thickness, first_min, second_min, ratio: i32) -> i32 {
	room := total_length - divider_thickness
	if room <= 0 {
		return box_layout.split_ratio_clamp(ratio)
	}
	min_ratio := i32((i64(first_min) * box_layout.RATIO_WHOLE + i64(room) - 1) / i64(room))
	max_ratio := i32(i64(room - second_min) * box_layout.RATIO_WHOLE / i64(room))
	min_ratio = clamp(min_ratio, box_layout.SPLIT_RATIO_LEAST, box_layout.SPLIT_RATIO_MOST)
	max_ratio = clamp(max_ratio, box_layout.SPLIT_RATIO_LEAST, box_layout.SPLIT_RATIO_MOST)
	if min_ratio > max_ratio {
		return min_ratio
	}
	return clamp(ratio, min_ratio, max_ratio)
}

// compute_layout solves the full db_browser window geometry using modus:layout
// Box_Tree and split_pane. Guarantees non-overlapping, bounded panes at every
// size from LEAST_WIDTH x LEAST_HEIGHT to LARGEST_WIDTH x LARGEST_HEIGHT.
compute_layout :: proc "contextless" (
	tree: ^box_layout.Box_Tree,
	width, height: i32,
	ratios: Split_Ratios,
	right_status_width: i32,
	status_gap: i32 = 8,
) -> (out: Window_Layout, ok: bool) {
	if tree == nil || width < LEAST_WIDTH || height < LEAST_HEIGHT {
		return {}, false
	}
	w := clamp(width, LEAST_WIDTH, box_layout.LENGTH_LIMIT)
	h := clamp(height, LEAST_HEIGHT, box_layout.LENGTH_LIMIT)

	if box_layout.tree_begin(tree, w, h, {label = "db_browser", child_axis = .Y}) != .Done {
		return {}, false
	}
	content_idx, c_status := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}})
	if c_status != .Done {
		return {}, false
	}
	status_idx, s_status := box_layout.box_open(tree, {
		size        = {.X = box_layout.fill(), .Y = box_layout.px(STATUS_HEIGHT)},
		child_axis  = .X,
		cross_align = .Center,
		padding     = {.X = status_gap, .Y = 0},
		gap         = 2 * status_gap,
	})
	if s_status != .Done {
		return {}, false
	}
	status_left_idx, sl_status := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(16)}})
	clamped_right := clamp(right_status_width, 0, max(w - 4 * status_gap, 0))
	status_right_idx, sr_status := box_layout.box_add(tree, {
		size       = {.X = box_layout.text_size(), .Y = box_layout.px(16)},
		text_width = clamped_right,
	})
	if sl_status != .Done || sr_status != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}
	action_bar_idx, ab_status := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(ACTION_BAR_HEIGHT)}})
	if ab_status != .Done {
		return {}, false
	}
	if box_layout.solve(tree) != .Done {
		return {}, false
	}

	out.content = box_layout.box_of(tree, content_idx).rect
	out.status = box_layout.box_of(tree, status_idx).rect
	out.status_left = box_layout.box_of(tree, status_left_idx).rect
	out.status_right = box_layout.box_of(tree, status_right_idx).rect
	out.action_bar = box_layout.box_of(tree, action_bar_idx).rect

	// Horizontal split: left sidebar | divider | right column.
	sb_ratio := clamp_split_ratio(out.content.width, DIVIDER_THICKNESS, SIDEBAR_MIN_WIDTH, RIGHT_MIN_WIDTH, ratios.sidebar_ratio)
	hsplit, h_status := box_layout.split_pane(out.content, .X, sb_ratio, DIVIDER_THICKNESS)
	if h_status != .Done {
		return {}, false
	}
	out.sidebar = hsplit.first
	out.sidebar_divider = hsplit.divider
	out.right_column = hsplit.second

	// Split sidebar vertically into Tables (top 60%) and Columns (bottom 40%).
	sb_split, sb_status := box_layout.split_pane(out.sidebar, .Y, 6000, 1)
	if sb_status != .Done {
		return {}, false
	}
	out.sidebar_tables = sb_split.first
	out.sidebar_columns = sb_split.second

	// Vertical split of right column: SQL editor | divider | Result grid.
	ed_ratio := clamp_split_ratio(out.right_column.height, DIVIDER_THICKNESS, EDITOR_MIN_HEIGHT, GRID_MIN_HEIGHT, ratios.editor_ratio)
	vsplit, v_status := box_layout.split_pane(out.right_column, .Y, ed_ratio, DIVIDER_THICKNESS)
	if v_status != .Done {
		return {}, false
	}
	out.editor_pane = vsplit.first
	out.editor_divider = vsplit.divider
	out.grid_pane = vsplit.second

	// Editor sub-rects: header bar, text body, vertical scrollbar.
	out.editor_header = {out.editor_pane.x, out.editor_pane.y, out.editor_pane.width, EDITOR_HEADER_HEIGHT}
	ed_body_y := out.editor_pane.y + EDITOR_HEADER_HEIGHT
	ed_body_h := max(out.editor_pane.height - EDITOR_HEADER_HEIGHT, 0)
	ed_body_w := max(out.editor_pane.width - SCROLL_BAR_THICKNESS, 0)
	out.editor_body = {out.editor_pane.x, ed_body_y, ed_body_w, ed_body_h}
	out.editor_scroll = {out.editor_pane.x + ed_body_w, ed_body_y, SCROLL_BAR_THICKNESS, ed_body_h}

	// Result grid sub-rects: sticky header, scrollable body, vertical + horizontal scrollbars.
	grid_w := max(out.grid_pane.width - SCROLL_BAR_THICKNESS, 0)
	grid_h_total := max(out.grid_pane.height - SCROLL_BAR_THICKNESS, 0)
	header_h := min(GRID_HEADER_HEIGHT, grid_h_total)
	body_h := max(grid_h_total - header_h, 0)
	out.grid_header = {out.grid_pane.x, out.grid_pane.y, grid_w, header_h}
	out.grid_body = {out.grid_pane.x, out.grid_pane.y + header_h, grid_w, body_h}
	out.grid_vscroll = {out.grid_pane.x + grid_w, out.grid_pane.y + header_h, SCROLL_BAR_THICKNESS, body_h}
	out.grid_hscroll = {out.grid_pane.x, out.grid_pane.y + grid_h_total, grid_w, SCROLL_BAR_THICKNESS}
	out.grid_corner = {out.grid_pane.x + grid_w, out.grid_pane.y + grid_h_total, SCROLL_BAR_THICKNESS, SCROLL_BAR_THICKNESS}

	return out, true
}

rect_contains :: proc "contextless" (r: box_layout.Rect, x, y: i32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

rects_overlap :: proc "contextless" (a, b: box_layout.Rect) -> bool {
	if a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0 {
		return false
	}
	return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
}

// hit_test_grid_header returns the clicked column index, or -1 if outside.
hit_test_grid_header :: proc "contextless" (layout: ^Window_Layout, snap: ^Result_Snapshot, scroll_x: i32, x, y: i32) -> int {
	if layout == nil || snap == nil || !rect_contains(layout.grid_header, x, y) {
		return -1
	}
	local_x := (x - layout.grid_header.x) + max(scroll_x, 0)
	col_x: i32 = 0
	for c in 0 ..< snap.column_count {
		w := snap.column_widths[c]
		if local_x >= col_x && local_x < col_x + w {
			return c
		}
		col_x += w
	}
	return -1
}

// hit_test_sidebar_row returns the clicked row index inside a sidebar list
// (below its PANE_HEADING_HEIGHT heading), or -1 if outside.
hit_test_sidebar_row :: proc "contextless" (area: box_layout.Rect, first_row, total_rows: int, x, y: i32) -> int {
	rows_rect := box_layout.Rect{area.x, area.y + PANE_HEADING_HEIGHT, area.width, max(area.height - PANE_HEADING_HEIGHT, 0)}
	if !rect_contains(rows_rect, x, y) || total_rows <= 0 {
		return -1
	}
	row := first_row + int((y - rows_rect.y) / PANE_ROW_HEIGHT)
	if row < 0 || row >= total_rows {
		return -1
	}
	return row
}
