package host_agent_bridge

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import contract "modus:contract/agent_bridge"
import assistant_contract "modus:contract/assistant"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/remote"
import "modus:contract/wide_grants"

@(private = "file")
Step_Test_Transport :: struct {
	calls:     [dynamic]string,
	call_hits: int,
}

@(private = "file")
step_test_eval_lex :: proc(user_data: rawptr, line: string, allocator: mem.Allocator) -> (result: Lex_Eval_Result, outcome: call_outcome.Call_Outcome, err: string) {
	st := (^Step_Test_Transport)(user_data)
	st.call_hits += 1
	append(&st.calls, strings.clone(line))
	if line == "monitor.processes()" {
		cols := make([]string, 2, allocator)
		cols[0], cols[1] = "slot", "name"
		kinds := make([]contract.Lex_Column_Kind, 2, allocator)
		kinds[0], kinds[1] = .Integer, .Text
		units := make([]i64, 2, allocator)
		r0 := make([]string, 2, allocator); r0[0], r0[1] = "1", "root"
		r1 := make([]string, 2, allocator); r1[0], r1[1] = "2", "console"
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
	if strings.has_prefix(line, "settings.set(") {
		return {value_kind = .Text, text_value = "language updated"}, .Succeeded, ""
	}
	return {value_kind = .Integer, integer_value = 42}, .Succeeded, ""
}

@(private = "file")
step_test_policy :: proc(client_key: [32]u8, now_ms: u64) -> contract.Bridge_Client_Policy {
	client_key := client_key
	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = 1,
		grantee_identity_hash = blake3.hash(client_key[:]),
		authorities_word      = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input}),
		target_window_count   = 1,
		target_window_ids     = {0 = 10},
		duration_ms           = wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	terms.terms_hash, _ = wide_grants.wide_grant_terms_compute_hash(&terms)
	return {
		client_key_public     = client_key,
		principal_id          = 1,
		permissions_word      = contract.bridge_permissions_to_word({.Eval_Lex, .Eval_Step, .Read_Screen, .Send_Input, .Read_Log_Facts}),
		remote_uses_word      = remote.client_uses_word({.Calls, .View, .Input}),
		has_wide_grant        = true,
		wide_grant_serial     = 21,
		wide_grant_state_word = u64(wide_grants.Wide_Grant_State.Active),
		wide_grant_terms      = terms,
		wide_grant_created_ms = now_ms - 500,
		wide_grant_expires_ms = now_ms + 60_000,
		collector_available   = true,
	}
}

@(private = "file")
fixed_clock_1000 :: proc(user_data: rawptr) -> u64 {
	_ = user_data
	return 1000
}

@(test)
test_bridge_eval_step_persists_variables_and_enforces_read_only_border :: proc(t: ^testing.T) {
	st: Step_Test_Transport
	defer {
		for s in st.calls {
			delete(s)
		}
		delete(st.calls)
	}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, step_test_policy({0 = 0xAA, 31 = 0xBB}, 1000), {user_data = &st, eval_lex = step_test_eval_lex}))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fixed_clock_1000

	// Step 1: bind processes table and filter in the same step.
	req1 := `{"jsonrpc":"2.0","id":1,"method":"eval_step","params":{"lines":["p = monitor.processes()","p |> where(slot = 2)"]}}`
	ans1 := bridge_handle_json_line(&bridge, req1, context.temp_allocator)
	parsed1, err1 := json.parse_string(ans1, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err1, json.Error.None)
	res1 := parsed1.(json.Object)["result"].(json.Object)
	testing.expect_value(t, res1["value_kind"].(json.String), "table")
	testing.expect_value(t, res1["total_rows"].(json.Integer), i64(1))
	testing.expect_value(t, st.call_hits, 1)

	// Step 2: reuse variable `p` across steps without another machine call.
	req2 := `{"jsonrpc":"2.0","id":2,"method":"eval_step","params":{"lines":["p |> count()"]}}`
	ans2 := bridge_handle_json_line(&bridge, req2, context.temp_allocator)
	parsed2, err2 := json.parse_string(ans2, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err2, json.Error.None)
	res2 := parsed2.(json.Object)["result"].(json.Object)
	testing.expect_value(t, res2["value"].(json.Integer), i64(2))
	testing.expect_value(t, st.call_hits, 1)

	// Unauthorized call inside map -> Permission_Denied (NOT Awaiting_Principal_Approval), zero machine calls.
	req_bad := `{"jsonrpc":"2.0","id":3,"method":"eval_step","params":{"lines":["map([1], (x) => plans.apply(\"home\"))"]}}`
	ans_bad := bridge_handle_json_line(&bridge, req_bad, context.temp_allocator)
	parsed_bad, _ := json.parse_string(ans_bad, .JSON, true, context.temp_allocator)
	err_obj := parsed_bad.(json.Object)["error"].(json.Object)
	testing.expect_value(t, err_obj["state"].(json.String), "Ended")
	testing.expect_value(t, err_obj["refusal"].(json.String), "Permission_Denied")
	testing.expect_value(t, st.call_hits, 1)

	// Reset bindings on new request -> `p` is cleared.
	bridge_reset_step_bindings(&bridge)
	req3 := `{"jsonrpc":"2.0","id":4,"method":"eval_step","params":{"lines":["p |> count()"]}}`
	ans3 := bridge_handle_json_line(&bridge, req3, context.temp_allocator)
	parsed3, _ := json.parse_string(ans3, .JSON, true, context.temp_allocator)
	_, has_err := parsed3.(json.Object)["error"]
	testing.expect(t, has_err)

	// Verify collector BLAKE3 chain remained valid across all step records.
	verify_refusal, _ := bridge_act_log_verify(&bridge.act_log)
	testing.expect_value(t, verify_refusal, wide_grants.Wide_Grant_Refusal.None)
}

@(test)
test_bridge_run_approved_act_enforces_single_use_and_principal_proof :: proc(t: ^testing.T) {
	st: Step_Test_Transport
	defer {
		for s in st.calls {
			delete(s)
		}
		delete(st.calls)
	}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, step_test_policy({0 = 0xCC, 31 = 0xDD}, 1000), {user_data = &st, eval_lex = step_test_eval_lex}))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fixed_clock_1000

	// 1. Sensitive action (plans.apply) MUST NEVER execute even with Allowed_By_Principal + active wide grant.
	plan_line := `plans.apply("home")`
	plan_binding := contract.Approved_Act_Binding {
		act_number      = 1,
		principal_state = .Allowed_By_Principal,
		service         = transmute([]u8)string("plans"),
		export          = transmute([]u8)string("apply"),
		line_hash       = blake3.hash(transmute([]u8)plan_line),
	}
	_, plan_dec, _, _ := bridge_run_approved_act(&bridge, plan_binding, plan_line, context.temp_allocator)
	testing.expect_value(t, plan_dec.refusal, contract.Bridge_Refusal.Principal_Approval_Required)
	testing.expect_value(t, st.call_hits, 0)

	// 2. Non-sensitive approved act runs ONCE and records a BLAKE3 Act_Record.
	set_line := `settings.set(.french)`
	set_binding := contract.Approved_Act_Binding {
		act_number      = 2,
		principal_state = .Allowed_By_Principal,
		service         = transmute([]u8)string("settings"),
		export          = transmute([]u8)string("set"),
		line_hash       = blake3.hash(transmute([]u8)set_line),
	}
	res, ok_dec, act_rec, err_txt := bridge_run_approved_act(&bridge, set_binding, set_line, context.temp_allocator)
	testing.expectf(t, ok_dec.outcome == .Succeeded && err_txt == "", "expected ok, got %v %q", ok_dec, err_txt)
	testing.expect_value(t, res.text_value, "language updated")
	testing.expect_value(t, act_rec.detail_word_0, u64(2))
	testing.expect_value(t, st.call_hits, 1)

	// 3. Replaying the same act_number MUST be refused with Approval_Already_Used and zero extra calls.
	_, replay_dec, _, _ := bridge_run_approved_act(&bridge, set_binding, set_line, context.temp_allocator)
	testing.expect_value(t, replay_dec.refusal, contract.Bridge_Refusal.Approval_Already_Used)
	testing.expect_value(t, st.call_hits, 1)

	// 4. Forged state (Proposed) on a fresh act_number MUST be refused.
	forged := set_binding
	forged.act_number = 3
	forged.principal_state = assistant_contract.Act_State.Proposed
	_, forged_dec, _, _ := bridge_run_approved_act(&bridge, forged, set_line, context.temp_allocator)
	testing.expect_value(t, forged_dec.refusal, contract.Bridge_Refusal.Principal_Approval_Required)
	testing.expect_value(t, st.call_hits, 1)

	verify_refusal, _ := bridge_act_log_verify(&bridge.act_log)
	testing.expect_value(t, verify_refusal, wide_grants.Wide_Grant_Refusal.None)
}

@(test)
test_bridge_eval_step_refuses_lex_injection_in_arguments :: proc(t: ^testing.T) {
	st: Step_Test_Transport
	defer {
		for s in st.calls {
			delete(s)
		}
		delete(st.calls)
	}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, step_test_policy({0 = 0xEE, 31 = 0xFF}, 1000), {user_data = &st, eval_lex = step_test_eval_lex}))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fixed_clock_1000

	// Backslash or ${ interpolation marker in dynamic string arg must be refused before transport.
	for bad_req in ([]string{
		`{"jsonrpc":"2.0","id":1,"method":"eval_step","params":{"lines":["s = \"a\\\\b\"","manual.exports(s)"]}}`,
		`{"jsonrpc":"2.0","id":2,"method":"eval_step","params":{"lines":["s = \"a${plans.apply(1)}\"","manual.exports(s)"]}}`,
	}) {
		ans := bridge_handle_json_line(&bridge, bad_req, context.temp_allocator)
		parsed, err := json.parse_string(ans, .JSON, true, context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		_, has_err := parsed.(json.Object)["error"]
		testing.expectf(t, has_err, "expected injection refusal for %s", bad_req)
		testing.expect_value(t, st.call_hits, 0)
	}
}
