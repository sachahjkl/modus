package build

import module "modus:contract/module"
import "modus:support/sentence"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The helpers that the host tests of the log facts of each module share
// (src/md/features/log_facts.md, "The facts of the root service" and the
// sections after it). A test reads the fact types with the extraction of
// the tool on the sources of a module, and makes a module file of their
// table: a host test does not depend on a build, or on the age of a module
// file that a build left. Each sentence is compared with the parts of the
// old line written by sentence.format, at the edges of each field.

// A value of one field of a fact for these tests: an integer (the bits of
// a signed one), a text of a name, or a whole hash.
@(private)
Fact_Test_Value :: union {
	u64,
	string,
	[module.HASH_SIZE]u8,
}

@(private)
Fact_Test_Field :: struct {
	name:  string,
	value: Fact_Test_Value,
}

// facts_file_of_folder gives a module file with the table Facts of the
// fact types that the calls in the sources of one folder write, made from
// the extraction of those sources: a host test does not depend on a build.
@(private)
facts_file_of_folder :: proc(t: ^testing.T, folder: string) -> (file: []u8, ok: bool) {
	paths, listed := foundation.files_with_suffix(folder, ".odin")
	if !testing.expectf(t, listed, "the sources of %s cannot be listed", folder) {
		return nil, false
	}
	sources := make([dynamic]Fact_Source, context.temp_allocator)
	for path in paths {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source, readable := foundation.read_file(path)
		if !testing.expectf(t, readable, "the source %s cannot be read", path) {
			return nil, false
		}
		append(&sources, Fact_Source{path = path, source = string(source)})
	}
	facts, extracted := facts_of_sources(sources[:])
	if !testing.expectf(t, extracted && len(facts) > 0, "the extraction gives no fact type of %s", folder) {
		return nil, false
	}
	description: Module_Description
	if !testing.expectf(t, facts_merge(&description, facts), "the fact types of %s do not merge", folder) {
		return nil, false
	}
	return facts_module_file(description), true
}

// facts_module_file writes the tables Records, Fields, Facts and Strings of
// a description, as the conversion writes them: the row 0 of each table is
// empty, and the facts are sorted by key (facts_merge).
@(private)
facts_module_file :: proc(description: Module_Description) -> []u8 {
	TABLES :: module.TABLE_COUNT
	file := make([dynamic]u8, size_of(module.Header) + TABLES * size_of(module.Table_Entry), context.temp_allocator)
	directory: [TABLES]module.Table_Entry
	strings_table := make([dynamic]u8, context.temp_allocator)
	append(&strings_table, 0)
	put :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
		offset = u32(len(table))
		append(table, text)
		return offset, u32(len(text))
	}
	records := make([dynamic]module.Record, context.temp_allocator)
	fields := make([dynamic]module.Field, context.temp_allocator)
	facts := make([dynamic]module.Fact, context.temp_allocator)
	append(&records, module.Record{})
	append(&fields, module.Field{})
	append(&facts, module.Fact{})
	for record in description.records {
		row := module.Record{size = record.size, first_field = u32(len(fields)), field_count = u32(len(record.fields))}
		row.name_offset, row.name_count = put(&strings_table, record.name)
		append(&records, row)
		for item in record.fields {
			field := module.Field{offset = item.offset, type = u8(item.type), unsigned = item.unsigned, integer_unit = item.integer_unit, detail = item.detail, kind = u8(item.kind), contract_enum = u8(item.contract_enum)}
			field.name_offset, field.name_count = put(&strings_table, item.name)
			append(&fields, field)
		}
	}
	for fact in description.facts {
		row := module.Fact{key = fact.key, record = fact.record_index}
		row.template_offset, row.template_count = put(&strings_table, fact.template)
		row.package_offset, row.package_count = put(&strings_table, fact.package_name)
		append(&facts, row)
	}
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, ([^]u8)(raw_data(records[:]))[:len(records) * size_of(module.Record)], u32(len(records)), size_of(module.Record))
	add(&file, &directory, .Fields, ([^]u8)(raw_data(fields[:]))[:len(fields) * size_of(module.Field)], u32(len(fields)), size_of(module.Field))
	add(&file, &directory, .Facts, ([^]u8)(raw_data(facts[:]))[:len(facts) * size_of(module.Fact)], u32(len(facts)), size_of(module.Fact))
	add(&file, &directory, .Strings, strings_table[:], u32(len(strings_table)), 1)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = TABLES}
	(^[TABLES]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

// fact_test_render gives the sentence of the fact type
// <package_name>.<type_name> with the values of its fields, by the one
// render of the contract. A field that the test names and the record does
// not have, a value of another form than its field, and a refused render
// fail the test.
@(private)
fact_test_render :: proc(t: ^testing.T, file: []u8, package_name, type_name: string, values: []Fact_Test_Field) -> string {
	key, bytes, made := fact_test_record(t, file, package_name, type_name, values)
	if !made {
		return ""
	}
	buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
	count, _, refusal := module.fact_sentence_write(file, key, bytes, buffer[:], nil)
	testing.expectf(t, refusal == .None, "the fact %s.%s is refused: %v", package_name, type_name, refusal)
	return strings.clone(string(buffer[:count]), context.temp_allocator)
}

// fact_test_record gives the key of the fact type <package_name>.<type_name>
// and the bytes of its record with the values of its fields, the other
// bytes zero. made is false, and the test fails, for a fact type that the
// file lacks and a field that its record lacks.
@(private)
fact_test_record :: proc(t: ^testing.T, file: []u8, package_name, type_name: string, values: []Fact_Test_Field) -> (key: u64, bytes: []u8, made: bool) {
	key = fact_key(package_name, type_name)
	_, _, description, found := module.fact_find(file, key)
	if !testing.expectf(t, found, "the module file has no fact type %s.%s", package_name, type_name) {
		return key, nil, false
	}
	bytes = make([]u8, description.size, context.temp_allocator)
	for value in values {
		item: module.Field
		has_field := false
		for number in 0 ..< description.field_count {
			candidate, candidate_ok := module.field(file, description, number)
			if candidate_ok && module.string_at(file, candidate.name_offset, candidate.name_count) == value.name {
				item, has_field = candidate, true
			}
		}
		if !testing.expectf(t, has_field, "the fact type %s has no field %s", type_name, value.name) {
			return key, nil, false
		}
		place := bytes[item.offset:][:module.field_size(item)]
		switch written in value.value {
		case u64:
			for index in 0 ..< len(place) {
				place[index] = u8(written >> (8 * u64(index)))
			}
		case string:
			testing.expectf(t, item.type == u8(module.Type.Text) && len(written) <= len(place), "the field %s of %s takes no text of %d bytes", value.name, type_name, len(written))
			copy(place, written)
		case [module.HASH_SIZE]u8:
			hash := written
			testing.expectf(t, len(place) == len(hash), "the field %s of %s takes no hash", value.name, type_name)
			copy(place, hash[:])
		}
	}
	return key, bytes, true
}

// line_of_before gives the line that the writer wrote before the fact, with the
// parts of its call of system.log.
@(private)
line_of_before :: proc(parts: ..sentence.Part) -> string {
	buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
	return strings.clone(sentence.format(buffer[:], ..parts), context.temp_allocator)
}

@(private)
facts_expect_line :: proc(t: ^testing.T, written, old: string, loc := #caller_location) {
	testing.expectf(t, written == old, "the fact writes %q, the line of before was %q", written, old, loc = loc)
}

// The bits of a signed value in a field of these tests.
@(private)
signed_bits :: proc(value: i64) -> u64 {
	return u64(value)
}

// facts_expect_text_fields_last checks that each fact type of a file that
// has a Text field ends with its Text fields, and that each Text field
// ends with a zero byte that no value of the writer takes: the serial line
// of a fact stops at its last byte that is not zero, so the zeros after a
// short text cost no byte, and no text is cut. text_bytes_most gives, for
// the name of each Text field, the most bytes of the text that its writer
// puts there; a Text field that it does not name fails the test.
@(private)
facts_expect_text_fields_last :: proc(t: ^testing.T, file: []u8, text_bytes_most: map[string]u32) {
	rows := module.count(file, .Facts)
	testing.expect(t, rows > 1)
	for row_index in 1 ..< rows {
		_, description, row_ok := module.fact(file, row_index)
		if !testing.expect(t, row_ok) {
			continue
		}
		type_name := module.string_at(file, description.name_offset, description.name_count)
		first_text_offset := description.size
		last_other_end: u32 = 0
		for number in 0 ..< description.field_count {
			item, item_ok := module.field(file, description, number)
			if !testing.expect(t, item_ok) {
				continue
			}
			if item.type != u8(module.Type.Text) {
				last_other_end = max(last_other_end, item.offset + module.field_size(item))
				continue
			}
			first_text_offset = min(first_text_offset, item.offset)
			name := module.string_at(file, item.name_offset, item.name_count)
			most, known := text_bytes_most[name]
			if !testing.expectf(t, known, "the Text field %s of %s is no text that this test knows", name, type_name) {
				continue
			}
			testing.expectf(t, module.field_size(item) > most, "the field %s of %s has %d bytes: no zero byte after a text of %d bytes", name, type_name, module.field_size(item), most)
		}
		testing.expectf(t, last_other_end <= first_text_offset, "the fact type %s has a field after a Text field", type_name)
	}
}
