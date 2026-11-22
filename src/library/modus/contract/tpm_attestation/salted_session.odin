// TPM 2.0 salted session key derivation, symmetric parameter encryption,
// cpHash/rpHash HMAC generation and constant-time verification, and nonce
// rolling (src/md/features/tpm_sealed_machine_key.md).
//
// Parameter encryption keeps secrets confidential across a discrete TPM bus.
// Every session requires non-zero salt and non-zero distinct caller and TPM
// nonces; a refused call never mutates session state or output buffers.
package tpm_attestation

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Standard 32-byte SHA-256 session nonce size.
NONCE_SIZE :: 32

// Upper bound on salt secret length accepted into KDFa.
MAX_SALT_SIZE :: 64

// Maximum parameter payload supported for single-shot KDFa XOR obfuscation.
MAX_PARAMETER_BYTES :: 4096

// Closed set of symmetric parameter protection ciphers (TPM 2.0 Part 2).
Session_Cipher :: enum u16 {
	Aes_128_Cfb = 0x0006, // TPM_ALG_AES in 128-bit CFB mode.
	Xor_Sha256  = 0x000A, // TPM_ALG_XOR with KDFa(SHA-256) stream.
}

// Direction of a session message, selecting nonce ordering in KDFa and HMAC.
Session_Direction :: enum u8 {
	Command  = 1,
	Response = 2,
}

// TPMA_SESSION bit positions (TPM 2.0 Part 2).
Session_Attribute :: enum u8 {
	Continue_Session = 0,
	Audit_Exclusive  = 1,
	Audit_Reset      = 2,
	Decrypt          = 5,
	Encrypt          = 6,
	Audit            = 7,
}

Session_Attributes :: bit_set[Session_Attribute; u8]

// Closed set of refusals for TPM 2.0 salted sessions.
Session_Refusal :: enum u8 {
	None                  = 0,
	Bad_Cipher            = 1,
	Bad_Direction         = 2,
	Not_Initialized       = 3,
	Zero_Salt             = 4,
	Salt_Too_Long         = 5,
	Auth_Value_Too_Long   = 6,
	Zero_Nonce            = 7,
	Replayed_Nonce        = 8,
	Invalid_Bit_Count     = 9,
	Empty_Label           = 10,
	Empty_Parameter       = 11,
	Parameter_Too_Large   = 12,
	Buffer_Too_Small      = 13,
	Hmac_Mismatch         = 14,
}

// Active TPM 2.0 salted HMAC/parameter-encryption session state.
Salted_Session :: struct {
	initialized:       bool,
	cipher:            Session_Cipher,
	session_key:       Digest,
	auth_value:        Digest,
	auth_value_length: u8,
	nonce_caller:      [NONCE_SIZE]u8,
	nonce_tpm:         [NONCE_SIZE]u8,
	encrypt_key:       [AES128_KEY_SIZE]u8,
	iv:                [AES128_BLOCK_SIZE]u8,
	command_counter:   u64,
}

// session_cipher_of_word converts a transport algorithm word to Session_Cipher.
session_cipher_of_word :: proc "contextless" (word: u64) -> (cipher: Session_Cipher, ok: bool) {
	return enum_word.member_of_word(Session_Cipher, word)
}

// session_direction_of_word converts a transport word to Session_Direction.
session_direction_of_word :: proc "contextless" (word: u64) -> (direction: Session_Direction, ok: bool) {
	return enum_word.member_of_word(Session_Direction, word)
}

// kdfa_sha256 implements TPM 2.0 KDFa (SP 800-108 counter-mode HMAC-SHA-256).
// Counter starts at 1; each block hashes:
//   be32(counter) || label || 0x00 || context_u || context_v || be32(bits).
// Refuses empty/all-zero keys, empty labels, zero or non-byte-aligned bit
// counts, or undersized output buffers without writing to output.
kdfa_sha256 :: proc "contextless" (
	key: []u8,
	label: string,
	context_u: []u8,
	context_v: []u8,
	bits: u32,
	output: []u8,
) -> Session_Refusal {
	if len(key) == 0 || is_all_zero(key) {
		return .Zero_Salt
	}
	if len(label) == 0 {
		return .Empty_Label
	}
	if bits == 0 || (bits % 8) != 0 {
		return .Invalid_Bit_Count
	}
	byte_count := int(bits / 8)
	if len(output) < byte_count {
		return .Buffer_Too_Small
	}

	label_bytes := transmute([]u8)label
	zero_sep := [1]u8{0}
	bits_encoded: [4]u8
	byte_order.write_u32_big_endian(bits_encoded[:], 0, bits)

	written := 0
	counter: u32 = 1
	for written < byte_count {
		counter_encoded: [4]u8
		byte_order.write_u32_big_endian(counter_encoded[:], 0, counter)

		mac_ctx: Hmac_Sha256_State
		hmac_sha256_init(&mac_ctx, key)
		hmac_sha256_update(&mac_ctx, counter_encoded[:])
		hmac_sha256_update(&mac_ctx, label_bytes)
		// TPM 2.0 Part 1 appends a NUL byte if label does not already end in NUL.
		if label_bytes[len(label_bytes) - 1] != 0 {
			hmac_sha256_update(&mac_ctx, zero_sep[:])
		}
		if len(context_u) > 0 {
			hmac_sha256_update(&mac_ctx, context_u)
		}
		if len(context_v) > 0 {
			hmac_sha256_update(&mac_ctx, context_v)
		}
		hmac_sha256_update(&mac_ctx, bits_encoded[:])
		block := hmac_sha256_final(&mac_ctx)

		take := min(SHA256_SIZE, byte_count - written)
		copy(output[written:written + take], block[:take])
		zero_bytes(block[:])
		written += take
		counter += 1
	}
	return .None
}

// build_composite_hmac_key writes session_key || auth_value[:auth_value_length]
// into destination and returns its active length.
@(private)
build_composite_hmac_key :: proc "contextless" (session: ^Salted_Session, destination: ^[SHA256_SIZE * 2]u8) -> int {
	copy(destination[:SHA256_SIZE], session.session_key[:])
	auth_len := min(int(session.auth_value_length), SHA256_SIZE)
	if auth_len > 0 {
		copy(destination[SHA256_SIZE:SHA256_SIZE + auth_len], session.auth_value[:auth_len])
	}
	return SHA256_SIZE + auth_len
}

// salted_session_init validates all inputs and derives session_key ("ATH")
// plus the initial command encrypt_key and iv ("CFB"). A refused call leaves
// session untouched.
salted_session_init :: proc "contextless" (
	session: ^Salted_Session,
	cipher: Session_Cipher,
	salt_secret: []u8,
	auth_value: []u8,
	nonce_caller: [NONCE_SIZE]u8,
	nonce_tpm: [NONCE_SIZE]u8,
) -> Session_Refusal {
	checked_cipher, cipher_ok := session_cipher_of_word(u64(cipher))
	if !cipher_ok {
		return .Bad_Cipher
	}
	if len(salt_secret) == 0 || is_all_zero(salt_secret) {
		return .Zero_Salt
	}
	if len(salt_secret) > MAX_SALT_SIZE {
		return .Salt_Too_Long
	}
	if len(auth_value) > SHA256_SIZE {
		return .Auth_Value_Too_Long
	}
	nc := nonce_caller
	nt := nonce_tpm
	if is_all_zero(nc[:]) || is_all_zero(nt[:]) {
		return .Zero_Nonce
	}
	if constant_time_equal(nc[:], nt[:]) {
		return .Replayed_Nonce
	}

	next: Salted_Session
	next.initialized = true
	next.cipher = checked_cipher
	next.nonce_caller = nc
	next.nonce_tpm = nt
	next.auth_value_length = u8(len(auth_value))
	if len(auth_value) > 0 {
		copy(next.auth_value[:len(auth_value)], auth_value)
	}

	// TPM 2.0 Part 1 sessionKey = KDFa(salt, "ATH", nonceTPM, nonceCaller, 256).
	if refusal := kdfa_sha256(salt_secret, "ATH", nt[:], nc[:], 256, next.session_key[:]); refusal != .None {
		salted_session_wipe(&next)
		return refusal
	}

	// Derive initial command symmetric key and IV.
	enc_key, iv, sym_refusal := salted_session_derive_sym_keys(&next, .Command)
	if sym_refusal != .None {
		salted_session_wipe(&next)
		return sym_refusal
	}
	next.encrypt_key = enc_key
	next.iv = iv
	zero_bytes(enc_key[:])
	zero_bytes(iv[:])

	session^ = next
	salted_session_wipe(&next)
	return .None
}

// salted_session_derive_sym_keys derives the 128-bit AES key and 128-bit IV
// for a command or response using KDFa(sessionKey || authValue, "CFB",
// nonceNewer, nonceOlder, 256).
salted_session_derive_sym_keys :: proc "contextless" (
	session: ^Salted_Session,
	direction: Session_Direction,
) -> (encrypt_key: [AES128_KEY_SIZE]u8, iv: [AES128_BLOCK_SIZE]u8, refusal: Session_Refusal) {
	if !session.initialized {
		return {}, {}, .Not_Initialized
	}
	checked_dir, dir_ok := session_direction_of_word(u64(direction))
	if !dir_ok {
		return {}, {}, .Bad_Direction
	}

	composite: [SHA256_SIZE * 2]u8
	key_len := build_composite_hmac_key(session, &composite)
	defer zero_bytes(composite[:])

	nonce_newer, nonce_older: [NONCE_SIZE]u8
	switch checked_dir {
	case .Command:
		nonce_newer = session.nonce_caller
		nonce_older = session.nonce_tpm
	case .Response:
		nonce_newer = session.nonce_tpm
		nonce_older = session.nonce_caller
	}

	material: [AES128_KEY_SIZE + AES128_BLOCK_SIZE]u8
	defer zero_bytes(material[:])
	if kdf_refusal := kdfa_sha256(composite[:key_len], "CFB", nonce_newer[:], nonce_older[:], 256, material[:]); kdf_refusal != .None {
		return {}, {}, kdf_refusal
	}
	copy(encrypt_key[:], material[:AES128_KEY_SIZE])
	copy(iv[:], material[AES128_KEY_SIZE:])
	return encrypt_key, iv, .None
}

@(private)
salted_session_xor_stream :: proc "contextless" (
	session: ^Salted_Session,
	direction: Session_Direction,
	input: []u8,
	output: []u8,
) -> Session_Refusal {
	composite: [SHA256_SIZE * 2]u8
	key_len := build_composite_hmac_key(session, &composite)
	defer zero_bytes(composite[:])

	nonce_newer, nonce_older: [NONCE_SIZE]u8
	switch direction {
	case .Command:
		nonce_newer = session.nonce_caller
		nonce_older = session.nonce_tpm
	case .Response:
		nonce_newer = session.nonce_tpm
		nonce_older = session.nonce_caller
	}

	mask_buf: [MAX_PARAMETER_BYTES]u8
	defer zero_bytes(mask_buf[:len(input)])
	bits := u32(len(input)) * 8
	if kdf_refusal := kdfa_sha256(composite[:key_len], "XOR", nonce_newer[:], nonce_older[:], bits, mask_buf[:len(input)]); kdf_refusal != .None {
		return kdf_refusal
	}
	for i in 0 ..< len(input) {
		output[i] = input[i] ~ mask_buf[i]
	}
	return .None
}

// salted_session_encrypt_parameter encrypts a command or response parameter
// payload using the session's configured cipher (AES-128-CFB or KDFa XOR).
salted_session_encrypt_parameter :: proc "contextless" (
	session: ^Salted_Session,
	direction: Session_Direction,
	plaintext: []u8,
	ciphertext: []u8,
) -> Session_Refusal {
	if !session.initialized {
		return .Not_Initialized
	}
	checked_dir, dir_ok := session_direction_of_word(u64(direction))
	if !dir_ok {
		return .Bad_Direction
	}
	if len(plaintext) == 0 {
		return .Empty_Parameter
	}
	if len(plaintext) > MAX_PARAMETER_BYTES {
		return .Parameter_Too_Large
	}
	if len(ciphertext) < len(plaintext) {
		return .Buffer_Too_Small
	}

	switch session.cipher {
	case .Aes_128_Cfb:
		key, iv, refusal := salted_session_derive_sym_keys(session, checked_dir)
		if refusal != .None {
			return refusal
		}
		defer zero_bytes(key[:])
		defer zero_bytes(iv[:])
		aes128_cfb_encrypt(key, iv, plaintext, ciphertext[:len(plaintext)])
		return .None
	case .Xor_Sha256:
		return salted_session_xor_stream(session, checked_dir, plaintext, ciphertext[:len(plaintext)])
	}
	return .Bad_Cipher
}

// salted_session_decrypt_parameter decrypts a command or response parameter
// payload using the session's configured cipher.
salted_session_decrypt_parameter :: proc "contextless" (
	session: ^Salted_Session,
	direction: Session_Direction,
	ciphertext: []u8,
	plaintext: []u8,
) -> Session_Refusal {
	if !session.initialized {
		return .Not_Initialized
	}
	checked_dir, dir_ok := session_direction_of_word(u64(direction))
	if !dir_ok {
		return .Bad_Direction
	}
	if len(ciphertext) == 0 {
		return .Empty_Parameter
	}
	if len(ciphertext) > MAX_PARAMETER_BYTES {
		return .Parameter_Too_Large
	}
	if len(plaintext) < len(ciphertext) {
		return .Buffer_Too_Small
	}

	switch session.cipher {
	case .Aes_128_Cfb:
		key, iv, refusal := salted_session_derive_sym_keys(session, checked_dir)
		if refusal != .None {
			return refusal
		}
		defer zero_bytes(key[:])
		defer zero_bytes(iv[:])
		aes128_cfb_decrypt(key, iv, ciphertext, plaintext[:len(ciphertext)])
		return .None
	case .Xor_Sha256:
		return salted_session_xor_stream(session, checked_dir, ciphertext, plaintext[:len(ciphertext)])
	}
	return .Bad_Cipher
}

// compute_cp_hash computes the command parameter hash:
// SHA-256(be32(command_code) || handle_name_0 || ... || parameters).
compute_cp_hash :: proc "contextless" (command_code: u32, handle_names: [][]u8, parameters: []u8) -> Digest {
	ctx: Sha256_State
	sha256_init(&ctx)
	sha256_update_u32_be(&ctx, command_code)
	for name in handle_names {
		sha256_update(&ctx, name)
	}
	sha256_update(&ctx, parameters)
	return sha256_final(&ctx)
}

// compute_rp_hash computes the response parameter hash:
// SHA-256(be32(response_code) || be32(command_code) || parameters).
compute_rp_hash :: proc "contextless" (response_code: u32, command_code: u32, parameters: []u8) -> Digest {
	ctx: Sha256_State
	sha256_init(&ctx)
	sha256_update_u32_be(&ctx, response_code)
	sha256_update_u32_be(&ctx, command_code)
	sha256_update(&ctx, parameters)
	return sha256_final(&ctx)
}

// salted_session_command_hmac computes the TPM 2.0 authorization HMAC over a
// command: HMAC-SHA-256(sessionKey || authValue, cpHash || nonceCaller ||
// nonceTPM || sessionAttributes).
salted_session_command_hmac :: proc "contextless" (
	session: ^Salted_Session,
	cp_hash: Digest,
	attributes: Session_Attributes,
) -> (mac: Digest, refusal: Session_Refusal) {
	if !session.initialized {
		return {}, .Not_Initialized
	}
	composite: [SHA256_SIZE * 2]u8
	key_len := build_composite_hmac_key(session, &composite)
	defer zero_bytes(composite[:])

	cp := cp_hash
	attr_byte := [1]u8{transmute(u8)attributes}
	ctx: Hmac_Sha256_State
	hmac_sha256_init(&ctx, composite[:key_len])
	hmac_sha256_update(&ctx, cp[:])
	hmac_sha256_update(&ctx, session.nonce_caller[:])
	hmac_sha256_update(&ctx, session.nonce_tpm[:])
	hmac_sha256_update(&ctx, attr_byte[:])
	return hmac_sha256_final(&ctx), .None
}

// salted_session_verify_command_hmac verifies a command authorization HMAC in
// constant time.
salted_session_verify_command_hmac :: proc "contextless" (
	session: ^Salted_Session,
	cp_hash: Digest,
	attributes: Session_Attributes,
	candidate_mac: Digest,
) -> Session_Refusal {
	expected, refusal := salted_session_command_hmac(session, cp_hash, attributes)
	if refusal != .None {
		return refusal
	}
	defer zero_bytes(expected[:])
	candidate := candidate_mac
	if !constant_time_equal(expected[:], candidate[:]) {
		return .Hmac_Mismatch
	}
	return .None
}

// salted_session_response_hmac computes the TPM 2.0 authorization HMAC over a
// response: HMAC-SHA-256(sessionKey || authValue, rpHash || nonceTPM ||
// nonceCaller || sessionAttributes).
salted_session_response_hmac :: proc "contextless" (
	session: ^Salted_Session,
	rp_hash: Digest,
	attributes: Session_Attributes,
) -> (mac: Digest, refusal: Session_Refusal) {
	if !session.initialized {
		return {}, .Not_Initialized
	}
	composite: [SHA256_SIZE * 2]u8
	key_len := build_composite_hmac_key(session, &composite)
	defer zero_bytes(composite[:])

	rp := rp_hash
	attr_byte := [1]u8{transmute(u8)attributes}
	ctx: Hmac_Sha256_State
	hmac_sha256_init(&ctx, composite[:key_len])
	hmac_sha256_update(&ctx, rp[:])
	hmac_sha256_update(&ctx, session.nonce_tpm[:])
	hmac_sha256_update(&ctx, session.nonce_caller[:])
	hmac_sha256_update(&ctx, attr_byte[:])
	return hmac_sha256_final(&ctx), .None
}

// salted_session_verify_response_hmac verifies a response authorization HMAC
// in constant time.
salted_session_verify_response_hmac :: proc "contextless" (
	session: ^Salted_Session,
	rp_hash: Digest,
	attributes: Session_Attributes,
	candidate_mac: Digest,
) -> Session_Refusal {
	expected, refusal := salted_session_response_hmac(session, rp_hash, attributes)
	if refusal != .None {
		return refusal
	}
	defer zero_bytes(expected[:])
	candidate := candidate_mac
	if !constant_time_equal(expected[:], candidate[:]) {
		return .Hmac_Mismatch
	}
	return .None
}

// salted_session_roll_caller_nonce advances nonce_caller before sending the
// next command. Refuses zero nonces and replayed nonces without mutating state.
salted_session_roll_caller_nonce :: proc "contextless" (
	session: ^Salted_Session,
	next_nonce_caller: [NONCE_SIZE]u8,
) -> Session_Refusal {
	if !session.initialized {
		return .Not_Initialized
	}
	nc := next_nonce_caller
	if is_all_zero(nc[:]) {
		return .Zero_Nonce
	}
	if constant_time_equal(nc[:], session.nonce_caller[:]) || constant_time_equal(nc[:], session.nonce_tpm[:]) {
		return .Replayed_Nonce
	}
	previous_nonce := session.nonce_caller
	session.nonce_caller = nc
	enc_key, iv, refusal := salted_session_derive_sym_keys(session, .Command)
	if refusal != .None {
		session.nonce_caller = previous_nonce
		return refusal
	}
	session.encrypt_key = enc_key
	session.iv = iv
	session.command_counter += 1
	zero_bytes(enc_key[:])
	zero_bytes(iv[:])
	return .None
}

// salted_session_roll_tpm_nonce advances nonce_tpm after receiving a TPM
// response. Refuses zero nonces and replayed nonces without mutating state.
salted_session_roll_tpm_nonce :: proc "contextless" (
	session: ^Salted_Session,
	next_nonce_tpm: [NONCE_SIZE]u8,
) -> Session_Refusal {
	if !session.initialized {
		return .Not_Initialized
	}
	nt := next_nonce_tpm
	if is_all_zero(nt[:]) {
		return .Zero_Nonce
	}
	if constant_time_equal(nt[:], session.nonce_tpm[:]) || constant_time_equal(nt[:], session.nonce_caller[:]) {
		return .Replayed_Nonce
	}
	previous_nonce := session.nonce_tpm
	session.nonce_tpm = nt
	enc_key, iv, refusal := salted_session_derive_sym_keys(session, .Response)
	if refusal != .None {
		session.nonce_tpm = previous_nonce
		return refusal
	}
	session.encrypt_key = enc_key
	session.iv = iv
	zero_bytes(enc_key[:])
	zero_bytes(iv[:])
	return .None
}

// salted_session_wipe erases all secret keys and nonces from session memory.
salted_session_wipe :: proc "contextless" (session: ^Salted_Session) {
	session.initialized = false
	zero_bytes(session.session_key[:])
	zero_bytes(session.auth_value[:])
	session.auth_value_length = 0
	zero_bytes(session.nonce_caller[:])
	zero_bytes(session.nonce_tpm[:])
	zero_bytes(session.encrypt_key[:])
	zero_bytes(session.iv[:])
	session.command_counter = 0
}
