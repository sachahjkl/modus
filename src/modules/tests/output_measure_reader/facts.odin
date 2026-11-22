package output_measure_reader

import "modus:contract/value_kinds"

// The log facts of the test module output_measure_reader (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "output_measure_reader: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The bytes of the Text field of the name of an end word: the longest,
// "Writer_Stopped", has 14 bytes, and a zero byte.
END_WORD_FIELD_BYTES :: 16

// A record that the reader waited for came as another one.
@(log_fact = "output_measure_reader: WRONG: wanted the record {wanted_serial}, read the status word {status_word}, the kind word {kind_word} and the serial {serial}")
Wrong_Record :: struct {
	wanted_serial: u64,
	status_word:   u64,
	kind_word:     u64,
	serial:        u64,
}

// The records did not end with a clean end record.
@(log_fact = "output_measure_reader: WRONG: after {records} records, the status word {status_word} and the end word {end_word}")
Wrong_End :: struct {
	records:     u64,
	status_word: u64,
	end_word:    [16]u8,
}

// The time from a write to the read of a reader that waits, and the wakes
// of a burst.
@(log_fact = "output_measure_reader: the wake: from a write to the read of a reader that waits on another processor: least {least}, median {median} cycles, of {wake_records} records; a burst of {burst_records} records: {wakes} wakes")
Wake_Measured :: struct {
	least:         u64,
	median:        u64,
	wake_records:  u64,
	burst_records: u64,
	wakes:         u64,
}
