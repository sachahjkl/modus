package ring

import "base:intrinsics"

// The ring of compartments: a ring whose command queue holds compartments of a size
// that both sides compute, and whose completion queue holds the records of
// 64 bytes of each ring (src/md/features/module_outputs.md, "The ring and
// its records"). An output ring has this form: one compartment is the compartment word
// and one record of a record output.
//
// The memory of a ring of compartments:
//   page 0        the head (Head), as in each ring
//   after it      the command compartments, then the completion records, with
//                 no gap between them
//
// The memory has 1 + ceil(capacity * (compartment_size + 64) / 4096) pages, so a
// ring of compartments of 64 bytes is the ring of `open`, with its capacity. As
// for a ring, the capacity and the size of a compartment are not in the shared
// memory: each side computes them, from the size that the kernel gives and
// from the record description that it holds.

// The bytes of the largest compartment: one page. A record of a record output
// has at most 256 bytes, so its compartment has at most 320.
COMPARTMENT_SIZE_LIMIT :: PAGE_SIZE

// One queue of compartments, as one side sees it. This record is not in the
// shared memory.
Compartment_Queue :: struct {
	counters:         ^Counters, // The counters of the queue, in the shared head.
	compartments:     [^]u8, // The first byte of the first compartment, in the shared memory.
	compartment_size: u32, // The bytes of one compartment: a multiple of the size of a Record.
	mask:             u32, // The capacity - 1.
}

// A ring of compartments that is mapped. head is nil for no ring.
Compartment_Ring :: struct {
	head:        ^Head, // The shared head.
	commands:    Compartment_Queue, // The compartments: the writer of the stream pushes, the reader pops.
	completions: Queue, // The completions: the reader pushes, the writer pops.
}

// compartment_pages gives the pages of a ring of compartments with a capacity and a
// size of a compartment.
//
// Example: `compartment_pages(256, 64)` is 9, as `pages(256)`; `compartment_pages(256,
// 320)` is 25: the head, 20 pages of compartments and 4 of completions.
compartment_pages :: proc "contextless" (capacity: u32, compartment_size: u32) -> u64 {
	bytes := u64(capacity) * (u64(compartment_size) + size_of(Record))
	return 1 + (bytes + PAGE_SIZE - 1) / PAGE_SIZE
}

// compartment_size_valid says if a size is the size of a compartment: a multiple of
// the size of a Record, from one Record to COMPARTMENT_SIZE_LIMIT.
compartment_size_valid :: proc "contextless" (compartment_size: u32) -> bool {
	return compartment_size >= size_of(Record) && compartment_size <= COMPARTMENT_SIZE_LIMIT && compartment_size % size_of(Record) == 0
}

// compartment_open gives the ring of compartments in mapped memory of page_count
// pages, for compartments of compartment_size bytes. false: no ring has this size: the
// size of a compartment is not one that compartment_size_valid takes, or the count of
// pages is the compartment_pages of no power of two from CAPACITY to
// CAPACITY_LIMIT. It reads no byte of the memory.
//
// ```odin
// size := output.compartment_size(description.size)
// stream, ok := ring.compartment_open(address, page_count, size)
// ```
compartment_open :: proc "contextless" (memory: rawptr, page_count: u64, compartment_size: u32) -> (ring: Compartment_Ring, ok: bool) {
	if memory == nil || !compartment_size_valid(compartment_size) {
		return {}, false
	}
	for capacity := u32(CAPACITY); capacity <= CAPACITY_LIMIT; capacity *= 2 {
		if compartment_pages(capacity, compartment_size) != page_count {
			continue
		}
		head := (^Head)(memory)
		compartments := ([^]u8)(uintptr(memory) + PAGE_SIZE)
		completions := ([^]Record)(uintptr(memory) + PAGE_SIZE + uintptr(capacity) * uintptr(compartment_size))
		return {head = head, commands = {&head.commands, compartments, compartment_size, capacity - 1}, completions = {&head.completions, completions, capacity - 1}}, true
	}
	return {}, false
}

// compartment_capacity gives the compartments that a queue holds when it is full.
compartment_capacity :: proc "contextless" (queue: ^Compartment_Queue) -> u32 {
	return queue.mask + 1
}

// compartment_count gives the compartments that wait in a queue, at most the capacity,
// as `count` does for a queue of records.
compartment_count :: proc "contextless" (queue: ^Compartment_Queue) -> u32 {
	return min(intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed) - intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed), queue.mask + 1)
}

// compartment_full says if a push into a queue of compartments would be refused now.
// The writer of a record output calls it on each of its rings before a
// write, so that a write is whole or refused.
compartment_full :: proc "contextless" (queue: ^Compartment_Queue) -> bool {
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	return write - intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire) > queue.mask
}

// compartment_push copies one compartment at the end of a queue. false: the queue is
// full, or compartment does not have the size of a compartment; nothing is written.
// The side that writes the queue calls it; it wakes no reader.
compartment_push :: proc "contextless" (queue: ^Compartment_Queue, compartment: []u8) -> bool {
	if len(compartment) != int(queue.compartment_size) {
		return false
	}
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	// The same test as compartment_full, on the one read of the counter that the
	// compartment and the new count use.
	if write - intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire) > queue.mask {
		return false
	}
	at := int(write & queue.mask) * int(queue.compartment_size)
	intrinsics.mem_copy_non_overlapping(&queue.compartments[at], raw_data(compartment), len(compartment))
	// The other side, on another processor, sees the compartment before the count.
	intrinsics.atomic_store_explicit(&queue.counters.write, write + 1, .Release)
	return true
}

// compartment_pop copies the first compartment of a queue into into, private memory of
// the reader, and takes it. ok is false when the queue is empty, when the
// counters say more compartments than the queue holds, and when into does not
// have the size of a compartment: the counters then stay as they are. The reader
// checks the copy, never the shared bytes, which the writer can change.
compartment_pop :: proc "contextless" (queue: ^Compartment_Queue, into: []u8) -> (ok: bool) {
	if len(into) != int(queue.compartment_size) {
		return false
	}
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Acquire)
	if write == read || write - read > queue.mask + 1 {
		return false
	}
	at := int(read & queue.mask) * int(queue.compartment_size)
	intrinsics.mem_copy_non_overlapping(raw_data(into), &queue.compartments[at], len(into))
	intrinsics.atomic_store_explicit(&queue.counters.read, read + 1, .Release)
	return true
}
