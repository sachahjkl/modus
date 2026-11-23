#+build !freestanding
package ring

import "base:intrinsics"
import "core:slice"
import "core:testing"
import "core:thread"
import "core:time"

// The bound of a stall of the cases with two threads or more: the hang
// bound of the checks of a process (docs/TOOLS.md, "The bounds of the
// tests"). A contract package imports no support package, so its value is
// written here. A case ends when no record moved for this long: a lost
// record or a lost turn, never a slow host.
@(private = "file")
STALL_BOUND_MILLISECONDS :: 60_000

// A count of pages whose product with CAPACITY is 2 to the 64: the capacity
// of one more page wraps to 0, of two more to CAPACITY.
@(private = "file")
WRAP_PAGES :: u64(1) << 59

// A word that no counter, no turn and no record of these cases holds, to see
// each byte that an operation wrote where it must not.
@(private = "file")
UNTOUCHED :: u64(0xA5A5_A5A5_A5A5_A5A5)

@(private = "file")
memory_of_pages :: proc(page_count: u64) -> []u64 {
	return make([]u64, page_count * PAGE_SIZE / size_of(u64))
}

// A record whose every byte is set, with its number in tag, in the first
// value and, inverted, in the last: a torn copy shows as two words that
// disagree.
@(private = "file")
numbered_record :: proc(number: u32) -> Record {
	record := Record{kind = max(u32), tag = number}
	for &value in record.values {
		value = max(u64)
	}
	record.values[0] = u64(number)
	record.values[len(record.values) - 1] = ~u64(number)
	return record
}

@(private = "file")
record_is_whole :: proc(record: Record) -> bool {
	return record.values[len(record.values) - 1] == ~record.values[0] && u64(record.tag) == record.values[0]
}

// open refuses each count of pages that no ring has: below the smallest
// ring, a capacity that is not a power of two, one past the largest, and a
// count so large that the product would wrap to a small power of two or to
// 0. A refusal gives no ring.
@(test)
open_refuses_each_count_of_pages_that_no_ring_has :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	address := raw_data(memory)
	nil_ring, nil_opened := open(nil, PAGE_COUNT)
	testing.expect(t, !nil_opened, "a nil address is refused")
	testing.expect(t, nil_ring.head == nil)
	refused := [?]u64 {
		0,
		1,
		PAGE_COUNT + 2, // A capacity of 96.
		pages(CAPACITY_LIMIT) - 1,
		pages(CAPACITY_LIMIT) + 1,
		pages(CAPACITY_LIMIT * 2), // A power of two, one past the limit.
		1 + WRAP_PAGES, // The capacity wraps to 0.
		2 + WRAP_PAGES, // The capacity wraps to CAPACITY.
		3 + WRAP_PAGES, // The capacity wraps to 2 * CAPACITY.
		max(u64) - 1,
		max(u64),
	}
	for page_count in refused {
		ring, opened := open(address, page_count)
		testing.expectf(t, !opened, "a ring of %v pages is refused", page_count)
		testing.expect(t, ring.head == nil)
	}
	// The successful cases last: each power of two from the smallest to the
	// largest, with its two queues one after the other. open reads no byte,
	// so a count of pages past this memory is given safely.
	for capacity_of_ring := u32(CAPACITY); capacity_of_ring <= CAPACITY_LIMIT; capacity_of_ring *= 2 {
		ring, opened := open(address, pages(capacity_of_ring))
		testing.expectf(t, opened, "a ring of capacity %v opens", capacity_of_ring)
		testing.expect_value(t, capacity(&ring.commands), capacity_of_ring)
		testing.expect_value(t, capacity(&ring.completions), capacity_of_ring)
		testing.expect_value(t, uintptr(ring.commands.records), uintptr(address) + PAGE_SIZE)
		testing.expect_value(t, uintptr(ring.completions.records), uintptr(address) + PAGE_SIZE + uintptr(capacity_of_ring) * size_of(Record))
	}
	for word in memory {
		testing.expect_value(t, word, 0)
	}
}

// A push on a full queue gives false and changes no byte; a pop then makes
// room for one push only.
@(test)
a_full_queue_refuses_a_push_and_changes_nothing :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	queue := &ring.commands
	for number in 0 ..< u32(CAPACITY) {
		testing.expect(t, push(queue, numbered_record(number)))
	}
	testing.expect_value(t, count(queue), u32(CAPACITY))
	before := slice.clone(memory)
	defer delete(before)
	testing.expect(t, !push(queue, numbered_record(max(u32))), "a full queue refuses a push")
	testing.expect(t, slice.equal(before, memory), "a refused push writes no byte")
	testing.expect(t, empty(&ring.completions), "the commands are not in the completions")
	record, popped := pop(queue)
	testing.expect(t, popped)
	testing.expect_value(t, record, numbered_record(0))
	testing.expect(t, push(queue, numbered_record(CAPACITY)))
	testing.expect(t, !push(queue, numbered_record(max(u32))), "one pop makes room for one push")
	testing.expect_value(t, count(queue), u32(CAPACITY))
}

// A pop on an empty queue gives no record and changes no counter, also on
// a queue that its reader emptied.
@(test)
an_empty_queue_gives_no_record :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	queue := &ring.commands
	record, popped := pop(queue)
	testing.expect(t, !popped, "an empty queue gives no record")
	testing.expect_value(t, record, Record{})
	testing.expect(t, empty(queue))
	testing.expect_value(t, count(queue), 0)
	testing.expect_value(t, ring.head.commands.read, 0)
	testing.expect(t, push(queue, numbered_record(1)))
	_, popped = pop(queue)
	testing.expect(t, popped)
	record, popped = pop(queue)
	testing.expect(t, !popped, "a queue that its reader emptied gives no record")
	testing.expect_value(t, record, Record{})
	testing.expect_value(t, ring.head.commands.read, 1)
	testing.expect_value(t, ring.head.commands.write, 1)
}

// The counters count since the start and wrap at the top of their type:
// the records across the wrap keep their places and their order, and a
// full queue across the wrap is still full.
@(test)
the_counters_wrap_at_the_top_of_their_type :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	queue := &ring.commands
	start := max(u32) - 1
	ring.head.commands.write = start
	ring.head.commands.read = start
	for number in 0 ..< u32(3) {
		testing.expect(t, push(queue, numbered_record(number)))
	}
	testing.expect_value(t, ring.head.commands.write, start + 3)
	testing.expect_value(t, count(queue), 3)
	for number in 0 ..< u32(3) {
		testing.expect_value(t, queue.records[(start + number) & queue.mask], numbered_record(number))
	}
	for number in 0 ..< u32(3) {
		record, popped := pop(queue)
		testing.expect(t, popped)
		testing.expect_value(t, record, numbered_record(number))
	}
	testing.expect(t, empty(queue))
	for number in 0 ..< u32(CAPACITY) {
		testing.expect(t, push(queue, numbered_record(number)))
	}
	testing.expect(t, !push(queue, numbered_record(max(u32))), "a full queue across the wrap refuses a push")
	testing.expect_value(t, count(queue), u32(CAPACITY))
}

// Counters that the other side wrote false (the read past the write, a
// distance above the capacity) give a count of at most the capacity, and
// refuse each push and each pop with no byte and no counter changed. The
// true counts across the wrap and at the capacity then pop the record of
// the place of their count.
@(test)
hostile_counters_are_refused :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	queue := &ring.commands
	for place in 0 ..< u32(CAPACITY) {
		queue.records[place] = numbered_record(place)
	}
	Hostile_Counters :: struct {
		write: u32,
		read:  u32,
	}
	hostile := [?]Hostile_Counters {
		{write = 0, read = 1}, // The read one past the write.
		{write = CAPACITY + 1, read = 0}, // One past the capacity.
		{write = max(u32), read = 0},
		{write = 0, read = 1 << 31},
		{write = CAPACITY, read = max(u32)}, // One past the capacity, across the wrap.
	}
	for counters in hostile {
		queue.counters.write = counters.write
		queue.counters.read = counters.read
		testing.expectf(t, count(queue) == u32(CAPACITY), "write %v and read %v give the count %v", counters.write, counters.read, count(queue))
		before := slice.clone(memory)
		testing.expectf(t, !push(queue, numbered_record(max(u32))), "write %v and read %v refuse a push", counters.write, counters.read)
		record, popped := pop(queue)
		testing.expectf(t, !popped, "write %v and read %v refuse a pop", counters.write, counters.read)
		testing.expect_value(t, record, Record{})
		testing.expect(t, slice.equal(before, memory), "a refused push and a refused pop change no byte and no counter")
		delete(before)
	}
	// The successful cases last: true counts.
	true_counts := [?]Hostile_Counters {
		{write = 0, read = max(u32)}, // A distance of 1, across the wrap.
		{write = max(u32), read = max(u32) - CAPACITY}, // The capacity: a full queue.
		{write = CAPACITY - 1, read = max(u32)}, // The capacity, across the wrap.
	}
	for counters in true_counts {
		queue.counters.write = counters.write
		queue.counters.read = counters.read
		testing.expect_value(t, count(queue), counters.write - counters.read)
		record, popped := pop(queue)
		testing.expect(t, popped)
		testing.expect_value(t, record, numbered_record(counters.read & queue.mask))
		testing.expect_value(t, queue.counters.read, counters.read + 1)
		testing.expect_value(t, queue.counters.write, counters.write)
	}
}

// full says what the next push answers, and reads no byte past the
// counters: a queue at its capacity and each false count are full, and so
// refuse a push; one place of room, across the wrap too, is not full and
// takes one push. The kernel runs a command only when the completion queue
// is not full, so the two must agree at each edge.
@(test)
full_says_what_the_next_push_answers :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	queue := &ring.completions
	Counts :: struct {
		write: u32,
		read:  u32,
	}
	full_counts := [?]Counts {
		{write = CAPACITY, read = 0}, // The capacity.
		{write = CAPACITY + 1, read = 0}, // One past the capacity: a false count.
		{write = max(u32), read = 0}, // The largest distance.
		{write = 0, read = 1}, // The read one past the write.
		{write = CAPACITY - 1, read = max(u32)}, // The capacity, across the wrap.
		{write = CAPACITY, read = max(u32)}, // One past the capacity, across the wrap.
	}
	for counts in full_counts {
		queue.counters.write = counts.write
		queue.counters.read = counts.read
		before := slice.clone(memory)
		testing.expectf(t, full(queue), "write %v and read %v are full", counts.write, counts.read)
		testing.expect(t, slice.equal(before, memory), "full writes no byte")
		testing.expectf(t, !push(queue, numbered_record(1)), "write %v and read %v refuse a push", counts.write, counts.read)
		testing.expect(t, slice.equal(before, memory), "the refused push writes no byte")
		delete(before)
	}
	// The successful cases last: 0, one record, and one place of room, at
	// the start and across the wrap. Each takes one push.
	room_counts := [?]Counts {
		{write = 0, read = 0},
		{write = 1, read = 0},
		{write = CAPACITY - 1, read = 0}, // One place of room.
		{write = CAPACITY - 2, read = max(u32)}, // One place of room, across the wrap.
		{write = max(u32), read = max(u32)}, // Empty at the top of the type.
	}
	for counts in room_counts {
		queue.counters.write = counts.write
		queue.counters.read = counts.read
		testing.expectf(t, !full(queue), "write %v and read %v have room", counts.write, counts.read)
		testing.expectf(t, push(queue, numbered_record(2)), "write %v and read %v take a push", counts.write, counts.read)
		testing.expect_value(t, queue.counters.write, counts.write + 1)
	}
	testing.expect(t, empty(&ring.commands), "full and push of the completions touch no command")
}

// A record is one slot of 64 bytes: a push writes the bytes of its slot and
// its counter, and no byte of another slot, of the other queue or past the
// ring.
@(test)
a_push_writes_its_slot_only :: proc(t: ^testing.T) {
	// One page past the ring holds UNTOUCHED, to see a write past it.
	memory := memory_of_pages(PAGE_COUNT + 1)
	defer delete(memory)
	for &word in memory {
		word = UNTOUCHED
	}
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	ring.head^ = {}
	words_of_record :: size_of(Record) / size_of(u64)
	first_record_word :: PAGE_SIZE / size_of(u64)
	for queue_index in 0 ..< 2 {
		queue := queue_index == 0 ? &ring.commands : &ring.completions
		first_word := first_record_word + queue_index * CAPACITY * words_of_record
		counter_word := int(uintptr(&queue.counters.write) - uintptr(raw_data(memory))) / size_of(u64)
		for place in 0 ..< CAPACITY {
			before := slice.clone(memory)
			testing.expect(t, push(queue, numbered_record(u32(place))))
			slot := first_word + place * words_of_record
			for word, index in memory {
				if index == counter_word || index >= slot && index < slot + words_of_record {
					continue
				}
				if word != before[index] {
					testing.expectf(t, false, "a push at place %v of queue %v wrote the word %v", place, queue_index, index)
				}
			}
			delete(before)
		}
	}
	for word in memory[(PAGE_COUNT * PAGE_SIZE) / size_of(u64):] {
		testing.expect_value(t, word, UNTOUCHED)
	}
}

@(private = "file")
Ring_Work :: struct {
	ring:         Ring,
	total:        u32, // The records that the writer writes.
	progress:     u32, // A push or a pop adds 1: a stall is no growth of it.
	received:     u32,
	out_of_order: u32, // The records that the reader took in another order than the writer wrote them, or torn.
	abandoned:    bool, // A thread saw a stall: each thread ends.
}

@(private = "file")
Stall_Watch :: struct {
	progress: u32,
	since:    time.Tick,
}

// stalled says if no record moved for the stall bound, and then makes each
// thread of the case end.
@(private = "file")
stalled :: proc(watch: ^Stall_Watch, progress: ^u32, abandoned: ^bool) -> bool {
	if intrinsics.atomic_load(abandoned) {
		return true
	}
	seen := intrinsics.atomic_load(progress)
	if seen != watch.progress {
		watch.progress = seen
		watch.since = time.tick_now()
		return false
	}
	if time.tick_since(watch.since) > time.Duration(STALL_BOUND_MILLISECONDS) * time.Millisecond {
		intrinsics.atomic_store(abandoned, true)
		return true
	}
	return false
}

@(private = "file")
ring_writer :: proc(work: ^Ring_Work) {
	watch := Stall_Watch{since = time.tick_now()}
	for number: u32 = 0; number < work.total; {
		if push(&work.ring.commands, numbered_record(number)) {
			intrinsics.atomic_add(&work.progress, 1)
			number += 1
		} else if stalled(&watch, &work.progress, &work.abandoned) {
			return
		} else {
			intrinsics.cpu_relax()
		}
	}
}

@(private = "file")
ring_reader :: proc(work: ^Ring_Work) {
	watch := Stall_Watch{since = time.tick_now()}
	for work.received < work.total {
		record, popped := pop(&work.ring.commands)
		if popped {
			if !record_is_whole(record) || record.tag != work.received {
				work.out_of_order += 1
			}
			work.received += 1
			intrinsics.atomic_add(&work.progress, 1)
		} else if stalled(&watch, &work.progress, &work.abandoned) {
			return
		} else {
			intrinsics.cpu_relax()
		}
	}
}

// The writer and the reader of one queue on two threads: each record
// arrives once, whole and in the order of the writer, across many wraps
// of the places. This checks the counting of the queue under a real
// interleaving. It does not check the order of the memory accesses: an
// x86 host keeps the order of the stores, so a push with a relaxed store
// of its counter passes here too.
@(test)
a_writer_and_a_reader_on_two_threads_keep_the_order :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	work := new(Ring_Work)
	defer free(work)
	opened: bool
	work.ring, opened = open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	work.total = 1 << 18
	writer := thread.create_and_start_with_poly_data(work, ring_writer)
	reader := thread.create_and_start_with_poly_data(work, ring_reader)
	thread.join(writer)
	thread.join(reader)
	thread.destroy(writer)
	thread.destroy(reader)
	testing.expectf(t, !work.abandoned, "no record moved for %v ms, after %v records", STALL_BOUND_MILLISECONDS, work.received)
	testing.expect_value(t, work.received, work.total)
	testing.expect_value(t, work.out_of_order, 0)
	testing.expect(t, empty(&work.ring.commands))
}

// shared_open refuses each count of pages that no shared queue has: from 0
// to 5 pages only 3 and 4 open; past the largest capacity, a nil address
// and the largest count are refused.
@(test)
shared_open_refuses_each_count_of_pages_that_no_shared_queue_has :: proc(t: ^testing.T) {
	memory := memory_of_pages(shared_pages(SHARED_CAPACITY))
	defer delete(memory)
	address := raw_data(memory)
	nil_queue, nil_opened := shared_open(nil, shared_pages(SHARED_CAPACITY))
	testing.expect(t, !nil_opened, "a nil address is refused")
	testing.expect(t, nil_queue.head == nil)
	refused := [?]u64{shared_pages(SHARED_CAPACITY_LIMIT) - 1, shared_pages(SHARED_CAPACITY_LIMIT) + 1, shared_pages(SHARED_CAPACITY_LIMIT * 2), max(u64)}
	for page_count in refused {
		queue, opened := shared_open(address, page_count)
		testing.expectf(t, !opened, "a shared queue of %v pages is refused", page_count)
		testing.expect(t, queue.head == nil)
	}
	// shared_open reads no byte, so a count of pages past this memory is
	// given safely.
	for page_count: u64 = 0; page_count <= 5; page_count += 1 {
		queue, opened := shared_open(address, page_count)
		if page_count == shared_pages(SHARED_CAPACITY) {
			testing.expect(t, opened)
			testing.expect_value(t, shared_capacity(&queue), u32(SHARED_CAPACITY))
		} else if page_count == shared_pages(SHARED_CAPACITY * 2) {
			testing.expect(t, opened)
			testing.expect_value(t, shared_capacity(&queue), u32(SHARED_CAPACITY * 2))
		} else {
			testing.expectf(t, !opened, "a shared queue of %v pages is refused", page_count)
			testing.expect(t, queue.head == nil)
		}
	}
	for capacity_of_queue := u32(SHARED_CAPACITY); capacity_of_queue <= SHARED_CAPACITY_LIMIT; capacity_of_queue *= 2 {
		queue, opened := shared_open(address, shared_pages(capacity_of_queue))
		testing.expectf(t, opened, "a shared queue of capacity %v opens", capacity_of_queue)
		testing.expect_value(t, shared_capacity(&queue), capacity_of_queue)
		turn_pages := (uintptr(capacity_of_queue) + TURNS_IN_PAGE - 1) / TURNS_IN_PAGE
		testing.expect_value(t, uintptr(queue.turns), uintptr(address) + PAGE_SIZE)
		testing.expect_value(t, uintptr(queue.records), uintptr(address) + PAGE_SIZE * (1 + turn_pages))
		testing.expect(t, uintptr(queue.records) + uintptr(capacity_of_queue) * size_of(Record) <= uintptr(address) + uintptr(shared_pages(capacity_of_queue)) * PAGE_SIZE)
	}
}

// A push on a full shared queue gives false and changes no byte; a pop on
// an empty one gives no record. The records come out in the order of one
// writer.
@(test)
a_full_shared_queue_refuses_a_push_and_an_empty_one_a_pop :: proc(t: ^testing.T) {
	memory := memory_of_pages(shared_pages(SHARED_CAPACITY))
	defer delete(memory)
	queue, opened := shared_open(raw_data(memory), shared_pages(SHARED_CAPACITY))
	testing.expect(t, opened)
	record, popped := shared_pop(&queue)
	testing.expect(t, !popped, "an empty shared queue gives no record")
	testing.expect_value(t, record, Record{})
	testing.expect(t, !shared_ready(&queue))
	testing.expect(t, shared_room(&queue))
	for number in 0 ..< u32(SHARED_CAPACITY) {
		testing.expect(t, shared_push(&queue, numbered_record(number)))
	}
	testing.expect_value(t, shared_count(&queue), u32(SHARED_CAPACITY))
	testing.expect(t, !shared_room(&queue))
	before := slice.clone(memory)
	defer delete(before)
	testing.expect(t, !shared_push(&queue, numbered_record(max(u32))), "a full shared queue refuses a push")
	testing.expect(t, slice.equal(before, memory), "a refused push writes no byte")
	for number in 0 ..< u32(SHARED_CAPACITY) {
		record, popped = shared_pop(&queue)
		testing.expect(t, popped)
		testing.expect_value(t, record, numbered_record(number))
	}
	record, popped = shared_pop(&queue)
	testing.expect(t, !popped, "a shared queue that its readers emptied gives no record")
	testing.expect_value(t, record, Record{})
	testing.expect_value(t, shared_count(&queue), 0)
	testing.expect(t, !shared_ready(&queue))
}

// The counts of a shared queue wrap at the top of their type: the turn
// words of each place name the count of the lap across the wrap.
@(test)
the_shared_counts_wrap_at_the_top_of_their_type :: proc(t: ^testing.T) {
	memory := memory_of_pages(shared_pages(SHARED_CAPACITY))
	defer delete(memory)
	queue, opened := shared_open(raw_data(memory), shared_pages(SHARED_CAPACITY))
	testing.expect(t, opened)
	start := max(u32) - 1
	queue.head.write = start
	queue.head.read = start
	// The free count of each place is the first count from start that falls
	// on it; its turn word is that count less the place.
	for place in 0 ..< u32(SHARED_CAPACITY) {
		free_count := start + ((place - start) & queue.mask)
		queue.turns[place] = free_count - place
	}
	for number in 0 ..< u32(3) {
		testing.expect(t, shared_push(&queue, numbered_record(number)))
	}
	testing.expect_value(t, queue.head.write, start + 3)
	testing.expect_value(t, shared_count(&queue), 3)
	for number in 0 ..< u32(3) {
		record, popped := shared_pop(&queue)
		testing.expect(t, popped)
		testing.expect_value(t, record, numbered_record(number))
	}
	testing.expect_value(t, queue.head.read, start + 3)
	for number in 0 ..< u32(SHARED_CAPACITY) {
		testing.expect(t, shared_push(&queue, numbered_record(number)))
	}
	testing.expect(t, !shared_push(&queue, numbered_record(max(u32))), "a full shared queue across the wrap refuses a push")
}

// Counts and turn words that a hostile thread wrote: the count stays from 0
// to the capacity, a push that finds no free turn writes no byte, and no
// operation writes past the queue.
@(test)
hostile_shared_words_keep_each_access_inside_the_queue :: proc(t: ^testing.T) {
	page_count := shared_pages(SHARED_CAPACITY)
	// One page past the queue holds UNTOUCHED, to see a write past it.
	memory := memory_of_pages(page_count + 1)
	defer delete(memory)
	for &word in memory[page_count * PAGE_SIZE / size_of(u64):] {
		word = UNTOUCHED
	}
	queue, opened := shared_open(raw_data(memory), page_count)
	testing.expect(t, opened)
	// The read past the write, and a distance above the capacity.
	queue.head.write = 0
	queue.head.read = 1
	testing.expect_value(t, shared_count(&queue), 0)
	queue.head.write = 1 << 20
	queue.head.read = 0
	testing.expect_value(t, shared_count(&queue), u32(SHARED_CAPACITY))
	// A turn word ahead of the count: the place seems taken by another
	// writer at each try. The push gives up and writes nothing.
	queue.head.write = 0
	queue.head.read = 0
	queue.turns[0] = 5
	before := slice.clone(memory)
	testing.expect(t, !shared_push(&queue, numbered_record(1)), "a push that finds no free turn gives up")
	testing.expect(t, slice.equal(before, memory), "a push that gave up writes no byte")
	delete(before)
	// A turn word behind the count: the record of one lap before was not
	// read. The push is refused at once.
	queue.head.write = 7
	queue.turns[7] = max(u32) - 7
	before = slice.clone(memory)
	testing.expect(t, !shared_push(&queue, numbered_record(1)))
	testing.expect(t, slice.equal(before, memory))
	delete(before)
	// A pop that finds no completed record gives none, and writes nothing.
	queue.head.read = 3
	queue.turns[3] = 9
	before = slice.clone(memory)
	record, popped := shared_pop(&queue)
	testing.expect(t, !popped)
	testing.expect_value(t, record, Record{})
	testing.expect(t, slice.equal(before, memory))
	delete(before)
	// Counts at the top of the type and turn words of each value: each
	// access stays at a place of the queue.
	hostile_words := [?]u32{0, 1, queue.mask, queue.mask + 1, 1 << 31, max(u32) - 1, max(u32)}
	for count_word in hostile_words {
		for turn_word in hostile_words {
			queue.head.write = count_word
			queue.head.read = count_word
			for place in 0 ..< u32(SHARED_CAPACITY) {
				queue.turns[place] = turn_word
			}
			_ = shared_push(&queue, numbered_record(count_word))
			_, _ = shared_pop(&queue)
			testing.expect(t, shared_count(&queue) <= shared_capacity(&queue))
		}
	}
	for word in memory[page_count * PAGE_SIZE / size_of(u64):] {
		testing.expect_value(t, word, UNTOUCHED)
	}
}

@(private = "file")
Shared_Work :: struct {
	queue:     Shared,
	total:     u32, // The records that the writers write in all; each number once.
	progress:  u32, // A push or a pop adds 1: a stall is no growth of it.
	received:  u32,
	torn:      u32, // The records whose words disagree, or whose number is past the total.
	seen:      []u32, // The times that the readers took each number.
	abandoned: bool, // A thread saw a stall: each thread ends.
}

@(private = "file")
Shared_Writer :: struct {
	work:  ^Shared_Work,
	first: u32, // The first number that this writer writes.
	count: u32,
}

@(private = "file")
shared_writer :: proc(writer: ^Shared_Writer) {
	work := writer.work
	watch := Stall_Watch{since = time.tick_now()}
	for number := writer.first; number < writer.first + writer.count; {
		if shared_push(&work.queue, numbered_record(number)) {
			intrinsics.atomic_add(&work.progress, 1)
			number += 1
		} else if stalled(&watch, &work.progress, &work.abandoned) {
			return
		} else {
			intrinsics.cpu_relax()
		}
	}
}

@(private = "file")
shared_reader :: proc(work: ^Shared_Work) {
	watch := Stall_Watch{since = time.tick_now()}
	for intrinsics.atomic_load(&work.received) < work.total {
		record, popped := shared_pop(&work.queue)
		if popped {
			if !record_is_whole(record) || record.tag >= work.total {
				intrinsics.atomic_add(&work.torn, 1)
			} else {
				intrinsics.atomic_add(&work.seen[record.tag], 1)
			}
			intrinsics.atomic_add(&work.received, 1)
			intrinsics.atomic_add(&work.progress, 1)
		} else if stalled(&watch, &work.progress, &work.abandoned) {
			return
		} else {
			intrinsics.cpu_relax()
		}
	}
}

// Two writers and two readers on four threads: each record arrives whole
// and exactly once, none is lost and none is read twice, across many laps
// of the places. This checks the turn protocol and the compare-and-exchange
// of the counts under a real interleaving. It does not check the order of
// the memory accesses: an x86 host keeps the order of the stores, so a
// turn word written with a relaxed store passes here too.
@(test)
two_writers_and_two_readers_move_each_record_once :: proc(t: ^testing.T) {
	memory := memory_of_pages(shared_pages(SHARED_CAPACITY))
	defer delete(memory)
	work := new(Shared_Work)
	defer free(work)
	opened: bool
	work.queue, opened = shared_open(raw_data(memory), shared_pages(SHARED_CAPACITY))
	testing.expect(t, opened)
	work.total = 1 << 18
	work.seen = make([]u32, work.total)
	defer delete(work.seen)
	writers := [2]Shared_Writer{{work = work, first = 0, count = work.total / 2}, {work = work, first = work.total / 2, count = work.total / 2}}
	threads := [4]^thread.Thread {
		thread.create_and_start_with_poly_data(&writers[0], shared_writer),
		thread.create_and_start_with_poly_data(&writers[1], shared_writer),
		thread.create_and_start_with_poly_data(work, shared_reader),
		thread.create_and_start_with_poly_data(work, shared_reader),
	}
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	testing.expectf(t, !work.abandoned, "no record moved for %v ms, after %v records", STALL_BOUND_MILLISECONDS, work.received)
	testing.expect_value(t, work.received, work.total)
	testing.expect_value(t, work.torn, 0)
	wrong := 0
	for times in work.seen {
		if times != 1 {
			wrong += 1
		}
	}
	testing.expectf(t, wrong == 0, "%v numbers were not read exactly once", wrong)
	testing.expect_value(t, shared_count(&work.queue), 0)
}

// The counters that a reader in a loop must end the queue for: a ring
// never written, a flood up to the capacity (each record is read, then the
// queue is empty), and the false counts, one past the capacity, a write
// behind the read, and the largest distance. None is refused while a pop
// can give its records.
@(test)
a_false_count_is_refused_and_a_flood_is_not :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	queue := &ring.commands
	testing.expect(t, !counters_refused(queue), "a ring never written")
	for number in 0 ..< u32(CAPACITY) {
		testing.expect(t, push(queue, numbered_record(number)))
	}
	testing.expect(t, !counters_refused(queue), "a flood up to the capacity")
	for _ in 0 ..< CAPACITY {
		_, popped := pop(queue)
		testing.expect(t, popped)
	}
	testing.expect(t, empty(queue) && !counters_refused(queue), "a flood that was read")
	ring.head.commands.write = ring.head.commands.read + u32(CAPACITY) + 1
	testing.expect(t, counters_refused(queue), "one past the capacity")
	_, popped := pop(queue)
	testing.expect(t, !popped && !empty(queue), "pop refuses it and the counts differ: a wait ends at once")
	ring.head.commands.write = ring.head.commands.read - 1
	testing.expect(t, counters_refused(queue), "a write behind the read")
	ring.head.commands.write, ring.head.commands.read = max(u32), 0
	testing.expect(t, counters_refused(queue), "the largest distance")
	ring.head.commands.write, ring.head.commands.read = 5, max(u32) - u32(CAPACITY) + 6
	testing.expect(t, !counters_refused(queue), "a full queue across the wrap")
}

// A reader refuses a false count by its own counter: the queue is empty, a
// push works again, and an honest queue, empty or full, is left as it is.
@(test)
a_false_count_is_refused_by_the_count_of_the_reader :: proc(t: ^testing.T) {
	memory := memory_of_pages(PAGE_COUNT)
	defer delete(memory)
	ring, opened := open(raw_data(memory), PAGE_COUNT)
	testing.expect(t, opened)
	queue := &ring.commands
	testing.expect(t, !false_count_refuse(queue), "an empty queue")
	for number in 0 ..< u32(CAPACITY) {
		testing.expect(t, push(queue, numbered_record(number)))
	}
	testing.expect(t, !false_count_refuse(queue), "a full queue")
	testing.expect_value(t, count(queue), u32(CAPACITY))
	ring.head.commands.write = ring.head.commands.read + u32(CAPACITY) + 1
	testing.expect(t, false_count_refuse(queue))
	testing.expect(t, empty(queue) && !counters_refused(queue))
	testing.expect(t, push(queue, numbered_record(7)))
	record, popped := pop(queue)
	testing.expect(t, popped && record == numbered_record(7))
	ring.head.commands.write, ring.head.commands.read = 3, 9
	testing.expect(t, false_count_refuse(queue), "a write behind the read")
	testing.expect_value(t, ring.head.commands.read, 3)
}
