// Selection, picker, and form controls for modus:interface
// (src/md/features/rich_widgets.md): checkboxes (2-state and indeterminate),
// radio groups, dropdown & searchable combobox, multi-select with removable
// tag chips, numeric stepper, collapsible disclosure headers, and progress bars.
// Every widget resolves colors from theme_current(frame) with zero heap allocation.
package interface

import "modus:contract/accessibility"
import "modus:contract/draw_record"
import "modus:display"
import "modus:graphics"

// Closed set of states for a tri-state checkbox.
Checkbox_State :: enum u8 {
	Unchecked = 0,
	Checked   = 1,
	Mixed     = 2,
}

// Layout direction of a radio_group.
Radio_Direction :: enum u8 {
	Vertical   = 0,
	Horizontal = 1,
}

// Plan value: standard checkbox/radio indicator geometry in logical pixels.
CHECKBOX_BOX_SIZE :: 16
RADIO_BOX_SIZE :: 16
RADIO_MAX_ITEMS :: 16

// Plan value: dropdown/multi-select filter query capacity and visible popup rows.
PICKER_FILTER_CAPACITY :: 32
PICKER_MAX_VISIBLE_ROWS :: 7
PICKER_ROW_HEIGHT :: 24
PICKER_HEADER_HEIGHT :: 28
PICKER_SHADOW_OFFSET :: 3

// Caller-owned state for a dropdown or searchable combobox.
Dropdown_State :: struct {
	open:        bool,
	highlighted: int,
	scroll:      int,
	filter:      [PICKER_FILTER_CAPACITY]u8,
	filter_len:  int,
	trigger:     Area, // Saved by dropdown_trigger for overlay positioning.
}

// Caller-owned state for a multi-select picker with removable tag chips.
Multi_Select_State :: struct {
	open:        bool,
	highlighted: int,
	scroll:      int,
	filter:      [PICKER_FILTER_CAPACITY]u8,
	filter_len:  int,
	trigger:     Area,
}

// Caller-owned state for number_stepper inline typing.
Number_Stepper_State :: struct {
	editing: bool,
	buf:     [SLIDER_EDIT_CAPACITY]u8,
	count:   int,
}

@(private = "file")
picker_ascii_lower :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

// picker_matches_filter checks whether query is a case-insensitive substring of label.
@(private = "file")
picker_matches_filter :: proc "contextless" (query: []u8, label: string) -> bool {
	if len(query) == 0 {
		return true
	}
	if len(query) > len(label) {
		return false
	}
	limit := len(label) - len(query)
	for start := 0; start <= limit; start += 1 {
		ok := true
		for j in 0 ..< len(query) {
			if picker_ascii_lower(label[start + j]) != picker_ascii_lower(query[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// picker_popup_rect places a floating dropdown menu below trigger, flipping
// above trigger when it would cross the bottom of the window.
@(private = "file")
picker_popup_rect :: proc "contextless" (trigger: Area, popup_h, win_w, win_h: int) -> Area {
	w := max(trigger.width, 160)
	x := trigger.x
	if win_w > 0 && x + w > win_w - 4 {
		x = max(win_w - 4 - w, 4)
	}
	y := trigger.y + trigger.height + 2
	if win_h > 0 && y + popup_h > win_h - 4 {
		above := trigger.y - popup_h - 2
		if above >= 4 {
			y = above
		} else {
			y = max(win_h - 4 - popup_h, 4)
		}
	}
	return {x, y, w, popup_h}
}

// checkbox_tri draws a 3-state checkbox (Unchecked, Checked, Mixed). Clicking
// the row or pressing Space/Enter toggles Unchecked/Mixed -> Checked and
// Checked -> Unchecked.
checkbox_tri :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, label: string, state: ^Checkbox_State, disabled := false) -> (result: Element_Result) {
	if frame == nil || state == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	if !disabled {
		result = element_interact(frame, element, area, .Button)
		if result.activated {
			state^ = state^ == .Checked ? .Unchecked : .Checked
			result.changed = true
		}
	}
	element_name(frame, area, label)
	hovered := !disabled && result.under_pointer
	pressed_down := !disabled && frame.state.pressed == element && frame.input.button_held && hovered

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
	toggle := accessibility.Toggle_State.False
	switch state^ {
	case .Unchecked:
		toggle = .False
	case .Checked:
		toggle = .True
	case .Mixed:
		toggle = .Mixed
	}
	el := u32(element)
	table := frame.table
	theme := theme_current(frame)
	draw_element_push(table, area, el, .Checkbox, {
		toggle  = toggle,
		states  = states,
		actions = actions,
		name    = label,
	})
	defer draw_element_pop(table)

	if hovered {
		draw_rectangle(table, area.x, area.y, area.width, area.height, theme.card_top, el)
	}
	bx := area.x + 4
	by := area.y + (area.height - CHECKBOX_BOX_SIZE) / 2
	active := state^ != .Unchecked
	bg: graphics.Color
	border: graphics.Color
	switch {
	case disabled:
		bg = theme.recess
		border = theme.track
	case active:
		bg = pressed_down ? graphics.shade(theme.chosen, 82) : (hovered ? graphics.shade(theme.chosen, 118) : theme.chosen)
		border = theme.accent
	case:
		bg = hovered ? theme.track : theme.recess
		border = hovered ? theme.accent : theme.border
	}
	draw_rectangle(table, bx, by, CHECKBOX_BOX_SIZE, CHECKBOX_BOX_SIZE, bg, el)
	draw_outline(table, bx, by, CHECKBOX_BOX_SIZE, CHECKBOX_BOX_SIZE, 1, border, el)

	mark_col := disabled ? theme.text_dim : theme.text_on_chosen
	switch state^ {
	case .Unchecked:
	case .Checked:
		// Crisp rectangular check mark drawn from two angled segments.
		draw_line(table, bx + 3, by + 8, bx + 6, by + 11, 2, mark_col, el)
		draw_line(table, bx + 6, by + 11, bx + 12, by + 4, 2, mark_col, el)
	case .Mixed:
		draw_rectangle(table, bx + 3, by + 7, CHECKBOX_BOX_SIZE - 6, 2, mark_col, el)
	}

	label_x := bx + CHECKBOX_BOX_SIZE + 8
	label_room := max(area.x + area.width - label_x - 4, 0)
	if label != "" && label_room > 0 {
		shown := text_fit(table, FONT_INTERFACE, label, label_room)
		col := disabled ? theme.text_dim : (hovered ? theme.text_strong : theme.text)
		draw_text(table, label_x, area.y + (area.height - LINE) / 2, shown, col, FONT_INTERFACE, el)
	}
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// checkbox draws a standard 2-state checkbox backed by value^.
checkbox :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, label: string, value: ^bool, disabled := false) -> (result: Element_Result) {
	if value == nil {
		return
	}
	tri: Checkbox_State = value^ ? .Checked : .Unchecked
	result = checkbox_tri(frame, area, element, label, &tri, disabled)
	if result.changed {
		value^ = tri == .Checked
	}
	return
}

// radio_group draws a vertical or horizontal list of mutually exclusive radio
// buttons. Up/Down (or Left/Right) keys move chosen^ when focused.
radio_group :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	labels: []string,
	chosen: ^int,
	direction: Radio_Direction = .Vertical,
	disabled := false,
) -> (result: Element_Result) {
	count := min(len(labels), RADIO_MAX_ITEMS)
	if frame == nil || chosen == nil || count <= 0 || area.width <= 0 || area.height <= 0 {
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
			case display.KEY_UP, display.KEY_LEFT:
				chosen^ = (chosen^ + count - 1) % count
				key.taken = true
			case display.KEY_DOWN, display.KEY_RIGHT:
				chosen^ = (chosen^ + 1) % count
				key.taken = true
			case display.KEY_HOME:
				chosen^ = 0
				key.taken = true
			case display.KEY_END:
				chosen^ = count - 1
				key.taken = true
			}
		}
	}

	table := frame.table
	theme := theme_current(frame)
	el := u32(element)
	g_states: accessibility.Element_States
	if disabled {
		g_states += {.Disabled}
	} else {
		g_states += {.Focusable}
		if result.focused {
			g_states += {.Focused}
		}
	}
	draw_element_push(table, area, el, .Radio_Group, {states = g_states, actions = disabled ? {} : {.Focus}})
	defer draw_element_pop(table)

	row_h := direction == .Vertical ? max(area.height / count, 20) : area.height
	col_w := direction == .Horizontal ? max(area.width / count, 48) : area.width
	for idx in 0 ..< count {
		item_area: Area
		if direction == .Vertical {
			item_area = {area.x, area.y + idx * row_h, area.width, row_h}
		} else {
			sx := area.x + idx * col_w
			sw := idx == count - 1 ? (area.x + area.width - sx) : col_w
			item_area = {sx, area.y, sw, area.height}
		}
		hovered := !disabled && frame.input.pointer_known && area_contains(item_area, frame.input.pointer_x, frame.input.pointer_y)
		if hovered && frame.input.pressed {
			chosen^ = idx
			result.activated = true
		}
		sel := idx == chosen^
		opt_id := u32(identity_with(element, idx))
		draw_element_push(table, item_area, opt_id, .Radio, {
			states          = sel ? {.Selected} : {},
			actions         = disabled ? {} : {.Select},
			name            = labels[idx],
			position_in_set = u32(idx + 1),
			set_size        = u32(count),
		})
		if hovered {
			draw_rectangle(table, item_area.x, item_area.y, item_area.width, item_area.height, theme.card_top, opt_id)
		}
		rx := item_area.x + 4
		ry := item_area.y + (item_area.height - RADIO_BOX_SIZE) / 2
		border := disabled ? theme.track : (sel ? theme.accent : (hovered ? theme.accent : theme.border))
		draw_rectangle(table, rx, ry, RADIO_BOX_SIZE, RADIO_BOX_SIZE, theme.recess, opt_id)
		draw_outline(table, rx, ry, RADIO_BOX_SIZE, RADIO_BOX_SIZE, 1, border, opt_id)
		if sel {
			inner := disabled ? theme.text_dim : theme.chosen
			draw_rectangle(table, rx + 4, ry + 4, RADIO_BOX_SIZE - 8, RADIO_BOX_SIZE - 8, inner, opt_id)
		}
		lx := rx + RADIO_BOX_SIZE + 8
		lroom := max(item_area.x + item_area.width - lx - 4, 0)
		shown := text_fit(table, sel ? FONT_INTERFACE_BOLD : FONT_INTERFACE, labels[idx], lroom)
		col := disabled ? theme.text_dim : (sel ? theme.text_strong : (hovered ? theme.text_strong : theme.text))
		draw_text(table, lx, item_area.y + (item_area.height - LINE) / 2, shown, col, sel ? FONT_INTERFACE_BOLD : FONT_INTERFACE, opt_id)
		draw_element_pop(table)
	}
	result.changed = chosen^ != before
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// dropdown_trigger draws the closed/open trigger button for a single-select
// dropdown or searchable combobox. Pair with dropdown_overlay at the end of the
// frame so the floating list draws above sibling controls.
dropdown_trigger :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	labels: []string,
	selected: ^int,
	state: ^Dropdown_State,
	placeholder := "Choose...",
	disabled := false,
) -> (result: Element_Result) {
	if frame == nil || selected == nil || state == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	state.trigger = area
	if len(labels) > 0 {
		selected^ = clamp(selected^, -1, len(labels) - 1)
	} else {
		selected^ = -1
	}
	if !disabled {
		result = element_interact(frame, element, area, .Button)
		if result.activated {
			state.open = !state.open
			if state.open {
				state.highlighted = max(selected^, 0)
				state.scroll = 0
				state.filter_len = 0
			}
		}
	}
	hovered := !disabled && result.under_pointer
	table := frame.table
	theme := theme_current(frame)
	el := u32(element)
	label_text := (selected^ >= 0 && selected^ < len(labels)) ? labels[selected^] : placeholder
	element_name(frame, area, label_text)

	draw_element_push(table, area, el, .Button, {
		toggle  = state.open ? .True : .False,
		states  = disabled ? {.Disabled} : (result.focused ? {.Focusable, .Focused} : {.Focusable}),
		actions = disabled ? {} : {.Press, .Focus},
		name    = label_text,
	})
	defer draw_element_pop(table)

	bg := disabled ? theme.recess : (state.open ? theme.track : (hovered ? graphics.shade(theme.track, 114) : theme.recess))
	border := disabled ? theme.track : (state.open || hovered || result.focused ? theme.accent : theme.border)
	draw_rectangle(table, area.x, area.y, area.width, area.height, bg, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, border, el)

	text_room := max(area.width - 28, 0)
	shown := text_fit(table, FONT_INTERFACE, label_text, text_room)
	is_placeholder := selected^ < 0 || selected^ >= len(labels)
	col := disabled || is_placeholder ? theme.text_dim : theme.text_strong
	draw_text(table, area.x + 8, area.y + (area.height - LINE) / 2, shown, col, FONT_INTERFACE, el)

	// Down/Up chevron indicator on right edge.
	cx := area.x + area.width - 14
	cy := area.y + area.height / 2
	chev_col := disabled ? theme.text_dim : (state.open ? theme.accent : theme.text)
	if state.open {
		draw_line(table, cx - 4, cy + 2, cx, cy - 2, 1, chev_col, el)
		draw_line(table, cx, cy - 2, cx + 4, cy + 2, 1, chev_col, el)
	} else {
		draw_line(table, cx - 4, cy - 2, cx, cy + 2, 1, chev_col, el)
		draw_line(table, cx, cy + 2, cx + 4, cy - 2, 1, chev_col, el)
	}
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// dropdown_overlay handles input and renders the floating popup of an open
// dropdown or searchable combobox. Call near the end of frame construction (or
// route overlay input before sibling controls).
dropdown_overlay :: proc "contextless" (
	frame: ^Frame,
	element: Element_Identity,
	labels: []string,
	selected: ^int,
	state: ^Dropdown_State,
	win_w, win_h: int,
	searchable := false,
) -> (changed: bool) {
	if frame == nil || selected == nil || state == nil || !state.open {
		return false
	}
	// Collect filtered item indices (zero allocation).
	MAX_FILTERED :: 128
	matched: [MAX_FILTERED]int
	match_count := 0
	query := state.filter[:state.filter_len]
	for idx in 0 ..< len(labels) {
		if match_count >= MAX_FILTERED {
			break
		}
		if !searchable || picker_matches_filter(query, labels[idx]) {
			matched[match_count] = idx
			match_count += 1
		}
	}
	if match_count > 0 {
		state.highlighted = clamp(state.highlighted, 0, match_count - 1)
	} else {
		state.highlighted = 0
	}

	visible_rows := clamp(max(match_count, 1), 1, PICKER_MAX_VISIBLE_ROWS)
	header_h := searchable ? PICKER_HEADER_HEIGHT : 0
	popup_h := header_h + visible_rows * PICKER_ROW_HEIGHT + 8
	popup := picker_popup_rect(state.trigger, popup_h, win_w, win_h)

	// Keyboard handling when open.
	for &key in frame.input.keys[:frame.input.key_count] {
		if key.taken {
			continue
		}
		switch key.code {
		case display.KEY_ESCAPE:
			state.open = false
			key.taken = true
			return false
		case display.KEY_UP:
			if match_count > 0 {
				state.highlighted = (state.highlighted + match_count - 1) % match_count
			}
			key.taken = true
		case display.KEY_DOWN:
			if match_count > 0 {
				state.highlighted = (state.highlighted + 1) % match_count
			}
			key.taken = true
		case display.KEY_HOME:
			state.highlighted = 0
			key.taken = true
		case display.KEY_END:
			if match_count > 0 {
				state.highlighted = match_count - 1
			}
			key.taken = true
		case display.KEY_ENTER:
			if match_count > 0 && state.highlighted >= 0 && state.highlighted < match_count {
				next := matched[state.highlighted]
				if selected^ != next {
					selected^ = next
					changed = true
				}
			}
			state.open = false
			key.taken = true
			return changed
		case display.KEY_BACKSPACE:
			if searchable && state.filter_len > 0 {
				state.filter_len -= 1
				state.highlighted = 0
				state.scroll = 0
				key.taken = true
			}
		case:
			if searchable && key.character >= 0x20 && key.character < 0x7F && state.filter_len < PICKER_FILTER_CAPACITY {
				state.filter[state.filter_len] = u8(key.character)
				state.filter_len += 1
				state.highlighted = 0
				state.scroll = 0
				key.taken = true
			}
		}
	}

	// Keep highlighted row inside scroll window.
	if match_count > visible_rows {
		if state.highlighted < state.scroll {
			state.scroll = state.highlighted
		} else if state.highlighted >= state.scroll + visible_rows {
			state.scroll = state.highlighted - visible_rows + 1
		}
		state.scroll = clamp(state.scroll, 0, match_count - visible_rows)
	} else {
		state.scroll = 0
	}

	// Pointer handling on popup.
	over_popup := frame.input.pointer_known && area_contains(popup, frame.input.pointer_x, frame.input.pointer_y)
	over_trigger := frame.input.pointer_known && area_contains(state.trigger, frame.input.pointer_x, frame.input.pointer_y)
	if over_popup && frame.input.wheel != 0 && match_count > visible_rows {
		state.scroll = clamp(state.scroll + (frame.input.wheel > 0 ? 1 : -1), 0, match_count - visible_rows)
		frame.input.wheel = 0
	}
	if frame.input.pressed && !over_popup && !over_trigger {
		state.open = false
		frame.input.pressed = false
		return false
	}

	// Draw sharp drop shadow and machined card.
	table := frame.table
	theme := theme_current(frame)
	el := u32(identity_in(element, "popup"))
	draw_rectangle_with_alpha(table, popup.x + PICKER_SHADOW_OFFSET, popup.y + PICKER_SHADOW_OFFSET, popup.width, popup.height, draw_record.with_alpha(graphics.COLOR_BLACK, 120), el)
	draw_vertical_gradient(table, popup.x, popup.y, popup.width, popup.height, theme.card_top, theme.card_bottom, el)
	draw_outline(table, popup.x, popup.y, popup.width, popup.height, 1, theme.accent, el)

	y := popup.y + 4
	if searchable {
		box := Area{popup.x + 6, y, popup.width - 12, PICKER_HEADER_HEIGHT - 4}
		draw_rectangle(table, box.x, box.y, box.width, box.height, theme.recess, el)
		draw_outline(table, box.x, box.y, box.width, box.height, 1, theme.border, el)
		qtext := state.filter_len > 0 ? string(state.filter[:state.filter_len]) : "Filter..."
		qcol := state.filter_len > 0 ? theme.text_strong : theme.text_dim
		draw_text(table, box.x + 6, box.y + (box.height - LINE) / 2, text_fit(table, {}, qtext, max(box.width - 12, 0)), qcol, {}, el)
		y += PICKER_HEADER_HEIGHT
	}

	if match_count == 0 {
		draw_text(table, popup.x + 10, y + 4, "No matches", theme.text_dim, FONT_INTERFACE, el)
		return false
	}

	for r in 0 ..< visible_rows {
		m_idx := state.scroll + r
		if m_idx >= match_count {
			break
		}
		item_idx := matched[m_idx]
		row_area := Area{popup.x + 4, y + r * PICKER_ROW_HEIGHT, popup.width - 8, PICKER_ROW_HEIGHT}
		row_hot := frame.input.pointer_known && area_contains(row_area, frame.input.pointer_x, frame.input.pointer_y)
		if row_hot {
			state.highlighted = m_idx
			if frame.input.pressed {
				if selected^ != item_idx {
					selected^ = item_idx
					changed = true
				}
				state.open = false
				frame.input.pressed = false
			}
		}
		is_hi := m_idx == state.highlighted
		is_sel := item_idx == selected^
		if is_hi {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.chosen, el)
		} else if is_sel {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.track, el)
		}
		if is_sel {
			draw_rectangle(table, row_area.x, row_area.y + 4, 3, row_area.height - 8, is_hi ? theme.text_on_chosen : theme.accent, el)
		}
		col := is_hi ? theme.text_on_chosen : (is_sel ? theme.text_strong : theme.text)
		font := is_sel ? FONT_INTERFACE_BOLD : FONT_INTERFACE
		shown := text_fit(table, font, labels[item_idx], max(row_area.width - 18, 0))
		draw_text(table, row_area.x + 10, row_area.y + (row_area.height - LINE) / 2, shown, col, font, el)
	}
	if over_popup && frame.input.pressed {
		frame.input.pressed = false
	}
	return changed
}

// multi_select_trigger draws a multi-select field showing removable tag chips
// for every selected item (with "x" buttons and "+N" overflow badge).
multi_select_trigger :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	labels: []string,
	selected: []bool,
	state: ^Multi_Select_State,
	placeholder := "Select items...",
	disabled := false,
) -> (result: Element_Result) {
	if frame == nil || state == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	state.trigger = area
	n := min(len(labels), len(selected))

	table := frame.table
	theme := theme_current(frame)
	el := u32(element)
	hovered := !disabled && frame.input.pointer_known && area_contains(area, frame.input.pointer_x, frame.input.pointer_y)

	// Measure and place tag chips first so clicking a chip's "x" removes the
	// item without toggling the popup.
	chip_removed := false
	chip_x := area.x + 6
	chip_y := area.y + (area.height - 18) / 2
	chip_limit := area.x + area.width - 26
	selected_count := 0
	for i in 0 ..< n {
		if selected[i] {
			selected_count += 1
		}
	}

	// Draw trigger container.
	bg := disabled ? theme.recess : (state.open ? theme.track : theme.recess)
	border := disabled ? theme.track : (state.open || hovered ? theme.accent : theme.border)
	draw_rectangle(table, area.x, area.y, area.width, area.height, bg, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, border, el)

	if selected_count == 0 {
		draw_text(table, area.x + 8, area.y + (area.height - LINE) / 2, text_fit(table, FONT_INTERFACE, placeholder, max(area.width - 30, 0)), theme.text_dim, FONT_INTERFACE, el)
	} else {
		shown_chips := 0
		for i in 0 ..< n {
			if !selected[i] {
				continue
			}
			tw := text_measured_width(table, FONT_CAPTION, labels[i])
			cw := tw + 22
			remaining := selected_count - shown_chips
			reserve := remaining > 1 ? 34 : 0
			if chip_x + cw + reserve > chip_limit && shown_chips > 0 {
				// Draw "+N" overflow chip.
				more_buf: Text_Builder
				text_put(&more_buf, "+")
				text_put_number(&more_buf, u64(remaining))
				more_str := text_of(&more_buf)
				mw := text_measured_width(table, FONT_CAPTION, more_str) + 10
				draw_rectangle(table, chip_x, chip_y, mw, 18, theme.track, el)
				draw_text(table, chip_x + 5, chip_y + 1, more_str, theme.text_strong, FONT_CAPTION, el)
				break
			}
			cw = min(cw, max(chip_limit - chip_x, 28))
			chip_area := Area{chip_x, chip_y, cw, 18}
			close_area := Area{chip_x + cw - 15, chip_y, 15, 18}
			close_hot := !disabled && frame.input.pointer_known && area_contains(close_area, frame.input.pointer_x, frame.input.pointer_y)
			if close_hot && frame.input.pressed {
				selected[i] = false
				chip_removed = true
				result.changed = true
				frame.input.pressed = false
				continue
			}
			draw_rectangle(table, chip_area.x, chip_area.y, chip_area.width, chip_area.height, graphics.shade(theme.chosen, 72), el)
			draw_outline(table, chip_area.x, chip_area.y, chip_area.width, chip_area.height, 1, theme.accent, el)
			draw_text(table, chip_area.x + 5, chip_area.y + 1, text_fit(table, FONT_CAPTION, labels[i], max(cw - 19, 0)), theme.text_on_chosen, FONT_CAPTION, el)
			draw_text(table, close_area.x + 4, close_area.y + 1, "x", close_hot ? theme.danger : theme.text_on_chosen, FONT_CAPTION, el)
			chip_x += cw + 4
			shown_chips += 1
		}
	}

	// Chevron at right edge.
	cx := area.x + area.width - 14
	cy := area.y + area.height / 2
	chev_col := disabled ? theme.text_dim : (state.open ? theme.accent : theme.text)
	if state.open {
		draw_line(table, cx - 4, cy + 2, cx, cy - 2, 1, chev_col, el)
		draw_line(table, cx, cy - 2, cx + 4, cy + 2, 1, chev_col, el)
	} else {
		draw_line(table, cx - 4, cy - 2, cx, cy + 2, 1, chev_col, el)
		draw_line(table, cx, cy + 2, cx + 4, cy - 2, 1, chev_col, el)
	}

	if !disabled && !chip_removed {
		interact := element_interact(frame, element, area, .Button)
		result.focused = interact.focused
		result.under_pointer = interact.under_pointer
		result.activated = interact.activated
		if interact.activated {
			state.open = !state.open
			if state.open {
				state.highlighted = 0
				state.scroll = 0
				state.filter_len = 0
			}
		}
		// Backspace removes the last selected chip when focused and closed.
		if result.focused && !state.open {
			for &key in frame.input.keys[:frame.input.key_count] {
				if !key.taken && key.code == display.KEY_BACKSPACE {
					for j := n - 1; j >= 0; j -= 1 {
						if selected[j] {
							selected[j] = false
							result.changed = true
							key.taken = true
							break
						}
					}
				}
			}
		}
	}
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// multi_select_overlay handles input and draws the floating checklist popup
// for an open multi_select widget (with live filter and All / Clear actions).
multi_select_overlay :: proc "contextless" (
	frame: ^Frame,
	element: Element_Identity,
	labels: []string,
	selected: []bool,
	state: ^Multi_Select_State,
	win_w, win_h: int,
	searchable := true,
) -> (changed: bool) {
	if frame == nil || state == nil || !state.open {
		return false
	}
	n := min(len(labels), len(selected))
	MAX_FILTERED :: 128
	matched: [MAX_FILTERED]int
	match_count := 0
	query := state.filter[:state.filter_len]
	for idx in 0 ..< n {
		if match_count >= MAX_FILTERED {
			break
		}
		if !searchable || picker_matches_filter(query, labels[idx]) {
			matched[match_count] = idx
			match_count += 1
		}
	}
	if match_count > 0 {
		state.highlighted = clamp(state.highlighted, 0, match_count - 1)
	} else {
		state.highlighted = 0
	}

	visible_rows := clamp(max(match_count, 1), 1, PICKER_MAX_VISIBLE_ROWS)
	header_h := searchable ? PICKER_HEADER_HEIGHT : 0
	footer_h := 26
	popup_h := header_h + visible_rows * PICKER_ROW_HEIGHT + footer_h + 8
	popup := picker_popup_rect(state.trigger, popup_h, win_w, win_h)

	for &key in frame.input.keys[:frame.input.key_count] {
		if key.taken {
			continue
		}
		switch key.code {
		case display.KEY_ESCAPE:
			state.open = false
			key.taken = true
			return false
		case display.KEY_UP:
			if match_count > 0 {
				state.highlighted = (state.highlighted + match_count - 1) % match_count
			}
			key.taken = true
		case display.KEY_DOWN:
			if match_count > 0 {
				state.highlighted = (state.highlighted + 1) % match_count
			}
			key.taken = true
		case display.KEY_ENTER, display.KEY_SPACE:
			if key.code == display.KEY_SPACE && searchable && state.filter_len > 0 {
				// Let space be typed into filter when already filtering.
				if state.filter_len < PICKER_FILTER_CAPACITY {
					state.filter[state.filter_len] = ' '
					state.filter_len += 1
					key.taken = true
				}
			} else if match_count > 0 && state.highlighted >= 0 && state.highlighted < match_count {
				idx := matched[state.highlighted]
				selected[idx] = !selected[idx]
				changed = true
				key.taken = true
			}
		case display.KEY_BACKSPACE:
			if searchable && state.filter_len > 0 {
				state.filter_len -= 1
				state.highlighted = 0
				state.scroll = 0
				key.taken = true
			}
		case:
			if searchable && key.character >= 0x20 && key.character < 0x7F && state.filter_len < PICKER_FILTER_CAPACITY {
				state.filter[state.filter_len] = u8(key.character)
				state.filter_len += 1
				state.highlighted = 0
				state.scroll = 0
				key.taken = true
			}
		}
	}

	if match_count > visible_rows {
		if state.highlighted < state.scroll {
			state.scroll = state.highlighted
		} else if state.highlighted >= state.scroll + visible_rows {
			state.scroll = state.highlighted - visible_rows + 1
		}
		state.scroll = clamp(state.scroll, 0, match_count - visible_rows)
	} else {
		state.scroll = 0
	}

	over_popup := frame.input.pointer_known && area_contains(popup, frame.input.pointer_x, frame.input.pointer_y)
	over_trigger := frame.input.pointer_known && area_contains(state.trigger, frame.input.pointer_x, frame.input.pointer_y)
	if over_popup && frame.input.wheel != 0 && match_count > visible_rows {
		state.scroll = clamp(state.scroll + (frame.input.wheel > 0 ? 1 : -1), 0, match_count - visible_rows)
		frame.input.wheel = 0
	}
	if frame.input.pressed && !over_popup && !over_trigger {
		state.open = false
		frame.input.pressed = false
		return changed
	}

	table := frame.table
	theme := theme_current(frame)
	el := u32(identity_in(element, "multi_popup"))
	draw_rectangle_with_alpha(table, popup.x + PICKER_SHADOW_OFFSET, popup.y + PICKER_SHADOW_OFFSET, popup.width, popup.height, draw_record.with_alpha(graphics.COLOR_BLACK, 120), el)
	draw_vertical_gradient(table, popup.x, popup.y, popup.width, popup.height, theme.card_top, theme.card_bottom, el)
	draw_outline(table, popup.x, popup.y, popup.width, popup.height, 1, theme.accent, el)

	y := popup.y + 4
	if searchable {
		box := Area{popup.x + 6, y, popup.width - 12, PICKER_HEADER_HEIGHT - 4}
		draw_rectangle(table, box.x, box.y, box.width, box.height, theme.recess, el)
		draw_outline(table, box.x, box.y, box.width, box.height, 1, theme.border, el)
		qtext := state.filter_len > 0 ? string(state.filter[:state.filter_len]) : "Filter options..."
		qcol := state.filter_len > 0 ? theme.text_strong : theme.text_dim
		draw_text(table, box.x + 6, box.y + (box.height - LINE) / 2, text_fit(table, {}, qtext, max(box.width - 12, 0)), qcol, {}, el)
		y += PICKER_HEADER_HEIGHT
	}

	for r in 0 ..< visible_rows {
		m_idx := state.scroll + r
		if m_idx >= match_count {
			break
		}
		item_idx := matched[m_idx]
		row_area := Area{popup.x + 4, y + r * PICKER_ROW_HEIGHT, popup.width - 8, PICKER_ROW_HEIGHT}
		row_hot := frame.input.pointer_known && area_contains(row_area, frame.input.pointer_x, frame.input.pointer_y)
		if row_hot {
			state.highlighted = m_idx
			if frame.input.pressed {
				selected[item_idx] = !selected[item_idx]
				changed = true
				frame.input.pressed = false
			}
		}
		is_hi := m_idx == state.highlighted
		is_sel := selected[item_idx]
		if is_hi {
			draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, theme.track, el)
		}
		// Mini checkbox inside each row.
		bx := row_area.x + 6
		by := row_area.y + (row_area.height - 14) / 2
		draw_rectangle(table, bx, by, 14, 14, is_sel ? theme.chosen : theme.recess, el)
		draw_outline(table, bx, by, 14, 14, 1, is_sel ? theme.accent : theme.border, el)
		if is_sel {
			draw_line(table, bx + 3, by + 7, bx + 6, by + 10, 2, theme.text_on_chosen, el)
			draw_line(table, bx + 6, by + 10, bx + 11, by + 3, 2, theme.text_on_chosen, el)
		}
		shown := text_fit(table, is_sel ? FONT_INTERFACE_BOLD : FONT_INTERFACE, labels[item_idx], max(row_area.width - 30, 0))
		draw_text(table, bx + 20, row_area.y + (row_area.height - LINE) / 2, shown, is_sel ? theme.text_strong : theme.text, is_sel ? FONT_INTERFACE_BOLD : FONT_INTERFACE, el)
	}

	// Footer row: All | Clear | Done.
	fy := popup.y + popup.height - footer_h - 2
	draw_rectangle(table, popup.x + 4, fy - 2, popup.width - 8, 1, theme.divider, el)
	all_area := Area{popup.x + 6, fy + 2, 48, 20}
	clr_area := Area{popup.x + 58, fy + 2, 54, 20}
	done_area := Area{popup.x + popup.width - 56, fy + 2, 50, 20}
	if frame.input.pointer_known && frame.input.pressed {
		switch {
		case area_contains(all_area, frame.input.pointer_x, frame.input.pointer_y):
			for i in 0 ..< n {
				if !selected[i] {
					selected[i] = true
					changed = true
				}
			}
			frame.input.pressed = false
		case area_contains(clr_area, frame.input.pointer_x, frame.input.pointer_y):
			for i in 0 ..< n {
				if selected[i] {
					selected[i] = false
					changed = true
				}
			}
			frame.input.pressed = false
		case area_contains(done_area, frame.input.pointer_x, frame.input.pointer_y):
			state.open = false
			frame.input.pressed = false
		}
	}
	draw_rectangle(table, all_area.x, all_area.y, all_area.width, all_area.height, theme.track, el)
	draw_text(table, all_area.x + 12, all_area.y + 2, "All", theme.text, FONT_CAPTION, el)
	draw_rectangle(table, clr_area.x, clr_area.y, clr_area.width, clr_area.height, theme.track, el)
	draw_text(table, clr_area.x + 10, clr_area.y + 2, "Clear", theme.text, FONT_CAPTION, el)
	draw_rectangle(table, done_area.x, done_area.y, done_area.width, done_area.height, theme.chosen, el)
	draw_text(table, done_area.x + 10, done_area.y + 2, "Done", theme.text_on_chosen, FONT_CAPTION, el)

	if over_popup && frame.input.pressed {
		frame.input.pressed = false
	}
	return changed
}

// number_stepper draws a numeric control with "-" and "+" buttons, wheel
// stepping, and Shift coarse steps (10x step), clamped to [min_val, max_val].
number_stepper :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	value: ^int,
	min_val, max_val: int,
	step := 1,
	suffix := "",
	disabled := false,
) -> (result: Element_Result) {
	if frame == nil || value == nil || area.width <= 0 || area.height <= 0 || max_val < min_val {
		return
	}
	step_n := max(step, 1)
	value^ = clamp(value^, min_val, max_val)
	before := value^

	btn_w := clamp(area.height, 22, 30)
	if area.width < 2 * btn_w + 24 {
		btn_w = max(area.width / 4, 16)
	}
	dec_area := Area{area.x, area.y, btn_w, area.height}
	inc_area := Area{area.x + area.width - btn_w, area.y, btn_w, area.height}
	val_area := Area{area.x + btn_w, area.y, max(area.width - 2 * btn_w, 0), area.height}

	if !disabled {
		result = element_interact(frame, element, area, .List)
		if result.focused {
			for &key in frame.input.keys[:frame.input.key_count] {
				if key.taken {
					continue
				}
				mult := key.modifiers & display.MODIFIER_SHIFT != 0 ? 10 : 1
				switch key.code {
				case display.KEY_UP, display.KEY_RIGHT:
					value^ = clamp(value^ + step_n * mult, min_val, max_val)
					key.taken = true
				case display.KEY_DOWN, display.KEY_LEFT:
					value^ = clamp(value^ - step_n * mult, min_val, max_val)
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
		if result.under_pointer && frame.input.wheel != 0 {
			delta := frame.input.wheel > 0 ? -step_n : step_n
			value^ = clamp(value^ + delta, min_val, max_val)
			frame.input.wheel = 0
		}
	}

	table := frame.table
	theme := theme_current(frame)
	el := u32(element)
	at_min := value^ <= min_val
	at_max := value^ >= max_val

	dec_hot := !disabled && !at_min && frame.input.pointer_known && area_contains(dec_area, frame.input.pointer_x, frame.input.pointer_y)
	inc_hot := !disabled && !at_max && frame.input.pointer_known && area_contains(inc_area, frame.input.pointer_x, frame.input.pointer_y)
	if dec_hot && frame.input.pressed {
		value^ = clamp(value^ - step_n, min_val, max_val)
		result.activated = true
	}
	if inc_hot && frame.input.pressed {
		value^ = clamp(value^ + step_n, min_val, max_val)
		result.activated = true
	}

	// Center readout + outer frame.
	draw_rectangle(table, area.x, area.y, area.width, area.height, theme.recess, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, disabled ? theme.track : (result.focused ? theme.accent : theme.border), el)

	// "-" button.
	draw_rectangle(table, dec_area.x + 1, dec_area.y + 1, max(dec_area.width - 1, 0), max(dec_area.height - 2, 0), dec_hot ? theme.hover : theme.track, el)
	draw_rectangle(table, dec_area.x + dec_area.width - 1, dec_area.y + 1, 1, max(dec_area.height - 2, 0), theme.divider, el)
	draw_text(table, dec_area.x + (dec_area.width - 8) / 2, dec_area.y + (dec_area.height - LINE) / 2, "-", (disabled || at_min) ? theme.text_dim : (dec_hot ? theme.text_on_chosen : theme.text_strong), FONT_INTERFACE_BOLD, el)

	// "+" button.
	draw_rectangle(table, inc_area.x, inc_area.y + 1, max(inc_area.width - 1, 0), max(inc_area.height - 2, 0), inc_hot ? theme.hover : theme.track, el)
	draw_rectangle(table, inc_area.x, inc_area.y + 1, 1, max(inc_area.height - 2, 0), theme.divider, el)
	draw_text(table, inc_area.x + (inc_area.width - 8) / 2, inc_area.y + (inc_area.height - LINE) / 2, "+", (disabled || at_max) ? theme.text_dim : (inc_hot ? theme.text_on_chosen : theme.text_strong), FONT_INTERFACE_BOLD, el)

	// Formatted value centered in val_area.
	buf: Text_Builder
	if value^ < 0 {
		text_put(&buf, "-")
		text_put_number(&buf, u64(-value^))
	} else {
		text_put_number(&buf, u64(value^))
	}
	if suffix != "" {
		text_put(&buf, suffix)
	}
	vstr := text_of(&buf)
	shown := text_fit(table, {}, vstr, max(val_area.width - 8, 0))
	tw := text_measured_width(table, {}, shown)
	draw_text(table, val_area.x + max((val_area.width - tw) / 2, 2), val_area.y + (val_area.height - LINE) / 2, shown, disabled ? theme.text_dim : theme.text_strong, {}, el)

	result.changed = value^ != before
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// disclosure draws a collapsible section header with chevron indicator and
// optional summary text on the right. Clicking or pressing Space/Enter toggles
// open^.
disclosure :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	element: Element_Identity,
	title: string,
	open: ^bool,
	summary := "",
) -> (result: Element_Result) {
	if frame == nil || open == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	result = element_interact(frame, element, area, .Button)
	if result.activated {
		open^ = !open^
		result.changed = true
	}
	element_name(frame, area, title)
	hovered := result.under_pointer
	table := frame.table
	theme := theme_current(frame)
	el := u32(element)

	draw_element_push(table, area, el, .Button, {
		toggle  = open^ ? .True : .False,
		states  = result.focused ? {.Focusable, .Focused} : {.Focusable},
		actions = {.Press, .Focus},
		name    = title,
	})
	defer draw_element_pop(table)

	bg := hovered ? theme.track : theme.card_top
	draw_rectangle(table, area.x, area.y, area.width, area.height, bg, el)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, open^ || hovered ? theme.accent : theme.divider, el)

	cx := area.x + 12
	cy := area.y + area.height / 2
	chev_col := open^ ? theme.accent : theme.text_dim
	if open^ {
		draw_line(table, cx - 4, cy - 2, cx, cy + 2, 2, chev_col, el)
		draw_line(table, cx, cy + 2, cx + 4, cy - 2, 2, chev_col, el)
	} else {
		draw_line(table, cx - 2, cy - 4, cx + 2, cy, 2, chev_col, el)
		draw_line(table, cx + 2, cy, cx - 2, cy + 4, 2, chev_col, el)
	}

	right_used := 8
	if summary != "" {
		sw := text_measured_width(table, FONT_CAPTION, summary)
		right_used += sw + 8
		draw_text_right(table, area.x + area.width - 8, area.y + (area.height - LINE) / 2 + 1, summary, theme.text_dim, FONT_CAPTION, el)
	}
	shown := text_fit(table, FONT_INTERFACE_BOLD, title, max(area.width - 26 - right_used, 0))
	draw_text(table, area.x + 24, area.y + (area.height - LINE) / 2, shown, open^ || hovered ? theme.text_strong : theme.text, FONT_INTERFACE_BOLD, el)
	if result.focused {
		draw_focus_ring(table, area, el)
	}
	return
}

// progress_bar draws a determinate or indeterminate progress indicator using
// the active theme. value_percent is clamped to [0, 100]; when indeterminate is
// true, phase_ms drives a smooth sliding highlight bar.
progress_bar :: proc "contextless" (
	frame: ^Frame,
	area: Area,
	value_percent: int,
	indeterminate := false,
	phase_ms: u64 = 0,
	label := "",
) {
	if frame == nil || area.width <= 0 || area.height <= 0 {
		return
	}
	table := frame.table
	theme := theme_current(frame)
	draw_rectangle(table, area.x, area.y, area.width, area.height, theme.recess)
	draw_outline(table, area.x, area.y, area.width, area.height, 1, theme.border)
	inner_w := max(area.width - 2, 0)
	inner_h := max(area.height - 2, 0)
	if inner_w > 0 && inner_h > 0 {
		if indeterminate {
			seg_w := max(inner_w / 3, 18)
			span := inner_w + seg_w
			pos := int((phase_ms / 16) % u64(max(span, 1))) - seg_w
			left := clamp(pos, 0, inner_w)
			right := clamp(pos + seg_w, 0, inner_w)
			if right > left {
				draw_horizontal_gradient(table, area.x + 1 + left, area.y + 1, right - left, inner_h, theme.chosen, theme.accent)
			}
		} else {
			pct := clamp(value_percent, 0, 100)
			fill_w := inner_w * pct / 100
			if fill_w > 0 {
				draw_horizontal_gradient(table, area.x + 1, area.y + 1, fill_w, inner_h, theme.chosen, theme.accent)
			}
		}
	}
	if label != "" && area.height >= LINE {
		shown := text_fit(table, FONT_CAPTION, label, max(area.width - 12, 0))
		tw := text_measured_width(table, FONT_CAPTION, shown)
		draw_text(table, area.x + max((area.width - tw) / 2, 4), area.y + (area.height - LINE) / 2 + 1, shown, theme.text_on_chosen, FONT_CAPTION)
	}
}
