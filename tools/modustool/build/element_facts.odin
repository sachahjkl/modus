package build

// The element lines of a log, read from the fields of their facts
// (src/md/infrastructure/test_pointer.md; src/md/features/log_facts.md,
// "The facts of the compositor and of the windows"). A window writes the
// fact interface.Element_Placed for each named element whose place changes,
// in pixels of its surface, and interface.Element_Gone when its frame no
// longer has the name. The palette is a panel of the compositor, not a
// window: the compositor writes compositor.Palette_Element_Placed and
// compositor.Palette_Element_Gone, in pixels of the screen. A step of a
// machine test reads the place of an element from the fields of the last
// such fact, never from its sentence.

// The owner of a step that names an element of the palette, in place of
// the title of a window.
PALETTE_ELEMENTS :: "the palette"

// The fact types of the element lines: the place and the end of an element
// of a window, and of an element of the palette.
ELEMENT_PLACE_FACT :: "interface.Element_Placed"
ELEMENT_GONE_FACT :: "interface.Element_Gone"
PALETTE_ELEMENT_PLACE_FACT :: "compositor.Palette_Element_Placed"
PALETTE_ELEMENT_GONE_FACT :: "compositor.Palette_Element_Gone"
// The process that writes the facts of the palette.
PALETTE_ELEMENT_PROCESS :: "compositor"

// Where the last element line of an element puts it.
Element_Line :: enum {
	Absent, // The log has no line of the element yet.
	Gone, // The last line says that the element is gone.
	Placed, // The last line gives its rectangle.
}

// The fact types that the element lines of an owner have in the catalog of
// the build: each module that writes them has its own type.
Element_Fact_Types :: struct {
	placed, gone: []Fact_Step_Type,
	palette:      bool, // The owner is the palette: the facts have no field window, and the compositor writes them.
}

// element_fact_types gives the fact types of the element lines of an
// owner, among the fact types of a catalog (fact_catalog_types).
element_fact_types :: proc(known: []Fact_Catalog_Type, owner: string) -> Element_Fact_Types {
	if owner == PALETTE_ELEMENTS {
		return {placed = fact_types_of_name(known, PALETTE_ELEMENT_PLACE_FACT), gone = fact_types_of_name(known, PALETTE_ELEMENT_GONE_FACT), palette = true}
	}
	return {placed = fact_types_of_name(known, ELEMENT_PLACE_FACT), gone = fact_types_of_name(known, ELEMENT_GONE_FACT)}
}

// element_fact_names says if the record of an element line names the
// element of the owner: the field element, and the field window for a
// window. A field that the record lacks names nothing.
element_fact_names :: proc(type: Fact_Step_Type, values: []u8, owner, element: string, palette: bool) -> bool {
	named, has_name := fact_field_value(type, values, "element")
	if !has_name || !named.is_text || named.text != element {
		return false
	}
	if palette {
		return true
	}
	window, has_window := fact_field_value(type, values, "window")
	return has_window && window.is_text && window.text == owner
}

// element_line_read reads the last element line of an element in the lines
// of facts of a log: the rectangle that its fields give, in pixels of the
// surface of the window or of the screen for the palette. It compares the
// fields with the owner and the element whole, so the line of "frame 1" is
// not the line of "frame 10". A line of the palette that another process
// wrote is not a line of the palette. A line whose record lacks a field of
// the rectangle gives no place.
element_line_read :: proc(lines: []Fact_Line_Place, types: Element_Fact_Types, owner, element: string) -> (x, y, width, height: int, found: Element_Line) {
	rectangle_fields := [4]string{"x", "y", "width", "height"}
	#reverse for place in lines {
		if types.palette && place.process != PALETTE_ELEMENT_PROCESS {
			continue
		}
		if gone_type, gone_values, is_gone := fact_line_of_types(types.gone, place.line); is_gone {
			if element_fact_names(gone_type, gone_values, owner, element, types.palette) {
				return 0, 0, 0, 0, .Gone
			}
			continue
		}
		placed_type, placed_values, is_placed := fact_line_of_types(types.placed, place.line)
		if !is_placed || !element_fact_names(placed_type, placed_values, owner, element, types.palette) {
			continue
		}
		rectangle: [4]int
		for name, field_index in rectangle_fields {
			value, has_value := fact_field_value(placed_type, placed_values, name)
			if !has_value || value.is_text {
				return 0, 0, 0, 0, .Absent
			}
			rectangle[field_index] = int(value.integer)
		}
		return rectangle[0], rectangle[1], rectangle[2], rectangle[3], .Placed
	}
	return 0, 0, 0, 0, .Absent
}
