package host_agent_bridge

import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import contract "modus:contract/agent_bridge"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/wide_grants"

@(private = "file")
Fake_Clock :: struct {
	now_ms: u64,
}

@(private = "file")
fake_clock_now_ms :: proc(user_data: rawptr) -> u64 {
	clock := (^Fake_Clock)(user_data)
	return clock.now_ms
}

@(private = "file")
Fake_Transport_State :: struct {
	eval_lex_calls:       int,
	last_lex_line:        string,
	next_lex_result:      Lex_Eval_Result,
	fail_eval_lex:        bool,
	eval_lex_err:         string,

	read_screen_calls:    int,
	last_screen_request:  Screen_Snapshot_Request,
	next_screen_result:   Screen_Snapshot_Result,
	fail_read_screen:     bool,
	read_screen_err:      string,

	send_key_calls:       int,
	last_key_window:      u64,
	last_key:             remote_display.Key_Body,
	fail_send_key:        bool,
	send_key_err:         string,

	send_pointer_calls:   int,
	last_pointer_window:  u64,
	last_pointer:         remote_display.Pointer_Body,
	fail_send_pointer:    bool,
	send_pointer_err:     string,

	read_log_facts_calls: int,
	last_log_query:       Log_Facts_Query,
	next_log_facts:       []Structured_Log_Fact,
	fail_read_log_facts:  bool,
	read_log_facts_err:   string,
}

@(private = "file")
fake_eval_lex :: proc(user_data: rawptr, line: string, allocator: mem.Allocator) -> (result: Lex_Eval_Result, err: string, ok: bool) {
	_ = allocator
	state := (^Fake_Transport_State)(user_data)
	state.eval_lex_calls += 1
	state.last_lex_line = strings.clone(line, context.temp_allocator)
	if state.fail_eval_lex {
		return {}, state.eval_lex_err, false
	}
	return state.next_lex_result, "", true
}

@(private = "file")
fake_read_screen :: proc(user_data: rawptr, request: Screen_Snapshot_Request, allocator: mem.Allocator) -> (snapshot: Screen_Snapshot_Result, err: string, ok: bool) {
	_ = allocator
	state := (^Fake_Transport_State)(user_data)
	state.read_screen_calls += 1
	state.last_screen_request = request
	if state.fail_read_screen {
		return {}, state.read_screen_err, false
	}
	return state.next_screen_result, "", true
}

@(private = "file")
fake_send_key :: proc(user_data: rawptr, window_id: u64, key: remote_display.Key_Body) -> (err: string, ok: bool) {
	state := (^Fake_Transport_State)(user_data)
	state.send_key_calls += 1
	state.last_key_window = window_id
	state.last_key = key
	if state.fail_send_key {
		return state.send_key_err, false
	}
	return "", true
}

@(private = "file")
fake_send_pointer :: proc(user_data: rawptr, window_id: u64, pointer: remote_display.Pointer_Body) -> (err: string, ok: bool) {
	state := (^Fake_Transport_State)(user_data)
	state.send_pointer_calls += 1
	state.last_pointer_window = window_id
	state.last_pointer = pointer
	if state.fail_send_pointer {
		return state.send_pointer_err, false
	}
	return "", true
}

@(private = "file")
fake_read_log_facts :: proc(user_data: rawptr, query: Log_Facts_Query, allocator: mem.Allocator) -> (facts: []Structured_Log_Fact, err: string, ok: bool) {
	_ = allocator
	state := (^Fake_Transport_State)(user_data)
	state.read_log_facts_calls += 1
	state.last_log_query = Log_Facts_Query {
		module_filter    = strings.clone(query.module_filter, context.temp_allocator),
		fact_name_filter = strings.clone(query.fact_name_filter, context.temp_allocator),
		sequence_start   = query.sequence_start,
		sequence_end     = query.sequence_end,
		max_records      = query.max_records,
	}
	if state.fail_read_log_facts {
		return nil, state.read_log_facts_err, false
	}
	return state.next_log_facts, "", true
}

@(private = "file")
make_fake_transport :: proc(state: ^Fake_Transport_State) -> Machine_Transport {
	return Machine_Transport {
		user_data      = state,
		eval_lex       = fake_eval_lex,
		read_screen    = fake_read_screen,
		send_key       = fake_send_key,
		send_pointer   = fake_send_pointer,
		read_log_facts = fake_read_log_facts,
	}
}

@(private = "file")
make_test_key :: proc(seed: u8) -> (key: [32]u8) {
	for index in 0 ..< len(key) {
		key[index] = seed + u8(index)
	}
	return key
}

@(private = "file")
make_full_policy :: proc(client_key: [32]u8) -> contract.Bridge_Client_Policy {
	key_copy := client_key
	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = 0,
		grantee_identity_hash = blake3.hash(key_copy[:]),
		authorities_word      = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input}),
		target_window_count   = 2,
		target_window_ids     = {0 = 101, 1 = 202},
		duration_ms           = wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	_ = wide_grants.wide_grant_terms_seal(&terms)

	return contract.Bridge_Client_Policy {
		client_key_public     = client_key,
		principal_id          = 0,
		permissions_word      = contract.bridge_permissions_to_word({.Eval_Lex, .Read_Screen, .Send_Input, .Read_Log_Facts}),
		remote_uses_word      = remote.client_uses_word({.Calls, .View, .Input}),
		has_wide_grant        = true,
		wide_grant_serial     = 7,
		wide_grant_state_word = u64(wide_grants.Wide_Grant_State.Active),
		wide_grant_terms      = terms,
		wide_grant_created_ms = 1_000,
		wide_grant_expires_ms = 1_000 + wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS,
		collector_available   = true,
	}
}

@(private = "file")
parse_json_object :: proc(t: ^testing.T, text: string) -> json.Object {
	parsed, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	testing.expectf(t, err == .None, "response is not valid JSON (%v): %s", err, text)
	obj, is_obj := parsed.(json.Object)
	testing.expectf(t, is_obj, "response is not a JSON object: %s", text)
	version, is_str := obj["jsonrpc"].(json.String)
	testing.expectf(t, is_str && version == "2.0", "jsonrpc field missing or not 2.0: %s", text)
	return obj
}

@(private = "file")
expect_json_result :: proc(t: ^testing.T, text: string) -> json.Object {
	root := parse_json_object(t, text)
	_, has_error := root["error"]
	testing.expectf(t, !has_error, "expected result but got error: %s", text)
	raw_result, has_result := root["result"]
	testing.expectf(t, has_result, "missing result field: %s", text)
	res_obj, is_obj := raw_result.(json.Object)
	testing.expectf(t, is_obj, "result field is not an object: %s", text)
	return res_obj
}

@(private = "file")
expect_json_error :: proc(
	t: ^testing.T,
	text: string,
	expected_code: Json_Rpc_Error_Code,
	expected_status: contract.Bridge_Status,
	expected_refusal: contract.Bridge_Refusal,
) {
	root := parse_json_object(t, text)
	_, has_result := root["result"]
	testing.expectf(t, !has_result, "expected error but got result: %s", text)
	raw_error, has_error := root["error"]
	testing.expectf(t, has_error, "missing error field: %s", text)
	err_obj, is_obj := raw_error.(json.Object)
	testing.expectf(t, is_obj, "error field is not an object: %s", text)
	code_val, code_ok := err_obj["code"].(json.Integer)
	testing.expectf(t, code_ok && code_val == i64(expected_code), "expected error code %d, got %v in %s", i64(expected_code), err_obj["code"], text)
	status_val, status_ok := err_obj["status"].(json.String)
	testing.expectf(t, status_ok && status_val == contract.bridge_status_name(expected_status), "expected status %s, got %v in %s", contract.bridge_status_name(expected_status), err_obj["status"], text)
	refusal_val, refusal_ok := err_obj["refusal"].(json.String)
	testing.expectf(t, refusal_ok && refusal_val == contract.bridge_refusal_name(expected_refusal), "expected refusal %s, got %v in %s", contract.bridge_refusal_name(expected_refusal), err_obj["refusal"], text)
}

@(test)
test_eval_lex_structured_values_and_tables :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x11)), make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	// Integer value
	state.next_lex_result = Lex_Eval_Result{value_kind = .Integer, integer_value = 4}
	resp := bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":1,"method":"eval_lex","params":{"line":"monitor.count(\"processors\")"}}`)
	res := expect_json_result(t, resp)
	testing.expect_value(t, res["status"].(json.String), "Ok")
	testing.expect_value(t, res["value_kind"].(json.String), "integer")
	testing.expect_value(t, res["value"].(json.Integer), i64(4))
	testing.expect_value(t, state.eval_lex_calls, 1)
	testing.expect_value(t, state.last_lex_line, `monitor.count("processors")`)

	// Boolean value
	state.next_lex_result = Lex_Eval_Result{value_kind = .Boolean, bool_value = true}
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":"req-bool","method":"eval_lex","params":{"line":"plans.status()"}}`)
	root := parse_json_object(t, resp)
	testing.expect_value(t, root["id"].(json.String), "req-bool")
	res = expect_json_result(t, resp)
	testing.expect_value(t, res["value_kind"].(json.String), "boolean")
	testing.expect_value(t, res["value"].(json.Boolean), true)

	// Text value with special characters requiring JSON escaping
	state.next_lex_result = Lex_Eval_Result{value_kind = .Text, text_value = "line1\n\"quoted\"\\tail"}
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":3,"method":"eval_lex","params":{"line":"log.fact_records(\"lex\")"}}`)
	res = expect_json_result(t, resp)
	testing.expect_value(t, res["value_kind"].(json.String), "text")
	testing.expect_value(t, res["value"].(json.String), "line1\n\"quoted\"\\tail")

	// Enum member value
	state.next_lex_result = Lex_Eval_Result{value_kind = .Enum_Member, text_value = ".french"}
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":4,"method":"eval_lex","params":{"line":"monitor.count(.french)"}}`)
	res = expect_json_result(t, resp)
	testing.expect_value(t, res["value_kind"].(json.String), "enum")
	testing.expect_value(t, res["value"].(json.String), ".french")

	// Structured Table result (never scraped text)
	cols := []string{"slot", "name"}
	row0 := []string{"1", "root"}
	row1 := []string{"2", "compositor"}
	rows := [][]string{row0, row1}
	state.next_lex_result = Lex_Eval_Result {
		value_kind  = .Table,
		record_name = "Process",
		columns     = cols,
		rows        = rows,
		total_rows  = 12,
	}
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":5,"method":"eval_lex","params":{"line":"monitor.processes()"}}`)
	res = expect_json_result(t, resp)
	testing.expect_value(t, res["value_kind"].(json.String), "table")
	testing.expect_value(t, res["record_name"].(json.String), "Process")
	testing.expect_value(t, res["total_rows"].(json.Integer), i64(12))
	json_cols := res["columns"].(json.Array)
	testing.expect_value(t, len(json_cols), 2)
	testing.expect_value(t, json_cols[0].(json.String), "slot")
	testing.expect_value(t, json_cols[1].(json.String), "name")
	json_rows := res["rows"].(json.Array)
	testing.expect_value(t, len(json_rows), 2)
	testing.expect_value(t, json_rows[1].(json.Array)[1].(json.String), "compositor")

	// Transport failure propagates as Transport_Error (-32003)
	state.fail_eval_lex = true
	state.eval_lex_err = "peer disconnected"
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":6,"method":"eval_lex","params":{"line":"monitor.processes()"}}`)
	expect_json_error(t, resp, .Transport_Error, .Transport_Error, .None)
}

@(test)
test_read_screen_snapshot_and_bounds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x22)), make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	fake_png := []u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04}
	expected_digest := blake3.hash(fake_png)
	state.next_screen_result = Screen_Snapshot_Result {
		format       = .Png,
		width        = 1280,
		height       = 720,
		frame_serial = 99,
		bytes        = fake_png,
	}

	// Out-of-bounds parameters refused before touching transport
	bad_cases := []string {
		`{"jsonrpc":"2.0","id":1,"method":"read_screen","params":{"format":"jpeg"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"read_screen","params":{"max_width":99999}}`,
		`{"jsonrpc":"2.0","id":3,"method":"read_screen","params":{"wait_settled_ms":30001}}`,
		`{"jsonrpc":"2.0","id":4,"method":"read_screen","params":{"max_width":-1}}`,
	}
	for req in bad_cases {
		resp := bridge_handle_json_line(&bridge, req)
		expect_json_error(t, resp, .Invalid_Params, .Refused, .Invalid_Field)
	}
	testing.expect_value(t, state.read_screen_calls, 0)

	// An agent-supplied output_path is never read: with no snapshot folder,
	// no file is written, and the snapshot comes back in the response.
	tmp_dir, tmp_err := os.make_directory_temp("", "agent_bridge_snap_*", context.temp_allocator)
	testing.expect_value(t, tmp_err, nil)
	defer _ = os.remove_all(tmp_dir)
	out_file := fmt.tprintf("%s/snap.png", tmp_dir)

	req_line := fmt.tprintf(`{{"jsonrpc":"2.0","id":10,"method":"read_screen","params":{{"format":"png","max_width":1280,"max_height":720,"wait_settled_ms":500,"output_path":%q}}}}`, out_file)
	resp := bridge_handle_json_line(&bridge, req_line)
	res := expect_json_result(t, resp)
	testing.expect_value(t, state.read_screen_calls, 1)
	testing.expect_value(t, state.last_screen_request.format, contract.Screen_Picture_Format.Png)
	testing.expect_value(t, state.last_screen_request.max_width, u32(1280))
	testing.expect_value(t, state.last_screen_request.wait_settled_ms, u32(500))
	testing.expect_value(t, res["format"].(json.String), "png")
	testing.expect_value(t, res["width"].(json.Integer), i64(1280))
	testing.expect_value(t, res["height"].(json.Integer), i64(720))
	testing.expect_value(t, res["frame_serial"].(json.Integer), i64(99))
	testing.expect_value(t, res["byte_count"].(json.Integer), i64(len(fake_png)))
	_, has_saved_path := res["saved_path"]
	testing.expect(t, !has_saved_path, "no file is written without a snapshot folder")
	testing.expect(t, !os.exists(out_file), "the agent-supplied output_path was written")

	expected_hex := string(hex.encode(expected_digest[:], context.temp_allocator))
	testing.expect_value(t, res["blake3"].(json.String), expected_hex)
	decoded_b64, b64_err := base64.decode(res["data_base64"].(json.String), allocator = context.temp_allocator)
	testing.expect_value(t, b64_err, nil)
	testing.expect_value(t, string(decoded_b64), string(fake_png))

	// raw_bgrx format accepted
	state.next_screen_result.format = .Raw_Bgrx
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":11,"method":"read_screen","params":{"format":"raw_bgrx"}}`)
	res = expect_json_result(t, resp)
	testing.expect_value(t, res["format"].(json.String), "raw_bgrx")
	testing.expect_value(t, state.last_screen_request.format, contract.Screen_Picture_Format.Raw_Bgrx)
}

@(test)
test_send_key_and_send_pointer_window_scope_and_act_chain :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x33)), make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	// Out-of-scope windows (0 and 999) refused without calling transport or growing act log
	resp := bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":1,"method":"send_key","params":{"window_id":0,"code":30,"character":97,"pressed":true,"modifiers":0}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Window_Not_In_Scope)
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":2,"method":"send_key","params":{"window_id":999,"code":30,"character":97,"pressed":true,"modifiers":0}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Window_Not_In_Scope)
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":3,"method":"send_pointer","params":{"window_id":999,"x":100,"y":200,"buttons":1,"wheel":0}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Window_Not_In_Scope)
	testing.expect_value(t, state.send_key_calls, 0)
	testing.expect_value(t, state.send_pointer_calls, 0)
	testing.expect_value(t, len(bridge.act_log.records), 0)

	// Invalid key/pointer fields refused at payload validation border
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":4,"method":"send_key","params":{"window_id":101,"code":0,"pressed":true}}`)
	expect_json_error(t, resp, .Invalid_Params, .Refused, .Invalid_Field)
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":5,"method":"send_pointer","params":{"window_id":101,"x":99999,"y":10,"buttons":0}}`)
	expect_json_error(t, resp, .Invalid_Params, .Refused, .Invalid_Field)
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":6,"method":"send_pointer","params":{"window_id":101,"x":10,"y":10,"buttons":4}}`)
	expect_json_error(t, resp, .Invalid_Params, .Refused, .Invalid_Field)
	testing.expect_value(t, state.send_key_calls, 0)
	testing.expect_value(t, state.send_pointer_calls, 0)

	// Valid send_key to in-scope window 101
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":10,"method":"send_key","params":{"window_id":101,"code":30,"character":97,"pressed":true,"modifiers":1}}`)
	res := expect_json_result(t, resp)
	testing.expect_value(t, res["delivered"].(json.Boolean), true)
	testing.expect_value(t, res["window_id"].(json.Integer), i64(101))
	testing.expect_value(t, res["act_sequence"].(json.Integer), i64(0))
	testing.expect_value(t, len(res["act_record_hash"].(json.String)), 64)
	testing.expect_value(t, state.send_key_calls, 1)
	testing.expect_value(t, state.last_key_window, u64(101))
	testing.expect_value(t, state.last_key.code, u32(30))
	testing.expect_value(t, state.last_key.character, u32(97))
	testing.expect_value(t, state.last_key.pressed, u32(1))
	testing.expect_value(t, state.last_key.modifiers, u32(1))

	// Valid send_pointer move (buttons=0) and click (buttons=1) to in-scope window 202
	clock.now_ms = 2_050
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":11,"method":"send_pointer","params":{"window_id":202,"x":320,"y":240,"buttons":0,"wheel":0}}`)
	res = expect_json_result(t, resp)
	testing.expect_value(t, res["act_sequence"].(json.Integer), i64(1))
	testing.expect_value(t, state.send_pointer_calls, 1)
	testing.expect_value(t, state.last_pointer_window, u64(202))
	testing.expect_value(t, state.last_pointer.x, u32(320))
	testing.expect_value(t, state.last_pointer.y, u32(240))

	clock.now_ms = 2_100
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":12,"method":"send_pointer","params":{"window_id":202,"x":320,"y":240,"buttons":1,"wheel":-3}}`)
	res = expect_json_result(t, resp)
	testing.expect_value(t, res["act_sequence"].(json.Integer), i64(2))
	testing.expect_value(t, state.send_pointer_calls, 2)
	testing.expect_value(t, state.last_pointer.buttons, u32(1))
	testing.expect_value(t, state.last_pointer.wheel, i32(-3))

	// Verify BLAKE3 hash chain and recorded act kinds
	testing.expect_value(t, len(bridge.act_log.records), 3)
	testing.expect_value(t, bridge.act_log.records[0].act_kind_word, u64(wide_grants.Act_Kind.Key_Injected))
	testing.expect_value(t, bridge.act_log.records[1].act_kind_word, u64(wide_grants.Act_Kind.Pointer_Moved))
	testing.expect_value(t, bridge.act_log.records[2].act_kind_word, u64(wide_grants.Act_Kind.Pointer_Clicked))
	verify_refusal, failing_idx := bridge_act_log_verify(&bridge.act_log)
	testing.expect_value(t, verify_refusal, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, failing_idx, u64(0))

	// Expired wide grant at exact expiry boundary refuses input
	clock.now_ms = bridge.policy.wide_grant_expires_ms
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":13,"method":"send_key","params":{"window_id":101,"code":30,"pressed":false}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Wide_Grant_Expired)
	testing.expect_value(t, state.send_key_calls, 1)
}

@(test)
test_read_log_facts_queries_and_bounds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x44)), make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	// Out-of-bounds and invalid filter queries refused before touching transport
	bad_cases := []struct {
		line:    string,
		refusal: contract.Bridge_Refusal,
	}{
		{`{"jsonrpc":"2.0","id":1,"method":"read_log_facts","params":{"max_records":0}}`, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":2,"method":"read_log_facts","params":{"max_records":257}}`, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":3,"method":"read_log_facts","params":{"sequence_start":50,"sequence_end":10}}`, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":4,"method":"read_log_facts","params":{"module":"bad name"}}`, .Invalid_Text},
		{`{"jsonrpc":"2.0","id":5,"method":"read_log_facts","params":{"fact_name":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}`, .Invalid_Text},
	}
	for item in bad_cases {
		resp := bridge_handle_json_line(&bridge, item.line)
		expect_json_error(t, resp, .Invalid_Params, .Refused, item.refusal)
	}
	testing.expect_value(t, state.read_log_facts_calls, 0)

	// Valid query returns structured JSON facts
	fields := []Log_Fact_Field{{name = "slot", value = "4"}, {name = "status", value = "Ok"}}
	state.next_log_facts = []Structured_Log_Fact {
		{
			sequence     = 42,
			timestamp_ms = 12345,
			module_name  = "storage",
			fact_name    = "Mount_Ready",
			level        = "Info",
			fields       = fields,
		},
	}
	resp := bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":6,"method":"read_log_facts","params":{"module":"storage","fact_name":"Mount_Ready","sequence_start":40,"sequence_end":50,"max_records":16}}`)
	res := expect_json_result(t, resp)
	testing.expect_value(t, state.read_log_facts_calls, 1)
	testing.expect_value(t, state.last_log_query.module_filter, "storage")
	testing.expect_value(t, state.last_log_query.fact_name_filter, "Mount_Ready")
	testing.expect_value(t, state.last_log_query.sequence_start, u64(40))
	testing.expect_value(t, state.last_log_query.sequence_end, u64(50))
	testing.expect_value(t, state.last_log_query.max_records, u32(16))
	testing.expect_value(t, res["count"].(json.Integer), i64(1))
	facts_arr := res["facts"].(json.Array)
	testing.expect_value(t, len(facts_arr), 1)
	first := facts_arr[0].(json.Object)
	testing.expect_value(t, first["sequence"].(json.Integer), i64(42))
	testing.expect_value(t, first["module"].(json.String), "storage")
	testing.expect_value(t, first["fact_name"].(json.String), "Mount_Ready")
	testing.expect_value(t, first["level"].(json.String), "Info")
	first_fields := first["fields"].(json.Object)
	testing.expect_value(t, first_fields["slot"].(json.String), "4")
	testing.expect_value(t, first_fields["status"].(json.String), "Ok")
}

@(test)
test_unauthorized_permissions_and_remote_uses_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}

	// Only Read_Log_Facts permission + Calls remote use
	policy := make_full_policy(make_test_key(0x55))
	policy.permissions_word = contract.bridge_permissions_to_word({.Read_Log_Facts})
	policy.remote_uses_word = remote.client_uses_word({.Calls})

	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, policy, make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	resp := bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":1,"method":"eval_lex","params":{"line":"monitor.processes()"}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Permission_Denied)

	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":2,"method":"read_screen","params":{"format":"png"}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Permission_Denied)

	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":3,"method":"send_key","params":{"window_id":101,"code":30,"pressed":true}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Permission_Denied)

	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":4,"method":"send_pointer","params":{"window_id":101,"x":10,"y":20,"buttons":0}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Permission_Denied)

	testing.expect_value(t, state.eval_lex_calls, 0)
	testing.expect_value(t, state.read_screen_calls, 0)
	testing.expect_value(t, state.send_key_calls, 0)
	testing.expect_value(t, state.send_pointer_calls, 0)

	// Allowed capability still runs
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":5,"method":"read_log_facts","params":{}}`)
	_ = expect_json_result(t, resp)
	testing.expect_value(t, state.read_log_facts_calls, 1)

	// Bridge permission set for Read_Screen & Send_Input, but remote key lacks View/Input
	bridge.policy.permissions_word = contract.bridge_permissions_to_word({.Eval_Lex, .Read_Screen, .Send_Input, .Read_Log_Facts})
	bridge.policy.remote_uses_word = remote.client_uses_word({.Calls})
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":6,"method":"read_screen","params":{"format":"png"}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Permission_Denied)

	// View without Input refuses Send_Key and Send_Pointer
	bridge.policy.remote_uses_word = remote.client_uses_word({.Calls, .View})
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":7,"method":"send_key","params":{"window_id":101,"code":30,"pressed":true}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Permission_Denied)
	testing.expect_value(t, state.send_key_calls, 0)

	// Missing client key refused with Client_Key_Missing
	bridge.policy.client_key_public = {}
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":8,"method":"eval_lex","params":{"line":"monitor.processes()"}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Client_Key_Missing)
	testing.expect_value(t, state.eval_lex_calls, 0)
}

// The snapshot folder of the operator: each file has a name of the bridge,
// inside that folder only; an agent path, a traversal, a symbolic link at
// the name and a folder that became a link are refused.
@(test)
test_snapshot_folder_of_the_operator_is_the_only_place_of_a_file :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x23)), make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock
	state.next_screen_result = Screen_Snapshot_Result{format = .Raw_Bgrx, width = 1, height = 1, frame_serial = 1, bytes = []u8{1, 2, 3, 4}}

	root, root_error := os.make_directory_temp("", "agent_bridge_folder_*", context.temp_allocator)
	testing.expect_value(t, root_error, nil)
	defer _ = os.remove_all(root)
	snapshots := fmt.tprintf("%s/snapshots", root)
	testing.expect_value(t, os.make_directory(snapshots), nil)
	outside := fmt.tprintf("%s/outside", root)
	testing.expect_value(t, os.make_directory(outside), nil)

	// The folder check refuses an empty path, a missing folder, a file and a link.
	_, problem := snapshot_directory_check("")
	testing.expect(t, problem != "")
	_, problem = snapshot_directory_check(fmt.tprintf("%s/missing", root))
	testing.expect(t, problem != "")
	plain_file := fmt.tprintf("%s/plain", root)
	testing.expect_value(t, os.write_entire_file(plain_file, []u8{0}), nil)
	_, problem = snapshot_directory_check(plain_file)
	testing.expect(t, problem != "")
	link_folder := fmt.tprintf("%s/link", root)
	testing.expect_value(t, os.symlink(outside, link_folder), nil)
	_, problem = snapshot_directory_check(link_folder)
	testing.expect(t, problem != "", "a symbolic link to a folder was accepted")

	checked, checked_problem := snapshot_directory_check(snapshots)
	testing.expect_value(t, checked_problem, "")
	defer delete(checked)
	bridge.snapshot_directory = checked

	// Each path that an agent names is ignored: the file has the name of the bridge.
	agent_paths := [?]string{fmt.tprintf("%s/evil.bgrx", outside), "../outside/evil.bgrx", "/tmp/../etc/evil"}
	for agent_path, index in agent_paths {
		line := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"read_screen","params":{{"format":"raw_bgrx","output_path":%q}}}}`, index + 1, agent_path)
		res := expect_json_result(t, bridge_handle_json_line(&bridge, line))
		expected := fmt.tprintf("%s/snapshot_%d.bgrx", checked, index + 1)
		testing.expect_value(t, res["saved_path"].(json.String), expected)
		written, read_error := os.read_entire_file(expected, context.temp_allocator)
		testing.expect_value(t, read_error, nil)
		testing.expect_value(t, string(written), "\x01\x02\x03\x04")
	}
	outside_entries, list_error := os.read_directory_by_path(outside, -1, context.temp_allocator)
	testing.expect_value(t, list_error, nil)
	testing.expect_value(t, len(outside_entries), 0)

	// A symbolic link planted at the next name is refused, never followed.
	target := fmt.tprintf("%s/target", outside)
	testing.expect_value(t, os.symlink(target, fmt.tprintf("%s/snapshot_4.bgrx", checked)), nil)
	expect_json_error(t, bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":9,"method":"read_screen","params":{"format":"raw_bgrx"}}`), .Transport_Error, .Transport_Error, .None)
	testing.expect(t, !os.exists(target), "the bridge followed a symbolic link")

	// A folder that became a link after the check is refused.
	testing.expect_value(t, os.remove_all(checked), nil)
	testing.expect_value(t, os.symlink(outside, checked), nil)
	expect_json_error(t, bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":10,"method":"read_screen","params":{"format":"raw_bgrx"}}`), .Transport_Error, .Transport_Error, .None)
	outside_entries, list_error = os.read_directory_by_path(outside, -1, context.temp_allocator)
	testing.expect_value(t, list_error, nil)
	testing.expect_value(t, len(outside_entries), 0)
}

@(test)
test_grant_adding_plans_apply_and_sensitive_actions_await_principal_approval :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	state.next_lex_result = Lex_Eval_Result{value_kind = .Text, text_value = "applied"}
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x66)), make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

// plans.apply and plans.rollback wait for the principal whatever flags
	// the request carries: the bridge reads none of them.
	bypass_lines := [?]string{"plans.apply(1)", "plans.apply()", "plans.rollback()", "plans.rollback(1)"}
	bypass_fields := [?]string {
		``,
		`,"plan_diff":{"any_grant_added":false,"added_grants_count":0}`,
		`,"sensitive_action":false`,
		`,"sensitive_action":"Normal_Semantic_Read"`,
		`,"any_grant_added":false,"sensitive_action":false`,
		`,"plan_diff":{"any_grant_added":false},"sensitive_action":"Normal_Window_Input"`,
	}
	for line in bypass_lines {
		for fields in bypass_fields {
			req := fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"eval_lex","params":{{"line":%q%s}}}}`, line, fields)
			resp := bridge_handle_json_line(&bridge, req)
			expect_json_error(t, resp, .Awaiting_Principal_Approval, .Awaiting_Principal_Approval, .Principal_Approval_Required)
		}
	}

	// The same through a wire frame.
	for line in bypass_lines {
		frame := contract.Bridge_Command_Frame {
			command         = .Eval_Lex,
			request_id      = 7,
			principal_id    = bridge.policy.principal_id,
			client_key_hash = blake3.hash(bridge.policy.client_key_public[:]),
			payload         = transmute([]u8)line,
		}
		frame_buffer: [contract.COMMAND_HEADER_SIZE + 64]u8
		frame_size, encode_refusal := contract.encode_command_frame(&frame, frame_buffer[:])
		testing.expect_value(t, encode_refusal, contract.Bridge_Refusal.None)
		response_buffer: [contract.RESPONSE_HEADER_SIZE + 64]u8
		_, status, refusal := bridge_handle_wire_frame(&bridge, frame_buffer[:frame_size], response_buffer[:])
		testing.expect_value(t, status, contract.Bridge_Status.Awaiting_Principal_Approval)
		testing.expect_value(t, refusal, contract.Bridge_Refusal.Principal_Approval_Required)
	}

	// A comment cannot hide a second line: each such line is refused.
	for line in ([?]string{"# comment\nplans.apply(1)", "-- comment\nstorage.write(\"a\", \"b\")", "// comment\nsettings.appearance(1)", "monitor.processes() // plans.apply(1)", "plan |> plans.apply()"}) {
		req := fmt.tprintf(`{{"jsonrpc":"2.0","id":2,"method":"eval_lex","params":{{"line":%q,"sensitive_action":false}}}}`, line)
		resp := bridge_handle_json_line(&bridge, req)
		expect_json_error(t, resp, .Refused, .Refused, .Invalid_Text)
	}

	// Calls outside the read-only list cannot self-approve.
	for line in ([?]string{`compositor.wide_grant_indicator(0, 0)`, `settings.appearance(1)`, `storage.write("a", "b")`, `debugger.attach(1)`, `remote.allow("abcd")`}) {
		req := fmt.tprintf(`{{"jsonrpc":"2.0","id":4,"method":"eval_lex","params":{{"line":%q,"sensitive_action":"Normal_Semantic_Read"}}}}`, line)
		resp := bridge_handle_json_line(&bridge, req)
		expect_json_error(t, resp, .Awaiting_Principal_Approval, .Awaiting_Principal_Approval, .Principal_Approval_Required)
	}

	testing.expect_value(t, state.eval_lex_calls, 0)
	testing.expect_value(t, state.read_screen_calls, 0)
	testing.expect_value(t, state.send_key_calls, 0)

	// A read-only call runs, whatever the request says of it.
	resp := bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":8,"method":"eval_lex","params":{"line":"monitor.processes()","sensitive_action":"Passphrase_Or_Unlock_Dialog"}}`)
	res := expect_json_result(t, resp)
	testing.expect_value(t, res["status"].(json.String), "Ok")
	testing.expect_value(t, state.eval_lex_calls, 1)
}
@(test)
test_collector_full_fails_closed_and_detects_tampering :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	// Bounded collector capacity of 2 records
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x77)), make_fake_transport(&state), act_capacity = 2))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	// First two input acts fill the collector
	resp := bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":1,"method":"send_key","params":{"window_id":101,"code":30,"pressed":true}}`)
	_ = expect_json_result(t, resp)
	clock.now_ms = 2_010
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":2,"method":"send_pointer","params":{"window_id":202,"x":50,"y":60,"buttons":1}}`)
	_ = expect_json_result(t, resp)
	testing.expect_value(t, state.send_key_calls, 1)
	testing.expect_value(t, state.send_pointer_calls, 1)
	testing.expect_value(t, len(bridge.act_log.records), 2)

	// Collector is now full: subsequent key and pointer inputs fail closed with Act_Log_Required
	clock.now_ms = 2_020
	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":3,"method":"send_key","params":{"window_id":101,"code":30,"pressed":false}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Act_Log_Required)

	resp = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":4,"method":"send_pointer","params":{"window_id":202,"x":51,"y":61,"buttons":0}}`)
	expect_json_error(t, resp, .Refused, .Refused, .Act_Log_Required)

	testing.expect_value(t, state.send_key_calls, 1)
	testing.expect_value(t, state.send_pointer_calls, 1)
	testing.expect_value(t, len(bridge.act_log.records), 2)

	// Direct append refuses full log and backward timestamp
	_, full_refusal := bridge_act_log_append(&bridge.act_log, 7, 2_030, .Key_Injected, 101, 1, 2)
	testing.expect_value(t, full_refusal, wide_grants.Wide_Grant_Refusal.Act_Log_Full)

	small_log: Bridge_Act_Log
	testing.expect(t, bridge_act_log_init(&small_log, 4))
	defer bridge_act_log_destroy(&small_log)
	_, r0 := bridge_act_log_append(&small_log, 7, 5_000, .Key_Injected, 101, 30, 97)
	testing.expect_value(t, r0, wide_grants.Wide_Grant_Refusal.None)
	_, back_r := bridge_act_log_append(&small_log, 7, 4_999, .Key_Injected, 101, 30, 97)
	testing.expect_value(t, back_r, wide_grants.Wide_Grant_Refusal.Chain_Tampered)

	// Tampering with an appended record breaks verification
	bridge.act_log.records[0].detail_word_0 ~= 1
	tamper_refusal, tamper_idx := bridge_act_log_verify(&bridge.act_log)
	testing.expect_value(t, tamper_refusal, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, tamper_idx, u64(0))
}

@(test)
test_wire_command_modab1_roundtrips_and_adversarial_frames :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	client_key := make_test_key(0x88)
	key_hash := blake3.hash(client_key[:])
	state: Fake_Transport_State
	state.next_lex_result = Lex_Eval_Result{value_kind = .Text, text_value = "ok-lex"}
	state.next_screen_result = Screen_Snapshot_Result{format = .Png, width = 640, height = 480, frame_serial = 5, bytes = []u8{1, 2, 3, 4}}
	state.next_log_facts = []Structured_Log_Fact{{sequence = 1, module_name = "root", fact_name = "Ready", level = "Info"}}

	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(client_key), make_fake_transport(&state), act_capacity = 2))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	encode_cmd_hex :: proc(t: ^testing.T, frame: ^contract.Bridge_Command_Frame) -> string {
		buf: [512]u8
		n, r := contract.encode_command_frame(frame, buf[:])
		testing.expect_value(t, r, contract.Bridge_Refusal.None)
		return string(hex.encode(buf[:n], context.temp_allocator))
	}

	decode_wire_json_response :: proc(t: ^testing.T, json_resp: string) -> contract.Bridge_Response_Frame {
		res := expect_json_result(t, json_resp)
		resp_hex := res["response_frame_hex"].(json.String)
		raw, ok := hex.decode(transmute([]u8)resp_hex, context.temp_allocator)
		testing.expect(t, ok)
		decoded, dr := contract.decode_response_frame(raw)
		testing.expect_value(t, dr, contract.Bridge_Refusal.None)
		return decoded
	}

	wire_json_req :: proc(id: int, hex_str: string) -> string {
		return fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"wire_command","params":{{"frame_hex":%q}}}}`, id, hex_str)
	}

	// 1. Eval_Lex over wire_command
	lex_frame := contract.Bridge_Command_Frame {
		command         = .Eval_Lex,
		request_id      = 101,
		principal_id    = 0,
		client_key_hash = key_hash,
		payload         = transmute([]u8)string("monitor.processes()"),
	}
	resp_json := bridge_handle_json_line(&bridge, wire_json_req(1, encode_cmd_hex(t, &lex_frame)))
	wire_resp := decode_wire_json_response(t, resp_json)
	testing.expect_value(t, wire_resp.status, contract.Bridge_Status.Ok)
	testing.expect_value(t, wire_resp.request_id, u64(101))
	testing.expect_value(t, string(wire_resp.payload), "text:ok-lex")

	// 2. Read_Screen over wire_command
	screen_payload_buf: [contract.READ_SCREEN_PAYLOAD_SIZE]u8
	screen_payload := contract.Read_Screen_Payload{format = .Png, max_width = 640, max_height = 480, wait_settled_ms = 100}
	sp_n, sp_r := contract.encode_read_screen_payload(&screen_payload, screen_payload_buf[:])
	testing.expect_value(t, sp_r, contract.Bridge_Refusal.None)
	screen_frame := contract.Bridge_Command_Frame {
		command         = .Read_Screen,
		request_id      = 102,
		principal_id    = 0,
		client_key_hash = key_hash,
		payload         = screen_payload_buf[:sp_n],
	}
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(2, encode_cmd_hex(t, &screen_frame)))
	wire_resp = decode_wire_json_response(t, resp_json)
	testing.expect_value(t, wire_resp.status, contract.Bridge_Status.Ok)
	testing.expect_value(t, len(wire_resp.payload), 4)

	// 3. Send_Key over wire_command records act hash and sequence 0
	key_payload_buf: [contract.SEND_KEY_PAYLOAD_SIZE]u8
	key_payload := contract.Send_Key_Payload{key = {code = 30, character = 'a', pressed = 1, modifiers = 0}}
	kp_n, kp_r := contract.encode_send_key_payload(&key_payload, key_payload_buf[:])
	testing.expect_value(t, kp_r, contract.Bridge_Refusal.None)
	key_frame := contract.Bridge_Command_Frame {
		command          = .Send_Key,
		request_id       = 103,
		principal_id     = 0,
		grant_serial     = 7,
		target_window_id = 101,
		client_key_hash  = key_hash,
		payload          = key_payload_buf[:kp_n],
	}
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(3, encode_cmd_hex(t, &key_frame)))
	wire_resp = decode_wire_json_response(t, resp_json)
	testing.expect_value(t, wire_resp.status, contract.Bridge_Status.Ok)
	testing.expect_value(t, wire_resp.act_sequence_number, u64(0))
	testing.expect_value(t, wire_resp.act_record_hash, bridge.act_log.records[0].record_hash)

	// 4. Send_Pointer over wire_command records act sequence 1
	ptr_payload_buf: [contract.SEND_POINTER_PAYLOAD_SIZE]u8
	ptr_payload := contract.Send_Pointer_Payload{pointer = {x = 120, y = 240, buttons = 1, wheel = 0}}
	pp_n, pp_r := contract.encode_send_pointer_payload(&ptr_payload, ptr_payload_buf[:])
	testing.expect_value(t, pp_r, contract.Bridge_Refusal.None)
	ptr_frame := contract.Bridge_Command_Frame {
		command          = .Send_Pointer,
		request_id       = 104,
		principal_id     = 0,
		grant_serial     = 7,
		target_window_id = 202,
		client_key_hash  = key_hash,
		payload          = ptr_payload_buf[:pp_n],
	}
	clock.now_ms = 2_010
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(4, encode_cmd_hex(t, &ptr_frame)))
	wire_resp = decode_wire_json_response(t, resp_json)
	testing.expect_value(t, wire_resp.status, contract.Bridge_Status.Ok)
	testing.expect_value(t, wire_resp.act_sequence_number, u64(1))
	testing.expect_value(t, wire_resp.act_record_hash, bridge.act_log.records[1].record_hash)

	// 5. Read_Log_Facts over wire_command
	log_payload_buf: [256]u8
	log_payload := contract.Read_Log_Facts_Payload{max_records = 10}
	lp_n, lp_r := contract.encode_read_log_facts_payload(&log_payload, log_payload_buf[:])
	testing.expect_value(t, lp_r, contract.Bridge_Refusal.None)
	log_frame := contract.Bridge_Command_Frame {
		command         = .Read_Log_Facts,
		request_id      = 105,
		principal_id    = 0,
		client_key_hash = key_hash,
		payload         = log_payload_buf[:lp_n],
	}
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(5, encode_cmd_hex(t, &log_frame)))
	wire_resp = decode_wire_json_response(t, resp_json)
	testing.expect_value(t, wire_resp.status, contract.Bridge_Status.Ok)
	testing.expect_value(t, string(wire_resp.payload), "1")

	// Collector is full (capacity=2): next wire Send_Key fails closed with Act_Log_Required
	key_frame.request_id = 106
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(6, encode_cmd_hex(t, &key_frame)))
	expect_json_error(t, resp_json, .Refused, .Refused, .Act_Log_Required)

	// plans.apply in wire Eval_Lex stops with Awaiting_Principal_Approval
	apply_frame := contract.Bridge_Command_Frame {
		command         = .Eval_Lex,
		request_id      = 107,
		principal_id    = 0,
		client_key_hash = key_hash,
		payload         = transmute([]u8)string("plans.apply(1)"),
	}
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(7, encode_cmd_hex(t, &apply_frame)))
	expect_json_error(t, resp_json, .Awaiting_Principal_Approval, .Awaiting_Principal_Approval, .Principal_Approval_Required)

	// Mismatched client_key_hash, principal_id, and grant_serial are refused
	wrong_key_frame := lex_frame
	wrong_key_frame.client_key_hash[0] ~= 0xFF
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(8, encode_cmd_hex(t, &wrong_key_frame)))
	expect_json_error(t, resp_json, .Refused, .Refused, .Permission_Denied)

	wrong_principal_frame := lex_frame
	wrong_principal_frame.principal_id = 99
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(9, encode_cmd_hex(t, &wrong_principal_frame)))
	expect_json_error(t, resp_json, .Refused, .Refused, .Permission_Denied)

	wrong_grant_frame := key_frame
	wrong_grant_frame.grant_serial = 999
	resp_json = bridge_handle_json_line(&bridge, wire_json_req(10, encode_cmd_hex(t, &wrong_grant_frame)))
	expect_json_error(t, resp_json, .Refused, .Refused, .Wide_Grant_Not_Active)

	// Malformed hex and corrupted MODAB1 wire frames
	resp_json = bridge_handle_json_line(&bridge, `{"jsonrpc":"2.0","id":11,"method":"wire_command","params":{"frame_hex":"not-hex!!"}}`)
	expect_json_error(t, resp_json, .Invalid_Params, .Refused, .Bad_Header)

	raw_buf: [256]u8
	written, _ := contract.encode_command_frame(&lex_frame, raw_buf[:])
	resp_out: [256]u8

	// Truncated header
	_, st, ref := bridge_handle_wire_frame(&bridge, raw_buf[:contract.COMMAND_HEADER_SIZE - 1], resp_out[:])
	testing.expect_value(t, st, contract.Bridge_Status.Refused)
	testing.expect_value(t, ref, contract.Bridge_Refusal.Truncated)

	// Bad magic
	bad_magic := raw_buf
	bad_magic[0] = 'X'
	_, st, ref = bridge_handle_wire_frame(&bridge, bad_magic[:written], resp_out[:])
	testing.expect_value(t, st, contract.Bridge_Status.Refused)
	testing.expect_value(t, ref, contract.Bridge_Refusal.Bad_Header)

	// Non-zero reserved word
	bad_reserved := raw_buf
	byte_order.write_u32_little_endian(bad_reserved[:], 80, 1)
	_, st, ref = bridge_handle_wire_frame(&bridge, bad_reserved[:written], resp_out[:])
	testing.expect_value(t, st, contract.Bridge_Status.Refused)
	testing.expect_value(t, ref, contract.Bridge_Refusal.Bad_Header)

	// Trailing byte
	trailing := raw_buf
	trailing[written] = 0xAA
	_, st, ref = bridge_handle_wire_frame(&bridge, trailing[:written + 1], resp_out[:])
	testing.expect_value(t, st, contract.Bridge_Status.Refused)
	testing.expect_value(t, ref, contract.Bridge_Refusal.Trailing_Bytes)

	// Unknown command word
	bad_cmd := raw_buf
	byte_order.write_u32_little_endian(bad_cmd[:], 8, 99)
	_, st, ref = bridge_handle_wire_frame(&bridge, bad_cmd[:written], resp_out[:])
	testing.expect_value(t, st, contract.Bridge_Status.Refused)
	testing.expect_value(t, ref, contract.Bridge_Refusal.Unknown_Command)

	// Verify only the 5 valid commands ever reached the transport
	testing.expect_value(t, state.eval_lex_calls, 1)
	testing.expect_value(t, state.read_screen_calls, 1)
	testing.expect_value(t, state.send_key_calls, 1)
	testing.expect_value(t, state.send_pointer_calls, 1)
	testing.expect_value(t, state.read_log_facts_calls, 1)
}

@(test)
test_malformed_json_and_invalid_jsonrpc_requests :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state: Fake_Transport_State
	clock := Fake_Clock{now_ms = 2_000}
	bridge: Agent_Bridge
	testing.expect(t, bridge_init(&bridge, make_full_policy(make_test_key(0x99)), make_fake_transport(&state)))
	defer bridge_destroy(&bridge)
	bridge.clock_ms_proc = fake_clock_now_ms
	bridge.clock_user_data = &clock

	cases := []struct {
		line:    string,
		code:    Json_Rpc_Error_Code,
		refusal: contract.Bridge_Refusal,
	}{
		{"", .Parse_Error, .Bad_Header},
		{"   \t  ", .Parse_Error, .Bad_Header},
		{"{not valid json", .Parse_Error, .Bad_Header},
		{"[1, 2, 3]", .Invalid_Request, .Bad_Header},
		{`"plain-string"`, .Invalid_Request, .Bad_Header},
		{`{"jsonrpc":"1.0","id":1,"method":"eval_lex","params":{"line":"a"}}`, .Invalid_Request, .Bad_Header},
		{`{"id":1,"method":"eval_lex","params":{"line":"a"}}`, .Invalid_Request, .Bad_Header},
		{`{"jsonrpc":"2.0","id":[1],"method":"eval_lex","params":{"line":"a"}}`, .Invalid_Request, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":true,"method":"eval_lex","params":{"line":"a"}}`, .Invalid_Request, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":1}`, .Invalid_Request, .Unknown_Command},
		{`{"jsonrpc":"2.0","id":1,"method":123}`, .Invalid_Request, .Unknown_Command},
		{`{"jsonrpc":"2.0","id":1,"method":"does_not_exist","params":{}}`, .Method_Not_Found, .Unknown_Command},
		{`{"jsonrpc":"2.0","id":1,"method":"eval_lex","params":[1,2]}`, .Invalid_Params, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":1,"method":"eval_lex","params":{}}`, .Invalid_Params, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":1,"method":"send_key","params":{"window_id":101,"code":30}}`, .Invalid_Params, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":1,"method":"send_key","params":{"window_id":-1,"code":30,"pressed":true}}`, .Invalid_Params, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":1,"method":"send_pointer","params":{"window_id":101,"x":10}}`, .Invalid_Params, .Invalid_Field},
		{`{"jsonrpc":"2.0","id":1,"method":"wire_command","params":{}}`, .Invalid_Params, .Bad_Header},
	}

	for item in cases {
		resp := bridge_handle_json_line(&bridge, item.line)
		expect_json_error(t, resp, item.code, .Refused, item.refusal)
	}

	testing.expect_value(t, state.eval_lex_calls, 0)
	testing.expect_value(t, state.read_screen_calls, 0)
	testing.expect_value(t, state.send_key_calls, 0)
	testing.expect_value(t, state.send_pointer_calls, 0)
	testing.expect_value(t, state.read_log_facts_calls, 0)
}

@(test)
test_remote_transport_lifecycle_and_fail_closed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	remote_key := make_test_key(0xAA)

	// Invalid open arguments refused cleanly
	testing.expect(t, !remote_transport_open(nil, "/tmp/unused.socket", remote_key))
	transport: Remote_Machine_Transport
	testing.expect(t, !remote_transport_open(&transport, "", remote_key))

	// Socket path allocated in temp_allocator must survive free_all(context.temp_allocator)
	temp_socket := fmt.tprintf("/tmp/nonexistent-agent-bridge-%d.socket", 42)
	testing.expect(t, remote_transport_open(&transport, temp_socket, remote_key))
	defer remote_transport_close(&transport)
	free_all(context.temp_allocator)
	testing.expect_value(t, transport.socket_path, "/tmp/nonexistent-agent-bridge-42.socket")
	testing.expect_value(t, transport.client.socket, "/tmp/nonexistent-agent-bridge-42.socket")

	iface := remote_transport_interface(&transport)
	testing.expect(t, iface.user_data == &transport)
	testing.expect(t, iface.eval_lex != nil)
	testing.expect(t, iface.read_screen != nil)
	testing.expect(t, iface.send_key != nil)
	testing.expect(t, iface.send_pointer != nil)
	testing.expect(t, iface.read_log_facts != nil)

	// Malformed Lex call fails cleanly before touching the socket
	_, eval_err, eval_ok := iface.eval_lex(iface.user_data, "not_a_call", context.temp_allocator)
	testing.expect(t, !eval_ok && len(eval_err) > 0)

	// Unattached live remote_display operations fail closed with clear transport errors
	_, screen_err, screen_ok := iface.read_screen(iface.user_data, Screen_Snapshot_Request{format = .Png}, context.temp_allocator)
	testing.expect(t, !screen_ok && len(screen_err) > 0)
	key_err, key_ok := iface.send_key(iface.user_data, 101, remote_display.Key_Body{code = 30, pressed = 1})
	testing.expect(t, !key_ok && len(key_err) > 0)
	ptr_err, ptr_ok := iface.send_pointer(iface.user_data, 101, remote_display.Pointer_Body{x = 10, y = 20})
	testing.expect(t, !ptr_ok && len(ptr_err) > 0)

	// Closed transport fails closed cleanly
	remote_transport_close(&transport)
	_, closed_err, closed_ok := iface.eval_lex(iface.user_data, "monitor.processes()", context.temp_allocator)
	testing.expect(t, !closed_ok && len(closed_err) > 0)
}
