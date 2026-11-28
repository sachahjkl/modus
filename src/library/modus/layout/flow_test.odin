#+build !freestanding
package layout

import "core:testing"

@(test)
flow_wrap_refuses_invalid_inputs_without_mutation :: proc(t: ^testing.T) {
	items := [?]Flow_Item{{width = 40, height = 20}, {width = 50, height = 20}}
	places := [2]Flow_Place{{x = 99, y = 99}, {x = 88, y = 88}}

	// Unknown Align enum member refused.
	_, _, st := flow_wrap(items[:], places[:], {0, 0, 200, 100}, 4, 4, Align(99))
	testing.expect_value(t, st, Box_Status.Unknown_Member)
	testing.expect_value(t, places[0].x, i32(99))

	// Places slice shorter than items refused.
	_, _, st = flow_wrap(items[:], places[:1], {0, 0, 200, 100}, 4, 4)
	testing.expect_value(t, st, Box_Status.Places_Too_Few)

	// Negative gap or item dimension refused.
	_, _, st = flow_wrap(items[:], places[:], {0, 0, 200, 100}, -1, 4)
	testing.expect_value(t, st, Box_Status.Length_Refused)

	bad_items := [?]Flow_Item{{width = -5, height = 20}}
	_, _, st = flow_wrap(bad_items[:], places[:], {0, 0, 200, 100}, 4, 4)
	testing.expect_value(t, st, Box_Status.Length_Refused)

	huge_items := [?]Flow_Item{{width = LENGTH_LIMIT + 1, height = 20}}
	_, _, st = flow_wrap(huge_items[:], places[:], {0, 0, 200, 100}, 4, 4)
	testing.expect_value(t, st, Box_Status.Length_Refused)
}

@(test)
flow_wrap_wraps_lines_and_aligns_start_center_end :: proc(t: ^testing.T) {
	items := [?]Flow_Item{
		{width = 60, height = 20},
		{width = 60, height = 28},
		{width = 50, height = 20},
	}
	places: [3]Flow_Place

	// Width 130 fits item 0 (60) + gap (8) + item 1 (60) = 128 on line 0, wraps item 2 to line 1.
	h, lines, st := flow_wrap(items[:], places[:], {10, 20, 130, 200}, 8, 6, .Start)
	testing.expect_value(t, st, Box_Status.Done)
	testing.expect_value(t, lines, i32(2))
	testing.expect_value(t, h, i32(28 + 6 + 20))
	testing.expect_value(t, places[0].line, i32(0))
	testing.expect_value(t, places[0].x, i32(10))
	testing.expect_value(t, places[0].y, i32(24)) // Vertically centered inside 28 px row.
	testing.expect_value(t, places[1].line, i32(0))
	testing.expect_value(t, places[1].x, i32(78))
	testing.expect_value(t, places[2].line, i32(1))
	testing.expect_value(t, places[2].x, i32(10))
	testing.expect_value(t, places[2].y, i32(20 + 28 + 6))

	// .Center alignment centers row 1 (50 px inside 130 px -> +40 px).
	_, _, st = flow_wrap(items[:], places[:], {10, 20, 130, 200}, 8, 6, .Center)
	testing.expect_value(t, st, Box_Status.Done)
	testing.expect_value(t, places[2].x, i32(10 + 40))

	// .End alignment right-aligns row 1 (130 - 50 = +80 px).
	_, _, st = flow_wrap(items[:], places[:], {10, 20, 130, 200}, 8, 6, .End)
	testing.expect_value(t, st, Box_Status.Done)
	testing.expect_value(t, places[2].x, i32(10 + 80))

	// Empty item slice returns zero height and zero lines cleanly.
	eh, elines, est := flow_wrap(nil, nil, {0, 0, 100, 100}, 4, 4)
	testing.expect_value(t, est, Box_Status.Done)
	testing.expect_value(t, eh, i32(0))
	testing.expect_value(t, elines, i32(0))
}
