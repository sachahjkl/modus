package disk_processes_service

// Log facts emitted by the delegated disk_processes service.

FAILURE_FIELD_BYTES :: 96

@(log_fact = "disk_processes: ready")
Service_Ready :: struct {}

@(log_fact = "disk_processes: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "disk_processes: catalog entry registered, total {catalog_entries}")
Catalog_Entry_Registered :: struct {
	catalog_entries: u64,
}

@(log_fact = "disk_processes: prepared start request for principal {principal}, imports {import_count}")
Start_Prepared :: struct {
	principal:    u64,
	import_count: u64,
}

@(log_fact = "disk_processes: command {command_kind} refused with code {refusal_code}")
Command_Refused :: struct {
	command_kind: u64,
	refusal_code: u64,
}
