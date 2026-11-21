package devices_service

// Log facts emitted by the delegated devices service.

FAILURE_FIELD_BYTES :: 96

@(log_fact = "devices: ready, known identities {identities}")
Service_Ready :: struct {
	identities: u64,
}

@(log_fact = "devices: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "devices: bound role {role} at bus {bus} device {device} function {function} to service {service_slot}")
Device_Bound :: struct {
	role:         u64,
	bus:          u64,
	device:       u64,
	function:     u64,
	service_slot: u64,
}

@(log_fact = "devices: command {command_kind} refused with code {refusal_code}")
Command_Refused :: struct {
	command_kind: u64,
	refusal_code: u64,
}
