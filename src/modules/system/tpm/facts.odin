package tpm_device_service

import "modus:contract/tpm_service"
import "modus:contract/value_kinds"

// The log facts of the TPM service (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the seals, the
// extends of PCR 12 and their refusal, and the steps of the interface that
// fail, as records of fields. Each fact template is the sentence that the
// line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. A line whose sentence differs by its case
// is one fact type for each case: the template has no condition. No field
// has the name of a column of the head of facts(): number, time, process,
// level.
//
// A step of the interface is a Text field: tpm_service.Device_Step is no
// contract enum that a field can name, so the field holds the words of its
// member. A Text field is the last field, and is [N]u8 with N written out,
// as the tool reads it.

// The bytes of the Text field of the words of a step of the interface:
// the longest, "the wait until the TPM is ready", has 31 bytes, and a zero
// byte.
STEP_FIELD_BYTES :: 32
// The bytes of the Text field of the properties that a TPM2_GetCapability
// asks for: the longest, "the state of the hierarchies", has 28 bytes.
PROPERTIES_FIELD_BYTES :: 32

// The interface failed at the TPM2_Shutdown that follows a use of an
// authorization value.
@(log_fact = "tpm: the interface failed at TPM2_Shutdown after a use of an authorization value: {step}; the next start of the TPM can count one failure")
Shutdown_Interface_Failed :: struct {
	step: [32]u8,
}

// A seal of 32 bytes to PCR 7, PCR 11 and an authorization value.
@(log_fact = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of {public_area} and a private area of {private_area}, with its creation data and its ticket")
Sealed_With_Authorization :: struct {
	public_area:  value_kinds.Size_In_Bytes,
	private_area: value_kinds.Size_In_Bytes,
}

// A seal of 32 bytes to PCR 7 and PCR 11.
@(log_fact = "tpm: sealed 32 bytes to PCR 7 and PCR 11: a public area of {public_area} and a private area of {private_area}, with its creation data and its ticket")
Sealed :: struct {
	public_area:  value_kinds.Size_In_Bytes,
	private_area: value_kinds.Size_In_Bytes,
}

// The service refused an extend of PCR 12: the extends of this start
// reached their limit, and no command went to the TPM.
@(log_fact = "tpm: refused an extend of PCR 12: {extends} extends ran in this start, the most that it takes")
Extend_Refused_At_Limit :: struct {
	extends: u64,
}

// The TPM took an extend of PCR 12, and the interface failed at its read
// back.
@(log_fact = "tpm: extended PCR 12, and the interface failed at its read back: {step}")
Extend_Read_Back_Interface_Failed :: struct {
	step: [32]u8,
}

// An extend of PCR 12 with the digest of a start policy, and its place
// among the extends of this start.
@(log_fact = "tpm: extended PCR 12 with the digest of a start policy: extend {extend} of {extend_limit} in this start")
Start_Policy_Measured :: struct {
	extend:       u64,
	extend_limit: u64,
}

// The interface failed at a TPM2_GetCapability.
@(log_fact = "tpm: the interface failed at TPM2_GetCapability of {properties}: {step}")
Capability_Interface_Failed :: struct {
	properties: [32]u8,
	step:       [32]u8,
}

// The answer of the TPM to a TPM2_GetCapability does not hold the
// properties asked.
@(log_fact = "tpm: the answer of the TPM to TPM2_GetCapability of {properties} does not hold the properties asked, each in its place")
Capability_Answer_Malformed :: struct {
	properties: [32]u8,
}

// The interface failed at the TPM2_HierarchyChangeAuth of the lockout
// hierarchy.
@(log_fact = "tpm: the interface failed at TPM2_HierarchyChangeAuth of the lockout hierarchy: {step}; it can keep its empty authorization value until the next start")
Lockout_Change_Interface_Failed :: struct {
	step: [32]u8,
}

// The count limits of the TPM, read at the start. The line writes a count
// of seconds as "N seconds": an Integer, not a Time, which writes " s".
@(log_fact = "tpm: the count limits of the TPM: a lockout after {lockout_failures} wrong authorization values, one forgiven each {forgive_interval_seconds} seconds; {counted_failures} counted now; the lockout hierarchy waits {lockout_recovery_seconds} seconds after a wrong value of its own")
Count_Limits :: struct {
	lockout_failures:         u64,
	forgive_interval_seconds: u64,
	counted_failures:         u64,
	lockout_recovery_seconds: u64,
}

// The bytes of the Text field of the words of a refusal of a pin: the
// longest, "a form with the TPM becomes the passphrase alone", has 48
// bytes, and a zero byte.
PIN_REFUSAL_FIELD_BYTES :: 56

// The payload of the index of a pin, as Pin_Read gave it to unlock. The
// state is the word of tpm_service.Pin_State.
@(log_fact = "tpm: read the pin at the index {index}: state {state}, {payload_bytes} bytes of payload")
Pin_Read :: struct {
	index:         value_kinds.Hexadecimal_Sixteen_Digits,
	state:         u64,
	payload_bytes: u64,
}

// The TPM took a new payload of a pin.
@(log_fact = "tpm: wrote the pin at the index {index}: {payload_bytes} bytes, in a policy session of PCR 7 and PCR 11")
Pin_Written :: struct {
	index:         value_kinds.Hexadecimal_Sixteen_Digits,
	payload_bytes: u64,
}

// An index at the place of a pin that is not a pin of now was removed
// before its definition. The state is the word of tpm_service.Pin_State.
@(log_fact = "tpm: removed the index {index} at the place of a pin, of state {state}, to define it with the policy of PCR 7 and PCR 11 now")
Pin_Index_Removed :: struct {
	index: value_kinds.Hexadecimal_Sixteen_Digits,
	state: u64,
}

// The service removed an index of an older policy, and its definition or
// its write failed after: no pin is in the TPM until the next write, and
// the next start of unlock pins the record that it finds.
@(log_fact = "tpm: removed the index {index} of a pin, and its definition or its write failed: no pin holds until the next write, and the next start pins the record that it finds")
Pin_Lost_After_Removal :: struct {
	index: value_kinds.Hexadecimal_Sixteen_Digits,
}

// A new payload of a pin was refused: nothing is written.
@(log_fact = "tpm: refused the new pin at the index {index}: {pin_refusal}; nothing is written")
Pin_Write_Refused :: struct {
	index:       value_kinds.Hexadecimal_Sixteen_Digits,
	pin_refusal: [56]u8,
}

#assert(size_of(Pin_Write_Refused) == 8 + PIN_REFUSAL_FIELD_BYTES)

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte. One size in each module keeps one
// meaning for the field name.
FAILURE_FIELD_BYTES :: 96

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "tpm: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

// The facts below have the response code of the TPM in the form that the
// line wrote, 16 hexadecimal digits with no "0x", or no field: their
// sentence is their template.

// The TPM refused the TPM2_Shutdown that follows a use of an authorization
// value.
@(log_fact = "tpm: the TPM refused TPM2_Shutdown after a use of an authorization value (response code {response_code}); the next start of the TPM can count one failure")
Shutdown_Refused :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM took the TPM2_Shutdown that follows a use of an authorization
// value.
@(log_fact = "tpm: TPM2_Shutdown after the use of an authorization value: a stop of the machine now makes the TPM count no failure")
Shutdown_Done :: struct {}

// The bytes of the Text field tpm_request: the words of a request
// (tpm_service.command_words). The field is not "request", which is the
// name of a control request of 16 bytes in the sound service: the longest, "the work of the service
// itself", has 30 bytes, and a zero byte.
TPM_REQUEST_FIELD_BYTES :: 32
// The bytes of the Text field of the bound that ended a wait
// (tpm_service.wait_bound_words): the longest, "the deadline of the work",
// has 24 bytes, and a zero byte.
BOUND_FIELD_BYTES :: 32

// The wait report of a wait of the interface that passed one more interval
// (src/md/features/tpm_sealed_machine_key.md, "A wait that is long"). The
// seconds are the count of the report times the interval: a fixed number,
// not the time of the clock at the check.
@(log_fact = "tpm: a wait passed {passed_seconds} s: {step}, for the TPM command {command_code} in locality {locality}, during {tpm_request}; waited {waited_milliseconds} ms")
Wait_Passed :: struct {
	passed_seconds:      u64,
	command_code:        value_kinds.Hexadecimal_Sixteen_Digits,
	locality:            u64,
	waited_milliseconds: u64,
	step:                [32]u8,
	tpm_request:         [32]u8,
}

// A wait of the interface reached its bound: the step and the work that
// waited, and which bound ended it.
@(log_fact = "tpm: a wait reached {ending_bound} after {waited_milliseconds} ms: {step}, for the TPM command {command_code} in locality {locality}, during {tpm_request}")
Wait_Bound_Reached :: struct {
	command_code:        value_kinds.Hexadecimal_Sixteen_Digits,
	locality:            u64,
	waited_milliseconds: u64,
	step:                [32]u8,
	tpm_request:         [32]u8,
	ending_bound:        [32]u8, // Not "bound": a field of that name is a time in milliseconds in each module.
}

// The service refused an unseal: the creation data names no PCR digest.
@(log_fact = "tpm: refused the unseal: the creation data does not name PCR 7 and PCR 11 with a digest")
Unseal_Creation_Data_Refused :: struct {}

// The service refused an unseal: the policy or the attributes of the
// object are not those of a seal.
@(log_fact = "tpm: refused the unseal: the policy of the object is not the policy of the PCR values of its creation, or its attributes are not the attributes of a sealed object")
Unseal_Policy_Refused :: struct {}

// The TPM refused the creation ticket of the object of an unseal.
@(log_fact = "tpm: refused the unseal: the TPM refuses the creation ticket of the object (response code {response_code}): this TPM did not make it so")
Unseal_Ticket_Refused :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM refused an unseal: the PCR values are not those of the seal.
@(log_fact = "tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal (response code {response_code})")
Unseal_Pcr_Values_Refused :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM refused an unseal: a wrong authorization value, which it
// counted.
@(log_fact = "tpm: the TPM refuses the unseal: the authorization value is wrong, and the TPM counted the failure (response code {response_code})")
Unseal_Authorization_Wrong :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM refused an unseal: it counted too many wrong values.
@(log_fact = "tpm: the TPM refuses the unseal: it counted too many wrong authorization values, and refuses each try for now (response code {response_code})")
Unseal_Locked_Out :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// An unseal done, with an authorization value.
@(log_fact = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal, and the authorization value is right")
Unsealed_With_Authorization :: struct {}

// An unseal done.
@(log_fact = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal")
Unsealed :: struct {}

// A seal of 32 bytes to an update-surviving publisher policy.
@(log_fact = "tpm: sealed 32 bytes to the publisher authorized update policy: a public area of {public_area} and a private area of {private_area}")
Sealed_Authorized :: struct {
	public_area:  value_kinds.Size_In_Bytes,
	private_area: value_kinds.Size_In_Bytes,
}

// An update-surviving unseal done after publisher signature and floor checks.
@(log_fact = "tpm: unsealed 32 bytes under the publisher authorized update policy and version floor")
Unsealed_Authorized :: struct {}

// The storage primary key was persisted and the owner hierarchy received a
// random authorization value sealed to the update policy.
@(log_fact = "tpm: persisted the storage key at {persistent_handle} and protected the owner hierarchy with a sealed random authorization value")
Owner_Hierarchy_Protected :: struct {
	persistent_handle: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM refused an extend of PCR 12.
@(log_fact = "tpm: the TPM refused the extend of PCR 12 (response code {response_code})")
Extend_Refused :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM took an extend of PCR 12, and refused its read back.
@(log_fact = "tpm: extended PCR 12, and its read back gave no value of PCR 12 of SHA-256 (response code {response_code})")
Extend_Read_Back_Refused :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The TPM refused a TPM2_GetCapability.
@(log_fact = "tpm: the TPM refused TPM2_GetCapability of {properties} (response code {response_code})")
Capability_Refused :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
	properties:    [32]u8,
}

// The TPM limits no rate of the wrong authorization values.
@(log_fact = "tpm: the TPM limits no rate of the wrong authorization values: its lockout interval is 0")
No_Rate_Limit :: struct {}

// The state of the lockout hierarchy was not read.
@(log_fact = "tpm: the lockout hierarchy is not checked: another system can reset the count of the TPM while its value is empty")
Lockout_Not_Checked :: struct {}

// The lockout hierarchy has an authorization value already.
@(log_fact = "tpm: the lockout hierarchy has an authorization value: an earlier start of this system set it, or another system did; this service keeps no copy of it and leaves it")
Lockout_Authorization_Found :: struct {}

// The lockout hierarchy keeps its empty value: the process has no seed.
@(log_fact = "tpm: the lockout hierarchy keeps its empty authorization value: this process has no seed, and another system can reset the count of the TPM")
Lockout_Kept_Empty_Without_Seed :: struct {}

// The lockout hierarchy keeps its empty value: the seed is too weak.
@(log_fact = "tpm: the lockout hierarchy keeps its empty authorization value: the seed of this process is too weak for a key, and another system can reset the count of the TPM")
Lockout_Kept_Empty_Weak_Seed :: struct {}

// The TPM refused a lockout authorization value.
@(log_fact = "tpm: the TPM refused a lockout authorization value (response code {response_code}): the lockout hierarchy keeps its empty one until the next start, and another system can reset the count of the TPM")
Lockout_Authorization_Refused :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The answer to the change of the lockout value has no valid form.
@(log_fact = "tpm: the answer of the TPM to TPM2_HierarchyChangeAuth of the lockout hierarchy does not have its form: the next start reads the state of the hierarchy again")
Lockout_Change_Answer_Malformed :: struct {}

// The service set a random lockout value and kept no copy.
@(log_fact = "tpm: the lockout hierarchy had an empty authorization value: this service set a random one and kept no copy, so no system resets the count of the TPM or changes its limits")
Lockout_Authorization_Set :: struct {}

// The service is ready: the address of its registers, as the line wrote
// it, and the buffer of the interface.
@(log_fact = "tpm: ok, the CRB interface at {registers_address}, a buffer of {buffer_size}; it seals to PCR 7 and PCR 11")
Ready :: struct {
	registers_address: value_kinds.Hexadecimal_Sixteen_Digits,
	buffer_size:       value_kinds.Size_In_Bytes,
}

// The service has no measure ring.
@(log_fact = "tpm: no measure ring: no start policy is measured into PCR 12")
No_Measure_Ring :: struct {}

// A completion did not fit in its full queue.
@(log_fact = "tpm: the completion queue of a ring of the TPM service is full: a completion is lost")
Completion_Lost :: struct {}

#assert(size_of(Capability_Refused) == 8 + PROPERTIES_FIELD_BYTES)
#assert(size_of(Shutdown_Interface_Failed) == STEP_FIELD_BYTES)
#assert(size_of(Wait_Passed) == 32 + STEP_FIELD_BYTES + TPM_REQUEST_FIELD_BYTES)
#assert(size_of(Wait_Bound_Reached) == 24 + STEP_FIELD_BYTES + TPM_REQUEST_FIELD_BYTES + BOUND_FIELD_BYTES)
#assert(size_of(Capability_Answer_Malformed) == PROPERTIES_FIELD_BYTES)

// step_field gives the Text field of the words of a step of the
// interface.
step_field :: proc "contextless" (step: tpm_service.Device_Step) -> [STEP_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_service.device_step_words[step], STEP_FIELD_BYTES)
}

// tpm_request_field gives the Text field of the words of a request.
tpm_request_field :: proc "contextless" (command: tpm_service.Command) -> [TPM_REQUEST_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_service.command_words[command], TPM_REQUEST_FIELD_BYTES)
}

// bound_field gives the Text field of the words of the bound that ended a
// wait.
bound_field :: proc "contextless" (bound: tpm_service.Wait_Bound) -> [BOUND_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_service.wait_bound_words[bound], BOUND_FIELD_BYTES)
}

// properties_field gives the Text field of the properties that a
// TPM2_GetCapability asks for.
properties_field :: proc "contextless" (what: string) -> [PROPERTIES_FIELD_BYTES]u8 {
	return value_kinds.text_field(what, PROPERTIES_FIELD_BYTES)
}

// bytes_field gives a count of bytes as a field with its unit.
bytes_field :: proc "contextless" (count: int) -> value_kinds.Size_In_Bytes {
	return value_kinds.Size_In_Bytes(count)
}
