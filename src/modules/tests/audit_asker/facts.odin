package audit_asker

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the test module audit_asker
// (src/md/features/log_facts.md). A text view is the last field. No field
// has the name of a column of the head of facts(): number, time, process,
// level.

// A check failed: what the test checked, and the value that it found.
@(log_fact = "audit_asker: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A command of the root ring was refused: what the test asked, the status
// word, and the seven words of the error record of the completion.
@(log_fact = "audit_asker: WRONG: {what} {status}; the error record: {error_kind} {error_unit} {error_operation} {error_argument} {error_value} {error_limit} {error_found}")
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
@(log_fact = "audit_asker: WRONG: {what}: the status {status}, the kind {kind}, the unit {unit}, the operation {operation}, the argument {argument}, the value {value}, the limit {limit}, the found {found}")
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
@(log_fact = "audit_asker: WRONG: {what}: wanted the status {status}, the kind {kind}, the unit {unit}, the operation {operation}, the argument {argument}, the value {value}, the limit {limit}, the found {found}")
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

// The two lists of pairs were refused, each with its status and its error
// record, and the budget of this process did not change.
@(log_fact = "audit_asker: a pair with no source row and a second pair of one source: refused, each with its status and its error record and the budget unchanged: as it must")
Pair_Refusals_Checked :: struct {}

// The display answered plan_diff_ask of a caller that holds no role Plans
// with another answer than No_Grant.
@(log_fact = "audit_asker: WRONG: the display answered plan_diff_ask of a caller that does not hold Plans with the call status {status}, the result {result}, the kind {error_kind} and the unit {error_unit}, in place of No_Grant")
Wrong_Display_Answer :: struct {
	status:     u64,
	result:     i64,
	error_kind: i64,
	error_unit: i64,
}

// The display refused the dialog of a plan to a caller that holds no role
// Plans and does not act for its principal.
@(log_fact = "audit_asker: the display refused plan_diff_ask to a caller that does not hold the role Plans, with No_Grant: as it must")
Display_Refused_A_Stranger :: struct {}

// A compartment of the pair is not the next probe of left.
@(log_fact = "audit_asker: WRONG: the pair gave the status {status_word}, the kind {kind_word}, the serial {serial}, a probe of the side {probe_side} and the number {probe_number}, in place of the probe {wanted_number} of left")
Wrong_Forwarded_Record :: struct {
	status_word:   u64,
	kind_word:     u64,
	serial:        u64,
	probe_side:    u64,
	probe_number:  u64,
	wanted_number: u64,
}

// The pair ended with an error, or before each probe of left.
@(log_fact = "audit_asker: WRONG: the pair ended with the end word {end_word} and the error kind {error_kind} after {records} records, in place of a clean end after {wanted_records}")
Wrong_Pair_End :: struct {
	end_word:       u64,
	error_kind:     u64,
	records:        u64,
	wanted_records: u64,
}

// Each probe of left came through the pair, in its order, then the clean
// end of the source.
@(log_fact = "audit_asker: the {probes} probes of generic_source.left came through the pair of collector.forward, in their order, then the clean end of the source")
Pair_Forwarded :: struct {
	probes: u64,
}
