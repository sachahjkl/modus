// The system library: what a process uses to talk to the kernel and to other
// processes. It is compiled into each module. It allocates no hidden memory.
//
// Every process, every service and every module that calls the kernel
// imports it; the kernel does not. Each kernel operation has a procedure
// here that fills the command record, enters the kernel and gives the
// results and the `Status`; each one takes an optional
// `error: ^errors.Error_Record` as its last parameter, written only when the
// operation fails. The parts, by file:
//
// - `system.odin`: the kernel entry (`call`, `call_with_error`,
//   `commands_call`), the time,
//   the memory (`memory_create`, `memory_map`, `memory_commit`,
//   `memory_protect`), the handles (`give`, `handle_state`, `close`), the
//   rings (`ring_create`, `ring_open`), the threads (`thread_start`,
//   `thread_wait`, `thread_schedule_read`, `thread_schedule_write`,
//   `process_schedule_read`, `process_schedule_write`), the fault ring and the kernel events.
// - `wait.odin`: the waits on words and the queues with waits (`send`,
//   `receive`, `wait_begin`, `wait_end`).
// - `text.odin`, `log.odin`: the log of a process (`log`, `format`).
// - `load.odin`: the loader of modules and the start of processes
//   (`process_start`, `Module_Space`).
// - `calls.odin`, `service.odin`, `tables.odin`: the calls of exports, direct
//   and isolated, and the side of a service.
// - `grants.odin`: the commands of the root ring and the grants of a process.
// - `lock.odin`: a lock between the threads of one process.
//
// See [kernel operation](term:kernel-operation) and
// (docs/ARCHITECTURE.md, "U9. Base library").
package system

import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "base:intrinsics"

// The names of the contract that a process uses most, so that it writes
// `system.Handle` and imports no contract package for them.
Handle :: op.Handle
Status :: op.Status // The status of a kernel operation: `op.Status`.
Right :: op.Right
Rights :: op.Rights
Budget_Amounts :: op.Budget_Amounts
Context :: op.Context
PAGE_SIZE :: op.PAGE_SIZE
WAIT_FOREVER :: op.WAIT_FOREVER

// The procedures in assembly of `runtime`: the instructions that Odin does
// not give.
foreign _ {
	// system_enter is the `syscall` instruction: the kernel executes the
	// commands of the kernel ring, then waits until `wait` when it is not 0,
	// and gives the time. Call `enter`, which counts it.
	system_enter :: proc "c" (wait: u64) -> u64 ---
	// thread_record gives the thread record of the thread that runs: the
	// kernel keeps its address in the gs register.
	thread_record :: proc "c" () -> ^op.Thread_Record ---
	// The `out` and `in` instructions on a port of a device. A thread can use
	// a port only when its process holds a ports handle that names it
	// (`Device_Create`); another port faults with General_Protection.
	port_write_8 :: proc "c" (port: u16, value: u8) ---
	port_read_8 :: proc "c" (port: u16) -> u8 ---
	port_write_32 :: proc "c" (port: u16, value: u32) ---
	port_read_32 :: proc "c" (port: u16) -> u32 ---
	// export_call calls an export with the call form (docs/MODULE_CONTRACT.md,
	// section 4). It loads the 6 integer registers and the 8 float registers
	// from the two arrays, writes the integers 7 to 12 on the stack, calls
	// address, and writes the results: the two integer results, then the two
	// float results.
	export_call :: proc "c" (address: uintptr, integers: ^[CALL_INTEGERS]u64, floats: ^[CALL_FLOATS]u64, results: ^[CALL_RESULTS]u64) ---
}

// The integer arguments of the call form: `module.PARAMETER_CAPACITY`. The
// first 6 are in registers, the others on the stack; enter.asm writes 6
// words of stack, so a change of this number changes export_call too.
CALL_INTEGERS :: 12
CALL_FLOATS :: 8 // The float registers of the call form.
CALL_RESULTS :: 4 // The results of the call form: two integers, then two floats.

// kernel_ring gives the kernel ring of the thread that runs: it is after the
// thread record.
kernel_ring :: #force_inline proc "contextless" () -> ring.Ring {
	kernel, _ := ring.open(rawptr(uintptr(thread_record()) + PAGE_SIZE), ring.PAGE_COUNT)
	return kernel
}

// entered counts the kernel entries of this process that go through this
// library: a process measures its own cost with no grant to inspect.
entered: u64

// kernel_entries gives the kernel entries of this process, as this library
// counted them.
kernel_entries :: proc "contextless" () -> u64 {
	return intrinsics.atomic_load(&entered)
}

// enter is the kernel entry of this library: it counts it.
enter :: #force_inline proc "contextless" (wait: u64) -> u64 {
	intrinsics.atomic_add(&entered, 1)
	return system_enter(wait)
}

// call executes one kernel operation and gives its results and its status.
// When the status is not Ok, the results are zero.
//
// It is the general form: each operation with no procedure of its own goes
// through it. `values` are the arguments in the order of the comment of the
// operation, at most 7.
//
// ```odin
// results, status := system.call(.Memory_Size, u64(memory))
// pages := results[0]
// ```
call :: proc "contextless" (operation: op.Operation, values: ..u64) -> (results: [7]u64, status: Status) {
	return call_with_error(nil, operation, ..values)
}

// call_with_error executes one kernel operation, as call. When the status is
// not Ok and error is not nil, the error record of the failure is written at
// error (docs/MODULE_CONTRACT.md, section 8): the kernel gives it in the
// values of the completion record. The caller owns the record; no global
// state keeps the last error. A call that succeeds does not write it.
// The wrappers below take the same `error` as their last parameter.
call_with_error :: proc "contextless" (error: ^errors.Error_Record, operation: op.Operation, values: ..u64) -> (results: [7]u64, status: Status) {
	command := ring.Record {
		kind = u32(operation),
	}
	for value, index in values {
		command.values[index] = value
	}
	return command_call(error, command)
}

// command_call executes one command record of the kernel ring, as
// call_with_error, through commands_call.
@(private = "package")
command_call :: proc "contextless" (error: ^errors.Error_Record, command: ring.Record) -> (results: [7]u64, status: Status) {
	commands := [1]ring.Record{command}
	completions: [1]ring.Record
	_, status = commands_call(commands[:], completions[:], 0, error)
	if status != .Ok {
		return {}, status
	}
	completion := completions[0]
	if completion.kind != u32(Status.Ok) {
		refused, refusal := status_of_word(completion.kind)
		if error != nil {
			error^ = refusal.kind == i64(errors.Kind.None) ? transmute(errors.Error_Record)completion.values : refusal
		}
		return {}, refused
	}
	return completion.values, .Ok
}

// commands_call executes a batch of command records of the kernel ring in
// one kernel entry, which waits until deadline when it is not 0 (as
// `enter`), and writes the completion of each command at the same place of
// completions. It gives the time. A status that is not Ok is a refusal of
// the batch by this library, with no command run, or an answer that is not
// the answer of its command; the status of each command is the kind of its
// completion.
//
// It is the one path of this library into the kernel ring, and it uses an
// empty kernel ring only: a command or a completion that waits in the ring
// belongs to code that writes the ring itself, and this call neither reads
// it nor runs before it. It then gives `Bad_Operation` with an error record
// `Busy`, and no command runs. An answer with another tag than its command
// gives `Bad_Operation` with an error record `Refused`
// (src/md/api/kernel_ring_completion_room.md).
//
// ```odin
// commands := [2]ring.Record{{kind = u32(op.Operation.Word_Wake), values = {0 = word, 1 = 1}}, {kind = u32(op.Operation.Word_Wait), values = {0 = words, 1 = 1}}}
// completions: [2]ring.Record
// now, status := system.commands_call(commands[:], completions[:], deadline)
// ```
commands_call :: proc "contextless" (commands: []ring.Record, completions: []ring.Record, deadline: u64 = 0, error: ^errors.Error_Record = nil) -> (now: u64, status: Status) {
	kernel := kernel_ring()
	first_tag, pushed := kernel_commands_push(&kernel, commands, len(completions), error)
	if !pushed {
		return time(), .Bad_Operation
	}
	now = enter(deadline)
	if !kernel_completions_take(&kernel, first_tag, commands, completions, error) {
		return now, .Bad_Operation
	}
	return now, .Ok
}

// kernel_command_tag is the tag of the last command that commands_call
// pushed. Each batch takes the next tags, so each answer that it reads
// names its own command.
@(private = "file")
kernel_command_tag: u32

// kernel_commands_push writes a batch of commands into an empty kernel
// ring, with consecutive new tags from first_tag. false: nothing is written,
// and error gets its record: an empty batch (`Too_Small`), a batch past the
// capacity of the ring (`Too_Long`), completions with fewer places than the
// batch (`Too_Small`, argument 2), or a ring that holds a command or a
// completion (`Busy`, with the records that wait). A pure part of
// commands_call, so the host tests it.
@(private = "package")
kernel_commands_push :: proc "contextless" (kernel: ^ring.Ring, commands: []ring.Record, completion_places: int, error: ^errors.Error_Record) -> (first_tag: u32, pushed: bool) {
	capacity_of_ring := int(ring.capacity(&kernel.commands))
	refusal: errors.Error_Record
	switch {
	case len(commands) == 0:
		refusal = {kind = i64(errors.Kind.Too_Small), unit = i64(errors.Unit.Records), argument = 1, value = 0, limit = 1}
	case len(commands) > capacity_of_ring:
		refusal = {kind = i64(errors.Kind.Too_Long), unit = i64(errors.Unit.Records), argument = 1, value = i64(len(commands)), limit = i64(capacity_of_ring)}
	case completion_places < len(commands):
		refusal = {kind = i64(errors.Kind.Too_Small), unit = i64(errors.Unit.Records), argument = 2, value = i64(completion_places), limit = i64(len(commands))}
	case !ring.empty(&kernel.commands) || !ring.empty(&kernel.completions):
		waiting := u64(ring.count(&kernel.commands)) + u64(ring.count(&kernel.completions))
		refusal = {kind = i64(errors.Kind.Busy), unit = i64(errors.Unit.Requests), operation = i64(commands[0].kind &~ op.COMMAND_NAMES_ERROR_DETAILS), value = i64(waiting)}
	}
	if refusal.kind != i64(errors.Kind.None) {
		if error != nil {
			error^ = refusal
		}
		return 0, false
	}
	first_tag = intrinsics.atomic_add(&kernel_command_tag, u32(len(commands))) + 1
	// The ring is empty and the batch fits it, so each push takes its record
	// while only its own thread writes the ring. A refused push means that
	// another thread wrote it: the records before stay, and the batch does
	// not enter the kernel.
	for command, index in commands {
		tagged := command
		tagged.tag = first_tag + u32(index)
		if !ring.push(&kernel.commands, tagged) {
			if error != nil {
				error^ = {kind = i64(errors.Kind.Busy), unit = i64(errors.Unit.Requests), operation = i64(command.kind &~ op.COMMAND_NAMES_ERROR_DETAILS), value = i64(ring.count(&kernel.commands))}
			}
			return 0, false
		}
	}
	return first_tag, true
}

// kernel_completions_take takes the answer of each command of a batch, in
// its order, into completions. false: an answer is absent or has another
// tag than its command; error gets a record `Refused` that names the
// operation of that command. With the ring empty before the push, only a
// write into this ring by another thread of the process gives that.
@(private = "package")
kernel_completions_take :: proc "contextless" (kernel: ^ring.Ring, first_tag: u32, commands: []ring.Record, completions: []ring.Record, error: ^errors.Error_Record) -> bool {
	for command, index in commands {
		popped, ok := ring.pop(&kernel.completions)
		if !ok || popped.tag != first_tag + u32(index) {
			if error != nil {
				error^ = {kind = i64(errors.Kind.Refused), operation = i64(command.kind &~ op.COMMAND_NAMES_ERROR_DETAILS), found = i64(Status.Bad_Operation)}
			}
			return false
		}
		completions[index] = popped
	}
	return true
}

// time gives the milliseconds since boot. It reads the time page: it does
// not enter the kernel.
//
// The value is at most one tick old. A deadline of a wait is in the same
// clock: `system.sleep(system.time() + 100)` waits 100 ms.
time :: proc "contextless" () -> u64 {
	record := (^op.Time_Record)(uintptr(op.TIME_ADDRESS))
	return intrinsics.volatile_load(&record.milliseconds)
}

// cycle_frequency gives the cycles of the cycle counter in one second. It
// reads the time page: it does not enter the kernel.
cycle_frequency :: proc "contextless" () -> u64 {
	record := (^op.Time_Record)(uintptr(op.TIME_ADDRESS))
	return record.cycle_frequency
}

// nanoseconds gives the nanoseconds since boot, from the cycle counter and
// the two constants of the time page: it does not enter the kernel, and it
// does not wait for a tick. The same time 0 as time().
nanoseconds :: proc "contextless" () -> u64 {
	record := (^op.Time_Record)(uintptr(op.TIME_ADDRESS))
	passed := cycles() - record.cycle_start
	frequency := max(record.cycle_frequency, 1)
	// The seconds and the rest are divided apart: no product overflows.
	return passed / frequency * 1_000_000_000 + passed % frequency * 1_000_000_000 / frequency
}

// time_entered gives the milliseconds since boot with a kernel entry. The
// kernel also does the commands in the kernel ring of the thread.
time_entered :: proc "contextless" () -> u64 {
	return enter(0)
}

// sleep stops the thread until the time is deadline. It gives the time.
//
// A deadline in the past returns at once. The deadline 0 is taken as 1,
// because the entry 0 does not wait.
sleep :: proc "contextless" (deadline: u64) -> u64 {
	return enter(max(deadline, 1))
}

// stop ends this process with its stop outcome: each of its threads ends,
// and its memory and its handles end. A holder of its process handle reads
// the stop cause `Itself` and the outcome with `Process_State`. The outcome
// says what the work gave, never a result: a result goes through memory
// that the starter shares. It has no default, so each stop names its
// outcome. It does not return.
//
// It stops the process whatever its kernel ring holds: it drops each
// completion that waits, as the process ends and wants no answer, and
// enters the kernel so that each held command runs, at most one round for
// each place of the ring. Then it sends its stop. A ring that still cannot
// take the stop ends the process with a fault that no handler can take,
// and the stop cause is then `Fault`, never `Itself`
// (src/md/api/kernel_ring_completion_room.md, "The stop of a process").
//
// Example: `system.stop(.Done)` at the end of the work; `system.stop(.Failed)`
// after a check of a test that failed, with its line on the log before;
// `system.stop(.Refused)` for a context or an argument that it refuses.
stop :: proc "contextless" (outcome: op.Stop_Outcome, error: ^errors.Error_Record = nil) -> ! {
	kernel := kernel_ring()
	for round := 0; ; round += 1 {
		switch stop_step(&kernel, round) {
		case .Enter_For_Held_Commands:
			enter(0)
		case .Send_Stop:
			if _, status := call(.Process_Stop, 0, u64(outcome), u64(uintptr(error))); status == .Ok {
				// The kernel ends this thread when it leaves its processor.
				for {}
			}
			stop_by_fault()
		case .Stop_By_Fault:
			stop_by_fault()
		}
	}
}

// What stop does next with its kernel ring.
@(private = "package")
Stop_Step :: enum u8 {
	Send_Stop,               // The ring is empty: the stop command fits.
	Enter_For_Held_Commands, // Commands wait: an entry runs them, and their completions are dropped at the next step.
	Stop_By_Fault,           // The ring does not empty: counters that the process wrote false, or the bound of the rounds.
}

// stop_step drops each completion that waits in the kernel ring, then
// says what stop does: send its stop on an empty ring, enter the kernel for
// the held commands while round is below the capacity of the ring, else
// stop by a fault. Each entry with room runs at least one command, so an
// honest ring is empty within that count of rounds. A pure part of stop, so
// the host tests it.
@(private = "package")
stop_step :: proc "contextless" (kernel: ^ring.Ring, round: int) -> Stop_Step {
	for _ in 0 ..< ring.capacity(&kernel.completions) {
		if _, popped := ring.pop(&kernel.completions); !popped {
			break
		}
	}
	commands_empty := ring.empty(&kernel.commands)
	completions_empty := ring.empty(&kernel.completions)
	switch {
	case commands_empty && completions_empty:
		return .Send_Stop
	case !completions_empty || round >= int(ring.capacity(&kernel.commands)):
		// A completion that pop refuses stays: the counters are false, and
		// no entry changes them.
		return .Stop_By_Fault
	}
	return .Enter_For_Held_Commands
}

// stop_by_fault ends the process with a write to the time page, which a
// process can only read. The kernel serves no fault at that address to a
// fault handler or a debugger, so it stops the process, with the stop cause
// Fault and the report of a page fault.
@(private = "file")
stop_by_fault :: proc "contextless" () -> ! {
	intrinsics.volatile_store((^u64)(uintptr(op.TIME_ADDRESS)), 0)
	for {}
}

// context_record gives the context of this process: it is at a fixed address.
context_record :: #force_inline proc "contextless" () -> ^Context {
	return (^Context)(uintptr(op.CONTEXT_ADDRESS))
}

// own_budget gives the budget that this process received when it started.
own_budget :: proc "contextless" () -> Handle {
	return context_record().handles[op.CONTEXT_BUDGET]
}

// budget_create moves amounts from a budget (0: the budget of this process)
// to a new budget.
//
// The pages, the processes, the threads and the log records of each second
// leave the budget `from`; the processor limit of the new budget is at most
// that of `from`. The handle of `from` needs **Spend**. The new handle has each
// right of a budget. The statuses: `No_Budget` when `from` does not hold an
// amount; `Bad_Handle`, `No_Right`, `No_Slot`.
//
// ```odin
// budget, status := system.budget_create({pages = 256, threads = 2, processor = 100_000, log_records = 50})
// ```
budget_create :: proc "contextless" (amounts: Budget_Amounts, from: Handle = 0, error: ^errors.Error_Record = nil) -> (budget: Handle, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Budget_Create, u64(from == 0 ? own_budget() : from), amounts.pages, amounts.processes, amounts.threads, amounts.processor, amounts.log_records)
	return Handle(results[0]), status
}

// budget_read gives what a budget (0: the budget of this process) can still pay.
//
// The handle needs **Read**. `processor` is the limit of the budget, and
// `log_records` the records of each second that it holds after the budgets
// that came from it; neither is what is left in this period.
budget_read :: proc "contextless" (budget: Handle = 0, error: ^errors.Error_Record = nil) -> (amounts: Budget_Amounts, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Budget_Read, u64(budget == 0 ? own_budget() : budget))
	return {pages = results[0], processes = results[1], threads = results[2], processor = results[3], log_records = results[4]}, status
}

// budget_used gives the microseconds of processor time that a budget (0: the
// budget of this process) used since it was made, with the budgets that came
// from it, and the log records that the kernel refused.
budget_used :: proc "contextless" (budget: Handle = 0) -> (processor_time: u64, refused: u64) {
	results, _ := call(.Budget_Read, u64(budget == 0 ? own_budget() : budget))
	return results[5], results[6]
}

// memory_create makes a memory object. The budget (0: the budget of this
// process) pays for its pages now. Each page gets its page frame at its
// first use, or at creation with the flag Frames_Now.
//
// - `page_count`: from 1 to `op.MEMORY_PAGE_LIMIT` (1 GiB) for an object
//   that is not contiguous.
// - `budget`: a budget handle with **Spend**; 0 is the budget of the
//   process.
// - `flags`: `op.Memory_Flags`.
//
// The result is a memory handle with each right of memory. The statuses are
// those of `Memory_Create`: `No_Budget` when the budget cannot pay,
// `Bad_Operation` for a count or flags that it refuses.
//
// ```odin
// memory := system.memory_create(16) or_return
// bytes := ([^]u8)(system.memory_map(memory) or_return)[:16 * system.PAGE_SIZE]
// ```
memory_create :: proc "contextless" (page_count: u64, budget: Handle = 0, flags: op.Memory_Flags = {}, error: ^errors.Error_Record = nil) -> (memory: Handle, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Create, u64(budget == 0 ? own_budget() : budget), page_count, transmute(u64)flags)
	return Handle(results[0]), status
}

// memory_map maps a memory object in this process (process 0) or in another.
// address 0 lets the kernel choose. page_count 0 maps all pages from first.
//
// - `memory`: a memory handle with **Read**, and **Write** or **Execute** for
//   those flags.
// - `flags`: `{.Write}` by default; `{}` is read only. Never `Write` with
//   `Execute`.
// - `process`: 0, or a process handle with **Control**.
// - `address`, `first`, `page_count`: where, and which pages of the object.
//
// The result is the address of the first page, as a pointer of this process
// even for another process. The statuses are those of `Memory_Map`.
//
// ```odin
// address := system.memory_map(memory, {}) or_return // Read only.
// ```
memory_map :: proc "contextless" (memory: Handle, flags: op.Map_Flags = {.Write}, process: Handle = 0, address: u64 = 0, first: u64 = 0, page_count: u64 = 0, error: ^errors.Error_Record = nil) -> (result: rawptr, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Map, u64(memory), u64(process), address, transmute(u64)flags, first, page_count)
	return rawptr(uintptr(results[0])), status
}

// memory_unmap removes the mapping that starts at an address, in this
// process (process 0) or in another one (a process handle with
// **Control**). The memory object ends when no handle and no mapping names
// it. `Bad_Address` when no mapping starts there.
memory_unmap :: proc "contextless" (address: rawptr, process: Handle = 0, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Memory_Unmap, u64(process), u64(uintptr(address)))
	return status
}

// memory_commit commits the pages of a table of ranges of an object made
// with the flag Uncommitted: the budget pays one page for each page that
// was not committed. The budget (0: the budget of this process) must be the
// budget of the object, with the right Commit or Spend. It gives the pages
// that changed. The ranges are in increasing order and do not overlap
// (op.RANGE_TABLE_CAPACITY ranges and op.RANGE_TABLE_PAGE_LIMIT pages at most).
//
// ```odin
// ranges := [1]op.Page_Range{{first = 0, page_count = 4}}
// changed, status := system.memory_commit(memory, ranges[:])
// ```
memory_commit :: proc "contextless" (memory: Handle, ranges: []op.Page_Range, budget: Handle = 0, error: ^errors.Error_Record = nil) -> (changed: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Commit, u64(memory), u64(budget == 0 ? own_budget() : budget), u64(uintptr(raw_data(ranges))), u64(len(ranges)), 0)
	return results[0], status
}

// memory_decommit takes back the committed pages of a table of ranges: the
// frames and the pages return to the budget at once; the addresses stay,
// and a page committed again is zero. The object must be mapped once, by
// this process only.
memory_decommit :: proc "contextless" (memory: Handle, ranges: []op.Page_Range, error: ^errors.Error_Record = nil) -> (changed: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Commit, u64(memory), 0, u64(uintptr(raw_data(ranges))), u64(len(ranges)), transmute(u64)op.Commit_Flags{.Decommit})
	return results[0], status
}

// memory_protect sets the protection of the pages of a table of ranges of
// addresses of this process: {} is read only, {.Write}, {.Execute}, or
// {.No_Access}. It can only take away what each mapping has. With
// `process`, the ranges are guest memory of a process that no thread ran:
// a mapping made with Write and Execute gets one of the two in turn.
//
// The object of each range must be named by this process only, with one
// mapping (`Object_Shared` else). It gives the pages that changed.
//
// ```odin
// guard := [1]op.Address_Range{{address = u64(uintptr(stack)), page_count = 1}}
// system.memory_protect(guard[:], {.No_Access})
// ```
memory_protect :: proc "contextless" (ranges: []op.Address_Range, flags: op.Map_Flags, error: ^errors.Error_Record = nil, process: Handle = 0) -> (changed: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Protect, u64(uintptr(raw_data(ranges))), u64(len(ranges)), transmute(u64)flags, u64(process))
	return results[0], status
}

// The fault ring (docs/ARCHITECTURE.md, "The fault ring").

// fault_handler_set makes a thread of this process its fault handler (0:
// the thread that calls it): the faults of these kinds of the other threads
// become records of the ring in the thread record of the handler, and each
// faulting thread waits for fault_answer. No kinds: page faults only.
//
// The handler thread reads the records with `fault_record_next`, in a loop:
//
// ```odin
// system.fault_handler_set(0, {.Page_Fault, .Breakpoint})
// for {
// 	record := system.fault_record_next() or_continue
// 	system.fault_answer(record, .Stop)
// }
// ```
fault_handler_set :: proc "contextless" (thread: Handle = 0, kinds: op.Fault_Kinds = {}, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Fault_Handler_Set, u64(thread), u64(op.Fault_Handler_Action.Set), transmute(u64)kinds)
	return status
}

// fault_handler_end ends the delivery: a fault stops the process again.
// If a thread waits for an answer, its record is lost with the ring: the
// process stops with the stop cause Fault_Unanswered. Answer first.
fault_handler_end :: proc "contextless" () -> Status {
	_, status := call(.Fault_Handler_Set, 0, u64(op.Fault_Handler_Action.End))
	return status
}

// fault_answer answers for the thread of a record: Resume lets the thread
// continue at the instruction of the record (Bad_State for a kind that
// does not resume: op.fault_kind_resumes), Stop stops the process with the
// report of the fault.
fault_answer :: proc "contextless" (record: op.Fault_Record, answer: op.Fault_Answer_Kind, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Fault_Answer, record.thread, record.serial, u64(answer))
	return status
}

// fault_record_next gives the next record of the fault ring of the thread
// that calls it, its fault handler. It waits until one comes, or until the
// deadline (false).
fault_record_next :: proc "contextless" (deadline: u64 = WAIT_FOREVER) -> (record: op.Fault_Record, ok: bool) {
	own := thread_record()
	for {
		written := intrinsics.atomic_load(&own.fault_written)
		read := intrinsics.atomic_load(&own.fault_read)
		if written != read {
			record = own.fault_records[read % op.FAULT_RECORD_CAPACITY]
			// The place is free again for the kernel after this store.
			intrinsics.atomic_store(&own.fault_read, read + 1)
			return record, true
		}
		if word_wait(&own.fault_written, written, deadline) >= deadline {
			return {}, false
		}
	}
}

// The debugger of a process (docs/ARCHITECTURE.md, "The debugger of a
// process"). A process with a handle of another process that has the right
// Debug becomes its debugger: it receives its debug exceptions and its
// breakpoints in the fault ring of one of its own threads, holds its
// threads by their numbers, reads and writes their registers and their
// breakpoints, and reads its memory.
//
// ```odin
// system.debug_attach(process)
// system.thread_control_stop(process, 0)
// breakpoints: op.Thread_Breakpoints
// breakpoints.breakpoints[0] = {address = address_of_a_procedure, kind = .Execute}
// system.thread_breakpoints_write(process, 0, breakpoints)
// system.thread_control_resume(process, 0)
// record := system.fault_record_next() or_return
// registers, _ := system.thread_registers_read(process, record.thread)
// system.debug_fault_answer(process, record)
// system.debug_detach(process)
// ```

// debug_attach makes a thread of this process (0: the thread that calls
// it) the debug handler of another process: this process is then its
// debugger. The handle of that process needs the right Debug. The faults
// of the kinds Debug and Breakpoint of that process (always both) become
// records of the fault ring of the handler, which reads them with
// `fault_record_next`; each faulting thread waits for `debug_fault_answer`.
// The debugging ends at `debug_detach`, when the handler thread ends, when
// the last handle with Debug closes, and when the process stops: the
// process then gets back each thread that the debugger held.
debug_attach :: proc "contextless" (process: Handle, kinds: op.Fault_Kinds = {}, thread: Handle = 0, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Fault_Handler_Set, u64(thread), u64(op.Fault_Handler_Action.Set), transmute(u64)kinds, u64(process))
	return status
}

// debug_detach ends the debugging of a process by this process: the kernel
// removes the breakpoints of each thread of that process, clears the trap
// flag that the debugger wrote, takes back the stops that it made, and
// resumes each thread that waits for its answer.
debug_detach :: proc "contextless" (process: Handle, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Fault_Handler_Set, 0, u64(op.Fault_Handler_Action.End), 0, u64(process))
	return status
}

// debug_fault_answer lets the thread of a record of a debugged process go
// on. After an execute breakpoint the thread runs the instruction of the
// breakpoint once, and the breakpoint stays. A debugger gives no answer
// Stop: it stops a process with Process_Stop and the right Control.
debug_fault_answer :: proc "contextless" (process: Handle, record: op.Fault_Record, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Fault_Answer, record.thread, record.serial, u64(op.Fault_Answer_Kind.Resume), u64(process))
	return status
}

// The control of a thread (docs/ARCHITECTURE.md, "The control of a
// thread"). Each procedure names the thread in one of three ways:
// - `thread` 0 and the number of a thread of this process;
// - a thread handle with the rights of the command (`number` is not read);
// - the handle with the right Debug of the process that this process
//   debugs, and the number of a thread of that process.

// thread_control_stop adds 1 to the stop count of a thread and gives the
// count: the thread runs no instruction until its count is 0 again.
thread_control_stop :: proc "contextless" (thread: Handle, number: u64, error: ^errors.Error_Record = nil) -> (count: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Stop))
	return results[0], status
}

// thread_control_resume takes 1 from the stop count of a thread and gives
// the count: at 0 the thread runs again. A debugger takes back only its
// own stops, and each other caller only the stops that the debugger did
// not make (Bad_State with no stop of its own).
thread_control_resume :: proc "contextless" (thread: Handle, number: u64, error: ^errors.Error_Record = nil) -> (count: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Resume))
	return results[0], status
}

// process_record_start makes the kernel write each process input of a
// process into an input history (src/md/features/record_and_replay.md).
// `process` is a process handle with Debug; `history` a contiguous memory
// object with Read and Write, which also pays the point copies. The process
// must not have run yet: the kernel refuses another with the record State,
// Processes.
process_record_start :: proc "contextless" (process: Handle, history: Handle, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Thread_Control, u64(process), u64(history), u64(op.Thread_Control_Command.Record_Start))
	return status
}

// process_replay_start makes the kernel run a process in replay mode from an
// input history (src/md/features/record_and_replay.md, "The replay"): each
// input comes from the history, and the first difference stops the process
// with a divergence. `process` is a process handle with Debug that did not
// run yet; `history` a contiguous memory object with Read and Write whose
// record ended. The kernel writes the end of the replay into the header of
// the history.
process_replay_start :: proc "contextless" (process: Handle, history: Handle, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Thread_Control, u64(process), u64(history), u64(op.Thread_Control_Command.Replay_Start))
	return status
}

// process_record_end ends the record that process_record_start began: the
// kernel writes the end record into the input history and stops writing it.
process_record_end :: proc "contextless" (process: Handle, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Thread_Control, u64(process), 0, u64(op.Thread_Control_Command.Record_End))
	return status
}

// thread_registers_read gives the registers of a held thread.
thread_registers_read :: proc "contextless" (thread: Handle, number: u64, error: ^errors.Error_Record = nil) -> (registers: op.Thread_Registers, status: Status) {
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Read_Registers), u64(uintptr(&registers)), size_of(registers))
	return registers, status
}

// thread_registers_write gives a held thread these registers: it goes on
// with them. Bad_Operation for registers that a thread of a process cannot
// have; the error record names the refused part.
thread_registers_write :: proc "contextless" (thread: Handle, number: u64, registers: op.Thread_Registers, error: ^errors.Error_Record = nil) -> (status: Status) {
	written := registers
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Write_Registers), u64(uintptr(&written)), size_of(written))
	return status
}

// thread_breakpoints_read gives the breakpoints of a held thread.
thread_breakpoints_read :: proc "contextless" (thread: Handle, number: u64, error: ^errors.Error_Record = nil) -> (breakpoints: op.Thread_Breakpoints, status: Status) {
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Read_Breakpoints), u64(uintptr(&breakpoints)), size_of(breakpoints))
	return breakpoints, status
}

// thread_breakpoints_write gives a held thread these breakpoints, and no
// other: at most four, each an execute breakpoint or a data breakpoint at
// an address of its process. Only the debugger of the process writes them:
// `thread` is its handle with the right Debug, and 0 or a thread handle
// gives Bad_Handle. A reached breakpoint is a fault of the kind
// Debug of that thread, with the number of the breakpoint in the debug
// status of its record. Bad_Operation for a breakpoint that a thread
// cannot have; the error record names the refused part.
thread_breakpoints_write :: proc "contextless" (thread: Handle, number: u64, breakpoints: op.Thread_Breakpoints, error: ^errors.Error_Record = nil) -> (status: Status) {
	written := breakpoints
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Write_Breakpoints), u64(uintptr(&written)), size_of(written))
	return status
}

// thread_memory_read copies bytes of the process of a thread, from
// `source` in that process, into `buffer` (at most
// op.THREAD_MEMORY_READ_LIMIT bytes), and gives the count that it copied.
// It reads only pages that the process maps, can read and that have a
// frame; it stops before the first page that is not so. Bad_Address when
// no byte is read. A thread handle needs the rights Inspect and Write.
thread_memory_read :: proc "contextless" (thread: Handle, number: u64, source: u64, buffer: []u8, error: ^errors.Error_Record = nil) -> (count: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Read_Memory), u64(uintptr(raw_data(buffer))), u64(len(buffer)), source)
	return results[0], status
}

// The thread counters (docs/ARCHITECTURE.md, "The counters of a thread"):
// the events of the processor for the code of the calling thread, in user
// mode only. A start and a read take the machine handle with the right
// Counters, and act on the calling thread. A machine whose processors have
// no counters that the kernel uses gives them Bad_Operation, with the error
// kind Unsupported.

// thread_counters_start makes the calling thread count from 0, from now on.
thread_counters_start :: proc "contextless" (machine: Handle, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Thread_Control, u64(machine), 0, u64(op.Thread_Control_Command.Start_Counters))
	return status
}

// thread_counters_read gives the counts of the calling thread since its
// last start; it goes on counting. Bad_State when it does not count.
thread_counters_read :: proc "contextless" (machine: Handle, error: ^errors.Error_Record = nil) -> (counters: op.Thread_Counters, status: Status) {
	_, status = call_with_error(error, .Thread_Control, u64(machine), 0, u64(op.Thread_Control_Command.Read_Counters), u64(uintptr(&counters)), size_of(counters))
	return counters, status
}

// thread_counters_stop makes the calling thread stop counting. It needs no
// handle and no right: it only takes a capability away, so a thread whose
// right was revoked can still stop.
thread_counters_stop :: proc "contextless" (error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Thread_Control, 0, 0, u64(op.Thread_Control_Command.Stop_Counters))
	return status
}

// memory_physical gives the device address of the first page of a memory
// object: the devices of the caller see its pages follow each other from
// there. It is the physical address of a contiguous object, or with the
// IOMMU the window of another object. The machine handle needs the right
// Physical.
memory_physical :: proc "contextless" (machine: Handle, memory: Handle, error: ^errors.Error_Record = nil) -> (address: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Physical, u64(machine), u64(memory))
	return results[0], status
}

// memory_size gives the pages of a memory object, and the status of the
// kernel. When the kernel refuses, pages is 0 and the error record is at
// error, if it is not nil.
//
// Any rights suffice. The kernel refuses a handle that is not a memory
// handle (`Bad_Handle`).
memory_size :: proc "contextless" (memory: Handle, error: ^errors.Error_Record = nil) -> (pages: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Memory_Size, u64(memory))
	if status != .Ok {
		return 0, status
	}
	return results[0], .Ok
}

// give copies a handle to another process. target is a process handle, or a
// memory handle: then the other process that maps this memory receives it.
// With the target 0, the copy is in this process.
// The new handle has the rights of handle that are also in rights.
// The result is the handle in the table of that process.
//
// The handle needs **Give** for another process. A starter gives each grant
// of a new process with it; a service gives a handle to a caller through
// the memory of their ring, and the caller proves it with `handle_state`.
//
// ```odin
// copy, status := system.give(process, memory, {.Read})
// ```
give :: proc "contextless" (target: Handle, handle: Handle, rights: Rights, error: ^errors.Error_Record = nil) -> (result: Handle, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Handle_Give, u64(target), u64(handle), u64(transmute(u32)rights))
	return Handle(results[0]), status
}

// handle_state gives the kind of the object of a handle, and the rights of
// the handle. kind is None when the number names no handle of this process.
// through says if the handle came through a memory object: another process
// gave it with this memory as the target of give.
//
// A handle number from another process is hostile input: check it with
// this procedure before use.
//
// ```odin
// kind, rights, through := system.handle_state(handle, ring_memory)
// if kind != .Memory || !through {
// 	return // Not a memory object that the other side gave through the ring.
// }
// ```
handle_state :: proc "contextless" (handle: Handle, memory: Handle = 0) -> (kind: op.Object_Kind, rights: Rights, through: bool) {
	results, status := call(.Handle_State, u64(handle), u64(memory))
	if status != .Ok {
		return .None, {}, false
	}
	object_kind, known := enum_word.member_of_word(op.Object_Kind, results[0])
	if !known {
		kernel_word_refused("the kind of an object", results[0])
	}
	return object_kind, transmute(Rights)u32(results[1]), results[2] != 0
}

// kernel_word_refused writes the line of a word of a result of the kernel
// that names no member of its enum, and stops the process with `Failed`.
// The kernel and this library come from one build: such a word is a fault
// of the build, and no member stands in for it.
kernel_word_refused :: proc "contextless" (what: string, word: u64) -> ! {
	log(.Error, "system: the kernel gave the word ", word, " for ", what, ", which names no member")
	stop(.Failed)
}

// handle_revoke ends each handle and each mapping that came from a handle:
// in one process (a handle with the right Control), or in each process.
// The handle stays, and the mappings of this process stay. count is the
// count of holdings that ended.
handle_revoke :: proc "contextless" (handle: Handle, process: Handle = 0, error: ^errors.Error_Record = nil) -> (count: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Handle_Revoke, u64(handle), u64(process))
	return results[0], status
}

// region_refusal checks the handle of a data region that a client sent
// with the command Attach of a device ring (src/library/modus/contract/block, src/library/modus/contract/frame):
// memory, with Read and Write, that came through the ring. When it refuses,
// it gives the values of the error record of the completion and its call
// outcome, in the order of the tests of a callee (lent_handle_outcome).
region_refusal :: proc "contextless" (handle: Handle, ring_memory: Handle, command: u32) -> (values: [7]u64, outcome: call_outcome.Call_Outcome, refused: bool) {
	kind, rights, through := handle_state(handle, ring_memory)
	needed := Rights{.Read, .Write}
	switch {
	case kind != .Memory:
		return errors.ring_fail(command, .Handle_Kind, .None, 1, i64(handle), i64(op.Object_Kind.Memory), i64(kind)), lent_handle_outcome(false, true, false), true
	case !through:
		return errors.ring_fail(command, .Absent, .Region, 1), lent_handle_outcome(true, false, false), true
	case !(needed <= rights):
		return errors.ring_fail(command, .Handle_Rights, .None, 1, i64(handle), i64(transmute(u32)needed), i64(transmute(u32)rights)), lent_handle_outcome(false, false, true), true
	}
	return {}, .Succeeded, false
}

// handle_holdings gives the count of the handles and the mappings that
// came from a handle, in each process.
handle_holdings :: proc "contextless" (handle: Handle) -> u64 {
	results, _ := call(.Handle_State, u64(handle), 0)
	return results[3]
}

// A handle that the caller of an export lends for the time of the call
// (module.Type.Handle). RIGHTS is what the export needs: the description of
// the export has it, and the caller lends no other right.
//   fill :: proc "c" (memory: system.Lent({.Read, .Write}), value: i64) -> i64
// In a register and in a record, it is the 32 bits of the handle.
Lent :: struct($RIGHTS: Rights) {
	handle: Handle,
}

// close ends a handle of this process (`Handle_Close`). The object ends
// when no handle and no mapping names it; the mappings that the handle made
// stay. A handle that names nothing is ignored.
close :: proc "contextless" (handle: Handle) {
	call(.Handle_Close, u64(handle))
}

// ring_create makes the memory of a ring and maps it in this process. The
// capacity is the count of records of each queue: a power of two, 32 or
// more. Choose it for the largest burst of the writer.
//
// `Bad_Operation` for a capacity that is not a power of two from
// `ring.CAPACITY` to `ring.CAPACITY_LIMIT`. Give the memory handle to the
// other side, which opens it with `ring_open`.
//
// ```odin
// memory, calls := system.ring_create(64) or_return
// ```
ring_create :: proc "contextless" (capacity: u32 = ring.CAPACITY, receive_handles := false) -> (memory: Handle, mapped: ring.Ring, status: Status) {
	if capacity < ring.CAPACITY || capacity > ring.CAPACITY_LIMIT || capacity & (capacity - 1) != 0 {
		return 0, {}, .Bad_Operation
	}
	memory = memory_create(ring.pages(capacity)) or_return
	mapped, status = ring_open(memory, receive_handles = receive_handles)
	if status != .Ok {
		close(memory)
		memory = 0
	}
	return memory, mapped, status
}

// ring_open maps the memory of a ring in this process. The capacity of the
// ring comes from the size of the memory, that the kernel gives.
// receive_handles: pass Map_Flag.Receive_Handles so the peer can transfer
// handles through this ring with Handle_Give (false by default).
// error: the record of a refusal, if the caller gives one. The argument 1
// is the memory. Each cause has its own answer: the status and the record
// of the kernel for a handle that it refuses (Memory_Size, Memory_Map), and
// Bad_Operation with the record of ring_pages_refusal for a size that is no
// ring.
ring_open :: proc "contextless" (memory: Handle, error: ^errors.Error_Record = nil, receive_handles := false) -> (mapped: ring.Ring, status: Status) {
	page_count := memory_size(memory, error) or_return
	if refusal, refused := ring_pages_refusal(page_count); refused {
		if error != nil {
			error^ = refusal
		}
		return {}, .Bad_Operation
	}
	flags := op.Map_Flags{.Write}
	if receive_handles {
		flags += {.Receive_Handles}
	}
	address := memory_map(memory, flags, error = error) or_return
	opened, ok := ring.open(address, page_count)
	if !ok {
		// ring_pages_refusal took this count, and ring.open reads no byte of
		// the memory: its one other refusal is an address of no memory.
		memory_unmap(address)
		errors.fail(error, 0, .Bad_Address, .None, 1, i64(uintptr(address)))
		return {}, .Bad_Address
	}
	return opened, .Ok
}

// ring_pages_refusal is the check of the size of the memory of a ring: the
// record Bad_Value, unit Pages, of argument 1, for a count of pages that is
// no ring (below ring.PAGE_COUNT, above the pages of ring.CAPACITY_LIMIT, or
// a capacity that is not a power of two). The bound comes first, so the
// product of a large count never wraps. It reads and changes no state.
ring_pages_refusal :: proc "contextless" (page_count: u64) -> (refusal: errors.Error_Record, refused: bool) {
	largest := ring.pages(ring.CAPACITY_LIMIT)
	if page_count < ring.PAGE_COUNT || page_count > largest {
		return errors.error_make(.Bad_Value, .Pages, 1, i64(min(page_count, 1 << 62)), i64(largest)), true
	}
	capacity := (page_count - 1) * ring.CAPACITY
	if capacity & (capacity - 1) != 0 {
		return errors.error_make(.Bad_Value, .Pages, 1, i64(page_count), i64(largest)), true
	}
	return {}, false
}

// ring_close unmaps a ring.
ring_close :: proc "contextless" (mapped: ^ring.Ring) {
	if mapped.head != nil {
		memory_unmap(mapped.head)
	}
	mapped^ = {}
}

// shared_create makes the memory of a shared queue and maps it in this
// process. The capacity is a power of two, 64 or more.
shared_create :: proc "contextless" (capacity: u32 = ring.SHARED_CAPACITY) -> (memory: Handle, mapped: ring.Shared, status: Status) {
	if capacity < ring.SHARED_CAPACITY || capacity > ring.SHARED_CAPACITY_LIMIT || capacity & (capacity - 1) != 0 {
		return 0, {}, .Bad_Operation
	}
	memory = memory_create(ring.shared_pages(capacity)) or_return
	mapped, status = shared_open(memory)
	if status != .Ok {
		close(memory)
		memory = 0
	}
	return memory, mapped, status
}

// shared_open maps the memory of a shared queue in this process. The
// capacity comes from the size of the memory, that the kernel gives.
shared_open :: proc "contextless" (memory: Handle) -> (mapped: ring.Shared, status: Status) {
	page_count := memory_size(memory) or_return
	if page_count > ring.shared_pages(ring.SHARED_CAPACITY_LIMIT) {
		return {}, .Bad_Handle
	}
	address := memory_map(memory) or_return
	opened, ok := ring.shared_open(address, page_count)
	if !ok {
		memory_unmap(address)
		return {}, .Bad_Handle
	}
	return opened, .Ok
}

// shared_close unmaps a shared queue.
shared_close :: proc "contextless" (mapped: ^ring.Shared) {
	if mapped.head != nil {
		memory_unmap(mapped.head)
	}
	mapped^ = {}
}

// A thread of this process, and the memory of its stack.
Thread :: struct {
	handle: Handle,
	stack:  rawptr,
}

// A thread that calls the module cryptography or draws random bytes needs
// 24 KiB of stack at least: the 16 KiB that erase_stack_below_the_caller
// erases below its frame, and its frames (src/runtime/memory.asm). With less, the
// thread stops at the guard page under its stack, and no other memory is
// written.
THREAD_STACK_PAGES :: op.THREAD_STACK_PAGES

// thread_start starts a new thread of this process at entry. The threads of
// a process share all its memory and all its handles. The stack is new
// memory; the page under it has no memory.
//
// ```odin
// worker :: proc "c" (parameter: rawptr) -> ! {
// 	// ... the work ...
// 	system.thread_stop()
// }
// thread := system.thread_start(worker, &shared) or_return
// system.thread_wait(thread)
// ```
//
// The entry never returns: it calls thread_stop. The budget (0: the budget
// of this process) pays for the thread and gives its processor time. The
// weight (1 to the new-thread weight limit of the calling thread, which is
// op.WEIGHT_FULL unless the holder of the machine lowered it; 0: that
// limit) and the request in
// microseconds (0: op.REQUEST_DEFAULT) are for the scheduling strategies
// that use them (docs/SCHEDULING.md).
thread_start :: proc "contextless" (entry: proc "c" (parameter: rawptr) -> !, parameter: rawptr, stack_pages: u64 = THREAD_STACK_PAGES, budget: Handle = 0, weight: u64 = 0, request: u64 = 0, error: ^errors.Error_Record = nil) -> (thread: Thread, status: Status) {
	memory := memory_create(stack_pages, 0, {}, error) or_return
	defer close(memory)
	thread.stack = memory_map(memory, error = error) or_return
	results: [7]u64
	results, status = call_with_error(error, .Thread_Create, u64(budget == 0 ? own_budget() : budget), u64(uintptr(rawptr(entry))), u64(uintptr(thread.stack)) + stack_pages * PAGE_SIZE, u64(uintptr(parameter)), weight, request)
	if status != .Ok {
		memory_unmap(thread.stack)
		return {}, status
	}
	thread.handle = Handle(results[0])
	return thread, .Ok
}

// strategy_set changes the scheduling strategy of the machine while it
// runs, and gives the strategy before. The machine handle needs the right
// Schedule.
strategy_set :: proc "contextless" (machine: Handle, strategy: op.Strategy, error: ^errors.Error_Record = nil) -> (before: op.Strategy, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Strategy_Set, u64(machine), u64(strategy))
	if status != .Ok {
		return {}, status
	}
	strategy_before, known := enum_word.member_of_word(op.Strategy, results[0])
	if !known {
		kernel_word_refused("the strategy before", results[0])
	}
	return strategy_before, status
}

// thread_schedule_read gives the schedule of a thread: its weight and its
// request, the values in use (docs/SCHEDULING.md, "The schedule of a live
// thread"). The thread is named in one of three ways:
// - `thread` 0 and the number of a thread of this process
//   (`Thread_Record.number`);
// - a thread handle with the right Inspect (`number` is not read);
// - the machine handle with the rights Schedule and Inspect, and the
//   machine number of any thread (`op.Thread_Report.machine_number`).
//
// ```odin
// schedule, status := system.thread_schedule_read(0, system.thread_record().number)
// ```
thread_schedule_read :: proc "contextless" (thread: Handle, number: u64, error: ^errors.Error_Record = nil) -> (schedule: op.Thread_Schedule, status: Status) {
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Read_Schedule), u64(uintptr(&schedule)), size_of(schedule))
	return schedule, status
}

// thread_schedule_write gives a thread a weight and a request in
// microseconds, also while the thread runs. The thread is named as for
// thread_schedule_read; a thread handle needs the right Control, the
// machine handle the rights Schedule and Inspect.
//
// Through 0 or a thread handle the write only lowers: a weight above the
// weight of the thread, or a request above its request, gives
// Bad_Operation; 0 keeps a value. Only a write through the machine handle
// raises a weight or a request, and reads `weight_limit` and
// `new_thread_weight_limit`: it gives the four values (0: op.WEIGHT_FULL
// for the limit, the limit for the weight and for the new-thread weight
// limit, op.REQUEST_DEFAULT), so read the schedule first to change one of
// them. A raised weight starts the thread again as a new thread for
// its scheduling strategy.
//
// ```odin
// status := system.thread_schedule_write(worker.handle, 0, {weight = 256})
// ```
thread_schedule_write :: proc "contextless" (thread: Handle, number: u64, schedule: op.Thread_Schedule, error: ^errors.Error_Record = nil) -> (status: Status) {
	written := schedule
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Write_Schedule), u64(uintptr(&written)), size_of(written))
	return status
}

// process_schedule_read gives the schedule of a process: the new-thread
// weight limit of all its threads (docs/SCHEDULING.md, "The new-thread
// weight limit"). Only the machine handle with the rights Schedule and
// Inspect; the process is named by its slot and its serial
// (`op.Process_Report.process_serial`).
//
// ```odin
// schedule, status := system.process_schedule_read(machine, slot, report.process_serial)
// ```
process_schedule_read :: proc "contextless" (machine: Handle, slot, serial: u64, error: ^errors.Error_Record = nil) -> (schedule: op.Process_Schedule, status: Status) {
	_, status = call_with_error(error, .Thread_Control, u64(machine), op.process_slot_and_serial(slot, serial), u64(op.Thread_Control_Command.Read_Process_Schedule), u64(uintptr(&schedule)), size_of(schedule))
	return schedule, status
}

// process_schedule_write gives a process a schedule: from the write on,
// no thread of the process creates a thread with a weight limit above its
// new-thread weight limit (0: op.WEIGHT_FULL). Named as for
// process_schedule_read, with the same rights.
//
// ```odin
// status := system.process_schedule_write(machine, slot, report.process_serial, {new_thread_weight_limit = 32})
// ```
process_schedule_write :: proc "contextless" (machine: Handle, slot, serial: u64, schedule: op.Process_Schedule, error: ^errors.Error_Record = nil) -> (status: Status) {
	written := schedule
	_, status = call_with_error(error, .Thread_Control, u64(machine), op.process_slot_and_serial(slot, serial), u64(op.Thread_Control_Command.Write_Process_Schedule), u64(uintptr(&written)), size_of(written))
	return status
}

// thread_placement_read gives the placement of a thread: the set of the
// processors that can run it, and the limit of that set
// (docs/SCHEDULING.md, "The placement of a thread"). Bit n of a set is the
// processor n. The thread is named as for thread_schedule_read, with the
// same rights.
//
// ```odin
// placement, status := system.thread_placement_read(0, system.thread_record().number)
// ```
thread_placement_read :: proc "contextless" (thread: Handle, number: u64, error: ^errors.Error_Record = nil) -> (placement: op.Thread_Placement, status: Status) {
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Read_Placement), u64(uintptr(&placement)), size_of(placement))
	return placement, status
}

// thread_placement_write gives a thread the set of the processors that can
// run it, also while the thread runs. The thread is named as for
// thread_schedule_write, with the same rights.
//
// Through 0 or a thread handle the write only narrows: a set with a
// processor that the set of the thread does not have gives Bad_Operation;
// 0 keeps the set. Only a write through the machine handle widens a set,
// and reads `processors_limit`: it gives the two sets (0: every processor
// for the limit, the limit for the set), so read the placement first to
// change one of them. A set with no processor of the machine is refused.
// A thread that runs on a processor that left its set leaves it at the
// end of its stint at the latest.
//
// ```odin
// status := system.thread_placement_write(worker.handle, 0, {processors = 0b0011})
// ```
thread_placement_write :: proc "contextless" (thread: Handle, number: u64, placement: op.Thread_Placement, error: ^errors.Error_Record = nil) -> (status: Status) {
	written := placement
	_, status = call_with_error(error, .Thread_Control, u64(thread), number, u64(op.Thread_Control_Command.Write_Placement), u64(uintptr(&written)), size_of(written))
	return status
}

// events_set gives the event table of the machine (docs/ARCHITECTURE.md,
// "Kernel events"): the rules, and a Contiguous memory object with Write
// that holds one event ring of `records` records for each processor. It
// gives the bytes of one ring and the count of processors. A new table of
// this process replaces its table. The machine handle needs the right
// Events.
events_set :: proc "contextless" (machine: Handle, memory: Handle, rules: []op.Event_Rule, records: u64, error: ^errors.Error_Record = nil) -> (ring_bytes: u64, processor_count: u64, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Events_Set, u64(machine), u64(memory), u64(uintptr(raw_data(rules))), u64(len(rules)), records)
	return results[0], results[1], status
}

// events_end takes the event table of this process away. When it returns,
// the kernel writes no more record in the memory object of the rings.
events_end :: proc "contextless" (machine: Handle, error: ^errors.Error_Record = nil) -> Status {
	_, status := call_with_error(error, .Events_Set, u64(machine), 0)
	return status
}

// One exit of a guest processor: the results of `Guest_Run`
// (`op.Guest_Exit_Kind` says what `a`, `b` and `c` hold).
Guest_Exit :: struct {
	kind:          op.Guest_Exit_Kind,
	a, b, c:       u64,
	next:          u64, // The address after the instruction of the exit, for a port, `hlt`, `cpuid`, `rdmsr`, `wrmsr`, `rdtsc` and `rdtscp`.
	code:          u64, // The exit code of the processor.
	information:   u64, // The first exit information of the processor.
}

// guest_run runs one guest processor of a process on this thread until an
// exit that the kernel does not handle itself (docs/ARCHITECTURE.md, "A
// guest"). `processor` names it, from 0 to
// `op.GUEST_PROCESSOR_CAPACITY - 1`; other threads can run the others at
// the same time. `process` is a process handle with **Control** of a process
// that `Process_Create` made and that no thread ran; its addresses are the
// guest physical addresses. `registers` goes in, and holds the registers
// of the guest after the exit: the process answers an exit by a change of
// it before the next run. `Bad_Operation` with the error kind
// `Unsupported`: the machine has no virtualization support that the kernel
// uses.
//
// ```odin
// registers := op.Guest_Registers{rip = 0x1000}
// exit, status := system.guest_run(guest, &registers)
// if exit.kind == .Port_Write {
// 	registers.rip = exit.next
// }
// ```
guest_run :: proc "contextless" (process: Handle, registers: ^op.Guest_Registers, error: ^errors.Error_Record = nil, processor: u64 = 0) -> (exit: Guest_Exit, status: Status) {
	results: [7]u64
	results, status = call_with_error(error, .Guest_Run, u64(process), u64(uintptr(registers)), processor)
	if status != .Ok {
		return {}, status
	}
	// The kernel writes the kind as a word: a word that names no kind is the
	// refusal Bad_Operation with the record Bad_Value, never an exit.
	kind, kind_ok := enum_word.member_of_word(op.Guest_Exit_Kind, results[0])
	if !kind_ok {
		errors.fail(error, 0, .Bad_Value, .None, 0, i64(results[0]), i64(max(op.Guest_Exit_Kind)))
		return {}, .Bad_Operation
	}
	return {kind = kind, a = results[1], b = results[2], c = results[3], next = results[4], code = results[5], information = results[6]}, .Ok
}

// event_ring gives the head and the records of the event ring of one
// processor, in the memory object of the rings mapped at base. records is
// the count that this process gave to events_set.
event_ring :: proc "contextless" (base: rawptr, ring_bytes: u64, processor: u64, records: u64) -> (head: ^op.Event_Ring, ring_records: []op.Event_Record) {
	head = (^op.Event_Ring)(uintptr(base) + uintptr(processor * ring_bytes))
	ring_records = ([^]op.Event_Record)(uintptr(head) + op.EVENT_RING_HEAD_BYTES)[:records]
	return
}

// event_next gives the next record of an event ring, or false when the ring
// is empty. The place of the record is free for the kernel again after it.
event_next :: proc "contextless" (head: ^op.Event_Ring, ring_records: []op.Event_Record) -> (record: op.Event_Record, ok: bool) {
	written := intrinsics.atomic_load(&head.written)
	read := intrinsics.atomic_load(&head.read)
	if read == written || len(ring_records) == 0 {
		return {}, false
	}
	record = ring_records[read % u64(len(ring_records))]
	intrinsics.atomic_store(&head.read, read + 1)
	return record, true
}

// thread_stop ends the thread that calls it. Its stack stays until another
// thread calls `thread_end` or `thread_wait`. The end of the last thread
// ends the process with the stop cause Last_Thread_Ended.
thread_stop :: proc "contextless" () -> ! {
	call(.Thread_Stop, 0)
	for {}
}

// thread_stopped says if a thread ended.
thread_stopped :: proc "contextless" (thread: Thread) -> bool {
	results, status := call(.Thread_State, u64(thread.handle))
	return status != .Ok || op.Process_State(results[0]) == .Stopped
}

// thread_end stops a thread if it runs, then frees its stack and its handle.
thread_end :: proc "contextless" (thread: Thread) {
	call(.Thread_Stop, u64(thread.handle))
	memory_unmap(thread.stack)
	close(thread.handle)
}

// thread_wait waits until a thread ends by itself, then frees its stack and
// its handle. The end of a thread is an event for the other threads.
thread_wait :: proc "contextless" (thread: Thread) {
	for {
		wait := wait_begin()
		if thread_stopped(thread) {
			break
		}
		wait_end(&wait)
	}
	thread_end(thread)
}
