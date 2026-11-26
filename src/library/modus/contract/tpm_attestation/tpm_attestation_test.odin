#+build !freestanding
#+build !modus
package tpm_attestation

import "core:crypto/aes"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:testing"
import "modus:contract/byte_order"

@(private = "file")
make_filled_nonce :: proc(seed: u8) -> (out: [NONCE_SIZE]u8) {
	for i in 0 ..< NONCE_SIZE {
		out[i] = seed ~ u8(i * 13 + 7)
	}
	return out
}

@(private = "file")
make_digest :: proc(seed: u8) -> (out: Digest) {
	for i in 0 ..< SHA256_SIZE {
		out[i] = seed + u8(i * 5 + 1)
	}
	return out
}

// Verify inline SHA-256 and HMAC-SHA-256 against NIST/RFC vectors and Odin's core:crypto.
@(test)
sha256_and_hmac_match_standard_vectors :: proc(t: ^testing.T) {
	// Empty input FIPS 180-4 SHA-256 vector.
	empty_got := sha256_sum(nil)
	empty_ref: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, nil, empty_ref[:])
	testing.expect_value(t, empty_got, Digest(empty_ref))

	// Exact block boundary (64 bytes), 55 bytes, 56 bytes, 128 bytes, and streaming chunks.
	lengths := [?]int{1, 3, 55, 56, 63, 64, 65, 119, 120, 128, 257}
	for n in lengths {
		buf: [300]u8
		for i in 0 ..< n {
			buf[i] = u8((i * 37 + 11) & 0xFF)
		}
		got := sha256_sum(buf[:n])
		ref: [32]u8
		hash.hash_bytes_to_buffer(.SHA256, buf[:n], ref[:])
		testing.expect_value(t, got, Digest(ref))

		// Streaming 7-byte chunks must match single-shot.
		ctx: Sha256_State
		sha256_init(&ctx)
		for pos := 0; pos < n; pos += 7 {
			end := min(pos + 7, n)
			sha256_update(&ctx, buf[pos:end])
		}
		streamed := sha256_final(&ctx)
		testing.expect_value(t, streamed, got)
	}

	// RFC 4231 HMAC-SHA-256 test case 2 (key = "Jefe", data = "what do ya want for nothing?")
	// plus long key (> 64 bytes) cross-checked against core:crypto/hmac.
	key_short := transmute([]u8)string("Jefe")
	msg_short := transmute([]u8)string("what do ya want for nothing?")
	mac_got := hmac_sha256(key_short, msg_short)
	mac_ref: [32]u8
	hmac.sum(.SHA256, mac_ref[:], msg_short, key_short)
	testing.expect_value(t, mac_got, Digest(mac_ref))

	key_long: [131]u8
	for i in 0 ..< len(key_long) {
		key_long[i] = 0xAA
	}
	mac_long_got := hmac_sha256(key_long[:], msg_short)
	mac_long_ref: [32]u8
	hmac.sum(.SHA256, mac_long_ref[:], msg_short, key_long[:])
	testing.expect_value(t, mac_long_got, Digest(mac_long_ref))
}

// Verify constant-time algebraic AES-128 and AES-128-CFB against FIPS 197 and core:crypto/aes.
@(test)
aes128_and_cfb_match_fips197_and_sp800_38a :: proc(t: ^testing.T) {
	// FIPS 197 Appendix B test vector.
	key := [16]u8{
		0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
		0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C,
	}
	plain := [16]u8{
		0x32, 0x43, 0xF6, 0xA8, 0x88, 0x5A, 0x30, 0x8D,
		0x31, 0x31, 0x98, 0xA2, 0xE0, 0x37, 0x07, 0x34,
	}
	expected := [16]u8{
		0x39, 0x25, 0x84, 0x1D, 0x02, 0xDC, 0x09, 0xFB,
		0xDC, 0x11, 0x85, 0x97, 0x19, 0x6A, 0x0B, 0x32,
	}
	got := aes128_encrypt_block(key, plain)
	testing.expect_value(t, got, expected)

	// Cross-check against core:crypto/aes ECB block.
	ecb: aes.Context_ECB
	aes.init_ecb(&ecb, key[:])
	ref_out: [16]u8
	aes.encrypt_ecb(&ecb, ref_out[:], plain[:])
	testing.expect_value(t, got, ref_out)

	// NIST SP 800-38A F.3.13 CFB128-AES128.Encrypt first 32 bytes.
	iv := [16]u8{
		0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
		0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
	}
	pt_cfb := [32]u8{
		0x6B, 0xC1, 0xBE, 0xE2, 0x2E, 0x40, 0x9F, 0x96,
		0xE9, 0x3D, 0x7E, 0x11, 0x73, 0x93, 0x17, 0x2A,
		0xAE, 0x2D, 0x8A, 0x57, 0x1E, 0x03, 0xAC, 0x9C,
		0x9E, 0xB7, 0x6F, 0xAC, 0x45, 0xAF, 0x8E, 0x51,
	}
	ct_expected := [32]u8{
		0x3B, 0x3F, 0xD9, 0x2E, 0xB7, 0x2D, 0xAD, 0x20,
		0x33, 0x34, 0x49, 0xF8, 0xE8, 0x3C, 0xFB, 0x4A,
		0xC8, 0xA6, 0x45, 0x37, 0xA0, 0xB3, 0xA9, 0x3F,
		0xCD, 0xE3, 0xCD, 0xAD, 0x9F, 0x1C, 0xE5, 0x8B,
	}
	ct: [32]u8
	aes128_cfb_encrypt(key, iv, pt_cfb[:], ct[:])
	testing.expect_value(t, ct, ct_expected)

	// Decrypt back including non-block-aligned partial length (23 bytes) and in-place.
	rt: [32]u8
	aes128_cfb_decrypt(key, iv, ct[:23], rt[:23])
	testing.expect(t, constant_time_equal(rt[:23], pt_cfb[:23]), "partial CFB round-trip must match")
	copy(rt[:], ct[:])
	aes128_cfb_decrypt(key, iv, rt[:], rt[:])
	testing.expect_value(t, rt, pt_cfb)
}

// Adversarial tests for KDFa and Salted_Session initialization, parameter
// encryption (AES-128-CFB and XOR), cpHash/rpHash HMAC verification, and nonce rolling.
@(test)
salted_session_refusals_and_roundtrip :: proc(t: ^testing.T) {
	// Enum borders refuse unknown transport words.
	_, bad_c := session_cipher_of_word(0)
	testing.expect(t, !bad_c, "0 is not a valid Session_Cipher")
	_, bad_c2 := session_cipher_of_word(0xFFFF)
	testing.expect(t, !bad_c2, "0xFFFF is not a valid Session_Cipher")
	_, bad_d := session_direction_of_word(0)
	testing.expect(t, !bad_d, "0 is not a valid Session_Direction")
	_, bad_d2 := session_direction_of_word(3)
	testing.expect(t, !bad_d2, "3 is not a valid Session_Direction")

	// KDFa edge refusals with zero-mutation guarantee.
	sentinel_out := [32]u8{0 ..< 32 = 0xCC}
	out := sentinel_out
	salt := [32]u8{0 ..< 32 = 0x5A}
	zero_salt: [32]u8
	testing.expect_value(t, kdfa_sha256(nil, "ATH", nil, nil, 256, out[:]), Session_Refusal.Zero_Salt)
	testing.expect_value(t, kdfa_sha256(zero_salt[:], "ATH", nil, nil, 256, out[:]), Session_Refusal.Zero_Salt)
	testing.expect_value(t, kdfa_sha256(salt[:], "", nil, nil, 256, out[:]), Session_Refusal.Empty_Label)
	testing.expect_value(t, kdfa_sha256(salt[:], "ATH", nil, nil, 0, out[:]), Session_Refusal.Invalid_Bit_Count)
	testing.expect_value(t, kdfa_sha256(salt[:], "ATH", nil, nil, 255, out[:]), Session_Refusal.Invalid_Bit_Count)
	testing.expect_value(t, kdfa_sha256(salt[:], "ATH", nil, nil, 256, out[:31]), Session_Refusal.Buffer_Too_Small)
	testing.expect_value(t, out, sentinel_out)

	// Uninitialized session refuses every operation.
	uninit: Salted_Session
	dummy := [16]u8{0 ..< 16 = 0x11}
	dummy_out: [16]u8
	_, _, r_sym := salted_session_derive_sym_keys(&uninit, .Command)
	testing.expect_value(t, r_sym, Session_Refusal.Not_Initialized)
	testing.expect_value(t, salted_session_encrypt_parameter(&uninit, .Command, dummy[:], dummy_out[:]), Session_Refusal.Not_Initialized)
	testing.expect_value(t, salted_session_decrypt_parameter(&uninit, .Command, dummy[:], dummy_out[:]), Session_Refusal.Not_Initialized)
	_, r_cmac := salted_session_command_hmac(&uninit, {}, {.Continue_Session})
	testing.expect_value(t, r_cmac, Session_Refusal.Not_Initialized)
	testing.expect_value(t, salted_session_roll_caller_nonce(&uninit, make_filled_nonce(1)), Session_Refusal.Not_Initialized)
	testing.expect_value(t, salted_session_roll_tpm_nonce(&uninit, make_filled_nonce(2)), Session_Refusal.Not_Initialized)

	// Init refusals: bad cipher, zero salt, oversize salt, oversize auth, zero nonces, identical nonces.
	nc := make_filled_nonce(0x11)
	nt := make_filled_nonce(0x22)
	zero_nonce: [NONCE_SIZE]u8
	oversize_salt: [MAX_SALT_SIZE + 1]u8
	oversize_salt[0] = 1
	oversize_auth: [SHA256_SIZE + 1]u8
	oversize_auth[0] = 1

	s: Salted_Session
	testing.expect_value(t, salted_session_init(&s, Session_Cipher(0x1234), salt[:], nil, nc, nt), Session_Refusal.Bad_Cipher)
	testing.expect_value(t, salted_session_init(&s, .Aes_128_Cfb, zero_salt[:], nil, nc, nt), Session_Refusal.Zero_Salt)
	testing.expect_value(t, salted_session_init(&s, .Aes_128_Cfb, oversize_salt[:], nil, nc, nt), Session_Refusal.Salt_Too_Long)
	testing.expect_value(t, salted_session_init(&s, .Aes_128_Cfb, salt[:], oversize_auth[:], nc, nt), Session_Refusal.Auth_Value_Too_Long)
	testing.expect_value(t, salted_session_init(&s, .Aes_128_Cfb, salt[:], nil, zero_nonce, nt), Session_Refusal.Zero_Nonce)
	testing.expect_value(t, salted_session_init(&s, .Aes_128_Cfb, salt[:], nil, nc, zero_nonce), Session_Refusal.Zero_Nonce)
	testing.expect_value(t, salted_session_init(&s, .Aes_128_Cfb, salt[:], nil, nc, nc), Session_Refusal.Replayed_Nonce)
	testing.expect(t, !s.initialized, "refused init must leave session uninitialized")

	// Valid init for both ciphers: AES-128-CFB and XOR-SHA256.
	auth := [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	for cipher in Session_Cipher {
		sess: Salted_Session
		testing.expect_value(t, salted_session_init(&sess, cipher, salt[:], auth[:], nc, nt), Session_Refusal.None)
		testing.expect(t, sess.initialized, "session must be initialized")

		secret := [37]u8{0 ..< 37 = 0xAB}
		secret[0] = 0xDE
		secret[36] = 0xEF
		encrypted: [37]u8
		decrypted: [37]u8

		// Refusals on empty parameter, undersized output, bad direction.
		testing.expect_value(t, salted_session_encrypt_parameter(&sess, .Command, nil, encrypted[:]), Session_Refusal.Empty_Parameter)
		testing.expect_value(t, salted_session_encrypt_parameter(&sess, .Command, secret[:], encrypted[:36]), Session_Refusal.Buffer_Too_Small)
		testing.expect_value(t, salted_session_encrypt_parameter(&sess, Session_Direction(9), secret[:], encrypted[:]), Session_Refusal.Bad_Direction)

		// Command direction round-trip.
		testing.expect_value(t, salted_session_encrypt_parameter(&sess, .Command, secret[:], encrypted[:]), Session_Refusal.None)
		testing.expect(t, !constant_time_equal(secret[:], encrypted[:]), "ciphertext must differ from plaintext")
		testing.expect_value(t, salted_session_decrypt_parameter(&sess, .Command, encrypted[:], decrypted[:]), Session_Refusal.None)
		testing.expect_value(t, decrypted, secret)

		// Cross-direction decryption must NOT recover plaintext.
		wrong_dir: [37]u8
		testing.expect_value(t, salted_session_decrypt_parameter(&sess, .Response, encrypted[:], wrong_dir[:]), Session_Refusal.None)
		testing.expect(t, !constant_time_equal(wrong_dir[:], secret[:]), "response key must differ from command key")

		// cpHash / rpHash HMAC generation, verification, and 1-bit tamper refusal.
		handle_name := [34]u8{0 = 0x00, 1 = 0x0B, 2 ..< 34 = 0x42}
		handles := [1][]u8{handle_name[:]}
		cp := compute_cp_hash(0x0000_015E, handles[:], encrypted[:])
		attrs := Session_Attributes{.Continue_Session, .Decrypt, .Encrypt}
		cmac, r_c := salted_session_command_hmac(&sess, cp, attrs)
		testing.expect_value(t, r_c, Session_Refusal.None)
		testing.expect_value(t, salted_session_verify_command_hmac(&sess, cp, attrs, cmac), Session_Refusal.None)

		tampered_cmac := cmac
		tampered_cmac[31] ~= 0x01
		testing.expect_value(t, salted_session_verify_command_hmac(&sess, cp, attrs, tampered_cmac), Session_Refusal.Hmac_Mismatch)
		testing.expect_value(t, salted_session_verify_command_hmac(&sess, cp, {.Continue_Session}, cmac), Session_Refusal.Hmac_Mismatch)

		rp := compute_rp_hash(0, 0x0000_015E, encrypted[:])
		rmac, r_r := salted_session_response_hmac(&sess, rp, attrs)
		testing.expect_value(t, r_r, Session_Refusal.None)
		testing.expect_value(t, salted_session_verify_response_hmac(&sess, rp, attrs, rmac), Session_Refusal.None)
		tampered_rmac := rmac
		tampered_rmac[0] ~= 0x80
		testing.expect_value(t, salted_session_verify_response_hmac(&sess, rp, attrs, tampered_rmac), Session_Refusal.Hmac_Mismatch)

		// Nonce rolling refuses zero and replayed nonces without mutation.
		saved_key := sess.encrypt_key
		testing.expect_value(t, salted_session_roll_caller_nonce(&sess, zero_nonce), Session_Refusal.Zero_Nonce)
		testing.expect_value(t, salted_session_roll_caller_nonce(&sess, nc), Session_Refusal.Replayed_Nonce)
		testing.expect_value(t, salted_session_roll_caller_nonce(&sess, nt), Session_Refusal.Replayed_Nonce)
		testing.expect_value(t, sess.encrypt_key, saved_key)
		testing.expect_value(t, sess.command_counter, u64(0))

		nc2 := make_filled_nonce(0x33)
		testing.expect_value(t, salted_session_roll_caller_nonce(&sess, nc2), Session_Refusal.None)
		testing.expect_value(t, sess.command_counter, u64(1))
		testing.expect(t, !constant_time_equal(sess.encrypt_key[:], saved_key[:]), "rolling caller nonce must rotate encrypt_key")

		// Old command HMAC must now fail under rolled nonce.
		testing.expect_value(t, salted_session_verify_command_hmac(&sess, cp, attrs, cmac), Session_Refusal.Hmac_Mismatch)

		nt2 := make_filled_nonce(0x44)
		testing.expect_value(t, salted_session_roll_tpm_nonce(&sess, zero_nonce), Session_Refusal.Zero_Nonce)
		testing.expect_value(t, salted_session_roll_tpm_nonce(&sess, nt), Session_Refusal.Replayed_Nonce)
		testing.expect_value(t, salted_session_roll_tpm_nonce(&sess, nc2), Session_Refusal.Replayed_Nonce)
		testing.expect_value(t, salted_session_roll_tpm_nonce(&sess, nt2), Session_Refusal.None)

		// Wipe clears all secrets.
		salted_session_wipe(&sess)
		testing.expect(t, !sess.initialized, "wiped session must be uninitialized")
		testing.expect(t, is_all_zero(sess.session_key[:]), "session_key must be zeroed")
		testing.expect(t, is_all_zero(sess.encrypt_key[:]), "encrypt_key must be zeroed")
		testing.expect(t, is_all_zero(sess.iv[:]), "iv must be zeroed")
	}
}

@(private = "file")
test_quote_sig_verify :: proc "contextless" (attest_bytes: []u8, attest_digest: Digest, signature: []u8, user_data: rawptr) -> bool {
	if user_data == nil || len(signature) != SHA256_SIZE {
		return false
	}
	secret_key := (^[32]u8)(user_data)
	// Verify that attest_digest matches SHA-256(attest_bytes) and signature == HMAC(secret_key, attest_digest).
	computed := sha256_sum(attest_bytes)
	ad := attest_digest
	if !constant_time_equal(computed[:], ad[:]) {
		return false
	}
	expected_sig := hmac_sha256(secret_key[:], ad[:])
	return constant_time_equal(expected_sig[:], signature)
}

// Exhaustive adversarial tests for TPMS_ATTEST quote parsing and verification.
@(test)
quote_verify_refuses_every_malformed_input_and_accepts_valid_quote :: proc(t: ^testing.T) {
	nonce := make_filled_nonce(0x77)
	zero_nonce: [QUOTE_NONCE_SIZE]u8
	signer := [34]u8{0 = 0x00, 1 = 0x0B, 2 ..< 34 = 0x3C}
	expected_pcrs := Expected_Pcr_Values {
		pcr7_secure_boot     = make_digest(0x07),
		pcr11_system_measure = make_digest(0x11),
		pcr12_start_policy   = make_digest(0x12),
	}
	pcr_digest := compute_expected_pcr_digest(expected_pcrs)
	clock := Clock_Info{clock = 987654321, reset_count = 4, restart_count = 2, safe = true}
	fw_ver := u64(0x2026_0001_0002_0003)

	quote_buf: [256]u8
	quote_len, build_refusal := build_tpms_attest_quote(
		signer[:], nonce, clock, fw_ver, REQUIRED_PCR_MASK, 3, pcr_digest, quote_buf[:],
	)
	testing.expect_value(t, build_refusal, Quote_Refusal.None)
	valid_quote := quote_buf[:quote_len]

	ak_key := [32]u8{0 ..< 32 = 0x99}
	attest_digest := sha256_sum(valid_quote)
	valid_sig := hmac_sha256(ak_key[:], attest_digest[:])

	// 1. Missing verifier or empty signature.
	_, r := verify_attestation_quote(valid_quote, valid_sig[:], nonce, expected_pcrs, nil, &ak_key)
	testing.expect_value(t, r, Quote_Refusal.Missing_Verifier)
	_, r = verify_attestation_quote(valid_quote, nil, nonce, expected_pcrs, test_quote_sig_verify, &ak_key)
	testing.expect_value(t, r, Quote_Refusal.Signature_Invalid)

	// 2. Zero expected nonce refused.
	_, r = verify_attestation_quote(valid_quote, valid_sig[:], zero_nonce, expected_pcrs, test_quote_sig_verify, &ak_key)
	testing.expect_value(t, r, Quote_Refusal.Zero_Expected_Nonce)

	// 3. Truncation at EVERY byte offset from 0 to quote_len - 1.
	for cut in 0 ..< quote_len {
		_, tr := parse_tpms_attest_quote(valid_quote[:cut], nonce)
		testing.expect(t, tr != .None, "truncated TPMS_ATTEST must be refused")
	}

	// 4. Trailing byte refused.
	trailing_buf: [256]u8
	copy(trailing_buf[:quote_len], valid_quote)
	trailing_buf[quote_len] = 0x00
	_, r = parse_tpms_attest_quote(trailing_buf[:quote_len + 1], nonce)
	testing.expect_value(t, r, Quote_Refusal.Trailing_Bytes)

	// 5. Wrong magic.
	bad_magic := quote_buf
	bad_magic[0] ~= 0x01
	_, r = parse_tpms_attest_quote(bad_magic[:quote_len], nonce)
	testing.expect_value(t, r, Quote_Refusal.Bad_Magic)

	// 6. Wrong attest type (e.g. TPM_ST_ATTEST_CERTIFY = 0x8017).
	bad_type := quote_buf
	byte_order.write_u16_big_endian(bad_type[:], 4, 0x8017)
	_, r = parse_tpms_attest_quote(bad_type[:quote_len], nonce)
	testing.expect_value(t, r, Quote_Refusal.Bad_Attest_Type)

	// 7. Mismatched nonce.
	wrong_nonce := nonce
	wrong_nonce[15] ~= 0x01
	_, r = verify_attestation_quote(valid_quote, valid_sig[:], wrong_nonce, expected_pcrs, test_quote_sig_verify, &ak_key)
	testing.expect_value(t, r, Quote_Refusal.Nonce_Mismatch)

	// 8. Missing each required PCR individually (missing PCR 7, missing PCR 11, missing PCR 12).
	missing_masks := [3]u32{
		(1 << 11) | (1 << 12),
		(1 << 7) | (1 << 12),
		(1 << 7) | (1 << 11),
	}
	for mask in missing_masks {
		bad_pcr_buf: [256]u8
		n, br := build_tpms_attest_quote(signer[:], nonce, clock, fw_ver, mask, 3, pcr_digest, bad_pcr_buf[:])
		testing.expect_value(t, br, Quote_Refusal.None)
		_, pr := parse_tpms_attest_quote(bad_pcr_buf[:n], nonce)
		testing.expect_value(t, pr, Quote_Refusal.Missing_Required_Pcrs)
	}

	// 9. Extra unexpected PCR selected (PCR 0 in addition to 7, 11, 12).
	extra_pcr_buf: [256]u8
	en, ebr := build_tpms_attest_quote(signer[:], nonce, clock, fw_ver, REQUIRED_PCR_MASK | (1 << 0), 3, pcr_digest, extra_pcr_buf[:])
	testing.expect_value(t, ebr, Quote_Refusal.None)
	_, epr := parse_tpms_attest_quote(extra_pcr_buf[:en], nonce)
	testing.expect_value(t, epr, Quote_Refusal.Unexpected_Pcr_Selected)

	// 10. Invalid clockInfo.safe byte (2 instead of 0/1).
	bad_safe := quote_buf
	safe_offset := 4 + 2 + 2 + len(signer) + 2 + QUOTE_NONCE_SIZE + 8 + 4 + 4
	bad_safe[safe_offset] = 2
	_, r = parse_tpms_attest_quote(bad_safe[:quote_len], nonce)
	testing.expect_value(t, r, Quote_Refusal.Bad_Clock_Safe_Flag)

	// 11. Wrong PCR bank algorithm (SHA-1 = 0x0004 instead of SHA-256 = 0x000B).
	bad_alg := quote_buf
	alg_offset := safe_offset + 1 + 8 + 4
	byte_order.write_u16_big_endian(bad_alg[:], alg_offset, 0x0004)
	_, r = parse_tpms_attest_quote(bad_alg[:quote_len], nonce)
	testing.expect_value(t, r, Quote_Refusal.Unsupported_Hash_Algorithm)

	// 12. Mismatched expected PCR digest (e.g. altered PCR 11 system description).
	wrong_pcrs := expected_pcrs
	wrong_pcrs.pcr11_system_measure[0] ~= 0xFF
	_, r = verify_attestation_quote(valid_quote, valid_sig[:], nonce, wrong_pcrs, test_quote_sig_verify, &ak_key)
	testing.expect_value(t, r, Quote_Refusal.Pcr_Digest_Mismatch)

	// 13. Signature callback failure (1-bit signature tamper).
	bad_sig := valid_sig
	bad_sig[0] ~= 0x01
	_, r = verify_attestation_quote(valid_quote, bad_sig[:], nonce, expected_pcrs, test_quote_sig_verify, &ak_key)
	testing.expect_value(t, r, Quote_Refusal.Signature_Invalid)

	// 14. Valid quote passes and preserves exact parsed fields.
	parsed, ok_refusal := verify_attestation_quote(valid_quote, valid_sig[:], nonce, expected_pcrs, test_quote_sig_verify, &ak_key)
	testing.expect_value(t, ok_refusal, Quote_Refusal.None)
	testing.expect_value(t, parsed.qualified_signer_length, u16(len(signer)))
	testing.expect_value(t, parsed.extra_data, nonce)
	testing.expect_value(t, parsed.clock_info, clock)
	testing.expect_value(t, parsed.firmware_version, fw_ver)
	testing.expect_value(t, parsed.pcr_mask, REQUIRED_PCR_MASK)
	testing.expect_value(t, parsed.pcr_digest, pcr_digest)
}

@(private = "file")
test_policy_sig_verify :: proc "contextless" (publisher_key_digest: Digest, approval_digest: Digest, signature: []u8, user_data: rawptr) -> bool {
	if user_data == nil || len(signature) != SHA256_SIZE {
		return false
	}
	pub_secret := (^[32]u8)(user_data)
	ah := approval_digest
	expected := hmac_sha256(pub_secret[:], ah[:])
	// Also confirm the publisher key digest matches the key under test.
	expected_key_digest := sha256_sum(pub_secret[:])
	pk := publisher_key_digest
	if !constant_time_equal(pk[:], expected_key_digest[:]) {
		return false
	}
	return constant_time_equal(expected[:], signature)
}

// Exhaustive adversarial tests for monotonic disk-grant-table counter and
// TPM2_PolicyAuthorize publisher-key floor policy verification.
@(test)
rollback_floor_counter_and_policy_authorize :: proc(t: ^testing.T) {
	pub_secret := [32]u8{0 ..< 32 = 0x5E}
	pub_digest := sha256_sum(pub_secret[:])
	zero_digest: Digest

	// Init refusals: zero key, out-of-range floors (> 64).
	state: Rollback_Floor_State
	testing.expect_value(t, rollback_floor_init(&state, zero_digest, 0, 1, 1), Rollback_Refusal.Zero_Publisher_Key)
	testing.expect_value(t, rollback_floor_init(&state, pub_digest, 0, 65, 1), Rollback_Refusal.Key_Number_Out_Of_Range)
	testing.expect_value(t, rollback_floor_init(&state, pub_digest, 0, 1, 65), Rollback_Refusal.Policy_Version_Out_Of_Range)
	testing.expect(t, !state.initialized, "failed init must leave state uninitialized")

	// Uninitialized state refuses counter advance and policy verify.
	testing.expect_value(t, rollback_floor_advance_counter(&state, 1), Rollback_Refusal.Not_Initialized)

	// Valid init with initial_counter = 10, key_floor = 2, version_floor = 5.
	testing.expect_value(t, rollback_floor_init(&state, pub_digest, 10, 2, 5), Rollback_Refusal.None)

	// Counter refusals: 0, < 10 (rollback), == 10 (replay). Zero mutation!
	testing.expect_value(t, rollback_floor_advance_counter(&state, 0), Rollback_Refusal.Counter_Zero)
	testing.expect_value(t, rollback_floor_advance_counter(&state, 1), Rollback_Refusal.Counter_Rollback)
	testing.expect_value(t, rollback_floor_advance_counter(&state, 9), Rollback_Refusal.Counter_Rollback)
	testing.expect_value(t, rollback_floor_advance_counter(&state, 10), Rollback_Refusal.Counter_Replay)
	testing.expect_value(t, state.last_grant_table_counter, u64(10))

	// Valid monotonic advances up to max(u64).
	testing.expect_value(t, rollback_floor_advance_counter(&state, 11), Rollback_Refusal.None)
	testing.expect_value(t, state.last_grant_table_counter, u64(11))
	testing.expect_value(t, rollback_floor_advance_counter(&state, 11), Rollback_Refusal.Counter_Replay)
	testing.expect_value(t, rollback_floor_advance_counter(&state, max(u64)), Rollback_Refusal.None)
	testing.expect_value(t, rollback_floor_advance_counter(&state, max(u64)), Rollback_Refusal.Counter_Replay)
	testing.expect_value(t, rollback_floor_advance_counter(&state, max(u64) - 1), Rollback_Refusal.Counter_Rollback)

	// PolicyAuthorize statements.
	ref_digest := make_digest(0xA1)
	stmt_v5 := Approved_Policy_Statement {
		key_number      = 2,
		policy_version  = 5,
		approved_policy = make_digest(0x55),
		policy_ref      = ref_digest,
	}
	h_v5 := compute_policy_approval_hash(stmt_v5)
	sig_v5 := hmac_sha256(pub_secret[:], h_v5[:])

	// Missing verifier, empty sig, tampered sig, zero approved policy, out-of-range key/version.
	_, r := rollback_floor_verify_policy_authorize(&state, stmt_v5, sig_v5[:], nil, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Missing_Verifier)
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_v5, nil, test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Signature_Invalid)

	bad_sig := sig_v5
	bad_sig[0] ~= 0x01
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_v5, bad_sig[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Signature_Invalid)

	stmt_zero_pol := stmt_v5
	stmt_zero_pol.approved_policy = {}
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_zero_pol, sig_v5[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Zero_Policy_Digest)

	stmt_bad_key := stmt_v5
	stmt_bad_key.key_number = 0
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_bad_key, sig_v5[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Key_Number_Out_Of_Range)

	stmt_bad_ver := stmt_v5
	stmt_bad_ver.policy_version = 65
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_bad_ver, sig_v5[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Policy_Version_Out_Of_Range)

	// Refusal of policy version below floor (version 4 < 5) and revoked key (key 1 < 2).
	stmt_old_ver := Approved_Policy_Statement{key_number = 2, policy_version = 4, approved_policy = make_digest(0x44), policy_ref = ref_digest}
	h_old_ver := compute_policy_approval_hash(stmt_old_ver)
	sig_old_ver := hmac_sha256(pub_secret[:], h_old_ver[:])
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_old_ver, sig_old_ver[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Policy_Version_Below_Floor)

	stmt_revoked_key := Approved_Policy_Statement{key_number = 1, policy_version = 64, approved_policy = make_digest(0x64), policy_ref = ref_digest}
	h_revoked := compute_policy_approval_hash(stmt_revoked_key)
	sig_revoked := hmac_sha256(pub_secret[:], h_revoked[:])
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_revoked_key, sig_revoked[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Key_Number_Below_Floor)
	testing.expect_value(t, state.key_floor, u32(2))
	testing.expect_value(t, state.version_floor, u32(5))

	// Valid statement at current floor succeeds and produces PCR-7-independent digest.
	auth_digest_v5, ok_r := rollback_floor_verify_policy_authorize(&state, stmt_v5, sig_v5[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, ok_r, Rollback_Refusal.None)
	testing.expect_value(t, auth_digest_v5, compute_policy_authorize_digest(pub_digest, ref_digest))

	// Valid newer statement (v6) with different approved_policy (e.g. new PCR 11 / PCR 7 change)
	// yields the SAME PolicyAuthorize root digest (so sealed objects stay open!) and raises floor to 6.
	stmt_v6 := Approved_Policy_Statement{key_number = 2, policy_version = 6, approved_policy = make_digest(0x66), policy_ref = ref_digest}
	h_v6 := compute_policy_approval_hash(stmt_v6)
	sig_v6 := hmac_sha256(pub_secret[:], h_v6[:])
	auth_digest_v6, ok_r6 := rollback_floor_verify_policy_authorize(&state, stmt_v6, sig_v6[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, ok_r6, Rollback_Refusal.None)
	testing.expect_value(t, auth_digest_v6, auth_digest_v5)
	testing.expect_value(t, state.version_floor, u32(6))

	// Now v5 is below the raised floor 6 and must be refused!
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_v5, sig_v5[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Policy_Version_Below_Floor)

	// New key number (key 3, version 1) raises key_floor to 3 and starts its own version floor at 1.
	stmt_k3 := Approved_Policy_Statement{key_number = 3, policy_version = 1, approved_policy = make_digest(0x31), policy_ref = ref_digest}
	h_k3 := compute_policy_approval_hash(stmt_k3)
	sig_k3 := hmac_sha256(pub_secret[:], h_k3[:])
	_, ok_k3 := rollback_floor_verify_policy_authorize(&state, stmt_k3, sig_k3[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, ok_k3, Rollback_Refusal.None)
	testing.expect_value(t, state.key_floor, u32(3))
	testing.expect_value(t, state.version_floor, u32(1))

	// Key 2 (even at version 6) is now revoked!
	_, r = rollback_floor_verify_policy_authorize(&state, stmt_v6, sig_v6[:], test_policy_sig_verify, &pub_secret)
	testing.expect_value(t, r, Rollback_Refusal.Key_Number_Below_Floor)
}


@(private = "file")
all_bytes_are :: proc(bytes: []u8, value: u8) -> bool {
	for item in bytes {
		if item != value {
			return false
		}
	}
	return true
}

@(test)
machine_key_form_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for word in ([?]u64{0, 4, 255, 256, 257, 0xFFFF_FFFF_FFFF_FFFF}) {
		form, ok := machine_key_form_of_word(word)
		testing.expectf(t, !ok, "word %d must name no form", word)
		testing.expect_value(t, form, Machine_Key_Form.None)
	}
	form, ok := machine_key_form_of_word(1)
	testing.expect(t, ok && form == .MachineT)
	form, ok = machine_key_form_of_word(2)
	testing.expect(t, ok && form == .MachineP)
	form, ok = machine_key_form_of_word(3)
	testing.expect(t, ok && form == .MachineK)

	short := transmute([]u8)string("MACHINE")
	_, ok = machine_key_form_of_record_magic(short)
	testing.expect(t, !ok)
	unknown := transmute([]u8)string("MACHINEX and more")
	_, ok = machine_key_form_of_record_magic(unknown)
	testing.expect(t, !ok)
	lower := transmute([]u8)string("machinet")
	_, ok = machine_key_form_of_record_magic(lower)
	testing.expect(t, !ok)
	sealed := transmute([]u8)string("MACHINET followed by the record")
	form, ok = machine_key_form_of_record_magic(sealed)
	testing.expect(t, ok && form == .MachineT)
	with_passphrase := transmute([]u8)string("MACHINEP")
	form, ok = machine_key_form_of_record_magic(with_passphrase)
	testing.expect(t, ok && form == .MachineP)
	passphrase_alone := transmute([]u8)string("MACHINEK")
	form, ok = machine_key_form_of_record_magic(passphrase_alone)
	testing.expect(t, ok && form == .MachineK)
}

@(private = "file")
Expected_Writer :: struct {
	bytes: [256]u8,
	place: int,
}

@(private = "file")
expected_put :: proc(writer: ^Expected_Writer, data: ..u8) {
	for item in data {
		writer.bytes[writer.place] = item
		writer.place += 1
	}
}

@(private = "file")
expected_put_slice :: proc(writer: ^Expected_Writer, data: []u8) {
	for item in data {
		writer.bytes[writer.place] = item
		writer.place += 1
	}
}

@(private = "file")
make_key_name :: proc(seed: u8) -> (name: [KEY_NAME_SIZE]u8) {
	name[0] = 0x00
	name[1] = 0x0B
	digest := make_digest(seed)
	copy(name[2:], digest[:])
	return name
}

@(test)
policy_authorize_command_layout_and_refusals :: proc(t: ^testing.T) {
	approved := make_digest(0x10)
	reference := [4]u8{0xA1, 0xA2, 0xA3, 0xA4}
	name := make_key_name(0x20)
	ticket := Verified_Ticket{hierarchy = .Owner, digest = make_digest(0x30)}
	session := u32(0x0300_0001)

	expected: Expected_Writer
	expected_put(&expected, 0x80, 0x01, 0x00, 0x00, 0x00, 0x82, 0x00, 0x00, 0x01, 0x6A)
	expected_put(&expected, 0x03, 0x00, 0x00, 0x01)
	expected_put(&expected, 0x00, 0x20)
	expected_put_slice(&expected, approved[:])
	expected_put(&expected, 0x00, 0x04, 0xA1, 0xA2, 0xA3, 0xA4)
	expected_put(&expected, 0x00, 0x22)
	expected_put_slice(&expected, name[:])
	expected_put(&expected, 0x80, 0x22, 0x40, 0x00, 0x00, 0x01, 0x00, 0x20)
	ticket_digest := ticket.digest
	expected_put_slice(&expected, ticket_digest[:])
	testing.expect_value(t, expected.place, 130)

	untouched: [256]u8
	for &item in untouched {
		item = 0xEE
	}
	count, refusal := encode_policy_authorize(session, approved, reference[:], name[:], ticket, untouched[:129])
	testing.expect_value(t, refusal, Wire_Refusal.Buffer_Too_Small)
	testing.expect_value(t, count, 0)
	_, refusal = encode_policy_authorize(session, approved, reference[:], name[:], ticket, nil)
	testing.expect_value(t, refusal, Wire_Refusal.Buffer_Too_Small)
	for handle in ([?]u32{0, 0x0200_0000, 0x02FF_FFFF, 0x0400_0000, 0x4000_0001, 0x8000_0000, max(u32)}) {
		_, refusal = encode_policy_authorize(handle, approved, reference[:], name[:], ticket, untouched[:])
		testing.expectf(t, refusal == .Handle_Not_Policy_Session, "handle %x was taken for a policy session", handle)
	}
	_, refusal = encode_policy_authorize(session, {}, reference[:], name[:], ticket, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Zero_Approved_Policy)
	too_long_reference: [POLICY_REFERENCE_LIMIT + 1]u8
	_, refusal = encode_policy_authorize(session, approved, too_long_reference[:], name[:], ticket, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Policy_Reference_Too_Large)
	_, refusal = encode_policy_authorize(session, approved, reference[:], name[:KEY_NAME_SIZE - 1], ticket, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Key_Name_Malformed)
	_, refusal = encode_policy_authorize(session, approved, reference[:], nil, ticket, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Key_Name_Malformed)
	wrong_algorithm := name
	wrong_algorithm[1] = 0x04
	_, refusal = encode_policy_authorize(session, approved, reference[:], wrong_algorithm[:], ticket, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Key_Name_Malformed)
	zero_name: [KEY_NAME_SIZE]u8
	zero_name[1] = 0x0B
	_, refusal = encode_policy_authorize(session, approved, reference[:], zero_name[:], ticket, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Key_Name_Malformed)
	_, refusal = encode_policy_authorize(session, approved, reference[:], name[:], {hierarchy = .Owner}, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Zero_Ticket_Digest)
	testing.expect(t, all_bytes_are(untouched[:], 0xEE))

	// The borders of the words of a ticket and an answer.
	_, ok := ticket_hierarchy_of_word(0x4000_0007)
	testing.expect(t, !ok)
	_, ok = ticket_hierarchy_of_word(0x4000_000A)
	testing.expect(t, !ok)
	_, ok = hierarchy_of_word(0x4000_0007)
	testing.expect(t, !ok)
	_, ok = hierarchy_of_word(0)
	testing.expect(t, !ok)
	_, ok = response_tag_of_word(0x8022)
	testing.expect(t, !ok)

	// The accepted cases come last: the exact bytes, an empty reference,
	// and the largest reference.
	out: [256]u8
	count, refusal = encode_policy_authorize(session, approved, reference[:], name[:], ticket, out[:130])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, count, 130)
	testing.expect(t, string(out[:130]) == string(expected.bytes[:130]))
	count, refusal = encode_policy_authorize(0x03FF_FFFF, approved, nil, name[:], ticket, out[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, count, 126)
	testing.expect_value(t, byte_order.read_u32_big_endian(out[:], 2), u32(126))
	testing.expect_value(t, byte_order.read_u16_big_endian(out[:], 48), u16(0))
	largest_reference: [POLICY_REFERENCE_LIMIT]u8
	largest_reference[0] = 1
	count, refusal = encode_policy_authorize(session, approved, largest_reference[:], name[:], ticket, out[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, count, 158)
}

@(test)
hierarchy_change_auth_command_layout_and_refusals :: proc(t: ^testing.T) {
	new_value := [3]u8{0x01, 0x02, 0x03}
	current_value := [2]u8{0xC1, 0xC2}

	untouched: [128]u8
	for &item in untouched {
		item = 0xEE
	}
	count, refusal := encode_hierarchy_change_auth(.Lockout, nil, new_value[:], untouched[:31])
	testing.expect_value(t, refusal, Wire_Refusal.Buffer_Too_Small)
	testing.expect_value(t, count, 0)
	_, refusal = encode_hierarchy_change_auth(.Lockout, nil, nil, untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Empty_Authorization)
	zeros: [16]u8
	_, refusal = encode_hierarchy_change_auth(.Owner, nil, zeros[:], untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Zero_Authorization)
	too_long: [AUTHORIZATION_LIMIT + 1]u8
	too_long[0] = 1
	_, refusal = encode_hierarchy_change_auth(.Owner, nil, too_long[:], untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Authorization_Too_Large)
	_, refusal = encode_hierarchy_change_auth(.Owner, too_long[:], new_value[:], untouched[:])
	testing.expect_value(t, refusal, Wire_Refusal.Authorization_Too_Large)
	testing.expect(t, all_bytes_are(untouched[:], 0xEE))

	// The accepted cases come last: the exact bytes with the empty current
	// value, then with a current value, then the largest values.
	out: [128]u8
	count, refusal = encode_hierarchy_change_auth(.Lockout, nil, new_value[:], out[:32])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, count, 32)
	expected_empty := [32]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x01, 0x29,
		0x40, 0x00, 0x00, 0x0A,
		0x00, 0x00, 0x00, 0x09,
		0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x03, 0x01, 0x02, 0x03,
	}
	testing.expect(t, string(out[:32]) == string(expected_empty[:]))

	count, refusal = encode_hierarchy_change_auth(.Owner, current_value[:], new_value[:], out[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, count, 34)
	expected_current := [34]u8 {
		0x80, 0x02, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x01, 0x29,
		0x40, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x0B,
		0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x02, 0xC1, 0xC2,
		0x00, 0x03, 0x01, 0x02, 0x03,
	}
	testing.expect(t, string(out[:34]) == string(expected_current[:]))

	largest: [AUTHORIZATION_LIMIT]u8
	largest[AUTHORIZATION_LIMIT - 1] = 1
	count, refusal = encode_hierarchy_change_auth(.Endorsement, largest[:], largest[:], out[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, count, 29 + 2 * AUTHORIZATION_LIMIT)
	one := [1]u8{0x7F}
	count, refusal = encode_hierarchy_change_auth(.Platform, nil, one[:], out[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, count, 30)
}

@(test)
tpm_response_decoding_refuses_truncated_and_error_answers :: proc(t: ^testing.T) {
	_, refusal := decode_tpm_response_header(nil)
	testing.expect_value(t, refusal, Wire_Refusal.Response_Truncated)
	success := [10]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00}
	_, refusal = decode_tpm_response_header(success[:9])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Truncated)

	for tag in ([?]u16{0x0000, 0x8000, 0x8003, 0x8022, 0xFFFF, 0x0180}) {
		answer := success
		byte_order.write_u16_big_endian(answer[:], 0, tag)
		_, refusal = decode_tpm_response_header(answer[:])
		testing.expectf(t, refusal == .Response_Tag_Unknown, "tag %x was taken", tag)
	}

	// The size field must be the bytes given, in both directions.
	for size in ([?]u32{0, 9, 11, 0xFFFF_FFFF}) {
		answer := success
		byte_order.write_u32_big_endian(answer[:], 2, size)
		_, refusal = decode_tpm_response_header(answer[:])
		testing.expectf(t, refusal == .Response_Size_Mismatch, "size %d was taken", size)
	}
	longer: [11]u8
	copy(longer[:], success[:])
	_, refusal = decode_tpm_response_header(longer[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Size_Mismatch)

	// A failure gives its code, and only in the form of a failure.
	failure := [10]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x09, 0x8E}
	header: Response_Header
	header, refusal = decode_tpm_response_header(failure[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Error)
	testing.expect_value(t, header.code, u32(0x098E))
	code: u32
	code, refusal = decode_policy_authorize_response(failure[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Error)
	testing.expect_value(t, code, u32(0x098E))
	code, refusal = decode_hierarchy_change_auth_response(failure[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Error)
	testing.expect_value(t, code, u32(0x098E))
	failure_with_sessions := failure
	failure_with_sessions[1] = 0x02
	_, refusal = decode_tpm_response_header(failure_with_sessions[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)
	failure_with_body := [14]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x09, 0x8E, 0, 0, 0, 0}
	_, refusal = decode_tpm_response_header(failure_with_body[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)

	// The answer of TPM2_PolicyAuthorize is the header alone.
	success_with_sessions := success
	success_with_sessions[1] = 0x02
	_, refusal = decode_policy_authorize_response(success_with_sessions[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)
	success_with_body := [12]u8{0x80, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
	_, refusal = decode_policy_authorize_response(success_with_body[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)

	// The answer of TPM2_HierarchyChangeAuth: no parameter, an empty nonce
	// and an empty HMAC.
	change_success := [19]u8{0x80, 0x02, 0x00, 0x00, 0x00, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00}
	_, refusal = decode_hierarchy_change_auth_response(change_success[:15])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Size_Mismatch)
	_, refusal = decode_hierarchy_change_auth_response(success[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)
	with_parameters := change_success
	with_parameters[13] = 0x04
	_, refusal = decode_hierarchy_change_auth_response(with_parameters[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)
	with_nonce := change_success
	with_nonce[15] = 0x01
	_, refusal = decode_hierarchy_change_auth_response(with_nonce[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)
	with_hmac := change_success
	with_hmac[18] = 0x01
	_, refusal = decode_hierarchy_change_auth_response(with_hmac[:])
	testing.expect_value(t, refusal, Wire_Refusal.Response_Malformed)

	// The accepted cases come last.
	header, refusal = decode_tpm_response_header(success[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, header, Response_Header{tag = .No_Sessions, size = 10, code = 0})
	code, refusal = decode_policy_authorize_response(success[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	code, refusal = decode_hierarchy_change_auth_response(change_success[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, code, TPM_RC_SUCCESS)
}
