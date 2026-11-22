// Unforgeable trusted-display Powerbox grant dialog, trusted Store Picker,
// and Wide-Grant active bar mark inside the compositor
// (src/md/features/powerbox.md) and (src/md/features/wide_grants.md).
//
// Drawn directly by the Display role holder above every client window so no
// process can spoof, cover, or click-jack a grant approval, and while a wide
// agent grant is active an unforgeable mark stays visible in the bar and
// revokes immediately on Ctrl+Shift+Escape.
package compositor

import "modus:contract/powerbox"
import "modus:contract/wide_grants"
import "modus:display"
import "modus:graphics"
import "modus:interface"

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
	damage_whole_screen()
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
	if !powerbox_prompt.open {
		return
	}
	is_picker := powerbox_prompt.kind == .Store_Share
	width := POWERBOX_DIALOG_WIDTH
	height := is_picker ? POWERBOX_DIALOG_HEIGHT + POWERBOX_PICKER_ROOM : POWERBOX_DIALOG_HEIGHT
	// In the middle of the desktop, and never on the bar at either edge.
	x := max(0, (desktop_width - width) / 2)
	y := max(desktop_work_top() + 16, min((desktop_height - height) / 2, desktop_work_bottom() - height - 16))

	// The frame of a window: a sharp shadow, the outer line of the edge, a
	// line of the blue of the title inside it, the cards gradient, and the
	// title plate in the gradient of a focused window with its line of
	// light. The shadow and the edge are tokens: a shade of the background
	// is near black in the light appearance too, a black box there.
	interface.draw_rectangle(table, x + 4, y + 4, width, height, graphics.colors.shadow)
	interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, x, y, width, height, 1, graphics.colors.edge)
	interface.draw_outline(table, x + 1, y + 1, width - 2, height - 2, 1, graphics.colors.title)
	interface.draw_horizontal_gradient(table, x + 2, y + 2, width - 4, 1, graphics.shade(graphics.colors.title, 125), graphics.shade(graphics.colors.title_end, 125))
	interface.draw_horizontal_gradient(table, x + 2, y + 3, width - 4, POWERBOX_TITLE_HEIGHT - 1, graphics.colors.title, graphics.colors.title_end)
	interface.draw_rectangle(table, x + 2, y + 2 + POWERBOX_TITLE_HEIGHT, width - 4, 1, graphics.colors.edge)
	header := is_picker ? "TRUSTED STORE PICKER" : "TRUSTED GRANT REQUEST"
	interface.draw_text(table, x + POWERBOX_MARGIN - 4, y + 2 + (POWERBOX_TITLE_HEIGHT - graphics.CELL_HEIGHT) / 2, header, graphics.COLOR_WHITE, interface.FONT_INTERFACE_BOLD)

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
