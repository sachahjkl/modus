package venus_vulkan

import "base:intrinsics"

// The Venus ring: a command ring in a shared blob resource, read by the
// renderer while the driver writes (Mesa vn_ring.c, virglrenderer vkr_ring.c).
// The layout is Mesa's: the head, the tail and the status each in their own
// 64-byte line, then the buffer, then the extra region.
//
// The head and the tail are free-running 32-bit byte counters: the byte at
// counter c is at offset c & (buffer_size - 1) of the buffer. The driver owns
// the tail and stores it with release order after it writes the bytes. The
// renderer owns the head and the status. The tail after a write is the
// sequence number of that write: the write is done when the head reaches it.

RING_HEAD_OFFSET :: 0
RING_TAIL_OFFSET :: 64
RING_STATUS_OFFSET :: 128
RING_BUFFER_OFFSET :: 192
MIN_RING_BUFFER_BYTES :: u32(4096)
MAX_RING_BUFFER_BYTES :: u32(1 << 24)

// VkRingStatusFlagBitsMESA, by bit position.
Ring_Status_Flag :: enum u32 {
	Idle  = 0,
	Fatal = 1,
	Alive = 2,
}

Ring_Status :: bit_set[Ring_Status_Flag; u32]

RING_STATUS_KNOWN_BITS :: u32(0x0000_0007)

// The driver side of one ring.
Ring :: struct {
	shared:      []u8,
	buffer_size: u32,
	extra_size:  u32,
	tail:        u32,
}

// The renderer side of one ring. The tests use it to stand for the host.
Ring_Reader :: struct {
	shared:      []u8,
	buffer_size: u32,
	head:        u32,
}

@(private = "file")
is_power_of_two :: proc "contextless" (value: u64) -> bool {
	return value != 0 && value & (value - 1) == 0
}

// ring_shared_bytes is the size of the shared memory of a ring.
ring_shared_bytes :: proc "contextless" (buffer_size, extra_size: u32) -> u64 {
	return u64(RING_BUFFER_OFFSET) + u64(buffer_size) + u64(extra_size)
}

@(private = "file")
ring_memory_check :: proc "contextless" (shared: []u8, buffer_size, extra_size: u32) -> Venus_Problem {
	if buffer_size < MIN_RING_BUFFER_BYTES || buffer_size > MAX_RING_BUFFER_BYTES || !is_power_of_two(u64(buffer_size)) {
		return .Ring_Buffer_Size_Invalid
	}
	if extra_size % 4 != 0 {
		return .Misaligned_Length
	}
	if uintptr(raw_data(shared)) % 4 != 0 {
		return .Ring_Memory_Misaligned
	}
	if u64(len(shared)) < ring_shared_bytes(buffer_size, extra_size) {
		return .Ring_Memory_Too_Small
	}
	return .None
}

// ring_create_info_check refuses a VkRingCreateInfoMESA that does not have
// the layout of this package inside its range of the resource.
ring_create_info_check :: proc "contextless" (info: Ring_Create_Info) -> Venus_Problem {
	if info.buffer_size < u64(MIN_RING_BUFFER_BYTES) || info.buffer_size > u64(MAX_RING_BUFFER_BYTES) || !is_power_of_two(info.buffer_size) {
		return .Ring_Buffer_Size_Invalid
	}
	if info.head_offset != RING_HEAD_OFFSET || info.tail_offset != RING_TAIL_OFFSET || info.status_offset != RING_STATUS_OFFSET || info.buffer_offset != RING_BUFFER_OFFSET {
		return .Ring_Memory_Misaligned
	}
	if info.offset % 4 != 0 || info.extra_size % 4 != 0 {
		return .Misaligned_Length
	}
	if info.extra_offset != info.buffer_offset + info.buffer_size {
		return .Ring_Memory_Misaligned
	}
	if info.size < info.extra_offset + info.extra_size {
		return .Ring_Memory_Too_Small
	}
	return .None
}

// ring_init prepares the shared memory of a new ring: the head, the tail and
// the status start at 0, as the renderer requires.
ring_init :: proc "contextless" (shared: []u8, buffer_size, extra_size: u32) -> (ring: Ring, problem: Venus_Problem) {
	if problem = ring_memory_check(shared, buffer_size, extra_size); problem != .None {
		return {}, problem
	}
	for index in 0 ..< RING_BUFFER_OFFSET {
		shared[index] = 0
	}
	return Ring{shared = shared, buffer_size = buffer_size, extra_size = extra_size}, .None
}

// ring_create_info describes the ring for vkCreateRingMESA, with the ring at
// offset of the blob resource.
ring_create_info :: proc "contextless" (ring: ^Ring, resource_id: u32, offset: u64, idle_timeout_nanoseconds: u64) -> Ring_Create_Info {
	return Ring_Create_Info{
		resource_id   = resource_id,
		offset        = offset,
		size          = ring_shared_bytes(ring.buffer_size, ring.extra_size),
		idle_timeout  = idle_timeout_nanoseconds,
		head_offset   = RING_HEAD_OFFSET,
		tail_offset   = RING_TAIL_OFFSET,
		status_offset = RING_STATUS_OFFSET,
		buffer_offset = RING_BUFFER_OFFSET,
		buffer_size   = u64(ring.buffer_size),
		extra_offset  = u64(RING_BUFFER_OFFSET) + u64(ring.buffer_size),
		extra_size    = u64(ring.extra_size),
	}
}

@(private = "file")
control_word :: proc "contextless" (shared: []u8, offset: int) -> ^u32 {
	return (^u32)(&shared[offset])
}

// ring_head loads the head that the renderer stored, and refuses a head that
// is ahead of the tail or more than one buffer behind it.
ring_head :: proc "contextless" (ring: ^Ring) -> (head: u32, problem: Venus_Problem) {
	head = intrinsics.atomic_load_explicit(control_word(ring.shared, RING_HEAD_OFFSET), .Acquire)
	if ring.tail - head > ring.buffer_size {
		return 0, .Ring_Head_Invalid
	}
	return head, .None
}

// ring_status loads the status that the renderer stored.
ring_status :: proc "contextless" (ring: ^Ring) -> (status: Ring_Status, problem: Venus_Problem) {
	word := intrinsics.atomic_load_explicit(control_word(ring.shared, RING_STATUS_OFFSET), .Seq_Cst)
	if word & ~RING_STATUS_KNOWN_BITS != 0 {
		return {}, .Ring_Status_Invalid
	}
	return transmute(Ring_Status)word, .None
}

// ring_free_bytes is the room for the next write.
ring_free_bytes :: proc "contextless" (ring: ^Ring) -> (free: u32, problem: Venus_Problem) {
	head := ring_head(ring) or_return
	return ring.buffer_size - (ring.tail - head), .None
}

// ring_write copies one or more whole commands into the ring and publishes
// them. A write that does not fit is refused whole: the caller waits for the
// renderer, or sends the commands through Submit_3D.
ring_write :: proc "contextless" (ring: ^Ring, commands: []u8) -> (seqno: u32, problem: Venus_Problem) {
	if len(commands) == 0 {
		return 0, .Stream_Empty
	}
	if len(commands) % 4 != 0 {
		return 0, .Misaligned_Length
	}
	if u64(len(commands)) > u64(ring.buffer_size) {
		return 0, .Stream_Too_Large
	}
	status := ring_status(ring) or_return
	if .Fatal in status {
		return 0, .Ring_Fatal
	}
	free := ring_free_bytes(ring) or_return
	if u32(len(commands)) > free {
		return 0, .Ring_Full
	}
	buffer := ring.shared[RING_BUFFER_OFFSET:][:ring.buffer_size]
	offset := int(ring.tail & (ring.buffer_size - 1))
	first := min(len(commands), int(ring.buffer_size) - offset)
	copy(buffer[offset:offset + first], commands[:first])
	copy(buffer[:len(commands) - first], commands[first:])
	ring.tail += u32(len(commands))
	// Full fence before publishing tail flushes Write_Combining store buffers
	// so command bytes are globally visible before tail advances; full fence
	// after storing tail closes the Store-Load Dekker race before reading
	// RING_STATUS_OFFSET for vkNotifyRingMESA.
	intrinsics.atomic_thread_fence(.Seq_Cst)
	intrinsics.atomic_store_explicit(control_word(ring.shared, RING_TAIL_OFFSET), ring.tail, .Release)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	return ring.tail, .None
}

// ring_needs_notify says whether the renderer sleeps: after a write, the
// driver then sends vkNotifyRingMESA through Submit_3D.
ring_needs_notify :: proc "contextless" (ring: ^Ring) -> (notify: bool, problem: Venus_Problem) {
	status := ring_status(ring) or_return
	return .Idle in status, .None
}

// ring_seqno_reached says whether the renderer has read the write whose
// sequence number is seqno. The comparison follows vn_ring_ge_seqno: both
// counters wrap, and the tail of the driver tells their order.
ring_seqno_reached :: proc "contextless" (ring: ^Ring, seqno: u32) -> (reached: bool, problem: Venus_Problem) {
	head := ring_head(ring) or_return
	if head >= seqno {
		return ring.tail >= head || ring.tail < seqno, .None
	}
	return ring.tail >= head && ring.tail < seqno, .None
}

// ring_reader_init opens the renderer side of a ring that ring_init prepared.
ring_reader_init :: proc "contextless" (shared: []u8, buffer_size: u32) -> (reader: Ring_Reader, problem: Venus_Problem) {
	if problem = ring_memory_check(shared, buffer_size, 0); problem != .None {
		return {}, problem
	}
	return Ring_Reader{shared = shared, buffer_size = buffer_size}, .None
}

// ring_reader_read copies the published bytes, at most len(destination)
// rounded down to whole words, and stores the new head.
ring_reader_read :: proc "contextless" (reader: ^Ring_Reader, destination: []u8) -> (read: int, problem: Venus_Problem) {
	read = ring_reader_take(reader, destination) or_return
	ring_reader_release(reader)
	return read, .None
}

// ring_reader_release stores the head after the renderer ran the commands
// that it took, as vkr_ring does: the replies of those commands are then in
// the reply stream when the driver sees the head.
ring_reader_release :: proc "contextless" (reader: ^Ring_Reader) {
	intrinsics.atomic_store_explicit(control_word(reader.shared, RING_HEAD_OFFSET), reader.head, .Release)
}

// ring_reader_take copies the published bytes as ring_reader_read does, and
// keeps the stored head until ring_reader_release.
ring_reader_take :: proc "contextless" (reader: ^Ring_Reader, destination: []u8) -> (read: int, problem: Venus_Problem) {
	tail := intrinsics.atomic_load_explicit(control_word(reader.shared, RING_TAIL_OFFSET), .Acquire)
	available := tail - reader.head
	if available > reader.buffer_size || available % 4 != 0 {
		return 0, .Ring_Tail_Invalid
	}
	read = min(int(available), len(destination) & ~int(3))
	buffer := reader.shared[RING_BUFFER_OFFSET:][:reader.buffer_size]
	offset := int(reader.head & (reader.buffer_size - 1))
	first := min(read, int(reader.buffer_size) - offset)
	copy(destination[:first], buffer[offset:offset + first])
	copy(destination[first:read], buffer[:read - first])
	reader.head += u32(read)
	return read, .None
}

// ring_reader_set_status stores the status word of the renderer side.
ring_reader_set_status :: proc "contextless" (reader: ^Ring_Reader, status: Ring_Status) {
	intrinsics.atomic_store_explicit(control_word(reader.shared, RING_STATUS_OFFSET), transmute(u32)status, .Seq_Cst)
}
