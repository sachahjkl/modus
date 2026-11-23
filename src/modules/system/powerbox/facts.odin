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
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "powerbox: refused request serial {request_serial} with refusal {refusal_code}")
Request_Refused :: struct {
	request_serial: u64,
	refusal_code:   u64,
}

// The bytes of the text of the cause of a store that the picker leaves out:
// the longest text of powerbox.picker_store_refusal_texts, 65 bytes, and a
// zero byte, on 8 bytes.
STORE_CAUSE_FIELD_BYTES :: 72

// A store of the list that no row of the picker can show: the other stores
// show, and this line names the one left out and its cause.
@(log_fact = "powerbox: the store picker leaves out store {store} of principal {principal}: {cause}")
Picker_Store_Left_Out :: struct {
	principal: u64,
	store:     u64,
	cause:     [72]u8,
}
#assert(size_of(Picker_Store_Left_Out{}.cause) == STORE_CAUSE_FIELD_BYTES)

@(log_fact = "powerbox: expired {expired_dialogs} pending dialogs")
Dialogs_Expired :: struct {
	expired_dialogs: u64,
}
