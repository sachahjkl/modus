package collector_service

// Log facts emitted by the freestanding collector service. Field names avoid
// the reserved log table header names (number, time, process, level).

FAILURE_FIELD_BYTES :: 96

@(log_fact = "collector: ready for principal {principal_id}, act capacity {act_capacity}")
Service_Ready :: struct {
	principal_id: u64,
	act_capacity: u64,
}

@(log_fact = "collector: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "collector: refused wide grant action with refusal {refusal_code} on grant {grant_serial}")
Wide_Grant_Action_Refused :: struct {
	refusal_code: u64,
	grant_serial: u64,
}

@(log_fact = "collector: expired {expired_grants} wide grants")
Grants_Expired :: struct {
	expired_grants: u64,
}

@(log_fact = "collector: act chain verification failed at index {failing_index} with refusal {refusal_code}")
Chain_Verification_Failed :: struct {
	failing_index: u64,
	refusal_code:  u64,
}
