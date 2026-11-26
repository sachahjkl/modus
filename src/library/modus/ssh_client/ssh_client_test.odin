#+build !freestanding
#+build !modus
package ssh_client

import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/text_encoding"
import "modus:cryptography_primitives"

// The pair of a procedure of the call form, as one value that a check
// compares.
@(private = "file")
Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}

@(private = "file")
answer_of :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> Answer {
	return {outcome, value}
}

// refused says if a call refused an argument: the outcome Argument_Refused
// and the value 0.
@(private = "file")
refused :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> bool {
	return outcome == .Argument_Refused && value == 0
}

// Helper: build an in-memory mock SSH-2 server for full end-to-end protocol testing.
@(private = "file")
Mock_Ssh_Server :: struct {
	banner:           string,
	host_ed_secret:   [ED25519_PRIVATE_KEY_SIZE]u8,
	host_ed_public:   [ED25519_PUBLIC_KEY_SIZE]u8,
	kex_secret:       [X25519_KEY_SIZE]u8,
	kex_public:       [X25519_KEY_SIZE]u8,
	cookie:           [COOKIE_SIZE]u8,
	client_banner:    [MAX_BANNER_LENGTH]u8,
	client_banner_n:  int,
	client_kexinit:   [MAX_KEXINIT_SIZE]u8,
	client_kexinit_n: int,
	server_kexinit:   [MAX_KEXINIT_SIZE]u8,
	server_kexinit_n: int,
	session_id:       [SHA256_DIGEST_SIZE]u8,
	exchange_hash:    [SHA256_DIGEST_SIZE]u8,
	c2s_key:          [CHACHA20_POLY1305_KEY_SIZE]u8,
	s2c_key:          [CHACHA20_POLY1305_KEY_SIZE]u8,
	send_seq:         u32,
	recv_seq:         u32,
	encrypted:        bool,
}

@(private = "file")
mock_server_init :: proc(t: ^testing.T, srv: ^Mock_Ssh_Server, host_seed, kex_seed: u8) {
	srv^ = {}
	srv.banner = "SSH-2.0-MockOpenSSH_9.8"
	for i in 0 ..< 32 {
		srv.host_ed_secret[i] = host_seed + u8(i * 3 + 1)
		srv.kex_secret[i] = kex_seed + u8(i * 5 + 7)
	}
	for i in 0 ..< COOKIE_SIZE {
		srv.cookie[i] = u8(0xA0 + i)
	}
	sec_str := string(srv.host_ed_secret[:])
	pub_slice := srv.host_ed_public[:]
	err: errors.Error_Record
	_, n := cryptography_primitives.ed25519_public_key(&sec_str, &pub_slice, &err)
	testing.expect_value(t, n, i64(ED25519_PUBLIC_KEY_SIZE))

	pub, st := x25519_public_from_secret(srv.kex_secret)
	testing.expect_value(t, st, Status.Ok)
	srv.kex_public = pub
}

@(private = "file")
mock_server_send :: proc(srv: ^Mock_Ssh_Server, payload: []u8, out: []u8) -> (int, Status) {
	pad := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	if srv.encrypted {
		n, st := packet_seal_chacha20_poly1305(&srv.s2c_key, srv.send_seq, payload, pad[:], out)
		if st == .Ok {
			srv.send_seq += 1
		}
		return n, st
	}
	n, st := packet_pack_plain(payload, pad[:], out)
	if st == .Ok {
		srv.send_seq += 1
	}
	return n, st
}

@(private = "file")
mock_server_recv :: proc(srv: ^Mock_Ssh_Server, wire: []u8, payload_out: []u8) -> (int, Status) {
	if srv.encrypted {
		plen, _, st := packet_open_chacha20_poly1305(&srv.c2s_key, srv.recv_seq, wire, payload_out)
		if st == .Ok {
			srv.recv_seq += 1
		}
		return plen, st
	}
	plen, _, st := packet_unpack_plain(wire, payload_out)
	if st == .Ok {
		srv.recv_seq += 1
	}
	return plen, st
}

@(private = "file")
mock_server_build_kex_reply :: proc(
	t: ^testing.T,
	srv: ^Mock_Ssh_Server,
	client_q_c: [X25519_KEY_SIZE]u8,
	override_q_s: ^[X25519_KEY_SIZE]u8,
	corrupt_sig: bool,
	out: []u8,
) -> int {
	client_q_c := client_q_c
	q_s := override_q_s != nil ? override_q_s^ : srv.kex_public
	shared, ss_st := x25519_shared_secret(srv.kex_secret, client_q_c)
	testing.expect_value(t, ss_st, Status.Ok)

	k_s_blob: [64]u8
	k_s_len, ks_st := encode_ssh_ed25519_public_key(srv.host_ed_public, k_s_blob[:])
	testing.expect_value(t, ks_st, Status.Ok)

	h_st := compute_exchange_hash(
		srv.client_banner[:srv.client_banner_n],
		transmute([]u8)srv.banner,
		srv.client_kexinit[:srv.client_kexinit_n],
		srv.server_kexinit[:srv.server_kexinit_n],
		k_s_blob[:k_s_len],
		client_q_c[:],
		q_s[:],
		shared[:],
		&srv.exchange_hash,
	)
	testing.expect_value(t, h_st, Status.Ok)
	srv.session_id = srv.exchange_hash

	testing.expect_value(t, derive_key(shared[:], &srv.exchange_hash, .Enc_Client_To_Server, &srv.session_id, srv.c2s_key[:]), Status.Ok)
	testing.expect_value(t, derive_key(shared[:], &srv.exchange_hash, .Enc_Server_To_Client, &srv.session_id, srv.s2c_key[:]), Status.Ok)

	raw_sig: [ED25519_SIGNATURE_SIZE]u8
	sec_str := string(srv.host_ed_secret[:])
	msg_str := string(srv.exchange_hash[:])
	sig_slice := raw_sig[:]
	err: errors.Error_Record
	testing.expect_value(t, answer_of(cryptography_primitives.ed25519_sign(&sec_str, &msg_str, &sig_slice, &err)), Answer{.Succeeded, i64(ED25519_SIGNATURE_SIZE)})
	if corrupt_sig {
		raw_sig[0] ~= 0x01
	}

	sig_blob: [128]u8
	sig_len, sb_st := encode_ssh_ed25519_signature(raw_sig, sig_blob[:])
	testing.expect_value(t, sb_st, Status.Ok)

	payload: [512]u8
	enc := encoder_init(payload[:])
	testing.expect(t, encode_byte(&enc, u8(Message_Type.Kex_Ecdh_Reply)))
	testing.expect(t, encode_ssh_bytes(&enc, k_s_blob[:k_s_len]))
	testing.expect(t, encode_ssh_bytes(&enc, q_s[:]))
	testing.expect(t, encode_ssh_bytes(&enc, sig_blob[:sig_len]))

	n, st := mock_server_send(srv, encoder_bytes(&enc), out)
	testing.expect_value(t, st, Status.Ok)
	return n
}

// Helper: advance client & mock server through banner and KEXINIT to Kex_Ecdh_Sent.
@(private = "file")
handshake_to_ecdh_sent :: proc(t: ^testing.T, cli: ^Client_Session, srv: ^Mock_Ssh_Server) -> [X25519_KEY_SIZE]u8 {
	kex_secret: [X25519_KEY_SIZE]u8
	cookie: [COOKIE_SIZE]u8
	for i in 0 ..< 32 {
		kex_secret[i] = u8(0x31 + i)
	}
	for i in 0 ..< COOKIE_SIZE {
		cookie[i] = u8(0x11 + i)
	}
	testing.expect_value(t, client_init(cli, "example.modus.test", 22, kex_secret, cookie), Status.Ok)

	wire: [4096]u8
	pad := [8]u8{9, 8, 7, 6, 5, 4, 3, 2}

	// Banner exchange
	n, st := client_write_banner(cli, wire[:])
	testing.expect_value(t, st, Status.Ok)
	cb, _, cb_st := banner_parse(wire[:n])
	testing.expect_value(t, cb_st, Status.Ok)
	copy(srv.client_banner[:], cb)
	srv.client_banner_n = len(cb)

	srv_banner_wire: [128]u8
	copy(srv_banner_wire[:], srv.banner)
	srv_banner_wire[len(srv.banner)] = '\r'
	srv_banner_wire[len(srv.banner) + 1] = '\n'
	_, st = client_receive_banner(cli, srv_banner_wire[:len(srv.banner) + 2])
	testing.expect_value(t, st, Status.Ok)

	// KEXINIT exchange
	n, st = client_write_kexinit(cli, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	srv.client_kexinit_n, st = mock_server_recv(srv, wire[:n], srv.client_kexinit[:])
	testing.expect_value(t, st, Status.Ok)

	srv.server_kexinit_n, st = kexinit_build(srv.cookie, srv.server_kexinit[:])
	testing.expect_value(t, st, Status.Ok)
	n, st = mock_server_send(srv, srv.server_kexinit[:srv.server_kexinit_n], wire[:])
	testing.expect_value(t, st, Status.Ok)
	_, st = client_receive_kexinit(cli, wire[:n])
	testing.expect_value(t, st, Status.Ok)

	// KEX_ECDH_INIT
	n, st = client_write_kex_ecdh_init(cli, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	ecdh_payload: [128]u8
	ecdh_len, r_st := mock_server_recv(srv, wire[:n], ecdh_payload[:])
	testing.expect_value(t, r_st, Status.Ok)
	dec := decoder_init(ecdh_payload[:ecdh_len])
	op, _ := decode_byte(&dec)
	testing.expect_value(t, op, u8(Message_Type.Kex_Ecdh_Init))
	qc_slice, qc_ok := decode_ssh_bytes(&dec)
	testing.expect(t, qc_ok && len(qc_slice) == X25519_KEY_SIZE)
	qc: [X25519_KEY_SIZE]u8
	copy(qc[:], qc_slice)
	return qc
}

// --- Adversarial edge-case tests FIRST ---

@(test)
wire_border_and_packet_refusals :: proc(t: ^testing.T) {
	// Closed enum border: reject undefined wire opcodes.
	for bad in ([]u8{0, 7, 19, 22, 32, 49, 101, 255}) {
		_, ok := message_type_of_byte(bad)
		testing.expectf(t, !ok, "wire byte %d must be refused", bad)
	}
	mt, ok := message_type_of_byte(20)
	testing.expect(t, ok && mt == .Kexinit)

	// Banner refusals: empty, truncated, SSH-1.x, NUL, oversized.
	_, _, st := banner_parse(nil)
	testing.expect_value(t, st, Status.Truncated)
	_, _, st = banner_parse(transmute([]u8)string("SSH-2.0-no-newline"))
	testing.expect_value(t, st, Status.Truncated)
	_, _, st = banner_parse(transmute([]u8)string("SSH-1.99-OldServer\r\n"))
	testing.expect_value(t, st, Status.Bad_Banner)
	_, _, st = banner_parse(transmute([]u8)string("SSH-1.5-Legacy\r\n"))
	testing.expect_value(t, st, Status.Bad_Banner)
	_, _, st = banner_parse([]u8{'S', 'S', 'H', '-', '2', '.', '0', '-', 0, 'x', '\r', '\n'})
	testing.expect_value(t, st, Status.Bad_Banner)

	long_banner: [300]u8
	copy(long_banner[:], "SSH-2.0-")
	for i in 8 ..< 260 {
		long_banner[i] = 'a'
	}
	long_banner[260] = '\r'
	long_banner[261] = '\n'
	_, _, st = banner_parse(long_banner[:262])
	testing.expect_value(t, st, Status.Bad_Banner)

	// Valid banner with pre-banner welcome line.
	pre_and_banner := transmute([]u8)string("Welcome to modus\r\nSSH-2.0-OpenSSH_9.9\r\n")
	parsed, consumed, p_st := banner_parse(pre_and_banner)
	testing.expect_value(t, p_st, Status.Ok)
	testing.expect_value(t, string(parsed), "SSH-2.0-OpenSSH_9.9")
	testing.expect_value(t, consumed, len(pre_and_banner))

	// Oversized plain packet (> 35000) and max(u32) refused cleanly.
	bad_wire: [64]u8
	byte_order.write_u32_big_endian(bad_wire[:], 0, MAX_PACKET_LENGTH + 1)
	out_payload: [64]u8
	_, _, st = packet_unpack_plain(bad_wire[:], out_payload[:])
	testing.expect_value(t, st, Status.Oversized_Packet)

	byte_order.write_u32_big_endian(bad_wire[:], 0, max(u32))
	_, _, st = packet_unpack_plain(bad_wire[:], out_payload[:])
	testing.expect_value(t, st, Status.Oversized_Packet)

	// Empty payload packing refused.
	_, st = packet_pack_plain(nil, nil, bad_wire[:])
	testing.expect_value(t, st, Status.Invalid_Argument)

	// Padding < 4 refused.
	byte_order.write_u32_big_endian(bad_wire[:], 0, 12)
	bad_wire[4] = 3
	_, _, st = packet_unpack_plain(bad_wire[:16], out_payload[:])
	testing.expect_value(t, st, Status.Bad_Padding)
}

@(test)
known_hosts_strict_no_tofu_and_bounds :: proc(t: ^testing.T) {
	kh: Known_Hosts
	known_hosts_init(&kh)

	key_a: [ED25519_PUBLIC_KEY_SIZE]u8
	key_b: [ED25519_PUBLIC_KEY_SIZE]u8
	for i in 0 ..< 32 {
		key_a[i] = u8(i + 1)
		key_b[i] = u8(i + 100)
	}

	// Refusals: empty host, port 0, control char, oversized host.
	testing.expect_value(t, known_hosts_add(&kh, "", 22, key_a), Status.Invalid_Argument)
	testing.expect_value(t, known_hosts_add(&kh, "host", 0, key_a), Status.Invalid_Argument)
	testing.expect_value(t, known_hosts_add(&kh, "bad host", 22, key_a), Status.Invalid_Argument)
	huge_host: [MAX_HOST_NAME_LENGTH + 1]u8
	for &c in huge_host {
		c = 'a'
	}
	testing.expect_value(t, known_hosts_add(&kh, string(huge_host[:]), 22, key_a), Status.Invalid_Argument)
	testing.expect_value(t, kh.count, 0)

	// Zero silent TOFU: unknown host MUST return Unknown_Host_Key and table stays empty.
	testing.expect_value(t, known_hosts_verify(&kh, "server.local", 22, key_a), Status.Unknown_Host_Key)
	testing.expect_value(t, kh.count, 0)

	// Pin host, verify match, verify MITM mismatch, verify conflicting re-add refused.
	testing.expect_value(t, known_hosts_add(&kh, "server.local", 22, key_a), Status.Ok)
	testing.expect_value(t, known_hosts_verify(&kh, "server.local", 22, key_a), Status.Ok)
	testing.expect_value(t, known_hosts_verify(&kh, "server.local", 22, key_b), Status.Host_Key_Mismatch)
	testing.expect_value(t, known_hosts_verify(&kh, "server.local", 2222, key_a), Status.Unknown_Host_Key)
	testing.expect_value(t, known_hosts_add(&kh, "server.local", 22, key_b), Status.Host_Key_Mismatch)

	// Fill table to bound, check one past bound is Table_Full.
	for i in 1 ..< MAX_KNOWN_HOSTS {
		name_buf: [16]u8
		name_buf[0] = 'h'
		name_buf[1] = u8('a' + (i / 26))
		name_buf[2] = u8('a' + (i % 26))
		testing.expect_value(t, known_hosts_add(&kh, string(name_buf[:3]), 22, key_a), Status.Ok)
	}
	testing.expect_value(t, kh.count, MAX_KNOWN_HOSTS)
	testing.expect_value(t, known_hosts_add(&kh, "overflow.host", 22, key_a), Status.Table_Full)
	testing.expect(t, known_hosts_remove(&kh, "server.local", 22))
	testing.expect_value(t, kh.count, MAX_KNOWN_HOSTS - 1)
	testing.expect_value(t, known_hosts_verify(&kh, "server.local", 22, key_a), Status.Unknown_Host_Key)
}

@(test)
chacha20_poly1305_tamper_and_sequence_refusals :: proc(t: ^testing.T) {
	key: [CHACHA20_POLY1305_KEY_SIZE]u8
	for i in 0 ..< len(key) {
		key[i] = u8(0x40 + i)
	}
	payload := transmute([]u8)string("hello encrypted ssh world")
	pad := [8]u8{4, 5, 6, 7, 8, 9, 10, 11}
	wire: [256]u8
	n, st := packet_seal_chacha20_poly1305(&key, 7, payload, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)

	out: [256]u8
	// Wrong sequence number decrypts garbage length or fails MAC; must always be refused.
	_, _, st = packet_open_chacha20_poly1305(&key, 8, wire[:n], out[:])
	testing.expect(t, st != .Ok)

	// Wrong main key K_1 (with matching header key K_2) must fail Poly1305 with Not_Authentic.
	bad_k1 := key
	bad_k1[0] ~= 0x01
	_, _, st = packet_open_chacha20_poly1305(&bad_k1, 7, wire[:n], out[:])
	testing.expect_value(t, st, Status.Not_Authentic)

	// Tampered encrypted payload byte must fail authentication.
	wire[6] ~= 0x80
	_, _, st = packet_open_chacha20_poly1305(&key, 7, wire[:n], out[:])
	testing.expect_value(t, st, Status.Not_Authentic)
	wire[6] ~= 0x80

	// Tampered Poly1305 tag byte must fail authentication.
	wire[n - 1] ~= 0x01
	_, _, st = packet_open_chacha20_poly1305(&key, 7, wire[:n], out[:])
	testing.expect_value(t, st, Status.Not_Authentic)
	wire[n - 1] ~= 0x01

	// Tampered encrypted length header must fail.
	wire[0] ~= 0xFF
	_, _, st = packet_open_chacha20_poly1305(&key, 7, wire[:n], out[:])
	testing.expect(t, st != .Ok)
	wire[0] ~= 0xFF

	// Authentic packet opens cleanly.
	plen, consumed, open_st := packet_open_chacha20_poly1305(&key, 7, wire[:n], out[:])
	testing.expect_value(t, open_st, Status.Ok)
	testing.expect_value(t, consumed, n)
	testing.expect_value(t, string(out[:plen]), "hello encrypted ssh world")
}

@(test)
handshake_refuses_unknown_mitm_bad_sig_and_small_order_kex :: proc(t: ^testing.T) {
	// 1. Unknown host key (zero silent TOFU).
	{
		cli: Client_Session
		srv: Mock_Ssh_Server
		mock_server_init(t, &srv, 0x10, 0x20)
		qc := handshake_to_ecdh_sent(t, &cli, &srv)

		reply_wire: [1024]u8
		reply_n := mock_server_build_kex_reply(t, &srv, qc, nil, false, reply_wire[:])
		empty_kh: Known_Hosts
		known_hosts_init(&empty_kh)
		_, st := client_receive_kex_ecdh_reply(&cli, reply_wire[:reply_n], &empty_kh)
		testing.expect_value(t, st, Status.Unknown_Host_Key)
		testing.expect_value(t, cli.state, Session_State.Kex_Ecdh_Sent)
		session_destroy(&cli)
	}

	// 2. Changed / MITM host key.
	{
		cli: Client_Session
		srv: Mock_Ssh_Server
		mock_server_init(t, &srv, 0x10, 0x20)
		qc := handshake_to_ecdh_sent(t, &cli, &srv)

		reply_wire: [1024]u8
		reply_n := mock_server_build_kex_reply(t, &srv, qc, nil, false, reply_wire[:])
		kh: Known_Hosts
		known_hosts_init(&kh)
		different_key := srv.host_ed_public
		different_key[0] ~= 0xFF
		testing.expect_value(t, known_hosts_add(&kh, "example.modus.test", 22, different_key), Status.Ok)

		_, st := client_receive_kex_ecdh_reply(&cli, reply_wire[:reply_n], &kh)
		testing.expect_value(t, st, Status.Host_Key_Mismatch)
		testing.expect_value(t, cli.state, Session_State.Kex_Ecdh_Sent)
		session_destroy(&cli)
	}

	// 3. Bad Ed25519 host signature over H.
	{
		cli: Client_Session
		srv: Mock_Ssh_Server
		mock_server_init(t, &srv, 0x10, 0x20)
		qc := handshake_to_ecdh_sent(t, &cli, &srv)

		reply_wire: [1024]u8
		reply_n := mock_server_build_kex_reply(t, &srv, qc, nil, true, reply_wire[:])
		kh: Known_Hosts
		known_hosts_init(&kh)
		testing.expect_value(t, known_hosts_add(&kh, "example.modus.test", 22, srv.host_ed_public), Status.Ok)

		_, st := client_receive_kex_ecdh_reply(&cli, reply_wire[:reply_n], &kh)
		testing.expect_value(t, st, Status.Bad_Host_Signature)
		testing.expect_value(t, cli.state, Session_State.Kex_Ecdh_Sent)
		session_destroy(&cli)
	}

	// 4. Small-order X25519 peer point (all zeros) refused with Bad_Kex_Point.
	{
		cli: Client_Session
		srv: Mock_Ssh_Server
		mock_server_init(t, &srv, 0x10, 0x20)
		qc := handshake_to_ecdh_sent(t, &cli, &srv)

		small_order: [X25519_KEY_SIZE]u8
		reply_wire: [1024]u8
		reply_n := mock_server_build_kex_reply(t, &srv, qc, &small_order, false, reply_wire[:])
		kh: Known_Hosts
		known_hosts_init(&kh)
		testing.expect_value(t, known_hosts_add(&kh, "example.modus.test", 22, srv.host_ed_public), Status.Ok)

		_, st := client_receive_kex_ecdh_reply(&cli, reply_wire[:reply_n], &kh)
		testing.expect_value(t, st, Status.Bad_Kex_Point)
		testing.expect_value(t, cli.state, Session_State.Kex_Ecdh_Sent)
		session_destroy(&cli)
	}

	// 5. Algorithm mismatch in peer KEXINIT.
	{
		bad_kex: [512]u8
		enc := encoder_init(bad_kex[:])
		cookie: [COOKIE_SIZE]u8
		testing.expect(t, encode_byte(&enc, u8(Message_Type.Kexinit)))
		testing.expect(t, encode_raw(&enc, cookie[:]))
		testing.expect(t, encode_ssh_string(&enc, "diffie-hellman-group14-sha256"))
		testing.expect(t, encode_ssh_string(&enc, ALG_HOST_KEY))
		testing.expect(t, encode_ssh_string(&enc, "aes128-ctr"))
		testing.expect(t, encode_ssh_string(&enc, "aes128-ctr"))
		testing.expect(t, encode_ssh_string(&enc, "hmac-sha2-256"))
		testing.expect(t, encode_ssh_string(&enc, "hmac-sha2-256"))
		testing.expect(t, encode_ssh_string(&enc, "none"))
		testing.expect(t, encode_ssh_string(&enc, "none"))
		testing.expect(t, encode_ssh_string(&enc, ""))
		testing.expect(t, encode_ssh_string(&enc, ""))
		testing.expect(t, encode_bool(&enc, false))
		testing.expect(t, encode_u32(&enc, 0))
		_, st := kexinit_parse_and_negotiate(encoder_bytes(&enc))
		testing.expect_value(t, st, Status.Algorithm_Mismatch)
	}
}

@(test)
full_ssh2_handshake_publickey_auth_and_interactive_channel :: proc(t: ^testing.T) {
	cli: Client_Session
	srv: Mock_Ssh_Server
	mock_server_init(t, &srv, 0x55, 0x77)

	kh: Known_Hosts
	known_hosts_init(&kh)
	testing.expect_value(t, known_hosts_add(&kh, "example.modus.test", 22, srv.host_ed_public), Status.Ok)

	qc := handshake_to_ecdh_sent(t, &cli, &srv)

	// Server sends KEX_ECDH_REPLY
	wire: [4096]u8
	pad := [8]u8{1, 3, 5, 7, 9, 11, 13, 15}
	reply_n := mock_server_build_kex_reply(t, &srv, qc, nil, false, wire[:])
	_, st := client_receive_kex_ecdh_reply(&cli, wire[:reply_n], &kh)
	testing.expect_value(t, st, Status.Ok)
	testing.expect_value(t, cli.state, Session_State.Newkeys_Wait)
	// Ephemeral X25519 secret must already be erased.
	zero_key: [X25519_KEY_SIZE]u8
	testing.expect(t, bytes_equal(cli.client_kex_secret[:], zero_key[:]))
	// Derived keys must match server keys identically.
	testing.expect(t, bytes_equal(cli.c2s_key[:], srv.c2s_key[:]))
	testing.expect(t, bytes_equal(cli.s2c_key[:], srv.s2c_key[:]))

	// NEWKEYS exchange
	n, wn_st := client_write_newkeys(&cli, pad[:], wire[:])
	testing.expect_value(t, wn_st, Status.Ok)
	srv_rx: [2048]u8
	rx_n, rx_st := mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)
	testing.expect_value(t, rx_n, 1)
	testing.expect_value(t, srv_rx[0], u8(Message_Type.Newkeys))

	srv_newkeys := [1]u8{u8(Message_Type.Newkeys)}
	n, st = mock_server_send(&srv, srv_newkeys[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	srv.encrypted = true

	_, st = client_receive_newkeys(&cli, wire[:n])
	testing.expect_value(t, st, Status.Ok)
	testing.expect_value(t, cli.state, Session_State.Encrypted)

	// Service request: ssh-userauth
	n, st = client_write_service_request(&cli, "ssh-userauth", pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	rx_n, rx_st = mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)
	testing.expect_value(t, srv_rx[0], u8(Message_Type.Service_Request))

	// Server sends SERVICE_ACCEPT("ssh-userauth")
	svc_acc: [64]u8
	acc_enc := encoder_init(svc_acc[:])
	testing.expect(t, encode_byte(&acc_enc, u8(Message_Type.Service_Accept)))
	testing.expect(t, encode_ssh_string(&acc_enc, "ssh-userauth"))
	n, st = mock_server_send(&srv, encoder_bytes(&acc_enc), wire[:])
	testing.expect_value(t, st, Status.Ok)
	_, st = client_receive_service_accept(&cli, "ssh-userauth", wire[:n])
	testing.expect_value(t, st, Status.Ok)
	testing.expect_value(t, cli.state, Session_State.Userauth_Ready)

	// Public-key userauth (RFC 4252)
	client_ed_secret: [ED25519_PRIVATE_KEY_SIZE]u8
	for i in 0 ..< 32 {
		client_ed_secret[i] = u8(0x90 + i)
	}
	client_ed_pub: [ED25519_PUBLIC_KEY_SIZE]u8
	sec_s := string(client_ed_secret[:])
	pub_sl := client_ed_pub[:]
	err: errors.Error_Record
	testing.expect_value(t, answer_of(cryptography_primitives.ed25519_public_key(&sec_s, &pub_sl, &err)), Answer{.Succeeded, i64(ED25519_PUBLIC_KEY_SIZE)})

	n, st = client_write_userauth_publickey(&cli, "sacha", client_ed_secret, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	rx_n, rx_st = mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)

	// Mock server strictly verifies the client's Ed25519 signature over session_id || USERAUTH_REQUEST.
	dec := decoder_init(srv_rx[:rx_n])
	op, _ := decode_byte(&dec)
	testing.expect_value(t, op, u8(Message_Type.Userauth_Request))
	user_b, _ := decode_ssh_bytes(&dec)
	svc_b, _ := decode_ssh_bytes(&dec)
	method_b, _ := decode_ssh_bytes(&dec)
	has_sig, _ := decode_bool(&dec)
	alg_b, _ := decode_ssh_bytes(&dec)
	pk_blob, _ := decode_ssh_bytes(&dec)
	sig_blob, _ := decode_ssh_bytes(&dec)
	testing.expect_value(t, string(user_b), "sacha")
	testing.expect_value(t, string(svc_b), "ssh-connection")
	testing.expect_value(t, string(method_b), "publickey")
	testing.expect(t, has_sig)
	testing.expect_value(t, string(alg_b), ALG_HOST_KEY)

	parsed_client_pk, pk_st := parse_ssh_ed25519_public_key(pk_blob)
	testing.expect_value(t, pk_st, Status.Ok)
	testing.expect(t, bytes_equal(parsed_client_pk[:], client_ed_pub[:]))
	parsed_client_sig, sg_st := parse_ssh_ed25519_signature(sig_blob)
	testing.expect_value(t, sg_st, Status.Ok)

	sign_data: [MAX_AUTH_SIGN_DATA]u8
	sign_n, sd_st := build_userauth_publickey_sign_data(&srv.session_id, "sacha", pk_blob, sign_data[:])
	testing.expect_value(t, sd_st, Status.Ok)
	pk_str := string(parsed_client_pk[:])
	sd_str := string(sign_data[:sign_n])
	sg_str := string(parsed_client_sig[:])
	testing.expect_value(t, answer_of(cryptography_primitives.ed25519_verify(&pk_str, &sd_str, &sg_str, &err)), Answer{.Succeeded, i64(0)})

	// Server sends USERAUTH_SUCCESS
	auth_ok := [1]u8{u8(Message_Type.Userauth_Success)}
	n, st = mock_server_send(&srv, auth_ok[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	_, st = client_receive_userauth_response(&cli, wire[:n])
	testing.expect_value(t, st, Status.Ok)
	testing.expect_value(t, cli.state, Session_State.Authenticated)

	// CHANNEL_OPEN("session")
	n, st = client_write_channel_open_session(&cli, 7, 1024, 512, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	rx_n, rx_st = mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)
	testing.expect_value(t, srv_rx[0], u8(Message_Type.Channel_Open))

	// Server confirms channel with remote_id = 42, window = 64, max_packet = 64.
	conf_buf: [64]u8
	c_enc := encoder_init(conf_buf[:])
	testing.expect(t, encode_byte(&c_enc, u8(Message_Type.Channel_Open_Confirmation)))
	testing.expect(t, encode_u32(&c_enc, 7))
	testing.expect(t, encode_u32(&c_enc, 42))
	testing.expect(t, encode_u32(&c_enc, 64))
	testing.expect(t, encode_u32(&c_enc, 64))
	n, st = mock_server_send(&srv, encoder_bytes(&c_enc), wire[:])
	testing.expect_value(t, st, Status.Ok)
	_, st = client_receive_channel_open_confirmation(&cli, wire[:n])
	testing.expect_value(t, st, Status.Ok)
	testing.expect_value(t, cli.state, Session_State.Channel_Open)
	testing.expect_value(t, cli.remote_channel_id, u32(42))

	// pty-req, shell, window-change
	n, st = client_write_channel_request_pty(&cli, "xterm-256color", 80, 24, true, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	rx_n, rx_st = mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)
	testing.expect_value(t, srv_rx[0], u8(Message_Type.Channel_Request))

	n, st = client_write_channel_request_shell(&cli, true, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	rx_n, rx_st = mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)

	n, st = client_write_channel_request_window_change(&cli, 120, 40, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	rx_n, rx_st = mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)

	// Client sends CHANNEL_DATA ("uname -a\n"), verify remote window decrements and overflow refused.
	cmd := transmute([]u8)string("uname -a\n")
	n, st = client_write_channel_data(&cli, cmd, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	testing.expect_value(t, cli.remote_window, u32(64 - len(cmd)))
	rx_n, rx_st = mock_server_recv(&srv, wire[:n], srv_rx[:])
	testing.expect_value(t, rx_st, Status.Ok)
	d_dec := decoder_init(srv_rx[:rx_n])
	d_op, _ := decode_byte(&d_dec)
	d_ch, _ := decode_u32(&d_dec)
	d_msg, _ := decode_ssh_bytes(&d_dec)
	testing.expect_value(t, d_op, u8(Message_Type.Channel_Data))
	testing.expect_value(t, d_ch, u32(42))
	testing.expect_value(t, string(d_msg), "uname -a\n")

	// Window overflow refused without consuming seq or window.
	too_big: [65]u8
	_, st = client_write_channel_data(&cli, too_big[:], pad[:], wire[:])
	testing.expect_value(t, st, Status.Window_Exceeded)

	// Server sends encrypted ANSI output over CHANNEL_DATA; tamper once first to confirm refusal preserves recv_seq.
	ansi_out := transmute([]u8)string("\x1b[1;32mmodus\x1b[0m \xC3\xA9")
	sdata: [128]u8
	sd_enc := encoder_init(sdata[:])
	testing.expect(t, encode_byte(&sd_enc, u8(Message_Type.Channel_Data)))
	testing.expect(t, encode_u32(&sd_enc, 7))
	testing.expect(t, encode_ssh_bytes(&sd_enc, ansi_out))
	n, st = mock_server_send(&srv, encoder_bytes(&sd_enc), wire[:])
	testing.expect_value(t, st, Status.Ok)

	recv_buf: [256]u8
	wire[10] ~= 0x42
	_, _, _, tamper_st := client_receive_channel_message(&cli, wire[:n], recv_buf[:])
	testing.expect_value(t, tamper_st, Status.Not_Authentic)
	wire[10] ~= 0x42

	ev, dlen, _, ev_st := client_receive_channel_message(&cli, wire[:n], recv_buf[:])
	testing.expect_value(t, ev_st, Status.Ok)
	testing.expect_value(t, ev, Channel_Event.Data)
	testing.expect_value(t, string(recv_buf[:dlen]), string(ansi_out))

	// Feed decrypted SSH output directly into ANSI parser + Terminal_Grid.
	grid: Terminal_Grid
	parser: Ansi_Parser
	testing.expect_value(t, grid_init(&grid, 20, 4), Status.Ok)
	ansi_parser_init(&parser)
	ansi_feed(&parser, &grid, recv_buf[:dlen])
	c0, _ := grid_cell(&grid, 0, 0)
	testing.expect_value(t, c0.character, rune('m'))
	testing.expect_value(t, c0.foreground, Ansi_Color.Green)
	testing.expect(t, .Bold in c0.attributes)
	c6, _ := grid_cell(&grid, 6, 0)
	testing.expect_value(t, c6.character, rune('é'))
	testing.expect_value(t, c6.foreground, Ansi_Color.Default)

	// Window adjust, EOF, Close
	n, st = client_write_channel_window_adjust(&cli, 256, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	n, st = client_write_channel_eof(&cli, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	n, st = client_write_channel_close(&cli, pad[:], wire[:])
	testing.expect_value(t, st, Status.Ok)
	testing.expect(t, cli.close_sent)

	// Rekey bound enforcement before 32-bit sequence wraparound.
	cli.state = .Channel_Open
	cli.close_sent = false
	cli.eof_sent = false
	cli.packets_sent_under_key = REKEY_PACKET_LIMIT
	_, st = client_write_channel_data(&cli, cmd[:1], pad[:], wire[:])
	testing.expect_value(t, st, Status.Rekey_Required)

	// Destroy erases all key material.
	session_destroy(&cli)
	zero_k64: [CHACHA20_POLY1305_KEY_SIZE]u8
	testing.expect(t, bytes_equal(cli.c2s_key[:], zero_k64[:]))
	testing.expect(t, bytes_equal(cli.s2c_key[:], zero_k64[:]))
	testing.expect(t, bytes_equal(cli.session_id[:], zero_key[:]))
}

@(test)
ansi_parser_adversarial_and_vt100_sequences :: proc(t: ^testing.T) {
	grid: Terminal_Grid
	parser: Ansi_Parser

	// Edge refusals for grid_init: 0, negative, one past bound.
	testing.expect_value(t, grid_init(&grid, 0, 10), Status.Invalid_Argument)
	testing.expect_value(t, grid_init(&grid, -5, 10), Status.Invalid_Argument)
	testing.expect_value(t, grid_init(&grid, MAX_GRID_COLS + 1, 10), Status.Invalid_Argument)
	testing.expect_value(t, grid_init(&grid, 10, 0), Status.Invalid_Argument)
	testing.expect_value(t, grid_init(&grid, 10, MAX_GRID_ROWS + 1), Status.Invalid_Argument)
	_, cell_ok := grid_cell(&grid, -1, 0)
	testing.expect(t, !cell_ok)

	testing.expect_value(t, grid_init(&grid, 10, 4), Status.Ok)
	ansi_parser_init(&parser)

	// Malformed/truncated/oversized CSI, huge coordinates, >16 params, invalid UTF-8: no panic or OOB.
	adversarial := []u8{
		0x1B, '[', '9', '9', '9', '9', '9', '9', ';', '9', '9', '9', '9', '9', 'H',
		0x1B, '[', '1', ';', '2', ';', '3', ';', '4', ';', '5', ';', '6', ';', '7', ';', '8', ';', '9', ';',
		'1', ';', '2', ';', '3', ';', '4', ';', '5', ';', '6', ';', '7', ';', '8', ';', '9', 'm',
		0x1B, '[', '?', '2', '5', 'l',
		0x1B, ']', '0', ';', 't', 'i', 't', 'l', 'e', 0x07,
		0x1B, '[', '1', ';', 0x18,
		0xC0, 0xAF,
		0xED, 0xA0, 0x80,
		0x80,
		0x1B, '[',
	}
	ansi_feed(&parser, &grid, adversarial)
	testing.expect(t, grid.cursor_col >= 0 && grid.cursor_col <= grid.cols)
	testing.expect(t, grid.cursor_row >= 0 && grid.cursor_row < grid.rows)
	testing.expect_value(t, parser.state, Ansi_State.Csi_Entry)

	// Reset grid and test cursor movement, home, SGR attributes, erase J/K, chunked UTF-8.
	testing.expect_value(t, grid_init(&grid, 10, 3), Status.Ok)
	ansi_parser_init(&parser)

	seq := transmute([]u8)string(
		"\x1b[1;7;31;44mAB\x1b[0m" +
		"\x1b[2;5H" +
		"\xC5\x93" +
		"\x1b[1A\x1b[2D" +
		"Z" +
		"\x1b[1;1H\x1b[0K",
	)
	// Stream 1 byte at a time to verify split UTF-8 and split CSI state machine.
	for i in 0 ..< len(seq) {
		ansi_feed(&parser, &grid, seq[i : i + 1])
	}
	// Row 0 was erased by ESC[0K from (0,0).
	c00, _ := grid_cell(&grid, 0, 0)
	testing.expect_value(t, c00.character, rune(' '))
	// Row 1 col 4 still holds 'œ'.
	c41, _ := grid_cell(&grid, 4, 1)
	testing.expect_value(t, c41.character, rune('œ'))

	// Erase entire display ESC[2J clears everything.
	ansi_feed(&parser, &grid, transmute([]u8)string("\x1b[2J"))
	c41_after, _ := grid_cell(&grid, 4, 1)
	testing.expect_value(t, c41_after.character, rune(' '))

	// Scrolling: writing 4 lines into 3-row grid scrolls row 0 off.
	ansi_feed(&parser, &grid, transmute([]u8)string("\x1b[1;1HL0\r\nL1\r\nL2\r\nL3"))
	r0c1, _ := grid_cell(&grid, 1, 0)
	r2c1, _ := grid_cell(&grid, 1, 2)
	testing.expect_value(t, r0c1.character, rune('1'))
	testing.expect_value(t, r2c1.character, rune('3'))

	// Ensure replacement character emitted on truncated UTF-8 followed by ASCII.
	testing.expect_value(t, grid_init(&grid, 10, 2), Status.Ok)
	ansi_parser_init(&parser)
	ansi_feed(&parser, &grid, []u8{0xE2, 0x82, 'X'})
	r0, _ := grid_cell(&grid, 0, 0)
	r1, _ := grid_cell(&grid, 1, 0)
	testing.expect_value(t, r0.character, text_encoding.REPLACEMENT_CHARACTER)
	testing.expect_value(t, r1.character, rune('X'))
}
