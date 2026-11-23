#+build !freestanding
package module

import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The kinds of a field that a line of a module wrote before the facts and
// that the first kinds did not write: 16 hexadecimal digits, the head of a
// hash, hundredths, nanoseconds as microseconds, the enums of an error
// record and a status of 8 bytes; and a fact type with no field.

// The key of the fact of each kind, and of the fact with no field. The
// table is sorted by key.
@(private = "file")
KINDS_KEY :: u64(0x6b01)
@(private = "file")
NOTHING_KEY :: u64(0x6b02)

@(private = "file")
KINDS_TEMPLATE :: "a {address} p {passes} s {spent} k {kind} u {unit} t {status} h {policy}"
@(private = "file")
NOTHING_TEMPLATE :: "root: the machine is usable"

// The record of the fact of each kind: six Integers of 8 bytes, then a
// whole hash.
@(private = "file")
KINDS_RECORD_SIZE :: 6 * 8 + value_kinds.HASH_FIELD_BYTES

// The fields of the record of the fact of each kind, by their offsets.
@(private = "file")
ADDRESS_FIELD :: Field{offset = 0, type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal_Sixteen_Digits)}
@(private = "file")
PASSES_FIELD :: Field{offset = 8, type = u8(Type.Integer), kind = u8(value_kinds.Field_Kind.Hundredths)}
@(private = "file")
SPENT_FIELD :: Field{offset = 16, type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Nanoseconds_As_Microseconds)}
@(private = "file")
KIND_FIELD :: Field{offset = 24, type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Error_Kind)}
@(private = "file")
UNIT_FIELD :: Field{offset = 32, type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Error_Unit)}
@(private = "file")
STATUS_FIELD :: Field{offset = 40, type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Status)}
@(private = "file")
POLICY_FIELD :: Field{offset = 48, type = u8(Type.Bytes), detail = value_kinds.HASH_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Hash_Head)}
// The fields of the second round of kinds, alone at offset 0.
@(private = "file")
TENTHS_FIELD :: Field{offset = 0, type = u8(Type.Integer), kind = u8(value_kinds.Field_Kind.Tenths)}
@(private = "file")
ADDRESS_SHORT_FIELD :: Field{offset = 0, type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal_No_Leading_Zero)}
@(private = "file")
TIME_OF_DAY_FIELD :: Field{offset = 0, type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Time_Of_Day)}

// kinds_file gives a module file with the record "Kinds" of a field of
// each new kind, the record "Nothing" with no field, and a fact of each.
@(private = "file")
kinds_file :: proc() -> []u8 {
	strings_table := make([dynamic]u8, context.temp_allocator)
	append(&strings_table, 0)
	put :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
		offset = u32(len(table))
		append(table, text)
		return offset, u32(len(text))
	}
	records: [3]Record
	records[1].name_offset, records[1].name_count = put(&strings_table, "Kinds")
	records[1].size, records[1].first_field, records[1].field_count = KINDS_RECORD_SIZE, 1, 7
	// A record of no field names no first field: field reads none.
	records[2].name_offset, records[2].name_count = put(&strings_table, "Nothing")
	fields: [8]Field
	named :: proc(table: ^[dynamic]u8, name: string, item: Field) -> Field {
		result := item
		result.name_offset, result.name_count = put(table, name)
		return result
	}
	fields[1] = named(&strings_table, "address", ADDRESS_FIELD)
	fields[2] = named(&strings_table, "passes", PASSES_FIELD)
	fields[3] = named(&strings_table, "spent", SPENT_FIELD)
	fields[4] = named(&strings_table, "kind", KIND_FIELD)
	fields[5] = named(&strings_table, "unit", UNIT_FIELD)
	fields[6] = named(&strings_table, "status", STATUS_FIELD)
	fields[7] = named(&strings_table, "policy", POLICY_FIELD)
	facts: [3]Fact
	package_offset, package_count := put(&strings_table, "probe")
	facts[1] = {key = KINDS_KEY, record = 1, package_offset = package_offset, package_count = package_count}
	facts[1].template_offset, facts[1].template_count = put(&strings_table, KINDS_TEMPLATE)
	facts[2] = {key = NOTHING_KEY, record = 2, package_offset = package_offset, package_count = package_count}
	facts[2].template_offset, facts[2].template_count = put(&strings_table, NOTHING_TEMPLATE)

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

// put_word writes a word of 8 bytes, little-endian, at an offset.
@(private = "file")
put_word :: proc(values: []u8, offset: int, word: u64) {
	for index in 0 ..< 8 {
		values[offset + index] = u8(word >> (8 * u64(index)))
	}
}

// bits_of gives the bits of a signed value, at the run: a constant that is
// negative does not convert to an unsigned type.
@(private = "file")
bits_of :: proc(value: i64) -> u64 {
	return u64(value)
}

// kind_text gives the text of one field by its kind, in a buffer of the
// test.
@(private = "file")
kind_text :: proc(buffer: []u8, item: Field, word: u64) -> (text: string, value_kind: value_kinds.Value_Kind, ok: bool) {
	record: [8]u8
	put_word(record[:], 0, word)
	at_zero := item
	at_zero.offset = 0
	return field_kind_text(buffer, record[:], at_zero)
}

// The edges of each kind that the field kind alone writes: 0, 1, the
// largest value, and the least and a negative value where the type has a
// sign. Each text is the text of the line before the facts.
@(test)
the_edges_of_each_new_kind_are_written :: proc(t: ^testing.T) {
	Case :: struct {
		item: Field,
		word: u64,
		text: string,
		kind: value_kinds.Value_Kind,
	}
	cases := [?]Case {
		// As system.Hex: 16 digits with no "0x", whatever the value.
		{ADDRESS_FIELD, 0, "0000000000000000", .Number},
		{ADDRESS_FIELD, 1, "0000000000000001", .Number},
		{ADDRESS_FIELD, 0x922, "0000000000000922", .Number},
		{ADDRESS_FIELD, max(u64), "ffffffffffffffff", .Number},
		// n / 100 with two decimals, the sign before the whole.
		{PASSES_FIELD, 0, "0.00", .Number},
		{PASSES_FIELD, 1, "0.01", .Number},
		{PASSES_FIELD, 105, "1.05", .Number},
		{PASSES_FIELD, 100, "1.00", .Number},
		{PASSES_FIELD, bits_of(-1), "-0.01", .Number},
		{PASSES_FIELD, bits_of(-50), "-0.50", .Number},
		{PASSES_FIELD, bits_of(max(i64)), "92233720368547758.07", .Number},
		{PASSES_FIELD, bits_of(min(i64)), "-92233720368547758.08", .Number},
		// Microseconds with one decimal, cut, not rounded.
		{SPENT_FIELD, 0, "0.0 us", .Time},
		{SPENT_FIELD, 1, "0.0 us", .Time},
		{SPENT_FIELD, 99, "0.0 us", .Time},
		{SPENT_FIELD, 100, "0.1 us", .Time},
		{SPENT_FIELD, 812_499, "812.4 us", .Time},
		{SPENT_FIELD, 812_500, "812.5 us", .Time},
		{SPENT_FIELD, max(u64), "18446744073709551.6 us", .Time},
		// n / 10 with one decimal, the sign before the whole.
		{TENTHS_FIELD, 0, "0.0", .Number},
		{TENTHS_FIELD, 1, "0.1", .Number},
		{TENTHS_FIELD, 123, "12.3", .Number},
		{TENTHS_FIELD, bits_of(-5), "-0.5", .Number},
		{TENTHS_FIELD, bits_of(-1), "-0.1", .Number},
		{TENTHS_FIELD, bits_of(max(i64)), "922337203685477580.7", .Number},
		{TENTHS_FIELD, bits_of(min(i64)), "-922337203685477580.8", .Number},
		// As write_number of the support package sentence: no zero before
		// the first digit.
		{ADDRESS_SHORT_FIELD, 0, "0x0", .Number},
		{ADDRESS_SHORT_FIELD, 1, "0x1", .Number},
		{ADDRESS_SHORT_FIELD, 0x1a2b, "0x1a2b", .Number},
		{ADDRESS_SHORT_FIELD, 0x10, "0x10", .Number},
		{ADDRESS_SHORT_FIELD, max(u64), "0xffffffffffffffff", .Number},
		// The hours and the minutes, two digits each at least.
		{TIME_OF_DAY_FIELD, 0, "00:00", .Time},
		{TIME_OF_DAY_FIELD, 1, "00:00", .Time},
		{TIME_OF_DAY_FIELD, 25_440, "07:04", .Time},
		{TIME_OF_DAY_FIELD, 86_399, "23:59", .Time},
		{TIME_OF_DAY_FIELD, 86_400, "24:00", .Time},
		{TIME_OF_DAY_FIELD, 360_000, "100:00", .Time},
	}
	for item in cases {
		buffer: [64]u8
		text, value_kind, ok := kind_text(buffer[:], item.item, item.word)
		testing.expectf(t, ok && text == item.text && value_kind == item.kind, "the word %d of the kind %d gave %q of %v, not %q", item.word, item.item.kind, text, value_kind, item.text)
	}
	// An unsigned field of hundredths has no sign: its largest word is a
	// number, never a negative one.
	unsigned_passes := PASSES_FIELD
	unsigned_passes.unsigned = true
	buffer: [64]u8
	text, _, ok := kind_text(buffer[:], unsigned_passes, max(u64))
	testing.expect(t, ok && text == "184467440737095516.15")
	// The head of a hash: its first 4 bytes, in two digits each, then the
	// mark; the bytes after the head are not written.
	record: [value_kinds.HASH_FIELD_BYTES]u8
	head := POLICY_FIELD
	head.offset = 0
	zero_text, zero_kind, zero_ok := field_kind_text(buffer[:], record[:], head)
	testing.expect(t, zero_ok && zero_text == "00000000…" && zero_kind == .Version)
	for &value, index in record {
		value = u8(0x1a + 0x11 * index)
	}
	head_text, _, head_ok := field_kind_text(buffer[:], record[:], head)
	testing.expect(t, head_ok && head_text == "1a2b3c4d…", head_text)
	for &value in record {
		value = 0xFF
	}
	full_text, _, full_ok := field_kind_text(buffer[:], record[:], head)
	testing.expect(t, full_ok && full_text == "ffffffff…")
}

// field_kind_text writes no other kind, and no text that its buffer cannot
// hold whole: a Plain, a Hexadecimal and a Status field give nothing, a
// buffer one byte short of the text gives nothing, and the buffer of the
// exact length gives the text.
@(test)
field_kind_text_refuses_what_it_does_not_write :: proc(t: ^testing.T) {
	record: [8]u8
	put_word(record[:], 0, 105)
	others := [?]Field {
		{type = u8(Type.Integer)},
		{type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal)},
		{type = u8(Type.Integer), unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Error_Kind)},
		{type = u8(Type.Integer), kind = u8(max(value_kinds.Field_Kind)) + 1},
	}
	buffer: [64]u8
	for item in others {
		text, _, ok := field_kind_text(buffer[:], record[:], item)
		testing.expectf(t, !ok && text == "", "the field %v gave %q", item, text)
	}
	passes := PASSES_FIELD
	passes.offset = 0
	short_text, _, short_ok := field_kind_text(buffer[:len("1.05") - 1], record[:], passes)
	testing.expect(t, !short_ok && short_text == "")
	exact_text, _, exact_ok := field_kind_text(buffer[:len("1.05")], record[:], passes)
	testing.expect(t, exact_ok && exact_text == "1.05")
	// A head of a hash in a record shorter than the head is no text.
	head := POLICY_FIELD
	head.offset = 0
	head_text, _, head_ok := field_kind_text(buffer[:], record[:value_kinds.HASH_HEAD_BYTES - 1], head)
	testing.expect(t, !head_ok && head_text == "")
}

// A fact with the enums of an error record and a status of 8 bytes: a word
// that names no member is its number, never the name of another member:
// one past the last member, and the largest word, which is the word -1 of
// an error record. The members are their names.
@(test)
the_enums_of_a_fact_name_their_members :: proc(t: ^testing.T) {
	file := kinds_file()
	values: [KINDS_RECORD_SIZE]u8
	sentence: [FACT_SENTENCE_BYTES_MOST]u8
	runs: [FACT_SENTENCE_RUNS_MOST]value_kinds.Value_Run_In_Call
	put_word(values[:], 24, u64(max(errors.Kind)) + 1)
	put_word(values[:], 32, max(u64))
	put_word(values[:], 40, u64(max(op.Status)) + 1)
	count, _, refusal := fact_sentence_write(file, KINDS_KEY, values[:], sentence[:], runs[:])
	testing.expect_value(t, refusal, Fact_Render_Refusal.None)
	expected_unknown := "a 0000000000000000 p 0.00 s 0.0 us k 43 u 18446744073709551615 t "
	testing.expectf(t, len(sentence[:count]) > len(expected_unknown) && string(sentence[:len(expected_unknown)]) == expected_unknown, "the sentence is %q", string(sentence[:count]))
	put_word(values[:], 24, u64(errors.Kind.Too_Long))
	put_word(values[:], 32, u64(errors.Unit.Bytes))
	put_word(values[:], 40, u64(op.Status.Bad_Address))
	put_word(values[:], 0, 0x922)
	put_word(values[:], 8, 105)
	put_word(values[:], 16, 812_499)
	for &value, index in values[48:] {
		value = u8(0x1a + 0x11 * index)
	}
	kept := values
	count, _, refusal = fact_sentence_write(file, KINDS_KEY, values[:], sentence[:], runs[:])
	testing.expect_value(t, refusal, Fact_Render_Refusal.None)
	testing.expect_value(t, string(sentence[:count]), "a 0000000000000922 p 1.05 s 812.4 us k Too_Long u Bytes t Bad_Address h 1a2b3c4d…")
	testing.expect(t, values == kept)
}

// A fact type with no field: its record has 0 bytes, and its sentence is
// its template. Any value byte is refused, with the buffer of the caller
// unchanged: 1 byte, and the values of one whole fact. A brace that names
// a field is refused in its template, since the record has none. The fact
// of 0 bytes is written last.
@(test)
a_fact_with_no_field_is_its_template :: proc(t: ^testing.T) {
	file := kinds_file()
	_, row, description, found := fact_find(file, NOTHING_KEY)
	testing.expect(t, found && description.size == 0 && description.field_count == 0)
	testing.expect_value(t, fact_template_valid(file, row, description), Fact_Template_Fault.None)
	values: [op.LOG_FACT_VALUE_CAPACITY]u8
	sentence: [FACT_SENTENCE_BYTES_MOST]u8
	MARK :: u8(0x5A)
	for count in ([2]int{1, op.LOG_FACT_VALUE_CAPACITY}) {
		for &value in sentence {
			value = MARK
		}
		written, _, refusal := fact_sentence_write(file, NOTHING_KEY, values[:count], sentence[:], nil)
		testing.expectf(t, refusal == .Value_Count && written == 0, "a fact of no field with %d value bytes gave %v", count, refusal)
		for value in sentence {
			testing.expect_value(t, value, MARK)
		}
	}
	no_names: []string
	brace_fault, brace_place := fact_template_check("the machine is {usable}", no_names)
	testing.expect(t, brace_fault == .Unknown_Field && brace_place == len("the machine is {"))
	plain_fault, _ := fact_template_check(NOTHING_TEMPLATE, no_names)
	testing.expect_value(t, plain_fault, Fact_Template_Fault.None)
	written, run_count, refusal := fact_sentence_write(file, NOTHING_KEY, values[:0], sentence[:], nil)
	testing.expect(t, refusal == .None && run_count == 0)
	testing.expect_value(t, string(sentence[:written]), NOTHING_TEMPLATE)
}
