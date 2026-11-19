package ring

import "base:intrinsics"

// The ring of places: a ring whose command queue holds places of a size
// that both sides compute, and whose completion queue holds the records of
// 64 bytes of each ring (src/md/features/module_outputs.md, "The ring and
// its records"). An output ring has this form: one place is the place word
// and one record of a record output.
//
// The memory of a ring of places:
//   page 0        the head (Head), as in each ring
//   after it      the command places, then the completion records, with
//                 no gap between them
//
// The memory has 1 + ceil(capacity * (place_size + 64) / 4096) pages, so a
// ring of places of 64 bytes is the ring of `open`, with its capacity. As
// for a ring, the capacity and the size of a place are not in the shared
// memory: each side computes them, from the size that the kernel gives and
// from the record description that it holds.

// The bytes of the largest place: one page. A record of a record output
// has at most 256 bytes, so its place has at most 320.
PLACE_SIZE_LIMIT :: PAGE_SIZE

// One queue of places, as one side sees it. This record is not in the
// shared memory.
Place_Queue :: struct {
	counters:   ^Counters, // The counters of the queue, in the shared head.
	places:     [^]u8, // The first byte of the first place, in the shared memory.
	place_size: u32, // The bytes of one place: a multiple of the size of a Record.
	mask:       u32, // The capacity - 1.
}

// A ring of places that is mapped. head is nil for no ring.
Place_Ring :: struct {
	head:        ^Head, // The shared head.
	commands:    Place_Queue, // The places: the writer of the stream pushes, the reader pops.
	completions: Queue, // The completions: the reader pushes, the writer pops.
}

// place_pages gives the pages of a ring of places with a capacity and a
// size of a place.
//
// Example: `place_pages(256, 64)` is 9, as `pages(256)`; `place_pages(256,
// 320)` is 25: the head, 20 pages of places and 4 of completions.
place_pages :: proc "contextless" (capacity: u32, place_size: u32) -> u64 {
	bytes := u64(capacity) * (u64(place_size) + size_of(Record))
	return 1 + (bytes + PAGE_SIZE - 1) / PAGE_SIZE
}

// place_size_valid says if a size is the size of a place: a multiple of
// the size of a Record, from one Record to PLACE_SIZE_LIMIT.
place_size_valid :: proc "contextless" (place_size: u32) -> bool {
	return place_size >= size_of(Record) && place_size <= PLACE_SIZE_LIMIT && place_size % size_of(Record) == 0
}

// place_open gives the ring of places in mapped memory of page_count
// pages, for places of place_size bytes. false: no ring has this size: the
// size of a place is not one that place_size_valid takes, or the count of
// pages is the place_pages of no power of two from CAPACITY to
// CAPACITY_LIMIT. It reads no byte of the memory.
//
// ```odin
// size := output.place_size(description.size)
// stream, ok := ring.place_open(address, page_count, size)
// ```
place_open :: proc "contextless" (memory: rawptr, page_count: u64, place_size: u32) -> (ring: Place_Ring, ok: bool) {
	if memory == nil || !place_size_valid(place_size) {
		return {}, false
	}
	for capacity := u32(CAPACITY); capacity <= CAPACITY_LIMIT; capacity *= 2 {
		if place_pages(capacity, place_size) != page_count {
			continue
		}
		head := (^Head)(memory)
		places := ([^]u8)(uintptr(memory) + PAGE_SIZE)
		completions := ([^]Record)(uintptr(memory) + PAGE_SIZE + uintptr(capacity) * uintptr(place_size))
		return {head = head, commands = {&head.commands, places, place_size, capacity - 1}, completions = {&head.completions, completions, capacity - 1}}, true
	}
	return {}, false
}

// place_capacity gives the places that a queue holds when it is full.
place_capacity :: proc "contextless" (queue: ^Place_Queue) -> u32 {
	return queue.mask + 1
}

// place_count gives the places that wait in a queue, at most the capacity,
// as `count` does for a queue of records.
place_count :: proc "contextless" (queue: ^Place_Queue) -> u32 {
	return min(intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed) - intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed), queue.mask + 1)
}

// place_full says if a push into a queue of places would be refused now.
// The writer of a record output calls it on each of its rings before a
// write, so that a write is whole or refused.
place_full :: proc "contextless" (queue: ^Place_Queue) -> bool {
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	return write - intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire) > queue.mask
}

// place_push copies one place at the end of a queue. false: the queue is
// full, or place does not have the size of a place; nothing is written.
// The side that writes the queue calls it; it wakes no reader.
place_push :: proc "contextless" (queue: ^Place_Queue, place: []u8) -> bool {
	if len(place) != int(queue.place_size) {
		return false
	}
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	// The same test as place_full, on the one read of the counter that the
	// place and the new count use.
	if write - intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire) > queue.mask {
		return false
	}
	at := int(write & queue.mask) * int(queue.place_size)
	intrinsics.mem_copy_non_overlapping(&queue.places[at], raw_data(place), len(place))
	// The other side, on another processor, sees the place before the count.
	intrinsics.atomic_store_explicit(&queue.counters.write, write + 1, .Release)
	return true
}

// place_pop copies the first place of a queue into into, private memory of
// the reader, and takes it. ok is false when the queue is empty, when the
// counters say more places than the queue holds, and when into does not
// have the size of a place: the counters then stay as they are. The reader
// checks the copy, never the shared bytes, which the writer can change.
place_pop :: proc "contextless" (queue: ^Place_Queue, into: []u8) -> (ok: bool) {
	if len(into) != int(queue.place_size) {
		return false
	}
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Acquire)
	if write == read || write - read > queue.mask + 1 {
		return false
	}
	at := int(read & queue.mask) * int(queue.place_size)
	intrinsics.mem_copy_non_overlapping(raw_data(into), &queue.places[at], len(into))
	intrinsics.atomic_store_explicit(&queue.counters.read, read + 1, .Release)
	return true
}
