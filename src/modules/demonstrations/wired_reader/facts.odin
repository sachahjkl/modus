package wired_reader

import "modus:contract/value_kinds"

// The log facts of the reader of the demonstration pair
// (src/md/features/log_facts.md). Each fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. A text view is the last field.

// No writer came within the hang bound: the start policy did not start
// wired_writer, or the root service refused its wiring row.
@(log_fact = "wired_reader: no writer came within {milliseconds} ms: the start list did not start wired_writer with its wiring row")
No_Writer_Came :: struct {
	milliseconds: u64,
}

// A check failed: what the test checked, and the value that it found. The
// check is a text of the caller, so the fact carries it as a text view.
@(log_fact = "wired_reader: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// The joined record of 0, each number in order, and a clean end.
@(log_fact = "wired_reader: read the joined record of 0, the {numbers} numbers of wired_writer in order, and a clean end: the start list wired them before the first instruction of the writer")
Numbers_Read :: struct {
	numbers: u64,
}
