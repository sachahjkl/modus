#+build !freestanding
#+build !modus
package console_condition

import "core:fmt"
import "core:testing"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:sentence"

// The record of the tests: a field of each type and kind that a condition
// meets, in the order of their offsets.
@(private = "file")
Sample :: struct {
	file:   []u8,
	record: module.Record,
}

@(private = "file")
SAMPLE_FIELDS :: "number, key, check, handle, level, small, name, writer, module_hash"

@(private = "file")
sample_make :: proc(t: ^testing.T) -> (sample: Sample) {
	strings_table := make([dynamic]u8, context.temp_allocator)
	append(&strings_table, 0)
	put :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
		offset = u32(len(table))
		append(table, text)
		return offset, u32(len(text))
	}
	named :: proc(table: ^[dynamic]u8, name: string, item: module.Field) -> module.Field {
		result := item
		result.name_offset, result.name_count = put(table, name)
		return result
	}
	records: [2]module.Record
	records[1].name_offset, records[1].name_count = put(&strings_table, "Sample")
	records[1].size, records[1].first_field, records[1].field_count = 56, 1, 9
	fields: [10]module.Field
	fields[1] = named(&strings_table, "number", {offset = 0, type = u8(module.Type.Integer)})
	fields[2] = named(&strings_table, "key", {offset = 8, type = u8(module.Type.Integer), unsigned = true, integer_unit = value_kinds.size_in(.Pages)})
	fields[3] = named(&strings_table, "check", {offset = 16, type = u8(module.Type.Integer), detail = 4, unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal)})
	fields[4] = named(&strings_table, "handle", {offset = 20, type = u8(module.Type.Handle)})
	fields[5] = named(&strings_table, "level", {offset = 24, type = u8(module.Type.Integer), detail = 1, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Log_Level)})
	fields[6] = named(&strings_table, "small", {offset = 25, type = u8(module.Type.Integer), detail = 1, unsigned = true})
	fields[7] = named(&strings_table, "name", {offset = 26, type = u8(module.Type.Text), detail = 16})
	fields[8] = named(&strings_table, "writer", {offset = 42, type = u8(module.Type.Text), detail = 8, kind = u8(value_kinds.Field_Kind.Module_Name)})
	fields[9] = named(&strings_table, "module_hash", {offset = 50, type = u8(module.Type.Bytes), detail = 4, kind = u8(value_kinds.Field_Kind.Hash)})
	file := make([dynamic]u8, size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry), context.temp_allocator)
	directory: [module.TABLE_COUNT]module.Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, ([^]u8)(&records)[:size_of(records)], len(records), size_of(module.Record))
	add(&file, &directory, .Fields, ([^]u8)(&fields)[:size_of(fields)], len(fields), size_of(module.Field))
	add(&file, &directory, .Strings, strings_table[:], u32(len(strings_table)), 1)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^[module.TABLE_COUNT]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	sample.file = file[:]
	ok: bool
	sample.record, ok = module.record_type(sample.file, 1)
	testing.expect(t, ok, "the record of the tests is valid")
	return sample
}

@(private = "file")
sample_field :: proc(sample: Sample, name: string) -> module.Field {
	item, _ := field_find(sample.file, sample.record, name)
	return item
}

// refusal_text gives the sentence of a refusal, as the console fails a
// line with it.
@(private = "file")
refusal_text :: proc(refusal: Refusal, details: Refusal_Details) -> string {
	buffer := make([]u8, 512, context.temp_allocator)
	writer := sentence.Writer {
		buffer = buffer,
	}
	refusal_write(&writer, refusal, details)
	return sentence.written(&writer)
}

// The field and the operator: no field, a field and no operator, a "!"
// alone, "==", and nothing after the operator, at the end of the line and
// before the ")" that ends the argument; each with its sentence. The last
// case reads a field, an operator of two bytes and the place of its value.
@(test)
the_head_of_a_condition_is_refused_at_each_fault :: proc(t: ^testing.T) {
	sample := sample_make(t)
	Case :: struct {
		text:     string,
		refusal:  Refusal,
		sentence: string,
	}
	cases := [?]Case {
		{"", .No_Field, "where takes a condition: a field, an operator and a value, as where(t, block = 12); the fields are " + SAMPLE_FIELDS},
		{" = 3)", .No_Field, "where takes a condition: a field, an operator and a value, as where(t, block = 12); the fields are " + SAMPLE_FIELDS},
		{" \"level\" = 3)", .No_Field, "where takes a condition: a field, an operator and a value, as where(t, block = 12); the fields are " + SAMPLE_FIELDS},
		{" level)", .No_Operator, "where: after the field level comes an operator: =, !=, <, <=, > or >="},
		{" level", .No_Operator, "where: after the field level comes an operator: =, !=, <, <=, > or >="},
		{" level ! Warning)", .Lone_Bang, "where: \"!\" alone is no operator: the operator of a difference is !="},
		{" level == Warning)", .Double_Equal, "where: \"==\" is no operator: the operator of equality is ="},
		{" number <", .No_Value, "where: the condition on number has no value after its operator <"},
		{" number <=   ", .No_Value, "where: the condition on number has no value after its operator <="},
		{" number = )", .No_Value, "where: the condition on number has no value after its operator ="},
		{" number != , 1)", .No_Value, "where: the condition on number has no value after its operator !="},
	}
	for item in cases {
		head, refusal := head_read(item.text, 0)
		testing.expectf(t, refusal == item.refusal, "%q gave %v, not %v", item.text, refusal, item.refusal)
		text := refusal_text(refusal, {command = "where", file = sample.file, record = sample.record, field = head.field, comparison = head.comparison})
		testing.expectf(t, text == item.sentence, "%q gave the sentence %q", item.text, text)
	}
	text := " number >= 12)"
	head, refusal := head_read(text, 0)
	testing.expect_value(t, refusal, Refusal.None)
	testing.expect_value(t, head.field, "number")
	testing.expect_value(t, head.comparison, Comparison.Greater_Or_Equal)
	testing.expect_value(t, text[head.value_start:], " 12)")
}

// The field: a name that the record lacks; a field with no value that the
// console compares (a hash); an order on a status, on a Text and on a
// module name. Equality on each field, and an order on an Integer and a
// handle, are taken: the last cases.
@(test)
a_field_that_takes_no_operator_is_refused :: proc(t: ^testing.T) {
	sample := sample_make(t)
	_, found := field_find(sample.file, sample.record, "levle")
	testing.expect(t, !found)
	// A field near by its letters, by its unit, or none; an empty name and a
	// name far from each field get no suggestion.
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = "levle"}), "where: the records Sample have no field levle; did you mean level? Their fields are " + SAMPLE_FIELDS)
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = "pages"}), "where: the records Sample have no field pages; did you mean key? Their fields are " + SAMPLE_FIELDS)
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = "nme"}), "where: the records Sample have no field nme; did you mean name? Their fields are " + SAMPLE_FIELDS)
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = "smal"}), "where: the records Sample have no field smal; did you mean small? Their fields are " + SAMPLE_FIELDS)
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = "chek"}), "where: the records Sample have no field chek; did you mean check? Their fields are " + SAMPLE_FIELDS)
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = "zzzzzzzz"}), "where: the records Sample have no field zzzzzzzz; their fields are " + SAMPLE_FIELDS)
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = ""}), "where: the records Sample have no field ; their fields are " + SAMPLE_FIELDS)
	testing.expect_value(t, refusal_text(.Unknown_Field, {command = "where", file = sample.file, record = sample.record, field = "e"}), "where: the records Sample have no field e; their fields are " + SAMPLE_FIELDS)
	Case :: struct {
		field:      string,
		comparison: Comparison,
		refusal:    Refusal,
		sentence:   string,
	}
	cases := [?]Case {
		{"module_hash", .Equal, .Not_Comparable, "where: the field module_hash is Hash(4); where compares an Integer, a Text or a status"},
		{"level", .Greater_Or_Equal, .No_Order, "where: the field level is Status(Log_Level): it takes = and != only, because the order of the members is no order of weight"},
		{"level", .Less, .No_Order, "where: the field level is Status(Log_Level): it takes = and != only, because the order of the members is no order of weight"},
		{"name", .Less, .No_Order, "where: the field name is Text(16): a Text takes = and != only"},
		{"writer", .Greater, .No_Order, "where: the field writer is Module_Name(8): a Text takes = and != only"},
	}
	for item in cases {
		field := sample_field(sample, item.field)
		refusal := field_check(field, item.comparison)
		testing.expectf(t, refusal == item.refusal, "%s %v gave %v", item.field, item.comparison, refusal)
		text := refusal_text(refusal, {command = "where", file = sample.file, record = sample.record, field = item.field, item = field, comparison = item.comparison})
		testing.expectf(t, text == item.sentence, "%s gave the sentence %q", item.field, text)
	}
	accepted := [?]Case{{"level", .Equal, .None, ""}, {"level", .Not_Equal, .None, ""}, {"name", .Equal, .None, ""}, {"number", .Less, .None, ""}, {"key", .Greater_Or_Equal, .None, ""}, {"handle", .Less_Or_Equal, .None, ""}}
	for item in accepted {
		testing.expectf(t, field_check(sample_field(sample, item.field), item.comparison) == .None, "%s %v is refused", item.field, item.comparison)
	}
}

// The member of a status: a name of no member, the case of its letters
// too; a text and a number, which are no names; nothing; then a member,
// which gives its word and the byte after it.
@(test)
the_member_of_a_status_is_a_name :: proc(t: ^testing.T) {
	sample := sample_make(t)
	level := sample_field(sample, "level")
	which, status := field_is_status(level)
	testing.expect(t, status && which == .Log_Level)
	_, number_is_status := field_is_status(sample_field(sample, "number"))
	testing.expect(t, !number_is_status)
	Case :: struct {
		text:     string,
		refusal:  Refusal,
		sentence: string,
	}
	cases := [?]Case {
		{" warning)", .Unknown_Member, "where: the field level holds a member of Log_Level: Info, Debug, Warning, Error; \"warning\" names none"},
		{" WARNING)", .Unknown_Member, "where: the field level holds a member of Log_Level: Info, Debug, Warning, Error; \"WARNING\" names none"},
		{" \"Warning\")", .Member_Is_A_Name, "where: the field level holds a member of Log_Level, and a member is a name, not a text or a number: \"Warning\" is none; the members are Info, Debug, Warning, Error"},
		{" 2)", .Member_Is_A_Name, "where: the field level holds a member of Log_Level, and a member is a name, not a text or a number: 2 is none; the members are Info, Debug, Warning, Error"},
		{" )", .No_Value, "where: the condition on level has no value after its operator ="},
		{"", .No_Value, "where: the condition on level has no value after its operator ="},
	}
	for item in cases {
		word, member, _, refusal := member_read(item.text, 0, which)
		testing.expectf(t, refusal == item.refusal && word == 0, "%q gave %v and the word %d", item.text, refusal, word)
		text := refusal_text(refusal, {command = "where", file = sample.file, record = sample.record, field = "level", item = level, member = member})
		testing.expectf(t, text == item.sentence, "%q gave the sentence %q", item.text, text)
	}
	text := " Warning)"
	word, member, end, refusal := member_read(text, 0, which)
	testing.expect(t, refusal == .None && word == u64(op.Log_Level.Warning) && member == "Warning" && text[end:] == ")")
	last, _, _, last_refusal := member_read(" Error", 0, which)
	testing.expect(t, last_refusal == .None && last == u64(max(op.Log_Level)))
}

// A value of the wrong kind on each kind of field, a negative value on an
// unsigned field, and a value past the bytes of a field, at its edges;
// then the edges that each field holds.
@(test)
a_value_of_another_kind_or_range_is_refused :: proc(t: ^testing.T) {
	sample := sample_make(t)
	Case :: struct {
		field:    string,
		type:     module.Type,
		value:    i64,
		refusal:  Refusal,
		sentence: string,
	}
	cases := [?]Case {
		{"number", .Text, 0, .Wrong_Kind, "where: the field number is Integer, the value is Text"},
		{"key", .Text, 0, .Wrong_Kind, "where: the field key is Integer, the value is Text"},
		{"check", .Text, 0, .Wrong_Kind, "where: the field check is Integer, the value is Text"},
		{"handle", .Text, 0, .Wrong_Kind, "where: the field handle is Handle, the value is Text"},
		{"name", .Integer, 0, .Wrong_Kind, "where: the field name is Text, the value is Integer"},
		{"writer", .Integer, 0, .Wrong_Kind, "where: the field writer is Text, the value is Integer"},
		{"number", .Record, 0, .Wrong_Kind, "where: the field number is Integer, the value is Record"},
		{"name", .Table, 0, .Wrong_Kind, "where: the field name is Text, the value is Table"},
		{"key", .Integer, -1, .Negative_For_Unsigned, "where: the field key is Unsigned, which holds no negative value"},
		{"key", .Integer, min(i64), .Negative_For_Unsigned, "where: the field key is Unsigned, which holds no negative value"},
		{"small", .Integer, -1, .Negative_For_Unsigned, "where: the field small is Unsigned(1), which holds no negative value"},
		{"small", .Integer, 256, .Out_Of_Field, "where: the field small is Unsigned(1), which cannot hold the value"},
		{"check", .Integer, 1 << 32, .Out_Of_Field, "where: the field check is Hexadecimal(4), which cannot hold the value"},
		{"handle", .Integer, -1, .Out_Of_Field, "where: the field handle is Handle, which cannot hold the value"},
		{"handle", .Integer, 1 << 32, .Out_Of_Field, "where: the field handle is Handle, which cannot hold the value"},
	}
	for item in cases {
		field := sample_field(sample, item.field)
		refusal := value_check(field, item.type, item.value)
		testing.expectf(t, refusal == item.refusal, "%s with %v %d gave %v", item.field, item.type, item.value, refusal)
		text := refusal_text(refusal, {command = "where", file = sample.file, record = sample.record, field = item.field, item = field, value_type = item.type})
		testing.expectf(t, text == item.sentence, "%s gave the sentence %q", item.field, text)
	}
	Taken :: struct {
		field: string,
		type:  module.Type,
		value: i64,
	}
	taken := [?]Taken{{"small", .Integer, 0}, {"small", .Integer, 255}, {"check", .Integer, (1 << 32) - 1}, {"number", .Integer, min(i64)}, {"number", .Integer, max(i64)}, {"key", .Integer, max(i64)}, {"handle", .Integer, i64(max(u32))}, {"name", .Text, 0}}
	for item in taken {
		testing.expectf(t, value_check(sample_field(sample, item.field), item.type, item.value) == .None, "%s with %d is refused", item.field, item.value)
	}
}

// The order of the values of fields: an unsigned field of 8 bytes holds
// 2^63 and max(u64), which are past each value of an i64, and `key > 0`
// keeps them; a negative signed value is before an unsigned one; texts
// byte by byte, a shorter one first.
@(test)
unsigned_fields_compare_as_unsigned :: proc(t: ^testing.T) {
	sample := sample_make(t)
	key := sample_field(sample, "key")
	row: [56]u8
	set_key :: proc(row: []u8, value: u64) {
		for index in 0 ..< 8 {
			row[8 + index] = u8(value >> (8 * u64(index)))
		}
	}
	keys := [?]u64{0, 1, 1 << 63, max(u64)}
	for value in keys {
		set_key(row[:], value)
		field, ok := field_value_of(row[:], key)
		testing.expect(t, ok && field.unsigned)
		testing.expectf(t, condition_holds(field, {field = "key", comparison = .Greater, compared = 0}) == (value > 0), "%d > 0", value)
		testing.expectf(t, condition_holds(field, {field = "key", comparison = .Less, compared = 0}) == false, "%d < 0", value)
		testing.expectf(t, condition_holds(field, {field = "key", comparison = .Greater_Or_Equal, compared = max(i64)}) == (value >= 1 << 63), "%d >= max(i64)", value)
		testing.expectf(t, condition_holds(field, {field = "key", comparison = .Equal, compared = i64(value)}), "%d = itself", value)
	}
	largest := Field_Value{integer = transmute(i64)max(u64), unsigned = true}
	half := Field_Value{integer = transmute(i64)u64(1 << 63), unsigned = true}
	testing.expect_value(t, values_compare(largest, half), 1)
	testing.expect_value(t, values_compare(half, largest), -1)
	testing.expect_value(t, values_compare(half, {integer = max(i64)}), 1)
	testing.expect_value(t, values_compare({integer = -1}, {integer = 0, unsigned = true}), -1)
	testing.expect_value(t, values_compare({integer = 0, unsigned = true}, {integer = -1}), 1)
	testing.expect_value(t, values_compare({integer = -1}, {integer = 1}), -1)
	testing.expect_value(t, values_compare({integer = min(i64)}, {integer = min(i64)}), 0)
	testing.expect_value(t, values_compare({is_text = true, text = "ab"}, {is_text = true, text = "abc"}), -1)
	testing.expect_value(t, values_compare({is_text = true, text = "b"}, {is_text = true, text = "abc"}), 1)
	testing.expect_value(t, values_compare({is_text = true, text = ""}, {is_text = true, text = ""}), 0)
	// A field with no compared value gives none.
	_, hash_ok := field_value_of(row[:], sample_field(sample, "module_hash"))
	testing.expect(t, !hash_ok)
}

// The conditions of one line: each one up to the capacity is kept at its
// own address; one more is refused with its sentence, and the list does
// not change.
@(test)
a_line_holds_a_bounded_count_of_conditions :: proc(t: ^testing.T) {
	list := new(Condition_List, context.temp_allocator)
	for index in 0 ..< CONDITION_CAPACITY {
		kept, refusal := condition_keep(list, {field = "number", compared = i64(index)})
		testing.expect(t, refusal == .None && kept != nil && kept.compared == i64(index))
	}
	testing.expect_value(t, list.count, CONDITION_CAPACITY)
	kept, refusal := condition_keep(list, {field = "past"})
	testing.expect(t, refusal == .Too_Many && kept == nil)
	testing.expect_value(t, list.count, CONDITION_CAPACITY)
	testing.expect_value(t, list.items[CONDITION_CAPACITY - 1].compared, i64(CONDITION_CAPACITY - 1))
	testing.expect_value(t, refusal_text(.Too_Many, {}), fmt.tprintf("a line holds at most %d conditions", CONDITION_CAPACITY))
	// No line that runs holds more conditions than the capacity.
	testing.expect(t, (CONDITION_CAPACITY + 1) * CONDITION_BYTES_LEAST > 256)
}
