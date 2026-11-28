#+build !freestanding
#+build !modus
package interface

import "core:testing"

// The element names of a frame: a button by its label, a text input by its
// placeholder, a part of a scroll bar by two words; the first element of a
// name keeps it; an empty or too long name, and a name past the capacity,
// are counted and kept nowhere. A place needs a line only when the set that
// was written has no place of its name, or another rectangle.
@(test)
the_element_names_of_a_frame :: proc(t: ^testing.T) {
	process_drawing_begin()
	records: [128]Draw_Record
	characters: [4096]u8
	table := Draw_Table{records = records[:], text = characters[:]}
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	button(&frame, {0, 0, 96, 24}, identity("watch"), "watch")
	button(&frame, {104, 0, 96, 24}, identity("second watch"), "watch")
	typed: [16]u8
	typed_count := 0
	text_input(&frame, {0, 32, 200, 24}, identity("place"), typed[:], &typed_count, "the debug place")
	element_name(&frame, {0, 64, 200, 20}, "")
	TOO_LONG :: "an element name of 33 bytes long."
	#assert(len(TOO_LONG) == ELEMENT_NAME_CAPACITY + 1)
	element_name(&frame, {0, 64, 200, 20}, TOO_LONG)
	element_name_joined(&frame, {200, 96, 17, 17}, "scroll bar", "arrow up")
	places := &frame.element_places
	testing.expect_value(t, places.count, 3)
	testing.expect_value(t, places.dropped, 2)
	testing.expect_value(t, element_place_name(&places.places[0]), "watch")
	testing.expect_value(t, places.places[0].area, Area{0, 0, 96, 24})
	testing.expect_value(t, element_place_name(&places.places[1]), "the debug place")
	testing.expect_value(t, element_place_name(&places.places[2]), "scroll bar arrow up")
	testing.expect_value(t, places.places[2].area, Area{200, 96, 17, 17})

	// The set that the log has: empty, then the same set, then one moved
	// rectangle.
	written: Element_Places
	testing.expect(t, element_place_changed(&written, &places.places[0]))
	written = places^
	for &place in places.places[:places.count] {
		testing.expect(t, !element_place_changed(&written, &place))
	}
	written.places[0].area.x = 4
	testing.expect(t, element_place_changed(&written, &places.places[0]))
	testing.expect(t, !element_place_changed(&written, &places.places[1]))

	// The capacity: the names past it are counted.
	for index in 0 ..< ELEMENT_PLACE_CAPACITY {
		name := [3]u8{'n', u8('0' + index / 10), u8('0' + index % 10)}
		element_name(&frame, {index, 0, 1, 1}, string(name[:]))
	}
	testing.expect_value(t, places.count, ELEMENT_PLACE_CAPACITY)
	testing.expect_value(t, places.dropped, 2 + 3)
	frame_end(&frame)
}

@(test)
element_names_respect_active_clip :: proc(t: ^testing.T) {
	process_drawing_begin()
	records: [128]Draw_Record
	characters: [4096]u8
	table := Draw_Table{records = records[:], text = characters[:]}
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)

	// Open a clip view at (10, 20, 100, 80) -> x in [10, 110), y in [20, 100).
	draw_clip_push(frame.table, 10, 20, 100, 80)

	// Completely outside (above, below, left, right) -> omitted, dropped stays 0.
	element_name(&frame, {10, -40, 80, 24}, "above")
	element_name(&frame, {10, 100, 80, 24}, "below")
	element_name(&frame, {-50, 30, 60, 24}, "left")
	element_name(&frame, {110, 30, 40, 24}, "right")
	element_name_joined(&frame, {10, 120, 40, 20}, "off", "screen")
	testing.expect_value(t, frame.element_places.count, 0)
	testing.expect_value(t, frame.element_places.dropped, 0)

	// Partly clipped at top edge -> cut to visible intersection.
	element_name(&frame, {15, 10, 50, 30}, "partial")
	testing.expect_value(t, frame.element_places.count, 1)
	testing.expect_value(t, frame.element_places.places[0].area, Area{15, 20, 50, 20})

	// Nested clip narrows further; empty nested clip omits everything inside.
	draw_clip_push(frame.table, 20, 30, 40, 20)
	element_name(&frame, {15, 25, 60, 40}, "nested")
	testing.expect_value(t, frame.element_places.count, 2)
	testing.expect_value(t, frame.element_places.places[1].area, Area{20, 30, 40, 20})
	draw_clip_push(frame.table, 0, 0, 0, 0)
	element_name(&frame, {25, 35, 10, 10}, "empty_clip")
	testing.expect_value(t, frame.element_places.count, 2)
	draw_clip_pop(frame.table)
	draw_clip_pop(frame.table)

	// Pop outer clip: elements outside old clip are recorded whole again.
	draw_clip_pop(frame.table)
	element_name(&frame, {0, 0, 200, 20}, "unclipped")
	testing.expect_value(t, frame.element_places.count, 3)
	testing.expect_value(t, frame.element_places.places[2].area, Area{0, 0, 200, 20})
	frame_end(&frame)
}

@(test)
element_places_scroll_coalescing_decisions :: proc(t: ^testing.T) {
	// Equal to written always clears pending and emits nothing.
	act, due := element_places_step_decide(true, true, true, true, true, true, true, 1000, 1100)
	testing.expect_value(t, act, Element_Places_Action.None)
	testing.expect_value(t, due, u64(0))

	// First frame always publishes immediately, even if scroll flags are set.
	act, due = element_places_step_decide(false, false, false, false, true, true, true, 1000, 0)
	testing.expect_value(t, act, Element_Places_Action.Publish_Now)
	testing.expect_value(t, due, u64(0))

	// Active scrollbar drag defers until release even if settle is not wired.
	act, due = element_places_step_decide(true, false, false, false, true, true, false, 1000, 0)
	testing.expect_value(t, act, Element_Places_Action.Defer_Until_Release)
	testing.expect_value(t, due, u64(0))

	// Scroll frame in a wired window defers until now + settle interval.
	act, due = element_places_step_decide(true, false, false, false, true, false, true, 1000, 0)
	testing.expect_value(t, act, Element_Places_Action.Defer_Until_Deadline)
	testing.expect_value(t, due, u64(1000 + ELEMENT_PLACES_SCROLL_SETTLE_MILLISECONDS))

	// Scroll frame in an unwired window publishes immediately so places never stall.
	act, due = element_places_step_decide(true, false, false, false, true, false, false, 1000, 0)
	testing.expect_value(t, act, Element_Places_Action.Publish_Now)
	testing.expect_value(t, due, u64(0))

	// Hover redraw during the settle window with identical pending places keeps waiting.
	act, due = element_places_step_decide(true, false, true, true, false, false, true, 1050, 1150)
	testing.expect_value(t, act, Element_Places_Action.Defer_Until_Deadline)
	testing.expect_value(t, due, u64(1150))

	// Discrete layout change (differs from pending, not scrolling) publishes immediately.
	act, due = element_places_step_decide(true, false, true, false, false, false, true, 1050, 1150)
	testing.expect_value(t, act, Element_Places_Action.Publish_Now)
	testing.expect_value(t, due, u64(0))

	// Release after drag (dragging_bar = false, scrolling = false, no deadline) publishes immediately.
	act, due = element_places_step_decide(true, false, true, true, false, false, true, 1050, 0)
	testing.expect_value(t, act, Element_Places_Action.Publish_Now)
	testing.expect_value(t, due, u64(0))

	// Deadline edges: before, at, and with dirty = false or deadline = 0.
	testing.expect(t, !element_places_deadline_due(false, 1150, 1150))
	testing.expect(t, !element_places_deadline_due(true, 0, 1150))
	testing.expect(t, !element_places_deadline_due(true, 1150, 1149))
	testing.expect(t, element_places_deadline_due(true, 1150, 1150))
	testing.expect(t, element_places_deadline_due(true, 1150, 1200))

	// Set equality ignores order and catches moved rectangles or changed counts.
	a, b: Element_Places
	element_places_add(&a, {0, 0, 10, 10}, "one")
	element_places_add(&a, {20, 0, 10, 10}, "two")
	element_places_add(&b, {20, 0, 10, 10}, "two")
	element_places_add(&b, {0, 0, 10, 10}, "one")
	testing.expect(t, element_places_equal(&a, &b))
	b.places[0].area.y = 5
	testing.expect(t, !element_places_equal(&a, &b))
}

