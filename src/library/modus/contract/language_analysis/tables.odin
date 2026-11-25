// Flat MODLAEF1 table rows, zero-copy encoder, hostile-input validator, and
// typed readers (src/md/features/language_analysis.md).
package language_analysis

import "modus:contract/byte_order"

// Format property: serialized byte widths of each flat table row.
DIAGNOSTIC_ROW_SIZE :: 32
SEMANTIC_TOKEN_ROW_SIZE :: 16
COMPLETION_ROW_SIZE :: 24
DEFINITION_SPAN_SIZE :: 24
HOVER_ENTRY_SIZE :: 24

// One diagnostic span with line/column coordinates and string-pool message slice.
Diagnostic_Row :: struct {
	start_offset:   u32,
	end_offset:     u32,
	line:           u32,
	column:         u32,
	severity_word:  u32,
	message_offset: u32,
	message_bytes:  u32,
	reserved:       u32,
}
#assert(size_of(Diagnostic_Row) == DIAGNOSTIC_ROW_SIZE)

// One semantic highlight token covering [start_offset, start_offset + length).
Semantic_Token_Row :: struct {
	start_offset: u32,
	length:       u32,
	kind_word:    u32,
	flags:        u32,
}
#assert(size_of(Semantic_Token_Row) == SEMANTIC_TOKEN_ROW_SIZE)

// One completion candidate referencing label and detail slices in the string pool.
Completion_Row :: struct {
	kind_word:     u32,
	label_offset:  u32,
	label_bytes:   u32,
	detail_offset: u32,
	detail_bytes:  u32,
	reserved:      u32,
}
#assert(size_of(Completion_Row) == COMPLETION_ROW_SIZE)

// Maps an identifier use span [use_start, use_end) to its declaration span.
Definition_Span :: struct {
	use_start:    u32,
	use_end:      u32,
	target_start: u32,
	target_end:   u32,
	name_offset:  u32,
	name_bytes:   u32,
}
#assert(size_of(Definition_Span) == DEFINITION_SPAN_SIZE)

// Hover signature and short summary attached to [start_offset, end_offset).
Hover_Entry :: struct {
	start_offset:     u32,
	end_offset:       u32,
	signature_offset: u32,
	signature_bytes:  u32,
	summary_offset:   u32,
	summary_bytes:    u32,
}
#assert(size_of(Hover_Entry) == HOVER_ENTRY_SIZE)

// Input tables passed to snapshot_encode for one-pass serialization.
Snapshot_Tables :: struct {
	document_generation: u64,
	diagnostics:         []Diagnostic_Row,
	tokens:              []Semantic_Token_Row,
	completions:         []Completion_Row,
	definitions:         []Definition_Span,
	hovers:              []Hover_Entry,
	strings:             []u8,
}

@(private = "file")
Section_Span :: struct {
	present: bool,
	start:   u64,
	end:     u64,
}

@(private = "file")
align_up_u64 :: proc "contextless" (value: u64, alignment: u64) -> u64 {
	return (value + alignment - 1) &~ (alignment - 1)
}

@(private = "file")
string_span_valid :: proc "contextless" (offset, count, pool_bytes: u32) -> bool {
	if count == 0 {
		return offset <= pool_bytes
	}
	return u64(offset) + u64(count) <= u64(pool_bytes)
}

// snapshot_required_bytes computes the exact serialized byte size for tables.
snapshot_required_bytes :: proc "contextless" (tables: Snapshot_Tables) -> (size: u64, ok: bool) {
	cursor := u64(SNAPSHOT_HEADER_SIZE)
	sections := [5][2]u64{
		{u64(len(tables.diagnostics)), DIAGNOSTIC_ROW_SIZE},
		{u64(len(tables.tokens)), SEMANTIC_TOKEN_ROW_SIZE},
		{u64(len(tables.completions)), COMPLETION_ROW_SIZE},
		{u64(len(tables.definitions)), DEFINITION_SPAN_SIZE},
		{u64(len(tables.hovers)), HOVER_ENTRY_SIZE},
	}
	for sec in sections {
		if sec[0] > 0 {
			cursor = align_up_u64(cursor, SECTION_ALIGNMENT)
			bytes := sec[0] * sec[1]
			if bytes > u64(max(u32)) - cursor {
				return 0, false
			}
			cursor += bytes
		}
	}
	if len(tables.strings) > 0 {
		if u64(len(tables.strings)) > u64(max(u32)) - cursor {
			return 0, false
		}
		cursor += u64(len(tables.strings))
	}
	return cursor, cursor <= u64(max(u32))
}

// snapshot_encode validates tables and serializes a canonical MODLAEF1 snapshot into out.
snapshot_encode :: proc "contextless" (tables: Snapshot_Tables, out: []u8) -> (written: int, refusal: Analysis_Refusal) {
	required, fits_u32 := snapshot_required_bytes(tables)
	if !fits_u32 {
		return 0, .Capacity_Exceeded
	}
	if required > u64(len(out)) {
		return 0, .Buffer_Too_Small
	}
	pool_bytes := u32(len(tables.strings))

	// Validate every row before writing so a refused encode never writes a valid magic header.
	for row in tables.diagnostics {
		if row.start_offset > row.end_offset {
			return 0, .Span_Order_Invalid
		}
		if row.reserved != 0 {
			return 0, .Bad_Size
		}
		if _, ok := diagnostic_severity_of_word(u64(row.severity_word)); !ok {
			return 0, .Unknown_Enum_Word
		}
		if !string_span_valid(row.message_offset, row.message_bytes, pool_bytes) {
			return 0, .String_Out_Of_Bounds
		}
	}
	for row in tables.tokens {
		if row.flags != 0 {
			return 0, .Bad_Size
		}
		if _, ok := semantic_token_kind_of_word(u64(row.kind_word)); !ok {
			return 0, .Unknown_Enum_Word
		}
	}
	for row in tables.completions {
		if row.reserved != 0 {
			return 0, .Bad_Size
		}
		if _, ok := completion_kind_of_word(u64(row.kind_word)); !ok {
			return 0, .Unknown_Enum_Word
		}
		if !string_span_valid(row.label_offset, row.label_bytes, pool_bytes) ||
			!string_span_valid(row.detail_offset, row.detail_bytes, pool_bytes) {
			return 0, .String_Out_Of_Bounds
		}
	}
	for row in tables.definitions {
		if row.use_start > row.use_end || row.target_start > row.target_end {
			return 0, .Span_Order_Invalid
		}
		if !string_span_valid(row.name_offset, row.name_bytes, pool_bytes) {
			return 0, .String_Out_Of_Bounds
		}
	}
	for row in tables.hovers {
		if row.start_offset > row.end_offset {
			return 0, .Span_Order_Invalid
		}
		if !string_span_valid(row.signature_offset, row.signature_bytes, pool_bytes) ||
			!string_span_valid(row.summary_offset, row.summary_bytes, pool_bytes) {
			return 0, .String_Out_Of_Bounds
		}
	}

	// Zero the target region so padding bytes stay deterministic.
	for index in 0 ..< int(required) {
		out[index] = 0
	}

	header := Analysis_Snapshot_Header{
		magic               = SNAPSHOT_MAGIC,
		version             = SNAPSHOT_VERSION,
		total_bytes         = u32(required),
		document_generation = tables.document_generation,
	}

	cursor := u64(SNAPSHOT_HEADER_SIZE)
	if len(tables.diagnostics) > 0 {
		cursor = align_up_u64(cursor, SECTION_ALIGNMENT)
		header.diagnostics_offset = u32(cursor)
		header.diagnostics_count = u32(len(tables.diagnostics))
		for row in tables.diagnostics {
			at := int(cursor)
			byte_order.write_u32_little_endian(out, at + 0, row.start_offset)
			byte_order.write_u32_little_endian(out, at + 4, row.end_offset)
			byte_order.write_u32_little_endian(out, at + 8, row.line)
			byte_order.write_u32_little_endian(out, at + 12, row.column)
			byte_order.write_u32_little_endian(out, at + 16, row.severity_word)
			byte_order.write_u32_little_endian(out, at + 20, row.message_offset)
			byte_order.write_u32_little_endian(out, at + 24, row.message_bytes)
			byte_order.write_u32_little_endian(out, at + 28, 0)
			cursor += DIAGNOSTIC_ROW_SIZE
		}
	}
	if len(tables.tokens) > 0 {
		cursor = align_up_u64(cursor, SECTION_ALIGNMENT)
		header.tokens_offset = u32(cursor)
		header.tokens_count = u32(len(tables.tokens))
		for row in tables.tokens {
			at := int(cursor)
			byte_order.write_u32_little_endian(out, at + 0, row.start_offset)
			byte_order.write_u32_little_endian(out, at + 4, row.length)
			byte_order.write_u32_little_endian(out, at + 8, row.kind_word)
			byte_order.write_u32_little_endian(out, at + 12, 0)
			cursor += SEMANTIC_TOKEN_ROW_SIZE
		}
	}
	if len(tables.completions) > 0 {
		cursor = align_up_u64(cursor, SECTION_ALIGNMENT)
		header.completions_offset = u32(cursor)
		header.completions_count = u32(len(tables.completions))
		for row in tables.completions {
			at := int(cursor)
			byte_order.write_u32_little_endian(out, at + 0, row.kind_word)
			byte_order.write_u32_little_endian(out, at + 4, row.label_offset)
			byte_order.write_u32_little_endian(out, at + 8, row.label_bytes)
			byte_order.write_u32_little_endian(out, at + 12, row.detail_offset)
			byte_order.write_u32_little_endian(out, at + 16, row.detail_bytes)
			byte_order.write_u32_little_endian(out, at + 20, 0)
			cursor += COMPLETION_ROW_SIZE
		}
	}
	if len(tables.definitions) > 0 {
		cursor = align_up_u64(cursor, SECTION_ALIGNMENT)
		header.definitions_offset = u32(cursor)
		header.definitions_count = u32(len(tables.definitions))
		for row in tables.definitions {
			at := int(cursor)
			byte_order.write_u32_little_endian(out, at + 0, row.use_start)
			byte_order.write_u32_little_endian(out, at + 4, row.use_end)
			byte_order.write_u32_little_endian(out, at + 8, row.target_start)
			byte_order.write_u32_little_endian(out, at + 12, row.target_end)
			byte_order.write_u32_little_endian(out, at + 16, row.name_offset)
			byte_order.write_u32_little_endian(out, at + 20, row.name_bytes)
			cursor += DEFINITION_SPAN_SIZE
		}
	}
	if len(tables.hovers) > 0 {
		cursor = align_up_u64(cursor, SECTION_ALIGNMENT)
		header.hovers_offset = u32(cursor)
		header.hovers_count = u32(len(tables.hovers))
		for row in tables.hovers {
			at := int(cursor)
			byte_order.write_u32_little_endian(out, at + 0, row.start_offset)
			byte_order.write_u32_little_endian(out, at + 4, row.end_offset)
			byte_order.write_u32_little_endian(out, at + 8, row.signature_offset)
			byte_order.write_u32_little_endian(out, at + 12, row.signature_bytes)
			byte_order.write_u32_little_endian(out, at + 16, row.summary_offset)
			byte_order.write_u32_little_endian(out, at + 20, row.summary_bytes)
			cursor += HOVER_ENTRY_SIZE
		}
	}
	if len(tables.strings) > 0 {
		header.strings_offset = u32(cursor)
		header.strings_bytes = u32(len(tables.strings))
		copy(out[int(cursor):int(cursor) + len(tables.strings)], tables.strings)
		cursor += u64(len(tables.strings))
	}

	if write_err := snapshot_header_write(out, header); write_err != .None {
		return 0, write_err
	}
	return int(cursor), .None
}

@(private = "file")
section_span_check :: proc "contextless" (offset, count: u32, row_size: u64, aligned: bool, total_bytes: u64) -> (span: Section_Span, refusal: Analysis_Refusal) {
	if count == 0 {
		if offset != 0 {
			return {}, .Section_Out_Of_Bounds
		}
		return {}, .None
	}
	if offset < SNAPSHOT_HEADER_SIZE {
		return {}, .Section_Out_Of_Bounds
	}
	if aligned && (offset % SECTION_ALIGNMENT) != 0 {
		return {}, .Bad_Alignment
	}
	byte_len := u64(count) * row_size
	if byte_len > total_bytes || u64(offset) > total_bytes - byte_len {
		return {}, .Section_Out_Of_Bounds
	}
	return Section_Span{present = true, start = u64(offset), end = u64(offset) + byte_len}, .None
}

// snapshot_validate checks an untrusted MODLAEF1 byte slice completely before reading.
snapshot_validate :: proc "contextless" (bytes: []u8) -> (header: Analysis_Snapshot_Header, refusal: Analysis_Refusal) {
	header, refusal = snapshot_header_read(bytes)
	if refusal != .None {
		return {}, refusal
	}
	if header.magic != SNAPSHOT_MAGIC {
		return {}, .Bad_Magic
	}
	if header.version != SNAPSHOT_VERSION {
		return {}, .Unsupported_Version
	}
	if header.total_bytes < SNAPSHOT_HEADER_SIZE || u64(header.total_bytes) > u64(len(bytes)) {
		return {}, .Bad_Size
	}

	total := u64(header.total_bytes)
	spans: [6]Section_Span
	spans[0], refusal = section_span_check(header.diagnostics_offset, header.diagnostics_count, DIAGNOSTIC_ROW_SIZE, true, total)
	if refusal != .None {
		return {}, refusal
	}
	spans[1], refusal = section_span_check(header.tokens_offset, header.tokens_count, SEMANTIC_TOKEN_ROW_SIZE, true, total)
	if refusal != .None {
		return {}, refusal
	}
	spans[2], refusal = section_span_check(header.completions_offset, header.completions_count, COMPLETION_ROW_SIZE, true, total)
	if refusal != .None {
		return {}, refusal
	}
	spans[3], refusal = section_span_check(header.definitions_offset, header.definitions_count, DEFINITION_SPAN_SIZE, true, total)
	if refusal != .None {
		return {}, refusal
	}
	spans[4], refusal = section_span_check(header.hovers_offset, header.hovers_count, HOVER_ENTRY_SIZE, true, total)
	if refusal != .None {
		return {}, refusal
	}
	spans[5], refusal = section_span_check(header.strings_offset, header.strings_bytes, 1, false, total)
	if refusal != .None {
		return {}, refusal
	}

	for i in 0 ..< len(spans) {
		if !spans[i].present {
			continue
		}
		for j in i + 1 ..< len(spans) {
			if !spans[j].present {
				continue
			}
			if spans[i].start < spans[j].end && spans[j].start < spans[i].end {
				return {}, .Section_Overlap
			}
		}
	}

	pool_bytes := header.strings_bytes
	for index in u32(0) ..< header.diagnostics_count {
		row := snapshot_diagnostic_at(bytes, header, index)
		if row.start_offset > row.end_offset {
			return {}, .Span_Order_Invalid
		}
		if row.reserved != 0 {
			return {}, .Bad_Size
		}
		if _, ok := diagnostic_severity_of_word(u64(row.severity_word)); !ok {
			return {}, .Unknown_Enum_Word
		}
		if !string_span_valid(row.message_offset, row.message_bytes, pool_bytes) {
			return {}, .String_Out_Of_Bounds
		}
	}
	for index in u32(0) ..< header.tokens_count {
		row := snapshot_token_at(bytes, header, index)
		if row.flags != 0 {
			return {}, .Bad_Size
		}
		if _, ok := semantic_token_kind_of_word(u64(row.kind_word)); !ok {
			return {}, .Unknown_Enum_Word
		}
	}
	for index in u32(0) ..< header.completions_count {
		row := snapshot_completion_at(bytes, header, index)
		if row.reserved != 0 {
			return {}, .Bad_Size
		}
		if _, ok := completion_kind_of_word(u64(row.kind_word)); !ok {
			return {}, .Unknown_Enum_Word
		}
		if !string_span_valid(row.label_offset, row.label_bytes, pool_bytes) ||
			!string_span_valid(row.detail_offset, row.detail_bytes, pool_bytes) {
			return {}, .String_Out_Of_Bounds
		}
	}
	for index in u32(0) ..< header.definitions_count {
		row := snapshot_definition_at(bytes, header, index)
		if row.use_start > row.use_end || row.target_start > row.target_end {
			return {}, .Span_Order_Invalid
		}
		if !string_span_valid(row.name_offset, row.name_bytes, pool_bytes) {
			return {}, .String_Out_Of_Bounds
		}
	}
	for index in u32(0) ..< header.hovers_count {
		row := snapshot_hover_at(bytes, header, index)
		if row.start_offset > row.end_offset {
			return {}, .Span_Order_Invalid
		}
		if !string_span_valid(row.signature_offset, row.signature_bytes, pool_bytes) ||
			!string_span_valid(row.summary_offset, row.summary_bytes, pool_bytes) {
			return {}, .String_Out_Of_Bounds
		}
	}

	return header, .None
}

// ---- Zero-copy typed readers (caller passes a header verified by snapshot_validate).

snapshot_diagnostic_at :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, index: u32) -> Diagnostic_Row {
	at := int(header.diagnostics_offset) + int(index) * DIAGNOSTIC_ROW_SIZE
	return Diagnostic_Row{
		start_offset   = byte_order.read_u32_little_endian(bytes, at + 0),
		end_offset     = byte_order.read_u32_little_endian(bytes, at + 4),
		line           = byte_order.read_u32_little_endian(bytes, at + 8),
		column         = byte_order.read_u32_little_endian(bytes, at + 12),
		severity_word  = byte_order.read_u32_little_endian(bytes, at + 16),
		message_offset = byte_order.read_u32_little_endian(bytes, at + 20),
		message_bytes  = byte_order.read_u32_little_endian(bytes, at + 24),
		reserved       = byte_order.read_u32_little_endian(bytes, at + 28),
	}
}

snapshot_token_at :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, index: u32) -> Semantic_Token_Row {
	at := int(header.tokens_offset) + int(index) * SEMANTIC_TOKEN_ROW_SIZE
	return Semantic_Token_Row{
		start_offset = byte_order.read_u32_little_endian(bytes, at + 0),
		length       = byte_order.read_u32_little_endian(bytes, at + 4),
		kind_word    = byte_order.read_u32_little_endian(bytes, at + 8),
		flags        = byte_order.read_u32_little_endian(bytes, at + 12),
	}
}

snapshot_completion_at :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, index: u32) -> Completion_Row {
	at := int(header.completions_offset) + int(index) * COMPLETION_ROW_SIZE
	return Completion_Row{
		kind_word     = byte_order.read_u32_little_endian(bytes, at + 0),
		label_offset  = byte_order.read_u32_little_endian(bytes, at + 4),
		label_bytes   = byte_order.read_u32_little_endian(bytes, at + 8),
		detail_offset = byte_order.read_u32_little_endian(bytes, at + 12),
		detail_bytes  = byte_order.read_u32_little_endian(bytes, at + 16),
		reserved      = byte_order.read_u32_little_endian(bytes, at + 20),
	}
}

snapshot_definition_at :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, index: u32) -> Definition_Span {
	at := int(header.definitions_offset) + int(index) * DEFINITION_SPAN_SIZE
	return Definition_Span{
		use_start    = byte_order.read_u32_little_endian(bytes, at + 0),
		use_end      = byte_order.read_u32_little_endian(bytes, at + 4),
		target_start = byte_order.read_u32_little_endian(bytes, at + 8),
		target_end   = byte_order.read_u32_little_endian(bytes, at + 12),
		name_offset  = byte_order.read_u32_little_endian(bytes, at + 16),
		name_bytes   = byte_order.read_u32_little_endian(bytes, at + 20),
	}
}

snapshot_hover_at :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, index: u32) -> Hover_Entry {
	at := int(header.hovers_offset) + int(index) * HOVER_ENTRY_SIZE
	return Hover_Entry{
		start_offset     = byte_order.read_u32_little_endian(bytes, at + 0),
		end_offset       = byte_order.read_u32_little_endian(bytes, at + 4),
		signature_offset = byte_order.read_u32_little_endian(bytes, at + 8),
		signature_bytes  = byte_order.read_u32_little_endian(bytes, at + 12),
		summary_offset   = byte_order.read_u32_little_endian(bytes, at + 16),
		summary_bytes    = byte_order.read_u32_little_endian(bytes, at + 20),
	}
}

snapshot_string_at :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, offset, count: u32) -> string {
	if count == 0 {
		return ""
	}
	start := int(header.strings_offset) + int(offset)
	return string(bytes[start : start + int(count)])
}

snapshot_definition_for_offset :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, cursor: u32) -> (span: Definition_Span, found: bool) {
	for index in u32(0) ..< header.definitions_count {
		candidate := snapshot_definition_at(bytes, header, index)
		if cursor >= candidate.use_start && cursor <= candidate.use_end {
			return candidate, true
		}
	}
	return {}, false
}

snapshot_hover_for_offset :: proc "contextless" (bytes: []u8, header: Analysis_Snapshot_Header, cursor: u32) -> (entry: Hover_Entry, found: bool) {
	for index in u32(0) ..< header.hovers_count {
		candidate := snapshot_hover_at(bytes, header, index)
		if cursor >= candidate.start_offset && cursor <= candidate.end_offset {
			return candidate, true
		}
	}
	return {}, false
}
