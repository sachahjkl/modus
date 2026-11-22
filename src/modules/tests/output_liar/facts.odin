package output_liar

import "modus:contract/value_kinds"

// The log facts of the test module output_liar (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_liar: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The liar runs, and waits for a reader.
@(log_fact = "output_liar: it waits for a reader")
Waits_For_Reader :: struct {}

// The liar wrote a record that the condition of its wiring leaves out.
@(log_fact = "output_liar: wrote a record of the status 200 into a ring whose wiring has a condition: as it must")
Record_Written_Past_Condition :: struct {}
