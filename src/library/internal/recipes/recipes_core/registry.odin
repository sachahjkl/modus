// The recipes that a caller registered, and the history of the builds of
// the recipes service (src/md/features/recipes.md, "The realisation").
//
// A recipe is registered once by its hash and built by that hash: the call
// of a build carries 32 bytes, not the 8 KiB of a recipe, and two callers
// that register one recipe share its realisation.
package recipes_core

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

// The recipes that the service holds at once.
MAX_REGISTERED_RECIPES :: 16

// The builds that the history keeps: the newest ones.
MAX_BUILD_HISTORY :: 32

// One registered recipe.
Registered_Recipe :: struct {
	active:      bool,
	recipe_hash: blake3.Hash,
	spec:        pr.Recipe_Spec,
}

// The registered recipes and the history of the builds.
Recipe_Registry :: struct {
	recipes:      [MAX_REGISTERED_RECIPES]Registered_Recipe,
	history:      [MAX_BUILD_HISTORY]pr.Recipe_Build_Row,
	builds_total: u64,
}

// The state of one build of the inputs tree builder: build_recipe gives a
// failed builder as Builder_Failed, and the registry gives back the cause.
@(private = "file")
Inputs_Tree_Call :: struct {
	refusal: pr.Recipe_Refusal,
}

// register_recipe validates spec, hashes it and keeps it. A recipe that is
// already registered gives its hash again and keeps nothing twice. A full
// registry refuses with Recipe_Limit_Reached and changes nothing.
register_recipe :: proc "contextless" (registry: ^Recipe_Registry, spec: ^pr.Recipe_Spec) -> (recipe_hash: blake3.Hash, refusal: pr.Recipe_Refusal) {
	if registry == nil || spec == nil {
		return {}, .Buffer_Too_Small
	}
	recipe_hash, refusal = pr.recipe_hash(spec)
	if refusal != .None {
		return {}, refusal
	}
	free := -1
	for &slot, index in registry.recipes {
		if slot.active && slot.recipe_hash == recipe_hash {
			return recipe_hash, .None
		}
		if !slot.active && free < 0 {
			free = index
		}
	}
	if free < 0 {
		return {}, .Recipe_Limit_Reached
	}
	// Field by field: a literal of the slot would be a value of about
	// 90 KiB on the stack.
	slot := &registry.recipes[free]
	slot.active = true
	slot.recipe_hash = recipe_hash
	slot.spec = spec^
	return recipe_hash, .None
}

// registered_recipe gives the registered recipe of recipe_hash, or nil.
registered_recipe :: proc "contextless" (registry: ^Recipe_Registry, recipe_hash: blake3.Hash) -> ^pr.Recipe_Spec {
	for &slot in registry.recipes {
		if slot.active && slot.recipe_hash == recipe_hash {
			return &slot.spec
		}
	}
	return nil
}

// The start of a builder that is not the inputs tree builder: the service
// gives it (src/modules/system/recipes, builder_start.odin), and a host
// test gives one in memory. invoke writes the cause of a refusal in
// refusal: the result gives it in place of Builder_Failed.
Builder_Start :: struct {
	invoke:  Builder_Invoke_Proc,
	data:    rawptr,
	refusal: pr.Recipe_Refusal,
}

// build_registered builds the registered recipe of recipe_hash in mode, and
// keeps the result in the history. A realisation in the local store answers
// a mode that takes the cache with no build. On a miss, the service builds a
// recipe of the inputs tree builder itself, and each other builder with
// start, in its own process (src/md/features/recipes.md, "The builder").
// With no start, another builder is refused with Builder_Needs_Sandbox.
build_registered :: proc "contextless" (state: ^Recipes_State, registry: ^Recipe_Registry, recipe_hash: blake3.Hash, mode: pr.Build_Mode, start: ^Builder_Start = nil) -> (result: pr.Recipe_Build_Result) {
	spec := registered_recipe(registry, recipe_hash)
	if spec == nil {
		state.counters.total_refusals += 1
		result = {outcome = .Refused, refusal = .Unknown_Recipe, recipe_hash = recipe_hash}
		history_add(registry, &result, mode)
		return result
	}
	if start != nil && start.invoke != nil && spec.builder_hash != pr.inputs_tree_builder_hash() {
		start.refusal = .None
		result = build_recipe(state, spec, mode, {}, nil, start.invoke, nil, nil, start)
		if result.refusal == .Builder_Failed && start.refusal != .None {
			result.refusal = start.refusal
		}
	} else {
		result = build_with_inputs_tree(state, spec, mode)
	}
	history_add(registry, &result, mode)
	return result
}

// build_with_inputs_tree builds spec in mode with the inputs tree builder as
// the one builder that the service runs itself, and gives the cause of a
// refusal of that builder in place of Builder_Failed.
build_with_inputs_tree :: proc "contextless" (state: ^Recipes_State, spec: ^pr.Recipe_Spec, mode: pr.Build_Mode) -> (result: pr.Recipe_Build_Result) {
	call := Inputs_Tree_Call{}
	result = build_recipe(state, spec, mode, {}, nil, inputs_tree_invoke, nil, nil, &call)
	if result.refusal == .Builder_Failed && call.refusal != .None {
		result.refusal = call.refusal
	}
	return result
}

@(private = "file")
inputs_tree_invoke :: proc "contextless" (sandbox: ^pr.Builder_Sandbox_Spec, out_payload: []u8, user_data: rawptr) -> (payload_length: int, ok: bool) {
	call := (^Inputs_Tree_Call)(user_data)
	written, refusal := pr.inputs_tree_build(sandbox, out_payload)
	if refusal != .None {
		if call != nil {
			call.refusal = refusal
		}
		return 0, false
	}
	return written, true
}

@(private = "file")
history_add :: proc "contextless" (registry: ^Recipe_Registry, result: ^pr.Recipe_Build_Result, mode: pr.Build_Mode) {
	registry.history[registry.builds_total % MAX_BUILD_HISTORY] = pr.recipe_build_row_of(result, mode)
	registry.builds_total += 1
}

// history_rows writes the builds that the history keeps into out, oldest
// first, and gives the count of builds that it keeps, which can pass the
// length of out.
history_rows :: proc "contextless" (registry: ^Recipe_Registry, out: []pr.Recipe_Build_Row) -> int {
	kept := int(min(registry.builds_total, MAX_BUILD_HISTORY))
	first := registry.builds_total - u64(kept)
	for index in 0 ..< kept {
		if index < len(out) {
			out[index] = registry.history[(first + u64(index)) % MAX_BUILD_HISTORY]
		}
	}
	return kept
}

// realisation_rows writes each realisation of the local store into out and
// gives their count, which can pass the length of out.
realisation_rows :: proc "contextless" (state: ^Recipes_State, out: []pr.Realisation_Row) -> int {
	count := 0
	for &slot in state.realisations {
		if !slot.active {
			continue
		}
		if count < len(out) {
			out[count] = pr.realisation_row_of(&slot.record, u64(slot.origin))
		}
		count += 1
	}
	return count
}
