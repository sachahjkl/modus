#+build !freestanding
#+build !modus
package machine_mesh

import "base:runtime"
import "core:crypto/ed25519"
import "core:crypto/ristretto255"
import "core:crypto/sha2"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/tree_hash"

// ============================================================================
// Test helpers (Ed25519 signing/verification and deterministic fixture keys)
// ============================================================================

@(private = "file")
make_hash :: proc(seed: u8) -> blake3.Hash {
	input := [4]u8{seed, seed ~ 0x5A, seed + 17, 0xA5}
	return blake3.hash(input[:])
}

@(private = "file")
make_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 11 + 3)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
ed25519_verify_callback :: proc "contextless" (
	public_key: [PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	pub_copy := public_key
	sig_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, pub_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, sig_copy[:])
}

@(private = "file")
make_machine_entry :: proc(
	seed: u8,
	tpm_attested: bool,
	state: Machine_Entry_State,
	added_at_ms: u64,
	revoked_at_ms: u64,
) -> (entry: Machine_Entry, signing_priv: ed25519.Private_Key) {
	_, machine_id := make_keypair(seed)
	signing_key, signing_pub := make_keypair(seed + 1)
	_, transport_pub := make_keypair(seed + 2)
	entry = Machine_Entry {
		machine_id           = machine_id,
		signing_public_key   = signing_pub,
		transport_public_key = transport_pub,
		uses                 = {.Calls, .View},
		tpm_attested         = tpm_attested,
		state                = state,
		added_at_ms          = added_at_ms,
		revoked_at_ms        = revoked_at_ms,
	}
	return entry, signing_key
}

@(private = "file")
sign_machine_list :: proc(list: ^Signed_Machine_List, root_priv: ^ed25519.Private_Key) {
	buf: [MAX_MACHINE_LIST_SIGNING_BYTES]u8
	written, status := machine_list_signing_bytes(list, buf[:])
	assert(status == .Accepted)
	ed25519.sign(root_priv, buf[:written], list.signature[:])
}

@(private = "file")
sign_grant :: proc(grant: ^Signed_Grant, signing_priv: ^ed25519.Private_Key) {
	signing_bytes, status := signed_grant_signing_bytes(grant)
	assert(status == .Accepted)
	ed25519.sign(signing_priv, signing_bytes[:], grant.signature[:])
}

@(private = "file")
sign_revocation_list :: proc(list: ^Revocation_List, signing_priv: ^ed25519.Private_Key) {
	buf := make([]u8, revocation_list_signing_bytes_size(list.revoked_count))
	defer delete(buf)
	written, status := revocation_list_signing_bytes(list, buf)
	assert(status == .Accepted)
	ed25519.sign(signing_priv, buf[:written], list.signature[:])
}

// ============================================================================
// 1. SHA-512 cross-verification against core:crypto/sha2
// ============================================================================

@(test)
sha512_matches_core_crypto_across_boundaries :: proc(t: ^testing.T) {
	lengths := [?]int{0, 1, 3, 63, 64, 111, 112, 113, 127, 128, 129, 255, 256, 384, 513}
	buffer: [513]u8
	for index in 0 ..< len(buffer) {
		buffer[index] = u8((index * 37 + 13) & 0xFF)
	}

	for length in lengths {
		input := buffer[:length]
		got := sha512_sum(input)

		expected: [sha2.DIGEST_SIZE_512]u8
		ctx: sha2.Context_512
		sha2.init_512(&ctx)
		sha2.update(&ctx, input)
		sha2.final(&ctx, expected[:])
		testing.expect_value(t, got, expected)
	}

	// Incremental chunked updates match single-shot SHA-512 and clear state on final.
	stream_input := buffer[:300]
	state: Sha512_State
	sha512_init(&state)
	offset := 0
	step := 1
	for offset < len(stream_input) {
		take := min(step, len(stream_input) - offset)
		sha512_update(&state, stream_input[offset:offset + take])
		offset += take
		step = (step * 5 + 3) % 41 + 1
	}
	streamed := sha512_final(&state)
	testing.expect_value(t, streamed, sha512_sum(stream_input))
	testing.expect(t, bytes_all_zero(([^]u8)(&state)[:size_of(Sha512_State)]))
}

// ============================================================================
// 2. Ristretto255 RFC 9496 cross-verification and non-canonical refusals
// ============================================================================

@(test)
ristretto255_matches_core_crypto_and_refuses_non_canonical :: proc(t: ^testing.T) {
	// Cross-verify from_uniform_bytes + encode + decode + scalar_mul against core:crypto/ristretto255.
	for trial in 0 ..< 16 {
		uniform: [64]u8
		switch trial {
		case 0:
			// All zeros.
		case 1:
			for index in 0 ..< 64 {
				uniform[index] = 0xFF
			}
		case:
			seed := [2]u8{u8(trial), u8(trial * 29 + 7)}
			uniform = sha512_sum(seed[:])
		}

		ours := ristretto255_from_uniform_bytes(uniform)
		our_bytes := ristretto255_encode(ours)

		ref_ge: ristretto255.Group_Element
		ristretto255.ge_set_wide_bytes(&ref_ge, uniform[:])
		ref_bytes: [32]u8
		ristretto255.ge_bytes(&ref_ge, ref_bytes[:])
		testing.expect_value(t, our_bytes, ref_bytes)

		// Decode round-trip reproduces the exact point and encoding.
		decoded, dec_ok := ristretto255_decode(our_bytes)
		testing.expect(t, dec_ok)
		testing.expect(t, ristretto255_equal(decoded, ours))
		testing.expect_value(t, ristretto255_encode(decoded), our_bytes)

		// Scalar multiplication matches core:crypto/ristretto255 across wide scalars.
		wide_scalar := sha512_sum(our_bytes[:])
		our_scalar := ristretto255_scalar_reduce_64(wide_scalar)

		ref_sc: ristretto255.Scalar
		ristretto255.sc_set_bytes_wide(&ref_sc, wide_scalar[:])
		ref_scalar_bytes: [32]u8
		ristretto255.sc_bytes(&ref_sc, ref_scalar_bytes[:])
		testing.expect_value(t, our_scalar, ref_scalar_bytes)

		our_prod := ristretto255_scalar_mul(our_scalar, decoded)
		our_prod_bytes := ristretto255_encode(our_prod)

		ref_prod: ristretto255.Group_Element
		ristretto255.ge_scalarmult(&ref_prod, &ref_ge, &ref_sc)
		ref_prod_bytes: [32]u8
		ristretto255.ge_bytes(&ref_prod, ref_prod_bytes[:])
		testing.expect_value(t, our_prod_bytes, ref_prod_bytes)
	}

	// Scalar reduction edge values: 0, 1, l - 1, l (reduces to 0), l + 1 (reduces to 1), max u256.
	order_l := [32]u8 {
		0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
		0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
	}
	testing.expect(t, ristretto255_scalar_is_zero([32]u8{}))
	testing.expect(t, ristretto255_scalar_is_zero(order_l))
	l_plus_one := order_l
	l_plus_one[0] += 1
	reduced_one := ristretto255_scalar_reduce_32(l_plus_one)
	expected_one := [32]u8{0 = 1}
	testing.expect_value(t, reduced_one, expected_one)

	// Invalid / non-canonical encodings covering every RFC 9496 decode refusal branch:
	// >= p, high bit set, odd s, non-square, negative t (s=2), and y == 0 (s=p-1).
	invalid_encodings := [?][32]u8 {
		// Non-canonical field element (p = 2^255 - 19).
		{0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
		// High bit set (non-canonical).
		{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80},
		// Negative s (LSB == 1).
		{0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
		// Non-square in decode (s = 8).
		{0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
		// Negative t (s = 2).
		{0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
		// y == 0 (s = p - 1 = 2^255 - 20, even and canonical).
		{0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
	}
	for invalid in invalid_encodings {
		invalid_copy := invalid
		_, our_ok := ristretto255_decode(invalid_copy)
		ref_ge: ristretto255.Group_Element
		ref_ok := ristretto255.ge_set_bytes(&ref_ge, invalid_copy[:])
		testing.expect_value(t, our_ok, ref_ok)
		testing.expect(t, !our_ok)
	}

	// Cross-check decode acceptance/refusal across all 256 values of byte 0.
	for candidate_byte in 0 ..< 256 {
		probe: [32]u8
		probe[0] = u8(candidate_byte)
		our_point, our_ok := ristretto255_decode(probe)
		ref_ge: ristretto255.Group_Element
		ref_ok := ristretto255.ge_set_bytes(&ref_ge, probe[:])
		testing.expect_value(t, our_ok, ref_ok)
		if our_ok {
			testing.expect_value(t, ristretto255_encode(our_point), probe)
		}
	}
}

// ============================================================================
// 3. CPaceRistretto255 PAKE tests
// ============================================================================

@(test)
cpace_matching_pairing_code_derives_identical_isk_and_confirms :: proc(t: ^testing.T) {
	prs := transmute([]u8)string("A7K9-M2P4-Q8R3")
	channel_id := transmute([]u8)string("tls-exporter-channel-binding-v1")
	sid := transmute([]u8)string("pairing-session-01")
	ad_initiator := transmute([]u8)string("machine-a-id-key")
	ad_responder := transmute([]u8)string("machine-b-id-key")

	scalar_a := make_hash(0x11)
	scalar_b := make_hash(0x22)

	initiator: Cpace_Session
	responder: Cpace_Session

	ya, st_a := cpace_start(&initiator, .Initiator, prs, channel_id, sid, ad_initiator, scalar_a)
	testing.expect_value(t, st_a, Cpace_Status.Ok)
	testing.expect(t, !bytes_all_zero(ya[:]))

	yb, st_b := cpace_start(&responder, .Responder, prs, channel_id, sid, ad_responder, scalar_b)
	testing.expect_value(t, st_b, Cpace_Status.Ok)
	testing.expect(t, !bytes_all_zero(yb[:]))
	testing.expect(t, ya != yb)

	tag_a, fin_a := cpace_finish(&initiator, yb, ad_responder)
	testing.expect_value(t, fin_a, Cpace_Status.Ok)
	// Ephemeral scalar must be erased immediately after cpace_finish.
	testing.expect(t, bytes_all_zero(initiator.secret_scalar[:]))

	tag_b, fin_b := cpace_finish(&responder, ya, ad_initiator)
	testing.expect_value(t, fin_b, Cpace_Status.Ok)
	testing.expect(t, bytes_all_zero(responder.secret_scalar[:]))

	// Both sides derive the exact same 64-byte ISK and distinct directional confirmation tags.
	testing.expect_value(t, initiator.intermediate_session_key, responder.intermediate_session_key)
	testing.expect(t, !bytes_all_zero(initiator.intermediate_session_key[:]))
	testing.expect(t, tag_a != tag_b)

	// Mutual confirmation succeeds and yields identical 32-byte session keys.
	key_a, conf_a := cpace_verify_peer_confirmation(&initiator, tag_b)
	testing.expect_value(t, conf_a, Cpace_Status.Ok)
	testing.expect_value(t, initiator.phase, Cpace_Phase.Confirmed)

	key_b, conf_b := cpace_verify_peer_confirmation(&responder, tag_a)
	testing.expect_value(t, conf_b, Cpace_Status.Ok)
	testing.expect_value(t, responder.phase, Cpace_Phase.Confirmed)
	testing.expect_value(t, key_a, key_b)
	testing.expect(t, !bytes_all_zero(key_a[:]))

	cpace_clear(&initiator)
	cpace_clear(&responder)
	testing.expect(t, bytes_all_zero(initiator.session_key[:]))
	testing.expect(t, bytes_all_zero(responder.intermediate_session_key[:]))
}

@(test)
cpace_one_character_wrong_code_fails_confirmation_and_erases_keys :: proc(t: ^testing.T) {
	prs_a := transmute([]u8)string("A7K9-M2P4-Q8R3")
	prs_b := transmute([]u8)string("A7K9-M2P4-Q8R4") // One character changed.
	channel_id := transmute([]u8)string("tls-exporter-channel-binding-v1")
	sid := transmute([]u8)string("pairing-session-02")

	initiator, responder: Cpace_Session
	ya, st_a := cpace_start(&initiator, .Initiator, prs_a, channel_id, sid, nil, make_hash(0x31))
	yb, st_b := cpace_start(&responder, .Responder, prs_b, channel_id, sid, nil, make_hash(0x32))
	testing.expect_value(t, st_a, Cpace_Status.Ok)
	testing.expect_value(t, st_b, Cpace_Status.Ok)

	tag_a, fin_a := cpace_finish(&initiator, yb, nil)
	tag_b, fin_b := cpace_finish(&responder, ya, nil)
	testing.expect_value(t, fin_a, Cpace_Status.Ok)
	testing.expect_value(t, fin_b, Cpace_Status.Ok)
	testing.expect(t, initiator.intermediate_session_key != responder.intermediate_session_key)

	key_a, conf_a := cpace_verify_peer_confirmation(&initiator, tag_b)
	testing.expect_value(t, conf_a, Cpace_Status.Refused_Confirmation_Failed)
	testing.expect(t, bytes_all_zero(key_a[:]))
	testing.expect_value(t, initiator.phase, Cpace_Phase.Failed)
	testing.expect(t, bytes_all_zero(initiator.intermediate_session_key[:]))
	testing.expect(t, bytes_all_zero(initiator.session_key[:]))

	key_b, conf_b := cpace_verify_peer_confirmation(&responder, tag_a)
	testing.expect_value(t, conf_b, Cpace_Status.Refused_Confirmation_Failed)
	testing.expect(t, bytes_all_zero(key_b[:]))
	testing.expect_value(t, responder.phase, Cpace_Phase.Failed)

	// One wrong code spends the session: re-attempting confirmation is refused.
	_, retry_status := cpace_verify_peer_confirmation(&initiator, tag_b)
	testing.expect_value(t, retry_status, Cpace_Status.Refused_Bad_Phase)
}

@(test)
cpace_mismatched_channel_sid_ad_or_roles_fails_confirmation :: proc(t: ^testing.T) {
	prs := transmute([]u8)string("B9X2-L4N7")

	// 1. Mismatched channel identifier.
	{
		a, b: Cpace_Session
		ya, _ := cpace_start(&a, .Initiator, prs, transmute([]u8)string("channel-A"), transmute([]u8)string("sid"), nil, make_hash(1))
		yb, _ := cpace_start(&b, .Responder, prs, transmute([]u8)string("channel-B"), transmute([]u8)string("sid"), nil, make_hash(2))
		tag_a, _ := cpace_finish(&a, yb, nil)
		tag_b, _ := cpace_finish(&b, ya, nil)
		_, st_a := cpace_verify_peer_confirmation(&a, tag_b)
		_, st_b := cpace_verify_peer_confirmation(&b, tag_a)
		testing.expect_value(t, st_a, Cpace_Status.Refused_Confirmation_Failed)
		testing.expect_value(t, st_b, Cpace_Status.Refused_Confirmation_Failed)
	}

	// 2. Mismatched session identifier.
	{
		a, b: Cpace_Session
		ya, _ := cpace_start(&a, .Initiator, prs, transmute([]u8)string("ch"), transmute([]u8)string("sid-1"), nil, make_hash(3))
		yb, _ := cpace_start(&b, .Responder, prs, transmute([]u8)string("ch"), transmute([]u8)string("sid-2"), nil, make_hash(4))
		tag_a, _ := cpace_finish(&a, yb, nil)
		tag_b, _ := cpace_finish(&b, ya, nil)
		_, st_a := cpace_verify_peer_confirmation(&a, tag_b)
		testing.expect_value(t, st_a, Cpace_Status.Refused_Confirmation_Failed)
		_, st_b := cpace_verify_peer_confirmation(&b, tag_a)
		testing.expect_value(t, st_b, Cpace_Status.Refused_Confirmation_Failed)
	}

	// 3. Mismatched associated data.
	{
		a, b: Cpace_Session
		ya, _ := cpace_start(&a, .Initiator, prs, transmute([]u8)string("ch"), transmute([]u8)string("sid"), transmute([]u8)string("ad-a"), make_hash(5))
		yb, _ := cpace_start(&b, .Responder, prs, transmute([]u8)string("ch"), transmute([]u8)string("sid"), transmute([]u8)string("ad-b"), make_hash(6))
		tag_a, _ := cpace_finish(&a, yb, transmute([]u8)string("ad-b-tampered"))
		tag_b, _ := cpace_finish(&b, ya, transmute([]u8)string("ad-a"))
		_, st_a := cpace_verify_peer_confirmation(&a, tag_b)
		_, st_b := cpace_verify_peer_confirmation(&b, tag_a)
		testing.expect_value(t, st_a, Cpace_Status.Refused_Confirmation_Failed)
		testing.expect_value(t, st_b, Cpace_Status.Refused_Confirmation_Failed)
	}

	// 4. Reflection attack: feeding own confirmation tag back fails because tags are role-separated.
	{
		a, b: Cpace_Session
		ya, _ := cpace_start(&a, .Initiator, prs, transmute([]u8)string("ch"), transmute([]u8)string("sid"), nil, make_hash(7))
		yb, _ := cpace_start(&b, .Responder, prs, transmute([]u8)string("ch"), transmute([]u8)string("sid"), nil, make_hash(8))
		tag_a, _ := cpace_finish(&a, yb, nil)
		_, _ = cpace_finish(&b, ya, nil)
		_, st_reflected := cpace_verify_peer_confirmation(&a, tag_a)
		testing.expect_value(t, st_reflected, Cpace_Status.Refused_Confirmation_Failed)
	}
}

@(test)
cpace_refuses_zero_identity_invalid_points_and_edge_inputs :: proc(t: ^testing.T) {
	session: Cpace_Session
	prs := transmute([]u8)string("CODE-1234")
	valid_scalar := make_hash(0x44)

	// Nil session.
	_, st := cpace_start(nil, .Initiator, prs, nil, nil, nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Refused_Nil_Input)
	_, st = cpace_finish(nil, [32]u8{}, nil)
	testing.expect_value(t, st, Cpace_Status.Refused_Nil_Input)
	_, st = cpace_verify_peer_confirmation(nil, [32]u8{})
	testing.expect_value(t, st, Cpace_Status.Refused_Nil_Input)

	// Invalid role words (0, 3, 255).
	for bad_role in ([]u8{0, 3, 255}) {
		_, role_ok := cpace_role_of_word(u64(bad_role))
		testing.expect(t, !role_ok)
		_, st = cpace_start(&session, Cpace_Role(bad_role), prs, nil, nil, nil, valid_scalar)
		testing.expect_value(t, st, Cpace_Status.Refused_Bad_Role)
	}

	// Empty pairing code.
	_, st = cpace_start(&session, .Initiator, nil, nil, nil, nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Refused_Empty_Pairing_Code)

	// Oversized inputs (one past each bound).
	big_buf: [CPACE_MAX_CHANNEL_BYTES + 1]u8
	_, st = cpace_start(&session, .Initiator, big_buf[:CPACE_MAX_PRS_BYTES + 1], nil, nil, nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Refused_Input_Too_Long)
	_, st = cpace_start(&session, .Initiator, prs, big_buf[:CPACE_MAX_CHANNEL_BYTES + 1], nil, nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Refused_Input_Too_Long)
	_, st = cpace_start(&session, .Initiator, prs, nil, big_buf[:CPACE_MAX_SID_BYTES + 1], nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Refused_Input_Too_Long)
	_, st = cpace_start(&session, .Initiator, prs, nil, nil, big_buf[:CPACE_MAX_AD_BYTES + 1], valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Refused_Input_Too_Long)

	// Zero scalar and scalar == group order l.
	_, st = cpace_start(&session, .Initiator, prs, nil, nil, nil, [32]u8{})
	testing.expect_value(t, st, Cpace_Status.Refused_Zero_Scalar)
	order_l := [32]u8 {
		0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
		0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
	}
	_, st = cpace_start(&session, .Initiator, prs, nil, nil, nil, order_l)
	testing.expect_value(t, st, Cpace_Status.Refused_Zero_Scalar)

	// Out-of-phase calls.
	uninit: Cpace_Session
	_, st = cpace_finish(&uninit, [32]u8{0 = 2}, nil)
	testing.expect_value(t, st, Cpace_Status.Refused_Bad_Phase)
	_, st = cpace_verify_peer_confirmation(&uninit, [32]u8{})
	testing.expect_value(t, st, Cpace_Status.Refused_Bad_Phase)

	// Oversized peer_associated_data in cpace_finish refuses, marks Failed, and wipes secret_scalar.
	_, st = cpace_start(&session, .Initiator, prs, nil, nil, nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Ok)
	_, st = cpace_finish(&session, [32]u8{0 = 4}, big_buf[:CPACE_MAX_AD_BYTES + 1])
	testing.expect_value(t, st, Cpace_Status.Refused_Input_Too_Long)
	testing.expect_value(t, session.phase, Cpace_Phase.Failed)
	testing.expect(t, bytes_all_zero(session.secret_scalar[:]))

	// Zero / identity peer point refused and secret scalar erased.
	_, st = cpace_start(&session, .Initiator, prs, nil, nil, nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Ok)
	_, st = cpace_finish(&session, [32]u8{}, nil)
	testing.expect_value(t, st, Cpace_Status.Refused_Identity_Point)
	testing.expect_value(t, session.phase, Cpace_Phase.Failed)
	testing.expect(t, bytes_all_zero(session.secret_scalar[:]))

	// Non-canonical / invalid peer point refused and secret scalar erased.
	_, st = cpace_start(&session, .Initiator, prs, nil, nil, nil, valid_scalar)
	testing.expect_value(t, st, Cpace_Status.Ok)
	invalid_peer := [32]u8{0 = 1} // Odd LSB is never canonical in Ristretto255.
	_, st = cpace_finish(&session, invalid_peer, nil)
	testing.expect_value(t, st, Cpace_Status.Refused_Invalid_Peer_Point)
	testing.expect_value(t, session.phase, Cpace_Phase.Failed)
	testing.expect(t, bytes_all_zero(session.secret_scalar[:]))
}

@(test)
cpace_generator_hashes_channel_identifier_before_session_identifier :: proc(t: ^testing.T) {
	prs := transmute([]u8)string("PAIR-9876")
	ci := transmute([]u8)string("channel-binding-alpha")
	sid := transmute([]u8)string("session-id-beta")

	gen_ci_then_sid, st_a := cpace_calculate_generator(prs, ci, sid)
	testing.expect_value(t, st_a, Cpace_Status.Ok)

	// Swapping CI and sid when CI != sid must produce a distinct generator.
	gen_swapped, st_b := cpace_calculate_generator(prs, sid, ci)
	testing.expect_value(t, st_b, Cpace_Status.Ok)
	testing.expect(t, !ristretto255_equal(gen_ci_then_sid, gen_swapped))

	// Cross-verify exact IRTF draft-irtf-cfrg-cpace lv_cat(DSI, PRS, Z_pad, CI, sid) layout.
	zpad_len := SHA512_BLOCK_SIZE - 1 - (1 + len(prs)) - (1 + len(CPACE_DSI))
	manual_input: [512]u8
	pos := 0
	manual_input[pos] = u8(len(CPACE_DSI))
	pos += 1
	copy(manual_input[pos:], CPACE_DSI)
	pos += len(CPACE_DSI)
	manual_input[pos] = u8(len(prs))
	pos += 1
	copy(manual_input[pos:], prs)
	pos += len(prs)
	manual_input[pos] = u8(zpad_len)
	pos += 1
	pos += zpad_len
	manual_input[pos] = u8(len(ci))
	pos += 1
	copy(manual_input[pos:], ci)
	pos += len(ci)
	manual_input[pos] = u8(len(sid))
	pos += 1
	copy(manual_input[pos:], sid)
	pos += len(sid)

	expected_hash: [sha2.DIGEST_SIZE_512]u8
	ctx: sha2.Context_512
	sha2.init_512(&ctx)
	sha2.update(&ctx, manual_input[:pos])
	sha2.final(&ctx, expected_hash[:])

	ref_ge: ristretto255.Group_Element
	ristretto255.ge_set_wide_bytes(&ref_ge, expected_hash[:])
	expected_bytes: [32]u8
	ristretto255.ge_bytes(&ref_ge, expected_bytes[:])
	testing.expect_value(t, ristretto255_encode(gen_ci_then_sid), expected_bytes)
}

// ============================================================================
// 4. Per-machine keys, signed machine list, TPM policy, and revocation
// ============================================================================

@(test)
machine_list_valid_sign_update_and_instant_revocation :: proc(t: ^testing.T) {
	root_priv, root_pub := make_keypair(0x10)
	entry_a, _ := make_machine_entry(0x20, true, .Active, 1_000, 0)
	entry_b, _ := make_machine_entry(0x30, true, .Active, 2_000, 0)

	list_v1 := Signed_Machine_List {
		principal_root_public_key = root_pub,
		sequence_number           = 1,
		entry_count               = 2,
	}
	list_v1.entries[0] = entry_a
	list_v1.entries[1] = entry_b
	sign_machine_list(&list_v1, &root_priv)

	state: Signed_Machine_List
	policy := default_join_policy()
	st := machine_list_apply_update(&state, false, &list_v1, policy, ed25519_verify_callback)
	testing.expect_value(t, st, Machine_List_Status.Accepted)

	found_a, ok_a := machine_list_find_active_by_machine_id(&state, entry_a.machine_id)
	testing.expect(t, ok_a)
	testing.expect_value(t, found_a.signing_public_key, entry_a.signing_public_key)
	_, ok_b := machine_list_find_active_by_signing_key(&state, entry_b.signing_public_key)
	testing.expect(t, ok_b)

	// Wire encode/decode round-trip preserves exact fields and signature.
	wire_buf: [MAX_MACHINE_LIST_WIRE_BYTES]u8
	written, enc_st := machine_list_encode(&state, wire_buf[:])
	testing.expect_value(t, enc_st, Machine_List_Status.Accepted)
	decoded, dec_st := machine_list_decode(wire_buf[:written])
	testing.expect_value(t, dec_st, Machine_List_Status.Accepted)
	testing.expect_value(t, machine_list_validate(nil, &decoded, policy, ed25519_verify_callback), Machine_List_Status.Accepted)

	// Machine B is stolen: root key signs seq 2 revoking B without changing principal_root_public_key.
	list_v2 := list_v1
	list_v2.sequence_number = 2
	list_v2.entries[1].state = .Revoked
	list_v2.entries[1].revoked_at_ms = 5_000
	sign_machine_list(&list_v2, &root_priv)

	st = machine_list_apply_update(&state, true, &list_v2, policy, ed25519_verify_callback)
	testing.expect_value(t, st, Machine_List_Status.Accepted)
	testing.expect_value(t, state.principal_root_public_key, root_pub)
	testing.expect_value(t, state.sequence_number, u64(2))

	// Machine B is revoked immediately; Machine A remains active.
	_, b_active_id := machine_list_find_active_by_machine_id(&state, entry_b.machine_id)
	_, b_active_sig := machine_list_find_active_by_signing_key(&state, entry_b.signing_public_key)
	testing.expect(t, !b_active_id)
	testing.expect(t, !b_active_sig)
	_, a_still_active := machine_list_find_active_by_machine_id(&state, entry_a.machine_id)
	testing.expect(t, a_still_active)
}

@(test)
machine_list_refuses_replay_downgrade_duplicates_and_bad_signatures :: proc(t: ^testing.T) {
	root_priv, root_pub := make_keypair(0x40)
	other_priv, other_pub := make_keypair(0x48)
	entry_a, signing_a_priv := make_machine_entry(0x50, true, .Active, 1_000, 0)
	entry_b, _ := make_machine_entry(0x60, true, .Active, 2_000, 0)

	list_v5 := Signed_Machine_List {
		principal_root_public_key = root_pub,
		sequence_number           = 5,
		entry_count               = 1,
	}
	list_v5.entries[0] = entry_a
	sign_machine_list(&list_v5, &root_priv)

	state: Signed_Machine_List
	policy := default_join_policy()
	testing.expect_value(t, machine_list_apply_update(&state, false, &list_v5, policy, ed25519_verify_callback), Machine_List_Status.Accepted)

	// Replay (same seq 5) and downgrade (seq 4) refused; state untouched.
	testing.expect_value(t, machine_list_apply_update(&state, true, &list_v5, policy, ed25519_verify_callback), Machine_List_Status.Refused_Replay_Or_Downgrade)
	list_v4 := list_v5
	list_v4.sequence_number = 4
	sign_machine_list(&list_v4, &root_priv)
	testing.expect_value(t, machine_list_apply_update(&state, true, &list_v4, policy, ed25519_verify_callback), Machine_List_Status.Refused_Replay_Or_Downgrade)
	testing.expect_value(t, state.sequence_number, u64(5))

	// Sequence 0 refused.
	list_v0 := list_v5
	list_v0.sequence_number = 0
	testing.expect_value(t, machine_list_validate(nil, &list_v0, policy, ed25519_verify_callback), Machine_List_Status.Refused_Zero_Sequence_Number)

	// Nil, empty, too many entries, zero root key, root key mismatch.
	testing.expect_value(t, machine_list_validate(nil, nil, policy, ed25519_verify_callback), Machine_List_Status.Refused_Nil_Input)
	empty_list := list_v5
	empty_list.entry_count = 0
	testing.expect_value(t, machine_list_validate(nil, &empty_list, policy, ed25519_verify_callback), Machine_List_Status.Refused_Empty_List)
	too_many := list_v5
	too_many.entry_count = MAX_MACHINE_LIST_ENTRIES + 1
	testing.expect_value(t, machine_list_validate(nil, &too_many, policy, ed25519_verify_callback), Machine_List_Status.Refused_Too_Many_Entries)
	zero_root := list_v5
	zero_root.principal_root_public_key = {}
	testing.expect_value(t, machine_list_validate(nil, &zero_root, policy, ed25519_verify_callback), Machine_List_Status.Refused_Zero_Root_Key)

	other_root_list := list_v5
	other_root_list.principal_root_public_key = other_pub
	other_root_list.sequence_number = 6
	sign_machine_list(&other_root_list, &other_priv)
	testing.expect_value(t, machine_list_apply_update(&state, true, &other_root_list, policy, ed25519_verify_callback), Machine_List_Status.Refused_Root_Key_Mismatch)
	testing.expect_value(t, state.principal_root_public_key, root_pub)

	// Duplicate machine_id, signing_public_key, transport_public_key, and signing_key == root_key.
	dup_id := list_v5
	dup_id.sequence_number = 6
	dup_id.entry_count = 2
	dup_id.entries[1] = entry_b
	dup_id.entries[1].machine_id = entry_a.machine_id
	testing.expect_value(t, machine_list_validate(nil, &dup_id, policy, ed25519_verify_callback), Machine_List_Status.Refused_Duplicate_Machine_Id)

	dup_sig := list_v5
	dup_sig.sequence_number = 6
	dup_sig.entry_count = 2
	dup_sig.entries[1] = entry_b
	dup_sig.entries[1].signing_public_key = entry_a.signing_public_key
	testing.expect_value(t, machine_list_validate(nil, &dup_sig, policy, ed25519_verify_callback), Machine_List_Status.Refused_Duplicate_Signing_Key)

	dup_trans := list_v5
	dup_trans.sequence_number = 6
	dup_trans.entry_count = 2
	dup_trans.entries[1] = entry_b
	dup_trans.entries[1].transport_public_key = entry_a.transport_public_key
	testing.expect_value(t, machine_list_validate(nil, &dup_trans, policy, ed25519_verify_callback), Machine_List_Status.Refused_Duplicate_Transport_Key)

	root_as_machine_id := list_v5
	root_as_machine_id.entries[0].machine_id = root_pub
	testing.expect_value(t, machine_list_validate(nil, &root_as_machine_id, policy, ed25519_verify_callback), Machine_List_Status.Refused_Duplicate_Machine_Id)

	root_as_machine_sig := list_v5
	root_as_machine_sig.entries[0].signing_public_key = root_pub
	testing.expect_value(t, machine_list_validate(nil, &root_as_machine_sig, policy, ed25519_verify_callback), Machine_List_Status.Refused_Duplicate_Signing_Key)

	root_as_machine_transport := list_v5
	root_as_machine_transport.entries[0].transport_public_key = root_pub
	testing.expect_value(t, machine_list_validate(nil, &root_as_machine_transport, policy, ed25519_verify_callback), Machine_List_Status.Refused_Duplicate_Transport_Key)

	// Unknown state, bad uses (empty, Input without View), bad timestamps.
	bad_state := list_v5
	bad_state.entries[0].state = Machine_Entry_State(0)
	testing.expect_value(t, machine_list_validate(nil, &bad_state, policy, ed25519_verify_callback), Machine_List_Status.Refused_Bad_Entry_State)
	bad_uses := list_v5
	bad_uses.entries[0].uses = {}
	testing.expect_value(t, machine_list_validate(nil, &bad_uses, policy, ed25519_verify_callback), Machine_List_Status.Refused_Bad_Uses)
	bad_input_uses := list_v5
	bad_input_uses.entries[0].uses = {.Input}
	testing.expect_value(t, machine_list_validate(nil, &bad_input_uses, policy, ed25519_verify_callback), Machine_List_Status.Refused_Bad_Uses)

	bad_ts_active := list_v5
	bad_ts_active.entries[0].revoked_at_ms = 999
	testing.expect_value(t, machine_list_validate(nil, &bad_ts_active, policy, ed25519_verify_callback), Machine_List_Status.Refused_Bad_Timestamps)
	bad_ts_revoked_zero := list_v5
	bad_ts_revoked_zero.entries[0].state = .Revoked
	bad_ts_revoked_zero.entries[0].revoked_at_ms = 0
	testing.expect_value(t, machine_list_validate(nil, &bad_ts_revoked_zero, policy, ed25519_verify_callback), Machine_List_Status.Refused_Bad_Timestamps)
	bad_ts_revoked_before := list_v5
	bad_ts_revoked_before.entries[0].state = .Revoked
	bad_ts_revoked_before.entries[0].revoked_at_ms = 500
	testing.expect_value(t, machine_list_validate(nil, &bad_ts_revoked_before, policy, ed25519_verify_callback), Machine_List_Status.Refused_Bad_Timestamps)

	// Forged signature signed by per-machine signing key instead of offline root key must fail!
	forged := list_v5
	forged.sequence_number = 6
	sign_machine_list(&forged, &signing_a_priv)
	testing.expect_value(t, machine_list_apply_update(&state, true, &forged, policy, ed25519_verify_callback), Machine_List_Status.Refused_Invalid_Signature)
	testing.expect_value(t, state.sequence_number, u64(5))

	// Nil verify callback and 1-bit flipped signature refused.
	testing.expect_value(t, machine_list_validate(nil, &list_v5, policy, nil), Machine_List_Status.Refused_Invalid_Signature)
	tampered := list_v5
	tampered.signature[0] ~= 0x01
	testing.expect_value(t, machine_list_validate(nil, &tampered, policy, ed25519_verify_callback), Machine_List_Status.Refused_Invalid_Signature)

	// Wire corruption refusals.
	wire_buf: [MAX_MACHINE_LIST_WIRE_BYTES]u8
	written, _ := machine_list_encode(&list_v5, wire_buf[:])
	_, dec_trunc := machine_list_decode(wire_buf[:written - 1])
	testing.expect_value(t, dec_trunc, Machine_List_Status.Refused_Malformed_Wire)
	bad_magic := wire_buf
	bad_magic[0] = 'X'
	_, dec_magic := machine_list_decode(bad_magic[:written])
	testing.expect_value(t, dec_magic, Machine_List_Status.Refused_Malformed_Wire)
	bad_tpm_byte := wire_buf
	bad_tpm_byte[MACHINE_LIST_WIRE_HEADER_SIZE + 104] = 2
	_, dec_tpm := machine_list_decode(bad_tpm_byte[:written])
	testing.expect_value(t, dec_tpm, Machine_List_Status.Refused_Malformed_Wire)
	bad_pad := wire_buf
	bad_pad[MACHINE_LIST_WIRE_HEADER_SIZE + 106] = 1
	_, dec_pad := machine_list_decode(bad_pad[:written])
	testing.expect_value(t, dec_pad, Machine_List_Status.Refused_Malformed_Wire)
}

@(test)
machine_list_tpm_policy_default_refusal_opt_in_warning_and_revocation :: proc(t: ^testing.T) {
	root_priv, root_pub := make_keypair(0x70)
	entry_tpm, _ := make_machine_entry(0x74, true, .Active, 1_000, 0)
	entry_no_tpm, _ := make_machine_entry(0x78, false, .Active, 2_000, 0)

	list_no_tpm := Signed_Machine_List {
		principal_root_public_key = root_pub,
		sequence_number           = 1,
		entry_count               = 2,
	}
	list_no_tpm.entries[0] = entry_tpm
	list_no_tpm.entries[1] = entry_no_tpm
	sign_machine_list(&list_no_tpm, &root_priv)

	// Default policy refuses non-TPM active machine and leaves state unchanged.
	state: Signed_Machine_List
	st_default := machine_list_apply_update(&state, false, &list_no_tpm, default_join_policy(), ed25519_verify_callback)
	testing.expect_value(t, st_default, Machine_List_Status.Refused_Without_Tpm)
	testing.expect_value(t, state.sequence_number, u64(0))

	// Explicit opt-in policy accepts with mandatory warning status.
	opt_in := Join_Policy{allow_without_tpm = true}
	st_opt_in := machine_list_apply_update(&state, false, &list_no_tpm, opt_in, ed25519_verify_callback)
	testing.expect_value(t, st_opt_in, Machine_List_Status.Accepted_Without_Tpm_Warning)
	testing.expect_value(t, state.sequence_number, u64(1))

	// Revoking the non-TPM machine is accepted cleanly even under the strict default policy.
	list_revoked := list_no_tpm
	list_revoked.sequence_number = 2
	list_revoked.entries[1].state = .Revoked
	list_revoked.entries[1].revoked_at_ms = 3_000
	sign_machine_list(&list_revoked, &root_priv)
	st_rev := machine_list_apply_update(&state, true, &list_revoked, default_join_policy(), ed25519_verify_callback)
	testing.expect_value(t, st_rev, Machine_List_Status.Accepted)
	testing.expect_value(t, state.sequence_number, u64(2))
}

// ============================================================================
// 5. Local network address hint (off by default, keyed BLAKE3 tag)
// ============================================================================

@(test)
address_hint_default_off_keyed_tag_and_refusals :: proc(t: ^testing.T) {
	hint_key := make_hash(0x81)
	other_key := make_hash(0x82)
	ipv4_addr := [ADDRESS_HINT_ADDRESS_SIZE]u8{0 = 192, 1 = 168, 2 = 1, 3 = 42}
	nonce := [ADDRESS_HINT_NONCE_SIZE]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

	// Default config is disabled and refuses both build and verify.
	default_cfg := default_address_hint_config()
	testing.expect(t, !default_cfg.enabled)
	_, st_disabled := address_hint_build(default_cfg, hint_key, .IPv4, 4433, ipv4_addr, nonce)
	testing.expect_value(t, st_disabled, Address_Hint_Status.Refused_Disabled)

	// Enabled build + wire round-trip + verify.
	enabled_cfg := Address_Hint_Config{enabled = true}
	dgram, st_build := address_hint_build(enabled_cfg, hint_key, .IPv4, 4433, ipv4_addr, nonce)
	testing.expect_value(t, st_build, Address_Hint_Status.Ok)
	testing.expect_value(t, address_hint_verify(default_cfg, hint_key, &dgram), Address_Hint_Status.Refused_Disabled)
	testing.expect_value(t, address_hint_verify(enabled_cfg, hint_key, &dgram), Address_Hint_Status.Ok)

	wire: [ADDRESS_HINT_WIRE_SIZE]u8
	written, st_enc := address_hint_encode(&dgram, wire[:])
	testing.expect_value(t, st_enc, Address_Hint_Status.Ok)
	testing.expect_value(t, written, ADDRESS_HINT_WIRE_SIZE)

	// Ensure the hint_key itself never appears anywhere in clear in the wire datagram.
	for offset in 0 ..= len(wire) - PUBLIC_KEY_SIZE {
		testing.expect(t, !slices_equal_constant_time(wire[offset:offset + PUBLIC_KEY_SIZE], hint_key[:]))
	}

	decoded, st_dec := address_hint_decode(wire[:])
	testing.expect_value(t, st_dec, Address_Hint_Status.Ok)
	testing.expect_value(t, address_hint_verify(enabled_cfg, hint_key, &decoded), Address_Hint_Status.Ok)

	// Wrong peer key or 1-bit tamper in tag, nonce, port, or address fails tag check.
	testing.expect_value(t, address_hint_verify(enabled_cfg, other_key, &decoded), Address_Hint_Status.Refused_Bad_Tag)
	tampered := decoded
	tampered.tag[31] ~= 0x01
	testing.expect_value(t, address_hint_verify(enabled_cfg, hint_key, &tampered), Address_Hint_Status.Refused_Bad_Tag)
	tampered = decoded
	tampered.port += 1
	testing.expect_value(t, address_hint_verify(enabled_cfg, hint_key, &tampered), Address_Hint_Status.Refused_Bad_Tag)
	tampered = decoded
	tampered.nonce[0] ~= 0x80
	testing.expect_value(t, address_hint_verify(enabled_cfg, hint_key, &tampered), Address_Hint_Status.Refused_Bad_Tag)

	// IPv6 succeeds when non-zero.
	ipv6_addr := [ADDRESS_HINT_ADDRESS_SIZE]u8{0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	v6_dgram, st_v6 := address_hint_build(enabled_cfg, hint_key, .IPv6, 8443, ipv6_addr, nonce)
	testing.expect_value(t, st_v6, Address_Hint_Status.Ok)
	testing.expect_value(t, address_hint_verify(enabled_cfg, hint_key, &v6_dgram), Address_Hint_Status.Ok)

	// Edge refusals: zero key, bad family, port 0, zero IPv4, dirty IPv4 pad, zero IPv6, zero nonce, small buffer.
	_, st := address_hint_build(enabled_cfg, [32]u8{}, .IPv4, 4433, ipv4_addr, nonce)
	testing.expect_value(t, st, Address_Hint_Status.Refused_Zero_Key)
	_, st = address_hint_build(enabled_cfg, hint_key, Address_Family(0), 4433, ipv4_addr, nonce)
	testing.expect_value(t, st, Address_Hint_Status.Refused_Bad_Family)
	_, st = address_hint_build(enabled_cfg, hint_key, .IPv4, 0, ipv4_addr, nonce)
	testing.expect_value(t, st, Address_Hint_Status.Refused_Bad_Port)
	_, st = address_hint_build(enabled_cfg, hint_key, .IPv4, 4433, [16]u8{}, nonce)
	testing.expect_value(t, st, Address_Hint_Status.Refused_Bad_Address)
	dirty_ipv4 := ipv4_addr
	dirty_ipv4[4] = 1
	_, st = address_hint_build(enabled_cfg, hint_key, .IPv4, 4433, dirty_ipv4, nonce)
	testing.expect_value(t, st, Address_Hint_Status.Refused_Bad_Address)
	_, st = address_hint_build(enabled_cfg, hint_key, .IPv6, 4433, [16]u8{}, nonce)
	testing.expect_value(t, st, Address_Hint_Status.Refused_Bad_Address)
	_, st = address_hint_build(enabled_cfg, hint_key, .IPv4, 4433, ipv4_addr, [16]u8{})
	testing.expect_value(t, st, Address_Hint_Status.Refused_Zero_Nonce)

	small_out := [ADDRESS_HINT_WIRE_SIZE - 1]u8{}
	small_out[0] = 0xAA
	written_small, st_small := address_hint_encode(&dgram, small_out[:])
	testing.expect_value(t, st_small, Address_Hint_Status.Refused_Buffer_Too_Small)
	testing.expect_value(t, written_small, 0)
	testing.expect_value(t, small_out[0], u8(0xAA))

	_, st_trunc := address_hint_decode(wire[:ADDRESS_HINT_WIRE_SIZE - 1])
	testing.expect_value(t, st_trunc, Address_Hint_Status.Refused_Malformed_Wire)
}

// ============================================================================
// 6. Signed cross-principal grants and revocation lists
// ============================================================================

@(test)
signed_grant_short_lived_and_long_lived_with_revocation :: proc(t: ^testing.T) {
	grantor_root_priv, grantor_root_pub := make_keypair(0x90)
	_, grantee_root_pub := make_keypair(0x94)
	_, other_grantee_pub := make_keypair(0x98)

	machine_entry, machine_signing_priv := make_machine_entry(0xA0, true, .Active, 1_000, 0)
	grantor_list := Signed_Machine_List {
		principal_root_public_key = grantor_root_pub,
		sequence_number           = 1,
		entry_count               = 1,
	}
	grantor_list.entries[0] = machine_entry
	sign_machine_list(&grantor_list, &grantor_root_priv)

	store_hash := make_hash(0xB1)
	issued := u64(10_000)

	// 1. Short-lived grant (exact 1-day bound = MAX_SHORT_GRANT_LIFE_MS) needs no revocation list.
	short_grant := Signed_Grant {
		grant_serial               = 42,
		grantor_root_public_key    = grantor_root_pub,
		grantor_signing_public_key = machine_entry.signing_public_key,
		serving_machine_id         = machine_entry.machine_id,
		grantee_root_public_key    = grantee_root_pub,
		target_kind                = .Store_Object,
		target_hash                = store_hash,
		rights                     = {.Read},
		issued_at_ms               = issued,
		expires_at_ms              = issued + MAX_SHORT_GRANT_LIFE_MS,
		revocation_list_epoch      = 0,
	}
	sign_grant(&short_grant, &machine_signing_priv)

	// Accepted at exact issue time and 1 ms before expiry.
	testing.expect_value(t, signed_grant_check(&short_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued, nil, ed25519_verify_callback), Grant_Check_Status.Accepted)
	testing.expect_value(t, signed_grant_check(&short_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + MAX_SHORT_GRANT_LIFE_MS - 1, nil, ed25519_verify_callback), Grant_Check_Status.Accepted)
	// Refused before issue time and at exact expiry boundary.
	testing.expect_value(t, signed_grant_check(&short_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued - 1, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Not_Yet_Valid)
	testing.expect_value(t, signed_grant_check(&short_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + MAX_SHORT_GRANT_LIFE_MS, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Expired)

	// Wrong grantee key refused.
	testing.expect_value(t, signed_grant_check(&short_grant, &grantor_list, machine_entry.machine_id, other_grantee_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Wrong_Grantee)

	// 2. Grant exceeding 1 day by even 1 ms without revocation list is refused.
	over_one_day := short_grant
	over_one_day.grant_serial = 43
	over_one_day.expires_at_ms = issued + MAX_SHORT_GRANT_LIFE_MS + 1
	over_one_day.revocation_list_epoch = 0
	sign_grant(&over_one_day, &machine_signing_priv)
	testing.expect_value(t, signed_grant_check(&over_one_day, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Long_Grant_Without_Revocation)

	// 3. Long-lived grant (30 days) with revocation_list_epoch = 2.
	long_grant := short_grant
	long_grant.grant_serial = 100
	long_grant.rights = {.Read, .Write}
	long_grant.expires_at_ms = issued + 30 * MAX_SHORT_GRANT_LIFE_MS
	long_grant.revocation_list_epoch = 2
	sign_grant(&long_grant, &machine_signing_priv)

	// Without revocation list -> refused.
	testing.expect_value(t, signed_grant_check(&long_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Long_Grant_Without_Revocation)

	// Stale revocation list (epoch 1 < 2) -> refused.
	rev_v1 := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 1,
		revoked_count           = 0,
	}
	sign_revocation_list(&rev_v1, &machine_signing_priv)
	testing.expect_value(t, signed_grant_check(&long_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 100, &rev_v1, ed25519_verify_callback), Grant_Check_Status.Refused_Stale_Revocation_List)

	// Fresh revocation list (epoch 2, serial 100 not revoked) -> accepted.
	rev_state: Revocation_List
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &rev_state, false, &rev_v1, ed25519_verify_callback), Revocation_List_Status.Accepted)

	rev_v2 := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 2,
		revoked_count           = 1,
	}
	rev_v2.revoked_serials[0] = 55
	sign_revocation_list(&rev_v2, &machine_signing_priv)
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &rev_state, true, &rev_v2, ed25519_verify_callback), Revocation_List_Status.Accepted)
	testing.expect_value(t, signed_grant_check(&long_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 100, &rev_state, ed25519_verify_callback), Grant_Check_Status.Accepted)

	// Replay/downgrade of revocation list (epoch 2 or epoch 1) refused; state unchanged.
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &rev_state, true, &rev_v2, ed25519_verify_callback), Revocation_List_Status.Refused_Replay_Or_Downgrade)
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &rev_state, true, &rev_v1, ed25519_verify_callback), Revocation_List_Status.Refused_Replay_Or_Downgrade)

	// Epoch 3 revokes BOTH serial 42 (short-lived) and serial 100 (long-lived).
	rev_v3 := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 3,
		revoked_count           = 3,
	}
	rev_v3.revoked_serials[0] = 42
	rev_v3.revoked_serials[1] = 55
	rev_v3.revoked_serials[2] = 100
	sign_revocation_list(&rev_v3, &machine_signing_priv)
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &rev_state, true, &rev_v3, ed25519_verify_callback), Revocation_List_Status.Accepted)

	testing.expect_value(t, signed_grant_check(&long_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 100, &rev_state, ed25519_verify_callback), Grant_Check_Status.Refused_Revoked)
	testing.expect_value(t, signed_grant_check(&short_grant, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 100, &rev_state, ed25519_verify_callback), Grant_Check_Status.Refused_Revoked)

	// Revoking the grantor's signing machine invalidates grants signed by that machine immediately.
	revoked_grantor_list := grantor_list
	revoked_grantor_list.sequence_number = 2
	revoked_grantor_list.entries[0].state = .Revoked
	revoked_grantor_list.entries[0].revoked_at_ms = 20_000
	sign_machine_list(&revoked_grantor_list, &grantor_root_priv)
	testing.expect_value(t, signed_grant_check(&short_grant, &revoked_grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Serving_Machine_Not_Active)

	// Machine B (active) signs a grant served by Machine A; revoking Machine A at seq 2 refuses the grant even while Machine B remains active.
	machine_b, machine_b_signing_priv := make_machine_entry(0xA6, true, .Active, 1_500, 0)
	two_machine_v1 := Signed_Machine_List {
		principal_root_public_key = grantor_root_pub,
		sequence_number           = 1,
		entry_count               = 2,
	}
	two_machine_v1.entries[0] = machine_entry
	two_machine_v1.entries[1] = machine_b
	sign_machine_list(&two_machine_v1, &grantor_root_priv)

	cross_machine_grant := Signed_Grant {
		grant_serial               = 200,
		grantor_root_public_key    = grantor_root_pub,
		grantor_signing_public_key = machine_b.signing_public_key,
		serving_machine_id         = machine_entry.machine_id,
		grantee_root_public_key    = grantee_root_pub,
		target_kind                = .Store_Object,
		target_hash                = store_hash,
		rights                     = {.Read},
		issued_at_ms               = issued,
		expires_at_ms              = issued + MAX_SHORT_GRANT_LIFE_MS,
		revocation_list_epoch      = 0,
	}
	sign_grant(&cross_machine_grant, &machine_b_signing_priv)
	testing.expect_value(t, signed_grant_check(&cross_machine_grant, &two_machine_v1, machine_entry.machine_id, grantee_root_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Accepted)

	// Revoke Machine A (serving machine) at seq 2 while Machine B (signer) stays active.
	two_machine_v2 := two_machine_v1
	two_machine_v2.sequence_number = 2
	two_machine_v2.entries[0].state = .Revoked
	two_machine_v2.entries[0].revoked_at_ms = 25_000
	sign_machine_list(&two_machine_v2, &grantor_root_priv)
	testing.expect_value(t, signed_grant_check(&cross_machine_grant, &two_machine_v2, machine_entry.machine_id, grantee_root_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Serving_Machine_Not_Active)

	// Revoke Machine B (signer) at seq 3 while Machine A stays active -> Refused_Grantor_Key_Not_Active.
	two_machine_v3 := two_machine_v1
	two_machine_v3.sequence_number = 3
	two_machine_v3.entries[1].state = .Revoked
	two_machine_v3.entries[1].revoked_at_ms = 30_000
	sign_machine_list(&two_machine_v3, &grantor_root_priv)
	testing.expect_value(t, signed_grant_check(&cross_machine_grant, &two_machine_v3, machine_entry.machine_id, grantee_root_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Grantor_Key_Not_Active)

	// Unlisted serving_machine_id is also refused even when grant matches it.
	_, unlisted_machine_id := make_keypair(0xAC)
	unlisted_grant := cross_machine_grant
	unlisted_grant.serving_machine_id = unlisted_machine_id
	sign_grant(&unlisted_grant, &machine_b_signing_priv)
	testing.expect_value(t, signed_grant_check(&unlisted_grant, &two_machine_v1, unlisted_machine_id, grantee_root_pub, issued + 100, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Serving_Machine_Not_Active)
}

@(test)
signed_grant_refuses_all_adversarial_inputs :: proc(t: ^testing.T) {
	grantor_root_priv, grantor_root_pub := make_keypair(0xB0)
	_, grantee_root_pub := make_keypair(0xB4)
	_, other_machine_id := make_keypair(0xB8)
	machine_entry, machine_signing_priv := make_machine_entry(0xC0, true, .Active, 1_000, 0)
	grantor_list := Signed_Machine_List {
		principal_root_public_key = grantor_root_pub,
		sequence_number           = 1,
		entry_count               = 1,
	}
	grantor_list.entries[0] = machine_entry
	sign_machine_list(&grantor_list, &grantor_root_priv)

	base_grant := Signed_Grant {
		grant_serial               = 7,
		grantor_root_public_key    = grantor_root_pub,
		grantor_signing_public_key = machine_entry.signing_public_key,
		serving_machine_id         = machine_entry.machine_id,
		grantee_root_public_key    = grantee_root_pub,
		target_kind                = .Role_Contract,
		target_hash                = make_hash(0xC9),
		rights                     = {.Read},
		issued_at_ms               = 5_000,
		expires_at_ms              = 6_000,
		revocation_list_epoch      = 0,
	}
	sign_grant(&base_grant, &machine_signing_priv)

	// Wire round-trip succeeds.
	wire: [SIGNED_GRANT_WIRE_SIZE]u8
	written, enc_st := signed_grant_encode(&base_grant, wire[:])
	testing.expect_value(t, enc_st, Grant_Check_Status.Accepted)
	testing.expect_value(t, written, SIGNED_GRANT_WIRE_SIZE)
	decoded, dec_st := signed_grant_decode(wire[:])
	testing.expect_value(t, dec_st, Grant_Check_Status.Accepted)
	testing.expect_value(t, signed_grant_check(&decoded, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Accepted)

	// Zero rights, Write without Read, and unknown rights bits refused.
	_, rights_zero_ok := share_rights_of_word(0)
	testing.expect(t, !rights_zero_ok)
	_, rights_write_only_ok := share_rights_of_word(share_rights_word({.Write}))
	testing.expect(t, !rights_write_only_ok)
	_, rights_unknown_ok := share_rights_of_word(4)
	testing.expect(t, !rights_unknown_ok)
	_, rights_max_ok := share_rights_of_word(max(u64))
	testing.expect(t, !rights_max_ok)

	bad := base_grant
	bad.rights = {}
	testing.expect_value(t, signed_grant_check(&bad, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Bad_Rights)

	bad = base_grant
	bad.rights = {.Write}
	testing.expect_value(t, signed_grant_check(&bad, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Bad_Rights)
	bad_wire_write_only := wire
	byte_order.write_u64_little_endian(bad_wire_write_only[:], 176, share_rights_word({.Write}))
	_, st_write_only_wire := signed_grant_decode(bad_wire_write_only[:])
	testing.expect_value(t, st_write_only_wire, Grant_Check_Status.Refused_Bad_Rights)

	bad = base_grant
	bad.grant_serial = 0
	testing.expect_value(t, signed_grant_check(&bad, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Zero_Serial)

	bad = base_grant
	bad.target_hash = {}
	testing.expect_value(t, signed_grant_check(&bad, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Zero_Target_Hash)

	bad = base_grant
	bad.target_kind = Grant_Target_Kind(0)
	testing.expect_value(t, signed_grant_check(&bad, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Bad_Target_Kind)

	bad = base_grant
	bad.expires_at_ms = bad.issued_at_ms
	testing.expect_value(t, signed_grant_check(&bad, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_000, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Bad_Lifetime)

	// Wrong serving machine ID.
	testing.expect_value(t, signed_grant_check(&base_grant, &grantor_list, other_machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Wrong_Serving_Machine)

	// Escalating rights without re-signing fails Ed25519 verification.
	escalated := base_grant
	escalated.rights = {.Read, .Write}
	testing.expect_value(t, signed_grant_check(&escalated, &grantor_list, machine_entry.machine_id, grantee_root_pub, 5_500, nil, ed25519_verify_callback), Grant_Check_Status.Refused_Invalid_Signature)

	// Revocation list structural refusals: unsorted, duplicate, zero serial, too many entries.
	bad_rev := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 1,
		revoked_count           = 2,
	}
	bad_rev.revoked_serials[0] = 20
	bad_rev.revoked_serials[1] = 10
	testing.expect_value(t, revocation_list_validate(&grantor_list, nil, &bad_rev, ed25519_verify_callback), Revocation_List_Status.Refused_Not_Strictly_Sorted)
	bad_rev.revoked_serials[1] = 20
	testing.expect_value(t, revocation_list_validate(&grantor_list, nil, &bad_rev, ed25519_verify_callback), Revocation_List_Status.Refused_Not_Strictly_Sorted)
	bad_rev.revoked_serials[0] = 0
	testing.expect_value(t, revocation_list_validate(&grantor_list, nil, &bad_rev, ed25519_verify_callback), Revocation_List_Status.Refused_Zero_Serial)
	bad_rev.revoked_count = INLINE_REVOKED_GRANTS + 1
	testing.expect_value(t, revocation_list_validate(&grantor_list, nil, &bad_rev, ed25519_verify_callback), Revocation_List_Status.Refused_Too_Many_Entries)

	// Malformed wire grant refusals.
	bad_wire := wire
	bad_wire[5] = 99
	_, st_bad_kind := signed_grant_decode(bad_wire[:])
	testing.expect_value(t, st_bad_kind, Grant_Check_Status.Refused_Bad_Target_Kind)
	bad_wire = wire
	byte_order.write_u64_little_endian(bad_wire[:], 176, 0)
	_, st_bad_rights := signed_grant_decode(bad_wire[:])
	testing.expect_value(t, st_bad_rights, Grant_Check_Status.Refused_Bad_Rights)
	_, st_trunc := signed_grant_decode(wire[:SIGNED_GRANT_WIRE_SIZE - 1])
	testing.expect_value(t, st_trunc, Grant_Check_Status.Refused_Malformed_Wire)
}

// ============================================================================
// 7. Store delta sync wire protocol and three-way reconciliation
// ============================================================================

@(test)
sync_wire_roundtrip_and_strict_refusals :: proc(t: ^testing.T) {
	store_id := make_hash(0xD1)
	base_h := make_hash(0xD2)
	head_1 := make_hash(0xD3)
	head_2 := make_hash(0xD4)
	payload := transmute([]u8)string("versioned store blob content")
	blob_h := blake3.hash(payload)

	frame_buf: [2048]u8

	// 1. Heads_Offer round-trip.
	offer := Sync_Frame {
		kind             = .Heads_Offer,
		store_id         = store_id,
		has_common_base  = true,
		common_base_hash = base_h,
		head_count       = 2,
	}
	offer.heads[0] = head_1
	offer.heads[1] = head_2
	written, ref := sync_frame_encode(&offer, frame_buf[:])
	testing.expect_value(t, ref, Sync_Wire_Refusal.None)
	dec_offer, dec_ref := sync_frame_decode(frame_buf[:written])
	testing.expect_value(t, dec_ref, Sync_Wire_Refusal.None)
	testing.expect_value(t, dec_offer.kind, Sync_Frame_Kind.Heads_Offer)
	testing.expect_value(t, dec_offer.head_count, u8(2))
	testing.expect_value(t, dec_offer.heads[1], head_2)

	// 2. Want_Objects round-trip.
	want := Sync_Frame {
		kind       = .Want_Objects,
		store_id   = store_id,
		want_count = 1,
	}
	want.want_hashes[0] = blob_h
	written, ref = sync_frame_encode(&want, frame_buf[:])
	testing.expect_value(t, ref, Sync_Wire_Refusal.None)
	dec_want, dec_want_ref := sync_frame_decode(frame_buf[:written])
	testing.expect_value(t, dec_want_ref, Sync_Wire_Refusal.None)
	testing.expect_value(t, dec_want.want_hashes[0], blob_h)

	// 3. Send_Object round-trip.
	send := Sync_Frame {
		kind        = .Send_Object,
		store_id    = store_id,
		object_hash = blob_h,
		object_kind = .Blob,
		payload     = payload,
		object_total_bytes = u64(len(payload)),
	}
	written, ref = sync_frame_encode(&send, frame_buf[:])
	testing.expect_value(t, ref, Sync_Wire_Refusal.None)
	dec_send, dec_send_ref := sync_frame_decode(frame_buf[:written])
	testing.expect_value(t, dec_send_ref, Sync_Wire_Refusal.None)
	testing.expect_value(t, dec_send.object_kind, Sync_Object_Kind.Blob)
	testing.expect_value(t, string(dec_send.payload), string(payload))

	// 4. Sync_Ack round-trip.
	ack := Sync_Frame {
		kind                 = .Sync_Ack,
		store_id             = store_id,
		acked_head_hash      = head_1,
		new_common_base_hash = head_1,
	}
	written, ref = sync_frame_encode(&ack, frame_buf[:])
	testing.expect_value(t, ref, Sync_Wire_Refusal.None)
	dec_ack, dec_ack_ref := sync_frame_decode(frame_buf[:written])
	testing.expect_value(t, dec_ack_ref, Sync_Wire_Refusal.None)
	testing.expect_value(t, dec_ack.acked_head_hash, head_1)

	// 5. Sync_Refusal round-trip.
	refusal_frame := Sync_Frame {
		kind           = .Sync_Refusal,
		store_id       = store_id,
		refusal_reason = .Revoked,
	}
	written, ref = sync_frame_encode(&refusal_frame, frame_buf[:])
	testing.expect_value(t, ref, Sync_Wire_Refusal.None)
	dec_refusal, dec_refusal_err := sync_frame_decode(frame_buf[:written])
	testing.expect_value(t, dec_refusal_err, Sync_Wire_Refusal.None)
	testing.expect_value(t, dec_refusal.refusal_reason, Sync_Refusal_Reason.Revoked)

	// Adversarial wire refusals: bad magic, version, unknown enums, reserved bytes, trailing bytes, duplicates, small buffer.
	_, err := sync_frame_decode(frame_buf[:written - 1])
	testing.expect_value(t, err, Sync_Wire_Refusal.Truncated)
	_, err = sync_frame_decode(frame_buf[:written + 1])
	testing.expect_value(t, err, Sync_Wire_Refusal.Trailing_Bytes)

	bad_frame := frame_buf
	bad_frame[0] = 'Z'
	_, err = sync_frame_decode(bad_frame[:written])
	testing.expect_value(t, err, Sync_Wire_Refusal.Bad_Magic)

	bad_frame = frame_buf
	bad_frame[4] = 99
	_, err = sync_frame_decode(bad_frame[:written])
	testing.expect_value(t, err, Sync_Wire_Refusal.Unsupported_Version)

	bad_frame = frame_buf
	bad_frame[5] = 0
	_, err = sync_frame_decode(bad_frame[:written])
	testing.expect_value(t, err, Sync_Wire_Refusal.Bad_Frame_Kind)

	bad_frame = frame_buf
	bad_frame[6] = 1
	_, err = sync_frame_decode(bad_frame[:written])
	testing.expect_value(t, err, Sync_Wire_Refusal.Reserved_Nonzero)

	bad_frame = frame_buf
	bad_frame[SYNC_FRAME_HEADER_SIZE + 32] = 99
	_, err = sync_frame_decode(bad_frame[:written])
	testing.expect_value(t, err, Sync_Wire_Refusal.Bad_Refusal_Reason)

	// Duplicate heads in Heads_Offer refused; output buffer untouched.
	dup_offer := offer
	dup_offer.heads[1] = head_1
	sentinel: [16]u8
	sentinel[0] = 0x55
	w_dup, dup_ref := sync_frame_encode(&dup_offer, sentinel[:])
	testing.expect_value(t, dup_ref, Sync_Wire_Refusal.Duplicate_Hash)
	testing.expect_value(t, w_dup, 0)
	testing.expect_value(t, sentinel[0], u8(0x55))

	// Zero head_count and over-bound head_count refused.
	bad_count := offer
	bad_count.head_count = 0
	_, err = sync_frame_encode(&bad_count, frame_buf[:])
	testing.expect_value(t, err, Sync_Wire_Refusal.Bad_Count)
	bad_count.head_count = MAX_SYNC_HEADS + 1
	_, err = sync_frame_encode(&bad_count, frame_buf[:])
	testing.expect_value(t, err, Sync_Wire_Refusal.Bad_Count)

	// has_common_base == false with non-zero common_base_hash refused.
	bad_flag := offer
	bad_flag.has_common_base = false
	_, err = sync_frame_encode(&bad_flag, frame_buf[:])
	testing.expect_value(t, err, Sync_Wire_Refusal.Bad_Flag)
}

@(test)
sync_three_way_reconcile_fast_forward_conflict_fork_and_session :: proc(t: ^testing.T) {
	store_id := make_hash(0xE0)
	base_h := make_hash(0xE1)
	local_h := make_hash(0xE2)
	remote_h := make_hash(0xE3)

	// 1. Already up to date.
	res_same := reconcile_heads(true, base_h, local_h, local_h)
	testing.expect_value(t, res_same.outcome, Reconcile_Outcome.Already_Up_To_Date)
	testing.expect_value(t, res_same.resulting_head_hash, local_h)

	// 2. Clean fast-forward when local stayed at common base and remote moved forward.
	res_ff := reconcile_heads(true, base_h, base_h, remote_h)
	testing.expect_value(t, res_ff.outcome, Reconcile_Outcome.Fast_Forward_Local)
	testing.expect_value(t, res_ff.resulting_head_hash, remote_h)
	testing.expect_value(t, res_ff.new_common_base_hash, remote_h)

	// 3. Remote behind local: local kept untouched.
	res_behind := reconcile_heads(true, base_h, local_h, base_h)
	testing.expect_value(t, res_behind.outcome, Reconcile_Outcome.Remote_Behind_Local)
	testing.expect_value(t, res_behind.resulting_head_hash, local_h)

	// 4. Diverged commits: clean conflict fork preserving BOTH local and remote heads.
	res_fork_a := reconcile_heads(true, base_h, local_h, remote_h)
	res_fork_b := reconcile_heads(true, base_h, remote_h, local_h)
	testing.expect_value(t, res_fork_a.outcome, Reconcile_Outcome.Conflict_Fork)
	testing.expect_value(t, res_fork_b.outcome, Reconcile_Outcome.Conflict_Fork)
	testing.expect_value(t, res_fork_a.conflict_fork.common_base_hash, base_h)
	testing.expect_value(t, res_fork_a.conflict_fork.local_head_hash, local_h)
	testing.expect_value(t, res_fork_a.conflict_fork.remote_head_hash, remote_h)
	testing.expect(t, !key_is_zero(res_fork_a.resulting_head_hash))
	// Both machines compute the exact same deterministic merge commit hash.
	testing.expect_value(t, res_fork_a.resulting_head_hash, res_fork_b.resulting_head_hash)

	// 5. Initial pull with no common base and empty local fast-forwards to remote.
	res_init := reconcile_heads(false, {}, {}, remote_h)
	testing.expect_value(t, res_init.outcome, Reconcile_Outcome.Fast_Forward_Local)
	testing.expect_value(t, res_init.resulting_head_hash, remote_h)

	// 5b. Empty remote with no common base must NOT prematurely advance common base to local_h,
	// so an offline remote commit R1 before pulling L1 triggers Conflict_Fork preserving both L1 and R1.
	res_remote_empty := reconcile_heads(false, {}, local_h, {})
	testing.expect_value(t, res_remote_empty.outcome, Reconcile_Outcome.Remote_Behind_Local)
	testing.expect_value(t, res_remote_empty.resulting_head_hash, local_h)
	testing.expect(t, key_is_zero(res_remote_empty.new_common_base_hash))
	res_after_offline_remote := reconcile_heads(false, res_remote_empty.new_common_base_hash, local_h, remote_h)
	testing.expect_value(t, res_after_offline_remote.outcome, Reconcile_Outcome.Conflict_Fork)
	testing.expect_value(t, res_after_offline_remote.conflict_fork.local_head_hash, local_h)
	testing.expect_value(t, res_after_offline_remote.conflict_fork.remote_head_hash, remote_h)

	// 6. Invalid hash combinations refused.
	testing.expect_value(t, reconcile_heads(false, {}, {}, {}).outcome, Reconcile_Outcome.Refused_Invalid_Hashes)
	testing.expect_value(t, reconcile_heads(true, {}, local_h, remote_h).outcome, Reconcile_Outcome.Refused_Invalid_Hashes)
	testing.expect_value(t, reconcile_heads(false, base_h, local_h, remote_h).outcome, Reconcile_Outcome.Refused_Invalid_Hashes)

	// 7. Per-object three-way reconciliation keeps both sides on conflict.
	dec_unch, h_unch, _ := reconcile_object(base_h, base_h, base_h)
	testing.expect_value(t, dec_unch, Object_Merge_Decision.Unchanged)
	testing.expect_value(t, h_unch, base_h)

	dec_loc, h_loc, _ := reconcile_object(base_h, local_h, base_h)
	testing.expect_value(t, dec_loc, Object_Merge_Decision.Take_Local)
	testing.expect_value(t, h_loc, local_h)

	dec_rem, h_rem, _ := reconcile_object(base_h, base_h, remote_h)
	testing.expect_value(t, dec_rem, Object_Merge_Decision.Take_Remote)
	testing.expect_value(t, h_rem, remote_h)

	dec_both, h_both, _ := reconcile_object(base_h, local_h, local_h)
	testing.expect_value(t, dec_both, Object_Merge_Decision.Both_Same)
	testing.expect_value(t, h_both, local_h)

	dec_conf_a, h_conf_a, cv_a := reconcile_object(base_h, local_h, remote_h)
	dec_conf_b, h_conf_b, _ := reconcile_object(base_h, remote_h, local_h)
	testing.expect_value(t, dec_conf_a, Object_Merge_Decision.Conflict_Keep_Both)
	testing.expect_value(t, dec_conf_b, Object_Merge_Decision.Conflict_Keep_Both)
	testing.expect_value(t, cv_a.base_hash, base_h)
	testing.expect_value(t, cv_a.local_hash, local_h)
	testing.expect_value(t, cv_a.remote_hash, remote_h)
	testing.expect_value(t, h_conf_a, h_conf_b)

	// 8. Full Sync_Session receiving a Blob, a canonical Tree, and a domain-separated Version_Node,
	// refusing kind confusion and corruption without losing verified progress.
	blob_payload := transmute([]u8)string("note paragraph from laptop")
	blob_hash := blake3.hash(blob_payload)
	version_payload := transmute([]u8)string("note paragraph from laptop") // Same bytes, distinct domain hash.
	version_hash := version_node_hash(version_payload)
	testing.expect(t, !keys_equal_constant_time(blob_hash, version_hash))
	testing.expect(t, sync_object_verify(.Blob, blob_hash, blob_payload))
	testing.expect(t, !sync_object_verify(.Version_Node, blob_hash, blob_payload))
	testing.expect(t, sync_object_verify(.Version_Node, version_hash, version_payload))
	testing.expect(t, !sync_object_verify(.Blob, version_hash, version_payload))

	tree_entry, entry_ref := tree_hash.tree_entry_make(.Object, "note.txt", blob_hash)
	testing.expect_value(t, entry_ref, tree_hash.Tree_Refusal.None)
	tree_entries := [1]tree_hash.Tree_Entry{tree_entry}
	tree_buf: [256]u8
	tree_len, tree_enc_ref := tree_hash.tree_encode(tree_entries[:], tree_buf[:])
	testing.expect_value(t, tree_enc_ref, tree_hash.Tree_Refusal.None)
	tree_bytes := tree_buf[:tree_len]
	computed_tree_hash, tree_h_ref := tree_hash.tree_hash(tree_bytes)
	testing.expect_value(t, tree_h_ref, tree_hash.Tree_Refusal.None)

	missing := [3]Expected_Sync_Object {
		{kind = .Blob, hash = blob_hash},
		{kind = .Tree, hash = computed_tree_hash},
		{kind = .Version_Node, hash = version_hash},
	}
	session, begin_ok := sync_session_begin_receive(store_id, true, base_h, local_h, remote_h, missing[:])
	testing.expect(t, begin_ok)
	testing.expect_value(t, session.state, Sync_Session_State.Waiting_Objects)
	sync_assembly: [256]u8

	// Corrupted blob payload is refused with Hash_Mismatch and does not corrupt session state.
	corrupt_payload := [len("note paragraph from laptop")]u8{}
	copy(corrupt_payload[:], blob_payload)
	corrupt_payload[0] ~= 0x01
	bad_send := Sync_Frame {
		kind        = .Send_Object,
		store_id    = store_id,
		object_hash = blob_hash,
		object_kind = .Blob,
		payload     = corrupt_payload[:],
		object_total_bytes = u64(len(corrupt_payload[:])),
	}
	reason, recv_ok := sync_session_receive_object(&session, &bad_send, sync_assembly[:])
	testing.expect(t, !recv_ok)
	testing.expect_value(t, reason, Sync_Refusal_Reason.Hash_Mismatch)
	testing.expect_value(t, session.received_mask, u64(0))
	testing.expect_value(t, session.state, Sync_Session_State.Waiting_Objects)

	// Kind confusion: a Blob masquerading as a Version_Node (and vice versa) is refused.
	blob_as_version := Sync_Frame {
		kind        = .Send_Object,
		store_id    = store_id,
		object_hash = blob_hash,
		object_kind = .Version_Node,
		payload     = blob_payload,
		object_total_bytes = u64(len(blob_payload)),
	}
	reason, recv_ok = sync_session_receive_object(&session, &blob_as_version, sync_assembly[:])
	testing.expect(t, !recv_ok)
	testing.expect_value(t, reason, Sync_Refusal_Reason.Protocol_Error)
	testing.expect_value(t, session.received_mask, u64(0))

	version_as_blob := Sync_Frame {
		kind        = .Send_Object,
		store_id    = store_id,
		object_hash = version_hash,
		object_kind = .Blob,
		payload     = version_payload,
		object_total_bytes = u64(len(version_payload)),
	}
	reason, recv_ok = sync_session_receive_object(&session, &version_as_blob, sync_assembly[:])
	testing.expect(t, !recv_ok)
	testing.expect_value(t, reason, Sync_Refusal_Reason.Protocol_Error)
	testing.expect_value(t, session.received_mask, u64(0))

	// Wrong store ID refused with Unknown_Store.
	wrong_store := bad_send
	wrong_store.store_id = make_hash(0xFF)
	wrong_store.payload = blob_payload
	reason, recv_ok = sync_session_receive_object(&session, &wrong_store, sync_assembly[:])
	testing.expect(t, !recv_ok)
	testing.expect_value(t, reason, Sync_Refusal_Reason.Unknown_Store)

	// Valid blob accepted.
	good_blob := Sync_Frame {
		kind        = .Send_Object,
		store_id    = store_id,
		object_hash = blob_hash,
		object_kind = .Blob,
		payload     = blob_payload,
		object_total_bytes = u64(len(blob_payload)),
	}
	_, recv_ok = sync_session_receive_object(&session, &good_blob, sync_assembly[:])
	testing.expect(t, recv_ok)
	testing.expect_value(t, session.state, Sync_Session_State.Waiting_Objects)

	// Duplicate delivery of already-received blob refused.
	reason, recv_ok = sync_session_receive_object(&session, &good_blob, sync_assembly[:])
	testing.expect(t, !recv_ok)
	testing.expect_value(t, reason, Sync_Refusal_Reason.Protocol_Error)

	// Valid canonical tree accepted while version node is still pending.
	good_tree := Sync_Frame {
		kind        = .Send_Object,
		store_id    = store_id,
		object_hash = computed_tree_hash,
		object_kind = .Tree,
		payload     = tree_bytes,
		object_total_bytes = u64(len(tree_bytes)),
	}
	_, recv_ok = sync_session_receive_object(&session, &good_tree, sync_assembly[:])
	testing.expect(t, recv_ok)
	testing.expect_value(t, session.state, Sync_Session_State.Waiting_Objects)

	// Valid domain-separated Version_Node completes the session and reconciles into the conflict fork.
	good_version := Sync_Frame {
		kind        = .Send_Object,
		store_id    = store_id,
		object_hash = version_hash,
		object_kind = .Version_Node,
		payload     = version_payload,
		object_total_bytes = u64(len(version_payload)),
	}
	_, recv_ok = sync_session_receive_object(&session, &good_version, sync_assembly[:])
	testing.expect(t, recv_ok)
	testing.expect_value(t, session.state, Sync_Session_State.Reconciled)
	testing.expect_value(t, session.reconcile_result.outcome, Reconcile_Outcome.Conflict_Fork)
	testing.expect_value(t, session.reconcile_result.conflict_fork.local_head_hash, local_h)
	testing.expect_value(t, session.reconcile_result.conflict_fork.remote_head_hash, remote_h)
}

// A blob of 200 KiB, past the 64 KiB of one frame, crosses in four pieces
// that the frame border reads back; a piece out of order, a piece past the
// size, an object larger than the buffer, and a changed byte are refused,
// and the object is received only whole.
@(test)
sync_object_of_200_kibibytes_crosses_in_pieces :: proc(t: ^testing.T) {
	SIZE :: 200 * 1024
	blob := make([]u8, SIZE, context.temp_allocator)
	for index in 0 ..< SIZE {
		blob[index] = u8(index * 13 + index / 509)
	}
	hash := blake3.hash(blob)
	store_id := blake3.hash(transmute([]u8)string("store of a large note"))
	missing := [1]Expected_Sync_Object{{kind = .Blob, hash = hash}}
	local_h, remote_h := blake3.hash([]u8{1}), blake3.hash([]u8{2})
	assembly := make([]u8, SIZE, context.temp_allocator)
	wire := make([]u8, MAX_SYNC_BODY_BYTES + SYNC_FRAME_HEADER_SIZE, context.temp_allocator)

	piece :: proc(store_id, hash: blake3.Hash, blob: []u8, offset: int) -> Sync_Frame {
		end := min(offset + SYNC_CHUNK_BYTES, len(blob))
		return Sync_Frame{kind = .Send_Object, store_id = store_id, object_hash = hash, object_kind = .Blob, object_total_bytes = u64(len(blob)), chunk_offset = u64(offset), payload = blob[offset:end]}
	}

	// The border: a piece past the bound of a frame, a piece past the size,
	// an offset past the size, an empty piece of an object that is not empty.
	too_big := piece(store_id, hash, blob, 0)
	too_big.payload = blob[:SYNC_CHUNK_BYTES + 1]
	_, refusal := sync_frame_encoded_size(&too_big)
	testing.expect_value(t, refusal, Sync_Wire_Refusal.Too_Large)
	past := piece(store_id, hash, blob, SIZE - 10)
	past.payload = blob[SIZE - 10 - 5:SIZE - 5 + 1]
	_, refusal = sync_frame_encoded_size(&past)
	testing.expect_value(t, refusal, Sync_Wire_Refusal.Bad_Count)
	empty := piece(store_id, hash, blob, 0)
	empty.payload = nil
	_, refusal = sync_frame_encoded_size(&empty)
	testing.expect_value(t, refusal, Sync_Wire_Refusal.Bad_Count)

	session, begin_ok := sync_session_begin_receive(store_id, false, {}, local_h, remote_h, missing[:])
	testing.expect(t, begin_ok)
	// An object larger than the buffer of the receiver.
	first := piece(store_id, hash, blob, 0)
	reason, ok := sync_session_receive_object(&session, &first, assembly[:SIZE - 1])
	testing.expect(t, !ok && reason == .Object_Too_Large)
	// A piece that is not the first starts nothing.
	second := piece(store_id, hash, blob, SYNC_CHUNK_BYTES)
	reason, ok = sync_session_receive_object(&session, &second, assembly)
	testing.expect(t, !ok && reason == .Protocol_Error)
	// The pieces in order, each one encoded and decoded, with one byte
	// changed in the third: the whole object is refused at its end.
	pieces := 0
	for offset := 0; offset < SIZE; offset += SYNC_CHUNK_BYTES {
		frame := piece(store_id, hash, blob, offset)
		written, encode_refusal := sync_frame_encode(&frame, wire)
		testing.expect_value(t, encode_refusal, Sync_Wire_Refusal.None)
		if pieces == 2 {
			wire[written - 1] ~= 1
		}
		decoded, decode_refusal := sync_frame_decode(wire[:written])
		testing.expect_value(t, decode_refusal, Sync_Wire_Refusal.None)
		testing.expect_value(t, decoded.chunk_offset, u64(offset))
		testing.expect_value(t, decoded.object_total_bytes, u64(SIZE))
		reason, ok = sync_session_receive_object(&session, &decoded, assembly)
		pieces += 1
		if offset + SYNC_CHUNK_BYTES < SIZE {
			testing.expect(t, ok)
		} else {
			testing.expect(t, !ok && reason == .Hash_Mismatch)
		}
	}
	testing.expect_value(t, pieces, 4)
	testing.expect_value(t, session.state, Sync_Session_State.Waiting_Objects)
	// A piece out of order in the middle ends the object.
	frame := piece(store_id, hash, blob, 0)
	_, ok = sync_session_receive_object(&session, &frame, assembly)
	testing.expect(t, ok)
	frame = piece(store_id, hash, blob, 2 * SYNC_CHUNK_BYTES)
	reason, ok = sync_session_receive_object(&session, &frame, assembly)
	testing.expect(t, !ok && reason == .Protocol_Error)
	// The true pieces: the object is received, and the session reconciles.
	for offset := 0; offset < SIZE; offset += SYNC_CHUNK_BYTES {
		frame = piece(store_id, hash, blob, offset)
		_, ok = sync_session_receive_object(&session, &frame, assembly)
		testing.expect(t, ok)
	}
	testing.expect_value(t, session.state, Sync_Session_State.Reconciled)
	testing.expect(t, string(assembly) == string(blob))
}

@(test)
revocation_list_crosses_inline_tier_and_fails_closed :: proc(t: ^testing.T) {
	grantor_root_priv, grantor_root_pub := make_keypair(0xD0)
	_, grantee_root_pub := make_keypair(0xD4)
	machine_entry, machine_signing_priv := make_machine_entry(0xD8, true, .Active, 1_000, 0)
	grantor_list := Signed_Machine_List {
		principal_root_public_key = grantor_root_pub,
		sequence_number           = 1,
		entry_count               = 1,
	}
	grantor_list.entries[0] = machine_entry
	sign_machine_list(&grantor_list, &grantor_root_priv)

	issued := u64(50_000)
	make_long_grant :: proc(serial: u64, epoch: u64, grantor_root: Principal_Root_Public_Key, entry: Machine_Entry, grantee: Principal_Root_Public_Key, issued_at: u64, priv: ^ed25519.Private_Key) -> Signed_Grant {
		g := Signed_Grant {
			grant_serial               = serial,
			grantor_root_public_key    = grantor_root,
			grantor_signing_public_key = entry.signing_public_key,
			serving_machine_id         = entry.machine_id,
			grantee_root_public_key    = grantee,
			target_kind                = .Store_Object,
			target_hash                = make_hash(0xE1),
			rights                     = {.Read},
			issued_at_ms               = issued_at,
			expires_at_ms              = issued_at + 10 * MAX_SHORT_GRANT_LIFE_MS,
			revocation_list_epoch      = epoch,
		}
		sign_grant(&g, priv)
		return g
	}

	// 1. Exact inline bound (64 revocations) verifies with nil scratch and slow_tier_uses == 0.
	rev_64 := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 1,
		revoked_count           = INLINE_REVOKED_GRANTS,
	}
	for i in 0 ..< INLINE_REVOKED_GRANTS {
		rev_64.revoked_serials[i] = u64(i + 1)
	}
	sign_revocation_list(&rev_64, &machine_signing_priv)
	testing.expect_value(t, revocation_list_validate(&grantor_list, nil, &rev_64, ed25519_verify_callback), Revocation_List_Status.Accepted)
	testing.expect_value(t, rev_64.slow_tier_uses, u64(0))
	testing.expect(t, revocation_list_contains_serial(&rev_64, 1))
	testing.expect(t, revocation_list_contains_serial(&rev_64, INLINE_REVOKED_GRANTS))
	testing.expect(t, !revocation_list_contains_serial(&rev_64, INLINE_REVOKED_GRANTS + 1))

	// 2. One past inline bound (65 revocations) without external_serials fails closed.
	rev_65_no_ext := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 2,
		revoked_count           = INLINE_REVOKED_GRANTS + 1,
	}
	testing.expect_value(t, revocation_list_validate(&grantor_list, &rev_64, &rev_65_no_ext, ed25519_verify_callback), Revocation_List_Status.Refused_Too_Many_Entries)

	// 3. One past inline bound (65 revocations) with external_serials:
	//    - nil or 1-byte-short scratch fails closed (Refused_Buffer_Too_Small, slow_tier_uses unchanged)
	//    - signed_grant_check without scratch fails closed (Refused_Bad_Revocation_List)
	//    - exact scratch succeeds, increments slow_tier_uses, revokes #65, accepts #66.
	serials_65 := make([]u64, INLINE_REVOKED_GRANTS + 1)
	defer delete(serials_65)
	for i in 0 ..< len(serials_65) {
		serials_65[i] = u64(i + 1)
	}
	rev_65 := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 2,
		revoked_count           = u16(len(serials_65)),
		external_serials        = serials_65,
	}
	sign_revocation_list(&rev_65, &machine_signing_priv)

	required_65 := revocation_list_signing_bytes_size(rev_65.revoked_count)
	scratch_65 := make([]u8, required_65)
	defer delete(scratch_65)

	testing.expect_value(t, revocation_list_validate(&grantor_list, &rev_64, &rev_65, ed25519_verify_callback), Revocation_List_Status.Refused_Buffer_Too_Small)
	testing.expect_value(t, revocation_list_validate(&grantor_list, &rev_64, &rev_65, ed25519_verify_callback, nil, scratch_65[:required_65 - 1]), Revocation_List_Status.Refused_Buffer_Too_Small)
	testing.expect_value(t, rev_65.slow_tier_uses, u64(0))

	grant_65 := make_long_grant(65, 2, grantor_root_pub, machine_entry, grantee_root_pub, issued, &machine_signing_priv)
	grant_66 := make_long_grant(66, 2, grantor_root_pub, machine_entry, grantee_root_pub, issued, &machine_signing_priv)
	testing.expect_value(t, signed_grant_check(&grant_65, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 10, &rev_65, ed25519_verify_callback), Grant_Check_Status.Refused_Bad_Revocation_List)
	testing.expect_value(t, signed_grant_check(&grant_65, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 10, &rev_65, ed25519_verify_callback, nil, scratch_65), Grant_Check_Status.Refused_Revoked)
	testing.expect_value(t, rev_65.slow_tier_uses, u64(1))
	testing.expect_value(t, signed_grant_check(&grant_66, &grantor_list, machine_entry.machine_id, grantee_root_pub, issued + 10, &rev_65, ed25519_verify_callback, nil, scratch_65), Grant_Check_Status.Accepted)
	testing.expect_value(t, rev_65.slow_tier_uses, u64(2))

	// 4. Larger tier (256 revocations): validates cleanly, refuses unsorted/duplicate/zero serial past 64,
	//    and refused apply_update leaves state unchanged.
	serials_256 := make([]u64, 256)
	defer delete(serials_256)
	for i in 0 ..< len(serials_256) {
		serials_256[i] = u64((i + 1) * 10)
	}
	rev_256 := Revocation_List {
		grantor_root_public_key = grantor_root_pub,
		signer_public_key       = machine_entry.signing_public_key,
		epoch                   = 3,
		revoked_count           = 256,
		external_serials        = serials_256,
	}
	sign_revocation_list(&rev_256, &machine_signing_priv)
	scratch_256 := make([]u8, revocation_list_signing_bytes_size(256))
	defer delete(scratch_256)

	state := rev_64
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &state, true, &rev_256, ed25519_verify_callback, nil, scratch_256), Revocation_List_Status.Accepted)
	testing.expect_value(t, state.epoch, u64(3))
	testing.expect_value(t, state.revoked_count, u16(256))
	testing.expect_value(t, state.slow_tier_uses, u64(1))
	testing.expect(t, revocation_list_contains_serial(&state, 2560))
	testing.expect(t, !revocation_list_contains_serial(&state, 2555))

	// A second slow-tier update preserves and increments cumulative slow_tier_uses on state.
	rev_256_next := rev_256
	rev_256_next.epoch = 4
	rev_256_next.slow_tier_uses = 0
	sign_revocation_list(&rev_256_next, &machine_signing_priv)
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &state, true, &rev_256_next, ed25519_verify_callback, nil, scratch_256), Revocation_List_Status.Accepted)
	testing.expect_value(t, state.epoch, u64(4))
	testing.expect_value(t, state.slow_tier_uses, u64(2))

	// Unsorted entry at index 200 refused, leaving state unchanged.
	bad_serials := make([]u64, 256)
	defer delete(bad_serials)
	copy(bad_serials, serials_256)
	bad_serials[200] = bad_serials[199]
	bad_rev := rev_256
	bad_rev.epoch = 5
	bad_rev.external_serials = bad_serials
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &state, true, &bad_rev, ed25519_verify_callback, nil, scratch_256), Revocation_List_Status.Refused_Not_Strictly_Sorted)
	testing.expect_value(t, state.epoch, u64(4))
	testing.expect_value(t, state.slow_tier_uses, u64(2))

	// Zero serial at index 200 refused.
	bad_serials[200] = 0
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &state, true, &bad_rev, ed25519_verify_callback, nil, scratch_256), Revocation_List_Status.Refused_Zero_Serial)
	testing.expect_value(t, state.epoch, u64(4))

	// External slice shorter than revoked_count refused.
	short_rev := rev_256
	short_rev.epoch = 5
	short_rev.external_serials = serials_256[:255]
	testing.expect_value(t, revocation_list_apply_update(&grantor_list, &state, true, &short_rev, ed25519_verify_callback, nil, scratch_256), Revocation_List_Status.Refused_Too_Many_Entries)
	testing.expect_value(t, state.epoch, u64(4))
}
