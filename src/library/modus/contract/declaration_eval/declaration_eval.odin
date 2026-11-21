// Contract between a caller and the sandboxed declaration evaluator
// (src/md/features/declarations.md, "Text stops at the evaluation").
//
// The evaluation process holds no writable store, no network and no root
// ring. Its caller passes a read-only bundle of referenced .lex sources and
// optional tree hash for here(), and receives back either a canonical
// serialized value or a typed refusal with its source place. Every byte that
// crosses the border is validated once before use, and every closed set of
// choices enters through enum_word.member_of_word.
package declaration_eval

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// ---- Read-only input bundle format.

BUNDLE_MAGIC :: u32(0x4244454C) // "LEDB"
BUNDLE_VERSION :: u32(1)
BUNDLE_HEADER_BYTES :: 48
BUNDLE_ENTRY_BYTES :: 56 // kind(1) + pad(3) + path_off(4) + path_len(4) + content_off(4) + content_len(4) + hash(32) + pad(4)
BUNDLE_ENTRY_LIMIT :: 64
BUNDLE_FLAG_HAS_HERE :: u32(1)
DECLARATION_PATH_LIMIT :: 256

// What an entry of an input bundle keys on.
Bundle_Entry_Kind :: enum u8 {
	File_Path        = 1, // A relative .lex file path inside a tree.
	Declaration_Hash = 2, // A 32-byte BLAKE3 hash of a declaration tree.
}

// Why an input bundle is refused at the border.
Bundle_Refusal :: enum u8 {
	None                 = 0,
	Too_Small            = 1,
	Bad_Magic            = 2,
	Bad_Version          = 3,
	Bad_Flags            = 4,
	Too_Many_Entries     = 5,
	Unknown_Entry_Kind   = 6,
	Bad_Reserved         = 7,
	Entry_Out_Of_Bounds  = 8,
	Invalid_Path         = 9,
	Buffer_Too_Small     = 10,
}

// One entry to encode into an input bundle.
Bundle_Input_Entry :: struct {
	kind:    Bundle_Entry_Kind,
	path:    string,
	hash:    blake3.Hash,
	content: string,
}

// declaration_path_valid checks a relative .lex import path inside a tree:
// UTF-8 with no control character, ending in ".lex", non-empty, within
// DECLARATION_PATH_LIMIT, no leading or trailing '/', no "//", no '\\', and
// no "." or ".." segment.
declaration_path_valid :: proc "contextless" (path: string) -> bool {
	if len(path) < len(".lex") + 1 || len(path) > DECLARATION_PATH_LIMIT {
		return false
	}
	if path[len(path) - len(".lex"):] != ".lex" {
		return false
	}
	if !text_encoding.text_valid(transmute([]u8)path) {
		return false
	}
	if path[0] == '/' || path[len(path) - 1] == '/' {
		return false
	}
	segment_start := 0
	for index in 0 ..= len(path) {
		at_end := index == len(path)
		if !at_end && path[index] == '\\' {
			return false
		}
		if at_end || path[index] == '/' {
			segment := path[segment_start:index]
			if len(segment) == 0 || segment == "." || segment == ".." {
				return false
			}
			segment_start = index + 1
		}
	}
	return true
}

// bundle_write encodes a read-only input bundle into destination.
bundle_write :: proc "contextless" (destination: []u8, entries: []Bundle_Input_Entry, has_here: bool = false, here_hash: blake3.Hash = {}) -> (written: int, refusal: Bundle_Refusal) {
	if len(entries) > BUNDLE_ENTRY_LIMIT {
		return 0, .Too_Many_Entries
	}
	table_end := BUNDLE_HEADER_BYTES + len(entries) * BUNDLE_ENTRY_BYTES
	total := table_end
	for entry in entries {
		switch entry.kind {
		case .File_Path:
			if !declaration_path_valid(entry.path) {
				return 0, .Invalid_Path
			}
			total += len(entry.path)
		case .Declaration_Hash:
		}
		total += len(entry.content)
	}
	if total > len(destination) {
		return 0, .Buffer_Too_Small
	}
	for &b in destination[:table_end] {
		b = 0
	}
	byte_order.write_u32_little_endian(destination, 0, BUNDLE_MAGIC)
	byte_order.write_u32_little_endian(destination, 4, BUNDLE_VERSION)
	byte_order.write_u32_little_endian(destination, 8, u32(len(entries)))
	byte_order.write_u32_little_endian(destination, 12, has_here ? BUNDLE_FLAG_HAS_HERE : 0)
	if has_here {
		here := here_hash
		copy(destination[16:48], here[:])
	}
	cursor := table_end
	for entry, index in entries {
		offset := BUNDLE_HEADER_BYTES + index * BUNDLE_ENTRY_BYTES
		destination[offset] = u8(entry.kind)
		switch entry.kind {
		case .File_Path:
			path_offset := u32(cursor)
			copy(destination[cursor:], entry.path)
			cursor += len(entry.path)
			byte_order.write_u32_little_endian(destination, offset + 4, path_offset)
			byte_order.write_u32_little_endian(destination, offset + 8, u32(len(entry.path)))
		case .Declaration_Hash:
			entry_hash := entry.hash
			copy(destination[offset + 20:offset + 52], entry_hash[:])
		}
		content_offset := u32(cursor)
		copy(destination[cursor:], entry.content)
		cursor += len(entry.content)
		byte_order.write_u32_little_endian(destination, offset + 12, content_offset)
		byte_order.write_u32_little_endian(destination, offset + 16, u32(len(entry.content)))
	}
	return cursor, .None
}

// range_fits checks that [offset, offset + length) lies inside total without
// integer overflow and starts at or after min_offset.
@(private)
range_fits :: proc "contextless" (offset, length: u32, min_offset, total: int) -> bool {
	if int(offset) < min_offset || int(offset) > total {
		return false
	}
	return int(length) <= total - int(offset)
}

// bundle_validate validates a read-only input bundle at the border: magic,
// version, unknown flags, entry count, reserved bytes, entry kind enum,
// path validity, and payload bounds.
bundle_validate :: proc "contextless" (bytes: []u8) -> Bundle_Refusal {
	if len(bytes) < BUNDLE_HEADER_BYTES {
		return .Too_Small
	}
	if byte_order.read_u32_little_endian(bytes, 0) != BUNDLE_MAGIC {
		return .Bad_Magic
	}
	if byte_order.read_u32_little_endian(bytes, 4) != BUNDLE_VERSION {
		return .Bad_Version
	}
	entry_count := byte_order.read_u32_little_endian(bytes, 8)
	if entry_count > BUNDLE_ENTRY_LIMIT {
		return .Too_Many_Entries
	}
	flags := byte_order.read_u32_little_endian(bytes, 12)
	if (flags & ~BUNDLE_FLAG_HAS_HERE) != 0 {
		return .Bad_Flags
	}
	table_end := BUNDLE_HEADER_BYTES + int(entry_count) * BUNDLE_ENTRY_BYTES
	if len(bytes) < table_end {
		return .Entry_Out_Of_Bounds
	}
	for index in 0 ..< int(entry_count) {
		offset := BUNDLE_HEADER_BYTES + index * BUNDLE_ENTRY_BYTES
		kind, kind_ok := enum_word.member_of_word(Bundle_Entry_Kind, u64(bytes[offset]))
		if !kind_ok {
			return .Unknown_Entry_Kind
		}
		if bytes[offset + 1] != 0 || bytes[offset + 2] != 0 || bytes[offset + 3] != 0 || byte_order.read_u32_little_endian(bytes, offset + 52) != 0 {
			return .Bad_Reserved
		}
		path_off := byte_order.read_u32_little_endian(bytes, offset + 4)
		path_len := byte_order.read_u32_little_endian(bytes, offset + 8)
		content_off := byte_order.read_u32_little_endian(bytes, offset + 12)
		content_len := byte_order.read_u32_little_endian(bytes, offset + 16)
		if !range_fits(content_off, content_len, table_end, len(bytes)) {
			return .Entry_Out_Of_Bounds
		}
		switch kind {
		case .File_Path:
			if !range_fits(path_off, path_len, table_end, len(bytes)) {
				return .Entry_Out_Of_Bounds
			}
			path := string(bytes[int(path_off):int(path_off) + int(path_len)])
			if !declaration_path_valid(path) {
				return .Invalid_Path
			}
		case .Declaration_Hash:
			if path_off != 0 || path_len != 0 {
				return .Bad_Reserved
			}
		}
	}
	return .None
}

// bundle_here_hash gives the source tree hash carried by a validated bundle.
bundle_here_hash :: proc "contextless" (bytes: []u8) -> (hash: blake3.Hash, has_here: bool) {
	if len(bytes) < BUNDLE_HEADER_BYTES {
		return {}, false
	}
	flags := byte_order.read_u32_little_endian(bytes, 12)
	if (flags & BUNDLE_FLAG_HAS_HERE) == 0 {
		return {}, false
	}
	copy(hash[:], bytes[16:48])
	return hash, true
}

// bundle_lookup_path finds a .lex file entry by relative path in a validated bundle.
bundle_lookup_path :: proc "contextless" (bytes: []u8, path: string) -> (content: string, found: bool) {
	if len(bytes) < BUNDLE_HEADER_BYTES {
		return "", false
	}
	entry_count := int(min(byte_order.read_u32_little_endian(bytes, 8), BUNDLE_ENTRY_LIMIT))
	for index in 0 ..< entry_count {
		offset := BUNDLE_HEADER_BYTES + index * BUNDLE_ENTRY_BYTES
		if offset + BUNDLE_ENTRY_BYTES > len(bytes) {
			return "", false
		}
		if bytes[offset] != u8(Bundle_Entry_Kind.File_Path) {
			continue
		}
		path_off := int(byte_order.read_u32_little_endian(bytes, offset + 4))
		path_len := int(byte_order.read_u32_little_endian(bytes, offset + 8))
		if path_off + path_len > len(bytes) {
			continue
		}
		if string(bytes[path_off:path_off + path_len]) != path {
			continue
		}
		content_off := int(byte_order.read_u32_little_endian(bytes, offset + 12))
		content_len := int(byte_order.read_u32_little_endian(bytes, offset + 16))
		if content_off + content_len > len(bytes) {
			return "", false
		}
		return string(bytes[content_off:content_off + content_len]), true
	}
	return "", false
}

// bundle_lookup_hash finds a declaration entry by BLAKE3 hash in a validated bundle.
bundle_lookup_hash :: proc "contextless" (bytes: []u8, hash: blake3.Hash) -> (content: string, found: bool) {
	if len(bytes) < BUNDLE_HEADER_BYTES {
		return "", false
	}
	entry_count := int(min(byte_order.read_u32_little_endian(bytes, 8), BUNDLE_ENTRY_LIMIT))
	for index in 0 ..< entry_count {
		offset := BUNDLE_HEADER_BYTES + index * BUNDLE_ENTRY_BYTES
		if offset + BUNDLE_ENTRY_BYTES > len(bytes) {
			return "", false
		}
		if bytes[offset] != u8(Bundle_Entry_Kind.Declaration_Hash) {
			continue
		}
		entry_hash: blake3.Hash
		copy(entry_hash[:], bytes[offset + 20:offset + 52])
		if entry_hash != hash {
			continue
		}
		content_off := int(byte_order.read_u32_little_endian(bytes, offset + 12))
		content_len := int(byte_order.read_u32_little_endian(bytes, offset + 16))
		if content_off + content_len > len(bytes) {
			return "", false
		}
		return string(bytes[content_off:content_off + content_len]), true
	}
	return "", false
}

// ---- Canonical output value format.

OUTPUT_MAGIC :: u32(0x4F44454C) // "LEDO"
OUTPUT_VERSION :: u32(1)
OUTPUT_HEADER_BYTES :: 24
OUTPUT_DEPTH_LIMIT :: 64
OUTPUT_COLLECTION_LIMIT :: 4096

// Whether an evaluation succeeded or was refused.
Output_Status :: enum u8 {
	Ok      = 1,
	Refused = 2,
}

// Typed failure classification at the evaluation border.
Failure_Kind :: enum u8 {
	None                 = 0,
	Parse_Error          = 1,
	Cycle_Detected       = 2,
	Step_Bound_Reached   = 3,
	Depth_Bound_Reached  = 4,
	Stack_Bound_Reached  = 5,
	Effect_Refused       = 6,
	Unknown_Name         = 7,
	Unknown_Command      = 8,
	Type_Error           = 9,
	Field_Unknown        = 10,
	Division_By_Zero     = 11,
	Overflow             = 12,
	Import_Path_Refused  = 13,
	Import_Not_Found     = 14,
	Pool_Exhausted       = 15,
	Unserializable_Value = 16,
}

// Canonical value tags in the output buffer.
Value_Tag :: enum u8 {
	Integer    = 1,
	Boolean    = 2,
	Text       = 3,
	Hash       = 4,
	Member     = 5,
	Module_Ref = 6,
	Recipe_Ref = 7,
	Follow_Ref = 8,
	Store_Ref  = 9,
	List       = 10,
	Record     = 11,
	Plan       = 12,
	Project    = 13,
}

// Why an output buffer is refused by a reader.
Output_Refusal :: enum u8 {
	None                  = 0,
	Too_Small             = 1,
	Bad_Magic             = 2,
	Bad_Version           = 3,
	Unknown_Status        = 4,
	Unknown_Failure_Kind  = 5,
	Bad_Reserved          = 6,
	Unknown_Value_Tag     = 7,
	Truncated             = 8,
	Bad_Boolean           = 9,
	Invalid_Text          = 10,
	Depth_Limit_Exceeded  = 11,
	Count_Limit_Exceeded  = 12,
	Unsorted_Record       = 13,
	Trailing_Bytes        = 14,
}

// Decoded output header.
Output_Header :: struct {
	status:       Output_Status,
	failure_kind: Failure_Kind,
	steps_taken:  u32,
	line:         u32,
	column:       u32,
}

// Sequential canonical output writer over a caller-owned buffer.
Output_Writer :: struct {
	buffer:   []u8,
	written:  int,
	overflow: bool,
}

output_writer_start :: proc "contextless" (buffer: []u8, header: Output_Header) -> (writer: Output_Writer) {
	writer.buffer = buffer
	if len(buffer) < OUTPUT_HEADER_BYTES {
		writer.overflow = true
		return writer
	}
	byte_order.write_u32_little_endian(buffer, 0, OUTPUT_MAGIC)
	byte_order.write_u32_little_endian(buffer, 4, OUTPUT_VERSION)
	buffer[8] = u8(header.status)
	buffer[9] = u8(header.failure_kind)
	byte_order.write_u16_little_endian(buffer, 10, 0)
	byte_order.write_u32_little_endian(buffer, 12, header.steps_taken)
	byte_order.write_u32_little_endian(buffer, 16, header.line)
	byte_order.write_u32_little_endian(buffer, 20, header.column)
	writer.written = OUTPUT_HEADER_BYTES
	return writer
}

output_write_u8 :: proc "contextless" (output_writer: ^Output_Writer, value: u8) {
	if output_writer.overflow || output_writer.written + 1 > len(output_writer.buffer) {
		output_writer.overflow = true
		return
	}
	output_writer.buffer[output_writer.written] = value
	output_writer.written += 1
}

output_write_u32 :: proc "contextless" (writer: ^Output_Writer, value: u32) {
	if writer.overflow || writer.written + 4 > len(writer.buffer) {
		writer.overflow = true
		return
	}
	byte_order.write_u32_little_endian(writer.buffer, writer.written, value)
	writer.written += 4
}

output_write_i64 :: proc "contextless" (writer: ^Output_Writer, value: i64) {
	if writer.overflow || writer.written + 8 > len(writer.buffer) {
		writer.overflow = true
		return
	}
	byte_order.write_u64_little_endian(writer.buffer, writer.written, u64(value))
	writer.written += 8
}

output_write_bytes :: proc "contextless" (output_writer: ^Output_Writer, bytes: []u8) {
	if output_writer.overflow || len(bytes) > len(output_writer.buffer) - output_writer.written {
		output_writer.overflow = true
		return
	}
	copy(output_writer.buffer[output_writer.written:], bytes)
	output_writer.written += len(bytes)
}

output_write_string :: proc "contextless" (writer: ^Output_Writer, text: string) {
	output_write_u32(writer, u32(len(text)))
	output_write_bytes(writer, transmute([]u8)text)
}

output_write_integer :: proc "contextless" (writer: ^Output_Writer, value: i64) {
	output_write_u8(writer, u8(Value_Tag.Integer))
	output_write_i64(writer, value)
}

output_write_boolean :: proc "contextless" (writer: ^Output_Writer, value: bool) {
	output_write_u8(writer, u8(Value_Tag.Boolean))
	output_write_u8(writer, value ? 1 : 0)
}

output_write_text :: proc "contextless" (writer: ^Output_Writer, text: string) {
	output_write_u8(writer, u8(Value_Tag.Text))
	output_write_string(writer, text)
}

output_write_hash :: proc "contextless" (writer: ^Output_Writer, hash: blake3.Hash) {
	output_write_u8(writer, u8(Value_Tag.Hash))
	h := hash
	output_write_bytes(writer, h[:])
}

output_write_member :: proc "contextless" (writer: ^Output_Writer, member_name: string) {
	output_write_u8(writer, u8(Value_Tag.Member))
	output_write_string(writer, member_name)
}

output_write_module_ref :: proc "contextless" (writer: ^Output_Writer, hash: blake3.Hash) {
	output_write_u8(writer, u8(Value_Tag.Module_Ref))
	h := hash
	output_write_bytes(writer, h[:])
}

output_write_follow_ref :: proc "contextless" (writer: ^Output_Writer, publisher: blake3.Hash, name: string) {
	output_write_u8(writer, u8(Value_Tag.Follow_Ref))
	p := publisher
	output_write_bytes(writer, p[:])
	output_write_string(writer, name)
}

output_write_refusal :: proc "contextless" (buffer: []u8, failure_kind: Failure_Kind, steps_taken, line, column: u32, detail: string) -> (written: int, ok: bool) {
	writer := output_writer_start(buffer, {status = .Refused, failure_kind = failure_kind, steps_taken = steps_taken, line = line, column = column})
	output_write_string(&writer, detail)
	if writer.overflow {
		return 0, false
	}
	return writer.written, true
}

// Sequential reader over a canonical output buffer.
Output_Reader :: struct {
	bytes:  []u8,
	offset: int,
}

output_read_header :: proc "contextless" (bytes: []u8) -> (header: Output_Header, reader: Output_Reader, refusal: Output_Refusal) {
	if len(bytes) < OUTPUT_HEADER_BYTES {
		return {}, {}, .Too_Small
	}
	if byte_order.read_u32_little_endian(bytes, 0) != OUTPUT_MAGIC {
		return {}, {}, .Bad_Magic
	}
	if byte_order.read_u32_little_endian(bytes, 4) != OUTPUT_VERSION {
		return {}, {}, .Bad_Version
	}
	status, status_ok := enum_word.member_of_word(Output_Status, u64(bytes[8]))
	if !status_ok {
		return {}, {}, .Unknown_Status
	}
	failure_kind, failure_ok := enum_word.member_of_word(Failure_Kind, u64(bytes[9]))
	if !failure_ok {
		return {}, {}, .Unknown_Failure_Kind
	}
	if byte_order.read_u16_little_endian(bytes, 10) != 0 {
		return {}, {}, .Bad_Reserved
	}
	header = {
		status       = status,
		failure_kind = failure_kind,
		steps_taken  = byte_order.read_u32_little_endian(bytes, 12),
		line         = byte_order.read_u32_little_endian(bytes, 16),
		column       = byte_order.read_u32_little_endian(bytes, 20),
	}
	return header, {bytes = bytes, offset = OUTPUT_HEADER_BYTES}, .None
}

output_read_u8 :: proc "contextless" (reader: ^Output_Reader) -> (value: u8, refusal: Output_Refusal) {
	if reader.offset + 1 > len(reader.bytes) {
		return 0, .Truncated
	}
	value = reader.bytes[reader.offset]
	reader.offset += 1
	return value, .None
}

output_read_u32 :: proc "contextless" (reader: ^Output_Reader) -> (value: u32, refusal: Output_Refusal) {
	if reader.offset + 4 > len(reader.bytes) {
		return 0, .Truncated
	}
	value = byte_order.read_u32_little_endian(reader.bytes, reader.offset)
	reader.offset += 4
	return value, .None
}

output_read_i64 :: proc "contextless" (reader: ^Output_Reader) -> (value: i64, refusal: Output_Refusal) {
	if reader.offset + 8 > len(reader.bytes) {
		return 0, .Truncated
	}
	value = i64(byte_order.read_u64_little_endian(reader.bytes, reader.offset))
	reader.offset += 8
	return value, .None
}

output_read_hash :: proc "contextless" (reader: ^Output_Reader) -> (hash: blake3.Hash, refusal: Output_Refusal) {
	if len(reader.bytes) - reader.offset < blake3.HASH_SIZE {
		return {}, .Truncated
	}
	copy(hash[:], reader.bytes[reader.offset:reader.offset + blake3.HASH_SIZE])
	reader.offset += blake3.HASH_SIZE
	return hash, .None
}

output_read_string :: proc "contextless" (reader: ^Output_Reader) -> (text: string, refusal: Output_Refusal) {
	length := output_read_u32(reader) or_return
	if int(length) > len(reader.bytes) - reader.offset {
		return "", .Truncated
	}
	slice := reader.bytes[reader.offset:reader.offset + int(length)]
	reader.offset += int(length)
	if !text_encoding.text_valid(slice) {
		return "", .Invalid_Text
	}
	return string(slice), .None
}

output_read_tag :: proc "contextless" (reader: ^Output_Reader) -> (tag: Value_Tag, refusal: Output_Refusal) {
	word := output_read_u8(reader) or_return
	member, ok := enum_word.member_of_word(Value_Tag, u64(word))
	if !ok {
		return .Integer, .Unknown_Value_Tag
	}
	return member, .None
}

// output_validate validates an entire serialized output buffer from header
// to final byte, including tag enums, UTF-8 text, sorted record field order,
// recursion depth bound, and absence of trailing bytes.
output_validate :: proc "contextless" (bytes: []u8) -> (header: Output_Header, refusal: Output_Refusal) {
	reader: Output_Reader
	header, reader, refusal = output_read_header(bytes)
	if refusal != .None {
		return {}, refusal
	}
	switch header.status {
	case .Ok:
		if header.failure_kind != .None {
			return {}, .Unknown_Failure_Kind
		}
		refusal = output_validate_value(&reader, 0)
		if refusal != .None {
			return {}, refusal
		}
	case .Refused:
		if header.failure_kind == .None {
			return {}, .Unknown_Failure_Kind
		}
		_, refusal = output_read_string(&reader)
		if refusal != .None {
			return {}, refusal
		}
	}
	if reader.offset != len(bytes) {
		return {}, .Trailing_Bytes
	}
	return header, .None
}

@(private)
output_validate_value :: proc "contextless" (reader: ^Output_Reader, depth: int) -> Output_Refusal {
	if depth >= OUTPUT_DEPTH_LIMIT {
		return .Depth_Limit_Exceeded
	}
	tag, refusal := output_read_tag(reader)
	if refusal != .None {
		return refusal
	}
	switch tag {
	case .Integer:
		_, refusal = output_read_i64(reader)
		return refusal
	case .Boolean:
		b, r := output_read_u8(reader)
		if r != .None {
			return r
		}
		if b > 1 {
			return .Bad_Boolean
		}
		return .None
	case .Text, .Member:
		_, refusal = output_read_string(reader)
		return refusal
	case .Hash, .Module_Ref:
		_, refusal = output_read_hash(reader)
		return refusal
	case .Recipe_Ref:
		_, refusal = output_read_hash(reader)
		if refusal != .None {
			return refusal
		}
		_, refusal = output_read_hash(reader)
		if refusal != .None {
			return refusal
		}
		return output_validate_value(reader, depth + 1)
	case .Follow_Ref:
		_, refusal = output_read_hash(reader)
		if refusal != .None {
			return refusal
		}
		_, refusal = output_read_string(reader)
		return refusal
	case .Store_Ref:
		_, refusal = output_read_string(reader)
		if refusal != .None {
			return refusal
		}
		right_count, r := output_read_u32(reader)
		if r != .None {
			return r
		}
		if right_count > OUTPUT_COLLECTION_LIMIT {
			return .Count_Limit_Exceeded
		}
		for _ in 0 ..< right_count {
			_, refusal = output_read_string(reader)
			if refusal != .None {
				return refusal
			}
		}
		return .None
	case .List:
		count, r := output_read_u32(reader)
		if r != .None {
			return r
		}
		if count > OUTPUT_COLLECTION_LIMIT {
			return .Count_Limit_Exceeded
		}
		for _ in 0 ..< count {
			if err := output_validate_value(reader, depth + 1); err != .None {
				return err
			}
		}
		return .None
	case .Record:
		count, r := output_read_u32(reader)
		if r != .None {
			return r
		}
		if count > OUTPUT_COLLECTION_LIMIT {
			return .Count_Limit_Exceeded
		}
		previous_name := ""
		has_previous := false
		for _ in 0 ..< count {
			name, name_err := output_read_string(reader)
			if name_err != .None {
				return name_err
			}
			if has_previous && name <= previous_name {
				return .Unsorted_Record
			}
			previous_name, has_previous = name, true
			if err := output_validate_value(reader, depth + 1); err != .None {
				return err
			}
		}
		return .None
	case .Plan, .Project:
		return output_validate_value(reader, depth + 1)
	}
	return .Unknown_Value_Tag
}
