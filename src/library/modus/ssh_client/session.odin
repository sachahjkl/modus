// SSH-2 client session state machine: key exchange (RFC 4253 / RFC 8731),
// public-key userauth (RFC 4252), and interactive session channel (RFC 4254).
//
// Zero heap allocation: all scratch buffers are bounded on the stack and
// secret material is explicitly erased on key derivation and session destroy.
package ssh_client

import "modus:contract/errors"
import crypto "modus:cryptography/compatibility_crypto"
import "modus:cryptography_primitives"

MAX_KEXINIT_SIZE :: 2048
MAX_AUTH_SIGN_DATA :: 1024
MAX_USERNAME_LENGTH :: 128
MAX_TERM_LENGTH :: 64
MAX_PAYLOAD_SCRATCH :: MAX_PACKET_LENGTH
DEFAULT_CHANNEL_WINDOW :: u32(256 * 1024)
DEFAULT_CHANNEL_MAX_PACKET :: u32(16384)

Session_State :: enum u8 {
	Init              = 0,
	Banner_Sent       = 1,
	Banner_Exchanged  = 2,
	Kexinit_Sent      = 3,
	Kex_Negotiated    = 4,
	Kex_Ecdh_Sent     = 5,
	Newkeys_Wait      = 6,
	Encrypted         = 7,
	Service_Requested = 8,
	Userauth_Ready    = 9,
	Auth_Sent         = 10,
	Authenticated     = 11,
	Channel_Opening   = 12,
	Channel_Open      = 13,
	Closed            = 14,
}

Channel_Event :: enum u8 {
	None            = 0,
	Data            = 1,
	Extended_Data   = 2,
	Window_Adjust   = 3,
	Eof             = 4,
	Close           = 5,
	Request_Success = 6,
	Request_Failure = 7,
	Disconnected    = 8,
	Ignored         = 9,
}

Client_Session :: struct {
	state:                  Session_State,
	host:                   [MAX_HOST_NAME_LENGTH]u8,
	host_len:               int,
	port:                   u16,
	server_banner:          [MAX_BANNER_LENGTH]u8,
	server_banner_len:      int,
	client_kexinit:         [MAX_KEXINIT_SIZE]u8,
	client_kexinit_len:     int,
	server_kexinit:         [MAX_KEXINIT_SIZE]u8,
	server_kexinit_len:     int,
	client_kex_secret:      [X25519_KEY_SIZE]u8,
	client_kex_public:      [X25519_KEY_SIZE]u8,
	kex_cookie:             [COOKIE_SIZE]u8,
	session_id:             [SHA256_DIGEST_SIZE]u8,
	has_session_id:         bool,
	exchange_hash:          [SHA256_DIGEST_SIZE]u8,
	c2s_iv:                 [SHA256_DIGEST_SIZE]u8,
	s2c_iv:                 [SHA256_DIGEST_SIZE]u8,
	c2s_key:                [CHACHA20_POLY1305_KEY_SIZE]u8,
	s2c_key:                [CHACHA20_POLY1305_KEY_SIZE]u8,
	c2s_mac:                [SHA256_DIGEST_SIZE]u8,
	s2c_mac:                [SHA256_DIGEST_SIZE]u8,
	c2s_encrypted:          bool,
	s2c_encrypted:          bool,
	send_seq:               u32,
	recv_seq:               u32,
	packets_sent_under_key: u32,
	packets_recv_under_key: u32,
	local_channel_id:       u32,
	remote_channel_id:      u32,
	local_window:           u32,
	remote_window:          u32,
	remote_max_packet:      u32,
	eof_sent:               bool,
	eof_received:           bool,
	close_sent:             bool,
	close_received:         bool,
	last_disconnect_code:   u32,
	last_window_added:      u32,
}

// client_init initializes a fresh SSH-2 client session with caller-supplied ephemeral X25519 scalar and KEX cookie.
client_init :: proc "contextless" (
	s: ^Client_Session,
	host: string,
	port: u16,
	ephemeral_kex_secret: [X25519_KEY_SIZE]u8,
	kex_cookie: [COOKIE_SIZE]u8,
) -> Status {
	if s == nil || len(host) == 0 || len(host) > MAX_HOST_NAME_LENGTH || port == 0 {
		return .Invalid_Argument
	}
	pub, pub_status := x25519_public_from_secret(ephemeral_kex_secret)
	if pub_status != .Ok {
		return pub_status
	}
	session_destroy(s)
	copy(s.host[:], host)
	s.host_len = len(host)
	s.port = port
	s.client_kex_secret = ephemeral_kex_secret
	s.client_kex_public = pub
	s.kex_cookie = kex_cookie
	s.state = .Init
	return .Ok
}

// session_destroy erases every secret key, ephemeral scalar, and hash stored in the session.
session_destroy :: proc "contextless" (s: ^Client_Session) {
	if s == nil {
		return
	}
	crypto.zero_explicit(&s.client_kex_secret, size_of(s.client_kex_secret))
	crypto.zero_explicit(&s.c2s_iv, size_of(s.c2s_iv))
	crypto.zero_explicit(&s.s2c_iv, size_of(s.s2c_iv))
	crypto.zero_explicit(&s.c2s_key, size_of(s.c2s_key))
	crypto.zero_explicit(&s.s2c_key, size_of(s.s2c_key))
	crypto.zero_explicit(&s.c2s_mac, size_of(s.c2s_mac))
	crypto.zero_explicit(&s.s2c_mac, size_of(s.s2c_mac))
	crypto.zero_explicit(&s.session_id, size_of(s.session_id))
	crypto.zero_explicit(&s.exchange_hash, size_of(s.exchange_hash))
	s^ = {}
}

// session_pack_packet frames payload (plain before NEWKEYS, chacha20-poly1305@openssh.com after)
// and enforces the rekey packet limit before 32-bit sequence wraparound.
@(private)
session_pack_packet :: proc "contextless" (s: ^Client_Session, payload: []u8, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if s.c2s_encrypted {
		if s.packets_sent_under_key >= REKEY_PACKET_LIMIT || s.send_seq == max(u32) {
			return 0, .Rekey_Required
		}
		written, status = packet_seal_chacha20_poly1305(&s.c2s_key, s.send_seq, payload, pad_bytes, out)
		if status != .Ok {
			return 0, status
		}
		s.send_seq += 1
		s.packets_sent_under_key += 1
		return written, .Ok
	}
	written, status = packet_pack_plain(payload, pad_bytes, out)
	if status != .Ok {
		return 0, status
	}
	s.send_seq += 1
	return written, .Ok
}

// session_unpack_packet opens one packet (plain before NEWKEYS, authenticated after)
// without advancing recv_seq on failure.
@(private)
session_unpack_packet :: proc "contextless" (s: ^Client_Session, wire: []u8, payload_out: []u8) -> (payload_len: int, consumed: int, status: Status) {
	if s.s2c_encrypted {
		if s.packets_recv_under_key >= REKEY_PACKET_LIMIT || s.recv_seq == max(u32) {
			return 0, 0, .Rekey_Required
		}
		payload_len, consumed, status = packet_open_chacha20_poly1305(&s.s2c_key, s.recv_seq, wire, payload_out)
		if status != .Ok {
			return 0, 0, status
		}
		s.recv_seq += 1
		s.packets_recv_under_key += 1
		return payload_len, consumed, .Ok
	}
	payload_len, consumed, status = packet_unpack_plain(wire, payload_out)
	if status != .Ok {
		return 0, 0, status
	}
	s.recv_seq += 1
	return payload_len, consumed, .Ok
}

client_write_banner :: proc "contextless" (s: ^Client_Session, out: []u8) -> (written: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Init {
		return 0, .Bad_State
	}
	written, status = banner_write(out)
	if status == .Ok {
		s.state = .Banner_Sent
	}
	return written, status
}

client_receive_banner :: proc "contextless" (s: ^Client_Session, data: []u8) -> (consumed: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Banner_Sent {
		return 0, .Bad_State
	}
	banner, n, b_status := banner_parse(data)
	if b_status != .Ok {
		return 0, b_status
	}
	copy(s.server_banner[:], banner)
	s.server_banner_len = len(banner)
	s.state = .Banner_Exchanged
	return n, .Ok
}

client_write_kexinit :: proc "contextless" (s: ^Client_Session, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Banner_Exchanged {
		return 0, .Bad_State
	}
	payload_len, k_status := kexinit_build(s.kex_cookie, s.client_kexinit[:])
	if k_status != .Ok {
		return 0, k_status
	}
	s.client_kexinit_len = payload_len
	written, status = session_pack_packet(s, s.client_kexinit[:payload_len], pad_bytes, out)
	if status == .Ok {
		s.state = .Kexinit_Sent
	}
	return written, status
}

client_receive_kexinit :: proc "contextless" (s: ^Client_Session, wire: []u8) -> (consumed: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Kexinit_Sent {
		return 0, .Bad_State
	}
	payload: [MAX_KEXINIT_SIZE]u8
	plen, n, u_status := session_unpack_packet(s, wire, payload[:])
	if u_status != .Ok {
		return 0, u_status
	}
	_, neg_status := kexinit_parse_and_negotiate(payload[:plen])
	if neg_status != .Ok {
		return 0, neg_status
	}
	copy(s.server_kexinit[:], payload[:plen])
	s.server_kexinit_len = plen
	s.state = .Kex_Negotiated
	return n, .Ok
}

client_write_kex_ecdh_init :: proc "contextless" (s: ^Client_Session, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Kex_Negotiated {
		return 0, .Bad_State
	}
	payload: [64]u8
	enc := encoder_init(payload[:])
	if !encode_byte(&enc, u8(Message_Type.Kex_Ecdh_Init)) || !encode_ssh_bytes(&enc, s.client_kex_public[:]) {
		return 0, .Buffer_Too_Small
	}
	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.state = .Kex_Ecdh_Sent
	}
	return written, status
}

// client_receive_kex_ecdh_reply verifies the server host key strictly against known_hosts,
// computes the X25519 shared secret (refusing small-order points), verifies the Ed25519
// signature over the SHA-256 exchange hash H, derives RFC 4253 keys A..F, and erases K.
client_receive_kex_ecdh_reply :: proc "contextless" (s: ^Client_Session, wire: []u8, known_hosts: ^Known_Hosts) -> (consumed: int, status: Status) {
	if s == nil || known_hosts == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Kex_Ecdh_Sent {
		return 0, .Bad_State
	}
	payload: [2048]u8
	plen, n, u_status := session_unpack_packet(s, wire, payload[:])
	if u_status != .Ok {
		return 0, u_status
	}
	dec := decoder_init(payload[:plen])
	msg_byte, m_ok := decode_byte(&dec)
	if !m_ok {
		return 0, .Truncated
	}
	msg_type, t_ok := message_type_of_byte(msg_byte)
	if !t_ok || msg_type != .Kex_Ecdh_Reply {
		return 0, .Unexpected_Message
	}
	k_s_blob, ks_ok := decode_ssh_bytes(&dec)
	q_s_bytes, qs_ok := decode_ssh_bytes(&dec)
	sig_blob, sig_ok := decode_ssh_bytes(&dec)
	if !ks_ok || !qs_ok || !sig_ok || decoder_remaining(&dec) != 0 {
		return 0, .Truncated
	}
	if len(q_s_bytes) != X25519_KEY_SIZE {
		return 0, .Bad_Kex_Point
	}

	// Parse and strictly verify host key against Known_Hosts before accepting anything.
	host_pub, hk_status := parse_ssh_ed25519_public_key(k_s_blob)
	if hk_status != .Ok {
		return 0, hk_status
	}
	kh_status := known_hosts_verify(known_hosts, string(s.host[:s.host_len]), s.port, host_pub)
	if kh_status != .Ok {
		return 0, kh_status
	}

	// Parse Ed25519 signature blob.
	host_sig, sig_status := parse_ssh_ed25519_signature(sig_blob)
	if sig_status != .Ok {
		return 0, sig_status
	}

	// Compute X25519 shared secret (refuses small-order points).
	q_s: [X25519_KEY_SIZE]u8
	copy(q_s[:], q_s_bytes)
	shared_secret, ss_status := x25519_shared_secret(s.client_kex_secret, q_s)
	defer crypto.zero_explicit(&shared_secret, size_of(shared_secret))
	if ss_status != .Ok {
		return 0, ss_status
	}

	// Compute exchange hash H.
	exchange_h: [SHA256_DIGEST_SIZE]u8
	h_status := compute_exchange_hash(
		transmute([]u8)string(CLIENT_BANNER),
		s.server_banner[:s.server_banner_len],
		s.client_kexinit[:s.client_kexinit_len],
		s.server_kexinit[:s.server_kexinit_len],
		k_s_blob,
		s.client_kex_public[:],
		q_s[:],
		shared_secret[:],
		&exchange_h,
	)
	if h_status != .Ok {
		return 0, h_status
	}

	// Strictly verify Ed25519 signature over H using modus:cryptography_primitives.
	pub_str := string(host_pub[:])
	msg_str := string(exchange_h[:])
	sig_str := string(host_sig[:])
	verify_err: errors.Error_Record
	if cryptography_primitives.ed25519_verify(&pub_str, &msg_str, &sig_str, &verify_err) != 0 {
		return 0, .Bad_Host_Signature
	}

	// Derive RFC 4253 keys A..F into temporaries, commit only if every derivation succeeds.
	s.exchange_hash = exchange_h
	if !s.has_session_id {
		s.session_id = exchange_h
		s.has_session_id = true
	}
	if derive_key(shared_secret[:], &s.exchange_hash, .Iv_Client_To_Server, &s.session_id, s.c2s_iv[:]) != .Ok ||
		derive_key(shared_secret[:], &s.exchange_hash, .Iv_Server_To_Client, &s.session_id, s.s2c_iv[:]) != .Ok ||
		derive_key(shared_secret[:], &s.exchange_hash, .Enc_Client_To_Server, &s.session_id, s.c2s_key[:]) != .Ok ||
		derive_key(shared_secret[:], &s.exchange_hash, .Enc_Server_To_Client, &s.session_id, s.s2c_key[:]) != .Ok ||
		derive_key(shared_secret[:], &s.exchange_hash, .Mac_Client_To_Server, &s.session_id, s.c2s_mac[:]) != .Ok ||
		derive_key(shared_secret[:], &s.exchange_hash, .Mac_Server_To_Client, &s.session_id, s.s2c_mac[:]) != .Ok {
		return 0, .Crypto_Error
	}

	// Ephemeral X25519 private scalar is no longer needed; erase immediately.
	crypto.zero_explicit(&s.client_kex_secret, size_of(s.client_kex_secret))
	s.state = .Newkeys_Wait
	return n, .Ok
}

client_write_newkeys :: proc "contextless" (s: ^Client_Session, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Newkeys_Wait {
		return 0, .Bad_State
	}
	payload := [1]u8{u8(Message_Type.Newkeys)}
	written, status = session_pack_packet(s, payload[:], pad_bytes, out)
	if status == .Ok {
		s.c2s_encrypted = true
		s.packets_sent_under_key = 0
	}
	return written, status
}

client_receive_newkeys :: proc "contextless" (s: ^Client_Session, wire: []u8) -> (consumed: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Newkeys_Wait || !s.c2s_encrypted {
		return 0, .Bad_State
	}
	payload: [32]u8
	plen, n, u_status := session_unpack_packet(s, wire, payload[:])
	if u_status != .Ok {
		return 0, u_status
	}
	if plen != 1 {
		return 0, .Unexpected_Message
	}
	msg_type, ok := message_type_of_byte(payload[0])
	if !ok || msg_type != .Newkeys {
		return 0, .Unexpected_Message
	}
	s.s2c_encrypted = true
	s.packets_recv_under_key = 0
	s.state = .Encrypted
	return n, .Ok
}

// --- RFC 4252: ssh-userauth publickey ---

client_write_service_request :: proc "contextless" (s: ^Client_Session, service_name: string, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if s == nil || len(service_name) == 0 || len(service_name) > 64 {
		return 0, .Invalid_Argument
	}
	if s.state != .Encrypted {
		return 0, .Bad_State
	}
	payload: [128]u8
	enc := encoder_init(payload[:])
	if !encode_byte(&enc, u8(Message_Type.Service_Request)) || !encode_ssh_string(&enc, service_name) {
		return 0, .Buffer_Too_Small
	}
	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.state = .Service_Requested
	}
	return written, status
}

client_receive_service_accept :: proc "contextless" (s: ^Client_Session, expected_service: string, wire: []u8) -> (consumed: int, status: Status) {
	if s == nil || len(expected_service) == 0 {
		return 0, .Invalid_Argument
	}
	if s.state != .Service_Requested {
		return 0, .Bad_State
	}
	payload: [256]u8
	plen, n, u_status := session_unpack_packet(s, wire, payload[:])
	if u_status != .Ok {
		return 0, u_status
	}
	dec := decoder_init(payload[:plen])
	msg_byte, m_ok := decode_byte(&dec)
	if !m_ok {
		return 0, .Truncated
	}
	msg_type, t_ok := message_type_of_byte(msg_byte)
	if !t_ok || msg_type != .Service_Accept {
		return 0, .Unexpected_Message
	}
	svc, svc_ok := decode_ssh_bytes(&dec)
	if !svc_ok || decoder_remaining(&dec) != 0 {
		return 0, .Truncated
	}
	if !bytes_equal(svc, transmute([]u8)expected_service) {
		return 0, .Unexpected_Message
	}
	s.state = .Userauth_Ready
	return n, .Ok
}

// build_userauth_publickey_sign_data encodes RFC 4252 section 7 signature input:
// string(session_id) || byte(50) || string(username) || string("ssh-connection") ||
// string("publickey") || boolean(TRUE) || string("ssh-ed25519") || string(pub_key_blob).
build_userauth_publickey_sign_data :: proc "contextless" (
	session_id: ^[SHA256_DIGEST_SIZE]u8,
	username: string,
	pub_key_blob: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if session_id == nil || len(username) == 0 || len(username) > MAX_USERNAME_LENGTH || len(pub_key_blob) == 0 {
		return 0, .Invalid_Argument
	}
	enc := encoder_init(out)
	ok := encode_ssh_bytes(&enc, session_id[:]) &&
		encode_byte(&enc, u8(Message_Type.Userauth_Request)) &&
		encode_ssh_string(&enc, username) &&
		encode_ssh_string(&enc, "ssh-connection") &&
		encode_ssh_string(&enc, "publickey") &&
		encode_bool(&enc, true) &&
		encode_ssh_string(&enc, ALG_HOST_KEY) &&
		encode_ssh_bytes(&enc, pub_key_blob)
	if !ok {
		return 0, .Buffer_Too_Small
	}
	return enc.offset, .Ok
}

client_write_userauth_publickey :: proc "contextless" (
	s: ^Client_Session,
	username: string,
	client_ed25519_secret: [ED25519_PRIVATE_KEY_SIZE]u8,
	pad_bytes: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if s == nil || len(username) == 0 || len(username) > MAX_USERNAME_LENGTH {
		return 0, .Invalid_Argument
	}
	if s.state != .Userauth_Ready {
		return 0, .Bad_State
	}
	secret_copy := client_ed25519_secret
	defer crypto.zero_explicit(&secret_copy, size_of(secret_copy))

	// Derive Ed25519 public key from secret via modus:cryptography_primitives.
	pub_key: [ED25519_PUBLIC_KEY_SIZE]u8
	sec_str := string(secret_copy[:])
	pub_slice := pub_key[:]
	err: errors.Error_Record
	if cryptography_primitives.ed25519_public_key(&sec_str, &pub_slice, &err) != ED25519_PUBLIC_KEY_SIZE {
		return 0, .Crypto_Error
	}

	pub_blob: [64]u8
	pub_blob_len, pb_status := encode_ssh_ed25519_public_key(pub_key, pub_blob[:])
	if pb_status != .Ok {
		return 0, pb_status
	}

	sign_data: [MAX_AUTH_SIGN_DATA]u8
	sign_len, sd_status := build_userauth_publickey_sign_data(&s.session_id, username, pub_blob[:pub_blob_len], sign_data[:])
	if sd_status != .Ok {
		return 0, sd_status
	}

	raw_sig: [ED25519_SIGNATURE_SIZE]u8
	sign_msg := string(sign_data[:sign_len])
	sig_slice := raw_sig[:]
	if cryptography_primitives.ed25519_sign(&sec_str, &sign_msg, &sig_slice, &err) != ED25519_SIGNATURE_SIZE {
		return 0, .Crypto_Error
	}

	sig_blob: [128]u8
	sig_blob_len, sb_status := encode_ssh_ed25519_signature(raw_sig, sig_blob[:])
	if sb_status != .Ok {
		return 0, sb_status
	}

	payload: [1024]u8
	enc := encoder_init(payload[:])
	ok := encode_byte(&enc, u8(Message_Type.Userauth_Request)) &&
		encode_ssh_string(&enc, username) &&
		encode_ssh_string(&enc, "ssh-connection") &&
		encode_ssh_string(&enc, "publickey") &&
		encode_bool(&enc, true) &&
		encode_ssh_string(&enc, ALG_HOST_KEY) &&
		encode_ssh_bytes(&enc, pub_blob[:pub_blob_len]) &&
		encode_ssh_bytes(&enc, sig_blob[:sig_blob_len])
	if !ok {
		return 0, .Buffer_Too_Small
	}

	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.state = .Auth_Sent
	}
	return written, status
}

client_receive_userauth_response :: proc "contextless" (s: ^Client_Session, wire: []u8) -> (consumed: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Auth_Sent {
		return 0, .Bad_State
	}
	payload: [1024]u8
	plen, n, u_status := session_unpack_packet(s, wire, payload[:])
	if u_status != .Ok {
		return 0, u_status
	}
	if plen < 1 {
		return 0, .Truncated
	}
	msg_type, t_ok := message_type_of_byte(payload[0])
	if !t_ok {
		return 0, .Unexpected_Message
	}
	#partial switch msg_type {
	case .Userauth_Success:
		if plen != 1 {
			return 0, .Truncated
		}
		s.state = .Authenticated
		return n, .Ok
	case .Userauth_Failure:
		s.state = .Userauth_Ready
		return n, .Auth_Failed
	case .Userauth_Banner:
		// Banner is informational; remain in Auth_Sent awaiting Success or Failure.
		return n, .Ok
	case:
		return 0, .Unexpected_Message
	}
}

// --- RFC 4254: Interactive session channel ---

client_write_channel_open_session :: proc "contextless" (
	s: ^Client_Session,
	local_channel_id: u32,
	initial_window: u32,
	max_packet_size: u32,
	pad_bytes: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if s == nil || initial_window == 0 || max_packet_size == 0 || max_packet_size > MAX_PACKET_LENGTH {
		return 0, .Invalid_Argument
	}
	if s.state != .Authenticated {
		return 0, .Bad_State
	}
	payload: [64]u8
	enc := encoder_init(payload[:])
	ok := encode_byte(&enc, u8(Message_Type.Channel_Open)) &&
		encode_ssh_string(&enc, "session") &&
		encode_u32(&enc, local_channel_id) &&
		encode_u32(&enc, initial_window) &&
		encode_u32(&enc, max_packet_size)
	if !ok {
		return 0, .Buffer_Too_Small
	}
	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.local_channel_id = local_channel_id
		s.local_window = initial_window
		s.state = .Channel_Opening
	}
	return written, status
}

client_receive_channel_open_confirmation :: proc "contextless" (s: ^Client_Session, wire: []u8) -> (consumed: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Opening {
		return 0, .Bad_State
	}
	payload: [256]u8
	plen, n, u_status := session_unpack_packet(s, wire, payload[:])
	if u_status != .Ok {
		return 0, u_status
	}
	dec := decoder_init(payload[:plen])
	msg_byte, m_ok := decode_byte(&dec)
	if !m_ok {
		return 0, .Truncated
	}
	msg_type, t_ok := message_type_of_byte(msg_byte)
	if !t_ok {
		return 0, .Unexpected_Message
	}
	if msg_type == .Channel_Open_Failure {
		s.state = .Authenticated
		return n, .Channel_Rejected
	}
	if msg_type != .Channel_Open_Confirmation {
		return 0, .Unexpected_Message
	}
	recipient, r_ok := decode_u32(&dec)
	sender, s_ok := decode_u32(&dec)
	rem_win, w_ok := decode_u32(&dec)
	rem_max, p_ok := decode_u32(&dec)
	if !(r_ok && s_ok && w_ok && p_ok) || decoder_remaining(&dec) != 0 {
		return 0, .Truncated
	}
	if recipient != s.local_channel_id || rem_max == 0 {
		return 0, .Unexpected_Message
	}
	s.remote_channel_id = sender
	s.remote_window = rem_win
	s.remote_max_packet = min(rem_max, MAX_PACKET_LENGTH)
	s.eof_sent = false
	s.eof_received = false
	s.close_sent = false
	s.close_received = false
	s.state = .Channel_Open
	return n, .Ok
}

client_write_channel_request_pty :: proc "contextless" (
	s: ^Client_Session,
	term: string,
	cols, rows: u32,
	want_reply: bool,
	pad_bytes: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if s == nil || len(term) == 0 || len(term) > MAX_TERM_LENGTH || cols == 0 || rows == 0 {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Open || s.close_sent {
		return 0, .Bad_State
	}
	payload: [256]u8
	enc := encoder_init(payload[:])
	ok := encode_byte(&enc, u8(Message_Type.Channel_Request)) &&
		encode_u32(&enc, s.remote_channel_id) &&
		encode_ssh_string(&enc, "pty-req") &&
		encode_bool(&enc, want_reply) &&
		encode_ssh_string(&enc, term) &&
		encode_u32(&enc, cols) &&
		encode_u32(&enc, rows) &&
		encode_u32(&enc, 0) && // pixel width
		encode_u32(&enc, 0) && // pixel height
		encode_ssh_bytes(&enc, []u8{0}) // TTY_OP_END
	if !ok {
		return 0, .Buffer_Too_Small
	}
	return session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
}

client_write_channel_request_shell :: proc "contextless" (
	s: ^Client_Session,
	want_reply: bool,
	pad_bytes: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Open || s.close_sent {
		return 0, .Bad_State
	}
	payload: [64]u8
	enc := encoder_init(payload[:])
	ok := encode_byte(&enc, u8(Message_Type.Channel_Request)) &&
		encode_u32(&enc, s.remote_channel_id) &&
		encode_ssh_string(&enc, "shell") &&
		encode_bool(&enc, want_reply)
	if !ok {
		return 0, .Buffer_Too_Small
	}
	return session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
}

client_write_channel_request_window_change :: proc "contextless" (
	s: ^Client_Session,
	cols, rows: u32,
	pad_bytes: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if s == nil || cols == 0 || rows == 0 {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Open || s.close_sent {
		return 0, .Bad_State
	}
	payload: [64]u8
	enc := encoder_init(payload[:])
	ok := encode_byte(&enc, u8(Message_Type.Channel_Request)) &&
		encode_u32(&enc, s.remote_channel_id) &&
		encode_ssh_string(&enc, "window-change") &&
		encode_bool(&enc, false) && // RFC 4254 section 6.7: want_reply is FALSE
		encode_u32(&enc, cols) &&
		encode_u32(&enc, rows) &&
		encode_u32(&enc, 0) &&
		encode_u32(&enc, 0)
	if !ok {
		return 0, .Buffer_Too_Small
	}
	return session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
}

client_write_channel_data :: proc "contextless" (
	s: ^Client_Session,
	data: []u8,
	pad_bytes: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if s == nil || len(data) == 0 {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Open || s.eof_sent || s.close_sent {
		return 0, .Bad_State
	}
	if u32(len(data)) > s.remote_max_packet || u32(len(data)) > s.remote_window {
		return 0, .Window_Exceeded
	}
	if 1 + 4 + 4 + len(data) + 1 + MIN_PADDING_LENGTH > MAX_PACKET_LENGTH {
		return 0, .Oversized_Packet
	}
	payload: [MAX_PAYLOAD_SCRATCH]u8
	enc := encoder_init(payload[:])
	ok := encode_byte(&enc, u8(Message_Type.Channel_Data)) &&
		encode_u32(&enc, s.remote_channel_id) &&
		encode_ssh_bytes(&enc, data)
	if !ok {
		return 0, .Buffer_Too_Small
	}
	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.remote_window -= u32(len(data))
	}
	return written, status
}

client_write_channel_window_adjust :: proc "contextless" (
	s: ^Client_Session,
	bytes_to_add: u32,
	pad_bytes: []u8,
	out: []u8,
) -> (written: int, status: Status) {
	if s == nil || bytes_to_add == 0 {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Open || s.close_sent {
		return 0, .Bad_State
	}
	if bytes_to_add > max(u32) - s.local_window {
		return 0, .Window_Exceeded
	}
	payload: [16]u8
	enc := encoder_init(payload[:])
	ok := encode_byte(&enc, u8(Message_Type.Channel_Window_Adjust)) &&
		encode_u32(&enc, s.remote_channel_id) &&
		encode_u32(&enc, bytes_to_add)
	if !ok {
		return 0, .Buffer_Too_Small
	}
	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.local_window += bytes_to_add
	}
	return written, status
}

client_write_channel_eof :: proc "contextless" (s: ^Client_Session, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Open || s.eof_sent || s.close_sent {
		return 0, .Bad_State
	}
	payload: [16]u8
	enc := encoder_init(payload[:])
	if !encode_byte(&enc, u8(Message_Type.Channel_Eof)) || !encode_u32(&enc, s.remote_channel_id) {
		return 0, .Buffer_Too_Small
	}
	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.eof_sent = true
	}
	return written, status
}

client_write_channel_close :: proc "contextless" (s: ^Client_Session, pad_bytes: []u8, out: []u8) -> (written: int, status: Status) {
	if s == nil {
		return 0, .Invalid_Argument
	}
	if s.state != .Channel_Open || s.close_sent {
		return 0, .Bad_State
	}
	payload: [16]u8
	enc := encoder_init(payload[:])
	if !encode_byte(&enc, u8(Message_Type.Channel_Close)) || !encode_u32(&enc, s.remote_channel_id) {
		return 0, .Buffer_Too_Small
	}
	written, status = session_pack_packet(s, encoder_bytes(&enc), pad_bytes, out)
	if status == .Ok {
		s.close_sent = true
		if s.close_received {
			s.state = .Closed
		}
	}
	return written, status
}

// client_receive_channel_message authenticates and dispatches one encrypted message on an open session channel.
client_receive_channel_message :: proc "contextless" (
	s: ^Client_Session,
	wire: []u8,
	data_out: []u8,
) -> (event: Channel_Event, data_len: int, consumed: int, status: Status) {
	if s == nil {
		return .None, 0, 0, .Invalid_Argument
	}
	if s.state != .Channel_Open {
		return .None, 0, 0, .Bad_State
	}
	payload: [MAX_PAYLOAD_SCRATCH]u8
	plen, n, u_status := session_unpack_packet(s, wire, payload[:])
	if u_status != .Ok {
		return .None, 0, 0, u_status
	}
	dec := decoder_init(payload[:plen])
	msg_byte, m_ok := decode_byte(&dec)
	if !m_ok {
		return .None, 0, 0, .Truncated
	}
	msg_type, t_ok := message_type_of_byte(msg_byte)
	if !t_ok {
		return .None, 0, 0, .Unexpected_Message
	}

	switch msg_type {
	case .Channel_Data:
		recipient, r_ok := decode_u32(&dec)
		chunk, c_ok := decode_ssh_bytes(&dec)
		if !r_ok || !c_ok || decoder_remaining(&dec) != 0 || recipient != s.local_channel_id {
			return .None, 0, 0, .Unexpected_Message
		}
		if u32(len(chunk)) > s.local_window {
			return .None, 0, 0, .Window_Exceeded
		}
		if len(data_out) < len(chunk) {
			return .None, 0, 0, .Buffer_Too_Small
		}
		copy(data_out[:len(chunk)], chunk)
		s.local_window -= u32(len(chunk))
		return .Data, len(chunk), n, .Ok

	case .Channel_Extended_Data:
		recipient, r_ok := decode_u32(&dec)
		_, dt_ok := decode_u32(&dec)
		chunk, c_ok := decode_ssh_bytes(&dec)
		if !r_ok || !dt_ok || !c_ok || decoder_remaining(&dec) != 0 || recipient != s.local_channel_id {
			return .None, 0, 0, .Unexpected_Message
		}
		if u32(len(chunk)) > s.local_window {
			return .None, 0, 0, .Window_Exceeded
		}
		if len(data_out) < len(chunk) {
			return .None, 0, 0, .Buffer_Too_Small
		}
		copy(data_out[:len(chunk)], chunk)
		s.local_window -= u32(len(chunk))
		return .Extended_Data, len(chunk), n, .Ok

	case .Channel_Window_Adjust:
		recipient, r_ok := decode_u32(&dec)
		added, a_ok := decode_u32(&dec)
		if !r_ok || !a_ok || decoder_remaining(&dec) != 0 || recipient != s.local_channel_id {
			return .None, 0, 0, .Unexpected_Message
		}
		if added > max(u32) - s.remote_window {
			return .None, 0, 0, .Window_Exceeded
		}
		s.remote_window += added
		s.last_window_added = added
		return .Window_Adjust, 0, n, .Ok

	case .Channel_Eof:
		recipient, r_ok := decode_u32(&dec)
		if !r_ok || decoder_remaining(&dec) != 0 || recipient != s.local_channel_id {
			return .None, 0, 0, .Unexpected_Message
		}
		s.eof_received = true
		return .Eof, 0, n, .Ok

	case .Channel_Close:
		recipient, r_ok := decode_u32(&dec)
		if !r_ok || decoder_remaining(&dec) != 0 || recipient != s.local_channel_id {
			return .None, 0, 0, .Unexpected_Message
		}
		s.close_received = true
		if s.close_sent {
			s.state = .Closed
		}
		return .Close, 0, n, .Ok

	case .Channel_Success:
		recipient, r_ok := decode_u32(&dec)
		if !r_ok || decoder_remaining(&dec) != 0 || recipient != s.local_channel_id {
			return .None, 0, 0, .Unexpected_Message
		}
		return .Request_Success, 0, n, .Ok

	case .Channel_Failure:
		recipient, r_ok := decode_u32(&dec)
		if !r_ok || decoder_remaining(&dec) != 0 || recipient != s.local_channel_id {
			return .None, 0, 0, .Unexpected_Message
		}
		return .Request_Failure, 0, n, .Ok

	case .Disconnect:
		reason, r_ok := decode_u32(&dec)
		if !r_ok {
			return .None, 0, 0, .Truncated
		}
		s.last_disconnect_code = reason
		s.state = .Closed
		return .Disconnected, 0, n, .Ok

	case .Ignore, .Debug:
		return .Ignored, 0, n, .Ok

	case .Unimplemented, .Service_Request, .Service_Accept, .Kexinit, .Newkeys,
		.Kex_Ecdh_Init, .Kex_Ecdh_Reply, .Userauth_Request, .Userauth_Failure,
		.Userauth_Success, .Userauth_Banner, .Userauth_Pk_Ok, .Global_Request,
		.Channel_Open, .Channel_Open_Confirmation, .Channel_Open_Failure, .Channel_Request:
		return .None, 0, 0, .Unexpected_Message
	}
	return .None, 0, 0, .Unexpected_Message
}
