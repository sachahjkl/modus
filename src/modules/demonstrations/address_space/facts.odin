package address_space

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the demonstration address_space
// (src/md/features/log_facts.md, "The facts of the demonstrations"): its
// cases and its measures, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a machine
// test on that sentence reads it as before. No field has the name of a
// column of the head of facts(): number, time, process, level.
//
// A word that says whether a case held ("right", "WRONG", "as it must") is
// a Text field of a closed set of words, so one fact type keeps each case.
// A Text field comes last, and holds its longest text and a zero byte.

// An edge case of the address space, and whether it held.
@(log_fact = "address_space: edge case: {case_name}: {verdict}")
Edge_Case :: struct {
	verdict:   [16]u8,
	case_name: [104]u8,
}

// The revocation of a mapping of 1 GiB while a thread of the child waits on
// a word of it.
@(log_fact = "address_space: a revocation of a mapping of 1 GiB with a thread that waits on a word of it: {revocation}; the waiter {waiter}")
Revocation_Of_Large_Mapping :: struct {
	revocation: value_kinds.Time_In_Microseconds,
	waiter:     [16]u8,
}

// The end of an uncommitted object of 1 GiB with 4 frames.
@(log_fact = "address_space: an Uncommitted object of 1 GiB with 4 frames: unmap and close in {unmap_and_close}; pages kept: {pages_kept}")
Large_Object_Ended :: struct {
	unmap_and_close: value_kinds.Time_In_Microseconds,
	pages_kept:      u64,
}

// The child that holds its own process handle could not map its board.
@(log_fact = "address_space: the child of its own handle could not map its board: {map_status}")
Own_Handle_Child_Board_Not_Mapped :: struct {
	map_status: op.Status,
}

// The child that holds its own process handle stopped itself: its stop
// cause is Itself, with its outcome.
@(log_fact = "address_space: a child stopped through its own process handle: the give gave {give_status}, the stop through the handle {stop_verdict}, and the child stopped: {cause}, {outcome}")
Own_Handle_Child_Stopped :: struct {
	give_status:  op.Status,
	cause:        op.Stop_Cause,
	outcome:      op.Stop_Outcome,
	stop_verdict: [36]u8,
}

// The child that holds its own process handle stopped for another cause
// than itself: it chose no outcome.
@(log_fact = "address_space: a child stopped through its own process handle: the give gave {give_status}, the stop through the handle {stop_verdict}, and the child stopped: {cause}")
Own_Handle_Child_Stopped_Without_Outcome :: struct {
	give_status:  op.Status,
	cause:        op.Stop_Cause,
	stop_verdict: [32]u8,
}

// The kernel answered a Process_Stop that it must refuse with another
// status or another error record than Bad_Value of the argument 2.
@(log_fact = "address_space: WRONG: Process_Stop of {target} with the word {stop_word} gave the status word {status_word}, the error kind {error_kind}, the argument {argument} and the limit {limit}")
Stop_Word_Not_Refused :: struct {
	stop_word:   u64,
	status_word: u64,
	error_kind:  i64,
	argument:    i64,
	limit:       i64,
	target:      [16]u8,
}

// A case of the page tables of a mapping of one page at its own entry of
// three levels.
@(log_fact = "address_space: page tables: {mappings} mappings of one page, each at its own entry of three levels: {least_paid} to {most_paid} pages of tables while mapped, {pages_kept} pages kept after the unmap: {verdict}")
Page_Tables_Of_Spread_Mappings :: struct {
	mappings:   u64,
	least_paid: u64,
	most_paid:  u64,
	pages_kept: u64,
	verdict:    [16]u8,
}

// A case of the page tables of a reservation with a commit and a decommit.
@(log_fact = "address_space: page tables: a reservation of {reservation_pages} pages: {table_pages} pages of tables, {budget_after_decommit} after a commit and a decommit of 16 pages, {pages_kept} pages kept after the unmap: {verdict}")
Page_Tables_Of_Reservation :: struct {
	reservation_pages:     u64,
	table_pages:           u64,
	pages_kept:            u64,
	budget_after_decommit: [16]u8,
	verdict:               [16]u8,
}

// A case of the page tables above a large page.
@(log_fact = "address_space: page tables: a large page: {table_pages} pages of tables above it while mapped, {pages_kept} pages kept after the unmap: {verdict}")
Page_Tables_Of_Large_Page :: struct {
	table_pages: u64,
	pages_kept:  u64,
	verdict:     [16]u8,
}

// The other thread of the case of the neighbour page wrote and read its
// page.
@(log_fact = "address_space: page tables: the other thread wrote and read its page {touches} times during the rounds")
Neighbour_Touches :: struct {
	touches: u64,
}

// A case of the page tables beside a page that another thread writes and
// reads.
@(log_fact = "address_space: page tables: {rounds} rounds of a map and an unmap beside a page that another thread writes and reads: {rounds_right} rounds right, the page of the other thread {neighbour_page}, {pages_kept} pages kept: {verdict}")
Page_Tables_Beside_Neighbour :: struct {
	rounds:         u64,
	rounds_right:   u64,
	pages_kept:     u64,
	neighbour_page: [16]u8,
	verdict:        [16]u8,
}

// The measure of the sparse table and of its decommit.
@(log_fact = "address_space: sparse table: {pages_committed} pages committed of {object_pages}, {pages_present} with a frame; decommit: {pages_returned} pages back in the budget at once, in {decommit_time}; a page committed again is zero: {committed_again_zero}")
Sparse_Table_Measured :: struct {
	pages_committed:      u64,
	object_pages:         u64,
	pages_present:        u64,
	pages_returned:       u64,
	decommit_time:        value_kinds.Time_In_Microseconds,
	committed_again_zero: u64,
}

// The reuse of addresses: one object mapped and unmapped many times.
@(log_fact = "address_space: addresses: one object mapped and unmapped 100000 times: the budget holds {pages_after_last} pages after, {pages_after_first} after the first time")
Addresses_Reused :: struct {
	pages_after_last:  u64,
	pages_after_first: u64,
}

// The demonstration found a fault: the first one.
@(log_fact = "address_space: wrong: {problem}")
Demonstration_Wrong :: struct {
	problem: [96]u8,
}
