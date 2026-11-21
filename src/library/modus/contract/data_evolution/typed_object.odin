// Self-describing typed object container (`MODTYPE1`) and strict border
// validation (src/md/features/data_evolution.md, "What a stored record carries").
//
// Wire layout (all integers little-endian):
//   Header (16 bytes):
//     [8]u8  magic       = "MODTYPE1"
//     u32    version     = 1
//     u32    table_count = 1..=MAX_TABLES_PER_OBJECT
//   Descriptions section (for each table in 0 ..< table_count):
//     u32    description_byte_length
//     u8[description_byte_length] canonical Stored_Type_Description
//   Records section (for each table in 0 ..< table_count):
//     u32    record_count
//     u8[record_count * record_size] fixed-stride record rows
//
// No trailing bytes are allowed after the last row of the last table. Every
// reader computes each table's description hash from the validated canonical
// description bytes and refuses any record with non-zero padding, invalid UTF-8
// text, or an unknown enum value.
package data_evolution

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/text_encoding"

// Container header constants.
TYPED_OBJECT_MAGIC :: [8]u8{'M', 'O', 'D', 'T', 'Y', 'P', 'E', '1'}
TYPED_OBJECT_VERSION :: u32(1)
TYPED_OBJECT_HEADER_SIZE :: 16
MAX_TABLES_PER_OBJECT :: 16

// Why a typed object or record was refused at the border.
Object_Error :: enum u8 {
	None                  = 0,
	Bad_Magic             = 1,
	Unsupported_Version   = 2,
	Invalid_Table_Count   = 3,
	Truncated             = 4,
	Trailing_Bytes        = 5,
	Invalid_Description   = 6,
	Duplicate_Table_Name  = 7,
	Invalid_Record_Length = 8,
	Non_Zero_Padding      = 9,
	Invalid_Text_Encoding = 10,
	Unknown_Enum_Value    = 11,
	Buffer_Too_Small      = 12,
}

// Detailed outcome of validating or encoding a MODTYPE1 typed object.
Object_Validation_Result :: struct {
	err:               Object_Error,
	description_err:   Description_Error, // Non-.None when err == .Invalid_Description.
	table_index:       u32,               // Failing table index (0-based) when applicable.
	record_index:      u32,               // Failing record index (0-based) when applicable.
	field_index:       u32,               // Failing field index (0-based) when applicable.
}

// Validated slice offsets and computed description hash for one table inside a
// MODTYPE1 byte buffer.
Typed_Table_View :: struct {
	description_offset: u32,
	description_length: u32,
	description_hash:   blake3.Hash, // Computed by the reader, never read from the object.
	record_size:        u32,
	record_count:       u32,
	records_offset:     u32,
	records_length:     u32,
}

// Validated zero-allocation view of a MODTYPE1 typed object.
Typed_Object_View :: struct {
	table_count: u32,
	tables:      [MAX_TABLES_PER_OBJECT]Typed_Table_View,
}

// Caller-supplied table input for typed_object_encode.
Typed_Table_Input :: struct {
	description:  ^Stored_Type_Description,
	record_count: u32,
	records:      []u8, // Must hold exactly record_count * description.record_size bytes.
}

// read_unsigned_little_endian reads a 1, 2, 4, or 8 byte little-endian unsigned
// integer at offset. Caller must have validated bounds and size.
read_unsigned_little_endian :: proc "contextless" (bytes: []u8, offset: u32, size: u32) -> u64 {
	switch size {
	case 1:
		return u64(bytes[offset])
	case 2:
		return u64(byte_order.read_u16_little_endian(bytes, int(offset)))
	case 4:
		return u64(byte_order.read_u32_little_endian(bytes, int(offset)))
	case 8:
		return byte_order.read_u64_little_endian(bytes, int(offset))
	}
	return 0
}

// read_signed_little_endian reads a 1, 2, 4, or 8 byte little-endian signed
// two's-complement integer at offset with exact sign extension.
read_signed_little_endian :: proc "contextless" (bytes: []u8, offset: u32, size: u32) -> i64 {
	switch size {
	case 1:
		return i64(i8(bytes[offset]))
	case 2:
		return i64(i16(byte_order.read_u16_little_endian(bytes, int(offset))))
	case 4:
		return i64(i32(byte_order.read_u32_little_endian(bytes, int(offset))))
	case 8:
		return i64(byte_order.read_u64_little_endian(bytes, int(offset)))
	}
	return 0
}

// write_unsigned_little_endian writes the low size bytes (1, 2, 4, or 8) of
// value in little-endian order at offset.
write_unsigned_little_endian :: proc "contextless" (bytes: []u8, offset: u32, size: u32, value: u64) {
	switch size {
	case 1:
		bytes[offset] = u8(value)
	case 2:
		byte_order.write_u16_little_endian(bytes, int(offset), u16(value))
	case 4:
		byte_order.write_u32_little_endian(bytes, int(offset), u32(value))
	case 8:
		byte_order.write_u64_little_endian(bytes, int(offset), value)
	}
}

// write_signed_little_endian writes the low size bytes (1, 2, 4, or 8) of
// two's-complement value in little-endian order at offset.
write_signed_little_endian :: proc "contextless" (bytes: []u8, offset: u32, size: u32, value: i64) {
	write_unsigned_little_endian(bytes, offset, size, u64(value))
}

// unsigned_fits_in_size reports whether value fits in an unsigned integer of
// size bytes (1, 2, 4, or 8) without truncation.
unsigned_fits_in_size :: proc "contextless" (value: u64, size: u32) -> bool {
	switch size {
	case 1:
		return value <= u64(max(u8))
	case 2:
		return value <= u64(max(u16))
	case 4:
		return value <= u64(max(u32))
	case 8:
		return true
	}
	return false
}

// signed_fits_in_size reports whether value fits in a signed two's-complement
// integer of size bytes (1, 2, 4, or 8) without clamping or wraparound.
signed_fits_in_size :: proc "contextless" (value: i64, size: u32) -> bool {
	switch size {
	case 1:
		return value >= i64(min(i8)) && value <= i64(max(i8))
	case 2:
		return value >= i64(min(i16)) && value <= i64(max(i16))
	case 4:
		return value >= i64(min(i32)) && value <= i64(max(i32))
	case 8:
		return true
	}
	return false
}

// text_field_length returns the byte length before the first NUL byte in a
// fixed-capacity Text field slice.
text_field_length :: proc "contextless" (field_bytes: []u8) -> int {
	for byte_value, index in field_bytes {
		if byte_value == 0 {
			return index
		}
	}
	return len(field_bytes)
}

// enum_field_contains_value reports whether value matches one of the declared
// members of an Enum field in description.
enum_field_contains_value :: proc "contextless" (description: ^Stored_Type_Description, field: ^Stored_Field_Description, value: u64) -> bool {
	if field.field_type != .Enum {
		return false
	}
	start := int(field.first_enum_member)
	end := start + int(field.enum_member_count)
	if end > int(description.enum_member_count) || end > MAX_ENUM_MEMBERS_PER_TYPE {
		return false
	}
	for index in start ..< end {
		if description.enum_members[index].value == value {
			return true
		}
	}
	return false
}

// record_validate_validated checks one fixed-stride record against a
// Stored_Type_Description that has already passed description_validate.
@(private)
record_validate_validated :: proc "contextless" (description: ^Stored_Type_Description, record_bytes: []u8) -> (err: Object_Error, field_index: u32) {
	if len(record_bytes) != int(description.record_size) {
		return .Invalid_Record_Length, 0
	}

	previous_end := u32(0)
	for index in 0 ..< int(description.field_count) {
		field := &description.fields[index]

		// Every padding byte before this field must be zero.
		for pad_offset in previous_end ..< field.offset {
			if record_bytes[pad_offset] != 0 {
				return .Non_Zero_Padding, u32(index)
			}
		}

		field_slice := record_bytes[field.offset:][:field.size]
		switch field.field_type {
		case .None:
			return .Invalid_Description, u32(index)
		case .Unsigned_Int, .Signed_Int, .Bytes, .Hash:
			// Every bit pattern is valid for fixed-size integers, raw bytes, and hashes.
		case .Text:
			text_len := text_field_length(field_slice)
			// Every byte after the first NUL byte must also be zero.
			for trailing_index in text_len ..< len(field_slice) {
				if field_slice[trailing_index] != 0 {
					return .Non_Zero_Padding, u32(index)
				}
			}
			if !text_encoding.text_valid(field_slice[:text_len]) {
				return .Invalid_Text_Encoding, u32(index)
			}
		case .Enum:
			enum_value := read_unsigned_little_endian(record_bytes, field.offset, field.size)
			if !enum_field_contains_value(description, field, enum_value) {
				return .Unknown_Enum_Value, u32(index)
			}
		}

		previous_end = field.offset + field.size
	}

	// Trailing padding bytes after the last field must be zero.
	for pad_offset in previous_end ..< description.record_size {
		if record_bytes[pad_offset] != 0 {
			return .Non_Zero_Padding, u32(description.field_count)
		}
	}

	return .None, 0
}

// record_validate strictly checks one fixed-stride record against a
// Stored_Type_Description: validates the description, verifies zero padding in
// every gap byte, valid UTF-8 with zero trailing padding in Text fields, and
// declared member values in Enum fields.
record_validate :: proc "contextless" (description: ^Stored_Type_Description, record_bytes: []u8) -> (err: Object_Error, field_index: u32) {
	if description == nil || description_validate(description) != .None {
		return .Invalid_Description, 0
	}
	return record_validate_validated(description, record_bytes)
}

// typed_object_encoded_size validates tables and returns the exact byte length
// required to encode them as a MODTYPE1 typed object.
typed_object_encoded_size :: proc "contextless" (tables: []Typed_Table_Input) -> (size: int, result: Object_Validation_Result) {
	if len(tables) == 0 || len(tables) > MAX_TABLES_PER_OBJECT {
		return 0, {err = .Invalid_Table_Count}
	}

	total := u64(TYPED_OBJECT_HEADER_SIZE)
	for table_index in 0 ..< len(tables) {
		table := tables[table_index]
		if table.description == nil {
			return 0, {err = .Invalid_Description, description_err = .Invalid_Type_Name, table_index = u32(table_index)}
		}
		desc_size, desc_err := description_encoded_size(table.description)
		if desc_err != .None {
			return 0, {err = .Invalid_Description, description_err = desc_err, table_index = u32(table_index)}
		}

		table_name := stored_type_name(table.description)
		for earlier in 0 ..< table_index {
			if stored_type_name(tables[earlier].description) == table_name {
				return 0, {err = .Duplicate_Table_Name, table_index = u32(table_index)}
			}
		}

		rows_bytes := u64(table.record_count) * u64(table.description.record_size)
		if rows_bytes != u64(len(table.records)) {
			return 0, {err = .Invalid_Record_Length, table_index = u32(table_index)}
		}

		// Per table: u32 desc_len + desc_bytes + u32 record_count + row_bytes.
		addition := u64(4) + u64(desc_size) + u64(4) + rows_bytes
		if total > u64(max(int)) - addition {
			return 0, {err = .Buffer_Too_Small, table_index = u32(table_index)}
		}
		total += addition
	}

	return int(total), {}
}

// typed_object_encode validates every table description and every record row,
// then encodes a MODTYPE1 typed object into out_buffer. On any validation or
// capacity failure, out_buffer is untouched.
typed_object_encode :: proc "contextless" (tables: []Typed_Table_Input, out_buffer: []u8) -> (written: int, result: Object_Validation_Result) {
	needed, size_result := typed_object_encoded_size(tables)
	if size_result.err != .None {
		return 0, size_result
	}

	// Validate every record before writing any byte to out_buffer (fail-closed).
	for table_index in 0 ..< len(tables) {
		table := tables[table_index]
		stride := int(table.description.record_size)
		for record_index in 0 ..< int(table.record_count) {
			row := table.records[record_index * stride:][:stride]
			row_err, failing_field := record_validate_validated(table.description, row)
			if row_err != .None {
				return 0, {
					err          = row_err,
					table_index  = u32(table_index),
					record_index = u32(record_index),
					field_index  = failing_field,
				}
			}
		}
	}

	if len(out_buffer) < needed {
		return 0, {err = .Buffer_Too_Small}
	}

	// Header.
	magic := TYPED_OBJECT_MAGIC
	copy(out_buffer[0:8], magic[:])
	byte_order.write_u32_little_endian(out_buffer, 8, TYPED_OBJECT_VERSION)
	byte_order.write_u32_little_endian(out_buffer, 12, u32(len(tables)))
	cursor := TYPED_OBJECT_HEADER_SIZE

	// Descriptions section.
	for table_index in 0 ..< len(tables) {
		table := tables[table_index]
		desc_size, _ := description_encoded_size(table.description)
		byte_order.write_u32_little_endian(out_buffer, cursor, u32(desc_size))
		cursor += 4
		encoded_len, _ := description_encode(table.description, out_buffer[cursor:][:desc_size])
		cursor += encoded_len
	}

	// Records section.
	for table_index in 0 ..< len(tables) {
		table := tables[table_index]
		byte_order.write_u32_little_endian(out_buffer, cursor, table.record_count)
		cursor += 4
		if len(table.records) > 0 {
			copy(out_buffer[cursor:][:len(table.records)], table.records)
			cursor += len(table.records)
		}
	}

	return cursor, {}
}

// typed_object_validate strictly checks a raw MODTYPE1 byte buffer, computes
// each table's description hash from its canonical description bytes, validates
// every record row, and refuses trailing bytes. On failure, view is cleared.
typed_object_validate :: proc "contextless" (object_bytes: []u8) -> (view: Typed_Object_View, result: Object_Validation_Result) {
	if u64(len(object_bytes)) > u64(max(u32)) {
		return {}, {err = .Buffer_Too_Small}
	}
	if len(object_bytes) < TYPED_OBJECT_HEADER_SIZE {
		return {}, {err = .Truncated}
	}

	magic := TYPED_OBJECT_MAGIC
	for index in 0 ..< 8 {
		if object_bytes[index] != magic[index] {
			return {}, {err = .Bad_Magic}
		}
	}

	version := byte_order.read_u32_little_endian(object_bytes, 8)
	if version != TYPED_OBJECT_VERSION {
		return {}, {err = .Unsupported_Version}
	}

	table_count := byte_order.read_u32_little_endian(object_bytes, 12)
	if table_count == 0 || table_count > MAX_TABLES_PER_OBJECT {
		return {}, {err = .Invalid_Table_Count}
	}
	view.table_count = table_count

	// Track table names to refuse duplicates within one object.
	table_names: [MAX_TABLES_PER_OBJECT][MAX_NAME_LENGTH]u8
	table_name_lengths: [MAX_TABLES_PER_OBJECT]u8

	cursor := TYPED_OBJECT_HEADER_SIZE
	decoded_description: Stored_Type_Description

	// Pass 1: decode and validate every table description and compute its hash.
	for table_index in 0 ..< int(table_count) {
		if len(object_bytes) - cursor < 4 {
			return {}, {err = .Truncated, table_index = u32(table_index)}
		}
		desc_length := byte_order.read_u32_little_endian(object_bytes, cursor)
		cursor += 4
		if u64(desc_length) > u64(len(object_bytes) - cursor) {
			return {}, {err = .Truncated, table_index = u32(table_index)}
		}
		if desc_length == 0 || desc_length > MAX_CANONICAL_DESCRIPTION_BYTES {
			return {}, {err = .Invalid_Description, description_err = .Truncated, table_index = u32(table_index)}
		}

		desc_slice := object_bytes[cursor:][:desc_length]
		_, desc_err := description_decode(desc_slice, &decoded_description, true)
		if desc_err != .None {
			return {}, {err = .Invalid_Description, description_err = desc_err, table_index = u32(table_index)}
		}

		name := stored_type_name(&decoded_description)
		for earlier in 0 ..< table_index {
			earlier_name := string(table_names[earlier][:table_name_lengths[earlier]])
			if earlier_name == name {
				return {}, {err = .Duplicate_Table_Name, table_index = u32(table_index)}
			}
		}
		copy(table_names[table_index][:], name)
		table_name_lengths[table_index] = u8(len(name))

		view.tables[table_index] = {
			description_offset = u32(cursor),
			description_length = desc_length,
			description_hash   = description_hash_of_canonical_bytes(desc_slice),
			record_size        = decoded_description.record_size,
		}
		cursor += int(desc_length)
	}

	// Pass 2: validate every table's fixed-stride record rows against its description.
	for table_index in 0 ..< int(table_count) {
		table := &view.tables[table_index]
		if len(object_bytes) - cursor < 4 {
			return {}, {err = .Truncated, table_index = u32(table_index)}
		}
		record_count := byte_order.read_u32_little_endian(object_bytes, cursor)
		cursor += 4

		// Multiply in u64 to prevent overflow on adversarial record_count values.
		rows_bytes_u64 := u64(record_count) * u64(table.record_size)
		if rows_bytes_u64 > u64(len(object_bytes) - cursor) {
			return {}, {err = .Truncated, table_index = u32(table_index)}
		}

		desc_slice := object_bytes[table.description_offset:][:table.description_length]
		_, desc_err := description_decode(desc_slice, &decoded_description, true)
		if desc_err != .None {
			return {}, {err = .Invalid_Description, description_err = desc_err, table_index = u32(table_index)}
		}

		stride := int(table.record_size)
		rows_start := cursor
		for record_index in 0 ..< int(record_count) {
			row := object_bytes[rows_start + record_index * stride:][:stride]
			row_err, failing_field := record_validate_validated(&decoded_description, row)
			if row_err != .None {
				return {}, {
					err          = row_err,
					table_index  = u32(table_index),
					record_index = u32(record_index),
					field_index  = failing_field,
				}
			}
		}

		table.record_count = record_count
		table.records_offset = u32(rows_start)
		table.records_length = u32(rows_bytes_u64)
		cursor += int(rows_bytes_u64)
	}

	if cursor != len(object_bytes) {
		return {}, {err = .Trailing_Bytes}
	}

	return view, {}
}

// typed_object_table_description decodes the Stored_Type_Description of table
// table_index from a validated MODTYPE1 object.
typed_object_table_description :: proc "contextless" (
	object_bytes: []u8,
	view: ^Typed_Object_View,
	table_index: u32,
	out_description: ^Stored_Type_Description,
) -> bool {
	if table_index >= view.table_count || table_index >= MAX_TABLES_PER_OBJECT {
		out_description^ = {}
		return false
	}
	table := &view.tables[table_index]
	end := u64(table.description_offset) + u64(table.description_length)
	if end > u64(len(object_bytes)) {
		out_description^ = {}
		return false
	}
	_, err := description_decode(object_bytes[table.description_offset:][:table.description_length], out_description, true)
	return err == .None
}

// typed_object_table_records returns the raw record-rows slice of table
// table_index from a validated MODTYPE1 object.
typed_object_table_records :: proc "contextless" (object_bytes: []u8, view: ^Typed_Object_View, table_index: u32) -> (records: []u8, ok: bool) {
	if table_index >= view.table_count || table_index >= MAX_TABLES_PER_OBJECT {
		return nil, false
	}
	table := &view.tables[table_index]
	end := u64(table.records_offset) + u64(table.records_length)
	if end > u64(len(object_bytes)) {
		return nil, false
	}
	return object_bytes[table.records_offset:][:table.records_length], true
}

// typed_object_record_at returns the slice of one record row from a validated
// MODTYPE1 object.
typed_object_record_at :: proc "contextless" (object_bytes: []u8, view: ^Typed_Object_View, table_index: u32, record_index: u32) -> (row: []u8, ok: bool) {
	if table_index >= view.table_count || table_index >= MAX_TABLES_PER_OBJECT {
		return nil, false
	}
	table := &view.tables[table_index]
	if record_index >= table.record_count {
		return nil, false
	}
	row_offset := u64(table.records_offset) + u64(record_index) * u64(table.record_size)
	if row_offset + u64(table.record_size) > u64(len(object_bytes)) {
		return nil, false
	}
	return object_bytes[row_offset:][:table.record_size], true
}

// typed_object_check_expected_hashes verifies that every table in view has the
// exact expected description hash (computed by the reader).
typed_object_check_expected_hashes :: proc "contextless" (view: ^Typed_Object_View, expected_hashes: []blake3.Hash) -> (ok: bool, mismatched_table: u32) {
	if int(view.table_count) != len(expected_hashes) {
		return false, 0
	}
	for table_index in 0 ..< view.table_count {
		if view.tables[table_index].description_hash != expected_hashes[table_index] {
			return false, table_index
		}
	}
	return true, 0
}
