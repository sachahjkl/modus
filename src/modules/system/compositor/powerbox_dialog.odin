// Unforgeable trusted-display Powerbox grant dialog, trusted Store Picker,
// and Wide-Grant active bar mark inside the compositor
// (src/md/features/powerbox.md) and (src/md/features/wide_grants.md).
//
// Drawn directly by the Display role holder above every client window so no
// process can spoof, cover, or click-jack a grant approval, and while a wide
// agent grant is active an unforgeable mark stays visible in the bar and
// revokes immediately on Ctrl+Shift+Escape.
package compositor

import "internal:compositor/bar"
import "modus:contract/powerbox"
import "modus:contract/value_kinds"
import "modus:contract/wide_grants"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

POWERBOX_DIALOG_WIDTH :: 440
POWERBOX_DIALOG_HEIGHT :: 160
POWERBOX_TEXT_LIMIT :: 96
POWERBOX_PICKER_SLOTS :: 4
POWERBOX_TITLE_HEIGHT :: 30 // The title plate, inside the two lines of the frame.
POWERBOX_MARGIN :: 16 // From the frame to the texts, the list and the buttons.
POWERBOX_PICKER_LINE :: 24
POWERBOX_PICKER_ROOM :: POWERBOX_PICKER_SLOTS * POWERBOX_PICKER_LINE + 12 // The list and the room around it.
POWERBOX_BUTTON_HEIGHT :: 26
POWERBOX_BUTTON_PADDING :: 12 // On each side of the text of a button.
POWERBOX_BUTTON_GAP :: 8 // Between two buttons, and between the act and its key in one button.

Powerbox_Prompt_State :: struct {
	open:            bool,
	request_id:      u64,
	kind:            powerbox.Request_Item_Kind,
	process_name:    [POWERBOX_TEXT_LIMIT]u8,
	process_len:     int,
	resource_text:   [POWERBOX_TEXT_LIMIT]u8,
	resource_len:    int,
	picker_selected: int,
	picker_count:    int,
	picker_stores:   [POWERBOX_PICKER_SLOTS]string,
	chosen_store:    string,
	last_decision:   powerbox.Item_Decision,
}

Wide_Grant_Display_State :: struct {
	active:       bool,
	grant_id:     u64,
	authorities:  wide_grants.Wide_Authorities,
	revoked_once: bool,
}

powerbox_prompt: Powerbox_Prompt_State
wide_grant_display: Wide_Grant_Display_State
powerbox_next_id: u64 = 1
// The requested grants that the principal kept and that hold: the menu of
// the windows lists them under the window of their process.
window_grants: bar.Window_Grant_Table
plan_difference_dialog: bar.Plan_Difference_Dialog

// trusted_dialog_open reports whether a dialog of the trusted display
// shows: one at a time, so a key or a press acts on the one that the
// principal sees.
trusted_dialog_open :: proc "contextless" () -> bool {
	return powerbox_prompt.open || plan_difference_dialog.open
}

powerbox_prompt_open :: proc "contextless" (kind: powerbox.Request_Item_Kind, process_name, resource_text: string) -> u64 {
	if len(process_name) == 0 || len(resource_text) == 0 {
		return 0
	}
	id := powerbox_next_id
	powerbox_next_id += 1
	powerbox_prompt = {
		open          = true,
		request_id    = id,
		kind          = kind,
		process_len   = min(len(process_name), POWERBOX_TEXT_LIMIT),
		resource_len  = min(len(resource_text), POWERBOX_TEXT_LIMIT),
		last_decision = .None,
	}
	if kind == .Store_Share {
		// Candidate stores presented ONLY to the principal on the trusted display;
		// the requesting process never sees this list and receives a share of the chosen store only.
		powerbox_prompt.picker_stores = {"documents", "notes", "projects", "downloads"}
		powerbox_prompt.picker_count = 4
		powerbox_prompt.picker_selected = 0
	}
	copy(powerbox_prompt.process_name[:powerbox_prompt.process_len], process_name[:powerbox_prompt.process_len])
	copy(powerbox_prompt.resource_text[:powerbox_prompt.resource_len], resource_text[:powerbox_prompt.resource_len])
	damage_whole_screen()
	return id
}

powerbox_prompt_decide :: proc "contextless" (allow: bool) -> bool {
	if !powerbox_prompt.open {
		return false
	}
	powerbox_prompt.open = false
	if allow && powerbox_prompt.kind == .Store_Share && powerbox_prompt.picker_count > 0 {
		powerbox_prompt.chosen_store = powerbox_prompt.picker_stores[powerbox_prompt.picker_selected]
	} else {
		powerbox_prompt.chosen_store = ""
	}
	powerbox_prompt.last_decision = allow ? .Granted : .Refused
	if allow {
		window_grant_add(string(powerbox_prompt.process_name[:powerbox_prompt.process_len]), string(powerbox_prompt.resource_text[:powerbox_prompt.resource_len]), powerbox_prompt.chosen_store)
	}
	damage_whole_screen()
	return true
}

// window_grant_add records a grant that the principal kept, so the menu
// of the windows lists it. A store names the store that the principal
// picked, then the mode that the process asked for.
window_grant_add :: proc "contextless" (process_name, resource_text, chosen_store: string) {
	resource_bytes: [bar.WINDOW_GRANT_RESOURCE_BYTES + 1]u8 // One more byte: a name past the bound is refused, not cut.
	resource := resource_text
	if len(chosen_store) > 0 {
		length := copy(resource_bytes[:], chosen_store)
		length += copy(resource_bytes[length:], ", ")
		length += copy(resource_bytes[length:], resource_text)
		resource = string(resource_bytes[:length])
	}
	grant_id, refusal := bar.window_grant_record(&window_grants, process_name, resource)
	if refusal != .None {
		system.log_fact(.Warning, Window_Grant_Not_Listed{window = value_kinds.module_name_field(process_name)})
		return
	}
	system.log_fact(.Info, Window_Grant_Recorded{grant = grant_id, resource = value_kinds.text_field(resource, GRANT_RESOURCE_FIELD_BYTES), window = value_kinds.module_name_field(process_name)})
	windows_menu_rows_build() // start_menu.odin
}

// window_grant_revoke ends a requested grant that the menu of the windows
// lists, and gives false when no grant of that number holds. A revocation
// only takes authority away: the trusted display does it at once.
window_grant_revoke :: proc "contextless" (grant_id: u64) -> bool {
	revoked, ok := bar.window_grant_revoke(&window_grants, grant_id)
	if !ok {
		return false
	}
	system.log_fact(.Info, Window_Grant_Revoked{grant = revoked.grant_id, resource = value_kinds.text_field(bar.window_grant_resource(&revoked), GRANT_RESOURCE_FIELD_BYTES), window = value_kinds.module_name_field(bar.window_grant_process(&revoked))})
	windows_menu_rows_build() // start_menu.odin
	return true
}

// window_grants_window_closed ends the grants of the process of a window
// that closed: a grant for this run ends with its process, and a later
// process of the same name must not find them in the menu.
window_grants_window_closed :: proc "contextless" (process_name: string) {
	if ended := bar.window_grants_end_of_process(&window_grants, process_name); ended > 0 {
		system.log_fact(.Info, Window_Grants_Ended{grants = u64(ended), window = value_kinds.module_name_field(process_name)})
	}
}

// plan_difference_show shows the difference of a plan on the trusted
// display, and gives its serial, or 0 with the refusal and the argument
// that it names, from 1.
plan_difference_show :: proc "contextless" (plan_name, added, removed: string) -> (serial: u64, refusal: bar.Plan_Difference_Refusal, argument: int) {
	if powerbox_prompt.open {
		return 0, .Busy, 0
	}
	serial, refusal, argument = bar.plan_difference_open(&plan_difference_dialog, plan_name, added, removed, system.time())
	if refusal != .None {
		return
	}
	system.log_fact(.Info, Plan_Difference_Shown{added = u64(plan_difference_dialog.added_count), removed = u64(plan_difference_dialog.removed_count), plan = value_kinds.text_field(plan_name, PLAN_NAME_FIELD_BYTES)})
	damage_whole_screen()
	return
}

// plan_difference_answer records the decision of the principal, if the
// last key or press made one.
plan_difference_answer :: proc "contextless" (decision: bar.Plan_Difference_Decision) {
	plan := value_kinds.text_field(bar.plan_difference_name(&plan_difference_dialog), PLAN_NAME_FIELD_BYTES)
	switch decision {
	case .Pending:
		return
	case .Accepted:
		system.log_fact(.Info, Plan_Difference_Accepted{plan = plan})
	case .Refused:
		system.log_fact(.Info, Plan_Difference_Refused{plan = plan})
	}
	damage_whole_screen()
}

// plan_difference_pointer gives a press to the dialog of a plan, and
// reports whether the dialog took the pointer: while it shows, no menu and
// no window receives a press or a move.
plan_difference_pointer :: proc "contextless" (pressed: bool) -> bool {
	if !plan_difference_dialog.open {
		return false
	}
	if pressed {
		focus := plan_difference_dialog.focus
		plan_difference_answer(bar.plan_difference_press(&plan_difference_dialog, desktop_width, desktop_work_top(), desktop_work_bottom(), pointer_x, pointer_y, system.time()))
		if plan_difference_dialog.open && plan_difference_dialog.focus != focus {
			damage_whole_screen()
		}
	}
	return true
}

wide_grant_mark_set :: proc "contextless" (active: bool, grant_id: u64) {
	wide_grant_display.active = active
	wide_grant_display.grant_id = active ? grant_id : 0
	if active {
		wide_grant_display.authorities = {.View_Screen, .Send_Input}
	} else {
		wide_grant_display.authorities = {}
	}
	damage_bar()
}

powerbox_and_wide_grant_key :: proc "contextless" (code: u32, pressed: bool, modifiers: u32) -> bool {
	if !pressed {
		return false
	}
	ctrl_shift := u32(display.MODIFIER_CONTROL | display.MODIFIER_SHIFT)
	if wide_grant_display.active && code == display.KEY_ESCAPE && (modifiers & ctrl_shift) == ctrl_shift {
		wide_grant_display.revoked_once = true
		wide_grant_mark_set(false, 0)
		return true
	}
	if plan_difference_dialog.open {
		key: bar.Plan_Difference_Key
		switch code {
		case display.KEY_TAB, display.KEY_LEFT, display.KEY_RIGHT, display.KEY_UP, display.KEY_DOWN:
			key = .Next
		case display.KEY_ENTER:
			key = .Act
		case display.KEY_ESCAPE:
			key = .Escape
		case:
			key = .Other
		}
		focus := plan_difference_dialog.focus
		plan_difference_answer(bar.plan_difference_key(&plan_difference_dialog, key, system.time()))
		if plan_difference_dialog.open && plan_difference_dialog.focus != focus {
			damage_whole_screen()
		}
		return true
	}
	if !powerbox_prompt.open {
		return false
	}
	switch code {
	case display.KEY_UP:
		if powerbox_prompt.kind == .Store_Share && powerbox_prompt.picker_count > 0 {
			powerbox_prompt.picker_selected = (powerbox_prompt.picker_selected + powerbox_prompt.picker_count - 1) % powerbox_prompt.picker_count
			damage_whole_screen()
		}
		return true
	case display.KEY_DOWN:
		if powerbox_prompt.kind == .Store_Share && powerbox_prompt.picker_count > 0 {
			powerbox_prompt.picker_selected = (powerbox_prompt.picker_selected + 1) % powerbox_prompt.picker_count
			damage_whole_screen()
		}
		return true
	case display.KEY_ENTER:
		return powerbox_prompt_decide(true)
	case display.KEY_ESCAPE:
		return powerbox_prompt_decide(false)
	}
	return true
}

powerbox_dialog_records :: proc "contextless" (table: ^interface.Draw_Table) {
	if wide_grant_display.active {
		badge_w := 104
		badge_x := max(0, desktop_width / 2 - badge_w / 2)
		interface.draw_rectangle(table, badge_x, desktop_bar_y() + 3, badge_w, BAR_HEIGHT - 6, graphics.colors.stop_process)
		interface.draw_text(table, badge_x + 8, desktop_bar_y() + 7, "AGENT GRANT", graphics.COLOR_WHITE, interface.FONT_INTERFACE)
	}
	plan_difference_records(table)
	if !powerbox_prompt.open {
		return
	}
	is_picker := powerbox_prompt.kind == .Store_Share
	width := POWERBOX_DIALOG_WIDTH
	height := is_picker ? POWERBOX_DIALOG_HEIGHT + POWERBOX_PICKER_ROOM : POWERBOX_DIALOG_HEIGHT
	// In the middle of the desktop, and never on the bar at either edge.
	x := max(0, (desktop_width - width) / 2)
	y := max(desktop_work_top() + 16, min((desktop_height - height) / 2, desktop_work_bottom() - height - 16))

	trusted_card_records(table, x, y, width, height, is_picker ? "TRUSTED STORE PICKER" : "TRUSTED GRANT REQUEST")

	// The asker and what it asks for.
	text_room := width - 2 * POWERBOX_MARGIN
	body_y := y + 2 + POWERBOX_TITLE_HEIGHT + 1 + 12
	proc_str := string(powerbox_prompt.process_name[:powerbox_prompt.process_len])
	res_str := string(powerbox_prompt.resource_text[:powerbox_prompt.resource_len])
	interface.draw_text(table, x + POWERBOX_MARGIN, body_y, interface.text_fit(table, interface.FONT_INTERFACE, proc_str, text_room), graphics.colors.text_strong, interface.FONT_INTERFACE)
	interface.draw_text(table, x + POWERBOX_MARGIN, body_y + 22, interface.text_fit(table, interface.FONT_INTERFACE, res_str, text_room), graphics.colors.dim, interface.FONT_INTERFACE)

	button_y := y + height - POWERBOX_MARGIN - POWERBOX_BUTTON_HEIGHT
	if is_picker {
		// The stores, in a recessed list with a hairline border; the chosen
		// store is a plate in the gradient of the chosen blue.
		list_x, list_y := x + POWERBOX_MARGIN, body_y + 48
		list_width, list_height := text_room, POWERBOX_PICKER_SLOTS * POWERBOX_PICKER_LINE + 2
		interface.draw_rectangle(table, list_x, list_y, list_width, list_height, graphics.colors.recess)
		interface.draw_outline(table, list_x, list_y, list_width, list_height, 1, graphics.colors.track)
		for i in 0 ..< powerbox_prompt.picker_count {
			ry := list_y + 1 + i * POWERBOX_PICKER_LINE
			sel := i == powerbox_prompt.picker_selected
			if sel {
				interface.draw_vertical_gradient(table, list_x + 1, ry, list_width - 2, POWERBOX_PICKER_LINE, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86))
				interface.draw_rectangle(table, list_x + 2, ry, list_width - 4, 1, graphics.shade(graphics.colors.chosen, 140))
			}
			interface.draw_text(table, list_x + 12, ry + 4, powerbox_prompt.picker_stores[i], sel ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
		}
		interface.draw_text(table, x + POWERBOX_MARGIN, button_y + (POWERBOX_BUTTON_HEIGHT - graphics.CELL_HEIGHT) / 2, "Up/Down: choose", graphics.colors.dim, interface.FONT_INTERFACE)
	}
	// The two acts at the right, the refusal last: each button says its key.
	right := x + width - POWERBOX_MARGIN
	right = powerbox_button_records(table, right, button_y, "Refuse", "Esc", false)
	_ = powerbox_button_records(table, right - POWERBOX_BUTTON_GAP, button_y, is_picker ? "Share" : "Allow", "Enter", true)
}

// trusted_card_records draws the frame of a dialog of the trusted display,
// in the look of a window: a sharp shadow, the outer line of the edge, a
// line of the blue of the title inside it, the cards gradient, and the
// title plate in the gradient of a focused window with its line of light.
// The shadow and the edge are tokens: a shade of the background is near
// black in the light appearance too, a black box there.
@(private = "file")
trusted_card_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, header: string) {
	interface.draw_rectangle(table, x + 4, y + 4, width, height, graphics.colors.shadow)
	interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, x, y, width, height, 1, graphics.colors.edge)
	interface.draw_outline(table, x + 1, y + 1, width - 2, height - 2, 1, graphics.colors.title)
	interface.draw_horizontal_gradient(table, x + 2, y + 2, width - 4, 1, graphics.shade(graphics.colors.title, 125), graphics.shade(graphics.colors.title_end, 125))
	interface.draw_horizontal_gradient(table, x + 2, y + 3, width - 4, POWERBOX_TITLE_HEIGHT - 1, graphics.colors.title, graphics.colors.title_end)
	interface.draw_rectangle(table, x + 2, y + 2 + POWERBOX_TITLE_HEIGHT, width - 4, 1, graphics.colors.edge)
	interface.draw_text(table, x + POWERBOX_MARGIN - 4, y + 2 + (POWERBOX_TITLE_HEIGHT - graphics.CELL_HEIGHT) / 2, header, graphics.COLOR_WHITE, interface.FONT_INTERFACE_BOLD)
}

// plan_difference_records draws the difference of a plan: its name, what
// it adds in the color of an expected answer, what it removes in the coral
// of a failure, each with its sign so the two read apart with no color,
// and the two buttons. The places come from the bar package, as the
// presses that it hit-tests.
@(private = "file")
plan_difference_records :: proc "contextless" (table: ^interface.Draw_Table) {
	dialog := &plan_difference_dialog
	if !dialog.open {
		return
	}
	#assert(bar.PLAN_DIFFERENCE_TITLE_HEIGHT == POWERBOX_TITLE_HEIGHT)
	x, y, width, height := bar.plan_difference_place(dialog, desktop_width, desktop_work_top(), desktop_work_bottom())
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity("plan difference")), .Alert_Dialog, {name = "plan difference"})
	defer interface.draw_element_pop(table)
	trusted_card_records(table, x, y, width, height, "TRUSTED PLAN DIFFERENCE")
	text_x := x + bar.PLAN_DIFFERENCE_MARGIN
	text_room := width - 2 * bar.PLAN_DIFFERENCE_MARGIN
	line_y := y + 2 + bar.PLAN_DIFFERENCE_TITLE_HEIGHT + 1 + bar.PLAN_DIFFERENCE_MARGIN
	text_offset := (bar.PLAN_DIFFERENCE_LINE - graphics.CELL_HEIGHT) / 2
	name_x := interface.draw_text(table, text_x, line_y + text_offset, "plan", graphics.colors.dim, interface.FONT_INTERFACE) + bar.PLAN_DIFFERENCE_GAP
	interface.draw_text(table, name_x, line_y + text_offset, interface.text_fit(table, interface.FONT_INTERFACE_BOLD, bar.plan_difference_name(dialog), x + width - bar.PLAN_DIFFERENCE_MARGIN - name_x), graphics.colors.text_strong, interface.FONT_INTERFACE_BOLD)
	line_y += bar.PLAN_DIFFERENCE_LINE
	sides := [2]struct {
		heading, sign: string,
		items:         []bar.Plan_Difference_Item,
		color:         graphics.Color,
	} {
		{"adds", "+", dialog.added[:dialog.added_count], graphics.colors.process},
		{"removes", "-", dialog.removed[:dialog.removed_count], graphics.colors.failed},
	}
	for &side in sides {
		if len(side.items) == 0 {
			continue
		}
		line_y += bar.PLAN_DIFFERENCE_GAP
		interface.draw_text(table, text_x, line_y + text_offset, side.heading, graphics.colors.dim, interface.FONT_CAPTION)
		line_y += bar.PLAN_DIFFERENCE_LINE
		for &item in side.items {
			item_x := interface.draw_text(table, text_x + 8, line_y + text_offset, side.sign, side.color, interface.FONT_INTERFACE_BOLD) + bar.PLAN_DIFFERENCE_GAP
			shown := interface.text_fit(table, interface.FONT_INTERFACE, bar.plan_difference_item_text(&item), text_x + text_room - item_x)
			interface.draw_text(table, item_x, line_y + text_offset, shown, side.color, interface.FONT_INTERFACE)
			line_y += bar.PLAN_DIFFERENCE_LINE
		}
	}
	accept_x, button_y, button_width, button_height := bar.plan_difference_button_place(x, y, width, height, .Accept)
	refuse_x, _, _, _ := bar.plan_difference_button_place(x, y, width, height, .Refuse)
	interface.draw_text(table, text_x, button_y + (button_height - graphics.CELL_HEIGHT) / 2, "Tab: move", graphics.colors.dim, interface.FONT_INTERFACE)
	plan_difference_button_records(table, accept_x, button_y, button_width, button_height, "Accept plan", "Enter", true, dialog.focus == .Accept)
	plan_difference_button_records(table, refuse_x, button_y, button_width, button_height, "Refuse", "Esc", false, dialog.focus == .Refuse)
}

// plan_difference_button_records draws a button of the dialog of a plan in
// its fixed place, in the look of the buttons of the grant dialog, with
// the ring of the focus on the button that Enter acts on.
@(private = "file")
plan_difference_button_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, act, key: string, grants, focused: bool) {
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity(act)), .Button, {name = act})
	defer interface.draw_element_pop(table)
	if grants {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86))
		interface.draw_outline(table, x, y, width, height, 1, graphics.shade(graphics.colors.chosen, 70))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.chosen, 140))
	} else {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.track, graphics.shade(graphics.colors.track, 88))
		interface.draw_outline(table, x, y, width, height, 1, graphics.shade(graphics.colors.track, 150))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.track, 130))
	}
	text_y := y + (height - graphics.CELL_HEIGHT) / 2
	interface.draw_text(table, x + POWERBOX_BUTTON_PADDING, text_y, act, grants ? graphics.COLOR_WHITE : graphics.colors.text_strong, interface.FONT_INTERFACE)
	interface.draw_text_right(table, x + width - POWERBOX_BUTTON_PADDING, text_y, key, grants ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
	if focused {
		interface.draw_focus_ring(table, {x, y, width, height})
	}
}

// powerbox_button_records draws a button of the dialog that ends at right:
// its act, then its key in a dim text. The act that grants is a plate of
// the chosen blue with a line of light; the refusal is a plate of the track
// with a hairline border. It gives the x of its left edge.
@(private = "file")
powerbox_button_records :: proc "contextless" (table: ^interface.Draw_Table, right, y: int, act, key: string, grants: bool) -> int {
	act_width := interface.text_measured_width(table, interface.FONT_INTERFACE, act)
	key_width := interface.text_measured_width(table, interface.FONT_INTERFACE, key)
	width := act_width + POWERBOX_BUTTON_GAP + key_width + 2 * POWERBOX_BUTTON_PADDING
	left := right - width
	if grants {
		interface.draw_vertical_gradient(table, left, y, width, POWERBOX_BUTTON_HEIGHT, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86))
		interface.draw_outline(table, left, y, width, POWERBOX_BUTTON_HEIGHT, 1, graphics.shade(graphics.colors.chosen, 70))
		interface.draw_rectangle(table, left + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.chosen, 140))
	} else {
		interface.draw_vertical_gradient(table, left, y, width, POWERBOX_BUTTON_HEIGHT, graphics.colors.track, graphics.shade(graphics.colors.track, 88))
		interface.draw_outline(table, left, y, width, POWERBOX_BUTTON_HEIGHT, 1, graphics.shade(graphics.colors.track, 150))
		interface.draw_rectangle(table, left + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.track, 130))
	}
	text_y := y + (POWERBOX_BUTTON_HEIGHT - graphics.CELL_HEIGHT) / 2
	// The act: white on the chosen blue; on the track, the strong text, so
	// the refusal reads on the light track too.
	key_x := interface.draw_text(table, left + POWERBOX_BUTTON_PADDING, text_y, act, grants ? graphics.COLOR_WHITE : graphics.colors.text_strong, interface.FONT_INTERFACE) + POWERBOX_BUTTON_GAP
	// The key in the text color on the track: the dim color has the
	// contrast of a large text only there.
	interface.draw_text(table, key_x, text_y, key, grants ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
	return left
}
