// Canonical stored type descriptions and domain-separated BLAKE3 description
// hashes (src/md/features/data_evolution.md, "What a stored record carries").
//
// A typed object embeds the canonical binary description of each table with no
// documentation text and no stored hash. Every reader validates the description
// and computes its description hash from those canonical bytes.
//
// This package allocates no memory and imports only contract packages, so the
// kernel, modules, and host tools share one implementation.
package data_evolution

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Domain separation context string for BLAKE3 derive_key over canonical stored
// type descriptions.
DESCRIPTION_HASH_CONTEXT :: "modus stored type v1"

// Byte length of a BLAKE3 hash and of a Hash field.
HASH_SIZE :: blake3.HASH_SIZE

// Fixed capacities keeping every description and plan stack-allocatable with
// zero dynamic allocation.
MAX_NAME_LENGTH :: 48
MAX_FIELDS_PER_TYPE :: 32
MAX_ENUM_MEMBERS_PER_TYPE :: 64
MAX_RECORD_SIZE :: 1024
MAX_CANONICAL_DESCRIPTION_BYTES :: 6144

// The stored type of one field in a record. Zero is unset so an uninitialized
// field description is refused at the border.
Stored_Field_Type :: enum u8 {
	None         = 0, // Unset: refused by description validation.
	Unsigned_Int = 1, // Little-endian unsigned integer of 1, 2, 4, or 8 bytes.
	Signed_Int   = 2, // Little-endian two's-complement signed integer of 1, 2, 4, or 8 bytes.
	Text         = 3, // Fixed-capacity UTF-8 text, zero-padded after the first NUL byte.
	Bytes        = 4, // Fixed-length raw byte sequence.
	Enum         = 5, // Little-endian unsigned integer of 1, 2, 4, or 8 bytes restricted to declared members.
	Hash         = 6, // 32-byte BLAKE3 hash.
}

// How a field is displayed or what semantic unit it carries. Plain and
// Hexadecimal are unitless display kinds; Timestamp_Ms and Size_Pages carry
// semantic units whose change requires a declared migration.
Stored_Field_Kind :: enum u8 {
	Plain        = 0, // Default unitless display for the field's type.
	Hexadecimal  = 1, // Unitless integer displayed in hexadecimal.
	Timestamp_Ms = 2, // Integer counting milliseconds.
	Size_Pages   = 3, // Integer counting 4096-byte pages.
}

// Why a stored type description was refused during validation, encoding, or
// decoding.
Description_Error :: enum u8 {
	None                    = 0,
	Invalid_Type_Name       = 1,
	Invalid_Record_Size     = 2,
	Invalid_Field_Count     = 3,
	Invalid_Field_Name      = 4,
	Duplicate_Field_Name    = 5,
	Invalid_Field_Type      = 6,
	Invalid_Field_Kind      = 7,
	Invalid_Field_Size      = 8,
	Invalid_Field_Alignment = 9,
	Field_Out_Of_Bounds     = 10,
	Field_Overlap_Or_Order  = 11,
	Invalid_Enum_Members    = 12,
	Duplicate_Enum_Member   = 13,
	Enum_Value_Out_Of_Range = 14,
	Buffer_Too_Small        = 15,
	Truncated               = 16,
	Trailing_Bytes          = 17,
}

// One named member of an Enum field in a stored type description.
Stored_Enum_Member :: struct {
	name:        [MAX_NAME_LENGTH]u8,
	name_length: u8,
	value:       u64,
}

// One field in a stored type description.
Stored_Field_Description :: struct {
	name:              [MAX_NAME_LENGTH]u8,
	name_length:       u8,
	field_type:        Stored_Field_Type,
	field_kind:        Stored_Field_Kind,
	offset:            u32,
	size:              u32,
	first_enum_member: u16, // Index into Stored_Type_Description.enum_members for Enum fields; 0 otherwise.
	enum_member_count: u16, // Member count for Enum fields (>= 1); 0 otherwise.
}

// Complete self-contained description of one stored record type, with no
// documentation text and no stored hash.
Stored_Type_Description :: struct {
	name:              [MAX_NAME_LENGTH]u8,
	name_length:       u8,
	record_size:       u32,
	field_count:       u16,
	enum_member_count: u16,
	fields:            [MAX_FIELDS_PER_TYPE]Stored_Field_Description,
	enum_members:      [MAX_ENUM_MEMBERS_PER_TYPE]Stored_Enum_Member,
}

// stored_field_type_of_word converts a wire byte to a Stored_Field_Type at the
// border, refusing unknown values and None.
stored_field_type_of_word :: proc "contextless" (word: u8) -> (field_type: Stored_Field_Type, ok: bool) {
	decoded, known := enum_word.member_of_word(Stored_Field_Type, u64(word))
	if !known || decoded == .None {
		return .None, false
	}
	return decoded, true
}

// stored_field_kind_of_word converts a wire byte to a Stored_Field_Kind at the
// border, refusing unknown values.
stored_field_kind_of_word :: proc "contextless" (word: u8) -> (field_kind: Stored_Field_Kind, ok: bool) {
	return enum_word.member_of_word(Stored_Field_Kind, u64(word))
}

// stored_type_init initializes a Stored_Type_Description with its type name and
// fixed record byte size.
stored_type_init :: proc "contextless" (description: ^Stored_Type_Description, name: string, record_size: u32) -> bool {
	description^ = {}
	if len(name) == 0 || len(name) > MAX_NAME_LENGTH || !text_encoding.identifier_valid(transmute([]u8)name) {
		return false
	}
	if record_size == 0 || record_size > MAX_RECORD_SIZE {
		return false
	}
	copy(description.name[:], name)
	description.name_length = u8(len(name))
	description.record_size = record_size
	return true
}

// stored_type_add_field appends a non-enum field to a Stored_Type_Description.
stored_type_add_field :: proc "contextless" (
	description: ^Stored_Type_Description,
	name: string,
	offset: u32,
	size: u32,
	field_type: Stored_Field_Type,
	field_kind: Stored_Field_Kind = .Plain,
) -> bool {
	if field_type == .Enum || field_type == .None {
		return false
	}
	if int(description.field_count) >= MAX_FIELDS_PER_TYPE {
		return false
	}
	if len(name) == 0 || len(name) > MAX_NAME_LENGTH || !text_encoding.identifier_valid(transmute([]u8)name) {
		return false
	}
	field := &description.fields[description.field_count]
	field^ = {}
	copy(field.name[:], name)
	field.name_length = u8(len(name))
	field.field_type = field_type
	field.field_kind = field_kind
	field.offset = offset
	field.size = size
	description.field_count += 1
	return true
}

// stored_type_add_enum_field appends an Enum field with its declared members to
// a Stored_Type_Description.
stored_type_add_enum_field :: proc "contextless" (
	description: ^Stored_Type_Description,
	name: string,
	offset: u32,
	size: u32,
	members: []Stored_Enum_Member,
) -> bool {
	if int(description.field_count) >= MAX_FIELDS_PER_TYPE {
		return false
	}
	if len(name) == 0 || len(name) > MAX_NAME_LENGTH || !text_encoding.identifier_valid(transmute([]u8)name) {
		return false
	}
	if len(members) == 0 || int(description.enum_member_count) + len(members) > MAX_ENUM_MEMBERS_PER_TYPE {
		return false
	}
	first_member := description.enum_member_count
	for member in members {
		description.enum_members[description.enum_member_count] = member
		description.enum_member_count += 1
	}
	field := &description.fields[description.field_count]
	field^ = {}
	copy(field.name[:], name)
	field.name_length = u8(len(name))
	field.field_type = .Enum
	field.field_kind = .Plain
	field.offset = offset
	field.size = size
	field.first_enum_member = first_member
	field.enum_member_count = u16(len(members))
	description.field_count += 1
	return true
}

// stored_enum_member_build constructs a Stored_Enum_Member from a name and value.
stored_enum_member_build :: proc "contextless" (name: string, value: u64) -> (member: Stored_Enum_Member, ok: bool) {
	if len(name) == 0 || len(name) > MAX_NAME_LENGTH || !text_encoding.identifier_valid(transmute([]u8)name) {
		return {}, false
	}
	copy(member.name[:], name)
	member.name_length = u8(len(name))
	member.value = value
	return member, true
}

// stored_type_name returns the type name slice inside description.
stored_type_name :: proc "contextless" (description: ^Stored_Type_Description) -> string {
	length := min(int(description.name_length), MAX_NAME_LENGTH)
	return string(description.name[:length])
}

// stored_field_name returns the field name slice inside field.
stored_field_name :: proc "contextless" (field: ^Stored_Field_Description) -> string {
	length := min(int(field.name_length), MAX_NAME_LENGTH)
	return string(field.name[:length])
}

// stored_enum_member_name returns the member name slice inside member.
stored_enum_member_name :: proc "contextless" (member: ^Stored_Enum_Member) -> string {
	length := min(int(member.name_length), MAX_NAME_LENGTH)
	return string(member.name[:length])
}

// stored_field_is_integer reports whether field_type is an unsigned or signed integer.
stored_field_is_integer :: proc "contextless" (field_type: Stored_Field_Type) -> bool {
	return field_type == .Unsigned_Int || field_type == .Signed_Int
}

// stored_field_kind_is_unit reports whether field_kind carries a semantic unit
// rather than display-only formatting.
stored_field_kind_is_unit :: proc "contextless" (field_kind: Stored_Field_Kind) -> bool {
	switch field_kind {
	case .Plain, .Hexadecimal:
		return false
	case .Timestamp_Ms, .Size_Pages:
		return true
	}
	return false
}

// fixed_name_valid checks that a fixed-capacity identifier buffer has a valid
// ASCII identifier prefix and zero bytes in every unused trailing slot.
@(private)
fixed_name_valid :: proc "contextless" (storage: ^[MAX_NAME_LENGTH]u8, length: u8) -> bool {
	if length == 0 || int(length) > MAX_NAME_LENGTH {
		return false
	}
	for byte_value in storage[length:] {
		if byte_value != 0 {
			return false
		}
	}
	return text_encoding.identifier_valid(storage[:length])
}

// integer_size_valid checks that an integer or enum field size is 1, 2, 4, or 8 bytes.
@(private)
integer_size_valid :: proc "contextless" (size: u32) -> bool {
	return size == 1 || size == 2 || size == 4 || size == 8
}

// enum_value_fits_backing_size checks that an unsigned enum member value fits
// within size bytes (1, 2, 4, or 8).
@(private)
enum_value_fits_backing_size :: proc "contextless" (size: u32, value: u64) -> bool {
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

// description_alignment returns the required record alignment: the largest size
// among integer and enum fields, at least 1.
description_alignment :: proc "contextless" (description: ^Stored_Type_Description) -> u32 {
	alignment := u32(1)
	count := min(int(description.field_count), MAX_FIELDS_PER_TYPE)
	for index in 0 ..< count {
		field := &description.fields[index]
		switch field.field_type {
		case .Unsigned_Int, .Signed_Int, .Enum:
			if field.size > alignment {
				alignment = field.size
			}
		case .None, .Text, .Bytes, .Hash:
		}
	}
	return alignment
}

// description_validate verifies every structural and semantic invariant of a
// Stored_Type_Description.
description_validate :: proc "contextless" (description: ^Stored_Type_Description) -> Description_Error {
	if !fixed_name_valid(&description.name, description.name_length) {
		return .Invalid_Type_Name
	}
	if description.record_size == 0 || description.record_size > MAX_RECORD_SIZE {
		return .Invalid_Record_Size
	}
	if description.field_count == 0 || int(description.field_count) > MAX_FIELDS_PER_TYPE {
		return .Invalid_Field_Count
	}
	if int(description.enum_member_count) > MAX_ENUM_MEMBERS_PER_TYPE {
		return .Invalid_Enum_Members
	}

	previous_end := u32(0)
	expected_enum_cursor := u16(0)
	max_alignment := u32(1)

	for index in 0 ..< int(description.field_count) {
		field := &description.fields[index]
		if !fixed_name_valid(&field.name, field.name_length) {
			return .Invalid_Field_Name
		}
		field_name := stored_field_name(field)
		for earlier in 0 ..< index {
			if stored_field_name(&description.fields[earlier]) == field_name {
				return .Duplicate_Field_Name
			}
		}

		field_type, type_ok := stored_field_type_of_word(u8(field.field_type))
		if !type_ok {
			return .Invalid_Field_Type
		}
		field_kind, kind_ok := stored_field_kind_of_word(u8(field.field_kind))
		if !kind_ok {
			return .Invalid_Field_Kind
		}

		switch field_type {
		case .None:
			return .Invalid_Field_Type
		case .Unsigned_Int, .Signed_Int:
			if !integer_size_valid(field.size) {
				return .Invalid_Field_Size
			}
			if field.offset % field.size != 0 {
				return .Invalid_Field_Alignment
			}
			if field.size > max_alignment {
				max_alignment = field.size
			}
			if field.first_enum_member != 0 || field.enum_member_count != 0 {
				return .Invalid_Enum_Members
			}
		case .Text, .Bytes:
			if field_kind != .Plain {
				return .Invalid_Field_Kind
			}
			if field.size == 0 || field.size > MAX_RECORD_SIZE {
				return .Invalid_Field_Size
			}
			if field.first_enum_member != 0 || field.enum_member_count != 0 {
				return .Invalid_Enum_Members
			}
		case .Hash:
			if field_kind != .Plain {
				return .Invalid_Field_Kind
			}
			if field.size != HASH_SIZE {
				return .Invalid_Field_Size
			}
			if field.first_enum_member != 0 || field.enum_member_count != 0 {
				return .Invalid_Enum_Members
			}
		case .Enum:
			if field_kind != .Plain {
				return .Invalid_Field_Kind
			}
			if !integer_size_valid(field.size) {
				return .Invalid_Field_Size
			}
			if field.offset % field.size != 0 {
				return .Invalid_Field_Alignment
			}
			if field.size > max_alignment {
				max_alignment = field.size
			}
			if field.enum_member_count == 0 || field.first_enum_member != expected_enum_cursor {
				return .Invalid_Enum_Members
			}
			if u32(field.first_enum_member) + u32(field.enum_member_count) > u32(description.enum_member_count) {
				return .Invalid_Enum_Members
			}
			for member_offset in 0 ..< int(field.enum_member_count) {
				member := &description.enum_members[int(field.first_enum_member) + member_offset]
				if !fixed_name_valid(&member.name, member.name_length) {
					return .Invalid_Enum_Members
				}
				if !enum_value_fits_backing_size(field.size, member.value) {
					return .Enum_Value_Out_Of_Range
				}
				member_name := stored_enum_member_name(member)
				for earlier_offset in 0 ..< member_offset {
					earlier_member := &description.enum_members[int(field.first_enum_member) + earlier_offset]
					if stored_enum_member_name(earlier_member) == member_name || earlier_member.value == member.value {
						return .Duplicate_Enum_Member
					}
				}
			}
			expected_enum_cursor += field.enum_member_count
		}

		if u64(field.offset) + u64(field.size) > u64(description.record_size) {
			return .Field_Out_Of_Bounds
		}
		if field.offset < previous_end {
			return .Field_Overlap_Or_Order
		}
		previous_end = field.offset + field.size
	}

	// Refuse unreferenced enum members in the pool so canonical encoding is unique.
	if expected_enum_cursor != description.enum_member_count {
		return .Invalid_Enum_Members
	}

	// Record size must be a multiple of record alignment so fixed-stride rows stay aligned.
	if description.record_size % max_alignment != 0 {
		return .Invalid_Record_Size
	}

	return .None
}

// description_encoded_size computes the exact byte length of the canonical
// binary encoding of description.
description_encoded_size :: proc "contextless" (description: ^Stored_Type_Description) -> (size: int, err: Description_Error) {
	if validation_err := description_validate(description); validation_err != .None {
		return 0, validation_err
	}
	// Type header: u16 name_len + name + u32 record_size + u16 field_count.
	total := 2 + int(description.name_length) + 4 + 2
	for index in 0 ..< int(description.field_count) {
		field := &description.fields[index]
		// Field: u16 name_len + name + u32 offset + u32 size + u8 type + u8 kind + u16 member_count.
		total += 2 + int(field.name_length) + 4 + 4 + 1 + 1 + 2
		if field.field_type == .Enum {
			for member_offset in 0 ..< int(field.enum_member_count) {
				member := &description.enum_members[int(field.first_enum_member) + member_offset]
				// Member: u16 name_len + name + u64 value.
				total += 2 + int(member.name_length) + 8
			}
		}
	}
	return total, .None
}

// description_encode writes the canonical binary encoding of description into
// out_buffer. On any error, out_buffer is untouched.
description_encode :: proc "contextless" (description: ^Stored_Type_Description, out_buffer: []u8) -> (written: int, err: Description_Error) {
	needed, size_err := description_encoded_size(description)
	if size_err != .None {
		return 0, size_err
	}
	if len(out_buffer) < needed {
		return 0, .Buffer_Too_Small
	}

	cursor := 0
	byte_order.write_u16_little_endian(out_buffer, cursor, u16(description.name_length))
	cursor += 2
	copy(out_buffer[cursor:][:description.name_length], description.name[:description.name_length])
	cursor += int(description.name_length)
	byte_order.write_u32_little_endian(out_buffer, cursor, description.record_size)
	cursor += 4
	byte_order.write_u16_little_endian(out_buffer, cursor, description.field_count)
	cursor += 2

	for index in 0 ..< int(description.field_count) {
		field := &description.fields[index]
		byte_order.write_u16_little_endian(out_buffer, cursor, u16(field.name_length))
		cursor += 2
		copy(out_buffer[cursor:][:field.name_length], field.name[:field.name_length])
		cursor += int(field.name_length)
		byte_order.write_u32_little_endian(out_buffer, cursor, field.offset)
		cursor += 4
		byte_order.write_u32_little_endian(out_buffer, cursor, field.size)
		cursor += 4
		out_buffer[cursor] = u8(field.field_type)
		cursor += 1
		out_buffer[cursor] = u8(field.field_kind)
		cursor += 1
		byte_order.write_u16_little_endian(out_buffer, cursor, field.enum_member_count)
		cursor += 2

		if field.field_type == .Enum {
			for member_offset in 0 ..< int(field.enum_member_count) {
				member := &description.enum_members[int(field.first_enum_member) + member_offset]
				byte_order.write_u16_little_endian(out_buffer, cursor, u16(member.name_length))
				cursor += 2
				copy(out_buffer[cursor:][:member.name_length], member.name[:member.name_length])
				cursor += int(member.name_length)
				byte_order.write_u64_little_endian(out_buffer, cursor, member.value)
				cursor += 8
			}
		}
	}

	return cursor, .None
}

// description_decode parses one canonical stored type description from bytes
// and validates every invariant. It requires bytes to end exactly after the
// description when require_exact_length is true. On error, out_description is
// cleared.
description_decode :: proc "contextless" (
	bytes: []u8,
	out_description: ^Stored_Type_Description,
	require_exact_length: bool = true,
) -> (consumed: int, err: Description_Error) {
	out_description^ = {}
	cursor := 0

	if len(bytes) < 2 {
		return 0, .Truncated
	}
	type_name_length := int(byte_order.read_u16_little_endian(bytes, cursor))
	cursor += 2
	if type_name_length == 0 || type_name_length > MAX_NAME_LENGTH {
		return 0, .Invalid_Type_Name
	}
	if len(bytes) - cursor < type_name_length + 4 + 2 {
		return 0, .Truncated
	}
	copy(out_description.name[:type_name_length], bytes[cursor:][:type_name_length])
	out_description.name_length = u8(type_name_length)
	cursor += type_name_length

	out_description.record_size = byte_order.read_u32_little_endian(bytes, cursor)
	cursor += 4
	field_count := int(byte_order.read_u16_little_endian(bytes, cursor))
	cursor += 2
	if field_count == 0 || field_count > MAX_FIELDS_PER_TYPE {
		out_description^ = {}
		return 0, .Invalid_Field_Count
	}
	out_description.field_count = u16(field_count)

	for index in 0 ..< field_count {
		if len(bytes) - cursor < 2 {
			out_description^ = {}
			return 0, .Truncated
		}
		field_name_length := int(byte_order.read_u16_little_endian(bytes, cursor))
		cursor += 2
		if field_name_length == 0 || field_name_length > MAX_NAME_LENGTH {
			out_description^ = {}
			return 0, .Invalid_Field_Name
		}
		if len(bytes) - cursor < field_name_length + 4 + 4 + 1 + 1 + 2 {
			out_description^ = {}
			return 0, .Truncated
		}

		field := &out_description.fields[index]
		copy(field.name[:field_name_length], bytes[cursor:][:field_name_length])
		field.name_length = u8(field_name_length)
		cursor += field_name_length

		field.offset = byte_order.read_u32_little_endian(bytes, cursor)
		cursor += 4
		field.size = byte_order.read_u32_little_endian(bytes, cursor)
		cursor += 4

		decoded_type, type_ok := stored_field_type_of_word(bytes[cursor])
		cursor += 1
		if !type_ok {
			out_description^ = {}
			return 0, .Invalid_Field_Type
		}
		field.field_type = decoded_type

		decoded_kind, kind_ok := stored_field_kind_of_word(bytes[cursor])
		cursor += 1
		if !kind_ok {
			out_description^ = {}
			return 0, .Invalid_Field_Kind
		}
		field.field_kind = decoded_kind

		member_count := int(byte_order.read_u16_little_endian(bytes, cursor))
		cursor += 2

		if decoded_type != .Enum {
			if member_count != 0 {
				out_description^ = {}
				return 0, .Invalid_Enum_Members
			}
			continue
		}

		if member_count == 0 || int(out_description.enum_member_count) + member_count > MAX_ENUM_MEMBERS_PER_TYPE {
			out_description^ = {}
			return 0, .Invalid_Enum_Members
		}
		field.first_enum_member = out_description.enum_member_count
		field.enum_member_count = u16(member_count)

		for _ in 0 ..< member_count {
			if len(bytes) - cursor < 2 {
				out_description^ = {}
				return 0, .Truncated
			}
			member_name_length := int(byte_order.read_u16_little_endian(bytes, cursor))
			cursor += 2
			if member_name_length == 0 || member_name_length > MAX_NAME_LENGTH {
				out_description^ = {}
				return 0, .Invalid_Enum_Members
			}
			if len(bytes) - cursor < member_name_length + 8 {
				out_description^ = {}
				return 0, .Truncated
			}
			member := &out_description.enum_members[out_description.enum_member_count]
			copy(member.name[:member_name_length], bytes[cursor:][:member_name_length])
			member.name_length = u8(member_name_length)
			cursor += member_name_length
			member.value = byte_order.read_u64_little_endian(bytes, cursor)
			cursor += 8
			out_description.enum_member_count += 1
		}
	}

	if require_exact_length && cursor != len(bytes) {
		out_description^ = {}
		return 0, .Trailing_Bytes
	}

	if validation_err := description_validate(out_description); validation_err != .None {
		out_description^ = {}
		return 0, validation_err
	}

	return cursor, .None
}

// description_hash_of_canonical_bytes computes the domain-separated BLAKE3 hash
// of validated canonical description bytes.
description_hash_of_canonical_bytes :: proc "contextless" (canonical_bytes: []u8) -> blake3.Hash {
	return blake3.derive_key(DESCRIPTION_HASH_CONTEXT, canonical_bytes)
}

// description_hash encodes description canonically and returns its
// domain-separated BLAKE3 description hash.
description_hash :: proc "contextless" (description: ^Stored_Type_Description) -> (hash: blake3.Hash, err: Description_Error) {
	buffer: [MAX_CANONICAL_DESCRIPTION_BYTES]u8
	written, encode_err := description_encode(description, buffer[:])
	if encode_err != .None {
		return {}, encode_err
	}
	return description_hash_of_canonical_bytes(buffer[:written]), .None
}
