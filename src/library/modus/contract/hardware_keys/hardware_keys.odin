// FIDO2/CTAP2 and PIV/OpenPGP hardware security key challenge, assertion wire
// encoding, and verification contract (src/md/features/hardware_keys.md).
//
// Private key material never leaves the hardware token. Every signed assertion
// binds the closed protocol, closed purpose, caller scope (RP ID or action),
// fresh 32-byte challenge, user presence / user verification flags, and
// monotonic sign counter under one domain-separated signature.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package hardware_keys

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: domain separation prefix prepended to signed assertion bytes.
HARDWARE_KEY_DOMAIN :: "modus hardware key assertion v1"

// Format property: 8-byte wire magic identifying a Hardware_Key_Assertion record.
HARDWARE_KEY_MAGIC :: [8]u8{'M', 'O', 'D', 'H', 'W', 'K', '0', '1'}

// Format property: canonical wire format version.
HARDWARE_KEY_VERSION :: u32(1)

// Format property: byte length of a fresh challenge nonce.
HARDWARE_KEY_CHALLENGE_SIZE :: 32

// Format property: byte length of a hardware token Ed25519 public key.
HARDWARE_KEY_PUBLIC_KEY_SIZE :: 32

// Format property: byte length of a hardware token Ed25519 assertion signature.
HARDWARE_KEY_SIGNATURE_SIZE :: 64

// Format property: maximum ASCII byte length of a Relying Party ID or action scope.
HARDWARE_KEY_SCOPE_LIMIT :: 128

// Format property: fixed unsigned header bytes before variable scope bytes
// (magic 8 + version 4 + protocol 1 + purpose 1 + flags 1 + reserved 1 + sign_count 4 + challenge 32 + public_key 32 + scope_length 4).
HARDWARE_KEY_HEADER_SIZE :: 8 + 4 + 1 + 1 + 1 + 1 + 4 + HARDWARE_KEY_CHALLENGE_SIZE + HARDWARE_KEY_PUBLIC_KEY_SIZE + 4

// Format property: maximum encoded byte length of one Hardware_Key_Assertion record.
HARDWARE_KEY_WIRE_LIMIT :: HARDWARE_KEY_HEADER_SIZE + HARDWARE_KEY_SCOPE_LIMIT + HARDWARE_KEY_SIGNATURE_SIZE

// Format property: maximum byte length of the domain-separated signing message.
HARDWARE_KEY_SIGNING_LIMIT :: len(HARDWARE_KEY_DOMAIN) + HARDWARE_KEY_HEADER_SIZE + HARDWARE_KEY_SCOPE_LIMIT

// Closed set of supported hardware security key protocols.
Hardware_Key_Protocol :: enum u8 {
	None              = 0,
	Ctap2_Fido2       = 1,
	Smartcard_Piv     = 2,
	Smartcard_OpenPGP = 3,
}

// Closed set of authorized purposes for a hardware key assertion.
Hardware_Key_Purpose :: enum u8 {
	None               = 0,
	Unlock             = 1,
	Approve_Wide_Grant = 2,
	Sign_Realisation   = 3,
	Browser_WebAuthn   = 4,
}

// Closed set of hardware token assertion flags.
Hardware_Key_Flag :: enum u8 {
	User_Present  = 0, // Physical touch or presence check performed on the token.
	User_Verified = 1, // PIN or biometric verification performed on the token.
}

// Bit set of assertion flags reported by the hardware token.
Hardware_Key_Flags :: bit_set[Hardware_Key_Flag;u8]

// Mask of every defined Hardware_Key_Flag bit; unknown bits are refused at the border.
ALL_HARDWARE_KEY_FLAGS :: Hardware_Key_Flags{.User_Present, .User_Verified}

// Closed set of refusal reasons for hardware key encoding, decoding, and verification.
Hardware_Key_Refusal :: enum u8 {
	None                      = 0,
	Bad_Wire_Length           = 1,
	Bad_Magic                 = 2,
	Unsupported_Version       = 3,
	Nonzero_Reserved          = 4,
	Unknown_Protocol          = 5,
	Unknown_Purpose           = 6,
	Unknown_Flags             = 7,
	Zero_Challenge            = 8,
	Empty_Scope               = 9,
	Scope_Too_Long            = 10,
	Bad_Scope_Byte            = 11,
	Zero_Public_Key           = 12,
	Zero_Signature            = 13,
	Protocol_Mismatch         = 14,
	Purpose_Mismatch          = 15,
	Scope_Mismatch            = 16,
	Challenge_Mismatch        = 17,
	User_Presence_Missing     = 18,
	User_Verification_Missing = 19,
	Sign_Count_Rollback       = 20,
	Key_Mismatch              = 21,
	Missing_Verifier          = 22,
	Bad_Signature             = 23,
}

// hardware_key_protocol_from_word converts a transport word into a
// Hardware_Key_Protocol at the border, refusing None and every unknown value.
hardware_key_protocol_from_word :: proc "contextless" (word: u64) -> (protocol: Hardware_Key_Protocol, ok: bool) {
	member := enum_word.member_of_word(Hardware_Key_Protocol, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// hardware_key_purpose_from_word converts a transport word into a
// Hardware_Key_Purpose at the border, refusing None and every unknown value.
hardware_key_purpose_from_word :: proc "contextless" (word: u64) -> (purpose: Hardware_Key_Purpose, ok: bool) {
	member := enum_word.member_of_word(Hardware_Key_Purpose, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// hardware_key_flags_to_word returns the canonical u8 wire mask of flags.
hardware_key_flags_to_word :: proc "contextless" (flags: Hardware_Key_Flags) -> u8 {
	return transmute(u8)flags
}

// hardware_key_flags_from_word converts a wire byte into Hardware_Key_Flags,
// refusing any bit outside ALL_HARDWARE_KEY_FLAGS.
hardware_key_flags_from_word :: proc "contextless" (word: u8) -> (flags: Hardware_Key_Flags, ok: bool) {
	all_flags := ALL_HARDWARE_KEY_FLAGS
	allowed := transmute(u8)all_flags
	if (word & ~allowed) != 0 {
		return {}, false
	}
	return transmute(Hardware_Key_Flags)word, true
}

// hardware_key_refusal_from_word converts a transport word into a
// Hardware_Key_Refusal at the border, refusing any unknown value.
hardware_key_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Hardware_Key_Refusal, ok: bool) {
	return enum_word.member_of_word(Hardware_Key_Refusal, word)
}

// Challenge issued to the isolated hardware-key device service.
Hardware_Key_Challenge :: struct {
	protocol:                  Hardware_Key_Protocol,
	purpose:                   Hardware_Key_Purpose,
	challenge:                 [HARDWARE_KEY_CHALLENGE_SIZE]u8,
	scope:                     string,
	require_user_presence:     bool,
	require_user_verification: bool,
}

// Signed assertion returned by the hardware-key device service.
Hardware_Key_Assertion :: struct {
	version:      u32,
	protocol:     Hardware_Key_Protocol,
	purpose:      Hardware_Key_Purpose,
	flags:        Hardware_Key_Flags,
	sign_count:   u32,
	challenge:    [HARDWARE_KEY_CHALLENGE_SIZE]u8,
	public_key:   [HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	scope_bytes:  [HARDWARE_KEY_SCOPE_LIMIT]u8,
	scope_length: u32,
	signature:    [HARDWARE_KEY_SIGNATURE_SIZE]u8,
}

// Callback supplied by callers to verify an Ed25519 assertion signature.
Hardware_Key_Verify_Proc :: #type proc "contextless" (
	public_key: [HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [HARDWARE_KEY_SIGNATURE_SIZE]u8,
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

// scope_bytes_check validates that scope is non-empty, within HARDWARE_KEY_SCOPE_LIMIT,
// and contains only printable ASCII non-whitespace bytes (0x21..0x7E).
@(private = "file")
scope_bytes_check :: proc "contextless" (scope: []u8) -> Hardware_Key_Refusal {
	if len(scope) == 0 {
		return .Empty_Scope
	}
	if len(scope) > HARDWARE_KEY_SCOPE_LIMIT {
		return .Scope_Too_Long
	}
	for b in scope {
		if b < 0x21 || b > 0x7E {
			return .Bad_Scope_Byte
		}
	}
	return .None
}

// hardware_key_assertion_scope_set copies scope into assertion's inline buffer.
hardware_key_assertion_scope_set :: proc "contextless" (assertion: ^Hardware_Key_Assertion, scope: string) -> Hardware_Key_Refusal {
	if assertion == nil {
		return .Bad_Wire_Length
	}
	bytes := transmute([]u8)scope
	if check := scope_bytes_check(bytes); check != .None {
		return check
	}
	assertion.scope_bytes = {}
	copy(assertion.scope_bytes[:len(bytes)], bytes)
	assertion.scope_length = u32(len(bytes))
	return .None
}

// hardware_key_assertion_scope returns the scope string held in assertion,
// or empty string when scope_length exceeds HARDWARE_KEY_SCOPE_LIMIT.
hardware_key_assertion_scope :: proc "contextless" (assertion: ^Hardware_Key_Assertion) -> string {
	if assertion == nil || assertion.scope_length > HARDWARE_KEY_SCOPE_LIMIT {
		return ""
	}
	return string(assertion.scope_bytes[:assertion.scope_length])
}

// assertion_unsigned_check validates every non-signature field of assertion.
@(private = "file")
assertion_unsigned_check :: proc "contextless" (assertion: ^Hardware_Key_Assertion) -> Hardware_Key_Refusal {
	if assertion == nil {
		return .Bad_Wire_Length
	}
	if assertion.version != HARDWARE_KEY_VERSION {
		return .Unsupported_Version
	}
	if _, ok := hardware_key_protocol_from_word(u64(assertion.protocol)); !ok {
		return .Unknown_Protocol
	}
	if _, ok := hardware_key_purpose_from_word(u64(assertion.purpose)); !ok {
		return .Unknown_Purpose
	}
	if _, ok := hardware_key_flags_from_word(hardware_key_flags_to_word(assertion.flags)); !ok {
		return .Unknown_Flags
	}
	challenge := assertion.challenge
	if is_zero_bytes(challenge[:]) {
		return .Zero_Challenge
	}
	pub := assertion.public_key
	if is_zero_bytes(pub[:]) {
		return .Zero_Public_Key
	}
	if assertion.scope_length == 0 {
		return .Empty_Scope
	}
	if assertion.scope_length > HARDWARE_KEY_SCOPE_LIMIT {
		return .Scope_Too_Long
	}
	if check := scope_bytes_check(assertion.scope_bytes[:assertion.scope_length]); check != .None {
		return check
	}
	return .None
}

// assertion_write_unsigned writes the canonical unsigned prefix (header + scope).
@(private = "file")
assertion_write_unsigned :: proc "contextless" (assertion: ^Hardware_Key_Assertion, dst: []u8) -> int {
	magic := HARDWARE_KEY_MAGIC
	offset := 0
	copy(dst[offset:][:len(magic)], magic[:])
	offset += len(magic)
	byte_order.write_u32_little_endian(dst, offset, assertion.version)
	offset += 4
	dst[offset] = u8(assertion.protocol)
	dst[offset + 1] = u8(assertion.purpose)
	dst[offset + 2] = hardware_key_flags_to_word(assertion.flags)
	dst[offset + 3] = 0
	offset += 4
	byte_order.write_u32_little_endian(dst, offset, assertion.sign_count)
	offset += 4
	copy(dst[offset:][:HARDWARE_KEY_CHALLENGE_SIZE], assertion.challenge[:])
	offset += HARDWARE_KEY_CHALLENGE_SIZE
	copy(dst[offset:][:HARDWARE_KEY_PUBLIC_KEY_SIZE], assertion.public_key[:])
	offset += HARDWARE_KEY_PUBLIC_KEY_SIZE
	byte_order.write_u32_little_endian(dst, offset, assertion.scope_length)
	offset += 4
	scope_len := int(assertion.scope_length)
	copy(dst[offset:][:scope_len], assertion.scope_bytes[:scope_len])
	offset += scope_len
	return offset
}

// hardware_key_signing_bytes writes the exact domain-separated message signed
// by the hardware security key.
hardware_key_signing_bytes :: proc "contextless" (
	assertion: ^Hardware_Key_Assertion,
	out: ^[HARDWARE_KEY_SIGNING_LIMIT]u8,
) -> (written: int, refusal: Hardware_Key_Refusal) {
	if out == nil {
		return 0, .Bad_Wire_Length
	}
	if check := assertion_unsigned_check(assertion); check != .None {
		return 0, check
	}
	domain_len := len(HARDWARE_KEY_DOMAIN)
	copy(out[:domain_len], HARDWARE_KEY_DOMAIN)
	unsigned_len := assertion_write_unsigned(assertion, out[domain_len:])
	return domain_len + unsigned_len, .None
}

// hardware_key_assertion_encode writes assertion in canonical little-endian
// wire form into out. On refusal, out is left unchanged.
hardware_key_assertion_encode :: proc "contextless" (
	assertion: ^Hardware_Key_Assertion,
	out: []u8,
) -> (written: int, refusal: Hardware_Key_Refusal) {
	if check := assertion_unsigned_check(assertion); check != .None {
		return 0, check
	}
	sig := assertion.signature
	if is_zero_bytes(sig[:]) {
		return 0, .Zero_Signature
	}
	needed := HARDWARE_KEY_HEADER_SIZE + int(assertion.scope_length) + HARDWARE_KEY_SIGNATURE_SIZE
	if len(out) < needed {
		return 0, .Bad_Wire_Length
	}
	unsigned_len := assertion_write_unsigned(assertion, out[:needed - HARDWARE_KEY_SIGNATURE_SIZE])
	copy(out[unsigned_len:][:HARDWARE_KEY_SIGNATURE_SIZE], assertion.signature[:])
	return needed, .None
}

// hardware_key_assertion_decode parses one canonical Hardware_Key_Assertion,
// refusing truncated buffers, trailing bytes, unknown protocol/purpose/flags,
// nonzero reserved bytes, malformed scope, and zero mandatory fields.
hardware_key_assertion_decode :: proc "contextless" (
	wire: []u8,
) -> (assertion: Hardware_Key_Assertion, refusal: Hardware_Key_Refusal) {
	min_wire := HARDWARE_KEY_HEADER_SIZE + 1 + HARDWARE_KEY_SIGNATURE_SIZE
	if len(wire) < min_wire || len(wire) > HARDWARE_KEY_WIRE_LIMIT {
		return {}, .Bad_Wire_Length
	}
	magic := HARDWARE_KEY_MAGIC
	if !constant_time_equal(wire[:len(magic)], magic[:]) {
		return {}, .Bad_Magic
	}
	offset := len(magic)
	version := byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	if version != HARDWARE_KEY_VERSION {
		return {}, .Unsupported_Version
	}
	protocol, proto_ok := hardware_key_protocol_from_word(u64(wire[offset]))
	if !proto_ok {
		return {}, .Unknown_Protocol
	}
	purpose, purpose_ok := hardware_key_purpose_from_word(u64(wire[offset + 1]))
	if !purpose_ok {
		return {}, .Unknown_Purpose
	}
	flags, flags_ok := hardware_key_flags_from_word(wire[offset + 2])
	if !flags_ok {
		return {}, .Unknown_Flags
	}
	if wire[offset + 3] != 0 {
		return {}, .Nonzero_Reserved
	}
	offset += 4

	decoded: Hardware_Key_Assertion
	decoded.version = version
	decoded.protocol = protocol
	decoded.purpose = purpose
	decoded.flags = flags
	decoded.sign_count = byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	copy(decoded.challenge[:], wire[offset:][:HARDWARE_KEY_CHALLENGE_SIZE])
	offset += HARDWARE_KEY_CHALLENGE_SIZE
	copy(decoded.public_key[:], wire[offset:][:HARDWARE_KEY_PUBLIC_KEY_SIZE])
	offset += HARDWARE_KEY_PUBLIC_KEY_SIZE
	scope_length := byte_order.read_u32_little_endian(wire, offset)
	offset += 4
	if scope_length == 0 {
		return {}, .Empty_Scope
	}
	if scope_length > HARDWARE_KEY_SCOPE_LIMIT {
		return {}, .Scope_Too_Long
	}
	expected_wire_len := HARDWARE_KEY_HEADER_SIZE + int(scope_length) + HARDWARE_KEY_SIGNATURE_SIZE
	if len(wire) != expected_wire_len {
		return {}, .Bad_Wire_Length
	}
	decoded.scope_length = scope_length
	copy(decoded.scope_bytes[:scope_length], wire[offset:][:scope_length])
	offset += int(scope_length)
	copy(decoded.signature[:], wire[offset:][:HARDWARE_KEY_SIGNATURE_SIZE])

	if check := assertion_unsigned_check(&decoded); check != .None {
		return {}, check
	}
	if is_zero_bytes(decoded.signature[:]) {
		return {}, .Zero_Signature
	}
	return decoded, .None
}

// hardware_key_assertion_verify checks assertion against challenge, expected
// public key, previous monotonic sign_count, UP/UV requirements, and Ed25519
// signature.
hardware_key_assertion_verify :: proc "contextless" (
	challenge: ^Hardware_Key_Challenge,
	assertion: ^Hardware_Key_Assertion,
	expected_public_key: [HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	last_sign_count: u32,
	verify_sig: Hardware_Key_Verify_Proc,
	user: rawptr = nil,
) -> Hardware_Key_Refusal {
	if verify_sig == nil {
		return .Missing_Verifier
	}
	if challenge == nil || assertion == nil {
		return .Bad_Wire_Length
	}
	if _, ok := hardware_key_protocol_from_word(u64(challenge.protocol)); !ok {
		return .Unknown_Protocol
	}
	if _, ok := hardware_key_purpose_from_word(u64(challenge.purpose)); !ok {
		return .Unknown_Purpose
	}
	exp_challenge := challenge.challenge
	if is_zero_bytes(exp_challenge[:]) {
		return .Zero_Challenge
	}
	exp_scope := transmute([]u8)challenge.scope
	if scope_check := scope_bytes_check(exp_scope); scope_check != .None {
		return scope_check
	}
	exp_key := expected_public_key
	if is_zero_bytes(exp_key[:]) {
		return .Zero_Public_Key
	}

	if check := assertion_unsigned_check(assertion); check != .None {
		return check
	}
	sig := assertion.signature
	if is_zero_bytes(sig[:]) {
		return .Zero_Signature
	}
	if assertion.protocol != challenge.protocol {
		return .Protocol_Mismatch
	}
	if assertion.purpose != challenge.purpose {
		return .Purpose_Mismatch
	}
	if !constant_time_equal(assertion.public_key[:], exp_key[:]) {
		return .Key_Mismatch
	}
	if !constant_time_equal(assertion.challenge[:], exp_challenge[:]) {
		return .Challenge_Mismatch
	}
	if !constant_time_equal(assertion.scope_bytes[:assertion.scope_length], exp_scope) {
		return .Scope_Mismatch
	}
	if challenge.require_user_presence && (.User_Present not_in assertion.flags) {
		return .User_Presence_Missing
	}
	if challenge.require_user_verification && (.User_Verified not_in assertion.flags) {
		return .User_Verification_Missing
	}
	if last_sign_count > 0 && assertion.sign_count <= last_sign_count {
		return .Sign_Count_Rollback
	}

	signing_buf: [HARDWARE_KEY_SIGNING_LIMIT]u8
	written, build_ref := hardware_key_signing_bytes(assertion, &signing_buf)
	if build_ref != .None {
		return build_ref
	}
	if !verify_sig(exp_key, signing_buf[:written], assertion.signature, user) {
		return .Bad_Signature
	}
	return .None
}
