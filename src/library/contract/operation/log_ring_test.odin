#+build !freestanding
package operation

import "core:testing"

// The record that the kernel writes over now is the record
// `written - LOG_RECORD_CAPACITY`: while the kernel writes record W,
// `written` is still W. Its copy is never kept, the record after it is.
@(test)
the_record_under_the_writer_is_never_kept :: proc(t: ^testing.T) {
	writing := u64(LOG_RECORD_CAPACITY + 40) // The kernel writes this record; `written` is still its number.
	written := writing
	under_the_writer := writing - LOG_RECORD_CAPACITY
	testing.expect(t, !log_copy_kept(under_the_writer, written))
	testing.expect(t, log_copy_kept(under_the_writer + 1, written))
	// When the kernel ends the record and starts the next one, the next
	// record under the writer is lost too.
	testing.expect(t, !log_copy_kept(under_the_writer + 1, written + 1))
	testing.expect(t, log_copy_kept(written - 1, written))
}

// log_first_kept starts at the first record that log_copy_kept can keep,
// and counts each record before it as lost.
@(test)
the_first_kept_record_agrees_with_the_copy_rule :: proc(t: ^testing.T) {
	written := u64(LOG_RECORD_CAPACITY + 10)
	next, lost := log_first_kept(0, written)
	testing.expect_value(t, next, 11)
	testing.expect_value(t, lost, 11)
	testing.expect(t, log_copy_kept(next, written))
	testing.expect(t, !log_copy_kept(next - 1, written))

	// A log with fewer records than the capacity: nothing is lost.
	short_next, short_lost := log_first_kept(0, LOG_RECORD_CAPACITY - 1)
	testing.expect_value(t, short_next, 0)
	testing.expect_value(t, short_lost, 0)
	// Exactly the capacity: the record 0 is under the writer of the next one.
	full_next, full_lost := log_first_kept(0, LOG_RECORD_CAPACITY)
	testing.expect_value(t, full_next, 1)
	testing.expect_value(t, full_lost, 1)
	// A number past the last record gives the end, with nothing lost.
	end_next, end_lost := log_first_kept(written + 5, written)
	testing.expect_value(t, end_next, written)
	testing.expect_value(t, end_lost, 0)
}
