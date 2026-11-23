// The exports of the recipes service (src/md/features/recipes.md, "The
// builder"; src/md/features/declarations.md, "The services of the
// declarations").
package recipes_service

import "base:intrinsics"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"
import "modus:system"

// The failures of the exports of this file, each with its error record.
ERROR_NO_CALLER :: i64(-1) // No_Grant, Connection: the call came through no connection.
ERROR_ACTS_FOR_PRINCIPAL :: i64(-2) // No_Grant, Acts_For_Principal: the caller does not act for its principal.
ERROR_NOT_READY :: i64(-3) // State, Requests: the service has not started its tables.
ERROR_RECIPE :: i64(-4) // The recipe is refused: the value found is the Recipe_Refusal.
ERROR_BUILD :: i64(-5) // The build is refused: the value found is the Recipe_Refusal.

// The registered recipes and the history of the builds.
service_registry: recipes_core.Recipe_Registry

// The parts of a recipe of the call, copied once out of the call region.
copied_head: pr.Recipe_Head
copied_inputs: [pr.MAX_RECIPE_INPUTS]pr.Recipe_Input_Row
copied_arguments: [pr.MAX_RECIPE_ARG_BYTES]u8
copied_output: [recipes_core.MAX_RECIPE_OUTPUT_BYTES]u8 // The output of an evaluation of the call, copied once out of the call region.
copied_reference: pr.Recipe_Reference
export_spec: pr.Recipe_Spec
export_result: pr.Recipe_Build_Result

// caller_check refuses a call with no connection and, when acts is true, a
// caller that does not act for its principal: a build spends the store of
// the service for the principal that asks.
@(private = "file")
caller_check :: proc "contextless" (acts: bool, error: ^errors.Error_Record) -> (failure: i64, ok: bool) {
	connection := system.service_caller()
	if connection == nil {
		return errors.fail(error, ERROR_NO_CALLER, .No_Grant, .Connection), false
	}
	if acts && connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal), false
	}
	if !service_state.initialized {
		return errors.fail(error, ERROR_NOT_READY, .State, .Requests), false
	}
	return 0, true
}

// recipe_refusal_fail writes the error record of a refusal of the recipes
// contract, with the refusal as the value found.
@(private = "file")
recipe_refusal_fail :: proc "contextless" (error: ^errors.Error_Record, result: i64, refusal: pr.Recipe_Refusal, argument: i64 = 0, bad_index: u32 = 0) -> i64 {
	if error != nil {
		error^ = recipes_core.recipe_refusal_record(refusal, argument, bad_index)
	}
	return result
}

// register keeps a recipe by its hash, so build and cache_lookup name it
// with 32 bytes.
//
// - **head**: the builder hash, the output kind, the date of the recipe and
//   the bound of its output in blocks.
// - **inputs**: one row for each input, a name and a hash, at most 32.
// - **arguments**: the bytes of the argument record, at most 4096.
// - **result**: one row: the recipe hash.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_RECIPE with the refusal as the value found.
@(export, link_name = "register")
register :: proc "c" (head: ^pr.Recipe_Head, inputs: ^system.Table_To_Read(pr.Recipe_Input_Row), arguments: ^system.Bytes_To_Read, result: ^[]pr.Recipe_Reference, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if head == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 1)
	}
	copied_head = intrinsics.volatile_load(head)
	input_count: u64 = 0
	if inputs != nil {
		input_count = intrinsics.volatile_load(&inputs.count)
	}
	if input_count > pr.MAX_RECIPE_INPUTS {
		return recipe_refusal_fail(error, ERROR_RECIPE, .Too_Many_Inputs, 2)
	}
	for index in 0 ..< input_count {
		copied_inputs[index] = intrinsics.volatile_load(&inputs.records[index])
	}
	argument_count: u64 = 0
	if arguments != nil {
		argument_count = intrinsics.volatile_load(&arguments.count)
	}
	if argument_count > pr.MAX_RECIPE_ARG_BYTES {
		return recipe_refusal_fail(error, ERROR_RECIPE, .Arguments_Too_Large, 3)
	}
	if argument_count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied_arguments[0], arguments.bytes, int(argument_count))
	}
	refusal, bad_index := pr.recipe_spec_of_parts(&copied_head, copied_inputs[:input_count], copied_arguments[:argument_count], &export_spec)
	if refusal != .None {
		argument := i64(1)
		if refusal == .Invalid_Input_Name || refusal == .Bad_Input_Kind || refusal == .Zero_Input_Hash || refusal == .Duplicate_Input {
			argument = 2
		}
		return recipe_refusal_fail(error, ERROR_RECIPE, refusal, argument, bad_index)
	}
	recipe_hash, register_refusal := recipes_core.register_recipe(&service_registry, &export_spec)
	if register_refusal != .None {
		return recipe_refusal_fail(error, ERROR_RECIPE, register_refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = {recipe_hash = value_kinds.Hash_Field(recipe_hash)}
	}
	return 1
}

// register_evaluation keeps the recipe that a declaration names, from the
// output of its evaluation: outputs.default of a project, as the evaluator
// wrote it (src/md/features/application_projects.md, "The export of the
// service"). The service copies the bytes into its own memory before it
// reads them, converts them with the one conversion of the contract, and
// registers the record under the hash that the evaluator wrote.
//
// - **output**: the output of the evaluation, whose value is a recipe.
// - **result**: one row: the recipe hash.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_RECIPE with the refusal as the value found: a bare hash, an input
// below the first level, a value that is no recipe, a damaged output, too
// many inputs, arguments too large.
@(export, link_name = "register_evaluation")
register_evaluation :: proc "c" (output: ^system.Bytes_To_Read, result: ^[]pr.Recipe_Reference, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if output == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 1)
	}
	count := intrinsics.volatile_load(&output.count)
	if count > recipes_core.MAX_RECIPE_OUTPUT_BYTES {
		return errors.fail(error, ERROR_RECIPE, .Too_Long, .Bytes, 1, 0, recipes_core.MAX_RECIPE_OUTPUT_BYTES, i64(count))
	}
	// A private copy: the caller can change its memory during the call, and
	// the conversion reads the bytes more than once.
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied_output[0], output.bytes, int(count))
	}
	recipe_hash, refusal := recipes_core.register_evaluation(&service_registry, copied_output[:count], &export_spec)
	if refusal != .None {
		return recipe_refusal_fail(error, ERROR_RECIPE, refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = {recipe_hash = value_kinds.Hash_Field(recipe_hash)}
	}
	return 1
}

// build realises a registered recipe, or a recipe that the private store
// keeps by its hash. A mode that takes the cache gives a realisation of the
// local store at once, with no build; on a miss the service builds the
// recipe (the inputs tree builder in the service, the guest builder in a
// guest of this process), keeps its output and its realisation, and the
// next build of the recipe is a hit.
//
// - **recipe**: the recipe hash that register gave.
// - **mode**: the Build_Mode word: 1 Cache_First, 2 Build_Only,
//   3 Cache_Only, 4 Verify.
// - **result**: one row: the outcome, the recipe hash and the output hash.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or ERROR_BUILD
// with the refusal as the value found.
@(export, link_name = "build")
build :: proc "c" (recipe: ^pr.Recipe_Reference, mode: i64, result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if recipe == nil {
		return errors.fail(error, ERROR_BUILD, .Bad_Address, .None, 1)
	}
	if mode < 0 {
		return recipe_refusal_fail(error, ERROR_BUILD, .Bad_Build_Mode, 2)
	}
	checked_mode, mode_ok := pr.build_mode_of_word(u64(mode))
	if !mode_ok {
		return recipe_refusal_fail(error, ERROR_BUILD, .Bad_Build_Mode, 2)
	}
	copied_reference = intrinsics.volatile_load(recipe)
	recipe_hash := blake3.Hash(copied_reference.recipe_hash)
	// A recipe that a writer of the store kept there registers at its first
	// build (guest_build.odin).
	stored_recipe_register(recipe_hash)
	guest: ^recipes_core.Guest_Builder_Workspace
	if spec := recipes_core.registered_recipe(&service_registry, recipe_hash); spec != nil {
		guest = guest_workspace_for(spec.builder_hash)
	}
	export_result = recipes_core.build_registered_with_guest(&service_state, &service_registry, recipe_hash, checked_mode, guest)
	system.log_fact(.Info, Recipe_Build_Completed{outcome = u64(export_result.outcome), refusal_code = u64(export_result.refusal)})
	if export_result.refusal != .None {
		return recipe_refusal_fail(error, ERROR_BUILD, export_result.refusal, 1)
	}
	if len(result^) > 0 {
		result[0] = pr.recipe_build_row_of(&export_result, checked_mode)
	}
	return 1
}

// The bytes of the largest object that put takes in one call.
OBJECT_PUT_BYTES_MOST :: 32 * 1024

// One object of the private store, as put gives it: its hash.
Object_Reference :: struct {
	hash: value_kinds.Hash_Field,
}

copied_object: [OBJECT_PUT_BYTES_MOST]u8

// put keeps an object in the private store by its hash, so a recipe names
// it as an input, or a guest build as its kernel or its initial archive.
//
// - **kind**: the Cache_Object_Kind word: 1 a blob, 2 a tree, whose bytes
//   are a canonical MODTREE1 node.
// - **bytes**: the object, at most OBJECT_PUT_BYTES_MOST bytes.
// - **result**: one row: the hash of the object.
//
// The result is 1, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_RECIPE with the refusal as the value found.
@(export, link_name = "put")
put :: proc "c" (kind: i64, bytes: ^system.Bytes_To_Read, result: ^[]Object_Reference, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(true, error); !ok {
		return failure
	}
	if bytes == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 2)
	}
	object_kind, kind_ok := object_cache.cache_object_kind_of_word(u64(max(kind, 0)))
	if kind < 0 || !kind_ok {
		return recipe_refusal_fail(error, ERROR_RECIPE, .Bad_Input_Kind, 1)
	}
	count := intrinsics.volatile_load(&bytes.count)
	if count == 0 || count > OBJECT_PUT_BYTES_MOST {
		return errors.fail(error, ERROR_RECIPE, .Too_Long, .Bytes, 2, i64(min(count, 1 << 62)), OBJECT_PUT_BYTES_MOST)
	}
	// A private copy: the hash and the write read the same bytes.
	intrinsics.mem_copy_non_overlapping(&copied_object[0], bytes.bytes, int(count))
	hash, refusal := pr.recipe_hash_output(object_kind, copied_object[:count])
	if refusal != .None {
		return recipe_refusal_fail(error, ERROR_RECIPE, refusal, 2)
	}
	name := pr.blob_object_name(hash)
	if pr.private_store_write(&service_state.store, pr.private_object_name_text(&name), copied_object[:count]) != .Ok {
		return recipe_refusal_fail(error, ERROR_RECIPE, .Store_Failed, 2)
	}
	if len(result^) > 0 {
		result[0] = {hash = value_kinds.Hash_Field(hash)}
	}
	return 1
}

// cache_lookup gives the realisation of a recipe in the local store, with
// no build.
//
// - **recipe**: the recipe hash.
// - **result**: one row when the store holds a realisation of the recipe.
//
// The result is 1 when the store holds one, 0 when it holds none, or a
// negative number with an error record: ERROR_NO_CALLER or ERROR_NOT_READY.
@(export, link_name = "cache_lookup")
cache_lookup :: proc "c" (recipe: ^pr.Recipe_Reference, result: ^[]pr.Realisation_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(false, error); !ok {
		return failure
	}
	if recipe == nil {
		return errors.fail(error, ERROR_RECIPE, .Bad_Address, .None, 1)
	}
	copied_reference = intrinsics.volatile_load(recipe)
	slot, found := recipes_core.query_provenance(&service_state, blake3.Hash(copied_reference.recipe_hash))
	if !found {
		return 0
	}
	if len(result^) > 0 {
		result[0] = pr.realisation_row_of(&slot.record, u64(slot.origin))
	}
	return 1
}

// builds gives the newest builds, oldest first, at most 32.
//
// The result is the count of builds, or a negative number with an error
// record: ERROR_NO_CALLER or ERROR_NOT_READY.
@(export, link_name = "builds")
builds :: proc "c" (result: ^[]pr.Recipe_Build_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(false, error); !ok {
		return failure
	}
	return i64(recipes_core.history_rows(&service_registry, result^))
}

// realisations gives each realisation of the local store.
//
// The result is the count of realisations, or a negative number with an
// error record: ERROR_NO_CALLER or ERROR_NOT_READY.
@(export, link_name = "realisations")
realisations :: proc "c" (result: ^[]pr.Realisation_Row, error: ^errors.Error_Record) -> i64 {
	if failure, ok := caller_check(false, error); !ok {
		return failure
	}
	return i64(recipes_core.realisation_rows(&service_state, result^))
}
