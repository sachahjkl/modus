package compositor

import "modus:contract/value_kinds"
import "modus:support/interface"
import "modus:support/system"

// The log facts of the compositor (src/md/features/log_facts.md, "The facts
// of the compositor and of the windows"): the lines of the windows that a
// reader groups or filters, as records of fields. Each fact template is
// the sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A line whose sentence
// differs by its case is one fact type for each case: the template has no
// condition. No field has the name of a column of the head of facts():
// number, time, process, level.
//
// The title of a window is a system.Name: 31 bytes at most and a zero
// byte, as a Module_Name_Field holds it whole. It is the last field: the
// serial line of a fact stops at its last byte that is not zero, so the
// zeros after a short title cost no byte.

// A window has a surface: the first one, or the new one after a resize.
// Its size, and the place of its surface on the screen.
@(log_fact = "compositor: surface {window} {width}x{height} at {x},{y}")
Surface_Made :: struct {
	width:  u64,
	height: u64,
	x:      u64,
	y:      u64,
	window: value_kinds.Module_Name_Field,
}

// The first picture of a window reached the screen: from here on the
// window is in the menu of the windows.
@(log_fact = "compositor: window {window} is shown")
Window_Shown :: struct {
	window: value_kinds.Module_Name_Field,
}

// A window came to the front: by the menu of the windows or by the
// palette.
@(log_fact = "compositor: window {window} in front")
Window_In_Front :: struct {
	window: value_kinds.Module_Name_Field,
}

// A window closed after records whose word names no command: the count
// that the first such record announced.
@(log_fact = "compositor: window {window} closed after {refused} records whose word names no command")
Window_Closed_After_Refused_Commands :: struct {
	refused: u64,
	window:  value_kinds.Module_Name_Field,
}

// A window closed after clipboard records that the compositor refused.
@(log_fact = "compositor: window {window} closed after {refused} clipboard records that no key of the principal started or that the border refused")
Window_Closed_After_Refused_Clipboard_Records :: struct {
	refused: u64,
	window:  value_kinds.Module_Name_Field,
}

// A window closed while its queue lost records: the end of the loss.
@(log_fact = "compositor: window {window} closed and did not read its events: {key_records} key records, {pointer_records} pointer records and {other_records} other records were lost")
Window_Closed_With_Lost_Events :: struct {
	key_records:     u64,
	pointer_records: u64,
	other_records:   u64,
	window:          value_kinds.Module_Name_Field,
}

// The ring of a window and its queue are full: a record is lost, and the
// loss begins.
@(log_fact = "compositor: window {window} does not read its events: {waiting} records wait for it, and a new record is lost")
Window_Events_Lost :: struct {
	waiting: u64,
	window:  value_kinds.Module_Name_Field,
}

// A window that lost records reads its events again: the end of the loss,
// with its counts.
@(log_fact = "compositor: window {window} reads its events again: {key_records} key records, {pointer_records} pointer records and {other_records} other records were lost")
Window_Events_Read_Again :: struct {
	key_records:     u64,
	pointer_records: u64,
	other_records:   u64,
	window:          value_kinds.Module_Name_Field,
}

// The first record of a window whose word names no command: the next
// ones are counted, and Window_Closed_After_Refused_Commands gives the
// count.
@(log_fact = "compositor: a window sent the word {word}, which names no command; the next ones are counted, and the count comes when the window closes")
Window_Word_Refused :: struct {
	word: u64,
}

// A word of the control ring that names no control command.
@(log_fact = "compositor: the root service sent the control word {word}, which names no control command")
Control_Word_Refused :: struct {
	word: u64,
}

// A control command that goes from the compositor to the root service,
// never the other way.
@(log_fact = "compositor: the root service sent the control command {word}, which the compositor does not take")
Control_Command_Not_Taken :: struct {
	word: u64,
}

// A word of the input ring that names no input.
@(log_fact = "compositor: the input service sent the word {word}, which names no input")
Input_Word_Refused :: struct {
	word: u64,
}

// A window asked for a pointer shape that names no shape.
@(log_fact = "compositor: {window} asks for the pointer shape {shape}, which names no shape: it is refused")
Pointer_Shape_Refused :: struct {
	shape:  u64,
	window: value_kinds.Module_Name_Field,
}

// The palette placed a named element, or moved it: its rectangle in
// pixels of the screen. The palette is a panel of the compositor, not a
// window, so the compositor writes these facts, as interface.Element_Place
// for a window.
@(log_fact = "compositor: the palette: the element {element} at {x},{y},{width},{height}")
Palette_Element_Place :: struct {
	x:       i64,
	y:       i64,
	width:   i64,
	height:  i64,
	element: [40]u8,
}

// A named element that the palette no longer has: each one when it closes.
@(log_fact = "compositor: the palette: the element {element} is gone")
Palette_Element_Gone :: struct {
	element: [40]u8,
}

// The tool reads the length of a Text field as a literal: the field of an
// element name has the bytes of the field of a window.
#assert(size_of(Palette_Element_Place) == 4 * size_of(i64) + interface.ELEMENT_FACT_TEXT_BYTES && size_of(Palette_Element_Gone) == interface.ELEMENT_FACT_TEXT_BYTES)

// palette_element_places_publish writes the facts of the elements of the
// palette that changed since the set that was written, as
// interface.element_places_publish does for a window, then keeps the set
// of the frame.
palette_element_places_publish :: proc "contextless" () {
	written, now := &palette_element_places_written, &palette_element_places_drawn
	for &place in now.places[:now.count] {
		if !interface.element_place_changed(written, &place) {
			continue
		}
		area := place.area
		system.log_fact(.Info, Palette_Element_Place{element = value_kinds.text_field(interface.element_place_name(&place), interface.ELEMENT_FACT_TEXT_BYTES), x = i64(area.x), y = i64(area.y), width = i64(area.width), height = i64(area.height)})
	}
	for &place in written.places[:written.count] {
		name := interface.element_place_name(&place)
		if interface.element_places_find(now, name) == nil {
			system.log_fact(.Info, Palette_Element_Gone{element = value_kinds.text_field(name, interface.ELEMENT_FACT_TEXT_BYTES)})
		}
	}
	interface.element_places_keep(written, now)
}

// window_field gives the field of the title of a window: its text before
// the first zero byte.
window_field :: proc "contextless" (title: []u8) -> value_kinds.Module_Name_Field {
	return value_kinds.module_name_field(system.name_of(title))
}
