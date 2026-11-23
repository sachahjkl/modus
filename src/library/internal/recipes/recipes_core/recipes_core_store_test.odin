#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"

// recipes_test_state_init starts state with a memory store that the test
// frees.
recipes_test_state_init :: proc(state: ^Recipes_State) -> ^pr.Memory_Private_Store {
	store := new(pr.Memory_Private_Store)
	state_init(state, pr.memory_private_store_port(store))
	return store
}

@(private = "file")
store_test_hash :: proc(tag: u8) -> blake3.Hash {
	data := [3]u8{'s', 't', tag}
	return blake3.hash(data[:])
}

@(private = "file")
store_test_spec :: proc(spec: ^pr.Recipe_Spec) {
	spec^ = {}
	spec.builder_hash = pr.inputs_tree_builder_hash()
	spec.output_kind = .Tree
	spec.input_count = 2
	spec.inputs[0], _ = pr.recipe_input_make("src", .Tree, store_test_hash(1))
	spec.inputs[1], _ = pr.recipe_input_make("lib", .Blob, store_test_hash(2))
}

@(test)
a_realisation_in_the_store_answers_a_build_after_a_start_with_no_rebuild :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	registry := new(Recipe_Registry)
	defer free(registry)
	store := recipes_test_state_init(state)
	defer free(store)
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	store_test_spec(spec)
	recipe, _ := register_recipe(registry, spec)

	first := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, first.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	name := pr.realisation_object_name(recipe)
	testing.expect(t, pr.memory_private_store_find(store, pr.private_object_name_text(&name)) != nil, "the build wrote its realisation")
	testing.expect_value(t, len(pr.private_object_name_text(&name)), 64)

	// A service that starts again has an empty memory and the same store: the
	// build takes the realisation from the store and runs no builder.
	state_init(state, pr.memory_private_store_port(store))
	for mode in ([?]pr.Build_Mode{.Prefer_Cache, .Cache_Only}) {
		again := build_registered(state, registry, recipe, mode)
		testing.expect_value(t, again.outcome, pr.Recipe_Build_Outcome.From_Cache)
		testing.expect(t, again.output_hash == first.output_hash, "the store gives the output of the build")
	}
	testing.expect_value(t, state.counters.local_builds, u64(0))
	testing.expect_value(t, state.counters.cache_hits_store, u64(1))
	testing.expect_value(t, state.counters.cache_hits_local, u64(2))

	// Build_Only builds again and gives the same output: the build is
	// deterministic.
	rebuilt := build_registered(state, registry, recipe, .Build_Only)
	testing.expect_value(t, rebuilt.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect(t, rebuilt.output_hash == first.output_hash, "a rebuild gives the same output hash")
}

@(test)
the_recipe_hash_is_deterministic_and_names_each_part :: proc(t: ^testing.T) {
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	store_test_spec(spec)
	first, refusal := pr.recipe_hash(spec)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	second, _ := pr.recipe_hash(spec)
	testing.expect(t, first == second, "one recipe has one hash")
	// The order of the input table does not change the hash.
	swapped := new(pr.Recipe_Spec, context.temp_allocator)
	store_test_spec(swapped)
	swapped.inputs[0], swapped.inputs[1] = spec.inputs[1], spec.inputs[0]
	swapped_hash, _ := pr.recipe_hash(swapped)
	testing.expect(t, swapped_hash == first, "the inputs are hashed in the order of their names")
	// A changed input hash, input kind, builder or output kind gives another hash.
	changes := new([4]pr.Recipe_Spec, context.temp_allocator)
	for &change in changes {
		store_test_spec(&change)
	}
	changes[0].inputs[0], _ = pr.recipe_input_make("src", .Tree, store_test_hash(9))
	changes[1].inputs[1], _ = pr.recipe_input_make("lib", .Tree, store_test_hash(2))
	changes[2].builder_hash = store_test_hash(7)
	changes[3].output_kind = .Blob
	for &changed, index in changes {
		digest, changed_refusal := pr.recipe_hash(&changed)
		testing.expectf(t, changed_refusal == .None && digest != first, "change %d gives another hash", index)
	}
}

// A head that does not decode is refused, and builds nothing: the store is
// damaged, and a build would hide it.
@(test)
a_damaged_realisation_in_the_store_is_refused_and_builds_nothing :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	registry := new(Recipe_Registry)
	defer free(registry)
	store := recipes_test_state_init(state)
	defer free(store)
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	store_test_spec(spec)
	recipe, _ := register_recipe(registry, spec)
	_ = build_registered(state, registry, recipe, .Prefer_Cache)
	name := pr.realisation_object_name(recipe)
	object := pr.memory_private_store_find(store, pr.private_object_name_text(&name))
	saved := object^
	testing.expect_value(t, saved.length, pr.REALISATION_OBJECT_HEAD_SIZE)
	damages := [?]struct {
		offset: int,
		length: int,
	} {
		{0, -1}, // The magic.
		{8, -1}, // A byte of the recipe hash.
		{72, -1}, // The output kind.
		{80, -1}, // The origin.
		{pr.REALISATION_OBJECT_HEAD_SIZE - 1, -1}, // The count of the output bytes, past one object of a cache.
		{-1, pr.REALISATION_OBJECT_HEAD_SIZE - 1}, // Shorter than its head.
		{-1, pr.REALISATION_OBJECT_HEAD_SIZE + 1}, // One byte more.
	}
	for damage, index in damages {
		object^ = saved
		if damage.offset >= 0 {
			object.bytes[damage.offset] ~= 0x41
		} else {
			object.length = damage.length
		}
		state_init(state, pr.memory_private_store_port(store))
		result := build_registered(state, registry, recipe, .Prefer_Cache)
		testing.expectf(t, result.outcome == .Refused && result.refusal == .Store_Damaged, "damage %d: %v %v", index, result.outcome, result.refusal)
		testing.expect_value(t, state.counters.local_builds, u64(0))
		_, found := query_provenance(state, recipe)
		testing.expect(t, !found)
	}
	// The store whole again: the realisation reads.
	object^ = saved
	state_init(state, pr.memory_private_store_port(store))
	whole := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, whole.outcome, pr.Recipe_Build_Outcome.From_Cache)
}

// An output that the store lacks, or whose bytes are not its hash, is a
// miss: the build runs again and writes the output again, and the next
// build takes it from the store. Cache_Only runs no build, and misses.
@(test)
an_absent_or_damaged_output_builds_again :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	registry := new(Recipe_Registry)
	defer free(registry)
	store := recipes_test_state_init(state)
	defer free(store)
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	store_test_spec(spec)
	recipe, _ := register_recipe(registry, spec)
	first := build_registered(state, registry, recipe, .Prefer_Cache)
	output_name := pr.blob_object_name(first.output_hash)
	head_name := pr.realisation_object_name(recipe)
	head := pr.memory_private_store_find(store, pr.private_object_name_text(&head_name))
	Damage :: enum {
		Output_Removed,
		Output_Byte,
		Output_Shorter,
		Output_Longer,
		Head_Output_Hash,
		Head_Count,
	}
	for damage in Damage {
		output := pr.memory_private_store_find(store, pr.private_object_name_text(&output_name))
		if !testing.expectf(t, output != nil, "%v: the output is in the store", damage) {
			return
		}
		switch damage {
		case .Output_Removed:
			output^ = {}
		case .Output_Byte:
			output.bytes[3] ~= 0x41
		case .Output_Shorter:
			output.length -= 1
		case .Output_Longer:
			output.length += 1
		case .Head_Output_Hash:
			head.bytes[40] ~= 0x41
		case .Head_Count:
			head.bytes[pr.REALISATION_OBJECT_HEAD_SIZE - 8] ~= 0x01
		}
		state_init(state, pr.memory_private_store_port(store))
		only := build_registered(state, registry, recipe, .Cache_Only)
		testing.expectf(t, only.refusal == .Cache_Miss, "%v: Cache_Only gives %v", damage, only.refusal)
		again := build_registered(state, registry, recipe, .Prefer_Cache)
		testing.expectf(t, again.outcome == .Built_Locally && again.output_hash == first.output_hash, "%v: %v %v", damage, again.outcome, again.refusal)
		testing.expect_value(t, state.counters.local_builds, u64(1))
		state_init(state, pr.memory_private_store_port(store))
		read := build_registered(state, registry, recipe, .Prefer_Cache)
		testing.expectf(t, read.outcome == .From_Cache, "%v: the build wrote the store whole again: %v", damage, read.outcome)
	}
}

@(test)
a_store_that_refuses_the_realisation_records_nothing :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	registry := new(Recipe_Registry)
	defer free(registry)
	store := recipes_test_state_init(state)
	defer free(store)
	spec := new(pr.Recipe_Spec, context.temp_allocator)
	store_test_spec(spec)
	recipe, _ := register_recipe(registry, spec)
	store.writes_allowed = 0
	refused := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, refused.outcome, pr.Recipe_Build_Outcome.Refused)
	testing.expect_value(t, refused.refusal, pr.Recipe_Refusal.Store_Failed)
	_, found := query_provenance(state, recipe)
	testing.expect(t, !found)
	testing.expect_value(t, realisation_rows(state, nil), 0)
	// Cache_Only finds nothing: no realisation was recorded.
	only := build_registered(state, registry, recipe, .Cache_Only)
	testing.expect_value(t, only.refusal, pr.Recipe_Refusal.Cache_Miss)
	// The store takes writes again: the next build records the realisation.
	store.writes_allowed = -1
	built := build_registered(state, registry, recipe, .Prefer_Cache)
	testing.expect_value(t, built.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect_value(t, realisation_rows(state, nil), 1)
}

@(test)
a_corrupt_recipe_is_refused_before_any_build :: proc(t: ^testing.T) {
	head := pr.Recipe_Head{output_kind_word = i64(object_cache.Cache_Object_Kind.Tree)}
	head.builder_hash = value_kinds.Hash_Field(pr.inputs_tree_builder_hash())
	rows := [2]pr.Recipe_Input_Row{{kind_word = i64(object_cache.Cache_Object_Kind.Tree)}, {kind_word = i64(object_cache.Cache_Object_Kind.Tree)}}
	rows[0].hash = value_kinds.Hash_Field(store_test_hash(1))
	rows[1].hash = value_kinds.Hash_Field(store_test_hash(2))
	copy(rows[0].name[:], "src")
	copy(rows[1].name[:], "src")
	spec: pr.Recipe_Spec
	duplicate, _ := pr.recipe_spec_of_parts(&head, rows[:], nil, &spec)
	testing.expect_value(t, duplicate, pr.Recipe_Refusal.Duplicate_Input)
	copy(rows[1].name[:], "lib")
	rows[1].hash = {}
	zero, _ := pr.recipe_spec_of_parts(&head, rows[:], nil, &spec)
	testing.expect_value(t, zero, pr.Recipe_Refusal.Zero_Input_Hash)
	rows[1].hash = value_kinds.Hash_Field(store_test_hash(2))
	rows[1].kind_word = 3
	kind, _ := pr.recipe_spec_of_parts(&head, rows[:], nil, &spec)
	testing.expect_value(t, kind, pr.Recipe_Refusal.Bad_Input_Kind)
	rows[1].kind_word = i64(object_cache.Cache_Object_Kind.Tree)
	no_builder := head
	no_builder.builder_hash = {}
	builder, _ := pr.recipe_spec_of_parts(&no_builder, rows[:], nil, &spec)
	testing.expect_value(t, builder, pr.Recipe_Refusal.Zero_Builder_Hash)
	whole, _ := pr.recipe_spec_of_parts(&head, rows[:], nil, &spec)
	testing.expect_value(t, whole, pr.Recipe_Refusal.None)
}