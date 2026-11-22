#+build !freestanding
package plans_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"
import "modus:contract/start_grant"

TRUSTED_DISPLAY_SLOT :: u32(5)

@(private = "file")
make_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'p', 'l', 'n', tag}
	return blake3.hash(data[:])
}

@(private = "file")
make_plan_consent :: proc(
	diff: ^pr.Plan_Difference,
	principal: u64,
	accepted: bool,
	display_slot: u32 = TRUSTED_DISPLAY_SLOT,
	origin: powerbox.Input_Origin = .Local_Machine,
) -> (dialog: powerbox.Dialog_Record, answer: powerbox.Grant_Answer) {
	batch, _ := pr.plan_difference_to_powerbox_batch(diff, 10, 3, principal, make_hash(99))
	dialog = powerbox.Dialog_Record {
		action_word         = u64(powerbox.Dialog_Action.Show_Plan_Difference),
		dialog_serial       = 77,
		request_serial      = batch.request_serial,
		session_principal   = principal,
		asker_process_slot  = batch.asker_process_slot,
		asker_module_origin = batch.asker_module_origin,
		asker_module_hash   = batch.asker_module_hash,
		asker_label_bytes   = batch.asker_label_bytes,
		asker_label_length  = batch.asker_label_length,
		item_count          = 1,
	}
	dialog.items[0] = batch.items[0]
	_ = powerbox.dialog_record_seal(&dialog)

	answer = powerbox.Grant_Answer {
		dialog_serial            = dialog.dialog_serial,
		request_serial           = dialog.request_serial,
		dialog_record_hash       = dialog.record_hash,
		display_holder_slot      = display_slot,
		input_origin_word        = u64(origin),
		shown_timestamp_ms       = 1000,
		input_press_timestamp_ms = 1300,
		answer_timestamp_ms      = 1350,
		whole_plan_accepted      = accepted,
		item_count               = 1,
	}
	answer.items[0] = {
		decision_word = accepted ? u64(powerbox.Item_Decision.Granted) : u64(powerbox.Item_Decision.Refused),
		duration_word = u64(powerbox.Grant_Duration.None),
	}
	return dialog, answer
}

@(test)
test_plans_apply_requires_trusted_consent_on_added_grants :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, TRUSTED_DISPLAY_SLOT)
	defer free(store)

	store_bit := u64(1) << u64(start_grant.Grant.Store)
	net_bit := u64(1) << u64(start_grant.Grant.Network)

	// Plan 1: zero-grant module applies with no added grant.
	p1 := pr.Plan_Spec{principal = 0, entry_count = 1}
	p1.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", make_hash(1), 0)

	// Nil out_diff is refused cleanly with no state change.
	testing.expect_value(t, compute_difference(state, &p1, nil), pr.Plan_Refusal.Buffer_Too_Small)
	_, nil_diff_ref := apply_plan(state, &p1, {}, nil, nil, 1000, nil)
	testing.expect_value(t, nil_diff_ref, pr.Plan_Refusal.Buffer_Too_Small)

	diff1: pr.Plan_Difference
	dref1 := compute_difference(state, &p1, &diff1)
	testing.expect_value(t, dref1, pr.Plan_Refusal.None)
	testing.expect(t, !diff1.any_grant_added, "zero-grant module adds no grant")

	scratch_diff: pr.Plan_Difference
	rec1, aref1 := apply_plan(state, &p1, {}, nil, nil, 1000, &scratch_diff)
	testing.expect_value(t, aref1, pr.Plan_Refusal.None)
	testing.expect_value(t, rec1.generation, u64(1))

	// Plan 2: adds Store grant -> refused without consent, refused on forged/remote/declined consent.
	p2 := pr.Plan_Spec{principal = 0, entry_count = 1}
	p2.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", make_hash(1), store_bit)

	diff2: pr.Plan_Difference
	dref2 := compute_difference(state, &p2, &diff2)
	testing.expect_value(t, dref2, pr.Plan_Refusal.None)
	testing.expect(t, diff2.any_grant_added, "adding Store grant requires consent")

	_, ref_no_consent := apply_plan(state, &p2, rec1.plan_hash, nil, nil, 2000, &scratch_diff)
	testing.expect_value(t, ref_no_consent, pr.Plan_Refusal.Consent_Required)

	// Declined consent refused.
	dlg_decl, ans_decl := make_plan_consent(&diff2, 0, false)
	_, ref_decl := apply_plan(state, &p2, rec1.plan_hash, &dlg_decl, &ans_decl, 2000, &scratch_diff)
	testing.expect_value(t, ref_decl, pr.Plan_Refusal.Untrusted_Consent)

	// Wrong display slot refused.
	dlg_slot, ans_slot := make_plan_consent(&diff2, 0, true, TRUSTED_DISPLAY_SLOT + 1)
	_, ref_slot := apply_plan(state, &p2, rec1.plan_hash, &dlg_slot, &ans_slot, 2000, &scratch_diff)
	testing.expect_value(t, ref_slot, pr.Plan_Refusal.Untrusted_Consent)

	// Remote display input refused.
	dlg_rem, ans_rem := make_plan_consent(&diff2, 0, true, TRUSTED_DISPLAY_SLOT, .Remote_Display)
	_, ref_rem := apply_plan(state, &p2, rec1.plan_hash, &dlg_rem, &ans_rem, 2000, &scratch_diff)
	testing.expect_value(t, ref_rem, pr.Plan_Refusal.Untrusted_Consent)

	// Stale expected_current_hash refused even with valid consent.
	dlg_ok, ans_ok := make_plan_consent(&diff2, 0, true)
	_, ref_stale := apply_plan(state, &p2, make_hash(200), &dlg_ok, &ans_ok, 2000, &scratch_diff)
	testing.expect_value(t, ref_stale, pr.Plan_Refusal.Stale_Current_Plan)

	// Valid trusted Show_Plan_Difference acceptance commits generation 2 atomically.
	rec2, aref2 := apply_plan(state, &p2, rec1.plan_hash, &dlg_ok, &ans_ok, 2000, &scratch_diff)
	testing.expect_value(t, aref2, pr.Plan_Refusal.None)
	testing.expect_value(t, rec2.generation, u64(2))
	testing.expect_value(t, rec2.previous_plan_hash, rec1.plan_hash)

	// Consent for p2 cannot be replayed for p3 (different plan hash).
	p3 := pr.Plan_Spec{principal = 0, entry_count = 1}
	p3.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", make_hash(1), store_bit | net_bit)
	_, ref_replay := apply_plan(state, &p3, rec2.plan_hash, &dlg_ok, &ans_ok, 3000, &scratch_diff)
	testing.expect_value(t, ref_replay, pr.Plan_Refusal.Untrusted_Consent)
}

@(test)
test_plans_rollback_and_monotonic_generation_history :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, TRUSTED_DISPLAY_SLOT)
	defer free(store)

	// Rollback on empty history refused.
	_, empty_ref := rollback_commit(state, 0)
	testing.expect_value(t, empty_ref, pr.Plan_Refusal.Empty_History)

	// Apply gen 1, gen 2, gen 3 (all zero-grant modules to test history & rollback directly).
	scratch_diff: pr.Plan_Difference
	p1 := pr.Plan_Spec{principal = 0, entry_count = 1}
	p1.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "a", make_hash(1), 0)
	r1, err1 := apply_plan(state, &p1, {}, nil, nil, 100, &scratch_diff)
	testing.expect_value(t, err1, pr.Plan_Refusal.None)

	// Rollback from gen 1 refused (no previous generation).
	_, rb1_ref := rollback_commit(state, 0)
	testing.expect_value(t, rb1_ref, pr.Plan_Refusal.Empty_History)

	p2 := pr.Plan_Spec{principal = 0, entry_count = 1}
	p2.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "a", make_hash(2), 0)
	r2, err2 := apply_plan(state, &p2, r1.plan_hash, nil, nil, 200, &scratch_diff)
	testing.expect_value(t, err2, pr.Plan_Refusal.None)

	p3 := pr.Plan_Spec{principal = 0, entry_count = 1}
	p3.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "a", make_hash(3), 0)
	r3, err3 := apply_plan(state, &p3, r2.plan_hash, nil, nil, 300, &scratch_diff)
	testing.expect_value(t, err3, pr.Plan_Refusal.None)
	testing.expect_value(t, r3.generation, u64(3))

	// Rollback without target selects gen 2 and writes no new plan.
	sel2, rb2_ref := rollback_commit(state, 0)
	testing.expect_value(t, rb2_ref, pr.Plan_Refusal.None)
	testing.expect_value(t, sel2.generation, u64(2))

	hist: [MAX_HISTORY_PER_PRINCIPAL]pr.Applied_Plan_Record
	count, cur_gen, _ := history_snapshot(state, 0, hist[:])
	testing.expect_value(t, count, 3)
	testing.expect_value(t, cur_gen, u64(2))

	// Explicit rollback to gen 1 succeeds; rollback to current gen 1 refused.
	sel1, rb_to1 := rollback_commit(state, 0, 1, true)
	testing.expect_value(t, rb_to1, pr.Plan_Refusal.None)
	testing.expect_value(t, sel1.generation, u64(1))

	_, rb_same := rollback_commit(state, 0, 1, true)
	testing.expect_value(t, rb_same, pr.Plan_Refusal.Already_At_Generation)

	// Next apply after rollback writes generation 4 (never overwrites 2 or 3).
	p4 := pr.Plan_Spec{principal = 0, entry_count = 1}
	p4.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "a", make_hash(4), 0)
	r4, err4 := apply_plan(state, &p4, r1.plan_hash, nil, nil, 400, &scratch_diff)
	testing.expect_value(t, err4, pr.Plan_Refusal.None)
	testing.expect_value(t, r4.generation, u64(4))
	testing.expect_value(t, r4.previous_plan_hash, r1.plan_hash)

	count, cur_gen, _ = history_snapshot(state, 0, hist[:])
	testing.expect_value(t, count, 4)
	testing.expect_value(t, cur_gen, u64(4))
}
