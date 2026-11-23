#+build !freestanding
package bar

import "core:testing"

// The work area of the scale 2 under a bar of 32 lines: 960 x 508.
@(private = "file")
WORK_AT_2 :: Work_Box{left = 0, top = 32, width = 960, height = 508}

@(private = "file")
terminal_at :: proc(x, y, width, height: int) -> Fit_Window {
	return {x = x, y = y, width = width, height = height, chrome_width = 2, chrome_height = 41}
}

// The order of the fit and of the scale: a fit that grows on either axis,
// by one pixel too, comes after the rescale; the same size and a smaller
// one come before it. The maximized terminal from 2 back to 1.25 grows
// from 958 x 467 to 1534 x 791: the scale first.
@(test)
a_fit_that_grows_comes_after_the_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, fit_order(958, 467, 1534, 791), Fit_Order.Scale_First)
	testing.expect_value(t, fit_order(958, 467, 959, 467), Fit_Order.Scale_First)
	testing.expect_value(t, fit_order(958, 467, 958, 468), Fit_Order.Scale_First)
	testing.expect_value(t, fit_order(958, 467, 900, 468), Fit_Order.Scale_First)
	testing.expect_value(t, fit_order(0, 0, max(int), max(int)), Fit_Order.Scale_First)
	testing.expect_value(t, fit_order(958, 467, 958, 467), Fit_Order.Fit_First)
	testing.expect_value(t, fit_order(1534, 791, 958, 467), Fit_Order.Fit_First)
	testing.expect_value(t, fit_order(max(int), max(int), 0, 0), Fit_Order.Fit_First)
}

// A window larger than the work area first: the terminal maximized at
// 1.25, 1536 x 792 under its frame, gets the size that fits the work area
// at 2, and its corner at the top left of it.
@(test)
a_window_larger_than_the_work_area_gets_the_size_that_fits :: proc(t: ^testing.T) {
	x, y, width, height := window_fit(terminal_at(0, 32, 1536, 792), WORK_AT_2)
	testing.expect_value(t, width, 960 - 2)
	testing.expect_value(t, height, 508 - 41)
	testing.expect_value(t, x, 0)
	testing.expect_value(t, y, 32)
	// One column and one line past the room: one less each.
	x, y, width, height = window_fit(terminal_at(0, 32, 959, 468), WORK_AT_2)
	testing.expect(t, width == 958 && height == 467 && x == 0 && y == 32)
	// The room exactly: no change.
	x, y, width, height = window_fit(terminal_at(0, 32, 958, 467), WORK_AT_2)
	testing.expect(t, width == 958 && height == 467 && x == 0 && y == 32)
}

// The fit has no floor at a least size: a window of 1200 x 700, fixed or
// with a larger least size, gets the room, and scrolls its layout in it.
// A work area smaller than the frame, an empty one and a negative one give
// a surface of 1 x 1 at the corner, never 0 or less.
@(test)
a_window_gets_at_most_the_room_and_never_less_than_one :: proc(t: ^testing.T) {
	x, y, width, height := window_fit(terminal_at(500, 300, 1200, 700), WORK_AT_2)
	testing.expect(t, width == 958 && height == 467 && x == 0 && y == 32)
	for work in ([?]Work_Box{{left = 0, top = 32, width = 2, height = 41}, {left = 0, top = 32, width = 0, height = 0}, {left = 0, top = 32, width = -5, height = -5}}) {
		x, y, width, height = window_fit(terminal_at(50, 60, 300, 200), work)
		testing.expectf(t, width == 1 && height == 1 && x == 0 && y == 32, "%v gives %d, %d, %dx%d", work, x, y, width, height)
	}
	// A wanted size of 0 or less is 1.
	x, y, width, height = window_fit(terminal_at(0, 32, 0, -4), WORK_AT_2)
	testing.expect(t, width == 1 && height == 1)
}

// A smaller window keeps its size; its place is moved into the work area
// from each side: past the right, past the bottom, left of the screen,
// under the top, and at the largest places of the type.
@(test)
a_smaller_window_keeps_its_size_and_moves_on_the_screen :: proc(t: ^testing.T) {
	Case :: struct {
		x, y, kept_x, kept_y: int,
	}
	cases := [?]Case {
		{x = 900, y = 500, kept_x = 960 - 402, kept_y = 32 + 508 - 241},
		{x = -300, y = 0, kept_x = 0, kept_y = 32},
		{x = max(int) / 2, y = max(int) / 2, kept_x = 960 - 402, kept_y = 32 + 508 - 241},
		{x = min(int) / 2, y = min(int) / 2, kept_x = 0, kept_y = 32},
		{x = 100, y = 100, kept_x = 100, kept_y = 100},
	}
	for each in cases {
		x, y, width, height := window_fit(terminal_at(each.x, each.y, 400, 200), WORK_AT_2)
		testing.expectf(t, x == each.kept_x && y == each.kept_y && width == 400 && height == 200, "%v gives %d, %d, %dx%d", each, x, y, width, height)
	}
}
