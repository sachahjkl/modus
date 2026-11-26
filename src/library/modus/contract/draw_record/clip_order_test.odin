#+build !freestanding
#+build !modus
package draw_record

import "core:testing"

// The tests of the clip stack (src/md/api/draw_table.md, "The kinds"): the
// border of a push and of a pop, then the border of the order of a table.
// The refusals come first; the successful cases are the last ones.

// A record of a push in a box of whole pixels.
@(private = "file")
push_record :: proc(left, top, right, bottom: int) -> Draw_Record {
	return record_of(Draw_Clip_Push{}, 0, units_of_pixels(left), units_of_pixels(top), units_of_pixels(right), units_of_pixels(bottom))
}

@(private = "file")
pop_record :: proc() -> Draw_Record {
	return record_of(Draw_Clip_Pop{}, 0, 0, 0, 0, 0)
}

@(private = "file")
rectangle_record :: proc() -> Draw_Record {
	return record_of(Draw_Rectangle{color = OPAQUE_ALPHA << ALPHA_SHIFT}, 0, 0, 0, units_of_pixels(4), units_of_pixels(4))
}

// The word 5 of the Clip of version 16, which replaced the cut, names no
// kind: a record of that form is refused, with a box and with a box of no
// width, the end of each cut of version 16.
@(test)
read_refuses_the_word_of_the_clip_that_replaced_the_cut :: proc(t: ^testing.T) {
	CLIP_WORD :: 5
	_, known := draw_kind_of_word(CLIP_WORD)
	testing.expect(t, !known, "the word 5 names a kind")
	boxes := [2][4]i32{{units_of_pixels(10), units_of_pixels(10), units_of_pixels(60), units_of_pixels(40)}, {}}
	for box in boxes {
		record := record_of(Draw_Nothing{}, 0, box[0], box[1], box[2], box[3])
		record.kind = CLIP_WORD
		primitive, problem := read(record)
		testing.expectf(t, problem == .Unknown_Kind && primitive == nil, "the word 5 in the box %v: %v", box, problem)
	}
}

// A pop names no byte of its box: each edge that is not 0, by one pixel,
// by one unit and at the far ends of the limit, is refused, with the box
// that stays the right way. An inverted box and an edge past the limit get
// the problem of the earlier check.
@(test)
read_refuses_a_pop_whose_box_is_not_zero :: proc(t: ^testing.T) {
	values := [?]i32{1, UNITS_PER_PIXEL, COORDINATE_UNIT_LIMIT}
	for value in values {
		for side in 0 ..< 4 {
			record := pop_record()
			switch side {
			case 0:
				record.left, record.right = -value, 0
			case 1:
				record.top, record.bottom = -value, 0
			case 2:
				record.right = value
			case 3:
				record.bottom = value
			}
			primitive, problem := read(record)
			expected := Problem.Reserved_Not_Zero
			// A box inside a pixel is refused first, as for each kind on
			// whole pixels.
			if !on_whole_pixel(value) {
				expected = .Box_Not_On_Whole_Pixels
			}
			testing.expectf(t, problem == expected && primitive == nil, "a pop with the edge %d at %d: %v", side, value, problem)
		}
	}
	inverted := pop_record()
	inverted.left = units_of_pixels(1)
	_, problem := read(inverted)
	testing.expect_value(t, problem, Problem.Box_Inverted)
	past := pop_record()
	past.right = COORDINATE_UNIT_LIMIT + UNITS_PER_PIXEL
	_, problem = read(past)
	testing.expect_value(t, problem, Problem.Box_Past_Coordinate_Limit)
	_, problem = read(pop_record())
	testing.expect_value(t, problem, Problem.None)
}

// A push is on whole pixels: an edge one unit off is refused on each side.
// An empty box and a box at the far ends of the limit are read: an empty
// clip and a clip of the whole plane.
@(test)
read_takes_a_push_on_whole_pixels_only :: proc(t: ^testing.T) {
	for side in 0 ..< 4 {
		record := push_record(2, 2, 10, 10)
		switch side {
		case 0:
			record.left += 1
		case 1:
			record.top += 1
		case 2:
			record.right -= 1
		case 3:
			record.bottom -= 1
		}
		_, problem := read(record)
		testing.expectf(t, problem == .Box_Not_On_Whole_Pixels, "a push with the edge %d off a pixel: %v", side, problem)
	}
	inverted := push_record(10, 2, 9, 10)
	_, problem := read(inverted)
	testing.expect_value(t, problem, Problem.Box_Inverted)
	empty := push_record(5, 5, 5, 5)
	primitive: Draw_Primitive
	primitive, problem = read(empty)
	_, is_push := primitive.(Draw_Clip_Push)
	testing.expect(t, problem == .None && is_push, "an empty push is read")
	whole := record_of(Draw_Clip_Push{}, 0, -COORDINATE_UNIT_LIMIT, -COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT, COORDINATE_UNIT_LIMIT)
	_, problem = read(whole)
	testing.expect_value(t, problem, Problem.None)
}

// A table of pushes and pops of a depth, each push with its pop after the
// rectangle at the deepest place.
@(private = "file")
nested_table :: proc(records: []Draw_Record, depth: int) -> int {
	count := 0
	for _ in 0 ..< depth {
		records[count] = push_record(0, 0, 100, 100)
		count += 1
	}
	records[count] = rectangle_record()
	count += 1
	for _ in 0 ..< depth {
		records[count] = pop_record()
		count += 1
	}
	return count
}

// The border of the order refuses each fault at the record that has it,
// and changes no record: a pop with no push (first, after a balanced pair,
// and after the pop of a push past the bound), a push at the bound plus
// one, and a push with no pop, also nested, where the index is the
// outermost push open.
@(test)
clip_order_check_refuses_each_fault :: proc(t: ^testing.T) {
	records: [2 * CLIP_DEPTH_LIMIT + 8]Draw_Record
	// A pop alone, at the index 0.
	records[0] = pop_record()
	problem, index := clip_order_check(records[:1])
	testing.expect_value(t, problem, Clip_Order_Problem.Pop_Without_Push)
	testing.expect_value(t, index, 0)
	// A pair, a rectangle, then one pop more.
	records[0], records[1], records[2], records[3] = push_record(0, 0, 8, 8), pop_record(), rectangle_record(), pop_record()
	problem, index = clip_order_check(records[:4])
	testing.expect_value(t, problem, Clip_Order_Problem.Pop_Without_Push)
	testing.expect_value(t, index, 3)
	// The bound plus one: CLIP_DEPTH_LIMIT pushes are taken, the next one
	// is refused at its own index.
	for place in 0 ..= CLIP_DEPTH_LIMIT {
		records[place] = push_record(0, 0, 8, 8)
	}
	problem, index = clip_order_check(records[:CLIP_DEPTH_LIMIT + 1])
	testing.expect_value(t, problem, Clip_Order_Problem.Push_Past_Depth_Limit)
	testing.expect_value(t, index, CLIP_DEPTH_LIMIT)
	// A push with no pop: the outermost push open, also after a pair that
	// closed and with a nested push open under it.
	records[0], records[1], records[2], records[3], records[4] = push_record(0, 0, 8, 8), pop_record(), push_record(0, 0, 8, 8), push_record(0, 0, 4, 4), pop_record()
	kept := records
	problem, index = clip_order_check(records[:5])
	testing.expect_value(t, problem, Clip_Order_Problem.Push_Without_Pop)
	testing.expect_value(t, index, 2)
	testing.expect(t, kept == records, "the check changed a record")
	// A push that the border of the record refuses is still a push: its
	// table with no pop is refused.
	refused_push := push_record(0, 0, 8, 8)
	refused_push.reserved[0] = 1
	records[0] = refused_push
	problem, index = clip_order_check(records[:1])
	testing.expect_value(t, problem, Clip_Order_Problem.Push_Without_Pop)
	testing.expect_value(t, index, 0)
	// A word that names no kind is no clip: it closes nothing.
	unknown := push_record(0, 0, 8, 8)
	unknown.kind = 5
	records[0], records[1] = unknown, pop_record()
	problem, index = clip_order_check(records[:2])
	testing.expect_value(t, problem, Clip_Order_Problem.Pop_Without_Push)
	testing.expect_value(t, index, 1)
}

// The steps of the order at their edges: a pop at the depth 0 changes
// nothing; a push at the bound is counted past it, and its pop ends it
// before any push held; the end with a push past the bound open is a fault.
@(test)
clip_order_steps_at_their_edges :: proc(t: ^testing.T) {
	order: Clip_Order
	testing.expect_value(t, clip_order_pop(&order), Clip_Order_Problem.Pop_Without_Push)
	testing.expect_value(t, order, Clip_Order{})
	for _ in 0 ..< CLIP_DEPTH_LIMIT {
		testing.expect_value(t, clip_order_push(&order), Clip_Order_Problem.None)
	}
	testing.expect_value(t, order, Clip_Order{depth = CLIP_DEPTH_LIMIT})
	testing.expect_value(t, clip_order_push(&order), Clip_Order_Problem.Push_Past_Depth_Limit)
	testing.expect_value(t, clip_order_push(&order), Clip_Order_Problem.Push_Past_Depth_Limit)
	testing.expect_value(t, order, Clip_Order{depth = CLIP_DEPTH_LIMIT, excess = 2})
	testing.expect_value(t, clip_order_end(order), Clip_Order_Problem.Push_Without_Pop)
	testing.expect_value(t, clip_order_pop(&order), Clip_Order_Problem.None)
	testing.expect_value(t, order, Clip_Order{depth = CLIP_DEPTH_LIMIT, excess = 1})
	testing.expect_value(t, clip_order_end(order), Clip_Order_Problem.Push_Without_Pop)
	testing.expect_value(t, clip_order_pop(&order), Clip_Order_Problem.None)
	testing.expect_value(t, order, Clip_Order{depth = CLIP_DEPTH_LIMIT})
	for _ in 0 ..< CLIP_DEPTH_LIMIT {
		testing.expect_value(t, clip_order_pop(&order), Clip_Order_Problem.None)
	}
	testing.expect_value(t, clip_order_end(order), Clip_Order_Problem.None)
	testing.expect_value(t, clip_order_pop(&order), Clip_Order_Problem.Pop_Without_Push)
}

// The depths that the border takes, last: a table of no record, no clip
// (depth 0), one clip, and CLIP_DEPTH_LIMIT clips nested.
@(test)
clip_order_check_takes_each_depth_to_the_bound :: proc(t: ^testing.T) {
	problem, index := clip_order_check(nil)
	testing.expect_value(t, problem, Clip_Order_Problem.None)
	testing.expect_value(t, index, 0)
	records: [2 * CLIP_DEPTH_LIMIT + 1]Draw_Record
	depths := [3]int{0, 1, CLIP_DEPTH_LIMIT}
	for depth in depths {
		count := nested_table(records[:], depth)
		problem, index = clip_order_check(records[:count])
		testing.expectf(t, problem == .None && index == 0, "the depth %d: %v at %d", depth, problem, index)
	}
}
