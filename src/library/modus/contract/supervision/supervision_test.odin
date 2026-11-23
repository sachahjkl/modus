#+build !freestanding
package supervision

import "core:testing"
import "modus:contract/call_outcome"
import op "modus:contract/operation"
import "modus:contract/role_contract"

@(test)
border_converters_refuse_zero_and_unknown_words :: proc(t: ^testing.T) {
	// Restart_Strategy: edges first (0, past max, u32 max, u64 max).
	for bad in ([?]u64{0, u64(Restart_Strategy.Rest_For_One) + 1, 99, u64(max(u32)), max(u64)}) {
		strategy, ok := restart_strategy_from_word(bad)
		testing.expectf(t, !ok && strategy == .None, "restart strategy word %d must be refused", bad)
	}
	for member in Restart_Strategy {
		if member == .None {
			continue
		}
		parsed, ok := restart_strategy_from_word(u64(member))
		testing.expectf(t, ok && parsed == member, "restart strategy %v must round-trip", member)
	}

	// Connection_State: edges first.
	for bad in ([?]u64{0, u64(Connection_State.Closed) + 1, 42, u64(max(u32)), max(u64)}) {
		state, ok := connection_state_from_word(bad)
		testing.expectf(t, !ok && state == .None, "connection state word %d must be refused", bad)
	}
	for member in Connection_State {
		if member == .None {
			continue
		}
		parsed, ok := connection_state_from_word(u64(member))
		testing.expectf(t, ok && parsed == member, "connection state %v must round-trip", member)
	}

	// Call_Replay_Rule: edges first.
	for bad in ([?]u64{0, u64(Call_Replay_Rule.Serial_Tracked) + 1, 100, u64(max(u32)), max(u64)}) {
		rule, ok := call_replay_rule_from_word(bad)
		testing.expectf(t, !ok && rule == .None, "call replay rule word %d must be refused", bad)
	}
	for member in Call_Replay_Rule {
		if member == .None {
			continue
		}
		parsed, ok := call_replay_rule_from_word(u64(member))
		testing.expectf(t, ok && parsed == member, "call replay rule %v must round-trip", member)
	}

	// Escalation_Action: edges first.
	for bad in ([?]u64{0, u64(Escalation_Action.Stop_Permanently) + 1, 255, u64(max(u32)), max(u64)}) {
		action, ok := escalation_action_from_word(bad)
		testing.expectf(t, !ok && action == .None, "escalation action word %d must be refused", bad)
	}
	for member in Escalation_Action {
		if member == .None {
			continue
		}
		parsed, ok := escalation_action_from_word(u64(member))
		testing.expectf(t, ok && parsed == member, "escalation action %v must round-trip", member)
	}
}

@(test)
connection_page_border_refuses_corrupt_and_inconsistent_pages :: proc(t: ^testing.T) {
	// Null page refused everywhere.
	_, refusal := connection_page_read(nil)
	testing.expect_value(t, refusal, Connection_Page_Refusal.Null_Page)
	testing.expect_value(t, connection_page_initialize(nil, 1, .Storage, 1), Connection_Page_Refusal.Null_Page)

	// Zero-initialized page has bad magic.
	empty_page: Connection_Page
	_, refusal = connection_page_read(&empty_page)
	testing.expect_value(t, refusal, Connection_Page_Refusal.Bad_Magic)

	// Initialize rejects bad inputs and leaves page untouched.
	testing.expect_value(t, connection_page_initialize(&empty_page, 0, .Storage, 1), Connection_Page_Refusal.Zero_Connection_Serial)
	testing.expect_value(t, connection_page_initialize(&empty_page, 1, .Storage, 0), Connection_Page_Refusal.Zero_Holder_Generation)
	testing.expect_value(t, connection_page_initialize(&empty_page, 1, .None, 1), Connection_Page_Refusal.Invalid_Role)
	testing.expect_value(t, connection_page_initialize(&empty_page, 1, role_contract.Role(999), 1), Connection_Page_Refusal.Invalid_Role)
	testing.expect_value(t, empty_page, Connection_Page{})

	// Build a valid base page and corrupt each field one by one.
	base: Connection_Page
	testing.expect_value(t, connection_page_initialize(&base, 7, .Storage, 10), Connection_Page_Refusal.None)

	// Bad version (0, 2, max(u32)).
	for bad_ver in ([?]u32{0, CONNECTION_PAGE_VERSION + 1, max(u32)}) {
		p := base
		p.version = bad_ver
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Bad_Version)
	}

	// Non-zero reserved word at every slot.
	for idx in 0 ..< len(base.reserved) {
		p := base
		p.reserved[idx] = 1
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Reserved_Not_Zero)
	}

	// Zero connection_serial and zero holder_generation.
	{
		p := base
		p.connection_serial = 0
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Zero_Connection_Serial)
	}
	{
		p := base
		p.holder_generation = 0
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Zero_Holder_Generation)
	}

	// Invalid role words.
	for bad_role in ([?]u64{0, u64(max(role_contract.Role)) + 1, max(u64)}) {
		p := base
		p.role_word = bad_role
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Invalid_Role)
	}

	// Invalid state words.
	for bad_state in ([?]u32{0, u32(Connection_State.Closed) + 1, max(u32)}) {
		p := base
		p.state_word = bad_state
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Invalid_State)
	}

	// Active states (Connected, Reconnecting) must not carry stop words.
	for active_state in ([?]Connection_State{.Connected, .Reconnecting}) {
		p := base
		p.state_word = u32(active_state)
		p.stop_cause_word = u32(op.Stop_Cause.Fault)
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Stop_Words_While_Active)

		p2 := base
		p2.state_word = u32(active_state)
		p2.stop_outcome_word = u32(op.Stop_Outcome.Failed)
		_, r2 := connection_page_read(&p2)
		testing.expect_value(t, r2, Connection_Page_Refusal.Stop_Words_While_Active)
	}

	// Holder_Stopped with invalid stop word pairs is refused.
	{
		p := base
		p.state_word = u32(Connection_State.Holder_Stopped)
		// Cause None is invalid for a stopped holder.
		p.stop_cause_word = 0
		p.stop_outcome_word = 0
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Invalid_Stop_Words)

		// Cause Itself with Outcome None is invalid.
		p.stop_cause_word = u32(op.Stop_Cause.Itself)
		p.stop_outcome_word = 0
		_, r = connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Invalid_Stop_Words)

		// Cause Fault with non-zero Outcome is invalid.
		p.stop_cause_word = u32(op.Stop_Cause.Fault)
		p.stop_outcome_word = u32(op.Stop_Outcome.Failed)
		_, r = connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Invalid_Stop_Words)

		// Unknown stop cause word.
		p.stop_cause_word = 999
		p.stop_outcome_word = 0
		_, r = connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Invalid_Stop_Words)
	}

	// Odd change_count (stalled concurrent writer) stops cleanly after bounded retries.
	{
		p := base
		p.change_count = 3
		_, r := connection_page_read(&p)
		testing.expect_value(t, r, Connection_Page_Refusal.Concurrent_Write_In_Progress)
	}
}

@(test)
connection_page_enforces_state_machine_and_surviving_reconnect :: proc(t: ^testing.T) {
	page: Connection_Page
	testing.expect_value(t, connection_page_initialize(&page, 42, .Display, 100), Connection_Page_Refusal.None)

	// Invalid transitions from Connected leave page untouched.
	before := page
	testing.expect_value(t, connection_page_begin_reconnect(&page), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, connection_page_complete_reconnect(&page, 101), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .None, .None), Connection_Page_Refusal.Invalid_Stop_Words)
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .Failed), Connection_Page_Refusal.Invalid_Stop_Words)
	testing.expect_value(t, page, before)

	// Commit request serial 5 with 2 pending calls; regressed serial 4 is refused.
	testing.expect_value(t, connection_page_record_commit(&page, 5, 2), Connection_Page_Refusal.None)
	before_regress := page
	testing.expect_value(t, connection_page_record_commit(&page, 4, 1), Connection_Page_Refusal.Request_Serial_Regressed)
	testing.expect_value(t, page, before_regress)

	// Holder faults: page moves to Holder_Stopped while preserving connection_serial and last committed serial.
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .None), Connection_Page_Refusal.None)
	snap, r := connection_page_read(&page)
	testing.expect_value(t, r, Connection_Page_Refusal.None)
	testing.expect_value(t, snap.connection_serial, u64(42))
	testing.expect_value(t, snap.role, role_contract.Role.Display)
	testing.expect_value(t, snap.state, Connection_State.Holder_Stopped)
	testing.expect_value(t, snap.holder_generation, u64(100))
	testing.expect_value(t, snap.stop_cause, op.Stop_Cause.Fault)
	testing.expect_value(t, snap.stop_outcome, op.Stop_Outcome.None)
	testing.expect_value(t, snap.pending_call_count, u32(2))
	testing.expect_value(t, snap.last_committed_request_serial, u64(5))

	// Commits are refused while Holder_Stopped; second Holder_Stopped transition refused.
	before_stopped := page
	testing.expect_value(t, connection_page_record_commit(&page, 6, 1), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .None), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, page, before_stopped)

	// Transition to Reconnecting clears stop words.
	testing.expect_value(t, connection_page_begin_reconnect(&page), Connection_Page_Refusal.None)
	snap, r = connection_page_read(&page)
	testing.expect_value(t, r, Connection_Page_Refusal.None)
	testing.expect_value(t, snap.state, Connection_State.Reconnecting)
	testing.expect_value(t, snap.stop_cause, op.Stop_Cause.None)
	testing.expect_value(t, snap.stop_outcome, op.Stop_Outcome.None)

	// Completing reconnect with old or equal generation is refused and leaves page unchanged.
	before_reconn := page
	testing.expect_value(t, connection_page_complete_reconnect(&page, 100), Connection_Page_Refusal.Holder_Generation_Not_Advanced)
	testing.expect_value(t, connection_page_complete_reconnect(&page, 99), Connection_Page_Refusal.Holder_Generation_Not_Advanced)
	testing.expect_value(t, connection_page_complete_reconnect(&page, 0), Connection_Page_Refusal.Holder_Generation_Not_Advanced)
	testing.expect_value(t, page, before_reconn)

	// Completing reconnect with new generation 101 restores Connected on the SAME connection_serial!
	testing.expect_value(t, connection_page_complete_reconnect(&page, 101), Connection_Page_Refusal.None)
	snap, r = connection_page_read(&page)
	testing.expect_value(t, r, Connection_Page_Refusal.None)
	testing.expect_value(t, snap.connection_serial, u64(42))
	testing.expect_value(t, snap.holder_generation, u64(101))
	testing.expect_value(t, snap.state, Connection_State.Connected)
	testing.expect_value(t, snap.last_committed_request_serial, u64(5))

	// Close with invalid stop words refused; valid stop words closes permanently.
	before_close := page
	testing.expect_value(t, connection_page_close(&page, .Itself, .None), Connection_Page_Refusal.Invalid_Stop_Words)
	testing.expect_value(t, page, before_close)

	testing.expect_value(t, connection_page_close(&page, .Itself, .Failed), Connection_Page_Refusal.None)
	snap, r = connection_page_read(&page)
	testing.expect_value(t, r, Connection_Page_Refusal.None)
	testing.expect_value(t, snap.state, Connection_State.Closed)
	testing.expect_value(t, snap.stop_cause, op.Stop_Cause.Itself)
	testing.expect_value(t, snap.stop_outcome, op.Stop_Outcome.Failed)
	testing.expect_value(t, snap.pending_call_count, u32(0))

	// Closed is terminal: every subsequent transition is refused and changes nothing.
	closed_snapshot := page
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .None), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, connection_page_begin_reconnect(&page), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, connection_page_complete_reconnect(&page, 200), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, connection_page_close(&page), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, connection_page_set_pending_calls(&page, 1), Connection_Page_Refusal.Invalid_Transition)
	testing.expect_value(t, page, closed_snapshot)
}

@(test)
request_serial_log_deduplicates_and_blocks_replays :: proc(t: ^testing.T) {
	log: Request_Serial_Log

	// Invalid inputs refused and leave log unchanged.
	st, res := request_serial_log_check(nil, 1, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Invalid_Input)
	testing.expect_value(t, res, u64(0))
	st, _ = request_serial_log_check(&log, 0, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Invalid_Input)
	st, _ = request_serial_log_check(&log, 1, 0)
	testing.expect_value(t, st, Serial_Lookup_Status.Invalid_Input)

	testing.expect_value(t, request_serial_log_commit(nil, 1, 1, 10), Serial_Commit_Refusal.Zero_Client_Id)
	testing.expect_value(t, request_serial_log_commit(&log, 0, 1, 10), Serial_Commit_Refusal.Zero_Client_Id)
	testing.expect_value(t, request_serial_log_commit(&log, 1, 0, 10), Serial_Commit_Refusal.Zero_Request_Serial)
	testing.expect_value(t, log, Request_Serial_Log{})

	// Fresh serial returns Execute_New; after commit, replay returns Already_Committed with stored result_word.
	st, _ = request_serial_log_check(&log, 10, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Execute_New)
	testing.expect_value(t, request_serial_log_commit(&log, 10, 1, 0xCAFE_0001), Serial_Commit_Refusal.None)

	st, res = request_serial_log_check(&log, 10, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Already_Committed)
	testing.expect_value(t, res, u64(0xCAFE_0001))

	// Duplicate commit with different result is refused and does not overwrite stored result.
	before_dup := log
	testing.expect_value(t, request_serial_log_commit(&log, 10, 1, 0xDEAD_BEEF), Serial_Commit_Refusal.Duplicate_Serial)
	testing.expect_value(t, log, before_dup)
	st, res = request_serial_log_check(&log, 10, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Already_Committed)
	testing.expect_value(t, res, u64(0xCAFE_0001))

	// Separate client with same request_serial 1 executes independently.
	st, _ = request_serial_log_check(&log, 20, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Execute_New)
	testing.expect_value(t, request_serial_log_commit(&log, 20, 1, 0xBEEF_0001), Serial_Commit_Refusal.None)
	st, res = request_serial_log_check(&log, 20, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Already_Committed)
	testing.expect_value(t, res, u64(0xBEEF_0001))

	// Sliding window: commit serials 2..20 for client 10.
	for serial in u64(2) ..= 20 {
		testing.expect_value(t, request_serial_log_commit(&log, 10, serial, 0xCAFE_0000 + serial), Serial_Commit_Refusal.None)
	}
	// Newest REQUEST_SERIALS_IN_FLIGHT (13..20) return exact cached results.
	for serial in u64(20 - REQUEST_SERIALS_IN_FLIGHT + 1) ..= 20 {
		st, res = request_serial_log_check(&log, 10, serial)
		testing.expect_value(t, st, Serial_Lookup_Status.Already_Committed)
		testing.expect_value(t, res, 0xCAFE_0000 + serial)
	}
	// Evicted older serials (1..12) are blocked as Serial_Too_Old, never re-executed!
	for serial in u64(1) ..= u64(20 - REQUEST_SERIALS_IN_FLIGHT) {
		st, res = request_serial_log_check(&log, 10, serial)
		testing.expect_value(t, st, Serial_Lookup_Status.Serial_Too_Old)
		testing.expect_value(t, res, u64(0))
		testing.expect_value(t, request_serial_log_commit(&log, 10, serial, 999), Serial_Commit_Refusal.Serial_Too_Old)
	}

	// Out-of-order execution inside the 8-call in-flight window: commit 25 before 22.
	testing.expect_value(t, request_serial_log_commit(&log, 10, 25, 0x5555), Serial_Commit_Refusal.None)
	st, _ = request_serial_log_check(&log, 10, 22)
	testing.expect_value(t, st, Serial_Lookup_Status.Execute_New)
	testing.expect_value(t, request_serial_log_commit(&log, 10, 22, 0x2222), Serial_Commit_Refusal.None)
	st, res = request_serial_log_check(&log, 10, 22)
	testing.expect_value(t, st, Serial_Lookup_Status.Already_Committed)
	testing.expect_value(t, res, u64(0x2222))

	// Table full behavior: fill all REQUEST_LOG_CLIENT_CAPACITY slots, verify refusal, remove one, verify recovery.
	request_serial_log_clear(&log)
	for cid in u64(1) ..= u64(REQUEST_LOG_CLIENT_CAPACITY) {
		testing.expect_value(t, request_serial_log_commit(&log, cid, 1, cid * 100), Serial_Commit_Refusal.None)
	}
	full_before := log
	st, _ = request_serial_log_check(&log, REQUEST_LOG_CLIENT_CAPACITY + 1, 1)
	testing.expect_value(t, st, Serial_Lookup_Status.Table_Full)
	testing.expect_value(t, request_serial_log_commit(&log, REQUEST_LOG_CLIENT_CAPACITY + 1, 1, 777), Serial_Commit_Refusal.Table_Full)
	testing.expect_value(t, log, full_before)

	// Removing client 5 frees a slot for a new client.
	testing.expect(t, !request_serial_log_remove_client(&log, 0))
	testing.expect(t, !request_serial_log_remove_client(&log, 9999))
	testing.expect(t, request_serial_log_remove_client(&log, 5))
	testing.expect_value(t, request_serial_log_commit(&log, REQUEST_LOG_CLIENT_CAPACITY + 1, max(u64), 0xABCD), Serial_Commit_Refusal.None)
	st, res = request_serial_log_check(&log, REQUEST_LOG_CLIENT_CAPACITY + 1, max(u64))
	testing.expect_value(t, st, Serial_Lookup_Status.Already_Committed)
	testing.expect_value(t, res, u64(0xABCD))
}

@(test)
client_retry_refuses_invalid_inputs_and_not_idempotent_resends :: proc(t: ^testing.T) {
	connected_gen1 := Connection_Snapshot {
		connection_serial = 1,
		holder_generation = 10,
		role              = .Storage,
		state             = .Connected,
	}
	stopped_gen1 := Connection_Snapshot {
		connection_serial = 1,
		holder_generation = 10,
		role              = .Storage,
		state             = .Holder_Stopped,
		stop_cause        = .Fault,
	}
	connected_gen2 := Connection_Snapshot {
		connection_serial = 1,
		holder_generation = 11,
		role              = .Storage,
		state             = .Connected,
	}

	// client_call_begin refuses bad rules, non-Connected states, zero gen, and zero serial for Serial_Tracked.
	_, ok := client_call_begin(.None, 1, connected_gen1)
	testing.expect(t, !ok)
	_, ok = client_call_begin(Call_Replay_Rule(99), 1, connected_gen1)
	testing.expect(t, !ok)
	_, ok = client_call_begin(.Idempotent, 0, stopped_gen1)
	testing.expect(t, !ok)
	_, ok = client_call_begin(.Serial_Tracked, 0, connected_gen1)
	testing.expect(t, !ok)
	zero_gen := connected_gen1
	zero_gen.holder_generation = 0
	_, ok = client_call_begin(.Idempotent, 0, zero_gen)
	testing.expect(t, !ok)

	// Not_Idempotent never auto-resends on Holder_Stopped.
	tracker, began := client_call_begin(.Not_Idempotent, 0, connected_gen1)
	testing.expect(t, began)
	testing.expect_value(t, client_call_on_connection_change(&tracker, stopped_gen1), Client_Retry_Decision.Return_Holder_Stopped_In_Flight)
	testing.expect_value(t, tracker.state, Client_Call_State.Failed)
	testing.expect_value(t, tracker.retries_used, u32(0))
	// Further updates on a Failed tracker are refused.
	testing.expect_value(t, client_call_on_connection_change(&tracker, connected_gen2), Client_Retry_Decision.Refuse_Invalid_Input)

	// Not_Idempotent also refuses direct holder generation jump (Connected gen 1 -> Connected gen 2).
	tracker2, began2 := client_call_begin(.Not_Idempotent, 0, connected_gen1)
	testing.expect(t, began2)
	testing.expect_value(t, client_call_on_connection_change(&tracker2, connected_gen2), Client_Retry_Decision.Return_Holder_Stopped_In_Flight)
	testing.expect_value(t, tracker2.state, Client_Call_State.Failed)
	testing.expect_value(t, tracker2.retries_used, u32(0))

	// Holder generation regression is refused without mutating tracker.
	tracker3, began3 := client_call_begin(.Idempotent, 0, connected_gen2)
	testing.expect(t, began3)
	before_reg := tracker3
	testing.expect_value(t, client_call_on_connection_change(&tracker3, connected_gen1), Client_Retry_Decision.Refuse_Invalid_Input)
	testing.expect_value(t, tracker3, before_reg)
}

@(test)
client_retry_enforces_idempotent_recovery_and_single_retry_bound :: proc(t: ^testing.T) {
	page: Connection_Page
	testing.expect_value(t, connection_page_initialize(&page, 9, .Storage, 1), Connection_Page_Refusal.None)
	snap1, _ := connection_page_read(&page)

	tracker, ok := client_call_begin(.Idempotent, 0, snap1)
	testing.expect(t, ok)

	// Same generation Connected -> Continue_Waiting.
	testing.expect_value(t, client_call_on_connection_change(&tracker, snap1), Client_Retry_Decision.Continue_Waiting)

	// Holder stops -> Waiting_For_Reconnect.
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .None), Connection_Page_Refusal.None)
	snap_stop, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&tracker, snap_stop), Client_Retry_Decision.Continue_Waiting)
	testing.expect_value(t, tracker.state, Client_Call_State.Waiting_For_Reconnect)

	// Seeing old generation Connected while Waiting_For_Reconnect is refused.
	testing.expect_value(t, client_call_on_connection_change(&tracker, snap1), Client_Retry_Decision.Refuse_Invalid_Input)

	// Reconnecting -> Continue_Waiting.
	testing.expect_value(t, connection_page_begin_reconnect(&page), Connection_Page_Refusal.None)
	snap_reconn, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&tracker, snap_reconn), Client_Retry_Decision.Continue_Waiting)

	// New holder gen 2 connects -> Resend_To_New_Holder once!
	testing.expect_value(t, connection_page_complete_reconnect(&page, 2), Connection_Page_Refusal.None)
	snap2, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&tracker, snap2), Client_Retry_Decision.Resend_To_New_Holder)
	testing.expect_value(t, tracker.state, Client_Call_State.Ready_To_Resend)
	testing.expect_value(t, tracker.retries_used, u32(1))
	testing.expect_value(t, tracker.sent_holder_generation, u64(2))

	// Client marks resent and transitions back to In_Flight.
	testing.expect(t, client_call_mark_resent(&tracker))
	testing.expect(t, !client_call_mark_resent(&tracker))
	testing.expect_value(t, tracker.state, Client_Call_State.In_Flight)

	// New holder gen 2 ALSO crashes! Must NOT retry a second time -> Return_Holder_Stopped_In_Flight.
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .None), Connection_Page_Refusal.None)
	snap_stop2, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&tracker, snap_stop2), Client_Retry_Decision.Return_Holder_Stopped_In_Flight)
	testing.expect_value(t, tracker.state, Client_Call_State.Failed)
	testing.expect_value(t, tracker.retries_used, MAX_AUTOMATIC_RETRIES)

	// Even if gen 3 comes up, this failed call never loops.
	testing.expect_value(t, connection_page_complete_reconnect(&page, 3), Connection_Page_Refusal.None)
	snap3, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&tracker, snap3), Client_Retry_Decision.Refuse_Invalid_Input)

	// Separate call observes Closed connection -> Return_Connection_Closed.
	tracker_closed, ok_closed := client_call_begin(.Idempotent, 0, snap3)
	testing.expect(t, ok_closed)
	testing.expect_value(t, connection_page_close(&page, .Itself, .Failed), Connection_Page_Refusal.None)
	snap_closed, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&tracker_closed, snap_closed), Client_Retry_Decision.Return_Connection_Closed)
	testing.expect_value(t, tracker_closed.state, Client_Call_State.Failed)
}

@(test)
serial_tracked_end_to_end_guarantees_at_most_once_across_restart :: proc(t: ^testing.T) {
	// Simulate a stateful holder that executes a mutation once per fresh
	// request_serial and persists Request_Serial_Log across crashes.
	Simulated_Holder :: struct {
		serial_log:      Request_Serial_Log,
		execution_count: u64,
		counter_value:   u64,
	}
	handle_increment :: proc(holder: ^Simulated_Holder, client_id: u64, request_serial: u64) -> (result_word: u64, ok: bool) {
		status, stored := request_serial_log_check(&holder.serial_log, client_id, request_serial)
		switch status {
		case .Already_Committed:
			// Replay deduplicated: return stored result without re-executing!
			return stored, true
		case .Execute_New:
			holder.execution_count += 1
			holder.counter_value += 10
			res := holder.counter_value
			if request_serial_log_commit(&holder.serial_log, client_id, request_serial, res) != .None {
				return 0, false
			}
			return res, true
		case .Serial_Too_Old, .Invalid_Input, .Table_Full:
			return 0, false
		}
		return 0, false
	}

	page: Connection_Page
	client_id :: u64(77)
	testing.expect_value(t, connection_page_initialize(&page, client_id, .Storage, 1), Connection_Page_Refusal.None)
	holder: Simulated_Holder

	// Case A: holder crashes AFTER committing serial 1, BEFORE sending reply to client.
	snap1, _ := connection_page_read(&page)
	call_a, ok_a := client_call_begin(.Serial_Tracked, 1, snap1)
	testing.expect(t, ok_a)

	// Old holder executes and commits serial 1, then faults before client gets answer.
	committed_res, handled := handle_increment(&holder, client_id, call_a.request_serial)
	testing.expect(t, handled)
	testing.expect_value(t, committed_res, u64(10))
	testing.expect_value(t, holder.execution_count, u64(1))
	testing.expect_value(t, connection_page_record_commit(&page, 1, 1), Connection_Page_Refusal.None)
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .None), Connection_Page_Refusal.None)

	snap_stop, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&call_a, snap_stop), Client_Retry_Decision.Continue_Waiting)

	// New holder gen 2 takes over with persisted serial_log.
	testing.expect_value(t, connection_page_complete_reconnect(&page, 2), Connection_Page_Refusal.None)
	snap2, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&call_a, snap2), Client_Retry_Decision.Resend_To_New_Holder)
	testing.expect_value(t, call_a.request_serial, u64(1)) // Exact same serial!
	testing.expect(t, client_call_mark_resent(&call_a))

	// New holder receives replayed serial 1 -> returns cached 10 with ZERO double-execution!
	replay_res, replay_ok := handle_increment(&holder, client_id, call_a.request_serial)
	testing.expect(t, replay_ok)
	testing.expect_value(t, replay_res, u64(10))
	testing.expect_value(t, holder.execution_count, u64(1)) // Still 1!
	testing.expect_value(t, holder.counter_value, u64(10))  // Still 10!
	testing.expect_value(t, client_call_complete(&call_a, replay_res), Client_Retry_Decision.Complete_With_Answer)
	testing.expect_value(t, call_a.completed_result_word, u64(10))

	// Case B: holder crashes BEFORE committing serial 2.
	call_b, ok_b := client_call_begin(.Serial_Tracked, 2, snap2)
	testing.expect(t, ok_b)
	testing.expect_value(t, connection_page_mark_holder_stopped(&page, .Fault, .None), Connection_Page_Refusal.None)
	testing.expect_value(t, connection_page_complete_reconnect(&page, 3), Connection_Page_Refusal.None)
	snap3, _ := connection_page_read(&page)
	testing.expect_value(t, client_call_on_connection_change(&call_b, snap3), Client_Retry_Decision.Resend_To_New_Holder)
	testing.expect_value(t, call_b.request_serial, u64(2))
	testing.expect(t, client_call_mark_resent(&call_b))

	// New holder gen 3 executes serial 2 exactly once -> counter becomes 20.
	res_b, ok_exec_b := handle_increment(&holder, client_id, call_b.request_serial)
	testing.expect(t, ok_exec_b)
	testing.expect_value(t, res_b, u64(20))
	testing.expect_value(t, holder.execution_count, u64(2))
	testing.expect_value(t, client_call_complete(&call_b, res_b), Client_Retry_Decision.Complete_With_Answer)

	// Case C: old holder wrote completion before crashing -> client reads completion first, no replay needed.
	call_c, ok_c := client_call_begin(.Serial_Tracked, 3, snap3)
	testing.expect(t, ok_c)
	testing.expect_value(t, client_call_complete(&call_c, 30), Client_Retry_Decision.Complete_With_Answer)
	testing.expect_value(t, call_c.state, Client_Call_State.Completed)
	testing.expect_value(t, client_call_on_connection_change(&call_c, snap_stop), Client_Retry_Decision.Refuse_Invalid_Input)
}

// A decision that ends a call in flight with no answer gives an outcome in
// doubt, since the call left; each other decision ends no call that way.
@(test)
a_call_ended_in_flight_is_in_doubt :: proc(t: ^testing.T) {
	for decision in Client_Retry_Decision {
		outcome, ended := client_call_ended_outcome(decision)
		switch decision {
		case .Return_Holder_Stopped_In_Flight:
			testing.expect(t, ended && outcome == .Callee_Stopped_During_The_Call)
		case .Return_Connection_Closed:
			testing.expect(t, ended && outcome == .Connection_Ended_During_The_Call)
		case .None, .Continue_Waiting, .Complete_With_Answer, .Resend_To_New_Holder, .Refuse_Invalid_Input:
			testing.expectf(t, !ended, "the decision %v ends the call", decision)
		}
		if ended {
			testing.expect_value(t, call_outcome.effect_group_of(outcome), call_outcome.Effect_Group.Change_In_Doubt)
		}
	}
}
