package plans_service

// Log facts emitted by the delegated plans service.

FAILURE_FIELD_BYTES :: 96

@(log_fact = "plans: ready, trusted display slot {display_slot}")
Service_Ready :: struct {
	display_slot: u64,
}

@(log_fact = "plans: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "plans: applied generation {generation} for principal {principal}")
Plan_Applied :: struct {
	generation: u64,
	principal:  u64,
}

@(log_fact = "plans: rolled back to generation {generation} for principal {principal}")
Plan_Rolled_Back :: struct {
	generation: u64,
	principal:  u64,
}

@(log_fact = "plans: refused command for principal {principal} with refusal {refusal_code}")
Plan_Command_Refused :: struct {
	principal:    u64,
	refusal_code: u64,
}
