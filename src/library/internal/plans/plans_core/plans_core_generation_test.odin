#+build !freestanding
package plans_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

@(private = "file")
generation_test_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'g', 'e', 'n', tag}
	return blake3.hash(data[:])
}

// apply_zero_grant_plan applies a plan of one module with no grant, so the
// test needs no consent, and returns its record.
@(private = "file")
apply_zero_grant_plan :: proc(t: ^testing.T, state: ^Plans_State, principal: u64, tag: u8, expected_current_hash: blake3.Hash, now_ms: u64) -> pr.Applied_Plan_Record {
	plan := test_plan(principal, 1)
	plan.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", generation_test_hash(tag), 0)
	scratch_diff: pr.Plan_Difference
	record, refusal := apply_plan(state, &plan, expected_current_hash, nil, nil, now_ms, &scratch_diff)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	return record
}

@(test)
test_plans_generation_queries_refuse_and_change_nothing :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)

	// A principal with no applied plan: no generation, and no rollback target.
	testing.expect_value(t, highest_generation(state, 0), u64(0))
	testing.expect_value(t, highest_generation(state, max(u64)), u64(0))
	_, no_history := rollback_target(state, 0)
	testing.expect_value(t, no_history, pr.Plan_Refusal.Empty_History)
	testing.expect_value(t, state.counters, Plans_Counters{})

	// One generation: a rollback with no target has nothing to select.
	first := apply_zero_grant_plan(t, state, 0, 1, {}, 100)
	testing.expect_value(t, highest_generation(state, 0), u64(1))
	_, at_first := rollback_target(state, 0)
	testing.expect_value(t, at_first, pr.Plan_Refusal.Empty_History)

	second := apply_zero_grant_plan(t, state, 0, 2, first.plan_hash, 200)
	third := apply_zero_grant_plan(t, state, 0, 3, second.plan_hash, 300)
	testing.expect_value(t, third.generation, u64(3))

	// The query selects the generation before the current one and changes no
	// state: the current generation and every counter stay the same.
	counters_before := state.counters
	target, target_refusal := rollback_target(state, 0)
	testing.expect_value(t, target_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, target.generation, u64(2))
	_, current_record, found := current_plan(state, 0)
	testing.expect(t, found, "a current plan stays after the query")
	testing.expect_value(t, current_record.generation, u64(3))
	testing.expect_value(t, state.counters, counters_before)

	// Another principal sees none of the generations of principal 0.
	testing.expect_value(t, highest_generation(state, 1), u64(0))
	_, other := rollback_target(state, 1)
	testing.expect_value(t, other, pr.Plan_Refusal.Empty_History)
}

@(test)
test_plans_rollback_refuses_bad_targets_and_keeps_the_highest_generation :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)

	first := apply_zero_grant_plan(t, state, 0, 1, {}, 100)
	second := apply_zero_grant_plan(t, state, 0, 2, first.plan_hash, 200)
	_ = apply_zero_grant_plan(t, state, 0, 3, second.plan_hash, 300)

	// Each target that names no generation is refused, and the current
	// generation stays 3.
	bad_targets := [?]u64{0, 4, 99, max(u64)}
	for bad in bad_targets {
		_, refusal := rollback_commit(state, 0, bad, true)
		testing.expect_value(t, refusal, pr.Plan_Refusal.Unknown_Generation)
		_, record, _ := current_plan(state, 0)
		testing.expect_value(t, record.generation, u64(3))
	}
	_, same := rollback_commit(state, 0, 3, true)
	testing.expect_value(t, same, pr.Plan_Refusal.Already_At_Generation)
	_, unknown_principal := rollback_commit(state, 7)
	testing.expect_value(t, unknown_principal, pr.Plan_Refusal.Empty_History)
	testing.expect_value(t, state.counters.total_rollbacks, u64(0))
	testing.expect_value(t, state.counters.total_refusals, u64(len(bad_targets) + 2))

	// A rollback lowers the current generation and keeps the highest one; the
	// query then names the generation before the new current one.
	selected, refusal := rollback_commit(state, 0)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, selected.generation, u64(2))
	testing.expect_value(t, highest_generation(state, 0), u64(3))
	target, _ := rollback_target(state, 0)
	testing.expect_value(t, target.generation, u64(1))

	// The next apply writes the generation after the highest one, not after
	// the current one, so generation 3 is never overwritten.
	fourth := apply_zero_grant_plan(t, state, 0, 4, second.plan_hash, 400)
	testing.expect_value(t, fourth.generation, u64(4))
	testing.expect_value(t, fourth.previous_plan_hash, second.plan_hash)
	testing.expect_value(t, highest_generation(state, 0), u64(4))
}

@(test)
test_plans_rollback_refuses_a_damaged_history :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)

	first := apply_zero_grant_plan(t, state, 0, 1, {}, 100)
	second := apply_zero_grant_plan(t, state, 0, 2, first.plan_hash, 200)
	_ = apply_zero_grant_plan(t, state, 0, 3, second.plan_hash, 300)
	entry := &state.principals[0]
	testing.expect(t, entry.active && entry.history_count == 3, "principal 0 holds three generations")

	// A zero plan hash in the history: the query and the rollback refuse, and
	// the current generation does not move.
	saved := entry.history[1]
	entry.history[1].plan_hash = {}
	_, zero_query := rollback_target(state, 0)
	testing.expect_value(t, zero_query, pr.Plan_Refusal.Zero_Plan_Hash)
	_, zero_rollback := rollback_commit(state, 0)
	testing.expect_value(t, zero_rollback, pr.Plan_Refusal.Zero_Plan_Hash)
	testing.expect_value(t, entry.current_generation, u64(3))
	entry.history[1] = saved

	// A record of another principal in the history.
	entry.history[2].principal = 9
	_, mismatch := rollback_commit(state, 0)
	testing.expect_value(t, mismatch, pr.Plan_Refusal.Principal_Mismatch)
	testing.expect_value(t, entry.current_generation, u64(3))
	entry.history[2].principal = 0

	// Generations out of order.
	entry.history[2].generation = 1
	_, order := rollback_commit(state, 0, 1, true)
	testing.expect_value(t, order, pr.Plan_Refusal.Bad_Header)
	entry.history[2].generation = 3

	// A current generation that no record holds.
	entry.current_generation = 17
	_, lost := rollback_commit(state, 0)
	testing.expect_value(t, lost, pr.Plan_Refusal.Unknown_Generation)
	_, lost_query := rollback_target(state, 0)
	testing.expect_value(t, lost_query, pr.Plan_Refusal.Unknown_Generation)
	testing.expect_value(t, entry.current_generation, u64(17))
	testing.expect_value(t, state.counters.total_rollbacks, u64(0))

	// With the history restored, the rollback passes.
	entry.current_generation = 3
	selected, restored := rollback_commit(state, 0)
	testing.expect_value(t, restored, pr.Plan_Refusal.None)
	testing.expect_value(t, selected.generation, u64(2))
}

@(test)
test_plans_difference_counts_only_accepted_plans :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)

	diff: pr.Plan_Difference
	testing.expect_value(t, compute_difference(state, nil, &diff), pr.Plan_Refusal.Empty_Plan)
	plan := test_plan(0, 1)
	plan.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", generation_test_hash(1), 0)
	testing.expect_value(t, compute_difference(state, &plan, nil), pr.Plan_Refusal.Buffer_Too_Small)

	// An entry count past the bound of the plan is refused.
	too_many := test_plan_copy(&plan)
	too_many.entry_count = max(u32)
	testing.expect(t, compute_difference(state, &too_many, &diff) != .None, "an entry count past the bound is refused")
	testing.expect_value(t, state.counters.total_diffs, u64(0))
	testing.expect_value(t, state.counters.total_refusals, u64(3))

	testing.expect_value(t, compute_difference(state, &plan, &diff), pr.Plan_Refusal.None)
	testing.expect_value(t, state.counters.total_diffs, u64(1))
}
