package debug_target

// The log fact of the target of the debugger (src/md/features/log_facts.md):
// its one line with a value. The fact template is the sentence that the
// line wrote before it was a fact. It is in a file of its own: the machine
// test of the debugger names lines of main.odin, which must not move.

// Rounds of the main thread gave a wrong total.
@(log_fact = "debug_target: 64 more rounds ran, and {wrong_totals} rounds gave a wrong total: WRONG")
Wrong_Totals :: struct {
	wrong_totals: u64,
}
