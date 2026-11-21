#+build !freestanding
package data_evolution

import "core:testing"
import "modus:contract/blake3"

// Helper: verify every byte of buf equals expected_byte.
@(private = "file")
buffer_all_equal :: proc(buf: []u8, expected_byte: u8) -> bool {
	for value in buf {
		if value != expected_byte {
			return false
		}
	}
	return true
}

// Helper: fill a fixed-capacity Text slice inside a record with ASCII/UTF-8 bytes and zero pad.
@(private = "file")
set_text_field :: proc(record: []u8, offset: u32, size: u32, text: string) {
	field := record[offset:][:size]
	for &byte_value in field {
		byte_value = 0
	}
	copy(field, text)
}

// Helper: construct a minimal valid Stored_Type_Description with one u32 field.
@(private = "file")
make_simple_u32_type :: proc(type_name: string, field_name: string, kind: Stored_Field_Kind = .Plain) -> Stored_Type_Description {
	desc: Stored_Type_Description
	_ = stored_type_init(&desc, type_name, 4)
	_ = stored_type_add_field(&desc, field_name, 0, 4, .Unsigned_Int, kind)
	return desc
}

@(test)
test_description_validation_and_edge_refusals :: proc(t: ^testing.T) {
	// Zero-initialized description must be refused.
	empty_desc: Stored_Type_Description
	testing.expect_value(t, description_validate(&empty_desc), Description_Error.Invalid_Type_Name)

	// Invalid type names: empty, control char, space, non-ASCII, non-zero trailing byte.
	bad_name := make_simple_u32_type("Good", "value")
	bad_name.name_length = 0
	testing.expect_value(t, description_validate(&bad_name), Description_Error.Invalid_Type_Name)

	bad_name = make_simple_u32_type("Good", "value")
	bad_name.name[4] = 'X' // Non-zero trailing byte past name_length.
	testing.expect_value(t, description_validate(&bad_name), Description_Error.Invalid_Type_Name)

	bad_name = make_simple_u32_type("Good", "value")
	bad_name.name[1] = ' ' // Space is not an identifier byte.
	testing.expect_value(t, description_validate(&bad_name), Description_Error.Invalid_Type_Name)

	bad_name = make_simple_u32_type("Good", "value")
	bad_name.name_length = MAX_NAME_LENGTH + 1
	testing.expect_value(t, description_validate(&bad_name), Description_Error.Invalid_Type_Name)

	// Invalid record sizes: 0, MAX_RECORD_SIZE + 1, misaligned with field alignment.
	bad_size := make_simple_u32_type("Good", "value")
	bad_size.record_size = 0
	testing.expect_value(t, description_validate(&bad_size), Description_Error.Invalid_Record_Size)

	bad_size = make_simple_u32_type("Good", "value")
	bad_size.record_size = MAX_RECORD_SIZE + 1
	testing.expect_value(t, description_validate(&bad_size), Description_Error.Invalid_Record_Size)

	bad_size = make_simple_u32_type("Good", "value")
	bad_size.record_size = 6 // Not a multiple of u32 alignment (4).
	testing.expect_value(t, description_validate(&bad_size), Description_Error.Invalid_Record_Size)

	// Field count bounds: 0 and MAX_FIELDS_PER_TYPE + 1.
	bad_count := make_simple_u32_type("Good", "value")
	bad_count.field_count = 0
	testing.expect_value(t, description_validate(&bad_count), Description_Error.Invalid_Field_Count)

	bad_count.field_count = MAX_FIELDS_PER_TYPE + 1
	testing.expect_value(t, description_validate(&bad_count), Description_Error.Invalid_Field_Count)

	// Duplicate field name refused.
	dup_field: Stored_Type_Description
	testing.expect(t, stored_type_init(&dup_field, "Dup", 8))
	testing.expect(t, stored_type_add_field(&dup_field, "same", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&dup_field, "same", 4, 4, .Unsigned_Int))
	testing.expect_value(t, description_validate(&dup_field), Description_Error.Duplicate_Field_Name)

	// Unknown field type byte and .None refused.
	bad_type := make_simple_u32_type("Good", "value")
	bad_type.fields[0].field_type = .None
	testing.expect_value(t, description_validate(&bad_type), Description_Error.Invalid_Field_Type)
	bad_type.fields[0].field_type = Stored_Field_Type(7)
	testing.expect_value(t, description_validate(&bad_type), Description_Error.Invalid_Field_Type)

	// Unknown field kind byte and incompatible kind on Text/Bytes/Hash/Enum.
	bad_kind := make_simple_u32_type("Good", "value")
	bad_kind.fields[0].field_kind = Stored_Field_Kind(4)
	testing.expect_value(t, description_validate(&bad_kind), Description_Error.Invalid_Field_Kind)

	text_hex: Stored_Type_Description
	testing.expect(t, stored_type_init(&text_hex, "Txt", 8))
	testing.expect(t, stored_type_add_field(&text_hex, "label", 0, 8, .Text, .Hexadecimal))
	testing.expect_value(t, description_validate(&text_hex), Description_Error.Invalid_Field_Kind)

	hash_pages: Stored_Type_Description
	testing.expect(t, stored_type_init(&hash_pages, "Hsh", 32))
	testing.expect(t, stored_type_add_field(&hash_pages, "digest", 0, 32, .Hash, .Size_Pages))
	testing.expect_value(t, description_validate(&hash_pages), Description_Error.Invalid_Field_Kind)

	// Invalid sizes: integer size 3, Hash size 16, Text size 0.
	bad_int_size: Stored_Type_Description
	testing.expect(t, stored_type_init(&bad_int_size, "BadInt", 8))
	testing.expect(t, stored_type_add_field(&bad_int_size, "x", 0, 3, .Unsigned_Int))
	testing.expect_value(t, description_validate(&bad_int_size), Description_Error.Invalid_Field_Size)

	bad_hash_size: Stored_Type_Description
	testing.expect(t, stored_type_init(&bad_hash_size, "BadHash", 16))
	testing.expect(t, stored_type_add_field(&bad_hash_size, "h", 0, 16, .Hash))
	testing.expect_value(t, description_validate(&bad_hash_size), Description_Error.Invalid_Field_Size)

	bad_text_size: Stored_Type_Description
	testing.expect(t, stored_type_init(&bad_text_size, "BadText", 8))
	testing.expect(t, stored_type_add_field(&bad_text_size, "s", 0, 0, .Text))
	testing.expect_value(t, description_validate(&bad_text_size), Description_Error.Invalid_Field_Size)

	// Misaligned integer field.
	misaligned: Stored_Type_Description
	testing.expect(t, stored_type_init(&misaligned, "Align", 8))
	testing.expect(t, stored_type_add_field(&misaligned, "a", 0, 1, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&misaligned, "b", 2, 4, .Unsigned_Int))
	testing.expect_value(t, description_validate(&misaligned), Description_Error.Invalid_Field_Alignment)

	// Out-of-bounds field and u32 overflow.
	oob: Stored_Type_Description
	testing.expect(t, stored_type_init(&oob, "Oob", 8))
	testing.expect(t, stored_type_add_field(&oob, "a", 4, 8, .Unsigned_Int))
	testing.expect_value(t, description_validate(&oob), Description_Error.Invalid_Field_Alignment)

	oob2: Stored_Type_Description
	testing.expect(t, stored_type_init(&oob2, "Oob2", 8))
	testing.expect(t, stored_type_add_field(&oob2, "a", 8, 8, .Unsigned_Int))
	testing.expect_value(t, description_validate(&oob2), Description_Error.Field_Out_Of_Bounds)

	// Overlapping and out-of-order fields.
	overlap: Stored_Type_Description
	testing.expect(t, stored_type_init(&overlap, "Overlap", 8))
	testing.expect(t, stored_type_add_field(&overlap, "first", 4, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&overlap, "second", 0, 4, .Unsigned_Int))
	testing.expect_value(t, description_validate(&overlap), Description_Error.Field_Overlap_Or_Order)

	overlap2: Stored_Type_Description
	testing.expect(t, stored_type_init(&overlap2, "Overlap2", 16))
	testing.expect(t, stored_type_add_field(&overlap2, "first", 0, 8, .Bytes))
	testing.expect(t, stored_type_add_field(&overlap2, "second", 4, 4, .Bytes))
	testing.expect_value(t, description_validate(&overlap2), Description_Error.Field_Overlap_Or_Order)

	// Enum validation: 0 members, duplicate name, duplicate value, value out of backing size range.
	empty_enum: Stored_Type_Description
	testing.expect(t, stored_type_init(&empty_enum, "EmptyEnum", 4))
	empty_enum.field_count = 1
	copy(empty_enum.fields[0].name[:], "status")
	empty_enum.fields[0].name_length = 6
	empty_enum.fields[0].field_type = .Enum
	empty_enum.fields[0].offset = 0
	empty_enum.fields[0].size = 4
	testing.expect_value(t, description_validate(&empty_enum), Description_Error.Invalid_Enum_Members)

	m0, _ := stored_enum_member_build("idle", 0)
	m1_dup_val, _ := stored_enum_member_build("busy", 0)
	m1_dup_name, _ := stored_enum_member_build("idle", 1)
	m_oob, _ := stored_enum_member_build("overflow", 256)

	dup_enum_val: Stored_Type_Description
	testing.expect(t, stored_type_init(&dup_enum_val, "DupVal", 1))
	testing.expect(t, stored_type_add_enum_field(&dup_enum_val, "state", 0, 1, {m0, m1_dup_val}))
	testing.expect_value(t, description_validate(&dup_enum_val), Description_Error.Duplicate_Enum_Member)

	dup_enum_name: Stored_Type_Description
	testing.expect(t, stored_type_init(&dup_enum_name, "DupName", 1))
	testing.expect(t, stored_type_add_enum_field(&dup_enum_name, "state", 0, 1, {m0, m1_dup_name}))
	testing.expect_value(t, description_validate(&dup_enum_name), Description_Error.Duplicate_Enum_Member)

	oob_enum: Stored_Type_Description
	testing.expect(t, stored_type_init(&oob_enum, "OobEnum", 1))
	testing.expect(t, stored_type_add_enum_field(&oob_enum, "state", 0, 1, {m0, m_oob}))
	testing.expect_value(t, description_validate(&oob_enum), Description_Error.Enum_Value_Out_Of_Range)
}

@(test)
test_canonical_description_encoding_and_domain_separated_hash :: proc(t: ^testing.T) {
	m_off, _ := stored_enum_member_build("off", 0)
	m_on, _ := stored_enum_member_build("on", 1)

	desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&desc, "SettingsRow", 64))
	testing.expect(t, stored_type_add_field(&desc, "flags", 0, 1, .Unsigned_Int, .Hexadecimal))
	testing.expect(t, stored_type_add_enum_field(&desc, "mode", 2, 2, {m_off, m_on}))
	testing.expect(t, stored_type_add_field(&desc, "updated_ms", 8, 8, .Signed_Int, .Timestamp_Ms))
	testing.expect(t, stored_type_add_field(&desc, "label", 16, 16, .Text))
	testing.expect(t, stored_type_add_field(&desc, "digest", 32, 32, .Hash))
	testing.expect_value(t, description_validate(&desc), Description_Error.None)

	encoded: [MAX_CANONICAL_DESCRIPTION_BYTES]u8
	written, enc_err := description_encode(&desc, encoded[:])
	testing.expect_value(t, enc_err, Description_Error.None)
	testing.expect(t, written > 0)

	// Buffer too small leaves buffer untouched.
	small_buf: [8]u8 = 0xCC
	_, small_err := description_encode(&desc, small_buf[:])
	testing.expect_value(t, small_err, Description_Error.Buffer_Too_Small)
	testing.expect(t, buffer_all_equal(small_buf[:], 0xCC))

	// Decode round-trip.
	decoded: Stored_Type_Description
	consumed, dec_err := description_decode(encoded[:written], &decoded, true)
	testing.expect_value(t, dec_err, Description_Error.None)
	testing.expect_value(t, consumed, written)
	testing.expect(t, decoded == desc)

	// Truncated decode refused at every prefix length.
	for cut in 0 ..< written {
		bad_decoded: Stored_Type_Description
		_, err := description_decode(encoded[:cut], &bad_decoded, true)
		testing.expect(t, err != .None)
		testing.expect_value(t, bad_decoded.field_count, u16(0))
	}

	// Trailing byte refused when require_exact_length is true.
	encoded[written] = 0
	_, trailing_err := description_decode(encoded[:written + 1], &decoded, true)
	testing.expect_value(t, trailing_err, Description_Error.Trailing_Bytes)

	// Domain-separated BLAKE3 hash must match derive_key("modus stored type v1", ...) and differ from plain hash.
	h1, hash_err := description_hash(&desc)
	testing.expect_value(t, hash_err, Description_Error.None)
	expected_derived := blake3.derive_key(DESCRIPTION_HASH_CONTEXT, encoded[:written])
	plain_hash := blake3.hash(encoded[:written])
	testing.expect_value(t, h1, expected_derived)
	testing.expect(t, h1 != plain_hash)

	// Display-only field kind change must still change the description hash.
	desc_plain := desc
	desc_plain.fields[0].field_kind = .Plain
	h2, _ := description_hash(&desc_plain)
	testing.expect(t, h1 != h2)
}

@(test)
test_typed_object_encode_validate_and_adversarial_corruptions :: proc(t: ^testing.T) {
	m_a, _ := stored_enum_member_build("alpha", 1)
	m_b, _ := stored_enum_member_build("beta", 2)

	// Record with explicit alignment padding: u8 at 0, padding [1..4), enum u32 at 4, Text(8) at 8 -> size 16.
	desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&desc, "Item", 16))
	testing.expect(t, stored_type_add_field(&desc, "tag", 0, 1, .Unsigned_Int))
	testing.expect(t, stored_type_add_enum_field(&desc, "state", 4, 4, {m_a, m_b}))
	testing.expect(t, stored_type_add_field(&desc, "name", 8, 8, .Text))
	testing.expect_value(t, description_validate(&desc), Description_Error.None)

	rows: [2 * 16]u8
	// Row 0: tag=42, state=1 ("alpha"), name="café" (5 UTF-8 bytes + 3 zeros).
	rows[0] = 42
	write_unsigned_little_endian(rows[:], 4, 4, 1)
	set_text_field(rows[:16], 8, 8, "café")

	// Row 1: tag=255, state=2 ("beta"), name="12345678" (full to last byte, no NUL).
	rows[16 + 0] = 255
	write_unsigned_little_endian(rows[16:], 4, 4, 2)
	set_text_field(rows[16:32], 8, 8, "12345678")

	tables := []Typed_Table_Input{{description = &desc, record_count = 2, records = rows[:]}}
	obj_buf: [2048]u8
	written, enc_res := typed_object_encode(tables, obj_buf[:])
	testing.expect_value(t, enc_res.err, Object_Error.None)
	testing.expect(t, written > TYPED_OBJECT_HEADER_SIZE)

	// Validate happy path and verify reader-computed hash.
	view, val_res := typed_object_validate(obj_buf[:written])
	testing.expect_value(t, val_res.err, Object_Error.None)
	testing.expect_value(t, view.table_count, u32(1))
	testing.expect_value(t, view.tables[0].record_count, u32(2))
	expected_hash, _ := description_hash(&desc)
	testing.expect_value(t, view.tables[0].description_hash, expected_hash)

	hashes_ok, _ := typed_object_check_expected_hashes(&view, {expected_hash})
	testing.expect(t, hashes_ok)
	wrong_hash := expected_hash
	wrong_hash[0] ~= 0xFF
	hashes_bad, bad_idx := typed_object_check_expected_hashes(&view, {wrong_hash})
	testing.expect(t, !hashes_bad)
	testing.expect_value(t, bad_idx, u32(0))

	// Refusal: truncated header (0, 1, 15 bytes).
	for length in ([]int{0, 1, 15}) {
		_, r := typed_object_validate(obj_buf[:length])
		testing.expect_value(t, r.err, Object_Error.Truncated)
	}

	// Refusal: bad magic.
	corrupt: [2048]u8
	copy(corrupt[:written], obj_buf[:written])
	corrupt[7] = '2'
	_, r_magic := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_magic.err, Object_Error.Bad_Magic)

	// Refusal: unsupported version (0 and 2).
	copy(corrupt[:written], obj_buf[:written])
	write_unsigned_little_endian(corrupt[:], 8, 4, 0)
	_, r_v0 := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_v0.err, Object_Error.Unsupported_Version)
	write_unsigned_little_endian(corrupt[:], 8, 4, 2)
	_, r_v2 := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_v2.err, Object_Error.Unsupported_Version)

	// Refusal: table count 0 and 17.
	copy(corrupt[:written], obj_buf[:written])
	write_unsigned_little_endian(corrupt[:], 12, 4, 0)
	_, r_t0 := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_t0.err, Object_Error.Invalid_Table_Count)
	write_unsigned_little_endian(corrupt[:], 12, 4, MAX_TABLES_PER_OBJECT + 1)
	_, r_t17 := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_t17.err, Object_Error.Invalid_Table_Count)

	// Refusal: trailing byte after valid object.
	copy(corrupt[:written], obj_buf[:written])
	corrupt[written] = 0
	_, r_trail := typed_object_validate(corrupt[:written + 1])
	testing.expect_value(t, r_trail.err, Object_Error.Trailing_Bytes)

	// Refusal: truncated row (missing last byte).
	_, r_trunc_row := typed_object_validate(obj_buf[:written - 1])
	testing.expect_value(t, r_trunc_row.err, Object_Error.Truncated)

	// Refusal: adversarial record_count overflow (0x8000_0001 * 16).
	copy(corrupt[:written], obj_buf[:written])
	record_count_offset := view.tables[0].records_offset - 4
	write_unsigned_little_endian(corrupt[:], record_count_offset, 4, 0x8000_0001)
	_, r_ovf := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_ovf.err, Object_Error.Truncated)

	// Refusal: non-zero padding byte between tag (offset 0) and state (offset 4).
	copy(corrupt[:written], obj_buf[:written])
	corrupt[view.tables[0].records_offset + 2] = 0x01
	_, r_pad := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_pad.err, Object_Error.Non_Zero_Padding)
	testing.expect_value(t, r_pad.record_index, u32(0))

	// Refusal: non-zero byte hidden after NUL inside Text field.
	copy(corrupt[:written], obj_buf[:written])
	corrupt[view.tables[0].records_offset + 8 + 7] = 'Z' // Row 0 "café" ends at byte 5, byte 5 is 0, byte 7 is non-zero!
	_, r_txt_pad := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_txt_pad.err, Object_Error.Non_Zero_Padding)

	// Refusal: invalid UTF-8 byte in Text field.
	copy(corrupt[:written], obj_buf[:written])
	corrupt[view.tables[0].records_offset + 8 + 0] = 0xFF
	_, r_utf8 := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_utf8.err, Object_Error.Invalid_Text_Encoding)

	// Refusal: control character (\n) in Text field.
	copy(corrupt[:written], obj_buf[:written])
	corrupt[view.tables[0].records_offset + 8 + 0] = '\n'
	_, r_ctrl := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_ctrl.err, Object_Error.Invalid_Text_Encoding)

	// Refusal: unknown enum member value (0 is not in {1, 2}, and 99 is not in {1, 2}).
	copy(corrupt[:written], obj_buf[:written])
	write_unsigned_little_endian(corrupt[:], view.tables[0].records_offset + 4, 4, 0)
	_, r_enum0 := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_enum0.err, Object_Error.Unknown_Enum_Value)
	testing.expect_value(t, r_enum0.record_index, u32(0))

	write_unsigned_little_endian(corrupt[:], view.tables[0].records_offset + 16 + 4, 4, 99)
	_, r_enum99 := typed_object_validate(corrupt[:written])
	testing.expect_value(t, r_enum99.err, Object_Error.Unknown_Enum_Value)

	// Refusal: encode refuses invalid record and leaves out_buffer untouched.
	bad_rows := rows
	bad_rows[2] = 0x55 // Non-zero padding in row 0.
	sentinel_buf: [2048]u8 = 0xA5
	_, bad_enc := typed_object_encode({{description = &desc, record_count = 2, records = bad_rows[:]}}, sentinel_buf[:])
	testing.expect_value(t, bad_enc.err, Object_Error.Non_Zero_Padding)
	testing.expect(t, buffer_all_equal(sentinel_buf[:], 0xA5))

	// Refusal: duplicate table names in one object.
	_, dup_enc := typed_object_encode({
		{description = &desc, record_count = 0, records = nil},
		{description = &desc, record_count = 0, records = nil},
	}, sentinel_buf[:])
	testing.expect_value(t, dup_enc.err, Object_Error.Duplicate_Table_Name)
	testing.expect(t, buffer_all_equal(sentinel_buf[:], 0xA5))

	// Boundary: 16 tables (MAX_TABLES_PER_OBJECT) encode and validate cleanly.
	max_descs: [MAX_TABLES_PER_OBJECT]Stored_Type_Description
	max_inputs: [MAX_TABLES_PER_OBJECT]Typed_Table_Input
	names := [MAX_TABLES_PER_OBJECT]string{
		"T00", "T01", "T02", "T03", "T04", "T05", "T06", "T07",
		"T08", "T09", "T10", "T11", "T12", "T13", "T14", "T15",
	}
	for i in 0 ..< MAX_TABLES_PER_OBJECT {
		max_descs[i] = make_simple_u32_type(names[i], "id")
		max_inputs[i] = {description = &max_descs[i], record_count = 0, records = nil}
	}
	max_buf: [4096]u8
	max_written, max_enc_res := typed_object_encode(max_inputs[:], max_buf[:])
	testing.expect_value(t, max_enc_res.err, Object_Error.None)
	max_view, max_val_res := typed_object_validate(max_buf[:max_written])
	testing.expect_value(t, max_val_res.err, Object_Error.None)
	testing.expect_value(t, max_view.table_count, u32(MAX_TABLES_PER_OBJECT))
}

@(test)
test_migration_add_and_remove_fields_with_stated_loss :: proc(t: ^testing.T) {
	// Old: {id: u32, legacy: u32}
	old_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&old_desc, "Account", 8))
	testing.expect(t, stored_type_add_field(&old_desc, "id", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "legacy", 4, 4, .Unsigned_Int))

	// New: {id: u32, quota: u64, note: Text(8)} -> removed "legacy", added "quota" & "note".
	new_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&new_desc, "Account", 24))
	testing.expect(t, stored_type_add_field(&new_desc, "id", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "quota", 8, 8, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "note", 16, 8, .Text))

	// Build 3 old records: row 0 legacy=0, row 1 legacy=77, row 2 legacy=99.
	old_rows: [3 * 8]u8
	write_unsigned_little_endian(old_rows[0:8], 0, 4, 1)
	write_unsigned_little_endian(old_rows[0:8], 4, 4, 0)
	write_unsigned_little_endian(old_rows[8:16], 0, 4, 2)
	write_unsigned_little_endian(old_rows[8:16], 4, 4, 77)
	write_unsigned_little_endian(old_rows[16:24], 0, 4, 3)
	write_unsigned_little_endian(old_rows[16:24], 4, 4, 99)

	old_obj: [1024]u8
	old_len, _ := typed_object_encode({{description = &old_desc, record_count = 3, records = old_rows[:]}}, old_obj[:])

	spec := []Table_Migration_Spec{{old_description = &old_desc, new_description = &new_desc}}

	// Forward: removed "legacy" has 2 non-zero records (row 1 and row 2), 0 for row 0.
	new_obj: [2048]u8
	fwd_res := migration_apply_object(old_obj[:old_len], spec, .Forward, new_obj[:])
	testing.expect_value(t, fwd_res.err, Migration_Apply_Error.None)
	testing.expect_value(t, fwd_res.losses.total_non_zero_values, u64(2))
	testing.expect_value(t, fwd_res.losses.affected_records, u64(2))
	testing.expect_value(t, fwd_res.losses.field_count, u32(1))
	testing.expect_value(t, stated_loss_field_name(&fwd_res.losses.fields[0]), "legacy")
	testing.expect_value(t, fwd_res.losses.fields[0].non_zero_records, u64(2))

	// Validate migrated object and verify added fields are zero-defaulted.
	new_view, new_val := typed_object_validate(new_obj[:fwd_res.bytes_written])
	testing.expect_value(t, new_val.err, Object_Error.None)
	for row_idx in 0 ..< u32(3) {
		row, ok := typed_object_record_at(new_obj[:fwd_res.bytes_written], &new_view, 0, row_idx)
		testing.expect(t, ok)
		testing.expect_value(t, read_unsigned_little_endian(row, 0, 4), u64(row_idx + 1))
		testing.expect_value(t, read_unsigned_little_endian(row, 8, 8), u64(0))
		testing.expect_value(t, text_field_length(row[16:24]), 0)
	}

	// Rollback check right after forward: added fields are all zero -> 0 stated losses!
	rb_zero := migration_check_rollback(new_obj[:fwd_res.bytes_written], spec)
	testing.expect_value(t, rb_zero.err, Migration_Apply_Error.None)
	testing.expect_value(t, rb_zero.losses.total_non_zero_values, u64(0))
	testing.expect_value(t, rb_zero.losses.affected_records, u64(0))
	testing.expect_value(t, rb_zero.losses.field_count, u32(0))

	// Now populate non-zero values in the added fields (quota on row 0, both quota & note on row 2).
	mut_rows: [3 * 24]u8
	raw_new_rows, _ := typed_object_table_records(new_obj[:fwd_res.bytes_written], &new_view, 0)
	copy(mut_rows[:], raw_new_rows)
	write_unsigned_little_endian(mut_rows[0:24], 8, 8, 500)
	write_unsigned_little_endian(mut_rows[48:72], 8, 8, 900)
	set_text_field(mut_rows[48:72], 16, 8, "hello")
	edited_obj: [2048]u8
	edited_len, _ := typed_object_encode({{description = &new_desc, record_count = 3, records = mut_rows[:]}}, edited_obj[:])

	// Pre-flight rollback check reports exact stated losses before principal confirms!
	rb_check := migration_check_rollback(edited_obj[:edited_len], spec)
	testing.expect_value(t, rb_check.err, Migration_Apply_Error.None)
	testing.expect_value(t, rb_check.losses.total_non_zero_values, u64(3)) // 2 quotas + 1 note.
	testing.expect_value(t, rb_check.losses.affected_records, u64(2))      // row 0 and row 2.
	testing.expect_value(t, rb_check.losses.field_count, u32(2))
	testing.expect_value(t, stated_loss_field_name(&rb_check.losses.fields[0]), "quota")
	testing.expect_value(t, rb_check.losses.fields[0].non_zero_records, u64(2))
	testing.expect_value(t, stated_loss_field_name(&rb_check.losses.fields[1]), "note")
	testing.expect_value(t, rb_check.losses.fields[1].non_zero_records, u64(1))

	// Apply backward migration: restores legacy as 0 and keeps id intact.
	rolled_obj: [1024]u8
	bwd_res := migration_apply_object(edited_obj[:edited_len], spec, .Backward, rolled_obj[:])
	testing.expect_value(t, bwd_res.err, Migration_Apply_Error.None)
	testing.expect_value(t, bwd_res.losses.total_non_zero_values, u64(3))
	rolled_view, rolled_val := typed_object_validate(rolled_obj[:bwd_res.bytes_written])
	testing.expect_value(t, rolled_val.err, Object_Error.None)
	for row_idx in 0 ..< u32(3) {
		row, _ := typed_object_record_at(rolled_obj[:bwd_res.bytes_written], &rolled_view, 0, row_idx)
		testing.expect_value(t, read_unsigned_little_endian(row, 0, 4), u64(row_idx + 1))
		testing.expect_value(t, read_unsigned_little_endian(row, 4, 4), u64(0))
	}

	// Edge: adding an Enum field whose members do NOT include 0 must require a declared migration!
	m1, _ := stored_enum_member_build("one", 1)
	m2, _ := stored_enum_member_build("two", 2)
	no_zero_enum_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&no_zero_enum_desc, "Account", 8))
	testing.expect(t, stored_type_add_field(&no_zero_enum_desc, "id", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_enum_field(&no_zero_enum_desc, "tier", 4, 4, {m1, m2}))

	no_zero_plan := migration_plan_derive(&old_desc, &no_zero_enum_desc, {}, .Forward)
	testing.expect_value(t, no_zero_plan.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, no_zero_plan.reason, Migration_Refusal_Reason.Enum_Added_Without_Zero)
}

@(test)
test_migration_rename_move_type_rename_and_meaning_change :: proc(t: ^testing.T) {
	// Old: TypeA {a: u32 @ 0, b: u64 @ 8}
	old_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&old_desc, "TypeA", 16))
	testing.expect(t, stored_type_add_field(&old_desc, "a", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "b", 8, 8, .Unsigned_Int))

	// New: TypeB {y: u64 @ 0, x: u32 @ 8} (moved offsets, renamed fields a->x, b->y, renamed type).
	new_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&new_desc, "TypeB", 16))
	testing.expect(t, stored_type_add_field(&new_desc, "y", 0, 8, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "x", 8, 4, .Unsigned_Int))

	// Row 10: Different type name WITHOUT type_renamed -> meaning change -> Requires_Declared_Migration!
	meaning_fwd := migration_plan_derive(&old_desc, &new_desc, {}, .Forward)
	testing.expect_value(t, meaning_fwd.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, meaning_fwd.reason, Migration_Refusal_Reason.Type_Name_Changed)

	meaning_bwd := migration_plan_derive(&old_desc, &new_desc, {}, .Backward)
	testing.expect_value(t, meaning_bwd.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, meaning_bwd.reason, Migration_Refusal_Reason.Type_Name_Changed)

	// Row 3: With declared type_renamed + field_renames -> Derived in BOTH directions!
	decls := Migration_Declarations {
		type_renamed = true,
		field_renames = {
			{old_name = "a", new_name = "x"},
			{old_name = "b", new_name = "y"},
		},
	}
	fwd_plan := migration_plan_derive(&old_desc, &new_desc, decls, .Forward)
	testing.expect_value(t, fwd_plan.classification, Migration_Classification.Derived)
	testing.expect_value(t, fwd_plan.dropped_count, u16(0))

	bwd_plan := migration_plan_derive(&old_desc, &new_desc, decls, .Backward)
	testing.expect_value(t, bwd_plan.classification, Migration_Classification.Derived)
	testing.expect_value(t, bwd_plan.dropped_count, u16(0))

	src: [16]u8
	write_unsigned_little_endian(src[:], 0, 4, 0x1234_5678)
	write_unsigned_little_endian(src[:], 8, 8, 0xDEAD_BEEF_CAFE_BABE)

	mid: [16]u8
	fwd_err, fwd_loss := migration_apply_record(&fwd_plan, src[:], mid[:])
	testing.expect_value(t, fwd_err, Migration_Apply_Error.None)
	testing.expect_value(t, fwd_loss, u32(0))
	testing.expect_value(t, read_unsigned_little_endian(mid[:], 0, 8), u64(0xDEAD_BEEF_CAFE_BABE))
	testing.expect_value(t, read_unsigned_little_endian(mid[:], 8, 4), u64(0x1234_5678))

	back: [16]u8
	bwd_err, bwd_loss := migration_apply_record(&bwd_plan, mid[:], back[:])
	testing.expect_value(t, bwd_err, Migration_Apply_Error.None)
	testing.expect_value(t, bwd_loss, u32(0))
	testing.expect(t, back == src)

	// Stale type_renamed when names are identical -> Invalid_Declaration.
	same_name_plan := migration_plan_derive(&old_desc, &old_desc, {type_renamed = true}, .Forward)
	testing.expect_value(t, same_name_plan.classification, Migration_Classification.Invalid_Declaration)
	testing.expect_value(t, same_name_plan.reason, Migration_Refusal_Reason.Stale_Or_Missing_Rename)

	// Stale field rename naming a nonexistent field -> Invalid_Declaration.
	stale_field_plan := migration_plan_derive(&old_desc, &new_desc, {
		type_renamed  = true,
		field_renames = {{old_name = "missing", new_name = "x"}},
	}, .Forward)
	testing.expect_value(t, stale_field_plan.classification, Migration_Classification.Invalid_Declaration)
	testing.expect_value(t, stale_field_plan.reason, Migration_Refusal_Reason.Stale_Or_Missing_Rename)
}

@(test)
test_migration_widen_and_checked_backward_narrow_no_clamp_no_cut :: proc(t: ^testing.T) {
	// Old: {u: u8 @ 0, s: i8 @ 1, text: Text(3) @ 2} -> size 5.
	old_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&old_desc, "Widened", 5))
	testing.expect(t, stored_type_add_field(&old_desc, "u", 0, 1, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "s", 1, 1, .Signed_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "text", 2, 3, .Text))

	// New: {u: u32 @ 0, s: i64 @ 8, text: Text(8) @ 16} -> size 24.
	new_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&new_desc, "Widened", 24))
	testing.expect(t, stored_type_add_field(&new_desc, "u", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "s", 8, 8, .Signed_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "text", 16, 8, .Text))

	fwd := migration_plan_derive(&old_desc, &new_desc, {}, .Forward)
	testing.expect_value(t, fwd.classification, Migration_Classification.Derived)

	bwd := migration_plan_derive(&old_desc, &new_desc, {}, .Backward)
	testing.expect_value(t, bwd.classification, Migration_Classification.Derived)

	// Forward widen: u=255 (zero-extended, NOT sign-extended), s=-128 (sign-extended), text="abc".
	old_rec: [5]u8
	old_rec[0] = 255
	write_signed_little_endian(old_rec[:], 1, 1, -128)
	set_text_field(old_rec[:], 2, 3, "abc")

	new_rec: [24]u8
	fwd_err, _ := migration_apply_record(&fwd, old_rec[:], new_rec[:])
	testing.expect_value(t, fwd_err, Migration_Apply_Error.None)
	testing.expect_value(t, read_unsigned_little_endian(new_rec[:], 0, 4), u64(255))
	testing.expect_value(t, read_signed_little_endian(new_rec[:], 8, 8), i64(-128))
	testing.expect_value(t, string(new_rec[16:19]), "abc")
	testing.expect(t, buffer_all_equal(new_rec[19:24], 0))

	// Backward narrow: exact boundary values fit cleanly.
	back_rec: [5]u8
	bwd_err, _ := migration_apply_record(&bwd, new_rec[:], back_rec[:])
	testing.expect_value(t, bwd_err, Migration_Apply_Error.None)
	testing.expect(t, back_rec == old_rec)

	// Backward narrow boundary: s=127 fits i8, u=0 fits u8, text="" fits Text(3).
	edge_fit: [24]u8
	write_unsigned_little_endian(edge_fit[:], 0, 4, 0)
	write_signed_little_endian(edge_fit[:], 8, 8, 127)
	fit_err, _ := migration_apply_record(&bwd, edge_fit[:], back_rec[:])
	testing.expect_value(t, fit_err, Migration_Apply_Error.None)
	testing.expect_value(t, read_signed_little_endian(back_rec[:], 1, 1), i64(127))

	// Refusal 1: Unsigned 300 (and 256) into u8 -> Value_Does_Not_Fit, NO clamp, dst untouched!
	sentinel: [5]u8 = 0x5A
	bad_u := edge_fit
	write_unsigned_little_endian(bad_u[:], 0, 4, 300)
	u_err, _ := migration_apply_record(&bwd, bad_u[:], sentinel[:])
	testing.expect_value(t, u_err, Migration_Apply_Error.Value_Does_Not_Fit)
	testing.expect(t, buffer_all_equal(sentinel[:], 0x5A))

	write_unsigned_little_endian(bad_u[:], 0, 4, 256)
	u256_err, _ := migration_apply_record(&bwd, bad_u[:], sentinel[:])
	testing.expect_value(t, u256_err, Migration_Apply_Error.Value_Does_Not_Fit)
	testing.expect(t, buffer_all_equal(sentinel[:], 0x5A))

	// Refusal 2: Signed 128 and -129 and min(i64) into i8 -> Value_Does_Not_Fit, NO clamp!
	for bad_signed in ([]i64{128, -129, min(i64), max(i64)}) {
		bad_s := edge_fit
		write_signed_little_endian(bad_s[:], 8, 8, bad_signed)
		s_err, _ := migration_apply_record(&bwd, bad_s[:], sentinel[:])
		testing.expect_value(t, s_err, Migration_Apply_Error.Value_Does_Not_Fit)
		testing.expect(t, buffer_all_equal(sentinel[:], 0x5A))
	}

	// Refusal 3: Text "hello" (5 bytes) and "abcd" (4 bytes) into Text(3) -> Value_Does_Not_Fit, NO truncation!
	for bad_text in ([]string{"hello", "abcd"}) {
		bad_t := edge_fit
		set_text_field(bad_t[:], 16, 8, bad_text)
		t_err, _ := migration_apply_record(&bwd, bad_t[:], sentinel[:])
		testing.expect_value(t, t_err, Migration_Apply_Error.Value_Does_Not_Fit)
		testing.expect(t, buffer_all_equal(sentinel[:], 0x5A))
	}
}

@(test)
test_migration_field_kind_display_vs_unit_and_breaking_changes :: proc(t: ^testing.T) {
	// Row 5: Plain <-> Hexadecimal is Derived in BOTH directions.
	plain_u32 := make_simple_u32_type("Metric", "val", .Plain)
	hex_u32 := make_simple_u32_type("Metric", "val", .Hexadecimal)
	testing.expect_value(t, migration_plan_derive(&plain_u32, &hex_u32, {}, .Forward).classification, Migration_Classification.Derived)
	testing.expect_value(t, migration_plan_derive(&plain_u32, &hex_u32, {}, .Backward).classification, Migration_Classification.Derived)
	testing.expect_value(t, migration_plan_derive(&hex_u32, &plain_u32, {}, .Forward).classification, Migration_Classification.Derived)
	testing.expect_value(t, migration_plan_derive(&hex_u32, &plain_u32, {}, .Backward).classification, Migration_Classification.Derived)

	// Row 6 (unit change): Plain <-> Timestamp_Ms, Plain <-> Size_Pages, Timestamp_Ms <-> Size_Pages, Hexadecimal <-> Timestamp_Ms.
	ts_u32 := make_simple_u32_type("Metric", "val", .Timestamp_Ms)
	pages_u32 := make_simple_u32_type("Metric", "val", .Size_Pages)

	unit_pairs := [][2]^Stored_Type_Description{
		{&plain_u32, &ts_u32},
		{&plain_u32, &pages_u32},
		{&ts_u32, &pages_u32},
		{&hex_u32, &ts_u32},
		{&hex_u32, &pages_u32},
	}
	for pair in unit_pairs {
		p_fwd := migration_plan_derive(pair[0], pair[1], {}, .Forward)
		testing.expect_value(t, p_fwd.classification, Migration_Classification.Requires_Declared_Migration)
		testing.expect_value(t, p_fwd.reason, Migration_Refusal_Reason.Field_Unit_Changed)
		p_bwd := migration_plan_derive(pair[0], pair[1], {}, .Backward)
		testing.expect_value(t, p_bwd.classification, Migration_Classification.Requires_Declared_Migration)
		testing.expect_value(t, p_bwd.reason, Migration_Refusal_Reason.Field_Unit_Changed)
	}

	// Row 6 (sign change): Unsigned_Int <-> Signed_Int requires Declared in BOTH directions.
	signed_i32: Stored_Type_Description
	testing.expect(t, stored_type_init(&signed_i32, "Metric", 4))
	testing.expect(t, stored_type_add_field(&signed_i32, "val", 0, 4, .Signed_Int))
	for dir in ([]Migration_Direction{.Forward, .Backward}) {
		p := migration_plan_derive(&plain_u32, &signed_i32, {}, dir)
		testing.expect_value(t, p.classification, Migration_Classification.Requires_Declared_Migration)
		testing.expect_value(t, p.reason, Migration_Refusal_Reason.Field_Sign_Changed)
	}

	// Row 6 (narrow forward): u32 -> u16 and Text(8) -> Text(4) require Declared in BOTH directions!
	small_u16: Stored_Type_Description
	testing.expect(t, stored_type_init(&small_u16, "Metric", 2))
	testing.expect(t, stored_type_add_field(&small_u16, "val", 0, 2, .Unsigned_Int))
	for dir in ([]Migration_Direction{.Forward, .Backward}) {
		p := migration_plan_derive(&plain_u32, &small_u16, {}, dir)
		testing.expect_value(t, p.classification, Migration_Classification.Requires_Declared_Migration)
		testing.expect_value(t, p.reason, Migration_Refusal_Reason.Field_Narrowed)
	}

	text8, text4: Stored_Type_Description
	testing.expect(t, stored_type_init(&text8, "Txt", 8))
	testing.expect(t, stored_type_add_field(&text8, "s", 0, 8, .Text))
	testing.expect(t, stored_type_init(&text4, "Txt", 4))
	testing.expect(t, stored_type_add_field(&text4, "s", 0, 4, .Text))
	for dir in ([]Migration_Direction{.Forward, .Backward}) {
		p := migration_plan_derive(&text8, &text4, {}, dir)
		testing.expect_value(t, p.classification, Migration_Classification.Requires_Declared_Migration)
		testing.expect_value(t, p.reason, Migration_Refusal_Reason.Field_Narrowed)
	}

	// Row 6 (Bytes resize): Bytes(4) -> Bytes(8) is not derived -> Requires_Declared_Migration.
	bytes4, bytes8: Stored_Type_Description
	testing.expect(t, stored_type_init(&bytes4, "Raw", 4))
	testing.expect(t, stored_type_add_field(&bytes4, "b", 0, 4, .Bytes))
	testing.expect(t, stored_type_init(&bytes8, "Raw", 8))
	testing.expect(t, stored_type_add_field(&bytes8, "b", 0, 8, .Bytes))
	testing.expect_value(t, migration_plan_derive(&bytes4, &bytes8, {}, .Forward).classification, Migration_Classification.Requires_Declared_Migration)

	// Row 6 (field type change): Unsigned_Int -> Text.
	u32_as_text: Stored_Type_Description
	testing.expect(t, stored_type_init(&u32_as_text, "Metric", 4))
	testing.expect(t, stored_type_add_field(&u32_as_text, "val", 0, 4, .Text))
	for dir in ([]Migration_Direction{.Forward, .Backward}) {
		p := migration_plan_derive(&plain_u32, &u32_as_text, {}, dir)
		testing.expect_value(t, p.classification, Migration_Classification.Requires_Declared_Migration)
		testing.expect_value(t, p.reason, Migration_Refusal_Reason.Field_Type_Changed)
	}

	// Row 7 (split/merge fields): two old fields mapped to one new field, or one old field mapped to two new fields.
	two_fields: Stored_Type_Description
	testing.expect(t, stored_type_init(&two_fields, "Split", 8))
	testing.expect(t, stored_type_add_field(&two_fields, "first", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&two_fields, "second", 4, 4, .Unsigned_Int))

	one_field := make_simple_u32_type("Split", "combined")

	merge_plan := migration_plan_derive(&two_fields, &one_field, {
		field_renames = {
			{old_name = "first", new_name = "combined"},
			{old_name = "second", new_name = "combined"},
		},
	}, .Forward)
	testing.expect_value(t, merge_plan.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, merge_plan.reason, Migration_Refusal_Reason.Field_Split_Or_Merge)

	split_plan := migration_plan_derive(&one_field, &two_fields, {
		field_renames = {
			{old_name = "combined", new_name = "first"},
			{old_name = "combined", new_name = "second"},
		},
	}, .Forward)
	testing.expect_value(t, split_plan.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, split_plan.reason, Migration_Refusal_Reason.Field_Split_Or_Merge)
}

@(test)
test_migration_enum_add_remove_and_explicit_maps :: proc(t: ^testing.T) {
	m_low, _ := stored_enum_member_build("low", 0)
	m_med, _ := stored_enum_member_build("medium", 1)
	m_high, _ := stored_enum_member_build("high", 2)

	desc_2: Stored_Type_Description
	testing.expect(t, stored_type_init(&desc_2, "Priority", 4))
	testing.expect(t, stored_type_add_enum_field(&desc_2, "level", 0, 4, {m_low, m_med}))

	desc_3: Stored_Type_Description
	testing.expect(t, stored_type_init(&desc_3, "Priority", 4))
	testing.expect(t, stored_type_add_enum_field(&desc_3, "level", 0, 4, {m_low, m_med, m_high}))

	// Row 8: Add member ("high" = 2).
	// Forward: Derived.
	add_fwd := migration_plan_derive(&desc_2, &desc_3, {}, .Forward)
	testing.expect_value(t, add_fwd.classification, Migration_Classification.Derived)

	// Backward WITHOUT map: strictly refused (NEVER silently defaults to member 0!).
	add_bwd_nomap := migration_plan_derive(&desc_2, &desc_3, {}, .Backward)
	testing.expect_value(t, add_bwd_nomap.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, add_bwd_nomap.reason, Migration_Refusal_Reason.Enum_Member_Removed)

	// Backward WITH explicit map (high=2 -> medium=1): Derived and remaps cleanly.
	add_bwd_map := migration_plan_derive(&desc_2, &desc_3, {
		enum_maps = {{field_name = "level", source_value = 2, target_value = 1}},
	}, .Backward)
	testing.expect_value(t, add_bwd_map.classification, Migration_Classification.Derived)

	rec_high, rec_out: [4]u8
	write_unsigned_little_endian(rec_high[:], 0, 4, 2)
	map_err, _ := migration_apply_record(&add_bwd_map, rec_high[:], rec_out[:])
	testing.expect_value(t, map_err, Migration_Apply_Error.None)
	testing.expect_value(t, read_unsigned_little_endian(rec_out[:], 0, 4), u64(1))

	// Backward WITH explicit refusal rule (high=2 -> refuse=true): low/medium pass, high refused!
	add_bwd_refuse := migration_plan_derive(&desc_2, &desc_3, {
		enum_maps = {{field_name = "level", source_value = 2, refuse = true}},
	}, .Backward)
	testing.expect_value(t, add_bwd_refuse.classification, Migration_Classification.Derived)

	rec_med: [4]u8
	write_unsigned_little_endian(rec_med[:], 0, 4, 1)
	ok_err, _ := migration_apply_record(&add_bwd_refuse, rec_med[:], rec_out[:])
	testing.expect_value(t, ok_err, Migration_Apply_Error.None)
	testing.expect_value(t, read_unsigned_little_endian(rec_out[:], 0, 4), u64(1))

	sentinel: [4]u8 = 0xEE
	ref_err, _ := migration_apply_record(&add_bwd_refuse, rec_high[:], sentinel[:])
	testing.expect_value(t, ref_err, Migration_Apply_Error.Refused_Enum_Member)
	testing.expect(t, buffer_all_equal(sentinel[:], 0xEE))

	// Row 9: Remove member ("high" = 2, going desc_3 -> desc_2).
	// Forward WITHOUT map: strictly refused!
	rem_fwd_nomap := migration_plan_derive(&desc_3, &desc_2, {}, .Forward)
	testing.expect_value(t, rem_fwd_nomap.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, rem_fwd_nomap.reason, Migration_Refusal_Reason.Enum_Member_Removed)

	// Backward of removal (desc_2 -> desc_3): Derived!
	rem_bwd := migration_plan_derive(&desc_3, &desc_2, {}, .Backward)
	testing.expect_value(t, rem_bwd.classification, Migration_Classification.Derived)

	// Enum member value changed without map -> Enum_Member_Changed.
	m_med_moved, _ := stored_enum_member_build("medium", 5)
	desc_moved: Stored_Type_Description
	testing.expect(t, stored_type_init(&desc_moved, "Priority", 4))
	testing.expect(t, stored_type_add_enum_field(&desc_moved, "level", 0, 4, {m_low, m_med_moved}))
	moved_plan := migration_plan_derive(&desc_2, &desc_moved, {}, .Forward)
	testing.expect_value(t, moved_plan.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, moved_plan.reason, Migration_Refusal_Reason.Enum_Member_Changed)

	// Enum backing size changed -> Enum_Size_Changed.
	desc_u8: Stored_Type_Description
	testing.expect(t, stored_type_init(&desc_u8, "Priority", 1))
	testing.expect(t, stored_type_add_enum_field(&desc_u8, "level", 0, 1, {m_low, m_med}))
	size_plan := migration_plan_derive(&desc_u8, &desc_2, {}, .Forward)
	testing.expect_value(t, size_plan.classification, Migration_Classification.Requires_Declared_Migration)
	testing.expect_value(t, size_plan.reason, Migration_Refusal_Reason.Enum_Size_Changed)

	// Invalid enum map targeting nonexistent target member -> Invalid_Declaration.
	bad_map := migration_plan_derive(&desc_2, &desc_3, {
		enum_maps = {{field_name = "level", source_value = 2, target_value = 99}},
	}, .Backward)
	testing.expect_value(t, bad_map.classification, Migration_Classification.Invalid_Declaration)
	testing.expect_value(t, bad_map.reason, Migration_Refusal_Reason.Invalid_Enum_Map)
}

@(test)
test_object_migration_fail_closed_and_hash_enforcement :: proc(t: ^testing.T) {
	// Table 0: widens u8 -> u16.
	old_t0, new_t0: Stored_Type_Description
	testing.expect(t, stored_type_init(&old_t0, "Counters", 1))
	testing.expect(t, stored_type_add_field(&old_t0, "count", 0, 1, .Unsigned_Int))
	testing.expect(t, stored_type_init(&new_t0, "Counters", 2))
	testing.expect(t, stored_type_add_field(&new_t0, "count", 0, 2, .Unsigned_Int))

	// Table 1: widens Text(3) -> Text(8) and adds extra u32.
	old_t1, new_t1: Stored_Type_Description
	testing.expect(t, stored_type_init(&old_t1, "Labels", 3))
	testing.expect(t, stored_type_add_field(&old_t1, "name", 0, 3, .Text))
	testing.expect(t, stored_type_init(&new_t1, "Labels", 12))
	testing.expect(t, stored_type_add_field(&new_t1, "name", 0, 8, .Text))
	testing.expect(t, stored_type_add_field(&new_t1, "extra", 8, 4, .Unsigned_Int))

	// Build a 2-table new object where row 0 & 1 fit backward, but row 2 overflows u8 (count=300)!
	t0_rows: [3 * 2]u8
	write_unsigned_little_endian(t0_rows[0:2], 0, 2, 10)
	write_unsigned_little_endian(t0_rows[2:4], 0, 2, 255)
	write_unsigned_little_endian(t0_rows[4:6], 0, 2, 300) // Refuses on backward!

	t1_rows: [1 * 12]u8
	set_text_field(t1_rows[:], 0, 8, "ok")
	write_unsigned_little_endian(t1_rows[:], 8, 4, 42)

	obj_buf: [2048]u8
	obj_len, enc_res := typed_object_encode({
		{description = &new_t0, record_count = 3, records = t0_rows[:]},
		{description = &new_t1, record_count = 1, records = t1_rows[:]},
	}, obj_buf[:])
	testing.expect_value(t, enc_res.err, Object_Error.None)

	specs := []Table_Migration_Spec{
		{old_description = &old_t0, new_description = &new_t0},
		{old_description = &old_t1, new_description = &new_t1},
	}

	// Rollback check catches record 2 of table 0 before confirmation!
	rb_fail := migration_check_rollback(obj_buf[:obj_len], specs)
	testing.expect_value(t, rb_fail.err, Migration_Apply_Error.Value_Does_Not_Fit)
	testing.expect_value(t, rb_fail.table_index, u32(0))
	testing.expect_value(t, rb_fail.record_index, u32(2))

	// Fail-closed: migration_apply_object must leave destination buffer 100% untouched!
	dst: [2048]u8 = 0xA5
	apply_fail := migration_apply_object(obj_buf[:obj_len], specs, .Backward, dst[:])
	testing.expect_value(t, apply_fail.err, Migration_Apply_Error.Value_Does_Not_Fit)
	testing.expect_value(t, apply_fail.table_index, u32(0))
	testing.expect_value(t, apply_fail.record_index, u32(2))
	testing.expect(t, buffer_all_equal(dst[:], 0xA5))

	// Fail-closed: unknown description hash (passing old_t0 as if object were Forward when it's new_t0).
	hash_fail := migration_apply_object(obj_buf[:obj_len], specs, .Forward, dst[:])
	testing.expect_value(t, hash_fail.err, Migration_Apply_Error.Unknown_Description_Hash)
	testing.expect_value(t, hash_fail.table_index, u32(0))
	expected_new_hash, _ := description_hash(&new_t0)
	testing.expect_value(t, hash_fail.mismatched_hash, expected_new_hash)
	testing.expect(t, buffer_all_equal(dst[:], 0xA5))

	// Fail-closed: table count mismatch (split/merge tables).
	count_fail := migration_apply_object(obj_buf[:obj_len], specs[:1], .Backward, dst[:])
	testing.expect_value(t, count_fail.err, Migration_Apply_Error.Table_Count_Mismatch)
	testing.expect(t, buffer_all_equal(dst[:], 0xA5))

	// Fail-closed: corrupt source object never overwrites dst.
	corrupt_obj := obj_buf
	corrupt_obj[0] = 'X'
	corrupt_fail := migration_apply_object(corrupt_obj[:obj_len], specs, .Backward, dst[:])
	testing.expect_value(t, corrupt_fail.err, Migration_Apply_Error.Invalid_Source_Object)
	testing.expect_value(t, corrupt_fail.object_validation.err, Object_Error.Bad_Magic)
	testing.expect(t, buffer_all_equal(dst[:], 0xA5))

	// Fix row 2 so all records fit, then verify Buffer_Too_Small leaves dst untouched, then succeed!
	write_unsigned_little_endian(t0_rows[4:6], 0, 2, 200)
	obj_len, enc_res = typed_object_encode({
		{description = &new_t0, record_count = 3, records = t0_rows[:]},
		{description = &new_t1, record_count = 1, records = t1_rows[:]},
	}, obj_buf[:])
	testing.expect_value(t, enc_res.err, Object_Error.None)

	// Rollback check succeeds and reports the 1 non-zero "extra" dropped in table 1!
	rb_ok := migration_check_rollback(obj_buf[:obj_len], specs)
	testing.expect_value(t, rb_ok.err, Migration_Apply_Error.None)
	testing.expect_value(t, rb_ok.losses.total_non_zero_values, u64(1))
	testing.expect_value(t, rb_ok.losses.field_count, u32(1))
	testing.expect_value(t, rb_ok.losses.fields[0].table_index, u32(1))
	testing.expect_value(t, stated_loss_field_name(&rb_ok.losses.fields[0]), "extra")

	// Tiny buffer leaves dst untouched.
	tiny_dst: [16]u8 = 0xA5
	small_fail := migration_apply_object(obj_buf[:obj_len], specs, .Backward, tiny_dst[:])
	testing.expect_value(t, small_fail.err, Migration_Apply_Error.Buffer_Too_Small)
	testing.expect(t, buffer_all_equal(tiny_dst[:], 0xA5))

	// Full backward apply succeeds and produces a valid MODTYPE1 object matching old_t0 and old_t1 hashes!
	bwd_ok := migration_apply_object(obj_buf[:obj_len], specs, .Backward, dst[:])
	testing.expect_value(t, bwd_ok.err, Migration_Apply_Error.None)
	testing.expect(t, bwd_ok.bytes_written > 0)

	final_view, final_val := typed_object_validate(dst[:bwd_ok.bytes_written])
	testing.expect_value(t, final_val.err, Object_Error.None)
	old_h0, _ := description_hash(&old_t0)
	old_h1, _ := description_hash(&old_t1)
	final_hashes_ok, _ := typed_object_check_expected_hashes(&final_view, {old_h0, old_h1})
	testing.expect(t, final_hashes_ok)

	r0, _ := typed_object_record_at(dst[:bwd_ok.bytes_written], &final_view, 0, 2)
	testing.expect_value(t, read_unsigned_little_endian(r0, 0, 1), u64(200))
	r1, _ := typed_object_record_at(dst[:bwd_ok.bytes_written], &final_view, 1, 0)
	testing.expect_value(t, string(r1[:2]), "ok")
	testing.expect_value(t, r1[2], u8(0))
}

@(test)
test_wire_description_corruptions_inside_typed_object :: proc(t: ^testing.T) {
	// Type "Rec" (3 bytes): header = u16(3)+"Rec"(3)+u32(8)+u16(2) = 11 bytes.
	// Field 0 "a" (1 byte): u16(1)+"a"(1)+u32(offset=0)+u32(size=4)+u8(type=1)+u8(kind=0)+u16(0) = 15 bytes.
	//   Inside description: field 0 offset at byte 14, size at 18, type at 22, kind at 23.
	// Field 1 "b" (1 byte): starts at byte 26; offset at 29, size at 33, type at 37, kind at 38.
	desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&desc, "Rec", 8))
	testing.expect(t, stored_type_add_field(&desc, "a", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&desc, "b", 4, 4, .Unsigned_Int))

	row: [8]u8
	obj: [256]u8
	obj_len, enc_res := typed_object_encode({{description = &desc, record_count = 1, records = row[:]}}, obj[:])
	testing.expect_value(t, enc_res.err, Object_Error.None)

	view, ok_res := typed_object_validate(obj[:obj_len])
	testing.expect_value(t, ok_res.err, Object_Error.None)
	desc_start := int(view.tables[0].description_offset)

	corrupt: [256]u8

	// Corrupt wire field_type byte to 0 (.None), 7 (unknown), and 255 (unknown).
	for bad_type_word in ([]u8{0, 7, 255}) {
		copy(corrupt[:obj_len], obj[:obj_len])
		corrupt[desc_start + 22] = bad_type_word
		_, r := typed_object_validate(corrupt[:obj_len])
		testing.expect_value(t, r.err, Object_Error.Invalid_Description)
		testing.expect_value(t, r.description_err, Description_Error.Invalid_Field_Type)
	}

	// Corrupt wire field_kind byte to 4 and 255 (unknown).
	for bad_kind_word in ([]u8{4, 255}) {
		copy(corrupt[:obj_len], obj[:obj_len])
		corrupt[desc_start + 23] = bad_kind_word
		_, r := typed_object_validate(corrupt[:obj_len])
		testing.expect_value(t, r.err, Object_Error.Invalid_Description)
		testing.expect_value(t, r.description_err, Description_Error.Invalid_Field_Kind)
	}

	// Corrupt field 1 offset to 0 so it overlaps field 0.
	copy(corrupt[:obj_len], obj[:obj_len])
	write_unsigned_little_endian(corrupt[:], u32(desc_start + 29), 4, 0)
	_, r_overlap := typed_object_validate(corrupt[:obj_len])
	testing.expect_value(t, r_overlap.err, Object_Error.Invalid_Description)
	testing.expect_value(t, r_overlap.description_err, Description_Error.Field_Overlap_Or_Order)

	// Corrupt field 1 offset to 8 (out of bounds for record_size=8).
	copy(corrupt[:obj_len], obj[:obj_len])
	write_unsigned_little_endian(corrupt[:], u32(desc_start + 29), 4, 8)
	_, r_oob := typed_object_validate(corrupt[:obj_len])
	testing.expect_value(t, r_oob.err, Object_Error.Invalid_Description)
	testing.expect_value(t, r_oob.description_err, Description_Error.Field_Out_Of_Bounds)
}

@(test)
test_migration_all_integer_widths_utf8_and_swap :: proc(t: ^testing.T) {
	// Test widening u16->u32, u32->u64, i16->i32, i32->i64, and UTF-8 Text(2)->Text(4).
	old_desc, new_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&old_desc, "Widths", 16))
	testing.expect(t, stored_type_add_field(&old_desc, "u16_field", 0, 2, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "i16_field", 2, 2, .Signed_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "u32_field", 4, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "i32_field", 8, 4, .Signed_Int))
	testing.expect(t, stored_type_add_field(&old_desc, "utf8_field", 12, 2, .Text))

	testing.expect(t, stored_type_init(&new_desc, "Widths", 32))
	testing.expect(t, stored_type_add_field(&new_desc, "u16_field", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "i16_field", 4, 4, .Signed_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "u32_field", 8, 8, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "i32_field", 16, 8, .Signed_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "utf8_field", 24, 4, .Text))

	fwd := migration_plan_derive(&old_desc, &new_desc, {}, .Forward)
	bwd := migration_plan_derive(&old_desc, &new_desc, {}, .Backward)
	testing.expect_value(t, fwd.classification, Migration_Classification.Derived)
	testing.expect_value(t, bwd.classification, Migration_Classification.Derived)

	// Extreme valid values: max(u16), min(i16), max(u32), min(i32), 2-byte UTF-8 "é".
	old_rec: [16]u8
	write_unsigned_little_endian(old_rec[:], 0, 2, u64(max(u16)))
	write_signed_little_endian(old_rec[:], 2, 2, i64(min(i16)))
	write_unsigned_little_endian(old_rec[:], 4, 4, u64(max(u32)))
	write_signed_little_endian(old_rec[:], 8, 4, i64(min(i32)))
	set_text_field(old_rec[:], 12, 2, "é")

	new_rec: [32]u8
	fwd_err, _ := migration_apply_record(&fwd, old_rec[:], new_rec[:])
	testing.expect_value(t, fwd_err, Migration_Apply_Error.None)
	testing.expect_value(t, read_unsigned_little_endian(new_rec[:], 0, 4), u64(max(u16)))
	testing.expect_value(t, read_signed_little_endian(new_rec[:], 4, 4), i64(min(i16)))
	testing.expect_value(t, read_unsigned_little_endian(new_rec[:], 8, 8), u64(max(u32)))
	testing.expect_value(t, read_signed_little_endian(new_rec[:], 16, 8), i64(min(i32)))
	testing.expect_value(t, string(new_rec[24:26]), "é")

	back_rec: [16]u8
	bwd_err, _ := migration_apply_record(&bwd, new_rec[:], back_rec[:])
	testing.expect_value(t, bwd_err, Migration_Apply_Error.None)
	testing.expect(t, back_rec == old_rec)

	// One past each bound must fail cleanly with Value_Does_Not_Fit.
	sentinel: [16]u8 = 0x77
	cases := [6][32]u8{new_rec, new_rec, new_rec, new_rec, new_rec, new_rec}
	write_unsigned_little_endian(cases[0][:], 0, 4, u64(max(u16)) + 1)
	write_signed_little_endian(cases[1][:], 4, 4, i64(min(i16)) - 1)
	write_unsigned_little_endian(cases[2][:], 8, 8, u64(max(u32)) + 1)
	write_signed_little_endian(cases[3][:], 16, 8, i64(max(i32)) + 1)
	write_signed_little_endian(cases[4][:], 16, 8, i64(min(i32)) - 1)
	set_text_field(cases[5][:], 24, 4, "é!") // 3 UTF-8 bytes does not fit in Text(2).
	for &bad_case in cases {
		err, _ := migration_apply_record(&bwd, bad_case[:], sentinel[:])
		testing.expect_value(t, err, Migration_Apply_Error.Value_Does_Not_Fit)
		testing.expect(t, buffer_all_equal(sentinel[:], 0x77))
	}

	// Swapping two field names (a <-> b) works in both directions.
	swap_old, swap_new: Stored_Type_Description
	testing.expect(t, stored_type_init(&swap_old, "Pair", 8))
	testing.expect(t, stored_type_add_field(&swap_old, "a", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&swap_old, "b", 4, 4, .Unsigned_Int))
	testing.expect(t, stored_type_init(&swap_new, "Pair", 8))
	testing.expect(t, stored_type_add_field(&swap_new, "a", 0, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&swap_new, "b", 4, 4, .Unsigned_Int))
	swap_plan := migration_plan_derive(&swap_old, &swap_new, {
		field_renames = {{old_name = "a", new_name = "b"}, {old_name = "b", new_name = "a"}},
	}, .Forward)
	testing.expect_value(t, swap_plan.classification, Migration_Classification.Derived)
	p_in, p_out: [8]u8
	write_unsigned_little_endian(p_in[:], 0, 4, 11)
	write_unsigned_little_endian(p_in[:], 4, 4, 22)
	s_err, _ := migration_apply_record(&swap_plan, p_in[:], p_out[:])
	testing.expect_value(t, s_err, Migration_Apply_Error.None)
	testing.expect_value(t, read_unsigned_little_endian(p_out[:], 0, 4), u64(22))
	testing.expect_value(t, read_unsigned_little_endian(p_out[:], 4, 4), u64(11))

	// Executing a non-derived plan must refuse with Plan_Not_Executable and keep dst untouched.
	non_exec := migration_plan_derive(&new_desc, &old_desc, {}, .Forward)
	testing.expect_value(t, non_exec.classification, Migration_Classification.Requires_Declared_Migration)
	ne_err, _ := migration_apply_record(&non_exec, new_rec[:], sentinel[:])
	testing.expect_value(t, ne_err, Migration_Apply_Error.Plan_Not_Executable)
	testing.expect(t, buffer_all_equal(sentinel[:], 0x77))
}

@(test)
test_migration_end_to_end_forward_and_backward_roundtrip :: proc(t: ^testing.T) {
	m_open, _ := stored_enum_member_build("open", 0)
	m_closed, _ := stored_enum_member_build("closed", 1)
	m_archived, _ := stored_enum_member_build("archived", 2)

	old_desc, new_desc: Stored_Type_Description
	testing.expect(t, stored_type_init(&old_desc, "Grant", 48))
	testing.expect(t, stored_type_add_field(&old_desc, "id", 0, 4, .Unsigned_Int, .Plain))
	testing.expect(t, stored_type_add_enum_field(&old_desc, "state", 4, 4, {m_open, m_closed}))
	testing.expect(t, stored_type_add_field(&old_desc, "title", 8, 8, .Text))
	testing.expect(t, stored_type_add_field(&old_desc, "digest", 16, 32, .Hash))

	// New: id changed Plain->Hexadecimal & widened u32->u64, state added "archived"=2,
	// title renamed -> label and widened Text(8)->Text(16), digest moved, added tag u32.
	testing.expect(t, stored_type_init(&new_desc, "Grant", 64))
	testing.expect(t, stored_type_add_field(&new_desc, "id", 0, 8, .Unsigned_Int, .Hexadecimal))
	testing.expect(t, stored_type_add_enum_field(&new_desc, "state", 8, 4, {m_open, m_closed, m_archived}))
	testing.expect(t, stored_type_add_field(&new_desc, "tag", 12, 4, .Unsigned_Int))
	testing.expect(t, stored_type_add_field(&new_desc, "label", 16, 16, .Text))
	testing.expect(t, stored_type_add_field(&new_desc, "digest", 32, 32, .Hash))

	old_row: [48]u8
	write_unsigned_little_endian(old_row[:], 0, 4, 0xCAFE_BABE)
	write_unsigned_little_endian(old_row[:], 4, 4, 1)
	set_text_field(old_row[:], 8, 8, "primary")
	sample_hash := blake3.hash(transmute([]u8)string("modus"))
	copy(old_row[16:48], sample_hash[:])

	old_obj, mid_obj, back_obj: [2048]u8
	old_len, enc_res := typed_object_encode({{description = &old_desc, record_count = 1, records = old_row[:]}}, old_obj[:])
	testing.expect_value(t, enc_res.err, Object_Error.None)

	fwd_specs := []Table_Migration_Spec{{
		old_description = &old_desc,
		new_description = &new_desc,
		declarations    = {field_renames = {{old_name = "title", new_name = "label"}}},
	}}
	fwd_res := migration_apply_object(old_obj[:old_len], fwd_specs, .Forward, mid_obj[:])
	testing.expect_value(t, fwd_res.err, Migration_Apply_Error.None)
	testing.expect_value(t, fwd_res.losses.total_non_zero_values, u64(0))

	// Backward without enum_map refuses because "archived"=2 was added.
	bwd_nomap := migration_check_rollback(mid_obj[:fwd_res.bytes_written], fwd_specs)
	testing.expect_value(t, bwd_nomap.err, Migration_Apply_Error.Requires_Declared_Migration)
	testing.expect_value(t, bwd_nomap.refusal_reason, Migration_Refusal_Reason.Enum_Member_Removed)

	// Backward with explicit enum_map succeeds and reproduces the exact original old_obj bytes!
	bwd_specs := []Table_Migration_Spec{{
		old_description = &old_desc,
		new_description = &new_desc,
		declarations = {
			field_renames = {{old_name = "title", new_name = "label"}},
			enum_maps     = {{field_name = "state", source_value = 2, target_value = 1}},
		},
	}}
	bwd_check := migration_check_rollback(mid_obj[:fwd_res.bytes_written], bwd_specs)
	testing.expect_value(t, bwd_check.err, Migration_Apply_Error.None)
	testing.expect_value(t, bwd_check.losses.total_non_zero_values, u64(0))

	bwd_res := migration_apply_object(mid_obj[:fwd_res.bytes_written], bwd_specs, .Backward, back_obj[:])
	testing.expect_value(t, bwd_res.err, Migration_Apply_Error.None)
	testing.expect_value(t, bwd_res.bytes_written, old_len)
	for i in 0 ..< old_len {
		testing.expect_value(t, back_obj[i], old_obj[i])
	}
}

