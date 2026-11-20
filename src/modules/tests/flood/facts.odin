package flood

// The log fact of flood (src/md/features/log_facts.md): its one line with
// a value. The fact template is the sentence that the line wrote before it
// was a fact, so the wait of the machine test reads it as before.

// The key Space paused the lines: the last line written.
@(log_fact = "flood: Space: no more lines after {last_line}")
Lines_Paused :: struct {
	last_line: u64,
}
