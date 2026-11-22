package disk_processes_service

// Log facts emitted by the delegated disk_processes service. The core
// writes the lines of each load: this service writes its start, its fault,
// and a command of the core that it refuses.

FAILURE_FIELD_BYTES :: 96

@(log_fact = "disk_processes: ready")
Service_Ready :: struct {}

@(log_fact = "disk_processes: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "disk_processes: refused the command {command_kind} of the core: its word, its tag or its order is wrong")
Command_Refused :: struct {
	command_kind: u64,
}
