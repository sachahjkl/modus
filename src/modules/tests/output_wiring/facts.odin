package output_wiring

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the test module output_wiring
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before; a
// status that the line wrote as its number is now the name of its member.
// A text view is the last field. No field has the name of a column of the
// head of facts(): number, time, process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_wiring: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A command of the root ring was refused: what the test asked, the status
// word, and the seven words of the error record of the completion, since
// several limits of the root service give one status.
@(log_fact = "output_wiring: WRONG: {what} {status}; the error record: {error_kind} {error_unit} {error_operation} {error_argument} {error_value} {error_limit} {error_found}")
Wrong_Refused :: struct {
	status:          u64,
	error_kind:      u64,
	error_unit:      u64,
	error_operation: u64,
	error_argument:  u64,
	error_value:     u64,
	error_limit:     u64,
	error_found:     u64,
	what:            value_kinds.Text_View,
}

// A refusal of the test came with another outcome or error record than
// the one that it waits for: the outcome and the record that came.
@(log_fact = "output_wiring: WRONG: {what}: the outcome {outcome}, the kind {kind}, the unit {unit}, the operation {operation}, the argument {argument}, the value {value}, the limit {limit}, the found {found}")
Wrong_Refusal :: struct {
	outcome:   call_outcome.Call_Outcome_Word,
	kind:      i64,
	unit:      i64,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	what:      value_kinds.Text_View,
}

// The outcome and the error record that the refusal of Wrong_Refusal waited
// for.
@(log_fact = "output_wiring: WRONG: {what}: wanted the outcome {outcome}, the kind {kind}, the unit {unit}, the operation {operation}, the argument {argument}, the value {value}, the limit {limit}, the found {found}")
Wrong_Refusal_Wanted :: struct {
	outcome:   call_outcome.Call_Outcome_Word,
	kind:      i64,
	unit:      i64,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	what:      value_kinds.Text_View,
}

// A refusal changed the pages of the budget of this process.
@(log_fact = "output_wiring: WRONG: {what}: the budget held {pages_before} pages before and {pages_after} after")
Wrong_Budget :: struct {
	pages_before: u64,
	pages_after:  u64,
	what:         value_kinds.Text_View,
}

// The budget did not come back to the pages of the start of a case within
// the hang bound.
@(log_fact = "output_wiring: WRONG: after {case_name}, the budget held {pages_held} pages within the hang bound, and {pages_wanted} at its start")
Wrong_Budget_Not_Settled :: struct {
	pages_held:   u64,
	pages_wanted: u64,
	case_name:    value_kinds.Text_View,
}

// The refusals of Wire before its list page, and the list page.
@(log_fact = "output_wiring: Wire before its list page, with a step that names nothing and with a reserved word, and the list page past the budget: refused, each with its status and its error record, the budget unchanged; then the list page, its handle revoked, unmapped and closed, and a new handle of it: as it must")
List_Page_Checked :: struct {}

// The lent handles that lists of no row gave back.
@(log_fact = "output_wiring: {lent_handles} lent handles given back with lists of no row, each list refused with its status and its error record and the budget unchanged: as it must")
Lent_Handles_Given_Back :: struct {
	lent_handles: u64,
}

// The refusals of a wiring, and the Wire of the second reader.
@(log_fact = "output_wiring: the refusals of a wiring, each with its status and its error record and the budget unchanged, {lent_handles} lent memory handles among them, {conditions} conditions that the root service refuses at its border, and the Wire of the second reader: as it must")
Wiring_Refusals_Checked :: struct {
	lent_handles: u64,
	conditions:   u64,
}

// The refusals of Start and of its list.
@(log_fact = "output_wiring: the refusals of Start and of its list, each with its status and its error record and the budget unchanged: as it must")
Start_Refusals_Checked :: struct {}

// The ends of a writer that stopped and of a reader that stopped.
@(log_fact = "output_wiring: the writer that stopped and the reader that stopped: as it must")
Stopped_Ends_Checked :: struct {}

// A text record of the log of log_flood is not the one that it wrote: its
// serial, its form, level, more and runs, its text and the text wanted.
@(log_fact = "output_wiring: WRONG: the log of log_flood: the record {record_serial} has the form {form_word}, the level {level_word}, more {more}, the runs {runs} and the text \"{text}\"; wanted \"{wanted_text}\"")
Wrong_Log_Text :: struct {
	record_serial: u64,
	form_word:     u64,
	level_word:    u64,
	more:          u64,
	runs:          u64,
	text:          value_kinds.Text_View,
	wanted_text:   value_kinds.Text_View,
}

// A record of the log of log_flood is not the next one.
@(log_fact = "output_wiring: WRONG: the log of log_flood: the record {record_serial} came as the status word {status_word}, the kind word {kind_word} and the serial {serial}")
Wrong_Log_Record :: struct {
	record_serial: u64,
	status_word:   u64,
	kind_word:     u64,
	serial:        u64,
}

// The record of the fact of log_flood is not the fact that it wrote.
@(log_fact = "output_wiring: WRONG: the log of log_flood: the record {record_serial} is not the fact Flood_Fact: the form {form_word}, the level {level_word}, the part {part} of {part_count}, the values {value_count}")
Wrong_Flood_Fact :: struct {
	record_serial: u64,
	form_word:     u64,
	level_word:    u64,
	part:          u64,
	part_count:    u64,
	value_count:   u64,
}

// The ring of the log of log_flood was not full with log_flood waiting.
@(log_fact = "output_wiring: WRONG: the ring of the log of log_flood was not full with log_flood waiting on it: the end {end_word}, {held_compartments} compartments of {capacity}")
Wrong_Log_Ring_Not_Full :: struct {
	end_word:          u64,
	held_compartments: u64,
	capacity:          u64,
}

// log_flood did not stop itself with Done after the end of its reader.
@(log_fact = "output_wiring: WRONG: log_flood, held by its log, stopped after the end of its reader with the cause {stop_cause_word} and the outcome {stop_outcome_word}; wanted itself and Done")
Wrong_Flood_Stop :: struct {
	stop_cause_word:   u64,
	stop_outcome_word: u64,
}

// The wired log of log_flood kept each of its records while the kernel log
// refused each call.
@(log_fact = "output_wiring: the log of log_flood kept its {records} records in order while the kernel refused its {calls} calls; then this asker closed its end, and log_flood, which its log held, stopped with Done: as it must")
Flood_Log_Kept :: struct {
	records: u64,
	calls:   u64,
}

// The wirings of an asker with no count, past 8, 9 and 20, until its
// budget pays no more; the next refused, and the revocation of the grant
// wirings.
@(log_fact = "output_wiring: {wirings} wirings of one asker, past 8, 9 and 20, until its budget paid no more; one more refused with Wire and with a Start, each with the budget unchanged, then the revocation of the grant wirings: as it must")
Asker_Limit_Checked :: struct {
	wirings: u64,
}

// The ends that a side refused and closed, and the wiring ring that it
// does not read.
@(log_fact = "output_wiring: the end that a side refused ended with Refused, the wiring that a side closed gave its probe then Side_Closed, and {ends} ends filled the wiring ring that it does not read, then one more refused with Busy, its status and its error record and the budget unchanged: as it must")
Side_Checked :: struct {
	ends: u64,
}

// The wiring of this asker gave the joined record and the first probe.
@(log_fact = "output_wiring: the wiring of this asker gave the joined record of 0 and the probe 0, after {refusals} refusals; this asker stops: as it must")
Asker_Wiring_Checked :: struct {
	refusals: u64,
}

// Each case of the test passed.
@(log_fact = "output_wiring: ok")
Checked :: struct {}
