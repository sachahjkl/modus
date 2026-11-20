package fault_ring

import op "modus:contract/operation"

// The log facts of the demonstration fault_ring
// (src/md/features/log_facts.md, "The facts of the demonstrations"): its
// cases, the controls of a thread and the faults of a child, as records of
// fields. Each fact template is the sentence that the line wrote before it
// was a fact, so a wait of a machine test on that sentence reads it as
// before. A Text field comes last, and holds its longest text and a zero
// byte. A verdict is "as it must" or "WRONG"; a case name is the name of a
// row of the window.
//
// Some lines stay text: an address, a value or the result bits that
// system.Hex writes in 16 digits with no "0x", which no field kind writes;
// the load of a child that did not start, a free sentence; the outcome of
// the lost debug frame, a sentence longer than a fact holds beside its
// verdict; and the lines with no value.

// A child stops at a step that is not the check of its case.
@(log_fact = "fault_ring: a child: {step} failed")
Child_Step_Failed :: struct {
	step: [56]u8,
}

// A write to a read-only page, which the handler repaired.
@(log_fact = "fault_ring: a write to a read-only page: the handler gave Write back; the page holds {page_value}: {verdict}")
Read_Only_Write_Repaired :: struct {
	page_value: u64,
	verdict:    [16]u8,
}

// A stack that grows, each page committed by the handler.
@(log_fact = "fault_ring: a stack that grows: {repaired_pages} pages of {stack_pages}, each one committed by the handler at its first touch; one repaired fault took {least_repair_time} ns at least: {verdict}")
Stack_Grown :: struct {
	repaired_pages:    u64,
	stack_pages:       u64,
	least_repair_time: u64,
	verdict:           [16]u8,
}

// An answer with a wrong serial, and what the kernel did with it.
@(log_fact = "fault_ring: an answer with a wrong serial: {serial_answer}")
Wrong_Serial_Answer :: struct {
	serial_answer: [80]u8,
}

// An answer from another process for a thread of the child.
@(log_fact = "fault_ring: an answer from another process: the parent answered for the thread {answered_thread} and the serial {answered_serial}: {foreign_answer}; the thread still waited, and the answer of its own process resumed it: {verdict}")
Foreign_Answer :: struct {
	answered_thread: u64,
	answered_serial: u64,
	foreign_answer:  [24]u8,
	verdict:         [16]u8,
}

// Answers given at once to many faults.
@(log_fact = "fault_ring: 10 000 answers given at once: {answers} faults resumed, {right_values} values right, of {early_faults}: {verdict}, in {elapsed} ms")
Early_Answers :: struct {
	answers:      u64,
	right_values: u64,
	early_faults: u64,
	elapsed:      u64,
	verdict:      [16]u8,
}

// A breakpoint answered with resume.
@(log_fact = "fault_ring: a breakpoint, answered resume: {records_seen} record of the kind {record_kind}; the thread went on after the int3 and computed {computed}: {verdict}")
Breakpoint_Resumed :: struct {
	records_seen: u64,
	record_kind:  u64,
	computed:     u64,
	verdict:      [16]u8,
}

// The kinds of a fault that never come to a handler.
@(log_fact = "fault_ring: the kinds never delivered: Fault_Handler_Set refused {refused_arguments} arguments of {asked_arguments} with Bad_Operation: {verdict}")
Kinds_Never_Delivered :: struct {
	refused_arguments: u64,
	asked_arguments:   u64,
	verdict:           [16]u8,
}

// A kind of a fault that the handler answers: its record names the
// instruction of the stop report.
@(log_fact = "fault_ring: {case_name}: {records_seen} record of the kind {record_kind}, the error code {error_code}, the instruction of the stop report; Resume got {resume_answer}: {verdict}")
Fault_Kind_At_Report_Instruction :: struct {
	records_seen:  u64,
	record_kind:   u64,
	error_code:    u64,
	case_name:     [48]u8,
	resume_answer: [32]u8,
	verdict:       [16]u8,
}

// A kind of a fault that the handler answers: its record does not name the
// instruction of the stop report.
@(log_fact = "fault_ring: {case_name}: {records_seen} record of the kind {record_kind}, the error code {error_code}, not the instruction of the stop report; Resume got {resume_answer}: {verdict}")
Fault_Kind_Not_At_Report_Instruction :: struct {
	records_seen:  u64,
	record_kind:   u64,
	error_code:    u64,
	case_name:     [48]u8,
	resume_answer: [32]u8,
	verdict:       [16]u8,
}

// A stop of a thread that spins.
@(log_fact = "fault_ring: a stop of a thread that spins: {address_place}, {loop_motion}: {verdict}")
Spinning_Thread_Stopped :: struct {
	address_place: [48]u8,
	loop_motion:   [56]u8,
	verdict:       [16]u8,
}

// A frame that a process cannot hold: each hostile write refused.
@(log_fact = "fault_ring: a frame that a process cannot hold: {refused_writes} writes of {writes} refused with Bad_Operation (the code selector of the kernel, the I/O privilege level, interrupts off, an instruction address that is not canonical); {run_after}: {verdict}")
Hostile_Frame_Refused :: struct {
	refused_writes: u64,
	writes:         u64,
	run_after:      [40]u8,
	verdict:        [16]u8,
}

// Thread_State gave a layout that names none.
@(log_fact = "fault_ring: Thread_State gave the layout {layout_word}, which names no layout: WRONG")
Layout_Unknown :: struct {
	layout_word: u64,
}

// An extended state that faults: each hostile write refused.
@(log_fact = "fault_ring: an extended state that faults: every hostile write refused with Bad_Operation, the area that was read accepted; {run_after_resume}: {verdict}")
Hostile_Extended_State_Refused :: struct {
	run_after_resume: [40]u8,
	verdict:          [16]u8,
}

// A stop of a thread that waits.
@(log_fact = "fault_ring: a stop of a thread that waits: its wait ended, {before_resume}, {after_resume}: {verdict}")
Waiting_Thread_Stopped :: struct {
	before_resume: [40]u8,
	after_resume:  [32]u8,
	verdict:       [16]u8,
}

// Two stops of a thread need two resumes.
@(log_fact = "fault_ring: two stops, two resumes: {after_one_resume}, {after_two_resumes}; a third Resume got {third_resume}: {verdict}")
Two_Stops_Two_Resumes :: struct {
	third_resume:      op.Status,
	after_one_resume:  [32]u8,
	after_two_resumes: [32]u8,
	verdict:           [16]u8,
}

// A divide error that the handler skipped.
@(log_fact = "fault_ring: a divide error skipped by its handler: Resume before the write got {resume_status}; after the write of the instruction address and rax, the thread went on with {result}: {verdict}")
Divide_Error_Skipped :: struct {
	result:        u64,
	resume_status: op.Status,
	verdict:       [20]u8,
}

// The thread of another process, which no number and no handle names.
@(log_fact = "fault_ring: the thread of another process: {refused_calls} calls of {tried_calls} refused; no number and no handle of this process names it: {verdict}")
Foreign_Thread_Refused :: struct {
	refused_calls: u64,
	tried_calls:   u64,
	verdict:       [16]u8,
}

// The entries of the kernel and the debug trap, each a case of its own.
@(log_fact = "fault_ring: int 3 in two bytes: one breakpoint record, at the address of the instruction plus 2: {verdict}")
Two_Byte_Breakpoint :: struct {
	verdict: [16]u8,
}

@(log_fact = "fault_ring: int 14: one protection fault with the error code 0x72, no page fault; the handler skipped the two bytes: {verdict}")
Software_Page_Fault_Vector :: struct {
	verdict: [16]u8,
}

@(log_fact = "fault_ring: int1: one debug record, at the address of the instruction plus 1: {verdict}")
Debug_Instruction :: struct {
	verdict: [16]u8,
}

@(log_fact = "fault_ring: the trap flag set with popfq: 6 debug records, one after each instruction, the last after the popfq that cleared the flag: {verdict}")
Trap_Flag_Steps :: struct {
	verdict: [16]u8,
}

@(log_fact = "fault_ring: mov ss, then syscall, with the trap flag: on this processor the machine went on, and each record is a debug trap of this process, in its code: {verdict}")
Stack_Selector_Then_Syscall :: struct {
	verdict: [16]u8,
}

@(log_fact = "fault_ring: mov ss, then int3, with the trap flag: on this processor the machine went on; one breakpoint record after the int3, and each other record is a debug trap of this process, in its code: {verdict}")
Stack_Selector_Then_Breakpoint :: struct {
	verdict: [16]u8,
}

@(log_fact = "fault_ring: two int1 in a row: two debug records, at the address of the first plus 1 and plus 2: {verdict}")
Two_Debug_Instructions :: struct {
	verdict: [16]u8,
}

// The shared page of a child could not be made or mapped.
@(log_fact = "fault_ring: {case_name}: {failed_call} of the shared page failed: {call_status}")
Shared_Page_Failed :: struct {
	call_status: op.Status,
	case_name:   [56]u8,
	failed_call: [16]u8,
}

// An answer of the parent for a fault of the child was not refused.
@(log_fact = "fault_ring: {case_name}: Fault_Answer of the parent gave {answer_status}, not Bad_State")
Parent_Answer_Not_Refused :: struct {
	answer_status: op.Status,
	case_name:     [56]u8,
}

// A child did not stop in the hang bound.
@(log_fact = "fault_ring: {case_name}: the child did not stop in {bound} ms")
Child_Not_Stopped :: struct {
	bound:     u64,
	case_name: [56]u8,
}

// The child of the early answers did not stop in the overall bound.
@(log_fact = "fault_ring: {case_name}: the child did not stop in {overall_bound} ms: at step {progress} of {early_faults}, {answers} answers, after {elapsed} ms")
Child_Not_Stopped_Overall :: struct {
	overall_bound: u64,
	progress:      u64,
	early_faults:  u64,
	answers:       u64,
	elapsed:       u64,
	case_name:     [56]u8,
}

// The child of the early answers made no progress in the hang bound.
@(log_fact = "fault_ring: {case_name}: the child did not stop: no progress for {bound} ms at step {progress} of {early_faults}, {answers} answers, after {elapsed} ms")
Child_Without_Progress :: struct {
	bound:        u64,
	progress:     u64,
	early_faults: u64,
	answers:      u64,
	elapsed:      u64,
	case_name:    [56]u8,
}

// The budget of this process did not get back the amounts of a child in
// the hang bound.
// The fields without "_after" are the amounts that the budget must hold
// again: those before the start of the child.
@(log_fact = "fault_ring: {case_name}: the budget of this process did not get back every page, thread and process of the child in {bound} ms: pages {pages} expected, {pages_after} after; threads {threads}, {threads_after}; processes {processes}, {processes_after}")
Budget_Not_Returned :: struct {
	bound:           u64,
	pages:           u64,
	pages_after:     u64,
	threads:         u64,
	threads_after:   u64,
	processes:       u64,
	processes_after: u64,
	case_name:       [56]u8,
}

// The budget of this process after the line of a budget not returned.
@(log_fact = "fault_ring: {case_name}: after the line: pages {pages}, threads {threads}, processes {processes}")
Budget_After_Line :: struct {
	pages:     u64,
	threads:   u64,
	processes: u64,
	case_name: [56]u8,
}

// The context names a role that names none.
@(log_fact = "fault_ring: the context names the role {role_word}, which names no role")
Role_Unknown :: struct {
	role_word: u64,
}

// A child stopped by this process after it stopped keeps its stop cause.
@(log_fact = "fault_ring: {case_name}: stopped again by this process, the child keeps the stop cause {cause}: {verdict}")
Stopped_Again :: struct {
	cause:     op.Stop_Cause,
	case_name: [56]u8,
	verdict:   [16]u8,
}

// The records that the handler read, and the vector of the stop report.
@(log_fact = "fault_ring: {case_name}: the handler read {records_read} records; the stop report names the vector {vector}: {verdict}")
Handler_Records_Read :: struct {
	records_read: u64,
	vector:       u64,
	case_name:    [56]u8,
	verdict:      [16]u8,
}

// The thread of the parent that a child tried to control.
@(log_fact = "fault_ring: {case_name}: the thread of the parent has the stop count {stop_count} and {parent_thread_running}: {verdict}")
Parent_Thread_Kept :: struct {
	stop_count:            u64,
	case_name:             [56]u8,
	parent_thread_running: [16]u8,
	verdict:               [16]u8,
}

// The thread of the parent for the case of a foreign thread did not
// start.
@(log_fact = "fault_ring: {case_name}: the thread of the parent did not start: {start_status}")
Parent_Thread_Not_Started :: struct {
	start_status: op.Status,
	case_name:    [56]u8,
}

// Each case held.
@(log_fact = "fault_ring: ok, {cases} cases: each fault was repaired, or stopped its process with the report of today, each control of a thread held, and each child gave back every page and every thread")
Fault_Ring_Held :: struct {
	cases: u64,
}

// Some cases did not hold.
@(log_fact = "fault_ring: failed: {wrong_cases} cases of {cases}")
Fault_Ring_Failed :: struct {
	wrong_cases: u64,
	cases:       u64,
}
