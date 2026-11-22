// ANSI 24-bit TrueColor VT100 renderer for typed modus:terminal records
// (src/md/features/console_renderers.md, "Variant A: serial_terminal").
//
// Translates the typed terminal grid (Tone, Style, Flag, Lex Code_Runs,
// cursor, Status bar, Hint line, and interactive List_Keeping completion
// popup) directly into 24-bit TrueColor ANSI escape sequences over a
// caller-supplied byte buffer, with zero compositor, zero drawing module,
// and zero framebuffer.
package ansi_terminal

import "modus:contract/text_encoding"
import "modus:graphics"
import terminal_records "modus:terminal"

// Writer appends UTF-8 and ANSI bytes into a caller-supplied slice.
Byte_Sink :: struct {
	bytes:    []u8,
	count:    int,
	overflow: bool,
}

sink_make :: proc "contextless" (buffer: []u8) -> Byte_Sink {
	return {bytes = buffer}
}

sink_written :: proc "contextless" (sink: ^Byte_Sink) -> []u8 {
	return sink.bytes[:sink.count]
}

sink_byte :: proc "contextless" (sink: ^Byte_Sink, value: u8) {
	if sink.count >= len(sink.bytes) {
		sink.overflow = true
		return
	}
	sink.bytes[sink.count] = value
	sink.count += 1
}

sink_text :: proc "contextless" (sink: ^Byte_Sink, text: string) {
	if sink.count + len(text) > len(sink.bytes) {
		sink.overflow = true
		return
	}
	for index in 0 ..< len(text) {
		sink.bytes[sink.count + index] = text[index]
	}
	sink.count += len(text)
}

sink_unsigned :: proc "contextless" (sink: ^Byte_Sink, value: u64) {
	if value == 0 {
		sink_byte(sink, '0')
		return
	}
	digits: [20]u8
	count := 0
	n := value
	for n > 0 {
		digits[count] = u8('0' + n % 10)
		n /= 10
		count += 1
	}
	for index := count - 1; index >= 0; index -= 1 {
		sink_byte(sink, digits[index])
	}
}

// tone_color maps a terminal Tone to the active Modus appearance palette.
tone_color :: proc "contextless" (tone: terminal_records.Tone, appearance: graphics.Appearance) -> graphics.Color {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	switch tone {
	case .Default:
		return palette.text
	case .Dim:
		return palette.dim
	case .Strong:
		return palette.text_strong
	case .Good:
		return palette.process
	case .Warning:
		return palette.boot_program
	case .Bad:
		return palette.failed
	case .Accent:
		return palette.chosen
	case .Number:
		return palette.memory
	}
	return palette.text
}

// style_colors resolves foreground and background 24-bit RGB colors for a
// terminal Style in the chosen appearance.
style_colors :: proc "contextless" (style: terminal_records.Style, appearance: graphics.Appearance) -> (foreground, background: graphics.Color) {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	background = palette.background
	if .Color in style.flags {
		foreground = graphics.Color(style.color & 0x00FF_FFFF)
	} else if kind, kind_ok := terminal_records.code_kind_of(style.code); kind_ok && kind != .None {
		class := terminal_records.code_kind_classes[kind]
		foreground = class == .None ? palette.text : graphics.code_class_color(class, appearance)
	} else {
		tone, ok := terminal_records.tone_of_byte(style.tone)
		foreground = tone_color(ok ? tone : .Default, appearance)
	}
	if .Reverse in style.flags {
		foreground, background = background, foreground
	}
	return foreground, background
}

// emit_sgr_rgb emits 24-bit TrueColor foreground and background SGR codes.
emit_sgr_rgb :: proc "contextless" (sink: ^Byte_Sink, foreground, background: graphics.Color) {
	sink_text(sink, "\x1b[38;2;")
	sink_unsigned(sink, u64((foreground >> 16) & 0xFF))
	sink_byte(sink, ';')
	sink_unsigned(sink, u64((foreground >> 8) & 0xFF))
	sink_byte(sink, ';')
	sink_unsigned(sink, u64(foreground & 0xFF))
	sink_text(sink, ";48;2;")
	sink_unsigned(sink, u64((background >> 16) & 0xFF))
	sink_byte(sink, ';')
	sink_unsigned(sink, u64((background >> 8) & 0xFF))
	sink_byte(sink, ';')
	sink_unsigned(sink, u64(background & 0xFF))
	sink_byte(sink, 'm')
}

emit_reset :: proc "contextless" (sink: ^Byte_Sink) {
	sink_text(sink, "\x1b[0m")
}

emit_clear_screen :: proc "contextless" (sink: ^Byte_Sink, appearance: graphics.Appearance) {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	emit_sgr_rgb(sink, palette.text, palette.background)
	sink_text(sink, "\x1b[2J\x1b[H")
}

emit_cursor_move :: proc "contextless" (sink: ^Byte_Sink, row_1based, col_1based: int) {
	r := max(row_1based, 1)
	c := max(col_1based, 1)
	sink_text(sink, "\x1b[")
	sink_unsigned(sink, u64(r))
	sink_byte(sink, ';')
	sink_unsigned(sink, u64(c))
	sink_byte(sink, 'H')
}

// The mark that a renderer writes for a character of a process that would
// act on the terminal of the reader, and for an invalid UTF-8 sequence.
SANITIZED_MARK :: '?'

// sink_sanitized_characters appends the text of a process, at most
// character_limit characters, and gives the characters written. Each
// character is decoded as UTF-8 (text_encoding.character_decode): a valid
// character that is no control passes whole; Tab passes; each C0 control
// (ESC, CR, LF, BS, BEL...), Delete, each C1 control (U+0080 to U+009F: the
// CSI, OSC and DCS of 8 bits, as 0xC2 0x9B) and each invalid sequence (a raw
// byte 0x80 to 0xFF, a cut or overlong sequence, a surrogate) becomes one
// SANITIZED_MARK. The text of a process never acts on the terminal: only
// this renderer writes sequences.
sink_sanitized_characters :: proc "contextless" (sink: ^Byte_Sink, text: []u8, character_limit: int) -> (written: int) {
	place := 0
	for place < len(text) && written < character_limit {
		character, length, valid := text_encoding.character_decode(text, place)
		length = max(length, 1)
		switch {
		case text[place] == '\t':
			sink_byte(sink, '\t')
		case valid && text_encoding.character_in_text(character):
			sink_text(sink, string(text[place:][:length]))
		case:
			sink_byte(sink, SANITIZED_MARK)
		}
		place += length
		written += 1
	}
	return written
}

// sink_sanitized appends the whole text of a process through
// sink_sanitized_characters.
sink_sanitized :: proc "contextless" (sink: ^Byte_Sink, text: []u8) {
	_ = sink_sanitized_characters(sink, text, max(int))
}

// emit_styled_text emits a plain styled run. The text goes through
// sink_sanitized, so the output of a process can never inject an escape
// sequence or a control byte.
emit_styled_text :: proc "contextless" (sink: ^Byte_Sink, text: []u8, style: terminal_records.Style, appearance: graphics.Appearance) {
	fg, bg := style_colors(style, appearance)
	emit_sgr_rgb(sink, fg, bg)
	sink_sanitized(sink, text)
	if .End_Line in style.flags {
		sink_text(sink, "\x1b[K\r\n")
	}
}

// The layout of the screen of serial_terminal: the rows 1 to rows - 1 are
// the output, a scroll region that scrolls by itself at each new line; the
// last row is the edit line. The output keeps its own cursor, which DEC
// saves with ESC 7 and gives back with ESC 8, so the edit line and the
// completion list never move where the next output goes.

// emit_layout clears the screen, sets the scroll region of the output, and
// saves the cursor of the output at its first row. rows below 2 give one
// row of output.
emit_layout :: proc "contextless" (sink: ^Byte_Sink, rows: int, appearance: graphics.Appearance) {
	emit_clear_screen(sink, appearance)
	sink_text(sink, "\x1b[1;")
	sink_unsigned(sink, u64(max(rows - 1, 1)))
	sink_byte(sink, 'r')
	emit_cursor_move(sink, 1, 1)
	sink_text(sink, "\x1b7")
}

// emit_output_text writes a run of output at the cursor of the output,
// saves that cursor again, then puts the cursor back on the edit line at
// edit_column: the reader types there.
emit_output_text :: proc "contextless" (sink: ^Byte_Sink, text: []u8, style: terminal_records.Style, edit_row_1based, edit_column_1based: int, appearance: graphics.Appearance) {
	sink_text(sink, "\x1b8")
	emit_styled_text(sink, text, style, appearance)
	sink_text(sink, "\x1b7")
	emit_cursor_move(sink, edit_row_1based, edit_column_1based)
}

// emit_edit_line renders the active console edit line with Lex syntax
// highlighting (Code_Runs) and places the terminal cursor at cursor_byte.
emit_edit_line :: proc "contextless" (
	sink: ^Byte_Sink,
	row_1based: int,
	text: []u8,
	runs: ^terminal_records.Code_Runs,
	cursor_byte: u64,
	appearance: graphics.Appearance,
) {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	emit_cursor_move(sink, row_1based, 1)
	emit_sgr_rgb(sink, palette.text, palette.background)
	sink_text(sink, "\x1b[K")
	pos := 0
	if runs != nil && runs.count > 0 {
		for index in 0 ..< min(runs.count, terminal_records.CODE_RUN_LIMIT) {
			run := runs.runs[index]
			start := int(run.start)
			end := min(start + int(run.length), len(text))
			if start > pos && start <= len(text) {
				emit_sgr_rgb(sink, palette.text, palette.background)
				sink_sanitized(sink, text[pos:start])
				pos = start
			}
			if start >= pos && end > start {
				kind, ok := terminal_records.code_kind_of(run.kind)
				color := palette.text
				if ok && kind != .None {
					class := terminal_records.code_kind_classes[kind]
					if class != .None {
						color = graphics.code_class_color(class, appearance)
					}
				}
				emit_sgr_rgb(sink, color, palette.background)
				sink_sanitized(sink, text[start:end])
				pos = end
			}
		}
	}
	if pos < len(text) {
		emit_sgr_rgb(sink, palette.text, palette.background)
		sink_sanitized(sink, text[pos:])
	}
	if cursor_byte != terminal_records.NO_CURSOR {
		// The cut is in u64: a word past the largest int never wraps to a
		// column before the line.
		emit_cursor_move(sink, row_1based, edit_column_of(cursor_byte, len(text)))
	}
}

// edit_column_of gives the column, from 1, of the cursor of an edit line of
// length bytes: a cursor past the text is at its end.
edit_column_of :: proc "contextless" (cursor_byte: u64, length: int) -> int {
	return int(min(cursor_byte, u64(max(length, 0)))) + 1
}

// popup_top_row gives the row, from 1, of the top border of a completion
// list of row_count rows at the edit line anchor_row: under it when the
// list fits there, else above it. A screen too small for the list above
// gives row 1.
popup_top_row :: proc "contextless" (anchor_row_1based, row_count, rows: int) -> int {
	height := row_count + 2
	if anchor_row_1based + height <= rows {
		return anchor_row_1based + 1
	}
	return max(anchor_row_1based - height, 1)
}

// The least width of the box of a completion list: the two borders and
// one character.
POPUP_LEAST_WIDTH :: 3

// emit_completion_popup renders the floating completion popup box (List_Shown)
// at the edit line anchor_row, under it when it fits and above it if not
// (popup_top_row), using Unicode box-drawing borders, highlighted selected
// row, and dim descriptions. The box never passes the columns of the
// screen; a screen narrower than POPUP_LEAST_WIDTH shows no box. Passing
// row_count == 0 clears the rows that the largest list takes, on the same
// side. A row whose name length is out of its text is drawn with the name
// cut to the text.
emit_completion_popup :: proc "contextless" (
	sink: ^Byte_Sink,
	list: ^terminal_records.List_Shown,
	anchor_row_1based: int,
	columns: int,
	screen_rows: int,
	appearance: graphics.Appearance,
) {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	if list == nil || list.row_count <= 0 {
		emit_sgr_rgb(sink, palette.text, palette.background)
		top := popup_top_row(anchor_row_1based, terminal_records.LIST_ROWS, screen_rows)
		for offset in 0 ..< terminal_records.LIST_ROWS + 2 {
			row := top + offset
			if row != anchor_row_1based && row >= 1 && row <= max(screen_rows, 1) {
				emit_cursor_move(sink, row, 1)
				sink_text(sink, "\x1b[2K")
			}
		}
		return
	}
	if columns < POPUP_LEAST_WIDTH {
		return
	}
	rows := min(list.row_count, terminal_records.LIST_ROWS)
	box_col := clamp(list.anchor + 1, 1, max(columns - 24, 1))
	box_width := min(clamp(columns - box_col + 1, 20, 56), columns - box_col + 1)
	inner := box_width - 2
	top := popup_top_row(anchor_row_1based, rows, screen_rows)

	// Top border.
	emit_cursor_move(sink, top, box_col)
	emit_sgr_rgb(sink, palette.edge, palette.card_top)
	sink_text(sink, "┌")
	for _ in 0 ..< inner {
		sink_text(sink, "─")
	}
	sink_text(sink, "┐")

	// Candidate rows.
	for row_index in 0 ..< rows {
		row := &list.rows[row_index]
		selected := row_index == list.chosen
		row_bg := selected ? palette.chosen : palette.card_bottom
		name_fg := selected ? graphics.COLOR_WHITE : palette.text_strong
		desc_fg := selected ? graphics.COLOR_WHITE : palette.dim

		emit_cursor_move(sink, top + 1 + row_index, box_col)
		emit_sgr_rgb(sink, palette.edge, palette.card_bottom)
		sink_text(sink, "│")
		emit_sgr_rgb(sink, name_fg, row_bg)
		sink_byte(sink, ' ')
		written := 1
		length := clamp(row.length, 0, len(row.text))
		name_len := clamp(row.name_length, 0, length)
		written += sink_sanitized_characters(sink, row.text[:name_len], inner - written)
		if length > name_len && written + 2 < inner {
			sink_text(sink, "  ")
			written += 2
			emit_sgr_rgb(sink, desc_fg, row_bg)
			written += sink_sanitized_characters(sink, row.text[name_len:length], inner - written)
		}
		for written < inner {
			sink_byte(sink, ' ')
			written += 1
		}
		emit_sgr_rgb(sink, palette.edge, palette.card_bottom)
		sink_text(sink, "│")
	}

	// Bottom border.
	emit_cursor_move(sink, top + 1 + rows, box_col)
	emit_sgr_rgb(sink, palette.edge, palette.card_bottom)
	sink_text(sink, "└")
	for _ in 0 ..< inner {
		sink_text(sink, "─")
	}
	sink_text(sink, "┘")
	emit_reset(sink)
}
