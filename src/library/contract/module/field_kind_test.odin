#+build !freestanding
package module

import "core:testing"
import "modus:contract/value_kinds"

// A file with one record of one field, at offset 0, of the size of that
// field: the least file that record_type reads.
@(private = "file")
file_with_one_field :: proc(item: Field, size: u32) -> [dynamic]u8 {
	TABLES :: int(Table_Kind.Fields) + 1
	records_offset := size_of(Header) + TABLES * size_of(Table_Entry)
	fields_offset := records_offset + 2 * size_of(Record)
	file := make([dynamic]u8, fields_offset + 2 * size_of(Field))
	(^Header)(&file[0])^ = {
		magic       = MAGIC,
		version     = VERSION,
		header_size = size_of(Header),
		machine     = .X86_64,
		table_count = u32(TABLES),
	}
	directory := size_of(Header)
	(^Table_Entry)(&file[directory + int(Table_Kind.Records) * size_of(Table_Entry)])^ = {u64(records_offset), 2, size_of(Record)}
	(^Table_Entry)(&file[directory + int(Table_Kind.Fields) * size_of(Table_Entry)])^ = {u64(fields_offset), 2, size_of(Field)}
	(^Record)(&file[records_offset + size_of(Record)])^ = {size = size, first_field = 1, field_count = 1}
	(^Field)(&file[fields_offset + size_of(Field)])^ = item
	return file
}

// A field whose kind or enum names no member, or whose reserved bytes are
// not 0, is refused, and so is the record that holds it: the edges of each
// byte first, one past the last member and the largest byte.
@(test)
a_field_kind_that_names_no_member_is_refused :: proc(t: ^testing.T) {
	plain := Field{type = u8(Type.Integer), detail = 8}
	refused: [dynamic]Field
	defer delete(refused)
	for word in ([3]u8{u8(max(value_kinds.Field_Kind)) + 1, 128, max(u8)}) {
		item := plain
		item.kind = word
		append(&refused, item)
	}
	for word in ([3]u8{u8(max(value_kinds.Contract_Enum)) + 1, 128, max(u8)}) {
		item := plain
		item.kind, item.unsigned, item.contract_enum = u8(value_kinds.Field_Kind.Status), true, word
		append(&refused, item)
	}
	for reserved in ([3][2]u8{{1, 0}, {0, 1}, {max(u8), max(u8)}}) {
		item := plain
		item.reserved = reserved
		append(&refused, item)
	}
	for item in refused {
		testing.expectf(t, !field_kind_valid(item), "the field %v is taken", item)
		file := file_with_one_field(item, 8)
		defer delete(file)
		_, ok := record_type(file[:], 1)
		testing.expectf(t, !ok, "the record of the field %v is taken", item)
	}
	_, kind_ok := field_kind(Field{kind = u8(max(value_kinds.Field_Kind)) + 1})
	_, which_ok := field_contract_enum(Field{contract_enum = u8(max(value_kinds.Contract_Enum)) + 1})
	testing.expect(t, !kind_ok && !which_ok)
}

// A kind on a field of a type that it does not fit is refused: each kind
// on each other type, a unit beside a kind, a Status with a sign or with
// no enum, an enum beside a kind that is not a Status, a Bytes field that
// is not a Hash, and a hash of 0 bytes or one byte past the hash of a
// module. Each refused field makes its record refused.
@(test)
a_field_kind_on_the_wrong_field_is_refused :: proc(t: ^testing.T) {
	HEXADECIMAL :: u8(value_kinds.Field_Kind.Hexadecimal)
	STATUS :: u8(value_kinds.Field_Kind.Status)
	MODULE_NAME :: u8(value_kinds.Field_Kind.Module_Name)
	HASH :: u8(value_kinds.Field_Kind.Hash)
	LEVEL :: u8(value_kinds.Contract_Enum.Log_Level)
	INTEGER :: u8(Type.Integer)
	TEXT :: u8(Type.Text)
	HANDLE :: u8(Type.Handle)
	BYTES :: u8(Type.Bytes)
	refused := [?]Field {
		// Hexadecimal: an Integer only, with no unit.
		{type = TEXT, detail = 8, kind = HEXADECIMAL},
		{type = HANDLE, kind = HEXADECIMAL},
		{type = BYTES, detail = 8, kind = HEXADECIMAL},
		{type = INTEGER, detail = 8, kind = HEXADECIMAL, integer_unit = value_kinds.size_in(.Bytes)},
		{type = INTEGER, detail = 8, kind = HEXADECIMAL, contract_enum = LEVEL},
		// Status: an unsigned Integer with an enum.
		{type = INTEGER, detail = 1, kind = STATUS, contract_enum = LEVEL},
		{type = INTEGER, detail = 1, unsigned = true, kind = STATUS},
		{type = INTEGER, detail = 1, unsigned = true, kind = STATUS, contract_enum = LEVEL, integer_unit = value_kinds.time_in(.Seconds)},
		{type = TEXT, detail = 8, unsigned = true, kind = STATUS, contract_enum = LEVEL},
		{type = BYTES, detail = 8, unsigned = true, kind = STATUS, contract_enum = LEVEL},
		// An enum on a field that is not a Status.
		{type = INTEGER, detail = 1, unsigned = true, contract_enum = LEVEL},
		// Module_Name: a Text only.
		{type = INTEGER, detail = 8, kind = MODULE_NAME},
		{type = BYTES, detail = 8, kind = MODULE_NAME},
		{type = TEXT, detail = 8, kind = MODULE_NAME, contract_enum = LEVEL},
		// Hash: Bytes only, of 1 to 32 bytes.
		{type = TEXT, detail = 8, kind = HASH},
		{type = INTEGER, detail = 8, kind = HASH},
		{type = BYTES, detail = 0, kind = HASH},
		{type = BYTES, detail = value_kinds.HASH_FIELD_BYTES + 1, kind = HASH},
		{type = BYTES, detail = RECORD_SIZE_LIMIT, kind = HASH},
		{type = BYTES, detail = 8, kind = HASH, contract_enum = LEVEL},
		// Bytes with no kind: a reader has no form for them.
		{type = BYTES, detail = 8},
	}
	for item in refused {
		testing.expectf(t, !field_kind_valid(item), "the field %v is taken", item)
		size := max(field_size(item), 1)
		size = (size + 7) / 8 * 8
		file := file_with_one_field(item, size)
		defer delete(file)
		_, ok := record_type(file[:], 1)
		testing.expectf(t, !ok, "the record of the field %v is taken", item)
	}
}

// Two records whose one field differs only by its kind, or only by its
// enum, are not equal: the check of a replacement and of an import
// declaration refuse them.
@(test)
a_field_of_another_kind_is_another_record :: proc(t: ^testing.T) {
	hexadecimal := Field{type = u8(Type.Integer), detail = 4, unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal)}
	plain := hexadecimal
	plain.kind = u8(value_kinds.Field_Kind.Plain)
	level := Field{type = u8(Type.Integer), detail = 4, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Log_Level)}
	status := level
	status.contract_enum = u8(value_kinds.Contract_Enum.Status)
	pairs := [?][2]Field{{hexadecimal, plain}, {level, status}, {level, hexadecimal}}
	for pair in pairs {
		first := file_with_one_field(pair[0], 4)
		defer delete(first)
		second := file_with_one_field(pair[1], 4)
		defer delete(second)
		testing.expectf(t, !records_equal(first[:], 1, second[:], 1), "the fields %v and %v are equal", pair[0], pair[1])
		testing.expect(t, records_equal(first[:], 1, first[:], 1))
	}
}

// field_bytes gives the bytes of a Bytes field, its zero bytes too, and
// nothing for another type or a field past the record.
@(test)
the_bytes_of_a_hash_field_are_whole :: proc(t: ^testing.T) {
	row := [8]u8{0, 1, 0, 2, 0, 0, 3, 0}
	hash := Field{type = u8(Type.Bytes), offset = 2, detail = 4, kind = u8(value_kinds.Field_Kind.Hash)}
	testing.expect_value(t, len(field_bytes(row[:], hash)), 4)
	testing.expect_value(t, field_bytes(row[:], hash)[3], 0)
	past := hash
	past.offset = 5
	testing.expect(t, field_bytes(row[:], past) == nil)
	text := hash
	text.type = u8(Type.Text)
	testing.expect(t, field_bytes(row[:], text) == nil)
	testing.expect_value(t, field_size(hash), 4)
	whole := Field{type = u8(Type.Bytes), detail = value_kinds.HASH_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Hash)}
	file := file_with_one_field(whole, value_kinds.HASH_FIELD_BYTES)
	defer delete(file)
	_, ok := record_type(file[:], 1)
	testing.expect(t, ok)
}

// The pairs of the contract are taken, the last case: each kind on the
// type that it fits, and a zero field, which is a plain Integer of 8
// bytes as before the kinds.
@(test)
each_field_kind_on_its_type_is_taken :: proc(t: ^testing.T) {
	accepted := [?]Field {
		{type = u8(Type.Integer), detail = 8},
		{type = u8(Type.Integer), detail = 8, integer_unit = value_kinds.size_in(.Pages)},
		{type = u8(Type.Text), detail = 8},
		{type = u8(Type.Handle)},
		{type = u8(Type.Integer), detail = 1, kind = u8(value_kinds.Field_Kind.Hexadecimal)},
		{type = u8(Type.Integer), detail = 8, unsigned = true, kind = u8(value_kinds.Field_Kind.Hexadecimal)},
		{type = u8(Type.Integer), detail = 1, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Log_Level)},
		{type = u8(Type.Integer), detail = 4, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Status)},
		{type = u8(Type.Text), detail = value_kinds.MODULE_NAME_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Module_Name)},
		{type = u8(Type.Bytes), detail = 1, kind = u8(value_kinds.Field_Kind.Hash)},
		{type = u8(Type.Bytes), detail = value_kinds.HASH_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Hash)},
	}
	for item in accepted {
		testing.expectf(t, field_kind_valid(item), "the field %v is refused", item)
		size := field_size(item)
		file := file_with_one_field(item, size)
		defer delete(file)
		_, ok := record_type(file[:], 1)
		testing.expectf(t, ok, "the record of the field %v is refused", item)
	}
	testing.expect(t, field_kind_valid(Field{type = u8(Type.Integer)}))
}
