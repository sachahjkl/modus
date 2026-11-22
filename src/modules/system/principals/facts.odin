package principals_service

// Log facts emitted by the delegated principals service.

FAILURE_FIELD_BYTES :: 96

@(log_fact = "principals: ready with {principals} principals")
Service_Ready :: struct {
	principals: u64,
}

@(log_fact = "principals: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "principals: registered principal {principal}, total {principals}")
Principal_Registered :: struct {
	principal:  u64,
	principals: u64,
}

@(log_fact = "principals: session action {action} on principal {principal}, active sessions {active_sessions}")
Session_Changed :: struct {
	principal:       u64,
	action:          u64,
	active_sessions: u64,
}

@(log_fact = "principals: applied {rows} disk grant rows for principal {principal} at generation {generation}")
Disk_Rows_Applied :: struct {
	principal:  u64,
	generation: u64,
	rows:       u64,
}

@(log_fact = "principals: client key action {action} for principal {principal}, active keys {active_keys}")
Client_Key_Updated :: struct {
	principal:   u64,
	action:      u64,
	active_keys: u64,
}

@(log_fact = "principals: start policy action {action} for principal {principal}, updates {updates}")
Start_Policy_Updated :: struct {
	principal: u64,
	action:    u64,
	updates:   u64,
}

@(log_fact = "principals: command {command_kind} refused with code {refusal_code}")
Command_Refused :: struct {
	command_kind: u64,
	refusal_code: u64,
}
