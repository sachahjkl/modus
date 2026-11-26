#+build !freestanding
#+build !modus
package system

import op "modus:contract/operation"
import "core:testing"

// A deadline is never in the past and never wraps. The edges come first:
// the largest time, one below it, the last time whose sum still fits and
// one past it; then the time 0 and 1, last.
@(test)
answer_deadline_never_wraps :: proc(t: ^testing.T) {
	last_that_fits := WAIT_FOREVER - ANSWER_BOUND_MILLISECONDS
	testing.expect_value(t, answer_deadline(WAIT_FOREVER), WAIT_FOREVER)
	testing.expect_value(t, answer_deadline(WAIT_FOREVER - 1), WAIT_FOREVER)
	testing.expect_value(t, answer_deadline(last_that_fits + 1), WAIT_FOREVER)
	testing.expect_value(t, answer_deadline(last_that_fits), WAIT_FOREVER)
	testing.expect_value(t, answer_deadline(last_that_fits - 1), WAIT_FOREVER - 1)
	testing.expect_value(t, answer_deadline(0), u64(ANSWER_BOUND_MILLISECONDS))
	testing.expect_value(t, answer_deadline(1), u64(ANSWER_BOUND_MILLISECONDS) + 1)
}

// A process that stopped, and a handle that names no process, end the
// wait at once, before and after the deadline: no answer comes from them.
// A process that runs past its deadline is silent, at the deadline and one
// past it. A process that runs before its deadline, and one that was made
// and not started, keep the wait, last.
@(test)
answer_wait_of_ends_at_a_stop_and_at_the_deadline :: proc(t: ^testing.T) {
	deadline := answer_deadline(1000)
	for state in ([]op.Process_State{.None, .Stopped}) {
		testing.expect_value(t, answer_wait_of(0, deadline, state), Answer_Wait.Stopped)
		testing.expect_value(t, answer_wait_of(deadline - 1, deadline, state), Answer_Wait.Stopped)
		testing.expect_value(t, answer_wait_of(deadline, deadline, state), Answer_Wait.Stopped)
		testing.expect_value(t, answer_wait_of(WAIT_FOREVER, deadline, state), Answer_Wait.Stopped)
	}
	for state in ([]op.Process_State{.Created, .Ready, .Waiting}) {
		testing.expect_value(t, answer_wait_of(deadline, deadline, state), Answer_Wait.Silent)
		testing.expect_value(t, answer_wait_of(deadline + 1, deadline, state), Answer_Wait.Silent)
		testing.expect_value(t, answer_wait_of(WAIT_FOREVER, deadline, state), Answer_Wait.Silent)
		testing.expect_value(t, answer_wait_of(deadline - 1, deadline, state), Answer_Wait.Waits)
		testing.expect_value(t, answer_wait_of(0, deadline, state), Answer_Wait.Waits)
	}
	// The largest deadline is never passed by a process that runs.
	testing.expect_value(t, answer_wait_of(WAIT_FOREVER - 1, WAIT_FOREVER, .Ready), Answer_Wait.Waits)
}

// The earliest deadline of the requests in flight: no place and only free
// places give WAIT_FOREVER; a free place (0) is never the earliest; the
// largest deadline is kept; then places in any order, last.
@(test)
answer_deadline_earliest_skips_the_free_places :: proc(t: ^testing.T) {
	testing.expect_value(t, answer_deadline_earliest(nil), WAIT_FOREVER)
	free := [3]u64{0, 0, 0}
	testing.expect_value(t, answer_deadline_earliest(free[:]), WAIT_FOREVER)
	largest := [2]u64{0, WAIT_FOREVER}
	testing.expect_value(t, answer_deadline_earliest(largest[:]), WAIT_FOREVER)
	one := [1]u64{1}
	testing.expect_value(t, answer_deadline_earliest(one[:]), u64(1))
	mixed := [5]u64{0, 9000, 0, 7000, 8000}
	testing.expect_value(t, answer_deadline_earliest(mixed[:]), u64(7000))
	last := [3]u64{9000, 8000, 7000}
	testing.expect_value(t, answer_deadline_earliest(last[:]), u64(7000))
}
