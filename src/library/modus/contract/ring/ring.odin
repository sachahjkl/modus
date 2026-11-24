// The ring: two queues of fixed records in shared memory. It is the base
// interface of the kernel, with no blocking operation, and the one way that
// two processes communicate.
//
// One side writes the queue of command records and reads the queue of
// completion records. The other side does the opposite. A queue has one
// writer and one reader: no queue operation needs a lock, and none enters
// the kernel. The same format is used between two processes and between a
// process and the kernel.
//
// The memory of a ring:
//   page 0        the head: the counters of the two queues (Head)
//   after it      the command records, then the completion records
//
// The capacity of a ring is the count of records of each queue. It is a
// power of two, and it comes from the size of the memory: a ring of
// 1 + capacity / 32 pages. The capacity is not written in the shared
// memory: each side computes it from the size that the kernel gives. A ring
// does not change its capacity. Memory that is all zero is an empty ring.
//
// Choose the capacity for the largest burst of the writer. When a queue is
// full, `push` writes nothing and says so: the writer waits for room, or it
// refuses the request that it serves and says so: a full queue slows the
// writer to the speed of the reader. The kernel follows it too: it runs a
// command of a kernel ring only when the completion queue has room for its
// answer, and else leaves the command in the command queue, unrun, until
// the thread reads its completions (`full`, and
// src/md/api/kernel_ring_completion_room.md).
//
// Who uses it: the kernel (the kernel ring of each thread), every service
// (its rings to its callers) and every process. The parts:
//
// - `Record`: one command or one completion, 64 bytes.
// - `Head`, `Counters`: the shared head of a ring.
// - `Ring`, `Queue`: a ring as one side holds it.
// - `open`, `push`, `pop`, `count`, `empty`, `full`, `complete`: the queue
//   operations, with no lock and no kernel entry.
// - `Shared_Head`, `shared_open` (`shared.odin`): the shared queue, which
//   several writers fill.
// - `Compartment_Ring`, `compartment_open`, `compartment_push`,
//   `compartment_pop` (`compartments.odin`): the form of a ring whose
//   commands are compartments of a size that both sides compute, the output
//   ring of a record output.
//
// `src/library/modus/system` adds the waits (`system.send`, `system.receive`). See
// [ring](term:ring), [command record](term:command-record) and
// (docs/ARCHITECTURE.md, "K4. Rings and wait").
package ring

import "base:intrinsics"

CAPACITY :: 32 // The capacity of the smallest ring.
PAGE_COUNT :: 2 // The pages of the smallest ring.
CAPACITY_LIMIT :: 1 << 16 // The largest capacity that `open` takes: 65536 records, a ring of 2049 pages.
PAGE_SIZE :: 4096 // The page of the processor: the head is one page.

// One record of a queue: a command, or the completion of a command.
//
// The writer fills it; the reader copies it out of the shared memory before
// it reads a field (`pop` gives a copy), because the writer of another
// process can change the shared bytes at any time. Each ring contract says
// what `kind` and `values` mean. 64 bytes: one line of the cache.
//
// Example: the kernel operation `Memory_Size` of the memory handle 5 is the
// command `{kind = 5, tag = 0, values = {5, 0, 0, 0, 0, 0, 0}}`; its
// completion is `{kind = 0 (Ok), values = {<pages>, ...}}`.
Record :: struct {
	kind:   u32, // A command: what to do (an `op.Operation`, a command of a service). A completion: a status; 0 is success.
	tag:    u32, // A number that the writer of the command chooses; the completion of the command has the same tag.
	values: [7]u64, // The arguments of a command, or the results of a completion; an `errors.Error_Record` for a completion that fails.
}
#assert(size_of(Record) == 64)

// The counters of one queue. write and read count records since the start;
// the place of a record is its count modulo the capacity. A side never
// trusts the numbers of the other side.
//
// A side that waits for the other side waits on a counter (the word wait of
// the kernel): the reader on `write`, while the queue is empty; the writer
// on `read`, while the queue is full. Before it waits, it sets its `waits`
// word. The other side enters the kernel to wake it only if that word is
// set. The system library does this: see system/wait.odin.
//
// The writer changes the first line of the cache, the reader the second.
Counters :: struct {
	write:        u32, // The records that the writer wrote since the start. Only the writer writes it.
	writer_waits: u32, // The writer waits, or will wait, for room.
	reserved_0:   [56]u8, // The rest of the line of the writer.
	read:         u32, // The records that the reader read since the start. Only the reader writes it.
	reader_waits: u32, // The reader waits, or will wait, for a record.
	reserved_1:   [56]u8, // The rest of the line of the reader.
}
#assert(size_of(Counters) == 128)

// The first page of a ring: the counters of the two queues, each in its own
// half of the page.
Head :: struct {
	commands:    Counters, // The queue of the commands.
	reserved_0:  [PAGE_SIZE / 2 - size_of(Counters)]u8,
	completions: Counters, // The queue of the completions.
	reserved_1:  [PAGE_SIZE / 2 - size_of(Counters)]u8,
}
#assert(size_of(Head) == PAGE_SIZE)

// One queue, as one side sees it. This record is not in the shared memory:
// the mask comes from the size of the memory.
Queue :: struct {
	counters:         ^Counters, // The counters of the queue, in the shared head.
	records:          [^]Record, // The first record of the queue, in the shared memory.
	mask:             u32, // The capacity - 1.
	false_count_seen: bool, // A false count was refused on this queue since open.
}

// A ring that is mapped. head is nil for no ring.
//
// Each side holds its own `Ring` in private memory: the masks come from
// the size of the mapping, never from the shared bytes.
Ring :: struct {
	head:        ^Head, // The shared head.
	commands:    Queue, // The commands: the side that asks pushes, the side that serves pops.
	completions: Queue, // The completions: the side that serves pushes, the side that asks pops.
}

// pages gives the pages of a ring with a capacity.
//
// Example: `pages(32)` is 2, `pages(256)` is 9.
pages :: proc "contextless" (capacity: u32) -> u64 {
	return 1 + u64(capacity) / CAPACITY
}

// open gives the ring in mapped memory of page_count pages. false: no ring
// has this size.
//
// A ring of n pages has the capacity `(n - 1) * 32`; open refuses a count
// below `PAGE_COUNT`, or whose capacity is not a power of two or is above
// `CAPACITY_LIMIT`. It reads no byte of the memory.
//
// ```odin
// address := system.memory_map(memory, {.Write}) or_return
// calls, ok := ring.open(address, ring.pages(64))
// ```
open :: proc "contextless" (memory: rawptr, page_count: u64) -> (ring: Ring, ok: bool) {
	// The count of the record pages is bounded before the product: a count
	// of pages near the top of the type would make the capacity wrap to a
	// small power of two, or to 0 and a mask of every bit.
	if memory == nil || page_count < PAGE_COUNT || page_count - 1 > CAPACITY_LIMIT / CAPACITY {
		return {}, false
	}
	capacity := (page_count - 1) * CAPACITY
	if capacity > CAPACITY_LIMIT || capacity & (capacity - 1) != 0 {
		return {}, false
	}
	head := (^Head)(memory)
	records := ([^]Record)(uintptr(memory) + PAGE_SIZE)
	return {head = head, commands = {counters = &head.commands, records = records, mask = u32(capacity) - 1}, completions = {counters = &head.completions, records = records[capacity:], mask = u32(capacity) - 1}}, true
}

// capacity gives the records that a queue holds when it is full.
capacity :: proc "contextless" (queue: ^Queue) -> u32 {
	return queue.mask + 1
}

// count gives the records that wait in a queue. It reads the two counters
// with no order: the value can be old by the time the caller reads it, and
// it is at most the capacity even when the other side wrote a false count.
count :: proc "contextless" (queue: ^Queue) -> u32 {
	return min(intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed) - intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed), queue.mask + 1)
}

// push writes a record at the end of a queue. false: the queue is full, and
// nothing is written. The side that writes a queue calls it; it does not
// wake the reader (`system.send` does).
push :: proc "contextless" (queue: ^Queue, record: Record) -> bool {
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	// The same test as full, on the one read of the counter that the
	// record and the new count use: the other side can write the shared
	// counter between two reads.
	if write - intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire) > queue.mask {
		return false
	}
	queue.records[write & queue.mask] = record
	// The other side, on another processor, sees the record before the count.
	intrinsics.atomic_store_explicit(&queue.counters.write, write + 1, .Release)
	return true
}

// pop takes the first record of a queue, as a copy. ok is false when the
// queue is empty, and when the counters say more records than the queue
// holds: no honest writer writes that, and the counters then stay as they
// are. The side that reads a queue calls it.
pop :: proc "contextless" (queue: ^Queue) -> (record: Record, ok: bool) {
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Acquire)
	if write == read || write - read > queue.mask + 1 {
		return {}, false
	}
	record = queue.records[read & queue.mask]
	intrinsics.atomic_store_explicit(&queue.counters.read, read + 1, .Release)
	return record, true
}

// pop_erasing takes the first record of a queue, as pop does, and writes
// zeros over its slot before the writer can use it again: a record that
// holds a key leaves no copy in the memory that the two sides share.
pop_erasing :: proc "contextless" (queue: ^Queue) -> (record: Record, ok: bool) {
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Acquire)
	if write == read || write - read > queue.mask + 1 {
		return {}, false
	}
	slot := &queue.records[read & queue.mask]
	record = slot^
	intrinsics.mem_zero_volatile(slot, size_of(Record))
	intrinsics.atomic_store_explicit(&queue.counters.read, read + 1, .Release)
	return record, true
}

// empty says if a queue has no record to read.
empty :: proc "contextless" (queue: ^Queue) -> bool {
	return intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed) == intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
}

// counters_refused says if the counters of a queue say more records than it
// holds: pop refuses such a queue forever, while a wait on its records ends
// at once, as its counts differ. Only a hostile or broken writer writes
// that. A reader that serves such a queue in a loop ends it, or it loops
// with no wait.
counters_refused :: proc "contextless" (queue: ^Queue) -> bool {
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Acquire)
	return write - intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed) > queue.mask + 1
}

// false_count_refuse refuses the false count of a queue that its side reads:
// when the counters say more records than it holds, the reader sets its own
// count to the count of the writer, so the queue is empty, its records are
// dropped, and a wait on it waits again. The reader writes only its own
// counter. refused is false, and nothing changes, for a queue whose
// counters hold. first is true on the first refusal since open, so a
// reader logs once per ring and not once per false count.
false_count_refuse :: proc "contextless" (queue: ^Queue) -> (refused: bool, first: bool) {
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Acquire)
	if write - read <= queue.mask + 1 {
		return false, false
	}
	intrinsics.atomic_store_explicit(&queue.counters.read, write, .Release)
	first = !queue.false_count_seen
	queue.false_count_seen = true
	return true, first
}

// full says if a push into a queue would be refused now: the queue holds
// its capacity, or its counters say more records than it holds. The writer
// calls it before work whose record must find room: the kernel checks the
// completion queue of a thread before it runs a command. Only the reader
// makes room after it, so a queue that is not full stays so for the writer
// until its push, unless the reader writes a false count.
full :: proc "contextless" (queue: ^Queue) -> bool {
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	return write - intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire) > queue.mask
}

// complete makes the last store of a counter complete in memory, as each
// processor sees it, before the thread reads another word. push and pop do
// not do it: it costs more than the store. A side does it before it reads
// the `waits` word of the other side.
complete :: proc "contextless" (counter: ^u32) {
	intrinsics.atomic_store_explicit(counter, intrinsics.volatile_load(counter), .Seq_Cst)
}
