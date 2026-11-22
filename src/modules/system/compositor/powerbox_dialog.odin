// Unforgeable trusted-display Powerbox grant dialog and Wide-Grant active bar
// mark inside the compositor (src/md/features/powerbox.md) and
// (src/md/features/wide_grants.md).
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

POWERBOX_DIALOG_WIDTH :: 420
POWERBOX_DIALOG_HEIGHT :: 136
POWERBOX_TEXT_LIMIT :: 96

Powerbox_Prompt_State :: struct {
	open:          bool,
	request_id:    u64,
	kind:          powerbox.Request_Item_Kind,
	process_name:  [POWERBOX_TEXT_LIMIT]u8,
	process_len:   int,
	resource_text: [POWERBOX_TEXT_LIMIT]u8,
	resource_len:  int,
	last_decision: powerbox.Item_Decision,
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

// powerbox_and_wide_grant_key intercepts Enter/Escape for an open trusted
// powerbox dialog and Ctrl+Shift+Escape for immediate one-press wide-grant
// revocation before any client window receives keys.
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
	case display.KEY_ENTER:
		return powerbox_prompt_decide(true)
	case display.KEY_ESCAPE:
		return powerbox_prompt_decide(false)
	}
	return true // Modal trusted dialog absorbs other keys while open.
}

// powerbox_dialog_records draws the unforgeable trusted-display powerbox modal
// and the wide-grant active bar badge into the screen draw table.
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
	x := max(0, (desktop_width - POWERBOX_DIALOG_WIDTH) / 2)
	y := max(BAR_HEIGHT + 16, (desktop_height - POWERBOX_DIALOG_HEIGHT) / 2)
	interface.draw_rectangle(table, x, y, POWERBOX_DIALOG_WIDTH, POWERBOX_DIALOG_HEIGHT, graphics.colors.card_bottom)
	interface.draw_outline(table, x, y, POWERBOX_DIALOG_WIDTH, POWERBOX_DIALOG_HEIGHT, 2, graphics.colors.title)
	interface.draw_rectangle(table, x + 2, y + 2, POWERBOX_DIALOG_WIDTH - 4, 24, graphics.colors.title)
	interface.draw_text(table, x + 10, y + 6, "TRUSTED GRANT REQUEST", graphics.COLOR_WHITE, interface.FONT_INTERFACE)

	proc_str := string(powerbox_prompt.process_name[:powerbox_prompt.process_len])
	res_str := string(powerbox_prompt.resource_text[:powerbox_prompt.resource_len])
	proc_fit := interface.text_fit(table, interface.FONT_INTERFACE, proc_str, POWERBOX_DIALOG_WIDTH - 24)
	res_fit := interface.text_fit(table, interface.FONT_INTERFACE, res_str, POWERBOX_DIALOG_WIDTH - 24)
	interface.draw_text(table, x + 12, y + 38, proc_fit, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
	interface.draw_text(table, x + 12, y + 62, res_fit, graphics.colors.dim, interface.FONT_INTERFACE)
	interface.draw_text(table, x + 12, y + 102, "Enter: Allow   Escape: Refuse", graphics.colors.text, interface.FONT_INTERFACE)
}
