package requests_pace

import "modus:contract/value_kinds"

// The log facts of the test module requests_pace (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "requests_pace: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A command of the root ring was refused: what the test asked, the status
// word, and the seven words of the error record of the completion, since
// several limits of the root service give one status.
@(log_fact = "requests_pace: WRONG: {what} {status}; the error record: {error_kind} {error_unit} {error_operation} {error_argument} {error_value} {error_limit} {error_found}")
Wrong_Refused :: struct {
	status:          u64,
	error_kind:      u64,
	error_unit:      u64,
	error_operation: u64,
	error_argument:  u64,
	error_value:     u64,
	error_limit:     u64,
	error_found:     u64,
	what:            value_kinds.Text_View,
}

// The server runs with its three readers of requests.
@(log_fact = "requests_pace: server runs with three readers of requests: held of the pace Always_Holds_Writer and gapped of the pace Never_Holds_Writer, in rings of {ring_capacity}, and this process, the fast reader")
Server_Runs :: struct {
	ring_capacity: u64,
}

// A record of the fast reader is not the next one.
@(log_fact = "requests_pace: WRONG: the fast reader wanted the record {wanted_serial}, and read the status word {status_word}, the kind word {kind_word} and the serial {serial}")
Wrong_Fast_Record :: struct {
	wanted_serial: u64,
	status_word:   u64,
	kind_word:     u64,
	serial:        u64,
}

// The counts that the server published are not the counts of the test.
@(log_fact = "requests_pace: WRONG: the counts of the server: written {written}, discarded {discarded}, refused {refused}, held {held}; wanted {wanted_written}, 0, 0 and {wanted_held}")
Wrong_Counts :: struct {
	written:        u64,
	discarded:      u64,
	refused:        u64,
	held:           u64,
	wanted_written: u64,
	wanted_held:    u64,
}

// The fast reader read each record; it waits for the stop of the server.
@(log_fact = "requests_pace: the fast reader read the {records} records; it waits for the stop of server")
Fast_Reader_Read :: struct {
	records: u64,
}

// The fast reader read each record in order, and the slow reader held the
// server.
@(log_fact = "requests_pace: the fast reader: the joined record of 0 and the {records} records in order, no gap; the server was held {held} times by the slow reader of the pace Always_Holds_Writer and refused no record: as it must")
Fast_Reader_Checked :: struct {
	records: u64,
	held:    u64,
}
