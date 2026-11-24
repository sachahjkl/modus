// The agent runner of the assistant (src/md/features/assistant.md): the
// border of a model reply, the models, and the turn that answers one
// request of the window through remote and the host agent bridge.
package agent_runner

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import bridge_contract "modus:contract/agent_bridge"
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
	kind:             assistant_contract.Act_Kind,
	line:             string,
	step_lines:       [bridge_contract.AGENT_STEP_LINE_CAPACITY]string,
	step_line_count:  int,
	screen_format:    string,
	max_width:        u32,
	max_height:       u32,
	module_filter:    string,
	fact_name_filter: string,
	max_records:      u32,
	window_id:        u64,
	key_code:         u32,
	key_character:    u32,
	key_pressed:      bool,
	key_modifiers:    u32,
	pointer_x:        u32,
	pointer_y:        u32,
	pointer_buttons:  u32,
	pointer_wheel:    i32,
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
int_read :: proc(reader: ^Reader) -> (value: i64, ok: bool) {
	spaces_skip(reader)
	start := reader.place
	if reader.place < len(reader.text) && reader.text[reader.place] == '-' {
		reader.place += 1
	}
	digits_start := reader.place
	for reader.place < len(reader.text) && reader.text[reader.place] >= '0' && reader.text[reader.place] <= '9' {
		reader.place += 1
	}
	if reader.place == digits_start {
		return 0, false
	}
	parsed, parsed_ok := strconv.parse_i64(reader.text[start:reader.place])
	return parsed, parsed_ok
}

@(private = "file")
bool_read :: proc(reader: ^Reader) -> (value: bool, ok: bool) {
	spaces_skip(reader)
	if strings.has_prefix(reader.text[reader.place:], "true") {
		reader.place += 4
		return true, true
	}
	if strings.has_prefix(reader.text[reader.place:], "false") {
		reader.place += 5
		return false, true
	}
	return false, false
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
// array of 0 to 16 act objects. Each other form is refused whole with its
// error record, before any act runs.
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
lines_array_read :: proc(reader: ^Reader, act: ^Model_Act, number: int) -> (record: errors.Error_Record, ok: bool) {
	if !byte_take(reader, '[') {
		return refuse(.Bad_Value, .Bytes, .Line, i64(reader.place), 0, number), false
	}
	if byte_take(reader, ']') {
		return refuse(.Empty, .Records, .Line, 0, bridge_contract.AGENT_STEP_LINE_CAPACITY, number), false
	}
	for {
		if act.step_line_count >= bridge_contract.AGENT_STEP_LINE_CAPACITY {
			return refuse(.Too_Long, .Records, .Line, i64(act.step_line_count + 1), bridge_contract.AGENT_STEP_LINE_CAPACITY, number), false
		}
		place := reader.place
		value, value_ok := string_read(reader)
		if !value_ok {
			return refuse(.Bad_Value, .Bytes, .Line, i64(place), 0, number), false
		}
		if refused_record, refused := text_refusal(value, assistant_contract.ACT_LINE_BYTES, .Line, number); refused {
			return refused_record, false
		}
		act.step_lines[act.step_line_count] = value
		act.step_line_count += 1
		if byte_take(reader, ',') {
			continue
		}
		if byte_take(reader, ']') {
			return {}, true
		}
		return refuse(.Bad_Value, .Bytes, .Line, i64(reader.place), 0, number), false
	}
}

@(private = "file")
act_read :: proc(reader: ^Reader, number: int) -> (act: Model_Act, record: errors.Error_Record, ok: bool) {
	if !byte_take(reader, '{') {
		return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(reader.place), 0, number), false
	}
	has_kind, has_line, has_lines := false, false, false
	has_format, has_max_w, has_max_h := false, false, false
	has_module, has_fact_name, has_max_rec := false, false, false
	has_win, has_code, has_char, has_pressed, has_mods := false, false, false, false, false
	has_x, has_y, has_buttons, has_wheel := false, false, false, false

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
		case "lines":
			if has_lines {
				return {}, refuse(.Bad_Value, .Bytes, .Line, i64(name_place), 0, number), false
			}
			has_lines = true
			lines_rec, lines_ok := lines_array_read(reader, &act, number)
			if !lines_ok {
				return {}, lines_rec, false
			}
		case "format":
			if has_format {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_format = true
			val, val_ok := string_read(reader)
			if !val_ok || (val != "png" && val != "raw_bgrx") {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.screen_format = val
		case "max_width":
			if has_max_w {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_max_w = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > i64(max(u32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.max_width = u32(v)
		case "max_height":
			if has_max_h {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_max_h = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > i64(max(u32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.max_height = u32(v)
		case "module":
			if has_module {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_module = true
			val, val_ok := string_read(reader)
			if !val_ok || len(val) > bridge_contract.MAX_FILTER_NAME_BYTES {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), bridge_contract.MAX_FILTER_NAME_BYTES, number), false
			}
			act.module_filter = val
		case "fact_name":
			if has_fact_name {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_fact_name = true
			val, val_ok := string_read(reader)
			if !val_ok || len(val) > bridge_contract.MAX_FILTER_NAME_BYTES {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), bridge_contract.MAX_FILTER_NAME_BYTES, number), false
			}
			act.fact_name_filter = val
		case "max_records":
			if has_max_rec {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_max_rec = true
			v, vok := int_read(reader)
			if !vok || v <= 0 || v > bridge_contract.MAX_LOG_FACT_QUERY_LIMIT {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), bridge_contract.MAX_LOG_FACT_QUERY_LIMIT, number), false
			}
			act.max_records = u32(v)
		case "window_id":
			if has_win {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_win = true
			v, vok := int_read(reader)
			if !vok || v <= 0 {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.window_id = u64(v)
		case "code":
			if has_code {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_code = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > i64(max(u32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.key_code = u32(v)
		case "character":
			if has_char {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_char = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > 0x10FFFF {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0x10FFFF, number), false
			}
			act.key_character = u32(v)
		case "pressed":
			if has_pressed {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_pressed = true
			b, bok := bool_read(reader)
			if !bok {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.key_pressed = b
		case "modifiers":
			if has_mods {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_mods = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > i64(max(u32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.key_modifiers = u32(v)
		case "x":
			if has_x {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_x = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > i64(max(u32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.pointer_x = u32(v)
		case "y":
			if has_y {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_y = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > i64(max(u32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.pointer_y = u32(v)
		case "buttons":
			if has_buttons {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_buttons = true
			v, vok := int_read(reader)
			if !vok || v < 0 || v > i64(max(u32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.pointer_buttons = u32(v)
		case "wheel":
			if has_wheel {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(name_place), 0, number), false
			}
			has_wheel = true
			v, vok := int_read(reader)
			if !vok || v < i64(min(i32)) || v > i64(max(i32)) {
				return {}, refuse(.Bad_Value, .Bytes, .Acts, i64(value_place), 0, number), false
			}
			act.pointer_wheel = i32(v)
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

	// Enforce exact per-kind field schema and build canonical window display line.
	screen_fields := has_format || has_max_w || has_max_h
	log_fields := has_module || has_fact_name || has_max_rec
	key_fields := has_code || has_char || has_pressed || has_mods
	ptr_fields := has_x || has_y || has_buttons || has_wheel

	switch act.kind {
	case .Eval_Lex:
		if has_lines || screen_fields || log_fields || has_win || key_fields || ptr_fields {
			return {}, refuse(.Bad_Value, .Bytes, .Acts, 0, 0, number), false
		}
		if !has_line {
			return {}, refuse(.Absent, .Bytes, .Line, 0, 0, number), false
		}
	case .Eval_Step:
		if has_line || screen_fields || log_fields || has_win || key_fields || ptr_fields {
			return {}, refuse(.Bad_Value, .Bytes, .Acts, 0, 0, number), false
		}
		if !has_lines || act.step_line_count == 0 {
			return {}, refuse(.Absent, .Bytes, .Line, 0, 0, number), false
		}
		joined := strings.join(act.step_lines[:act.step_line_count], "; ", reader.allocator)
		act.line = text_cut_bound(joined, assistant_contract.ACT_LINE_BYTES)
	case .Read_Screen:
		if has_line || has_lines || log_fields || has_win || key_fields || ptr_fields {
			return {}, refuse(.Bad_Value, .Bytes, .Acts, 0, 0, number), false
		}
		if !has_format {
			act.screen_format = "png"
		}
		act.line = fmt.aprintf("read_screen(format = \"%s\")", act.screen_format, allocator = reader.allocator)
	case .Read_Log_Facts:
		if has_line || has_lines || screen_fields || has_win || key_fields || ptr_fields {
			return {}, refuse(.Bad_Value, .Bytes, .Acts, 0, 0, number), false
		}
		if !has_max_rec {
			act.max_records = 64
		}
		act.line = fmt.aprintf("read_log_facts(max_records = %d)", act.max_records, allocator = reader.allocator)
	case .Send_Key:
		if has_line || has_lines || screen_fields || log_fields || ptr_fields {
			return {}, refuse(.Bad_Value, .Bytes, .Acts, 0, 0, number), false
		}
		if !has_win || !has_code || !has_pressed {
			return {}, refuse(.Absent, .Bytes, .Acts, 0, 0, number), false
		}
		act.line = fmt.aprintf("send_key(window = %d, code = %d, pressed = %s)", act.window_id, act.key_code, act.key_pressed ? "true" : "false", allocator = reader.allocator)
	case .Send_Pointer:
		if has_line || has_lines || screen_fields || log_fields || key_fields {
			return {}, refuse(.Bad_Value, .Bytes, .Acts, 0, 0, number), false
		}
		if !has_win || !has_x || !has_y {
			return {}, refuse(.Absent, .Bytes, .Acts, 0, 0, number), false
		}
		act.line = fmt.aprintf("send_pointer(window = %d, x = %d, y = %d, buttons = %d)", act.window_id, act.pointer_x, act.pointer_y, act.pointer_buttons, allocator = reader.allocator)
	}
	return act, {}, true
}
