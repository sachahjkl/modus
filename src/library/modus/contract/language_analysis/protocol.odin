// Shared-memory language analysis protocol records, closed enums, border
// converters, and MODLAEF1 snapshot header (src/md/features/language_analysis.md).
package language_analysis

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: 8-byte ASCII signature for Language Analysis Exchange Format v1.
SNAPSHOT_MAGIC :: [8]u8{'M', 'O', 'D', 'L', 'A', 'E', 'F', '1'}
// Format property: current binary layout version.
SNAPSHOT_VERSION :: u32(1)
// Format property: fixed serialized header size in bytes (64-bit aligned).
SNAPSHOT_HEADER_SIZE :: 72
// Format property: fixed ring request and response record sizes in bytes.
RING_REQUEST_SIZE :: 32
RING_RESPONSE_SIZE :: 32
// Format property: row table alignment requirement in bytes.
SECTION_ALIGNMENT :: 4

// Closed set of analysis operations requested by edit over the analysis ring.
Analysis_Request_Kind :: enum u8 {
	Full_Document = 1,
	Hover         = 2,
	Definition    = 3,
	Completions   = 4,
}

// Closed severity levels for editor diagnostics.
Analysis_Diagnostic_Severity :: enum u8 {
	Error   = 1,
	Warning = 2,
	Note    = 3,
}

// Closed semantic token categories rendered by edit.
Semantic_Token_Kind :: enum u8 {
	Keyword      = 1,
	Identifier   = 2,
	Number       = 3,
	Unit         = 4,
	Text_Literal = 5,
	Enum_Member  = 6,
	Hash_Literal = 7,
	Operator     = 8,
	Punctuation  = 9,
	Comment      = 10,
	Binding      = 11,
}

// Closed completion item kinds offered by edit.
Completion_Kind :: enum u8 {
	Keyword     = 1,
	Binding     = 2,
	Field       = 3,
	Command     = 4,
	Enum_Member = 5,
	Unit        = 6,
}

// Closed refusal reasons returned by encoders, validators, and analyzers.
Analysis_Refusal :: enum u8 {
	None                  = 0,
	Buffer_Too_Small      = 1,
	Bad_Magic             = 2,
	Unsupported_Version   = 3,
	Bad_Size              = 4,
	Bad_Alignment         = 5,
	Section_Out_Of_Bounds = 6,
	Section_Overlap       = 7,
	Unknown_Enum_Word     = 8,
	String_Out_Of_Bounds  = 9,
	Span_Order_Invalid    = 10,
	Capacity_Exceeded     = 11,
	Bad_Request           = 12,
}

request_kind_of_word :: proc "contextless" (word: u64) -> (kind: Analysis_Request_Kind, ok: bool) {
	return enum_word.member_of_word(Analysis_Request_Kind, word)
}

diagnostic_severity_of_word :: proc "contextless" (word: u64) -> (severity: Analysis_Diagnostic_Severity, ok: bool) {
	return enum_word.member_of_word(Analysis_Diagnostic_Severity, word)
}

semantic_token_kind_of_word :: proc "contextless" (word: u64) -> (kind: Semantic_Token_Kind, ok: bool) {
	return enum_word.member_of_word(Semantic_Token_Kind, word)
}

completion_kind_of_word :: proc "contextless" (word: u64) -> (kind: Completion_Kind, ok: bool) {
	return enum_word.member_of_word(Completion_Kind, word)
}

refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Analysis_Refusal, ok: bool) {
	return enum_word.member_of_word(Analysis_Refusal, word)
}

// Fixed-size request record written by edit into the analyzer ring.
Analysis_Ring_Request :: struct {
	request_id:          u64,
	document_generation: u64,
	cursor_offset:       u32,
	source_bytes:        u32,
	kind_word:           u32,
	flags:               u32,
}
#assert(size_of(Analysis_Ring_Request) == RING_REQUEST_SIZE)

// Fixed-size response record written by the analyzer back to edit.
Analysis_Ring_Response :: struct {
	request_id:          u64,
	document_generation: u64,
	snapshot_bytes:      u32,
	diagnostic_count:    u32,
	refusal_word:        u32,
	flags:               u32,
}
#assert(size_of(Analysis_Ring_Response) == RING_RESPONSE_SIZE)

// Header of one contiguous MODLAEF1 snapshot in lent shared memory.
Analysis_Snapshot_Header :: struct {
	magic:               [8]u8,
	version:             u32,
	total_bytes:         u32,
	document_generation: u64,
	diagnostics_offset:  u32,
	diagnostics_count:   u32,
	tokens_offset:       u32,
	tokens_count:        u32,
	completions_offset:  u32,
	completions_count:   u32,
	definitions_offset:  u32,
	definitions_count:   u32,
	hovers_offset:       u32,
	hovers_count:        u32,
	strings_offset:      u32,
	strings_bytes:       u32,
}
#assert(size_of(Analysis_Snapshot_Header) == SNAPSHOT_HEADER_SIZE)

// ring_request_validate checks one ring request at the analyzer border.
ring_request_validate :: proc "contextless" (request: Analysis_Ring_Request) -> (kind: Analysis_Request_Kind, refusal: Analysis_Refusal) {
	if request.request_id == 0 || request.flags != 0 {
		return {}, .Bad_Request
	}
	parsed_kind, kind_ok := request_kind_of_word(u64(request.kind_word))
	if !kind_ok {
		return {}, .Unknown_Enum_Word
	}
	if request.cursor_offset > request.source_bytes {
		return {}, .Span_Order_Invalid
	}
	return parsed_kind, .None
}

// ring_response_validate checks one ring response at the editor border.
ring_response_validate :: proc "contextless" (response: Analysis_Ring_Response, snapshot_capacity: u32) -> (status: Analysis_Refusal, refusal: Analysis_Refusal) {
	if response.request_id == 0 || response.flags != 0 {
		return {}, .Bad_Request
	}
	parsed_status, status_ok := refusal_of_word(u64(response.refusal_word))
	if !status_ok {
		return {}, .Unknown_Enum_Word
	}
	if response.snapshot_bytes > snapshot_capacity {
		return {}, .Bad_Size
	}
	return parsed_status, .None
}

// snapshot_header_write encodes header in canonical little-endian byte order.
snapshot_header_write :: proc "contextless" (out: []u8, header: Analysis_Snapshot_Header) -> Analysis_Refusal {
	if len(out) < SNAPSHOT_HEADER_SIZE {
		return .Buffer_Too_Small
	}
	for index in 0 ..< 8 {
		out[index] = header.magic[index]
	}
	byte_order.write_u32_little_endian(out, 8, header.version)
	byte_order.write_u32_little_endian(out, 12, header.total_bytes)
	byte_order.write_u64_little_endian(out, 16, header.document_generation)
	byte_order.write_u32_little_endian(out, 24, header.diagnostics_offset)
	byte_order.write_u32_little_endian(out, 28, header.diagnostics_count)
	byte_order.write_u32_little_endian(out, 32, header.tokens_offset)
	byte_order.write_u32_little_endian(out, 36, header.tokens_count)
	byte_order.write_u32_little_endian(out, 40, header.completions_offset)
	byte_order.write_u32_little_endian(out, 44, header.completions_count)
	byte_order.write_u32_little_endian(out, 48, header.definitions_offset)
	byte_order.write_u32_little_endian(out, 52, header.definitions_count)
	byte_order.write_u32_little_endian(out, 56, header.hovers_offset)
	byte_order.write_u32_little_endian(out, 60, header.hovers_count)
	byte_order.write_u32_little_endian(out, 64, header.strings_offset)
	byte_order.write_u32_little_endian(out, 68, header.strings_bytes)
	return .None
}

// snapshot_header_read decodes header in canonical little-endian byte order.
snapshot_header_read :: proc "contextless" (bytes: []u8) -> (header: Analysis_Snapshot_Header, refusal: Analysis_Refusal) {
	if len(bytes) < SNAPSHOT_HEADER_SIZE {
		return {}, .Buffer_Too_Small
	}
	for index in 0 ..< 8 {
		header.magic[index] = bytes[index]
	}
	header.version = byte_order.read_u32_little_endian(bytes, 8)
	header.total_bytes = byte_order.read_u32_little_endian(bytes, 12)
	header.document_generation = byte_order.read_u64_little_endian(bytes, 16)
	header.diagnostics_offset = byte_order.read_u32_little_endian(bytes, 24)
	header.diagnostics_count = byte_order.read_u32_little_endian(bytes, 28)
	header.tokens_offset = byte_order.read_u32_little_endian(bytes, 32)
	header.tokens_count = byte_order.read_u32_little_endian(bytes, 36)
	header.completions_offset = byte_order.read_u32_little_endian(bytes, 40)
	header.completions_count = byte_order.read_u32_little_endian(bytes, 44)
	header.definitions_offset = byte_order.read_u32_little_endian(bytes, 48)
	header.definitions_count = byte_order.read_u32_little_endian(bytes, 52)
	header.hovers_offset = byte_order.read_u32_little_endian(bytes, 56)
	header.hovers_count = byte_order.read_u32_little_endian(bytes, 60)
	header.strings_offset = byte_order.read_u32_little_endian(bytes, 64)
	header.strings_bytes = byte_order.read_u32_little_endian(bytes, 68)
	return header, .None
}
