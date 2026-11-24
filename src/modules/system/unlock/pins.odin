// The TPM pins of the record of the machine key and of the file of the
// named principal (src/md/features/tpm_sealed_machine_key.md, "The pin of
// the record"; src/md/features/tpm_sealed_principal_keys.md, "The pin of
// the file").
//
// On a machine where the root service gave the TPM, each record and each
// file that the store gives is checked against its pin before any key
// opens: a record that the pin does not name (another form, an older
// record, a record that was removed) is refused, and never replaced by an
// older or another one. A pin that cannot be read refuses too: a stop of
// the TPM service must not let a swapped record pass. Each write of a new
// record or file announces it in the pin first, then writes the store,
// then settles the pin on what the store kept: a stop between two steps
// leaves a record that the pin names.
//
// With no TPM given, nothing is pinned or checked: a machine with no TPM
// works as before. A pin is written only when a seal is allowed (Secure
// Boot on): its policy names PCR 7, and a pin written with Secure Boot off
// would bind the record to a boot program that nothing verified.
package unlock

import "modus:contract/tpm_attestation"
import "modus:contract/tpm_service"
import "modus:principals"
import "modus:system"

// The root service gave the ring and the region of the TPM service. It
// stays true when the service stops or fails, unlike has_tpm.
tpm_granted: bool

// The pin of the record of the machine key, as this run read and wrote it.
// machine_pin_read: this run read the index, with a pin or none.
machine_pin: tpm_attestation.Machine_Key_Pin
machine_pin_read: bool
// The record that the store holds now, as the pin was checked or settled
// on it: an announce settles a pin that names two records on it first.
machine_record_kept: [principals.MACHINE_RECORD_LIMIT]u8
machine_record_kept_count: int
// The pin of the file of the named principal, as this run read and wrote
// it, and the file that the store holds now.
principal_pin: tpm_attestation.Principal_File_Pin
principal_pin_read: bool
principal_file_kept: [principals.PRINCIPAL_FILE_LIMIT]u8
principal_file_kept_count: int

// The payload that Pin_Read gave.
pin_payload: [tpm_service.PIN_LIMIT]u8

// pins_writable says if this run may write a pin: the TPM service runs and
// a seal is allowed.
pins_writable :: proc "contextless" () -> bool {
	return has_tpm && seal_allowed
}

// pin_read asks the TPM service for the index of a pin. The payload, when
// the index holds one, is in pin_payload[:count]. With the TPM given and a
// service that stopped, it fails.
pin_read :: proc "contextless" (kind: tpm_service.Pin_Kind, principal: u64) -> (state: tpm_service.Pin_State, count: int, ok: bool) {
	if !has_tpm {
		return {}, 0, false
	}
	completion, outcome, record, answered := tpm_request(.Pin_Read, {0 = u64(kind), 1 = principal})
	if !answered || outcome != .Succeeded {
		tpm_refusal_log("pin", outcome, record, answered)
		return {}, 0, false
	}
	state_ok: bool
	state, state_ok = tpm_service.pin_state_of_word(completion.values[1])
	if !state_ok {
		system.log_fact(.Info, Pin_State_Unknown{state_word = completion.values[1]})
		return {}, 0, false
	}
	// The count comes from the service: the payload of its kind, only for a
	// state that holds one.
	holds := tpm_service.pin_state_holds_payload(state)
	expected := holds ? u64(tpm_service.pin_payload_size(kind)) : 0
	if completion.values[0] != expected {
		system.log_fact(.Info, Pin_Payload_Size_Wrong{payload_bytes = completion.values[0]})
		return {}, 0, false
	}
	count = int(expected)
	copy(pin_payload[:count], tpm_region[tpm_service.REGION_PIN:][:count])
	return state, count, true
}

// pin_write asks the TPM service to write a new payload of a pin.
pin_write :: proc "contextless" (kind: tpm_service.Pin_Kind, principal: u64, payload: []u8) -> bool {
	if !has_tpm {
		return false
	}
	copy(tpm_region[tpm_service.REGION_PIN:][:len(payload)], payload)
	_, outcome, record, answered := tpm_request(.Pin_Write, {0 = u64(kind), 1 = principal, 2 = u64(len(payload))})
	// A refusal of the payload or of its change is Argument_Refused with the
	// word of its refusal as the value found; a refusal at the border has
	// the word 0.
	if answered && outcome == .Argument_Refused && record.found != 0 {
		refusal, refusal_ok := tpm_attestation.pin_refusal_of_word(cast(u64)record.found)
		if refusal_ok {
			system.log_fact(.Info, Pin_Refused_By_Tpm_Service{pin_refusal = pin_refusal_field(refusal)})
		} else {
			system.log_fact(.Info, Pin_Refusal_Unknown{refusal_word = cast(u64)record.found})
		}
		return false
	}
	if !answered || outcome != .Succeeded {
		tpm_refusal_log("pin", outcome, record, answered)
		return false
	}
	return true
}

// machine_record_pin_check checks the record of the machine key that the
// store gave (present false: none) against its pin. refused: the record is
// not the pinned one, or the pin could not be read; nothing may open it or
// replace it. A first record with no pin is pinned here, and a record that
// the pin announced is settled, so the record of before is refused from
// then on.
machine_record_pin_check :: proc "contextless" (record: []u8, present: bool) -> (refused: bool) {
	if !tpm_granted {
		return false
	}
	state, count, read_ok := pin_read(.Machine_Key, 0)
	if !read_ok {
		system.log_fact(.Info, Machine_Pin_Not_Read{})
		return true
	}
	verdict, pin, refusal := tpm_service.machine_record_pin_verdict(state, pin_payload[:count], record, present)
	switch verdict {
	case .Record_Pin_Mismatch, .Principal_File_Pin_Mismatch, .Free_Slot:
		system.log_fact(.Info, Record_Pin_Mismatch{pin_refusal = pin_refusal_field(refusal)})
		return true
	case .Accepted, .Accepted_Next, .Not_Pinned:
	}
	machine_pin, machine_pin_read = pin, true
	machine_record_kept_count = len(record)
	copy(machine_record_kept[:], record)
	// A record with no pin gets its first one; a pin that names two records
	// is settled on the one that the store holds.
	if present && (verdict == .Not_Pinned || pin.next_digest != {}) {
		pin_settle(.Machine_Key, record)
	}
	return false
}

// principal_file_pin_check checks the file of the named principal number
// that the store gave against its pin, as machine_record_pin_check does.
principal_file_pin_check :: proc "contextless" (principal: u64, file: []u8) -> (refused: bool) {
	if !tpm_granted {
		return false
	}
	state, count, read_ok := pin_read(.Principal_File, principal)
	if !read_ok {
		system.log_fact(.Info, Principal_Pin_Not_Read{principal = principal})
		return true
	}
	verdict, pin, refusal := tpm_service.principal_file_pin_verdict(state, pin_payload[:count], principal, identifier, file, true)
	switch verdict {
	case .Record_Pin_Mismatch, .Principal_File_Pin_Mismatch, .Free_Slot:
		system.log_fact(.Info, Principal_File_Pin_Mismatch{principal = principal, pin_refusal = pin_refusal_field(refusal)})
		return true
	case .Accepted, .Accepted_Next, .Not_Pinned:
	}
	principal_pin, principal_pin_read = pin, true
	principal_file_kept_count = len(file)
	copy(principal_file_kept[:], file)
	if verdict == .Not_Pinned || pin.next_digest != {} {
		pin_settle(.Principal_File, file)
	}
	return false
}

// principal_file_removed_check says if a pin names a file of a named
// principal when the store holds none: a writer of the disk removed it. It
// writes the cause on the log. A pin that cannot be read counts as one
// that names a file. A removed file is never taken as the absence of a
// principal: no new principal takes its place (principal_creation_allowed),
// and nothing opens.
principal_file_removed_check :: proc "contextless" () -> (removed: bool) {
	if !tpm_granted {
		return false
	}
	for principal in u64(1) ..< principals.PRINCIPAL_CAPACITY {
		state, count, read_ok := pin_read(.Principal_File, principal)
		if !read_ok {
			system.log_fact(.Info, Principal_Pin_Not_Read{principal = principal})
			removed = true
			continue
		}
		verdict, free_pin, refusal := tpm_service.principal_file_pin_verdict(state, pin_payload[:count], principal, identifier, nil, false)
		switch verdict {
		case .Principal_File_Pin_Mismatch, .Record_Pin_Mismatch:
			system.log_fact(.Info, Principal_File_Pin_Mismatch{principal = principal, pin_refusal = pin_refusal_field(refusal)})
			removed = true
		case .Free_Slot:
			// Deliberately freed slot: preserve its Free pin generation so a
			// new creation advances cleanly to generation + 1.
			principal_pin, principal_pin_read = free_pin, true
		case .Not_Pinned, .Accepted, .Accepted_Next:
		}
	}
	return removed
}

// principal_creation_allowed says if a new principal may be created: not
// while an Active pin names the file of a principal. A Free pin from a prior
// deliberate removal allows creation at generation + 1.
principal_creation_allowed :: proc "contextless" () -> bool {
	principal_pin, principal_pin_read = {}, false
	if principal_file_removed_check() {
		system.log_fact(.Info, Principal_Creation_Refused_By_Pin{})
		return false
	}
	principal_pin_read = true
	return true
}

// principal_pin_free writes the "free, generation g" TPM pin payload at the
// end of a deliberate principal removal. Returns true when no TPM pin existed
// or when the pin is already Free or newly freed. Fails closed (false) when a
// TPM pin exists and pins are not writable, or when an Active pin names a
// different principal identifier.
principal_pin_free :: proc "contextless" (slot: u64, expected_identifier: principals.Principal_Identifier, had_pin: bool) -> bool {
	if !tpm_granted || !had_pin {
		return true
	}
	if !pins_writable() {
		return false
	}
	state, count, read_ok := pin_read(.Principal_File, slot)
	if !read_ok {
		return false
	}
	if !tpm_service.pin_state_holds_payload(state) {
		return true
	}
	current, dec_ref := tpm_attestation.principal_file_pin_decode(pin_payload[:count])
	if dec_ref != .None {
		return false
	}
	if current.state == .Free {
		principal_pin, principal_pin_read = current, true
		return true
	}
	if current.identifier != expected_identifier {
		return false
	}
	freed, free_ref := tpm_attestation.principal_file_pin_free(current)
	if free_ref != .None {
		return false
	}
	payload: [tpm_service.PIN_LIMIT]u8
	out_count, enc_ref := tpm_attestation.principal_file_pin_encode(freed, payload[:])
	if enc_ref != .None {
		return false
	}
	if !pin_write(.Principal_File, slot, payload[:out_count]) {
		return false
	}
	principal_pin, principal_pin_read = freed, true
	return true
}

// pin_announce writes the pin that announces a new record or file, before
// its write. false: the pin refuses it, the pin was not read, or the TPM
// service did not write the announce; the caller writes nothing, as the
// next start would refuse the new bytes. A pin that names two records is
// settled on the record of the store first; a pin that stays unsettled
// refuses the announce, as a new announce would drop the record that the
// store may hold. A record or a file with no pin needs no announce.
pin_announce :: proc "contextless" (kind: tpm_service.Pin_Kind, new_bytes: []u8) -> bool {
	if !tpm_granted {
		return true
	}
	payload: [tpm_service.PIN_LIMIT]u8
	count: int
	refusal: tpm_attestation.Pin_Refusal
	switch kind {
	case .Machine_Key:
		if !machine_pin_read {
			system.log_fact(.Info, Machine_Pin_Not_Read{})
			return false
		}
		if machine_pin.form == .None {
			return true
		}
		if !seal_allowed {
			system.log_fact(.Info, Pinned_Write_Without_Secure_Boot{})
			return false
		}
		if machine_pin.next_digest != {} {
			pin_settle(.Machine_Key, machine_record_kept[:machine_record_kept_count])
		}
		proposed: tpm_attestation.Machine_Key_Pin
		proposed, refusal = tpm_attestation.machine_key_pin_announce(machine_pin, new_bytes)
		if refusal == .None {
			count, refusal = tpm_attestation.machine_key_pin_encode(proposed, payload[:])
		}
		if refusal != .None {
			system.log_fact(.Info, Pin_Change_Refused{pin_refusal = pin_refusal_field(refusal)})
			return false
		}
		if !pin_write(kind, 0, payload[:count]) {
			system.log_fact(.Info, Pin_Announce_Not_Written{})
			return false
		}
		machine_pin = proposed
	case .Principal_File:
		if !principal_pin_read {
			system.log_fact(.Info, Principal_Pin_Not_Read{principal = number})
			return false
		}
		if principal_pin.generation == 0 {
			return true
		}
		if !seal_allowed {
			system.log_fact(.Info, Pinned_Write_Without_Secure_Boot{})
			return false
		}
		if principal_pin.next_digest != {} {
			pin_settle(.Principal_File, principal_file_kept[:principal_file_kept_count])
		}
		proposed: tpm_attestation.Principal_File_Pin
		proposed, refusal = tpm_attestation.principal_file_pin_announce(principal_pin, new_bytes)
		if refusal == .None {
			count, refusal = tpm_attestation.principal_file_pin_encode(proposed, payload[:])
		}
		if refusal != .None {
			system.log_fact(.Info, Pin_Change_Refused{pin_refusal = pin_refusal_field(refusal)})
			return false
		}
		if !pin_write(kind, u64(principal_pin.principal), payload[:count]) {
			system.log_fact(.Info, Pin_Announce_Not_Written{})
			return false
		}
		principal_pin = proposed
	}
	return true
}

// pin_settle writes the pin of the record or the file that the store kept
// now: the first pin of a record or a file, or the end of an announce. A
// failure leaves the pin as it was: the next start, or the next announce,
// settles it then.
pin_settle :: proc "contextless" (kind: tpm_service.Pin_Kind, kept: []u8) {
	if !pins_writable() {
		return
	}
	payload: [tpm_service.PIN_LIMIT]u8
	count: int
	refusal: tpm_attestation.Pin_Refusal
	switch kind {
	case .Machine_Key:
		if !machine_pin_read || len(kept) > len(machine_record_kept) {
			return
		}
		proposed: tpm_attestation.Machine_Key_Pin
		proposed, refusal = tpm_attestation.machine_key_pin_settle(machine_pin, kept)
		if refusal == .None {
			count, refusal = tpm_attestation.machine_key_pin_encode(proposed, payload[:])
		}
		if refusal != .None {
			system.log_fact(.Info, Pin_Change_Refused{pin_refusal = pin_refusal_field(refusal)})
			return
		}
		if !pin_write(kind, 0, payload[:count]) {
			system.log_fact(.Info, Pin_Settle_Not_Written{})
			return
		}
		machine_pin = proposed
		machine_record_kept_count = len(kept)
		copy(machine_record_kept[:], kept)
		system.log_fact(.Info, Machine_Record_Pinned{epoch = proposed.epoch})
	case .Principal_File:
		if !principal_pin_read || number == 0 || len(kept) > len(principal_file_kept) {
			return
		}
		proposed: tpm_attestation.Principal_File_Pin
		proposed, refusal = tpm_attestation.principal_file_pin_settle(principal_pin, u32(number), identifier, kept)
		if refusal == .None {
			count, refusal = tpm_attestation.principal_file_pin_encode(proposed, payload[:])
		}
		if refusal != .None {
			system.log_fact(.Info, Pin_Change_Refused{pin_refusal = pin_refusal_field(refusal)})
			return
		}
		if !pin_write(kind, number, payload[:count]) {
			system.log_fact(.Info, Pin_Settle_Not_Written{})
			return
		}
		principal_pin = proposed
		principal_file_kept_count = len(kept)
		copy(principal_file_kept[:], kept)
		system.log_fact(.Info, Principal_File_Pinned{principal = number, generation = proposed.generation})
	}
}

// principal_pin_after_creation pins the file of a new principal, once the
// root service gave its number: the creation writes the file before it
// knows the number of its pin.
principal_pin_after_creation :: proc "contextless" (file: []u8) {
	if !pins_writable() || number == 0 || number > tpm_service.PIN_PRINCIPAL_LIMIT {
		return
	}
	state, count, read_ok := pin_read(.Principal_File, number)
	if !read_ok {
		system.log_fact(.Info, Principal_Pin_Not_Read{principal = number})
		return
	}
	// If the slot holds a Free pin ("free, generation g") from a prior
	// deliberate removal, advance from Free(g) to Active(new_id, g + 1).
	// An Active or unreadable pin refuses creation so a writer cannot replace
	// a removed file without freeing the pin first.
	if tpm_service.pin_state_holds_payload(state) {
		decoded, dec_ref := tpm_attestation.principal_file_pin_decode(pin_payload[:count])
		if dec_ref != .None || decoded.state != .Free || decoded.principal != u32(number) {
			system.log_fact(.Info, Principal_Creation_Refused_By_Pin{})
			return
		}
		principal_pin = decoded
		principal_pin_read = true
		pin_settle(.Principal_File, file)
		return
	}
	principal_pin = {}
	principal_pin_read = true
	pin_settle(.Principal_File, file)
}

// machine_record_write writes the record of the machine key with its pin
// around the write (object_write). A pin that refuses the record writes
// nothing: the store keeps the record of before.
machine_record_write :: proc "contextless" (bytes: []u8) -> Write_Outcome {
	if !pin_announce(.Machine_Key, bytes) {
		return .Not_Kept
	}
	outcome := object_write(principals.MACHINE_OBJECT, bytes)
	if outcome == .Kept {
		pin_settle(.Machine_Key, bytes)
	}
	return outcome
}
