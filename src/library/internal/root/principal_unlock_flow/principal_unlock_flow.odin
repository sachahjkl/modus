package principal_unlock_flow

import "modus:contract/call_outcome"
import "modus:contract/root_ring"
import "modus:principals"

// The root service's tracking of storage keys that were sent to the storage
// service for a named principal before its session started, and of erases
// that must still reach the storage service after a lock or a failed unlock.
Flow :: struct {
	key_awaiting: [principals.PRINCIPAL_CAPACITY]bool,
	erase_owed:   [principals.PRINCIPAL_CAPACITY]bool,
}

// What the root service does with a Principal_Storage_Key command after
// checking its border, slot state, erase state, and ring room.
Storage_Key_Decision :: struct {
	send:    bool,
	outcome: call_outcome.Call_Outcome,
	refusal: [7]u64,
}

// storage_key_check validates Principal_Storage_Key before sending the two
// records (Principal_Identity and Principal_Storage_Key) to the storage
// service. It enforces the border, slot presence, Locked state, single-send
// awaiting rule, owed-erase barrier, non-zero key, holder presence, and
// atomic room for both records in the storage ring.
storage_key_check :: proc "contextless" (
	flow: ^Flow,
	values: [7]u64,
	record_state: principals.Session_State,
	identifier_zero: bool,
	storage_present: bool,
	ring_free: u32,
) -> (
	decision: Storage_Key_Decision,
) {
	kind := u32(root_ring.Root_Command.Principal_Storage_Key)
	number := values[4]
	for index in 5 ..< len(values) {
		if values[index] != 0 {
			decision.outcome = .Argument_Refused
			decision.refusal = root_ring.word_refusal(.Principal_Storage_Key, i64(index) + 1, values[index], 0)
			return decision
		}
	}
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY || record_state == .Absent || record_state == .Creating || identifier_zero {
		decision.outcome = root_ring.refuse(&decision.refusal, .Nothing_Has_That_Name, kind, .Absent, .Principals, 5, i64(min(number, 1 << 62)))
		return decision
	}
	if record_state != .Locked || flow.key_awaiting[number] {
		decision.outcome = root_ring.refuse(&decision.refusal, .Wrong_State, kind, .State, .Principals, 5, i64(number))
		return decision
	}
	if flow.erase_owed[number] {
		decision.outcome = root_ring.refuse(&decision.refusal, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1)
		return decision
	}
	if values[0] == 0 && values[1] == 0 && values[2] == 0 && values[3] == 0 {
		decision.outcome = root_ring.refuse(&decision.refusal, .Argument_Refused, kind, .Empty, .Bytes, 1)
		return decision
	}
	if !storage_present {
		decision.outcome = root_ring.refuse(&decision.refusal, .Nothing_Has_That_Name, kind, .Absent, .Services)
		return decision
	}
	// Both records or none: a ring with room for one only refuses the key.
	if ring_free < 2 {
		decision.outcome = root_ring.refuse(&decision.refusal, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1)
		return decision
	}
	decision.send = true
	decision.outcome = .Succeeded
	return decision
}

// storage_key_sent records the result of sending Principal_Identity and
// Principal_Storage_Key. When both succeeded, the slot awaits unlock. When
// the first succeeded and the second failed, the slot owes an erase so no
// half-written identity lingers in storage.
storage_key_sent :: proc "contextless" (flow: ^Flow, number: u64, identity_sent: bool, key_sent: bool) -> (succeeded: bool, owe_erase: bool) {
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY {
		return false, false
	}
	if identity_sent && key_sent {
		flow.key_awaiting[number] = true
		return true, false
	}
	if identity_sent {
		flow.key_awaiting[number] = false
		flow.erase_owed[number] = true
		return false, true
	}
	return false, false
}

// What principal_unlock checks before taking the disk-grant-table key.
Unlock_Precheck :: struct {
	ok:      bool,
	outcome: call_outcome.Call_Outcome,
	refusal: [7]u64,
}

// unlock_precheck verifies the slot, Locked state, non-zero identifier, and
// seat transition before principal_unlock takes the key. A seat that refuses
// the session never takes the key.
unlock_precheck :: proc "contextless" (
	number: u64,
	record_state: principals.Session_State,
	identifier_zero: bool,
	seat: principals.Seat,
) -> (
	check: Unlock_Precheck,
) {
	kind := u32(root_ring.Root_Command.Principal_Unlock)
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY || record_state == .Absent {
		check.outcome = root_ring.refuse(&check.refusal, .Nothing_Has_That_Name, kind, .Absent, .Principals, 2, i64(min(number, 1 << 62)))
		return check
	}
	if record_state != .Locked {
		check.outcome = root_ring.refuse(&check.refusal, .Wrong_State, kind, .State, .Principals, 2, i64(number))
		return check
	}
	if identifier_zero {
		check.outcome = root_ring.refuse(&check.refusal, .Wrong_State, kind, .State, .Principals, 2, i64(number))
		return check
	}
	if _, seat_ok := principals.seat_next(seat, .Session_Unlocked, number); !seat_ok {
		check.outcome = root_ring.refuse(&check.refusal, .Wrong_State, kind, .State, .Principals, 2, i64(number))
		return check
	}
	check.ok = true
	check.outcome = .Succeeded
	return check
}

// unlock_finished settles the awaiting storage key after principal_unlock
// completes. On failure, an awaiting slot owes an erase so no storage key
// stays held without a running session.
unlock_finished :: proc "contextless" (flow: ^Flow, number: u64, succeeded: bool) -> (owe_erase: bool) {
	if number >= principals.PRINCIPAL_CAPACITY || !flow.key_awaiting[number] {
		return false
	}
	flow.key_awaiting[number] = false
	if succeeded {
		return false
	}
	flow.erase_owed[number] = true
	return true
}

// erase_owe marks a slot as owing a Principal_Locked erase and clears any
// awaiting marker for it.
erase_owe :: proc "contextless" (flow: ^Flow, number: u64) {
	if number >= principals.PRINCIPAL_CAPACITY {
		return
	}
	flow.key_awaiting[number] = false
	flow.erase_owed[number] = true
}

// erase_attempt records one attempt to deliver an owed Principal_Locked
// erase to the storage service. When storage is absent (stopped), its
// memory and keys are gone, so the debt clears; when the ring had room and
// accepted the record, the debt clears; when the ring was full, the debt
// stays owed for the next pass.
erase_attempt :: proc "contextless" (flow: ^Flow, number: u64, storage_present: bool, sent: bool) -> (cleared: bool) {
	if number >= principals.PRINCIPAL_CAPACITY {
		return true
	}
	if !storage_present || sent {
		flow.erase_owed[number] = false
		return true
	}
	return false
}

// unlock_stopped_collect marks every slot with an awaiting storage key as
// owing an erase when `unlock` stops before starting the session.
unlock_stopped_collect :: proc "contextless" (flow: ^Flow) -> (owed: [principals.PRINCIPAL_CAPACITY]bool) {
	for awaiting, number in flow.key_awaiting {
		if awaiting {
			flow.key_awaiting[number] = false
			flow.erase_owed[number] = true
			owed[number] = true
		}
	}
	return owed
}
