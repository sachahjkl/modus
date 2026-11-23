package locks

import "base:intrinsics"
import op "modus:contract/operation"
import "modus:lockers"
import "modus:random"
import "modus:system"

// A wait does not keep its frame: a process whose thread waits on a word of
// its own memory object unmaps the object and closes it, so its frames
// return to the free frames. The unmap wakes that thread first, as no one
// changes or wakes its word. Then another process takes frames, waits on a
// word of them and wakes it: the wake counts its own waiter alone, so no
// thread of the first process holds a frame that serves the second. Each
// condition is a count that the processes write: no time but the hang
// bound.
unmap_wait_case :: proc "contextless" (image: []u8) {
	unmap_woke, other_woken: u64
	right := false
	defer system.log_fact(.Info, Unmap_Wakes_Waiter{unmap_woke = unmap_woke, other_woken = other_woken, verdict = verdict_field(right)})
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
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[lockers.GRANT_BOARD] = {board_memory, {.Read, .Write}}
	values[lockers.VALUE_ROLE] = u64(lockers.Role.Unmap_Wait)
	values[lockers.VALUE_INDEX] = 0
	unmapper, start_status := system.process_start(system.image_find(image, "locker"), "unmapper", grants, random.values_with_seed(&process_generator, values), UNTOUCHED_AMOUNTS)
	if start_status != .Ok {
		return
	}
	defer system.close(unmapper)
	defer system.process_stop(unmapper)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for intrinsics.atomic_load(&board.slots[0].done) == 0 && system.time() < deadline {
		system.word_wait(&board.slots[0].done, 0, deadline)
	}
	unmap_woke = board.slots[0].limit
	// The other process: a page of its own, a waiter, and its wake.
	taker := untouched_start(image, board_memory, 1, true)
	if taker == 0 {
		return
	}
	defer system.close(taker)
	defer system.process_stop(taker)
	for intrinsics.atomic_load(&board.slots[1].done) == 0 && system.time() < deadline {
		system.word_wait(&board.slots[1].done, 0, deadline)
	}
	other_woken = board.slots[1].entries
	right = unmap_woke == 1 && other_woken == 1
}
