// Opt-in relative pointer lock for the focused window (src/md/features/doom.md).
// The pure state transitions and key/bar decisions live in
// src/library/internal/compositor/bar/pointer_lock.odin so host tests cover
// every path.
package compositor

import "internal:compositor/bar"
import "modus:contract/ring"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:key_path"
import "modus:system"

pointer_lock_state: bar.Pointer_Lock_State

// pointer_lock_is_active reports whether a window currently holds pointer lock.
pointer_lock_is_active :: proc "contextless" () -> bool {
	return pointer_lock_state.active
}

// pointer_lock_modal_open reports whether any desktop modal, menu, palette,
// or keyboard mode currently prevents pointer lock acquisition.
@(private = "file")
pointer_lock_modal_open :: proc "contextless" () -> bool {
	return palette_is_open() ||
		trusted_dialog_open() ||
		desktop_context_menu.open ||
		menu_open != .None ||
		tray_state.open != .None ||
		capture_viewer_popover.open ||
		window_switcher.open ||
		keyboard_window_mode != .None ||
		bar_focus.kind != .None
}

// pointer_lock_command handles Command.Pointer_Lock from client index.
pointer_lock_command :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	mode, ok := display.pointer_lock_command_of_values(record.values)
	if !ok {
		if client.commands_refused == 0 {
			system.log_fact(.Info, Window_Word_Refused{word = u64(record.kind)})
		}
		client.commands_refused += 1
		return
	}
	has_focused := order_count > 0 && !clients[order[order_count - 1]].minimized
	focused := has_focused ? order[order_count - 1] : -1
	eligible_focus := has_focused && client.created && !client.minimized
	switch bar.pointer_lock_request(&pointer_lock_state, index, focused, eligible_focus, pointer_lock_modal_open(), mode) {
	case .None:
	case .Acquired:
		// Cancel any hover state before hiding the desktop cursor.
		if client.pointer_over {
			client.pointer_over = false
		}
		pointer_update(0)
		damage_bar()
		send(client, .Pointer_Lock_Changed, {0 = u64(display.Pointer_Lock_Mode.Acquire), 1 = u64(display.Pointer_Lock_Reason.Window_Request)})
		system.log_fact(.Info, Pointer_Lock_Acquired{window = window_field(client.title[:])})
	case .Released:
		key_path.window_queue_drop_pending_move(&window_queues[index], u32(display.Event_Kind.Pointer_Delta))
		pointer_update(0)
		damage_bar()
		send(client, .Pointer_Lock_Changed, {0 = u64(display.Pointer_Lock_Mode.Release), 1 = u64(display.Pointer_Lock_Reason.Window_Request)})
		system.log_fact(.Info, Pointer_Lock_Released{window = window_field(client.title[:])})
	case .Refused:
		send(client, .Pointer_Lock_Changed, {0 = u64(display.Pointer_Lock_Mode.Release), 1 = u64(display.Pointer_Lock_Reason.Refused)})
	}
}

// pointer_lock_release releases any active pointer lock and notifies its
// holder with reason.
pointer_lock_release :: proc "contextless" (reason: display.Pointer_Lock_Reason) {
	client_index, released := bar.pointer_lock_release(&pointer_lock_state)
	if !released {
		return
	}
	key_path.window_queue_drop_pending_move(&window_queues[client_index], u32(display.Event_Kind.Pointer_Delta))
	pointer_update(0)
	damage_bar()
	if client_index >= 0 && client_index < len(clients) && clients[client_index].ring.head != nil {
		client := &clients[client_index]
		send(client, .Pointer_Lock_Changed, {0 = u64(display.Pointer_Lock_Mode.Release), 1 = u64(reason)})
		system.log_fact(.Info, Pointer_Lock_Released{window = window_field(client.title[:])})
	}
}

// pointer_lock_release_by_key releases any active pointer lock triggered by a
// key shortcut handled before pointer_lock_key (such as Ctrl+Shift+Escape
// revoking an active wide grant) and records code so its key-up is swallowed.
pointer_lock_release_by_key :: proc "contextless" (code: u32) {
	if !pointer_lock_state.active {
		return
	}
	pointer_lock_state.kept_release_code = code
	pointer_lock_release(.Super_Key)
}

// pointer_lock_window_closed clears pointer lock if the closing window held it.
pointer_lock_window_closed :: proc "contextless" (index: int) {
	if !bar.pointer_lock_window_closed(&pointer_lock_state, index) {
		return
	}
	pointer_update(0)
	damage_bar()
}

// pointer_lock_key routes a key while pointer lock is active (or immediately
// after Super or Ctrl+Shift+Escape released it). Returns true when handled.
pointer_lock_key :: proc "contextless" (code: u32, pressed: bool, modifiers: u32, raw_values: [7]u64) -> bool {
	switch bar.pointer_lock_key_action(&pointer_lock_state, code, pressed, modifiers) {
	case .Not_Locked:
		return false
	case .Release_Lock:
		pointer_lock_release(.Super_Key)
		return true
	case .Swallow_Escape_Release:
		return true
	case .Deliver_To_Window:
		index := pointer_lock_state.client
		if index >= 0 && index < len(clients) && clients[index].ring.head != nil && !clients[index].minimized {
			send(&clients[index], .Key, quality_key_values(index, raw_values))
		}
		return true
	}
	return false
}

// pointer_lock_deliver_delta sends relative motion, button state, and wheel
// notches to the locked window without moving or clamping the desktop cursor.
pointer_lock_deliver_delta :: proc "contextless" (dx, dy: int, new_buttons: u32, wheel: int) {
	// Mask to the closed contract button bits so middle/extra bits never cause
	// display.event_of_record to reject the Pointer_Delta record.
	buttons = new_buttons & u32(display.BUTTON_LEFT | display.BUTTON_RIGHT)
	index := pointer_lock_state.client
	if index < 0 || index >= len(clients) || clients[index].ring.head == nil || clients[index].minimized {
		pointer_lock_release(.Focus_Lost)
		return
	}
	clamped_dx := clamp(i64(dx), -display.POINTER_DELTA_LIMIT, display.POINTER_DELTA_LIMIT)
	clamped_dy := clamp(i64(dy), -display.POINTER_DELTA_LIMIT, display.POINTER_DELTA_LIMIT)
	send(&clients[index], .Pointer_Delta, {0 = u64(clamped_dx), 1 = u64(clamped_dy), 2 = u64(buttons), 3 = u64(i64(wheel))})
}

// pointer_lock_mark_records draws the warning-outlined bar indicator while a
// window holds pointer lock so the principal always sees the Super escape key.
pointer_lock_mark_records :: proc "contextless" (table: ^interface.Draw_Table, right: int) -> (left: int) {
	if !pointer_lock_state.active {
		return right
	}
	full_width := interface.text_measured_width(table, interface.FONT_INTERFACE, bar.POINTER_LOCK_MARK_TEXT)
	short_width := interface.text_measured_width(table, interface.FONT_INTERFACE, bar.POINTER_LOCK_MARK_SHORT)
	mark := bar.pointer_lock_mark_place(full_width, short_width, right, bar.PLATES_X + bar.PLATE_WIDTH + 16)
	bar_top := desktop_bar_y()
	switch mark.form {
	case .Full:
		y := bar_top + bar.TRAY_Y
		interface.draw_outline(table, mark.x, y, mark.width, bar.TRAY_HEIGHT, 2, graphics.colors.warning)
		interface.draw_text(table, mark.x + bar.PADDING, y + (bar.TRAY_HEIGHT - graphics.CELL_HEIGHT) / 2, bar.POINTER_LOCK_MARK_TEXT, graphics.colors.text, interface.FONT_INTERFACE)
	case .Short:
		y := bar_top + bar.TRAY_Y
		interface.draw_outline(table, mark.x, y, mark.width, bar.TRAY_HEIGHT, 2, graphics.colors.warning)
		interface.draw_text(table, mark.x + bar.PADDING, y + (bar.TRAY_HEIGHT - graphics.CELL_HEIGHT) / 2, bar.POINTER_LOCK_MARK_SHORT, graphics.colors.text, interface.FONT_INTERFACE)
	case .Square:
		y := bar_top + bar.TRAY_Y + (bar.TRAY_HEIGHT - bar.POINTER_LOCK_MARK_SQUARE) / 2
		interface.draw_rectangle(table, mark.x, y, bar.POINTER_LOCK_MARK_SQUARE, bar.POINTER_LOCK_MARK_SQUARE, graphics.colors.warning)
	}
	return mark.x
}
