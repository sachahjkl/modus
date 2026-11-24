// Host bridge integration for read-only multi-line Lex steps (eval_step) and
// verified single-use execution of principal-approved assistant acts
// (src/md/features/agent_code_mode.md; src/md/features/assistant.md).
package host_agent_bridge

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import step_runner "internal:assistant/agent_step"
import contract "modus:contract/agent_bridge"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/wide_grants"

// bridge_ensure_step_session lazily allocates and initializes the persistent
// multi-line step session on bridge.
@(private = "file")
bridge_ensure_step_session :: proc(bridge: ^Agent_Bridge) -> ^step_runner.Step_Session {
	if bridge.step_session == nil {
		alloc := bridge.step_allocator.procedure != nil ? bridge.step_allocator : context.allocator
		bridge.step_session = new(step_runner.Step_Session, alloc)
		step_runner.session_init(bridge.step_session, grant_serial = bridge.policy.wide_grant_serial)
	}
	return bridge.step_session
}

// bridge_reset_step_bindings clears all persistent step variable bindings on a
// new request or reach change while preserving the audit log chain.
bridge_reset_step_bindings :: proc(bridge: ^Agent_Bridge) {
	if bridge == nil || bridge.step_session == nil {
		return
	}
	step_runner.session_reset_bindings(bridge.step_session)
}

@(private = "file")
Step_Bridge_Adapter :: struct {
	bridge:           ^Agent_Bridge,
	act_log_refused:  bool,
	last_err:         string,
	ctx:              runtime.Context,
}

@(private = "file")
step_adapter_now :: proc "contextless" (user_data: rawptr) -> u64 {
	adapter := (^Step_Bridge_Adapter)(user_data)
	context = adapter.ctx
	return bridge_now_ms(adapter.bridge)
}

@(private = "file")
step_adapter_call_export :: proc "contextless" (
	user_data: rawptr,
	service, export: string,
	args: []step_runner.Step_Arg,
	out: ^step_runner.Step_Call_Result,
) -> bool {
	adapter := (^Step_Bridge_Adapter)(user_data)
	context = adapter.ctx
	bridge := adapter.bridge

	if bridge.transport.eval_lex == nil {
		adapter.last_err = "eval_lex transport is not configured"
		return false
	}

	// Build canonical Lex single-call line: service.export(arg0, arg1, ...)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, service)
	strings.write_byte(&b, '.')
	strings.write_string(&b, export)
	strings.write_byte(&b, '(')
	for arg, idx in args {
		if idx > 0 {
			strings.write_string(&b, ", ")
		}
		switch arg.kind {
		case .Integer:
			fmt.sbprintf(&b, "%d", arg.integer)
		case .Boolean:
			strings.write_string(&b, arg.integer != 0 ? "true" : "false")
		case .Text:
			// Lex string literals have no escapes; refuse embedded quotes.
			if strings.index_byte(arg.text, '"') >= 0 {
				adapter.last_err = "string argument contains quote"
				return false
			}
			strings.write_byte(&b, '"')
			strings.write_string(&b, arg.text)
			strings.write_byte(&b, '"')
		case .Member:
			strings.write_string(&b, arg.text)
		}
	}
	strings.write_byte(&b, ')')
	call_line := strings.to_string(b)

	// Fail-closed: record the export call in bridge.act_log BEFORE executing it.
	digest := blake3.hash(transmute([]u8)call_line)
	detail_0 := byte_order.read_u64_little_endian(digest[:], 0)
	_, act_refusal := bridge_act_log_append(
		&bridge.act_log,
		bridge.policy.wide_grant_serial,
		bridge_now_ms(bridge),
		.Call_Made,
		0,
		detail_0,
		u64(len(call_line)),
	)
	if act_refusal != .None {
		adapter.act_log_refused = true
		adapter.last_err = "collector act log refused step call record"
		return false
	}

	res, eval_outcome, err_text := bridge.transport.eval_lex(bridge.transport.user_data, call_line, context.temp_allocator)
	if eval_outcome != .Succeeded {
		adapter.last_err = err_text != "" ? err_text : "remote eval_lex failed"
		return false
	}

	out.kind = res.value_kind
	switch res.value_kind {
	case .Integer:
		out.integer = res.integer_value
	case .Boolean:
		out.boolean = res.bool_value
	case .Text, .Enum_Member:
		out.text_count = copy(out.text[:], res.text_value)
	case .Table, .Record:
		tbl := out.table
		if tbl == nil {
			return false
		}
		tbl.is_record = res.value_kind == .Record
		tbl.name_count = u8(copy(tbl.name[:], res.record_name))
		cols := min(len(res.columns), step_runner.RESULT_COLUMN_CAPACITY)
		rows := min(len(res.rows), step_runner.RESULT_ROW_CAPACITY)
		tbl.column_count = cols
		tbl.row_count = rows
		tbl.total_rows = int(max(res.total_rows, i64(rows)))
		for c in 0 ..< cols {
			tbl.column_lens[c] = u8(copy(tbl.columns[c][:], res.columns[c]))
			tbl.column_kinds[c] = c < len(res.column_kinds) ? res.column_kinds[c] : .Text
			tbl.column_units[c] = c < len(res.column_units) ? res.column_units[c] : 0
		}
		for r in 0 ..< rows {
			row_cells := res.rows[r]
			has_row_ints := r < len(res.row_integers)
			for c in 0 ..< cols {
				cell := &tbl.cells[r * cols + c]
				if c < len(row_cells) {
					cell.text_count = u8(copy(cell.text[:], row_cells[c]))
				}
				if has_row_ints && c < len(res.row_integers[r]) && tbl.column_kinds[c] != .Text {
					cell.has_integer = true
					cell.integer = res.row_integers[r][c]
				} else if tbl.column_kinds[c] == .Integer && cell.text_count > 0 {
					if parsed, ok := strconv.parse_i64(string(cell.text[:cell.text_count])); ok {
						cell.has_integer = true
						cell.integer = parsed
					}
				}
			}
		}
		out.has_table = true
	case .None:
	}
	return true
}

// handle_eval_step_json runs a read-only multi-line Lex step (1..16 lines)
// with persistent per-request variables and fail-closed BLAKE3 act records.
handle_eval_step_json :: proc(
	bridge: ^Agent_Bridge,
	id_value: json.Value,
	has_id: bool,
	params: json.Object,
	now_ms: u64,
	allocator := context.temp_allocator,
) -> string {
	raw_lines, has_lines := params["lines"]
	if !has_lines {
		return json_error_response(id_value, has_id, .Invalid_Params, .Ended, contract.bridge_refusal_outcome(.Invalid_Field), .Invalid_Field, "eval_step requires array parameter lines", allocator)
	}
	arr, is_arr := raw_lines.(json.Array)
	if !is_arr || len(arr) == 0 {
		return json_error_response(id_value, has_id, .Invalid_Params, .Ended, contract.bridge_refusal_outcome(.Invalid_Field), .Invalid_Field, "eval_step lines must be a non-empty array of strings", allocator)
	}
	if len(arr) > contract.AGENT_STEP_LINE_CAPACITY {
		return json_error_response(id_value, has_id, .Invalid_Params, .Ended, contract.bridge_refusal_outcome(.Payload_Too_Large), .Payload_Too_Large, "eval_step exceeds maximum of 16 lines", allocator)
	}
	lines: [contract.AGENT_STEP_LINE_CAPACITY]string
	for item, idx in arr {
		s, is_str := item.(json.String)
		if !is_str {
			return json_error_response(id_value, has_id, .Invalid_Params, .Ended, contract.bridge_refusal_outcome(.Invalid_Field), .Invalid_Field, "each eval_step line must be a string", allocator)
		}
		lines[idx] = string(s)
	}

	auth_req := contract.Bridge_Authorization_Request {
		command = .Eval_Step,
		now_ms  = now_ms,
	}
	decision := contract.bridge_authorize_command(&bridge.policy, &auth_req)
	if decision.state != .Ended || decision.outcome != .Succeeded {
		return json_decision_error(id_value, has_id, decision, allocator)
	}

	// Fail-closed: record the step start in bridge.act_log BEFORE executing any line.
	step_hash_builder := strings.builder_make(context.temp_allocator)
	for line in lines[:len(arr)] {
		strings.write_string(&step_hash_builder, line)
		strings.write_byte(&step_hash_builder, '\n')
	}
	step_digest := blake3.hash(transmute([]u8)strings.to_string(step_hash_builder))
	step_detail_0 := byte_order.read_u64_little_endian(step_digest[:], 0)
	_, step_act_refusal := bridge_act_log_append(
		&bridge.act_log,
		bridge.policy.wide_grant_serial,
		now_ms,
		.Call_Made,
		0,
		step_detail_0,
		u64(len(arr)),
	)
	if step_act_refusal != .None {
		return json_error_response(id_value, has_id, .Refused, .Ended, contract.bridge_refusal_outcome(.Act_Log_Required), .Act_Log_Required, "collector act log refused step record", allocator)
	}

	session := bridge_ensure_step_session(bridge)
	session.grant_serial = bridge.policy.wide_grant_serial
	// Keep internal session act log synchronized with room for this step (the
	// bridge's canonical act_log also records every step and call).
	if session.act_log_count + 1 + len(arr) + step_runner.STEP_CALL_CAPACITY > step_runner.ACT_LOG_CAPACITY {
		session.act_log_count = 0
		session.last_act_hash = wide_grants.GENESIS_PREVIOUS_HASH
	}

	adapter := Step_Bridge_Adapter {
		bridge = bridge,
		ctx    = context,
	}
	transport := step_runner.Step_Transport {
		user_data   = rawptr(&adapter),
		call_export = step_adapter_call_export,
		now_ms      = step_adapter_now,
	}
	outcome := step_runner.step_run(session, lines[:len(arr)], transport)
	session.transport = {}
	if !outcome.ok {
		if adapter.act_log_refused || outcome.refusal == .Act_Log_Full {
			return json_error_response(id_value, has_id, .Refused, .Ended, contract.bridge_refusal_outcome(.Act_Log_Required), .Act_Log_Required, "collector act log full during step", allocator)
		}
		if outcome.refusal == .No_Grant {
			cmd := string(outcome.refused_command[:outcome.refused_command_len])
			// Read-only agent console refuses unauthorized calls with No_Grant and zero dialog.
			return json_error_response(id_value, has_id, .Refused, .Ended, .Grant_Or_Right_Missing, .Permission_Denied, fmt.tprintf("No_Grant at line %d: %s is outside read-only reach", outcome.failed_line, cmd), allocator)
		}
		refusal_code := contract.Bridge_Refusal.Invalid_Text
		switch outcome.refusal {
		case .Call_Limit_Exceeded, .Time_Bound_Exceeded:
			refusal_code = .Payload_Too_Large
		case .Transport_Failed:
			return json_error_response(id_value, has_id, .Transport_Error, .Ended, .Callee_Unavailable, .None, adapter.last_err != "" ? adapter.last_err : "step transport failed", allocator)
		case .None, .Empty_Step, .Too_Many_Lines, .Invalid_Line, .Line_Too_Long, .Pipe_Refused, .Parse_Refused, .No_Grant, .Act_Log_Full, .Evaluation_Refused, .Variables_Full, .Tables_Full, .Strings_Full, .Invalid_Argument:
		}
		return json_error_response(
			id_value,
			has_id,
			.Refused,
			.Ended,
			contract.bridge_refusal_outcome(refusal_code),
			refusal_code,
			fmt.tprintf("step refused at line %d: %s", outcome.failed_line, step_runner.STEP_REFUSAL_NAMES[outcome.refusal]),
			allocator,
		)
	}

	return format_eval_step_json(bridge, id_value, has_id, session, &outcome, allocator)
}

@(private = "file")
format_eval_step_json :: proc(
	bridge: ^Agent_Bridge,
	id_value: json.Value,
	has_id: bool,
	session: ^step_runner.Step_Session,
	outcome: ^step_runner.Step_Outcome,
	allocator: mem.Allocator,
) -> string {
	_ = bridge
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	json_write_id(&builder, id_value, has_id)
	strings.write_string(&builder, `,"result":{"state":"Ended","outcome":"Succeeded","step_lines":`)
	fmt.sbprintf(&builder, `%d,"calls_made":%d,"lines":[`, outcome.line_count, outcome.calls_made)
	for i in 0 ..< outcome.line_count {
		lo := &outcome.lines[i]
		if i > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_string(&builder, `{"line":`)
		fmt.sbprintf(&builder, `%d,"assigned":%s,"name":`, lo.line_index, lo.assigned ? "true" : "false")
		json_write_escaped_string(&builder, string(lo.assigned_buf[:lo.assigned_len]))
		strings.write_string(&builder, `,"summary":`)
		json_write_escaped_string(&builder, string(lo.summary[:lo.summary_len]))
		strings.write_byte(&builder, '}')
	}
	strings.write_byte(&builder, ']')

	// Expose the final line's typed value/table at top-level result keys so
	// assistant renders tables identically to single-call eval_lex.
	if outcome.line_count > 0 {
		last := &outcome.lines[outcome.line_count - 1]
		if last.table_index >= 0 {
			if tbl := step_runner.session_table(session, last.table_index); tbl != nil {
				kind_str := tbl.is_record ? contract.lex_value_kind_name(.Record) : contract.lex_value_kind_name(.Table)
				strings.write_string(&builder, `,"value_kind":`)
				json_write_escaped_string(&builder, kind_str)
				strings.write_string(&builder, `,"record_name":`)
				json_write_escaped_string(&builder, step_runner.table_name(tbl))
				strings.write_string(&builder, `,"columns":[`)
				for c in 0 ..< tbl.column_count {
					if c > 0 {
						strings.write_byte(&builder, ',')
					}
					json_write_escaped_string(&builder, step_runner.table_column_name(tbl, c))
				}
				strings.write_string(&builder, `],"column_kinds":[`)
				for c in 0 ..< tbl.column_count {
					if c > 0 {
						strings.write_byte(&builder, ',')
					}
					k := tbl.column_kinds[c]
					if k == .None {
						k = .Text
					}
					json_write_escaped_string(&builder, contract.lex_column_kind_name(k))
				}
				strings.write_string(&builder, `],"column_units":[`)
				for c in 0 ..< tbl.column_count {
					if c > 0 {
						strings.write_byte(&builder, ',')
					}
					fmt.sbprintf(&builder, "%d", tbl.column_units[c])
				}
				strings.write_string(&builder, `],"rows":[`)
				for r in 0 ..< tbl.row_count {
					if r > 0 {
						strings.write_byte(&builder, ',')
					}
					strings.write_byte(&builder, '[')
					for c in 0 ..< tbl.column_count {
						if c > 0 {
							strings.write_byte(&builder, ',')
						}
						json_write_escaped_string(&builder, step_runner.table_cell_text(tbl, r, c))
					}
					strings.write_byte(&builder, ']')
				}
				strings.write_string(&builder, `],"row_integers":[`)
				for r in 0 ..< tbl.row_count {
					if r > 0 {
						strings.write_byte(&builder, ',')
					}
					strings.write_byte(&builder, '[')
					for c in 0 ..< tbl.column_count {
						if c > 0 {
							strings.write_byte(&builder, ',')
						}
						fmt.sbprintf(&builder, "%d", tbl.cells[r * tbl.column_count + c].integer)
					}
					strings.write_byte(&builder, ']')
				}
				fmt.sbprintf(&builder, `],"total_rows":%d`, tbl.total_rows)
			}
		} else {
			switch last.kind {
			case .Integer:
				fmt.sbprintf(&builder, `,"value_kind":"integer","value":%d`, last.integer)
			case .Boolean:
				fmt.sbprintf(&builder, `,"value_kind":"boolean","value":%s`, last.integer != 0 ? "true" : "false")
			case .Text, .List:
				strings.write_string(&builder, `,"value_kind":"text","value":`)
				json_write_escaped_string(&builder, string(last.summary[:last.summary_len]))
			case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .Hash, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value, .Tree_Ref:
				strings.write_string(&builder, `,"value_kind":"none"`)
			}
		}
	}
	strings.write_string(&builder, "}}")
	return strings.to_string(builder)
}

// bridge_act_already_consumed reports whether a principal-approved act number
// has already been executed on bridge (single-use enforcement).
@(private = "file")
bridge_act_already_consumed :: proc(bridge: ^Agent_Bridge, act_number: u64) -> bool {
	for used in bridge.consumed_approved_acts {
		if used == act_number {
			return true
		}
	}
	return false
}

// bridge_run_approved_act executes a single-call Lex act that the principal
// explicitly allowed on the trusted display (Allowed_By_Principal read from
// the assistant window), under an active wide grant with a fail-closed BLAKE3
// Act_Record and single-use consumption.
//
// Sensitive actions for which wide_grants.act_requires_principal_proof is true
// (plans.apply, plans.rollback, unlock, trusted display dialogs, assistant.*,
// disk grants, principals, debugger/replace) are ALWAYS refused hard.
bridge_run_approved_act :: proc(
	bridge: ^Agent_Bridge,
	binding: contract.Approved_Act_Binding,
	lex_line: string,
	allocator := context.temp_allocator,
) -> (
	result: Lex_Eval_Result,
	decision: contract.Bridge_Authorization_Decision,
	act_record: wide_grants.Act_Record,
	err_text: string,
) {
	if bridge == nil {
		return {}, contract.bridge_refused(.Invalid_Field), {}, "bridge is not initialized"
	}
	now_ms := bridge_now_ms(bridge)
	bridge.policy.collector_available = bridge_act_log_has_room(&bridge.act_log)

	checked := binding
	checked.already_used = checked.already_used || bridge_act_already_consumed(bridge, binding.act_number)
	decision = contract.bridge_authorize_approved_act(&bridge.policy, &checked, transmute([]u8)lex_line, now_ms)
	if decision.state != .Ended || decision.outcome != .Succeeded {
		return {}, decision, {}, fmt.tprintf("approved act refused: %s", contract.bridge_refusal_name(decision.refusal))
	}

	if bridge.transport.eval_lex == nil {
		return {}, {state = .Ended, outcome = .Callee_Unavailable, refusal = .None}, {}, "eval_lex transport is not configured"
	}

	// Fail-closed: append BLAKE3 Act_Record bound to (grant_serial, act_number, line_hash)
	// BEFORE running the transport, and consume the act number before execution.
	line_digest := blake3.hash(transmute([]u8)lex_line)
	line_head := byte_order.read_u64_little_endian(line_digest[:], 0)
	act_rec, act_refusal := bridge_act_log_append(
		&bridge.act_log,
		bridge.policy.wide_grant_serial,
		now_ms,
		decision.required_act_kind,
		0,
		binding.act_number,
		line_head,
	)
	if act_refusal != .None {
		return {}, contract.bridge_refused(.Act_Log_Required), {}, "collector act log refused approved act record"
	}
	append(&bridge.consumed_approved_acts, binding.act_number)

	eval_res, eval_outcome, eval_err := bridge.transport.eval_lex(bridge.transport.user_data, lex_line, allocator)
	if eval_outcome != .Succeeded {
		return {}, {state = .Ended, outcome = eval_outcome, refusal = .None}, act_rec, eval_err != "" ? eval_err : "remote eval_lex failed"
	}
	return eval_res, decision, act_rec, ""
}
