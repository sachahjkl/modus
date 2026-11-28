// Adaptive collapsing and wrapping toolbar for modus:interface
// (src/md/features/rich_widgets.md).
//
// Groups of toolbar items adapt to any window width without heap allocation:
// - .Fold keeps a single row; pinned groups stay at the right edge while lower-
//   priority items fold into a "..." overflow menu (Context_Menu_State).
// - .Wrap wraps groups across multiple rows (each group moves whole when it
//   fits on one line; a group wider than one line wraps its items), keeping
//   pinned groups at the end of the last row.
package interface

// Plan value: maximum groups and items in one adaptive toolbar without heap allocation.
TOOLBAR_MAX_GROUPS :: 16
TOOLBAR_MAX_ITEMS :: 48
// Plan value: standard toolbar row height and spacing in logical pixels.
TOOLBAR_ROW_HEIGHT :: 28
TOOLBAR_ITEM_HEIGHT :: 24
TOOLBAR_ROW_GAP :: 4
TOOLBAR_ITEM_GAP :: 4
TOOLBAR_GROUP_GAP :: 10
TOOLBAR_SEPARATOR_WIDTH :: 9
TOOLBAR_PAD_X :: 8
TOOLBAR_PAD_Y :: 2
TOOLBAR_MORE_WIDTH :: 32

// How a toolbar reacts when its items exceed the available width.
Toolbar_Overflow :: enum u8 {
	Fold = 0, // One line; lowest-priority items fold into a "..." overflow menu.
	Wrap = 1, // Multiple lines; groups move whole to the next line when they fit.
}

// Horizontal alignment of non-pinned groups inside a toolbar.
Toolbar_Align :: enum u8 {
	Start  = 0,
	Center = 1,
}

// One group of related toolbar items.
Toolbar_Group :: struct {
	title:     string, // Optional section label for accessibility and overflow menu grouping.
	priority:  int,    // Lower folds first in .Fold mode.
	pinned:    bool,   // Kept at the right end; never folds and stays at the end of the last wrapped row.
	end:       bool,   // Placed toward the right end before "..." and pinned groups.
	separator: bool,   // Draws a thin vertical divider before the group when preceded on the same row.
}

// One clickable action or toggle item inside a toolbar.
Toolbar_Item :: struct {
	id:                u32,
	group:             int, // Index into the groups slice.
	label:             string,
	short_label:       string, // Optional shorter label shown inside the bar; label is kept in the overflow menu.
	shortcut:          string, // Optional shortcut text shown in the overflow menu ("Ctrl+K").
	priority_override: Maybe(int),
	on:                bool, // Highlighted / active toggle state.
	disabled:          bool,
	variant:           Button_Variant,
}

Toolbar_Options :: struct {
	overflow: Toolbar_Overflow,
	align:    Toolbar_Align,
}

// Caller-owned state for an adaptive toolbar's overflow menu.
Toolbar_State :: struct {
	overflow_menu: Context_Menu_State,
	more_area:     Area,
}

// Outcome of one toolbar frame.
Toolbar_Result :: struct {
	triggered:    bool,
	triggered_id: u32,
	height:       int, // Exact pixel height used (single row in .Fold, multi-row in .Wrap).
	folded_count: int, // Items currently folded into the "..." menu.
	line_count:   int, // Rows rendered (1 in .Fold, >= 1 in .Wrap).
}

@(private = "file")
toolbar_item_bar_label :: proc "contextless" (item: Toolbar_Item) -> string {
	return item.short_label != "" ? item.short_label : item.label
}

@(private = "file")
toolbar_item_width :: proc "contextless" (table: ^Draw_Table, item: Toolbar_Item) -> int {
	text := toolbar_item_bar_label(item)
	return max(text_measured_width(table, FONT_INTERFACE, text) + 18, 28)
}

@(private = "file")
toolbar_item_priority :: proc "contextless" (groups: []Toolbar_Group, item: Toolbar_Item) -> int {
	if p, ok := item.priority_override.?; ok {
		return p
	}
	if item.group >= 0 && item.group < len(groups) {
		return groups[item.group].priority
	}
	return 0
}

// toolbar_item_is_pinned reports whether an item belongs to a pinned group.
@(private = "file")
toolbar_item_is_pinned :: proc "contextless" (groups: []Toolbar_Group, item: Toolbar_Item) -> bool {
	return item.group >= 0 && item.group < len(groups) && groups[item.group].pinned
}

@(private = "file")
toolbar_item_is_end :: proc "contextless" (groups: []Toolbar_Group, item: Toolbar_Item) -> bool {
	return item.group >= 0 && item.group < len(groups) && groups[item.group].end && !groups[item.group].pinned
}

// toolbar_plan_fold computes which items remain visible in one line and which
// fold into the "..." overflow menu, folding lowest-priority non-pinned items
// from the tail first.
@(private = "file")
toolbar_plan_fold :: proc "contextless" (
	table: ^Draw_Table,
	inner_width: int,
	groups: []Toolbar_Group,
	items: []Toolbar_Item,
	widths: []int,
	visible: []bool,
) -> (folded_count: int) {
	n := min(len(items), TOOLBAR_MAX_ITEMS)
	for i in 0 ..< n {
		widths[i] = toolbar_item_width(table, items[i])
		visible[i] = true
	}
	row_need := proc "contextless" (groups: []Toolbar_Group, items: []Toolbar_Item, widths: []int, visible: []bool, n: int, has_more: bool) -> int {
		total := 0
		prev_group := -1
		shown_any := false
		// Order: normal groups, end groups, [more], pinned groups.
		for pass in 0 ..< 3 {
			for i in 0 ..< n {
				if !visible[i] {
					continue
				}
				pinned := toolbar_item_is_pinned(groups, items[i])
				is_end := toolbar_item_is_end(groups, items[i])
				want := (pass == 0 && !pinned && !is_end) || (pass == 1 && is_end) || (pass == 2 && pinned)
				if !want {
					continue
				}
				if shown_any {
					if items[i].group != prev_group {
						if items[i].group >= 0 && items[i].group < len(groups) && groups[items[i].group].separator {
							total += TOOLBAR_SEPARATOR_WIDTH
						} else {
							total += TOOLBAR_GROUP_GAP
						}
					} else {
						total += TOOLBAR_ITEM_GAP
					}
				}
				total += widths[i]
				prev_group = items[i].group
				shown_any = true
			}
			if pass == 1 && has_more {
				if shown_any {
					total += TOOLBAR_GROUP_GAP
				}
				total += TOOLBAR_MORE_WIDTH
				prev_group = -1
				shown_any = true
			}
		}
		return total
	}

	if row_need(groups, items, widths, visible, n, false) <= inner_width {
		return 0
	}
	// Fold lowest priority non-pinned items first (tail-first on ties).
	for {
		if row_need(groups, items, widths, visible, n, true) <= inner_width {
			break
		}
		victim := -1
		victim_prio := max(int)
		for i := n - 1; i >= 0; i -= 1 {
			if !visible[i] || toolbar_item_is_pinned(groups, items[i]) {
				continue
			}
			p := toolbar_item_priority(groups, items[i])
			if p < victim_prio {
				victim_prio = p
				victim = i
			}
		}
		if victim < 0 {
			break
		}
		visible[victim] = false
		folded_count += 1
	}
	return folded_count
}

// toolbar_plan_wrap computes row assignments and x coordinates for .Wrap mode.
// Each non-pinned group moves whole to the next line when it fits in inner_width;
// a group wider than inner_width wraps its items individually. Pinned items
// settle at the right end of the last line (or a new line if they do not fit).
@(private = "file")
toolbar_plan_wrap :: proc "contextless" (
	table: ^Draw_Table,
	inner_width: int,
	groups: []Toolbar_Group,
	items: []Toolbar_Item,
	widths: []int,
	item_x: []int,
	item_line: []int,
) -> (line_count: int) {
	n := min(len(items), TOOLBAR_MAX_ITEMS)
	if n == 0 {
		return 1
	}
	for i in 0 ..< n {
		widths[i] = toolbar_item_width(table, items[i])
		item_x[i] = 0
		item_line[i] = 0
	}
	// Group index order: normal groups, end groups, pinned groups.
	ordered: [TOOLBAR_MAX_ITEMS]int
	ordered_count := 0
	for pass in 0 ..< 3 {
		for i in 0 ..< n {
			pinned := toolbar_item_is_pinned(groups, items[i])
			is_end := toolbar_item_is_end(groups, items[i])
			want := (pass == 0 && !pinned && !is_end) || (pass == 1 && is_end) || (pass == 2 && pinned)
			if want {
				ordered[ordered_count] = i
				ordered_count += 1
			}
		}
	}

	cur_line := 0
	cur_x := 0
	prev_group := -1
	k := 0
	for k < ordered_count {
		idx := ordered[k]
		g := items[idx].group
		// Measure whole contiguous run belonging to group g.
		run_end := k
		run_w := 0
		for run_end < ordered_count && items[ordered[run_end]].group == g {
			if run_end > k {
				run_w += TOOLBAR_ITEM_GAP
			}
			run_w += widths[ordered[run_end]]
			run_end += 1
		}
		sep_gap := 0
		if cur_x > 0 && prev_group != g {
			if g >= 0 && g < len(groups) && groups[g].separator {
				sep_gap = TOOLBAR_SEPARATOR_WIDTH
			} else {
				sep_gap = TOOLBAR_GROUP_GAP
			}
		}
		// Move whole group to next line if it overflows current line but fits alone.
		if cur_x > 0 && cur_x + sep_gap + run_w > inner_width && run_w <= inner_width {
			cur_line += 1
			cur_x = 0
			sep_gap = 0
		}
		cur_x += sep_gap
		for j in k ..< run_end {
			it_idx := ordered[j]
			gap := j > k && cur_x > 0 ? TOOLBAR_ITEM_GAP : 0
			if cur_x > 0 && cur_x + gap + widths[it_idx] > inner_width {
				cur_line += 1
				cur_x = 0
				gap = 0
			}
			cur_x += gap
			item_x[it_idx] = cur_x
			item_line[it_idx] = cur_line
			cur_x += widths[it_idx]
		}
		prev_group = g
		k = run_end
	}
	return cur_line + 1
}

// toolbar_measure_height computes the exact logical pixel height a toolbar
// needs at the given width (single row in .Fold, wrapped multi-row in .Wrap).
toolbar_measure_height :: proc "contextless" (
	table: ^Draw_Table,
	width: int,
	groups: []Toolbar_Group,
	items: []Toolbar_Item,
	overflow: Toolbar_Overflow,
) -> int {
	if overflow == .Fold || len(items) == 0 {
		return TOOLBAR_ROW_HEIGHT
	}
	inner_w := max(width - 2 * TOOLBAR_PAD_X, 32)
	widths: [TOOLBAR_MAX_ITEMS]int
	xs: [TOOLBAR_MAX_ITEMS]int
	lines: [TOOLBAR_MAX_ITEMS]int
	count := toolbar_plan_wrap(table, inner_w, groups, items, widths[:], xs[:], lines[:])
	return count * TOOLBAR_ITEM_HEIGHT + max(count - 1, 0) * TOOLBAR_ROW_GAP + 2 * TOOLBAR_PAD_Y
}

// toolbar_handle_key routes keyboard events to an open overflow menu.
toolbar_handle_key :: proc "contextless" (frame: ^Frame, state: ^Toolbar_State) -> (triggered: bool, triggered_id: u32) {
	if frame == nil || state == nil || !state.overflow_menu.open {
		return false, 0
	}
	for &key in frame.input.keys[:frame.input.key_count] {
		if key.taken {
			continue
		}
		consumed, act := context_menu_handle_key(&state.overflow_menu, key.code, key.character, true, key.modifiers)
		if consumed {
			key.taken = true
		}
		if act != 0 {
			return true, act
		}
	}
	return false, 0
}

// toolbar_overlay_pointer handles pointer events for an open overflow menu
// before underlying controls run. Call before widgets in the frame.
toolbar_overlay_pointer :: proc "contextless" (frame: ^Frame, state: ^Toolbar_State) -> (triggered: bool, triggered_id: u32) {
	if frame == nil || state == nil || !state.overflow_menu.open {
		return false, 0
	}
	res := context_menu_pointer(&state.overflow_menu, frame.input.pointer_x, frame.input.pointer_y, frame.input.pressed)
	if frame.input.pressed || res.consumed {
		frame.input.pressed = false
		frame.input.released = false
		frame.input.wheel = 0
	}
	return res.triggered, res.triggered_id
}

// toolbar renders an adaptive collapsing or wrapping toolbar inside area.
// Call toolbar_draw_overlay(frame, state, win_w, win_h) at the end of the frame
// so the "..." overflow menu draws above sibling cards.
toolbar :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	groups: []Toolbar_Group,
	items: []Toolbar_Item,
	state: ^Toolbar_State,
	options: Toolbar_Options = {},
	win_w := 0,
	win_h := 0,
) -> (result: Toolbar_Result) {
	if frame == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	theme := theme_current(frame)
	table := frame.table
	el := u32(element)
	n := min(len(items), TOOLBAR_MAX_ITEMS)
	inner_w := max(area.width - 2 * TOOLBAR_PAD_X, 32)

	draw_element_push(table, area, el, .Group, {name = "toolbar"})
	defer draw_element_pop(table)

	// Machined toolbar background strip and bottom divider.
	draw_vertical_gradient(table, area.x, area.y, area.width, area.height, theme.card_top, theme.card_bottom, el)
	draw_rectangle(table, area.x, area.y + area.height - 1, area.width, 1, theme.divider, el)

	widths: [TOOLBAR_MAX_ITEMS]int
	if options.overflow == .Wrap {
		if state != nil && state.overflow_menu.open {
			context_menu_close(&state.overflow_menu)
		}
		xs: [TOOLBAR_MAX_ITEMS]int
		lines: [TOOLBAR_MAX_ITEMS]int
		line_count := toolbar_plan_wrap(table, inner_w, groups, items, widths[:], xs[:], lines[:])
		result.line_count = line_count
		result.height = line_count * TOOLBAR_ITEM_HEIGHT + max(line_count - 1, 0) * TOOLBAR_ROW_GAP + 2 * TOOLBAR_PAD_Y

		// Per-line width for optional .Center alignment and right-aligning pinned tail on last line.
		line_max_x: [TOOLBAR_MAX_ITEMS]int
		for i in 0 ..< n {
			ln := lines[i]
			if ln >= 0 && ln < TOOLBAR_MAX_ITEMS {
				end_x := xs[i] + widths[i]
				if end_x > line_max_x[ln] {
					line_max_x[ln] = end_x
				}
			}
		}

		// Render items in visual line order and draw group separators.
		for ln in 0 ..< line_count {
			row_y := area.y + TOOLBAR_PAD_Y + ln * (TOOLBAR_ITEM_HEIGHT + TOOLBAR_ROW_GAP)
			x_shift := 0
			if options.align == .Center && ln < TOOLBAR_MAX_ITEMS {
				x_shift = max((inner_w - line_max_x[ln]) / 2, 0)
			}
			prev_group := -1
			for i in 0 ..< n {
				if lines[i] != ln {
					continue
				}
				bx := area.x + TOOLBAR_PAD_X + x_shift + xs[i]
				if prev_group >= 0 && items[i].group != prev_group && items[i].group >= 0 && items[i].group < len(groups) && groups[items[i].group].separator {
					sep_x := bx - TOOLBAR_SEPARATOR_WIDTH / 2 - 1
					draw_rectangle(table, sep_x, row_y + 4, 1, TOOLBAR_ITEM_HEIGHT - 8, theme.divider, el)
				}
				box := Area{bx, row_y, widths[i], TOOLBAR_ITEM_HEIGHT}
				item_id := identity_with(element, int(items[i].id) * 31 + i + 1)
				btn_res := button_styled(frame, box, item_id, toolbar_item_bar_label(items[i]), items[i].variant, items[i].on, items[i].disabled)
				if btn_res.activated {
					result.triggered = true
					result.triggered_id = items[i].id
				}
				prev_group = items[i].group
			}
		}
		return result
	}

	// .Fold mode: single row with pinned right-aligned tail and "..." overflow menu.
	visible: [TOOLBAR_MAX_ITEMS]bool
	folded := toolbar_plan_fold(table, inner_w, groups, items, widths[:], visible[:])
	result.folded_count = folded
	result.line_count = 1
	result.height = TOOLBAR_ROW_HEIGHT

	row_y := area.y + (area.height - TOOLBAR_ITEM_HEIGHT) / 2
	// Measure right cluster (end + more + pinned) to anchor cleanly at the right edge.
	right_w := 0
	right_any := false
	prev_g := -1
	for pass in 0 ..< 2 {
		if pass == 1 && folded > 0 {
			if right_any {
				right_w += TOOLBAR_GROUP_GAP
			}
			right_w += TOOLBAR_MORE_WIDTH
			right_any = true
			prev_g = -1
		}
		for i in 0 ..< n {
			if !visible[i] {
				continue
			}
			pinned := toolbar_item_is_pinned(groups, items[i])
			is_end := toolbar_item_is_end(groups, items[i])
			if (pass == 0 && !is_end) || (pass == 1 && !pinned) {
				continue
			}
			if right_any {
				if items[i].group != prev_g && items[i].group >= 0 && items[i].group < len(groups) && groups[items[i].group].separator {
					right_w += TOOLBAR_SEPARATOR_WIDTH
				} else if items[i].group != prev_g {
					right_w += TOOLBAR_GROUP_GAP
				} else {
					right_w += TOOLBAR_ITEM_GAP
				}
			}
			right_w += widths[i]
			prev_g = items[i].group
			right_any = true
		}
	}

	// Measure left cluster (normal non-end, non-pinned items).
	left_w := 0
	left_any := false
	prev_g = -1
	for i in 0 ..< n {
		if !visible[i] || toolbar_item_is_pinned(groups, items[i]) || toolbar_item_is_end(groups, items[i]) {
			continue
		}
		if left_any {
			if items[i].group != prev_g && items[i].group >= 0 && items[i].group < len(groups) && groups[items[i].group].separator {
				left_w += TOOLBAR_SEPARATOR_WIDTH
			} else if items[i].group != prev_g {
				left_w += TOOLBAR_GROUP_GAP
			} else {
				left_w += TOOLBAR_ITEM_GAP
			}
		}
		left_w += widths[i]
		prev_g = items[i].group
		left_any = true
	}

	left_room := inner_w - (right_any ? right_w + TOOLBAR_GROUP_GAP : 0)
	x := area.x + TOOLBAR_PAD_X
	if options.align == .Center && left_room > left_w {
		x += (left_room - left_w) / 2
	}
	prev_g = -1
	drawn_left := false
	for i in 0 ..< n {
		if !visible[i] || toolbar_item_is_pinned(groups, items[i]) || toolbar_item_is_end(groups, items[i]) {
			continue
		}
		if drawn_left {
			if items[i].group != prev_g && items[i].group >= 0 && items[i].group < len(groups) && groups[items[i].group].separator {
				draw_rectangle(table, x + TOOLBAR_SEPARATOR_WIDTH / 2, row_y + 4, 1, TOOLBAR_ITEM_HEIGHT - 8, theme.divider, el)
				x += TOOLBAR_SEPARATOR_WIDTH
			} else if items[i].group != prev_g {
				x += TOOLBAR_GROUP_GAP
			} else {
				x += TOOLBAR_ITEM_GAP
			}
		}
		box := Area{x, row_y, widths[i], TOOLBAR_ITEM_HEIGHT}
		item_id := identity_with(element, int(items[i].id) * 31 + i + 1)
		btn_res := button_styled(frame, box, item_id, toolbar_item_bar_label(items[i]), items[i].variant, items[i].on, items[i].disabled)
		if btn_res.activated {
			result.triggered = true
			result.triggered_id = items[i].id
		}
		x += widths[i]
		prev_g = items[i].group
		drawn_left = true
	}

	// Render right cluster anchored at the right edge of the bar.
	rx := max(area.x + area.width - TOOLBAR_PAD_X - right_w, x + (drawn_left ? TOOLBAR_GROUP_GAP : 0))
	prev_g = -1
	drawn_right := false
	for pass in 0 ..< 2 {
		if pass == 1 && folded > 0 {
			if drawn_right {
				rx += TOOLBAR_GROUP_GAP
			}
			more_box := Area{rx, row_y, TOOLBAR_MORE_WIDTH, TOOLBAR_ITEM_HEIGHT}
			if state != nil {
				state.more_area = more_box
			}
			more_id := identity_in(element, "more")
			more_open := state != nil && state.overflow_menu.open
			more_res := button_styled(frame, more_box, more_id, "...", .Secondary, more_open)
			if more_res.activated && state != nil {
				if state.overflow_menu.open {
					context_menu_close(&state.overflow_menu)
				} else {
					menu_items: [CONTEXT_MENU_MAX_ITEMS]Context_Menu_Item
					menu_count := 0
					last_folded_group := -1
					for j in 0 ..< n {
						if visible[j] || menu_count >= CONTEXT_MENU_MAX_ITEMS {
							continue
						}
						sep := last_folded_group >= 0 && items[j].group != last_folded_group
						menu_items[menu_count] = {
							id               = items[j].id,
							label            = items[j].label,
							shortcut         = items[j].shortcut,
							disabled         = items[j].disabled,
							danger           = items[j].variant == .Danger,
							separator_before = sep,
						}
						menu_count += 1
						last_folded_group = items[j].group
					}
					mw := win_w > 0 ? win_w : area.x + area.width
					mh := win_h > 0 ? win_h : area.y + 400
					context_menu_open_compact(&state.overflow_menu, more_box.x, more_box.y + more_box.height + 2, mw, mh, menu_items[:menu_count])
				}
			}
			rx += TOOLBAR_MORE_WIDTH
			drawn_right = true
			prev_g = -1
		}
		for i in 0 ..< n {
			if !visible[i] {
				continue
			}
			pinned := toolbar_item_is_pinned(groups, items[i])
			is_end := toolbar_item_is_end(groups, items[i])
			if (pass == 0 && !is_end) || (pass == 1 && !pinned) {
				continue
			}
			if drawn_right {
				if items[i].group != prev_g && items[i].group >= 0 && items[i].group < len(groups) && groups[items[i].group].separator {
					draw_rectangle(table, rx + TOOLBAR_SEPARATOR_WIDTH / 2, row_y + 4, 1, TOOLBAR_ITEM_HEIGHT - 8, theme.divider, el)
					rx += TOOLBAR_SEPARATOR_WIDTH
				} else if items[i].group != prev_g {
					rx += TOOLBAR_GROUP_GAP
				} else {
					rx += TOOLBAR_ITEM_GAP
				}
			}
			box := Area{rx, row_y, widths[i], TOOLBAR_ITEM_HEIGHT}
			item_id := identity_with(element, int(items[i].id) * 31 + i + 1)
			btn_res := button_styled(frame, box, item_id, toolbar_item_bar_label(items[i]), items[i].variant, items[i].on, items[i].disabled)
			if btn_res.activated {
				result.triggered = true
				result.triggered_id = items[i].id
			}
			rx += widths[i]
			prev_g = items[i].group
			drawn_right = true
		}
	}
	if folded == 0 && state != nil && state.overflow_menu.open {
		context_menu_close(&state.overflow_menu)
	}
	return result
}

// toolbar_draw_overlay renders the toolbar's open "..." overflow menu above
// sibling cards. Call near the end of frame construction.
toolbar_draw_overlay :: proc "contextless" (frame: ^Frame, state: ^Toolbar_State) {
	if frame == nil || state == nil || !state.overflow_menu.open {
		return
	}
	context_menu_draw(frame.table, &state.overflow_menu)
}
