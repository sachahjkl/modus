package manual

// Pure box-tree layout for the manual window (src/md/features/box_layout.md).
// No system calls: host tests verify bounds, dark/light element tokens, and
// zero overlap across heading heights and window sizes.

import "modus:interface"
import box_layout "modus:layout"

// Minimum window bounds ensuring the module list, filter field, readable text
// column, scroll bar, action bar, and row status all fit without overlap.
MINIMUM_WIDTH :: LIST_WIDTH + MARGIN + 40 * CELL_WIDTH + SCROLL_GAP + SCROLL_WIDTH
MINIMUM_HEIGHT :: 10 * CELL_HEIGHT + 2 * MARGIN + interface.ACTION_BAR_ROW_HEIGHT
#assert(WIDTH >= MINIMUM_WIDTH && HEIGHT >= MINIMUM_HEIGHT)

// Solved rectangles for one frame of the manual window.
Manual_Boxes :: struct {
	root:         interface.Area,
	list_pane:    interface.Area,
	filter_field: interface.Area,
	list_header:  interface.Area,
	list_rows:    interface.Area,
	right_pane:   interface.Area,
	page_row:     interface.Area,
	text_view:    interface.Area,
	heading:      interface.Area,
	text_column:  interface.Area,
	scroll_bar:   interface.Area,
	footer_row:   interface.Area,
	action_bar:   interface.Area,
	row_status:   interface.Area,
}

@(private = "file")
area_of :: proc "contextless" (tree: ^box_layout.Box_Tree, index: box_layout.Box_Index) -> interface.Area {
	rect := tree.boxes[index].rect
	return {int(rect.x), int(rect.y), int(rect.width), int(rect.height)}
}

// manual_layout computes all rectangles of the manual window via modus:layout.
// Refuses nil tree, dimensions below minimums, or negative heading_rows.
manual_layout :: proc "contextless" (
	tree: ^box_layout.Box_Tree,
	width, height: int,
	heading_rows_count: int,
	tokens: box_layout.Element_Tokens,
) -> (boxes: Manual_Boxes, ok: bool) {
	if tree == nil || width < MINIMUM_WIDTH || height < MINIMUM_HEIGHT || heading_rows_count < 0 || width > int(box_layout.LENGTH_LIMIT) || height > int(box_layout.LENGTH_LIMIT) {
		return {}, false
	}
	margin := i32(MARGIN)
	list_gap := max(tokens.gap / 2, i32(4))
	status_margin := max(tokens.margin, margin)
	heading_pixels := i32(heading_rows_count * CELL_HEIGHT)
	max_heading := i32(height - interface.ACTION_BAR_ROW_HEIGHT - MARGIN - CELL_HEIGHT)
	if heading_pixels > max_heading {
		heading_pixels = max(max_heading, 0)
	}

	if box_layout.tree_begin(tree, i32(width), i32(height), {
		child_axis = .X,
	}) != .Done {
		return {}, false
	}

	// Left pane: module filter, exports column heading, and module list rows.
	list_pane, list_status := box_layout.box_open(tree, {
		label      = "list_pane",
		size       = {.X = box_layout.px(LIST_WIDTH), .Y = box_layout.fill()},
		child_axis = .Y,
		padding    = {.X = 6, .Y = list_gap},
		gap        = list_gap,
	})
	if list_status != .Done {
		return {}, false
	}
	filter_field, filter_status := box_layout.box_add(tree, {
		label = "filter_field",
		size  = {.X = box_layout.fill(), .Y = box_layout.px(CELL_HEIGHT + 6)},
	})
	list_header, header_status := box_layout.box_add(tree, {
		label = "list_header",
		size  = {.X = box_layout.fill(), .Y = box_layout.px(CELL_HEIGHT)},
	})
	list_rows, rows_status := box_layout.box_add(tree, {
		label = "list_rows",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	if filter_status != .Done || header_status != .Done || rows_status != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}

	// Right pane: page text + scroll bar above the action bar + row status footer.
	right_pane, right_status := box_layout.box_open(tree, {
		label      = "right_pane",
		size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
		child_axis = .Y,
	})
	if right_status != .Done {
		return {}, false
	}

	page_row, page_status := box_layout.box_open(tree, {
		label      = "page_row",
		size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
		child_axis = .X,
	})
	if page_status != .Done {
		return {}, false
	}

	text_view, tv_status := box_layout.box_open(tree, {
		label      = "text_view",
		size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
		child_axis = .X,
	})
	if tv_status != .Done {
		return {}, false
	}
	if _, s := box_layout.box_add(tree, {size = {.X = box_layout.px(margin), .Y = box_layout.fill()}}); s != .Done {
		return {}, false
	}
	if _, s := box_layout.box_open(tree, {
		label      = "page_content",
		size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
		child_axis = .Y,
	}); s != .Done {
		return {}, false
	}
	if _, s := box_layout.box_add(tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(margin)}}); s != .Done {
		return {}, false
	}
	heading_box, h_status := box_layout.box_add(tree, {
		label = "page_heading",
		size  = {.X = box_layout.fill(), .Y = box_layout.px(heading_pixels)},
	})
	text_column, tc_status := box_layout.box_add(tree, {
		label = "text_column",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	if h_status != .Done || tc_status != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}
	if _, s := box_layout.box_add(tree, {size = {.X = box_layout.px(SCROLL_GAP), .Y = box_layout.fill()}}); s != .Done {
		return {}, false
	}
	if box_layout.box_close(tree) != .Done {
		return {}, false
	}

	scroll_bar, sb_status := box_layout.box_add(tree, {
		label = "scroll_bar",
		size  = {.X = box_layout.px(SCROLL_WIDTH), .Y = box_layout.fill()},
	})
	if sb_status != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}

	footer_row, foot_status := box_layout.box_open(tree, {
		label      = "footer_row",
		size       = {.X = box_layout.fill(), .Y = box_layout.px(interface.ACTION_BAR_ROW_HEIGHT)},
		child_axis = .X,
	})
	if foot_status != .Done {
		return {}, false
	}
	action_bar, ab_status := box_layout.box_add(tree, {
		label = "action_bar",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	row_status, rs_status := box_layout.box_add(tree, {
		label = "row_status",
		size  = {.X = box_layout.px(PLACE_COLUMNS * CELL_WIDTH + status_margin), .Y = box_layout.fill()},
	})
	if ab_status != .Done || rs_status != .Done || box_layout.box_close(tree) != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}
	if box_layout.solve(tree) != .Done {
		return {}, false
	}

	boxes = {
		root         = area_of(tree, box_layout.ROOT_BOX),
		list_pane    = area_of(tree, list_pane),
		filter_field = area_of(tree, filter_field),
		list_header  = area_of(tree, list_header),
		list_rows    = area_of(tree, list_rows),
		right_pane   = area_of(tree, right_pane),
		page_row     = area_of(tree, page_row),
		text_view    = area_of(tree, text_view),
		heading      = area_of(tree, heading_box),
		text_column  = area_of(tree, text_column),
		scroll_bar   = area_of(tree, scroll_bar),
		footer_row   = area_of(tree, footer_row),
		action_bar   = area_of(tree, action_bar),
		row_status   = area_of(tree, row_status),
	}
	return boxes, true
}
