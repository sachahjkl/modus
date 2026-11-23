package locks

import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:system"

// A wake needs Write on its word. One memory object, mapped with Write and
// a second time read-only: a thread waits on the word through the mapping
// with Write; a wake of the same word through the read-only mapping is
// refused with Bad_Address and its record (the word, found 1: the process
// can read it), and the thread still waits; a wake through the mapping
// with Write then wakes it. Each condition is a status, a record, a count
// or a state that the kernel reports: no time but the hang bound.
read_only_waiter_word: ^u32
read_only_waiter_ended: u32

read_only_waiter :: proc "c" (parameter: rawptr) -> ! {
	system.word_wait(read_only_waiter_word, 0, system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	intrinsics.atomic_store(&read_only_waiter_ended, 1)
	system.thread_stop()
}

read_only_wake_case :: proc "contextless" () {
	refused_status := system.Status.Ok
	record: errors.Error_Record
	still_waits, woken: u64
	right := false
	defer system.log_fact(.Info, Read_Only_Wake_Refused{status = op.Status_Word(refused_status), still_waits = still_waits, woken = woken, verdict = verdict_field(right)})
	memory, memory_status := system.memory_create(1)
	if memory_status != .Ok {
		return
	}
	defer system.close(memory)
	writable, writable_status := system.memory_map(memory, {.Write})
	readable, readable_status := system.memory_map(memory, {})
	if writable_status != .Ok || readable_status != .Ok {
		return
	}
	defer system.memory_unmap(writable)
	defer system.memory_unmap(readable)
	read_only_waiter_word = (^u32)(writable)
	waiter, started := system.thread_start(read_only_waiter, nil)
	if started != .Ok {
		return
	}
	defer system.thread_wait(waiter)
	// The wake must find the thread in its wait.
	waiting :: proc "contextless" (thread: system.Thread) -> bool {
		states, _ := system.call(.Thread_State, u64(thread.handle))
		return op.Process_State(states[0]) == .Waiting
	}
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; !waiting(waiter) && system.time() < deadline; {
		system.sleep(system.time() + 1)
	}
	_, refused_status = system.call_with_error(&record, .Word_Wake, u64(uintptr(readable)), system.WAKE_ALL)
	still_waits = u64(waiting(waiter) && intrinsics.atomic_load(&read_only_waiter_ended) == 0)
	record_right := record.kind == i64(errors.Kind.Bad_Address) && record.value == i64(uintptr(readable)) && record.found == 1
	woken = system.word_wake(read_only_waiter_word, system.WAKE_ALL)
	right = refused_status == .Bad_Address && record_right && still_waits == 1 && woken == 1
}
