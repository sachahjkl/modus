#+build !freestanding
package storage

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "core:testing"

// The kind of a Listed row comes from the storage service. Each word that
// names no entry is refused first: None, one past the last kind, a
// negative word, the largest and the smallest word. Then each kind of an
// entry comes back from its own word.
@(test)
a_kind_that_names_no_entry_is_refused :: proc(t: ^testing.T) {
	refused := [?]i64{i64(Entry_Kind.None), i64(max(Entry_Kind)) + 1, -1, max(i64), min(i64)}
	for word in refused {
		_, ok := entry_kind_of_word(word)
		testing.expectf(t, !ok, "the kind %d names no entry, and it is taken", word)
	}
	for kind in Entry_Kind {
		if kind == .None {
			continue
		}
		read, ok := entry_kind_of_word(i64(kind))
		testing.expect(t, ok)
		testing.expect_value(t, read, kind)
	}
}

// A call is made again only for the refusal of the repair of the counts:
// the outcome Callee_Busy with the record Busy, unit Count_Repair, the
// status Failed, before the bound. Each other answer comes back at once:
// another status, another outcome, another kind or unit, and the bound
// itself and past it.
@(test)
only_the_refusal_of_a_repair_is_made_again :: proc(t: ^testing.T) {
	repair := errors.error_make(.Busy, .Count_Repair, 0, 2, 5, 0)
	requests := errors.error_make(.Busy, .Requests, 0, 2, 5, 0)
	damaged := errors.error_make(.Damaged, .Count_Repair, 0, 2, 5, 0)
	Case :: struct {
		status:  storage_status.Status,
		outcome: call_outcome.Call_Outcome,
		record:  errors.Error_Record,
		waited:  u64,
	}
	refused := [?]Case {
		{.Ok, .Callee_Busy, repair, 0},
		{.Refused, .Callee_Busy, repair, 0},
		{.Failed, .Data_Damaged, repair, 0},
		{.Failed, .Budget_Or_Capacity_Exhausted, repair, 0},
		{.Failed, .Callee_Busy, requests, 0},
		{.Failed, .Callee_Busy, damaged, 0},
		{.Failed, .Callee_Busy, repair, REPAIR_WAIT_BOUND_MILLISECONDS},
		{.Failed, .Callee_Busy, repair, REPAIR_WAIT_BOUND_MILLISECONDS + 1},
		{.Failed, .Callee_Busy, repair, max(u64)},
	}
	for &item, index in refused {
		retry, _ := repair_retry(item.status, item.outcome, &item.record, item.waited)
		testing.expectf(t, !retry, "case %d is made again", index)
	}
	retry, wait := repair_retry(.Failed, .Callee_Busy, &repair, 0)
	testing.expect(t, retry)
	testing.expect_value(t, wait, u64(REPAIR_RETRY_MILLISECONDS))
	// The last try waits only to the bound.
	retry, wait = repair_retry(.Failed, .Callee_Busy, &repair, REPAIR_WAIT_BOUND_MILLISECONDS - 1)
	testing.expect(t, retry)
	testing.expect_value(t, wait, u64(1))
}
