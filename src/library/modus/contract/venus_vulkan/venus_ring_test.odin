#+build !freestanding
#+build !modus
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"

RING_TEST_BUFFER :: u32(4096)

// Shared memory of a test ring, aligned as a blob mapping is.
@(private = "file")
Ring_Memory :: struct #align (64) {
	bytes: [RING_BUFFER_OFFSET + 4096 + 64]u8,
}

@(private = "file")
pattern :: proc(destination: []u8, seed: u8) {
	for index in 0 ..< len(destination) {
		destination[index] = seed + u8(index * 7)
	}
}

@(test)
ring_init_refuses_bad_sizes_and_memory :: proc(t: ^testing.T) {
	memory: Ring_Memory
	_, problem := ring_init(memory.bytes[:], RING_TEST_BUFFER - 4, 0)
	testing.expect_value(t, problem, Venus_Problem.Ring_Buffer_Size_Invalid)
	_, problem = ring_init(memory.bytes[:], MIN_RING_BUFFER_BYTES / 2, 0)
	testing.expect_value(t, problem, Venus_Problem.Ring_Buffer_Size_Invalid)
	_, problem = ring_init(memory.bytes[:], MAX_RING_BUFFER_BYTES * 2, 0)
	testing.expect_value(t, problem, Venus_Problem.Ring_Buffer_Size_Invalid)
	_, problem = ring_init(memory.bytes[:], 0, 0)
	testing.expect_value(t, problem, Venus_Problem.Ring_Buffer_Size_Invalid)
	_, problem = ring_init(memory.bytes[:], RING_TEST_BUFFER, 2)
	testing.expect_value(t, problem, Venus_Problem.Misaligned_Length)
	_, problem = ring_init(memory.bytes[:], RING_TEST_BUFFER, 128)
	testing.expect_value(t, problem, Venus_Problem.Ring_Memory_Too_Small)
	_, problem = ring_init(memory.bytes[1:], RING_TEST_BUFFER, 0)
	testing.expect_value(t, problem, Venus_Problem.Ring_Memory_Misaligned)
	_, problem = ring_init(memory.bytes[:RING_BUFFER_OFFSET + RING_TEST_BUFFER - 1], RING_TEST_BUFFER, 0)
	testing.expect_value(t, problem, Venus_Problem.Ring_Memory_Too_Small)

	// A ring starts with its control words at zero, as the renderer requires.
	for &byte_value in memory.bytes {
		byte_value = 0xFF
	}
	ring, init_problem := ring_init(memory.bytes[:], RING_TEST_BUFFER, 64)
	testing.expect_value(t, init_problem, Venus_Problem.None)
	testing.expect_value(t, byte_order.read_u32_little_endian(memory.bytes[:], RING_HEAD_OFFSET), u32(0))
	testing.expect_value(t, byte_order.read_u32_little_endian(memory.bytes[:], RING_TAIL_OFFSET), u32(0))
	testing.expect_value(t, byte_order.read_u32_little_endian(memory.bytes[:], RING_STATUS_OFFSET), u32(0))
	info := ring_create_info(&ring, 40, 0, 1_000_000)
	testing.expect_value(t, info.buffer_offset, u64(192))
	testing.expect_value(t, info.extra_offset, u64(192 + 4096))
	testing.expect_value(t, info.size, u64(192 + 4096 + 64))
	testing.expect_value(t, ring_create_info_check(info), Venus_Problem.None)
	moved := info
	moved.tail_offset = 4
	testing.expect_value(t, ring_create_info_check(moved), Venus_Problem.Ring_Memory_Misaligned)
	moved = info
	moved.extra_offset += 4
	testing.expect_value(t, ring_create_info_check(moved), Venus_Problem.Ring_Memory_Misaligned)
	moved = info
	moved.offset = 2
	testing.expect_value(t, ring_create_info_check(moved), Venus_Problem.Misaligned_Length)
}

@(test)
ring_wraps_around_and_refuses_a_full_write :: proc(t: ^testing.T) {
	memory: Ring_Memory
	ring, problem := ring_init(memory.bytes[:], RING_TEST_BUFFER, 0)
	testing.expect_value(t, problem, Venus_Problem.None)
	reader, reader_problem := ring_reader_init(memory.bytes[:], RING_TEST_BUFFER)
	testing.expect_value(t, reader_problem, Venus_Problem.None)

	chunk: [3000]u8
	pattern(chunk[:], 1)
	seqno, write_problem := ring_write(&ring, chunk[:])
	testing.expect_value(t, write_problem, Venus_Problem.None)
	testing.expect_value(t, seqno, u32(3000))
	reached, _ := ring_seqno_reached(&ring, seqno)
	testing.expect(t, !reached, "the renderer has not read the write yet")

	// The second write does not fit before the renderer reads: refused whole.
	second: [2000]u8
	pattern(second[:], 50)
	_, full := ring_write(&ring, second[:])
	testing.expect_value(t, full, Venus_Problem.Ring_Full)
	testing.expect_value(t, ring.tail, u32(3000))
	testing.expect_value(t, byte_order.read_u32_little_endian(memory.bytes[:], RING_TAIL_OFFSET), u32(3000))
	free, _ := ring_free_bytes(&ring)
	testing.expect_value(t, free, u32(1096))

	read_back: [4096]u8
	read, read_problem := ring_reader_read(&reader, read_back[:])
	testing.expect_value(t, read_problem, Venus_Problem.None)
	testing.expect_value(t, read, 3000)
	testing.expect(t, string(read_back[:3000]) == string(chunk[:]), "the first write must read back whole")
	reached, _ = ring_seqno_reached(&ring, seqno)
	testing.expect(t, reached, "the renderer has read the write")

	// The second write now fits and wraps past the end of the buffer.
	seqno, write_problem = ring_write(&ring, second[:])
	testing.expect_value(t, write_problem, Venus_Problem.None)
	testing.expect_value(t, seqno, u32(5000))
	buffer := memory.bytes[RING_BUFFER_OFFSET:][:RING_TEST_BUFFER]
	testing.expect_value(t, buffer[3000], second[0])
	testing.expect_value(t, buffer[0], second[1096])
	read, read_problem = ring_reader_read(&reader, read_back[:])
	testing.expect_value(t, read_problem, Venus_Problem.None)
	testing.expect_value(t, read, 2000)
	testing.expect(t, string(read_back[:2000]) == string(second[:]), "the wrapped write must read back whole")

	// A write of the whole buffer fits only when the ring is empty.
	whole: [RING_TEST_BUFFER]u8
	pattern(whole[:], 9)
	_, write_problem = ring_write(&ring, whole[:])
	testing.expect_value(t, write_problem, Venus_Problem.None)
	_, full = ring_write(&ring, whole[:4])
	testing.expect_value(t, full, Venus_Problem.Ring_Full)
	read, _ = ring_reader_read(&reader, read_back[:])
	testing.expect_value(t, read, int(RING_TEST_BUFFER))
	testing.expect(t, string(read_back[:]) == string(whole[:]), "a full-buffer write must read back whole")

	// Refusals: empty, unaligned, larger than the buffer.
	_, empty := ring_write(&ring, nil)
	testing.expect_value(t, empty, Venus_Problem.Stream_Empty)
	_, odd := ring_write(&ring, whole[:6])
	testing.expect_value(t, odd, Venus_Problem.Misaligned_Length)
	larger: [RING_TEST_BUFFER + 4]u8
	_, too_large := ring_write(&ring, larger[:])
	testing.expect_value(t, too_large, Venus_Problem.Stream_Too_Large)
}

@(test)
ring_counters_wrap_past_the_largest_u32 :: proc(t: ^testing.T) {
	memory: Ring_Memory
	ring, _ := ring_init(memory.bytes[:], RING_TEST_BUFFER, 0)
	reader, _ := ring_reader_init(memory.bytes[:], RING_TEST_BUFFER)
	start := max(u32) - 7 // 8 bytes before the counters wrap
	ring.tail = start
	reader.head = start
	byte_order.write_u32_little_endian(memory.bytes[:], RING_HEAD_OFFSET, start)
	byte_order.write_u32_little_endian(memory.bytes[:], RING_TAIL_OFFSET, start)

	chunk: [64]u8
	pattern(chunk[:], 3)
	seqno, problem := ring_write(&ring, chunk[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, seqno, u32(56))
	reached, _ := ring_seqno_reached(&ring, seqno)
	testing.expect(t, !reached, "a wrapped sequence number is not reached before the read")
	read_back: [64]u8
	read, _ := ring_reader_read(&reader, read_back[:])
	testing.expect_value(t, read, 64)
	testing.expect(t, read_back == chunk, "the bytes across the wrap of the counters must read back whole")
	reached, _ = ring_seqno_reached(&ring, seqno)
	testing.expect(t, reached, "the wrapped sequence number is reached after the read")
	reached, _ = ring_seqno_reached(&ring, start)
	testing.expect(t, reached, "an earlier sequence number stays reached")
}

@(test)
ring_refuses_a_hostile_renderer :: proc(t: ^testing.T) {
	memory: Ring_Memory
	ring, _ := ring_init(memory.bytes[:], RING_TEST_BUFFER, 0)
	chunk: [64]u8
	_, _ = ring_write(&ring, chunk[:])

	// A head ahead of the tail.
	byte_order.write_u32_little_endian(memory.bytes[:], RING_HEAD_OFFSET, 128)
	_, head_problem := ring_write(&ring, chunk[:])
	testing.expect_value(t, head_problem, Venus_Problem.Ring_Head_Invalid)
	_, free_problem := ring_free_bytes(&ring)
	testing.expect_value(t, free_problem, Venus_Problem.Ring_Head_Invalid)
	_, reached_problem := ring_seqno_reached(&ring, 64)
	testing.expect_value(t, reached_problem, Venus_Problem.Ring_Head_Invalid)
	testing.expect_value(t, ring.tail, u32(64))
	byte_order.write_u32_little_endian(memory.bytes[:], RING_HEAD_OFFSET, 0)

	// Unknown status bits, then the fatal bit.
	byte_order.write_u32_little_endian(memory.bytes[:], RING_STATUS_OFFSET, 8)
	_, status_problem := ring_write(&ring, chunk[:])
	testing.expect_value(t, status_problem, Venus_Problem.Ring_Status_Invalid)
	reader, _ := ring_reader_init(memory.bytes[:], RING_TEST_BUFFER)
	ring_reader_set_status(&reader, {.Alive, .Fatal})
	_, fatal := ring_write(&ring, chunk[:])
	testing.expect_value(t, fatal, Venus_Problem.Ring_Fatal)
	testing.expect_value(t, ring.tail, u32(64))

	// The idle bit asks the driver for vkNotifyRingMESA.
	ring_reader_set_status(&reader, {.Alive})
	notify, _ := ring_needs_notify(&ring)
	testing.expect(t, !notify, "an awake renderer needs no notification")
	ring_reader_set_status(&reader, {.Alive, .Idle})
	notify, _ = ring_needs_notify(&ring)
	testing.expect(t, notify, "an idle renderer needs a notification")

	// A reader that sees a tail more than one buffer ahead refuses it.
	byte_order.write_u32_little_endian(memory.bytes[:], RING_TAIL_OFFSET, RING_TEST_BUFFER + 4)
	read_back: [64]u8
	_, tail_problem := ring_reader_read(&reader, read_back[:])
	testing.expect_value(t, tail_problem, Venus_Problem.Ring_Tail_Invalid)
	byte_order.write_u32_little_endian(memory.bytes[:], RING_TAIL_OFFSET, 6)
	_, tail_problem = ring_reader_read(&reader, read_back[:])
	testing.expect_value(t, tail_problem, Venus_Problem.Ring_Tail_Invalid)
}

@(test)
ring_carries_a_command_stream_to_the_renderer :: proc(t: ^testing.T) {
	memory: Ring_Memory
	ring, _ := ring_init(memory.bytes[:], RING_TEST_BUFFER, 0)
	reader, _ := ring_reader_init(memory.bytes[:], RING_TEST_BUFFER)
	commands: [512]u8
	encoder := encoder_init(commands[:])
	for _ in 0 ..< 10 {
		testing.expect_value(t, encode_cmd_draw(&encoder, 20, 3, 1, 0, 0), Venus_Problem.None)
	}
	stream := encoder_bytes(&encoder)
	received: [RING_TEST_BUFFER]u8
	total := 0
	// Many rounds move the commands across the end of the buffer.
	for round in 0 ..< 40 {
		_, problem := ring_write(&ring, stream)
		testing.expectf(t, problem == .None, "round %d: %v", round, problem)
		read, _ := ring_reader_read(&reader, received[:])
		count, validate_problem := stream_validate(received[:read])
		testing.expect_value(t, validate_problem, Venus_Problem.None)
		testing.expect_value(t, count, 10)
		total += read
	}
	testing.expect_value(t, total, 40 * len(stream))
	testing.expect(t, total > int(RING_TEST_BUFFER), "the test must wrap the buffer")
}
