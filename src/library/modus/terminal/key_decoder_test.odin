#+build !freestanding
package terminal_records

import "core:testing"
import "modus:display"

// The bytes of one key of the page of the console (browser_machine_console.html)
// and of a terminal of the host, as the reader types it.
@(private = "file")
Typed_Key :: struct {
	bytes:     string,
	code:      u32,
	character: rune,
	modifiers: u32,
}

// Each sequence that a VT100 terminal sends gives its one key, and no key
// before its last byte: the arrows, Home and End in both forms, Delete,
// Page Up, Page Down, Shift+Tab, Tab, Enter as CR and as LF, Backspace as
// DEL and as BS, Control+A and Control+Z, a letter, and UTF-8 of two,
// three and four bytes.
@(test)
vt_decoder_gives_one_key_for_each_sequence_of_a_terminal :: proc(t: ^testing.T) {
	keys := [?]Typed_Key {
		{"\x1b[A", display.KEY_UP, 0, 0},
		{"\x1b[B", display.KEY_DOWN, 0, 0},
		{"\x1b[C", display.KEY_RIGHT, 0, 0},
		{"\x1b[D", display.KEY_LEFT, 0, 0},
		{"\x1b[H", display.KEY_HOME, 0, 0},
		{"\x1b[F", display.KEY_END, 0, 0},
		{"\x1b[1~", display.KEY_HOME, 0, 0},
		{"\x1b[7~", display.KEY_HOME, 0, 0},
		{"\x1b[4~", display.KEY_END, 0, 0},
		{"\x1b[8~", display.KEY_END, 0, 0},
		{"\x1b[3~", display.KEY_DELETE, 0, 0},
		{"\x1b[5~", display.KEY_PAGE_UP, 0, 0},
		{"\x1b[6~", display.KEY_PAGE_DOWN, 0, 0},
		{"\x1b[Z", display.KEY_TAB, 0, display.MODIFIER_SHIFT},
		{"\t", display.KEY_TAB, '\t', 0},
		{"\r", display.KEY_ENTER, '\n', 0},
		{"\n", display.KEY_ENTER, '\n', 0},
		{"\x7f", display.KEY_BACKSPACE, 0, 0},
		{"\x08", display.KEY_BACKSPACE, 0, 0},
		{"\x01", 0, 'a', display.MODIFIER_CONTROL},
		{"\x1a", 0, 'z', display.MODIFIER_CONTROL},
		{"q", 0, 'q', 0},
		{"é", 0, 'é', 0},
		{"€", 0, '€', 0},
		{"😀", 0, '😀', 0},
	}
	for typed in keys {
		decoder: Vt_Decoder
		bytes := transmute([]u8)typed.bytes
		for b, index in bytes {
			key, ok := vt_decode_byte(&decoder, b)
			if index < len(bytes) - 1 {
				testing.expectf(t, !ok, "%q gives a key before its last byte", typed.bytes)
				continue
			}
			testing.expectf(t, ok, "%q gives no key", typed.bytes)
			testing.expectf(t, key.code == typed.code && key.character == typed.character && key.modifiers == typed.modifiers, "%q gives %v", typed.bytes, key)
		}
		testing.expect_value(t, decoder.state, Vt_State.Ground)
	}
}

// A sequence that names no key gives no key and leaves the decoder in
// Ground: a final byte that no key has, a parameter of ~ that no key has, a
// control byte inside a sequence. An ESC inside a sequence starts the next
// one, so the key after it is kept. NUL, a continuation byte with no lead
// and the bytes 0xF8 to 0xFF give no key.
@(test)
vt_decoder_refuses_malformed_sequences :: proc(t: ^testing.T) {
	refused := [?]string{"\x1b[Q", "\x1b[9~", "\x1b[33~", "\x1b[\x07", "\x00", "\x80", "\xbf", "\xf8", "\xff"}
	for sequence in refused {
		decoder: Vt_Decoder
		for b in transmute([]u8)sequence {
			_, ok := vt_decode_byte(&decoder, b)
			testing.expectf(t, !ok, "%q gives a key", sequence)
		}
		testing.expectf(t, decoder.state == .Ground, "%q leaves the state %v", sequence, decoder.state)
	}
	decoder: Vt_Decoder
	for b in transmute([]u8)string("\x1b[1\x1b[") {
		_, ok := vt_decode_byte(&decoder, b)
		testing.expect(t, !ok)
	}
	key, ok := vt_decode_byte(&decoder, 'A')
	testing.expect(t, ok && key.code == display.KEY_UP)
	// An Escape and another byte: the key Escape; the flush with no Escape
	// gives nothing.
	_, _ = vt_decode_byte(&decoder, 0x1B)
	key, ok = vt_decode_byte(&decoder, 'x')
	testing.expect(t, ok && key.code == display.KEY_ESCAPE)
	_, ok = vt_flush_escape(&decoder)
	testing.expect(t, !ok)
}

// UTF-8 that names no character gives the replacement character: an
// overlong form of NUL, of '/' and of U+07FF and U+FFFF, a surrogate, a code
// point past U+10FFFF. A lead byte cut by an ASCII byte gives that byte as
// its key.
@(test)
vt_decoder_refuses_overlong_and_surrogate_utf8 :: proc(t: ^testing.T) {
	refused := [?]string{"\xc0\x80", "\xc0\xaf", "\xe0\x9f\xbf", "\xf0\x8f\xbf\xbf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xf7\xbf\xbf\xbf"}
	for sequence in refused {
		decoder: Vt_Decoder
		bytes := transmute([]u8)sequence
		key: Key
		ok: bool
		for b in bytes {
			key, ok = vt_decode_byte(&decoder, b)
		}
		testing.expectf(t, ok && key.character == REPLACEMENT_CHARACTER, "%q gives %v", sequence, key)
	}
	decoder: Vt_Decoder
	_, _ = vt_decode_byte(&decoder, 0xC3)
	key, ok := vt_decode_byte(&decoder, 'b')
	testing.expect(t, ok && key.character == 'b')
	testing.expect_value(t, decoder.state, Vt_State.Ground)
}

@(test)
vt_decoder_handles_arrows_ctrl_utf8_and_refuses_overlong_csi :: proc(t: ^testing.T) {
	dec: Vt_Decoder

	// Up arrow: ESC [ A
	_, ok0 := vt_decode_byte(&dec, 0x1B)
	testing.expect(t, !ok0)
	_, ok1 := vt_decode_byte(&dec, '[')
	testing.expect(t, !ok1)
	k_up, ok2 := vt_decode_byte(&dec, 'A')
	testing.expect(t, ok2 && k_up.code == display.KEY_UP)

	// Shift+Tab: ESC [ Z
	_, _ = vt_decode_byte(&dec, 0x1B)
	_, _ = vt_decode_byte(&dec, '[')
	k_stab, ok_st := vt_decode_byte(&dec, 'Z')
	testing.expect(t, ok_st && k_stab.code == display.KEY_TAB && k_stab.modifiers == display.MODIFIER_SHIFT)

	// Delete: ESC [ 3 ~
	for b in ([]u8{0x1B, '[', '3'}) {
		_, ok := vt_decode_byte(&dec, b)
		testing.expect(t, !ok)
	}
	k_del, ok_del := vt_decode_byte(&dec, '~')
	testing.expect(t, ok_del && k_del.code == display.KEY_DELETE)

	// Ctrl+R (0x12)
	k_cr, ok_cr := vt_decode_byte(&dec, 0x12)
	testing.expect(t, ok_cr && k_cr.character == 'r' && k_cr.modifiers == display.MODIFIER_CONTROL)

	// UTF-8 'é' (0xC3 0xA9)
	_, ok_u0 := vt_decode_byte(&dec, 0xC3)
	testing.expect(t, !ok_u0)
	k_u1, ok_u1 := vt_decode_byte(&dec, 0xA9)
	testing.expect(t, ok_u1 && k_u1.character == 'é')

	// Overlong CSI sequence (>16 params) resets cleanly to Ground without hanging.
	_, _ = vt_decode_byte(&dec, 0x1B)
	_, _ = vt_decode_byte(&dec, '[')
	for _ in 0 ..< CSI_BUFFER_LIMIT + 4 {
		_, _ = vt_decode_byte(&dec, '1')
	}
	testing.expect_value(t, dec.state, Vt_State.Ground)
	k_a, ok_a := vt_decode_byte(&dec, 'a')
	testing.expect(t, ok_a && k_a.character == 'a')

	// Standalone Escape via flush.
	_, _ = vt_decode_byte(&dec, 0x1B)
	k_esc, ok_esc := vt_flush_escape(&dec)
	testing.expect(t, ok_esc && k_esc.code == display.KEY_ESCAPE)
}
