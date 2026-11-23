package bar

// The presses on a title bar: a double press toggles the maximize of its
// window, and a drag of a maximized window gives it back its size of
// before under the pointer (src/md/features/window_resize.md, "The
// maximize"). These procedures hold no state of the compositor, so a host
// test checks each edge.

// The longest time between the two presses of a double press. The system
// has no setting of it: this is the usual time of desktops.
DOUBLE_PRESS_MILLISECONDS :: 400
// The farthest that the second press of a double press is from the first,
// on each axis, in logical pixels. A drag of a maximized window restores it
// only past the same distance, so the small move of a hand between the two
// presses does not restore it.
PRESS_STILL_DISTANCE :: 4

// The last press on a title bar that can start a double press.
Double_Press :: struct {
	armed:             bool, // A first press waits for its second.
	time_milliseconds: u64,
	x, y:              int,
	window:            int, // The index of the window in the table of the compositor.
}

// double_press_take takes a press on the title bar of a window, and says
// whether it is the second press of a double press: the same window, at
// most DOUBLE_PRESS_MILLISECONDS after the first, at most
// PRESS_STILL_DISTANCE from it on each axis. A double press disarms the
// state, so a third press starts a new pair. A clock that went back gives
// no double press: the press starts a new pair.
double_press_take :: proc "contextless" (state: ^Double_Press, time_milliseconds: u64, x, y: int, window: int) -> bool {
	is_double := state.armed && state.window == window && time_milliseconds >= state.time_milliseconds && time_milliseconds - state.time_milliseconds <= DOUBLE_PRESS_MILLISECONDS && press_still(state.x, state.y, x, y)
	if is_double {
		state^ = {}
		return true
	}
	state^ = {armed = true, time_milliseconds = time_milliseconds, x = x, y = y, window = window}
	return false
}

// press_still says whether a pointer at (x, y) is still at the press at
// (press_x, press_y): at most PRESS_STILL_DISTANCE on each axis.
press_still :: proc "contextless" (press_x, press_y, x, y: int) -> bool {
	return abs(x - press_x) <= PRESS_STILL_DISTANCE && abs(y - press_y) <= PRESS_STILL_DISTANCE
}

// restored_hold_x gives the place in the title of a window that the pointer
// holds after the window takes back its outer width of before a maximize:
// the same part of the title, so the pointer stays over the title of the
// smaller window. A width of 0 or less, a hold outside the maximized
// window, or a restored width of 0 or less gives a hold at the left edge of
// the title, which is inside each window.
restored_hold_x :: proc "contextless" (held_x, outer_width, restored_outer_width: int) -> int {
	if outer_width <= 0 || restored_outer_width <= 0 || held_x < 0 || held_x >= outer_width {
		return 0
	}
	// The product fits: both sides are widths of a window on a screen.
	return held_x * restored_outer_width / outer_width
}
