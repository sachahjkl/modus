#+build !freestanding
package tls_tcp

import "core:testing"
import "modus:contract/byte_order"

@(private = "file")
make_test_configs :: proc(suite: Tls_Cipher_Suite, restrict: bool) -> (client_cfg: Tls_Config, server_cfg: Tls_Config) {
	server_ed_priv := [ED25519_KEY_SIZE]u8{
		0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
		0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01,
		0x12, 0x23, 0x34, 0x45, 0x56, 0x67, 0x78, 0x89,
		0x9A, 0xAB, 0xBC, 0xCD, 0xDE, 0xEF, 0xF0, 0x02,
	}
	server_ed_pub: [ED25519_KEY_SIZE]u8
	_ = ed25519_derive_public(server_ed_priv[:], &server_ed_pub)

	client_cfg = Tls_Config{
		role                     = .Client,
		preferred_suite          = suite,
		restrict_to_preferred    = restrict,
		pinned_server_public_key = server_ed_pub,
	}
	sni := "example.modus.test"
	copy(client_cfg.server_name[:], sni)
	client_cfg.server_name_len = len(sni)
	for i := 0; i < 32; i += 1 {
		client_cfg.ephemeral_private_key[i] = u8(0x40 + i)
		client_cfg.random_bytes[i] = u8(0x80 + i)
	}

	server_cfg = Tls_Config{
		role                       = .Server,
		preferred_suite            = suite,
		server_ed25519_private_key = server_ed_priv,
	}
	for i := 0; i < 32; i += 1 {
		server_cfg.ephemeral_private_key[i] = u8(0x20 + i)
		server_cfg.random_bytes[i] = u8(0xA0 + i)
	}
	return client_cfg, server_cfg
}

@(private = "file")
pump_stream :: proc(from: ^Tls_Session, to: ^Tls_Session, chunk_size: int) -> Tls_Refusal {
	wire := make([]u8, MAX_WIRE_BUFFER)
	defer delete(wire)
	n := tls_take_outgoing(from, wire)
	if n == 0 {
		return .None
	}
	step := chunk_size if chunk_size > 0 else n
	offset := 0
	for offset < n {
		end := min(offset + step, n)
		if r := tls_feed_incoming(to, wire[offset:end]); r != .None {
			return r
		}
		offset = end
	}
	return .None
}

@(test)
test_enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	_, ok := tls_role_of_word(0)
	testing.expect(t, !ok, "role 0 must be refused")
	role, ok2 := tls_role_of_word(1)
	testing.expect(t, ok2 && role == .Client, "role 1 must decode as Client")
	role, ok2 = tls_role_of_word(2)
	testing.expect(t, ok2 && role == .Server, "role 2 must decode as Server")
	_, ok = tls_role_of_word(3)
	testing.expect(t, !ok, "role 3 must be refused")
	_, ok = tls_role_of_word(255)
	testing.expect(t, !ok, "role 255 must be refused")

	for bad in ([]u8{0, 1, 19, 24, 255}) {
		_, ct_ok := content_type_of_word(bad)
		testing.expectf(t, !ct_ok, "content type %d must be refused", bad)
	}
	ct, ct_ok := content_type_of_word(23)
	testing.expect(t, ct_ok && ct == .Application_Data, "content type 23 must decode as Application_Data")

	for bad in ([]u16{0, 1, 0x1300, 0x1302, 0x1304, 0xFFFF}) {
		_, cs_ok := cipher_suite_of_word(bad)
		testing.expectf(t, !cs_ok, "cipher suite 0x%04x must be refused", bad)
	}
	cs, cs_ok := cipher_suite_of_word(0x1301)
	testing.expect(t, cs_ok && cs == .TLS_AES_128_GCM_SHA256, "0x1301 must decode as AES-128-GCM")
	cs, cs_ok = cipher_suite_of_word(0x1303)
	testing.expect(t, cs_ok && cs == .TLS_CHACHA20_POLY1305_SHA256, "0x1303 must decode as ChaCha20-Poly1305")
}

@(test)
test_record_layer_roundtrip_and_attacks :: proc(t: ^testing.T) {
	secret := [HASH_SIZE]u8{
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
		17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
	}

	for suite in ([]Tls_Cipher_Suite{.TLS_AES_128_GCM_SHA256, .TLS_CHACHA20_POLY1305_SHA256}) {
		send_k, recv_k: Traffic_Keys
		testing.expect_value(t, derive_traffic_keys(suite, secret[:], &send_k), Tls_Refusal.None)
		testing.expect_value(t, derive_traffic_keys(suite, secret[:], &recv_k), Tls_Refusal.None)

		rec_buf := make([]u8, MAX_CIPHERTEXT_SIZE + RECORD_HEADER_SIZE + 32)
		plain_buf := make([]u8, MAX_PLAINTEXT_SIZE + 32)
		defer delete(rec_buf)
		defer delete(plain_buf)

		// 1. Round-trip with padding stripped cleanly.
		msg := transmute([]u8)string("hello tls 1.3 record layer")
		n, ref := record_encrypt(&send_k, .Application_Data, msg, 17, rec_buf)
		testing.expect_value(t, ref, Tls_Refusal.None)
		testing.expect_value(t, n, RECORD_HEADER_SIZE + len(msg) + 1 + 17 + AEAD_TAG_SIZE)

		inner_ct, plen, dref := record_decrypt(&recv_k, rec_buf[:n], plain_buf)
		testing.expect_value(t, dref, Tls_Refusal.None)
		testing.expect_value(t, inner_ct, Tls_Content_Type.Application_Data)
		testing.expect_value(t, plen, len(msg))
		testing.expect_value(t, string(plain_buf[:plen]), string(msg))
		testing.expect_value(t, send_k.sequence_number, u64(1))
		testing.expect_value(t, recv_k.sequence_number, u64(1))

		// 2. Exact MAX_PLAINTEXT_SIZE (16384 bytes) succeeds.
		big_plain := make([]u8, MAX_PLAINTEXT_SIZE + 1)
		defer delete(big_plain)
		for i := 0; i < len(big_plain); i += 1 {
			big_plain[i] = u8(i & 0xFF)
		}
		n, ref = record_encrypt(&send_k, .Application_Data, big_plain[:MAX_PLAINTEXT_SIZE], 0, rec_buf)
		testing.expect_value(t, ref, Tls_Refusal.None)
		inner_ct, plen, dref = record_decrypt(&recv_k, rec_buf[:n], plain_buf)
		testing.expect_value(t, dref, Tls_Refusal.None)
		testing.expect_value(t, plen, MAX_PLAINTEXT_SIZE)

		// 3. Oversized plaintext (16385 bytes) refused.
		_, ref = record_encrypt(&send_k, .Application_Data, big_plain[:MAX_PLAINTEXT_SIZE + 1], 0, rec_buf)
		testing.expect_value(t, ref, Tls_Refusal.Record_Too_Large)

		// 4. Oversized ciphertext header (16641 bytes) refused.
		bad_hdr := [5]u8{u8(Tls_Content_Type.Application_Data), 0x03, 0x03, 0x41, 0x01} // 16641
		_, hdr_ref := record_parse_header(bad_hdr[:], false)
		testing.expect_value(t, hdr_ref, Tls_Refusal.Record_Too_Large)

		// 5. Tampered ciphertext byte refused, sequence number unchanged.
		n, ref = record_encrypt(&send_k, .Application_Data, msg, 0, rec_buf)
		testing.expect_value(t, ref, Tls_Refusal.None)
		rec_buf[RECORD_HEADER_SIZE + 2] ~= 0x01
		seq_before := recv_k.sequence_number
		_, _, dref = record_decrypt(&recv_k, rec_buf[:n], plain_buf)
		testing.expect_value(t, dref, Tls_Refusal.Authentication_Failed)
		testing.expect_value(t, recv_k.sequence_number, seq_before)

		// 6. Tampered AEAD tag byte refused.
		rec_buf[RECORD_HEADER_SIZE + 2] ~= 0x01 // restore ciphertext
		rec_buf[n - 1] ~= 0x80 // flip tag
		_, _, dref = record_decrypt(&recv_k, rec_buf[:n], plain_buf)
		testing.expect_value(t, dref, Tls_Refusal.Authentication_Failed)

		// 7. Sequence number exhaustion at max(u64) refused on BOTH encrypt and decrypt.
		send_k.sequence_number = max(u64)
		_, ref = record_encrypt(&send_k, .Application_Data, msg, 0, rec_buf)
		testing.expect_value(t, ref, Tls_Refusal.Sequence_Exhausted)
		testing.expect_value(t, send_k.sequence_number, max(u64))

		recv_k.sequence_number = max(u64)
		_, _, dref = record_decrypt(&recv_k, rec_buf[:n], plain_buf)
		testing.expect_value(t, dref, Tls_Refusal.Sequence_Exhausted)
		testing.expect_value(t, recv_k.sequence_number, max(u64))
	}
}

@(test)
test_full_handshake_and_bidirectional_data_both_suites :: proc(t: ^testing.T) {
	for suite in ([]Tls_Cipher_Suite{.TLS_AES_128_GCM_SHA256, .TLS_CHACHA20_POLY1305_SHA256}) {
		client_cfg, server_cfg := make_test_configs(suite, true)
		client := new(Tls_Session)
		server := new(Tls_Session)
		defer free(client)
		defer free(server)

		testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)

		// Deliver ClientHello in small 7-byte TCP chunks to verify reassembly.
		testing.expect_value(t, pump_stream(client, server, 7), Tls_Refusal.None)
		testing.expect_value(t, server.state, Tls_State.Server_Wait_Client_Finished)
		testing.expect_value(t, server.negotiated_suite, suite)
		testing.expect_value(t, string(server.peer_server_name[:server.peer_server_name_len]), "example.modus.test")

		// Deliver Server flight (SH + EE + Cert + CV + SF) in 11-byte TCP chunks.
		testing.expect_value(t, pump_stream(server, client, 11), Tls_Refusal.None)
		testing.expect_value(t, client.state, Tls_State.Connected)
		testing.expect_value(t, client.negotiated_suite, suite)

		// Deliver Client Finished.
		testing.expect_value(t, pump_stream(client, server, 5), Tls_Refusal.None)
		testing.expect_value(t, server.state, Tls_State.Connected)

		// Bidirectional encrypted Application_Data exchange.
		req := transmute([]u8)string("GET / HTTP/1.1\r\nHost: example.modus.test\r\n\r\n")
		testing.expect_value(t, tls_send_application_data(client, req), Tls_Refusal.None)
		testing.expect_value(t, pump_stream(client, server, 13), Tls_Refusal.None)

		read_buf := make([]u8, 1024)
		defer delete(read_buf)
		got := tls_read_application_data(server, read_buf)
		testing.expect_value(t, string(read_buf[:got]), string(req))

		resp := transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
		testing.expect_value(t, tls_send_application_data(server, resp), Tls_Refusal.None)
		testing.expect_value(t, pump_stream(server, client, 9), Tls_Refusal.None)
		got = tls_read_application_data(client, read_buf)
		testing.expect_value(t, string(read_buf[:got]), string(resp))

		// Clean close_notify alert.
		testing.expect_value(t, tls_send_close_notify(client), Tls_Refusal.None)
		testing.expect_value(t, client.state, Tls_State.Closed)
		testing.expect_value(t, pump_stream(client, server, 0), Tls_Refusal.None)
		testing.expect_value(t, server.state, Tls_State.Closed)
		testing.expect(t, server.peer_closed, "server must observe peer close_notify")
	}
}

@(test)
test_tampered_wire_ciphertext_refused :: proc(t: ^testing.T) {
	client_cfg, server_cfg := make_test_configs(.TLS_CHACHA20_POLY1305_SHA256, true)
	client := new(Tls_Session)
	server := new(Tls_Session)
	defer free(client)
	defer free(server)

	testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)
	testing.expect_value(t, pump_stream(client, server, 0), Tls_Refusal.None)

	// Capture server flight, flip one byte in the encrypted portion (past ServerHello).
	wire := make([]u8, MAX_WIRE_BUFFER)
	defer delete(wire)
	n := tls_take_outgoing(server, wire)
	testing.expect(t, n > 100, "server flight must be non-empty")
	wire[n - 5] ~= 0x40
	ref := tls_feed_incoming(client, wire[:n])
	testing.expect_value(t, ref, Tls_Refusal.Authentication_Failed)
	testing.expect_value(t, client.state, Tls_State.Failed)
}

@(test)
test_bad_certificate_verify_signature_refused :: proc(t: ^testing.T) {
	client_cfg, server_cfg := make_test_configs(.TLS_AES_128_GCM_SHA256, true)
	client := new(Tls_Session)
	server := new(Tls_Session)
	defer free(client)
	defer free(server)

	testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)
	testing.expect_value(t, pump_stream(client, server, 0), Tls_Refusal.None)

	// Walk server outgoing records: SH (plaintext), EE (enc 0), Cert (enc 1), CV (enc 2), SF (enc 3).
	// Re-encrypt CV with a corrupted Ed25519 signature using the real server handshake traffic key!
	wire := make([]u8, MAX_WIRE_BUFFER)
	defer delete(wire)
	_ = tls_take_outgoing(server, wire)

	// Find offsets of records 0..3.
	pos := 0
	rec_starts: [5]int
	rec_lens: [5]int
	for i := 0; i < 5; i += 1 {
		rec_starts[i] = pos
		rlen := int(byte_order.read_u16_big_endian(wire, pos + 3))
		rec_lens[i] = RECORD_HEADER_SIZE + rlen
		pos += rec_lens[i]
	}

	// Feed SH, EE, Cert cleanly.
	testing.expect_value(t, tls_feed_incoming(client, wire[:rec_starts[3]]), Tls_Refusal.None)
	testing.expect_value(t, client.state, Tls_State.Client_Wait_Certificate_Verify)

	// Decrypt the real CV record with a copy of client's recv_keys, flip 1 bit in signature, re-encrypt.
	dec_keys := client.recv_keys
	enc_keys := client.recv_keys
	plain_cv := make([]u8, 256)
	defer delete(plain_cv)
	ct, cv_len, dref := record_decrypt(&dec_keys, wire[rec_starts[3]:rec_starts[3] + rec_lens[3]], plain_cv)
	testing.expect_value(t, dref, Tls_Refusal.None)
	testing.expect_value(t, ct, Tls_Content_Type.Handshake)

	// Flip 1 bit in the 64-byte Ed25519 signature.
	plain_cv[cv_len - 1] ~= 0x01

	forged_cv := make([]u8, 256)
	defer delete(forged_cv)
	forged_len, eref := record_encrypt(&enc_keys, .Handshake, plain_cv[:cv_len], 0, forged_cv)
	testing.expect_value(t, eref, Tls_Refusal.None)

	ref := tls_feed_incoming(client, forged_cv[:forged_len])
	testing.expect_value(t, ref, Tls_Refusal.Invalid_Certificate_Verify)
	testing.expect_value(t, client.state, Tls_State.Failed)
}

@(test)
test_tampered_server_finished_refused :: proc(t: ^testing.T) {
	client_cfg, server_cfg := make_test_configs(.TLS_CHACHA20_POLY1305_SHA256, true)
	client := new(Tls_Session)
	server := new(Tls_Session)
	defer free(client)
	defer free(server)

	testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)
	testing.expect_value(t, pump_stream(client, server, 0), Tls_Refusal.None)

	wire := make([]u8, MAX_WIRE_BUFFER)
	defer delete(wire)
	_ = tls_take_outgoing(server, wire)

	pos := 0
	rec_starts: [5]int
	rec_lens: [5]int
	for i := 0; i < 5; i += 1 {
		rec_starts[i] = pos
		rlen := int(byte_order.read_u16_big_endian(wire, pos + 3))
		rec_lens[i] = RECORD_HEADER_SIZE + rlen
		pos += rec_lens[i]
	}

	// Feed SH, EE, Cert, CV cleanly.
	testing.expect_value(t, tls_feed_incoming(client, wire[:rec_starts[4]]), Tls_Refusal.None)
	testing.expect_value(t, client.state, Tls_State.Client_Wait_Finished)

	// Decrypt real server Finished, corrupt verify_data by 1 bit, re-encrypt validly.
	dec_keys := client.recv_keys
	enc_keys := client.recv_keys
	plain_fin := make([]u8, 128)
	defer delete(plain_fin)
	_, fin_len, dref := record_decrypt(&dec_keys, wire[rec_starts[4]:rec_starts[4] + rec_lens[4]], plain_fin)
	testing.expect_value(t, dref, Tls_Refusal.None)

	plain_fin[fin_len - 1] ~= 0x01

	forged_fin := make([]u8, 128)
	defer delete(forged_fin)
	forged_len, eref := record_encrypt(&enc_keys, .Handshake, plain_fin[:fin_len], 0, forged_fin)
	testing.expect_value(t, eref, Tls_Refusal.None)

	ref := tls_feed_incoming(client, forged_fin[:forged_len])
	testing.expect_value(t, ref, Tls_Refusal.Invalid_Finished)
	testing.expect_value(t, client.state, Tls_State.Failed)
}

@(test)
test_wrong_pinned_server_key_refused :: proc(t: ^testing.T) {
	client_cfg, server_cfg := make_test_configs(.TLS_AES_128_GCM_SHA256, true)
	client_cfg.pinned_server_public_key[0] ~= 0xFF // pin a different key
	client := new(Tls_Session)
	server := new(Tls_Session)
	defer free(client)
	defer free(server)

	testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)
	testing.expect_value(t, pump_stream(client, server, 0), Tls_Refusal.None)

	ref := pump_stream(server, client, 0)
	testing.expect_value(t, ref, Tls_Refusal.Invalid_Certificate)
	testing.expect_value(t, client.state, Tls_State.Failed)
}

@(test)
test_tls12_downgrade_attempts_refused :: proc(t: ^testing.T) {
	// Case 1: ServerHello with TLS 1.2 downgrade sentinel in random[24..32].
	{
		client_cfg, _ := make_test_configs(.TLS_AES_128_GCM_SHA256, true)
		client := new(Tls_Session)
		defer free(client)
		testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)

		sh: [128]u8
		pos := HANDSHAKE_HEADER_SIZE
		byte_order.write_u16_big_endian(sh[:], pos, TLS_LEGACY_VERSION)
		pos += 2
		for i := 0; i < 24; i += 1 {
			sh[pos + i] = u8(i + 1)
		}
		dg := TLS12_DOWNGRADE_SENTINEL
		copy(sh[pos + 24:pos + 32], dg[:])
		pos += 32
		sh[pos] = 0 // empty session id
		pos += 1
		byte_order.write_u16_big_endian(sh[:], pos, u16(Tls_Cipher_Suite.TLS_AES_128_GCM_SHA256))
		pos += 2
		sh[pos] = 0 // compression
		pos += 1
		byte_order.write_u16_big_endian(sh[:], pos, 0) // no extensions
		pos += 2
		sh[0] = u8(Tls_Handshake_Type.Server_Hello)
		body_len := pos - HANDSHAKE_HEADER_SIZE
		sh[1] = u8((body_len >> 16) & 0xFF)
		sh[2] = u8((body_len >> 8) & 0xFF)
		sh[3] = u8(body_len & 0xFF)

		rec: [160]u8
		rn, wref := record_write_plaintext(.Handshake, sh[:pos], rec[:])
		testing.expect_value(t, wref, Tls_Refusal.None)
		testing.expect_value(t, tls_feed_incoming(client, rec[:rn]), Tls_Refusal.Downgrade_Refused)
	}

	// Case 2: ServerHello without supported_versions extension (plain TLS 1.2 ServerHello).
	{
		client_cfg, _ := make_test_configs(.TLS_AES_128_GCM_SHA256, true)
		client := new(Tls_Session)
		defer free(client)
		testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)

		sh: [128]u8
		pos := HANDSHAKE_HEADER_SIZE
		byte_order.write_u16_big_endian(sh[:], pos, TLS_LEGACY_VERSION)
		pos += 2
		for i := 0; i < 32; i += 1 {
			sh[pos + i] = u8(0x55)
		}
		pos += 32
		sh[pos] = 0
		pos += 1
		byte_order.write_u16_big_endian(sh[:], pos, u16(Tls_Cipher_Suite.TLS_AES_128_GCM_SHA256))
		pos += 2
		sh[pos] = 0
		pos += 1
		sh[0] = u8(Tls_Handshake_Type.Server_Hello)
		body_len := pos - HANDSHAKE_HEADER_SIZE
		sh[1] = 0
		sh[2] = u8((body_len >> 8) & 0xFF)
		sh[3] = u8(body_len & 0xFF)

		rec: [160]u8
		rn, wref := record_write_plaintext(.Handshake, sh[:pos], rec[:])
		testing.expect_value(t, wref, Tls_Refusal.None)
		testing.expect_value(t, tls_feed_incoming(client, rec[:rn]), Tls_Refusal.Downgrade_Refused)
	}

	// Case 3: ClientHello offering only TLS 1.2 (0x0303) refused by server.
	{
		client_cfg, server_cfg := make_test_configs(.TLS_AES_128_GCM_SHA256, true)
		client := new(Tls_Session)
		server := new(Tls_Session)
		defer free(client)
		defer free(server)
		testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)

		wire := make([]u8, 1024)
		defer delete(wire)
		n := tls_take_outgoing(client, wire)
		// Locate supported_versions value 0x03 0x04 in ClientHello and mutate it to 0x03 0x03.
		mutated := false
		for i := RECORD_HEADER_SIZE; i + 4 < n; i += 1 {
			if wire[i] == 0x00 && wire[i + 1] == 0x2B && wire[i + 4] == 0x02 && wire[i + 5] == 0x03 && wire[i + 6] == 0x04 {
				wire[i + 6] = 0x03
				mutated = true
				break
			}
		}
		testing.expect(t, mutated, "must locate supported_versions extension in ClientHello")
		testing.expect_value(t, tls_feed_incoming(server, wire[:n]), Tls_Refusal.Downgrade_Refused)
	}
}

@(test)
test_tampered_client_finished_refused :: proc(t: ^testing.T) {
	client_cfg, server_cfg := make_test_configs(.TLS_AES_128_GCM_SHA256, true)
	client := new(Tls_Session)
	server := new(Tls_Session)
	defer free(client)
	defer free(server)

	testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
	testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)
	testing.expect_value(t, pump_stream(client, server, 0), Tls_Refusal.None)
	testing.expect_value(t, pump_stream(server, client, 0), Tls_Refusal.None)

	// Client has queued encrypted Finished; decrypt with server's recv_keys, flip verify_data, re-encrypt.
	wire := make([]u8, 256)
	defer delete(wire)
	n := tls_take_outgoing(client, wire)

	dec_keys := server.recv_keys
	enc_keys := server.recv_keys
	plain := make([]u8, 128)
	defer delete(plain)
	_, plen, dref := record_decrypt(&dec_keys, wire[:n], plain)
	testing.expect_value(t, dref, Tls_Refusal.None)
	plain[plen - 1] ~= 0x02

	forged := make([]u8, 256)
	defer delete(forged)
	fn, eref := record_encrypt(&enc_keys, .Handshake, plain[:plen], 0, forged)
	testing.expect_value(t, eref, Tls_Refusal.None)

	testing.expect_value(t, tls_feed_incoming(server, forged[:fn]), Tls_Refusal.Invalid_Finished)
	testing.expect_value(t, server.state, Tls_State.Failed)
}

@(test)
test_small_order_key_share_and_hello_retry_refused :: proc(t: ^testing.T) {
	// Small-order all-zero X25519 key share in ClientHello is refused.
	{
		client_cfg, server_cfg := make_test_configs(.TLS_CHACHA20_POLY1305_SHA256, true)
		client := new(Tls_Session)
		server := new(Tls_Session)
		defer free(client)
		defer free(server)
		testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_session_init(server, &server_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)

		wire := make([]u8, 1024)
		defer delete(wire)
		n := tls_take_outgoing(client, wire)
		// Last 32 bytes of ClientHello are the X25519 key_share public key.
		for i := n - 32; i < n; i += 1 {
			wire[i] = 0
		}
		testing.expect_value(t, tls_feed_incoming(server, wire[:n]), Tls_Refusal.Invalid_Key_Share)
	}

	// HelloRetryRequest random in ServerHello is refused.
	{
		client_cfg, _ := make_test_configs(.TLS_CHACHA20_POLY1305_SHA256, true)
		client := new(Tls_Session)
		defer free(client)
		testing.expect_value(t, tls_session_init(client, &client_cfg), Tls_Refusal.None)
		testing.expect_value(t, tls_client_start(client), Tls_Refusal.None)

		sh: [128]u8
		pos := HANDSHAKE_HEADER_SIZE
		byte_order.write_u16_big_endian(sh[:], pos, TLS_LEGACY_VERSION)
		pos += 2
		hrr := HELLO_RETRY_REQUEST_RANDOM
		copy(sh[pos:pos + 32], hrr[:])
		pos += 32
		sh[pos] = 0
		pos += 1
		byte_order.write_u16_big_endian(sh[:], pos, u16(Tls_Cipher_Suite.TLS_CHACHA20_POLY1305_SHA256))
		pos += 2
		sh[pos] = 0
		pos += 1
		byte_order.write_u16_big_endian(sh[:], pos, 0)
		pos += 2
		sh[0] = u8(Tls_Handshake_Type.Server_Hello)
		body_len := pos - HANDSHAKE_HEADER_SIZE
		sh[1] = 0
		sh[2] = u8((body_len >> 8) & 0xFF)
		sh[3] = u8(body_len & 0xFF)

		rec: [160]u8
		rn, wref := record_write_plaintext(.Handshake, sh[:pos], rec[:])
		testing.expect_value(t, wref, Tls_Refusal.None)
		testing.expect_value(t, tls_feed_incoming(client, rec[:rn]), Tls_Refusal.Invalid_Key_Share)
	}
}

