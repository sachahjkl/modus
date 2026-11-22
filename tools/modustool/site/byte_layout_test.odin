package site

import "core:fmt"
import "core:strings"
import "core:testing"
import draw_record "modus:contract/draw_record"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/store"
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
	slot: module.Import_Slot
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
	ring_record: ring.Record
	counters: ring.Counters
	error_record: errors.Error_Record
	process_context: op.Context
	log_record: op.Log_Record
	log_fact: op.Log_Fact
	thread_record: op.Thread_Record
	fault_record: op.Fault_Record
	root: store.Root
	store_entry: store.Store_Entry
	pointer: store.Pointer
	store_block: store.Store_Block
	tree_header: store.Tree_Header
	store_record: store.Entry
	object_node: store.Object_Node
	object_child: store.Object_Child
	version_index: store.Version_Index
	version_leaf: store.Version_Leaf
	version_entry: store.Version_Entry
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
		{"module.Import_Slot", "memory_offset", offset_of(module.Import_Slot, memory_offset), size_of(slot.memory_offset)},
		{"module.Import_Slot", "import_index", offset_of(module.Import_Slot, import_index), size_of(slot.import_index)},
		{"module.Import_Slot", "export_index", offset_of(module.Import_Slot, export_index), size_of(slot.export_index)},
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
		{"output.Wiring", "paired_row", offset_of(output.Wiring, paired_row), size_of(wiring.paired_row)},
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
		{"ring.Record", "kind", offset_of(ring.Record, kind), size_of(ring_record.kind)},
		{"ring.Record", "tag", offset_of(ring.Record, tag), size_of(ring_record.tag)},
		{"ring.Record", "values", offset_of(ring.Record, values), size_of(ring_record.values)},
		{"ring.Counters", "write", offset_of(ring.Counters, write), size_of(counters.write)},
		{"ring.Counters", "writer_waits", offset_of(ring.Counters, writer_waits), size_of(counters.writer_waits)},
		{"ring.Counters", "reserved_0", offset_of(ring.Counters, reserved_0), size_of(counters.reserved_0)},
		{"ring.Counters", "read", offset_of(ring.Counters, read), size_of(counters.read)},
		{"ring.Counters", "reader_waits", offset_of(ring.Counters, reader_waits), size_of(counters.reader_waits)},
		{"ring.Counters", "reserved_1", offset_of(ring.Counters, reserved_1), size_of(counters.reserved_1)},
		{"errors.Error_Record", "kind", offset_of(errors.Error_Record, kind), size_of(error_record.kind)},
		{"errors.Error_Record", "unit", offset_of(errors.Error_Record, unit), size_of(error_record.unit)},
		{"errors.Error_Record", "operation", offset_of(errors.Error_Record, operation), size_of(error_record.operation)},
		{"errors.Error_Record", "argument", offset_of(errors.Error_Record, argument), size_of(error_record.argument)},
		{"errors.Error_Record", "value", offset_of(errors.Error_Record, value), size_of(error_record.value)},
		{"errors.Error_Record", "limit", offset_of(errors.Error_Record, limit), size_of(error_record.limit)},
		{"errors.Error_Record", "found", offset_of(errors.Error_Record, found), size_of(error_record.found)},
		{"operation.Context", "handles", offset_of(op.Context, handles), size_of(process_context.handles)},
		{"operation.Context", "values", offset_of(op.Context, values), size_of(process_context.values)},
		{"operation.Log_Record", "sequence", offset_of(op.Log_Record, sequence), size_of(log_record.sequence)},
		{"operation.Log_Record", "time", offset_of(op.Log_Record, time), size_of(log_record.time)},
		{"operation.Log_Record", "process", offset_of(op.Log_Record, process), size_of(log_record.process)},
		{"operation.Log_Record", "thread", offset_of(op.Log_Record, thread), size_of(log_record.thread)},
		{"operation.Log_Record", "level", offset_of(op.Log_Record, level), size_of(log_record.level)},
		{"operation.Log_Record", "more", offset_of(op.Log_Record, more), size_of(log_record.more)},
		{"operation.Log_Record", "process_serial", offset_of(op.Log_Record, process_serial), size_of(log_record.process_serial)},
		{"operation.Log_Record", "own_number", offset_of(op.Log_Record, own_number), size_of(log_record.own_number)},
		{"operation.Log_Record", "text_count", offset_of(op.Log_Record, text_count), size_of(log_record.text_count)},
		{"operation.Log_Record", "run_count", offset_of(op.Log_Record, run_count), size_of(log_record.run_count)},
		{"operation.Log_Record", "form", offset_of(op.Log_Record, form), size_of(log_record.form)},
		{"operation.Log_Record", "name", offset_of(op.Log_Record, name), size_of(log_record.name)},
		{"operation.Log_Record", "runs", offset_of(op.Log_Record, runs), size_of(log_record.runs)},
		{"operation.Log_Record", "text", offset_of(op.Log_Record, text), size_of(log_record.text)},
		{"operation.Log_Fact", "module_hash", offset_of(op.Log_Fact, module_hash), size_of(log_fact.module_hash)},
		{"operation.Log_Fact", "key", offset_of(op.Log_Fact, key), size_of(log_fact.key)},
		{"operation.Log_Fact", "value_count", offset_of(op.Log_Fact, value_count), size_of(log_fact.value_count)},
		{"operation.Log_Fact", "part", offset_of(op.Log_Fact, part), size_of(log_fact.part)},
		{"operation.Log_Fact", "part_count", offset_of(op.Log_Fact, part_count), size_of(log_fact.part_count)},
		{"operation.Log_Fact", "reserved", offset_of(op.Log_Fact, reserved), size_of(log_fact.reserved)},
		{"operation.Log_Fact", "values", offset_of(op.Log_Fact, values), size_of(log_fact.values)},
		{"operation.Thread_Record", "self", offset_of(op.Thread_Record, self), size_of(thread_record.self)},
		{"operation.Thread_Record", "parameter", offset_of(op.Thread_Record, parameter), size_of(thread_record.parameter)},
		{"operation.Thread_Record", "number", offset_of(op.Thread_Record, number), size_of(thread_record.number)},
		{"operation.Thread_Record", "events", offset_of(op.Thread_Record, events), size_of(thread_record.events)},
		{"operation.Thread_Record", "processors", offset_of(op.Thread_Record, processors), size_of(thread_record.processors)},
		{"operation.Thread_Record", "fault_written", offset_of(op.Thread_Record, fault_written), size_of(thread_record.fault_written)},
		{"operation.Thread_Record", "fault_read", offset_of(op.Thread_Record, fault_read), size_of(thread_record.fault_read)},
		{"operation.Thread_Record", "fault_full", offset_of(op.Thread_Record, fault_full), size_of(thread_record.fault_full)},
		{"operation.Thread_Record", "fault_reserved", offset_of(op.Thread_Record, fault_reserved), size_of(thread_record.fault_reserved)},
		{"operation.Thread_Record", "fault_records", offset_of(op.Thread_Record, fault_records), size_of(thread_record.fault_records)},
		{"operation.Fault_Record", "thread", offset_of(op.Fault_Record, thread), size_of(fault_record.thread)},
		{"operation.Fault_Record", "serial", offset_of(op.Fault_Record, serial), size_of(fault_record.serial)},
		{"operation.Fault_Record", "address", offset_of(op.Fault_Record, address), size_of(fault_record.address)},
		{"operation.Fault_Record", "access", offset_of(op.Fault_Record, access), size_of(fault_record.access)},
		{"operation.Fault_Record", "instruction", offset_of(op.Fault_Record, instruction), size_of(fault_record.instruction)},
		{"operation.Fault_Record", "kind", offset_of(op.Fault_Record, kind), size_of(fault_record.kind)},
		{"operation.Fault_Record", "error_code", offset_of(op.Fault_Record, error_code), size_of(fault_record.error_code)},
		{"operation.Fault_Record", "reserved", offset_of(op.Fault_Record, reserved), size_of(fault_record.reserved)},
		{"store.Root", "magic", offset_of(store.Root, magic), size_of(root.magic)},
		{"store.Root", "generation", offset_of(store.Root, generation), size_of(root.generation)},
		{"store.Root", "disk_blocks", offset_of(store.Root, disk_blocks), size_of(root.disk_blocks)},
		{"store.Root", "time", offset_of(store.Root, time), size_of(root.time)},
		{"store.Root", "date", offset_of(store.Root, date), size_of(root.date)},
		{"store.Root", "reserved", offset_of(store.Root, reserved), size_of(root.reserved)},
		{"store.Root", "stores", offset_of(store.Root, stores), size_of(root.stores)},
		{"store.Root", "padding", offset_of(store.Root, padding), size_of(root.padding)},
		{"store.Root", "check", offset_of(store.Root, check), size_of(root.check)},
		{"store.Store_Entry", "name", offset_of(store.Store_Entry, name), size_of(store_entry.name)},
		{"store.Store_Entry", "limit", offset_of(store.Store_Entry, limit), size_of(store_entry.limit)},
		{"store.Store_Entry", "used", offset_of(store.Store_Entry, used), size_of(store_entry.used)},
		{"store.Store_Entry", "store", offset_of(store.Store_Entry, store), size_of(store_entry.store)},
		{"store.Pointer", "block", offset_of(store.Pointer, block), size_of(pointer.block)},
		{"store.Pointer", "check", offset_of(store.Pointer, check), size_of(pointer.check)},
		{"store.Store_Block", "tree", offset_of(store.Store_Block, tree), size_of(store_block.tree)},
		{"store.Store_Block", "removals", offset_of(store.Store_Block, removals), size_of(store_block.removals)},
		{"store.Store_Block", "next_removal", offset_of(store.Store_Block, next_removal), size_of(store_block.next_removal)},
		{"store.Store_Block", "objects", offset_of(store.Store_Block, objects), size_of(store_block.objects)},
		{"store.Store_Block", "trees", offset_of(store.Store_Block, trees), size_of(store_block.trees)},
		{"store.Store_Block", "current_blocks", offset_of(store.Store_Block, current_blocks), size_of(store_block.current_blocks)},
		{"store.Store_Block", "node_blocks", offset_of(store.Store_Block, node_blocks), size_of(store_block.node_blocks)},
		{"store.Store_Block", "removing", offset_of(store.Store_Block, removing), size_of(store_block.removing)},
		{"store.Store_Block", "reserved", offset_of(store.Store_Block, reserved), size_of(store_block.reserved)},
		{"store.Store_Block", "padding", offset_of(store.Store_Block, padding), size_of(store_block.padding)},
		{"store.Tree_Header", "level", offset_of(store.Tree_Header, level), size_of(tree_header.level)},
		{"store.Tree_Header", "count", offset_of(store.Tree_Header, count), size_of(tree_header.count)},
		{"store.Tree_Header", "magic", offset_of(store.Tree_Header, magic), size_of(tree_header.magic)},
		{"store.Tree_Header", "reserved", offset_of(store.Tree_Header, reserved), size_of(tree_header.reserved)},
		{"store.Tree_Header", "unused", offset_of(store.Tree_Header, unused), size_of(tree_header.unused)},
		{"store.Entry", "kind", offset_of(store.Entry, kind), size_of(store_record.kind)},
		{"store.Entry", "size", offset_of(store.Entry, size), size_of(store_record.size)},
		{"store.Entry", "generation", offset_of(store.Entry, generation), size_of(store_record.generation)},
		{"store.Entry", "time", offset_of(store.Entry, time), size_of(store_record.time)},
		{"store.Entry", "date", offset_of(store.Entry, date), size_of(store_record.date)},
		{"store.Entry", "hash", offset_of(store.Entry, hash), size_of(store_record.hash)},
		{"store.Entry", "pointer", offset_of(store.Entry, pointer), size_of(store_record.pointer)},
		{"store.Entry", "versions", offset_of(store.Entry, versions), size_of(store_record.versions)},
		{"store.Object_Node", "header", offset_of(store.Object_Node, header), size_of(object_node.header)},
		{"store.Object_Node", "children", offset_of(store.Object_Node, children), size_of(object_node.children)},
		{"store.Object_Node", "padding", offset_of(store.Object_Node, padding), size_of(object_node.padding)},
		{"store.Object_Child", "block", offset_of(store.Object_Child, block), size_of(object_child.block)},
		{"store.Object_Child", "check", offset_of(store.Object_Child, check), size_of(object_child.check)},
		{"store.Object_Child", "blocks", offset_of(store.Object_Child, blocks), size_of(object_child.blocks)},
		{"store.Object_Child", "value", offset_of(store.Object_Child, value), size_of(object_child.value)},
		{"store.Version_Index", "leaf_count", offset_of(store.Version_Index, leaf_count), size_of(version_index.leaf_count)},
		{"store.Version_Index", "version_count", offset_of(store.Version_Index, version_count), size_of(version_index.version_count)},
		{"store.Version_Index", "retention_time", offset_of(store.Version_Index, retention_time), size_of(version_index.retention_time)},
		{"store.Version_Index", "reserved", offset_of(store.Version_Index, reserved), size_of(version_index.reserved)},
		{"store.Version_Index", "leaves", offset_of(store.Version_Index, leaves), size_of(version_index.leaves)},
		{"store.Version_Leaf", "count", offset_of(store.Version_Leaf, count), size_of(version_leaf.count)},
		{"store.Version_Leaf", "reserved", offset_of(store.Version_Leaf, reserved), size_of(version_leaf.reserved)},
		{"store.Version_Leaf", "entries", offset_of(store.Version_Leaf, entries), size_of(version_leaf.entries)},
		{"store.Version_Entry", "generation", offset_of(store.Version_Entry, generation), size_of(version_entry.generation)},
		{"store.Version_Entry", "size", offset_of(store.Version_Entry, size), size_of(version_entry.size)},
		{"store.Version_Entry", "time", offset_of(store.Version_Entry, time), size_of(version_entry.time)},
		{"store.Version_Entry", "date", offset_of(store.Version_Entry, date), size_of(version_entry.date)},
		{"store.Version_Entry", "root", offset_of(store.Version_Entry, root), size_of(version_entry.root)},
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
	// The grid, folds counted: each cell once, and one offset for each row.
	grid_rows := len(byte_layout_grid_row_offsets(layout))
	grid := make([]int, grid_rows * BYTE_LAYOUT_ROW_BYTES, context.temp_allocator)
	for piece in byte_layout_pieces(layout) {
		for row in piece.grid_row ..< piece.grid_row + piece.grid_rows {
			for column in piece.column ..< piece.column + piece.span {
				place := row * BYTE_LAYOUT_ROW_BYTES + column
				if testing.expectf(t, place < len(grid), "%s: a rectangle of %s covers the cell %d of the grid, past its %d rows", layout.key, layout.fields[piece.field].name, place, grid_rows) {
					grid[place] += 1
				}
			}
		}
	}
	// Only the end of the last row, past the record, is empty.
	empty_cells := byte_layout_row_count(layout.size) * BYTE_LAYOUT_ROW_BYTES - layout.size
	for count, place in grid {
		expected := place < len(grid) - empty_cells ? 1 : 0
		testing.expectf(t, count == expected, "%s: the cell %d of the grid is covered %d times", layout.key, place, count)
	}
}

// A field of BYTE_LAYOUT_FOLD_ROWS whole rows, then a field of one row more,
// between two words.
@(private = "file")
Fold_Record :: struct {
	head:  u64,
	exact: [BYTE_LAYOUT_FOLD_ROWS * BYTE_LAYOUT_ROW_BYTES]u8,
	over:  [(BYTE_LAYOUT_FOLD_ROWS + 1) * BYTE_LAYOUT_ROW_BYTES]u8,
	tail:  u64,
}

// A rectangle of more rows than BYTE_LAYOUT_FOLD_ROWS is folded to its first
// row and its last row; one of BYTE_LAYOUT_FOLD_ROWS rows is not; the
// rectangles after a fold move up by the rows that it hides, and the grid
// keeps the offset of each row that it shows.
@(test)
byte_layout_tall_rectangles_fold :: proc(t: ^testing.T) {
	declarations := make(map[string]Byte_Layout_Declaration, context.temp_allocator)
	declarations["Fold_Record"] = Byte_Layout_Declaration {
		fields = []Byte_Layout_Source_Field{{name = "head", type_text = "u64"}, {name = "exact", type_text = "[64]u8"}, {name = "over", type_text = "[72]u8"}, {name = "tail", type_text = "u64"}},
	}
	source := Byte_Layout_Source{key = "test.Fold_Record", file = "test", declaration = "Fold_Record", info = type_info_of(Fold_Record), what = "a record of the test"}
	layout, problem := byte_layout_make(source, declarations)
	testing.expect_value(t, problem, "")
	expect_each_byte_covered_once(t, layout)
	pieces := byte_layout_pieces(layout)
	if testing.expect_value(t, len(pieces), 4) {
		testing.expect(t, !pieces[1].folded && pieces[1].grid_rows == BYTE_LAYOUT_FOLD_ROWS && pieces[1].grid_row == 1, "a field of BYTE_LAYOUT_FOLD_ROWS rows is drawn whole")
		testing.expect(t, pieces[2].folded && pieces[2].grid_rows == BYTE_LAYOUT_FOLDED_ROWS && pieces[2].grid_row == 1 + BYTE_LAYOUT_FOLD_ROWS, "a field of one row more is folded")
		testing.expect_value(t, pieces[3].row, 1 + 2 * BYTE_LAYOUT_FOLD_ROWS + 1)
		testing.expect_value(t, pieces[3].grid_row, 1 + BYTE_LAYOUT_FOLD_ROWS + BYTE_LAYOUT_FOLDED_ROWS)
	}
	offsets := byte_layout_grid_row_offsets(layout)
	over_offset := int(offset_of(Fold_Record, over))
	if testing.expect_value(t, len(offsets), 1 + BYTE_LAYOUT_FOLD_ROWS + BYTE_LAYOUT_FOLDED_ROWS + 1) {
		testing.expect_value(t, offsets[1 + BYTE_LAYOUT_FOLD_ROWS], over_offset)
		testing.expect_value(t, offsets[2 + BYTE_LAYOUT_FOLD_ROWS], over_offset + size_of(Fold_Record{}.over) - BYTE_LAYOUT_ROW_BYTES)
		testing.expect_value(t, offsets[len(offsets) - 1], int(offset_of(Fold_Record, tail)))
	}

	// The root block of the disk: 512 rows, each array and its padding folded.
	layouts, ok := byte_layouts_read()
	testing.expect(t, ok, "the byte layouts are read")
	root_offsets := byte_layout_grid_row_offsets(layouts["store.Root"])
	stores_offset := int(offset_of(store.Root, stores))
	padding_offset := int(offset_of(store.Root, padding))
	expected_root := [?]int{0, 8, 16, 24, 32, 40, 48, 56, stores_offset, padding_offset - BYTE_LAYOUT_ROW_BYTES, padding_offset, int(offset_of(store.Root, check)) - BYTE_LAYOUT_ROW_BYTES, int(offset_of(store.Root, check))}
	if testing.expect_value(t, len(root_offsets), len(expected_root)) {
		for offset, index in expected_root {
			testing.expect_value(t, root_offsets[index], offset)
		}
	}
	// The layout from the type information alone has the same grid.
	testing.expect_value(t, len(byte_layout_grid_row_offsets(byte_layout_of_type(Byte_Layout_Source{key = "store.Root", info = type_info_of(store.Root)}))), len(expected_root))
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
	wrong := "Before.\n\n```byte-layout module.Import_Slot\nan old text\n```\n\nAfter.\n"
	rewritten, fences, problems := byte_layout_document_rewrite(wrong, "test.md", layouts)
	testing.expect_value(t, fences, 1)
	testing.expect_value(t, len(problems), 0)
	import_slot_layout := []Byte_Layout{layouts["module.Import_Slot"]}
	testing.expect_value(t, rewritten, strings.concatenate({"Before.\n\n```byte-layout module.Import_Slot\n", byte_layouts_text(import_slot_layout), "```\n\nAfter.\n"}, context.temp_allocator))
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
	import_slot_layout := []Byte_Layout{site.byte_layouts["module.Import_Slot"]}
	markdown := strings.concatenate({"```byte-layout module.Import_Slot\n", byte_layouts_text(import_slot_layout), "```\n"}, context.temp_allocator)
	renderer := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&renderer, markdown)
	html := strings.to_string(renderer.builder)
	testing.expectf(t, len(site.byte_layout_problems) == 0, "no fault: %v", site.byte_layout_problems)
	expect := [?]string {
		"<figure class=\"byte-layout\" id=\"byte-layout-module-import-slot\">",
		fmt.tprintf("<div class=\"byte-cell byte-column-1 byte-span-%d byte-row-1 byte-rows-1\" title=\"memory_offset: u64, offset 0, 8 bytes", BYTE_LAYOUT_ROW_BYTES),
		fmt.tprintf("<div class=\"byte-cell byte-column-%d byte-span-4 byte-row-2 byte-rows-1\" title=\"import_index: u32, offset %d, 4 bytes", offset_of(module.Import_Slot, import_index) % BYTE_LAYOUT_ROW_BYTES + 1, offset_of(module.Import_Slot, import_index)),
		fmt.tprintf("<div class=\"byte-cell byte-column-%d byte-span-4 byte-row-2 byte-rows-1\" title=\"export_index: u32, offset %d, 4 bytes", offset_of(module.Import_Slot, export_index) % BYTE_LAYOUT_ROW_BYTES + 1, offset_of(module.Import_Slot, export_index)),
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
	site_render_markdown(&wrong_renderer, "```byte-layout module.Import_Slot\nan old text\n```\n")
	testing.expect_value(t, len(site.byte_layout_problems), 0)
	site.document_headings_pending = false
	site_render_markdown(&wrong_renderer, "```byte-layout module.Import_Slot\nan old text\n```\n\n```byte-layout module.Nothing\n```\n")
	testing.expect_value(t, len(site.byte_layout_problems), 2)

	// A folded rectangle says so, beside its size.
	clear(&site.byte_layout_problems)
	root_layout := []Byte_Layout{site.byte_layouts["store.Root"]}
	root_renderer := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&root_renderer, strings.concatenate({"```byte-layout store.Root\n", byte_layouts_text(root_layout), "```\n"}, context.temp_allocator))
	root_html := strings.to_string(root_renderer.builder)
	testing.expect(t, strings.contains(root_html, "<div class=\"byte-cell byte-cell-folded byte-column-1 byte-span-8 byte-row-9 byte-rows-2\" title=\"stores:"), "the array of the stores is folded to two rows of the grid")
	testing.expect(t, strings.contains(root_html, fmt.tprintf("%d rows folded", size_of(store.Root{}.stores) / BYTE_LAYOUT_ROW_BYTES)), "a folded rectangle says how many rows it folds")
	testing.expect(t, strings.contains(root_html, fmt.tprintf("<span class=\"byte-offset byte-row-11\">%d</span>", offset_of(store.Root, padding))), "the row after a fold has its own offset")
	testing.expectf(t, len(site.byte_layout_problems) == 0, "no fault: %v", site.byte_layout_problems)

	// The rules of the rows reach the largest grid of a layout, folds
	// counted, and no further.
	rules := byte_layout_rules()
	most_rows := 0
	for _, each_layout in site.byte_layouts {
		most_rows = max(most_rows, len(byte_layout_grid_row_offsets(each_layout)))
	}
	testing.expect(t, strings.contains(rules, fmt.tprintf(".byte-row-%d {{ grid-row-start: %d; }}", most_rows, most_rows + 2)), "the rules have the last row of the largest layout")
	testing.expect(t, !strings.contains(rules, fmt.tprintf(".byte-row-%d {{", most_rows + 1)), "the rules stop at the largest layout")
}
