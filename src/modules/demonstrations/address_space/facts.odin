package address_space

import "modus:contract/call_outcome"
import "modus:contract/errors"
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
	map_status: call_outcome.Call_Outcome,
}

// The child that holds its own process handle stopped itself: its stop
// cause is Itself, with its outcome.
@(log_fact = "address_space: a child stopped through its own process handle: the give gave {give_status}, the stop through the handle {stop_verdict}, and the child stopped: {cause}, {outcome}")
Own_Handle_Child_Stopped :: struct {
	give_status:  call_outcome.Call_Outcome,
	cause:        op.Stop_Cause,
	outcome:      op.Stop_Outcome,
	stop_verdict: [48]u8,
}

// The child that holds its own process handle stopped for another cause
// than itself: it chose no outcome.
@(log_fact = "address_space: a child stopped through its own process handle: the give gave {give_status}, the stop through the handle {stop_verdict}, and the child stopped: {cause}")
Own_Handle_Child_Stopped_Without_Outcome :: struct {
	give_status:  call_outcome.Call_Outcome,
	cause:        op.Stop_Cause,
	stop_verdict: [44]u8,
}

// The kernel answered a Process_Stop that it must refuse with another
// status or another error record than Bad_Value of the argument 2.
@(log_fact = "address_space: WRONG: Process_Stop of {target} with the word {stop_word} gave the status word {status_word}, the error kind {error_kind}, the argument {argument} and the limit {limit}")
Stop_Word_Not_Refused :: struct {
	stop_word:   u64,
	status_word: call_outcome.Call_Outcome_Word,
	error_kind:  errors.Kind_Word,
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

// A case of the page tables of a large page (upper tables plus parked demotion table).
@(log_fact = "address_space: page tables: a large page: {table_pages} pages of tables while mapped, {pages_kept} pages kept after the unmap: {verdict}")
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

// Each case held.
@(log_fact = "address_space: ok, the arena and the sparse table paid only what they used, the decommit gave each page back, the protection changed with its shoot-down, the guard page stopped the child, the large pages are in the report, each refusal has its error record")
Address_Space_Held :: struct {}

// The child that holds its own process handle got no handle in the hang
// bound.
@(log_fact = "address_space: the child of its own handle got no handle")
Own_Handle_Child_Without_Handle :: struct {}

// A Process_Stop that the kernel must refuse stopped the child.
@(log_fact = "address_space: WRONG: a refused Process_Stop stopped the child")
Refused_Stop_Stopped_Child :: struct {}

// The page of the other thread of the case of the neighbour page has no
// mapping.
@(log_fact = "address_space: page tables: the page of the other thread: no mapping: WRONG")
Neighbour_Page_Not_Mapped :: struct {}

// The library refused the command of a Process_Stop that the kernel must
// refuse: the status of the library, a word of 8 bytes after the word of
// the stop.
@(log_fact = "address_space: WRONG: the library refused the command of Process_Stop with the word {stop_word}: {call_status}")
Stop_Command_Refused_By_Library :: struct {
	stop_word:   u64,
	call_status: call_outcome.Call_Outcome_Word,
}

// The measure of the arena: 1 GiB of addresses in one mapping.
@(log_fact = "address_space: arena: 1 GiB of addresses in one mapping, {frame_list_pages} pages paid for its frame list, mapped in {map_time} us; pages committed and used in one second with 1, 16, 256 ranges for each kernel entry: {pages_one_range}, {pages_16_ranges}, {pages_256_ranges}; kernel entries for 1000 pages: {entries_one_range}, {entries_16_ranges}, {entries_256_ranges}")
Arena_Measured :: struct {
	frame_list_pages:   u64,
	map_time:           u64,
	pages_one_range:    u64,
	pages_16_ranges:    u64,
	pages_256_ranges:   u64,
	entries_one_range:  u64,
	entries_16_ranges:  u64,
	entries_256_ranges: u64,
}

// The measure of a change of protection with its shoot-down.
@(log_fact = "address_space: protection of 64 pages, one call with its shoot-down, the middle of 40 calls, least and most of 5 batches: {least_one_processor} to {most_one_processor} ns with 1 processor running the process, {least_two_processors} to {most_two_processors} ns with 2, {least_four_processors} to {most_four_processors} ns with 4")
Protection_Measured :: struct {
	least_one_processor:   u64,
	most_one_processor:    u64,
	least_two_processors:  u64,
	most_two_processors:   u64,
	least_four_processors: u64,
	most_four_processors:  u64,
}

// The child of the guard page stopped: its vector and the address of the
// fault, as system.Hex writes an address.
@(log_fact = "address_space: guard page: the child stopped with vector {vector} at {fault_address}, in its guard page: {in_guard_page}")
Guard_Page_Stop :: struct {
	vector:        u64,
	fault_address: value_kinds.Hexadecimal_Sixteen_Digits,
	in_guard_page: u64,
}

// The measure of one random read through large pages and through pages of
// 4 KiB of the same object, in hundredths of a nanosecond, and whether the
// report names the large pages.
@(log_fact = "address_space: large pages: one random read over 64 MiB: {large_page_read} ns through large pages of 2 MiB, {small_page_read} ns through pages of 4 KiB of the same object; the report says Large: {large_in_report}")
Large_Pages_Measured :: struct {
	large_page_read: value_kinds.Hundredths,
	small_page_read: value_kinds.Hundredths,
	large_in_report: u64,
}

// A call that the kernel must refuse, with its error record.
@(log_fact = "address_space: refused: {refusal_name}: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Refusal_Recorded :: struct {
	kind:         errors.Kind_Word,
	unit:         errors.Unit_Word,
	operation:    i64,
	argument:     i64,
	value:        i64,
	limit:        i64,
	found:        i64,
	refusal_name: [32]u8,
}

// The steps of the delegation of a child budget, each a fact type of its
// own: the words of a step are longer than a Text field holds beside the
// record. A step whose call of B the kernel refused holds the error record
// of that call; a step whose call succeeded holds a zero record, kind None.
// The verdict is "as expected" or "WRONG".

@(log_fact = "address_space: delegation: 1 B commits 32 pages, then one more: {verdict}: 32 pages committed; the 33rd: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Delegation_Commit_Past_Budget :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	verdict:   [16]u8,
}

@(log_fact = "address_space: delegation: 2 B commits with no budget handle; it reads and writes the committed pages: {verdict}: B wrote and read 55 in a committed page; a commit: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Delegation_Commit_Without_Budget :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	verdict:   [16]u8,
}

@(log_fact = "address_space: delegation: 3 B makes an object with the handle that has Commit only: {verdict}: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Delegation_Object_With_Commit_Only :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	verdict:   [16]u8,
}

@(log_fact = "address_space: delegation: 4 B commits with a budget that does not pay for the object: {verdict}: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Delegation_Commit_With_Other_Payer :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	verdict:   [16]u8,
}

@(log_fact = "address_space: delegation: 5 A revokes the budget handle of B: B commits no more: {verdict}: the 32 pages stay committed and paid (the child budget holds 0); a commit: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Delegation_Commit_After_Revocation :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	verdict:   [16]u8,
}

@(log_fact = "address_space: delegation: 7 B decommits pages of an object that A holds too: {verdict}: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Delegation_Decommit_Of_Shared_Object :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	verdict:   [16]u8,
}

@(log_fact = "address_space: delegation: 9 B gives its Commit handle on: it has no right Give: {verdict}: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Delegation_Give_Without_Right :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	verdict:   [16]u8,
}

@(log_fact = "address_space: delegation: 6 A takes the pages back: it revokes the object of B, then decommits: {verdict}: 32 pages back in the child budget; A held the object with no mapping")
Delegation_Pages_Taken_Back :: struct {
	verdict: [16]u8,
}

@(log_fact = "address_space: delegation: 6 A takes the pages back: it revokes the object of B, then decommits: {verdict}: the decommit was refused")
Delegation_Pages_Not_Taken_Back :: struct {
	verdict: [16]u8,
}

@(log_fact = "address_space: delegation: 8 the child budget ends: the object moves to the budget of A: {verdict}: a commit with the budget of A: 1 page; with the old handle: refused")
Delegation_Object_Moved :: struct {
	verdict: [16]u8,
}

@(log_fact = "address_space: delegation: 8 the child budget ends: the object moves to the budget of A: {verdict}: the commit with the budget of A was refused")
Delegation_Object_Not_Moved :: struct {
	verdict: [16]u8,
}

@(log_fact = "address_space: delegation: 10 an object that B made with a Spend handle, after the revocation: {verdict}: the object of 1 page that B made with it lives on after the revocation, paid by the child budget, and A cannot end it: the narrow right Commit makes no object")
Delegation_Object_Lives_On :: struct {
	verdict: [16]u8,
}

@(log_fact = "address_space: delegation: 10 an object that B made with a Spend handle, after the revocation: {verdict}: the object did not stay")
Delegation_Object_Gone :: struct {
	verdict: [16]u8,
}
