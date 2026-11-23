package recipes_core

import "modus:contract/blake3"
import "modus:contract/builder"
import "modus:contract/call_outcome"
import "modus:contract/declaration_eval"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"

// The recipe that a declaration names, registered from the output of its
// evaluation (src/md/features/application_projects.md, "The export of the
// service"), and the error record of each refusal of a recipe, one place
// for each export of the service.

// The bytes of the largest output of an evaluation whose value is a recipe
// that converts: the head of the output, the tag, the written hash and the
// builder hash, then the largest argument value.
MAX_RECIPE_OUTPUT_BYTES :: declaration_eval.OUTPUT_HEADER_BYTES + 1 + 2 * blake3.HASH_SIZE + pr.MAX_RECIPE_ARGUMENT_VALUE_BYTES

// register_evaluation converts the output of an evaluation whose value is a
// recipe, and registers the record under the hash that the evaluator wrote.
// output is a private copy of the caller: it does not change during the
// call. On a refusal nothing is registered, and spec is zero.
register_evaluation :: proc "contextless" (registry: ^Recipe_Registry, output: []u8, spec: ^pr.Recipe_Spec) -> (recipe_hash: blake3.Hash, refusal: pr.Recipe_Refusal) {
	if registry == nil || spec == nil {
		return {}, .Buffer_Too_Small
	}
	if len(output) > MAX_RECIPE_OUTPUT_BYTES {
		spec^ = {}
		return {}, .Arguments_Too_Large
	}
	// recipe_spec_of_output already refuses a record whose hash is not the
	// hash that the evaluator wrote, so register_recipe stores only a record
	// that matches it.
	_, refusal = pr.recipe_spec_of_output(output, spec)
	if refusal != .None {
		return {}, refusal
	}
	recipe_hash, refusal = register_recipe(registry, spec)
	if refusal != .None {
		spec^ = {}
		return {}, refusal
	}
	return recipe_hash, .None
}

// recipe_refusal_record gives the error record of a refusal of a recipe,
// with the refusal as the value found: the one mapping of the exports of the
// service. argument is the argument of the call that the refusal names, and
// bad_index the index of the input or of the row when one is named.
recipe_refusal_record :: proc "contextless" (refusal: pr.Recipe_Refusal, argument: i64 = 0, bad_index: u32 = 0) -> errors.Error_Record {
	found := i64(refusal)
	switch refusal {
	case .None:
		return errors.error_make(.Refused, .None, argument, 0, 0, found)
	case .Zero_Builder_Hash, .Bad_Output_Kind, .Bad_Build_Mode, .Invalid_Input_Name, .Zero_Input_Hash, .Duplicate_Input, .Bad_Input_Kind, .Nonzero_Padding, .Bad_Head_Value:
		return errors.error_make(.Bad_Value, .None, argument, i64(bad_index), 0, found)
	case .Untyped_Hash, .Nested_Input, .Not_A_Recipe, .Unsupported_Argument:
		return errors.error_make(.Bad_Value, .None, argument, 0, 0, found)
	case .Too_Many_Inputs:
		return errors.error_make(.Over_Limit, .Records, argument, 0, pr.MAX_RECIPE_INPUTS, found)
	case .Arguments_Too_Large:
		return errors.error_make(.Too_Long, .Bytes, argument, 0, pr.MAX_RECIPE_ARG_BYTES, found)
	case .Cache_Miss, .Unknown_Recipe, .Builder_Absent, .Input_Absent:
		return errors.error_make(.Absent, .Objects, argument, 0, 0, found)
	case .Builder_Timed_Out:
		// Not No_Answer: its value found names what did not answer, and the
		// value found of each record of this mapping is the refusal.
		return errors.error_make(.Refused, .None, argument, 0, builder.BUILD_TIME_BOUND_MILLISECONDS, found)
	case .Input_Too_Large:
		return errors.error_make(.Over_Limit, .Objects, argument, 0, builder.MAX_INPUT_OBJECTS, found)
	case .Store_Full, .Recipe_Limit_Reached, .Buffer_Too_Small:
		return errors.error_make(.Full, .Objects, argument, 0, 0, found)
	case .Untrusted_Realisation, .Hash_Mismatch, .Bad_Signature, .Malformed_Output, .Verify_Disagreement:
		return errors.error_make(.Not_Authentic, .Objects, argument, 0, 0, found)
	case .Builder_Failed, .Sandbox_Violation:
		return errors.error_make(.Refused, .None, argument, 0, 0, found)
	case .Builder_Needs_Sandbox:
		return errors.error_make(.Unsupported, .None, argument, 0, 0, found)
	case .Store_Failed:
		return errors.error_make(.Device, .Store, argument, 0, 0, found)
	case .Store_Damaged:
		return errors.error_make(.Damaged, .Store, argument, 0, 0, found)
	case .Damaged_Recipe:
		return errors.error_make(.Damaged, .None, argument, 0, 0, found)
	}
	return errors.error_make(.Refused, .None, argument, 0, 0, found)
}

// recipe_refusal_outcome gives the call outcome of a refusal of a recipe:
// the one mapping of the exports of the service, beside its record.
recipe_refusal_outcome :: proc "contextless" (refusal: pr.Recipe_Refusal) -> call_outcome.Call_Outcome {
	switch refusal {
	case .None, .Zero_Builder_Hash, .Bad_Output_Kind, .Bad_Build_Mode, .Invalid_Input_Name, .Zero_Input_Hash, .Duplicate_Input, .Bad_Input_Kind, .Nonzero_Padding, .Bad_Head_Value, .Untyped_Hash, .Nested_Input, .Not_A_Recipe, .Unsupported_Argument, .Too_Many_Inputs, .Arguments_Too_Large, .Buffer_Too_Small, .Damaged_Recipe:
		return .Argument_Refused
	case .Cache_Miss, .Unknown_Recipe:
		return .Nothing_Has_That_Name
	case .Store_Full, .Recipe_Limit_Reached:
		return .Budget_Or_Capacity_Exhausted
	case .Untrusted_Realisation, .Hash_Mismatch, .Bad_Signature, .Malformed_Output, .Verify_Disagreement, .Store_Damaged:
		return .Data_Damaged
	case .Builder_Failed, .Sandbox_Violation, .Store_Failed:
		return .Callee_Unavailable
	case .Builder_Needs_Sandbox:
		return .Operation_Unsupported
	}
	return .Argument_Refused
}
