package plan_applier

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the test module plan_applier
// (src/md/features/log_facts.md). A text view is the last field. No field
// has the name of a column of the head of facts(): number, time, process,
// level.

// A check failed: what the test checked, and the value that it found.
@(log_fact = "plan_applier: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A call to the holder of Plans failed: the call status word, and the
// fields of its error record.
@(log_fact = "plan_applier: WRONG: {what}: the call outcome {outcome}, the kind {error_kind}, the unit {error_unit}, the argument {error_argument}, the value {error_value}, the found {error_found}")
Wrong_Call :: struct {
	outcome:        call_outcome.Call_Outcome_Word,
	error_kind:     u64,
	error_unit:     u64,
	error_argument: i64,
	error_value:    i64,
	error_found:    i64,
	what:           value_kinds.Text_View,
}

// A refusal came with another result or error record than the case waits
// for.
@(log_fact = "plan_applier: WRONG: {what}: the result {result}, the call outcome {outcome}, the kind {error_kind}, the unit {error_unit}, the argument {error_argument}, the found {error_found}; wanted the kind {wanted_kind}, the unit {wanted_unit}, the argument {wanted_argument}, the found {wanted_found}")
Wrong_Refusal :: struct {
	result:          i64,
	outcome:         call_outcome.Call_Outcome_Word,
	error_kind:      i64,
	error_unit:      i64,
	error_argument:  i64,
	error_found:     i64,
	wanted_kind:     i64,
	wanted_unit:     i64,
	wanted_argument: i64,
	wanted_found:    i64,
	what:            value_kinds.Text_View,
}

// After a refusal, a generation is current, or current_generation failed.
@(log_fact = "plan_applier: WRONG: after {what}, the current generation is {generation}, the call outcome {outcome}")
Wrong_Generation :: struct {
	generation: i64,
	outcome:    call_outcome.Call_Outcome_Word,
	what:       value_kinds.Text_View,
}

// A case was refused with its error record, and generation 0 is current.
@(log_fact = "plan_applier: {what}: refused with the refusal {refusal_code}, and no generation is current: as it must")
Refused_As_It_Must :: struct {
	refusal_code: u64,
	what:         value_kinds.Text_View,
}

// plans.apply showed the difference of a plan on the trusted display.
@(log_fact = "plan_applier: the difference of the plan {plan} shows on the trusted display, ticket {ticket}")
Difference_Shown :: struct {
	ticket: u64,
	plan:   value_kinds.Text_View,
}

// The arm time of the dialog passed: a key of the principal counts now.
@(log_fact = "plan_applier: the dialog of the plan {plan} takes the decision of the principal now, ticket {ticket}")
Dialog_Armed :: struct {
	ticket: u64,
	plan:   value_kinds.Text_View,
}

// The principal accepted the plan, and the holder of Plans committed it.
@(log_fact = "plan_applier: the principal accepted the plan: generation {generation}, whose holder of the role Settings is settings_stand_in")
Plan_Accepted :: struct {
	generation: u64,
}
