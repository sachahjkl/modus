#+build !freestanding
package module

import "core:testing"

// The parts of a module file of these tests: three records, their fields,
// the strings, two record outputs and two record inputs. Each table holds
// its record 0.
//
// The records: 1 "Probe", two unsigned Integers of 8 bytes, each byte
// covered; 2 "Padded", a u8 then a u64 at 8, with 7 bytes that no field
// names; 3 "Lent", a Handle then a u32.
// The record outputs: 1 "alpha" of Probe; 2 "beta", generic and Paired.
// The record inputs: 1 "gamma", generic, Many_Types, with the terms Probe;
// 2 "orders" of Probe, One.
@(private = "file")
Stream_File :: struct {
	records: [dynamic]Record,
	fields:  [dynamic]Field,
	strings: [dynamic]u8,
	outputs: [dynamic]Record_Output,
	inputs:  [dynamic]Record_Input,
	output_count: u32, // Not 0: the count that the directory states for Record_Outputs, past the rows that the file holds.
	input_count:  u32, // The same for Record_Inputs.
}

@(private = "file")
PROBE :: 1
@(private = "file")
PADDED :: 2
@(private = "file")
LENT :: 3

@(private = "file")
stream_string_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
	offset = u32(len(table))
	append(table, text)
	return offset, u32(len(text))
}

@(private = "file")
stream_file_parts :: proc() -> (parts: Stream_File) {
	parts.records = make([dynamic]Record, context.temp_allocator)
	parts.fields = make([dynamic]Field, context.temp_allocator)
	parts.strings = make([dynamic]u8, context.temp_allocator)
	parts.outputs = make([dynamic]Record_Output, context.temp_allocator)
	parts.inputs = make([dynamic]Record_Input, context.temp_allocator)
	append(&parts.strings, 0)
	append(&parts.records, Record{})
	append(&parts.fields, Field{})
	field_add :: proc(parts: ^Stream_File, name: string, offset: u32, type: Type, detail: u32) {
		name_offset, name_count := stream_string_add(&parts.strings, name)
		append(&parts.fields, Field{name_offset = name_offset, name_count = name_count, offset = offset, type = u8(type), detail = detail, unsigned = type == .Integer})
	}
	record_add :: proc(parts: ^Stream_File, name: string, size, field_count: u32) {
		name_offset, name_count := stream_string_add(&parts.strings, name)
		append(&parts.records, Record{name_offset = name_offset, name_count = name_count, size = size, first_field = u32(len(parts.fields)), field_count = field_count})
	}
	record_add(&parts, "Probe", 16, 2)
	field_add(&parts, "value", 0, .Integer, 0)
	field_add(&parts, "mark", 8, .Integer, 0)
	record_add(&parts, "Padded", 16, 2)
	field_add(&parts, "small", 0, .Integer, 1)
	field_add(&parts, "large", 8, .Integer, 0)
	record_add(&parts, "Lent", 8, 2)
	field_add(&parts, "handle", 0, .Handle, 0)
	field_add(&parts, "other", 4, .Integer, 4)

	about_offset, about_count := stream_string_add(&parts.strings, "One line of help.")
	text_offset, text_count := stream_string_add(&parts.strings, "One line of help.\n\nThe text.")
	output_add :: proc(parts: ^Stream_File, name: string, record: u32, pairing: Record_Output_Pairing, about_offset, about_count, text_offset, text_count: u32) {
		name_offset, name_count := stream_string_add(&parts.strings, name)
		append(&parts.outputs, Record_Output{name_offset = name_offset, name_count = name_count, about_offset = about_offset, about_count = about_count, text_offset = text_offset, text_count = text_count, record = record, pairing = u8(pairing)})
	}
	input_add :: proc(parts: ^Stream_File, name: string, record, terms: u32, wirings: Wiring_Count, about_offset, about_count, text_offset, text_count: u32) {
		name_offset, name_count := stream_string_add(&parts.strings, name)
		append(&parts.inputs, Record_Input{name_offset = name_offset, name_count = name_count, about_offset = about_offset, about_count = about_count, text_offset = text_offset, text_count = text_count, record = record, terms = terms, wirings = u8(wirings)})
	}
	append(&parts.outputs, Record_Output{})
	output_add(&parts, "alpha", PROBE, .Unpaired, about_offset, about_count, text_offset, text_count)
	output_add(&parts, "beta", 0, .Paired, about_offset, about_count, text_offset, text_count)
	append(&parts.inputs, Record_Input{})
	input_add(&parts, "gamma", 0, PROBE, .Many_Types, about_offset, about_count, text_offset, text_count)
	input_add(&parts, "orders", PROBE, 0, .One, about_offset, about_count, text_offset, text_count)
	return parts
}

@(private = "file")
stream_bytes_of :: proc(items: []$T) -> []u8 {
	return ([^]u8)(raw_data(items))[:len(items) * size_of(T)]
}

// stream_file writes a module file of the parts: the header, the directory
// and each table, with no segment.
@(private = "file")
stream_file :: proc(parts: Stream_File) -> []u8 {
	file := make([dynamic]u8, size_of(Header) + TABLE_COUNT * size_of(Table_Entry), context.temp_allocator)
	directory: [TABLE_COUNT]Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[TABLE_COUNT]Table_Entry, kind: Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, stream_bytes_of(parts.records[:]), u32(len(parts.records)), size_of(Record))
	add(&file, &directory, .Fields, stream_bytes_of(parts.fields[:]), u32(len(parts.fields)), size_of(Field))
	add(&file, &directory, .Strings, parts.strings[:], u32(len(parts.strings)), 1)
	add(&file, &directory, .Record_Outputs, stream_bytes_of(parts.outputs[:]), u32(len(parts.outputs)), size_of(Record_Output))
	add(&file, &directory, .Record_Inputs, stream_bytes_of(parts.inputs[:]), u32(len(parts.inputs)), size_of(Record_Input))
	if parts.output_count != 0 {
		directory[Table_Kind.Record_Outputs].count = parts.output_count
	}
	if parts.input_count != 0 {
		directory[Table_Kind.Record_Inputs].count = parts.input_count
	}
	(^Header)(&file[0])^ = {magic = MAGIC, version = VERSION, header_size = size_of(Header), machine = .X86_64, table_count = TABLE_COUNT}
	(^[TABLE_COUNT]Table_Entry)(&file[size_of(Header)])^ = directory
	return file[:]
}

// stream_row_rename gives a row a new name, added to the strings.
@(private = "file")
stream_row_rename :: proc(parts: ^Stream_File, offset_field: ^u32, count_field: ^u32, name: string) {
	offset, count := stream_string_add(&parts.strings, name)
	offset_field^, count_field^ = offset, count
}

@(private = "file")
Stream_Change :: struct {
	name:   string,
	change: proc(parts: ^Stream_File),
}

// A row of the table Record_Outputs that breaks a rule is refused by
// record_output, and the whole check names it: each reserved byte, a name
// of 0 bytes, past the strings or that is not a name of the source, a help
// and a text past the strings, the largest offsets, a record past the
// records, the largest index, a record with padding or a Handle, a pairing
// word one past the last member and the largest one, and Paired on a typed
// record output. The edges of the index come first.
@(test)
a_record_output_row_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	file := stream_file(stream_file_parts())
	for index in ([?]u32{0, 3, RECORD_STREAM_INDEX_MOST + 1, max(u32)}) {
		_, _, _, ok := record_output(file, index)
		testing.expectf(t, !ok, "the row %d is taken", index)
	}
	changes := [?]Stream_Change {
		{"a first reserved byte", proc(parts: ^Stream_File) {parts.outputs[1].reserved[0] = 1}},
		{"a last reserved byte", proc(parts: ^Stream_File) {parts.outputs[1].reserved[2] = 1}},
		{"a name of 0 bytes", proc(parts: ^Stream_File) {parts.outputs[1].name_count = 0}},
		{"a name past the strings", proc(parts: ^Stream_File) {parts.outputs[1].name_offset = u32(len(parts.strings))}},
		{"a name one byte past the strings", proc(parts: ^Stream_File) {parts.outputs[1].name_count = u32(len(parts.strings)) - parts.outputs[1].name_offset + 1}},
		{"the largest name offset", proc(parts: ^Stream_File) {parts.outputs[1].name_offset = max(u32)}},
		{"a name that starts with a digit", proc(parts: ^Stream_File) {
				offset, count := stream_string_add(&parts.strings, "1alpha")
				parts.outputs[1].name_offset, parts.outputs[1].name_count = offset, count
			}},
		{"a name with a space", proc(parts: ^Stream_File) {
				offset, count := stream_string_add(&parts.strings, "al pha")
				parts.outputs[1].name_offset, parts.outputs[1].name_count = offset, count
			}},
		{"a help past the strings", proc(parts: ^Stream_File) {parts.outputs[1].about_offset = u32(len(parts.strings))}},
		{"a text past the strings", proc(parts: ^Stream_File) {parts.outputs[1].text_count = max(u32)}},
		{"a record past the records", proc(parts: ^Stream_File) {parts.outputs[1].record = LENT + 1}},
		{"the largest record index", proc(parts: ^Stream_File) {parts.outputs[1].record = max(u32)}},
		{"a record with padding", proc(parts: ^Stream_File) {parts.outputs[1].record = PADDED}},
		{"a record with a Handle", proc(parts: ^Stream_File) {parts.outputs[1].record = LENT}},
		{"a pairing one past the last member", proc(parts: ^Stream_File) {parts.outputs[1].pairing = u8(max(Record_Output_Pairing)) + 1}},
		{"the largest pairing word", proc(parts: ^Stream_File) {parts.outputs[2].pairing = max(u8)}},
		{"Paired on a typed record output", proc(parts: ^Stream_File) {parts.outputs[1].pairing = u8(Record_Output_Pairing.Paired)}},
	}
	for item in changes {
		parts := stream_file_parts()
		item.change(&parts)
		changed := stream_file(parts)
		row := 1 if item.name != "the largest pairing word" else 2
		_, _, _, ok := record_output(changed, u32(row))
		testing.expectf(t, !ok, "a record output with %s is taken", item.name)
		fault, place := record_streams_check(changed)
		testing.expectf(t, fault == .Bad_Output && place == u32(row), "the check of a record output with %s gave %v at %d", item.name, fault, place)
	}
	// The rows as the build writes them, last.
	alpha, alpha_pairing, alpha_record, alpha_ok := record_output(file, 1)
	beta, beta_pairing, beta_record, beta_ok := record_output(file, 2)
	testing.expect(t, alpha_ok && alpha.record == PROBE && alpha_pairing == .Unpaired && alpha_record.size == 16)
	testing.expect(t, beta_ok && beta.record == 0 && beta_pairing == .Paired && beta_record == Record{})
	testing.expect_value(t, string_at(file, alpha.name_offset, alpha.name_count), "alpha")
}

// A row of the table Record_Inputs that breaks a rule is refused by
// record_input, and the whole check names it: the edges of the index, a
// reserved byte, a name that is not a name of the source, a record or
// terms with padding, with a Handle or past the records, a count of
// wirings one past the last member and the largest one, and Many_Types on
// a typed record input.
@(test)
a_record_input_row_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	file := stream_file(stream_file_parts())
	for index in ([?]u32{0, 3, RECORD_STREAM_INDEX_MOST + 1, max(u32)}) {
		_, _, _, _, ok := record_input(file, index)
		testing.expectf(t, !ok, "the row %d is taken", index)
	}
	changes := [?]Stream_Change {
		{"a reserved byte", proc(parts: ^Stream_File) {parts.inputs[2].reserved[1] = 1}},
		{"a name of 0 bytes", proc(parts: ^Stream_File) {parts.inputs[2].name_count = 0}},
		{"a name with a dash", proc(parts: ^Stream_File) {
				offset, count := stream_string_add(&parts.strings, "or-ders")
				parts.inputs[2].name_offset, parts.inputs[2].name_count = offset, count
			}},
		{"a help past the strings", proc(parts: ^Stream_File) {parts.inputs[2].about_count = u32(len(parts.strings)) + 1}},
		{"a record past the records", proc(parts: ^Stream_File) {parts.inputs[2].record = LENT + 1}},
		{"a record with padding", proc(parts: ^Stream_File) {parts.inputs[2].record = PADDED}},
		{"a record with a Handle", proc(parts: ^Stream_File) {parts.inputs[2].record = LENT}},
		{"terms past the records", proc(parts: ^Stream_File) {parts.inputs[2].terms = LENT + 1}},
		{"the largest terms index", proc(parts: ^Stream_File) {parts.inputs[2].terms = max(u32)}},
		{"terms with padding", proc(parts: ^Stream_File) {parts.inputs[2].terms = PADDED}},
		{"terms with a Handle", proc(parts: ^Stream_File) {parts.inputs[2].terms = LENT}},
		{"a count one past the last member", proc(parts: ^Stream_File) {parts.inputs[2].wirings = u8(max(Wiring_Count)) + 1}},
		{"the largest count word", proc(parts: ^Stream_File) {parts.inputs[2].wirings = max(u8)}},
		{"Many_Types on a typed record input", proc(parts: ^Stream_File) {parts.inputs[2].wirings = u8(Wiring_Count.Many_Types)}},
	}
	for item in changes {
		parts := stream_file_parts()
		item.change(&parts)
		changed := stream_file(parts)
		_, _, _, _, ok := record_input(changed, 2)
		testing.expectf(t, !ok, "a record input with %s is taken", item.name)
		fault, place := record_streams_check(changed)
		testing.expectf(t, fault == .Bad_Input && place == 2, "the check of a record input with %s gave %v at %d", item.name, fault, place)
	}
	// The count Many on a typed record input is taken; then the rows as the
	// build writes them.
	many := stream_file_parts()
	many.inputs[2].wirings = u8(Wiring_Count.Many)
	_, many_wirings, _, _, many_ok := record_input(stream_file(many), 2)
	testing.expect(t, many_ok && many_wirings == .Many)
	gamma, gamma_wirings, gamma_record, gamma_terms, gamma_ok := record_input(file, 1)
	orders, orders_wirings, orders_record, _, orders_ok := record_input(file, 2)
	testing.expect(t, gamma_ok && gamma.record == 0 && gamma_wirings == .Many_Types && gamma_record == Record{} && gamma_terms.size == 16)
	testing.expect(t, orders_ok && orders.terms == 0 && orders_wirings == .One && orders_record.size == 16)
}

// The rules of the whole tables: the count of the rows at its bound and
// one past it, names out of order and one name in two rows of a table, one
// name for a record output and a record input, and a generic record output
// with no generic record input or with two. The tables as the build writes
// them are the last case.
@(test)
the_tables_of_the_record_streams_keep_their_rules :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		change: proc(parts: ^Stream_File),
		fault:  Record_Stream_Fault,
		place:  u32,
	}
	cases := [?]Case {
		{"one row past the bound of the outputs", proc(parts: ^Stream_File) {parts.output_count = RECORD_STREAM_INDEX_MOST + 2}, .Too_Many_Outputs, RECORD_STREAM_INDEX_MOST + 1},
		{"one row past the bound of the inputs", proc(parts: ^Stream_File) {parts.input_count = RECORD_STREAM_INDEX_MOST + 2}, .Too_Many_Inputs, RECORD_STREAM_INDEX_MOST + 1},
		{"the largest count of the outputs", proc(parts: ^Stream_File) {parts.output_count = max(u32)}, .Too_Many_Outputs, RECORD_STREAM_INDEX_MOST + 1},
		// At the bound, the count passes, and the first row that the file
		// does not hold is refused.
		{"rows at the bound of the outputs", proc(parts: ^Stream_File) {parts.output_count = RECORD_STREAM_INDEX_MOST + 1}, .Bad_Output, 3},
		{"two outputs out of order", proc(parts: ^Stream_File) {stream_row_rename(parts, &parts.outputs[2].name_offset, &parts.outputs[2].name_count, "aardvark")}, .Outputs_Out_Of_Order, 2},
		{"two outputs with one name", proc(parts: ^Stream_File) {stream_row_rename(parts, &parts.outputs[2].name_offset, &parts.outputs[2].name_count, "alpha")}, .Outputs_Out_Of_Order, 2},
		{"two inputs out of order", proc(parts: ^Stream_File) {stream_row_rename(parts, &parts.inputs[2].name_offset, &parts.inputs[2].name_count, "gam")}, .Inputs_Out_Of_Order, 2},
		{"two inputs with one name", proc(parts: ^Stream_File) {stream_row_rename(parts, &parts.inputs[2].name_offset, &parts.inputs[2].name_count, "gamma")}, .Inputs_Out_Of_Order, 2},
		{"an input with the name of an output", proc(parts: ^Stream_File) {stream_row_rename(parts, &parts.inputs[2].name_offset, &parts.inputs[2].name_count, "zeta"); stream_row_rename(parts, &parts.inputs[1].name_offset, &parts.inputs[1].name_count, "beta")}, .Name_Of_Both, 2},
		{"a generic output and no generic input", proc(parts: ^Stream_File) {parts.inputs[1].record, parts.inputs[1].wirings = PROBE, u8(Wiring_Count.One)}, .Generic_Output_Alone, 2},
		{"a generic output and two generic inputs", proc(parts: ^Stream_File) {parts.inputs[2].record = 0}, .Generic_Output_Alone, 2},
		{"a generic output and no record input", proc(parts: ^Stream_File) {resize(&parts.inputs, 1)}, .Generic_Output_Alone, 2},
	}
	for item in cases {
		parts := stream_file_parts()
		item.change(&parts)
		fault, place := record_streams_check(stream_file(parts))
		testing.expectf(t, fault == item.fault && place == item.place, "%s gave %v at %d, not %v at %d", item.name, fault, place, item.fault, item.place)
	}
	// Two generic inputs with no generic output keep the rules; a file with
	// no table of either has none to break; then the tables of the build.
	two := stream_file_parts()
	two.inputs[2].record = 0
	resize(&two.outputs, 2)
	two_fault, _ := record_streams_check(stream_file(two))
	testing.expect_value(t, two_fault, Record_Stream_Fault.None)
	empty := stream_file_parts()
	clear(&empty.outputs)
	clear(&empty.inputs)
	empty_fault, _ := record_streams_check(stream_file(empty))
	testing.expect_value(t, empty_fault, Record_Stream_Fault.None)
	file := stream_file(stream_file_parts())
	testing.expect_value(t, validate(file), Error.None)
	fault, place := record_streams_check(file)
	testing.expect(t, fault == .None && place == 0)
}

// The record of a record stream covers each of its bytes: a field that
// starts past the end of the field before, a last field that ends before
// the end of the record, and a record of one field that fills it.
@(test)
a_record_with_a_byte_that_no_field_names_is_refused :: proc(t: ^testing.T) {
	parts := stream_file_parts()
	file := stream_file(parts)
	padded, padded_ok := record_type(file, PADDED)
	probe, probe_ok := record_type(file, PROBE)
	testing.expect(t, padded_ok && probe_ok)
	testing.expect(t, !record_covers_each_byte(file, padded))
	testing.expect(t, record_covers_each_byte(file, probe))
	// The record Probe with a size of 24: 8 bytes after its last field.
	longer := stream_file_parts()
	longer.records[PROBE].size = 24
	longer_file := stream_file(longer)
	longer_record, longer_ok := record_type(longer_file, PROBE)
	testing.expect(t, longer_ok && !record_covers_each_byte(longer_file, longer_record))
	_, stream_ok := record_stream_type(longer_file, PROBE)
	testing.expect(t, !stream_ok)
}
