package debug_target

import "modus:contract/call_outcome"

// The log facts of the target of the debugger (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence that
// the line wrote before it was a fact; a status that the line wrote as its
// number is now the name of its member. They are in a file of their own:
// the machine test of the debugger names lines of main.odin, which must not
// move.

// 64 more rounds ran, each with the right total.
@(log_fact = "debug_target: 64 more rounds ran, so the process is not held: as it must")
Rounds_Ran :: struct {}

// Rounds of the main thread gave a wrong total.
@(log_fact = "debug_target: 64 more rounds ran, and {wrong_totals} rounds gave a wrong total: WRONG")
Wrong_Totals :: struct {
	wrong_totals: u64,
}

// The thread that waits did not start.
@(log_fact = "debug_target: the second thread did not start: status {status}")
Thread_Not_Started :: struct {
	status: call_outcome.Call_Outcome,
}

// The process runs, with its thread that waits.
@(log_fact = "debug_target: runs, with a thread that waits")
Running :: struct {}
