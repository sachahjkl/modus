#+build !freestanding
package entropy_read_deadline

import "core:testing"

// A clock read before the time of the ask does not refuse the read: one
// before it, and the largest gap.
@(test)
a_time_before_the_ask_is_not_overdue :: proc(t: ^testing.T) {
	asked_ats := [?]u64{1, READ_DEADLINE_MILLISECONDS, READ_DEADLINE_MILLISECONDS + 1, max(u64)}
	for asked_at in asked_ats {
		testing.expect(t, !read_overdue(asked_at, asked_at - 1), "a time one before the ask is not past the deadline")
		testing.expect(t, !read_overdue(asked_at, 0), "the time 0 after a later ask is not past the deadline")
	}
}

// One less than the deadline is not past it, at each place of the clock.
@(test)
one_before_the_deadline_is_not_overdue :: proc(t: ^testing.T) {
	asked_ats := [?]u64{0, 1, 12_345, max(u64) - READ_DEADLINE_MILLISECONDS}
	for asked_at in asked_ats {
		testing.expect(t, !read_overdue(asked_at, asked_at), "the time of the ask is not past the deadline")
		testing.expect(t, !read_overdue(asked_at, asked_at + 1), "one after the ask is not past the deadline")
		testing.expect(t, !read_overdue(asked_at, asked_at + READ_DEADLINE_MILLISECONDS - 1), "one before the deadline is not past it")
	}
}

// A read asked so late that its deadline does not fit has the largest
// deadline, and no time of the clock is past it: the sum never wraps to a
// deadline in the past.
@(test)
a_deadline_that_does_not_fit_is_the_end_of_the_clock :: proc(t: ^testing.T) {
	asked_ats := [?]u64{max(u64) - READ_DEADLINE_MILLISECONDS + 1, max(u64) - 1, max(u64)}
	for asked_at in asked_ats {
		testing.expect_value(t, read_deadline(asked_at), max(u64))
		testing.expect(t, !read_overdue(asked_at, max(u64)), "no time of the clock is past a deadline that does not fit")
	}
	testing.expect_value(t, read_deadline(max(u64) - READ_DEADLINE_MILLISECONDS), max(u64))
}

// The successful cases come last: the deadline, one past it and the end of
// the clock are past it, and the deadline that read_deadline gives is the
// first time that read_overdue calls past.
@(test)
the_deadline_refuses_the_read :: proc(t: ^testing.T) {
	asked_ats := [?]u64{0, 1, 12_345, max(u64) - READ_DEADLINE_MILLISECONDS}
	for asked_at in asked_ats {
		deadline := read_deadline(asked_at)
		testing.expect_value(t, deadline, asked_at + READ_DEADLINE_MILLISECONDS)
		testing.expect(t, read_overdue(asked_at, deadline), "the deadline is past it")
		testing.expect(t, !read_overdue(asked_at, deadline - 1), "one before the deadline is not past it")
		testing.expect(t, read_overdue(asked_at, max(u64)), "the end of the clock is past it")
		if deadline < max(u64) {
			testing.expect(t, read_overdue(asked_at, deadline + 1), "one past the deadline is past it")
		}
	}
}
