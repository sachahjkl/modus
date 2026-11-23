package agent_runner

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:net"
import "core:testing"
import "core:time"
import "modustool:agent_bridge"
import assistant_contract "modus:contract/assistant"
import "modus:contract/call_outcome"
import "modus:contract/cut_mark"
import "modus:contract/errors"

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
	five := `{"kind": "eval_lex", "line": "x"}`
	refused_with(t, strings.concatenate({`{"text": "a", "acts": [`, five, ",", five, ",", five, ",", five, ",", five, "]}"}, context.temp_allocator), .Too_Long, .Acts)
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
	reply, _, ok = model_reply_decode(strings.concatenate({`{"text": "a", "acts": [`, act, ",", act, ",", act, ",", act, "]}"}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, reply.act_count, assistant_contract.MODEL_ACT_CAPACITY)
	testing.expect_value(t, reply.acts[3].line, "monitor.processes()")
	testing.expect_value(t, reply.acts[3].kind, assistant_contract.Act_Kind.Eval_Lex)
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
	testing.expect_value(t, outcome, Turn_Outcome.Model_Failed)
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
	for index in 0 ..< 20 {
		strings.write_byte(&rows, ',')
		strings.write_byte(&integers, ',')
		fmt.sbprintf(&rows, `["%d","name\u0001%d","","%d"]`, index, index, 100 * index)
		fmt.sbprintf(&integers, `[%d,0,0,%d]`, index, 100 * index)
	}
	long := strings.repeat("ab", assistant_contract.ACT_TABLE_CELL_BYTES, context.temp_allocator)
	// The braces of JSON are no format of fmt: the answer is joined.
	answer := strings.concatenate({`{"jsonrpc":"2.0","id":1,"result":{"status":"Ok","value_kind":"table","record_name":"Process","columns":["slot","name","hash","resident"],"column_kinds":["integer","text","text","size"],"column_units":[0,0,0,3],"rows":[["99","x\u0085y","`, long, `","7"]`, strings.to_string(rows), `],"row_integers":[[99,0,0,7]`, strings.to_string(integers), `],"total_rows":21}}`}, context.temp_allocator)
	report := bridge_answer_read(answer)
	testing.expect_value(t, report.state, assistant_contract.Act_State.Done)
	table := report.table
	testing.expect(t, table.present && table.shape == .Table && table.name == "Process")
	testing.expect_value(t, len(table.columns), 4)
	testing.expect(t, table.kinds[0] == .Integer && table.kinds[1] == .Text && table.kinds[3] == .Size && table.units[3] == 3)
	testing.expect_value(t, table.row_count, assistant_contract.ACT_TABLE_ROW_CAPACITY)
	testing.expect_value(t, len(table.cells), 4 * assistant_contract.ACT_TABLE_ROW_CAPACITY)
	testing.expect_value(t, table.total_rows, 21)
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
