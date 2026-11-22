// The indices of the pins: the record of the machine key and the file of
// each named principal, pinned in the TPM so that a writer of the disk
// cannot swap, remove or roll them back
// (src/md/features/tpm_sealed_machine_key.md, "The pin of the record").
//
// A pin is an ordinary index of the owner hierarchy. Anyone reads it with
// the empty password; only a policy session of TPM2_PolicyPCR of PCR 7 and
// PCR 11 with the values of the definition writes it: the system that
// defined it, after its measure, with the same state of Secure Boot. The
// payload is the one of modus:contract/tpm_attestation.
package tpm2

import "modus:contract/tpm_service"

COMMAND_NV_WRITE :: u32(0x0000_0137)

NV_TYPE_ORDINARY :: u32(0 << 4) // TPM_NT_ORDINARY: bytes that a write replaces.
// The attributes of a pin, NV_WRITTEN aside: a write by a policy session
// only, a read with the empty authorization value of the index, and no
// count of a wrong value.
PIN_ATTRIBUTES :: NV_POLICY_WRITE | NV_TYPE_ORDINARY | NV_AUTHORIZATION_READ | NV_NO_DICTIONARY_ATTACK

// The handles of the pins, in the range of the owner, after the floors
// (0x01806D00 to 0x01806D40): the pin of the machine key, then the pin of
// the file of the principal n at the base plus n.
PIN_INDEX_BASE :: u32(0x0180_6E00)
MACHINE_KEY_PIN_INDEX :: PIN_INDEX_BASE
// The highest principal number that has a pin index.
PIN_PRINCIPAL_LIMIT :: tpm_service.PIN_PRINCIPAL_LIMIT

// pin_index_of gives the handle of the index of a pin: principal is 0 for
// the machine key, and 1 to PIN_PRINCIPAL_LIMIT for a principal file. Any
// other pair names no index.
pin_index_of :: proc "contextless" (kind: tpm_service.Pin_Kind, principal: u64) -> (index: u32, ok: bool) {
	switch kind {
	case .Machine_Key:
		if principal != 0 {
			return 0, false
		}
		return MACHINE_KEY_PIN_INDEX, true
	case .Principal_File:
		if principal == 0 || principal > PIN_PRINCIPAL_LIMIT {
			return 0, false
		}
		return PIN_INDEX_BASE + u32(principal), true
	}
	return 0, false
}

// pin_define_command builds TPM2_NV_DefineSpace of a pin under the owner
// hierarchy with its empty password: no authorization value of the index,
// PIN_ATTRIBUTES, the policy given, and the bytes of the payload.
pin_define_command :: proc "contextless" (buffer: []u8, index: u32, policy: ^[DIGEST_SIZE]u8, size: int) -> int {
	if size <= 0 || size > tpm_service.PIN_LIMIT {
		return 0
	}
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_NV_DEFINE_SPACE)
	put_u32(&command_writer, HANDLE_OWNER)
	put_password_session(&command_writer)
	put_u16(&command_writer, 0) // No authorization value of the index.
	size_place := command_writer.count
	put_u16(&command_writer, 0)
	put_u32(&command_writer, index)
	put_u16(&command_writer, ALGORITHM_SHA256)
	put_u32(&command_writer, PIN_ATTRIBUTES)
	put_sized(&command_writer, policy^[:])
	put_u16(&command_writer, u16(size))
	set_u16_at(&command_writer, size_place, u16(command_writer.count - size_place - 2))
	return end(&command_writer)
}

// pin_write_command builds TPM2_NV_Write of the whole payload of a pin,
// from its first byte, in a policy session that ran policy_pcr_command.
// The session has no key, so its HMAC is empty.
pin_write_command :: proc "contextless" (buffer: []u8, index: u32, session: u32, payload: []u8) -> int {
	if len(payload) == 0 || len(payload) > tpm_service.PIN_LIMIT {
		return 0
	}
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_NV_WRITE)
	put_u32(&command_writer, index) // The authorization: the index, through its policy.
	put_u32(&command_writer, index)
	put_u32(&command_writer, 9) // The bytes of the area: one session of 9 bytes.
	put_u32(&command_writer, session)
	put_u16(&command_writer, 0) // No nonce.
	put_u8(&command_writer, SESSION_CONTINUE)
	put_u16(&command_writer, 0) // The empty HMAC.
	put_sized(&command_writer, payload)
	put_u16(&command_writer, 0) // From its first byte.
	return end(&command_writer)
}

// pin_read_command builds TPM2_NV_Read of the whole payload of a pin, with
// the index as its own authorization and the empty password.
pin_read_command :: proc "contextless" (buffer: []u8, index: u32, size: int) -> int {
	if size <= 0 || size > tpm_service.PIN_LIMIT {
		return 0
	}
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_NV_READ)
	put_u32(&command_writer, index)
	put_u32(&command_writer, index)
	put_password_session(&command_writer)
	put_u16(&command_writer, u16(size))
	put_u16(&command_writer, 0)
	return end(&command_writer)
}

// pin_read_answer reads the answer of TPM2_NV_Read of a pin: exactly the
// bytes asked, copied to out.
pin_read_answer :: proc "contextless" (answer: []u8, size: int, out: []u8) -> (count: int, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return 0, code, problem
	}
	parameters_begin(&reader)
	_, data := take_sized(&reader)
	if reader.failed || len(data) != size || size > len(out) {
		return 0, code, .Malformed
	}
	copy(out[:size], data)
	return size, code, .None
}

// pin_public_shape_check says if a public area has the shape of a pin of
// the size given at the index given: SHA-256, PIN_ATTRIBUTES with
// NV_WRITTEN set or not, and a policy of one SHA-256 digest. The policy
// itself is compared by pin_state_of_public.
pin_public_shape_check :: proc "contextless" (public: ^Nv_Public, index: u32, size: int) -> bool {
	return public.index == index && public.name_algorithm == ALGORITHM_SHA256 && public.attributes & ~NV_WRITTEN == PIN_ATTRIBUTES && int(public.data_size) == size && public.policy_size == DIGEST_SIZE
}

// pin_state_of_public decides the state of the index of a pin from the
// answer of TPM2_NV_ReadPublic, and the policy of PCR 7 and PCR 11 now.
// read is false when the TPM gave no answer that decides: the caller then
// changes nothing.
//
// Held_Other_Policy is a pin whose policy names other PCR values: this
// system before an update, or before a change of PCR 7. Its payload is
// read, as only a writer of the TPM could have written it; the next write
// defines the index again with the policy of now.
pin_state_of_public :: proc "contextless" (problem: Answer_Problem, code: u32, public: ^Nv_Public, index: u32, size: int, policy: ^[DIGEST_SIZE]u8) -> (state: tpm_service.Pin_State, read: bool) {
	switch {
	case problem == .Refused && handle_absent(code):
		return .Absent, true
	case problem != .None:
		return .Absent, false
	case !pin_public_shape_check(public, index, size):
		return .Foreign, true
	case public.attributes & NV_WRITTEN == 0:
		return .Never_Written, true
	case string(public.policy[:DIGEST_SIZE]) != string(policy^[:]):
		return .Held_Other_Policy, true
	}
	return .Held, true
}

// The step of a write of a pin, from the state of its index.
Pin_Step :: enum u8 {
	Write, // The index is a pin with the policy of now: write it.
	Define_Then_Write, // No index: define it, then write it.
	Remove_Then_Define_Then_Write, // An index that is not a pin of now: remove it, define it, then write it.
}

// pin_step_of gives the step of a write of a pin in a given state.
pin_step_of :: proc "contextless" (state: tpm_service.Pin_State) -> Pin_Step {
	switch state {
	case .Held:
		return .Write
	case .Absent:
		return .Define_Then_Write
	case .Held_Other_Policy, .Foreign, .Never_Written:
		return .Remove_Then_Define_Then_Write
	}
	return .Remove_Then_Define_Then_Write
}
