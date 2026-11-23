#+build !freestanding
package wide_grants

import "core:testing"
import "modus:contract/blake3"
import op "modus:contract/operation"
import "modus:contract/output"
import pr "modus:contract/plans_recipes"

@(private = "file")
act_test_hash :: proc(label: string) -> blake3.Hash {
	return blake3.hash(transmute([]u8)label)
}

@(private = "file")
act_test_terms :: proc(principal: u64 = 0) -> Wide_Grant_Terms {
	terms := Wide_Grant_Terms {
		principal_id          = principal,
		grantee_identity_hash = act_test_hash("agent-client-key-1"),
		authorities_word      = wide_authorities_to_word({.View_Screen, .Send_Input}),
		target_window_count   = 2,
		target_window_ids     = {0 = 10, 1 = 20},
		duration_ms           = DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	_ = wide_grant_terms_seal(&terms)
	return terms
}

@(private = "file")
act_test_store_bind :: proc(store: ^Space_Store, principal: u64) -> ^pr.Memory_Private_Store {
	memory := new(pr.Memory_Private_Store)
	space_store_init(store, principal, pr.memory_private_store_port(memory))
	return memory
}

// Authority key initialization refuses weak entropy, unknown Seed_Strength
// words, and an all-zero key. Only a fresh key from Processor/Entropy strength
// becomes Ready, round-trips through the four context value words, verifies a
// minted proof, and refuses another key or any tampered field.
@(test)
test_authority_key_refuses_weak_entropy_zero_key_and_tampering :: proc(t: ^testing.T) {
	fresh_key := act_test_hash("boot-fresh-authority-key-1")
	other_key := act_test_hash("boot-fresh-authority-key-2")
	verifier := act_test_hash("unlock-passphrase-token")
	terms := act_test_terms(0)

	// Refusal 1: Weak entropy (None, Weak, unknown word) refused even with non-zero key.
	auth: Wide_Grant_Authority
	for bad_strength in ([?]op.Seed_Strength{.None, .Weak, op.Seed_Strength(99), op.Seed_Strength(255)}) {
		testing.expect(t, !authority_init_from_bytes(&auth, fresh_key, bad_strength), "weak or unknown entropy must be refused")
		testing.expect_value(t, auth.status, Authority_Key_Status.Refused_Weak_Entropy)
		testing.expect_value(t, auth.key, Authority_Key{})
		_, words_ok := authority_context_words(&auth)
		testing.expect(t, !words_ok, "unready authority must not expose context words")
		_, mint_refusal := authority_mint_proof(&auth, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 1000)
		testing.expect_value(t, mint_refusal, Wide_Grant_Refusal.Invalid_Proof)
	}

	// Refusal 2: All-zero key refused even with strong entropy.
	for good_strength in ([?]op.Seed_Strength{.Processor, .Entropy}) {
		testing.expect(t, !authority_init_from_bytes(&auth, {}, good_strength), "zero key must be refused")
		testing.expect_value(t, auth.status, Authority_Key_Status.Refused_Zero_Key)
		testing.expect_value(t, auth.key, Authority_Key{})
		_, words_ok := authority_context_words(&auth)
		testing.expect(t, !words_ok, "zero-key authority must not expose context words")
	}

	// Success: fresh key from Processor/Entropy strength passes through context words.
	testing.expect(t, authority_init_from_bytes(&auth, fresh_key, .Entropy))
	testing.expect_value(t, auth.status, Authority_Key_Status.Ready)
	words, words_ok := authority_context_words(&auth)
	testing.expect(t, words_ok)
	rebuilt := authority_key_from_words(words)
	testing.expect_value(t, rebuilt, fresh_key)

	// Refusal 3: Remote_Display_Input origin is refused and does not advance proof serial.
	serial_before := auth.next_proof_serial
	_, remote_refusal := authority_mint_proof(&auth, &terms, .Passphrase_Verified, .Remote_Display_Input, verifier, 1000)
	testing.expect_value(t, remote_refusal, Wide_Grant_Refusal.Invalid_Proof)
	testing.expect_value(t, auth.next_proof_serial, serial_before)

	// Success: fresh key mints proof verified by rebuilt collector key.
	proof, mint_refusal := authority_mint_proof(&auth, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 2000)
	testing.expect_value(t, mint_refusal, Wide_Grant_Refusal.None)
	testing.expect_value(t, proof.proof_serial, u64(1))
	testing.expect_value(t, auth.next_proof_serial, u64(2))
	testing.expect_value(t, wide_grant_proof_validate(rebuilt, &terms, &proof, {}, 0), Wide_Grant_Refusal.None)

	// Refusal 4: Another key (from another start) refuses the proof.
	testing.expect_value(t, wide_grant_proof_validate(other_key, &terms, &proof, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	// Refusal 5: All-zero collector key refuses the proof.
	testing.expect_value(t, wide_grant_proof_validate({}, &terms, &proof, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	// Refusal 6: Replay of the same serial is refused.
	testing.expect_value(t, wide_grant_proof_validate(rebuilt, &terms, &proof, {}, 1), Wide_Grant_Refusal.Invalid_Proof)
	// Refusal 7: Tampered grant terms (window added/changed) or tampered proof tag refused.
	tampered_terms := terms
	tampered_terms.target_window_ids[0] = 999
	_ = wide_grant_terms_seal(&tampered_terms)
	testing.expect_value(t, wide_grant_proof_validate(rebuilt, &tampered_terms, &proof, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	tampered_proof := proof
	tampered_proof.proof_tag[0] ~= 0x01
	testing.expect_value(t, wide_grant_proof_validate(rebuilt, &terms, &tampered_proof, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

	// Erase clears the key and blocks subsequent proof minting.
	authority_erase(&auth)
	testing.expect_value(t, auth.status, Authority_Key_Status.Uninitialized)
	testing.expect_value(t, auth.key, Authority_Key{})
	_, after_erase := authority_mint_proof(&auth, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 3000)
	testing.expect_value(t, after_erase, Wide_Grant_Refusal.Invalid_Proof)
}

// Border validation of Act_Producer, Act_Stream_Record, and act_wiring_rows_build
// refuses zero, unknown words, missing target windows, invalid ends, duplicate
// handles, and out-of-range bounds before accepting a valid set.
@(test)
test_act_stream_borders_and_wiring_row_builder :: proc(t: ^testing.T) {
	// Act_Producer border refuses 0, out-of-range, and max(u64).
	for bad in ([?]u64{0, 5, 99, max(u64)}) {
		_, ok := act_producer_from_word(bad)
		testing.expect(t, !ok, "invalid Act_Producer word must be refused")
	}
	for member in Act_Producer {
		if member == .None {
			continue
		}
		parsed, ok := act_producer_from_word(u64(member))
		testing.expect(t, ok && parsed == member)
		from_name, name_ok := act_producer_from_source_name(transmute([]u8)ACT_PRODUCER_NAMES[member])
		testing.expect(t, name_ok && from_name == member)
	}
	_, unknown_name := act_producer_from_source_name(transmute([]u8)string("unknown"))
	testing.expect(t, !unknown_name)

	// Act_Stream_Record border checks.
	good := Act_Stream_Record {
		grant_serial     = 1,
		principal_id     = 0,
		timestamp_ms     = 100,
		producer_word    = u64(Act_Producer.Trusted_Display),
		act_kind_word    = u64(Act_Kind.Key_Injected),
		target_window_id = 42,
		detail_word_0    = 7,
		detail_word_1    = 9,
	}
	no_grant := good
	no_grant.grant_serial = 0
	_, _, r := act_stream_record_validate(&no_grant)
	testing.expect_value(t, r, Act_Wiring_Refusal.No_Active_Grant)

	bad_prod := good
	bad_prod.producer_word = 0
	_, _, r = act_stream_record_validate(&bad_prod)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Producer)

	bad_kind := good
	bad_kind.act_kind_word = 999
	_, _, r = act_stream_record_validate(&bad_kind)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Act_Kind)

	no_window := good
	no_window.target_window_id = 0
	_, _, r = act_stream_record_validate(&no_window)
	testing.expect_value(t, r, Act_Wiring_Refusal.Missing_Target_Window)

	encoded := act_stream_record_encode(&good)
	decoded, dec_ok := act_stream_record_decode(encoded[:])
	testing.expect(t, dec_ok && decoded == good)
	_, short_ok := act_stream_record_decode(encoded[:len(encoded) - 1])
	testing.expect(t, !short_ok)

	// act_wiring_rows_build refusals first.
	endpoints := [3]Act_Producer_Endpoint {
		{producer = .Agent_Console, end = .Started, handle = 2, output_index = 1},
		{producer = .Remote_Service, end = .Started, handle = 3, output_index = 1},
		{producer = .Trusted_Display, end = .Started, handle = 4, output_index = 1},
	}
	rows: [3]output.Wiring
	terms: Space_Terms

	_, r = act_wiring_rows_build(.Started, 1, 1, nil, 256, ACT_SPACE_BOUND_RECORDS, rows[:], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Wiring_End)
	_, r = act_wiring_rows_build(.Child, 1, 1, endpoints[:], 256, ACT_SPACE_BOUND_RECORDS, rows[:], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Wiring_End)
	_, r = act_wiring_rows_build(.Started, 0, 1, endpoints[:], 256, ACT_SPACE_BOUND_RECORDS, rows[:], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Wiring_End)
	_, r = act_wiring_rows_build(.Started, 1, 1, endpoints[:], 256, 0, rows[:], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Bound)
	_, r = act_wiring_rows_build(.Started, 1, 1, endpoints[:], 256, SPACE_RECORDS_MOST + 1, rows[:], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Bound)
	_, r = act_wiring_rows_build(.Started, 1, 1, endpoints[:], 256, ACT_SPACE_BOUND_RECORDS, rows[:2], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Buffer_Too_Small)

	// Duplicate handle with collector refused.
	bad_dup := endpoints
	bad_dup[1].handle = 1
	_, r = act_wiring_rows_build(.Started, 1, 1, bad_dup[:], 256, ACT_SPACE_BOUND_RECORDS, rows[:], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Duplicate_Handle)

	// Duplicate producer refused.
	bad_dup_prod := endpoints
	bad_dup_prod[2].producer = .Remote_Service
	_, r = act_wiring_rows_build(.Started, 1, 1, bad_dup_prod[:], 256, ACT_SPACE_BOUND_RECORDS, rows[:], &terms)
	testing.expect_value(t, r, Act_Wiring_Refusal.Bad_Producer)

	// Success: all three stream endpoints produce valid Always_Holds_Writer Audit rows.
	written, ok_refusal := act_wiring_rows_build(.Started, 1, 1, endpoints[:], 256, ACT_SPACE_BOUND_RECORDS, rows[:], &terms)
	testing.expect_value(t, ok_refusal, Act_Wiring_Refusal.None)
	testing.expect_value(t, written, 3)
	testing.expect_value(t, terms.kind_word, i64(Collector_Space_Kind.Audit))
	testing.expect_value(t, terms.forwarding_word, i64(Space_Forwarding.Keeps))
	testing.expect_value(t, terms.record_size, i64(size_of(Act_Stream_Record)))
	for row, idx in rows {
		testing.expect_value(t, row.pace, u32(output.Wiring_Pace.Always_Holds_Writer))
		testing.expect_value(t, row.reader_handle, u32(1))
		testing.expect_value(t, row.writer_handle, endpoints[idx].handle)
		testing.expect_value(t, row.terms_offset, u32(256))
		testing.expect_value(t, row.terms_count, u32(size_of(Space_Terms)))
	}
}

// End-to-end act wiring router lifecycle: refusals with no grant, attach all
// four audit spaces at grant, record from all four producers, refuse spoofed
// producers / wrong grant / full audit space fail-closed, revoke writes
// Grant_Revoked and stops recording, and a full audit space never blocks
// revocation.
@(test)
test_grant_act_router_wiring_refusals_and_revocation :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := act_test_store_bind(store, 0)
	defer free(memory)

	router: Grant_Act_Router

	// Refusal 1: Emit or revoke with no active grant fails closed.
	rec := Act_Stream_Record {
		grant_serial     = 1,
		principal_id     = 0,
		timestamp_ms     = 100,
		producer_word    = u64(Act_Producer.Remote_Service),
		act_kind_word    = u64(Act_Kind.Frame_Read),
		target_window_id = 10,
	}
	_, emit_r := act_wiring_emit(&router, store, rec)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.No_Active_Grant)
	testing.expect_value(t, act_wiring_revoke(&router, store, 1, .Principal_Revoked, 100), Act_Wiring_Refusal.No_Active_Grant)
	testing.expect_value(t, space_count(store), 0)

	// Refusal 2: Attach with grant_serial 0, wrong principal, or bad bound changes nothing.
	testing.expect_value(t, act_wiring_attach(&router, store, 0, 0, {.View_Screen}, 60_000, 100), Act_Wiring_Refusal.No_Active_Grant)
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 1, {.View_Screen}, 60_000, 100), Act_Wiring_Refusal.Principal_Mismatch)
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen}, 60_000, 100, 0), Act_Wiring_Refusal.Bad_Bound)
	testing.expect_value(t, router.state, Act_Wiring_State.Unwired)

	// Refusal 3: Store failure on attach leaves router unwired.
	memory.writes_allowed = 0
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, 4), Act_Wiring_Refusal.Store_Refused)
	testing.expect_value(t, router.state, Act_Wiring_State.Unwired)
	memory.writes_allowed = -1

	// Attach succeeds: all 4 audit spaces opened and Grant_Started recorded in root.acts.
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, 4), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Wired)
	testing.expect_value(t, router.wired_producers, ALL_ACT_PRODUCERS)
	testing.expect_value(t, space_count(store), 4)
	testing.expect_value(t, router.emitted_counts[.Root_Service], u64(1))

	// Refusal 4: Non-root producer cannot forge Grant_Revoked or spoof another producer.
	forged_revoke := Act_Stream_Record {
		grant_serial  = 1,
		principal_id  = 0,
		timestamp_ms  = 110,
		producer_word = u64(Act_Producer.Remote_Service),
		act_kind_word = u64(Act_Kind.Grant_Revoked),
	}
	_, emit_r = act_wiring_emit(&router, store, forged_revoke)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.Bad_Act_Kind)

	spoofed := Act_Stream_Record {
		grant_serial     = 1,
		principal_id     = 0,
		timestamp_ms     = 110,
		producer_word    = u64(Act_Producer.Root_Service),
		act_kind_word    = u64(Act_Kind.Frame_Read),
		target_window_id = 10,
	}
	testing.expect_value(t, act_wiring_accepts_stream_record(&router, &spoofed, .Remote_Service), Act_Wiring_Refusal.Bad_Producer)

	// Refusal 5: Wrong grant serial, wrong principal, backward clock refused.
	wrong_serial := rec
	wrong_serial.grant_serial = 2
	_, emit_r = act_wiring_emit(&router, store, wrong_serial)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.Grant_Serial_Mismatch)

	backward := rec
	backward.timestamp_ms = 50
	_, emit_r = act_wiring_emit(&router, store, backward)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.Clock_Went_Back)

	// Success: all four producers record acts into their respective audit spaces.
	samples := [4]Act_Stream_Record {
		{grant_serial = 1, principal_id = 0, timestamp_ms = 120, producer_word = u64(Act_Producer.Root_Service), act_kind_word = u64(Act_Kind.Action_Invoked), target_window_id = 10},
		{grant_serial = 1, principal_id = 0, timestamp_ms = 130, producer_word = u64(Act_Producer.Agent_Console), act_kind_word = u64(Act_Kind.Action_Invoked), target_window_id = 10},
		{grant_serial = 1, principal_id = 0, timestamp_ms = 140, producer_word = u64(Act_Producer.Remote_Service), act_kind_word = u64(Act_Kind.Frame_Read), target_window_id = 10},
		{grant_serial = 1, principal_id = 0, timestamp_ms = 150, producer_word = u64(Act_Producer.Trusted_Display), act_kind_word = u64(Act_Kind.Key_Injected), target_window_id = 10, detail_word_0 = 5},
	}
	for sample in samples {
		_, r := act_wiring_emit(&router, store, sample)
		testing.expect_value(t, r, Act_Wiring_Refusal.None)
	}
	testing.expect_value(t, router.emitted_counts[.Root_Service], u64(2))
	testing.expect_value(t, router.emitted_counts[.Agent_Console], u64(1))
	testing.expect_value(t, router.emitted_counts[.Remote_Service], u64(1))
	testing.expect_value(t, router.emitted_counts[.Trusted_Display], u64(1))

	// Refusal 6: Filling a producer's audit space fails closed with Audit_Space_Full.
	for i in u64(0) ..< 3 {
		fill_rec := samples[3]
		fill_rec.timestamp_ms = 160 + i
		_, r := act_wiring_emit(&router, store, fill_rec)
		testing.expect_value(t, r, Act_Wiring_Refusal.None)
	}
	overflow_rec := samples[3]
	overflow_rec.timestamp_ms = 170
	_, emit_r = act_wiring_emit(&router, store, overflow_rec)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.Audit_Space_Full)

	// Refusal 7: Bad revocation reason refused; state remains Wired.
	testing.expect_value(t, act_wiring_revoke(&router, store, 1, .None, 200), Act_Wiring_Refusal.Bad_Revocation_Reason)
	testing.expect_value(t, act_wiring_revoke(&router, store, 1, Revocation_Reason(99), 200), Act_Wiring_Refusal.Bad_Revocation_Reason)
	testing.expect_value(t, router.state, Act_Wiring_State.Wired)

	// Revocation writes Grant_Revoked to root.acts and stops all recording immediately.
	testing.expect_value(t, act_wiring_revoke(&router, store, 1, .Principal_Revoked, 200), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Ended)
	testing.expect_value(t, router.wired_producers, Act_Producers{})
	testing.expect(t, router.revocation_recorded, "revocation record must be persisted in root.acts")
	testing.expect_value(t, router.emitted_counts[.Root_Service], u64(3))

	// Post-revocation: every producer is refused with Grant_Revoked and chain verifies cleanly.
	after_revoke := samples[2]
	after_revoke.timestamp_ms = 210
	_, emit_r = act_wiring_emit(&router, store, after_revoke)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.Grant_Revoked)
	testing.expect_value(t, act_wiring_revoke(&router, store, 1, .Principal_Revoked, 220), Act_Wiring_Refusal.Grant_Revoked)

	for producer in Act_Producer {
		if producer == .None {
			continue
		}
		verify_r, _ := space_verify(store, router.space_numbers[producer])
		testing.expect_value(t, verify_r, Space_Refusal.None)
	}

	// Revocation still closes wirings even if root.acts is full (bound 4: 3 records already,
	// attach adds 1 -> full at 4, then revoke still transitions to Ended!).
	testing.expect_value(t, act_wiring_attach(&router, store, 2, 0, {.View_Screen}, 30_000, 300, 4), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Wired)
	testing.expect_value(t, act_wiring_revoke(&router, store, 2, .Duplicate_Connection, 310), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Ended)
	testing.expect(t, !router.revocation_recorded, "full audit space skips append but still ends wiring")
	post_rec := samples[1]
	post_rec.grant_serial = 2
	post_rec.timestamp_ms = 320
	_, emit_r = act_wiring_emit(&router, store, post_rec)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.Grant_Revoked)
}
