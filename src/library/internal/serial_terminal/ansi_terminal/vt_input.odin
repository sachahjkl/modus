// Stateful non-blocking VT100 / UTF-8 input decoder for serial_terminal
// (src/md/features/console_renderers.md, "Variant A: serial_terminal").
//
// Translates raw serial bytes of the second serial port (COM2) into typed
// terminal_records.Key values matching display.KEY_* and display.MODIFIER_*,
// refusing malformed or overlong CSI sequences and overlong or surrogate
// UTF-8 cleanly without blocking.
package ansi_terminal

import "modus:display"
import terminal_records "modus:terminal"

Vt_State :: enum u8 {
	Ground = 0,
	Escape = 1,
	Csi    = 2,
	Utf8   = 3,
}

CSI_BUFFER_LIMIT :: 16

Vt_Decoder :: struct {
	state:      Vt_State,
	csi:        [CSI_BUFFER_LIMIT]u8,
	csi_count:  int,
	utf8_value: u32,
	utf8_need:  u8,
	utf8_least: u32, // The least code point of the length of the sequence: a smaller one is overlong.
}

// The replacement character, for a UTF-8 sequence that names no character.
REPLACEMENT_CHARACTER :: rune(0xFFFD)

// vt_decode_byte feeds one raw byte from the serial port into the decoder.
// When a complete key is ready, ok is true.
vt_decode_byte :: proc "contextless" (decoder: ^Vt_Decoder, b: u8) -> (key: terminal_records.Key, ok: bool) {
	switch decoder.state {
	case .Ground:
		return vt_ground(decoder, b)
	case .Escape:
		if b == '[' {
			decoder.state = .Csi
			decoder.csi_count = 0
			return {}, false
		}
		// Standalone ESC followed by another byte: emit ESC and reset.
		decoder.state = .Ground
		return {code = display.KEY_ESCAPE}, true
	case .Csi:
		return vt_csi(decoder, b)
	case .Utf8:
		if (b & 0xC0) != 0x80 {
			decoder.state = .Ground
			return vt_ground(decoder, b)
		}
		decoder.utf8_value = (decoder.utf8_value << 6) | u32(b & 0x3F)
		decoder.utf8_need -= 1
		if decoder.utf8_need == 0 {
			decoder.state = .Ground
			r := rune(decoder.utf8_value)
			if r > 0x10FFFF || (r >= 0xD800 && r <= 0xDFFF) || decoder.utf8_value < decoder.utf8_least {
				r = REPLACEMENT_CHARACTER
			}
			return {character = r}, true
		}
		return {}, false
	}
	decoder.state = .Ground
	return {}, false
}

// vt_flush_escape emits a pending standalone Escape when no follow-up byte
// arrived within the inter-byte timeout.
vt_flush_escape :: proc "contextless" (decoder: ^Vt_Decoder) -> (key: terminal_records.Key, ok: bool) {
	if decoder.state == .Escape {
		decoder.state = .Ground
		return {code = display.KEY_ESCAPE}, true
	}
	return {}, false
}

@(private = "file")
vt_ground :: proc "contextless" (decoder: ^Vt_Decoder, b: u8) -> (key: terminal_records.Key, ok: bool) {
	switch b {
	case 0x1B:
		decoder.state = .Escape
		return {}, false
	case '\r', '\n':
		return {code = display.KEY_ENTER, character = '\n'}, true
	case '\t':
		return {code = display.KEY_TAB, character = '\t'}, true
	case 0x7F, 0x08:
		return {code = display.KEY_BACKSPACE}, true
	}
	// Control-A (1) through Control-Z (26), excluding Tab/CR/LF/BS above.
	if b >= 1 && b <= 26 {
		return {character = rune('a' + b - 1), modifiers = display.MODIFIER_CONTROL}, true
	}
	if b >= 0x20 && b < 0x7F {
		return {character = rune(b)}, true
	}
	// UTF-8 leading bytes.
	if (b & 0xE0) == 0xC0 {
		decoder.state = .Utf8
		decoder.utf8_value = u32(b & 0x1F)
		decoder.utf8_need = 1
		decoder.utf8_least = 0x80
		return {}, false
	}
	if (b & 0xF0) == 0xE0 {
		decoder.state = .Utf8
		decoder.utf8_value = u32(b & 0x0F)
		decoder.utf8_need = 2
		decoder.utf8_least = 0x800
		return {}, false
	}
	if (b & 0xF8) == 0xF0 {
		decoder.state = .Utf8
		decoder.utf8_value = u32(b & 0x07)
		decoder.utf8_need = 3
		decoder.utf8_least = 0x10000
		return {}, false
	}
	// A continuation byte with no lead, 0xF8 to 0xFF, NUL and the control
	// bytes that name no key: no key.
	return {}, false
}

@(private = "file")
vt_csi :: proc "contextless" (decoder: ^Vt_Decoder, b: u8) -> (key: terminal_records.Key, ok: bool) {
	// An ESC inside a sequence starts a new one: the reader pressed a key
	// before the sequence of the last one ended, and the new key is kept.
	if b == 0x1B {
		decoder.state = .Escape
		decoder.csi_count = 0
		return {}, false
	}
	// Parameter / intermediate bytes: 0x20..0x3F.
	if b >= 0x20 && b <= 0x3F {
		if decoder.csi_count >= CSI_BUFFER_LIMIT {
			// Overlong CSI sequence: refuse cleanly and return to Ground.
			decoder.state = .Ground
			decoder.csi_count = 0
			return {}, false
		}
		decoder.csi[decoder.csi_count] = b
		decoder.csi_count += 1
		return {}, false
	}
	// Final byte: 0x40..0x7E.
	decoder.state = .Ground
	params := string(decoder.csi[:decoder.csi_count])
	decoder.csi_count = 0
	if b < 0x40 || b > 0x7E {
		return {}, false
	}
	switch b {
	case 'A':
		return {code = display.KEY_UP}, true
	case 'B':
		return {code = display.KEY_DOWN}, true
	case 'C':
		return {code = display.KEY_RIGHT}, true
	case 'D':
		return {code = display.KEY_LEFT}, true
	case 'H':
		return {code = display.KEY_HOME}, true
	case 'F':
		return {code = display.KEY_END}, true
	case 'Z':
		return {code = display.KEY_TAB, modifiers = display.MODIFIER_SHIFT}, true
	case '~':
		switch params {
		case "1", "7":
			return {code = display.KEY_HOME}, true
		case "3":
			return {code = display.KEY_DELETE}, true
		case "4", "8":
			return {code = display.KEY_END}, true
		case "5":
			return {code = display.KEY_PAGE_UP}, true
		case "6":
			return {code = display.KEY_PAGE_DOWN}, true
		}
	}
	return {}, false
}
