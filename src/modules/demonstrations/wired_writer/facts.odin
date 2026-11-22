package wired_writer

// The log facts of the writer of the demonstration pair
// (src/md/features/log_facts.md). The fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before.

// The numbers are written to each reader, and the output is ended.
@(log_fact = "wired_writer: wrote {numbers} numbers to {readers} reader, and ended numbers")
Numbers_Written :: struct {
	numbers: u64,
	readers: u64,
}
