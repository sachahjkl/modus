package generic_source

import "modus:contract/value_kinds"

// The log facts of the test module generic_source (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "generic_source: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The probes are written into both outputs, and both are ended.
@(log_fact = "generic_source: wrote {probes} probes into left and into right, and ended both")
Probes_Written :: struct {
	probes: u64,
}
