package agent_runner

import "core:mem"
import "core:strings"
import "core:testing"
import "internal:assistant/conversation"
import "modustool:agent_bridge"
import bridge_contract "modus:contract/agent_bridge"
import assistant_contract "modus:contract/assistant"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/wide_grants"

@(private = "file")
Full_Mock_Transport :: struct {
	eval_hits:    int,
	screen_hits:  int,
	facts_hits:   int,
	key_hits:     int,
	pointer_hits: int,
}

@(private = "file")
mock_eval_lex :: proc(user_data: rawptr, line: string, allocator: mem.Allocator) -> (result: agent_bridge.Lex_Eval_Result, outcome: call_outcome.Call_Outcome, err: string) {
	m := (^Full_Mock_Transport)(user_data)
	m.eval_hits += 1
	if line == "monitor.processes()" {
		cols := make([]string, 2, allocator); cols[0], cols[1] = "slot", "name"
		kinds := make([]bridge_contract.Lex_Column_Kind, 2, allocator); kinds[0], kinds[1] = .Integer, .Text
		units := make([]i64, 2, allocator)
		r0 := make([]string, 2, allocator); r0[0], r0[1] = "1", "root"
		r1 := make([]string, 2, allocator); r1[0], r1[1] = "2", "assistant"
		rows := make([][]string, 2, allocator); rows[0], rows[1] = r0, r1
		i0 := make([]i64, 2, allocator); i0[0] = 1
		i1 := make([]i64, 2, allocator); i1[0] = 2
		rints := make([][]i64, 2, allocator); rints[0], rints[1] = i0, i1
		return {
			value_kind   = .Table,
			record_name  = "Process",
			columns      = cols,
			column_kinds = kinds,
			column_units = units,
			rows         = rows,
			row_integers = rints,
			total_rows   = 2,
		}, .Succeeded, ""
	}
	if line == "settings.set(.french)" {
		return {value_kind = .Text, text_value = "language set to french"}, .Succeeded, ""
	}
	return {value_kind = .Integer, integer_value = 7}, .Succeeded, ""
}

@(private = "file")
mock_read_screen :: proc(user_data: rawptr, req: agent_bridge.Screen_Snapshot_Request, allocator: mem.Allocator) -> (snap: agent_bridge.Screen_Snapshot_Result, err: string, ok: bool) {
	m := (^Full_Mock_Transport)(user_data)
	m.screen_hits += 1
	data := make([]u8, 4, allocator)
	data[0], data[1], data[2], data[3] = 0x89, 'P', 'N', 'G'
	return {
		format       = req.format,
		width        = 800,
		height       = 600,
		frame_serial = 12,
		bytes        = data,
		content_hash = blake3.hash(data),
	}, "", true
}

@(private = "file")
mock_read_log_facts :: proc(user_data: rawptr, query: agent_bridge.Log_Facts_Query, allocator: mem.Allocator) -> (facts: []agent_bridge.Structured_Log_Fact, err: string, ok: bool) {
	_ = query
	m := (^Full_Mock_Transport)(user_data)
	m.facts_hits += 1
	out := make([]agent_bridge.Structured_Log_Fact, 2, allocator)
	out[0] = {sequence = 10, timestamp_ms = 500, module_name = "assistant", fact_name = "Running", level = "Info"}
	out[1] = {sequence = 11, timestamp_ms = 600, module_name = "storage", fact_name = "Mounted", level = "Info"}
	return out, "", true
}

@(private = "file")
mock_send_key :: proc(user_data: rawptr, window_id: u64, key: remote_display.Key_Body) -> (err: string, ok: bool) {
	_ = window_id
	_ = key
	m := (^Full_Mock_Transport)(user_data)
	m.key_hits += 1
	return "", true
}

@(private = "file")
mock_send_pointer :: proc(user_data: rawptr, window_id: u64, ptr: remote_display.Pointer_Body) -> (err: string, ok: bool) {
	_ = window_id
	_ = ptr
	m := (^Full_Mock_Transport)(user_data)
	m.pointer_hits += 1
	return "", true
}

@(private = "file")
wide_grant_runner_policy :: proc(client_key: [32]u8, now_ms: u64, target_window: u64) -> bridge_contract.Bridge_Client_Policy {
	client_key := client_key
	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = 1,
		grantee_identity_hash = blake3.hash(client_key[:]),
		authorities_word      = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input}),
		target_window_count   = 1,
		target_window_ids     = {0 = target_window},
		duration_ms           = wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	terms.terms_hash, _ = wide_grants.wide_grant_terms_compute_hash(&terms)
	return {
		client_key_public     = client_key,
		principal_id          = 1,
		permissions_word      = bridge_contract.bridge_permissions_to_word({.Eval_Lex, .Eval_Step, .Read_Screen, .Send_Input, .Read_Log_Facts}),
		remote_uses_word      = remote.client_uses_word({.Calls, .View, .Input}),
		has_wide_grant        = true,
		wide_grant_serial     = 33,
		wide_grant_state_word = u64(wide_grants.Wide_Grant_State.Active),
		wide_grant_terms      = terms,
		wide_grant_created_ms = now_ms - 1000,
		wide_grant_expires_ms = now_ms + 60_000,
		collector_available   = true,
	}
}

@(private = "file")
fixed_runner_clock :: proc(user_data: rawptr) -> u64 {
	_ = user_data
	return 5000
}

// Local Conversation-backed Window_Port including act_state for end-to-end tests.
@(private = "file")
local_window_port :: proc(conv: ^conversation.Conversation) -> Window_Port {
	return {
		user_data      = conv,
		request_serial = proc(ud: rawptr) -> (i64, string, bool) {
			err: errors.Error_Record
			_, s := conversation.request_serial((^conversation.Conversation)(ud), true, &err)
			return s, "", false
		},
		request_text = proc(ud: rawptr, serial: i64) -> (string, string, bool) {
			err: errors.Error_Record
			buf := make([]u8, assistant_contract.REQUEST_TEXT_BYTES, context.temp_allocator)
			outcome, n, _ := conversation.request_text((^conversation.Conversation)(ud), true, serial, buf, &err)
			if outcome != .Succeeded {
				return "", "request_text refused", false
			}
			return string(buf[:n]), "", false
		},
		stop_requested = proc(ud: rawptr, serial: i64) -> (bool, string, bool) {
			err: errors.Error_Record
			_, v := conversation.stop_requested((^conversation.Conversation)(ud), true, serial, &err)
			return v != 0, "", false
		},
		reply = proc(ud: rawptr, serial: i64, text: string, acts: int) -> (string, bool) {
			err: errors.Error_Record
			outcome, _, _ := conversation.reply((^conversation.Conversation)(ud), true, serial, text, i64(acts), &err)
			return outcome == .Succeeded ? "" : "reply refused", false
		},
		reply_refused = proc(ud: rawptr, serial: i64, rec: errors.Error_Record) -> (string, bool) {
			err: errors.Error_Record
			outcome, _, _ := conversation.reply_refused((^conversation.Conversation)(ud), true, serial, rec.kind, rec.unit, rec.argument, rec.value, rec.limit, &err)
			return outcome == .Succeeded ? "" : "reply_refused refused", false
		},
		act = proc(ud: rawptr, serial: i64, kind: assistant_contract.Act_Kind, line, service, export: string) -> (i64, string, bool) {
			err: errors.Error_Record
			outcome, num, _ := conversation.act((^conversation.Conversation)(ud), true, serial, i64(kind), line, service, export, &err)
			return num, outcome == .Succeeded ? "" : "act refused", false
		},
		act_result = proc(ud: rawptr, number: i64, state: assistant_contract.Act_State, text: string) -> (string, bool) {
			err: errors.Error_Record
			outcome, _, _ := conversation.act_result((^conversation.Conversation)(ud), true, number, i64(state), text, &err)
			return outcome == .Succeeded ? "" : "act_result refused", false
		},
		act_state = proc(ud: rawptr, number: i64) -> (assistant_contract.Act_State, string, bool) {
			err: errors.Error_Record
			outcome, word := conversation.act_state((^conversation.Conversation)(ud), true, number, &err)
			if outcome != .Succeeded {
				return {}, "act_state refused", false
			}
			st, ok := assistant_contract.act_state_of_word(word)
			return st, ok ? "" : "bad state word", false
		},
		act_line = proc(ud: rawptr, number: i64) -> (string, string, bool) {
			err: errors.Error_Record
			buf := make([]u8, assistant_contract.ACT_LINE_BYTES, context.temp_allocator)
			outcome, n := conversation.act_line((^conversation.Conversation)(ud), true, number, buf, &err)
			if outcome != .Succeeded {
				return "", "act_line refused", false
			}
			return string(buf[:n]), "", false
		},
		act_table = proc(ud: rawptr, number: i64, table: Act_Result_Table) -> (string, bool) {
			_ = ud
			_ = number
			_ = table
			return "", false
		},
		loop_end = proc(ud: rawptr, serial: i64, cause: Agent_Loop_End) -> (string, bool) {
			err: errors.Error_Record
			outcome, _, _ := conversation.loop_end((^conversation.Conversation)(ud), true, serial, i64(cause), &err)
			return outcome == .Succeeded ? "" : "loop_end refused", false
		},
	}
}

@(test)
test_model_reply_decode_new_act_kinds_and_refusals :: proc(t: ^testing.T) {
	// Valid eval_step, read_screen, read_log_facts, send_key, send_pointer.
	good := `{"text":"running acts","acts":[` +
		`{"kind":"eval_step","lines":["p = monitor.processes()","p |> count()"]},` +
		`{"kind":"read_screen","format":"png","max_width":800,"max_height":600},` +
		`{"kind":"read_log_facts","module":"assistant","max_records":10},` +
		`{"kind":"send_key","window_id":4,"code":65,"character":97,"pressed":true},` +
		`{"kind":"send_pointer","window_id":4,"x":100,"y":200,"buttons":1}` +
		`]}`
	reply, _, ok := model_reply_decode(good)
	testing.expect(t, ok)
	testing.expect_value(t, reply.act_count, 5)
	testing.expect_value(t, reply.acts[0].kind, assistant_contract.Act_Kind.Eval_Step)
	testing.expect_value(t, reply.acts[0].step_line_count, 2)
	testing.expect_value(t, reply.acts[1].kind, assistant_contract.Act_Kind.Read_Screen)
	testing.expect_value(t, reply.acts[2].kind, assistant_contract.Act_Kind.Read_Log_Facts)
	testing.expect_value(t, reply.acts[3].kind, assistant_contract.Act_Kind.Send_Key)
	testing.expect_value(t, reply.acts[4].kind, assistant_contract.Act_Kind.Send_Pointer)

	// Refusals: empty lines, bad format, max_records > 256, window_id 0, missing pressed, cross-kind fields.
	bad_cases := []string{
		`{"text":"a","acts":[{"kind":"eval_step","lines":[]}]}`,
		`{"text":"a","acts":[{"kind":"eval_step"}]}`,
		`{"text":"a","acts":[{"kind":"read_screen","format":"jpeg"}]}`,
		`{"text":"a","acts":[{"kind":"read_log_facts","max_records":999}]}`,
		`{"text":"a","acts":[{"kind":"send_key","window_id":0,"code":65,"pressed":true}]}`,
		`{"text":"a","acts":[{"kind":"send_key","window_id":4,"code":65}]}`,
		`{"text":"a","acts":[{"kind":"send_pointer","window_id":4,"x":10}]}`,
		`{"text":"a","acts":[{"kind":"eval_lex","line":"monitor.processes()","window_id":4}]}`,
	}
	for raw in bad_cases {
		_, _, decoded_ok := model_reply_decode(raw)
		testing.expectf(t, !decoded_ok, "expected refusal for %s", raw)
	}
}

@(test)
test_runner_dispatches_eval_step_screen_logs_and_scoped_input :: proc(t: ^testing.T) {
	mock: Full_Mock_Transport
	transport := agent_bridge.Machine_Transport {
		user_data      = &mock,
		eval_lex       = mock_eval_lex,
		read_screen    = mock_read_screen,
		read_log_facts = mock_read_log_facts,
		send_key       = mock_send_key,
		send_pointer   = mock_send_pointer,
	}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, wide_grant_runner_policy({0 = 0x12, 31 = 0x34}, 5000, 42), transport))
	defer agent_bridge.bridge_destroy(&bridge)
	bridge.clock_ms_proc = fixed_runner_clock

	conv := new(conversation.Conversation)
	defer free(conv)
	_ = conversation.request_keep(conv, "inspect system and type into window 42")

	// Step 1: eval_step binds p, reads screen, reads log facts, sends key to scoped window 42 and unscoped window 99.
	// Step 2: eval_step reuses `p` from step 1.
	// Step 3: final reply.
	script := []string{
		`{"text":"step 1","acts":[` +
			`{"kind":"eval_step","lines":["p = monitor.processes()","p |> where(slot = 2)"]},` +
			`{"kind":"read_screen","format":"png"},` +
			`{"kind":"read_log_facts","max_records":10},` +
			`{"kind":"send_key","window_id":42,"code":65,"pressed":true},` +
			`{"kind":"send_pointer","window_id":99,"x":10,"y":20,"buttons":1}` +
			`]}`,
		`{"text":"step 2","acts":[{"kind":"eval_step","lines":["p |> count()"]}]}`,
		`{"text":"all checked"}`,
	}
	fake := Fake_Model{replies = script}
	runner := Runner{window = local_window_port(conv), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Final_Reply)
	testing.expect_value(t, report.step_count, 3)
	testing.expect_value(t, mock.eval_hits, 1) // step 2 reused `p` from step 1!
	testing.expect_value(t, mock.screen_hits, 1)
	testing.expect_value(t, mock.facts_hits, 1)
	testing.expect_value(t, mock.key_hits, 1) // window 42 succeeded
	testing.expect_value(t, mock.pointer_hits, 0) // window 99 refused (Window_Not_In_Scope)!

	testing.expect_value(t, report.steps[0].acts[0].state, assistant_contract.Act_State.Done)
	testing.expect_value(t, report.steps[0].acts[1].state, assistant_contract.Act_State.Done)
	testing.expect(t, strings.contains(report.steps[0].acts[1].text, "screen 800x600"))
	testing.expect_value(t, report.steps[0].acts[2].state, assistant_contract.Act_State.Done)
	testing.expect(t, strings.contains(report.steps[0].acts[2].text, "2 log facts"))
	testing.expect_value(t, report.steps[0].acts[3].state, assistant_contract.Act_State.Done)
	testing.expect(t, strings.contains(report.steps[0].acts[3].text, "delivered to window 42"))
	testing.expect_value(t, report.steps[0].acts[4].state, assistant_contract.Act_State.Refused)
	testing.expect(t, strings.contains(report.steps[0].acts[4].text, "Window_Not_In_Scope"))
	testing.expect_value(t, report.steps[1].acts[0].state, assistant_contract.Act_State.Done)
	testing.expect_value(t, report.steps[1].acts[0].text, "2")
}

@(test)
test_runner_run_approved_act_runs_non_sensitive_once_and_refuses_proof_gated :: proc(t: ^testing.T) {
	mock: Full_Mock_Transport
	transport := agent_bridge.Machine_Transport{user_data = &mock, eval_lex = mock_eval_lex}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, wide_grant_runner_policy({0 = 0x77, 31 = 0x88}, 5000, 42), transport))
	defer agent_bridge.bridge_destroy(&bridge)
	bridge.clock_ms_proc = fixed_runner_clock

	conv := new(conversation.Conversation)
	defer free(conv)
	_ = conversation.request_keep(conv, "update language and try plan")

	// Propose two non-read-only acts: settings.set(.french) and plans.apply("home").
	script := []string{
		`{"text":"proposing acts","acts":[` +
			`{"kind":"eval_lex","line":"settings.set(.french)"},` +
			`{"kind":"eval_lex","line":"plans.apply(\"home\")"}` +
			`]}`,
		`{"text":"waiting for principal"}`,
	}
	fake := Fake_Model{replies = script}
	runner := Runner{window = local_window_port(conv), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	testing.expect_value(t, report.end, Agent_Loop_End.Final_Reply)
	testing.expect_value(t, mock.eval_hits, 0)
	act1_num := report.steps[0].acts[0].number
	act2_num := report.steps[0].acts[1].number

	// Simulate trusted display allowing act 1 (non-sensitive) and act 2 (proof-gated).
	conversation.act_of(conv, act1_num).state = .Allowed_By_Principal
	conversation.act_of(conv, act2_num).state = .Allowed_By_Principal

	// Act 1 (settings.set) runs ONCE and moves to Done.
	rep1, prob1, _ := runner_run_approved_act(&runner, act1_num, "settings.set(.french)")
	testing.expect_value(t, prob1, "")
	testing.expect_value(t, rep1.state, assistant_contract.Act_State.Done)
	testing.expect_value(t, rep1.text, "language set to french")
	testing.expect_value(t, mock.eval_hits, 1)
	testing.expect_value(t, conversation.act_of(conv, act1_num).state, assistant_contract.Act_State.Done)

	// Replaying act 1 MUST be refused (state is now Done, not Allowed_By_Principal).
	rep1_again, _, _ := runner_run_approved_act(&runner, act1_num, "settings.set(.french)")
	testing.expect_value(t, rep1_again.state, assistant_contract.Act_State.Refused)
	testing.expect_value(t, mock.eval_hits, 1)

	// Act 2 (plans.apply) MUST be refused hard even with Allowed_By_Principal + active wide grant!
	rep2, prob2, _ := runner_run_approved_act(&runner, act2_num, `plans.apply("home")`)
	testing.expect_value(t, prob2, "")
	testing.expect_value(t, rep2.state, assistant_contract.Act_State.Refused)
	testing.expect(t, strings.contains(rep2.text, "Principal_Approval_Required"))
	testing.expect_value(t, mock.eval_hits, 1)
	testing.expect_value(t, conversation.act_of(conv, act2_num).state, assistant_contract.Act_State.Refused)

	// Verify collector BLAKE3 chain remained valid.
	chain_refusal, _ := agent_bridge.bridge_act_log_verify(&bridge.act_log)
	testing.expect_value(t, chain_refusal, wide_grants.Wide_Grant_Refusal.None)
}

@(test)
test_runner_run_approved_act_refuses_line_substitution_and_acts_equal_checks_all_fields :: proc(t: ^testing.T) {
	mock: Full_Mock_Transport
	transport := agent_bridge.Machine_Transport{user_data = &mock, eval_lex = mock_eval_lex}
	bridge: agent_bridge.Agent_Bridge
	testing.expect(t, agent_bridge.bridge_init(&bridge, wide_grant_runner_policy({0 = 0x91, 31 = 0x92}, 5000, 42), transport))
	defer agent_bridge.bridge_destroy(&bridge)
	bridge.clock_ms_proc = fixed_runner_clock

	conv := new(conversation.Conversation)
	defer free(conv)
	_ = conversation.request_keep(conv, "approve french")
	script := []string{
		`{"text":"propose","acts":[{"kind":"eval_lex","line":"settings.set(.french)"}]}`,
		`{"text":"waiting"}`,
	}
	fake := Fake_Model{replies = script}
	runner := Runner{window = local_window_port(conv), bridge = &bridge, model = fake_model(&fake)}
	defer conversation_close(&runner)

	report := runner_turn(&runner)
	act_num := report.steps[0].acts[0].number
	conversation.act_of(conv, act_num).state = .Allowed_By_Principal

	// Substituting a different non-sensitive line against the approved act_number
	// must fail with Approval_Mismatch and zero machine calls!
	sub_rep, sub_prob, _ := runner_run_approved_act(&runner, act_num, "settings.set(.english)")
	testing.expect_value(t, sub_prob, "")
	testing.expect_value(t, sub_rep.state, assistant_contract.Act_State.Refused)
	testing.expect(t, strings.contains(sub_rep.text, "Approval_Mismatch"))
	testing.expect_value(t, mock.eval_hits, 0)

	// Verify acts_equal distinguishes kind-specific fields even when display lines match.
	log_a := Model_Act{kind = .Read_Log_Facts, line = "read_log_facts(max_records = 10)", module_filter = "assistant", max_records = 10}
	log_b := Model_Act{kind = .Read_Log_Facts, line = "read_log_facts(max_records = 10)", module_filter = "storage", max_records = 10}
	testing.expect(t, !acts_equal([]Model_Act{log_a}, []Model_Act{log_b}))

	key_a := Model_Act{kind = .Send_Key, line = "send_key(window = 4, code = 65, pressed = true)", window_id = 4, key_code = 65, key_character = 'a', key_pressed = true}
	key_b := Model_Act{kind = .Send_Key, line = "send_key(window = 4, code = 65, pressed = true)", window_id = 4, key_code = 65, key_character = 'A', key_pressed = true, key_modifiers = 1}
	testing.expect(t, !acts_equal([]Model_Act{key_a}, []Model_Act{key_b}))

	ptr_a := Model_Act{kind = .Send_Pointer, line = "send_pointer(window = 4, x = 1, y = 2, buttons = 0)", window_id = 4, pointer_x = 1, pointer_y = 2, pointer_wheel = 1}
	ptr_b := Model_Act{kind = .Send_Pointer, line = "send_pointer(window = 4, x = 1, y = 2, buttons = 0)", window_id = 4, pointer_x = 1, pointer_y = 2, pointer_wheel = -1}
	testing.expect(t, !acts_equal([]Model_Act{ptr_a}, []Model_Act{ptr_b}))
}
