package errors_process

import op "modus:contract/operation"

// The log facts of the demonstration errors (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its measures, its counts and the
// failures of its cases, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a machine
// test on that sentence reads it as before. A Text field comes last, and
// holds its longest text and a zero byte.
//
// The lines that hold the sentence of an error record stay text: that
// sentence is the subject of this process, and it is longer than a fact
// holds. So does the line longer than one log record, whose join the main
// test checks, and the stack of a fault, which the tool reads as text. A
// status of the kernel that a line writes as a number is a plain Integer,
// `status_word`.

// A name of a process with an escape byte was not refused.
@(log_fact = "errors: WRONG: a name of a process with an escape byte gave {status_word}")
Escaped_Name_Not_Refused :: struct {
	status_word: u64,
}

// A case of the table of error details gave another status or another
// count than its rule.
@(log_fact = "errors: WRONG: {details_case} gave the status {status_word} and {details} error details")
Details_Wrong :: struct {
	status_word:  u64,
	details:      u64,
	details_case: [48]u8,
}

// A table of one place gave another status or another count than its rule.
@(log_fact = "errors: WRONG: a table of 1 place gave the status {status_word} and the count {details}")
Small_Table_Wrong :: struct {
	status_word: u64,
	details:     u64,
}

// The case of a full completion queue could not make its memory.
@(log_fact = "errors: WRONG: the case of a full completion queue has no memory: {held_status_word} {refused_status_word}")
Full_Queue_Without_Memory :: struct {
	held_status_word:    u64,
	refused_status_word: u64,
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
	status_word: u64,
	error_kind:  i64,
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
	status_word:        u64,
	stage_word:         u64,
	kernel_status_word: u64,
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
