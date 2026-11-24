// Contract between a caller and the sandboxed declaration evaluator
// (src/md/features/declarations.md, "Text stops at the evaluation").
//
// The evaluation process holds no writable store, no network and no root
// ring. Its caller passes a read-only bundle of referenced .lex sources,
// optional tree hash for here(), and a caller-supplied hash seed, and receives
// back either a canonical serialized value or a typed refusal with its source
// place. Every byte that crosses the border is validated once before use, and
// every closed set of choices enters through enum_word.member_of_word.
package declaration_eval

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// ---- Read-only input bundle format (v2).

BUNDLE_MAGIC :: u32(0x4244454C) // "LEDB"
BUNDLE_VERSION :: u32(2)
// Format property: magic(4) + version(4) + entry_count(4) + flags(4) + here_hash(32) + hash_seed(8).
BUNDLE_HEADER_BYTES :: 56
// Format property: kind(1) + pad(3) + path_off(4) + path_len(4) + content_off(4) + content_len(4) + hash(32) + pad(4).
BUNDLE_ENTRY_BYTES :: 56
BUNDLE_FLAG_HAS_HERE :: u32(1)
// Format property: maximum relative .lex import path length in bytes.
DECLARATION_PATH_LIMIT :: 256

// What an entry of an input bundle keys on.
Bundle_Entry_Kind :: enum u8 {
	File_Path        = 1, // A relative .lex file path inside a tree.
	Declaration_Hash = 2, // A 32-byte BLAKE3 hash of a declaration tree.
}

// Why an input bundle is refused at the border.
Bundle_Refusal :: enum u8 {
	None                = 0,
	Too_Small           = 1,
	Bad_Magic           = 2,
	Bad_Version         = 3,
	Bad_Flags           = 4,
	Unknown_Entry_Kind  = 5,
	Bad_Reserved        = 6,
	Entry_Out_Of_Bounds = 7,
	Bad_Path            = 8,
	Buffer_Too_Small    = 9,
	Unsorted_Entries    = 10,
	Duplicate_Entry     = 11,
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

@(private)
hash_compare :: proc "contextless" (a, b: blake3.Hash) -> int {
	for i in 0 ..< blake3.HASH_SIZE {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	return 0
}

@(private)
string_compare :: proc "contextless" (a, b: string) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

// Compares two already-bounds-checked entry slots inside a bundle buffer by
// (kind, path/hash).
@(private)
bundle_slot_compare :: proc "contextless" (bytes: []u8, a_idx, b_idx: int) -> int {
	a_off := BUNDLE_HEADER_BYTES + a_idx * BUNDLE_ENTRY_BYTES
	b_off := BUNDLE_HEADER_BYTES + b_idx * BUNDLE_ENTRY_BYTES
	ak := bytes[a_off]
	bk := bytes[b_off]
	if ak != bk {
		return ak < bk ? -1 : 1
	}
	if ak == u8(Bundle_Entry_Kind.File_Path) {
		ap_off := int(byte_order.read_u32_little_endian(bytes, a_off + 4))
		ap_len := int(byte_order.read_u32_little_endian(bytes, a_off + 8))
		bp_off := int(byte_order.read_u32_little_endian(bytes, b_off + 4))
		bp_len := int(byte_order.read_u32_little_endian(bytes, b_off + 8))
		return string_compare(string(bytes[ap_off:ap_off + ap_len]), string(bytes[bp_off:bp_off + bp_len]))
	}
	ah, bh: blake3.Hash
	copy(ah[:], bytes[a_off + 20:a_off + 52])
	copy(bh[:], bytes[b_off + 20:b_off + 52])
	return hash_compare(ah, bh)
}

@(private)
bundle_slot_swap :: proc "contextless" (bytes: []u8, a_idx, b_idx: int) {
	if a_idx == b_idx {
		return
	}
	a_off := BUNDLE_HEADER_BYTES + a_idx * BUNDLE_ENTRY_BYTES
	b_off := BUNDLE_HEADER_BYTES + b_idx * BUNDLE_ENTRY_BYTES
	tmp: [BUNDLE_ENTRY_BYTES]u8
	copy(tmp[:], bytes[a_off:a_off + BUNDLE_ENTRY_BYTES])
	copy(bytes[a_off:a_off + BUNDLE_ENTRY_BYTES], bytes[b_off:b_off + BUNDLE_ENTRY_BYTES])
	copy(bytes[b_off:b_off + BUNDLE_ENTRY_BYTES], tmp[:])
}

// In-place heapsort over the 56-byte entry descriptors in destination: O(N log N)
// time, O(1) stack space, zero allocator.
@(private)
bundle_sort_slots :: proc "contextless" (bytes: []u8, count: int) {
	sift_down :: proc "contextless" (bytes: []u8, start, end: int) {
		root := start
		for root * 2 + 1 < end {
			child := root * 2 + 1
			swap_idx := root
			if bundle_slot_compare(bytes, swap_idx, child) < 0 {
				swap_idx = child
			}
			if child + 1 < end && bundle_slot_compare(bytes, swap_idx, child + 1) < 0 {
				swap_idx = child + 1
			}
			if swap_idx == root {
				return
			}
			bundle_slot_swap(bytes, root, swap_idx)
			root = swap_idx
		}
	}
	for start := count / 2 - 1; start >= 0; start -= 1 {
		sift_down(bytes, start, count)
	}
	for end := count - 1; end > 0; end -= 1 {
		bundle_slot_swap(bytes, 0, end)
		sift_down(bytes, 0, end)
	}
}

// bundle_write encodes a read-only input bundle into destination with entries
// sorted by (kind, path/hash) and rejects duplicate keys.
bundle_write :: proc "contextless" (
	destination: []u8,
	entries: []Bundle_Input_Entry,
	has_here: bool = false,
	here_hash: blake3.Hash = {},
	hash_seed: u64 = 0,
) -> (written: int, refusal: Bundle_Refusal) {
	entry_count := u64(len(entries))
	if entry_count > u64(max(u32)) {
		return 0, .Buffer_Too_Small
	}
	table_bytes := entry_count * u64(BUNDLE_ENTRY_BYTES)
	total := u64(BUNDLE_HEADER_BYTES) + table_bytes
	if total < u64(BUNDLE_HEADER_BYTES) || total > u64(len(destination)) {
		return 0, .Buffer_Too_Small
	}
	for entry in entries {
		switch entry.kind {
		case .File_Path:
			if !declaration_path_valid(entry.path) {
				return 0, .Bad_Path
			}
			if u64(len(entry.path)) > u64(len(destination)) - total {
				return 0, .Buffer_Too_Small
			}
			total += u64(len(entry.path))
		case .Declaration_Hash:
		}
		if u64(len(entry.content)) > u64(len(destination)) - total {
			return 0, .Buffer_Too_Small
		}
		total += u64(len(entry.content))
	}
	if total > u64(max(u32)) {
		return 0, .Buffer_Too_Small
	}
	table_end := int(u64(BUNDLE_HEADER_BYTES) + table_bytes)
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
	byte_order.write_u64_little_endian(destination, 48, hash_seed)
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
	if len(entries) > 1 {
		bundle_sort_slots(destination[:cursor], len(entries))
		for index in 1 ..< len(entries) {
			if bundle_slot_compare(destination[:cursor], index - 1, index) == 0 {
				return 0, .Duplicate_Entry
			}
		}
	}
	return cursor, .None
}

// range_fits checks that [offset, offset + length) lies inside total without
// integer overflow and starts at or after min_offset.
@(private)
range_fits :: proc "contextless" (offset, length: u32, min_offset, total: int) -> bool {
	if u64(offset) < u64(min_offset) || u64(offset) > u64(total) {
		return false
	}
	return u64(length) <= u64(total) - u64(offset)
}

// bundle_validate validates a read-only input bundle at the border: magic,
// version, unknown flags, overflow-safe entry table bounds, reserved bytes,
// entry kind enum, path validity, payload bounds, and strictly ascending
// sorted unique keys.
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
	flags := byte_order.read_u32_little_endian(bytes, 12)
	if (flags & ~BUNDLE_FLAG_HAS_HERE) != 0 {
		return .Bad_Flags
	}
	max_entries := (u64(len(bytes)) - u64(BUNDLE_HEADER_BYTES)) / u64(BUNDLE_ENTRY_BYTES)
	if u64(entry_count) > max_entries {
		return .Entry_Out_Of_Bounds
	}
	table_end := BUNDLE_HEADER_BYTES + int(entry_count) * BUNDLE_ENTRY_BYTES
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
				return .Bad_Path
			}
		case .Declaration_Hash:
			if path_off != 0 || path_len != 0 {
				return .Bad_Reserved
			}
		}
		if index > 0 {
			cmp := bundle_slot_compare(bytes, index - 1, index)
			if cmp == 0 {
				return .Duplicate_Entry
			}
			if cmp > 0 {
				return .Unsorted_Entries
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

// bundle_hash_seed returns the caller-supplied hash seed carried by a validated
// bundle for zero-handle evaluation.
bundle_hash_seed :: proc "contextless" (bytes: []u8) -> u64 {
	if len(bytes) < BUNDLE_HEADER_BYTES {
		return 0
	}
	return byte_order.read_u64_little_endian(bytes, 48)
}

// bundle_lookup_path finds a .lex file entry by relative path in a validated
// sorted bundle in O(log N) time with zero auxiliary memory.
bundle_lookup_path :: proc "contextless" (bytes: []u8, path: string) -> (content: string, found: bool) {
	if len(bytes) < BUNDLE_HEADER_BYTES {
		return "", false
	}
	entry_count := byte_order.read_u32_little_endian(bytes, 8)
	max_entries := (u64(len(bytes)) - u64(BUNDLE_HEADER_BYTES)) / u64(BUNDLE_ENTRY_BYTES)
	if u64(entry_count) > max_entries {
		return "", false
	}
	lo, hi := 0, int(entry_count)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		offset := BUNDLE_HEADER_BYTES + mid * BUNDLE_ENTRY_BYTES
		kind := bytes[offset]
		if kind != u8(Bundle_Entry_Kind.File_Path) {
			// File_Path (1) precedes Declaration_Hash (2).
			hi = mid
			continue
		}
		path_off := int(byte_order.read_u32_little_endian(bytes, offset + 4))
		path_len := int(byte_order.read_u32_little_endian(bytes, offset + 8))
		if u64(path_off) > u64(len(bytes)) || u64(path_len) > u64(len(bytes)) - u64(path_off) {
			return "", false
		}
		cmp := string_compare(string(bytes[path_off:path_off + path_len]), path)
		if cmp < 0 {
			lo = mid + 1
		} else if cmp > 0 {
			hi = mid
		} else {
			content_off := int(byte_order.read_u32_little_endian(bytes, offset + 12))
			content_len := int(byte_order.read_u32_little_endian(bytes, offset + 16))
			if u64(content_off) > u64(len(bytes)) || u64(content_len) > u64(len(bytes)) - u64(content_off) {
				return "", false
			}
			return string(bytes[content_off:content_off + content_len]), true
		}
	}
	return "", false
}

// bundle_lookup_hash finds a declaration entry by BLAKE3 hash in a validated
// sorted bundle in O(log N) time with zero auxiliary memory.
bundle_lookup_hash :: proc "contextless" (bytes: []u8, hash: blake3.Hash) -> (content: string, found: bool) {
	if len(bytes) < BUNDLE_HEADER_BYTES {
		return "", false
	}
	entry_count := byte_order.read_u32_little_endian(bytes, 8)
	max_entries := (u64(len(bytes)) - u64(BUNDLE_HEADER_BYTES)) / u64(BUNDLE_ENTRY_BYTES)
	if u64(entry_count) > max_entries {
		return "", false
	}
	lo, hi := 0, int(entry_count)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		offset := BUNDLE_HEADER_BYTES + mid * BUNDLE_ENTRY_BYTES
		kind := bytes[offset]
		if kind != u8(Bundle_Entry_Kind.Declaration_Hash) {
			// File_Path (1) precedes Declaration_Hash (2).
			lo = mid + 1
			continue
		}
		entry_hash: blake3.Hash
		copy(entry_hash[:], bytes[offset + 20:offset + 52])
		cmp := hash_compare(entry_hash, hash)
		if cmp < 0 {
			lo = mid + 1
		} else if cmp > 0 {
			hi = mid
		} else {
			content_off := int(byte_order.read_u32_little_endian(bytes, offset + 12))
			content_len := int(byte_order.read_u32_little_endian(bytes, offset + 16))
			if u64(content_off) > u64(len(bytes)) || u64(content_len) > u64(len(bytes)) - u64(content_off) {
				return "", false
			}
			return string(bytes[content_off:content_off + content_len]), true
		}
	}
	return "", false
}

// ---- Canonical output value format.

OUTPUT_MAGIC :: u32(0x4F44454C) // "LEDO"
OUTPUT_VERSION :: u32(1)
OUTPUT_HEADER_BYTES :: 24
// Format property: nesting depth limit for canonical serialized values.
OUTPUT_DEPTH_LIMIT :: 64

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
	Recipe_Refused       = 17, // The conversion of a recipe refused it: the detail is the words of its refusal (plans_recipes.recipe_refusal_words).
	Assertion_Failed     = 18, // An assert(cond, msg, value) call evaluated cond to false.
	No_Matching_Arm      = 19, // A match expression reached the end of its arms with no match.
}

// Canonical value tags in the output buffer.
Value_Tag :: enum u8 {
	Integer      = 1,
	Boolean      = 2,
	Text         = 3,
	Hash         = 4,
	Member       = 5,
	Module_Ref   = 6,
	Recipe_Ref   = 7,
	Follow_Ref   = 8,
	Store_Ref    = 9,
	List         = 10,
	Record       = 11,
	Plan         = 12,
	Project      = 13,
	Tree_Ref     = 14, // A tree by its hash, as here() gives it: an input of a recipe that names its kind.
	Integer_Unit = 15, // A typed unit integer: kind:u8, unit:u8, value:i64 LE (kind != .None).
}

// Why an output buffer is refused by a reader.
Output_Refusal :: enum u8 {
	None                 = 0,
	Too_Small            = 1,
	Bad_Magic            = 2,
	Bad_Version          = 3,
	Unknown_Status       = 4,
	Unknown_Failure_Kind = 5,
	Bad_Reserved         = 6,
	Unknown_Value_Tag    = 7,
	Truncated            = 8,
	Bad_Boolean          = 9,
	Bad_Text             = 10,
	Depth_Limit_Exceeded = 11,
	Unsorted_Record      = 12,
	Trailing_Bytes       = 13,
	Bad_Integer_Unit     = 14,
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

output_write_integer_unit :: proc "contextless" (writer: ^Output_Writer, value: i64, unit: value_kinds.Integer_Unit) {
	if unit.kind == .None || !value_kinds.integer_unit_valid(unit) {
		output_write_integer(writer, value)
		return
	}
	output_write_u8(writer, u8(Value_Tag.Integer_Unit))
	output_write_u8(writer, u8(unit.kind))
	output_write_u8(writer, unit.unit)
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

// output_write_tree writes a tree by its hash, as here() gives it.
output_write_tree :: proc "contextless" (writer: ^Output_Writer, hash: blake3.Hash) {
	output_write_u8(writer, u8(Value_Tag.Tree_Ref))
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

output_read_integer_unit :: proc "contextless" (reader: ^Output_Reader) -> (value: i64, unit: value_kinds.Integer_Unit, refusal: Output_Refusal) {
	kind_byte := output_read_u8(reader) or_return
	unit_byte := output_read_u8(reader) or_return
	kind, kind_ok := value_kinds.value_kind_of(kind_byte)
	if !kind_ok || kind == .None {
		return 0, {}, .Bad_Integer_Unit
	}
	u := value_kinds.Integer_Unit{kind = kind, unit = unit_byte}
	if !value_kinds.integer_unit_valid(u) {
		return 0, {}, .Bad_Integer_Unit
	}
	v := output_read_i64(reader) or_return
	return v, u, .None
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
	if u64(length) > u64(len(reader.bytes) - reader.offset) {
		return "", .Truncated
	}
	slice := reader.bytes[reader.offset:reader.offset + int(length)]
	reader.offset += int(length)
	if !text_encoding.text_valid(slice) {
		return "", .Bad_Text
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

// output_skip_value reads one whole value at depth past reader, with the
// checks of output_validate, so a reader of a record skips a field that it
// does not use and still refuses a damaged one.
output_skip_value :: proc "contextless" (reader: ^Output_Reader, depth: int) -> Output_Refusal {
	return output_validate_value(reader, depth)
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
	case .Integer_Unit:
		_, _, refusal = output_read_integer_unit(reader)
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
	case .Hash, .Module_Ref, .Tree_Ref:
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
		// Each right string occupies at least 4 bytes (u32 length).
		if u64(right_count) > u64(len(reader.bytes) - reader.offset) / 4 {
			return .Truncated
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
		// Each list item occupies at least 1 byte (Value_Tag).
		if u64(count) > u64(len(reader.bytes) - reader.offset) {
			return .Truncated
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
		// Each field occupies at least 5 bytes (u32 name_len + Value_Tag).
		if u64(count) > u64(len(reader.bytes) - reader.offset) / 5 {
			return .Truncated
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
