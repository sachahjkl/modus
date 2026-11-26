#+build !freestanding
#+build !modus
package system

import "core:testing"
import "modus:contract/ring"

// The queue of these cases: the smallest ring, in memory of the test.
@(private = "file")
room_ring_of :: proc(t: ^testing.T, memory: []u64) -> ring.Ring {
	opened, ok := ring.open(raw_data(memory), ring.PAGE_COUNT)
	testing.expect(t, ok)
	return opened
}

@(private = "file")
room_fill :: proc(queue: ^ring.Queue, count: u32) {
	for _ in 0 ..< count {
		ring.push(queue, {kind = 1})
	}
}

// A writer that needs two places and finds one waits on the count of the
// records read, with the value that it judged the room from: the wait does
// not end before the reader takes a record, and ends when it takes one.
@(test)
a_writer_that_needs_two_places_and_finds_one_waits_for_a_read :: proc(t: ^testing.T) {
	memory := make([]u64, ring.PAGE_COUNT * ring.PAGE_SIZE / size_of(u64))
	defer delete(memory)
	opened := room_ring_of(t, memory)
	queue := &opened.commands
	capacity := ring.capacity(queue)
	room_fill(queue, capacity - 1) // One place is free.

	wait: Wait
	wait_room_for(&wait, queue, 2)
	testing.expect(t, !wait.full, "one place for two records: the writer must wait")
	testing.expect_value(t, wait.count, 1)
	testing.expect_value(t, wait.inline_words[0].address, u64(uintptr(&queue.counters.read)))
	testing.expect_value(t, u32(wait.inline_words[0].value), queue.counters.read)
	testing.expect_value(t, wait.inline_parts[0].flag, &queue.counters.writer_waits)
	testing.expect_value(t, wait.inline_parts[0].other_flag, &queue.counters.reader_waits)

	// wait_room ends at once on the same queue: the loop with no wait.
	not_full: Wait
	wait_room(&not_full, queue)
	testing.expect(t, not_full.inline_words[0].value != u64(queue.counters.read), "wait_room does not hold a writer that finds one place")

	// The reader takes one record: the word changes, the wait ends.
	_, popped := ring.pop(queue)
	testing.expect(t, popped)
	testing.expect(t, u64(queue.counters.read) != wait.inline_words[0].value)
	again: Wait
	wait_room_for(&again, queue, 2)
	testing.expect(t, again.full, "two places now: the wait ends at once")
}

// The edges: no record, one, the capacity, one past it; a full queue and
// an empty one; a count of the records read that the reader wrote wrong.
@(test)
the_room_for_records_at_its_edges :: proc(t: ^testing.T) {
	memory := make([]u64, ring.PAGE_COUNT * ring.PAGE_SIZE / size_of(u64))
	defer delete(memory)
	opened := room_ring_of(t, memory)
	queue := &opened.commands
	capacity := ring.capacity(queue)
	testing.expect(t, room_is_enough(queue, queue.counters.read, 0), "no record needs no room")
	testing.expect(t, room_is_enough(queue, queue.counters.read, capacity), "an empty queue has room for its capacity")
	testing.expect(t, room_is_enough(queue, queue.counters.read, capacity + 1), "a count past the capacity waits for an empty queue")
	testing.expect(t, room_is_enough(queue, queue.counters.read, max(u32)))
	room_fill(queue, capacity)
	testing.expect(t, room_is_enough(queue, queue.counters.read, 0))
	testing.expect(t, !room_is_enough(queue, queue.counters.read, 1), "a full queue has no room for one record")
	testing.expect(t, !room_is_enough(queue, queue.counters.read, capacity + 1))
	// A count of the records read past the count written: no room is
	// assumed, never a room larger than the capacity.
	testing.expect(t, !room_is_enough(queue, queue.counters.write + 1, 1))
	wait: Wait
	wait_room_for(&wait, queue, 1)
	testing.expect(t, !wait.full, "a full queue: the writer waits")
}
