#+build !freestanding
package usb_hid

import "core:testing"

@(test)
usb_keyboard_boot_report_diffs_and_refuses_rollover_error :: proc(t: ^testing.T) {
	_, bad_act := key_action_of_word(99)
	testing.expect(t, !bad_act)
	act, ok_act := key_action_of_word(u64(Key_Action.Press))
	testing.expect(t, ok_act && act == .Press)

	kb: Keyboard_State
	keyboard_state_init(&kb)
	events: [MAX_KEY_EVENTS_PER_REPORT]Key_Event

	// Short/long reports refused cleanly.
	_, r := keyboard_boot_report_apply(&kb, []u8{0, 0, 0}, events[:])
	testing.expect_value(t, r, Hid_Refusal.Report_Too_Short)
	_, r = keyboard_boot_report_apply(&kb, []u8{0, 0, 0, 0, 0, 0, 0, 0, 0}, events[:])
	testing.expect_value(t, r, Hid_Refusal.Report_Too_Long)

	// Press Left Shift + 'a' (0x04) + 'b' (0x05).
	n, r1 := keyboard_boot_report_apply(&kb, []u8{0x02, 0, 0x04, 0x05, 0, 0, 0, 0}, events[:])
	testing.expect_value(t, r1, Hid_Refusal.None)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, events[0].usage_id, u8(0xE1))
	testing.expect_value(t, events[0].action, Key_Action.Press)
	testing.expect_value(t, events[1].usage_id, u8(0x04))
	testing.expect_value(t, events[2].usage_id, u8(0x05))

	// Rollover error (0x01) refused WITHOUT mutating pressed state!
	_, r_err := keyboard_boot_report_apply(&kb, []u8{0x00, 0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01}, events[:])
	testing.expect_value(t, r_err, Hid_Refusal.Rollover_Error)
	testing.expect(t, .Left_Shift in kb.modifiers)
	testing.expect_value(t, kb.pressed[0], u8(0x04))

	// Release 'a', keep Shift + 'b', press 'c' (0x06).
	n2, r2 := keyboard_boot_report_apply(&kb, []u8{0x02, 0, 0x05, 0x06, 0, 0, 0, 0}, events[:])
	testing.expect_value(t, r2, Hid_Refusal.None)
	testing.expect_value(t, n2, 2)
	testing.expect_value(t, events[0].usage_id, u8(0x04))
	testing.expect_value(t, events[0].action, Key_Action.Release)
	testing.expect_value(t, events[1].usage_id, u8(0x06))
	testing.expect_value(t, events[1].action, Key_Action.Press)
}

@(test)
usb_pointer_boot_report_clamps_bounds_and_tracks_buttons :: proc(t: ^testing.T) {
	p: Pointer_State
	testing.expect_value(t, pointer_state_init(&p, 0, 1080), Hid_Refusal.Invalid_Bounds)
	testing.expect_value(t, pointer_state_init(&p, 1920, 1080), Hid_Refusal.None)
	testing.expect_value(t, p.x, i32(960))
	testing.expect_value(t, p.y, i32(540))

	_, r := pointer_boot_report_apply(&p, []u8{0, 0})
	testing.expect_value(t, r, Hid_Refusal.Report_Too_Short)

	// Move (-10, +25), wheel -1, left button down.
	ev, r1 := pointer_boot_report_apply(&p, []u8{0x01, u8(transmute(u8)i8(-10)), 25, u8(transmute(u8)i8(-1))})
	testing.expect_value(t, r1, Hid_Refusal.None)
	testing.expect_value(t, ev.x, i32(950))
	testing.expect_value(t, ev.y, i32(565))
	testing.expect_value(t, ev.wheel, i8(-1))
	testing.expect(t, .Left in ev.pressed_mask && ev.released_mask == {})

	// Clamp cleanly at (0, 0).
	p.x = 2
	p.y = 3
	ev2, r2 := pointer_boot_report_apply(&p, []u8{0x00, u8(transmute(u8)i8(-50)), u8(transmute(u8)i8(-50))})
	testing.expect_value(t, r2, Hid_Refusal.None)
	testing.expect_value(t, ev2.x, i32(0))
	testing.expect_value(t, ev2.y, i32(0))
	testing.expect(t, .Left in ev2.released_mask)
}
