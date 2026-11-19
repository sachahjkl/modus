#+build !freestanding
package module

import "core:testing"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The key of the fact whose template is valid, and of the fact whose
// template names a field that the record does not have.
@(private = "file")
SENTENCE_KEY :: u64(0x5e47)
@(private = "file")
BROKEN_KEY :: u64(0x5e48)

// The template of the fact SENTENCE_KEY: each field of each kind, and two
// braces.
@(private = "file")
SENTENCE_TEMPLATE :: "b {block} p {pause} h {hash} c {check} l {level} d {delta} n [{note}] m {name} {{x}}"

// The size of the record of the fact: the offset of its last field and
// the bytes of that field.
@(private = "file")
SENTENCE_RECORD_SIZE :: 40

// sentence_file gives a module file with the record "Probe" of a field of
// each kind, and two facts of it: SENTENCE_KEY with SENTENCE_TEMPLATE, and
// BROKEN_KEY with a template that names no field of the record.
@(private = "file")
sentence_file :: proc() -> []u8 {
	strings_table := make([dynamic]u8, context.temp_allocator)
	append(&strings_table, 0)
	put :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
		offset = u32(len(table))
		append(table, text)
		return offset, u32(len(text))
	}
	records: [2]Record
	records[1].name_offset, records[1].name_count = put(&strings_table, "Probe")
	records[1].size, records[1].first_field, records[1].field_count = SENTENCE_RECORD_SIZE, 1, 8
	fields: [9]Field
	named :: proc(table: ^[dynamic]u8, name: string, item: Field) -> Field {
		result := item
		result.name_offset, result.name_count = put(table, name)
		return result
	}
	fields[1] = named(&strings_table, "block", {offset = 0, type = u8(Type.Integer), unsigned = true})
	fields[2] = named(&strings_table, "pause", {offset = 8, type = u8(Type.Integer), integer_unit = value_kinds.time_in(.Milliseconds)})
	fields[3] = named(&strings_table, "hash", {offset = 16, type = u8(Type.Bytes), detail = 4, kind = u8(value_kinds.Field_Kind.Hash)})
	fields[4] = named(&strings_table, "check", {offset = 20, type = u8(Type.Integer), detail = 4, unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal)})
	fields[5] = named(&strings_table, "level", {offset = 24, type = u8(Type.Integer), detail = 1, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Log_Level)})
	fields[6] = named(&strings_table, "delta", {offset = 25, type = u8(Type.Integer), detail = 1})
	fields[7] = named(&strings_table, "note", {offset = 26, type = u8(Type.Text), detail = 4})
	fields[8] = named(&strings_table, "name", {offset = 30, type = u8(Type.Text), detail = 10, kind = u8(value_kinds.Field_Kind.Module_Name)})
	facts: [3]Fact
	package_offset, package_count := put(&strings_table, "probe")
	facts[1] = {key = SENTENCE_KEY, record = 1, package_offset = package_offset, package_count = package_count}
	facts[1].template_offset, facts[1].template_count = put(&strings_table, SENTENCE_TEMPLATE)
	facts[2] = {key = BROKEN_KEY, record = 1, package_offset = package_offset, package_count = package_count}
	facts[2].template_offset, facts[2].template_count = put(&strings_table, "b {block} and {other}")

	file := make([dynamic]u8, size_of(Header) + TABLE_COUNT * size_of(Table_Entry), context.temp_allocator)
	directory: [TABLE_COUNT]Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[TABLE_COUNT]Table_Entry, kind: Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, ([^]u8)(&records)[:size_of(records)], len(records), size_of(Record))
	add(&file, &directory, .Fields, ([^]u8)(&fields)[:size_of(fields)], len(fields), size_of(Field))
	add(&file, &directory, .Strings, strings_table[:], u32(len(strings_table)), 1)
	add(&file, &directory, .Facts, ([^]u8)(&facts)[:size_of(facts)], len(facts), size_of(Fact))
	(^Header)(&file[0])^ = {magic = MAGIC, version = VERSION, header_size = size_of(Header), machine = .X86_64, table_count = TABLE_COUNT}
	(^[TABLE_COUNT]Table_Entry)(&file[size_of(Header)])^ = directory
	return file[:]
}

// sentence_values gives the values of the fact: block 12, a pause of 1500
// ms, the hash head de ad 00 01, the check 0x231a, the level Warning, the
// delta -5, the note "ok" and the name "storage".
@(private = "file")
sentence_values :: proc() -> (values: [SENTENCE_RECORD_SIZE]u8) {
	values[0] = 12
	values[8], values[9] = 0xDC, 0x05 // 1500
	values[16], values[17], values[18], values[19] = 0xDE, 0xAD, 0x00, 0x01
	values[20], values[21] = 0x1A, 0x23
	values[24] = u8(op.Log_Level.Warning)
	values[25] = 0xFB // -5
	values[26], values[27] = 'o', 'k'
	name := "storage"
	copy(values[30:], name)
	return values
}

// Each fact that a reader cannot write is refused, with no byte written:
// the key 0, a key that no row has, a count of the value bytes of 0, one
// less and one more than the record, a template that names no field, and a
// sentence one byte longer than the buffer. The edge that fits, the
// buffer of the exact length, is written.
@(test)
a_fact_that_cannot_be_written_is_refused :: proc(t: ^testing.T) {
	file := sentence_file()
	values := sentence_values()
	sentence: [FACT_SENTENCE_BYTES_MOST]u8
	runs: [FACT_SENTENCE_RUNS_MOST]value_kinds.Value_Run_In_Call
	Refused :: struct {
		key:     u64,
		count:   int,
		refusal: Fact_Render_Refusal,
	}
	refused := [?]Refused {
		{0, SENTENCE_RECORD_SIZE, .No_Fact_Type},
		{SENTENCE_KEY + 2, SENTENCE_RECORD_SIZE, .No_Fact_Type},
		{max(u64), SENTENCE_RECORD_SIZE, .No_Fact_Type},
		{SENTENCE_KEY, 0, .Value_Count},
		{SENTENCE_KEY, SENTENCE_RECORD_SIZE - 1, .Value_Count},
		{SENTENCE_KEY, SENTENCE_RECORD_SIZE + 1, .Value_Count},
		{BROKEN_KEY, SENTENCE_RECORD_SIZE, .Template},
	}
	longer: [SENTENCE_RECORD_SIZE + 1]u8
	copy(longer[:], values[:])
	for item in refused {
		count, run_count, refusal := fact_sentence_write(file, item.key, longer[:item.count], sentence[:], runs[:])
		testing.expectf(t, refusal == item.refusal && count == 0 && run_count == 0, "the key %x with %d bytes gave %v, %d bytes", item.key, item.count, refusal, count)
	}
	whole, _, whole_refusal := fact_sentence_write(file, SENTENCE_KEY, values[:], sentence[:], runs[:])
	testing.expect_value(t, whole_refusal, Fact_Render_Refusal.None)
	short_count, short_runs, short_refusal := fact_sentence_write(file, SENTENCE_KEY, values[:], sentence[:whole - 1], runs[:])
	testing.expect(t, short_refusal == .Too_Long && short_count == 0 && short_runs == 0)
	exact: [FACT_SENTENCE_BYTES_MOST]u8
	exact_count, _, exact_refusal := fact_sentence_write(file, SENTENCE_KEY, values[:], exact[:whole], runs[:])
	testing.expect(t, exact_refusal == .None && exact_count == whole)
	testing.expect_value(t, string(exact[:exact_count]), string(sentence[:whole]))
}

// The values that a field cannot hold as a known form: a level word that
// names no member is its number, never a name; a Text with a line feed, an
// invalid byte and an escape takes "?" for each; the least signed values
// and the largest unsigned value are whole. The bytes of the caller do not
// change.
@(test)
the_edges_of_a_value_are_written_whole :: proc(t: ^testing.T) {
	file := sentence_file()
	values := sentence_values()
	values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7] = 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	values[8], values[9], values[10], values[11], values[12], values[13], values[14], values[15] = 0, 0, 0, 0, 0, 0, 0, 0x80
	values[24] = u8(max(op.Log_Level)) + 1
	values[25] = 0x80 // -128
	values[26], values[27], values[28], values[29] = '\n', 0xFF, 0x1B, 'a'
	kept := values
	sentence: [FACT_SENTENCE_BYTES_MOST]u8
	runs: [FACT_SENTENCE_RUNS_MOST]value_kinds.Value_Run_In_Call
	count, run_count, refusal := fact_sentence_write(file, SENTENCE_KEY, values[:], sentence[:], runs[:])
	testing.expect_value(t, refusal, Fact_Render_Refusal.None)
	testing.expect_value(t, string(sentence[:count]), "b 18446744073709551615 p -9223372036854775808 ms h dead0001 c 0x0000231a l 4 d -128 n [???a] m storage {x}")
	testing.expect(t, values == kept)
	// The level of no member has the kind of a number, not of a status.
	testing.expect_value(t, run_count, 7)
	testing.expect_value(t, runs[4].kind, u8(value_kinds.Value_Kind.Number))
}

// A whole fact, the last case: the template with each value by its kind,
// "{{" and "}}" as one brace, and one value run for each value that has a
// value kind, at the bytes of the value. A plain Text has no run. A table
// of runs with no room keeps the sentence whole.
@(test)
a_fact_is_written_with_its_values :: proc(t: ^testing.T) {
	file := sentence_file()
	values := sentence_values()
	sentence: [FACT_SENTENCE_BYTES_MOST]u8
	runs: [FACT_SENTENCE_RUNS_MOST]value_kinds.Value_Run_In_Call
	count, run_count, refusal := fact_sentence_write(file, SENTENCE_KEY, values[:], sentence[:], runs[:])
	text := string(sentence[:count])
	testing.expect_value(t, refusal, Fact_Render_Refusal.None)
	testing.expect_value(t, text, "b 12 p 1500 ms h dead0001 c 0x0000231a l Warning d -5 n [ok] m storage {x}")
	Expected :: struct {
		value: string,
		kind:  value_kinds.Value_Kind,
	}
	expected := [?]Expected{{"12", .Number}, {"1500 ms", .Time}, {"dead0001", .Version}, {"0x0000231a", .Number}, {"Warning", .Status}, {"-5", .Number}, {"storage", .Module}}
	testing.expect_value(t, run_count, len(expected))
	for item, index in expected[:min(run_count, len(expected))] {
		run := runs[index]
		testing.expectf(t, text[run.start:][:run.length] == item.value && run.kind == u8(item.kind), "the run %d is %q of the kind %d", index, text[run.start:][:run.length], run.kind)
	}
	no_room, no_runs, no_room_refusal := fact_sentence_write(file, SENTENCE_KEY, values[:], sentence[:], nil)
	testing.expect(t, no_room_refusal == .None && no_runs == 0 && no_room == count)
}
