package shortage

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the test of the shortage of frames
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before; the
// status and the error kind of the refused object, which the line wrote as
// their numbers, are now the names of their members. No field has the name
// of a column of the head of facts(): number, time, process, level.

// The full machine, when the refused object has the error kind Budget: the
// pages written, the budget, the free and the reserved pages, the drains
// of the stacks, and the refusal.
@(log_fact = "shortage: full: {pages} pages written in {objects} objects by {threads} threads in {elapsed}; the budget of this process holds {budget_pages} pages; the free pages that budgets can pay: {payable_pages} (the pages that the root service kept), and the reserved pages: {reserved_pages}; drains of the stacks: {drains}; a new memory object of 1 page: status {status}, error kind {error_kind} (Budget: the budget cannot pay)")
Full_Refused_By_Budget :: struct {
	pages:          u64,
	objects:        u64,
	threads:        u64,
	elapsed:        value_kinds.Time_In_Milliseconds,
	budget_pages:   u64,
	payable_pages:  u64,
	reserved_pages: u64,
	drains:         u64,
	status:         op.Status_Word,
	error_kind:     errors.Kind_Word,
}

// The full machine, when the refused object has another error kind.
@(log_fact = "shortage: full: {pages} pages written in {objects} objects by {threads} threads in {elapsed}; the budget of this process holds {budget_pages} pages; the free pages that budgets can pay: {payable_pages} (the pages that the root service kept), and the reserved pages: {reserved_pages}; drains of the stacks: {drains}; a new memory object of 1 page: status {status}, error kind {error_kind} (another kind)")
Full_Refused_By_Another_Kind :: struct {
	pages:          u64,
	objects:        u64,
	threads:        u64,
	elapsed:        value_kinds.Time_In_Milliseconds,
	budget_pages:   u64,
	payable_pages:  u64,
	reserved_pages: u64,
	drains:         u64,
	status:         op.Status_Word,
	error_kind:     errors.Kind_Word,
}

// Each check of the shortage passed.
@(log_fact = "shortage: ok, the stacks were drained for takes that cannot fail, a new object failed only when its budget could pay no page, and each frame returned")
Shortage_Checked :: struct {}

// A check of the shortage failed.
@(log_fact = "shortage: wrong")
Wrong :: struct {}

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
