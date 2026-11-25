// TPM storage hierarchy authorization seal, publisher-signed TPM2_PolicyAuthorize
// envelopes across PCR 7 changes, and monotonic NV floor policy verification
// (src/md/features/tpm_sealed_machine_key.md and src/md/features/rollback_floors.md).
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package tpm_policy

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: byte length of the random storage hierarchy authorization value.
STORAGE_HIERARCHY_AUTH_SIZE :: 32

// Format property: byte length of a publisher policy key tag or Ed25519 public key.
PUBLISHER_KEY_TAG_SIZE :: 32

// Format property: byte length of a TPM policy digest or PCR 7 digest.
TPM_POLICY_DIGEST_SIZE :: 32

// Format property: byte length of a signature over an authorized policy (ECDSA P-256 raw R||S or Ed25519).
TPM_POLICY_SIGNATURE_SIZE :: 64

// Format property: canonical wire format version for both seal and policy envelopes.
TPM_POLICY_FORMAT_VERSION :: u32(1)

// Format property: 8-byte wire magic identifying a Storage_Hierarchy_Auth_Seal record.
STORAGE_AUTH_SEAL_MAGIC :: [8]u8{'M', 'O', 'D', 'H', 'A', 'U', 'T', '1'}

// Format property: 8-byte wire magic identifying an Authorized_Policy_Envelope record.
AUTHORIZED_POLICY_MAGIC :: [8]u8{'M', 'O', 'D', 'T', 'P', 'O', 'L', '1'}

// Format property: domain separator for Storage_Hierarchy_Auth_Seal integrity tags.
STORAGE_AUTH_SEAL_DOMAIN :: "modus tpm storage auth seal v1"

// Format property: domain separator prepended to signed Authorized_Policy_Envelope bytes.
TPM_POLICY_DOMAIN :: "modus tpm policy authorize v1"

// Format property: bit-field NV floor bounds (TPM_NT_BITS holds 64 numbered positions).
KEY_NUMBER_MIN :: u32(1)
KEY_NUMBER_MAX :: u32(64)
NV_VERSION_FLOOR_MIN :: u32(1)
NV_VERSION_FLOOR_MAX :: u32(64)

// Format property: exact encoded byte length of Storage_Hierarchy_Auth_Seal
// (magic 8 + version 4 + reserved 4 + handle 4 + policy_digest 32 + auth_value 32 + integrity_tag 32).
STORAGE_AUTH_SEAL_WIRE_SIZE :: 8 + 4 + 4 + 4 + TPM_POLICY_DIGEST_SIZE + STORAGE_HIERARCHY_AUTH_SIZE + blake3.HASH_SIZE

// Format property: unsigned prefix length of Authorized_Policy_Envelope
// (magic 8 + version 4 + kind 1 + reserved 3 + key_number 4 + version_floor 4 + key_tag 32 + policy_digest 32 + pcr7_digest 32).
AUTHORIZED_POLICY_UNSIGNED_SIZE :: 8 + 4 + 1 + 3 + 4 + 4 + PUBLISHER_KEY_TAG_SIZE + TPM_POLICY_DIGEST_SIZE + TPM_POLICY_DIGEST_SIZE

// Format property: exact encoded byte length of Authorized_Policy_Envelope.
AUTHORIZED_POLICY_WIRE_SIZE :: AUTHORIZED_POLICY_UNSIGNED_SIZE + TPM_POLICY_SIGNATURE_SIZE

// Format property: exact byte length of the domain-separated message signed by the publisher policy key.
AUTHORIZED_POLICY_SIGNING_SIZE :: len(TPM_POLICY_DOMAIN) + AUTHORIZED_POLICY_UNSIGNED_SIZE

// Closed set of authorized TPM policy targets.
Tpm_Policy_Kind :: enum u8 {
	None             = 0,
	Machine_Key_Seal = 1, // Publisher-signed TPM2_PolicyAuthorize + TPM2_PolicyNV seal of the machine key.
	Rollback_Floor   = 2, // Publisher-signed TPM2_PolicyAuthorize policy for NV key and version floors across PCR 7 changes.
}

// Closed set of refusal reasons for storage hierarchy seals and authorized policy envelopes.
Tpm_Policy_Refusal :: enum u8 {
	None                       = 0,
	Bad_Wire_Length            = 1,
	Bad_Magic                  = 2,
	Unsupported_Version        = 3,
	Nonzero_Reserved           = 4,
	Unknown_Policy_Kind        = 5,
	Zero_Auth_Value            = 6,
	Zero_Persistent_Handle     = 7,
	Zero_Policy_Digest         = 8,
	Zero_Publisher_Key         = 9,
	Zero_Pcr7_Digest           = 10,
	Zero_Signature             = 11,
	Integrity_Mismatch         = 12,
	Key_Number_Out_Of_Range    = 13,
	Version_Floor_Out_Of_Range = 14,
	Key_Revoked                = 15,
	Version_Downgrade          = 16,
	Untrusted_Publisher_Key    = 17,
	Policy_Kind_Mismatch       = 18,
	Missing_Verifier           = 19,
	Bad_Signature              = 20,
}

// tpm_policy_kind_from_word converts a transport word into a Tpm_Policy_Kind
// at the border, refusing None and every unknown value.
tpm_policy_kind_from_word :: proc "contextless" (word: u64) -> (kind: Tpm_Policy_Kind, ok: bool) {
	member := enum_word.member_of_word(Tpm_Policy_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// tpm_policy_refusal_from_word converts a transport word into a
// Tpm_Policy_Refusal at the border, refusing any unknown value.
tpm_policy_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Tpm_Policy_Refusal, ok: bool) {
	return enum_word.member_of_word(Tpm_Policy_Refusal, word)
}

// Random 32-byte storage hierarchy authorization value sealed in the machine-key
// record under a persistent TPM storage key so unseal runs before the owner
// authorization value is known, and another system cannot undefine NV floors.
Storage_Hierarchy_Auth_Seal :: struct {
	version:                   u32,
	persistent_storage_handle: u32,
	policy_digest:             [TPM_POLICY_DIGEST_SIZE]u8,
	auth_value:                [STORAGE_HIERARCHY_AUTH_SIZE]u8,
	integrity_tag:             blake3.Hash,
}

// Publisher-signed TPM2_PolicyAuthorize envelope binding a policy digest,
// publisher key tag, monotonic NV version floor, and current PCR 7 digest so
// firmware or dbx updates keep rollback floors and machine-key seals valid
// while rejecting older signed systems.
Authorized_Policy_Envelope :: struct {
	version:                u32,
	kind:                   Tpm_Policy_Kind,
	key_number:             u32,
	version_floor:          u32,
	publisher_key_tag:      [PUBLISHER_KEY_TAG_SIZE]u8,
	approved_policy_digest: [TPM_POLICY_DIGEST_SIZE]u8,
	pcr7_digest:            [TPM_POLICY_DIGEST_SIZE]u8,
	signature:              [TPM_POLICY_SIGNATURE_SIZE]u8,
}

// Callback supplied by callers to verify a publisher ECDSA P-256 or Ed25519
// signature without coupling the contract package to a support crypto library.
Tpm_Policy_Verify_Proc :: #type proc "contextless" (
	publisher_key_tag: [PUBLISHER_KEY_TAG_SIZE]u8,
	message: []u8,
	signature: [TPM_POLICY_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool

// is_zero_bytes reports whether every byte of slice is zero.
@(private = "file")
is_zero_bytes :: proc "contextless" (bytes: []u8) -> bool {
	acc: u8 = 0
	for b in bytes {
		acc |= b
	}
	return acc == 0
}

// constant_time_equal compares two byte slices without early exit on mismatch.
@(private = "file", optimization_mode = "none")
constant_time_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	diff: u8 = 0
	for index in 0 ..< len(left) {
		diff |= left[index] ~ right[index]
	}
	return diff == 0
}

// storage_auth_seal_write_body writes the 84-byte authenticated prefix of seal.
@(private = "file")
storage_auth_seal_write_body :: proc "contextless" (seal: ^Storage_Hierarchy_Auth_Seal, dst: []u8) {
	magic := STORAGE_AUTH_SEAL_MAGIC
	offset := 0
	copy(dst[offset:][:len(magic)], magic[:])
	offset += len(magic)
	byte_order.write_u32_little_endian(dst, offset, seal.version)
	offset += 4
	byte_order.write_u32_little_endian(dst, offset, 0)
	offset += 4
	byte_order.write_u32_little_endian(dst, offset, seal.persistent_storage_handle)
	offset += 4
	copy(dst[offset:][:TPM_POLICY_DIGEST_SIZE], seal.policy_digest[:])
	offset += TPM_POLICY_DIGEST_SIZE
	copy(dst[offset:][:STORAGE_HIERARCHY_AUTH_SIZE], seal.auth_value[:])
}

// storage_auth_seal_fields_check validates non-tag fields of a storage auth seal.
@(private = "file")
storage_auth_seal_fields_check :: proc "contextless" (seal: ^Storage_Hierarchy_Auth_Seal) -> Tpm_Policy_Refusal {
	if seal == nil {
		return .Bad_Wire_Length
	}
	if seal.version != TPM_POLICY_FORMAT_VERSION {
		return .Unsupported_Version
	}
	if seal.persistent_storage_handle == 0 {
		return .Zero_Persistent_Handle
	}
	if is_zero_bytes(seal.policy_digest[:]) {
		return .Zero_Policy_Digest
	}
	if is_zero_bytes(seal.auth_value[:]) {
		return .Zero_Auth_Value
	}
	return .None
}

// storage_auth_seal_compute_tag computes the domain-separated BLAKE3 integrity
// tag over the canonical prefix of seal.
storage_auth_seal_compute_tag :: proc "contextless" (
	seal: ^Storage_Hierarchy_Auth_Seal,
) -> (tag: blake3.Hash, refusal: Tpm_Policy_Refusal) {
	if check := storage_auth_seal_fields_check(seal); check != .None {
		return {}, check
	}
	body: [STORAGE_AUTH_SEAL_WIRE_SIZE - blake3.HASH_SIZE]u8
	defer intrinsics.mem_zero_volatile(&body[0], len(body))
	storage_auth_seal_write_body(seal, body[:])
	return blake3.derive_key(STORAGE_AUTH_SEAL_DOMAIN, body[:]), .None
}

// storage_auth_seal_verify checks every field and the constant-time integrity
// tag of a Storage_Hierarchy_Auth_Seal.
storage_auth_seal_verify :: proc "contextless" (seal: ^Storage_Hierarchy_Auth_Seal) -> Tpm_Policy_Refusal {
	expected_tag, check := storage_auth_seal_compute_tag(seal)
	if check != .None {
		return check
	}
	got_tag := seal.integrity_tag
	if !constant_time_equal(got_tag[:], expected_tag[:]) {
		return .Integrity_Mismatch
	}
	return .None
}

// storage_auth_seal_encode writes a verified Storage_Hierarchy_Auth_Seal into
// out in canonical little-endian wire form. On refusal, out is left unchanged.
storage_auth_seal_encode :: proc "contextless" (
	seal: ^Storage_Hierarchy_Auth_Seal,
	out: []u8,
) -> (written: int, refusal: Tpm_Policy_Refusal) {
	if len(out) < STORAGE_AUTH_SEAL_WIRE_SIZE {
		return 0, .Bad_Wire_Length
	}
	if check := storage_auth_seal_verify(seal); check != .None {
		return 0, check
	}
	body_len := STORAGE_AUTH_SEAL_WIRE_SIZE - blake3.HASH_SIZE
	storage_auth_seal_write_body(seal, out[:body_len])
	copy(out[body_len:][:blake3.HASH_SIZE], seal.integrity_tag[:])
	return STORAGE_AUTH_SEAL_WIRE_SIZE, .None
}

// storage_auth_seal_decode reads one canonical 116-byte Storage_Hierarchy_Auth_Seal
// record, refusing truncated buffers, trailing bytes, zero auth values, and
// tampered integrity tags.
storage_auth_seal_decode :: proc "contextless" (
	wire: []u8,
) -> (seal: Storage_Hierarchy_Auth_Seal, refusal: Tpm_Policy_Refusal) {
	if len(wire) != STORAGE_AUTH_SEAL_WIRE_SIZE {
		return {}, .Bad_Wire_Length
	}
	magic := STORAGE_AUTH_SEAL_MAGIC
	if !constant_time_equal(wire[:len(magic)], magic[:]) {
		return {}, .Bad_Magic
	}
	offset := len(magic)
	version := byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	if version != TPM_POLICY_FORMAT_VERSION {
		return {}, .Unsupported_Version
	}
	reserved := byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	if reserved != 0 {
		return {}, .Nonzero_Reserved
	}
	decoded: Storage_Hierarchy_Auth_Seal
	decoded.version = version
	decoded.persistent_storage_handle = byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	copy(decoded.policy_digest[:], wire[offset:][:TPM_POLICY_DIGEST_SIZE])
	offset += TPM_POLICY_DIGEST_SIZE
	copy(decoded.auth_value[:], wire[offset:][:STORAGE_HIERARCHY_AUTH_SIZE])
	offset += STORAGE_HIERARCHY_AUTH_SIZE
	copy(decoded.integrity_tag[:], wire[offset:][:blake3.HASH_SIZE])

	if check := storage_auth_seal_verify(&decoded); check != .None {
		intrinsics.mem_zero_volatile(&decoded.auth_value[0], len(decoded.auth_value))
		return {}, check
	}
	return decoded, .None
}

// authorized_policy_unsigned_check validates non-signature fields of envelope.
@(private = "file")
authorized_policy_unsigned_check :: proc "contextless" (envelope: ^Authorized_Policy_Envelope) -> Tpm_Policy_Refusal {
	if envelope == nil {
		return .Bad_Wire_Length
	}
	if envelope.version != TPM_POLICY_FORMAT_VERSION {
		return .Unsupported_Version
	}
	if _, ok := tpm_policy_kind_from_word(u64(envelope.kind)); !ok {
		return .Unknown_Policy_Kind
	}
	if envelope.key_number < KEY_NUMBER_MIN || envelope.key_number > KEY_NUMBER_MAX {
		return .Key_Number_Out_Of_Range
	}
	if envelope.version_floor < NV_VERSION_FLOOR_MIN || envelope.version_floor > NV_VERSION_FLOOR_MAX {
		return .Version_Floor_Out_Of_Range
	}
	pub_key := envelope.publisher_key_tag
	if is_zero_bytes(pub_key[:]) {
		return .Zero_Publisher_Key
	}
	policy := envelope.approved_policy_digest
	if is_zero_bytes(policy[:]) {
		return .Zero_Policy_Digest
	}
	pcr7 := envelope.pcr7_digest
	if is_zero_bytes(pcr7[:]) {
		return .Zero_Pcr7_Digest
	}
	return .None
}

// authorized_policy_write_unsigned writes the 120-byte unsigned canonical prefix.
@(private = "file")
authorized_policy_write_unsigned :: proc "contextless" (envelope: ^Authorized_Policy_Envelope, dst: []u8) {
	magic := AUTHORIZED_POLICY_MAGIC
	offset := 0
	copy(dst[offset:][:len(magic)], magic[:])
	offset += len(magic)
	byte_order.write_u32_little_endian(dst, offset, envelope.version)
	offset += 4
	dst[offset] = u8(envelope.kind)
	dst[offset + 1] = 0
	dst[offset + 2] = 0
	dst[offset + 3] = 0
	offset += 4
	byte_order.write_u32_little_endian(dst, offset, envelope.key_number)
	offset += 4
	byte_order.write_u32_little_endian(dst, offset, envelope.version_floor)
	offset += 4
	copy(dst[offset:][:PUBLISHER_KEY_TAG_SIZE], envelope.publisher_key_tag[:])
	offset += PUBLISHER_KEY_TAG_SIZE
	copy(dst[offset:][:TPM_POLICY_DIGEST_SIZE], envelope.approved_policy_digest[:])
	offset += TPM_POLICY_DIGEST_SIZE
	copy(dst[offset:][:TPM_POLICY_DIGEST_SIZE], envelope.pcr7_digest[:])
}

// authorized_policy_signing_bytes builds the exact domain-separated bytes
// signed by the publisher policy key.
authorized_policy_signing_bytes :: proc "contextless" (
	envelope: ^Authorized_Policy_Envelope,
	out: ^[AUTHORIZED_POLICY_SIGNING_SIZE]u8,
) -> (written: int, refusal: Tpm_Policy_Refusal) {
	if out == nil {
		return 0, .Bad_Wire_Length
	}
	if check := authorized_policy_unsigned_check(envelope); check != .None {
		return 0, check
	}
	domain_len := len(TPM_POLICY_DOMAIN)
	copy(out[:domain_len], TPM_POLICY_DOMAIN)
	authorized_policy_write_unsigned(envelope, out[domain_len:])
	return AUTHORIZED_POLICY_SIGNING_SIZE, .None
}

// authorized_policy_encode writes envelope in canonical 184-byte little-endian
// wire form into out. On refusal, out is left unchanged.
authorized_policy_encode :: proc "contextless" (
	envelope: ^Authorized_Policy_Envelope,
	out: []u8,
) -> (written: int, refusal: Tpm_Policy_Refusal) {
	if len(out) < AUTHORIZED_POLICY_WIRE_SIZE {
		return 0, .Bad_Wire_Length
	}
	if check := authorized_policy_unsigned_check(envelope); check != .None {
		return 0, check
	}
	sig := envelope.signature
	if is_zero_bytes(sig[:]) {
		return 0, .Zero_Signature
	}
	authorized_policy_write_unsigned(envelope, out[:AUTHORIZED_POLICY_UNSIGNED_SIZE])
	copy(out[AUTHORIZED_POLICY_UNSIGNED_SIZE:][:TPM_POLICY_SIGNATURE_SIZE], envelope.signature[:])
	return AUTHORIZED_POLICY_WIRE_SIZE, .None
}

// authorized_policy_decode parses one canonical 184-byte Authorized_Policy_Envelope,
// refusing truncated buffers, trailing bytes, unknown kinds, nonzero reserved
// bytes, out-of-range floors, and zero mandatory fields.
authorized_policy_decode :: proc "contextless" (
	wire: []u8,
) -> (envelope: Authorized_Policy_Envelope, refusal: Tpm_Policy_Refusal) {
	if len(wire) != AUTHORIZED_POLICY_WIRE_SIZE {
		return {}, .Bad_Wire_Length
	}
	magic := AUTHORIZED_POLICY_MAGIC
	if !constant_time_equal(wire[:len(magic)], magic[:]) {
		return {}, .Bad_Magic
	}
	offset := len(magic)
	version := byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	if version != TPM_POLICY_FORMAT_VERSION {
		return {}, .Unsupported_Version
	}
	kind, kind_ok := tpm_policy_kind_from_word(u64(wire[offset]))
	if !kind_ok {
		return {}, .Unknown_Policy_Kind
	}
	if wire[offset + 1] != 0 || wire[offset + 2] != 0 || wire[offset + 3] != 0 {
		return {}, .Nonzero_Reserved
	}
	offset += 4
	decoded: Authorized_Policy_Envelope
	decoded.version = version
	decoded.kind = kind
	decoded.key_number = byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	decoded.version_floor = byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	copy(decoded.publisher_key_tag[:], wire[offset:][:PUBLISHER_KEY_TAG_SIZE])
	offset += PUBLISHER_KEY_TAG_SIZE
	copy(decoded.approved_policy_digest[:], wire[offset:][:TPM_POLICY_DIGEST_SIZE])
	offset += TPM_POLICY_DIGEST_SIZE
	copy(decoded.pcr7_digest[:], wire[offset:][:TPM_POLICY_DIGEST_SIZE])
	offset += TPM_POLICY_DIGEST_SIZE
	copy(decoded.signature[:], wire[offset:][:TPM_POLICY_SIGNATURE_SIZE])

	if check := authorized_policy_unsigned_check(&decoded); check != .None {
		return {}, check
	}
	if is_zero_bytes(decoded.signature[:]) {
		return {}, .Zero_Signature
	}
	return decoded, .None
}

// authorized_policy_verify validates an Authorized_Policy_Envelope against the
// expected policy kind, trusted publisher key, current monotonic key floor and
// version floor, and publisher signature. A PCR 7 change passes when signed by
// the trusted publisher key at or above the current floors.
authorized_policy_verify :: proc "contextless" (
	envelope: ^Authorized_Policy_Envelope,
	expected_kind: Tpm_Policy_Kind,
	trusted_publisher_key: [PUBLISHER_KEY_TAG_SIZE]u8,
	current_key_floor: u32,
	current_version_floor: u32,
	verify_sig: Tpm_Policy_Verify_Proc,
	user: rawptr = nil,
) -> Tpm_Policy_Refusal {
	if verify_sig == nil {
		return .Missing_Verifier
	}
	if _, expected_ok := tpm_policy_kind_from_word(u64(expected_kind)); !expected_ok {
		return .Unknown_Policy_Kind
	}
	trusted_key := trusted_publisher_key
	if is_zero_bytes(trusted_key[:]) {
		return .Zero_Publisher_Key
	}
	if check := authorized_policy_unsigned_check(envelope); check != .None {
		return check
	}
	sig := envelope.signature
	if is_zero_bytes(sig[:]) {
		return .Zero_Signature
	}
	if envelope.kind != expected_kind {
		return .Policy_Kind_Mismatch
	}
	if !constant_time_equal(envelope.publisher_key_tag[:], trusted_key[:]) {
		return .Untrusted_Publisher_Key
	}
	if envelope.key_number < current_key_floor {
		return .Key_Revoked
	}
	if envelope.version_floor < current_version_floor {
		return .Version_Downgrade
	}

	signing_buf: [AUTHORIZED_POLICY_SIGNING_SIZE]u8
	written, build_refusal := authorized_policy_signing_bytes(envelope, &signing_buf)
	if build_refusal != .None {
		return build_refusal
	}
	if !verify_sig(trusted_key, signing_buf[:written], envelope.signature, user) {
		return .Bad_Signature
	}
	return .None
}
