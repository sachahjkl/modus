package output_side

import "modus:contract/value_kinds"

// The log facts of the test module output_side (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_side: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The side refused and wrote each end of its test, and reads no more
// commands.
@(log_fact = "output_side: refused the end of its start; for the end of a Wire, wrote Closed for a number of no wiring, then Taken, Taken again, one probe and Closed; it reads no more commands: as it must")
Ends_Written :: struct {}
