// Pure box-tree layout for the desktop Grants window
// (src/md/features/grants_window.md and src/md/features/box_layout.md).
// No kernel calls: host tests verify bounds, dark and light element tokens,
// and zero overlap.
package grants_window

import "modus:graphics"
import "modus:interface"
import box_layout "modus:layout"

// Initial, minimum, and maximum window dimensions in logical pixels.
WIDTH :: 680
HEIGHT :: 560
LEAST_WIDTH :: 480
LEAST_HEIGHT :: 320
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 960

// Layout constants sized from interface typography and button metrics.
HEADER_HEIGHT :: 30
REFRESH_BUTTON_WIDTH :: 96
ACTION_BUTTON_WIDTH :: 96
CONFIRM_BUTTON_WIDTH :: 136
CANCEL_BUTTON_WIDTH :: 80
ROW_HEIGHT :: 32
SECTION_HEADING_HEIGHT :: 30
PROCESS_HEADING_HEIGHT :: 26

// Minimum bounds guaranteeing header, viewport, scroll bar, and action bar
// keep positive room without overlap.
MINIMUM_WIDTH :: 2 * graphics.MARGIN + REFRESH_BUTTON_WIDTH + interface.SCROLL_BAR_THICKNESS + 240
MINIMUM_HEIGHT :: 2 * graphics.MARGIN + HEADER_HEIGHT + interface.ACTION_BAR_ROW_HEIGHT + 3 * ROW_HEIGHT
#assert(WIDTH >= MINIMUM_WIDTH && HEIGHT >= MINIMUM_HEIGHT)
#assert(LEAST_WIDTH >= MINIMUM_WIDTH && LEAST_HEIGHT >= MINIMUM_HEIGHT)
#assert(LARGEST_WIDTH >= WIDTH && LARGEST_HEIGHT >= HEIGHT)

// Solved rectangles for one frame of the Grants window.
Grants_Boxes :: struct {
	root:           interface.Area,
	header:         interface.Area,
	status_area:    interface.Area,
	refresh_button: interface.Area,
	body_row:       interface.Area,
	viewport:       interface.Area,
	scroll_bar:     interface.Area,
	action_bar:     interface.Area,
}

@(private = "file")
area_of :: proc "contextless" (tree: ^box_layout.Box_Tree, index: box_layout.Box_Index) -> interface.Area {
	rect := tree.boxes[index].rect
	return {int(rect.x), int(rect.y), int(rect.width), int(rect.height)}
}

// grants_layout solves all outer chrome rectangles of the Grants window with
// modus:layout. Refuses nil trees or dimensions outside [MINIMUM, LENGTH_LIMIT]
// without mutating output.
grants_layout :: proc "contextless" (
	tree: ^box_layout.Box_Tree,
	width, height: int,
	tokens: box_layout.Element_Tokens,
) -> (boxes: Grants_Boxes, ok: bool) {
	if tree == nil || width < MINIMUM_WIDTH || height < MINIMUM_HEIGHT || width > int(box_layout.LENGTH_LIMIT) || height > int(box_layout.LENGTH_LIMIT) {
		return {}, false
	}
	margin := tokens.margin
	row_gap := tokens.gap
	inline_gap := max(tokens.gap / 2, i32(4))

	if box_layout.tree_begin(tree, i32(width), i32(height), {
		child_axis = .Y,
		padding    = {.X = margin, .Y = margin},
		gap        = row_gap,
	}) != .Done {
		return {}, false
	}

	// Header row: status message on the left, Refresh button on the right.
	header_box, header_status := box_layout.box_open(tree, {
		label      = "grants_header",
		size       = {.X = box_layout.fill(), .Y = box_layout.px(HEADER_HEIGHT)},
		child_axis = .X,
		gap        = inline_gap,
	})
	if header_status != .Done {
		return {}, false
	}
	status_box, status_status := box_layout.box_add(tree, {
		label = "grants_status",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	if status_status != .Done {
		return {}, false
	}
	refresh_box, refresh_status := box_layout.box_add(tree, {
		label = "grants_refresh_button",
		size  = {.X = box_layout.px(REFRESH_BUTTON_WIDTH), .Y = box_layout.fill()},
	})
	if refresh_status != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}

	// Main scrollable content row: viewport + vertical scroll bar.
	body_box, body_status := box_layout.box_open(tree, {
		label      = "grants_body",
		size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
		child_axis = .X,
		gap        = inline_gap,
	})
	if body_status != .Done {
		return {}, false
	}
	viewport_box, viewport_status := box_layout.box_add(tree, {
		label = "grants_viewport",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	if viewport_status != .Done {
		return {}, false
	}
	scroll_box, scroll_status := box_layout.box_add(tree, {
		label = "grants_scroll_bar",
		size  = {.X = box_layout.px(interface.SCROLL_BAR_THICKNESS), .Y = box_layout.fill()},
	})
	if scroll_status != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}

	// Bottom action bar.
	action_bar_box, action_bar_status := box_layout.box_add(tree, {
		label = "grants_action_bar",
		size  = {.X = box_layout.fill(), .Y = box_layout.px(interface.ACTION_BAR_ROW_HEIGHT)},
	})
	if action_bar_status != .Done {
		return {}, false
	}

	if box_layout.solve(tree) != .Done {
		return {}, false
	}

	boxes = {
		root           = area_of(tree, box_layout.ROOT_BOX),
		header         = area_of(tree, header_box),
		status_area    = area_of(tree, status_box),
		refresh_button = area_of(tree, refresh_box),
		body_row       = area_of(tree, body_box),
		viewport       = area_of(tree, viewport_box),
		scroll_bar     = area_of(tree, scroll_box),
		action_bar     = area_of(tree, action_bar_box),
	}
	return boxes, true
}
