#+build !freestanding
package input_history

import "core:testing"
import op "modus:contract/operation"

// Every closed enum border accepts its members and refuses edges past the bound.
@(test)
enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	for kind in History_Record_Kind {
		parsed, ok := history_record_kind_of_word(u64(kind))
		testing.expect(t, ok)
		testing.expect_value(t, parsed, kind)
	}
	for bad in ([?]u64{u64(max(History_Record_Kind)) + 1, 255, u64(max(u32)), max(u64)}) {
		_, ok := history_record_kind_of_word(bad)
		testing.expect(t, !ok)
	}

	for reason in History_End_Reason {
		parsed, ok := history_end_reason_of_word(u64(reason))
		testing.expect(t, ok)
		testing.expect_value(t, parsed, reason)
	}
	for bad in ([?]u64{u64(max(History_End_Reason)) + 1, u64(max(u32)), max(u64)}) {
		_, ok := history_end_reason_of_word(bad)
		testing.expect(t, !ok)
	}

	for mode in Record_Mode {
		parsed, ok := record_mode_of_word(u64(mode))
		testing.expect(t, ok)
		testing.expect_value(t, parsed, mode)
	}
	for bad in ([?]u64{u64(max(Record_Mode)) + 1, 255, max(u64)}) {
		_, ok := record_mode_of_word(bad)
		testing.expect(t, !ok)
	}

	for div in Divergence_Kind {
		parsed, ok := divergence_kind_of_word(u64(div))
		testing.expect(t, ok)
		testing.expect_value(t, parsed, div)
	}
	for bad in ([?]u64{u64(max(Divergence_Kind)) + 1, u64(max(u32)), max(u64)}) {
		_, ok := divergence_kind_of_word(bad)
		testing.expect(t, !ok)
	}
}

// Header validation refuses buffers too small, bad magic, bad version,
// non-zero flags, invalid bounds, unknown header enums, and non-zero reserved bytes.
@(test)
reader_refuses_corrupt_headers :: proc(t: ^testing.T) {
	// Empty, 1 byte, and one byte short of a header.
	tiny: [size_of(History_Header) - 1]u8
	_, ok := history_reader_open(nil)
	testing.expect(t, !ok)
	_, ok = history_reader_open(tiny[:1])
	testing.expect(t, !ok)
	_, ok = history_reader_open(tiny[:])
	testing.expect(t, !ok)

	// Writer also refuses buffers smaller than MIN_HISTORY_BUFFER_BYTES.
	short_for_writer: [MIN_HISTORY_BUFFER_BYTES - 1]u8
	_, ok = history_writer_init(short_for_writer[:], {}, 2_000_000_000, 100, 7)
	testing.expect(t, !ok)

	// Start with a valid buffer, then mutate one header field at a time.
	base: [4096]u8
	hash: [32]u8
	hash[0] = 0xAB
	_, ok = history_writer_init(base[:], hash, 2_000_000_000, 100, 7)
	testing.expect(t, ok)

	mutate :: proc(base_buf: []u8, edit: proc(h: ^History_Header)) -> [4096]u8 {
		buf: [4096]u8
		copy(buf[:], base_buf)
		h := (^History_Header)(raw_data(buf[:]))
		edit(h)
		return buf
	}

	bad_cases := [?]proc(h: ^History_Header) {
		proc(h: ^History_Header) { h.magic = 0 },
		proc(h: ^History_Header) { h.magic ~= 1 },
		proc(h: ^History_Header) { h.version = 0 },
		proc(h: ^History_Header) { h.version = HISTORY_VERSION + 1 },
		proc(h: ^History_Header) { h.version = max(u32) },
		proc(h: ^History_Header) { h.flags = 1 },
		proc(h: ^History_Header) { h.capacity_bytes = 4096 - size_of(History_Header) + 1 },
		proc(h: ^History_Header) { h.capacity_bytes = max(u64) },
		proc(h: ^History_Header) { h.written_bytes = h.capacity_bytes + 1 },
		proc(h: ^History_Header) { h.read_bytes = 1 }, // read_bytes > written_bytes (0)
		proc(h: ^History_Header) { h.end_reason = u32(max(History_End_Reason)) + 1 },
		proc(h: ^History_Header) { h.divergence_kind = u32(max(Divergence_Kind)) + 1 },
		proc(h: ^History_Header) { h.reserved[0] = 1 },
		proc(h: ^History_Header) { h.reserved[len(h.reserved) - 1] = 0x80 },
	}
	for edit in bad_cases {
		buf := mutate(base[:], edit)
		_, opened := history_reader_open(buf[:])
		testing.expect(t, !opened)
	}
}

// Reader refuses truncated record headers, truncated payloads, unknown record
// kinds (0, bound+1, max), oversized payload_bytes, and non-zero padding bytes,
// leaving read_offset unchanged on refusal.
@(test)
reader_refuses_corrupt_and_truncated_records :: proc(t: ^testing.T) {
	buf: [4096]u8
	writer, init_ok := history_writer_init(buf[:], {}, 1_000_000_000, 0, 3)
	testing.expect(t, init_ok)
	testing.expect(t, history_writer_append_cycle_counter(&writer, 0x401000, 0x7FFF_0000, {cycles = 42, processor_auxiliary = 0, is_rdtscp = 0}))
	valid_written := writer.write_offset

	// Truncated record header (1 byte, 31 bytes).
	for truncated_len in ([?]u64{1, size_of(History_Record_Header) - 1}) {
		copy_buf := buf
		(^History_Header)(raw_data(copy_buf[:])).written_bytes = truncated_len
		reader, open_ok := history_reader_open(copy_buf[:])
		testing.expect(t, open_ok)
		_, _, _, has_more, ok := history_reader_next(&reader)
		testing.expect(t, !ok && !has_more)
		testing.expect_value(t, reader.read_offset, u64(0))
	}

	// Truncated record payload (header intact, payload cut by 1 byte).
	{
		copy_buf := buf
		(^History_Header)(raw_data(copy_buf[:])).written_bytes = valid_written - 1
		reader, open_ok := history_reader_open(copy_buf[:])
		testing.expect(t, open_ok)
		_, _, _, has_more, ok := history_reader_next(&reader)
		testing.expect(t, !ok && !has_more)
		testing.expect_value(t, reader.read_offset, u64(0))
	}

	// Unknown record kinds: 0 (None), max+1, max(u32).
	for bad_kind in ([?]u32{0, u32(max(History_Record_Kind)) + 1, max(u32)}) {
		copy_buf := buf
		rec := (^History_Record_Header)(raw_data(copy_buf[size_of(History_Header):]))
		rec.kind = bad_kind
		reader, open_ok := history_reader_open(copy_buf[:])
		testing.expect(t, open_ok)
		_, _, _, _, ok := history_reader_next(&reader)
		testing.expect(t, !ok)
		testing.expect_value(t, reader.read_offset, u64(0))
	}

	// Payload length past MAX_RECORD_PAYLOAD_BYTES and max(u32).
	for bad_len in ([?]u32{MAX_RECORD_PAYLOAD_BYTES + 1, max(u32)}) {
		copy_buf := buf
		rec := (^History_Record_Header)(raw_data(copy_buf[size_of(History_Header):]))
		rec.payload_bytes = bad_len
		reader, open_ok := history_reader_open(copy_buf[:])
		testing.expect(t, open_ok)
		_, _, _, _, ok := history_reader_next(&reader)
		testing.expect(t, !ok)
		testing.expect_value(t, reader.read_offset, u64(0))
	}

	// Non-zero alignment padding byte after a Page_Delta of odd byte length.
	{
		pad_buf: [4096]u8
		w, ok := history_writer_init(pad_buf[:], {}, 1_000_000_000, 0, 3)
		testing.expect(t, ok)
		before, after: [HISTORY_PAGE_SIZE]u8
		after[10] = 0x55 // 1 changed byte -> payload = 16 + 4 + 1 = 21 bytes, padded to 24.
		delta: [PAGE_DELTA_MAX_BYTES]u8
		written, changed, enc_ok := page_delta_encode(0x4000, &before, &after, delta[:])
		testing.expect(t, enc_ok && changed)
		testing.expect_value(t, written, 21)
		testing.expect(t, history_writer_append(&w, .Page_Delta, 0x401000, 0x7FFF_0000, delta[:written]))
		// Corrupt padding byte 21 (the first pad byte).
		pad_buf[size_of(History_Header) + size_of(History_Record_Header) + 21] = 0xFF
		r, r_ok := history_reader_open(pad_buf[:])
		testing.expect(t, r_ok)
		_, _, _, _, next_ok := history_reader_next(&r)
		testing.expect(t, !next_ok)
		testing.expect_value(t, r.read_offset, u64(0))
	}

	// Invalid Cycle_Counter payload: is_rdtscp == 2, or rdtsc with non-zero aux.
	{
		copy_buf := buf
		payload_ptr := (^Cycle_Counter_Payload)(raw_data(copy_buf[size_of(History_Header) + size_of(History_Record_Header):]))
		payload_ptr.is_rdtscp = 2
		r, _ := history_reader_open(copy_buf[:])
		_, _, _, _, ok := history_reader_next(&r)
		testing.expect(t, !ok)

		copy_buf = buf
		payload_ptr = (^Cycle_Counter_Payload)(raw_data(copy_buf[size_of(History_Header) + size_of(History_Record_Header):]))
		payload_ptr.processor_auxiliary = 1
		r, _ = history_reader_open(copy_buf[:])
		_, _, _, _, ok = history_reader_next(&r)
		testing.expect(t, !ok)
	}
}

// Page delta encoder/validator/applier refuses invalid virtual addresses,
// zero ranges, zero-length ranges, offset+length > 4096, overlapping ranges,
// out-of-order ranges, non-zero reserved field, and truncated/trailing bytes,
// leaving the target page completely untouched on every refusal.
@(test)
page_delta_adversarial_refusals_and_round_trip :: proc(t: ^testing.T) {
	before, after: [HISTORY_PAGE_SIZE]u8
	scratch: [PAGE_DELTA_MAX_BYTES]u8

	// Unaligned and out-of-user-range virtual addresses are refused.
	for bad_addr in ([?]u64{1, 4095, op.USER_END, op.USER_END + 4096, max(u64)}) {
		_, _, ok := page_delta_encode(bad_addr, &before, &after, scratch[:])
		testing.expect(t, !ok)
	}

	// Identical pages emit no delta.
	written, changed, ok := page_delta_encode(0x1000, &before, &after, scratch[:])
	testing.expect(t, ok && !changed && written == 0)

	// Encode three disjoint ranges: offset 0 (1 byte), offset 100 (5 bytes), offset 4095 (1 byte).
	after[0] = 0xAA
	after[100] = 1
	after[101] = 2
	after[102] = 3
	after[103] = 4
	after[104] = 5
	after[4095] = 0xEE
	written, changed, ok = page_delta_encode(0x7000, &before, &after, scratch[:])
	testing.expect(t, ok && changed)
	testing.expect_value(t, written, size_of(Page_Delta_Header) + 3 * size_of(Page_Delta_Range) + 7)

	// Too-small destination buffer fails cleanly.
	_, ch_small, ok_small := page_delta_encode(0x7000, &before, &after, scratch[:written - 1])
	testing.expect(t, !ok_small && ch_small)

	// Valid delta applies cleanly to a copy of before and equals after.
	applied := before
	testing.expect(t, page_delta_apply(scratch[:written], &applied))
	testing.expect(t, applied == after)

	// Worst-case alternating bytes: must fit within PAGE_DELTA_MAX_BYTES and round-trip.
	alt_before, alt_after: [HISTORY_PAGE_SIZE]u8
	for i := 0; i < int(HISTORY_PAGE_SIZE); i += 2 {
		alt_after[i] = u8((i / 2) & 0xFF) | 1
	}
	alt_written, alt_changed, alt_ok := page_delta_encode(0x8000, &alt_before, &alt_after, scratch[:])
	testing.expect(t, alt_ok && alt_changed)
	testing.expect_value(t, alt_written, PAGE_DELTA_MAX_BYTES)
	alt_applied := alt_before
	testing.expect(t, page_delta_apply(scratch[:alt_written], &alt_applied))
	testing.expect(t, alt_applied == alt_after)

	// Adversarial crafted payloads: page must remain identical to sentinel on every refusal.
	sentinel: [HISTORY_PAGE_SIZE]u8
	for &b, i in sentinel {
		b = u8((i * 37 + 13) & 0xFF)
	}
	expect_refused :: proc(t: ^testing.T, payload: []u8, sentinel: ^[HISTORY_PAGE_SIZE]u8) {
		page := sentinel^
		testing.expect(t, !page_delta_apply(payload, &page))
		testing.expect(t, page == sentinel^)
	}

	// Empty and truncated header.
	expect_refused(t, nil, &sentinel)
	expect_refused(t, scratch[:size_of(Page_Delta_Header) - 1], &sentinel)

	// range_count == 0.
	{
		bad: [size_of(Page_Delta_Header)]u8
		(^Page_Delta_Header)(raw_data(bad[:]))^ = {virtual_address = 0x1000, range_count = 0}
		expect_refused(t, bad[:], &sentinel)
	}

	// Non-zero reserved field.
	{
		bad: [size_of(Page_Delta_Header) + size_of(Page_Delta_Range) + 1]u8
		(^Page_Delta_Header)(raw_data(bad[:]))^ = {virtual_address = 0x1000, range_count = 1, reserved = 1}
		(^Page_Delta_Range)(raw_data(bad[size_of(Page_Delta_Header):]))^ = {offset = 0, length = 1}
		expect_refused(t, bad[:], &sentinel)
	}

	// Zero-length range.
	{
		bad: [size_of(Page_Delta_Header) + size_of(Page_Delta_Range)]u8
		(^Page_Delta_Header)(raw_data(bad[:]))^ = {virtual_address = 0x1000, range_count = 1}
		(^Page_Delta_Range)(raw_data(bad[size_of(Page_Delta_Header):]))^ = {offset = 10, length = 0}
		expect_refused(t, bad[:], &sentinel)
	}

	// offset + length == 4097 (one past 4096) and offset == 4096.
	{
		bad: [size_of(Page_Delta_Header) + size_of(Page_Delta_Range) + 2]u8
		(^Page_Delta_Header)(raw_data(bad[:]))^ = {virtual_address = 0x1000, range_count = 1}
		(^Page_Delta_Range)(raw_data(bad[size_of(Page_Delta_Header):]))^ = {offset = 4095, length = 2}
		expect_refused(t, bad[:], &sentinel)

		(^Page_Delta_Range)(raw_data(bad[size_of(Page_Delta_Header):]))^ = {offset = 4096, length = 1}
		expect_refused(t, bad[:size_of(Page_Delta_Header) + size_of(Page_Delta_Range) + 1], &sentinel)

		(^Page_Delta_Range)(raw_data(bad[size_of(Page_Delta_Header):]))^ = {offset = max(u16), length = 2}
		expect_refused(t, bad[:], &sentinel)
	}

	// Overlapping ranges: range 0 covers [10, 14), range 1 starts at 13 (even though range 0 is valid, page must remain untouched!).
	{
		bad: [size_of(Page_Delta_Header) + 2 * size_of(Page_Delta_Range) + 6]u8
		(^Page_Delta_Header)(raw_data(bad[:]))^ = {virtual_address = 0x1000, range_count = 2}
		c := size_of(Page_Delta_Header)
		(^Page_Delta_Range)(raw_data(bad[c:]))^ = {offset = 10, length = 4}
		c += size_of(Page_Delta_Range)
		bad[c + 0], bad[c + 1], bad[c + 2], bad[c + 3] = 0xFF, 0xFF, 0xFF, 0xFF
		c += 4
		(^Page_Delta_Range)(raw_data(bad[c:]))^ = {offset = 13, length = 2}
		c += size_of(Page_Delta_Range)
		bad[c + 0], bad[c + 1] = 0xEE, 0xEE
		expect_refused(t, bad[:], &sentinel)
	}

	// Out-of-order ranges: range 0 at [20, 22), range 1 at [5, 7).
	{
		bad: [size_of(Page_Delta_Header) + 2 * size_of(Page_Delta_Range) + 4]u8
		(^Page_Delta_Header)(raw_data(bad[:]))^ = {virtual_address = 0x1000, range_count = 2}
		c := size_of(Page_Delta_Header)
		(^Page_Delta_Range)(raw_data(bad[c:]))^ = {offset = 20, length = 2}
		c += size_of(Page_Delta_Range) + 2
		(^Page_Delta_Range)(raw_data(bad[c:]))^ = {offset = 5, length = 2}
		expect_refused(t, bad[:], &sentinel)
	}

	// Trailing garbage byte after a valid delta.
	{
		bad: [size_of(Page_Delta_Header) + size_of(Page_Delta_Range) + 2]u8
		(^Page_Delta_Header)(raw_data(bad[:]))^ = {virtual_address = 0x1000, range_count = 1}
		(^Page_Delta_Range)(raw_data(bad[size_of(Page_Delta_Header):]))^ = {offset = 0, length = 1}
		expect_refused(t, bad[:], &sentinel)
	}
}

// replay_step_check detects every Divergence_Kind accurately and returns .None
// only on an exact match.
@(test)
replay_step_check_catches_every_divergence_kind :: proc(t: ^testing.T) {
	rec_header := History_Record_Header {
		kind                = u32(History_Record_Kind.Kernel_Completion),
		payload_bytes       = size_of(Kernel_Completion_Payload),
		point_number        = 1,
		instruction_address = 0x40_1200,
		stack_pointer       = 0x7FFF_DF00,
	}
	rec_kc := Kernel_Completion_Payload {
		command_kind             = u32(op.Operation.Memory_Size),
		command_tag              = 7,
		command_values           = {1, 2, 3, 4, 5, 6, 7},
		completion_status        = u32(op.Status.Ok),
		completion_values        = {16, 0, 0, 0, 0, 0, 0},
		return_time_milliseconds = 500,
	}
	kc_bytes := ([^]u8)(&rec_kc)[:size_of(rec_kc)]

	matching := Replay_Actual_Event {
		kind                = .Kernel_Completion,
		instruction_address = 0x40_1200,
		stack_pointer       = 0x7FFF_DF00,
		command_kind        = u32(op.Operation.Memory_Size),
		command_tag         = 7,
		command_values      = {1, 2, 3, 4, 5, 6, 7},
	}

	// Exact match succeeds.
	res := replay_step_check(matching, true, rec_header, .Kernel_Completion, kc_bytes)
	testing.expect_value(t, res.divergence, Divergence_Kind.None)

	// Missing_Record: stream ended or hit History_End.
	res = replay_step_check(matching, false, {}, .None, nil)
	testing.expect_value(t, res.divergence, Divergence_Kind.Missing_Record)

	end_p := History_End_Payload{reason = u32(History_End_Reason.Normal_Stop)}
	end_h := History_Record_Header{kind = u32(History_Record_Kind.History_End), payload_bytes = size_of(end_p)}
	res = replay_step_check(matching, true, end_h, .History_End, ([^]u8)(&end_p)[:size_of(end_p)])
	testing.expect_value(t, res.divergence, Divergence_Kind.Missing_Record)

	// Kind_Mismatch: actual Cycle_Counter vs recorded Kernel_Completion.
	wrong_kind := matching
	wrong_kind.kind = .Cycle_Counter
	res = replay_step_check(wrong_kind, true, rec_header, .Kernel_Completion, kc_bytes)
	testing.expect_value(t, res.divergence, Divergence_Kind.Kind_Mismatch)
	testing.expect_value(t, res.expected, u64(History_Record_Kind.Kernel_Completion))
	testing.expect_value(t, res.actual, u64(History_Record_Kind.Cycle_Counter))

	// Unexpected_Instruction: RIP mismatch, RSP mismatch, rdtsc vs rdtscp.
	wrong_rip := matching
	wrong_rip.instruction_address = 0x40_1204
	res = replay_step_check(wrong_rip, true, rec_header, .Kernel_Completion, kc_bytes)
	testing.expect_value(t, res.divergence, Divergence_Kind.Unexpected_Instruction)
	testing.expect_value(t, res.expected, u64(0x40_1200))
	testing.expect_value(t, res.actual, u64(0x40_1204))

	wrong_rsp := matching
	wrong_rsp.stack_pointer = 0x7FFF_DEF8
	res = replay_step_check(wrong_rsp, true, rec_header, .Kernel_Completion, kc_bytes)
	testing.expect_value(t, res.divergence, Divergence_Kind.Unexpected_Instruction)

	tsc_rec := Cycle_Counter_Payload{cycles = 999, processor_auxiliary = 0, is_rdtscp = 0}
	tsc_h := History_Record_Header{kind = u32(History_Record_Kind.Cycle_Counter), payload_bytes = size_of(tsc_rec), instruction_address = 0x40_1300, stack_pointer = 0x7FFF_DF00}
	tsc_actual := Replay_Actual_Event{kind = .Cycle_Counter, instruction_address = 0x40_1300, stack_pointer = 0x7FFF_DF00, is_rdtscp = 1}
	res = replay_step_check(tsc_actual, true, tsc_h, .Cycle_Counter, ([^]u8)(&tsc_rec)[:size_of(tsc_rec)])
	testing.expect_value(t, res.divergence, Divergence_Kind.Unexpected_Instruction)

	// Unexpected_Operation: different kernel operation.
	wrong_op := matching
	wrong_op.command_kind = u32(op.Operation.Log)
	res = replay_step_check(wrong_op, true, rec_header, .Kernel_Completion, kc_bytes)
	testing.expect_value(t, res.divergence, Divergence_Kind.Unexpected_Operation)
	testing.expect_value(t, res.expected, u64(op.Operation.Memory_Size))
	testing.expect_value(t, res.actual, u64(op.Operation.Log))

	// Unexpected_Arguments: command tag mismatch, command value mismatch, cpuid leaf/subleaf mismatch.
	wrong_tag := matching
	wrong_tag.command_tag = 8
	res = replay_step_check(wrong_tag, true, rec_header, .Kernel_Completion, kc_bytes)
	testing.expect_value(t, res.divergence, Divergence_Kind.Unexpected_Arguments)

	wrong_arg := matching
	wrong_arg.command_values[4] = 99
	res = replay_step_check(wrong_arg, true, rec_header, .Kernel_Completion, kc_bytes)
	testing.expect_value(t, res.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, res.expected, u64(5))
	testing.expect_value(t, res.actual, u64(99))

	cpuid_rec := Cpuid_Payload{leaf = 7, subleaf = 0, eax = 1, ebx = 2, ecx = 3, edx = 4}
	cpuid_h := History_Record_Header{kind = u32(History_Record_Kind.Processor_Identification), payload_bytes = size_of(cpuid_rec), instruction_address = 0x40_1400, stack_pointer = 0x7FFF_DF00}
	cpuid_actual := Replay_Actual_Event{kind = .Processor_Identification, instruction_address = 0x40_1400, stack_pointer = 0x7FFF_DF00, cpuid_leaf = 7, cpuid_subleaf = 1}
	res = replay_step_check(cpuid_actual, true, cpuid_h, .Processor_Identification, ([^]u8)(&cpuid_rec)[:size_of(cpuid_rec)])
	testing.expect_value(t, res.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, res.expected, u64(0))
	testing.expect_value(t, res.actual, u64(1))
}

// Round-trip of a multi-event history containing every record kind, plus
// refusal to append after History_End or when the buffer is full.
@(test)
multi_event_history_round_trip :: proc(t: ^testing.T) {
	buf: [16384]u8
	module_hash: [32]u8
	for &b, i in module_hash {
		b = u8(i + 1)
	}
	writer, ok := history_writer_init(buf[:], module_hash, 2_500_000_000, 123456, 7)
	testing.expect(t, ok)

	// 1. Page_Delta
	before, after: [HISTORY_PAGE_SIZE]u8
	after[0] = 0x10
	after[1] = 0x20
	after[2048] = 0x99
	delta_buf: [PAGE_DELTA_MAX_BYTES]u8
	delta_len, delta_changed, delta_ok := page_delta_encode(op.TIME_ADDRESS, &before, &after, delta_buf[:])
	testing.expect(t, delta_ok && delta_changed)
	testing.expect(t, history_writer_append(&writer, .Page_Delta, 0x40_0100, 0x7FFF_E000, delta_buf[:delta_len]))

	// 2. Cycle_Counter (rdtsc and rdtscp)
	testing.expect(t, history_writer_append_cycle_counter(&writer, 0x40_0110, 0x7FFF_E000, {cycles = 1_000_000, processor_auxiliary = 0, is_rdtscp = 0}))
	testing.expect(t, history_writer_append_cycle_counter(&writer, 0x40_0120, 0x7FFF_E000, {cycles = 1_000_500, processor_auxiliary = 0, is_rdtscp = 1}))

	// 3. Processor_Identification
	testing.expect(t, history_writer_append_cpuid(&writer, 0x40_0130, 0x7FFF_E000, {leaf = 1, subleaf = 0, eax = 0x11, ebx = 0x22, ecx = 0x33, edx = 0x44}))

	// 4. Kernel_Completion with copied bytes
	copied := [?]u8{0xDE, 0xAD, 0xBE, 0xEF, 0x01}
	kc := Kernel_Completion_Payload {
		command_kind             = u32(op.Operation.Process_State),
		command_tag              = 42,
		command_values           = {3, 0x10_0000, 0, 0, 0, 0, 0},
		completion_status        = u32(op.Status.Ok),
		copied_bytes_count       = u32(len(copied)),
		completion_values        = {2, 0, 0, 5, 1, 9, 0},
		return_time_milliseconds = 777,
		copied_user_address      = 0x10_0000,
	}
	testing.expect(t, history_writer_append_kernel_completion(&writer, 0x40_0140, 0x7FFF_E000, kc, copied[:]))

	// 5. History_End
	testing.expect(t, history_writer_append_end(&writer, 0x40_0150, 0x7FFF_E000, .Normal_Stop))

	// Appending after History_End is refused and leaves written_bytes unchanged.
	written_after_end := writer.write_offset
	testing.expect(t, !history_writer_append_cycle_counter(&writer, 0x40_0160, 0x7FFF_E000, {cycles = 2_000_000}))
	testing.expect_value(t, writer.write_offset, written_after_end)

	// Read everything back through the strict border.
	reader, open_ok := history_reader_open(buf[:])
	testing.expect(t, open_ok)
	testing.expect_value(t, reader.header.module_hash, module_hash)
	testing.expect_value(t, reader.header.cycle_frequency, u64(2_500_000_000))
	testing.expect_value(t, reader.header.point_count, u64(6))
	testing.expect_value(t, reader.header.end_reason, u32(History_End_Reason.Normal_Stop))

	// Record 1: Page_Delta
	h1, k1, p1, m1, ok1 := history_reader_next(&reader)
	testing.expect(t, ok1 && m1)
	testing.expect_value(t, k1, History_Record_Kind.Page_Delta)
	testing.expect_value(t, h1.point_number, u64(1))
	replayed_page := before
	testing.expect(t, page_delta_apply(p1, &replayed_page))
	testing.expect(t, replayed_page == after)

	// Record 2: rdtsc
	h2, k2, p2, m2, ok2 := history_reader_next(&reader)
	testing.expect(t, ok2 && m2)
	testing.expect_value(t, k2, History_Record_Kind.Cycle_Counter)
	c2, c2_ok := cycle_counter_from_payload(p2)
	testing.expect(t, c2_ok)
	testing.expect_value(t, c2.cycles, u64(1_000_000))
	testing.expect_value(t, h2.instruction_address, u64(0x40_0110))

	// Record 3: rdtscp
	_, k3, p3, m3, ok3 := history_reader_next(&reader)
	testing.expect(t, ok3 && m3)
	testing.expect_value(t, k3, History_Record_Kind.Cycle_Counter)
	c3, c3_ok := cycle_counter_from_payload(p3)
	testing.expect(t, c3_ok)
	testing.expect_value(t, c3.is_rdtscp, u32(1))

	// Record 4: cpuid
	_, k4, p4, m4, ok4 := history_reader_next(&reader)
	testing.expect(t, ok4 && m4)
	testing.expect_value(t, k4, History_Record_Kind.Processor_Identification)
	cp4, cp4_ok := cpuid_from_payload(p4)
	testing.expect(t, cp4_ok)
	testing.expect_value(t, cp4.ecx, u32(0x33))

	// Record 5: Kernel_Completion with copied bytes
	_, k5, p5, m5, ok5 := history_reader_next(&reader)
	testing.expect(t, ok5 && m5)
	testing.expect_value(t, k5, History_Record_Kind.Kernel_Completion)
	kc5, bytes5, kc5_ok := kernel_completion_from_payload(p5)
	testing.expect(t, kc5_ok)
	testing.expect_value(t, kc5.return_time_milliseconds, u64(777))
	testing.expect_value(t, len(bytes5), len(copied))
	for b, i in copied {
		testing.expect_value(t, bytes5[i], b)
	}

	// Record 6: History_End
	_, k6, p6, m6, ok6 := history_reader_next(&reader)
	testing.expect(t, ok6 && m6)
	testing.expect_value(t, k6, History_Record_Kind.History_End)
	_, reason6, div6, end6_ok := history_end_from_payload(p6)
	testing.expect(t, end6_ok)
	testing.expect_value(t, reason6, History_End_Reason.Normal_Stop)
	testing.expect_value(t, div6, Divergence_Kind.None)

	// Clean EOF.
	_, _, _, m7, ok7 := history_reader_next(&reader)
	testing.expect(t, ok7 && !m7)
}
