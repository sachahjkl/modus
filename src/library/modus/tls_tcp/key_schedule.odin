// RFC 8446 section 7.1 TLS 1.3 key schedule using modus:cryptography_primitives.
// Zero duplicate cryptographic code and zero allocations.
package tls_tcp

import "modus:contract/byte_order"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:cryptography_primitives"

HKDF_LABEL_PREFIX :: "tls13 "
HKDF_LABEL_MAX_LEN :: 249 // 255 - len("tls13 ")
HKDF_CONTEXT_MAX_LEN :: 255
HKDF_INFO_BUFFER_SIZE :: 2 + 1 + 6 + HKDF_LABEL_MAX_LEN + 1 + HKDF_CONTEXT_MAX_LEN

// Server CertificateVerify signing context (RFC 8446 section 4.4.3).
SERVER_VERIFY_CONTEXT :: "TLS 1.3, server CertificateVerify"
VERIFY_CONTENT_SIZE :: 64 + len(SERVER_VERIFY_CONTEXT) + 1 + HASH_SIZE // 130 bytes.

// Traffic_Keys holds AEAD key material and monotonic 64-bit sequence counter for one direction.
Traffic_Keys :: struct {
	suite:           Tls_Cipher_Suite,
	key:             [32]u8,
	key_len:         int,
	iv:              [NONCE_SIZE]u8,
	sequence_number: u64,
	active:          bool,
}

// Key_Schedule holds the RFC 8446 SHA-256 secrets for one TLS 1.3 handshake.
Key_Schedule :: struct {
	early_secret:               [HASH_SIZE]u8,
	handshake_secret:           [HASH_SIZE]u8,
	master_secret:              [HASH_SIZE]u8,
	client_handshake_traffic:   [HASH_SIZE]u8,
	server_handshake_traffic:   [HASH_SIZE]u8,
	client_application_traffic: [HASH_SIZE]u8,
	server_application_traffic: [HASH_SIZE]u8,
}

// traffic_keys_erase wipes key material and deactivates the traffic key slot.
traffic_keys_erase :: proc "contextless" (keys: ^Traffic_Keys) {
	erase_bytes(keys.key[:])
	erase_bytes(keys.iv[:])
	keys.key_len = 0
	keys.sequence_number = 0
	keys.active = false
}

// key_schedule_erase wipes all secrets in a key schedule.
key_schedule_erase :: proc "contextless" (schedule: ^Key_Schedule) {
	erase_bytes(schedule.early_secret[:])
	erase_bytes(schedule.handshake_secret[:])
	erase_bytes(schedule.master_secret[:])
	erase_bytes(schedule.client_handshake_traffic[:])
	erase_bytes(schedule.server_handshake_traffic[:])
	erase_bytes(schedule.client_application_traffic[:])
	erase_bytes(schedule.server_application_traffic[:])
}

// sha256_hash computes the 32-byte SHA-256 digest of input.
sha256_hash :: proc "contextless" (input: []u8, digest_out: ^[HASH_SIZE]u8) -> bool {
	text := string(input)
	result := digest_out[:]
	return cryptography_primitives.sha256(&text, &result) == HASH_SIZE
}

// hkdf_extract computes HKDF-Extract(salt, ikm) with SHA-256.
hkdf_extract :: proc "contextless" (salt, ikm: []u8, prk_out: ^[HASH_SIZE]u8) -> bool {
	salt_text := string(salt)
	ikm_text := string(ikm)
	result := prk_out[:]
	return cryptography_primitives.hkdf_sha256_extract(&salt_text, &ikm_text, &result) == HASH_SIZE
}

// build_hkdf_label encodes RFC 8446 HkdfLabel into buf and returns the encoded slice.
build_hkdf_label :: proc "contextless" (buf: ^[HKDF_INFO_BUFFER_SIZE]u8, label: string, ctx: []u8, length: int) -> (encoded: []u8, ok: bool) {
	if len(label) > HKDF_LABEL_MAX_LEN || len(ctx) > HKDF_CONTEXT_MAX_LEN || length < 1 || length > 0xFFFF {
		return nil, false
	}
	byte_order.write_u16_big_endian(buf[:], 0, u16(length))
	full_label_len := len(HKDF_LABEL_PREFIX) + len(label)
	buf[2] = u8(full_label_len)
	copy(buf[3:], HKDF_LABEL_PREFIX)
	copy(buf[3 + len(HKDF_LABEL_PREFIX):], label)
	pos := 3 + full_label_len
	buf[pos] = u8(len(ctx))
	copy(buf[pos + 1:], ctx)
	return buf[:pos + 1 + len(ctx)], true
}

// hkdf_expand_label executes RFC 8446 HKDF-Expand-Label(secret, label, ctx, len(out)).
hkdf_expand_label :: proc "contextless" (secret: []u8, label: string, ctx: []u8, out: []u8) -> Tls_Refusal {
	if len(secret) != HASH_SIZE || len(out) == 0 || len(out) > 0xFFFF {
		return .Crypto_Failed
	}
	info_buf: [HKDF_INFO_BUFFER_SIZE]u8
	info, ok := build_hkdf_label(&info_buf, label, ctx, len(out))
	if !ok {
		return .Crypto_Failed
	}
	key_text := string(secret)
	info_text := string(info)
	result := out
	err: errors.Error_Record
	outcome, written := cryptography_primitives.hkdf_sha256_expand(&key_text, &info_text, value_kinds.Size_In_Bytes(len(out)), &result, &err)
	if outcome != .Succeeded || written != i64(len(out)) {
		return .Crypto_Failed
	}
	return .None
}

// derive_secret executes RFC 8446 Derive-Secret(secret, label, transcript_hash).
derive_secret :: proc "contextless" (secret: []u8, label: string, transcript_hash: []u8, out: ^[HASH_SIZE]u8) -> Tls_Refusal {
	if len(transcript_hash) != HASH_SIZE {
		return .Crypto_Failed
	}
	return hkdf_expand_label(secret, label, transcript_hash, out[:])
}

// key_schedule_handshake computes early, handshake, handshake traffic, and master secrets.
key_schedule_handshake :: proc "contextless" (schedule: ^Key_Schedule, shared_secret: []u8, hello_transcript_hash: []u8) -> Tls_Refusal {
	if len(shared_secret) != X25519_KEY_SIZE || len(hello_transcript_hash) != HASH_SIZE {
		return .Crypto_Failed
	}
	zeros: [HASH_SIZE]u8
	empty_hash: [HASH_SIZE]u8
	derived: [HASH_SIZE]u8
	defer erase_bytes(derived[:])

	if !sha256_hash(nil, &empty_hash) {
		return .Crypto_Failed
	}
	if !hkdf_extract(nil, zeros[:], &schedule.early_secret) {
		return .Crypto_Failed
	}
	if r := derive_secret(schedule.early_secret[:], "derived", empty_hash[:], &derived); r != .None {
		return r
	}
	if !hkdf_extract(derived[:], shared_secret, &schedule.handshake_secret) {
		return .Crypto_Failed
	}
	if r := derive_secret(schedule.handshake_secret[:], "c hs traffic", hello_transcript_hash, &schedule.client_handshake_traffic); r != .None {
		return r
	}
	if r := derive_secret(schedule.handshake_secret[:], "s hs traffic", hello_transcript_hash, &schedule.server_handshake_traffic); r != .None {
		return r
	}
	if r := derive_secret(schedule.handshake_secret[:], "derived", empty_hash[:], &derived); r != .None {
		return r
	}
	if !hkdf_extract(derived[:], zeros[:], &schedule.master_secret) {
		return .Crypto_Failed
	}
	return .None
}

// key_schedule_application computes client and server application traffic secrets.
key_schedule_application :: proc "contextless" (schedule: ^Key_Schedule, server_finished_hash: []u8) -> Tls_Refusal {
	if len(server_finished_hash) != HASH_SIZE {
		return .Crypto_Failed
	}
	if r := derive_secret(schedule.master_secret[:], "c ap traffic", server_finished_hash, &schedule.client_application_traffic); r != .None {
		return r
	}
	if r := derive_secret(schedule.master_secret[:], "s ap traffic", server_finished_hash, &schedule.server_application_traffic); r != .None {
		return r
	}
	return .None
}

// derive_traffic_keys derives the AEAD key and IV for a traffic secret and cipher suite.
derive_traffic_keys :: proc "contextless" (suite: Tls_Cipher_Suite, traffic_secret: []u8, keys_out: ^Traffic_Keys) -> Tls_Refusal {
	key_len := cipher_suite_key_size(suite)
	if key_len == 0 || len(traffic_secret) != HASH_SIZE {
		return .Invalid_Cipher_Suite
	}
	traffic_keys_erase(keys_out)
	if r := hkdf_expand_label(traffic_secret, "key", nil, keys_out.key[:key_len]); r != .None {
		traffic_keys_erase(keys_out)
		return r
	}
	if r := hkdf_expand_label(traffic_secret, "iv", nil, keys_out.iv[:]); r != .None {
		traffic_keys_erase(keys_out)
		return r
	}
	keys_out.suite = suite
	keys_out.key_len = key_len
	keys_out.sequence_number = 0
	keys_out.active = true
	return .None
}

// compute_finished_verify_data calculates HMAC-SHA256(finished_key, transcript_hash) per RFC 8446 section 4.4.4.
compute_finished_verify_data :: proc "contextless" (traffic_secret: []u8, transcript_hash: []u8, verify_out: ^[HASH_SIZE]u8) -> Tls_Refusal {
	if len(traffic_secret) != HASH_SIZE || len(transcript_hash) != HASH_SIZE {
		return .Crypto_Failed
	}
	finished_key: [HASH_SIZE]u8
	defer erase_bytes(finished_key[:])

	if r := hkdf_expand_label(traffic_secret, "finished", nil, finished_key[:]); r != .None {
		return r
	}
	key_text := string(finished_key[:])
	msg_text := string(transcript_hash)
	result := verify_out[:]
	if cryptography_primitives.hmac_sha256(&key_text, &msg_text, &result) != HASH_SIZE {
		return .Crypto_Failed
	}
	return .None
}

// build_certificate_verify_content constructs the 130-byte server CertificateVerify input (RFC 8446 section 4.4.3).
build_certificate_verify_content :: proc "contextless" (transcript_hash: []u8, content_out: ^[VERIFY_CONTENT_SIZE]u8) -> bool {
	if len(transcript_hash) != HASH_SIZE {
		return false
	}
	for i := 0; i < 64; i += 1 {
		content_out[i] = 0x20
	}
	copy(content_out[64:], SERVER_VERIFY_CONTEXT)
	content_out[64 + len(SERVER_VERIFY_CONTEXT)] = 0x00
	copy(content_out[64 + len(SERVER_VERIFY_CONTEXT) + 1:], transcript_hash)
	return true
}

// x25519_scalar_mult computes X25519(scalar, point) and refuses small-order outputs.
x25519_scalar_mult :: proc "contextless" (scalar, point: []u8, out: ^[X25519_KEY_SIZE]u8) -> Tls_Refusal {
	if len(scalar) != X25519_KEY_SIZE || len(point) != X25519_KEY_SIZE {
		return .Invalid_Key_Share
	}
	s_text := string(scalar)
	p_text := string(point)
	result := out[:]
	err: errors.Error_Record
	if crypto_outcome, crypto_count := cryptography_primitives.x25519(&s_text, &p_text, &result, &err); crypto_outcome != .Succeeded || crypto_count != X25519_KEY_SIZE {
		return .Invalid_Key_Share
	}
	return .None
}

// ed25519_derive_public derives a 32-byte Ed25519 public key from a 32-byte private key.
ed25519_derive_public :: proc "contextless" (private_key: []u8, public_out: ^[ED25519_KEY_SIZE]u8) -> Tls_Refusal {
	if len(private_key) != ED25519_KEY_SIZE {
		return .Invalid_Configuration
	}
	priv_text := string(private_key)
	result := public_out[:]
	err: errors.Error_Record
	if crypto_outcome, crypto_count := cryptography_primitives.ed25519_public_key(&priv_text, &result, &err); crypto_outcome != .Succeeded || crypto_count != ED25519_KEY_SIZE {
		return .Crypto_Failed
	}
	return .None
}

// ed25519_sign_transcript signs the TLS 1.3 server CertificateVerify content.
ed25519_sign_transcript :: proc "contextless" (private_key: []u8, transcript_hash: []u8, sig_out: ^[ED25519_SIGNATURE_SIZE]u8) -> Tls_Refusal {
	content: [VERIFY_CONTENT_SIZE]u8
	if !build_certificate_verify_content(transcript_hash, &content) {
		return .Crypto_Failed
	}
	priv_text := string(private_key)
	msg_text := string(content[:])
	result := sig_out[:]
	err: errors.Error_Record
	if crypto_outcome, crypto_count := cryptography_primitives.ed25519_sign(&priv_text, &msg_text, &result, &err); crypto_outcome != .Succeeded || crypto_count != ED25519_SIGNATURE_SIZE {
		return .Crypto_Failed
	}
	return .None
}

// ed25519_verify_transcript verifies the TLS 1.3 server CertificateVerify signature.
ed25519_verify_transcript :: proc "contextless" (public_key: []u8, transcript_hash: []u8, signature: []u8) -> Tls_Refusal {
	if len(public_key) != ED25519_KEY_SIZE || len(signature) != ED25519_SIGNATURE_SIZE {
		return .Invalid_Certificate_Verify
	}
	content: [VERIFY_CONTENT_SIZE]u8
	if !build_certificate_verify_content(transcript_hash, &content) {
		return .Invalid_Certificate_Verify
	}
	pub_text := string(public_key)
	msg_text := string(content[:])
	sig_text := string(signature)
	err: errors.Error_Record
	if crypto_outcome, crypto_count := cryptography_primitives.ed25519_verify(&pub_text, &msg_text, &sig_text, &err); crypto_outcome != .Succeeded || crypto_count != 0 {
		return .Invalid_Certificate_Verify
	}
	return .None
}
