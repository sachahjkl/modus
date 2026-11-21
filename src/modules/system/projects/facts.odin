package projects_service

// Log facts emitted by the delegated projects service.

FAILURE_FIELD_BYTES :: 96

@(log_fact = "projects: ready")
Service_Ready :: struct {}

@(log_fact = "projects: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "projects: opened child console {console_id} for principal {principal}")
Project_Entered :: struct {
	console_id: u64,
	principal:  u64,
}

@(log_fact = "projects: closed child console {console_id} for principal {principal}")
Project_Exited :: struct {
	console_id: u64,
	principal:  u64,
}

@(log_fact = "projects: refused command with refusal {refusal_code}")
Project_Command_Refused :: struct {
	refusal_code: u64,
}
