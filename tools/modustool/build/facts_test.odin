package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "core:fmt"
import "core:strings"
import "core:testing"

// The folder of the sources of these tests: a module of the group tests.
@(private = "file")
FACT_TEST_FOLDER :: "src/modules/tests/fact_probe"
// A support package that declares a fact type, for a call through an import.
@(private = "file")
FACT_TEST_SUPPORT_FOLDER :: "src/library/support/fact_sample"

// fact_test_source gives a source of the module of these tests: the
// package, the import of system, then the declarations and the body of a
// procedure that writes.
@(private = "file")
fact_test_source :: proc(declarations, body: string) -> Fact_Source {
	text := fmt.tprintf("package fact_probe\n\nimport \"modus:support/system\"\nimport \"modus:support/fact_sample\"\n\n%s\n\nwrite :: proc() {{\n%s\n}}\n", declarations, body)
	return {path = FACT_TEST_FOLDER + "/main.odin", source = text}
}

// The support package of these tests, with one fact type.
@(private = "file")
FACT_TEST_SUPPORT_SOURCE :: `package fact_sample

@(log_fact = "sample: the place {place}")
Sample :: struct {
	place: u64,
}
`

// The record type that each refused source below changes, written whole.
@(private = "file")
FACT_TEST_GOOD_TYPE :: `@(log_fact = "probe: the block {block} has the check {check} and the other {other}")
Probe :: struct {
	block: u64,
	check: u32,
	other: u32,
}`

// Each source that the extraction must refuse, with what it breaks: the
// form of the call, the declaration of the type, the record and the
// template. For each, the extraction gives no fact.
@(test)
a_fact_type_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name:         string,
		declarations: string,
		body:         string,
	}
	good_body :: "system.log_fact(.Info, Probe{block = 1, check = 2, other = 3})"
	cases := [?]Case {
		{"a value from a variable", FACT_TEST_GOOD_TYPE, "probe := Probe{}\nsystem.log_fact(.Info, probe)"},
		{"a literal with no type", FACT_TEST_GOOD_TYPE, "system.log_fact(.Info, {block = 1})"},
		{"one argument", FACT_TEST_GOOD_TYPE, "system.log_fact(Probe{})"},
		{"three arguments", FACT_TEST_GOOD_TYPE, "system.log_fact(.Info, Probe{}, 3)"},
		{"a type with no attribute", "Probe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{block = 1})"},
		{"a type that the package does not declare", FACT_TEST_GOOD_TYPE, "system.log_fact(.Info, Missing{})"},
		{"the attribute on a constant", "@(log_fact = \"a {block}\")\nCOUNT :: 3", ""},
		{"the attribute on a variable", "@(log_fact = \"a\")\ncount: u64", ""},
		{"the attribute on a procedure", "@(log_fact = \"a\")\nhelper :: proc() {}", ""},
		{"the attribute inside a procedure", "", "@(log_fact = \"a {block}\")\nLocal :: struct {\n\tblock: u64,\n}\nsystem.log_fact(.Info, Local{block = 1})"},
		{"a type private to its file", "@(private = \"file\", log_fact = \"a {block}\")\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{block = 1})"},
		{"a template that is a constant", "TEMPLATE :: \"a {block}\"\n@(log_fact = TEMPLATE)\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{block = 1})"},
		{"a template that is a number", "@(log_fact = 3)\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{block = 1})"},
		{"padding before a field", "@(log_fact = \"{small} {large}\")\nProbe :: struct {\n\tsmall: u8,\n\tlarge: u64,\n}", "system.log_fact(.Info, Probe{small = 1, large = 2})"},
		{"padding after the last field", "@(log_fact = \"{large} {small}\")\nProbe :: struct {\n\tlarge: u64,\n\tsmall: u8,\n}", "system.log_fact(.Info, Probe{small = 1, large = 2})"},
		{"a Handle field", "@(log_fact = \"{lent} {other}\")\nProbe :: struct {\n\tlent: system.Lent({.Read}),\n\tother: u32,\n}", "system.log_fact(.Info, Probe{other = 1})"},
		{"values one byte past one record", fmt.tprintf("@(log_fact = \"{{text}}\")\nProbe :: struct {{\n\ttext: [%d]u8,\n}}", op.LOG_FACT_VALUE_CAPACITY + 1), "system.log_fact(.Info, Probe{})"},
		{"a field that the template does not name", "@(log_fact = \"{block}\")\nProbe :: struct {\n\tblock: u64,\n\tcheck: u64,\n}", "system.log_fact(.Info, Probe{})"},
		{"a name that names no field", "@(log_fact = \"{block} {blocks}\")\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{})"},
		{"a format in braces", "@(log_fact = \"{block:08x}\")\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{})"},
		{"a field named two times", "@(log_fact = \"{block} {block}\")\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{})"},
		{"an unclosed brace", "@(log_fact = \"{block\")\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{})"},
		{"a control character", "@(log_fact = \"{block}\\n\")\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe{})"},
	}
	support := Fact_Source{path = FACT_TEST_SUPPORT_FOLDER + "/sample.odin", source = FACT_TEST_SUPPORT_SOURCE}
	for item in cases {
		sources := [2]Fact_Source{fact_test_source(item.declarations, item.body), support}
		facts, ok := facts_of_sources(sources[:])
		testing.expectf(t, !ok && len(facts) == 0, "the extraction takes %s", item.name)
	}
	// The edge that is taken: the values of one record exactly.
	whole_type := fmt.tprintf("@(log_fact = \"{{text}}\")\nProbe :: struct {{\n\ttext: [%d]u8,\n}}", op.LOG_FACT_VALUE_CAPACITY)
	whole_sources := [2]Fact_Source{fact_test_source(whole_type, "system.log_fact(.Info, Probe{})"), support}
	whole, whole_ok := facts_of_sources(whole_sources[:])
	testing.expect(t, whole_ok && len(whole) == 1 && whole[0].record.size == op.LOG_FACT_VALUE_CAPACITY)
	// A call of another procedure named log_fact, not of system, is no fact.
	other_sources := [2]Fact_Source{fact_test_source("log_fact :: proc(a, b: int) {}", "log_fact(1, 2)"), support}
	other, other_ok := facts_of_sources(other_sources[:])
	testing.expect(t, other_ok && len(other) == 0)
}

// The fact types of a module: one fact for each type, whatever the count
// of its calls; a type of this package and a type of a support package
// through its import; the key of each is the typeid that the tool computes,
// with the package name of its declaration.
@(test)
the_fact_types_of_a_module_come_from_their_calls :: proc(t: ^testing.T) {
	body := "system.log_fact(.Info, Probe{block = 1, check = 2, other = 3})\nsystem.log_fact(.Warning, Probe{block = 4})\nsystem.log_fact(.Info, fact_sample.Sample{place = 5})"
	sources := [2]Fact_Source{fact_test_source(FACT_TEST_GOOD_TYPE, body), {path = FACT_TEST_SUPPORT_FOLDER + "/sample.odin", source = FACT_TEST_SUPPORT_SOURCE}}
	facts, ok := facts_of_sources(sources[:])
	testing.expect(t, ok && len(facts) == 2)
	if len(facts) != 2 {
		return
	}
	probe, sample := facts[0], facts[1]
	testing.expect_value(t, probe.key, fact_key("fact_probe", "Probe"))
	testing.expect_value(t, probe.template, "probe: the block {block} has the check {check} and the other {other}")
	testing.expect(t, probe.package_name == "fact_probe" && probe.type_name == "Probe" && probe.record.size == 16 && len(probe.record.fields) == 3)
	testing.expect_value(t, sample.key, fact_key("fact_sample", "Sample"))
	testing.expect(t, sample.package_name == "fact_sample" && sample.template == "sample: the place {place}")
}

// facts_merge refuses a key of 0, two fact types with one key, and a record
// of a fact whose name the module describes another way. It shares the
// record of an equal description, and sorts the facts by key.
@(test)
facts_merge_refuses_a_collision :: proc(t: ^testing.T) {
	record := Record_Description{name = "Probe", size = 8, fields = []Field_Description{{name = "block", type = .Integer, unsigned = true}}}
	other_record := Record_Description{name = "Probe", size = 8, fields = []Field_Description{{name = "place", type = .Integer, unsigned = true}}}
	first := Fact_Description{key = 2, package_name = "a", type_name = "Probe", record = record}
	second := Fact_Description{key = 1, package_name = "b", type_name = "Other", record = record}
	Case :: struct {
		name:    string,
		records: []Record_Description,
		facts:   []Fact_Description,
	}
	zero_key := first
	zero_key.key = 0
	same_key := second
	same_key.key = first.key
	other_layout := second
	other_layout.record = other_record
	cases := [?]Case {
		{"the key 0", nil, {zero_key}},
		{"two types with one key", nil, {first, same_key}},
		{"a record of another layout than the record of an export", {record}, {other_layout}},
		{"two facts whose records have one name and two layouts", nil, {first, other_layout}},
	}
	for item in cases {
		description := Module_Description{records = item.records}
		testing.expectf(t, !facts_merge(&description, item.facts), "facts_merge takes %s", item.name)
		testing.expectf(t, len(description.facts) == 0 && len(description.records) == len(item.records), "facts_merge with %s changed the description", item.name)
	}
	description := Module_Description{records = {record}}
	testing.expect(t, facts_merge(&description, {first, second}))
	testing.expect(t, len(description.records) == 1 && len(description.facts) == 2)
	testing.expect(t, description.facts[0].key == 1 && description.facts[1].key == 2)
	testing.expect(t, description.facts[0].record_index == 1 && description.facts[1].record_index == 1)
}

// The check of the keys in the LLVM IR: the key as a signed operand of 64
// bits, with no digit after it. A key past 2^63 is negative in the IR. A
// number that only starts with the key, a key with no "i64 " before it,
// and an IR with no key are refused.
@(test)
the_fact_keys_are_in_the_llvm_ir :: proc(t: ^testing.T) {
	key := fact_key("storage", "Bad_Block")
	testing.expect(t, key > u64(max(i64)))
	held := fmt.tprintf("  store i64 %d, ptr %%fact.key, align 8\n", i64(key))
	testing.expect(t, llvm_ir_holds_integer(held, key))
	testing.expect(t, llvm_ir_holds_integer(fmt.tprintf("i64 %d", i64(key)), key))
	testing.expect(t, !llvm_ir_holds_integer(fmt.tprintf("store i64 %d7, ptr %%x", i64(key)), key))
	testing.expect(t, !llvm_ir_holds_integer(fmt.tprintf("store i32 %d, ptr %%x", i64(key)), key))
	testing.expect(t, !llvm_ir_holds_integer(fmt.tprintf("store i64 %d, ptr %%x", key), key))
	testing.expect(t, !llvm_ir_holds_integer("", key))
	// A first place with a digit after it, then the key: found.
	testing.expect(t, llvm_ir_holds_integer(fmt.tprintf("i64 %d0 i64 %d\n", i64(key), i64(key)), key))
	fact := Fact_Description{key = key, package_name = "storage", type_name = "Bad_Block"}
	testing.expect(t, facts_ir_problem("define void @f() {\n}\n", {fact}) != "")
	testing.expect_value(t, facts_ir_problem(held, {fact}), "")
	testing.expect_value(t, facts_ir_problem("", nil), "")
}

// A module file of one fact type, with its record, its template and its
// package name, for the render: the record "Probe" with an unsigned
// Integer "value" of 8 bytes and a hexadecimal "mark" of 4 bytes and a
// "number" of 4 bytes.
@(private = "file")
fact_render_file :: proc(template: string) -> []u8 {
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

@(private = "file")
FACT_RENDER_KEY :: u64(0xfa0a_df38_a559_f4d1)

// fact_render_line gives the line of a fact as the kernel writes it.
@(private = "file")
fact_render_line :: proc(hash: [module.HASH_SIZE]u8, key: u64, values: []u8) -> string {
	fact := op.Log_Fact{module_hash = hash, key = key, value_count = u16(len(values))}
	copy(fact.values[:], values)
	line: [op.LOG_FACT_LINE_BYTES_MOST]u8
	count := op.log_fact_line(&fact, &line)
	return strings.clone(string(line[:count]), context.temp_allocator)
}

// The render of the line of a fact: the template with each value by the
// kind of its field. A line stays raw when it is not the line of a fact
// (each break of its form), when no module of the catalog has its hash,
// when its module has no fact of its key, and when it has more value bytes
// than the record. The catalog refuses two modules whose hashes share
// their first 8 bytes. The render of a whole log changes the lines of the
// facts only.
@(test)
the_line_of_a_fact_is_rendered_on_the_host :: proc(t: ^testing.T) {
	file := fact_render_file("probe: the value {value}, the mark {mark} and the number {number}; {{braces}}")
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(index + 1)
	}
	catalog := Fact_Catalog{allocator = context.temp_allocator}
	testing.expect_value(t, fact_catalog_add(&catalog, hash, "", file), "")
	values := [16]u8{42, 0, 0, 0, 0, 0, 0, 0, 0x46, 0x47, 0x4f, 0x4c, 7, 0, 0, 0}
	line := fact_render_line(hash, FACT_RENDER_KEY, values[:])

	// Lines that are not the line of a fact.
	for text in ([?]string{"", "#", "a log line", strings.to_upper(line, context.temp_allocator), line[1:], strings.concatenate({line, "0"}, context.temp_allocator), strings.concatenate({line[:len("#0102030405060708:fa0adf38a559f4d1")], " "}, context.temp_allocator)}) {
		_, parsed := fact_line_parse(text)
		testing.expectf(t, !parsed, "the text %q is read as a fact", text)
	}
	too_many := strings.concatenate({line[:len("#0102030405060708:fa0adf38a559f4d1")], " ", strings.repeat("ab", op.LOG_FACT_VALUE_CAPACITY + 1, context.temp_allocator)}, context.temp_allocator)
	_, too_many_parsed := fact_line_parse(too_many)
	testing.expect(t, !too_many_parsed)

	// Lines that stay raw: another module, another key, more values than
	// the record.
	other_hash := hash
	other_hash[0] = 0xFF
	long_values: [17]u8
	long_values[16] = 1
	for text in ([3]string{fact_render_line(other_hash, FACT_RENDER_KEY, values[:]), fact_render_line(hash, FACT_RENDER_KEY + 1, values[:]), fact_render_line(hash, FACT_RENDER_KEY, long_values[:])}) {
		_, rendered := fact_line_render(&catalog, text)
		testing.expectf(t, !rendered, "the line %s is rendered", text)
	}
	// A second module whose hash starts with the same 8 bytes is refused.
	twin := hash
	twin[module.HASH_SIZE - 1] = 0xFF
	testing.expect(t, fact_catalog_add(&catalog, twin, "", file) != "")
	testing.expect_value(t, len(catalog.modules), 1)

	sentence, rendered := fact_line_render(&catalog, line)
	testing.expect(t, rendered)
	testing.expect_value(t, sentence, "probe: the value 42, the mark 0x4c4f4746 and the number 7; {braces}")
	// The values of zero bytes after the last one that is not zero: the
	// line holds none of them, and the render reads them as zero.
	zero_line := fact_render_line(hash, FACT_RENDER_KEY, nil)
	zero_sentence, zero_rendered := fact_line_render(&catalog, zero_line)
	testing.expect(t, zero_rendered && zero_sentence == "probe: the value 0, the mark 0x00000000 and the number 0; {braces}")

	log := strings.concatenate({"[root] root: a text\r\n[log_reader] ", line, "\r\n[x] #not a fact\r\n"}, context.temp_allocator)
	testing.expect_value(t, fact_lines_render(&catalog, log), "[root] root: a text\r\n[log_reader] probe: the value 42, the mark 0x4c4f4746 and the number 7; {braces}\r\n[x] #not a fact\r\n")
	testing.expect_value(t, fact_lines_render(&catalog, "[root] root: a text\r\n"), "[root] root: a text\r\n")
}
