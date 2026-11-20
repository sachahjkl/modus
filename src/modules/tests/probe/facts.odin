package probe

// The log fact of the library module probe (src/md/features/log_facts.md).
// The fact template is the sentence that the line wrote before it was a
// fact, so the waits of the machine test read it as before. The text of
// log_long stays text: it tests the split of a long text line.

// The call of spin runs, and never returns.
@(log_fact = "probe: spin runs, and never returns")
Spin_Runs :: struct {}
