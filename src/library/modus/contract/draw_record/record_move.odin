package draw_record

// The move of a record by a step, in 1/64 pixel. The window layer of the
// interface package moves each record of a frame by the scroll of a window
// whose layout is larger than its view (src/md/features/window_scroll.md):
// the drawing module then draws the moved table as any table, and its
// export needs no origin. The box moves, and each place in the fields of
// its kind: the cell of a pattern, the two points of a gradient, the origin
// of a text. The points of a path are in the text table, and
// path_points_move moves them.

// record_moved gives the record moved by (step_x, step_y). A record with no
// box (None, Clip_Pop, Element_Pop) stays as it is. A record that read
// refuses, and a record whose box or place the step takes past
// COORDINATE_LIMIT, stays as it is with ok false: the move never makes a
// record that the border refuses from one that it took.
record_moved :: proc "contextless" (record: Draw_Record, step_x, step_y: i32) -> (moved: Draw_Record, ok: bool) {
	primitive, problem := read(record)
	if problem != .None {
		return record, false
	}
	left, left_ok := place_moved(record.left, step_x)
	top, top_ok := place_moved(record.top, step_y)
	right, right_ok := place_moved(record.right, step_x)
	bottom, bottom_ok := place_moved(record.bottom, step_y)
	if !left_ok || !top_ok || !right_ok || !bottom_ok {
		return record, false
	}
	switch &value in primitive {
	case Draw_Nothing, Draw_Clip_Pop, Draw_Element_Pop:
		return record, true
	case Draw_Clip_Push, Draw_Element_Push, Draw_Picture, Draw_Text_Grid, Draw_Path:
	case Draw_Rectangle:
		if value.repetition != {} {
			x, x_ok := place_moved(value.repetition.cell_x, step_x)
			y, y_ok := place_moved(value.repetition.cell_y, step_y)
			if !x_ok || !y_ok {
				return record, false
			}
			value.repetition.cell_x, value.repetition.cell_y = x, y
		}
	case Draw_Gradient:
		start_x, start_x_ok := place_moved(value.start_x, step_x)
		start_y, start_y_ok := place_moved(value.start_y, step_y)
		end_x, end_x_ok := place_moved(value.end_x, step_x)
		end_y, end_y_ok := place_moved(value.end_y, step_y)
		if !start_x_ok || !start_y_ok || !end_x_ok || !end_y_ok {
			return record, false
		}
		value.start_x, value.start_y, value.end_x, value.end_y = start_x, start_y, end_x, end_y
	case Draw_Text:
		origin_x, origin_ok := place_moved(value.origin_x, step_x)
		if !origin_ok {
			return record, false
		}
		value.origin_x = origin_x
	}
	return record_of(primitive, record.element, left, top, right, bottom), true
}

// path_points_move moves each point of a path by (step_x, step_y), in
// place. When a point would pass COORDINATE_LIMIT, no point moves and ok is
// false: a path never has some points moved and others not.
path_points_move :: proc "contextless" (points: []Path_Point_Record, step_x, step_y: i32) -> (ok: bool) {
	for point in points {
		if _, x_ok := place_moved(point.x, step_x); !x_ok {
			return false
		}
		if _, y_ok := place_moved(point.y, step_y); !y_ok {
			return false
		}
	}
	for &point in points {
		point.x += step_x
		point.y += step_y
	}
	return true
}

// place_moved gives a place moved by a step, or false past COORDINATE_LIMIT.
@(private)
place_moved :: proc "contextless" (place, step: i32) -> (moved: i32, ok: bool) {
	sum := i64(place) + i64(step)
	if sum < -COORDINATE_UNIT_LIMIT || sum > COORDINATE_UNIT_LIMIT {
		return place, false
	}
	return i32(sum), true
}
