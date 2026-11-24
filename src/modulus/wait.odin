package kernel

import "modulus:budget_peak"
import "base:intrinsics"
import op "modus:contract/operation"
import "modulus:word_table"

// The word wait (docs/ARCHITECTURE.md, "Locks of the kernel", "The word
// wait"). A thread that waits on a word has an entry in the table of the
// words (modulus:word_table): a bucket for each page frame, and in it one
// list for each distinct word, so a wake reads the distinct words of its
// frame and the entries of its word only. The wait lock of a bucket
// protects it: WAIT_LOCKS locks, a bucket takes the lock of its number.
// Entry n of a thread is one of its op.WORD_WAIT_INLINE entries in
// wait_entries, or, past them, an entry of its wait room: pages that the
// budget of its process paid (Thread_Control_Command.Wait_Room), which only
// the kernel maps.
//
// An entry has the wait serial of its thread at the time of the
// registration. The serial changes when the wait ends: an entry with an
// old serial is a leftover, and a waker does not count it.

WAIT_LOCKS :: 64

Wait_Lock :: struct #align (64) {
	lock: Lock,
}

Wait_Entry :: word_table.Entry
#assert(size_of(Wait_Entry) * op.WAIT_ROOM_WORDS_OF_A_PAGE == PAGE_SIZE)
#assert(op.WAIT_ROOM_PAGES_MOST * size_of(u64) == PAGE_SIZE)
#assert(word_table.PAGE_SIZE == PAGE_SIZE)

wait_locks: [WAIT_LOCKS]Wait_Lock
wait_words: word_table.Table // Its buckets: tables_start, from the frames of the machine.
wait_entries: []Wait_Entry // op.WORD_WAIT_INLINE for each thread: tables_start.

wait_lock :: #force_inline proc "contextless" (word: u64) -> ^Lock {
	return &wait_locks[word_table.bucket_of(&wait_words, word) % WAIT_LOCKS].lock
}

// wait_capacity gives the words that one entry of a thread can register:
// its inline entries, or the words of its wait room.
wait_capacity :: #force_inline proc "contextless" (thread: ^Thread) -> u32 {
	return u32(op.wait_room_words(u64(thread.wait_room_pages)))
}

// wait_entry gives entry n of a thread, below its capacity.
wait_entry :: #force_inline proc "contextless" (thread: ^Thread, n: u32) -> ^Wait_Entry {
	if n < op.WORD_WAIT_INLINE {
		return &wait_entries[thread_index(thread) * op.WORD_WAIT_INLINE + n]
	}
	place := n - op.WORD_WAIT_INLINE
	pages := direct(thread.wait_room, [op.WAIT_ROOM_PAGES_MOST]u64)
	return &direct(pages[place / op.WAIT_ROOM_WORDS_OF_A_PAGE], [op.WAIT_ROOM_WORDS_OF_A_PAGE]Wait_Entry)[place % op.WAIT_ROOM_WORDS_OF_A_PAGE]
}

// Wait_Register_Outcome: what wait_register did with one word.
Wait_Register_Outcome :: enum u8 {
	Held,      // The word holds the value: the thread can wait on it.
	Changed,   // The word does not hold the value: the thread does not wait.
	Duplicate, // The thread holds the word already in this entry: refused, and nothing changed.
}

// wait_register adds the next word of the wait of a thread: the comparison
// and the entry are one section of the wait lock. The caller makes sure
// that the page of the word stays: it holds the process lock of the
// process that maps the word, and that the thread has room for one more
// word (wait_capacity).
wait_register :: proc "contextless" (thread: ^Thread, word: u64, value: u32) -> Wait_Register_Outcome {
	entry := wait_entry(thread, thread.word_count)
	lock := wait_lock(word)
	lock_take(lock, .Wait)
	inserted, _ := word_table.insert(&wait_words, entry, word, thread_index(thread), intrinsics.atomic_load(&thread.wait_serial))
	held := intrinsics.atomic_load(direct(word, u32)) == value
	lock_free(lock, .Wait)
	if !inserted {
		return .Duplicate
	}
	thread.word_count += 1
	intrinsics.atomic_add(&processes[thread.process].waited_words, 1)
	return held ? .Held : .Changed
}

// wait_unregister removes all the entries of a thread. The thread does not
// run on another processor: its processor calls this, or the thread ended.
wait_unregister :: proc "contextless" (thread: ^Thread) {
	for n in 0 ..< thread.word_count {
		entry := wait_entry(thread, n)
		lock := wait_lock(entry.word)
		lock_take(lock, .Wait)
		word_table.remove(&wait_words, entry)
		lock_free(lock, .Wait)
	}
	if thread.word_count != 0 {
		intrinsics.atomic_sub(&processes[thread.process].waited_words, thread.word_count)
	}
	thread.word_count = 0
}

// word_wake ends the wait of at most count threads that wait on a word. A
// thread that still registers its words in its own entry counts too: it
// does not wait, and reads its words again. It reads the distinct words of
// the frame of the word, then the entries of the word only.
word_wake :: proc "contextless" (word: u64, count: u64) -> (woken: u64) {
	lock := wait_lock(word)
	lock_take(lock, .Wait)
	first, _ := word_table.first_of_word(&wait_words, word)
	for entry := first; entry != nil && woken < count; entry = entry.word_next {
		if wait_entry_wake(&threads[entry.thread], entry.serial) {
			woken += 1
		}
	}
	lock_free(lock, .Wait)
	return woken
}

// wait_room_set gives a thread a wait room of `words` words, paid by the
// budget of its process, and gives back the pages of its room before
// (op.Thread_Control_Command.Wait_Room). The new pages are taken before the
// old ones leave, so a refusal changes nothing. The thread is the calling
// thread, in its entry, with no word registered: no entry of the room is
// in a bucket.
wait_room_set :: proc "contextless" (thread: ^Thread, process: ^Process, words: u64) -> (capacity: u64, status: Operation_Outcome) {
	if words > op.WORD_WAIT_MOST {
		return 0, .Bad_Operation
	}
	if thread.word_count != 0 {
		return 0, .Bad_State
	}
	pages := op.wait_room_pages(words)
	if pages == u64(thread.wait_room_pages) {
		return op.wait_room_words(pages), .Ok
	}
	room: u64
	if pages != 0 {
		room = frame_paid(&process.budget)
		if room == 0 {
			return 0, .No_Budget
		}
		names := direct(room, [op.WAIT_ROOM_PAGES_MOST]u64)
		for page in 0 ..< pages - 1 {
			names[page] = frame_paid(&process.budget)
			if names[page] == 0 {
				wait_room_give_back(room, u32(pages), &process.budget)
				return 0, .No_Budget
			}
		}
	}
	wait_room_end(thread, process)
	thread.wait_room = room
	thread.wait_room_pages = u32(pages)
	// The library of the thread reads the room in its thread record. The
	// record is memory of the process: a false value there harms only the
	// waits of this thread, which the kernel still checks against its room.
	if record := thread.record_in_kernel; record != nil {
		intrinsics.atomic_store(&record.wait_room_words, u32(op.wait_room_words(pages)))
	}
	return op.wait_room_words(pages), .Ok
}

// wait_room_end gives the pages of the wait room of a thread back to the
// budget of its process, as a page table returns: the field of the budget
// is read under the frame lock, where the end of a budget moves it to the
// parent (budget_release). So the pages never return to a budget that
// ended. The thread has no word registered: wait_unregister ran, so no
// waker reaches an entry of the room.
wait_room_end :: proc "contextless" (thread: ^Thread, process: ^Process) {
	if thread.wait_room == 0 {
		return
	}
	wait_room_give_back(thread.wait_room, thread.wait_room_pages, &process.budget)
	thread.wait_room = 0
	thread.wait_room_pages = 0
}

// wait_room_give_back frees the frames of a room of `pages` pages, the
// page that names the others first among them, and the budget that the
// field names under the frame lock gets a page back for each frame. A name
// of 0 was never taken.
@(private = "file")
wait_room_give_back :: proc "contextless" (room: u64, pages: u32, budget_field: ^u32) {
	names := direct(room, [op.WAIT_ROOM_PAGES_MOST]u64)
	lock_take(&frame_lock, .Frame)
	budget := budget_field^
	for page in 0 ..< pages - 1 {
		if names[page] != 0 {
			frames_free_held(names[page], 1)
			budget_peak.give_back(&budgets[budget].amounts.pages, 1)
		}
	}
	frames_free_held(room, 1)
	budget_peak.give_back(&budgets[budget].amounts.pages, 1)
	lock_free(&frame_lock, .Frame)
}

// wait_entry_wake ends the wait of a thread for one of its entries. true:
// the thread waited, or registers and will not wait.
@(private = "file")
wait_entry_wake :: proc "contextless" (thread: ^Thread, serial: u32) -> bool {
	home := run_lock(thread)
	counted, queued, preempts := false, false, false
	switch {
	case thread.wait_serial != serial:
	// A leftover of a wait that ended.
	case thread.state == .Waiting:
		queued, preempts = thread_ready_held(thread)
		counted = true
	case thread.state == .Ready && !thread.woken:
		thread.woken = true
		counted = true
	}
	run_unlock(home)
	if queued {
		kick(home, thread, preempts)
	}
	return counted
}

// thread_words_wake ends the wait of a thread for its words, whatever its
// serial: a thread that waits becomes ready; a thread that registered its
// words and does not wait yet gets `woken`, and its wait_end does not wait.
// For a thread whose words name a frame that leaves its process (a
// decommit, a revocation): the caller holds the process lock of the thread,
// so no word is added meanwhile (a word is registered in the kernel entry,
// under that lock). The words can still be dropped at the start of the next
// entry of the thread (wait_begin), with no process lock: then the caller
// reads a word list that is ending, and at worst wakes a thread that waits
// no more, which only reads its words again. A thread that registers again
// later does it under the process lock, after the frames left, and finds
// the page not committed.
//
// A thread that waits for an answer of the fault ring is in no table of
// words, and its wait ends only with the answer: it is skipped. Its caller
// holds the process lock, under which fault_waits changes.
thread_words_wake :: proc "contextless" (thread: ^Thread) {
	if thread.fault_waits {
		return
	}
	home := run_lock(thread)
	queued, preempts := false, false
	switch {
	case thread.state == .Waiting:
		queued, preempts = thread_ready_held(thread)
	case thread.state == .Ready:
		thread.woken = true
	}
	run_unlock(home)
	if queued {
		kick(home, thread, preempts)
	}
}

// wait_begin starts the registration of a kernel entry: the entries of the
// last wait leave the table.
wait_begin :: proc "contextless" (thread: ^Thread) {
	wait_unregister(thread)
	thread.woken = false
	thread.word_changed = false
}

// wait_end makes the thread wait, unless a word changed or a waker came
// during the registration. With no wait, the entries become leftovers.
wait_end :: proc "contextless" (thread: ^Thread, deadline: u64) {
	if deadline == 0 && thread.word_count == 0 {
		return // No wait and no entry: nothing for a waker to see.
	}
	home := run_lock(thread)
	if deadline != 0 && !thread.word_changed && !thread.woken {
		thread.state = .Waiting
		intrinsics.atomic_store(&thread.deadline, deadline)
	} else {
		intrinsics.atomic_add(&thread.wait_serial, 1)
	}
	run_unlock(home)
}
