package store_stranger

import "modus:contract/value_kinds"

// The log facts of the test module store_stranger (src/md/features/log_facts.md).

// A check failed: what the test checked, and the value that it found.
@(log_fact = "store_stranger: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The display answered a call that it must refuse to a stranger: the
// call, its status, its result and the kind and the unit of its record.
@(log_fact = "store_stranger: WRONG: the display answered {what} of a caller that does not act for its principal with the call status {status}, the result {result}, the error kind {error_kind} and the unit {error_unit}")
Wrong_Answer :: struct {
	status:     u64,
	result:     i64,
	error_kind: i64,
	error_unit: i64,
	what:       value_kinds.Text_View,
}

// The display refused both calls: the stranger saw no grant and no list.
@(log_fact = "store_stranger: the display refused window_grants and powerbox_pick_store with No_Grant: this process sees no store of the principal, as it must")
Saw_Nothing :: struct {}
