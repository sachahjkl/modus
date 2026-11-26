package bar

import "modus:display"

// Pointer lock state and input routing rules for the compositor
// (src/md/features/doom.md). The zero value is unlocked.
Pointer_Lock_State :: struct {
	active:            bool,
	client:            int,
	kept_release_code: u32, // Key code that ended lock (Super or Escape) until its key-up arrives.
}

// What the compositor must do after a window sends Command.Pointer_Lock.
Pointer_Lock_Request_Action :: enum u8 {
	None, // State unchanged; no event needed.
	Acquired, // Lock granted to this window; hide cursor and send Acquire.
	Released, // Lock released by this window; restore cursor and send Release.
	Refused, // Unfocused or modal open; state unchanged and send Refused.
}

// pointer_lock_request applies a window's Command.Pointer_Lock request.
// Only the focused window can acquire lock, and never while a desktop modal,
// menu, palette, or keyboard mode holds focus.
pointer_lock_request :: proc "contextless" (state: ^Pointer_Lock_State, client, focused_client: int, has_focused, desktop_modal_open: bool, mode: display.Pointer_Lock_Mode) -> Pointer_Lock_Request_Action {
	switch mode {
	case .Acquire:
		if !has_focused || client != focused_client || desktop_modal_open {
			return .Refused
		}
		if state.active && state.client == client {
			return .None
		}
		state.active = true
		state.client = client
		state.kept_release_code = 0
		return .Acquired
	case .Release:
		if !state.active || state.client != client {
			return .None
		}
		state.active = false
		state.client = 0
		return .Released
	}
	return .None
}

// pointer_lock_release clears an active pointer lock and gives the client
// that held it. When unlocked, it changes nothing and returns false.
pointer_lock_release :: proc "contextless" (state: ^Pointer_Lock_State) -> (client: int, released: bool) {
	if !state.active {
		return 0, false
	}
	client = state.client
	state.active = false
	state.client = 0
	return client, true
}

// pointer_lock_window_closed clears pointer lock if the closing window held it.
pointer_lock_window_closed :: proc "contextless" (state: ^Pointer_Lock_State, client: int) -> (cleared: bool) {
	if !state.active || state.client != client {
		return false
	}
	state.active = false
	state.client = 0
	return true
}

// How the compositor routes one key event under pointer lock.
Pointer_Lock_Key_Action :: enum u8 {
	Not_Locked, // Pointer is not locked; normal compositor key handling runs.
	Release_Lock, // Super or Ctrl+Shift+Escape pressed while locked; release lock and swallow key.
	Swallow_Escape_Release, // Release of the Super or Escape key that ended pointer lock.
	Deliver_To_Window, // Deliver directly to the locked window, bypassing desktop shortcuts.
}

// pointer_lock_key_action decides how a key event routes while pointer lock is
// active (or immediately after Super or Ctrl+Shift+Escape released it). Both
// Super and Ctrl+Shift+Escape always release lock so no process can trap input;
// every other key (including plain Escape, Alt+Tab, Ctrl+C, and
// Ctrl+Shift+Arrow) goes directly to the locked window.
pointer_lock_key_action :: proc "contextless" (state: ^Pointer_Lock_State, code: u32, pressed: bool, modifiers: u32) -> Pointer_Lock_Key_Action {
	if !state.active {
		if !pressed && state.kept_release_code != 0 && code == state.kept_release_code {
			state.kept_release_code = 0
			return .Swallow_Escape_Release
		}
		return .Not_Locked
	}
	ctrl_shift := u32(display.MODIFIER_CONTROL | display.MODIFIER_SHIFT)
	if pressed && code == display.KEY_SUPER {
		state.kept_release_code = display.KEY_SUPER
		return .Release_Lock
	}
	if pressed && code == display.KEY_ESCAPE && (modifiers & ctrl_shift) == ctrl_shift {
		state.kept_release_code = display.KEY_ESCAPE
		return .Release_Lock
	}
	return .Deliver_To_Window
}

// How the compositor handles a right-button press on the desktop.
Right_Click_Action :: enum u8 {
	Deliver_To_Locked_Window, // Pointer lock is active; deliver relative/button event to locked window.
	Open_Desktop_Menu, // Empty desktop background; open desktop context menu.
	Deliver_To_Window_Surface, // Over a window client surface; raise and deliver right button to that window.
	Raise_Window_Frame, // Over a window title bar or border; raise without sending out-of-surface coordinates.
	Bar_Or_Overlay, // Inside the bar or while a menu, tray widget, or popover overlay is open.
}

// right_click_decide determines whether a right-button press opens the desktop
// context menu, stays in the bar/overlay, raises a window frame, or reaches
// the window surface under the pointer.
right_click_decide :: proc "contextless" (pointer_locked, overlay_open, in_bar: bool, window_position: int, on_window_surface: bool) -> Right_Click_Action {
	if pointer_locked {
		return .Deliver_To_Locked_Window
	}
	if overlay_open || in_bar {
		return .Bar_Or_Overlay
	}
	if window_position < 0 {
		return .Open_Desktop_Menu
	}
	if !on_window_surface {
		return .Raise_Window_Frame
	}
	return .Deliver_To_Window_Surface
}

// The bar mark shown while a window holds pointer lock so the principal always
// sees the escape key.
POINTER_LOCK_MARK_TEXT :: "Pointer locked (Super)"
POINTER_LOCK_MARK_SHORT :: "Locked (Super)"
POINTER_LOCK_MARK_SQUARE :: 16 // Format property: matches CAPTURE_MARK_SQUARE and ASSISTIVE_MARK_SQUARE.

Pointer_Lock_Mark_Form :: enum u8 {
	Full,
	Short,
	Square,
}

Pointer_Lock_Mark :: struct {
	x:     int,
	width: int,
	form:  Pointer_Lock_Mark_Form,
}

// pointer_lock_mark_place places the pointer lock bar mark ending at right and
// staying at or right of left_floor so it never overlaps window plates.
pointer_lock_mark_place :: proc "contextless" (full_text_width, short_text_width, right, left_floor: int) -> Pointer_Lock_Mark {
	room := right - left_floor
	full_width := full_text_width + 2 * PADDING
	if full_width <= room {
		return {x = right - full_width, width = full_width, form = .Full}
	}
	short_width := short_text_width + 2 * PADDING
	if short_width <= room {
		return {x = right - short_width, width = short_width, form = .Short}
	}
	return {x = right - POINTER_LOCK_MARK_SQUARE, width = POINTER_LOCK_MARK_SQUARE, form = .Square}
}
