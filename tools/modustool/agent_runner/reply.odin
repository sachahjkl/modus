// The agent runner of the assistant (src/md/features/assistant.md): the
// border of a model reply, the models, and the turn that answers one
// request of the window through remote and the host agent bridge.
package agent_runner

import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"

// The bytes of a whole model reply at most: the text, up to 16 acts and
// the JSON around them, with room for escapes.
MODEL_REPLY_BYTES :: 256 * 1024

// The field that a refusal of a model reply names, as the argument of its
// error record: 0 the reply as a whole.
Reply_Field :: enum i64 {
	Reply = 0,
	Text  = 1,
	Acts  = 2,
	Kind  = 3,
	Line  = 4,
}

Model_Act :: struct {
	kind: assistant_contract.Act_Kind,
	line: string,
}

// A model reply that passed the border: its text, one line, and its acts.
Model_Reply :: struct {
	text:      string,
	acts:      [assistant_contract.MODEL_ACT_CAPACITY]Model_Act,
	act_count: int,
}

@(private = "file")
Reader :: struct {
	text:      string,
	place:     int,
	allocator: mem.Allocator,
}

@(private = "file")
refuse :: proc(kind: errors.Kind, unit: errors.Unit, field: Reply_Field, value: i64 = 0, limit: i64 = 0, act: int = 0) -> errors.Error_Record {
	return errors.error_make(kind, unit, i64(field), value, limit, i64(act))
}

@(private = "file")
spaces_skip :: proc(reader: ^Reader) {
	for reader.place < len(reader.text) {
		switch reader.text[reader.place] {
		case ' ', '\t', '\n', '\r':
			reader.place += 1
		case:
			return
		}
	}
}

@(private = "file")
byte_take :: proc(reader: ^Reader, expected: u8) -> bool {
	spaces_skip(reader)
	if reader.place < len(reader.text) && reader.text[reader.place] == expected {
		reader.place += 1
		return true
	}
	return false
}

@(private = "file")
byte_next :: proc(reader: ^Reader) -> (character: u8, present: bool) {
	spaces_skip(reader)
	if reader.place >= len(reader.text) {
		return 0, false
	}
	return reader.text[reader.place], true
}

// string_read reads a JSON string at the place, with its escapes: a
// control byte in it, an escape that JSON does not have, a lone surrogate
// and an end of the reply refuse it.
@(private = "file")
string_read :: proc(reader: ^Reader) -> (text: string, ok: bool) {
	if !byte_take(reader, '"') {
		return "", false
	}
	builder := strings.builder_make(reader.allocator)
	for reader.place < len(reader.text) {
		character := reader.text[reader.place]
		reader.place += 1
		switch {
		case character == '"':
			return strings.to_string(builder), true
		case character < 0x20:
			return "", false
		case character != '\\':
			strings.write_byte(&builder, character)
			continue
		}
		if reader.place >= len(reader.text) {
			return "", false
		}
		escape := reader.text[reader.place]
		reader.place += 1
		switch escape {
		case '"', '\\', '/':
			strings.write_byte(&builder, escape)
		case 'b':
			strings.write_byte(&builder, 0x08)
		case 'f':
			strings.write_byte(&builder, 0x0C)
		case 'n':
			strings.write_byte(&builder, '\n')
		case 'r':
			strings.write_byte(&builder, '\r')
		case 't':
			strings.write_byte(&builder, '\t')
		case 'u':
			first := hex4_read(reader) or_return
			code := rune(first)
			if first >= 0xD800 && first <= 0xDBFF {
				if reader.place + 2 > len(reader.text) || reader.text[reader.place] != '\\' || reader.text[reader.place + 1] != 'u' {
					return "", false
				}
				reader.place += 2
				second := hex4_read(reader) or_return
				if second < 0xDC00 || second > 0xDFFF {
					return "", false
				}
				code = rune(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
			} else if first >= 0xDC00 && first <= 0xDFFF {
				return "", false
			}
			bytes, count := utf8.encode_rune(code)
			strings.write_bytes(&builder, bytes[:count])
		case:
			return "", false
		}
	}
	return "", false
}

@(private = "file")
hex4_read :: proc(reader: ^Reader) -> (value: u32, ok: bool) {
	if reader.place + 4 > len(reader.text) {
		return 0, false
	}
	for character in transmute([]u8)reader.text[reader.place:][:4] {
		digit: u32
		switch character {
		case '0' ..= '9':
			digit = u32(character - '0')
		case 'a' ..= 'f':
			digit = u32(character - 'a' + 10)
		case 'A' ..= 'F':
			digit = u32(character - 'A' + 10)
		case:
			return 0, false
		}
		value = value * 16 + digit
	}
	reader.place += 4
	return value, true
}

// one_line gives a text of the model with each line end written as a
// space: a Text that crosses to the window has no control byte. Any other
// control character stays, and the check of the text refuses it.
@(private = "file")
one_line :: proc(text: string, allocator: mem.Allocator) -> string {
	if strings.index_byte(text, '\n') < 0 && strings.index_byte(text, '\r') < 0 {
		return text
	}
	builder := strings.builder_make(allocator)
	for index := 0; index < len(text); index += 1 {
		switch text[index] {
		case '\r':
			if index + 1 < len(text) && text[index + 1] == '\n' {
				index += 1
			}
			strings.write_byte(&builder, ' ')
		case '\n':
			strings.write_byte(&builder, ' ')
		case:
			strings.write_byte(&builder, text[index])
		}
	}
	return strings.to_string(builder)
}

// text_refusal gives the record of a text that the contract refuses.
@(private = "file")
text_refusal :: proc(text: string, bound: int, field: Reply_Field, act: int) -> (record: errors.Error_Record, refused: bool) {
	switch assistant_contract.text_check(text, bound) {
	case .None:
		return {}, false
	case .Empty:
		return refuse(.Empty, .Bytes, field, 0, i64(bound), act), true
	case .Too_Long:
		return refuse(.Too_Long, .Bytes, field, i64(len(text)), i64(bound), act), true
	case .Not_Text:
		return refuse(.Bad_Value, .Bytes, field, i64(len(text)), 0, act), true
	}
	return refuse(.Bad_Value, .Bytes, field, 0, 0, act), true
}

// model_reply_decode reads a model reply at the one border of the runner:
// one JSON object with the field "text" and the optional field "acts", an
// array of 0 to 4 objects with the fields "kind" and "line". Each other
// form is refused whole with its error record, before any act runs: an
// unknown, missing, duplicated or mistyped field, text after the object,
// a reply that is no JSON, a text or a line past its bound or with a
// control character, a kind that names no member. The argument of the
// record names the field (Reply_Field); found is the act, from 1, or 0.
model_reply_decode :: proc(text: string, allocator := context.temp_allocator) -> (reply: Model_Reply, record: errors.Error_Record, ok: bool) {
	if len(text) > MODEL_REPLY_BYTES {
		return {}, refuse(.Too_Long, .Bytes, .Reply, i64(len(text)), MODEL_REPLY_BYTES), false
	}
	reader := Reader{text = text, allocator = allocator}
	if !byte_take(&reader, '{') {
		return {}, refuse(.Bad_Value, .Bytes, .Reply, i64(reader.place)), false
	}
	has_text, has_acts := false, false
	first := true
	for {
		if first && byte_take(&reader, '}') {
			break
		}
		first = false
		name_place := reader.place
		name, name_ok := string_read(&reader)
		if !name_ok || !byte_take(&reader, ':') {
			return {}, refuse(.Bad_Value, .Bytes, .Reply, i64(name_place)), false
		}
		switch name {
		case "text":
			if has_text {
				return {}, refuse(.Bad_Value, .Bytes, .Text, i64(name_place)), false
			}
			has_text = true
			value_place := reader.place
			value, value_ok := string_read(&reader)
			if !value_ok {
				return {}, refuse(.Bad_Value, .Bytes, .Text, i64(value_place)), false
			}
			reply.text = one_line(value, allocator)
			if refused_record, refused := text_refusal(reply.text, assistant_contract.REPLY_TEXT_BYTES, .Text, 0); refused {
				return {}, refused_record, false
			}
		case "acts":
			if has_acts {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place)), false
			}
			has_acts = true
			acts_record, acts_ok := acts_read(&reader, &reply)
			if !acts_ok {
				return {}, acts_record, false
			}
		case:
			return {}, refuse(.Bad_Value, .Bytes, .Reply, i64(name_place)), false
		}
		if byte_take(&reader, ',') {
			continue
		}
		if byte_take(&reader, '}') {
			break
		}
		return {}, refuse(.Bad_Value, .Bytes, .Reply, i64(reader.place)), false
	}
	spaces_skip(&reader)
	if reader.place != len(reader.text) {
		return {}, refuse(.Bad_Value, .Bytes, .Reply, i64(reader.place)), false
	}
	if !has_text {
		return {}, refuse(.Absent, .Bytes, .Text), false
	}
	return reply, {}, true
}

@(private = "file")
acts_read :: proc(reader: ^Reader, reply: ^Model_Reply) -> (record: errors.Error_Record, ok: bool) {
	if !byte_take(reader, '[') {
		return refuse(.Bad_Value, .Bytes, .Acts, i64(reader.place)), false
	}
	if byte_take(reader, ']') {
		return {}, true
	}
	for {
		number := reply.act_count + 1
		if reply.act_count >= assistant_contract.MODEL_ACT_CAPACITY {
			return refuse(.Too_Long, .Records, .Acts, i64(number), assistant_contract.MODEL_ACT_CAPACITY), false
		}
		act, act_record, act_ok := act_read(reader, number)
		if !act_ok {
			return act_record, false
		}
		reply.acts[reply.act_count] = act
		reply.act_count += 1
		if byte_take(reader, ',') {
			continue
		}
		if byte_take(reader, ']') {
			return {}, true
		}
		return refuse(.Bad_Value, .Bytes, .Acts, i64(reader.place), 0, number), false
	}
}

@(private = "file")
act_read :: proc(reader: ^Reader, number: int) -> (act: Model_Act, record: errors.Error_Record, ok: bool) {
	if !byte_take(reader, '{') {
		return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(reader.place), 0, number), false
	}
	has_kind, has_line := false, false
	first := true
	for {
		if first && byte_take(reader, '}') {
			break
		}
		first = false
		name_place := reader.place
		name, name_ok := string_read(reader)
		if !name_ok || !byte_take(reader, ':') {
			return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
		}
		value_place := reader.place
		switch name {
		case "kind":
			if has_kind {
				return {}, refuse(.Bad_Value, .Bytes, .Kind, i64(name_place), 0, number), false
			}
			has_kind = true
			value, value_ok := string_read(reader)
			kind, kind_ok := assistant_contract.act_kind_of_name(value)
			if !value_ok || !kind_ok {
				return {}, refuse(.Bad_Value, .Bytes, .Kind, i64(value_place), 0, number), false
			}
			act.kind = kind
		case "line":
			if has_line {
				return {}, refuse(.Bad_Value, .Bytes, .Line, i64(name_place), 0, number), false
			}
			has_line = true
			value, value_ok := string_read(reader)
			if !value_ok {
				return {}, refuse(.Bad_Value, .Bytes, .Line, i64(value_place), 0, number), false
			}
			if refused_record, refused := text_refusal(value, assistant_contract.ACT_LINE_BYTES, .Line, number); refused {
				return {}, refused_record, false
			}
			act.line = value
		case:
			return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
		}
		if byte_take(reader, ',') {
			continue
		}
		if byte_take(reader, '}') {
			break
		}
		return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(reader.place), 0, number), false
	}
	if !has_kind {
		return {}, refuse(.Absent, .Bytes, .Kind, 0, 0, number), false
	}
	if !has_line {
		return {}, refuse(.Absent, .Bytes, .Line, 0, 0, number), false
	}
	return act, {}, true
}
