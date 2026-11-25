package system

import "modus:contract/call_outcome"
import "modus:contract/errors"
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

// The words that a wait holds in itself, on the stack of its thread: about
// 3.5 KiB. A stream end, a call and a window wait on fewer
// (src/md/data/table_sizes.md, "A wait holds 64 words on the stack"). The
// kernel holds as many for each thread with no wait room.
WAIT_INLINE_WORDS :: op.WORD_WAIT_INLINE

// What wait_end does with one word of a list, past its value.
Wait_Part :: struct {
	flag:       ^u32, // The `waits` word of a queue: wait_end sets it.
	other_flag: ^u32, // A queue: the `waits` word of the other side.
	other_word: ^u32, // A queue: the counter that the other side waits on.
	waiters:    ^ring.Waiters, // A word that several threads wait on, when one wake is for one thread.
	kept:       bool, // Several threads set the flag: the thread does not clear it after the wait.
}

// The places of a list of more than WAIT_INLINE_WORDS words, in memory of
// the caller: a thread that waits on the rings of many clients sizes one
// to its tables, keeps it in its globals or its arena (wait_set_of), and
// gives it to wait_begin. The first wait_begin with the set asks the kernel
// for a wait room of its words for the calling thread
// (op.Thread_Control_Command.Wait_Room), which the budget of the process
// pays. One set serves one thread: the room is of the thread that asked,
// and two threads that fill one set at once mix their lists.
Wait_Set :: struct {
	words:   []op.Word,
	parts:   []Wait_Part,
	// The kernel refused the room for this set once (the budget cannot pay
	// it): the set asks no more, and holds the room that the thread has.
	refused: bool,
}

// wait_set_of gives a set of the places of the caller: words and parts of
// one length, at most op.WORD_WAIT_MOST. It asks the kernel for nothing:
// the first wait_begin of the thread that waits does.
wait_set_of :: proc "contextless" (words: []op.Word, parts: []Wait_Part) -> Wait_Set {
	count := min(len(words), len(parts), op.WORD_WAIT_MOST)
	return {words = words[:count], parts = parts[:count]}
}

// thread_wait_room gives the words that each wait of the calling thread
// holds: its wait room, which the kernel writes in its thread record, and
// WAIT_INLINE_WORDS with no room. The room is of the thread: every set that
// the thread uses shares it.
thread_wait_room :: proc "contextless" () -> int {
	return max(int(intrinsics.atomic_load(&thread_record().wait_room_words)), WAIT_INLINE_WORDS)
}

// wait_set_room grows the wait room of the calling thread to the words of a
// set, when the room is smaller: never smaller, so a room never shrinks
// under another set of the same thread. A refusal (the budget cannot pay
// the pages) writes one line, and the set asks no more: its lists hold the
// room that the thread has.
@(private = "file")
wait_set_room :: proc "contextless" (set: ^Wait_Set) {
	if set.refused || len(set.words) <= thread_wait_room() {
		return
	}
	if _, status := call(.Thread_Control, 0, 0, u64(op.Thread_Control_Command.Wait_Room), 0, u64(len(set.words))); status != .Succeeded {
		set.refused = true
		log(.Error, "system: the kernel gave no wait room of ", u64(len(set.words)), " words to this thread: its waits hold ", u64(thread_wait_room()), " words, and a wait on more waits until its deadline")
	}
}



// The list of the words of one wait, built by `wait_begin` and the
// `wait_` procedures, ended by `wait_end`. It lives on the stack of the
// thread for one turn of its loop, with WAIT_INLINE_WORDS places, or with
// the places of a Wait_Set of the caller. The `waits` flags of the queues
// take places too.
Wait :: struct {
	inline_words: [WAIT_INLINE_WORDS]op.Word, // The words, and the value that each one holds while the thread waits.
	inline_parts: [WAIT_INLINE_WORDS]Wait_Part,
	set:          ^Wait_Set, // The places of the caller; nil: the places above.
	room:         int, // With a set: the words of the room of the thread when the list began (thread_wait_room).
	count:        int, // The words in the list.
	flag_count:   int, // The words that have a flag: wait_end adds one word for each.
	full:         bool, // A word changed, or a queue has room now: the wait ends at once.
	// A word did not fit. The caller bounds its words by wait_room_left
	// and refuses what does not fit; a list that overflows anyway is a
	// fault of the caller, which wait_end writes on the log once and does
	// not turn into a loop with no wait.
	refused:      bool,
}

// wait_words gives the places of the words of a list.
@(private = "file")
wait_words :: #force_inline proc "contextless" (wait: ^Wait) -> []op.Word {
	return wait.set != nil ? wait.set.words[:min(len(wait.set.words), wait.room)] : wait.inline_words[:]
}

// wait_parts gives the places of the parts of a list.
@(private = "file")
wait_parts :: #force_inline proc "contextless" (wait: ^Wait) -> []Wait_Part {
	return wait.set != nil ? wait.set.parts[:min(len(wait.set.parts), wait.room)] : wait.inline_parts[:]
}

// wait_room_left gives the words that a list still takes, with the flags
// that wait_end adds: a caller that adds a ring for each client checks it,
// and refuses a client past it.
wait_room_left :: proc "contextless" (wait: ^Wait) -> int {
	return len(wait_words(wait)) - wait.count - wait.flag_count
}

// wait_overflow_told: the line of a list that overflowed is on the log.
@(private = "file")
wait_overflow_told: bool

SPIN_COUNT :: 400 // The times that wait_spin reads the words: some microseconds.

// events gives the address of the event word of the thread that runs. The
// kernel adds 1 to it when an interrupt of the process arrives, when a
// process that this process holds stops, and when another thread ends.
events :: proc "contextless" () -> ^u32 {
	return &thread_record().events
}

// wait_begin starts a list with the event word. Call it before the thread
// reads the state that an event changes. set: the places of the caller for
// a list of more than WAIT_INLINE_WORDS words; nil: the places of the list.
wait_begin :: proc "contextless" (set: ^Wait_Set = nil) -> (wait: Wait) {
	// A set that holds no word yet (a Growing_Wait_Set before its first
	// growth) waits in the places of the list.
	if set != nil && len(set.words) > 0 {
		wait_set_room(set)
		wait.room = thread_wait_room()
		wait.set = set
	}
	word := events()
	wait_word(&wait, word, intrinsics.volatile_load(word))
	return wait
}

// wait_of_set starts a list in the places of a set with no word, for a
// loop that adds the event word itself or waits on none.
wait_of_set :: proc "contextless" (set: ^Wait_Set) -> (wait: Wait) {
	if len(set.words) == 0 {
		return wait
	}
	wait_set_room(set)
	wait.set = set
	wait.room = thread_wait_room()
	return wait
}

// A set whose places grow with the tables of its owner: a thread that
// waits on a ring for each entry of a table that has no fixed count. The
// words and the parts are in two arenas of the budget of the process, which
// never move, so a set grows with no copy. The first wait_begin after a
// growth asks the kernel for the room of the new count.
Growing_Wait_Set :: struct {
	set:   Wait_Set,
	words: Arena,
	parts: Arena,
	made:  bool,
}

// wait_set_grow makes a set hold count words, at most op.WORD_WAIT_MOST,
// the largest wait of the kernel. false: the budget does not pay the
// places, and the set keeps the words that it holds.
wait_set_grow :: proc "contextless" (growing: ^Growing_Wait_Set, count: int) -> bool {
	wanted := min(count, op.WORD_WAIT_MOST)
	held := len(growing.set.words)
	if wanted <= held {
		return true
	}
	if !growing.made {
		// The arenas reserve the places of the largest wait, and commit
		// only what a growth pushes.
		words, words_status := arena_create(u64(op.WORD_WAIT_MOST * size_of(op.Word) + PAGE_SIZE - 1) / PAGE_SIZE)
		if words_status != .Succeeded {
			return false
		}
		parts, parts_status := arena_create(u64(op.WORD_WAIT_MOST * size_of(Wait_Part) + PAGE_SIZE - 1) / PAGE_SIZE)
		if parts_status != .Succeeded {
			_ = arena_end(&words)
			return false
		}
		// Exact commits keep both small tables to the pages the wait needs
		// instead of committing ARENA_GROWTH_STEP_FIRST_PAGES each.
		words.exact_commits = true
		parts.exact_commits = true
		growing.words, growing.parts, growing.made = words, parts, true
	}
	added := wanted - held
	words_place, words_status := arena_push(&growing.words, u64(added * size_of(op.Word)), align_of(op.Word))
	if words_status != .Succeeded {
		return false
	}
	parts_place, parts_status := arena_push(&growing.parts, u64(added * size_of(Wait_Part)), align_of(Wait_Part))
	if parts_status != .Succeeded {
		_ = arena_pop(&growing.words, u64(added * size_of(op.Word)))
		return false
	}
	intrinsics.mem_zero(words_place, added * size_of(op.Word))
	intrinsics.mem_zero(parts_place, added * size_of(Wait_Part))
	// A room that the kernel refused for the smaller set is asked again
	// for the larger one: the budget can pay it now.
	growing.set = wait_set_of(([^]op.Word)(growing.words.base)[:wanted], ([^]Wait_Part)(growing.parts.base)[:wanted])
	return true
}

// wait_word adds a word: the thread waits while the word holds value.
// word_wake ends the wait. false: the list has no place for it, and is
// refused (Wait.refused).
wait_word :: proc "contextless" (wait: ^Wait, word: ^u32, value: u32, flag: ^u32 = nil, other_flag: ^u32 = nil, other_word: ^u32 = nil, waiters: ^ring.Waiters = nil, keep_flag := false) -> bool {
	if wait_room_left(wait) < (flag != nil ? 2 : 1) {
		wait.refused = true
		return false
	}
	if flag != nil {
		wait.flag_count += 1
	}
	wait_words(wait)[wait.count] = {address = u64(uintptr(word)), value = u64(value)}
	wait_parts(wait)[wait.count] = {flag = flag, other_flag = other_flag, other_word = other_word, waiters = waiters, kept = keep_flag}
	wait.count += 1
	return true
}

// wait_records adds a queue that this thread reads: the thread waits while
// the queue is empty.
wait_records :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) -> bool {
	counters := queue.counters
	return wait_word(wait, &counters.write, intrinsics.atomic_load_explicit(&counters.read, .Relaxed), &counters.reader_waits, &counters.writer_waits, &counters.read)
}

// wait_room adds a queue that this thread writes: the thread waits while
// the queue is full. The reader wakes it when half of the queue is free.
wait_room :: proc "contextless" (wait: ^Wait, queue: ^ring.Queue) -> bool {
	counters := queue.counters
	return wait_word(wait, &counters.read, intrinsics.atomic_load_explicit(&counters.write, .Relaxed) - ring.capacity(queue), &counters.writer_waits, &counters.reader_waits, &counters.write)
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
	parts := wait_parts(wait)[:wait.count]
	for part in parts {
		if part.waiters != nil {
			intrinsics.atomic_add(&part.waiters.spins, 1)
		}
	}
	defer for part in parts {
		if part.waiters != nil {
			intrinsics.atomic_sub(&part.waiters.spins, 1)
		}
	}
	for _ in 0 ..< SPIN_COUNT {
		for word in wait_words(wait)[:wait.count] {
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
	// A list that overflowed waits on the words that it holds until its
	// deadline: never a loop with no wait. Its caller did not bound its
	// words, and the log says so once.
	if wait.refused && !wait_overflow_told {
		wait_overflow_told = true
		log(.Error, "system: a wait held more words than its ", u64(len(wait_words(wait))), " places: it waits on the first ones until its deadline; its process bounds its words by wait_room_left, or gives wait_begin a wait set")
	}
	words := wait_words(wait)
	parts := wait_parts(wait)
	// A `waits` word is also a word of the wait: the thread waits while it
	// is 1. The other side sets it to 0 before each wake. A late wake, for
	// a record that this thread already read, can set it to 0 before this
	// thread waits: the wait then ends at once, and no later wake is lost.
	total := wait.count
	for index in 0 ..< wait.count {
		if flag := parts[index].flag; flag != nil {
			intrinsics.atomic_store(flag, 1)
			words[total] = {address = u64(uintptr(flag)), value = 1}
			total += 1
		}
		if waiters := parts[index].waiters; waiters != nil {
			// The other side changes the word before it reads the count:
			// the kernel then reads a new value, and this thread does not
			// stop.
			intrinsics.atomic_add(&waiters.count, 1)
		}
		// This thread does nothing with the queue while it waits. If the
		// other side waits for this thread, it must continue now: a writer
		// that waits for half of the queue, or a reader that was not told
		// of the last records (ring.push with no wake_reader).
		if other := parts[index].other_flag; other != nil && intrinsics.atomic_exchange(other, 0) != 0 {
			word_wake(parts[index].other_word, WAKE_ALL)
		}
	}
	// The kernel reads each word again: a record that arrived before the
	// `waits` word was set ends the wait at once. On a kernel ring that holds
	// other records, commands_call pushes nothing and gives the time: an
	// early end is an answer of each wait, as its caller reads its words
	// again, and no held command keeps the address of these words after
	// this frame ends (src/md/api/kernel_ring_completion_room.md).
	commands := [1]ring.Record{wait_command(words[:total])}
	completions: [1]ring.Record
	now, _ := commands_call(commands[:], completions[:], max(deadline, 1))
	// The kernel refuses a list that names one word twice, and the entry
	// does not wait. Such a list is a fault of its caller: the list loses its
	// second places and waits again, so no loop turns with no wait, and the
	// log says it once. The search runs on this refusal only.
	if is_duplicate_word_refusal(completions[0]) {
		if !wait_twice_told {
			wait_twice_told = true
			log(.Error, "system: a wait named a word twice, which the kernel refuses: the list waits on each word once; its process adds each word once")
		}
		kept, ends_at_once := words_once(words[:total])
		if !ends_at_once {
			commands = {wait_command(words[:kept])}
			now, _ = commands_call(commands[:], completions[:], max(deadline, 1))
			// The kernel compares frames, this search addresses: two
			// mappings of one frame are two addresses of one word. The record
			// names the place of that word, and the words before it hold no
			// word twice: the wait takes them until its deadline, never a
			// loop with no wait.
			if is_duplicate_word_refusal(completions[0]) {
				commands = {wait_command(words[:words_before_refused(completions[0], kept)])}
				now, _ = commands_call(commands[:], completions[:], max(deadline, 1))
			}
		}
	}
	// The thread does not wait now: the other side does not need to wake it.
	for index in 0 ..< wait.count {
		// A flag that several threads set stays: another thread can still
		// wait with it.
		if flag := parts[index].flag; flag != nil && !parts[index].kept {
			intrinsics.atomic_store(flag, 0)
		}
		if waiters := parts[index].waiters; waiters != nil {
			intrinsics.atomic_sub(&waiters.count, 1)
			intrinsics.atomic_store(&waiters.wakes, 0) // This thread runs: see wake_one.
		}
	}
	return now
}

// wait_twice_told: the line of a list that named a word twice is on the log.
@(private = "file")
wait_twice_told: bool

// is_duplicate_word_refusal says whether a Word_Wait completion refused
// because the list named one word twice.
@(private = "package")
is_duplicate_word_refusal :: proc "contextless" (completion: ring.Record) -> bool {
	if completion.kind != u32(call_outcome.Call_Outcome.Argument_Refused) {
		return false
	}
	record := transmute(errors.Error_Record)completion.values
	return record.kind == i64(errors.Kind.Bad_Value) && record.unit == i64(errors.Unit.Words)
}

// words_before_refused gives the words of a list before the word that the
// kernel refused as named twice: the place that the error record of the
// completion names (Bad_Value of the unit Words), at most the count of the
// list. A record of another kind gives 0 words: the wait then waits on no
// word, until its deadline. A pure part of wait_end, so the host tests it.
@(private = "package")
words_before_refused :: proc "contextless" (completion: ring.Record, count: int) -> int {
	record := transmute(errors.Error_Record)completion.values
	if record.kind != i64(errors.Kind.Bad_Value) || record.unit != i64(errors.Unit.Words) || record.value < 0 {
		return 0
	}
	return int(min(u64(record.value), u64(count)))
}

// words_once keeps the first place of each word of a list, in its order,
// and gives the count kept. ends_at_once: one word named with two values,
// which it cannot both hold, so the wait ends at once. A pure part of
// wait_end, so the host tests it.
@(private = "package")
words_once :: proc "contextless" (words: []op.Word) -> (kept: int, ends_at_once: bool) {
	for word in words {
		seen := false
		for earlier in words[:kept] {
			if earlier.address == word.address {
				seen = true
				ends_at_once ||= u32(earlier.value) != u32(word.value)
			}
		}
		if !seen {
			words[kept] = word
			kept += 1
		}
	}
	return kept, ends_at_once
}

// wait_command gives the command Word_Wait of the words of a list. A pure
// part of wait_end, so the host tests what it pushes.
@(private = "package")
wait_command :: proc "contextless" (words: []op.Word) -> ring.Record {
	return {kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(raw_data(words))), 1 = u64(len(words))}}
}

// word_wait stops the thread while the word holds value, until word_wake
// names the word or until the time is deadline. It gives the time.
// The word can be in memory that another process maps.
// Read the word again after the wait: the deadline also ends it. It holds
// one word on the stack, not a whole list: the threads that wait on one
// word have small stacks.
word_wait :: proc "contextless" (word: ^u32, value: u32, deadline: u64 = WAIT_FOREVER) -> u64 {
	words := [1]op.Word{{address = u64(uintptr(word)), value = u64(value)}}
	commands := [1]ring.Record{wait_command(words[:])}
	completions: [1]ring.Record
	now, _ := commands_call(commands[:], completions[:], max(deadline, 1))
	return now
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
	receive_wake_writer(queue)
	return record, true
}

// receive_erasing receives a record as receive does, and writes zeros over
// its slot in the ring: the reader of a ring that can carry a key calls it.
receive_erasing :: proc "contextless" (queue: ^ring.Queue) -> (record: ring.Record, ok: bool) {
	record = ring.pop_erasing(queue) or_return
	receive_wake_writer(queue)
	return record, true
}

@(private = "file")
receive_wake_writer :: proc "contextless" (queue: ^ring.Queue) {
	if ring.count(queue) == ring.capacity(queue) / 2 {
		ring.complete(&queue.counters.read) // See wake_reader.
		if intrinsics.atomic_load(&queue.counters.writer_waits) != 0 && intrinsics.atomic_exchange(&queue.counters.writer_waits, 0) != 0 {
			word_wake(&queue.counters.read, WAKE_ALL)
		}
	}
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
wait_event :: proc "contextless" (wait: ^Wait, event: ^Event, seen: u32) -> bool {
	return wait_word(wait, &event.count, seen, &event.waits, keep_flag = true)
}

// event_wait stops the thread while the count of the event is seen, or
// until the time is deadline. It gives the time. It holds the word of the
// event and its flag on the stack, not a whole list.
event_wait :: proc "contextless" (event: ^Event, seen: u32, deadline: u64 = WAIT_FOREVER) -> u64 {
	intrinsics.atomic_store(&event.waits, 1)
	words := [2]op.Word{{address = u64(uintptr(&event.count)), value = u64(seen)}, {address = u64(uintptr(&event.waits)), value = 1}}
	commands := [1]ring.Record{wait_command(words[:])}
	completions: [1]ring.Record
	now, _ := commands_call(commands[:], completions[:], max(deadline, 1))
	// The flag stays: another thread can wait with it (wait_event keeps it too).
	return now
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
wait_shared_records :: proc "contextless" (wait: ^Wait, queue: ^ring.Shared) -> bool {
	written := intrinsics.atomic_load(&queue.head.written)
	if ring.shared_ready(queue) {
		wait.full = true // A record arrived after the thread tried to read.
		return true
	}
	return wait_word(wait, &queue.head.written, written, waiters = &queue.head.readers)
}

// wait_shared_room adds a shared queue that this thread writes: the thread
// waits until a reader takes a record. The readers wake it when half of
// the queue is free.
wait_shared_room :: proc "contextless" (wait: ^Wait, queue: ^ring.Shared) -> bool {
	taken := intrinsics.atomic_load(&queue.head.taken)
	if ring.shared_room(queue) {
		wait.full = true
		return true
	}
	return wait_word(wait, &queue.head.taken, taken, &queue.head.writer_waits, keep_flag = true)
}
