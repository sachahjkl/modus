#+build !freestanding
package ansi_terminal

import "core:strings"
import "core:testing"
import "modus:graphics"
import terminal_records "modus:terminal"

@(private = "file")
sanitized :: proc(text: string) -> string {
	buf := make([]u8, 4 * len(text) + 8, context.temp_allocator)
	sink := sink_make(buf)
	sink_sanitized(&sink, transmute([]u8)text)
	return strings.clone(string(sink_written(&sink)), context.temp_allocator)
}

// Each byte alone: a C0 control but Tab, Delete, and each byte 0x80 to 0xFF,
// which is no whole UTF-8 sequence alone, gives one '?'; Tab and each
// printable ASCII byte pass.
@(test)
ansi_render_sanitizes_each_byte_alone :: proc(t: ^testing.T) {
	for b in 0 ..< 256 {
		one := [1]u8{u8(b)}
		expected := string(one[:])
		if (b < 0x20 && b != '\t') || b >= 0x7F {
			expected = "?"
		}
		got := sanitized(string(one[:]))
		testing.expectf(t, got == expected, "the byte %x gives %q", b, got)
	}
}

// The C1 controls in UTF-8 (CSI 0xC2 0x9B, OSC 0xC2 0x9D, DCS 0xC2 0x90,
// U+0080 and U+009F), a raw 0x9B, a cut sequence, an overlong form, a
// surrogate and a byte past U+10FFFF each give one '?': a terminal that
// reads 8-bit controls never sees one. Valid characters pass whole.
@(test)
ansi_render_sanitizes_c1_controls_and_invalid_utf8 :: proc(t: ^testing.T) {
	refused := [?]string{"\xc2\x9b", "\xc2\x9d", "\xc2\x90", "\xc2\x80", "\xc2\x9f", "\x9b", "\xc3", "\xe2\x82", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xff"}
	for text in refused {
		got := sanitized(text)
		testing.expectf(t, strings.count(got, "?") >= 1 && !strings.contains_any(got, "\x1b\x9b\x9d\x90\xc2"), "%q gives %q", text, got)
		for b in transmute([]u8)got {
			testing.expectf(t, b == '?', "%q gives %q", text, got)
		}
	}
	testing.expect_value(t, sanitized("\xc2\x9b31m"), "?31m")
	testing.expect_value(t, sanitized("a\x1b[2Jb"), "a?[2Jb")
	testing.expect_value(t, sanitized("a\r\nb\x07\x08\t"), "a??b??\t")
	// Last: valid text passes whole, Latin-1 letters, box drawing, CJK and
	// a character of 4 bytes included.
	for text in ([?]string{"é", "€", "中", "┌─┐", "naïve café 中文 😀", " ", "ÿ"}) {
		testing.expect_value(t, sanitized(text), text)
	}
	buf: [1024]u8
	sink := sink_make(buf[:])
	emit_styled_text(&sink, transmute([]u8)string("é\xc2\x9b[2J"), {}, .Dark)
	out := string(sink_written(&sink))
	testing.expect(t, strings.has_suffix(out, "é?[2J"))
	testing.expect_value(t, strings.count(out, "\x1b"), 1)
}

// The characters of a popup row are counted as characters, not bytes: a
// row of 3-byte characters fills the box with whole characters.
@(test)
ansi_render_counts_characters_in_the_popup :: proc(t: ^testing.T) {
	buf: [64]u8
	sink := sink_make(buf[:])
	testing.expect_value(t, sink_sanitized_characters(&sink, transmute([]u8)string("中中中中"), 2), 2)
	testing.expect_value(t, string(sink_written(&sink)), "中中")
	sink = sink_make(buf[:])
	testing.expect_value(t, sink_sanitized_characters(&sink, transmute([]u8)string("abc"), 0), 0)
	testing.expect_value(t, sink.count, 0)
	testing.expect_value(t, sink_sanitized_characters(&sink, transmute([]u8)string("ab"), -5), 0)
}

// Each of the 8 tones gives its own 24-bit foreground, in each appearance;
// a tone byte that names no tone is Default; Reverse swaps the two colors;
// the flag Color takes the color of the style.
@(test)
ansi_render_gives_each_tone_its_color :: proc(t: ^testing.T) {
	for appearance in ([?]graphics.Appearance{.Dark, .Light}) {
		seen: map[graphics.Color]terminal_records.Tone
		defer delete(seen)
		for tone in terminal_records.Tone {
			foreground, background := style_colors({tone = u8(tone)}, appearance)
			if other, taken := seen[foreground]; taken {
				testing.expectf(t, false, "%v and %v share a color in %v", tone, other, appearance)
			}
			seen[foreground] = tone
			testing.expect_value(t, foreground, tone_color(tone, appearance))
			reversed_foreground, reversed_background := style_colors({tone = u8(tone), flags = {.Reverse}}, appearance)
			testing.expect(t, reversed_foreground == background && reversed_background == foreground)
		}
		testing.expect_value(t, len(seen), len(terminal_records.Tone))
		unknown, _ := style_colors({tone = u8(max(terminal_records.Tone)) + 1}, appearance)
		testing.expect_value(t, unknown, tone_color(.Default, appearance))
	}
	colored, _ := style_colors({flags = {.Color}, color = 0xFF12_3456}, .Dark)
	testing.expect_value(t, colored, graphics.Color(0x12_3456))
	buf: [128]u8
	sink := sink_make(buf[:])
	emit_sgr_rgb(&sink, 0x12_3456, 0xAB_CDEF)
	testing.expect_value(t, string(sink_written(&sink)), "\x1b[38;2;18;52;86;48;2;171;205;239m")
}

// A cursor past the edit line, the largest word and a word past the
// largest int, sits at the end of the line; NO_CURSOR places no cursor.
@(test)
ansi_render_cuts_the_cursor_to_the_edit_line :: proc(t: ^testing.T) {
	testing.expect_value(t, edit_column_of(0, 4), 1)
	testing.expect_value(t, edit_column_of(4, 4), 5)
	testing.expect_value(t, edit_column_of(5, 4), 5)
	testing.expect_value(t, edit_column_of(1 << 63, 4), 5)
	testing.expect_value(t, edit_column_of(max(u64) - 1, 4), 5)
	testing.expect_value(t, edit_column_of(3, -1), 1)
	buf: [512]u8
	sink := sink_make(buf[:])
	emit_edit_line(&sink, 3, transmute([]u8)string("ab\x1bc"), nil, terminal_records.NO_CURSOR, .Dark)
	out := string(sink_written(&sink))
	testing.expect(t, strings.has_suffix(out, "ab?c"))
	sink = sink_make(buf[:])
	emit_edit_line(&sink, 3, transmute([]u8)string("abcd"), nil, 1 << 63, .Dark)
	testing.expect(t, strings.has_suffix(string(sink_written(&sink)), "\x1b[3;5H"))
}

// The layout keeps the output in the rows above the edit line, and an
// output run goes back to the saved cursor of the output, saves it, and
// puts the cursor on the edit line.
@(test)
ansi_render_keeps_the_output_above_the_edit_line :: proc(t: ^testing.T) {
	buf: [512]u8
	sink := sink_make(buf[:])
	emit_layout(&sink, 24, .Dark)
	out := string(sink_written(&sink))
	testing.expect(t, strings.contains(out, "\x1b[2J"))
	testing.expect(t, strings.contains(out, "\x1b[1;23r"))
	testing.expect(t, strings.has_suffix(out, "\x1b[1;1H\x1b7"))
	sink = sink_make(buf[:])
	emit_layout(&sink, 1, .Dark)
	testing.expect(t, strings.contains(string(sink_written(&sink)), "\x1b[1;1r"))
	sink = sink_make(buf[:])
	emit_output_text(&sink, transmute([]u8)string("ok"), {flags = {.End_Line}}, 24, 7, .Dark)
	out = string(sink_written(&sink))
	testing.expect(t, strings.has_prefix(out, "\x1b8"))
	testing.expect(t, strings.has_suffix(out, "ok\x1b[K\r\n\x1b7\x1b[24;7H"))
}

// A list at the last row goes above the edit line, and its box never
// passes the columns of the screen. A screen narrower than the least box
// shows none. A row whose name length is negative, or past its text, or
// whose length is past its text, draws inside the box with no fault.
@(test)
ansi_render_completion_popup_stays_on_the_screen :: proc(t: ^testing.T) {
	testing.expect_value(t, popup_top_row(10, 2, 26), 11)
	testing.expect_value(t, popup_top_row(24, 2, 24), 20)
	testing.expect_value(t, popup_top_row(3, 8, 6), 1)
	list: terminal_records.List_Shown
	list.row_count = 3
	list.chosen = -1
	list.anchor = 1 << 30
	copy(list.rows[0].text[:], "first")
	list.rows[0].length = 5
	list.rows[0].name_length = -7
	copy(list.rows[1].text[:], "second")
	list.rows[1].length = 6
	list.rows[1].name_length = 1 << 40
	list.rows[2].length = 1 << 40
	list.rows[2].name_length = 3
	buf: [8192]u8
	for columns in ([?]int{0, 2, 3, 10, 30, 104}) {
		sink := sink_make(buf[:])
		emit_completion_popup(&sink, &list, 24, columns, 24, .Dark)
		out := string(sink_written(&sink))
		testing.expect(t, !sink.overflow)
		if columns < POPUP_LEAST_WIDTH {
			testing.expect_value(t, out, "")
			continue
		}
		testing.expect(t, strings.contains(out, "\x1b[19;"))
		testing.expect(t, !strings.contains(out, "\x1b[24;"))
		// The top border: at most the columns of the screen.
		top := strings.index(out, "┌")
		end := strings.index(out, "┐")
		testing.expect(t, top >= 0 && end > top)
		testing.expectf(t, strings.count(out[top:end], "─") + 2 <= columns, "the box has %d columns on a screen of %d", strings.count(out[top:end], "─") + 2, columns)
	}
}

// A list that does not fit the buffer marks the overflow and never writes
// past the buffer, for each size of the buffer up to the whole list.
@(test)
ansi_render_completion_popup_overflow_never_passes_the_buffer :: proc(t: ^testing.T) {
	list: terminal_records.List_Shown
	list.row_count = terminal_records.LIST_ROWS
	list.chosen = 2
	for &row in list.rows {
		for i in 0 ..< len(row.text) {
			row.text[i] = 'x'
		}
		row.length = len(row.text)
		row.name_length = 20
	}
	whole: [16384]u8
	sink := sink_make(whole[:])
	emit_completion_popup(&sink, &list, 2, 104, 32, .Dark)
	testing.expect(t, !sink.overflow)
	needed := sink.count
	for size in ([?]int{0, 1, 16, 255, needed / 2, needed - 1}) {
		buffer := make([]u8, size + 8)
		defer delete(buffer)
		for i in 0 ..< len(buffer) {
			buffer[i] = 0xAA
		}
		small := sink_make(buffer[:size])
		emit_completion_popup(&small, &list, 2, 104, 32, .Dark)
		testing.expectf(t, small.overflow, "a buffer of %d bytes of %d has no overflow", size, needed)
		testing.expect(t, small.count <= size)
		for b in buffer[size:] {
			testing.expect_value(t, b, u8(0xAA))
		}
	}
}
