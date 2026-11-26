#+build !freestanding
#+build !modus
package storage

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "core:testing"
import block "modus:contract/block"
import "modus:system"

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

// A call is made again only for the refusal of the repair or the recount
// of the counts: the outcome Callee_Busy with the record Busy, unit
// Count_Repair or Count_Recount, the
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
	// A recount refuses the changes as a repair does, to the same bound.
	recount := errors.error_make(.Busy, .Count_Recount, 0, 2, 5, 0)
	retry, _ = repair_retry(.Failed, .Callee_Busy, &recount, 0)
	testing.expect(t, retry, "the refusal of a recount is made again")
	retry, _ = repair_retry(.Failed, .Callee_Busy, &recount, REPAIR_WAIT_BOUND_MILLISECONDS)
	testing.expect(t, !retry, "past the bound the recount refusal comes back")
	recount_damaged := errors.error_make(.Damaged, .Count_Recount, 0, 2, 5, 0)
	retry, _ = repair_retry(.Failed, .Callee_Busy, &recount_damaged, 0)
	testing.expect(t, !retry, "another kind of the unit comes back at once")
}

// The bound of a call: past the bound of the disk, so that a silent disk
// answers Device before the client gives up; never in the past, at the
// largest time too.
@(test)
the_bound_of_a_call_passes_the_bound_of_the_disk :: proc(t: ^testing.T) {
	testing.expect(t, storage_status.ANSWER_BOUND_MILLISECONDS > block.NO_ANSWER_BOUND_MILLISECONDS)
	testing.expect_value(t, call_deadline(0), u64(storage_status.ANSWER_BOUND_MILLISECONDS))
	testing.expect_value(t, call_deadline(5), u64(5 + storage_status.ANSWER_BOUND_MILLISECONDS))
	edge := system.WAIT_FOREVER - storage_status.ANSWER_BOUND_MILLISECONDS
	testing.expect_value(t, call_deadline(edge), system.WAIT_FOREVER)
	testing.expect_value(t, call_deadline(edge + 1), system.WAIT_FOREVER)
	testing.expect_value(t, call_deadline(max(u64)), system.WAIT_FOREVER)
}

// After No_Answer the client waits for the answer of the late call only:
// an answer of another tag, a tag 0, or a second look after the answer came
// does not clear it, and the client serves again once it came.
@(test)
a_late_answer_clears_the_late_call_once :: proc(t: ^testing.T) {
	client: Client
	testing.expect(t, !late_answer_is(&client, 0))
	testing.expect(t, !late_answer_is(&client, 7))
	client.late_tag = 7
	testing.expect(t, !late_answer_is(&client, 0))
	testing.expect(t, !late_answer_is(&client, 6))
	testing.expect(t, !late_answer_is(&client, 8))
	testing.expect_value(t, client.late_tag, u32(7))
	testing.expect(t, late_answer_is(&client, 7))
	testing.expect_value(t, client.late_tag, u32(0))
	testing.expect(t, !late_answer_is(&client, 7))
	testing.expect(t, !client.gone)
}
