#+build !freestanding
package interface

import "core:testing"
import "modus:contract/draw_record"
import "modus:support/graphics"

// The tests of the clip stack in the writer, the execution and the
// difference (src/md/api/draw_table.md, "The kinds"). The refusals come
// first; the reference pixels and the successful cases come last.

@(private = "file")
CLIP_CANVAS_WIDTH :: 64
@(private = "file")
CLIP_CANVAS_HEIGHT :: 48
@(private = "file")
CLIP_BACKGROUND :: graphics.Color(0x123456)
@(private = "file")
CLIP_FILL :: graphics.Color(0x00C08040)

@(private = "file")
Clip_Tables :: struct {
	records: [64]Draw_Record,
	text:    [64]u8,
}

@(private = "file")
clip_table_of :: proc(memory: ^Clip_Tables) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:]}
}

@(private = "file")
clip_canvas :: proc(pixels: []graphics.Color) -> graphics.Canvas {
	return {pixels = raw_data(pixels), width = CLIP_CANVAS_WIDTH, height = CLIP_CANVAS_HEIGHT, stride = CLIP_CANVAS_WIDTH}
}

// clip_draw draws a table whole over the background.
@(private = "file")
clip_draw :: proc(table: ^Draw_Table, pixels: []graphics.Color) {
	canvas := clip_canvas(pixels)
	graphics.clear(canvas, CLIP_BACKGROUND)
	execute(table, canvas)
}

// clip_draw_in_parts draws a table over the background in four rectangles
// that cut the canvas at odd places, each rectangle on its own.
@(private = "file")
clip_draw_in_parts :: proc(table: ^Draw_Table, pixels: []graphics.Color) {
	canvas := clip_canvas(pixels)
	graphics.clear(canvas, CLIP_BACKGROUND)
	parts := [4]Rectangle{{0, 0, 23, 17}, {23, 0, CLIP_CANVAS_WIDTH, 17}, {0, 17, 23, CLIP_CANVAS_HEIGHT}, {23, 17, CLIP_CANVAS_WIDTH, CLIP_CANVAS_HEIGHT}}
	execute_in_rectangles(table, canvas, parts[:])
}

@(private = "file")
clip_same_pixels :: proc(first, second: []graphics.Color) -> bool {
	for pixel, index in first {
		if pixel != second[index] {
			return false
		}
	}
	return len(first) == len(second)
}

// clip_after_damage draws the table before whole, then the table now in
// its damage only, over the background as the window layer does, and says
// if the canvas is the table now drawn whole.
@(private = "file")
clip_after_damage :: proc(before, now: ^Draw_Table) -> bool {
	surface: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	whole: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	canvas := clip_canvas(surface[:])
	graphics.clear(canvas, graphics.colors.background)
	execute(before, canvas)
	damage: Damage
	damage_by_difference(before, now, &damage)
	draw_damage_on_surface(now, canvas, damage.rectangles[:damage.count])
	whole_canvas := clip_canvas(whole[:])
	graphics.clear(whole_canvas, graphics.colors.background)
	execute(now, whole_canvas)
	return clip_same_pixels(surface[:], whole[:])
}

@(private = "file")
clip_push_record :: proc(left, top, right, bottom: int) -> Draw_Record {
	return draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, draw_record.units_of_pixels(left), draw_record.units_of_pixels(top), draw_record.units_of_pixels(right), draw_record.units_of_pixels(bottom))
}

@(private = "file")
clip_pop_record :: proc() -> Draw_Record {
	return draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0)
}

@(private = "file")
clip_fill_record :: proc(left, top, right, bottom: int) -> Draw_Record {
	return draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(CLIP_FILL)}, 0, draw_record.units_of_pixels(left), draw_record.units_of_pixels(top), draw_record.units_of_pixels(right), draw_record.units_of_pixels(bottom))
}

// A pop with no push open is not written and sets refused; the table
// keeps each record and each byte of text that it had.
@(test)
draw_clip_pop_with_no_push_is_refused :: proc(t: ^testing.T) {
	memory: Clip_Tables
	table := clip_table_of(&memory)
	draw_rectangle(&table, 0, 0, 4, 4, CLIP_FILL)
	kept := table.records[0]
	draw_clip_pop(&table)
	testing.expect(t, table.refused, "a pop with no push is not refused")
	testing.expect_value(t, table.record_count, 1)
	testing.expect_value(t, table.clip_depth, 0)
	testing.expect(t, table.records[0] == kept && table.records[1] == Draw_Record{}, "a refused pop changed the table")
	// After a push and its pop, one pop more is refused too.
	draw_table_clear(&table)
	draw_clip_push(&table, 0, 0, 8, 8)
	draw_clip_pop(&table)
	testing.expect(t, !table.refused)
	draw_clip_pop(&table)
	testing.expect(t, table.refused, "a second pop is not refused")
	testing.expect_value(t, table.record_count, 2)
}

// The bound: CLIP_DEPTH_LIMIT pushes are written; one more is not written,
// sets refused, and its pop is not written either. The records under it
// are not written, and their text is not copied: they draw no pixel. The
// table ends in an order that the border takes. The pushes are each one
// pixel smaller, so a rectangle after the pop of the 17th push, under the
// 16 written, is cut to the deepest one.
@(test)
draw_clip_push_past_the_bound_is_refused :: proc(t: ^testing.T) {
	AFTER_FILL :: graphics.Color(0x0020E040)
	memory: Clip_Tables
	table := clip_table_of(&memory)
	for depth in 0 ..< draw_record.CLIP_DEPTH_LIMIT {
		draw_clip_push(&table, depth, depth, CLIP_CANVAS_WIDTH - 2 * depth, CLIP_CANVAS_HEIGHT - 2 * depth)
	}
	testing.expect(t, !table.refused, "a push at the bound is refused")
	testing.expect_value(t, table.record_count, draw_record.CLIP_DEPTH_LIMIT)
	draw_clip_push(&table, 30, 20, 2, 2)
	testing.expect(t, table.refused, "a push past the bound is not refused")
	testing.expect_value(t, table.record_count, draw_record.CLIP_DEPTH_LIMIT)
	testing.expect_value(t, table.clip_pushes_not_written, 1)
	// Under the push that is not written: no record and no byte of text.
	draw_rectangle(&table, 0, 0, CLIP_CANVAS_WIDTH, CLIP_CANVAS_HEIGHT, CLIP_FILL)
	draw_text(&table, 20, 20, "hidden", CLIP_FILL)
	testing.expect_value(t, table.record_count, draw_record.CLIP_DEPTH_LIMIT)
	testing.expect_value(t, table.text_count, 0)
	draw_clip_pop(&table)
	testing.expect_value(t, table.record_count, draw_record.CLIP_DEPTH_LIMIT)
	testing.expect_value(t, table.clip_pushes_not_written, 0)
	// After its pop, a record is written again, under the 16 clips.
	draw_rectangle(&table, 0, 0, CLIP_CANVAS_WIDTH, CLIP_CANVAS_HEIGHT, AFTER_FILL)
	testing.expect_value(t, table.record_count, draw_record.CLIP_DEPTH_LIMIT + 1)
	for _ in 0 ..< draw_record.CLIP_DEPTH_LIMIT {
		draw_clip_pop(&table)
	}
	testing.expect_value(t, table.record_count, 2 * draw_record.CLIP_DEPTH_LIMIT + 1)
	problem, _ := draw_record.clip_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Clip_Order_Problem.None)
	// No pixel of the hidden rectangle; the rectangle after the pop is cut
	// by the 16 clips that the table holds.
	pixels: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	clip_draw(&table, pixels[:])
	last := draw_record.CLIP_DEPTH_LIMIT - 1
	for y in 0 ..< CLIP_CANVAS_HEIGHT {
		for x in 0 ..< CLIP_CANVAS_WIDTH {
			pixel := pixels[y * CLIP_CANVAS_WIDTH + x]
			inside := x >= last && x < CLIP_CANVAS_WIDTH - last && y >= last && y < CLIP_CANVAS_HEIGHT - last
			testing.expectf(t, pixel != CLIP_FILL, "the pixel (%d, %d) of a rectangle under a push that is not written", x, y)
			testing.expectf(t, (pixel == AFTER_FILL) == inside, "the pixel (%d, %d) after the pop of the 17th push", x, y)
		}
	}
}

// A push with no room is not written; the records under it are not
// written, until its pop. A table of 3 places with 2 records: the push
// does not fit with its pop, and the rectangle after it is not written.
@(test)
draw_clip_push_with_no_room_hides_its_records :: proc(t: ^testing.T) {
	records: [3]Draw_Record
	table := Draw_Table{records = records[:]}
	draw_rectangle(&table, 0, 0, 4, 4, CLIP_FILL)
	draw_rectangle(&table, 4, 0, 4, 4, CLIP_FILL)
	testing.expect_value(t, table.record_count, 2)
	testing.expect(t, !table.full && !table.refused)
	kept := records
	draw_clip_push(&table, 0, 0, 8, 8)
	testing.expect(t, table.full, "a push with no room for its pop does not set full")
	testing.expect_value(t, table.clip_pushes_not_written, 1)
	draw_rectangle(&table, 0, 0, 30, 30, CLIP_FILL)
	testing.expect(t, table.refused, "a record under a push that is not written does not set refused")
	testing.expect_value(t, table.record_count, 2)
	testing.expect(t, records == kept, "a record under a push that is not written changed the table")
	draw_clip_pop(&table)
	testing.expect_value(t, table.record_count, 2)
	testing.expect_value(t, table.clip_pushes_not_written, 0)
	problem, _ := draw_record.clip_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Clip_Order_Problem.None)
}

// A table with no room: a push that does not fit with its pop sets full
// and is not written, and its pop is not written; each record that the
// table takes keeps room for the pops of the clips open, so a pop always
// fits.
@(test)
draw_clip_keeps_room_for_its_pop :: proc(t: ^testing.T) {
	records: [3]Draw_Record
	table := Draw_Table{records = records[:]}
	draw_clip_push(&table, 0, 0, 8, 8)
	draw_rectangle(&table, 0, 0, 4, 4, CLIP_FILL)
	testing.expect(t, !table.full)
	// The third place is the room of the pop.
	draw_rectangle(&table, 4, 4, 4, 4, CLIP_FILL)
	testing.expect(t, table.full, "a record took the room of a pop")
	testing.expect_value(t, table.record_count, 2)
	draw_clip_pop(&table)
	testing.expect_value(t, table.record_count, 3)
	problem, _ := draw_record.clip_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Clip_Order_Problem.None)
	// One place: no room for a push and its pop.
	one: [1]Draw_Record
	small := Draw_Table{records = one[:]}
	draw_clip_push(&small, 0, 0, 8, 8)
	testing.expect(t, small.full && small.record_count == 0, "a push with no room for its pop is written")
	draw_clip_pop(&small)
	testing.expect_value(t, small.record_count, 0)
	testing.expect_value(t, small.clip_pushes_not_written, 0)
}

// A frame that leaves a clip open: frame_end pops it and sets refused, so
// the table ends in an order that the drawing module takes. A negative
// size is an empty clip.
@(test)
frame_end_closes_each_clip_left_open :: proc(t: ^testing.T) {
	memory: Clip_Tables
	table := clip_table_of(&memory)
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	draw_clip_push(frame.table, 2, 2, -5, 8)
	draw_clip_push(frame.table, 2, 2, 8, 8)
	frame_end(&frame)
	testing.expect(t, table.refused, "a clip left open is not refused")
	testing.expect_value(t, table.record_count, 4)
	testing.expect_value(t, table.clip_depth, 0)
	problem, _ := draw_record.clip_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Clip_Order_Problem.None)
	view := record_view(table.records[0])
	testing.expect(t, view.read && view.kind == .Clip_Push && view.width == 0, "a negative width is not an empty clip")
	// A frame that closes its clips is not refused.
	frame = frame_begin(&table, &state, &input)
	draw_clip_push(frame.table, 2, 2, 8, 8)
	draw_clip_pop(frame.table)
	frame_end(&frame)
	testing.expect(t, !table.refused)
}

// Tables out of order, as a hostile caller writes them, through the
// execution of the package: a pop with no push draws nothing and keeps the
// cut; a push past the bound hides each record until its pop; a table that
// ends with a push open draws what it draws. No pixel is drawn outside a
// clip that the table pushed.
@(test)
execute_draws_less_for_a_table_out_of_order :: proc(t: ^testing.T) {
	pixels: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	expected: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	// A pop with no push, between a clip and its records: the cut stays.
	{
		records := [?]Draw_Record{clip_pop_record(), clip_push_record(4, 4, 20, 20), clip_pop_record(), clip_pop_record(), clip_fill_record(0, 0, 30, 30)}
		table := Draw_Table{records = records[:], record_count = len(records)}
		clip_draw(&table, pixels[:])
		reference := [?]Draw_Record{clip_fill_record(0, 0, 30, 30)}
		reference_table := Draw_Table{records = reference[:], record_count = 1}
		clip_draw(&reference_table, expected[:])
		testing.expect(t, clip_same_pixels(pixels[:], expected[:]), "pops with no push change the pixels")
	}
	// The bound plus one: the records under the 17th push draw nothing,
	// the records after its pop draw under the 16 clips.
	{
		records: [2 * draw_record.CLIP_DEPTH_LIMIT + 6]Draw_Record
		count := 0
		for _ in 0 ..< draw_record.CLIP_DEPTH_LIMIT {
			records[count] = clip_push_record(2, 2, 40, 40)
			count += 1
		}
		records[count] = clip_push_record(0, 0, CLIP_CANVAS_WIDTH, CLIP_CANVAS_HEIGHT)
		records[count + 1] = clip_fill_record(0, 0, CLIP_CANVAS_WIDTH, CLIP_CANVAS_HEIGHT)
		records[count + 2] = clip_pop_record()
		records[count + 3] = clip_fill_record(10, 10, 50, 50)
		count += 4
		problem, index := draw_record.clip_order_check(records[:count])
		testing.expect_value(t, problem, draw_record.Clip_Order_Problem.Push_Past_Depth_Limit)
		testing.expect_value(t, index, draw_record.CLIP_DEPTH_LIMIT)
		table := Draw_Table{records = records[:], record_count = count}
		clip_draw(&table, pixels[:])
		reference := [?]Draw_Record{clip_fill_record(10, 10, 40, 40)}
		reference_table := Draw_Table{records = reference[:], record_count = 1}
		clip_draw(&reference_table, expected[:])
		testing.expect(t, clip_same_pixels(pixels[:], expected[:]), "a push past the bound draws its records")
		clip_draw_in_parts(&table, pixels[:])
		testing.expect(t, clip_same_pixels(pixels[:], expected[:]), "a push past the bound draws its records in parts")
	}
	// A push open at the end cuts the records after it, and nothing else.
	{
		records := [?]Draw_Record{clip_push_record(8, 8, 16, 16), clip_fill_record(0, 0, 30, 30)}
		table := Draw_Table{records = records[:], record_count = len(records)}
		clip_draw(&table, pixels[:])
		reference := [?]Draw_Record{clip_fill_record(8, 8, 16, 16)}
		reference_table := Draw_Table{records = reference[:], record_count = 1}
		clip_draw(&reference_table, expected[:])
		testing.expect(t, clip_same_pixels(pixels[:], expected[:]), "a push with no pop draws outside its clip")
	}
}

// The edges of a clip: an empty clip, a clip outside the canvas, a clip at
// the far ends of the coordinate limit, and a nested clip larger than its
// parent. Each clipped rectangle draws the pixels of the rectangle of the
// intersection, whole and in four parts, pixel by pixel; an intersection
// with no pixel draws nothing.
@(test)
a_clipped_rectangle_is_the_rectangle_of_the_intersection :: proc(t: ^testing.T) {
	LIMIT :: draw_record.COORDINATE_LIMIT
	Clip_Case :: struct {
		name:         string,
		clips:        [2]Rectangle, // The parent, then the nested clip; a nested clip of zeros is none.
		nested:       bool,
		fill:         Rectangle,
		intersection: Rectangle, // Empty: nothing is drawn.
	}
	cases := [?]Clip_Case {
		{"an empty clip", {{10, 10, 10, 30}, {}}, false, {0, 0, 64, 48}, {}},
		{"a clip of no height", {{10, 10, 30, 10}, {}}, false, {0, 0, 64, 48}, {}},
		{"a clip outside the canvas", {{100, 100, 140, 140}, {}}, false, {0, 0, 200, 200}, {}},
		{"a clip left of and above the canvas", {{-40, -40, -1, -1}, {}}, false, {-50, -50, 64, 48}, {}},
		{"a clip at the limit", {{-LIMIT, -LIMIT, LIMIT, LIMIT}, {}}, false, {5, 6, 20, 21}, {5, 6, 20, 21}},
		{"a clip that cuts a corner", {{10, 8, 40, 30}, {}}, false, {20, 20, 64, 48}, {20, 20, 40, 30}},
		{"a nested clip larger than its parent", {{10, 8, 40, 30}, {0, 0, 64, 48}}, true, {0, 0, 64, 48}, {10, 8, 40, 30}},
		{"a nested clip inside its parent", {{10, 8, 40, 30}, {12, 10, 20, 12}}, true, {0, 0, 64, 48}, {12, 10, 20, 12}},
		{"a nested clip beside its parent", {{10, 8, 40, 30}, {40, 8, 60, 30}}, true, {0, 0, 64, 48}, {}},
		{"a nested clip across an edge of its parent", {{10, 8, 40, 30}, {30, 0, 64, 20}}, true, {0, 0, 64, 48}, {30, 8, 40, 20}},
	}
	pixels: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	expected: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	for item in cases {
		records: [6]Draw_Record
		count := 0
		records[count] = clip_push_record(item.clips[0].left, item.clips[0].top, item.clips[0].right, item.clips[0].bottom)
		count += 1
		if item.nested {
			records[count] = clip_push_record(item.clips[1].left, item.clips[1].top, item.clips[1].right, item.clips[1].bottom)
			count += 1
		}
		records[count] = clip_fill_record(item.fill.left, item.fill.top, item.fill.right, item.fill.bottom)
		count += 1
		records[count] = clip_pop_record()
		count += 1
		if item.nested {
			records[count] = clip_pop_record()
			count += 1
		}
		problem, _ := draw_record.clip_order_check(records[:count])
		testing.expectf(t, problem == .None, "%s: the order is refused: %v", item.name, problem)
		table := Draw_Table{records = records[:], record_count = count}
		reference: [1]Draw_Record
		reference_table := Draw_Table{records = reference[:]}
		if !empty(item.intersection) {
			reference[0] = clip_fill_record(item.intersection.left, item.intersection.top, item.intersection.right, item.intersection.bottom)
			reference_table.record_count = 1
		}
		clip_draw(&reference_table, expected[:])
		clip_draw(&table, pixels[:])
		testing.expectf(t, clip_same_pixels(pixels[:], expected[:]), "%s: the clipped rectangle is not the rectangle of the intersection", item.name)
		clip_draw_in_parts(&table, pixels[:])
		testing.expectf(t, clip_same_pixels(pixels[:], expected[:]), "%s: in four parts, the clipped rectangle is not the rectangle of the intersection", item.name)
	}
}

// The depths 0, 1 and CLIP_DEPTH_LIMIT through the writer: each push is
// one pixel inside the one before, so the rectangle under them is the
// rectangle of the deepest; a translucent rectangle blends once, whole and
// in four parts.
@(test)
each_depth_to_the_bound_cuts_to_the_deepest_clip :: proc(t: ^testing.T) {
	_ = blend_table()
	depths := [3]int{0, 1, draw_record.CLIP_DEPTH_LIMIT}
	pixels: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	expected: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	color := draw_record.with_alpha(0x0040A0E0, 128)
	for depth in depths {
		memory, reference_memory: Clip_Tables
		table, reference := clip_table_of(&memory), clip_table_of(&reference_memory)
		for level in 0 ..< depth {
			draw_clip_push(&table, level + 1, level + 1, CLIP_CANVAS_WIDTH - 2 * (level + 1), CLIP_CANVAS_HEIGHT - 2 * (level + 1))
		}
		draw_rectangle_with_alpha(&table, 0, 0, CLIP_CANVAS_WIDTH, CLIP_CANVAS_HEIGHT, color)
		for _ in 0 ..< depth {
			draw_clip_pop(&table)
		}
		testing.expectf(t, !table.refused && !table.full, "the depth %d is not written", depth)
		draw_rectangle_with_alpha(&reference, depth, depth, CLIP_CANVAS_WIDTH - 2 * depth, CLIP_CANVAS_HEIGHT - 2 * depth, color)
		clip_draw(&reference, expected[:])
		clip_draw(&table, pixels[:])
		testing.expectf(t, clip_same_pixels(pixels[:], expected[:]), "the depth %d: the pixels differ from the deepest rectangle", depth)
		clip_draw_in_parts(&table, pixels[:])
		testing.expectf(t, clip_same_pixels(pixels[:], expected[:]), "the depth %d: in four parts, the pixels differ", depth)
	}
}

// The damage of a frame drawn over the frame before gives the frame drawn
// whole: a push whose box moves, a pop that moves, a clip that becomes a
// rectangle, a record under a clip that changes, a push that the border
// refuses in one frame only, and a frame that adds a clip around its
// records.
@(test)
the_damage_of_clips_is_never_too_small :: proc(t: ^testing.T) {
	Build :: proc(table: ^Draw_Table, variant: int)
	cases := [?]struct {
		name:  string,
		build: Build,
	} {
		{"a push whose box moves", proc(table: ^Draw_Table, variant: int) {
				draw_clip_push(table, 4 + variant * 9, 4, 30, 20)
				draw_rectangle(table, 0, 0, 64, 48, CLIP_FILL)
				draw_clip_pop(table)
			}},
		{"an inner push whose box moves outside its parent", proc(table: ^Draw_Table, variant: int) {
				draw_clip_push(table, 10, 10, 30, 30)
				draw_clip_push(table, variant == 0 ? 12 : 30, 12, 30, 10)
				draw_rectangle(table, 0, 0, 64, 48, CLIP_FILL)
				draw_clip_pop(table)
				draw_clip_pop(table)
			}},
		{"a pop that moves", proc(table: ^Draw_Table, variant: int) {
				draw_clip_push(table, 4, 4, 20, 20)
				draw_rectangle(table, 0, 0, 30, 30, CLIP_FILL)
				if variant == 0 {
					draw_clip_pop(table)
				}
				draw_rectangle(table, 10, 10, 40, 30, graphics.colors.kernel)
				if variant == 1 {
					draw_clip_pop(table)
				}
			}},
		{"a record under a clip that changes", proc(table: ^Draw_Table, variant: int) {
				draw_clip_push(table, 4, 4, 20, 20)
				draw_rectangle(table, variant * 7, 0, 30, 30, CLIP_FILL)
				draw_clip_pop(table)
			}},
		{"a clip added around the records", proc(table: ^Draw_Table, variant: int) {
				if variant == 1 {
					draw_clip_push(table, 8, 8, 16, 16)
				}
				draw_rectangle(table, 0, 0, 64, 48, CLIP_FILL)
				if variant == 1 {
					draw_clip_pop(table)
				}
				draw_rectangle(table, 50, 30, 8, 8, graphics.colors.kernel)
			}},
	}
	for item in cases {
		for order in 0 ..< 2 {
			first, second: Clip_Tables
			before, now := clip_table_of(&first), clip_table_of(&second)
			item.build(&before, order)
			item.build(&now, 1 - order)
			testing.expectf(t, clip_after_damage(&before, &now), "%s: the frame in its damage differs from the whole frame (order %d)", item.name, order)
		}
	}
	// A push that the border refuses in the frame now only: the records
	// under it draw nothing now.
	before_records := [3]Draw_Record{clip_push_record(4, 4, 30, 30), clip_fill_record(0, 0, 64, 48), clip_pop_record()}
	now_records := before_records
	now_records[0].reserved[0] = 1
	before := Draw_Table{records = before_records[:], record_count = 3}
	now := Draw_Table{records = now_records[:], record_count = 3}
	testing.expect(t, clip_after_damage(&before, &now), "a push that becomes refused")
	testing.expect(t, clip_after_damage(&now, &before), "a refused push that becomes read")
	// Two equal frames with clips damage nothing.
	damage: Damage
	damage_by_difference(&before, &before, &damage)
	testing.expect_value(t, damage.count, 0)
}

// A list keeps the clip of the card that holds it: its push is inside the
// push of the card, its records are cut by both, and it pops its clip. A
// list in an area shorter than one line draws no pixel outside its area.
@(test)
a_list_pushes_the_clip_of_its_area :: proc(t: ^testing.T) {
	_ = blend_table()
	memory: Clip_Tables
	table := clip_table_of(&memory)
	state: Interface_State
	input: Input
	rows := [3]List_Row{{name = "first"}, {name = "second"}, {name = "third"}}
	frame := frame_begin(&table, &state, &input)
	draw_clip_push(frame.table, 0, 0, 40, 30)
	list_of_rows(&frame, {4, 4, 60, 3 * TABLE_LINE}, rows[:], {chosen = 0, total = len(rows)})
	draw_clip_pop(frame.table)
	frame_end(&frame)
	testing.expect(t, !table.refused && !table.full, "the list is not written")
	testing.expect_value(t, record_view(table.records[0]).kind, Draw_Kind.Clip_Push)
	list_push := record_view(table.records[1])
	testing.expect(t, list_push.kind == .Clip_Push && list_push.x == 4 && list_push.y == 4 && list_push.width == 60 && list_push.height == 3 * TABLE_LINE, "the list does not push its area")
	testing.expect_value(t, record_view(table.records[table.record_count - 2]).kind, Draw_Kind.Clip_Pop)
	testing.expect_value(t, record_view(table.records[table.record_count - 1]).kind, Draw_Kind.Clip_Pop)
	problem, _ := draw_record.clip_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Clip_Order_Problem.None)
	pixels: [CLIP_CANVAS_WIDTH * CLIP_CANVAS_HEIGHT]graphics.Color
	clip_draw(&table, pixels[:])
	for y in 0 ..< CLIP_CANVAS_HEIGHT {
		for x in 0 ..< CLIP_CANVAS_WIDTH {
			if x >= 40 || y >= 30 || x < 4 || y < 4 {
				testing.expectf(t, pixels[y * CLIP_CANVAS_WIDTH + x] == CLIP_BACKGROUND, "the list draws the pixel (%d, %d) outside the clip of its card", x, y)
			}
		}
	}
	// A list with a choice in an area of 10 pixels: its one line is cut.
	names := [2]string{"one", "two"}
	choice := 0
	frame = frame_begin(&table, &state, &input)
	list_with_choice(&frame, {0, 0, 50, 10}, identity("list"), names[:], &choice)
	frame_end(&frame)
	testing.expect(t, !table.refused && !table.full)
	clip_draw(&table, pixels[:])
	for y in 10 ..< CLIP_CANVAS_HEIGHT {
		for x in 0 ..< CLIP_CANVAS_WIDTH {
			testing.expectf(t, pixels[y * CLIP_CANVAS_WIDTH + x] == CLIP_BACKGROUND, "the list draws the pixel (%d, %d) below its area", x, y)
		}
	}
}
