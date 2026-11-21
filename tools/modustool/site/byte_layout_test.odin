package site

import "core:fmt"
import "core:strings"
import "core:testing"
import draw_record "modus:contract/draw_record"
import module "modus:contract/module"
import "modus:contract/output"
import "modustool:foundation"

// One field as the compiler places it, written with offset_of and size_of,
// so that the test does not read the layout through the type information
// that the tool reads.
@(private = "file")
Expected_Field :: struct {
	key:    string,
	name:   string,
	offset: uintptr, // The type that offset_of gives.
	size:   int,
}

@(private = "file")
expected_fields :: proc() -> []Expected_Field {
	header: module.Header
	entry: module.Table_Entry
	segment: module.Segment
	import_record: module.Import
	slot: module.Slot
	export_record: module.Export
	function: module.Function
	record: module.Record
	field: module.Field
	documentation: module.Documentation
	budget: module.Budget_Request
	fact: module.Fact
	own_hash_place: module.Own_Hash_Place
	record_output: module.Record_Output
	record_input: module.Record_Input
	enum_type: module.Enum_Type
	member: module.Member
	member_text: module.Member_Text
	compartment_word: output.Compartment_Word
	end_words: output.End_Words
	list_head: output.Wiring_List_Head
	wiring: output.Wiring
	draw: draw_record.Draw_Record
	rectangle: draw_record.Rectangle_Fields
	gradient: draw_record.Gradient_Fields
	text: draw_record.Text_Fields
	picture: draw_record.Picture_Fields
	grid: draw_record.Text_Grid_Fields
	path: draw_record.Path_Fields
	point: draw_record.Path_Point_Record
	rows := [?]Expected_Field {
		{"module.Header", "magic", offset_of(module.Header, magic), size_of(header.magic)},
		{"module.Header", "version", offset_of(module.Header, version), size_of(header.version)},
		{"module.Header", "header_size", offset_of(module.Header, header_size), size_of(header.header_size)},
		{"module.Header", "must_understand", offset_of(module.Header, must_understand), size_of(header.must_understand)},
		{"module.Header", "machine", offset_of(module.Header, machine), size_of(header.machine)},
		{"module.Header", "table_count", offset_of(module.Header, table_count), size_of(header.table_count)},
		{"module.Header", "memory_size", offset_of(module.Header, memory_size), size_of(header.memory_size)},
		{"module.Header", "entry_export", offset_of(module.Header, entry_export), size_of(header.entry_export)},
		{"module.Header", "reserved", offset_of(module.Header, reserved), size_of(header.reserved)},
		{"module.Table_Entry", "offset", offset_of(module.Table_Entry, offset), size_of(entry.offset)},
		{"module.Table_Entry", "count", offset_of(module.Table_Entry, count), size_of(entry.count)},
		{"module.Table_Entry", "record_size", offset_of(module.Table_Entry, record_size), size_of(entry.record_size)},
		{"module.Segment", "file_offset", offset_of(module.Segment, file_offset), size_of(segment.file_offset)},
		{"module.Segment", "file_size", offset_of(module.Segment, file_size), size_of(segment.file_size)},
		{"module.Segment", "memory_offset", offset_of(module.Segment, memory_offset), size_of(segment.memory_offset)},
		{"module.Segment", "memory_size", offset_of(module.Segment, memory_size), size_of(segment.memory_size)},
		{"module.Segment", "flags", offset_of(module.Segment, flags), size_of(segment.flags)},
		{"module.Segment", "reserved", offset_of(module.Segment, reserved), size_of(segment.reserved)},
		{"module.Import", "hash", offset_of(module.Import, hash), size_of(import_record.hash)},
		{"module.Slot", "memory_offset", offset_of(module.Slot, memory_offset), size_of(slot.memory_offset)},
		{"module.Slot", "import_index", offset_of(module.Slot, import_index), size_of(slot.import_index)},
		{"module.Slot", "export_index", offset_of(module.Slot, export_index), size_of(slot.export_index)},
		{"module.Export", "code_offset", offset_of(module.Export, code_offset), size_of(export_record.code_offset)},
		{"module.Export", "function", offset_of(module.Export, function), size_of(export_record.function)},
		{"module.Export", "reserved", offset_of(module.Export, reserved), size_of(export_record.reserved)},
		{"module.Rebases", "word", 0, module.REBASE_WORD_SIZE},
		{"module.Function", "name_offset", offset_of(module.Function, name_offset), size_of(function.name_offset)},
		{"module.Function", "name_count", offset_of(module.Function, name_count), size_of(function.name_count)},
		{"module.Function", "about_offset", offset_of(module.Function, about_offset), size_of(function.about_offset)},
		{"module.Function", "about_count", offset_of(module.Function, about_count), size_of(function.about_count)},
		{"module.Function", "parameter_names", offset_of(module.Function, parameter_names), size_of(function.parameter_names)},
		{"module.Function", "parameter_count", offset_of(module.Function, parameter_count), size_of(function.parameter_count)},
		{"module.Function", "result", offset_of(module.Function, result), size_of(function.result)},
		{"module.Function", "parameters", offset_of(module.Function, parameters), size_of(function.parameters)},
		{"module.Function", "parameter_name_counts", offset_of(module.Function, parameter_name_counts), size_of(function.parameter_name_counts)},
		{"module.Function", "parameter_directions", offset_of(module.Function, parameter_directions), size_of(function.parameter_directions)},
		{"module.Function", "optional_parameters", offset_of(module.Function, optional_parameters), size_of(function.optional_parameters)},
		{"module.Function", "text_offset", offset_of(module.Function, text_offset), size_of(function.text_offset)},
		{"module.Function", "text_count", offset_of(module.Function, text_count), size_of(function.text_count)},
		{"module.Function", "parameter_details", offset_of(module.Function, parameter_details), size_of(function.parameter_details)},
		{"module.Function", "result_detail", offset_of(module.Function, result_detail), size_of(function.result_detail)},
		{"module.Function", "error_record", offset_of(module.Function, error_record), size_of(function.error_record)},
		{"module.Documentation", "about_offset", offset_of(module.Documentation, about_offset), size_of(documentation.about_offset)},
		{"module.Documentation", "about_count", offset_of(module.Documentation, about_count), size_of(documentation.about_count)},
		{"module.Documentation", "text_offset", offset_of(module.Documentation, text_offset), size_of(documentation.text_offset)},
		{"module.Documentation", "text_count", offset_of(module.Documentation, text_count), size_of(documentation.text_count)},
		{"module.Record", "name_offset", offset_of(module.Record, name_offset), size_of(record.name_offset)},
		{"module.Record", "name_count", offset_of(module.Record, name_count), size_of(record.name_count)},
		{"module.Record", "size", offset_of(module.Record, size), size_of(record.size)},
		{"module.Record", "first_field", offset_of(module.Record, first_field), size_of(record.first_field)},
		{"module.Record", "field_count", offset_of(module.Record, field_count), size_of(record.field_count)},
		{"module.Record", "reserved", offset_of(module.Record, reserved), size_of(record.reserved)},
		{"module.Field", "name_offset", offset_of(module.Field, name_offset), size_of(field.name_offset)},
		{"module.Field", "name_count", offset_of(module.Field, name_count), size_of(field.name_count)},
		{"module.Field", "offset", offset_of(module.Field, offset), size_of(field.offset)},
		{"module.Field", "type", offset_of(module.Field, type), size_of(field.type)},
		{"module.Field", "unsigned", offset_of(module.Field, unsigned), size_of(field.unsigned)},
		{"module.Field", "integer_unit", offset_of(module.Field, integer_unit), size_of(field.integer_unit)},
		{"module.Field", "detail", offset_of(module.Field, detail), size_of(field.detail)},
		{"module.Field", "kind", offset_of(module.Field, kind), size_of(field.kind)},
		{"module.Field", "contract_enum", offset_of(module.Field, contract_enum), size_of(field.contract_enum)},
		{"module.Field", "reserved", offset_of(module.Field, reserved), size_of(field.reserved)},
		{"module.Budget_Request", "pages", offset_of(module.Budget_Request, pages), size_of(budget.pages)},
		{"module.Budget_Request", "processes", offset_of(module.Budget_Request, processes), size_of(budget.processes)},
		{"module.Budget_Request", "threads", offset_of(module.Budget_Request, threads), size_of(budget.threads)},
		{"module.Fact", "key", offset_of(module.Fact, key), size_of(fact.key)},
		{"module.Fact", "record", offset_of(module.Fact, record), size_of(fact.record)},
		{"module.Fact", "template_offset", offset_of(module.Fact, template_offset), size_of(fact.template_offset)},
		{"module.Fact", "template_count", offset_of(module.Fact, template_count), size_of(fact.template_count)},
		{"module.Fact", "package_offset", offset_of(module.Fact, package_offset), size_of(fact.package_offset)},
		{"module.Fact", "package_count", offset_of(module.Fact, package_count), size_of(fact.package_count)},
		{"module.Fact", "reserved", offset_of(module.Fact, reserved), size_of(fact.reserved)},
		{"module.Own_Hash_Place", "memory_offset", offset_of(module.Own_Hash_Place, memory_offset), size_of(own_hash_place.memory_offset)},
		{"module.Record_Output", "name_offset", offset_of(module.Record_Output, name_offset), size_of(record_output.name_offset)},
		{"module.Record_Output", "name_count", offset_of(module.Record_Output, name_count), size_of(record_output.name_count)},
		{"module.Record_Output", "about_offset", offset_of(module.Record_Output, about_offset), size_of(record_output.about_offset)},
		{"module.Record_Output", "about_count", offset_of(module.Record_Output, about_count), size_of(record_output.about_count)},
		{"module.Record_Output", "text_offset", offset_of(module.Record_Output, text_offset), size_of(record_output.text_offset)},
		{"module.Record_Output", "text_count", offset_of(module.Record_Output, text_count), size_of(record_output.text_count)},
		{"module.Record_Output", "record", offset_of(module.Record_Output, record), size_of(record_output.record)},
		{"module.Record_Output", "pairing", offset_of(module.Record_Output, pairing), size_of(record_output.pairing)},
		{"module.Record_Output", "reserved", offset_of(module.Record_Output, reserved), size_of(record_output.reserved)},
		{"module.Record_Output", "place", offset_of(module.Record_Output, place), size_of(record_output.place)},
		{"module.Record_Input", "name_offset", offset_of(module.Record_Input, name_offset), size_of(record_input.name_offset)},
		{"module.Record_Input", "name_count", offset_of(module.Record_Input, name_count), size_of(record_input.name_count)},
		{"module.Record_Input", "about_offset", offset_of(module.Record_Input, about_offset), size_of(record_input.about_offset)},
		{"module.Record_Input", "about_count", offset_of(module.Record_Input, about_count), size_of(record_input.about_count)},
		{"module.Record_Input", "text_offset", offset_of(module.Record_Input, text_offset), size_of(record_input.text_offset)},
		{"module.Record_Input", "text_count", offset_of(module.Record_Input, text_count), size_of(record_input.text_count)},
		{"module.Record_Input", "record", offset_of(module.Record_Input, record), size_of(record_input.record)},
		{"module.Record_Input", "terms", offset_of(module.Record_Input, terms), size_of(record_input.terms)},
		{"module.Record_Input", "wirings", offset_of(module.Record_Input, wirings), size_of(record_input.wirings)},
		{"module.Record_Input", "reserved", offset_of(module.Record_Input, reserved), size_of(record_input.reserved)},
		{"module.Record_Input", "place", offset_of(module.Record_Input, place), size_of(record_input.place)},
		{"module.Enum_Type", "name_offset", offset_of(module.Enum_Type, name_offset), size_of(enum_type.name_offset)},
		{"module.Enum_Type", "name_count", offset_of(module.Enum_Type, name_count), size_of(enum_type.name_count)},
		{"module.Enum_Type", "first_member", offset_of(module.Enum_Type, first_member), size_of(enum_type.first_member)},
		{"module.Enum_Type", "member_count", offset_of(module.Enum_Type, member_count), size_of(enum_type.member_count)},
		{"module.Enum_Type", "size", offset_of(module.Enum_Type, size), size_of(enum_type.size)},
		{"module.Enum_Type", "unsigned", offset_of(module.Enum_Type, unsigned), size_of(enum_type.unsigned)},
		{"module.Enum_Type", "reserved", offset_of(module.Enum_Type, reserved), size_of(enum_type.reserved)},
		{"module.Member", "name_offset", offset_of(module.Member, name_offset), size_of(member.name_offset)},
		{"module.Member", "name_count", offset_of(module.Member, name_count), size_of(member.name_count)},
		{"module.Member", "value", offset_of(module.Member, value), size_of(member.value)},
		{"module.Member_Text", "enum_index", offset_of(module.Member_Text, enum_index), size_of(member_text.enum_index)},
		{"module.Member_Text", "member_number", offset_of(module.Member_Text, member_number), size_of(member_text.member_number)},
		{"module.Member_Text", "text_offset", offset_of(module.Member_Text, text_offset), size_of(member_text.text_offset)},
		{"module.Member_Text", "text_count", offset_of(module.Member_Text, text_count), size_of(member_text.text_count)},
		{"module.Member_Text", "tag_offset", offset_of(module.Member_Text, tag_offset), size_of(member_text.tag_offset)},
		{"module.Member_Text", "tag_count", offset_of(module.Member_Text, tag_count), size_of(member_text.tag_count)},
		{"output.Compartment_Word", "kind", offset_of(output.Compartment_Word, kind), size_of(compartment_word.kind)},
		{"output.Compartment_Word", "serial", offset_of(output.Compartment_Word, serial), size_of(compartment_word.serial)},
		{"output.End_Words", "end", offset_of(output.End_Words, end), size_of(end_words.end)},
		{"output.End_Words", "stop_cause", offset_of(output.End_Words, stop_cause), size_of(end_words.stop_cause)},
		{"output.End_Words", "stop_outcome", offset_of(output.End_Words, stop_outcome), size_of(end_words.stop_outcome)},
		{"output.End_Words", "reserved", offset_of(output.End_Words, reserved), size_of(end_words.reserved)},
		{"output.Wiring_List_Head", "row_count", offset_of(output.Wiring_List_Head, row_count), size_of(list_head.row_count)},
		{"output.Wiring_List_Head", "handle_count", offset_of(output.Wiring_List_Head, handle_count), size_of(list_head.handle_count)},
		{"output.Wiring_List_Head", "reserved", offset_of(output.Wiring_List_Head, reserved), size_of(list_head.reserved)},
		{"output.Wiring", "writer_end", offset_of(output.Wiring, writer_end), size_of(wiring.writer_end)},
		{"output.Wiring", "writer_handle", offset_of(output.Wiring, writer_handle), size_of(wiring.writer_handle)},
		{"output.Wiring", "writer_stream", offset_of(output.Wiring, writer_stream), size_of(wiring.writer_stream)},
		{"output.Wiring", "writer_index", offset_of(output.Wiring, writer_index), size_of(wiring.writer_index)},
		{"output.Wiring", "reader_end", offset_of(output.Wiring, reader_end), size_of(wiring.reader_end)},
		{"output.Wiring", "reader_handle", offset_of(output.Wiring, reader_handle), size_of(wiring.reader_handle)},
		{"output.Wiring", "reader_index", offset_of(output.Wiring, reader_index), size_of(wiring.reader_index)},
		{"output.Wiring", "pace", offset_of(output.Wiring, pace), size_of(wiring.pace)},
		{"output.Wiring", "capacity", offset_of(output.Wiring, capacity), size_of(wiring.capacity)},
		{"output.Wiring", "terms_offset", offset_of(output.Wiring, terms_offset), size_of(wiring.terms_offset)},
		{"output.Wiring", "terms_count", offset_of(output.Wiring, terms_count), size_of(wiring.terms_count)},
		{"output.Wiring", "condition_offset", offset_of(output.Wiring, condition_offset), size_of(wiring.condition_offset)},
		{"output.Wiring", "condition_count", offset_of(output.Wiring, condition_count), size_of(wiring.condition_count)},
		{"output.Wiring", "reserved", offset_of(output.Wiring, reserved), size_of(wiring.reserved)},
		{"draw_record.Draw_Record", "kind", offset_of(draw_record.Draw_Record, kind), size_of(draw.kind)},
		{"draw_record.Draw_Record", "reserved", offset_of(draw_record.Draw_Record, reserved), size_of(draw.reserved)},
		{"draw_record.Draw_Record", "element", offset_of(draw_record.Draw_Record, element), size_of(draw.element)},
		{"draw_record.Draw_Record", "left", offset_of(draw_record.Draw_Record, left), size_of(draw.left)},
		{"draw_record.Draw_Record", "top", offset_of(draw_record.Draw_Record, top), size_of(draw.top)},
		{"draw_record.Draw_Record", "right", offset_of(draw_record.Draw_Record, right), size_of(draw.right)},
		{"draw_record.Draw_Record", "bottom", offset_of(draw_record.Draw_Record, bottom), size_of(draw.bottom)},
		{"draw_record.Draw_Record", "fields", offset_of(draw_record.Draw_Record, fields), size_of(draw.fields)},
		{"draw_record.Rectangle_Fields", "color", offset_of(draw_record.Rectangle_Fields, color), size_of(rectangle.color)},
		{"draw_record.Rectangle_Fields", "cell_x", offset_of(draw_record.Rectangle_Fields, cell_x), size_of(rectangle.cell_x)},
		{"draw_record.Rectangle_Fields", "cell_y", offset_of(draw_record.Rectangle_Fields, cell_y), size_of(rectangle.cell_y)},
		{"draw_record.Rectangle_Fields", "cell_width", offset_of(draw_record.Rectangle_Fields, cell_width), size_of(rectangle.cell_width)},
		{"draw_record.Rectangle_Fields", "cell_height", offset_of(draw_record.Rectangle_Fields, cell_height), size_of(rectangle.cell_height)},
		{"draw_record.Rectangle_Fields", "step_x", offset_of(draw_record.Rectangle_Fields, step_x), size_of(rectangle.step_x)},
		{"draw_record.Rectangle_Fields", "step_y", offset_of(draw_record.Rectangle_Fields, step_y), size_of(rectangle.step_y)},
		{"draw_record.Rectangle_Fields", "reserved", offset_of(draw_record.Rectangle_Fields, reserved), size_of(rectangle.reserved)},
		{"draw_record.Gradient_Fields", "start_x", offset_of(draw_record.Gradient_Fields, start_x), size_of(gradient.start_x)},
		{"draw_record.Gradient_Fields", "start_y", offset_of(draw_record.Gradient_Fields, start_y), size_of(gradient.start_y)},
		{"draw_record.Gradient_Fields", "end_x", offset_of(draw_record.Gradient_Fields, end_x), size_of(gradient.end_x)},
		{"draw_record.Gradient_Fields", "end_y", offset_of(draw_record.Gradient_Fields, end_y), size_of(gradient.end_y)},
		{"draw_record.Gradient_Fields", "start_color", offset_of(draw_record.Gradient_Fields, start_color), size_of(gradient.start_color)},
		{"draw_record.Gradient_Fields", "end_color", offset_of(draw_record.Gradient_Fields, end_color), size_of(gradient.end_color)},
		{"draw_record.Text_Fields", "first", offset_of(draw_record.Text_Fields, first), size_of(text.first)},
		{"draw_record.Text_Fields", "count", offset_of(draw_record.Text_Fields, count), size_of(text.count)},
		{"draw_record.Text_Fields", "color", offset_of(draw_record.Text_Fields, color), size_of(text.color)},
		{"draw_record.Text_Fields", "origin_x", offset_of(draw_record.Text_Fields, origin_x), size_of(text.origin_x)},
		{"draw_record.Text_Fields", "font", offset_of(draw_record.Text_Fields, font), size_of(text.font)},
		{"draw_record.Text_Fields", "weight", offset_of(draw_record.Text_Fields, weight), size_of(text.weight)},
		{"draw_record.Text_Fields", "size", offset_of(draw_record.Text_Fields, size), size_of(text.size)},
		{"draw_record.Text_Fields", "reserved", offset_of(draw_record.Text_Fields, reserved), size_of(text.reserved)},
		{"draw_record.Picture_Fields", "memory", offset_of(draw_record.Picture_Fields, memory), size_of(picture.memory)},
		{"draw_record.Picture_Fields", "format", offset_of(draw_record.Picture_Fields, format), size_of(picture.format)},
		{"draw_record.Picture_Fields", "memory_reserved", offset_of(draw_record.Picture_Fields, memory_reserved), size_of(picture.memory_reserved)},
		{"draw_record.Picture_Fields", "first", offset_of(draw_record.Picture_Fields, first), size_of(picture.first)},
		{"draw_record.Picture_Fields", "stride", offset_of(draw_record.Picture_Fields, stride), size_of(picture.stride)},
		{"draw_record.Picture_Fields", "generation", offset_of(draw_record.Picture_Fields, generation), size_of(picture.generation)},
		{"draw_record.Picture_Fields", "reserved", offset_of(draw_record.Picture_Fields, reserved), size_of(picture.reserved)},
		{"draw_record.Text_Grid_Fields", "first", offset_of(draw_record.Text_Grid_Fields, first), size_of(grid.first)},
		{"draw_record.Text_Grid_Fields", "count", offset_of(draw_record.Text_Grid_Fields, count), size_of(grid.count)},
		{"draw_record.Text_Grid_Fields", "columns", offset_of(draw_record.Text_Grid_Fields, columns), size_of(grid.columns)},
		{"draw_record.Text_Grid_Fields", "size", offset_of(draw_record.Text_Grid_Fields, size), size_of(grid.size)},
		{"draw_record.Text_Grid_Fields", "reserved", offset_of(draw_record.Text_Grid_Fields, reserved), size_of(grid.reserved)},
		{"draw_record.Path_Fields", "first", offset_of(draw_record.Path_Fields, first), size_of(path.first)},
		{"draw_record.Path_Fields", "count", offset_of(draw_record.Path_Fields, count), size_of(path.count)},
		{"draw_record.Path_Fields", "fill_color", offset_of(draw_record.Path_Fields, fill_color), size_of(path.fill_color)},
		{"draw_record.Path_Fields", "stroke_color", offset_of(draw_record.Path_Fields, stroke_color), size_of(path.stroke_color)},
		{"draw_record.Path_Fields", "stroke_width", offset_of(draw_record.Path_Fields, stroke_width), size_of(path.stroke_width)},
		{"draw_record.Path_Fields", "reserved", offset_of(draw_record.Path_Fields, reserved), size_of(path.reserved)},
		{"draw_record.Path_Point_Record", "command", offset_of(draw_record.Path_Point_Record, command), size_of(point.command)},
		{"draw_record.Path_Point_Record", "x", offset_of(draw_record.Path_Point_Record, x), size_of(point.x)},
		{"draw_record.Path_Point_Record", "y", offset_of(draw_record.Path_Point_Record, y), size_of(point.y)},
	}
	list := make([]Expected_Field, len(rows), context.temp_allocator)
	copy(list, rows[:])
	return list
}

// A struct with padding inside and at its end, and a field that crosses
// three rows: a u8, three bytes, a u32, a u16, 20 bytes from the byte 10 to
// the byte 30, two bytes.
@(private = "file")
Test_Record :: struct {
	first:  u8,
	second: u32,
	third:  u16,
	fourth: [20]u8,
}

// find_field gives the field of a layout by its name, or false.
@(private = "file")
find_field :: proc(layout: Byte_Layout, name: string) -> (found: Byte_Layout_Field, ok: bool) {
	for field in layout.fields {
		if !field.is_padding && field.name == name {
			return field, true
		}
	}
	return {}, false
}

// The rectangles of a layout cover each byte of its record once, and none
// passes the end of its row.
@(private = "file")
expect_each_byte_covered_once :: proc(t: ^testing.T, layout: Byte_Layout) {
	covered := make([]int, layout.size, context.temp_allocator)
	for piece in byte_layout_pieces(layout) {
		name := layout.fields[piece.field].name
		testing.expectf(t, piece.column + piece.span <= BYTE_LAYOUT_ROW_BYTES, "%s: a rectangle of %s passes the end of its row", layout.key, name)
		for row in piece.row ..< piece.row + piece.rows {
			for column in piece.column ..< piece.column + piece.span {
				place := row * BYTE_LAYOUT_ROW_BYTES + column
				if testing.expectf(t, place < layout.size, "%s: a rectangle of %s covers the byte %d, past the record", layout.key, name, place) {
					covered[place] += 1
				}
			}
		}
	}
	for count, place in covered {
		testing.expectf(t, count == 1, "%s: the byte %d is covered %d times", layout.key, place, count)
	}
}

// Each field of each layout has the offset of offset_of and the size of
// size_of; each layout has each field of its struct and no other; the rows
// of a layout follow each other with no gap and no overlap, padding
// included, up to the size of the record.
@(test)
byte_layout_offsets_agree_with_offset_of :: proc(t: ^testing.T) {
	layouts, ok := byte_layouts_read()
	testing.expect(t, ok, "the byte layouts are read")
	expected := expected_fields()
	counts := make(map[string]int, context.temp_allocator)
	for row in expected {
		counts[row.key] += 1
		layout, found := layouts[row.key]
		if !testing.expectf(t, found, "the byte layout %s exists", row.key) {
			continue
		}
		field, has_field := find_field(layout, row.name)
		if !testing.expectf(t, has_field, "the byte layout %s has the field %s", row.key, row.name) {
			continue
		}
		testing.expectf(t, uintptr(field.offset) == row.offset, "%s.%s is at %d in the layout and at %d by offset_of", row.key, row.name, field.offset, row.offset)
		testing.expectf(t, field.size == row.size, "%s.%s has %d bytes in the layout and %d by size_of", row.key, row.name, field.size, row.size)
	}
	testing.expect_value(t, size_of(u64), module.REBASE_WORD_SIZE)
	for key, layout in layouts {
		fields := 0
		position := 0
		for field in layout.fields {
			if !field.is_padding {
				fields += 1
			}
			testing.expectf(t, field.offset == position, "%s: the row %s starts at %d, after the end %d of the row before", key, field.name, field.offset, position)
			testing.expectf(t, field.size > 0, "%s: the row %s has bytes", key, field.name)
			position = field.offset + field.size
		}
		testing.expectf(t, position == layout.size, "%s: the rows end at %d, and the record has %d bytes", key, position, layout.size)
		testing.expectf(t, fields == counts[key], "%s: the layout has %d fields, and the test names %d", key, fields, counts[key])
	}
}

// The rectangles of a layout cover each byte of its record once. A field
// over whole rows is one rectangle; a field that does not start at a row
// has one rectangle for each row that it crosses. A struct with padding
// gives its rows of padding.
@(test)
byte_layout_rectangles_cover_each_byte_once :: proc(t: ^testing.T) {
	layouts, ok := byte_layouts_read()
	testing.expect(t, ok, "the byte layouts are read")
	for _, each_layout in layouts {
		expect_each_byte_covered_once(t, each_layout)
	}

	// A field over whole rows: one rectangle.
	import_pieces := byte_layout_pieces(layouts["module.Import"])
	if testing.expect_value(t, len(import_pieces), 1) {
		testing.expect_value(t, import_pieces[0].rows, size_of(module.Import) / BYTE_LAYOUT_ROW_BYTES)
		testing.expect_value(t, import_pieces[0].span, BYTE_LAYOUT_ROW_BYTES)
	}

	declarations := make(map[string]Byte_Layout_Declaration, context.temp_allocator)
	declarations["Test_Record"] = Byte_Layout_Declaration {
		fields = []Byte_Layout_Source_Field{{name = "first", type_text = "u8"}, {name = "second", type_text = "u32"}, {name = "third", type_text = "u16"}, {name = "fourth", type_text = "[20]u8", comment = "Twenty bytes."}},
	}
	source := Byte_Layout_Source{key = "test.Test_Record", file = "test", declaration = "Test_Record", info = type_info_of(Test_Record), what = "a record of the test"}
	layout, problem := byte_layout_make(source, declarations)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, layout.size, size_of(Test_Record))
	if testing.expect_value(t, len(layout.fields), 6) {
		testing.expect(t, layout.fields[1].is_padding && layout.fields[1].offset == int(offset_of(Test_Record, first)) + 1 && layout.fields[1].size == int(offset_of(Test_Record, second)) - 1, "the padding after first")
		testing.expect(t, layout.fields[5].is_padding && layout.fields[5].offset == int(offset_of(Test_Record, fourth)) + 20 && layout.fields[5].offset + layout.fields[5].size == size_of(Test_Record), "the padding at the end")
		testing.expect_value(t, layout.fields[4].comment, "Twenty bytes.")
	}
	expect_each_byte_covered_once(t, layout)
	fourth_pieces := make([dynamic]Byte_Layout_Piece, context.temp_allocator)
	for piece in byte_layout_pieces(layout) {
		if layout.fields[piece.field].name == "fourth" {
			append(&fourth_pieces, piece)
		}
	}
	if testing.expect_value(t, len(fourth_pieces), 3) {
		testing.expect(t, fourth_pieces[0].first && !fourth_pieces[1].first && !fourth_pieces[2].first, "the first piece of a field holds its size, the others say continued")
		testing.expect_value(t, fourth_pieces[0].column, int(offset_of(Test_Record, fourth)) % BYTE_LAYOUT_ROW_BYTES)
		testing.expect_value(t, fourth_pieces[1].span, BYTE_LAYOUT_ROW_BYTES)
		testing.expect_value(t, fourth_pieces[1].rows, 1)
	}

	// A source and a type information that name other fields stop it.
	declarations["Test_Record"] = Byte_Layout_Declaration {
		fields = []Byte_Layout_Source_Field{{name = "first"}, {name = "second"}, {name = "third"}, {name = "fifth"}},
	}
	_, renamed := byte_layout_make(source, declarations)
	testing.expect(t, renamed != "", "a field of another name in the source is a fault")
	declarations["Test_Record"] = Byte_Layout_Declaration {
		fields = []Byte_Layout_Source_Field{{name = "first"}, {name = "second"}, {name = "third"}},
	}
	_, shorter := byte_layout_make(source, declarations)
	testing.expect(t, shorter != "", "a field that the source does not have is a fault")
}

// Each table kind of the module format has a layout, or states why it has
// none: a new table reaches the guide.
@(test)
byte_layout_every_table_kind_has_a_layout :: proc(t: ^testing.T) {
	keys := make(map[string]bool, context.temp_allocator)
	for source in byte_layout_sources() {
		testing.expectf(t, source.key not_in keys, "the byte layout %s has one row", source.key)
		keys[source.key] = true
	}
	tables := byte_layout_table_sources()
	for source, kind in tables {
		if kind == .None {
			continue
		}
		testing.expectf(t, source.info != nil || source.what != "", "the table kind %v has a byte layout or states why it has none", kind)
		if source.info != nil {
			testing.expectf(t, source.key in keys, "the byte layout of the table kind %v is in byte_layout_sources", kind)
			testing.expectf(t, byte_layout_source_size(source) > 0, "the byte layout of the table kind %v has bytes", kind)
		}
	}
}

// The text form of the header, as a fence of a guide holds it.
@(test)
byte_layout_text_of_the_header :: proc(t: ^testing.T) {
	layouts, ok := byte_layouts_read()
	testing.expect(t, ok, "the byte layouts are read")
	expected := fmt.tprintf(
		"module.Header, %d bytes: the start of the file\n" +
		"offset  size  field            type\n" +
		"     0     8  magic            u64\n" +
		"     8     4  version          u32\n" +
		"    12     4  header_size      u32\n" +
		"    16     8  must_understand  u64\n" +
		"    24     4  machine          Machine\n" +
		"    28     4  table_count      u32\n" +
		"    32     8  memory_size      u64\n" +
		"    40     4  entry_export     u32\n" +
		"    44     4  reserved         u32\n",
		size_of(module.Header),
	)
	testing.expect_value(t, byte_layout_text(layouts["module.Header"]), expected)
}

// The fences of the guides hold the text that the code gives, and the guide
// of the module contract has its fences.
@(test)
byte_layout_guides_hold_the_text_of_the_code :: proc(t: ^testing.T) {
	layouts, ok := byte_layouts_read()
	testing.expect(t, ok, "the byte layouts are read")
	paths, listed := foundation.files_with_suffix(BYTE_LAYOUT_DOCUMENT_FOLDER, ".md")
	testing.expect(t, listed, "the guides are listed")
	contract_fences := 0
	for path in paths {
		content, read := foundation.read_text_file(path)
		if !testing.expectf(t, read, "%s is read", path) {
			continue
		}
		rewritten, fences, problems := byte_layout_document_rewrite(content, path, layouts)
		testing.expectf(t, len(problems) == 0, "%s: %v", path, problems)
		testing.expectf(t, rewritten == content, "%s: a fence %s does not hold the text that the code gives: run `modustool byte-layouts write`", path, BYTE_LAYOUT_FENCE_LANGUAGE)
		if path == SITE_MODULE_CONTRACT_DOCUMENT {
			contract_fences = fences
		}
	}
	testing.expectf(t, contract_fences > 0, "%s has fences %s", SITE_MODULE_CONTRACT_DOCUMENT, BYTE_LAYOUT_FENCE_LANGUAGE)

	// A wrong body is written again; a key that is not a layout is a fault.
	wrong := "Before.\n\n```byte-layout module.Slot\nan old text\n```\n\nAfter.\n"
	rewritten, fences, problems := byte_layout_document_rewrite(wrong, "test.md", layouts)
	testing.expect_value(t, fences, 1)
	testing.expect_value(t, len(problems), 0)
	slot := []Byte_Layout{layouts["module.Slot"]}
	testing.expect_value(t, rewritten, strings.concatenate({"Before.\n\n```byte-layout module.Slot\n", byte_layouts_text(slot), "```\n\nAfter.\n"}, context.temp_allocator))
	_, _, unknown := byte_layout_document_rewrite("```byte-layout module.Nothing\n```\n", "test.md", layouts)
	testing.expect_value(t, len(unknown), 1)
}

// A fence of a guide becomes a diagram placed by classes, with no style
// attribute; a wrong body and a key that is not a layout are faults; the
// style sheet has the classes of the rows of the largest layout.
@(test)
byte_layout_fence_on_a_page :: proc(t: ^testing.T) {
	site: Site
	ok: bool
	site.byte_layouts, ok = byte_layouts_read()
	testing.expect(t, ok, "the byte layouts are read")
	site.byte_layout_problems = make([dynamic]string, context.temp_allocator)
	slot := []Byte_Layout{site.byte_layouts["module.Slot"]}
	markdown := strings.concatenate({"```byte-layout module.Slot\n", byte_layouts_text(slot), "```\n"}, context.temp_allocator)
	renderer := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&renderer, markdown)
	html := strings.to_string(renderer.builder)
	testing.expectf(t, len(site.byte_layout_problems) == 0, "no fault: %v", site.byte_layout_problems)
	expect := [?]string {
		"<figure class=\"byte-layout\" id=\"byte-layout-module-slot\">",
		fmt.tprintf("<div class=\"byte-cell byte-column-1 byte-span-%d byte-row-1 byte-rows-1\" title=\"memory_offset: u64, offset 0, 8 bytes", BYTE_LAYOUT_ROW_BYTES),
		fmt.tprintf("<div class=\"byte-cell byte-column-%d byte-span-4 byte-row-2 byte-rows-1\" title=\"import_index: u32, offset %d, 4 bytes", offset_of(module.Slot, import_index) % BYTE_LAYOUT_ROW_BYTES + 1, offset_of(module.Slot, import_index)),
		fmt.tprintf("<div class=\"byte-cell byte-column-%d byte-span-4 byte-row-2 byte-rows-1\" title=\"export_index: u32, offset %d, 4 bytes", offset_of(module.Slot, export_index) % BYTE_LAYOUT_ROW_BYTES + 1, offset_of(module.Slot, export_index)),
		"<code>memory_<wbr>offset</code>",
		"<span class=\"byte-offset byte-row-2\">8</span>",
		"<span class=\"byte-ruler byte-column-8\">7</span>",
	}
	for part in expect {
		testing.expectf(t, strings.contains(html, part), "the diagram holds %s", part)
	}
	testing.expect(t, !strings.contains(html, "<pre>"), "the fence is not shown as code")
	testing.expect_value(t, site_inline_code_problem(html), "")

	// The heading pass records no fault; the second pass records each one.
	site.document_headings_pending = true
	wrong_renderer := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&wrong_renderer, "```byte-layout module.Slot\nan old text\n```\n")
	testing.expect_value(t, len(site.byte_layout_problems), 0)
	site.document_headings_pending = false
	site_render_markdown(&wrong_renderer, "```byte-layout module.Slot\nan old text\n```\n\n```byte-layout module.Nothing\n```\n")
	testing.expect_value(t, len(site.byte_layout_problems), 2)

	// The rules of the rows reach the largest layout, and no further.
	rules := byte_layout_rules()
	most_rows := byte_layout_row_count(size_of(module.Function))
	testing.expect(t, strings.contains(rules, fmt.tprintf(".byte-row-%d {{ grid-row-start: %d; }}", most_rows, most_rows + 2)), "the rules have the last row of the largest layout")
	testing.expect(t, !strings.contains(rules, fmt.tprintf(".byte-row-%d {{", most_rows + 1)), "the rules stop at the largest layout")
}
