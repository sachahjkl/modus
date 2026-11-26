#+build !freestanding
#+build !modus
package draw_record

import "core:testing"

// A step of one page of scroll up, in units: 300 pixels.
@(private = "file")
STEP_UP :: -300 * UNITS_PER_PIXEL

// The edges first: a record whose box the step takes one unit past
// COORDINATE_LIMIT, on each side, is refused and stays as it is; the box at
// the limit exactly is moved. A record that read refuses stays as it is.
@(test)
a_move_past_the_coordinate_limit_is_refused :: proc(t: ^testing.T) {
	at_top := record_of(Draw_Rectangle{color = 0xFF102030}, 0, 0, -COORDINATE_UNIT_LIMIT + 64, 640, 0)
	moved, ok := record_moved(at_top, 0, -64)
	testing.expect(t, ok && moved.top == -COORDINATE_UNIT_LIMIT)
	moved, ok = record_moved(at_top, 0, -65)
	testing.expect(t, !ok && moved == at_top)
	at_right := record_of(Draw_Rectangle{color = 0xFF102030}, 0, 0, 0, COORDINATE_UNIT_LIMIT, 64)
	moved, ok = record_moved(at_right, 1, 0)
	testing.expect(t, !ok && moved == at_right)
	moved, ok = record_moved(at_right, max(i32), max(i32))
	testing.expect(t, !ok && moved == at_right)
	unknown := at_right
	unknown.kind = 255
	moved, ok = record_moved(unknown, 0, STEP_UP)
	testing.expect(t, !ok && moved == unknown)
}

// A record with no box stays as it is; each other kind moves its box, and
// the places in its fields: the cell of a pattern, the points of a
// gradient, the origin of a text. A move and the move back give the record.
@(test)
a_move_moves_the_box_and_each_place_of_each_kind :: proc(t: ^testing.T) {
	for primitive in ([?]Draw_Primitive{Draw_Nothing{}, Draw_Clip_Pop{}, Draw_Element_Pop{}}) {
		record := record_of(primitive, 0, 0, 0, 0, 0)
		moved, ok := record_moved(record, 64, STEP_UP)
		testing.expectf(t, ok && moved == record, "%v moved", primitive)
	}
	rectangle := record_of(Draw_Rectangle{color = 0xFF102030}, 7, 640, 19200, 1280, 20480)
	moved, ok := record_moved(rectangle, 64, STEP_UP)
	testing.expect(t, ok && moved.left == 704 && moved.right == 1344 && moved.top == 0 && moved.bottom == 1280 && moved.element == 7)
	back, back_ok := record_moved(moved, -64, -STEP_UP)
	testing.expect(t, back_ok && back == rectangle)
	pattern := record_of(Draw_Rectangle{color = 0xFF102030, repetition = {cell_x = 640, cell_y = 19200, cell_width = 64, cell_height = 64, step_x = 256, step_y = 256}}, 0, 640, 19200, 2560, 25600)
	moved, ok = record_moved(pattern, 64, STEP_UP)
	read_pattern, _ := read(moved)
	testing.expect(t, ok && read_pattern.(Draw_Rectangle).repetition.cell_x == 704 && read_pattern.(Draw_Rectangle).repetition.cell_y == 0)
	gradient := record_of(Draw_Gradient{start_x = 0, start_y = 19200, end_x = 0, end_y = 25600, start_color = 0xFF000000, end_color = 0xFFFFFFFF}, 0, 0, 19200, 640, 25600)
	moved, ok = record_moved(gradient, 64, STEP_UP)
	read_gradient, _ := read(moved)
	line := read_gradient.(Draw_Gradient)
	testing.expect(t, ok && line.start_x == 64 && line.start_y == 0 && line.end_x == 64 && line.end_y == 6400)
	text := record_of(Draw_Text{first = 0, count = 1, color = 0xFFFFFFFF, origin_x = 640, font = .Cells_8x16, weight = .Regular, size = 1024}, 0, 640, 19200, 1152, 20224)
	moved, ok = record_moved(text, 64, STEP_UP)
	read_text, read_problem := read(moved)
	testing.expect(t, ok && read_problem == .None && read_text.(Draw_Text).origin_x == 704 && moved.top == 0)
}

// The points of a path move together: a point that the step would take
// past COORDINATE_LIMIT leaves every point where it was.
@(test)
the_points_of_a_path_move_together :: proc(t: ^testing.T) {
	points := [3]Path_Point_Record{{command = 0, x = 0, y = 19200}, {command = 1, x = 640, y = 25600}, {command = 1, x = 1280, y = 19200}}
	testing.expect(t, path_points_move(points[:], 64, STEP_UP))
	testing.expect(t, points[0].x == 64 && points[0].y == 0 && points[1].y == 6400 && points[2].x == 1344)
	before := points
	points[2].y = COORDINATE_UNIT_LIMIT
	before[2].y = COORDINATE_UNIT_LIMIT
	testing.expect(t, !path_points_move(points[:], 0, 1))
	testing.expect(t, points == before)
	testing.expect(t, path_points_move(points[:0], 0, max(i32)))
}

// The kinds whose fields hold no place move their box only: a push of a
// clip and of an element, a picture, a grid, a path, whose points the text
// table holds. Their fields stay as they were, the move and the move back
// give the record, and a box past the limit is refused for each kind.
@(test)
a_move_moves_the_box_alone_of_the_kinds_with_no_place_in_their_fields :: proc(t: ^testing.T) {
	Case :: struct {
		name:      string,
		primitive: Draw_Primitive,
		element:   u32,
	}
	cases := [?]Case{
		{"clip push", Draw_Clip_Push{}, 0},
		{"element push", Draw_Element_Push{name_first = 0, name_count = 4}, 9},
		{"picture", Draw_Picture{memory = 0, format = .Opaque, first = 0, stride = 10, generation = 3}, 0},
		{"text grid", Draw_Text_Grid{first = 0, count = 32, columns = 2, size = 1024}, 0},
		{"path", Draw_Path{first = 0, count = 24, fill_color = 0xFF102030}, 0},
	}
	for each in cases {
		record := record_of(each.primitive, each.element, 640, 19200, 1280, 20480)
		_, read_problem := read(record)
		testing.expectf(t, read_problem == .None, "%s: the record is not read (%v)", each.name, read_problem)
		moved, ok := record_moved(record, 64, STEP_UP)
		testing.expectf(t, ok && moved.left == 704 && moved.right == 1344 && moved.top == 0 && moved.bottom == 1280, "%s: the box is %d,%d,%d,%d", each.name, moved.left, moved.top, moved.right, moved.bottom)
		testing.expectf(t, moved.fields == record.fields && moved.kind == record.kind && moved.element == record.element, "%s: the fields changed", each.name)
		back, back_ok := record_moved(moved, -64, -STEP_UP)
		testing.expectf(t, back_ok && back == record, "%s: the move back differs", each.name)
		past := record_of(each.primitive, each.element, 0, 0, COORDINATE_UNIT_LIMIT, 64)
		refused, refused_ok := record_moved(past, 64, 0)
		testing.expectf(t, !refused_ok && refused == past, "%s: a box past the limit is moved", each.name)
	}
}

// A record whose move is refused draws nothing in its place: a push keeps
// its kind with an empty box, so the order of the clips and of the
// elements stays whole; a pop stays a pop; each other kind becomes
// Draw_Nothing. A record that read refuses stays as it is.
@(test)
a_hidden_record_draws_nothing_and_keeps_the_order_of_the_clips :: proc(t: ^testing.T) {
	push := record_hidden(record_of(Draw_Clip_Push{}, 0, 640, 640, 1280, 1280))
	primitive, problem := read(push)
	_, is_push := primitive.(Draw_Clip_Push)
	testing.expect(t, problem == .None && is_push && push.left == 0 && push.top == 0 && push.right == 0 && push.bottom == 0)
	element := record_hidden(record_of(Draw_Element_Push{name_count = 4}, 9, 640, 640, 1280, 1280))
	primitive, problem = read(element)
	_, is_element := primitive.(Draw_Element_Push)
	testing.expect(t, problem == .None && is_element && element.element == 9 && element.right == 0)
	pop := record_of(Draw_Clip_Pop{}, 0, 0, 0, 0, 0)
	testing.expect(t, record_hidden(pop) == pop)
	for each in ([?]Draw_Primitive{Draw_Rectangle{color = 0xFF102030}, Draw_Text{first = 0, count = 1, color = 0xFFFFFFFF, origin_x = 640, font = .Cells_8x16, weight = .Regular, size = 1024}, Draw_Path{first = 0, count = 24, fill_color = 0xFF102030}}) {
		hidden := record_hidden(record_of(each, 3, 640, 640, 1280, 1280))
		testing.expectf(t, hidden == record_of(Draw_Nothing{}, 0, 0, 0, 0, 0), "%v is not hidden", each)
	}
	unknown := record_of(Draw_Rectangle{color = 0xFF102030}, 0, 0, 0, 64, 64)
	unknown.kind = 255
	testing.expect(t, record_hidden(unknown) == unknown)
}
