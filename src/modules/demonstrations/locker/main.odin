// A module that the process `locks` starts several times, to load the
// kernel from several processes at one time (package modus:lockers). It
// works only on its own objects: another process never waits for it, unless
// the kernel makes it wait.
//
//
// **What it is for.** The process `locks` needs load on the kernel from
// several processes whose kernel entries touch no common object: then a
// locker waits for another one only when a lock of the kernel makes it
// wait, and the waits that `locks` counts are the cost of the
// [locks of the kernel](term:lock-of-the-kernel). This process is that
// load.
//
// **What a reader sees.** Nothing of its own: no window, no menu line. It
// runs while `locks` measures, and `locks` writes its counts.
//
// **How it works.** `locks` starts it from the boot image with a
// [locker](term:locker) slot of a shared board (`lockers.Board`). The
// locker waits on the word `command` of its slot, then runs the mode that
// the slot names until the time `end` of the command, or until the count
// `limit` of the command: `Entries` (one cheap kernel
// operation on its own object, as often as it can), `Faults` (pages on
// first use: create, map, write one byte in each page, unmap, close), or
// `Large` (create and close a memory object of 600 pages). It counts its
// operations and its kernel entries in its slot. In the stress case
// (`lockers.ROLE_CHURN`) it starts and stops processes with a peer instead.
//
// **Its grants**: none of the root service. The board and its role come
// from `locks`.
package locker

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:lockers"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:system"

// entries enters the kernel with one cheap operation on an own object,
// until the time is end or the count is limit (0: no limit).
entries :: proc "contextless" (memory: system.Handle, end, limit: u64) -> (count: u64) {
	for system.time() < end && (limit == 0 || count < limit) {
		for _ in 0 ..< 64 {
			system.call(.Memory_Size, u64(memory))
		}
		count += 64
	}
	return count
}

// fault_round creates a memory object, maps it, writes one byte in each
// page, unmaps it and closes it. Each first write is a page fault on first
// use. It gives the pages written.
fault_round :: proc "contextless" () -> u64 {
	memory, status := system.memory_create(lockers.FAULT_PAGES)
	if status != .Succeeded {
		return 0
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory, {.Write}, 0, lockers.FAULT_ADDRESS)
	if map_status != .Succeeded {
		return 0
	}
	for &page in ([^][system.PAGE_SIZE]u8)(address)[:lockers.FAULT_PAGES] {
		intrinsics.volatile_store(&page[0], 1)
	}
	system.memory_unmap(address)
	return lockers.FAULT_PAGES
}

// faults repeats fault_round until the time is end or the pages are limit
// (0: no limit).
faults :: proc "contextless" (end, limit: u64) -> (count: u64) {
	for system.time() < end && (limit == 0 || count < limit) {
		count += fault_round()
	}
	return count
}

spin :: proc "c" (parameter: rawptr) -> ! {
	for {
		intrinsics.cpu_relax()
	}
}

brief :: proc "c" (parameter: rawptr) -> ! {
	system.thread_stop()
}

// churn is the role of a locker in the stress case (lockers.ROLE_CHURN).
churn :: proc "contextless" (stop_after: u64, peer: system.Handle) -> ! {
	start := system.time()
	stop_after := stop_after
	spinners: [2]system.Thread
	for &spinner in spinners {
		spinner, _ = system.thread_start(spin, nil)
	}
	for round := 0; ; round += 1 {
		if stop_after != 0 && system.time() >= start + stop_after {
			if peer == 0 {
				system.stop(.Done)
			}
			// Two processes stop each other: `locks` stops this one now too.
			system.process_stop(peer)
			stop_after = 0
		}
		if thread, status := system.thread_start(brief, nil); status == .Succeeded {
			system.thread_wait(thread)
		}
		spinner := &spinners[round % len(spinners)]
		if spinner.handle != 0 {
			system.thread_end(spinner^)
		}
		spinner^, _ = system.thread_start(spin, nil)
	}
}

// entry runs the role that `locks` wrote in the context: the stress case
// (`churn`), or a locker slot of the board. A locker prepares the page
// tables of its range, tells `locks` that it is ready, then waits for each
// command and runs its mode until the next one. With no board or a slot
// number past the board, it stops with `Failed`.
// wait_room_role is the role of a locker in the case of the wait room
// (lockers.ROLE_WAIT_ROOM). The status of the room is the count of the
// slot, for `locks` to check.
wait_room_role :: proc "contextless" (ctx: ^system.Context) -> ! {
	address, status := system.memory_map(ctx.handles[lockers.GRANT_BOARD])
	if status != .Succeeded {
		system.stop(.Failed)
	}
	slot := &(^lockers.Board)(address).slots[0]
	_, room_status := system.call(.Thread_Control, 0, 0, u64(op.Thread_Control_Command.Wait_Room), 0, ctx.values[lockers.VALUE_ROOM_WORDS])
	if ctx.values[lockers.VALUE_BUDGET_END] != 0 {
		system.close(system.own_budget())
	}
	slot.count = u64(room_status)
	intrinsics.atomic_add(&slot.done, 1)
	system.word_wake(&slot.done, system.WAKE_ALL)
	// Each word holds 0 and the wait names 0: the wait has no end but the
	// stop of the process.
	waited: [lockers.ROOM_WAITED]u32
	words: [lockers.ROOM_WAITED]op.Word
	for &word, index in words {
		word = {address = u64(uintptr(&waited[index])), value = 0}
	}
	for {
		commands := [1]ring.Record{{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&words[0])), 1 = len(words)}}}
		completions: [1]ring.Record
		system.commands_call(commands[:], completions[:], system.WAIT_FOREVER)
	}
}

// The slot and the word of the role of the untouched page.
untouched_slot: ^lockers.Slot
untouched_word: ^u32

// untouched_waiter waits on the word of a page that no instruction of this
// process touched, until a wake or the hang bound, and counts the end.
untouched_waiter :: proc "c" (parameter: rawptr) -> ! {
	words := [1]op.Word{{address = u64(uintptr(untouched_word)), value = 0}}
	commands := [1]ring.Record{{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&words[0])), 1 = 1}}}
	completions: [1]ring.Record
	system.commands_call(commands[:], completions[:], system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	intrinsics.atomic_add(&untouched_slot.count, 1)
	system.thread_stop()
}

// untouched_role is the role of a locker in the case of the untouched page
// (lockers.ROLE_UNTOUCHED_WAIT).
untouched_role :: proc "contextless" (ctx: ^system.Context) -> ! {
	board, board_status := system.memory_map(ctx.handles[lockers.GRANT_BOARD])
	index := ctx.values[lockers.VALUE_INDEX]
	memory, memory_status := system.memory_create(1)
	page: rawptr
	page_status := memory_status
	if memory_status == .Succeeded {
		page, page_status = system.memory_map(memory, {.Write})
	}
	if board_status != .Succeeded || page_status != .Succeeded || index >= lockers.LOCKER_CAPACITY {
		system.stop(.Failed)
	}
	untouched_slot = &(^lockers.Board)(board).slots[index]
	untouched_word = (^u32)(uintptr(page) + lockers.UNTOUCHED_OFFSET)
	if _, started := system.thread_start(untouched_waiter, nil); started != .Succeeded {
		system.stop(.Failed)
	}
	if ctx.values[lockers.VALUE_WAKES] != 0 {
		deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
		for system.time() < deadline {
			if woken := system.word_wake(untouched_word, system.WAKE_ALL); woken != 0 {
				untouched_slot.entries = woken
				break
			}
			system.sleep(system.time() + 1)
		}
	}
	intrinsics.atomic_add(&untouched_slot.done, 1)
	system.word_wake(&untouched_slot.done, system.WAKE_ALL)
	for {
		system.word_wait(&untouched_slot.command, intrinsics.atomic_load(&untouched_slot.command))
	}
}

// 1: the waiter of the role of the unmap ended its wait.
unmap_waiter_ended: u32

// The waiter of the role of the unmap: it waits on its word until the hang
// bound, and says if the wait ended before.
unmap_waiter :: proc "c" (parameter: rawptr) -> ! {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	words := [1]op.Word{{address = u64(uintptr(untouched_word)), value = 0}}
	commands := [1]ring.Record{{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&words[0])), 1 = 1}}}
	completions: [1]ring.Record
	now, _ := system.commands_call(commands[:], completions[:], deadline)
	untouched_slot.limit = now < deadline ? 1 : 0
	intrinsics.atomic_store(&unmap_waiter_ended, 1)
	system.word_wake(&unmap_waiter_ended, system.WAKE_ALL)
	system.thread_stop()
}

// unmap_role is the role of a locker in the case of the unmap
// (lockers.ROLE_UNMAP_WAIT).
unmap_role :: proc "contextless" (ctx: ^system.Context) -> ! {
	board, board_status := system.memory_map(ctx.handles[lockers.GRANT_BOARD])
	index := ctx.values[lockers.VALUE_INDEX]
	memory, memory_status := system.memory_create(1)
	page: rawptr
	page_status := memory_status
	if memory_status == .Succeeded {
		page, page_status = system.memory_map(memory, {.Write})
	}
	if board_status != .Succeeded || page_status != .Succeeded || index >= lockers.LOCKER_CAPACITY {
		system.stop(.Failed)
	}
	untouched_slot = &(^lockers.Board)(board).slots[index]
	untouched_word = (^u32)(page)
	intrinsics.atomic_store(untouched_word, 0)
	waiter, started := system.thread_start(unmap_waiter, nil)
	if started != .Succeeded {
		system.stop(.Failed)
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		states, _ := system.call(.Thread_State, u64(waiter.handle))
		if op.Process_State(states[0]) == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	system.memory_unmap(page)
	system.close(memory)
	for intrinsics.atomic_load(&unmap_waiter_ended) == 0 && system.time() < deadline {
		system.word_wait(&unmap_waiter_ended, 0, deadline)
	}
	intrinsics.atomic_add(&untouched_slot.done, 1)
	system.word_wake(&untouched_slot.done, system.WAKE_ALL)
	for {
		system.word_wait(&untouched_slot.command, intrinsics.atomic_load(&untouched_slot.command))
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	role, role_ok := enum_word.member_of_word(lockers.Role, ctx.values[lockers.VALUE_ROLE])
	if !role_ok {
		system.log_fact(.Info, Role_Word_Unknown{role_word = ctx.values[lockers.VALUE_ROLE]})
		system.stop(.Refused)
	}
	switch role {
	case .Measure:
	case .Churn:
		churn(ctx.values[lockers.VALUE_STOP_AFTER], ctx.handles[lockers.GRANT_PEER])
	case .Wait_Room:
		wait_room_role(ctx)
	case .Untouched_Wait:
		untouched_role(ctx)
	case .Unmap_Wait:
		unmap_role(ctx)
	}
	address, status := system.memory_map(ctx.handles[lockers.GRANT_BOARD])
	index := ctx.values[lockers.VALUE_INDEX]
	if status != .Succeeded || index >= lockers.LOCKER_CAPACITY {
		system.log_fact(.Info, Slot_Past_Board{slot = index})
		system.stop(.Failed)
	}
	slot := &(^lockers.Board)(address).slots[index]
	own, _ := system.memory_create(1)
	// The page tables of the range of the measure: the budget pays for
	// them now, and each later page returns to the budget.
	fault_round()
	// Ready: `locks` waits for this before the first command.
	intrinsics.atomic_add(&slot.done, 1)
	system.word_wake(&slot.done, system.WAKE_ALL)
	seen: u32
	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		command := intrinsics.atomic_load(&slot.command)
		if command == seen {
			system.word_wait(&slot.command, command)
			continue
		}
		seen = command
		// The process locks writes the mode: a word that names no mode is
		// refused with a line and a stop, never read as a mode.
		mode, mode_ok := enum_word.member_of_word(lockers.Mode, u64(slot.mode))
		if !mode_ok {
			system.log_fact(.Info, Mode_Word_Unknown{mode_word = u64(slot.mode)})
			system.stop(.Refused)
		}
		start := slot.start
		end := slot.end
		limit := slot.limit
		before, _ := system.budget_read()
		entered := system.kernel_entries()
		for system.time() < start {
			intrinsics.cpu_relax()
		}
		count: u64
		switch mode {
		case .Wait:
			// No work until the next command.
		case .Entries:
			count = entries(own, end, limit)
		case .Faults:
			count = faults(end, limit)
		case .Large:
			for system.time() < end && (limit == 0 || count < limit) {
				if memory, made := system.memory_create(lockers.LARGE_PAGES); made == .Succeeded {
					system.close(memory)
					count += 1
				}
			}
		}
		after, _ := system.budget_read()
		slot.count = count
		slot.entries = system.kernel_entries() - entered
		slot.budget_before = before.pages
		slot.budget_after = after.pages
		intrinsics.atomic_add(&slot.done, 1)
		system.word_wake(&slot.done, system.WAKE_ALL)
	}
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}
