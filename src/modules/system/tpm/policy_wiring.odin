// The steps of the signed policy and of the pins, on the TPM that this
// service owns (src/md/features/rollback_floors.md, "Built and left";
// src/md/features/tpm_sealed_machine_key.md, "The form of the record is not pinned").
//
// No ring command reaches these steps yet: the NV indices of the pins, the
// signed policy of the seal and the owner authorization value need their
// boot and unlock machine tests first. The steps are here so that the rules
// of modus:contract/tpm_attestation are the ones that the service runs, and
// a later command only adds its word to the ring.
package tpm_device_service

import "modus:contract/tpm_attestation"
import "modus:contract/tpm_service"

// outcome_of_wire gives the outcome of an answer of a command that
// tpm_attestation built and read: a code of the TPM is Refused, any other
// fault of the answer a Device_Error at the step Answer.
outcome_of_wire :: proc "contextless" (refusal: tpm_attestation.Wire_Refusal, code: u32, command: u32) -> Outcome {
	if refusal == .Response_Error {
		return {status = .Refused, values = {0 = u64(code), 1 = u64(command)}}
	}
	return {status = .Device_Error, values = {0 = u64(tpm_service.Device_Step.Answer)}}
}

// signed_policy_authorize checks the signed statement of the publisher
// against the floors, then sends TPM2_PolicyAuthorize in the policy
// session. The floors change only when the TPM took the command: a refused
// command leaves them as they were, so a later try with the same statement
// is checked against the same floors.
signed_policy_authorize :: proc "contextless" (
	floors: ^tpm_attestation.Rollback_Floor_State,
	statement: tpm_attestation.Approved_Policy_Statement,
	signature: []u8,
	verify_signature: tpm_attestation.Policy_Signature_Verify_Proc,
	user_data: rawptr,
	session: u32,
	key_sign_name: []u8,
	ticket: tpm_attestation.Verified_Ticket,
) -> (failed: Outcome, ok: bool) {
	candidate := floors^
	_, floor_refusal := tpm_attestation.rollback_floor_verify_policy_authorize(&candidate, statement, signature, verify_signature, user_data)
	if floor_refusal != .None {
		return {status = .Bad_Command, values = {0 = u64(floor_refusal)}}, false
	}
	policy_reference := statement.policy_ref
	count, encode_refusal := tpm_attestation.encode_policy_authorize(session, statement.approved_policy, policy_reference[:], key_sign_name, ticket, command_bytes[:])
	if encode_refusal != .None {
		return {status = .Bad_Command, values = {0 = u64(encode_refusal)}}, false
	}
	answer, step := transact(count)
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	code, answer_refusal := tpm_attestation.decode_policy_authorize_response(answer)
	if answer_refusal != .None {
		return outcome_of_wire(answer_refusal, code, tpm_attestation.COMMAND_POLICY_AUTHORIZE), false
	}
	floors^ = candidate
	return {}, true
}

// hierarchy_authorization_change sends TPM2_HierarchyChangeAuth with the
// current value of the hierarchy. The command buffer held both values: it
// is erased after the command.
hierarchy_authorization_change :: proc "contextless" (hierarchy: tpm_attestation.Hierarchy, current_value: []u8, new_value: []u8) -> (failed: Outcome, ok: bool) {
	defer erase(command_bytes[:])
	count, encode_refusal := tpm_attestation.encode_hierarchy_change_auth(hierarchy, current_value, new_value, command_bytes[:])
	if encode_refusal != .None {
		return {status = .Bad_Command, values = {0 = u64(encode_refusal)}}, false
	}
	answer, step := transact(count)
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	code, answer_refusal := tpm_attestation.decode_hierarchy_change_auth_response(answer)
	if answer_refusal != .None {
		return outcome_of_wire(answer_refusal, code, tpm_attestation.COMMAND_HIERARCHY_CHANGE_AUTH), false
	}
	return {}, true
}

// machine_key_pin_of_index reads the payload of the index of the machine
// key pin. No bytes is the state of a machine with no pin: the index is
// absent.
machine_key_pin_of_index :: proc "contextless" (stored: []u8) -> (pin: tpm_attestation.Machine_Key_Pin, refusal: tpm_attestation.Pin_Refusal) {
	if len(stored) == 0 {
		return {}, .None
	}
	return tpm_attestation.machine_key_pin_decode(stored)
}

// machine_key_pin_transition decides the next payload of the index of the
// machine key pin: the stored payload, then the proposed pin, which must be
// a change that the pin allows. out then holds the bytes to write.
machine_key_pin_transition :: proc "contextless" (stored: []u8, proposed: tpm_attestation.Machine_Key_Pin, out: []u8) -> (count: int, refusal: tpm_attestation.Pin_Refusal) {
	current: tpm_attestation.Machine_Key_Pin
	current, refusal = machine_key_pin_of_index(stored)
	if refusal != .None {
		return 0, refusal
	}
	refusal = tpm_attestation.machine_key_pin_advance(current, proposed)
	if refusal != .None {
		return 0, refusal
	}
	return tpm_attestation.machine_key_pin_encode(proposed, out)
}

// machine_key_record_check checks a record of the machine key from the
// disk against the payload of the index.
machine_key_record_check :: proc "contextless" (stored: []u8, record: []u8) -> tpm_attestation.Pin_Refusal {
	pin, refusal := machine_key_pin_of_index(stored)
	if refusal != .None {
		return refusal
	}
	return tpm_attestation.machine_key_record_matches_pin(pin, record)
}

// principal_file_pin_of_index reads the payload of the index of a principal
// file pin. No bytes is the state of a principal with no pin.
principal_file_pin_of_index :: proc "contextless" (stored: []u8) -> (pin: tpm_attestation.Principal_File_Pin, refusal: tpm_attestation.Pin_Refusal) {
	if len(stored) == 0 {
		return {}, .None
	}
	return tpm_attestation.principal_file_pin_decode(stored)
}

// principal_file_pin_transition decides the next payload of the index of a
// principal file pin, for the file that the store now keeps. out then
// holds the bytes to write.
principal_file_pin_transition :: proc "contextless" (stored: []u8, principal: u32, generation: u64, file: []u8, out: []u8) -> (count: int, refusal: tpm_attestation.Pin_Refusal) {
	current: tpm_attestation.Principal_File_Pin
	current, refusal = principal_file_pin_of_index(stored)
	if refusal != .None {
		return 0, refusal
	}
	proposed := tpm_attestation.Principal_File_Pin {
		principal   = principal,
		generation  = generation,
		file_digest = tpm_attestation.principal_file_digest(file),
	}
	refusal = tpm_attestation.principal_file_pin_advance(current, proposed)
	if refusal != .None {
		return 0, refusal
	}
	return tpm_attestation.principal_file_pin_encode(proposed, out)
}

// principal_file_check checks a principal file from the disk against the
// payload of the index.
principal_file_check :: proc "contextless" (stored: []u8, principal: u32, file: []u8) -> tpm_attestation.Pin_Refusal {
	pin, refusal := principal_file_pin_of_index(stored)
	if refusal != .None {
		return refusal
	}
	return tpm_attestation.principal_file_pin_check(pin, principal, file)
}
