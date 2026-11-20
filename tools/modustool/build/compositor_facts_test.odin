package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the compositor and of the windows against the lines
// that they replaced (src/md/features/log_facts.md, "The facts of the
// compositor and of the windows"), and the read of the element lines from
// the fields of their facts. The fact types come from the extraction of the
// tool on the sources of the compositor and of the package interface: a
// host test does not depend on a build.

// The folder of the support package interface.
@(private = "file")
INTERFACE_SOURCES :: foundation.SOURCE_FOLDER_SUPPORT + "/interface"
// The bytes of a Text field of an element line: interface.ELEMENT_FACT_TEXT_BYTES.
@(private = "file")
ELEMENT_TEXT_BYTES :: 40
// The longest window title of the window layer (display.Window.title), and
// the longest element name (interface.ELEMENT_NAME_CAPACITY).
@(private = "file")
WINDOW_TITLE_BYTES_MOST :: 32
@(private = "file")
ELEMENT_NAME_BYTES_MOST :: 32

// Each fact type of the compositor writes the line of before, byte for
// byte, at the edges of its fields: a title of 31 bytes, the longest that
// a system.Name holds; the counts 0 and max(u64).
@(test)
the_facts_of_the_compositor_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "compositor")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "compositor", type_name, values)
	}
	window := strings.repeat("w", value_kinds.MODULE_NAME_FIELD_BYTES - 1, context.temp_allocator)
	short := "c"
	most := max(u64)
	facts_expect_line(t, render(t, file, "Surface_Made", {{"window", window}, {"width", most}, {"height", u64(0)}, {"x", u64(0)}, {"y", most}}), line_of_before("compositor: surface ", window, " ", most, "x", u64(0), " at ", u64(0), ",", most))
	facts_expect_line(t, render(t, file, "Surface_Made", {{"window", short}, {"width", u64(1)}, {"height", u64(1)}, {"x", most}, {"y", u64(0)}}), line_of_before("compositor: surface ", short, " ", u64(1), "x", u64(1), " at ", most, ",", u64(0)))
	facts_expect_line(t, render(t, file, "Window_Shown", {{"window", window}}), line_of_before("compositor: window ", window, " is shown"))
	facts_expect_line(t, render(t, file, "Window_In_Front", {{"window", window}}), line_of_before("compositor: window ", window, " in front"))
	refused_counts := [2]u64{1, most}
	for refused in refused_counts {
		facts_expect_line(t, render(t, file, "Window_Closed_After_Refused_Commands", {{"window", window}, {"refused", refused}}), line_of_before("compositor: window ", window, " closed after ", refused, " records whose word names no command"))
		facts_expect_line(t, render(t, file, "Window_Closed_After_Refused_Clipboard_Records", {{"window", window}, {"refused", refused}}), line_of_before("compositor: window ", window, " closed after ", refused, " clipboard records that no key of the principal started or that the border refused"))
	}
	facts_expect_line(t, render(t, file, "Window_Closed_With_Lost_Events", {{"window", window}, {"key_records", u64(0)}, {"pointer_records", most}, {"other_records", u64(1)}}), line_of_before("compositor: window ", window, " closed and did not read its events: ", u64(0), " key records, ", most, " pointer records and ", u64(1), " other records were lost"))
	facts_expect_line(t, render(t, file, "Window_Events_Lost", {{"window", window}, {"waiting", most}}), line_of_before("compositor: window ", window, " does not read its events: ", most, " records wait for it, and a new record is lost"))
	facts_expect_line(t, render(t, file, "Window_Events_Read_Again", {{"window", window}, {"key_records", most}, {"pointer_records", u64(0)}, {"other_records", most}}), line_of_before("compositor: window ", window, " reads its events again: ", most, " key records, ", u64(0), " pointer records and ", most, " other records were lost"))
	// A word of a ring is a u32 that another party wrote: 0, which names
	// None, and the largest word.
	words := [2]u64{0, u64(max(u32))}
	for word in words {
		facts_expect_line(t, render(t, file, "Window_Word_Refused", {{"word", word}}), line_of_before("compositor: a window sent the word ", word, ", which names no command; the next ones are counted, and the count comes when the window closes"))
		facts_expect_line(t, render(t, file, "Control_Word_Refused", {{"word", word}}), line_of_before("compositor: the root service sent the control word ", word, ", which names no control command"))
		facts_expect_line(t, render(t, file, "Control_Command_Not_Taken", {{"word", word}}), line_of_before("compositor: the root service sent the control command ", word, ", which the compositor does not take"))
		facts_expect_line(t, render(t, file, "Input_Word_Refused", {{"word", word}}), line_of_before("compositor: the input service sent the word ", word, ", which names no input"))
	}
	facts_expect_line(t, render(t, file, "Pointer_Shape_Refused", {{"window", window}, {"shape", most}}), line_of_before("compositor: ", window, " asks for the pointer shape ", most, ", which names no shape: it is refused"))
	element := strings.repeat("e", ELEMENT_NAME_BYTES_MOST, context.temp_allocator)
	facts_expect_line(t, render(t, file, "Palette_Element_Placed", {{"element", element}, {"x", signed_bits(min(i64))}, {"y", signed_bits(max(i64))}, {"width", signed_bits(0)}, {"height", signed_bits(-1)}}), line_of_before("compositor: the palette: the element ", element, " at ", min(i64), ",", max(i64), ",", i64(0), ",", i64(-1)))
	facts_expect_line(t, render(t, file, "Palette_Element_Gone", {{"element", element}}), line_of_before("compositor: the palette: the element ", element, " is gone"))
}

// Each fact type of the element lines of a window writes the line of
// before, byte for byte: a title and an element name of 32 bytes, the
// longest that the window layer keeps, the least and the largest i64, and
// a name with spaces.
@(test)
the_element_lines_of_a_window_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, INTERFACE_SOURCES)
	if !ok {
		return
	}
	window := strings.repeat("t", WINDOW_TITLE_BYTES_MOST, context.temp_allocator)
	element := strings.repeat("n", ELEMENT_NAME_BYTES_MOST, context.temp_allocator)
	facts_expect_line(t, fact_test_render(t, file, "interface", "Element_Placed", {{"window", window}, {"element", element}, {"x", signed_bits(min(i64))}, {"y", signed_bits(max(i64))}, {"width", signed_bits(0)}, {"height", signed_bits(-1)}}), line_of_before("interface: ", window, ": the element ", element, " at ", min(i64), ",", max(i64), ",", i64(0), ",", i64(-1)))
	facts_expect_line(t, fact_test_render(t, file, "interface", "Element_Placed", {{"window", "debugger_window"}, {"element", "scroll bar arrow up"}, {"x", signed_bits(4)}, {"y", signed_bits(28)}, {"width", signed_bits(16)}, {"height", signed_bits(16)}}), line_of_before("interface: ", "debugger_window", ": the element ", "scroll bar arrow up", " at ", i64(4), ",", i64(28), ",", i64(16), ",", i64(16)))
	facts_expect_line(t, fact_test_render(t, file, "interface", "Element_Gone", {{"window", window}, {"element", element}}), line_of_before("interface: ", window, ": the element ", element, " is gone"))
}

// One line of a fact for the tests of the element reader: the record of a
// fact type of a module file, with the values of its fields, as the serial
// port gives it, from a process.
@(private = "file")
element_test_line :: proc(t: ^testing.T, file: []u8, package_name, type_name, process: string, values: []Fact_Test_Field) -> Fact_Line_Place {
	key, bytes, made := fact_test_record(t, file, package_name, type_name, values)
	if !made {
		return {}
	}
	line := Fact_Line{key_tag = op.log_fact_key_tag(key)}
	line.module_tag = element_test_module_tag(package_name)
	copy(line.values[:], bytes)
	// The serial line holds the values up to their last byte that is not
	// zero.
	for index in 0 ..< len(bytes) {
		if bytes[index] != 0 {
			line.value_count = index + 1
		}
	}
	return {process = process, line = line}
}

// The head of the hash of the module file of a package, in these tests: one
// for each package, so the files are other modules.
@(private = "file")
element_test_module_tag :: proc(package_name: string) -> [FACT_LINE_MODULE_TAG_BYTES]u8 {
	prefix: [FACT_LINE_MODULE_TAG_BYTES]u8
	switch package_name {
	case "interface":
		prefix[0] = 1
	case "compositor":
		prefix[0] = 2
	case:
		prefix[0] = 3
	}
	return prefix
}

// The fact types of a module file as a catalog gives them.
@(private = "file")
element_test_known :: proc(file: []u8, package_name: string) -> []Fact_Catalog_Type {
	known := make([dynamic]Fact_Catalog_Type, context.temp_allocator)
	for row_index in 1 ..< module.count(file, .Facts) {
		row, description, row_ok := module.fact(file, row_index)
		if !row_ok {
			continue
		}
		type_name := module.string_at(file, description.name_offset, description.name_count)
		append(&known, Fact_Catalog_Type{module_tag = element_test_module_tag(package_name), file = file, key = row.key, description = description, name = strings.concatenate({package_name, ".", type_name}, context.temp_allocator)})
	}
	return known[:]
}

// The reader of the element lines: the last line of the element wins, a
// line of another element, of another window or of a name that only
// starts with the name is not its line, a line of the palette from another
// process than the compositor is not a line of the palette, a line with
// more value bytes than its record and a line of another module are read
// as no line. The place comes from the fields, a negative one too.
@(test)
the_tool_reads_an_element_line_from_the_fields_of_its_fact :: proc(t: ^testing.T) {
	interface_file, interface_ok := facts_file_of_folder(t, INTERFACE_SOURCES)
	compositor_file, compositor_ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "compositor")
	if !interface_ok || !compositor_ok {
		return
	}
	known := make([dynamic]Fact_Catalog_Type, context.temp_allocator)
	append(&known, ..element_test_known(interface_file, "interface"))
	append(&known, ..element_test_known(compositor_file, "compositor"))
	window_types := element_fact_types(known[:], "debugger_window")
	palette_types := element_fact_types(known[:], PALETTE_ELEMENTS)
	testing.expect(t, len(window_types.placed) == 1 && len(window_types.gone) == 1 && !window_types.palette)
	testing.expect(t, len(palette_types.placed) == 1 && len(palette_types.gone) == 1 && palette_types.palette)

	placed :: proc(t: ^testing.T, file: []u8, window, element: string, x, y, width, height: i64) -> Fact_Line_Place {
		return element_test_line(t, file, "interface", "Element_Placed", "debugger_window", {{"window", window}, {"element", element}, {"x", signed_bits(x)}, {"y", signed_bits(y)}, {"width", signed_bits(width)}, {"height", signed_bits(height)}})
	}
	gone :: proc(t: ^testing.T, file: []u8, window, element: string) -> Fact_Line_Place {
		return element_test_line(t, file, "interface", "Element_Gone", "debugger_window", {{"window", window}, {"element", element}})
	}
	read :: proc(lines: []Fact_Line_Place, types: Element_Fact_Types, owner, element: string) -> (rectangle: [4]int, found: Element_Line) {
		rectangle[0], rectangle[1], rectangle[2], rectangle[3], found = element_line_read(lines, types, owner, element)
		return
	}

	// No line at all.
	_, nothing := read(nil, window_types, "debugger_window", "frame 1")
	testing.expect_value(t, nothing, Element_Line.Absent)
	// Lines of other elements only: a name that only starts with the name,
	// another window, an empty name.
	others := [?]Fact_Line_Place{placed(t, interface_file, "debugger_window", "frame 10", 1, 2, 3, 4), placed(t, interface_file, "inspect", "frame 1", 1, 2, 3, 4), placed(t, interface_file, "debugger_window", "", 1, 2, 3, 4), placed(t, interface_file, "debugger_window_two", "frame 1", 1, 2, 3, 4)}
	_, other_found := read(others[:], window_types, "debugger_window", "frame 1")
	testing.expect_value(t, other_found, Element_Line.Absent)
	// A line with one value byte past its record, and a line of another
	// module with the same key: no line.
	too_long := placed(t, interface_file, "debugger_window", "frame 1", 1, 2, 3, 4)
	too_long.line.value_count = int(window_types.placed[0].description.size) + 1
	other_module := placed(t, interface_file, "debugger_window", "frame 1", 1, 2, 3, 4)
	other_module.line.module_tag = element_test_module_tag("another")
	refused := [?]Fact_Line_Place{too_long, other_module}
	_, refused_found := read(refused[:], window_types, "debugger_window", "frame 1")
	testing.expect_value(t, refused_found, Element_Line.Absent)
	// Placed, then gone: gone. Gone, then placed again: the last place, a
	// negative one, and the largest that an int holds.
	sequence := [?]Fact_Line_Place{placed(t, interface_file, "debugger_window", "frame 1", 10, 20, 30, 40), gone(t, interface_file, "debugger_window", "frame 1")}
	_, after_gone := read(sequence[:], window_types, "debugger_window", "frame 1")
	testing.expect_value(t, after_gone, Element_Line.Gone)
	again := [?]Fact_Line_Place{sequence[0], sequence[1], placed(t, interface_file, "debugger_window", "frame 1", -7, 0, max(i64), 1), gone(t, interface_file, "debugger_window", "frame 10")}
	place, placed_found := read(again[:], window_types, "debugger_window", "frame 1")
	testing.expect_value(t, placed_found, Element_Line.Placed)
	testing.expect(t, place == [4]int{-7, 0, int(max(i64)), 1})
	// The element gone in another window leaves this window as it is.
	other_gone := [?]Fact_Line_Place{again[2], gone(t, interface_file, "inspect", "frame 1")}
	_, still := read(other_gone[:], window_types, "debugger_window", "frame 1")
	testing.expect_value(t, still, Element_Line.Placed)

	// The palette: its facts come from the compositor only, and a line of
	// a window titled as the owner of the palette is not one of them.
	palette_line := element_test_line(t, compositor_file, "compositor", "Palette_Element_Placed", "compositor", {{"element", "round_robin"}, {"x", signed_bits(5)}, {"y", signed_bits(6)}, {"width", signed_bits(7)}, {"height", signed_bits(8)}})
	forged := palette_line
	forged.process = "console"
	titled := placed(t, interface_file, PALETTE_ELEMENTS, "round_robin", 1, 1, 1, 1)
	not_palette := [?]Fact_Line_Place{forged, titled}
	_, forged_found := read(not_palette[:], palette_types, PALETTE_ELEMENTS, "round_robin")
	testing.expect_value(t, forged_found, Element_Line.Absent)
	palette_lines := [?]Fact_Line_Place{palette_line, forged}
	palette_place, palette_found := read(palette_lines[:], palette_types, PALETTE_ELEMENTS, "round_robin")
	testing.expect_value(t, palette_found, Element_Line.Placed)
	testing.expect(t, palette_place == [4]int{5, 6, 7, 8})
	palette_closed := [?]Fact_Line_Place{palette_line, element_test_line(t, compositor_file, "compositor", "Palette_Element_Gone", "compositor", {{"element", "round_robin"}})}
	_, closed_found := read(palette_closed[:], palette_types, PALETTE_ELEMENTS, "round_robin")
	testing.expect_value(t, closed_found, Element_Line.Gone)
}

// The Text field of an element line holds the longest title and the
// longest name of the window layer, and its zero byte. The name is the
// last field, so the serial line of a short name ends with it.
@(test)
an_element_line_holds_the_longest_title_and_name :: proc(t: ^testing.T) {
	testing.expect(t, ELEMENT_TEXT_BYTES > WINDOW_TITLE_BYTES_MOST && ELEMENT_TEXT_BYTES > ELEMENT_NAME_BYTES_MOST)
	file, ok := facts_file_of_folder(t, INTERFACE_SOURCES)
	if !ok {
		return
	}
	_, _, description, found := module.fact_find(file, fact_key("interface", "Element_Placed"))
	if !testing.expect(t, found && description.size == 2 * ELEMENT_TEXT_BYTES + 4 * 8) {
		return
	}
	element_offset: u32 = 0
	has_element := false
	for number in 0 ..< description.field_count {
		item, item_ok := module.field(file, description, number)
		if item_ok && module.string_at(file, item.name_offset, item.name_count) == "element" {
			element_offset, has_element = item.offset, true
		}
	}
	testing.expect(t, has_element && element_offset == description.size - ELEMENT_TEXT_BYTES)
	// A short name: the values end with its last byte.
	_, bytes, made := fact_test_record(t, file, "interface", "Element_Placed", {{"window", "inspect"}, {"element", "network"}, {"x", signed_bits(1)}})
	if made {
		last := -1
		for index in 0 ..< len(bytes) {
			if bytes[index] != 0 {
				last = index
			}
		}
		testing.expect_value(t, last, int(element_offset) + len("network") - 1)
	}
}
