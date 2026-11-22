#+build !freestanding
package input_history

import "core:testing"
import op "modus:contract/operation"

// The simulated window process of the tests below: it starts with no shared
// mapping, waits for its handles, maps the ring of its compositor with Write
// and its surface without Write, then reads both in rounds while the
// compositor writes them. It unmaps the surface after one round. A replay
// runs it alone: each Shared_Mapping that follows a completion of
// Memory_Map makes a stand-in mapping, and the deltas write it.

RECEIVED_RING_ADDRESS :: u64(0x60_0000)
RECEIVED_SURFACE_ADDRESS :: u64(0x70_0000)
RECEIVED_SURFACE_PAGES :: 2
RECEIVED_POOL_PAGES :: 1 + RECEIVED_SURFACE_PAGES
RECEIVED_RING_HANDLE :: u64(5)
RECEIVED_SURFACE_HANDLE :: u64(6)
RECEIVED_ROUNDS :: 4
RECEIVED_UNMAP_ROUND :: 3
RECEIVED_STACK :: u64(0x7FFF_E000)
RECEIVED_MAP_ADDRESS :: u64(0x40_2000)
RECEIVED_WAIT_ADDRESS :: u64(0x40_2100)
RECEIVED_CARRIER_ADDRESS :: u64(0x40_2200)
RECEIVED_UNMAP_ADDRESS :: u64(0x40_2300)
RECEIVED_WRITE_FLAG :: u64(1) << u64(op.Map_Flag.Write)

// How a replayed window process differs from the recorded one.
Received_Variant :: enum {
	Same,
	Surface_Other_Size, // It maps one page of the surface.
	Ring_Without_Write, // It maps the ring without Write.
	Skips_Surface, // It never maps the surface.
	Reads_Surface_After_Unmap, // Its checksum reads the surface after the unmap.
}

Received_Session :: struct {
	replaying:      bool,
	variant:        Received_Variant,
	// The live pages in the record, the stand-in pages in the replay: the
	// ring, then the pages of the surface. A stand-in mapping names its
	// first page here by its place.
	pages:          [RECEIVED_POOL_PAGES][HISTORY_PAGE_SIZE]u8,
	baseline:       [RECEIVED_POOL_PAGES][HISTORY_PAGE_SIZE]u8,
	ring_mapped:    bool,
	surface_mapped: bool,
	writer:         History_Writer,
	reader:         History_Reader,
	stand_ins:      Stand_In_Mapping_Set,
	scratch:        [MAX_RECORD_PAYLOAD_BYTES]u8,
	divergence:     Replay_Check_Result,
	point:          u64,
	checksum:       u64,
}

received_page_address :: proc(index: int) -> u64 {
	if index == 0 {
		return RECEIVED_RING_ADDRESS
	}
	return RECEIVED_SURFACE_ADDRESS + u64(index - 1) * HISTORY_PAGE_SIZE
}

received_page_mapped :: proc(session: ^Received_Session, index: int) -> bool {
	return index == 0 ? session.ring_mapped : session.surface_mapped
}

// received_peer_write is the compositor: what it writes in the ring and in
// the surface before the entry of a round. Round 0 is before the maps. The
// replay never runs it.
received_peer_write :: proc(session: ^Received_Session, round: int) {
	session.pages[0][0] = u8(round + 1)
	for index in 0 ..< 16 {
		session.pages[0][64 + 16 * round + index] = u8(round * 3 + index)
	}
	for index in 0 ..< 32 {
		session.pages[1][128 * round + index] = u8(0x40 + round)
		session.pages[2][int(HISTORY_PAGE_SIZE) - 32 * (round + 1) + index] = u8(0x80 + round)
	}
}

// received_fail ends a replay with its first divergence.
received_fail :: proc(session: ^Received_Session, check: Replay_Check_Result, point: u64) -> bool {
	session.divergence = check
	session.point = point
	return false
}

// received_apply_deltas applies each Page_Delta that comes next to the
// stand-in pages. A delta outside every stand-in mapping, or a damaged
// record, is a divergence at its point.
received_apply_deltas :: proc(session: ^Received_Session) -> bool {
	for {
		record_header, kind, payload, stride, has_more, ok := history_reader_peek_into(&session.reader, session.scratch[:])
		if !ok {
			return received_fail(session, {.Missing_Record, 0, 0}, history_reader_next_point(&session.reader))
		}
		if !has_more || kind != .Page_Delta {
			return true
		}
		delta_header, _ := page_delta_validate(payload)
		stand_in, page, found := stand_in_mapping_set_find(&session.stand_ins, delta_header.virtual_address)
		if !found || !page_delta_apply(payload, &session.pages[u64(stand_in.place) + page]) {
			return received_fail(session, {.Missing_Record, 0, 0}, record_header.point_number)
		}
		history_reader_advance(&session.reader, record_header, stride)
	}
}

// received_entry is one kernel entry with one command. The record writes
// its completion, with the address of a map as its first value. The replay
// checks it and gives that recorded value; trailing: the deltas that the
// writers wrote at this entry come next.
received_entry :: proc(t: ^testing.T, session: ^Received_Session, actual: Replay_Actual_Event, completion_address: u64, trailing: bool) -> (recorded_address: u64, go_on: bool) {
	if !session.replaying {
		entry := Kernel_Completion_Payload {
			command_kind      = actual.command_kind,
			command_values    = actual.command_values,
			completion_status = u32(op.Status.Ok),
			completion_values = {0 = completion_address},
		}
		testing.expect(t, history_writer_append_kernel_completion(&session.writer, actual.instruction_address, actual.stack_pointer, entry, nil))
		return completion_address, true
	}
	if !received_apply_deltas(session) {
		return 0, false
	}
	record_header, kind, payload, has_more, ok := history_reader_next_into(&session.reader, session.scratch[:])
	check := replay_step_check(actual, ok && has_more, record_header, kind, payload)
	if check.divergence != .None {
		return 0, received_fail(session, check, ok && has_more ? record_header.point_number : history_reader_next_point(&session.reader))
	}
	completion, _, _ := kernel_completion_from_payload(payload)
	if trailing && !received_apply_deltas(session) {
		return 0, false
	}
	return completion.completion_values[0], true
}

// received_capture writes the deltas of each mapped page at an input point
// of the record: what the compositor wrote since the last capture.
received_capture :: proc(t: ^testing.T, session: ^Received_Session, instruction_address: u64, first, count: int) {
	delta: [PAGE_DELTA_MAX_BYTES]u8
	for index in first ..< first + count {
		if !received_page_mapped(session, index) {
			continue
		}
		written, changed, ok := page_delta_capture(received_page_address(index), &session.baseline[index], &session.pages[index], delta[:])
		testing.expect(t, ok)
		if changed {
			testing.expect(t, history_writer_append(&session.writer, .Page_Delta, instruction_address, RECEIVED_STACK, delta[:written]))
		}
	}
}

// received_map is a Memory_Map of received memory. The record writes the
// completion, then the Shared_Mapping, then the first bytes of each page.
// The replay checks the completion, then the Shared_Mapping against its own
// map, then makes the stand-in mapping and writes its first bytes.
received_map :: proc(t: ^testing.T, session: ^Received_Session, handle: u64, write: bool, page_count: u64, address: u64, place: u32) -> bool {
	flags := write ? RECEIVED_WRITE_FLAG : 0
	actual := Replay_Actual_Event {
		kind                = .Kernel_Completion,
		instruction_address = RECEIVED_MAP_ADDRESS,
		stack_pointer       = RECEIVED_STACK,
		command_kind        = u32(op.Operation.Memory_Map),
		command_values      = {0 = handle, 3 = flags, 5 = page_count},
	}
	recorded_address, go_on := received_entry(t, session, actual, address, trailing = false)
	if !go_on {
		return false
	}
	access := write ? Shared_Mapping_Access.Read_Write : Shared_Mapping_Access.Read
	if !session.replaying {
		entry := Shared_Mapping_Payload{virtual_address = address, page_count = page_count, access = u32(access)}
		testing.expect(t, history_writer_append(&session.writer, .Shared_Mapping, RECEIVED_MAP_ADDRESS, RECEIVED_STACK, bytes_of(&entry)))
		if place == 0 {
			session.ring_mapped = true
		} else {
			session.surface_mapped = true
		}
		received_capture(t, session, RECEIVED_MAP_ADDRESS, int(place), int(page_count))
		return true
	}
	record_header, kind, payload, stride, has_more, ok := history_reader_peek_into(&session.reader, session.scratch[:])
	if !ok || !has_more || kind != .Shared_Mapping {
		return received_fail(session, {.Missing_Record, u64(History_Record_Kind.Shared_Mapping), u64(kind)}, history_reader_next_point(&session.reader))
	}
	entry, recorded_access, _ := shared_mapping_validate(payload)
	check := replay_shared_mapping_check(actual.command_values, recorded_address, entry, recorded_access)
	if check.divergence != .None {
		return received_fail(session, check, record_header.point_number)
	}
	if !stand_in_mapping_set_add(&session.stand_ins, entry, recorded_access, place, u64(place) + 1) {
		return received_fail(session, {.Unexpected_Arguments, entry.virtual_address, 0}, record_header.point_number)
	}
	history_reader_advance(&session.reader, record_header, stride)
	return received_apply_deltas(session)
}

// received_checksum reads the bytes that the process sees: the ring, and the
// surface while it is mapped.
received_checksum :: proc(session: ^Received_Session, checksum: u64) -> u64 {
	checksum := checksum
	reads_surface := session.surface_mapped || session.replaying && session.variant == .Reads_Surface_After_Unmap
	for page, index in session.pages {
		if index > 0 && !reads_surface {
			break
		}
		for byte_value, offset in page {
			checksum = (checksum ~ u64(byte_value) * u64(offset + 1)) * 0x1000_0000_01B3
		}
	}
	return checksum
}

received_program :: proc(t: ^testing.T, session: ^Received_Session) {
	checksum := u64(0xCBF2_9CE4_8422_2325)
	wait := Replay_Actual_Event{kind = .Kernel_Completion, instruction_address = RECEIVED_WAIT_ADDRESS, stack_pointer = RECEIVED_STACK, command_kind = u32(op.Operation.Word_Wait), command_values = {0 = 0x60_0000, 1 = 1}}
	// The wait for the handles: the compositor writes the first bytes then.
	if _, go_on := received_entry(t, session, wait, 0, trailing = true); !go_on {
		return
	}
	if !session.replaying {
		received_peer_write(session, 0)
	}
	if !received_map(t, session, RECEIVED_RING_HANDLE, !(session.replaying && session.variant == .Ring_Without_Write), 1, RECEIVED_RING_ADDRESS, 0) {
		return
	}
	if !(session.replaying && session.variant == .Skips_Surface) {
		surface_pages := u64(RECEIVED_SURFACE_PAGES)
		if session.replaying && session.variant == .Surface_Other_Size {
			surface_pages = 1
		}
		if !received_map(t, session, RECEIVED_SURFACE_HANDLE, false, surface_pages, RECEIVED_SURFACE_ADDRESS, 1) {
			return
		}
	}
	for round in 1 ..= RECEIVED_ROUNDS {
		if _, go_on := received_entry(t, session, wait, 0, trailing = session.replaying); !go_on {
			return
		}
		if !session.replaying {
			received_peer_write(session, round)
			received_capture(t, session, RECEIVED_WAIT_ADDRESS, 0, RECEIVED_POOL_PAGES)
		}
		checksum = received_checksum(session, checksum)
		carrier := Replay_Actual_Event{kind = .Kernel_Completion, instruction_address = RECEIVED_CARRIER_ADDRESS, stack_pointer = RECEIVED_STACK, command_kind = u32(op.Operation.Word_Wake), command_values = {0 = 0x60_0008, 1 = checksum}}
		if _, go_on := received_entry(t, session, carrier, 0, trailing = true); !go_on {
			return
		}
		if round == RECEIVED_UNMAP_ROUND {
			unmap := Replay_Actual_Event{kind = .Kernel_Completion, instruction_address = RECEIVED_UNMAP_ADDRESS, stack_pointer = RECEIVED_STACK, command_kind = u32(op.Operation.Memory_Unmap), command_values = {1 = RECEIVED_SURFACE_ADDRESS}}
			if _, go_on := received_entry(t, session, unmap, 0, trailing = true); !go_on {
				return
			}
			session.surface_mapped = false
			if session.replaying {
				testing.expect_value(t, stand_in_mapping_set_remove_range(&session.stand_ins, RECEIVED_SURFACE_ADDRESS, RECEIVED_SURFACE_PAGES), 1)
			}
		}
	}
	session.checksum = checksum
	if !session.replaying {
		testing.expect(t, history_writer_append_end(&session.writer, 0, 0, .Normal_Stop))
		return
	}
	if !received_apply_deltas(session) {
		return
	}
	record_header, kind, payload, has_more, ok := history_reader_next_into(&session.reader, session.scratch[:])
	if check := replay_end_check(ok && has_more, kind, payload); check.divergence != .None {
		received_fail(session, check, ok && has_more ? record_header.point_number : history_reader_next_point(&session.reader))
	}
}

received_record :: proc(t: ^testing.T, buffer: []u8) -> (checksum: u64) {
	session := new(Received_Session)
	defer free(session)
	ok: bool
	session.writer, ok = history_writer_init(buffer, {}, 1_000_000_000, 0, 3)
	testing.expect(t, ok)
	received_program(t, session)
	return session.checksum
}

received_replay :: proc(t: ^testing.T, buffer: []u8, variant: Received_Variant) -> (result: Replay_Check_Result, point: u64, checksum: u64) {
	session := new(Received_Session)
	defer free(session)
	session.replaying = true
	session.variant = variant
	opened: bool
	session.reader, opened = history_reader_open(buffer)
	if !opened {
		return {.Missing_Record, 0, 0}, 0, 0
	}
	// The replay reads the surface while its stand-in mapping lives: the
	// history alone decides which pages hold what.
	session.ring_mapped = true
	session.surface_mapped = true
	received_program(t, session)
	return session.divergence, session.point, session.checksum
}

// received_count gives the count of the records of a kind in a history.
received_count :: proc(buffer: []u8, wanted: History_Record_Kind) -> (count: int) {
	reader, _ := history_reader_open(buffer)
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	for {
		_, kind, _, has_more, ok := history_reader_next_into(&reader, scratch)
		if !ok || !has_more {
			return count
		}
		if kind == wanted {
			count += 1
		}
	}
}

// A window process that receives its ring and its surface after its start
// replays alone, three times, with no divergence and the same checksum. The
// history has no Shared_Mapping in its head: each one comes right after the
// completion of its Memory_Map, at the address of that completion, before
// the first bytes of its pages; and no delta names the surface after its
// unmap.
@(test)
received_mappings_replay_alone_with_no_divergence :: proc(t: ^testing.T) {
	buffer := make([]u8, 131072)
	defer delete(buffer)
	recorded := received_record(t, buffer)
	testing.expect(t, recorded != 0)
	for _ in 0 ..< 3 {
		result, point, replayed := received_replay(t, buffer, .Same)
		testing.expect_value(t, result.divergence, Divergence_Kind.None)
		testing.expect_value(t, point, u64(0))
		testing.expect_value(t, replayed, recorded)
	}

	reader, _ := history_reader_open(buffer)
	scratch := make([]u8, MAX_RECORD_PAYLOAD_BYTES)
	defer delete(scratch)
	previous_kind: History_Record_Kind
	previous_completion: Kernel_Completion_Payload
	previous_point: u64
	mappings, completions, first_bytes: int
	unmapped := false
	surface_deltas_after_unmap := 0
	for {
		record_header, kind, payload, has_more, ok := history_reader_next_into(&reader, scratch)
		testing.expect(t, ok)
		if !has_more {
			break
		}
		testing.expect(t, record_header.point_number > previous_point)
		switch kind {
		case .Kernel_Completion:
			completions += 1
			previous_completion, _, _ = kernel_completion_from_payload(payload)
			if previous_completion.command_kind == u32(op.Operation.Memory_Unmap) {
				unmapped = true
			}
		case .Shared_Mapping:
			mappings += 1
			// Never in the head: after the wait for the handles, right
			// after the completion of its Memory_Map, at its address.
			testing.expect(t, completions >= 2)
			testing.expect_value(t, previous_kind, History_Record_Kind.Kernel_Completion)
			testing.expect_value(t, previous_completion.command_kind, u32(op.Operation.Memory_Map))
			entry, access, _ := shared_mapping_validate(payload)
			testing.expect_value(t, entry.virtual_address, previous_completion.completion_values[0])
			testing.expect_value(t, entry.page_count, previous_completion.command_values[5])
			testing.expect_value(t, access == .Read_Write, previous_completion.command_values[3] & RECEIVED_WRITE_FLAG != 0)
		case .Page_Delta:
			header, _ := page_delta_validate(payload)
			if previous_kind == .Shared_Mapping || previous_kind == .Page_Delta && previous_completion.command_kind == u32(op.Operation.Memory_Map) {
				first_bytes += 1
			}
			if unmapped && header.virtual_address >= RECEIVED_SURFACE_ADDRESS {
				surface_deltas_after_unmap += 1
			}
		case .None, .Cycle_Counter, .Processor_Identification, .History_End:
		}
		previous_kind = kind
		previous_point = record_header.point_number
	}
	testing.expect_value(t, mappings, 2)
	// The first bytes of the ring and of the two pages of the surface.
	testing.expect_value(t, first_bytes, RECEIVED_POOL_PAGES)
	testing.expect_value(t, surface_deltas_after_unmap, 0)
	testing.expect_value(t, previous_kind, History_Record_Kind.History_End)
}

// A replay that maps otherwise than the record diverges at the exact point:
// another size or another access at the completion of the Memory_Map, a
// skipped map at the completion that the history holds there, and a read of
// the surface after its unmap at the next carrier of the checksum.
@(test)
received_mappings_replay_finds_each_wrong_map :: proc(t: ^testing.T) {
	buffer := make([]u8, 131072)
	defer delete(buffer)
	recorded := received_record(t, buffer)
	_, ring_map_point, _ := find_record(buffer, .Kernel_Completion, 2)
	_, surface_map_point, _ := find_record(buffer, .Kernel_Completion, 3)

	result, point, _ := received_replay(t, buffer, .Surface_Other_Size)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, surface_map_point)
	testing.expect_value(t, result.expected, u64(RECEIVED_SURFACE_PAGES))
	testing.expect_value(t, result.actual, u64(1))

	result, point, _ = received_replay(t, buffer, .Ring_Without_Write)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, ring_map_point)
	testing.expect_value(t, result.expected, RECEIVED_WRITE_FLAG)
	testing.expect_value(t, result.actual, u64(0))

	// The skipped map: the next entry is the wait of round 1, at another
	// instruction than the map that the history holds there.
	result, point, _ = received_replay(t, buffer, .Skips_Surface)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Instruction)
	testing.expect_value(t, point, surface_map_point)
	testing.expect_value(t, result.expected, RECEIVED_MAP_ADDRESS)
	testing.expect_value(t, result.actual, RECEIVED_WAIT_ADDRESS)

	// The completions: the wait for the handles, the two maps, then a wait
	// and a carrier in each round, and the unmap after the carrier of its
	// round. The first carrier after the unmap is the next round's.
	_, carrier_after_unmap, _ := find_record(buffer, .Kernel_Completion, 3 + 2 * RECEIVED_UNMAP_ROUND + 1 + 2)
	replayed: u64
	result, point, replayed = received_replay(t, buffer, .Reads_Surface_After_Unmap)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, carrier_after_unmap)
	testing.expect(t, replayed != recorded)
}

// A damaged Shared_Mapping after a Memory_Map stops the replay at its point,
// with no stand-in mapping: another access, another count of pages, another
// address than the completion, a range that meets a stand-in mapping, and
// an input point that does not grow. A delta at the surface after its unmap
// finds no stand-in mapping.
@(test)
received_mappings_refuse_damaged_histories :: proc(t: ^testing.T) {
	buffer := make([]u8, 131072)
	defer delete(buffer)
	received_record(t, buffer)
	copy_of :: proc(buffer: []u8) -> []u8 {
		edited := make([]u8, len(buffer))
		copy(edited, buffer)
		return edited
	}

	// The ring recorded as Read: the replay maps it with Write.
	edited := copy_of(buffer)
	ring_offset, ring_point, _ := find_record(edited, .Shared_Mapping, 1)
	(^Shared_Mapping_Payload)(&edited[ring_offset])^.access = u32(Shared_Mapping_Access.Read)
	result, point, _ := received_replay(t, edited, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, ring_point)
	testing.expect_value(t, result.expected, u64(Shared_Mapping_Access.Read))
	testing.expect_value(t, result.actual, u64(Shared_Mapping_Access.Read_Write))
	delete(edited)

	// The surface recorded with one page: the map asks two.
	edited = copy_of(buffer)
	surface_offset, surface_point, _ := find_record(edited, .Shared_Mapping, 2)
	(^Shared_Mapping_Payload)(&edited[surface_offset])^.page_count = 1
	result, point, _ = received_replay(t, edited, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, surface_point)
	testing.expect_value(t, result.expected, u64(1))
	testing.expect_value(t, result.actual, u64(RECEIVED_SURFACE_PAGES))
	delete(edited)

	// The surface recorded at another address than its completion.
	edited = copy_of(buffer)
	(^Shared_Mapping_Payload)(&edited[surface_offset])^.virtual_address = RECEIVED_SURFACE_ADDRESS + HISTORY_PAGE_SIZE
	result, point, _ = received_replay(t, edited, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, surface_point)
	testing.expect_value(t, result.expected, RECEIVED_SURFACE_ADDRESS + HISTORY_PAGE_SIZE)
	testing.expect_value(t, result.actual, RECEIVED_SURFACE_ADDRESS)
	delete(edited)

	// The completion and the Shared_Mapping of the surface both at the ring:
	// they agree, and the set of the stand-in mappings refuses the overlap.
	edited = copy_of(buffer)
	completion_offset, _, _ := find_record(edited, .Kernel_Completion, 3)
	(^Kernel_Completion_Payload)(&edited[completion_offset])^.completion_values[0] = RECEIVED_RING_ADDRESS
	(^Shared_Mapping_Payload)(&edited[surface_offset])^.virtual_address = RECEIVED_RING_ADDRESS
	result, point, _ = received_replay(t, edited, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, point, surface_point)
	testing.expect_value(t, result.expected, RECEIVED_RING_ADDRESS)
	testing.expect_value(t, result.actual, u64(0))
	delete(edited)

	// The Shared_Mapping of the surface with the point of its completion:
	// the reader refuses it, and the divergence names the point that it
	// must have.
	edited = copy_of(buffer)
	_, surface_map_point, _ := find_record(edited, .Kernel_Completion, 3)
	(^History_Record_Header)(&edited[surface_offset - size_of(History_Record_Header)])^.point_number = surface_map_point
	result, point, _ = received_replay(t, edited, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Missing_Record)
	testing.expect_value(t, point, surface_map_point + 1)
	delete(edited)

	// The last delta, of the ring after the unmap of the surface, moved to
	// the surface: no stand-in mapping holds that page any more.
	edited = copy_of(buffer)
	last_delta_offset, last_delta_point, found := find_record(edited, .Page_Delta, received_count(edited, .Page_Delta))
	testing.expect(t, found)
	(^Page_Delta_Header)(&edited[last_delta_offset])^.virtual_address = RECEIVED_SURFACE_ADDRESS
	result, point, _ = received_replay(t, edited, .Same)
	testing.expect_value(t, result.divergence, Divergence_Kind.Missing_Record)
	testing.expect_value(t, point, last_delta_point)
	delete(edited)
}

// The removal by range: only the mappings that lie whole inside the range
// leave; a range that only meets a mapping, a range of no pages, a range
// past USER_END and a nil set remove nothing.
@(test)
stand_in_mapping_set_remove_range_edges :: proc(t: ^testing.T) {
	page := HISTORY_PAGE_SIZE
	set: Stand_In_Mapping_Set
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = 0x40_0000, page_count = 2}, .Read, 3, 1))
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = 0x40_0000 + 2 * page, page_count = 1}, .Read_Write, 3, 1))
	testing.expect(t, stand_in_mapping_set_add(&set, {virtual_address = 0x50_0000, page_count = 4}, .Read, 4, 2))
	before := set

	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x40_0000 + page, 1), 0) // The last page of the first mapping.
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x40_0000 - page, 2), 0) // The first page of the first mapping, from below.
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x50_0000, 3), 0) // One page short.
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x50_0000 + page, 4), 0) // Starts one page late.
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x40_0000, 0), 0)
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, op.USER_END, 1), 0)
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, op.USER_END - page, 2), 0)
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x40_0000, max(u64)), 0)
	testing.expect_value(t, stand_in_mapping_set_remove_range(nil, 0x40_0000, 2), 0)
	testing.expect(t, set == before)

	// Two mappings of one place: the range of the first removes it alone.
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x40_0000, 2), 1)
	testing.expect_value(t, set.count, 2)
	testing.expect_value(t, set.page_count, u64(5))
	_, _, ok := stand_in_mapping_set_find(&set, 0x40_0000)
	testing.expect(t, !ok)
	found, _, still := stand_in_mapping_set_find(&set, 0x40_0000 + 2 * page)
	testing.expect(t, still && found.place == 3)
	// A range that holds the rest removes both.
	testing.expect_value(t, stand_in_mapping_set_remove_range(&set, 0x40_0000, (0x50_0000 - 0x40_0000) / page + 4), 2)
	testing.expect_value(t, set.count, 0)
	testing.expect_value(t, set.page_count, u64(0))
}

// The access of a received mapping: Write gives Read_Write, no Write gives
// Read, Receive_Handles changes nothing, and Execute, No_Access,
// At_Address_Zero and Write_Combining are refused alone and with each other
// flag.
@(test)
shared_mapping_access_of_map_flags_refuses_each_other_flag :: proc(t: ^testing.T) {
	access, ok := shared_mapping_access_of_map_flags({})
	testing.expect(t, ok && access == .Read)
	access, ok = shared_mapping_access_of_map_flags({.Write})
	testing.expect(t, ok && access == .Read_Write)
	access, ok = shared_mapping_access_of_map_flags({.Write, .Receive_Handles})
	testing.expect(t, ok && access == .Read_Write)
	access, ok = shared_mapping_access_of_map_flags({.Receive_Handles})
	testing.expect(t, ok && access == .Read)
	for refused in ([?]op.Map_Flag{.Execute, .No_Access, .At_Address_Zero, .Write_Combining}) {
		for other in ([?]op.Map_Flags{{}, {.Write}, {.Receive_Handles}, {.Write, .Receive_Handles}}) {
			access, ok = shared_mapping_access_of_map_flags(other + {refused})
			testing.expect(t, !ok)
			testing.expect_value(t, access, Shared_Mapping_Access.None)
		}
	}
}

// The check of a replayed map against its Shared_Mapping: each argument at
// its edge, then the cases that agree.
@(test)
replay_shared_mapping_check_refuses_each_difference :: proc(t: ^testing.T) {
	entry := Shared_Mapping_Payload{virtual_address = 0x60_0000, page_count = 3, access = u32(Shared_Mapping_Access.Read_Write)}
	values := [7]u64{0 = 9, 3 = RECEIVED_WRITE_FLAG, 5 = 3}

	refused :: proc(t: ^testing.T, values: [7]u64, completion: u64, entry: Shared_Mapping_Payload, access: Shared_Mapping_Access, expected, actual: u64) {
		result := replay_shared_mapping_check(values, completion, entry, access)
		testing.expect_value(t, result.divergence, Divergence_Kind.Unexpected_Arguments)
		testing.expect_value(t, result.expected, expected)
		testing.expect_value(t, result.actual, actual)
	}

	// A map into another process.
	other := values
	other[1] = 4
	refused(t, other, 0x60_0000, entry, .Read_Write, 0, 4)
	// An unknown flag, Execute, No_Access, At_Address_Zero.
	for word in ([?]u64{1 << 63, RECEIVED_WRITE_FLAG | 1 << u64(op.Map_Flag.Execute), 1 << u64(op.Map_Flag.No_Access), 1 << u64(op.Map_Flag.At_Address_Zero)}) {
		bad := values
		bad[3] = word
		refused(t, bad, 0x60_0000, entry, .Read_Write, u64(Shared_Mapping_Access.Read_Write), word)
	}
	// Another access, each way.
	read_only := values
	read_only[3] = 0
	refused(t, read_only, 0x60_0000, entry, .Read_Write, u64(Shared_Mapping_Access.Read_Write), u64(Shared_Mapping_Access.Read))
	refused(t, values, 0x60_0000, entry, .Read, u64(Shared_Mapping_Access.Read), u64(Shared_Mapping_Access.Read_Write))
	// Another address than the completion, one page each way.
	refused(t, values, 0x60_0000 + HISTORY_PAGE_SIZE, entry, .Read_Write, 0x60_0000, 0x60_0000 + HISTORY_PAGE_SIZE)
	refused(t, values, 0x60_0000 - HISTORY_PAGE_SIZE, entry, .Read_Write, 0x60_0000, 0x60_0000 - HISTORY_PAGE_SIZE)
	// An asked address that is not the recorded one.
	asked := values
	asked[2] = 0x70_0000
	refused(t, asked, 0x60_0000, entry, .Read_Write, 0x60_0000, 0x70_0000)
	// One page less, one page more, the largest count.
	for count in ([?]u64{2, 4, max(u64)}) {
		bad := values
		bad[5] = count
		refused(t, bad, 0x60_0000, entry, .Read_Write, 3, count)
	}

	// The cases that agree: the kernel's choice, the asked address, and a
	// count of 0, which the history gives.
	testing.expect_value(t, replay_shared_mapping_check(values, 0x60_0000, entry, .Read_Write).divergence, Divergence_Kind.None)
	asked[2] = 0x60_0000
	testing.expect_value(t, replay_shared_mapping_check(asked, 0x60_0000, entry, .Read_Write).divergence, Divergence_Kind.None)
	whole := values
	whole[5] = 0
	testing.expect_value(t, replay_shared_mapping_check(whole, 0x60_0000, entry, .Read_Write).divergence, Divergence_Kind.None)
}

// The record keeps the set of the stand-in mappings that its replay will
// make, and refuses a received mapping that the replay could not hold: past
// 96 mappings, past 96 pages, past 64 pages in one mapping, or over a
// mapping of the set. An unmap makes room at once.
@(test)
record_set_of_stand_ins_refuses_past_the_capacity :: proc(t: ^testing.T) {
	page := HISTORY_PAGE_SIZE
	set := new(Stand_In_Mapping_Set)
	defer free(set)
	// The head: a shared writer of 64 pages.
	testing.expect(t, stand_in_mapping_set_add(set, {virtual_address = 0x100_0000, page_count = SHARED_MAPPING_PAGE_LIMIT}, .Read_Write, 1, 1))
	// Mappings after the start, one page each, up to the bound of the pages.
	for index in 0 ..< int(STAND_IN_PAGE_LIMIT - SHARED_MAPPING_PAGE_LIMIT) {
		testing.expect(t, stand_in_mapping_set_admits(set, {virtual_address = 0x200_0000 + u64(index) * 2 * page, page_count = 1}))
		testing.expect(t, stand_in_mapping_set_add(set, {virtual_address = 0x200_0000 + u64(index) * 2 * page, page_count = 1}, .Read, u32(10 + index), 1))
	}
	testing.expect_value(t, set.page_count, STAND_IN_PAGE_LIMIT)
	before := set^
	testing.expect(t, !stand_in_mapping_set_admits(set, {virtual_address = 0x300_0000, page_count = 1}))
	testing.expect(t, !stand_in_mapping_set_add(set, {virtual_address = 0x300_0000, page_count = 1}, .Read, 99, 1))
	testing.expect(t, set^ == before)
	// The unmap of one page of the head range removes nothing; the unmap of
	// the whole head mapping makes room for 64 pages.
	testing.expect_value(t, stand_in_mapping_set_remove_range(set, 0x100_0000, 1), 0)
	testing.expect_value(t, stand_in_mapping_set_remove_range(set, 0x100_0000, SHARED_MAPPING_PAGE_LIMIT), 1)
	testing.expect(t, !stand_in_mapping_set_admits(set, {virtual_address = 0x300_0000, page_count = SHARED_MAPPING_PAGE_LIMIT + 1}))
	testing.expect(t, stand_in_mapping_set_admits(set, {virtual_address = 0x300_0000, page_count = SHARED_MAPPING_PAGE_LIMIT}))
	// Over a mapping of the set, by its first page.
	testing.expect(t, !stand_in_mapping_set_admits(set, {virtual_address = 0x200_0000 - page, page_count = 2}))

	// 96 mappings of one page: the 97th is refused, an unmap makes room.
	many := new(Stand_In_Mapping_Set)
	defer free(many)
	for index in 0 ..< STAND_IN_MAPPING_CAPACITY {
		testing.expect(t, stand_in_mapping_set_add(many, {virtual_address = 0x400_0000 + u64(index) * 2 * page, page_count = 1}, .Read, 7, 1))
	}
	testing.expect(t, !stand_in_mapping_set_admits(many, {virtual_address = 0x500_0000, page_count = 1}))
	testing.expect_value(t, stand_in_mapping_set_remove_range(many, 0x400_0000 + 5 * 2 * page, 1), 1)
	testing.expect_value(t, many.count, STAND_IN_MAPPING_CAPACITY - 1)
	testing.expect(t, stand_in_mapping_set_add(many, {virtual_address = 0x500_0000, page_count = 1}, .Read, 7, 1))
}
