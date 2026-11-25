// Remote TPM attestation quote payload encoding and verification contract
// (src/md/features/attestation.md).
//
// An attestation payload binds the signed boot description hash, the composite
// TPM PCR digest, the active plan hash of principal 0, the canonical
// role-holder measurement digest, and a fresh 32-byte verifier nonce into a
// fixed-size little-endian wire record signed by an attestation key.
package attestation

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: domain separation prefix prepended to the signed payload bytes.
ATTESTATION_DOMAIN :: "modus tpm attestation v1"

// Format property: 8-byte wire magic identifying an attestation payload record.
ATTESTATION_MAGIC :: [8]u8{'M', 'O', 'D', 'A', 'T', 'T', '0', '1'}

// Format property: canonical wire format version.
ATTESTATION_VERSION :: u32(1)

// Format property: byte length of the fresh verifier challenge nonce.
ATTESTATION_NONCE_SIZE :: 32

// Format property: byte length of an Ed25519 attestation public key.
ATTESTATION_PUBLIC_KEY_SIZE :: 32

// Format property: byte length of an Ed25519 attestation signature.
ATTESTATION_SIGNATURE_SIZE :: 64

// Format property: unsigned wire prefix length (magic + version + reserved + 6 x 32-byte fields).
ATTESTATION_UNSIGNED_WIRE_SIZE :: 8 + 4 + 4 + blake3.HASH_SIZE * 4 + ATTESTATION_NONCE_SIZE + ATTESTATION_PUBLIC_KEY_SIZE

// Format property: exact encoded byte length of one Attestation_Payload record.
ATTESTATION_PAYLOAD_WIRE_SIZE :: ATTESTATION_UNSIGNED_WIRE_SIZE + ATTESTATION_SIGNATURE_SIZE

// Format property: exact byte length of the domain-separated message signed by the attestation key.
ATTESTATION_SIGNING_BYTES_SIZE :: len(ATTESTATION_DOMAIN) + ATTESTATION_UNSIGNED_WIRE_SIZE

// Closed set of refusal reasons for attestation encoding, decoding, and verification.
Attestation_Refusal :: enum u8 {
	None                  = 0,
	Bad_Wire_Length       = 1,
	Bad_Magic             = 2,
	Unsupported_Version   = 3,
	Nonzero_Reserved      = 4,
	Zero_Boot_Hash        = 5,
	Zero_Pcr_Digest       = 6,
	Zero_Roles_Digest     = 7,
	Zero_Nonce            = 8,
	Zero_Signer_Key       = 9,
	Zero_Signature        = 10,
	Nonce_Mismatch        = 11,
	Boot_Hash_Mismatch    = 12,
	Plan_Hash_Mismatch    = 13,
	Roles_Digest_Mismatch = 14,
	Missing_Verifier      = 15,
	Bad_Signature         = 16,
}

// attestation_refusal_from_word converts a transport word into an
// Attestation_Refusal at the border, refusing any unknown value.
attestation_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Attestation_Refusal, ok: bool) {
	return enum_word.member_of_word(Attestation_Refusal, word)
}

// Remote TPM attestation payload covering boot state, PCR digest, active plan,
// active role holders, and fresh verifier nonce.
Attestation_Payload :: struct {
	version:               u32,
	boot_description_hash: blake3.Hash,
	pcr_digest:            blake3.Hash,
	active_plan_hash:      blake3.Hash,
	roles_digest:          blake3.Hash,
	nonce:                 [ATTESTATION_NONCE_SIZE]u8,
	signer_public_key:     [ATTESTATION_PUBLIC_KEY_SIZE]u8,
	signature:             [ATTESTATION_SIGNATURE_SIZE]u8,
}

// Callback supplied by callers to verify an Ed25519 signature without coupling
// the freestanding contract package to a support cryptography implementation.
Attestation_Signature_Verify_Proc :: #type proc "contextless" (
	public_key: [ATTESTATION_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [ATTESTATION_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool

// attestation_unsigned_check validates the non-signature fields of payload.
@(private = "file")
attestation_unsigned_check :: proc "contextless" (payload: ^Attestation_Payload) -> Attestation_Refusal {
	if payload == nil {
		return .Bad_Wire_Length
	}
	if payload.version != ATTESTATION_VERSION {
		return .Unsupported_Version
	}
	boot := payload.boot_description_hash
	if is_zero_bytes(boot[:]) {
		return .Zero_Boot_Hash
	}
	pcr := payload.pcr_digest
	if is_zero_bytes(pcr[:]) {
		return .Zero_Pcr_Digest
	}
	roles := payload.roles_digest
	if is_zero_bytes(roles[:]) {
		return .Zero_Roles_Digest
	}
	nonce := payload.nonce
	if is_zero_bytes(nonce[:]) {
		return .Zero_Nonce
	}
	signer := payload.signer_public_key
	if is_zero_bytes(signer[:]) {
		return .Zero_Signer_Key
	}
	return .None
}

// attestation_write_unsigned writes the canonical 208-byte unsigned wire prefix.
@(private = "file")
attestation_write_unsigned :: proc "contextless" (payload: ^Attestation_Payload, dst: []u8) {
	magic := ATTESTATION_MAGIC
	offset := 0
	copy(dst[offset:][:len(magic)], magic[:])
	offset += len(magic)
	byte_order.write_u32_little_endian(dst, offset, payload.version)
	offset += 4
	byte_order.write_u32_little_endian(dst, offset, 0)
	offset += 4
	copy(dst[offset:][:blake3.HASH_SIZE], payload.boot_description_hash[:])
	offset += blake3.HASH_SIZE
	copy(dst[offset:][:blake3.HASH_SIZE], payload.pcr_digest[:])
	offset += blake3.HASH_SIZE
	copy(dst[offset:][:blake3.HASH_SIZE], payload.active_plan_hash[:])
	offset += blake3.HASH_SIZE
	copy(dst[offset:][:blake3.HASH_SIZE], payload.roles_digest[:])
	offset += blake3.HASH_SIZE
	copy(dst[offset:][:ATTESTATION_NONCE_SIZE], payload.nonce[:])
	offset += ATTESTATION_NONCE_SIZE
	copy(dst[offset:][:ATTESTATION_PUBLIC_KEY_SIZE], payload.signer_public_key[:])
}

// attestation_signing_bytes builds the exact domain-separated byte sequence
// signed by the attestation key.
attestation_signing_bytes :: proc "contextless" (
	payload: ^Attestation_Payload,
	out: ^[ATTESTATION_SIGNING_BYTES_SIZE]u8,
) -> (written: int, refusal: Attestation_Refusal) {
	if out == nil {
		return 0, .Bad_Wire_Length
	}
	if check := attestation_unsigned_check(payload); check != .None {
		return 0, check
	}
	domain_len := len(ATTESTATION_DOMAIN)
	copy(out[:domain_len], ATTESTATION_DOMAIN)
	attestation_write_unsigned(payload, out[domain_len:])
	return ATTESTATION_SIGNING_BYTES_SIZE, .None
}

// attestation_encode writes payload in canonical 272-byte little-endian wire
// form into out. On refusal, out is left unchanged.
attestation_encode :: proc "contextless" (
	payload: ^Attestation_Payload,
	out: []u8,
) -> (written: int, refusal: Attestation_Refusal) {
	if len(out) < ATTESTATION_PAYLOAD_WIRE_SIZE {
		return 0, .Bad_Wire_Length
	}
	if check := attestation_unsigned_check(payload); check != .None {
		return 0, check
	}
	sig := payload.signature
	if is_zero_bytes(sig[:]) {
		return 0, .Zero_Signature
	}
	attestation_write_unsigned(payload, out[:ATTESTATION_UNSIGNED_WIRE_SIZE])
	copy(out[ATTESTATION_UNSIGNED_WIRE_SIZE:][:ATTESTATION_SIGNATURE_SIZE], payload.signature[:])
	return ATTESTATION_PAYLOAD_WIRE_SIZE, .None
}

// attestation_decode reads one canonical 272-byte little-endian wire payload,
// refusing truncated buffers, trailing bytes, unknown versions, nonzero
// reserved fields, and zero mandatory fields.
attestation_decode :: proc "contextless" (wire: []u8) -> (payload: Attestation_Payload, refusal: Attestation_Refusal) {
	if len(wire) != ATTESTATION_PAYLOAD_WIRE_SIZE {
		return {}, .Bad_Wire_Length
	}
	magic := ATTESTATION_MAGIC
	if !constant_time_equal(wire[:len(magic)], magic[:]) {
		return {}, .Bad_Magic
	}
	offset := len(magic)
	version := byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	if version != ATTESTATION_VERSION {
		return {}, .Unsupported_Version
	}
	reserved := byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	if reserved != 0 {
		return {}, .Nonzero_Reserved
	}
	decoded: Attestation_Payload
	decoded.version = version
	copy(decoded.boot_description_hash[:], wire[offset:][:blake3.HASH_SIZE])
	offset += blake3.HASH_SIZE
	copy(decoded.pcr_digest[:], wire[offset:][:blake3.HASH_SIZE])
	offset += blake3.HASH_SIZE
	copy(decoded.active_plan_hash[:], wire[offset:][:blake3.HASH_SIZE])
	offset += blake3.HASH_SIZE
	copy(decoded.roles_digest[:], wire[offset:][:blake3.HASH_SIZE])
	offset += blake3.HASH_SIZE
	copy(decoded.nonce[:], wire[offset:][:ATTESTATION_NONCE_SIZE])
	offset += ATTESTATION_NONCE_SIZE
	copy(decoded.signer_public_key[:], wire[offset:][:ATTESTATION_PUBLIC_KEY_SIZE])
	offset += ATTESTATION_PUBLIC_KEY_SIZE
	copy(decoded.signature[:], wire[offset:][:ATTESTATION_SIGNATURE_SIZE])

	if check := attestation_unsigned_check(&decoded); check != .None {
		return {}, check
	}
	if is_zero_bytes(decoded.signature[:]) {
		return {}, .Zero_Signature
	}
	return decoded, .None
}

// attestation_verify checks payload integrity, expected nonce, boot hash,
// active plan hash, active role-holder digest, and Ed25519 signature.
attestation_verify :: proc "contextless" (
	payload: ^Attestation_Payload,
	expected_nonce: [ATTESTATION_NONCE_SIZE]u8,
	expected_boot_hash: blake3.Hash,
	expected_plan_hash: blake3.Hash,
	expected_roles_digest: blake3.Hash,
	verify_sig: Attestation_Signature_Verify_Proc,
	user: rawptr = nil,
) -> Attestation_Refusal {
	if verify_sig == nil {
		return .Missing_Verifier
	}
	if check := attestation_unsigned_check(payload); check != .None {
		return check
	}
	sig := payload.signature
	if is_zero_bytes(sig[:]) {
		return .Zero_Signature
	}
	exp_nonce := expected_nonce
	if is_zero_bytes(exp_nonce[:]) {
		return .Zero_Nonce
	}
	exp_boot := expected_boot_hash
	if is_zero_bytes(exp_boot[:]) {
		return .Zero_Boot_Hash
	}
	exp_roles := expected_roles_digest
	if is_zero_bytes(exp_roles[:]) {
		return .Zero_Roles_Digest
	}
	exp_plan := expected_plan_hash

	if !constant_time_equal(payload.nonce[:], exp_nonce[:]) {
		return .Nonce_Mismatch
	}
	if !constant_time_equal(payload.boot_description_hash[:], exp_boot[:]) {
		return .Boot_Hash_Mismatch
	}
	if !constant_time_equal(payload.active_plan_hash[:], exp_plan[:]) {
		return .Plan_Hash_Mismatch
	}
	if !constant_time_equal(payload.roles_digest[:], exp_roles[:]) {
		return .Roles_Digest_Mismatch
	}

	signing_buf: [ATTESTATION_SIGNING_BYTES_SIZE]u8
	written, build_refusal := attestation_signing_bytes(payload, &signing_buf)
	if build_refusal != .None {
		return build_refusal
	}
	if !verify_sig(payload.signer_public_key, signing_buf[:written], payload.signature, user) {
		return .Bad_Signature
	}
	return .None
}
