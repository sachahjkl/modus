#+build !freestanding
package dom_protocol

import "core:encoding/json"
import "core:strings"
import "core:testing"
import terminal_records "modus:terminal"

// written gives the line of one write, checks that it is one JSON object
// that ends with one '\n', and gives it without the '\n'.
@(private = "file")
checked :: proc(t: ^testing.T, line: ^Line) -> string {
	bytes := line_written(line)
	testing.expect(t, !line.overflow)
	text := string(bytes)
	if !testing.expectf(t, strings.has_suffix(text, "\n"), "%q has no end of line", text) {
		return text
	}
	body := text[:len(text) - 1]
	testing.expectf(t, !strings.contains(body, "\n"), "%q holds a second line", text)
	value, error := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	testing.expectf(t, error == .None, "%q is no JSON: %v", body, error)
	_, is_object := value.(json.Object)
	testing.expectf(t, is_object, "%q is no object", body)
	return body
}

@(private = "file")
output_of :: proc(t: ^testing.T, text: string, style: terminal_records.Style = {}) -> string {
	buffer := make([]u8, LINE_LIMIT, context.temp_allocator)
	line := line_make(buffer)
	write_output(&line, transmute([]u8)text, style)
	return checked(t, &line)
}

// Each byte that could act on the page or break the line becomes '?' or
// its escape: a quote, a backslash, Tab, each C0 control (NUL, ESC, CR, LF,
// BEL), Delete, a C1 control (the CSI of 8 bits 0xC2 0x9B, and U+0085), a
// raw byte 0x80 to 0xFF, an overlong form, a surrogate, a code point past
// U+10FFFF and a sequence cut at the end. Each valid character passes
// whole, and the page reads one character for each character of the text.
@(test)
put_string_escapes_and_replaces_each_byte_that_could_act :: proc(t: ^testing.T) {
	Case :: struct {
		text:     string,
		expected: string,
	}
	cases := [?]Case {
		{"", "\"\""},
		{"a\"b", "\"a\\\"b\""},
		{"a\\b", "\"a\\\\b\""},
		{"a\tb", "\"a\\tb\""},
		{"\x00\x01\x1b[31m\r\n\x07", "\"???[31m???\""},
		{"\x7f", "\"?\""},
		{"\xc2\x9b2J", "\"?2J\""},
		{"\xc2\x85", "\"?\""},
		{"\x80\xbf\xff\xfe", "\"????\""},
		{"\xc0\xaf", "\"??\""},
		{"\xed\xa0\x80", "\"???\""},
		{"\xf4\x90\x80\x80", "\"????\""},
		{"ok\xe2\x82", "\"ok??\""},
		{"é€😀", "\"é€😀\""},
		{" ", "\" \""},
	}
	for item in cases {
		buffer: [64]u8
		line := line_make(buffer[:])
		put_string(&line, transmute([]u8)item.text)
		testing.expectf(t, string(line_written(&line)) == item.expected, "%q gives %q, not %q", item.text, string(line_written(&line)), item.expected)
		value, error := json.parse(line_written(&line), allocator = context.temp_allocator)
		testing.expectf(t, error == .None, "%q gives no JSON", item.text)
		if text, ok := value.(json.String); ok {
			testing.expectf(t, strings.rune_count(text) == characters_before(transmute([]u8)item.text, len(item.text)), "%q: the page reads %d characters", item.text, strings.rune_count(text))
		}
	}
}

// A plain run is the smallest line; each key comes only when it says more.
// A tone byte and a code byte that name no member are left out, never read
// as another member.
@(test)
write_output_writes_only_the_keys_that_say_more :: proc(t: ^testing.T) {
	testing.expect_value(t, output_of(t, "x"), "{\"t\":\"out\",\"s\":\"x\"}")
	style := terminal_records.Style {
		tone  = u8(terminal_records.Tone.Good),
		code  = u8(terminal_records.Code_Kind.Function),
		flags = {.Color, .Reverse, .End_Line},
		color = 0xFF12_AB0C,
	}
	testing.expect_value(t, output_of(t, "ok", style), "{\"t\":\"out\",\"s\":\"ok\",\"tone\":\"good\",\"code\":\"function\",\"fg\":\"#12ab0c\",\"rev\":true,\"nl\":true}")
	for tone in terminal_records.Tone {
		body := output_of(t, "", {tone = u8(tone)})
		testing.expect(t, tone == .Default ? !strings.contains(body, "tone") : strings.contains(body, tone_name(tone)))
	}
	refused := terminal_records.Style{tone = u8(max(terminal_records.Tone)) + 1, code = 255}
	testing.expect_value(t, output_of(t, "x", refused), "{\"t\":\"out\",\"s\":\"x\"}")
	testing.expect_value(t, output_of(t, "", {flags = {.Color}, color = 0}), "{\"t\":\"out\",\"s\":\"\",\"fg\":\"#000000\"}")
}

@(test)
write_clear_writes_one_object :: proc(t: ^testing.T) {
	buffer: [16]u8
	line := line_make(buffer[:])
	write_clear(&line)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"clr\"}")
}

// The cursor and the runs of the edit line count characters: a byte of a
// character of two bytes is one character of the page. No cursor gives no
// key cur, and no runs no key runs.
@(test)
write_edit_counts_characters :: proc(t: ^testing.T) {
	edit: terminal_records.Renderer_Edit
	edit.length = copy(edit.text[:], "é(\"€\")")
	edit.has_cursor = true
	edit.cursor = 2
	edit.code.runs[0] = {start = 0, length = 2, kind = u8(terminal_records.Code_Kind.Function)}
	edit.code.runs[1] = {start = 2, length = 1, kind = u8(terminal_records.Code_Kind.Operator)}
	edit.code.runs[2] = {start = 3, length = 5, kind = u8(terminal_records.Code_Kind.Text)}
	edit.code.runs[3] = {start = 8, length = 1, kind = 200}
	edit.code.count = 4
	buffer: [LINE_LIMIT]u8
	line := line_make(buffer[:])
	write_edit(&line, &edit)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"edit\",\"text\":\"é(\\\"€\\\")\",\"cur\":1,\"runs\":[[0,1,\"function\"],[1,2,\"operator\"],[2,5,\"text\"]]}")

	edit.has_cursor = false
	edit.code.count = 0
	line = line_make(buffer[:])
	write_edit(&line, &edit)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"edit\",\"text\":\"é(\\\"€\\\")\"}")

	// A cursor past the text gives the end of the text, a cursor inside a
	// character gives the character after it.
	edit.has_cursor = true
	edit.cursor = 1
	line = line_make(buffer[:])
	write_edit(&line, &edit)
	testing.expect(t, strings.contains(checked(t, &line), "\"cur\":1"))
	edit.cursor = 1000
	line = line_make(buffer[:])
	write_edit(&line, &edit)
	testing.expect(t, strings.contains(checked(t, &line), "\"cur\":6"))
}

// The hint gives its long form only, and its mark in characters. An empty
// text is the hint that hides.
@(test)
write_hint_gives_the_long_form_and_its_mark :: proc(t: ^testing.T) {
	hint: terminal_records.Renderer_Hint
	hint.length = copy(hint.text[:], "é(a: Text, b)é(b)")
	hint.long_bytes = len("é(a: Text, b)")
	hint.mark_start = len("é(")
	hint.mark_length = len("a: Text")
	buffer: [LINE_LIMIT]u8
	line := line_make(buffer[:])
	write_hint(&line, &hint)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"hint\",\"text\":\"é(a: Text, b)\",\"ms\":2,\"ml\":7}")
	hint = {}
	line = line_make(buffer[:])
	write_hint(&line, &hint)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"hint\",\"text\":\"\"}")
}

@(test)
write_status_gives_value_and_total :: proc(t: ^testing.T) {
	status: terminal_records.Renderer_Status
	status.length = copy(status.text[:], "build \x1b")
	status.value, status.total = 3, max(u64)
	buffer: [LINE_LIMIT]u8
	line := line_make(buffer[:])
	write_status(&line, &status)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"status\",\"text\":\"build ?\",\"v\":3,\"tot\":18446744073709551615}")
	status = {}
	line = line_make(buffer[:])
	write_status(&line, &status)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"status\",\"text\":\"\",\"v\":0,\"tot\":0}")
}

// A list gives its rows with their names, details, icons, matches and runs
// in characters, the chosen row or -1, and the start of the name in
// characters of the edit line. A chosen row past the rows is -1; an empty
// list has no items.
@(test)
write_list_gives_each_row :: proc(t: ^testing.T) {
	shown: terminal_records.List_Shown
	edit: terminal_records.Renderer_Edit
	edit.length = copy(edit.text[:], "é = he")
	shown.anchor = len("é = ")
	shown.row_count = 2
	shown.chosen = 1
	shown.first = 4
	shown.total = 14
	row := &shown.rows[0]
	row.length = copy(row.text[:], "héllo command")
	row.name_length = len("héllo")
	row.matched = {1 | 1 << 1 | 1 << 2 | 1 << 3, 0} // h, é and its second byte, l.
	row.icon = .Command
	row.code.runs[0] = {start = 0, length = 6, kind = u8(terminal_records.Code_Kind.Function)}
	row.code.runs[1] = {start = 7, length = 7, kind = u8(terminal_records.Code_Kind.Words)}
	row.code.count = 2
	shown.rows[1].length = copy(shown.rows[1].text[:], "x")
	shown.rows[1].name_length = 1
	buffer: [LINE_LIMIT]u8
	line := line_make(buffer[:])
	write_list(&line, &shown, &edit)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"list\",\"chosen\":1,\"first\":4,\"total\":14,\"start\":4,\"items\":[{\"name\":\"héllo\",\"detail\":\" command\",\"icon\":\"command\",\"match\":[0,1,2],\"runs\":[[0,5,\"function\"],[6,13,\"words\"]]},{\"name\":\"x\",\"detail\":\"\"}]}")

	shown.chosen = 2
	line = line_make(buffer[:])
	write_list(&line, &shown, &edit)
	testing.expect(t, strings.has_prefix(checked(t, &line), "{\"t\":\"list\",\"chosen\":-1,"))
	shown.chosen = -1
	shown.row_count = 0
	line = line_make(buffer[:])
	write_list(&line, &shown, &edit)
	testing.expect_value(t, checked(t, &line), "{\"t\":\"list\",\"chosen\":-1,\"first\":4,\"total\":14,\"start\":4,\"items\":[]}")
	// A row count, a name length and a first that a process could not
	// give are brought inside their bounds.
	shown.row_count = max(int)
	shown.first = -5
	shown.rows[0].name_length = max(int)
	line = line_make(buffer[:])
	write_list(&line, &shown, &edit)
	body := checked(t, &line)
	testing.expect(t, strings.contains(body, "\"first\":0"))
	testing.expect_value(t, strings.count(body, "\"name\":"), terminal_records.LIST_ROWS)
}

// The largest list fits LINE_LIMIT: each row of RUN_LIMIT quotes, which
// escape to two bytes, each byte of the name matched, and CODE_RUN_LIMIT
// runs.
@(test)
the_largest_list_fits_one_line :: proc(t: ^testing.T) {
	shown: terminal_records.List_Shown
	edit: terminal_records.Renderer_Edit
	shown.row_count = terminal_records.LIST_ROWS
	shown.chosen = 0
	shown.total = max(int)
	shown.first = max(int)
	for &row in shown.rows {
		for index in 0 ..< terminal_records.RUN_LIMIT {
			row.text[index] = '"'
		}
		row.length = terminal_records.RUN_LIMIT
		row.name_length = MATCHED_BYTES_LIMIT
		row.matched = {max(u64), max(u64)}
		row.icon = .History_Line
		for index in 0 ..< terminal_records.CODE_RUN_LIMIT {
			row.code.runs[index] = {start = u16(index * 4), length = 4, kind = u8(terminal_records.Code_Kind.Text_Unfinished)}
		}
		row.code.count = terminal_records.CODE_RUN_LIMIT
	}
	buffer: [LINE_LIMIT]u8
	line := line_make(buffer[:])
	write_list(&line, &shown, &edit)
	_ = checked(t, &line)
}

// A line that does not fit is not written at all: each size of the buffer
// below the line gives nil and writes no byte past the buffer; the size of
// the line gives the line.
@(test)
a_line_that_does_not_fit_is_not_written :: proc(t: ^testing.T) {
	full: [LINE_LIMIT]u8
	line := line_make(full[:])
	write_output(&line, transmute([]u8)string("é\"\\x"), {tone = u8(terminal_records.Tone.Bad), flags = {.End_Line}})
	whole := string(line_written(&line))
	testing.expect(t, len(whole) > 0)
	for size in 0 ..< len(whole) {
		guarded: [64]u8
		for &b in guarded {
			b = 0xAA
		}
		small := line_make(guarded[:size])
		write_output(&small, transmute([]u8)string("é\"\\x"), {tone = u8(terminal_records.Tone.Bad), flags = {.End_Line}})
		testing.expectf(t, line_written(&small) == nil, "a buffer of %d bytes gives a line", size)
		for b in guarded[size:] {
			testing.expect_value(t, b, u8(0xAA))
		}
	}
	exact := make([]u8, len(whole), context.temp_allocator)
	fitted := line_make(exact)
	write_output(&fitted, transmute([]u8)string("é\"\\x"), {tone = u8(terminal_records.Tone.Bad), flags = {.End_Line}})
	testing.expect_value(t, string(line_written(&fitted)), whole)
}

// write_step gives nil for None, and one line for each other step, from
// the state of the intake.
@(test)
write_step_writes_each_step_of_the_intake :: proc(t: ^testing.T) {
	intake := terminal_records.renderer_intake_make(nil)
	intake.text_length = copy(intake.text[:], "hi")
	buffer: [LINE_LIMIT]u8
	for step in terminal_records.Renderer_Step {
		line := line_make(buffer[:])
		written := write_step(&line, step, &intake, {})
		if step == .None {
			testing.expect(t, written == nil)
			continue
		}
		body := checked(t, &line)
		expected: string
		switch step {
		case .None:
		case .Text:
			expected = "{\"t\":\"out\","
		case .Clear:
			expected = "{\"t\":\"clr\""
		case .Edit:
			expected = "{\"t\":\"edit\","
		case .List:
			expected = "{\"t\":\"list\","
		case .Status:
			expected = "{\"t\":\"status\","
		case .Hint:
			expected = "{\"t\":\"hint\","
		}
		testing.expectf(t, strings.has_prefix(body, expected), "%v gives %q", step, body)
	}
}

// Each member has its own name: the page reads a class from it.
@(test)
each_member_has_its_own_name :: proc(t: ^testing.T) {
	names := make(map[string]bool, context.temp_allocator)
	for tone in terminal_records.Tone {
		testing.expect(t, !names[tone_name(tone)])
		names[tone_name(tone)] = true
	}
	clear(&names)
	for kind in terminal_records.Code_Kind {
		testing.expect(t, !names[code_kind_name(kind)])
		names[code_kind_name(kind)] = true
	}
	clear(&names)
	for icon in terminal_records.List_Icon {
		testing.expect(t, !names[list_icon_name(icon)])
		names[list_icon_name(icon)] = true
	}
}
