package output_count_reader

import "modus:contract/value_kinds"

// The log facts of the test module output_count_reader (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_count_reader: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The reader joined, then read the records that its condition keeps, in
// order.
@(log_fact = "output_count_reader: joined after {joined_serial} records, then {records} records of the status 404, serials {first_serial}, {second_serial} and {third_serial}, each 3 or more past the one before: as it must")
Counts_Read :: struct {
	joined_serial: u64,
	records:       u64,
	first_serial:  u64,
	second_serial: u64,
	third_serial:  u64,
}
