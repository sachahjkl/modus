package output_writer

import "modus:contract/value_kinds"

// The log facts of the test module output_writer (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_writer: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The bytes of a Text field of the name of an end word: the longest,
// "Writer_Stopped", has 14 bytes, and a zero byte.
END_WORD_FIELD_BYTES :: 16

// The bytes of the Text field of the name of a case that ends a ring: the
// longest, "watched", has 7 bytes, and a zero byte.
CASE_FIELD_BYTES :: 16

// The unended case: one probe, then the stop of the writer with no end
// record.
@(log_fact = "output_writer: unended: one probe, then the stop with no end record: as it must")
Unended_Written :: struct {}

// The probes case: each probe to two readers, a clean end, and Ended.
@(log_fact = "output_writer: probes: {probes} probes to two readers, the second one after {probes_before_second}, a clean end, and Ended after it: as it must")
Probes_Written :: struct {
	probes:               u64,
	probes_before_second: u64,
}

// A case whose ring ended with the end word that it waits for.
@(log_fact = "output_writer: {case_name}: the ring ended with the end word {end_word}: as it must")
Ring_Ended :: struct {
	case_name: [16]u8,
	end_word:  [16]u8,
}

// The large case: each ring ended with Revoked.
@(log_fact = "output_writer: large: {rings} rings, each ended with the end word Revoked: as it must")
Large_Rings_Revoked :: struct {
	rings: u64,
}
