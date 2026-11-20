package shortage

import "modus:contract/value_kinds"

// The log facts of the test of the shortage of frames
// (src/md/features/log_facts.md): the lines with a value, as records of
// fields. Each fact template is the sentence that the line wrote before it
// was a fact, so a wait of a machine test on that sentence reads it as
// before. The line of the full machine stays text: it writes a status as
// its number, and a field of a status writes the name of its member. No
// field has the name of a column of the head of facts(): number, time,
// process, level.

// The start: the free pages that budgets can pay, the pages of the budget
// of this process, and the processors.
@(log_fact = "shortage: start: {payable_pages} free pages that budgets can pay, {own_pages} of them in the budget of this process, {processors} processors")
Started :: struct {
	payable_pages: u64,
	own_pages:     u64,
	processors:    u64,
}

// Every object closed: the time of the closes, the pages that came back
// to the budget, and the free pages that budgets can pay after and
// before.
@(log_fact = "shortage: freed in {elapsed}; the budget holds {budget_pages} pages of {own_pages} ({kept_pages} pages kept); the free pages that budgets can pay: {payable_pages_after} of {payable_pages_before}")
Freed :: struct {
	elapsed:              value_kinds.Time_In_Milliseconds,
	budget_pages:         u64,
	own_pages:            u64,
	kept_pages:           u64,
	payable_pages_after:  u64,
	payable_pages_before: u64,
}
