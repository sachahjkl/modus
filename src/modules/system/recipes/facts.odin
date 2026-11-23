package recipes_service

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

// The call of build did not give 1: the call status (call_status.Call_Status),
// the result, and the kind of the error record.
@(log_fact = "recipes: the call of build gave the call status {call_status}, the result {result}, the error kind {kind}")
Builder_Call_Ended :: struct {
	call_status: u64,
	result:      i64,
	kind:        i64,
}

@(log_fact = "recipes: realisation disagreement detected for recipe ({disagreements} total)")
Realisation_Disagreement :: struct {
	disagreements: u64,
}
