package log

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the window log (src/md/features/log_facts.md, "The
// migration"): each line, as a record of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. No field has
// the name of a column of the head of facts(): number, time, process,
// level.

// The grant of the log records gives no memory that this process can read:
// the window stops. The status is the word of the kernel, which a reader
// writes by the name of its member.
@(log_fact = "log: cannot read the records of the log: status {status}")
Records_Not_Readable :: struct {
	status: call_outcome.Call_Outcome_Word,
}

// The memory of the log at the start of the window: the records that it
// holds and its size.
@(log_fact = "log: the memory of the log: {capacity} records in {memory}")
Log_Memory :: struct {
	capacity: u64,
	memory:   value_kinds.Size_In_Kibibytes,
}

// The window took the records of the log for the first time: the records
// that it keeps, those gone before its start, those lost since, and the
// processes that wrote them.
@(log_fact = "log: ok, {records} records, {gone_before_start} gone before its start, {lost} lost since, {processes} processes")
Window_Ready :: struct {
	records:           u64,
	gone_before_start: u64,
	lost:              u64,
	processes:         u64,
}
