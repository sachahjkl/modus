package agent_runner

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:net"
import "core:testing"
import "core:time"
import "internal:assistant/conversation"
import "modustool:agent_bridge"
import bridge_contract "modus:contract/agent_bridge"
import assistant_contract "modus:contract/assistant"
import "modus:contract/call_outcome"
import "modus:contract/cut_mark"
import "modus:contract/errors"
import "modus:contract/remote"

@(private = "file")
refused_with :: proc(t: ^testing.T, reply: string, kind: errors.Kind, field: Reply_Field, act: int = 0, loc := #caller_location) {
	_, record, ok := model_reply_decode(reply)
	testing.expectf(t, !ok, "%q passed the border", reply, loc = loc)
	testing.expectf(t, record.kind == i64(kind) && record.argument == i64(field) && record.found == i64(act), "%q: %v, not %v on %v of act %d", reply, record, kind, field, act, loc = loc)
}

// Each form that the border refuses, first: no JSON, text after the object,
// a field unknown, missing, duplicated or of another type, a text and a
// line at the edges of their bounds, a control byte, a bad escape, a lone
// surrogate, too many acts, a kind that names no member.
@(test)
the_border_refuses_each_malformed_model_reply :: proc(t: ^testing.T) {
	text_most := strings.repeat("a", assistant_contract.REPLY_TEXT_BYTES, context.temp_allocator)
	line_most := strings.repeat("b", assistant_contract.ACT_LINE_BYTES, context.temp_allocator)
	refused_with(t, "", .Bad_Value, .Reply)
	refused_with(t, "There are 12 processes.", .Bad_Value, .Reply)
	refused_with(t, "[]", .Bad_Value, .Reply)
	refused_with(t, "{", .Bad_Value, .Reply)
	refused_with(t, "{}", .Absent, .Text)
	refused_with(t, `{"text": "a"} {"text": "b"}`, .Bad_Value, .Reply)
	refused_with(t, `{"text": "a",}`, .Bad_Value, .Reply)
	refused_with(t, `{"text": "a", "text": "b"}`, .Bad_Value, .Text)
	refused_with(t, `{"text": "a", "approve": true}`, .Bad_Value, .Reply)
	refused_with(t, `{"text": 12}`, .Bad_Value, .Text)
	refused_with(t, `{"text": ""}`, .Empty, .Text)
	refused_with(t, strings.concatenate({`{"text": "`, text_most, `a"}`}, context.temp_allocator), .Too_Long, .Text)
	refused_with(t, "{\"text\": \"a\tb\"}", .Bad_Value, .Text)
	refused_with(t, `{"text": "a\u0001b"}`, .Bad_Value, .Text)
	refused_with(t, `{"text": "a\qb"}`, .Bad_Value, .Text)
	refused_with(t, `{"text": "\ud800"}`, .Bad_Value, .Text)
	refused_with(t, `{"text": "\udc00"}`, .Bad_Value, .Text)
	refused_with(t, `{"text": "a", "acts": {}}`, .Bad_Value, .Acts)
	refused_with(t, `{"text": "a", "acts": [], "acts": []}`, .Bad_Value, .Acts)
	refused_with(t, `{"text": "a", "acts": [{"kind": "eval_lex"}]}`, .Absent, .Line, 1)
	refused_with(t, `{"text": "a", "acts": [{"line": "monitor.processes()"}]}`, .Absent, .Kind, 1)
	refused_with(t, `{"text": "a", "acts": [{"kind": "approve", "line": "x"}]}`, .Bad_Value, .Kind, 1)
	refused_with(t, `{"text": "a", "acts": [{"kind": "eval_lex", "line": "x", "line": "y"}]}`, .Bad_Value, .Line, 1)
	refused_with(t, `{"text": "a", "acts": [{"kind": "eval_lex", "line": ""}]}`, .Empty, .Line, 1)
	refused_with(t, `{"text": "a", "acts": [{"kind": "eval_lex", "line": "a\nb"}]}`, .Bad_Value, .Line, 1)
	refused_with(t, strings.concatenate({`{"text": "a", "acts": [{"kind": "eval_lex", "line": "`, line_most, `b"}]}`}, context.temp_allocator), .Too_Long, .Line, 1)
	refused_with(t, `{"text": "a", "acts": [{"kind": "eval_lex", "line": "x", "safe": true}]}`, .Bad_Value, .Acts, 1)
	one_act := `{"kind": "eval_lex", "line": "x"}`
	too_many := strings.builder_make(context.temp_allocator)
	strings.write_string(&too_many, `{"text": "a", "acts": [`)
	for index in 0 ..< assistant_contract.MODEL_ACT_CAPACITY + 1 {
		if index > 0 {
			strings.write_byte(&too_many, ',')
		}
		strings.write_string(&too_many, one_act)
	}
	strings.write_string(&too_many, "]}")
	refused_with(t, strings.to_string(too_many), .Too_Long, .Acts)
	_, record, _ := model_reply_decode(strings.repeat(" ", MODEL_REPLY_BYTES + 1, context.temp_allocator))
	testing.expect_value(t, record.kind, i64(errors.Kind.Too_Long))
	testing.expect_value(t, record.limit, i64(MODEL_REPLY_BYTES))
}

// The forms that pass, last: the bounds themselves, no act, four acts,
// escapes, a line end that becomes a space, the fields in any order.
@(test)
the_border_passes_a_whole_model_reply :: proc(t: ^testing.T) {
	text_most := strings.repeat("a", assistant_contract.REPLY_TEXT_BYTES, context.temp_allocator)
	reply, _, ok := model_reply_decode(strings.concatenate({`{"text": "`, text_most, `"}`}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, len(reply.text), assistant_contract.REPLY_TEXT_BYTES)
	reply, _, ok = model_reply_decode(`  {"acts": [], "text": "two\nlines \u00e9t\u00e9 \"q\" \ud83d\ude00"}  `)
	testing.expect(t, ok)
	testing.expect_value(t, reply.text, "two lines été \"q\" 😀")
	testing.expect_value(t, reply.act_count, 0)
	act := `{"line": "monitor.processes()", "kind": "eval_lex"}`
	max_acts := strings.builder_make(context.temp_allocator)
	strings.write_string(&max_acts, `{"text": "a", "acts": [`)
	for index in 0 ..< assistant_contract.MODEL_ACT_CAPACITY {
		if index > 0 {
			strings.write_byte(&max_acts, ',')
		}
		strings.write_string(&max_acts, act)
	}
	strings.write_string(&max_acts, "]}")
	reply, _, ok = model_reply_decode(strings.to_string(max_acts))
	testing.expect(t, ok)
	testing.expect_value(t, reply.act_count, assistant_contract.MODEL_ACT_CAPACITY)
	testing.expect_value(t, reply.acts[assistant_contract.MODEL_ACT_CAPACITY - 1].line, "monitor.processes()")
	testing.expect_value(t, reply.acts[assistant_contract.MODEL_ACT_CAPACITY - 1].kind, assistant_contract.Act_Kind.Eval_Lex)
}

// An endpoint is plain HTTP with a host, a port and a path: each other form
// is refused at the start.
@(test)
an_endpoint_is_plain_http_with_a_port :: proc(t: ^testing.T) {
	for url in ([]string{"", "https://api.example:443/v1/chat", "ftp://a:1/b", "http://a/b", "http://a:0/b", "http://a:65536/b", "http://a:x/b", "http://user:secret@a:80/b", "http://a:80", "http://:80/b", "http://a:80/b c"}) {
		_, problem := endpoint_parse(url)
		testing.expectf(t, problem != "", "%q passed", url)
		testing.expectf(t, !strings.contains(problem, "secret"), "%q: the problem names the user part", url)
	}
	endpoint, problem := endpoint_parse("http://127.0.0.1:65535/v1/chat/completions")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, endpoint.host, "127.0.0.1")
	testing.expect_value(t, endpoint.port, 65535)
	testing.expect_value(t, endpoint.path, "/v1/chat/completions")
}

// The request holds the key in its header only, the conversation as JSON
// with its quotes and line ends escaped; the answer gives the content of
// the first choice, whole by its length, in chunks, or to the end; each
// other answer is a problem that names no key.
@(test)
the_endpoint_request_and_answer :: proc(t: ^testing.T) {
	model := Http_Model{endpoint = {host = "127.0.0.1", port = 8080, path = "/v1"}, key = "key-that-must-stay-hidden", model_name = "m"}
	conversation := []Turn{{role = .Principal, text = "say \"hi\"\nplease"}}
	request := http_request_build(&model, conversation)
	testing.expect(t, strings.has_prefix(request, "POST /v1 HTTP/1.1\r\n"))
	testing.expect_value(t, strings.count(request, model.key), 1)
	testing.expect(t, strings.contains(request, "Authorization: Bearer key-that-must-stay-hidden\r\n"))
	testing.expect(t, strings.contains(request, `"content":"say \"hi\"\nplease"`))
	body := `{"choices":[{"message":{"role":"assistant","content":"{\"text\": \"hi\"}"}}]}`
	whole := strings.concatenate({"HTTP/1.1 200 OK\r\nContent-Length: ", fmt.tprintf("%d", len(body)), "\r\n\r\n", body}, context.temp_allocator)
	content, problem := http_answer_content(transmute([]u8)whole)
	testing.expectf(t, problem == "" && content == `{"text": "hi"}`, "%q %q", content, problem)
	chunked := strings.concatenate({"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "a\r\n", body[:10], "\r\n", fmt.tprintf("%x", len(body) - 10), "\r\n", body[10:], "\r\n0\r\n\r\n"}, context.temp_allocator)
	content, problem = http_answer_content(transmute([]u8)chunked)
	testing.expectf(t, problem == "" && content == `{"text": "hi"}`, "%q %q", content, problem)
	to_the_end := strings.concatenate({"HTTP/1.0 200 OK\r\n\r\n", body}, context.temp_allocator)
	content, problem = http_answer_content(transmute([]u8)to_the_end)
	testing.expect_value(t, problem, "")
	for answer in ([]string{"", "HTTP/1.1 200 OK\r\n", "HTTP/1.1 401 Unauthorized\r\n\r\n{}", "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\n{}", "HTTP/1.1 200 OK\r\n\r\nnot json", "HTTP/1.1 200 OK\r\n\r\n{\"choices\":[]}", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"}) {
		_, answer_problem := http_answer_content(transmute([]u8)answer)
		testing.expectf(t, answer_problem != "", "%q passed", answer)
		testing.expect(t, !strings.contains(answer_problem, model.key))
	}
}

// The fake model gives its script in order, then a problem.
@(test)
the_fake_model_gives_its_script_in_order :: proc(t: ^testing.T) {
	replies := fake_script_read("one\n\n  \ntwo\n", context.temp_allocator)
	testing.expect_value(t, len(replies), 2)
	fake := Fake_Model{replies = replies}
	model := fake_model(&fake)
	first, _ := model.reply(model.user_data, nil, context.temp_allocator)
	second, _ := model.reply(model.user_data, nil, context.temp_allocator)
	_, problem := model.reply(model.user_data, nil, context.temp_allocator)
	testing.expect_value(t, first, "one")
	testing.expect_value(t, second, "two")
	testing.expect(t, problem != "")
}

// The words of a result keep the bound of the window, cut after a whole
// character with the mark; a control byte becomes a space; no words say so.
@(test)
the_words_of_a_result_keep_the_bound_of_the_window :: proc(t: ^testing.T) {
	testing.expect_value(t, text_cut(""), "no words")
	testing.expect_value(t, text_cut("a\nb\x01"), "a b ")
	most := strings.repeat("é", assistant_contract.REPLY_TEXT_BYTES / 2, context.temp_allocator)
	testing.expect_value(t, text_cut(most), most)
	cut := text_cut(strings.concatenate({most, "a"}, context.temp_allocator))
	testing.expect(t, len(cut) <= assistant_contract.REPLY_TEXT_BYTES)
	testing.expect(t, strings.has_suffix(cut, " bytes more"))
	testing.expect(t, strings.contains(cut, cut_mark.MARK_START))
	testing.expect_value(t, assistant_contract.text_check(cut, assistant_contract.REPLY_TEXT_BYTES), assistant_contract.Text_Refusal.None)
}

// A fake transport of the bridge: it counts the lines that reach the
// machine, and gives a table of one row.
@(private = "file")
Counting_Transport :: struct {
	lines: int,
}

@(private = "file")
counting_eval_lex :: proc(user_data: rawptr, line: string, allocator: mem.Allocator) -> (result: agent_bridge.Lex_Eval_Result, outcome: call_outcome.Call_Outcome, err: string) {
	transport := (^Counting_Transport)(user_data)
	transport.lines += 1
	columns := make([]string, 2, allocator)
	columns[0], columns[1] = "slot", "name"
	row := make([]string, 2, allocator)
	row[0], row[1] = "3", "console"
	rows := make([][]string, 1, allocator)
	rows[0] = row
	return {value_kind = .Table, record_name = "Process", columns = columns, rows = rows, total_rows = 1}, .Succeeded, ""
}

// An act runs through the bridge as any agent: a line on the read-only
// list reaches the machine and is Done; a grant-adding line and a line that
// names the window stop for the principal and never reach the machine; a
// line that is no single call is refused at the border of the bridge.
@(test)
an_act_runs_only_through_the_bridge :: proc(t: ^testing.T) {
	counting: Counting_Transport
	transport := agent_bridge.Machine_Transport{user_data = &counting, eval_lex = counting_eval_lex}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, runner_policy({1 = 7}, 0), transport))
	defer agent_bridge.bridge_destroy(&bridge)
	runner := Runner{bridge = &bridge}
	awaiting := []string{`plans.apply("home")`, "assistant.act_result(1, 5, \"allowed\")", `compositor.act_ask("plans.apply")`, "settings.set(.french)"}
	for line in awaiting {
		report := act_run(&runner, {kind = .Eval_Lex, line = line})
		testing.expectf(t, report.state == .Awaiting_Principal, "%q: %v %q", line, report.state, report.text)
	}
	refused := []string{"monitor.processes() |> first(1)", "let x = 1 in x", "monitor.processes(plans.apply(1))", "lock"}
	for line in refused {
		report := act_run(&runner, {kind = .Eval_Lex, line = line})
		testing.expectf(t, report.state == .Refused, "%q: %v %q", line, report.state, report.text)
	}
	testing.expect_value(t, counting.lines, 0)
	// A line whose names the act dialog cannot show: the bridge stops it,
	// and the outcome for the window is a refusal, never a wait that the
	// window would refuse.
	long_export := strings.concatenate({"plans.", strings.repeat("a", assistant_contract.ACT_NAME_BYTES + 5, context.temp_allocator), "()"}, context.temp_allocator)
	for line in ([]string{long_export, "plans.Apply()", "plans._apply()"}) {
		stopped := act_run(&runner, {kind = .Eval_Lex, line = line})
		service, export := act_names(line)
		testing.expectf(t, service == "" && export == "", "%q gave the names %q %q", line, service, export)
		shown := act_outcome_for_display(stopped, service)
		testing.expectf(t, shown.state == .Refused && shown.text == ACT_WITHOUT_NAMES_WORDS, "%q: %v %q, the bridge gave %v", line, shown.state, shown.text, stopped.state)
	}
	// A line with names keeps its wait; an outcome that is no wait is
	// kept as the bridge gave it.
	named := act_run(&runner, {kind = .Eval_Lex, line = `plans.apply("home")`})
	named_service, _ := act_names(`plans.apply("home")`)
	testing.expect_value(t, act_outcome_for_display(named, named_service).state, assistant_contract.Act_State.Awaiting_Principal)
	testing.expect_value(t, act_outcome_for_display({state = .Done, text = "12"}, "").state, assistant_contract.Act_State.Done)
	testing.expect_value(t, counting.lines, 0)
	report := act_run(&runner, {kind = .Eval_Lex, line = "monitor.processes()"})
	testing.expect_value(t, report.state, assistant_contract.Act_State.Done)
	testing.expect_value(t, report.text, "1 rows of Process: slot 3, name console")
	testing.expect_value(t, counting.lines, 1)
}

// An answer of the bridge that is no JSON, or that has neither a result
// nor an error, is a refusal, never a result.
@(test)
a_bridge_answer_that_is_not_whole_is_a_refusal :: proc(t: ^testing.T) {
	for answer in ([]string{"", "not json", "[]", `{"jsonrpc":"2.0","id":1}`}) {
		testing.expect_value(t, bridge_answer_read(answer).state, assistant_contract.Act_State.Refused)
	}
	report := bridge_answer_read(`{"jsonrpc":"2.0","id":1,"result":{"state":"Ended","outcome":"Succeeded","value_kind":"Integer","value":12}}`)
	testing.expect(t, report.state == .Done && report.text == "12")
}

// A host that is not this machine is refused unless the option names the
// risk; a host with a space, a line end or another byte that names no host
// is refused with the option too. The loopback forms pass.
@(test)
an_endpoint_off_this_machine_needs_the_option_that_names_the_risk :: proc(t: ^testing.T) {
	for url in ([]string{"http://10.0.2.2:8080/v1", "http://api.example:80/v1", "http://128.0.0.1:80/v1", "http://127.0.0.256:80/v1", "http://127.0.0:80/v1", "http://127.0.0.1.2:80/v1", "http://localhost.example:80/v1", "http://[::2]:80/v1"}) {
		_, problem := endpoint_parse(url)
		testing.expectf(t, strings.contains(problem, OFF_HOST_OPTION), "%q: %q", url, problem)
	}
	for url in ([]string{"http://a\r\nX-Injected: 1:80/v1", "http://a b:80/v1", "http://a\n:80/v1", "http://a\x00:80/v1", "http://é:80/v1"}) {
		_, problem := endpoint_parse(url, true)
		testing.expectf(t, problem != "", "%q passed with the option", url)
	}
	for url in ([]string{"http://127.0.0.1:80/v1", "http://127.255.0.9:80/v1", "http://localhost:11434/v1", "http://[::1]:80/v1"}) {
		_, problem := endpoint_parse(url)
		testing.expectf(t, problem == "", "%q: %q", url, problem)
	}
	endpoint, problem := endpoint_parse("http://10.0.2.2:8080/v1", true)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, endpoint.host, "10.0.2.2")
}

// A key with a line end, a space, a control byte or a byte that is not
// ASCII would add a line to the head of the request: refused, and the
// problem never names the key.
@(test)
a_key_with_a_line_end_or_a_space_is_refused :: proc(t: ^testing.T) {
	for key in ([]string{"", "abc\r\nX-Injected: 1", "abc\ndef", "abc def", "abc\tdef", "abc\x00", "abc\x7F", "abcé"}) {
		problem := key_check(key)
		testing.expectf(t, problem != "", "%q passed", key)
		testing.expect(t, len(key) == 0 || !strings.contains(problem, key))
	}
	testing.expect_value(t, key_check("sk-0123456789abcdef_ABC.~"), "")
}

// The chunks of an answer: a size near the largest int, a size one past
// the room, a chunk with no end of line; the room itself passes.
@(test)
the_chunks_of_an_answer_keep_their_bounds :: proc(t: ^testing.T) {
	head := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
	for chunks in ([]string{"7fffffffffffffff\r\nab\r\n0\r\n\r\n", "ffffffffffffffff\r\nab\r\n0\r\n\r\n", "3\r\nab\r\n0\r\n\r\n", "2\r\nab", "2\r\nab\r", "-1\r\nab\r\n"}) {
		_, problem := http_answer_content(transmute([]u8)strings.concatenate({head, chunks}, context.temp_allocator))
		testing.expectf(t, problem != "", "%q passed", chunks)
	}
}

// A body nested past the bound is refused before the parser descends; a
// bracket inside a string counts nothing.
@(test)
a_body_nested_past_the_bound_is_refused :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", 100_000, context.temp_allocator), strings.repeat("]", 100_000, context.temp_allocator)}, context.temp_allocator)
	_, problem := http_answer_content(transmute([]u8)strings.concatenate({"HTTP/1.1 200 OK\r\n\r\n", deep}, context.temp_allocator))
	testing.expect(t, strings.contains(problem, "nested"))
	testing.expect(t, !json_depth_within(strings.repeat("{", JSON_DEPTH_BOUND + 1, context.temp_allocator), JSON_DEPTH_BOUND))
	testing.expect(t, json_depth_within(strings.repeat("[", JSON_DEPTH_BOUND, context.temp_allocator), JSON_DEPTH_BOUND))
	testing.expect(t, json_depth_within(`["[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\"[["]`, 2))
}

// The status of an answer is printed only when it is three digits: a long
// token, a token with a control byte, and words are refused with a
// problem that does not hold them.
@(test)
the_status_of_an_answer_is_three_digits :: proc(t: ^testing.T) {
	long_token := strings.repeat("9", 5000, context.temp_allocator)
	for status in ([]string{long_token, "2000", "20", "abc", "6xx", "2\x1b0"}) {
		_, problem := http_answer_content(transmute([]u8)strings.concatenate({"HTTP/1.1 ", status, " X\r\n\r\n{}"}, context.temp_allocator))
		testing.expectf(t, problem != "" && !strings.contains(problem, status), "%q: %q", status, problem)
	}
	_, problem := http_answer_content(transmute([]u8)string("HTTP/1.1 503 Busy\r\n\r\n{}"))
	testing.expect(t, strings.contains(problem, "503"))
}

// The deadline of the answer in the test of a stall: the behaviour under
// test, short so the test ends soon. The test asserts no duration.
@(private = "file")
STALL_TEST_DEADLINE :: 200 * time.Millisecond

// An endpoint that takes the connection and never answers fails the model
// at the deadline of the answer, a parameter of the model under test: the
// outcome is Model_Failed with the record No_Answer, not a hang.
@(test)
an_endpoint_that_stalls_fails_the_model :: proc(t: ^testing.T) {
	listener, listen_error := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect(t, listen_error == nil)
	defer net.close(listener)
	bound, bound_error := net.bound_endpoint(listener)
	testing.expect(t, bound_error == nil)
	model := Http_Model{endpoint = {host = "127.0.0.1", port = bound.port, path = "/v1"}, key = "k", model_name = "m", answer_deadline = STALL_TEST_DEADLINE}
	_, outcome, record, problem := model_answer(http_model(&model), nil)
	testing.expect_value(t, outcome, Model_Answer_Kind.Model_Failed)
	testing.expect_value(t, record.kind, i64(errors.Kind.No_Answer))
	testing.expectf(t, strings.contains(problem, "no whole answer"), "%q", problem)
}

// The conversation keeps the last requests whole: an outcome never stays
// without the call that it answers. A request is the role user, a reply
// the role assistant with its acts as calls, an outcome the role tool.
@(test)
the_conversation_is_bounded_and_outcomes_speak_as_tools :: proc(t: ^testing.T) {
	runner: Runner
	defer conversation_close(&runner)
	for index in 0 ..< CONVERSATION_REQUEST_CAPACITY + 3 {
		append(&runner.conversation, Turn{role = .Principal, text = fmt.aprintf("request %d", index)})
		calls := make([]Turn_Call, 1)
		calls[0] = {id = fmt.aprintf("call_%d", index), kind = .Eval_Lex, line = strings.clone("monitor.processes()")}
		append(&runner.conversation, Turn{role = .Model, text = strings.clone("a reply"), calls = calls})
		append(&runner.conversation, Turn{role = .Outcome, text = strings.clone("Done: 3 rows"), call_id = fmt.aprintf("call_%d", index)})
		conversation_bound(&runner)
	}
	testing.expect_value(t, len(runner.conversation), 3 * CONVERSATION_REQUEST_CAPACITY)
	testing.expect_value(t, runner.conversation[0].role, Turn_Role.Principal)
	testing.expect_value(t, runner.conversation[0].text, "request 3")
	model := Http_Model{endpoint = {host = "127.0.0.1", port = 8080, path = "/v1"}, key = "k", model_name = "m"}
	request := http_request_build(&model, runner.conversation[:3])
	testing.expect(t, strings.contains(request, `{"role":"user","content":"request 3"}`))
	testing.expect(t, strings.contains(request, `"tool_calls":[{"id":"call_3","type":"function","function":{"name":"eval_lex","arguments":"{\"line\":\"monitor.processes()\"}"}}]`))
	testing.expect(t, strings.contains(request, `{"role":"tool","tool_call_id":"call_3","content":"Done: 3 rows"}`))
	testing.expect_value(t, strings.count(request, `"role":"user"`), 1)
}

// The names of an act come from the parser of the bridge: one call gives
// its two names, any other line none.
@(test)
the_names_of_an_act_come_from_the_parser_of_the_bridge :: proc(t: ^testing.T) {
	service, export := act_names(`plans.apply("home")`)
	testing.expect(t, service == "plans" && export == "apply")
	service, export = act_names("monitor.processes()")
	testing.expect(t, service == "monitor" && export == "processes")
	for line in ([]string{"monitor.processes() |> first(1)", "let x = 1 in x", "lock", "a.b.c()", "Plans.apply()", "x.y(); z.w()", "monitor.processes()\nplans.apply()"}) {
		service, export = act_names(line)
		testing.expectf(t, service == "" && export == "", "%q gave %q %q", line, service, export)
	}
}

// The typed result of a bridge answer: a table keeps its columns with
// their kind and unit, its first rows within the bound and its total; a
// number column carries its value and no text, a text column its text and
// no value; a long cell ends with the cut mark and keeps the bound; a
// control character, U+0085 too, becomes a space; an empty cell stays
// empty; a record is one row.
@(test)
a_table_of_the_bridge_crosses_typed_within_the_bounds :: proc(t: ^testing.T) {
	rows := strings.builder_make(context.temp_allocator)
	integers := strings.builder_make(context.temp_allocator)
	extra_rows := assistant_contract.ACT_TABLE_ROW_CAPACITY + 10
	for index in 0 ..< extra_rows {
		strings.write_byte(&rows, ',')
		strings.write_byte(&integers, ',')
		fmt.sbprintf(&rows, `["%d","name\u0001%d","","%d"]`, index, index, 100 * index)
		fmt.sbprintf(&integers, `[%d,0,0,%d]`, index, 100 * index)
	}
	long := strings.repeat("ab", assistant_contract.ACT_TABLE_CELL_BYTES, context.temp_allocator)
	// The braces of JSON are no format of fmt: the answer is joined.
	answer := strings.concatenate({`{"jsonrpc":"2.0","id":1,"result":{"status":"Ok","value_kind":"table","record_name":"Process","columns":["slot","name","hash","resident"],"column_kinds":["integer","text","text","size"],"column_units":[0,0,0,3],"rows":[["99","x\u0085y","`, long, `","7"]`, strings.to_string(rows), `],"row_integers":[[99,0,0,7]`, strings.to_string(integers), `],"total_rows":`, fmt.tprintf("%d", extra_rows + 1), `}}`}, context.temp_allocator)
	report := bridge_answer_read(answer)
	testing.expect_value(t, report.state, assistant_contract.Act_State.Done)
	table := report.table
	testing.expect(t, table.present && table.shape == .Table && table.name == "Process")
	testing.expect_value(t, len(table.columns), 4)
	testing.expect(t, table.kinds[0] == .Integer && table.kinds[1] == .Text && table.kinds[3] == .Size && table.units[3] == 3)
	testing.expect_value(t, table.row_count, assistant_contract.ACT_TABLE_ROW_CAPACITY)
	testing.expect_value(t, len(table.cells), 4 * assistant_contract.ACT_TABLE_ROW_CAPACITY)
	testing.expect_value(t, table.total_rows, i64(extra_rows + 1))
	// A number column: its value, and no text.
	testing.expect(t, table.cells[0] == "" && table.integers[0] == 99)
	testing.expect(t, table.cells[7] == "" && table.integers[7] == 0)
	testing.expect_value(t, table.integers[4 + 3], 0)
	testing.expect_value(t, table.integers[2 * 4 + 3], 100)
	// A text column: its text, and no value.
	testing.expect(t, len(table.cells[2]) <= assistant_contract.ACT_TABLE_CELL_BYTES && strings.contains(table.cells[2], cut_mark.MARK_START))
	testing.expect(t, table.integers[1] == 0 && table.integers[2] == 0)
	// U+0085 is a control character of the window too: it becomes a
	// space, so the window takes the cell.
	testing.expect_value(t, table.cells[1], "x y")
	testing.expect_value(t, text_cut("a\u0085b\u009fc"), "a b c")
	testing.expect_value(t, table.cells[4 + 1], "name 0")
	testing.expect_value(t, table.cells[4 + 2], "")
	for cell in table.cells {
		testing.expect_value(t, assistant_contract.text_check(cell == "" ? "x" : cell, assistant_contract.ACT_TABLE_CELL_BYTES), assistant_contract.Text_Refusal.None)
	}
	record := bridge_answer_read(`{"jsonrpc":"2.0","id":1,"result":{"status":"Ok","value_kind":"record","record_name":"Counts","columns":["processes","threads"],"column_kinds":["integer","integer"],"column_units":[0,0],"rows":[["12","40"]],"row_integers":[[12,40]],"total_rows":1}}`)
	testing.expect(t, record.table.present && record.table.shape == .Record && record.table.row_count == 1 && record.table.integers[1] == 40)
}

// Each answer that is not a whole table within the bounds has no table:
// the act shows its words only. A value has none either.
@(test)
a_table_that_is_not_whole_crosses_as_words_only :: proc(t: ^testing.T) {
	many := strings.builder_make(context.temp_allocator)
	many_kinds := strings.builder_make(context.temp_allocator)
	many_units := strings.builder_make(context.temp_allocator)
	many_row := strings.builder_make(context.temp_allocator)
	many_values := strings.builder_make(context.temp_allocator)
	for index in 0 ..< assistant_contract.ACT_TABLE_COLUMN_CAPACITY + 1 {
		if index > 0 {
			for builder in ([]^strings.Builder{&many, &many_kinds, &many_units, &many_row, &many_values}) {
				strings.write_byte(builder, ',')
			}
		}
		fmt.sbprintf(&many, `"c%d"`, index)
		strings.write_string(&many_kinds, `"text"`)
		strings.write_string(&many_units, "0")
		strings.write_string(&many_row, `"1"`)
		strings.write_string(&many_values, "0")
	}
	head :: `{"jsonrpc":"2.0","id":1,"result":{"status":"Ok",`
	whole :: `"column_kinds":["text"],"column_units":[0],"row_integers":[[0]],`
	results := []string {
		`"value_kind":"table","record_name":"P","columns":["a","b"],"column_kinds":["text","text"],"column_units":[0,0],"rows":[["1"]],"row_integers":[[0]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],` + whole + `"rows":[[1]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":[],"column_kinds":[],"column_units":[],"rows":[],"row_integers":[],"total_rows":0}}`,
		`"value_kind":"table","record_name":"P","columns":[""],` + whole + `"rows":[["1"]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"","columns":["a"],` + whole + `"rows":[["1"]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],` + whole + `"rows":[["1"]],"total_rows":0}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],"rows":[["1"]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":"a",` + whole + `"rows":[["1"]],"total_rows":1}}`,
		`"value_kind":"record","record_name":"P","columns":["a"],"column_kinds":["text"],"column_units":[0],"rows":[["1"],["2"]],"row_integers":[[0],[0]],"total_rows":2}}`,
		// The kind and the unit at their border: a kind of no name, none,
		// a unit that does not fit, a kind that is no text, a missing value.
		`"value_kind":"table","record_name":"P","columns":["a"],"column_kinds":["number"],"column_units":[0],"rows":[["1"]],"row_integers":[[1]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],"column_kinds":["none"],"column_units":[0],"rows":[["1"]],"row_integers":[[1]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],"column_kinds":["size"],"column_units":[99],"rows":[["1"]],"row_integers":[[1]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],"column_kinds":["hexadecimal"],"column_units":[0],"rows":[["1"]],"row_integers":[[1]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],"column_kinds":[2],"column_units":[0],"rows":[["1"]],"row_integers":[[1]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],"column_kinds":["integer"],"column_units":[0],"rows":[["1"]],"row_integers":[["1"]],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a"],"column_kinds":["integer"],"column_units":[0],"rows":[["1"]],"row_integers":[],"total_rows":1}}`,
		`"value_kind":"table","record_name":"P","columns":["a","b"],"column_kinds":["integer"],"column_units":[0,0],"rows":[["1","2"]],"row_integers":[[1,2]],"total_rows":1}}`,
		`"value_kind":"integer","value":12}}`,
		strings.concatenate({`"value_kind":"table","record_name":"P","columns":[`, strings.to_string(many), `],"column_kinds":[`, strings.to_string(many_kinds), `],"column_units":[`, strings.to_string(many_units), `],"rows":[[`, strings.to_string(many_row), `]],"row_integers":[[`, strings.to_string(many_values), `]],"total_rows":1}}`}, context.temp_allocator),
	}
	for result in results {
		report := bridge_answer_read(strings.concatenate({head, result}, context.temp_allocator))
		testing.expectf(t, report.state == .Done && !report.table.present, "%q gave a table", result)
	}
	// The whole form, last: a table.
	report := bridge_answer_read(strings.concatenate({head, `"value_kind":"table","record_name":"P","columns":["a"],`, whole, `"rows":[["1"]],"total_rows":1}}`}, context.temp_allocator))
	testing.expect(t, report.table.present)
}

// The system instructions name no service and tell the model to discover
// commands through manual.modules(), manual.exports(name) and
// manual.signature(name, n).
@(test)
system_prompt_names_no_service_and_explains_discovery :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(SYSTEM_PROMPT, "manual.modules()"))
	testing.expect(t, strings.contains(SYSTEM_PROMPT, "manual.exports(name)"))
	testing.expect(t, strings.contains(SYSTEM_PROMPT, "manual.signature(name, n)"))
	for forbidden in ([]string{"monitor", "log.records", "compositor", "plans", "recipes", "projects", "storage", "settings"}) {
		testing.expectf(t, !strings.contains(SYSTEM_PROMPT, forbidden), "SYSTEM_PROMPT named service %q", forbidden)
	}
}

// What the model reads from a bridge result is bounded to 64 rows, 24
// columns and the step byte budget (<= 16 KiB), with a count of omitted
// rows and columns.
@(test)
model_result_bounds_rows_columns_and_bytes :: proc(t: ^testing.T) {
	cols := strings.builder_make(context.temp_allocator)
	kinds := strings.builder_make(context.temp_allocator)
	units := strings.builder_make(context.temp_allocator)
	col_count := MODEL_RESULT_COLUMN_CAPACITY + 4
	for c in 0 ..< col_count {
		if c > 0 {
			strings.write_byte(&cols, ',')
			strings.write_byte(&kinds, ',')
			strings.write_byte(&units, ',')
		}
		fmt.sbprintf(&cols, `"c%d"`, c)
		strings.write_string(&kinds, `"text"`)
		strings.write_string(&units, "0")
	}
	rows := strings.builder_make(context.temp_allocator)
	ints := strings.builder_make(context.temp_allocator)
	row_count := MODEL_RESULT_ROW_CAPACITY + 20
	for r in 0 ..< row_count {
		if r > 0 {
			strings.write_byte(&rows, ',')
			strings.write_byte(&ints, ',')
		}
		strings.write_byte(&rows, '[')
		strings.write_byte(&ints, '[')
		for c in 0 ..< col_count {
			if c > 0 {
				strings.write_byte(&rows, ',')
				strings.write_byte(&ints, ',')
			}
			fmt.sbprintf(&rows, `"v%d_%d"`, r, c)
			strings.write_byte(&ints, '0')
		}
		strings.write_byte(&rows, ']')
		strings.write_byte(&ints, ']')
	}
	answer := strings.concatenate({
		`{"jsonrpc":"2.0","id":1,"result":{"status":"Ok","value_kind":"table","record_name":"Big","columns":[`,
		strings.to_string(cols),
		`],"column_kinds":[`,
		strings.to_string(kinds),
		`],"column_units":[`,
		strings.to_string(units),
		`],"rows":[`,
		strings.to_string(rows),
		`],"row_integers":[`,
		strings.to_string(ints),
		`],"total_rows":`,
		fmt.tprintf("%d", row_count),
		`}}`,
	}, context.temp_allocator)
	report := bridge_answer_read(answer, 2048)
	testing.expect_value(t, report.state, assistant_contract.Act_State.Done)
	testing.expect(t, len(report.model_text) <= 2048)
	testing.expect(t, strings.contains(report.model_text, "4 columns more not shown"))
	testing.expect(t, strings.contains(report.model_text, cut_mark.MARK_START))
	full := bridge_answer_read(answer, MODEL_STEP_RESULT_BYTES)
	testing.expect(t, len(full.model_text) <= MODEL_STEP_RESULT_BYTES)
	testing.expect(t, !strings.contains(full.model_text, "v70_0"))
	testing.expect(t, !strings.contains(full.model_text, "c25 "))
}

// In-memory Window_Port backed by the real conversation border, so host
// tests exercise the full runner + bridge + conversation loop end to end.
@(private = "file")
Memory_Window :: struct {
	talk:               ^conversation.Conversation,
	acts_for_principal: bool,
}

@(private = "file")
memory_window_port :: proc(win: ^Memory_Window) -> Window_Port {
	return {
		user_data = win,
		request_serial = proc(user_data: rawptr) -> (serial: i64, problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			err: errors.Error_Record
			outcome, r := conversation.request_serial(w.talk, w.acts_for_principal, &err)
			if outcome != .Succeeded {
				return 0, "request_serial refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return r, "", false
		},
		request_text = proc(user_data: rawptr, serial: i64) -> (text: string, problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			buf := make([]u8, assistant_contract.REQUEST_TEXT_BYTES, context.temp_allocator)
			err: errors.Error_Record
			outcome, r, _ := conversation.request_text(w.talk, w.acts_for_principal, serial, buf, &err)
			if outcome != .Succeeded {
				return "", "request_text refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return string(buf[:r]), "", false
		},
		stop_requested = proc(user_data: rawptr, serial: i64) -> (stopped: bool, problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			err: errors.Error_Record
			outcome, r := conversation.stop_requested(w.talk, w.acts_for_principal, serial, &err)
			if outcome != .Succeeded {
				return false, "stop_requested refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return r != 0, "", false
		},
		reply = proc(user_data: rawptr, serial: i64, text: string, acts: int) -> (problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			err: errors.Error_Record
			outcome, _, _ := conversation.reply(w.talk, w.acts_for_principal, serial, text, i64(acts), &err)
			if outcome != .Succeeded {
				return "reply refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return "", false
		},
		reply_refused = proc(user_data: rawptr, serial: i64, record: errors.Error_Record) -> (problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			err: errors.Error_Record
			outcome, _, _ := conversation.reply_refused(w.talk, w.acts_for_principal, serial, record.kind, record.unit, record.argument, record.value, record.limit, &err)
			if outcome != .Succeeded {
				return "reply_refused refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return "", false
		},
		act = proc(user_data: rawptr, serial: i64, kind: assistant_contract.Act_Kind, line, service, export: string) -> (number: i64, problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			err: errors.Error_Record
			outcome, r, _ := conversation.act(w.talk, w.acts_for_principal, serial, i64(kind), line, service, export, &err)
			if outcome != .Succeeded {
				return 0, "act refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return r, "", false
		},
		act_result = proc(user_data: rawptr, number: i64, state: assistant_contract.Act_State, text: string) -> (problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			err: errors.Error_Record
			outcome, _, _ := conversation.act_result(w.talk, w.acts_for_principal, number, i64(state), text, &err)
			if outcome != .Succeeded {
				return "act_result refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return "", false
		},
		act_table = proc(user_data: rawptr, number: i64, table: Act_Result_Table) -> (problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			cols := make([]assistant_contract.Act_Table_Column, len(table.columns), context.temp_allocator)
			for name, i in table.columns {
				copy(cols[i].name[:], name)
				cols[i].kind = i64(table.kinds[i])
				cols[i].unit = table.units[i]
			}
			cells := make([]assistant_contract.Act_Table_Cell, len(table.cells), context.temp_allocator)
			for text, i in table.cells {
				copy(cells[i].text[:], text)
				cells[i].integer = table.integers[i]
			}
			err: errors.Error_Record
			outcome, _, _ := conversation.act_table(w.talk, w.acts_for_principal, number, i64(table.shape), table.name, table.total_rows, cols, cells, &err)
			if outcome != .Succeeded {
				return "act_table refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return "", false
		},
		loop_end = proc(user_data: rawptr, serial: i64, cause: Agent_Loop_End) -> (problem: string, grant_ended: bool) {
			w := (^Memory_Window)(user_data)
			err: errors.Error_Record
			outcome, _, _ := conversation.loop_end(w.talk, w.acts_for_principal, serial, i64(cause), &err)
			if outcome != .Succeeded {
				return "loop_end refused", err.kind == i64(errors.Kind.No_Grant)
			}
			return "", false
		},
	}
}

// Fake transport that serves discovery (manual.*) and monitor.processes()
// and records every line executed, with an optional callback after a call.
@(private = "file")
Loop_Transport :: struct {
	lines:     [dynamic]string,
	after_act: proc(state: ^Loop_Transport),
	stop_talk: ^conversation.Conversation,
	vary:      bool, // Each call of manual.signature gives another text: a state that moves.
}

@(private = "file")
loop_eval_lex :: proc(user_data: rawptr, line: string, allocator: mem.Allocator) -> (result: agent_bridge.Lex_Eval_Result, outcome: call_outcome.Call_Outcome, err: string) {
	state := (^Loop_Transport)(user_data)
	append(&state.lines, strings.clone(line, allocator))
	if state.after_act != nil {
		state.after_act(state)
	}
	switch {
	case line == "manual.modules()":
		cols := make([]string, 2, allocator)
		cols[0], cols[1] = "name", "exports"
		kinds := make([]bridge_contract.Lex_Column_Kind, 2, allocator)
		kinds[0], kinds[1] = .Text, .Integer
		units := make([]i64, 2, allocator)
		r0 := make([]string, 2, allocator)
		r0[0], r0[1] = "monitor", "5"
		i0 := make([]i64, 2, allocator)
		i0[1] = 5
		rows := make([][]string, 1, allocator)
		rows[0] = r0
		row_ints := make([][]i64, 1, allocator)
		row_ints[0] = i0
		return {value_kind = .Table, record_name = "Module", columns = cols, column_kinds = kinds, column_units = units, rows = rows, row_integers = row_ints, total_rows = 1}, .Succeeded, ""
	case strings.has_prefix(line, "manual.exports("):
		cols := make([]string, 1, allocator)
		cols[0] = "name"
		kinds := make([]bridge_contract.Lex_Column_Kind, 1, allocator)
		kinds[0] = .Text
		units := make([]i64, 1, allocator)
		r0 := make([]string, 1, allocator)
		r0[0] = "processes"
		i0 := make([]i64, 1, allocator)
		rows := make([][]string, 1, allocator)
		rows[0] = r0
		row_ints := make([][]i64, 1, allocator)
		row_ints[0] = i0
		return {value_kind = .Table, record_name = "Export", columns = cols, column_kinds = kinds, column_units = units, rows = rows, row_integers = row_ints, total_rows = 1}, .Succeeded, ""
	case strings.has_prefix(line, "manual.signature("):
		if state.vary {
			return {value_kind = .Text, text_value = fmt.aprintf("processes() -> Table, call %d", len(state.lines), allocator = allocator)}, .Succeeded, ""
		}
		return {value_kind = .Text, text_value = "processes() -> Table"}, .Succeeded, ""
	case:
		cols := make([]string, 2, allocator)
		cols[0], cols[1] = "slot", "name"
		kinds := make([]bridge_contract.Lex_Column_Kind, 2, allocator)
		kinds[0], kinds[1] = .Integer, .Text
		units := make([]i64, 2, allocator)
		r0 := make([]string, 2, allocator)
		r0[0], r0[1] = "1", "root"
		i0 := make([]i64, 2, allocator)
		i0[0] = 1
		rows := make([][]string, 1, allocator)
		rows[0] = r0
		row_ints := make([][]i64, 1, allocator)
		row_ints[0] = i0
		return {value_kind = .Table, record_name = "Process", columns = cols, column_kinds = kinds, column_units = units, rows = rows, row_integers = row_ints, total_rows = 1}, .Succeeded, ""
	}
}

// Multi-step loop: discovery (manual.modules -> manual.exports & signature)
// -> query (monitor.processes) -> final answer (0 acts). Verifies tool
// outcomes feed back in the tool role, older steps fold in the window, and
// the latest action step stays open.
@(test)
multi_step_loop_discovers_queries_and_answers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	talk := new(conversation.Conversation, context.temp_allocator)
	testing.expect(t, conversation.request_keep(talk, "which processes run") != nil)
	win := Memory_Window{talk = talk, acts_for_principal = true}
	lt := Loop_Transport{lines = make([dynamic]string, context.temp_allocator)}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, runner_policy({1 = 9}, 0), {user_data = &lt, eval_lex = loop_eval_lex}))
	defer agent_bridge.bridge_destroy(&bridge)
	replies := []string {
		`{"text": "Finding modules.", "acts": [{"kind": "eval_lex", "line": "manual.modules()"}]}`,
		`{"text": "Checking monitor exports.", "acts": [{"kind": "eval_lex", "line": "manual.exports(\"monitor\")"}, {"kind": "eval_lex", "line": "manual.signature(\"monitor\", 1)"}]}`,
		`{"text": "Listing processes.", "acts": [{"kind": "eval_lex", "line": "monitor.processes()"}]}`,
		`{"text": "One process runs: root."}`,
	}
	fake := Fake_Model{replies = replies}
	runner := Runner{window = memory_window_port(&win), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	testing.expect(t, report.has_request)
	testing.expect_value(t, report.end, Agent_Loop_End.Final_Reply)
	testing.expect_value(t, report.step_count, 4)
	testing.expect_value(t, report.total_acts, 4)
	testing.expect_value(t, len(lt.lines), 4)
	testing.expect_value(t, lt.lines[0], "manual.modules()")
	testing.expect_value(t, lt.lines[3], "monitor.processes()")
	// Tool results fed back in the tool role for every act.
	tool_turns := 0
	for turn in runner.conversation {
		if turn.role == .Outcome {
			tool_turns += 1
			testing.expect(t, turn.call_id != "")
		}
	}
	testing.expect_value(t, tool_turns, 4)
	// Older steps folded in conversation; latest action step (act 4) stays open.
	testing.expect(t, conversation.act_folded(talk, conversation.act_of(talk, 1)))
	testing.expect(t, conversation.act_folded(talk, conversation.act_of(talk, 2)))
	testing.expect(t, !conversation.act_folded(talk, conversation.act_of(talk, 4)))
	testing.expect_value(t, conversation.request_of(talk, 1).turn, conversation.Turn_State.Ended)
	testing.expect_value(t, conversation.request_of(talk, 1).end_cause, Agent_Loop_End.Final_Reply)
}

// Step limit: 16 steps with distinct acts stop cleanly at Step_Limit and
// never call the model a 17th time.
@(test)
multi_step_loop_stops_at_step_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	talk := new(conversation.Conversation, context.temp_allocator)
	testing.expect(t, conversation.request_keep(talk, "check signatures") != nil)
	win := Memory_Window{talk = talk, acts_for_principal = true}
	lt := Loop_Transport{lines = make([dynamic]string, context.temp_allocator)}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, runner_policy({1 = 10}, 0), {user_data = &lt, eval_lex = loop_eval_lex}))
	defer agent_bridge.bridge_destroy(&bridge)
	replies := make([]string, assistant_contract.AGENT_LOOP_STEP_CAPACITY + 2, context.temp_allocator)
	for i in 0 ..< len(replies) {
		// The braces of JSON are no format of fmt: the reply is joined.
		replies[i] = strings.concatenate({`{"text": "Step `, fmt.tprintf("%d", i + 1), `", "acts": [{"kind": "eval_lex", "line": "manual.signature(\"monitor\", `, fmt.tprintf("%d", i + 1), `)"}]}`}, context.temp_allocator)
	}
	fake := Fake_Model{replies = replies}
	runner := Runner{window = memory_window_port(&win), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Step_Limit)
	testing.expect_value(t, report.step_count, assistant_contract.AGENT_LOOP_STEP_CAPACITY)
	testing.expect_value(t, fake.next, assistant_contract.AGENT_LOOP_STEP_CAPACITY)
	testing.expect_value(t, len(lt.lines), assistant_contract.AGENT_LOOP_STEP_CAPACITY)
	testing.expect_value(t, conversation.request_of(talk, 1).end_cause, Agent_Loop_End.Step_Limit)
}

// Repeated step: proposing the exact same acts as the previous step ends
// cleanly with Repeated_Step without running the duplicate acts.
@(test)
multi_step_loop_stops_on_repeated_step :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	talk := new(conversation.Conversation, context.temp_allocator)
	testing.expect(t, conversation.request_keep(talk, "repeat") != nil)
	win := Memory_Window{talk = talk, acts_for_principal = true}
	lt := Loop_Transport{lines = make([dynamic]string, context.temp_allocator)}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, runner_policy({1 = 11}, 0), {user_data = &lt, eval_lex = loop_eval_lex}))
	defer agent_bridge.bridge_destroy(&bridge)
	replies := []string {
		`{"text": "Try 1", "acts": [{"kind": "eval_lex", "line": "manual.modules()"}]}`,
		`{"text": "Try 2", "acts": [{"kind": "eval_lex", "line": "manual.modules()"}]}`,
		`{"text": "Never reached"}`,
	}
	fake := Fake_Model{replies = replies}
	runner := Runner{window = memory_window_port(&win), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Repeated_Step)
	// A repeat is known from its results: the second step ran, and the
	// model gets no third reply.
	testing.expect_value(t, report.step_count, 2)
	testing.expect_value(t, len(lt.lines), 2)
	testing.expect_value(t, fake.next, 2)
	testing.expect_value(t, conversation.request_of(talk, 1).end_cause, Agent_Loop_End.Repeated_Step)
}

// The same acts whose results changed are no repeat: the loop goes on to
// the final reply. The same acts in another order, or one act more, are no
// repeat either.
@(test)
the_same_acts_with_new_results_are_no_repeat :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	talk := new(conversation.Conversation, context.temp_allocator)
	testing.expect(t, conversation.request_keep(talk, "wait for a change") != nil)
	win := Memory_Window{talk = talk, acts_for_principal = true}
	lt := Loop_Transport{lines = make([dynamic]string, context.temp_allocator), vary = true}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, runner_policy({1 = 15}, 0), {user_data = &lt, eval_lex = loop_eval_lex}))
	defer agent_bridge.bridge_destroy(&bridge)
	same := `{"text": "Again", "acts": [{"kind": "eval_lex", "line": "manual.signature(\"monitor\", 1)"}]}`
	replies := []string{same, same, same, `{"text": "It changed three times."}`}
	fake := Fake_Model{replies = replies}
	runner := Runner{window = memory_window_port(&win), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)
	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Final_Reply)
	testing.expect_value(t, report.step_count, 4)
	testing.expect_value(t, len(lt.lines), 3)
	// The rule alone, at its edges.
	a := Model_Act{kind = .Eval_Lex, line = "manual.modules()"}
	b := Model_Act{kind = .Eval_Lex, line = "manual.exports(\"monitor\")"}
	testing.expect(t, step_repeats({a, b}, {a, b}, {"x", "y"}, {"x", "y"}))
	testing.expect(t, !step_repeats({a, b}, {b, a}, {"x", "y"}, {"y", "x"}))
	testing.expect(t, !step_repeats({a, b}, {a}, {"x", "y"}, {"x"}))
	testing.expect(t, !step_repeats({a}, {a}, {"x"}, {"x2"}))
	testing.expect(t, !step_repeats({}, {}, {}, {}))
}

// Principal stop: pressing Stop during step 1 stops the loop before step 2
// runs, ending cleanly with Stopped_By_Principal.
@(test)
multi_step_loop_stops_when_principal_stops :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	talk := new(conversation.Conversation, context.temp_allocator)
	testing.expect(t, conversation.request_keep(talk, "stop me") != nil)
	win := Memory_Window{talk = talk, acts_for_principal = true}
	lt := Loop_Transport {
		lines     = make([dynamic]string, context.temp_allocator),
		stop_talk = talk,
		after_act = proc(state: ^Loop_Transport) {
			conversation.principal_stop(state.stop_talk)
		},
	}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, runner_policy({1 = 12}, 0), {user_data = &lt, eval_lex = loop_eval_lex}))
	defer agent_bridge.bridge_destroy(&bridge)
	replies := []string {
		`{"text": "Step 1", "acts": [{"kind": "eval_lex", "line": "manual.modules()"}]}`,
		`{"text": "Step 2", "acts": [{"kind": "eval_lex", "line": "monitor.processes()"}]}`,
	}
	fake := Fake_Model{replies = replies}
	runner := Runner{window = memory_window_port(&win), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Stopped_By_Principal)
	testing.expect_value(t, report.step_count, 1)
	testing.expect_value(t, len(lt.lines), 1)
	testing.expect_value(t, fake.next, 1)
	testing.expect_value(t, conversation.request_of(talk, 1).end_cause, Agent_Loop_End.Stopped_By_Principal)
}

// Malformed model replies are refused on step 1 or on a later step; no act
// of the malformed reply runs and the window records Reply_Refused.
@(test)
multi_step_loop_refuses_malformed_reply_on_any_step :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	talk := new(conversation.Conversation, context.temp_allocator)
	testing.expect(t, conversation.request_keep(talk, "bad step 2") != nil)
	win := Memory_Window{talk = talk, acts_for_principal = true}
	lt := Loop_Transport{lines = make([dynamic]string, context.temp_allocator)}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, runner_policy({1 = 13}, 0), {user_data = &lt, eval_lex = loop_eval_lex}))
	defer agent_bridge.bridge_destroy(&bridge)
	replies := []string {
		`{"text": "Step 1", "acts": [{"kind": "eval_lex", "line": "manual.modules()"}]}`,
		`{"text": "Bad", "acts": [{"kind": "approve", "line": "plans.apply(\"home\")"}]}`,
	}
	fake := Fake_Model{replies = replies}
	runner := Runner{window = memory_window_port(&win), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Model_Failed)
	testing.expect(t, report.reply_refused)
	testing.expect_value(t, report.step_count, 1)
	testing.expect_value(t, len(lt.lines), 1)
	testing.expect_value(t, conversation.request_of(talk, 1).end_cause, Agent_Loop_End.Model_Failed)
}

// Losing the bridge permission or the window grant ends the loop with
// Grant_Ended.
@(test)
multi_step_loop_ends_on_grant_ended :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// 1. Bridge lacks Eval_Lex permission.
	talk := new(conversation.Conversation, context.temp_allocator)
	testing.expect(t, conversation.request_keep(talk, "no bridge grant") != nil)
	win := Memory_Window{talk = talk, acts_for_principal = true}
	lt := Loop_Transport{lines = make([dynamic]string, context.temp_allocator)}
	no_lex_policy := bridge_contract.Bridge_Client_Policy {
		client_key_public   = {1 = 14},
		permissions_word    = bridge_contract.bridge_permissions_to_word({.Read_Log_Facts}),
		remote_uses_word    = remote.client_uses_word({.Calls}),
		collector_available = true,
	}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, no_lex_policy, {user_data = &lt, eval_lex = loop_eval_lex}))
	defer agent_bridge.bridge_destroy(&bridge)
	replies := []string {
		`{"text": "Step 1", "acts": [{"kind": "eval_lex", "line": "manual.modules()"}]}`,
		`{"text": "Step 2"}`,
	}
	fake := Fake_Model{replies = replies}
	runner := Runner{window = memory_window_port(&win), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)
	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Grant_Ended)
	testing.expect_value(t, len(lt.lines), 0)
	testing.expect_value(t, conversation.request_of(talk, 1).end_cause, Agent_Loop_End.Grant_Ended)

	// 2. Window caller lost Acts_For_Principal.
	win2 := Memory_Window{talk = talk, acts_for_principal = false}
	runner2 := Runner{window = memory_window_port(&win2), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner2)
	report2 := runner_turn(&runner2)
	testing.expect_value(t, report2.end, Agent_Loop_End.Grant_Ended)
}
