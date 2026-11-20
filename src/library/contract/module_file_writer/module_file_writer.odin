// The module file writer: the one body of code that writes the bytes of a
// module file from its parts (docs/MODULE_CONTRACT.md, "The module file
// writer").
//
// The modus tool fills the parts from the linked file of `lld`; a program of
// modus that writes a module (an assembler) fills them from its own source.
// Both call the same two procedures, so the format has one writer:
//
// - `file_size_needed` checks the parts and gives the bytes of the file.
// - `write` checks the parts again and writes the file into the memory that
//   the caller gives. It allocates nothing and calls no kernel operation.
//
// A refusal is a `Refusal_Record`: what is wrong, the table of the part, and
// the index of the part in its list. The writer refuses a table past its
// bound, a name that is not a name, an export or a record stream with no
// description of a record that it names, two segments that overlap, and
// each part that a loader would refuse (`module.validate`). A written file
// is checked last with `module.validate`, with the readers of the
// descriptions, and with `module.record_streams_check`.
//
// See [module file writer](term:module-file-writer).
package module_file_writer

import "base:intrinsics"
import module "modus:contract/module"
import "modus:contract/value_kinds"

// The name of the export that a loader starts: the header names it in
// `entry_export`.
ENTRY_EXPORT_NAME :: "entry"

// The bytes of a name, at most: the count of the name of a parameter is one
// byte (module.Function.parameter_name_counts), and one bound holds for
// each name.
NAME_BYTES_MOST :: 255

// The records of a table, record 0 included, at most, and the bytes of the
// string table: the directory holds a count in 32 bits
// (module.Table_Entry.count), and a string offset is 32 bits.
TABLE_RECORDS_MOST :: u64(max(u32))

// The alignment of each table in the file: the largest field of a record is
// 8 bytes.
TABLE_ALIGNMENT :: 8

// One segment: a run of the memory of the module with one access.
Segment_Part :: struct {
	memory_offset: u64, // From the base of the module: a multiple of module.PAGE_SIZE.
	memory_size:   u64, // A multiple of module.PAGE_SIZE.
	// The access before the relocations. The writer removes Write and
	// Read_Only_After_Load from a segment that no rebase and no slot writes
	// (segment_flags_after_the_relocations).
	flags:         module.Segment_Flags,
	data:          []u8, // The bytes from memory_offset: at most memory_size. The zero bytes at its end are not stored.
}

// One export, with its description: what module.Export and module.Function
// hold.
Export_Part :: struct {
	name:                 string, // A name: ENTRY_EXPORT_NAME for the entry of the module.
	code_offset:          u64, // The memory offset of its first instruction, in a segment with Execute.
	about:                string, // One line of help.
	text:                 string, // The documentation text, in its Markdown.
	parameters:           []module.Type, // At most module.PARAMETER_CAPACITY arguments in the call form (module.call_argument_count).
	parameter_names:      []string, // The name of each parameter: one for each.
	// What the type of each parameter needs (module.Function.parameter_details):
	// a Record or a Table: the number of its record, from 1, in
	// Module_Parts.records. At most one for each parameter; a missing one is 0.
	parameter_details:    []u32,
	// An Enum parameter: module.enum_detail_make of the number of its enum,
	// from 1, in Module_Parts.enums, and of the number of its getter, from
	// 1, in Module_Parts.exports, or 0.
	parameter_directions: []module.Direction, // At most one for each parameter; a missing one is Read.
	optional_parameters:  u16, // Bit n: a call may leave out the parameter n, an Enum (module.Function.optional_parameters).
	result:               module.Type,
	result_detail:        u32, // A Record or Table result: the number of its record, from 1. An Enum result: the number of its enum, from 1.
	error_record:         u32, // Not 0: the number of the record of its error record, from 1.
}

// The description of an enum: what module.Enum_Type and its members hold.
Enum_Description :: struct {
	name:     string, // The name of the type in its source.
	size:     u8, // 1, 2, 4 or 8.
	unsigned: bool,
	members:  []Member_Description,
}

// One member of an enum: what module.Member holds.
Member_Description :: struct {
	name:  string, // A name that module.enum_member_name_valid takes.
	value: i64,
}

// The description of a record: what module.Record and its fields hold.
Record_Description :: struct {
	name:   string,
	size:   u32,
	fields: []Field_Description,
}

// The description of one field of a record: what module.Field holds.
Field_Description :: struct {
	name:          string,
	offset:        u32,
	type:          module.Type,
	detail:        u32, // An Integer: its size, 0 for 8. A Handle: the rights that the callee needs. A Text or Bytes: its size in bytes.
	unsigned:      bool, // An unsigned Integer.
	integer_unit:  value_kinds.Integer_Unit, // An Integer: what it counts, {} for a plain number (module.Field.integer_unit).
	kind:          value_kinds.Field_Kind, // How a reader writes the value (module.Field.kind).
	contract_enum: value_kinds.Contract_Enum, // A Status: the enum of its members (module.Field.contract_enum).
}

// One log fact that the module writes: one row of the table Facts.
Fact_Part :: struct {
	key:          u64, // The fact key: not 0. The facts of a module are in the order of their keys, each key one time.
	record_index: u32, // The number of the record of its values, from 1, in Module_Parts.records.
	template:     string, // The fact template: not empty.
	package_name: string, // The name of the package that declares the record type.
}

// One record output that the module declares: one row of the table
// Record_Outputs (src/md/features/module_outputs.md, "The declaration in
// the module").
Record_Output_Part :: struct {
	name:         string, // A name: the name of its variable in the source. The record outputs are in the order of their names.
	about:        string, // One line of help.
	text:         string, // The documentation text, in its Markdown.
	record_index: u32, // The number of its record, from 1, in Module_Parts.records; 0 for a generic record output.
	pairing:      module.Record_Output_Pairing,
	// The memory offset of its variable, where a loader writes the index of
	// the row: 0 when the link kept no variable, else
	// module.RECORD_STREAM_PLACE_SIZE aligned bytes in a segment with Write
	// that keeps Write after the load.
	place:        u64,
}

// One record input that the module declares: one row of the table
// Record_Inputs.
Record_Input_Part :: struct {
	name:         string, // A name, as for a record output. The record inputs are in the order of their names, and no name is in both lists.
	about:        string,
	text:         string,
	record_index: u32, // The number of its record, from 1; 0 for a generic record input.
	terms_index:  u32, // The number of the record of its wiring terms, from 1; 0 for none.
	wirings:      module.Wiring_Count,
	place:        u64, // As Record_Output_Part.place.
}

// The parts of one module file. The record n + 1 of a table of the file is
// the part n of its list: index 0 of each table is the empty record.
Module_Parts :: struct {
	segments:           []Segment_Part, // In the order of their memory offsets, no two on one page.
	exports:            []Export_Part,
	imports:            [][module.HASH_SIZE]u8, // The hash of the file of each imported module.
	slots:              []module.Slot, // Each in writable data, its import an index of imports from 1.
	rebases:            []u64, // The memory offsets that a loader rebases: in order, each one time, each in writable data.
	records:            []Record_Description,
	enums:              []Enum_Description, // The file has the tables Enums and Members when there is one.
	facts:              []Fact_Part,
	has_own_hash_place: bool, // The module has an own-hash place: a module that writes a fact must have one.
	own_hash_place:     u64, // module.HASH_SIZE bytes in a segment with Write and no Execute.
	about:              string, // One line: what the module is.
	text:               string, // The documentation text of the module, in its Markdown.
	has_budget:         bool, // The module asks for a budget: the file has the table Budget.
	budget:             module.Budget_Request,
	record_outputs:     []Record_Output_Part, // At most module.RECORD_STREAM_INDEX_MOST: the file has the table Record_Outputs when there is one.
	record_inputs:      []Record_Input_Part, // At most module.RECORD_STREAM_INDEX_MOST: the table Record_Inputs.
}

// What is wrong with the parts, or with the memory of the output. The
// values are fixed: a test and a caller name the member.
Refusal :: enum u32 {
	None                          = 0, // The file is written.
	Table_Past_Bound              = 1, // A table has more records than TABLE_RECORDS_MOST, or the string table more bytes. value: the count.
	Not_A_Name                    = 2, // A name is empty, longer than NAME_BYTES_MOST, or has a byte that is not an ASCII letter, a digit or `_`, or starts with a digit.
	Name_Twice                    = 3, // Two exports have one name: an import binds an export by its name.
	Export_Without_Description    = 4, // A Record or Table parameter or result, or an error record, names no record of the parts. value: the number that it names.
	Too_Many_Arguments            = 5, // The call form of an export has more than module.PARAMETER_CAPACITY arguments. value: the count.
	Parameter_Lists_Disagree      = 6, // An export has not one name for each parameter, or more details or directions than parameters.
	Export_Outside_Code           = 7, // The code offset of an export is in no segment with Execute. value: the offset.
	Segment_Not_On_Pages          = 8, // The memory offset or the memory size of a segment is not a multiple of module.PAGE_SIZE.
	Segment_Past_Address_Range    = 9, // The end of a segment passes the end of 64 bits.
	Segment_Data_Past_Size        = 10, // A segment has more bytes of data than its memory size.
	Segment_Overlap               = 11, // A segment starts before the end of the segment before it.
	Segment_Written_And_Executed  = 12, // A segment has Execute with Write or with Read_Only_After_Load.
	Slot_Not_Valid                = 13, // A slot names no import or no export, or its 8 bytes are not in writable data.
	Rebase_Not_Valid              = 14, // A rebase is not after the one before it, not on 8 bytes, or not in writable data. value: the offset.
	Record_Not_Valid              = 15, // A record description is refused by module.record_type.
	Fact_Not_Valid                = 16, // A fact has the key 0, a key not after the one before it, no record, or no template.
	Facts_Without_Own_Hash_Place  = 17, // The module writes facts and has no own-hash place.
	Own_Hash_Place_Not_Writable   = 18, // The own-hash place is not module.HASH_SIZE bytes inside one segment with Write and no Execute.
	Output_Too_Small              = 19, // The memory of the output is smaller than the file. value: the bytes that the file needs.
	Written_File_Not_Valid        = 20, // module.validate refuses the written file: a fault of this writer. value: the module.Error.
	Record_Streams_Past_Bound     = 21, // More record outputs, or more record inputs, than module.RECORD_STREAM_INDEX_MOST: each loader checks the place of each one against each other write of its load. value: the count.
	Record_Stream_Without_Description = 22, // The record or the terms of a record stream names no record of the parts. value: the number that it names.
	Record_Stream_Place_Not_Writable  = 23, // The place of a record stream is not 0, nor module.RECORD_STREAM_PLACE_SIZE aligned bytes in a segment with Write, no Execute, and not Read_Only_After_Load. value: the place.
	// module.record_streams_check refuses the record streams of the written file: a row that its reader
	// refuses, names out of order or two times, a name in both tables, or a generic record output with no
	// generic record input or with two. index: the row from 1, 0 for the tables; value: the
	// module.Record_Stream_Fault.
	Record_Streams_Not_Valid      = 24,
	// An Enum parameter or result names no enum of the parts or a getter past the exports, an optional bit is on
	// a parameter that is no Enum, or module.enum_type and module.function_enums_check refuse the written file.
	// value: the module.Enum_Problem, or the number that names nothing.
	Enum_Not_Valid                = 25,
}

// The refusal of the writer, and where it is.
Refusal_Record :: struct {
	refusal: Refusal,
	table:   module.Table_Kind, // The table of the part that is wrong; None for the output.
	index:   u64, // The index of the part in its list of Module_Parts, from 0.
	value:   u64, // What the member of Refusal says.
}

// The place of each table, the end of the file, and the facts of the
// header, which file_size_needed and write compute in one way.
@(private)
Layout :: struct {
	directory:    [module.TABLE_COUNT]module.Table_Entry,
	tables_end:   u64, // The end of the last table: the data of the first segment starts on the next page.
	file_size:    u64,
	memory_size:  u64,
	entry_export: u32,
}

// file_size_needed gives the bytes of the file that write writes from the
// parts, after it checked the parts. It reads no byte of a text: only its
// length.
file_size_needed :: proc "contextless" (parts: Module_Parts) -> (size: u64, refusal: Refusal_Record) {
	layout: Layout
	layout, refusal = plan(parts)
	return layout.file_size, refusal
}

// write writes the module file of the parts at the start of output, and
// gives its size. A refusal of the parts, and Output_Too_Small, change no
// byte of output; Output_Too_Small gives the size that the file needs. A
// refusal of the last check (Record_Not_Valid, Fact_Not_Valid,
// Written_File_Not_Valid) leaves the bytes of the file at zero, so no part
// of a refused file stays.
//
// ```odin
// size, refusal := module_file_writer.file_size_needed(parts)
// // The caller takes `size` bytes of its own memory.
// size, refusal = module_file_writer.write(parts, output[:size])
// ```
write :: proc "contextless" (parts: Module_Parts, output: []u8) -> (size: u64, refusal: Refusal_Record) {
	layout: Layout
	layout, refusal = plan(parts)
	if refusal.refusal != .None {
		return 0, refusal
	}
	size = layout.file_size
	if u64(len(output)) < size {
		return size, {refusal = .Output_Too_Small, value = size}
	}
	file := output[:size]
	intrinsics.mem_zero(raw_data(file), len(file))
	tables_write(parts, layout, file)
	refusal = written_file_check(parts, file)
	if refusal.refusal != .None {
		intrinsics.mem_zero(raw_data(file), len(file))
		return 0, refusal
	}
	return size, {}
}

// indexed_table_fits says if a table of count parts fits in the directory:
// the parts and the empty record 0.
indexed_table_fits :: proc "contextless" (count: int) -> bool {
	return count >= 0 && u64(count) < TABLE_RECORDS_MOST
}

// is_name says if a text is a name of the module format: 1 to
// NAME_BYTES_MOST bytes, ASCII letters, digits and `_`, and no digit first.
// A reader shows a name and an import binds by it, so a name has one
// spelling and no control byte.
is_name :: proc "contextless" (text: string) -> bool {
	if len(text) == 0 || len(text) > NAME_BYTES_MOST {
		return false
	}
	for index in 0 ..< len(text) {
		character := text[index]
		letter := character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character == '_'
		digit := character >= '0' && character <= '9'
		if !letter && !(digit && index > 0) {
			return false
		}
	}
	return true
}

// segment_flags_after_the_relocations gives the flags of a segment once
// each rebase and each slot of the module is known. A segment that is
// read-only after the load and that holds no rebase and no slot is a
// segment that no loader writes: it loses Write and Read_Only_After_Load,
// and is a constant segment. Each other segment keeps its flags.
//
// Why it is sound: a loader writes a segment in two ways only, a rebase
// and a slot, and both lists are complete here. The pages of such a
// segment are then the same at each base and with each binding, which is
// what makes a segment a part of the shared code of a module. Its
// protection in a process does not change: a segment that is read-only
// after the load was never writable there.
segment_flags_after_the_relocations :: proc "contextless" (segment: module.Segment, rebases: []u64, slots: []module.Slot) -> module.Segment_Flags {
	if .Read_Only_After_Load not_in segment.flags {
		return segment.flags
	}
	for offset in rebases {
		if offset >= segment.memory_offset && offset - segment.memory_offset < segment.memory_size {
			return segment.flags
		}
	}
	for slot in slots {
		if slot.memory_offset >= segment.memory_offset && slot.memory_offset - segment.memory_offset < segment.memory_size {
			return segment.flags
		}
	}
	return segment.flags - {.Write, .Read_Only_After_Load}
}

// plan checks the parts and computes the layout of the file. It checks
// the count of each list before it reads one part of it.
@(private)
plan :: proc "contextless" (parts: Module_Parts) -> (layout: Layout, refusal: Refusal_Record) {
	Count :: struct {
		table: module.Table_Kind,
		count: int,
	}
	counts := [?]Count {
		{.Segments, len(parts.segments)},
		{.Imports, len(parts.imports)},
		{.Slots, len(parts.slots)},
		{.Exports, len(parts.exports)},
		{.Records, len(parts.records)},
		{.Enums, len(parts.enums)},
		{.Facts, len(parts.facts)},
	}
	for item in counts {
		if !indexed_table_fits(item.count) {
			return {}, {refusal = .Table_Past_Bound, table = item.table, value = u64(item.count)}
		}
	}
	// The record streams have a bound of their own, far below the bound of
	// a table, which module.validate checks before it reads a row.
	streams := [2]Count{{.Record_Outputs, len(parts.record_outputs)}, {.Record_Inputs, len(parts.record_inputs)}}
	for item in streams {
		if item.count > module.RECORD_STREAM_INDEX_MOST {
			return {}, {refusal = .Record_Streams_Past_Bound, table = item.table, value = u64(item.count)}
		}
	}

	layout.memory_size, refusal = segments_check(parts.segments)
	if refusal.refusal != .None {
		return {}, refusal
	}
	Check :: proc "contextless" (checked: Module_Parts) -> Refusal_Record
	checks := [?]Check{names_check, exports_check, relocations_check, facts_check, record_streams_check}
	for check in checks {
		refusal = check(parts)
		if refusal.refusal != .None {
			return {}, refusal
		}
	}
	for item, index in parts.exports {
		if item.name == ENTRY_EXPORT_NAME {
			layout.entry_export = u32(index + 1)
		}
	}

	field_count := u64(1)
	for item in parts.records {
		field_count = sum_or_most(field_count, u64(len(item.fields)))
	}
	if field_count > TABLE_RECORDS_MOST {
		return {}, {refusal = .Table_Past_Bound, table = .Fields, value = field_count}
	}
	member_count := u64(1)
	for item in parts.enums {
		member_count = sum_or_most(member_count, u64(len(item.members)))
	}
	if member_count > TABLE_RECORDS_MOST {
		return {}, {refusal = .Table_Past_Bound, table = .Members, value = member_count}
	}
	string_bytes := string_bytes_needed(parts)
	if string_bytes > TABLE_RECORDS_MOST {
		return {}, {refusal = .Table_Past_Bound, table = .Strings, value = string_bytes}
	}
	rebase_words := rebase_words_encode(parts.rebases, nil)
	if rebase_words > TABLE_RECORDS_MOST {
		return {}, {refusal = .Table_Past_Bound, table = .Rebases, value = rebase_words}
	}

	// The tables, in the order of the format of the tool before this
	// package: one order gives the same bytes, so the same hash.
	cursor := u64(size_of(module.Header) + size_of(layout.directory))
	add :: proc "contextless" (layout: ^Layout, cursor: ^u64, kind: module.Table_Kind, count: u64, record_size: u64) {
		offset := align_forward(cursor^, TABLE_ALIGNMENT)
		layout.directory[kind] = {offset = offset, count = u32(count), record_size = u32(record_size)}
		cursor^ = offset + count * record_size
	}
	add(&layout, &cursor, .Segments, u64(len(parts.segments)) + 1, size_of(module.Segment))
	add(&layout, &cursor, .Imports, u64(len(parts.imports)) + 1, size_of(module.Import))
	add(&layout, &cursor, .Slots, u64(len(parts.slots)) + 1, size_of(module.Slot))
	add(&layout, &cursor, .Exports, u64(len(parts.exports)) + 1, size_of(module.Export))
	add(&layout, &cursor, .Rebases, rebase_words, module.REBASE_WORD_SIZE)
	add(&layout, &cursor, .Functions, u64(len(parts.exports)) + 1, size_of(module.Function))
	add(&layout, &cursor, .Records, u64(len(parts.records)) + 1, size_of(module.Record))
	add(&layout, &cursor, .Fields, field_count, size_of(module.Field))
	if len(parts.facts) > 0 {
		add(&layout, &cursor, .Facts, u64(len(parts.facts)) + 1, size_of(module.Fact))
	}
	if parts.has_own_hash_place {
		add(&layout, &cursor, .Own_Hash, 2, size_of(module.Own_Hash_Place))
	}
	if len(parts.record_outputs) > 0 {
		add(&layout, &cursor, .Record_Outputs, u64(len(parts.record_outputs)) + 1, size_of(module.Record_Output))
	}
	if len(parts.record_inputs) > 0 {
		add(&layout, &cursor, .Record_Inputs, u64(len(parts.record_inputs)) + 1, size_of(module.Record_Input))
	}
	if len(parts.enums) > 0 {
		add(&layout, &cursor, .Enums, u64(len(parts.enums)) + 1, size_of(module.Enum_Type))
		add(&layout, &cursor, .Members, member_count, size_of(module.Member))
	}
	add(&layout, &cursor, .Strings, string_bytes, 1)
	add(&layout, &cursor, .Documentation, 2, size_of(module.Documentation))
	if parts.has_budget {
		add(&layout, &cursor, .Budget, 2, size_of(module.Budget_Request))
	}
	layout.tables_end = cursor
	// The data of each segment starts on its own page of the file. A
	// segment with no stored byte still moves the end to a page.
	for item in parts.segments {
		cursor = align_forward(cursor, module.PAGE_SIZE) + u64(len(stored_bytes(item.data)))
	}
	layout.file_size = cursor
	return layout, {}
}

// segments_check checks the order, the pages, the end, the data and the
// access of each segment, and gives the memory size of the module: the end
// of its last segment.
@(private)
segments_check :: proc "contextless" (segments: []Segment_Part) -> (memory_size: u64, refusal: Refusal_Record) {
	for item, index in segments {
		where_it_is := Refusal_Record{table = .Segments, index = u64(index)}
		switch {
		case item.memory_offset % module.PAGE_SIZE != 0 || item.memory_size % module.PAGE_SIZE != 0:
			where_it_is.refusal = .Segment_Not_On_Pages
		case item.memory_size > max(u64) - item.memory_offset:
			where_it_is.refusal = .Segment_Past_Address_Range
		case u64(len(item.data)) > item.memory_size:
			where_it_is.refusal = .Segment_Data_Past_Size
			where_it_is.value = u64(len(item.data))
		case index > 0 && item.memory_offset < memory_size:
			where_it_is.refusal = .Segment_Overlap
			where_it_is.value = item.memory_offset
		case .Execute in item.flags && item.flags & {.Write, .Read_Only_After_Load} != {}:
			where_it_is.refusal = .Segment_Written_And_Executed
		}
		if where_it_is.refusal != .None {
			return 0, where_it_is
		}
		memory_size = item.memory_offset + item.memory_size
	}
	return memory_size, {}
}

// names_check checks each name of the parts, and that no two exports have
// one name.
@(private)
names_check :: proc "contextless" (parts: Module_Parts) -> Refusal_Record {
	for item, index in parts.exports {
		if !is_name(item.name) {
			return {refusal = .Not_A_Name, table = .Exports, index = u64(index)}
		}
		for name in item.parameter_names {
			if !is_name(name) {
				return {refusal = .Not_A_Name, table = .Functions, index = u64(index)}
			}
		}
		for other in parts.exports[:index] {
			if other.name == item.name {
				return {refusal = .Name_Twice, table = .Exports, index = u64(index)}
			}
		}
	}
	for item, index in parts.records {
		if !is_name(item.name) {
			return {refusal = .Not_A_Name, table = .Records, index = u64(index)}
		}
		for field in item.fields {
			if !is_name(field.name) {
				return {refusal = .Not_A_Name, table = .Fields, index = u64(index)}
			}
		}
	}
	for item, index in parts.facts {
		if !is_name(item.package_name) {
			return {refusal = .Not_A_Name, table = .Facts, index = u64(index)}
		}
	}
	for item, index in parts.enums {
		if !is_name(item.name) {
			return {refusal = .Not_A_Name, table = .Enums, index = u64(index)}
		}
		for member in item.members {
			if !module.enum_member_name_valid(member.name) {
				return {refusal = .Not_A_Name, table = .Members, index = u64(index)}
			}
		}
	}
	for item, index in parts.record_outputs {
		if !is_name(item.name) {
			return {refusal = .Not_A_Name, table = .Record_Outputs, index = u64(index)}
		}
	}
	for item, index in parts.record_inputs {
		if !is_name(item.name) {
			return {refusal = .Not_A_Name, table = .Record_Inputs, index = u64(index)}
		}
	}
	return {}
}

// record_streams_check checks the record and the terms of each record
// stream, which name a record of the parts or 0, and its place, where a
// loader writes the index of its row. The order of the names and the rules
// of a generic stream are checked on the written file, by the one reader
// of the format (written_file_check).
@(private)
record_streams_check :: proc "contextless" (parts: Module_Parts) -> Refusal_Record {
	described_or_none :: proc "contextless" (number: u32, records: []Record_Description) -> bool {
		return u64(number) <= u64(len(records))
	}
	for item, index in parts.record_outputs {
		where_it_is := Refusal_Record{table = .Record_Outputs, index = u64(index)}
		if !described_or_none(item.record_index, parts.records) {
			where_it_is.refusal, where_it_is.value = .Record_Stream_Without_Description, u64(item.record_index)
			return where_it_is
		}
		if !record_stream_place_writable(parts.segments, item.place) {
			where_it_is.refusal, where_it_is.value = .Record_Stream_Place_Not_Writable, item.place
			return where_it_is
		}
	}
	for item, index in parts.record_inputs {
		where_it_is := Refusal_Record{table = .Record_Inputs, index = u64(index)}
		if !described_or_none(item.record_index, parts.records) {
			where_it_is.refusal, where_it_is.value = .Record_Stream_Without_Description, u64(item.record_index)
			return where_it_is
		}
		if !described_or_none(item.terms_index, parts.records) {
			where_it_is.refusal, where_it_is.value = .Record_Stream_Without_Description, u64(item.terms_index)
			return where_it_is
		}
		if !record_stream_place_writable(parts.segments, item.place) {
			where_it_is.refusal, where_it_is.value = .Record_Stream_Place_Not_Writable, item.place
			return where_it_is
		}
	}
	return {}
}

// record_stream_place_writable says if a place is one that a loader writes
// and that the library writes after the load: 0, or
// module.RECORD_STREAM_PLACE_SIZE aligned bytes in a segment with Write, no
// Execute, and not Read_Only_After_Load. A place that meets another write
// of a loader is refused by module.validate in the last check.
@(private)
record_stream_place_writable :: proc "contextless" (segments: []Segment_Part, place: u64) -> bool {
	if place == 0 {
		return true
	}
	if place % module.RECORD_STREAM_PLACE_SIZE != 0 || !writable_range(segments, place, module.RECORD_STREAM_PLACE_SIZE) {
		return false
	}
	for item in segments {
		if place >= item.memory_offset && place - item.memory_offset < item.memory_size {
			return .Read_Only_After_Load not_in item.flags
		}
	}
	return false
}

// exports_check checks the call form of each export and that each record
// that it names is in the parts.
@(private)
exports_check :: proc "contextless" (parts: Module_Parts) -> Refusal_Record {
	described :: proc "contextless" (number: u32, records: []Record_Description) -> bool {
		return number >= 1 && u64(number) <= u64(len(records))
	}
	for item, index in parts.exports {
		where_it_is := Refusal_Record{table = .Exports, index = u64(index)}
		arguments := module.call_argument_count(len(item.parameters), u8(item.result), item.error_record != 0)
		if arguments > module.PARAMETER_CAPACITY {
			where_it_is.refusal, where_it_is.value = .Too_Many_Arguments, u64(arguments)
			return where_it_is
		}
		if len(item.parameter_names) != len(item.parameters) || len(item.parameter_details) > len(item.parameters) || len(item.parameter_directions) > len(item.parameters) {
			where_it_is.refusal = .Parameter_Lists_Disagree
			return where_it_is
		}
		for type, parameter in item.parameters {
			detail := parameter < len(item.parameter_details) ? item.parameter_details[parameter] : 0
			if module.parameter_optional({optional_parameters = item.optional_parameters}, parameter) && type != .Enum {
				where_it_is.refusal, where_it_is.value = .Enum_Not_Valid, u64(module.Enum_Problem.Bad_Optional)
				return where_it_is
			}
			if type == .Enum {
				enum_number, getter := module.enum_detail_of(detail)
				if enum_number == 0 || u64(enum_number) > u64(len(parts.enums)) {
					where_it_is.refusal, where_it_is.value = .Enum_Not_Valid, u64(enum_number)
					return where_it_is
				}
				if u64(getter) > u64(len(parts.exports)) {
					where_it_is.refusal, where_it_is.value = .Enum_Not_Valid, u64(getter)
					return where_it_is
				}
				continue
			}
			if type != .Record && type != .Table {
				continue
			}
			if !described(detail, parts.records) {
				where_it_is.refusal, where_it_is.value = .Export_Without_Description, u64(detail)
				return where_it_is
			}
		}
		if item.optional_parameters >> u16(min(len(item.parameters), 16)) != 0 {
			where_it_is.refusal, where_it_is.value = .Enum_Not_Valid, u64(module.Enum_Problem.Bad_Optional)
			return where_it_is
		}
		if (item.result == .Record || item.result == .Table) && !described(item.result_detail, parts.records) {
			where_it_is.refusal, where_it_is.value = .Export_Without_Description, u64(item.result_detail)
			return where_it_is
		}
		if item.result == .Enum && (item.result_detail == 0 || u64(item.result_detail) > u64(len(parts.enums))) {
			where_it_is.refusal, where_it_is.value = .Enum_Not_Valid, u64(item.result_detail)
			return where_it_is
		}
		if item.error_record != 0 && !described(item.error_record, parts.records) {
			where_it_is.refusal, where_it_is.value = .Export_Without_Description, u64(item.error_record)
			return where_it_is
		}
		in_code := false
		for segment in parts.segments {
			if .Execute in segment.flags && item.code_offset >= segment.memory_offset && item.code_offset - segment.memory_offset < segment.memory_size {
				in_code = true
			}
		}
		if !in_code {
			where_it_is.refusal, where_it_is.value = .Export_Outside_Code, item.code_offset
			return where_it_is
		}
	}
	return {}
}

// relocations_check checks each slot, each rebase and the own-hash place:
// a loader writes each of them, so each is in writable data.
@(private)
relocations_check :: proc "contextless" (parts: Module_Parts) -> Refusal_Record {
	for item, index in parts.slots {
		if item.import_index == 0 || u64(item.import_index) > u64(len(parts.imports)) || item.export_index == 0 || item.memory_offset % module.REBASE_WORD_SIZE != 0 || !writable_range(parts.segments, item.memory_offset, module.REBASE_WORD_SIZE) {
			return {refusal = .Slot_Not_Valid, table = .Slots, index = u64(index), value = item.memory_offset}
		}
	}
	for offset, index in parts.rebases {
		after_the_one_before := index == 0 || offset > parts.rebases[index - 1]
		if !after_the_one_before || offset % module.REBASE_WORD_SIZE != 0 || !writable_range(parts.segments, offset, module.REBASE_WORD_SIZE) {
			return {refusal = .Rebase_Not_Valid, table = .Rebases, index = u64(index), value = offset}
		}
	}
	if parts.has_own_hash_place && !writable_range(parts.segments, parts.own_hash_place, module.HASH_SIZE) {
		return {refusal = .Own_Hash_Place_Not_Writable, table = .Own_Hash, value = parts.own_hash_place}
	}
	return {}
}

// facts_check checks the order of the keys, the record and the template of
// each fact, and that a module with facts has its own-hash place: a fact
// record names its module by the hash that a loader writes there.
@(private)
facts_check :: proc "contextless" (parts: Module_Parts) -> Refusal_Record {
	if len(parts.facts) > 0 && !parts.has_own_hash_place {
		return {refusal = .Facts_Without_Own_Hash_Place, table = .Facts}
	}
	for item, index in parts.facts {
		after_the_one_before := index == 0 || item.key > parts.facts[index - 1].key
		described := item.record_index >= 1 && u64(item.record_index) <= u64(len(parts.records))
		if item.key == 0 || !after_the_one_before || !described || len(item.template) == 0 {
			return {refusal = .Fact_Not_Valid, table = .Facts, index = u64(index), value = item.key}
		}
	}
	return {}
}

// writable_range says if size bytes at memory_offset are inside one segment
// with Write and no Execute. No sum is formed: an offset near the end of 64
// bits must not wrap into a segment near 0.
@(private)
writable_range :: proc "contextless" (segments: []Segment_Part, memory_offset: u64, size: u64) -> bool {
	for item in segments {
		if memory_offset < item.memory_offset {
			continue
		}
		into := memory_offset - item.memory_offset
		if into <= item.memory_size && item.memory_size - into >= size {
			return .Write in item.flags && .Execute not_in item.flags
		}
	}
	return false
}

// string_bytes_needed gives the bytes of the string table: the zero byte
// at offset 0, then each text in the order of tables_write.
@(private)
string_bytes_needed :: proc "contextless" (parts: Module_Parts) -> u64 {
	total := u64(1)
	for item in parts.exports {
		total = sum_or_most(total, u64(len(item.name)))
		total = sum_or_most(total, u64(len(item.about)))
		total = sum_or_most(total, u64(len(item.text)))
		for name in item.parameter_names {
			total = sum_or_most(total, u64(len(name)))
		}
	}
	total = sum_or_most(total, u64(len(parts.about)))
	total = sum_or_most(total, u64(len(parts.text)))
	for item in parts.records {
		total = sum_or_most(total, u64(len(item.name)))
		for field in item.fields {
			total = sum_or_most(total, u64(len(field.name)))
		}
	}
	for item in parts.facts {
		total = sum_or_most(total, u64(len(item.template)))
		total = sum_or_most(total, u64(len(item.package_name)))
	}
	for item in parts.record_outputs {
		total = sum_or_most(total, u64(len(item.name)))
		total = sum_or_most(total, u64(len(item.about)))
		total = sum_or_most(total, u64(len(item.text)))
	}
	for item in parts.record_inputs {
		total = sum_or_most(total, u64(len(item.name)))
		total = sum_or_most(total, u64(len(item.about)))
		total = sum_or_most(total, u64(len(item.text)))
	}
	for item in parts.enums {
		total = sum_or_most(total, u64(len(item.name)))
		for member in item.members {
			total = sum_or_most(total, u64(len(member.name)))
		}
	}
	return total
}

// sum_or_most gives a + b, or the largest value when the sum passes the end
// of 64 bits: such a sum is past each bound.
@(private)
sum_or_most :: proc "contextless" (a, b: u64) -> u64 {
	sum, overflowed := intrinsics.overflow_add(a, b)
	return overflowed ? max(u64) : sum
}

// align_forward gives the first multiple of alignment at or after value.
// alignment is a power of two.
@(private)
align_forward :: proc "contextless" (value: u64, alignment: u64) -> u64 {
	return (value + alignment - 1) & ~(alignment - 1)
}

// stored_bytes gives the bytes of a segment that the file stores: the
// zero bytes at its end are not stored, a loader gives zero memory.
@(private)
stored_bytes :: proc "contextless" (data: []u8) -> []u8 {
	count := len(data)
	for count > 0 && data[count - 1] == 0 {
		count -= 1
	}
	return data[:count]
}

// rebase_words_encode writes sorted memory offsets in the RELR form
// (module/format.odin) at the start of destination, and gives the count of
// its words. A nil destination only counts them.
@(private)
rebase_words_encode :: proc "contextless" (memory_offsets: []u64, destination: []u8) -> (word_count: u64) {
	put :: proc "contextless" (destination: []u8, word_count: u64, word: u64) {
		if destination != nil {
			store(destination, word_count * module.REBASE_WORD_SIZE, word)
		}
	}
	index := 0
	for index < len(memory_offsets) {
		put(destination, word_count, memory_offsets[index])
		word_count += 1
		cursor := memory_offsets[index] + module.REBASE_WORD_SIZE
		index += 1
		for {
			bitmap: u64
			for index < len(memory_offsets) {
				distance := memory_offsets[index] - cursor
				if distance >= module.REBASE_WORD_SIZE * module.REBASE_BITMAP_LOCATIONS || distance % module.REBASE_WORD_SIZE != 0 {
					break
				}
				bitmap |= 1 << (distance / module.REBASE_WORD_SIZE + 1)
				index += 1
			}
			if bitmap == 0 {
				break
			}
			put(destination, word_count, bitmap | 1)
			word_count += 1
			cursor += module.REBASE_WORD_SIZE * module.REBASE_BITMAP_LOCATIONS
		}
	}
	return word_count
}

// store writes a value at a byte offset of the file, at any alignment of
// the memory of the caller.
@(private)
store :: proc "contextless" (file: []u8, offset: u64, value: $T) {
	intrinsics.unaligned_store((^T)(raw_data(file[offset:][:size_of(T)])), value)
}

// The string table as it is written: each text after the one before.
@(private)
String_Cursor :: struct {
	file:   []u8,
	offset: u64, // The offset of the string table in the file.
	used:   u32, // The bytes written, the zero byte 0 included.
}

// string_append writes a text in the string table and gives its offset.
@(private)
string_append :: proc "contextless" (strings: ^String_Cursor, text: string) -> (offset: u32) {
	offset = strings.used
	if len(text) > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(strings.file[strings.offset + u64(offset):]), raw_data(text), len(text))
	}
	strings.used += u32(len(text))
	return offset
}

// tables_write writes the header, the directory, each table and the data
// of each segment into a file of layout.file_size zero bytes.
@(private)
tables_write :: proc "contextless" (parts: Module_Parts, layout: Layout, file: []u8) {
	directory := layout.directory
	place :: proc "contextless" (directory: [module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, index: int) -> u64 {
		entry := directory[kind]
		return entry.offset + u64(index) * u64(entry.record_size)
	}

	// The segments, with the place of their data in the file.
	data_offset := layout.tables_end
	for item, index in parts.segments {
		data := stored_bytes(item.data)
		data_offset = align_forward(data_offset, module.PAGE_SIZE)
		segment := module.Segment {
			file_offset   = data_offset,
			file_size     = u64(len(data)),
			memory_offset = item.memory_offset,
			memory_size   = item.memory_size,
			flags         = item.flags,
		}
		segment.flags = segment_flags_after_the_relocations(segment, parts.rebases, parts.slots)
		store(file, place(directory, .Segments, index + 1), segment)
		if len(data) > 0 {
			intrinsics.mem_copy_non_overlapping(raw_data(file[data_offset:]), raw_data(data), len(data))
		}
		data_offset += u64(len(data))
	}
	for hash, index in parts.imports {
		store(file, place(directory, .Imports, index + 1), module.Import{hash = hash})
	}
	for slot, index in parts.slots {
		store(file, place(directory, .Slots, index + 1), slot)
	}
	_ = rebase_words_encode(parts.rebases, file[directory[module.Table_Kind.Rebases].offset:])

	// The texts, in the order that string_bytes_needed counts.
	strings := String_Cursor{file = file, offset = directory[module.Table_Kind.Strings].offset, used = 1}
	for item, index in parts.exports {
		store(file, place(directory, .Exports, index + 1), module.Export{code_offset = item.code_offset, function = u32(index + 1)})
		function := module.Function {
			name_count      = u32(len(item.name)),
			about_count     = u32(len(item.about)),
			text_count      = u32(len(item.text)),
			parameter_count = u8(len(item.parameters)),
			optional_parameters = item.optional_parameters,
			result          = u8(item.result),
			result_detail   = item.result_detail,
			error_record    = item.error_record,
		}
		for type, parameter in item.parameters {
			function.parameters[parameter] = u8(type)
		}
		for detail, parameter in item.parameter_details {
			function.parameter_details[parameter] = detail
		}
		for direction, parameter in item.parameter_directions {
			function.parameter_directions[parameter] = direction
		}
		function.name_offset = string_append(&strings, item.name)
		function.about_offset = string_append(&strings, item.about)
		function.text_offset = string_append(&strings, item.text)
		for name, parameter in item.parameter_names {
			function.parameter_names[parameter] = string_append(&strings, name)
			function.parameter_name_counts[parameter] = u8(len(name))
		}
		store(file, place(directory, .Functions, index + 1), function)
	}
	documentation := module.Documentation {
		about_count = u32(len(parts.about)),
		text_count  = u32(len(parts.text)),
	}
	documentation.about_offset = string_append(&strings, parts.about)
	documentation.text_offset = string_append(&strings, parts.text)
	store(file, place(directory, .Documentation, 1), documentation)

	// The records, and the fields of each record one after the other.
	field_number := 1
	for item, index in parts.records {
		record := module.Record {
			name_count  = u32(len(item.name)),
			size        = item.size,
			first_field = u32(field_number),
			field_count = u32(len(item.fields)),
		}
		record.name_offset = string_append(&strings, item.name)
		store(file, place(directory, .Records, index + 1), record)
		for field in item.fields {
			row := module.Field {
				name_count    = u32(len(field.name)),
				offset        = field.offset,
				type          = u8(field.type),
				detail        = field.detail,
				unsigned      = field.unsigned,
				integer_unit  = field.integer_unit,
				kind          = u8(field.kind),
				contract_enum = u8(field.contract_enum),
			}
			row.name_offset = string_append(&strings, field.name)
			store(file, place(directory, .Fields, field_number), row)
			field_number += 1
		}
	}
	for item, index in parts.facts {
		row := module.Fact {
			key            = item.key,
			record         = item.record_index,
			template_count = u32(len(item.template)),
			package_count  = u32(len(item.package_name)),
		}
		row.template_offset = string_append(&strings, item.template)
		row.package_offset = string_append(&strings, item.package_name)
		store(file, place(directory, .Facts, index + 1), row)
	}
	// The record streams, with their name, their help and their text in
	// the strings, after the texts of the facts.
	for item, index in parts.record_outputs {
		row := module.Record_Output {
			name_count  = u32(len(item.name)),
			about_count = u32(len(item.about)),
			text_count  = u32(len(item.text)),
			record      = item.record_index,
			pairing     = u8(item.pairing),
			place       = item.place,
		}
		row.name_offset = string_append(&strings, item.name)
		row.about_offset = string_append(&strings, item.about)
		row.text_offset = string_append(&strings, item.text)
		store(file, place(directory, .Record_Outputs, index + 1), row)
	}
	for item, index in parts.record_inputs {
		row := module.Record_Input {
			name_count  = u32(len(item.name)),
			about_count = u32(len(item.about)),
			text_count  = u32(len(item.text)),
			record      = item.record_index,
			terms       = item.terms_index,
			wirings     = u8(item.wirings),
			place       = item.place,
		}
		row.name_offset = string_append(&strings, item.name)
		row.about_offset = string_append(&strings, item.about)
		row.text_offset = string_append(&strings, item.text)
		store(file, place(directory, .Record_Inputs, index + 1), row)
	}
	// The enums, and the members of each enum one after the other.
	member_number := 1
	for item, index in parts.enums {
		row := module.Enum_Type {
			name_count   = u32(len(item.name)),
			first_member = u32(member_number),
			member_count = u32(len(item.members)),
			size         = item.size,
			unsigned     = item.unsigned,
		}
		row.name_offset = string_append(&strings, item.name)
		store(file, place(directory, .Enums, index + 1), row)
		for member in item.members {
			member_row := module.Member {
				name_count = u32(len(member.name)),
				value      = member.value,
			}
			member_row.name_offset = string_append(&strings, member.name)
			store(file, place(directory, .Members, member_number), member_row)
			member_number += 1
		}
	}
	if parts.has_own_hash_place {
		store(file, place(directory, .Own_Hash, 1), module.Own_Hash_Place{memory_offset = parts.own_hash_place})
	}
	if parts.has_budget {
		store(file, place(directory, .Budget, 1), parts.budget)
	}

	header := module.Header {
		magic        = module.MAGIC,
		version      = module.VERSION,
		header_size  = size_of(module.Header),
		machine      = .X86_64,
		table_count  = module.TABLE_COUNT,
		memory_size  = layout.memory_size,
		entry_export = layout.entry_export,
	}
	store(file, 0, header)
	store(file, size_of(module.Header), directory)
}

// written_file_check reads the written file as a loader and a reader do:
// module.validate, then the description of each export, each record and
// each fact, then the record streams. A refusal here is a part that only the format of the file
// shows wrong, or a fault of this writer.
@(private)
written_file_check :: proc "contextless" (parts: Module_Parts, file: []u8) -> Refusal_Record {
	if error := module.validate(file); error != .None {
		return {refusal = .Written_File_Not_Valid, value = u64(error)}
	}
	for index in 0 ..< len(parts.exports) {
		if _, ok := module.function(file, u32(index + 1)); !ok {
			return {refusal = .Written_File_Not_Valid, table = .Functions, index = u64(index)}
		}
	}
	for index in 0 ..< len(parts.records) {
		if _, ok := module.record_type(file, u32(index + 1)); !ok {
			return {refusal = .Record_Not_Valid, table = .Records, index = u64(index)}
		}
	}
	for index in 0 ..< len(parts.facts) {
		if _, _, ok := module.fact(file, u32(index + 1)); !ok {
			return {refusal = .Fact_Not_Valid, table = .Facts, index = u64(index), value = parts.facts[index].key}
		}
	}
	// The members, their values and each getter: the readers take an enum
	// through these two procedures, so the writer writes none that they
	// refuse.
	for index in 0 ..< len(parts.enums) {
		if _, problem := module.enum_type(file, u32(index + 1)); problem != .None {
			return {refusal = .Enum_Not_Valid, table = .Enums, index = u64(index), value = u64(problem)}
		}
	}
	for index in 0 ..< len(parts.exports) {
		function, _ := module.function(file, u32(index + 1))
		if _, problem := module.function_enums_check(file, function); problem != .None {
			return {refusal = .Enum_Not_Valid, table = .Functions, index = u64(index), value = u64(problem)}
		}
	}
	// The reader of the root service checks the record streams of a file
	// with this procedure: the writer writes none that it refuses.
	if fault, row := module.record_streams_check(file); fault != .None {
		table := module.Table_Kind.Record_Outputs
		switch fault {
		case .Too_Many_Inputs, .Bad_Input, .Inputs_Out_Of_Order:
			table = .Record_Inputs
		case .None, .Too_Many_Outputs, .Bad_Output, .Outputs_Out_Of_Order, .Name_Of_Both, .Generic_Output_Alone:
			// A fault of the outputs, or of the two tables together.
		}
		return {refusal = .Record_Streams_Not_Valid, table = table, index = u64(row), value = u64(fault)}
	}
	return {}
}
