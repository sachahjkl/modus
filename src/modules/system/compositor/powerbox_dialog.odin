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
POWERBOX_DIALOG_HEIGHT :: 156
POWERBOX_TEXT_LIMIT :: 96
POWERBOX_PICKER_SLOTS :: 4

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
	damage_add(0, 0, desktop_width, BAR_HEIGHT)
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
		interface.draw_rectangle(table, badge_x, 3, badge_w, BAR_HEIGHT - 6, graphics.colors.stop_process)
		interface.draw_text(table, badge_x + 8, 7, "AGENT GRANT", graphics.COLOR_WHITE, interface.FONT_INTERFACE)
	}
	if !powerbox_prompt.open {
		return
	}
	is_picker := powerbox_prompt.kind == .Store_Share
	dlg_h := is_picker ? POWERBOX_DIALOG_HEIGHT + 72 : POWERBOX_DIALOG_HEIGHT
	x := max(0, (desktop_width - POWERBOX_DIALOG_WIDTH) / 2)
	y := max(BAR_HEIGHT + 16, (desktop_height - dlg_h) / 2)
	interface.draw_rectangle(table, x, y, POWERBOX_DIALOG_WIDTH, dlg_h, graphics.colors.card_bottom)
	interface.draw_outline(table, x, y, POWERBOX_DIALOG_WIDTH, dlg_h, 2, graphics.colors.title)
	interface.draw_rectangle(table, x + 2, y + 2, POWERBOX_DIALOG_WIDTH - 4, 24, graphics.colors.title)
	header := is_picker ? "TRUSTED STORE PICKER" : "TRUSTED GRANT REQUEST"
	interface.draw_text(table, x + 10, y + 6, header, graphics.COLOR_WHITE, interface.FONT_INTERFACE)

	proc_str := string(powerbox_prompt.process_name[:powerbox_prompt.process_len])
	res_str := string(powerbox_prompt.resource_text[:powerbox_prompt.resource_len])
	proc_fit := interface.text_fit(table, interface.FONT_INTERFACE, proc_str, POWERBOX_DIALOG_WIDTH - 24)
	res_fit := interface.text_fit(table, interface.FONT_INTERFACE, res_str, POWERBOX_DIALOG_WIDTH - 24)
	interface.draw_text(table, x + 12, y + 38, proc_fit, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
	interface.draw_text(table, x + 12, y + 60, res_fit, graphics.colors.dim, interface.FONT_INTERFACE)

	if is_picker {
		for i in 0 ..< powerbox_prompt.picker_count {
			ry := y + 86 + i * 24
			sel := i == powerbox_prompt.picker_selected
			if sel {
				interface.draw_rectangle(table, x + 12, ry, POWERBOX_DIALOG_WIDTH - 24, 22, graphics.colors.chosen)
			}
			interface.draw_text(table, x + 20, ry + 3, powerbox_prompt.picker_stores[i], sel ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
		}
		interface.draw_text(table, x + 12, y + dlg_h - 26, "Up/Down: Choose   Enter: Share   Escape: Refuse", graphics.colors.text, interface.FONT_INTERFACE)
	} else {
		interface.draw_text(table, x + 12, y + dlg_h - 28, "Enter: Allow   Escape: Refuse", graphics.colors.text, interface.FONT_INTERFACE)
	}
}
