package doom

import "modus:contract/enum_word"
import "modus:display"

// Doom key codes from doomkeys.h that cross the C input bridge.
Doom_Key :: enum u8 {
	None       = 0,
	Tab        = 9,
	Enter      = 13,
	Escape     = 27,
	Minus      = '-',
	Equals     = '=',
	Digit_0    = '0',
	Digit_1    = '1',
	Digit_2    = '2',
	Digit_3    = '3',
	Digit_4    = '4',
	Digit_5    = '5',
	Digit_6    = '6',
	Digit_7    = '7',
	Digit_8    = '8',
	Digit_9    = '9',
	Key_N      = 'n',
	Key_Y      = 'y',
	Backspace  = 0x7f,
	Strafe_L   = 0xa0,
	Strafe_R   = 0xa1,
	Use        = 0xa2,
	Fire       = 0xa3,
	Left       = 0xac,
	Up         = 0xad,
	Right      = 0xae,
	Down       = 0xaf,
	Rshift     = 0x80 + 0x36,
	Lalt       = 0x80 + 0x38,
	F1         = 0x80 + 0x3b,
	F2         = 0x80 + 0x3c,
	F3         = 0x80 + 0x3d,
	F4         = 0x80 + 0x3e,
	F5         = 0x80 + 0x3f,
	F6         = 0x80 + 0x40,
	F7         = 0x80 + 0x41,
	F8         = 0x80 + 0x42,
	F9         = 0x80 + 0x43,
	F10        = 0x80 + 0x44,
	F11        = 0x80 + 0x57,
	F12        = 0x80 + 0x58,
}

// PC set-1 scan codes handled by Doom's key mapper.
Scan_Code :: enum u32 {
	Escape      = display.KEY_ESCAPE,
	Digit_1     = 0x02,
	Digit_2     = 0x03,
	Digit_3     = 0x04,
	Digit_4     = 0x05,
	Digit_5     = 0x06,
	Digit_6     = 0x07,
	Digit_7     = 0x08,
	Digit_8     = 0x09,
	Digit_9     = 0x0A,
	Digit_0     = 0x0B,
	Minus       = 0x0C,
	Equals      = 0x0D,
	Backspace   = display.KEY_BACKSPACE,
	Tab         = display.KEY_TAB,
	W           = 0x11,
	E           = 0x12,
	Y           = 0x15,
	Enter       = display.KEY_ENTER,
	Ctrl_Left   = 0x1D,
	A           = 0x1E,
	S           = 0x1F,
	D           = 0x20,
	Shift_Left  = 0x2A,
	N           = 0x31,
	Shift_Right = 0x36,
	Alt_Left    = 0x38,
	Space       = display.KEY_SPACE,
	F1          = 0x3B,
	F2          = 0x3C,
	F3          = display.KEY_F3,
	F4          = 0x3E,
	F5          = 0x3F,
	F6          = 0x40,
	F7          = display.KEY_F7,
	F8          = display.KEY_F8,
	F9          = 0x43,
	F10         = display.KEY_F10,
	F11         = 0x57,
	F12         = 0x58,
	Ctrl_Right  = display.KEY_EXTENDED | 0x1D,
	Alt_Right   = display.KEY_EXTENDED | 0x38,
	Up          = display.KEY_UP,
	Left        = display.KEY_LEFT,
	Right       = display.KEY_RIGHT,
	Down        = display.KEY_DOWN,
}

// Inline capacity: 64 queued key transitions exceed the events arriving in one
// 35 Hz tic; overflow drops newest events and increments `dropped`.
KEY_QUEUE_CAPACITY :: 64

Key_Transition :: struct {
	pressed: bool,
	key:     u8,
}

Key_Queue :: struct {
	items:   [KEY_QUEUE_CAPACITY]Key_Transition,
	head:    int,
	count:   int,
	dropped: u64,
}

// Mouse state accumulated between Doom tics.
Mouse_Input :: struct {
	dx:      i32,
	dy:      i32,
	buttons: u32,
	pending: bool,
}

// doom_key_of_event translates a modus display key event into a doomkeys.h code.
// Returns 0 for keys that Doom does not consume.
doom_key_of_event :: proc "contextless" (code: u32, character: rune) -> u8 {
	if scan, known := enum_word.member_of_word(Scan_Code, u64(code)); known {
		switch scan {
		case .Escape:                   return u8(Doom_Key.Escape)
		case .Enter:                    return u8(Doom_Key.Enter)
		case .Tab:                      return u8(Doom_Key.Tab)
		case .Backspace:                return u8(Doom_Key.Backspace)
		case .Space, .E:                return u8(Doom_Key.Use)
		case .Up, .W:                   return u8(Doom_Key.Up)
		case .Down, .S:                 return u8(Doom_Key.Down)
		case .Left:                     return u8(Doom_Key.Left)
		case .Right:                    return u8(Doom_Key.Right)
		case .A:                        return u8(Doom_Key.Strafe_L)
		case .D:                        return u8(Doom_Key.Strafe_R)
		case .Ctrl_Left, .Ctrl_Right:   return u8(Doom_Key.Fire)
		case .Shift_Left, .Shift_Right: return u8(Doom_Key.Rshift)
		case .Alt_Left, .Alt_Right:     return u8(Doom_Key.Lalt)
		case .Minus:                    return u8(Doom_Key.Minus)
		case .Equals:                   return u8(Doom_Key.Equals)
		case .Digit_0:                  return u8(Doom_Key.Digit_0)
		case .Digit_1:                  return u8(Doom_Key.Digit_1)
		case .Digit_2:                  return u8(Doom_Key.Digit_2)
		case .Digit_3:                  return u8(Doom_Key.Digit_3)
		case .Digit_4:                  return u8(Doom_Key.Digit_4)
		case .Digit_5:                  return u8(Doom_Key.Digit_5)
		case .Digit_6:                  return u8(Doom_Key.Digit_6)
		case .Digit_7:                  return u8(Doom_Key.Digit_7)
		case .Digit_8:                  return u8(Doom_Key.Digit_8)
		case .Digit_9:                  return u8(Doom_Key.Digit_9)
		case .Y:                        return u8(Doom_Key.Key_Y)
		case .N:                        return u8(Doom_Key.Key_N)
		case .F1:                       return u8(Doom_Key.F1)
		case .F2:                       return u8(Doom_Key.F2)
		case .F3:                       return u8(Doom_Key.F3)
		case .F4:                       return u8(Doom_Key.F4)
		case .F5:                       return u8(Doom_Key.F5)
		case .F6:                       return u8(Doom_Key.F6)
		case .F7:                       return u8(Doom_Key.F7)
		case .F8:                       return u8(Doom_Key.F8)
		case .F9:                       return u8(Doom_Key.F9)
		case .F10:                      return u8(Doom_Key.F10)
		case .F11:                      return u8(Doom_Key.F11)
		case .F12:                      return u8(Doom_Key.F12)
		}
	}
	if character >= 'A' && character <= 'Z' {
		return u8(character - 'A' + 'a')
	}
	if character >= 0x20 && character <= 0x7E {
		return u8(character)
	}
	return 0
}

key_queue_push :: proc "contextless" (q: ^Key_Queue, pressed: bool, key: u8) {
	if key == 0 {
		return
	}
	if q.count >= KEY_QUEUE_CAPACITY {
		q.dropped += 1
		return
	}
	slot := (q.head + q.count) % KEY_QUEUE_CAPACITY
	q.items[slot] = {pressed = pressed, key = key}
	q.count += 1
}

key_queue_pop :: proc "contextless" (q: ^Key_Queue) -> (item: Key_Transition, ok: bool) {
	if q.count <= 0 {
		return {}, false
	}
	item = q.items[q.head]
	q.head = (q.head + 1) % KEY_QUEUE_CAPACITY
	q.count -= 1
	return item, true
}

// doom_mouse_buttons maps modus display buttons (BUTTON_LEFT | BUTTON_RIGHT)
// into Doom's mouse button bitmask (bit 0 fire, bit 1 strafe).
doom_mouse_buttons :: proc "contextless" (display_buttons: u32) -> u32 {
	out: u32
	if display_buttons & display.BUTTON_LEFT != 0 {
		out |= 1
	}
	if display_buttons & display.BUTTON_RIGHT != 0 {
		out |= 2
	}
	return out
}

// mouse_input_add accumulates relative pointer motion and button state for the
// next Doom tic, scaling raw logical deltas for responsive turning.
mouse_input_add :: proc "contextless" (m: ^Mouse_Input, dx, dy: i32, display_buttons: u32) {
	// Scale logical pointer deltas into Doom turning units so gentle motion turns cleanly.
	m.dx += dx * 4
	m.dy += dy * 4
	m.buttons = doom_mouse_buttons(display_buttons)
	m.pending = true
}

// mouse_input_set_buttons updates buttons from absolute Pointer events without
// injecting spurious relative turning deltas.
mouse_input_set_buttons :: proc "contextless" (m: ^Mouse_Input, display_buttons: u32) {
	next := doom_mouse_buttons(display_buttons)
	if next != m.buttons {
		m.buttons = next
		m.pending = true
	}
}

// mouse_input_clear releases held mouse buttons when pointer lock exits.
mouse_input_clear :: proc "contextless" (m: ^Mouse_Input) {
	if m.buttons != 0 || m.dx != 0 || m.dy != 0 {
		m.dx = 0
		m.dy = 0
		m.buttons = 0
		m.pending = true
	}
}

mouse_input_take :: proc "contextless" (m: ^Mouse_Input) -> (buttons: i32, dx, dy: i32, ok: bool) {
	if !m.pending {
		return 0, 0, 0, false
	}
	buttons = i32(m.buttons)
	dx = m.dx
	dy = m.dy
	m.dx = 0
	m.dy = 0
	m.pending = false
	return buttons, dx, dy, true
}
