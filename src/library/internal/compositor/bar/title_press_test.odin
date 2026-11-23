#+build !freestanding
package bar

import "core:testing"

// The time between the two presses: 0, exactly the bound, and one past it.
// A clock that went back gives no double press.
@(test)
a_double_press_ends_at_its_time_bound :: proc(t: ^testing.T) {
	cases := [?]struct {
		second:   u64,
		expected: bool,
	}{{1000, true}, {1000 + DOUBLE_PRESS_MILLISECONDS, true}, {1000 + DOUBLE_PRESS_MILLISECONDS + 1, false}, {999, false}, {max(u64), false}}
	for item in cases {
		state: Double_Press
		testing.expect(t, !double_press_take(&state, 1000, 50, 10, 3))
		testing.expectf(t, double_press_take(&state, item.second, 50, 10, 3) == item.expected, "a second press at %d after a first at 1000", item.second)
	}
}

// The distance between the two presses on each axis: the bound, and one
// past it, in each direction.
@(test)
a_double_press_ends_at_its_distance_bound :: proc(t: ^testing.T) {
	cases := [?]struct {
		dx, dy:   int,
		expected: bool,
	}{
		{0, 0, true},
		{PRESS_STILL_DISTANCE, 0, true},
		{-PRESS_STILL_DISTANCE, PRESS_STILL_DISTANCE, true},
		{PRESS_STILL_DISTANCE + 1, 0, false},
		{0, -PRESS_STILL_DISTANCE - 1, false},
		{-PRESS_STILL_DISTANCE - 1, -PRESS_STILL_DISTANCE - 1, false},
	}
	for item in cases {
		state: Double_Press
		testing.expect(t, !double_press_take(&state, 0, 100, 100, 1))
		testing.expectf(t, double_press_take(&state, 10, 100 + item.dx, 100 + item.dy, 1) == item.expected, "a second press %d, %d away", item.dx, item.dy)
	}
}

// A press on another window starts a new pair; a double press disarms, so
// the third press is a first press; a press with no first press is never a
// double press.
@(test)
a_double_press_needs_one_window_and_starts_again_after_it :: proc(t: ^testing.T) {
	state: Double_Press
	testing.expect(t, !double_press_take(&state, 0, 5, 5, 0))
	testing.expect(t, !double_press_take(&state, 10, 5, 5, 1)) // Another window.
	testing.expect(t, double_press_take(&state, 20, 5, 5, 1))
	testing.expect(t, !state.armed)
	testing.expect(t, !double_press_take(&state, 30, 5, 5, 1)) // The third press.
	testing.expect(t, double_press_take(&state, 40, 5, 5, 1))
	forgotten: Double_Press
	testing.expect(t, !double_press_take(&forgotten, 0, 0, 0, 0)) // The zero state with the zero window is no first press.
}

// The hold of the title after the restore: a hold outside the maximized
// window, or a width that is no width, gives the left edge; the edges of
// the title give the edges of the restored title.
@(test)
the_hold_of_a_restored_title_keeps_its_part :: proc(t: ^testing.T) {
	testing.expect_value(t, restored_hold_x(0, 1536, 640), 0)
	testing.expect_value(t, restored_hold_x(768, 1536, 640), 320)
	testing.expect_value(t, restored_hold_x(1535, 1536, 640), 639)
	testing.expect_value(t, restored_hold_x(1536, 1536, 640), 0) // One past the window.
	testing.expect_value(t, restored_hold_x(-1, 1536, 640), 0)
	testing.expect_value(t, restored_hold_x(10, 0, 640), 0)
	testing.expect_value(t, restored_hold_x(10, 1536, 0), 0)
	testing.expect_value(t, restored_hold_x(10, -5, 640), 0)
}
