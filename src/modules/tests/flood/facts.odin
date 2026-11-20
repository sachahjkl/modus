package flood

// The log facts of flood (src/md/features/log_facts.md): each line, as a
// record of fields. Each fact template is the sentence that the line wrote
// before it was a fact, so the waits of the machine test read them as
// before.

// The context holds no terminal.
@(log_fact = "flood: no terminal")
No_Terminal :: struct {}

// The process runs, and writes its lines.
@(log_fact = "flood: ok")
Running :: struct {}

// The key Space paused the lines: the last line written.
@(log_fact = "flood: Space: no more lines after {last_line}")
Lines_Paused :: struct {
	last_line: u64,
}

// The key Space let the lines continue.
@(log_fact = "flood: Space: the lines continue")
Lines_Continue :: struct {}
