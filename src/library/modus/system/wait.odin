package system

import op "modus:contract/operation"
import "modus:contract/ring"
import "base:intrinsics"

// The wait: the one way for a thread to wait for something else than a
// time. A thread waits while each word of a list holds a value. The words
// are the counters of ring queues, the event word of the thread, and the
// words of the process itself (a lock), the words of shared queues and of
// events.
//
//   for {
//       wait := system.wait_begin()       // Reads the event word.
//       system.wait_records(&wait, queue) // The thread waits while the queue is empty.
//       ... read the queues, read the state ...
//       system.wait_end(&wait, deadline)
//   }
//
// If a word changes after the thread reads it and before the thread waits,
// the wait ends at once: no wake is lost.

// The count of `word_wake` that wakes each thread that waits on the word.
WAKE_ALL :: max(u64)

// The list of the words of one wait, built by `wait_begin` and the
// `wait_` procedures, ended by `wait_end`. It lives on the stack of the
// thread for one turn of its loop; it holds at most `op.WORD_WAIT_CAPACITY`
// words, the `waits` flags of the queues included: about 12 KiB of the
// stack, which a thread of 16 pages holds.
Wait :: struct {
	words:   [op.WORD_WAIT_CAPACITY]op.Word, // The words, and the value that each one holds while the thread waits.
	flags:   [op.WORD_WAIT_CAPACITY]^u32, // The `waits` word of a queue: wait_end sets it.
	other_flags: [op.WORD_WAIT_CAPACITY]^u32, // A queue: the `waits` word of the other side.
	other_words: [op.WORD_WAIT_CAPACITY]^u32, // A queue: the counter that the other side waits on.
	waiters: [op.WORD_WAIT_CAPACITY]^ring.Waiters, // A word that several threads wait on, when one wake is for one thread.
	kept:    [op.WORD_WAIT_CAPACITY]bool, // Several threads set the flag: the thread does not clear it after the wait.
	count:   int, // The words in the list.
	flag_count: int, // The words that have a flag: wait_end adds one word for each.
	full:    bool, // A word did not fit: the wait ends at once.
}

SPIN_COUNT :: 400 // The times that wait_spin reads the words: some microseconds.

// events gives the address of the event word of the thread that runs. The
// kernel adds 1 to it when an interrupt of the process arrives, when a
// process that this process holds stops, and when another thread ends.
events :: proc "contextless" () -> ^u32 {
	return &thread_record().events
}

// wait_begin starts a list with the event word. Call it before the thread
// reads the state that an event changes.
wait_begin :: proc "contextless" () -> (wait: Wait) {
	word := events()
	wait_word(&wait, word, intrinsics.volatile_load(word))
	return wait
}

// wait_word adds a word: the thread waits while the word holds value.
// word_wake ends the wait.
wait_word :: proc "contextless" (wait: ^Wait, word: ^u32, value: u32, flag: ^u32 = nil, other_flag: ^u32 = nil, other_word: ^u32 = nil, waiters: ^ring.Waiters = nil, keep_flag := false) {
	if wait.count + wait.flag_count + (flag != nil ? 2 : 1) > len(wait.words) {
		wait.full = true
		return
	}
	if flag != nil {
		wait.flag_count += 1
	}
	wait.waiters[wait.count] = waiters
	wait.kept[wait.count] = keep_flag
	wait.words[wait.count] = {address = u64(uintptr(word)), value = u64(value)}
	wait.flags[wait.count] = flag
	wait.other_flags[wait.count] = other_flag
	wait.other_words[wait.count] = other_word
	wait.count += 1
}

// wait_records adds a queue that this thread reads: the thread waits while
// the queue is empty.
wait_records :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	counters := queue.counters
	wait_word(wait, &counters.write, intrinsics.atomic_load_explicit(&counters.read, .Relaxed), &counters.reader_waits, &counters.writer_waits, &counters.read)
}

// wait_room adds a queue that this thread writes: the thread waits while
// the queue is full. The reader wakes it when half of the queue is free.
wait_room :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) {
	counters := queue.counters
	wait_word(wait, &counters.read, intrinsics.atomic_load_explicit(&counters.write, .Relaxed) - ring.capacity(queue), &counters.writer_waits, &counters.reader_waits, &counters.write)
}

// wait_room_for adds a queue that this thread writes: the thread waits
// until the queue has room for records. wait_room ends as soon as the
// queue is not full, so a writer that needs two places and finds one would
// loop with no wait while the reader does not read. Here the count of the
// records read is read once, and the room is judged from that same count:
// a record that the reader takes after this read changes the word, and the
// wait ends at once. With room now, the wait ends at once. The reader wakes
// the writer when half of the queue is free, or before it waits itself. A
// count past the capacity waits for an empty queue.
wait_room_for :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue, records: u32) {
	counters := queue.counters
	read := intrinsics.atomic_load_explicit(&counters.read, .Acquire)
	if room_is_enough(queue, read, records) {
		wait.full = true // Room now: the wait ends at once, as with a word that changed.
		return
	}
	wait_word(wait, &counters.read, read, &counters.writer_waits, &counters.reader_waits, &counters.write)
}

// room_is_enough says if a queue whose reader has read read records has
// room for records more. The writer is the caller: its count of the
// records written does not change meanwhile.
@(private = "package")
room_is_enough :: proc "contextless" (queue: ^ring.Queue, read: u32, records: u32) -> bool {
	capacity := ring.capacity(queue)
	written := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	held := written - read
	if held > capacity {
		return false // A count that the reader wrote wrong: no room is assumed, and the word still ends the wait.
	}
	return capacity - held >= min(records, capacity)
}

// wait_spin reads the words of the list for a short time, with no kernel
// entry. true: a word changed, the thread does not need to wait. Call it
// before wait_end when the other side answers in less time than a kernel
// entry takes: the other side then does not enter the kernel to wake this
// thread. With one processor it gives false at once.
wait_spin :: proc "contextless" (wait: ^Wait) -> bool {
	if wait.full {
		return true
	}
	if thread_record().processors < 2 {
		return false
	}
	// The other side of a shared queue does not wake a thread while this
	// thread reads the words: this thread takes the record.
	for waiters in wait.waiters[:wait.count] {
		if waiters != nil {
			intrinsics.atomic_add(&waiters.spins, 1)
		}
	}
	defer for waiters in wait.waiters[:wait.count] {
		if waiters != nil {
			intrinsics.atomic_sub(&waiters.spins, 1)
		}
	}
	for _ in 0 ..< SPIN_COUNT {
		for word in wait.words[:wait.count] {
			if intrinsics.volatile_load((^u32)(uintptr(word.address))) != u32(word.value) {
				return true
			}
		}
		intrinsics.cpu_relax()
	}
	return false
}

// wait_end stops the thread while each word holds its value, or until the
// time is deadline. It gives the time.
wait_end :: proc "contextless" (wait: ^Wait, deadline: u64 = WAIT_FOREVER) -> u64 {
	if wait.full {
		return time()
	}
	// A `waits` word is also a word of the wait: the thread waits while it
	// is 1. The other side sets it to 0 before each wake. A late wake, for
	// a record that this thread already read, can set it to 0 before this
	// thread waits: the wait then ends at once, and no later wake is lost.
	total := wait.count
	for index in 0 ..< wait.count {
		if flag := wait.flags[index]; flag != nil {
			intrinsics.atomic_store(flag, 1)
			wait.words[total] = {address = u64(uintptr(flag)), value = 1}
			total += 1
		}
		if waiters := wait.waiters[index]; waiters != nil {
			// The other side changes the word before it reads the count:
			// the kernel then reads a new value, and this thread does not
			// stop.
			intrinsics.atomic_add(&waiters.count, 1)
		}
		// This thread does nothing with the queue while it waits. If the
		// other side waits for this thread, it must continue now: a writer
		// that waits for half of the queue, or a reader that was not told
		// of the last records (ring.push with no wake_reader).
		if other := wait.other_flags[index]; other != nil && intrinsics.atomic_exchange(other, 0) != 0 {
			word_wake(wait.other_words[index], WAKE_ALL)
		}
	}
	// The kernel reads each word again: a record that arrived before the
	// `waits` word was set ends the wait at once. On a kernel ring that holds
	// other records, commands_call pushes nothing and gives the time: an
	// early end is an answer of each wait, as its caller reads its words
	// again, and no held command keeps the address of these words after
	// this frame ends (src/md/api/kernel_ring_completion_room.md).
	commands := [1]ring.Record{wait_command(&wait.words, total)}
	completions: [1]ring.Record
	now, _ := commands_call(commands[:], completions[:], max(deadline, 1))
	// The thread does not wait now: the other side does not need to wake it.
	for index in 0 ..< wait.count {
		// A flag that several threads set stays: another thread can still
		// wait with it.
		if flag := wait.flags[index]; flag != nil && !wait.kept[index] {
			intrinsics.atomic_store(flag, 0)
		}
		if waiters := wait.waiters[index]; waiters != nil {
			intrinsics.atomic_sub(&waiters.count, 1)
			intrinsics.atomic_store(&waiters.wakes, 0) // This thread runs: see wake_one.
		}
	}
	return now
}

// wait_command gives the command Word_Wait of the first count words of a
// list. A pure part of wait_end, so the host tests what it pushes.
@(private = "package")
wait_command :: proc "contextless" (words: ^[op.WORD_WAIT_CAPACITY]op.Word, count: int) -> ring.Record {
	return {kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(words)), 1 = u64(count)}}
}

// word_wait stops the thread while the word holds value, until word_wake
// names the word or until the time is deadline. It gives the time.
// The word can be in memory that another process maps.
// Read the word again after the wait: the deadline also ends it.
word_wait :: proc "contextless" (word: ^u32, value: u32, deadline: u64 = WAIT_FOREVER) -> u64 {
	wait: Wait
	wait_word(&wait, word, value)
	return wait_end(&wait, deadline)
}

// word_wake wakes at most count threads that wait on the word. It gives
// the number of threads that it woke.
word_wake :: proc "contextless" (word: ^u32, count: u64 = 1) -> u64 {
	results, _ := call(.Word_Wake, u64(uintptr(word)), count)
	return results[0]
}

// send writes a record in a queue, and wakes the reader if it waits. It
// enters the kernel only for that wake. false: the queue is full.
send :: proc "contextless" (queue: ^ring.Queue, record: ring.Record) -> bool {
	ring.push(queue, record) or_return
	wake_reader(queue)
	return true
}

// wake_reader wakes the reader of a queue if it waits. A thread that
// writes several records with ring.push calls it one time after the last
// record: one complete store for the group, in place of one for each
// record.
wake_reader :: proc "contextless" (queue: ^ring.Queue) {
	// The count is complete in memory before this thread reads the `waits`
	// word. If not, this thread can read "no wait" while the reader reads
	// the old count, and the reader then waits with no wake.
	ring.complete(&queue.counters.write)
	if intrinsics.atomic_load(&queue.counters.reader_waits) != 0 && intrinsics.atomic_exchange(&queue.counters.reader_waits, 0) != 0 {
		word_wake(&queue.counters.write, WAKE_ALL)
	}
}

// wake_writer wakes the writer of a queue if it waits on the count of the
// records read. A reader calls it after it read each record of the queue,
// when the writer can wait for that and not only for room: the process of
// a window waits until the compositor took its last picture
// (display.canvas_wait). It enters the kernel only for that wake.
wake_writer :: proc "contextless" (queue: ^ring.Queue) {
	ring.complete(&queue.counters.read) // See wake_reader.
	if intrinsics.atomic_load(&queue.counters.writer_waits) != 0 && intrinsics.atomic_exchange(&queue.counters.writer_waits, 0) != 0 {
		word_wake(&queue.counters.read, WAKE_ALL)
	}
}

// records_of_turn gives the count of records that a reader takes from a
// queue in one turn of its loop: the records that the queue holds now, at
// most its capacity even when the writer wrote a false count. A reader of
// a queue that another process writes takes that many with `receive`, and
// no more: a writer that writes as fast as the reader reads then cannot
// keep the reader in its loop. The records that come later end the next
// wait of the reader at once (wait_records).
//
//   for _ in 0 ..< system.records_of_turn(queue) {
//       record := system.receive(queue) or_break
//       ...
//   }
records_of_turn :: proc "contextless" (queue: ^ring.Queue) -> u32 {
	return ring.count(queue)
}

// receive reads a record from a queue. If the writer waits for room, it
// wakes the writer when half of the queue is free: the writer then writes
// many records for one kernel entry.
//
// A writer waits only while the queue is full. From a full queue, the count
// of records passes each number: the reader looks at the `waits` word only
// when half of the queue is free, and before it waits itself (wait_end).
receive :: proc "contextless" (queue: ^ring.Queue) -> (record: ring.Record, ok: bool) {
	record = ring.pop(queue) or_return
	if ring.count(queue) == ring.capacity(queue) / 2 {
		ring.complete(&queue.counters.read) // See wake_reader.
		if intrinsics.atomic_load(&queue.counters.writer_waits) != 0 && intrinsics.atomic_exchange(&queue.counters.writer_waits, 0) != 0 {
			word_wake(&queue.counters.read, WAKE_ALL)
		}
	}
	return record, true
}

// wake_one wakes one of the threads that wait on a word, if one waits. Call
// it after a complete change of the word.
//
// It does not enter the kernel while a thread reads the word in wait_spin:
// that thread sees the change. It does not enter the kernel again while
// the thread of the last wake does not run yet: that thread will read the
// state. Without these two rules, one thread that sleeps costs one kernel
// entry for each change of the word.
wake_one :: proc "contextless" (word: ^u32, waiters: ^ring.Waiters) {
	if intrinsics.atomic_load(&waiters.count) == 0 || intrinsics.atomic_load(&waiters.spins) != 0 {
		return
	}
	if _, ok := intrinsics.atomic_compare_exchange_strong(&waiters.wakes, 0, 1); !ok {
		return
	}
	if word_wake(word, 1) == 0 {
		// The thread of the count does not sleep yet, or does not sleep
		// now: it reads the word itself.
		intrinsics.atomic_store(&waiters.wakes, 0)
	}
}

// An event: a count that several threads wait on. The zero value is an
// event that never happened. An event in shared memory works between
// processes.
//
//   seen := system.event_count(&event)
//   ... read the state that the event changes ...
//   system.event_wait(&event, seen)
Event :: struct {
	count: u32, // The times that the event happened.
	waits: u32, // 1: a thread waits, or will wait.
}

// event_count gives the count of an event: the value to give to
// `event_wait` or `wait_event`. Read it before the state that the event
// changes, so that no event between the two is lost.
event_count :: proc "contextless" (event: ^Event) -> u32 {
	return intrinsics.atomic_load(&event.count)
}

// event_wake adds 1 to the count of the event and wakes each thread that
// waits on it. It enters the kernel only if a thread waits.
event_wake :: proc "contextless" (event: ^Event) {
	intrinsics.atomic_add(&event.count, 1)
	if intrinsics.atomic_load(&event.waits) != 0 && intrinsics.atomic_exchange(&event.waits, 0) != 0 {
		word_wake(&event.count, WAKE_ALL)
	}
}

// wait_event adds an event to a list: the thread waits while the count of
// the event is seen.
wait_event :: proc "contextless" (wait: ^Wait, event: ^Event, seen: u32) {
	wait_word(wait, &event.count, seen, &event.waits, keep_flag = true)
}

// event_wait stops the thread while the count of the event is seen, or
// until the time is deadline. It gives the time.
event_wait :: proc "contextless" (event: ^Event, seen: u32, deadline: u64 = WAIT_FOREVER) -> u64 {
	wait: Wait
	wait_event(&wait, event, seen)
	return wait_end(&wait, deadline)
}

// shared_send writes a record in a shared queue, and wakes one reader if
// it is necessary (wake_one). false: the queue is full.
shared_send :: proc "contextless" (queue: ^ring.Shared, record: ring.Record) -> bool {
	ring.shared_push(queue, record) or_return
	// A complete change of `written`, then the count of the readers that
	// wait: a reader that reads the old value of `written` is in the count.
	intrinsics.atomic_add(&queue.head.written, 1)
	wake_one(&queue.head.written, &queue.head.readers)
	return true
}

// shared_receive reads a record from a shared queue. If writers wait for
// room, it wakes them when half of the queue is free: one kernel entry,
// then the writers write many records.
shared_receive :: proc "contextless" (queue: ^ring.Shared) -> (record: ring.Record, ok: bool) {
	record = ring.shared_pop(queue) or_return
	intrinsics.atomic_add(&queue.head.taken, 1)
	if intrinsics.atomic_load(&queue.head.writer_waits) != 0 && ring.shared_count(queue) <= ring.shared_capacity(queue) / 2 && intrinsics.atomic_exchange(&queue.head.writer_waits, 0) != 0 {
		word_wake(&queue.head.taken, WAKE_ALL)
	}
	// One wake is for one reader. If a record still waits, the readers
	// that run are not enough: this reader wakes the next one.
	if ring.shared_ready(queue) {
		wake_one(&queue.head.written, &queue.head.readers)
	}
	return record, true
}

// wait_shared_records adds a shared queue that this thread reads: the
// thread waits until a writer completes a record.
wait_shared_records :: proc "contextless" (wait: ^Wait, queue: ^ring.Shared) {
	written := intrinsics.atomic_load(&queue.head.written)
	if ring.shared_ready(queue) {
		wait.full = true // A record arrived after the thread tried to read.
		return
	}
	wait_word(wait, &queue.head.written, written, waiters = &queue.head.readers)
}

// wait_shared_room adds a shared queue that this thread writes: the thread
// waits until a reader takes a record. The readers wake it when half of
// the queue is free.
wait_shared_room :: proc "contextless" (wait: ^Wait, queue: ^ring.Shared) {
	taken := intrinsics.atomic_load(&queue.head.taken)
	if ring.shared_room(queue) {
		wait.full = true
		return
	}
	wait_word(wait, &queue.head.taken, taken, &queue.head.writer_waits, keep_flag = true)
}
