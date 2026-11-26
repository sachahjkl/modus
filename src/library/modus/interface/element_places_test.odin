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
