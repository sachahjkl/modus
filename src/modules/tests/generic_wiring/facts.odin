package generic_wiring

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the test module generic_wiring (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before; a status that the line wrote as its
// number is now the name of its member. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "generic_wiring: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A command of the root ring was refused: what the test asked, the status
// word, and the seven words of the error record of the completion, since
// several limits of the root service give one status.
@(log_fact = "generic_wiring: WRONG: {what} {status}; the error record: {error_kind} {error_unit} {error_operation} {error_argument} {error_value} {error_limit} {error_found}")
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

// A refusal of the test came with another status or error record than
// the one that it waits for: the status and the record that came.
@(log_fact = "generic_wiring: WRONG: {what}: the status {status}, the kind {kind}, the unit {unit}, the operation {operation}, the argument {argument}, the value {value}, the limit {limit}, the found {found}")
Wrong_Refusal :: struct {
	status:    op.Status_Word,
	kind:      i64,
	unit:      i64,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	what:      value_kinds.Text_View,
}

// The status and the error record that the refusal of Wrong_Refusal waited
// for.
@(log_fact = "generic_wiring: WRONG: {what}: wanted the status {status}, the kind {kind}, the unit {unit}, the operation {operation}, the argument {argument}, the value {value}, the limit {limit}, the found {found}")
Wrong_Refusal_Wanted :: struct {
	status:    op.Status_Word,
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
@(log_fact = "generic_wiring: WRONG: {what}: the budget held {pages_before} pages before and {pages_after} after")
Wrong_Budget :: struct {
	pages_before: u64,
	pages_after:  u64,
	what:         value_kinds.Text_View,
}

// Each refusal of the root service, each with its status, its error record
// and the budget unchanged.
@(log_fact = "generic_wiring: a second source of another record, a generic output with no fixed type, a record of no terms into a running generic input and a condition on no field: refused, each with its status and its error record and the budget unchanged: as it must")
Refusals_Checked :: struct {}

// A record of filter.kept is not the next probe of mark 1 of its side.
@(log_fact = "generic_wiring: WRONG: filter.kept gave the status word {status_word}, the kind word {kind_word}, the serial {serial} and the probe of the side {probe_side}, number {probe_number}, mark {probe_mark}; wanted the serial {wanted_serial}")
Wrong_Kept_Record :: struct {
	status_word:   u64,
	kind_word:     u64,
	serial:        u64,
	probe_side:    u64,
	probe_number:  u64,
	probe_mark:    u64,
	wanted_serial: u64,
}

// filter.kept did not end with a clean end record after each probe.
@(log_fact = "generic_wiring: WRONG: filter.kept ended with the end word {end_word} and the error kind {error_kind} after {records} records; wanted a clean end record after {wanted_records}")
Wrong_Kept_End :: struct {
	end_word:       u64,
	error_kind:     i64,
	records:        u64,
	wanted_records: u64,
}

// The chain of the start list kept each probe of mark 1, in order.
@(log_fact = "generic_wiring: generic_source to merge to filter with mark = 1 to this asker, in one start list, after a refused Wire of Other into filter.source kept no type: the joined record of 0, the {probes} probes of mark 1 of the two sides, each side in its order, then a clean end: as it must")
Chain_Kept :: struct {
	probes: u64,
}

// filter with a condition on the field 0 did not end at once with the
// error record of that field.
@(log_fact = "generic_wiring: WRONG: filter with the field 0: the joined status word {joined_status_word}, the end status word {end_status_word}, the end word {end_word}, the error kind {error_kind}, unit {error_unit}, argument {error_argument}, value {error_value}, limit {error_limit}")
Wrong_No_Field_End :: struct {
	joined_status_word: u64,
	end_status_word:    u64,
	end_word:           u64,
	error_kind:         i64,
	error_unit:         i64,
	error_argument:     i64,
	error_value:        i64,
	error_limit:        i64,
}

// filter with a condition on the field 0 ended at once with the error
// record of that field.
@(log_fact = "generic_wiring: filter with a condition on the field 0 ended kept at once with the error record of that field: as it must")
No_Field_Ended :: struct {}

// Each case of the test passed.
@(log_fact = "generic_wiring: ok, after {refusals} refusals")
Checked :: struct {
	refusals: u64,
}
