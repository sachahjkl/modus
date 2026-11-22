// The steps of the signed policy and of the owner authorization value, on
// the TPM that this service owns (src/md/features/rollback_floors.md,
// "Built and left").
//
// No ring command reaches these steps: a signed policy needs a key of the
// publisher that the TPM verifies (RSA or ECDSA; the publisher signs with
// Ed25519), and an owner authorization value needs a place to keep it that
// the seal of the machine key does not need first, and a boot program that
// can still define its floors. The steps are here so that the rules of
// modus:contract/tpm_attestation are the ones that the service runs.
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
