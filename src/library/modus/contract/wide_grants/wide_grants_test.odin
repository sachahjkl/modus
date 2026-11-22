#+build !freestanding
package wide_grants

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
test_hash :: proc(label: string) -> blake3.Hash {
	raw := transmute([]u8)label
	return blake3.hash(raw)
}

@(private = "file")
make_valid_terms :: proc() -> Wide_Grant_Terms {
	terms := Wide_Grant_Terms {
		principal_id          = 0,
		grantee_identity_hash = test_hash("agent-key-1"),
		authorities_word      = wide_authorities_to_word({.View_Screen, .Send_Input, .Read_Semantic_Tree}),
		target_window_count   = 2,
		target_window_ids     = {0 = 101, 1 = 202},
		duration_ms           = DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	_ = wide_grant_terms_seal(&terms)
	return terms
}

@(private = "file")
build_chain :: proc(records: []Act_Record, grant_serial: u64, start_ts: u64) {
	prev := GENESIS_PREVIOUS_HASH
	for index in 0 ..< len(records) {
		kind := Act_Kind.Frame_Read
		window_id := u64(101)
		if index == 0 {
			kind = .Grant_Started
			window_id = 0
		} else if index % 2 == 1 {
			kind = .Key_Injected
		}
		records[index] = Act_Record {
			sequence_number  = u64(index),
			grant_serial     = grant_serial,
			timestamp_ms     = start_ts + u64(index) * 10,
			act_kind_word    = u64(kind),
			target_window_id = window_id,
			detail_word_0    = u64(index + 1),
			detail_word_1    = u64(index * 7),
			previous_hash    = prev,
		}
		_ = act_record_seal(&records[index])
		prev = records[index].record_hash
	}
}

@(test)
test_enum_border_parsers_refuse_zero_and_unknown_words :: proc(t: ^testing.T) {
	// Wide_Authority single-member parser
	if _, ok := wide_authority_from_word(0); ok {
		testing.fail_now(t, "wide_authority_from_word accepted 0")
	}
	if _, ok := wide_authority_from_word(4); ok {
		testing.fail_now(t, "wide_authority_from_word accepted 4")
	}
	if _, ok := wide_authority_from_word(max(u64)); ok {
		testing.fail_now(t, "wide_authority_from_word accepted max(u64)")
	}
	for expected in Wide_Authority {
		parsed, ok := wide_authority_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}

	// Wide_Authorities bitmask parser: refuses 0, bit 0, bit 4, high bits, max(u64)
	bad_masks := [?]u64{0, 1, 1 << 4, 1 << 63, WIDE_AUTHORITY_KNOWN_MASK | 1, WIDE_AUTHORITY_KNOWN_MASK | (1 << 5), max(u64)}
	for mask in bad_masks {
		if _, ok := wide_authorities_from_word(mask); ok {
			testing.fail_now(t, "wide_authorities_from_word accepted invalid mask")
		}
	}
	all_word := wide_authorities_to_word({.View_Screen, .Send_Input, .Read_Semantic_Tree})
	decoded, decoded_ok := wide_authorities_from_word(all_word)
	testing.expect(t, decoded_ok && decoded == {.View_Screen, .Send_Input, .Read_Semantic_Tree})

	// Proof_Kind refuses 0, 3, max(u64)
	if _, ok := proof_kind_from_word(0); ok {
		testing.fail_now(t, "proof_kind_from_word accepted 0")
	}
	if _, ok := proof_kind_from_word(3); ok {
		testing.fail_now(t, "proof_kind_from_word accepted 3")
	}
	if _, ok := proof_kind_from_word(max(u64)); ok {
		testing.fail_now(t, "proof_kind_from_word accepted max(u64)")
	}
	k1, ok1 := proof_kind_from_word(1)
	k2, ok2 := proof_kind_from_word(2)
	testing.expect(t, ok1 && k1 == .Passphrase_Verified && ok2 && k2 == .Host_Key_Signed)

	// Wide_Grant_State refuses 0, 5, max(u64)
	if _, ok := wide_grant_state_from_word(0); ok {
		testing.fail_now(t, "wide_grant_state_from_word accepted 0")
	}
	if _, ok := wide_grant_state_from_word(5); ok {
		testing.fail_now(t, "wide_grant_state_from_word accepted 5")
	}
	if _, ok := wide_grant_state_from_word(max(u64)); ok {
		testing.fail_now(t, "wide_grant_state_from_word accepted max(u64)")
	}
	for expected in Wide_Grant_State {
		if expected == .None {
			continue
		}
		parsed, ok := wide_grant_state_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}

	// Act_Kind refuses 0, 10, max(u64)
	if _, ok := act_kind_from_word(0); ok {
		testing.fail_now(t, "act_kind_from_word accepted 0")
	}
	if _, ok := act_kind_from_word(10); ok {
		testing.fail_now(t, "act_kind_from_word accepted 10")
	}
	if _, ok := act_kind_from_word(max(u64)); ok {
		testing.fail_now(t, "act_kind_from_word accepted max(u64)")
	}
	for expected in Act_Kind {
		if expected == .None {
			continue
		}
		parsed, ok := act_kind_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}

	// Wide_Grant_Refusal accepts 0..14, refuses 15 and max(u64)
	if _, ok := wide_grant_refusal_from_word(15); ok {
		testing.fail_now(t, "wide_grant_refusal_from_word accepted 15")
	}
	if _, ok := wide_grant_refusal_from_word(max(u64)); ok {
		testing.fail_now(t, "wide_grant_refusal_from_word accepted max(u64)")
	}
	for expected in Wide_Grant_Refusal {
		parsed, ok := wide_grant_refusal_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}

	// Sensitive_Action refuses 0, 11, max(u64)
	if _, ok := sensitive_action_from_word(0); ok {
		testing.fail_now(t, "sensitive_action_from_word accepted 0")
	}
	if _, ok := sensitive_action_from_word(11); ok {
		testing.fail_now(t, "sensitive_action_from_word accepted 11")
	}
	if _, ok := sensitive_action_from_word(max(u64)); ok {
		testing.fail_now(t, "sensitive_action_from_word accepted max(u64)")
	}

	// Collector_Ring_Command refuses 0, 9, max(u32)
	if _, ok := collector_ring_command_from_word(0); ok {
		testing.fail_now(t, "collector_ring_command_from_word accepted 0")
	}
	if _, ok := collector_ring_command_from_word(9); ok {
		testing.fail_now(t, "collector_ring_command_from_word accepted 9")
	}
	if _, ok := collector_ring_command_from_word(max(u32)); ok {
		testing.fail_now(t, "collector_ring_command_from_word accepted max(u32)")
	}
}

@(test)
test_terms_validation_refuses_every_invalid_edge :: proc(t: ^testing.T) {
	// Restart persistence is strictly forbidden
	{
		terms := make_valid_terms()
		terms.survives_restart = true
		testing.expect_value(t, wide_grant_terms_seal(&terms), Wide_Grant_Refusal.Restart_Persistence_Forbidden)
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Restart_Persistence_Forbidden)
	}

	// Non-zero reserved pad refused
	{
		terms := make_valid_terms()
		terms.reserved_pad = 1
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Invalid_Authority)
	}

	// Zero or unknown authority bits refused
	{
		terms := make_valid_terms()
		terms.authorities_word = 0
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Invalid_Authority)

		terms.authorities_word = 1 << 9
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Invalid_Authority)

		// Send_Input without View_Screen is refused
		terms.authorities_word = wide_authorities_to_word({.Send_Input})
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Invalid_Authority)
	}

	// Window set bounds: 0, MAX+1 (17), max(u32), zero id, duplicate id, non-zero tail
	{
		terms := make_valid_terms()
		terms.target_window_count = 0
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Empty_Window_Set)

		terms = make_valid_terms()
		terms.target_window_count = MAX_TARGET_WINDOWS + 1
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Too_Many_Windows)

		terms = make_valid_terms()
		terms.target_window_count = max(u32)
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Too_Many_Windows)

		terms = make_valid_terms()
		terms.target_window_ids[1] = 0
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Window_Not_In_Scope)

		terms = make_valid_terms()
		terms.target_window_ids[1] = terms.target_window_ids[0]
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Window_Not_In_Scope)

		terms = make_valid_terms()
		terms.target_window_ids[2] = 999
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Too_Many_Windows)
	}

	// Duration bounds: 0, MAX+1, max(u64)
	{
		terms := make_valid_terms()
		terms.duration_ms = 0
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Duration_Zero)

		terms = make_valid_terms()
		terms.duration_ms = MAX_WIDE_GRANT_DURATION_MS + 1
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Duration_Past_Bound)

		terms = make_valid_terms()
		terms.duration_ms = max(u64)
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Duration_Past_Bound)
	}

	// Zero grantee hash and tampered terms_hash refused
	{
		terms := make_valid_terms()
		terms.grantee_identity_hash = {}
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Invalid_Proof)

		terms = make_valid_terms()
		terms.terms_hash = {}
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Invalid_Proof)

		terms = make_valid_terms()
		terms.duration_ms -= 1 // Mutated after sealing without resealing
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.Invalid_Proof)
	}

	// Boundary valid cases: 1 window + 1 ms, and 16 windows + MAX_WIDE_GRANT_DURATION_MS
	{
		min_terms := Wide_Grant_Terms {
			principal_id          = 0,
			grantee_identity_hash = test_hash("agent-min"),
			authorities_word      = wide_authorities_to_word({.View_Screen}),
			target_window_count   = 1,
			target_window_ids     = {0 = 1},
			duration_ms           = 1,
			survives_restart      = false,
		}
		testing.expect_value(t, wide_grant_terms_seal(&min_terms), Wide_Grant_Refusal.None)
		testing.expect_value(t, wide_grant_terms_validate(&min_terms), Wide_Grant_Refusal.None)
		testing.expect(t, wide_grant_terms_contains_window(&min_terms, 1))
		testing.expect(t, !wide_grant_terms_contains_window(&min_terms, 0))
		testing.expect(t, !wide_grant_terms_contains_window(&min_terms, 2))

		max_terms := Wide_Grant_Terms {
			principal_id          = 42,
			grantee_identity_hash = test_hash("agent-max"),
			authorities_word      = wide_authorities_to_word({.Read_Semantic_Tree}),
			target_window_count   = MAX_TARGET_WINDOWS,
			duration_ms           = MAX_WIDE_GRANT_DURATION_MS,
			survives_restart      = false,
		}
		for i in 0 ..< MAX_TARGET_WINDOWS {
			max_terms.target_window_ids[i] = u64(i + 1)
		}
		testing.expect_value(t, wide_grant_terms_seal(&max_terms), Wide_Grant_Refusal.None)
		testing.expect_value(t, wide_grant_terms_validate(&max_terms), Wide_Grant_Refusal.None)
		testing.expect(t, wide_grant_terms_contains_window(&max_terms, 16))
		testing.expect(t, !wide_grant_terms_contains_window(&max_terms, 17))
	}
}

@(test)
test_proof_validation_refuses_every_forgery :: proc(t: ^testing.T) {
	terms := make_valid_terms()
	authority_key := test_hash("unlock-authority-key")
	host_key := test_hash("host-principal-signing-key")
	unlock_token := test_hash("local-unlock-session-token")

	// The all-zero authority key is refused when a proof is made and when it is checked.
	{
		_, zero_make := wide_grant_proof_make({}, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, 1, unlock_token, 1000)
		testing.expect_value(t, zero_make, Wide_Grant_Refusal.Invalid_Proof)
		good, _ := wide_grant_proof_make(authority_key, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, 1, unlock_token, 1000)
		testing.expect_value(t, wide_grant_proof_validate({}, &terms, &good, host_key, 0), Wide_Grant_Refusal.Invalid_Proof)
		// A proof tagged under the zero key by a forger who calls the keyed hash itself.
		forged := good
		forged_payload := forged
		forged_payload.proof_tag = {}
		_, forged_ok := wide_grant_proof_tag({}, &forged_payload)
		testing.expect(t, !forged_ok, "the tag of the zero key is refused")
		testing.expect(t, !authority_key_is_valid({}))
	}

	// Missing proof (zero kind or zero tag)
	empty_proof := Wide_Grant_Proof{}
	testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &empty_proof, host_key, 0), Wide_Grant_Refusal.Missing_Proof)

	// Passphrase proof valid path
	pass_proof, pass_make := wide_grant_proof_make(authority_key, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, 7, unlock_token, 1000)
	testing.expect_value(t, pass_make, Wide_Grant_Refusal.None)

	// A proof tagged under another key, or with the unkeyed hash, is refused.
	{
		other_key := test_hash("forger-key")
		forged, _ := wide_grant_proof_make(other_key, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, 7, unlock_token, 1000)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &forged, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		unkeyed := pass_proof
		unkeyed.proof_tag = blake3.derive_key("modus wide grant proof v1", unkeyed.terms_hash[:])
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &unkeyed, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	}

	// The origin is in the tag: a flipped origin is refused, and no proof
	// kind is accepted from remote display input even with a right tag.
	{
		bad := pass_proof
		bad.origin_word = u64(Proof_Origin.Local_Host_Key)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.origin_word = u64(Proof_Origin.Remote_Display_Input)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		// A remote origin with a right tag computed by the key holder is still refused.
		bad.proof_tag, _ = wide_grant_proof_tag(authority_key, &bad)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.origin_word = 0
		bad.proof_tag, _ = wide_grant_proof_tag(authority_key, &bad)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.origin_word = 99
		bad.proof_tag, _ = wide_grant_proof_tag(authority_key, &bad)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		_, remote_make := wide_grant_proof_make(authority_key, &terms, .Passphrase_Verified, .Remote_Display_Input, 8, unlock_token, 1000)
		testing.expect_value(t, remote_make, Wide_Grant_Refusal.Invalid_Proof)
		_, cross_make := wide_grant_proof_make(authority_key, &terms, .Host_Key_Signed, .Local_Unlock_Dialog, 8, host_key, 1000)
		testing.expect_value(t, cross_make, Wide_Grant_Refusal.Invalid_Proof)
	}

	// The serial: zero, equal to the last accepted one, and older are refused.
	{
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &pass_proof, {}, 7), Wide_Grant_Refusal.Invalid_Proof)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &pass_proof, {}, max(u64)), Wide_Grant_Refusal.Invalid_Proof)
		_, zero_serial := wide_grant_proof_make(authority_key, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, 0, unlock_token, 1000)
		testing.expect_value(t, zero_serial, Wide_Grant_Refusal.Missing_Proof)

		bad := pass_proof
		bad.proof_serial = 8
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	}

	// The windows: a proof of other terms is refused for these terms.
	{
		wider := terms
		wider.target_window_count = 3
		wider.target_window_ids[2] = 303
		testing.expect_value(t, wide_grant_terms_seal(&wider), Wide_Grant_Refusal.None)
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &wider, &pass_proof, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	}

	// Each field of the proof is in the tag.
	{
		bad := pass_proof
		bad.proof_tag[0] ~= 0x01
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.proof_tag = {}
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Missing_Proof)

		bad = pass_proof
		bad.terms_hash[0] ~= 0x80
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.principal_id = 99
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.proof_kind_word = 99
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.proof_timestamp_ms += 1
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)

		bad = pass_proof
		bad.verifier_key_or_token_hash[31] ~= 0x01
		testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &bad, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	}

	// The accepted case comes last.
	testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &pass_proof, {}, 6), Wide_Grant_Refusal.None)

	// Host key signed proof
	host_proof, host_make := wide_grant_proof_make(authority_key, &terms, .Host_Key_Signed, .Local_Host_Key, 9, host_key, 2000)
	testing.expect_value(t, host_make, Wide_Grant_Refusal.None)
	testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &host_proof, {}, 0), Wide_Grant_Refusal.Invalid_Proof)
	testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &host_proof, test_hash("wrong-key"), 0), Wide_Grant_Refusal.Invalid_Proof)
	testing.expect_value(t, wide_grant_proof_validate(authority_key, &terms, &host_proof, host_key, 0), Wide_Grant_Refusal.None)
}

@(test)
test_authority_key_and_new_enums_at_the_border :: proc(t: ^testing.T) {
	testing.expect(t, !authority_key_is_valid(authority_key_from_words({0, 0, 0, 0})))
	key := authority_key_from_words({1, 0, 0, max(u64)})
	testing.expect(t, authority_key_is_valid(key))
	testing.expect_value(t, key[0], u8(1))
	testing.expect_value(t, key[31], u8(0xFF))

	for word in ([?]u64{0, 4, 99, max(u64)}) {
		_, origin_ok := proof_origin_from_word(word)
		testing.expectf(t, !origin_ok, "proof origin word %d accepted", word)
		_, reason_ok := revocation_reason_from_word(word)
		testing.expectf(t, !reason_ok, "revocation reason word %d accepted", word)
	}
	origin, origin_ok := proof_origin_from_word(1)
	testing.expect(t, origin_ok && origin == .Local_Unlock_Dialog)
	reason, reason_ok := revocation_reason_from_word(3)
	testing.expect(t, reason_ok && reason == .Duplicate_Connection)
}

@(test)
test_act_record_and_chain_verification_detects_every_tampering :: proc(t: ^testing.T) {
	// Empty chain is valid only with genesis head hash
	empty: []Act_Record = nil
	r_empty, idx_empty := act_chain_verify(empty)
	testing.expect_value(t, r_empty, Wide_Grant_Refusal.None)
	testing.expect_value(t, idx_empty, u64(0))

	r_head, _ := act_chain_verify_with_head(empty, 0, test_hash("non-zero"))
	testing.expect_value(t, r_head, Wide_Grant_Refusal.Chain_Tampered)

	// Single record invalid edges
	{
		rec := Act_Record{sequence_number = 0, grant_serial = 0, act_kind_word = u64(Act_Kind.Frame_Read)}
		testing.expect_value(t, act_record_seal(&rec), Wide_Grant_Refusal.Chain_Tampered)

		rec = Act_Record{sequence_number = 0, grant_serial = 1, act_kind_word = 0}
		testing.expect_value(t, act_record_seal(&rec), Wide_Grant_Refusal.Chain_Tampered)

		rec = Act_Record{sequence_number = 0, grant_serial = 1, act_kind_word = 99}
		testing.expect_value(t, act_record_seal(&rec), Wide_Grant_Refusal.Chain_Tampered)

		// Window-scoped input act with window 0 refused
		rec = Act_Record{sequence_number = 0, grant_serial = 1, act_kind_word = u64(Act_Kind.Key_Injected), target_window_id = 0}
		testing.expect_value(t, act_record_seal(&rec), Wide_Grant_Refusal.Window_Not_In_Scope)
	}

	// Build a valid 6-record chain and verify it passes
	base_chain: [6]Act_Record
	build_chain(base_chain[:], 7, 1000)
	refusal, fail_idx := act_chain_verify(base_chain[:])
	testing.expect_value(t, refusal, Wide_Grant_Refusal.None)
	testing.expect_value(t, fail_idx, u64(0))

	head_refusal, head_idx := act_chain_verify_with_head(base_chain[:], 6, base_chain[5].record_hash)
	testing.expect_value(t, head_refusal, Wide_Grant_Refusal.None)
	testing.expect_value(t, head_idx, u64(0))

	// 1. Deleted middle record (index 2 removed) -> detected at index 2
	{
		deleted: [5]Act_Record
		deleted[0] = base_chain[0]
		deleted[1] = base_chain[1]
		deleted[2] = base_chain[3]
		deleted[3] = base_chain[4]
		deleted[4] = base_chain[5]
		r, idx := act_chain_verify(deleted[:])
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(2))
	}

	// 2. Deleted first record -> detected at index 0
	{
		r, idx := act_chain_verify(base_chain[1:])
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(0))
	}

	// 3. Tail truncation (last record removed) -> detected by head verification
	{
		r, idx := act_chain_verify_with_head(base_chain[:5], 6, base_chain[5].record_hash)
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(5))
	}

	// 4. Reordered records (swap index 2 and 3) -> detected at index 2
	{
		swapped := base_chain
		swapped[2], swapped[3] = swapped[3], swapped[2]
		r, idx := act_chain_verify(swapped[:])
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(2))
	}

	// 5. Modified field in record 3 (1-bit flip) -> detected at index 3
	{
		modified := base_chain
		modified[3].detail_word_0 ~= 1
		r, idx := act_chain_verify(modified[:])
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(3))
	}

	// 6. Modified and resealed record 3 without re-chaining record 4 -> detected at index 4!
	{
		forked := base_chain
		forked[3].detail_word_1 = 0xDEAD_BEEF
		testing.expect_value(t, act_record_seal(&forked[3]), Wide_Grant_Refusal.None)
		r, idx := act_chain_verify(forked[:])
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(4))
	}

	// 7. Backward timestamp (even if validly hash-chained!) -> detected at index 2
	{
		backward := base_chain
		backward[2].timestamp_ms = backward[1].timestamp_ms - 1
		testing.expect_value(t, act_record_seal(&backward[2]), Wide_Grant_Refusal.None)
		for i in 3 ..< len(backward) {
			backward[i].previous_hash = backward[i - 1].record_hash
			testing.expect_value(t, act_record_seal(&backward[i]), Wide_Grant_Refusal.None)
		}
		r, idx := act_chain_verify(backward[:])
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(2))
	}

	// 8. Sequence overflow edge case at max(u64)
	{
		overflow_pair: [2]Act_Record
		overflow_pair[0] = Act_Record {
			sequence_number  = max(u64),
			grant_serial     = 1,
			timestamp_ms     = 10,
			act_kind_word    = u64(Act_Kind.Grant_Started),
			previous_hash    = GENESIS_PREVIOUS_HASH,
		}
		testing.expect_value(t, act_record_seal(&overflow_pair[0]), Wide_Grant_Refusal.None)
		overflow_pair[1] = Act_Record {
			sequence_number  = 0,
			grant_serial     = 1,
			timestamp_ms     = 20,
			act_kind_word    = u64(Act_Kind.Frame_Read),
			previous_hash    = overflow_pair[0].record_hash,
		}
		testing.expect_value(t, act_record_seal(&overflow_pair[1]), Wide_Grant_Refusal.None)
		r, idx := act_chain_verify(overflow_pair[:], max(u64), GENESIS_PREVIOUS_HASH)
		testing.expect_value(t, r, Wide_Grant_Refusal.Chain_Tampered)
		testing.expect_value(t, idx, u64(1))
	}
}

@(test)
test_sensitive_actions_still_require_principal_proof :: proc(t: ^testing.T) {
	// Permitted normal agent actions
	testing.expect(t, !act_requires_principal_proof(.Normal_Window_Input))
	testing.expect(t, !act_requires_principal_proof(.Normal_Screen_Read))
	testing.expect(t, !act_requires_principal_proof(.Normal_Semantic_Read))

	// Strictly blocked sensitive actions (must ask principal even under a wide grant)
	testing.expect(t, act_requires_principal_proof(.None))
	testing.expect(t, act_requires_principal_proof(.Plans_Apply_Adding_Grant))
	testing.expect(t, act_requires_principal_proof(.Passphrase_Or_Unlock_Dialog))
	testing.expect(t, act_requires_principal_proof(.Trusted_Display_Grant_Dialog))
	testing.expect(t, act_requires_principal_proof(.Disk_Grant_Change))
	testing.expect(t, act_requires_principal_proof(.Principal_Management))
	testing.expect(t, act_requires_principal_proof(.Module_Replace_Or_Debug))
	testing.expect(t, act_requires_principal_proof(.Wide_Grant_Screen_Or_Mark))
}
