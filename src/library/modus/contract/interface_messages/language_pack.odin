// Compiled binary language pack format (MODLANG1): encoder, strict border
// validator, and O(log N) binary-search lookup
// (src/md/features/interface_language.md).
//
// A language pack is an immutable read-only data object mapped into a process
// at start. Its binary layout is:
//   - Header (64 bytes): magic "MODLANG1", version 1, entry_count,
//     payload_offset, payload_length, canonical BCP 47 language tag, reserved 0.
//   - Index table (entry_count * 16 bytes): sorted strictly ascending by
//     message_id_hash (u64), with relative payload_offset (u32) and
//     payload_length (u32).
//   - Payload table (payload_length bytes): contiguous UTF-8 MF2 messages.
//   - Integrity digest (32 bytes): BLAKE3 over all preceding bytes.
//
// This is a freestanding contract package: it imports base and contract
// packages only, calls no kernel operation, and allocates no memory.
package interface_messages

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/language_tag"
import "modus:contract/text_encoding"

// Eight-byte format signature at byte 0 of every MODLANG1 pack.
PACK_MAGIC :: [8]u8{'M', 'O', 'D', 'L', 'A', 'N', 'G', '1'}

// Format version number of MODLANG1.
PACK_FORMAT_VERSION :: u32(1)

// Fixed byte size of the MODLANG1 header.
PACK_HEADER_SIZE :: 64

// Fixed byte size of one sorted index table entry: hash (8) + offset (4) + length (4).
PACK_ENTRY_SIZE :: 16

// Byte size of the trailing BLAKE3 integrity digest.
PACK_DIGEST_SIZE :: blake3.HASH_SIZE

// Minimum byte size of a valid MODLANG1 pack (zero entries, zero payload).
PACK_MIN_SIZE :: PACK_HEADER_SIZE + PACK_DIGEST_SIZE

// Maximum number of message entries in one MODLANG1 pack.
PACK_MAX_ENTRIES :: 4096

// Maximum total payload bytes in one MODLANG1 pack.
PACK_MAX_PAYLOAD_BYTES :: 1024 * 1024

// Maximum byte length of a message identifier string.
PACK_MESSAGE_ID_MAX_BYTES :: 128

// Domain separator used to derive 64-bit message identifier hashes with BLAKE3.
PACK_MESSAGE_ID_HASH_CONTEXT :: "MODUS_INTERFACE_MESSAGE_ID_V1"

// Closed set of outcomes from encoding, validating, or querying a MODLANG1 pack.
Pack_Status :: enum u32 {
	Ok                   = 0,
	Too_Short            = 1,
	Bad_Magic            = 2,
	Unsupported_Version  = 3,
	Invalid_Language_Tag = 4,
	Non_Zero_Reserved    = 5,
	Too_Many_Entries     = 6,
	Size_Mismatch        = 7,
	Bad_Digest           = 8,
	Unsorted_Entries     = 9,
	Duplicate_Entry      = 10,
	Truncated_Payload    = 11,
	Overlapping_Payload  = 12,
	Corrupted_Payload    = 13,
	Invalid_Message_Id   = 14,
	Buffer_Too_Small     = 15,
	Not_Found            = 16,
}

// One input message supplied to pack_encode.
Pack_Entry_Input :: struct {
	message_id:      string,
	message_pattern: string,
}

// Decoded header fields of a validated MODLANG1 pack.
Pack_Header :: struct {
	version:             u32,
	entry_count:         u32,
	payload_offset:      u32,
	payload_length:      u32,
	language_tag_length: u8,
	language_tag_bytes:  [LANGUAGE_TAG_CAPACITY]u8,
	digest:              blake3.Hash,
}

// message_id_valid checks whether a message identifier is a non-empty bounded
// ASCII identifier.
message_id_valid :: proc "contextless" (message_id: string) -> bool {
	raw := transmute([]u8)message_id
	if len(raw) == 0 || len(raw) > PACK_MESSAGE_ID_MAX_BYTES {
		return false
	}
	return text_encoding.identifier_valid(raw)
}

// message_id_hash computes the deterministic 64-bit domain-separated BLAKE3
// hash used as the sorted key in MODLANG1 index tables.
message_id_hash :: proc "contextless" (message_id: string) -> u64 {
	digest := blake3.derive_key(PACK_MESSAGE_ID_HASH_CONTEXT, transmute([]u8)message_id)
	return byte_order.read_u64_little_endian(digest[:], 0)
}

// pack_language_tag returns the canonical BCP 47 tag stored in a Pack_Header.
pack_language_tag :: proc "contextless" (header: ^Pack_Header) -> string {
	if header == nil {
		return ""
	}
	length := int(header.language_tag_length)
	if length <= 0 || length > LANGUAGE_TAG_CAPACITY {
		return ""
	}
	return string(header.language_tag_bytes[:length])
}

// pack_encoded_size computes the exact byte size of an encoded MODLANG1 pack
// for entries without writing any output bytes.
pack_encoded_size :: proc "contextless" (entries: []Pack_Entry_Input) -> (size: int, status: Pack_Status) {
	if len(entries) > PACK_MAX_ENTRIES {
		return 0, .Too_Many_Entries
	}
	payload_total: u64 = 0
	for entry in entries {
		if !message_id_valid(entry.message_id) {
			return 0, .Invalid_Message_Id
		}
		if len(entry.message_pattern) > MESSAGE_PATTERN_MAX_BYTES {
			return 0, .Corrupted_Payload
		}
		payload_total += u64(len(entry.message_pattern))
		if payload_total > PACK_MAX_PAYLOAD_BYTES {
			return 0, .Size_Mismatch
		}
	}
	total := u64(PACK_HEADER_SIZE) + u64(len(entries)) * u64(PACK_ENTRY_SIZE) + payload_total + u64(PACK_DIGEST_SIZE)
	return int(total), .Ok
}

// index_slot_swap exchanges two 16-byte index slots inside destination during
// in-place heapsort.
@(private = "file")
index_slot_swap :: proc "contextless" (destination: []u8, first_index, second_index: int) {
	if first_index == second_index {
		return
	}
	first_off := PACK_HEADER_SIZE + first_index * PACK_ENTRY_SIZE
	second_off := PACK_HEADER_SIZE + second_index * PACK_ENTRY_SIZE
	for byte_index in 0 ..< PACK_ENTRY_SIZE {
		saved := destination[first_off + byte_index]
		destination[first_off + byte_index] = destination[second_off + byte_index]
		destination[second_off + byte_index] = saved
	}
}

@(private = "file")
index_slot_hash :: proc "contextless" (destination: []u8, slot_index: int) -> u64 {
	return byte_order.read_u64_little_endian(destination, PACK_HEADER_SIZE + slot_index * PACK_ENTRY_SIZE)
}

// index_table_heapsort sorts entry_count 16-byte slots inside destination in
// ascending order of message_id_hash in O(N log N) time with zero extra memory.
@(private = "file")
index_table_heapsort :: proc "contextless" (destination: []u8, entry_count: int) {
	if entry_count <= 1 {
		return
	}
	sift_down :: proc "contextless" (destination: []u8, start_index, end_index: int) {
		root := start_index
		for root * 2 + 1 < end_index {
			child := root * 2 + 1
			swap_target := root
			if index_slot_hash(destination, swap_target) < index_slot_hash(destination, child) {
				swap_target = child
			}
			if child + 1 < end_index && index_slot_hash(destination, swap_target) < index_slot_hash(destination, child + 1) {
				swap_target = child + 1
			}
			if swap_target == root {
				return
			}
			index_slot_swap(destination, root, swap_target)
			root = swap_target
		}
	}

	for start := entry_count / 2 - 1; start >= 0; start -= 1 {
		sift_down(destination, start, entry_count)
	}
	for end := entry_count - 1; end > 0; end -= 1 {
		index_slot_swap(destination, 0, end)
		sift_down(destination, 0, end)
	}
}

// pack_encode serializes a canonical language tag and a slice of MF2 messages
// into the MODLANG1 binary format in destination. All inputs are validated
// before writing so every refusal leaves destination untouched.
pack_encode :: proc "contextless" (language: string, entries: []Pack_Entry_Input, destination: []u8) -> (written: int, status: Pack_Status) {
	if language_tag.canonical_check(language) != .None {
		return 0, .Invalid_Language_Tag
	}
	if len(entries) > PACK_MAX_ENTRIES {
		return 0, .Too_Many_Entries
	}

	// Validate all IDs, duplicates, and MF2 payloads before modifying destination.
	payload_total: u64 = 0
	for entry, index in entries {
		if !message_id_valid(entry.message_id) {
			return 0, .Invalid_Message_Id
		}
		for earlier in 0 ..< index {
			if entries[earlier].message_id == entry.message_id {
				return 0, .Duplicate_Entry
			}
		}
		_, parse_status, _ := message_parse(entry.message_pattern)
		if parse_status != .Ok {
			return 0, .Corrupted_Payload
		}
		payload_total += u64(len(entry.message_pattern))
		if payload_total > PACK_MAX_PAYLOAD_BYTES {
			return 0, .Size_Mismatch
		}
	}

	entry_count := len(entries)
	payload_offset := PACK_HEADER_SIZE + entry_count * PACK_ENTRY_SIZE
	total_size := payload_offset + int(payload_total) + PACK_DIGEST_SIZE
	if len(destination) < total_size {
		return 0, .Buffer_Too_Small
	}

	// Write 64-byte header (zeroed first so padding and reserved stay zero).
	for byte_index in 0 ..< PACK_HEADER_SIZE {
		destination[byte_index] = 0
	}
	magic := PACK_MAGIC
	for byte_index in 0 ..< len(magic) {
		destination[byte_index] = magic[byte_index]
	}
	byte_order.write_u32_little_endian(destination, 8, PACK_FORMAT_VERSION)
	byte_order.write_u32_little_endian(destination, 12, u32(entry_count))
	byte_order.write_u32_little_endian(destination, 16, u32(payload_offset))
	byte_order.write_u32_little_endian(destination, 20, u32(payload_total))
	destination[24] = u8(len(language))
	lang_raw := transmute([]u8)language
	for byte_index in 0 ..< len(lang_raw) {
		destination[25 + byte_index] = lang_raw[byte_index]
	}
	byte_order.write_u32_little_endian(destination, 60, 0)

	// Populate temporary index slots with (id_hash, input_index, pattern_length).
	for entry, index in entries {
		slot_off := PACK_HEADER_SIZE + index * PACK_ENTRY_SIZE
		byte_order.write_u64_little_endian(destination, slot_off, message_id_hash(entry.message_id))
		byte_order.write_u32_little_endian(destination, slot_off + 8, u32(index))
		byte_order.write_u32_little_endian(destination, slot_off + 12, u32(len(entry.message_pattern)))
	}

	// Sort index slots in-place by ascending message_id_hash.
	index_table_heapsort(destination, entry_count)

	// Guard against 64-bit hash collision across distinct IDs.
	for index in 1 ..< entry_count {
		if index_slot_hash(destination, index) == index_slot_hash(destination, index - 1) {
			for byte_index in 0 ..< total_size {
				destination[byte_index] = 0
			}
			return 0, .Duplicate_Entry
		}
	}

	// Copy payloads in sorted index order and write final relative offsets.
	payload_cursor := 0
	for index in 0 ..< entry_count {
		slot_off := PACK_HEADER_SIZE + index * PACK_ENTRY_SIZE
		original_index := int(byte_order.read_u32_little_endian(destination, slot_off + 8))
		pattern_bytes := transmute([]u8)entries[original_index].message_pattern
		byte_order.write_u32_little_endian(destination, slot_off + 8, u32(payload_cursor))
		for byte_index in 0 ..< len(pattern_bytes) {
			destination[payload_offset + payload_cursor + byte_index] = pattern_bytes[byte_index]
		}
		payload_cursor += len(pattern_bytes)
	}

	// Write trailing 32-byte BLAKE3 integrity digest over header + index + payload.
	digest_offset := total_size - PACK_DIGEST_SIZE
	digest := blake3.hash(destination[:digest_offset])
	for byte_index in 0 ..< PACK_DIGEST_SIZE {
		destination[digest_offset + byte_index] = digest[byte_index]
	}
	return total_size, .Ok
}

// pack_read_header decodes and validates the 64-byte MODLANG1 header and exact
// pack length without scanning entries or recomputing the BLAKE3 digest.
pack_read_header :: proc "contextless" (pack_bytes: []u8) -> (header: Pack_Header, status: Pack_Status) {
	if len(pack_bytes) < PACK_MIN_SIZE {
		return {}, .Too_Short
	}
	magic := PACK_MAGIC
	for byte_index in 0 ..< len(magic) {
		if pack_bytes[byte_index] != magic[byte_index] {
			return {}, .Bad_Magic
		}
	}
	version := byte_order.read_u32_little_endian(pack_bytes, 8)
	if version != PACK_FORMAT_VERSION {
		return {}, .Unsupported_Version
	}
	entry_count := byte_order.read_u32_little_endian(pack_bytes, 12)
	payload_offset := byte_order.read_u32_little_endian(pack_bytes, 16)
	payload_length := byte_order.read_u32_little_endian(pack_bytes, 20)
	tag_length := pack_bytes[24]
	reserved := byte_order.read_u32_little_endian(pack_bytes, 60)

	if reserved != 0 {
		return {}, .Non_Zero_Reserved
	}
	if tag_length == 0 || int(tag_length) > LANGUAGE_TAG_CAPACITY {
		return {}, .Invalid_Language_Tag
	}
	for byte_index in 0 ..< LANGUAGE_TAG_CAPACITY {
		value := pack_bytes[25 + byte_index]
		if byte_index >= int(tag_length) && value != 0 {
			return {}, .Invalid_Language_Tag
		}
		header.language_tag_bytes[byte_index] = value
	}
	header.language_tag_length = tag_length
	if language_tag.canonical_check(string(header.language_tag_bytes[:tag_length])) != .None {
		return {}, .Invalid_Language_Tag
	}

	if entry_count > PACK_MAX_ENTRIES {
		return {}, .Too_Many_Entries
	}
	expected_payload_offset := u64(PACK_HEADER_SIZE) + u64(entry_count) * u64(PACK_ENTRY_SIZE)
	if u64(payload_offset) != expected_payload_offset {
		return {}, .Size_Mismatch
	}
	if payload_length > PACK_MAX_PAYLOAD_BYTES {
		return {}, .Size_Mismatch
	}
	expected_total := expected_payload_offset + u64(payload_length) + u64(PACK_DIGEST_SIZE)
	if u64(len(pack_bytes)) != expected_total {
		return {}, .Size_Mismatch
	}

	header.version = version
	header.entry_count = entry_count
	header.payload_offset = payload_offset
	header.payload_length = payload_length
	digest_offset := len(pack_bytes) - PACK_DIGEST_SIZE
	for byte_index in 0 ..< PACK_DIGEST_SIZE {
		header.digest[byte_index] = pack_bytes[digest_offset + byte_index]
	}
	return header, .Ok
}

// pack_validate checks every invariant of an untrusted MODLANG1 pack at the
// border: header, exact length, BLAKE3 integrity digest, strictly ascending
// unique message_id_hash entries, contiguous non-overlapping payload spans,
// and valid UTF-8 MF2 syntax for every message payload.
pack_validate :: proc "contextless" (pack_bytes: []u8) -> (header: Pack_Header, status: Pack_Status) {
	header, status = pack_read_header(pack_bytes)
	if status != .Ok {
		return {}, status
	}

	digest_offset := len(pack_bytes) - PACK_DIGEST_SIZE
	computed_digest := blake3.hash(pack_bytes[:digest_offset])
	if computed_digest != header.digest {
		return {}, .Bad_Digest
	}

	// Pass 1: verify index table is strictly ascending with no duplicate hashes.
	previous_hash: u64 = 0
	for index in u32(0) ..< header.entry_count {
		slot_off := PACK_HEADER_SIZE + int(index) * PACK_ENTRY_SIZE
		entry_hash := byte_order.read_u64_little_endian(pack_bytes, slot_off)
		if index > 0 {
			if entry_hash == previous_hash {
				return {}, .Duplicate_Entry
			}
			if entry_hash < previous_hash {
				return {}, .Unsorted_Entries
			}
		}
		previous_hash = entry_hash
	}

	// Pass 2: verify contiguous non-overlapping payload bounds and MF2 syntax.
	expected_cursor: u64 = 0
	for index in u32(0) ..< header.entry_count {
		slot_off := PACK_HEADER_SIZE + int(index) * PACK_ENTRY_SIZE
		entry_offset := byte_order.read_u32_little_endian(pack_bytes, slot_off + 8)
		entry_length := byte_order.read_u32_little_endian(pack_bytes, slot_off + 12)

		if u64(entry_offset) + u64(entry_length) > u64(header.payload_length) {
			return {}, .Truncated_Payload
		}
		if u64(entry_offset) < expected_cursor {
			return {}, .Overlapping_Payload
		}
		if u64(entry_offset) > expected_cursor {
			return {}, .Corrupted_Payload
		}
		if entry_length > MESSAGE_PATTERN_MAX_BYTES {
			return {}, .Corrupted_Payload
		}

		abs_start := int(header.payload_offset) + int(entry_offset)
		abs_end := abs_start + int(entry_length)
		_, parse_status, _ := message_parse(string(pack_bytes[abs_start:abs_end]))
		if parse_status != .Ok {
			return {}, .Corrupted_Payload
		}
		expected_cursor += u64(entry_length)
	}

	if expected_cursor != u64(header.payload_length) {
		return {}, .Corrupted_Payload
	}
	return header, .Ok
}

// pack_lookup finds the UTF-8 MF2 message pattern for message_id inside a
// validated MODLANG1 pack using O(log N) binary search over message_id_hash.
pack_lookup :: proc "contextless" (pack_bytes: []u8, message_id: string) -> (pattern: string, status: Pack_Status) {
	if !message_id_valid(message_id) {
		return "", .Invalid_Message_Id
	}
	header, header_status := pack_read_header(pack_bytes)
	if header_status != .Ok {
		return "", header_status
	}
	if header.entry_count == 0 {
		return "", .Not_Found
	}

	target_hash := message_id_hash(message_id)
	low := 0
	high := int(header.entry_count)
	for low < high {
		mid := low + (high - low) / 2
		slot_off := PACK_HEADER_SIZE + mid * PACK_ENTRY_SIZE
		mid_hash := byte_order.read_u64_little_endian(pack_bytes, slot_off)
		if mid_hash == target_hash {
			rel_offset := byte_order.read_u32_little_endian(pack_bytes, slot_off + 8)
			entry_length := byte_order.read_u32_little_endian(pack_bytes, slot_off + 12)
			if u64(rel_offset) + u64(entry_length) > u64(header.payload_length) || entry_length > MESSAGE_PATTERN_MAX_BYTES {
				return "", .Truncated_Payload
			}
			abs_start := int(header.payload_offset) + int(rel_offset)
			abs_end := abs_start + int(entry_length)
			return string(pack_bytes[abs_start:abs_end]), .Ok
		}
		if mid_hash < target_hash {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return "", .Not_Found
}

// pack_format_message looks up message_id inside pack_bytes and formats the
// resulting MF2 message in the pack's canonical BCP 47 language.
pack_format_message :: proc "contextless" (
	pack_bytes: []u8,
	message_id: string,
	arguments: []Message_Argument,
	destination: []u8,
) -> (written: int, pack_status: Pack_Status, message_status: Message_Status) {
	header, header_status := pack_read_header(pack_bytes)
	if header_status != .Ok {
		return 0, header_status, .Ok
	}
	pattern, lookup_status := pack_lookup(pack_bytes, message_id)
	if lookup_status != .Ok {
		return 0, lookup_status, .Ok
	}
	locale_tag := pack_language_tag(&header)
	count, fmt_status := message_format(pattern, locale_tag, arguments, destination)
	return count, .Ok, fmt_status
}
