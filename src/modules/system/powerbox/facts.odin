package powerbox_service

// Log facts emitted by the delegated powerbox service. Field names avoid the
// reserved log table header names (number, time, process, level).

FAILURE_FIELD_BYTES :: 96

@(log_fact = "powerbox: ready, trusted display slot {display_slot}, contract version {contract_version}")
Service_Ready :: struct {
	display_slot:     u64,
	contract_version: u64,
}

@(log_fact = "powerbox: {failure}")
Service_Failed :: struct {
	failure: [FAILURE_FIELD_BYTES]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "powerbox: refused request serial {request_serial} with refusal {refusal_code}")
Request_Refused :: struct {
	request_serial: u64,
	refusal_code:   u64,
}

@(log_fact = "powerbox: expired {expired_dialogs} pending dialogs")
Dialogs_Expired :: struct {
	expired_dialogs: u64,
}
