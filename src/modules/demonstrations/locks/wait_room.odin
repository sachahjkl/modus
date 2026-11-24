package locks

import "modus:contract/call_outcome"
import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/ring"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:lockers"
import "modus:random"
import "modus:system"

// The wait room of the kernel at its edges (op.Thread_Control_Command.
// Wait_Room): a wait of one word past the words that a thread has with no
// room is refused, and names that count as its limit; a word named twice
// in one wait is refused with its place; a room past the most words, or for
// another thread, is refused; a room of one word past them holds a whole
// page of words more, and its pages leave the budget; a wait of each word
// of the room passes, one word more is refused with the room as its limit;
// the room given back returns its pages to the budget. Then the pages of a
// room return to the budget at each end: of its thread, of its process
// stopped during a wait, and of its process after its budget ended. Each
// condition is a status, a record or a count of pages: no time but the
// hang bound of a cleanup.
ROOM_WORDS_ASKED :: op.WORD_WAIT_INLINE + 1
ROOM_WORDS_HELD :: op.WORD_WAIT_INLINE + op.WAIT_ROOM_WORDS_OF_A_PAGE

// Each word holds 1, and each wait names 0: a wait that the kernel takes
// ends at once. One word for each place of a list, so no word is named
// twice.
room_targets: [ROOM_WORDS_HELD + 1]u32

room_wait :: proc "contextless" (words: []op.Word, record: ^errors.Error_Record) -> call_outcome.Call_Outcome {
	_, status := system.call_with_error(record, .Word_Wait, u64(uintptr(raw_data(words))), u64(len(words)))
	return status
}

room_ask :: proc "contextless" (thread: u64, words: u64, record: ^errors.Error_Record) -> (held: u64, status: call_outcome.Call_Outcome) {
	results: [7]u64
	results, status = system.call_with_error(record, .Thread_Control, thread, 0, u64(op.Thread_Control_Command.Wait_Room), 0, words)
	return results[0], status
}

// pages_back_wait waits until the budget of this process holds pages again,
// or the hang bound: the cleanup of a process runs after its last thread
// left its processor.
pages_back_wait :: proc "contextless" (pages: u64) -> bool {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		if now, _ := system.budget_read(); now.pages == pages {
			return true
		}
		system.sleep(system.time() + 10)
	}
	return false
}

// The result of the thread of the room end case.
Room_Thread_Result :: struct {
	status: call_outcome.Call_Outcome,
}

// room_thread_run asks for a room and ends with it.
room_thread_run :: proc "c" (parameter: rawptr) -> ! {
	result := (^Room_Thread_Result)(parameter)
	_, result.status = room_ask(0, ROOM_WORDS_ASKED, nil)
	system.thread_stop()
}

// room_locker_case starts a locker that takes a room and waits with no
// end, stops it, and waits until the budget of this process holds its
// pages again. budget_end: the locker ends its budget first, so the pages
// of the room return to the budget that pays the process then.
room_locker_case :: proc "contextless" (image: []u8, budget_end: bool) -> (room_status: call_outcome.Call_Outcome, back: bool) {
	board_memory, memory_status := system.memory_create(1)
	if memory_status != .Succeeded {
		return memory_status, false
	}
	defer system.close(board_memory)
	address, map_status := system.memory_map(board_memory)
	if map_status != .Succeeded {
		return map_status, false
	}
	defer system.memory_unmap(address)
	slot := &(^lockers.Board)(address).slots[0]
	_ = intrinsics.atomic_load(&slot.done)
	// Read the budget after board_memory is created, mapped, and faulted so
	// before.pages matches the budget once the child process stops (while
	// board_memory is still held by defer).
	before, _ := system.budget_read()
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[lockers.GRANT_BOARD] = {board_memory, {.Read, .Write}}
	values[lockers.VALUE_ROLE] = u64(lockers.Role.Wait_Room)
	values[lockers.VALUE_ROOM_WORDS] = 2 * lockers.ROOM_WAITED
	values[lockers.VALUE_BUDGET_END] = budget_end ? 1 : 0
	process, start_status := system.process_start(system.image_find(image, "locker"), "room", grants, random.values_with_seed(&process_generator, values), LOCKER_AMOUNTS)
	if start_status != .Succeeded {
		return start_status, false
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for intrinsics.atomic_load(&slot.done) == 0 && system.time() < deadline {
		system.word_wait(&slot.done, 0, deadline)
	}
	status, status_ok := enum_word.member_of_word(call_outcome.Call_Outcome, slot.count)
	room_status = status_ok ? status : .Argument_Refused
	system.process_stop(process)
	system.close(process)
	return room_status, pages_back_wait(before.pages)
}

// room_long_wait measures one wait of op.WORD_WAIT_MOST words, which the
// kernel registers in chunks: the time of its entry is a measure, and the
// status a condition.
room_long_wait :: proc "contextless" () -> (status: call_outcome.Call_Outcome, microseconds: u64) {
	list_pages := u64(op.WORD_WAIT_MOST * size_of(op.Word) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	target_pages := u64(op.WORD_WAIT_MOST * size_of(u32) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory, memory_status := system.memory_create(list_pages + target_pages)
	if memory_status != .Succeeded {
		return memory_status, 0
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Succeeded {
		return map_status, 0
	}
	defer system.memory_unmap(address)
	words := ([^]op.Word)(address)[:op.WORD_WAIT_MOST]
	targets := ([^]u32)(uintptr(address) + uintptr(list_pages * system.PAGE_SIZE))[:op.WORD_WAIT_MOST]
	for &word, index in words {
		targets[index] = 1
		word = {address = u64(uintptr(&targets[index])), value = 0}
	}
	if _, room_status := room_ask(0, op.WORD_WAIT_MOST, nil); room_status != .Succeeded {
		return room_status, 0
	}
	defer room_ask(0, 0, nil)
	start := system.nanoseconds()
	status = room_wait(words, nil)
	return status, (system.nanoseconds() - start) / 1000
}

// The frame of the measure of a full bucket: each of its 1024 words is
// waited on by one thread, so the bucket of the frame holds 1024 distinct
// words; the word 0 is the first registered, the last of the bucket.
full_frame_memory: rawptr

full_frame_waiter :: proc "c" (parameter: rawptr) -> ! {
	words: [WORDS_OF_A_FRAME]op.Word
	frame := ([^]u32)(full_frame_memory)
	for &word, index in words {
		word = {address = u64(uintptr(&frame[index])), value = 0}
	}
	if _, status := room_ask(0, WORDS_OF_A_FRAME, nil); status != .Succeeded {
		system.thread_stop()
	}
	commands := [1]ring.Record{{kind = u32(op.Operation.Word_Wait), values = {0 = u64(uintptr(&words[0])), 1 = len(words)}}}
	completions: [1]ring.Record
	system.commands_call(commands[:], completions[:], system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	system.thread_stop()
}

WORDS_OF_A_FRAME :: system.PAGE_SIZE / 4

// full_frame_wake measures one wake of the last word of a bucket that holds
// the 1024 distinct words of one frame: the most that a wake reads before
// it finds its word. The time is a measure; the count woken a condition.
full_frame_wake :: proc "contextless" () -> (woken: u64, microseconds: u64) {
	memory, memory_status := system.memory_create(1)
	if memory_status != .Succeeded {
		return 0, 0
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Succeeded {
		return 0, 0
	}
	defer system.memory_unmap(address)
	full_frame_memory = address
	waiter, started := system.thread_start(full_frame_waiter, nil)
	if started != .Succeeded {
		return 0, 0
	}
	defer system.thread_wait(waiter)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		states, _ := system.call(.Thread_State, u64(waiter.handle))
		if op.Process_State(states[0]) == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	start := system.nanoseconds()
	woken = system.word_wake((^u32)(address), system.WAKE_ALL)
	return woken, (system.nanoseconds() - start) / 1000
}

// The pages of the mapping of the measure of an unmap.
UNMAP_MEASURE_PAGES :: 4096

unmap_measure_word: ^u32

unmap_measure_waiter :: proc "c" (parameter: rawptr) -> ! {
	system.word_wait(unmap_measure_word, 0, system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	system.thread_stop()
}

// unmap_measure gives the time of one unmap of a mapping of
// UNMAP_MEASURE_PAGES pages that each have a frame, with a thread that
// waits on its last word or with none: the unmap reads the words of the
// process only when one is waited. A measure, with no condition.
unmap_measure :: proc "contextless" (with_waiter: bool) -> (microseconds: u64) {
	memory, memory_status := system.memory_create(UNMAP_MEASURE_PAGES)
	if memory_status != .Succeeded {
		return 0
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Succeeded {
		return 0
	}
	pages := ([^][system.PAGE_SIZE]u8)(address)[:UNMAP_MEASURE_PAGES]
	for &page in pages {
		intrinsics.volatile_store(&page[0], 0)
	}
	waiter: system.Thread
	if with_waiter {
		unmap_measure_word = (^u32)(&pages[UNMAP_MEASURE_PAGES - 1][system.PAGE_SIZE - 4])
		started: call_outcome.Call_Outcome
		if waiter, started = system.thread_start(unmap_measure_waiter, nil); started != .Succeeded {
			system.memory_unmap(address)
			return 0
		}
		for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
			states, _ := system.call(.Thread_State, u64(waiter.handle))
			if op.Process_State(states[0]) == .Waiting {
				break
			}
			system.sleep(system.time() + 1)
		}
	}
	start := system.nanoseconds()
	system.memory_unmap(address)
	microseconds = (system.nanoseconds() - start) / 1000
	if with_waiter {
		system.thread_wait(waiter)
	}
	return microseconds
}

wait_room_case :: proc "contextless" (image: []u8) {
	words: [ROOM_WORDS_HELD + 1]op.Word
	for &word, index in words {
		room_targets[index] = 1
		word = {address = u64(uintptr(&room_targets[index])), value = 0}
	}

	no_room: errors.Error_Record
	no_room_status := room_wait(words[:op.WORD_WAIT_INLINE + 1], &no_room)
	right := no_room_status == .Budget_Or_Capacity_Exhausted && no_room.kind == i64(errors.Kind.Over_Limit) && no_room.unit == i64(errors.Unit.Words) && no_room.limit == op.WORD_WAIT_INLINE
	right &&= room_wait(words[:op.WORD_WAIT_INLINE], nil) == .Succeeded

	// The same word twice: refused, with the place of the second.
	twice := [2]op.Word{words[0], words[0]}
	twice_record: errors.Error_Record
	twice_status := room_wait(twice[:], &twice_record)
	right &&= twice_status == .Argument_Refused && twice_record.kind == i64(errors.Kind.Bad_Value) && twice_record.value == 1

	too_many: errors.Error_Record
	_, too_many_status := room_ask(0, op.WORD_WAIT_MOST + 1, &too_many)
	right &&= too_many_status == .Argument_Refused && too_many.kind == i64(errors.Kind.Too_Long) && too_many.limit == op.WORD_WAIT_MOST
	_, other_status := room_ask(1, ROOM_WORDS_ASKED, nil)
	right &&= other_status == .Argument_Refused

	before, _ := system.budget_read()
	held, room_status := room_ask(0, ROOM_WORDS_ASKED, nil)
	with_room, _ := system.budget_read()
	pages := before.pages - with_room.pages
	right &&= room_status == .Succeeded && held == ROOM_WORDS_HELD && pages == op.wait_room_pages(ROOM_WORDS_ASKED)

	held_status := room_wait(words[:ROOM_WORDS_HELD], nil)
	past: errors.Error_Record
	past_status := room_wait(words[:ROOM_WORDS_HELD + 1], &past)
	right &&= held_status == .Succeeded && past_status == .Budget_Or_Capacity_Exhausted && past.limit == ROOM_WORDS_HELD

	back, back_status := room_ask(0, 0, nil)
	after, _ := system.budget_read()
	returned := back_status == .Succeeded && back == op.WORD_WAIT_INLINE && after.pages == before.pages
	right &&= returned

	// The ends of a room: its thread, its process stopped in a wait, and
	// its process after its budget ended.
	thread_room_result := Room_Thread_Result{status = .Wrong_State}
	thread_before, _ := system.budget_read()
	thread_end := false
	if thread, started := system.thread_start(room_thread_run, &thread_room_result); started == .Succeeded {
		system.thread_wait(thread)
		thread_end = pages_back_wait(thread_before.pages)
	}
	stopped_status, stopped_back := room_locker_case(image, false)
	ended_status, ended_back := room_locker_case(image, true)
	ends_right := thread_room_result.status == .Succeeded && thread_end && stopped_status == .Succeeded && stopped_back && ended_status == .Succeeded && ended_back

	system.log_fact(.Info, Wait_Room_Checked{
		inline_words = op.WORD_WAIT_INLINE,
		no_room_status = call_outcome.Call_Outcome_Word(no_room_status),
		twice_status = call_outcome.Call_Outcome_Word(twice_status),
		most_words = op.WORD_WAIT_MOST,
		too_many_status = call_outcome.Call_Outcome_Word(too_many_status),
		other_status = call_outcome.Call_Outcome_Word(other_status),
		asked = ROOM_WORDS_ASKED,
		held = held,
		pages = pages,
		held_status = call_outcome.Call_Outcome_Word(held_status),
		past_status = call_outcome.Call_Outcome_Word(past_status),
		returned = u64(returned),
		verdict = verdict_field(right),
	})
	system.log_fact(.Info, Wait_Room_Ends{
		thread_end = u64(thread_end),
		stopped_back = u64(stopped_back),
		ended_back = u64(ended_back),
		verdict = verdict_field(ends_right),
	})
	long_status, long_time := room_long_wait()
	system.log_fact(.Info, Wait_Room_Long{words = op.WORD_WAIT_MOST, status = call_outcome.Call_Outcome_Word(long_status), time = value_kinds.Time_In_Microseconds(long_time)})
	system.log_fact(.Info, Unmap_Time{pages = UNMAP_MEASURE_PAGES, alone = value_kinds.Time_In_Microseconds(unmap_measure(false)), waited = value_kinds.Time_In_Microseconds(unmap_measure(true))})
	full_woken, full_time := full_frame_wake()
	system.log_fact(.Info, Full_Frame_Wake{words = WORDS_OF_A_FRAME, woken = full_woken, time = value_kinds.Time_In_Microseconds(full_time)})
}
