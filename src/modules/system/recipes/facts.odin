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

// The budget of the service did not pay the disks of a guest build: the
// build is refused.
@(log_fact = "recipes: the disks of a guest build were not made: a buffer of {pages} pages was refused with {status_word}")
Guest_Buffers_Refused :: struct {
	status_word: call_outcome.Call_Outcome_Word,
	pages:       u64,
}

// An object that a guest build needs is not in the private store.
@(log_fact = "recipes: the private store holds no object {hash} for a guest build: status {status}")
Guest_Object_Missing :: struct {
	hash:   value_kinds.Hash_Field,
	status: u64,
}

// A guest build asks for more memory than the budget of the service has
// left: its guest and its nested page table.
@(log_fact = "recipes: the guest build was not started: it needs {pages} pages of memory, and the budget of the service has {left} left")
Guest_Memory_Past_Bound :: struct {
	pages: u64,
	left:  u64,
}

// The guest of a build ran to its end.
@(log_fact = "recipes: the guest build ended after {exits} exits of the guest ({runs} runs), with the exit status {exit_code} and the state {state}")
Guest_Build_Ended :: struct {
	exits:     u64,
	runs:      u64,
	exit_code: u64,
	state:     u64,
}

// A guest build joined the queue of the guest builds.
@(log_fact = "recipes: the guest build of the recipe {recipe} is in the queue")
Guest_Build_Queued :: struct {
	recipe: value_kinds.Hash_Field,
}

// A guest build started on the build thread.
@(log_fact = "recipes: the guest build of the recipe {recipe} started")
Guest_Build_Started :: struct {
	recipe: value_kinds.Hash_Field,
}

// A guest build gave the realisation of its recipe.
@(log_fact = "recipes: the recipe {recipe} is realised with the output {output}")
Guest_Recipe_Realised :: struct {
	recipe: value_kinds.Hash_Field,
	output: value_kinds.Hash_Field,
}

// The kernel did not start the build thread: the build is refused.
@(log_fact = "recipes: the build thread did not start: Thread_Create gave {status_word}")
Guest_Thread_Refused :: struct {
	status_word: call_outcome.Call_Outcome_Word,
}

// One pass of the retention of the store.
@(log_fact = "recipes: the retention pass kept {kept} objects of {marked} named, and removed {removed} (refusal {refusal})")
Retention_Passed :: struct {
	marked:  u64,
	kept:    u64,
	removed: u64,
	refusal: u64,
}

// A check before the run of the guest refused the build.
@(log_fact = "recipes: the guest build was refused before its run: refusal {refusal}, boot refusal {boot_refusal}")
Guest_Build_Refused_Before_Run :: struct {
	refusal:      u64,
	boot_refusal: u64,
}

// The processors of the machine run no guest.
@(log_fact = "recipes: Guest_Run gave Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest build runs")
Guests_Unsupported :: struct {}

// A kernel operation of a guest build failed.
@(log_fact = "recipes: the guest build stopped: {step} gave {status_word}")
Guest_Step_Failed :: struct {
	status_word: call_outcome.Call_Outcome_Word,
	step:        [40]u8,
}

// A recipe object of the private store does not decode to its hash.
@(log_fact = "recipes: the stored recipe {recipe} does not decode to its hash: it is not registered")
Stored_Recipe_Damaged :: struct {
	recipe: value_kinds.Hash_Field,
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

// The QUIC remote object cache was configured with a pinned server public key.
@(log_fact = "recipes: remote QUIC object cache configured on UDP port {port}, server key {server_key}")
Remote_Cache_Configured :: struct {
	port:       u64,
	server_key: value_kinds.Hash_Field,
}
