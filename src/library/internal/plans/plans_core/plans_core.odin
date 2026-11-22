// Pure state machine for the delegated plans service
// (src/md/features/declarations.md, "Apply, the difference and the rollback").
//
// Maintains per-principal applied_plans generation history in fixed-capacity
// tables with zero dynamic allocation:
// - computes authoritative Plan_Difference against the service's own copy of
//   the principal's current applied plan;
// - requires a verified trusted Display Show_Plan_Difference acceptance from
//   the powerbox whenever any grant is added or widened;
// - refuses stale applies when the current applied plan changed since the
//   difference was computed;
// - commits atomically to applied_plans generation highest + 1;
// - rolls back by updating current_generation without writing a new plan, so
//   a later apply never overwrites an existing generation.
package plans_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"

// Maximum distinct principals tracked simultaneously.
MAX_PRINCIPALS :: 8

// Maximum historical applied plans retained per principal.
MAX_HISTORY_PER_PRINCIPAL :: 32

// Per-principal authoritative applied plan table.
Principal_Plans_State :: struct {
	active:             bool,
	principal:          u64,
	current_generation: u64,
	highest_generation: u64,
	history_count:      u32,
	history:            [MAX_HISTORY_PER_PRINCIPAL]pr.Applied_Plan_Record,
	plans:              [MAX_HISTORY_PER_PRINCIPAL]pr.Plan_Spec,
}

// Aggregate counters for status inspection.
Plans_Counters :: struct {
	total_diffs:     u64,
	total_applies:   u64,
	total_rollbacks: u64,
	total_refusals:  u64,
}

// Complete fixed-capacity state of the plans service engine.
Plans_State :: struct {
	initialized:          bool,
	trusted_display_slot: u32,
	principals:           [MAX_PRINCIPALS]Principal_Plans_State,
	counters:             Plans_Counters,
}

// state_init resets state and binds the trusted Display role holder slot used
// to verify Show_Plan_Difference consent answers.
state_init :: proc "contextless" (state: ^Plans_State, trusted_display_slot: u32) {
	state^ = {}
	state.initialized = true
	state.trusted_display_slot = trusted_display_slot
}

@(private = "file")
find_principal :: proc "contextless" (state: ^Plans_State, principal: u64) -> ^Principal_Plans_State {
	for &entry in state.principals {
		if entry.active && entry.principal == principal {
			return &entry
		}
	}
	return nil
}

@(private = "file")
find_or_create_principal :: proc "contextless" (state: ^Plans_State, principal: u64) -> ^Principal_Plans_State {
	if existing := find_principal(state, principal); existing != nil {
		return existing
	}
	for &entry in state.principals {
		if !entry.active {
			entry = {active = true, principal = principal}
			return &entry
		}
	}
	return nil
}

@(private = "file")
find_generation_index :: proc "contextless" (entry: ^Principal_Plans_State, generation: u64) -> int {
	if entry == nil || generation == 0 {
		return -1
	}
	for index in u32(0) ..< entry.history_count {
		if entry.history[index].generation == generation {
			return int(index)
		}
	}
	return -1
}

// current_plan returns the authoritative current Plan_Spec and its
// Applied_Plan_Record for principal, or found = false when no plan is applied.
current_plan :: proc "contextless" (state: ^Plans_State, principal: u64) -> (plan: ^pr.Plan_Spec, record: pr.Applied_Plan_Record, found: bool) {
	entry := find_principal(state, principal)
	if entry == nil || entry.current_generation == 0 {
		return nil, {}, false
	}
	idx := find_generation_index(entry, entry.current_generation)
	if idx < 0 {
		return nil, {}, false
	}
	return &entry.plans[idx], entry.history[idx], true
}

// compute_difference validates proposed and writes its Plan_Difference into
// caller-supplied out_diff against the service's authoritative current applied
// plan for proposed.principal. Applies nothing.
compute_difference :: proc "contextless" (state: ^Plans_State, proposed: ^pr.Plan_Spec, out_diff: ^pr.Plan_Difference) -> pr.Plan_Refusal {
	if out_diff == nil {
		state.counters.total_refusals += 1
		return .Buffer_Too_Small
	}
	if proposed == nil {
		out_diff^ = {}
		state.counters.total_refusals += 1
		return .Empty_Plan
	}
	cur_plan, _, _ := current_plan(state, proposed.principal)
	refusal := pr.plan_diff_compute(cur_plan, proposed, out_diff)
	if refusal != .None {
		state.counters.total_refusals += 1
		return refusal
	}
	state.counters.total_diffs += 1
	return .None
}

// apply_plan validates proposed, writes its Plan_Difference into caller-supplied
// out_diff, verifies that the current applied plan hash still matches
// expected_current_hash, enforces trusted Show_Plan_Difference consent whenever
// any grant is added or widened, and atomically records the new generation into
// applied_plans. On any refusal, zero state changes occur.
apply_plan :: proc "contextless" (
	state: ^Plans_State,
	proposed: ^pr.Plan_Spec,
	expected_current_hash: blake3.Hash,
	consent_dialog: ^powerbox.Dialog_Record,
	consent_answer: ^powerbox.Grant_Answer,
	now_ms: u64,
	out_diff: ^pr.Plan_Difference,
) -> (record: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	if out_diff == nil {
		state.counters.total_refusals += 1
		return {}, .Buffer_Too_Small
	}
	if proposed == nil {
		out_diff^ = {}
		state.counters.total_refusals += 1
		return {}, .Empty_Plan
	}

	cur_plan, _, _ := current_plan(state, proposed.principal)
	refusal = pr.plan_diff_compute(cur_plan, proposed, out_diff)
	if refusal != .None {
		state.counters.total_refusals += 1
		return {}, refusal
	}

	// Refuse stale apply when the principal's current plan changed since the
	// difference was reviewed.
	if expected_current_hash != out_diff.current_plan_hash {
		state.counters.total_refusals += 1
		return {}, .Stale_Current_Plan
	}

	// Require verified trusted Display Show_Plan_Difference consent whenever
	// any grant is added or widened.
	if out_diff.any_grant_added {
		if consent_dialog == nil || consent_answer == nil {
			state.counters.total_refusals += 1
			return {}, .Consent_Required
		}
		if consent_dialog.action_word != u64(powerbox.Dialog_Action.Show_Plan_Difference) {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if consent_dialog.session_principal != proposed.principal {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if consent_dialog.item_count != 1 || consent_dialog.items[0].plan_hash != out_diff.proposed_plan_hash {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if pb_refusal, _ := powerbox.answer_record_validate(consent_dialog, consent_answer, state.trusted_display_slot); pb_refusal != .None {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
		if !consent_answer.whole_plan_accepted {
			state.counters.total_refusals += 1
			return {}, .Untrusted_Consent
		}
	}

	// Pre-check capacity before committing so no partial mutation can occur.
	entry := find_or_create_principal(state, proposed.principal)
	if entry == nil || entry.history_count >= MAX_HISTORY_PER_PRINCIPAL {
		state.counters.total_refusals += 1
		return {}, .History_Full
	}

	next_generation := entry.highest_generation + 1
	new_record := pr.Applied_Plan_Record {
		plan_hash          = out_diff.proposed_plan_hash,
		previous_plan_hash = out_diff.current_plan_hash,
		generation         = next_generation,
		timestamp_ms       = now_ms,
		principal          = proposed.principal,
	}

	// Atomic commit: write plan and generation record first, then advance the
	// current_generation commit pointer.
	slot_index := entry.history_count
	entry.plans[slot_index] = proposed^
	entry.history[slot_index] = new_record
	entry.history_count += 1
	entry.highest_generation = next_generation
	entry.current_generation = next_generation
	state.counters.total_applies += 1
	return new_record, .None
}

// rollback moves current_generation of principal to the immediately preceding
// generation (when has_target is false) or to target_generation (when true).
// Writes no new plan record; a subsequent apply writes highest_generation + 1.
rollback :: proc "contextless" (
	state: ^Plans_State,
	principal: u64,
	target_generation: u64 = 0,
	has_target: bool = false,
) -> (selected: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	entry := find_principal(state, principal)
	if entry == nil || entry.history_count == 0 || entry.current_generation == 0 {
		state.counters.total_refusals += 1
		return {}, .Empty_History
	}
	selected, refusal = pr.plan_rollback_check(entry.history[:entry.history_count], entry.current_generation, target_generation, has_target)
	if refusal != .None {
		state.counters.total_refusals += 1
		return {}, refusal
	}
	entry.current_generation = selected.generation
	state.counters.total_rollbacks += 1
	return selected, .None
}

// highest_generation returns the newest generation that an apply committed for
// principal, or 0 when no apply committed one. A rollback lowers the current
// generation and leaves this one: the next apply writes the generation after it,
// so no apply overwrites a generation that a rollback can still select.
highest_generation :: proc "contextless" (state: ^Plans_State, principal: u64) -> u64 {
	entry := find_principal(state, principal)
	if entry == nil {
		return 0
	}
	return entry.highest_generation
}

// rollback_target returns the record that a rollback with no target selects for
// principal, with the refusal that such a rollback gives, and changes no state
// and no counter: a reader sees the generation before it asks for the rollback.
rollback_target :: proc "contextless" (state: ^Plans_State, principal: u64) -> (selected: pr.Applied_Plan_Record, refusal: pr.Plan_Refusal) {
	entry := find_principal(state, principal)
	if entry == nil || entry.history_count == 0 || entry.current_generation == 0 {
		return {}, .Empty_History
	}
	return pr.plan_rollback_check(entry.history[:entry.history_count], entry.current_generation)
}

// history_snapshot copies the applied_plans history of principal into out and
// reports the count copied and the active current_generation.
history_snapshot :: proc "contextless" (
	state: ^Plans_State,
	principal: u64,
	out: []pr.Applied_Plan_Record,
) -> (count: int, current_generation: u64) {
	entry := find_principal(state, principal)
	if entry == nil {
		return 0, 0
	}
	limit := min(int(entry.history_count), len(out))
	for index in 0 ..< limit {
		out[index] = entry.history[index]
	}
	return limit, entry.current_generation
}
