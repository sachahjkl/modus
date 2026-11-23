// The screen of a wide grant, the mark of a grant that holds, and the bound
// of the input of a viewer under it (src/md/features/wide_grants.md, "The
// screen", "The mark" and "The path of a grant, end to end").
//
// The root service asks for the screen with Wide_Grant_Screen_Show and
// draws the mark with Wide_Grant_Mark; the compositor answers on its
// control ring. Only the keys and the pointer of the input service reach
// the screen, the card of the mark and a window marked local: the input of
// a viewer is dropped on each of them.
package compositor

import "modus:contract/ring"
import "modus:contract/wide_grants"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

WIDE_GRANT_SCREEN_WIDTH :: 480
WIDE_GRANT_SCREEN_LINE :: 24
WIDE_GRANT_MARK_WIDTH :: 120
WIDE_GRANT_REVOKE_WIDTH :: 96

// The lines of the screen, in order: the two scopes, the duration, then
// one line for each window offered.
Wide_Grant_Screen_Line :: enum u8 {
	View_Screen = 0,
	Send_Input  = 1,
	Until_Lock  = 2,
	Window      = 3,
}

Wide_Grant_Screen_State :: struct {
	open:          bool,
	show:          wide_grants.Screen_Show,
	chosen:        wide_grants.Wide_Authorities,
	until_lock:    bool,
	window_count:  int,
	window_ids:    [wide_grants.SCREEN_WINDOWS_MOST]u64,
	window_chosen: [wide_grants.SCREEN_WINDOWS_MOST]bool,
	focus:         int,
}

wide_grant_screen: Wide_Grant_Screen_State

// wide_grant_trusted_surface_open says if a surface of a wide grant shows
// and takes the keys: the screen, or the card of the mark.
wide_grant_trusted_surface_open :: proc "contextless" () -> bool {
	return wide_grant_screen.open || wide_grant_display.card_open
}

// wide_grant_screen_show takes Wide_Grant_Screen_Show of the root service.
// It offers the windows that show, top first, at most SCREEN_WINDOWS_MOST,
// none marked local; the front window is chosen.
wide_grant_screen_show :: proc "contextless" (values: [7]u64) {
	show, ok := wide_grants.screen_show_of_values(values)
	if !ok {
		system.log_fact(.Info, Wide_Grant_Screen_Word_Refused{})
		return
	}
	window_switcher_cancel() // window_switcher.odin
	wide_grant_screen = {open = true, show = show, chosen = show.authorities}
	for position := order_count - 1; position >= 0 && wide_grant_screen.window_count < wide_grants.SCREEN_WINDOWS_MOST; position -= 1 {
		client := &clients[order[position]]
		if client.minimized || !client.created || client.local_input_only {
			continue
		}
		wide_grant_screen.window_ids[wide_grant_screen.window_count] = u64(order[position] + 1)
		wide_grant_screen.window_chosen[wide_grant_screen.window_count] = wide_grant_screen.window_count == 0
		wide_grant_screen.window_count += 1
	}
	damage_whole_screen()
}

@(private = "file")
screen_line_count :: proc "contextless" () -> int {
	return int(Wide_Grant_Screen_Line.Window) + wide_grant_screen.window_count
}

@(private = "file")
screen_line_kind :: proc "contextless" (line: int) -> Wide_Grant_Screen_Line {
	if line >= int(Wide_Grant_Screen_Line.Window) {
		return .Window
	}
	return Wide_Grant_Screen_Line(line)
}

// screen_line_toggle changes the choice of one line. A scope that the ask
// did not propose stays out; Send_Input needs View_Screen, so the one
// leaves with the other.
@(private = "file")
screen_line_toggle :: proc "contextless" (line: int) {
	screen := &wide_grant_screen
	switch screen_line_kind(line) {
	case .View_Screen:
		if .View_Screen in screen.chosen {
			screen.chosen -= {.View_Screen, .Send_Input}
		} else if .View_Screen in screen.show.authorities {
			screen.chosen += {.View_Screen}
		}
	case .Send_Input:
		if .Send_Input in screen.chosen {
			screen.chosen -= {.Send_Input}
		} else if .Send_Input in screen.show.authorities {
			screen.chosen += {.View_Screen, .Send_Input}
		}
	case .Until_Lock:
		screen.until_lock = !screen.until_lock && screen.show.duration_ms > wide_grants.SCREEN_DURATION_ONE_HOUR
	case .Window:
		index := line - int(Wide_Grant_Screen_Line.Window)
		screen.window_chosen[index] = !screen.window_chosen[index]
	}
}

// wide_grant_screen_answer sends the answer of the principal. A Give with
// no scope or no window is not sent: the screen stays. A full control ring
// keeps the screen open, so the principal presses again.
@(private = "file")
wide_grant_screen_answer :: proc "contextless" (give: bool) {
	screen := &wide_grant_screen
	answer := wide_grants.Screen_Answer{flow_serial = screen.show.flow_serial, decision = .Refuse}
	if give {
		answer.decision = .Give
		answer.authorities = screen.chosen
		answer.duration_ms = screen.until_lock ? screen.show.duration_ms : min(screen.show.duration_ms, wide_grants.SCREEN_DURATION_ONE_HOUR)
		for index in 0 ..< screen.window_count {
			if screen.window_chosen[index] {
				answer.window_ids[answer.window_count] = screen.window_ids[index]
				answer.window_count += 1
			}
		}
		if answer.authorities == {} || answer.window_count == 0 {
			return
		}
	}
	if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Wide_Grant_Screen_Answer), values = wide_grants.screen_answer_values(answer)}) {
		system.log_fact(.Warning, Wide_Grant_Answer_Not_Sent{})
		return
	}
	if give {
		wide_grant_display.bound = answer
	}
	screen^ = {}
	damage_whole_screen()
}

// wide_grant_mark_take takes Wide_Grant_Mark of the root service, the one
// writer of the mark. A grant serial of 0 clears the mark, its card and a
// screen that still shows. The windows of the answer of the same screen
// bound the input of a viewer; a mark of another screen bounds it to none.
wide_grant_mark_take :: proc "contextless" (values: [7]u64) {
	mark, ok := wide_grants.mark_of_values(values)
	if !ok {
		system.log_fact(.Info, Wide_Grant_Screen_Word_Refused{})
		return
	}
	if mark.grant_serial == 0 {
		wide_grant_display = {}
		wide_grant_screen = {}
		damage_whole_screen()
		return
	}
	bound := wide_grant_display.bound
	if bound.flow_serial != mark.flow_serial {
		bound = {}
	}
	wide_grant_display = {active = true, mark = mark, bound = bound}
	damage_bar()
}

// wide_grant_revoke_press tells the root service that the principal pressed
// revoke. The mark clears only when the record left: a full ring keeps the
// mark, since the grant still holds.
wide_grant_revoke_press :: proc "contextless" () -> bool {
	if !wide_grant_display.active {
		return false
	}
	if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Wide_Grant_Revoke_Pressed), values = {0 = wide_grant_display.mark.grant_serial}}) {
		system.log_fact(.Warning, Wide_Grant_Answer_Not_Sent{})
		return true
	}
	system.log_fact(.Info, Wide_Grant_Revoke_Pressed{grant = wide_grant_display.mark.grant_serial})
	wide_grant_display = {}
	damage_whole_screen()
	return true
}

// wide_grant_screen_key takes a key of the input service while the screen
// or the card of the mark shows: each key stops here.
wide_grant_screen_key :: proc "contextless" (code: u32, pressed: bool) -> bool {
	if wide_grant_display.card_open {
		if pressed {
			switch code {
			case display.KEY_ENTER:
				_ = wide_grant_revoke_press()
			case display.KEY_ESCAPE:
				wide_grant_display.card_open = false
				damage_whole_screen()
			}
		}
		return true
	}
	if !wide_grant_screen.open {
		return false
	}
	if !pressed {
		return true
	}
	screen := &wide_grant_screen
	switch code {
	case display.KEY_UP:
		screen.focus = (screen.focus + screen_line_count() - 1) % screen_line_count()
	case display.KEY_DOWN, display.KEY_TAB:
		screen.focus = (screen.focus + 1) % screen_line_count()
	case display.KEY_SPACE:
		screen_line_toggle(screen.focus)
	case display.KEY_ENTER:
		wide_grant_screen_answer(true)
		return true
	case display.KEY_ESCAPE:
		wide_grant_screen_answer(false)
		return true
	}
	damage_whole_screen()
	return true
}

@(private = "file")
mark_place :: proc "contextless" () -> (x, y, width, height: int) {
	return max(0, desktop_width / 2 - WIDE_GRANT_MARK_WIDTH / 2), desktop_bar_y() + 3, WIDE_GRANT_MARK_WIDTH, BAR_HEIGHT - 6
}

@(private = "file")
card_place :: proc "contextless" () -> (x, y, width, height: int) {
	height = POWERBOX_TITLE_HEIGHT + 3 * WIDE_GRANT_SCREEN_LINE + 2 * POWERBOX_MARGIN + POWERBOX_BUTTON_HEIGHT
	x = max(0, (desktop_width - WIDE_GRANT_SCREEN_WIDTH) / 2)
	y = max(desktop_work_top() + 16, min((desktop_height - height) / 2, desktop_work_bottom() - height - 16))
	return x, y, WIDE_GRANT_SCREEN_WIDTH, height
}

@(private = "file")
revoke_place :: proc "contextless" () -> (x, y, width, height: int) {
	card_x, card_y, card_width, card_height := card_place()
	return card_x + card_width - POWERBOX_MARGIN - WIDE_GRANT_REVOKE_WIDTH, card_y + card_height - POWERBOX_MARGIN - POWERBOX_BUTTON_HEIGHT, WIDE_GRANT_REVOKE_WIDTH, POWERBOX_BUTTON_HEIGHT
}

// wide_grant_mark_pointer takes a press of the pointer on the mark, which
// opens its card, and on revoke in the card. The pointer of a viewer never
// reaches it: wide_grant_viewer_pointer_allowed drops it first.
wide_grant_mark_pointer :: proc "contextless" (pressed: bool) -> bool {
	if !wide_grant_display.active {
		return false
	}
	if wide_grant_display.card_open {
		if pressed {
			revoke_x, revoke_y, revoke_width, revoke_height := revoke_place()
			card_x, card_y, card_width, card_height := card_place()
			if inside(pointer_x, pointer_y, revoke_x, revoke_y, revoke_width, revoke_height) {
				_ = wide_grant_revoke_press()
			} else if !inside(pointer_x, pointer_y, card_x, card_y, card_width, card_height) {
				wide_grant_display.card_open = false
				damage_whole_screen()
			}
		}
		return true
	}
	if x, y, width, height := mark_place(); pressed && inside(pointer_x, pointer_y, x, y, width, height) {
		wide_grant_display.card_open = true
		damage_whole_screen()
		return true
	}
	return false
}

// wide_grant_screen_pointer: the screen takes the pointer; a press on a
// line changes it.
wide_grant_screen_pointer :: proc "contextless" (pressed: bool) -> bool {
	if !wide_grant_screen.open {
		return false
	}
	if pressed {
		x, y, width, _ := screen_place()
		for line in 0 ..< screen_line_count() {
			if inside(pointer_x, pointer_y, x, screen_line_y(y, line), width, WIDE_GRANT_SCREEN_LINE) {
				wide_grant_screen.focus = line
				screen_line_toggle(line)
				damage_whole_screen()
			}
		}
	}
	return true
}

@(private = "file")
screen_place :: proc "contextless" () -> (x, y, width, height: int) {
	height = POWERBOX_TITLE_HEIGHT + 2 * POWERBOX_MARGIN + (screen_line_count() + 2) * WIDE_GRANT_SCREEN_LINE + POWERBOX_BUTTON_HEIGHT
	x = max(0, (desktop_width - WIDE_GRANT_SCREEN_WIDTH) / 2)
	y = max(desktop_work_top() + 16, min((desktop_height - height) / 2, desktop_work_bottom() - height - 16))
	return x, y, WIDE_GRANT_SCREEN_WIDTH, height
}

@(private = "file")
screen_line_y :: proc "contextless" (top: int, line: int) -> int {
	return top + 2 + POWERBOX_TITLE_HEIGHT + POWERBOX_MARGIN + (line + 1) * WIDE_GRANT_SCREEN_LINE
}

// wide_grant_viewer_key_allowed says if a key of a viewer reaches the
// window in front: never over a surface of the trusted display or a window
// marked local, and under a grant only a window of its bound. Each key
// dropped under a grant is counted.
wide_grant_viewer_key_allowed :: proc "contextless" () -> bool {
	if trusted_dialog_open() || local_input_window_shows() {
		return false
	}
	if !wide_grant_display.active {
		return true
	}
	if order_count > 0 && wide_grants.window_in_bound(&wide_grant_display.bound, u64(order[order_count - 1] + 1)) {
		return true
	}
	wide_grant_display.dropped_input += 1
	return false
}

// wide_grant_viewer_pointer_allowed says if a pointer of a viewer at the
// logical place (x, y) reaches the desktop. Under a grant it reaches a
// window of its bound only, never the bar, the desktop or another window.
wide_grant_viewer_pointer_allowed :: proc "contextless" (x, y: int) -> (allowed: bool, window_id: u64) {
	if trusted_dialog_open() || local_input_window_shows() {
		return false, 0
	}
	if !wide_grant_display.active {
		return true, 0
	}
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		if client.minimized {
			continue
		}
		csd := client.decoration == .Client
		outer_width := csd ? client.width : client.width + 2 * BORDER
		outer_height := csd ? client.height : client.height + TITLE_HEIGHT + BORDER
		if !inside(x, y, client.x, client.y, outer_width, outer_height) {
			continue
		}
		id := u64(order[position] + 1)
		if wide_grants.window_in_bound(&wide_grant_display.bound, id) && y < desktop_bar_y() {
			return true, id
		}
		break
	}
	wide_grant_display.dropped_input += 1
	return false, 0
}

// local_input_window_shows says if a window marked local is open: while
// the proof of a wide grant asks for a passphrase, no input of a viewer
// reaches the desktop at all.
@(private = "file")
local_input_window_shows :: proc "contextless" () -> bool {
	for position in 0 ..< order_count {
		if clients[order[position]].local_input_only {
			return true
		}
	}
	return false
}

@(private = "file")
digits_write :: proc "contextless" (buffer: []u8, number: u64) -> int {
	scratch: [20]u8
	count := 0
	value := number
	for {
		scratch[count] = u8('0' + value % 10)
		count += 1
		value /= 10
		if value == 0 || count == len(scratch) {
			break
		}
	}
	written := min(count, len(buffer))
	for index in 0 ..< written {
		buffer[index] = scratch[count - 1 - index]
	}
	return written
}

// minutes_text writes "<prefix><n> min" for the minutes left until ends_at.
@(private = "file")
minutes_text :: proc "contextless" (buffer: []u8, prefix: string, ends_at_ms: u64) -> string {
	now := system.time()
	left := ends_at_ms > now ? (ends_at_ms - now + 59_999) / 60_000 : 0
	count := copy(buffer, prefix)
	count += digits_write(buffer[count:], left)
	count += copy(buffer[count:], " min")
	return string(buffer[:count])
}

// wide_grant_records draws the mark in the bar, its card, and the screen.
wide_grant_records :: proc "contextless" (table: ^interface.Draw_Table) {
	if wide_grant_display.active {
		x, y, width, height := mark_place()
		text: [32]u8
		interface.draw_rectangle(table, x, y, width, height, graphics.colors.stop_process)
		interface.draw_text(table, x + 8, y + 4, minutes_text(text[:], "AGENT ", wide_grant_display.mark.ends_at_ms), graphics.COLOR_WHITE, interface.FONT_INTERFACE)
	}
	if wide_grant_display.card_open {
		x, y, width, height := card_place()
		trusted_card_records(table, x, y, width, height, "WIDE GRANT")
		line_y := y + 2 + POWERBOX_TITLE_HEIGHT + POWERBOX_MARGIN
		scopes := "Sees the screen"
		if .Send_Input in wide_grant_display.mark.authorities {
			scopes = "Sees the screen and sends keys and pointer"
		}
		text: [48]u8
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y, scopes, graphics.colors.text_strong, interface.FONT_INTERFACE)
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y + WIDE_GRANT_SCREEN_LINE, minutes_text(text[:], "Ends in ", wide_grant_display.mark.ends_at_ms), graphics.colors.text, interface.FONT_INTERFACE)
		acts: [48]u8
		acts_count := copy(acts[:], "Acts recorded: ")
		acts_count += digits_write(acts[acts_count:], wide_grant_display.acts_recorded)
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y + 2 * WIDE_GRANT_SCREEN_LINE, string(acts[:acts_count]), graphics.colors.dim, interface.FONT_INTERFACE)
		revoke_x, revoke_y, revoke_width, revoke_height := revoke_place()
		interface.draw_rectangle(table, revoke_x, revoke_y, revoke_width, revoke_height, graphics.colors.stop_process)
		interface.draw_text(table, revoke_x + 12, revoke_y + (revoke_height - graphics.CELL_HEIGHT) / 2, "Revoke", graphics.COLOR_WHITE, interface.FONT_INTERFACE)
		interface.draw_text(table, x + POWERBOX_MARGIN, revoke_y + (revoke_height - graphics.CELL_HEIGHT) / 2, "Esc: close", graphics.colors.dim, interface.FONT_INTERFACE)
	}
	if !wide_grant_screen.open {
		return
	}
	screen := &wide_grant_screen
	x, y, width, height := screen_place()
	trusted_card_records(table, x, y, width, height, "TRUSTED WIDE GRANT")
	room := width - 2 * POWERBOX_MARGIN
	head: [40]u8
	head_count := copy(head[:], "An agent asks to act for you. Key ")
	digits := "0123456789abcdef"
	for index in 0 ..< 3 {
		byte := u8(screen.show.client_key_head >> (8 * u64(index)))
		if head_count + 2 <= len(head) {
			head[head_count] = digits[byte >> 4]
			head[head_count + 1] = digits[byte & 0x0F]
			head_count += 2
		}
	}
	interface.draw_text(table, x + POWERBOX_MARGIN, y + 2 + POWERBOX_TITLE_HEIGHT + POWERBOX_MARGIN, interface.text_fit(table, interface.FONT_INTERFACE, string(head[:head_count]), room), graphics.colors.text_strong, interface.FONT_INTERFACE)
	for line in 0 ..< screen_line_count() {
		line_y := screen_line_y(y, line)
		on, offered: bool
		label: string
		window_name: string
		switch screen_line_kind(line) {
		case .View_Screen:
			on, offered, label = .View_Screen in screen.chosen, .View_Screen in screen.show.authorities, "See the screen"
		case .Send_Input:
			on, offered, label = .Send_Input in screen.chosen, .Send_Input in screen.show.authorities, "Send keys and pointer to the windows below"
		case .Until_Lock:
			on, offered, label = screen.until_lock, screen.show.duration_ms > wide_grants.SCREEN_DURATION_ONE_HOUR, "Until the lock (else for one hour)"
		case .Window:
			index := line - int(Wide_Grant_Screen_Line.Window)
			client := &clients[screen.window_ids[index] - 1]
			window_name = system.name_of(client.title[:])
			on, offered, label = screen.window_chosen[index], true, window_name
		}
		if line == screen.focus {
			interface.draw_rectangle(table, x + 2, line_y, width - 4, WIDE_GRANT_SCREEN_LINE, graphics.colors.recess)
		}
		box := on ? "[x] " : "[ ] "
		color := offered ? graphics.colors.text : graphics.colors.dim
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y + 4, box, color, interface.FONT_INTERFACE)
		interface.draw_text(table, x + POWERBOX_MARGIN + 32, line_y + 4, interface.text_fit(table, interface.FONT_INTERFACE, label, room - 32), color, interface.FONT_INTERFACE)
	}
	button_y := y + height - POWERBOX_MARGIN - POWERBOX_BUTTON_HEIGHT
	interface.draw_text(table, x + POWERBOX_MARGIN, button_y + (POWERBOX_BUTTON_HEIGHT - graphics.CELL_HEIGHT) / 2, "Space: change", graphics.colors.dim, interface.FONT_INTERFACE)
	right := x + width - POWERBOX_MARGIN
	right = powerbox_button_records(table, right, button_y, "Refuse", "Esc", false)
	_ = powerbox_button_records(table, right - POWERBOX_BUTTON_GAP, button_y, "Give", "Enter", true)
}
