package output_reader

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the test module output_reader (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_reader: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The bytes of a Text field of the name of an end word: the longest,
// "Writer_Stopped", has 14 bytes, and a zero byte.
END_WORD_FIELD_BYTES :: 16

// The watched case: the reader read the joined record and one probe, and
// stops.
@(log_fact = "output_reader: watched: the joined record and one probe, then this reader stops: as it must")
Watched_Read :: struct {}

// The probes case: the reader joined, then read each probe in order, and a
// clean end.
@(log_fact = "output_reader: probes: joined after {joined_serial} records, the probes {first_probe} to {last_probe} in order, and a clean end: as it must")
Probes_Read :: struct {
	joined_serial: u64,
	first_probe:   u64,
	last_probe:    u64,
}

// The unended case: the end words carry the stop that the kernel recorded.
// A stop cause and a stop outcome write the words of a reader.
@(log_fact = "output_reader: unended: the joined record of 0, one probe, then the end word {end_word} with the stop {stop_cause}, {stop_outcome}: as it must")
Unended_Read :: struct {
	stop_cause:   op.Stop_Cause_Word,
	stop_outcome: op.Stop_Outcome_Word,
	end_word:     [16]u8,
}
