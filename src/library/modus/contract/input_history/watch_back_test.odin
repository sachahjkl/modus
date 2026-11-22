#+build !freestanding
package input_history

import "core:testing"
import op "modus:contract/operation"

// The page of the variables in these tests, and the address of one of them.
@(private = "file")
TEST_PAGE :: u64(0x40_0000)
@(private = "file")
TEST_VARIABLE :: TEST_PAGE + 0x100

// test_history makes a history buffer with no record.
@(private = "file")
test_history :: proc(t: ^testing.T, buffer: []u8) -> History_Writer {
	writer, ok := history_writer_init(buffer, {}, 1_000_000, 0, 3)
	testing.expect(t, ok)
	return writer
}

// append_page_write appends a page delta of TEST_PAGE that changes the
// bytes at each offset of offsets to the value of the same index.
@(private = "file")
append_page_write :: proc(t: ^testing.T, writer: ^History_Writer, offsets: []int, values: []u8, instruction: u64 = 0x40_1000) {
	before, after: [HISTORY_PAGE_SIZE]u8
	for offset, index in offsets {
		after[offset] = values[index]
	}
	encoded: [PAGE_DELTA_MAX_BYTES]u8
	written, changed, ok := page_delta_encode(TEST_PAGE, &before, &after, encoded[:])
	testing.expect(t, ok && changed)
	testing.expect(t, history_writer_append(writer, .Page_Delta, instruction, 0x70_0000, encoded[:written]))
}

// append_cpuid appends a record that writes no memory.
@(private = "file")
append_cpuid :: proc(t: ^testing.T, writer: ^History_Writer) {
	testing.expect(t, history_writer_append_cpuid(writer, 0x40_2000, 0x70_0000, Cpuid_Payload{leaf = 1}))
}

@(test)
watch_back_refuses_bad_arguments_before_the_history :: proc(t: ^testing.T) {
	buffer: [4096]u8
	writer := test_history(t, buffer[:])
	append_page_write(t, &writer, {0x100}, {0xAA})

	// The size: 0, one past the bound, and the largest value.
	for size in ([]u64{0, WATCH_BACK_SIZE_LIMIT + 1, max(u64)}) {
		match, refusal := history_find_last_write(buffer[:], TEST_VARIABLE, size, 0)
		testing.expect_value(t, refusal, Watch_Back_Refusal.Bad_Size)
		testing.expect_value(t, match, Watch_Back_Match{})
	}
	// The address: 0, USER_END, a range that passes USER_END by one byte,
	// and a range whose end wraps past the largest address.
	bad_addresses := [][2]u64{{0, 1}, {op.USER_END, 1}, {op.USER_END - 4, 8}, {max(u64) - 1, 4}, {max(u64), 1}}
	for case_ in bad_addresses {
		match, refusal := history_find_last_write(buffer[:], case_[0], case_[1], 0)
		testing.expect_value(t, refusal, Watch_Back_Refusal.Bad_Address)
		testing.expect_value(t, match, Watch_Back_Match{})
	}
	// The edges that pass: the bound of the size, and a range that ends at USER_END.
	_, refusal := history_find_last_write(buffer[:], TEST_PAGE, WATCH_BACK_SIZE_LIMIT, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
	_, refusal = history_find_last_write(buffer[:], op.USER_END - 8, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.No_Write)
}

@(test)
watch_back_refuses_a_damaged_or_empty_history :: proc(t: ^testing.T) {
	// No byte, and a buffer one byte shorter than the header.
	_, refusal := history_find_last_write(nil, TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	short: [size_of(History_Header) - 1]u8
	_, refusal = history_find_last_write(short[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)

	// A valid header with no record has no write.
	buffer: [4096]u8
	writer := test_history(t, buffer[:])
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.No_Write)

	append_page_write(t, &writer, {0x100}, {0xAA})
	// A wrong magic, a wrong version, written bytes past the capacity, and a
	// byte of the reserved field each refuse the whole history.
	header := (^History_Header)(raw_data(buffer[:]))
	saved := header^
	header.magic ~= 1
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	header^ = saved
	header.version += 1
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	header^ = saved
	header.written_bytes = header.capacity_bytes + 1
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	header^ = saved
	header.reserved[119] = 1
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	header^ = saved

	// A history cut inside its record: written bytes one short of the record.
	header.written_bytes -= 1
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	header^ = saved
	match, valid := history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, valid, Watch_Back_Refusal.None)
	testing.expect_value(t, match.point_number, u64(1))
}

@(test)
watch_back_refuses_a_damaged_record_that_it_reads :: proc(t: ^testing.T) {
	buffer: [4096]u8
	writer := test_history(t, buffer[:])
	append_page_write(t, &writer, {0x100}, {0x11})
	second_offset := size_of(History_Header) + int(writer.write_offset)
	append_page_write(t, &writer, {0x100}, {0x22})
	third_offset := size_of(History_Header) + int(writer.write_offset)
	append_page_write(t, &writer, {0x100}, {0x33})

	// A kind that names no member in the third record: a scan that reads it
	// refuses, also the scan that stops at it, and a scan that stops before
	// it does not read it.
	third := (^History_Record_Header)(raw_data(buffer[third_offset:]))
	third.kind = u32(max(History_Record_Kind)) + 1
	_, refusal := history_find_last_write(buffer[:], TEST_VARIABLE, 1, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 1, 3)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	match, early := history_find_last_write(buffer[:], TEST_VARIABLE, 1, 2)
	testing.expect_value(t, early, Watch_Back_Refusal.None)
	testing.expect_value(t, match.point_number, u64(1))
	testing.expect_value(t, match.shown_bytes[0], u8(0x11))
	third.kind = u32(History_Record_Kind.Page_Delta)

	// An input point that does not grow refuses the history: a scan cannot
	// know which of the two writes came last.
	second := (^History_Record_Header)(raw_data(buffer[second_offset:]))
	second.point_number = 1
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 1, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	second.point_number = 0
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 1, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	second.point_number = 2

	// A page delta whose range passes the end of its page.
	delta := (^Page_Delta_Range)(raw_data(buffer[second_offset + size_of(History_Record_Header) + size_of(Page_Delta_Header):]))
	saved := delta^
	delta.offset = u16(HISTORY_PAGE_SIZE - 1)
	delta.length = 2
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 1, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.Damaged_History)
	delta^ = saved
	_, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 1, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
}

@(test)
watch_back_misses_writes_that_do_not_overlap :: proc(t: ^testing.T) {
	buffer: [8192]u8
	writer := test_history(t, buffer[:])
	append_cpuid(t, &writer)
	append_page_write(t, &writer, {0x0F0, 0x200}, {1, 2})
	// A kernel completion that copies bytes beside the variable, not on it.
	entry := Kernel_Completion_Payload{completion_status = u32(op.Status.Ok), copied_bytes_count = 8, copied_user_address = TEST_VARIABLE + 8}
	copied := [8]u8{9, 9, 9, 9, 9, 9, 9, 9}
	testing.expect(t, history_writer_append_kernel_completion(&writer, 0x40_3000, 0x70_0000, entry, copied[:]))
	testing.expect(t, history_writer_append_end(&writer, 0x40_4000, 0x70_0000, .Normal_Stop))

	_, refusal := history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.No_Write)
	// Another page, at the same offset in it.
	_, refusal = history_find_last_write(buffer[:], TEST_PAGE + HISTORY_PAGE_SIZE + 0x0F0, 1, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.No_Write)
}

@(test)
watch_back_hits_the_edges_of_the_range :: proc(t: ^testing.T) {
	buffer: [4096]u8
	writer := test_history(t, buffer[:])
	append_page_write(t, &writer, {0x100}, {0x5A})
	written := TEST_PAGE + 0x100

	// The last byte of the range is the written byte: a hit.
	match, refusal := history_find_last_write(buffer[:], written - 7, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
	testing.expect_value(t, match.written_address, written)
	testing.expect_value(t, match.written_count, u64(1))
	testing.expect_value(t, match.shown_count, u32(1))
	testing.expect_value(t, match.shown_bytes[0], u8(0x5A))
	// The range ends at the written byte: a miss.
	_, refusal = history_find_last_write(buffer[:], written - 8, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.No_Write)
	// The first byte of the range is the written byte: a hit.
	_, refusal = history_find_last_write(buffer[:], written, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
	// The range starts one past the written byte: a miss.
	_, refusal = history_find_last_write(buffer[:], written + 1, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.No_Write)
}

@(test)
watch_back_gives_the_latest_write_before_the_point :: proc(t: ^testing.T) {
	buffer: [8192]u8
	writer := test_history(t, buffer[:])
	append_page_write(t, &writer, {0x100}, {0x11}, 0x40_1001) // point 1
	append_cpuid(t, &writer) // point 2
	third_offset := writer.write_offset
	append_page_write(t, &writer, {0x101}, {0x22}, 0x40_1003) // point 3
	append_page_write(t, &writer, {0x900}, {0x77}, 0x40_1004) // point 4: another variable
	// Point 5: the kernel copies 8 bytes over the variable.
	entry := Kernel_Completion_Payload{completion_status = u32(op.Status.Ok), copied_bytes_count = 8, copied_user_address = TEST_VARIABLE - 4}
	copied := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect(t, history_writer_append_kernel_completion(&writer, 0x40_1005, 0x70_0005, entry, copied[:]))
	append_cpuid(t, &writer) // point 6

	match, refusal := history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
	testing.expect_value(t, match.point_number, u64(5))
	testing.expect_value(t, match.kind, History_Record_Kind.Kernel_Completion)
	testing.expect_value(t, match.instruction_address, u64(0x40_1005))
	testing.expect_value(t, match.stack_pointer, u64(0x70_0005))
	testing.expect_value(t, match.written_address, TEST_VARIABLE)
	testing.expect_value(t, match.written_count, u64(4))
	testing.expect_value(t, match.shown_count, u32(4))
	testing.expect_value(t, match.shown_bytes, [8]u8{5, 6, 7, 8, 0, 0, 0, 0})

	// Strictly before point 5 (and before 4, which wrote elsewhere): point 3.
	for before in ([]u64{5, 4}) {
		match, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, before)
		testing.expect_value(t, refusal, Watch_Back_Refusal.None)
		testing.expect_value(t, match.point_number, u64(3))
		testing.expect_value(t, match.kind, History_Record_Kind.Page_Delta)
		testing.expect_value(t, match.history_byte_offset, third_offset)
		testing.expect_value(t, match.written_address, TEST_VARIABLE + 1)
		testing.expect_value(t, match.shown_bytes[0], u8(0x22))
	}
	// Strictly before point 3: point 1.
	match, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 3)
	testing.expect_value(t, match.point_number, u64(1))
	testing.expect_value(t, match.history_byte_offset, u64(0))
	testing.expect_value(t, match.shown_bytes[0], u8(0x11))
	// Strictly before point 1: nothing came before.
	match, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, 1)
	testing.expect_value(t, refusal, Watch_Back_Refusal.No_Write)
	testing.expect_value(t, match, Watch_Back_Match{})
	// A point past the history is the whole history.
	match, refusal = history_find_last_write(buffer[:], TEST_VARIABLE, 8, max(u64))
	testing.expect_value(t, match.point_number, u64(5))
}

@(test)
watch_back_counts_each_range_of_one_record :: proc(t: ^testing.T) {
	buffer: [4096]u8
	writer := test_history(t, buffer[:])
	// Two ranges inside the watched bytes, and one outside them.
	append_page_write(t, &writer, {0x102, 0x103, 0x106, 0x200}, {0xA2, 0xA3, 0xA6, 0xFF})
	match, refusal := history_find_last_write(buffer[:], TEST_VARIABLE, 8, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
	testing.expect_value(t, match.written_address, TEST_VARIABLE + 2)
	testing.expect_value(t, match.written_count, u64(3))
	// The shown values stop at the end of the first contiguous run.
	testing.expect_value(t, match.shown_count, u32(2))
	testing.expect_value(t, match.shown_bytes, [8]u8{0xA2, 0xA3, 0, 0, 0, 0, 0, 0})
	// A whole page watched: the shown values stop at their bound.
	full_buffer: [8192]u8
	full_writer := test_history(t, full_buffer[:])
	offsets: [16]int
	values: [16]u8
	for index in 0 ..< 16 {
		offsets[index] = index
		values[index] = u8(index + 1)
	}
	append_page_write(t, &full_writer, offsets[:], values[:])
	match, refusal = history_find_last_write(full_buffer[:], TEST_PAGE, WATCH_BACK_SIZE_LIMIT, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
	testing.expect_value(t, match.written_count, u64(16))
	testing.expect_value(t, match.shown_count, u32(WATCH_BACK_SHOWN_BYTES))
	testing.expect_value(t, match.shown_bytes, [8]u8{1, 2, 3, 4, 5, 6, 7, 8})
}

@(test)
checkpoint_plan_for_target_takes_the_checkpoint_strictly_before :: proc(t: ^testing.T) {
	// A nil ring, an uninitialized ring, and the point 0, which no record has.
	testing.expect_value(t, checkpoint_plan_for_target(nil, 3).status, Step_Back_Status.Invalid_Request)
	ring: Checkpoint_Ring
	testing.expect_value(t, checkpoint_plan_for_target(&ring, 3).status, Step_Back_Status.Invalid_Request)
	testing.expect(t, checkpoint_ring_init(&ring, 4))
	testing.expect_value(t, checkpoint_plan_for_target(&ring, 0).status, Step_Back_Status.Invalid_Request)
	// A damaged ring.
	damaged := ring
	damaged.head = damaged.capacity
	testing.expect_value(t, checkpoint_plan_for_target(&damaged, 3).status, Step_Back_Status.Invalid_Request)

	// An empty ring: the replay starts at the first instruction.
	empty := checkpoint_plan_for_target(&ring, 3)
	testing.expect_value(t, empty.status, Step_Back_Status.No_Prior_Checkpoint)
	testing.expect_value(t, empty.replay_points_to_advance, u64(3))

	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 1, position = {point_number = 2}, history_byte_offset = 64}))
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 2, position = {point_number = 5}, history_byte_offset = 256}))
	// Before the first checkpoint, and at it: none is strictly before.
	for target in ([]u64{1, 2}) {
		plan := checkpoint_plan_for_target(&ring, target)
		testing.expect_value(t, plan.status, Step_Back_Status.No_Prior_Checkpoint)
		testing.expect_value(t, plan.replay_points_to_advance, target)
	}
	// At the second checkpoint: the first one, which is before the write.
	plan := checkpoint_plan_for_target(&ring, 5)
	testing.expect_value(t, plan.status, Step_Back_Status.Ok)
	testing.expect_value(t, plan.checkpoint.id, u64(1))
	testing.expect_value(t, plan.replay_points_to_advance, u64(3))
	testing.expect_value(t, plan.history_start_offset, u64(64))
	// One past it, and the largest point.
	plan = checkpoint_plan_for_target(&ring, 6)
	testing.expect_value(t, plan.checkpoint.id, u64(2))
	testing.expect_value(t, plan.replay_points_to_advance, u64(1))
	plan = checkpoint_plan_for_target(&ring, max(u64))
	testing.expect_value(t, plan.checkpoint.id, u64(2))
	testing.expect_value(t, plan.replay_points_to_advance, max(u64) - 5)

	// The match of a history paired with its checkpoint.
	buffer: [4096]u8
	writer := test_history(t, buffer[:])
	for _ in 0 ..< 3 {
		append_cpuid(t, &writer)
	}
	append_page_write(t, &writer, {0x100}, {0x44}) // point 4
	match, refusal := history_find_last_write(buffer[:], TEST_VARIABLE, 1, 0)
	testing.expect_value(t, refusal, Watch_Back_Refusal.None)
	paired := checkpoint_plan_for_target(&ring, match.point_number)
	testing.expect_value(t, paired.status, Step_Back_Status.Ok)
	testing.expect_value(t, paired.checkpoint.id, u64(1))
	testing.expect_value(t, paired.start_position.point_number, u64(2))
	testing.expect_value(t, paired.target_position.point_number, u64(4))
	testing.expect_value(t, paired.replay_points_to_advance, u64(2))
}
