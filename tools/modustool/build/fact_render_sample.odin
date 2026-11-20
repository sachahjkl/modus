package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "core:strings"

// The sample of a module file and of a fact line, for the host tests of
// the render (facts_test.odin, fact_step_test.odin) and of the reader of
// the log of a machine (tools/modustool/machine). A test of another package
// cannot read a procedure of a test file of this one, so the sample lives
// here.

// fact_render_file gives a module file of one fact type, with its record,
// its template and its package name "probe": the record "Probe" with an
// unsigned Integer "value" of 8 bytes, a hexadecimal "mark" of 4 bytes and
// a "number" of 4 bytes, or the Text "note" of 4 bytes in place of
// "number".
fact_render_file :: proc(template: string, last_is_text := false) -> []u8 {
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
	name_offset, name_count := put(&strings_table, "Probe")
	records := [2]module.Record{{}, {name_offset = name_offset, name_count = name_count, size = 16, first_field = 1, field_count = 3}}
	fields: [4]module.Field
	fields[1].name_offset, fields[1].name_count = put(&strings_table, "value")
	fields[1].type, fields[1].unsigned = u8(module.Type.Integer), true
	fields[2].name_offset, fields[2].name_count = put(&strings_table, "mark")
	fields[2].type, fields[2].unsigned, fields[2].offset, fields[2].detail = u8(module.Type.Integer), true, 8, 4
	fields[2].kind = u8(value_kinds.Field_Kind.Hexadecimal)
	fields[3].name_offset, fields[3].name_count = put(&strings_table, "number")
	fields[3].type, fields[3].unsigned, fields[3].offset, fields[3].detail = u8(module.Type.Integer), true, 12, 4
	if last_is_text {
		fields[3].name_offset, fields[3].name_count = put(&strings_table, "note")
		fields[3].type, fields[3].unsigned = u8(module.Type.Text), false
	}
	facts: [2]module.Fact
	facts[1] = {key = FACT_RENDER_KEY, record = 1}
	facts[1].template_offset, facts[1].template_count = put(&strings_table, template)
	facts[1].package_offset, facts[1].package_count = put(&strings_table, "probe")
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, ([^]u8)(&records)[:size_of(records)], len(records), size_of(module.Record))
	add(&file, &directory, .Fields, ([^]u8)(&fields)[:size_of(fields)], len(fields), size_of(module.Field))
	add(&file, &directory, .Facts, ([^]u8)(&facts)[:size_of(facts)], len(facts), size_of(module.Fact))
	add(&file, &directory, .Strings, strings_table[:], u32(len(strings_table)), 1)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = TABLES}
	(^[TABLES]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

// The key of the fact type of fact_render_file.
FACT_RENDER_KEY :: u64(0xfa0a_df38_a559_f4d1)

// fact_render_line gives the line of a fact as the kernel writes it.
fact_render_line :: proc(hash: [module.HASH_SIZE]u8, key: u64, values: []u8) -> string {
	fact := op.Log_Fact{module_hash = hash, key = key, value_count = u16(len(values))}
	copy(fact.values[:], values)
	line: [op.LOG_FACT_LINE_BYTES_MOST]u8
	count := op.log_fact_line(&fact, &line)
	return strings.clone(string(line[:count]), context.temp_allocator)
}
