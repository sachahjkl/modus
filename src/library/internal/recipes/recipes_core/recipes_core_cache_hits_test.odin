#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"

@(test)
test_recipes_cache_hit_count_sums_without_wrapping :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)
	testing.expect_value(t, cache_hit_count(state), u64(0))

	state.counters.cache_hits_local = 3
	state.counters.cache_hits_remote = 4
	testing.expect_value(t, cache_hit_count(state), u64(7))

	// The edges of the sum: one side at the largest value, then both sides
	// whose sum passes it by one.
	state.counters.cache_hits_local = max(u64)
	state.counters.cache_hits_remote = 0
	testing.expect_value(t, cache_hit_count(state), max(u64))
	state.counters.cache_hits_local = 0
	state.counters.cache_hits_remote = max(u64)
	testing.expect_value(t, cache_hit_count(state), max(u64))
	state.counters.cache_hits_local = max(u64) / 2 + 1
	state.counters.cache_hits_remote = max(u64) / 2 + 1
	testing.expect_value(t, cache_hit_count(state), max(u64))
	state.counters.cache_hits_local = max(u64) - 1
	state.counters.cache_hits_remote = 1
	testing.expect_value(t, cache_hit_count(state), max(u64))
}

@(test)
test_recipes_refused_requests_count_no_build_and_no_hit :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)
	policy := object_cache.Substitution_Policy{mode = .Prefer_Cache}

	spec := pr.Recipe_Spec {
		output_kind        = .Tree,
		output_block_limit = 256,
	}

	// A mode word one past the last mode, a large one and the largest one,
	// then a recipe with no builder.
	bad_modes := [?]u8{u8(max(pr.Build_Mode)) + 1, 250, max(u8)}
	for word in bad_modes {
		result := build_recipe(state, &spec, pr.Build_Mode(word), policy, nil, nil, nil, nil)
		testing.expect_value(t, result.outcome, pr.Recipe_Build_Outcome.Refused)
		testing.expect_value(t, result.refusal, pr.Recipe_Refusal.Bad_Build_Mode)
	}
	empty := build_recipe(state, &spec, .Cache_First, policy, nil, nil, nil, nil)
	testing.expect_value(t, empty.outcome, pr.Recipe_Build_Outcome.Refused)
	testing.expect(t, empty.refusal != .None, "a recipe with no builder is refused")

	testing.expect_value(t, state.counters.total_builds, u64(0))
	testing.expect_value(t, cache_hit_count(state), u64(0))
	testing.expect_value(t, state.counters.total_refusals, u64(len(bad_modes) + 1))
}
