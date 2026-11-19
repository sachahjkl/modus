#+build !freestanding
package ring

import "core:testing"

// A byte that no place of these cases holds, to see each byte that an
// operation wrote where it must not.
@(private = "file")
UNTOUCHED_BYTE :: u8(0xA5)

// The size of the place of a log record: the place word and 256 bytes.
@(private = "file")
LOG_PLACE_SIZE :: 320

@(private = "file")
place_memory :: proc(page_count: u64) -> []u8 {
	return make([]u8, page_count * PAGE_SIZE, context.temp_allocator)
}

// A place whose every byte is its number, so that a torn or shifted copy
// shows.
@(private = "file")
numbered_place :: proc(number: u8, place_size: u32) -> []u8 {
	place := make([]u8, place_size, context.temp_allocator)
	for &value in place {
		value = number
	}
	return place
}

// place_open refuses each size of a place that is not one, and each count
// of pages that no ring of places has: a size of 0, below one Record, not
// a multiple of a Record, one Record past the limit and the largest; a
// count of no page, one page below and one page above a ring, and the
// largest count. A ring of places of 64 bytes is the ring of `open`, at
// each capacity. The usual sizes are the last cases.
@(test)
place_open_refuses_each_size_that_no_ring_of_places_has :: proc(t: ^testing.T) {
	memory := place_memory(place_pages(CAPACITY, PLACE_SIZE_LIMIT))
	address := raw_data(memory)
	for size in ([?]u32{0, 1, size_of(Record) - 1, size_of(Record) + 8, LOG_PLACE_SIZE - 1, PLACE_SIZE_LIMIT + size_of(Record), max(u32)}) {
		_, ok := place_open(address, place_pages(CAPACITY, size_of(Record)), size)
		testing.expectf(t, !ok, "the size of a place %d is taken", size)
	}
	_, nil_ok := place_open(nil, place_pages(CAPACITY, LOG_PLACE_SIZE), LOG_PLACE_SIZE)
	testing.expect(t, !nil_ok)
	smallest := place_pages(CAPACITY, LOG_PLACE_SIZE)
	for page_count in ([?]u64{0, 1, smallest - 1, smallest + 1, place_pages(CAPACITY_LIMIT, LOG_PLACE_SIZE) + 1, max(u64)}) {
		_, ok := place_open(address, page_count, LOG_PLACE_SIZE)
		testing.expectf(t, !ok, "%d pages are taken for places of %d bytes", page_count, LOG_PLACE_SIZE)
	}
	// The ring of open, at each capacity.
	for capacity := u32(CAPACITY); capacity <= CAPACITY_LIMIT; capacity *= 2 {
		testing.expect_value(t, place_pages(capacity, size_of(Record)), pages(capacity))
		places, places_ok := place_open(address, pages(capacity), size_of(Record))
		records, records_ok := open(address, pages(capacity))
		testing.expect(t, places_ok && records_ok && place_capacity(&places.commands) == capacity && uintptr(rawptr(places.completions.records)) == uintptr(rawptr(records.completions.records)))
	}
	// The ring of a log record at 256 places: 25 pages; the largest place.
	testing.expect_value(t, place_pages(256, LOG_PLACE_SIZE), 25)
	log_ring, log_ok := place_open(address, 25, LOG_PLACE_SIZE)
	testing.expect(t, log_ok && place_capacity(&log_ring.commands) == 256 && log_ring.commands.place_size == LOG_PLACE_SIZE)
	largest, largest_ok := place_open(address, place_pages(CAPACITY, PLACE_SIZE_LIMIT), PLACE_SIZE_LIMIT)
	testing.expect(t, largest_ok && place_capacity(&largest.commands) == CAPACITY)
}

// A full queue of places refuses a push and changes nothing; an empty one
// gives no place; a place of another size than the queue is refused at
// the push and at the pop, with nothing written and the counters as they
// were. Then each place comes out whole, in order, past the end of the
// counters.
@(test)
a_queue_of_places_moves_each_place_whole_and_in_order :: proc(t: ^testing.T) {
	page_count := place_pages(CAPACITY, LOG_PLACE_SIZE)
	memory := place_memory(page_count)
	for &value in memory[PAGE_SIZE:] {
		value = UNTOUCHED_BYTE
	}
	stream, ok := place_open(raw_data(memory), page_count, LOG_PLACE_SIZE)
	testing.expect(t, ok)
	if !ok {
		return
	}
	queue := &stream.commands
	into := make([]u8, LOG_PLACE_SIZE, context.temp_allocator)
	testing.expect(t, !place_pop(queue, into))
	// Sizes that are not the size of a place.
	testing.expect(t, !place_push(queue, numbered_place(1, LOG_PLACE_SIZE - 1)))
	testing.expect(t, !place_push(queue, numbered_place(1, LOG_PLACE_SIZE + 1)))
	testing.expect(t, !place_push(queue, nil))
	testing.expect(t, queue.counters.write == 0 && memory[PAGE_SIZE] == UNTOUCHED_BYTE)
	// Fill the queue, then one more.
	for number in 0 ..< CAPACITY {
		testing.expect(t, place_push(queue, numbered_place(u8(number + 1), LOG_PLACE_SIZE)))
	}
	testing.expect(t, place_full(queue) && place_count(queue) == CAPACITY)
	testing.expect(t, !place_push(queue, numbered_place(0xEE, LOG_PLACE_SIZE)))
	testing.expect_value(t, queue.counters.write, u32(CAPACITY))
	// The completions after the places are untouched.
	completions := ([^]u8)(rawptr(stream.completions.records))
	testing.expect_value(t, completions[0], UNTOUCHED_BYTE)
	testing.expect_value(t, memory[PAGE_SIZE + CAPACITY * LOG_PLACE_SIZE - 1], u8(CAPACITY))
	// A pop into memory of another size takes nothing.
	short := make([]u8, LOG_PLACE_SIZE - 1, context.temp_allocator)
	testing.expect(t, !place_pop(queue, short) && queue.counters.read == 0)
	for number in 0 ..< CAPACITY {
		testing.expect(t, place_pop(queue, into))
		for value in into {
			if value != u8(number + 1) {
				testing.expectf(t, false, "the place %d is not whole", number)
				break
			}
		}
	}
	testing.expect(t, !place_pop(queue, into) && !place_full(queue))
}

// Counters that the other side wrote false: more places than the queue
// holds give no place, and the read counter stays; the counters at the top
// of their type wrap to the first place.
@(test)
hostile_counters_of_a_queue_of_places_are_refused :: proc(t: ^testing.T) {
	page_count := place_pages(CAPACITY, LOG_PLACE_SIZE)
	memory := place_memory(page_count)
	stream, _ := place_open(raw_data(memory), page_count, LOG_PLACE_SIZE)
	queue := &stream.commands
	into := make([]u8, LOG_PLACE_SIZE, context.temp_allocator)
	queue.counters.write = CAPACITY + 1
	testing.expect(t, !place_pop(queue, into) && queue.counters.read == 0)
	queue.counters.write = max(u32)
	testing.expect(t, !place_pop(queue, into) && queue.counters.read == 0)
	testing.expect_value(t, place_count(queue), u32(CAPACITY))
	// At the top of the type: the write after max(u32) is at the place 0.
	queue.counters.write, queue.counters.read = max(u32), max(u32)
	testing.expect(t, place_push(queue, numbered_place(7, LOG_PLACE_SIZE)) && queue.counters.write == 0)
	testing.expect(t, memory[PAGE_SIZE + (CAPACITY - 1) * LOG_PLACE_SIZE] == 7)
	testing.expect(t, place_pop(queue, into) && into[0] == 7 && queue.counters.read == 0)
}
