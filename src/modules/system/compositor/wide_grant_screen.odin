// The screen of a wide grant, the mark of a grant that holds, the bound of
// the input of a viewer under it, and the act records of the trusted
// display (src/md/features/wide_grants.md, "The screen of a wide grant";
// src/md/features/wide_grants.md, "The mark";
// src/md/features/wide_grants.md, "The path of a grant, end to end"). The rules are the pure part
// internal:compositor/wide_grant_view; this file draws them, reads the
// desktop for them, and writes the records.
//
// The root service asks for the screen with Wide_Grant_Screen_Show and
// draws the mark with Wide_Grant_Mark; the compositor answers on its
// control ring. Only the keys and the pointer of the input service reach
// the screen, the card of the mark and a window marked local.
package compositor

import "internal:compositor/bar"
import "internal:compositor/wide_grant_view"
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

wide_grant_screen: wide_grant_view.Screen
wide_grant_display: wide_grant_view.Display
// A screen that came while another trusted dialog showed: it opens when
// that dialog closes. One trusted dialog shows at a time.
wide_grant_screen_waiting: wide_grants.Screen_Show
wide_grant_screen_waits: bool
// The id of the last window that opened. An id is never given twice in a
// run: a window that closes leaves no id that a later window takes. Past
// SCREEN_WINDOW_ID_MOST a window gets 0, which no screen offers.
window_serial_last: u64

// The act records of the trusted display under a wide grant: one record
// for each change of the window of the input of a viewer, and the open and
// the close of a view (src/md/features/wide_grants.md, "The record of each
// act").
acts: system.Record_Output(wide_grants.Act_Stream_Record)

// window_serial_next gives the id of a window that opens.
window_serial_next :: proc "contextless" () -> u64 {
	if window_serial_last >= wide_grants.SCREEN_WINDOW_ID_MOST {
		return 0
	}
	window_serial_last += 1
	return window_serial_last
}

// wide_grant_trusted_surface_open says if a surface of a wide grant shows
// and takes the keys: the screen, or the card of the mark.
wide_grant_trusted_surface_open :: proc "contextless" () -> bool {
	return wide_grant_screen.open || wide_grant_display.card_open
}

// wide_grant_screen_show takes Wide_Grant_Screen_Show of the root service.
// Over another trusted dialog it waits for that dialog to close.
wide_grant_screen_show :: proc "contextless" (values: [7]u64) {
	show, ok := wide_grants.screen_show_of_values(values)
	if !ok {
		system.log_fact(.Info, Wide_Grant_Screen_Word_Refused{})
		return
	}
	if powerbox_prompt.open || plan_difference_dialog.open {
		wide_grant_screen_waiting, wide_grant_screen_waits = show, true
		return
	}
	wide_grant_screen_open_now(show)
}

// wide_grant_screen_waiting_open opens a screen that waited, once no other
// trusted dialog shows. The loop calls it at each pass.
wide_grant_screen_waiting_open :: proc "contextless" () {
	if wide_grant_screen_waits && !powerbox_prompt.open && !plan_difference_dialog.open {
		wide_grant_screen_waits = false
		wide_grant_screen_open_now(wide_grant_screen_waiting)
	}
}

// wide_grant_screen_open_now offers the windows that show, top first, none
// minimized and none marked local.
@(private = "file")
wide_grant_screen_open_now :: proc "contextless" (show: wide_grants.Screen_Show) {
	window_switcher_cancel() // window_switcher.odin
	windows: [wide_grants.SCREEN_WINDOWS_MOST]u64
	count := 0
	for position := order_count - 1; position >= 0 && count < len(windows); position -= 1 {
		client := &clients[order[position]]
		if client.minimized || !client.created || client.local_input_only || client.window_serial == 0 {
			continue
		}
		windows[count] = client.window_serial
		count += 1
	}
	wide_grant_view.screen_open(&wide_grant_screen, show, windows[:count])
	damage_whole_screen()
}

// client_of_window gives the client of a window id, or nil.
client_of_window :: proc "contextless" (window_id: u64) -> ^Client {
	if window_id == 0 {
		return nil
	}
	for &client in clients {
		if client.ring_memory != 0 && client.window_serial == window_id {
			return &client
		}
	}
	return nil
}

// wide_grant_window_closed takes a window that closed: it leaves the bound
// of the grant and the lines of the screen.
wide_grant_window_closed :: proc "contextless" (client: ^Client) {
	was_open := wide_grant_screen.open
	wide_grant_view.display_window_closed(&wide_grant_display, &wide_grant_screen, client.window_serial)
	if was_open {
		damage_whole_screen()
	}
}

// wide_grant_screen_answer sends the answer of the principal. A give with
// no scope or no window is not sent: the screen stays. A full control ring
// keeps the screen open, so the principal presses again.
@(private = "file")
wide_grant_screen_answer :: proc "contextless" (give: bool) {
	answer, sendable := wide_grant_view.screen_answer(&wide_grant_screen, give)
	if !sendable {
		return
	}
	if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Wide_Grant_Screen_Answer), values = wide_grants.screen_answer_values(answer)}) {
		system.log_fact(.Warning, Wide_Grant_Answer_Not_Sent{})
		return
	}
	wide_grant_view.display_answer_given(&wide_grant_display, answer)
	wide_grant_screen = {}
	damage_whole_screen()
}

// wide_grant_mark_take takes Wide_Grant_Mark of the root service, the one
// writer of the mark.
wide_grant_mark_take :: proc "contextless" (values: [7]u64) {
	// The end of a grant: the counts of the last window leave first.
	if values[0] == 0 {
		wide_grant_counts_write()
	}
	started, ok := wide_grant_view.display_mark_take(&wide_grant_display, &wide_grant_screen, values)
	if !ok {
		system.log_fact(.Info, Wide_Grant_Screen_Word_Refused{})
		return
	}
	// A view that is open when the grant starts gets its record of the open
	// now: the agent may read the screen through it from here on.
	if started && capture.client >= 0 && !wide_grant_view_record(true, capture.client) {
		capture_end("the act record of the view did not leave")
	}
	damage_whole_screen()
}

// wide_grant_revoke_press tells the root service that the principal pressed
// revoke. The mark clears only when the record left: a full ring keeps the
// mark, since the grant still holds.
wide_grant_revoke_press :: proc "contextless" () -> bool {
	if !wide_grant_display.active {
		return false
	}
	grant := wide_grant_display.mark.grant_serial
	wide_grant_counts_write()
	if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Wide_Grant_Revoke_Pressed), values = {0 = grant}}) {
		system.log_fact(.Warning, Wide_Grant_Answer_Not_Sent{})
		return true
	}
	system.log_fact(.Info, Wide_Grant_Revoke_Pressed{grant = grant})
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
		wide_grant_view.screen_focus_move(screen, -1)
	case display.KEY_DOWN, display.KEY_TAB:
		wide_grant_view.screen_focus_move(screen, 1)
	case display.KEY_SPACE:
		wide_grant_view.screen_toggle(screen, screen.focus)
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
	height = POWERBOX_TITLE_HEIGHT + 4 * WIDE_GRANT_SCREEN_LINE + 2 * POWERBOX_MARGIN + POWERBOX_BUTTON_HEIGHT
	x = max(0, (desktop_width - WIDE_GRANT_SCREEN_WIDTH) / 2)
	y = max(desktop_work_top() + 16, min((desktop_height - height) / 2, desktop_work_bottom() - height - 16))
	return x, y, WIDE_GRANT_SCREEN_WIDTH, height
}

@(private = "file")
revoke_place :: proc "contextless" () -> (x, y, width, height: int) {
	card_x, card_y, card_width, card_height := card_place()
	return card_x + card_width - POWERBOX_MARGIN - WIDE_GRANT_REVOKE_WIDTH, card_y + card_height - POWERBOX_MARGIN - POWERBOX_BUTTON_HEIGHT, WIDE_GRANT_REVOKE_WIDTH, POWERBOX_BUTTON_HEIGHT
}

// wide_grant_mark_pointer takes a press of the pointer of the input service
// on the mark, which opens its card, and on revoke in the card. The pointer
// of a viewer never reaches it: viewer_input_surface says Trusted or Bar.
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
		for line in 0 ..< wide_grant_view.screen_line_count(&wide_grant_screen) {
			if inside(pointer_x, pointer_y, x, screen_line_y(y, line), width, WIDE_GRANT_SCREEN_LINE) {
				wide_grant_screen.focus = line
				wide_grant_view.screen_toggle(&wide_grant_screen, line)
				damage_whole_screen()
			}
		}
	}
	return true
}

@(private = "file")
screen_place :: proc "contextless" () -> (x, y, width, height: int) {
	height = POWERBOX_TITLE_HEIGHT + 2 * POWERBOX_MARGIN + (wide_grant_view.screen_line_count(&wide_grant_screen) + 2) * WIDE_GRANT_SCREEN_LINE + POWERBOX_BUTTON_HEIGHT
	x = max(0, (desktop_width - WIDE_GRANT_SCREEN_WIDTH) / 2)
	y = max(desktop_work_top() + 16, min((desktop_height - height) / 2, desktop_work_bottom() - height - 16))
	return x, y, WIDE_GRANT_SCREEN_WIDTH, height
}

@(private = "file")
screen_line_y :: proc "contextless" (top: int, line: int) -> int {
	return top + 2 + POWERBOX_TITLE_HEIGHT + POWERBOX_MARGIN + (line + 1) * WIDE_GRANT_SCREEN_LINE
}

// local_input_window_shows says if a window marked local is open: while
// the proof of a wide grant asks for a passphrase, no input of a viewer
// reaches the desktop at all, and a viewer cannot resize the screen.
local_input_window_shows :: proc "contextless" () -> bool {
	for position in 0 ..< order_count {
		if clients[order[position]].local_input_only {
			return true
		}
	}
	return false
}

// overlay_takes_input says if a part of the desktop over the windows takes
// the input first: the palette, a menu, a card of the bar, a list, a move
// or a resize of a window, a mode of the keyboard.
@(private = "file")
overlay_takes_input :: proc "contextless" () -> bool {
	return palette_is_open() || menu_open != .None || dragging >= 0 || resizing >= 0 || desktop_context_menu.open || window_switcher.open || tray_state.open != .None || capture_viewer_popover.open || keyboard_window_mode != .None || bar_focus.kind != .None
}

// viewer_key_surface gives what takes a key of a viewer now: the window in
// front, under nothing.
viewer_key_surface :: proc "contextless" () -> (surface: wide_grant_view.Surface, window_id: u64) {
	switch {
	case trusted_dialog_open(), local_input_window_shows():
		return .Trusted, 0
	case overlay_takes_input():
		return .Overlay, 0
	case order_count == 0 || clients[order[order_count - 1]].minimized:
		return .Desktop, 0
	}
	return .Window, clients[order[order_count - 1]].window_serial
}

// viewer_pointer_surface gives what takes a pointer of a viewer at the
// logical place (x, y), by the hit test of a press (window_position_at):
// the surface of a window, never its frame, its title or its buttons.
viewer_pointer_surface :: proc "contextless" (x, y: int) -> (surface: wide_grant_view.Surface, window_id: u64) {
	switch {
	case trusted_dialog_open(), local_input_window_shows():
		return .Trusted, 0
	case overlay_takes_input():
		return .Overlay, 0
	case bar.inside_bar(bar_layout, y):
		return .Bar, 0
	}
	if index, edges := resize_edges_at(x, y); edges != {} && index >= 0 {
		return .Overlay, 0
	}
	position := window_position_at(x, y)
	if position < 0 {
		return .Desktop, 0
	}
	client := &clients[order[position]]
	if _, _, on_surface := surface_point(client, x, y); !on_surface {
		return .Overlay, 0
	}
	return .Window, client.window_serial
}

// act_write is the write of wide_grants.act_emit: the status of the output
// becomes its member of Act_Write_Status, at this border.
@(private = "file")
act_write :: proc "contextless" (user: rawptr, record: wide_grants.Act_Stream_Record) -> wide_grants.Act_Write_Status {
	switch system.output_write(&acts, record, wait = false) {
	case .Ok:
		return .Ok
	case .Full:
		return .Full
	case .No_Reader:
		return .No_Reader
	case .No_Writer:
		return .No_Writer
	case .Ended:
		return .Ended
	case .Bad_Record:
		return .Bad_Record
	case .No_Record:
		return .No_Record
	}
	return .Bad_Record
}

// wide_grant_record writes one act record while a grant holds, the counts
// of the input that wait first (wide_grants.display_emit), and says if the
// act may run: with no grant, yes, with no record.
@(private = "file")
wide_grant_record :: proc "contextless" (record: wide_grants.Act_Stream_Record) -> bool {
	outcome, _ := wide_grants.display_emit(act_write, nil, &wide_grant_display.target, record)
	switch outcome {
	case .No_Grant:
		return true
	case .Recorded:
		wide_grant_display.acts_recorded += 1
		return true
	case .Refused:
		wide_grant_display.dropped_acts += 1
		damage_bar()
		return false
	}
	return false
}

// wide_grant_viewer_input_checked gives the verdict of an input of a
// viewer on a surface, and logs the first input that a grant refuses.
// false: the input goes nowhere.
wide_grant_viewer_input_checked :: proc "contextless" (surface: wide_grant_view.Surface, window_id: u64) -> bool {
	switch wide_grant_view.viewer_input_verdict(&wide_grant_display, surface, window_id) {
	case .Allowed:
		return true
	case .Dropped_Counted:
		if wide_grant_display.dropped_input == 1 {
			system.log_fact(.Info, Wide_Grant_Viewer_Input_Refused{grant = wide_grant_display.mark.grant_serial})
		}
	case .Dropped:
	}
	damage_bar()
	return false
}

// wide_grant_input_allowed is the one step of an input of a viewer under a
// grant: the record of its window leaves first when the window changed,
// then the act counts on it. false: the act must not run.
wide_grant_input_allowed :: proc "contextless" (window_id: u64, act: wide_grants.Input_Act) -> bool {
	if !wide_grant_display.active {
		return true
	}
	target := &wide_grant_display.target
	if record, needed := wide_grants.input_target_record(target, wide_grant_display.mark.grant_serial, wide_grant_display.mark.principal_id, window_id, system.time()); needed {
		if !wide_grant_record(record) {
			return false
		}
		wide_grants.input_target_taken(target, window_id)
	}
	wide_grants.input_target_count(target, act, system.time())
	return true
}

// wide_grant_counts_write writes the counts of the window of the input
// that wait, with the time of their last act. The loop calls it at
// INPUT_COUNTS_INTERVAL_MILLISECONDS, and the end of a grant before the mark
// clears. A record that did not leave keeps the counts for the next try.
wide_grant_counts_write :: proc "contextless" () {
	if !wide_grant_display.active {
		return
	}
	target := &wide_grant_display.target
	if record, needed := wide_grants.input_target_counts_record(target, wide_grant_display.mark.grant_serial, wide_grant_display.mark.principal_id); needed && wide_grant_record(record) {
		wide_grants.input_target_counts_taken(target)
	}
}

// The time of the last write of the counts, for the interval.
wide_grant_counts_written_ms: u64

// wide_grant_counts_tick writes the counts at their interval while a grant
// holds.
wide_grant_counts_tick :: proc "contextless" (now_ms: u64) {
	if wide_grant_display.active && now_ms - wide_grant_counts_written_ms >= wide_grants.INPUT_COUNTS_INTERVAL_MILLISECONDS {
		wide_grant_counts_written_ms = now_ms
		wide_grant_counts_write()
	}
}

// wide_grant_view_record writes the open (true) or the close of a view of
// the screen while a grant holds. false: a view that opens must not open.
wide_grant_view_record :: proc "contextless" (opens: bool, client_place: int) -> bool {
	return wide_grant_record({
		grant_serial  = wide_grant_display.active ? wide_grant_display.mark.grant_serial : 0,
		principal_id  = wide_grant_display.mark.principal_id,
		timestamp_ms  = system.time(),
		producer_word = u64(wide_grants.Act_Producer.Trusted_Display),
		act_kind_word = u64(wide_grants.Act_Kind.Frame_Read),
		detail_word_0 = opens ? 1 : 0,
		detail_word_1 = u64(client_place),
	})
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

// window_line_name gives the name of a window on the screen: the name
// that the root service gave its process, never a title that the process
// chose.
@(private = "file")
window_line_name :: proc "contextless" (window_id: u64) -> string {
	client := client_of_window(window_id)
	if client == nil || client.given_name_length == 0 {
		return "a window with no name"
	}
	return string(client.given_name[:client.given_name_length])
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
		// The card says what holds: the scopes of the mark, which bound the
		// input of a viewer.
		scopes := "Sees the screen; sends no key and no press"
		if .Send_Input in wide_grant_display.mark.authorities {
			scopes = "Sees the screen, and types and presses in the windows you picked"
		}
		text: [48]u8
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y, interface.text_fit(table, interface.FONT_INTERFACE, scopes, width - 2 * POWERBOX_MARGIN), graphics.colors.text_strong, interface.FONT_INTERFACE)
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y + WIDE_GRANT_SCREEN_LINE, minutes_text(text[:], "Ends in ", wide_grant_display.mark.ends_at_ms), graphics.colors.text, interface.FONT_INTERFACE)
		acts_text: [64]u8
		acts_count := copy(acts_text[:], "Acts recorded: ")
		acts_count += digits_write(acts_text[acts_count:], wide_grant_display.acts_recorded)
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y + 2 * WIDE_GRANT_SCREEN_LINE, string(acts_text[:acts_count]), graphics.colors.dim, interface.FONT_INTERFACE)
		// Why acts were refused: a record with no room means that the space
		// of the act records of the grant is full, or its ring is; each next
		// act is refused until the grant ends.
		refused_text: [96]u8
		refused_count := copy(refused_text[:], "Refused: ")
		refused_count += digits_write(refused_text[refused_count:], wide_grant_display.dropped_acts)
		refused_count += copy(refused_text[refused_count:], " with no room for their record, ")
		refused_count += digits_write(refused_text[refused_count:], wide_grant_display.dropped_input)
		refused_count += copy(refused_text[refused_count:], " out of your windows")
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y + 3 * WIDE_GRANT_SCREEN_LINE, interface.text_fit(table, interface.FONT_INTERFACE, string(refused_text[:refused_count]), width - 2 * POWERBOX_MARGIN), graphics.colors.dim, interface.FONT_INTERFACE)
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
	for line in 0 ..< wide_grant_view.screen_line_count(screen) {
		line_y := screen_line_y(y, line)
		label: string
		switch wide_grant_view.screen_line_kind(line) {
		case .View_Screen:
			label = "See the screen"
		case .Send_Input:
			label = "Type and press in the windows below"
		case .Until_Lock:
			label = "Until the lock (else for one hour)"
		case .Window:
			label = window_line_name(screen.window_ids[line - wide_grant_view.LINE_FIRST_WINDOW])
		}
		if line == screen.focus {
			interface.draw_rectangle(table, x + 2, line_y, width - 4, WIDE_GRANT_SCREEN_LINE, graphics.colors.recess)
		}
		box := wide_grant_view.screen_line_on(screen, line) ? "[x] " : "[ ] "
		color := wide_grant_view.screen_line_offered(screen, line) ? graphics.colors.text : graphics.colors.dim
		interface.draw_text(table, x + POWERBOX_MARGIN, line_y + 4, box, color, interface.FONT_INTERFACE)
		interface.draw_text(table, x + POWERBOX_MARGIN + 32, line_y + 4, interface.text_fit(table, interface.FONT_INTERFACE, label, room - 32), color, interface.FONT_INTERFACE)
	}
	button_y := y + height - POWERBOX_MARGIN - POWERBOX_BUTTON_HEIGHT
	interface.draw_text(table, x + POWERBOX_MARGIN, button_y + (POWERBOX_BUTTON_HEIGHT - graphics.CELL_HEIGHT) / 2, "Space: change", graphics.colors.dim, interface.FONT_INTERFACE)
	right := x + width - POWERBOX_MARGIN
	right = powerbox_button_records(table, right, button_y, "Refuse", "Esc", false)
	_ = powerbox_button_records(table, right - POWERBOX_BUTTON_GAP, button_y, "Give", "Enter", true)
}
