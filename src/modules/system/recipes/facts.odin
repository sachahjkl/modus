package recipes_service

import op "modus:contract/operation"
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
	status_word: op.Status_Word,
	pages:       u64,
}

// An object that a guest build needs is not in the private store.
@(log_fact = "recipes: the private store holds no object {hash} for a guest build: status {status}")
Guest_Object_Missing :: struct {
	hash:   value_kinds.Hash_Field,
	status: u64,
}

// A guest build asks for more memory than the service gives a guest.
@(log_fact = "recipes: the guest build asks for {pages} pages of memory; the service gives a guest at most {most}")
Guest_Memory_Past_Bound :: struct {
	pages: u64,
	most:  u64,
}

// The guest of a build ran to its end.
@(log_fact = "recipes: the guest build ended after {exits} exits of the guest, with the exit status {exit_code} and the state {state}")
Guest_Build_Ended :: struct {
	exits:     u64,
	exit_code: u64,
	state:     u64,
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
	status_word: op.Status_Word,
	step:        [40]u8,
}

// A recipe object of the private store does not decode to its hash.
@(log_fact = "recipes: the stored recipe {recipe} does not decode to its hash: it is not registered")
Stored_Recipe_Damaged :: struct {
	recipe: value_kinds.Hash_Field,
}

@(log_fact = "recipes: realisation disagreement detected for recipe ({disagreements} total)")
Realisation_Disagreement :: struct {
	disagreements: u64,
}
