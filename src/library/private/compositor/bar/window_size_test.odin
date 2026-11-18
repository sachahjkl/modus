#+build !freestanding
package bar

import "core:testing"

// The frame of the compositor: borders of 2, a title of 24.
@(private = "file")
BORDER_OF_TEST :: 2
@(private = "file")
FRAME_WIDTH_OF_TEST :: 2 * BORDER_OF_TEST
@(private = "file")
FRAME_HEIGHT_OF_TEST :: 24 + BORDER_OF_TEST
@(private = "file")
SCREEN_WIDTH_OF_TEST :: 1280
@(private = "file")
SCREEN_HEIGHT_OF_TEST :: 768

// A window of 816 x 336 at (64, 56): its frame is 820 x 362.
@(private = "file")
OUTER_OF_TEST :: Outer_Rectangle{64, 56, 816 + FRAME_WIDTH_OF_TEST, 336 + FRAME_HEIGHT_OF_TEST}

@(private = "file")
SIZES_OF_TEST :: Size_Range{least_width = 816, least_height = 336, largest_width = 2048, largest_height = 2048}

@(private = "file")
start_of :: proc(edges: Resize_Edges, pointer_x, pointer_y: int) -> Resize_Start {
	return {edges = edges, pointer_x = pointer_x, pointer_y = pointer_y, x = OUTER_OF_TEST.x, y = OUTER_OF_TEST.y, width = 816, height = 336}
}

@(private = "file")
drag :: proc(start: Resize_Start, pointer_x, pointer_y: int, sizes := SIZES_OF_TEST) -> (x, y, width, height: int) {
	return resize_drag(start, pointer_x, pointer_y, sizes, FRAME_WIDTH_OF_TEST, FRAME_HEIGHT_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
}

// The places that are no edge come first: one pixel past the reach on each
// side, far away, the largest and the least coordinates, the surface, and
// the title bar, which moves the window.
@(test)
resize_edges_at_refuses_each_place_that_is_no_edge :: proc(t: ^testing.T) {
	outer := OUTER_OF_TEST
	right, bottom := outer.x + outer.width, outer.y + outer.height
	middle_x, middle_y := outer.x + outer.width / 2, outer.y + outer.height / 2
	no_edge := [?][2]int{
		{outer.x - RESIZE_REACH - 1, middle_y},
		{right + RESIZE_REACH, middle_y},
		{middle_x, outer.y - RESIZE_REACH - 1},
		{middle_x, bottom + RESIZE_REACH},
		{max(int), middle_y},
		{min(int), middle_y},
		{middle_x, max(int)},
		{middle_x, min(int)},
		{middle_x, middle_y}, // The surface.
		{middle_x, outer.y + 12}, // The title bar.
		{outer.x + BORDER_OF_TEST, middle_y}, // The first column of the surface.
		{right - BORDER_OF_TEST - 1, middle_y}, // The last column of the surface.
	}
	for place in no_edge {
		edges := resize_edges_at(outer, BORDER_OF_TEST, place[0], place[1])
		testing.expectf(t, edges == {}, "the place %v gives the edges %v", place, edges)
	}
}

// Each edge and each corner, at the border and at the end of the reach.
@(test)
resize_edges_at_each_edge_and_corner :: proc(t: ^testing.T) {
	outer := OUTER_OF_TEST
	right, bottom := outer.x + outer.width, outer.y + outer.height
	middle_x, middle_y := outer.x + outer.width / 2, outer.y + outer.height / 2
	cases := [?]struct {
		x, y:  int,
		edges: Resize_Edges,
	}{
		{outer.x, middle_y, {.Left}},
		{outer.x - RESIZE_REACH, middle_y, {.Left}},
		{right - 1, middle_y, {.Right}},
		{right + RESIZE_REACH - 1, middle_y, {.Right}},
		{middle_x, bottom - 1, {.Bottom}},
		{middle_x, bottom + RESIZE_REACH - 1, {.Bottom}},
		{middle_x, outer.y - 1, {.Top}},
		{middle_x, outer.y - RESIZE_REACH, {.Top}},
		{right - 1, bottom - 1, {.Right, .Bottom}},
		{right + RESIZE_REACH - 1, bottom + RESIZE_REACH - 1, {.Right, .Bottom}},
		{outer.x, bottom - 1, {.Left, .Bottom}},
		{outer.x - 1, outer.y - 1, {.Left, .Top}},
		{right, outer.y - 1, {.Right, .Top}},
		{outer.x, outer.y + 12, {.Left}}, // The left border goes up through the title bar.
	}
	for each in cases {
		edges := resize_edges_at(outer, BORDER_OF_TEST, each.x, each.y)
		testing.expectf(t, edges == each.edges, "the place %d,%d gives the edges %v, not %v", each.x, each.y, edges, each.edges)
	}
}

// No edge held: the drag changes nothing, wherever the pointer goes.
@(test)
resize_drag_with_no_edge_changes_nothing :: proc(t: ^testing.T) {
	pointers := [?][2]int{{0, 0}, {SCREEN_WIDTH_OF_TEST - 1, SCREEN_HEIGHT_OF_TEST - 1}, {-5000, -5000}, {5000, 5000}}
	for pointer in pointers {
		x, y, width, height := drag(start_of({}, 400, 300), pointer[0], pointer[1])
		testing.expect_value(t, x, OUTER_OF_TEST.x)
		testing.expect_value(t, y, OUTER_OF_TEST.y)
		testing.expect_value(t, width, 816)
		testing.expect_value(t, height, 336)
	}
}

// The size never goes below the least size: a pointer that would give a
// size of 0, a negative size, or the least one less one pixel.
@(test)
resize_drag_stops_at_the_least_size :: proc(t: ^testing.T) {
	press_x, press_y := OUTER_OF_TEST.x + OUTER_OF_TEST.width - 1, OUTER_OF_TEST.y + OUTER_OF_TEST.height - 1
	targets := [?][2]int{
		{press_x - 816, press_y - 336}, // A size of 0.
		{press_x - 2000, press_y - 2000}, // A negative size.
		{min(int) / 2, min(int) / 2},
		{press_x - 8, press_y - 8}, // One step below the least size.
	}
	for target in targets {
		_, _, width, height := drag(start_of({.Right, .Bottom}, press_x, press_y), target[0], target[1])
		testing.expect_value(t, width, SIZES_OF_TEST.least_width)
		testing.expect_value(t, height, SIZES_OF_TEST.least_height)
	}
	// The left and the top edge: the right and the bottom edge stay.
	x, y, width, height := drag(start_of({.Left, .Top}, OUTER_OF_TEST.x, OUTER_OF_TEST.y - 1), OUTER_OF_TEST.x + 900, OUTER_OF_TEST.y + 900)
	testing.expect_value(t, width, SIZES_OF_TEST.least_width)
	testing.expect_value(t, height, SIZES_OF_TEST.least_height)
	testing.expect_value(t, x, OUTER_OF_TEST.x)
	testing.expect_value(t, y, OUTER_OF_TEST.y)
}

// The size never goes past the largest size, nor past the screen: the
// pointer far past the screen stops the edge at it.
@(test)
resize_drag_stops_at_the_largest_size_and_at_the_screen :: proc(t: ^testing.T) {
	press_x, press_y := OUTER_OF_TEST.x + OUTER_OF_TEST.width - 1, OUTER_OF_TEST.y + OUTER_OF_TEST.height - 1
	// The screen stops the right and the bottom edge before the largest size.
	x, y, width, height := drag(start_of({.Right, .Bottom}, press_x, press_y), max(int) / 2, max(int) / 2)
	testing.expect_value(t, x, OUTER_OF_TEST.x)
	testing.expect_value(t, y, OUTER_OF_TEST.y)
	testing.expect_value(t, width, SCREEN_WIDTH_OF_TEST - OUTER_OF_TEST.x - FRAME_WIDTH_OF_TEST)
	testing.expect_value(t, height, SCREEN_HEIGHT_OF_TEST - OUTER_OF_TEST.y - FRAME_HEIGHT_OF_TEST)
	// The largest size stops them before the screen.
	small := Size_Range{least_width = 816, least_height = 336, largest_width = 900, largest_height = 400}
	_, _, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + 400, press_y + 300, small)
	testing.expect_value(t, width, 900)
	testing.expect_value(t, height, 400)
	// The left edge stops at 0 and the top edge under the bar, with the
	// pointer far outside the screen.
	x, y, width, height = drag(start_of({.Left, .Top}, OUTER_OF_TEST.x, OUTER_OF_TEST.y - 1), min(int) / 2, min(int) / 2)
	testing.expect_value(t, x, 0)
	testing.expect_value(t, y, HEIGHT)
	testing.expect_value(t, width, OUTER_OF_TEST.x + 816)
	testing.expect_value(t, height, OUTER_OF_TEST.y + 336 - HEIGHT)
}

// A window already partly past the right of the screen: a drag to the
// right does not make it larger, and the screen does not make it smaller.
@(test)
resize_drag_of_a_window_past_the_screen :: proc(t: ^testing.T) {
	start := start_of({.Right}, 1270, 200)
	start.x = 800 // Its right edge is at 1620, past the screen.
	_, _, width, _ := drag(start, 1279, 200)
	testing.expect_value(t, width, 816)
	// Toward the left, it becomes smaller as the pointer says.
	_, _, width, _ = drag(start, 1270 - 40, 200, Size_Range{least_width = 400, least_height = 336, largest_width = 1200, largest_height = 600})
	testing.expect_value(t, width, 776)
}

// The edges move by steps of the grid, to the nearest step: a move of 3
// pixels is no step, a move of 4 is one, toward the start a move of 4 is
// none and a move of 5 is one. Then the drag of a corner to a size inside
// the limits and inside the screen, last.
@(test)
resize_drag_moves_by_steps_of_the_grid :: proc(t: ^testing.T) {
	sizes := Size_Range{least_width = 400, least_height = 200, largest_width = 1200, largest_height = 600}
	press_x, press_y := OUTER_OF_TEST.x + OUTER_OF_TEST.width - 1, OUTER_OF_TEST.y + OUTER_OF_TEST.height - 1
	_, _, width, height := drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + 3, press_y - 4, sizes)
	testing.expect_value(t, width, 816)
	testing.expect_value(t, height, 336)
	_, _, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + 4, press_y - 5, sizes)
	testing.expect_value(t, width, 816 + GRID)
	testing.expect_value(t, height, 336 - GRID)
	x, y: int
	x, y, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + 160, press_y + 64, sizes)
	testing.expect_value(t, x, OUTER_OF_TEST.x)
	testing.expect_value(t, y, OUTER_OF_TEST.y)
	testing.expect_value(t, width, 976)
	testing.expect_value(t, height, 400)
	// The left edge: the window keeps its right edge, on the grid.
	x, _, width, _ = drag(start_of({.Left}, OUTER_OF_TEST.x, 200), OUTER_OF_TEST.x - 40, 200, sizes)
	testing.expect_value(t, width, 856)
	testing.expect_value(t, x, OUTER_OF_TEST.x - 40)
	testing.expect(t, x %% GRID == 0, "the left edge stays on the grid")
}
