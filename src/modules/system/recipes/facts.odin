package recipes_service

// Log facts emitted by the delegated recipes service.

FAILURE_FIELD_BYTES :: 96

@(log_fact = "recipes: ready")
Service_Ready :: struct {}

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

@(log_fact = "recipes: realisation disagreement detected for recipe ({disagreements} total)")
Realisation_Disagreement :: struct {
	disagreements: u64,
}
