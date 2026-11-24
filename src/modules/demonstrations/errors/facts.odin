package errors_process

import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the demonstration errors (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its measures, its counts and the
// failures of its cases, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a machine
// test on that sentence reads it as before. A Text field comes last, and
// holds its longest text and a zero byte.
//
// The lines that hold the sentence of an error record, of a load error or
// of a stack stay text: those sentences are the subject of this process,
// and the main test checks each writer of them by its words. So does the
// line longer than one log record, whose join the main test checks. A
// status of the kernel is `status_word`, the word type of the status: the
// sentence writes the name of its member.

// A name of a process with an escape byte was not refused.
@(log_fact = "errors: WRONG: a name of a process with an escape byte gave {status_word}")
Escaped_Name_Not_Refused :: struct {
	status_word: call_outcome.Call_Outcome_Word,
}

// A case of the table of error details gave another status or another
// count than its rule.
@(log_fact = "errors: WRONG: {details_case} gave the status {status_word} and {details} error details")
Details_Wrong :: struct {
	status_word:  call_outcome.Call_Outcome_Word,
	details:      u64,
	details_case: [48]u8,
}

// A table of one place gave another status or another count than its rule.
@(log_fact = "errors: WRONG: a table of 1 place gave the status {status_word} and the count {details}")
Small_Table_Wrong :: struct {
	status_word: call_outcome.Call_Outcome_Word,
	details:     u64,
}

// The case of a full completion queue could not make its memory.
@(log_fact = "errors: WRONG: the case of a full completion queue has no memory: {held_status_word} {refused_status_word}")
Full_Queue_Without_Memory :: struct {
	held_status_word:    call_outcome.Call_Outcome_Word,
	refused_status_word: call_outcome.Call_Outcome_Word,
}

// A command past a full completion queue: whether the queue filled, and
// whether the command was held with no wait.
@(log_fact = "errors: WRONG: a command past a full completion queue: the queue filled: {queue_filled}; the command held with no wait: {command_held}")
Full_Queue_Command_Wrong :: struct {
	queue_filled: [8]u8,
	command_held: [8]u8,
}

// A kernel call on a kernel ring that holds records was not refused with
// Busy.
@(log_fact = "errors: WRONG: a kernel call on a kernel ring that holds records gave {status_word} and the kind {error_kind}")
Busy_Ring_Call_Not_Refused :: struct {
	status_word: call_outcome.Call_Outcome_Word,
	error_kind:  errors.Kind_Word,
}

// The answers of a full completion queue: whether each came once in order,
// and whether the held command ran once.
@(log_fact = "errors: WRONG: the answers of a full completion queue: each once in order: {answers_in_order}; the held command ran once: {held_command_ran}")
Full_Queue_Answers_Wrong :: struct {
	answers_in_order: [8]u8,
	held_command_ran: [8]u8,
}

// The measure of a kernel command with and without a table of error
// details.
@(log_fact = "errors: a kernel command and its table of error details: accepted with no table {accepted_without_table} ns, with a table {accepted_with_table} ns; refused with its error record {refused_with_record} ns, with its 2 error details {refused_with_details} ns")
Details_Measured :: struct {
	accepted_without_table: u64,
	accepted_with_table:    u64,
	refused_with_record:    u64,
	refused_with_details:   u64,
}

// The slot of the child served another process before its report was
// read.
@(log_fact = "errors: WRONG: the slot {slot} of the child served another process before its report was read")
Slot_Reused_Early :: struct {
	slot: u64,
}

// The report of the free slot of the child keeps a fact of the child.
@(log_fact = "errors: WRONG: the report of the free slot {slot} gives the state {state_word}, the stop cause {cause_word}, the stop outcome {outcome_word}, {handles} handles, {entries} entries of the process before it")
Free_Slot_Report_Wrong :: struct {
	slot:         u64,
	state_word:   u64,
	cause_word:   u64,
	outcome_word: u64,
	handles:      u64,
	entries:      u64,
}

// A stop on a kernel ring that holds records did not end the child as a
// stop of itself with Done.
@(log_fact = "errors: WRONG: a stop on a kernel ring that holds records left the child {child_state}{cause}, with the outcome {outcome}")
Busy_Ring_Stop_Wrong :: struct {
	cause:       op.Stop_Cause,
	outcome:     op.Stop_Outcome,
	child_state: [32]u8,
}

// The child of the refusals did not start: the status, the stage of the
// load, the status of the kernel and the error of the file.
@(log_fact = "errors: WRONG: the child of the refusals did not start: {status_word}, the stage {stage_word}, the status of the kernel {kernel_status_word}, the error of the file {file_error_word}")
Refusals_Child_Not_Started :: struct {
	status_word:        call_outcome.Call_Outcome_Word,
	stage_word:         u64,
	kernel_status_word: call_outcome.Call_Outcome_Word,
	file_error_word:    u64,
}

// The failures of two threads on the handles that a third thread closes
// and makes again.
@(log_fact = "errors: under contention: {failures} failures from 2 threads while a third thread closed and made {handles_made} handles; {wrong_records} records contradict their status, {refused_records} records name no cause (Refused)")
Contention_Counted :: struct {
	failures:        u64,
	handles_made:    u64,
	wrong_records:   u64,
	refused_records: u64,
}

// Each case gave its expected error record.
@(log_fact = "errors: ok, {cases} cases, each with the expected error record")
Errors_Held :: struct {
	cases: u64,
}

// Some cases gave another answer.
@(log_fact = "errors: {wrong_cases} cases of {cases} gave another answer")
Errors_Wrong :: struct {
	wrong_cases: u64,
	cases:       u64,
}

// The measure of a kernel operation and of a direct call, each that
// succeeds and that fails.
@(log_fact = "errors: a kernel operation that succeeds: {kernel_succeeds} ns; one that fails, with its error record: {kernel_fails} ns; a direct call that succeeds: {direct_succeeds} ns; one that fails: {direct_fails} ns")
Calls_Measured :: struct {
	kernel_succeeds: u64,
	kernel_fails:    u64,
	direct_succeeds: u64,
	direct_fails:    u64,
}

// The window shows another page of the cases.
@(log_fact = "errors: the window shows the page {page} of the cases")
Page_Shown :: struct {
	page: u64,
}

// The lines with no value: each sentence is its fact type.

@(log_fact = "errors: a name of a process with an escape byte is refused: as it must")
Escaped_Name_Refused :: struct {}

@(log_fact = "errors: a kernel command with two wrong arguments gives the two in its table of error details: as it must")
Two_Details_Given :: struct {}

@(log_fact = "errors: a table smaller than its error details holds the first and counts each one: as it must")
Small_Table_Counts_Each :: struct {}

@(log_fact = "errors: an accepted kernel command leaves its table of error details empty: as it must")
Accepted_Command_Table_Empty :: struct {}

@(log_fact = "errors: Log with a level that names no member and one run past the bound gives the two in its table of error details: as it must")
Log_Details_Given :: struct {}

@(log_fact = "errors: an accepted Log with a table of error details leaves the table empty: as it must")
Accepted_Log_Table_Empty :: struct {}

@(log_fact = "errors: WRONG: the kernel ring refused a push of the case of a full completion queue")
Full_Queue_Push_Refused :: struct {}

@(log_fact = "errors: a command past a full completion queue stays unrun in the kernel ring, and the entry does not wait: as it must")
Command_Past_Full_Queue_Held :: struct {}

@(log_fact = "errors: a kernel call on a kernel ring that holds records is refused with Busy, and its command does not run: as it must")
Busy_Ring_Call_Refused :: struct {}

@(log_fact = "errors: a wait of the library on a kernel ring that holds records ends at once and pushes nothing: as it must")
Busy_Ring_Wait_Ended :: struct {}

@(log_fact = "errors: WRONG: a wait of the library on a kernel ring that holds records waited or pushed its command")
Busy_Ring_Wait_Wrong :: struct {}

@(log_fact = "errors: each answer of a full completion queue arrives once and in order, and the held command runs once after them: as it must")
Full_Queue_Answers_In_Order :: struct {}

@(log_fact = "errors: the sum of the calls is 0")
Sum_Of_Calls_Zero :: struct {}

@(log_fact = "errors: the report of the slot of the child after its last handle closed gives its state None and its serial, and no fact of the child: as it must")
Free_Slot_Report_Empty :: struct {}

@(log_fact = "errors: a stop on a kernel ring that holds records ends the process as a stop of itself, not a fault: as it must")
Busy_Ring_Stop_Is_Itself :: struct {}

@(log_fact = "errors: no random seed in the context")
No_Random_Seed :: struct {}

@(log_fact = "errors: WRONG: the case under contention failed")
Contention_Case_Failed :: struct {}

// The measure of a failed call of each family that is not a kernel
// operation: a wrapper of support, a command of the root ring, an export.
// The times of the wrapper and of the export are in hundredths of a
// nanosecond.
@(log_fact = "errors: a failed call of each family: a wrapper of support (terminal.open with no terminal): {wrapper_time} ns; a command of the root ring (Connect refused): {root_time} ns; an export (tally.add with a note of 40 bytes, direct): {export_time} ns; {failures} failures")
Families_Measured :: struct {
	wrapper_time: value_kinds.Hundredths,
	root_time:    u64,
	export_time:  value_kinds.Hundredths,
	failures:     u64,
}

// The measure of refused calls: their time and the locks that they took.
@(log_fact = "errors: {log_refusals} refused Log: {log_time} ns each, the control lock taken {log_control_locks} times and the frame lock {log_frame_locks} times; {create_refusals} refused Memory_Create: {create_time} ns each, the control lock taken {create_control_locks} times and the frame lock {create_frame_locks} times")
Refusals_Measured :: struct {
	log_refusals:         u64,
	log_time:             u64,
	log_control_locks:    u64,
	log_frame_locks:      u64,
	create_refusals:      u64,
	create_time:          u64,
	create_control_locks: u64,
	create_frame_locks:   u64,
}
