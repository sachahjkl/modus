package interface

import "modus:contract/value_kinds"
import "modus:system"

// The element places (src/md/infrastructure/test_pointer.md): each frame
// keeps the rectangle of each element that has an element name, and a
// window writes a log fact when the rectangle of a name changes. A
// machine test presses an element by its name from the fields of that
// fact, so a change of a layout moves the press with the element.

ELEMENT_NAME_CAPACITY :: 32 // The bytes of the longest element name.
ELEMENT_PLACE_CAPACITY :: 64 // The named elements of one frame.

// One named element of a frame: its name and the rectangle where it takes
// a press, in pixels of the surface of the window.
Element_Place :: struct {
	area:   Area,
	length: u8, // The bytes of `name` in use: 1 to ELEMENT_NAME_CAPACITY.
	name:   [ELEMENT_NAME_CAPACITY]u8,
}

// The named elements of a frame, in the order that the frame named them,
// or the set that a window last wrote on the log.
Element_Places :: struct {
	places:  [ELEMENT_PLACE_CAPACITY]Element_Place,
	count:   int, // The entries of `places` in use.
	dropped: int, // The names that the frame did not keep: empty, too long, or past the capacity.
}

// element_place_name gives the name of an element place.
element_place_name :: proc "contextless" (place: ^Element_Place) -> string {
	return string(place.name[:min(int(place.length), ELEMENT_NAME_CAPACITY)])
}

// element_name gives an element of the frame its element name: the name
// that a machine test presses it by. Call it in each frame that draws the
// element, with the area where it takes a press. A button and a text input
// name themselves by their label and their placeholder. The first element
// of a frame with a name keeps it: a second one with the same name has no
// element line.
element_name :: proc "contextless" (frame: ^Frame, area: Area, name: string) {
	element_places_add(&frame.element_places, area, name)
}

// element_name_joined is element_name with a name in two parts, with a
// space between them: "scroll bar" and "arrow up".
element_name_joined :: proc "contextless" (frame: ^Frame, area: Area, first, second: string) {
	buffer: [ELEMENT_NAME_CAPACITY]u8
	if len(first) + 1 + len(second) > ELEMENT_NAME_CAPACITY {
		frame.element_places.dropped += 1
		return
	}
	count := copy(buffer[:], first)
	buffer[count] = ' '
	count += 1
	count += copy(buffer[count:], second)
	element_places_add(&frame.element_places, area, string(buffer[:count]))
}

// element_places_add adds a name and its area to a set, when the set does
// not have the name yet.
element_places_add :: proc "contextless" (places: ^Element_Places, area: Area, name: string) {
	if len(name) == 0 || len(name) > ELEMENT_NAME_CAPACITY {
		places.dropped += 1
		return
	}
	for &kept in places.places[:places.count] {
		if element_place_name(&kept) == name {
			return
		}
	}
	if places.count >= ELEMENT_PLACE_CAPACITY {
		places.dropped += 1
		return
	}
	added := &places.places[places.count]
	added^ = {area = area, length = u8(len(name))}
	copy(added.name[:], name)
	places.count += 1
}

// element_places_find gives the entry of a set with a name, or nil.
element_places_find :: proc "contextless" (places: ^Element_Places, name: string) -> ^Element_Place {
	for &kept in places.places[:places.count] {
		if element_place_name(&kept) == name {
			return &kept
		}
	}
	return nil
}

// element_place_changed says if the set that was written has no place of
// that name, or another rectangle for it: the place needs a line. A host
// test runs it with no log.
element_place_changed :: proc "contextless" (written: ^Element_Places, place: ^Element_Place) -> bool {
	before := element_places_find(written, element_place_name(place))
	return before == nil || before.area != place.area
}

// The bytes of a Text field of an element place: the title of a window
// (display.Window.title, 32 bytes) or an element name (32 bytes), its zero
// byte, and the bytes up to the next multiple of 8, so that the record
// ends on 8 bytes after its Integer fields and has no padding. A fact
// type writes the number itself, [40]u8: the tool reads the length of a
// Text field as a literal.
ELEMENT_FACT_TEXT_BYTES :: 40
#assert(ELEMENT_FACT_TEXT_BYTES > ELEMENT_NAME_CAPACITY && ELEMENT_FACT_TEXT_BYTES % 8 == 0)
#assert(offset_of(Element_Placed, window) == 4 * size_of(i64) && offset_of(Element_Placed, element) == 4 * size_of(i64) + ELEMENT_FACT_TEXT_BYTES)
#assert(size_of(Element_Gone) == 2 * ELEMENT_FACT_TEXT_BYTES)

// A window placed a named element, or moved it: its rectangle in pixels
// of the surface of the window. A machine test presses the element by its
// name from the fields of the last such fact (src/md/features/log_facts.md,
// "The facts of the compositor and of the windows"). The name of the
// element is the last field: the serial line of a fact stops at its last
// byte that is not zero, so the zeros after a short name cost no byte.
@(log_fact = "interface: {window}: the element {element} at {x},{y},{width},{height}")
Element_Placed :: struct {
	x:       i64,
	y:       i64,
	width:   i64,
	height:  i64,
	window:  [40]u8,
	element: [40]u8,
}

// A named element that the last frame of a window no longer has.
@(log_fact = "interface: {window}: the element {element} is gone")
Element_Gone :: struct {
	window:  [40]u8,
	element: [40]u8,
}

// element_places_publish writes on the log what changed from the set that
// was written (written) to the set of the frame that is drawn now (now),
// then keeps now as the set that was written. A name that is new or has
// another rectangle writes the fact Element_Placed; a name that the frame no
// longer has writes Element_Gone. A set with no change writes nothing, so
// a window that does not move its elements adds no record to the log. The
// palette is no window: the compositor writes its own facts with the same
// procedures (element_place_changed, element_places_find,
// element_places_keep).
element_places_publish :: proc "contextless" (written, now: ^Element_Places, window_title: string) {
	window := value_kinds.text_field(window_title, ELEMENT_FACT_TEXT_BYTES)
	for &place in now.places[:now.count] {
		if !element_place_changed(written, &place) {
			continue
		}
		system.log_fact(.Info, Element_Placed{window = window, element = value_kinds.text_field(element_place_name(&place), ELEMENT_FACT_TEXT_BYTES), x = i64(place.area.x), y = i64(place.area.y), width = i64(place.area.width), height = i64(place.area.height)})
	}
	for &place in written.places[:written.count] {
		name := element_place_name(&place)
		if element_places_find(now, name) == nil {
			system.log_fact(.Info, Element_Gone{window = window, element = value_kinds.text_field(name, ELEMENT_FACT_TEXT_BYTES)})
		}
	}
	element_places_keep(written, now)
}

// element_places_keep keeps the set of the frame that is drawn now as the
// set that was written.
element_places_keep :: proc "contextless" (written, now: ^Element_Places) {
	written.places = now.places
	written.count = now.count
	written.dropped = now.dropped
}
