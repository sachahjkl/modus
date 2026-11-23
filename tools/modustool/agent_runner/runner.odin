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

// The service of the window, as remote names it.
WINDOW_SERVICE :: "assistant"

// The parties of the runner: the calls to the window through remote, the
// bridge that runs each act, and the model. The conversation is the words
// that the model reads at its next reply.
Runner :: struct {
	client:       ^machine.Call_Client,
	bridge:       ^agent_bridge.Agent_Bridge,
	model:        Model,
	conversation: [dynamic]Turn,
	next_bridge_request: u64,
}

Turn_Outcome :: enum {
	No_Request, // No request of the window waits.
	Answered, // The reply showed, and each of its acts has its outcome.
	Reply_Refused, // The reply did not pass the border: its record showed.
	Model_Failed, // The model gave no reply: the window shows No_Answer.
	Window_Failed, // A call to the window failed: problem says which.
}

Turn_Report :: struct {
	outcome: Turn_Outcome,
	serial:  i64,
	acts:    [assistant_contract.MODEL_ACT_CAPACITY]Act_Report,
	act_count: int,
	record:  errors.Error_Record, // Reply_Refused: the record that the window shows.
	problem: string,
}

Act_Report :: struct {
	number: i64,
	state:  assistant_contract.Act_State,
	text:   string,
}

// window_call calls an export of the window with values, and gives the
// Integer result, or a problem.
@(private = "file")
window_call :: proc(runner: ^Runner, export: string, arguments: []machine.Call_Argument) -> (result: machine.Call_Result, problem: string) {
	result = machine.call_run_values(runner.client, WINDOW_SERVICE, export, arguments)
	if result.outcome != .Result {
		joined := strings.join(result.lines[:], "; ", context.temp_allocator)
		return result, fmt.tprintf("assistant.%s gave %v: %s", export, result.outcome, joined)
	}
	return result, ""
}

// runner_turn answers the oldest request of the window that no runner
// took, if one waits: the model replies, the reply passes the border or
// shows its refusal, then each act runs through the bridge and its outcome
// shows. An act stopped for the principal shows the act dialog of the
// trusted display, which the window asks for; the runner never answers it.
runner_turn :: proc(runner: ^Runner) -> (report: Turn_Report) {
	serial_result, problem := window_call(runner, "request_serial", nil)
	if problem != "" {
		return {outcome = .Window_Failed, problem = problem}
	}
	report.serial = serial_result.value
	if report.serial == 0 {
		report.outcome = .No_Request
		return
	}
	serial_argument := machine.Call_Argument{integer = report.serial}
	text_arguments := [1]machine.Call_Argument{serial_argument}
	text_result: machine.Call_Result
	if text_result, problem = window_call(runner, "request_text", text_arguments[:]); problem != "" {
		report.outcome, report.problem = .Window_Failed, problem
		return
	}
	append(&runner.conversation, Turn{role = .Principal, text = strings.clone(text_result.text)})
	raw, model_problem := runner.model.reply(runner.model.user_data, runner.conversation[:], context.temp_allocator)
	if model_problem != "" {
		report.outcome, report.problem = .Model_Failed, model_problem
		report.record = errors.error_make(.No_Answer)
		window_problem_keep(&report, reply_refused_show(runner, report.serial, report.record))
		return
	}
	reply, record, reply_ok := model_reply_decode(raw)
	if !reply_ok {
		report.outcome, report.record = .Reply_Refused, record
		window_problem_keep(&report, reply_refused_show(runner, report.serial, record))
		return
	}
	append(&runner.conversation, Turn{role = .Model, text = strings.clone(reply.text)})
	reply_arguments := [2]machine.Call_Argument{serial_argument, {is_text = true, text = reply.text}}
	if _, problem = window_call(runner, "reply", reply_arguments[:]); problem != "" {
		report.outcome, report.problem = .Window_Failed, problem
		return
	}
	for act in reply.acts[:reply.act_count] {
		act_arguments := [3]machine.Call_Argument{serial_argument, {integer = i64(act.kind)}, {is_text = true, text = act.line}}
		act_result: machine.Call_Result
		if act_result, problem = window_call(runner, "act", act_arguments[:]); problem != "" {
			report.outcome, report.problem = .Window_Failed, problem
			return
		}
		outcome := act_run(runner, act)
		outcome.number = act_result.value
		outcome_arguments := [3]machine.Call_Argument{{integer = outcome.number}, {integer = i64(outcome.state)}, {is_text = true, text = outcome.text}}
		if _, problem = window_call(runner, "act_result", outcome_arguments[:]); problem != "" {
			report.outcome, report.problem = .Window_Failed, problem
			return
		}
		append(&runner.conversation, Turn{role = .Outcome, text = fmt.aprintf("%s: %s, %s", act.line, assistant_contract.ACT_KIND_NAMES[act.kind], outcome.text)})
		report.acts[report.act_count] = outcome
		report.act_count += 1
	}
	report.outcome = .Answered
	return
}

// window_problem_keep keeps the problem of a call to the window in a
// report: the turn then failed, whatever it was before.
@(private = "file")
window_problem_keep :: proc(report: ^Turn_Report, problem: string) {
	if problem != "" {
		report.outcome, report.problem = .Window_Failed, problem
	}
}

@(private = "file")
reply_refused_show :: proc(runner: ^Runner, serial: i64, record: errors.Error_Record) -> string {
	arguments := [6]machine.Call_Argument{{integer = serial}, {integer = record.kind}, {integer = record.unit}, {integer = record.argument}, {integer = record.value}, {integer = record.limit}}
	_, problem := window_call(runner, "reply_refused", arguments[:])
	return problem
}

// act_run gives one act to the bridge, as one JSON-RPC line, so it passes
// each check of the bridge as any agent: the classification of the line,
// the read-only list, the act record. The answer becomes a state and words
// for the principal.
act_run :: proc(runner: ^Runner, act: Model_Act) -> (report: Act_Report) {
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
	return bridge_answer_read(answer)
}

// bridge_answer_read reads an answer of the bridge: a result is Done with
// its words, the error Awaiting_Principal_Approval waits for the
// principal, any other error is Refused with its message. The words are
// cut to the bound of the window.
bridge_answer_read :: proc(answer: string) -> (report: Act_Report) {
	parsed, parse_error := json.parse_string(answer, .JSON, true, context.temp_allocator)
	root, root_ok := parsed.(json.Object)
	if parse_error != .None || !root_ok {
		return {state = .Refused, text = "the bridge gave an answer that is no JSON"}
	}
	if error_value, has_error := root["error"].(json.Object); has_error {
		status, _ := error_value["status"].(json.String)
		refusal, _ := error_value["refusal"].(json.String)
		message, _ := error_value["message"].(json.String)
		if string(status) == bridge_contract.bridge_status_name(.Awaiting_Principal_Approval) {
			return {state = .Awaiting_Principal, text = text_cut(fmt.tprintf("the bridge stopped it for the principal: %s", refusal))}
		}
		return {state = .Refused, text = text_cut(fmt.tprintf("%s: %s", refusal, message))}
	}
	result, result_ok := root["result"].(json.Object)
	if !result_ok {
		return {state = .Refused, text = "the bridge gave neither a result nor an error"}
	}
	return {state = .Done, text = text_cut(result_words(result))}
}

// result_words writes a typed result of the bridge as words: a value, or
// the count of rows of a table with its columns and its first rows.
@(private = "file")
result_words :: proc(result: json.Object) -> string {
	kind_value, _ := result["value_kind"].(json.String)
	kind := string(kind_value)
	builder := strings.builder_make(context.temp_allocator)
	switch {
	case kind == bridge_contract.lex_value_kind_name(.Table) || kind == bridge_contract.lex_value_kind_name(.Record):
		name, _ := result["record_name"].(json.String)
		total, _ := result["total_rows"].(json.Integer)
		fmt.sbprintf(&builder, "%d rows of %s", total, name)
		columns, _ := result["columns"].(json.Array)
		rows, _ := result["rows"].(json.Array)
		for row, row_number in rows {
			cells, _ := row.(json.Array)
			strings.write_string(&builder, row_number == 0 ? ": " : "; ")
			for cell, cell_number in cells {
				if cell_number > 0 {
					strings.write_string(&builder, ", ")
				}
				if cell_number < len(columns) {
					column, _ := columns[cell_number].(json.String)
					fmt.sbprintf(&builder, "%s ", column)
				}
				text, _ := cell.(json.String)
				strings.write_string(&builder, string(text))
			}
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

// text_cut gives the words within the bound of the window, cut after a
// whole character, with the cut mark of the system, "... and N bytes
// more"; each line end and control byte becomes a space, as the contract
// of the window wants.
text_cut :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for character in text {
		if character < ' ' || character == 0x7F {
			strings.write_byte(&builder, ' ')
		} else {
			strings.write_rune(&builder, character)
		}
	}
	clean := strings.to_string(builder)
	if len(clean) == 0 {
		return "no words"
	}
	if len(clean) <= assistant_contract.REPLY_TEXT_BYTES {
		return clean
	}
	buffer := make([]u8, assistant_contract.REPLY_TEXT_BYTES, context.temp_allocator)
	given := copy(buffer, clean)
	count, _, _ := cut_mark.apply(buffer, given, len(clean) - given)
	return string(buffer[:count])
}
