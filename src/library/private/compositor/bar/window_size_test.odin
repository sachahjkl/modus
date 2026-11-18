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
		{press_x - 8, press_y - 8}, // A gap below the least size.
		{press_x - 1, press_y - 1}, // One pixel below the least size.
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
	// One pixel past the largest size, and the largest size itself.
	_, _, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + (900 - 816) + 1, press_y + (400 - 336) + 1, small)
	testing.expect_value(t, width, 900)
	testing.expect_value(t, height, 400)
	_, _, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + (900 - 816), press_y + (400 - 336), small)
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

// The edges move with the pointer, to the pixel: a drag of no pixel changes
// nothing, a drag of one pixel changes the size by one pixel in each
// direction, and the left and the top edge move by one pixel too. Then the
// drag of a corner to a size inside the limits and inside the screen, last.
@(test)
resize_drag_moves_to_the_pixel :: proc(t: ^testing.T) {
	sizes := Size_Range{least_width = 400, least_height = 200, largest_width = 1200, largest_height = 600}
	press_x, press_y := OUTER_OF_TEST.x + OUTER_OF_TEST.width - 1, OUTER_OF_TEST.y + OUTER_OF_TEST.height - 1
	_, _, width, height := drag(start_of({.Right, .Bottom}, press_x, press_y), press_x, press_y, sizes)
	testing.expect_value(t, width, 816)
	testing.expect_value(t, height, 336)
	_, _, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + 1, press_y - 1, sizes)
	testing.expect_value(t, width, 816 + 1)
	testing.expect_value(t, height, 336 - 1)
	_, _, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x - 1, press_y + 1, sizes)
	testing.expect_value(t, width, 816 - 1)
	testing.expect_value(t, height, 336 + 1)
	x, y: int
	x, y, width, height = drag(start_of({.Left, .Top}, OUTER_OF_TEST.x, OUTER_OF_TEST.y - 1), OUTER_OF_TEST.x + 1, OUTER_OF_TEST.y, sizes)
	testing.expect_value(t, x, OUTER_OF_TEST.x + 1)
	testing.expect_value(t, y, OUTER_OF_TEST.y + 1)
	testing.expect_value(t, width, 816 - 1)
	testing.expect_value(t, height, 336 - 1)
	x, y, width, height = drag(start_of({.Right, .Bottom}, press_x, press_y), press_x + 163, press_y + 61, sizes)
	testing.expect_value(t, x, OUTER_OF_TEST.x)
	testing.expect_value(t, y, OUTER_OF_TEST.y)
	testing.expect_value(t, width, 816 + 163)
	testing.expect_value(t, height, 336 + 61)
	// The left edge: the window keeps its right edge.
	x, _, width, _ = drag(start_of({.Left}, OUTER_OF_TEST.x, 200), OUTER_OF_TEST.x - 43, 200, sizes)
	testing.expect_value(t, width, 816 + 43)
	testing.expect_value(t, x, OUTER_OF_TEST.x - 43)
}

// A window behind the front one: its frame is under the band of the right
// edge of the front window.
@(private = "file")
BEHIND_OF_TEST :: Outer_Rectangle{880, 100, 200, 200}

// The band of an edge never takes a press from a window that lies under the
// pointer, and a window in front hides the edges of the windows behind it.
// The places that give no edge come first, then the edges that hold.
@(test)
resize_target_refuses_a_place_that_another_window_holds :: proc(t: ^testing.T) {
	front_first := [2]Window_Hit{{outer = OUTER_OF_TEST, resizable = true}, {outer = BEHIND_OF_TEST, resizable = false}}
	right := OUTER_OF_TEST.x + OUTER_OF_TEST.width
	no_edge := [?][2]int{
		{right + 2, 200}, // The band of the front window, over the window behind.
		{OUTER_OF_TEST.x + 100, OUTER_OF_TEST.y + 100}, // The surface of the front window.
		{2000, 2000}, // Far from each window.
		{max(int), min(int)},
	}
	for place in no_edge {
		found, edges := resize_target(front_first[:], BORDER_OF_TEST, place[0], place[1])
		testing.expectf(t, found == -1 && edges == {}, "the place %v gives the window %d and the edges %v", place, found, edges)
	}
	// The other order: the window behind comes to the front and is
	// resizable. It covers the right border of the other window, and its own
	// band at its left lies over the frame of the other window.
	other_order := [2]Window_Hit{{outer = BEHIND_OF_TEST, resizable = true}, {outer = OUTER_OF_TEST, resizable = true}}
	covered := [?][2]int{
		{right - 1, 200}, // The right border of the window behind, under the front one.
		{BEHIND_OF_TEST.x - 3, 200}, // The band of the front window, over the frame of the other one.
	}
	for place in covered {
		found, edges := resize_target(other_order[:], BORDER_OF_TEST, place[0], place[1])
		testing.expectf(t, found == -1 && edges == {}, "the place %v gives the window %d and the edges %v", place, found, edges)
	}
	// No window at all.
	found, edges := resize_target(nil, BORDER_OF_TEST, right - 1, 200)
	testing.expect(t, found == -1 && edges == {})
	// A fixed window has no edge, at its border and in its band.
	fixed := [1]Window_Hit{{outer = OUTER_OF_TEST, resizable = false}}
	found, edges = resize_target(fixed[:], BORDER_OF_TEST, right - 1, 200)
	testing.expect(t, found == -1 && edges == {})
	found, edges = resize_target(fixed[:], BORDER_OF_TEST, right + 2, 200)
	testing.expect(t, found == -1 && edges == {})
	// The edges that hold: the border of the front window over the window
	// behind, and its band where no window lies.
	found, edges = resize_target(front_first[:], BORDER_OF_TEST, right - 1, 200)
	testing.expect_value(t, found, 0)
	testing.expect_value(t, edges, Resize_Edges{.Right})
	found, edges = resize_target(front_first[:], BORDER_OF_TEST, right + 2, 400)
	testing.expect_value(t, found, 0)
	testing.expect_value(t, edges, Resize_Edges{.Right})
	// The border of the window behind where the front one does not cover it.
	behind_bottom := BEHIND_OF_TEST.y + BEHIND_OF_TEST.height - 1
	found, edges = resize_target(other_order[:], BORDER_OF_TEST, BEHIND_OF_TEST.x + 50, behind_bottom)
	testing.expect_value(t, found, 0)
	testing.expect_value(t, edges, Resize_Edges{.Bottom})
}

// The facts of a Surface_Resize that the compositor takes: the answer of
// 880 x 384 to the request of that size.
@(private = "file")
answer_of_test :: proc() -> Surface_Resize_Facts {
	return {
		is_memory = true,
		readable = true,
		memory_bytes = 880 * 384 * SURFACE_BYTES_FOR_EACH_PIXEL,
		width = 880,
		height = 384,
		resizable = true,
		limits = {least_width = 816, least_height = 336, largest_width = 1216, largest_height = 640},
		asked = true,
		asked_width = 880,
		asked_height = 384,
	}
}

// Each rule that a Surface_Resize can break, from the edges: a handle that
// is no memory or that cannot be read, a fixed window, no request, another
// size than the asked one (one pixel off, and the largest word), a size
// past limits that a Resizable narrowed, memory one byte too small, and a
// second answer after the first. The answer that holds comes last.
@(test)
surface_resize_refusal_refuses_each_broken_rule :: proc(t: ^testing.T) {
	Case :: struct {
		facts:   Surface_Resize_Facts,
		refusal: Surface_Resize_Refusal,
	}
	cases: [12]Case
	for &each in cases {
		each.facts = answer_of_test()
	}
	cases[0].facts.is_memory, cases[0].refusal = false, .Not_Memory
	cases[1].facts.readable, cases[1].refusal = false, .No_Read
	cases[2].facts.resizable, cases[2].refusal = false, .Not_Resizable
	cases[3].facts.asked, cases[3].refusal = false, .Not_Asked
	cases[4].facts.width, cases[4].refusal = 881, .Other_Size
	cases[5].facts.height, cases[5].refusal = 383, .Other_Size
	cases[6].facts.width, cases[6].refusal = max(u64), .Other_Size
	cases[7].facts.width, cases[7].refusal = 0, .Other_Size
	cases[8].facts.limits.largest_width, cases[8].refusal = 872, .Outside_Limits
	cases[9].facts.limits.least_height, cases[9].refusal = 392, .Outside_Limits
	cases[10].facts.memory_bytes, cases[10].refusal = 880 * 384 * SURFACE_BYTES_FOR_EACH_PIXEL - 1, .Too_Small
	cases[11].facts.memory_bytes, cases[11].refusal = 0, .Too_Small
	for each, index in cases {
		refusal := surface_resize_refusal(each.facts)
		testing.expectf(t, refusal == each.refusal, "case %d gives %v, not %v", index, refusal, each.refusal)
	}
	// The first answer is taken; the compositor then clears the request,
	// so the same record a second time is refused.
	facts := answer_of_test()
	testing.expect_value(t, surface_resize_refusal(facts), Surface_Resize_Refusal.None)
	facts.asked = false
	testing.expect_value(t, surface_resize_refusal(facts), Surface_Resize_Refusal.Not_Asked)
	// The edges that hold: the size at each limit, and memory larger than
	// needed.
	facts = answer_of_test()
	facts.width, facts.asked_width = 1216, 1216
	facts.height, facts.asked_height = 336, 336
	facts.memory_bytes = 1216 * 336 * SURFACE_BYTES_FOR_EACH_PIXEL
	testing.expect_value(t, surface_resize_refusal(facts), Surface_Resize_Refusal.None)
	facts.memory_bytes += 4096
	testing.expect_value(t, surface_resize_refusal(facts), Surface_Resize_Refusal.None)
}

// A window that took a new surface and keeps the edges at its right: its
// left edge can be left of the screen, or its title over the bar. The rule
// of the places brings it back where its title can be taken.
@(test)
resized_window_place_is_kept_on_screen :: proc(t: ^testing.T) {
	frame := Window_Frame{outer_width = 1216 + FRAME_WIDTH_OF_TEST, border = BORDER_OF_TEST, close_size = 24, title_height = 24}
	places := [?][2]int{{-2000, -2000}, {-1216, 0}, {0, HEIGHT - 1}, {SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST}}
	for place in places {
		x, y := window_place_kept(place[0], place[1], frame, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
		title_end := x + frame.outer_width - frame.border - frame.close_size
		testing.expectf(t, y >= HEIGHT && title_end >= TITLE_KEPT && x <= SCREEN_WIDTH_OF_TEST - TITLE_KEPT, "the place %v gives %d,%d", place, x, y)
	}
}
