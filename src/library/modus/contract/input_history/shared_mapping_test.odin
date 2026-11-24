#+build !freestanding
package input_history

import "core:testing"
import "modus:contract/call_outcome"
import op "modus:contract/operation"

// page_delta_capture is what the kernel does at an input point: it encodes
// what changed from the baseline to the live page, then the baseline takes the
// live page, so the next capture gives only the later changes. On a
// refusal the baseline stays, so no change is dropped.
page_delta_capture :: proc(virtual_address: u64, baseline: ^[HISTORY_PAGE_SIZE]u8, live: ^[HISTORY_PAGE_SIZE]u8, destination: []u8) -> (written: int, changed: bool, ok: bool) {
	written, changed, ok = page_delta_encode(virtual_address, baseline, live, destination)
	if ok && changed {
		copy(baseline[:], live[:])
	}
	return written, changed, ok
}

// bytes_of gives the bytes of a fixed-layout value.
bytes_of :: proc(value: ^$T) -> []u8 {
	return ([^]u8)(value)[:size_of(T)]
}

// The border of a Shared_Mapping payload: each field at and past its edge.
@(test)
shared_mapping_border_refuses_each_bad_field :: proc(t: ^testing.T) {
	good := Shared_Mapping_Payload{virtual_address = 0x10_0000, page_count = 2, access = u32(Shared_Mapping_Access.Read_Write)}
	bytes := transmute([size_of(Shared_Mapping_Payload)]u8)good
	entry, access, ok := shared_mapping_validate(bytes[:])
	testing.expect(t, ok)
	testing.expect_value(t, access, Shared_Mapping_Access.Read_Write)
	testing.expect_value(t, entry.page_count, u64(2))

	// The exact size only.
	_, _, ok = shared_mapping_validate(bytes[:size_of(Shared_Mapping_Payload) - 1])
	testing.expect(t, !ok)
	longer: [size_of(Shared_Mapping_Payload) + 1]u8
	copy(longer[:], bytes[:])
	_, _, ok = shared_mapping_validate(longer[:])
	testing.expect(t, !ok)
	_, _, ok = shared_mapping_validate(nil)
	testing.expect(t, !ok)

	refused :: proc(t: ^testing.T, entry: Shared_Mapping_Payload) {
		bytes := transmute([size_of(Shared_Mapping_Payload)]u8)entry
		_, _, ok := shared_mapping_validate(bytes[:])
		testing.expect(t, !ok)
		testing.expect(t, !payload_valid(.Shared_Mapping, bytes[:]))
	}
	accepted :: proc(t: ^testing.T, entry: Shared_Mapping_Payload) {
		bytes := transmute([size_of(Shared_Mapping_Payload)]u8)entry
		_, _, ok := shared_mapping_validate(bytes[:])
		testing.expect(t, ok)
	}
	for word in ([?]u32{u32(Shared_Mapping_Access.None), u32(max(Shared_Mapping_Access)) + 1, 255, max(u32)}) {
		bad := good
		bad.access = word
		refused(t, bad)
	}
	for reserved in ([?]u32{1, 0x8000_0000, max(u32)}) {
		bad := good
		bad.reserved = reserved
		refused(t, bad)
	}
	for count in ([?]u64{0, SHARED_MAPPING_PAGE_LIMIT + 1, max(u64)}) {
		bad := good
		bad.page_count = count
		refused(t, bad)
	}
	for address in ([?]u64{0, 0x10_0001, 0x10_0FFF, op.USER_END, op.USER_END + HISTORY_PAGE_SIZE, max(u64) &~ (HISTORY_PAGE_SIZE - 1)}) {
		bad := good
		bad.virtual_address = address
		refused(t, bad)
	}
	// A range that ends past USER_END, by one page.
	crossing := good
	crossing.virtual_address = op.USER_END - HISTORY_PAGE_SIZE
	refused(t, crossing)

	// The edges that are inside: the last two pages below USER_END, the most pages.
	last := good
	last.virtual_address = op.USER_END - 2 * HISTORY_PAGE_SIZE
	accepted(t, last)
	most := good
	most.page_count = SHARED_MAPPING_PAGE_LIMIT
	accepted(t, most)
	read_only := good
	read_only.access = u32(Shared_Mapping_Access.Read)
	accepted(t, read_only)

	for access_value in Shared_Mapping_Access {
		parsed, parsed_ok := shared_mapping_access_of_word(u64(access_value))
		testing.expect(t, parsed_ok)
		testing.expect_value(t, parsed, access_value)
	}
	for bad in ([?]u64{u64(max(Shared_Mapping_Access)) + 1, u64(max(u32)), max(u64)}) {
		_, parsed_ok := shared_mapping_access_of_word(bad)
		testing.expect(t, !parsed_ok)
	}
}

// The set of stand-in mappings: overlaps on each side, a range inside
// another, the full set, the bound of the pages, and the find of each edge.
@(test)
stand_in_mapping_set_refuses_overlaps_and_bounds :: proc(t: ^testing.T) {
	set: Stand_In_Mapping_Set
	base := u64(0x20_0000)
	page := HISTORY_PAGE_SIZE
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = base, page_count = 4}, .Read_Write, 7))
	before := set

	// The same start, one page in from below, one page in from above, a
	// range inside, a range that holds it.
	for entry in ([?]Shared_Mapping_Payload {
			{virtual_address = base, page_count = 1},
			{virtual_address = base - page, page_count = 2},
			{virtual_address = base + 3 * page, page_count = 2},
			{virtual_address = base + page, page_count = 1},
			{virtual_address = base - page, page_count = 6},
		}) {
		testing.expect(t, !stand_in_mapping_set_add(&set, entry, .Read, 1))
	}
	testing.expect(t, set == before)
	// An access None is refused, and so are zero pages and too many.
	testing.expect(t, !stand_in_mapping_set_add(&set, {virtual_address = base + 8 * page, page_count = 1}, .None, 1))
	testing.expect(t, !stand_in_mapping_set_add(&set, {virtual_address = base + 8 * page, page_count = 0}, .Read, 1))
	testing.expect(t, !stand_in_mapping_set_add(&set, {virtual_address = base + 8 * page, page_count = SHARED_MAPPING_PAGE_LIMIT + 1}, .Read, 1))
	testing.expect(t, !stand_in_mapping_set_add(&set, {virtual_address = op.USER_END - page, page_count = 2}, .Read, 1))
	testing.expect(t, !stand_in_mapping_set_add(nil, {virtual_address = base, page_count = 1}, .Read, 1))
	testing.expect(t, set == before)

	// Adjacent ranges on both sides are accepted.
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = base - page, page_count = 1}, .Read, 8))
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = base + 4 * page, page_count = 1}, .Read, 9))
	testing.expect_value(t, set.page_count, u64(6))

	// The find: the first page, the last page, one past the end, one before.
	found, index, ok := stand_in_mapping_set_find(&set, base)
	testing.expect(t, ok)
	testing.expect_value(t, found.place, u32(7))
	testing.expect_value(t, index, u64(0))
	found, index, ok = stand_in_mapping_set_find(&set, base + 3 * page)
	testing.expect(t, ok && found.place == 7 && index == 3)
	found, index, ok = stand_in_mapping_set_find(&set, base + 4 * page)
	testing.expect(t, ok && found.place == 9 && index == 0)
	_, _, ok = stand_in_mapping_set_find(&set, base + 5 * page)
	testing.expect(t, !ok)
	_, _, ok = stand_in_mapping_set_find(&set, base - 2 * page)
	testing.expect(t, !ok)
	_, _, ok = stand_in_mapping_set_find(nil, base)
	testing.expect(t, !ok)

	// The bound of the pages: 6 + 64 + 26 = 96, then one more page is refused.
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = 0x100_0000, page_count = SHARED_MAPPING_PAGE_LIMIT}, .Read_Write, 10))
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = 0x200_0000, page_count = STAND_IN_PAGE_LIMIT - 6 - SHARED_MAPPING_PAGE_LIMIT}, .Read_Write, 11))
	testing.expect_value(t, set.page_count, STAND_IN_PAGE_LIMIT)
	testing.expect(t, !stand_in_mapping_set_add(&set, {virtual_address = 0x300_0000, page_count = 1}, .Read, 12))

	// The full set: STAND_IN_MAPPING_CAPACITY one-page ranges, then one more.
	full: Stand_In_Mapping_Set
	for slot in 0 ..< STAND_IN_MAPPING_CAPACITY {
		testing.expect(t, stand_in_mapping_set_add(&full, {virtual_address = 0x40_0000 + u64(slot) * 2 * page, page_count = 1}, .Read, u32(slot)))
	}
	testing.expect(t, !stand_in_mapping_set_add(&full, {virtual_address = 0x80_0000, page_count = 1}, .Read, 99))
	testing.expect_value(t, full.count, STAND_IN_MAPPING_CAPACITY)
}

// A capture gives the changes since the last capture only, on each page of
// a shared mapping; a refusal leaves the baseline as it was.
@(test)
page_delta_capture_on_several_pages :: proc(t: ^testing.T) {
	base := u64(0x30_0000)
	live := new([2][HISTORY_PAGE_SIZE]u8)
	defer free(live)
	baseline := new([2][HISTORY_PAGE_SIZE]u8)
	defer free(baseline)
	replayed := new([2][HISTORY_PAGE_SIZE]u8)
	defer free(replayed)
	scratch: [PAGE_DELTA_MAX_BYTES]u8

	capture_and_apply :: proc(t: ^testing.T, base: u64, live, baseline, replayed: ^[2][HISTORY_PAGE_SIZE]u8, scratch: []u8) -> (changed_pages: int) {
		for page in 0 ..< 2 {
			written, changed, ok := page_delta_capture(base + u64(page) * HISTORY_PAGE_SIZE, &baseline[page], &live[page], scratch)
			testing.expect(t, ok)
			if changed {
				changed_pages += 1
				testing.expect(t, page_delta_apply(scratch[:written], &replayed[page]))
			}
			testing.expect(t, baseline[page] == live[page])
		}
		return changed_pages
	}

	// The two edges of each page, and a run that ends at the last byte.
	live[0][0] = 1
	live[0][4095] = 2
	live[1][0] = 3
	live[1][4000] = 4
	for index in 4090 ..< 4096 {
		live[1][index] = u8(index)
	}
	testing.expect_value(t, capture_and_apply(t, base, live, baseline, replayed, scratch[:]), 2)
	testing.expect(t, replayed^ == live^)

	// No change: no delta.
	testing.expect_value(t, capture_and_apply(t, base, live, baseline, replayed, scratch[:]), 0)

	// A write over bytes that an earlier delta wrote: the later delta holds
	// only the bytes that differ from the baseline, and the replay ends equal.
	live[1][4092] = 0xEE
	testing.expect_value(t, capture_and_apply(t, base, live, baseline, replayed, scratch[:]), 1)
	testing.expect(t, replayed^ == live^)

	// Every other byte of a page: one full-page range, never more.
	for index in 0 ..< int(HISTORY_PAGE_SIZE) {
		if index % 2 == 0 {
			live[0][index] = 0xAA
		}
	}
	written, changed, ok := page_delta_capture(base, &baseline[0], &live[0], scratch[:])
	testing.expect(t, ok && changed)
	testing.expect(t, written <= PAGE_DELTA_MAX_BYTES)
	testing.expect(t, page_delta_apply(scratch[:written], &replayed[0]))
	testing.expect(t, replayed[0] == live[0])

	// A refusal leaves the baseline: a bad address, a destination too small.
	live[1][7] = 0x77
	kept := baseline[1]
	_, _, ok = page_delta_capture(base + 1, &baseline[1], &live[1], scratch[:])
	testing.expect(t, !ok)
	testing.expect(t, baseline[1] == kept)
	_, _, ok = page_delta_capture(op.USER_END, &baseline[1], &live[1], scratch[:])
	testing.expect(t, !ok)
	testing.expect(t, baseline[1] == kept)
	_, changed, ok = page_delta_capture(base + HISTORY_PAGE_SIZE, &baseline[1], &live[1], scratch[:size_of(Page_Delta_Header) + size_of(Page_Delta_Range)])
	testing.expect(t, !ok && changed)
	testing.expect(t, baseline[1] == kept)
}

// A delta whose ranges overlap, run out of order, or leave the page is
// refused whole: the page stays as it was.
@(test)
page_delta_refuses_overlapping_and_out_of_range :: proc(t: ^testing.T) {
	build :: proc(buffer: []u8, ranges: []Page_Delta_Range) -> int {
		header := Page_Delta_Header{virtual_address = 0x40_0000, range_count = u32(len(ranges))}
		header_value := header
		copy(buffer, bytes_of(&header_value))
		cursor := size_of(Page_Delta_Header)
		for entry in ranges {
			entry_value := entry
			copy(buffer[cursor:], bytes_of(&entry_value))
			cursor += size_of(Page_Delta_Range)
			length := min(int(entry.length), int(HISTORY_PAGE_SIZE))
			for index in 0 ..< length {
				buffer[cursor + index] = 0xC3
			}
			cursor += length
		}
		return cursor
	}
	buffer := make([]u8, 4 * PAGE_DELTA_MAX_BYTES)
	defer delete(buffer)
	page: [HISTORY_PAGE_SIZE]u8
	cases := [?][]Page_Delta_Range {
		{{offset = 10, length = 10}, {offset = 15, length = 2}}, // Overlap.
		{{offset = 10, length = 10}, {offset = 19, length = 1}}, // Overlap by the last byte.
		{{offset = 20, length = 1}, {offset = 10, length = 1}}, // Out of order.
		{{offset = 10, length = 1}, {offset = 10, length = 1}}, // The same range twice.
		{{offset = 4096, length = 1}}, // Offset past the page.
		{{offset = 4095, length = 2}}, // One byte past the page.
		{{offset = 0, length = 4097}}, // Longer than a page.
		{{offset = 0xFFFF, length = 1}}, // The largest offset.
		{{offset = 4000, length = 0}}, // An empty range.
	}
	for ranges in cases {
		written := build(buffer, ranges)
		_, ok := page_delta_validate(buffer[:written])
		testing.expect(t, !ok)
		testing.expect(t, !page_delta_apply(buffer[:written], &page))
		testing.expect(t, page == [HISTORY_PAGE_SIZE]u8{})
	}
	// Adjacent ranges and the last byte of the page are accepted.
	written := build(buffer, {{offset = 10, length = 10}, {offset = 20, length = 1}, {offset = 4095, length = 1}})
	testing.expect(t, page_delta_apply(buffer[:written], &page))
	testing.expect_value(t, page[4095], u8(0xC3))
}

// The reader refuses a record whose input point does not grow, and a
// damaged Shared_Mapping record; the point of the next record is known.
@(test)
reader_refuses_points_that_do_not_grow_and_damaged_mappings :: proc(t: ^testing.T) {
	buffer: [4096]u8
	writer, ok := history_writer_init(buffer[:], {}, 1, 0, 3)
	testing.expect(t, ok)
	mapping := Shared_Mapping_Payload{virtual_address = 0x10_0000, page_count = 1, access = u32(Shared_Mapping_Access.Read_Write)}
	testing.expect(t, history_writer_append(&writer, .Shared_Mapping, 0, 0, bytes_of(&mapping)))
	testing.expect(t, history_writer_append_cycle_counter(&writer, 0x40_1000, 0x7000, {cycles = 5}))
	testing.expect(t, history_writer_append_cycle_counter(&writer, 0x40_1000, 0x7000, {cycles = 6}))
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)

	// Unchanged: three records with points 1, 2, 3.
	reader, opened := history_reader_open(buffer[:])
	testing.expect(t, opened)
	for expected_point in u64(1) ..= 3 {
		testing.expect_value(t, history_reader_next_point(&reader), expected_point)
		record_header, _, _, has_more, read_ok := history_reader_next_into(&reader, scratch)
		testing.expect(t, read_ok && has_more)
		testing.expect_value(t, record_header.point_number, expected_point)
	}

	// The second record starts after the first: its header and 24 bytes.
	second := size_of(History_Header) + size_of(History_Record_Header) + int(align_up_record(size_of(Shared_Mapping_Payload)))
	for point in ([?]u64{0, 1}) {
		damaged := buffer
		(^History_Record_Header)(&damaged[second])^.point_number = point
		damaged_reader, _ := history_reader_open(damaged[:])
		_, _, _, has_more, read_ok := history_reader_next_into(&damaged_reader, scratch)
		testing.expect(t, read_ok && has_more)
		before := damaged_reader.read_offset
		_, _, _, has_more, read_ok = history_reader_next_into(&damaged_reader, scratch)
		testing.expect(t, !read_ok && !has_more)
		testing.expect_value(t, damaged_reader.read_offset, before)
		testing.expect_value(t, history_reader_next_point(&damaged_reader), u64(2))
		_, _, _, _, peek_ok := history_reader_next(&damaged_reader)
		testing.expect(t, !peek_ok)
	}

	// A damaged Shared_Mapping record: an access None, an access past the
	// enum, a reserved word, an unaligned address, no pages.
	payload_offset := size_of(History_Header) + size_of(History_Record_Header)
	for edit in ([?]proc(entry: ^Shared_Mapping_Payload) {
			proc(entry: ^Shared_Mapping_Payload) {entry.access = 0},
			proc(entry: ^Shared_Mapping_Payload) {entry.access = 3},
			proc(entry: ^Shared_Mapping_Payload) {entry.reserved = 1},
			proc(entry: ^Shared_Mapping_Payload) {entry.virtual_address += 8},
			proc(entry: ^Shared_Mapping_Payload) {entry.page_count = 0},
		}) {
		damaged := buffer
		edit((^Shared_Mapping_Payload)(&damaged[payload_offset]))
		damaged_reader, _ := history_reader_open(damaged[:])
		_, _, _, has_more, read_ok := history_reader_next_into(&damaged_reader, scratch)
		testing.expect(t, !read_ok && !has_more)
		testing.expect_value(t, damaged_reader.read_offset, u64(0))
	}
}

// The end check: only a History_End with Normal_Stop after the last entry
// agrees with a stop of the replayed process by its own instructions.
@(test)
replay_end_check_refuses_each_other_end :: proc(t: ^testing.T) {
	end_of :: proc(reason: History_End_Reason, kind: Divergence_Kind = .None, expected: u64 = 0, actual: u64 = 0) -> [size_of(History_End_Payload)]u8 {
		payload := History_End_Payload{reason = u32(reason), divergence_kind = u32(kind), expected_value = expected, actual_value = actual}
		return transmute([size_of(History_End_Payload)]u8)payload
	}
	normal := end_of(.Normal_Stop)
	testing.expect_value(t, replay_end_check(true, .History_End, normal[:]).divergence, Divergence_Kind.None)

	for reason in ([?]History_End_Reason{.Recorder_Stopped, .Stint_Bound_Reached, .Revocation, .Buffer_Full}) {
		payload := end_of(reason)
		result := replay_end_check(true, .History_End, payload[:])
		testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_End)
		testing.expect_value(t, result.expected, u64(reason))
		testing.expect_value(t, result.actual, u64(History_End_Reason.Normal_Stop))
	}
	diverged := end_of(.Divergence, .Unexpected_Arguments, 1, 2)
	testing.expect_value(t, replay_end_check(true, .History_End, diverged[:]).divergence, Divergence_Kind.Unexpected_End)

	// The history goes on: each kind of record.
	for kind in ([?]History_Record_Kind{.Kernel_Completion, .Cycle_Counter, .Processor_Identification, .Page_Delta, .Shared_Mapping}) {
		result := replay_end_check(true, kind, nil)
		testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_End)
		testing.expect_value(t, result.expected, u64(kind))
		testing.expect_value(t, result.actual, u64(History_Record_Kind.History_End))
	}
	// No record, a record of kind None, a damaged end.
	testing.expect_value(t, replay_end_check(false, .None, nil).divergence, Divergence_Kind.Unexpected_End)
	testing.expect_value(t, replay_end_check(true, .None, nil).divergence, Divergence_Kind.Unexpected_End)
	damaged := end_of(.None)
	testing.expect_value(t, replay_end_check(true, .History_End, damaged[:]).divergence, Divergence_Kind.Unexpected_End)
	testing.expect_value(t, replay_end_check(true, .History_End, normal[:4]).divergence, Divergence_Kind.Unexpected_End)
}

// The simulated program of the tests below: three rounds, each with a
// kernel entry where a peer writes two shared pages, a kernel entry that
// carries the checksum of the bytes as an argument, a read of the cycle
// counter and a cpuid. A replay runs the same rounds from the history,
// with private stand-in pages and no peer.

SIMULATED_SHARED_BASE :: u64(0x50_0000)
SIMULATED_ROUNDS :: 3
SIMULATED_WAIT_ADDRESS :: u64(0x40_1000)
SIMULATED_CHECKSUM_ADDRESS :: u64(0x40_1100)
SIMULATED_CYCLES_ADDRESS :: u64(0x40_1200)
SIMULATED_CPUID_ADDRESS :: u64(0x40_1300)
SIMULATED_STACK :: u64(0x7FFF_F000)
SIMULATED_WAKE :: u32(op.Operation.Word_Wake)
SIMULATED_WAIT :: u32(op.Operation.Word_Wait)

// How a replayed program differs from the recorded one.
Simulated_Variant :: enum {
	Same,
	Other_Operation, // Round 2 enters with Word_Wait in place of Word_Wake.
	Other_Cycles_Address, // Round 2 reads the cycle counter at another instruction.
	Other_Cpuid_Leaf, // Round 2 asks another leaf of cpuid.
	Stops_Early, // The program stops after round 2.
}

Simulated_Session :: struct {
	replaying:  bool,
	variant:    Simulated_Variant,
	pages:      [2][HISTORY_PAGE_SIZE]u8, // The live pages in the record, the stand-in pages in the replay.
	baseline:   [2][HISTORY_PAGE_SIZE]u8, // The record: the pages at the last capture.
	writer:     History_Writer,
	reader:     History_Reader,
	stand_ins:  Stand_In_Mapping_Set,
	scratch:    [MAX_RECORD_PAYLOAD_BYTES]u8,
	divergence: Replay_Check_Result,
	point:      u64, // The input point of the divergence.
	checksum:   u64,
}

// simulated_peer_write is the shared writer of the record: what it writes
// before the entry of a round. The replay never runs it.
simulated_peer_write :: proc(session: ^Simulated_Session, round: int) {
	for index in 0 ..< 8 {
		session.pages[0][16 * round + index] = u8(round * 7 + index)
	}
	// The same bytes each round: deltas that overlap earlier ones.
	for index in 100 ..< 104 {
		session.pages[0][index] = u8(round)
	}
	// The last bytes of the second page.
	for index in 4090 ..< 4096 {
		session.pages[1][index] = u8(0xA0 + round)
	}
	if round == 2 {
		session.pages[1][0] = 0x55
	}
}

// simulated_capture writes a Page_Delta of each page that changed since the
// last capture, at an input point of the record.
simulated_capture :: proc(t: ^testing.T, session: ^Simulated_Session, instruction_address: u64) {
	delta: [PAGE_DELTA_MAX_BYTES]u8
	for page in 0 ..< 2 {
		written, changed, ok := page_delta_capture(SIMULATED_SHARED_BASE + u64(page) * HISTORY_PAGE_SIZE, &session.baseline[page], &session.pages[page], delta[:])
		testing.expect(t, ok)
		if changed {
			testing.expect(t, history_writer_append(&session.writer, .Page_Delta, instruction_address, SIMULATED_STACK, delta[:written]))
		}
	}
}

// simulated_apply_deltas applies each Page_Delta that comes next in the
// history to the stand-in pages. false: a delta outside the stand-in mappings, or a
// damaged record; the session holds the divergence.
simulated_apply_deltas :: proc(session: ^Simulated_Session) -> bool {
	for {
		record_header, kind, payload, stride, has_more, ok := history_reader_peek_into(&session.reader, session.scratch[:])
		if !ok {
			session.divergence = {.Missing_Record, 0, 0}
			session.point = history_reader_next_point(&session.reader)
			return false
		}
		if !has_more || kind != .Page_Delta {
			return true
		}
		delta_header, _ := page_delta_validate(payload)
		stand_in, page, found := stand_in_mapping_set_find(&session.stand_ins, delta_header.virtual_address)
		if !found || !page_delta_apply(payload, &session.pages[page + u64(stand_in.place)]) {
			session.divergence = {.Missing_Record, 0, 0}
			session.point = record_header.point_number
			return false
		}
		history_reader_advance(&session.reader, record_header, stride)
	}
}

// simulated_event is one input point of the program: the record writes it,
// the replay checks it and gives the recorded value.
simulated_event :: proc(t: ^testing.T, session: ^Simulated_Session, actual: Replay_Actual_Event, recorded_value: u64) -> (value: u64, go_on: bool) {
	if !session.replaying {
		switch actual.kind {
		case .Kernel_Completion:
			entry := Kernel_Completion_Payload{command_kind = actual.command_kind, command_values = actual.command_values, completion_status = u32(call_outcome.Call_Outcome.Succeeded)}
			testing.expect(t, history_writer_append_kernel_completion(&session.writer, actual.instruction_address, actual.stack_pointer, entry, nil))
		case .Cycle_Counter:
			testing.expect(t, history_writer_append_cycle_counter(&session.writer, actual.instruction_address, actual.stack_pointer, {cycles = recorded_value}))
		case .Processor_Identification:
			testing.expect(t, history_writer_append_cpuid(&session.writer, actual.instruction_address, actual.stack_pointer, {leaf = actual.cpuid_leaf, eax = u32(recorded_value)}))
		case .None, .Page_Delta, .History_End, .Shared_Mapping:
			testing.fail(t)
		}
		return recorded_value, true
	}
	if !simulated_apply_deltas(session) {
		return 0, false
	}
	record_header, kind, payload, has_more, ok := history_reader_next_into(&session.reader, session.scratch[:])
	check := replay_step_check(actual, ok && has_more, record_header, kind, payload)
	if check.divergence != .None {
		session.divergence = check
		session.point = ok && has_more ? record_header.point_number : history_reader_next_point(&session.reader)
		return 0, false
	}
	value = 0
	switch kind {
	case .Cycle_Counter:
		entry, _ := cycle_counter_from_payload(payload)
		value = entry.cycles
	case .Processor_Identification:
		entry, _ := cpuid_from_payload(payload)
		value = u64(entry.eax)
	case .Kernel_Completion, .None, .Page_Delta, .History_End, .Shared_Mapping:
	}
	// The deltas after the entry: what the writers wrote while the thread
	// waited there.
	if !simulated_apply_deltas(session) {
		return 0, false
	}
	return value, true
}

// simulated_program runs the rounds. In the record the peer writes and the
// counters are real values; in the replay each value comes from the history.
simulated_program :: proc(t: ^testing.T, session: ^Simulated_Session) {
	checksum := u64(0x9E37_79B9_7F4A_7C15)
	go_on: bool
	for round in 1 ..= SIMULATED_ROUNDS {
		if session.replaying && session.variant == .Stops_Early && round == SIMULATED_ROUNDS {
			break
		}
		// The wait of the round: the peer writes while the thread is at
		// this input point, and the record captures its writes there.
		wait := Replay_Actual_Event{kind = .Kernel_Completion, instruction_address = SIMULATED_WAIT_ADDRESS, stack_pointer = SIMULATED_STACK, command_kind = SIMULATED_WAIT, command_values = {0 = 0x60_0000, 1 = 1}}
		if _, go_on = simulated_event(t, session, wait, 0); !go_on {
			return
		}
		if !session.replaying {
			simulated_peer_write(session, round)
			simulated_capture(t, session, SIMULATED_WAIT_ADDRESS)
		}
		for page in session.pages {
			for byte_value, index in page {
				checksum = (checksum ~ u64(byte_value) * u64(index + 1)) * 0x1000_0000_01B3
			}
		}
		operation := SIMULATED_WAKE
		if session.replaying && session.variant == .Other_Operation && round == 2 {
			operation = SIMULATED_WAIT
		}
		// The checksum is an argument of an entry: a replay that read other
		// bytes diverges at this point.
		carrier := Replay_Actual_Event{kind = .Kernel_Completion, instruction_address = SIMULATED_CHECKSUM_ADDRESS, stack_pointer = SIMULATED_STACK, command_kind = operation, command_values = {0 = 0x60_0008, 1 = checksum}}
		if _, go_on = simulated_event(t, session, carrier, 0); !go_on {
			return
		}
		cycles_address := SIMULATED_CYCLES_ADDRESS
		if session.replaying && session.variant == .Other_Cycles_Address && round == 2 {
			cycles_address += 2
		}
		cycles: u64
		cycles, go_on = simulated_event(t, session, {kind = .Cycle_Counter, instruction_address = cycles_address, stack_pointer = SIMULATED_STACK}, 1_000_000 * u64(round) + 17)
		if !go_on {
			return
		}
		checksum = (checksum ~ cycles) * 0x1000_0000_01B3
		leaf := u32(1)
		if session.replaying && session.variant == .Other_Cpuid_Leaf && round == 2 {
			leaf = 7
		}
		answer: u64
		answer, go_on = simulated_event(t, session, {kind = .Processor_Identification, instruction_address = SIMULATED_CPUID_ADDRESS, stack_pointer = SIMULATED_STACK, cpuid_leaf = leaf}, 0x000A_0655 + u64(round))
		if !go_on {
			return
		}
		checksum = (checksum ~ answer) * 0x1000_0000_01B3
	}
	session.checksum = checksum
	if !session.replaying {
		testing.expect(t, history_writer_append_end(&session.writer, 0, 0, .Normal_Stop))
		return
	}
	// The stop of the program: the history must end here too.
	if !simulated_apply_deltas(session) {
		return
	}
	record_header, kind, payload, has_more, ok := history_reader_next_into(&session.reader, session.scratch[:])
	check := replay_end_check(ok && has_more, kind, payload)
	if check.divergence != .None {
		session.divergence = check
		session.point = ok && has_more ? record_header.point_number : history_reader_next_point(&session.reader)
	}
}

// simulated_record records the program with its peer into buffer.
simulated_record :: proc(t: ^testing.T, buffer: []u8) -> (checksum: u64) {
	session := new(Simulated_Session)
	defer free(session)
	ok: bool
	session.writer, ok = history_writer_init(buffer, {}, 1_000_000_000, 0, 3)
	testing.expect(t, ok)
	// The head: the shared mapping, then the first bytes of its pages.
	mapping := Shared_Mapping_Payload{virtual_address = SIMULATED_SHARED_BASE, page_count = 2, access = u32(Shared_Mapping_Access.Read_Write)}
	testing.expect(t, history_writer_append(&session.writer, .Shared_Mapping, 0, 0, bytes_of(&mapping)))
	session.pages[0][0], session.pages[0][1], session.pages[1][2] = 1, 2, 3
	simulated_capture(t, session, 0)
	simulated_program(t, session)
	return session.checksum
}

// simulated_replay replays buffer: the head makes the stand-in pages, then
// the program runs with no peer.
simulated_replay :: proc(t: ^testing.T, buffer: []u8, variant: Simulated_Variant) -> (result: Replay_Check_Result, point: u64, checksum: u64) {
	session := new(Simulated_Session)
	defer free(session)
	session.replaying = true
	session.variant = variant
	opened: bool
	session.reader, opened = history_reader_open(buffer)
	if !opened {
		return {.Missing_Record, 0, 0}, 0, 0
	}
	// The head: each Shared_Mapping makes a stand-in mapping (its place is the index
	// of its first page here), then the program applies the first deltas.
	for {
		record_header, kind, payload, stride, has_more, ok := history_reader_peek_into(&session.reader, session.scratch[:])
		if !ok {
			return {.Missing_Record, 0, 0}, history_reader_next_point(&session.reader), 0
		}
		if !has_more || kind != .Shared_Mapping {
			break
		}
		entry, access, _ := shared_mapping_validate(payload)
		place := u32(session.stand_ins.page_count)
		if !stand_in_mapping_set_add(&session.stand_ins, entry, access, place) || session.stand_ins.page_count > 2 {
			return {.Missing_Record, 0, 0}, record_header.point_number, 0
		}
		history_reader_advance(&session.reader, record_header, stride)
	}
	simulated_program(t, session)
	return session.divergence, session.point, session.checksum
}

// The record and the replay of the same program agree: no divergence, the
// same checksum, though the replay has no peer and zero pages at its start.
@(test)
simulated_replay_with_no_peer_has_no_divergence :: proc(t: ^testing.T) {
	buffer := make([]u8, 65536)
	defer delete(buffer)
	recorded := simulated_record(t, buffer)
	testing.expect(t, recorded != 0)
	for _ in 0 ..< 3 {
		result, point, replayed := simulated_replay(t, buffer, .Same)
		testing.expect_value(t, result.divergence, Divergence_Kind.None)
		testing.expect_value(t, point, u64(0))
		testing.expect_value(t, replayed, recorded)
	}
	// The record holds the deltas of both pages, the overlapping writes of
	// each round, and an end with Normal_Stop.
	reader, _ := history_reader_open(buffer)
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	deltas, mappings: int
	pages_seen: [2]bool
	last_kind: History_Record_Kind
	for {
		_, kind, payload, has_more, ok := history_reader_next_into(&reader, scratch)
		testing.expect(t, ok)
		if !has_more {
			break
		}
		last_kind = kind
		if kind == .Shared_Mapping {
			mappings += 1
		}
		if kind == .Page_Delta {
			deltas += 1
			header, _ := page_delta_validate(payload)
			pages_seen[(header.virtual_address - SIMULATED_SHARED_BASE) / HISTORY_PAGE_SIZE] = true
		}
	}
	testing.expect_value(t, mappings, 1)
	testing.expect(t, pages_seen[0] && pages_seen[1])
	testing.expect_value(t, deltas, 2 + 2 * SIMULATED_ROUNDS)
	testing.expect_value(t, last_kind, History_Record_Kind.History_End)
}

// find_record gives the byte offset of the payload of the nth record of a
// kind, and its input point.
find_record :: proc(buffer: []u8, wanted: History_Record_Kind, nth: int) -> (payload_offset: int, point: u64, found: bool) {
	reader, _ := history_reader_open(buffer)
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	seen := 0
	for {
		offset := reader.read_offset
		record_header, kind, _, has_more, ok := history_reader_next_into(&reader, scratch)
		if !ok || !has_more {
			return 0, 0, false
		}
		if kind == wanted {
			seen += 1
			if seen == nth {
				return size_of(History_Header) + int(offset) + size_of(History_Record_Header), record_header.point_number, true
			}
		}
	}
}

// A byte of a shared page changed in the history: the replay reads it, and
// diverges at the first entry that carries the checksum after it.
@(test)
simulated_replay_finds_a_changed_shared_byte :: proc(t: ^testing.T) {
	buffer := make([]u8, 65536)
	defer delete(buffer)
	simulated_record(t, buffer)
	// The deltas: two of the head, then two in each round. The first of
	// round 2 is the fifth.
	offset, delta_point, found := find_record(buffer, .Page_Delta, 5)
	testing.expect(t, found)
	// The first data byte: after the delta header and its first range.
	buffer[offset + size_of(Page_Delta_Header) + size_of(Page_Delta_Range)] ~= 0x01
	// The checksum of round 2 is the fourth kernel completion: the wait and
	// the checksum of each round.
	_, carrier_point, carrier_found := find_record(buffer, .Kernel_Completion, 4)
	testing.expect(t, carrier_found)
	testing.expect(t, carrier_point > delta_point)

	result, point, _ := simulated_replay(t, buffer, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, carrier_point)
	testing.expect(t, result.expected != result.actual)

	// The report from the header names that point and its record.
	testing.expect(t, history_header_record_end(buffer, .Divergence, result.divergence, point, result.expected, result.actual))
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	report, report_found, report_ok := divergence_report_of_history(buffer, scratch)
	testing.expect(t, report_ok && report_found)
	testing.expect_value(t, report.kind, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, report.point, carrier_point)
	testing.expect_value(t, report.expected, result.expected)
	testing.expect_value(t, report.actual, result.actual)
	testing.expect_value(t, report.recorded_kind, History_Record_Kind.Kernel_Completion)
	testing.expect_value(t, report.recorded_instruction_address, SIMULATED_CHECKSUM_ADDRESS)
	testing.expect_value(t, report.recorded_stack_pointer, SIMULATED_STACK)
}

// A changed recorded value of the cycle counter or of cpuid reaches the
// checksum, so the replay diverges at the carrier of the round after it.
@(test)
simulated_replay_finds_changed_counter_values :: proc(t: ^testing.T) {
	for kind in ([?]History_Record_Kind{.Cycle_Counter, .Processor_Identification}) {
		buffer := make([]u8, 65536)
		defer delete(buffer)
		simulated_record(t, buffer)
		offset, _, found := find_record(buffer, kind, 2)
		testing.expect(t, found)
		// The cycles are the first word; the answer eax of cpuid is the
		// third word of its payload.
		if kind == .Cycle_Counter {
			(^u64)(&buffer[offset])^ += 1
		} else {
			(^u32)(&buffer[offset + 8])^ ~= 0x10
		}
		// The checksum of round 3: the sixth kernel completion.
		_, carrier_point, _ := find_record(buffer, .Kernel_Completion, 6)
		result, point, _ := simulated_replay(t, buffer, .Same)
		testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
		testing.expect_value(t, point, carrier_point)
	}
}

// Each other run of the program diverges at its exact first difference,
// with the kind of that difference.
@(test)
simulated_replay_finds_each_kind_of_divergence :: proc(t: ^testing.T) {
	buffer := make([]u8, 65536)
	defer delete(buffer)
	simulated_record(t, buffer)
	_, carrier_point, _ := find_record(buffer, .Kernel_Completion, 4)
	_, cycles_point, _ := find_record(buffer, .Cycle_Counter, 2)
	_, cpuid_point, _ := find_record(buffer, .Processor_Identification, 2)
	_, wait_point, _ := find_record(buffer, .Kernel_Completion, 5)

	result, point, _ := simulated_replay(t, buffer, .Other_Operation)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Operation)
	testing.expect_value(t, point, carrier_point)
	testing.expect_value(t, result.expected, u64(SIMULATED_WAKE))
	testing.expect_value(t, result.actual, u64(SIMULATED_WAIT))

	result, point, _ = simulated_replay(t, buffer, .Other_Cycles_Address)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Instruction)
	testing.expect_value(t, point, cycles_point)
	testing.expect_value(t, result.expected, SIMULATED_CYCLES_ADDRESS)
	testing.expect_value(t, result.actual, SIMULATED_CYCLES_ADDRESS + 2)

	result, point, _ = simulated_replay(t, buffer, .Other_Cpuid_Leaf)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, cpuid_point)
	testing.expect_value(t, result.expected, u64(1))
	testing.expect_value(t, result.actual, u64(7))

	// A program that stops where the history goes on: the end check names
	// the wait of round 3, the next record of the history.
	result, point, _ = simulated_replay(t, buffer, .Stops_Early)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_End)
	testing.expect_value(t, point, wait_point)
	testing.expect_value(t, result.expected, u64(History_Record_Kind.Kernel_Completion))
	testing.expect_value(t, result.actual, u64(History_Record_Kind.History_End))
}

// A history that the replay cannot trust stops it: a delta outside every
// stand-in mapping, a delta with overlapping ranges, a damaged mapping of
// the head, and an end that is not Normal_Stop.
@(test)
simulated_replay_refuses_damaged_histories :: proc(t: ^testing.T) {
	buffer := make([]u8, 65536)
	defer delete(buffer)
	simulated_record(t, buffer)

	// A delta of round 1 moved to a page that no stand-in mapping holds.
	outside := make([]u8, len(buffer))
	defer delete(outside)
	copy(outside, buffer)
	offset, delta_point, _ := find_record(outside, .Page_Delta, 3)
	(^Page_Delta_Header)(&outside[offset])^.virtual_address = SIMULATED_SHARED_BASE + 2 * HISTORY_PAGE_SIZE
	result, point, _ := simulated_replay(t, outside, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Missing_Record)
	testing.expect_value(t, point, delta_point)

	// A delta with overlapping ranges, made in place: its second range
	// starts at the offset of the first.
	overlapping := make([]u8, len(buffer))
	defer delete(overlapping)
	copy(overlapping, buffer)
	offset, delta_point, _ = find_record(overlapping, .Page_Delta, 3)
	header := (^Page_Delta_Header)(&overlapping[offset])^
	testing.expect(t, header.range_count >= 2)
	first := (^Page_Delta_Range)(&overlapping[offset + size_of(Page_Delta_Header)])^
	second_offset := offset + size_of(Page_Delta_Header) + size_of(Page_Delta_Range) + int(first.length)
	(^Page_Delta_Range)(&overlapping[second_offset])^.offset = first.offset
	result, point, _ = simulated_replay(t, overlapping, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Missing_Record)
	testing.expect_value(t, point, delta_point)

	// The shared mapping of the head with an access None.
	damaged_head := make([]u8, len(buffer))
	defer delete(damaged_head)
	copy(damaged_head, buffer)
	mapping_offset, _, _ := find_record(damaged_head, .Shared_Mapping, 1)
	(^Shared_Mapping_Payload)(&damaged_head[mapping_offset])^.access = 0
	result, point, _ = simulated_replay(t, damaged_head, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Missing_Record)
	testing.expect_value(t, point, u64(1))

	// A record that ended for another reason than a stop of the process.
	other_end := make([]u8, len(buffer))
	defer delete(other_end)
	copy(other_end, buffer)
	end_offset, end_point, _ := find_record(other_end, .History_End, 1)
	(^History_End_Payload)(&other_end[end_offset])^.reason = u32(History_End_Reason.Recorder_Stopped)
	result, point, _ = simulated_replay(t, other_end, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_End)
	testing.expect_value(t, point, end_point)
	testing.expect_value(t, result.expected, u64(History_End_Reason.Recorder_Stopped))
}

// The report of a history: none when it did not diverge, none from a
// damaged history, and a point past its last record names no record.
@(test)
divergence_report_of_history_edges :: proc(t: ^testing.T) {
	buffer := make([]u8, 65536)
	defer delete(buffer)
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	simulated_record(t, buffer)

	_, found, ok := divergence_report_of_history(buffer, scratch)
	testing.expect(t, ok && !found)
	_, found, ok = divergence_report_of_history(buffer[:100], scratch)
	testing.expect(t, !ok && !found)

	reader, _ := history_reader_open(buffer)
	past := reader.header.point_count + 5
	testing.expect(t, history_header_record_end(buffer, .Divergence, .Unexpected_End, past, 1, 2))
	report, report_found, report_ok := divergence_report_of_history(buffer, scratch)
	testing.expect(t, report_ok && report_found)
	testing.expect_value(t, report.point, past)
	testing.expect_value(t, report.recorded_kind, History_Record_Kind.None)
	testing.expect_value(t, report.expected, u64(1))
	testing.expect_value(t, report.actual, u64(2))

	// A damaged record before the point refuses the report.
	_, carrier_point, _ := find_record(buffer, .Kernel_Completion, 4)
	testing.expect(t, history_header_record_end(buffer, .Divergence, .Unexpected_Arguments, carrier_point, 1, 2))
	offset, _, _ := find_record(buffer, .Shared_Mapping, 1)
	(^Shared_Mapping_Payload)(&buffer[offset])^.reserved = 1
	_, found, ok = divergence_report_of_history(buffer, scratch)
	testing.expect(t, !ok && !found)
}

// The capacity of the set is one stand-in mapping for each page that the
// kernel keeps for a record: 96 one-page mappings fit, the 97th does not,
// and a removal makes room again. Each entry keeps the serial of its place.
@(test)
stand_in_mapping_set_holds_96_and_removes_by_place :: proc(t: ^testing.T) {
	testing.expect_value(t, STAND_IN_MAPPING_CAPACITY, 96)
	testing.expect_value(t, STAND_IN_PAGE_LIMIT, u64(96))
	set := new(Stand_In_Mapping_Set)
	defer free(set)
	page := HISTORY_PAGE_SIZE
	for slot in 0 ..< STAND_IN_MAPPING_CAPACITY {
		testing.expect(t, stand_in_mapping_set_add(set, {virtual_address = 0x40_0000 + u64(slot) * 2 * page, page_count = 1}, .Read_Write, u32(100 + slot), u64(1000 + slot)))
	}
	testing.expect_value(t, set.count, 96)
	testing.expect_value(t, set.page_count, u64(96))
	before := set^
	testing.expect(t, !stand_in_mapping_set_add(set, {virtual_address = 0x100_0000, page_count = 1}, .Read, 999, 1))
	testing.expect(t, set^ == before)

	found, _, ok := stand_in_mapping_set_find(set, 0x40_0000 + 10 * 2 * page)
	testing.expect(t, ok)
	testing.expect_value(t, found.place, u32(110))
	testing.expect_value(t, found.place_serial, u64(1010))

	// A place that names nothing removes nothing.
	testing.expect_value(t, stand_in_mapping_set_remove(set, 7), 0)
	testing.expect_value(t, stand_in_mapping_set_remove(nil, 110), 0)
	testing.expect(t, set^ == before)
	// The removal of a place: its addresses find nothing, the others stay,
	// and the set takes one more mapping.
	testing.expect_value(t, stand_in_mapping_set_remove(set, 110), 1)
	testing.expect_value(t, set.count, 95)
	testing.expect_value(t, set.page_count, u64(95))
	_, _, ok = stand_in_mapping_set_find(set, 0x40_0000 + 10 * 2 * page)
	testing.expect(t, !ok)
	for slot in 0 ..< STAND_IN_MAPPING_CAPACITY {
		if slot == 10 {
			continue
		}
		found, _, ok = stand_in_mapping_set_find(set, 0x40_0000 + u64(slot) * 2 * page)
		testing.expect(t, ok && found.place == u32(100 + slot) && found.place_serial == u64(1000 + slot))
	}
	testing.expect(t, stand_in_mapping_set_add(set, {virtual_address = 0x100_0000, page_count = 1}, .Read, 999, 1))
	testing.expect_value(t, set.count, 96)

	// Two mappings of one place both leave; the last entry of the set leaves too.
	two := new(Stand_In_Mapping_Set)
	defer free(two)
	testing.expect(t, stand_in_mapping_set_add(two, {virtual_address = 0x40_0000, page_count = 2}, .Read, 5, 1))
	testing.expect(t, stand_in_mapping_set_add(two, {virtual_address = 0x50_0000, page_count = 1}, .Read, 6, 2))
	testing.expect(t, stand_in_mapping_set_add(two, {virtual_address = 0x60_0000, page_count = 3}, .Read, 5, 1))
	testing.expect_value(t, stand_in_mapping_set_remove(two, 5), 2)
	testing.expect_value(t, two.count, 1)
	testing.expect_value(t, two.page_count, u64(1))
	testing.expect_value(t, two.mappings[0].place, u32(6))
	testing.expect_value(t, stand_in_mapping_set_remove(two, 6), 1)
	testing.expect_value(t, two.count, 0)
	testing.expect_value(t, two.page_count, u64(0))
}

// A record with the largest input point is refused: the point after it,
// which a reader names at a damaged record, would wrap to 0. The point
// below it is accepted.
@(test)
reader_refuses_the_largest_point :: proc(t: ^testing.T) {
	buffer: [4096]u8
	writer, ok := history_writer_init(buffer[:], {}, 1, 0, 3)
	testing.expect(t, ok)
	testing.expect(t, history_writer_append_cycle_counter(&writer, 0x40_1000, 0x7000, {cycles = 5}))
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	first := size_of(History_Header)

	for point, accepted in ([?]u64{max(u64) - 1, max(u64)}) {
		edited := buffer
		(^History_Record_Header)(&edited[first])^.point_number = point
		reader, opened := history_reader_open(edited[:])
		testing.expect(t, opened)
		record_header, _, _, has_more, read_ok := history_reader_next_into(&reader, scratch)
		if accepted == 0 {
			testing.expect(t, read_ok && has_more)
			testing.expect_value(t, record_header.point_number, max(u64) - 1)
			testing.expect_value(t, history_reader_next_point(&reader), max(u64))
		} else {
			testing.expect(t, !read_ok && !has_more)
			testing.expect_value(t, reader.read_offset, u64(0))
			testing.expect_value(t, history_reader_next_point(&reader), u64(1))
			plain, plain_opened := history_reader_open(edited[:])
			testing.expect(t, plain_opened)
			_, _, _, _, plain_ok := history_reader_next(&plain)
			testing.expect(t, !plain_ok)
		}
	}
}

// A replay that stopped at a damaged record (Missing_Record at the point of
// that record) keeps the report of its header: the point, the kind and the
// values, with no record named. A record past the point that is damaged
// changes nothing either.
@(test)
divergence_report_at_a_damaged_record_keeps_the_header :: proc(t: ^testing.T) {
	buffer := make([]u8, 65536)
	defer delete(buffer)
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	simulated_record(t, buffer)
	// A delta of round 2 with a reserved word: the replay stops there.
	offset, delta_point, _ := find_record(buffer, .Page_Delta, 5)
	(^Page_Delta_Header)(&buffer[offset])^.reserved = 1
	result, point, _ := simulated_replay(t, buffer, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Missing_Record)
	testing.expect_value(t, point, delta_point)
	testing.expect(t, history_header_record_end(buffer, .Divergence, result.divergence, point, 0, 0))

	report, found, ok := divergence_report_of_history(buffer, scratch)
	testing.expect(t, ok && found)
	testing.expect_value(t, report.kind, Divergence_Kind.Missing_Record)
	testing.expect_value(t, report.point, delta_point)
	testing.expect_value(t, report.recorded_kind, History_Record_Kind.None)
	testing.expect_value(t, report.recorded_instruction_address, u64(0))

	// A divergence at an earlier point, before the damaged record: its
	// record is read, as the damage comes after it.
	_, carrier_point, _ := find_record(buffer, .Kernel_Completion, 2)
	testing.expect(t, carrier_point < delta_point)
	testing.expect(t, history_header_record_end(buffer, .Divergence, .Unexpected_Arguments, carrier_point, 3, 4))
	report, found, ok = divergence_report_of_history(buffer, scratch)
	testing.expect(t, ok && found)
	testing.expect_value(t, report.recorded_kind, History_Record_Kind.Kernel_Completion)
	testing.expect_value(t, report.recorded_instruction_address, SIMULATED_CHECKSUM_ADDRESS)

	// A divergence one point past the damaged record: the damage comes
	// before it, so the report is refused.
	testing.expect(t, history_header_record_end(buffer, .Divergence, .Unexpected_Arguments, delta_point + 1, 3, 4))
	_, found, ok = divergence_report_of_history(buffer, scratch)
	testing.expect(t, !ok && !found)
}
