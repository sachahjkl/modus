package memory_read_border

import "modus:contract/value_kinds"

// The log facts of the test module memory_read_border (src/md/features/log_facts.md).

@(log_fact = "memory_read_border: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

@(log_fact = "memory_read_border: WRONG: {what}: the status {status}, not {expected}")
Wrong_Status :: struct {
	status:   u64,
	expected: u64,
	what:     value_kinds.Text_View,
}

@(log_fact = "memory_read_border: each refusal of Memory_Read holds, and none wrote a byte: as it must")
Refusals_Hold :: struct {}

// A measure, with no bound: the time of one whole read under the locks.
@(log_fact = "memory_read_border: one Memory_Read of 1 MiB took {nanoseconds} ns, the kernel entry included")
Large_Read_Measured :: struct {
	nanoseconds: u64,
}
