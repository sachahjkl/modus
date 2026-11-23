#+build !freestanding
package storage

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

// The result of a failed export comes from the storage service. Each
// result that names no answer is refused first: 0, a positive result, one
// past each end of the answers, the largest and the smallest word. Then
// each answer comes back from its own result.
@(test)
a_result_that_names_no_answer_is_refused :: proc(t: ^testing.T) {
	last := min(Export_Error)
	refused := [?]i64{0, 1, i64(max(Export_Error)) + 1, i64(last) - 1, max(i64), min(i64)}
	for result in refused {
		_, ok := export_error_of_result(result)
		testing.expectf(t, !ok, "the result %d names no answer, and it is taken", result)
		testing.expect(t, !export_failed_with(.Failed, result, .No_Store))
		testing.expect(t, !export_failed_with(.Failed, result, last))
	}
	for answer in Export_Error {
		read, ok := export_error_of_result(i64(answer))
		testing.expect(t, ok)
		testing.expect_value(t, read, answer)
		// The answer counts only with the status Failed.
		testing.expect(t, !export_failed_with(.Ok, i64(answer), answer))
		testing.expect(t, export_failed_with(.Failed, i64(answer), answer))
	}
}

// A call is made again only for the refusal of the repair of the counts:
// Busy with the unit Count_Repair, the status Failed, before the bound.
// Each other answer comes back at once: another status, another result,
// another kind or unit, and the bound itself and past it.
@(test)
only_the_refusal_of_a_repair_is_made_again :: proc(t: ^testing.T) {
	repair := errors.error_make(.Busy, .Count_Repair, 0, 2, 5, 0)
	requests := errors.error_make(.Busy, .Requests, 0, 2, 5, 0)
	damaged := errors.error_make(.Damaged, .Count_Repair, 0, 2, 5, 0)
	Case :: struct {
		status: storage_status.Status,
		value:  i64,
		record: errors.Error_Record,
		waited: u64,
	}
	refused := [?]Case {
		{.Ok, i64(Export_Error.Busy), repair, 0},
		{.Refused, i64(Export_Error.Busy), repair, 0},
		{.Failed, i64(Export_Error.Damaged), repair, 0},
		{.Failed, i64(Export_Error.Busy) + 1, repair, 0},
		{.Failed, i64(Export_Error.Busy), requests, 0},
		{.Failed, i64(Export_Error.Busy), damaged, 0},
		{.Failed, i64(Export_Error.Busy), repair, REPAIR_WAIT_BOUND_MILLISECONDS},
		{.Failed, i64(Export_Error.Busy), repair, REPAIR_WAIT_BOUND_MILLISECONDS + 1},
		{.Failed, i64(Export_Error.Busy), repair, max(u64)},
	}
	for &item, index in refused {
		retry, _ := repair_retry(item.status, item.value, &item.record, item.waited)
		testing.expectf(t, !retry, "case %d is made again", index)
	}
	retry, wait := repair_retry(.Failed, i64(Export_Error.Busy), &repair, 0)
	testing.expect(t, retry)
	testing.expect_value(t, wait, u64(REPAIR_RETRY_MILLISECONDS))
	// The last try waits only to the bound.
	retry, wait = repair_retry(.Failed, i64(Export_Error.Busy), &repair, REPAIR_WAIT_BOUND_MILLISECONDS - 1)
	testing.expect(t, retry)
	testing.expect_value(t, wait, u64(1))
}
