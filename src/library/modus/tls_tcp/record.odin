// RFC 8446 section 5 TLS 1.3 record framing and AEAD record protection.
// Reuses modus:cryptography_primitives with zero heap allocations.
package tls_tcp

import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:cryptography_primitives"

// Decoded 5-byte TLS record header.
Record_Header :: struct {
	content_type:   Tls_Content_Type,
	legacy_version: u16,
	length:         u16,
}

// record_parse_header parses a 5-byte TLS record header through strict enum and length borders.
record_parse_header :: proc "contextless" (data: []u8, allow_legacy_0301: bool) -> (header: Record_Header, refusal: Tls_Refusal) {
	if len(data) < RECORD_HEADER_SIZE {
		return {}, .Record_Header_Incomplete
	}
	ct, ct_ok := content_type_of_word(data[0])
	if !ct_ok {
		return {}, .Invalid_Content_Type
	}
	ver := byte_order.read_u16_big_endian(data, 1)
	if ver != TLS_LEGACY_VERSION && !(allow_legacy_0301 && ver == TLS_LEGACY_CLIENT_HELLO_RECORD_VERSION) {
		return {}, .Invalid_Legacy_Version
	}
	length := byte_order.read_u16_big_endian(data, 3)
	if ct == .Application_Data {
		if int(length) > MAX_CIPHERTEXT_SIZE {
			return {}, .Record_Too_Large
		}
	} else {
		if int(length) > MAX_PLAINTEXT_SIZE {
			return {}, .Record_Too_Large
		}
	}
	return Record_Header{
		content_type   = ct,
		legacy_version = ver,
		length         = length,
	}, .None
}

// record_write_plaintext frames an unencrypted TLS record (used only for ClientHello, ServerHello, and CCS).
record_write_plaintext :: proc "contextless" (ct: Tls_Content_Type, payload: []u8, out: []u8) -> (written: int, refusal: Tls_Refusal) {
	if len(payload) > MAX_PLAINTEXT_SIZE {
		return 0, .Record_Too_Large
	}
	total := RECORD_HEADER_SIZE + len(payload)
	if len(out) < total {
		return 0, .Buffer_Too_Small
	}
	out[0] = u8(ct)
	byte_order.write_u16_big_endian(out, 1, TLS_LEGACY_VERSION)
	byte_order.write_u16_big_endian(out, 3, u16(len(payload)))
	copy(out[RECORD_HEADER_SIZE:], payload)
	return total, .None
}

// compute_record_nonce computes iv XOR padded_be64(sequence_number) per RFC 8446 section 5.3.
compute_record_nonce :: proc "contextless" (iv: [NONCE_SIZE]u8, sequence_number: u64) -> [NONCE_SIZE]u8 {
	nonce := iv
	seq_bytes: [8]u8
	byte_order.write_u64_big_endian(seq_bytes[:], 0, sequence_number)
	for i := 0; i < 8; i += 1 {
		nonce[4 + i] ~= seq_bytes[i]
	}
	return nonce
}

// record_encrypt protects an inner TLSPlaintext as an RFC 8446 TLSCiphertext record.
// Refuses sequence exhaustion at max(u64) to prevent nonce reuse.
record_encrypt :: proc "contextless" (keys: ^Traffic_Keys, inner_type: Tls_Content_Type, plaintext: []u8, padding_len: int, out: []u8) -> (written: int, refusal: Tls_Refusal) {
	if !keys.active || keys.key_len == 0 {
		return 0, .Invalid_State
	}
	valid_inner, inner_ok := content_type_of_word(u8(inner_type))
	if !inner_ok {
		return 0, .Invalid_Content_Type
	}
	if keys.sequence_number == max(u64) {
		return 0, .Sequence_Exhausted
	}
	if len(plaintext) > MAX_PLAINTEXT_SIZE || padding_len < 0 || padding_len > MAX_CIPHERTEXT_SIZE {
		return 0, .Record_Too_Large
	}
	inner_len := len(plaintext) + 1 + padding_len
	cipher_len := inner_len + AEAD_TAG_SIZE
	if cipher_len > MAX_CIPHERTEXT_SIZE {
		return 0, .Record_Too_Large
	}
	_ = valid_inner
	total := RECORD_HEADER_SIZE + cipher_len
	if len(out) < total {
		return 0, .Buffer_Too_Small
	}

	// Build outer 5-byte TLSCiphertext header (also used as AAD).
	out[0] = u8(Tls_Content_Type.Application_Data)
	byte_order.write_u16_big_endian(out, 1, TLS_LEGACY_VERSION)
	byte_order.write_u16_big_endian(out, 3, u16(cipher_len))

	// Assemble TLSInnerPlaintext in a private stack buffer (plaintext || inner_type || zeros).
	inner_buf: [MAX_CIPHERTEXT_SIZE]u8
	defer erase_bytes(inner_buf[:inner_len])
	copy(inner_buf[:len(plaintext)], plaintext)
	inner_buf[len(plaintext)] = u8(inner_type)
	for i := 0; i < padding_len; i += 1 {
		inner_buf[len(plaintext) + 1 + i] = 0
	}

	nonce := compute_record_nonce(keys.iv, keys.sequence_number)
	key_text := string(keys.key[:keys.key_len])
	nonce_text := string(nonce[:])
	aad_text := string(out[:RECORD_HEADER_SIZE])
	plain_text := string(inner_buf[:inner_len])
	cipher_slice := out[RECORD_HEADER_SIZE:total]
	err: errors.Error_Record

	sealed: i64
	sealed_outcome: call_outcome.Call_Outcome
	switch keys.suite {
	case .TLS_AES_128_GCM_SHA256:
		sealed_outcome, sealed = cryptography_primitives.seal_with_aes_128_gcm(&key_text, &nonce_text, &aad_text, &plain_text, &cipher_slice, &err)
	case .TLS_CHACHA20_POLY1305_SHA256:
		sealed_outcome, sealed = cryptography_primitives.seal_with_chacha20_poly1305(&key_text, &nonce_text, &aad_text, &plain_text, &cipher_slice, &err)
	}
	if sealed_outcome != .Succeeded || sealed != i64(cipher_len) {
		return 0, .Crypto_Failed
	}

	keys.sequence_number += 1
	return total, .None
}

// record_decrypt authenticates and decrypts one complete TLSCiphertext record, stripping zero padding.
// Refuses sequence exhaustion at max(u64), oversized records, invalid tags, and missing inner content type.
record_decrypt :: proc "contextless" (keys: ^Traffic_Keys, record_bytes: []u8, plaintext_out: []u8) -> (inner_type: Tls_Content_Type, plaintext_len: int, refusal: Tls_Refusal) {
	if !keys.active || keys.key_len == 0 {
		return {}, 0, .Invalid_State
	}
	if keys.sequence_number == max(u64) {
		return {}, 0, .Sequence_Exhausted
	}
	header, hdr_refusal := record_parse_header(record_bytes, false)
	if hdr_refusal != .None {
		return {}, 0, hdr_refusal
	}
	if header.content_type != .Application_Data {
		return {}, 0, .Invalid_Content_Type
	}
	cipher_len := int(header.length)
	if cipher_len < AEAD_TAG_SIZE + 1 {
		return {}, 0, .Malformed_Message
	}
	if len(record_bytes) < RECORD_HEADER_SIZE + cipher_len {
		return {}, 0, .Record_Incomplete
	}

	inner_buf: [MAX_CIPHERTEXT_SIZE]u8
	inner_len := cipher_len - AEAD_TAG_SIZE
	defer erase_bytes(inner_buf[:inner_len])

	nonce := compute_record_nonce(keys.iv, keys.sequence_number)
	key_text := string(keys.key[:keys.key_len])
	nonce_text := string(nonce[:])
	aad_text := string(record_bytes[:RECORD_HEADER_SIZE])
	sealed_text := string(record_bytes[RECORD_HEADER_SIZE : RECORD_HEADER_SIZE + cipher_len])
	dest := inner_buf[:inner_len]
	err: errors.Error_Record

	opened: i64
	opened_outcome: call_outcome.Call_Outcome
	switch keys.suite {
	case .TLS_AES_128_GCM_SHA256:
		opened_outcome, opened = cryptography_primitives.open_with_aes_128_gcm(&key_text, &nonce_text, &aad_text, &sealed_text, &dest, &err)
	case .TLS_CHACHA20_POLY1305_SHA256:
		opened_outcome, opened = cryptography_primitives.open_with_chacha20_poly1305(&key_text, &nonce_text, &aad_text, &sealed_text, &dest, &err)
	}
	if opened_outcome != .Succeeded || opened != i64(inner_len) {
		return {}, 0, .Authentication_Failed
	}

	// RFC 8446 section 5.4: scan backwards past trailing zero padding to locate the inner ContentType.
	idx := inner_len - 1
	for idx >= 0 && inner_buf[idx] == 0 {
		idx -= 1
	}
	if idx < 0 {
		return {}, 0, .Inner_Content_Missing
	}
	ct, ct_ok := content_type_of_word(inner_buf[idx])
	if !ct_ok {
		return {}, 0, .Invalid_Content_Type
	}
	if idx > MAX_PLAINTEXT_SIZE {
		return {}, 0, .Record_Too_Large
	}
	if len(plaintext_out) < idx {
		return {}, 0, .Buffer_Too_Small
	}
	copy(plaintext_out[:idx], inner_buf[:idx])
	keys.sequence_number += 1
	return ct, idx, .None
}
