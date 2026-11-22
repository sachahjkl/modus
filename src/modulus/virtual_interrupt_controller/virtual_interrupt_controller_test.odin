#+build !freestanding
package virtual_interrupt_controller

import "core:testing"

set :: proc(pending: ^Pending_Words, vector: u8) -> bool {
	index, mask, ok := vector_bit(vector)
	if ok {
		pending[index] |= mask
	}
	return ok
}

take :: proc(pending: ^Pending_Words) -> (u8, bool) {
	vector, found := highest_pending(pending^)
	if found {
		index, mask, _ := vector_bit(vector)
		pending[index] &~= mask
	}
	return vector, found
}

// An exception vector has no bit, at the edge 31, and the first interrupt
// vector and the last one have one.
@(test)
exception_vectors_are_refused :: proc(t: ^testing.T) {
	for vector in ([]u8{0, 1, 14, 31}) {
		_, mask, ok := vector_bit(vector)
		testing.expectf(t, !ok && mask == 0, "the exception vector %d has a bit", vector)
	}
	index, mask, ok := vector_bit(32)
	testing.expect(t, ok && index == 0 && mask == u64(1) << 32, "the vector 32 has the wrong bit")
	index, mask, ok = vector_bit(255)
	testing.expect(t, ok && index == 3 && mask == u64(1) << 63, "the vector 255 has the wrong bit")
	_, found := highest_pending({})
	testing.expect(t, !found, "an empty set gives a vector")
}

// A bit of an exception vector that a damaged word holds is never given.
@(test)
exception_bits_are_never_given :: proc(t: ^testing.T) {
	_, found := highest_pending({0xFFFF_FFFF, 0, 0, 0})
	testing.expect(t, !found, "an exception bit is given")
	vector, found_32 := highest_pending({0x1_FFFF_FFFF, 0, 0, 0})
	testing.expect(t, found_32 && vector == 32, "the vector 32 is lost among exception bits")
}

// The highest vector comes first, each vector comes once, and a vector set
// twice before its take comes once.
@(test)
vectors_come_highest_first_and_once :: proc(t: ^testing.T) {
	pending: Pending_Words
	for vector in ([]u8{48, 63, 64, 49, 255, 127, 128, 32, 49}) {
		testing.expect(t, set(&pending, vector))
	}
	want := [?]u8{255, 128, 127, 64, 63, 49, 48, 32}
	for expected in want {
		vector, taken := take(&pending)
		testing.expectf(t, taken && vector == expected, "took %d (%v), not %d", vector, taken, expected)
	}
	_, taken := take(&pending)
	testing.expect(t, !taken, "a vector came twice")
}

// A period of 0 or an exception vector does not arm the timer, and leaves
// the timer as it was.
@(test)
a_wrong_timer_is_refused :: proc(t: ^testing.T) {
	timer: Timer
	testing.expect(t, !timer_arm(&timer, 100, 0, 48), "a period of 0 is accepted")
	testing.expect(t, !timer_arm(&timer, 100, 10, 31), "an exception vector is accepted")
	testing.expect(t, timer == Timer{}, "a refused arm changed the timer")
	testing.expect(t, !timer_check(&timer, max(u64)), "a timer that is not armed fires")
	testing.expect_value(t, wait_bound(timer, 0, 7), 7)
}

// The timer fires at its deadline and not one nanosecond before, then one
// period later.
@(test)
the_timer_fires_at_its_deadline :: proc(t: ^testing.T) {
	timer: Timer
	testing.expect(t, timer_arm(&timer, 1000, 100, 48))
	testing.expect_value(t, wait_bound(timer, 1000, 1_000_000), 100)
	testing.expect(t, !timer_check(&timer, 1099), "the timer fires early")
	testing.expect(t, timer_check(&timer, 1100), "the timer does not fire at its deadline")
	testing.expect(t, !timer_check(&timer, 1199), "the timer fires twice in one period")
	testing.expect(t, timer_check(&timer, 1200), "the second period gives no tick")
}

// Missed deadlines give one tick, and the next deadline is in the future.
@(test)
missed_ticks_give_one_tick :: proc(t: ^testing.T) {
	timer: Timer
	testing.expect(t, timer_arm(&timer, 0, 10, 48))
	testing.expect(t, timer_check(&timer, 1_000_005), "a late check does not fire")
	testing.expect(t, !timer_check(&timer, 1_000_005), "a late check fires twice")
	testing.expect_value(t, timer.deadline_nanoseconds, 1_000_015)
}

// A deadline near the top of the clock saturates and never wraps to a
// deadline in the past.
@(test)
the_deadline_saturates :: proc(t: ^testing.T) {
	timer: Timer
	testing.expect(t, timer_arm(&timer, max(u64) - 5, 10, 48))
	testing.expect_value(t, timer.deadline_nanoseconds, max(u64))
	testing.expect(t, !timer_check(&timer, max(u64) - 1), "a saturated deadline fires early")
	testing.expect(t, timer_check(&timer, max(u64)), "a saturated deadline never fires")
	testing.expect_value(t, timer.deadline_nanoseconds, max(u64))
}

// A paused timer gives no tick, and the idle wait is not bounded by it; at
// its end, a deadline that passed gives one tick.
@(test)
a_paused_timer_gives_no_tick :: proc(t: ^testing.T) {
	timer: Timer
	testing.expect(t, timer_arm(&timer, 0, 10, 48))
	timer_pause(&timer, true)
	testing.expect(t, !timer_check(&timer, 50), "a paused timer fires")
	testing.expect_value(t, wait_bound(timer, 50, 1000), 1000)
	timer_pause(&timer, false)
	testing.expect_value(t, wait_bound(timer, 50, 1000), 0)
	testing.expect(t, timer_check(&timer, 50), "the timer does not fire after its pause")
}
