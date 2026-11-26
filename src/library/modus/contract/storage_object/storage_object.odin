// Wire contract for read-only object mapping, bounded ambiguity tables, and
// durable pin requests on the storage service (src/md/features/objects_by_hash.md).
//
// All integers are little-endian with zero implicit padding. Every decoder
// enforces exact buffer lengths (refusing truncated inputs and trailing bytes),
// validates all closed enums through single-border converters, requires zero
// reserved fields and unknown flag bits, and validates UTF-8 names and strict
// '/' object paths.
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package storage_object_contract

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/store"

// Format property: 6-byte magic and version identifying version 1 of the
// storage read-only object wire contract.
WIRE_MAGIC :: [6]u8{'S', 'T', 'O', 'B', 'J', '1'}
WIRE_VERSION :: u16(1)

// Format property: fixed byte sizes of wire headers and records.
ENVELOPE_SIZE :: 12
MAP_OBJECT_REQUEST_HEADER_SIZE :: 60
MAP_OBJECT_ANSWER_SIZE :: 64
AMBIGUITY_TABLE_HEADER_SIZE :: 24
AMBIGUITY_ENTRY_HEADER_SIZE :: 48
PIN_REQUEST_SIZE :: 56
UNPIN_REQUEST_SIZE :: 56
LIST_PINS_HEADER_SIZE :: 24
PIN_RECORD_SIZE :: 48

// Format property: upper bound on ambiguity match records carried in one
// call-region reply so variable-length match names never overflow the 56-byte
// Error_Record or exceed a bounded call region.
AMBIGUITY_RECORD_LIMIT :: 64

// Format property: maximum byte length of a tree root label in an ambiguity
// record, matching store.ENTRY_NAME_CAPACITY.
TREE_NAME_LIMIT :: store.ENTRY_NAME_CAPACITY

// Plan value: upper bound on durable pin records returned in one List_Pins_Answer,
// matching storage's durable pin table capacity.
LIST_PINS_LIMIT :: 512

// Closed set of wire message kinds carried in the common 12-byte envelope.
// Zero is reserved as unset and refused at the border.
Wire_Kind :: enum u8 {
	Map_Object_Request = 1,
	Map_Object_Answer  = 2,
	Ambiguity_Table    = 3,
	Pin_Request        = 4,
	Unpin_Request      = 5,
	List_Pins_Answer   = 6,
}

// wire_kind_of_word converts a raw wire byte into a Wire_Kind member.
wire_kind_of_word :: proc "contextless" (word: u64) -> (kind: Wire_Kind, ok: bool) {
	return enum_word.member_of_word(Wire_Kind, word)
}

// Closed set of results returned by storage for a read-only object map request.
Map_Object_Result :: enum u8 {
	Mapped        = 0, // Object resolved and read-only handle granted.
	Not_Found     = 1, // Path matched zero objects (or named a subtree).
	Ambiguous     = 2, // Path matched two or more granted trees; see ambiguity table.
	Hash_Mismatch = 3, // Object exists at path, but its intact hash differs from expected_hash.
	Path_Refused  = 4, // Path failed store.object_path_validate.
	Quota_Full    = 5, // Per-principal or machine cache quota exhausted with no idle entry to evict.
	Damaged       = 6, // Stored bytes failed integrity verification.
	Unavailable   = 7, // Backing disk store is absent, silent, or unusable.
}

// map_object_result_of_word converts a raw wire byte into a Map_Object_Result member.
map_object_result_of_word :: proc "contextless" (word: u64) -> (result: Map_Object_Result, ok: bool) {
	return enum_word.member_of_word(Map_Object_Result, word)
}

// Closed set of flags accepted in Map_Object_Request.
Map_Object_Flag :: enum u32 {
	Has_Expected_Hash = 0, // Caller supplied expected_hash to pin exact object bytes.
}

Map_Object_Flags :: bit_set[Map_Object_Flag; u32]

// Format property: bit mask of all defined Map_Object_Flag bits.
MAP_OBJECT_FLAGS_KNOWN_MASK :: u32(1) << u32(Map_Object_Flag.Has_Expected_Hash)

// Closed set of wire encoding and border validation refusals.
Wire_Problem :: enum u8 {
	None                = 0,
	Truncated           = 1,
	Trailing_Bytes      = 2,
	Buffer_Too_Small    = 3,
	Bad_Magic           = 4,
	Bad_Version         = 5,
	Bad_Kind            = 6,
	Bad_Enum            = 7,
	Bad_Flags           = 8,
	Non_Zero_Reserved   = 9,
	Invalid_Path        = 10,
	Invalid_Text        = 11,
	Count_Exceeds_Limit = 12,
	Invalid_State       = 13,
}

// wire_problem_of_word converts a transport word into a Wire_Problem member.
wire_problem_of_word :: proc "contextless" (word: u64) -> (problem: Wire_Problem, ok: bool) {
	return enum_word.member_of_word(Wire_Problem, word)
}

// Decoded read-only object map request.
Map_Object_Request :: struct {
	path:               string,
	has_expected_hash:  bool,
	expected_hash:      blake3.Hash,
	ambiguity_capacity: u32,
}

// Decoded read-only object map answer.
Map_Object_Answer :: struct {
	result:          Map_Object_Result,
	path_problem:    store.Object_Path_Problem,
	ambiguity_total: u32,
	size:            u64,
	hash:            blake3.Hash,
}

// One matching tree entry in a call-region Ambiguity_Table.
Ambiguity_Entry :: struct {
	grant_index: u32,
	tree_name:   string,
	path:        string,
	size:        u64,
	hash:        blake3.Hash,
}

// Decoded durable pin or unpin request.
Pin_Request :: struct {
	store_index: u32,
	hash:        blake3.Hash,
}

// One durable pin record returned in List_Pins_Answer.
Pin_Record :: struct {
	principal_id: u64,
	store_index:  u32,
	pin_count:    u32,
	hash:         blake3.Hash,
}

// map_object_result_outcome maps a Map_Object_Result onto the standard
// Call_Outcome and errors.Kind pair required by the storage contract.
map_object_result_outcome :: proc "contextless" (result: Map_Object_Result) -> (outcome: call_outcome.Call_Outcome, kind: errors.Kind) {
	switch result {
	case .Mapped:
		return .Succeeded, .None
	case .Not_Found:
		return .Nothing_Has_That_Name, .Absent
	case .Ambiguous:
		return .Argument_Refused, .Bad_Value
	case .Hash_Mismatch:
		return .Another_Change_Came_First, .State
	case .Path_Refused:
		return .Argument_Refused, .Bad_Byte
	case .Quota_Full:
		return .Budget_Or_Capacity_Exhausted, .Full
	case .Damaged:
		return .Data_Damaged, .Damaged
	case .Unavailable:
		return .Callee_Unavailable, .Device
	}
	return .Answer_Unreadable, .Bad_Value
}

@(private = "file")
write_envelope :: proc "contextless" (output: []u8, kind: Wire_Kind) {
	magic := WIRE_MAGIC
	copy(output[0:6], magic[:])
	byte_order.write_u16_little_endian(output, 6, WIRE_VERSION)
	output[8] = u8(kind)
	output[9] = 0
	byte_order.write_u16_little_endian(output, 10, 0)
}

@(private = "file")
read_envelope :: proc "contextless" (bytes: []u8, expected_kind: Wire_Kind) -> Wire_Problem {
	if len(bytes) < ENVELOPE_SIZE {
		return .Truncated
	}
	magic := WIRE_MAGIC
	for i in 0 ..< 6 {
		if bytes[i] != magic[i] {
			return .Bad_Magic
		}
	}
	if byte_order.read_u16_little_endian(bytes, 6) != WIRE_VERSION {
		return .Bad_Version
	}
	kind, kind_ok := wire_kind_of_word(u64(bytes[8]))
	if !kind_ok || kind != expected_kind {
		return .Bad_Kind
	}
	if bytes[9] != 0 || byte_order.read_u16_little_endian(bytes, 10) != 0 {
		return .Non_Zero_Reserved
	}
	return .None
}

// -----------------------------------------------------------------------------
// Map_Object_Request
// -----------------------------------------------------------------------------

// map_object_request_encoded_size returns the canonical byte length of a valid
// Map_Object_Request, or 0 if path is invalid.
map_object_request_encoded_size :: proc "contextless" (path: string) -> int {
	if _, p_problem, _, _ := store.object_path_validate(path); p_problem != .None {
		return 0
	}
	return MAP_OBJECT_REQUEST_HEADER_SIZE + len(path)
}

// map_object_request_encode validates request and writes canonical wire bytes
// into output. On refusal, output is untouched and written is 0.
map_object_request_encode :: proc "contextless" (request: Map_Object_Request, output: []u8) -> (written: int, problem: Wire_Problem) {
	if _, p_problem, _, _ := store.object_path_validate(request.path); p_problem != .None {
		return 0, .Invalid_Path
	}
	if request.ambiguity_capacity > AMBIGUITY_RECORD_LIMIT {
		return 0, .Count_Exceeds_Limit
	}
	if !request.has_expected_hash && request.expected_hash != {} {
		return 0, .Invalid_State
	}
	required := MAP_OBJECT_REQUEST_HEADER_SIZE + len(request.path)
	if len(output) < required {
		return 0, .Buffer_Too_Small
	}
	write_envelope(output, .Map_Object_Request)
	flags: u32 = request.has_expected_hash ? MAP_OBJECT_FLAGS_KNOWN_MASK : 0
	byte_order.write_u32_little_endian(output, 12, flags)
	byte_order.write_u32_little_endian(output, 16, u32(len(request.path)))
	byte_order.write_u32_little_endian(output, 20, request.ambiguity_capacity)
	byte_order.write_u32_little_endian(output, 24, 0)
	hash := request.expected_hash
	copy(output[28:60], hash[:])
	copy(output[60:required], request.path)
	return required, .None
}

// map_object_request_decode validates every header field, flag bit, reserved
// word, exact length, and strict '/' path grammar. Decoded path borrows bytes.
map_object_request_decode :: proc "contextless" (bytes: []u8) -> (request: Map_Object_Request, problem: Wire_Problem) {
	if env := read_envelope(bytes, .Map_Object_Request); env != .None {
		return {}, env
	}
	if len(bytes) < MAP_OBJECT_REQUEST_HEADER_SIZE {
		return {}, .Truncated
	}
	flags := byte_order.read_u32_little_endian(bytes, 12)
	if flags & ~MAP_OBJECT_FLAGS_KNOWN_MASK != 0 {
		return {}, .Bad_Flags
	}
	path_length := byte_order.read_u32_little_endian(bytes, 16)
	ambiguity_capacity := byte_order.read_u32_little_endian(bytes, 20)
	reserved := byte_order.read_u32_little_endian(bytes, 24)
	if reserved != 0 {
		return {}, .Non_Zero_Reserved
	}
	if ambiguity_capacity > AMBIGUITY_RECORD_LIMIT {
		return {}, .Count_Exceeds_Limit
	}
	if path_length == 0 || path_length > store.OBJECT_PATH_LIMIT {
		return {}, .Invalid_Path
	}
	expected_total := MAP_OBJECT_REQUEST_HEADER_SIZE + int(path_length)
	if len(bytes) < expected_total {
		return {}, .Truncated
	}
	if len(bytes) > expected_total {
		return {}, .Trailing_Bytes
	}
	has_expected_hash := (flags & MAP_OBJECT_FLAGS_KNOWN_MASK) != 0
	expected_hash: blake3.Hash
	copy(expected_hash[:], bytes[28:60])
	if !has_expected_hash && expected_hash != {} {
		return {}, .Invalid_State
	}
	path := string(bytes[60:expected_total])
	if _, p_problem, _, _ := store.object_path_validate(path); p_problem != .None {
		return {}, .Invalid_Path
	}
	return {
		path               = path,
		has_expected_hash  = has_expected_hash,
		expected_hash      = expected_hash,
		ambiguity_capacity = ambiguity_capacity,
	}, .None
}

// -----------------------------------------------------------------------------
// Map_Object_Answer
// -----------------------------------------------------------------------------

@(private = "file")
map_object_answer_validate_fields :: proc "contextless" (answer: Map_Object_Answer) -> Wire_Problem {
	result, result_ok := map_object_result_of_word(u64(answer.result))
	if !result_ok {
		return .Bad_Enum
	}
	path_problem, path_ok := store.object_path_problem_of_word(u64(answer.path_problem))
	if !path_ok {
		return .Bad_Enum
	}
	switch result {
	case .Mapped:
		if path_problem != .None || answer.ambiguity_total != 0 {
			return .Invalid_State
		}
	case .Ambiguous:
		if path_problem != .None || answer.ambiguity_total < 2 || answer.size != 0 || answer.hash != {} {
			return .Invalid_State
		}
	case .Hash_Mismatch:
		if path_problem != .None || answer.ambiguity_total != 0 {
			return .Invalid_State
		}
	case .Path_Refused:
		if path_problem == .None || answer.ambiguity_total != 0 || answer.size != 0 || answer.hash != {} {
			return .Invalid_State
		}
	case .Not_Found, .Quota_Full, .Damaged, .Unavailable:
		if path_problem != .None || answer.ambiguity_total != 0 || answer.size != 0 || answer.hash != {} {
			return .Invalid_State
		}
	}
	return .None
}

// map_object_answer_encode writes a canonical 64-byte Map_Object_Answer.
map_object_answer_encode :: proc "contextless" (answer: Map_Object_Answer, output: []u8) -> (written: int, problem: Wire_Problem) {
	if p := map_object_answer_validate_fields(answer); p != .None {
		return 0, p
	}
	if len(output) < MAP_OBJECT_ANSWER_SIZE {
		return 0, .Buffer_Too_Small
	}
	write_envelope(output, .Map_Object_Answer)
	output[12] = u8(answer.result)
	output[13] = u8(answer.path_problem)
	byte_order.write_u16_little_endian(output, 14, 0)
	byte_order.write_u32_little_endian(output, 16, answer.ambiguity_total)
	byte_order.write_u32_little_endian(output, 20, 0)
	byte_order.write_u64_little_endian(output, 24, answer.size)
	hash := answer.hash
	copy(output[32:64], hash[:])
	return MAP_OBJECT_ANSWER_SIZE, .None
}

// map_object_answer_decode validates and decodes a canonical 64-byte
// Map_Object_Answer.
map_object_answer_decode :: proc "contextless" (bytes: []u8) -> (answer: Map_Object_Answer, problem: Wire_Problem) {
	if env := read_envelope(bytes, .Map_Object_Answer); env != .None {
		return {}, env
	}
	if len(bytes) < MAP_OBJECT_ANSWER_SIZE {
		return {}, .Truncated
	}
	if len(bytes) > MAP_OBJECT_ANSWER_SIZE {
		return {}, .Trailing_Bytes
	}
	result, result_ok := map_object_result_of_word(u64(bytes[12]))
	if !result_ok {
		return {}, .Bad_Enum
	}
	path_problem, path_ok := store.object_path_problem_of_word(u64(bytes[13]))
	if !path_ok {
		return {}, .Bad_Enum
	}
	if byte_order.read_u16_little_endian(bytes, 14) != 0 || byte_order.read_u32_little_endian(bytes, 20) != 0 {
		return {}, .Non_Zero_Reserved
	}
	decoded := Map_Object_Answer {
		result          = result,
		path_problem    = path_problem,
		ambiguity_total = byte_order.read_u32_little_endian(bytes, 16),
		size            = byte_order.read_u64_little_endian(bytes, 24),
	}
	copy(decoded.hash[:], bytes[32:64])
	if p := map_object_answer_validate_fields(decoded); p != .None {
		return {}, p
	}
	return decoded, .None
}

// -----------------------------------------------------------------------------
// Bounded Ambiguity Table (call-region encoding)
// -----------------------------------------------------------------------------

// ambiguity_table_encoded_size computes the exact byte count for entries, or 0
// when any entry violates format bounds or text/path rules.
ambiguity_table_encoded_size :: proc "contextless" (entries: []Ambiguity_Entry) -> int {
	if len(entries) > AMBIGUITY_RECORD_LIMIT {
		return 0
	}
	total := AMBIGUITY_TABLE_HEADER_SIZE
	for &entry in entries {
		if len(entry.tree_name) == 0 || len(entry.tree_name) > TREE_NAME_LIMIT {
			return 0
		}
		if refusal, _, _ := store.name_refusal(entry.tree_name); refusal != .None {
			return 0
		}
		if _, p_problem, _, _ := store.object_path_validate(entry.path); p_problem != .None {
			return 0
		}
		total += AMBIGUITY_ENTRY_HEADER_SIZE + len(entry.tree_name) + len(entry.path)
	}
	return total
}

// ambiguity_table_encode validates total_matches and entries and writes a
// canonical call-region ambiguity table. On refusal, output is untouched.
ambiguity_table_encode :: proc "contextless" (total_matches: u32, entries: []Ambiguity_Entry, output: []u8) -> (written: int, problem: Wire_Problem) {
	if len(entries) > AMBIGUITY_RECORD_LIMIT {
		return 0, .Count_Exceeds_Limit
	}
	if total_matches < u32(len(entries)) {
		return 0, .Invalid_State
	}
	if len(entries) > 0 && total_matches < 2 {
		return 0, .Invalid_State
	}
	total := AMBIGUITY_TABLE_HEADER_SIZE
	for &entry in entries {
		if len(entry.tree_name) == 0 || len(entry.tree_name) > TREE_NAME_LIMIT {
			return 0, .Invalid_Text
		}
		if refusal, _, _ := store.name_refusal(entry.tree_name); refusal != .None {
			return 0, .Invalid_Text
		}
		if _, p_problem, _, _ := store.object_path_validate(entry.path); p_problem != .None {
			return 0, .Invalid_Path
		}
		total += AMBIGUITY_ENTRY_HEADER_SIZE + len(entry.tree_name) + len(entry.path)
	}
	if len(output) < total {
		return 0, .Buffer_Too_Small
	}

	write_envelope(output, .Ambiguity_Table)
	byte_order.write_u32_little_endian(output, 12, total_matches)
	byte_order.write_u32_little_endian(output, 16, u32(len(entries)))
	byte_order.write_u32_little_endian(output, 20, 0)

	cursor := AMBIGUITY_TABLE_HEADER_SIZE
	for &entry in entries {
		byte_order.write_u32_little_endian(output, cursor + 0, entry.grant_index)
		byte_order.write_u16_little_endian(output, cursor + 4, u16(len(entry.tree_name)))
		byte_order.write_u16_little_endian(output, cursor + 6, u16(len(entry.path)))
		byte_order.write_u64_little_endian(output, cursor + 8, entry.size)
		hash := entry.hash
		copy(output[cursor + 16:cursor + 48], hash[:])
		cursor += AMBIGUITY_ENTRY_HEADER_SIZE
		copy(output[cursor:cursor + len(entry.tree_name)], entry.tree_name)
		cursor += len(entry.tree_name)
		copy(output[cursor:cursor + len(entry.path)], entry.path)
		cursor += len(entry.path)
	}
	return total, .None
}

// ambiguity_table_decode validates every record in bytes and writes up to
// len(out) decoded entries whose strings borrow from bytes. Always validates
// the entire payload before returning, refusing truncated or trailing bytes.
ambiguity_table_decode :: proc "contextless" (bytes: []u8, out: []Ambiguity_Entry) -> (total_matches: u32, record_count: int, written: int, problem: Wire_Problem) {
	if env := read_envelope(bytes, .Ambiguity_Table); env != .None {
		return 0, 0, 0, env
	}
	if len(bytes) < AMBIGUITY_TABLE_HEADER_SIZE {
		return 0, 0, 0, .Truncated
	}
	total_matches = byte_order.read_u32_little_endian(bytes, 12)
	raw_count := byte_order.read_u32_little_endian(bytes, 16)
	reserved := byte_order.read_u32_little_endian(bytes, 20)
	if reserved != 0 {
		return 0, 0, 0, .Non_Zero_Reserved
	}
	if raw_count > AMBIGUITY_RECORD_LIMIT {
		return 0, 0, 0, .Count_Exceeds_Limit
	}
	if total_matches < raw_count || (raw_count > 0 && total_matches < 2) {
		return 0, 0, 0, .Invalid_State
	}

	// Pass 1: validate entire payload before mutating out.
	cursor := AMBIGUITY_TABLE_HEADER_SIZE
	for _ in 0 ..< int(raw_count) {
		if len(bytes) - cursor < AMBIGUITY_ENTRY_HEADER_SIZE {
			return 0, 0, 0, .Truncated
		}
		name_len := int(byte_order.read_u16_little_endian(bytes, cursor + 4))
		path_len := int(byte_order.read_u16_little_endian(bytes, cursor + 6))
		if name_len == 0 || name_len > TREE_NAME_LIMIT {
			return 0, 0, 0, .Invalid_Text
		}
		if path_len == 0 || path_len > store.OBJECT_PATH_LIMIT {
			return 0, 0, 0, .Invalid_Path
		}
		cursor += AMBIGUITY_ENTRY_HEADER_SIZE
		if len(bytes) - cursor < name_len + path_len {
			return 0, 0, 0, .Truncated
		}
		tree_name := string(bytes[cursor:cursor + name_len])
		if refusal, _, _ := store.name_refusal(tree_name); refusal != .None {
			return 0, 0, 0, .Invalid_Text
		}
		path := string(bytes[cursor + name_len:cursor + name_len + path_len])
		if _, p_problem, _, _ := store.object_path_validate(path); p_problem != .None {
			return 0, 0, 0, .Invalid_Path
		}
		cursor += name_len + path_len
	}
	if cursor != len(bytes) {
		return 0, 0, 0, .Trailing_Bytes
	}

	// Pass 2: populate out up to len(out).
	cursor = AMBIGUITY_TABLE_HEADER_SIZE
	for index in 0 ..< int(raw_count) {
		grant_index := byte_order.read_u32_little_endian(bytes, cursor + 0)
		name_len := int(byte_order.read_u16_little_endian(bytes, cursor + 4))
		path_len := int(byte_order.read_u16_little_endian(bytes, cursor + 6))
		size := byte_order.read_u64_little_endian(bytes, cursor + 8)
		hash: blake3.Hash
		copy(hash[:], bytes[cursor + 16:cursor + 48])
		cursor += AMBIGUITY_ENTRY_HEADER_SIZE
		tree_name := string(bytes[cursor:cursor + name_len])
		path := string(bytes[cursor + name_len:cursor + name_len + path_len])
		cursor += name_len + path_len
		if index < len(out) {
			out[index] = {
				grant_index = grant_index,
				tree_name   = tree_name,
				path        = path,
				size        = size,
				hash        = hash,
			}
			written += 1
		}
	}
	return total_matches, int(raw_count), written, .None
}

// -----------------------------------------------------------------------------
// Pin_Request / Unpin_Request
// -----------------------------------------------------------------------------

@(private = "file")
pin_like_encode :: proc "contextless" (kind: Wire_Kind, request: Pin_Request, output: []u8) -> (written: int, problem: Wire_Problem) {
	if len(output) < PIN_REQUEST_SIZE {
		return 0, .Buffer_Too_Small
	}
	write_envelope(output, kind)
	byte_order.write_u32_little_endian(output, 12, 0) // flags (none defined)
	byte_order.write_u32_little_endian(output, 16, request.store_index)
	byte_order.write_u32_little_endian(output, 20, 0) // reserved
	hash := request.hash
	copy(output[24:56], hash[:])
	return PIN_REQUEST_SIZE, .None
}

@(private = "file")
pin_like_decode :: proc "contextless" (expected_kind: Wire_Kind, bytes: []u8) -> (request: Pin_Request, problem: Wire_Problem) {
	if env := read_envelope(bytes, expected_kind); env != .None {
		return {}, env
	}
	if len(bytes) < PIN_REQUEST_SIZE {
		return {}, .Truncated
	}
	if len(bytes) > PIN_REQUEST_SIZE {
		return {}, .Trailing_Bytes
	}
	if byte_order.read_u32_little_endian(bytes, 12) != 0 {
		return {}, .Bad_Flags
	}
	if byte_order.read_u32_little_endian(bytes, 20) != 0 {
		return {}, .Non_Zero_Reserved
	}
	request.store_index = byte_order.read_u32_little_endian(bytes, 16)
	copy(request.hash[:], bytes[24:56])
	return request, .None
}

pin_request_encode :: proc "contextless" (request: Pin_Request, output: []u8) -> (written: int, problem: Wire_Problem) {
	return pin_like_encode(.Pin_Request, request, output)
}

pin_request_decode :: proc "contextless" (bytes: []u8) -> (request: Pin_Request, problem: Wire_Problem) {
	return pin_like_decode(.Pin_Request, bytes)
}

unpin_request_encode :: proc "contextless" (request: Pin_Request, output: []u8) -> (written: int, problem: Wire_Problem) {
	return pin_like_encode(.Unpin_Request, request, output)
}

unpin_request_decode :: proc "contextless" (bytes: []u8) -> (request: Pin_Request, problem: Wire_Problem) {
	return pin_like_decode(.Unpin_Request, bytes)
}

// -----------------------------------------------------------------------------
// List_Pins_Answer
// -----------------------------------------------------------------------------

// list_pins_answer_encoded_size returns the exact wire byte count for count
// pin records, or 0 if count exceeds LIST_PINS_LIMIT.
list_pins_answer_encoded_size :: proc "contextless" (count: int) -> int {
	if count < 0 || count > LIST_PINS_LIMIT {
		return 0
	}
	return LIST_PINS_HEADER_SIZE + count * PIN_RECORD_SIZE
}

// list_pins_answer_encode validates records (each pin_count >= 1) and writes a
// canonical List_Pins_Answer into output. On refusal, output is untouched.
list_pins_answer_encode :: proc "contextless" (total_pins: u32, records: []Pin_Record, output: []u8) -> (written: int, problem: Wire_Problem) {
	if len(records) > LIST_PINS_LIMIT {
		return 0, .Count_Exceeds_Limit
	}
	if total_pins < u32(len(records)) {
		return 0, .Invalid_State
	}
	for &rec in records {
		if rec.pin_count == 0 {
			return 0, .Invalid_State
		}
	}
	required := LIST_PINS_HEADER_SIZE + len(records) * PIN_RECORD_SIZE
	if len(output) < required {
		return 0, .Buffer_Too_Small
	}
	write_envelope(output, .List_Pins_Answer)
	byte_order.write_u32_little_endian(output, 12, total_pins)
	byte_order.write_u32_little_endian(output, 16, u32(len(records)))
	byte_order.write_u32_little_endian(output, 20, 0)
	cursor := LIST_PINS_HEADER_SIZE
	for &rec in records {
		byte_order.write_u64_little_endian(output, cursor + 0, rec.principal_id)
		byte_order.write_u32_little_endian(output, cursor + 8, rec.store_index)
		byte_order.write_u32_little_endian(output, cursor + 12, rec.pin_count)
		hash := rec.hash
		copy(output[cursor + 16:cursor + 48], hash[:])
		cursor += PIN_RECORD_SIZE
	}
	return required, .None
}

// list_pins_answer_decode validates the entire List_Pins_Answer buffer and
// copies up to len(out) pin records. Refuses zero pin_count, non-zero reserved
// words, truncation, and trailing bytes.
list_pins_answer_decode :: proc "contextless" (bytes: []u8, out: []Pin_Record) -> (total_pins: u32, record_count: int, written: int, problem: Wire_Problem) {
	if env := read_envelope(bytes, .List_Pins_Answer); env != .None {
		return 0, 0, 0, env
	}
	if len(bytes) < LIST_PINS_HEADER_SIZE {
		return 0, 0, 0, .Truncated
	}
	total_pins = byte_order.read_u32_little_endian(bytes, 12)
	raw_count := byte_order.read_u32_little_endian(bytes, 16)
	reserved := byte_order.read_u32_little_endian(bytes, 20)
	if reserved != 0 {
		return 0, 0, 0, .Non_Zero_Reserved
	}
	if raw_count > LIST_PINS_LIMIT {
		return 0, 0, 0, .Count_Exceeds_Limit
	}
	if total_pins < raw_count {
		return 0, 0, 0, .Invalid_State
	}
	expected_total := LIST_PINS_HEADER_SIZE + int(raw_count) * PIN_RECORD_SIZE
	if len(bytes) < expected_total {
		return 0, 0, 0, .Truncated
	}
	if len(bytes) > expected_total {
		return 0, 0, 0, .Trailing_Bytes
	}

	// Pass 1: validate all pin records before mutating out.
	for i in 0 ..< int(raw_count) {
		offset := LIST_PINS_HEADER_SIZE + i * PIN_RECORD_SIZE
		if byte_order.read_u32_little_endian(bytes, offset + 12) == 0 {
			return 0, 0, 0, .Invalid_State
		}
	}

	// Pass 2: populate out up to len(out).
	for i in 0 ..< int(raw_count) {
		if i < len(out) {
			offset := LIST_PINS_HEADER_SIZE + i * PIN_RECORD_SIZE
			rec := Pin_Record {
				principal_id = byte_order.read_u64_little_endian(bytes, offset + 0),
				store_index  = byte_order.read_u32_little_endian(bytes, offset + 8),
				pin_count    = byte_order.read_u32_little_endian(bytes, offset + 12),
			}
			copy(rec.hash[:], bytes[offset + 16:offset + 48])
			out[i] = rec
			written += 1
		}
	}
	return total_pins, int(raw_count), written, .None
}
