package locks

import "base:intrinsics"
import op "modus:contract/operation"
import "modus:lockers"
import "modus:random"
import "modus:system"

// Two processes wait each on the word at one offset of a page that no
// instruction of theirs touched. The kernel makes the page of each present
// before it registers the word (src/md/data/table_sizes.md, "The word of a
// wait is a frame of its process"), so the two words are two frames: the
// wake of the first counts its own waiter alone, and the waiter of the
// second still waits. Each condition is a count and a state that the
// kernel reports: no time but the hang bound.
UNTOUCHED_AMOUNTS :: system.Budget_Amounts{pages = 1024, processes = 1, threads = 2, processor = 1_000_000, log_records = 10}

untouched_threads: op.Thread_Table_Report

// untouched_waiting gives the threads of a process that wait, or 0 when the
// report is refused.
untouched_waiting :: proc "contextless" (process: system.Handle) -> (waiting: u64) {
	slot, _, place_status := system.process_place(process)
	if place_status != .Ok {
		return 0
	}
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Threads), slot, u64(uintptr(&untouched_threads)), size_of(untouched_threads)); status != .Ok {
		return 0
	}
	for &thread in untouched_threads.threads[:min(untouched_threads.count, op.THREAD_REPORT_CAPACITY)] {
		if thread.state == .Waiting {
			waiting += 1
		}
	}
	return waiting
}

untouched_start :: proc "contextless" (image: []u8, board: system.Handle, index: u64, wakes: bool) -> system.Handle {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[lockers.GRANT_BOARD] = {board, {.Read, .Write}}
	values[lockers.VALUE_ROLE] = u64(lockers.Role.Untouched_Wait)
	values[lockers.VALUE_INDEX] = index
	values[lockers.VALUE_WAKES] = wakes ? 1 : 0
	process, _ := system.process_start(system.image_find(image, "locker"), wakes ? "waker" : "sleeper", grants, random.values_with_seed(&process_generator, values), UNTOUCHED_AMOUNTS)
	return process
}

untouched_page_case :: proc "contextless" (image: []u8) {
	woken: u64
	other_waits := false
	right := false
	defer system.log_fact(.Info, Untouched_Page_Waits{woken = woken, other_waits = u64(other_waits), verdict = verdict_field(right)})
	board_memory, memory_status := system.memory_create(1)
	if memory_status != .Ok {
		return
	}
	defer system.close(board_memory)
	address, map_status := system.memory_map(board_memory)
	if map_status != .Ok {
		return
	}
	defer system.memory_unmap(address)
	board := (^lockers.Board)(address)
	// The sleeper first: its two threads wait, its waiter on its word.
	sleeper := untouched_start(image, board_memory, 0, false)
	if sleeper == 0 {
		return
	}
	defer system.close(sleeper)
	defer system.process_stop(sleeper)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for untouched_waiting(sleeper) < 2 && system.time() < deadline {
		system.sleep(system.time() + 1)
	}
	if untouched_waiting(sleeper) < 2 {
		return
	}
	waker := untouched_start(image, board_memory, 1, true)
	if waker == 0 {
		return
	}
	defer system.close(waker)
	defer system.process_stop(waker)
	for intrinsics.atomic_load(&board.slots[1].done) == 0 && system.time() < deadline {
		system.word_wait(&board.slots[1].done, 0, deadline)
	}
	woken = board.slots[1].entries
	other_waits = untouched_waiting(sleeper) == 2 && intrinsics.atomic_load(&board.slots[0].count) == 0
	right = woken == 1 && other_waits
}
