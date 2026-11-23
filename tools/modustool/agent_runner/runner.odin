package agent_runner

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "modustool:agent_bridge"
import "modustool:machine"
import bridge_contract "modus:contract/agent_bridge"
import assistant_contract "modus:contract/assistant"
import "modus:contract/cut_mark"
import "modus:contract/errors"
import "modus:contract/text_encoding"

// The service of the window, as remote names it.
WINDOW_SERVICE :: "assistant"

// The requests that the conversation of the model keeps, with their
// replies and outcomes: a run of the runner has no end, and the words that
// the model reads have a bound.
CONVERSATION_REQUEST_CAPACITY :: 16

// The bounds of what the model reads from one step of results
// (src/md/features/agent_code_mode.md, "The bounds of one step"): at most
// 64 rows and 24 columns per act, and 16 KiB across the whole step.
MODEL_RESULT_ROW_CAPACITY :: 64
MODEL_RESULT_COLUMN_CAPACITY :: assistant_contract.ACT_TABLE_COLUMN_CAPACITY
MODEL_STEP_RESULT_BYTES :: 16 * 1024

// Closed set of loop end causes, shared with the window contract.
Agent_Loop_End :: assistant_contract.Agent_Loop_End

// How the runner speaks to the window of the assistant: through remote on
// a live machine, or through an in-memory conversation in a host test.
Window_Port :: struct {
	user_data:      rawptr,
	request_serial: proc(user_data: rawptr) -> (serial: i64, problem: string, grant_ended: bool),
	request_text:   proc(user_data: rawptr, serial: i64) -> (text: string, problem: string, grant_ended: bool),
	stop_requested: proc(user_data: rawptr, serial: i64) -> (stopped: bool, problem: string, grant_ended: bool),
	reply:          proc(user_data: rawptr, serial: i64, text: string, acts: int) -> (problem: string, grant_ended: bool),
	reply_refused:  proc(user_data: rawptr, serial: i64, record: errors.Error_Record) -> (problem: string, grant_ended: bool),
	act:            proc(user_data: rawptr, serial: i64, kind: assistant_contract.Act_Kind, line, service, export: string) -> (number: i64, problem: string, grant_ended: bool),
	act_result:     proc(user_data: rawptr, number: i64, state: assistant_contract.Act_State, text: string) -> (problem: string, grant_ended: bool),
	act_table:      proc(user_data: rawptr, number: i64, table: Act_Result_Table) -> (problem: string, grant_ended: bool),
	loop_end:       proc(user_data: rawptr, serial: i64, cause: Agent_Loop_End) -> (problem: string, grant_ended: bool),
}

// The parties of the runner: the calls to the window through remote (or a
// test port), the bridge that runs each act, and the model. The
// conversation is the words that the model reads at its next reply; its
// strings belong to the allocator of the runner.
Runner :: struct {
	client:              ^machine.Call_Client,
	window:              Window_Port,
	bridge:              ^agent_bridge.Agent_Bridge,
	model:               Model,
	conversation:        [dynamic]Turn,
	next_bridge_request: u64,
	next_call:           u64, // The number of the last call id of an act.
}

// turn_free frees the strings of one turn of the conversation.
@(private = "file")
turn_free :: proc(turn: Turn) {
	delete(turn.text)
	delete(turn.call_id)
	for call in turn.calls {
		delete(call.id)
		delete(call.line)
	}
	delete(turn.calls)
}

// conversation_bound drops the oldest request with all its turns while the
// conversation keeps more than CONVERSATION_REQUEST_CAPACITY requests. A
// request leaves whole, so no outcome stays without the call that it
// answers.
conversation_bound :: proc(runner: ^Runner) {
	for {
		requests, second := 0, -1
		for turn, index in runner.conversation {
			if turn.role == .Principal {
				requests += 1
				if requests == 2 {
					second = index
				}
			}
		}
		if requests <= CONVERSATION_REQUEST_CAPACITY || second < 0 {
			return
		}
		for turn in runner.conversation[:second] {
			turn_free(turn)
		}
		remove_range(&runner.conversation, 0, second)
	}
}

// conversation_close frees the conversation of a runner.
conversation_close :: proc(runner: ^Runner) {
	for turn in runner.conversation {
		turn_free(turn)
	}
	delete(runner.conversation)
}

// exchange_keep keeps the reply of the model and the outcome of each of
// its acts in the conversation: a call for each act, and a turn of the
// role tool for each outcome. An act with no outcome, as when a step ended
// early, says so: each call has its answer.
@(private = "file")
exchange_keep :: proc(runner: ^Runner, reply: Model_Reply, outcomes: []string) {
	reply := reply
	calls := make([]Turn_Call, reply.act_count)
	for act, index in reply.acts[:reply.act_count] {
		runner.next_call += 1
		calls[index] = {id = fmt.aprintf("call_%d", runner.next_call), kind = act.kind, line = strings.clone(act.line)}
	}
	append(&runner.conversation, Turn{role = .Model, text = strings.clone(reply.text), calls = calls})
	for call, index in calls {
		outcome := index < len(outcomes) && outcomes[index] != "" ? outcomes[index] : "no outcome: the step ended before the act ran"
		append(&runner.conversation, Turn{role = .Outcome, text = strings.clone(outcome), call_id = strings.clone(call.id)})
	}
}

Model_Answer_Kind :: enum {
	Answered, // The reply passed the border.
	Reply_Refused, // The reply failed the border: record holds why.
	Model_Failed, // The model gave no reply: record is No_Answer.
}

// model_answer asks the model for its reply to the conversation and reads
// it at the border: Answered with the reply; Model_Failed, with the record
// No_Answer and the problem, when the model gives no reply, as when its
// endpoint stalls past its deadline; Reply_Refused with the record of the
// border.
model_answer :: proc(model: Model, conversation: []Turn) -> (reply: Model_Reply, kind: Model_Answer_Kind, record: errors.Error_Record, problem: string) {
	raw, model_problem := model.reply(model.user_data, conversation, context.temp_allocator)
	if model_problem != "" {
		return {}, .Model_Failed, errors.error_make(.No_Answer), model_problem
	}
	decoded, decode_record, decoded_ok := model_reply_decode(raw)
	if !decoded_ok {
		return {}, .Reply_Refused, decode_record, ""
	}
	return decoded, .Answered, {}, ""
}

// The words of an act that the bridge stopped for the principal and whose
// line names no export that the act dialog can show.
ACT_WITHOUT_NAMES_WORDS :: "the act names no export that the trusted display can show"

// act_outcome_for_display gives the outcome that the window takes for an
// act. An act that waits for the principal needs the names of its one call
// for the act dialog; with no names (a name past 31 bytes, an upper case
// letter, a leading _), the act is refused, as the trusted display could
// never show it, and the window never refuses the outcome.
act_outcome_for_display :: proc(outcome: Act_Report, service: string) -> Act_Report {
	if outcome.state != .Awaiting_Principal || service != "" {
		return outcome
	}
	return {number = outcome.number, state = .Refused, text = ACT_WITHOUT_NAMES_WORDS, model_text = ACT_WITHOUT_NAMES_WORDS}
}

// act_names gives the service and the export of the one call of a line,
// with the parser of the bridge, or two empty texts for a line that is no
// single call: the window and the trusted display read the names as typed
// values, never from the line.
act_names :: proc(line: string) -> (service, export: string) {
	service_bytes, export_bytes, ok := bridge_contract.lex_line_single_call(transmute([]u8)line)
	if !ok || !assistant_contract.act_name_valid(string(service_bytes)) || !assistant_contract.act_name_valid(string(export_bytes)) {
		return "", ""
	}
	return string(service_bytes), string(export_bytes)
}

// acts_equal reports whether two steps propose the exact same sequence of
// acts (same count, same kind and line at every index).
acts_equal :: proc(first, second: []Model_Act) -> bool {
	if len(first) != len(second) {
		return false
	}
	for index in 0 ..< len(first) {
		if first[index].kind != second[index].kind || first[index].line != second[index].line {
			return false
		}
	}
	return true
}

// step_repeats says if a step repeats the step before: the same acts, in
// order, with the same outcomes. The same acts whose results changed are
// no repeat: the agent can wait for a state that moves.
step_repeats :: proc(acts, previous_acts: []Model_Act, outcomes, previous_outcomes: []string) -> bool {
	if len(acts) == 0 || !acts_equal(acts, previous_acts) || len(outcomes) != len(previous_outcomes) {
		return false
	}
	for outcome, index in outcomes {
		if outcome != previous_outcomes[index] {
			return false
		}
	}
	return true
}

Step_Report :: struct {
	step:      int,
	text:      string,
	acts:      [assistant_contract.MODEL_ACT_CAPACITY]Act_Report,
	act_count: int,
}

Turn_Report :: struct {
	has_request:   bool, // False when no request waited.
	end:           Agent_Loop_End, // Valid when has_request is true (or on poll failure).
	serial:        i64,
	steps:         [assistant_contract.AGENT_LOOP_STEP_CAPACITY]Step_Report,
	step_count:    int,
	total_acts:    int,
	record:        errors.Error_Record, // Model_Failed: the error record sent to reply_refused.
	reply_refused: bool, // Model_Failed: true when the model reply failed the border.
	problem:       string,
}

Act_Report :: struct {
	number:        i64,
	state:         assistant_contract.Act_State,
	text:          string, // Bounded to REPLY_TEXT_BYTES for the window.
	model_text:    string, // Bounded to the step budget for the model tool turn.
	table:         Act_Result_Table, // Done: the typed result, when the bridge gave a whole table or record within the bounds.
	table_problem: string, // The refusal of act_table by the window: the act shows its words only.
	grant_ended:   bool, // True when the bridge refused because the grant or client key ended.
}

// The typed result of an act, within the bounds of the window
// (src/md/features/assistant.md, "The result of an act"): the first rows,
// each text cut with the cut mark past its bound.
Act_Result_Table :: struct {
	present:    bool,
	shape:      assistant_contract.Act_Table_Shape,
	name:       string,
	columns:    []string,
	kinds:      []bridge_contract.Lex_Column_Kind, // How each column is written and aligned.
	units:      []i64, // The unit word of each column.
	cells:      []string, // Row after row: len(columns) cells in each row; empty in a number column.
	integers:   []i64, // Row after row: the value of each cell of a number column; 0 in a text column.
	row_count:  int,
	total_rows: i64,
}

// remote_window_call calls an export of the window through remote and
// reports whether a failure means the grant or client key ended.
@(private = "file")
remote_window_call :: proc(client: ^machine.Call_Client, export: string, arguments: []machine.Call_Argument) -> (result: machine.Call_Result, problem: string, grant_ended: bool) {
	result = machine.call_run_values(client, WINDOW_SERVICE, export, arguments)
	if result.outcome != .Result {
		joined := strings.join(result.lines[:], "; ", context.temp_allocator)
		grant_ended = result.error.kind == i64(errors.Kind.No_Grant) ||
			result.transport_outcome == .Client_Refused ||
			result.transport_outcome == .Key_Refused
		return result, fmt.tprintf("assistant.%s gave %v: %s", export, result.outcome, joined), grant_ended
	}
	return result, "", false
}

// remote_window_port builds a Window_Port backed by remote calls on client.
remote_window_port :: proc(client: ^machine.Call_Client) -> Window_Port {
	return {
		user_data      = client,
		request_serial = remote_request_serial,
		request_text   = remote_request_text,
		stop_requested = remote_stop_requested,
		reply          = remote_reply,
		reply_refused  = remote_reply_refused,
		act            = remote_act,
		act_result     = remote_act_result,
		act_table      = remote_act_table,
		loop_end       = remote_loop_end,
	}
}

@(private = "file")
remote_request_serial :: proc(user_data: rawptr) -> (serial: i64, problem: string, grant_ended: bool) {
	result, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "request_serial", nil)
	return result.value, call_problem, call_grant
}

@(private = "file")
remote_request_text :: proc(user_data: rawptr, serial: i64) -> (text: string, problem: string, grant_ended: bool) {
	arguments := [1]machine.Call_Argument{{integer = serial}}
	result, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "request_text", arguments[:])
	return result.text, call_problem, call_grant
}

@(private = "file")
remote_stop_requested :: proc(user_data: rawptr, serial: i64) -> (stopped: bool, problem: string, grant_ended: bool) {
	arguments := [1]machine.Call_Argument{{integer = serial}}
	result, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "stop_requested", arguments[:])
	return result.value != 0, call_problem, call_grant
}

@(private = "file")
remote_reply :: proc(user_data: rawptr, serial: i64, text: string, acts: int) -> (problem: string, grant_ended: bool) {
	arguments := [3]machine.Call_Argument{{integer = serial}, {is_text = true, text = text}, {integer = i64(acts)}}
	_, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "reply", arguments[:])
	return call_problem, call_grant
}

@(private = "file")
remote_reply_refused :: proc(user_data: rawptr, serial: i64, record: errors.Error_Record) -> (problem: string, grant_ended: bool) {
	arguments := [6]machine.Call_Argument{{integer = serial}, {integer = record.kind}, {integer = record.unit}, {integer = record.argument}, {integer = record.value}, {integer = record.limit}}
	_, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "reply_refused", arguments[:])
	return call_problem, call_grant
}

@(private = "file")
remote_act :: proc(user_data: rawptr, serial: i64, kind: assistant_contract.Act_Kind, line, service, export: string) -> (number: i64, problem: string, grant_ended: bool) {
	arguments := [5]machine.Call_Argument{{integer = serial}, {integer = i64(kind)}, {is_text = true, text = line}, {is_text = true, text = service}, {is_text = true, text = export}}
	result, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "act", arguments[:])
	return result.value, call_problem, call_grant
}

@(private = "file")
remote_act_result :: proc(user_data: rawptr, number: i64, state: assistant_contract.Act_State, text: string) -> (problem: string, grant_ended: bool) {
	arguments := [3]machine.Call_Argument{{integer = number}, {integer = i64(state)}, {is_text = true, text = text}}
	_, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "act_result", arguments[:])
	return call_problem, call_grant
}

@(private = "file")
remote_act_table :: proc(user_data: rawptr, number: i64, table: Act_Result_Table) -> (problem: string, grant_ended: bool) {
	client := (^machine.Call_Client)(user_data)
	col_count := len(table.columns)
	column_rows := make([][]machine.Call_Argument, col_count, context.temp_allocator)
	for column, index in table.columns {
		column_rows[index] = make([]machine.Call_Argument, 3, context.temp_allocator)
		column_rows[index][0] = {is_text = true, text = column}
		column_rows[index][1] = {integer = i64(table.kinds[index])}
		column_rows[index][2] = {integer = table.units[index]}
	}
	cell_rows := make([][]machine.Call_Argument, len(table.cells), context.temp_allocator)
	for cell, index in table.cells {
		cell_rows[index] = make([]machine.Call_Argument, 2, context.temp_allocator)
		cell_rows[index][0] = {is_text = true, text = cell}
		cell_rows[index][1] = {integer = table.integers[index]}
	}
	// Keep each remote call within the 64 KiB call region: send whole rows
	// up to ACT_TABLE_CELL_BATCH_CAPACITY cells in act_table, then stream
	// remaining rows through act_table_rows.
	rows_per_batch := col_count > 0 ? max(assistant_contract.ACT_TABLE_CELL_BATCH_CAPACITY / col_count, 1) : 1
	first_rows := min(table.row_count, rows_per_batch)
	first_cells := first_rows * col_count
	arguments := [6]machine.Call_Argument{{integer = number}, {integer = i64(table.shape)}, {is_text = true, text = table.name}, {integer = table.total_rows}, {is_table = true, rows = column_rows}, {is_table = true, rows = cell_rows[:first_cells]}}
	_, call_problem, call_grant := remote_window_call(client, "act_table", arguments[:])
	if call_problem != "" {
		return call_problem, call_grant
	}
	for sent_rows := first_rows; sent_rows < table.row_count; {
		batch_rows := min(table.row_count - sent_rows, rows_per_batch)
		start_cell := sent_rows * col_count
		end_cell := (sent_rows + batch_rows) * col_count
		row_args := [2]machine.Call_Argument{{integer = number}, {is_table = true, rows = cell_rows[start_cell:end_cell]}}
		_, batch_problem, batch_grant := remote_window_call(client, "act_table_rows", row_args[:])
		if batch_problem != "" {
			return batch_problem, batch_grant
		}
		sent_rows += batch_rows
	}
	return "", false
}

@(private = "file")
remote_loop_end :: proc(user_data: rawptr, serial: i64, cause: Agent_Loop_End) -> (problem: string, grant_ended: bool) {
	arguments := [2]machine.Call_Argument{{integer = serial}, {integer = i64(cause)}}
	_, call_problem, call_grant := remote_window_call((^machine.Call_Client)(user_data), "loop_end", arguments[:])
	return call_problem, call_grant
}

@(private = "file")
runner_window :: proc(runner: ^Runner) -> Window_Port {
	if runner.window.request_serial != nil {
		return runner.window
	}
	return remote_window_port(runner.client)
}

@(private = "file")
window_failure_end :: proc(report: ^Turn_Report, problem: string, grant_ended: bool) {
	report.end = grant_ended ? .Grant_Ended : .Window_Failed
	report.problem = problem
}

@(private = "file")
finish_with_loop_end :: proc(window: Window_Port, report: ^Turn_Report, cause: Agent_Loop_End) {
	problem, grant_ended := window.loop_end(window.user_data, report.serial, cause)
	if problem != "" {
		window_failure_end(report, problem, grant_ended)
		return
	}
	report.end = cause
}

// runner_turn answers the oldest request of the window that no runner
// took, if one waits, running an agent loop of up to
// AGENT_LOOP_STEP_CAPACITY (16) steps: each step asks the model, runs its
// acts through the bridge, shows their outcomes and typed tables in the
// window, and feeds bounded tool results back to the model until a final
// reply (0 acts), 16 steps, a repeated step, a stop by the principal, a
// model/window error, or the end of the grant.
runner_turn :: proc(runner: ^Runner) -> (report: Turn_Report) {
	window := runner_window(runner)
	serial, problem, grant_ended := window.request_serial(window.user_data)
	if problem != "" {
		window_failure_end(&report, problem, grant_ended)
		return
	}
	if serial == 0 {
		return
	}
	report.has_request = true
	report.serial = serial
	request_text: string
	if request_text, problem, grant_ended = window.request_text(window.user_data, serial); problem != "" {
		window_failure_end(&report, problem, grant_ended)
		return
	}
	append(&runner.conversation, Turn{role = .Principal, text = strings.clone(request_text)})
	conversation_bound(runner)

	previous_acts: [assistant_contract.MODEL_ACT_CAPACITY]Model_Act
	previous_outcomes: [assistant_contract.MODEL_ACT_CAPACITY]string
	previous_act_count := 0

	for step := 1; step <= assistant_contract.AGENT_LOOP_STEP_CAPACITY; step += 1 {
		stopped: bool
		if stopped, problem, grant_ended = window.stop_requested(window.user_data, serial); problem != "" {
			window_failure_end(&report, problem, grant_ended)
			return
		}
		if stopped {
			finish_with_loop_end(window, &report, .Stopped_By_Principal)
			return
		}

		reply, answer_kind, record, model_problem := model_answer(runner.model, runner.conversation[:])
		switch answer_kind {
		case .Model_Failed, .Reply_Refused:
			report.end = .Model_Failed
			report.record = record
			report.problem = model_problem
			report.reply_refused = answer_kind == .Reply_Refused
			if refused_problem, refused_grant := window.reply_refused(window.user_data, serial, record); refused_problem != "" {
				window_failure_end(&report, refused_problem, refused_grant)
			}
			return
		case .Answered:
		}

		// Re-check stop after waiting for the model, before showing or running acts.
		if stopped, problem, grant_ended = window.stop_requested(window.user_data, serial); problem != "" {
			window_failure_end(&report, problem, grant_ended)
			return
		}
		if stopped {
			finish_with_loop_end(window, &report, .Stopped_By_Principal)
			return
		}

		if problem, grant_ended = window.reply(window.user_data, serial, reply.text, reply.act_count); problem != "" {
			window_failure_end(&report, problem, grant_ended)
			return
		}

		// Final answer (0 acts): the window already marked the request ended.
		if reply.act_count == 0 {
			report.steps[report.step_count] = {step = step, text = reply.text}
			report.step_count += 1
			exchange_keep(runner, reply, nil)
			report.end = .Final_Reply
			return
		}

		step_report := Step_Report{step = step, text = reply.text}
		outcomes: [assistant_contract.MODEL_ACT_CAPACITY]string
		remaining_bytes := MODEL_STEP_RESULT_BYTES
		step_window_failed := false
		step_grant_ended := false
		step_stopped := false

		for act, index in reply.acts[:reply.act_count] {
			if index > 0 {
				if stopped, problem, grant_ended = window.stop_requested(window.user_data, serial); problem != "" {
					step_window_failed = !grant_ended
					step_grant_ended = grant_ended
					report.problem = problem
					break
				}
				if stopped {
					step_stopped = true
					break
				}
			}

			service, export := act_names(act.line)
			act_number: i64
			if act_number, problem, grant_ended = window.act(window.user_data, serial, act.kind, act.line, service, export); problem != "" {
				step_window_failed = !grant_ended
				step_grant_ended = grant_ended
				report.problem = problem
				break
			}

			acts_left := reply.act_count - index
			act_budget := max(remaining_bytes / acts_left, 0)
			outcome := act_outcome_for_display(act_run(runner, act, act_budget), service)
			outcome.number = act_number

			if problem, grant_ended = window.act_result(window.user_data, outcome.number, outcome.state, outcome.text); problem != "" {
				step_window_failed = !grant_ended
				step_grant_ended = grant_ended
				report.problem = problem
				break
			}

			// A table that the window refuses is no failure of the step: the
			// act keeps its words, and the report says why the table is missing.
			if outcome.state == .Done && outcome.table.present {
				outcome.table_problem, _ = window.act_table(window.user_data, outcome.number, outcome.table)
			}

			tool_body := outcome.model_text != "" ? outcome.model_text : outcome.text
			tool_line := fmt.tprintf("%v: %s", outcome.state, tool_body)
			if len(tool_line) > remaining_bytes {
				tool_line = text_cut_bound(tool_line, remaining_bytes)
			}
			remaining_bytes = max(remaining_bytes - len(tool_line), 0)
			outcomes[index] = tool_line

			step_report.acts[step_report.act_count] = outcome
			step_report.act_count += 1
			report.total_acts += 1

			if outcome.grant_ended {
				step_grant_ended = true
				report.problem = outcome.text
				break
			}
		}

		report.steps[report.step_count] = step_report
		report.step_count += 1
		exchange_keep(runner, reply, outcomes[:])

		if step_grant_ended {
			// Best-effort notice to the window; if the window also lost grant,
			// the cause stays Grant_Ended.
			_, _ = window.loop_end(window.user_data, serial, .Grant_Ended)
			report.end = .Grant_Ended
			return
		}
		if step_window_failed {
			report.end = .Window_Failed
			return
		}
		if step_stopped {
			finish_with_loop_end(window, &report, .Stopped_By_Principal)
			return
		}

		// The acts of a step are read-only: a repeat is known only from its
		// results, so its acts ran, and the loop ends after them.
		if step > 1 && step_repeats(reply.acts[:reply.act_count], previous_acts[:previous_act_count], outcomes[:reply.act_count], previous_outcomes[:previous_act_count]) {
			finish_with_loop_end(window, &report, .Repeated_Step)
			return
		}
		previous_acts = reply.acts
		previous_outcomes = outcomes
		previous_act_count = reply.act_count
	}

	finish_with_loop_end(window, &report, .Step_Limit)
	return
}

// act_run gives one act to the bridge, as one JSON-RPC line, so it passes
// each check of the bridge as any agent: the classification of the line,
// the read-only list, the act record. The answer becomes a state, words
// for the window, and bounded tool text for the model.
act_run :: proc(runner: ^Runner, act: Model_Act, model_byte_budget := MODEL_STEP_RESULT_BYTES) -> (report: Act_Report) {
	runner.next_bridge_request += 1
	request := strings.builder_make(context.temp_allocator)
	// The braces of JSON are no format of fmt: the request is written in
	// parts.
	strings.write_string(&request, `{"jsonrpc":"2.0","id":`)
	strings.write_u64(&request, runner.next_bridge_request)
	strings.write_string(&request, `,"method":"`)
	strings.write_string(&request, assistant_contract.ACT_KIND_NAMES[act.kind])
	strings.write_string(&request, `","params":{"line":`)
	json_string_write(&request, act.line)
	strings.write_string(&request, "}}")
	answer := agent_bridge.bridge_handle_json_line(runner.bridge, strings.to_string(request), context.temp_allocator)
	return bridge_answer_read(answer, model_byte_budget)
}

@(private = "file")
bridge_refusal_ends_grant :: proc(refusal: string) -> bool {
	return refusal == bridge_contract.bridge_refusal_name(.Permission_Denied) ||
		refusal == bridge_contract.bridge_refusal_name(.Client_Key_Missing) ||
		refusal == bridge_contract.bridge_refusal_name(.Wide_Grant_Expired) ||
		refusal == bridge_contract.bridge_refusal_name(.Wide_Grant_Not_Active)
}

// bridge_answer_read reads an answer of the bridge: a result is Done with
// its words, the error Awaiting_Principal_Approval waits for the
// principal, any other error is Refused with its message. Window words are
// cut to REPLY_TEXT_BYTES; model_text is bounded to model_byte_budget.
bridge_answer_read :: proc(answer: string, model_byte_budget := MODEL_STEP_RESULT_BYTES) -> (report: Act_Report) {
	parsed, parse_error := json.parse_string(answer, .JSON, true, context.temp_allocator)
	root, root_ok := parsed.(json.Object)
	if parse_error != .None || !root_ok {
		msg := "the bridge gave an answer that is no JSON"
		return {state = .Refused, text = msg, model_text = msg}
	}
	if error_value, has_error := root["error"].(json.Object); has_error {
		state, _ := error_value["state"].(json.String)
		refusal, _ := error_value["refusal"].(json.String)
		message, _ := error_value["message"].(json.String)
		if string(state) == bridge_contract.bridge_request_state_name(.Awaiting_Principal_Approval) {
			words := text_cut(fmt.tprintf("the bridge stopped it for the principal: %s", refusal))
			return {state = .Awaiting_Principal, text = words, model_text = words}
		}
		words := text_cut(fmt.tprintf("%s: %s", refusal, message))
		return {state = .Refused, text = words, model_text = words, grant_ended = bridge_refusal_ends_grant(string(refusal))}
	}
	result, result_ok := root["result"].(json.Object)
	if !result_ok {
		msg := "the bridge gave neither a result nor an error"
		return {state = .Refused, text = msg, model_text = msg}
	}
	return {
		state      = .Done,
		text       = text_cut(result_words(result)),
		model_text = model_result_words(result, model_byte_budget),
		table      = result_table_read(result),
	}
}

// result_table_read reads the typed table of a result of the bridge: the
// kind table or record, a name, columns that are texts, rows that are
// arrays of texts of the width of the columns, and a total that is no
// fewer than the rows. Any other form, and more columns than the window
// takes, has no table: the act shows its words only. The texts keep the
// bounds of the window: a control byte becomes a space, and a text past
// its bound ends with the cut mark.
result_table_read :: proc(result: json.Object) -> (table: Act_Result_Table) {
	kind_value, _ := result["value_kind"].(json.String)
	switch string(kind_value) {
	case bridge_contract.lex_value_kind_name(.Table):
		table.shape = .Table
	case bridge_contract.lex_value_kind_name(.Record):
		table.shape = .Record
	case:
		return {}
	}
	name, name_ok := result["record_name"].(json.String)
	columns, columns_ok := result["columns"].(json.Array)
	kinds, kinds_ok := result["column_kinds"].(json.Array)
	units, units_ok := result["column_units"].(json.Array)
	rows, rows_ok := result["rows"].(json.Array)
	row_integers, integers_ok := result["row_integers"].(json.Array)
	total, total_ok := result["total_rows"].(json.Integer)
	if !name_ok || len(name) == 0 || !columns_ok || !rows_ok || !total_ok || !kinds_ok || !units_ok || !integers_ok {
		return {}
	}
	if len(kinds) != len(columns) || len(units) != len(columns) || len(row_integers) != len(rows) {
		return {}
	}
	if len(columns) == 0 || len(columns) > assistant_contract.ACT_TABLE_COLUMN_CAPACITY || i64(total) < i64(len(rows)) {
		return {}
	}
	if table.shape == .Record && (len(rows) != 1 || total != 1) {
		return {}
	}
	table.name = field_text_cut(string(name), assistant_contract.ACT_TABLE_NAME_BYTES)
	table.columns = make([]string, len(columns), context.temp_allocator)
	table.kinds = make([]bridge_contract.Lex_Column_Kind, len(columns), context.temp_allocator)
	table.units = make([]i64, len(columns), context.temp_allocator)
	for column, index in columns {
		column_name, column_ok := column.(json.String)
		kind_name, kind_name_ok := kinds[index].(json.String)
		unit, unit_ok := units[index].(json.Integer)
		if !column_ok || len(column_name) == 0 || !kind_name_ok || !unit_ok {
			return {}
		}
		// The kind and the unit cross at this border: an unknown kind, or a
		// unit that does not fit its kind, gives no table.
		kind, kind_ok := bridge_contract.lex_column_kind_of_name(string(kind_name))
		if !kind_ok || !bridge_contract.lex_column_unit_valid(kind, i64(unit)) {
			return {}
		}
		table.columns[index] = field_text_cut(string(column_name), assistant_contract.ACT_TABLE_NAME_BYTES)
		table.kinds[index], table.units[index] = kind, i64(unit)
	}
	table.row_count = min(len(rows), assistant_contract.ACT_TABLE_ROW_CAPACITY)
	table.cells = make([]string, table.row_count * len(columns), context.temp_allocator)
	table.integers = make([]i64, table.row_count * len(columns), context.temp_allocator)
	for row, row_index in rows {
		cells, cells_ok := row.(json.Array)
		values, values_ok := row_integers[row_index].(json.Array)
		if !cells_ok || len(cells) != len(columns) || !values_ok || len(values) != len(columns) {
			return {}
		}
		for cell, column_index in cells {
			text, text_ok := cell.(json.String)
			value, value_ok := values[column_index].(json.Integer)
			if !text_ok || !value_ok {
				return {}
			}
			if row_index >= table.row_count {
				continue
			}
			// A number column carries its value, a text column its text:
			// each fact of a cell in one place.
			place := row_index * len(columns) + column_index
			if table.kinds[column_index] == .Text {
				table.cells[place] = field_text_cut(string(text), assistant_contract.ACT_TABLE_CELL_BYTES)
			} else {
				table.integers[place] = i64(value)
			}
		}
	}
	table.total_rows = i64(total)
	table.present = true
	return table
}

// field_text_cut gives a text within a bound of bytes, cut after a whole
// character with the cut mark of the system; each control byte becomes a
// space. An empty text stays empty: a cell can be empty.
field_text_cut :: proc(text: string, bound: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for character in text {
		if !text_encoding.character_in_text(character) {
			strings.write_byte(&builder, ' ')
		} else {
			strings.write_rune(&builder, character)
		}
	}
	clean := strings.to_string(builder)
	if len(clean) <= bound {
		return clean
	}
	buffer := make([]u8, bound, context.temp_allocator)
	given := copy(buffer, clean)
	count, _, _ := cut_mark.apply(buffer, given, len(clean) - given)
	return string(buffer[:count])
}

// result_words_bounded writes a typed result of the bridge as words,
// bounded to max_rows rows and max_columns columns, noting omitted columns
// and rows against total_rows.
@(private = "file")
result_words_bounded :: proc(result: json.Object, max_rows, max_columns, soft_byte_limit: int) -> string {
	kind_value, _ := result["value_kind"].(json.String)
	kind := string(kind_value)
	builder := strings.builder_make(context.temp_allocator)
	switch {
	case kind == bridge_contract.lex_value_kind_name(.Table) || kind == bridge_contract.lex_value_kind_name(.Record):
		name, _ := result["record_name"].(json.String)
		total, _ := result["total_rows"].(json.Integer)
		columns, _ := result["columns"].(json.Array)
		rows, _ := result["rows"].(json.Array)
		shown_columns := min(len(columns), max_columns)
		fmt.sbprintf(&builder, "%d rows of %s", total, name)
		if len(columns) > shown_columns {
			fmt.sbprintf(&builder, " (%d columns more not shown)", len(columns) - shown_columns)
		}
		shown_rows := 0
		row_limit := min(len(rows), max_rows)
		for row_number in 0 ..< row_limit {
			if soft_byte_limit > 0 && strings.builder_len(builder) > soft_byte_limit {
				break
			}
			cells, _ := rows[row_number].(json.Array)
			strings.write_string(&builder, row_number == 0 ? ": " : "; ")
			cell_limit := min(len(cells), shown_columns)
			for cell_number in 0 ..< cell_limit {
				if cell_number > 0 {
					strings.write_string(&builder, ", ")
				}
				column, _ := columns[cell_number].(json.String)
				fmt.sbprintf(&builder, "%s ", column)
				text, _ := cells[cell_number].(json.String)
				strings.write_string(&builder, string(text))
			}
			shown_rows += 1
		}
		if i64(total) > i64(shown_rows) {
			fmt.sbprintf(&builder, "; %d rows more are not shown", i64(total) - i64(shown_rows))
		}
	case kind == bridge_contract.lex_value_kind_name(.None):
		strings.write_string(&builder, "done, no value")
	case:
		switch value in result["value"] {
		case json.Integer:
			fmt.sbprintf(&builder, "%d", value)
		case json.String:
			strings.write_string(&builder, string(value))
		case json.Boolean:
			strings.write_string(&builder, value ? "true" : "false")
		case json.Null, json.Float, json.Array, json.Object:
			strings.write_string(&builder, "a value that the window does not show")
		}
	}
	return strings.to_string(builder)
}

// result_words writes a typed result of the bridge as words for the window.
@(private = "file")
result_words :: proc(result: json.Object) -> string {
	return result_words_bounded(result, MODEL_RESULT_ROW_CAPACITY, MODEL_RESULT_COLUMN_CAPACITY, assistant_contract.REPLY_TEXT_BYTES + 256)
}

// model_result_words formats a typed result for the model's tool turn,
// bounded to MODEL_RESULT_ROW_CAPACITY (64) rows,
// MODEL_RESULT_COLUMN_CAPACITY (24) columns, and byte_budget (<= 16 KiB).
model_result_words :: proc(result: json.Object, byte_budget := MODEL_STEP_RESULT_BYTES) -> string {
	bound := clamp(byte_budget, 0, MODEL_STEP_RESULT_BYTES)
	if bound == 0 {
		return ""
	}
	raw := result_words_bounded(result, MODEL_RESULT_ROW_CAPACITY, MODEL_RESULT_COLUMN_CAPACITY, bound + 256)
	return text_cut_bound(raw, bound)
}

// text_cut_bound gives the words within bound bytes, cut after a whole
// character, with the cut mark of the system, "... and N bytes more"; each
// line end and control byte becomes a space.
text_cut_bound :: proc(text: string, bound: int) -> string {
	if bound <= 0 {
		return ""
	}
	builder := strings.builder_make(context.temp_allocator)
	for character in text {
		if !text_encoding.character_in_text(character) {
			strings.write_byte(&builder, ' ')
		} else {
			strings.write_rune(&builder, character)
		}
	}
	clean := strings.to_string(builder)
	if len(clean) == 0 {
		return len("no words") <= bound ? "no words" : ""
	}
	if len(clean) <= bound {
		return clean
	}
	buffer := make([]u8, bound, context.temp_allocator)
	given := copy(buffer, clean)
	count, _, _ := cut_mark.apply(buffer, given, len(clean) - given)
	return string(buffer[:count])
}

// text_cut gives the words within the bound of the window, cut after a
// whole character, with the cut mark of the system, "... and N bytes
// more"; each line end and control byte becomes a space, as the contract
// of the window wants.
text_cut :: proc(text: string) -> string {
	return text_cut_bound(text, assistant_contract.REPLY_TEXT_BYTES)
}
