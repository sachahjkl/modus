// The deadline of a read of the entropy device that the root service asked
// for: a pure part, which the host tests (src/md/features/missing_hardware.md).
package entropy_read_deadline

import "modus:support/system"

// The time that a read has, from the moment the root service asked for it.
// It is the hang bound of the system, not a measure of the speed of the
// device: a slow device is not called absent.
READ_DEADLINE_MILLISECONDS :: system.TEST_HANG_BOUND_MILLISECONDS

// read_deadline gives the time at which a read asked at asked_at counts as
// refused. A time so late that the sum does not fit gives the largest time:
// the read then has no end before the end of the clock, never an end at a
// time that wrapped to the past.
read_deadline :: proc "contextless" (asked_at: u64) -> u64 {
	if asked_at > max(u64) - READ_DEADLINE_MILLISECONDS {
		return max(u64)
	}
	return asked_at + READ_DEADLINE_MILLISECONDS
}

// read_overdue says if a read asked at asked_at is past its deadline at now.
// A now before asked_at is not past it: a clock read out of order does not
// refuse a read.
read_overdue :: proc "contextless" (asked_at, now: u64) -> bool {
	return now >= asked_at && now - asked_at >= READ_DEADLINE_MILLISECONDS
}
