#+build !freestanding
package bar

import "core:testing"

// The work area of the scale 2 under a bar of 32 lines: 960 x 508.
@(private = "file")
WORK_AT_2 :: Work_Box{left = 0, top = 32, width = 960, height = 508}

@(private = "file")
terminal_at :: proc(x, y, width, height: int) -> Fit_Window {
	return {x = x, y = y, width = width, height = height, chrome_width = 2, chrome_height = 41, limits = {least_width = 200, least_height = 120, largest_width = 1600, largest_height = 900}, resizable = true}
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

// A least size larger than the room keeps the least size, and the corner at
// the top left: the title stays on the screen.
@(test)
a_least_size_past_the_room_keeps_the_least_size_and_the_title :: proc(t: ^testing.T) {
	window := terminal_at(700, 400, 1000, 600)
	window.limits.least_width, window.limits.least_height = 1000, 600
	x, y, width, height := window_fit(window, WORK_AT_2)
	testing.expect(t, width == 1000 && height == 600 && x == 0 && y == 32)
	// An empty work area: the least size, at its corner.
	x, y, width, height = window_fit(terminal_at(50, 60, 300, 200), {left = 0, top = 32, width = 0, height = 0})
	testing.expect(t, width == 200 && height == 120 && x == 0 && y == 32)
}

// A window that is not resizable keeps its size, and only moves.
@(test)
a_window_that_is_not_resizable_only_moves :: proc(t: ^testing.T) {
	window := terminal_at(500, 300, 1200, 700)
	window.resizable = false
	x, y, width, height := window_fit(window, WORK_AT_2)
	testing.expect(t, width == 1200 && height == 700 && x == 0 && y == 32)
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
