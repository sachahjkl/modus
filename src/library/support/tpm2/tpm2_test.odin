#+build !freestanding
package tpm2

import "core:testing"

// Each command is compared with its bytes, as part 3 of the TPM 2.0
// library gives its fields: a wrong size or a field in the wrong order is
// refused by a TPM, and no host test sees a TPM.

@(test)
the_storage_key_command_has_its_bytes :: proc(t: ^testing.T) {
	buffer: [256]u8
	count := create_primary_command(buffer[:])
	expected := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x43, 0x00, 0x00, 0x01, 0x31, // The header: 67 bytes.
		0x40, 0x00, 0x00, 0x01, // The owner hierarchy.
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, // The empty password.
		0x00, 0x04, 0x00, 0x00, 0x00, 0x00, // No authorization value, no data.
		0x00, 0x1A, // The public part: 26 bytes.
		0x00, 0x23, 0x00, 0x0B, 0x00, 0x03, 0x04, 0x72, 0x00, 0x00, // ECC, SHA-256, the attributes, no policy.
		0x00, 0x06, 0x00, 0x80, 0x00, 0x43, // AES-128 in CFB mode.
		0x00, 0x10, 0x00, 0x03, 0x00, 0x10, // No scheme, P-256, no key derivation function.
		0x00, 0x00, 0x00, 0x00, // The empty unique point.
		0x00, 0x00, // No outside information.
		0x00, 0x00, 0x00, 0x00, // No PCR.
	}
	testing.expect_value(t, count, len(expected))
	testing.expect(t, string(buffer[:count]) == string(expected[:]))
	// A buffer one byte too small gives no command.
	testing.expect_value(t, create_primary_command(buffer[:len(expected) - 1]), 0)
}

@(test)
the_session_commands_have_their_bytes :: proc(t: ^testing.T) {
	buffer: [256]u8
	count := start_session_command(buffer[:], SESSION_TRIAL)
	expected_start := [?]u8 {
		0x80, 0x01, 0x00, 0x00, 0x00, 0x2B, 0x00, 0x00, 0x01, 0x76,
		0x40, 0x00, 0x00, 0x07, 0x40, 0x00, 0x00, 0x07, // No key, no bind.
		0x00, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // The nonce: 16 zero bytes.
		0x00, 0x00, // No salt.
		0x03, // Trial.
		0x00, 0x10, // No symmetric algorithm.
		0x00, 0x0B, // SHA-256.
	}
	testing.expect_value(t, count, len(expected_start))
	testing.expect(t, string(buffer[:count]) == string(expected_start[:]))
	count = start_session_command(buffer[:], SESSION_POLICY)
	testing.expect_value(t, count, len(expected_start))
	testing.expect_value(t, buffer[38], SESSION_POLICY) // After the header, the two handles, the nonce and the salt.

	count = policy_pcr_command(buffer[:], 0x0300_0000)
	expected_pcr := [?]u8 {
		0x80, 0x01, 0x00, 0x00, 0x00, 0x1A, 0x00, 0x00, 0x01, 0x7F,
		0x03, 0x00, 0x00, 0x00, // The session.
		0x00, 0x00, // No digest: the values of now.
		0x00, 0x00, 0x00, 0x01, 0x00, 0x0B, 0x03, 0x80, 0x08, 0x00, // PCR 7 and PCR 11 of SHA-256.
	}
	testing.expect_value(t, count, len(expected_pcr))
	testing.expect(t, string(buffer[:count]) == string(expected_pcr[:]))

	count = policy_get_digest_command(buffer[:], 0x0300_0000)
	expected_digest := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x01, 0x89, 0x03, 0x00, 0x00, 0x00}
	testing.expect(t, string(buffer[:count]) == string(expected_digest[:]))

	count = flush_command(buffer[:], 0x8000_0001)
	expected_flush := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x01, 0x65, 0x80, 0x00, 0x00, 0x01}
	testing.expect(t, string(buffer[:count]) == string(expected_flush[:]))
}

@(test)
the_seal_and_the_unseal_have_their_bytes :: proc(t: ^testing.T) {
	buffer: [512]u8
	secret, policy: [32]u8
	for index in 0 ..< 32 {
		secret[index] = u8(index + 1)
		policy[index] = u8(0xA0 + index)
	}
	count := create_sealed_command(buffer[:], 0x8000_0000, &secret, &policy, nil)
	testing.expect_value(t, count, 125)
	header := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00, 0x01, 0x53,
		0x80, 0x00, 0x00, 0x00, // The storage key.
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x24, 0x00, 0x00, 0x00, 0x20, // 36 bytes: no authorization value, 32 bytes of data.
	}
	testing.expect(t, string(buffer[:len(header)]) == string(header[:]))
	testing.expect(t, string(buffer[len(header):][:32]) == string(secret[:]))
	public_start := len(header) + 32
	public_head := [?]u8 {
		0x00, 0x2E, // 46 bytes.
		0x00, 0x08, 0x00, 0x0B, 0x00, 0x00, 0x04, 0x92, // Keyed hash, SHA-256, the attributes: userWithAuth clear, adminWithPolicy set.
		0x00, 0x20, // The policy: 32 bytes.
	}
	testing.expect(t, string(buffer[public_start:][:len(public_head)]) == string(public_head[:]))
	testing.expect(t, string(buffer[public_start + len(public_head):][:32]) == string(policy[:]))
	tail := [?]u8 {
		0x00, 0x10, 0x00, 0x00, // No scheme, no unique bytes.
		0x00, 0x00, // No outside information.
		0x00, 0x00, 0x00, 0x01, 0x00, 0x0B, 0x03, 0x80, 0x08, 0x00, // PCR 7 and PCR 11 in the creation data.
	}
	testing.expect(t, string(buffer[public_start + len(public_head) + 32:count]) == string(tail[:]))

	count = unseal_command(buffer[:], 0x8000_0001, 0x0300_0000, nil)
	expected_unseal := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x1B, 0x00, 0x00, 0x01, 0x5E,
		0x80, 0x00, 0x00, 0x01, // The sealed object.
		0x00, 0x00, 0x00, 0x09, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, // The policy session: no nonce, continue, an empty HMAC.
	}
	testing.expect_value(t, count, len(expected_unseal))
	testing.expect(t, string(buffer[:count]) == string(expected_unseal[:]))

	private_area := [?]u8{0x00, 0x02, 0xAA, 0xBB}
	public_area := [?]u8{0x00, 0x01, 0xCC}
	count = load_command(buffer[:], 0x8000_0000, public_area[:], private_area[:])
	expected_load := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x01, 0x57,
		0x80, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x02, 0xAA, 0xBB, // The private area first,
		0x00, 0x01, 0xCC, // then the public area.
	}
	testing.expect_value(t, count, len(expected_load))
	testing.expect(t, string(buffer[:count]) == string(expected_load[:]))
}

@(test)
the_answers_are_read_and_checked :: proc(t: ^testing.T) {
	// A session: the handle, then the nonce of the TPM.
	session_answer := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	handle, code, problem := handle_answer(session_answer[:])
	testing.expect_value(t, problem, Answer_Problem.None)
	testing.expect_value(t, handle, u32(0x0300_0000))
	testing.expect_value(t, code, RESPONSE_SUCCESS)

	// A storage key: the handle, the size of the parameters, and the area of
	// the sessions.
	primary_answer := [?]u8{0x80, 0x02, 0x00, 0x00, 0x00, 0x1B, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 9, 9, 9, 9, 0x00, 0x00, 0x01, 0x00, 0x00}
	handle, _, problem = handle_answer(primary_answer[:])
	testing.expect_value(t, problem, Answer_Problem.None)
	testing.expect_value(t, handle, u32(0x8000_0000))
	// A size of the parameters past the end.
	wrong_parameters := primary_answer
	wrong_parameters[17] = 0x40
	_, _, problem = handle_answer(wrong_parameters[:])
	testing.expect_value(t, problem, Answer_Problem.Malformed)

	// A refusal: the policy does not hold for session 1.
	refusal := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x09, 0x9D}
	_, code, problem = handle_answer(refusal[:])
	testing.expect_value(t, problem, Answer_Problem.Refused)
	testing.expect_value(t, code, u32(0x99D))
	testing.expect(t, policy_fails(code))
	testing.expect(t, !policy_fails(0x101)) // A format 0 code is no failure of a policy.
	// TPM_RC_TICKET of parameter 4, the ticket of TPM2_CertifyCreation; a
	// lack of memory of the TPM is no fault of a ticket.
	testing.expect(t, ticket_fails(0x4A0))
	testing.expect(t, !ticket_fails(0x99D))
	testing.expect(t, !ticket_fails(0x902)) // TPM_RC_OBJECT_MEMORY.

	// A size in the header that is not the count of the bytes.
	short := refusal
	short[5] = 0x0B
	_, _, problem = handle_answer(short[:])
	testing.expect_value(t, problem, Answer_Problem.Malformed)
	_, _, problem = handle_answer(refusal[:9])
	testing.expect_value(t, problem, Answer_Problem.Malformed)
	_, _, problem = handle_answer(nil)
	testing.expect_value(t, problem, Answer_Problem.Malformed)

	// A digest of 32 bytes, and one of 31.
	digest_bytes: [44]u8
	digest_head := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20}
	copy(digest_bytes[:], digest_head[:])
	for index in 0 ..< 32 {
		digest_bytes[12 + index] = u8(index)
	}
	digest, _, digest_problem := digest_answer(digest_bytes[:])
	testing.expect_value(t, digest_problem, Answer_Problem.None)
	testing.expect_value(t, digest[31], u8(31))
	digest_bytes[5], digest_bytes[11] = 0x2B, 0x1F
	_, _, digest_problem = digest_answer(digest_bytes[:43])
	testing.expect_value(t, digest_problem, Answer_Problem.Malformed)
}

// creation_data_write writes a creation data, with its size field, as the
// TPM gives it for PCR 7 and PCR 11 of SHA-256: the selection, the digest of
// the PCRs, the locality, the name of the parent, its qualified name, and
// no outside information.
@(private = "file")
creation_data_write :: proc(buffer: []u8, pcr_digest: [DIGEST_SIZE]u8) -> []u8 {
	writer := Command_Writer{buffer = buffer}
	put_u16(&writer, 0)
	put_pcr_selection(&writer)
	digest := pcr_digest
	put_sized(&writer, digest[:])
	put_u8(&writer, 0)
	put_u16(&writer, ALGORITHM_SHA256)
	name: [34]u8
	put_sized(&writer, name[:])
	put_sized(&writer, name[:])
	put_u16(&writer, 0)
	set_u16_at(&writer, 0, u16(writer.count - 2))
	return buffer[:writer.count]
}

// ticket_write writes a creation ticket of the owner hierarchy.
@(private = "file")
ticket_write :: proc(buffer: []u8) -> []u8 {
	writer := Command_Writer{buffer = buffer}
	put_u16(&writer, TAG_CREATION)
	put_u32(&writer, HANDLE_OWNER)
	digest: [DIGEST_SIZE]u8
	for &item in digest {
		item = 0x5A
	}
	put_sized(&writer, digest[:])
	return buffer[:writer.count]
}

// public_write writes the public area of a sealed object, with its size
// field, with a policy and attributes.
@(private = "file")
public_write :: proc(buffer: []u8, policy: [DIGEST_SIZE]u8, attributes: u32) -> []u8 {
	writer := Command_Writer{buffer = buffer}
	put_u16(&writer, 0)
	put_u16(&writer, ALGORITHM_KEYED_HASH)
	put_u16(&writer, ALGORITHM_SHA256)
	put_u32(&writer, attributes)
	object_policy := policy
	put_sized(&writer, object_policy[:])
	put_u16(&writer, ALGORITHM_NULL)
	unique: [DIGEST_SIZE]u8
	put_sized(&writer, unique[:])
	set_u16_at(&writer, 0, u16(writer.count - 2))
	return buffer[:writer.count]
}

// The digests of SHA-256 of the checks, from hashlib of Python: the policy
// of PCR 7 and PCR 11 whose digest is 32 bytes of 0x11, and the creation
// hash of the bytes "creation data".
@(test)
the_policy_and_the_creation_hash_have_their_digests :: proc(t: ^testing.T) {
	pcr_digest: [DIGEST_SIZE]u8
	for &item in pcr_digest {
		item = 0x11
	}
	policy := policy_pcr_digest(&pcr_digest)
	expected_policy := [DIGEST_SIZE]u8{0x55, 0x67, 0x25, 0x1b, 0x09, 0x1e, 0xe9, 0xdb, 0xb8, 0x8c, 0xae, 0x8c, 0x84, 0x05, 0x79, 0xa3, 0xbc, 0xa3, 0xd7, 0x9f, 0x1a, 0xdb, 0x61, 0xd6, 0x99, 0x86, 0x35, 0x07, 0x5f, 0xf2, 0x68, 0x63}
	testing.expect(t, policy == expected_policy)
	sized := [?]u8{0x00, 0x0D, 'c', 'r', 'e', 'a', 't', 'i', 'o', 'n', ' ', 'd', 'a', 't', 'a'}
	hash := creation_hash(sized[:])
	expected_hash := [DIGEST_SIZE]u8{0x73, 0x25, 0x9d, 0x8f, 0x35, 0x25, 0x86, 0x4f, 0xa8, 0xe6, 0x29, 0x20, 0xb2, 0xbd, 0x0e, 0x9f, 0xbf, 0xd3, 0x08, 0xfd, 0x65, 0x57, 0x51, 0xad, 0xcd, 0x0a, 0xef, 0x6e, 0x1b, 0x18, 0xbc, 0x43}
	testing.expect(t, hash == expected_hash)
}

// The proof of the creation: the creation data must name PCR 7 and PCR 11
// with a digest, the ticket must have its form, and the public area must
// have the attributes of a sealed object and the policy of the PCR values
// of its creation data. An object that another system made with the policy
// of this system has a creation data with the PCRs of that system: its
// policy is not the policy of its creation data, and it is refused.
@(test)
a_forged_sealed_object_is_refused :: proc(t: ^testing.T) {
	this_system, other_system: [DIGEST_SIZE]u8
	for index in 0 ..< DIGEST_SIZE {
		this_system[index] = u8(index)
		other_system[index] = u8(index + 1)
	}
	creation_buffer: [CREATION_DATA_LIMIT]u8
	creation := creation_data_write(creation_buffer[:], this_system)
	testing.expect_value(t, len(creation), 123)
	digest, read := creation_data_pcr_digest(creation)
	testing.expect(t, read)
	testing.expect(t, digest == this_system)
	policy := policy_pcr_digest(&this_system)
	public_buffer: [PUBLIC_AREA_LIMIT]u8
	testing.expect(t, sealed_public_check(public_write(public_buffer[:], policy, SEALED_OBJECT_ATTRIBUTES), &policy, SEALED_OBJECT_ATTRIBUTES))
	// The object of the other system: the policy of this system, the
	// creation data of the other one.
	other_creation_buffer: [CREATION_DATA_LIMIT]u8
	other_digest, other_read := creation_data_pcr_digest(creation_data_write(other_creation_buffer[:], other_system))
	testing.expect(t, other_read)
	policy_of_the_other_creation := policy_pcr_digest(&other_digest)
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], policy, SEALED_OBJECT_ATTRIBUTES), &policy_of_the_other_creation, SEALED_OBJECT_ATTRIBUTES))
	// The attributes: userWithAuth set, adminWithPolicy clear, another
	// fixed bit clear.
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], policy, SEALED_OBJECT_ATTRIBUTES | ATTRIBUTE_USER_WITH_AUTH), &policy, SEALED_OBJECT_ATTRIBUTES))
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], policy, SEALED_OBJECT_ATTRIBUTES &~ ATTRIBUTE_ADMIN_WITH_POLICY), &policy, SEALED_OBJECT_ATTRIBUTES))
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], policy, SEALED_OBJECT_ATTRIBUTES &~ ATTRIBUTE_FIXED_TPM), &policy, SEALED_OBJECT_ATTRIBUTES))
	// A creation data with PCR 11 only, a byte after it, or a cut digest.
	changed := creation_buffer
	changed[2 + 4 + 2 + 1] = 0x00 // No PCR 7.
	_, read = creation_data_pcr_digest(changed[:len(creation)])
	testing.expect(t, !read)
	longer := creation_buffer
	longer[1] += 1
	_, read = creation_data_pcr_digest(longer[:len(creation) + 1])
	testing.expect(t, !read)
	cut := creation_buffer
	cut[2 + 10 + 1] = 31 // A digest of 31 bytes: the fields after it no longer end at the end.
	_, read = creation_data_pcr_digest(cut[:len(creation)])
	testing.expect(t, !read)
	// The ticket: its form, another tag, a byte after it.
	ticket_buffer: [CREATION_TICKET_LIMIT]u8
	ticket := ticket_write(ticket_buffer[:])
	testing.expect_value(t, len(ticket), 40)
	testing.expect(t, ticket_fits(ticket))
	testing.expect(t, !ticket_fits(ticket_buffer[:len(ticket) + 1]))
	other_tag := ticket_buffer
	other_tag[1] = 0x22
	testing.expect(t, !ticket_fits(other_tag[:len(ticket)]))
	// The command that makes the TPM check the ticket.
	command: [256]u8
	hash := creation_hash(creation)
	count := certify_creation_command(command[:], 0x8000_0001, &hash, ticket)
	expected_head := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x6D, 0x00, 0x00, 0x01, 0x4A, // 109 bytes.
		0x40, 0x00, 0x00, 0x07, 0x80, 0x00, 0x00, 0x01, // No signing key, the object.
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, // The empty password of the handle NULL.
		0x00, 0x00, // No qualifying data.
		0x00, 0x20, // The creation hash: 32 bytes.
	}
	testing.expect_value(t, count, 109)
	testing.expect(t, string(command[:len(expected_head)]) == string(expected_head[:]))
	testing.expect(t, string(command[len(expected_head):][:32]) == string(hash[:]))
	testing.expect_value(t, command[len(expected_head) + 33], u8(0x10)) // No scheme.
	testing.expect(t, string(command[count - len(ticket):count]) == string(ticket))
}

// The answer of swtpm (libtpms) to the TPM2_Create of the TPM service, on
// the test machine: 488 bytes, taken from the log of swtpm. Its creation
// ticket has a digest of SHA-512, 64 bytes, and the area of the sessions
// follows the parameters.
@(private = "file")
swtpm_create_answer := [488]u8 {
		0x80, 0x02, 0x00, 0x00, 0x01, 0xE8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xD5, 0x00, 0x9E,
		0x00, 0x20, 0xFA, 0x1D, 0x04, 0x66, 0x66, 0x6E, 0x20, 0x78, 0x8D, 0x2D, 0x58, 0xD5, 0x28, 0xA8,
		0x10, 0x8D, 0x0E, 0xF2, 0xDB, 0x06, 0x1F, 0xB4, 0x35, 0x9D, 0x09, 0x3C, 0xAA, 0x1F, 0x8E, 0x6C,
		0x9F, 0xAB, 0x00, 0x10, 0xB1, 0x8A, 0x6C, 0x85, 0x13, 0xA1, 0xAD, 0x47, 0x9A, 0x77, 0x8F, 0x0F,
		0x11, 0x3F, 0xBA, 0x34, 0x00, 0xEC, 0x91, 0xDD, 0x3E, 0xCB, 0xD7, 0x35, 0xDA, 0xE4, 0x17, 0x42,
		0x27, 0x29, 0xB7, 0x59, 0xCF, 0x45, 0xDA, 0x02, 0x48, 0xFD, 0x75, 0xCB, 0x3C, 0x11, 0x2A, 0x26,
		0x8A, 0xF0, 0xDA, 0x05, 0x19, 0x9E, 0xA7, 0xDF, 0x85, 0x8B, 0x3A, 0x1B, 0x85, 0xA6, 0x40, 0x66,
		0xDD, 0xBA, 0x64, 0x32, 0xB2, 0x22, 0x8F, 0x1E, 0x4C, 0x90, 0x9E, 0x78, 0x64, 0x1F, 0x11, 0x0E,
		0xDB, 0x70, 0x51, 0x61, 0xB7, 0xF2, 0xE3, 0x65, 0xC8, 0x04, 0xF5, 0xF2, 0x9D, 0x11, 0x49, 0xA2,
		0x66, 0xE0, 0xF3, 0x4F, 0x26, 0xC2, 0x31, 0x5E, 0xA7, 0x64, 0xEB, 0xB8, 0xCD, 0xC4, 0x38, 0x99,
		0x34, 0x53, 0xE0, 0x41, 0x2E, 0xE4, 0xA6, 0x89, 0x5F, 0x4F, 0x80, 0xB4, 0x7B, 0x87, 0x00, 0x4E,
		0x00, 0x08, 0x00, 0x0B, 0x00, 0x00, 0x04, 0x92, 0x00, 0x20, 0x18, 0xC4, 0xCE, 0x7A, 0xB6, 0xF6,
		0x57, 0x7C, 0x8B, 0xC6, 0x3B, 0xBB, 0x1E, 0xED, 0xE1, 0x10, 0x58, 0xE9, 0x01, 0x91, 0x7F, 0x95,
		0xD4, 0x3B, 0xF1, 0xD2, 0xF9, 0xBF, 0xCE, 0x29, 0xF9, 0x6C, 0x00, 0x10, 0x00, 0x20, 0x89, 0x1A,
		0x48, 0x6A, 0xF4, 0x02, 0x93, 0xF0, 0x16, 0xAF, 0x7B, 0x43, 0x0E, 0x98, 0xC6, 0xF4, 0x97, 0xA3,
		0x74, 0x25, 0x79, 0x53, 0x56, 0xA4, 0x03, 0xED, 0xAB, 0x63, 0xA9, 0xB4, 0x03, 0x3C, 0x00, 0x79,
		0x00, 0x00, 0x00, 0x01, 0x00, 0x0B, 0x03, 0x80, 0x08, 0x00, 0x00, 0x20, 0x7D, 0x9F, 0x21, 0x30,
		0x03, 0x94, 0x59, 0x20, 0x38, 0x47, 0x33, 0x7A, 0xAE, 0x40, 0xBE, 0x5C, 0xDE, 0x29, 0x0C, 0xD6,
		0x7E, 0x6C, 0x70, 0x8C, 0xBF, 0xCD, 0x40, 0x7D, 0xD8, 0xC3, 0x4E, 0x94, 0x01, 0x00, 0x0B, 0x00,
		0x22, 0x00, 0x0B, 0xD2, 0x94, 0xB7, 0x70, 0x26, 0xCF, 0x40, 0x55, 0x8D, 0x01, 0xF9, 0x23, 0x91,
		0x69, 0x02, 0xA6, 0x67, 0x08, 0x27, 0xCA, 0xA2, 0x23, 0x61, 0x5A, 0x00, 0x59, 0xD0, 0x5F, 0xAF,
		0x57, 0xE3, 0xCE, 0x00, 0x22, 0x00, 0x0B, 0x69, 0x77, 0x8B, 0xFE, 0xF2, 0x70, 0x35, 0xE4, 0xE2,
		0x34, 0xEA, 0x9B, 0xFF, 0xB9, 0x35, 0x4D, 0xCA, 0xA3, 0xA6, 0xE5, 0xA1, 0xB9, 0x1D, 0xE0, 0x05,
		0xA6, 0xDD, 0x7D, 0x65, 0x6D, 0x6D, 0xB4, 0x00, 0x00, 0x00, 0x20, 0x37, 0x1D, 0x82, 0xFA, 0xE4,
		0xFE, 0x15, 0x89, 0x28, 0xE4, 0xE1, 0x30, 0x16, 0x7F, 0x07, 0xA9, 0xE4, 0x0A, 0x8A, 0xF7, 0x47,
		0xB7, 0xE2, 0xD6, 0xE7, 0x7E, 0x7B, 0x18, 0x97, 0x7E, 0x49, 0x51, 0x80, 0x21, 0x40, 0x00, 0x00,
		0x01, 0x00, 0x40, 0x4E, 0xB9, 0x16, 0xEF, 0x9D, 0xD6, 0xD6, 0x4D, 0x69, 0x6F, 0x65, 0xA3, 0x27,
		0x95, 0x45, 0x49, 0xC2, 0xBD, 0xC2, 0x04, 0x36, 0x1D, 0x03, 0x9F, 0x9E, 0xCE, 0x22, 0xCC, 0x5B,
		0x69, 0x18, 0x0E, 0x77, 0x70, 0x31, 0xCA, 0xA1, 0xE7, 0x45, 0x94, 0x5C, 0x7D, 0x53, 0x4A, 0x33,
		0x0D, 0x6A, 0x84, 0x24, 0x00, 0xF9, 0x77, 0xE8, 0x0E, 0x41, 0x47, 0xB4, 0x91, 0xDD, 0x04, 0xB7,
		0x84, 0xDC, 0xE7, 0x00, 0x00, 0x01, 0x00, 0x00,
}

// The real answer is taken whole, each part within its limit; the checks of
// the unseal pass on it: the policy of the object is the policy of its
// creation data, and the creation hash is the hash that the TPM gave.
@(test)
the_answer_of_swtpm_to_the_seal_is_taken :: proc(t: ^testing.T) {
	answer := swtpm_create_answer
	created, code, problem := create_answer(answer[:])
	testing.expect_value(t, problem, Answer_Problem.None)
	testing.expect_value(t, code, RESPONSE_SUCCESS)
	testing.expect_value(t, len(created.private_area), 160)
	testing.expect_value(t, len(created.public_area), 80)
	testing.expect_value(t, len(created.creation_data), 123)
	testing.expect_value(t, len(created.creation_ticket), CREATION_TICKET_LIMIT)
	testing.expect(t, ticket_fits(created.creation_ticket))
	pcr_digest, named := creation_data_pcr_digest(created.creation_data)
	testing.expect(t, named)
	policy := policy_pcr_digest(&pcr_digest)
	testing.expect(t, sealed_public_check(created.public_area, &policy, SEALED_OBJECT_ATTRIBUTES))
	// The creation hash of the answer: after the header, the size of the
	// parameters, the two areas and the creation data, then its size field.
	HEADER_AND_PARAMETERS_SIZE :: 10 + 4
	hash := creation_hash(created.creation_data)
	hash_place := HEADER_AND_PARAMETERS_SIZE + len(created.private_area) + len(created.public_area) + len(created.creation_data) + 2
	testing.expect(t, string(hash[:]) == string(answer[hash_place:][:DIGEST_SIZE]))
	// A size of the parameters that counts the area of the sessions as a
	// parameter is refused: the low byte of the size, at the end of the
	// header, grows by the 5 bytes of that area.
	SESSION_AREA_SIZE :: 5
	changed := answer
	changed[HEADER_AND_PARAMETERS_SIZE - 1] += SESSION_AREA_SIZE
	_, _, problem = create_answer(changed[:])
	testing.expect_value(t, problem, Answer_Problem.Malformed)
	// A ticket with a digest one byte larger than the largest of a TPM.
	larger: [CREATION_TICKET_LIMIT + 1]u8
	copy(larger[:], created.creation_ticket)
	larger[len(created.creation_ticket) - TICKET_DIGEST_LIMIT - 1] += 1
	testing.expect(t, !ticket_fits(larger[:]))
}

@(test)
the_areas_and_the_secret_are_taken_within_their_limits :: proc(t: ^testing.T) {
	// An answer of TPM2_Create: the two areas, the creation data, the
	// creation hash, the ticket, then the area of the sessions.
	answer: [512]u8
	writer := begin(answer[:], TAG_SESSIONS, RESPONSE_SUCCESS)
	put_u32(&writer, 0)
	parameters_start := writer.count
	private_bytes := [?]u8{0xAA, 0xBB, 0xCC, 0xDD}
	put_sized(&writer, private_bytes[:])
	public_buffer: [PUBLIC_AREA_LIMIT]u8
	this_system: [DIGEST_SIZE]u8
	public_area := public_write(public_buffer[:], policy_pcr_digest(&this_system), SEALED_OBJECT_ATTRIBUTES)
	put_bytes(&writer, public_area)
	creation_buffer: [CREATION_DATA_LIMIT]u8
	creation := creation_data_write(creation_buffer[:], this_system)
	put_bytes(&writer, creation)
	hash := creation_hash(creation)
	put_sized(&writer, hash[:])
	ticket_buffer: [CREATION_TICKET_LIMIT]u8
	ticket := ticket_write(ticket_buffer[:])
	put_bytes(&writer, ticket)
	set_u32_at(&writer, parameters_start - 4, u32(writer.count - parameters_start))
	sessions := [?]u8{0x00, 0x00, 0x01, 0x00, 0x00}
	put_bytes(&writer, sessions[:])
	count := end(&writer)
	created, _, problem := create_answer(answer[:count])
	testing.expect_value(t, problem, Answer_Problem.None)
	expected_private := [?]u8{0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD}
	testing.expect(t, string(created.private_area) == string(expected_private[:]))
	testing.expect(t, string(created.public_area) == string(public_area))
	testing.expect(t, string(created.creation_data) == string(creation))
	testing.expect(t, string(created.creation_ticket) == string(ticket))
	testing.expect(t, area_fits(created.private_area, PRIVATE_AREA_LIMIT))
	testing.expect(t, area_fits(created.public_area, PUBLIC_AREA_LIMIT))
	// The same answer with a ticket of another tag is refused.
	changed := answer
	changed[count - len(sessions) - len(ticket) + 1] = 0x22
	_, _, problem = create_answer(changed[:count])
	testing.expect_value(t, problem, Answer_Problem.Malformed)

	// A private area larger than the record keeps.
	large: [512]u8
	large_head := [?]u8{0x80, 0x02, 0x00, 0x00, 0x01, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x16, 0x01, 0x12}
	copy(large[:], large_head[:])
	// 10 + 4 + 276 + 2 = 292 bytes: a private area of 276 bytes with its
	// size field, and an empty public area; the answer ends there.
	_, _, problem = create_answer(large[:292])
	testing.expect_value(t, problem, Answer_Problem.Malformed)

	// The unseal: 32 bytes of secret.
	unseal_bytes: [53]u8
	unseal_head := [?]u8{0x80, 0x02, 0x00, 0x00, 0x00, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x22, 0x00, 0x20}
	copy(unseal_bytes[:], unseal_head[:])
	for index in 0 ..< 32 {
		unseal_bytes[16 + index] = u8(0x40 + index)
	}
	unseal_bytes[48 + 2] = 0x01
	secret, _, unseal_problem := unseal_answer(unseal_bytes[:])
	testing.expect_value(t, unseal_problem, Answer_Problem.None)
	testing.expect_value(t, len(secret), SECRET_SIZE)
	testing.expect_value(t, secret[0], u8(0x40))
	// A secret of 31 bytes is refused.
	unseal_bytes[15] = 0x1F
	_, _, unseal_problem = unseal_answer(unseal_bytes[:])
	testing.expect_value(t, unseal_problem, Answer_Problem.Malformed)

	// An area of the record: its size field must count its bytes.
	good := [?]u8{0x00, 0x02, 1, 2}
	testing.expect(t, area_fits(good[:], PUBLIC_AREA_LIMIT))
	testing.expect(t, !area_fits(good[:3], PUBLIC_AREA_LIMIT))
	testing.expect(t, !area_fits(good[:1], PUBLIC_AREA_LIMIT))
	testing.expect(t, !area_fits(good[:], 3))
}

// The seal of the keys of a named principal: the authorization value in the
// sensitive part, noDA clear; the unseal sends the value as the password of
// the policy session.
@(test)
the_seal_with_an_authorization_value_has_its_bytes :: proc(t: ^testing.T) {
	buffer: [512]u8
	secret, policy: [SECRET_SIZE]u8
	authorization: [AUTHORIZATION_VALUE_SIZE]u8
	for index in 0 ..< SECRET_SIZE {
		secret[index] = u8(index + 1)
		policy[index] = u8(0xA0 + index)
		authorization[index] = u8(0x61 + index % 26)
	}
	without_count := create_sealed_command(buffer[:], 0x8000_0000, &secret, &policy, nil)
	count := create_sealed_command(buffer[:], 0x8000_0000, &secret, &policy, authorization[:])
	testing.expect_value(t, count, without_count + AUTHORIZATION_VALUE_SIZE)
	// After the header, the storage key and its password session: the size
	// of the sensitive part, then the authorization value with its size.
	SENSITIVE_PLACE :: 10 + 4 + 13
	sensitive_size := 2 + AUTHORIZATION_VALUE_SIZE + 2 + SECRET_SIZE
	testing.expect_value(t, int(buffer[SENSITIVE_PLACE]) << 8 | int(buffer[SENSITIVE_PLACE + 1]), sensitive_size)
	testing.expect_value(t, int(buffer[SENSITIVE_PLACE + 3]), AUTHORIZATION_VALUE_SIZE)
	testing.expect(t, string(buffer[SENSITIVE_PLACE + 4:][:AUTHORIZATION_VALUE_SIZE]) == string(authorization[:]))
	testing.expect(t, string(buffer[SENSITIVE_PLACE + 4 + AUTHORIZATION_VALUE_SIZE + 2:][:SECRET_SIZE]) == string(secret[:]))
	// The attributes, after the size of the public part, its kind and its
	// hash: noDA clear.
	attributes_place := SENSITIVE_PLACE + 2 + sensitive_size + 2 + 2 + 2
	attributes := u32(buffer[attributes_place]) << 24 | u32(buffer[attributes_place + 1]) << 16 | u32(buffer[attributes_place + 2]) << 8 | u32(buffer[attributes_place + 3])
	testing.expect_value(t, attributes, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES)
	testing.expect(t, attributes & ATTRIBUTE_NO_DICTIONARY_ATTACK == 0)
	testing.expect_value(t, sealed_object_attributes(false), SEALED_OBJECT_ATTRIBUTES)
	// A value longer than the digest of the name of the object gives no
	// command.
	too_long: [AUTHORIZATION_VALUE_SIZE + 1]u8
	testing.expect_value(t, create_sealed_command(buffer[:], 0x8000_0000, &secret, &policy, too_long[:]), 0)

	empty_count := unseal_command(buffer[:], 0x8000_0001, 0x0300_0000, nil)
	count = unseal_command(buffer[:], 0x8000_0001, 0x0300_0000, authorization[:])
	testing.expect_value(t, count, empty_count + AUTHORIZATION_VALUE_SIZE)
	expected_head := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, u8(count), 0x00, 0x00, 0x01, 0x5E,
		0x80, 0x00, 0x00, 0x01, // The sealed object.
		0x00, 0x00, 0x00, u8(9 + AUTHORIZATION_VALUE_SIZE), 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, SESSION_CONTINUE, 0x00, u8(AUTHORIZATION_VALUE_SIZE), // The policy session: no nonce, continue, the value as the password.
	}
	testing.expect(t, string(buffer[:len(expected_head)]) == string(expected_head[:]))
	testing.expect(t, string(buffer[len(expected_head):count]) == string(authorization[:]))
	testing.expect_value(t, unseal_command(buffer[:], 0x8000_0001, 0x0300_0000, too_long[:]), 0)

	count = policy_password_command(buffer[:], 0x0300_0000)
	expected_password := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x01, 0x8C, 0x03, 0x00, 0x00, 0x00}
	testing.expect_value(t, count, len(expected_password))
	testing.expect(t, string(buffer[:count]) == string(expected_password[:]))
	count = shutdown_command(buffer[:])
	expected_shutdown := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x01, 0x45, 0x00, 0x00}
	testing.expect_value(t, count, len(expected_shutdown))
	testing.expect(t, string(buffer[:count]) == string(expected_shutdown[:]))
}

// The policy with TPM2_PolicyPassword, from the digest of sha256sum: the
// policy of PCR 7 and PCR 11 whose digest is 32 bytes of 0x11, then the
// code of TPM2_PolicyAuthValue.
@(test)
the_policy_with_the_password_has_its_digest :: proc(t: ^testing.T) {
	pcr_digest: [DIGEST_SIZE]u8
	for &item in pcr_digest {
		item = 0x11
	}
	policy := sealed_object_policy(&pcr_digest, true)
	expected := [DIGEST_SIZE]u8{0x69, 0x03, 0xef, 0xb5, 0x9a, 0x7e, 0x86, 0x94, 0x6e, 0xb6, 0xae, 0x93, 0x71, 0x49, 0xe3, 0xf3, 0xcf, 0xd3, 0x3c, 0x57, 0xed, 0x80, 0x60, 0xb1, 0x58, 0x6d, 0x6d, 0x96, 0xf3, 0xf0, 0x5d, 0x8a}
	testing.expect(t, policy == expected)
	testing.expect(t, sealed_object_policy(&pcr_digest, false) == policy_pcr_digest(&pcr_digest))
}

// An object of a named principal passes only with its own attributes and
// its own policy: an object with noDA set, whose wrong values the TPM would
// not count, or an object with the policy of the PCRs only, which opens
// with no passphrase, is refused.
@(test)
an_object_with_an_authorization_value_is_checked :: proc(t: ^testing.T) {
	this_system: [DIGEST_SIZE]u8
	for index in 0 ..< DIGEST_SIZE {
		this_system[index] = u8(index)
	}
	authorized_policy := sealed_object_policy(&this_system, true)
	pcr_policy := sealed_object_policy(&this_system, false)
	public_buffer: [PUBLIC_AREA_LIMIT]u8
	testing.expect(t, sealed_public_check(public_write(public_buffer[:], authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES), &authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES))
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES | ATTRIBUTE_NO_DICTIONARY_ATTACK), &authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES))
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], pcr_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES), &authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES))
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES | ATTRIBUTE_USER_WITH_AUTH), &authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES))
	// The object of the machine key is no object of a named principal.
	testing.expect(t, !sealed_public_check(public_write(public_buffer[:], pcr_policy, SEALED_OBJECT_ATTRIBUTES), &authorized_policy, AUTHORIZED_SEALED_OBJECT_ATTRIBUTES))
}

// The response codes of an authorization value: a wrong value that the TPM
// counted, one that it did not count, the lockout, and a retry.
@(test)
the_codes_of_an_authorization_value_are_named :: proc(t: ^testing.T) {
	SESSION_ONE :: u32(0x900) // The bits of session 1 in a format 1 code.
	RESPONSE_BAD_AUTHORIZATION :: u32(0x022) // TPM_RC_BAD_AUTH: a failure that the TPM does not count.
	counted := RESPONSE_FORMAT_ONE | RESPONSE_AUTHORIZATION_FAIL | SESSION_ONE
	testing.expect_value(t, counted, u32(0x98E))
	testing.expect(t, authorization_fails(counted))
	testing.expect(t, !authorization_fails(RESPONSE_FORMAT_ONE | RESPONSE_BAD_AUTHORIZATION | SESSION_ONE))
	testing.expect(t, !authorization_fails(RESPONSE_FORMAT_ONE | RESPONSE_POLICY_FAIL | SESSION_ONE))
	testing.expect(t, !policy_fails(counted))
	testing.expect(t, locked_out(RESPONSE_LOCKOUT))
	testing.expect(t, !locked_out(RESPONSE_RETRY))
	testing.expect(t, retry_asked(RESPONSE_RETRY))
	testing.expect(t, !retry_asked(counted))
	// The format 0 codes are no format 1 failure.
	testing.expect(t, !authorization_fails(RESPONSE_LOCKOUT))
}

// The commands of the lockout hierarchy: the read of the properties, the
// change of the lockout authorization value with the empty one, and the
// reset of the count that only the tool sends.
@(test)
the_commands_of_the_lockout_hierarchy_have_their_bytes :: proc(t: ^testing.T) {
	buffer: [256]u8
	count := properties_command(buffer[:], PROPERTY_LOCKOUT_COUNTER, u32(COUNT_LIMIT_PROPERTIES))
	expected_properties := [?]u8 {
		0x80, 0x01, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x01, 0x7A, // The header: 22 bytes, TPM2_GetCapability.
		0x00, 0x00, 0x00, 0x06, // TPM_CAP_TPM_PROPERTIES.
		0x00, 0x00, 0x02, 0x0E, // From TPM_PT_LOCKOUT_COUNTER,
		0x00, 0x00, 0x00, 0x04, // four properties.
	}
	testing.expect_value(t, count, len(expected_properties))
	testing.expect(t, string(buffer[:count]) == string(expected_properties[:]))
	count = properties_command(buffer[:], PROPERTY_PERMANENT, 1)
	testing.expect_value(t, count, len(expected_properties))
	testing.expect_value(t, buffer[16], u8(0x02)) // TPM_PT_PERMANENT, 0x200, after the header and the capability.
	testing.expect_value(t, buffer[17], u8(0x00))
	testing.expect_value(t, buffer[21], u8(0x01))
	testing.expect_value(t, properties_command(buffer[:len(expected_properties) - 1], PROPERTY_PERMANENT, 1), 0)

	value: [AUTHORIZATION_VALUE_SIZE]u8
	for index in 0 ..< AUTHORIZATION_VALUE_SIZE {
		value[index] = u8(0xC0 + index)
	}
	count = lockout_authorization_change_command(buffer[:], value[:])
	expected_change_head := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x3D, 0x00, 0x00, 0x01, 0x29, // The header: 61 bytes, TPM2_HierarchyChangeAuth.
		0x40, 0x00, 0x00, 0x0A, // The lockout hierarchy.
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, // The empty password: the value of now.
		0x00, 0x20, // The new value: 32 bytes.
	}
	testing.expect_value(t, count, len(expected_change_head) + AUTHORIZATION_VALUE_SIZE)
	testing.expect(t, string(buffer[:len(expected_change_head)]) == string(expected_change_head[:]))
	testing.expect(t, string(buffer[len(expected_change_head):count]) == string(value[:]))
	// An empty value changes nothing, and a value longer than the digest of
	// the hash of the TPM is refused by it: neither gives a command.
	too_long: [AUTHORIZATION_VALUE_SIZE + 1]u8
	testing.expect_value(t, lockout_authorization_change_command(buffer[:], nil), 0)
	testing.expect_value(t, lockout_authorization_change_command(buffer[:], too_long[:]), 0)
	testing.expect_value(t, lockout_authorization_change_command(buffer[:len(expected_change_head)], value[:]), 0)

	count = dictionary_attack_lock_reset_command(buffer[:])
	expected_reset := [?]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x1B, 0x00, 0x00, 0x01, 0x39, // The header: 27 bytes, TPM2_DictionaryAttackLockReset.
		0x40, 0x00, 0x00, 0x0A, // The lockout hierarchy.
		0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, // The empty password.
	}
	testing.expect_value(t, count, len(expected_reset))
	testing.expect(t, string(buffer[:count]) == string(expected_reset[:]))
}

// properties_answer_write writes an answer of TPM2_GetCapability of the
// properties: the bit moreData, the capability, and the pairs given, each
// a property and its value.
@(private = "file")
properties_answer_write :: proc(buffer: []u8, capability: u32, pairs: [][2]u32) -> []u8 {
	writer := begin(buffer, TAG_NO_SESSIONS, RESPONSE_SUCCESS)
	put_u8(&writer, 0)
	put_u32(&writer, capability)
	put_u32(&writer, u32(len(pairs)))
	for pair in pairs {
		put_u32(&writer, pair[0])
		put_u32(&writer, pair[1])
	}
	return buffer[:end(&writer)]
}

// The answer of the count limits, as libtpms gives it with no setup: no
// failure counted, a lockout after 3, one forgiven each 1000 seconds; and
// each hostile form of it refused with no value given.
@(test)
the_answer_of_the_properties_is_read_and_checked :: proc(t: ^testing.T) {
	buffer: [256]u8
	limits := [?][2]u32 {
		{PROPERTY_LOCKOUT_COUNTER, 0},
		{PROPERTY_MAXIMUM_AUTHORIZATION_FAILURES, 3},
		{PROPERTY_LOCKOUT_INTERVAL, 1000},
		{PROPERTY_LOCKOUT_RECOVERY, 1000},
	}
	answer := properties_answer_write(buffer[:], CAPABILITY_TPM_PROPERTIES, limits[:])
	testing.expect_value(t, len(answer), 10 + 1 + 4 + 4 + COUNT_LIMIT_PROPERTIES * 8)
	values: [COUNT_LIMIT_PROPERTIES]u32
	code, problem := properties_answer(answer, PROPERTY_LOCKOUT_COUNTER, values[:])
	testing.expect_value(t, problem, Answer_Problem.None)
	testing.expect_value(t, code, RESPONSE_SUCCESS)
	testing.expect_value(t, values[PROPERTY_MAXIMUM_AUTHORIZATION_FAILURES - PROPERTY_LOCKOUT_COUNTER], u32(3))
	testing.expect_value(t, values[PROPERTY_LOCKOUT_INTERVAL - PROPERTY_LOCKOUT_COUNTER], u32(1000))
	testing.expect_value(t, values[PROPERTY_LOCKOUT_RECOVERY - PROPERTY_LOCKOUT_COUNTER], u32(1000))

	// The bit lockoutAuthSet, alone and among other bits.
	permanent_buffer: [64]u8
	permanent_pairs := [1][2]u32{{PROPERTY_PERMANENT, PERMANENT_LOCKOUT_AUTHORIZATION_SET | 1 << 0 | 1 << 10}}
	permanent: [1]u32
	_, problem = properties_answer(properties_answer_write(permanent_buffer[:], CAPABILITY_TPM_PROPERTIES, permanent_pairs[:]), PROPERTY_PERMANENT, permanent[:])
	testing.expect_value(t, problem, Answer_Problem.None)
	testing.expect(t, lockout_authorization_set(permanent[0]))
	testing.expect(t, !lockout_authorization_set(1 << 0 | 1 << 1 | 1 << 9 | 1 << 10)) // The other bits: the owner, the endorsement, inLockout, tpmGeneratedEPS.

	// expect_refused checks that an answer is refused and gives no value.
	expect_refused :: proc(t: ^testing.T, refused_answer: []u8, wanted: Answer_Problem) {
		refused_values: [COUNT_LIMIT_PROPERTIES]u32
		for &item in refused_values {
			item = 0xFFFF_FFFF
		}
		_, refused_problem := properties_answer(refused_answer, PROPERTY_LOCKOUT_COUNTER, refused_values[:])
		testing.expect_value(t, refused_problem, wanted)
		testing.expect(t, refused_values == [COUNT_LIMIT_PROPERTIES]u32{})
	}
	other_buffer: [256]u8
	// A property missing: the TPM gives three of the four.
	expect_refused(t, properties_answer_write(other_buffer[:], CAPABILITY_TPM_PROPERTIES, limits[:3]), .Malformed)
	// One property more than asked.
	more := [?][2]u32{limits[0], limits[1], limits[2], limits[3], {PROPERTY_LOCKOUT_RECOVERY + 1, 0}}
	expect_refused(t, properties_answer_write(other_buffer[:], CAPABILITY_TPM_PROPERTIES, more[:]), .Malformed)
	// Two properties in the wrong order, and one property twice.
	swapped := [?][2]u32{limits[0], limits[2], limits[1], limits[3]}
	expect_refused(t, properties_answer_write(other_buffer[:], CAPABILITY_TPM_PROPERTIES, swapped[:]), .Malformed)
	twice := [?][2]u32{limits[0], limits[1], limits[1], limits[3]}
	expect_refused(t, properties_answer_write(other_buffer[:], CAPABILITY_TPM_PROPERTIES, twice[:]), .Malformed)
	// Another capability.
	expect_refused(t, properties_answer_write(other_buffer[:], CAPABILITY_TPM_PROPERTIES + 1, limits[:]), .Malformed)
	// A count of the list far past the bytes that came, then the same
	// count as asked with the answer cut before the last value.
	huge := buffer
	huge[15], huge[16], huge[17], huge[18] = 0xFF, 0xFF, 0xFF, 0xFF
	expect_refused(t, huge[:len(answer)], .Malformed)
	cut := buffer
	cut[5] -= 4
	expect_refused(t, cut[:len(answer) - 4], .Malformed)
	// A byte after the list, counted in the size of the header.
	longer := buffer
	longer[5] += 1
	expect_refused(t, longer[:len(answer) + 1], .Malformed)
	// A bit moreData that is neither 0 nor 1.
	more_data := buffer
	more_data[10] = 2
	expect_refused(t, more_data[:len(answer)], .Malformed)
	// The tag of an answer with sessions: a command with none never has it.
	with_sessions := buffer
	with_sessions[1] = 0x02
	expect_refused(t, with_sessions[:len(answer)], .Malformed)
	// A refusal of the TPM gives its code.
	refusal := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x01, 0xC4}
	expect_refused(t, refusal[:], .Refused)
	_, code, _ = answer_begin(refusal[:])
	testing.expect_value(t, code, u32(0x1C4))
	expect_refused(t, nil, .Malformed)
}

// The answers to the lockout hierarchy: a TPM with a lockout value refuses
// the empty one, and counts it (TPM_RC_AUTH_FAIL of session 1); a lockout
// hierarchy that waits after such a failure answers TPM_RC_LOCKOUT.
@(test)
the_refusals_of_the_lockout_hierarchy_are_named :: proc(t: ^testing.T) {
	refused := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x09, 0x8E}
	code, problem := status_answer(refused[:])
	testing.expect_value(t, problem, Answer_Problem.Refused)
	testing.expect(t, authorization_fails(code))
	waits := [?]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x09, 0x21}
	code, problem = status_answer(waits[:])
	testing.expect_value(t, problem, Answer_Problem.Refused)
	testing.expect(t, locked_out(code))
	// The answer of a change that the TPM took: no parameter, and the area
	// of the session of the password.
	taken := [?]u8{0x80, 0x02, 0x00, 0x00, 0x00, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00}
	code, problem = status_answer(taken[:])
	testing.expect_value(t, problem, Answer_Problem.None)
	testing.expect_value(t, code, RESPONSE_SUCCESS)
}
