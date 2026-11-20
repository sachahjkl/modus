package arena

import "modus:contract/errors"
import op "modus:contract/operation"

// The log facts of the test of an arena (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before; a status and an error kind that the
// line wrote as their number are now the names of their members. A status
// beside fields of 8 bytes is its word type, so the record has no padding.
// No field has the name of a column of the head of facts(): number, time,
// process, level.

// The reservation of the arena failed.
@(log_fact = "arena: WRONG: the reservation of {reservation_pages} pages failed with {status}")
Wrong_Reservation :: struct {
	reservation_pages: u64,
	status:            op.Status_Word,
}

// The growth stopped for another refusal than the budget.
@(log_fact = "arena: WRONG: the growth stopped with {status} and the error kind {error_kind}, not with No_Budget")
Wrong_Growth_Stop :: struct {
	status:     op.Status_Word,
	error_kind: errors.Kind_Word,
}

// After the refusal the budget held pages, or a second push was not refused
// with nothing changed.
@(log_fact = "arena: WRONG: after the refusal the budget held {budget_pages} pages, and a second push gave {status} or changed the arena")
Wrong_After_Refusal :: struct {
	budget_pages: u64,
	status:       op.Status_Word,
}

// After a reset the pushes did not take the same pages with no commit.
@(log_fact = "arena: WRONG: after a reset the same pushes did not take the same pages with no commit")
Wrong_Reset :: struct {}

// The end of the arena failed, or did not give each page back.
@(log_fact = "arena: WRONG: the end gave {status}, and the budget holds {budget_pages_after} pages of {budget_pages_before}")
Wrong_End :: struct {
	status:              op.Status_Word,
	budget_pages_after:  u64,
	budget_pages_before: u64,
}

// Each check of the arena passed.
@(log_fact = "arena: the budget refused the commit with No_Budget, the arena kept its state, a reset took the same pages again with no commit, and its end gave every page back to the budget: as it must")
Arena_Checked :: struct {}

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
