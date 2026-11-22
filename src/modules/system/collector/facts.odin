package collector_service

// Log facts emitted by the freestanding collector service. Field names avoid
// the reserved log table header names (number, time, process, level).

FAILURE_FIELD_BYTES :: 96

@(log_fact = "collector: ready for principal {principal_id}, act capacity {act_capacity}, store {store}")
Service_Ready :: struct {
	principal_id: u64,
	act_capacity: u64,
	store:        u64,
}

// The audit spaces that a start read back from the private store, each
// segment checked.
@(log_fact = "collector: read {spaces} audit spaces with {records} records from its store")
Spaces_Loaded :: struct {
	spaces:  u64,
	records: u64,
}

// A start found a damaged object of its audit spaces: each step of a space
// is refused until the store is repaired, so no part of an audit is served
// as the whole. Space 0 is the index of the spaces.
@(log_fact = "collector: the audit spaces in its store are damaged at space {space}")
Spaces_Store_Damaged :: struct {
	space: u64,
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

// The first refusal of a full space or of a full forward queue: the writer
// of the space waits from now on, and the counts of the space show each
// later refusal.
@(log_fact = "collector: space {space} is full and holds its writer, refusal {refusal_code}")
Space_Refused_Record :: struct {
	space:        u64,
	refusal_code: u64,
}

@(log_fact = "collector: act chain verification failed at index {failing_index} with refusal {refusal_code}")
Chain_Verification_Failed :: struct {
	failing_index: u64,
	refusal_code:  u64,
}
