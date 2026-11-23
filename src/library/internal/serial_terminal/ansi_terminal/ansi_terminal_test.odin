#+build !freestanding
package ansi_terminal

import "core:strings"
import "core:testing"
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
	emit_edit_line(&sink, 12, line, runs.runs[:runs.count], 5, .Dark)
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

	emit_completion_popup(&sink, &list, 10, 80, 26, .Dark)
	out := string(sink_written(&sink))
	testing.expect(t, !sink.overflow)
	testing.expect(t, strings.contains(out, "┌"))
	testing.expect(t, strings.contains(out, "┘"))
	testing.expect(t, strings.contains(out, "start"))
	testing.expect(t, strings.contains(out, "stop"))

	// Closing popup clears all popup lines cleanly.
	sink2 := sink_make(buf[:])
	empty: terminal_records.List_Shown
	emit_completion_popup(&sink2, &empty, 10, 80, 26, .Dark)
	testing.expect(t, !sink2.overflow)
	testing.expect(t, strings.contains(string(sink_written(&sink2)), "\x1b[2K"))
}

