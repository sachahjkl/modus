#+build !freestanding
package agent_bridge

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/remote"
import "modus:contract/remote_display"
import "modus:contract/wide_grants"

@(private = "file")
make_client_key :: proc(seed: u8) -> (key: [32]u8) {
	for index in 0 ..< len(key) {
		key[index] = seed + u8(index)
	}
	return key
}

@(private = "file")
make_hash :: proc(label: string) -> blake3.Hash {
	raw := transmute([]u8)label
	return blake3.hash(raw)
}

@(private = "file")
make_active_policy :: proc(client_key: [32]u8) -> Bridge_Client_Policy {
	key_copy := client_key
	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = 0,
		grantee_identity_hash = blake3.hash(key_copy[:]),
		authorities_word      = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input, .Read_Semantic_Tree}),
		target_window_count   = 2,
		target_window_ids     = {0 = 101, 1 = 202},
		duration_ms           = wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	_ = wide_grants.wide_grant_terms_seal(&terms)

	return Bridge_Client_Policy {
		client_key_public     = client_key,
		principal_id          = 0,
		permissions_word      = bridge_permissions_to_word({.Eval_Lex, .Read_Screen, .Send_Input, .Read_Log_Facts}),
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

@(test)
test_enum_border_parsers_refuse_zero_and_unknown_values :: proc(t: ^testing.T) {
	// Bridge_Command_Kind: refuses 0, 6, max(u32)
	if _, ok := bridge_command_kind_from_word(0); ok {
		testing.fail_now(t, "bridge_command_kind_from_word accepted 0")
	}
	if _, ok := bridge_command_kind_from_word(6); ok {
		testing.fail_now(t, "bridge_command_kind_from_word accepted 6")
	}
	if _, ok := bridge_command_kind_from_word(max(u32)); ok {
		testing.fail_now(t, "bridge_command_kind_from_word accepted max(u32)")
	}
	for expected in Bridge_Command_Kind {
		if expected == .None {
			continue
		}
		parsed, ok := bridge_command_kind_from_word(u32(expected))
		testing.expect(t, ok && parsed == expected)
		testing.expect(t, len(bridge_command_kind_name(expected)) > 0)
	}

	// Bridge_Status: refuses 0, 5, max(u32)
	if _, ok := bridge_status_from_word(0); ok {
		testing.fail_now(t, "bridge_status_from_word accepted 0")
	}
	if _, ok := bridge_status_from_word(5); ok {
		testing.fail_now(t, "bridge_status_from_word accepted 5")
	}
	if _, ok := bridge_status_from_word(max(u32)); ok {
		testing.fail_now(t, "bridge_status_from_word accepted max(u32)")
	}
	for expected in Bridge_Status {
		if expected == .None {
			continue
		}
		parsed, ok := bridge_status_from_word(u32(expected))
		testing.expect(t, ok && parsed == expected)
		testing.expect(t, len(bridge_status_name(expected)) > 0)
	}

	// Bridge_Refusal: accepts 0..19, refuses 20 and max(u32)
	if _, ok := bridge_refusal_from_word(20); ok {
		testing.fail_now(t, "bridge_refusal_from_word accepted 20")
	}
	if _, ok := bridge_refusal_from_word(max(u32)); ok {
		testing.fail_now(t, "bridge_refusal_from_word accepted max(u32)")
	}
	for expected in Bridge_Refusal {
		parsed, ok := bridge_refusal_from_word(u32(expected))
		testing.expect(t, ok && parsed == expected)
		testing.expect(t, len(bridge_refusal_name(expected)) > 0)
	}

	// Bridge_Permission and Bridge_Permissions bitmask: refuses 0, bit 0, bit 5, max(u64)
	if _, ok := bridge_permission_from_word(0); ok {
		testing.fail_now(t, "bridge_permission_from_word accepted 0")
	}
	if _, ok := bridge_permission_from_word(5); ok {
		testing.fail_now(t, "bridge_permission_from_word accepted 5")
	}
	if _, ok := bridge_permission_from_word(max(u64)); ok {
		testing.fail_now(t, "bridge_permission_from_word accepted max(u64)")
	}
	bad_masks := [?]u64{0, 1, 1 << 5, 1 << 63, BRIDGE_PERMISSION_KNOWN_MASK | 1, BRIDGE_PERMISSION_KNOWN_MASK | (1 << 6), max(u64)}
	for mask in bad_masks {
		if _, ok := bridge_permissions_from_word(mask); ok {
			testing.fail_now(t, "bridge_permissions_from_word accepted invalid mask")
		}
	}
	all_perms := Bridge_Permissions{.Eval_Lex, .Read_Screen, .Send_Input, .Read_Log_Facts}
	decoded_perms, perms_ok := bridge_permissions_from_word(bridge_permissions_to_word(all_perms))
	testing.expect(t, perms_ok && decoded_perms == all_perms)

	// Screen_Picture_Format and Lex_Value_Kind
	if _, ok := screen_picture_format_from_word(0); ok {
		testing.fail_now(t, "screen_picture_format_from_word accepted 0")
	}
	if _, ok := screen_picture_format_from_word(3); ok {
		testing.fail_now(t, "screen_picture_format_from_word accepted 3")
	}
	if _, ok := screen_picture_format_from_word(max(u8)); ok {
		testing.fail_now(t, "screen_picture_format_from_word accepted max(u8)")
	}
	if _, ok := lex_value_kind_from_word(0); ok {
		testing.fail_now(t, "lex_value_kind_from_word accepted 0")
	}
	if _, ok := lex_value_kind_from_word(7); ok {
		testing.fail_now(t, "lex_value_kind_from_word accepted 7")
	}
	if _, ok := lex_value_kind_from_word(max(u8)); ok {
		testing.fail_now(t, "lex_value_kind_from_word accepted max(u8)")
	}
}

@(test)
test_command_and_response_wire_framing_roundtrip_and_refusals :: proc(t: ^testing.T) {
	payload_text := "monitor.processes()"
	payload_bytes := transmute([]u8)payload_text
	frame := Bridge_Command_Frame {
		command          = .Eval_Lex,
		request_id       = 42,
		principal_id     = 1,
		grant_serial     = 9,
		target_window_id = 101,
		client_key_hash  = make_hash("client-1"),
		payload          = payload_bytes,
	}

	// Refusals on encode: nil, None command, zero request_id, zero client hash, small buffer, oversized payload.
	buf: [256]u8
	_, r := encode_command_frame(nil, buf[:])
	testing.expect_value(t, r, Bridge_Refusal.Unknown_Command)

	bad_frame := frame
	bad_frame.command = .None
	_, r = encode_command_frame(&bad_frame, buf[:])
	testing.expect_value(t, r, Bridge_Refusal.Unknown_Command)

	bad_frame = frame
	bad_frame.request_id = 0
	_, r = encode_command_frame(&bad_frame, buf[:])
	testing.expect_value(t, r, Bridge_Refusal.Invalid_Field)

	bad_frame = frame
	bad_frame.client_key_hash = {}
	_, r = encode_command_frame(&bad_frame, buf[:])
	testing.expect_value(t, r, Bridge_Refusal.Client_Key_Missing)

	// Buffer too small leaves output untouched
	sentinel: [COMMAND_HEADER_SIZE]u8
	for &b in sentinel {
		b = 0xAA
	}
	_, r = encode_command_frame(&frame, sentinel[:COMMAND_HEADER_SIZE - 1])
	testing.expect_value(t, r, Bridge_Refusal.Buffer_Too_Small)
	for b in sentinel {
		testing.expect_value(t, b, u8(0xAA))
	}

	// Oversized payload refused
	oversized := make([]u8, MAX_BRIDGE_PAYLOAD_BYTES + 1, context.temp_allocator)
	bad_frame = frame
	bad_frame.payload = oversized
	_, r = encode_command_frame(&bad_frame, buf[:])
	testing.expect_value(t, r, Bridge_Refusal.Payload_Too_Large)

	// Valid encode + decode round-trip
	written, enc_refusal := encode_command_frame(&frame, buf[:])
	testing.expect_value(t, enc_refusal, Bridge_Refusal.None)
	testing.expect_value(t, written, COMMAND_HEADER_SIZE + len(payload_bytes))

	decoded, dec_refusal := decode_command_frame(buf[:written])
	testing.expect_value(t, dec_refusal, Bridge_Refusal.None)
	testing.expect_value(t, decoded.command, Bridge_Command_Kind.Eval_Lex)
	testing.expect_value(t, decoded.request_id, u64(42))
	testing.expect_value(t, decoded.principal_id, u64(1))
	testing.expect_value(t, decoded.grant_serial, u64(9))
	testing.expect_value(t, decoded.target_window_id, u64(101))
	testing.expect_value(t, decoded.client_key_hash, frame.client_key_hash)
	testing.expect_value(t, string(decoded.payload), payload_text)

	// Adversarial decode: truncated at every length from 0 to written - 1
	for cut in 0 ..< written {
		_, cut_refusal := decode_command_frame(buf[:cut])
		testing.expect_value(t, cut_refusal, Bridge_Refusal.Truncated)
	}

	// Trailing byte refused
	buf[written] = 0x00
	_, trailing_refusal := decode_command_frame(buf[:written + 1])
	testing.expect_value(t, trailing_refusal, Bridge_Refusal.Trailing_Bytes)

	// Corrupted header fields
	{
		mut := buf
		mut[0] = 'X'
		_, mr := decode_command_frame(mut[:written])
		testing.expect_value(t, mr, Bridge_Refusal.Bad_Header)
	}
	{
		mut := buf
		byte_order.write_u16_little_endian(mut[:], 6, 2)
		_, mr := decode_command_frame(mut[:written])
		testing.expect_value(t, mr, Bridge_Refusal.Bad_Header)
	}
	{
		mut := buf
		byte_order.write_u32_little_endian(mut[:], 8, 99)
		_, mr := decode_command_frame(mut[:written])
		testing.expect_value(t, mr, Bridge_Refusal.Unknown_Command)
	}
	{
		mut := buf
		byte_order.write_u64_little_endian(mut[:], 12, 0)
		_, mr := decode_command_frame(mut[:written])
		testing.expect_value(t, mr, Bridge_Refusal.Invalid_Field)
	}
	{
		mut := buf
		for i in 0 ..< blake3.HASH_SIZE {
			mut[44 + i] = 0
		}
		_, mr := decode_command_frame(mut[:written])
		testing.expect_value(t, mr, Bridge_Refusal.Client_Key_Missing)
	}
	{
		mut := buf
		byte_order.write_u32_little_endian(mut[:], 80, 1)
		_, mr := decode_command_frame(mut[:written])
		testing.expect_value(t, mr, Bridge_Refusal.Bad_Header)
	}
	{
		mut := buf
		byte_order.write_u32_little_endian(mut[:], 76, MAX_BRIDGE_PAYLOAD_BYTES + 1)
		_, mr := decode_command_frame(mut[:written])
		testing.expect_value(t, mr, Bridge_Refusal.Payload_Too_Large)
	}

	// Response frame round-trip + refusals
	resp := Bridge_Response_Frame {
		status              = .Awaiting_Principal_Approval,
		refusal             = .Principal_Approval_Required,
		request_id          = 42,
		act_sequence_number = 3,
		act_record_hash     = make_hash("act-3"),
		payload             = transmute([]u8)string("approval needed"),
	}
	resp_buf: [256]u8
	resp_written, resp_enc := encode_response_frame(&resp, resp_buf[:])
	testing.expect_value(t, resp_enc, Bridge_Refusal.None)
	testing.expect_value(t, resp_written, RESPONSE_HEADER_SIZE + len(resp.payload))

	dec_resp, resp_dec := decode_response_frame(resp_buf[:resp_written])
	testing.expect_value(t, resp_dec, Bridge_Refusal.None)
	testing.expect_value(t, dec_resp.status, Bridge_Status.Awaiting_Principal_Approval)
	testing.expect_value(t, dec_resp.refusal, Bridge_Refusal.Principal_Approval_Required)
	testing.expect_value(t, dec_resp.request_id, u64(42))
	testing.expect_value(t, dec_resp.act_sequence_number, u64(3))
	testing.expect_value(t, dec_resp.act_record_hash, resp.act_record_hash)
	testing.expect_value(t, string(dec_resp.payload), "approval needed")

	// Response frame refusals: unknown status, unknown refusal, truncated, trailing, reserved non-zero
	{
		mut := resp_buf
		byte_order.write_u32_little_endian(mut[:], 8, 0)
		_, mr := decode_response_frame(mut[:resp_written])
		testing.expect_value(t, mr, Bridge_Refusal.Unknown_Status)
	}
	{
		mut := resp_buf
		byte_order.write_u32_little_endian(mut[:], 12, 999)
		_, mr := decode_response_frame(mut[:resp_written])
		testing.expect_value(t, mr, Bridge_Refusal.Bad_Header)
	}
	{
		mut := resp_buf
		byte_order.write_u32_little_endian(mut[:], 68, 7)
		_, mr := decode_response_frame(mut[:resp_written])
		testing.expect_value(t, mr, Bridge_Refusal.Bad_Header)
	}
	_, tr := decode_response_frame(resp_buf[:resp_written - 1])
	testing.expect_value(t, tr, Bridge_Refusal.Truncated)
	resp_buf[resp_written] = 1
	_, tb := decode_response_frame(resp_buf[:resp_written + 1])
	testing.expect_value(t, tb, Bridge_Refusal.Trailing_Bytes)
}

@(test)
test_typed_payload_codecs_refuse_boundary_violations :: proc(t: ^testing.T) {
	// Lex line validation
	testing.expect_value(t, validate_lex_line(nil), Bridge_Refusal.Invalid_Text)
	testing.expect_value(t, validate_lex_line([]u8{0x07}), Bridge_Refusal.Invalid_Text)
	testing.expect_value(t, validate_lex_line([]u8{0xFF, 0xFE}), Bridge_Refusal.Invalid_Text)
	too_long_lex := make([]u8, MAX_LEX_LINE_BYTES + 1, context.temp_allocator)
	for &b in too_long_lex {
		b = 'a'
	}
	testing.expect_value(t, validate_lex_line(too_long_lex), Bridge_Refusal.Payload_Too_Large)
	testing.expect_value(t, validate_lex_line(too_long_lex[:MAX_LEX_LINE_BYTES]), Bridge_Refusal.None)

	// Read_Screen payload
	{
		buf: [32]u8
		good := Read_Screen_Payload{format = .Png, max_width = remote_display.SCREEN_WIDTH_LIMIT, max_height = remote_display.SCREEN_HEIGHT_LIMIT, wait_settled_ms = MAX_WAIT_SETTLED_MS}
		n, r := encode_read_screen_payload(&good, buf[:])
		testing.expect_value(t, r, Bridge_Refusal.None)
		testing.expect_value(t, n, READ_SCREEN_PAYLOAD_SIZE)
		dec, dr := decode_read_screen_payload(buf[:n])
		testing.expect_value(t, dr, Bridge_Refusal.None)
		testing.expect_value(t, dec, good)

		bad := good
		bad.max_width = remote_display.SCREEN_WIDTH_LIMIT + 1
		testing.expect_value(t, validate_read_screen_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.wait_settled_ms = MAX_WAIT_SETTLED_MS + 1
		testing.expect_value(t, validate_read_screen_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.format = .None
		testing.expect_value(t, validate_read_screen_payload(&bad), Bridge_Refusal.Invalid_Field)

		_, tr := decode_read_screen_payload(buf[:n - 1])
		testing.expect_value(t, tr, Bridge_Refusal.Truncated)
		_, tb := decode_read_screen_payload(buf[:n + 1])
		testing.expect_value(t, tb, Bridge_Refusal.Trailing_Bytes)
	}

	// Send_Key payload
	{
		buf: [32]u8
		good := Send_Key_Payload{key = {code = 0x1E, character = 'a', pressed = 1, modifiers = 0b01}}
		n, r := encode_send_key_payload(&good, buf[:])
		testing.expect_value(t, r, Bridge_Refusal.None)
		dec, dr := decode_send_key_payload(buf[:n])
		testing.expect_value(t, dr, Bridge_Refusal.None)
		testing.expect_value(t, dec, good)

		bad := good
		bad.key.code = 0
		testing.expect_value(t, validate_send_key_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.key.code = remote_display.KEY_RELEASE_BIT | 0x1E
		testing.expect_value(t, validate_send_key_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.key.code = remote_display.KEY_CODE_LIMIT + 1
		testing.expect_value(t, validate_send_key_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.key.character = 0xD800
		testing.expect_value(t, validate_send_key_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.key.pressed = 2
		testing.expect_value(t, validate_send_key_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.key.modifiers = 0b100
		testing.expect_value(t, validate_send_key_payload(&bad), Bridge_Refusal.Invalid_Field)
	}

	// Send_Pointer payload
	{
		buf: [32]u8
		good := Send_Pointer_Payload{pointer = {x = 1919, y = 1079, buttons = 0b01, wheel = -64}}
		n, r := encode_send_pointer_payload(&good, buf[:])
		testing.expect_value(t, r, Bridge_Refusal.None)
		dec, dr := decode_send_pointer_payload(buf[:n])
		testing.expect_value(t, dr, Bridge_Refusal.None)
		testing.expect_value(t, dec, good)

		bad := good
		bad.pointer.x = remote_display.SCREEN_WIDTH_LIMIT
		testing.expect_value(t, validate_send_pointer_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.pointer.y = remote_display.SCREEN_HEIGHT_LIMIT
		testing.expect_value(t, validate_send_pointer_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.pointer.buttons = 0b100
		testing.expect_value(t, validate_send_pointer_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.pointer.wheel = remote_display.WHEEL_NOTCHES_LIMIT + 1
		testing.expect_value(t, validate_send_pointer_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.pointer.wheel = -remote_display.WHEEL_NOTCHES_LIMIT - 1
		testing.expect_value(t, validate_send_pointer_payload(&bad), Bridge_Refusal.Invalid_Field)
	}

	// Read_Log_Facts payload
	{
		buf: [256]u8
		good := Read_Log_Facts_Payload {
			module_filter_length    = 7,
			fact_name_filter_length = 9,
			sequence_start          = 10,
			sequence_end            = 50,
			max_records             = 64,
		}
		copy(good.module_filter_bytes[:], "storage")
		copy(good.fact_name_filter_bytes[:], "Bad_Block")
		n, r := encode_read_log_facts_payload(&good, buf[:])
		testing.expect_value(t, r, Bridge_Refusal.None)
		dec, dr := decode_read_log_facts_payload(buf[:n])
		testing.expect_value(t, dr, Bridge_Refusal.None)
		testing.expect_value(t, dec, good)

		bad := good
		bad.max_records = 0
		testing.expect_value(t, validate_read_log_facts_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.max_records = MAX_LOG_FACT_QUERY_LIMIT + 1
		testing.expect_value(t, validate_read_log_facts_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.sequence_end = 9
		testing.expect_value(t, validate_read_log_facts_payload(&bad), Bridge_Refusal.Invalid_Field)
		bad = good
		bad.module_filter_bytes[8] = 'z' // non-zero tail padding
		testing.expect_value(t, validate_read_log_facts_payload(&bad), Bridge_Refusal.Invalid_Text)
	}
}

@(test)
test_lex_line_classification_is_a_strict_read_only_allowlist :: proc(t: ^testing.T) {
	classify :: proc(line: string) -> Lex_Line_Class {
		return lex_line_classify(transmute([]u8)line)
	}

	// Comments, second lines, pipes, chains and nested calls are refused:
	// a comment can no longer hide the call after it.
	malformed := [?]string {
		"# comment\nplans.apply(1)",
		"-- comment\nstorage.write(\"a\", \"b\")",
		"// comment\nsettings.appearance(1)",
		"monitor.processes() // plans.apply(1)",
		"monitor.processes() -- plans.apply(1)",
		"monitor.processes() # plans.apply(1)",
		"monitor.processes()\nplans.apply(1)",
		"monitor.processes()\rplans.apply(1)",
		"monitor.processes(); plans.apply(1)",
		"monitor.processes() |> plans.apply()",
		"monitor.processes()\x00",
		"monitor.processes(plans.apply())",
		"monitor.processes(x = plans.rollback())",
		"monitor.count(lock)",
		"monitor.count(n = lock)",
		"monitor.processes() monitor.processes()",
		"monitor.processes()()",
		"monitor . processes()",
		"monitor.processes.x()",
		"monitor",
		"lock",
		"unlock()",
		"",
		"   ",
		"monitor.processes(",
		"monitor.processes(1,)",
		"monitor.processes(,1)",
		"monitor.counts(\"unclosed)",
		"monitor.count(--1)",
		"monitor.count(1abc)",
		"monitor.count(== 1)",
		"monitor.count(n == 1)",
		"monitor.count([1, 2])",
		"monitor.count({a = 1})",
		"monitor.count((x) => x)",
		"monitor.count(let a = 1 in a)",
		"monitor.count(blake3:00)",
		"monitor.count(blake3:" + "AA" + "00000000000000000000000000000000000000000000000000000000000000)",
		"monitor.count(.a.b)",
	}
	for line in malformed {
		testing.expectf(t, classify(line) == .Malformed, "line %q was not refused", line)
	}

	// A text of Lex has no escape: the quote ends it, and the call after it
	// is seen as a call.
	testing.expect_value(t, classify(`monitor.counts("a\") plans.apply("b")`), Lex_Line_Class.Malformed)

	// One call of an export outside the read-only list waits for the principal.
	needs_approval := [?]string {
		"plans.apply(1)",
		"plans.apply()",
		"plans.apply",
		"plans.rollback()",
		"plans.apply_poll(1)",
		"storage.write(\"a\", \"b\")",
		"settings.appearance(1)",
		"settings.set(font = .spleen)",
		"compositor.wide_grant_indicator(0, 0)",
		"compositor.wide_grant_indicator(0)",
		"compositor.notify(\"a\", \"b\")",
		"compositor.revoke_grant(1)",
		"debugger.attach(1)",
		"debugger.memory(1, 0, 16)",
		"debugger.registers(1)",
		"collector.act_records_read(0, 0, 10)",
		"recipes.build(1)",
		"projects.load(\"a\")",
		"unknown.export()",
	}
	for line in needs_approval {
		testing.expectf(t, classify(line) == .Requires_Principal_Approval, "line %q was not held for approval", line)
	}

	// No export that changes a state is on the read-only list.
	for entry in READ_ONLY_EXPORTS {
		for word in ([?]string{"apply", "rollback", "write", "set", "attach", "detach", "indicator", "load", "update", "register", "revoke", "notify", "ask", "open", "hold", "release"}) {
			testing.expectf(t, !contains_word(entry.export, word), "read-only export %s.%s names %s", entry.service, entry.export, word)
		}
		testing.expectf(t, entry.service != "storage" && entry.service != "settings" && entry.service != "debugger" && entry.service != "collector", "service %s is on the read-only list", entry.service)
	}

	// Read-only calls with literal arguments run, last.
	read_only := [?]string {
		"monitor.processes()",
		"monitor.processes",
		"  monitor.processes ( )  ",
		"monitor.count(\"plans.apply(1) # -- //\")",
		"monitor.counts_named(\"a\", -7, true, false, .Error)",
		"log.records(level = .Warning, sequence >= 10, name != \"x\")",
		"plans.difference(blake3:" + "00000000000000000000000000000000000000000000000000000000000000ff" + ")",
		"compositor.windows()",
		"plans.status()",
	}
	for line in read_only {
		testing.expectf(t, classify(line) == .Read_Only, "read-only line %q was not accepted", line)
	}
}

@(private = "file")
contains_word :: proc(text: string, word: string) -> bool {
	if len(word) > len(text) {
		return false
	}
	for start in 0 ..= len(text) - len(word) {
		if text[start:start + len(word)] == word {
			return true
		}
	}
	return false
}

@(test)
test_authorization_enforces_permissions_wide_grants_and_principal_approval :: proc(t: ^testing.T) {
	client_key := make_client_key(0x21)
	policy := make_active_policy(client_key)

// 1. plans.apply and plans.rollback ALWAYS stop with
	// Awaiting_Principal_Approval: the request has no flag that can change it.
	for line in ([?]string{"plans.apply(1)", "plans.apply()", "plans.rollback()", "plans.rollback(1)"}) {
		req := Bridge_Authorization_Request {
			command  = .Eval_Lex,
			now_ms   = 2_000,
			lex_line = transmute([]u8)line,
		}
		dec := bridge_authorize_command(&policy, &req)
		testing.expect_value(t, dec.status, Bridge_Status.Awaiting_Principal_Approval)
		testing.expect_value(t, dec.refusal, Bridge_Refusal.Principal_Approval_Required)
	}

	// 2. A comment, a second line or a chain is refused, never run.
	for line in ([?]string{"# comment\nplans.apply(1)", "-- comment\nstorage.write(\"a\", \"b\")", "// comment\nsettings.appearance(1)", "monitor.processes() |> plans.apply()"}) {
		req := Bridge_Authorization_Request {
			command  = .Eval_Lex,
			now_ms   = 2_000,
			lex_line = transmute([]u8)line,
		}
		dec := bridge_authorize_command(&policy, &req)
		testing.expect_value(t, dec.status, Bridge_Status.Refused)
		testing.expect_value(t, dec.refusal, Bridge_Refusal.Invalid_Text)
	}

	// 3. A call outside the read-only list waits; a read-only call runs.
	{
		req := Bridge_Authorization_Request {
			command  = .Eval_Lex,
			now_ms   = 2_000,
			lex_line = transmute([]u8)string("compositor.wide_grant_indicator(0, 0)"),
		}
		dec := bridge_authorize_command(&policy, &req)
		testing.expect_value(t, dec.status, Bridge_Status.Awaiting_Principal_Approval)
		req.lex_line = transmute([]u8)string("monitor.processes()")
		dec = bridge_authorize_command(&policy, &req)
		testing.expect_value(t, dec.status, Bridge_Status.Ok)
		testing.expect_value(t, dec.required_act_kind, wide_grants.Act_Kind.Action_Invoked)
	}

		// 5. Permission and remote key use checks for each capability.
	{
		read_only_policy := policy
		read_only_policy.permissions_word = bridge_permissions_to_word({.Read_Log_Facts})
		req := Bridge_Authorization_Request{command = .Eval_Lex, now_ms = 2_000, lex_line = transmute([]u8)string("monitor.processes()")}
		testing.expect_value(t, bridge_authorize_command(&read_only_policy, &req).refusal, Bridge_Refusal.Permission_Denied)

		req = Bridge_Authorization_Request{command = .Read_Screen, now_ms = 2_000}
		testing.expect_value(t, bridge_authorize_command(&read_only_policy, &req).refusal, Bridge_Refusal.Permission_Denied)

		req = Bridge_Authorization_Request{command = .Send_Key, now_ms = 2_000, target_window_id = 101}
		testing.expect_value(t, bridge_authorize_command(&read_only_policy, &req).refusal, Bridge_Refusal.Permission_Denied)

		req = Bridge_Authorization_Request{command = .Read_Log_Facts, now_ms = 2_000}
		testing.expect_value(t, bridge_authorize_command(&read_only_policy, &req).status, Bridge_Status.Ok)

		// Missing remote View use refuses Read_Screen even if Bridge_Permission.Read_Screen is set.
		calls_only_policy := policy
		calls_only_policy.remote_uses_word = remote.client_uses_word({.Calls})
		req = Bridge_Authorization_Request{command = .Read_Screen, now_ms = 2_000}
		testing.expect_value(t, bridge_authorize_command(&calls_only_policy, &req).refusal, Bridge_Refusal.Permission_Denied)
	}

	// 6. Send_Key / Send_Pointer wide grant and window scope enforcement.
	{
		key_req := Bridge_Authorization_Request{command = .Send_Key, now_ms = 2_000, target_window_id = 101}

		// Valid active grant in scope -> Ok + Key_Injected
		dec := bridge_authorize_command(&policy, &key_req)
		testing.expect_value(t, dec.status, Bridge_Status.Ok)
		testing.expect_value(t, dec.required_act_kind, wide_grants.Act_Kind.Key_Injected)

		// Valid pointer click vs move
		ptr_req := Bridge_Authorization_Request{command = .Send_Pointer, now_ms = 2_000, target_window_id = 202, pointer_has_click = true}
		dec = bridge_authorize_command(&policy, &ptr_req)
		testing.expect_value(t, dec.status, Bridge_Status.Ok)
		testing.expect_value(t, dec.required_act_kind, wide_grants.Act_Kind.Pointer_Clicked)

		ptr_req.pointer_has_click = false
		dec = bridge_authorize_command(&policy, &ptr_req)
		testing.expect_value(t, dec.status, Bridge_Status.Ok)
		testing.expect_value(t, dec.required_act_kind, wide_grants.Act_Kind.Pointer_Moved)

		// Out-of-scope window (0 and 999) refused!
		out_req := key_req
		out_req.target_window_id = 0
		testing.expect_value(t, bridge_authorize_command(&policy, &out_req).refusal, Bridge_Refusal.Window_Not_In_Scope)
		out_req.target_window_id = 999
		testing.expect_value(t, bridge_authorize_command(&policy, &out_req).refusal, Bridge_Refusal.Window_Not_In_Scope)

		// Missing wide grant refused
		no_wg := policy
		no_wg.has_wide_grant = false
		testing.expect_value(t, bridge_authorize_command(&no_wg, &key_req).refusal, Bridge_Refusal.Wide_Grant_Required)

		// Revoked or Pending wide grant refused
		revoked_wg := policy
		revoked_wg.wide_grant_state_word = u64(wide_grants.Wide_Grant_State.Revoked)
		testing.expect_value(t, bridge_authorize_command(&revoked_wg, &key_req).refusal, Bridge_Refusal.Wide_Grant_Not_Active)

		// Expired at exact boundary (now_ms == expires_ms) and before created_ms
		exp_req := key_req
		exp_req.now_ms = policy.wide_grant_expires_ms
		testing.expect_value(t, bridge_authorize_command(&policy, &exp_req).refusal, Bridge_Refusal.Wide_Grant_Expired)
		exp_req.now_ms = policy.wide_grant_created_ms - 1
		testing.expect_value(t, bridge_authorize_command(&policy, &exp_req).refusal, Bridge_Refusal.Wide_Grant_Expired)

		// Mismatched client key vs grantee_identity_hash refused
		wrong_key := policy
		wrong_key.client_key_public = make_client_key(0x99)
		testing.expect_value(t, bridge_authorize_command(&wrong_key, &key_req).refusal, Bridge_Refusal.Wide_Grant_Not_Active)

		// Collector unavailable fails closed!
		no_collector := policy
		no_collector.collector_available = false
		testing.expect_value(t, bridge_authorize_command(&no_collector, &key_req).refusal, Bridge_Refusal.Act_Log_Required)

		// Missing client key refused
		no_key := policy
		no_key.client_key_public = {}
		testing.expect_value(t, bridge_authorize_command(&no_key, &key_req).refusal, Bridge_Refusal.Client_Key_Missing)
	}
}
