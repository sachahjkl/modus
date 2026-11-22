// Full RFC 8446 TLS 1.3 client and server byte-stream state machine over TCP records.
// Pure freestanding zero-allocation code reusing modus:cryptography_primitives.
package tls_tcp

import "modus:contract/byte_order"

// Configuration supplied by the caller to initialize a TLS 1.3 session.
Tls_Config :: struct {
	role:                      Tls_Role,
	preferred_suite:           Tls_Cipher_Suite,
	restrict_to_preferred:     bool, // When true on client, offer only preferred_suite.
	server_name:               [MAX_SERVER_NAME_LEN]u8,
	server_name_len:           int,
	ephemeral_private_key:     [X25519_KEY_SIZE]u8,
	random_bytes:              [32]u8,
	server_ed25519_private_key: [ED25519_KEY_SIZE]u8, // Server role only.
	pinned_server_public_key:  [ED25519_KEY_SIZE]u8, // Client role only.
}

// Complete in-memory state of one TLS 1.3 over TCP endpoint.
Tls_Session :: struct {
	config:          Tls_Config,
	state:           Tls_State,
	last_refusal:    Tls_Refusal,
	last_peer_alert: Tls_Alert_Description,
	peer_closed:     bool,

	negotiated_suite: Tls_Cipher_Suite,
	peer_server_name: [MAX_SERVER_NAME_LEN]u8,
	peer_server_name_len: int,

	schedule:  Key_Schedule,
	send_keys: Traffic_Keys,
	recv_keys: Traffic_Keys,

	transcript:     [MAX_TRANSCRIPT_SIZE]u8,
	transcript_len: int,

	handshake_buf: [MAX_HANDSHAKE_REASSEMBLY]u8,
	handshake_len: int,

	send_buf: [MAX_WIRE_BUFFER]u8,
	send_len: int,

	recv_buf: [MAX_WIRE_BUFFER]u8,
	recv_len: int,

	app_buf: [MAX_APP_BUFFER]u8,
	app_len: int,
}

// tls_session_erase_secrets wipes all cryptographic secrets held by a session.
tls_session_erase_secrets :: proc "contextless" (session: ^Tls_Session) {
	erase_bytes(session.config.ephemeral_private_key[:])
	erase_bytes(session.config.server_ed25519_private_key[:])
	key_schedule_erase(&session.schedule)
	traffic_keys_erase(&session.send_keys)
	traffic_keys_erase(&session.recv_keys)
}

// tls_session_init validates configuration and prepares a client or server session.
tls_session_init :: proc "contextless" (session: ^Tls_Session, cfg: ^Tls_Config) -> Tls_Refusal {
	session^ = {}
	role, role_ok := tls_role_of_word(u8(cfg.role))
	if !role_ok {
		session.state = .Failed
		session.last_refusal = .Invalid_Role
		return .Invalid_Role
	}
	suite, suite_ok := cipher_suite_of_word(u16(cfg.preferred_suite))
	if !suite_ok {
		session.state = .Failed
		session.last_refusal = .Invalid_Cipher_Suite
		return .Invalid_Cipher_Suite
	}
	if cfg.server_name_len < 0 || cfg.server_name_len > MAX_SERVER_NAME_LEN {
		session.state = .Failed
		session.last_refusal = .Invalid_Configuration
		return .Invalid_Configuration
	}
	if is_all_zero(cfg.ephemeral_private_key[:]) || is_all_zero(cfg.random_bytes[:]) {
		session.state = .Failed
		session.last_refusal = .Invalid_Configuration
		return .Invalid_Configuration
	}
	switch role {
	case .Client:
		if is_all_zero(cfg.pinned_server_public_key[:]) {
			session.state = .Failed
			session.last_refusal = .Invalid_Configuration
			return .Invalid_Configuration
		}
	case .Server:
		if is_all_zero(cfg.server_ed25519_private_key[:]) {
			session.state = .Failed
			session.last_refusal = .Invalid_Configuration
			return .Invalid_Configuration
		}
	}

	session.config = cfg^
	session.config.role = role
	session.config.preferred_suite = suite
	switch role {
	case .Client:
		session.state = .Initial
	case .Server:
		session.state = .Server_Wait_Client_Hello
	}
	return .None
}

// tls_client_start generates and queues the ClientHello record for a client session.
tls_client_start :: proc "contextless" (session: ^Tls_Session) -> Tls_Refusal {
	if session.config.role != .Client || session.state != .Initial {
		return fail_session(session, .Invalid_State)
	}
	pub_key: [X25519_KEY_SIZE]u8
	basepoint := X25519_BASEPOINT
	if r := x25519_scalar_mult(session.config.ephemeral_private_key[:], basepoint[:], &pub_key); r != .None {
		return fail_session(session, r)
	}

	msg_buf: [1024]u8
	msg_len, build_ref := build_client_hello(session, pub_key[:], msg_buf[:])
	if build_ref != .None {
		return fail_session(session, build_ref)
	}
	if r := append_transcript(session, msg_buf[:msg_len]); r != .None {
		return fail_session(session, r)
	}
	if r := queue_plaintext_record(session, .Handshake, msg_buf[:msg_len]); r != .None {
		return fail_session(session, r)
	}
	session.state = .Client_Wait_Server_Hello
	return .None
}

// tls_take_outgoing copies queued wire bytes out of the session send buffer.
tls_take_outgoing :: proc "contextless" (session: ^Tls_Session, out: []u8) -> int {
	if session.send_len == 0 || len(out) == 0 {
		return 0
	}
	n := min(session.send_len, len(out))
	copy(out[:n], session.send_buf[:n])
	rem := session.send_len - n
	if rem > 0 {
		copy(session.send_buf[:rem], session.send_buf[n:session.send_len])
	}
	session.send_len = rem
	return n
}

// tls_pending_outgoing returns how many wire bytes are waiting to be sent.
tls_pending_outgoing :: proc "contextless" (session: ^Tls_Session) -> int {
	return session.send_len
}

// tls_read_application_data reads decrypted application bytes received from the peer.
tls_read_application_data :: proc "contextless" (session: ^Tls_Session, out: []u8) -> int {
	if session.app_len == 0 || len(out) == 0 {
		return 0
	}
	n := min(session.app_len, len(out))
	copy(out[:n], session.app_buf[:n])
	rem := session.app_len - n
	if rem > 0 {
		copy(session.app_buf[:rem], session.app_buf[n:session.app_len])
	}
	session.app_len = rem
	return n
}

// tls_send_application_data encrypts plaintext into RFC 8446 Application_Data records.
tls_send_application_data :: proc "contextless" (session: ^Tls_Session, data: []u8) -> Tls_Refusal {
	if session.state != .Connected {
		return .Invalid_State
	}
	offset := 0
	for offset < len(data) {
		chunk := min(len(data) - offset, MAX_PLAINTEXT_SIZE)
		if r := queue_encrypted_record(session, .Application_Data, data[offset:offset + chunk]); r != .None {
			return fail_session(session, r)
		}
		offset += chunk
	}
	return .None
}

// tls_send_close_notify queues an encrypted close_notify alert and closes the session.
tls_send_close_notify :: proc "contextless" (session: ^Tls_Session) -> Tls_Refusal {
	if session.state != .Connected {
		return .Invalid_State
	}
	alert := [2]u8{u8(Tls_Alert_Level.Warning), u8(Tls_Alert_Description.Close_Notify)}
	if r := queue_encrypted_record(session, .Alert, alert[:]); r != .None {
		return fail_session(session, r)
	}
	session.state = .Closed
	tls_session_erase_secrets(session)
	return .None
}

// tls_feed_incoming ingests incoming TCP stream bytes and advances the TLS 1.3 state machine.
tls_feed_incoming :: proc "contextless" (session: ^Tls_Session, data: []u8) -> Tls_Refusal {
	if session.state == .Failed {
		return session.last_refusal
	}
	if session.state == .Closed {
		return .Peer_Closed
	}
	if len(data) == 0 {
		return .None
	}
	if session.recv_len + len(data) > MAX_WIRE_BUFFER {
		return fail_session(session, .Buffer_Too_Small)
	}
	copy(session.recv_buf[session.recv_len:], data)
	session.recv_len += len(data)

	for session.recv_len >= RECORD_HEADER_SIZE {
		allow_0301 := session.state == .Server_Wait_Client_Hello
		header, hdr_ref := record_parse_header(session.recv_buf[:session.recv_len], allow_0301)
		if hdr_ref != .None {
			return fail_session(session, hdr_ref)
		}
		total_rec := RECORD_HEADER_SIZE + int(header.length)
		if session.recv_len < total_rec {
			break
		}

		// Process one complete record.
		rec_ref := process_incoming_record(session, header, session.recv_buf[:total_rec])
		rem := session.recv_len - total_rec
		if rem > 0 {
			copy(session.recv_buf[:rem], session.recv_buf[total_rec:session.recv_len])
		}
		session.recv_len = rem

		if rec_ref != .None {
			return rec_ref
		}
		if session.state == .Closed {
			break
		}
	}
	return .None
}

// Internal helpers.

@(private = "file")
fail_session :: proc "contextless" (session: ^Tls_Session, reason: Tls_Refusal) -> Tls_Refusal {
	session.state = .Failed
	session.last_refusal = reason
	tls_session_erase_secrets(session)
	return reason
}

@(private = "file")
append_transcript :: proc "contextless" (session: ^Tls_Session, msg: []u8) -> Tls_Refusal {
	if session.transcript_len + len(msg) > MAX_TRANSCRIPT_SIZE {
		return .Transcript_Full
	}
	copy(session.transcript[session.transcript_len:], msg)
	session.transcript_len += len(msg)
	return .None
}

@(private = "file")
queue_plaintext_record :: proc "contextless" (session: ^Tls_Session, ct: Tls_Content_Type, payload: []u8) -> Tls_Refusal {
	avail := session.send_buf[session.send_len:]
	n, ref := record_write_plaintext(ct, payload, avail)
	if ref != .None {
		return ref
	}
	session.send_len += n
	return .None
}

@(private = "file")
queue_encrypted_record :: proc "contextless" (session: ^Tls_Session, inner_type: Tls_Content_Type, payload: []u8) -> Tls_Refusal {
	avail := session.send_buf[session.send_len:]
	n, ref := record_encrypt(&session.send_keys, inner_type, payload, 0, avail)
	if ref != .None {
		return ref
	}
	session.send_len += n
	return .None
}

@(private = "file")
process_incoming_record :: proc "contextless" (session: ^Tls_Session, header: Record_Header, full_record: []u8) -> Tls_Refusal {
	payload := full_record[RECORD_HEADER_SIZE:]

	// Middlebox compatibility ChangeCipherSpec is ignored during an active handshake (RFC 8446 section 5).
	if header.content_type == .Change_Cipher_Spec {
		if session.state == .Connected || session.state == .Initial || len(payload) != 1 || payload[0] != 0x01 {
			return fail_session(session, .Malformed_Message)
		}
		return .None
	}

	// Plaintext alert before encryption keys become active.
	if header.content_type == .Alert && !session.recv_keys.active {
		return handle_alert_payload(session, payload)
	}

	// Encrypted records when receive keys are active.
	if session.recv_keys.active {
		if header.content_type != .Application_Data {
			return fail_session(session, .Invalid_Content_Type)
		}
		plain_buf: [MAX_PLAINTEXT_SIZE]u8
		inner_type, plain_len, dec_ref := record_decrypt(&session.recv_keys, full_record, plain_buf[:])
		if dec_ref != .None {
			return fail_session(session, dec_ref)
		}
		plain := plain_buf[:plain_len]
		switch inner_type {
		case .Handshake:
			return ingest_handshake_bytes(session, plain)
		case .Application_Data:
			if session.state != .Connected {
				return fail_session(session, .Invalid_State)
			}
			if session.app_len + plain_len > MAX_APP_BUFFER {
				return fail_session(session, .Buffer_Too_Small)
			}
			copy(session.app_buf[session.app_len:], plain)
			session.app_len += plain_len
			return .None
		case .Alert:
			return handle_alert_payload(session, plain)
		case .Change_Cipher_Spec:
			return fail_session(session, .Invalid_Content_Type)
		}
		return fail_session(session, .Invalid_Content_Type)
	}

	// Plaintext handshake records before encryption keys are active.
	if header.content_type != .Handshake {
		return fail_session(session, .Invalid_Content_Type)
	}
	return ingest_handshake_bytes(session, payload)
}

@(private = "file")
handle_alert_payload :: proc "contextless" (session: ^Tls_Session, payload: []u8) -> Tls_Refusal {
	if len(payload) != 2 {
		return fail_session(session, .Malformed_Message)
	}
	level, level_ok := alert_level_of_word(payload[0])
	desc, desc_ok := alert_description_of_word(payload[1])
	if !level_ok || !desc_ok {
		return fail_session(session, .Malformed_Message)
	}
	session.last_peer_alert = desc
	if desc == .Close_Notify && level == .Warning {
		session.peer_closed = true
		session.state = .Closed
		tls_session_erase_secrets(session)
		return .None
	}
	return fail_session(session, .Peer_Alert)
}

@(private = "file")
ingest_handshake_bytes :: proc "contextless" (session: ^Tls_Session, bytes: []u8) -> Tls_Refusal {
	if len(bytes) == 0 {
		return fail_session(session, .Malformed_Message)
	}
	if session.handshake_len + len(bytes) > MAX_HANDSHAKE_REASSEMBLY {
		return fail_session(session, .Buffer_Too_Small)
	}
	copy(session.handshake_buf[session.handshake_len:], bytes)
	session.handshake_len += len(bytes)

	for session.handshake_len >= HANDSHAKE_HEADER_SIZE {
		msg_type, type_ok := handshake_type_of_word(session.handshake_buf[0])
		if !type_ok {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		body_len := int(session.handshake_buf[1]) << 16 | int(session.handshake_buf[2]) << 8 | int(session.handshake_buf[3])
		total_msg := HANDSHAKE_HEADER_SIZE + body_len
		if total_msg > MAX_HANDSHAKE_REASSEMBLY {
			return fail_session(session, .Record_Too_Large)
		}
		if session.handshake_len < total_msg {
			break
		}

		// Copy message out so reassembly buffer can shift cleanly before dispatch.
		msg_copy: [MAX_HANDSHAKE_REASSEMBLY]u8
		copy(msg_copy[:total_msg], session.handshake_buf[:total_msg])
		rem := session.handshake_len - total_msg
		if rem > 0 {
			copy(session.handshake_buf[:rem], session.handshake_buf[total_msg:session.handshake_len])
		}
		session.handshake_len = rem

		key_change := false
		ref := dispatch_handshake_message(session, msg_type, msg_copy[:total_msg], &key_change)
		if ref != .None {
			return ref
		}
		// RFC 8446 section 5.1: handshake messages must not cross an encryption key boundary in one record.
		if key_change && session.handshake_len > 0 {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
	}
	return .None
}

@(private = "file")
dispatch_handshake_message :: proc "contextless" (session: ^Tls_Session, msg_type: Tls_Handshake_Type, raw_msg: []u8, key_change: ^bool) -> Tls_Refusal {
	body := raw_msg[HANDSHAKE_HEADER_SIZE:]
	switch session.state {
	case .Server_Wait_Client_Hello:
		if msg_type != .Client_Hello {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		key_change^ = true
		return handle_client_hello(session, raw_msg, body)
	case .Client_Wait_Server_Hello:
		if msg_type != .Server_Hello {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		key_change^ = true
		return handle_server_hello(session, raw_msg, body)
	case .Client_Wait_Encrypted_Extensions:
		if msg_type != .Encrypted_Extensions {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		return handle_encrypted_extensions(session, raw_msg, body)
	case .Client_Wait_Certificate:
		if msg_type != .Certificate {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		return handle_certificate(session, raw_msg, body)
	case .Client_Wait_Certificate_Verify:
		if msg_type != .Certificate_Verify {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		return handle_certificate_verify(session, raw_msg, body)
	case .Client_Wait_Finished:
		if msg_type != .Finished {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		key_change^ = true
		return handle_server_finished(session, raw_msg, body)
	case .Server_Wait_Client_Finished:
		if msg_type != .Finished {
			return fail_session(session, .Unexpected_Handshake_Message)
		}
		key_change^ = true
		return handle_client_finished(session, raw_msg, body)
	case .Connected:
		if session.config.role == .Client && msg_type == .New_Session_Ticket {
			return .None
		}
		return fail_session(session, .Unexpected_Handshake_Message)
	case .Initial, .Closed, .Failed:
		return fail_session(session, .Invalid_State)
	}
	return fail_session(session, .Invalid_State)
}

// Handshake message builders.

@(private = "file")
write_handshake_header :: proc "contextless" (out: []u8, msg_type: Tls_Handshake_Type, body_len: int) {
	out[0] = u8(msg_type)
	out[1] = u8((body_len >> 16) & 0xFF)
	out[2] = u8((body_len >> 8) & 0xFF)
	out[3] = u8(body_len & 0xFF)
}

@(private = "file")
build_client_hello :: proc "contextless" (session: ^Tls_Session, x25519_pub: []u8, out: []u8) -> (written: int, refusal: Tls_Refusal) {
	pos := HANDSHAKE_HEADER_SIZE
	if len(out) < 512 {
		return 0, .Buffer_Too_Small
	}
	// legacy_version = 0x0303.
	byte_order.write_u16_big_endian(out, pos, TLS_LEGACY_VERSION)
	pos += 2
	// random (32 bytes).
	copy(out[pos:pos + 32], session.config.random_bytes[:])
	pos += 32
	// legacy_session_id (empty).
	out[pos] = 0
	pos += 1

	// cipher_suites.
	if session.config.restrict_to_preferred {
		byte_order.write_u16_big_endian(out, pos, 2)
		pos += 2
		byte_order.write_u16_big_endian(out, pos, u16(session.config.preferred_suite))
		pos += 2
	} else {
		other := Tls_Cipher_Suite.TLS_AES_128_GCM_SHA256
		if session.config.preferred_suite == .TLS_AES_128_GCM_SHA256 {
			other = .TLS_CHACHA20_POLY1305_SHA256
		}
		byte_order.write_u16_big_endian(out, pos, 4)
		pos += 2
		byte_order.write_u16_big_endian(out, pos, u16(session.config.preferred_suite))
		pos += 2
		byte_order.write_u16_big_endian(out, pos, u16(other))
		pos += 2
	}

	// legacy_compression_methods = [0].
	out[pos] = 1
	out[pos + 1] = 0
	pos += 2

	// Reserve extensions total length.
	ext_len_pos := pos
	pos += 2
	ext_start := pos

	// Optional SNI extension (server_name = 0).
	if session.config.server_name_len > 0 {
		nlen := session.config.server_name_len
		byte_order.write_u16_big_endian(out, pos, u16(Tls_Extension_Type.Server_Name))
		byte_order.write_u16_big_endian(out, pos + 2, u16(nlen + 5))
		byte_order.write_u16_big_endian(out, pos + 4, u16(nlen + 3))
		out[pos + 6] = 0 // host_name
		byte_order.write_u16_big_endian(out, pos + 7, u16(nlen))
		copy(out[pos + 9:], session.config.server_name[:nlen])
		pos += 9 + nlen
	}

	// supported_versions (43): TLS 1.3 only.
	byte_order.write_u16_big_endian(out, pos, u16(Tls_Extension_Type.Supported_Versions))
	byte_order.write_u16_big_endian(out, pos + 2, 3)
	out[pos + 4] = 2
	byte_order.write_u16_big_endian(out, pos + 5, TLS_VERSION_1_3)
	pos += 7

	// supported_groups (10): X25519.
	byte_order.write_u16_big_endian(out, pos, u16(Tls_Extension_Type.Supported_Groups))
	byte_order.write_u16_big_endian(out, pos + 2, 4)
	byte_order.write_u16_big_endian(out, pos + 4, 2)
	byte_order.write_u16_big_endian(out, pos + 6, NAMED_GROUP_X25519)
	pos += 8

	// signature_algorithms (13): Ed25519.
	byte_order.write_u16_big_endian(out, pos, u16(Tls_Extension_Type.Signature_Algorithms))
	byte_order.write_u16_big_endian(out, pos + 2, 4)
	byte_order.write_u16_big_endian(out, pos + 4, 2)
	byte_order.write_u16_big_endian(out, pos + 6, SIGNATURE_SCHEME_ED25519)
	pos += 8

	// key_share (51): X25519 32-byte public key.
	byte_order.write_u16_big_endian(out, pos, u16(Tls_Extension_Type.Key_Share))
	byte_order.write_u16_big_endian(out, pos + 2, 38)
	byte_order.write_u16_big_endian(out, pos + 4, 36)
	byte_order.write_u16_big_endian(out, pos + 6, NAMED_GROUP_X25519)
	byte_order.write_u16_big_endian(out, pos + 8, X25519_KEY_SIZE)
	copy(out[pos + 10:pos + 10 + X25519_KEY_SIZE], x25519_pub)
	pos += 10 + X25519_KEY_SIZE

	byte_order.write_u16_big_endian(out, ext_len_pos, u16(pos - ext_start))
	write_handshake_header(out, .Client_Hello, pos - HANDSHAKE_HEADER_SIZE)
	return pos, .None
}

@(private = "file")
build_server_hello :: proc "contextless" (session: ^Tls_Session, session_id: []u8, suite: Tls_Cipher_Suite, server_x25519_pub: []u8, out: []u8) -> int {
	pos := HANDSHAKE_HEADER_SIZE
	byte_order.write_u16_big_endian(out, pos, TLS_LEGACY_VERSION)
	pos += 2
	copy(out[pos:pos + 32], session.config.random_bytes[:])
	pos += 32
	out[pos] = u8(len(session_id))
	pos += 1
	copy(out[pos:], session_id)
	pos += len(session_id)
	byte_order.write_u16_big_endian(out, pos, u16(suite))
	pos += 2
	out[pos] = 0 // legacy_compression_method
	pos += 1

	ext_len_pos := pos
	pos += 2
	ext_start := pos

	// supported_versions (43): 0x0304.
	byte_order.write_u16_big_endian(out, pos, u16(Tls_Extension_Type.Supported_Versions))
	byte_order.write_u16_big_endian(out, pos + 2, 2)
	byte_order.write_u16_big_endian(out, pos + 4, TLS_VERSION_1_3)
	pos += 6

	// key_share (51): X25519 public key.
	byte_order.write_u16_big_endian(out, pos, u16(Tls_Extension_Type.Key_Share))
	byte_order.write_u16_big_endian(out, pos + 2, 36)
	byte_order.write_u16_big_endian(out, pos + 4, NAMED_GROUP_X25519)
	byte_order.write_u16_big_endian(out, pos + 6, X25519_KEY_SIZE)
	copy(out[pos + 8:pos + 8 + X25519_KEY_SIZE], server_x25519_pub)
	pos += 8 + X25519_KEY_SIZE

	byte_order.write_u16_big_endian(out, ext_len_pos, u16(pos - ext_start))
	write_handshake_header(out, .Server_Hello, pos - HANDSHAKE_HEADER_SIZE)
	return pos
}

@(private = "file")
build_encrypted_extensions :: proc "contextless" (out: []u8) -> int {
	write_handshake_header(out, .Encrypted_Extensions, 2)
	byte_order.write_u16_big_endian(out, HANDSHAKE_HEADER_SIZE, 0)
	return HANDSHAKE_HEADER_SIZE + 2
}

@(private = "file")
build_certificate :: proc "contextless" (server_pub_key: []u8, out: []u8) -> int {
	pos := HANDSHAKE_HEADER_SIZE
	out[pos] = 0 // certificate_request_context len = 0
	pos += 1
	entry_len := 3 + ED25519_SPKI_SIZE + 2 // 49 bytes
	out[pos] = 0
	out[pos + 1] = u8((entry_len >> 8) & 0xFF)
	out[pos + 2] = u8(entry_len & 0xFF)
	pos += 3
	out[pos] = 0
	out[pos + 1] = 0
	out[pos + 2] = u8(ED25519_SPKI_SIZE)
	pos += 3
	prefix := ED25519_SPKI_PREFIX
	copy(out[pos:pos + 12], prefix[:])
	pos += 12
	copy(out[pos:pos + ED25519_KEY_SIZE], server_pub_key)
	pos += ED25519_KEY_SIZE
	byte_order.write_u16_big_endian(out, pos, 0) // entry extensions = 0
	pos += 2
	write_handshake_header(out, .Certificate, pos - HANDSHAKE_HEADER_SIZE)
	return pos
}

@(private = "file")
build_certificate_verify :: proc "contextless" (signature: []u8, out: []u8) -> int {
	pos := HANDSHAKE_HEADER_SIZE
	byte_order.write_u16_big_endian(out, pos, SIGNATURE_SCHEME_ED25519)
	byte_order.write_u16_big_endian(out, pos + 2, ED25519_SIGNATURE_SIZE)
	pos += 4
	copy(out[pos:pos + ED25519_SIGNATURE_SIZE], signature)
	pos += ED25519_SIGNATURE_SIZE
	write_handshake_header(out, .Certificate_Verify, pos - HANDSHAKE_HEADER_SIZE)
	return pos
}

@(private = "file")
build_finished :: proc "contextless" (verify_data: []u8, out: []u8) -> int {
	write_handshake_header(out, .Finished, HASH_SIZE)
	copy(out[HANDSHAKE_HEADER_SIZE:HANDSHAKE_HEADER_SIZE + HASH_SIZE], verify_data)
	return HANDSHAKE_HEADER_SIZE + HASH_SIZE
}

// Handshake message handlers.

@(private = "file")
handle_client_hello :: proc "contextless" (session: ^Tls_Session, raw_msg: []u8, body: []u8) -> Tls_Refusal {
	pos := 0
	if len(body) < 34 {
		return fail_session(session, .Malformed_Message)
	}
	legacy_ver := byte_order.read_u16_big_endian(body, pos)
	pos += 2
	if legacy_ver != TLS_LEGACY_VERSION {
		return fail_session(session, .Downgrade_Refused)
	}
	pos += 32 // client random

	if pos >= len(body) {
		return fail_session(session, .Malformed_Message)
	}
	sid_len := int(body[pos])
	pos += 1
	if sid_len > 32 || pos + sid_len > len(body) {
		return fail_session(session, .Malformed_Message)
	}
	session_id := body[pos:pos + sid_len]
	pos += sid_len

	// Cipher suites list.
	if pos + 2 > len(body) {
		return fail_session(session, .Malformed_Message)
	}
	cs_len := int(byte_order.read_u16_big_endian(body, pos))
	pos += 2
	if cs_len < 2 || cs_len % 2 != 0 || pos + cs_len > len(body) {
		return fail_session(session, .Malformed_Message)
	}
	offered_aes := false
	offered_chacha := false
	for i := 0; i < cs_len; i += 2 {
		word := byte_order.read_u16_big_endian(body, pos + i)
		suite, ok := cipher_suite_of_word(word)
		if ok {
			switch suite {
			case .TLS_AES_128_GCM_SHA256:
				offered_aes = true
			case .TLS_CHACHA20_POLY1305_SHA256:
				offered_chacha = true
			}
		}
	}
	pos += cs_len

	chosen_suite: Tls_Cipher_Suite
	if session.config.preferred_suite == .TLS_CHACHA20_POLY1305_SHA256 && offered_chacha {
		chosen_suite = .TLS_CHACHA20_POLY1305_SHA256
	} else if session.config.preferred_suite == .TLS_AES_128_GCM_SHA256 && offered_aes {
		chosen_suite = .TLS_AES_128_GCM_SHA256
	} else if offered_chacha {
		chosen_suite = .TLS_CHACHA20_POLY1305_SHA256
	} else if offered_aes {
		chosen_suite = .TLS_AES_128_GCM_SHA256
	} else {
		return fail_session(session, .Unsupported_Cipher_Suite)
	}

	// Compression methods must contain null (0x00).
	if pos >= len(body) {
		return fail_session(session, .Malformed_Message)
	}
	comp_len := int(body[pos])
	pos += 1
	if comp_len < 1 || pos + comp_len > len(body) {
		return fail_session(session, .Malformed_Message)
	}
	has_null_comp := false
	for i := 0; i < comp_len; i += 1 {
		if body[pos + i] == 0 {
			has_null_comp = true
		}
	}
	if !has_null_comp {
		return fail_session(session, .Malformed_Message)
	}
	pos += comp_len

	// Extensions.
	if pos + 2 > len(body) {
		return fail_session(session, .Missing_Required_Extension)
	}
	ext_total := int(byte_order.read_u16_big_endian(body, pos))
	pos += 2
	if pos + ext_total != len(body) {
		return fail_session(session, .Malformed_Message)
	}

	seen_exts: [32]u16
	seen_count := 0
	has_tls13 := false
	has_x25519_group := false
	has_ed25519_sig := false
	has_x25519_share := false
	client_pub_key: [X25519_KEY_SIZE]u8

	end := pos + ext_total
	for pos < end {
		if pos + 4 > end {
			return fail_session(session, .Malformed_Message)
		}
		ext_word := byte_order.read_u16_big_endian(body, pos)
		ext_len := int(byte_order.read_u16_big_endian(body, pos + 2))
		pos += 4
		if pos + ext_len > end {
			return fail_session(session, .Malformed_Message)
		}
		// Reject duplicate extension types.
		for k := 0; k < seen_count; k += 1 {
			if seen_exts[k] == ext_word {
				return fail_session(session, .Duplicate_Extension)
			}
		}
		if seen_count >= len(seen_exts) {
			return fail_session(session, .Malformed_Message)
		}
		seen_exts[seen_count] = ext_word
		seen_count += 1

		ext_data := body[pos:pos + ext_len]
		pos += ext_len

		ext_type, known := extension_type_of_word(ext_word)
		if !known {
			continue
		}
		switch ext_type {
		case .Server_Name:
			if len(ext_data) < 5 {
				return fail_session(session, .Malformed_Message)
			}
			list_len := int(byte_order.read_u16_big_endian(ext_data, 0))
			if list_len + 2 != len(ext_data) || ext_data[2] != 0 {
				return fail_session(session, .Malformed_Message)
			}
			nlen := int(byte_order.read_u16_big_endian(ext_data, 3))
			if nlen == 0 || nlen > MAX_SERVER_NAME_LEN || 5 + nlen != len(ext_data) {
				return fail_session(session, .Malformed_Message)
			}
			copy(session.peer_server_name[:nlen], ext_data[5:5 + nlen])
			session.peer_server_name_len = nlen
		case .Supported_Versions:
			if len(ext_data) < 3 {
				return fail_session(session, .Malformed_Message)
			}
			vlen := int(ext_data[0])
			if vlen < 2 || vlen % 2 != 0 || 1 + vlen != len(ext_data) {
				return fail_session(session, .Malformed_Message)
			}
			for i := 1; i < 1 + vlen; i += 2 {
				if byte_order.read_u16_big_endian(ext_data, i) == TLS_VERSION_1_3 {
					has_tls13 = true
				}
			}
		case .Supported_Groups:
			if len(ext_data) < 4 {
				return fail_session(session, .Malformed_Message)
			}
			glen := int(byte_order.read_u16_big_endian(ext_data, 0))
			if glen < 2 || glen % 2 != 0 || 2 + glen != len(ext_data) {
				return fail_session(session, .Malformed_Message)
			}
			for i := 2; i < 2 + glen; i += 2 {
				if byte_order.read_u16_big_endian(ext_data, i) == NAMED_GROUP_X25519 {
					has_x25519_group = true
				}
			}
		case .Signature_Algorithms:
			if len(ext_data) < 4 {
				return fail_session(session, .Malformed_Message)
			}
			slen := int(byte_order.read_u16_big_endian(ext_data, 0))
			if slen < 2 || slen % 2 != 0 || 2 + slen != len(ext_data) {
				return fail_session(session, .Malformed_Message)
			}
			for i := 2; i < 2 + slen; i += 2 {
				if byte_order.read_u16_big_endian(ext_data, i) == SIGNATURE_SCHEME_ED25519 {
					has_ed25519_sig = true
				}
			}
		case .Key_Share:
			if len(ext_data) < 2 {
				return fail_session(session, .Malformed_Message)
			}
			klen := int(byte_order.read_u16_big_endian(ext_data, 0))
			if 2 + klen != len(ext_data) {
				return fail_session(session, .Malformed_Message)
			}
			kp := 2
			for kp < len(ext_data) {
				if kp + 4 > len(ext_data) {
					return fail_session(session, .Malformed_Message)
				}
				grp := byte_order.read_u16_big_endian(ext_data, kp)
				el := int(byte_order.read_u16_big_endian(ext_data, kp + 2))
				kp += 4
				if kp + el > len(ext_data) {
					return fail_session(session, .Malformed_Message)
				}
				if grp == NAMED_GROUP_X25519 {
					if el != X25519_KEY_SIZE || has_x25519_share {
						return fail_session(session, .Invalid_Key_Share)
					}
					copy(client_pub_key[:], ext_data[kp:kp + X25519_KEY_SIZE])
					has_x25519_share = true
				}
				kp += el
			}
		}
	}

	if !has_tls13 {
		return fail_session(session, .Downgrade_Refused)
	}
	if !has_x25519_group || !has_ed25519_sig || !has_x25519_share {
		return fail_session(session, .Missing_Required_Extension)
	}

	session.negotiated_suite = chosen_suite
	if r := append_transcript(session, raw_msg); r != .None {
		return fail_session(session, r)
	}

	// Compute server ephemeral public key and shared secret.
	server_pub_key: [X25519_KEY_SIZE]u8
	shared_secret: [X25519_KEY_SIZE]u8
	defer erase_bytes(shared_secret[:])
	basepoint := X25519_BASEPOINT
	if r := x25519_scalar_mult(session.config.ephemeral_private_key[:], basepoint[:], &server_pub_key); r != .None {
		return fail_session(session, r)
	}
	if r := x25519_scalar_mult(session.config.ephemeral_private_key[:], client_pub_key[:], &shared_secret); r != .None {
		return fail_session(session, r)
	}

	// 1. ServerHello (plaintext).
	sh_buf: [256]u8
	sh_len := build_server_hello(session, session_id, chosen_suite, server_pub_key[:], sh_buf[:])
	if r := append_transcript(session, sh_buf[:sh_len]); r != .None {
		return fail_session(session, r)
	}
	if r := queue_plaintext_record(session, .Handshake, sh_buf[:sh_len]); r != .None {
		return fail_session(session, r)
	}

	// Derive handshake keys from SHA-256(ClientHello || ServerHello).
	hello_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &hello_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	if r := key_schedule_handshake(&session.schedule, shared_secret[:], hello_hash[:]); r != .None {
		return fail_session(session, r)
	}
	if r := derive_traffic_keys(chosen_suite, session.schedule.server_handshake_traffic[:], &session.send_keys); r != .None {
		return fail_session(session, r)
	}
	if r := derive_traffic_keys(chosen_suite, session.schedule.client_handshake_traffic[:], &session.recv_keys); r != .None {
		return fail_session(session, r)
	}

	// 2. EncryptedExtensions (encrypted).
	ee_buf: [16]u8
	ee_len := build_encrypted_extensions(ee_buf[:])
	if r := append_transcript(session, ee_buf[:ee_len]); r != .None {
		return fail_session(session, r)
	}
	if r := queue_encrypted_record(session, .Handshake, ee_buf[:ee_len]); r != .None {
		return fail_session(session, r)
	}

	// 3. Certificate (Ed25519 SPKI, encrypted).
	ed_pub: [ED25519_KEY_SIZE]u8
	if r := ed25519_derive_public(session.config.server_ed25519_private_key[:], &ed_pub); r != .None {
		return fail_session(session, r)
	}
	cert_buf: [128]u8
	cert_len := build_certificate(ed_pub[:], cert_buf[:])
	if r := append_transcript(session, cert_buf[:cert_len]); r != .None {
		return fail_session(session, r)
	}
	if r := queue_encrypted_record(session, .Handshake, cert_buf[:cert_len]); r != .None {
		return fail_session(session, r)
	}

	// 4. CertificateVerify (Ed25519 signature over transcript through Certificate, encrypted).
	cert_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &cert_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	sig: [ED25519_SIGNATURE_SIZE]u8
	if r := ed25519_sign_transcript(session.config.server_ed25519_private_key[:], cert_hash[:], &sig); r != .None {
		return fail_session(session, r)
	}
	cv_buf: [128]u8
	cv_len := build_certificate_verify(sig[:], cv_buf[:])
	if r := append_transcript(session, cv_buf[:cv_len]); r != .None {
		return fail_session(session, r)
	}
	if r := queue_encrypted_record(session, .Handshake, cv_buf[:cv_len]); r != .None {
		return fail_session(session, r)
	}

	// 5. Server Finished (encrypted).
	cv_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &cv_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	verify_data: [HASH_SIZE]u8
	if r := compute_finished_verify_data(session.schedule.server_handshake_traffic[:], cv_hash[:], &verify_data); r != .None {
		return fail_session(session, r)
	}
	fin_buf: [64]u8
	fin_len := build_finished(verify_data[:], fin_buf[:])
	if r := append_transcript(session, fin_buf[:fin_len]); r != .None {
		return fail_session(session, r)
	}
	if r := queue_encrypted_record(session, .Handshake, fin_buf[:fin_len]); r != .None {
		return fail_session(session, r)
	}

	// Derive application secrets from transcript through server Finished and switch server send keys.
	sf_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &sf_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	if r := key_schedule_application(&session.schedule, sf_hash[:]); r != .None {
		return fail_session(session, r)
	}
	if r := derive_traffic_keys(chosen_suite, session.schedule.server_application_traffic[:], &session.send_keys); r != .None {
		return fail_session(session, r)
	}

	session.state = .Server_Wait_Client_Finished
	return .None
}

@(private = "file")
handle_server_hello :: proc "contextless" (session: ^Tls_Session, raw_msg: []u8, body: []u8) -> Tls_Refusal {
	pos := 0
	if len(body) < 38 {
		return fail_session(session, .Malformed_Message)
	}
	legacy_ver := byte_order.read_u16_big_endian(body, pos)
	pos += 2
	if legacy_ver != TLS_LEGACY_VERSION {
		return fail_session(session, .Downgrade_Refused)
	}
	server_random := body[pos:pos + 32]
	pos += 32

	// Refuse HelloRetryRequest and RFC 8446 TLS 1.2/1.1 downgrade sentinels.
	hrr := HELLO_RETRY_REQUEST_RANDOM
	if constant_time_equal(server_random, hrr[:]) {
		return fail_session(session, .Invalid_Key_Share)
	}
	dg12 := TLS12_DOWNGRADE_SENTINEL
	dg11 := TLS11_DOWNGRADE_SENTINEL
	if constant_time_equal(server_random[24:32], dg12[:]) || constant_time_equal(server_random[24:32], dg11[:]) {
		return fail_session(session, .Downgrade_Refused)
	}

	sid_len := int(body[pos])
	pos += 1
	if sid_len > 32 || pos + sid_len + 3 > len(body) {
		return fail_session(session, .Malformed_Message)
	}
	pos += sid_len

	suite_word := byte_order.read_u16_big_endian(body, pos)
	pos += 2
	suite, suite_ok := cipher_suite_of_word(suite_word)
	if !suite_ok {
		return fail_session(session, .Unsupported_Cipher_Suite)
	}
	if session.config.restrict_to_preferred && suite != session.config.preferred_suite {
		return fail_session(session, .Unsupported_Cipher_Suite)
	}

	if body[pos] != 0 {
		return fail_session(session, .Malformed_Message)
	}
	pos += 1

	// Extensions are mandatory in TLS 1.3 ServerHello; absence means TLS 1.2 downgrade.
	if pos == len(body) {
		return fail_session(session, .Downgrade_Refused)
	}
	if pos + 2 > len(body) {
		return fail_session(session, .Malformed_Message)
	}
	ext_total := int(byte_order.read_u16_big_endian(body, pos))
	pos += 2
	if pos + ext_total != len(body) {
		return fail_session(session, .Malformed_Message)
	}

	has_tls13 := false
	has_key_share := false
	server_pub_key: [X25519_KEY_SIZE]u8
	seen_exts: [16]u16
	seen_count := 0

	end := pos + ext_total
	for pos < end {
		if pos + 4 > end {
			return fail_session(session, .Malformed_Message)
		}
		ext_word := byte_order.read_u16_big_endian(body, pos)
		ext_len := int(byte_order.read_u16_big_endian(body, pos + 2))
		pos += 4
		if pos + ext_len > end {
			return fail_session(session, .Malformed_Message)
		}
		for k := 0; k < seen_count; k += 1 {
			if seen_exts[k] == ext_word {
				return fail_session(session, .Duplicate_Extension)
			}
		}
		if seen_count >= len(seen_exts) {
			return fail_session(session, .Malformed_Message)
		}
		seen_exts[seen_count] = ext_word
		seen_count += 1

		ext_data := body[pos:pos + ext_len]
		pos += ext_len

		ext_type, known := extension_type_of_word(ext_word)
		if !known {
			return fail_session(session, .Malformed_Message)
		}
		switch ext_type {
		case .Supported_Versions:
			if len(ext_data) != 2 || byte_order.read_u16_big_endian(ext_data, 0) != TLS_VERSION_1_3 {
				return fail_session(session, .Downgrade_Refused)
			}
			has_tls13 = true
		case .Key_Share:
			if len(ext_data) != 4 + X25519_KEY_SIZE {
				return fail_session(session, .Invalid_Key_Share)
			}
			grp := byte_order.read_u16_big_endian(ext_data, 0)
			klen := byte_order.read_u16_big_endian(ext_data, 2)
			if grp != NAMED_GROUP_X25519 || klen != X25519_KEY_SIZE {
				return fail_session(session, .Invalid_Key_Share)
			}
			copy(server_pub_key[:], ext_data[4:4 + X25519_KEY_SIZE])
			has_key_share = true
		case .Server_Name, .Supported_Groups, .Signature_Algorithms:
			return fail_session(session, .Malformed_Message)
		}
	}

	if !has_tls13 {
		return fail_session(session, .Downgrade_Refused)
	}
	if !has_key_share {
		return fail_session(session, .Missing_Required_Extension)
	}

	session.negotiated_suite = suite
	if r := append_transcript(session, raw_msg); r != .None {
		return fail_session(session, r)
	}

	shared_secret: [X25519_KEY_SIZE]u8
	defer erase_bytes(shared_secret[:])
	if r := x25519_scalar_mult(session.config.ephemeral_private_key[:], server_pub_key[:], &shared_secret); r != .None {
		return fail_session(session, r)
	}

	hello_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &hello_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	if r := key_schedule_handshake(&session.schedule, shared_secret[:], hello_hash[:]); r != .None {
		return fail_session(session, r)
	}
	if r := derive_traffic_keys(suite, session.schedule.client_handshake_traffic[:], &session.send_keys); r != .None {
		return fail_session(session, r)
	}
	if r := derive_traffic_keys(suite, session.schedule.server_handshake_traffic[:], &session.recv_keys); r != .None {
		return fail_session(session, r)
	}

	session.state = .Client_Wait_Encrypted_Extensions
	return .None
}

@(private = "file")
handle_encrypted_extensions :: proc "contextless" (session: ^Tls_Session, raw_msg: []u8, body: []u8) -> Tls_Refusal {
	if len(body) < 2 {
		return fail_session(session, .Malformed_Message)
	}
	ext_len := int(byte_order.read_u16_big_endian(body, 0))
	if 2 + ext_len != len(body) {
		return fail_session(session, .Malformed_Message)
	}
	if r := append_transcript(session, raw_msg); r != .None {
		return fail_session(session, r)
	}
	session.state = .Client_Wait_Certificate
	return .None
}

@(private = "file")
handle_certificate :: proc "contextless" (session: ^Tls_Session, raw_msg: []u8, body: []u8) -> Tls_Refusal {
	if len(body) < 4 {
		return fail_session(session, .Invalid_Certificate)
	}
	ctx_len := int(body[0])
	if ctx_len != 0 {
		return fail_session(session, .Invalid_Certificate)
	}
	list_len := int(body[1]) << 16 | int(body[2]) << 8 | int(body[3])
	if 4 + list_len != len(body) || list_len < 5 {
		return fail_session(session, .Invalid_Certificate)
	}
	entry_data_len := int(body[4]) << 16 | int(body[5]) << 8 | int(body[6])
	if entry_data_len != ED25519_SPKI_SIZE || 7 + entry_data_len + 2 > len(body) {
		return fail_session(session, .Invalid_Certificate)
	}
	spki := body[7:7 + ED25519_SPKI_SIZE]
	prefix := ED25519_SPKI_PREFIX
	if !constant_time_equal(spki[:12], prefix[:]) {
		return fail_session(session, .Invalid_Certificate)
	}
	if !constant_time_equal(spki[12:44], session.config.pinned_server_public_key[:]) {
		return fail_session(session, .Invalid_Certificate)
	}
	entry_ext_len := int(byte_order.read_u16_big_endian(body, 7 + entry_data_len))
	if 7 + entry_data_len + 2 + entry_ext_len != len(body) {
		return fail_session(session, .Invalid_Certificate)
	}
	if r := append_transcript(session, raw_msg); r != .None {
		return fail_session(session, r)
	}
	session.state = .Client_Wait_Certificate_Verify
	return .None
}

@(private = "file")
handle_certificate_verify :: proc "contextless" (session: ^Tls_Session, raw_msg: []u8, body: []u8) -> Tls_Refusal {
	if len(body) != 4 + ED25519_SIGNATURE_SIZE {
		return fail_session(session, .Invalid_Certificate_Verify)
	}
	scheme := byte_order.read_u16_big_endian(body, 0)
	sig_len := byte_order.read_u16_big_endian(body, 2)
	if scheme != SIGNATURE_SCHEME_ED25519 || sig_len != ED25519_SIGNATURE_SIZE {
		return fail_session(session, .Invalid_Certificate_Verify)
	}
	// Hash transcript BEFORE CertificateVerify.
	cert_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &cert_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	if r := ed25519_verify_transcript(session.config.pinned_server_public_key[:], cert_hash[:], body[4:4 + ED25519_SIGNATURE_SIZE]); r != .None {
		return fail_session(session, .Invalid_Certificate_Verify)
	}
	if r := append_transcript(session, raw_msg); r != .None {
		return fail_session(session, r)
	}
	session.state = .Client_Wait_Finished
	return .None
}

@(private = "file")
handle_server_finished :: proc "contextless" (session: ^Tls_Session, raw_msg: []u8, body: []u8) -> Tls_Refusal {
	if len(body) != HASH_SIZE {
		return fail_session(session, .Invalid_Finished)
	}
	// Verify server Finished against transcript BEFORE server Finished.
	cv_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &cv_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	expected: [HASH_SIZE]u8
	if r := compute_finished_verify_data(session.schedule.server_handshake_traffic[:], cv_hash[:], &expected); r != .None {
		return fail_session(session, r)
	}
	if !constant_time_equal(body, expected[:]) {
		return fail_session(session, .Invalid_Finished)
	}

	if r := append_transcript(session, raw_msg); r != .None {
		return fail_session(session, r)
	}

	// Derive application secrets from transcript through server Finished.
	sf_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &sf_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	if r := key_schedule_application(&session.schedule, sf_hash[:]); r != .None {
		return fail_session(session, r)
	}

	// Build and send client Finished encrypted with client_handshake_traffic keys.
	client_verify: [HASH_SIZE]u8
	if r := compute_finished_verify_data(session.schedule.client_handshake_traffic[:], sf_hash[:], &client_verify); r != .None {
		return fail_session(session, r)
	}
	fin_buf: [64]u8
	fin_len := build_finished(client_verify[:], fin_buf[:])
	if r := queue_encrypted_record(session, .Handshake, fin_buf[:fin_len]); r != .None {
		return fail_session(session, r)
	}
	if r := append_transcript(session, fin_buf[:fin_len]); r != .None {
		return fail_session(session, r)
	}

	// Switch both client send and receive keys to application traffic keys.
	if r := derive_traffic_keys(session.negotiated_suite, session.schedule.client_application_traffic[:], &session.send_keys); r != .None {
		return fail_session(session, r)
	}
	if r := derive_traffic_keys(session.negotiated_suite, session.schedule.server_application_traffic[:], &session.recv_keys); r != .None {
		return fail_session(session, r)
	}

	session.state = .Connected
	return .None
}

@(private = "file")
handle_client_finished :: proc "contextless" (session: ^Tls_Session, raw_msg: []u8, body: []u8) -> Tls_Refusal {
	if len(body) != HASH_SIZE {
		return fail_session(session, .Invalid_Finished)
	}
	// Verify client Finished against transcript through server Finished.
	sf_hash: [HASH_SIZE]u8
	if !sha256_hash(session.transcript[:session.transcript_len], &sf_hash) {
		return fail_session(session, .Crypto_Failed)
	}
	expected: [HASH_SIZE]u8
	if r := compute_finished_verify_data(session.schedule.client_handshake_traffic[:], sf_hash[:], &expected); r != .None {
		return fail_session(session, r)
	}
	if !constant_time_equal(body, expected[:]) {
		return fail_session(session, .Invalid_Finished)
	}

	if r := append_transcript(session, raw_msg); r != .None {
		return fail_session(session, r)
	}
	if r := derive_traffic_keys(session.negotiated_suite, session.schedule.client_application_traffic[:], &session.recv_keys); r != .None {
		return fail_session(session, r)
	}

	session.state = .Connected
	return .None
}
