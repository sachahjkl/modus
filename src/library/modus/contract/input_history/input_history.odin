// The input history of a recorded process: fixed-layout records, borders that
// refuse unknown words or damaged payloads, page-delta encoding and decoding,
// and the pure divergence comparator used during replay
// (src/md/features/record_and_replay.md).
//
// This package is a contract between the kernel and the recorder or replayer:
// it holds no kernel operation call and imports no support package.
package input_history

import "modus:contract/enum_word"
import op "modus:contract/operation"

// The magic number at the start of every valid input history ("MODUSHIS").
HISTORY_MAGIC :: u64(0x4D4F_4455_5348_4953)
// The format version of the input history.
HISTORY_VERSION :: u32(1)
// The page size in bytes for page deltas.
HISTORY_PAGE_SIZE :: u64(op.PAGE_SIZE)
// Alignment stride in bytes for records in the history stream.
RECORD_ALIGNMENT :: u64(8)
// Largest payload of a single record in bytes (covers reports and page deltas).
MAX_RECORD_PAYLOAD_BYTES :: u32(65536)
// Largest byte size of an encoded page delta: header + one full-page range + 4096 bytes.
PAGE_DELTA_MAX_BYTES :: size_of(Page_Delta_Header) + size_of(Page_Delta_Range) + int(HISTORY_PAGE_SIZE)

// What a record in an input history carries. Zero names no record.
History_Record_Kind :: enum u32 {
	None                     = 0,
	Kernel_Completion        = 1,
	Cycle_Counter            = 2,
	Processor_Identification = 3,
	Page_Delta               = 4,
	History_End              = 5,
	Shared_Mapping           = 6,
}

// Why an input history ended. Zero means the history has not ended.
History_End_Reason :: enum u32 {
	None                = 0,
	Normal_Stop         = 1,
	Recorder_Stopped    = 2,
	Stint_Bound_Reached = 3,
	Revocation          = 4,
	Buffer_Full         = 5,
	Divergence          = 6,
}

// Whether a process or thread runs normally, is recorded, or is replayed.
Record_Mode :: enum u8 {
	None      = 0,
	Recording = 1,
	Replaying = 2,
}

// What disagreed between the replayed process and the recorded input history.
Divergence_Kind :: enum u32 {
	None                   = 0,
	Unexpected_Operation   = 1,
	Unexpected_Instruction = 2,
	Missing_Record         = 3,
	Kind_Mismatch          = 4,
	Unexpected_Arguments   = 5,
	Unexpected_End         = 6, // The replayed process stopped where the history does not end, or with another end.
}

// What the recorded process could do with the pages of a shared mapping.
// Zero names no access: a record of a mapping always has one.
Shared_Mapping_Access :: enum u32 {
	None       = 0,
	Read       = 1, // A page that another process writes, mapped without Write: a point copy in the record.
	Read_Write = 2, // A page that the recorded process and a shared writer both write.
}

// history_record_kind_of_word is the one border for History_Record_Kind.
history_record_kind_of_word :: proc "contextless" (word: u64) -> (kind: History_Record_Kind, ok: bool) {
	return enum_word.member_of_word(History_Record_Kind, word)
}

// history_end_reason_of_word is the one border for History_End_Reason.
history_end_reason_of_word :: proc "contextless" (word: u64) -> (reason: History_End_Reason, ok: bool) {
	return enum_word.member_of_word(History_End_Reason, word)
}

// record_mode_of_word is the one border for Record_Mode.
record_mode_of_word :: proc "contextless" (word: u64) -> (mode: Record_Mode, ok: bool) {
	return enum_word.member_of_word(Record_Mode, word)
}

// shared_mapping_access_of_word is the one border for Shared_Mapping_Access.
shared_mapping_access_of_word :: proc "contextless" (word: u64) -> (access: Shared_Mapping_Access, ok: bool) {
	return enum_word.member_of_word(Shared_Mapping_Access, word)
}

// divergence_kind_of_word is the one border for Divergence_Kind.
divergence_kind_of_word :: proc "contextless" (word: u64) -> (kind: Divergence_Kind, ok: bool) {
	return enum_word.member_of_word(Divergence_Kind, word)
}

// The header at byte 0 of an input history memory object. Fixed 256 bytes
// (four cache lines) with no implicit padding.
History_Header :: struct {
	magic:               u64, // HISTORY_MAGIC.
	version:             u32, // HISTORY_VERSION.
	flags:               u32, // 0; non-zero refused at the border.
	capacity_bytes:      u64, // Bytes available for records immediately after this header.
	written_bytes:       u64, // Bytes of records written into the stream.
	read_bytes:          u64, // Bytes of records consumed by the reader.
	point_count:         u64, // Count of input points recorded.
	cycle_frequency:     u64, // Cycle counter frequency in cycles per second.
	cycle_start:         u64, // Cycle counter value at boot time 0.
	xcr0_components:     u64, // Extended state components enabled on the recording machine.
	module_hash:         [32]u8, // BLAKE3 hash of the main module of the recorded process.
	end_reason:          u32, // History_End_Reason word when ended; 0 while active.
	divergence_kind:     u32, // Divergence_Kind word when ended by Divergence; 0 otherwise.
	divergence_point:    u64, // Input point number where divergence happened, or 0.
	divergence_expected: u64, // Expected value at divergence, or 0.
	divergence_actual:   u64, // Actual value at divergence, or 0.
	reserved:            [120]u8, // Zero; non-zero refused at the border.
}
#assert(size_of(History_Header) == 256)

// The header of each record in the history stream. Every record starts on an
// 8-byte boundary after History_Header.
History_Record_Header :: struct {
	kind:                u32, // History_Record_Kind word (never None).
	payload_bytes:       u32, // Exact byte length of payload immediately following this header.
	point_number:        u64, // Monotonic input point number.
	instruction_address: u64, // Instruction pointer at this input point.
	stack_pointer:       u64, // Stack pointer at this input point.
}
#assert(size_of(History_Record_Header) == 32)

// Payload of History_Record_Kind.Kernel_Completion. Optional user-memory bytes
// written by the kernel follow immediately when copied_bytes_count > 0.
Kernel_Completion_Payload :: struct {
	command_kind:             u32, // Command record kind (Operation plus optional error-details flag).
	command_tag:              u32, // Caller-supplied tag of the command record.
	command_values:           [7]u64, // Command arguments for replay comparison.
	completion_status:        u32, // op.Status word of the completion.
	copied_bytes_count:       u32, // Bytes written to caller memory following this struct.
	completion_values:        [7]u64, // Completion results or error record words.
	return_time_milliseconds: u64, // Return value placed in rax on kernel entry return.
	copied_user_address:      u64, // Destination virtual address when copied_bytes_count > 0; else 0.
}
#assert(size_of(Kernel_Completion_Payload) == 144)

// Payload of History_Record_Kind.Cycle_Counter for a trapped rdtsc or rdtscp.
Cycle_Counter_Payload :: struct {
	cycles:              u64, // Full 64-bit cycle counter (edx:eax).
	processor_auxiliary: u32, // Fixed TSC_AUX value returned in ecx for rdtscp; 0 for rdtsc.
	is_rdtscp:           u32, // 0 for rdtsc, 1 for rdtscp; any other value refused.
}
#assert(size_of(Cycle_Counter_Payload) == 16)

// Payload of History_Record_Kind.Processor_Identification for a trapped cpuid.
Cpuid_Payload :: struct {
	leaf:    u32, // Input eax.
	subleaf: u32, // Input ecx.
	eax:     u32, // Filtered output eax.
	ebx:     u32, // Filtered output ebx.
	ecx:     u32, // Filtered output ecx.
	edx:     u32, // Filtered output edx.
}
#assert(size_of(Cpuid_Payload) == 24)

// Header of History_Record_Kind.Page_Delta. Immediately followed by
// range_count entries, each consisting of a Page_Delta_Range and its raw bytes.
Page_Delta_Header :: struct {
	virtual_address: u64, // Page-aligned user virtual address below USER_END.
	range_count:     u32, // Count of non-overlapping byte ranges (at least 1).
	reserved:        u32, // 0; non-zero refused at the border.
}
#assert(size_of(Page_Delta_Header) == 16)

// One changed byte range within a 4096-byte page.
Page_Delta_Range :: struct {
	offset: u16, // Starting byte offset within the page (0 ..< 4096).
	length: u16, // Count of changed bytes (1 ..= 4096 - offset).
}
#assert(size_of(Page_Delta_Range) == 4)

// Payload of History_Record_Kind.History_End.
History_End_Payload :: struct {
	reason:          u32, // History_End_Reason word (never None).
	divergence_kind: u32, // Divergence_Kind word (non-None if and only if reason == Divergence).
	expected_value:  u64, // Expected value when reason == Divergence; else 0.
	actual_value:    u64, // Actual value when reason == Divergence; else 0.
}
#assert(size_of(History_End_Payload) == 24)

// The most pages of one shared mapping: the kernel keeps one baseline frame
// for each shared page and one frame for each point copy, so a mapping with
// more pages cannot be recorded.
SHARED_MAPPING_PAGE_LIMIT :: u64(64)

// Payload of History_Record_Kind.Shared_Mapping. The head of a history holds
// one for each mapping of the recorded process whose pages another process
// writes, before the Page_Delta records of its first bytes. A mapping that
// the recorded process makes after its start, of memory that another
// process holds, has one right after the Kernel_Completion of its
// Memory_Map, then the Page_Delta records of its first bytes. A replay holds
// no peer, so the kernel maps private pages of the replayer at that place,
// before the first instruction or at that Memory_Map, and each Page_Delta
// of the history writes them.
Shared_Mapping_Payload :: struct {
	virtual_address: u64, // Page-aligned user virtual address of the first page.
	page_count:      u64, // Pages of the mapping: 1 ..= SHARED_MAPPING_PAGE_LIMIT.
	access:          u32, // Shared_Mapping_Access word (never None).
	reserved:        u32, // 0; non-zero refused at the border.
}
#assert(size_of(Shared_Mapping_Payload) == 24)

// shared_mapping_validate is the border of a Shared_Mapping payload: its
// exact size, a page-aligned range below USER_END, a page count in its
// bound, a known access that is not None, and a zero reserved word.
shared_mapping_validate :: proc "contextless" (payload: []u8) -> (entry: Shared_Mapping_Payload, access: Shared_Mapping_Access, ok: bool) {
	if len(payload) != size_of(Shared_Mapping_Payload) {
		return {}, .None, false
	}
	entry = copy_from_bytes(payload, Shared_Mapping_Payload)
	access, ok = shared_mapping_access_of_word(u64(entry.access))
	if !ok || access == .None || entry.reserved != 0 {
		return {}, .None, false
	}
	if entry.page_count == 0 || entry.page_count > SHARED_MAPPING_PAGE_LIMIT {
		return {}, .None, false
	}
	if entry.virtual_address == 0 || entry.virtual_address % HISTORY_PAGE_SIZE != 0 || entry.virtual_address >= op.USER_END {
		return {}, .None, false
	}
	if entry.page_count * HISTORY_PAGE_SIZE > op.USER_END - entry.virtual_address {
		return {}, .None, false
	}
	return entry, access, true
}

// align_up_record rounds a byte count up to RECORD_ALIGNMENT.
align_up_record :: #force_inline proc "contextless" (bytes: u64) -> u64 {
	return (bytes + RECORD_ALIGNMENT - 1) &~ (RECORD_ALIGNMENT - 1)
}

// copy_into_bytes copies a fixed-layout value into a byte slice.
@(private = "file")
copy_into_bytes :: #force_inline proc "contextless" (destination: []u8, value: ^$T) {
	source := ([^]u8)(value)[:size_of(T)]
	copy(destination[:size_of(T)], source)
}

// copy_from_bytes copies a fixed-layout value out of a byte slice.
@(private = "file")
copy_from_bytes :: #force_inline proc "contextless" (source: []u8, $T: typeid) -> (value: T) {
	destination := ([^]u8)(&value)[:size_of(T)]
	copy(destination, source[:size_of(T)])
	return value
}

// page_delta_encode compares two 4096-byte pages and encodes every changed
// contiguous byte range into destination. When pages are equal, changed is
// false and written is 0. If the run-encoded delta would exceed a single full
// page range, a single full-page range is emitted so a delta never exceeds
// PAGE_DELTA_MAX_BYTES. ok is false if virtual_address is invalid or
// destination is too small; destination is unchanged in the invalid-address case.
page_delta_encode :: proc "contextless" (virtual_address: u64, before: ^[HISTORY_PAGE_SIZE]u8, after: ^[HISTORY_PAGE_SIZE]u8, destination: []u8) -> (written: int, changed: bool, ok: bool) {
	if virtual_address % HISTORY_PAGE_SIZE != 0 || virtual_address >= op.USER_END {
		return 0, false, false
	}
	// First pass: measure exact encoded size and range count without writing.
	range_count: u32
	encoded_bytes := size_of(Page_Delta_Header)
	index := 0
	for index < int(HISTORY_PAGE_SIZE) {
		if before[index] == after[index] {
			index += 1
			continue
		}
		start := index
		for index < int(HISTORY_PAGE_SIZE) && before[index] != after[index] {
			index += 1
		}
		length := index - start
		range_count += 1
		encoded_bytes += size_of(Page_Delta_Range) + length
	}
	if range_count == 0 {
		return 0, false, true
	}
	// Cap delta size at one full-page range so alternating bytes never expand.
	emit_full_page := encoded_bytes > PAGE_DELTA_MAX_BYTES
	needed := emit_full_page ? PAGE_DELTA_MAX_BYTES : encoded_bytes
	if len(destination) < needed {
		return 0, true, false
	}
	header := Page_Delta_Header {
		virtual_address = virtual_address,
		range_count     = emit_full_page ? 1 : range_count,
		reserved        = 0,
	}
	copy_into_bytes(destination, &header)
	cursor := size_of(Page_Delta_Header)
	if emit_full_page {
		full_range := Page_Delta_Range{offset = 0, length = u16(HISTORY_PAGE_SIZE)}
		copy_into_bytes(destination[cursor:], &full_range)
		cursor += size_of(Page_Delta_Range)
		copy(destination[cursor:cursor + int(HISTORY_PAGE_SIZE)], after[:])
		cursor += int(HISTORY_PAGE_SIZE)
		return cursor, true, true
	}
	index = 0
	actual_ranges: u32
	for index < int(HISTORY_PAGE_SIZE) {
		if before[index] == after[index] {
			index += 1
			continue
		}
		start := index
		for index < int(HISTORY_PAGE_SIZE) && before[index] != after[index] {
			index += 1
		}
		length := index - start
		if cursor + size_of(Page_Delta_Range) + length > len(destination) {
			return 0, true, false
		}
		entry := Page_Delta_Range{offset = u16(start), length = u16(length)}
		copy_into_bytes(destination[cursor:], &entry)
		cursor += size_of(Page_Delta_Range)
		copy(destination[cursor:cursor + length], after[start:index])
		cursor += length
		actual_ranges += 1
	}
	if actual_ranges != range_count {
		header.range_count = actual_ranges
		copy_into_bytes(destination, &header)
		if actual_ranges == 0 {
			return 0, false, true
		}
	}
	return cursor, true, true
}

// page_delta_validate checks that a Page_Delta payload is well-formed: valid
// page-aligned user address, zero reserved field, at least one range, every
// range strictly non-zero and in-bounds within 4096 bytes, strictly ordered
// without overlap, and exact byte length with no trailing garbage.
page_delta_validate :: proc "contextless" (payload: []u8) -> (header: Page_Delta_Header, ok: bool) {
	if len(payload) < size_of(Page_Delta_Header) {
		return {}, false
	}
	header = copy_from_bytes(payload, Page_Delta_Header)
	if header.reserved != 0 || header.virtual_address % HISTORY_PAGE_SIZE != 0 || header.virtual_address >= op.USER_END {
		return {}, false
	}
	if header.range_count == 0 || u64(header.range_count) > HISTORY_PAGE_SIZE {
		return {}, false
	}
	cursor := size_of(Page_Delta_Header)
	previous_end := u32(0)
	for range_index in 0 ..< header.range_count {
		if len(payload) - cursor < size_of(Page_Delta_Range) {
			return {}, false
		}
		entry := copy_from_bytes(payload[cursor:], Page_Delta_Range)
		cursor += size_of(Page_Delta_Range)
		offset := u32(entry.offset)
		length := u32(entry.length)
		if length == 0 || offset >= u32(HISTORY_PAGE_SIZE) || length > u32(HISTORY_PAGE_SIZE) - offset {
			return {}, false
		}
		if range_index > 0 && offset < previous_end {
			return {}, false
		}
		if len(payload) - cursor < int(length) {
			return {}, false
		}
		cursor += int(length)
		previous_end = offset + length
	}
	if cursor != len(payload) {
		return {}, false
	}
	return header, true
}

// page_delta_apply validates a Page_Delta payload completely before copying
// its changed byte ranges into page. On refusal, page is untouched.
page_delta_apply :: proc "contextless" (payload: []u8, page: ^[HISTORY_PAGE_SIZE]u8) -> bool {
	header, valid := page_delta_validate(payload)
	if !valid {
		return false
	}
	cursor := size_of(Page_Delta_Header)
	for _ in 0 ..< header.range_count {
		entry := copy_from_bytes(payload[cursor:], Page_Delta_Range)
		cursor += size_of(Page_Delta_Range)
		offset := int(entry.offset)
		length := int(entry.length)
		copy(page[offset:offset + length], payload[cursor:cursor + length])
		cursor += length
	}
	return true
}

// payload_valid checks the internal border of a record payload for its kind.
payload_valid :: proc "contextless" (kind: History_Record_Kind, payload: []u8) -> bool {
	switch kind {
	case .None:
		return false
	case .Kernel_Completion:
		if len(payload) < size_of(Kernel_Completion_Payload) {
			return false
		}
		entry := copy_from_bytes(payload, Kernel_Completion_Payload)
		if _, status_ok := enum_word.member_of_word(op.Status, u64(entry.completion_status)); !status_ok {
			return false
		}
		expected_bytes := u64(size_of(Kernel_Completion_Payload)) + u64(entry.copied_bytes_count)
		if u64(len(payload)) != expected_bytes {
			return false
		}
		if entry.copied_bytes_count == 0 && entry.copied_user_address != 0 {
			return false
		}
		if entry.copied_bytes_count > 0 && (entry.copied_user_address == 0 || entry.copied_user_address >= op.USER_END || u64(entry.copied_bytes_count) > op.USER_END - entry.copied_user_address) {
			return false
		}
		return true
	case .Cycle_Counter:
		if len(payload) != size_of(Cycle_Counter_Payload) {
			return false
		}
		entry := copy_from_bytes(payload, Cycle_Counter_Payload)
		if entry.is_rdtscp > 1 {
			return false
		}
		if entry.is_rdtscp == 0 && entry.processor_auxiliary != 0 {
			return false
		}
		return true
	case .Processor_Identification:
		return len(payload) == size_of(Cpuid_Payload)
	case .Page_Delta:
		_, ok := page_delta_validate(payload)
		return ok
	case .Shared_Mapping:
		_, _, ok := shared_mapping_validate(payload)
		return ok
	case .History_End:
		if len(payload) != size_of(History_End_Payload) {
			return false
		}
		entry := copy_from_bytes(payload, History_End_Payload)
		reason, reason_ok := history_end_reason_of_word(u64(entry.reason))
		if !reason_ok || reason == .None {
			return false
		}
		div_kind, div_ok := divergence_kind_of_word(u64(entry.divergence_kind))
		if !div_ok {
			return false
		}
		if (reason == .Divergence) != (div_kind != .None) {
			return false
		}
		if reason != .Divergence && (entry.expected_value != 0 || entry.actual_value != 0) {
			return false
		}
		return true
	}
	return false
}

// A writer that appends records into a caller-supplied history buffer.
History_Writer :: struct {
	buffer:       []u8,
	capacity:     u64,
	write_offset: u64,
	point_count:  u64,
	ended:        bool,
}

// Minimum buffer size needed for a valid history: header plus room for at least
// one History_End record.
MIN_HISTORY_BUFFER_BYTES :: size_of(History_Header) + size_of(History_Record_Header) + size_of(History_End_Payload)

// history_writer_init initializes a fresh input history buffer. Returns false
// when the buffer is smaller than MIN_HISTORY_BUFFER_BYTES.
history_writer_init :: proc "contextless" (buffer: []u8, module_hash: [32]u8, cycle_frequency, cycle_start, xcr0_components: u64) -> (writer: History_Writer, ok: bool) {
	if len(buffer) < MIN_HISTORY_BUFFER_BYTES {
		return {}, false
	}
	capacity := u64(len(buffer) - size_of(History_Header))
	header := History_Header {
		magic           = HISTORY_MAGIC,
		version         = HISTORY_VERSION,
		capacity_bytes  = capacity,
		cycle_frequency = cycle_frequency,
		cycle_start     = cycle_start,
		xcr0_components = xcr0_components,
		module_hash     = module_hash,
	}
	copy_into_bytes(buffer, &header)
	return History_Writer{buffer = buffer, capacity = capacity}, true
}

// history_writer_append validates and appends one record to the history buffer.
// On refusal (invalid kind, already ended, invalid payload, or full buffer),
// nothing in the buffer changes.
history_writer_append :: proc "contextless" (history_writer: ^History_Writer, kind: History_Record_Kind, instruction_address, stack_pointer: u64, payload: []u8) -> bool {
	if history_writer == nil || history_writer.ended || kind == .None {
		return false
	}
	if u64(len(payload)) > u64(MAX_RECORD_PAYLOAD_BYTES) || !payload_valid(kind, payload) {
		return false
	}
	record_total := u64(size_of(History_Record_Header)) + align_up_record(u64(len(payload)))
	if record_total > history_writer.capacity - history_writer.write_offset {
		return false
	}
	next_point := history_writer.point_count + 1
	record_header := History_Record_Header {
		kind                = u32(kind),
		payload_bytes       = u32(len(payload)),
		point_number        = next_point,
		instruction_address = instruction_address,
		stack_pointer       = stack_pointer,
	}
	base := size_of(History_Header) + int(history_writer.write_offset)
	copy_into_bytes(history_writer.buffer[base:], &record_header)
	payload_start := base + size_of(History_Record_Header)
	copy(history_writer.buffer[payload_start:payload_start + len(payload)], payload)
	// Zero padding bytes to the 8-byte boundary so readers can enforce zero padding.
	padded_payload := int(align_up_record(u64(len(payload))))
	for pad := len(payload); pad < padded_payload; pad += 1 {
		history_writer.buffer[payload_start + pad] = 0
	}
	history_writer.write_offset += record_total
	history_writer.point_count = next_point
	// Update header counts in place.
	header := copy_from_bytes(history_writer.buffer, History_Header)
	header.written_bytes = history_writer.write_offset
	header.point_count = history_writer.point_count
	if kind == .History_End {
		end_payload := copy_from_bytes(payload, History_End_Payload)
		header.end_reason = end_payload.reason
		header.divergence_kind = end_payload.divergence_kind
		if end_payload.reason == u32(History_End_Reason.Divergence) {
			header.divergence_point = next_point
			header.divergence_expected = end_payload.expected_value
			header.divergence_actual = end_payload.actual_value
		}
		history_writer.ended = true
	}
	copy_into_bytes(history_writer.buffer, &header)
	return true
}

// history_writer_append_kernel_completion appends a Kernel_Completion record
// with optional copied user bytes without needing a separate scratch buffer.
history_writer_append_kernel_completion :: proc "contextless" (history_writer: ^History_Writer, instruction_address, stack_pointer: u64, entry: Kernel_Completion_Payload, copied_bytes: []u8) -> bool {
	if history_writer == nil || history_writer.ended {
		return false
	}
	if u64(entry.copied_bytes_count) != u64(len(copied_bytes)) {
		return false
	}
	if _, status_ok := enum_word.member_of_word(op.Status, u64(entry.completion_status)); !status_ok {
		return false
	}
	if entry.copied_bytes_count == 0 && entry.copied_user_address != 0 {
		return false
	}
	if entry.copied_bytes_count > 0 && (entry.copied_user_address == 0 || entry.copied_user_address >= op.USER_END || u64(entry.copied_bytes_count) > op.USER_END - entry.copied_user_address) {
		return false
	}
	payload_bytes := u64(size_of(Kernel_Completion_Payload)) + u64(len(copied_bytes))
	if payload_bytes > u64(MAX_RECORD_PAYLOAD_BYTES) {
		return false
	}
	record_total := u64(size_of(History_Record_Header)) + align_up_record(payload_bytes)
	if record_total > history_writer.capacity - history_writer.write_offset {
		return false
	}
	next_point := history_writer.point_count + 1
	record_header := History_Record_Header {
		kind                = u32(History_Record_Kind.Kernel_Completion),
		payload_bytes       = u32(payload_bytes),
		point_number        = next_point,
		instruction_address = instruction_address,
		stack_pointer       = stack_pointer,
	}
	base := size_of(History_Header) + int(history_writer.write_offset)
	copy_into_bytes(history_writer.buffer[base:], &record_header)
	payload_start := base + size_of(History_Record_Header)
	local_entry := entry
	copy_into_bytes(history_writer.buffer[payload_start:], &local_entry)
	if len(copied_bytes) > 0 {
		copy(history_writer.buffer[payload_start + size_of(Kernel_Completion_Payload):payload_start + int(payload_bytes)], copied_bytes)
	}
	padded_payload := int(align_up_record(payload_bytes))
	for pad := int(payload_bytes); pad < padded_payload; pad += 1 {
		history_writer.buffer[payload_start + pad] = 0
	}
	history_writer.write_offset += record_total
	history_writer.point_count = next_point
	header := copy_from_bytes(history_writer.buffer, History_Header)
	header.written_bytes = history_writer.write_offset
	header.point_count = history_writer.point_count
	copy_into_bytes(history_writer.buffer, &header)
	return true
}

// history_writer_append_cycle_counter appends a Cycle_Counter record.
history_writer_append_cycle_counter :: proc "contextless" (writer: ^History_Writer, instruction_address, stack_pointer: u64, payload: Cycle_Counter_Payload) -> bool {
	local := payload
	return history_writer_append(writer, .Cycle_Counter, instruction_address, stack_pointer, ([^]u8)(&local)[:size_of(local)])
}

// history_writer_append_cpuid appends a Processor_Identification record.
history_writer_append_cpuid :: proc "contextless" (writer: ^History_Writer, instruction_address, stack_pointer: u64, payload: Cpuid_Payload) -> bool {
	local := payload
	return history_writer_append(writer, .Processor_Identification, instruction_address, stack_pointer, ([^]u8)(&local)[:size_of(local)])
}

// history_writer_append_end appends a History_End record and seals the writer.
history_writer_append_end :: proc "contextless" (writer: ^History_Writer, instruction_address, stack_pointer: u64, reason: History_End_Reason, divergence_kind: Divergence_Kind = .None, expected_value: u64 = 0, actual_value: u64 = 0) -> bool {
	payload := History_End_Payload {
		reason          = u32(reason),
		divergence_kind = u32(divergence_kind),
		expected_value  = expected_value,
		actual_value    = actual_value,
	}
	return history_writer_append(writer, .History_End, instruction_address, stack_pointer, ([^]u8)(&payload)[:size_of(payload)])
}

// history_header_record_end updates the end/divergence summary in the header
// directly (used when the buffer has no room for a trailing record or when
// replay records a divergence in its read-write history buffer).
history_header_record_end :: proc "contextless" (buffer: []u8, reason: History_End_Reason, divergence_kind: Divergence_Kind, point, expected_value, actual_value: u64) -> bool {
	if len(buffer) < size_of(History_Header) || reason == .None {
		return false
	}
	if (reason == .Divergence) != (divergence_kind != .None) {
		return false
	}
	header := copy_from_bytes(buffer, History_Header)
	if header.magic != HISTORY_MAGIC || header.version != HISTORY_VERSION {
		return false
	}
	header.end_reason = u32(reason)
	header.divergence_kind = u32(divergence_kind)
	if reason == .Divergence {
		header.divergence_point = point
		header.divergence_expected = expected_value
		header.divergence_actual = actual_value
	}
	copy_into_bytes(buffer, &header)
	return true
}

// A strict sequential reader over a validated input history buffer.
History_Reader :: struct {
	buffer:      []u8,
	header:      History_Header,
	read_offset: u64,
	// The input point of the last record that the reader passed; 0 before
	// the first. A record whose point does not grow past it is refused: a
	// reader that took it could apply an input twice or out of order.
	last_point:  u64,
}

// history_reader_next_point gives the input point that the next record must
// have at least: the point of a divergence found where the next record is
// damaged or missing.
history_reader_next_point :: proc "contextless" (reader: ^History_Reader) -> u64 {
	return reader.last_point + 1
}

// history_reader_advance passes the record that a peek gave: its stride,
// and its input point.
history_reader_advance :: proc "contextless" (reader: ^History_Reader, record_header: History_Record_Header, stride: u64) {
	reader.read_offset += stride
	reader.last_point = record_header.point_number
}

// history_reader_open validates the History_Header at the border before
// returning a reader. Any corrupt magic, version, flags, bounds, unknown enum
// word, or non-zero reserved byte is refused.
history_reader_open :: proc "contextless" (buffer: []u8) -> (reader: History_Reader, ok: bool) {
	if len(buffer) < size_of(History_Header) {
		return {}, false
	}
	header := copy_from_bytes(buffer, History_Header)
	if header.magic != HISTORY_MAGIC || header.version != HISTORY_VERSION || header.flags != 0 {
		return {}, false
	}
	available := u64(len(buffer) - size_of(History_Header))
	if header.capacity_bytes > available || header.written_bytes > header.capacity_bytes || header.read_bytes > header.written_bytes {
		return {}, false
	}
	end_reason, reason_ok := history_end_reason_of_word(u64(header.end_reason))
	if !reason_ok {
		return {}, false
	}
	div_kind, div_ok := divergence_kind_of_word(u64(header.divergence_kind))
	if !div_ok {
		return {}, false
	}
	if (end_reason == .Divergence) != (div_kind != .None) {
		return {}, false
	}
	for reserved_byte in header.reserved {
		if reserved_byte != 0 {
			return {}, false
		}
	}
	return History_Reader{buffer = buffer, header = header, read_offset = 0}, true
}

// history_reader_peek_into copies the next record header and aligned payload
// ONCE out of reader.buffer into caller-supplied private scratch memory, then
// validates padding and payload strictly on that private copy. This eliminates
// double-fetch TOCTOU when reader.buffer is shared with a user process.
history_reader_peek_into :: proc "contextless" (reader: ^History_Reader, scratch: []u8) -> (record_header: History_Record_Header, kind: History_Record_Kind, payload: []u8, stride: u64, has_more: bool, ok: bool) {
	if reader == nil {
		return {}, .None, nil, 0, false, false
	}
	if reader.read_offset == reader.header.written_bytes {
		return {}, .None, nil, 0, false, true
	}
	remaining := reader.header.written_bytes - reader.read_offset
	if remaining < size_of(History_Record_Header) {
		return {}, .None, nil, 0, false, false
	}
	base := size_of(History_Header) + int(reader.read_offset)
	record_header = copy_from_bytes(reader.buffer[base:], History_Record_Header)
	parsed_kind, kind_ok := history_record_kind_of_word(u64(record_header.kind))
	if !kind_ok || parsed_kind == .None {
		return {}, .None, nil, 0, false, false
	}
	// The largest point is refused too: the point after it, which a reader
	// names at a damaged record, would wrap to 0.
	if record_header.point_number <= reader.last_point || record_header.point_number == max(u64) || record_header.payload_bytes > MAX_RECORD_PAYLOAD_BYTES {
		return {}, .None, nil, 0, false, false
	}
	padded_payload := align_up_record(u64(record_header.payload_bytes))
	total := u64(size_of(History_Record_Header)) + padded_payload
	if total > remaining || padded_payload > u64(len(scratch)) {
		return {}, .None, nil, 0, false, false
	}
	payload_start := base + size_of(History_Record_Header)
	copy(scratch[:int(padded_payload)], reader.buffer[payload_start:payload_start + int(padded_payload)])
	for pad := int(record_header.payload_bytes); pad < int(padded_payload); pad += 1 {
		if scratch[pad] != 0 {
			return {}, .None, nil, 0, false, false
		}
	}
	payload = scratch[:int(record_header.payload_bytes)]
	if !payload_valid(parsed_kind, payload) {
		return {}, .None, nil, 0, false, false
	}
	return record_header, parsed_kind, payload, total, true, true
}

// history_reader_next_into reads and validates the next record into private
// scratch memory, advancing read_offset only when completely valid.
history_reader_next_into :: proc "contextless" (reader: ^History_Reader, scratch: []u8) -> (record_header: History_Record_Header, kind: History_Record_Kind, payload: []u8, has_more: bool, ok: bool) {
	stride: u64
	record_header, kind, payload, stride, has_more, ok = history_reader_peek_into(reader, scratch)
	if ok && has_more {
		history_reader_advance(reader, record_header, stride)
	}
	return record_header, kind, payload, has_more, ok
}

// history_reader_peek inspects the next record without advancing read_offset.
// Returns has_more = false, ok = true at clean end of stream.
// Returns has_more = false, ok = false on any truncation, unknown kind, bad
// padding, or invalid payload.
history_reader_peek :: proc "contextless" (reader: ^History_Reader) -> (record_header: History_Record_Header, kind: History_Record_Kind, payload: []u8, stride: u64, has_more: bool, ok: bool) {
	if reader == nil {
		return {}, .None, nil, 0, false, false
	}
	if reader.read_offset == reader.header.written_bytes {
		return {}, .None, nil, 0, false, true
	}
	remaining := reader.header.written_bytes - reader.read_offset
	if remaining < size_of(History_Record_Header) {
		return {}, .None, nil, 0, false, false
	}
	base := size_of(History_Header) + int(reader.read_offset)
	record_header = copy_from_bytes(reader.buffer[base:], History_Record_Header)
	parsed_kind, kind_ok := history_record_kind_of_word(u64(record_header.kind))
	if !kind_ok || parsed_kind == .None {
		return {}, .None, nil, 0, false, false
	}
	// The largest point is refused too: the point after it, which a reader
	// names at a damaged record, would wrap to 0.
	if record_header.point_number <= reader.last_point || record_header.point_number == max(u64) || record_header.payload_bytes > MAX_RECORD_PAYLOAD_BYTES {
		return {}, .None, nil, 0, false, false
	}
	padded_payload := align_up_record(u64(record_header.payload_bytes))
	total := u64(size_of(History_Record_Header)) + padded_payload
	if total > remaining {
		return {}, .None, nil, 0, false, false
	}
	payload_start := base + size_of(History_Record_Header)
	payload_end := payload_start + int(record_header.payload_bytes)
	for pad := int(record_header.payload_bytes); pad < int(padded_payload); pad += 1 {
		if reader.buffer[payload_start + pad] != 0 {
			return {}, .None, nil, 0, false, false
		}
	}
	payload = reader.buffer[payload_start:payload_end]
	if !payload_valid(parsed_kind, payload) {
		return {}, .None, nil, 0, false, false
	}
	return record_header, parsed_kind, payload, total, true, true
}

// history_reader_next reads and validates the next record, advancing
// read_offset only when the record is completely valid.
history_reader_next :: proc "contextless" (reader: ^History_Reader) -> (record_header: History_Record_Header, kind: History_Record_Kind, payload: []u8, has_more: bool, ok: bool) {
	stride: u64
	record_header, kind, payload, stride, has_more, ok = history_reader_peek(reader)
	if ok && has_more {
		history_reader_advance(reader, record_header, stride)
	}
	return record_header, kind, payload, has_more, ok
}

// Typed payload decoders for readers that already passed the border.
kernel_completion_from_payload :: proc "contextless" (payload: []u8) -> (entry: Kernel_Completion_Payload, copied_bytes: []u8, ok: bool) {
	if !payload_valid(.Kernel_Completion, payload) {
		return {}, nil, false
	}
	entry = copy_from_bytes(payload, Kernel_Completion_Payload)
	copied_bytes = payload[size_of(Kernel_Completion_Payload):]
	return entry, copied_bytes, true
}

cycle_counter_from_payload :: proc "contextless" (payload: []u8) -> (entry: Cycle_Counter_Payload, ok: bool) {
	if !payload_valid(.Cycle_Counter, payload) {
		return {}, false
	}
	return copy_from_bytes(payload, Cycle_Counter_Payload), true
}

cpuid_from_payload :: proc "contextless" (payload: []u8) -> (entry: Cpuid_Payload, ok: bool) {
	if !payload_valid(.Processor_Identification, payload) {
		return {}, false
	}
	return copy_from_bytes(payload, Cpuid_Payload), true
}

history_end_from_payload :: proc "contextless" (payload: []u8) -> (entry: History_End_Payload, reason: History_End_Reason, div_kind: Divergence_Kind, ok: bool) {
	if !payload_valid(.History_End, payload) {
		return {}, .None, .None, false
	}
	entry = copy_from_bytes(payload, History_End_Payload)
	reason, _ = history_end_reason_of_word(u64(entry.reason))
	div_kind, _ = divergence_kind_of_word(u64(entry.divergence_kind))
	return entry, reason, div_kind, true
}

// The live event observed from a replayed thread at an input point.
Replay_Actual_Event :: struct {
	kind:                History_Record_Kind,
	instruction_address: u64,
	stack_pointer:       u64,
	// Kernel_Completion fields:
	command_kind:        u32,
	command_tag:         u32,
	command_values:      [7]u64,
	// Cycle_Counter field:
	is_rdtscp:           u32,
	// Processor_Identification fields:
	cpuid_leaf:          u32,
	cpuid_subleaf:       u32,
}

// Outcome of comparing an actual replay event against the next recorded record.
Replay_Check_Result :: struct {
	divergence: Divergence_Kind, // .None when actual matches recorded.
	expected:   u64,
	actual:     u64,
}

// replay_step_check compares an actual event produced by a replayed thread
// against the next recorded input history record. Pure and deterministic.
replay_step_check :: proc "contextless" (actual: Replay_Actual_Event, has_recorded: bool, recorded_header: History_Record_Header, recorded_kind: History_Record_Kind, recorded_payload: []u8) -> Replay_Check_Result {
	if actual.kind == .None {
		return {.Kind_Mismatch, u64(recorded_kind), u64(actual.kind)}
	}
	if !has_recorded || recorded_kind == .None {
		return {.Missing_Record, u64(actual.kind), 0}
	}
	if recorded_kind == .History_End {
		return {.Missing_Record, u64(actual.kind), u64(History_Record_Kind.History_End)}
	}
	if recorded_kind != actual.kind {
		return {.Kind_Mismatch, u64(recorded_kind), u64(actual.kind)}
	}
	if recorded_header.instruction_address != actual.instruction_address {
		return {.Unexpected_Instruction, recorded_header.instruction_address, actual.instruction_address}
	}
	if recorded_header.stack_pointer != actual.stack_pointer {
		return {.Unexpected_Instruction, recorded_header.stack_pointer, actual.stack_pointer}
	}
	switch recorded_kind {
	case .None, .History_End:
		return {.Missing_Record, u64(actual.kind), 0}
	case .Kernel_Completion:
		entry, _, ok := kernel_completion_from_payload(recorded_payload)
		if !ok {
			return {.Missing_Record, u64(actual.kind), 0}
		}
		if entry.command_kind != actual.command_kind {
			return {.Unexpected_Operation, u64(entry.command_kind), u64(actual.command_kind)}
		}
		if entry.command_tag != actual.command_tag {
			return {.Unexpected_Arguments, u64(entry.command_tag), u64(actual.command_tag)}
		}
		for index in 0 ..< len(entry.command_values) {
			if entry.command_values[index] != actual.command_values[index] {
				return {.Unexpected_Arguments, entry.command_values[index], actual.command_values[index]}
			}
		}
	case .Cycle_Counter:
		entry, ok := cycle_counter_from_payload(recorded_payload)
		if !ok {
			return {.Missing_Record, u64(actual.kind), 0}
		}
		if entry.is_rdtscp != actual.is_rdtscp {
			return {.Unexpected_Instruction, u64(entry.is_rdtscp), u64(actual.is_rdtscp)}
		}
	case .Processor_Identification:
		entry, ok := cpuid_from_payload(recorded_payload)
		if !ok {
			return {.Missing_Record, u64(actual.kind), 0}
		}
		if entry.leaf != actual.cpuid_leaf {
			return {.Unexpected_Arguments, u64(entry.leaf), u64(actual.cpuid_leaf)}
		}
		if entry.subleaf != actual.cpuid_subleaf {
			return {.Unexpected_Arguments, u64(entry.subleaf), u64(actual.cpuid_subleaf)}
		}
	case .Page_Delta:
		if _, ok := page_delta_validate(recorded_payload); !ok {
			return {.Missing_Record, u64(actual.kind), 0}
		}
	case .Shared_Mapping:
		// A shared mapping belongs to the head of a history, or follows the
		// completion of a Memory_Map (replay_shared_mapping_check): no event
		// of a replayed thread is one.
		return {.Kind_Mismatch, u64(recorded_kind), u64(actual.kind)}
	}
	return {.None, 0, 0}
}

// replay_end_check compares the stop of a replayed process by its own
// instructions (a stop of itself, its last thread, a fault) with the next
// record of the history, after the record of its last kernel entry. The
// record stopped there too only when that next record is a History_End
// with Normal_Stop. Unexpected_End gives the recorded kind and the kind
// History_End when the history goes on, and the recorded and Normal_Stop
// reasons when the history ended for another reason.
replay_end_check :: proc "contextless" (has_recorded: bool, recorded_kind: History_Record_Kind, recorded_payload: []u8) -> Replay_Check_Result {
	if !has_recorded || recorded_kind == .None {
		return {.Unexpected_End, 0, u64(History_Record_Kind.History_End)}
	}
	if recorded_kind != .History_End {
		return {.Unexpected_End, u64(recorded_kind), u64(History_Record_Kind.History_End)}
	}
	_, reason, _, ok := history_end_from_payload(recorded_payload)
	if !ok {
		return {.Unexpected_End, 0, u64(History_Record_Kind.History_End)}
	}
	if reason != .Normal_Stop {
		return {.Unexpected_End, u64(reason), u64(History_End_Reason.Normal_Stop)}
	}
	return {.None, 0, 0}
}

// The most stand-in mappings of one replay: one for each page that the
// kernel keeps for one record (a point copy or a shared page), so a record
// whose pages are each a mapping of their own can still be replayed. The
// kernel checks this sum against its own capacities.
STAND_IN_MAPPING_CAPACITY :: 96
// The most pages of all the stand-in mappings of one replay: the point copies
// and the shared pages that the kernel keeps for one record.
STAND_IN_PAGE_LIMIT :: u64(96)

// One range of private pages that a replay maps where the record had a
// shared mapping.
Stand_In_Mapping :: struct {
	virtual_address: u64,
	page_count:      u64,
	access:          Shared_Mapping_Access,
	place:           u32, // What backs the pages, for the owner of the set: the memory object in the kernel.
	place_serial:    u64, // The serial of that place when it was added: a place used again later is another object.
}

// The stand-in mappings of one replay. They never overlap, so a page names at
// most one of them.
Stand_In_Mapping_Set :: struct {
	mappings:   [STAND_IN_MAPPING_CAPACITY]Stand_In_Mapping,
	count:      int,
	page_count: u64,
}

// stand_in_mapping_set_admits says whether entry fits the set: a range that
// meets no range of the set, a free place, and pages in the bound. It
// changes nothing.
stand_in_mapping_set_admits :: proc "contextless" (set: ^Stand_In_Mapping_Set, entry: Shared_Mapping_Payload) -> bool {
	if set == nil || set.count >= STAND_IN_MAPPING_CAPACITY || entry.page_count == 0 || entry.page_count > SHARED_MAPPING_PAGE_LIMIT {
		return false
	}
	if entry.page_count > STAND_IN_PAGE_LIMIT - set.page_count {
		return false
	}
	if entry.virtual_address >= op.USER_END || entry.page_count * HISTORY_PAGE_SIZE > op.USER_END - entry.virtual_address {
		return false
	}
	end := entry.virtual_address + entry.page_count * HISTORY_PAGE_SIZE
	for mapping in set.mappings[:set.count] {
		mapping_end := mapping.virtual_address + mapping.page_count * HISTORY_PAGE_SIZE
		if entry.virtual_address < mapping_end && mapping.virtual_address < end {
			return false
		}
	}
	return true
}

// stand_in_mapping_set_add adds a validated shared mapping with the place
// that backs it. Refused: a range that meets one of the set, a full set,
// pages past STAND_IN_PAGE_LIMIT, an access None. On a refusal the set is
// unchanged.
stand_in_mapping_set_add :: proc "contextless" (set: ^Stand_In_Mapping_Set, entry: Shared_Mapping_Payload, access: Shared_Mapping_Access, place: u32, place_serial: u64 = 0) -> bool {
	if access == .None || !stand_in_mapping_set_admits(set, entry) {
		return false
	}
	set.mappings[set.count] = {virtual_address = entry.virtual_address, page_count = entry.page_count, access = access, place = place, place_serial = place_serial}
	set.count += 1
	set.page_count += entry.page_count
	return true
}

// stand_in_mapping_set_remove removes each stand-in mapping backed by
// place, when the replay unmapped it: a later delta at its addresses finds
// no stand-in mapping, and a place that serves again names nothing of the
// set. It gives the count of the mappings that it removed; the order of the
// others does not count.
stand_in_mapping_set_remove :: proc "contextless" (set: ^Stand_In_Mapping_Set, place: u32) -> (removed: int) {
	if set == nil {
		return 0
	}
	index := 0
	for index < set.count {
		if set.mappings[index].place != place {
			index += 1
			continue
		}
		set.page_count -= set.mappings[index].page_count
		set.count -= 1
		set.mappings[index] = set.mappings[set.count]
		set.mappings[set.count] = {}
		removed += 1
	}
	return removed
}

// stand_in_mapping_set_find gives the stand-in mapping that holds the page at
// virtual_address, and the index of the page inside it.
stand_in_mapping_set_find :: proc "contextless" (set: ^Stand_In_Mapping_Set, virtual_address: u64) -> (mapping: Stand_In_Mapping, page: u64, ok: bool) {
	if set == nil {
		return {}, 0, false
	}
	for candidate in set.mappings[:set.count] {
		if virtual_address >= candidate.virtual_address && virtual_address - candidate.virtual_address < candidate.page_count * HISTORY_PAGE_SIZE {
			return candidate, (virtual_address - candidate.virtual_address) / HISTORY_PAGE_SIZE, true
		}
	}
	return {}, 0, false
}

// stand_in_mapping_set_remove_range removes each mapping of the set that
// lies whole inside the range that a process unmapped. The record keeps the
// set of the stand-in mappings that its replay will make, by address, so
// it refuses a mapping that the replay could not hold: one unmap removes
// what that mapping named, and the other mappings of the same memory object
// stay. It gives the count of the mappings that it removed.
stand_in_mapping_set_remove_range :: proc "contextless" (set: ^Stand_In_Mapping_Set, virtual_address: u64, page_count: u64) -> (removed: int) {
	if set == nil || page_count == 0 || virtual_address >= op.USER_END || page_count > (op.USER_END - virtual_address) / HISTORY_PAGE_SIZE {
		return 0
	}
	end := virtual_address + page_count * HISTORY_PAGE_SIZE
	index := 0
	for index < set.count {
		mapping := set.mappings[index]
		if mapping.virtual_address < virtual_address || mapping.virtual_address + mapping.page_count * HISTORY_PAGE_SIZE > end {
			index += 1
			continue
		}
		set.page_count -= mapping.page_count
		set.count -= 1
		set.mappings[index] = set.mappings[set.count]
		set.mappings[set.count] = {}
		removed += 1
	}
	return removed
}

// shared_mapping_access_of_map_flags gives the access that a record names
// for a mapping that a recorded process makes, after its start, of memory
// that another process holds. Refused: Execute (a stand-in mapping never
// runs code, and a page that a peer writes must not either), No_Access (a
// point copy needs a page that the process can read), and At_Address_Zero
// (the memory of a guest, which a recorded process never holds).
shared_mapping_access_of_map_flags :: proc "contextless" (flags: op.Map_Flags) -> (access: Shared_Mapping_Access, ok: bool) {
	if .Execute in flags || .No_Access in flags || .At_Address_Zero in flags {
		return .None, false
	}
	if .Write in flags {
		return .Read_Write, true
	}
	return .Read, true
}

// replay_shared_mapping_check compares a Memory_Map of a replayed process,
// with the address of its recorded completion, against the Shared_Mapping
// that the history holds right after that completion. The replay maps a
// stand-in mapping there only when each of these agrees: the map is in the
// process itself, its flags give the recorded access, the recorded mapping
// starts at the recorded completion and at the asked address, and it has
// the asked count of pages. A count of 0 asks for the rest of the memory
// object, which the replay does not hold: the history gives it. The first
// disagreement is an Unexpected_Arguments with the value of the history
// and the value of the replay.
replay_shared_mapping_check :: proc "contextless" (command_values: [7]u64, completion_address: u64, entry: Shared_Mapping_Payload, access: Shared_Mapping_Access) -> Replay_Check_Result {
	if command_values[1] != 0 {
		return {.Unexpected_Arguments, 0, command_values[1]}
	}
	if command_values[3] & ~op.MAP_FLAGS_KNOWN != 0 {
		return {.Unexpected_Arguments, u64(access), command_values[3]}
	}
	asked, asked_ok := shared_mapping_access_of_map_flags(transmute(op.Map_Flags)command_values[3])
	if !asked_ok {
		return {.Unexpected_Arguments, u64(access), command_values[3]}
	}
	if asked != access {
		return {.Unexpected_Arguments, u64(access), u64(asked)}
	}
	if entry.virtual_address != completion_address {
		return {.Unexpected_Arguments, entry.virtual_address, completion_address}
	}
	if command_values[2] != 0 && command_values[2] != entry.virtual_address {
		return {.Unexpected_Arguments, entry.virtual_address, command_values[2]}
	}
	if command_values[5] != 0 && command_values[5] != entry.page_count {
		return {.Unexpected_Arguments, entry.page_count, command_values[5]}
	}
	return {.None, 0, 0}
}

// The first divergence of a replay, as a reader shows it: what differed,
// where, the two values, and the record that the history held there.
Divergence_Report :: struct {
	kind:                         Divergence_Kind,
	point:                        u64, // The input point of the divergence.
	expected:                     u64, // The value of the history.
	actual:                       u64, // The value of the replay.
	recorded_kind:                History_Record_Kind, // The record at that point; None when the history has no record there.
	recorded_instruction_address: u64, // Its instruction address, or 0.
	recorded_stack_pointer:       u64, // Its stack pointer, or 0.
}

// divergence_report_of_history reads the header of a history through its
// border, and, when a replay ended it with a divergence, finds the record
// at the point of the divergence. found is false when the history did not
// end with a divergence. ok is false when the header or a record before
// that point fails the border: a report from a damaged history could name
// a record that is not the one the replay read. A record that fails the
// border at that point gives the report of the header with no record. scratch holds one record:
// at least MAX_RECORD_PAYLOAD_BYTES bytes.
divergence_report_of_history :: proc "contextless" (buffer: []u8, scratch: []u8) -> (report: Divergence_Report, found: bool, ok: bool) {
	reader, opened := history_reader_open(buffer)
	if !opened {
		return {}, false, false
	}
	end_reason, _ := history_end_reason_of_word(u64(reader.header.end_reason))
	if end_reason != .Divergence {
		return {}, false, true
	}
	kind, _ := divergence_kind_of_word(u64(reader.header.divergence_kind))
	report = {
		kind     = kind,
		point    = reader.header.divergence_point,
		expected = reader.header.divergence_expected,
		actual   = reader.header.divergence_actual,
	}
	for {
		record_header, record_kind, _, has_more, read_ok := history_reader_next_into(&reader, scratch)
		if !read_ok {
			// A damaged record at or past the point is the record that the
			// replay could not read, as Missing_Record says: the header
			// holds the report, and no record is named. A damaged record
			// before the point refuses the report.
			if history_reader_next_point(&reader) >= report.point {
				return report, true, true
			}
			return {}, false, false
		}
		if !has_more || record_header.point_number > report.point {
			return report, true, true
		}
		if record_header.point_number == report.point {
			report.recorded_kind = record_kind
			report.recorded_instruction_address = record_header.instruction_address
			report.recorded_stack_pointer = record_header.stack_pointer
			return report, true, true
		}
	}
}
