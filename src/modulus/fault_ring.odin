package kernel

import "base:intrinsics"
import "modus:contract/enum_word"
import op "modus:contract/operation"

// The fault ring (docs/ARCHITECTURE.md, "The fault ring"). A process names
// one of its threads as its fault handler (Fault_Handler_Set), with the
// fault kinds that it takes. A fault of such a kind of another thread of the
// process, which would stop the process, becomes a record in the thread
// record of the handler; the faulting thread waits; a thread of the process
// repairs (Memory_Commit, Memory_Protect) and answers (Fault_Answer): Resume
// lets the thread continue at the instruction of its record, Stop stops the
// process with the report of the fault, as with no handler.
//
// The states of a faulting thread, each change under the locks named:
// - running -> waiting for an answer (fault_deliver): under the process
//   lock and the run lock of its home, the thread becomes Waiting with no
//   deadline and fault_waits true, before its record is published. It is
//   still on its processor, so kernel_interrupt then calls schedule, which
//   saves its extended state as for any thread that leaves a processor.
// - waiting -> ready (Fault_Answer Resume): under the process lock,
//   fault_waits becomes false, then thread_wake makes it Ready under the run
//   lock, as the end of a word wait does. run checks its frame at the
//   return (return_frame_prepare), as each return. A stop of
//   Thread_Control keeps a Ready thread out of the queue until its Resume.
// While it waits, Thread_Control reads and writes its registers and its
// extended state (thread_control.odin); a write makes Resume valid for a
// fault that would otherwise run the same instruction again.
// - waiting -> stopped (Fault_Answer Stop, a stop of the process, the end of
//   the handler): process_stop ends each thread of the process, a waiting
//   one as any thread that is on no processor.
// A waiting thread holds nothing but its thread: no record of the kernel,
// no lock, no page.
//
// A thread that waits for an answer is in no table of words, and only
// Fault_Answer, the end of the ring (its handler ends, or Fault_Handler_Set
// while it waits) or the stop of its process ends its wait. A thread whose
// record went to the debugger of its process waits in the same state, with
// fault_to_debugger true: the answer of the debugger or the end of the
// debugging ends its wait, and the ring of its process does not count it.
//
// The record names the faulting thread by its number and by the serial of
// the fault: a count of the process (Process.fault_serial), not the serial
// of the kernel's thread slot, which all processes share and which would
// tell a process how many threads others made in that slot.

// The debugger of a process (docs/ARCHITECTURE.md, "The debugger of a
// process"). A process with a handle of another process with the right
// Debug names one of its own threads as the debug handler of that process
// (Fault_Handler_Set with the handle). Then the faults of the kinds Debug
// and Breakpoint of that process go to the ring of that thread first, and
// only the debugger answers them (Fault_Answer with the handle).
//
// The ring is the fault ring of the thread record of the debug handler:
// the debugger pays for it. A thread is the debug handler of one process,
// and not the fault handler of its own, so one ring has one writer: the
// faults of the debugged process, each under the process lock of that
// process. The kernel's count of that ring is Process.debug_written of the
// debugged process.
//
// The record is memory of another process than the one that faults. The
// debugged process keeps the address of the record (Process.debug_record)
// under its own process lock. The end of the debug handler clears it under
// that lock, before the thread record is unmapped: thread_finish calls
// debug_handler_end first. So a fault never writes a record that is gone,
// and a fault takes one process lock only.
//
// What the debugger did to the process ends with the debugging
// (debug_handler_end): the breakpoints of each thread, the trap flag that
// it wrote, the stops that it made, and the wait of each thread for its
// answer. A debugger that ends never holds and never stops the process.

// What fault_deliver did with a fault.
Fault_Delivery :: enum u8 {
	Stops_The_Process,   // No ring takes the fault: the process stops, as with no handler.
	Waits_For_An_Answer, // The record is written, and the thread waits.
	Continues,           // A debug exception that no debugger waits for any more: the thread goes on.
}

// fault_deliver gives a fault of the current thread of this processor to
// the ring of the debugger of its process, or to the fault ring of its
// process. The frame of the thread is the frame of the fault; address is
// the address of a page fault, and 0 for another kind. The caller holds no
// lock.
fault_deliver :: proc "contextless" (thread_index: u32, address: u64) -> Fault_Delivery {
	thread := &threads[thread_index]
	vector := thread.frame.vector
	process_index := thread.process
	process := &processes[process_index]
	// A vector that names no kind of fault has no record: no handler and no
	// debugger can ask for it, and the record holds a kind, never a vector.
	fault_kind, fault_kind_known := enum_word.member_of_word(op.Fault_Kind, vector)
	if !fault_kind_known {
		return .Stops_The_Process
	}
	kind_bit := u64(1) << vector
	// The kinds of the handler and of the debugger, read with no lock: a
	// fault of a kind that neither asked for, and every fault of a process
	// with no handler, takes no lock here. The check under the lock below
	// decides. A debug exception always takes the lock: the status of a
	// breakpoint that was removed is judged there.
	if vector != VECTOR_DEBUG && (intrinsics.atomic_load(&process.fault_kinds) | intrinsics.atomic_load(&process.debug_kinds)) & kind_bit == 0 {
		return .Stops_The_Process
	}
	// The thread areas, the time page and the kernel half are not served: a
	// handler cannot repair them, and the records of the ring are in a
	// thread area.
	if vector == VECTOR_PAGE_FAULT && address >= op.THREAD_AREA_BASE {
		return .Stops_The_Process
	}
	taken := process_lock(process_index)
	defer process_unlock(process_index, taken)
	if process.state == .Stopped {
		return .Stops_The_Process
	}
	if vector == VECTOR_DEBUG && debug_exception_is_dropped(process, thread) {
		return .Continues
	}
	// The ring of the debugger first, for its kinds.
	record: ^op.Thread_Record
	to_debugger := false
	if process.debug_record != nil && process.debug_kinds & kind_bit != 0 {
		record = process.debug_record
		// fault_read is memory of the debugger: any value. The rule of the
		// ring of a process, below, holds here too: the kernel indexes with
		// its own count.
		if process.debug_written - intrinsics.atomic_load(&record.fault_read) >= op.FAULT_RECORD_CAPACITY {
			process.debug_full += 1
			intrinsics.volatile_store(&record.fault_full, process.debug_full)
			// One line of the log for each time that the ring becomes
			// full, with the count: a thread that steps through a full
			// ring comes here at each instruction, and a line for each one
			// would fill the log. The next record that finds room allows
			// the next line.
			if !process.debug_full_logged {
				process.debug_full_logged = true
				log_with_level(.Warning, "kernel: process ", Module_Name{process_name(process)}, ": the ring of its debugger is full (", u64(process.debug_full), " times): the debugger does not see the fault")
			}
			// A breakpoint, or a single step that the debugger asked for,
			// that finds no place is lost for the debugger, and is no
			// fault of the process: the thread goes on. The step is over:
			// its trap flag leaves the thread, so that the thread does not
			// come here again at each instruction. A breakpoint belongs to
			// the debugger: only the debugger writes one.
			status := thread.frame.error
			debugger_stepped := status & op.DEBUG_STATUS_STEP != 0 && thread.debugger_step
			if vector == VECTOR_DEBUG && (status & op.DEBUG_STATUS_BREAKPOINTS != 0 || debugger_stepped) {
				if debugger_stepped {
					thread.debugger_step = false
					thread.frame.rflags &~= FLAG_TRAP
				}
				breakpoint_resume_flag_set(thread)
				return .Continues
			}
			// Each other one (int3, int1, a single step that the process
			// asked for itself) stays with the process, as with no
			// debugger: its own fault handler below, or its stop.
		} else {
			to_debugger = true
			process.debug_full_logged = false
		}
	}
	if !to_debugger {
		handler_index := process.fault_handler
		// A fault of the handler itself is not delivered: no fault of a fault.
		if handler_index == 0 || handler_index == thread_index || process.fault_kinds & kind_bit == 0 {
			return .Stops_The_Process
		}
		handler := &threads[handler_index]
		// The handler of the process is a live thread of the process: thread_finish
		// clears fault_handler under this lock before it unmaps the record.
		record = handler.record_in_kernel
		if handler.process != process_index || handler.serial != process.fault_handler_serial || record == nil {
			return .Stops_The_Process
		}
		// fault_read is memory of the process: any value. The kernel indexes
		// with its own count, so it never writes outside fault_records. A
		// difference that is not below the capacity is full. A false fault_read
		// harms only its process: a value above the count makes the ring full,
		// and a value a little below the count lets the kernel write over
		// records that the process did not read yet.
		read := intrinsics.atomic_load(&record.fault_read)
		if process.fault_written - read >= op.FAULT_RECORD_CAPACITY {
			process.fault_full += 1
			intrinsics.volatile_store(&record.fault_full, process.fault_full)
			log_with_level(.Warning, "kernel: process ", Module_Name{process_name(process)}, ": the fault ring is full (", u64(process.fault_full), " times): the fault stops the process")
			return .Stops_The_Process
		}
	}
	// The entries of an earlier word wait stay in the table of words until
	// the next kernel entry of the thread (wait_begin), and a fault is not
	// one: a word_wake, a decommit or a revocation would end this wait
	// through them, with no answer. The thread leaves the table here. Its
	// processor owns it (it is the current thread), and the wait locks come
	// after the process lock.
	wait_unregister(thread)
	thread.woken = false
	process.fault_serial += 1
	// The thread waits before its record is published: an answer reads the
	// record first, so it finds the thread waiting.
	home := run_lock(thread)
	thread.state = .Waiting
	intrinsics.atomic_store(&thread.deadline, op.WAIT_FOREVER)
	thread.fault_waits = true
	thread.fault_to_debugger = to_debugger
	thread.fault_serial = process.fault_serial
	thread.fault_address = address
	thread.fault_instruction = thread.frame.rip
	thread.fault_frame_pointer = thread.frame.rbp
	// A write of Thread_Control before this fault does not make Resume
	// valid for it: the handler writes after it reads this record.
	thread.registers_written = false
	run_unlock(home)
	// The mark of a trap flag that the debugger wrote stays through its
	// record: the flag is still in the frame of the thread, and only the
	// next write of the registers, or the end of the debugging, takes it
	// out (debug_handler_end).
	access: u64
	if vector == VECTOR_PAGE_FAULT {
		access = thread.frame.error & 0b10011 // Present, Write, Execute: the bits of Fault_Access.
	}
	written := to_debugger ? &process.debug_written : &process.fault_written
	record.fault_records[written^ % op.FAULT_RECORD_CAPACITY] = {
		thread      = u64(thread.number),
		serial      = process.fault_serial,
		address     = address,
		access      = access,
		instruction = thread.frame.rip,
		kind        = u64(fault_kind),
		error_code  = thread.frame.error,
	}
	written^ += 1
	// The record is written before the count that publishes it.
	intrinsics.atomic_store(&record.fault_written, written^)
	word_wake(physical_of(&record.fault_written), max(u64))
	return .Waits_For_An_Answer
}

// fault_handler_set makes a thread of the process its fault handler for the
// fault kinds of a mask of vectors, with an empty ring, or ends the delivery
// (handler_index 0). The ring of the old handler ends either way: a thread
// that waits then has a record that no thread will read, so the process
// stops as at the end of the handler thread. The caller holds the process
// lock (execute).
fault_handler_set :: proc "contextless" (process_index: u32, handler_index: u32, kinds: u64) -> Operation_Outcome {
	process := &processes[process_index]
	handler := &threads[handler_index]
	// Only a live thread of this process: thread.process is 0 after
	// thread_finish, which runs under this lock.
	if handler_index != 0 && (handler.process != process_index || handler.record_in_kernel == nil) {
		return .Wrong_State
	}
	// One ring has one role: the ring of a debug handler takes the records
	// of the process that it debugs, with the count of that process.
	if handler_index != 0 && intrinsics.atomic_load(&handler.debugs_process) != 0 {
		return .Wrong_State
	}
	if fault_waiter_exists(process_index) {
		// A stop of the process takes the control lock.
		require_control() or_return
		process_stop(process_index, .Fault_Unanswered, .None)
		return .Succeeded
	}
	process.fault_handler = handler_index
	if handler_index == 0 {
		intrinsics.atomic_store(&process.fault_kinds, 0)
		return .Succeeded
	}
	process.fault_handler_serial = handler.serial
	process.fault_written = 0
	intrinsics.atomic_store(&handler.record_in_kernel.fault_written, 0)
	intrinsics.atomic_store(&handler.record_in_kernel.fault_read, 0)
	intrinsics.atomic_store(&process.fault_kinds, kinds)
	return .Succeeded
}

// fault_waiter_find gives the thread of a process with a number and a
// fault serial that waits for an answer, or 0. The caller holds the process lock,
// under which fault_waits and thread.process change.
fault_waiter_find :: proc "contextless" (process_index: u32, number: u64, serial: u64) -> u32 {
	for &thread, slot in threads[1:] {
		if thread.process == process_index && thread.fault_waits && u64(thread.number) == number && thread.fault_serial == serial {
			return u32(slot + 1)
		}
	}
	return 0
}

// fault_waiter_exists says if a thread of a process waits for an answer
// in the fault ring of the process. A thread that waits for the debugger
// of the process has its record in the ring of the debugger: the end of
// the ring of the process does not lose it. The caller holds the process
// lock.
fault_waiter_exists :: proc "contextless" (process_index: u32) -> bool {
	for &thread in threads[1:] {
		if thread.process == process_index && thread.fault_waits && !thread.fault_to_debugger {
			return true
		}
	}
	return false
}

// debug_handler_set makes a thread of the calling process the debug
// handler of another process, for the fault kinds of a mask of vectors,
// with an empty ring. The caller holds the control lock and the process
// lock of the calling process, and checked the right Debug on the handle
// of the debugged process.
debug_handler_set :: proc "contextless" (caller_index: u32, handler_index: u32, debugged_index: u32, kinds: u64) -> Operation_Outcome {
	// A process does not debug itself: its debug handler would wait for
	// its own answer.
	if debugged_index == caller_index {
		return .Wrong_State
	}
	handler := &threads[handler_index]
	// Only a live thread of the calling process, which is not its fault
	// handler: one ring has one role.
	if handler.process != caller_index || handler.record_in_kernel == nil || processes[caller_index].fault_handler == handler_index {
		return .Wrong_State
	}
	if serves := intrinsics.atomic_load(&handler.debugs_process); serves != 0 && serves != debugged_index {
		return .Wrong_State
	}
	// Two processes do not debug each other: each one could hold the debug
	// handler of the other, and both would wait for ever.
	if debugger_is(caller_index, debugged_index) {
		return .Wrong_State
	}
	taken := process_lock(debugged_index)
	defer process_unlock(debugged_index, taken)
	process := &processes[debugged_index]
	if process.state != .Created && process.state != .Ready {
		return .Wrong_State
	}
	if process.debug_handler != 0 {
		// One debugger at a time. The process of a thread changes only
		// under the control lock, which the caller holds.
		if threads[process.debug_handler].process != caller_index {
			return .Wrong_State
		}
		// A new debug handler of the same debugger: the ring of the old
		// one ends as at a detach, and its threads go on.
		debug_handler_end(debugged_index)
	}
	record := handler.record_in_kernel
	process.debug_handler = handler_index
	process.debug_record = record
	process.debug_written = 0
	// The counts of a full ring are those of this debugger.
	process.debug_full = 0
	process.debug_full_logged = false
	intrinsics.volatile_store(&record.fault_full, 0)
	intrinsics.atomic_store(&record.fault_written, 0)
	intrinsics.atomic_store(&record.fault_read, 0)
	intrinsics.atomic_store(&handler.debugs_process, debugged_index)
	intrinsics.atomic_store(&process.debug_kinds, kinds)
	return .Succeeded
}

// debug_handler_detach ends the debugging of a process by its debugger,
// the calling process. The caller holds the control lock.
debug_handler_detach :: proc "contextless" (caller_index: u32, debugged_index: u32) -> Operation_Outcome {
	taken := process_lock(debugged_index)
	defer process_unlock(debugged_index, taken)
	if !debugger_is(debugged_index, caller_index) {
		return .Wrong_State
	}
	debug_handler_end(debugged_index)
	return .Succeeded
}

// debugger_is says if a process is the debugger of another one: a thread
// of it is the debug handler. The caller holds the control lock, under
// which the process of a thread changes, and the process lock of the
// debugged process.
debugger_is :: proc "contextless" (debugged_index: u32, debugger_index: u32) -> bool {
	handler := processes[debugged_index].debug_handler
	return handler != 0 && debugger_index != debugged_index && threads[handler].process == debugger_index
}

// debug_handler_end ends the debugging of a process, if it has a
// debugger: the detach, the end of the debug handler thread, the end of
// the right Debug of the debugger, the stop of the process. No fault of
// the process goes to the old ring after it. In a process that runs, each
// thread gets back what the debugger took: its breakpoints end, the trap
// flag that the debugger wrote is cleared, the stops that the debugger
// made are taken back, and a thread that waits for the answer of the
// debugger goes on. The caller holds the control lock; this takes the
// process lock of the debugged process.
//
// A thread that a processor runs keeps its debug registers until it
// leaves that processor, and a trap flag that the debugger wrote is still
// in its flags. Its next debug exception finds no breakpoint and no
// debugger under the process lock, and is dropped
// (debug_exception_is_dropped).
debug_handler_end :: proc "contextless" (debugged_index: u32) {
	process := &processes[debugged_index]
	taken := process_lock(debugged_index)
	defer process_unlock(debugged_index, taken)
	handler_index := process.debug_handler
	if handler_index == 0 {
		return
	}
	process.debug_handler = 0
	process.debug_record = nil
	intrinsics.atomic_store(&process.debug_kinds, 0)
	intrinsics.atomic_store(&threads[handler_index].debugs_process, 0)
	if process.state != .Created && process.state != .Ready {
		return // The process stops: each of its threads ends.
	}
	for &thread in threads[1:] {
		if thread.process != debugged_index {
			continue
		}
		intrinsics.atomic_store(&thread.has_breakpoints, false)
		waits := thread.fault_waits && thread.fault_to_debugger
		stops := thread.debug_stops
		if !waits && stops == 0 {
			continue
		}
		// A thread that waits for the answer can still be on its way out
		// of its processor: that way takes no lock that is held here
		// (thread_held_off_processor).
		if waits {
			_ = thread_held_off_processor(&thread)
		}
		// The frame of a thread that no processor runs: the process lock
		// keeps the thread held.
		if intrinsics.atomic_load(&thread.processor) == 0 && thread.debugger_step {
			thread.frame.rflags &~= FLAG_TRAP
			thread.debugger_step = false
		}
		// Only the stops of the debugger: a stop of the process itself, or
		// of a holder of a thread handle, stays (thread_control.odin keeps
		// debug_stops at most control_stops).
		if stops != 0 {
			thread.debug_stops = 0
			thread_stops_release(&thread, stops)
		}
		if waits {
			thread.fault_waits = false
			thread.fault_to_debugger = false
			thread_wake(&thread)
		}
	}
}

// debug_right_closed ends the debugging of a process when a handle of its
// debugger to it with the right Debug closes or is revoked, and no other
// handle of the debugger has that right on it. handle_close calls it
// before it clears the slot: the slot still holds the handle, and the loop
// skips it. The caller holds the process lock of the process that closes
// the handle and the control lock (a close of a process handle asks for
// it; a revocation and the cleanup of a process hold it).
debug_right_closed :: proc "contextless" (holder: ^Process, closed: ^Handle_Slot) {
	debugged_index := closed.object
	for &slot in holder.handles {
		if &slot != closed && slot.kind == .Process && slot.object == debugged_index && .Debug in slot.rights {
			return
		}
	}
	taken := process_lock(debugged_index)
	defer process_unlock(debugged_index, taken)
	if debugger_is(debugged_index, index_of_process(holder)) {
		debug_handler_end(debugged_index)
	}
}

// debug_fault_answer lets a thread of a debugged process go on after a
// fault whose record went to its debugger, the calling process. The
// caller holds the control lock.
debug_fault_answer :: proc "contextless" (caller_index: u32, debugged_index: u32, number: u64, serial: u64) -> Operation_Outcome {
	taken := process_lock(debugged_index)
	defer process_unlock(debugged_index, taken)
	if !debugger_is(debugged_index, caller_index) {
		return .Wrong_State
	}
	waiter_index := fault_waiter_find(debugged_index, number, serial)
	if waiter_index == 0 || !threads[waiter_index].fault_to_debugger {
		return .Wrong_State
	}
	waiter := &threads[waiter_index]
	// The frame is written below: the thread left its processor first.
	if !thread_held_off_processor(waiter) {
		return .Wrong_State
	}
	breakpoint_resume_flag_set(waiter)
	waiter.fault_waits = false
	waiter.fault_to_debugger = false
	thread_wake(waiter)
	return .Succeeded
}
