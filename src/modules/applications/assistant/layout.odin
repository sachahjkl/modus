package assistant_window

// Pure box-tree layout for the assistant window (src/md/features/box_layout.md
// and src/md/features/assistant.md). No system calls: host tests verify bounds,
// dark/light element tokens, and zero overlap.

import "modus:interface"
import box_layout "modus:layout"

// Minimum window bounds ensuring the conversation view, scroll bar, request
// input field, and Stop button all keep positive room without overlap.
MINIMUM_WIDTH :: 2 * MARGIN + STOP_WIDTH + interface.SCROLL_BAR_THICKNESS + 160
MINIMUM_HEIGHT :: 2 * MARGIN + INPUT_HEIGHT + 96
#assert(WIDTH >= MINIMUM_WIDTH && HEIGHT >= MINIMUM_HEIGHT)

// Solved rectangles for one frame of the assistant window.
Assistant_Boxes :: struct {
	root:        interface.Area,
	body_row:    interface.Area,
	view:        interface.Area,
	scroll_bar:  interface.Area,
	foot_row:    interface.Area,
	input:       interface.Area,
	stop_button: interface.Area,
	has_stop:    bool,
}

@(private = "file")
area_of :: proc "contextless" (tree: ^box_layout.Box_Tree, index: box_layout.Box_Index) -> interface.Area {
	rect := tree.boxes[index].rect
	return {int(rect.x), int(rect.y), int(rect.width), int(rect.height)}
}

// assistant_layout computes all rectangles of the assistant window using
// modus:layout. Refuses dimensions below MINIMUM_WIDTH or MINIMUM_HEIGHT
// without modifying the returned boxes.
assistant_layout :: proc "contextless" (
	tree: ^box_layout.Box_Tree,
	width, height: int,
	running: bool,
	tokens: box_layout.Element_Tokens,
) -> (boxes: Assistant_Boxes, ok: bool) {
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

	body_row, body_status := box_layout.box_open(tree, {
		label      = "body",
		size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
		child_axis = .X,
		gap        = inline_gap,
	})
	if body_status != .Done {
		return {}, false
	}
	view_box, view_status := box_layout.box_add(tree, {
		label = "conversation_view",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	if view_status != .Done {
		return {}, false
	}
	scroll_box, scroll_status := box_layout.box_add(tree, {
		label = "conversation_scroll_bar",
		size  = {.X = box_layout.px(interface.SCROLL_BAR_THICKNESS), .Y = box_layout.fill()},
	})
	if scroll_status != .Done || box_layout.box_close(tree) != .Done {
		return {}, false
	}

	foot_row, foot_status := box_layout.box_open(tree, {
		label      = "foot",
		size       = {.X = box_layout.fill(), .Y = box_layout.px(INPUT_HEIGHT)},
		child_axis = .X,
		gap        = inline_gap,
	})
	if foot_status != .Done {
		return {}, false
	}
	input_box, input_status := box_layout.box_add(tree, {
		label = "request_input",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	if input_status != .Done {
		return {}, false
	}
	stop_box := box_layout.NO_BOX
	if running {
		stop_status: box_layout.Box_Status
		stop_box, stop_status = box_layout.box_add(tree, {
			label = "stop_button",
			size  = {.X = box_layout.px(STOP_WIDTH), .Y = box_layout.fill()},
		})
		if stop_status != .Done {
			return {}, false
		}
	}
	if box_layout.box_close(tree) != .Done {
		return {}, false
	}
	if box_layout.solve(tree) != .Done {
		return {}, false
	}

	boxes = {
		root        = area_of(tree, box_layout.ROOT_BOX),
		body_row    = area_of(tree, body_row),
		view        = area_of(tree, view_box),
		scroll_bar  = area_of(tree, scroll_box),
		foot_row    = area_of(tree, foot_row),
		input       = area_of(tree, input_box),
		stop_button = running ? area_of(tree, stop_box) : {},
		has_stop    = running,
	}
	return boxes, true
}
