// Real remote QUIC call transport adapter for the host Agent Bridge
// (src/md/features/agent_bridge.md).
//
// Wraps modustool:machine Call_Client so Eval_Lex and Read_Log_Facts speak
// directly to a running modus machine over the pinned peer call socket without
// scraping terminal text. Live remote_display frame/input streaming over the
// peer relay is not attached to this call-only transport and fails closed with
// a transport error.
package host_agent_bridge

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import contract "modus:contract/agent_bridge"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/value_kinds"
import "modus:contract/wide_grants"
import "modus:sentence"
import "modustool:build"
import "modustool:machine"

// Remote_Machine_Transport connects the host Agent_Bridge to a running modus
// machine through modustool:machine Call_Client and the peer Unix call socket.
Remote_Machine_Transport :: struct {
	opened:      bool,
	socket_path: string,
	remote_key:  [32]u8,
	client:      machine.Call_Client,
}

// remote_transport_open initializes the underlying Call_Client for socket_path
// and the pinned remote public key. Clones socket_path so temporary allocator
// resets between JSON-RPC requests never invalidate the socket path.
remote_transport_open :: proc(
	transport: ^Remote_Machine_Transport,
	socket_path: string,
	remote_key: [32]u8,
) -> bool {
	if transport == nil || len(socket_path) == 0 {
		return false
	}
	cloned_socket := strings.clone(socket_path)
	client: machine.Call_Client
	if !machine.call_client_open(&client, cloned_socket, remote_key) {
		delete(cloned_socket)
		return false
	}
	transport^ = Remote_Machine_Transport {
		opened      = true,
		socket_path = cloned_socket,
		remote_key  = remote_key,
		client      = client,
	}
	return true
}

// remote_transport_close releases buffers and cached module files held by
// transport.
remote_transport_close :: proc(transport: ^Remote_Machine_Transport) {
	if transport == nil || !transport.opened {
		return
	}
	machine.call_client_close(&transport.client)
	delete(transport.socket_path)
	transport^ = {}
}

// remote_transport_interface returns the Machine_Transport vtable backed by
// transport.
remote_transport_interface :: proc(transport: ^Remote_Machine_Transport) -> Machine_Transport {
	return Machine_Transport {
		user_data      = transport,
		eval_lex       = remote_transport_eval_lex,
		read_screen    = remote_transport_read_screen,
		send_key       = remote_transport_send_key,
		send_pointer   = remote_transport_send_pointer,
		read_log_facts = remote_transport_read_log_facts,
		ask_wide_grant = remote_transport_ask_wide_grant,
	}
}

// remote_transport_ask_wide_grant sends the ask of a wide grant through
// `remote`, and gives the number of the screen that the trusted display
// shows, or the sentence of the refusal.
@(private = "file")
remote_transport_ask_wide_grant :: proc(user_data: rawptr, authorities: wide_grants.Wide_Authorities, duration_ms: u64) -> (screen: u64, err: string, ok: bool) {
	transport, transport_ok := remote_transport_from_user_data(user_data)
	if !transport_ok {
		return 0, "remote transport is not open", false
	}
	answer, call_transport, sent := machine.wide_grant_ask_send(&transport.client, authorities, duration_ms)
	if !sent {
		return 0, format_remote_transport_failure(call_transport, context.temp_allocator), false
	}
	if answer.status != .Ok {
		error := answer.error
		return 0, fmt.tprintf("remote refused the ask of a wide grant: kind %d, unit %d, field %d", error.kind, error.unit, error.argument), false
	}
	return u64(answer.value), "", true
}

@(private = "file")
remote_transport_from_user_data :: proc(user_data: rawptr) -> (transport: ^Remote_Machine_Transport, ok: bool) {
	if user_data == nil {
		return nil, false
	}
	candidate := (^Remote_Machine_Transport)(user_data)
	if !candidate.opened {
		return nil, false
	}
	return candidate, true
}

// remote_transport_failure_outcome gives the call outcome of a call that
// got no whole answer, from the end that the transport saw: the one place
// of this map. A call that left and lost its answer is in doubt; a call that
// never left changed nothing.
@(private = "file")
remote_transport_failure_outcome :: proc(call_transport: machine.Call_Transport) -> call_outcome.Call_Outcome {
	switch call_transport.outcome {
	case .Reset, .Lost:
		return .Connection_Ended_During_The_Call
	case .Request_Too_Large:
		return .Argument_Refused
	case .Peer_Absent:
		return .Callee_Unavailable
	case .Peer_Full:
		// The peer serves other callers too: its room frees by itself.
		return .Callee_Busy
	case .Answer, .Answer_Too_Large:
		return .Answer_Unreadable
	case .Client_Refused:
		return .Grant_Or_Right_Missing
	case .No_Key, .Key_Refused, .Bad_Socket_Call:
		return .Callee_Unavailable
	}
	return .Answer_Unreadable
}

@(private = "file")
format_remote_transport_failure :: proc(call_transport: machine.Call_Transport, allocator: mem.Allocator) -> string {
	switch call_transport.outcome {
	case .Answer:
		return strings.clone("remote call gave an unexpected empty transport failure", allocator)
	case .Reset:
		name := remote.stream_error_name(call_transport.code)
		if name == "" {
			return fmt.aprintf("remote reset the stream with code %d", call_transport.code, allocator = allocator)
		}
		return fmt.aprintf("remote reset the stream with code %s", name, allocator = allocator)
	case .Lost, .No_Key, .Answer_Too_Large, .Key_Refused, .Bad_Socket_Call, .Client_Refused, .Request_Too_Large, .Peer_Absent, .Peer_Full:
		if call_transport.reason != "" {
			return strings.clone(call_transport.reason, allocator)
		}
		return fmt.aprintf("remote call failed with transport outcome %v", call_transport.outcome, allocator = allocator)
	}
	return strings.clone("remote call failed", allocator)
}

@(private = "file")
decode_remote_call_result :: proc(
	call: ^machine.Prepared_Call,
	answer: remote.Answer,
	result_bytes: []u8,
	allocator: mem.Allocator,
) -> (result: Lex_Eval_Result, err: string, ok: bool) {
	result_type, result_type_ok := module.function_result_type(call.function)
	if !result_type_ok {
		return {}, fmt.aprintf("remote export %s.%s returned unknown result type byte %d", call.service, call.export, call.function.result, allocator = allocator), false
	}
	switch result_type {
	case .None:
		return Lex_Eval_Result{value_kind = .None}, "", true

	case .Integer:
		return Lex_Eval_Result {
			value_kind    = .Integer,
			integer_value = answer.value,
			text_value    = fmt.aprintf("%d", answer.value, allocator = allocator),
		}, "", true

	case .Enum:
		described, problem := module.enum_type(call.file, call.function.result_detail)
		if problem == .None {
			value := module.enum_value_of_register(described, answer.value)
			if name, named := module.enum_name_of_value(call.file, described, value); named {
				return Lex_Eval_Result {
					value_kind = .Enum_Member,
					text_value = fmt.aprintf(".%s", name, allocator = allocator),
				}, "", true
			}
			return Lex_Eval_Result {
				value_kind    = .Integer,
				integer_value = value,
				text_value    = fmt.aprintf("%d", value, allocator = allocator),
			}, "", true
		}
		return Lex_Eval_Result {
			value_kind    = .Integer,
			integer_value = answer.value,
			text_value    = fmt.aprintf("%d", answer.value, allocator = allocator),
		}, "", true

	case .Text:
		return Lex_Eval_Result {
			value_kind = .Text,
			text_value = strings.clone(string(result_bytes), allocator),
		}, "", true

	case .Record:
		described, described_ok := module.record_type(call.file, call.function.result_detail)
		if !described_ok {
			return {}, strings.clone("remote record result has no valid description", allocator), false
		}
		field_count := int(described.field_count)
		columns := make([]string, field_count, allocator)
		kinds := make([]contract.Lex_Column_Kind, field_count, allocator)
		units := make([]i64, field_count, allocator)
		row := make([]string, field_count, allocator)
		integers := make([]i64, field_count, allocator)
		for index in 0 ..< field_count {
			item, _ := module.field(call.file, described, u32(index))
			columns[index] = strings.clone(module.string_at(call.file, item.name_offset, item.name_count), allocator)
			kinds[index], units[index] = column_kind_of_field(item)
			row[index] = strings.clone(build.field_value(result_bytes, item), allocator)
			integers[index] = column_integer(result_bytes, item, kinds[index])
		}
		rows := make([][]string, 1, allocator)
		rows[0] = row
		row_integers := make([][]i64, 1, allocator)
		row_integers[0] = integers
		record_name := strings.clone(module.string_at(call.file, described.name_offset, described.name_count), allocator)
		return Lex_Eval_Result {
			value_kind   = .Record,
			record_name  = record_name,
			columns      = columns,
			column_kinds = kinds,
			column_units = units,
			rows         = rows,
			row_integers = row_integers,
			total_rows   = 1,
		}, "", true

	case .Table:
		described, described_ok := module.record_type(call.file, call.function.result_detail)
		if !described_ok {
			return {}, strings.clone("remote table result has no valid description", allocator), false
		}
		row_size := int(max(described.size, 1))
		row_count := len(result_bytes) / row_size
		field_count := int(described.field_count)
		columns := make([]string, field_count, allocator)
		kinds := make([]contract.Lex_Column_Kind, field_count, allocator)
		units := make([]i64, field_count, allocator)
		for index in 0 ..< field_count {
			item, _ := module.field(call.file, described, u32(index))
			columns[index] = strings.clone(module.string_at(call.file, item.name_offset, item.name_count), allocator)
			kinds[index], units[index] = column_kind_of_field(item)
		}
		rows := make([][]string, row_count, allocator)
		row_integers := make([][]i64, row_count, allocator)
		for row_index in 0 ..< row_count {
			row_bytes := result_bytes[row_index * row_size:][:row_size]
			cells := make([]string, field_count, allocator)
			integers := make([]i64, field_count, allocator)
			for col_index in 0 ..< field_count {
				item, _ := module.field(call.file, described, u32(col_index))
				cells[col_index] = strings.clone(build.field_value(row_bytes, item), allocator)
				integers[col_index] = column_integer(row_bytes, item, kinds[col_index])
			}
			rows[row_index] = cells
			row_integers[row_index] = integers
		}
		record_name := strings.clone(module.string_at(call.file, described.name_offset, described.name_count), allocator)
		return Lex_Eval_Result {
			value_kind   = .Table,
			record_name  = record_name,
			columns      = columns,
			column_kinds = kinds,
			column_units = units,
			rows         = rows,
			row_integers = row_integers,
			total_rows   = answer.value,
		}, "", true

	case .Handle, .Bytes:
		return {}, fmt.aprintf("remote export %s.%s returned unsupported type %v", call.service, call.export, result_type, allocator = allocator), false
	}

	return {}, strings.clone("unsupported remote result type", allocator), false
}

@(private = "file")
remote_transport_eval_lex :: proc(
	user_data: rawptr,
	line: string,
	allocator: mem.Allocator,
) -> (result: Lex_Eval_Result, outcome: call_outcome.Call_Outcome, err: string) {
	transport, opened := remote_transport_from_user_data(user_data)
	if !opened {
		return {}, .Callee_Unavailable, strings.clone("remote transport is not open", allocator)
	}
	call, problem := machine.call_prepare(&transport.client, line)
	if problem != "" {
		return {}, .Argument_Refused, strings.clone(problem, allocator)
	}
	answer, result_bytes, call_transport, answered := machine.call_send(&transport.client, &call)
	if !answered {
		return {}, remote_transport_failure_outcome(call_transport), format_remote_transport_failure(call_transport, allocator)
	}
	// The answer comes from the network: its two outcome words go through
	// their border, and the agent reads the outcome and its effect group by
	// the names of their members.
	record: errors.Error_Record
	request_refused: bool
	outcome, record, request_refused = remote.answer_outcome(answer)
	if request_refused {
		field := ""
		if record.argument >= 1 && record.argument <= len(remote.REQUEST_FIELD_NAMES) {
			field = remote.REQUEST_FIELD_NAMES[record.argument - 1]
		}
		buffer := make([]u8, 512, context.temp_allocator)
		writer := sentence.Writer{buffer = buffer}
		sentence.error_text(&writer, &record, "remote", field)
		return {}, outcome, fmt.aprintf("%s (outcome %s, effect %s)", sentence.written(&writer), call_outcome.CALL_OUTCOME_NAMES[outcome], call_outcome.EFFECT_GROUP_NAMES[call_outcome.effect_group_of(outcome)], allocator = allocator)
	}
	answer.error = record
	if outcome != .Succeeded {
		buffer := make([]u8, 512, context.temp_allocator)
		writer := sentence.Writer{buffer = buffer}
		argument := ""
		if answer.error.argument >= 1 && answer.error.argument <= i64(call.function.parameter_count) {
			number := answer.error.argument - 1
			argument = module.string_at(call.file, call.function.parameter_names[number], u32(call.function.parameter_name_counts[number]))
		}
		sentence.call_failure_text(&writer, outcome, &answer.error, fmt.tprintf("%s.%s", call.service, call.export), argument)
		return {}, outcome, fmt.aprintf("%s (outcome %s, effect %s)", sentence.written(&writer), call_outcome.CALL_OUTCOME_NAMES[outcome], call_outcome.EFFECT_GROUP_NAMES[call_outcome.effect_group_of(outcome)], allocator = allocator)
	}
	// The call succeeded; a result that this reader cannot decode is an
	// answer that it cannot read.
	decoded, decode_problem, decoded_ok := decode_remote_call_result(&call, answer, result_bytes, allocator)
	if !decoded_ok {
		return {}, .Answer_Unreadable, decode_problem
	}
	return decoded, .Succeeded, ""
}

@(private = "file")
remote_transport_read_log_facts :: proc(
	user_data: rawptr,
	query: Log_Facts_Query,
	allocator: mem.Allocator,
) -> (facts: []Structured_Log_Fact, err: string, ok: bool) {
	transport, opened := remote_transport_from_user_data(user_data)
	if !opened {
		return nil, strings.clone("remote transport is not open", allocator), false
	}
	call_text := fmt.tprintf("log.records(%d)", query.sequence_start)
	table, table_ok := machine.table_call(&transport.client, call_text)
	if !table_ok {
		return nil, strings.clone("remote log.records call failed", allocator), false
	}
	row_count := len(table.rows) / table.size
	limit := int(query.max_records)
	if limit <= 0 {
		limit = contract.MAX_LOG_FACT_QUERY_LIMIT
	}
	matched := make([dynamic]Structured_Log_Fact, 0, min(row_count, limit), allocator)
	for row_index in 0 ..< row_count {
		if len(matched) >= limit {
			break
		}
		seq_val, seq_ok := strconv.parse_u64(machine.table_value(&table, row_index, "number"))
		if !seq_ok {
			continue
		}
		if seq_val < query.sequence_start {
			continue
		}
		if query.sequence_end != 0 && seq_val > query.sequence_end {
			continue
		}
		process_name := machine.table_value(&table, row_index, "process")
		if len(query.module_filter) > 0 && process_name != query.module_filter {
			continue
		}
		form_name := machine.table_value(&table, row_index, "form")
		if len(query.fact_name_filter) > 0 && form_name != query.fact_name_filter {
			continue
		}
		time_us, _ := strconv.parse_u64(machine.table_value(&table, row_index, "time"))
		level_name := machine.table_value(&table, row_index, "level")
		slot_text := machine.table_value(&table, row_index, "slot")
		body_text := machine.table_value(&table, row_index, "text")

		fields := make([dynamic]Log_Fact_Field, 0, 3, allocator)
		append(&fields, Log_Fact_Field{name = strings.clone("slot", allocator), value = strings.clone(slot_text, allocator)})
		append(&fields, Log_Fact_Field{name = strings.clone("form", allocator), value = strings.clone(form_name, allocator)})
		if len(body_text) > 0 {
			append(&fields, Log_Fact_Field{name = strings.clone("text", allocator), value = strings.clone(body_text, allocator)})
		}

		append(&matched, Structured_Log_Fact {
			sequence     = seq_val,
			timestamp_ms = time_us / 1_000,
			module_name  = strings.clone(process_name, allocator),
			fact_name    = strings.clone(form_name, allocator),
			level        = strings.clone(level_name, allocator),
			fields       = fields[:],
		})
	}
	return matched[:], "", true
}

@(private = "file")
remote_transport_read_screen :: proc(
	user_data: rawptr,
	request: Screen_Snapshot_Request,
	allocator: mem.Allocator,
) -> (snapshot: Screen_Snapshot_Result, err: string, ok: bool) {
	_ = request
	if _, opened := remote_transport_from_user_data(user_data); !opened {
		return {}, strings.clone("remote transport is not open", allocator), false
	}
	return {}, strings.clone("live remote_display frame streaming is not connected on the QUIC call transport", allocator), false
}

@(private = "file")
remote_transport_send_key :: proc(
	user_data: rawptr,
	window_id: u64,
	key: remote_display.Key_Body,
) -> (err: string, ok: bool) {
	_ = window_id
	_ = key
	if _, opened := remote_transport_from_user_data(user_data); !opened {
		return "remote transport is not open", false
	}
	return "live remote_display input streaming is not connected on the QUIC call transport", false
}

@(private = "file")
remote_transport_send_pointer :: proc(
	user_data: rawptr,
	window_id: u64,
	pointer: remote_display.Pointer_Body,
) -> (err: string, ok: bool) {
	_ = window_id
	_ = pointer
	if _, opened := remote_transport_from_user_data(user_data); !opened {
		return "remote transport is not open", false
	}
	return "live remote_display input streaming is not connected on the QUIC call transport", false
}

// column_kind_of_field gives the kind of a column of a result and its unit
// word, from the field that describes it: the form in which the drawers of
// the console write and align it (modus:console_results, cell_of). A
// number with no other form is an Integer, with its unit a Size or a Time;
// a hexadecimal number keeps its bytes; each other form (a text, a status
// name, a hash, a handle, a fixed point) is a Text, its cell the text that
// the bridge writes.
column_kind_of_field :: proc(item: module.Field) -> (kind: contract.Lex_Column_Kind, unit: i64) {
	type, type_ok := module.field_type(item)
	field_kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok || type != .Integer {
		return .Text, 0
	}
	// Two kinds of a field name a number form; each other kind is written
	// as a text, as module.field_kind_text writes it.
	if field_kind == .Hexadecimal {
		return .Hexadecimal, i64(module.field_size(item))
	}
	if field_kind != .Plain {
		return .Text, 0
	}
	integer_unit := item.integer_unit
	if value_kinds.integer_unit_valid(integer_unit) && integer_unit.kind == .Size {
		return .Size, i64(integer_unit.unit)
	}
	if value_kinds.integer_unit_valid(integer_unit) && integer_unit.kind == .Time {
		return .Time, i64(integer_unit.unit)
	}
	return .Integer, 0
}

// column_integer gives the value of a cell of a number column, 0 in a text
// column.
column_integer :: proc(row: []u8, item: module.Field, kind: contract.Lex_Column_Kind) -> i64 {
	switch kind {
	case .Integer, .Size, .Time, .Hexadecimal:
		if u64(item.offset) + u64(module.field_size(item)) <= u64(len(row)) {
			return module.field_integer(row, item)
		}
	case .None, .Text:
	}
	return 0
}
