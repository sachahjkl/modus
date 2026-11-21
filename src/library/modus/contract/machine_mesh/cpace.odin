// CPace balanced PAKE over Ristretto255 (IRTF draft-irtf-cfrg-cpace,
// ciphersuite CPaceRistretto255; src/md/features/several_machines.md,
// "Pairing, and no discovery").
//
// Two machines that share a short one-time pairing code (PRS) and a channel
// identifier / TLS exporter binding (CI, sid, ADa, ADb) derive a common
// generator G in Ristretto255, exchange one 32-byte element each (Ya, Yb),
// compute the intermediate session key (ISK), and verify explicit mutual key
// confirmation tags. A wrong pairing code, mismatched channel identifier,
// mismatched associated data, or invalid/identity public point is strictly
// refused before either side accepts.
package machine_mesh

import "modus:contract/enum_word"

// Ciphersuite domain separation identifiers per IRTF draft-irtf-cfrg-cpace.
CPACE_DSI :: "CPaceRistretto255"
CPACE_ISK_DSI :: "CPaceRistretto255_ISK"
CPACE_CONFIRM_INITIATOR_DSI :: "CPaceRistretto255_Confirm_I"
CPACE_CONFIRM_RESPONDER_DSI :: "CPaceRistretto255_Confirm_R"
CPACE_SESSION_KEY_DSI :: "CPaceRistretto255_SessionKey"

// Fixed byte sizes for CPace messages, keys, and confirmation tags.
CPACE_PUBLIC_ELEMENT_SIZE :: RISTRETTO255_ELEMENT_SIZE
CPACE_SCALAR_SIZE :: RISTRETTO255_SCALAR_SIZE
CPACE_ISK_SIZE :: SHA512_DIGEST_SIZE
CPACE_CONFIRM_TAG_SIZE :: 32
CPACE_SESSION_KEY_SIZE :: 32

// Upper bounds on caller-supplied variable-length CPace inputs so all hashing
// stays strictly bounded without dynamic allocation.
CPACE_MAX_PRS_BYTES :: 128
CPACE_MAX_CHANNEL_BYTES :: 256
CPACE_MAX_SID_BYTES :: 128
CPACE_MAX_AD_BYTES :: 256

// Closed party role in the CPace initiator-responder transcript order.
Cpace_Role :: enum u8 {
	Initiator = 1,
	Responder = 2,
}

// Closed lifecycle phase of a CPace_Session.
Cpace_Phase :: enum u8 {
	Uninitialized = 0,
	Started       = 1,
	Derived       = 2,
	Confirmed     = 3,
	Failed        = 4,
}

// Closed outcome returned by CPace procedures.
Cpace_Status :: enum u8 {
	Ok                          = 1,
	Refused_Nil_Input           = 2,
	Refused_Bad_Role            = 3,
	Refused_Bad_Phase           = 4,
	Refused_Empty_Pairing_Code  = 5,
	Refused_Input_Too_Long      = 6,
	Refused_Zero_Scalar         = 7,
	Refused_Invalid_Peer_Point  = 8,
	Refused_Identity_Point      = 9,
	Refused_Confirmation_Failed = 10,
}

// Ephemeral state of one CPaceRistretto255 pairing exchange.
// Callers must erase sessions via cpace_clear after completion or failure.
Cpace_Session :: struct {
	role:                      Cpace_Role,
	phase:                     Cpace_Phase,
	sid_length:                u16,
	sid:                       [CPACE_MAX_SID_BYTES]u8,
	own_ad_length:             u16,
	own_ad:                    [CPACE_MAX_AD_BYTES]u8,
	secret_scalar:             [CPACE_SCALAR_SIZE]u8,
	own_public_element:        [CPACE_PUBLIC_ELEMENT_SIZE]u8,
	peer_public_element:       [CPACE_PUBLIC_ELEMENT_SIZE]u8,
	intermediate_session_key:  [CPACE_ISK_SIZE]u8,
	own_confirmation_tag:      [CPACE_CONFIRM_TAG_SIZE]u8,
	expected_peer_confirm_tag: [CPACE_CONFIRM_TAG_SIZE]u8,
	session_key:               [CPACE_SESSION_KEY_SIZE]u8,
}

// sha512_update_uleb128 feeds the unsigned LEB128 encoding of value into state.
@(private = "file")
sha512_update_uleb128 :: proc "contextless" (state: ^Sha512_State, value: int) {
	remaining := u64(value)
	encoded: [10]u8
	count := 0
	for {
		chunk := u8(remaining & 0x7F)
		remaining >>= 7
		if remaining != 0 {
			chunk |= 0x80
		}
		encoded[count] = chunk
		count += 1
		if remaining == 0 {
			break
		}
	}
	sha512_update(state, encoded[:count])
}

// uleb128_encoded_size returns the byte length of unsigned LEB128(value).
@(private = "file")
uleb128_encoded_size :: proc "contextless" (value: int) -> int {
	remaining := u64(value)
	count := 0
	for {
		remaining >>= 7
		count += 1
		if remaining == 0 {
			break
		}
	}
	return count
}

// sha512_update_lv feeds prepend_len(data) = ULEB128(len(data)) || data.
@(private = "file")
sha512_update_lv :: proc "contextless" (state: ^Sha512_State, data: []u8) {
	sha512_update_uleb128(state, len(data))
	if len(data) > 0 {
		sha512_update(state, data)
	}
}

// sha512_update_lv_string feeds prepend_len(text).
@(private = "file")
sha512_update_lv_string :: proc "contextless" (state: ^Sha512_State, text: string) {
	sha512_update_lv(state, transmute([]u8)text)
}

// cpace_role_of_word is the single border converting a transport word into a
// Cpace_Role member.
cpace_role_of_word :: proc "contextless" (word: u64) -> (role: Cpace_Role, ok: bool) {
	return enum_word.member_of_word(Cpace_Role, word)
}

// cpace_clear wipes all ephemeral secrets and derived keys from session.
cpace_clear :: proc "contextless" (session: ^Cpace_Session) {
	if session == nil {
		return
	}
	clear_bytes_explicitly(([^]u8)(session)[:size_of(Cpace_Session)])
}

// cpace_calculate_generator implements calculate_generator(PRS, CI, sid) from
// IRTF draft-irtf-cfrg-cpace (Section 8.1 and Appendix A.2) for
// CPaceRistretto255:
//
//   len_zpad = max(0, SHA512_BLOCK_SIZE - 1 - len(lv(PRS)) - len(lv(DSI)))
//   gen_str  = lv_cat(DSI, PRS, zero_bytes(len_zpad), CI, sid)
//   gen_hash = SHA-512(gen_str)
//   G        = ristretto255_from_uniform_bytes(gen_hash)
cpace_calculate_generator :: proc "contextless" (
	pairing_secret: []u8,
	channel_identifier: []u8,
	session_identifier: []u8,
) -> (generator: Ristretto_Point, status: Cpace_Status) {
	if len(pairing_secret) == 0 {
		return ristretto255_identity(), .Refused_Empty_Pairing_Code
	}
	if len(pairing_secret) > CPACE_MAX_PRS_BYTES ||
		len(channel_identifier) > CPACE_MAX_CHANNEL_BYTES ||
		len(session_identifier) > CPACE_MAX_SID_BYTES {
		return ristretto255_identity(), .Refused_Input_Too_Long
	}

	dsi_lv_len := uleb128_encoded_size(len(CPACE_DSI)) + len(CPACE_DSI)
	prs_lv_len := uleb128_encoded_size(len(pairing_secret)) + len(pairing_secret)
	zpad_len := SHA512_BLOCK_SIZE - 1 - prs_lv_len - dsi_lv_len
	if zpad_len < 0 {
		zpad_len = 0
	}

	hash_state: Sha512_State
	sha512_init(&hash_state)
	sha512_update_lv_string(&hash_state, CPACE_DSI)
	sha512_update_lv(&hash_state, pairing_secret)
	zeros: [SHA512_BLOCK_SIZE]u8
	sha512_update_lv(&hash_state, zeros[:zpad_len])
	sha512_update_lv(&hash_state, channel_identifier)
	sha512_update_lv(&hash_state, session_identifier)
	gen_hash := sha512_final(&hash_state)
	defer clear_bytes_explicitly(gen_hash[:])

	generator = ristretto255_from_uniform_bytes(gen_hash)
	if ristretto255_is_identity(generator) {
		return ristretto255_identity(), .Refused_Identity_Point
	}
	return generator, .Ok
}

// cpace_start begins a CPaceRistretto255 exchange for role (Initiator or
// Responder), computing the shared generator from pairing_secret,
// channel_identifier, and session_identifier, multiplying by the caller's
// ephemeral scalar, and returning the 32-byte public element to send to peer.
cpace_start :: proc "contextless" (
	session: ^Cpace_Session,
	role: Cpace_Role,
	pairing_secret: []u8,
	channel_identifier: []u8,
	session_identifier: []u8,
	own_associated_data: []u8,
	ephemeral_scalar: [CPACE_SCALAR_SIZE]u8,
) -> (public_element: [CPACE_PUBLIC_ELEMENT_SIZE]u8, status: Cpace_Status) {
	if session == nil {
		return {}, .Refused_Nil_Input
	}
	checked_role, role_ok := cpace_role_of_word(u64(role))
	if !role_ok {
		return {}, .Refused_Bad_Role
	}
	if len(own_associated_data) > CPACE_MAX_AD_BYTES {
		return {}, .Refused_Input_Too_Long
	}
	reduced_scalar := ristretto255_scalar_reduce_32(ephemeral_scalar)
	defer clear_bytes_explicitly(reduced_scalar[:])
	if bytes_all_zero(reduced_scalar[:]) {
		return {}, .Refused_Zero_Scalar
	}

	generator, gen_status := cpace_calculate_generator(pairing_secret, channel_identifier, session_identifier)
	defer ristretto255_point_clear(&generator)
	if gen_status != .Ok {
		return {}, gen_status
	}

	own_point := ristretto255_scalar_mul(reduced_scalar, generator)
	defer ristretto255_point_clear(&own_point)
	if ristretto255_is_identity(own_point) {
		return {}, .Refused_Identity_Point
	}
	public_element = ristretto255_encode(own_point)

	cpace_clear(session)
	session.role = checked_role
	session.phase = .Started
	session.sid_length = u16(len(session_identifier))
	if len(session_identifier) > 0 {
		copy(session.sid[:len(session_identifier)], session_identifier)
	}
	session.own_ad_length = u16(len(own_associated_data))
	if len(own_associated_data) > 0 {
		copy(session.own_ad[:len(own_associated_data)], own_associated_data)
	}
	session.secret_scalar = reduced_scalar
	session.own_public_element = public_element
	return public_element, .Ok
}

// derive_cpace_subkey hashes domain || sid || isk || ordered_transcript with
// SHA-512 and returns the first 32 bytes.
@(private = "file")
derive_cpace_subkey :: proc "contextless" (
	domain: string,
	sid: []u8,
	isk: ^[CPACE_ISK_SIZE]u8,
	ya: ^[CPACE_PUBLIC_ELEMENT_SIZE]u8,
	ada: []u8,
	yb: ^[CPACE_PUBLIC_ELEMENT_SIZE]u8,
	adb: []u8,
) -> (output: [32]u8) {
	hash_state: Sha512_State
	sha512_init(&hash_state)
	sha512_update_lv_string(&hash_state, domain)
	sha512_update_lv(&hash_state, sid)
	sha512_update_lv(&hash_state, isk[:])
	sha512_update_lv(&hash_state, ya[:])
	sha512_update_lv(&hash_state, ada)
	sha512_update_lv(&hash_state, yb[:])
	sha512_update_lv(&hash_state, adb)
	digest := sha512_final(&hash_state)
	copy(output[:], digest[:32])
	clear_bytes_explicitly(digest[:])
	return output
}

// cpace_finish processes peer_public_element and peer_associated_data, refuses
// any invalid encoding or identity element, derives ISK and mutual key
// confirmation tags, and erases the ephemeral secret scalar.
//
// Callers send own_confirmation_tag to the peer and verify the peer's tag via
// cpace_verify_peer_confirmation before trusting session_key.
cpace_finish :: proc "contextless" (
	session: ^Cpace_Session,
	peer_public_element: [CPACE_PUBLIC_ELEMENT_SIZE]u8,
	peer_associated_data: []u8,
) -> (own_confirmation_tag: [CPACE_CONFIRM_TAG_SIZE]u8, status: Cpace_Status) {
	if session == nil {
		return {}, .Refused_Nil_Input
	}
	if session.phase != .Started {
		return {}, .Refused_Bad_Phase
	}
	if len(peer_associated_data) > CPACE_MAX_AD_BYTES {
		session.phase = .Failed
		clear_bytes_explicitly(session.secret_scalar[:])
		return {}, .Refused_Input_Too_Long
	}

	peer_copy := peer_public_element
	if bytes_all_zero(peer_copy[:]) {
		session.phase = .Failed
		clear_bytes_explicitly(session.secret_scalar[:])
		return {}, .Refused_Identity_Point
	}

	peer_point, decode_ok := ristretto255_decode(peer_copy)
	defer ristretto255_point_clear(&peer_point)
	if !decode_ok {
		session.phase = .Failed
		clear_bytes_explicitly(session.secret_scalar[:])
		return {}, .Refused_Invalid_Peer_Point
	}
	if ristretto255_is_identity(peer_point) {
		session.phase = .Failed
		clear_bytes_explicitly(session.secret_scalar[:])
		return {}, .Refused_Identity_Point
	}

	shared_point := ristretto255_scalar_mul(session.secret_scalar, peer_point)
	defer ristretto255_point_clear(&shared_point)
	// Ephemeral scalar is never needed again once K is derived.
	clear_bytes_explicitly(session.secret_scalar[:])

	if ristretto255_is_identity(shared_point) {
		session.phase = .Failed
		return {}, .Refused_Identity_Point
	}

	shared_bytes := ristretto255_encode(shared_point)
	defer clear_bytes_explicitly(shared_bytes[:])

	sid := session.sid[:session.sid_length]
	own_ad := session.own_ad[:session.own_ad_length]

	ya: [CPACE_PUBLIC_ELEMENT_SIZE]u8
	yb: [CPACE_PUBLIC_ELEMENT_SIZE]u8
	ada: []u8
	adb: []u8
	switch session.role {
	case .Initiator:
		ya = session.own_public_element
		ada = own_ad
		yb = peer_copy
		adb = peer_associated_data
	case .Responder:
		ya = peer_copy
		ada = peer_associated_data
		yb = session.own_public_element
		adb = own_ad
	}

	// ISK = SHA-512(lv_cat(CPACE_ISK_DSI, sid, K, Ya, ADa, Yb, ADb)).
	// Ordered transcript places Initiator's message and AD before Responder's.
	hash_state: Sha512_State
	sha512_init(&hash_state)
	sha512_update_lv_string(&hash_state, CPACE_ISK_DSI)
	sha512_update_lv(&hash_state, sid)
	sha512_update_lv(&hash_state, shared_bytes[:])
	sha512_update_lv(&hash_state, ya[:])
	sha512_update_lv(&hash_state, ada)
	sha512_update_lv(&hash_state, yb[:])
	sha512_update_lv(&hash_state, adb)
	isk := sha512_final(&hash_state)
	defer clear_bytes_explicitly(isk[:])

	initiator_tag := derive_cpace_subkey(CPACE_CONFIRM_INITIATOR_DSI, sid, &isk, &ya, ada, &yb, adb)
	defer clear_bytes_explicitly(initiator_tag[:])
	responder_tag := derive_cpace_subkey(CPACE_CONFIRM_RESPONDER_DSI, sid, &isk, &ya, ada, &yb, adb)
	defer clear_bytes_explicitly(responder_tag[:])
	derived_session_key := derive_cpace_subkey(CPACE_SESSION_KEY_DSI, sid, &isk, &ya, ada, &yb, adb)
	defer clear_bytes_explicitly(derived_session_key[:])

	session.peer_public_element = peer_copy
	session.intermediate_session_key = isk
	session.session_key = derived_session_key
	switch session.role {
	case .Initiator:
		session.own_confirmation_tag = initiator_tag
		session.expected_peer_confirm_tag = responder_tag
	case .Responder:
		session.own_confirmation_tag = responder_tag
		session.expected_peer_confirm_tag = initiator_tag
	}
	session.phase = .Derived
	return session.own_confirmation_tag, .Ok
}

// cpace_verify_peer_confirmation checks the peer's confirmation tag in constant
// time. On failure, the session transitions to Failed and all derived keys
// (ISK, session_key, confirmation tags) are erased immediately so one wrong
// code permanently spends the pairing session.
cpace_verify_peer_confirmation :: proc "contextless" (
	session: ^Cpace_Session,
	peer_confirmation_tag: [CPACE_CONFIRM_TAG_SIZE]u8,
) -> (session_key: [CPACE_SESSION_KEY_SIZE]u8, status: Cpace_Status) {
	if session == nil {
		return {}, .Refused_Nil_Input
	}
	if session.phase != .Derived {
		return {}, .Refused_Bad_Phase
	}
	if !keys_equal_constant_time(session.expected_peer_confirm_tag, peer_confirmation_tag) {
		clear_bytes_explicitly(session.intermediate_session_key[:])
		clear_bytes_explicitly(session.own_confirmation_tag[:])
		clear_bytes_explicitly(session.expected_peer_confirm_tag[:])
		clear_bytes_explicitly(session.session_key[:])
		session.phase = .Failed
		return {}, .Refused_Confirmation_Failed
	}
	session.phase = .Confirmed
	return session.session_key, .Ok
}
