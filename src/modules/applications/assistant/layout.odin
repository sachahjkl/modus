package assistant_window

// Pure box-tree layout for the assistant window (src/md/features/box_layout.md
// and src/md/features/assistant.md and src/md/features/agent_code_mode.md). No
// system calls: host tests verify bounds, dark/light element tokens, both view
// tabs, and zero overlap.

import "modus:interface"
import box_layout "modus:layout"

// Plan value: top header strip height holding the view tabs, live status badge,
// and optional review action button.
HEADER_HEIGHT :: 30
// Plan value: status badge width in the header bar (fits the widest loop progress or waiting count label).
STATUS_BADGE_WIDTH :: 112
// Plan value: review button width shown when an act awaits principal approval.
REVIEW_BUTTON_WIDTH :: 76
// Plan value: filter bar height at the top of the Code steps view.
STEP_FILTER_HEIGHT :: 26
// Plan value: height of the execution trace and approval inspector pane at the
// bottom of the Code steps view (grows proportionally on taller windows).
STEP_DETAIL_MIN_HEIGHT :: 136

// Computed: minimum window bounds ensuring the header (tabs + badge + review),
// body view (or split step list + detail), scroll bar, request input field, and
// Stop button all keep positive room without overlap.
MINIMUM_WIDTH :: 2 * MARGIN + 220 + STATUS_BADGE_WIDTH + REVIEW_BUTTON_WIDTH + 16
MINIMUM_HEIGHT :: 2 * MARGIN + HEADER_HEIGHT + STEP_FILTER_HEIGHT + STEP_DETAIL_MIN_HEIGHT + INPUT_HEIGHT + 96
#assert(WIDTH >= MINIMUM_WIDTH && HEIGHT >= MINIMUM_HEIGHT)

// Solved rectangles for one frame of the assistant window.
Assistant_Boxes :: struct {
	root:          interface.Area,
	header_row:    interface.Area,
	tab_bar:       interface.Area,
	status_badge:  interface.Area,
	review_button: interface.Area,
	has_review:    bool,
	body_row:      interface.Area,
	view:          interface.Area,
	scroll_bar:    interface.Area,
	steps_filter:  interface.Area,
	steps_list:    interface.Area,
	steps_detail:  interface.Area,
	foot_row:      interface.Area,
	input:         interface.Area,
	stop_button:   interface.Area,
	has_stop:      bool,
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
	active_tab: Assistant_View_Tab = .Conversation,
	has_waiting: bool = false,
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

	// Header row: view tab bar, live status badge, and optional Review button.
	header_row, header_status := box_layout.box_open(tree, {
		label      = "header",
		size       = {.X = box_layout.fill(), .Y = box_layout.px(HEADER_HEIGHT)},
		child_axis = .X,
		gap        = inline_gap,
	})
	if header_status != .Done {
		return {}, false
	}
	tab_box, tab_status := box_layout.box_add(tree, {
		label = "view_tabs",
		size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
	})
	if tab_status != .Done {
		return {}, false
	}
	badge_box, badge_status := box_layout.box_add(tree, {
		label = "status_badge",
		size  = {.X = box_layout.px(STATUS_BADGE_WIDTH), .Y = box_layout.fill()},
	})
	if badge_status != .Done {
		return {}, false
	}
	review_box := box_layout.NO_BOX
	if has_waiting {
		review_status: box_layout.Box_Status
		review_box, review_status = box_layout.box_add(tree, {
			label = "review_button",
			size  = {.X = box_layout.px(REVIEW_BUTTON_WIDTH), .Y = box_layout.fill()},
		})
		if review_status != .Done {
			return {}, false
		}
	}
	if box_layout.box_close(tree) != .Done {
		return {}, false
	}

	// Body row: either the conversation scroll view or the code-mode step view.
	body_row := box_layout.NO_BOX
	view_box := box_layout.NO_BOX
	scroll_box := box_layout.NO_BOX
	steps_filter_box := box_layout.NO_BOX
	steps_list_box := box_layout.NO_BOX
	steps_detail_box := box_layout.NO_BOX

	switch active_tab {
	case .Conversation:
		body_status: box_layout.Box_Status
		body_row, body_status = box_layout.box_open(tree, {
			label      = "body",
			size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
			child_axis = .X,
			gap        = inline_gap,
		})
		if body_status != .Done {
			return {}, false
		}
		view_status, scroll_status: box_layout.Box_Status
		view_box, view_status = box_layout.box_add(tree, {
			label = "conversation_view",
			size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
		})
		if view_status != .Done {
			return {}, false
		}
		scroll_box, scroll_status = box_layout.box_add(tree, {
			label = "conversation_scroll_bar",
			size  = {.X = box_layout.px(interface.SCROLL_BAR_THICKNESS), .Y = box_layout.fill()},
		})
		if scroll_status != .Done || box_layout.box_close(tree) != .Done {
			return {}, false
		}
	case .Steps:
		body_status: box_layout.Box_Status
		body_row, body_status = box_layout.box_open(tree, {
			label      = "steps_body",
			size       = {.X = box_layout.fill(), .Y = box_layout.fill()},
			child_axis = .Y,
			gap        = inline_gap,
		})
		if body_status != .Done {
			return {}, false
		}
		filter_status, list_status, detail_status: box_layout.Box_Status
		steps_filter_box, filter_status = box_layout.box_add(tree, {
			label = "steps_filter",
			size  = {.X = box_layout.fill(), .Y = box_layout.px(STEP_FILTER_HEIGHT)},
		})
		if filter_status != .Done {
			return {}, false
		}
		// Keep roughly 45% of body height for the execution trace inspector,
		// bounded below by STEP_DETAIL_MIN_HEIGHT so code and status stay legible.
		avail_body := height - 2 * int(margin) - HEADER_HEIGHT - INPUT_HEIGHT - 2 * int(row_gap) - STEP_FILTER_HEIGHT - 2 * int(inline_gap)
		detail_h := max(STEP_DETAIL_MIN_HEIGHT, avail_body * 45 / 100)
		detail_h = min(detail_h, max(STEP_DETAIL_MIN_HEIGHT, avail_body - 48))
		steps_list_box, list_status = box_layout.box_add(tree, {
			label = "steps_list",
			size  = {.X = box_layout.fill(), .Y = box_layout.fill()},
		})
		if list_status != .Done {
			return {}, false
		}
		steps_detail_box, detail_status = box_layout.box_add(tree, {
			label = "steps_detail",
			size  = {.X = box_layout.fill(), .Y = box_layout.px(i32(detail_h))},
		})
		if detail_status != .Done || box_layout.box_close(tree) != .Done {
			return {}, false
		}
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
		root          = area_of(tree, box_layout.ROOT_BOX),
		header_row    = area_of(tree, header_row),
		tab_bar       = area_of(tree, tab_box),
		status_badge  = area_of(tree, badge_box),
		review_button = has_waiting ? area_of(tree, review_box) : {},
		has_review    = has_waiting,
		body_row      = area_of(tree, body_row),
		view          = active_tab == .Conversation ? area_of(tree, view_box) : {},
		scroll_bar    = active_tab == .Conversation ? area_of(tree, scroll_box) : {},
		steps_filter  = active_tab == .Steps ? area_of(tree, steps_filter_box) : {},
		steps_list    = active_tab == .Steps ? area_of(tree, steps_list_box) : {},
		steps_detail  = active_tab == .Steps ? area_of(tree, steps_detail_box) : {},
		foot_row      = area_of(tree, foot_row),
		input         = area_of(tree, input_box),
		stop_button   = running ? area_of(tree, stop_box) : {},
		has_stop      = running,
	}
	return boxes, true
}
