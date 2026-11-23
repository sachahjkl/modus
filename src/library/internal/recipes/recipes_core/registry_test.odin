#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

@(private = "file")
registry_hash :: proc(tag: u8) -> blake3.Hash {
	data := [3]u8{'r', 'g', tag}
	return blake3.hash(data[:])
}

@(private = "file")
// A recipe is about 90 KiB: it is written in place, never returned.
inputs_tree_spec :: proc(spec: ^pr.Recipe_Spec, builder: blake3.Hash) {
	spec^ = {}
	spec.builder_hash = builder
	spec.output_kind = .Tree
	spec.input_count = 2
	spec.inputs[0], _ = pr.recipe_input_make("src", .Tree, registry_hash(1))
	spec.inputs[1], _ = pr.recipe_input_make("lib", .Blob, registry_hash(2))
}

@(test)
a_registered_recipe_builds_once_then_comes_from_the_cache :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	registry := new(Recipe_Registry)
	defer free(registry)
	store := recipes_test_state_init(state)
	defer free(store)
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	inputs_tree_spec(spec, pr.inputs_tree_builder_hash())
	recipe, refusal := register_recipe(registry, spec)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	again, _ := register_recipe(registry, spec)
	testing.expect(t, again == recipe, "a recipe registered twice keeps one hash")

	first := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, first.refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, first.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	second := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, second.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect(t, second.output_hash == first.output_hash, "the cache gives the realisation of the build")
	only := build_registered(state, registry, recipe, .Cache_Only)
	testing.expect_value(t, only.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, state.counters.local_builds, u64(1))
	testing.expect_value(t, state.counters.cache_hits_local, u64(2))

	rows: [MAX_BUILD_HISTORY]pr.Recipe_Build_Row
	testing.expect_value(t, history_rows(registry, rows[:]), 3)
	testing.expect_value(t, rows[0].outcome_word, i64(pr.Recipe_Build_Outcome.Built_Locally))
	testing.expect_value(t, rows[2].mode_word, i64(pr.Build_Mode.Cache_Only))
	realisations: [4]pr.Realisation_Row
	testing.expect_value(t, realisation_rows(state, realisations[:]), 1)
	testing.expect_value(t, realisations[0].origin_word, i64(Provenance_Origin.Local_Build))
	testing.expect_value(t, realisation_rows(state, nil), 1)
}

@(test)
a_build_refuses_unknown_recipes_misses_and_foreign_builders :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	registry := new(Recipe_Registry)
	defer free(registry)
	store := recipes_test_state_init(state)
	defer free(store)

	unknown := build_registered(state, registry, registry_hash(9), .Prefer_Cache)
	testing.expect_value(t, unknown.refusal, pr.Recipe_Refusal.Unknown_Recipe)

	sandboxed_spec := new(pr.Recipe_Spec, context.temp_allocator)
	inputs_tree_spec(sandboxed_spec, registry_hash(8))
	recipe, _ := register_recipe(registry, sandboxed_spec)
	miss := build_registered(state, registry, recipe, .Cache_Only)
	testing.expect_value(t, miss.refusal, pr.Recipe_Refusal.Cache_Miss)
	sandboxed := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, sandboxed.refusal, pr.Recipe_Refusal.Builder_Needs_Sandbox)
	testing.expect_value(t, state.counters.local_builds, u64(0))
	testing.expect_value(t, realisation_rows(state, nil), 0)

	empty: pr.Recipe_Spec
	_, refusal := register_recipe(registry, &empty)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.Zero_Builder_Hash)
	_, refusal = register_recipe(nil, sandboxed_spec)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.Buffer_Too_Small)
}

@(test)
a_full_registry_refuses_and_keeps_its_recipes :: proc(t: ^testing.T) {
	registry := new(Recipe_Registry)
	defer free(registry)
	for index in 0 ..< MAX_REGISTERED_RECIPES {
		spec := new(pr.Recipe_Spec, context.temp_allocator)
		inputs_tree_spec(spec, registry_hash(u8(index + 10)))
		_, refusal := register_recipe(registry, spec)
		testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	}
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	inputs_tree_spec(spec, registry_hash(200))
	_, refusal := register_recipe(registry, spec)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.Recipe_Limit_Reached)
	kept := new(pr.Recipe_Spec, context.temp_allocator)
	inputs_tree_spec(kept, registry_hash(10))
	_, refusal = register_recipe(registry, kept)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
}

@(test)
the_history_keeps_the_newest_builds :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	registry := new(Recipe_Registry)
	defer free(registry)
	store := recipes_test_state_init(state)
	defer free(store)
	for _ in 0 ..< MAX_BUILD_HISTORY + 3 {
		build_registered(state, registry, registry_hash(1), .Prefer_Cache)
	}
	rows: [MAX_BUILD_HISTORY]pr.Recipe_Build_Row
	testing.expect_value(t, history_rows(registry, rows[:]), MAX_BUILD_HISTORY)
	testing.expect_value(t, history_rows(registry, rows[:1]), MAX_BUILD_HISTORY)
	testing.expect_value(t, registry.builds_total, u64(MAX_BUILD_HISTORY + 3))
}
