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
