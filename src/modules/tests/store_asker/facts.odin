package store_asker

import "modus:contract/value_kinds"

// The log facts of the test module store_asker (src/md/features/log_facts.md).

// A check failed: what the test checked, and the value that it found.
@(log_fact = "store_asker: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The trusted display opened its store picker for this process.
@(log_fact = "store_asker: the trusted display shows the store picker for request {request}; this process sees no store of it")
Picker_Asked :: struct {
	request: u64,
}
