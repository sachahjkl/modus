// Responsive split-pane layout solver and hit-testing for store_explorer
// built on modus:layout (src/md/features/store_explorer.md).
package store_explorer_core

import box_layout "modus:layout"

// Plan values: default, minimum, and maximum logical window dimensions.
DEFAULT_WIDTH :: 1080
DEFAULT_HEIGHT :: 700
LEAST_WIDTH :: 720
LEAST_HEIGHT :: 440
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 960

// Plan values: minimum pane dimensions that guarantee zero overlap or cut text.
SIDEBAR_MIN_WIDTH :: 224
RIGHT_MIN_WIDTH :: 400
LIST_MIN_HEIGHT :: 160
INSPECTOR_MIN_HEIGHT :: 160
DIVIDER_THICKNESS :: 4

// Plan values: chrome heights matching modus:interface defaults.
PANE_HEADING_HEIGHT :: 28
PANE_ROW_HEIGHT :: 24
HEADER_BAR_HEIGHT :: 26
STATUS_HEIGHT :: 24
ACTION_BAR_HEIGHT :: 24
SCROLL_BAR_THICKNESS :: 17
PANE_PADDING :: 8

#assert(LEAST_WIDTH >= SIDEBAR_MIN_WIDTH + DIVIDER_THICKNESS + RIGHT_MIN_WIDTH)
#assert(LEAST_HEIGHT >= LIST_MIN_HEIGHT + DIVIDER_THICKNESS + INSPECTOR_MIN_HEIGHT + STATUS_HEIGHT + ACTION_BAR_HEIGHT)
#assert(DEFAULT_WIDTH >= LEAST_WIDTH && DEFAULT_WIDTH <= LARGEST_WIDTH)
#assert(DEFAULT_HEIGHT >= LEAST_HEIGHT && DEFAULT_HEIGHT <= LARGEST_HEIGHT)

Split_Ratios :: struct {
	sidebar_ratio: i32,
	list_ratio:    i32,
}

DEFAULT_SPLIT_RATIOS :: Split_Ratios {
	sidebar_ratio = 2300,
	list_ratio    = 4800,
}

Window_Layout :: struct {
	content:          box_layout.Rect,
	sidebar:          box_layout.Rect,
	sidebar_stores:   box_layout.Rect,
	sidebar_path:     box_layout.Rect,
	sidebar_divider:  box_layout.Rect,
	right_column:     box_layout.Rect,
	list_pane:        box_layout.Rect,
	list_header:      box_layout.Rect,
	list_body:        box_layout.Rect,
	list_scroll:      box_layout.Rect,
	middle_divider:   box_layout.Rect,
	inspector_pane:   box_layout.Rect,
	inspector_header: box_layout.Rect,
	inspector_body:   box_layout.Rect,
	inspector_scroll: box_layout.Rect,
	status:           box_layout.Rect,
	status_left:      box_layout.Rect,
	status_right:     box_layout.Rect,
	action_bar:       box_layout.Rect,
}

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

	if box_layout.tree_begin(tree, w, h, {label = "store_explorer", child_axis = .Y}) != .Done {
		return {}, false
	}
	content_idx, c_st := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}})
	if c_st != .Done {
		return {}, false
	}
	status_idx, s_st := box_layout.box_open(tree, {
		size        = {.X = box_layout.fill(), .Y = box_layout.px(STATUS_HEIGHT)},
		child_axis  = .X,
		cross_align = .Center,
		padding     = {.X = status_gap, .Y = 0},
		gap         = 2 * status_gap,
	})
	if s_st != .Done {
		return {}, false
	}
	status_left_idx, sl_st := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(16)}})
	clamped_right := clamp(right_status_width, 0, max(w - 4 * status_gap, 0))
	status_right_idx, sr_st := box_layout.box_add(tree, {
		size       = {.X = box_layout.text_size(), .Y = box_layout.px(16)},
		text_width = clamped_right,
	})
	if sl_st != .Done || sr_st != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}
	action_bar_idx, ab_st := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(ACTION_BAR_HEIGHT)}})
	if ab_st != .Done || box_layout.solve(tree) != .Done {
		return {}, false
	}

	out.content = box_layout.box_of(tree, content_idx).rect
	out.status = box_layout.box_of(tree, status_idx).rect
	out.status_left = box_layout.box_of(tree, status_left_idx).rect
	out.status_right = box_layout.box_of(tree, status_right_idx).rect
	out.action_bar = box_layout.box_of(tree, action_bar_idx).rect

	// Horizontal split: left sidebar | divider | right column.
	sb_ratio := clamp_split_ratio(out.content.width, DIVIDER_THICKNESS, SIDEBAR_MIN_WIDTH, RIGHT_MIN_WIDTH, ratios.sidebar_ratio)
	hsplit, h_st := box_layout.split_pane(out.content, .X, sb_ratio, DIVIDER_THICKNESS)
	if h_st != .Done {
		return {}, false
	}
	out.sidebar = hsplit.first
	out.sidebar_divider = hsplit.divider
	out.right_column = hsplit.second

	// Split sidebar into Stores (top 55%) and Path breadcrumbs (bottom 45%).
	sb_split, sb_st := box_layout.split_pane(out.sidebar, .Y, 5500, 1)
	if sb_st != .Done {
		return {}, false
	}
	out.sidebar_stores = sb_split.first
	out.sidebar_path = sb_split.second

	// Vertical split of right column: Entries list | divider | Object inspector.
	lv_ratio := clamp_split_ratio(out.right_column.height, DIVIDER_THICKNESS, LIST_MIN_HEIGHT, INSPECTOR_MIN_HEIGHT, ratios.list_ratio)
	vsplit, v_st := box_layout.split_pane(out.right_column, .Y, lv_ratio, DIVIDER_THICKNESS)
	if v_st != .Done {
		return {}, false
	}
	out.list_pane = vsplit.first
	out.middle_divider = vsplit.divider
	out.inspector_pane = vsplit.second

	// Entries list sub-rects.
	out.list_header = {out.list_pane.x, out.list_pane.y, out.list_pane.width, HEADER_BAR_HEIGHT}
	lb_y := out.list_pane.y + HEADER_BAR_HEIGHT
	lb_h := max(out.list_pane.height - HEADER_BAR_HEIGHT, 0)
	lb_w := max(out.list_pane.width - SCROLL_BAR_THICKNESS, 0)
	out.list_body = {out.list_pane.x, lb_y, lb_w, lb_h}
	out.list_scroll = {out.list_pane.x + lb_w, lb_y, SCROLL_BAR_THICKNESS, lb_h}

	// Object inspector sub-rects.
	out.inspector_header = {out.inspector_pane.x, out.inspector_pane.y, out.inspector_pane.width, HEADER_BAR_HEIGHT}
	ib_y := out.inspector_pane.y + HEADER_BAR_HEIGHT
	ib_h := max(out.inspector_pane.height - HEADER_BAR_HEIGHT, 0)
	ib_w := max(out.inspector_pane.width - SCROLL_BAR_THICKNESS, 0)
	out.inspector_body = {out.inspector_pane.x, ib_y, ib_w, ib_h}
	out.inspector_scroll = {out.inspector_pane.x + ib_w, ib_y, SCROLL_BAR_THICKNESS, ib_h}

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

hit_test_list_row :: proc "contextless" (body: box_layout.Rect, first_row, total_rows: int, x, y: i32) -> int {
	if !rect_contains(body, x, y) || total_rows <= 0 {
		return -1
	}
	row := first_row + int((y - body.y) / PANE_ROW_HEIGHT)
	if row < 0 || row >= total_rows {
		return -1
	}
	return row
}

hit_test_sidebar_row :: proc "contextless" (area: box_layout.Rect, first_row, total_rows: int, x, y: i32) -> int {
	rows_rect := box_layout.Rect{area.x, area.y + PANE_HEADING_HEIGHT, area.width, max(area.height - PANE_HEADING_HEIGHT, 0)}
	return hit_test_list_row(rows_rect, first_row, total_rows, x, y)
}
