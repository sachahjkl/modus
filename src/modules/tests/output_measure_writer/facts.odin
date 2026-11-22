package output_measure_writer

import "modus:contract/value_kinds"

// The log facts of the test module output_measure_writer (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_measure_writer: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The bytes of the Text field of the state of the log: the longest, "not
// wired", has 9 bytes, and a zero byte.
LOG_STATE_FIELD_BYTES :: 16

// The time of one write of a record into the ring of each reader.
@(log_fact = "output_measure_writer: {readers} readers: one write of a record of {record_bytes} bytes into the ring of each reader: least {least}, median {median} cycles, of {writes} writes")
Write_Measured :: struct {
	readers:      u64,
	record_bytes: u64,
	least:        u64,
	median:       u64,
	writes:       u64,
}

// The time of one log fact of the record, with the log not wired.
@(log_fact = "output_measure_writer: one log fact of the same record: least {least}, median {median} cycles, of {facts} facts")
Log_Fact_Measured :: struct {
	least:  u64,
	median: u64,
	facts:  u64,
}

// Measure 9: the time of one log fact, with the log wired or not.
@(log_fact = "output_measure_writer: measure 9, the log {log_state}: one log fact: least {least}, median {median} cycles, of {facts} facts")
Measure_Nine_Fact :: struct {
	least:     u64,
	median:    u64,
	facts:     u64,
	log_state: [16]u8,
}

// Measure 9: the time of one line of text with one value, with the log
// wired or not.
@(log_fact = "output_measure_writer: measure 9, the log {log_state}: one line of text with one value: least {least}, median {median} cycles, of {lines} lines")
Measure_Nine_Line :: struct {
	least:     u64,
	median:    u64,
	lines:     u64,
	log_state: [16]u8,
}
