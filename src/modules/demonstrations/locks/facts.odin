package locks

// The log facts of locks (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence, and the measure that the tool reads from
// it, read it as before. A line whose sentence differs by its case, a
// measure run or the check of a test, is one fact type for each case: the
// template has no condition.
//
// Lines stay text: the lines with no value; a status written as its number;
// the line of the stress, whose template passes the bound of one fact; and
// the lines that a loop writes, over the kinds of lock and over the
// processors, whose sentence has no fixed form.

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
