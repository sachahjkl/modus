package output_counter

// The log facts of the test module output_counter (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before. A text view is the last field. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// The writer runs, and waits for its first reader.
@(log_fact = "output_counter: it writes one record of counts each {interval_milliseconds} ms while a reader is wired, and waits for a reader")
Running :: struct {
	interval_milliseconds: u64,
}

// The last reader of counts left: the writer waits for the next one.
@(log_fact = "output_counter: counts has no reader after {records} records: it waits for one")
Reader_Left :: struct {
	records: u64,
}
