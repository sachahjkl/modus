#+build !freestanding
package wiring_service

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"

// Unknown command words, None, and max(u32) are refused before any field is read.
@(test)
command_from_record_refuses_unknown_and_zero_command_words :: proc(t: ^testing.T) {
	bad_kinds := [?]u32{0, u32(max(Command_Kind)) + 1, 1 << 16, max(u32) - 1, max(u32)}
	for kind in bad_kinds {
		rec := ring.Record{kind = kind, tag = 7, values = {1, 1, 0, 0, 0, 0, 0}}
		cmd, ok := command_from_record(rec)
		testing.expectf(t, !ok, "command word %d was accepted", kind)
		testing.expect_value(t, cmd, Command{})
	}
}

// Edge inputs for process slots, serials, flags, handles, end words, query kinds,
// and non-zero trailing reserved words are refused on every command.
@(test)
command_from_record_refuses_invalid_fields_and_flags :: proc(t: ^testing.T) {
	bad_slots := [?]u64{0, op.PROCESS_SLOTS_MOST, op.PROCESS_SLOTS_MOST + 1, max(u64)}
	for slot in bad_slots {
		_, ok := command_from_record({kind = u32(Command_Kind.List_Page), values = {slot, 1, 0, 0, 0, 0, 0}})
		testing.expectf(t, !ok, "List_Page accepted invalid slot %d", slot)
	}
	// Zero serial refused.
	_, ok := command_from_record({kind = u32(Command_Kind.List_Page), values = {1, 0, 0, 0, 0, 0, 0}})
	testing.expect(t, !ok)
	// Trailing non-zero word on List_Page refused.
	_, ok = command_from_record({kind = u32(Command_Kind.List_Page), values = {1, 1, 1, 0, 0, 0, 0}})
	testing.expect(t, !ok)

	// Register_Process: zero process handle, handle > max(u32), mismatched module
	// offset/size, mismatched Has_Wiring_Ring flag, and unknown flag bits.
	bad_flag_words := [?]u64{1 << 5, 1 << 31, u64(max(u32)), u64(1) << 32, max(u64)}
	for flag_word in bad_flag_words {
		_, flags_ok := process_flags_from_word(flag_word)
		testing.expectf(t, !flags_ok, "unknown flag word %x accepted", flag_word)
		_, cmd_ok := command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 4096, 4096, 5, 0, flag_word}})
		testing.expectf(t, !cmd_ok, "Register_Process accepted bad flag word %x", flag_word)
	}
	// Process handle 0 or > max(u32).
	_, ok = command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 0, 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 0, 0, u64(max(u32)) + 1, 0, 0}})
	testing.expect(t, !ok)
	// Wiring ring handle > max(u32).
	_, ok = command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 0, 0, 3, u64(max(u32)) + 1, u64(transmute(u32)Process_Flags{.Has_Wiring_Ring})}})
	testing.expect(t, !ok)
	// Has_Wiring_Ring set with handle 0, or unset with non-zero handle.
	_, ok = command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 0, 0, 3, 0, u64(transmute(u32)Process_Flags{.Has_Wiring_Ring})}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 0, 0, 3, 9, 0}})
	testing.expect(t, !ok)
	// Module offset set without size or size set without offset.
	_, ok = command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 4096, 0, 3, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Register_Process), values = {1, 1, 0, 4096, 3, 0, 0}})
	testing.expect(t, !ok)

	// Grant_Asker_Budget: 0 budget handle, > max(u32), trailing non-zero.
	_, ok = command_from_record({kind = u32(Command_Kind.Grant_Asker_Budget), values = {1, 1, 0, 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Grant_Asker_Budget), values = {1, 1, u64(max(u32)) + 1, 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Grant_Asker_Budget), values = {1, 1, 4, 1, 0, 0, 0}})
	testing.expect(t, !ok)

	// Prepare_Start_Wiring: zero module offset/size, unknown flags, trailing non-zero.
	_, ok = command_from_record({kind = u32(Command_Kind.Prepare_Start_Wiring), values = {1, 1, 0, 0, 4096, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Prepare_Start_Wiring), values = {1, 1, 0, 4096, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Prepare_Start_Wiring), values = {1, 1, 0, 4096, 4096, 1, 0}})
	testing.expect(t, !ok)

	// Commit_Start_Wiring / Abort_Start_Wiring: batch_id 0 or > max(u32).
	for bad_batch in ([?]u64{0, u64(max(u32)) + 1, max(u64)}) {
		_, commit_ok := command_from_record({kind = u32(Command_Kind.Commit_Start_Wiring), values = {bad_batch, 2, 10, 0, 0, 0, 0}})
		testing.expect(t, !commit_ok)
		_, abort_ok := command_from_record({kind = u32(Command_Kind.Abort_Start_Wiring), values = {bad_batch, 0, 0, 0, 0, 0, 0}})
		testing.expect(t, !abort_ok)
	}

	// Unwire: wiring_number 0 or > max(u32), End_Word.None or unknown end word.
	_, ok = command_from_record({kind = u32(Command_Kind.Unwire), values = {1, 1, 0, u64(output.End_Word.Revoked), 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Unwire), values = {1, 1, u64(max(u32)) + 1, u64(output.End_Word.Revoked), 0, 0, 0}})
	testing.expect(t, !ok)
	for bad_end in ([?]u64{0, u64(max(output.End_Word)) + 1, max(u64)}) {
		_, end_ok := command_from_record({kind = u32(Command_Kind.Unwire), values = {1, 1, 5, bad_end, 0, 0, 0}})
		testing.expectf(t, !end_ok, "Unwire accepted bad end word %d", bad_end)
	}

	// Query: invalid Query_Kind, Machine_Totals with non-zero target, Asker_Count with zero target.
	for bad_q in ([?]u64{0, u64(max(Query_Kind)) + 1, max(u64)}) {
		_, q_ok := command_from_record({kind = u32(Command_Kind.Query), values = {bad_q, 0, 0, 0, 0, 0, 0}})
		testing.expect(t, !q_ok)
	}
	_, ok = command_from_record({kind = u32(Command_Kind.Query), values = {u64(Query_Kind.Machine_Totals), 1, 0, 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Query), values = {u64(Query_Kind.Asker_Count), 0, 0, 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = command_from_record({kind = u32(Command_Kind.Query), values = {u64(Query_Kind.Process_Ends), op.PROCESS_SLOTS_MOST, 1, 0, 0, 0, 0}})
	testing.expect(t, !ok)
}

// Responses refuse outcome words that name none, a failure with no record,
// Command_Kind.None, handles past u32, zero required handles/ids, and
// non-zero trailing fields. A failure with its record comes last.
@(test)
response_from_record_refuses_invalid_statuses_and_values :: proc(t: ^testing.T) {
	_, ok := response_from_record({kind = 0}, .None)
	testing.expect(t, !ok)
	for bad_outcome in ([?]u32{u32(max(call_outcome.Call_Outcome)) + 1, 1 << 20, max(u32)}) {
		_, outcome_ok := response_from_record({kind = bad_outcome, tag = 1}, .Wire)
		testing.expectf(t, !outcome_ok, "bad response outcome %d accepted", bad_outcome)
	}
	// A failure whose values are no record.
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Wrong_State), tag = 1}, .Wire)
	testing.expect(t, !ok)
	// List_Page: list_page 0 or > max(u32), wiring_ring > max(u32), trailing non-zero.
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {0, 0, 0, 0, 0, 0, 0}}, .List_Page)
	testing.expect(t, !ok)
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {u64(max(u32)) + 1, 0, 0, 0, 0, 0, 0}}, .List_Page)
	testing.expect(t, !ok)
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {5, u64(max(u32)) + 1, 0, 0, 0, 0, 0}}, .List_Page)
	testing.expect(t, !ok)
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {5, 6, 1, 0, 0, 0, 0}}, .List_Page)
	testing.expect(t, !ok)
	// Wire: wiring_number 0 or > max(u32).
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {0, 1, 0, 0, 0, 0, 0}}, .Wire)
	testing.expect(t, !ok)
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {u64(max(u32)) + 1, 1, 0, 0, 0, 0, 0}}, .Wire)
	testing.expect(t, !ok)
	// Prepare_Start_Wiring: batch_id 0 or > max(u32).
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {0, 0, 0, 0, 0, 0, 0}}, .Prepare_Start_Wiring)
	testing.expect(t, !ok)
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {u64(max(u32)) + 1, 0, 0, 0, 0, 0, 0}}, .Prepare_Start_Wiring)
	testing.expect(t, !ok)
	// Register_Process: non-zero payload refused on Ok.
	_, ok = response_from_record({kind = u32(call_outcome.Call_Outcome.Succeeded), values = {1, 0, 0, 0, 0, 0, 0}}, .Register_Process)
	testing.expect(t, !ok)
	// A failure with its record is read whole.
	refusal := errors.error_make(.Exists, .Wirings, 2)
	failed, failed_ok := response_from_record({kind = u32(call_outcome.Call_Outcome.Name_Already_Taken), tag = 3, values = errors.completion_values(refusal)}, .Wire)
	testing.expect(t, failed_ok)
	testing.expect_value(t, failed.outcome, call_outcome.Call_Outcome.Name_Already_Taken)
	testing.expect_value(t, failed.error_record, refusal)
}

// Process_Stop_Notice border refuses invalid kinds, out-of-range slots, zero
// serials, non-zero tags/trailing values, and impossible (cause, outcome) pairs.
@(test)
stop_notice_from_record_refuses_invalid_notices :: proc(t: ^testing.T) {
	for bad_kind in ([?]u32{0, u32(max(Stop_Notice_Kind)) + 1, max(u32)}) {
		_, ok := stop_notice_from_record({kind = bad_kind, values = {1, 1, u64(op.Stop_Cause.Holder), 0, 0, 0, 0}})
		testing.expectf(t, !ok, "bad stop notice kind %d accepted", bad_kind)
	}
	for bad_slot in ([?]u64{0, op.PROCESS_SLOTS_MOST, max(u64)}) {
		_, ok := stop_notice_from_record({kind = u32(Stop_Notice_Kind.Process_Stopped), values = {bad_slot, 1, u64(op.Stop_Cause.Holder), 0, 0, 0, 0}})
		testing.expect(t, !ok)
	}
	// Zero serial, non-zero tag, trailing non-zero value.
	_, ok := stop_notice_from_record({kind = u32(Stop_Notice_Kind.Process_Stopped), values = {1, 0, u64(op.Stop_Cause.Holder), 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = stop_notice_from_record({kind = u32(Stop_Notice_Kind.Process_Stopped), tag = 1, values = {1, 1, u64(op.Stop_Cause.Holder), 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = stop_notice_from_record({kind = u32(Stop_Notice_Kind.Process_Stopped), values = {1, 1, u64(op.Stop_Cause.Holder), 0, 1, 0, 0}})
	testing.expect(t, !ok)

	// Invalid stop causes and impossible (cause, outcome) pairs.
	bad_pairs := [?][2]u64 {
		{u64(op.Stop_Cause.None), 0},
		{u64(max(op.Stop_Cause)) + 1, 0},
		{max(u64), 0},
		{u64(op.Stop_Cause.Itself), u64(op.Stop_Outcome.None)},
		{u64(op.Stop_Cause.Itself), u64(max(op.Stop_Outcome)) + 1},
		{u64(op.Stop_Cause.Itself), max(u64)},
		{u64(op.Stop_Cause.Holder), u64(op.Stop_Outcome.Done)},
		{u64(op.Stop_Cause.Fault), u64(op.Stop_Outcome.Failed)},
	}
	for pair in bad_pairs {
		_, pair_ok := stop_notice_from_record({kind = u32(Stop_Notice_Kind.Process_Stopped), values = {2, 9, pair[0], pair[1], 0, 0, 0}})
		testing.expectf(t, !pair_ok, "impossible stop pair (%d, %d) accepted", pair[0], pair[1])
	}
	// Process_Abandoned refuses any non-zero cause or outcome.
	_, ok = stop_notice_from_record({kind = u32(Stop_Notice_Kind.Process_Abandoned), values = {2, 9, u64(op.Stop_Cause.Holder), 0, 0, 0, 0}})
	testing.expect(t, !ok)
	_, ok = stop_notice_from_record({kind = u32(Stop_Notice_Kind.Process_Abandoned), values = {2, 9, 0, u64(op.Stop_Outcome.Done), 0, 0, 0}})
	testing.expect(t, !ok)
}

// Attenuated grant ceilings refuse over-privileged handles and empty rights.
@(test)
attenuated_rights_enforce_strict_least_privilege :: proc(t: ^testing.T) {
	_, ok := attenuated_rights_of(.None)
	testing.expect(t, !ok)
	testing.expect(t, !attenuated_rights_allowed(.None, {.Read}))
	testing.expect(t, !attenuated_rights_allowed(.Asker_Wiring_Budget, {}))
	testing.expect(t, !attenuated_rights_allowed(.Asker_Wiring_Budget, {.Spend, .Read}))
	testing.expect(t, !attenuated_rights_allowed(.Asker_Wiring_Budget, {.Spend, .Give}))
	testing.expect(t, attenuated_rights_allowed(.Asker_Wiring_Budget, {.Spend}))

	testing.expect(t, !attenuated_rights_allowed(.Stream_Process_Token, {}))
	testing.expect(t, !attenuated_rights_allowed(.Stream_Process_Token, {.Give, .Control}))
	testing.expect(t, !attenuated_rights_allowed(.Stream_Process_Token, {.Give, .Debug}))
	testing.expect(t, !attenuated_rights_allowed(.Stream_Process_Token, {.Give, .Read}))
	testing.expect(t, attenuated_rights_allowed(.Stream_Process_Token, {.Give}))

	testing.expect(t, !attenuated_rights_allowed(.Read_Only_Image, {.Read, .Write}))
	testing.expect(t, !attenuated_rights_allowed(.Read_Only_Image, {.Read, .Execute}))
	testing.expect(t, attenuated_rights_allowed(.Read_Only_Image, {.Read}))

	testing.expect(t, !attenuated_rights_allowed(.Process_Wiring_Ring, {.Read, .Write, .Give}))
	testing.expect(t, attenuated_rights_allowed(.Process_Wiring_Ring, {.Read, .Write}))
}

// Region request and prepared start ends borders refuse corrupted payloads.
@(test)
region_payload_borders_refuse_corrupted_inputs :: proc(t: ^testing.T) {
	req := Resolved_Wiring_Request{form = u32(output.Wiring_List_Form.Wire), list_bytes = 64}
	// Bad form word.
	bad_req := req
	bad_req.form = 99
	_, ok := resolved_request_check(&bad_req)
	testing.expect(t, !ok)
	// List bytes too small and too large.
	for bad_len in ([?]u32{0, 63, REGION_LIST_SIZE + 1, max(u32)}) {
		bad_req = req
		bad_req.list_bytes = bad_len
		_, ok = resolved_request_check(&bad_req)
		testing.expect(t, !ok)
	}
	// Wire with non-zero child module slice, Start with zero child module slice.
	bad_req = req
	bad_req.child_module_offset = 4096
	_, ok = resolved_request_check(&bad_req)
	testing.expect(t, !ok)
	bad_req = Resolved_Wiring_Request{form = u32(output.Wiring_List_Form.Start), list_bytes = 64}
	_, ok = resolved_request_check(&bad_req)
	testing.expect(t, !ok)
	// Counts past bounds.
	bad_req = req
	bad_req.lent_count = output.WIRING_LIST_HANDLE_LIMIT + 1
	_, ok = resolved_request_check(&bad_req)
	testing.expect(t, !ok)
	bad_req = req
	bad_req.connected_count = RESOLVED_CONNECTED_LIMIT + 1
	_, ok = resolved_request_check(&bad_req)
	testing.expect(t, !ok)
	// Non-boolean flag byte and invalid present identity.
	bad_req = req
	bad_req.lent_count = 1
	bad_req.lent[0] = {process_slot = 0, process_serial = 1, present = 1}
	_, ok = resolved_request_check(&bad_req)
	testing.expect(t, !ok)
	bad_req.lent[0] = {process_slot = 1, process_serial = 1, present = 2}
	_, ok = resolved_request_check(&bad_req)
	testing.expect(t, !ok)

	// Prepared_Start_Ends: batch mismatch, mismatched log pair, Asker_End in child ends,
	// Reader_End with no description, Writer_End with description.
	out: [output.WIRING_LIST_ROW_LIMIT]output.Given_End
	payload := Prepared_Start_Ends{batch_id = 3, child_end_count = 1}
	payload.child_ends[0] = {command = u32(output.Wiring_Command.Writer_End), tag = 1, ring = 10, index = 1, end_words = 11}
	_, ok = prepared_start_ends_check(&payload, 4, out[:])
	testing.expect(t, !ok)
	bad_payload := payload
	bad_payload.log_ring = 5
	_, ok = prepared_start_ends_check(&bad_payload, 3, out[:])
	testing.expect(t, !ok)
	bad_payload = payload
	bad_payload.child_ends[0].command = u32(output.Wiring_Command.Asker_End)
	_, ok = prepared_start_ends_check(&bad_payload, 3, out[:])
	testing.expect(t, !ok)
	bad_payload = payload
	bad_payload.child_ends[0].index = module.RECORD_STREAM_INDEX_MOST + 1
	_, ok = prepared_start_ends_check(&bad_payload, 3, out[:])
	testing.expect(t, !ok)
	bad_payload = payload
	bad_payload.child_ends[0] = {command = u32(output.Wiring_Command.Reader_End), tag = 1, ring = 10, index = 1, end_words = 11, description = 0}
	_, ok = prepared_start_ends_check(&bad_payload, 3, out[:])
	testing.expect(t, !ok)
	bad_payload = payload
	bad_payload.child_ends[0].description = 12
	_, ok = prepared_start_ends_check(&bad_payload, 3, out[:])
	testing.expect(t, !ok)
}

// Valid round-trip cases for commands, responses, stop notices, and region payloads.
@(test)
valid_commands_responses_and_stop_notices_round_trip :: proc(t: ^testing.T) {
	commands := [?]Command {
		{kind = .Register_Process, tag = 1, process = {3, 42}, module_offset = 4096, module_size = 8192, process_handle = 12, wiring_ring_handle = 13, flags = {.Is_Service, .Has_Wiring_Ring}},
		{kind = .Grant_Asker_Budget, tag = 2, process = {4, 19}, budget_handle = 20},
		{kind = .List_Page, tag = 3, process = {4, 19}},
		{kind = .Wire, tag = 4, process = {4, 19}, flags = {.Can_Wire, .Acts_For_Principal}},
		{kind = .Prepare_Start_Wiring, tag = 5, process = {4, 19}, flags = {.Is_Start_Policy}, module_offset = 16384, module_size = 4096},
		{kind = .Commit_Start_Wiring, tag = 6, batch_id = 7, process = {8, 99}},
		{kind = .Abort_Start_Wiring, tag = 7, batch_id = 7},
		{kind = .Unwire, tag = 8, process = {4, 19}, wiring_number = 55, end_word = .Revoked},
		{kind = .Revoke_Asker, tag = 9, process = {4, 19}},
		{kind = .Query, tag = 10, query_kind = .Machine_Totals},
		{kind = .Query, tag = 11, query_kind = .Asker_Count, process = {4, 19}},
		{kind = .Query, tag = 12, query_kind = .Process_Ends, process = {8, 99}},
	}
	for expected in commands {
		rec := command_to_record(expected)
		decoded, ok := command_from_record(rec)
		testing.expectf(t, ok, "valid command %v was refused", expected.kind)
		testing.expect_value(t, decoded, expected)
	}

	// Valid responses including error records.
	ok_list := Response{outcome = .Succeeded, tag = 3, list_page = 14, wiring_ring = 15}
	got_list, ok_l := response_from_record(response_to_record(ok_list, .List_Page), .List_Page)
	testing.expect(t, ok_l)
	testing.expect_value(t, got_list, ok_list)

	ok_wire := Response{outcome = .Succeeded, tag = 4, wiring_number = 9, asker_active = 3}
	got_wire, ok_w := response_from_record(response_to_record(ok_wire, .Wire), .Wire)
	testing.expect(t, ok_w)
	testing.expect_value(t, got_wire, ok_wire)

	err_rec := errors.error_make(.Full, .Wirings, 0, 9, 8)
	err_rec.operation = 29
	err_resp := Response{outcome = .Budget_Or_Capacity_Exhausted, tag = 4, error_record = err_rec}
	got_err, ok_e := response_from_record(response_to_record(err_resp, .Wire), .Wire)
	testing.expect(t, ok_e)
	testing.expect_value(t, got_err, err_resp)

	// Valid stop notices: every legal Stop_Cause and Stop_Outcome combination plus Abandoned.
	for cause in op.Stop_Cause {
		if cause == .None {
			continue
		}
		if cause == .Itself {
			for outcome in op.Stop_Outcome {
				if outcome == .None {
					continue
				}
				notice := Process_Stop_Notice{process_slot = 5, process_serial = 100, kind = .Process_Stopped, cause = cause, outcome = outcome}
				decoded, ok_s := stop_notice_from_record(stop_notice_to_record(notice))
				testing.expect(t, ok_s)
				testing.expect_value(t, decoded, notice)
			}
			continue
		}
		notice := Process_Stop_Notice{process_slot = 5, process_serial = 100, kind = .Process_Stopped, cause = cause, outcome = .None}
		decoded, ok_s := stop_notice_from_record(stop_notice_to_record(notice))
		testing.expect(t, ok_s)
		testing.expect_value(t, decoded, notice)
	}
	abandoned := Process_Stop_Notice{process_slot = 6, process_serial = 101, kind = .Process_Abandoned}
	decoded_abandoned, ok_a := stop_notice_from_record(stop_notice_to_record(abandoned))
	testing.expect(t, ok_a)
	testing.expect_value(t, decoded_abandoned, abandoned)

	// Valid region payloads.
	req := Resolved_Wiring_Request{
		form = u32(output.Wiring_List_Form.Start),
		list_bytes = 256,
		lent_count = 1,
		connected_count = 1,
		child_module_offset = 4096,
		child_module_size = 8192,
	}
	req.lent[0] = {process_slot = 2, process_serial = 11, started_by_asker = 1, present = 1}
	req.connected[0] = {process_slot = 3, process_serial = 12, handle_number = 7, asker_acts_for_principal = 1, process_is_a_service = 1, asker_holds_a_connection = 1, present = 1}
	form, req_ok := resolved_request_check(&req)
	testing.expect(t, req_ok)
	testing.expect_value(t, form, output.Wiring_List_Form.Start)

	out: [output.WIRING_LIST_ROW_LIMIT]output.Given_End
	payload := Prepared_Start_Ends{batch_id = 3, child_end_count = 2, asker_wiring_count = 1, log_ring = 20, log_end_words = 21}
	payload.asker_numbers[0] = 44
	writer_end := output.Given_End{command = .Writer_End, tag = 1, ring = 30, index = 1, pace = .Always_Holds_Writer, end_words = 31, condition = 32}
	reader_end := output.Given_End{command = .Reader_End, tag = 2, ring = 40, index = 2, terms = 41, description = 42, end_words = 43, filter = .By_Writer}
	payload.child_ends[0] = given_end_to_prepared(writer_end)
	payload.child_ends[1] = given_end_to_prepared(reader_end)
	count, p_ok := prepared_start_ends_check(&payload, 3, out[:])
	testing.expect(t, p_ok)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, out[0], writer_end)
	testing.expect_value(t, out[1], reader_end)
}
