package rights

// The log facts of rights (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.
//
// The wrong answer of an attempt stays text: it writes a status of the
// kernel as its number, and a field of a status writes its name.

// Each attempt gave the status that it must give.
@(log_fact = "rights: ok, {allowed} allowed, {refused} refused")
Attempts_Passed :: struct {
	allowed: u64,
	refused: u64,
}
