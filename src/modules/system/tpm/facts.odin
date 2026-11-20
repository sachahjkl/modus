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

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Shutdown_Interface_Failed) == STEP_FIELD_BYTES)
#assert(size_of(Capability_Answer_Malformed) == PROPERTIES_FIELD_BYTES)

// step_field gives the Text field of the words of a step of the
// interface.
step_field :: proc "contextless" (step: tpm_service.Device_Step) -> [STEP_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_service.device_step_words[step], STEP_FIELD_BYTES)
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
