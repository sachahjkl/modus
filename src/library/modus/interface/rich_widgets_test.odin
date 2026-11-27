#+build !freestanding
#+build !modus
package interface

import "core:testing"
import "modus:display"
import "modus:graphics"

@(test)
styled_buttons_and_disabled_refusals :: proc(t: ^testing.T) {
	records: [256]Draw_Record
	text_buf: [2048]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	state: Interface_State
	input: Input

	// Disabled button never enters focus order and never activates on click.
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 12, buttons = display.BUTTON_LEFT})
	frame := frame_begin(&table, &state, &input)
	res_dis := button_styled(&frame, {0, 0, 100, 24}, identity("dis"), "Disabled", .Primary, disabled = true)
	res_ok := button_styled(&frame, {0, 32, 100, 24}, identity("ok"), "Apply", .Primary)
	_ = button_styled(&frame, {0, 64, 100, 24}, identity("ghost"), "Ghost", .Ghost)
	_ = button_styled(&frame, {0, 96, 100, 24}, identity("danger"), "Delete", .Danger)
	_ = button_styled(&frame, {0, 128, 140, 28}, identity("nav"), "Display", .Sidebar_Row, open = true)
	frame_end(&frame)
	testing.expect(t, !res_dis.activated && !res_dis.focused && !res_dis.under_pointer)
	testing.expect_value(t, state.focus_count, 4) // Disabled excluded from Tab order.
	testing.expect(t, !res_ok.activated)

	// Release pointer from disabled area, then press and release on Primary button.
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 12, buttons = 0})
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 40, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input)
	_ = button_styled(&frame, {0, 32, 100, 24}, identity("ok"), "Apply", .Primary)
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 40, buttons = 0})
	frame = frame_begin(&table, &state, &input)
	res_ok = button_styled(&frame, {0, 32, 100, 24}, identity("ok"), "Apply", .Primary)
	frame_end(&frame)
	testing.expect(t, res_ok.activated)
}

@(test)
toggle_switch_segmented_tabs_and_slider :: proc(t: ^testing.T) {
	records: [512]Draw_Record
	text_buf: [4096]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	state: Interface_State
	input: Input

	// Toggle switch click flips bool and disabled refuses click.
	val := false
	_ = input_add(&input, {kind = .Pointer, x = 10, y = 10, buttons = display.BUTTON_LEFT})
	frame := frame_begin(&table, &state, &input)
	_ = toggle_switch(&frame, {0, 0, 200, 24}, identity("sw"), "Grid fit", &val)
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 10, y = 10, buttons = 0})
	frame = frame_begin(&table, &state, &input)
	sw_res := toggle_switch(&frame, {0, 0, 200, 24}, identity("sw"), "Grid fit", &val)
	frame_end(&frame)
	testing.expect(t, sw_res.activated && sw_res.changed && val)

	// Segmented control click & keyboard Right stepping.
	choices := [?]string{"Auto", "Dark", "Light"}
	chosen := 0
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 150, y = 12, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input)
	seg_res := segmented_control(&frame, {0, 0, 240, 26}, identity("seg"), choices[:], &chosen)
	frame_end(&frame)
	testing.expect(t, seg_res.changed && chosen == 1)

	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_RIGHT, pressed = true})
	frame = frame_begin(&table, &state, &input)
	seg_res = segmented_control(&frame, {0, 0, 240, 26}, identity("seg"), choices[:], &chosen)
	frame_end(&frame)
	testing.expect(t, seg_res.changed && chosen == 2)

	// Tab bar keyboard wrapping and click.
	tabs := [?]string{"Controls", "Drag & Drop", "Frame"}
	active_tab := 0
	state.focus = identity("tabs")
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_LEFT, pressed = true})
	frame = frame_begin(&table, &state, &input)
	tab_res := tab_bar(&frame, {0, 0, 400, 30}, identity("tabs"), tabs[:], &active_tab)
	frame_end(&frame)
	testing.expect(t, tab_res.changed && active_tab == 2)

	// Slider drag, bounds clamp, and keyboard Home/End.
	sval := 50
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 150, y = 12, buttons = 0})
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 199, y = 12, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input)
	sl_res := slider(&frame, {0, 0, 200, 24}, identity("sl"), &sval, 0, 100, 5)
	frame_end(&frame)
	testing.expect(t, sl_res.changed && sval == 100)

	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 199, y = 12, buttons = 0})
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_HOME, pressed = true})
	frame = frame_begin(&table, &state, &input)
	sl_res = slider(&frame, {0, 0, 200, 24}, identity("sl"), &sval, 0, 100, 5)
	frame_end(&frame)
	testing.expect(t, sl_res.changed && sval == 0)

	// Badge draws valid non-negative records even on tiny areas.
	frame = frame_begin(&table, &state, &input)
	badge(&frame, {0, 0, 80, 20}, "Active", graphics.colors.process)
	badge(&frame, {0, 0, 0, 0}, "Zero", graphics.colors.kernel)
	frame_end(&frame)
	for rec in table.records[:table.record_count] {
		testing.expect(t, rec.right >= rec.left && rec.bottom >= rec.top)
	}
}

@(test)
reorder_list_drag_drop_and_keyboard :: proc(t: ^testing.T) {
	records: [512]Draw_Record
	text_buf: [4096]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	state: Interface_State
	input: Input

	labels := [?]string{"Alpha", "Beta", "Gamma", "Delta"}
	order := [4]int{0, 1, 2, 3}
	selected := 0
	drag: Reorder_Drag_State
	list_area := Area{0, 0, 260, 4 * REORDER_ROW_HEIGHT}

	// Press row 0 at y = 15, drag down to row 2 (y = 75), release -> order becomes [1, 2, 0, 3].
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 15, buttons = display.BUTTON_LEFT})
	frame := frame_begin(&table, &state, &input)
	_ = reorder_list(&frame, list_area, identity("rl"), labels[:], order[:], &selected, &drag)
	frame_end(&frame)
	testing.expect(t, drag.pressing && !drag.dragging && drag.source_row == 0)

	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 75, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input)
	_ = reorder_list(&frame, list_area, identity("rl"), labels[:], order[:], &selected, &drag)
	frame_end(&frame)
	testing.expect(t, drag.dragging && drag.target_row == 2)

	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 75, buttons = 0})
	frame = frame_begin(&table, &state, &input)
	res := reorder_list(&frame, list_area, identity("rl"), labels[:], order[:], &selected, &drag)
	frame_end(&frame)
	testing.expect(t, res.changed && !drag.dragging && selected == 2)
	testing.expect(t, order[0] == 1 && order[1] == 2 && order[2] == 0 && order[3] == 3)

	// Alt+Up moves selected item (row 2 -> row 1): order becomes [1, 0, 2, 3].
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_UP, modifiers = display.MODIFIER_ALT, pressed = true})
	frame = frame_begin(&table, &state, &input)
	res = reorder_list(&frame, list_area, identity("rl"), labels[:], order[:], &selected, &drag)
	frame_end(&frame)
	testing.expect(t, res.changed && selected == 1)
	testing.expect(t, order[0] == 1 && order[1] == 0 && order[2] == 2 && order[3] == 3)

	// Out-of-bounds move refuses cleanly.
	testing.expect(t, !reorder_list_move_entry(order[:], -1, 2))
	testing.expect(t, !reorder_list_move_entry(order[:], 0, 9))
	testing.expect(t, !reorder_list_move_entry(order[:], 1, 1))
}

@(test)
slider_wheel_fine_step_and_double_click_reset :: proc(t: ^testing.T) {
	records: [256]Draw_Record
	text_buf: [2048]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	state: Interface_State
	input: Input

	val := 50
	area := Area{0, 0, 200, 24}

	// Wheel up (-1) increases by step (5) and consumes wheel.
	_ = input_add(&input, {kind = .Pointer, x = 80, y = 12, wheel = -display.WHEEL_TOWARD_THE_END})
	frame := frame_begin(&table, &state, &input, 100)
	res := slider(&frame, area, identity("slw"), &val, 0, 100, step = 5, default_value = 65)
	frame_end(&frame)
	testing.expect(t, res.changed && val == 55 && input.wheel == 0)

	// Wheel down (+2) decreases by 10.
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 80, y = 12, wheel = 2 * display.WHEEL_TOWARD_THE_END})
	frame = frame_begin(&table, &state, &input, 200)
	res = slider(&frame, area, identity("slw"), &val, 0, 100, step = 5, default_value = 65)
	frame_end(&frame)
	testing.expect(t, res.changed && val == 45 && input.wheel == 0)

	// Focus slider then Shift+Right adjusts by fine step (1), Page_Up by coarse (20).
	state.focus = identity("slw")
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_RIGHT, modifiers = display.MODIFIER_SHIFT, pressed = true})
	frame = frame_begin(&table, &state, &input, 300)
	res = slider(&frame, area, identity("slw"), &val, 0, 100, step = 5, default_value = 65)
	frame_end(&frame)
	testing.expect(t, res.changed && val == 46)

	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_PAGE_UP, pressed = true})
	frame = frame_begin(&table, &state, &input, 350)
	res = slider(&frame, area, identity("slw"), &val, 0, 100, step = 5, default_value = 65)
	frame_end(&frame)
	testing.expect(t, res.changed && val == 66)

	// Double-click at x = 20 within DOUBLE_CLICK_MILLISECONDS resets to default_value (65).
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 12, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input, 500)
	_ = slider(&frame, area, identity("slw"), &val, 0, 100, step = 5, default_value = 65)
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 12, buttons = 0})
	frame = frame_begin(&table, &state, &input, 550)
	_ = slider(&frame, area, identity("slw"), &val, 0, 100, step = 5, default_value = 65)
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = 20, y = 12, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input, 650)
	res = slider(&frame, area, identity("slw"), &val, 0, 100, step = 5, default_value = 65)
	frame_end(&frame)
	testing.expect(t, res.double_clicked && val == 65)
}

@(test)
slider_with_value_inline_edit_and_scrub :: proc(t: ^testing.T) {
	records: [256]Draw_Record
	text_buf: [2048]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	state: Interface_State
	input: Input

	val := 50
	edit: Slider_Edit_State
	area := Area{0, 0, 260, 24}
	box_x := 220 // inside the right-side 68 px value box.

	// Click & release value box enters inline edit mode with replace_next set.
	_ = input_add(&input, {kind = .Pointer, x = box_x, y = 12, buttons = display.BUTTON_LEFT})
	frame := frame_begin(&table, &state, &input, 100)
	_ = slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %", default_value = 65)
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = box_x, y = 12, buttons = 0})
	frame = frame_begin(&table, &state, &input, 120)
	_ = slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %", default_value = 65)
	frame_end(&frame)
	testing.expect(t, edit.editing && edit.replace_next)

	// Typing "84" + Enter replaces "50", commits 84, and exits edit mode.
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, character = '8', pressed = true})
	_ = input_add(&input, {kind = .Key, character = '4', pressed = true})
	_ = input_add(&input, {kind = .Key, code = display.KEY_ENTER, pressed = true})
	frame = frame_begin(&table, &state, &input, 200)
	res := slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %", default_value = 65)
	frame_end(&frame)
	testing.expect(t, res.changed && !edit.editing && val == 84)

	// Re-enter edit, type "999", Escape cancels without mutating value.
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = box_x, y = 12, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input, 800)
	_ = slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %")
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = box_x, y = 12, buttons = 0})
	frame = frame_begin(&table, &state, &input, 820)
	_ = slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %")
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, character = '9', pressed = true})
	_ = input_add(&input, {kind = .Key, code = display.KEY_ESCAPE, pressed = true})
	frame = frame_begin(&table, &state, &input, 860)
	_ = slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %")
	frame_end(&frame)
	testing.expect(t, !edit.editing && val == 84)

	// Drag horizontally left on value box scrubs value down by steps.
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = box_x, y = 12, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input, 1400)
	_ = slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %")
	frame_end(&frame)
	input_clear(&input)
	_ = input_add(&input, {kind = .Pointer, x = box_x - 16, y = 12, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input, 1420)
	res = slider_with_value(&frame, area, identity("sv"), &val, &edit, 0, 100, step = 5, suffix = " %")
	frame_end(&frame)
	testing.expect(t, edit.scrubbing && res.changed && val == 64)
}

@(test)
tab_bar_wheel_and_home_end :: proc(t: ^testing.T) {
	records: [256]Draw_Record
	text_buf: [2048]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	state: Interface_State
	input: Input

	tabs := [?]string{"One", "Two", "Three"}
	active := 0
	area := Area{0, 0, 300, 28}

	// Wheel down advances tab and consumes wheel.
	_ = input_add(&input, {kind = .Pointer, x = 40, y = 14, wheel = display.WHEEL_TOWARD_THE_END})
	frame := frame_begin(&table, &state, &input)
	res := tab_bar(&frame, area, identity("tbw"), tabs[:], &active)
	frame_end(&frame)
	testing.expect(t, res.changed && active == 1 && input.wheel == 0)

	// End key jumps to last tab, Home jumps to first.
	state.focus = identity("tbw")
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_END, pressed = true})
	frame = frame_begin(&table, &state, &input)
	res = tab_bar(&frame, area, identity("tbw"), tabs[:], &active)
	frame_end(&frame)
	testing.expect(t, res.changed && active == 2)

	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_HOME, pressed = true})
	frame = frame_begin(&table, &state, &input)
	res = tab_bar(&frame, area, identity("tbw"), tabs[:], &active)
	frame_end(&frame)
	testing.expect(t, res.changed && active == 0)
}

@(test)
text_input_rich_caret_selection_and_word_edit :: proc(t: ^testing.T) {
	records: [256]Draw_Record
	text_buf: [2048]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	state: Interface_State
	input: Input

	buf: [64]u8
	copy(buf[:], "hello world")
	count := 11
	area := Area{0, 0, 240, 26}
	el := identity("ti_rich")
	state.focus = el

	// Ctrl+Left jumps before "world", then typing "my " inserts mid-line.
	_ = input_add(&input, {kind = .Key, code = display.KEY_LEFT, modifiers = display.MODIFIER_CONTROL, pressed = true})
	_ = input_add(&input, {kind = .Key, character = 'm', pressed = true})
	_ = input_add(&input, {kind = .Key, character = 'y', pressed = true})
	_ = input_add(&input, {kind = .Key, character = ' ', pressed = true})
	frame := frame_begin(&table, &state, &input, 100)
	res := text_input(&frame, area, el, buf[:], &count)
	frame_end(&frame)
	testing.expect(t, res.changed && string(buf[:count]) == "hello my world")

	// Shift+Ctrl+Right selects "world", Delete removes it.
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_RIGHT, modifiers = display.MODIFIER_CONTROL | display.MODIFIER_SHIFT, pressed = true})
	_ = input_add(&input, {kind = .Key, code = display.KEY_DELETE, pressed = true})
	frame = frame_begin(&table, &state, &input, 200)
	res = text_input(&frame, area, el, buf[:], &count)
	frame_end(&frame)
	testing.expect(t, res.changed && string(buf[:count]) == "hello my ")

	// Ctrl+Backspace removes "my ".
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, code = display.KEY_BACKSPACE, modifiers = display.MODIFIER_CONTROL, pressed = true})
	frame = frame_begin(&table, &state, &input, 300)
	res = text_input(&frame, area, el, buf[:], &count)
	frame_end(&frame)
	testing.expect(t, res.changed && string(buf[:count]) == "hello ")

	// Ctrl+A selects all, typing '!' replaces entire line.
	input_clear(&input)
	_ = input_add(&input, {kind = .Key, character = 'a', modifiers = display.MODIFIER_CONTROL, pressed = true})
	_ = input_add(&input, {kind = .Key, character = '!', pressed = true})
	frame = frame_begin(&table, &state, &input, 400)
	res = text_input(&frame, area, el, buf[:], &count)
	frame_end(&frame)
	testing.expect(t, res.changed && string(buf[:count]) == "!")
}
