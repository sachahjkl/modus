#+build !freestanding
package tpm2

import info "modus:contract/boot_info"
import "modus:contract/tpm_service"
import "core:testing"

// The commands of the indices of the pins against their bytes, and the
// decision on each answer of TPM2_NV_ReadPublic and TPM2_NV_Read of a pin
// (src/md/features/tpm_sealed_machine_key.md, "The pin of the record").

@(private = "file")
PIN_SIZE :: 116 // The payload of the pin of the machine key.

// pin_public_answer_write writes an answer of TPM2_NV_ReadPublic: the
// public area of an index, then a name of SHA-256.
@(private = "file")
pin_public_answer_write :: proc(buffer: []u8, index: u32, name_algorithm: u16, attributes: u32, policy: []u8, data_size: u16) -> []u8 {
	writer := Command_Writer{buffer = buffer}
	put_u16(&writer, TAG_NO_SESSIONS)
	put_u32(&writer, 0)
	put_u32(&writer, RESPONSE_SUCCESS)
	area_place := writer.count
	put_u16(&writer, 0)
	put_u32(&writer, index)
	put_u16(&writer, name_algorithm)
	put_u32(&writer, attributes)
	put_sized(&writer, policy)
	put_u16(&writer, data_size)
	set_u16_at(&writer, area_place, u16(writer.count - area_place - 2))
	name: [2 + DIGEST_SIZE]u8
	name[1] = u8(ALGORITHM_SHA256)
	put_sized(&writer, name[:])
	set_u32_at(&writer, 2, u32(writer.count))
	return buffer[:writer.count]
}

// pin_read_answer_write writes an answer of TPM2_NV_Read: the size of the
// parameters, the data, then the session of the password.
@(private = "file")
pin_read_answer_write :: proc(buffer: []u8, data: []u8) -> []u8 {
	writer := Command_Writer{buffer = buffer}
	put_u16(&writer, TAG_SESSIONS)
	put_u32(&writer, 0)
	put_u32(&writer, RESPONSE_SUCCESS)
	put_u32(&writer, u32(2 + len(data)))
	put_sized(&writer, data)
	put_u16(&writer, 0) // No nonce.
	put_u8(&writer, SESSION_CONTINUE)
	put_u16(&writer, 0) // The empty HMAC.
	set_u32_at(&writer, 2, u32(writer.count))
	return buffer[:writer.count]
}

@(test)
each_pin_has_its_own_index :: proc(t: ^testing.T) {
	// A principal number on the machine key, principal 0, and one past the
	// limit name no index.
	_, ok := pin_index_of(.Machine_Key, 1)
	testing.expect(t, !ok)
	_, ok = pin_index_of(.Machine_Key, max(u64))
	testing.expect(t, !ok)
	_, ok = pin_index_of(.Principal_File, 0)
	testing.expect(t, !ok)
	_, ok = pin_index_of(.Principal_File, PIN_PRINCIPAL_LIMIT + 1)
	testing.expect(t, !ok)
	_, ok = pin_index_of(.Principal_File, max(u64))
	testing.expect(t, !ok)

	// No pin shares the index of a floor, or of another pin.
	machine, machine_ok := pin_index_of(.Machine_Key, 0)
	testing.expect(t, machine_ok)
	testing.expect_value(t, machine, u32(0x0180_6E00))
	last_floor := info.version_floor_index(info.FLOOR_LIMIT)
	testing.expect(t, machine > last_floor && machine > info.KEY_FLOOR_INDEX)
	previous := machine
	for principal in u64(1) ..= PIN_PRINCIPAL_LIMIT {
		index, index_ok := pin_index_of(.Principal_File, principal)
		testing.expect(t, index_ok)
		testing.expect_value(t, index, previous + 1)
		previous = index
	}
	testing.expect(t, previous <= 0x01BF_FFFF) // The range of the owner.
}

@(test)
the_pin_commands_have_their_bytes :: proc(t: ^testing.T) {
	buffer: [256]u8
	policy: [DIGEST_SIZE]u8
	for index in 0 ..< DIGEST_SIZE {
		policy[index] = u8(0xC0 + index)
	}
	count := pin_define_command(buffer[:], MACHINE_KEY_PIN_INDEX, &policy, PIN_SIZE)
	expected_define_head := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x4D, 0x00, 0x00, 0x01, 0x2A,
		0x40, 0x00, 0x00, 0x01, // The owner hierarchy.
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, // No authorization value of the index.
		0x00, 0x2E, // The public area: 46 bytes.
		0x01, 0x80, 0x6E, 0x00, 0x00, 0x0B, // The index, SHA-256.
		0x02, 0x04, 0x00, 0x08, // POLICYWRITE, an ordinary index, AUTHREAD, NO_DA.
		0x00, 0x20, // The policy: 32 bytes.
	}
	testing.expect_value(t, count, len(expected_define_head) + DIGEST_SIZE + 2)
	testing.expect(t, string(buffer[:len(expected_define_head)]) == string(expected_define_head[:]))
	testing.expect(t, string(buffer[len(expected_define_head):][:DIGEST_SIZE]) == string(policy[:]))
	testing.expect_value(t, buffer[count - 2], 0x00)
	testing.expect_value(t, buffer[count - 1], 0x74) // 116 bytes of data.
	// A size of 0 and one past the limit define nothing; a short buffer
	// gives nothing.
	testing.expect_value(t, pin_define_command(buffer[:], MACHINE_KEY_PIN_INDEX, &policy, 0), 0)
	testing.expect_value(t, pin_define_command(buffer[:], MACHINE_KEY_PIN_INDEX, &policy, tpm_service.PIN_LIMIT + 1), 0)
	testing.expect_value(t, pin_define_command(buffer[:count - 1], MACHINE_KEY_PIN_INDEX, &policy, PIN_SIZE), 0)

	payload: [PIN_SIZE]u8
	for index in 0 ..< PIN_SIZE {
		payload[index] = u8(index)
	}
	count = pin_write_command(buffer[:], MACHINE_KEY_PIN_INDEX, 0x0300_0001, payload[:])
	expected_write_head := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x97, 0x00, 0x00, 0x01, 0x37, // 151 bytes.
		0x01, 0x80, 0x6E, 0x00, 0x01, 0x80, 0x6E, 0x00, // The index authorizes its own write.
		0x00, 0x00, 0x00, 0x09, 0x03, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, // The policy session: no nonce, continue, an empty HMAC.
		0x00, 0x74, // 116 bytes of payload.
	}
	testing.expect_value(t, count, len(expected_write_head) + PIN_SIZE + 2)
	testing.expect(t, string(buffer[:len(expected_write_head)]) == string(expected_write_head[:]))
	testing.expect(t, string(buffer[len(expected_write_head):][:PIN_SIZE]) == string(payload[:]))
	testing.expect_value(t, buffer[count - 2], 0x00) // From its first byte.
	testing.expect_value(t, buffer[count - 1], 0x00)
	testing.expect_value(t, pin_write_command(buffer[:], MACHINE_KEY_PIN_INDEX, 0x0300_0001, nil), 0)
	too_long: [tpm_service.PIN_LIMIT + 1]u8
	testing.expect_value(t, pin_write_command(buffer[:], MACHINE_KEY_PIN_INDEX, 0x0300_0001, too_long[:]), 0)
	testing.expect_value(t, pin_write_command(buffer[:count - 1], MACHINE_KEY_PIN_INDEX, 0x0300_0001, payload[:]), 0)

	index, _ := pin_index_of(.Principal_File, 1)
	count = pin_read_command(buffer[:], index, 120)
	expected_read := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x23, 0x00, 0x00, 0x01, 0x4E,
		0x01, 0x80, 0x6E, 0x01, 0x01, 0x80, 0x6E, 0x01, // The index authorizes its own read.
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, // The empty password.
		0x00, 0x78, 0x00, 0x00, // 120 bytes from the first.
	}
	testing.expect_value(t, count, len(expected_read))
	testing.expect(t, string(buffer[:count]) == string(expected_read[:]))
	testing.expect_value(t, pin_read_command(buffer[:], index, 0), 0)
	testing.expect_value(t, pin_read_command(buffer[:], index, tpm_service.PIN_LIMIT + 1), 0)
}

// An index planted by another system, an index of a floor, a pin of
// another size or hash, and a pin that was never written are no pin of
// this system; a pin of the policy of an earlier PCR value is read, and
// written again with the policy of now.
@(test)
each_finding_of_a_pin_has_its_state_and_its_step :: proc(t: ^testing.T) {
	policy: [DIGEST_SIZE]u8
	policy[0] = 0x11
	other_policy := policy
	other_policy[31] = 0x22
	buffer: [256]u8
	public: Nv_Public
	index := MACHINE_KEY_PIN_INDEX

	absent := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x01, 0x8B}
	_, code, problem := nv_public_answer(absent[:])
	state, read := pin_state_of_public(problem, code, &public, index, PIN_SIZE, &policy)
	testing.expect(t, read && state == .Absent)
	// A failure of the TPM that names no handle, and a malformed answer,
	// decide nothing.
	failed := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x09, 0x01}
	_, code, problem = nv_public_answer(failed[:])
	_, read = pin_state_of_public(problem, code, &public, index, PIN_SIZE, &policy)
	testing.expect(t, !read)
	_, read = pin_state_of_public(.Malformed, 0, &public, index, PIN_SIZE, &policy)
	testing.expect(t, !read)

	Foreign_Case :: struct {
		index:          u32,
		name_algorithm: u16,
		attributes:     u32,
		policy_size:    int,
		data_size:      u16,
	}
	foreign_cases := [?]Foreign_Case {
		{index + 1, ALGORITHM_SHA256, PIN_ATTRIBUTES | NV_WRITTEN, DIGEST_SIZE, PIN_SIZE}, // Another index.
		{index, 0x0004, PIN_ATTRIBUTES | NV_WRITTEN, DIGEST_SIZE, PIN_SIZE}, // SHA-1.
		{index, ALGORITHM_SHA256, FLOOR_ATTRIBUTES | NV_WRITTEN, DIGEST_SIZE, PIN_SIZE}, // The type of a floor.
		{index, ALGORITHM_SHA256, (PIN_ATTRIBUTES &~ NV_POLICY_WRITE) | NV_WRITTEN, DIGEST_SIZE, PIN_SIZE}, // A write with no policy.
		{index, ALGORITHM_SHA256, (PIN_ATTRIBUTES &~ NV_AUTHORIZATION_READ) | NV_WRITTEN, DIGEST_SIZE, PIN_SIZE}, // A read that needs another authorization.
		{index, ALGORITHM_SHA256, PIN_ATTRIBUTES | NV_WRITTEN, DIGEST_SIZE, PIN_SIZE - 1}, // One byte short.
		{index, ALGORITHM_SHA256, PIN_ATTRIBUTES | NV_WRITTEN, DIGEST_SIZE, PIN_SIZE + 1}, // One byte long.
		{index, ALGORITHM_SHA256, PIN_ATTRIBUTES | NV_WRITTEN, 20, PIN_SIZE}, // A policy of SHA-1.
		{index, ALGORITHM_SHA256, PIN_ATTRIBUTES | NV_WRITTEN, 0, PIN_SIZE}, // No policy.
	}
	for other in foreign_cases {
		public, code, problem = nv_public_answer(pin_public_answer_write(buffer[:], other.index, other.name_algorithm, other.attributes, policy[:other.policy_size], other.data_size))
		testing.expect_value(t, problem, Answer_Problem.None)
		state, read = pin_state_of_public(problem, code, &public, index, PIN_SIZE, &policy)
		testing.expectf(t, read && state == .Foreign, "the index %v is %v, not Foreign", other, state)
	}

	public, code, problem = nv_public_answer(pin_public_answer_write(buffer[:], index, ALGORITHM_SHA256, PIN_ATTRIBUTES, policy[:], PIN_SIZE))
	state, read = pin_state_of_public(problem, code, &public, index, PIN_SIZE, &policy)
	testing.expect(t, read && state == .Never_Written)
	public, code, problem = nv_public_answer(pin_public_answer_write(buffer[:], index, ALGORITHM_SHA256, PIN_ATTRIBUTES | NV_WRITTEN, other_policy[:], PIN_SIZE))
	state, read = pin_state_of_public(problem, code, &public, index, PIN_SIZE, &policy)
	testing.expect(t, read && state == .Held_Other_Policy)
	public, code, problem = nv_public_answer(pin_public_answer_write(buffer[:], index, ALGORITHM_SHA256, PIN_ATTRIBUTES | NV_WRITTEN, policy[:], PIN_SIZE))
	state, read = pin_state_of_public(problem, code, &public, index, PIN_SIZE, &policy)
	testing.expect(t, read && state == .Held)

	testing.expect_value(t, pin_step_of(.Held), Pin_Step.Write)
	testing.expect_value(t, pin_step_of(.Absent), Pin_Step.Define_Then_Write)
	for planted in ([3]tpm_service.Pin_State{.Held_Other_Policy, .Foreign, .Never_Written}) {
		testing.expect_value(t, pin_step_of(planted), Pin_Step.Remove_Then_Define_Then_Write)
	}
}

@(test)
a_hostile_answer_of_a_pin_read_gives_nothing :: proc(t: ^testing.T) {
	buffer: [256]u8
	out: [tpm_service.PIN_LIMIT]u8
	data: [PIN_SIZE]u8
	for index in 0 ..< PIN_SIZE {
		data[index] = u8(0x30 + index)
	}
	// One byte short of the size asked, one byte more, no data, and a
	// buffer of the caller too small.
	count, _, problem := pin_read_answer(pin_read_answer_write(buffer[:], data[:PIN_SIZE - 1]), PIN_SIZE, out[:])
	testing.expect(t, problem == .Malformed && count == 0)
	longer: [PIN_SIZE + 1]u8
	count, _, problem = pin_read_answer(pin_read_answer_write(buffer[:], longer[:]), PIN_SIZE, out[:])
	testing.expect(t, problem == .Malformed && count == 0)
	count, _, problem = pin_read_answer(pin_read_answer_write(buffer[:], nil), PIN_SIZE, out[:])
	testing.expect(t, problem == .Malformed && count == 0)
	count, _, problem = pin_read_answer(pin_read_answer_write(buffer[:], data[:]), PIN_SIZE, out[:PIN_SIZE - 1])
	testing.expect(t, problem == .Malformed && count == 0)
	// An answer cut anywhere is malformed.
	whole := pin_read_answer_write(buffer[:], data[:])
	for cut in 0 ..< len(whole) - 5 {
		count, _, problem = pin_read_answer(whole[:cut], PIN_SIZE, out[:])
		testing.expectf(t, problem != .None && count == 0, "an answer cut at %d was taken", cut)
	}
	// A refusal of the TPM gives its code and no byte.
	refused := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x01, 0x49}
	code: u32
	count, code, problem = pin_read_answer(refused[:], PIN_SIZE, out[:])
	testing.expect(t, problem == .Refused && code == RESPONSE_NV_AUTHORIZATION && count == 0)
	for item in out {
		testing.expect_value(t, item, 0)
	}

	// The accepted case comes last.
	count, _, problem = pin_read_answer(pin_read_answer_write(buffer[:], data[:]), PIN_SIZE, out[:])
	testing.expect(t, problem == .None && count == PIN_SIZE)
	testing.expect(t, string(out[:PIN_SIZE]) == string(data[:]))
}
