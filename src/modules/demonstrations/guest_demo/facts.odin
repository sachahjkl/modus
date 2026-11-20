package guest_demo

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the demonstration guest_demo
// (src/md/features/log_facts.md, "The facts of the demonstrations"): its
// failures, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a step of a machine test that
// fails on "guest_demo: failed: " reads it as before. A Text field comes
// last, and holds its longest text and a zero byte.
//
// The status of a failure is the name of its member: `status_word` is the
// word type of the status. An address or an exit code is a field of the
// kind Hexadecimal_Sixteen_Digits, which writes it as system.Hex did. A
// case with no value is a fact type with no field.

// A step gave a status that stops the demonstration.
@(log_fact = "guest_demo: failed: {step} gave {status_word}")
Step_Failed :: struct {
	status_word: op.Status_Word,
	step:        [40]u8,
}

// A step that the kernel must refuse gave another status than the refusal.
@(log_fact = "guest_demo: failed: {step} gave {status_word}, not {expected}")
Step_Not_Refused :: struct {
	status_word: op.Status_Word,
	expected:    op.Status,
	step:        [36]u8,
}

// The exit of the port write names another count of bytes than 1.
@(log_fact = "guest_demo: failed: the port write has {port_write_bytes} bytes, not 1")
Port_Write_Size_Wrong :: struct {
	port_write_bytes: u64,
}

// The guest did not reach an instruction in the bound of its runs.
@(log_fact = "guest_demo: failed: the guest did not reach its {instruction} in {runs} runs")
Instruction_Not_Reached :: struct {
	runs:        u64,
	instruction: [8]u8,
}

// The guest wrote to its port another count of times, another value or to
// another port.
@(log_fact = "guest_demo: failed: the guest wrote {writes} times, the last {written_value} to the port {written_port}")
Port_Writes_Wrong :: struct {
	writes:        u64,
	written_value: u64,
	written_port:  u64,
}

// The guest halted at another address than its hlt.
@(log_fact = "guest_demo: failed: the guest halted at {halt_address}, not at {expected_address}")
Halted_Elsewhere :: struct {
	halt_address:     value_kinds.Hexadecimal_Sixteen_Digits,
	expected_address: value_kinds.Hexadecimal_Sixteen_Digits,
}

// An exit that the guest must not give: its kind, its code, its
// information and the instruction address.
@(log_fact = "guest_demo: failed: an exit of kind {exit_kind}, exit code {exit_code}, information {information}, at {instruction_address}")
Exit_Unexpected :: struct {
	exit_kind:           u64,
	exit_code:           value_kinds.Hexadecimal_Sixteen_Digits,
	information:         value_kinds.Hexadecimal_Sixteen_Digits,
	instruction_address: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The int1 of the guest gave another exit than Other with the code of a
// debug exception.
@(log_fact = "guest_demo: failed: int1 gave an exit of kind {exit_kind}, exit code {exit_code}, not Other with {expected_code}")
Debug_Exit_Wrong :: struct {
	exit_kind:     u64,
	exit_code:     value_kinds.Hexadecimal_Sixteen_Digits,
	expected_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The cases with no value: each sentence is its fact type.

@(log_fact = "guest_demo: Guest_Run gave Bad_Operation with the error kind Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest runs: as it must")
Guests_Unsupported :: struct {}

@(log_fact = "guest_demo: the guest wrote 42 to the port 0x80, then halted after it: as it must")
Port_Written_Then_Halted :: struct {}

@(log_fact = "guest_demo: the int1 of the guest arrived as an exit Other with the exit code 0x88: as it must")
Debug_Exit_Arrived :: struct {}

@(log_fact = "guest_demo: Process_Start of the guest gave Bad_State: as it must")
Guest_Start_Refused :: struct {}

// Each case held, or the machine runs no guest and the demonstration ends
// there.
@(log_fact = "guest_demo: ok")
Guest_Demo_Held :: struct {}
