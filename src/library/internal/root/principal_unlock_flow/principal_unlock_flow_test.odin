#+build !freestanding
package principal_unlock_flow

import "core:testing"
import "modus:contract/call_outcome"
import "modus:principals"

@(test)
storage_key_border_and_ring_room_refusals :: proc(t: ^testing.T) {
	flow: Flow
	good_key := [7]u64{1, 2, 3, 4, 1, 0, 0}

	// Trailing non-zero words refused before any state check.
	for bad_index in ([2]int{5, 6}) {
		bad := good_key
		bad[bad_index] = 1
		d := storage_key_check(&flow, bad, .Locked, false, true, 8)
		testing.expect(t, !d.send)
		testing.expect_value(t, d.outcome, call_outcome.Call_Outcome.Argument_Refused)
	}

	// Machine slot (0), bound (PRINCIPAL_CAPACITY), and max(u64) refused.
	for bad_slot in ([3]u64{principals.MACHINE, principals.PRINCIPAL_CAPACITY, max(u64)}) {
		bad := good_key
		bad[4] = bad_slot
		d := storage_key_check(&flow, bad, .Locked, false, true, 8)
		testing.expect(t, !d.send)
		testing.expect_value(t, d.outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	}

	// Absent, Creating, and zero identifier refused.
	testing.expect_value(t, storage_key_check(&flow, good_key, .Absent, false, true, 8).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	testing.expect_value(t, storage_key_check(&flow, good_key, .Creating, false, true, 8).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	testing.expect_value(t, storage_key_check(&flow, good_key, .Locked, true, true, 8).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)

	// Already unlocked session (In_Front) refused with Wrong_State.
	testing.expect_value(t, storage_key_check(&flow, good_key, .In_Front, false, true, 8).outcome, call_outcome.Call_Outcome.Wrong_State)

	// All-zero key refused.
	zero_key := [7]u64{0, 0, 0, 0, 1, 0, 0}
	testing.expect_value(t, storage_key_check(&flow, zero_key, .Locked, false, true, 8).outcome, call_outcome.Call_Outcome.Argument_Refused)

	// Missing storage holder refused.
	testing.expect_value(t, storage_key_check(&flow, good_key, .Locked, false, false, 8).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)

	// Ring with 0 or 1 free slot refuses atomically; 2 free slots accepts.
	testing.expect_value(t, storage_key_check(&flow, good_key, .Locked, false, true, 0).outcome, call_outcome.Call_Outcome.Callee_Busy)
	testing.expect_value(t, storage_key_check(&flow, good_key, .Locked, false, true, 1).outcome, call_outcome.Call_Outcome.Callee_Busy)
	d := storage_key_check(&flow, good_key, .Locked, false, true, 2)
	testing.expect(t, d.send)
	testing.expect_value(t, d.outcome, call_outcome.Call_Outcome.Succeeded)

	// Sending both marks awaiting and refuses a second key while awaiting.
	ok, owe := storage_key_sent(&flow, 1, true, true)
	testing.expect(t, ok && !owe)
	testing.expect(t, flow.key_awaiting[1])
	testing.expect_value(t, storage_key_check(&flow, good_key, .Locked, false, true, 8).outcome, call_outcome.Call_Outcome.Wrong_State)

	// Partial send (identity sent, key failed) owes an erase and leaves nothing awaiting.
	partial: Flow
	ok, owe = storage_key_sent(&partial, 1, true, false)
	testing.expect(t, !ok && owe)
	testing.expect(t, !partial.key_awaiting[1])
	testing.expect(t, partial.erase_owed[1])
}

@(test)
failed_unlock_and_abandoned_unlock_owe_storage_key_erase :: proc(t: ^testing.T) {
	flow: Flow
	good_key := [7]u64{9, 8, 7, 6, 1, 0, 0}

	// Send storage key, then principal_unlock fails (e.g. bad table key or seat refusal):
	// awaiting clears and erase becomes owed.
	ok, owe := storage_key_sent(&flow, 1, true, true)
	testing.expect(t, ok && !owe)
	testing.expect(t, unlock_finished(&flow, 1, false))
	testing.expect(t, !flow.key_awaiting[1])
	testing.expect(t, flow.erase_owed[1])

	// While erase is owed, a new storage key is refused with Callee_Busy.
	testing.expect_value(t, storage_key_check(&flow, good_key, .Locked, false, true, 8).outcome, call_outcome.Call_Outcome.Callee_Busy)

	// Once erase is delivered, the debt clears and a new unlock attempt can proceed.
	testing.expect(t, erase_attempt(&flow, 1, true, true))
	testing.expect(t, !flow.erase_owed[1])
	testing.expect(t, storage_key_check(&flow, good_key, .Locked, false, true, 2).send)

	// Unlock stops after sending storage key without ever sending Principal_Unlock:
	// unlock_stopped_collect marks the slot as owing an erase.
	ok, _ = storage_key_sent(&flow, 1, true, true)
	testing.expect(t, ok)
	owed := unlock_stopped_collect(&flow)
	testing.expect(t, owed[1])
	testing.expect(t, !flow.key_awaiting[1])
	testing.expect(t, flow.erase_owed[1])

	// Successful unlock clears awaiting without owing an erase.
	testing.expect(t, erase_attempt(&flow, 1, true, true))
	ok, _ = storage_key_sent(&flow, 1, true, true)
	testing.expect(t, ok)
	testing.expect(t, !unlock_finished(&flow, 1, true))
	testing.expect(t, !flow.key_awaiting[1])
	testing.expect(t, !flow.erase_owed[1])
}

@(test)
full_ring_at_lock_keeps_erase_owed_and_retries_until_room_or_stop :: proc(t: ^testing.T) {
	flow: Flow
	good_key := [7]u64{1, 1, 1, 1, 1, 0, 0}

	// Lock owes erase; ring is full -> debt stays owed and blocks next key.
	erase_owe(&flow, 1)
	testing.expect(t, flow.erase_owed[1])
	testing.expect(t, !erase_attempt(&flow, 1, true, false))
	testing.expect(t, flow.erase_owed[1])
	testing.expect_value(t, storage_key_check(&flow, good_key, .Locked, false, true, 8).outcome, call_outcome.Call_Outcome.Callee_Busy)

	// Second pass still full -> stays owed.
	testing.expect(t, !erase_attempt(&flow, 1, true, false))
	testing.expect(t, flow.erase_owed[1])

	// Ring frees room -> erase succeeds and debt clears.
	testing.expect(t, erase_attempt(&flow, 1, true, true))
	testing.expect(t, !flow.erase_owed[1])
	testing.expect(t, storage_key_check(&flow, good_key, .Locked, false, true, 2).send)

	// If storage service stops while erase is owed, its keys died with it: debt clears.
	erase_owe(&flow, 1)
	testing.expect(t, !erase_attempt(&flow, 1, true, false))
	testing.expect(t, erase_attempt(&flow, 1, false, false))
	testing.expect(t, !flow.erase_owed[1])
}

@(test)
seat_check_refuses_before_taking_key_and_machine_alone_refused_past_starting :: proc(t: ^testing.T) {
	// seat_next refuses Machine_Alone in every state past Starting.
	non_starting := [?]principals.Seat{
		{state = .Session, in_front = principals.MACHINE},
		{state = .Chooser},
		{state = .Unlock_Window},
		{state = .Session, in_front = 1},
	}
	for s in non_starting {
		next, ok := principals.seat_next(s, .Machine_Alone)
		testing.expect(t, !ok, "Machine_Alone must be refused past Starting")
		testing.expect_value(t, next, s)
	}
	// Machine_Alone succeeds from Starting only, and puts Machine in front.
	started, ok := principals.seat_next({state = .Starting}, .Machine_Alone)
	testing.expect(t, ok)
	testing.expect_value(t, started.state, principals.Seat_State.Session)
	testing.expect_value(t, started.in_front, principals.MACHINE)

	// unlock_precheck refuses out-of-range, Absent, non-Locked, zero id, and seats
	// that refuse Session_Unlocked (Starting, or already in a named Session).
	unlock_window := principals.Seat{state = .Unlock_Window}
	testing.expect_value(t, unlock_precheck(0, .Locked, false, unlock_window).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	testing.expect_value(t, unlock_precheck(principals.PRINCIPAL_CAPACITY, .Locked, false, unlock_window).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	testing.expect_value(t, unlock_precheck(max(u64), .Locked, false, unlock_window).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	testing.expect_value(t, unlock_precheck(1, .Absent, false, unlock_window).outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	testing.expect_value(t, unlock_precheck(1, .Creating, false, unlock_window).outcome, call_outcome.Call_Outcome.Wrong_State)
	testing.expect_value(t, unlock_precheck(1, .In_Front, false, unlock_window).outcome, call_outcome.Call_Outcome.Wrong_State)
	testing.expect_value(t, unlock_precheck(1, .Locked, true, unlock_window).outcome, call_outcome.Call_Outcome.Wrong_State)

	refusing_seats := [?]principals.Seat{
		{state = .Starting},
		{state = .Session, in_front = 1},
	}
	for bad_seat in refusing_seats {
		c := unlock_precheck(1, .Locked, false, bad_seat)
		testing.expect(t, !c.ok)
		testing.expect_value(t, c.outcome, call_outcome.Call_Outcome.Wrong_State)
	}

	// Chooser, Unlock_Window, and Machine-in-front allow Session_Unlocked for principal 1.
	for good_seat in ([3]principals.Seat{{state = .Chooser}, {state = .Unlock_Window}, {state = .Session, in_front = principals.MACHINE}}) {
		c := unlock_precheck(1, .Locked, false, good_seat)
		testing.expect(t, c.ok)
		testing.expect_value(t, c.outcome, call_outcome.Call_Outcome.Succeeded)
	}
}
