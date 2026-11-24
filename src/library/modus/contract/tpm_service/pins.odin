// The pins of the TPM service: what the service and unlock agree on for
// Pin_Read and Pin_Write, and the decisions of unlock on a record or a
// file of the disk against its pin
// (src/md/features/tpm_sealed_machine_key.md, "The pin of the record";
// src/md/features/tpm_sealed_principal_keys.md, "The pin of the file").
//
// Each decision is here, apart from the process, so that the host tests
// check the exact rule that unlock and the service run.
package tpm_service

import "modus:contract/enum_word"
import "modus:contract/tpm_attestation"

// What a pin pins. Its word crosses the ring, so each value is explicit.
Pin_Kind :: enum u64 {
	Machine_Key    = 1, // The record "machine" of the store of unlock.
	Principal_File = 2, // The file "principal" of the store of unlock.
}

// The state of the index of a pin, as the service read it. Its word
// crosses the ring, so each value is explicit.
Pin_State :: enum u64 {
	// No index: a machine before its first pin, or after a clear of the TPM.
	Absent            = 0,
	// A pin whose policy is PCR 7 and PCR 11 now: this system wrote it.
	Held              = 1,
	// A pin whose policy names other PCR values: this system before an
	// update of the system, or before a change of PCR 7. Its payload is
	// read; the next write defines the index again with the policy of now.
	Held_Other_Policy = 2,
	// An index of another shape at the handle: another software. It pins
	// nothing; the next write removes it.
	Foreign           = 3,
	// An index of the shape of a pin that was never written: a definition
	// whose write did not happen, or an index that another system planted.
	Never_Written     = 4,
}

// The bytes of the payload of a pin of each kind.
pin_payload_size :: proc "contextless" (kind: Pin_Kind) -> int {
	switch kind {
	case .Machine_Key:
		return tpm_attestation.MACHINE_KEY_PIN_RECORD_SIZE
	case .Principal_File:
		return tpm_attestation.PRINCIPAL_FILE_PIN_RECORD_SIZE
	}
	return 0
}

// The highest principal number that has a pin: one index for each, after
// the index of the machine key (modus:tpm2, pin_index_of).
PIN_PRINCIPAL_LIMIT :: 64

// The payload of each kind fits the place of the pin in the region, and
// that place is in the page of the region, after the authorization value.
#assert(tpm_attestation.MACHINE_KEY_PIN_RECORD_SIZE <= PIN_LIMIT)
#assert(tpm_attestation.PRINCIPAL_FILE_PIN_RECORD_SIZE <= PIN_LIMIT)
#assert(REGION_PIN >= REGION_AUTHORIZATION + AUTHORIZATION_SIZE)
#assert(REGION_PIN + PIN_LIMIT <= REGION_SIZE)
#assert(REGION_SIZE == 4096)

// A request of Pin_Read or Pin_Write, past the border.
Pin_Request :: struct {
	kind:      Pin_Kind,
	principal: u32, // 0 for the machine key.
	bytes:     int, // Pin_Write: the bytes of the payload in the region.
}

pin_kind_of_word :: proc "contextless" (word: u64) -> (kind: Pin_Kind, ok: bool) {
	return enum_word.member_of_word(Pin_Kind, word)
}

pin_state_of_word :: proc "contextless" (word: u64) -> (state: Pin_State, ok: bool) {
	return enum_word.member_of_word(Pin_State, word)
}

// pin_request_of_values is the border of Pin_Read and Pin_Write: a kind
// that names none, a principal of the other kind or past the limit, or a
// payload that is not the size of its kind is refused.
pin_request_of_values :: proc "contextless" (command: Command, values: [7]u64) -> (request: Pin_Request, ok: bool) {
	kind, kind_ok := pin_kind_of_word(values[0])
	if !kind_ok {
		return {}, false
	}
	switch kind {
	case .Machine_Key:
		if values[1] != 0 {
			return {}, false
		}
	case .Principal_File:
		if values[1] == 0 || values[1] > PIN_PRINCIPAL_LIMIT {
			return {}, false
		}
	}
	request = {kind = kind, principal = u32(values[1])}
	switch command {
	case .Pin_Read:
		return request, true
	case .Pin_Write:
		if values[2] != u64(pin_payload_size(kind)) {
			return {}, false
		}
		request.bytes = int(values[2])
		return request, true
	case .None, .Seal, .Unseal, .Measure_Start_Policy:
	}
	return {}, false
}

// pin_state_holds_payload says if the index of a state holds a payload
// that the service reads.
pin_state_holds_payload :: proc "contextless" (state: Pin_State) -> bool {
	switch state {
	case .Held, .Held_Other_Policy:
		return true
	case .Absent, .Foreign, .Never_Written:
		return false
	}
	return false
}

// pin_write_refusal decides a Pin_Write in the service: the new payload
// must decode, name the principal of the request, and be a change that the
// pin of the index allows. A stored payload that does not decode is never
// written over: unlock refuses each record against it, and a write over
// it would let any record become current.
pin_write_refusal :: proc "contextless" (request: Pin_Request, state: Pin_State, stored: []u8, proposed: []u8) -> tpm_attestation.Pin_Refusal {
	holds := pin_state_holds_payload(state)
	switch request.kind {
	case .Machine_Key:
		next, refusal := tpm_attestation.machine_key_pin_decode(proposed)
		if refusal != .None {
			return refusal
		}
		current: tpm_attestation.Machine_Key_Pin
		if holds {
			current, refusal = tpm_attestation.machine_key_pin_decode(stored)
			if refusal != .None {
				return refusal
			}
		}
		return tpm_attestation.machine_key_pin_advance(current, next)
	case .Principal_File:
		next, refusal := tpm_attestation.principal_file_pin_decode(proposed)
		if refusal != .None {
			return refusal
		}
		if next.principal != request.principal {
			return .Principal_Mismatch
		}
		current: tpm_attestation.Principal_File_Pin
		if holds {
			current, refusal = tpm_attestation.principal_file_pin_decode(stored)
			if refusal != .None {
				return refusal
			}
		}
		return tpm_attestation.principal_file_pin_advance(current, next)
	}
	return .Unknown_Form
}

// What unlock does with a record or a file of the disk, after its pin.
Pin_Verdict :: enum u8 {
	Accepted, // The pin names it.
	Accepted_Next, // The pin announced it: the write of the disk ended, the write of the pin did not. Unlock settles the pin.
	Not_Pinned, // No pin of this system: the record is taken, and unlock pins it when it may seal.
	Record_Pin_Mismatch, // The record of the machine key is not the pinned one, or the pinned one is absent: it is refused.
	Principal_File_Pin_Mismatch, // The file of the principal is not the pinned one: it is refused.
}

// machine_record_pin_verdict decides a record of the machine key from the
// disk (present false: the store holds none) against the index of its pin.
// pin is the decoded pin when the index holds one. An index that holds a
// payload that does not decode refuses each record: a damaged pin never
// lets an older or another record open.
machine_record_pin_verdict :: proc "contextless" (state: Pin_State, payload: []u8, record: []u8, present: bool) -> (verdict: Pin_Verdict, pin: tpm_attestation.Machine_Key_Pin, refusal: tpm_attestation.Pin_Refusal) {
	if !pin_state_holds_payload(state) {
		return .Not_Pinned, {}, .Not_Pinned
	}
	pin, refusal = tpm_attestation.machine_key_pin_decode(payload)
	if refusal != .None {
		return .Record_Pin_Mismatch, {}, refusal
	}
	if !present {
		return .Record_Pin_Mismatch, pin, .Record_Absent
	}
	match: tpm_attestation.Pin_Match
	match, refusal = tpm_attestation.machine_key_record_matches_pin(pin, record)
	if refusal != .None {
		return .Record_Pin_Mismatch, pin, refusal
	}
	switch match {
	case .Current:
		return .Accepted, pin, .None
	case .Next:
		return .Accepted_Next, pin, .None
	}
	return .Record_Pin_Mismatch, pin, .Digest_Mismatch
}

// principal_file_pin_verdict decides a file of a named principal from the
// disk (present false: the store holds none) against the index of the pin
// of its principal.
principal_file_pin_verdict :: proc "contextless" (state: Pin_State, payload: []u8, principal: u64, identifier: tpm_attestation.Identifier, file: []u8, present: bool) -> (verdict: Pin_Verdict, pin: tpm_attestation.Principal_File_Pin, refusal: tpm_attestation.Pin_Refusal) {
	if !pin_state_holds_payload(state) {
		return .Not_Pinned, {}, .Not_Pinned
	}
	pin, refusal = tpm_attestation.principal_file_pin_decode(payload)
	if refusal != .None {
		return .Principal_File_Pin_Mismatch, {}, refusal
	}
	if principal == 0 || principal > PIN_PRINCIPAL_LIMIT {
		return .Principal_File_Pin_Mismatch, pin, .Principal_Mismatch
	}
	if !present {
		return .Principal_File_Pin_Mismatch, pin, .Record_Absent
	}
	match: tpm_attestation.Pin_Match
	match, refusal = tpm_attestation.principal_file_pin_check(pin, u32(principal), identifier, file)
	if refusal != .None {
		return .Principal_File_Pin_Mismatch, pin, refusal
	}
	switch match {
	case .Current:
		return .Accepted, pin, .None
	case .Next:
		return .Accepted_Next, pin, .None
	}
	return .Principal_File_Pin_Mismatch, pin, .Digest_Mismatch
}
