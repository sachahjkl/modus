#+build !freestanding
package sample_history

import "modus:contract/draw_record"
import "core:testing"

// The box of a graph of the window of monitor.
TEST_BOX :: Graph_Box{left = 216, top = 120, width = 288, height = 40}

// The places of the edges of the curve in TEST_BOX, as curve_place states
// them: 1 pixel inside each edge, in units.
TEST_LEFT :: i32((216 + 1) * UNITS)
TEST_RIGHT :: i32((216 + 288 - 1) * UNITS)
TEST_TOP :: i32((120 + 1) * UNITS)
TEST_BASE :: i32((120 + 40 - 1) * UNITS)

// points_valid says if the border of the points of the draw record reads
// the points as one path.
points_valid :: proc(points: []Path_Point) -> bool {
	records: [AREA_POINT_CAPACITY]draw_record.Path_Point_Record
	for point, index in points {
		records[index] = {command = u32(point.command), x = point.x, y = point.y}
	}
	return draw_record.path_points_check(records[:len(points)]) == .None
}

// A box that cannot hold a graph is refused, and the history keeps what it
// held. The edges: a side of 0, 1, under the least, negative, the largest
// side; a negative edge; an edge one past the limit. Then the least box.
@(test)
a_box_that_holds_no_graph_is_refused :: proc(t: ^testing.T) {
	history: Sample_History
	testing.expect(t, sample_history_start(&history, .Rounded_Up, TEST_BOX))
	testing.expect(t, sample_history_push(&history, 7, 0))
	kept := history
	boxes := [?]Graph_Box {
		{0, 0, 0, 10},
		{0, 0, 1, 10},
		{0, 0, BOX_SIDE_LEAST - 1, 10},
		{0, 0, -1, 10},
		{0, 0, max(int), 10},
		{0, 0, 10, 0},
		{0, 0, 10, BOX_SIDE_LEAST - 1},
		{0, 0, 10, -1},
		{0, 0, 10, max(int)},
		{-1, 0, 10, 10},
		{0, -1, 10, 10},
		{min(int), 0, 10, 10},
		{draw_record.COORDINATE_LIMIT - 10 + 1, 0, 10, 10},
		{0, draw_record.COORDINATE_LIMIT - 10 + 1, 10, 10},
	}
	for box in boxes {
		testing.expectf(t, !sample_history_start(&history, .Fixed, box), "the box %v is taken", box)
		testing.expectf(t, history == kept, "the refused box %v changed the history", box)
	}
	testing.expect(t, sample_history_start(&history, .Fixed, {draw_record.COORDINATE_LIMIT - 10, draw_record.COORDINATE_LIMIT - 10, 10, 10}))
	testing.expect(t, sample_history_start(&history, .Fixed, {0, 0, BOX_SIDE_LEAST, BOX_SIDE_LEAST}))
	testing.expect_value(t, history.count, 0)
}

// A push into a history that was never started, and a Fixed top of 0, are
// refused: nothing changes.
@(test)
a_push_with_no_box_or_no_top_is_refused :: proc(t: ^testing.T) {
	never: Sample_History
	testing.expect(t, !sample_history_push(&never, 5, 100))
	testing.expect_value(t, never.count, 0)
	testing.expect(t, never == Sample_History{})

	history: Sample_History
	testing.expect(t, sample_history_start(&history, .Fixed, TEST_BOX))
	testing.expect(t, sample_history_push(&history, 5, 100))
	testing.expect(t, sample_history_push(&history, 6, 100))
	kept := history
	testing.expect(t, !sample_history_push(&history, 7, 0))
	testing.expect(t, history == kept)
}

// An empty history has no curve, and its top is 1, so the scale has a top.
@(test)
an_empty_history_draws_no_curve :: proc(t: ^testing.T) {
	for scale in Scale {
		history: Sample_History
		testing.expect(t, sample_history_start(&history, scale, TEST_BOX))
		testing.expect_value(t, history.count, 0)
		testing.expect_value(t, history.stroke_count, 0)
		testing.expect_value(t, history.area_count, 0)
		testing.expect_value(t, history.top, 1)
	}
}

// One sample: no segment, so no curve; the top already follows it.
@(test)
one_sample_draws_no_curve :: proc(t: ^testing.T) {
	history: Sample_History
	testing.expect(t, sample_history_start(&history, .Rounded_Up, TEST_BOX))
	testing.expect(t, sample_history_push(&history, 1873, 0))
	testing.expect_value(t, history.count, 1)
	testing.expect_value(t, history.stroke_count, 0)
	testing.expect_value(t, history.area_count, 0)
	testing.expect_value(t, history.top, 2000)
}

// Two samples: one segment, the newest at the right edge and the one
// before one step to its left; the area is closed on the base.
@(test)
two_samples_draw_one_segment :: proc(t: ^testing.T) {
	history: Sample_History
	testing.expect(t, sample_history_start(&history, .Fixed, TEST_BOX))
	testing.expect(t, sample_history_push(&history, 0, 100))
	testing.expect(t, sample_history_push(&history, 100, 100))
	testing.expect_value(t, history.stroke_count, 2)
	testing.expect_value(t, history.area_count, 5)
	step := (TEST_RIGHT - TEST_LEFT) / (SAMPLE_HISTORY_LENGTH - 1)
	testing.expect_value(t, history.stroke[0], Path_Point{command = .Move, x = TEST_RIGHT - step, y = TEST_BASE})
	testing.expect_value(t, history.stroke[1], Path_Point{command = .Line, x = TEST_RIGHT, y = TEST_TOP})
	testing.expect_value(t, history.area[0], Path_Point{command = .Move, x = TEST_RIGHT - step, y = TEST_BASE})
	testing.expect_value(t, history.area[3], Path_Point{command = .Line, x = TEST_RIGHT, y = TEST_BASE})
	testing.expect_value(t, history.area[4], Path_Point{command = .Close})
	testing.expect(t, points_valid(history.stroke[:history.stroke_count]))
	testing.expect(t, points_valid(history.area[:history.area_count]))
}

// A full history and one more sample: the oldest value leaves, the count
// stays, the oldest kept value is at the left edge and the newest at the
// right edge, and both paths stay within the limit of a path.
@(test)
a_full_history_and_one_more_sample :: proc(t: ^testing.T) {
	history: Sample_History
	testing.expect(t, sample_history_start(&history, .Rounded_Up, TEST_BOX))
	for value in 0 ..< SAMPLE_HISTORY_LENGTH + 1 {
		testing.expect(t, sample_history_push(&history, u64(value), 0))
	}
	testing.expect_value(t, history.count, SAMPLE_HISTORY_LENGTH)
	testing.expect_value(t, value_at(&history, 0), 1)
	testing.expect_value(t, value_at(&history, SAMPLE_HISTORY_LENGTH - 1), SAMPLE_HISTORY_LENGTH)
	testing.expect_value(t, history.top, rounded_top(SAMPLE_HISTORY_LENGTH))
	testing.expect_value(t, history.stroke_count, SAMPLE_HISTORY_LENGTH)
	testing.expect_value(t, history.area_count, SAMPLE_HISTORY_LENGTH + 3)
	testing.expect_value(t, history.stroke[0].x, TEST_LEFT)
	testing.expect_value(t, history.stroke[SAMPLE_HISTORY_LENGTH - 1].x, TEST_RIGHT)
	testing.expect(t, points_valid(history.stroke[:history.stroke_count]))
	testing.expect(t, points_valid(history.area[:history.area_count]))
	// The value that left no longer sets the top: a peak leaves with it.
	peak: Sample_History
	testing.expect(t, sample_history_start(&peak, .Rounded_Up, TEST_BOX))
	testing.expect(t, sample_history_push(&peak, 9000, 0))
	for _ in 0 ..< SAMPLE_HISTORY_LENGTH {
		testing.expect(t, sample_history_push(&peak, 3, 0))
	}
	testing.expect_value(t, peak.top, 5)
}

// A value of 0 lies on the base, a value at the top on the top edge, and a
// value past a fixed top on the top edge, never above it.
@(test)
the_edges_of_the_vertical_scale :: proc(t: ^testing.T) {
	history: Sample_History
	testing.expect(t, sample_history_start(&history, .Fixed, TEST_BOX))
	testing.expect(t, sample_history_push(&history, 0, 512))
	testing.expect(t, sample_history_push(&history, 512, 512))
	testing.expect_value(t, history.stroke[0].y, TEST_BASE)
	testing.expect_value(t, history.stroke[1].y, TEST_TOP)
	testing.expect(t, sample_history_push(&history, 513, 512))
	testing.expect_value(t, history.stroke[2].y, TEST_TOP)
	testing.expect(t, sample_history_push(&history, max(u64), 512))
	testing.expect_value(t, history.stroke[3].y, TEST_TOP)
}

// The largest value: a fixed top of the largest value, and a rounded top,
// with no product that wraps.
@(test)
the_largest_value :: proc(t: ^testing.T) {
	fixed: Sample_History
	testing.expect(t, sample_history_start(&fixed, .Fixed, TEST_BOX))
	testing.expect(t, sample_history_push(&fixed, max(u64), max(u64)))
	testing.expect(t, sample_history_push(&fixed, max(u64) / 2, max(u64)))
	testing.expect_value(t, fixed.stroke[0].y, TEST_TOP)
	middle := TEST_BASE - (TEST_BASE - TEST_TOP) / 2
	testing.expectf(t, abs(fixed.stroke[1].y - middle) <= 1, "half the largest value at %d, not near %d", fixed.stroke[1].y, middle)

	rounded: Sample_History
	testing.expect(t, sample_history_start(&rounded, .Rounded_Up, TEST_BOX))
	testing.expect(t, sample_history_push(&rounded, 0, 0))
	testing.expect(t, sample_history_push(&rounded, max(u64), 0))
	testing.expect_value(t, rounded.top, ROUNDED_TOP_LARGEST)
	testing.expect_value(t, rounded.stroke[0].y, TEST_BASE)
	testing.expect_value(t, rounded.stroke[1].y, TEST_TOP)

	testing.expect_value(t, height_of(max(u64), max(u64), 1), 1)
	testing.expect_value(t, height_of(0, max(u64), 1 << 29), 0)
	testing.expect_value(t, height_of(max(u64), max(u64), 1 << 29), 1 << 29)
	testing.expect_value(t, height_of(5, 0, 100), 0)
}

// The top of a rounded scale at the edges of each step.
@(test)
rounded_top_at_its_edges :: proc(t: ^testing.T) {
	Case :: struct {
		value, top: u64,
	}
	cases := [?]Case {
		{0, 1},
		{1, 1},
		{2, 2},
		{3, 5},
		{5, 5},
		{6, 10},
		{10, 10},
		{11, 20},
		{999, 1000},
		{1000, 1000},
		{1001, 2000},
		{1873, 2000},
		{5_000_000_000_000_000_000, 5_000_000_000_000_000_000},
		{5_000_000_000_000_000_001, ROUNDED_TOP_LARGEST},
		{ROUNDED_TOP_LARGEST, ROUNDED_TOP_LARGEST},
		{ROUNDED_TOP_LARGEST + 1, ROUNDED_TOP_LARGEST},
		{max(u64), ROUNDED_TOP_LARGEST},
	}
	for test_case in cases {
		testing.expectf(t, rounded_top(test_case.value) == test_case.top, "%d: the top %d, not %d", test_case.value, rounded_top(test_case.value), test_case.top)
	}
}

// A rate refuses a time of 0, and saturates past 64 bits.
@(test)
rate_per_second_at_its_edges :: proc(t: ^testing.T) {
	_, ok := rate_per_second(10, 0)
	testing.expect(t, !ok)
	rate: u64
	rate, ok = rate_per_second(0, 500)
	testing.expect(t, ok && rate == 0)
	rate, ok = rate_per_second(1, 1)
	testing.expect(t, ok && rate == 1000)
	rate, ok = rate_per_second(500, 500)
	testing.expect(t, ok && rate == 1000)
	rate, ok = rate_per_second(max(u64) / 1000, 1)
	testing.expect(t, ok && rate == max(u64) / 1000 * 1000)
	rate, ok = rate_per_second(max(u64) / 1000 + 1, 1)
	testing.expect(t, ok && rate == max(u64))
	rate, ok = rate_per_second(max(u64), 1)
	testing.expect(t, ok && rate == max(u64))
	rate, ok = rate_per_second(max(u64), 1000)
	testing.expect(t, ok && rate == max(u64) / 1000 * 1000)
	rate, ok = rate_per_second(max(u64), max(u64))
	testing.expect(t, ok && rate == 1000)
}

// The processor time refuses a time of 0 and 0 processors, and saturates at
// 100 % at and past the whole time of the processors.
@(test)
processor_time_at_its_edges :: proc(t: ^testing.T) {
	_, ok := processor_time_percent(10, 0, 4)
	testing.expect(t, !ok)
	_, ok = processor_time_percent(10, 500, 0)
	testing.expect(t, !ok)
	percent: u64
	percent, ok = processor_time_percent(0, 500, 4)
	testing.expect(t, ok && percent == 0)
	percent, ok = processor_time_percent(1999, 500, 4)
	testing.expect(t, ok && percent == 99)
	percent, ok = processor_time_percent(2000, 500, 4)
	testing.expect(t, ok && percent == 100)
	percent, ok = processor_time_percent(2001, 500, 4)
	testing.expect(t, ok && percent == 100)
	percent, ok = processor_time_percent(max(u64), 500, 4)
	testing.expect(t, ok && percent == 100)
	// Past 64 bits the share is a quotient that rounds the whole down: one
	// more than its floor at most, and under 100 under the whole.
	percent, ok = processor_time_percent(max(u64) / 2, max(u64), max(u64))
	testing.expect(t, ok && percent == 50)
	percent, ok = processor_time_percent(max(u64) - 1, max(u64), 1)
	testing.expect(t, ok && percent == 99)
}

// A compact number has at most four digits and one suffix.
@(test)
compact_numbers_at_their_edges :: proc(t: ^testing.T) {
	Case :: struct {
		value: u64,
		text:  string,
	}
	cases := [?]Case {
		{0, "0"},
		{9, "9"},
		{10, "10"},
		{9999, "9999"},
		{10_000, "10k"},
		{20_000, "20k"},
		{999_999, "999k"},
		{9_999_999, "9999k"},
		{10_000_000, "10M"},
		{ROUNDED_TOP_LARGEST, "10E"},
		{max(u64), "18E"},
	}
	for test_case in cases {
		buffer: [COMPACT_TEXT_SIZE]u8
		text := compact_number_text(&buffer, test_case.value)
		testing.expectf(t, text == test_case.text, "%d: %q, not %q", test_case.value, text, test_case.text)
	}
}

// A box that cannot hold a graph, and a history that no start made, are
// refused by a move: the history keeps its box and its curve. The edges: a
// side under the least, a negative edge, an edge one past the limit.
@(test)
a_move_to_a_box_that_holds_no_graph_is_refused :: proc(t: ^testing.T) {
	never_started: Sample_History
	testing.expect(t, !sample_history_box_set(&never_started, TEST_BOX))
	testing.expect(t, !never_started.started && never_started.box == {})

	history: Sample_History
	testing.expect(t, sample_history_start(&history, .Rounded_Up, TEST_BOX))
	testing.expect(t, sample_history_push(&history, 3, 0))
	testing.expect(t, sample_history_push(&history, 9, 0))
	kept := history
	boxes := [?]Graph_Box {
		{0, 0, 0, 10},
		{0, 0, BOX_SIDE_LEAST - 1, 10},
		{0, 0, 10, BOX_SIDE_LEAST - 1},
		{-1, 0, 10, 10},
		{0, -1, 10, 10},
		{draw_record.COORDINATE_LIMIT - 9, 0, 10, 10},
		{0, draw_record.COORDINATE_LIMIT - 9, 10, 10},
	}
	for box in boxes {
		testing.expectf(t, !sample_history_box_set(&history, box), "the box %v is taken", box)
		testing.expectf(t, history == kept, "the box %v changed the history", box)
	}
}

// A move to the same box changes nothing. A move to another box places the
// curve of the kept values in the new box, as a history that was in that
// box from its start: no value is lost, and the scale stays.
@(test)
a_move_places_the_kept_curve_in_the_new_box :: proc(t: ^testing.T) {
	moved_box := Graph_Box{left = 240, top = 144, width = 480, height = 40}
	moved, direct: Sample_History
	testing.expect(t, sample_history_start(&moved, .Rounded_Up, TEST_BOX))
	testing.expect(t, sample_history_start(&direct, .Rounded_Up, moved_box))
	for value in ([?]u64{4, 17, 0, 250}) {
		testing.expect(t, sample_history_push(&moved, value, 0))
		testing.expect(t, sample_history_push(&direct, value, 0))
	}
	kept := moved
	testing.expect(t, sample_history_box_set(&moved, TEST_BOX))
	testing.expect(t, moved == kept)
	testing.expect(t, sample_history_box_set(&moved, moved_box))
	testing.expect(t, moved == direct)
	testing.expect(t, points_valid(moved.stroke[:moved.stroke_count]) && points_valid(moved.area[:moved.area_count]))
	right := i32((moved_box.left + moved_box.width - 1) * UNITS)
	testing.expect_value(t, moved.stroke[moved.stroke_count - 1].x, right)
}
