#+build !freestanding
#+build !modus
package draw_record

import "core:math"
import "core:testing"

@(private = "file")
point_of :: proc(command: Path_Command, x: i32 = 0, y: i32 = 0) -> Path_Point_Record {
	return {command = u32(command), x = x, y = y}
}

// The most points of one case of this file but the cases of the count.
@(private = "file")
CASE_POINTS :: 8

// expect_refused gives the points to the border, with a copy and with no
// copy, and checks the refusal: the problem expected from both, a count of
// 0, and the points of the caller unchanged.
@(private = "file")
expect_refused :: proc(t: ^testing.T, name: string, records: []Path_Point_Record, expected: Path_Problem) {
	kept: [CASE_POINTS]Path_Point_Record
	copy(kept[:], records)
	points: [CASE_POINTS]Path_Point
	count, problem := path_points_read(records, points[:])
	testing.expectf(t, problem == expected && count == 0, "%s: %v and %d points, not %v", name, problem, count, expected)
	checked := path_points_check(records)
	testing.expectf(t, checked == expected, "%s: the check gives %v, not %v", name, checked, expected)
	for record, index in records[:min(len(records), CASE_POINTS)] {
		testing.expectf(t, record == kept[index], "%s: the border changed the point %d", name, index)
	}
}

// Each word that names no command, at the first point and at a later one:
// 0, one past the largest command, and the largest u32.
@(test)
path_points_refuse_a_word_that_names_no_command :: proc(t: ^testing.T) {
	words := [3]u32{0, u32(max(Path_Command)) + 1, max(u32)}
	for word in words {
		first := [2]Path_Point_Record{{command = word}, point_of(.Line, 64, 64)}
		expect_refused(t, "an unknown first command", first[:], .Unknown_Command)
		later := [3]Path_Point_Record{point_of(.Move), point_of(.Line, 64, 64), {command = word, x = 128}}
		expect_refused(t, "an unknown later command", later[:], .Unknown_Command)
	}
	for word in u32(0) ..= u32(max(Path_Command)) + 1 {
		_, known := path_command_of_word(word)
		testing.expectf(t, known == (word >= u32(min(Path_Command)) && word <= u32(max(Path_Command))), "the word %d", word)
	}
}

// The count of points: 0, 1, one past PATH_POINT_LIMIT, and a copy with
// room for fewer points than the records.
@(test)
path_points_refuse_a_count_out_of_its_bounds :: proc(t: ^testing.T) {
	expect_refused(t, "no point", nil, .Count_Out_Of_Range)
	one := [1]Path_Point_Record{point_of(.Move)}
	expect_refused(t, "one point", one[:], .Count_Out_Of_Range)
	many: [PATH_POINT_LIMIT + 1]Path_Point_Record
	many[0] = point_of(.Move)
	for index in 1 ..< len(many) {
		many[index] = point_of(.Line, i32(index), i32(index % 3))
	}
	points: [PATH_POINT_LIMIT + 1]Path_Point
	count, problem := path_points_read(many[:], points[:])
	testing.expectf(t, problem == .Count_Out_Of_Range && count == 0, "one point past the limit: %v, %d", problem, count)
	testing.expect_value(t, path_points_check(many[:]), Path_Problem.Count_Out_Of_Range)
	two := [2]Path_Point_Record{point_of(.Move), point_of(.Line, 1, 1)}
	small: [1]Path_Point
	count, problem = path_points_read(two[:], small[:])
	testing.expectf(t, problem == .Count_Out_Of_Range && count == 0, "a copy too small: %v", problem)
	// The limit itself is read.
	count, problem = path_points_read(many[:PATH_POINT_LIMIT], points[:])
	testing.expectf(t, problem == .None && count == PATH_POINT_LIMIT, "the limit of points: %v, %d", problem, count)
	testing.expect_value(t, points[PATH_POINT_LIMIT - 1], Path_Point{command = .Line, x = PATH_POINT_LIMIT - 1, y = (PATH_POINT_LIMIT - 1) % 3})
}

// The order of the commands: a first point that is not a Move, a subpath
// with no segment, a curve with no end, a Close out of its place.
@(test)
path_points_refuse_an_order_that_the_contract_forbids :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		points:   []Path_Point_Record,
		expected: Path_Problem,
	}
	line_first := [2]Path_Point_Record{point_of(.Line), point_of(.Line, 64)}
	curve_first := [3]Path_Point_Record{point_of(.Curve_Control), point_of(.Line, 64), point_of(.Line, 64, 64)}
	close_first := [3]Path_Point_Record{point_of(.Close), point_of(.Move), point_of(.Line, 64)}
	two_moves := [3]Path_Point_Record{point_of(.Move), point_of(.Move, 64), point_of(.Line, 64, 64)}
	move_last := [3]Path_Point_Record{point_of(.Move), point_of(.Line, 64), point_of(.Move, 128)}
	move_close := [3]Path_Point_Record{point_of(.Move), point_of(.Close), point_of(.Line, 64)}
	curve_last := [2]Path_Point_Record{point_of(.Move), point_of(.Curve_Control, 64, 64)}
	two_controls := [4]Path_Point_Record{point_of(.Move), point_of(.Curve_Control, 64), point_of(.Curve_Control, 64, 64), point_of(.Line, 128)}
	control_move := [4]Path_Point_Record{point_of(.Move), point_of(.Curve_Control, 64), point_of(.Move, 64, 64), point_of(.Line, 128)}
	control_close := [3]Path_Point_Record{point_of(.Move), point_of(.Curve_Control, 64), point_of(.Close)}
	line_after_close := [4]Path_Point_Record{point_of(.Move), point_of(.Line, 64), point_of(.Close), point_of(.Line, 64, 64)}
	two_closes := [4]Path_Point_Record{point_of(.Move), point_of(.Line, 64), point_of(.Close), point_of(.Close)}
	control_after_close := [5]Path_Point_Record{point_of(.Move), point_of(.Line, 64), point_of(.Close), point_of(.Curve_Control, 1), point_of(.Line, 2)}
	cases := [?]Case {
		{"a Line first", line_first[:], .Not_Started_By_Move},
		{"a Curve_Control first", curve_first[:], .Not_Started_By_Move},
		{"a Close first", close_first[:], .Not_Started_By_Move},
		{"two Moves", two_moves[:], .Empty_Subpath},
		{"a Move last", move_last[:], .Empty_Subpath},
		{"a Close after a Move", move_close[:], .Empty_Subpath},
		{"a Curve_Control last", curve_last[:], .Curve_Without_End},
		{"two Curve_Control", two_controls[:], .Curve_Without_End},
		{"a Move after a Curve_Control", control_move[:], .Curve_Without_End},
		{"a Close after a Curve_Control", control_close[:], .Curve_Without_End},
		{"a Line after a Close", line_after_close[:], .Close_Out_Of_Place},
		{"two Closes", two_closes[:], .Close_Out_Of_Place},
		{"a Curve_Control after a Close", control_after_close[:], .Close_Out_Of_Place},
	}
	for item in cases {
		expect_refused(t, item.name, item.points, item.expected)
	}
}

// The places: a point one unit past COORDINATE_LIMIT, and the largest and
// the smallest i32, on each axis, for each command that has a place; a
// Close whose x or y is not 0, even inside the limit. The problems come in
// the order of the checks of one point: the command, the limit, the place
// of a Close, then the order.
@(test)
path_points_refuse_a_place_past_its_bound :: proc(t: ^testing.T) {
	past := [4]i32{COORDINATE_UNIT_LIMIT + 1, -COORDINATE_UNIT_LIMIT - 1, max(i32), min(i32)}
	commands := [3]Path_Command{.Move, .Line, .Curve_Control}
	// The point of each command: the Move at 0, a Line at 3, the
	// Curve_Control at 1.
	places := [3]int{0, 3, 1}
	for value in past {
		for command, index in commands {
			for axis in 0 ..< 2 {
				points := [4]Path_Point_Record{point_of(.Move), point_of(.Curve_Control, 64), point_of(.Line, 64, 64), point_of(.Line, 0, 64)}
				place := places[index]
				points[place].command = u32(command)
				if axis == 0 {
					points[place].x = value
				} else {
					points[place].y = value
				}
				expect_refused(t, "a place past the limit", points[:], .Point_Past_Coordinate_Limit)
			}
		}
		closing := [3]Path_Point_Record{point_of(.Move), point_of(.Line, 64), point_of(.Close, value, 0)}
		expect_refused(t, "a Close past the limit", closing[:], .Point_Past_Coordinate_Limit)
	}
	off_zero := [4][2]i32{{1, 0}, {0, 1}, {-1, 0}, {0, COORDINATE_UNIT_LIMIT}}
	for place in off_zero {
		closing := [3]Path_Point_Record{point_of(.Move), point_of(.Line, 64), point_of(.Close, place[0], place[1])}
		expect_refused(t, "a Close whose place is not 0", closing[:], .Close_Point_Not_Zero)
	}
	// A Close first, off 0: the place is checked before the order.
	close_first := [2]Path_Point_Record{point_of(.Close, 1, 0), point_of(.Line, 64)}
	expect_refused(t, "a Close first off 0", close_first[:], .Close_Point_Not_Zero)
	// An unknown command past the limit: the command is checked first.
	both := [2]Path_Point_Record{{command = 0, x = max(i32)}, point_of(.Line, 64)}
	expect_refused(t, "an unknown command past the limit", both[:], .Unknown_Command)
}

// The points that the border reads, last: the limits of the places, a
// curve, a Close, two subpaths, and a subpath with no Close. The copy holds
// each point as its record.
@(test)
path_points_read_each_valid_form :: proc(t: ^testing.T) {
	L :: COORDINATE_UNIT_LIMIT
	records := [?]Path_Point_Record {
		point_of(.Move, -L, -L),
		point_of(.Line, L, -L),
		point_of(.Curve_Control, L, L),
		point_of(.Line, -L, L),
		point_of(.Close),
		point_of(.Move, 5, 7),
		point_of(.Line, 5, 7),
	}
	points: [len(records)]Path_Point
	count, problem := path_points_read(records[:], points[:])
	testing.expectf(t, problem == .None && count == len(records), "%v, %d", problem, count)
	testing.expect_value(t, path_points_check(records[:]), Path_Problem.None)
	for record, index in records {
		command, _ := path_command_of_word(record.command)
		testing.expectf(t, points[index] == Path_Point{command = command, x = record.x, y = record.y}, "the point %d", index)
	}
}

// The count of the segments of a curve: a curve on its chord is 1 segment;
// the bend at 4 * CURVE_TOLERANCE_UNITS * n * n is n segments and one unit
// more is n + 1; a bend past the limit, and the farthest control point,
// are CURVE_SEGMENT_LIMIT.
@(test)
curve_segment_count_at_its_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, curve_segment_count(0, 0, 640, 320, 1280, 640), 1)
	PER :: 4 * CURVE_TOLERANCE_UNITS
	for segments in 1 ..< CURVE_SEGMENT_LIMIT {
		bend := i32(PER * segments * segments)
		// The bend of a curve from 0 to 0 with its control at -bend / 2 on x.
		testing.expectf(t, curve_segment_count(0, 0, -bend / 2, 0, 0, 0) == segments, "a bend of %d", bend)
		testing.expectf(t, curve_segment_count(0, 0, -(bend + 2) / 2, 0, 0, 0) == segments + 1, "a bend of %d", bend + 2)
	}
	testing.expect_value(t, curve_segment_count(0, 0, 0, -i32(PER * CURVE_SEGMENT_LIMIT * CURVE_SEGMENT_LIMIT), 0, 0), CURVE_SEGMENT_LIMIT)
	L :: COORDINATE_UNIT_LIMIT
	testing.expect_value(t, curve_segment_count(-L, -L, L, L, -L, -L), CURVE_SEGMENT_LIMIT)
	testing.expect_value(t, curve_segment_count(-L, L, L, -L, L, L), CURVE_SEGMENT_LIMIT)
}

// The segments of a curve stay within the stated distance of the curve:
// CURVE_TOLERANCE_UNITS when the bend is at most 4 * CURVE_TOLERANCE_UNITS
// * CURVE_SEGMENT_LIMIT^2, else the bend over 4 * CURVE_SEGMENT_LIMIT^2;
// each with the rounding of each point to a unit, at most 1 unit. The curve
// is sampled at 2 048 places, in floats, against the nearest segment. The
// first and the last point are the ends, and each point is inside the box
// of the three points.
@(test)
curve_segments_stay_within_the_stated_distance :: proc(t: ^testing.T) {
	L :: COORDINATE_UNIT_LIMIT
	curves := [?][6]i32 {
		{0, 0, 640, 0, 640, 640},
		{0, 0, 3000, -3000, 6000, 0},
		{0, 0, 4096, 0, 0, 1},
		{100, 100, 101, 99, 103, 100},
		{-L, 0, 0, L, L, 0},
		{0, 0, L, -L, 7, 9},
		{-L, -L, L, L, -L, -L},
	}
	for curve, index in curves {
		start_x, start_y, control_x, control_y, end_x, end_y := curve[0], curve[1], curve[2], curve[3], curve[4], curve[5]
		count := curve_segment_count(start_x, start_y, control_x, control_y, end_x, end_y)
		bend := abs(f64(start_x) - 2 * f64(control_x) + f64(end_x)) + abs(f64(start_y) - 2 * f64(control_y) + f64(end_y))
		bound := f64(CURVE_TOLERANCE_UNITS)
		if count == CURVE_SEGMENT_LIMIT {
			bound = max(bound, bend / (4 * CURVE_SEGMENT_LIMIT * CURVE_SEGMENT_LIMIT))
		}
		bound += 1
		xs, ys: [CURVE_SEGMENT_LIMIT + 1]f64
		for step in 0 ..= count {
			x, y := curve_point(start_x, start_y, control_x, control_y, end_x, end_y, step, count)
			xs[step], ys[step] = f64(x), f64(y)
			inside := x >= min(start_x, control_x, end_x) && x <= max(start_x, control_x, end_x) && y >= min(start_y, control_y, end_y) && y <= max(start_y, control_y, end_y)
			testing.expectf(t, inside, "the curve %d: the point %d is outside the box of the curve", index, step)
		}
		testing.expectf(t, xs[0] == f64(start_x) && ys[0] == f64(start_y) && xs[count] == f64(end_x) && ys[count] == f64(end_y), "the curve %d does not run from its start to its end", index)
		farthest := 0.0
		SAMPLES :: 2048
		for sample in 0 ..= SAMPLES {
			along := f64(sample) / SAMPLES
			before := 1 - along
			x := before * before * f64(start_x) + 2 * along * before * f64(control_x) + along * along * f64(end_x)
			y := before * before * f64(start_y) + 2 * along * before * f64(control_y) + along * along * f64(end_y)
			nearest := math.F64_MAX
			for step in 0 ..< count {
				nearest = min(nearest, distance_to_segment(x, y, xs[step], ys[step], xs[step + 1], ys[step + 1]))
			}
			farthest = max(farthest, nearest)
		}
		testing.expectf(t, farthest <= bound, "the curve %d of %d segments: %.2f units from the curve, past %.2f", index, count, farthest, bound)
	}
}

@(private = "file")
distance_to_segment :: proc(x, y, from_x, from_y, to_x, to_y: f64) -> f64 {
	along_x, along_y := to_x - from_x, to_y - from_y
	length := along_x * along_x + along_y * along_y
	part := length == 0 ? 0 : clamp(((x - from_x) * along_x + (y - from_y) * along_y) / length, 0, 1)
	near_x, near_y := from_x + part * along_x - x, from_y + part * along_y - y
	return math.sqrt(near_x * near_x + near_y * near_y)
}

// divide_rounded rounds to the nearest, a half up, for each sign of the
// numerator.
@(test)
divide_rounded_at_the_halves :: proc(t: ^testing.T) {
	Case :: struct {
		numerator, denominator, expected: i64,
	}
	cases := [?]Case{{1, 2, 1}, {-1, 2, 0}, {3, 2, 2}, {-3, 2, -1}, {-5, 4, -1}, {-6, 4, -1}, {-7, 4, -2}, {0, 7, 0}, {13, 1, 13}, {-13, 1, -13}, {1 << 61, 3, ((1 << 61) + 1) / 3}}
	for item in cases {
		testing.expectf(t, divide_rounded(item.numerator, item.denominator) == item.expected, "%d / %d", item.numerator, item.denominator)
	}
}
