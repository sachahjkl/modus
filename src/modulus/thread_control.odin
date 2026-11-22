package kernel

import "modus:contract/enum_word"
import "base:intrinsics"
import op "modus:contract/operation"

// The control of a thread (docs/ARCHITECTURE.md, "The control of a
// thread"): Thread_Control stops a thread, reads and writes its registers
// and its extended state, and resumes it. A debugger, a garbage collector,
// a sampling profiler and the process that runs a guest use it.
//
// The debugger of a process names a thread of that process by its number,
// with its process handle that has the right Debug, for each command but
// the two of the schedule (docs/ARCHITECTURE.md, "The debugger of a
// process"). The stops that it makes are counted apart (Thread.debug_stops),
// so that the end of the debugging takes them back.
//
// Through a handle, a stop, a resume and a read need the right Inspect, a
// write the right Write (op.thread_control_rights). A write lets its holder
// choose the code that the process runs; a hold and a read do not, so a
// profiler or a collector that only reads gets no write. Control, the right
// to end the thread, gives neither: a handle given only so that another
// process can end a thread does not become a grant to debug it.
//
// The stop is a count, not a state: two holders that each stop the thread
// each resume it, and the thread runs again only after the last Resume. The
// count is orthogonal to the wait of the thread (Ready or Waiting): a wait
// still ends as before, but a thread whose count is above 0 enters no run
// queue. The three places where a thread enters a queue check it under
// the run lock of the home of the thread:
// - thread_ready_held (the end of a wait) leaves the thread out of the
//   queue;
// - schedule leaves the thread out of the queue when its processor leaves
//   it;
// - kernel_interrupt does not continue the thread after an entry.
// The Resume that makes the count 0 puts a thread that is Ready in the
// queue of its home.
//
// The registers of a thread are complete only while no processor runs it:
// the frame from its last kernel entry, the extended state from the save of
// schedule. So they are read and written only while the thread is held:
// its count is above 0, or it waits for an answer of the fault ring. Both
// last at least while the process lock of the thread is held: the count
// goes down and fault_waits ends only under it.
//
// A write is checked whole before anything changes: the frame must be one
// that the return to a process takes (op.thread_registers_refusal), the
// extended state one that xrstor or fxrstor takes
// (op.extended_state_refusal). So no write makes the kernel fault at the
// return or at the restore of the thread.
//
// The schedule of a thread (its weight and its request, op.Thread_Schedule)
// is read and written with no hold: a share changes while the thread runs
// (docs/SCHEDULING.md, "The schedule of a live thread"). A process writes
// the schedule of its own threads; through a thread handle a read needs
// Inspect and a write Control, because a holder that can end a thread can
// also give it a smaller share. These writes only lower the weight and
// the request. The machine handle with the right Schedule
// names any thread of the machine by its machine number, for these two
// commands only. It needs Inspect too, for a read as each report of the
// machine does, and for a write because a write gives the four values of
// the record: its holder must read the schedule to keep the values that
// it does not change.
//
// Only a write through the machine handle raises a weight or a request,
// and a raised weight starts the thread again as a new thread for its
// strategy. Each thread has a weight limit and a new-thread weight limit,
// the full weight at first. Only a write through the machine handle sets
// them, and a new thread gets the new-thread weight limit of the thread
// that creates it as its two limits, with a weight up to it. So a
// weight that the holder of Schedule lowered stays lowered: the process
// of the thread cannot write it back, and cannot leave the limit by a new
// thread.
//
// The placement of a thread (the processors that can run it,
// op.Thread_Placement) is read and written by the same three callers with
// the same rights, and with no hold (docs/SCHEDULING.md, "The placement of
// a thread"). A process, and the holder of a thread handle, only narrow
// the set; the machine handle writes any set and the limit of the set,
// which a new thread gets from the thread that creates it.
//
// The three commands of the thread counters act on the calling thread: a
// start and a read through the machine handle with the right Counters
// only, a stop with no handle (thread_counters.odin).

// thread_control_state_refuse records the specific state refusal of
// Thread_Control on the current processor before returning Bad_State.
thread_control_state_refuse :: #force_inline proc "contextless" (
	refusal: op.Thread_Control_State_Refusal,
	argument: i64,
	value: u64,
	limit: u64 = 0,
	found: u64 = 0,
) -> Operation_Outcome {
	operation := &processor_self().operation
	operation.thread_state_refusal = refusal
	operation.thread_state_refused_argument = argument
	operation.thread_state_refused_value = value
	operation.thread_state_refused_limit = limit
	operation.thread_state_refused_found = found
	return .Bad_State
}

// thread_control runs the operation Thread_Control. The caller holds the
// process lock of the process of the calling thread, and the control lock
// when the operation asked for it.
thread_control :: proc "contextless" (caller_index: u32, v: [7]u64, results: ^[7]u64) -> Operation_Outcome {
	caller_process_index := threads[caller_index].process
	caller_process := &processes[caller_process_index]
	// The record of the operation starts with no refusal (command_run).
	cpu := processor_self()
	operation := &cpu.operation
	command, command_known := enum_word.member_of_word(op.Thread_Control_Command, v[2])
	if !command_known || command == .None {
		return .Bad_Operation
	}
	if op.thread_control_names_a_process(command) {
		return process_schedule_control(caller_process, command, v, results)
	}
	if op.thread_control_counts_the_caller(command) {
		return thread_counters_control(caller_index, caller_process, command, v, results)
	}
	if op.thread_control_records_a_process(command) {
		return record_replay_control(caller_index, caller_process, command, v, results)
	}
	target_index: u32
	owner := caller_process_index
	by_machine := false // The machine handle names the thread: a write sets its weight limit, or the limit of its placement.
	by_debugger := false // The process handle with Debug names the thread: the caller is the debugger of its process.
	target_argument: i64 = 2
	target_value: u64 = v[1]
	can_read_state := true
	if v[0] == 0 {
		// A breakpoint is written only by the debugger of the process of
		// the thread, through its process handle.
		if op.thread_control_needs_the_debugger(command) {
			return .Bad_Handle
		}
		// A thread of this process, by its number: under the process lock,
		// which the caller holds, no thread of this process starts or ends.
		target_index = thread_of_number(caller_process_index, v[1])
		if target_index == 0 {
			return thread_control_state_refuse(.Thread_Absent, 2, v[1], op.THREAD_CAPACITY - 1)
		}
	} else {
		named := handle_find(caller_process, v[0], .None) or_return
		machine_rights, by_machine_number := op.thread_control_machine_rights(command)
		if named.kind == .Machine && by_machine_number {
			// The machine handle names any thread, for the schedule and
			// the placement only:
			// the right Schedule already lets its holder change the order
			// of every thread (Strategy_Set). Each other command with a
			// machine handle goes to the branch below, which refuses a
			// handle that is not a thread handle.
			if !(machine_rights <= named.rights) {
				return .No_Right
			}
			by_machine = true
			place, serial := v[1] & 0xFFFF_FFFF, u32(v[1] >> 32)
			if place == 0 || place >= THREAD_TABLE_CAPACITY {
				return thread_control_state_refuse(.Thread_Absent, 2, v[1])
			}
			// No handle keeps the place for this thread: a place serves a
			// new thread only under the control lock (thread_create), so
			// with it the serial names one thread until the operation ends.
			require_control() or_return
			target_index = u32(place)
			if threads[target_index].serial != serial {
				return thread_control_state_refuse(.Thread_Absent, 2, v[1]) // The thread of that number ended, and the place serves another one.
			}
			owner = threads[target_index].process
		} else if named.kind == .Process && op.thread_control_takes_debug_handle(command) {
			// The debugger of a process names a thread of it by its
			// number. Two process locks: the control lock first.
			if .Debug not_in named.rights {
				return .No_Right
			}
			require_control() or_return
			by_debugger = true
			can_read_state = .Read in named.rights
			owner = named.object
		} else {
			// A thread handle writes no breakpoint: a process, and the
			// holder of a handle of one of its threads, get no way to put
			// a debug exception where the kernel copies its memory.
			if op.thread_control_needs_the_debugger(command) {
				return .Bad_Handle
			}
			// The right of the command: a handle that a process gave so
			// that another one can end a thread (Control) does not let it
			// hold the thread or write its registers.
			slot := handle_find(caller_process, v[0], .Thread, op.thread_control_rights(command)) or_return
			target_index = slot.object
			target_argument = 1
			target_value = v[0]
			can_read_state = .Read in slot.rights
			// A thread of another process: its process lock, which the
			// lock order allows only with the control lock. The process of
			// a thread changes only under the control lock (thread_finish).
			if intrinsics.atomic_load(&threads[target_index].process) != caller_process_index {
				require_control() or_return
				owner = threads[target_index].process
			}
		}
	}
	if owner == 0 {
		return thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0) // The thread ended.
	}
	// The lock of the process of the caller is held already: then this
	// takes nothing (process_lock).
	taken := process_lock(owner)
	defer process_unlock(owner, taken)
	if by_debugger {
		// Check debugger ownership before process state so a non-debugger
		// holding a Debug-only handle without Read cannot tell stopped from
		// live targets via Error_Record.unit.
		if !debugger_is(owner, caller_process_index) {
			return thread_control_state_refuse(.Not_Debugger, 1, v[0], 0, can_read_state ? u64(processes[owner].state) : 0)
		}
	}
	if processes[owner].state == .Stopped || processes[owner].state == .None {
		if by_debugger {
			return thread_control_state_refuse(.Process_Stopped, 1, v[0], 0, can_read_state ? u64(processes[owner].state) : 0)
		}
		return thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
	}
	if by_debugger {
		// Under the process lock of the process, no thread of it starts
		// or ends.
		target_index = thread_of_number(owner, v[1])
		if target_index == 0 {
			return thread_control_state_refuse(.Thread_Absent, 2, v[1], op.THREAD_CAPACITY - 1)
		}
	}
	thread := &threads[target_index]
	if thread.process != owner {
		return thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
	}
	switch command {
	case .None:
		return .Bad_Operation
	case .Stop:
		status := thread_control_stop(target_index, results, target_argument, target_value, can_read_state)
		if status == .Ok && by_debugger {
			thread.debug_stops += 1
		}
		return status
	case .Resume:
		// Each side takes back only its own stops. The debugger: the
		// stops that it made. The process and the holder of a thread
		// handle: the stops that are not of the debugger. So the count of
		// the debugger is never above the stop count, and the end of the
		// debugging takes back the stops of the debugger and no others.
		if by_debugger && thread.debug_stops == 0 {
			return thread_control_state_refuse(.Not_Stopped, target_argument, target_value, 1, can_read_state ? u64(intrinsics.atomic_load(&thread.state)) : 0)
		}
		if !by_debugger && intrinsics.atomic_load(&thread.control_stops) <= thread.debug_stops {
			return thread_control_state_refuse(.Not_Stopped, target_argument, target_value, 1, can_read_state ? u64(intrinsics.atomic_load(&thread.state)) : 0)
		}
		status := thread_control_resume(thread, results, target_argument, target_value, can_read_state)
		if status == .Ok && by_debugger {
			thread.debug_stops -= 1
		}
		return status
	case .Read_Registers, .Write_Registers, .Read_Extended_State, .Write_Extended_State:
		size := command == .Read_Registers || command == .Write_Registers ? u64(size_of(op.Thread_Registers)) : extended_state_size
		writes_to_the_caller := command == .Read_Registers || command == .Read_Extended_State
		if v[4] < size || !user_range(caller_process, v[3], size, writes_to_the_caller) {
			return .Bad_Address
		}
		if target_index == caller_index || !thread_held_off_processor(thread) {
			thread_state := intrinsics.atomic_load(&thread.state)
			if target_index != caller_index && (thread_state == .None || thread_state == .Stopped || intrinsics.atomic_load(&thread.stop_requested)) {
				return thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
			}
			return thread_control_state_refuse(.Not_Held, target_argument, target_value, 1, can_read_state ? u64(thread_state) : 0)
		}
		// The case above holds the four members of a copy of the state.
		switch {
		case command == .Read_Registers:
			registers := thread_registers_of_frame(thread)
			user_copy(rawptr(uintptr(v[3])), &registers, size)
		case command == .Write_Registers:
			registers: op.Thread_Registers
			user_copy(&registers, rawptr(uintptr(v[3])), size)
			if refusal, value := op.thread_registers_refusal(&registers); refusal != .None {
				operation.thread_write_refusal, operation.thread_write_refused_value = refusal, value
				return .Bad_Operation
			}
			thread_frame_write(thread, &registers)
			thread.registers_written = true
			// A trap flag that the debugger wrote is its single step: if
			// the debugging ends before the step, the step is dropped
			// (debug_exception_is_dropped).
			thread.debugger_step = by_debugger && registers.rflags & FLAG_TRAP != 0
		case command == .Read_Extended_State:
			user_copy(rawptr(uintptr(v[3])), &thread.extended_state, size)
			results[1] = transmute(u64)extended_state_components
		case command == .Write_Extended_State:
			written := &cpu.extended_state_written
			// The bytes past the size of a save keep the values of the thread:
			// the area is copied whole below.
			written^ = thread.extended_state
			user_copy(written, rawptr(uintptr(v[3])), size)
			if refusal, value := extended_state_write_refusal(written); refusal != .None {
				operation.thread_write_refusal, operation.thread_write_refused_value = refusal, value
				return .Bad_Operation
			}
			thread.extended_state = written^
			thread.registers_written = true
		}
		results[0] = size
		return .Ok
	case .Read_Breakpoints, .Write_Breakpoints:
		// The breakpoints of a thread (breakpoints.odin). As the registers:
		// only while the thread is held, so that no processor loads them
		// while they change.
		size := u64(size_of(op.Thread_Breakpoints))
		if v[4] < size || !user_range(caller_process, v[3], size, command == .Read_Breakpoints) {
			return .Bad_Address
		}
		if target_index == caller_index || !thread_held_off_processor(thread) {
			thread_state := intrinsics.atomic_load(&thread.state)
			if target_index != caller_index && (thread_state == .None || thread_state == .Stopped || intrinsics.atomic_load(&thread.stop_requested)) {
				return thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
			}
			return thread_control_state_refuse(.Not_Held, target_argument, target_value, 1, can_read_state ? u64(thread_state) : 0)
		}
		// One copy in the memory of the kernel: the values that the check
		// accepts are the values that the thread gets.
		breakpoints: op.Thread_Breakpoints
		if command == .Read_Breakpoints {
			if intrinsics.atomic_load(&thread.has_breakpoints) {
				breakpoints = thread.breakpoints
			}
			user_copy(rawptr(uintptr(v[3])), &breakpoints, size)
		} else {
			user_copy(&breakpoints, rawptr(uintptr(v[3])), size)
			if refusal, value := op.thread_breakpoints_refusal(&breakpoints); refusal != .None {
				operation.thread_write_refusal, operation.thread_write_refused_value = refusal, value
				return .Bad_Operation
			}
			thread_breakpoints_write(thread, &breakpoints)
		}
		results[0] = size
		return .Ok
	case .Read_Process_Schedule, .Write_Process_Schedule:
		// They name a process, not a thread: process_schedule_control runs
		// them before a thread is named.
		return .Bad_Operation
	case .Start_Counters, .Read_Counters, .Stop_Counters:
		// They act on the calling thread: thread_counters_control runs them
		// before a thread is named.
		return .Bad_Operation
	case .Record_Start, .Record_End, .Replay_Start:
		// They act on a process handle: record_replay_control runs them
		// before a thread is named.
		return .Bad_Operation
	case .Read_Memory:
		// The bytes of the process of the thread (breakpoints.odin). The
		// thread is not held: the memory of a process changes while its
		// other threads run in any case. The process lock of that process
		// is held here, and the one of the caller.
		if v[4] > op.THREAD_MEMORY_READ_LIMIT {
			return .Bad_Operation
		}
		if !user_range(caller_process, v[3], v[4], true) {
			return .Bad_Address
		}
		copied := process_memory_read(&processes[owner], v[5], v[3], v[4])
		if copied == 0 && v[4] != 0 {
			return .Bad_Address
		}
		results[0] = copied
		return .Ok
	case .Read_Schedule, .Write_Schedule:
		size := u64(size_of(op.Thread_Schedule))
		if v[4] < size || !user_range(caller_process, v[3], size, command == .Read_Schedule) {
			return .Bad_Address
		}
		// One copy in the memory of the kernel: the values that the check
		// accepts are the values that the thread gets.
		schedule: op.Thread_Schedule
		if command == .Read_Schedule {
			read_status: Operation_Outcome
			schedule, read_status = thread_schedule_read(thread, target_argument, target_value, can_read_state)
			if read_status != .Ok {
				return read_status
			}
			user_copy(rawptr(uintptr(v[3])), &schedule, size)
		} else {
			user_copy(&schedule, rawptr(uintptr(v[3])), size)
			// The check of Thread_Create; the error record names the value
			// that it refused and the most that it takes. The weight limit
			// of the record is read only from the holder of the machine.
			refusal: op.Thread_Write_Refusal
			refused, most: u64
			switch {
			case schedule.weight > op.WEIGHT_FULL:
				refusal, refused, most = .Weight, u64(schedule.weight), op.WEIGHT_FULL
			case schedule.request > op.REQUEST_LIMIT:
				refusal, refused, most = .Request, u64(schedule.request), op.REQUEST_LIMIT
			case by_machine && schedule.weight_limit > op.WEIGHT_FULL:
				refusal, refused, most = .Weight_Limit, u64(schedule.weight_limit), op.WEIGHT_FULL
			case by_machine && schedule.new_thread_weight_limit > op.WEIGHT_FULL:
				refusal, refused, most = .New_Thread_Weight_Limit, u64(schedule.new_thread_weight_limit), op.WEIGHT_FULL
			case:
				write_status, write_refusal, write_most := thread_schedule_write(thread, schedule, by_machine, target_argument, target_value, can_read_state)
				if write_status != .Ok && write_status != .Bad_Operation {
					return write_status
				}
				// A weight or a request above the one that the thread has.
				refusal, refused, most = write_refusal, u64(write_refusal == .Request ? schedule.request : schedule.weight), u64(write_most)
			}
			if refusal != .None {
				operation.thread_write_refusal, operation.thread_write_refused_value, operation.thread_write_refused_limit = refusal, refused, most
				return .Bad_Operation
			}
		}
		results[0] = size
		return .Ok
	case .Read_Placement, .Write_Placement:
		size := u64(size_of(op.Thread_Placement))
		if v[4] < size || !user_range(caller_process, v[3], size, command == .Read_Placement) {
			return .Bad_Address
		}
		// One copy in the memory of the kernel: the sets that the check
		// accepts are the sets that the thread gets.
		placement: op.Thread_Placement
		if command == .Read_Placement {
			read_status: Operation_Outcome
			placement, read_status = thread_placement_read(thread, target_argument, target_value, can_read_state)
			if read_status != .Ok {
				return read_status
			}
			user_copy(rawptr(uintptr(v[3])), &placement, size)
		} else {
			user_copy(&placement, rawptr(uintptr(v[3])), size)
			write_status, refusal, most := thread_placement_write(thread, placement, by_machine, target_index == caller_index, target_argument, target_value, can_read_state)
			if write_status == .Bad_Operation {
				// The refused set, and the set that it had to stay inside.
				refused := refusal == .Processors_Limit ? placement.processors_limit : placement.processors
				operation.thread_write_refusal, operation.thread_write_refused_value, operation.thread_write_refused_limit = refusal, refused, most
			}
			if write_status != .Ok {
				return write_status
			}
		}
		results[0] = size
		return .Ok
	}
	return .Bad_Operation
}

// process_schedule_control runs the two commands of the schedule of a
// process (op.Process_Schedule). Only the machine handle with Schedule and
// Inspect names a process: its holder already orders every thread, and a
// read of any process is a report of the machine. `number` is the slot of
// the process and its serial (op.process_slot_and_serial). The write holds
// the control lock and the process lock of the process: a creation by a
// thread of that process holds the control lock too, so it comes wholly
// before the write or wholly after it (creation_weight_limit).
process_schedule_control :: proc "contextless" (caller_process: ^Process, command: op.Thread_Control_Command, v: [7]u64, results: ^[7]u64) -> Operation_Outcome {
	if v[0] == 0 {
		return .Bad_Handle
	}
	named := handle_find(caller_process, v[0], .None) or_return
	if named.kind != .Machine {
		return .Bad_Handle
	}
	machine_rights, _ := op.thread_control_machine_rights(command)
	if !(machine_rights <= named.rights) {
		return .No_Right
	}
	size := u64(size_of(op.Process_Schedule))
	if v[4] < size || !user_range(caller_process, v[3], size, command == .Read_Process_Schedule) {
		return .Bad_Address
	}
	slot, serial := v[1] & 0xFFFF_FFFF, u32(v[1] >> 32)
	if slot == 0 || slot >= PROCESS_CAPACITY {
		return thread_control_state_refuse(.Process_Absent, 2, v[1])
	}
	// A slot serves a new process only under the control lock
	// (process_create): with it the serial names one process until the
	// operation ends.
	require_control() or_return
	index := u32(slot)
	taken := process_lock(index)
	defer process_unlock(index, taken)
	process := &processes[index]
	if process.serial != serial || process.state == .None {
		return thread_control_state_refuse(.Process_Absent, 2, v[1])
	}
	if process.state == .Stopped {
		return thread_control_state_refuse(.Process_Stopped, 2, v[1], 0, u64(op.Process_State.Stopped))
	}
	// One copy in the memory of the kernel: the value that the check
	// accepts is the value that the process gets.
	schedule: op.Process_Schedule
	if command == .Read_Process_Schedule {
		schedule.new_thread_weight_limit = process_new_thread_weight_limit(process)
		user_copy(rawptr(uintptr(v[3])), &schedule, size)
	} else {
		user_copy(&schedule, rawptr(uintptr(v[3])), size)
		after, refusal := op.process_schedule_after_write(schedule)
		if refusal != .None {
			operation := &processor_self().operation
			operation.thread_write_refusal, operation.thread_write_refused_value, operation.thread_write_refused_limit = refusal, u64(schedule.new_thread_weight_limit), op.WEIGHT_FULL
			return .Bad_Operation
		}
		intrinsics.atomic_store(&process.new_thread_weight_limit, after.new_thread_weight_limit)
	}
	results[0] = size
	return .Ok
}

// thread_machine_number gives the machine number of a thread: its place in
// the thread table in the low 32 bits, and the serial of the thread in that
// place in the high 32 bits. The serial changes for each new thread of a
// place, so the number of a thread that ended names no later thread.
thread_machine_number :: #force_inline proc "contextless" (index: u32, serial: u32) -> u64 {
	return u64(index) | u64(serial) << 32
}

// thread_schedule_ends says if a thread has no schedule to read or to
// write: it ended, or another processor ends it. The caller holds the run
// lock of its home.
thread_schedule_ends :: #force_inline proc "contextless" (thread: ^Thread) -> bool {
	return thread.state == .None || thread.state == .Stopped || intrinsics.atomic_load(&thread.stop_requested)
}

// thread_schedule_read gives the weight, the request and the two weight
// limits of a thread, all of one moment: they change together under the
// run lock of its home. The caller holds the process lock of the thread.
thread_schedule_read :: proc "contextless" (thread: ^Thread, target_argument: i64, target_value: u64, can_read_state: bool) -> (schedule: op.Thread_Schedule, status: Operation_Outcome) {
	home := run_lock(thread)
	defer run_unlock(home)
	if thread_schedule_ends(thread) {
		return {}, thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
	}
	return op.Thread_Schedule{weight = thread.weight, request = thread.request, weight_limit = thread.weight_limit, new_thread_weight_limit = thread.new_thread_weight_limit}, .Ok
}

// thread_schedule_write gives a thread a weight and a request, in any state
// of the thread: in the queue of its home, on a processor, in a wait, or
// held by a stop. The caller checked each value against the most of the
// contract. The caller holds the process lock of the thread, so the thread
// does not end its life in the table and its place serves no new thread.
//
// by_machine false: the process of the thread, or the holder of a thread
// handle, writes. Such a write only lowers: a weight above the weight that
// the thread has now, or a request above its request, is refused
// (Bad_Operation, with the part and the value that the thread has), and
// nothing changes. 0 keeps the value that the thread has. The weight limit
// of the record is not read. A process chooses the moment of its writes;
// with one direction only, no sequence of them gets back what a write
// gave up.
//
// by_machine true: the holder of the machine writes the four values
// (op.thread_schedule_after_machine_write). 0 is the default of each: the
// full weight for the limit, the limit for the weight and for the
// new-thread weight limit, the default request. A weight or a new-thread
// weight limit above the new limit becomes the limit. Only this write
// raises a weight, and a raised thread gets the zero values of its
// strategy fields (strategy_weight_raised).
//
// All of it is one section of the run lock of the home of the thread
// (run_lock reads the home again after the take): a pick, a move, a wake,
// a tick, the end of a stint, a stop and the conversion of the queue to
// another strategy each take that lock, so each one sees the old schedule
// whole or the new one whole (docs/ARCHITECTURE.md, "Locks of the kernel").
// No weight is ever above its limit: both are written in this section.
//
// The sum of the weights of the list stays exact: the old weight of a
// thread of the list leaves it and the new one enters it. The list keeps
// its order, and the thread keeps its state, its home and its processor.
thread_schedule_write :: proc "contextless" (thread: ^Thread, schedule: op.Thread_Schedule, by_machine: bool, target_argument: i64, target_value: u64, can_read_state: bool) -> (status: Operation_Outcome, refusal: op.Thread_Write_Refusal, most: u32) {
	home := run_lock(thread)
	defer run_unlock(home)
	if thread_schedule_ends(thread) {
		return thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0), .None, 0
	}
	old_weight := thread.weight
	weight_limit := thread.weight_limit
	new_thread_weight_limit := thread.new_thread_weight_limit
	weight, request: u32
	if by_machine {
		after := op.thread_schedule_after_machine_write(schedule)
		weight, request, weight_limit, new_thread_weight_limit = after.weight, after.request, after.weight_limit, after.new_thread_weight_limit
	} else {
		weight = schedule.weight == 0 ? old_weight : schedule.weight
		request = schedule.request == 0 ? thread.request : schedule.request
		if weight > old_weight {
			return .Bad_Operation, .Weight, old_weight
		}
		if request > thread.request {
			return .Bad_Operation, .Request, thread.request
		}
	}
	queue := &run_queues[home]
	if thread.queued {
		queue.weight = queue.weight - old_weight + weight
	}
	// A report, and the diagnosis of a refused Thread_Create, read these
	// words with no lock, each one whole.
	intrinsics.atomic_store(&thread.weight, weight)
	intrinsics.atomic_store(&thread.request, request)
	intrinsics.atomic_store(&thread.weight_limit, weight_limit)
	intrinsics.atomic_store(&thread.new_thread_weight_limit, new_thread_weight_limit)
	if weight > old_weight {
		strategy_weight_raised(queue, home, thread)
	}
	return .Ok, .None, 0
}

// thread_placement_read gives the set of processors of a thread and the
// limit of that set, both of one moment: they change together under the
// run lock of its home. The caller holds the process lock of the thread.
thread_placement_read :: proc "contextless" (thread: ^Thread, target_argument: i64, target_value: u64, can_read_state: bool) -> (placement: op.Thread_Placement, status: Operation_Outcome) {
	home := run_lock(thread)
	defer run_unlock(home)
	if thread_schedule_ends(thread) {
		return {}, thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
	}
	return op.Thread_Placement{processors = thread.processors, processors_limit = thread.processors_limit}, .Ok
}

// thread_placement_write gives a thread a set of processors, in any state
// of the thread: in the queue of its home, on a processor, in a wait, or
// held by a stop (docs/SCHEDULING.md, "The placement of a thread"). The
// caller holds the process lock of the thread, so the thread does not end
// its life in the table, its place serves no new thread, and no other
// write of its placement runs: the placement that this procedure reads
// before it takes a run lock is the one that it finds under the lock.
//
// by_machine false: the process of the thread, or the holder of a thread
// handle, writes. Such a write only narrows (op.thread_placement_after_write):
// a process chooses the moment of its writes, and with one direction one
// thread commands fewer moves than the machine has processors. by_machine
// true: the holder of the machine writes any set and the limit.
//
// The home of a thread is in its set, or the thread is on the processor of
// its home. So when the new set does not have the home:
// - a thread in the list of its home moves to the list of a processor of
//   the set, in this section, under the run locks of the two processors,
//   taken in the order of the processors. It leaves the old list as a
//   thread that a Stop takes out of it, and enters the new one as a woken
//   thread: its strategy keeps what it owes, also when its budget has no
//   time in this period and the average of its queue does not count it
//   (strategy_leaves_list). The move of the balance takes the average
//   with the thread, which is right only for a thread whose budget has
//   time: the balance takes no other. During a change of strategy the
//   fields of the thread are cleared. Nothing that the thread owes is
//   forgiven;
// - a thread that waits, or that a stop holds, is in no list: it gets the
//   new home, and the wake or the Resume puts it in that queue. What it
//   keeps for its strategy is a value relative to its queue, which has
//   its meaning in each queue of the same strategy;
// - a thread on a processor keeps its home: only its processor takes it
//   out of there. It moves when it leaves that processor (schedule), at
//   the end of its stint at the latest.
//
// The write ends the stint of no other thread, and sends no interrupt to a
// processor that runs a thread: the thread that runs there when an
// interrupt arrives can be a thread of another process, which would pay
// for it. It wakes only an idle processor, for a thread that it left in a
// list (below). When the calling
// thread wrote its own set and its processor is not in it, its own stint
// ends at the end of this kernel entry (is_caller).
//
// A write that gives a processor to a thread that stays in the list of its
// home makes the processors look at that list (kick): an idle processor
// that the set has now takes the thread. Without it that processor stays
// idle until another wake, because the end of a stint wakes no processor.
// Only the holder of the machine widens a set, so no process commands
// these wakes.
//
// A pick by another processor can change the home between the read of the
// home and the take of the locks: then the locks are freed and the choice
// starts again.
thread_placement_write :: proc "contextless" (thread: ^Thread, written: op.Thread_Placement, by_machine: bool, is_caller: bool, target_argument: i64, target_value: u64, can_read_state: bool) -> (status: Operation_Outcome, refusal: op.Thread_Write_Refusal, most: u64) {
	if intrinsics.atomic_load(&thread.record_mode) != .None {
		return thread_control_state_refuse(.Thread_Recording, target_argument, target_value, 0, can_read_state ? u64(intrinsics.atomic_load(&thread.state)) : 0), .None, 0
	}
	every_processor := machine_processors()
	held := op.Thread_Placement {
		processors       = intrinsics.atomic_load(&thread.processors),
		processors_limit = intrinsics.atomic_load(&thread.processors_limit),
	}
	after: op.Thread_Placement
	after, refusal, most = op.thread_placement_after_write(written, held, every_processor, by_machine)
	entered, widened_in_list := false, false
	target: u32
	for {
		entered, widened_in_list = false, false
		home := intrinsics.atomic_load(&thread.home)
		target = refusal == .None ? placement_home(after.processors, home) : home
		first, second := min(home, target), max(home, target)
		lock_take(&run_queues[first].lock, .Run)
		if second != first {
			lock_take(&run_queues[second].lock, .Run)
		}
		status = .Ok
		home_changed := false
		switch {
		case intrinsics.atomic_load(&thread.home) != home:
			home_changed = true // Another processor took the thread from its list.
		case thread_schedule_ends(thread):
			status = thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
		case refusal != .None:
			status = .Bad_Operation
		case:
			intrinsics.atomic_store(&thread.processors, after.processors)
			intrinsics.atomic_store(&thread.processors_limit, after.processors_limit)
			intrinsics.atomic_store(&thread.placement_restricted, after.processors != every_processor)
			if target != home && thread.processor == 0 {
				from, to := &run_queues[home], &run_queues[target]
				same_strategy := from.strategy == to.strategy
				if thread.queued {
					if same_strategy {
						strategy_leaves_list(from, home, thread)
					} else {
						strategy_clear(thread)
					}
					queue_remove(thread)
					intrinsics.atomic_store(&thread.home, target)
					queue_ready(thread, .Woken)
					entered = true
				} else {
					if !same_strategy {
						strategy_clear(thread)
					}
					intrinsics.atomic_store(&thread.home, target)
				}
			} else if thread.queued && after.processors &~ held.processors != 0 {
				widened_in_list = true
			}
		}
		if second != first {
			lock_free(&run_queues[second].lock, .Run)
		}
		lock_free(&run_queues[first].lock, .Run)
		if !home_changed {
			break
		}
	}
	if status != .Ok {
		return status, refusal, most
	}
	if entered || widened_in_list {
		// The thread is in the list of another processor, or its set got
		// a processor while it stays in its list: the processor of that
		// list, or an idle one of its set, looks at it. For a thread
		// that stays, the target is its home.
		kick(target, thread)
	}
	if cpu := processor_self(); is_caller && after.processors & (u64(1) << cpu.index) == 0 {
		cpu.slice_left = 0
	}
	return .Ok, .None, 0
}

// thread_of_number gives the live thread of a process with a number, or 0.
// The caller holds the process lock.
thread_of_number :: proc "contextless" (process_index: u32, number: u64) -> u32 {
	if number >= op.THREAD_CAPACITY {
		return 0
	}
	for &thread, slot in threads[1:] {
		if thread.process == process_index && u64(thread.number) == number && thread.state != .None && thread.state != .Stopped && !thread.finished {
			return u32(slot + 1)
		}
	}
	return 0
}

// thread_control_stop adds 1 to the stop count of a thread. A thread in the
// queue of its home leaves it; a thread on another processor gets an
// interrupt, and the operation returns after it left that processor
// (stop_wait), so that the registers are complete when the caller reads
// them. The calling thread stops at the end of its kernel entry.
thread_control_stop :: proc "contextless" (index: u32, results: ^[7]u64, target_argument: i64, target_value: u64, can_read_state: bool) -> Operation_Outcome {
	thread := &threads[index]
	home := run_lock(thread)
	if thread.state == .None || thread.state == .Stopped || intrinsics.atomic_load(&thread.stop_requested) {
		run_unlock(home)
		return thread_control_state_refuse(.Thread_Ended, target_argument, target_value, 0, can_read_state ? u64(op.Process_State.Stopped) : 0)
	}
	if thread.control_stops >= op.THREAD_STOP_COUNT_LIMIT {
		stops := u64(thread.control_stops)
		run_unlock(home)
		return thread_control_state_refuse(.Stop_Count_Limit, target_argument, stops + 1, op.THREAD_STOP_COUNT_LIMIT)
	}
	intrinsics.atomic_store(&thread.control_stops, thread.control_stops + 1)
	count := thread.control_stops
	if thread.queued {
		// It leaves the list as a thread that starts to wait: its strategy
		// keeps its position, and the Resume places it as a woken thread.
		// Zero values here would forgive what the thread owes: a Stop and a
		// Resume by another thread of its process would put it before
		// threads that waited longer.
		strategy_leaves_list(&run_queues[home], home, thread)
		queue_remove(thread)
	}
	running := thread.processor
	serial := thread.serial
	run_unlock(home)
	self := processor_self()
	if running != 0 && processors[running - 1] != self {
		// The interrupt makes the thread enter the kernel, whose end does
		// not continue it.
		apic_send(processors[running - 1].apic_id, VECTOR_WAKE)
		self.operation.stopped_thread, self.operation.stopped_thread_serial = index, serial
	}
	results[0] = u64(count)
	return .Ok
}

// thread_control_resume takes 1 from the stop count of a thread. At 0, a
// thread that is Ready and on no processor enters the queue of its home, as
// at the end of a wait.
thread_control_resume :: proc "contextless" (thread: ^Thread, results: ^[7]u64, target_argument: i64, target_value: u64, can_read_state: bool) -> Operation_Outcome {
	home := run_lock(thread)
	if thread.control_stops == 0 {
		thread_state := thread.state
		run_unlock(home)
		return thread_control_state_refuse(.Not_Stopped, target_argument, target_value, 1, can_read_state ? u64(thread_state) : 0)
	}
	intrinsics.atomic_store(&thread.control_stops, thread.control_stops - 1)
	count := thread.control_stops
	queued := false
	if count == 0 && thread.state == .Ready && thread.processor == 0 && !thread.queued && !intrinsics.atomic_load(&thread.stop_requested) {
		queue_ready(thread, .Woken)
		queued = true
	}
	run_unlock(home)
	if queued {
		kick(home, thread)
	}
	results[0] = u64(count)
	return .Ok
}

// thread_held_off_processor says if a thread is held, and waits until no
// processor runs it when it waits for an answer of the fault ring. The
// caller holds the process lock of the thread: the hold lasts while it is
// held.
//
// A thread that waits for an answer can still be on its way out of its
// processor: its record is published before it leaves. That way takes no
// process lock and no control lock (fault_deliver returned; then
// kernel_interrupt and schedule up to the store of `processor`), so the
// wait here ends. A thread held only by its stop count and still on a
// processor can be inside an operation that waits for the process lock
// that the caller holds: no wait for it; Stop already waited for it, so a
// thread still there is one that another Stop holds now, and the caller
// gets Bad_State.
thread_held_off_processor :: proc "contextless" (thread: ^Thread) -> bool {
	if thread.state == .None || thread.state == .Stopped || intrinsics.atomic_load(&thread.stop_requested) {
		return false
	}
	if thread.fault_waits {
		cpu := processor_self()
		self := &threads[cpu.current]
		for intrinsics.atomic_load(&thread.processor) != 0 {
			if intrinsics.atomic_load(&self.stop_requested) {
				return false
			}
			sync_acknowledge(cpu)
			intrinsics.cpu_relax()
		}
		return true
	}
	return intrinsics.atomic_load(&thread.control_stops) != 0 && intrinsics.atomic_load(&thread.processor) == 0
}

// thread_registers_of_frame gives the registers of a held thread from its
// frame.
thread_registers_of_frame :: proc "contextless" (thread: ^Thread) -> op.Thread_Registers {
	frame := &thread.frame
	return {
		rax = frame.rax, rbx = frame.rbx, rcx = frame.rcx, rdx = frame.rdx,
		rsi = frame.rsi, rdi = frame.rdi, rbp = frame.rbp, rsp = frame.rsp,
		r8 = frame.r8, r9 = frame.r9, r10 = frame.r10, r11 = frame.r11,
		r12 = frame.r12, r13 = frame.r13, r14 = frame.r14, r15 = frame.r15,
		rip = frame.rip, rflags = frame.rflags, cs = frame.cs, ss = frame.ss,
		in_kernel_entry = thread.in_enter ? 1 : 0,
	}
}

// thread_frame_write writes checked registers into the frame of a held
// thread. The vector and the error code stay: they are the ones of the last
// entry, and no return reads them.
thread_frame_write :: proc "contextless" (thread: ^Thread, registers: ^op.Thread_Registers) {
	frame := &thread.frame
	frame.rax, frame.rbx, frame.rcx, frame.rdx = registers.rax, registers.rbx, registers.rcx, registers.rdx
	frame.rsi, frame.rdi, frame.rbp, frame.rsp = registers.rsi, registers.rdi, registers.rbp, registers.rsp
	frame.r8, frame.r9, frame.r10, frame.r11 = registers.r8, registers.r9, registers.r10, registers.r11
	frame.r12, frame.r13, frame.r14, frame.r15 = registers.r12, registers.r13, registers.r14, registers.r15
	frame.rip, frame.rflags, frame.cs, frame.ss = registers.rip, registers.rflags, registers.cs, registers.ss
}

#assert(op.THREAD_CODE_SELECTOR == SELECTOR_USER_CODE)
#assert(op.THREAD_STACK_SELECTOR == SELECTOR_USER_DATA)
#assert(op.THREAD_FLAGS_ALLOWED == RETURN_FLAGS_OF_A_PROCESS | USER_FLAGS)
#assert(op.THREAD_FLAGS_REQUIRED == USER_FLAGS)
