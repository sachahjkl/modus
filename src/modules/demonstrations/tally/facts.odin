package tally

// The log facts of tally (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before.

// The window is open and counts.
@(log_fact = "tally: ok")
Running :: struct {}
