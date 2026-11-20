package debugged

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the demonstration debugged (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its cases, their details and its
// failures, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. A Text field comes last, and holds its
// longest text and a zero byte.
//
// Each case is a fact type of its own, whose one field is its verdict:
// "as it must" or "WRONG". The sentences of three cases are longer than a
// Text field beside the verdict can hold, so the case is the type, and
// `facts(debugged.Breakpoints_Removed)` gives that case.
//
// An address or a status of the processor in a line of detail is a field
// of the kind Hexadecimal_Sixteen_Digits, which writes it as system.Hex
// did. A line with no value is a fact type with no field.

// The verdict field holds "as it must" and a zero byte: 16 bytes.
@(log_fact = "debugged: attach: the debugger is the debug handler of the child: {verdict}")
Attach_Checked :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a write of breakpoints on a thread that is not held: refused with Bad_State: {verdict}")
Breakpoints_On_Running_Thread_Refused :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a handle with no Debug: attach and Stop refused with No_Right: {verdict}")
Handle_Without_Debug_Refused :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a breakpoint at an address of the kernel: refused with the breakpoint address in the error record: {verdict}")
Kernel_Breakpoint_Refused :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: an execute breakpoint at a procedure of the child: the fault record names breakpoint 0 and the address: {verdict}")
Execute_Breakpoint_Reached :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: the registers at the stop: the instruction address is the breakpoint: {verdict}")
Registers_At_Breakpoint :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: Read_Memory of a value of the child: the bytes of the child, not of the debugger: {verdict}")
Child_Memory_Read :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: Read_Memory at an address of the kernel: refused with Bad_Address: {verdict}")
Kernel_Memory_Read_Refused :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: Read_Memory of a page that the child does not map: refused with Bad_Address: {verdict}")
Unmapped_Memory_Read_Refused :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: Read_Memory through a thread handle with Inspect only: refused with No_Right: {verdict}")
Inspect_Only_Memory_Read_Refused :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a write of breakpoints on a thread of the caller, with no Debug handle: refused with Bad_Handle: {verdict}")
Own_Thread_Breakpoints_Refused :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a single step: one instruction ran, and the record names the step: {verdict}")
Single_Step_Checked :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a data breakpoint on a word that the child writes: the fault record names breakpoint 1: {verdict}")
Data_Breakpoint_Reached :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: the breakpoints removed: the child resumed and stopped itself at its end: {verdict}")
Breakpoints_Removed :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a detach while a thread is held: the child runs again: {verdict}")
Detach_While_Held :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: the debugger ended while the child was held at a breakpoint: the child runs again: {verdict}")
Debugger_Ended_While_Held :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: the debugger closed its handle while the child was held at a breakpoint: the child runs again: {verdict}")
Debugger_Closed_While_Held :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: the handle of the debugger was revoked while the child was held at a breakpoint: the child runs again: {verdict}")
Debugger_Revoked_While_Held :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a single step, then the end of the debugger: the child ran to its own end: {verdict}")
Step_Then_Debugger_End :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a breakpoint of one thread: that thread stops, and another thread of the child runs through the same procedure: {verdict}")
Breakpoint_Of_One_Thread :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a stop of the child on its own thread, then a stop and a detach of the debugger: the thread is still held by the stop of the child: {verdict}")
Own_Stop_Kept_After_Detach :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a data breakpoint on a buffer that the kernel copies: the operation succeeded, no record came for the copy, and the read of the child came: {verdict}")
Kernel_Copy_Breakpoint :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a data breakpoint that a load of the stack selector holds before a syscall: the kernel entry returned: {verdict}")
Stack_Selector_Breakpoint :: struct {
	verdict: [16]u8,
}

@(log_fact = "debugged: a full ring of the debugger: the breakpoint is lost for the debugger, the child goes on, and a record comes again when the ring has room: {verdict}")
Full_Debugger_Ring :: struct {
	verdict: [16]u8,
}

// A process that the demonstration waits for did not stop in the hang
// bound.
@(log_fact = "debugged: detail: {subject} did not stop")
Detail_Not_Stopped :: struct {
	subject: [32]u8,
}

// A process that the demonstration waits for stopped itself, with its
// outcome.
@(log_fact = "debugged: detail: {subject} stopped: {cause}, {outcome}")
Detail_Stopped :: struct {
	cause:   op.Stop_Cause,
	outcome: op.Stop_Outcome,
	subject: [32]u8,
}

// A process that the demonstration waits for stopped for another cause than
// itself: it chose no outcome.
@(log_fact = "debugged: detail: {subject} stopped: {cause}")
Detail_Stopped_Without_Outcome :: struct {
	cause:   op.Stop_Cause,
	subject: [36]u8,
}

// A child or a second debugger stops at a step that failed.
@(log_fact = "debugged: {role}: {step} failed")
Step_Failed :: struct {
	role: [24]u8,
	step: [56]u8,
}

// The context of a child or of a second debugger names a mode that names
// none.
@(log_fact = "debugged: the context names the {mode_owner} mode {mode_word}, which names no mode")
Mode_Unknown :: struct {
	mode_word:  u64,
	mode_owner: [16]u8,
}

// The context names a role that names none.
@(log_fact = "debugged: the context names the role {role_word}, which names no role")
Role_Unknown :: struct {
	role_word: u64,
}

// The status of the attach, when it is not Ok.
@(log_fact = "debugged: detail: the attach gave the status {status_word}")
Attach_Status :: struct {
	status_word: op.Status_Word,
}

// The first breakpoint was not set: the words of the status of the stop,
// of the write and of the resume.
@(log_fact = "debugged: the first breakpoint was not set: the statuses {stop_status_word} {write_status_word} {resume_status_word}")
First_Breakpoint_Not_Set :: struct {
	stop_status_word:   op.Status_Word,
	write_status_word:  op.Status_Word,
	resume_status_word: op.Status_Word,
}

// The rounds of the child after the breakpoints were removed.
@(log_fact = "debugged: detail: the child ran {rounds} rounds")
Child_Rounds :: struct {
	rounds: u64,
}

// The revocation of the handle of the second debugger.
@(log_fact = "debugged: detail: the revocation ended {holdings} holdings")
Revocation_Ended :: struct {
	holdings: u64,
}

// The counts of a stop of the child on its own thread and of the stop of
// the debugger.
@(log_fact = "debugged: detail: the stop of the debugger gave the count {stop_count}; the Resume of the child gave the status {resume_status_word} and the count {resume_count}")
Own_Stop_Counts :: struct {
	stop_count:         u64,
	resume_status_word: op.Status_Word,
	resume_count:       u64,
}

// The data breakpoints of the kernel copy were not set: the words of the
// status of the attach, of the stop, of the write and of the resume.
@(log_fact = "debugged: the data breakpoints were not set: the statuses {attach_status_word} {stop_status_word} {write_status_word} {resume_status_word}")
Data_Breakpoints_Not_Set :: struct {
	attach_status_word: op.Status_Word,
	stop_status_word:   op.Status_Word,
	write_status_word:  op.Status_Word,
	resume_status_word: op.Status_Word,
}

// Where the trap of the load of the stack selector went.
@(log_fact = "debugged: detail: the trap of the load of the stack selector {trap_path}")
Stack_Selector_Trap :: struct {
	trap_path: [64]u8,
}

// The faults that found the ring of the debugger full.
@(log_fact = "debugged: detail: the faults that found the ring full: {faults}")
Full_Ring_Faults :: struct {
	faults: u64,
}

// Each case held.
@(log_fact = "debugged: ok, {cases} cases: a debugger holds, reads and steps one process, and its end gives the process back")
Debugged_Held :: struct {
	cases: u64,
}

// Some cases did not hold.
@(log_fact = "debugged: failed: {wrong_cases} cases of {cases}")
Debugged_Failed :: struct {
	wrong_cases: u64,
	cases:       u64,
}

// The record of the execute breakpoint: its kind, the status of the
// processor, the instruction and the procedure, each address as
// system.Hex writes it.
@(log_fact = "debugged: detail: the record of the execute breakpoint: kind {record_kind}, status {error_code}, instruction {instruction}, the procedure {procedure}")
Execute_Breakpoint_Record :: struct {
	record_kind: u64,
	error_code:  value_kinds.Hexadecimal_Sixteen_Digits,
	instruction: value_kinds.Hexadecimal_Sixteen_Digits,
	procedure:   value_kinds.Hexadecimal_Sixteen_Digits,
}

// The value that Read_Memory read in the child, and the copy of the
// debugger.
@(log_fact = "debugged: detail: the value of the child {child_value}, the copy of the debugger {debugger_copy}")
Child_Value_Read :: struct {
	child_value:   value_kinds.Hexadecimal_Sixteen_Digits,
	debugger_copy: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The single step: the status of the processor, the instruction address
// before and after, and the first byte of the instruction.
@(log_fact = "debugged: detail: the step: status {error_code}, the instruction address from {address_before} to {address_after}, the first byte {first_byte}")
Step_Detail :: struct {
	error_code:     value_kinds.Hexadecimal_Sixteen_Digits,
	address_before: value_kinds.Hexadecimal_Sixteen_Digits,
	address_after:  value_kinds.Hexadecimal_Sixteen_Digits,
	first_byte:     value_kinds.Hexadecimal_Sixteen_Digits,
}

// The record of the data breakpoint, and the word that the child wrote.
@(log_fact = "debugged: detail: the record of the data breakpoint: kind {record_kind}, status {error_code}, the word of the child {child_word}")
Data_Breakpoint_Record :: struct {
	record_kind: u64,
	error_code:  value_kinds.Hexadecimal_Sixteen_Digits,
	child_word:  u64,
}

// The status of the Log of the child on a watched buffer, by the name of
// its member, and the status of the processor in the record of the read.
@(log_fact = "debugged: detail: Log gave the status {log_status}; the record of the read of the child: status {error_code}")
Kernel_Copy_Detail :: struct {
	log_status: op.Status_Word,
	error_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// The lines with no value: each sentence is its fact type.

@(log_fact = "debugged: no shared page")
No_Shared_Page :: struct {}

@(log_fact = "debugged: a child did not start")
Child_Not_Started :: struct {}

@(log_fact = "debugged: an execute breakpoint at a procedure of the child: no record came: WRONG")
Execute_Breakpoint_Without_Record :: struct {}

@(log_fact = "debugged: no random seed in the context")
No_Random_Seed :: struct {}

@(log_fact = "debugged: no boot image")
No_Boot_Image :: struct {}
