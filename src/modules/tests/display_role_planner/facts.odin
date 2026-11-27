package display_role_planner

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the test module display_role_planner.

@(log_fact = "display_role_planner: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

@(log_fact = "display_role_planner: WRONG: {what}: the call outcome {outcome}, the kind {error_kind}, the unit {error_unit}, the argument {error_argument}, the value {error_value}, the found {error_found}")
Wrong_Call :: struct {
	outcome:        call_outcome.Call_Outcome_Word,
	error_kind:     u64,
	error_unit:     u64,
	error_argument: i64,
	error_value:    i64,
	error_found:    i64,
	what:           value_kinds.Text_View,
}

@(log_fact = "display_role_planner: the difference of the plan {plan} shows on the trusted display, ticket {ticket}")
Difference_Shown :: struct {
	ticket: u64,
	plan:   value_kinds.Text_View,
}

@(log_fact = "display_role_planner: the dialog of the plan {plan} takes the decision of the principal now, ticket {ticket}")
Dialog_Armed :: struct {
	ticket: u64,
	plan:   value_kinds.Text_View,
}

@(log_fact = "display_role_planner: the principal accepted the plan: generation {generation}, whose holder of the role Display is panel_display")
Plan_Accepted :: struct {
	generation: u64,
}
