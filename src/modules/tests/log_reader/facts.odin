package log_reader

import "modus:contract/call_status"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the lines of log_reader (src/md/features/log_facts.md):
// its checks, its refusals and its measures, as records of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of the machine test on that sentence reads it as before; an
// error kind that a line wrote as its number is now the name of its
// member. Fact_Probe and the two facts of the measured lines are in
// main.odin and measures.odin, beside the code that reads their bytes
// back.
//
// Two kinds of lines stay text, on purpose:
//
// - the record of this process and the record of each child: the test
//   reads their text and their value run back through the log service;
// - the line of a bad block and the line of a connection of the measures:
//   the measure compares their write as text with their write as a fact.
//
// A status of a call, the kind of an object and the form of a record are
// the words of their contract enums, written by the names of their
// members. A field of a status of a call is named `status`, not after the
// package call_status, so that a field and a local of that name never
// hide the package; main.odin converts with call_status_word.
//
// A field of the name of a process holds the name and a zero byte; the
// name of a refused call or of an edge is a Text field of its own size.
// A Text field is the last field, and is [N]u8 with N written out, as the
// tool reads it. No field has the name of a column of the head of facts():
// number, time, process, level.

// The bytes of the Text field of the name of a call of Log that the kernel
// must refuse: the longest, "a fact at the level one past the last
// member", has 44 bytes. The record ends on 8 bytes with no padding.
REFUSAL_NAME_FIELD_BYTES :: 52
// The bytes of the Text field of the name of an edge that Log takes: the
// longest, "one byte on the last byte of a mapped page", has 42 bytes.
EDGE_NAME_FIELD_BYTES :: 48

// The log service gave rows of other processes.
@(log_fact = "log_reader: WRONG: the log service gave {other_rows} rows of other processes")
Wrong_Other_Rows :: struct {
	other_rows: u64,
}

// The log service did not give the record that this process wrote.
@(log_fact = "log_reader: WRONG: the log service gave {own_rows} rows, the first with lost {first_lost}, and not the record that this process wrote")
Wrong_Own_Record_Missing :: struct {
	own_rows:   u64,
	first_lost: i64,
}

// The log service gave a row before the first record of this process, or
// of an earlier run. The names are short: the template holds 256 bytes.
@(log_fact = "log_reader: WRONG: the log service gave {rows} rows of the name log_reader, the first with the number {first} and lost {lost}, the record of this process with the number {own_number}; one row, its first record, with the number 0 and lost 0, was the answer")
Wrong_Own_Rows :: struct {
	rows:       u64,
	first:      i64,
	lost:       i64,
	own_number: i64,
}

// The log service gave value runs of other records.
@(log_fact = "log_reader: WRONG: the log service gave {other_runs} value runs of other records")
Wrong_Other_Runs :: struct {
	other_runs: u64,
}

// The own records of this process: its one record, in its slot.
@(log_fact = "log_reader: its own records: {own_rows} rows from the own number 0, its first record, in the slot {slot}, lost 0: no row of another process or of an earlier run: as it must")
Own_Records_Read :: struct {
	own_rows: u64,
	slot:     i64,
}

// The value runs of the own records of this process.
@(log_fact = "log_reader: the value runs: {runs} rows, each of a record of this process, with the run of its value {own_value}: as it must")
Own_Value_Runs_Read :: struct {
	runs:      u64,
	own_value: u64,
}

// The own log ring of each process kept its records after the storm.
@(log_fact = "log_reader: a child wrote {storm_records} records after the records of this process and of its two children, more than the {whole_log_capacity} that the whole log keeps, and the own log ring of each one kept its records: as it must")
Own_Log_Rings_Kept :: struct {
	storm_records:      u64,
	whole_log_capacity: u64,
}

// The storm child took its log records of each second from the budget of
// this process, and gave them back at its stop.
@(log_fact = "log_reader: the storm child took {storm_log_records} of the {whole_log_records} log records of each second of this process, which kept {kept_log_records}, and each child gave its records back at its stop: as it must")
Storm_Log_Records_Taken :: struct {
	storm_log_records: u64,
	whole_log_records: u64,
	kept_log_records:  u64,
}

// Log of the form Fact did not refuse a wrong fact with its status and its
// error record.
@(log_fact = "log_reader: WRONG: Log of a fact with {refusal} gave {status}, the error kind {error_kind} for the argument {argument} with the value {value}")
Wrong_Fact_Refusal :: struct {
	error_kind: i64,
	argument:   i64,
	value:      i64,
	status:     op.Status,
	refusal:    [52]u8,
}

// The refused facts changed the own log ring or the budget.
@(log_fact = "log_reader: WRONG: the refused facts changed the own log ring ({records_before} then {records_after} records) or the budget")
Wrong_Refused_Facts_Changed :: struct {
	records_before: i64,
	records_after:  i64,
}

// Log refused a fact at an edge that it takes. The length is at most the
// bytes of a whole fact, so 4 bytes hold it, beside the 4 of the status,
// with no padding.
@(log_fact = "log_reader: WRONG: Log of a fact of {length} bytes gave {status}")
Wrong_Fact_Edge_Refused :: struct {
	length: u32,
	status: op.Status,
}

// The facts at the edges took another count of records than one each.
@(log_fact = "log_reader: WRONG: the two facts at the edges and the fact of system.log_fact took {records_taken} records, not {records_expected}")
Wrong_Fact_Records :: struct {
	records_taken:    i64,
	records_expected: i64,
}

// Log wrote the facts at the edges, and system.log_fact its fact, each in
// one record.
@(log_fact = "log_reader: Log wrote a fact of {head_bytes} bytes and a fact of {whole_bytes} bytes, and system.log_fact the fact Fact_Probe, each in one record: as it must")
Facts_Written :: struct {
	head_bytes:  u64,
	whole_bytes: u64,
}

// log.fact_records gave another count of facts than the three of this
// process.
@(log_fact = "log_reader: WRONG: log.fact_records gave {facts} facts of this process, not 3")
Wrong_Fact_Count :: struct {
	facts: i64,
}

// The three facts read back hold what the kernel must write.
@(log_fact = "log_reader: the three facts read back: the form Fact, no next record, the reserved bytes 0, the key of each writer, 0, {whole_value_bytes} and {probe_value_bytes} value bytes, and the hash of this module in the fact of system.log_fact: as it must")
Facts_Read_Back :: struct {
	whole_value_bytes: u64,
	probe_value_bytes: u64,
}

// Log did not refuse a wrong call with its status and its error record.
@(log_fact = "log_reader: WRONG: Log with {refusal} gave {status}, the error kind {error_kind} for the argument {argument} with the value {value}")
Wrong_Text_Refusal :: struct {
	error_kind: i64,
	argument:   i64,
	value:      i64,
	status:     op.Status,
	refusal:    [52]u8,
}

// A refused call of Log wrote a record.
@(log_fact = "log_reader: WRONG: the own log ring kept {records_before} records before the refused calls of Log, and {records_after} after them")
Wrong_Refused_Calls_Wrote :: struct {
	records_before: i64,
	records_after:  i64,
}

// A refused call of Log changed the log records of the budget.
@(log_fact = "log_reader: WRONG: the budget held {log_records_before} log records and counted {refused_before} refused before the refused calls of Log, and {log_records_after} and {refused_after} after them")
Wrong_Refused_Calls_Changed_Budget :: struct {
	log_records_before: u64,
	refused_before:     u64,
	log_records_after:  u64,
	refused_after:      u64,
}

// Log refused a call at an edge that it takes.
@(log_fact = "log_reader: WRONG: Log with {edge} gave {status}")
Wrong_Edge_Refused :: struct {
	status: op.Status,
	edge:   [48]u8,
}

// The calls at the edges took another count of records.
@(log_fact = "log_reader: WRONG: the calls at the edges took {records_taken} records, not {records_expected}")
Wrong_Edge_Records :: struct {
	records_taken:    i64,
	records_expected: i64,
}

// The record of the text with the most runs kept another count of runs.
@(log_fact = "log_reader: WRONG: the record of the text with {call_runs} runs kept {kept_runs} runs")
Wrong_Runs_Kept :: struct {
	call_runs: u64,
	kept_runs: i64,
}

// Log wrote each text at an edge that it takes.
@(log_fact = "log_reader: Log wrote a text of 0 bytes, of 1 byte and of {text_bytes} bytes in 1, 1 and {text_records} records, a text at the level Error, a text with {call_runs} runs that keeps {kept_runs}, and one byte on the last byte of a page: as it must")
Texts_Written :: struct {
	text_bytes:   u64,
	text_records: u64,
	call_runs:    u64,
	kept_runs:    u64,
}

// The lend of the process handle of the log service, which has no Give,
// did not fail with No_Right.
@(log_fact = "log_reader: WRONG: the lend of the process handle of the log service gave {status}")
Wrong_Service_Handle_Lent :: struct {
	status: op.Status,
}

// A child did not start.
@(log_fact = "log_reader: WRONG: {child} did not start: {status}")
Wrong_Child_Not_Started :: struct {
	status: op.Status,
	child:  value_kinds.Module_Name_Field,
}

// A child did not stop within the hang bound.
@(log_fact = "log_reader: WRONG: {child} did not stop")
Wrong_Child_Not_Stopped :: struct {
	child: value_kinds.Module_Name_Field,
}

// A child stopped itself, with another outcome than Done.
@(log_fact = "log_reader: WRONG: {child} stopped: {cause}, {outcome}")
Wrong_Child_Stopped :: struct {
	cause:   op.Stop_Cause,
	outcome: op.Stop_Outcome,
	child:   value_kinds.Module_Name_Field,
}

// A child stopped for another cause than itself.
@(log_fact = "log_reader: WRONG: {child} stopped: {cause}")
Wrong_Child_Stopped_Without_Outcome :: struct {
	cause: op.Stop_Cause,
	child: value_kinds.Module_Name_Field,
}

// The two children did not give their log records back.
@(log_fact = "log_reader: WRONG: after the stop of the two children, this process holds {held_log_records} log records of each second, and not {whole_log_records}")
Wrong_Children_Records_Held :: struct {
	held_log_records:  u64,
	whole_log_records: u64,
}

// The storm child did not take its log records from the budget of this
// process.
@(log_fact = "log_reader: WRONG: while the storm child runs, this process holds {kept_log_records} log records of each second of its {whole_log_records}")
Wrong_Storm_Records_Kept :: struct {
	kept_log_records:  u64,
	whole_log_records: u64,
}

// The storm child did not give its log records back.
@(log_fact = "log_reader: WRONG: after the stop of the storm child, this process holds {held_log_records} log records of each second, and not {whole_log_records}")
Wrong_Storm_Records_Held :: struct {
	held_log_records:  u64,
	whole_log_records: u64,
}

// The records of a child hold rows of another process.
@(log_fact = "log_reader: WRONG: the records of {child}: {other_rows} rows of another process")
Wrong_Child_Other_Rows :: struct {
	other_rows: u64,
	child:      value_kinds.Module_Name_Field,
}

// The records of a child are not its one record.
@(log_fact = "log_reader: WRONG: the records of {child}: {rows} rows; one row, its record with the number 0 and lost 0, was the answer")
Wrong_Child_Rows :: struct {
	rows:  u64,
	child: value_kinds.Module_Name_Field,
}

// The value runs of a child are not the run of its value.
@(log_fact = "log_reader: WRONG: the value runs of {child}: {runs} rows; one row, the run of its value, was the answer")
Wrong_Child_Runs :: struct {
	runs:  u64,
	child: value_kinds.Module_Name_Field,
}

// The records of a child: its one record.
@(log_fact = "log_reader: the records of {child}: {rows} rows from the own number 0, its one record, lost 0: no row of this process, of the other child or of an earlier run: as it must")
Child_Records_Read :: struct {
	rows:  u64,
	child: value_kinds.Module_Name_Field,
}

// The value runs of a child: the run of its value.
@(log_fact = "log_reader: the value runs of {child}: {runs} rows, the run of its value {child_value}: as it must")
Child_Value_Runs_Read :: struct {
	runs:        u64,
	child_value: u64,
	child:       value_kinds.Module_Name_Field,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
// The bytes of the Text field of the reason of a failure: the longest,
// "the log service gave a row before the first record of this process, or
// of an earlier run", has 88 bytes, and a zero byte.
PROBLEM_FIELD_BYTES :: 96

// Log of the form Fact refused each wrong fact, and changed nothing.
@(log_fact = "log_reader: Log refused {refusals} wrong facts, each with its status and its error record: the form word, a run, the length below the head and past the whole fact, an address that the process cannot read, and the level; the own log ring kept the same {own_records} records, and the budget the same log records and the same refused count: as it must")
Refused_Facts_Checked :: struct {
	refusals:    u64,
	own_records: u64,
}

// The refused facts changed the log records of the budget or its refused
// count.
@(log_fact = "log_reader: WRONG: the facts changed the log records of the budget or its refused count")
Wrong_Facts_Changed_Budget :: struct {}

// A fact read back does not hold what the kernel must write. The form is
// its word type: the enum of 1 byte among fields of 8 would pad the
// record.
@(log_fact = "log_reader: WRONG: the fact {index} has the form {form}, more {continues}, the part {part} of {part_count}, the key {key}, {value_count} value bytes, the first {first_values} and the last {last_value}")
Wrong_Fact_Row :: struct {
	index:        u64,
	form:         op.Log_Record_Form_Word,
	continues:    i64,
	part:         u64,
	part_count:   u64,
	key:          value_kinds.Hexadecimal_Sixteen_Digits,
	value_count:  i64,
	first_values: value_kinds.Hexadecimal_Sixteen_Digits,
	last_value:   u64,
}

// Log refused each wrong call, and changed nothing.
@(log_fact = "log_reader: Log refused {refusals} wrong calls, each with its status and its error record: the level word, the runs and the length past their bounds, an address that the process cannot read, and a text or its runs past the end of what it can read; the own log ring kept the same {own_records} records, and the budget the same log records and the same refused count: as it must")
Refused_Calls_Checked :: struct {
	refusals:    u64,
	own_records: u64,
}

// The call with the process handle of the log service was not refused.
@(log_fact = "log_reader: WRONG: the call of log.process_records with the process handle of the log service gave the status {status}")
Wrong_Service_Handle_Call :: struct {
	status:      call_status.Call_Status_Word,
}

// The process handle of the log service, which has no Give, is not lent.
@(log_fact = "log_reader: the process handle of the log service from connect, with Read and no Give: the lend failed with No_Right, and it reads no record of the service: as it must")
Service_Handle_Not_Lent :: struct {}

// The call of log.process_records for a child did not come back.
@(log_fact = "log_reader: WRONG: the call of log.process_records for {child} gave the status {status}")
Wrong_Child_Records_Call :: struct {
	status:      call_status.Call_Status_Word,
	child:       value_kinds.Module_Name_Field,
}

// The call of log.process_value_runs for a child did not come back.
@(log_fact = "log_reader: WRONG: the call of log.process_value_runs for {child} gave the status {status}")
Wrong_Child_Runs_Call :: struct {
	status:      call_status.Call_Status_Word,
	child:       value_kinds.Module_Name_Field,
}

// The log service did not refuse a memory object in place of a process
// handle with the kind Handle_Kind.
@(log_fact = "log_reader: WRONG: a memory object in place of a process handle gave the status {status}, the kind {kind}, the argument {argument} and the found kind {found_kind}")
Wrong_Memory_Lent :: struct {
	status:      call_status.Call_Status_Word,
	kind:        errors.Kind_Word,
	argument:    i64,
	found_kind:  op.Object_Kind_Word,
}

// The log service refused a memory object in place of a process handle.
@(log_fact = "log_reader: a memory object in place of a process handle: the log service refused it with Handle_Kind: as it must")
Memory_Lent_Refused :: struct {}

// A check failed: the reason, one of the sentences of the checks.
@(log_fact = "log_reader: WRONG: {problem}")
Wrong_Check :: struct {
	problem: [96]u8,
}

// Two facts of several records, given to Log and read back whole.
@(log_fact = "log_reader: a fact of {short_bytes} value bytes in {short_records} records and a fact of {long_bytes} value bytes in {long_records} records, at the bound of a call, read back: each record with its part, the count of its parts and its value bytes, joined whole into the bytes given: as it must")
Long_Facts_Read_Back :: struct {
	short_bytes:   u64,
	short_records: u64,
	long_bytes:    u64,
	long_records:  u64,
}

// The log limit of a child refused each fact of more records than it had
// left, whole.
@(log_fact = "log_reader: a child whose log limit holds {log_limit} records: a fact of {most_records} records and one of {past_limit_records} were refused whole, each record counted as refused; a fact of as many records as its limit was taken, and one of 3 records after one of 2 in the same budget was refused; its records hold whole facts only: as it must")
Fact_Budget_Checked :: struct {
	log_limit:          u64,
	most_records:       u64,
	past_limit_records: u64,
}

// Each check passed.
@(log_fact = "log_reader: ok")
Checked :: struct {}

#assert(size_of(Wrong_Check) == PROBLEM_FIELD_BYTES)
#assert(size_of(Wrong_Fact_Refusal) == 3 * size_of(i64) + size_of(op.Status) + REFUSAL_NAME_FIELD_BYTES)
#assert(size_of(Wrong_Text_Refusal) == size_of(Wrong_Fact_Refusal))
#assert(size_of(Wrong_Edge_Refused) == size_of(op.Status) + EDGE_NAME_FIELD_BYTES)

// refusal_name_field gives the Text field of the name of a refused call.
refusal_name_field :: proc "contextless" (name: string) -> [REFUSAL_NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, REFUSAL_NAME_FIELD_BYTES)
}

// call_status_word gives the word of the status of a call, for a field
// of a fact.
call_status_word :: proc "contextless" (status: call_status.Call_Status) -> call_status.Call_Status_Word {
	return call_status.Call_Status_Word(status)
}

// problem_field gives the Text field of the reason of a failure.
problem_field :: proc "contextless" (problem: string) -> [PROBLEM_FIELD_BYTES]u8 {
	return value_kinds.text_field(problem, PROBLEM_FIELD_BYTES)
}

// edge_name_field gives the Text field of the name of an edge that Log
// takes.
edge_name_field :: proc "contextless" (name: string) -> [EDGE_NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, EDGE_NAME_FIELD_BYTES)
}
