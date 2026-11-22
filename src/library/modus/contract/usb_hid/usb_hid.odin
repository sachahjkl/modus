// Pure freestanding USB HID boot-protocol keyboard and pointer parser
// (src/md/features/device_services.md).
//
// Translates USB HID boot reports into typed key-press/key-release and
// pointer-delta events with rollover error refusal, bounds clamping, and zero
// dynamic allocations.
package usb_hid

import "modus:contract/enum_word"

// USB HID boot keyboard report length (modifier, reserved, 6 keycodes).
KEYBOARD_BOOT_REPORT_BYTES :: 8
KEYBOARD_ROLLOVER_SLOTS :: 6
KEYBOARD_ROLLOVER_ERROR_USAGE :: u8(0x01)
KEYBOARD_POST_FAIL_USAGE :: u8(0x02)
KEYBOARD_UNDEFINED_ERROR_USAGE :: u8(0x03)

// USB HID boot mouse report length (buttons, dx, dy, optional wheel).
POINTER_BOOT_REPORT_MIN_BYTES :: 3
POINTER_BOOT_REPORT_MAX_BYTES :: 8

// Maximum key events emitted from one keyboard report transition (6 releases + 6 presses + 8 modifiers).
MAX_KEY_EVENTS_PER_REPORT :: 20

Hid_Refusal :: enum u8 {
	None             = 0,
	Nil_State        = 1,
	Report_Too_Short = 2,
	Report_Too_Long  = 3,
	Rollover_Error   = 4,
	Invalid_Bounds   = 5,
}

Hid_Modifier :: enum u8 {
	Left_Control  = 0,
	Left_Shift    = 1,
	Left_Alt      = 2,
	Left_Super    = 3,
	Right_Control = 4,
	Right_Shift   = 5,
	Right_Alt     = 6,
	Right_Super   = 7,
}

Hid_Modifiers :: bit_set[Hid_Modifier; u8]

Key_Action :: enum u8 {
	Release = 0,
	Press   = 1,
}

key_action_of_word :: proc "contextless" (word: u64) -> (action: Key_Action, ok: bool) {
	return enum_word.member_of_word(Key_Action, word)
}

Key_Event :: struct {
	usage_id:  u8, // USB HID Usage Page 0x07 code (0x04='a'..'z', 0xE0..0xE7 modifiers).
	action:    Key_Action,
	modifiers: Hid_Modifiers,
}

Keyboard_State :: struct {
	modifiers: Hid_Modifiers,
	pressed:   [KEYBOARD_ROLLOVER_SLOTS]u8,
}

keyboard_state_init :: proc "contextless" (state: ^Keyboard_State) {
	if state == nil {
		return
	}
	state^ = {}
}

@(private = "file")
usage_in_slice :: proc "contextless" (usages: []u8, target: u8) -> bool {
	if target == 0 {
		return false
	}
	for u in usages {
		if u == target {
			return true
		}
	}
	return false
}

// keyboard_boot_report_apply parses an 8-byte USB HID boot keyboard report and
// writes differential press/release Key_Event records into events_out.
// Refuses Rollover_Error (0x01/0x02/0x03) without mutating keyboard state.
keyboard_boot_report_apply :: proc "contextless" (
	state: ^Keyboard_State,
	report: []u8,
	events_out: []Key_Event,
) -> (event_count: int, refusal: Hid_Refusal) {
	if state == nil {
		return 0, .Nil_State
	}
	if len(report) < KEYBOARD_BOOT_REPORT_BYTES {
		return 0, .Report_Too_Short
	}
	if len(report) > KEYBOARD_BOOT_REPORT_BYTES {
		return 0, .Report_Too_Long
	}

	next_keys: [KEYBOARD_ROLLOVER_SLOTS]u8
	for i in 0 ..< KEYBOARD_ROLLOVER_SLOTS {
		u := report[2 + i]
		if u == KEYBOARD_ROLLOVER_ERROR_USAGE || u == KEYBOARD_POST_FAIL_USAGE || u == KEYBOARD_UNDEFINED_ERROR_USAGE {
			return 0, .Rollover_Error
		}
		next_keys[i] = u
	}

	next_mods := transmute(Hid_Modifiers)report[0]
	old_mods := state.modifiers
	count := 0

	emit :: proc "contextless" (out: []Key_Event, count: ^int, usage: u8, action: Key_Action, mods: Hid_Modifiers) {
		if count^ < len(out) {
			out[count^] = {usage_id = usage, action = action, modifiers = mods}
		}
		count^ += 1
	}

	// 1. Modifier transitions (USB HID usages 0xE0..0xE7).
	for mod in Hid_Modifier {
		was := mod in old_mods
		now := mod in next_mods
		if was != now {
			emit(events_out, &count, u8(0xE0) + u8(mod), now ? .Press : .Release, next_mods)
		}
	}
	// 2. Released keys.
	for old_u in state.pressed {
		if old_u != 0 && !usage_in_slice(next_keys[:], old_u) {
			emit(events_out, &count, old_u, .Release, next_mods)
		}
	}
	// 3. Newly pressed keys (deduplicated within report).
	for i in 0 ..< KEYBOARD_ROLLOVER_SLOTS {
		new_u := next_keys[i]
		if new_u == 0 || usage_in_slice(next_keys[:i], new_u) {
			continue
		}
		if !usage_in_slice(state.pressed[:], new_u) {
			emit(events_out, &count, new_u, .Press, next_mods)
		}
	}

	state.modifiers = next_mods
	state.pressed = next_keys
	return min(count, len(events_out)), .None
}

// ============================================================================
// USB HID Boot Pointer (Mouse)
// ============================================================================

Pointer_Button :: enum u8 {
	Left   = 0,
	Right  = 1,
	Middle = 2,
}

Pointer_Buttons :: bit_set[Pointer_Button; u8]

Pointer_Event :: struct {
	x:             i32,
	y:             i32,
	dx:            i8,
	dy:            i8,
	wheel:         i8,
	buttons:       Pointer_Buttons,
	pressed_mask:  Pointer_Buttons,
	released_mask: Pointer_Buttons,
}

Pointer_State :: struct {
	screen_width:  i32,
	screen_height: i32,
	x:             i32,
	y:             i32,
	buttons:       Pointer_Buttons,
}

pointer_state_init :: proc "contextless" (state: ^Pointer_State, screen_width, screen_height: i32) -> Hid_Refusal {
	if state == nil {
		return .Nil_State
	}
	if screen_width <= 0 || screen_height <= 0 {
		return .Invalid_Bounds
	}
	state^ = {
		screen_width  = screen_width,
		screen_height = screen_height,
		x             = screen_width / 2,
		y             = screen_height / 2,
	}
	return .None
}

// pointer_boot_report_apply parses a 3..8-byte USB HID boot mouse report,
// clamping pointer coordinates to [0, screen_width - 1] x [0, screen_height - 1].
pointer_boot_report_apply :: proc "contextless" (
	state: ^Pointer_State,
	report: []u8,
) -> (event: Pointer_Event, refusal: Hid_Refusal) {
	if state == nil {
		return {}, .Nil_State
	}
	if state.screen_width <= 0 || state.screen_height <= 0 {
		return {}, .Invalid_Bounds
	}
	if len(report) < POINTER_BOOT_REPORT_MIN_BYTES {
		return {}, .Report_Too_Short
	}
	if len(report) > POINTER_BOOT_REPORT_MAX_BYTES {
		return {}, .Report_Too_Long
	}

	raw_buttons := report[0] & 0x07
	next_buttons := transmute(Pointer_Buttons)raw_buttons
	dx := i8(report[1])
	dy := i8(report[2])
	wheel := len(report) >= 4 ? i8(report[3]) : i8(0)

	next_x := clamp(i64(state.x) + i64(dx), 0, i64(state.screen_width - 1))
	next_y := clamp(i64(state.y) + i64(dy), 0, i64(state.screen_height - 1))

	pressed := next_buttons - state.buttons
	released := state.buttons - next_buttons

	state.x = i32(next_x)
	state.y = i32(next_y)
	state.buttons = next_buttons

	return Pointer_Event{
		x             = state.x,
		y             = state.y,
		dx            = dx,
		dy            = dy,
		wheel         = wheel,
		buttons       = next_buttons,
		pressed_mask  = pressed,
		released_mask = released,
	}, .None
}
