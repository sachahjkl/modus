// TPM 2.0 wire encoders, decoders, and policy digests for update-surviving
// seals (src/md/features/tpm_sealed_machine_key.md, "The seal across an update").
//
// An update-surviving seal binds a secret to a publisher ECDSA P-256 key via
// TPM2_PolicyAuthorize instead of exact PCR values, paired with TPM2_PolicyNV
// on the TPM version floor so older signed systems below the floor fail.
// Before setting the owner hierarchy authorization value, the storage primary
// key is made persistent via TPM2_EvictControl so unseal runs before the owner
// authorization value is known.
package tpm2

import "modus:contract/byte_order"
import "modus:contract/tpm_attestation"

// Format property: TPM 2.0 command codes for persistent handles, external
// signature verification, NV floor policies, and authorized policies.
COMMAND_EVICT_CONTROL :: u32(0x0000_0120)
COMMAND_POLICY_NV :: u32(0x0000_0149)
COMMAND_LOAD_EXTERNAL :: u32(0x0000_0167)
COMMAND_POLICY_AUTHORIZE :: tpm_attestation.COMMAND_POLICY_AUTHORIZE
COMMAND_READ_PUBLIC :: u32(0x0000_0173)
COMMAND_VERIFY_SIGNATURE :: u32(0x0000_0177)

// Format property: ECDSA signature scheme and verified ticket tag (TPM 2.0 Part 2).
ALGORITHM_ECDSA :: u16(0x0018)
TAG_VERIFIED :: tpm_attestation.TPM_ST_VERIFIED
ATTRIBUTE_SIGN_ENCRYPT :: u32(1 << 18)

// Format property: TPM_EO_BITSET verifies that all bits set in operandB are
// also set in the NV index bitfield (TPM 2.0 Part 2, TPM_EO).
OPERATION_BITSET :: u16(0x000B)

// Format property: bit ownerAuthSet of TPMA_PERMANENT.
PERMANENT_OWNER_AUTHORIZATION_SET :: u32(1 << 0)

// Format property: owner-hierarchy persistent handle for the primary ECC P-256
// storage key, allowing TPM2_Load and TPM2_Create without owner authorization
// once the owner hierarchy authorization value is set.
PERSISTENT_STORAGE_KEY_HANDLE :: u32(0x8100_0001)

// Format property: raw coordinate and signature component size of NIST P-256.
ECDSA_P256_COORD_SIZE :: 32

// Format property: attributes of an externally loaded publisher ECDSA P-256
// verification key (sign only, no decryption, no fixedTPM since external).
PUBLISHER_KEY_ATTRIBUTES :: ATTRIBUTE_SIGN_ENCRYPT | ATTRIBUTE_NO_DICTIONARY_ATTACK

// owner_authorization_set reports whether TPMA_PERMANENT indicates a non-empty
// owner hierarchy authorization value.
owner_authorization_set :: proc "contextless" (permanent: u32) -> bool {
	return permanent & PERMANENT_OWNER_AUTHORIZATION_SET != 0
}

// is_all_zero_bytes reports whether every byte in slice is zero.
@(private = "file")
is_all_zero_bytes :: proc "contextless" (bytes: []u8) -> bool {
	acc: u8
	for b in bytes {
		acc |= b
	}
	return acc == 0
}

// put_password_session_with_auth writes one TPM_RS_PW authorization session
// carrying auth_value (empty for default owner auth).
@(private = "file")
put_password_session_with_auth :: proc "contextless" (command_writer: ^Command_Writer, auth_value: []u8) {
	put_u32(command_writer, u32(9 + len(auth_value)))
	put_u32(command_writer, HANDLE_PASSWORD)
	put_u16(command_writer, 0) // No nonce.
	put_u8(command_writer, 0) // No attributes.
	put_sized(command_writer, auth_value)
}

// read_public_command builds TPM2_ReadPublic for handle (used to probe whether
// PERSISTENT_STORAGE_KEY_HANDLE is already persisted in the TPM).
read_public_command :: proc "contextless" (buffer: []u8, handle: u32) -> int {
	if handle == 0 {
		return 0
	}
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_READ_PUBLIC)
	put_u32(&command_writer, handle)
	return end(&command_writer)
}

// evict_control_command builds TPM2_EvictControl under the owner hierarchy to
// persist transient_object at persistent_handle (or evict it if already there).
// Refuses handles outside the persistent handle range 0x81000000..0x817FFFFF
// or authorization values longer than AUTHORIZATION_VALUE_SIZE.
evict_control_command :: proc "contextless" (
	buffer: []u8,
	owner_auth: []u8,
	object_handle: u32,
	persistent_handle: u32,
) -> int {
	if len(owner_auth) > AUTHORIZATION_VALUE_SIZE || object_handle == 0 {
		return 0
	}
	if persistent_handle < 0x8100_0000 || persistent_handle > 0x817F_FFFF {
		return 0
	}
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_EVICT_CONTROL)
	put_u32(&command_writer, HANDLE_OWNER)
	put_u32(&command_writer, object_handle)
	put_password_session_with_auth(&command_writer, owner_auth)
	put_u32(&command_writer, persistent_handle)
	return end(&command_writer)
}

// owner_authorization_change_command builds TPM2_HierarchyChangeAuth for the
// owner hierarchy, refusing empty, all-zero, or oversized authorization values.
owner_authorization_change_command :: proc "contextless" (
	buffer: []u8,
	current_auth: []u8,
	new_auth: []u8,
) -> int {
	written, refusal := tpm_attestation.encode_hierarchy_change_auth(.Owner, current_auth, new_auth, buffer)
	if refusal != .None {
		return 0
	}
	return written
}

// write_ecdsa_p256_public_body writes the canonical TPMT_PUBLIC bytes for an
// external ECDSA P-256 SHA-256 verification key with coordinates (pub_x, pub_y).
@(private = "file")
write_ecdsa_p256_public_body :: proc "contextless" (
	command_writer: ^Command_Writer,
	pub_x: ^[ECDSA_P256_COORD_SIZE]u8,
	pub_y: ^[ECDSA_P256_COORD_SIZE]u8,
) {
	put_u16(command_writer, ALGORITHM_ECC)
	put_u16(command_writer, ALGORITHM_SHA256)
	put_u32(command_writer, PUBLISHER_KEY_ATTRIBUTES)
	put_u16(command_writer, 0) // Empty authPolicy.
	put_u16(command_writer, ALGORITHM_NULL) // No symmetric cipher.
	put_u16(command_writer, ALGORITHM_ECDSA)
	put_u16(command_writer, ALGORITHM_SHA256)
	put_u16(command_writer, CURVE_NIST_P256)
	put_u16(command_writer, ALGORITHM_NULL) // No KDF.
	put_sized(command_writer, pub_x^[:])
	put_sized(command_writer, pub_y^[:])
}

// ecdsa_p256_key_name computes the canonical TPM 2.0 Name of an externally
// loaded ECDSA P-256 publisher verification key: be16(TPM_ALG_SHA256) ||
// SHA-256(TPMT_PUBLIC). Returns ok false when either coordinate is all zero.
ecdsa_p256_key_name :: proc "contextless" (
	pub_x: ^[ECDSA_P256_COORD_SIZE]u8,
	pub_y: ^[ECDSA_P256_COORD_SIZE]u8,
) -> (name: [tpm_attestation.KEY_NAME_SIZE]u8, ok: bool) {
	if pub_x == nil || pub_y == nil || is_all_zero_bytes(pub_x^[:]) || is_all_zero_bytes(pub_y^[:]) {
		return {}, false
	}
	// Format property: TPMT_PUBLIC of ECDSA P-256 is 2+2+4+2+2+2+2+2+2+(2+32)+(2+32) = 88 bytes.
	public_body: [96]u8
	writer := Command_Writer{buffer = public_body[:]}
	write_ecdsa_p256_public_body(&writer, pub_x, pub_y)
	if writer.overflowed {
		return {}, false
	}
	digest := sha256_of(public_body[:writer.count])
	byte_order.write_u16_big_endian(name[:], 0, ALGORITHM_SHA256)
	copy(name[2:], digest[:])
	return name, true
}

// load_external_ecdsa_p256_command builds TPM2_LoadExternal loading only the
// public part of a publisher ECDSA P-256 verification key into HANDLE_OWNER so
// TPM2_VerifySignature produces a verified ticket usable by TPM2_PolicyAuthorize.
load_external_ecdsa_p256_command :: proc "contextless" (
	buffer: []u8,
	pub_x: ^[ECDSA_P256_COORD_SIZE]u8,
	pub_y: ^[ECDSA_P256_COORD_SIZE]u8,
) -> int {
	if pub_x == nil || pub_y == nil || is_all_zero_bytes(pub_x^[:]) || is_all_zero_bytes(pub_y^[:]) {
		return 0
	}
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_LOAD_EXTERNAL)
	put_u16(&command_writer, 0) // Empty private sensitive part (public-only load).
	size_place := command_writer.count
	put_u16(&command_writer, 0)
	write_ecdsa_p256_public_body(&command_writer, pub_x, pub_y)
	set_u16_at(&command_writer, size_place, u16(command_writer.count - size_place - 2))
	put_u32(&command_writer, HANDLE_OWNER)
	return end(&command_writer)
}

// verify_signature_command builds TPM2_VerifySignature checking an ECDSA P-256
// SHA-256 signature (sig_r, sig_s) over digest under loaded key_handle.
verify_signature_command :: proc "contextless" (
	buffer: []u8,
	key_handle: u32,
	digest: ^[DIGEST_SIZE]u8,
	sig_r: ^[ECDSA_P256_COORD_SIZE]u8,
	sig_s: ^[ECDSA_P256_COORD_SIZE]u8,
) -> int {
	if key_handle == 0 || digest == nil || sig_r == nil || sig_s == nil {
		return 0
	}
	if is_all_zero_bytes(digest^[:]) || is_all_zero_bytes(sig_r^[:]) || is_all_zero_bytes(sig_s^[:]) {
		return 0
	}
	command_writer := begin(buffer, TAG_NO_SESSIONS, COMMAND_VERIFY_SIGNATURE)
	put_u32(&command_writer, key_handle)
	put_sized(&command_writer, digest^[:])
	put_u16(&command_writer, ALGORITHM_ECDSA)
	put_u16(&command_writer, ALGORITHM_SHA256)
	put_sized(&command_writer, sig_r^[:])
	put_sized(&command_writer, sig_s^[:])
	return end(&command_writer)
}

// verify_signature_answer decodes the TPMT_TK_VERIFIED ticket returned by
// TPM2_VerifySignature, verifying TAG_NO_SESSIONS and accepting any TPM HMAC
// digest length up to TICKET_DIGEST_LIMIT (including 64-byte SHA-512 swtpm
// tickets) while refusing the null hierarchy, zero digests, or trailing bytes.
verify_signature_answer :: proc "contextless" (
	answer: []u8,
) -> (ticket: tpm_attestation.Verified_Ticket, code: u32, problem: Answer_Problem) {
	reader: Answer_Reader
	reader, code, problem = answer_begin(answer)
	if problem != .None {
		return {}, code, problem
	}
	if byte_order.read_u16_big_endian(answer, 0) != TAG_NO_SESSIONS {
		return {}, code, .Malformed
	}
	tag := take_u16(&reader)
	hierarchy_word := take_u32(&reader)
	_, digest := take_sized(&reader)
	if reader.failed || reader.place != len(reader.bytes) || tag != TAG_VERIFIED || len(digest) == 0 || len(digest) > TICKET_DIGEST_LIMIT {
		return {}, code, .Malformed
	}
	hierarchy, hierarchy_ok := tpm_attestation.ticket_hierarchy_of_word(u64(hierarchy_word))
	if !hierarchy_ok || is_all_zero_bytes(digest) {
		return {}, code, .Malformed
	}
	ticket.hierarchy = hierarchy
	ticket.digest_len = u16(len(digest))
	copy(ticket.digest[:len(digest)], digest)
	return ticket, code, .None
}

// policy_nv_floor_command builds TPM2_PolicyNV checking that the 64-bit
// big-endian bitfield in nv_index has all bits in floor_bits set (TPM_EO_BITSET),
// reading the index with its empty password (NV_AUTHORIZATION_READ).
policy_nv_floor_command :: proc "contextless" (
	buffer: []u8,
	session: u32,
	nv_index: u32,
	floor_bits: u64,
) -> int {
	if session >> 24 != tpm_attestation.HANDLE_KIND_POLICY_SESSION || nv_index >> 24 != 0x01 || floor_bits == 0 {
		return 0
	}
	operand: [8]u8
	byte_order.write_u64_big_endian(operand[:], 0, floor_bits)
	command_writer := begin(buffer, TAG_SESSIONS, COMMAND_POLICY_NV)
	put_u32(&command_writer, nv_index) // authHandle: the NV index itself (empty authRead).
	put_u32(&command_writer, nv_index) // nvIndex.
	put_u32(&command_writer, session) // policySession.
	put_password_session(&command_writer)
	put_sized(&command_writer, operand[:])
	put_u16(&command_writer, 0) // offset 0 in the 8-byte bitfield.
	put_u16(&command_writer, OPERATION_BITSET)
	return end(&command_writer)
}

// policy_authorize_command builds TPM2_PolicyAuthorize for session, binding
// approved_policy and policy_ref under publisher key_sign_name and ticket.
policy_authorize_command :: proc "contextless" (
	buffer: []u8,
	session: u32,
	approved_policy: [DIGEST_SIZE]u8,
	policy_ref: []u8,
	key_sign_name: []u8,
	ticket: tpm_attestation.Verified_Ticket,
) -> int {
	written, refusal := tpm_attestation.encode_policy_authorize(session, approved_policy, policy_ref, key_sign_name, ticket, buffer)
	if refusal != .None {
		return 0
	}
	return written
}

// policy_authorize_approval_digest computes the digest signed by the publisher
// ECDSA P-256 key for TPM2_PolicyAuthorize: SHA-256(approved_policy || policy_ref)
// (TPM 2.0 Part 3, TPM2_PolicyAuthorize).
policy_authorize_approval_digest :: proc "contextless" (
	approved_policy: ^[DIGEST_SIZE]u8,
	policy_ref: []u8,
) -> [DIGEST_SIZE]u8 {
	return sha256_of(approved_policy^[:], policy_ref)
}

// policy_nv_extend_digest computes the TPM 2.0 policy digest after extending
// current_policy with TPM2_PolicyNV(nv_index_name, floor_bits, offset=0, BITSET):
//   argsHash = SHA-256(be64(floor_bits) || be16(0) || be16(TPM_EO_BITSET))
//   out      = SHA-256(current_policy || be32(TPM_CC_PolicyNV) || argsHash || nv_index_name)
policy_nv_extend_digest :: proc "contextless" (
	current_policy: ^[DIGEST_SIZE]u8,
	nv_index_name: []u8,
	floor_bits: u64,
) -> [DIGEST_SIZE]u8 {
	args_bytes: [12]u8
	byte_order.write_u64_big_endian(args_bytes[:], 0, floor_bits)
	byte_order.write_u16_big_endian(args_bytes[:], 8, 0)
	byte_order.write_u16_big_endian(args_bytes[:], 10, OPERATION_BITSET)
	args_hash := sha256_of(args_bytes[:])
	code: [4]u8
	byte_order.write_u32_big_endian(code[:], 0, COMMAND_POLICY_NV)
	return sha256_of(current_policy^[:], code[:], args_hash[:], nv_index_name)
}

// approved_update_branch_policy computes the approved policy branch for one
// signed system release: TPM2_PolicyPCR(PCR 7, PCR 11) followed by
// TPM2_PolicyNV(BITSET) on the version floor index.
approved_update_branch_policy :: proc "contextless" (
	pcr_digest: ^[DIGEST_SIZE]u8,
	version_floor_nv_name: []u8,
	floor_bits: u64,
) -> [DIGEST_SIZE]u8 {
	pcr_policy := policy_pcr_digest(pcr_digest)
	return policy_nv_extend_digest(&pcr_policy, version_floor_nv_name, floor_bits)
}

// authorized_sealed_object_policy computes the root policy digest of an
// update-surviving sealed object: TPM2_PolicyAuthorize(publisher_key_name,
// policy_ref), followed by TPM2_PolicyPassword when authorized is true.
authorized_sealed_object_policy :: proc "contextless" (
	publisher_key_name: []u8,
	policy_ref: []u8,
	authorized: bool,
) -> (policy: [DIGEST_SIZE]u8, ok: bool) {
	if len(publisher_key_name) != tpm_attestation.KEY_NAME_SIZE ||
	   byte_order.read_u16_big_endian(publisher_key_name, 0) != ALGORITHM_SHA256 ||
	   is_all_zero_bytes(publisher_key_name[2:]) ||
	   len(policy_ref) > tpm_attestation.POLICY_REFERENCE_LIMIT {
		return {}, false
	}
	zeros: [DIGEST_SIZE]u8
	code: [4]u8
	byte_order.write_u32_big_endian(code[:], 0, COMMAND_POLICY_AUTHORIZE)
	step1 := sha256_of(zeros[:], code[:], publisher_key_name)
	policy = sha256_of(step1[:], policy_ref)
	if authorized {
		policy = policy_with_password_digest(&policy)
	}
	return policy, true
}

// update_seal_public_check verifies that public_area is a sealed keyed-hash
// object whose attributes match sealed_object_attributes(authorized) and whose
// authPolicy equals authorized_sealed_object_policy(publisher_key_name,
// policy_ref, authorized).
update_seal_public_check :: proc "contextless" (
	public_area: []u8,
	publisher_key_name: []u8,
	policy_ref: []u8,
	authorized: bool,
) -> bool {
	policy, policy_ok := authorized_sealed_object_policy(publisher_key_name, policy_ref, authorized)
	if !policy_ok {
		return false
	}
	return sealed_public_check(public_area, &policy, sealed_object_attributes(authorized))
}
