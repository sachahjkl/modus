#+build !freestanding
#+build !modus
package wide_grants

import "base:runtime"
import "core:testing"
import "modus:contract/blake3"
import ed25519 "core:crypto/ed25519"

@(private = "file")
test_headless_hash :: proc(label: string) -> blake3.Hash {
	raw := transmute([]u8)label
	return blake3.hash(raw)
}

@(private = "file")
test_ed25519_verify :: proc "contextless" (
	public_key: [HEADLESS_PROOF_KEY_BYTES]u8,
	message: []u8,
	signature: [HEADLESS_PROOF_SIGNATURE_BYTES]u8,
) -> bool {
	context = runtime.default_context()
	pub: ed25519.Public_Key
	raw_pub := public_key
	raw_sig := signature
	if !ed25519.public_key_set_bytes(&pub, raw_pub[:]) {
		return false
	}
	return ed25519.verify(&pub, message, raw_sig[:])
}

@(private = "file")
test_sign_headless_proof :: proc(
	t: ^testing.T,
	seed: [32]u8,
	machine_id: [32]u8,
	principal_id: u64,
	client_key: [32]u8,
	authorities: Wide_Authorities,
	nonce: [32]u8,
	duration_ms: u64,
	issued_at_ms: u64,
) -> (proof: Headless_Wide_Grant_Proof, host_pub: [32]u8) {
	priv: ed25519.Private_Key
	local_seed := seed
	ok := ed25519.private_key_set_bytes(&priv, local_seed[:])
	testing.expect(t, ok, "private_key_set_bytes returned false")
	ed25519.private_key_public_bytes(&priv, host_pub[:])

	proof = Headless_Wide_Grant_Proof {
		version          = HEADLESS_PROOF_VERSION,
		machine_id       = machine_id,
		principal_id     = principal_id,
		client_key       = client_key,
		authorities_word = wide_authorities_to_word(authorities),
		nonce            = nonce,
		duration_ms      = duration_ms,
		issued_at_ms     = issued_at_ms,
		host_public_key  = host_pub,
	}
	signing_buf: [HEADLESS_PROOF_SIGNING_BYTES]u8
	written, refusal := headless_proof_signing_bytes(&proof, signing_buf[:])
	testing.expect_value(t, refusal, Headless_Proof_Refusal.None)
	testing.expect_value(t, written, HEADLESS_PROOF_SIGNING_BYTES)
	ed25519.sign(&priv, signing_buf[:written], proof.signature[:])
	return proof, host_pub
}

@(test)
test_headless_proof_refusal_border_parser :: proc(t: ^testing.T) {
	if _, ok := headless_proof_refusal_from_word(u64(max(Headless_Proof_Refusal)) + 1); ok {
		testing.fail_now(t, "headless_proof_refusal_from_word accepted one past max")
	}
	if _, ok := headless_proof_refusal_from_word(max(u64)); ok {
		testing.fail_now(t, "headless_proof_refusal_from_word accepted max(u64)")
	}
	for expected in Headless_Proof_Refusal {
		parsed, ok := headless_proof_refusal_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}
}

@(test)
test_headless_proof_wire_roundtrip_and_refusals :: proc(t: ^testing.T) {
	seed := test_headless_hash("host-seed-1")
	machine_id := test_headless_hash("machine-id-1")
	client_key := test_headless_hash("client-key-1")
	nonce := test_headless_hash("nonce-1")

	proof, host_pub := test_sign_headless_proof(
		t,
		seed,
		machine_id,
		2,
		client_key,
		{.View_Screen, .Send_Input},
		nonce,
		DEFAULT_WIDE_GRANT_DURATION_MS,
		5000,
	)

	// Short encode buffer and wrong decode lengths refused.
	short_buf: [HEADLESS_PROOF_WIRE_BYTES - 1]u8
	_, encode_refusal := headless_proof_encode(&proof, short_buf[:])
	testing.expect_value(t, encode_refusal, Headless_Proof_Refusal.Buffer_Too_Small)

	_, decode_short := headless_proof_decode(short_buf[:])
	testing.expect_value(t, decode_short, Headless_Proof_Refusal.Bad_Wire_Length)

	wire_buf: [HEADLESS_PROOF_WIRE_BYTES]u8
	written, ok_enc := headless_proof_encode(&proof, wire_buf[:])
	testing.expect_value(t, ok_enc, Headless_Proof_Refusal.None)
	testing.expect_value(t, written, HEADLESS_PROOF_WIRE_BYTES)

	decoded, ok_dec := headless_proof_decode(wire_buf[:])
	testing.expect_value(t, ok_dec, Headless_Proof_Refusal.None)
	testing.expect_value(t, decoded, proof)

	// Verify decoded proof with real Ed25519 callback.
	cache: Headless_Nonce_Cache
	verified, verify_refusal := headless_wide_grant_proof_verify(&decoded, machine_id, 2, host_pub, 6000, &cache, test_ed25519_verify)
	testing.expect_value(t, verify_refusal, Headless_Proof_Refusal.None)
	testing.expect_value(t, verified.origin, Proof_Origin.Local_Host_Key)
	testing.expect_value(t, verified.kind, Proof_Kind.Host_Key_Signed)
	testing.expect_value(t, verified.principal_id, u64(2))
	testing.expect_value(t, verified.authorities, Wide_Authorities{.View_Screen, .Send_Input})
	testing.expect_value(t, verified.host_key_hash, blake3.hash(host_pub[:]))

	// Replaying the same proof is refused.
	_, replay_refusal := headless_wide_grant_proof_verify(&decoded, machine_id, 2, host_pub, 6001, &cache, test_ed25519_verify)
	testing.expect_value(t, replay_refusal, Headless_Proof_Refusal.Replayed_Nonce)
}

@(test)
test_headless_proof_verify_refuses_every_forgery_and_edge :: proc(t: ^testing.T) {
	seed := test_headless_hash("host-seed-2")
	wrong_seed := test_headless_hash("wrong-host-seed")
	machine_id := test_headless_hash("machine-id-2")
	other_machine := test_headless_hash("machine-id-other")
	client_key := test_headless_hash("client-key-2")
	nonce := test_headless_hash("nonce-2")

	base, host_pub := test_sign_headless_proof(
		t,
		seed,
		machine_id,
		1,
		client_key,
		{.View_Screen, .Read_Semantic_Tree},
		nonce,
		DEFAULT_WIDE_GRANT_DURATION_MS,
		9000,
	)
	now_ms := u64(10_000)
	cache: Headless_Nonce_Cache

	// Nil proof and nil verifier refused.
	_, r := headless_wide_grant_proof_verify(nil, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
	testing.expect_value(t, r, Headless_Proof_Refusal.Nil_Input)

	_, r = headless_wide_grant_proof_verify(&base, machine_id, 1, host_pub, now_ms, &cache, nil)
	testing.expect_value(t, r, Headless_Proof_Refusal.Missing_Verifier)

	// Bad version refused.
	{
		bad := base
		bad.version = 0
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Bad_Version)
	}

	// Zero machine ID and mismatched machine ID refused.
	{
		bad := base
		bad.machine_id = {}
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Zero_Machine_Id)

		_, r = headless_wide_grant_proof_verify(&base, other_machine, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Machine_Id_Mismatch)
	}

	// Principal mismatch and zero client key refused.
	{
		_, r = headless_wide_grant_proof_verify(&base, machine_id, 2, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Principal_Mismatch)

		bad := base
		bad.client_key = {}
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Zero_Client_Key)
	}

	// Empty scopes, unknown scope bits, and Send_Input without View_Screen refused.
	{
		bad := base
		bad.authorities_word = 0
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Bad_Authorities)

		bad.authorities_word = u64(1) << 12
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Bad_Authorities)

		bad.authorities_word = wide_authorities_to_word({.Send_Input})
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Bad_Authorities)
	}

	// Zero nonce, zero duration, and duration past bound refused.
	{
		bad := base
		bad.nonce = {}
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Zero_Nonce)

		bad = base
		bad.duration_ms = 0
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Duration_Zero)

		bad = base
		bad.duration_ms = MAX_WIDE_GRANT_DURATION_MS + 1
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Duration_Past_Bound)
	}

	// Zero issued_at_ms, overflow, stale/expired proof, and future-skew proof refused.
	{
		bad := base
		bad.issued_at_ms = 0
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Zero_Issued_At)

		bad = base
		bad.issued_at_ms = max(u64) - 10
		_, r = headless_wide_grant_proof_verify(&bad, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Timestamp_Overflow)

		// Proof older than HEADLESS_PROOF_MAX_AGE_MS refused.
		_, r = headless_wide_grant_proof_verify(&base, machine_id, 1, host_pub, base.issued_at_ms + HEADLESS_PROOF_MAX_AGE_MS + 1, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Proof_Expired)

		// Proof whose own short duration elapsed is refused even inside max_age_ms.
		short_proof, _ := test_sign_headless_proof(t, seed, machine_id, 1, client_key, {.View_Screen}, nonce, 500, 9000)
		_, r = headless_wide_grant_proof_verify(&short_proof, machine_id, 1, host_pub, 9500, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Proof_Expired)

		// Proof issued further ahead than HEADLESS_PROOF_MAX_FUTURE_SKEW_MS refused.
		future_proof, _ := test_sign_headless_proof(t, seed, machine_id, 1, client_key, {.View_Screen}, nonce, DEFAULT_WIDE_GRANT_DURATION_MS, now_ms + HEADLESS_PROOF_MAX_FUTURE_SKEW_MS + 1)
		_, r = headless_wide_grant_proof_verify(&future_proof, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Proof_From_Future)
	}

	// Zero host key, mismatched host key, zero signature, tampered field, and wrong signer refused.
	{
		_, r = headless_wide_grant_proof_verify(&base, machine_id, 1, {}, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Zero_Host_Key)

		wrong_proof, wrong_pub := test_sign_headless_proof(
			t,
			wrong_seed,
			machine_id,
			1,
			client_key,
			{.View_Screen},
			nonce,
			DEFAULT_WIDE_GRANT_DURATION_MS,
			9000,
		)
		_, r = headless_wide_grant_proof_verify(&wrong_proof, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Host_Key_Mismatch)

		// Copy wrong_proof's signature onto base (host_pub matches, signature fails).
		forged := base
		forged.signature = wrong_proof.signature
		_, r = headless_wide_grant_proof_verify(&forged, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Signature_Refused)

		// Single-bit mutation of issued_at_ms breaks signature without caching nonce.
		tampered := base
		tampered.issued_at_ms += 1
		_, r = headless_wide_grant_proof_verify(&tampered, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Signature_Refused)

		zero_sig := base
		zero_sig.signature = {}
		_, r = headless_wide_grant_proof_verify(&zero_sig, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
		testing.expect_value(t, r, Headless_Proof_Refusal.Zero_Signature)

		// Verify wrong_pub is distinct and cache stayed untouched by all refusals above.
		testing.expect(t, wrong_pub != host_pub)
		testing.expect_value(t, cache.count, u32(0))
	}

	// Original valid proof still succeeds after all refused attempts.
	_, ok_r := headless_wide_grant_proof_verify(&base, machine_id, 1, host_pub, now_ms, &cache, test_ed25519_verify)
	testing.expect_value(t, ok_r, Headless_Proof_Refusal.None)
	testing.expect_value(t, cache.count, u32(1))

	// Evicting base's nonce past HEADLESS_NONCE_CACHE_CAPACITY still refuses replaying base.
	for index in u64(0) ..< u64(HEADLESS_NONCE_CACHE_CAPACITY + 2) {
		fresh_nonce := nonce
		fresh_nonce[0] ~= u8(index + 1)
		fresh_nonce[1] = u8((index + 1) >> 8)
		ts := now_ms + index + 1
		fresh, _ := test_sign_headless_proof(t, seed, machine_id, 1, client_key, {.View_Screen}, fresh_nonce, DEFAULT_WIDE_GRANT_DURATION_MS, ts)
		_, fresh_r := headless_wide_grant_proof_verify(&fresh, machine_id, 1, host_pub, ts, &cache, test_ed25519_verify)
		testing.expect_value(t, fresh_r, Headless_Proof_Refusal.None)
	}
	_, evicted_replay_r := headless_wide_grant_proof_verify(&base, machine_id, 1, host_pub, now_ms + 100, &cache, test_ed25519_verify)
	testing.expect_value(t, evicted_replay_r, Headless_Proof_Refusal.Proof_Expired)
}

@(test)
test_session_lock_terminates_principal_grants_and_emits_end_records :: proc(t: ^testing.T) {
	table: Wide_Grant_Session_Table

	// Refusal checks on registration (including started_at_ms + duration_ms overflow).
	testing.expect_value(t, wide_grant_session_register(&table, 0, 1, {.View_Screen}, 100, 1000), Headless_Proof_Refusal.Zero_Grant_Serial)
	testing.expect_value(t, wide_grant_session_register(&table, 10, 1, {.Send_Input}, 100, 1000), Headless_Proof_Refusal.Bad_Authorities)
	testing.expect_value(t, wide_grant_session_register(&table, 10, 1, {.View_Screen}, 100, 0), Headless_Proof_Refusal.Duration_Zero)
	testing.expect_value(t, wide_grant_session_register(&table, 10, 1, {.View_Screen}, 100, MAX_WIDE_GRANT_DURATION_MS + 1), Headless_Proof_Refusal.Duration_Past_Bound)
	testing.expect_value(t, wide_grant_session_register(&table, 10, 1, {.View_Screen}, max(u64) - 500, 1000), Headless_Proof_Refusal.Timestamp_Overflow)

	// Register two grants for principal 1 and one grant for principal 2.
	testing.expect_value(t, wide_grant_session_register(&table, 101, 1, {.View_Screen}, 1000, DEFAULT_WIDE_GRANT_DURATION_MS), Headless_Proof_Refusal.None)
	testing.expect_value(t, wide_grant_session_register(&table, 102, 1, {.View_Screen, .Send_Input}, 2000, DEFAULT_WIDE_GRANT_DURATION_MS), Headless_Proof_Refusal.None)
	testing.expect_value(t, wide_grant_session_register(&table, 201, 2, {.View_Screen}, 1500, DEFAULT_WIDE_GRANT_DURATION_MS), Headless_Proof_Refusal.None)
	testing.expect_value(t, wide_grant_session_register(&table, 101, 1, {.View_Screen}, 1000, DEFAULT_WIDE_GRANT_DURATION_MS), Headless_Proof_Refusal.Duplicate_Grant_Serial)

	// Clock before grant start refused without mutating table or output slice.
	{
		records: [4]Act_Stream_Record
		ended, r := wide_grant_session_lock_end(&table, 1, 1500, records[:])
		testing.expect_value(t, ended, 0)
		testing.expect_value(t, r, Headless_Proof_Refusal.Clock_Went_Back)
		testing.expect_value(t, wide_grant_session_active_count(&table, 1), 2)
	}

	// Short output buffer refused without mutating table or sentinel record.
	{
		short_records: [1]Act_Stream_Record
		short_records[0].grant_serial = 999
		ended, r := wide_grant_session_lock_end(&table, 1, 5000, short_records[:])
		testing.expect_value(t, ended, 0)
		testing.expect_value(t, r, Headless_Proof_Refusal.Buffer_Too_Small)
		testing.expect_value(t, short_records[0].grant_serial, u64(999))
		testing.expect_value(t, wide_grant_session_active_count(&table, 1), 2)
	}

	// Locking principal 1 terminates both of principal 1's grants and emits two
	// valid collector Grant_Revoked(Session_Locked) records while keeping
	// principal 2's grant Active.
	{
		records: [4]Act_Stream_Record
		ended, r := wide_grant_session_lock_end(&table, 1, 5000, records[:])
		testing.expect_value(t, r, Headless_Proof_Refusal.None)
		testing.expect_value(t, ended, 2)
		testing.expect_value(t, wide_grant_session_active_count(&table, 1), 0)
		testing.expect_value(t, wide_grant_session_active_count(&table, 2), 1)
		testing.expect_value(t, table.count, u32(1))

		for index in 0 ..< ended {
			producer, kind, valid_r := act_stream_record_validate(&records[index])
			testing.expect_value(t, valid_r, Act_Wiring_Refusal.None)
			testing.expect_value(t, producer, Act_Producer.Root_Service)
			testing.expect_value(t, kind, Act_Kind.Grant_Revoked)
			testing.expect_value(t, records[index].principal_id, u64(1))
			testing.expect_value(t, records[index].timestamp_ms, u64(5000))
			testing.expect_value(t, records[index].detail_word_0, u64(Revocation_Reason.Session_Locked))
		}
		testing.expect_value(t, records[0].grant_serial, u64(101))
		testing.expect_value(t, records[1].grant_serial, u64(102))
	}

	// Locking principal 1 a second time emits zero records cleanly.
	{
		records: [2]Act_Stream_Record
		ended, r := wide_grant_session_lock_end(&table, 1, 6000, records[:])
		testing.expect_value(t, r, Headless_Proof_Refusal.None)
		testing.expect_value(t, ended, 0)
	}

	// Repeated register+lock cycles past ACTIVE_WIDE_GRANT_TABLE_CAPACITY reclaim slots cleanly.
	{
		records: [1]Act_Stream_Record
		for cycle in u64(0) ..< u64(ACTIVE_WIDE_GRANT_TABLE_CAPACITY * 2 + 3) {
			serial := u64(1000) + cycle
			start_ts := u64(10_000) + cycle * 10
			testing.expect_value(t, wide_grant_session_register(&table, serial, 1, {.View_Screen}, start_ts, DEFAULT_WIDE_GRANT_DURATION_MS), Headless_Proof_Refusal.None)
			ended, lock_r := wide_grant_session_lock_end(&table, 1, start_ts + 5, records[:])
			testing.expect_value(t, lock_r, Headless_Proof_Refusal.None)
			testing.expect_value(t, ended, 1)
			testing.expect_value(t, records[0].grant_serial, serial)
		}
		testing.expect_value(t, wide_grant_session_active_count(&table, 1), 0)
		testing.expect_value(t, wide_grant_session_active_count(&table, 2), 1)
		testing.expect_value(t, table.count, u32(1))
	}
}
