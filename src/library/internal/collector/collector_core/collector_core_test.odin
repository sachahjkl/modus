#+build !freestanding
package collector_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/wide_grants"

@(private = "file")
test_hash :: proc(label: string) -> blake3.Hash {
	raw := transmute([]u8)label
	return blake3.hash(raw)
}

@(private = "file")
test_authority_key :: proc() -> wide_grants.Authority_Key {
	return test_hash("unlock-authority-key")
}

@(private = "file")
make_sealed_terms :: proc(
	principal_id: u64,
	grantee_label: string,
	authorities: wide_grants.Wide_Authorities,
	windows: []u64,
	duration_ms: u64,
) -> wide_grants.Wide_Grant_Terms {
	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = principal_id,
		grantee_identity_hash = test_hash(grantee_label),
		authorities_word      = wide_grants.wide_authorities_to_word(authorities),
		target_window_count   = u32(len(windows)),
		duration_ms           = duration_ms,
		survives_restart      = false,
	}
	for id, index in windows {
		terms.target_window_ids[index] = id
	}
	_ = wide_grants.wide_grant_terms_seal(&terms)
	return terms
}

@(test)
test_collector_bounds_fail_closed_and_tamper_detection :: proc(t: ^testing.T) {
	collector: Act_Collector

	// Uninitialized collector fails closed
	_, uninit_refusal := collector_append(&collector, 1, 100, .Grant_Started, 0)
	testing.expect_value(t, uninit_refusal, wide_grants.Wide_Grant_Refusal.Act_Log_Full)
	uninit_verify, _ := collector_verify(&collector)
	testing.expect_value(t, uninit_verify, wide_grants.Wide_Grant_Refusal.Chain_Tampered)

	// Invalid capacities refused
	testing.expect(t, !collector_init(&collector, 0))
	testing.expect(t, !collector_init(&collector, COLLECTOR_ACT_CAPACITY + 1))
	testing.expect(t, !collector_init(&collector, max(u32)))

	// Valid small capacity = 4
	testing.expect(t, collector_init(&collector, 4))
	testing.expect_value(t, collector_remaining_capacity(&collector), u32(4))

	// Append 4 valid records
	r0, e0 := collector_append(&collector, 1, 100, .Grant_Started, 0, 1, 2)
	testing.expect_value(t, e0, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, r0.sequence_number, u64(0))
	testing.expect_value(t, r0.previous_hash, wide_grants.GENESIS_PREVIOUS_HASH)

	// Backward timestamp refused without changing state
	_, back_err := collector_append(&collector, 1, 99, .Frame_Read, 10)
	testing.expect_value(t, back_err, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, collector.count, u32(1))

	// Invalid grant_serial = 0 and Act_Kind.None refused without changing state
	_, zero_grant_err := collector_append(&collector, 0, 105, .Frame_Read, 10)
	testing.expect_value(t, zero_grant_err, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	_, none_kind_err := collector_append(&collector, 1, 105, .None, 10)
	testing.expect_value(t, none_kind_err, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, collector.count, u32(1))

	r1, e1 := collector_append(&collector, 1, 110, .Frame_Read, 10)
	testing.expect_value(t, e1, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, r1.previous_hash, r0.record_hash)

	r2, e2 := collector_append(&collector, 2, 120, .Key_Injected, 20, 'a', 0)
	testing.expect_value(t, e2, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, r2.previous_hash, r1.record_hash)

	// Append prebuilt record: wrong sequence refused, wrong previous hash refused, valid accepted
	bad_prebuilt := wide_grants.Act_Record {
		sequence_number  = 99,
		grant_serial     = 2,
		timestamp_ms     = 130,
		act_kind_word    = u64(wide_grants.Act_Kind.Pointer_Clicked),
		target_window_id = 20,
		previous_hash    = r2.record_hash,
	}
	_ = wide_grants.act_record_seal(&bad_prebuilt)
	testing.expect_value(t, collector_append_prebuilt(&collector, &bad_prebuilt), wide_grants.Wide_Grant_Refusal.Chain_Tampered)

	bad_prev := bad_prebuilt
	bad_prev.sequence_number = 3
	bad_prev.previous_hash = test_hash("wrong-prev")
	_ = wide_grants.act_record_seal(&bad_prev)
	testing.expect_value(t, collector_append_prebuilt(&collector, &bad_prev), wide_grants.Wide_Grant_Refusal.Chain_Tampered)

	good_prebuilt := wide_grants.Act_Record {
		sequence_number  = 3,
		grant_serial     = 2,
		timestamp_ms     = 130,
		act_kind_word    = u64(wide_grants.Act_Kind.Pointer_Clicked),
		target_window_id = 20,
		previous_hash    = r2.record_hash,
	}
	testing.expect_value(t, wide_grants.act_record_seal(&good_prebuilt), wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, collector_append_prebuilt(&collector, &good_prebuilt), wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, collector_remaining_capacity(&collector), u32(0))

	// Full collector fails closed (never evicts!) and increments refused_full_count
	_, full_err := collector_append(&collector, 2, 140, .Frame_Read, 20)
	testing.expect_value(t, full_err, wide_grants.Wide_Grant_Refusal.Act_Log_Full)
	testing.expect_value(t, collector.refused_full_count, u64(1))
	testing.expect_value(t, collector.count, u32(4))

	// Full chain verifies cleanly
	v_refusal, v_idx := collector_verify(&collector)
	testing.expect_value(t, v_refusal, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, v_idx, u64(0))

	// Query by grant and by window
	out: [2]wide_grants.Act_Record
	c_zero, t_zero := collector_query_by_grant(&collector, 0, out[:])
	testing.expect(t, c_zero == 0 && t_zero == 0)

	c_g1, t_g1 := collector_query_by_grant(&collector, 1, out[:])
	testing.expect(t, c_g1 == 2 && t_g1 == 2)
	testing.expect_value(t, out[0].sequence_number, u64(0))
	testing.expect_value(t, out[1].sequence_number, u64(1))

	c_w0, t_w0 := collector_query_by_window(&collector, 0, out[:])
	testing.expect(t, c_w0 == 0 && t_w0 == 0)

	small_out: [1]wide_grants.Act_Record
	c_w20, t_w20 := collector_query_by_window(&collector, 20, small_out[:])
	testing.expect(t, c_w20 == 1 && t_w20 == 2)
	testing.expect_value(t, small_out[0].sequence_number, u64(2))

	// Tamper record 2 in memory and confirm exact detection at index 2
	collector.records[2].detail_word_0 ~= 0xFF
	bad_v, bad_i := collector_verify(&collector)
	testing.expect_value(t, bad_v, wide_grants.Wide_Grant_Refusal.Chain_Tampered)
	testing.expect_value(t, bad_i, u64(2))
}

@(test)
test_wide_grant_manager_proofs_scopes_and_sensitive_blocks :: proc(t: ^testing.T) {
	host_key := test_hash("host-key-principal-0")
	unlock_token := test_hash("local-unlock-token")
	manager: Wide_Grant_Manager
	authority_key := test_authority_key()
	testing.expect(t, !manager_init(&manager, 0, {}, host_key, 64), "the all-zero authority key is refused")
	testing.expect(t, !manager.initialized)
	testing.expect(t, manager_init(&manager, 0, authority_key, host_key, 64))

	// Terms with survives_restart = true refused, nothing changed
	bad_terms := make_sealed_terms(0, "agent-1", {.View_Screen, .Send_Input}, {101, 202}, 60_000)
	bad_terms.survives_restart = true
	bad_proof := wide_grants.Wide_Grant_Proof{}
	_, r_restart := manager_create_grant(&manager, &bad_terms, &bad_proof, 1000, 1000 + bad_terms.duration_ms)
	testing.expect_value(t, r_restart, wide_grants.Wide_Grant_Refusal.Restart_Persistence_Forbidden)
	testing.expect_value(t, manager.collector.count, u32(0))

	// Valid terms, missing proof refused
	terms := make_sealed_terms(0, "agent-1", {.View_Screen, .Send_Input, .Read_Semantic_Tree}, {101, 202}, 60_000)
	_, r_missing := manager_create_grant(&manager, &terms, &bad_proof, 1000, 1000 + terms.duration_ms)
	testing.expect_value(t, r_missing, wide_grants.Wide_Grant_Refusal.Missing_Proof)
	testing.expect_value(t, manager.collector.count, u32(0))

	// Wrong principal refused
	other_principal_terms := make_sealed_terms(7, "agent-1", {.View_Screen}, {101}, 60_000)
	other_proof, _ := wide_grants.wide_grant_proof_make(authority_key, &other_principal_terms, .Passphrase_Verified, .Local_Unlock_Dialog, 1, unlock_token, 1000)
	_, r_principal := manager_create_grant(&manager, &other_principal_terms, &other_proof, 1000, 1000 + other_principal_terms.duration_ms)
	testing.expect_value(t, r_principal, wide_grants.Wide_Grant_Refusal.Invalid_Proof)

	// A proof forged without the authority key, or under the zero key, is refused.
	forged_proof, _ := wide_grants.wide_grant_proof_make(test_hash("forger-key"), &terms, .Passphrase_Verified, .Local_Unlock_Dialog, 1, unlock_token, 1000)
	_, r_forged := manager_create_grant(&manager, &terms, &forged_proof, 1000, 1000 + terms.duration_ms)
	testing.expect_value(t, r_forged, wide_grants.Wide_Grant_Refusal.Invalid_Proof)
	testing.expect_value(t, manager.collector.count, u32(0))

	// Create grant with Passphrase_Verified
	pass_proof, make_err := wide_grants.wide_grant_proof_make(authority_key, &terms, .Passphrase_Verified, .Local_Unlock_Dialog, 1, unlock_token, 1000)
	testing.expect_value(t, make_err, wide_grants.Wide_Grant_Refusal.None)
	serial_1, r_create := manager_create_grant(&manager, &terms, &pass_proof, 1000, 1000 + terms.duration_ms)
	testing.expect_value(t, r_create, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, serial_1, u64(1))
	testing.expect_value(t, manager.counters.active_grants, u64(1))
	testing.expect_value(t, manager.collector.count, u32(1))
	testing.expect_value(t, manager.last_accepted_proof_serial, u64(1))

	// The same proof used again is refused: a proof serial is used once.
	_, r_replay := manager_create_grant(&manager, &terms, &pass_proof, 1001, 1001 + terms.duration_ms)
	testing.expect_value(t, r_replay, wide_grants.Wide_Grant_Refusal.Invalid_Proof)
	testing.expect_value(t, manager.collector.count, u32(1))

	// Permitted acts within window scope succeed and are recorded
	rec_frame, e_frame := manager_authorize_and_record_act(&manager, serial_1, 1010, .Frame_Read, 0, .Normal_Screen_Read)
	testing.expect_value(t, e_frame, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, rec_frame.act_kind_word, u64(wide_grants.Act_Kind.Frame_Read))

	rec_key, e_key := manager_authorize_and_record_act(&manager, serial_1, 1020, .Key_Injected, 101, .Normal_Window_Input, 'x', 0)
	testing.expect_value(t, e_key, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, rec_key.target_window_id, u64(101))

	rec_sem, e_sem := manager_authorize_and_record_act(&manager, serial_1, 1030, .Action_Invoked, 202, .Normal_Semantic_Read, 5, 0)
	testing.expect_value(t, e_sem, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, rec_sem.target_window_id, u64(202))

	// Out-of-scope window 303 refused AND recorded as Forbidden_Act_Blocked
	rec_oob, e_oob := manager_authorize_and_record_act(&manager, serial_1, 1040, .Pointer_Clicked, 303, .Normal_Window_Input)
	testing.expect_value(t, e_oob, wide_grants.Wide_Grant_Refusal.Window_Not_In_Scope)
	testing.expect_value(t, rec_oob.act_kind_word, u64(wide_grants.Act_Kind.Forbidden_Act_Blocked))
	testing.expect_value(t, rec_oob.detail_word_0, u64(wide_grants.Wide_Grant_Refusal.Window_Not_In_Scope))

	// All sensitive actions blocked with Act_Still_Requires_Principal AND recorded
	sensitive_cases := [?]wide_grants.Sensitive_Action{
		.None,
		.Plans_Apply_Adding_Grant,
		.Passphrase_Or_Unlock_Dialog,
		.Trusted_Display_Grant_Dialog,
		.Disk_Grant_Change,
		.Principal_Management,
		.Module_Replace_Or_Debug,
		.Wide_Grant_Screen_Or_Mark,
	}
	for action, idx in sensitive_cases {
		rec_block, e_block := manager_authorize_and_record_act(&manager, serial_1, 1050 + u64(idx), .Key_Injected, 101, action)
		testing.expect_value(t, e_block, wide_grants.Wide_Grant_Refusal.Act_Still_Requires_Principal)
		testing.expect_value(t, rec_block.act_kind_word, u64(wide_grants.Act_Kind.Forbidden_Act_Blocked))
		testing.expect_value(t, rec_block.detail_word_1, u64(action))
	}

	// Forged lifecycle act kind refused AND recorded
	rec_forge, e_forge := manager_authorize_and_record_act(&manager, serial_1, 1100, .Grant_Started, 101, .Normal_Window_Input)
	testing.expect_value(t, e_forge, wide_grants.Wide_Grant_Refusal.Invalid_Authority)
	testing.expect_value(t, rec_forge.act_kind_word, u64(wide_grants.Act_Kind.Forbidden_Act_Blocked))

	// Replacement grant for same grantee (via Host_Key_Signed, View_Screen only) revokes old serial_1 whole
	view_only_terms := make_sealed_terms(0, "agent-1", {.View_Screen}, {101}, 5000)
	host_proof, h_err := wide_grants.wide_grant_proof_make(authority_key, &view_only_terms, .Host_Key_Signed, .Local_Host_Key, 2, host_key, 1200)
	testing.expect_value(t, h_err, wide_grants.Wide_Grant_Refusal.None)
	serial_2, r_replace := manager_create_grant(&manager, &view_only_terms, &host_proof, 1200, 1200 + view_only_terms.duration_ms)
	testing.expect_value(t, r_replace, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, serial_2, u64(2))
	testing.expect_value(t, manager.counters.active_grants, u64(1))

	// Old grant serial_1 is now Revoked
	_, e_old := manager_authorize_and_record_act(&manager, serial_1, 1210, .Frame_Read, 101, .Normal_Screen_Read)
	testing.expect_value(t, e_old, wide_grants.Wide_Grant_Refusal.Grant_Revoked)

	// New grant serial_2 permits Frame_Read but refuses Key_Injected (no Send_Input)
	_, e_v2 := manager_authorize_and_record_act(&manager, serial_2, 1220, .Frame_Read, 101, .Normal_Screen_Read)
	testing.expect_value(t, e_v2, wide_grants.Wide_Grant_Refusal.None)
	_, e_no_input := manager_authorize_and_record_act(&manager, serial_2, 1230, .Key_Injected, 101, .Normal_Window_Input)
	testing.expect_value(t, e_no_input, wide_grants.Wide_Grant_Refusal.Invalid_Authority)

	// Whole chain verifies cleanly
	v_refusal, v_idx := manager_verify_chain(&manager)
	testing.expect_value(t, v_refusal, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, v_idx, u64(0))
}

// The one end time of a grant comes from the root service with
// Create_Grant: an end at now, before now, or past the duration that the
// proof covers is refused with no grant; an end shorter than the duration
// is taken, and the grant expires at it, not at now plus the duration.
@(test)
the_end_time_of_a_grant_is_the_one_of_the_root_service :: proc(t: ^testing.T) {
	host_key := test_hash("host-key-end-time")
	authority_key := test_authority_key()
	manager: Wide_Grant_Manager
	testing.expect(t, manager_init(&manager, 0, authority_key, host_key, 32))
	terms := make_sealed_terms(0, "agent-end-time", {.View_Screen}, {7}, 500)
	proof, _ := wide_grants.wide_grant_proof_make(authority_key, &terms, .Host_Key_Signed, .Local_Host_Key, 1, host_key, 1000)
	for ends_at in ([?]u64{0, 999, 1000, 1501, max(u64)}) {
		serial, refusal := manager_create_grant(&manager, &terms, &proof, 1000, ends_at)
		testing.expectf(t, serial == 0 && refusal == .Duration_Past_Bound, "the end %d is taken", ends_at)
	}
	testing.expect_value(t, manager.counters.active_grants, u64(0))
	serial, refusal := manager_create_grant(&manager, &terms, &proof, 1000, 1200)
	testing.expect_value(t, refusal, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, manager_expire_grants(&manager, 1199), u32(0))
	testing.expect_value(t, manager_expire_grants(&manager, 1200), u32(1))
	state, expires_ms, found := manager_grant_state(&manager, serial)
	testing.expect(t, found && state == .Expired && expires_ms == 1200)
}

@(test)
test_wide_grant_expiry_revocation_suspension_and_full_log_fail_closed :: proc(t: ^testing.T) {
	host_key := test_hash("host-key-headless")
	manager: Wide_Grant_Manager
	// Tight collector capacity of 3: 1 Grant_Started + 2 acts max!
	authority_key := test_authority_key()
	testing.expect(t, manager_init(&manager, 0, authority_key, host_key, 3))

	terms := make_sealed_terms(0, "agent-tight", {.View_Screen, .Send_Input}, {42}, 500)
	proof, _ := wide_grants.wide_grant_proof_make(authority_key, &terms, .Host_Key_Signed, .Local_Host_Key, 1, host_key, 1000)
	serial, r_create := manager_create_grant(&manager, &terms, &proof, 1000, 1000 + terms.duration_ms)
	testing.expect_value(t, r_create, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, manager.collector.count, u32(1))

	// Act 1 and Act 2 fill remaining capacity
	_, e1 := manager_authorize_and_record_act(&manager, serial, 1100, .Frame_Read, 42, .Normal_Screen_Read)
	testing.expect_value(t, e1, wide_grants.Wide_Grant_Refusal.None)
	_, e2 := manager_authorize_and_record_act(&manager, serial, 1200, .Key_Injected, 42, .Normal_Window_Input)
	testing.expect_value(t, e2, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, manager.collector.count, u32(3))
	testing.expect_value(t, manager.counters.total_acts_permitted, u64(2))

	// Act 3 MUST fail closed with Act_Log_Full — no unrecorded act ever runs!
	_, e3 := manager_authorize_and_record_act(&manager, serial, 1250, .Pointer_Moved, 42, .Normal_Window_Input)
	testing.expect_value(t, e3, wide_grants.Wide_Grant_Refusal.Act_Log_Full)
	testing.expect_value(t, manager.counters.total_acts_permitted, u64(2))
	testing.expect_value(t, manager.collector.refused_full_count, u64(1))

	// A revocation without a reason is refused and changes nothing.
	testing.expect_value(t, manager_revoke_grant(&manager, serial, 1255, .None), wide_grants.Wide_Grant_Refusal.Grant_Revoked)
	testing.expect_value(t, manager.counters.active_grants, u64(1))

	// One-press revocation MUST still succeed even when act log is full!
	testing.expect_value(t, manager_revoke_grant(&manager, serial, 1260, .Principal_Revoked), wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, manager.counters.active_grants, u64(0))
	grant_info, found := manager_get_grant(&manager, serial)
	testing.expect(t, found && grant_info.state == .Revoked)

	// After revocation, acts fail with Grant_Revoked
	_, e_after_rev := manager_authorize_and_record_act(&manager, serial, 1270, .Frame_Read, 42, .Normal_Screen_Read)
	testing.expect_value(t, e_after_rev, wide_grants.Wide_Grant_Refusal.Grant_Revoked)

	// Chain stays completely valid despite refused full writes
	v_ref, _ := manager_verify_chain(&manager)
	testing.expect_value(t, v_ref, wide_grants.Wide_Grant_Refusal.None)

	// Test monotonic expiry + duplicate connection suspension in fresh manager
	testing.expect(t, manager_init(&manager, 0, authority_key, host_key, 32))
	t_exp := make_sealed_terms(0, "agent-exp", {.View_Screen}, {10}, 100)
	p_exp, _ := wide_grants.wide_grant_proof_make(authority_key, &t_exp, .Host_Key_Signed, .Local_Host_Key, 1, host_key, 5000)
	s_exp, _ := manager_create_grant(&manager, &t_exp, &p_exp, 5000, 5000 + t_exp.duration_ms)

	// At expires_ms - 1 (5099): still active
	_, e_before := manager_authorize_and_record_act(&manager, s_exp, 5099, .Frame_Read, 10, .Normal_Screen_Read)
	testing.expect_value(t, e_before, wide_grants.Wide_Grant_Refusal.None)

	// At expires_ms (5100): expires immediately and records Grant_Expired
	_, e_at := manager_authorize_and_record_act(&manager, s_exp, 5100, .Frame_Read, 10, .Normal_Screen_Read)
	testing.expect_value(t, e_at, wide_grants.Wide_Grant_Refusal.Grant_Expired)
	g_exp, _ := manager_get_grant(&manager, s_exp)
	testing.expect_value(t, g_exp.state, wide_grants.Wide_Grant_State.Expired)

	// Backward clock refused
	_, e_back := manager_authorize_and_record_act(&manager, s_exp, 5050, .Frame_Read, 10, .Normal_Screen_Read)
	testing.expect_value(t, e_back, wide_grants.Wide_Grant_Refusal.Chain_Tampered)

	// Duplicate connection suspension
	t_dup := make_sealed_terms(0, "agent-dup", {.View_Screen}, {10}, 10_000)
	p_dup, _ := wide_grants.wide_grant_proof_make(authority_key, &t_dup, .Host_Key_Signed, .Local_Host_Key, 2, host_key, 5200)
	s_dup, _ := manager_create_grant(&manager, &t_dup, &p_dup, 5200, 5200 + t_dup.duration_ms)
	testing.expect_value(t, manager_suspend_for_duplicate_connection(&manager, s_dup, 5210), wide_grants.Wide_Grant_Refusal.None)
	g_dup, _ := manager_get_grant(&manager, s_dup)
	testing.expect(t, g_dup.state == .Revoked && g_dup.suspended_for_duplicate_connection)
	_, e_after_dup := manager_authorize_and_record_act(&manager, s_dup, 5220, .Frame_Read, 10, .Normal_Screen_Read)
	testing.expect_value(t, e_after_dup, wide_grants.Wide_Grant_Refusal.Grant_Revoked)

	// Sweep expiry test on a third grant
	t_sweep := make_sealed_terms(0, "agent-sweep", {.View_Screen}, {10}, 200)
	p_sweep, _ := wide_grants.wide_grant_proof_make(authority_key, &t_sweep, .Host_Key_Signed, .Local_Host_Key, 3, host_key, 5300)
	s_sweep, _ := manager_create_grant(&manager, &t_sweep, &p_sweep, 5300, 5300 + t_sweep.duration_ms)
	testing.expect_value(t, manager_expire_grants(&manager, 5499), u32(0))
	testing.expect_value(t, manager_expire_grants(&manager, 5500), u32(1))
	g_sweep, _ := manager_get_grant(&manager, s_sweep)
	testing.expect_value(t, g_sweep.state, wide_grants.Wide_Grant_State.Expired)

	v_ref2, v_idx2 := manager_verify_chain(&manager)
	testing.expect_value(t, v_ref2, wide_grants.Wide_Grant_Refusal.None)
	testing.expect_value(t, v_idx2, u64(0))
}
