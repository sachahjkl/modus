#+build !freestanding
package storage

import "core:testing"
import block "modus:contract/block"
import "modus:contract/storage_status"
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
