package projects_service

import "modus:contract/value_kinds"

// Log facts emitted by the delegated projects service.

FAILURE_FIELD_BYTES :: 96

// store is 1 when the root service gave the private store, else 0: with no
// store the service records no project.
@(log_fact = "projects: ready, store {store}")
Service_Ready :: struct {
	store: u64,
}

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

// projects.new made a project of a principal, with the store of its name.
@(log_fact = "projects: made the project {project} of principal {principal}, with the store of its name for its source")
Project_Made :: struct {
	principal: u64,
	project:   value_kinds.Module_Name_Field,
}
