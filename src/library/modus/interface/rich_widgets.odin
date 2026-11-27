// Rich interactive desktop controls for modus:interface
// (src/md/features/rich_widgets.md): styled buttons with tactile
// hover/pressed/disabled states, toggle switches, segmented controls, tab
// bars, draggable sliders, status badges, and drag-and-drop reorderable lists.
package interface

import "modus:contract/accessibility"
import "modus:display"
import "modus:graphics"

// Visual role of a styled button.
Button_Variant :: enum u8 {
	Secondary,   // Machined gradient button with subtle border and top highlight.
	Primary,     // High-emphasis accent button in colors.chosen.
	Ghost,       // Borderless button that surfaces on hover/press.
	Danger,      // Destructive action button in colors.stop_process.
	Sidebar_Row, // Left-aligned navigation item with a 3 px accent rail when selected.
}

// Plan value: machined 2:1 rectangular toggle switch fitting cleanly inside a 24 px row.
SWITCH_TRACK_WIDTH :: 36
SWITCH_TRACK_HEIGHT :: 18
SWITCH_THUMB_WIDTH :: 14
SWITCH_THUMB_HEIGHT :: 12
SWITCH_THUMB_INSET :: 3

// Plan value: horizontal padding inside each tab of tab_bar.
TAB_PADDING_X :: 14
// Plan value: thickness of the active bottom accent bar under the selected tab.
TAB_ACCENT_HEIGHT :: 2
// Plan value: caps a single tab bar without heap allocation.
TAB_BAR_MAX_TABS :: 12

// Plan value: caps a single horizontal segmented control without heap allocation.
SEGMENTED_MAX_ITEMS :: 8

// Plan value: visual geometry of the horizontal draggable slider.
SLIDER_TRACK_HEIGHT :: 6
SLIDER_THUMB_WIDTH :: 12
SLIDER_THUMB_HEIGHT :: 18

// Plan value: row height and drag threshold for reorder_list.
REORDER_ROW_HEIGHT :: 30
REORDER_DRAG_THRESHOLD :: 4
REORDER_GRIP_WIDTH :: 18

// Persistent drag-and-drop state owned by the caller for reorder_list.
Reorder_Drag_State :: struct {
	pressing:   bool,
	dragging:   bool,
	source_row: int,
	target_row: int,
	grab_y:     int,
	pointer_y:  int,
}

// button_styled draws a button with full tactile visual feedback: Rest, Hover,
// Pressed (button held over the control), Selected/Open, Focused, and Disabled.
button_styled :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, label: string, variant: Button_Variant = .Secondary, open := false, disabled := false, toggle: accessibility.Toggle_State = .None) -> (result: Element_Result) {
	if area.width <= 0 || area.height <= 0 {
		return
	}
	if !disabled {
		result = element_interact(frame, element, area, .Button)
	}
	element_name(frame, area, label)
	pressed_down := !disabled && frame.state.pressed == element && frame.input.button_held && result.under_pointer
	hovered := !disabled && result.under_pointer

	shown := text_fit(frame.table, FONT_INTERFACE, label, max(area.width - 16, 0))
	states: accessibility.Element_States
	actions: accessibility.Element_Actions
	if disabled {
		states += {.Disabled}
	} else {
		states += {.Focusable}
		actions = {.Press, .Focus}
		if result.focused {
			states += {.Focused}
		}
	}
	effective_toggle := toggle != .None ? toggle : (open ? accessibility.Toggle_State.True : accessibility.Toggle_State.None)
	draw_element_push(frame.table, area, u32(element), .Button, {
		toggle  = effective_toggle,
		states  = states,
		actions = actions,
		name    = shown != label ? label : "",
	})
	defer draw_element_pop(frame.table)

	table := frame.table
	el := u32(element)
	text_color := graphics.colors.text
	font := FONT_INTERFACE

	switch variant {
	case .Secondary:
		switch {
		case disabled:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.recess, el)
			draw_outline(table, area.x, area.y, area.width, area.height, 1, graphics.colors.track, el)
			text_color = graphics.colors.dim
		case pressed_down:
			top := graphics.shade(graphics.colors.chosen, 82)
			bot := graphics.shade(graphics.colors.chosen, 96)
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, top, bot, el)
			draw_outline(table, area.x, area.y, area.width, area.height, 1, graphics.colors.title, el)
			text_color = graphics.COLOR_WHITE
		case open:
			top := hovered ? graphics.shade(graphics.colors.chosen, 114) : graphics.shade(graphics.colors.chosen, 106)
			bot := graphics.shade(graphics.colors.chosen, 88)
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, top, bot, el)
			if area.width > 2 {
				draw_rectangle(table, area.x + 1, area.y + 1, area.width - 2, 1, graphics.shade(graphics.colors.chosen, 138), el)
			}
			text_color = graphics.COLOR_WHITE
		case hovered:
			top := graphics.shade(graphics.colors.title, 70)
			bot := graphics.shade(graphics.colors.title, 54)
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, top, bot, el)
			draw_outline(table, area.x, area.y, area.width, area.height, 1, graphics.colors.title, el)
			text_color = graphics.COLOR_WHITE
		case:
			top := graphics.shade(graphics.colors.track, 108)
			bot := graphics.shade(graphics.colors.track, 92)
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, top, bot, el)
			draw_outline(table, area.x, area.y, area.width, area.height, 1, graphics.colors.not_usable, el)
			if area.width > 2 && area.height > 2 {
				draw_rectangle(table, area.x + 1, area.y + 1, area.width - 2, 1, graphics.shade(graphics.colors.track, 122), el)
			}
			text_color = graphics.colors.text
		}
	case .Primary:
		font = FONT_INTERFACE_BOLD
		switch {
		case disabled:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.track, el)
			text_color = graphics.colors.dim
		case pressed_down:
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.shade(graphics.colors.chosen, 78), graphics.shade(graphics.colors.chosen, 92), el)
			draw_outline(table, area.x, area.y, area.width, area.height, 1, graphics.colors.title, el)
			text_color = graphics.COLOR_WHITE
		case hovered:
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.shade(graphics.colors.chosen, 122), graphics.shade(graphics.colors.chosen, 96), el)
			if area.width > 2 {
				draw_rectangle(table, area.x + 1, area.y + 1, area.width - 2, 1, graphics.shade(graphics.colors.chosen, 148), el)
			}
			text_color = graphics.COLOR_WHITE
		case:
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.shade(graphics.colors.chosen, 110), graphics.shade(graphics.colors.chosen, 88), el)
			if area.width > 2 {
				draw_rectangle(table, area.x + 1, area.y + 1, area.width - 2, 1, graphics.shade(graphics.colors.chosen, 138), el)
			}
			text_color = graphics.COLOR_WHITE
		}
	case .Ghost:
		switch {
		case disabled:
			text_color = graphics.colors.dim
		case pressed_down:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.chosen, el)
			text_color = graphics.COLOR_WHITE
		case open:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.track, el)
			draw_outline(table, area.x, area.y, area.width, area.height, 1, graphics.colors.title, el)
			text_color = graphics.colors.text_strong
		case hovered:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.track, el)
			text_color = graphics.colors.text_strong
		case:
			text_color = graphics.colors.text
		}
	case .Danger:
		font = FONT_INTERFACE_BOLD
		switch {
		case disabled:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.track, el)
			text_color = graphics.colors.dim
		case pressed_down:
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.shade(graphics.colors.stop_process, 78), graphics.shade(graphics.colors.stop_process, 92), el)
			text_color = graphics.COLOR_WHITE
		case hovered:
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.colors.stop_process_pointer_over, graphics.colors.stop_process, el)
			if area.width > 2 {
				draw_rectangle(table, area.x + 1, area.y + 1, area.width - 2, 1, graphics.shade(graphics.colors.stop_process_pointer_over, 132), el)
			}
			text_color = graphics.COLOR_WHITE
		case:
			draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.colors.stop_process, graphics.shade(graphics.colors.stop_process, 82), el)
			if area.width > 2 {
				draw_rectangle(table, area.x + 1, area.y + 1, area.width - 2, 1, graphics.shade(graphics.colors.stop_process, 130), el)
			}
			text_color = graphics.COLOR_WHITE
		}
	case .Sidebar_Row:
		switch {
		case disabled:
			text_color = graphics.colors.dim
		case open:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.track, el)
			draw_rectangle(table, area.x, area.y + 3, 3, max(area.height - 6, 2), graphics.colors.title, el)
			text_color = graphics.colors.text_strong
			font = FONT_INTERFACE_BOLD
		case pressed_down:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.chosen, el)
			text_color = graphics.COLOR_WHITE
		case hovered:
			draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.card_top, el)
			text_color = graphics.colors.text_strong
		case:
			text_color = graphics.colors.text
		}
	}

	text_x := area.x + (variant == .Sidebar_Row ? 12 : 8)
	text_y := area.y + (area.height - LINE) / 2 + (pressed_down ? 1 : 0)
	draw_text(table, text_x, text_y, shown, text_color, font, el)

	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// toggle_switch draws a labeled row with a tactile rectangular toggle switch
// aligned at its right edge. Clicking anywhere on the row or pressing
// Space/Enter while focused toggles value^.
toggle_switch :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, label: string, value: ^bool, disabled := false) -> (result: Element_Result) {
	if value == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	if !disabled {
		result = element_interact(frame, element, area, .Button)
		if result.activated {
			value^ = !value^
			result.changed = true
		}
	}
	element_name(frame, area, label)
	on := value^
	pressed_down := !disabled && frame.state.pressed == element && frame.input.button_held && result.under_pointer
	hovered := !disabled && result.under_pointer

	states: accessibility.Element_States
	actions: accessibility.Element_Actions
	if disabled {
		states += {.Disabled}
	} else {
		states += {.Focusable}
		actions = {.Press, .Focus}
		if result.focused {
			states += {.Focused}
		}
	}
	el := u32(element)
	draw_element_push(frame.table, area, el, .Switch, {
		toggle  = on ? .True : .False,
		states  = states,
		actions = actions,
		name    = label,
	})
	defer draw_element_pop(frame.table)

	table := frame.table
	if hovered {
		draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.card_top, el)
	}

	track_x := area.x + area.width - SWITCH_TRACK_WIDTH - 4
	track_y := area.y + (area.height - SWITCH_TRACK_HEIGHT) / 2
	label_room := max(track_x - area.x - 12, 0)
	if label != "" && label_room > 0 {
		shown := text_fit(table, FONT_INTERFACE, label, label_room)
		draw_text(table, area.x + 4, area.y + (area.height - LINE) / 2, shown, disabled ? graphics.colors.dim : (hovered ? graphics.colors.text_strong : graphics.colors.text), FONT_INTERFACE, el)
	}

	if track_x >= area.x {
		track_bg: graphics.Color
		track_border: graphics.Color
		switch {
		case disabled:
			track_bg = graphics.colors.recess
			track_border = graphics.colors.track
		case on:
			track_bg = hovered ? graphics.shade(graphics.colors.chosen, 118) : graphics.colors.chosen
			track_border = graphics.colors.title
		case:
			track_bg = hovered ? graphics.shade(graphics.colors.track, 118) : graphics.colors.track
			track_border = hovered ? graphics.colors.title : graphics.colors.not_usable
		}
		draw_rectangle(table, track_x, track_y, SWITCH_TRACK_WIDTH, SWITCH_TRACK_HEIGHT, track_bg, el)
		draw_outline(table, track_x, track_y, SWITCH_TRACK_WIDTH, SWITCH_TRACK_HEIGHT, 1, track_border, el)

		thumb_x := on ? (track_x + SWITCH_TRACK_WIDTH - SWITCH_THUMB_WIDTH - SWITCH_THUMB_INSET) : (track_x + SWITCH_THUMB_INSET)
		if pressed_down {
			thumb_x += on ? -1 : 1
		}
		thumb_y := track_y + (SWITCH_TRACK_HEIGHT - SWITCH_THUMB_HEIGHT) / 2
		thumb_col := disabled ? graphics.colors.not_usable : (on ? graphics.COLOR_WHITE : (hovered ? graphics.colors.text_strong : graphics.colors.text))
		draw_rectangle(table, thumb_x, thumb_y, SWITCH_THUMB_WIDTH, SWITCH_THUMB_HEIGHT, thumb_col, el)
	}

	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// segmented_control draws connected mutually-exclusive choices inside one
// recessed frame. Clicking a segment or using Left/Right arrows while focused
// changes chosen^.
segmented_control :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, labels: []string, chosen: ^int, disabled := false) -> (result: Element_Result) {
	count := min(len(labels), SEGMENTED_MAX_ITEMS)
	if chosen == nil || count <= 0 || area.width <= 0 || area.height <= 0 {
		return
	}
	chosen^ = clamp(chosen^, 0, count - 1)
	before := chosen^
	if !disabled {
		result = element_interact(frame, element, area, .List)
	}
	if result.focused && !disabled {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch key.code {
			case display.KEY_LEFT:
				chosen^ = (chosen^ + count - 1) % count
				key.taken = true
			case display.KEY_RIGHT:
				chosen^ = (chosen^ + 1) % count
				key.taken = true
			}
		}
	}

	table := frame.table
	el := u32(element)
	group_states: accessibility.Element_States
	if disabled {
		group_states += {.Disabled}
	} else {
		group_states += {.Focusable}
		if result.focused {
			group_states += {.Focused}
		}
	}
	draw_element_push(table, area, el, .Radio_Group, {states = group_states, actions = disabled ? {} : {.Focus}})
	defer draw_element_pop(table)

	// Recessed outer container.
	draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.recess, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, disabled ? graphics.colors.track : graphics.colors.not_usable, el)

	inner_x := area.x + 2
	inner_y := area.y + 2
	inner_w := max(area.width - 4, 0)
	inner_h := max(area.height - 4, 0)
	seg_w := inner_w / count

	for idx in 0 ..< count {
		sx := inner_x + idx * seg_w
		sw := idx == count - 1 ? (inner_x + inner_w - sx) : seg_w
		seg_area := Area{sx, inner_y, sw, inner_h}
		element_name(frame, seg_area, labels[idx])
		seg_hovered := !disabled && frame.input.pointer_known && area_contains(seg_area, frame.input.pointer_x, frame.input.pointer_y)
		if seg_hovered && frame.input.pressed {
			chosen^ = idx
			result.activated = true
		}
		is_selected := idx == chosen^
		opt_id := u32(identity_with(element, idx))
		draw_element_push(table, seg_area, opt_id, .Radio, {
			states          = is_selected ? {.Selected} : {},
			actions         = disabled ? {} : {.Select},
			name            = labels[idx],
			position_in_set = u32(idx + 1),
			set_size        = u32(count),
		})
		if is_selected {
			bg_top := disabled ? graphics.colors.track : graphics.shade(graphics.colors.chosen, 110)
			bg_bot := disabled ? graphics.colors.track : graphics.shade(graphics.colors.chosen, 88)
			draw_vertical_gradient(table, sx, inner_y, sw, inner_h, bg_top, bg_bot, opt_id)
			if !disabled && sw > 2 {
				draw_rectangle(table, sx + 1, inner_y, sw - 2, 1, graphics.shade(graphics.colors.chosen, 140), opt_id)
			}
		} else if seg_hovered {
			draw_rectangle(table, sx, inner_y, sw, inner_h, graphics.colors.track, opt_id)
		}
		if idx > 0 && !is_selected && (idx - 1) != chosen^ {
			draw_rectangle(table, sx, inner_y + 3, 1, max(inner_h - 6, 0), graphics.colors.track, el)
		}
		font := is_selected ? FONT_INTERFACE_BOLD : FONT_INTERFACE
		shown := text_fit(table, font, labels[idx], max(sw - 8, 0))
		tw := text_measured_width(table, font, shown)
		tx := sx + max((sw - tw) / 2, 2)
		ty := inner_y + (inner_h - LINE) / 2
		col := disabled ? graphics.colors.dim : (is_selected ? graphics.COLOR_WHITE : (seg_hovered ? graphics.colors.text_strong : graphics.colors.text))
		draw_text(table, tx, ty, shown, col, font, opt_id)
		draw_element_pop(table)
	}

	result.changed = chosen^ != before
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// tab_bar draws a horizontal tab strip with a bottom divider hairline and a
// 2 px title-accent indicator under the active tab.
tab_bar :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, labels: []string, active: ^int) -> (result: Element_Result) {
	count := min(len(labels), TAB_BAR_MAX_TABS)
	if active == nil || count <= 0 || area.width <= 0 || area.height <= 0 {
		return
	}
	active^ = clamp(active^, 0, count - 1)
	before := active^
	result = element_interact(frame, element, area, .List)
	if result.focused {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch key.code {
			case display.KEY_LEFT:
				active^ = (active^ + count - 1) % count
				key.taken = true
			case display.KEY_RIGHT:
				active^ = (active^ + 1) % count
				key.taken = true
			}
		}
	}

	table := frame.table
	el := u32(element)
	list_states := accessibility.Element_States{.Focusable}
	if result.focused {
		list_states += {.Focused}
	}
	draw_element_push(table, area, el, .Tab_List, {states = list_states, actions = {.Focus}})
	defer draw_element_pop(table)

	// Bottom hairline across the full tab strip.
	draw_rectangle(table, area.x, area.y + area.height - 1, area.width, 1, graphics.colors.track, el)

	cursor_x := area.x
	right_limit := area.x + area.width
	for idx in 0 ..< count {
		if cursor_x >= right_limit {
			break
		}
		is_active := idx == active^
		font := is_active ? FONT_INTERFACE_BOLD : FONT_INTERFACE
		measured := text_measured_width(table, FONT_INTERFACE_BOLD, labels[idx])
		tab_w := min(measured + 2 * TAB_PADDING_X, right_limit - cursor_x)
		tab_area := Area{cursor_x, area.y, tab_w, area.height}
		element_name(frame, tab_area, labels[idx])
		hovered := frame.input.pointer_known && area_contains(tab_area, frame.input.pointer_x, frame.input.pointer_y)
		if hovered && frame.input.pressed {
			active^ = idx
			result.activated = true
			is_active = true
			font = FONT_INTERFACE_BOLD
		}
		tab_id := u32(identity_with(element, idx))
		draw_element_push(table, tab_area, tab_id, .Tab, {
			states          = is_active ? {.Selected} : {},
			actions         = {.Select},
			name            = labels[idx],
			position_in_set = u32(idx + 1),
			set_size        = u32(count),
		})
		if is_active {
			draw_rectangle(table, tab_area.x, tab_area.y, tab_area.width, tab_area.height - TAB_ACCENT_HEIGHT, graphics.colors.card_top, tab_id)
			draw_rectangle(table, tab_area.x, tab_area.y + tab_area.height - TAB_ACCENT_HEIGHT, tab_area.width, TAB_ACCENT_HEIGHT, graphics.colors.title, tab_id)
		} else if hovered {
			draw_rectangle(table, tab_area.x, tab_area.y, tab_area.width, tab_area.height - 1, graphics.colors.track, tab_id)
		}
		shown := text_fit(table, font, labels[idx], max(tab_area.width - 8, 0))
		tw := text_measured_width(table, font, shown)
		tx := tab_area.x + max((tab_area.width - tw) / 2, 4)
		ty := tab_area.y + (tab_area.height - LINE) / 2
		draw_text(table, tx, ty, shown, is_active ? graphics.colors.text_strong : (hovered ? graphics.colors.text : graphics.colors.dim), font, tab_id)
		draw_element_pop(table)
		cursor_x += tab_w + 2
	}

	result.changed = active^ != before
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// slider draws an interactive horizontal slider supporting pointer click,
// continuous pointer drag, and keyboard Left/Right/Home/End stepping.
slider :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, value: ^int, min_val, max_val: int, step := 1, disabled := false, name := "slider") -> (result: Element_Result) {
	if value == nil || max_val <= min_val || area.width < SLIDER_THUMB_WIDTH || area.height <= 0 {
		return
	}
	eff_step := max(step, 1)
	value^ = clamp(value^, min_val, max_val)
	before := value^

	if !disabled {
		result = element_interact(frame, element, area, .List)
	}
	dragging := !disabled && frame.state.pressed == element && frame.input.button_held
	track_left := area.x + SLIDER_THUMB_WIDTH / 2
	track_w := max(area.width - SLIDER_THUMB_WIDTH, 1)
	span := max_val - min_val

	if !disabled && (dragging || (result.under_pointer && frame.input.pressed)) && frame.input.pointer_known {
		rel := clamp(frame.input.pointer_x - track_left, 0, track_w)
		raw := min_val + int((i64(rel) * i64(span) + i64(track_w / 2)) / i64(track_w))
		snapped := min_val + ((raw - min_val + eff_step / 2) / eff_step) * eff_step
		value^ = clamp(snapped, min_val, max_val)
	}
	if result.focused && !disabled {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch key.code {
			case display.KEY_LEFT:
				value^ = clamp(value^ - eff_step, min_val, max_val)
				key.taken = true
			case display.KEY_RIGHT:
				value^ = clamp(value^ + eff_step, min_val, max_val)
				key.taken = true
			case display.KEY_HOME:
				value^ = min_val
				key.taken = true
			case display.KEY_END:
				value^ = max_val
				key.taken = true
			}
		}
	}
	result.changed = value^ != before

	table := frame.table
	el := u32(element)
	states: accessibility.Element_States
	actions: accessibility.Element_Actions
	if disabled {
		states += {.Disabled}
	} else {
		states += {.Focusable}
		actions = {.Focus, .Increment, .Decrement}
		if result.focused {
			states += {.Focused}
		}
	}
	draw_element_push(table, area, el, .Slider, {
		states            = states,
		actions           = actions,
		name              = name,
		has_value_now     = true,
		value_now         = i64(value^),
		has_value_minimum = true,
		value_minimum     = i64(min_val),
		has_value_maximum = true,
		value_maximum     = i64(max_val),
	})
	defer draw_element_pop(table)

	track_y := area.y + (area.height - SLIDER_TRACK_HEIGHT) / 2
	fill_w := int(i64(value^ - min_val) * i64(track_w) / i64(span))
	draw_rectangle(table, track_left, track_y, track_w, SLIDER_TRACK_HEIGHT, graphics.colors.track, el)
	if fill_w > 0 {
		fill_col := disabled ? graphics.colors.not_usable : graphics.colors.chosen
		draw_vertical_gradient(table, track_left, track_y, fill_w, SLIDER_TRACK_HEIGHT, graphics.shade(fill_col, 120), graphics.shade(fill_col, 84), el)
	}

	thumb_x := track_left + fill_w - SLIDER_THUMB_WIDTH / 2
	thumb_y := area.y + (area.height - SLIDER_THUMB_HEIGHT) / 2
	thumb_bg := disabled ? graphics.colors.not_usable : (dragging ? graphics.colors.chosen : (result.under_pointer ? graphics.colors.text_strong : graphics.colors.text))
	draw_rectangle(table, thumb_x, thumb_y, SLIDER_THUMB_WIDTH, SLIDER_THUMB_HEIGHT, thumb_bg, el)
	draw_outline(table, thumb_x, thumb_y, SLIDER_THUMB_WIDTH, SLIDER_THUMB_HEIGHT, 1, dragging || result.under_pointer ? graphics.colors.title : graphics.colors.edge, el)

	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// badge draws a compact rectangular status or category tag with a 3 px left
// accent bar and high-contrast caption text in both dark and light appearances.
badge :: proc "contextless" (frame: ^Frame, area: Area, text: string, accent: graphics.Color) {
	if area.width <= 0 || area.height <= 0 {
		return
	}
	table := frame.table
	bg := graphics.mix(graphics.colors.card_top, accent, 18)
	border := graphics.mix(graphics.colors.card_top, accent, 55)
	draw_rectangle(table, area.x, area.y, area.width, area.height, bg)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, border)
	draw_rectangle(table, area.x, area.y, min(3, area.width), area.height, accent)
	if text != "" && area.width > 10 {
		shown := text_fit(table, FONT_CAPTION, text, area.width - 10)
		ty := area.y + (area.height - line_height(FONT_CAPTION)) / 2
		draw_text(table, area.x + 7, ty, shown, graphics.colors.text, FONT_CAPTION)
	}
}

// reorder_list_move_entry moves order[from] to index to, shifting intervening
// elements while preserving the exact permutation.
reorder_list_move_entry :: proc "contextless" (order: []int, from, to: int) -> bool {
	if from == to || from < 0 || from >= len(order) || to < 0 || to >= len(order) {
		return false
	}
	moved := order[from]
	if from < to {
		for i := from; i < to; i += 1 {
			order[i] = order[i + 1]
		}
	} else {
		for i := from; i > to; i -= 1 {
			order[i] = order[i - 1]
		}
	}
	order[to] = moved
	return true
}

// reorder_list draws a drag-and-drop reorderable list over caller-owned order.
// Dragging any row past REORDER_DRAG_THRESHOLD shows a live insertion bar and
// floating row preview; releasing commits the new order. Alt+Up / Alt+Down
// reorders the selected item via keyboard.
reorder_list :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, labels: []string, order: []int, selected: ^int, drag: ^Reorder_Drag_State, name := "reorderable list") -> (result: Element_Result) {
	count := len(order)
	if selected == nil || drag == nil || count <= 0 || area.width <= 0 || area.height <= 0 {
		return
	}
	selected^ = clamp(selected^, 0, count - 1)
	result = element_interact(frame, element, area, .List)

	// Keyboard navigation and Alt+Up / Alt+Down reordering.
	if result.focused {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			alt := key.modifiers & display.MODIFIER_ALT != 0
			switch key.code {
			case display.KEY_UP:
				key.taken = true
				if alt && selected^ > 0 {
					if reorder_list_move_entry(order, selected^, selected^ - 1) {
						selected^ -= 1
						result.changed = true
					}
				} else if !alt && selected^ > 0 {
					selected^ -= 1
				}
			case display.KEY_DOWN:
				key.taken = true
				if alt && selected^ + 1 < count {
					if reorder_list_move_entry(order, selected^, selected^ + 1) {
						selected^ += 1
						result.changed = true
					}
				} else if !alt && selected^ + 1 < count {
					selected^ += 1
				}
			}
		}
	}

	// Pointer press, drag-threshold activation, live target tracking, and drop.
	input := frame.input
	visible_rows := min(count, max(area.height / REORDER_ROW_HEIGHT, 1))
	if input.pointer_known {
		if input.pressed && area_contains(area, input.pointer_x, input.pointer_y) {
			row := (input.pointer_y - area.y) / REORDER_ROW_HEIGHT
			if row >= 0 && row < visible_rows {
				selected^ = row
				drag^ = {
					pressing   = true,
					dragging   = false,
					source_row = row,
					target_row = row,
					grab_y     = input.pointer_y,
					pointer_y  = input.pointer_y,
				}
			}
		} else if drag.pressing && input.button_held {
			drag.pointer_y = input.pointer_y
			delta := input.pointer_y - drag.grab_y
			if delta < 0 {
				delta = -delta
			}
			if delta >= REORDER_DRAG_THRESHOLD {
				drag.dragging = true
			}
			if drag.dragging {
				row := clamp((input.pointer_y - area.y) / REORDER_ROW_HEIGHT, 0, visible_rows - 1)
				drag.target_row = row
			}
		} else if drag.pressing && !input.button_held {
			if drag.dragging && drag.target_row != drag.source_row {
				if reorder_list_move_entry(order, drag.source_row, drag.target_row) {
					selected^ = drag.target_row
					result.changed = true
				}
			}
			drag^ = {}
		}
	} else if !input.button_held && drag.pressing {
		drag^ = {}
	}

	table := frame.table
	el := u32(element)
	list_states := accessibility.Element_States{.Focusable}
	if result.focused {
		list_states += {.Focused}
	}
	draw_element_push(table, area, el, .List_Box, {states = list_states, actions = {.Focus, .Press}, name = name})
	defer draw_element_pop(table)
	draw_clip_push(table, area.x, area.y, area.width, area.height)
	defer draw_clip_pop(table)

	for row in 0 ..< visible_rows {
		ry := area.y + row * REORDER_ROW_HEIGHT
		item_idx := order[row]
		label := (item_idx >= 0 && item_idx < len(labels)) ? labels[item_idx] : ""
		row_area := Area{area.x, ry, area.width, REORDER_ROW_HEIGHT}
		row_id := u32(identity_with(element, row))
		is_source := drag.dragging && row == drag.source_row
		is_selected := row == selected^ && !drag.dragging
		is_hovered := !drag.dragging && input.pointer_known && area_contains(row_area, input.pointer_x, input.pointer_y)

		draw_element_push(table, row_area, row_id, .Option, {
			states          = is_selected ? {.Selected} : {},
			actions         = {.Select},
			name            = label,
			position_in_set = u32(row + 1),
			set_size        = u32(count),
		})
		switch {
		case is_source:
			draw_rectangle(table, area.x, ry + 1, area.width, REORDER_ROW_HEIGHT - 2, graphics.colors.recess, row_id)
			draw_outline(table, area.x, ry + 1, area.width, REORDER_ROW_HEIGHT - 2, 1, graphics.colors.track, row_id)
		case is_selected:
			draw_vertical_gradient(table, area.x, ry + 1, area.width, REORDER_ROW_HEIGHT - 2, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86), row_id)
		case is_hovered:
			draw_rectangle(table, area.x, ry + 1, area.width, REORDER_ROW_HEIGHT - 2, graphics.colors.track, row_id)
		case:
			draw_rectangle(table, area.x, ry + 1, area.width, REORDER_ROW_HEIGHT - 2, row % 2 == 0 ? graphics.colors.card_top : graphics.colors.card_bottom, row_id)
		}

		// Crisp 6-dot rectangular drag grip handle (2 columns x 3 rows of 2 px squares).
		grip_col := is_selected ? graphics.COLOR_WHITE : graphics.colors.dim
		gx := area.x + 8
		gy := ry + (REORDER_ROW_HEIGHT - 10) / 2
		for r in 0 ..< 3 {
			draw_rectangle(table, gx, gy + r * 4, 2, 2, grip_col, row_id)
			draw_rectangle(table, gx + 4, gy + r * 4, 2, 2, grip_col, row_id)
		}

		// Position badge + item label.
		num_buf: Text_Builder
		text_put_number(&num_buf, u64(row + 1))
		text_y := ry + (REORDER_ROW_HEIGHT - LINE) / 2
		draw_text(table, area.x + REORDER_GRIP_WIDTH + 6, text_y, text_of(&num_buf), is_selected ? graphics.COLOR_WHITE : graphics.colors.dim, {}, row_id)
		label_x := area.x + REORDER_GRIP_WIDTH + 24
		shown := text_fit(table, FONT_INTERFACE, label, max(area.x + area.width - label_x - 8, 0))
		label_col := is_source ? graphics.colors.dim : (is_selected ? graphics.COLOR_WHITE : graphics.colors.text)
		draw_text(table, label_x, text_y, shown, label_col, FONT_INTERFACE, row_id)
		draw_element_pop(table)
	}

	// Live drop indicator and floating ghost card during drag.
	if drag.dragging && drag.source_row >= 0 && drag.source_row < visible_rows {
		indicator_y := area.y + drag.target_row * REORDER_ROW_HEIGHT
		if drag.target_row > drag.source_row {
			indicator_y += REORDER_ROW_HEIGHT - 2
		}
		draw_rectangle(table, area.x, indicator_y, area.width, 2, graphics.colors.title, el)
		draw_rectangle(table, area.x, indicator_y - 2, 4, 6, graphics.colors.title, el)
		draw_rectangle(table, area.x + area.width - 4, indicator_y - 2, 4, 6, graphics.colors.title, el)

		ghost_y := clamp(drag.pointer_y - REORDER_ROW_HEIGHT / 2, area.y, max(area.y, area.y + visible_rows * REORDER_ROW_HEIGHT - REORDER_ROW_HEIGHT))
		item_idx := order[drag.source_row]
		ghost_label := (item_idx >= 0 && item_idx < len(labels)) ? labels[item_idx] : ""
		draw_rectangle(table, area.x + 6, ghost_y + 3, max(area.width - 8, 0), REORDER_ROW_HEIGHT - 2, graphics.colors.shadow, el)
		draw_vertical_gradient(table, area.x + 3, ghost_y, max(area.width - 6, 0), REORDER_ROW_HEIGHT - 2, graphics.colors.card_top, graphics.colors.card_bottom, el)
		draw_outline(table, area.x + 3, ghost_y, max(area.width - 6, 0), REORDER_ROW_HEIGHT - 2, 1, graphics.colors.title, el)
		shown := text_fit(table, FONT_INTERFACE_BOLD, ghost_label, max(area.width - REORDER_GRIP_WIDTH - 24, 0))
		draw_text(table, area.x + REORDER_GRIP_WIDTH + 14, ghost_y + (REORDER_ROW_HEIGHT - LINE) / 2, shown, graphics.colors.text_strong, FONT_INTERFACE_BOLD, el)
	}

	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}
