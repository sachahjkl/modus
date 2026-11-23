package difference_hostile

import "modus:contract/value_kinds"

// The log facts of the test module difference_hostile (src/md/features/log_facts.md).

// A check failed: what the test checked, and the value that it found.
@(log_fact = "difference_hostile: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A call of the display gave another answer than the case needs.
@(log_fact = "difference_hostile: WRONG: the display answered with the status {status}, the result {result} and the error kind {error_kind}")
Wrong_Answer :: struct {
	status:     u64,
	result:     i64,
	error_kind: i64,
}

@(log_fact = "difference_hostile: the display refused an Uncommitted object with Bad_Value, kept no copy of it, and still serves: as it must")
Uncommitted_Refused :: struct {}

@(log_fact = "difference_hostile: the object of the difference {serial} is revoked while the display reads it")
Revoked_After_The_Call :: struct {
	serial: u64,
}

@(log_fact = "difference_hostile: the dialog of the revoked difference ended with the decision {decision}, and the display still serves: as it must")
Revoked_Display_Serves :: struct {
	decision: u64,
}
