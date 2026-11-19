package kernel

import "modus:contract/enum_word"
import "modus:contract/ring"
import "base:intrinsics"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// The kernel entry (docs/ARCHITECTURE.md, "Rings and wait"). It executes the
// command records of the kernel ring
// of the process, then makes the process wait if it asked for that.


enter :: proc "contextless" (cpu: ^Processor, index: u32) {
	thread := &threads[index]
	intrinsics.atomic_add(&processes[thread.process].entries, 1)
	thread.in_enter = true
	wait_begin(thread)
	for _ in 0 ..< ring.CAPACITY {
		if ring.empty(&thread.ring.commands) {
			break
		}
		// A command runs only when its answer has room: else it would do
		// its work and its completion would be lost. It stays in the
		// command queue, unrun, with each command after it, and the thread
		// reads its completions before it enters again. No wait follows:
		// the thread would sleep with its answers unread
		// (src/md/api/kernel_ring_completion_room.md).
		if ring.full(&thread.ring.completions) {
			thread.word_changed = true
			break
		}
		command, ok := ring.pop(&thread.ring.commands)
		if !ok {
			break
		}
		completion := ring.Record{tag = command.tag}
		// The event point of an operation (events.odin): with no rule of
		// this kind, one branch on a word of this processor; with a rule for
		// another process only, one more load and branch. No read of the
		// cycle counter in either case.
		started: u64
		if event_wanted(cpu, OBSERVED_OPERATION, .Operation, thread.process) {
			started = cycles_now()
		}
		status := command_run(index, command, &completion.values)
		if started != 0 {
			// The operation can have stopped this thread or its process: its
			// slot keeps its process and its number until its processor
			// leaves it (schedule), so the record names it.
			event_record(cpu, .Operation, thread.process, thread.number, u64(command.kind &~ op.COMMAND_NAMES_ERROR_DETAILS), cycles_now() - started, u64(status))
		}
		// The operation can end the thread: then it does nothing more.
		if intrinsics.atomic_load(&thread.stop_requested) {
			return
		}
		completion.kind = u32(status)
		if status != .Ok {
			// The error record: the values of a failed operation, and the
			// table of error details that the command names (diagnose.odin).
			completion.values = transmute([7]u64)diagnose_command(thread.process, command, status)
		}
		// The room was checked before the run, and only the reader changes
		// the read counter: the push fails only after a thread of the
		// process wrote a false count into this ring, and the loss is then
		// the process's alone.
		_ = ring.push(&thread.ring.completions, completion)
	}
	// A word that changed before the wait: the thread reads it again.
	wait_end(thread, thread.frame.rdi)
}

// The result of a kernel operation inside the kernel: each status of the
// contract, with its value, and Needs_Control, which no process sees. An
// operation that touches another process, or ends an object that other
// processes name, needs the control lock (docs/ARCHITECTURE.md, "Locks of
// the kernel"): it gives Needs_Control before it changes anything, and
// command_run runs it again with the lock. One value says it, so no path
// can ask for the lock and still run on.
Operation_Outcome :: enum u32 {
	Ok            = u32(op.Status.Ok),
	Bad_Operation = u32(op.Status.Bad_Operation),
	Bad_Handle    = u32(op.Status.Bad_Handle),
	Bad_Address   = u32(op.Status.Bad_Address),
	No_Memory     = u32(op.Status.No_Memory),
	No_Slot       = u32(op.Status.No_Slot),
	Bad_State     = u32(op.Status.Bad_State),
	No_Right      = u32(op.Status.No_Right),
	No_Budget     = u32(op.Status.No_Budget),
	Needs_Control = u32(max(op.Status)) + 1,
}
// A status added to the contract does not build until it has its member here.
#assert(len(Operation_Outcome) == len(op.Status) + 1)

// status_of_outcome gives the status of the completion record of a
// command. Needs_Control from the run with the control lock is a fault of
// the kernel: the operation asked for a lock that it held.
status_of_outcome :: proc "contextless" (outcome: Operation_Outcome) -> op.Status {
	switch outcome {
	case .Ok:
		return .Ok
	case .Bad_Operation:
		return .Bad_Operation
	case .Bad_Handle:
		return .Bad_Handle
	case .Bad_Address:
		return .Bad_Address
	case .No_Memory:
		return .No_Memory
	case .No_Slot:
		return .No_Slot
	case .Bad_State:
		return .Bad_State
	case .No_Right:
		return .No_Right
	case .No_Budget:
		return .No_Budget
	case .Needs_Control:
	}
	fault_report_begin()
	log("kernel: an operation asked for the control lock while it held it: the machine stops")
	machine_stop(.Invariant_Broken)
}

// The facts of the kernel operation that runs on a processor, in one
// record: command_run sets it to its start before each run of an
// operation, so no fact of an earlier operation stays for a reader. The
// error record of a refusal reads the facts after the run, before the next
// command.
Operation_In_Progress :: struct {
	running: bool, // A kernel operation of the current thread runs (command_run).
	control: bool, // The operation holds the control lock.
	// The stops that the operation made (stop_wait).
	stopped_thread, stopped_thread_serial: u32, // A thread that ran on another processor. 0: none.
	stopped_processes: u64, // Bit n: process n had a thread on a processor; its serial is in Processor.stopped_serials.
	// The part and the value that a write of Thread_Control refused: the
	// error record takes them from here, not from a second read of the
	// memory of the caller, which the caller can change between the two
	// reads.
	thread_write_refusal:       op.Thread_Write_Refusal,
	thread_write_refused_value: u64,
	thread_write_refused_limit: u64, // The most that the refused value can be. 0: the part has no range.
	// The limit of a new thread that Thread_Create checked the weight
	// against: the error record takes it from here, not from a second
	// read, which a write of the holder of the machine can change between
	// the operation and the record.
	thread_create_weight_limit: u32,
}

// command_run executes one command under the process lock of the caller,
// and runs it again with the control lock when it gives Needs_Control.
command_run :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> op.Status {
	cpu := processor_self()
	cpu.operation = {running = true}
	// A guest runs with no lock held: the operation takes its own locks
	// (guest.odin).
	if command.kind == u32(op.Operation.Guest_Run) {
		guest_outcome := guest_run(index, command.values, results)
		cpu.operation.running = false
		stop_wait(cpu)
		return status_of_outcome(guest_outcome)
	}
	outcome := execute_locked(index, command, results)
	if outcome == .Needs_Control {
		// The first run changed no state that the second run does twice:
		// Memory_Physical can have given the frames of the object and made
		// context entries, and the second run finds them made.
		results^ = {}
		control_take()
		cpu.operation = {running = true, control = true}
		outcome = execute_locked(index, command, results)
		cpu.operation.control = false
		control_free()
	}
	cpu.operation.running = false
	stop_wait(cpu)
	return status_of_outcome(outcome)
}

// stop_wait waits, with no lock held, until each thread that this
// operation stopped on another processor left it: after Thread_Stop or
// Process_Stop, no thread of what stopped runs an instruction: a thread
// that another thread stops ends at any instruction, and the caller then
// owns the data that this thread was changing.
// The wait ends at once if the current thread is stopped too: two threads
// that stop each other do not wait for each other. The same for a stop of
// Thread_Control, which also waits here: two threads that hold each other
// would wait for each other with interrupts off.
stop_wait :: proc "contextless" (cpu: ^Processor) {
	self := &threads[cpu.current]
	operation := &cpu.operation
	if operation.stopped_thread != 0 {
		thread := &threads[operation.stopped_thread]
		for intrinsics.atomic_load(&thread.serial) == operation.stopped_thread_serial && intrinsics.atomic_load(&thread.processor) != 0 && !intrinsics.atomic_load(&self.stop_requested) && intrinsics.atomic_load(&self.control_stops) == 0 {
			sync_acknowledge(cpu)
			intrinsics.cpu_relax()
		}
		operation.stopped_thread = 0
	}
	for operation.stopped_processes != 0 {
		index := u32(intrinsics.count_trailing_zeros(operation.stopped_processes))
		operation.stopped_processes &~= 1 << index
		process := &processes[index]
		for intrinsics.atomic_load(&process.serial) == cpu.stopped_serials[index] && intrinsics.atomic_load(&process.holds) & (HOLDS_STOPPED - 1) != 0 && !intrinsics.atomic_load(&self.stop_requested) {
			sync_acknowledge(cpu)
			intrinsics.cpu_relax()
		}
	}
}

execute_locked :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> Operation_Outcome {
	process_index := threads[index].process
	taken := process_lock(process_index)
	defer process_unlock(process_index, taken)
	return execute(index, command, results)
}

// require_control gives Needs_Control when the operation runs without the
// control lock, else Ok. The caller writes `require_control() or_return`
// before it changes anything: the return cannot be forgotten.
require_control :: proc "contextless" () -> Operation_Outcome {
	if processor_self().operation.control {
		return .Ok
	}
	return .Needs_Control
}

// target_lock gives the process that a process handle with the right
// Control names, with its lock (0 names the caller). The caller holds the
// control lock when the handle is not 0.
target_lock :: proc "contextless" (process: ^Process, handle: u64) -> (to: ^Process, taken: bool, status: Operation_Outcome) {
	if handle == 0 {
		return process, false, .Ok
	}
	slot := handle_find(process, handle, .Process, {.Control}) or_return
	return &processes[slot.object], process_lock(slot.object), .Ok
}

// developer_report_ready checks the memory of a report of a developer tool
// (report.odin), then asks for the control lock: the report reads another
// process, and only the control lock keeps its slot for that process.
developer_report_ready :: proc "contextless" (process: ^Process, v: [7]u64, size: u64) -> Operation_Outcome {
	if v[4] < size || !user_range(process, v[3], size, true) {
		return .Bad_Address
	}
	return require_control()
}

// execute runs one operation. The caller holds the process lock of the
// process of the thread, and the control lock if the operation asked for it.
execute :: proc "contextless" (index: u32, command: ring.Record, results: ^[7]u64) -> Operation_Outcome {
	process_index := threads[index].process
	process := &processes[process_index]
	v := command.values

	switch op.Operation(command.kind) {
	case .None:
		// The kind 0 names no operation: a zero record is a command that
		// a process never filled. It is refused as a kind past the last
		// operation is, and its error record says Unknown_Operation.
		return .Bad_Operation

	case .Guest_Run:
		// command_run takes Guest_Run before it comes here: it runs
		// outside the process lock.
		return .Bad_Operation

	case .Log:
		_ = handle_find(process, v[0], .Log, {.Write}) or_return
		form, form_known := enum_word.member_of_word(op.Log_Record_Form, v[5])
		if !form_known {
			return .Bad_Operation
		}
		switch form {
		case .Fact:
			return log_fact_operation(process_index, index, process, v)
		case .Text:
		}
		if v[4] > op.LOG_CALL_RUN_LIMIT {
			return .Bad_Operation
		}
		run_bytes := v[4] * size_of(value_kinds.Value_Run_In_Call)
		if v[2] > op.LOG_TEXT_BYTES_MOST || !user_range(process, v[1], v[2] + run_bytes, false) {
			return .Bad_Address
		}
		level, level_known := enum_word.member_of_word(op.Log_Level, v[3])
		if !level_known {
			return .Bad_Operation
		}
		name := transmute([]u8)process_name(process)
		log_text := &processor_self().log_text
		user_copy(log_text, rawptr(uintptr(v[1])), v[2])
		// The text of a log record is UTF-8 with no control character: the
		// serial port goes to a terminal of the host, which acts on a
		// carriage return or an escape sequence, so a process could forge or
		// hide a line. Each byte of an invalid sequence becomes "?" in the copy, which
		// keeps each offset of the value runs.
		text_encoding.invalid_sequences_replace(log_text[:v[2]])
		// A Log spends the records that its text takes, counted in the copy
		// as log_record cuts it: the amount bounds the lines of the serial
		// port, and a text of LOG_TEXT_BYTES_MOST bytes is 25 records.
		if !budget_log(process.budget, log_records_of_text(log_text[:v[2]])) {
			process.log_lines_refused += 1
			return .No_Budget
		}
		process.log_lines_refused = 0
		// The value runs: checked once, in the copy of this processor. Runs
		// that do not fit the text leave the record plain; the text is whole.
		log_runs := processor_self().log_runs[:v[4]]
		user_copy(raw_data(log_runs), rawptr(uintptr(v[1] + v[2])), run_bytes)
		if !value_kinds.value_runs_check(log_runs, int(v[2])) {
			log_runs = nil
		}
		// The records only, under the log lock: the serial writer writes
		// their line on the serial port after it. A Log that waited
		// for the serial port would learn from its own time how much the
		// other processes wrote (src/md/features/log_side_channels.md).
		taken := log_take()
		if taken && log_head != nil {
			log_record(process_index, intrinsics.atomic_load(&process.serial), process, index, name, level, log_text[:v[2]], log_runs)
			log_free(taken)
			serial_drain_before_the_tick()
			return .Ok
		}
		// No memory of the log: the serial port only.
		log_bytes({'['})
		log_bytes(name)
		log_bytes({']', ' '})
		log_bytes(log_text[:v[2]])
		log_bytes({'\r', '\n'})
		log_free(taken)
		return .Ok

	case .Log_Read:
		// The authority is the memory of the log: its holder reads each
		// record of the whole log, so the own log ring of a process tells it
		// nothing new (src/md/features/own_log_ring.md).
		memory := handle_find(process, v[0], .Memory, {.Read}) or_return
		if log_region == 0 || memory.object != log_region {
			return .Bad_Handle
		}
		if v[1] == 0 || v[1] >= PROCESS_CAPACITY || v[5] > op.OWN_LOG_RECORD_CAPACITY {
			return .Bad_Operation
		}
		// The pages of the caller are present before the log lock: a page on
		// first use takes the frame lock, which comes before it. The process
		// lock of the caller keeps them mapped until the copy ends.
		record_size := u64(size_of(op.Log_Record))
		if !user_range(process, v[4], v[5] * record_size, true) {
			return .Bad_Address
		}
		// The records go to the buffer of this processor under the log
		// lock, and to the caller after it.
		buffer := &processor_self().own_log_copy
		copied, lost, total, found := own_log_ring_copy(&processes[v[1]], v[2], u32(v[3]), v[5], buffer)
		if !found {
			return .Bad_State
		}
		if copied > 0 {
			user_copy(rawptr(uintptr(v[4])), &buffer[0], copied * record_size)
		}
		results[0] = copied
		results[1] = lost
		results[2] = total
		return .Ok

	case .Memory_Create:
		budget := handle_find(process, v[0], .Budget, {.Spend}) or_return
		if v[2] & ~op.MEMORY_FLAGS_KNOWN != 0 {
			return .Bad_Operation
		}
		flags := transmute(op.Memory_Flags)v[2]
		// An uncommitted object has its pages paid later: no frame now, and
		// a frame list. A large-page object is contiguous, of whole large pages.
		if .Uncommitted in flags && flags != {.Uncommitted} || .Large_Pages in flags && v[1] % op.LARGE_PAGE_PAGES != 0 {
			return .Bad_Operation
		}
		large_pages := .Large_Pages in flags
		region := region_create(budget.object, v[1], contiguous = .Contiguous in flags || large_pages, now = .Frames_Now in flags, uncommitted = .Uncommitted in flags, large_pages = large_pages) or_return
		handle := handle_insert(process, {kind = .Memory, rights = RIGHTS_MEMORY, object = region})
		if handle == 0 {
			regions[region].references = 1
			region_release(region)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Memory_Map:
		// A bit that the kernel does not know is refused, as the other
		// memory operations refuse it: a later kernel can give it a meaning.
		if v[3] & ~op.MAP_FLAGS_KNOWN != 0 {
			return .Bad_Operation
		}
		flags := transmute(op.Map_Flags)v[3]
		needed := op.Rights{.Read}
		if .Write in flags {
			needed += {.Write}
		}
		if .Execute in flags {
			needed += {.Execute}
		}
		slot := handle_find(process, v[0], .Memory, needed) or_return
		if v[1] != 0 {
			require_control() or_return
		}
		to, taken := target_lock(process, v[1]) or_return
		defer process_unlock(index_of_process(to), taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		// The registers of a device with a domain drive the device only from
		// the process that holds them: a mapping in another process would
		// outlive the domain of the owner, and could make the device write
		// what the next service of the device declares
		// (src/md/infrastructure/iommu.md, "Mechanism in the kernel, policy outside").
		if to != process && regions[slot.object].requester != 0 {
			return .Bad_Operation
		}
		address, status := map_region(to, slot.object, v[2], flags, v[4], v[5], holding_of_handle(process, slot), by_the_process = to == process)
		results[0] = address
		return status

	case .Memory_Unmap:
		if v[0] != 0 {
			require_control() or_return
		}
		to, taken := target_lock(process, v[0]) or_return
		defer process_unlock(index_of_process(to), taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		for &mapping in to.mappings {
			if mapping.page_count != 0 && mapping.address == v[1] && mapping.address < op.THREAD_AREA_BASE {
				// The code of a module of the starter stays: else the
				// process maps its own code there, under the name of
				// that module. The refusal changes nothing, so it comes
				// before the request of the control lock.
				if to == process && starter_module_meeting(to, mapping.address, mapping.page_count * PAGE_SIZE) != nil {
					return .No_Right
				}
				// The registers of a function behind a conventional bridge can
				// end the domain of its group: the control lock, as for a close.
				if regions[mapping.region].bridge_function != 0 {
					require_control() or_return
				}
				unmap(to, &mapping)
				return .Ok
			}
		}
		return .Bad_Address

	case .Memory_Size:
		slot := handle_find(process, v[0], .Memory) or_return
		results[0] = regions[slot.object].page_count
		return .Ok

	case .Process_Create:
		require_control() or_return
		budget := handle_find(process, v[0], .Budget, {.Spend}) or_return
		if v[2] > op.PROCESS_NAME_BYTES_MOST || !user_range(process, v[1], v[2], false) {
			return .Bad_Address
		}
		name: [op.PROCESS_NAME_BYTES_MOST + 1]u8
		user_copy(&name, rawptr(uintptr(v[1])), v[2])
		// The name starts each line of the log of the process on the serial
		// port: it is a name of the system, printable characters of ASCII
		// and the space ("node 1"), so that no name acts on a terminal of
		// the host. The check is on the copy. An empty name stays allowed.
		if v[2] > 0 && !text_encoding.identifier_words_valid(name[:v[2]]) {
			return .Bad_Operation
		}
		created := process_create(budget.object, name[:v[2]]) or_return
		handle := handle_insert(process, {kind = .Process, rights = RIGHTS_PROCESS, object = created})
		if handle == 0 {
			// No handle ever named it, so no reader sees this cause.
			process_stop(created, .Handles_Closed, .None)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Process_Start:
		require_control() or_return
		slot := handle_find(process, v[0], .Process, {.Control}) or_return
		to := &processes[slot.object]
		taken := process_lock(slot.object)
		defer process_unlock(slot.object, taken)
		// A guest has no kernel half in its page table: no thread runs on it.
		if to.state != .Created || process_is_guest(slot.object) {
			return .Bad_State
		}
		// The first thread of the process gets the limit of a new thread of
		// the thread that starts it, and the limit of its placement: a
		// process does not leave a limit by a process that it starts.
		if _, status := thread_create(slot.object, to.budget, v[1], v[2], v[3], weight_limit = creation_weight_limit(index), processors_limit = intrinsics.atomic_load(&threads[index].processors_limit)); status != .Ok {
			return status
		}
		to.state = .Ready
		return .Ok

	case .Thread_Create:
		require_control() or_return
		budget := handle_find(process, v[0], .Budget, {.Spend}) or_return
		// A weight above the full weight would raise the share: a process
		// would take processor time that its budget does not give. A weight
		// above the limit of a new thread of the calling thread would undo
		// a limit that the holder of the machine set: the new thread gets
		// that limit. A write of the value of the thread comes before this
		// read or after it, and a write of the value of its process holds
		// the control lock, which this operation holds: the creation is
		// then wholly before the write or after.
		weight_limit := creation_weight_limit(index)
		processor_self().operation.thread_create_weight_limit = weight_limit
		if _, accepted := op.thread_schedule_of_new_thread(weight_limit, v[4], v[5]); !accepted {
			return .Bad_Operation
		}
		// The limit of the placement of the calling thread goes to the new
		// thread in the same way, and a write of it at the same time comes
		// before this read or after it.
		created := thread_create(process_index, budget.object, v[1], v[2], v[3], v[4], v[5], weight_limit, intrinsics.atomic_load(&threads[index].processors_limit)) or_return
		handle := handle_insert(process, {kind = .Thread, rights = RIGHTS_THREAD, object = created})
		if handle == 0 {
			thread_stop(created)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Thread_Stop:
		require_control() or_return
		if v[0] == 0 {
			thread_stop(index)
			return .Ok
		}
		slot := handle_find(process, v[0], .Thread, {.Control}) or_return
		thread_stop(slot.object)
		return .Ok

	case .Thread_State:
		slot := handle_find(process, v[0], .Thread, {.Read}) or_return
		results[0] = u64(intrinsics.atomic_load(&threads[slot.object].state))
		// What a holder of the thread needs for Thread_Control: the stop
		// count, and the size and the layout of the extended state area.
		results[1] = u64(intrinsics.atomic_load(&threads[slot.object].control_stops))
		results[2] = extended_state_size
		results[3] = transmute(u64)extended_state_components
		results[4] = u64(EXTENDED_STATE_LAYOUTS[extended_state_form])
		return .Ok

	case .Process_Stop:
		require_control() or_return
		to, taken := target_lock(process, v[0]) or_return
		process_unlock(index_of_process(to), taken)
		// The cause comes from the target, not from the argument 0: a handle
		// that names the caller still makes a stop of the caller.
		cause := op.Stop_Cause.Holder
		if to == process {
			cause = .Itself
		}
		// The one border of the outcome word: only the process itself says
		// what its work gave, so a holder cannot forge a clean end. A refusal
		// changes nothing, and the target runs on.
		outcome, _, outcome_known := op.stop_outcome_of_operation_word(v[1], cause == .Itself)
		if !outcome_known {
			return .Bad_Operation
		}
		process_stop(index_of_process(to), cause, outcome)
		return .Ok

	case .Process_State:
		require_control() or_return
		slot := handle_find(process, v[0], .Process, {.Read}) or_return
		taken := process_lock(slot.object)
		defer process_unlock(slot.object, taken)
		results[0] = u64(process_state(slot.object))
		results[1] = u64(processes[slot.object].cause)
		results[2] = u64(processes[slot.object].outcome)
		results[3] = processes[slot.object].entries
		// The place of the process in the reports of Inspect: a starter that
		// states facts of its child by its slot needs no search of the
		// reports, which another process with the same name can confuse.
		results[4] = u64(slot.object)
		results[5] = u64(intrinsics.atomic_load(&processes[slot.object].serial))
		if v[1] != 0 {
			if !user_range(process, v[1], size_of(op.Stop_Report), true) {
				return .Bad_Address
			}
			user_copy(rawptr(uintptr(v[1])), &processes[slot.object].stop, size_of(op.Stop_Report))
		}
		return .Ok

	case .Handle_Give:
		// A copy in this process needs no Give right: no other process receives it.
		given := handle_find(process, v[1], .None, v[0] == 0 ? op.Rights{} : op.Rights{.Give}) or_return
		if v[0] != 0 || given.kind == .Ports || given.kind == .Interrupt {
			require_control() or_return
		}
		to: ^Process
		through: u64
		if v[0] == 0 {
			to = process
		} else {
			to_slot := handle_find(process, v[0], .None) or_return
			switch to_slot.kind {
			case .Process:
				if .Control not_in to_slot.rights {
					return .No_Right
				}
				to = &processes[to_slot.object]
			case .Memory:
				find: for &other, other_index in processes[1:] {
					other_taken := process_lock(u32(other_index + 1))
					maps := &other != process && other.state != .None && other.state != .Stopped && maps_region(&other, to_slot.object)
					process_unlock(u32(other_index + 1), other_taken)
					if maps {
						to = &other
						break find
					}
				}
				if to == nil {
					// No other process maps the memory yet: the one other
					// process that holds a handle to it. Two holders: no target.
					for &other, other_index in processes[1:] {
						other_taken := process_lock(u32(other_index + 1))
						holds := &other != process && other.state != .None && other.state != .Stopped && holds_region(&other, to_slot.object)
						process_unlock(u32(other_index + 1), other_taken)
						if !holds {
							continue
						}
						if to != nil {
							return .Bad_Handle
						}
						to = &other
					}
				}
				through = regions[to_slot.object].serial
			case .Interrupt, .Ports, .Machine, .Thread, .Budget, .Log, .None:
				// A target of another kind names no process: Bad_Handle below.
			}
		}
		if to == nil {
			return .Bad_Handle
		}
		to_taken := process_lock(index_of_process(to))
		defer process_unlock(index_of_process(to), to_taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		// An object with marks of protection of a part is not given: the marks
		// would reach the mapping of the other process.
		if given.kind == .Memory && to != process && intrinsics.atomic_load(&regions[given.object].marked_pages) != 0 {
			return .Bad_State
		}
		copy := given^
		copy.rights &= transmute(op.Rights)u32(v[2])
		// A process handle that reaches the process that it names loses
		// Control and Give: else the process gives it to a child, and the
		// child changes the module records of its starter in its place
		// (src/md/features/module_record_writer.md).
		if given.kind == .Process && given.object == index_of_process(to) {
			copy.rights -= {.Control, .Give}
		}
		copy.through = through
		handle := handle_insert(to, copy)
		if handle == 0 {
			return .No_Slot
		}
		if !origin_attach(holding_of_handle(to, &to.handles[u32(handle) & 0xFFFF]), holding_of_handle(process, given)) {
			handle_insert_undo(to, handle)
			return .Needs_Control
		}
		results[0] = u64(handle)
		return .Ok

	case .Handle_Revoke:
		require_control() or_return
		slot := handle_find(process, v[0], .None) or_return
		only: u32
		if v[1] != 0 {
			in_process := handle_find(process, v[1], .Process, {.Control}) or_return
			only = in_process.object
		}
		results[0] = revoke(holding_of_handle(process, slot), process_index, only)
		return .Ok

	case .Process_Module:
		if v[0] != 0 {
			require_control() or_return
		}
		to, taken := target_lock(process, v[0]) or_return
		defer process_unlock(index_of_process(to), taken)
		if to.state == .None || to.state == .Stopped {
			return .Bad_State
		}
		if !user_range(process, v[1], size_of(op.Module_Record), false) {
			return .Bad_Address
		}
		record: op.Module_Record
		user_copy(&record, rawptr(uintptr(v[1])), size_of(record))
		// The writer is the party: a process that holds a handle to itself
		// is still the process.
		return process_module(to, record, by_the_process = to == process)

	case .Handle_Close:
		slot := handle_find(process, v[0], .None) or_return
		// A machine handle with Events can end the event table, which
		// changes under the control lock (events.odin). The registers of a
		// function behind a conventional bridge can end the domain of its
		// group, and the interrupt entries of the group with it, which
		// change under the control lock (src/md/infrastructure/iommu.md,
		// "The domain of a conventional bridge").
		bridge_registers := slot.kind == .Memory && regions[slot.object].bridge_function != 0
		if handle_needs_control(slot.kind) || slot.kind == .Machine && .Events in slot.rights || bridge_registers {
			require_control() or_return
		}
		handle_close(process, slot)
		return .Ok

	case .Budget_Create:
		require_control() or_return
		from := handle_find(process, v[0], .Budget, {.Spend}) or_return
		created := budget_create(from.object, {pages = v[1], processes = v[2], threads = v[3], processor = v[4], log_records = v[5]}) or_return
		handle := handle_insert(process, {kind = .Budget, rights = RIGHTS_BUDGET, object = created})
		if handle == 0 {
			budgets[created].references = 1
			budget_release(created)
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Handle_State:
		slot := handle_find(process, v[0], .None) or_return
		results[0] = u64(slot.kind)
		results[1] = u64(transmute(u32)slot.rights)
		if v[1] != 0 {
			memory := handle_find(process, v[1], .Memory) or_return
			results[2] = u64(slot.through != 0 && slot.through == regions[memory.object].serial)
		}
		results[3] = origin_count(holding_of_handle(process, slot))
		return .Ok

	case .Budget_Read:
		slot := handle_find(process, v[0], .Budget, {.Read}) or_return
		amounts := budgets[slot.object].amounts
		results[0] = amounts.pages
		results[1] = amounts.processes
		results[2] = amounts.threads
		results[3] = amounts.processor
		results[4] = amounts.log_records
		results[5] = microseconds(budgets[slot.object].spent_total)
		results[6] = budgets[slot.object].refused
		return .Ok

	case .Word_Wait:
		thread := &threads[index]
		if v[1] > u64(op.WORD_WAIT_CAPACITY - thread.word_count) {
			return .No_Slot
		}
		if !user_range(process, v[0], v[1] * size_of(op.Word), false) {
			return .Bad_Address
		}
		for index in 0 ..< v[1] {
			word: op.Word
			user_copy(&word, rawptr(uintptr(v[0] + index * size_of(op.Word))), size_of(op.Word))
			physical := word_address(process, word.address)
			if physical == 0 {
				thread.word_changed = true // The wait cannot end by this word: do not wait.
				return .Bad_Address
			}
			if !wait_register(thread, physical, u32(word.value)) {
				thread.word_changed = true
			}
		}
		return .Ok

	case .Word_Wake:
		word := word_address(process, v[0])
		if word == 0 {
			return .Bad_Address
		}
		results[0] = word_wake(word, v[1])
		return .Ok

	case .Interrupt_Read:
		slot := handle_find(process, v[0], .Interrupt, {.Read}) or_return
		results[0] = u64(intrinsics.atomic_exchange(&interrupt_pending[slot.object], 0))
		return .Ok

	case .Device_Create:
		_ = handle_find(process, v[0], .Machine, {.Devices}) or_return
		require_control() or_return
		device_kind, device_kind_known := enum_word.member_of_word(op.Device_Kind, v[1])
		if !device_kind_known {
			return .Bad_Operation
		}
		slot: Handle_Slot
		switch device_kind {
		case .Ports:
			if v[2] >= 65536 || v[3] == 0 || v[3] > 65536 - v[2] {
				return .Bad_Address
			}
			slot = {kind = .Ports, rights = RIGHTS_PORTS, object = u32(v[2]), count = u32(v[3])}
		case .Interrupt:
			if v[2] == 0 || v[2] >= INTERRUPT_LINES {
				return .Bad_Address
			}
			slot = {kind = .Interrupt, rights = RIGHTS_INTERRUPT, object = u32(v[2])}
		case .Memory, .Display_Memory:
			// The registers of the IOMMU and the configuration of the bus
			// that it reads belong to the kernel while it is in use.
			if !device_range(v[2], v[3]) || iommu_owns_range(v[2], v[3]) {
				return .Bad_Address
			}
			registers := device_kind == .Memory
			if !registers && !display_memory_range(v[2], v[3]) {
				return .Bad_Operation
			}
			region := region_device(v[2], v[3])
			if region == 0 {
				return .No_Slot
			}
			// A read of a register has an effect, so it must reach the
			// device each time. The pixels of a screen page do not: they
			// keep the rule of the framebuffer of the firmware, which the
			// kernel maps with no attribute of its own.
			regions[region].uncached = registers
			// The function whose registers these are: the process that holds
			// the handle is its service for the IOMMU. Pixels program no
			// access of the device: video memory has no requester. Behind a
			// conventional bridge, the requester is the one that the devices
			// there share.
			if registers {
				regions[region].requester, regions[region].bridge_function = iommu_requester_of(v[2])
			}
			handle := handle_insert(process, {kind = .Memory, rights = {.Give, .Read, .Write}, object = region})
			if handle == 0 {
				regions[region].references = 1
				region_release(region)
				return .No_Slot
			}
			results[0] = u64(handle)
			results[1] = transmute(u64)iommu_device_facts(regions[region].requester)
			// A function behind a conventional bridge that the check of its
			// group did not count ends the domain of the group.
			iommu_bridge_function_made(region)
			return .Ok
		case .Message:
			message := u32(INTERRUPT_CAPACITY)
			for candidate in u32(INTERRUPT_LINES) ..< INTERRUPT_CAPACITY {
				if interrupt_references[candidate] == 0 {
					message = candidate
					break
				}
			}
			if message == INTERRUPT_CAPACITY {
				return .No_Slot
			}
			interrupt_pending[message] = 0
			handle := handle_insert(process, {kind = .Interrupt, rights = RIGHTS_INTERRUPT, object = message})
			if handle == 0 {
				return .No_Slot
			}
			// The first processor receives each message. With interrupt
			// remapping, the entry of the message names the device whose
			// base address register starts at a, so no other device sends
			// it (src/md/infrastructure/iommu.md, "Interrupt remapping").
			results[0] = u64(handle)
			results[1], results[2] = iommu_message_bind(message - INTERRUPT_LINES, v[2])
			return .Ok
		case .None:
			return .Bad_Operation
		}
		handle := handle_insert(process, slot)
		if handle == 0 {
			return .No_Slot
		}
		results[0] = u64(handle)
		return .Ok

	case .Inspect:
		_ = handle_find(process, v[0], .Machine, {.Inspect}) or_return
		inspect_kind, inspect_kind_known := enum_word.member_of_word(op.Inspect_Kind, v[1])
		if !inspect_kind_known {
			return .Bad_Operation
		}
		switch inspect_kind {
		case .System:
			if v[4] < size_of(op.System_Report) || !user_range(process, v[3], size_of(op.System_Report), true) {
				return .Bad_Address
			}
			report := op.System_Report {
				time          = intrinsics.atomic_load(&time_milliseconds),
				page_count    = frame_count,
				process_slots = PROCESS_CAPACITY,
				processors    = u64(processor_count),
				locks         = lock_counts_sum(),
				strategy      = intrinsics.atomic_load(&strategy_chosen),
				strategy_changes = u32(intrinsics.atomic_load(&strategy_changes)),
			}
			// One section of the frame lock: the free pages are the pages of
			// the budgets and the reserved pages, at this moment.
			lock_take(&frame_lock, .Frame)
			report.free_pages, report.reserved_pages = frames_counted() // With the frame caches.
			for budget in budgets {
				report.budget_pages += budget.amounts.pages
			}
			lock_free(&frame_lock, .Frame)
			for cpu in processors[:processor_count] {
				report.entries += intrinsics.volatile_load(&cpu.entries)
				report.interrupts += intrinsics.volatile_load(&cpu.interrupts)
				report.first_use_faults += intrinsics.volatile_load(&cpu.first_use_faults)
			}
			for region in regions {
				if region.page_count != 0 {
					report.region_count += 1
				}
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.System_Report)
		case .Process:
			if v[4] < size_of(op.Process_Report) || !user_range(process, v[3], size_of(op.Process_Report), true) {
				return .Bad_Address
			}
			// Another process: under its lock, with the control lock.
			require_control() or_return
			report: op.Process_Report
			if v[2] != 0 && v[2] < PROCESS_CAPACITY {
				about := &processes[v[2]]
				about_taken := process_lock(u32(v[2]))
				defer process_unlock(u32(v[2]), about_taken)
				// A free slot keeps the facts of its last process: the report
				// gives only its state and its serial, as the stop report of a
				// free slot gives nothing (stop_report_for_inspect).
				if about.state == .None {
					report = {state = .None, process_serial = u64(about.serial)}
				} else {
					report = {
						state        = process_state(u32(v[2])),
						thread_count = u64(about.thread_count),
						stop_cause   = u32(about.cause),
						stop_outcome = u32(about.outcome),
						name         = about.name,
						mapped_pages = about.mapped_pages,
						present_pages = about.table == 0 ? 0 : present_pages(about),
						process_serial = u64(about.serial),
						run_time     = about.run_time,
						start_time   = about.start_time,
						entries      = about.entries,
						budget       = budgets[about.budget].amounts,
					}
					for slot in about.handles {
						if slot.kind != .None {
							report.handle_count += 1
						}
					}
				}
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.Process_Report)
		case .Boot:
			if v[4] < size_of(op.Boot_Report) || !user_range(process, v[3], size_of(op.Boot_Report), true) {
				return .Bad_Address
			}
			record := &processor_self().boot_report
			boot_report(record)
			user_copy(rawptr(uintptr(v[3])), record, size_of(op.Boot_Report))
			results[0] = size_of(op.Boot_Report)
		case .Mappings:
			if v[4] < size_of(op.Mapping_Report) || !user_range(process, v[3], size_of(op.Mapping_Report), true) {
				return .Bad_Address
			}
			record := &processor_self().mapping_report
			if v[2] == 0 {
				mappings_report(record, kernel_table, 256, 512)
			} else {
				mappings_report(record, process.table, 0, 256)
			}
			user_copy(rawptr(uintptr(v[3])), record, size_of(op.Mapping_Report))
			results[0] = size_of(op.Mapping_Report)
		case .Modules:
			if v[4] < size_of(op.Module_Report) || !user_range(process, v[3], size_of(op.Module_Report), true) {
				return .Bad_Address
			}
			require_control() or_return
			report := &processor_self().module_report
			report^ = {}
			if v[2] != 0 && v[2] < PROCESS_CAPACITY {
				about_taken := process_lock(u32(v[2]))
				defer process_unlock(u32(v[2]), about_taken)
				if processes[v[2]].state != .None {
					report.process_serial = u64(processes[v[2]].serial)
				}
				// In the order of the addresses: the module of the process first.
				for item in processes[v[2]].modules {
					if item.size == 0 {
						continue
					}
					place := report.count
					for place > 0 && report.modules[place - 1].base > item.base {
						report.modules[place] = report.modules[place - 1]
						place -= 1
					}
					report.modules[place] = item
					report.count += 1
				}
			}
			user_copy(rawptr(uintptr(v[3])), report, size_of(op.Module_Report))
			results[0] = size_of(op.Module_Report)
		case .Processor:
			if v[4] < size_of(op.Processor_Report) || !user_range(process, v[3], size_of(op.Processor_Report), true) {
				return .Bad_Address
			}
			report: op.Processor_Report
			if v[2] < u64(processor_count) {
				cpu := processors[v[2]]
				report.busy_time = cpu.busy_time
				report.apic_id = u64(cpu.apic_id)
				// Counts that the processor writes alone, and two words of
				// its queue: read with no lock, each one whole.
				report.strategy = intrinsics.atomic_load(&run_queues[cpu.index].strategy)
				report.queued = intrinsics.atomic_load(&run_queues[cpu.index].count)
				report.picks = intrinsics.volatile_load(&cpu.picks)
				report.preemptions = intrinsics.volatile_load(&cpu.preemptions)
				report.moves = intrinsics.volatile_load(&cpu.moves)
				report.pick_cycles = intrinsics.volatile_load(&cpu.pick_cycles)
				report.interrupt_preemptions = intrinsics.volatile_load(&cpu.interrupt_preemptions)
				report.preempt_cycles = intrinsics.volatile_load(&cpu.preempt_cycles)
				report.cache_frames = u64(intrinsics.volatile_load(&cpu.frame_cache.count))
				report.cache_batches_taken = intrinsics.volatile_load(&cpu.frame_cache.batches_taken)
				report.cache_batches_given = intrinsics.volatile_load(&cpu.frame_cache.batches_given)
				report.cache_drains = intrinsics.volatile_load(&cpu.frame_cache.drains)
				if cpu.current != 0 {
					report.process = u64(threads[cpu.current].process)
					report.same = u64(processes[report.process].table == process.table)
				}
			}
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.Processor_Report)
		case .Process_Mappings:
			developer_report_ready(process, v, size_of(op.Process_Mapping_Report)) or_return
			report := &processor_self().process_mapping_report
			process_mappings_report(report, u32(min(v[2], PROCESS_CAPACITY)))
			user_copy(rawptr(uintptr(v[3])), report, size_of(op.Process_Mapping_Report))
			results[0] = size_of(op.Process_Mapping_Report)
		case .Threads:
			developer_report_ready(process, v, size_of(op.Thread_Table_Report)) or_return
			report := &processor_self().thread_table_report
			threads_report(report, u32(min(v[2], PROCESS_CAPACITY)))
			user_copy(rawptr(uintptr(v[3])), report, size_of(op.Thread_Table_Report))
			results[0] = size_of(op.Thread_Table_Report)
		case .Stop:
			developer_report_ready(process, v, size_of(op.Stop_Report)) or_return
			report := &processor_self().stop_report
			stop_report_for_inspect(report, u32(min(v[2], PROCESS_CAPACITY)))
			user_copy(rawptr(uintptr(v[3])), report, size_of(op.Stop_Report))
			results[0] = size_of(op.Stop_Report)
		case .Pages:
			if v[4] < size_of(op.Page_Report) || !user_range(process, v[3], size_of(op.Page_Report), true) {
				return .Bad_Address
			}
			// The process that asks only: another process is not watched page
			// by page. Its process lock is held (execute_locked).
			if v[2] != 0 {
				return .Bad_Operation
			}
			report: op.Page_Report
			user_copy(&report, rawptr(uintptr(v[3])), size_of(report))
			if report.address & (PAGE_SIZE - 1) != 0 || report.address >= op.USER_END || op.PAGE_REPORT_CAPACITY * PAGE_SIZE > op.USER_END - report.address {
				return .Bad_Operation
			}
			pages_report(&report, process)
			user_copy(rawptr(uintptr(v[3])), &report, size_of(report))
			results[0] = size_of(op.Page_Report)
		case .None:
			return .Bad_Operation
		}
		return .Ok

	case .Memory_Physical:
		_ = handle_find(process, v[0], .Machine, {.Physical}) or_return
		slot := handle_find(process, v[1], .Memory, {.Read}) or_return
		// The call of a device service declares the object to its devices,
		// which write it only when this handle can, and gives the address
		// that they use for it.
		results[0] = iommu_declare(process_index, slot.object, .Write in slot.rights) or_return
		return .Ok

	case .Memory_Commit:
		memory := handle_find(process, v[0], .Memory, {.Write}) or_return
		flags := transmute(op.Commit_Flags)v[4]
		decommit := .Decommit in flags
		// The payer: a handle to the budget of the object, with Commit or
		// Spend (docs/ARCHITECTURE.md, "Who pays a commit"). A decommit gives pages back to it, and
		// reads no budget handle.
		if !decommit {
			budget := handle_find(process, v[1], .Budget) or_return
			if budget.rights & {.Commit, .Spend} == {} {
				return .No_Right
			}
			if budget.object != intrinsics.atomic_load(&regions[memory.object].budget) {
				return .Bad_Handle
			}
		}
		if v[3] == 0 || v[3] > op.RANGE_TABLE_CAPACITY || v[4] & ~op.COMMIT_FLAGS_KNOWN != 0 {
			return .Bad_Operation
		}
		if !user_range(process, v[2], v[3] * size_of(op.Page_Range), false) {
			return .Bad_Address
		}
		table := &processor_self().range_table
		user_copy(table, rawptr(uintptr(v[2])), v[3] * size_of(op.Page_Range))
		counts: [op.RANGE_TABLE_CAPACITY]u64
		for range, index in table[:v[3]] {
			counts[index] = range.page_count
		}
		if table_pages(counts[:v[3]]) > op.RANGE_TABLE_PAGE_LIMIT {
			return .Bad_Operation
		}
		changed := memory_commit(process, memory.object, table[:v[3]], decommit) or_return
		results[0] = changed
		return .Ok

	case .Memory_Protect:
		if v[1] == 0 || v[1] > op.RANGE_TABLE_CAPACITY || v[2] & ~op.MAP_FLAGS_KNOWN != 0 {
			return .Bad_Operation
		}
		flags := transmute(op.Map_Flags)v[2]
		if !user_range(process, v[0], v[1] * size_of(op.Address_Range), false) {
			return .Bad_Address
		}
		table := &processor_self().range_table
		user_copy(table, rawptr(uintptr(v[0])), v[1] * size_of(op.Address_Range))
		ranges := ([^]op.Address_Range)(&table[0])[:v[1]]
		changed := memory_protect(process, ranges, flags) or_return
		results[0] = changed
		return .Ok

	case .Fault_Handler_Set:
		// The fault ring (fault_ring.odin): the process names one of its
		// own threads. The handler of the faults of a process is a thread
		// of that process.
		action, action_known := enum_word.member_of_word(op.Fault_Handler_Action, v[1])
		if v[3] != 0 {
			// The debugger of another process: the thread takes the debug
			// exceptions and the breakpoints of that process. Two processes:
			// the control lock.
			debugger_kinds, debugger_known := op.fault_kinds_of_debugger_argument(v[2])
			if !action_known || !debugger_known || action == .End && v[2] != 0 {
				return .Bad_Operation
			}
			debugged := handle_find(process, v[3], .Process, {.Debug}) or_return
			require_control() or_return
			switch action {
			case .End:
				return debug_handler_detach(process_index, debugged.object)
			case .Set:
				debug_handler := index
				if v[0] != 0 {
					slot := handle_find(process, v[0], .Thread, {.Control}) or_return
					debug_handler = slot.object
				}
				return debug_handler_set(process_index, debug_handler, debugged.object, debugger_kinds)
			}
		}
		kinds, known := op.fault_kinds_of_argument(v[2])
		if !action_known || !known {
			return .Bad_Operation
		}
		switch action {
		case .End:
			if v[2] != 0 {
				return .Bad_Operation // The end of the delivery takes no kinds.
			}
			return fault_handler_set(process_index, 0, 0)
		case .Set:
		}
		handler := index
		if v[0] != 0 {
			slot := handle_find(process, v[0], .Thread, {.Control}) or_return
			handler = slot.object
		}
		return fault_handler_set(process_index, handler, kinds)

	case .Fault_Answer:
		answer, answer_known := enum_word.member_of_word(op.Fault_Answer_Kind, v[2])
		if !answer_known || answer == .None {
			return .Bad_Operation
		}
		if v[3] != 0 {
			// The answer of the debugger of another process. Only Resume:
			// the report of a stop reads the stack of the process through
			// the page table of this processor, which is the one of the
			// debugger here; a debugger stops a process with Process_Stop.
			if answer != .Resume {
				return .Bad_Operation
			}
			debugged := handle_find(process, v[3], .Process, {.Debug}) or_return
			require_control() or_return
			return debug_fault_answer(process_index, debugged.object, v[0], v[1])
		}
		// A stop of the process on a fault takes the control lock.
		if answer == .Stop {
			require_control() or_return
		}
		waiter_index := fault_waiter_find(process_index, v[0], v[1])
		// A thread whose record went to the debugger of the process waits
		// for the debugger: the process does not answer in its place.
		if waiter_index == 0 || threads[waiter_index].fault_to_debugger {
			return .Bad_State // No thread with that number and fault serial waits: an old answer, or a wrong one.
		}
		waiter := &threads[waiter_index]
		// A fault that is not a page fault and not a trap would run the same
		// instruction on the same registers, and fault again with no end,
		// unless the handler wrote the registers or the extended state of
		// the thread since the fault (Thread_Control): then the handler
		// chose where and with what the thread goes on, and each new fault
		// is a new record that it reads. With no write, the refusal leaves
		// the thread waiting, so that Stop still ends it with its report.
		// The vector is the one of its fault: a write of Thread_Control
		// does not change it.
		if answer == .Resume && !op.fault_kind_resumes(waiter.frame.vector) && !waiter.registers_written {
			return .Bad_State
		}
		if answer == .Resume {
			// A thread that goes on at an execute breakpoint of its own
			// runs that instruction once (breakpoints.odin). Its frame is
			// written only after it left its processor.
			if waiter.frame.vector == VECTOR_DEBUG && intrinsics.atomic_load(&waiter.has_breakpoints) {
				if !thread_held_off_processor(waiter) {
					return .Bad_State
				}
				breakpoint_resume_flag_set(waiter)
			}
			waiter.fault_waits = false
			thread_wake(waiter)
			return .Ok
		}
		waiter.fault_waits = false
		// The report of the fault, as with no handler. A write of
		// Thread_Control can have moved the instruction address and the
		// frame pointer of the waiting thread since its fault: the report
		// takes the two of the fault, which fault_deliver kept, so that it
		// names the instruction that faulted and its stack trace. The vector
		// and the error code are the fault's: no write changes them. The page
		// table of this processor is the one of the process (the stack trace).
		fault_frame := waiter.frame
		fault_frame.rip = waiter.fault_instruction
		fault_frame.rbp = waiter.fault_frame_pointer
		process_stop(process_index, process_fault_report(process_index, &fault_frame, waiter.fault_address), .None)
		return .Ok

	case .Events_Set:
		// Kernel events (events.odin): the table changes under the control
		// lock.
		return events_set(process_index, v, results)

	case .Strategy_Set:
		_ = handle_find(process, v[0], .Machine, {.Schedule}) or_return
		strategy, strategy_known := enum_word.member_of_word(op.Strategy, v[1])
		if !strategy_known || strategy == .None {
			return .Bad_Operation
		}
		results[0] = u64(strategy_change(strategy))
		return .Ok

	case .Thread_Control:
		// The control of a thread (thread_control.odin).
		return thread_control(index, v, results)

	case .Machine_Stop:
		_ = handle_find(process, v[0], .Machine, {.Stop}) or_return
		// The host receives one byte: a larger code would end the machine
		// with its low byte, and 256 would read as a normal end.
		if v[1] > op.MACHINE_STOP_CODE_MOST {
			return .Bad_Operation
		}
		log("kernel: the machine stops with code ", v[1])
		machine_stop_with_code(u8(v[1]))

	case:
		// A command that names a table of error details has a kind that no
		// operation has, so only this branch reads the bit: the dispatch of
		// a command with no table runs no added instruction. The command
		// with the bit removed runs once, under the same locks
		// (src/md/features/kernel_error_details.md).
		if command.kind & op.COMMAND_NAMES_ERROR_DETAILS != 0 {
			named := command
			named.kind &~= op.COMMAND_NAMES_ERROR_DETAILS
			if operation, known := enum_word.member_of_word(op.Operation, u64(named.kind)); known && op.command_takes_error_details(operation) {
				return execute(index, named, results)
			}
		}
	}
	return .Bad_Operation
}
