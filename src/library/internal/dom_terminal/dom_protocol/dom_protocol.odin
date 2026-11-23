package dom_protocol

// The lines that dom_terminal writes on the second serial port for a page
// that draws the terminal with the document of a browser
// (src/md/features/console_renderers.md, "Variant C: dom_terminal"). Each
// step of the renderer intake becomes one JSON object on one line, ended
// by '\n'. Each place in a text (a cursor, a run, a mark, a match) counts
// characters, not bytes, as the characters of a JavaScript string that
// Array.from gives: the page never decodes UTF-8 offsets.
//
// The text of a process never reaches the page raw: each character is
// decoded as UTF-8 (text_encoding.character_decode); a valid character
// that is no control passes whole, Tab becomes \t, '"' and '\' are
// escaped, and each C0 control, Delete, each C1 control and each invalid
// sequence becomes one '?'. A line that does not fit its buffer is not
// written at all, so the page never reads half an object.

import "modus:contract/text_encoding"
import terminal_records "modus:terminal"

// The bytes of the longest line: an edit line of EDIT_TEXT_LIMIT bytes,
// escaped to at most two bytes for each byte, with EDIT_CODE_RUN_LIMIT
// runs; a completion list of LIST_ROWS rows of RUN_LIMIT bytes is less.
LINE_LIMIT :: 65536

// The longest edit line: its frame and cursor in 64 bytes, its text, and
// each run as [start,end,"kind"], with two numbers of at most 5 digits and
// the longest name of a kind.
EDIT_LINE_BYTES_MOST :: 64 + 2 * terminal_records.EDIT_TEXT_LIMIT + terminal_records.EDIT_CODE_RUN_LIMIT * (2 * 5 + len("[,,\"\"],") + len("Text_Unfinished"))
#assert(EDIT_LINE_BYTES_MOST <= LINE_LIMIT)

// The mark of a character that the page must not receive.
SANITIZED_MARK :: '?'

// The bytes of a name of a list row whose match the List_Row record holds:
// two words of 64 bits.
MATCHED_BYTES_LIMIT :: 128

// One line that is written into a buffer of the caller.
Line :: struct {
	bytes:    []u8,
	length:   int,
	overflow: bool, // A byte did not fit: the line is not written.
}

line_make :: proc "contextless" (bytes: []u8) -> Line {
	return {bytes = bytes}
}

// line_written gives the bytes of a whole line, or nil when it overflowed.
line_written :: proc "contextless" (line: ^Line) -> []u8 {
	if line.overflow {
		return nil
	}
	return line.bytes[:line.length]
}

@(private = "file")
put_byte :: proc "contextless" (line: ^Line, value: u8) {
	if line.length >= len(line.bytes) {
		line.overflow = true
		return
	}
	line.bytes[line.length] = value
	line.length += 1
}

@(private = "file")
put_raw :: proc "contextless" (line: ^Line, text: string) {
	for index in 0 ..< len(text) {
		put_byte(line, text[index])
	}
}

@(private = "file")
put_unsigned :: proc "contextless" (line: ^Line, value: u64) {
	digits: [20]u8
	count := 0
	rest := value
	for {
		digits[count] = u8('0' + rest % 10)
		count += 1
		rest /= 10
		if rest == 0 {
			break
		}
	}
	for count > 0 {
		count -= 1
		put_byte(line, digits[count])
	}
}

// put_count writes a count that is never negative: a place or a size.
@(private = "file")
put_count :: proc "contextless" (line: ^Line, value: int) {
	put_unsigned(line, u64(max(value, 0)))
}

// put_key writes ',"<name>":', or '"<name>":' for the first key.
@(private = "file")
put_key :: proc "contextless" (line: ^Line, name: string, first := false) {
	if !first {
		put_byte(line, ',')
	}
	put_byte(line, '"')
	put_raw(line, name)
	put_raw(line, "\":")
}

// put_name writes a name of the protocol as a JSON string.
@(private = "file")
put_name :: proc "contextless" (line: ^Line, name: string) {
	put_byte(line, '"')
	put_raw(line, name)
	put_byte(line, '"')
}

// put_string writes a text of a process as a JSON string.
put_string :: proc "contextless" (line: ^Line, text: []u8) {
	put_byte(line, '"')
	place := 0
	for place < len(text) {
		character, length, valid := text_encoding.character_decode(text, place)
		length = max(length, 1)
		switch {
		case text[place] == '\t':
			put_raw(line, "\\t")
		case valid && character == '"':
			put_raw(line, "\\\"")
		case valid && character == '\\':
			put_raw(line, "\\\\")
		case valid:
			for index in 0 ..< length {
				put_byte(line, text[place + index])
			}
		case:
			put_byte(line, SANITIZED_MARK)
		}
		place += length
	}
	put_byte(line, '"')
}

// characters_before gives the characters of text that start before the
// byte place: the place in the string of the page of that byte. A place
// inside a character counts that character. put_string writes one
// character for each one that this counts.
characters_before :: proc "contextless" (text: []u8, place: int) -> int {
	count := 0
	at := 0
	for at < len(text) && at < place {
		_, length, _ := text_encoding.character_decode(text, at)
		at += max(length, 1)
		count += 1
	}
	return count
}

tone_name :: proc "contextless" (tone: terminal_records.Tone) -> string {
	switch tone {
	case .Default:
		return "default"
	case .Dim:
		return "dim"
	case .Strong:
		return "strong"
	case .Good:
		return "good"
	case .Warning:
		return "warning"
	case .Bad:
		return "bad"
	case .Accent:
		return "accent"
	case .Number:
		return "number"
	}
	return "default"
}

code_kind_name :: proc "contextless" (kind: terminal_records.Code_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Function:
		return "function"
	case .Module:
		return "module"
	case .Type:
		return "type"
	case .Parameter:
		return "parameter"
	case .Variable:
		return "variable"
	case .Number:
		return "number"
	case .Text:
		return "text"
	case .Text_Unfinished:
		return "text_unfinished"
	case .Operator:
		return "operator"
	case .Arrow:
		return "arrow"
	case .Words:
		return "words"
	case .Unknown:
		return "unknown"
	}
	return "none"
}

list_icon_name :: proc "contextless" (icon: terminal_records.List_Icon) -> string {
	switch icon {
	case .None:
		return "none"
	case .Command:
		return "command"
	case .Export:
		return "export"
	case .Record:
		return "record"
	case .Service:
		return "service"
	case .Module:
		return "module"
	case .Process:
		return "process"
	case .Variable:
		return "variable"
	case .History_Line:
		return "history_line"
	}
	return "none"
}

// put_runs writes '[[start,end,"kind"],...]' in characters of text. The
// intake checked the runs against the text; a byte that names no kind is
// left out, as each border reads it again.
@(private = "file")
put_runs :: proc "contextless" (line: ^Line, runs: []terminal_records.Code_Run, text: []u8) {
	put_byte(line, '[')
	written := 0
	for run in runs {
		kind, kind_ok := terminal_records.code_kind_of(run.kind)
		if !kind_ok || kind == .None {
			continue
		}
		if written > 0 {
			put_byte(line, ',')
		}
		put_byte(line, '[')
		put_count(line, characters_before(text, int(run.start)))
		put_byte(line, ',')
		put_count(line, characters_before(text, int(run.start) + int(run.length)))
		put_byte(line, ',')
		put_name(line, code_kind_name(kind))
		put_byte(line, ']')
		written += 1
	}
	put_byte(line, ']')
}

@(private = "file")
put_hex_color :: proc "contextless" (line: ^Line, color: u32) {
	put_raw(line, "\"#")
	for shift := 20; shift >= 0; shift -= 4 {
		digit := u8((color >> uint(shift)) & 0xF)
		put_byte(line, digit < 10 ? '0' + digit : 'a' + digit - 10)
	}
	put_byte(line, '"')
}

// write_output writes a run of text: '{"t":"out","s":"..."}' with the keys
// tone, code, fg, rev and nl only when they say more than plain text. The
// page colors tone and code by classes, so a change of its theme colors
// each line again with no new line.
write_output :: proc "contextless" (line: ^Line, text: []u8, style: terminal_records.Style) {
	put_raw(line, "{\"t\":\"out\",\"s\":")
	put_string(line, text)
	if tone, ok := terminal_records.tone_of_byte(style.tone); ok && tone != .Default {
		put_key(line, "tone")
		put_name(line, tone_name(tone))
	}
	if kind, ok := terminal_records.code_kind_of(style.code); ok && kind != .None {
		put_key(line, "code")
		put_name(line, code_kind_name(kind))
	}
	if .Color in style.flags {
		put_key(line, "fg")
		put_hex_color(line, style.color & 0x00FF_FFFF)
	}
	if .Reverse in style.flags {
		put_raw(line, ",\"rev\":true")
	}
	if .End_Line in style.flags {
		put_raw(line, ",\"nl\":true")
	}
	put_raw(line, "}\n")
}

write_clear :: proc "contextless" (line: ^Line) {
	put_raw(line, "{\"t\":\"clr\"}\n")
}

// write_edit writes the edit line: its text, its cursor in characters when
// it has one, and its runs of code when it has some.
write_edit :: proc "contextless" (line: ^Line, edit: ^terminal_records.Renderer_Edit) {
	text := edit.text[:clamp(edit.length, 0, terminal_records.EDIT_TEXT_LIMIT)]
	put_raw(line, "{\"t\":\"edit\",\"text\":")
	put_string(line, text)
	if edit.has_cursor {
		put_key(line, "cur")
		put_count(line, characters_before(text, edit.cursor))
	}
	if edit.code.count > 0 {
		put_key(line, "runs")
		put_runs(line, edit.code.runs[:clamp(edit.code.count, 0, terminal_records.EDIT_CODE_RUN_LIMIT)], text)
	}
	put_raw(line, "}\n")
}

// write_hint writes the long form of the hint and its marked part, in
// characters. An empty text hides the hint. The page wraps a long form, so
// the short form is not sent.
write_hint :: proc "contextless" (line: ^Line, hint: ^terminal_records.Renderer_Hint) {
	text := hint.text[:clamp(hint.long_bytes, 0, terminal_records.RUN_LIMIT)]
	put_raw(line, "{\"t\":\"hint\",\"text\":")
	put_string(line, text)
	if hint.mark_length > 0 {
		start := characters_before(text, hint.mark_start)
		put_key(line, "ms")
		put_count(line, start)
		put_key(line, "ml")
		put_count(line, characters_before(text, hint.mark_start + hint.mark_length) - start)
	}
	put_raw(line, "}\n")
}

// write_status writes the status line. A total of 0 hides it.
write_status :: proc "contextless" (line: ^Line, status: ^terminal_records.Renderer_Status) {
	put_raw(line, "{\"t\":\"status\",\"text\":")
	put_string(line, status.text[:clamp(status.length, 0, terminal_records.RUN_LIMIT)])
	put_key(line, "v")
	put_unsigned(line, status.value)
	put_key(line, "tot")
	put_unsigned(line, status.total)
	put_raw(line, "}\n")
}

// write_list writes the completion list. chosen is -1 for no row. start
// is the character of the edit line where the name starts. Each item has
// its name, the text after the name (detail), its icon, the characters of
// the name that matched, and its runs in characters of the name and the
// detail together. No items hides the list.
write_list :: proc "contextless" (line: ^Line, shown: ^terminal_records.List_Shown, edit: ^terminal_records.Renderer_Edit) {
	row_count := clamp(shown.row_count, 0, terminal_records.LIST_ROWS)
	put_raw(line, "{\"t\":\"list\",\"chosen\":")
	if shown.chosen >= 0 && shown.chosen < row_count {
		put_count(line, shown.chosen)
	} else {
		put_raw(line, "-1")
	}
	put_key(line, "first")
	put_count(line, shown.first)
	put_key(line, "total")
	put_count(line, shown.total)
	put_key(line, "start")
	put_count(line, characters_before(edit.text[:clamp(edit.length, 0, terminal_records.RUN_LIMIT)], shown.anchor))
	put_key(line, "items")
	put_byte(line, '[')
	for index in 0 ..< row_count {
		if index > 0 {
			put_byte(line, ',')
		}
		put_list_item(line, &shown.rows[index])
	}
	put_raw(line, "]}\n")
}

@(private = "file")
put_list_item :: proc "contextless" (line: ^Line, row: ^terminal_records.List_Row) {
	text := row.text[:clamp(row.length, 0, terminal_records.RUN_LIMIT)]
	name_length := clamp(row.name_length, 0, len(text))
	put_byte(line, '{')
	put_key(line, "name", true)
	put_string(line, text[:name_length])
	put_key(line, "detail")
	put_string(line, text[name_length:])
	if row.icon != .None {
		put_key(line, "icon")
		put_name(line, list_icon_name(row.icon))
	}
	// A match is a bit for each byte of the name; the page marks the
	// character that starts at a marked byte.
	written := 0
	place := 0
	character_index := 0
	for place < name_length {
		_, length, _ := text_encoding.character_decode(text[:name_length], place)
		if place < MATCHED_BYTES_LIMIT && (row.matched[place / 64] >> uint(place % 64)) & 1 != 0 {
			put_raw(line, written == 0 ? ",\"match\":[" : ",")
			put_count(line, character_index)
			written += 1
		}
		place += max(length, 1)
		character_index += 1
	}
	if written > 0 {
		put_byte(line, ']')
	}
	if row.code.count > 0 {
		put_key(line, "runs")
		put_runs(line, row.code.runs[:clamp(row.code.count, 0, terminal_records.CODE_RUN_LIMIT)], text)
	}
	put_byte(line, '}')
}

// write_step writes the line of one step of the intake into line, and
// gives its bytes: nil for a step that the page does not see, and for a
// line that did not fit.
write_step :: proc "contextless" (line: ^Line, step: terminal_records.Renderer_Step, intake: ^terminal_records.Renderer_Intake, style: terminal_records.Style) -> []u8 {
	switch step {
	case .None:
		return nil
	case .Text:
		write_output(line, intake.text[:clamp(intake.text_length, 0, terminal_records.RUN_LIMIT)], style)
	case .Clear:
		write_clear(line)
	case .Edit:
		write_edit(line, &intake.edit)
	case .List:
		write_list(line, &intake.list.shown, &intake.edit)
	case .Status:
		write_status(line, &intake.status)
	case .Hint:
		write_hint(line, &intake.hint)
	}
	return line_written(line)
}
