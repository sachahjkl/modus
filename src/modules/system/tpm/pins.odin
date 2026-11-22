// The pins of the record of the machine key and of the file of each named
// principal, on the TPM that this service owns
// (src/md/features/tpm_sealed_machine_key.md, "The pin of the record").
//
// Pin_Read gives unlock the payload of an index and its state. Pin_Write
// checks a new payload against the payload of the index
// (tpm_service.pin_write_refusal), then writes it in a policy session of
// PCR 7 and PCR 11: the TPM itself refuses the write to another system. An
// index of the shape of a pin whose policy names other PCR values, or an
// index of another shape, is removed and defined again with the policy of
// now.
package tpm_device_service

import "modus:contract/tpm_attestation"
import "modus:contract/tpm_service"
import "modus:contract/value_kinds"
import "modus:system"
import "modus:tpm2"

// pin_policy_now computes the policy of PCR 7 and PCR 11 now, in a trial
// session: the policy of each pin that this system writes.
pin_policy_now :: proc "contextless" () -> (policy: [tpm2.DIGEST_SIZE]u8, failed: Outcome, ok: bool) {
	session, session_failed, session_ok := policy_session(.Trial, false)
	defer flush(session)
	if !session_ok {
		return {}, session_failed, false
	}
	count := tpm2.policy_get_digest_command(command_bytes[:], session)
	answer, step := transact(count)
	if step != .None {
		return {}, {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	code: u32
	problem: tpm2.Answer_Problem
	policy, code, problem = tpm2.digest_answer(answer)
	if problem != .None {
		return {}, outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_GET_DIGEST), false
	}
	return policy, {}, true
}

// pin_index_read reads the state of the index of a pin, and its payload
// into payload when the index holds one.
pin_index_read :: proc "contextless" (index: u32, size: int, policy: ^[tpm2.DIGEST_SIZE]u8, payload: []u8) -> (state: tpm_service.Pin_State, count: int, failed: Outcome, ok: bool) {
	command_count := tpm2.nv_read_public_command(command_bytes[:], index)
	answer, step := transact(command_count)
	if step != .None {
		return {}, 0, {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	public, code, problem := tpm2.nv_public_answer(answer)
	read: bool
	state, read = tpm2.pin_state_of_public(problem, code, &public, index, size, policy)
	if !read {
		return {}, 0, outcome_of_problem(problem, code, tpm2.COMMAND_NV_READ_PUBLIC), false
	}
	if !tpm_service.pin_state_holds_payload(state) {
		return state, 0, {}, true
	}
	command_count = tpm2.pin_read_command(command_bytes[:], index, size)
	answer, step = transact(command_count)
	if step != .None {
		return {}, 0, {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	count, code, problem = tpm2.pin_read_answer(answer, size, payload)
	if problem != .None {
		return {}, 0, outcome_of_problem(problem, code, tpm2.COMMAND_NV_READ), false
	}
	return state, count, {}, true
}

// pin_read answers Pin_Read: the payload of the index at REGION_PIN, and
// its state.
pin_read :: proc "contextless" (values: [7]u64) -> Outcome {
	request, request_ok := tpm_service.pin_request_of_values(.Pin_Read, values)
	index, index_ok := tpm2.pin_index_of(request.kind, u64(request.principal))
	if !request_ok || !index_ok {
		return {status = .Bad_Command}
	}
	size := tpm_service.pin_payload_size(request.kind)
	policy, policy_failed, policy_ok := pin_policy_now()
	if !policy_ok {
		return policy_failed
	}
	payload: [tpm_service.PIN_LIMIT]u8
	state, count, read_failed, read_ok := pin_index_read(index, size, &policy, payload[:])
	if !read_ok {
		return read_failed
	}
	copy(region[tpm_service.REGION_PIN:][:count], payload[:count])
	system.log_fact(.Info, Pin_Read{index = value_kinds.Hexadecimal_Sixteen_Digits(index), state = u64(state), payload_bytes = u64(count)})
	return {status = .Ok, values = {0 = u64(count), 1 = u64(state)}}
}

// pin_write answers Pin_Write: it checks the new payload against the
// index, then defines the index when it must and writes the payload.
pin_write :: proc "contextless" (values: [7]u64) -> Outcome {
	request, request_ok := tpm_service.pin_request_of_values(.Pin_Write, values)
	index, index_ok := tpm2.pin_index_of(request.kind, u64(request.principal))
	if !request_ok || !index_ok {
		return {status = .Bad_Command}
	}
	size := tpm_service.pin_payload_size(request.kind)
	// One copy of the payload: the client can change the region while this
	// service reads it, so the checks and the write read the copy only.
	proposed: [tpm_service.PIN_LIMIT]u8
	copy(proposed[:size], region[tpm_service.REGION_PIN:][:size])
	policy, policy_failed, policy_ok := pin_policy_now()
	if !policy_ok {
		return policy_failed
	}
	stored: [tpm_service.PIN_LIMIT]u8
	state, stored_count, read_failed, read_ok := pin_index_read(index, size, &policy, stored[:])
	if !read_ok {
		return read_failed
	}
	// The whole check of the change comes before any command that changes
	// the TPM: an index of an older policy is removed only for a pin that
	// the stored one allows.
	step, refusal := tpm2.pin_write_plan(request, state, stored[:stored_count], proposed[:size])
	if refusal != .None {
		system.log_fact(.Warning, Pin_Write_Refused{index = value_kinds.Hexadecimal_Sixteen_Digits(index), pin_refusal = pin_refusal_field(refusal)})
		return {status = .Bad_Command, values = {0 = u64(refusal)}}
	}
	removed := false
	switch step {
	case .Remove_Then_Define_Then_Write:
		if failed, ok := pin_index_command(tpm2.nv_undefine_command(command_bytes[:], index), tpm2.COMMAND_NV_UNDEFINE_SPACE); !ok {
			return failed
		}
		removed = true
		system.log_fact(.Info, Pin_Index_Removed{index = value_kinds.Hexadecimal_Sixteen_Digits(index), state = u64(state)})
		fallthrough
	case .Define_Then_Write:
		if failed, ok := pin_index_command(tpm2.pin_define_command(command_bytes[:], index, &policy, size), tpm2.COMMAND_NV_DEFINE_SPACE); !ok {
			if removed {
				system.log_fact(.Warning, Pin_Lost_After_Removal{index = value_kinds.Hexadecimal_Sixteen_Digits(index)})
			}
			return failed
		}
	case .Write:
	}
	session, session_failed, session_ok := policy_session(.Policy, false)
	defer flush(session)
	if !session_ok {
		if removed {
			system.log_fact(.Warning, Pin_Lost_After_Removal{index = value_kinds.Hexadecimal_Sixteen_Digits(index)})
		}
		return session_failed
	}
	if failed, ok := pin_index_command(tpm2.pin_write_command(command_bytes[:], index, session, proposed[:size]), tpm2.COMMAND_NV_WRITE); !ok {
		if removed {
			system.log_fact(.Warning, Pin_Lost_After_Removal{index = value_kinds.Hexadecimal_Sixteen_Digits(index)})
		}
		return failed
	}
	system.log_fact(.Info, Pin_Written{index = value_kinds.Hexadecimal_Sixteen_Digits(index), payload_bytes = u64(size)})
	return {status = .Ok}
}

// pin_index_command sends one command of an index whose answer has no
// parameter that this service reads.
pin_index_command :: proc "contextless" (count: int, command: u32) -> (failed: Outcome, ok: bool) {
	answer, step := transact(count)
	if step != .None {
		return {status = .Device_Error, values = {0 = u64(step)}}, false
	}
	code, problem := tpm2.status_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, command), false
	}
	return {}, true
}

// pin_refusal_field gives the Text field of the words of a refusal of a
// pin.
pin_refusal_field :: proc "contextless" (refusal: tpm_attestation.Pin_Refusal) -> [PIN_REFUSAL_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_attestation.pin_refusal_words[refusal], PIN_REFUSAL_FIELD_BYTES)
}
