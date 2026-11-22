// SSH-2 transport layer: banner exchange, binary packet framing, OpenSSH
// chacha20-poly1305@openssh.com AEAD framing, curve25519-sha256 exchange hash,
// RFC 4253 key derivation, and ssh-ed25519 key/signature blobs.
//
// All cryptographic primitives are reused from modus:cryptography_primitives and
// modus:cryptography (chacha20, poly1305, compatibility_crypto) with zero duplicate
// implementations and explicit secret erasure.
package ssh_client

import "base:runtime"
import "modus:contract/byte_order"
import "modus:contract/errors"
import "modus:cryptography/chacha20"
import crypto "modus:cryptography/compatibility_crypto"
import "modus:cryptography/poly1305"
import "modus:cryptography_primitives"

// Zero context for cryptography calls: no allocator and no thread-local RNG.
@(private)
ssh_zero_context :: #force_inline proc "contextless" () -> runtime.Context {
	return {}
}

// RFC 4253 section 7.2 key derivation letters.
Key_Letter :: enum u8 {
	Iv_Client_To_Server  = 'A',
	Iv_Server_To_Client  = 'B',
	Enc_Client_To_Server = 'C',
	Enc_Server_To_Client = 'D',
	Mac_Client_To_Server = 'E',
	Mac_Server_To_Client = 'F',
}

// banner_write writes "SSH-2.0-modus\r\n" into out.
banner_write :: proc "contextless" (out: []u8) -> (written: int, status: Status) {
	needed := len(CLIENT_BANNER) + 2
	if len(out) < needed {
		return 0, .Buffer_Too_Small
	}
	copy(out, CLIENT_BANNER)
	out[len(CLIENT_BANNER)] = '\r'
	out[len(CLIENT_BANNER) + 1] = '\n'
	return needed, .Ok
}

// banner_parse reads optional pre-banner lines and extracts the peer's "SSH-2.0-..." identification
// string without trailing CR/LF (RFC 4253, section 4.2).
banner_parse :: proc "contextless" (data: []u8) -> (banner: []u8, consumed: int, status: Status) {
	pos := 0
	lines_seen := 0
	for pos < len(data) {
		lines_seen += 1
		if lines_seen > MAX_PRE_BANNER_LINES {
			return nil, 0, .Bad_Banner
		}
		line_start := pos
		lf_pos := -1
		for i := pos; i < len(data); i += 1 {
			if data[i] == 0 {
				return nil, 0, .Bad_Banner
			}
			if data[i] == '\n' {
				lf_pos = i
				break
			}
			if i - line_start >= MAX_BANNER_LENGTH {
				return nil, 0, .Bad_Banner
			}
		}
		if lf_pos < 0 {
			return nil, 0, .Truncated
		}
		line_end := lf_pos
		if line_end > line_start && data[line_end - 1] == '\r' {
			line_end -= 1
		}
		line := data[line_start:line_end]
		pos = lf_pos + 1
		if len(line) >= 4 && bytes_equal(line[:4], transmute([]u8)string("SSH-")) {
			// Require SSH-2.0- strictly; refuse SSH-1.x and malformed banners.
			if len(line) < 9 || !bytes_equal(line[:8], transmute([]u8)string("SSH-2.0-")) {
				return nil, 0, .Bad_Banner
			}
			if len(line) + 2 > MAX_BANNER_LENGTH {
				return nil, 0, .Bad_Banner
			}
			return line, pos, .Ok
		}
	}
	return nil, 0, .Truncated
}

// packet_pack_plain frames an unencrypted SSH binary packet (RFC 4253, section 6).
// pad_bytes supplies deterministic or random padding bytes (at least 4 bytes needed).
packet_pack_plain :: proc "contextless" (payload: []u8, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if len(payload) == 0 {
		return 0, .Invalid_Argument
	}
	// Total unencrypted length (4 + 1 + len(payload) + pad_len) must be a multiple of 8.
	unpadded := 4 + 1 + len(payload)
	pad_len := CIPHER_BLOCK_SIZE - (unpadded % CIPHER_BLOCK_SIZE)
	if pad_len < MIN_PADDING_LENGTH {
		pad_len += CIPHER_BLOCK_SIZE
	}
	packet_length := 1 + len(payload) + pad_len
	if packet_length > MAX_PACKET_LENGTH {
		return 0, .Oversized_Packet
	}
	total := 4 + packet_length
	if len(out) < total {
		return 0, .Buffer_Too_Small
	}
	byte_order.write_u32_big_endian(out, 0, u32(packet_length))
	out[4] = u8(pad_len)
	copy(out[5:], payload)
	for i in 0 ..< pad_len {
		out[5 + len(payload) + i] = i < len(pad_bytes) ? pad_bytes[i] : u8(i + 1)
	}
	return total, .Ok
}

// packet_unpack_plain parses one unencrypted SSH binary packet from wire.
packet_unpack_plain :: proc "contextless" (wire: []u8, payload_out: []u8) -> (payload_len: int, consumed: int, status: Status) {
	if len(wire) < 4 {
		return 0, 0, .Truncated
	}
	packet_length := byte_order.read_u32_big_endian(wire, 0)
	if packet_length > MAX_PACKET_LENGTH {
		return 0, 0, .Oversized_Packet
	}
	if packet_length < 1 + MIN_PADDING_LENGTH {
		return 0, 0, .Bad_Padding
	}
	total := 4 + int(packet_length)
	if total % CIPHER_BLOCK_SIZE != 0 {
		return 0, 0, .Bad_Padding
	}
	if len(wire) < total {
		return 0, 0, .Truncated
	}
	pad_len := int(wire[4])
	if pad_len < MIN_PADDING_LENGTH || 1 + pad_len >= int(packet_length) {
		return 0, 0, .Bad_Padding
	}
	plen := int(packet_length) - 1 - pad_len
	if len(payload_out) < plen {
		return 0, 0, .Buffer_Too_Small
	}
	copy(payload_out[:plen], wire[5 : 5 + plen])
	return plen, total, .Ok
}

// build_openssh_chacha_nonce creates the 12-byte IETF ChaCha20 nonce equivalent to
// OpenSSH's 64-bit big-endian sequence number nonce with zero high counter word.
@(private)
build_openssh_chacha_nonce :: proc "contextless" (seq: u32) -> (nonce: [12]u8) {
	byte_order.write_u32_big_endian(nonce[:], 8, seq)
	return nonce
}

// packet_seal_chacha20_poly1305 encrypts and authenticates an SSH packet using
// chacha20-poly1305@openssh.com (K_1 = key[0:32] for Poly1305/payload, K_2 = key[32:64] for length).
packet_seal_chacha20_poly1305 :: proc "contextless" (key: ^[CHACHA20_POLY1305_KEY_SIZE]u8, seq: u32, payload: []u8, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	context = ssh_zero_context()
	if key == nil || len(payload) == 0 {
		return 0, .Invalid_Argument
	}
	// Under chacha20-poly1305@openssh.com the 4-byte length is encrypted separately with K_2,
	// so the body (padding_length || payload || padding) itself is padded to a multiple of 8 bytes.
	unpadded_body := 1 + len(payload)
	pad_len := CIPHER_BLOCK_SIZE - (unpadded_body % CIPHER_BLOCK_SIZE)
	if pad_len < MIN_PADDING_LENGTH {
		pad_len += CIPHER_BLOCK_SIZE
	}
	packet_length := unpadded_body + pad_len
	if packet_length > MAX_PACKET_LENGTH {
		return 0, .Oversized_Packet
	}
	total := 4 + packet_length + POLY1305_TAG_SIZE
	if len(out) < total {
		return 0, .Buffer_Too_Small
	}

	nonce := build_openssh_chacha_nonce(seq)
	len_plain: [4]u8
	byte_order.write_u32_big_endian(len_plain[:], 0, u32(packet_length))

	// Encrypt 4-byte packet length with K_2 at counter 0.
	header_cipher: chacha20.Context
	chacha20.init(&header_cipher, key[32:64], nonce[:])
	chacha20.seek(&header_cipher, 0)
	chacha20.xor_bytes(&header_cipher, out[0:4], len_plain[:])
	chacha20.reset(&header_cipher)

	// Write plaintext body into out[4 : 4 + packet_length], then encrypt in place with K_1.
	out[4] = u8(pad_len)
	copy(out[5 : 5 + len(payload)], payload)
	for i in 0 ..< pad_len {
		out[5 + len(payload) + i] = i < len(pad_bytes) ? pad_bytes[i] : u8(i + 1)
	}

	// Derive 32-byte Poly1305 one-time key from K_1 at counter 0, then encrypt body at counter 1.
	poly_key: [poly1305.KEY_SIZE]u8
	defer crypto.zero_explicit(&poly_key, size_of(poly_key))
	main_cipher: chacha20.Context
	chacha20.init(&main_cipher, key[0:32], nonce[:])
	chacha20.seek(&main_cipher, 0)
	chacha20.keystream_bytes(&main_cipher, poly_key[:])
	chacha20.seek(&main_cipher, 1)
	chacha20.xor_bytes(&main_cipher, out[4 : 4 + packet_length], out[4 : 4 + packet_length])
	chacha20.reset(&main_cipher)

	// Authenticate encrypted length || encrypted body with Poly1305.
	poly1305.sum(out[4 + packet_length : total], out[0 : 4 + packet_length], poly_key[:])
	return total, .Ok
}

// packet_open_chacha20_poly1305 verifies the Poly1305 MAC in constant time before decrypting
// the packet body, refusing tampered ciphertext, tampered length, bad padding, or oversized packets.
packet_open_chacha20_poly1305 :: proc "contextless" (key: ^[CHACHA20_POLY1305_KEY_SIZE]u8, seq: u32, wire: []u8, payload_out: []u8) -> (payload_len: int, consumed: int, status: Status) {
	context = ssh_zero_context()
	if key == nil {
		return 0, 0, .Invalid_Argument
	}
	if len(wire) < 4 + 1 + MIN_PADDING_LENGTH + POLY1305_TAG_SIZE {
		return 0, 0, .Truncated
	}

	nonce := build_openssh_chacha_nonce(seq)
	len_plain: [4]u8
	header_cipher: chacha20.Context
	chacha20.init(&header_cipher, key[32:64], nonce[:])
	chacha20.seek(&header_cipher, 0)
	chacha20.xor_bytes(&header_cipher, len_plain[:], wire[0:4])
	chacha20.reset(&header_cipher)

	packet_length := byte_order.read_u32_big_endian(len_plain[:], 0)
	if packet_length > MAX_PACKET_LENGTH {
		return 0, 0, .Oversized_Packet
	}
	if packet_length < 1 + MIN_PADDING_LENGTH {
		return 0, 0, .Bad_Padding
	}
	total := 4 + int(packet_length) + POLY1305_TAG_SIZE
	if len(wire) < total {
		return 0, 0, .Truncated
	}

	// Derive Poly1305 one-time key with K_1 at counter 0 and verify tag before decrypting.
	poly_key: [poly1305.KEY_SIZE]u8
	defer crypto.zero_explicit(&poly_key, size_of(poly_key))
	main_cipher: chacha20.Context
	chacha20.init(&main_cipher, key[0:32], nonce[:])
	chacha20.seek(&main_cipher, 0)
	chacha20.keystream_bytes(&main_cipher, poly_key[:])

	tag := wire[4 + int(packet_length) : total]
	if !poly1305.verify(tag, wire[0 : 4 + int(packet_length)], poly_key[:]) {
		chacha20.reset(&main_cipher)
		return 0, 0, .Not_Authentic
	}

	// Tag is authentic: decrypt the padding length byte first, validate bounds,
	// then stream payload directly into payload_out without a 35 KiB stack copy.
	chacha20.seek(&main_cipher, 1)
	pad_byte: [1]u8
	chacha20.xor_bytes(&main_cipher, pad_byte[:], wire[4:5])
	pad_len := int(pad_byte[0])
	if pad_len < MIN_PADDING_LENGTH || 1 + pad_len >= int(packet_length) {
		chacha20.reset(&main_cipher)
		return 0, 0, .Bad_Padding
	}
	plen := int(packet_length) - 1 - pad_len
	if len(payload_out) < plen {
		chacha20.reset(&main_cipher)
		return 0, 0, .Buffer_Too_Small
	}
	chacha20.xor_bytes(&main_cipher, payload_out[:plen], wire[5 : 5 + plen])
	chacha20.reset(&main_cipher)
	return plen, total, .Ok
}

// kexinit_build writes an SSH_MSG_KEXINIT payload advertising only the strict modern suite.
kexinit_build :: proc "contextless" (cookie: [COOKIE_SIZE]u8, out: []u8) -> (written: int, status: Status) {
	cookie := cookie
	enc := encoder_init(out)
	ok := encode_byte(&enc, u8(Message_Type.Kexinit)) &&
		encode_raw(&enc, cookie[:]) &&
		encode_ssh_string(&enc, ALG_KEX) &&
		encode_ssh_string(&enc, ALG_HOST_KEY) &&
		encode_ssh_string(&enc, ALG_CIPHER) &&
		encode_ssh_string(&enc, ALG_CIPHER) &&
		encode_ssh_string(&enc, ALG_MAC_IMPLICIT) &&
		encode_ssh_string(&enc, ALG_MAC_IMPLICIT) &&
		encode_ssh_string(&enc, ALG_COMPRESSION) &&
		encode_ssh_string(&enc, ALG_COMPRESSION) &&
		encode_ssh_string(&enc, "") &&
		encode_ssh_string(&enc, "") &&
		encode_bool(&enc, false) &&
		encode_u32(&enc, 0)
	if !ok {
		return 0, .Buffer_Too_Small
	}
	return enc.offset, .Ok
}

// kexinit_parse_and_negotiate verifies that the peer's KEXINIT supports our strict suite.
kexinit_parse_and_negotiate :: proc "contextless" (payload: []u8) -> (first_kex_packet_follows: bool, status: Status) {
	dec := decoder_init(payload)
	msg_byte, msg_ok := decode_byte(&dec)
	if !msg_ok {
		return false, .Truncated
	}
	msg_type, type_ok := message_type_of_byte(msg_byte)
	if !type_ok || msg_type != .Kexinit {
		return false, .Unexpected_Message
	}
	if _, cookie_ok := decode_raw(&dec, COOKIE_SIZE); !cookie_ok {
		return false, .Truncated
	}
	kex_algs, kex_ok := decode_ssh_bytes(&dec)
	host_key_algs, hk_ok := decode_ssh_bytes(&dec)
	enc_c2s, enc1_ok := decode_ssh_bytes(&dec)
	enc_s2c, enc2_ok := decode_ssh_bytes(&dec)
	_, mac1_ok := decode_ssh_bytes(&dec) // Implicit MAC for chacha20-poly1305@openssh.com.
	_, mac2_ok := decode_ssh_bytes(&dec)
	comp_c2s, comp1_ok := decode_ssh_bytes(&dec)
	comp_s2c, comp2_ok := decode_ssh_bytes(&dec)
	_, lang1_ok := decode_ssh_bytes(&dec)
	_, lang2_ok := decode_ssh_bytes(&dec)
	follows, follows_ok := decode_bool(&dec)
	_, reserved_ok := decode_u32(&dec)
	if !(kex_ok && hk_ok && enc1_ok && enc2_ok && mac1_ok && mac2_ok && comp1_ok && comp2_ok && lang1_ok && lang2_ok && follows_ok && reserved_ok) {
		return false, .Truncated
	}
	if decoder_remaining(&dec) != 0 {
		return false, .Truncated
	}
	if !name_list_contains(kex_algs, ALG_KEX) ||
		!name_list_contains(host_key_algs, ALG_HOST_KEY) ||
		!name_list_contains(enc_c2s, ALG_CIPHER) ||
		!name_list_contains(enc_s2c, ALG_CIPHER) ||
		!name_list_contains(comp_c2s, ALG_COMPRESSION) ||
		!name_list_contains(comp_s2c, ALG_COMPRESSION) {
		return false, .Algorithm_Mismatch
	}
	return follows, .Ok
}

// encode_ssh_ed25519_public_key encodes string("ssh-ed25519") || string(32-byte key).
encode_ssh_ed25519_public_key :: proc "contextless" (public_key: [ED25519_PUBLIC_KEY_SIZE]u8, out: []u8) -> (written: int, status: Status) {
	enc := encoder_init(out)
	pk := public_key
	if !encode_ssh_string(&enc, ALG_HOST_KEY) || !encode_ssh_bytes(&enc, pk[:]) {
		return 0, .Buffer_Too_Small
	}
	return enc.offset, .Ok
}

// parse_ssh_ed25519_public_key decodes string("ssh-ed25519") || string(32-byte key) with no trailing bytes.
parse_ssh_ed25519_public_key :: proc "contextless" (blob: []u8) -> (public_key: [ED25519_PUBLIC_KEY_SIZE]u8, status: Status) {
	dec := decoder_init(blob)
	alg, alg_ok := decode_ssh_bytes(&dec)
	key_bytes, key_ok := decode_ssh_bytes(&dec)
	if !alg_ok || !key_ok || decoder_remaining(&dec) != 0 {
		return {}, .Truncated
	}
	if !bytes_equal(alg, transmute([]u8)string(ALG_HOST_KEY)) {
		return {}, .Algorithm_Mismatch
	}
	if len(key_bytes) != ED25519_PUBLIC_KEY_SIZE {
		return {}, .Bad_Host_Signature
	}
	copy(public_key[:], key_bytes)
	return public_key, .Ok
}

// encode_ssh_ed25519_signature encodes string("ssh-ed25519") || string(64-byte signature).
encode_ssh_ed25519_signature :: proc "contextless" (signature: [ED25519_SIGNATURE_SIZE]u8, out: []u8) -> (written: int, status: Status) {
	enc := encoder_init(out)
	sig := signature
	if !encode_ssh_string(&enc, ALG_HOST_KEY) || !encode_ssh_bytes(&enc, sig[:]) {
		return 0, .Buffer_Too_Small
	}
	return enc.offset, .Ok
}

// parse_ssh_ed25519_signature decodes string("ssh-ed25519") || string(64-byte signature).
parse_ssh_ed25519_signature :: proc "contextless" (blob: []u8) -> (signature: [ED25519_SIGNATURE_SIZE]u8, status: Status) {
	dec := decoder_init(blob)
	alg, alg_ok := decode_ssh_bytes(&dec)
	sig_bytes, sig_ok := decode_ssh_bytes(&dec)
	if !alg_ok || !sig_ok || decoder_remaining(&dec) != 0 {
		return {}, .Truncated
	}
	if !bytes_equal(alg, transmute([]u8)string(ALG_HOST_KEY)) {
		return {}, .Algorithm_Mismatch
	}
	if len(sig_bytes) != ED25519_SIGNATURE_SIZE {
		return {}, .Bad_Host_Signature
	}
	copy(signature[:], sig_bytes)
	return signature, .Ok
}

// x25519_public_from_secret computes the Curve25519 public key from a 32-byte scalar (RFC 7748).
x25519_public_from_secret :: proc "contextless" (secret: [X25519_KEY_SIZE]u8) -> (public_key: [X25519_KEY_SIZE]u8, status: Status) {
	s := secret
	defer crypto.zero_explicit(&s, size_of(s))
	base_point: [X25519_KEY_SIZE]u8
	base_point[0] = 9
	scalar_str := string(s[:])
	point_str := string(base_point[:])
	out_slice := public_key[:]
	err: errors.Error_Record
	n := cryptography_primitives.x25519(&scalar_str, &point_str, &out_slice, &err)
	if n != X25519_KEY_SIZE {
		return {}, .Bad_Kex_Point
	}
	return public_key, .Ok
}

// x25519_shared_secret computes the X25519 shared secret and refuses small-order peer points.
x25519_shared_secret :: proc "contextless" (secret: [X25519_KEY_SIZE]u8, peer_public: [X25519_KEY_SIZE]u8) -> (shared: [X25519_KEY_SIZE]u8, status: Status) {
	s := secret
	p := peer_public
	defer crypto.zero_explicit(&s, size_of(s))
	scalar_str := string(s[:])
	point_str := string(p[:])
	out_slice := shared[:]
	err: errors.Error_Record
	n := cryptography_primitives.x25519(&scalar_str, &point_str, &out_slice, &err)
	if n != X25519_KEY_SIZE {
		crypto.zero_explicit(&shared, size_of(shared))
		return {}, .Bad_Kex_Point
	}
	return shared, .Ok
}

// sha256_bytes hashes input bytes with modus:cryptography_primitives.sha256.
sha256_bytes :: proc "contextless" (input: []u8, digest_out: ^[SHA256_DIGEST_SIZE]u8) -> bool {
	in_str := string(input)
	out_slice := digest_out[:]
	return cryptography_primitives.sha256(&in_str, &out_slice) == SHA256_DIGEST_SIZE
}

// compute_exchange_hash computes H = SHA-256(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || mpint(K))
// (RFC 8731, section 3.1).
MAX_EXCHANGE_HASH_INPUT :: 8192

compute_exchange_hash :: proc "contextless" (
	v_c, v_s, i_c, i_s, k_s, q_c, q_s, shared_secret: []u8,
	hash_out: ^[SHA256_DIGEST_SIZE]u8,
) -> Status {
	if hash_out == nil || len(q_c) != X25519_KEY_SIZE || len(q_s) != X25519_KEY_SIZE || len(shared_secret) != X25519_KEY_SIZE {
		return .Invalid_Argument
	}
	scratch: [MAX_EXCHANGE_HASH_INPUT]u8
	defer crypto.zero_explicit(&scratch, size_of(scratch))
	enc := encoder_init(scratch[:])
	ok := encode_ssh_bytes(&enc, v_c) &&
		encode_ssh_bytes(&enc, v_s) &&
		encode_ssh_bytes(&enc, i_c) &&
		encode_ssh_bytes(&enc, i_s) &&
		encode_ssh_bytes(&enc, k_s) &&
		encode_ssh_bytes(&enc, q_c) &&
		encode_ssh_bytes(&enc, q_s) &&
		encode_mpint(&enc, shared_secret)
	if !ok {
		return .Buffer_Too_Small
	}
	if !sha256_bytes(encoder_bytes(&enc), hash_out) {
		return .Crypto_Error
	}
	return .Ok
}

// derive_key derives key material according to RFC 4253 section 7.2:
// K1 = HASH(mpint(K) || H || letter || session_id)
// K2 = HASH(mpint(K) || H || K1) ... until len(key_out) bytes are produced.
derive_key :: proc "contextless" (
	shared_secret: []u8,
	exchange_hash: ^[SHA256_DIGEST_SIZE]u8,
	letter: Key_Letter,
	session_id: ^[SHA256_DIGEST_SIZE]u8,
	key_out: []u8,
) -> Status {
	if exchange_hash == nil || session_id == nil || len(shared_secret) != X25519_KEY_SIZE || len(key_out) == 0 || len(key_out) > 128 {
		return .Invalid_Argument
	}
	scratch: [256]u8
	defer crypto.zero_explicit(&scratch, size_of(scratch))

	// Block 1: mpint(K) || H || letter || session_id
	enc := encoder_init(scratch[:])
	if !encode_mpint(&enc, shared_secret) ||
		!encode_raw(&enc, exchange_hash[:]) ||
		!encode_byte(&enc, u8(letter)) ||
		!encode_raw(&enc, session_id[:]) {
		return .Buffer_Too_Small
	}
	block: [SHA256_DIGEST_SIZE]u8
	defer crypto.zero_explicit(&block, size_of(block))
	if !sha256_bytes(encoder_bytes(&enc), &block) {
		return .Crypto_Error
	}
	produced := min(len(key_out), SHA256_DIGEST_SIZE)
	copy(key_out[:produced], block[:produced])

	// Subsequent blocks: mpint(K) || H || K1 || ... || Kn
	for produced < len(key_out) {
		enc_next := encoder_init(scratch[:])
		if !encode_mpint(&enc_next, shared_secret) ||
			!encode_raw(&enc_next, exchange_hash[:]) ||
			!encode_raw(&enc_next, key_out[:produced]) {
			return .Buffer_Too_Small
		}
		if !sha256_bytes(encoder_bytes(&enc_next), &block) {
			return .Crypto_Error
		}
		take := min(len(key_out) - produced, SHA256_DIGEST_SIZE)
		copy(key_out[produced : produced + take], block[:take])
		produced += take
	}
	return .Ok
}
