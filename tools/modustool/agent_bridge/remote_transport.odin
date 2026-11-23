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
import "modus:contract/enum_word"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/remote"
import "modus:contract/remote_display"
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
	}
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
	case .Lost, .No_Key, .Answer_Too_Large, .Key_Refused, .Bad_Socket_Call, .Client_Refused, .Answer_Unknown_Status:
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
		row := make([]string, field_count, allocator)
		for index in 0 ..< field_count {
			item, _ := module.field(call.file, described, u32(index))
			columns[index] = strings.clone(module.string_at(call.file, item.name_offset, item.name_count), allocator)
			row[index] = strings.clone(build.field_value(result_bytes, item), allocator)
		}
		rows := make([][]string, 1, allocator)
		rows[0] = row
		record_name := strings.clone(module.string_at(call.file, described.name_offset, described.name_count), allocator)
		return Lex_Eval_Result {
			value_kind  = .Record,
			record_name = record_name,
			columns     = columns,
			rows        = rows,
			total_rows  = 1,
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
		for index in 0 ..< field_count {
			item, _ := module.field(call.file, described, u32(index))
			columns[index] = strings.clone(module.string_at(call.file, item.name_offset, item.name_count), allocator)
		}
		rows := make([][]string, row_count, allocator)
		for row_index in 0 ..< row_count {
			row_bytes := result_bytes[row_index * row_size:][:row_size]
			cells := make([]string, field_count, allocator)
			for col_index in 0 ..< field_count {
				item, _ := module.field(call.file, described, u32(col_index))
				cells[col_index] = strings.clone(build.field_value(row_bytes, item), allocator)
			}
			rows[row_index] = cells
		}
		record_name := strings.clone(module.string_at(call.file, described.name_offset, described.name_count), allocator)
		return Lex_Eval_Result {
			value_kind  = .Table,
			record_name = record_name,
			columns     = columns,
			rows        = rows,
			total_rows  = answer.value,
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
) -> (result: Lex_Eval_Result, err: string, ok: bool) {
	transport, opened := remote_transport_from_user_data(user_data)
	if !opened {
		return {}, strings.clone("remote transport is not open", allocator), false
	}
	call, problem := machine.call_prepare(&transport.client, line)
	if problem != "" {
		return {}, strings.clone(problem, allocator), false
	}
	answer, result_bytes, call_transport, answered := machine.call_send(&transport.client, &call)
	if !answered {
		return {}, format_remote_transport_failure(call_transport, allocator), false
	}
	switch answer.status {
	case .Ok:
	case .Refused:
		field := ""
		if answer.error.argument >= 1 && answer.error.argument <= len(remote.REQUEST_FIELD_NAMES) {
			field = remote.REQUEST_FIELD_NAMES[answer.error.argument - 1]
		}
		buffer := make([]u8, 512, context.temp_allocator)
		writer := sentence.Writer{buffer = buffer}
		sentence.error_text(&writer, &answer.error, "remote", field)
		return {}, strings.clone(sentence.written(&writer), allocator), false
	}

	call_status, call_status_known := enum_word.member_of_word(isolated.Status, u64(answer.call_status))
	if !call_status_known {
		return {}, fmt.aprintf("remote service %s returned unknown call status %d", call.service, answer.call_status, allocator = allocator), false
	}
	switch call_status {
	case .Ok:
	case .Bad_Export:
		return {}, fmt.aprintf("service %s has no export %d", call.service, call.index, allocator = allocator), false
	case .Bad_Arguments:
		return {}, fmt.aprintf("service %s refused the arguments of %s", call.service, call.export, allocator = allocator), false
	case .Bad_Handle, .Load_Failed:
		return {}, fmt.aprintf("service %s refused %s with status %v", call.service, call.export, call_status, allocator = allocator), false
	}

	if call.function.error_record != 0 && answer.value < 0 {
		buffer := make([]u8, 512, context.temp_allocator)
		writer := sentence.Writer{buffer = buffer}
		sentence.export_error_text(&writer, call.file, call.index, call.service, &answer.error)
		return {}, strings.clone(sentence.written(&writer), allocator), false
	}

	return decode_remote_call_result(&call, answer, result_bytes, allocator)
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
