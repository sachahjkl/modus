// ANSI 24-bit TrueColor VT100 renderer for typed modus:terminal records
// (src/md/features/console_renderers.md, "Variant A: serial_terminal").
//
// Translates the typed terminal grid (Tone, Style, Flag, Lex Code_Runs,
// cursor, Status bar, Hint line, and interactive List_Keeping completion
// popup) directly into 24-bit TrueColor ANSI escape sequences over a
// caller-supplied byte buffer, with zero compositor, zero drawing module,
// and zero framebuffer.
package ansi_terminal

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

// emit_styled_text emits a plain styled run, sanitizing any raw ESC byte so
// untrusted process output can never inject escape sequences.
emit_styled_text :: proc "contextless" (sink: ^Byte_Sink, text: []u8, style: terminal_records.Style, appearance: graphics.Appearance) {
	fg, bg := style_colors(style, appearance)
	emit_sgr_rgb(sink, fg, bg)
	for b in text {
		if b == 0x1B {
			sink_byte(sink, '?')
		} else {
			sink_byte(sink, b)
		}
	}
	if .End_Line in style.flags {
		sink_text(sink, "\x1b[K\r\n")
	}
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
				for b in text[pos:start] {
					sink_byte(sink, b == 0x1B ? '?' : b)
				}
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
				for b in text[start:end] {
					sink_byte(sink, b == 0x1B ? '?' : b)
				}
				pos = end
			}
		}
	}
	if pos < len(text) {
		emit_sgr_rgb(sink, palette.text, palette.background)
		for b in text[pos:] {
			sink_byte(sink, b == 0x1B ? '?' : b)
		}
	}
	if cursor_byte != terminal_records.NO_CURSOR {
		col := min(int(cursor_byte), len(text)) + 1
		emit_cursor_move(sink, row_1based, col)
	}
}

// emit_completion_popup renders the floating completion popup box (List_Shown)
// below anchor_row using Unicode box-drawing borders, highlighted selected row,
// and dim descriptions. Passing row_count == 0 clears the popup rows cleanly.
emit_completion_popup :: proc "contextless" (
	sink: ^Byte_Sink,
	list: ^terminal_records.List_Shown,
	anchor_row_1based: int,
	columns: int,
	appearance: graphics.Appearance,
) {
	palette := graphics.colors_for_contrast_mode(.Standard, appearance == .Dark)
	if list == nil || list.row_count <= 0 {
		emit_sgr_rgb(sink, palette.text, palette.background)
		for offset in 0 ..< terminal_records.LIST_ROWS + 2 {
			emit_cursor_move(sink, anchor_row_1based + 1 + offset, 1)
			sink_text(sink, "\x1b[K")
		}
		return
	}
	rows := min(list.row_count, terminal_records.LIST_ROWS)
	box_col := clamp(list.anchor + 1, 1, max(columns - 24, 1))
	box_width := clamp(columns - box_col + 1, 20, 56)
	inner := box_width - 2

	// Top border.
	emit_cursor_move(sink, anchor_row_1based + 1, box_col)
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

		emit_cursor_move(sink, anchor_row_1based + 2 + row_index, box_col)
		emit_sgr_rgb(sink, palette.edge, palette.card_bottom)
		sink_text(sink, "│")
		emit_sgr_rgb(sink, name_fg, row_bg)
		sink_byte(sink, ' ')
		written := 1
		name_len := min(row.name_length, row.length)
		for i in 0 ..< name_len {
			if written >= inner {
				break
			}
			b := row.text[i]
			sink_byte(sink, b == 0x1B ? '?' : b)
			written += 1
		}
		if row.length > name_len && written + 2 < inner {
			sink_text(sink, "  ")
			written += 2
			emit_sgr_rgb(sink, desc_fg, row_bg)
			for i in name_len ..< row.length {
				if written >= inner {
					break
				}
				b := row.text[i]
				sink_byte(sink, b == 0x1B ? '?' : b)
				written += 1
			}
		}
		for written < inner {
			sink_byte(sink, ' ')
			written += 1
		}
		emit_sgr_rgb(sink, palette.edge, palette.card_bottom)
		sink_text(sink, "│")
	}

	// Bottom border.
	emit_cursor_move(sink, anchor_row_1based + 2 + rows, box_col)
	emit_sgr_rgb(sink, palette.edge, palette.card_bottom)
	sink_text(sink, "└")
	for _ in 0 ..< inner {
		sink_text(sink, "─")
	}
	sink_text(sink, "┘")
	emit_reset(sink)
}
