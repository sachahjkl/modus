// The pins of the record of the machine key and of the file of the named
// principal in the TPM (src/md/features/tpm_sealed_machine_key.md, "The
// pin of the record"; src/md/features/tpm_sealed_principal_keys.md, "The
// pin of the file").
//
// On a machine with the TPM service, each record and each file that the
// store gives is checked against its pin before any key opens: a record
// that the pin does not name (another form, an older record, a record that
// was removed) is refused, and never replaced by an older or another one.
// Each write of a new record or file announces it in the pin first, then
// writes the store, then settles the pin on what the store kept: a stop
// between two steps leaves a record that the pin names.
//
// With no TPM service nothing is pinned or checked: a machine with no TPM
// works as before. A pin is written only when a seal is allowed (Secure
// Boot on): its policy names PCR 7, and a pin written with Secure Boot off
// would bind the record to a boot program that nothing verified.
package unlock

import "modus:contract/tpm_attestation"
import "modus:contract/tpm_service"
import "modus:principals"
import "modus:system"

// The pin of the record of the machine key, as this run read and wrote it.
// machine_pin_read: this run read the index, with a pin or none.
machine_pin: tpm_attestation.Machine_Key_Pin
machine_pin_read: bool
// The pin of the file of the named principal, as this run read and wrote
// it.
principal_pin: tpm_attestation.Principal_File_Pin
principal_pin_read: bool

// The payload that Pin_Read gave.
pin_payload: [tpm_service.PIN_LIMIT]u8

// pins_writable says if this run may write a pin: the TPM service runs and
// a seal is allowed.
pins_writable :: proc "contextless" () -> bool {
	return has_tpm && seal_allowed
}

// pin_read asks the TPM service for the index of a pin. The payload, when
// the index holds one, is in pin_payload[:count].
pin_read :: proc "contextless" (kind: tpm_service.Pin_Kind, principal: u64) -> (state: tpm_service.Pin_State, count: int, ok: bool) {
	completion, status, answered := tpm_request(.Pin_Read, {0 = u64(kind), 1 = principal})
	if !answered || status != .Ok {
		tpm_refusal_log("pin", completion, status, answered)
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
	copy(tpm_region[tpm_service.REGION_PIN:][:len(payload)], payload)
	completion, status, answered := tpm_request(.Pin_Write, {0 = u64(kind), 1 = principal, 2 = u64(len(payload))})
	// A refusal of the payload or of its change is Bad_Command with the word
	// of its refusal; a refusal at the border has the word 0.
	if answered && status == .Bad_Command && completion.values[0] != 0 {
		refusal, refusal_ok := tpm_attestation_pin_refusal_of_word(completion.values[0])
		if refusal_ok {
			system.log_fact(.Info, Pin_Refused_By_Tpm_Service{pin_refusal = pin_refusal_field(refusal)})
		} else {
			system.log_fact(.Info, Pin_Refusal_Unknown{refusal_word = completion.values[0]})
		}
		return false
	}
	if !answered || status != .Ok {
		tpm_refusal_log("pin", completion, status, answered)
		return false
	}
	return true
}

// tpm_attestation_pin_refusal_of_word is the border of the word of a
// refusal that the TPM service gave.
tpm_attestation_pin_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: tpm_attestation.Pin_Refusal, ok: bool) {
	for member in tpm_attestation.Pin_Refusal {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// machine_record_pin_check checks the record of the machine key that the
// store gave (present false: none) against its pin. refused: the record is
// not the pinned one, and nothing may open it or replace it. A first
// record with no pin is pinned here, and an announced record that the
// store kept is settled.
machine_record_pin_check :: proc "contextless" (record: []u8, present: bool) -> (refused: bool) {
	if !has_tpm {
		return false
	}
	state, count, read_ok := pin_read(.Machine_Key, 0)
	if !read_ok {
		// A TPM that gives no answer opens no sealed record either: the
		// record is taken as on a machine with no TPM.
		system.log_fact(.Info, Machine_Pin_Not_Read{})
		return false
	}
	verdict, pin, refusal := tpm_service.machine_record_pin_verdict(state, pin_payload[:count], record, present)
	switch verdict {
	case .Record_Pin_Mismatch, .Principal_File_Pin_Mismatch:
		system.log_fact(.Info, Record_Pin_Mismatch{pin_refusal = pin_refusal_field(refusal)})
		return true
	case .Accepted:
		machine_pin, machine_pin_read = pin, true
		// A write that the store did not keep left its announce: it goes.
		if pin.next_digest != {} {
			pin_settle(.Machine_Key, record)
		}
	case .Accepted_Next:
		machine_pin, machine_pin_read = pin, true
		pin_settle(.Machine_Key, record)
	case .Not_Pinned:
		machine_pin, machine_pin_read = {}, true
		if present {
			pin_settle(.Machine_Key, record)
		}
	}
	return false
}

// principal_file_pin_check checks the file of the named principal number
// that the store gave against its pin, as machine_record_pin_check does.
principal_file_pin_check :: proc "contextless" (principal: u64, file: []u8) -> (refused: bool) {
	if !has_tpm {
		return false
	}
	state, count, read_ok := pin_read(.Principal_File, principal)
	if !read_ok {
		system.log_fact(.Info, Principal_Pin_Not_Read{principal = principal})
		return false
	}
	verdict, pin, refusal := tpm_service.principal_file_pin_verdict(state, pin_payload[:count], principal, file, true)
	switch verdict {
	case .Record_Pin_Mismatch, .Principal_File_Pin_Mismatch:
		system.log_fact(.Info, Principal_File_Pin_Mismatch{principal = principal, pin_refusal = pin_refusal_field(refusal)})
		return true
	case .Accepted:
		principal_pin, principal_pin_read = pin, true
		if pin.next_digest != {} {
			pin_settle(.Principal_File, file)
		}
	case .Accepted_Next:
		principal_pin, principal_pin_read = pin, true
		pin_settle(.Principal_File, file)
	case .Not_Pinned:
		principal_pin, principal_pin_read = {}, true
		pin_settle(.Principal_File, file)
	}
	return false
}

// principal_file_removed_check says on the log when the store holds no
// file of a named principal and a pin names one: a writer of the disk
// removed it. Nothing opens either way; the line names the cause.
principal_file_removed_check :: proc "contextless" () {
	if !has_tpm {
		return
	}
	for principal in u64(1) ..< principals.PRINCIPAL_CAPACITY {
		state, count, read_ok := pin_read(.Principal_File, principal)
		if !read_ok {
			continue
		}
		verdict, _, refusal := tpm_service.principal_file_pin_verdict(state, pin_payload[:count], principal, nil, false)
		if verdict == .Principal_File_Pin_Mismatch {
			system.log_fact(.Info, Principal_File_Pin_Mismatch{principal = principal, pin_refusal = pin_refusal_field(refusal)})
		}
	}
}

// pin_announce writes the pin that announces a new record or file, before
// its write. false: the pin refuses it, or the TPM service did not write
// the announce; the caller writes nothing, as the next start would refuse
// the new bytes. A record or a file with no pin needs no announce.
pin_announce :: proc "contextless" (kind: tpm_service.Pin_Kind, new_bytes: []u8) -> bool {
	if !has_tpm {
		return true
	}
	payload: [tpm_service.PIN_LIMIT]u8
	count: int
	refusal: tpm_attestation.Pin_Refusal
	principal: u64
	switch kind {
	case .Machine_Key:
		if !machine_pin_read || machine_pin.form == .None {
			return true
		}
		if !seal_allowed {
			system.log_fact(.Info, Pinned_Write_Without_Secure_Boot{})
			return false
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
		if !principal_pin_read || principal_pin.generation == 0 {
			return true
		}
		if !seal_allowed {
			system.log_fact(.Info, Pinned_Write_Without_Secure_Boot{})
			return false
		}
		principal = u64(principal_pin.principal)
		proposed: tpm_attestation.Principal_File_Pin
		proposed, refusal = tpm_attestation.principal_file_pin_announce(principal_pin, new_bytes)
		if refusal == .None {
			count, refusal = tpm_attestation.principal_file_pin_encode(proposed, payload[:])
		}
		if refusal != .None {
			system.log_fact(.Info, Pin_Change_Refused{pin_refusal = pin_refusal_field(refusal)})
			return false
		}
		if !pin_write(kind, principal, payload[:count]) {
			system.log_fact(.Info, Pin_Announce_Not_Written{})
			return false
		}
		principal_pin = proposed
	}
	return true
}

// pin_settle writes the pin of the record or the file that the store kept
// now: the first pin of a record or a file, or the end of an announce. A
// failure leaves the announce: the next start takes the old or the new
// bytes, and settles then.
pin_settle :: proc "contextless" (kind: tpm_service.Pin_Kind, kept: []u8) {
	if !pins_writable() {
		return
	}
	payload: [tpm_service.PIN_LIMIT]u8
	count: int
	refusal: tpm_attestation.Pin_Refusal
	switch kind {
	case .Machine_Key:
		if !machine_pin_read {
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
		system.log_fact(.Info, Machine_Record_Pinned{epoch = proposed.epoch})
	case .Principal_File:
		if !principal_pin_read || number == 0 {
			return
		}
		proposed: tpm_attestation.Principal_File_Pin
		proposed, refusal = tpm_attestation.principal_file_pin_settle(principal_pin, u32(number), kept)
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
	principal_pin = {}
	if tpm_service.pin_state_holds_payload(state) {
		refusal: tpm_attestation.Pin_Refusal
		principal_pin, refusal = tpm_attestation.principal_file_pin_decode(pin_payload[:count])
		if refusal != .None {
			system.log_fact(.Info, Principal_File_Pin_Mismatch{principal = number, pin_refusal = pin_refusal_field(refusal)})
			return
		}
	}
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
