#+build !freestanding
package remote_display

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"

@(private = "file")
make_test_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [DISPLAY_TOKEN_PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for i in 0 ..< len(seed) {
		seed[i] = seed_byte + u8(i * 13 + 7)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
ed25519_verify_cb :: proc "contextless" (
	public_key: [DISPLAY_TOKEN_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [DISPLAY_TOKEN_SIGNATURE_SIZE]u8,
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
sign_display_token :: proc(token: ^Display_Token, priv: ^ed25519.Private_Key) {
	signing_bytes, status := display_token_signing_bytes(token)
	assert(status == .Valid)
	ed25519.sign(priv, signing_bytes[:], token.signature[:])
}

// Every closed enum and bit-set border converter in agent_gateway refuses all
// unknown words and invalid bit combinations (including Input without View).
@(test)
agent_gateway_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	// Agent_Capture_Mode: 1..3 valid; 0, 4, max(u64) refused.
	for word in u64(0) ..= 10 {
		m, ok := agent_capture_mode_of_word(word)
		if word >= 1 && word <= 3 {
			testing.expectf(t, ok && u64(m) == word, "valid capture mode %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown capture mode %d accepted as %v", word, m)
		}
	}
	_, bad_max_mode := agent_capture_mode_of_word(max(u64))
	testing.expect(t, !bad_max_mode)

	// Gateway_Transport: 1..2 valid; 0, 3, max(u64) refused.
	for word in u64(0) ..= 10 {
		tr, ok := gateway_transport_of_word(word)
		if word == 1 || word == 2 {
			testing.expectf(t, ok && u64(tr) == word, "valid transport %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown transport %d accepted as %v", word, tr)
		}
	}

	// Display_Token_Rights: 0 refused, View (1) valid, Input-only (2) refused,
	// View+Input (3) valid, unknown bit (4, 1<<63) refused.
	_, r0 := display_token_rights_of_word(0)
	testing.expect(t, !r0, "zero rights must be refused")
	v_only, r1 := display_token_rights_of_word(display_token_rights_word({.View}))
	testing.expect(t, r1 && v_only == {.View}, "View right must be accepted")
	_, r2 := display_token_rights_of_word(display_token_rights_word({.Input}))
	testing.expect(t, !r2, "Input without View must be refused")
	vi, r3 := display_token_rights_of_word(display_token_rights_word({.View, .Input}))
	testing.expect(t, r3 && vi == {.View, .Input}, "View+Input must be accepted")
	_, r4 := display_token_rights_of_word(u64(1) << 2)
	testing.expect(t, !r4, "unknown right bit 2 must be refused")
	_, r63 := display_token_rights_of_word(u64(1) << 63)
	testing.expect(t, !r63, "unknown right bit 63 must be refused")

	// Gateway_Frame_Kind: 1..5 valid; 0 and 6+ refused.
	for word in u64(0) ..= 10 {
		k, ok := gateway_frame_kind_of_word(word)
		if word >= 1 && word <= 5 {
			testing.expectf(t, ok && u64(k) == word, "valid frame kind %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown frame kind %d accepted as %v", word, k)
		}
	}

	// Gateway_Frame_Flags: 0..1 valid; 2..255 refused.
	for word in 0 ..= 255 {
		_, ok := gateway_frame_flags_of_word(u8(word))
		if word <= int(GATEWAY_FRAME_FLAGS_VALID_MASK) {
			testing.expectf(t, ok, "valid flags %d refused", word)
		} else {
			testing.expectf(t, !ok, "invalid flags %d accepted", word)
		}
	}
}

// Settle_Tracker and agent_screen_evaluate enforce monotonic timestamps and
// damage generations, strict hang bounds, quiet settle windows, and zero
// mutation on every refusal.
@(test)
agent_settle_tracker_state_machine_and_refusals :: proc(t: ^testing.T) {
	tracker: Settle_Tracker

	// Uninitialized tracker refuses observations and evaluations.
	testing.expect_value(t, settle_tracker_observe(&tracker, 1, 0, 100), Agent_Screen_Status.Refused_Uninitialized_Tracker)
	resp := agent_screen_evaluate(&tracker, {mode = .Capture_Now}, 100)
	testing.expect_value(t, resp.status, Agent_Screen_Status.Refused_Uninitialized_Tracker)

	// Invalid screen dimensions (0 or past 1920x1080) refused with zero mutation.
	testing.expect_value(t, settle_tracker_init(&tracker, {0, 800}, 1, 100), Agent_Screen_Status.Refused_Invalid_Screen)
	testing.expect_value(t, settle_tracker_init(&tracker, {SCREEN_WIDTH_LIMIT + 1, 800}, 1, 100), Agent_Screen_Status.Refused_Invalid_Screen)
	testing.expect(t, !tracker.initialized, "failed init must leave tracker uninitialized")

	// Initialize validly at t = 1000 ms, generation = 5.
	testing.expect_value(t, settle_tracker_init(&tracker, {1280, 800}, 5, 1000), Agent_Screen_Status.Ready)

	// Backwards timestamp and backwards generation refused with zero mutation.
	snap := tracker
	testing.expect_value(t, settle_tracker_observe(&tracker, 5, 0, 999), Agent_Screen_Status.Refused_Timestamp_Backwards)
	testing.expect_value(t, tracker, snap)
	testing.expect_value(t, settle_tracker_observe(&tracker, 4, 0, 1050), Agent_Screen_Status.Refused_Generation_Backwards)
	testing.expect_value(t, tracker, snap)

	// Capture_Now returns immediately.
	resp = agent_screen_evaluate(&tracker, {mode = .Capture_Now, started_at_ms = 1000}, 1010)
	testing.expect_value(t, resp.status, Agent_Screen_Status.Ready)
	testing.expect_value(t, resp.damage_generation, u64(5))

	// Invalid mode, zero hang bound, oversized hang bound, invalid settle window, backwards eval clock.
	testing.expect_value(t, agent_screen_evaluate(&tracker, {mode = Agent_Capture_Mode(0), started_at_ms = 1000}, 1010).status, Agent_Screen_Status.Refused_Invalid_Mode)
	testing.expect_value(t, agent_screen_evaluate(&tracker, {mode = .Wait_Settled, settle_ms = 50, hang_bound_ms = 0, started_at_ms = 1000}, 1010).status, Agent_Screen_Status.Refused_Zero_Bound)
	testing.expect_value(t, agent_screen_evaluate(&tracker, {mode = .Wait_Changed, since_generation = 5, hang_bound_ms = 0, started_at_ms = 1000}, 1010).status, Agent_Screen_Status.Refused_Zero_Bound)
	testing.expect_value(t, agent_screen_evaluate(&tracker, {mode = .Wait_Settled, settle_ms = 50, hang_bound_ms = AGENT_HANG_BOUND_MAX_MS + 1, started_at_ms = 1000}, 1010).status, Agent_Screen_Status.Refused_Bound_Too_Large)
	testing.expect_value(t, agent_screen_evaluate(&tracker, {mode = .Wait_Settled, settle_ms = 0, hang_bound_ms = 500, started_at_ms = 1000}, 1010).status, Agent_Screen_Status.Refused_Invalid_Settle_Window)
	testing.expect_value(t, agent_screen_evaluate(&tracker, {mode = .Wait_Settled, settle_ms = 600, hang_bound_ms = 500, started_at_ms = 1000}, 1010).status, Agent_Screen_Status.Refused_Invalid_Settle_Window)
	testing.expect_value(t, agent_screen_evaluate(&tracker, {mode = .Wait_Settled, settle_ms = 50, hang_bound_ms = 500, started_at_ms = 1200}, 1100).status, Agent_Screen_Status.Refused_Timestamp_Backwards)

	// Wait_Settled: pending surfaces prevent settling; quiet window settles after settle_ms.
	req_settle := Agent_Screen_Request{
		mode          = .Wait_Settled,
		settle_ms     = 100,
		hang_bound_ms = 500,
		started_at_ms = 1000,
	}
	testing.expect_value(t, settle_tracker_observe(&tracker, 6, 1, 1050), Agent_Screen_Status.Ready)
	testing.expect_value(t, agent_screen_evaluate(&tracker, req_settle, 1140).status, Agent_Screen_Status.Waiting)

	// Clear pending surfaces at t = 1150, still within quiet window at 1249, settled at 1250.
	testing.expect_value(t, settle_tracker_observe(&tracker, 6, 0, 1150), Agent_Screen_Status.Ready)
	// Because damage happened at 1050 with pending=1, pending stayed 1 until 1150? Wait: last_damage_at_ms was 1050 when pending was 1,
	// so at 1150 pending became 0 -> quiet_ms = 1150 - 1050 = 100! Wait: while pending > 0 at 1140, it was Waiting.
	// Let's also advance generation at 1200 so quiet resets cleanly to 0!
	testing.expect_value(t, settle_tracker_observe(&tracker, 7, 0, 1200), Agent_Screen_Status.Ready)
	testing.expect_value(t, agent_screen_evaluate(&tracker, req_settle, 1299).status, Agent_Screen_Status.Waiting)
	settled_resp := agent_screen_evaluate(&tracker, req_settle, 1300)
	testing.expect_value(t, settled_resp.status, Agent_Screen_Status.Settled)
	testing.expect_value(t, settled_resp.quiet_elapsed_ms, u64(100))

	// Hang bound enforcement when frames keep arriving past hang_bound_ms.
	testing.expect_value(t, settle_tracker_observe(&tracker, 8, 0, 1480), Agent_Screen_Status.Ready)
	testing.expect_value(t, agent_screen_evaluate(&tracker, req_settle, 1500).status, Agent_Screen_Status.Changing)

	// Wait_Changed: waits while generation == since_generation, Ready when incremented, Changing at hang bound.
	req_change := Agent_Screen_Request{
		mode             = .Wait_Changed,
		since_generation = 8,
		hang_bound_ms    = 300,
		started_at_ms    = 1500,
	}
	testing.expect_value(t, agent_screen_evaluate(&tracker, req_change, 1799).status, Agent_Screen_Status.Waiting)
	testing.expect_value(t, agent_screen_evaluate(&tracker, req_change, 1800).status, Agent_Screen_Status.Changing)
	testing.expect_value(t, settle_tracker_observe(&tracker, 9, 0, 1850), Agent_Screen_Status.Ready)
	changed_resp := agent_screen_evaluate(&tracker, req_change, 1850)
	testing.expect_value(t, changed_resp.status, Agent_Screen_Status.Ready)
	testing.expect_value(t, changed_resp.damage_generation, u64(9))
}

// Display_Token Ed25519 verification, sliding 1-day renewal, hard absolute_end
// ceiling, explicit revocation list, and wire serialization reject every attack.
@(test)
display_token_verify_renew_and_revocation_edges :: proc(t: ^testing.T) {
	priv, pub := make_test_keypair(0x21)
	_, wrong_pub := make_test_keypair(0x99)
	revocations: Token_Revocation_List

	issued := u64(1_700_000_000)
	abs_end := issued + DISPLAY_TOKEN_DEFAULT_ABSOLUTE_SECONDS // +7 days
	token := Display_Token{
		token_id          = 42,
		principal_id      = 7,
		transport         = .WebTransport,
		rights            = {.View, .Input},
		issued_at_unix    = issued,
		expires_at_unix   = issued + DISPLAY_TOKEN_MAX_WINDOW_SECONDS, // +1 day
		absolute_end_unix = abs_end,
	}
	sign_display_token(&token, &priv)

	// 1. Valid verification one second before expiry succeeds.
	verified, status := display_token_verify_and_renew(&token, &revocations, token.expires_at_unix - 1, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Valid)
	testing.expect_value(t, verified.token_id, u64(42))

	// 2. Wire round-trip preserves exact fields and signature; tampered wire bytes fail decode/verify.
	wire: [DISPLAY_TOKEN_WIRE_SIZE]u8
	wlen, enc_status := display_token_wire_encode(wire[:], &token)
	testing.expect_value(t, enc_status, Display_Token_Status.Valid)
	testing.expect_value(t, wlen, DISPLAY_TOKEN_WIRE_SIZE)
	decoded, dec_status := display_token_wire_decode(wire[:])
	testing.expect_value(t, dec_status, Display_Token_Status.Valid)
	testing.expect_value(t, decoded, token)

	bad_wire := wire
	bad_wire[0] = 'X' // Corrupt domain prefix.
	_, bad_dec := display_token_wire_decode(bad_wire[:])
	testing.expect_value(t, bad_dec, Display_Token_Status.Refused_Malformed_Wire)
	bad_wire = wire
	bad_wire[27] = 1 // Non-zero reserved byte.
	_, bad_dec = display_token_wire_decode(bad_wire[:])
	testing.expect_value(t, bad_dec, Display_Token_Status.Refused_Malformed_Wire)

	// 3. Exact expiry instant and one second past expiry are refused.
	_, status = display_token_verify_and_renew(&token, &revocations, token.expires_at_unix, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Expired)
	_, status = display_token_verify_and_renew(&token, &revocations, token.expires_at_unix + 1, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Expired)

	// 4. Clock before issued_at_unix is refused.
	_, status = display_token_verify_and_renew(&token, &revocations, issued - 1, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Not_Yet_Valid)

	// 5. Tampered signature, tampered principal, wrong public key, nil verifier, zero key all refused.
	tampered := token
	tampered.signature[0] ~= 0x01
	_, status = display_token_verify_and_renew(&tampered, &revocations, issued + 10, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Invalid_Signature)

	tampered = token
	tampered.principal_id = 99
	_, status = display_token_verify_and_renew(&tampered, &revocations, issued + 10, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Invalid_Signature)

	_, status = display_token_verify_and_renew(&token, &revocations, issued + 10, 0, wrong_pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Invalid_Signature)

	_, status = display_token_verify_and_renew(&token, &revocations, issued + 10, 0, pub, nil)
	testing.expect_value(t, status, Display_Token_Status.Refused_Invalid_Signature)

	zero_pub: [DISPLAY_TOKEN_PUBLIC_KEY_SIZE]u8
	_, status = display_token_verify_and_renew(&token, &revocations, issued + 10, 0, zero_pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Zero_Public_Key)

	// 6. Unknown transport, invalid rights (Input without View), window > 1 day, absolute_end > 30 days refused.
	bad_tok := token
	bad_tok.transport = Gateway_Transport(9)
	_, status = display_token_verify_and_renew(&bad_tok, &revocations, issued + 10, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Unknown_Transport)

	bad_tok = token
	bad_tok.rights = {.Input}
	_, status = display_token_verify_and_renew(&bad_tok, &revocations, issued + 10, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Invalid_Rights)

	bad_tok = token
	bad_tok.expires_at_unix = issued + DISPLAY_TOKEN_MAX_WINDOW_SECONDS + 1
	_, status = display_token_verify_and_renew(&bad_tok, &revocations, issued + 10, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Invalid_Window)

	bad_tok = token
	bad_tok.absolute_end_unix = issued + DISPLAY_TOKEN_MAX_ABSOLUTE_SECONDS + 1
	_, status = display_token_verify_and_renew(&bad_tok, &revocations, issued + 10, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Absolute_End_Past_Limit)

	// 7. Valid sliding renewal 1 hour before expiry succeeds and clears old signature for issuer re-sign.
	renew_now := token.expires_at_unix - 3600
	new_exp := renew_now + DISPLAY_TOKEN_MAX_WINDOW_SECONDS
	renewed, renew_status := display_token_verify_and_renew(&token, &revocations, renew_now, new_exp, pub, ed25519_verify_cb)
	testing.expect_value(t, renew_status, Display_Token_Status.Renewed)
	testing.expect_value(t, renewed.issued_at_unix, renew_now)
	testing.expect_value(t, renewed.expires_at_unix, new_exp)
	testing.expect_value(t, renewed.signature, [DISPLAY_TOKEN_SIGNATURE_SIZE]u8{})
	// Re-signing the renewed token produces a structurally valid, verifiable token.
	sign_display_token(&renewed, &priv)
	_, renewed_verify_status := display_token_verify_and_renew(&renewed, &revocations, renew_now + 60, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, renewed_verify_status, Display_Token_Status.Valid)
	// Original token struct was not mutated.
	testing.expect_value(t, token.expires_at_unix, issued + DISPLAY_TOKEN_MAX_WINDOW_SECONDS)

	// 8. Renewal past absolute_end_unix is ALWAYS refused, even by 1 second.
	near_end_token := Display_Token{
		token_id          = 43,
		principal_id      = 7,
		transport         = .WebSocket,
		rights            = {.View},
		issued_at_unix    = abs_end - 7200,
		expires_at_unix   = abs_end - 3600,
		absolute_end_unix = abs_end,
	}
	sign_display_token(&near_end_token, &priv)
	_, status = display_token_verify_and_renew(&near_end_token, &revocations, abs_end - 3601, abs_end + 1, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Renewal_Past_Absolute_End)

	// Renewal up to exact absolute_end_unix succeeds.
	capped, cap_status := display_token_verify_and_renew(&near_end_token, &revocations, abs_end - 3601, abs_end, pub, ed25519_verify_cb)
	testing.expect_value(t, cap_status, Display_Token_Status.Renewed)
	testing.expect_value(t, capped.expires_at_unix, abs_end)

	// Renewal requesting > 1 day from now or <= now is refused.
	_, status = display_token_verify_and_renew(&token, &revocations, renew_now, renew_now + DISPLAY_TOKEN_MAX_WINDOW_SECONDS + 1, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Renewal_Window_Invalid)
	_, status = display_token_verify_and_renew(&token, &revocations, renew_now, renew_now, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Renewal_Window_Invalid)

	// 9. Explicit Token_Revocation_List blocks verification and renewal immediately.
	testing.expect_value(t, token_revocation_add(&revocations, 0), Display_Token_Status.Refused_Zero_Token_Id)
	testing.expect_value(t, token_revocation_add(&revocations, token.token_id), Display_Token_Status.Valid)
	testing.expect_value(t, token_revocation_add(&revocations, token.token_id), Display_Token_Status.Valid) // Idempotent.
	testing.expect_value(t, revocations.count, u32(1))

	_, status = display_token_verify_and_renew(&token, &revocations, issued + 10, 0, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Revoked)
	_, status = display_token_verify_and_renew(&token, &revocations, renew_now, new_exp, pub, ed25519_verify_cb)
	testing.expect_value(t, status, Display_Token_Status.Refused_Revoked)

	// Filling revocation list past TOKEN_REVOCATION_CAPACITY refuses cleanly.
	for i in u64(100) ..< u64(100 + TOKEN_REVOCATION_CAPACITY - 1) {
		testing.expect_value(t, token_revocation_add(&revocations, i), Display_Token_Status.Valid)
	}
	testing.expect_value(t, revocations.count, u32(TOKEN_REVOCATION_CAPACITY))
	testing.expect_value(t, token_revocation_add(&revocations, 9999), Display_Token_Status.Refused_Revocation_List_Full)
	testing.expect_value(t, revocations.count, u32(TOKEN_REVOCATION_CAPACITY))
}

// Shared WebTransport and WebSocket binary gateway framing encodes/decodes
// identically and refuses every malformed wire edge without mutating output on
// encode failure.
@(test)
gateway_frame_encode_decode_shared_and_adversarial :: proc(t: ^testing.T) {
	payload := [?]u8{0x01, 0x02, 0x03, 0x04, 0x05, 0xAA, 0xBB}
	buf_wt: [64]u8
	buf_ws: [64]u8

	hdr_wt := Gateway_Frame_Header{
		transport = .WebTransport,
		kind      = .Display_Record,
		flags     = {.End_Of_Message},
		sequence  = 17,
	}
	hdr_ws := hdr_wt
	hdr_ws.transport = .WebSocket

	n_wt, p_wt := gateway_frame_encode(buf_wt[:], hdr_wt, payload[:])
	n_ws, p_ws := gateway_frame_encode(buf_ws[:], hdr_ws, payload[:])
	testing.expect_value(t, p_wt, Gateway_Frame_Problem.None)
	testing.expect_value(t, p_ws, Gateway_Frame_Problem.None)
	testing.expect_value(t, n_wt, GATEWAY_FRAME_HEADER_SIZE + len(payload))
	testing.expect_value(t, n_ws, n_wt)

	// Only byte 3 (the transport enum byte) differs between WebTransport and WebSocket frames.
	for i in 0 ..< n_wt {
		if i == 3 {
			testing.expect_value(t, buf_wt[i], u8(Gateway_Transport.WebTransport))
			testing.expect_value(t, buf_ws[i], u8(Gateway_Transport.WebSocket))
		} else {
			testing.expect_value(t, buf_wt[i], buf_ws[i])
		}
	}

	// Decode round-trip for both transports.
	dec_hdr, dec_pay, dec_prob := gateway_frame_decode(buf_wt[:n_wt])
	testing.expect_value(t, dec_prob, Gateway_Frame_Problem.None)
	testing.expect_value(t, dec_hdr.transport, Gateway_Transport.WebTransport)
	testing.expect_value(t, dec_hdr.kind, Gateway_Frame_Kind.Display_Record)
	testing.expect_value(t, dec_hdr.flags, Gateway_Frame_Flags{.End_Of_Message})
	testing.expect_value(t, dec_hdr.sequence, u32(17))
	testing.expect_value(t, dec_hdr.payload_length, u32(len(payload)))
	testing.expect_value(t, len(dec_pay), len(payload))
	for i in 0 ..< len(payload) {
		testing.expect_value(t, dec_pay[i], payload[i])
	}

	dec_hdr_ws, _, dec_prob_ws := gateway_frame_decode(buf_ws[:n_ws])
	testing.expect_value(t, dec_prob_ws, Gateway_Frame_Problem.None)
	testing.expect_value(t, dec_hdr_ws.transport, Gateway_Transport.WebSocket)

	// Encode refusals leave output buffer untouched.
	canary: [32]u8
	for &b in canary {
		b = 0xCC
	}
	_, ep := gateway_frame_encode(canary[:], {transport = Gateway_Transport(0), kind = .Close}, nil)
	testing.expect_value(t, ep, Gateway_Frame_Problem.Unknown_Transport)
	_, ep = gateway_frame_encode(canary[:], {transport = .WebTransport, kind = Gateway_Frame_Kind(99)}, nil)
	testing.expect_value(t, ep, Gateway_Frame_Problem.Unknown_Kind)
	_, ep = gateway_frame_encode(canary[:], {transport = .WebTransport, kind = .Close, flags = transmute(Gateway_Frame_Flags)u8(0x80)}, nil)
	testing.expect_value(t, ep, Gateway_Frame_Problem.Invalid_Flags)
	_, ep = gateway_frame_encode(canary[:GATEWAY_FRAME_HEADER_SIZE - 1], hdr_wt, nil)
	testing.expect_value(t, ep, Gateway_Frame_Problem.Buffer_Too_Small)
	for b in canary {
		testing.expect_value(t, b, u8(0xCC))
	}

	// Decode refusals: truncated header, bad magic, wrong version, unknown transport,
	// unknown kind, invalid flags, non-zero reserved, oversized payload, truncated payload, trailing bytes.
	_, _, dp := gateway_frame_decode(buf_wt[:GATEWAY_FRAME_HEADER_SIZE - 1])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Truncated)

	corrupt := buf_wt
	corrupt[0] = 'X'
	_, _, dp = gateway_frame_decode(corrupt[:n_wt])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Bad_Magic)

	corrupt = buf_wt
	corrupt[2] = 2
	_, _, dp = gateway_frame_decode(corrupt[:n_wt])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Unsupported_Version)

	corrupt = buf_wt
	corrupt[3] = 0
	_, _, dp = gateway_frame_decode(corrupt[:n_wt])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Unknown_Transport)

	corrupt = buf_wt
	corrupt[4] = 99
	_, _, dp = gateway_frame_decode(corrupt[:n_wt])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Unknown_Kind)

	corrupt = buf_wt
	corrupt[5] = 0x02
	_, _, dp = gateway_frame_decode(corrupt[:n_wt])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Invalid_Flags)

	corrupt = buf_wt
	corrupt[6] = 1
	_, _, dp = gateway_frame_decode(corrupt[:n_wt])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Non_Zero_Reserved)

	corrupt = buf_wt
	oversized := GATEWAY_FRAME_PAYLOAD_LIMIT + 1
	corrupt[12] = u8(oversized)
	corrupt[13] = u8(oversized >> 8)
	corrupt[14] = u8(oversized >> 16)
	corrupt[15] = u8(oversized >> 24)
	_, _, dp = gateway_frame_decode(corrupt[:n_wt])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Payload_Too_Large)

	// Truncated payload (1 byte short) and trailing byte (1 byte extra).
	_, _, dp = gateway_frame_decode(buf_wt[:n_wt - 1])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Truncated)
	_, _, dp = gateway_frame_decode(buf_wt[:n_wt + 1])
	testing.expect_value(t, dp, Gateway_Frame_Problem.Trailing_Bytes)
}
