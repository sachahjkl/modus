package guest_demo

import op "modus:contract/operation"

// The log facts of the demonstration guest_demo
// (src/md/features/log_facts.md, "The facts of the demonstrations"): its
// failures, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a step of a machine test that
// fails on "guest_demo: failed: " reads it as before. A Text field comes
// last, and holds its longest text and a zero byte.
//
// The status of a failure is the number of its word, as the line wrote it:
// `status_word` is a plain Integer. The lines of its cases have no value
// and stay text, and so do the failures with an address or an exit code,
// which system.Hex writes in 16 digits with no "0x".

// A step gave a status that stops the demonstration.
@(log_fact = "guest_demo: failed: {step} gave {status_word}")
Step_Failed :: struct {
	status_word: u64,
	step:        [40]u8,
}

// A step that the kernel must refuse gave another status than the refusal.
@(log_fact = "guest_demo: failed: {step} gave {status_word}, not {expected}")
Step_Not_Refused :: struct {
	status_word: u64,
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
