#+build !freestanding
package ring

import "core:testing"

// A byte that no compartment of these cases holds, to see each byte that an
// operation wrote where it must not.
@(private = "file")
UNTOUCHED_BYTE :: u8(0xA5)

// The size of the compartment of a log record: the compartment word and 256 bytes.
@(private = "file")
LOG_COMPARTMENT_SIZE :: 320

@(private = "file")
compartment_memory :: proc(page_count: u64) -> []u8 {
	return make([]u8, page_count * PAGE_SIZE, context.temp_allocator)
}

// A compartment whose every byte is its number, so that a torn or shifted copy
// shows.
@(private = "file")
numbered_compartment :: proc(number: u8, compartment_size: u32) -> []u8 {
	compartment := make([]u8, compartment_size, context.temp_allocator)
	for &value in compartment {
		value = number
	}
	return compartment
}

// compartment_open refuses each size of a compartment that is not one, and each count
// of pages that no ring of compartments has: a size of 0, below one Record, not
// a multiple of a Record, one Record past the limit and the largest; a
// count of no page, one page below and one page above a ring, and the
// largest count. A ring of compartments of 64 bytes is the ring of `open`, at
// each capacity. The usual sizes are the last cases.
@(test)
compartment_open_refuses_each_size_that_no_ring_of_compartments_has :: proc(t: ^testing.T) {
	memory := compartment_memory(compartment_pages(CAPACITY, COMPARTMENT_SIZE_LIMIT))
	address := raw_data(memory)
	for size in ([?]u32{0, 1, size_of(Record) - 1, size_of(Record) + 8, LOG_COMPARTMENT_SIZE - 1, COMPARTMENT_SIZE_LIMIT + size_of(Record), max(u32)}) {
		_, ok := compartment_open(address, compartment_pages(CAPACITY, size_of(Record)), size)
		testing.expectf(t, !ok, "the size of a compartment %d is taken", size)
	}
	_, nil_ok := compartment_open(nil, compartment_pages(CAPACITY, LOG_COMPARTMENT_SIZE), LOG_COMPARTMENT_SIZE)
	testing.expect(t, !nil_ok)
	smallest := compartment_pages(CAPACITY, LOG_COMPARTMENT_SIZE)
	for page_count in ([?]u64{0, 1, smallest - 1, smallest + 1, compartment_pages(CAPACITY_LIMIT, LOG_COMPARTMENT_SIZE) + 1, max(u64)}) {
		_, ok := compartment_open(address, page_count, LOG_COMPARTMENT_SIZE)
		testing.expectf(t, !ok, "%d pages are taken for compartments of %d bytes", page_count, LOG_COMPARTMENT_SIZE)
	}
	// The ring of open, at each capacity.
	for capacity := u32(CAPACITY); capacity <= CAPACITY_LIMIT; capacity *= 2 {
		testing.expect_value(t, compartment_pages(capacity, size_of(Record)), pages(capacity))
		compartments, compartments_ok := compartment_open(address, pages(capacity), size_of(Record))
		records, records_ok := open(address, pages(capacity))
		testing.expect(t, compartments_ok && records_ok && compartment_capacity(&compartments.commands) == capacity && uintptr(rawptr(compartments.completions.records)) == uintptr(rawptr(records.completions.records)))
	}
	// The ring of a log record at 256 compartments: 25 pages; the largest compartment.
	testing.expect_value(t, compartment_pages(256, LOG_COMPARTMENT_SIZE), 25)
	log_ring, log_ok := compartment_open(address, 25, LOG_COMPARTMENT_SIZE)
	testing.expect(t, log_ok && compartment_capacity(&log_ring.commands) == 256 && log_ring.commands.compartment_size == LOG_COMPARTMENT_SIZE)
	largest, largest_ok := compartment_open(address, compartment_pages(CAPACITY, COMPARTMENT_SIZE_LIMIT), COMPARTMENT_SIZE_LIMIT)
	testing.expect(t, largest_ok && compartment_capacity(&largest.commands) == CAPACITY)
}

// A full queue of compartments refuses a push and changes nothing; an empty one
// gives no compartment; a compartment of another size than the queue is refused at
// the push and at the pop, with nothing written and the counters as they
// were. Then each compartment comes out whole, in order, past the end of the
// counters.
@(test)
a_queue_of_compartments_moves_each_compartment_whole_and_in_order :: proc(t: ^testing.T) {
	page_count := compartment_pages(CAPACITY, LOG_COMPARTMENT_SIZE)
	memory := compartment_memory(page_count)
	for &value in memory[PAGE_SIZE:] {
		value = UNTOUCHED_BYTE
	}
	stream, ok := compartment_open(raw_data(memory), page_count, LOG_COMPARTMENT_SIZE)
	testing.expect(t, ok)
	if !ok {
		return
	}
	queue := &stream.commands
	into := make([]u8, LOG_COMPARTMENT_SIZE, context.temp_allocator)
	testing.expect(t, !compartment_pop(queue, into))
	// Sizes that are not the size of a compartment.
	testing.expect(t, !compartment_push(queue, numbered_compartment(1, LOG_COMPARTMENT_SIZE - 1)))
	testing.expect(t, !compartment_push(queue, numbered_compartment(1, LOG_COMPARTMENT_SIZE + 1)))
	testing.expect(t, !compartment_push(queue, nil))
	testing.expect(t, queue.counters.write == 0 && memory[PAGE_SIZE] == UNTOUCHED_BYTE)
	// Fill the queue, then one more.
	for number in 0 ..< CAPACITY {
		testing.expect(t, compartment_push(queue, numbered_compartment(u8(number + 1), LOG_COMPARTMENT_SIZE)))
	}
	testing.expect(t, compartment_full(queue) && compartment_count(queue) == CAPACITY)
	testing.expect(t, !compartment_push(queue, numbered_compartment(0xEE, LOG_COMPARTMENT_SIZE)))
	testing.expect_value(t, queue.counters.write, u32(CAPACITY))
	// The completions after the compartments are untouched.
	completions := ([^]u8)(rawptr(stream.completions.records))
	testing.expect_value(t, completions[0], UNTOUCHED_BYTE)
	testing.expect_value(t, memory[PAGE_SIZE + CAPACITY * LOG_COMPARTMENT_SIZE - 1], u8(CAPACITY))
	// A pop into memory of another size takes nothing.
	short := make([]u8, LOG_COMPARTMENT_SIZE - 1, context.temp_allocator)
	testing.expect(t, !compartment_pop(queue, short) && queue.counters.read == 0)
	for number in 0 ..< CAPACITY {
		testing.expect(t, compartment_pop(queue, into))
		for value in into {
			if value != u8(number + 1) {
				testing.expectf(t, false, "the compartment %d is not whole", number)
				break
			}
		}
	}
	testing.expect(t, !compartment_pop(queue, into) && !compartment_full(queue))
}

// Counters that the other side wrote false: more compartments than the queue
// holds give no compartment, and the read counter stays; the counters at the top
// of their type wrap to the first compartment.
@(test)
hostile_counters_of_a_queue_of_compartments_are_refused :: proc(t: ^testing.T) {
	page_count := compartment_pages(CAPACITY, LOG_COMPARTMENT_SIZE)
	memory := compartment_memory(page_count)
	stream, _ := compartment_open(raw_data(memory), page_count, LOG_COMPARTMENT_SIZE)
	queue := &stream.commands
	into := make([]u8, LOG_COMPARTMENT_SIZE, context.temp_allocator)
	queue.counters.write = CAPACITY + 1
	testing.expect(t, !compartment_pop(queue, into) && queue.counters.read == 0)
	queue.counters.write = max(u32)
	testing.expect(t, !compartment_pop(queue, into) && queue.counters.read == 0)
	testing.expect_value(t, compartment_count(queue), u32(CAPACITY))
	// At the top of the type: the write after max(u32) is at the compartment 0.
	queue.counters.write, queue.counters.read = max(u32), max(u32)
	testing.expect(t, compartment_push(queue, numbered_compartment(7, LOG_COMPARTMENT_SIZE)) && queue.counters.write == 0)
	testing.expect(t, memory[PAGE_SIZE + (CAPACITY - 1) * LOG_COMPARTMENT_SIZE] == 7)
	testing.expect(t, compartment_pop(queue, into) && into[0] == 7 && queue.counters.read == 0)
}
