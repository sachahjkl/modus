package script_fonts_planner

import "modus:contract/value_kinds"

// The log facts of the test module script_fonts_planner
// (src/md/features/log_facts.md). A text view is the last field. No field
// has the name of a column of the head of facts(): number, time, process,
// level.

// A check failed: what the test checked, and the value that it found.
@(log_fact = "script_fonts_planner: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A call to the holder of Plans failed: the call status word, and the
// fields of its error record.
@(log_fact = "script_fonts_planner: WRONG: {what}: the call status {status}, the kind {error_kind}, the unit {error_unit}, the argument {error_argument}, the value {error_value}, the found {error_found}")
Wrong_Call :: struct {
	status:         u64,
	error_kind:     u64,
	error_unit:     u64,
	error_argument: i64,
	error_value:    i64,
	error_found:    i64,
	what:           value_kinds.Text_View,
}

// The set that the plan names: the font outlines of the boot image, whole
// or cut.
@(log_fact = "script_fonts_planner: names the script font set {hash}, {set_size}: {plan}")
Set_Named :: struct {
	hash:     value_kinds.Hash_Field,
	set_size: value_kinds.Size_In_Bytes,
	plan:     value_kinds.Text_View,
}

// plans.apply showed the difference of the plan on the trusted display.
@(log_fact = "script_fonts_planner: the difference of the plan {plan} shows on the trusted display, ticket {ticket}")
Difference_Shown :: struct {
	ticket: u64,
	plan:   value_kinds.Text_View,
}

// The arm time of the dialog passed: a key of the principal counts now.
@(log_fact = "script_fonts_planner: the dialog of the plan {plan} takes the decision of the principal now, ticket {ticket}")
Dialog_Armed :: struct {
	ticket: u64,
	plan:   value_kinds.Text_View,
}

// The principal accepted the plan, and the holder of Plans committed it.
@(log_fact = "script_fonts_planner: the principal accepted the plan: generation {generation}, which names the script font set {hash}")
Plan_Accepted :: struct {
	generation: u64,
	hash:       value_kinds.Hash_Field,
}
