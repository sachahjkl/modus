package log_reader

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the lines of log_reader (src/md/features/log_facts.md):
// its checks and its refusals, as records of fields. Each fact template is
// the sentence that the line wrote before it was a fact, so a wait of the
// machine test on that sentence reads it as before. Fact_Probe and the two
// facts of the measures are in main.odin and measures.odin, beside the code
// that reads their bytes back.
//
// Some lines stay text, each for a reason of its own:
//
// - the record of this process and the record of each child: the test
//   reads their text and their value run back through the log service;
// - the line of a bad block and the line of a connection of the measures:
//   the measure compares their write as text with their write as a fact;
// - a line whose template would pass the 256 bytes of a template: the
//   refusals of Log, of its text and of its facts, and the lines of the
//   measures;
// - a line that writes a status as its number, or a number as
//   system.Hex writes it, which no field kind writes;
// - a line with no value, and the reason of a failure, a free sentence.
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
#assert(size_of(Wrong_Fact_Refusal) == 3 * size_of(i64) + size_of(op.Status) + REFUSAL_NAME_FIELD_BYTES)
#assert(size_of(Wrong_Text_Refusal) == size_of(Wrong_Fact_Refusal))
#assert(size_of(Wrong_Edge_Refused) == size_of(op.Status) + EDGE_NAME_FIELD_BYTES)

// refusal_name_field gives the Text field of the name of a refused call.
refusal_name_field :: proc "contextless" (name: string) -> [REFUSAL_NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, REFUSAL_NAME_FIELD_BYTES)
}

// edge_name_field gives the Text field of the name of an edge that Log
// takes.
edge_name_field :: proc "contextless" (name: string) -> [EDGE_NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, EDGE_NAME_FIELD_BYTES)
}
