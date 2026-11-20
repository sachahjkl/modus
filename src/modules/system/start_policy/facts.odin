package start_policy

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the start policy (src/md/features/log_facts.md): the
// start list that it reads, the rows that it does not start, the stops of
// its rows and their restarts, and the completions that it refuses, as
// records of fields. Each fact template is the sentence that the line
// wrote before it was a fact, so a wait of a machine test on that sentence
// reads it as before. A line whose sentence differs by its case is one
// fact type for each case: the template has no condition. No field has
// the name of a column of the head of facts(): number, time, process,
// level.
//
// The stop of a row has the fields of the stop of the root service: its
// cause, and its outcome when it stopped itself, so where(outcome = Done)
// reads both. The process of a row is the Text field row_process. A Text
// field is the last field, and is [N]u8 with N written out, as the tool
// reads it.

// The bytes of the Text field of the fault of a start list: the longest,
// "a row has a mark that is neither needed nor not needed", has 54 bytes,
// and a zero byte.
LIST_PROBLEM_FIELD_BYTES :: 56
// The bytes of the Text field of a part of the machine: the longest,
// "disk of the measures", has 20 bytes.
PART_FIELD_BYTES :: 24

// The start list is refused, at one of its rows.
@(log_fact = "start_policy: the start list is refused: {list_problem}, at its row {row}: no row starts")
Start_List_Refused :: struct {
	row:          u64,
	list_problem: [56]u8,
}

// The start list, read whole.
@(log_fact = "start_policy: the start list has {rows} rows: each starts in its order")
Start_List_Read :: struct {
	rows: u64,
}

// A row is not started: the machine lacks a part that it needs.
@(log_fact = "start_policy: {row_process} is not started: the machine has no {missing_part}")
Row_Not_Started :: struct {
	row_process:  value_kinds.Module_Name_Field,
	missing_part: [24]u8,
}

// A row that the machine needs did not start.
@(log_fact = "start_policy: the machine is not usable without {row_process}: the start policy stops before Machine_Usable")
Machine_Not_Usable_Without :: struct {
	row_process: value_kinds.Module_Name_Field,
}

// A row stopped itself with an outcome that no restart follows.
@(log_fact = "start_policy: {row_process} stopped: {cause}, {outcome}; it does not start again")
Row_Stopped_Not_Restarted :: struct {
	cause:       op.Stop_Cause,
	outcome:     op.Stop_Outcome,
	row_process: value_kinds.Module_Name_Field,
}

// A row stopped for another cause than itself, with an outcome that no
// restart follows.
@(log_fact = "start_policy: {row_process} stopped: {cause}; it does not start again")
Row_Stopped_Not_Restarted_Without_Outcome :: struct {
	cause:       op.Stop_Cause,
	row_process: value_kinds.Module_Name_Field,
}

// A row stopped itself past its restarts.
@(log_fact = "start_policy: {row_process} stopped: {cause}, {outcome}; past its {restarts} restarts, it stays stopped")
Row_Stopped_Past_Restarts :: struct {
	restarts:    u32,
	cause:       op.Stop_Cause,
	outcome:     op.Stop_Outcome,
	row_process: value_kinds.Module_Name_Field,
}

// A row stopped for another cause than itself, past its restarts.
@(log_fact = "start_policy: {row_process} stopped: {cause}; past its {restarts} restarts, it stays stopped")
Row_Stopped_Past_Restarts_Without_Outcome :: struct {
	restarts:    u32,
	cause:       op.Stop_Cause,
	row_process: value_kinds.Module_Name_Field,
}

// A row stopped itself, and starts again.
@(log_fact = "start_policy: {row_process} stopped: {cause}, {outcome}; it starts again, {restarts_left} restarts left")
Row_Restarted :: struct {
	restarts_left: u32,
	cause:         op.Stop_Cause,
	outcome:       op.Stop_Outcome,
	row_process:   value_kinds.Module_Name_Field,
}

// A row stopped for another cause than itself, and starts again.
@(log_fact = "start_policy: {row_process} stopped: {cause}; it starts again, {restarts_left} restarts left")
Row_Restarted_Without_Outcome :: struct {
	restarts_left: u32,
	cause:         op.Stop_Cause,
	row_process:   value_kinds.Module_Name_Field,
}

// A completion of the root service whose tag names no command in flight.
@(log_fact = "start_policy: refused a completion of the tag {tag}, which names no command in flight")
Completion_Tag_Refused :: struct {
	tag: u64,
}

// A completion of the root service whose status word names no status: the
// word keeps its number, as the line wrote it.
@(log_fact = "start_policy: refused a completion whose status word {status_word} names no status")
Completion_Status_Refused :: struct {
	status_word: u64,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Start_List_Refused) == 8 + LIST_PROBLEM_FIELD_BYTES)
#assert(size_of(Row_Not_Started) == value_kinds.MODULE_NAME_FIELD_BYTES + PART_FIELD_BYTES)
