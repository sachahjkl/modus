#+build !freestanding
package module_file_writer

import module "modus:contract/module"
import "core:strings"
import "core:testing"

// The parts of the tests: a code segment, a constant segment that the
// loader never writes, a segment that the loader writes once (one slot and
// one rebase), and the data with the own-hash place.
@(private = "file")
CODE_OFFSET :: 0
@(private = "file")
CONSTANT_OFFSET :: module.PAGE_SIZE
@(private = "file")
AFTER_LOAD_OFFSET :: 2 * module.PAGE_SIZE
@(private = "file")
DATA_OFFSET :: 3 * module.PAGE_SIZE
@(private = "file")
MEMORY_SIZE :: 4 * module.PAGE_SIZE
@(private = "file")
OWN_HASH_PLACE :: DATA_OFFSET + 64
@(private = "file")
FACT_KEY :: 7

// The memory of the parts: a test changes one part, then writes.
@(private = "file")
Test_Storage :: struct {
	code:             [2]u8,
	constant:         [5]u8,
	after_load:       [16]u8,
	segments:         [4]Segment_Part,
	parameters:       [2]module.Type,
	parameter_names:  [2]string,
	details:          [2]u32,
	directions:       [2]module.Direction,
	exports:          [2]Export_Part,
	rectangle_fields: [2]Field_Description,
	failure_fields:   [1]Field_Description,
	records:          [2]Record_Description,
	facts:            [1]Fact_Part,
	imports:          [1][module.HASH_SIZE]u8,
	slots:            [1]module.Slot,
	rebases:          [1]u64,
}

@(private = "file")
test_parts :: proc(storage: ^Test_Storage) -> Module_Parts {
	storage.code = {0x90, 0xC3}
	storage.constant = {1, 2, 3, 0, 0}
	storage.segments = {
		{memory_offset = CODE_OFFSET, memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = storage.code[:]},
		{memory_offset = CONSTANT_OFFSET, memory_size = module.PAGE_SIZE, flags = {.Read, .Write, .Read_Only_After_Load}, data = storage.constant[:]},
		{memory_offset = AFTER_LOAD_OFFSET, memory_size = module.PAGE_SIZE, flags = {.Read, .Write, .Read_Only_After_Load}, data = storage.after_load[:]},
		{memory_offset = DATA_OFFSET, memory_size = module.PAGE_SIZE, flags = {.Read, .Write}},
	}
	storage.parameters = {.Record, .Integer}
	storage.parameter_names = {"rectangle", "scale"}
	storage.details = {1, 0}
	storage.directions = {.Read, .Read}
	storage.exports = {
		{name = ENTRY_EXPORT_NAME, code_offset = CODE_OFFSET, about = "Starts the probe."},
		{
			name = "area",
			code_offset = CODE_OFFSET + 1,
			about = "Gives the area of a rectangle.",
			text = "Gives the area of a rectangle, times a scale.",
			parameters = storage.parameters[:],
			parameter_names = storage.parameter_names[:],
			parameter_details = storage.details[:],
			parameter_directions = storage.directions[:],
			result = .Integer,
			error_record = 2,
		},
	}
	storage.rectangle_fields = {{name = "width", offset = 0, type = .Integer}, {name = "height", offset = 8, type = .Integer}}
	storage.failure_fields = {{name = "code", offset = 0, type = .Integer}}
	storage.records = {{name = "Rectangle", size = 16, fields = storage.rectangle_fields[:]}, {name = "Failure", size = 8, fields = storage.failure_fields[:]}}
	storage.facts = {{key = FACT_KEY, record_index = 2, template = "probe: failed with {code}", package_name = "probe"}}
	for &item in storage.imports[0] {
		item = 0x5A
	}
	storage.slots = {{memory_offset = AFTER_LOAD_OFFSET, import_index = 1, export_index = 1}}
	storage.rebases = {AFTER_LOAD_OFFSET + 8}
	return {
		segments = storage.segments[:],
		exports = storage.exports[:],
		imports = storage.imports[:],
		slots = storage.slots[:],
		rebases = storage.rebases[:],
		records = storage.records[:],
		facts = storage.facts[:],
		has_own_hash_place = true,
		own_hash_place = OWN_HASH_PLACE,
		about = "A probe of the writer.",
		text = "A probe of the writer, with each table.",
		has_budget = true,
		budget = {pages = 100, processes = 1, threads = 2},
	}
}

// The byte that fills an output before a refused write: a refusal must
// leave each of them.
@(private = "file")
UNTOUCHED :: 0xAA

// expect_refusal checks that the parts are refused, by file_size_needed
// and by write, with the refusal, the table and the index, and that write
// changed no byte of its output.
@(private = "file")
expect_refusal :: proc(t: ^testing.T, parts: Module_Parts, refusal: Refusal, table: module.Table_Kind, index: u64, loc := #caller_location) {
	_, needed := file_size_needed(parts)
	testing.expect_value(t, needed.refusal, refusal, loc)
	testing.expect_value(t, needed.table, table, loc)
	testing.expect_value(t, needed.index, index, loc)
	output: [2 * MEMORY_SIZE]u8
	for &item in output {
		item = UNTOUCHED
	}
	size, written := write(parts, output[:])
	testing.expect_value(t, written, needed, loc)
	testing.expect_value(t, size, 0, loc)
	for item in output {
		if item != UNTOUCHED {
			testing.expect(t, false, "a refused write changed its output", loc = loc)
			break
		}
	}
}

// expect_last_check_refusal checks a refusal that only the readers of the
// written file find: the plan takes the parts, and write refuses them and
// leaves each byte of the file at zero.
@(private = "file")
expect_last_check_refusal :: proc(t: ^testing.T, parts: Module_Parts, refusal: Refusal, table: module.Table_Kind, index: u64, loc := #caller_location) {
	size, needed := file_size_needed(parts)
	testing.expect_value(t, needed.refusal, Refusal.None, loc)
	output := make([]u8, int(size))
	defer delete(output)
	written_size, written := write(parts, output)
	testing.expect_value(t, written.refusal, refusal, loc)
	testing.expect_value(t, written.table, table, loc)
	testing.expect_value(t, written.index, index, loc)
	testing.expect_value(t, written_size, 0, loc)
	for item in output {
		if item != 0 {
			testing.expect(t, false, "a refused file kept a byte", loc = loc)
			break
		}
	}
}

// write_to_memory writes the parts into memory of the exact size.
@(private = "file")
write_to_memory :: proc(t: ^testing.T, parts: Module_Parts, loc := #caller_location) -> []u8 {
	size, needed := file_size_needed(parts)
	testing.expect_value(t, needed.refusal, Refusal.None, loc)
	file := make([]u8, int(size))
	written_size, written := write(parts, file)
	testing.expect_value(t, written.refusal, Refusal.None, loc)
	testing.expect_value(t, written_size, size, loc)
	return file
}

@(test)
segments_that_a_loader_refuses_are_refused :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)

	// Not on pages: the offset, then the size, one byte off.
	storage.segments[1].memory_offset = CONSTANT_OFFSET + 1
	expect_refusal(t, parts, .Segment_Not_On_Pages, .Segments, 1)
	parts = test_parts(&storage)
	storage.segments[1].memory_size = module.PAGE_SIZE + 1
	expect_refusal(t, parts, .Segment_Not_On_Pages, .Segments, 1)

	// A segment that starts on the last page of the one before, and one
	// that comes before it.
	parts = test_parts(&storage)
	storage.segments[1].memory_offset = CODE_OFFSET
	expect_refusal(t, parts, .Segment_Overlap, .Segments, 1)
	parts = test_parts(&storage)
	storage.segments[0].memory_size = 2 * module.PAGE_SIZE
	expect_refusal(t, parts, .Segment_Overlap, .Segments, 1)

	// Data of one byte more than the memory, then exactly the memory.
	parts = test_parts(&storage)
	larger := make([]u8, module.PAGE_SIZE + 1)
	defer delete(larger)
	storage.segments[3].data = larger
	expect_refusal(t, parts, .Segment_Data_Past_Size, .Segments, 3)
	storage.segments[3].data = larger[:module.PAGE_SIZE]
	file := write_to_memory(t, parts)
	delete(file)

	// Code that the loader writes.
	parts = test_parts(&storage)
	storage.segments[0].flags = {.Read, .Write, .Execute}
	expect_refusal(t, parts, .Segment_Written_And_Executed, .Segments, 0)
	storage.segments[0].flags = {.Read, .Execute, .Read_Only_After_Load}
	expect_refusal(t, parts, .Segment_Written_And_Executed, .Segments, 0)
}

@(test)
the_largest_segment :: proc(t: ^testing.T) {
	LARGEST :: max(u64) & ~u64(module.PAGE_SIZE - 1)
	code := [?]u8{0xC3}
	exports := [?]Export_Part{{name = ENTRY_EXPORT_NAME}}
	segments := [?]Segment_Part{{memory_size = LARGEST, flags = {.Read, .Execute}, data = code[:]}}
	parts := Module_Parts{segments = segments[:], exports = exports[:]}

	// One page more than the end of 64 bits, and a size that is not pages.
	segments[0].memory_offset = module.PAGE_SIZE
	expect_refusal(t, parts, .Segment_Past_Address_Range, .Segments, 0)
	segments[0].memory_offset = 0
	segments[0].memory_size = max(u64)
	expect_refusal(t, parts, .Segment_Not_On_Pages, .Segments, 0)

	// The largest: from 0 to the last page of 64 bits.
	segments[0].memory_size = LARGEST
	file := write_to_memory(t, parts)
	defer delete(file)
	testing.expect_value(t, module.validate(file), module.Error.None)
	head, _ := module.header(file)
	testing.expect_value(t, head.memory_size, u64(LARGEST))
}

@(test)
exports_with_no_description_are_refused :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)

	// Two exports with one name.
	storage.exports[1].name = ENTRY_EXPORT_NAME
	expect_refusal(t, parts, .Name_Twice, .Exports, 1)

	// A record parameter that names no record: 0, then one past the last;
	// the last one is described.
	parts = test_parts(&storage)
	storage.details[0] = 0
	expect_refusal(t, parts, .Export_Without_Description, .Exports, 1)
	storage.details[0] = u32(len(storage.records)) + 1
	expect_refusal(t, parts, .Export_Without_Description, .Exports, 1)
	storage.details[0] = u32(len(storage.records))
	file := write_to_memory(t, parts)
	delete(file)

	// A record parameter with no detail at all.
	parts = test_parts(&storage)
	storage.exports[1].parameter_details = nil
	expect_refusal(t, parts, .Export_Without_Description, .Exports, 1)

	// An error record and a Table result that name no record.
	parts = test_parts(&storage)
	storage.exports[1].error_record = u32(len(storage.records)) + 1
	expect_refusal(t, parts, .Export_Without_Description, .Exports, 1)
	parts = test_parts(&storage)
	storage.exports[1].result = .Table
	expect_refusal(t, parts, .Export_Without_Description, .Exports, 1)

	// One name for each parameter, and no more details or directions than
	// parameters.
	parts = test_parts(&storage)
	storage.exports[1].parameter_names = storage.parameter_names[:1]
	expect_refusal(t, parts, .Parameter_Lists_Disagree, .Exports, 1)
	parts = test_parts(&storage)
	storage.exports[1].parameters = storage.parameters[:1]
	storage.exports[1].parameter_names = storage.parameter_names[:1]
	expect_refusal(t, parts, .Parameter_Lists_Disagree, .Exports, 1)

	// Code outside the code: in the data, and one byte past the code.
	parts = test_parts(&storage)
	storage.exports[1].code_offset = DATA_OFFSET
	expect_refusal(t, parts, .Export_Outside_Code, .Exports, 1)
	storage.exports[1].code_offset = CODE_OFFSET + module.PAGE_SIZE
	expect_refusal(t, parts, .Export_Outside_Code, .Exports, 1)
	storage.exports[1].code_offset = CODE_OFFSET + module.PAGE_SIZE - 1
	file = write_to_memory(t, parts)
	delete(file)
}

// An Enum parameter names an enum of the parts and a getter among the
// exports, an optional bit is on an Enum parameter, an Enum result names an
// enum, and a member has a name of a member: each edge is refused, and the
// written file is checked by the readers of the enums last.
@(test)
enums_that_a_reader_refuses_are_refused :: proc(t: ^testing.T) {
	storage: Test_Storage
	members := [2]Member_Description{{"slow", 0}, {"fast", 1}}
	enums := [1]Enum_Description{{"Mode", 4, true, members[:]}}
	enum_parts :: proc(storage: ^Test_Storage, enums: []Enum_Description) -> Module_Parts {
		parts := test_parts(storage)
		parts.enums = enums
		storage.parameters[1] = .Enum
		storage.details[1], _ = module.enum_detail_make(1, 0)
		return parts
	}
	// The value of each refusal is the Enum_Problem, never a number of the
	// parts.
	expect_problem :: proc(t: ^testing.T, parts: Module_Parts, problem: module.Enum_Problem, loc := #caller_location) {
		expect_refusal(t, parts, .Enum_Not_Valid, .Exports, 1, loc)
		_, needed := file_size_needed(parts)
		testing.expect_value(t, needed.value, u64(problem), loc)
	}
	// An enum of no description: 0, then one past the last, and the
	// largest index.
	parts := enum_parts(&storage, enums[:])
	storage.details[1] = 0
	expect_problem(t, parts, .No_Enum)
	storage.details[1], _ = module.enum_detail_make(2, 0)
	expect_problem(t, parts, .No_Enum)
	storage.details[1], _ = module.enum_detail_make(module.ENUM_DETAIL_INDEX_MOST, 0)
	expect_problem(t, parts, .No_Enum)
	// A getter past the exports, and a getter whose form a reader refuses:
	// the entry gives no Enum.
	storage.details[1], _ = module.enum_detail_make(1, u32(len(storage.exports)) + 1)
	expect_problem(t, parts, .No_Getter)
	storage.details[1], _ = module.enum_detail_make(1, 1)
	expect_last_check_refusal(t, parts, .Enum_Not_Valid, .Functions, 1)
	// An optional bit on a parameter that is no Enum, and past the
	// parameters.
	parts = enum_parts(&storage, enums[:])
	storage.exports[1].optional_parameters = 0b01
	expect_problem(t, parts, .Bad_Optional)
	storage.exports[1].optional_parameters = 0b100
	expect_problem(t, parts, .Bad_Optional)
	// An Enum result of no enum: 0, one past the last, the largest word,
	// and the enum with the bits of a getter, which a result never has.
	// Each is an enum refusal, never a refusal of a record.
	parts = enum_parts(&storage, enums[:])
	storage.exports[1].result, storage.exports[1].error_record = .Enum, 0
	for detail in ([]u32{0, 2, max(u32), 1 | 1 << 16}) {
		storage.exports[1].result_detail = detail
		expect_problem(t, parts, .No_Enum)
	}
	storage.exports[1].result_detail = 1
	enum_result := write_to_memory(t, parts)
	delete(enum_result)
	// A member with no name of a member, then a member that the reader
	// refuses in the written file: the absent word.
	parts = enum_parts(&storage, enums[:])
	members[1].name = "Fast"
	expect_refusal(t, parts, .Not_A_Name, .Members, 0)
	members[1] = {"fast", 0xFFFF_FFFF}
	expect_last_check_refusal(t, parts, .Enum_Not_Valid, .Enums, 0)
	// The success comes last: an optional Enum parameter, read back.
	members[1] = {"fast", 1}
	parts = enum_parts(&storage, enums[:])
	storage.exports[1].optional_parameters = 0b10
	file := write_to_memory(t, parts)
	defer delete(file)
	function, _ := module.function(file, 2)
	described, problem := module.enum_type(file, 1)
	value, found := module.enum_value_of_name(file, described, "fast")
	testing.expect(t, problem == .None && found && value == 1 && module.parameter_optional(function, 1) && !module.parameter_optional(function, 0))
}

@(test)
the_call_form_has_at_most_its_capacity :: proc(t: ^testing.T) {
	parameters: [module.PARAMETER_CAPACITY + 1]module.Type
	names: [module.PARAMETER_CAPACITY + 1]string
	for index in 0 ..< len(parameters) {
		parameters[index] = .Integer
		names[index] = "value"
	}
	code := [?]u8{0xC3}
	segments := [?]Segment_Part{{memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = code[:]}}
	exports := [?]Export_Part{{name = "sum", result = .Integer}}
	parts := Module_Parts{segments = segments[:], exports = exports[:]}

	// One past the capacity, then the capacity with the buffer of a Text
	// result, then with an error record.
	exports[0].parameters = parameters[:module.PARAMETER_CAPACITY + 1]
	exports[0].parameter_names = names[:module.PARAMETER_CAPACITY + 1]
	expect_refusal(t, parts, .Too_Many_Arguments, .Exports, 0)
	exports[0].parameters = parameters[:module.PARAMETER_CAPACITY]
	exports[0].parameter_names = names[:module.PARAMETER_CAPACITY]
	exports[0].result = .Text
	expect_refusal(t, parts, .Too_Many_Arguments, .Exports, 0)

	// The capacity: its last parameter is written.
	exports[0].result = .Integer
	file := write_to_memory(t, parts)
	defer delete(file)
	function, ok := module.function(file, 1)
	testing.expect(t, ok)
	testing.expect_value(t, int(function.parameter_count), module.PARAMETER_CAPACITY)
	testing.expect_value(t, module.string_at(file, function.parameter_names[module.PARAMETER_CAPACITY - 1], u32(function.parameter_name_counts[module.PARAMETER_CAPACITY - 1])), "value")
}

@(test)
names_at_their_edges :: proc(t: ^testing.T) {
	longest := strings.repeat("a", NAME_BYTES_MOST)
	defer delete(longest)
	too_long := strings.repeat("a", NAME_BYTES_MOST + 1)
	defer delete(too_long)
	for name in ([?]string{"", "1a", "a-b", "a b", "a.b", "é", "a\x00", too_long}) {
		testing.expectf(t, !is_name(name), "%q is taken as a name", name)
	}
	for name in ([?]string{"a", "_", "Z", "a1", "entry", "Error_Record", longest}) {
		testing.expectf(t, is_name(name), "%q is not taken as a name", name)
	}

	// The place of each name in the parts.
	storage: Test_Storage
	parts := test_parts(&storage)
	storage.exports[1].name = "1area"
	expect_refusal(t, parts, .Not_A_Name, .Exports, 1)
	parts = test_parts(&storage)
	storage.parameter_names[1] = ""
	expect_refusal(t, parts, .Not_A_Name, .Functions, 1)
	parts = test_parts(&storage)
	storage.records[1].name = "Fail ure"
	expect_refusal(t, parts, .Not_A_Name, .Records, 1)
	parts = test_parts(&storage)
	storage.rectangle_fields[1].name = too_long
	expect_refusal(t, parts, .Not_A_Name, .Fields, 0)
	parts = test_parts(&storage)
	storage.facts[0].package_name = "modus:support/probe"
	expect_refusal(t, parts, .Not_A_Name, .Facts, 0)
}

@(test)
relocations_outside_writable_data_are_refused :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)

	// A slot that names no import, one past the imports, no export.
	storage.slots[0].import_index = 0
	expect_refusal(t, parts, .Slot_Not_Valid, .Slots, 0)
	storage.slots[0].import_index = u32(len(storage.imports)) + 1
	expect_refusal(t, parts, .Slot_Not_Valid, .Slots, 0)
	parts = test_parts(&storage)
	storage.slots[0].export_index = 0
	expect_refusal(t, parts, .Slot_Not_Valid, .Slots, 0)

	// A slot in the code, off 8 bytes, and across the end of its segment;
	// its last 8 bytes are taken.
	parts = test_parts(&storage)
	storage.slots[0].memory_offset = CODE_OFFSET
	expect_refusal(t, parts, .Slot_Not_Valid, .Slots, 0)
	storage.slots[0].memory_offset = AFTER_LOAD_OFFSET + 4
	expect_refusal(t, parts, .Slot_Not_Valid, .Slots, 0)
	storage.slots[0].memory_offset = MEMORY_SIZE - 4
	expect_refusal(t, parts, .Slot_Not_Valid, .Slots, 0)
	storage.slots[0].memory_offset = MEMORY_SIZE
	expect_refusal(t, parts, .Slot_Not_Valid, .Slots, 0)
	storage.slots[0].memory_offset = MEMORY_SIZE - 8
	file := write_to_memory(t, parts)
	delete(file)

	// Rebases: in the code, off 8 bytes, twice, out of order, and at the
	// largest offset.
	parts = test_parts(&storage)
	storage.rebases[0] = CODE_OFFSET
	expect_refusal(t, parts, .Rebase_Not_Valid, .Rebases, 0)
	storage.rebases[0] = AFTER_LOAD_OFFSET + 12
	expect_refusal(t, parts, .Rebase_Not_Valid, .Rebases, 0)
	storage.rebases[0] = max(u64) & ~u64(7)
	expect_refusal(t, parts, .Rebase_Not_Valid, .Rebases, 0)
	twice := [?]u64{AFTER_LOAD_OFFSET + 8, AFTER_LOAD_OFFSET + 8}
	parts.rebases = twice[:]
	expect_refusal(t, parts, .Rebase_Not_Valid, .Rebases, 1)
	out_of_order := [?]u64{AFTER_LOAD_OFFSET + 16, AFTER_LOAD_OFFSET + 8}
	parts.rebases = out_of_order[:]
	expect_refusal(t, parts, .Rebase_Not_Valid, .Rebases, 1)

	// The own-hash place: in the code, across the end of the data, and at
	// the last HASH_SIZE bytes of the data.
	parts = test_parts(&storage)
	parts.own_hash_place = CODE_OFFSET
	expect_refusal(t, parts, .Own_Hash_Place_Not_Writable, .Own_Hash, 0)
	parts.own_hash_place = MEMORY_SIZE - module.HASH_SIZE + 8
	expect_refusal(t, parts, .Own_Hash_Place_Not_Writable, .Own_Hash, 0)
	parts.own_hash_place = MEMORY_SIZE - module.HASH_SIZE
	file = write_to_memory(t, parts)
	delete(file)
}

@(test)
facts_that_a_reader_refuses_are_refused :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)

	// A module that writes facts and has no own-hash place.
	parts.has_own_hash_place = false
	expect_refusal(t, parts, .Facts_Without_Own_Hash_Place, .Facts, 0)

	// The key 0, no record, a record one past the last, no template.
	parts = test_parts(&storage)
	storage.facts[0].key = 0
	expect_refusal(t, parts, .Fact_Not_Valid, .Facts, 0)
	parts = test_parts(&storage)
	storage.facts[0].record_index = 0
	expect_refusal(t, parts, .Fact_Not_Valid, .Facts, 0)
	storage.facts[0].record_index = u32(len(storage.records)) + 1
	expect_refusal(t, parts, .Fact_Not_Valid, .Facts, 0)
	parts = test_parts(&storage)
	storage.facts[0].template = ""
	expect_refusal(t, parts, .Fact_Not_Valid, .Facts, 0)

	// Two facts with one key, and two out of order.
	parts = test_parts(&storage)
	two := [?]Fact_Part{storage.facts[0], storage.facts[0]}
	parts.facts = two[:]
	expect_refusal(t, parts, .Fact_Not_Valid, .Facts, 1)
	two[1].key = FACT_KEY - 1
	expect_refusal(t, parts, .Fact_Not_Valid, .Facts, 1)
	two[1].key = FACT_KEY + 1
	file := write_to_memory(t, parts)
	defer delete(file)
	testing.expect_value(t, module.count(file, .Facts), 3)
}

@(test)
tables_past_their_bound_are_refused :: proc(t: ^testing.T) {
	testing.expect(t, indexed_table_fits(0))
	testing.expect(t, indexed_table_fits(int(TABLE_RECORDS_MOST) - 1))
	testing.expect(t, !indexed_table_fits(int(TABLE_RECORDS_MOST)))
	testing.expect(t, !indexed_table_fits(-1))
	testing.expect(t, !indexed_table_fits(max(int)))

	// A list of exports one past the bound. The writer reads its count
	// before any export, so the list needs no memory past its first item.
	one := Export_Part{name = ENTRY_EXPORT_NAME}
	exports := ([^]Export_Part)(&one)[:int(TABLE_RECORDS_MOST)]
	expect_refusal(t, {exports = exports}, .Table_Past_Bound, .Exports, 0)
	slot: module.Slot
	expect_refusal(t, {slots = ([^]module.Slot)(&slot)[:int(TABLE_RECORDS_MOST)]}, .Table_Past_Bound, .Slots, 0)

	// The string table: its zero byte and a text of the rest of the bound,
	// then one byte more. The writer reads the length of a text, and no
	// byte of it, before it has the memory of the file.
	character := u8('a')
	at_the_bound := Module_Parts{text = strings.string_from_ptr(&character, int(TABLE_RECORDS_MOST) - 1)}
	size, refusal := file_size_needed(at_the_bound)
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect(t, size > TABLE_RECORDS_MOST, "the file holds the whole string table")
	past_the_bound := Module_Parts{text = strings.string_from_ptr(&character, int(TABLE_RECORDS_MOST))}
	_, refusal = file_size_needed(past_the_bound)
	testing.expect_value(t, refusal, Refusal_Record{refusal = .Table_Past_Bound, table = .Strings, value = TABLE_RECORDS_MOST + 1})
}

@(test)
a_record_that_a_reader_refuses_leaves_no_file :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)
	// An Integer of 8 bytes at an offset that is not a multiple of 8: the
	// parts are whole, and only the reader of the record refuses it.
	storage.rectangle_fields[1].offset = 4
	size, needed := file_size_needed(parts)
	testing.expect_value(t, needed.refusal, Refusal.None)
	output := make([]u8, int(size))
	defer delete(output)
	for &item in output {
		item = UNTOUCHED
	}
	written_size, written := write(parts, output)
	testing.expect_value(t, written, Refusal_Record{refusal = .Record_Not_Valid, table = .Records, index = 0})
	testing.expect_value(t, written_size, 0)
	for item in output {
		if item != 0 {
			testing.expect(t, false, "a refused file left its bytes")
			break
		}
	}
}

@(test)
an_output_too_small_is_not_changed :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)
	size, _ := file_size_needed(parts)
	output := make([]u8, int(size))
	defer delete(output)
	for &item in output {
		item = UNTOUCHED
	}
	// No memory, then one byte less than the file.
	for length in ([?]u64{0, size - 1}) {
		written_size, refusal := write(parts, output[:length])
		testing.expect_value(t, refusal, Refusal_Record{refusal = .Output_Too_Small, value = size})
		testing.expect_value(t, written_size, size)
	}
	for item in output {
		if item != UNTOUCHED {
			testing.expect(t, false, "a refused write changed its output")
			break
		}
	}
	// Memory larger than the file: the bytes after it stay.
	larger := make([]u8, int(size) + 1)
	defer delete(larger)
	larger[size] = UNTOUCHED
	written_size, refusal := write(parts, larger)
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, written_size, size)
	testing.expect_value(t, larger[size], UNTOUCHED)
}

@(test)
zero_exports_and_an_empty_string_table :: proc(t: ^testing.T) {
	// No part at all: a header, a directory and the empty records.
	file := write_to_memory(t, {})
	defer delete(file)
	testing.expect_value(t, module.validate(file), module.Error.None)
	head, _ := module.header(file)
	testing.expect_value(t, head.entry_export, 0)
	testing.expect_value(t, head.memory_size, 0)
	testing.expect_value(t, module.count(file, .Exports), 1)
	testing.expect_value(t, module.count(file, .Strings), 1)
	testing.expect_value(t, module.count(file, .Rebases), 0)
	testing.expect_value(t, module.count(file, .Facts), 0)
	testing.expect_value(t, module.count(file, .Own_Hash), 0)
	testing.expect_value(t, module.count(file, .Budget), 0)
	_, stated := module.budget_request(file)
	testing.expect(t, !stated)
}

@(test)
one_export_is_the_entry :: proc(t: ^testing.T) {
	code := [?]u8{0xC3}
	segments := [?]Segment_Part{{memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = code[:]}}
	exports := [?]Export_Part{{name = "start"}}
	parts := Module_Parts{segments = segments[:], exports = exports[:]}

	// An export with another name is no entry.
	file := write_to_memory(t, parts)
	head, _ := module.header(file)
	testing.expect_value(t, head.entry_export, 0)
	delete(file)

	exports[0].name = ENTRY_EXPORT_NAME
	file = write_to_memory(t, parts)
	defer delete(file)
	head, _ = module.header(file)
	testing.expect_value(t, head.entry_export, 1)
	address, ok := module.export_address(file, 0, head.entry_export)
	testing.expect(t, ok)
	testing.expect_value(t, address, 0)
}

// The rebase table that the writer writes must make module.rebase add the
// base to exactly the given locations, and the bitmap form is shorter than
// one word per location.
@(test)
rebases_round_trip :: proc(t: ^testing.T) {
	SIZE :: 3 * module.PAGE_SIZE
	offsets := [?]u64{0, 8, 16, 64, 504, 512, 520, 4096, 4104, 8184}
	segments := [?]Segment_Part{{memory_size = SIZE, flags = {.Read, .Write}}}
	file := write_to_memory(t, {segments = segments[:], rebases = offsets[:]})
	defer delete(file)

	testing.expect_value(t, module.validate(file), module.Error.None)
	memory := make([]u64, SIZE / 8)
	defer delete(memory)
	BASE :: 0x1000_0000
	testing.expect_value(t, module.rebase(file, ([^]u8)(raw_data(memory))[:SIZE], BASE), module.Error.None)
	for word, index in memory {
		expected: u64
		for offset in offsets {
			if offset == u64(index * 8) {
				expected = BASE
			}
		}
		testing.expect_value(t, word, expected)
	}
	testing.expect(t, int(module.count(file, .Rebases)) < len(offsets), "the bitmap form is shorter than one word per location")
}

// A segment that is read-only after the load and that no loader writes (no
// rebase and no slot in its pages) becomes a constant segment; with a
// rebase or with a slot it keeps its flags. A location at the first byte
// after the segment is not in it, and a segment of another kind never
// changes.
@(test)
a_segment_that_no_loader_writes_is_only_read :: proc(t: ^testing.T) {
	after_load := module.Segment_Flags{.Read, .Write, .Read_Only_After_Load}
	segment := module.Segment{memory_offset = 2 * module.PAGE_SIZE, memory_size = module.PAGE_SIZE, flags = after_load}
	outside := [?]u64{0, 2 * module.PAGE_SIZE - 8, 3 * module.PAGE_SIZE}
	slots_outside := [?]module.Slot{{memory_offset = 3 * module.PAGE_SIZE, import_index = 1, export_index = 1}}
	// No rebase and no slot at all, then some in the other segments only.
	testing.expect_value(t, segment_flags_after_the_relocations(segment, nil, nil), module.Segment_Flags{.Read})
	testing.expect_value(t, segment_flags_after_the_relocations(segment, outside[:], slots_outside[:]), module.Segment_Flags{.Read})
	// A rebase at its first word, and at its last word.
	first := [?]u64{2 * module.PAGE_SIZE}
	last := [?]u64{3 * module.PAGE_SIZE - 8}
	testing.expect_value(t, segment_flags_after_the_relocations(segment, first[:], nil), after_load)
	testing.expect_value(t, segment_flags_after_the_relocations(segment, last[:], nil), after_load)
	// A slot.
	slots_inside := [?]module.Slot{{memory_offset = 2 * module.PAGE_SIZE + 16, import_index = 1, export_index = 1}}
	testing.expect_value(t, segment_flags_after_the_relocations(segment, outside[:], slots_inside[:]), after_load)
	// The data and the code of a module keep their flags with no rebase.
	data := module.Segment{memory_offset = 2 * module.PAGE_SIZE, memory_size = module.PAGE_SIZE, flags = {.Read, .Write}}
	code := module.Segment{memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}}
	testing.expect_value(t, segment_flags_after_the_relocations(data, nil, nil), module.Segment_Flags{.Read, .Write})
	testing.expect_value(t, segment_flags_after_the_relocations(code, nil, nil), module.Segment_Flags{.Read, .Execute})
}

// The whole module: each table, read back by the readers of the contract.
@(test)
a_written_module_is_valid :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)
	file := write_to_memory(t, parts)
	defer delete(file)

	testing.expect_value(t, module.validate(file), module.Error.None)
	head, _ := module.header(file)
	testing.expect_value(t, head.entry_export, 1)
	testing.expect_value(t, head.memory_size, MEMORY_SIZE)

	// The segments: the constant one lost Write, the one with the slot and
	// the rebase kept it, and the zero bytes at the end are not stored.
	expected_flags := [?]module.Segment_Flags{{.Read, .Execute}, {.Read}, {.Read, .Write, .Read_Only_After_Load}, {.Read, .Write}}
	expected_sizes := [?]u64{2, 3, 0, 0}
	for index in 0 ..< len(expected_flags) {
		segment, _ := module.record(file, .Segments, u32(index + 1), module.Segment)
		testing.expect_value(t, segment.flags, expected_flags[index])
		testing.expect_value(t, segment.file_size, expected_sizes[index])
		testing.expect_value(t, segment.file_offset % module.PAGE_SIZE, 0)
	}
	code_segment, _ := module.record(file, .Segments, 1, module.Segment)
	testing.expect_value(t, file[code_segment.file_offset + 1], storage.code[1])

	// The import, the slot and the rebase.
	imported, _ := module.record(file, .Imports, 1, module.Import)
	testing.expect_value(t, imported.hash, storage.imports[0])
	slot, _ := module.record(file, .Slots, 1, module.Slot)
	testing.expect_value(t, slot, storage.slots[0])
	memory := make([]u8, MEMORY_SIZE)
	defer delete(memory)
	testing.expect_value(t, module.rebase(file, memory, module.PAGE_SIZE), module.Error.None)
	testing.expect_value(t, (^u64)(&memory[AFTER_LOAD_OFFSET + 8])^, u64(module.PAGE_SIZE))

	// The export and its description.
	function, has_function := module.function(file, 2)
	testing.expect(t, has_function)
	testing.expect_value(t, module.string_at(file, function.name_offset, function.name_count), "area")
	testing.expect_value(t, module.string_at(file, function.about_offset, function.about_count), storage.exports[1].about)
	testing.expect_value(t, module.string_at(file, function.text_offset, function.text_count), storage.exports[1].text)
	testing.expect_value(t, module.string_at(file, function.parameter_names[1], u32(function.parameter_name_counts[1])), "scale")
	testing.expect_value(t, function.parameters[0], u8(module.Type.Record))
	testing.expect_value(t, function.parameter_details[0], 1)
	testing.expect_value(t, function.error_record, 2)
	testing.expect_value(t, module.export_find(file, "area"), 2)
	address, _ := module.export_address(file, 0, 2)
	testing.expect_value(t, address, CODE_OFFSET + 1)

	// The records and the fact.
	rectangle, has_rectangle := module.record_type(file, 1)
	testing.expect(t, has_rectangle)
	testing.expect_value(t, module.string_at(file, rectangle.name_offset, rectangle.name_count), "Rectangle")
	height, _ := module.field(file, rectangle, 1)
	testing.expect_value(t, module.string_at(file, height.name_offset, height.name_count), "height")
	testing.expect_value(t, height.offset, 8)
	fact, _, has_fact := module.fact(file, 1)
	testing.expect(t, has_fact)
	testing.expect_value(t, fact.key, FACT_KEY)
	testing.expect_value(t, module.string_at(file, fact.template_offset, fact.template_count), storage.facts[0].template)
	testing.expect_value(t, module.string_at(file, fact.package_offset, fact.package_count), "probe")

	// The own-hash place, the budget and the documentation.
	place, present := module.own_hash_place(file)
	testing.expect(t, present)
	testing.expect_value(t, place, OWN_HASH_PLACE)
	budget, stated := module.budget_request(file)
	testing.expect(t, stated)
	testing.expect_value(t, budget, parts.budget)
	about, text := module.documentation(file)
	testing.expect_value(t, about, parts.about)
	testing.expect_value(t, text, parts.text)
}

// The places of the record streams of the tests: aligned words of the data
// segment, apart from the own-hash place.
@(private = "file")
OUTPUT_PLACE :: DATA_OFFSET + 128
@(private = "file")
INPUT_PLACE :: DATA_OFFSET + 132

// expect_refused_file checks a refusal of the last check: file_size_needed
// takes the parts, and write refuses them with the refusal, the table and
// the value, and leaves the bytes of the file at zero.
@(private = "file")
expect_refused_file :: proc(t: ^testing.T, parts: Module_Parts, refusal: Refusal, table: module.Table_Kind, value: u64, loc := #caller_location) {
	size, needed := file_size_needed(parts)
	testing.expect_value(t, needed.refusal, Refusal.None, loc)
	output := make([]u8, int(size))
	defer delete(output)
	for &item in output {
		item = UNTOUCHED
	}
	written_size, written := write(parts, output)
	testing.expect_value(t, written.refusal, refusal, loc)
	testing.expect_value(t, written.table, table, loc)
	testing.expect_value(t, written.value, value, loc)
	testing.expect_value(t, written_size, 0, loc)
	for item in output {
		if item != 0 {
			testing.expect(t, false, "a refused file kept a byte", loc = loc)
			break
		}
	}
}

// The record streams that a loader or a reader refuses are refused, each
// with its table and the index of its part: one past the bound in each
// table, a name that is not a name, a record or terms that name no record,
// and a place that is not aligned, in the code, in a segment that loses
// Write after the load, or past the memory.
@(test)
record_streams_that_a_reader_refuses_are_refused :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)
	too_many_outputs := make([]Record_Output_Part, module.RECORD_STREAM_INDEX_MOST + 1)
	defer delete(too_many_outputs)
	too_many_inputs := make([]Record_Input_Part, module.RECORD_STREAM_INDEX_MOST + 1)
	defer delete(too_many_inputs)
	{
		past := parts
		past.record_outputs = too_many_outputs
		expect_refusal(t, past, .Record_Streams_Past_Bound, .Record_Outputs, 0)
		past = parts
		past.record_inputs = too_many_inputs
		expect_refusal(t, past, .Record_Streams_Past_Bound, .Record_Inputs, 0)
	}
	outputs := [1]Record_Output_Part{{name = "sizes", record_index = 1, place = OUTPUT_PLACE}}
	inputs := [1]Record_Input_Part{{name = "orders", record_index = 1, place = INPUT_PLACE}}
	with_streams := parts
	with_streams.record_outputs = outputs[:]
	with_streams.record_inputs = inputs[:]

	outputs[0].name = "9sizes"
	expect_refusal(t, with_streams, .Not_A_Name, .Record_Outputs, 0)
	outputs[0].name = "sizes"
	inputs[0].name = ""
	expect_refusal(t, with_streams, .Not_A_Name, .Record_Inputs, 0)
	inputs[0].name = "orders"

	outputs[0].record_index = u32(len(parts.records)) + 1
	expect_refusal(t, with_streams, .Record_Stream_Without_Description, .Record_Outputs, 0)
	outputs[0].record_index = 1
	inputs[0].terms_index = u32(len(parts.records)) + 1
	expect_refusal(t, with_streams, .Record_Stream_Without_Description, .Record_Inputs, 0)
	inputs[0].terms_index = 0

	for place in ([?]u64{OUTPUT_PLACE + 2, CODE_OFFSET + 4, AFTER_LOAD_OFFSET + 16, MEMORY_SIZE, max(u64) - 3}) {
		outputs[0].place = place
		expect_refusal(t, with_streams, .Record_Stream_Place_Not_Writable, .Record_Outputs, 0)
	}
	outputs[0].place = OUTPUT_PLACE
	inputs[0].place = INPUT_PLACE + 1
	expect_refusal(t, with_streams, .Record_Stream_Place_Not_Writable, .Record_Inputs, 0)
}

// The rules of the whole tables and of the places, which the written file
// shows: names out of order, a name in both tables, a generic record output
// alone, a place over the own-hash place, two rows at one place. Each
// leaves no byte of the file.
@(test)
record_streams_that_the_written_file_breaks_are_refused :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)
	out_of_order := [2]Record_Output_Part{{name = "zeta", record_index = 1}, {name = "alpha", record_index = 1}}
	unordered := parts
	unordered.record_outputs = out_of_order[:]
	expect_refused_file(t, unordered, .Record_Streams_Not_Valid, .Record_Outputs, u64(module.Record_Stream_Fault.Outputs_Out_Of_Order))

	same_output := [1]Record_Output_Part{{name = "same", record_index = 1}}
	same_input := [1]Record_Input_Part{{name = "same", record_index = 1}}
	both := parts
	both.record_outputs, both.record_inputs = same_output[:], same_input[:]
	expect_refused_file(t, both, .Record_Streams_Not_Valid, .Record_Outputs, u64(module.Record_Stream_Fault.Name_Of_Both))

	generic := [1]Record_Output_Part{{name = "forward", record_index = 0, pairing = .Paired}}
	alone := parts
	alone.record_outputs = generic[:]
	expect_refused_file(t, alone, .Record_Streams_Not_Valid, .Record_Outputs, u64(module.Record_Stream_Fault.Generic_Output_Alone))

	over_hash := [1]Record_Output_Part{{name = "sizes", record_index = 1, place = OWN_HASH_PLACE}}
	on_hash := parts
	on_hash.record_outputs = over_hash[:]
	expect_refused_file(t, on_hash, .Written_File_Not_Valid, .None, u64(module.Error.Bad_Record_Stream_Place))

	shared_output := [1]Record_Output_Part{{name = "sizes", record_index = 1, place = OUTPUT_PLACE}}
	shared_input := [1]Record_Input_Part{{name = "orders", record_index = 1, place = OUTPUT_PLACE}}
	one_place := parts
	one_place.record_outputs, one_place.record_inputs = shared_output[:], shared_input[:]
	expect_refused_file(t, one_place, .Written_File_Not_Valid, .None, u64(module.Error.Bad_Record_Stream_Place))
}

// The record streams that a reader takes, last: the bound of each table
// with place 0 (the link kept no variable), and a record output and a
// record input with their places, read back by the readers of the
// contract, and their indexes written at their places by a loader.
@(test)
record_streams_are_written_and_read_back :: proc(t: ^testing.T) {
	storage: Test_Storage
	parts := test_parts(&storage)
	at_bound := make([]Record_Output_Part, module.RECORD_STREAM_INDEX_MOST)
	defer delete(at_bound)
	names := make([]string, module.RECORD_STREAM_INDEX_MOST)
	defer delete(names)
	for &item, index in at_bound {
		digits := [2]u8{'0' + u8(index / 10), '0' + u8(index % 10)}
		names[index] = strings.concatenate({"stream_", string(digits[:])}, context.temp_allocator)
		item = {name = names[index], record_index = 1}
	}
	full := parts
	full.record_outputs = at_bound
	full_file := write_to_memory(t, full)
	defer delete(full_file)
	testing.expect_value(t, module.count(full_file, .Record_Outputs), module.RECORD_STREAM_INDEX_MOST + 1)

	outputs := [1]Record_Output_Part{{name = "sizes", about = "The sizes of each rectangle.", text = "Each rectangle that the probe measured.", record_index = 1, place = OUTPUT_PLACE}}
	inputs := [1]Record_Input_Part{{name = "orders", about = "The rectangles to measure.", record_index = 1, terms_index = 2, wirings = .Many, place = INPUT_PLACE}}
	with_streams := parts
	with_streams.record_outputs = outputs[:]
	with_streams.record_inputs = inputs[:]
	file := write_to_memory(t, with_streams)
	defer delete(file)
	testing.expect_value(t, module.validate(file), module.Error.None)
	fault, row := module.record_streams_check(file)
	testing.expect_value(t, fault, module.Record_Stream_Fault.None)
	testing.expect_value(t, row, 0)

	output_row, pairing, _, output_ok := module.record_output(file, 1)
	testing.expect(t, output_ok)
	testing.expect_value(t, module.string_at(file, output_row.name_offset, output_row.name_count), "sizes")
	testing.expect_value(t, module.string_at(file, output_row.about_offset, output_row.about_count), outputs[0].about)
	testing.expect_value(t, module.string_at(file, output_row.text_offset, output_row.text_count), outputs[0].text)
	testing.expect_value(t, output_row.record, 1)
	testing.expect_value(t, pairing, module.Record_Output_Pairing.Unpaired)
	testing.expect_value(t, output_row.place, OUTPUT_PLACE)
	input_row, wirings, _, _, input_ok := module.record_input(file, 1)
	testing.expect(t, input_ok)
	testing.expect_value(t, module.string_at(file, input_row.name_offset, input_row.name_count), "orders")
	testing.expect_value(t, input_row.terms, 2)
	testing.expect_value(t, wirings, module.Wiring_Count.Many)
	testing.expect_value(t, input_row.place, INPUT_PLACE)

	memory := make([]u8, MEMORY_SIZE)
	defer delete(memory)
	testing.expect(t, module.record_stream_indexes_write(file, memory))
	testing.expect_value(t, (^u32)(&memory[OUTPUT_PLACE])^, 1)
	testing.expect_value(t, (^u32)(&memory[INPUT_PLACE])^, 1)
}
