package build

import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/value_kinds"
import "core:fmt"
import "core:testing"

// The kinds that the writers of every module need, past the first kinds
// (src/md/features/log_facts.md, "Field kinds"): a fact type with no field,
// 16 hexadecimal digits, the head of a hash, a hash of 16 bytes,
// hundredths, nanoseconds as microseconds, a status of 8 bytes, and the
// fields of an error record as a distinct type of one shared shape.

// The folder of the sources of these tests: a module of the group tests,
// which the tests give whole, so no file of it is on the disk.
@(private = "file")
KINDS_TEST_FOLDER :: "src/modules/tests/fact_kinds_probe"

// The imports of each source of these tests.
@(private = "file")
KINDS_TEST_IMPORTS :: `package fact_kinds_probe

import "modus:system"
import "modus:contract/value_kinds"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
`

// The fact types of the case that is taken: one with no field, one of each
// new kind, and one of the shape of an error record.
@(private = "file")
KINDS_TEST_TYPES :: `
@(log_fact = "probe: the machine is usable")
Usable :: struct {}

@(log_fact = "probe: at {address}, {passes} passes, in {spent}, the status {status}, the start policy {policy}, the module {head}...")
Kinds :: struct {
	address: value_kinds.Hexadecimal_Sixteen_Digits,
	passes:  value_kinds.Hundredths,
	spent:   value_kinds.Nanoseconds_As_Microseconds,
	status:  call_outcome.Call_Outcome_Word,
	policy:  value_kinds.Hash_Head_Field,
	head:    value_kinds.Hash_Sixteen_Bytes_Field,
}

@(log_fact = "probe: the block service refused a request: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Request_Refused :: distinct errors.Error_Record_Fact_Fields
`

// The calls of the case that is taken: the fact of no field, the fact of
// each kind, and the fact of an error record by a conversion.
@(private = "file")
KINDS_TEST_CALLS :: `
	system.log_fact(.Info, Usable{})
	system.log_fact(.Info, Kinds{})
	system.log_fact(.Warning, Request_Refused(errors.error_record_fact_fields(errors.Error_Record{})))
`

@(private = "file")
kinds_test_source :: proc(declarations, body: string) -> Fact_Source {
	text := fmt.tprintf("%s\n%s\n\nwrite :: proc() {{\n%s\n}}\n", KINDS_TEST_IMPORTS, declarations, body)
	return {path = KINDS_TEST_FOLDER + "/main.odin", source = text}
}

// Each source that the extraction must refuse, with what it breaks. A
// fact type with no field takes no name in braces; a distinct type names a
// record type that the tool reads; a fact of an error record ends with the
// words of each such fact; a conversion converts to a fact type; a status
// of 4 bytes after a field of 8 leaves 4 bytes that no field covers, which
// its word type of 8 bytes covers. For each, the extraction gives no fact.
@(test)
a_fact_type_of_the_new_kinds_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name:         string,
		declarations: string,
		body:         string,
	}
	cases := [?]Case {
		{"a name in braces in a fact of no field", "@(log_fact = \"probe: {usable}\")\nUsable :: struct {}", "system.log_fact(.Info, Usable{})"},
		{"a distinct type of an integer", "@(log_fact = \"probe: {count}\")\nCount :: distinct u64", "system.log_fact(.Info, Count(1))"},
		{"a distinct type of a type that no package declares", "@(log_fact = \"probe\")\nShape :: distinct missing.Shape", "system.log_fact(.Info, Shape{})"},
		{"a distinct type of a record type of the package with no attribute on the type", "Shape :: struct {\n\tblock: u64,\n}\nCopy :: distinct Shape", "system.log_fact(.Info, Copy{block = 1})"},
		{"a fact of an error record with other words at its end", "@(log_fact = \"probe: refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}.\")\nRefused :: distinct errors.Error_Record_Fact_Fields", "system.log_fact(.Warning, Refused(errors.error_record_fact_fields(errors.Error_Record{})))"},
		{"a fact of an error record that names a field two times", "@(log_fact = \"probe: {kind} kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}\")\nRefused :: distinct errors.Error_Record_Fact_Fields", "system.log_fact(.Warning, Refused(errors.error_record_fact_fields(errors.Error_Record{})))"},
		{"a conversion by a procedure", "helper :: proc(value: u64) -> u64 {return value}", "system.log_fact(.Info, helper(1))"},
		{"a conversion of two values", "@(log_fact = \"probe: {block}\")\nProbe :: struct {\n\tblock: u64,\n}", "system.log_fact(.Info, Probe(1, 2))"},
		{"a stop cause of 4 bytes after a field of 8", "@(log_fact = \"probe: {block} {cause}\")\nProbe :: struct {\n\tblock: u64,\n\tcause: op.Stop_Cause,\n}", "system.log_fact(.Info, Probe{block = 1})"},
		{"a word of a kind of an error record of 8 bytes beside a field of 4", "@(log_fact = \"probe: {kind} {small}\")\nProbe :: struct {\n\tkind:  errors.Kind_Word,\n\tsmall: u32,\n}", "system.log_fact(.Info, Probe{small = 1})"},
	}
	for item in cases {
		sources := [1]Fact_Source{kinds_test_source(item.declarations, item.body)}
		facts, ok := facts_of_sources(sources[:])
		testing.expectf(t, !ok && len(facts) == 0, "the extraction takes %s", item.name)
	}
	// The word type of a status covers the 4 bytes: taken.
	word_type := "@(log_fact = \"probe: {block} {status}\")\nProbe :: struct {\n\tblock:  u64,\n\tstatus: call_outcome.Call_Outcome_Word,\n}"
	word_sources := [1]Fact_Source{kinds_test_source(word_type, "system.log_fact(.Info, Probe{block = 1})")}
	word_facts, word_ok := facts_of_sources(word_sources[:])
	testing.expect(t, word_ok && len(word_facts) == 1 && word_facts[0].record.size == 16)
}

// A record of an export with no field is refused: a call carries values,
// and only a log fact can have none.
@(test)
a_record_of_an_export_with_no_field_is_refused :: proc(t: ^testing.T) {
	source := `// A record with no field.
package sample

Empty :: struct {}

// take takes a record with no field.
@(export)
take :: proc "c" (empty: ^Empty) -> i64 {return 0}
`
	list := make([dynamic]Export_Description, context.temp_allocator)
	testing.expect(t, !describe_source("sample.odin", source, &list))
}

// The fact types that are taken, the last case: their descriptions, field
// by field, and the sentence of each by the one render of the contract,
// the edges of each new kind first.
@(test)
the_fact_types_of_the_new_kinds_are_described_and_rendered :: proc(t: ^testing.T) {
	sources := [1]Fact_Source{kinds_test_source(KINDS_TEST_TYPES, KINDS_TEST_CALLS)}
	facts, ok := facts_of_sources(sources[:])
	if !testing.expect(t, ok && len(facts) == 3) {
		return
	}
	usable, kinds, refused := facts[0], facts[1], facts[2]
	testing.expect(t, usable.type_name == "Usable" && usable.record.size == 0 && len(usable.record.fields) == 0)
	testing.expect_value(t, usable.key, fact_key("fact_kinds_probe", "Usable"))
	expected_kinds := [?]Field_Description {
		{"address", 0, .Integer, 0, true, {}, .Hexadecimal_Sixteen_Digits, .None},
		{"passes", 8, .Integer, 0, false, {}, .Hundredths, .None},
		{"spent", 16, .Integer, 0, true, {}, .Nanoseconds_As_Microseconds, .None},
		{"status", 24, .Integer, 0, true, {}, .Status, .Call_Outcome},
		{"policy", 32, .Bytes, value_kinds.HASH_FIELD_BYTES, false, {}, .Hash_Head, .None},
		{"head", 64, .Bytes, value_kinds.HASH_SIXTEEN_BYTES, false, {}, .Hash, .None},
	}
	testing.expect_value(t, kinds.record.size, 80)
	testing.expect_value(t, len(kinds.record.fields), len(expected_kinds))
	for item, index in expected_kinds[:min(len(expected_kinds), len(kinds.record.fields))] {
		testing.expect_value(t, kinds.record.fields[index], item)
		stored := module.Field{offset = item.offset, type = u8(item.type), detail = item.detail, unsigned = item.unsigned, kind = u8(item.kind), contract_enum = u8(item.contract_enum)}
		testing.expectf(t, module.field_kind_valid(stored), "the field %s is refused by the contract", item.name)
	}
	// The shape of an error record: the record has the name of the fact
	// type, and the fields of the shape, the kind and the unit by their
	// word types.
	expected_refused := [?]Field_Description {
		{"kind", 0, .Integer, 0, true, {}, .Status, .Error_Kind},
		{"unit", 8, .Integer, 0, true, {}, .Status, .Error_Unit},
		{"operation", 16, .Integer, 0, false, {}, .Plain, .None},
		{"argument", 24, .Integer, 0, false, {}, .Plain, .None},
		{"value", 32, .Integer, 0, false, {}, .Plain, .None},
		{"limit", 40, .Integer, 0, false, {}, .Plain, .None},
		{"found", 48, .Integer, 0, false, {}, .Plain, .None},
	}
	testing.expect(t, refused.type_name == "Request_Refused" && refused.record.name == "Request_Refused")
	testing.expect_value(t, refused.record.size, u32(size_of(errors.Error_Record)))
	testing.expect_value(t, len(refused.record.fields), len(expected_refused))
	for item, index in expected_refused[:min(len(expected_refused), len(refused.record.fields))] {
		testing.expect_value(t, refused.record.fields[index], item)
	}

	description: Module_Description
	if !testing.expect(t, facts_merge(&description, facts)) {
		return
	}
	file := facts_module_file(description)
	buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
	usable_count, _, usable_refusal := module.fact_sentence_write(file, usable.key, nil, buffer[:], nil)
	testing.expect(t, usable_refusal == .None && string(buffer[:usable_count]) == "probe: the machine is usable")
	one_byte := [1]u8{0}
	_, _, one_refusal := module.fact_sentence_write(file, usable.key, one_byte[:], buffer[:], nil)
	testing.expect_value(t, one_refusal, module.Fact_Render_Refusal.Value_Count)

	policy: [module.HASH_SIZE]u8
	for &value, index in policy {
		value = u8(0x1a + 0x11 * index)
	}
	Edge :: struct {
		address, passes, spent, status: u64,
		sentence:                       string,
	}
	edges := [?]Edge {
		{0, 0, 0, u64(call_outcome.Call_Outcome.Succeeded), "probe: at 0000000000000000, 0.00 passes, in 0.0 us, the status Succeeded, the start policy 1a2b3c4d…, the module 00000000000000000000000000000000..."},
		{1, 1, 1, u64(max(call_outcome.Call_Outcome)) + 1, fmt.tprintf("probe: at 0000000000000001, 0.01 passes, in 0.0 us, the status %d, the start policy 1a2b3c4d…, the module 00000000000000000000000000000000...", u64(max(call_outcome.Call_Outcome)) + 1)},
		{max(u64), signed_bits(-50), 812_499, max(u64), "probe: at ffffffffffffffff, -0.50 passes, in 812.4 us, the status 18446744073709551615, the start policy 1a2b3c4d…, the module 00000000000000000000000000000000..."},
		{0x922, 105, max(u64), u64(call_outcome.Call_Outcome.Argument_Refused), "probe: at 0000000000000922, 1.05 passes, in 18446744073709551.6 us, the status Argument_Refused, the start policy 1a2b3c4d…, the module 00000000000000000000000000000000..."},
	}
	for edge in edges {
		written := fact_test_render(t, file, "fact_kinds_probe", "Kinds", {{"address", edge.address}, {"passes", edge.passes}, {"spent", edge.spent}, {"status", edge.status}, {"policy", policy}})
		testing.expectf(t, written == edge.sentence, "the fact of each kind writes %q, not %q", written, edge.sentence)
	}
	// The hash of 16 bytes: its 32 digits, and the template writes "...".
	key, bytes, made := fact_test_record(t, file, "fact_kinds_probe", "Kinds", {{"policy", policy}})
	if made {
		for index in 0 ..< value_kinds.HASH_SIXTEEN_BYTES {
			bytes[64 + index] = u8(0xA0 + index)
		}
		count, _, refusal := module.fact_sentence_write(file, key, bytes, buffer[:], nil)
		testing.expect_value(t, refusal, module.Fact_Render_Refusal.None)
		testing.expect_value(t, string(buffer[:count]), "probe: at 0000000000000000, 0.00 passes, in 0.0 us, the status Succeeded, the start policy 1a2b3c4d…, the module a0a1a2a3a4a5a6a7a8a9aaabacadaeaf...")
	}

	// An error record: each member by its name; a kind or a unit that
	// names no member, and the word -1 of a record, by their numbers.
	Record_Case :: struct {
		record:   errors.Error_Record,
		sentence: string,
	}
	record_cases := [?]Record_Case {
		{{kind = i64(errors.Kind.Too_Long), unit = i64(errors.Unit.Bytes), operation = 3, argument = 2, value = 300, limit = 255}, "probe: the block service refused a request: kind Too_Long, unit Bytes, operation 3, argument 2, value 300, limit 255, found 0"},
		{{kind = i64(max(errors.Kind)) + 1, unit = i64(max(errors.Unit)) + 1, value = -1}, fmt.tprintf("probe: the block service refused a request: kind %d, unit %d, operation 0, argument 0, value -1, limit 0, found 0", i64(max(errors.Kind)) + 1, i64(max(errors.Unit)) + 1)},
		{{kind = -1, unit = -1, found = min(i64)}, "probe: the block service refused a request: kind 18446744073709551615, unit 18446744073709551615, operation 0, argument 0, value 0, limit 0, found -9223372036854775808"},
	}
	for item in record_cases {
		fields := errors.error_record_fact_fields(item.record)
		values := transmute([size_of(errors.Error_Record_Fact_Fields)]u8)fields
		count, _, refusal := module.fact_sentence_write(file, refused.key, values[:], buffer[:], nil)
		testing.expect_value(t, refusal, module.Fact_Render_Refusal.None)
		testing.expectf(t, string(buffer[:count]) == item.sentence, "the error record %v writes %q", item.record, string(buffer[:count]))
	}
}

// The text of a field of each new kind, as the step Fact and a measure
// read it: the text of the sentence.
@(test)
field_value_writes_each_new_kind :: proc(t: ^testing.T) {
	row: [value_kinds.HASH_FIELD_BYTES]u8
	row[0], row[1] = 0x22, 0x09
	address := module.Field{type = u8(module.Type.Integer), offset = 0, unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal_Sixteen_Digits)}
	testing.expect_value(t, field_value(row[:], address), "0000000000000922")
	passes := module.Field{type = u8(module.Type.Integer), offset = 0, kind = u8(value_kinds.Field_Kind.Hundredths)}
	testing.expect_value(t, field_value(row[:], passes), "23.38")
	spent := module.Field{type = u8(module.Type.Integer), offset = 0, unsigned = true, kind = u8(value_kinds.Field_Kind.Nanoseconds_As_Microseconds)}
	testing.expect_value(t, field_value(row[:], spent), "2.3 us")
	head := module.Field{type = u8(module.Type.Bytes), offset = 0, detail = value_kinds.HASH_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Hash_Head)}
	testing.expect_value(t, field_value(row[:], head), "22090000…")
	kind := module.Field{type = u8(module.Type.Integer), offset = 0, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Error_Kind)}
	testing.expect_value(t, field_value(row[:], kind), "2338")
	row[0], row[1] = u8(errors.Kind.Too_Long), 0
	testing.expect_value(t, field_value(row[:], kind), "Too_Long")
}
