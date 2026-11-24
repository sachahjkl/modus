package kernel

import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"

// The error record of a kernel operation that failed, and the stack trace
// of a fault (docs/MODULE_CONTRACT.md, section 8).
//
// The kernel finds the record after the operation failed: the operations
// do not change, and an operation that succeeds runs no code of this file.
// The record comes from the forms of the parameters (op.OPERATIONS), read
// in their order, as the operation reads them. It describes what the
// caller gave and its own handles: the amounts of a budget and the state
// of a process only when the handle has the right Read: without it, a
// process learns nothing of another process.
//
// Each table is read in one place: the procedures `read_*` below. Each one
// takes the lock that protects what it reads in the table "Locks of the
// kernel" of docs/ARCHITECTURE.md, in the lock order, copies what it reads,
// and frees the lock before it returns. `diagnose` runs after the operation
// freed all its locks (enter, after command_run), and only on a failure: the
// path of a success takes no lock here. Between the failure and the record,
// another thread can change the state: the record describes what the kernel
// reads now, and `diagnose` keeps it only if its kind can explain the status
// (`kind_explains`); else the record is Refused with the status. A record
// never contradicts its status.
//
// A read that follows a handle to another object (a budget, a memory object,
// a process) finds the handle again under the process lock of the caller,
// and keeps that lock while it reads the object: the handle holds a
// reference, so the slot of the object cannot serve another object.

// The lock of the process that runs. Taken by each read of its handle table,
// its mappings and its page table. A read in the stack trace runs under this
// lock already (process_fault): process_lock then takes nothing.
@(private = "file")
caller_lock :: proc "contextless" (process: ^Process) -> (index: u32, taken: bool) {
	index = u32(intrinsics.ptr_sub(process, &processes[0]))
	return index, process_lock(index)
}

// find is handle_find on a copy of the slot, under the process lock that the
// caller of find holds.
@(private = "file")
find :: proc "contextless" (process: ^Process, handle: u64, kind: Object_Kind, rights: op.Rights) -> (slot: Handle_Slot, ok: bool) {
	index := handle & 0xFFFF
	if index == 0 || index >= HANDLE_CAPACITY || handle >> 32 != 0 {
		return {}, false
	}
	slot = process.handles[index]
	if slot.kind == .None || u64(slot.generation) != handle >> 16 || kind != .None && slot.kind != kind || !(rights <= slot.rights) {
		return {}, false
	}
	return slot, true
}

// read_handle copies the slot of a handle of a process. Lock: the process
// lock.
@(private = "file")
read_handle :: proc "contextless" (process: ^Process, index: u64) -> Handle_Slot {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	return process.handles[index]
}

// read_handle_find copies the slot of a handle that names an object of the
// kind with the rights. Lock: the process lock.
@(private = "file")
read_handle_find :: proc "contextless" (process: ^Process, handle: u64, kind: Object_Kind, rights: op.Rights = {}) -> (slot: Handle_Slot, ok: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	return find(process, handle, kind, rights)
}

// read_free_handles counts the free places of the handle table of a
// process. Lock: the process lock.
@(private = "file")
read_free_handles :: proc "contextless" (process: ^Process) -> (count: u64) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	for slot in process.handles[1:] {
		count += u64(slot.kind == .None)
	}
	return count
}

// read_user copies memory of the process that runs, if it can read it.
// Lock: the process lock: no unmap runs between user_range and the copy.
@(private = "file")
read_user :: proc "contextless" (process: ^Process, address: u64, destination: rawptr, size: u64) -> bool {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	if !user_range(process, address, size, false) {
		return false
	}
	user_copy_from_process(destination, address, size)
	return true
}

// read_range says if the process can read (or write) a range of its
// memory. Lock: the process lock.
@(private = "file")
read_range :: proc "contextless" (process: ^Process, address: u64, size: u64, write := false) -> bool {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	return user_range(process, address, size, write)
}

// read_overlaps says if a range of addresses overlaps a mapping of the
// process. Lock: the process lock.
@(private = "file")
read_overlaps :: proc "contextless" (process: ^Process, address: u64, size: u64) -> bool {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	for mapping in process.mappings {
		if mapping.page_count != 0 && address < mapping.address + mapping.page_count * PAGE_SIZE && mapping.address < address + size {
			return true
		}
	}
	return false
}

// read_mapping_at gives the pages of the mapping of the process that starts
// at an address, if one starts there. Lock: the process lock.
@(private = "file")
read_mapping_at :: proc "contextless" (process: ^Process, address: u64) -> (page_count: u64, found: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	for mapping in process.mappings {
		if mapping.page_count != 0 && mapping.address == address {
			return mapping.page_count, true
		}
	}
	return 0, false
}

// read_starter_module copies the module record of the writer Starter that
// meets a range of addresses of the process. Lock: the process lock.
@(private = "file")
read_starter_module :: proc "contextless" (process: ^Process, address: u64, size: u64) -> (record: op.Module_Record, found: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	if item := starter_module_meeting(process, address, size); item != nil {
		return item^, true
	}
	return {}, false
}

// read_own_full says which tables of the process are full: its mappings,
// its module records, its thread areas. Lock: the process lock.
@(private = "file")
read_own_full :: proc "contextless" (process: ^Process) -> (mappings, modules, threads: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	mappings, modules = true, true
	for mapping in process.mappings {
		if mapping.page_count == 0 {
			mappings = false
		}
	}
	for item in process.modules {
		if item.size == 0 {
			modules = false
		}
	}
	threads = process.thread_count >= op.THREAD_CAPACITY
	return mappings, modules, threads
}

// read_regions_full says if the table of the memory objects is full. Lock:
// the frame lock (the slots of the memory objects).
@(private = "file")
read_regions_full :: proc "contextless" () -> bool {
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	for region in regions[1:] {
		if region.page_count == 0 {
			return false
		}
	}
	return true
}

// Machine_Full: which tables of the machine are full.
@(private = "file")
Machine_Full :: struct {
	processes, budgets, messages: bool,
}

// read_machine_full reads the tables of the machine that the operations
// that create objects scan under the control lock. Lock: the control lock.
@(private = "file")
read_machine_full :: proc "contextless" () -> (full: Machine_Full) {
	control_take()
	defer control_free()
	full = {true, true, true}
	for process in processes[1:] {
		if process.state == .None {
			full.processes = false
		}
	}
	for budget in budgets[1:] {
		if !budget.live {
			full.budgets = false
		}
	}
	for candidate in u32(INTERRUPT_LINES) ..< INTERRUPT_CAPACITY {
		if interrupt_references[candidate] == 0 {
			full.messages = false
		}
	}
	return full
}

// read_device_word says if a word of a process is in device memory. Lock:
// the process lock.
@(private = "file")
read_device_word :: proc "contextless" (process: ^Process, address: u64) -> bool {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	return word_in_device_memory(process, address)
}

// read_word says if a process can wait on a word, or with write, wake it.
// Lock: the process lock.
@(private = "file")
read_word :: proc "contextless" (process: ^Process, address: u64, write := false) -> bool {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	return word_address(process, address, write) != 0
}

// read_threads gives the threads of a process. Lock: the process lock.
@(private = "file")
read_threads :: proc "contextless" (process: ^Process) -> u32 {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	return process.thread_count
}

// read_budget copies the rights of a budget handle with the right Spend,
// and, with the right Read, the amounts that the operation needs. Locks, in
// their order: the control lock only for the processes, the threads and the
// limits (Process_Create, Thread_Create, Budget_Create); the process lock
// (the handle); the frame lock (the pages). A handle without Read gives no
// amount: the amounts tell of the other processes that the budget pays for.
@(private = "file")
read_budget :: proc "contextless" (process: ^Process, handle: u64, operation: op.Operation) -> (amounts: op.Budget_Amounts, rights: op.Rights, ok: bool) {
	rights, ok = read_budget_rights(process, handle)
	if !ok || .Read not_in rights {
		return {}, rights, ok
	}
	control := operation != .Memory_Create
	if control {
		control_take()
	}
	at, taken := caller_lock(process)
	slot: Handle_Slot
	if slot, ok = find(process, handle, .Budget, {.Spend, .Read}); ok {
		budget := &budgets[slot.object]
		if control {
			amounts = budget.amounts
		}
		lock_take(&frame_lock, .Frame)
		amounts.pages = budget.amounts.pages
		lock_free(&frame_lock, .Frame)
	}
	process_unlock(at, taken)
	if control {
		control_free()
	}
	return amounts, slot.rights, ok
}

// read_budget_rights gives the rights of a budget handle with the right
// Spend. Lock: the process lock.
@(private = "file")
read_budget_rights :: proc "contextless" (process: ^Process, handle: u64) -> (rights: op.Rights, ok: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	slot: Handle_Slot
	slot, ok = find(process, handle, .Budget, {.Spend})
	return slot.rights, ok
}

// read_log_count gives the log records in this second of the budget that
// paid for the process, and its limit, if the process holds that budget
// with the right Read, because the count tells of the other processes that
// the budget pays for; held is false otherwise. Lock: the process lock
// only. The handle keeps the budget live; process.budget changes only when
// that budget ends (an atomic store). The limit changes when a budget comes
// from it or ends, under the frame lock, and is read once, as Log reads it.
// The count is atomic.
@(private = "file")
read_log_count :: proc "contextless" (process: ^Process) -> (logged, limit: u64, held: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	budget := intrinsics.atomic_load(&process.budget)
	for slot in process.handles[1:] {
		if slot.kind == .Budget && slot.object == budget && .Read in slot.rights {
			held = true
		}
	}
	if !held {
		return 0, 0, false
	}
	word := intrinsics.atomic_load(&budgets[budget].logged)
	second := intrinsics.atomic_load(&time_milliseconds) / LOG_PERIOD
	logged = word >> 32 == second ? word & 0xFFFF_FFFF : 0
	return logged, intrinsics.atomic_load(&budgets[budget].amounts.log_records), true
}

// read_protect_range says if one mapping of the process holds a range of
// pages from an address, and if the range is a part of a mapping whose
// protection changes only whole (a contiguous object, a thread area).
@(private = "file")
read_protect_range :: proc "contextless" (process: ^Process, address: u64, page_count: u64) -> (covered: bool, whole_only: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	for mapping in process.mappings {
		if mapping.page_count != 0 && address >= mapping.address && (address - mapping.address) / PAGE_SIZE + page_count <= mapping.page_count {
			whole := address == mapping.address && page_count == mapping.page_count
			whole_only = mapping.address >= op.THREAD_AREA_BASE || !whole && regions[mapping.region].contiguous
			return true, whole_only
		}
	}
	return false, false
}

// read_protect_walk gives what a table of address ranges of a protection
// change costs, as memory_protect counts it (protect_walk_count). A range
// that no mapping covers counts its pages.
@(private = "file")
read_protect_walk :: proc "contextless" (process: ^Process, address: u64, count: u64) -> (walked: u64) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	for index in 0 ..< min(count, op.RANGE_TABLE_CAPACITY) {
		range: op.Address_Range
		if !read_user(process, address + index * size_of(op.Address_Range), &range, size_of(range)) {
			return 0
		}
		cost := min(range.page_count, op.RANGE_TABLE_PAGE_LIMIT + 1)
		for &mapping in process.mappings {
			if mapping.page_count != 0 && range.address >= mapping.address && (range.address - mapping.address) / PAGE_SIZE + range.page_count <= mapping.page_count {
				cost = protect_walk_count(&mapping, range)
				break
			}
		}
		walked += cost
	}
	return walked
}

// read_marked_pages gives the pages with a protection of their own of the
// memory object of a handle; 0 for another handle.
@(private = "file")
read_marked_pages :: proc "contextless" (process: ^Process, handle: u64) -> u64 {
	slot, found := read_handle_find(process, handle, .Memory)
	if !found {
		return 0
	}
	return intrinsics.atomic_load(&regions[slot.object].marked_pages)
}

// read_device_cache_conflict says if a map of a memory handle with flags
// meets a live mapping of another cache type over its frames
// (device_cache_type_claim). It reads the counts under the frame lock and
// changes nothing.
@(private = "file")
read_device_cache_conflict :: proc "contextless" (process: ^Process, handle: u64, flags: op.Map_Flags) -> bool {
	slot, found := read_handle_find(process, handle, .Memory)
	if !found {
		return false
	}
	region := &regions[slot.object]
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	if !region.cache_types_counted {
		return false
	}
	return device_cache_type_conflict(slot.object, device_cache_type_of(region, flags))
}

// read_table_pages gives the pages of a table of ranges in memory of the
// process (a Page_Range or an Address_Range: the offset of the count).
@(private = "file")
read_table_pages :: proc "contextless" (process: ^Process, address: u64, count: u64, record_size: u64, count_offset: uintptr) -> (pages: u64) {
	for index in 0 ..< min(count, op.RANGE_TABLE_CAPACITY) {
		value: u64
		if !read_user(process, address + index * record_size + u64(count_offset), &value, 8) {
			return 0
		}
		pages += min(value, op.RANGE_TABLE_PAGE_LIMIT + 1)
	}
	return pages
}

// read_commit_needed gives the pages that a commit of a table of ranges
// asks (the pages that are not committed) and the pages that the budget of
// the object holds; held is false when the record must not name them.
@(private = "file")
read_commit_needed :: proc "contextless" (process: ^Process, handle: u64, ranges_address: u64, count: u64) -> (needed, pages: u64, held: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	slot: Handle_Slot
	ok: bool
	if slot, ok = find(process, handle, .Memory, {}); !ok {
		return
	}
	region := &regions[slot.object]
	if !region.uncommitted {
		return
	}
	walked: u64
	for index in 0 ..< min(count, op.RANGE_TABLE_CAPACITY) {
		range: op.Page_Range
		if !read_user(process, ranges_address + index * size_of(op.Page_Range), &range, size_of(range)) || range.first >= region.page_count || range.page_count > region.page_count - range.first {
			return
		}
		// At most RANGE_TABLE_PAGE_LIMIT pages read: the table is memory of
		// the process, which can grow it after the call failed, and the
		// sum runs with the process lock held.
		walked += range.page_count
		if walked > op.RANGE_TABLE_PAGE_LIMIT {
			return
		}
		for page in range.first ..< range.first + range.page_count {
			needed += 1 - intrinsics.atomic_load(region_slot(region, page)) & SLOT_COMMITTED
		}
	}
	lock_take(&frame_lock, .Frame)
	pages = budgets[region.budget].amounts.pages
	lock_free(&frame_lock, .Frame)
	return needed, pages, true
}

// read_memory_pages gives the pages of the memory object of a handle.
// Locks, in their order: the process lock (the handle), the frame lock (the
// slot of the object).
@(private = "file")
read_memory_pages :: proc "contextless" (process: ^Process, handle: u64) -> (pages: u64, ok: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	slot: Handle_Slot
	if slot, ok = find(process, handle, .Memory, {}); !ok {
		return 0, false
	}
	lock_take(&frame_lock, .Frame)
	pages = regions[slot.object].page_count
	lock_free(&frame_lock, .Frame)
	return pages, true
}

// read_process_state gives the kind and the rights of a handle, and the
// state of its process when it names a process with the right Read (else
// None). Locks, in their order: the control lock (another process), the
// process lock of the caller (the handle), the process lock of the other
// process (two process locks only under the control lock).
@(private = "file")
read_process_state :: proc "contextless" (process: ^Process, handle: u64) -> (slot: Handle_Slot, state: op.Process_State, ok: bool) {
	control_take()
	defer control_free()
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	if slot, ok = find(process, handle, .None, {}); !ok {
		return {}, .None, false
	}
	if slot.kind == .Process && .Read in slot.rights {
		other := process_lock(slot.object)
		state = process_state(slot.object)
		process_unlock(slot.object, other)
	}
	return slot, state, true
}

// read_memory_info reads the kind flags of the memory object of a handle.
// Locks, in their order: the process lock, the frame lock.
@(private = "file")
read_memory_info :: proc "contextless" (process: ^Process, handle: u64) -> (uncommitted, uncached: bool, ok: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	slot: Handle_Slot
	if slot, ok = find(process, handle, .Memory, {}); !ok {
		return false, false, false
	}
	lock_take(&frame_lock, .Frame)
	uncommitted = regions[slot.object].uncommitted
	uncached = regions[slot.object].uncached
	lock_free(&frame_lock, .Frame)
	return uncommitted, uncached, true
}

// read_module_problem checks whether a Module_Record fails because no record
// exists at its base (size == 0) or because it overlaps an existing record
// (size != 0). Lock: the process lock.
@(private = "file")
read_module_problem :: proc "contextless" (process: ^Process, record: op.Module_Record) -> (missing, overlaps: bool) {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	if record.size == 0 {
		for item in process.modules {
			if item.size != 0 && item.base == record.base {
				return false, false
			}
		}
		return true, false
	}
	for item in process.modules {
		if item.size != 0 && record.base < item.base + item.size && item.base < record.base + record.size {
			return false, true
		}
	}
	return false, false
}

// read_protect_rights_refused says if a range of a Memory_Protect asks for
// rights past what its mapping allows. Lock: the process lock.
@(private = "file")
read_protect_rights_refused :: proc "contextless" (process: ^Process, address: u64, count: u64, flags: op.Map_Flags) -> bool {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	for index in 0 ..< min(count, op.RANGE_TABLE_CAPACITY) {
		range: op.Address_Range
		if !read_user(process, address + index * size_of(op.Address_Range), &range, size_of(range)) {
			return false
		}
		for mapping in process.mappings {
			if mapping.page_count != 0 && range.address >= mapping.address && (range.address - mapping.address) / PAGE_SIZE + range.page_count <= mapping.page_count {
				if .Write in flags && mapping.limit_bits & PAGE_WRITE == 0 {
					return true
				}
				if .Execute in flags && mapping.limit_bits & PAGE_NO_EXECUTE != 0 {
					return true
				}
				whole := range.address == mapping.address && range.page_count == mapping.page_count
				if !whole {
					if .No_Access not_in flags && mapping.bits == 0 {
						return true
					}
					if .Write in flags && mapping.bits & PAGE_WRITE == 0 {
						return true
					}
					if .Execute in flags && mapping.bits & PAGE_NO_EXECUTE != 0 {
						return true
					}
				}
				break
			}
		}
	}
	return false
}

// kind_explains says if an error kind can be the cause of an outcome.
@(private = "file")
kind_explains :: proc "contextless" (kind: errors.Kind, outcome: call_outcome.Call_Outcome) -> bool {
	return outcome != .Succeeded && kind in call_outcome.KINDS_OF[outcome]
}

@(private = "file")
record_set :: proc "contextless" (record: ^errors.Error_Record, kind: errors.Kind, unit: errors.Unit, argument: int, value, limit, found: u64) {
	record.kind, record.unit, record.argument = i64(kind), i64(unit), i64(argument)
	record.value, record.limit, record.found = i64(value), i64(limit), i64(found)
}

// diagnose gives the error record of an operation of a process that failed
// with an outcome.
diagnose :: proc "contextless" (process_index: u32, command: ring.Record, outcome: call_outcome.Call_Outcome) -> (record: errors.Error_Record) {
	// It runs with no lock held: each read takes its locks in the lock order.
	when TEST_BUILD_CHECKS_LOCK_ORDER {
		for kind in op.Lock_Kind {
			if lock_ready && lock_held(kind) {
				log("kernel: diagnose runs with a lock ", op.LOCK_KIND_NAMES[kind], " held")
				machine_stop(.Invariant_Broken)
			}
		}
	}
	record.operation = i64(command.kind)
	operation, known := enum_word.member_of_word(op.Operation, u64(command.kind))
	if !known || operation == .None {
		record_set(&record, .Unknown_Operation, .None, 0, u64(command.kind), u64(max(op.Operation)), 0)
		return record
	}
	process := &processes[process_index]
	v := command.values
	explained := false
	switch outcome {
	case .Succeeded, .Name_Already_Taken, .Another_Change_Came_First, .Data_Damaged, .Callee_Unavailable, .Stopped_After_A_Partial_Change, .Callee_Stopped_During_The_Call, .Connection_Ended_During_The_Call, .Deadline_Passed_During_The_Call, .Answer_Unreadable:
		// No record explains a success, nor an outcome the kernel never gives.
	case .Operation_Unsupported:
		explained = unsupported_explain(&record, operation, v)
	case .Argument_Refused:
		explained = handles_explain(&record, process, operation, v, check_rights = false)
		if !explained {
			explained = address_explain(&record, process, operation, v)
		}
		if !explained {
			explained = value_explain(&record, process, operation, v)
		}
	case .Grant_Or_Right_Missing:
		explained = handles_explain(&record, process, operation, v, check_rights = true)
		if explained && record.kind != i64(errors.Kind.Handle_Rights) {
			record = {operation = record.operation}
			explained = false
		}
		if !explained {
			explained = starter_module_explain(&record, process, operation, v)
		}
	case .Nothing_Has_That_Name:
		if operation == .Thread_Control {
			explained = state_explain(&record, process, operation, v)
		}
	case .Callee_Busy:
		explained = slot_explain(&record, process, operation, v, .Callee_Busy)
	case .Budget_Or_Capacity_Exhausted:
		explained = budget_explain(&record, process, operation, v)
		if !explained && operation == .Thread_Control {
			explained = state_explain(&record, process, operation, v)
		}
		if !explained {
			explained = slot_explain(&record, process, operation, v, .Budget_Or_Capacity_Exhausted)
		}
	case .Wrong_State:
		explained = state_explain(&record, process, operation, v)
		if !explained && operation == .Handle_Give && v[0] != 0 {
			record_set(&record, .No_Target, .None, 1, v[0], 0, 0) // A memory object that no one other process maps with Receive_Handles.
			explained = true
		}
	}
	// The kind is the word that an explanation above wrote: it is read
	// through its border, as each word of a record is.
	explained_kind, explained_kind_ok := errors.kind_of_word(record.kind)
	if !explained || !explained_kind_ok || !kind_explains(explained_kind, outcome) {
		record = {operation = record.operation}
		record_set(&record, .Refused, .None, 0, 0, 0, u64(outcome))
	}
	return record
}

// unsupported_explain names an operation or subcommand that the machine
// does not support.
@(private = "file")
unsupported_explain :: proc "contextless" (record: ^errors.Error_Record, operation: op.Operation, v: [7]u64) -> bool {
	#partial switch operation {
	case .Guest_Run:
		if !intrinsics.atomic_load(&guest_support.ready) {
			record_set(record, .Unsupported, .None, 0, u64(op.Operation.Guest_Run), 0, 0)
			return true
		}
	case .Thread_Control:
		if command, command_known := enum_word.member_of_word(op.Thread_Control_Command, v[2]); command_known {
			if op.thread_control_counts_the_caller(command) && counter_plan.vendor == .None {
				record_set(record, .Unsupported, .None, 0, u64(op.Operation.Thread_Control), 0, 0)
				return true
			}
			if (command == .Record_Start || command == .Replay_Start) && !intrinsics.atomic_load(&cpuid_faulting_supported) {
				record_set(record, .Unsupported, .None, 0, u64(op.Operation.Thread_Control), 0, 0)
				return true
			}
		}
	}
	return false
}

// diagnose_command gives the error record of a command that failed, as
// diagnose, and writes its table of error details when its kind names one
// (src/md/features/kernel_error_details.md). It runs where diagnose runs:
// after the operation freed its locks, and only on a failure, so a command
// that succeeds never reads the bit here.
diagnose_command :: proc "contextless" (process_index: u32, command: ring.Record, outcome: call_outcome.Call_Outcome) -> errors.Error_Record {
	if command.kind & op.COMMAND_NAMES_ERROR_DETAILS == 0 {
		return diagnose(process_index, command, outcome)
	}
	named := command
	named.kind &~= op.COMMAND_NAMES_ERROR_DETAILS
	operation, known := enum_word.member_of_word(op.Operation, u64(named.kind))
	if !known || operation == .None {
		return diagnose(process_index, command, outcome) // Unknown_Operation, with the kind that the process sent.
	}
	// The dispatch refused the command before the operation: the last value
	// is an argument of this operation, or the operation runs before the
	// dispatch. It is not a table, and nothing is written there.
	if !op.command_takes_error_details(operation) {
		unsupported := errors.Error_Record{operation = i64(named.kind)}
		record_set(&unsupported, .Unsupported, .None, 0, u64(named.kind), 0, 0)
		return unsupported
	}
	record := diagnose(process_index, named, outcome)
	error_details_write(&processes[process_index], operation, named.values, record)
	return record
}

// error_details_write finds each argument of a refused command that the
// checks of its form find wrong now, and writes the details in the table
// place that the last value of the command names, with the Append rule.
// The first detail is the error record; then one for each other argument,
// in their order, at most one for each argument.
@(private = "file")
error_details_write :: proc "contextless" (process: ^Process, operation: op.Operation, v: [7]u64, first: errors.Error_Record) {
	place: op.Error_Details_Place
	place_address := v[op.ERROR_DETAILS_VALUE]
	if !read_user(process, place_address, &place, size_of(place)) {
		return // No table that the process can read: the completion holds the record.
	}
	details: [op.ERROR_DETAILS_MOST]errors.Error_Record
	details[0] = first
	count := 1
	for n in 0 ..< op.ERROR_DETAILS_VALUE {
		if i64(n + 1) == first.argument {
			continue
		}
		detail := errors.Error_Record{operation = i64(operation)}
		if argument_explain(&detail, process, operation, v, n) {
			details[count] = detail
			count += 1
		}
	}
	// The place is the copy above: the process can change its memory at any
	// time, and the kernel reads it once. A detail past the capacity is counted and not written: the Append
	// rule. A detail that fits and that the process cannot receive (its page
	// cannot be written, its address passes the end of the addresses) ends
	// the answer there: the count then names only the records written, so a
	// reader never takes old bytes for a detail.
	record_size := u64(size_of(errors.Error_Record))
	answered := u64(count)
	for &detail, number in details[:count] {
		at := place.count + u64(number)
		if at < place.count || at >= place.capacity {
			break
		}
		if at > (max(u64) - place.address) / record_size || !write_user(process, place.address + at * record_size, &detail, record_size) {
			answered = u64(number)
			break
		}
	}
	total := place.count + answered
	if total < place.count {
		total = max(u64) // The count stops at the largest number.
	}
	_ = write_user(process, place_address + u64(offset_of(op.Error_Details_Place, count)), &total, size_of(total))
}

// argument_explain says what is wrong with the argument n of an operation
// (from 0), from the checks that need no status: a handle, then the form
// of a count, a set of flags or a choice. It reads only the handles of the
// process and the values of the command: no fact of another process.
@(private = "file")
argument_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64, n: int) -> bool {
	if handle_argument_explain(record, process, operation, v, n) {
		return true
	}
	problem, limit := op.argument_value_problem(operation, n, v)
	if problem == .None {
		return false
	}
	record_set(record, problem, .None, n + 1, v[n], limit, 0)
	return true
}

// write_user copies to memory of the process that runs, if it can write it.
// Lock: the process lock: no unmap runs between user_range and the copy.
@(private = "file")
write_user :: proc "contextless" (process: ^Process, address: u64, source: rawptr, size: u64) -> bool {
	at, taken := caller_lock(process)
	defer process_unlock(at, taken)
	if !user_range(process, address, size, true) {
		return false
	}
	user_copy_to_process(address, source, size)
	return true
}

// handle_explain says what is wrong with a handle that an operation needs
// of a kind (None: any kind) with rights. false: the handle is good.
@(private = "file")
handle_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, argument: int, handle: u64, kind: Object_Kind, rights: op.Rights, check_rights := true) -> bool {
	index := handle & 0xFFFF
	generation := handle >> 16
	if index == 0 || index >= HANDLE_CAPACITY || generation > 0xFFFF {
		record_set(record, .Handle_Absent, .None, argument, handle, 0, 0)
		return true
	}
	slot := read_handle(process, index)
	if slot.kind == .None || u64(slot.generation) != generation {
		switch {
		case slot.kind == .None && slot.generation == u16(generation + 1): // A close of generation 0xFFFF gives 0.
			record_set(record, .Handle_Ended, .None, argument, handle, 0, u64(slot.ended))
		case u64(slot.generation) > generation:
			record_set(record, .Handle_Ended, .None, argument, handle, 0, u64(errors.End.Unknown))
		case:
			record_set(record, .Handle_Absent, .None, argument, handle, 0, 0)
		}
		return true
	}
	if kind != .None && slot.kind != kind {
		record_set(record, .Handle_Kind, .None, argument, handle, u64(kind), u64(slot.kind))
		return true
	}
	if check_rights && !(rights <= slot.rights) {
		record_set(record, .Handle_Rights, .None, argument, handle, u64(transmute(u32)rights), u64(transmute(u32)slot.rights))
		return true
	}
	return false
}

@(private = "file")
handles_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64, check_rights := true) -> bool {
	for n in 0 ..< len(v) {
		if handle_argument_explain(record, process, operation, v, n, check_rights) {
			return true
		}
	}
	return false
}

// handle_argument_explain says what is wrong with the handle argument n of
// an operation (from 0), with the kind and the rights that the operation
// needs of it, which can depend on the other arguments. false: the argument
// is not a handle, or the handle is good.
@(private = "file")
handle_argument_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64, n: int, check_rights := true) -> bool {
	// The payer of a commit: a handle of the budget of the object, with
	// Commit or Spend. The record says nothing of a budget that is not the
	// payer: a process sees only what its handles let it see.
	if operation == .Memory_Commit && n == 1 && transmute(op.Commit_Flags)v[4] & {.Decommit} == {} {
		if v[1] == 0 {
			record_set(record, .Handle_Absent, .None, 2, 0, 0, 0)
			return true
		}
		if handle_explain(record, process, 2, v[1], .Budget, {}, check_rights = false) {
			return true
		}
		slot, found := read_handle_find(process, v[1], .Budget)
		if !found {
			return false
		}
		if check_rights && slot.rights & {.Commit, .Spend} == {} {
			record_set(record, .Handle_Rights, .None, 2, v[1], u64(transmute(u32)op.Rights{.Commit}), u64(transmute(u32)slot.rights))
			return true
		}
		if memory, held := read_handle_find(process, v[0], .Memory); held && !read_pays_for(slot.object, memory.object) {
			record_set(record, .Not_Payer, .None, 2, v[1], 0, 0)
			return true
		}
		return false
	}
	// Record_Start and Replay_Start pass the history memory handle in v[1]
	// (parameter `number`, whose generic form is Value).
	if operation == .Thread_Control && n == 1 {
		if command, command_known := enum_word.member_of_word(op.Thread_Control_Command, v[2]); command_known && (command == .Record_Start || command == .Replay_Start) {
			return handle_explain(record, process, 2, v[1], .Memory, {.Read, .Write}, check_rights)
		}
	}
	// A handle that the operation does not read with these values names no
	// fault: the budget of a decommit, the thread of a command out of range.
	parameter := op.OPERATIONS[operation].parameters[n]
	if parameter.form != .Handle && parameter.form != .Handle_Or_Zero || !op.argument_is_read(operation, n, v) {
		return false
	}
	rights := parameter.rights
	kind := parameter.kind
	// An open choice by design: of the many operations, this diagnosis names
	// the few that give its status; each other one has no explanation here.
	#partial switch operation {
	case .Memory_Map:
		if n == 0 {
			flags := transmute(op.Map_Flags)v[3]
			if .Write in flags {
				rights += {.Write}
			}
			if .Execute in flags {
				rights += {.Execute}
			}
		}
	case .Handle_Give:
		if n == 1 && v[0] == 0 {
			rights = {} // A copy in this process needs no Give.
		}
		if n == 0 {
			// The target: a process with Control, or a memory object.
			slot, found := read_handle_find(process, v[0], .None)
			if found && slot.kind == .Process {
				rights = {.Control}
			} else if found && slot.kind != .Memory {
				kind = .Process
			}
		}
	case .Thread_Control:
		// The right depends on the command: Write for a write of the
		// registers, Control for a write of the schedule or of the
		// placement. A command of the schedule or of the placement
		// also takes the machine handle, with Schedule and Inspect.
		if command, command_known := enum_word.member_of_word(op.Thread_Control_Command, v[2]); n == 0 && command_known {
			rights = op.thread_control_rights(command)
			machine_rights, by_machine_number := op.thread_control_machine_rights(command)
			if op.thread_control_names_a_process(command) {
				// The schedule of a process: the machine handle only,
				// so each other handle is explained as a handle of the
				// wrong kind.
				kind, rights = .Machine, machine_rights
			} else if op.thread_control_counts_the_caller(command) {
				// The thread counters: the machine handle with Counters
				// only.
				kind, rights = .Machine, op.THREAD_COUNTERS_RIGHTS
			} else if op.thread_control_records_a_process(command) {
				// Record and replay take a process handle with Debug.
				kind, rights = .Process, {.Debug}
			} else if slot, found := read_handle_find(process, v[0], .None); found && slot.kind == .Machine && by_machine_number {
				kind, rights = .Machine, machine_rights
			} else if op.thread_control_needs_the_debugger(command) || found && slot.kind == .Process && op.thread_control_takes_debug_handle(command) {
				// The debugger of a process names a thread by the
				// process handle with Debug.
				kind, rights = .Process, {.Debug}
			}
		}
	}
	return handle_explain(record, process, n + 1, v[n], kind, rights, check_rights)
}

// read_pays_for says if a budget pays for a memory object now.
read_pays_for :: proc "contextless" (budget: u32, region: u32) -> bool {
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	return regions[region].budget == budget
}

// memory_create_cost gives the pages that a Memory_Create with these pages
// and flags takes from its budget: the kinds of the object as execute reads
// them from the flags (a Large_Pages object is contiguous), and the cost
// that region_create charges for that kind.
@(private = "file")
memory_create_cost :: proc "contextless" (page_count: u64, flags_word: u64) -> u64 {
	flags := transmute(op.Memory_Flags)flags_word
	return region_create_cost(page_count, contiguous = .Contiguous in flags || .Large_Pages in flags, uncommitted = .Uncommitted in flags)
}

// budget_explain gives what an operation asks of a budget, and what the
// budget holds of it.
@(private = "file")
budget_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64) -> bool {
	if operation == .Log {
		// The limit of the budget of the process. Its counts only with a
		// handle with Read, so that a process without it learns nothing of
		// another process. Only that budget counts the record: when it is
		// not over its limit now, a new second started, a budget that came
		// from it ended, or the text took more records than were left, and
		// the record is Refused.
		logged, limit, held := read_log_count(process)
		if !held {
			record_set(record, .Budget_Hidden, .Log_Records, 0, 0, 1, 0)
			return true
		}
		if logged < limit {
			return false
		}
		record_set(record, .Over_Limit, .Log_Records, 0, logged + 1, limit, 0)
		return true
	}
	if operation == .Memory_Commit {
		// The pages that the table asks against what the budget holds; what
		// it holds only with the right Read on the budget handle.
		needed, pages, held := read_commit_needed(process, v[0], v[2], v[3])
		if !held || needed <= pages {
			return false
		}
		if budget, found := read_handle_find(process, v[1], .Budget); found && .Read not_in budget.rights {
			record_set(record, .Budget_Hidden, .Pages, 2, v[1], needed, 0)
			return true
		}
		record_set(record, .Budget, .Pages, 2, v[1], needed, pages)
		return true
	}
	if operation != .Memory_Create && operation != .Process_Create && operation != .Thread_Create && operation != .Budget_Create {
		return false
	}
	holds, rights, found := read_budget(process, v[0], operation)
	if !found {
		return false
	}
	// Without Read the record depends on the operation alone, so that it
	// tells nothing of another process.
	if .Read not_in rights {
		// An open choice by design: of the many operations, this diagnosis names
		// the few that give its status; each other one has no explanation here.
		#partial switch operation {
		case .Memory_Create:
			record_set(record, .Budget_Hidden, .Pages, 1, v[0], memory_create_cost(v[1], v[2]), 0)
		case .Process_Create:
			record_set(record, .Budget_Hidden, .Processes, 1, v[0], 1, 0)
		case .Thread_Create:
			record_set(record, .Budget_Hidden, .Threads, 1, v[0], 1, 0)
		case .Budget_Create:
			record_set(record, .Budget_Hidden, .None, 1, v[0], 0, 0)
		}
		return true
	}
	unit: errors.Unit
	asked, held: u64
	argument := 1
	// An open choice by design: of the many operations, this diagnosis names
	// the few that give its status; each other one has no explanation here.
	#partial switch operation {
	case .Memory_Create:
		unit, asked, held = .Pages, memory_create_cost(v[1], v[2]), holds.pages
	case .Process_Create:
		unit, asked, held = .Processes, 1, holds.processes
		if holds.processes != 0 {
			// The top table, the own log ring, and the tables of the time page.
			unit, asked, held = .Pages, 1 + op.OWN_LOG_PAGES + TIME_PAGE_TABLES, holds.pages
		}
	case .Thread_Create:
		unit, asked, held = .Threads, 1, holds.threads
		if holds.threads != 0 {
			unit, asked, held = .Pages, 1 + ring.PAGE_COUNT, holds.pages // The thread area.
		}
	case .Thread_Control:
		// A wait room: its pages, before the pages of the room that it
		// replaces return.
		if v[2] != u64(op.Thread_Control_Command.Wait_Room) {
			return false
		}
		unit, asked, held, argument = .Pages, op.wait_room_pages(v[4]), holds.pages, 5
	case .Budget_Create:
		amounts := [5]u64{holds.pages, holds.processes, holds.threads, holds.processor, holds.log_records}
		units := [5]errors.Unit{.Pages, .Processes, .Threads, .Processor, .Log_Records}
		for amount, n in amounts {
			if v[n + 1] > amount {
				argument, unit, asked, held = n + 2, units[n], v[n + 1], amount
				break
			}
		}
	}
	// The cause is gone: the budget can pay now.
	if asked <= held {
		return false
	}
	record_set(record, .Budget, unit, argument, v[0], asked, held)
	return true
}

@(private = "file", rodata)
INSPECT_SIZES := [op.Inspect_Kind]u64 {
	.None      = 0,
	.System    = size_of(op.System_Report),
	.Process   = size_of(op.Process_Report),
	.Processor = size_of(op.Processor_Report),
	.Boot      = size_of(op.Boot_Report),
	.Mappings  = size_of(op.Mapping_Report),
	.Modules   = size_of(op.Module_Report),
	.Process_Mappings = size_of(op.Process_Mapping_Report),
	.Threads   = size_of(op.Thread_Table_Report),
	.Stop      = size_of(op.Stop_Report),
	.Pages     = size_of(op.Page_Report),
}

@(private = "file")
address_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64) -> bool {
	// An open choice by design: of the many operations, this diagnosis names
	// the few that give its status; each other one has no explanation here.
	#partial switch operation {
	case .Log:
		// A fact: its length is between its head and its whole record.
		if record_form, record_form_known := enum_word.member_of_word(op.Log_Record_Form, v[5]); record_form_known && record_form == .Fact {
			if v[2] < op.LOG_FACT_HEAD_BYTES {
				record_set(record, .Too_Small, .Bytes, 3, v[2], op.LOG_FACT_HEAD_BYTES, 0)
			} else if v[2] > op.LOG_FACT_CALL_BYTES_MOST {
				record_set(record, .Too_Long, .Bytes, 3, v[2], op.LOG_FACT_CALL_BYTES_MOST, 0)
			} else if !read_range(process, v[1], v[2]) {
				record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2], 0)
			} else {
				return false
			}
			return true
		}
		// The text, then its value runs, at the address.
		if v[2] > op.LOG_TEXT_BYTES_MOST {
			record_set(record, .Too_Long, .Bytes, 3, v[2], op.LOG_TEXT_BYTES_MOST, 0)
		} else if v[4] <= op.LOG_CALL_RUN_LIMIT && !read_range(process, v[1], v[2] + v[4] * size_of(value_kinds.Value_Run_In_Call)) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2] + v[4] * size_of(value_kinds.Value_Run_In_Call), 0)
		} else {
			return false
		}
	case .Process_Create:
		if v[2] > op.PROCESS_NAME_BYTES_MOST {
			record_set(record, .Too_Long, .Bytes, 3, v[2], op.PROCESS_NAME_BYTES_MOST, 0)
		} else if !read_range(process, v[1], v[2]) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], v[2], 0)
		} else {
			return false
		}
	case .Process_Stop:
		if v[2] == 0 || read_range(process, v[2], size_of(errors.Error_Record)) {
			return false
		}
		record_set(record, .Bad_Address, .Bytes, 3, v[2], size_of(errors.Error_Record), 0)
	case .Process_State:
		if read_range(process, v[1], size_of(op.Stop_Report), true) {
			return false
		}
		record_set(record, .Bad_Address, .Bytes, 2, v[1], size_of(op.Stop_Report), 1)
	case .Process_Module:
		module: op.Module_Record
		if !read_user(process, v[1], &module, size_of(module)) {
			record_set(record, .Bad_Address, .Bytes, 2, v[1], size_of(op.Module_Record), 0)
			return true
		}
		// The records of another process need its lock: no more detail.
		if v[0] != 0 {
			return false
		}
		missing, overlaps := read_module_problem(process, module)
		switch {
		case missing:
			record_set(record, .Absent, .Bytes, 2, module.base, 0, 0) // No record has this base.
		case overlaps:
			record_set(record, .Overlap, .Bytes, 2, module.base, module.size, 0)
		case:
			return false
		}
	case .Word_Wait:
		if !read_range(process, v[0], v[1] * size_of(op.Word)) {
			record_set(record, .Bad_Address, .Bytes, 1, v[0], v[1] * size_of(op.Word), 0)
			return true
		}
		for index in 0 ..< v[1] {
			word: op.Word
			if !read_user(process, v[0] + index * size_of(op.Word), &word, size_of(op.Word)) {
				return false // Unmapped since: the cause is not known now.
			}
			if !read_word(process, word.address) {
				// found 2: the word is in device memory, which no wait takes.
				record_set(record, .Bad_Address, .Bytes, 1, word.address, 4, read_device_word(process, word.address) ? 2 : 0)
				return true
			}
		}
		return false
	case .Word_Wake:
		// A wake needs Write on its word: found is 1 for a word that the
		// process can read and not write, 2 for a word of device memory.
		if read_word(process, v[0], write = true) {
			return false
		}
		found := u64(read_word(process, v[0]))
		if read_device_word(process, v[0]) {
			found = 2
		}
		record_set(record, .Bad_Address, .Bytes, 1, v[0], 4, found)
	case .Inspect:
		size: u64
		if kind, kind_known := enum_word.member_of_word(op.Inspect_Kind, v[1]); kind_known {
			size = INSPECT_SIZES[kind]
		}
		if v[4] < size {
			record_set(record, .Too_Small, .Bytes, 5, v[4], size, 0)
		} else if !read_range(process, v[3], size, true) {
			record_set(record, .Bad_Address, .Bytes, 4, v[3], size, 1)
		} else {
			return false
		}
	case .Memory_Map:
		page_count, found := read_memory_pages(process, v[0])
		if !found {
			return false
		}
		count := v[5] == 0 && v[4] < page_count ? page_count - v[4] : v[5]
		switch {
		case v[4] >= page_count:
			record_set(record, .Too_Long, .Pages, 5, v[4], page_count - 1, 0)
		case count > page_count - v[4]:
			record_set(record, .Too_Long, .Pages, 6, count, page_count - v[4], 0)
		case v[2] != 0 && (v[2] % PAGE_SIZE != 0 || v[2] < PAGE_SIZE || v[2] >= USER_END || count * PAGE_SIZE > USER_END - v[2]):
			record_set(record, .Bad_Address, .Bytes, 3, v[2], count * PAGE_SIZE, 0)
		case v[2] != 0 && v[1] == 0 && read_overlaps(process, v[2], count * PAGE_SIZE):
			record_set(record, .Overlap, .Bytes, 3, v[2], count * PAGE_SIZE, 0) // The addresses of another mapping.
		case:
			return false // In another process, whose mappings need its lock, or the overlap is gone.
		}
	case .Memory_Commit:
		// The first range that is not in the object, or not after the one before.
		pages, found := read_memory_pages(process, v[0])
		if !found || !read_range(process, v[2], v[3] * size_of(op.Page_Range)) {
			return false
		}
		end: u64
		for index in 0 ..< v[3] {
			range: op.Page_Range
			if !read_user(process, v[2] + index * size_of(op.Page_Range), &range, size_of(range)) {
				return false
			}
			switch {
			case range.page_count == 0:
				record_set(record, .Too_Small, .Pages, 3, 0, 1, index)
				return true
			case range.first >= pages || range.page_count > pages - range.first:
				record_set(record, .Too_Long, .Pages, 3, range.first + range.page_count, pages, index)
				return true
			case range.first < end:
				record_set(record, .Overlap, .Pages, 3, range.first, end, index)
				return true
			}
			end = range.first + range.page_count
		}
		return false
	case .Memory_Protect:
		// The first range that is not inside one mapping of this process, or
		// a part of a mapping that changes only whole. The mappings of a
		// guest are not read here: the diagnosis holds the lock of the
		// caller only.
		if v[3] != 0 || !read_range(process, v[0], v[1] * size_of(op.Address_Range)) {
			return false
		}
		for index in 0 ..< v[1] {
			range: op.Address_Range
			if !read_user(process, v[0] + index * size_of(op.Address_Range), &range, size_of(range)) {
				return false
			}
			covered, whole_only := read_protect_range(process, range.address, range.page_count)
			if range.address % PAGE_SIZE != 0 || range.page_count == 0 || !covered {
				record_set(record, .Absent, .Bytes, 1, range.address, range.page_count * PAGE_SIZE, index)
				return true
			}
			if whole_only {
				record_set(record, .Whole_Only, .Bytes, 1, range.address, range.page_count * PAGE_SIZE, index)
				return true
			}
		}
		return false
	case .Memory_Unmap:
		if _, found := read_mapping_at(process, v[1]); v[0] != 0 || found {
			return false
		}
		record_set(record, .Absent, .Bytes, 2, v[1], 0, 0) // No mapping starts at this address.
	case .Guest_Run:
		// The registers record, which the kernel reads and writes.
		if read_range(process, v[1], size_of(op.Guest_Registers), true) {
			return false
		}
		record_set(record, .Bad_Address, .Bytes, 2, v[1], size_of(op.Guest_Registers), 1)
	case:
		return false
	}
	return true
}

// starter_module_explain names the module record of the starter that a
// process changed in itself, or mapped or unmapped over (No_Right after the
// handles are good). The record is read again under the process lock; it
// names the record only when the range of the call meets it now. A handle
// that names the caller itself, and an address that the kernel chooses,
// give Refused: the first needs the handle read again, and the second never
// meets such a record.
@(private = "file")
starter_module_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64) -> bool {
	address, size: u64
	argument := 0
	// An open choice by design: of the many operations, this diagnosis names
	// the few that give its status; each other one has no explanation here.
	#partial switch operation {
	case .Process_Module:
		if v[0] != 0 {
			return false
		}
		module: op.Module_Record
		if !read_user(process, v[1], &module, size_of(module)) {
			return false
		}
		// The refusal names the record of the same base: one byte finds it.
		address, size, argument = module.base, 1, 2
	case .Memory_Map:
		if v[1] != 0 || v[2] == 0 {
			return false
		}
		page_count, found := read_memory_pages(process, v[0])
		if !found || v[4] >= page_count {
			return false
		}
		count := v[5] == 0 ? page_count - v[4] : v[5]
		if count > page_count - v[4] {
			return false
		}
		address, size, argument = v[2], count * PAGE_SIZE, 3
	case .Memory_Unmap:
		if v[0] != 0 {
			return false
		}
		page_count, found := read_mapping_at(process, v[1])
		if !found {
			return false
		}
		address, size, argument = v[1], page_count * PAGE_SIZE, 2
	case:
		return false
	}
	starter_record, meets := read_starter_module(process, address, size)
	if !meets || operation == .Process_Module && starter_record.base != address {
		return false
	}
	record_set(record, .Starter_Module, .Bytes, argument, address, starter_record.base, starter_record.size)
	return true
}

// slot_explain names the full table that refused, only when the table is
// full now and it is the one cause that the state shows; else Refused.
@(private = "file")
slot_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64, outcome: call_outcome.Call_Outcome) -> bool {
	if outcome == .Budget_Or_Capacity_Exhausted {
		mappings, modules, areas := read_own_full(process)
		#partial switch operation {
		case .Word_Wait:
			// The words of this entry count too: only a list longer than the
			// room of the calling thread is one cause that the record can name.
			// The diagnosis runs in the entry of that thread, on its processor.
			capacity := u64(wait_capacity(&threads[processor_self().current]))
			if v[1] <= capacity {
				return false
			}
			record_set(record, .Over_Limit, .Words, 2, v[1], capacity, 0)
			return true
		case .Memory_Map:
			if v[1] != 0 || !mappings {
				return false
			}
			record_set(record, .Full, .Mappings, 0, 0, MAPPING_CAPACITY, 0)
			return true
		case .Process_Module:
			if v[0] != 0 || !modules {
				return false
			}
			record_set(record, .Full, .Modules, 0, 0, op.PROCESS_MODULE_CAPACITY, 0)
			return true
		case .Handle_Give:
			// The one cause of capacity exhaustion here: the handle table of the target.
			record_set(record, .Full, .Handles, 1, v[0], HANDLE_CAPACITY - 1, 0)
			return true
		}
		// The new handle goes in the table of the caller.
		if operation != .Process_Start && read_free_handles(process) == 0 {
			record_set(record, .Full, .Handles, 0, 0, HANDLE_CAPACITY - 1, 0)
			return true
		}
		if operation == .Thread_Create {
			switch {
			case areas:
				record_set(record, .Full, .Threads, 0, 0, op.THREAD_CAPACITY, 0)
				return true
			case mappings:
				record_set(record, .Full, .Mappings, 0, 0, MAPPING_CAPACITY, 0)
				return true
			}
		}
		return false
	}
	// Shared tables of the machine (Callee_Busy).
	// A table of the machine is named only where it is the one cause that
	// the outcome leaves, and its lock is taken only for that operation.
	#partial switch operation {
	case .Memory_Physical:
		// It makes no handle. The device windows are named only when the
		// object needs one and none is free: a requester past the slots is
		// another cause, and stays Refused.
		slot, found := read_handle_find(process, v[1], .Memory)
		if !found || !iommu_windows_wanted(slot.object) {
			return false
		}
		record_set(record, .Full, .Device_Windows, 0, 0, u64(IOMMU_WINDOW_CAPACITY) - 1, 0)
	case .Memory_Create:
		if !read_regions_full() {
			return false
		}
		record_set(record, .Full, .Memory, 0, 0, u64(region_capacity) - 1, 0)
	case .Process_Create:
		if !read_machine_full().processes {
			return false
		}
		record_set(record, .Full, .Processes, 0, 0, u64(process_capacity) - 1, 0)
	case .Budget_Create:
		if !read_machine_full().budgets {
			return false
		}
		record_set(record, .Full, .Budgets, 0, 0, BUDGET_CAPACITY - 1, 0)
	case .Device_Create:
		device_kind, device_kind_known := enum_word.member_of_word(op.Device_Kind, v[1])
		switch {
		case !device_kind_known:
			return false
		case device_kind == .Message && read_machine_full().messages:
			record_set(record, .Full, .Interrupts, 0, 0, op.MESSAGE_CAPACITY, 0)
		case (device_kind == .Memory || device_kind == .Display_Memory) && read_regions_full():
			record_set(record, .Full, .Memory, 0, 0, u64(region_capacity) - 1, 0)
		case:
			return false
		}
	case:
		return false
	}
	return true
}

@(private = "file")
state_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64) -> bool {
	argument := 0
	// An open choice by design: of the many operations, this diagnosis names
	// the few that give its status; each other one has no explanation here.
	#partial switch operation {
	case .Memory_Map, .Handle_Give:
		// An object with pages of their own protection is not mapped again
		// and not given: the marks would reach the other mapping.
		memory_argument := operation == .Memory_Map ? 0 : 1
		// A target process that stopped is the cause first; the marks after.
		if operation == .Memory_Map && v[1] != 0 {
			if _, state, held := read_process_state(process, v[1]); held && (state == .Stopped || state == .None) {
				record_set(record, .State, .None, 2, v[1], 0, u64(state))
				return true
			}
		}
		if marked := read_marked_pages(process, v[memory_argument]); marked != 0 {
			record_set(record, .Object_Marked, .Pages, memory_argument + 1, v[memory_argument], 0, marked)
			return true
		}
		// Device memory whose frames a live mapping of another cache type
		// covers: the object is shared with that mapping.
		if operation == .Memory_Map && read_device_cache_conflict(process, v[0], transmute(op.Map_Flags)v[3]) {
			record_set(record, .Object_Shared, .None, 1, v[0], 0, 0)
			return true
		}
		argument = operation == .Memory_Map ? 2 : 1
	case .Memory_Unmap, .Process_Start, .Process_Module, .Guest_Run:
		argument = 1
	case .Memory_Commit:
		// A decommit needs an object that only this process names.
		record_set(record, .Object_Shared, .None, 1, v[0], 0, 0)
		return true
	case .Memory_Protect:
		// A part of a mapping needs an object that only this process names.
		// For a guest, the state of the guest can be the cause too: no
		// record names one of the two.
		if v[3] != 0 {
			return false
		}
		record_set(record, .Object_Shared, .None, 1, 0, 0, 0)
		return true
	case .Thread_Control:
		// The state refusal that Thread_Control recorded on this processor
		// before it returned Bad_State.
		operation_facts := &processor_self().operation
		if state_record, ok := op.thread_control_state_error(
			operation_facts.thread_state_refusal,
			operation_facts.thread_state_refused_argument,
			operation_facts.thread_state_refused_value,
			operation_facts.thread_state_refused_limit,
			operation_facts.thread_state_refused_found,
		); ok {
			record^ = state_record
			return true
		}
		return false
	case:
		return false
	}
	handle := v[argument - 1]
	if handle == 0 {
		return false
	}
	_, state, held := read_process_state(process, handle)
	if !held {
		return false
	}
	found := u64(state)
	limit := operation == .Process_Start ? u64(op.Process_State.Created) : 0
	record_set(record, .State, .None, argument, handle, limit, found)
	return true
}

@(private = "file")
value_explain :: proc "contextless" (record: ^errors.Error_Record, process: ^Process, operation: op.Operation, v: [7]u64) -> bool {
	form := &op.OPERATIONS[operation]
	// An open choice by design: of the many operations, this diagnosis names
	// the few that give its status; each other one has no explanation here.
	#partial switch operation {
	case .Word_Wait:
		if v[1] > op.WORD_WAIT_MOST {
			record_set(record, .Too_Long, .Words, 2, v[1], op.WORD_WAIT_MOST, 0)
			return true
		}
		// A word that the entry holds already: the value is its place in
		// the whole command.
		if facts := &processor_self().operation; facts.word_wait_duplicate {
			record_set(record, .Bad_Value, .Words, 1, facts.word_wait_refused_place, 0, 0)
			return true
		}
	case .Events_Set:
		if v[1] != 0 && v[3] > op.EVENT_RULE_CAPACITY {
			record_set(record, .Too_Long, .Records, 4, v[3], op.EVENT_RULE_CAPACITY, 0)
			return true
		}
	case .Log:
		// A fact has no value runs: its values are not text. Its bound is 0,
		// whatever the count, so this check comes first.
		if record_form, record_form_known := enum_word.member_of_word(op.Log_Record_Form, v[5]); record_form_known && record_form == .Fact && v[4] != 0 {
			record_set(record, .Too_Long, .Records, 5, v[4], 0, 0)
			return true
		}
		if v[4] > op.LOG_CALL_RUN_LIMIT {
			record_set(record, .Too_Long, .Records, 5, v[4], op.LOG_CALL_RUN_LIMIT, 0)
			return true
		}
	case .Inspect:
		if kind, kind_known := enum_word.member_of_word(op.Inspect_Kind, v[1]); !kind_known || kind != .Pages {
			break
		}
		page_report: op.Page_Report
		switch {
		case v[2] != 0:
			// Pages gives the pages of the process that asks only: index 0.
			record_set(record, .Bad_Value, .None, 3, v[2], 0, 0)
			return true
		case v[4] >= size_of(op.Page_Report) && read_user(process, v[3], &page_report, size_of(page_report)) && (page_report.address & (PAGE_SIZE - 1) != 0 || page_report.address >= USER_END || op.PAGE_REPORT_CAPACITY * PAGE_SIZE > USER_END - page_report.address):
			// The first page that the report at the argument address names:
			// aligned, and its 64 pages in the user half. The record gives that
			// first page, and the last first page that the call takes.
			record_set(record, .Bad_Value, .None, 4, page_report.address, USER_END - op.PAGE_REPORT_CAPACITY * PAGE_SIZE, 0)
			return true
		}
	case .Memory_Create:
		flags := transmute(op.Memory_Flags)v[2]
		switch {
		case v[2] & ~op.MEMORY_FLAGS_KNOWN != 0:
			record_set(record, .Bad_Flags, .None, 3, v[2], op.MEMORY_FLAGS_KNOWN, 0)
			return true
		case .Uncommitted in flags && flags != {.Uncommitted}:
			record_set(record, .Bad_Flags, .None, 3, v[2], 1 << u64(op.Memory_Flag.Uncommitted), 0) // Uncommitted goes alone.
			return true
		case .Large_Pages in flags && v[1] % op.LARGE_PAGE_PAGES != 0:
			record_set(record, .Not_Multiple, .Pages, 2, v[1], op.LARGE_PAGE_PAGES, v[1] % op.LARGE_PAGE_PAGES) // Whole large pages of 512 pages.
			return true
		case v[1] == 0:
			record_set(record, .Too_Small, .Pages, 2, 0, 1, 0)
			return true
		case v[1] > op.MEMORY_PAGE_LIMIT:
			record_set(record, .Too_Long, .Pages, 2, v[1], op.MEMORY_PAGE_LIMIT, 0)
			return true
		}
	case .Memory_Map:
		if v[3] & ~op.MAP_FLAGS_KNOWN != 0 {
			record_set(record, .Bad_Flags, .None, 4, v[3], op.MAP_FLAGS_KNOWN, 0)
			return true
		}
		flags := transmute(op.Map_Flags)v[3]
		_, uncached, info_ok := read_memory_info(process, v[0])
		if (.Write in flags && .Execute in flags && .No_Access not_in flags) || (info_ok && op.map_write_combining_refused(flags, uncached)) {
			record_set(record, .Bad_Value, .None, 4, v[3], 0, 0)
			return true
		}
	case .Memory_Commit:
		switch {
		case v[3] == 0:
			record_set(record, .Too_Small, .Records, 4, 0, 1, 0)
			return true
		case v[3] > op.RANGE_TABLE_CAPACITY:
			record_set(record, .Too_Long, .Records, 4, v[3], op.RANGE_TABLE_CAPACITY, 0)
			return true
		case v[4] & ~op.COMMIT_FLAGS_KNOWN != 0:
			record_set(record, .Bad_Flags, .None, 5, v[4], op.COMMIT_FLAGS_KNOWN, 0)
			return true
		}
		if pages := read_table_pages(process, v[2], v[3], size_of(op.Page_Range), offset_of(op.Page_Range, page_count)); pages > op.RANGE_TABLE_PAGE_LIMIT {
			record_set(record, .Too_Long, .Pages, 3, pages, op.RANGE_TABLE_PAGE_LIMIT, 0)
			return true
		}
		if uncommitted, _, info_ok := read_memory_info(process, v[0]); info_ok && !uncommitted {
			record_set(record, .Bad_Value, .None, 1, v[0], 0, 0) // The memory object was not made Uncommitted.
			return true
		}
	case .Memory_Protect:
		switch {
		case v[1] == 0:
			record_set(record, .Too_Small, .Records, 2, 0, 1, 0)
			return true
		case v[1] > op.RANGE_TABLE_CAPACITY:
			record_set(record, .Too_Long, .Records, 2, v[1], op.RANGE_TABLE_CAPACITY, 0)
			return true
		case v[2] & ~op.PROTECT_FLAGS_KNOWN != 0:
			record_set(record, .Bad_Flags, .None, 3, v[2], op.PROTECT_FLAGS_KNOWN, 0)
			return true
		}
		if pages := read_protect_walk(process, v[0], v[1]); v[3] == 0 && pages > op.RANGE_TABLE_PAGE_LIMIT {
			record_set(record, .Too_Long, .Pages, 1, pages, op.RANGE_TABLE_PAGE_LIMIT, 0)
			return true
		}
		flags := transmute(op.Map_Flags)v[2]
		if (.Write in flags && .Execute in flags) || (.No_Access in flags && flags != {.No_Access}) || (v[3] == 0 && read_protect_rights_refused(process, v[0], v[1], flags)) {
			record_set(record, .Bad_Value, .None, 3, v[2], 0, 0)
			return true
		}
	case .Thread_Control:
		// A refused write: the value and the part that the check refused, as
		// the operation kept them on this processor from its own copy.
		if operation_facts := &processor_self().operation; operation_facts.thread_write_refusal != .None {
			record_set(record, .Bad_Value, .None, 4, operation_facts.thread_write_refused_value, operation_facts.thread_write_refused_limit, u64(operation_facts.thread_write_refusal))
			return true
		}
		// A read of the memory of a process of more bytes than one read
		// takes.
		if v[2] == u64(op.Thread_Control_Command.Read_Memory) && v[4] > op.THREAD_MEMORY_READ_LIMIT {
			record_set(record, .Bad_Value, .None, 5, v[4], op.THREAD_MEMORY_READ_LIMIT, 0)
			return true
		}
		// A wait room of more words than a wait holds, or one that names a
		// thread: a room serves the calling thread only.
		if v[2] == u64(op.Thread_Control_Command.Wait_Room) {
			switch {
			case v[4] > op.WORD_WAIT_MOST:
				record_set(record, .Too_Long, .Words, 5, v[4], op.WORD_WAIT_MOST, 0)
				return true
			case v[0] != 0:
				record_set(record, .Bad_Value, .None, 1, v[0], 0, 0)
				return true
			case v[1] != 0:
				record_set(record, .Bad_Value, .None, 2, v[1], 0, 0)
				return true
			}
		}
	case .Fault_Handler_Set:
		action, action_known := enum_word.member_of_word(op.Fault_Handler_Action, v[1])
		switch {
		case !action_known:
			record_set(record, .Bad_Value, .None, 2, v[1], u64(max(op.Fault_Handler_Action)), 0)
			return true
		case action == .End && v[2] != 0:
			record_set(record, .Bad_Flags, .None, 3, v[2], 0, 0) // The end of the delivery takes no kinds.
			return true
		case v[3] != 0:
			if _, debugger_known := op.fault_kinds_of_debugger_argument(v[2]); !debugger_known {
				record_set(record, .Bad_Flags, .None, 3, v[2], op.FAULT_KINDS_DEBUGGER, 0) // The debugger of a process takes the two traps only.
				return true
			}
		case:
			if _, kinds_known := op.fault_kinds_of_argument(v[2]); !kinds_known {
				record_set(record, .Bad_Flags, .None, 3, v[2], op.FAULT_KINDS_DELIVERED, 0)
				return true
			}
		}
	case .Guest_Run:
		// A field of the registers record that its rules refuse: the value
		// of that field. The process can change its memory since the run:
		// this read is of the record now.
		registers: op.Guest_Registers
		if read_user(process, v[1], &registers, size_of(registers)) {
			value: u64
			_, refusal := op.guest_registers_check(registers)
			switch refusal {
			case .None:
				return false
			case .Flags:
				value = registers.rflags
			case .Control_0:
				value = registers.cr0
			case .Control_3:
				value = registers.cr3
			case .Control_4:
				value = registers.cr4
			case .Efer, .Long_Mode:
				value = registers.efer
			case .Instruction_Address:
				value = registers.rip
			case .Mode_Load:
				value = u64(registers.mode_load)
			case .Inject_Kind:
				value = u64(registers.inject_kind)
			case .Inject_Vector:
				value = u64(registers.inject_vector)
			case .Inject_Error_Code:
				value = u64(registers.inject_error_code)
			case .Reserved:
				value = u64(registers.reserved[0]) | u64(registers.reserved[1]) << 8
			case .Interrupt_Shadow:
				value = u64(registers.interrupt_shadow)
			case .Event_Pending:
				value = u64(registers.event_pending)
			case .Inject_In_Interrupt_Shadow:
				// The event that the shadow refuses: the kind, not the shadow,
				// is what the process changes.
				value = u64(registers.inject_kind)
			case .System_Call_Address:
				value = registers.lstar
			case .System_Call_Mask:
				value = registers.sfmask
			case .Segment_Base:
				// The first base that is not canonical, in the order of the record.
				five_level := registers.cr4 & op.GUEST_CONTROL_4_FIVE_LEVEL_PAGING != 0
				value = registers.kernel_gs_base
				if !op.guest_address_canonical(registers.fs_base, five_level) {
					value = registers.fs_base
				} else if !op.guest_address_canonical(registers.gs_base, five_level) {
					value = registers.gs_base
				}
			}
			record_set(record, .Bad_Value, .None, 2, value, 0, 0)
			return true
		}
	case .Device_Create:
		// Display_Memory over a range of device memory that does not hold
		// the framebuffer of the firmware: the record gives the address
		// and, as its limit, the address of that framebuffer.
		if device_kind, device_kind_known := enum_word.member_of_word(op.Device_Kind, v[1]); device_kind_known && device_kind == .Display_Memory && device_range(v[2], v[3]) && !display_memory_range(v[2], v[3]) {
			record_set(record, .Bad_Value, .None, 3, v[2], boot_record.framebuffer.address, 0)
			return true
		}
	case .Process_Stop:
		// An outcome word that the target does not take: the limit is the
		// largest member for a stop of the caller, and 0 for a stop of
		// another process.
		itself := v[0] == 0
		if !itself {
			slot, held := read_handle_find(process, v[0], .Process, {.Control})
			if !held {
				return false
			}
			itself = &processes[slot.object] == process
		}
		outcome, limit, known := op.stop_outcome_of_operation_word(v[1], itself)
		if !known {
			record_set(record, .Bad_Value, .None, 2, v[1], limit, 0)
			return true
		}
		if !op.stop_error_address_allowed(itself, outcome, v[2]) {
			record_set(record, .Bad_Value, .None, 3, v[2], 0, 0)
			return true
		}
		if v[2] != 0 {
			stop_error: errors.Error_Record
			if read_user(process, v[2], &stop_error, size_of(stop_error)) {
				if kind, kind_ok := errors.kind_of_word(stop_error.kind); !kind_ok || kind == .None {
					record_set(record, .Bad_Value, .None, 3, u64(stop_error.kind), u64(max(errors.Kind)), 0)
					return true
				}
				if _, unit_ok := errors.unit_of_word(stop_error.unit); !unit_ok {
					record_set(record, .Bad_Value, .None, 3, u64(stop_error.unit), u64(max(errors.Unit)), 0)
					return true
				}
			}
		}
	case .Machine_Stop:
		// A code that the host cannot receive whole.
		if v[1] > op.MACHINE_STOP_CODE_MOST {
			record_set(record, .Bad_Value, .None, 2, v[1], op.MACHINE_STOP_CODE_MOST, 0)
			return true
		}
	case .Fault_Answer:
		// The debugger of a process answers Resume only: the largest
		// answer that it gives.
		if v[3] != 0 && v[2] == u64(op.Fault_Answer_Kind.Stop) {
			record_set(record, .Bad_Value, .None, 3, v[2], u64(op.Fault_Answer_Kind.Resume), 0)
			return true
		}
	case .Thread_Create:
		// The most of a weight is the limit of a new thread of the calling
		// thread, which is the full weight unless the holder of the machine
		// lowered it: the value that the operation checked, kept on the
		// processor.
		weight_limit := u64(processor_self().operation.thread_create_weight_limit)
		switch {
		case v[4] > weight_limit:
			record_set(record, .Bad_Value, .None, 5, v[4], weight_limit, 0)
		case v[5] > op.REQUEST_LIMIT:
			record_set(record, .Bad_Value, .None, 6, v[5], op.REQUEST_LIMIT, 0)
		case:
			return false
		}
		return true
	}
	for parameter, n in form.parameters {
		if parameter.form == .Choice && (v[n] > parameter.limit || v[n] == 0 && operation != .Log) {
			record_set(record, .Bad_Value, .None, n + 1, v[n], parameter.limit, 0)
			return true
		}
	}
	return false
}

// stack_trace writes the stack trace of a thread that faulted: frame 0 is
// the instruction; each next frame is the return address that the frame
// pointer names. The process is the one of this processor: its page table
// is the one in use, so read_user reads its stack (the process lock). It
// runs on the path of the stop of a process on a fault.
stack_trace :: proc "contextless" (process: ^Process, frame: ^Frame, report: ^op.Stop_Report) {
	add :: proc "contextless" (process: ^Process, report: ^op.Stop_Report, address: u64) {
		item := &report.frames[report.frame_count]
		item.address = address
		if found := module_of(process, address); found != nil {
			item.base, item.hash = found.base, found.hash
		}
		report.frame_count += 1
	}
	report.frame_count = 0
	add(process, report, frame.rip)
	at := frame.rbp
	for report.frame_count < op.STOP_FRAME_CAPACITY {
		pair: [2]u64 // The frame pointer of the caller, then the return address.
		if at == 0 || at % 8 != 0 || !read_user(process, at, &pair, 16) {
			break
		}
		if pair[1] == 0 {
			break
		}
		add(process, report, pair[1])
		if pair[0] <= at {
			break
		}
		at = pair[0]
	}
}
