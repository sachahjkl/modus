#+build !freestanding
package bar

import "core:testing"
import "modus:display"

// Unfocused windows, missing focus, and open desktop modals are refused
// without changing pointer lock state.
@(test)
pointer_lock_refuses_unfocused_and_modal_requests :: proc(t: ^testing.T) {
	state: Pointer_Lock_State
	testing.expect_value(t, pointer_lock_request(&state, 2, 2, false, false, .Acquire), Pointer_Lock_Request_Action.Refused)
	testing.expect_value(t, state, Pointer_Lock_State{})

	testing.expect_value(t, pointer_lock_request(&state, 1, 2, true, false, .Acquire), Pointer_Lock_Request_Action.Refused)
	testing.expect_value(t, state, Pointer_Lock_State{})

	testing.expect_value(t, pointer_lock_request(&state, 2, 2, true, true, .Acquire), Pointer_Lock_Request_Action.Refused)
	testing.expect_value(t, state, Pointer_Lock_State{})

	// Releasing while unlocked (whether focused or not, e.g. uncreated/minimized) does nothing.
	testing.expect_value(t, pointer_lock_request(&state, 2, 2, true, false, .Release), Pointer_Lock_Request_Action.None)
	testing.expect_value(t, pointer_lock_request(&state, 2, 2, false, false, .Release), Pointer_Lock_Request_Action.None)
	_, released := pointer_lock_release(&state)
	testing.expect(t, !released)
	testing.expect_value(t, state, Pointer_Lock_State{})
}

// Acquire when focused succeeds, another window cannot steal or release it,
// and release / focus loss / window close cleanly unlock.
@(test)
pointer_lock_transitions_acquire_release_and_close :: proc(t: ^testing.T) {
	state: Pointer_Lock_State
	testing.expect_value(t, pointer_lock_request(&state, 3, 3, true, false, .Acquire), Pointer_Lock_Request_Action.Acquired)
	testing.expect(t, state.active && state.client == 3)

	// Duplicate acquire by the holder is a no-op.
	testing.expect_value(t, pointer_lock_request(&state, 3, 3, true, false, .Acquire), Pointer_Lock_Request_Action.None)
	testing.expect(t, state.active && state.client == 3)

	// Another window cannot steal lock or release another client's lock.
	testing.expect_value(t, pointer_lock_request(&state, 4, 3, true, false, .Acquire), Pointer_Lock_Request_Action.Refused)
	testing.expect_value(t, pointer_lock_request(&state, 4, 3, true, false, .Release), Pointer_Lock_Request_Action.None)
	testing.expect(t, state.active && state.client == 3)

	// Closing a different window leaves lock intact.
	testing.expect(t, !pointer_lock_window_closed(&state, 4))
	testing.expect(t, state.active && state.client == 3)

	// Explicit release by holder unlocks cleanly.
	testing.expect_value(t, pointer_lock_request(&state, 3, 3, true, false, .Release), Pointer_Lock_Request_Action.Released)
	testing.expect_value(t, state, Pointer_Lock_State{})

	// Focus loss releases active lock and returns its client.
	testing.expect_value(t, pointer_lock_request(&state, 5, 5, true, false, .Acquire), Pointer_Lock_Request_Action.Acquired)
	old_client, released := pointer_lock_release(&state)
	testing.expect(t, released && old_client == 5)
	testing.expect_value(t, state, Pointer_Lock_State{})

	// Closing the holder clears lock.
	testing.expect_value(t, pointer_lock_request(&state, 6, 6, true, false, .Acquire), Pointer_Lock_Request_Action.Acquired)
	testing.expect(t, pointer_lock_window_closed(&state, 6))
	testing.expect_value(t, state, Pointer_Lock_State{})
}

// While locked, Super or Ctrl+Shift+Escape press releases lock and its matching
// release is swallowed; plain Escape, Ctrl+Escape, Shift+Escape, arrows, and
// shortcut keys go directly to the locked window.
@(test)
pointer_lock_key_routing_frees_super_and_passes_game_keys :: proc(t: ^testing.T) {
	state: Pointer_Lock_State
	ctrl_shift := u32(display.MODIFIER_CONTROL | display.MODIFIER_SHIFT)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_SUPER, true, 0), Pointer_Lock_Key_Action.Not_Locked)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_ESCAPE, true, ctrl_shift), Pointer_Lock_Key_Action.Not_Locked)

	testing.expect_value(t, pointer_lock_request(&state, 1, 1, true, false, .Acquire), Pointer_Lock_Request_Action.Acquired)
	for code in ([?]u32{display.KEY_ESCAPE, display.KEY_LEFT, display.KEY_RIGHT, display.KEY_UP, display.KEY_DOWN, display.KEY_TAB, display.KEY_F7, display.KEY_F8, display.KEY_F10, display.KEY_SPACE}) {
		testing.expect_value(t, pointer_lock_key_action(&state, code, true, 0), Pointer_Lock_Key_Action.Deliver_To_Window)
		testing.expect_value(t, pointer_lock_key_action(&state, code, false, 0), Pointer_Lock_Key_Action.Deliver_To_Window)
	}
	// Ctrl+Escape alone and Shift+Escape alone stay inside the locked window.
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_ESCAPE, true, u32(display.MODIFIER_CONTROL)), Pointer_Lock_Key_Action.Deliver_To_Window)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_ESCAPE, true, u32(display.MODIFIER_SHIFT)), Pointer_Lock_Key_Action.Deliver_To_Window)
	// Ctrl+Shift+Arrow bypasses desktop snap and goes to the locked window.
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_LEFT, true, ctrl_shift), Pointer_Lock_Key_Action.Deliver_To_Window)

	// Super press triggers release.
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_SUPER, true, 0), Pointer_Lock_Key_Action.Release_Lock)
	_, released := pointer_lock_release(&state)
	testing.expect(t, released)
	// Matching Super release is swallowed once, then normal routing resumes.
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_SUPER, false, 0), Pointer_Lock_Key_Action.Swallow_Escape_Release)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_SUPER, false, 0), Pointer_Lock_Key_Action.Not_Locked)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_SUPER, true, 0), Pointer_Lock_Key_Action.Not_Locked)

	// Ctrl+Shift+Escape also releases lock unconditionally, and its Escape
	// release is swallowed once even if modifiers were released first.
	testing.expect_value(t, pointer_lock_request(&state, 1, 1, true, false, .Acquire), Pointer_Lock_Request_Action.Acquired)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_ESCAPE, true, ctrl_shift), Pointer_Lock_Key_Action.Release_Lock)
	_, released_esc := pointer_lock_release(&state)
	testing.expect(t, released_esc)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_ESCAPE, false, 0), Pointer_Lock_Key_Action.Swallow_Escape_Release)
	testing.expect_value(t, pointer_lock_key_action(&state, display.KEY_ESCAPE, false, 0), Pointer_Lock_Key_Action.Not_Locked)
}

// Right-click opens the desktop menu only on empty desktop background; over a
// window surface it delivers to that window, over a window frame it raises
// without delivering out-of-surface coordinates, over the bar or an overlay it
// never leaks to a window, and while pointer locked it always delivers to the
// locked window.
@(test)
right_click_decision_separates_window_and_empty_desktop :: proc(t: ^testing.T) {
	// Empty desktop background (window_position < 0).
	testing.expect_value(t, right_click_decide(false, false, false, -1, false), Right_Click_Action.Open_Desktop_Menu)
	// Over any window client surface (position 0 or higher, on_window_surface = true).
	testing.expect_value(t, right_click_decide(false, false, false, 0, true), Right_Click_Action.Deliver_To_Window_Surface)
	testing.expect_value(t, right_click_decide(false, false, false, 3, true), Right_Click_Action.Deliver_To_Window_Surface)
	// Over a window title bar or border (position >= 0, on_window_surface = false).
	testing.expect_value(t, right_click_decide(false, false, false, 0, false), Right_Click_Action.Raise_Window_Frame)
	testing.expect_value(t, right_click_decide(false, false, false, 2, false), Right_Click_Action.Raise_Window_Frame)
	// In bar or with menu / tray / popover overlay open (even if a window sits behind).
	testing.expect_value(t, right_click_decide(false, false, true, -1, false), Right_Click_Action.Bar_Or_Overlay)
	testing.expect_value(t, right_click_decide(false, false, true, 0, true), Right_Click_Action.Bar_Or_Overlay)
	testing.expect_value(t, right_click_decide(false, true, false, -1, false), Right_Click_Action.Bar_Or_Overlay)
	testing.expect_value(t, right_click_decide(false, true, false, 0, true), Right_Click_Action.Bar_Or_Overlay)
	// While pointer locked, even if cursor coordinates were on empty desktop or bar.
	testing.expect_value(t, right_click_decide(true, false, false, -1, false), Right_Click_Action.Deliver_To_Locked_Window)
	testing.expect_value(t, right_click_decide(true, true, true, -1, false), Right_Click_Action.Deliver_To_Locked_Window)
}

// Bar mark picks full text, short text, or warning square based on room.
@(test)
pointer_lock_mark_place_fits_available_room :: proc(t: ^testing.T) {
	full := pointer_lock_mark_place(140, 96, 800, 300)
	testing.expect_value(t, full.form, Pointer_Lock_Mark_Form.Full)
	testing.expect_value(t, full.width, 140 + 2 * PADDING)
	testing.expect_value(t, full.x + full.width, 800)

	short := pointer_lock_mark_place(140, 96, 420, 300)
	testing.expect_value(t, short.form, Pointer_Lock_Mark_Form.Short)
	testing.expect_value(t, short.width, 96 + 2 * PADDING)
	testing.expect_value(t, short.x + short.width, 420)

	sq := pointer_lock_mark_place(140, 96, 350, 300)
	testing.expect_value(t, sq.form, Pointer_Lock_Mark_Form.Square)
	testing.expect_value(t, sq.width, POINTER_LOCK_MARK_SQUARE)
	testing.expect_value(t, sq.x + sq.width, 350)
}
