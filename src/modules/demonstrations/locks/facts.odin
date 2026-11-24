package locks

import "modus:contract/call_outcome"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of locks (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence, and the measure that the tool reads from
// it, read it as before. A line whose sentence differs by its case, a
// measure run or the check of a test, is one fact type for each case: the
// template has no condition.

// The lines of the lock waits and of the frame caches were each one line
// that a loop wrote, over the kinds of lock and over the processors: each
// is now one fact for each kind and for each processor, whose sentence is
// the head of the line and the part of that kind or processor. A status
// that the line wrote as its number writes the name of its member.

// The bytes of the Text field of the name of a kind of lock: the longest,
// "control" and "process", have 7 bytes.
LOCK_FIELD_BYTES :: 8

// The context of the process holds no random seed.
@(log_fact = "locks: no random seed in the context")
No_Random_Seed :: struct {}

// The process has no boot image, or no memory for the board.
@(log_fact = "locks: no boot image or no memory")
No_Boot_Image_Or_Memory :: struct {}

// The kernel refused the start of a locker.
@(log_fact = "locks: cannot start a locker: status {status}")
Locker_Not_Started :: struct {
	status: call_outcome.Call_Outcome,
}

// The stress of the starts and the stops: the processes, how each one
// stopped, and the budget and the free pages after it.
@(log_fact = "locks: stress: {started} processes started, {stopped} stopped by this process (some by a thread while another thread closed the last handle), {closed_only} only by the close of their last handle, while their threads ran and they stopped each other; budget: pages {pages} of {pages_at_start}, processes {processes} of {processes_at_start}, threads {threads} of {threads_at_start}; free pages {free_pages}, in budgets {budget_pages}, reserved {reserved_pages}")
Stress_Done :: struct {
	started:            u64,
	stopped:            u64,
	closed_only:        u64,
	pages:              u64,
	pages_at_start:     u64,
	processes:          u64,
	processes_at_start: u64,
	threads:            u64,
	threads_at_start:   u64,
	free_pages:         u64,
	budget_pages:       u64,
	reserved_pages:     u64,
}

// The waits of the locks of one kind, over the takes, while 4 lockers
// entered the kernel.
@(log_fact = "locks: lock waits of takes, 4 lockers, kernel entries: {lock} {waits} of {takes}")
Entry_Lock_Waits :: struct {
	waits: u64,
	takes: u64,
	lock:  [8]u8,
}

// The waits of the locks of one kind while 4 lockers used pages for the
// first time.
@(log_fact = "locks: lock waits of takes, 4 lockers, pages on first use: {lock} {waits} of {takes}")
Fault_Lock_Waits :: struct {
	waits: u64,
	takes: u64,
	lock:  [8]u8,
}

// The waits of the locks of one kind during the word wait with 2 lockers.
@(log_fact = "locks: lock waits of takes, word wait with 2 lockers: {lock} {waits} of {takes}")
Pair_Lock_Waits :: struct {
	waits: u64,
	takes: u64,
	lock:  [8]u8,
}

// The frame cache of one processor after the measures.
@(log_fact = "locks: frame caches after the measures (frames now, batches taken, batches given, drains): processor {processor}: {frames}, {batches_taken}, {batches_given}, {drains}")
Frame_Cache_Shown :: struct {
	processor:     u64,
	frames:        u64,
	batches_taken: u64,
	batches_given: u64,
	drains:        u64,
}

// Each check passed.
@(log_fact = "locks: ok, the kernel counted each entry, each page returned, no wake was lost, each stopped process returned its pages, its slot and its threads")
Checks_Passed :: struct {}

// lock_field gives the Text field of the name of a kind of lock.
lock_field :: proc "contextless" (kind: op.Lock_Kind) -> [LOCK_FIELD_BYTES]u8 {
	return value_kinds.text_field(op.LOCK_KIND_NAMES[kind], LOCK_FIELD_BYTES)
}

// A locker counted another number of kernel entries than the kernel.
@(log_fact = "locks: locker {locker} counted {operations} operations and {entries} entries, the kernel {kernel_entries}")
Locker_Entries_Differ :: struct {
	locker:         u64,
	operations:     u64,
	entries:        u64,
	kernel_entries: u64,
}

// The objects of 600 pages that two lockers made and closed while two
// lockers faulted pages, and the reports of the free pages.
@(log_fact = "locks: frames: {made} objects of 600 pages made and closed by two lockers while two lockers faulted {faulted} pages and this process read {reports} reports; reports where the free pages less the reserved pages were not the pages of the budgets: {wrong}")
Frames_Stress_Done :: struct {
	made:    u64,
	faulted: u64,
	reports: u64,
	wrong:   u64,
}

// The kernel entries in one second of 1, 2 and 4 lockers, each on its own
// objects: a measure run.
@(log_fact = "locks: kernel entries in one second, each locker on its own objects: 1 locker {one_locker}, 2 lockers {two_lockers}, 4 lockers {four_lockers}")
Kernel_Entries_Measured :: struct {
	one_locker:   u64,
	two_lockers:  u64,
	four_lockers: u64,
}

// The kernel entries of 1, 2 and 4 lockers in the check of a test.
@(log_fact = "locks: kernel entries, each locker on its own objects: 1 locker {one_locker}, 2 lockers {two_lockers}, 4 lockers {four_lockers}")
Kernel_Entries_Counted :: struct {
	one_locker:   u64,
	two_lockers:  u64,
	four_lockers: u64,
}

// The pages on first use in one second of 1, 2 and 4 lockers, each in its
// own memory: a measure run.
@(log_fact = "locks: pages on first use in one second, each locker in its own memory: 1 locker {one_locker}, 2 lockers {two_lockers}, 4 lockers {four_lockers}")
Pages_On_First_Use_Measured :: struct {
	one_locker:   u64,
	two_lockers:  u64,
	four_lockers: u64,
}

// The pages on first use of 1, 2 and 4 lockers in the check of a test.
@(log_fact = "locks: pages on first use, each locker in its own memory: 1 locker {one_locker}, 2 lockers {two_lockers}, 4 lockers {four_lockers}")
Pages_On_First_Use_Counted :: struct {
	one_locker:   u64,
	two_lockers:  u64,
	four_lockers: u64,
}

// The wakes in one second of two threads that wake each other, alone and
// while 2 lockers enter the kernel: a measure run.
@(log_fact = "locks: word wait, two threads wake each other: {alone} wakes in one second alone, {loaded} while 2 lockers enter the kernel, {lost} lost")
Word_Wait_Measured :: struct {
	alone:  u64,
	loaded: u64,
	lost:   u64,
}

// The wakes of two threads that wake each other in the check of a test.
@(log_fact = "locks: word wait, two threads wake each other: {alone} wakes alone, {loaded} while 2 lockers enter the kernel, {lost} lost")
Word_Wait_Counted :: struct {
	alone:  u64,
	loaded: u64,
	lost:   u64,
}

// The wait room of the kernel at its edges (wait_room.odin).
@(log_fact = "locks: the wait room: with no room a wait of {inline_words} words and one more {no_room_status}; a word twice in a wait {twice_status}; a room past {most_words} words {too_many_status}, for another thread {other_status}; a room of {asked} words held {held} words for {pages} pages of the budget; a wait of that many words {held_status}, of one more {past_status}; the room given back returned its pages: {returned}: {verdict}")
Wait_Room_Checked :: struct {
	inline_words:    u64,
	no_room_status:  call_outcome.Call_Outcome_Word,
	twice_status:    call_outcome.Call_Outcome_Word,
	most_words:      u64,
	too_many_status: call_outcome.Call_Outcome_Word,
	other_status:    call_outcome.Call_Outcome_Word,
	asked:           u64,
	held:            u64,
	pages:           u64,
	held_status:     call_outcome.Call_Outcome_Word,
	past_status:     call_outcome.Call_Outcome_Word,
	returned:        u64,
	verdict:         [16]u8,
}

// The pages of a room returned to the budget at each end of the room.
@(log_fact = "locks: the pages of a wait room returned at the end of its thread: {thread_end}; at the stop of its process during a wait: {stopped_back}; at the stop of its process after its budget ended: {ended_back}: {verdict}")
Wait_Room_Ends :: struct {
	thread_end:   u64,
	stopped_back: u64,
	ended_back:   u64,
	verdict:      [16]u8,
}

// One wait of the most words, in one kernel entry: a measure.
@(log_fact = "locks: a wait of {words} words: {status} in {time} (a measure)")
Wait_Room_Long :: struct {
	words:  u64,
	status: call_outcome.Call_Outcome_Word,
	time:   value_kinds.Time_In_Microseconds,
}

// A wake through a read-only mapping of the word.
@(log_fact = "locks: a wake of a word through a read-only mapping {status}, and the thread that waits on it still waits: {still_waits}; a wake through the mapping with Write woke {woken} thread: {verdict}")
Read_Only_Wake_Refused :: struct {
	status:      call_outcome.Call_Outcome_Word,
	still_waits: u64,
	woken:       u64,
	verdict:     [16]u8,
}

// The time of one unmap of a mapping whose pages each have a frame, with no
// waited word in the process, and with one: a measure.
@(log_fact = "locks: an unmap of {pages} pages took {alone} with no thread waiting on a word of it, {waited} with a thread waiting on its last word (a measure)")
Unmap_Time :: struct {
	pages:  u64,
	alone:  value_kinds.Time_In_Microseconds,
	waited: value_kinds.Time_In_Microseconds,
}

// One wake of the last word of a bucket that holds the words of a frame.
@(log_fact = "locks: a wake of a word of a frame whose {words} words a thread waits on woke {woken} thread in {time} (a measure)")
Full_Frame_Wake :: struct {
	words: u64,
	woken: u64,
	time:  value_kinds.Time_In_Microseconds,
}

// The unmap of a waited object wakes its waiter; the next user of frames
// wakes its own waiter alone.
@(log_fact = "locks: a thread that waits on a word of an object that its process unmaps and closes was woken by the unmap: {unmap_woke}; another process that takes frames woke {other_woken} thread with its own wake: {verdict}")
Unmap_Wakes_Waiter :: struct {
	unmap_woke:  u64,
	other_woken: u64,
	verdict:     [16]u8,
}

// Two processes wait each on a word of a page that they never touched.
@(log_fact = "locks: two processes wait each on a word of a page that they never touched: the wake of one counted {woken} thread, and the other still waits: {other_waits}: {verdict}")
Untouched_Page_Waits :: struct {
	woken:       u64,
	other_waits: u64,
	verdict:     [16]u8,
}

// verdict_field gives the Text field of the verdict of a case in the words
// of the line: "as it must" or "WRONG".
verdict_field :: proc "contextless" (right: bool) -> [16]u8 {
	return value_kinds.text_field(right ? "as it must" : "WRONG", 16)
}

// A check failed: each check as 1 when it passed, and the lost wakes.
@(log_fact = "locks: wrong: entries {entries_right} faults {faults_right} pages {pages_right} wakes {wakes_right} lost {lost} stress {stress_right} frames {frames_right}")
Checks_Wrong :: struct {
	entries_right: u64,
	faults_right:  u64,
	pages_right:   u64,
	wakes_right:   u64,
	lost:          u64,
	stress_right:  u64,
	frames_right:  u64,
}
