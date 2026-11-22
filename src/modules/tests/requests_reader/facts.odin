package requests_reader

import "modus:contract/value_kinds"

// The log facts of the test module requests_reader (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "requests_reader: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The bytes of a Text field of the name of an end word: the longest,
// "Writer_Stopped", has 14 bytes, and a zero byte.
END_WORD_FIELD_BYTES :: 16

// A read of a record input gave another status than Ok.
@(log_fact = "requests_reader: WRONG: {stream}: the read of the serial {serial} gave the status word {status_word}")
Wrong_Read_Status :: struct {
	serial:      u64,
	status_word: u64,
	stream:      value_kinds.Text_View,
}

// A read of a record input gave another kind or another serial.
@(log_fact = "requests_reader: WRONG: {stream}: wanted the kind word {wanted_kind_word} and the serial {wanted_serial}, read the kind word {kind_word} and the serial {serial}")
Wrong_Read_Record :: struct {
	wanted_kind_word: u64,
	wanted_serial:    u64,
	kind_word:        u64,
	serial:           u64,
	stream:           value_kinds.Text_View,
}

// The ring of held was not full with the server waiting on it.
@(log_fact = "requests_reader: WRONG: the ring of held was not full with the server waiting on it, in the phase {phase}; the end word {end_word}")
Wrong_Held_Not_Full :: struct {
	phase:    u64,
	end_word: u64,
}

// No end came within the hang bound after the last request.
@(log_fact = "requests_reader: WRONG: {stream}: after the last request, the status word {status_word} (No_Record: no end within the hang bound) and the end word {end_word}")
Wrong_End_Not_Read :: struct {
	status_word: u64,
	end_word:    [16]u8,
	stream:      value_kinds.Text_View,
}

// The end after the last request is not Writer_Stopped.
@(log_fact = "requests_reader: WRONG: {stream}: after the last request, the status word {status_word} and the end word {end_word}")
Wrong_End :: struct {
	status_word: u64,
	end_word:    [16]u8,
	stream:      value_kinds.Text_View,
}

// The first phase of the test is read.
@(log_fact = "requests_reader: phase 1 read")
Phase_One_Read :: struct {}

// The second phase of the test is read.
@(log_fact = "requests_reader: phase 2 read")
Phase_Two_Read :: struct {}

// The counts that the server published in the ring of held are not the
// counts of the test.
@(log_fact = "requests_reader: WRONG: the counts of the server in the ring of held: written {written}, discarded {discarded}, refused {refused}, held {held}, past their gap {rings_past_gap}; wanted {wanted_written}, 0, 0, {wanted_held} and 0")
Wrong_Counts :: struct {
	written:        u64,
	discarded:      u64,
	refused:        u64,
	held:           u64,
	rings_past_gap: u64,
	wanted_written: u64,
	wanted_held:    u64,
}

// The reader of the pace Always_Holds_Writer read each record, and held
// the server twice.
@(log_fact = "requests_reader: held, of the pace Always_Holds_Writer: the joined record of 0 and the {records} records in order, no gap, with a ring of {ring_capacity} that held the server twice: as it must")
Held_Read :: struct {
	records:       u64,
	ring_capacity: u64,
}

// The reader of the pace Never_Holds_Writer read one gap record in place
// of the records that its ring refused.
@(log_fact = "requests_reader: gapped, of the pace Never_Holds_Writer: the joined record of 0, {records} records, and one gap record of exactly {gap_records} records from the serial {gap_serial}, which the records around it meet: as it must")
Gapped_Read :: struct {
	records:     u64,
	gap_records: u64,
	gap_serial:  u64,
}
