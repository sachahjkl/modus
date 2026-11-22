#+build !freestanding
package ansi_terminal

import "core:strings"
import "core:testing"
import "modus:display"
import terminal_records "modus:terminal"

@(test)
ansi_render_emits_truecolor_tones_and_sanitizes_escape :: proc(t: ^testing.T) {
	buf: [1024]u8
	sink := sink_make(buf[:])
	text := transmute([]u8)string("ok\x1b[31m!")
	emit_styled_text(&sink, text, {tone = u8(terminal_records.Tone.Good), flags = {.End_Line}}, .Dark)
	out := string(sink_written(&sink))
	testing.expect(t, !sink.overflow)
	testing.expect(t, strings.contains(out, "\x1b[38;2;"))
	testing.expect(t, strings.contains(out, "ok?[31m!"))
	testing.expect(t, strings.has_suffix(out, "\x1b[K\r\n"))
}

@(test)
ansi_render_edit_line_highlights_code_runs_and_places_cursor :: proc(t: ^testing.T) {
	buf: [2048]u8
	sink := sink_make(buf[:])
	line := transmute([]u8)string("start(\"browser\")")
	runs := terminal_records.Code_Runs {
		count = 2,
		runs = {
			0 = {start = 0, length = 5, kind = u8(terminal_records.Code_Kind.Function)},
			1 = {start = 6, length = 9, kind = u8(terminal_records.Code_Kind.Text)},
		},
	}
	emit_edit_line(&sink, 12, line, &runs, 5, .Dark)
	out := string(sink_written(&sink))
	testing.expect(t, !sink.overflow)
	testing.expect(t, strings.contains(out, "\x1b[12;1H"))
	testing.expect(t, strings.contains(out, "start"))
	testing.expect(t, strings.contains(out, "\"browser\""))
	testing.expect(t, strings.has_suffix(out, "\x1b[12;6H"))
}

@(test)
ansi_render_completion_popup_draws_box_and_clears_on_close :: proc(t: ^testing.T) {
	buf: [4096]u8
	sink := sink_make(buf[:])
	list: terminal_records.List_Shown
	list.row_count = 2
	list.chosen = 1
	list.anchor = 2
	row0 := "startcommand"
	copy(list.rows[0].text[:], row0)
	list.rows[0].length = len(row0)
	list.rows[0].name_length = 5
	row1 := "stopstop process"
	copy(list.rows[1].text[:], row1)
	list.rows[1].length = len(row1)
	list.rows[1].name_length = 4

	emit_completion_popup(&sink, &list, 10, 80, .Dark)
	out := string(sink_written(&sink))
	testing.expect(t, !sink.overflow)
	testing.expect(t, strings.contains(out, "┌"))
	testing.expect(t, strings.contains(out, "┘"))
	testing.expect(t, strings.contains(out, "start"))
	testing.expect(t, strings.contains(out, "stop"))

	// Closing popup clears all popup lines cleanly.
	sink2 := sink_make(buf[:])
	empty: terminal_records.List_Shown
	emit_completion_popup(&sink2, &empty, 10, 80, .Dark)
	testing.expect(t, !sink2.overflow)
	testing.expect(t, strings.contains(string(sink_written(&sink2)), "\x1b[K"))
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
