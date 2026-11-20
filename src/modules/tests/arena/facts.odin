package arena

// The log facts of the test of an arena (src/md/features/log_facts.md):
// the lines with a value, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. No field has the name
// of a column of the head of facts(): number, time, process, level.

// The growth of the arena until the budget refused a commit, and the
// pages that the budget held before and after.
@(log_fact = "arena: grew to {committed_pages} pages in {commits} commits, in a reservation of {reservation_pages} pages, and gave {pushes} pushes of one page; the budget held {budget_pages_before} pages before, and {budget_pages_after} after the refusal")
Arena_Grew :: struct {
	committed_pages:     u64,
	commits:             u64,
	reservation_pages:   u64,
	pushes:              u64,
	budget_pages_before: u64,
	budget_pages_after:  u64,
}

// The pushes gave no page, or pages that did not read zero.
@(log_fact = "arena: WRONG: {pushes} pushes, and {nonzero_pages} pages that did not read zero before their first write")
Wrong_Pushes :: struct {
	pushes:        u64,
	nonzero_pages: u64,
}
