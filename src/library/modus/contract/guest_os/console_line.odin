package guest_os

// The console line: the bytes that a Linux guest writes on its serial port,
// turned into lines of text for a terminal of the system
// (src/md/features/linux_shell.md, "The console line").
//
// The terminal of the system draws records, not escape sequences, so the
// line keeps the text that the guest writes now and a cursor, and reads the
// few sequences of the line editing of a shell: erase to the end of the line,
// and move the cursor. Each other sequence is read whole and does nothing.
// The bytes of the guest are hostile: the line and the number of a sequence
// each have a bound, and a byte of 128 or more
// becomes '?', so no byte of the guest makes a sequence of UTF-8 that a
// reader of the line decodes.

// The bytes of one line, at most: matches the widest terminal grid so a
// wide window never wraps early.
CONSOLE_LINE_BYTES :: 192
// The number of a sequence, at most: a larger number counts as this one.
CONSOLE_SEQUENCE_NUMBER_MOST :: CONSOLE_LINE_BYTES

CONSOLE_TAB_STOP :: 8

// Where the line is in the reading of a sequence.
Console_Escape :: enum u8 {
	None     = 0, // Text.
	Escape   = 1, // After ESC.
	Sequence = 2, // After ESC [: the number, then the final byte.
}

Console_Line :: struct {
	text:            [CONSOLE_LINE_BYTES]u8,
	length:          int, // The bytes of text.
	cursor:          int, // The place of the next byte, from 0 to length.
	columns:         int, // Active line wrap width (1 ..= CONSOLE_LINE_BYTES); 0 means CONSOLE_LINE_BYTES.
	escape:          Console_Escape,
	number:          int, // The number of the sequence that is read, at most CONSOLE_SEQUENCE_NUMBER_MOST.
}

// What one byte did to the line.
Console_Change :: enum u8 {
	None    = 0, // Nothing that a reader sees.
	Changed = 1, // The text or the cursor changed.
	Ended   = 2, // The line ended: console_line_text gives it, and console_line_next starts the next one.
}

// console_line_text gives the text of the line, and its cursor.
console_line_text :: proc "contextless" (line: ^Console_Line) -> (text: []u8, cursor: int) {
	return line.text[:line.length], line.cursor
}

// console_line_limit gives the active wrap width of line in bytes.
console_line_limit :: proc "contextless" (line: ^Console_Line) -> int {
	if line.columns > 0 && line.columns <= CONSOLE_LINE_BYTES {
		return line.columns
	}
	return CONSOLE_LINE_BYTES
}

// console_line_set_columns updates the active wrap width of line to match a
// resized terminal window. Refuses columns outside 1 ..= CONSOLE_LINE_BYTES.
console_line_set_columns :: proc "contextless" (line: ^Console_Line, columns: int) -> bool {
	if line == nil || columns < 1 || columns > CONSOLE_LINE_BYTES {
		return false
	}
	line.columns = columns
	return true
}

// console_line_next starts a new line after an end.
console_line_next :: proc "contextless" (line: ^Console_Line) {
	line.length = 0
	line.cursor = 0
}

// console_line_put reads one byte of the guest.
console_line_put :: proc "contextless" (line: ^Console_Line, value: u8) -> Console_Change {
	ESCAPE :: u8(0x1B)
	switch line.escape {
	case .Escape:
		line.escape = .None
		if value == '[' {
			line.escape = .Sequence
			line.number = 0
		}
		return .None
	case .Sequence:
		return console_sequence_put(line, value)
	case .None:
	}
	switch value {
	case '\n':
		return .Ended
	case '\r':
		line.cursor = 0
		return .Changed
	case '\b':
		line.cursor = max(line.cursor - 1, 0)
		return .Changed
	case '\t':
		next := (line.cursor / CONSOLE_TAB_STOP + 1) * CONSOLE_TAB_STOP
		for line.cursor < next {
			if console_line_write(line, ' ') == .Ended {
				return .Ended
			}
		}
		return .Changed
	case ESCAPE:
		line.escape = .Escape
		return .None
	}
	if value < 0x20 || value == 0x7F {
		return .None
	}
	return console_line_write(line, value < 0x80 ? value : '?')
}

// console_line_write writes one printable byte at the cursor. A line that
// is full ends: the byte waits for the next line.
@(private = "file")
console_line_write :: proc "contextless" (line: ^Console_Line, value: u8) -> Console_Change {
	limit := console_line_limit(line)
	if line.cursor >= limit {
		// The caller takes the full line and starts the next one; the byte
		// goes at its start.
		return .Ended
	}
	line.text[line.cursor] = value
	line.cursor += 1
	line.length = max(line.length, line.cursor)
	return line.cursor >= limit ? .Ended : .Changed
}

// console_sequence_put reads one byte of a sequence ESC [ <number> <final>.
@(private = "file")
console_sequence_put :: proc "contextless" (line: ^Console_Line, value: u8) -> Console_Change {
	// The number keeps its bound: a sequence of any length costs no memory,
	// and its bytes write nothing until its final byte.
	if value >= '0' && value <= '9' {
		line.number = min(line.number * 10 + int(value - '0'), CONSOLE_SEQUENCE_NUMBER_MOST)
		return .None
	}
	// A parameter byte or an intermediate byte: the sequence goes on.
	if value >= 0x20 && value <= 0x3F {
		return .None
	}
	line.escape = .None
	count := max(line.number, 1)
	switch value {
	case 'K':
		// 0 (or no number): erase from the cursor to the end of the line.
		// Another number erases what is before the cursor too: the line
		// keeps its length in spaces, as a screen does.
		if line.number == 0 {
			line.length = line.cursor
		} else {
			for place in 0 ..< line.cursor {
				line.text[place] = ' '
			}
			if line.number == 2 {
				line.length = line.cursor
			}
		}
		return .Changed
	case 'C':
		line.cursor = min(line.cursor + count, line.length)
		return .Changed
	case 'D':
		line.cursor = max(line.cursor - count, 0)
		return .Changed
	}
	return .None
}
