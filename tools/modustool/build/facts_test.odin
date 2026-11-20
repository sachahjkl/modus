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

// facts_merge refuses a key of 0, two fact types with one key, two fact
// types with one key tag (the high bytes that the serial line writes: the
// lowest and the highest key of one tag), and a record of a fact whose name
// the module describes another way. It shares the record of an equal
// description, and sorts the facts by key. Two keys of adjacent tags, the
// highest key of one and the lowest of the next, are two fact types.
@(test)
facts_merge_refuses_a_collision :: proc(t: ^testing.T) {
	// The least step of a fact key that changes its key tag.
	TAG_STEP :: u64(1) << (64 - 8 * op.LOG_FACT_LINE_KEY_BYTES)
	record := Record_Description{name = "Probe", size = 8, fields = []Field_Description{{name = "block", type = .Integer, unsigned = true}}}
	other_record := Record_Description{name = "Probe", size = 8, fields = []Field_Description{{name = "place", type = .Integer, unsigned = true}}}
	first := Fact_Description{key = 2 * TAG_STEP, package_name = "a", type_name = "Probe", record = record}
	second := Fact_Description{key = 2 * TAG_STEP - 1, package_name = "b", type_name = "Other", record = record}
	same_tag := second
	same_tag.key = 3 * TAG_STEP - 1
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
		{"two types with one key tag", nil, {first, same_tag}},
		{"two types with one key tag, the other first", nil, {same_tag, first}},
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
	testing.expect(t, description.facts[0].key == 2 * TAG_STEP - 1 && description.facts[1].key == 2 * TAG_STEP)
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

// The fact types that a compile reached: a fact type of a support package
// whose key the IR lacks has no row, and the IR holds no failure for it; a
// fact type of the package of the module whose key the IR lacks fails, also
// with a slash after the folder of the module, and also when another fact
// type is reached; an IR with every key keeps each fact type, in order.
@(test)
the_fact_types_of_a_module_are_those_that_its_code_reaches :: proc(t: ^testing.T) {
	own := Fact_Description{key = fact_key("fact_probe", "Probe"), package_name = "fact_probe", type_name = "Probe", file = FACT_TEST_FOLDER + "/main.odin"}
	support := Fact_Description{key = fact_key("fact_sample", "Sample"), package_name = "fact_sample", type_name = "Sample", file = FACT_TEST_SUPPORT_FOLDER + "/sample.odin"}
	ir_of :: proc(keys: ..u64) -> string {
		text := strings.builder_make(context.temp_allocator)
		for key in keys {
			fmt.sbprintfln(&text, "  store i64 %d, ptr %%fact.key, align 8", i64(key))
		}
		return strings.to_string(text)
	}
	// The own fact type is missing: a failure, with no list.
	missing, missing_problem := facts_reached(ir_of(support.key), {own, support}, FACT_TEST_FOLDER)
	testing.expect(t, missing_problem != "" && len(missing) == 0)
	_, slash_problem := facts_reached(ir_of(support.key), {own, support}, FACT_TEST_FOLDER + "/")
	testing.expect(t, slash_problem != "")
	_, empty_problem := facts_reached("", {own}, FACT_TEST_FOLDER)
	testing.expect(t, empty_problem != "")
	// The fact type of a support package is missing: no row, no failure.
	without_support, support_problem := facts_reached(ir_of(own.key), {own, support}, FACT_TEST_FOLDER)
	testing.expect_value(t, support_problem, "")
	testing.expect(t, len(without_support) == 1 && without_support[0].key == own.key)
	none, none_problem := facts_reached("", {support}, FACT_TEST_FOLDER)
	testing.expect(t, none_problem == "" && len(none) == 0)
	// A module with no fact type at all.
	nothing, nothing_problem := facts_reached("", nil, FACT_TEST_FOLDER)
	testing.expect(t, nothing_problem == "" && len(nothing) == 0)
	// Each key in the IR: each fact type, in its order.
	both, both_problem := facts_reached(ir_of(support.key, own.key), {own, support}, FACT_TEST_FOLDER)
	testing.expect_value(t, both_problem, "")
	testing.expect(t, len(both) == 2 && both[0].key == own.key && both[1].key == support.key)
}

// A module file of one fact type, with its record, its template and its
// package name, for the render: the record "Probe" with an unsigned
// Integer "value" of 8 bytes and a hexadecimal "mark" of 4 bytes and a
// "number" of 4 bytes. The tests of the step of a fact read it too
// (fact_step_test.odin).
@(private)
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
		// The last field is a Text of 4 bytes, "note", in place of "number".
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

@(private)
FACT_RENDER_KEY :: u64(0xfa0a_df38_a559_f4d1)

// fact_render_line gives the line of a fact as the kernel writes it.
@(private)
fact_render_line :: proc(hash: [module.HASH_SIZE]u8, key: u64, values: []u8) -> string {
	fact := op.Log_Fact{module_hash = hash, key = key, value_count = u16(len(values))}
	copy(fact.values[:], values)
	line: [op.LOG_FACT_LINE_BYTES_MOST]u8
	count := op.log_fact_line(&fact, &line)
	return strings.clone(string(line[:count]), context.temp_allocator)
}

// The render of the line of a fact: the template with each value by the
// kind of its field. A line stays raw when it is not the line of a fact
// (each break of its form, and each text that op.log_fact_line never
// writes), when no module of the catalog has its module tag, when its
// module has no fact of its key tag, and when it has more value bytes than
// the record. The catalog refuses two modules whose hashes share their
// module tag. The render of a whole log changes the lines of the facts
// only.
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
	// 42, a run of 7 zero bytes, the mark, then the number.
	testing.expect_value(t, line, "#01020304:fa0adf 2am46474f4c07")
	HEAD :: "#01020304:fa0adf"

	// Lines that are not the line of a fact, and texts that the kernel
	// never writes: a zero byte as digits, a run at the end, a short run
	// before another run, an odd digit, a letter past the runs.
	not_facts := [?]string {
		"",
		"#",
		"a log line",
		strings.to_upper(line, context.temp_allocator),
		line[1:],
		strings.concatenate({line, "0"}, context.temp_allocator),
		HEAD + " ",
		HEAD + "  2a",
		HEAD + " 2a00",
		HEAD + " 002a",
		HEAD + " 2ag",
		HEAD + " g",
		HEAD + " gg2a",
		HEAD + " yg2a",
		HEAD + " 2",
		HEAD + " 2a0",
		HEAD + " 2a{",
		HEAD + " 2aA0",
		HEAD + " 2az",
		HEAD + " 2azz",
		HEAD + " 2a  ",
		HEAD + " 2a\r",
		HEAD + " 2a\r\n",
		"#0102030:fa0adf 2a",
		"#01020304:fa0ad 2a",
		"#01020304fa0adf0 2a",
	}
	for text in not_facts {
		_, parsed := fact_line_parse(text)
		testing.expectf(t, !parsed, "the text %q is read as a fact", text)
	}
	// The capacity: 144 bytes by digits or by runs is a fact; one more
	// byte, by a digit or by a run, is not.
	full_digits := strings.concatenate({HEAD, " ", strings.repeat("ab", op.LOG_FACT_VALUE_CAPACITY, context.temp_allocator)}, context.temp_allocator)
	full, full_parsed := fact_line_parse(full_digits)
	testing.expect(t, full_parsed && full.value_count == op.LOG_FACT_VALUE_CAPACITY)
	too_many := strings.concatenate({HEAD, " ", strings.repeat("ab", op.LOG_FACT_VALUE_CAPACITY + 1, context.temp_allocator)}, context.temp_allocator)
	_, too_many_parsed := fact_line_parse(too_many)
	testing.expect(t, !too_many_parsed)
	// 143 zero bytes: 7 letters of 20 and one of 3, then one byte.
	full_runs, full_runs_parsed := fact_line_parse(HEAD + " zzzzzzzi7f")
	testing.expect(t, full_runs_parsed && full_runs.value_count == op.LOG_FACT_VALUE_CAPACITY && full_runs.values[op.LOG_FACT_VALUE_CAPACITY - 1] == 0x7f && full_runs.values[0] == 0)
	_, past_runs_parsed := fact_line_parse(HEAD + " zzzzzzzj7f")
	testing.expect(t, !past_runs_parsed)
	// Runs of two letters between two bytes: "zz" is 40 zero bytes, "zzg"
	// 41, and the line of the kernel for each is that text.
	Run_Read :: struct {
		text:  string,
		zeros: int,
	}
	for item in ([?]Run_Read{{HEAD + " 01z02", 20}, {HEAD + " 01zz02", 40}, {HEAD + " 01zzg02", 41}}) {
		read, read_ok := fact_line_parse(item.text)
		expected: [op.LOG_FACT_VALUE_CAPACITY]u8
		expected[0], expected[item.zeros + 1] = 0x01, 0x02
		testing.expectf(t, read_ok && read.value_count == item.zeros + 2 && read.values == expected, "%q does not read back as %d zero bytes between two bytes", item.text, item.zeros)
		testing.expect_value(t, fact_render_line(hash, FACT_RENDER_KEY, expected[:item.zeros + 2]), item.text)
	}

	// Each line that the kernel writes reads back to its bytes: each byte
	// value alone and after each run, and a Text field of its whole size.
	for byte_value in 1 ..= 255 {
		for zeros in ([?]int{0, 1, op.LOG_FACT_LINE_ZERO_RUN_MOST, op.LOG_FACT_LINE_ZERO_RUN_MOST + 1}) {
			bytes: [op.LOG_FACT_VALUE_CAPACITY]u8
			bytes[zeros] = u8(byte_value)
			read, read_ok := fact_line_parse(fact_render_line(hash, FACT_RENDER_KEY, bytes[:zeros + 1]))
			testing.expectf(t, read_ok && read.value_count == zeros + 1 && read.values == bytes && read.key_tag == op.log_fact_key_tag(FACT_RENDER_KEY), "the byte %d after %d zero bytes reads back wrong", byte_value, zeros)
		}
	}
	text_field: [op.LOG_FACT_VALUE_CAPACITY]u8
	for &value, index in text_field {
		value = 'a' + u8(index % 26)
	}
	whole_text, whole_text_ok := fact_line_parse(fact_render_line(hash, FACT_RENDER_KEY, text_field[:]))
	testing.expect(t, whole_text_ok && whole_text.value_count == op.LOG_FACT_VALUE_CAPACITY && whole_text.values == text_field)

	// Lines that stay raw: another module, another key tag, more values
	// than the record.
	other_hash := hash
	other_hash[0] = 0xFF
	long_values: [17]u8
	long_values[16] = 1
	TAG_STEP :: u64(1) << (64 - 8 * op.LOG_FACT_LINE_KEY_BYTES)
	for text in ([3]string{fact_render_line(other_hash, FACT_RENDER_KEY, values[:]), fact_render_line(hash, FACT_RENDER_KEY + TAG_STEP, values[:]), fact_render_line(hash, FACT_RENDER_KEY, long_values[:])}) {
		_, rendered := fact_line_render(&catalog, text)
		testing.expectf(t, !rendered, "the line %s is rendered", text)
	}
	// A second module whose hash starts with the same module tag is
	// refused, a hash that differs in the last byte of the tag is not.
	twin := hash
	twin[module.HASH_SIZE - 1] = 0xFF
	testing.expect(t, fact_catalog_add(&catalog, twin, "", file) != "")
	testing.expect_value(t, len(catalog.modules), 1)
	neighbour := hash
	neighbour[op.LOG_FACT_LINE_MODULE_HASH_BYTES - 1] += 1
	neighbour_catalog := Fact_Catalog{allocator = context.temp_allocator}
	testing.expect_value(t, fact_catalog_add(&neighbour_catalog, hash, "", file), "")
	testing.expect_value(t, fact_catalog_add(&neighbour_catalog, neighbour, "", file), "")
	// The outside modules of a test disk join the catalog of the build: an
	// outside module with the tag of a module of the build is refused, and
	// so is a second outside module with the tag of the first; modules with
	// other tags are taken, and the module of the build keeps its lines.
	outside_twin := [?]Fact_Catalog_Module{{hash = twin, file = file}}
	outside_catalog := Fact_Catalog{allocator = context.temp_allocator}
	testing.expect_value(t, fact_catalog_add(&outside_catalog, hash, "", file), "")
	testing.expect(t, fact_catalog_add_modules(&outside_catalog, outside_twin[:]) != "")
	other_outside := hash
	other_outside[0] = 0xEE
	twin_of_other := other_outside
	twin_of_other[module.HASH_SIZE - 1] = 0xEE
	outside_pair := [?]Fact_Catalog_Module{{hash = other_outside, file = file}, {hash = twin_of_other, file = file}}
	testing.expect(t, fact_catalog_add_modules(&outside_catalog, outside_pair[:]) != "")
	outside_taken := [?]Fact_Catalog_Module{{hash = neighbour, file = file}}
	testing.expect_value(t, fact_catalog_add_modules(&outside_catalog, outside_taken[:]), "")
	testing.expect(t, fact_catalog_file_of_hash(&outside_catalog, hash) != nil && fact_catalog_file_of_hash(&outside_catalog, twin) == nil)
	// A whole hash names its module only: the twin, which starts with the
	// same module tag, and the hash of zeros name none.
	testing.expect(t, fact_catalog_file_of_hash(&catalog, twin) == nil)
	testing.expect(t, fact_catalog_file_of_hash(&catalog, {}) == nil)
	testing.expect(t, fact_catalog_file_of_hash(&catalog, hash) != nil)

	sentence, rendered := fact_line_render(&catalog, line)
	testing.expect(t, rendered)
	testing.expect_value(t, sentence, "probe: the value 42, the mark 0x4c4f4746 and the number 7; {braces}")
	// The values of zero bytes after the last one that is not zero: the
	// line holds none of them, and the render reads them as zero.
	zero_line := fact_render_line(hash, FACT_RENDER_KEY, nil)
	zero_sentence, zero_rendered := fact_line_render(&catalog, zero_line)
	testing.expect(t, zero_rendered && zero_sentence == "probe: the value 0, the mark 0x00000000 and the number 0; {braces}")

	log := strings.concatenate({"[root] root: a text\r\n[log_reader] ", line, "\r\n[x] #not a fact\r\n"}, context.temp_allocator)
	whole_log, whole_lines := fact_lines_render(&catalog, log)
	testing.expect_value(t, whole_log, "[root] root: a text\r\n[log_reader] probe: the value 42, the mark 0x4c4f4746 and the number 7; {braces}\r\n[x] #not a fact\r\n")
	testing.expect_value(t, whole_lines, 1)
	// The lines after a place render alone, to the same text: a reader
	// that keeps the rendered start renders only the new lines.
	cut := len("[root] root: a text\r\n")
	start, _ := fact_lines_render(&catalog, log[:cut])
	rest, rest_lines := fact_lines_render(&catalog, log[cut:])
	testing.expect_value(t, strings.concatenate({start, rest}, context.temp_allocator), whole_log)
	testing.expect_value(t, rest_lines, 1)
	plain, plain_lines := fact_lines_render(&catalog, "[root] root: a text\r\n")
	testing.expect(t, plain == "[root] root: a text\r\n" && plain_lines == 0)
	// The place of a rendered line counts the bytes of its raw line, its
	// end of line included, for the measure of the two forms.
	places := make([dynamic]Fact_Line_Place, context.temp_allocator)
	_, _ = fact_lines_render(&catalog, log, &places)
	testing.expect_value(t, len(places), 1)
	if len(places) == 1 {
		testing.expect_value(t, places[0].raw_count, len("[log_reader] ") + len(line) + len("\r\n"))
		testing.expect_value(t, places[0].end - places[0].start, len("[log_reader] probe: the value 42, the mark 0x4c4f4746 and the number 7; {braces}\r\n"))
	}
	// The render of the bytes of a record, as a row of log.fact_records
	// gives them: a key that the file has no fact type for, a count of 0,
	// one less and one more than the record are refused; the record whole
	// is the sentence of its line.
	file_of_line := fact_catalog_file(&catalog, module_tag_of(hash))
	longer: [len(values) + 1]u8
	copy(longer[:], values[:])
	Refused_Values :: struct {
		key:   u64,
		count: int,
	}
	for item in ([?]Refused_Values{{FACT_RENDER_KEY + 1, len(values)}, {0, len(values)}, {FACT_RENDER_KEY, 0}, {FACT_RENDER_KEY, len(values) - 1}, {FACT_RENDER_KEY, len(values) + 1}}) {
		_, values_rendered := fact_values_render(file_of_line, item.key, longer[:item.count])
		testing.expectf(t, !values_rendered, "the key %x with %d value bytes is rendered", item.key, item.count)
	}
	whole_sentence, whole_rendered := fact_values_render(file_of_line, FACT_RENDER_KEY, values[:])
	testing.expect(t, whole_rendered)
	testing.expect_value(t, whole_sentence, sentence)
}

// A Text value of a fact is bytes of its writer, which the kernel does not
// filter: the render writes "?" for each byte of an invalid sequence, a
// line feed, a carriage return and an escape included, as the filter of the
// kernel does for a text. The bytes after the first zero byte are not
// text. Plain bytes stay as they are.
@(test)
a_text_value_of_a_fact_is_filtered :: proc(t: ^testing.T) {
	file := fact_render_file("probe: {value} {mark} [{note}]", true)
	hash: [module.HASH_SIZE]u8
	hash[0] = 7
	catalog := Fact_Catalog{allocator = context.temp_allocator}
	testing.expect_value(t, fact_catalog_add(&catalog, hash, "", file), "")
	Case :: struct {
		note:     [4]u8,
		sentence: string,
	}
	cases := [?]Case {
		{{'\n', '\r', 0x1B, 'x'}, "probe: 1 0x00000000 [???x]"},
		{{0xFF, 'a', 0, '\n'}, "probe: 1 0x00000000 [?a]"},
		{{'o', 'k', 0, 0}, "probe: 1 0x00000000 [ok]"},
	}
	for item in cases {
		values: [16]u8
		values[0] = 1
		note := item.note
		copy(values[12:], note[:])
		sentence, rendered := fact_line_render(&catalog, fact_render_line(hash, FACT_RENDER_KEY, values[:]))
		testing.expectf(t, rendered && sentence == item.sentence, "the note %v gave %q, not %q", item.note, sentence, item.sentence)
	}
}
