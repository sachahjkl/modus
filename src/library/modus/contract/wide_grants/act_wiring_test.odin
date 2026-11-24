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

// A plan of act spaces small enough to fill in a test: a whole ring of
// reserve, and room for one grant of a few records.
@(private = "file")
ACT_TEST_PLAN :: Act_Space_Plan{bound_records = 48, retained_grants = 1, records_per_minute = 1, grant_records_least = 1}

@(private = "file")
act_test_store_bind :: proc(store: ^Space_Store, principal: u64) -> ^pr.Memory_Private_Store {
	memory := new(pr.Memory_Private_Store)
	space_store_init(store, principal, TEST_COLLECTOR_IDENTIFIER, pr.memory_private_store_port(memory), space_window_heap_port())
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

	// A fresh key from Processor/Entropy strength is the key of the run: it
	// never leaves the authority and signs nothing.
	run: Wide_Grant_Authority
	testing.expect(t, authority_init_from_bytes(&run, fresh_key, .Entropy))
	testing.expect_value(t, run.status, Authority_Key_Status.Ready)
	_, run_words_ok := authority_context_words(&run)
	testing.expect(t, !run_words_ok, "the key of the run never goes to a collector")
	_, run_mint := authority_mint_proof(&run, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 1000)
	testing.expect_value(t, run_mint, Wide_Grant_Refusal.Invalid_Proof)

	// The key of principal 0 comes from the run, and passes through the
	// context words.
	testing.expect(t, authority_init_for_principal(&auth, &run, 0))
	testing.expect_value(t, auth.status, Authority_Key_Status.Ready)
	testing.expect(t, auth.key != fresh_key, "the key of a principal is not the key of the run")
	words, words_ok := authority_context_words(&auth)
	testing.expect(t, words_ok)
	rebuilt := authority_key_from_words(words)
	testing.expect_value(t, rebuilt, auth.key)

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

// The key of each principal comes from the key of the run, and signs the
// terms of that principal only: the collector of one principal accepts no
// proof that the key of another principal made, and a key of a principal
// makes no other key.
@(test)
the_key_of_one_principal_makes_no_proof_for_another :: proc(t: ^testing.T) {
	verifier := act_test_hash("unlock-passphrase-token")
	run: Wide_Grant_Authority
	testing.expect(t, authority_init_from_bytes(&run, act_test_hash("run-key"), .Processor))
	first, second: Wide_Grant_Authority
	testing.expect(t, authority_init_for_principal(&first, &run, 0))
	testing.expect(t, authority_init_for_principal(&second, &run, 1))
	testing.expect(t, first.key != second.key)

	// The refusals first: a key of a principal makes no key; an authority
	// is not its own run; nil and an erased run make none.
	derived: Wide_Grant_Authority
	testing.expect(t, !authority_init_for_principal(&derived, &first, 1), "a key of a principal makes no other key")
	testing.expect_value(t, derived.status, Authority_Key_Status.Uninitialized)
	testing.expect(t, !authority_init_for_principal(&derived, nil, 1))
	testing.expect(t, !authority_init_for_principal(nil, &run, 1))
	self := run
	testing.expect(t, !authority_init_for_principal(&self, &self, 1), "an authority is not its own run")
	erased := run
	authority_erase(&erased)
	testing.expect(t, !authority_init_for_principal(&derived, &erased, 1))
	testing.expect_value(t, derived.key, Authority_Key{})

	// The key of principal 1 refuses the terms of principal 0, and the
	// largest slot.
	terms_of_first := act_test_terms(0)
	serial_before := second.next_proof_serial
	_, other := authority_mint_proof(&second, &terms_of_first, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 1000)
	testing.expect_value(t, other, Wide_Grant_Refusal.Invalid_Proof)
	testing.expect_value(t, second.next_proof_serial, serial_before)
	terms_of_largest := act_test_terms(max(u64))
	_, largest := authority_mint_proof(&second, &terms_of_largest, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 1000)
	testing.expect_value(t, largest, Wide_Grant_Refusal.Invalid_Proof)

	// A proof that the key of principal 1 made for its own terms does not
	// verify under the key of principal 0, even with the field principal
	// changed to 0.
	terms_of_second := act_test_terms(1)
	proof, made := authority_mint_proof(&second, &terms_of_second, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 2000)
	testing.expect_value(t, made, Wide_Grant_Refusal.None)
	testing.expect_value(t, wide_grant_proof_validate(first.key, &terms_of_second, &proof, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	forged := proof
	forged.principal_id = 0
	testing.expect_value(t, wide_grant_proof_validate(first.key, &terms_of_first, &forged, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	testing.expect_value(t, wide_grant_proof_validate(second.key, &terms_of_second, &proof, {}, 0), Wide_Grant_Refusal.None)

	// Each principal has its own sequence of proof serials.
	testing.expect_value(t, proof.proof_serial, u64(1))
	first_proof, _ := authority_mint_proof(&first, &terms_of_first, .Passphrase_Verified, .Local_Unlock_Dialog, verifier, 2000)
	testing.expect_value(t, first_proof.proof_serial, u64(1))

	// The same run and slot give the same key: one key for a slot in a run.
	again: Wide_Grant_Authority
	testing.expect(t, authority_init_for_principal(&again, &run, 1))
	testing.expect_value(t, again.key, second.key)
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
	_, r = act_wiring_rows_build(.Started, 1, 1, endpoints[:], 256, SPACE_AUDIT_BOUND_MOST + 1, rows[:], &terms)
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
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen}, 60_000, 100, Act_Space_Plan{}), Act_Wiring_Refusal.Bad_Bound)
	small := ACT_TEST_PLAN
	small.bound_records = i64(ACT_RING_CAPACITY)
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen}, 60_000, 100, small), Act_Wiring_Refusal.Bad_Bound)
	testing.expect_value(t, router.state, Act_Wiring_State.Unwired)

	// Refusal 3: Store failure on attach leaves router unwired.
	memory.writes_allowed = 0
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, ACT_TEST_PLAN), Act_Wiring_Refusal.Store_Refused)
	testing.expect_value(t, router.state, Act_Wiring_State.Unwired)
	memory.writes_allowed = -1

	// Attach succeeds: the spaces of the three writers of this layer open,
	// and Grant_Started is recorded in root.acts.
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, ACT_TEST_PLAN), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Wired)
	testing.expect_value(t, router.wired_producers, ACT_PRODUCERS_WIRED)
	testing.expect_value(t, space_count(store), 3)
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
	for sample, index in samples {
		_, r := act_wiring_emit(&router, store, sample)
		// The agent console has no space in this layer: its record is refused.
		testing.expect_value(t, r, index == 1 ? Act_Wiring_Refusal.Producer_Not_Wired : Act_Wiring_Refusal.None)
	}
	testing.expect_value(t, router.emitted_counts[.Root_Service], u64(2))
	testing.expect_value(t, router.emitted_counts[.Agent_Console], u64(0))
	testing.expect_value(t, router.emitted_counts[.Remote_Service], u64(1))
	testing.expect_value(t, router.emitted_counts[.Trusted_Display], u64(1))

	// Refusal 6: Filling a producer's audit space fails closed with Audit_Space_Full.
	for i in u64(0) ..< u64(ACT_TEST_PLAN.bound_records) - 1 {
		fill_rec := samples[3]
		fill_rec.timestamp_ms = 151 + i
		_, r := act_wiring_emit(&router, store, fill_rec)
		testing.expect_value(t, r, Act_Wiring_Refusal.None)
	}
	overflow_rec := samples[3]
	overflow_rec.timestamp_ms = 199
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

	for producer in ACT_PRODUCERS_WIRED {
		verify_r, _ := space_verify(store, router.space_numbers[producer])
		testing.expect_value(t, verify_r, Space_Refusal.None)
	}

	// The next grant: the ring of one grant is full, so the grant before
	// rotates out of each space, whole segments at a time, and the full
	// space of the trusted display has room again.
	testing.expect_value(t, act_wiring_attach(&router, store, 2, 0, {.View_Screen}, 30_000, 300, ACT_TEST_PLAN), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Wired)
	testing.expect_value(t, router.retained.count, 1)
	display := space_of(store, router.space_numbers[.Trusted_Display])
	testing.expect_value(t, display.kept_first_serial, u64(ACT_TEST_PLAN.bound_records))
	// The root service fills its own space; the revocation still ends the
	// grant, with no record of its end.
	for index in u64(0) ..< u64(ACT_TEST_PLAN.bound_records) {
		filler := samples[0]
		filler.grant_serial = 2
		filler.timestamp_ms = 301 + index
		_, _ = act_wiring_emit(&router, store, filler)
	}
	testing.expect_value(t, act_wiring_revoke(&router, store, 2, .Duplicate_Connection, 400), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Ended)
	testing.expect(t, !router.revocation_recorded, "full audit space skips append but still ends wiring")
	post_rec := samples[1]
	post_rec.grant_serial = 2
	post_rec.timestamp_ms = 420
	_, emit_r = act_wiring_emit(&router, store, post_rec)
	testing.expect_value(t, emit_r, Act_Wiring_Refusal.Grant_Revoked)
}

@(private = "file")
act_test_remote_record :: proc(grant_serial: u64, timestamp_ms: u64, producer := Act_Producer.Remote_Service, kind := Act_Kind.Call_Made) -> [size_of(Act_Stream_Record)]u8 {
	record := Act_Stream_Record {
		grant_serial     = grant_serial,
		principal_id     = 0,
		timestamp_ms     = timestamp_ms,
		producer_word    = u64(producer),
		act_kind_word    = u64(kind),
		target_window_id = 10,
	}
	return act_stream_record_encode(&record)
}

@(private = "file")
act_test_remote_link :: proc(t: ^testing.T, links: ^Source_Links, store: ^Space_Store, tag: u32, bound: i64) -> ^Source_Link {
	link, refusal := link_open(links, store, tag, transmute([]u8)string("remote"), transmute([]u8)string(ACT_OUTPUT_NAME), act_audit_space_terms(bound), size_of(Act_Stream_Record))
	testing.expect_value(t, refusal, Space_Refusal.None)
	return link
}

@(private = "file")
act_test_kept :: proc(store: ^Space_Store, space: u32) -> u64 {
	found := space_of(store, space)
	return found == nil ? 0 : u64(found.count)
}

// A record on a ring of act records that breaks the gate closes its link
// before its space sees it, with no pending record: a record that does not
// decode, of another producer, of another grant, a lifecycle record of a
// producer that is not the root service, and, the case of the end, each
// record that arrives after the revocation of its grant. The space keeps
// only the record that came while the grant held.
@(test)
test_a_record_after_revocation_is_refused_and_kept_nowhere :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := act_test_store_bind(store, 0)
	defer free(memory)
	router: Grant_Act_Router
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, ACT_TEST_PLAN), Act_Wiring_Refusal.None)

	short := act_test_remote_record(1, 110)
	broken := [?]struct {
		record:   [size_of(Act_Stream_Record)]u8,
		expected: Act_Wiring_Refusal,
	} {
		{act_test_remote_record(1, 110, .Trusted_Display, .Key_Injected), .Bad_Producer},
		{act_test_remote_record(2, 110), .Grant_Serial_Mismatch},
		{act_test_remote_record(1, 110, .Remote_Service, .Grant_Revoked), .Bad_Act_Kind},
		{act_test_remote_record(1, 99), .Clock_Went_Back},
	}
	for case_of, index in broken {
		links, _ := source_links_heap()
		link := act_test_remote_link(t, &links, store, 5, ACT_TEST_PLAN.bound_records)
		record := case_of.record
		step, act_refusal, _ := act_link_keep(&router, store, link, record[:], .Remote_Service, 110)
		testing.expectf(t, step == .Refused && act_refusal == case_of.expected, "case %d: %v %v", index, step, act_refusal)
		testing.expect_value(t, link.state, Source_Link_State.Ended)
		testing.expect(t, !link.pending)
		testing.expect_value(t, act_test_kept(store, link.space), u64(0))
	}
	// A record of a wrong size never decodes.
	{
		links, _ := source_links_heap()
		link := act_test_remote_link(t, &links, store, 5, ACT_TEST_PLAN.bound_records)
		step, act_refusal, _ := act_link_keep(&router, store, link, short[:size_of(Act_Stream_Record) - 1], .Remote_Service, 110)
		testing.expect_value(t, step, Link_Step.Refused)
		testing.expect_value(t, act_refusal, Act_Wiring_Refusal.Bad_Producer)
		testing.expect_value(t, act_test_kept(store, link.space), u64(0))
	}

	links, _ := source_links_heap()
	link := act_test_remote_link(t, &links, store, 5, ACT_TEST_PLAN.bound_records)
	kept := act_test_remote_record(1, 110)
	step, act_refusal, _ := act_link_keep(&router, store, link, kept[:], .Remote_Service, 110)
	testing.expect_value(t, step, Link_Step.Kept)
	testing.expect_value(t, act_refusal, Act_Wiring_Refusal.None)
	testing.expect_value(t, act_test_kept(store, link.space), u64(1))

	testing.expect_value(t, act_wiring_revoke(&router, store, 1, .Principal_Revoked, 120), Act_Wiring_Refusal.None)
	late := act_test_remote_record(1, 130)
	step, act_refusal, _ = act_link_keep(&router, store, link, late[:], .Remote_Service, 130)
	testing.expect_value(t, step, Link_Step.Refused)
	testing.expect_value(t, act_refusal, Act_Wiring_Refusal.Grant_Revoked)
	testing.expect_value(t, link.state, Source_Link_State.Ended)
	testing.expect(t, !link.pending)
	testing.expect_value(t, act_test_kept(store, link.space), u64(1))
	verify, _ := space_verify(store, link.space)
	testing.expect_value(t, verify, Space_Refusal.None)
}

// The lock of the session ends the grant with its reason: the last record
// of the space of the root service is Grant_Revoked with Session_Locked,
// and it survives a start of the collector.
@(test)
test_the_lock_leaves_its_end_record :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := act_test_store_bind(store, 0)
	defer free(memory)
	router: Grant_Act_Router
	testing.expect_value(t, act_wiring_attach(&router, store, 3, 0, {.View_Screen}, 60_000, 100), Act_Wiring_Refusal.None)
	testing.expect_value(t, act_wiring_revoke(&router, store, 3, .Session_Locked, 150), Act_Wiring_Refusal.None)
	testing.expect(t, router.revocation_recorded)
	again := new(Space_Store)
	defer free(again)
	space_store_init(again, 0, TEST_COLLECTOR_IDENTIFIER, pr.memory_private_store_port(memory), space_window_heap_port())
	reader := Space_Reader{principal = 0, acts_for_principal = true}
	copy(reader.name[:], "console")
	heads: [4]Kept_Record_Head
	bytes: [4 * size_of(Act_Stream_Record)]u8
	count, refusal := records_read(again, router.space_numbers[.Root_Service], -1, 4, &reader, heads[:], bytes[:])
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, count, 2)
	last, decoded := act_stream_record_decode(bytes[size_of(Act_Stream_Record):][:size_of(Act_Stream_Record)])
	testing.expect(t, decoded)
	testing.expect_value(t, Act_Kind(last.act_kind_word), Act_Kind.Grant_Revoked)
	testing.expect_value(t, Revocation_Reason(last.detail_word_0), Revocation_Reason.Session_Locked)
	testing.expect_value(t, last.grant_serial, u64(3))
}

// One grant of an hour: the 33rd record of a writer is kept, and the 100th;
// the ring in memory holds the newest 64, the private store each of them,
// and a collector that starts again reads them back whole.
@(test)
test_a_grant_keeps_more_records_than_memory :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := act_test_store_bind(store, 0)
	defer free(memory)
	router: Grant_Act_Router
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60 * 60_000, 100), Act_Wiring_Refusal.None)
	testing.expect(t, act_grant_allowance(ACT_SPACE_PLAN, 60 * 60_000) >= 100)
	links, _ := source_links_heap()
	link := act_test_remote_link(t, &links, store, 5, ACT_SPACE_PLAN.bound_records)
	for index in u64(0) ..< 100 {
		record := act_test_remote_record(1, 110 + index)
		step, _, _ := act_link_keep(&router, store, link, record[:], .Remote_Service, 110 + index)
		testing.expectf(t, step == .Kept, "the record %d was not kept", index + 1)
	}
	space := space_of(store, link.space)
	testing.expect_value(t, space_kept_count(space), u64(100))
	testing.expect_value(t, space.count, u32(SPACE_RECORDS_MOST))
	testing.expect_value(t, space.first_serial, u64(100 - SPACE_RECORDS_MOST))
	verified, _ := space_verify(store, link.space)
	testing.expect_value(t, verified, Space_Refusal.None)
	last_hash := space.last_hash
	space_number := link.space

	again := new(Space_Store)
	defer free(again)
	space_store_init(again, 0, TEST_COLLECTOR_IDENTIFIER, pr.memory_private_store_port(memory), space_window_heap_port())
	testing.expect_value(t, space_store_ready(again), Space_Refusal.None)
	loaded := space_of(again, space_number)
	testing.expect_value(t, loaded.next_serial, u64(100))
	testing.expect(t, loaded.last_hash == last_hash, "the chain changed at the start")
	verified, _ = space_verify(again, space_number)
	testing.expect_value(t, verified, Space_Refusal.None)
}

// The ring of the kept grants: 17 grants in a row each start, the ring
// keeps the newest ACT_SPACE_PLAN.retained_grants, and a collector that
// starts again reads the ring back. With a small plan, the oldest grant
// rotates out of the space of a writer when a new grant needs its room,
// whole segments at a time, and the chain of what stays still verifies
// from its anchors, also after a start. A damaged ring refuses the grant.
@(test)
test_the_seventeenth_grant_rotates_the_oldest_out :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := act_test_store_bind(store, 0)
	defer free(memory)
	router: Grant_Act_Router
	now := u64(100)
	for grant in u64(1) ..= 17 {
		testing.expectf(t, act_wiring_attach(&router, store, grant, 0, {.View_Screen}, 60_000, now) == .None, "the grant %d did not start", grant)
		testing.expect_value(t, act_wiring_revoke(&router, store, grant, .Principal_Revoked, now + 1), Act_Wiring_Refusal.None)
		testing.expect(t, router.revocation_recorded)
		now += 10
	}
	testing.expect_value(t, router.retained.count, ACT_SPACE_PLAN.retained_grants)
	testing.expect_value(t, router.retained.rows[0].grant_serial, u64(17 - ACT_SPACE_PLAN.retained_grants + 1))
	testing.expect_value(t, router.retained.rows[router.retained.count - 1].grant_serial, u64(17))

	// A collector that starts again reads the same ring.
	again := new(Space_Store)
	defer free(again)
	space_store_init(again, 0, TEST_COLLECTOR_IDENTIFIER, pr.memory_private_store_port(memory), space_window_heap_port())
	restarted: Grant_Act_Router
	testing.expect_value(t, act_wiring_attach(&restarted, again, 18, 0, {.View_Screen}, 60_000, now), Act_Wiring_Refusal.None)
	testing.expect_value(t, restarted.retained.count, ACT_SPACE_PLAN.retained_grants)
	testing.expect_value(t, restarted.retained.rows[0].grant_serial, u64(18 - ACT_SPACE_PLAN.retained_grants + 1))

	// A small plan: two grants of 16 records of remote fill its space.
	small := Act_Space_Plan{bound_records = 64, retained_grants = 2, records_per_minute = 1, grant_records_least = 1}
	testing.expect_value(t, act_grant_records_most(small), u64(16))
	rotating := new(Space_Store)
	defer free(rotating)
	rotating_memory := act_test_store_bind(rotating, 0)
	defer free(rotating_memory)
	small_router: Grant_Act_Router
	time := u64(1000)
	for grant in u64(1) ..= 3 {
		testing.expect_value(t, act_wiring_attach(&small_router, rotating, grant, 0, {.View_Screen}, 16 * 60_000, time, small), Act_Wiring_Refusal.None)
		links, _ := source_links_heap()
		link := act_test_remote_link(t, &links, rotating, u32(grant), small.bound_records)
		for index in u64(0) ..< 16 {
			record := act_test_remote_record(grant, time + 1 + index)
			step, _, _ := act_link_keep(&small_router, rotating, link, record[:], .Remote_Service, time + 1 + index)
			testing.expect_value(t, step, Link_Step.Kept)
		}
		testing.expect_value(t, act_wiring_revoke(&small_router, rotating, grant, .Time_Bound, time + 100), Act_Wiring_Refusal.None)
		time += 1000
	}
	remote_space := space_of(rotating, small_router.space_numbers[.Remote_Service])
	// The third grant rotated the first out: its segment left.
	testing.expect_value(t, remote_space.kept_first_serial, u64(16))
	testing.expect_value(t, space_kept_count(remote_space), u64(32))
	testing.expect_value(t, remote_space.removed, u64(16))
	verified, _ := space_verify(rotating, small_router.space_numbers[.Remote_Service])
	testing.expect_value(t, verified, Space_Refusal.None)
	restart := new(Space_Store)
	defer free(restart)
	space_store_init(restart, 0, TEST_COLLECTOR_IDENTIFIER, pr.memory_private_store_port(rotating_memory), space_window_heap_port())
	testing.expect_value(t, space_store_ready(restart), Space_Refusal.None)
	reloaded := space_of(restart, small_router.space_numbers[.Remote_Service])
	testing.expect_value(t, reloaded.kept_first_serial, u64(16))
	testing.expect_value(t, reloaded.next_serial, u64(48))
	verified, _ = space_verify(restart, small_router.space_numbers[.Remote_Service])
	testing.expect_value(t, verified, Space_Refusal.None)
	// The grant that holds never rotates: a new grant waits for its end.
	testing.expect_value(t, act_wiring_attach(&small_router, rotating, 4, 0, {.View_Screen}, 60_000, time, small), Act_Wiring_Refusal.None)
	testing.expect_value(t, act_wiring_attach(&small_router, rotating, 5, 0, {.View_Screen}, 60_000, time, small), Act_Wiring_Refusal.Already_Wired)

	// A damaged ring refuses the grant, with nothing changed.
	object := pr.memory_private_store_find(rotating_memory, RETAINED_GRANTS_OBJECT_NAME)
	object.bytes[20] ~= 1
	broken: Grant_Act_Router
	testing.expect_value(t, act_wiring_attach(&broken, rotating, 6, 0, {.View_Screen}, 60_000, time, small), Act_Wiring_Refusal.Store_Refused)
	testing.expect_value(t, broken.state, Act_Wiring_State.Unwired)
}

// A grant that a newer one replaces closes each of its rings, with a
// pending record or not, and only once it ended.
@(test)
test_a_replaced_grant_closes_each_of_its_rings :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := act_test_store_bind(store, 0)
	defer free(memory)
	router: Grant_Act_Router
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, ACT_TEST_PLAN), Act_Wiring_Refusal.None)
	links, _ := source_links_heap()
	link := act_test_remote_link(t, &links, store, 5, ACT_TEST_PLAN.bound_records)
	closed: [4]u32
	// A grant that holds closes nothing.
	testing.expect_value(t, act_links_close_replaced(&router, &links, closed[:]), 0)
	testing.expect_value(t, act_wiring_revoke(&router, store, 1, .Replaced_By_Newer_Grant, 200), Act_Wiring_Refusal.None)
	// No pending record, and the ring closes anyway; with no room for its
	// tag, nothing closes.
	testing.expect(t, !link.pending)
	testing.expect_value(t, act_links_close_replaced(&router, &links, closed[:0]), 0)
	testing.expect_value(t, link.state, Source_Link_State.Open)
	testing.expect_value(t, act_links_close_replaced(&router, &links, closed[:]), 1)
	testing.expect_value(t, closed[0], u32(5))
	testing.expect_value(t, link.state, Source_Link_State.Ended)
	testing.expect_value(t, act_links_close_replaced(&router, &links, closed[:]), 0)
}

// An agent fills the space of its act records. While the grant holds, the
// collector reads no more of a ring once the space has room for one ring
// only: the ring fills, and the writer refuses its next act. A record that
// came anyway waits, pending, when the space is full. The revocation still
// ends the grant and its record lands, since only the collector writes
// root.acts. After the end, the records of a ring with a time at or before
// the end are kept in the room of the ring, a later one is refused, and the
// link of the record that a full space held closes, kept nowhere.
@(test)
test_a_full_act_space_never_blocks_the_end_of_its_grant :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := act_test_store_bind(store, 0)
	defer free(memory)
	router: Grant_Act_Router
	testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, ACT_TEST_PLAN), Act_Wiring_Refusal.None)
	links, _ := source_links_heap()
	link := act_test_remote_link(t, &links, store, 5, ACT_TEST_PLAN.bound_records)
	closed: [4]u32
	reserve_at := u64(ACT_TEST_PLAN.bound_records) - u64(ACT_RING_CAPACITY)
	for index in u64(0) ..< reserve_at {
		testing.expect(t, act_link_may_read(&router, store, link))
		record := act_test_remote_record(1, 110 + index)
		step, _, _ := act_link_keep(&router, store, link, record[:], .Remote_Service, 110 + index)
		testing.expect_value(t, step, Link_Step.Kept)
	}
	// The room of one ring is left: the collector reads no more.
	testing.expect(t, !act_link_may_read(&router, store, link))
	// The ring of the reserve, read anyway, fills the space; one more waits.
	for index in reserve_at ..< u64(ACT_TEST_PLAN.bound_records) {
		record := act_test_remote_record(1, 110 + index)
		step, _, _ := act_link_keep(&router, store, link, record[:], .Remote_Service, 110 + index)
		testing.expect_value(t, step, Link_Step.Kept)
	}
	held := act_test_remote_record(1, 170)
	step, act_refusal, space_refusal := act_link_keep(&router, store, link, held[:], .Remote_Service, 170)
	testing.expect_value(t, step, Link_Step.Held)
	testing.expect_value(t, act_refusal, Act_Wiring_Refusal.None)
	testing.expect_value(t, space_refusal, Space_Refusal.Space_Full)
	testing.expect(t, link.pending)
	testing.expect_value(t, act_links_close_ended(&router, &links, closed[:]), 0)
	testing.expect_value(t, link.state, Source_Link_State.Open)

	testing.expect_value(t, act_wiring_revoke(&router, store, 1, .Principal_Revoked, 200), Act_Wiring_Refusal.None)
	testing.expect_value(t, router.state, Act_Wiring_State.Ended)
	testing.expect(t, router.revocation_recorded)
	testing.expect(t, act_link_may_read(&router, store, link))
	testing.expect_value(t, act_links_close_ended(&router, &links, closed[:0]), 0)
	testing.expect_value(t, act_links_close_ended(&router, &links, closed[:]), 1)
	testing.expect_value(t, closed[0], u32(5))
	testing.expect_value(t, link.state, Source_Link_State.Ended)
	testing.expect(t, !link.pending)
	testing.expect_value(t, space_kept_count(space_of(store, link.space)), u64(ACT_TEST_PLAN.bound_records))
	testing.expect_value(t, act_links_close_ended(&router, &links, closed[:]), 0)

	// A ring of another writer, read after the end: its record of before
	// the end is kept, one of after the end is refused.
	display_links, _ := source_links_heap()
	display_link, display_open := link_open(&display_links, store, 6, transmute([]u8)string("compositor"), transmute([]u8)string(ACT_OUTPUT_NAME), act_audit_space_terms(ACT_TEST_PLAN.bound_records), size_of(Act_Stream_Record))
	testing.expect_value(t, display_open, Space_Refusal.None)
	before_end := act_test_remote_record(1, 195, .Trusted_Display, .Target_Window_Changed)
	step, act_refusal, _ = act_link_keep(&router, store, display_link, before_end[:], .Trusted_Display, 201)
	testing.expect_value(t, step, Link_Step.Kept)
	after_end := act_test_remote_record(1, 201, .Trusted_Display, .Target_Window_Changed)
	step, act_refusal, _ = act_link_keep(&router, store, display_link, after_end[:], .Trusted_Display, 201)
	testing.expect_value(t, step, Link_Step.Refused)
	testing.expect_value(t, act_refusal, Act_Wiring_Refusal.Grant_Revoked)
	testing.expect_value(t, space_kept_count(space_of(store, display_link.space)), u64(1))
}

// A wide grant beside 20 audited servers: the grant opens its three act
// spaces, the three rings of its writers and the 20 rings of the servers
// take 23 links, past the 16 of a fixed table; a budget that pays 22 links
// refuses the 23rd with Memory_Refused and opens no space for it.
@(test)
test_twenty_audited_servers_beside_a_wide_grant :: proc(t: ^testing.T) {
	for paid in ([?]int{23, 22}) {
		store := new(Space_Store)
		defer free(store)
		memory := act_test_store_bind(store, 0)
		defer free(memory)
		router: Grant_Act_Router
		testing.expect_value(t, act_wiring_attach(&router, store, 1, 0, {.View_Screen, .Send_Input}, 60_000, 100, ACT_TEST_PLAN), Act_Wiring_Refusal.None)
		links, _ := source_links_heap(paid)
		tag := u32(1)
		for writer in ACT_PRODUCERS_WIRED {
			_, refusal := link_open(&links, store, tag, transmute([]u8)ACT_PRODUCER_NAMES[writer], transmute([]u8)string(ACT_OUTPUT_NAME), act_audit_space_terms(ACT_TEST_PLAN.bound_records), size_of(Act_Stream_Record))
			testing.expect_value(t, refusal, Space_Refusal.None)
			tag += 1
		}
		name: [2]u8 = {'s', 'a'}
		for server in 0 ..< 20 {
			name[1] = 'a' + u8(server)
			terms := Space_Terms{kind_word = i64(Collector_Space_Kind.Audit), bound_records = 64, forwarding_word = i64(Space_Forwarding.Keeps), record_size = 8}
			_, refusal := link_open(&links, store, tag, name[:], transmute([]u8)string("orders"), terms, 8)
			tag += 1
			if server == 19 && paid == 22 {
				testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
				testing.expect_value(t, space_count(store), 3 + 19)
				testing.expect_value(t, len(links.links), 22)
				continue
			}
			testing.expectf(t, refusal == .None, "the server %d with %d links paid: %v", server, paid, refusal)
		}
		if paid == 23 {
			testing.expect_value(t, len(links.links), 23)
			testing.expect_value(t, space_count(store), 23)
			active := 0
			for &link in links.links {
				if link.active {
					active += 1
				}
			}
			testing.expect_value(t, active, 23)
		}
	}
}
