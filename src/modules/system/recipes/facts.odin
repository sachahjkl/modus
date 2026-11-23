package recipes_service

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// Log facts emitted by the delegated recipes service.

FAILURE_FIELD_BYTES :: 96

// store is 1 when the root service gave the private store, else 0: with no
// store the service records no realisation.
@(log_fact = "recipes: ready, store {store}")
Service_Ready :: struct {
	store: u64,
}

@(log_fact = "recipes: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "recipes: build completed with outcome {outcome} and refusal {refusal_code}")
Recipe_Build_Completed :: struct {
	outcome:      u64,
	refusal_code: u64,
}

// The call host of a builder did not start: the status word of the start,
// and the stage of its load (module.Load_Stage), 0 when the load did not run.
@(log_fact = "recipes: the call host of a builder did not start: the status {status}, the load stage {stage}")
Builder_Not_Started :: struct {
	status: u64,
	stage:  u64,
}

// The call of build did not give 1: the call outcome, the result, and the
// kind of the error record.
@(log_fact = "recipes: the call of build gave the call outcome {outcome}, the result {result}, the error kind {kind}")
Builder_Call_Ended :: struct {
	outcome:     call_outcome.Call_Outcome_Word,
	result:      i64,
	kind:        i64,
}

// After a build, an open of the place of the build gave this kind of error
// record: Absent (17) when the build left nothing, 0 when the place stayed.
@(log_fact = "recipes: after a build, an open of the place build gives the error kind {kind}")
Build_Place_Ended :: struct {
	kind: i64,
}

@(log_fact = "recipes: realisation disagreement detected for recipe ({disagreements} total)")
Realisation_Disagreement :: struct {
	disagreements: u64,
}

// A C source built into a module by the native C builder: the compiler
// and the assembler ran. The name of the source is a text view, the last
// field.
@(log_fact = "recipes: built {source_name} into a module of {size}, recipe {recipe_hash}, module {output_hash}")
C_Built :: struct {
	size:        value_kinds.Size_In_Bytes,
	recipe_hash: value_kinds.Hash_Field,
	output_hash: value_kinds.Hash_Field,
	source_name: value_kinds.Text_View,
}

// A C source whose recipe the local store realised already: no compile
// ran, and the module is the one of the realisation.
@(log_fact = "recipes: substituted {source_name}: the recipe {recipe_hash} is realised, module {output_hash} of {size}, with no compile")
C_Substituted :: struct {
	size:        value_kinds.Size_In_Bytes,
	recipe_hash: value_kinds.Hash_Field,
	output_hash: value_kinds.Hash_Field,
	source_name: value_kinds.Text_View,
}

// A step of a C build failed: nothing is kept. step_code is the
// C_Build_Step; for the step Compile, the value is the byte of the source
// that the diagnostic names.
@(log_fact = "recipes: the C build failed at the step {step_code}: error kind {error_kind}, value {error_value}; nothing is kept")
C_Build_Failed :: struct {
	step_code:   u64,
	error_kind:  u64,
	error_value: i64,
}
