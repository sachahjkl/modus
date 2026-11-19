// The debugger of a process, as the kernel gives it (docs/ARCHITECTURE.md,
// "The debugger of a process").
//
// A process with a handle of another process that has the right Debug
// becomes its debugger. This process is the debugger of children that it
// starts itself (this module, with a role): the process that creates a
// process has the right Debug on the handle that the creation gave. Each
// case checks one part of the contract:
//
// - The attach, and the refusals: a write of breakpoints on a thread that
//   is not held, a handle with no Debug, a breakpoint at an address of the
//   kernel, a write of breakpoints by a process on its own thread.
// - An execute breakpoint at a procedure of the child, the registers at
//   the stop, a single step, a data breakpoint, and the end of the child
//   with its own code when the breakpoints are removed.
// - `Read_Memory`: a value of the child, an address of the kernel, a page
//   that the child does not map, a thread handle with Inspect only.
// - The end of the debugging gives the process back: a detach while a
//   thread is held; a second debugger that ends while the child waits at
//   its breakpoint, that ends after a single step, that closes its handle,
//   and whose handle is revoked.
// - A breakpoint belongs to one thread: another thread of the child runs
//   through the same procedure.
// - A stop of the child on its own thread stays when the debugger, which
//   stopped that thread too, detaches.
// - A data breakpoint on memory that the kernel copies, and one that a
//   load of the stack selector holds until a syscall: the kernel does not
//   fault.
// - A full ring of the debugger: the breakpoint is lost for the debugger,
//   and the child goes on.
//
// **What it is for.** It is the test of the four additions of the kernel
// for a debugger: the right Debug, the delivery of the debug exceptions to
// the debugger, the breakpoints of a thread, and the read of the memory of
// a process. The commands of the console come on top of the same contract.
//
// **Start**: `start("debugged")` in the console. The parent starts each
// child from the boot image.
//
// **Grants**, as the root service gives them:
//
// - **Image**: the boot image, read-only, to start the children from it.
// - The log with **Give**: one child writes a line of the log from a
//   buffer that its debugger watches.
//
// **What a reader sees**: the log has one line for each case, which ends
// with "as it must", then "debugged: ok, 24 cases: a debugger holds, reads
// and steps one process, and its end gives the process back", or
// "debugged: failed: N cases of 24". The process has no window.
//
// The design: (docs/TOOLS.md, "The debugger: the design").
package debugged

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:support/random"
import "modus:support/system"

// Two children at a time, the process that is debugged and a second
// debugger, each with a budget of two threads; its main thread, and one
// thread of its own that only waits.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1860, processes = 3, threads = 6}

// The value of the context that gives the role of a child. Not the value 0:
// the root service writes there the size of the boot image of the grant
// Image, which the parent holds, so a role there would read a size.
VALUE_ROLE :: 7
VALUE_MODE :: 1 // What a child or a second debugger does: a Child_Mode or a Debugger_Mode.
VALUE_ADDRESS :: 2 // A second debugger: the address of the procedure of the child where it sets its breakpoint.

GRANT_SHARED :: 6 // A child, a second debugger: the page that it shares with the parent.
GRANT_TARGET :: 7 // A second debugger: the process that it debugs, with Debug.

CASE_COUNT :: 24

CHILD_ROUNDS :: 3

// The value that a child writes in `child_known_value`: the debugger reads
// it in the memory of the child, and its own copy stays 0.
KNOWN_VALUE :: u64(0x6368_696C_645F_6F6B)

// An address of the kernel half, and an address that no process maps: the
// first page.
KERNEL_ADDRESS :: u64(0xFFFF_8000_0000_0000)
UNMAPPED_ADDRESS :: u64(0x1000)

// The first byte of a procedure that keeps the frame pointer: push rbp.
PUSH_FRAME_POINTER :: 0x55

FLAG_TRAP :: u64(1) << 8

// The line that one child writes on the log from a buffer that its
// debugger watches. The machine test waits for it.
COPIED_LINE :: "the kernel copied this line from a watched buffer"

Role :: enum u64 {
	Parent          = 0,
	Child           = 1,
	Second_Debugger = 2,
}

// What a child does after it wrote its known value.
Child_Mode :: enum u64 {
	Rounds      = 0, // It waits for the parent, runs CHILD_ROUNDS rounds of its loop, and stops itself with `Done`.
	Forever     = 1, // Its loop has no end.
	With_Worker = 2, // Its loop has no end; a second thread runs the same procedure, and the main thread holds and releases it when the parent asks.
	Kernel_Copy = 3, // It gives a watched buffer to the kernel, loads its stack selector from a watched word before a syscall, then reads the buffer itself.
}

// What a second debugger does when the thread of the child waits at its
// breakpoint.
Debugger_Mode :: enum u64 {
	Ends               = 0, // It stops the thread once more, and ends with no answer.
	Steps_Then_Ends    = 1, // It runs one instruction of the thread, and ends at the record of the step.
	Closes_Its_Handle  = 2, // It closes its handle of the child, and lives.
	Waits_To_Be_Revoked = 3, // It lives: the parent revokes its handle.
}

// The page that a child or a second debugger shares with the parent.
Shared :: struct {
	ready:         u32, // 1: the child wrote its known value and its addresses. A second debugger: its breakpoint is set.
	go:            u32, // The parent writes it: the step that a child can start.
	rounds:        u32, // The rounds of its loop that the main thread of the child ended.
	worker_rounds: u32, // The rounds that the second thread of the child ended.
	worker_number: u32, // The number of that thread in the child.
	worker_ready:  u32, // 1: the second thread wrote its number.
	command:       u32, // The parent writes it: 1, the child stops its second thread; 2, it resumes it.
	answered:      u32, // The child writes the command that it ended.
	status:        u32, // The status of what the child did last.
	count:         u32, // The stop count that the last Resume of the child gave.
	stage:         u32, // A child of the mode Kernel_Copy: the steps that it ended. A second debugger: 1 when the thread of the child waits and it did its last act.
	// The addresses of the child, as the child has them: the debugger takes
	// them from here, and not from its own copy of the module.
	target:        u64, // child_step_target.
	watched:       u64, // child_watched_word.
	known:         u64, // child_known_value.
	text:          u64, // child_watched_text.
	selector:      u64, // child_stack_selector.
}

child_known_value: u64
child_watched_word: u64
child_calls: u64
// The text of COPIED_LINE, in words so that its first byte is on 8 bytes:
// a data breakpoint of 8 bytes watches its first word.
child_watched_text: [16]u64
// The stack selector of a thread of a process, in a word that a data
// breakpoint watches.
child_stack_selector: u64

process_generator: random.Generator
image: []u8
log_handle: system.Handle
right_count: int

foreign _ {
	load_stack_selector_then_syscall :: proc "c" (selector: ^u64) ---
}

// child_step_target is the procedure of the child where the debugger sets
// its execute breakpoint. It is not put inside its caller, so the thread
// reaches its first instruction at each call.
child_step_target :: proc "contextless" () {
	intrinsics.volatile_store(&child_calls, intrinsics.volatile_load(&child_calls) + 1)
}

// hang_bound gives a deadline that only ends a hang.
hang_bound :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

// verdict counts a case and gives the end of its line.
verdict :: proc "contextless" (right: bool) -> string {
	if right {
		right_count += 1
		return ": as it must"
	}
	return ": WRONG"
}

// wait_until_at_least waits until a word of a shared page is at least a
// value. The bound only ends a hang.
wait_until_at_least :: proc "contextless" (word: ^u32, least: u32) -> bool {
	for deadline := hang_bound(); system.time() < deadline; {
		if intrinsics.atomic_load(word) >= least {
			return true
		}
		system.sleep(system.time() + 1)
	}
	return false
}

// wait_for_growth waits until a count of a shared page grew by an amount
// since the caller read it. The bound only ends a hang.
wait_for_growth :: proc "contextless" (word: ^u32, before: u32, amount: u32 = 1) -> bool {
	for deadline := hang_bound(); system.time() < deadline; {
		if intrinsics.atomic_load(word) - before >= amount {
			return true
		}
		system.sleep(system.time() + 1)
	}
	return false
}

// wait_for_stop waits until a process stopped, and says if it stopped
// itself with Done: its clean end. A trap flag that stayed in a thread
// would stop it with the cause Fault instead. The line of detail gives the
// stop. The bound only ends a hang.
wait_for_stop :: proc "contextless" (process: system.Handle, what: string) -> (clean: bool) {
	cause, outcome, stopped := system.process_stop_wait(process, hang_bound())
	if !stopped {
		system.log(.Info, "debugged: detail: ", what, " did not stop")
		return false
	}
	buffer: [64]u8
	stop_text := system.Writer{buffer = buffer[:]}
	system.stop_write(&stop_text, cause, outcome)
	system.log(.Info, "debugged: detail: ", what, " stopped: ", system.written(&stop_text))
	return outcome == .Done
}

// step_failed ends a child or a second debugger at a step that failed: the
// line names the step, and the stop says only that it failed.
step_failed :: proc "contextless" (role: string, step: string) -> ! {
	system.log(.Info, "debugged: ", role, ": ", step, " failed")
	system.stop(.Failed)
}

// child_worker is the second thread of a child of the mode With_Worker: it
// runs the procedure of the breakpoint in a loop, and counts its rounds.
child_worker :: proc "c" (parameter: rawptr) -> ! {
	shared := (^Shared)(parameter)
	intrinsics.atomic_store(&shared.worker_number, u32(system.thread_record().number))
	intrinsics.atomic_store(&shared.worker_ready, 1)
	for {
		#force_no_inline child_step_target()
		intrinsics.atomic_add(&shared.worker_rounds, 1)
		system.sleep(system.time() + 1)
	}
}

// child_run is a child that the parent debugs: it writes its known value
// and its addresses, then does the work of its mode.
child_run :: proc "contextless" (ctx: ^system.Context) -> ! {
	address, status := system.memory_map(ctx.handles[GRANT_SHARED], {.Write})
	if status != .Ok {
		step_failed("a child", "the map of the shared page")
	}
	shared := (^Shared)(address)
	mode, mode_ok := enum_word.member_of_word(Child_Mode, ctx.values[VALUE_MODE])
	if !mode_ok {
		system.log(.Info, "debugged: the context names the child mode ", ctx.values[VALUE_MODE], ", which names no mode")
		system.stop(.Refused)
	}
	intrinsics.volatile_store(&child_known_value, KNOWN_VALUE)
	intrinsics.volatile_store(&child_stack_selector, op.THREAD_STACK_SELECTOR)
	line := COPIED_LINE
	text := ([^]u8)(&child_watched_text)
	for index in 0 ..< len(line) {
		text[index] = line[index]
	}
	shared.target = u64(uintptr(rawptr(child_step_target)))
	shared.watched = u64(uintptr(&child_watched_word))
	shared.known = u64(uintptr(&child_known_value))
	shared.text = u64(uintptr(&child_watched_text))
	shared.selector = u64(uintptr(&child_stack_selector))
	worker: system.Thread
	if mode == .With_Worker {
		started: system.Status
		worker, started = system.thread_start(child_worker, shared)
		if started != .Ok || !wait_until_at_least(&shared.worker_ready, 1) {
			step_failed("a child", "the start of its second thread")
		}
	}
	intrinsics.atomic_store(&shared.ready, 1)
	switch mode {
	case .Rounds:
		// The debugger sets its first breakpoint before the loop starts.
		wait_until_at_least(&shared.go, 1)
		for round in 0 ..< u64(CHILD_ROUNDS) {
			#force_no_inline child_step_target()
			intrinsics.volatile_store(&child_watched_word, round + 1)
			intrinsics.atomic_add(&shared.rounds, 1)
		}
	case .Forever, .With_Worker:
		for {
			#force_no_inline child_step_target()
			intrinsics.atomic_add(&shared.rounds, 1)
			// The main thread holds its second thread, and releases it,
			// when the parent asks.
			command := intrinsics.atomic_load(&shared.command)
			if mode == .With_Worker && command != intrinsics.atomic_load(&shared.answered) {
				count: u64
				did: system.Status
				if command == 1 {
					count, did = system.thread_control_stop(worker.handle, 0)
				} else {
					count, did = system.thread_control_resume(worker.handle, 0)
				}
				intrinsics.atomic_store(&shared.status, u32(did))
				intrinsics.atomic_store(&shared.count, u32(count))
				intrinsics.atomic_store(&shared.answered, command)
			}
			system.sleep(system.time() + 1)
		}
	case .Kernel_Copy:
		// 1. The kernel copies the watched buffer: the call names the
		// buffer by its address, and no instruction of this process reads
		// it here.
		wait_until_at_least(&shared.go, 1)
		_, logged := system.call(.Log, u64(ctx.handles[op.CONTEXT_LOG]), shared.text, u64(len(COPIED_LINE)), u64(op.Log_Level.Info), 0)
		intrinsics.atomic_store(&shared.status, u32(logged))
		intrinsics.atomic_store(&shared.stage, 1)
		// 2. A read of the watched word by a load of the stack selector,
		// then a syscall.
		wait_until_at_least(&shared.go, 2)
		load_stack_selector_then_syscall(&child_stack_selector)
		intrinsics.atomic_store(&shared.stage, 2)
		// 3. A read of the buffer by this process: the breakpoint is on.
		wait_until_at_least(&shared.go, 3)
		intrinsics.volatile_store(&child_calls, intrinsics.volatile_load(&child_watched_text[0]))
		intrinsics.atomic_store(&shared.stage, 3)
	}
	system.stop(.Done)
}

// second_debugger attaches to the process of its context and stops its
// first thread at an execute breakpoint, then does what its mode says. It
// stops itself with `Done` at its end; a step that failed writes the
// line that names it and stops with `Failed`.
second_debugger :: proc "contextless" (ctx: ^system.Context) -> ! {
	ROLE :: "a second debugger"
	address, status := system.memory_map(ctx.handles[GRANT_SHARED], {.Write})
	if status != .Ok {
		step_failed(ROLE, "the map of the shared page")
	}
	shared := (^Shared)(address)
	mode, mode_ok := enum_word.member_of_word(Debugger_Mode, ctx.values[VALUE_MODE])
	if !mode_ok {
		system.log(.Info, "debugged: the context names the debugger mode ", ctx.values[VALUE_MODE], ", which names no mode")
		system.stop(.Refused)
	}
	target := ctx.handles[GRANT_TARGET]
	if system.debug_attach(target) != .Ok {
		step_failed(ROLE, "the attach")
	}
	if _, held := system.thread_control_stop(target, 0); held != .Ok {
		step_failed(ROLE, "the stop of the first thread of the child")
	}
	breakpoints: op.Thread_Breakpoints
	breakpoints.breakpoints[0] = {address = ctx.values[VALUE_ADDRESS], kind = .Execute}
	if system.thread_breakpoints_write(target, 0, breakpoints) != .Ok {
		step_failed(ROLE, "the write of the execute breakpoint")
	}
	if _, resumed := system.thread_control_resume(target, 0); resumed != .Ok {
		step_failed(ROLE, "the resume of the first thread of the child")
	}
	intrinsics.atomic_store(&shared.ready, 1)
	record, came := system.fault_record_next(hang_bound())
	if !came {
		step_failed(ROLE, "the wait for the record of the breakpoint")
	}
	if record.kind != u64(op.Fault_Kind.Debug) || record.error_code & 1 == 0 {
		step_failed(ROLE, "the check of the record of the breakpoint")
	}
	switch mode {
	case .Ends:
		// A stop of the debugger on top of the wait: the end takes it back too.
		if _, held := system.thread_control_stop(target, record.thread); held != .Ok {
			step_failed(ROLE, "the stop of the waiting thread")
		}
	case .Steps_Then_Ends:
		// One instruction, and no second write of the registers: the trap
		// flag of the debugger is still in the thread when the debugger ends.
		registers, read := system.thread_registers_read(target, record.thread)
		registers.rflags |= FLAG_TRAP
		if read != .Ok || system.thread_registers_write(target, record.thread, registers) != .Ok {
			step_failed(ROLE, "the write of the trap flag")
		}
		if system.debug_fault_answer(target, record) != .Ok {
			step_failed(ROLE, "the answer to the record of the breakpoint")
		}
		step, step_came := system.fault_record_next(hang_bound())
		if !step_came || step.kind != u64(op.Fault_Kind.Debug) || step.error_code & op.DEBUG_STATUS_STEP == 0 {
			step_failed(ROLE, "the wait for the record of the single step")
		}
	case .Closes_Its_Handle:
		system.close(target)
		intrinsics.atomic_store(&shared.stage, 1)
		for {
			system.sleep(system.time() + 1000)
		}
	case .Waits_To_Be_Revoked:
		intrinsics.atomic_store(&shared.stage, 1)
		for {
			system.sleep(system.time() + 1000)
		}
	}
	system.stop(.Done)
}

// parked is a thread of the parent that only waits: the parent names it by
// a thread handle with less rights.
parked :: proc "c" (parameter: rawptr) -> ! {
	for {
		system.sleep(system.time() + 1000)
	}
}

// shared_page_create makes the page that a child shares with the parent.
shared_page_create :: proc "contextless" () -> (memory: system.Handle, shared: ^Shared, ok: bool) {
	status: system.Status
	memory, status = system.memory_create(1)
	if status != .Ok {
		return 0, nil, false
	}
	address, mapped := system.memory_map(memory, {.Write})
	if mapped != .Ok {
		system.close(memory)
		return 0, nil, false
	}
	return memory, (^Shared)(address), true
}

// child_start starts a child of this module with a role and a mode.
child_start :: proc "contextless" (role: Role, mode: u64, shared_memory: system.Handle, target: system.Handle = 0, address: u64 = 0) -> (process: system.Handle, ok: bool) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = u64(role)
	values[VALUE_MODE] = mode
	values[VALUE_ADDRESS] = address
	grants[GRANT_SHARED] = {shared_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = {log_handle, {.Write}}
	if target != 0 {
		grants[GRANT_TARGET] = {target, {.Debug}}
	}
	error: module.Load_Error
	status: system.Status
	process, status = system.process_start(system.image_find(image, "debugged"), "debugged child", grants, random.values_with_seed(&process_generator, values), {pages = 256, processes = 1, threads = 2, processor = 200_000, log_records = 10}, nil, nil, {image = image}, &error)
	return process, status == .Ok
}

// A child with its shared page, and what the parent closes at the end.
Started_Child :: struct {
	process: system.Handle,
	memory:  system.Handle,
	shared:  ^Shared,
}

// child_with_page starts a child or a second debugger with a new shared
// page, and waits until it is ready when wait_ready is true.
child_with_page :: proc "contextless" (role: Role, mode: u64, wait_ready: bool, target: system.Handle = 0, address: u64 = 0) -> (child: Started_Child, ok: bool) {
	made: bool
	child.memory, child.shared, made = shared_page_create()
	if !made {
		system.log(.Info, "debugged: no shared page")
		return {}, false
	}
	started: bool
	child.process, started = child_start(role, mode, child.memory, target, address)
	if !started || wait_ready && !wait_until_at_least(&child.shared.ready, 1) {
		system.log(.Info, "debugged: a child did not start")
		system.close(child.memory)
		return {}, false
	}
	return child, true
}

// child_end stops a child that has no end of its own, and closes what the
// parent holds for it.
child_end :: proc "contextless" (child: Started_Child) {
	system.process_stop(child.process)
	system.close(child.process)
	system.close(child.memory)
}

// cases_of_one_child runs the cases 1 to 14 on one child that runs three
// rounds of its loop.
cases_of_one_child :: proc "contextless" () {
	started, made := child_with_page(.Child, u64(Child_Mode.Rounds), true)
	if !made {
		return
	}
	defer child_end(started)
	child, shared := started.process, started.shared
	target, watched, known := shared.target, shared.watched, shared.known
	error: errors.Error_Record

	// 1. The attach.
	attached := system.debug_attach(child)
	system.log(.Info, "debugged: attach: the debugger is the debug handler of the child", verdict(attached == .Ok))
	if attached != .Ok {
		system.log(.Info, "debugged: detail: the attach gave the status ", u64(attached))
		return
	}

	// 2. The thread of the child runs or sleeps: it is not held.
	breakpoints: op.Thread_Breakpoints
	breakpoints.breakpoints[0] = {address = target, kind = .Execute}
	not_held := system.thread_breakpoints_write(child, 0, breakpoints)
	system.log(.Info, "debugged: a write of breakpoints on a thread that is not held: refused with Bad_State", verdict(not_held == .Bad_State))

	// 3. A copy of the handle with no Debug.
	without_debug, copied := system.give(0, child, {.Read, .Control})
	attach_refused := system.debug_attach(without_debug)
	_, stop_refused := system.thread_control_stop(without_debug, 0)
	system.close(without_debug)
	system.log(.Info, "debugged: a handle with no Debug: attach and Stop refused with No_Right", verdict(copied == .Ok && attach_refused == .No_Right && stop_refused == .No_Right))

	// The first breakpoint: the thread is held, gets it, and goes on.
	_, held := system.thread_control_stop(child, 0)
	written := system.thread_breakpoints_write(child, 0, breakpoints)
	_, resumed := system.thread_control_resume(child, 0)
	if held != .Ok || written != .Ok || resumed != .Ok {
		system.log(.Info, "debugged: the first breakpoint was not set: the statuses ", u64(held), " ", u64(written), " ", u64(resumed))
		return
	}
	intrinsics.atomic_store(&shared.go, 1)

	// 5. The thread reaches the procedure.
	record, came := system.fault_record_next(hang_bound())
	reached := came && record.kind == u64(op.Fault_Kind.Debug) && record.error_code == 1 && record.instruction == target && record.thread == 0
	system.log(.Info, "debugged: detail: the record of the execute breakpoint: kind ", u64(record.kind), ", status ", system.Hex(record.error_code), ", instruction ", system.Hex(record.instruction), ", the procedure ", system.Hex(target))
	if !came {
		system.log(.Info, "debugged: an execute breakpoint at a procedure of the child: no record came: WRONG")
		return
	}

	// 4. The thread is held at its breakpoint: a breakpoint of the kernel
	// half is refused, and the breakpoints of the thread stay.
	hostile: op.Thread_Breakpoints
	hostile.breakpoints[0] = {address = KERNEL_ADDRESS, kind = .Execute}
	error = {}
	kernel_refused := system.thread_breakpoints_write(child, 0, hostile, &error)
	kept, _ := system.thread_breakpoints_read(child, 0)
	system.log(.Info, "debugged: a breakpoint at an address of the kernel: refused with the breakpoint address in the error record", verdict(kernel_refused == .Bad_Operation && error.found == i64(op.Thread_Write_Refusal.Breakpoint_Address) && u64(error.value) == KERNEL_ADDRESS && kept.breakpoints[0].address == target && kept.breakpoints[0].kind == .Execute))
	system.log(.Info, "debugged: an execute breakpoint at a procedure of the child: the fault record names breakpoint 0 and the address", verdict(reached))

	// 6. The registers at the stop.
	registers, read := system.thread_registers_read(child, 0)
	system.log(.Info, "debugged: the registers at the stop: the instruction address is the breakpoint", verdict(read == .Ok && registers.rip == target))

	// 7. to 9. The memory of the child.
	value: u64
	bytes := ([^]u8)(&value)[:8]
	count, memory_read := system.thread_memory_read(child, 0, known, bytes)
	system.log(.Info, "debugged: detail: the value of the child ", system.Hex(value), ", the copy of the debugger ", system.Hex(intrinsics.volatile_load(&child_known_value)))
	system.log(.Info, "debugged: Read_Memory of a value of the child: the bytes of the child, not of the debugger", verdict(memory_read == .Ok && count == 8 && value == KNOWN_VALUE && intrinsics.volatile_load(&child_known_value) == 0))
	_, kernel_read := system.thread_memory_read(child, 0, KERNEL_ADDRESS, bytes)
	system.log(.Info, "debugged: Read_Memory at an address of the kernel: refused with Bad_Address", verdict(kernel_read == .Bad_Address))
	_, unmapped_read := system.thread_memory_read(child, 0, UNMAPPED_ADDRESS, bytes)
	system.log(.Info, "debugged: Read_Memory of a page that the child does not map: refused with Bad_Address", verdict(unmapped_read == .Bad_Address))

	// 10. A thread handle with Inspect only sees the thread, and reads no
	// byte of its process.
	own, own_started := system.thread_start(parked, nil)
	inspect_only, narrowed := system.give(0, own.handle, {.Inspect})
	_, with_write := system.thread_memory_read(own.handle, 0, u64(uintptr(&child_known_value)), bytes)
	_, with_inspect := system.thread_memory_read(inspect_only, 0, u64(uintptr(&child_known_value)), bytes)
	system.log(.Info, "debugged: Read_Memory through a thread handle with Inspect only: refused with No_Right", verdict(own_started == .Ok && narrowed == .Ok && with_write == .Ok && with_inspect == .No_Right))

	// 11. A process writes no breakpoint on its own threads: not by the
	// number of a thread, and not by a thread handle with each right.
	_, own_held := system.thread_control_stop(own.handle, 0)
	by_number := system.thread_breakpoints_write(0, 1, breakpoints)
	by_handle := system.thread_breakpoints_write(own.handle, 0, breakpoints)
	system.thread_control_resume(own.handle, 0)
	system.log(.Info, "debugged: a write of breakpoints on a thread of the caller, with no Debug handle: refused with Bad_Handle", verdict(own_held == .Ok && by_number == .Bad_Handle && by_handle == .Bad_Handle))

	// 12. One instruction: the trap flag, then the answer.
	first: [1]u8
	system.thread_memory_read(child, 0, target, first[:])
	stepping := registers
	stepping.rflags |= FLAG_TRAP
	step_written := system.thread_registers_write(child, 0, stepping)
	step_answered := system.debug_fault_answer(child, record)
	step, step_came := system.fault_record_next(hang_bound())
	after, _ := system.thread_registers_read(child, 0)
	moved := after.rip > registers.rip && after.rip - registers.rip <= 15
	if first[0] == PUSH_FRAME_POINTER {
		// The instruction is one byte, and it moves the stack by 8.
		moved = after.rip == registers.rip + 1 && after.rsp == registers.rsp - 8
	}
	system.log(.Info, "debugged: detail: the step: status ", system.Hex(step.error_code), ", the instruction address from ", system.Hex(registers.rip), " to ", system.Hex(after.rip), ", the first byte ", system.Hex(u64(first[0])))
	system.log(.Info, "debugged: a single step: one instruction ran, and the record names the step", verdict(step_written == .Ok && step_answered == .Ok && step_came && step.kind == u64(op.Fault_Kind.Debug) && step.error_code & op.DEBUG_STATUS_STEP != 0 && moved))
	if !step_came {
		return
	}
	// The thread goes on with no trap flag.
	after.rflags &~= FLAG_TRAP
	system.thread_registers_write(child, 0, after)

	// 13. A data breakpoint, and no execute breakpoint.
	data: op.Thread_Breakpoints
	data.breakpoints[1] = {address = watched, kind = .Write, length = 8}
	data_written := system.thread_breakpoints_write(child, 0, data)
	system.debug_fault_answer(child, step)
	write, write_came := system.fault_record_next(hang_bound())
	system.thread_memory_read(child, 0, watched, bytes)
	system.log(.Info, "debugged: detail: the record of the data breakpoint: kind ", u64(write.kind), ", status ", system.Hex(write.error_code), ", the word of the child ", value)
	system.log(.Info, "debugged: a data breakpoint on a word that the child writes: the fault record names breakpoint 1", verdict(data_written == .Ok && write_came && write.kind == u64(op.Fault_Kind.Debug) && write.error_code == 2 && value == 1))
	if !write_came {
		return
	}

	// 14. No breakpoint: the child ends its rounds.
	none: op.Thread_Breakpoints
	removed := system.thread_breakpoints_write(child, 0, none)
	now, _ := system.thread_breakpoints_read(child, 0)
	system.debug_fault_answer(child, write)
	clean := wait_for_stop(child, "the child")
	system.log(.Info, "debugged: detail: the child ran ", u64(intrinsics.atomic_load(&shared.rounds)), " rounds")
	system.log(.Info, "debugged: the breakpoints removed: the child resumed and stopped itself at its end", verdict(removed == .Ok && now == none && clean && intrinsics.atomic_load(&shared.rounds) == CHILD_ROUNDS))
}

// second_debugger_case runs one second debugger on a child whose thread
// counts its rounds, and says if the child runs again after what the
// debugger, or the parent, did. revoke: the parent revokes the handle of
// the debugger when the thread of the child waits for it.
second_debugger_case :: proc "contextless" (child: Started_Child, mode: Debugger_Mode, revoke: bool) -> bool {
	debugger, made := child_with_page(.Second_Debugger, u64(mode), true, child.process, child.shared.target)
	if !made {
		return false
	}
	defer child_end(debugger)
	right := false
	if mode == .Ends {
		right = wait_for_stop(debugger.process, "the second debugger")
	} else {
		// The thread of the child waits at its breakpoint, and the debugger lives.
		right = wait_until_at_least(&debugger.shared.stage, 1)
		if revoke {
			ended, revoked := system.handle_revoke(child.process, debugger.process)
			system.log(.Info, "debugged: detail: the revocation ended ", ended, " holdings")
			right = right && revoked == .Ok && ended >= 1
		}
		state, _, _ := system.process_state(debugger.process)
		right = right && state != .Stopped
	}
	before := intrinsics.atomic_load(&child.shared.rounds)
	runs := wait_for_growth(&child.shared.rounds, before)
	state, _, _ := system.process_state(child.process)
	return right && runs && state != .Stopped
}

// cases_of_the_end runs the cases 15 to 18 on one child whose loop has no
// end: what a debugger held comes back when the debugging ends.
cases_of_the_end :: proc "contextless" () {
	child, made := child_with_page(.Child, u64(Child_Mode.Forever), true)
	if !made {
		return
	}
	defer child_end(child)

	// 15. The thread is held, so its count of rounds stays; the detach
	// lets it count again.
	attached := system.debug_attach(child.process)
	_, held := system.thread_control_stop(child.process, 0)
	before := intrinsics.atomic_load(&child.shared.rounds)
	detached := system.debug_detach(child.process)
	runs := wait_for_growth(&child.shared.rounds, before)
	system.log(.Info, "debugged: a detach while a thread is held: the child runs again", verdict(attached == .Ok && held == .Ok && detached == .Ok && runs))

	// 16. to 18. Another process debugs the child, and its debugging ends
	// in three ways while the thread of the child waits at its breakpoint.
	system.log(.Info, "debugged: the debugger ended while the child was held at a breakpoint: the child runs again", verdict(second_debugger_case(child, .Ends, false)))
	system.log(.Info, "debugged: the debugger closed its handle while the child was held at a breakpoint: the child runs again", verdict(second_debugger_case(child, .Closes_Its_Handle, false)))
	system.log(.Info, "debugged: the handle of the debugger was revoked while the child was held at a breakpoint: the child runs again", verdict(second_debugger_case(child, .Waits_To_Be_Revoked, true)))
}

// case_of_the_step_then_the_end runs the case 19: a second debugger runs
// one instruction of the child and ends at the record of the step, with
// its trap flag still in the thread. The child must run its rounds and
// stop itself: a trap flag that stayed would stop it with the cause Fault
// of a debug exception.
case_of_the_step_then_the_end :: proc "contextless" () {
	child, made := child_with_page(.Child, u64(Child_Mode.Rounds), true)
	if !made {
		return
	}
	defer child_end(child)
	debugger, debugger_made := child_with_page(.Second_Debugger, u64(Debugger_Mode.Steps_Then_Ends), true, child.process, child.shared.target)
	if !debugger_made {
		return
	}
	defer child_end(debugger)
	// The breakpoint of the debugger is set: the child starts its loop.
	intrinsics.atomic_store(&child.shared.go, 1)
	debugger_clean := wait_for_stop(debugger.process, "the debugger that steps")
	clean := wait_for_stop(child.process, "the child")
	system.log(.Info, "debugged: a single step, then the end of the debugger: the child ran to its own end", verdict(debugger_clean && clean && intrinsics.atomic_load(&child.shared.rounds) == CHILD_ROUNDS))
}

// cases_of_two_threads runs the cases 20 and 21 on a child with two
// threads that run the same procedure.
cases_of_two_threads :: proc "contextless" () {
	started, made := child_with_page(.Child, u64(Child_Mode.With_Worker), true)
	if !made {
		return
	}
	defer child_end(started)
	child, shared := started.process, started.shared
	worker := u64(intrinsics.atomic_load(&shared.worker_number))

	// 20. The breakpoint is of the first thread: it stops there, and the
	// second thread goes on through the same instruction.
	attached := system.debug_attach(child)
	_, held := system.thread_control_stop(child, 0)
	breakpoints: op.Thread_Breakpoints
	breakpoints.breakpoints[0] = {address = shared.target, kind = .Execute}
	written := system.thread_breakpoints_write(child, 0, breakpoints)
	_, resumed := system.thread_control_resume(child, 0)
	record, came := system.fault_record_next(hang_bound())
	before := intrinsics.atomic_load(&shared.worker_rounds)
	other_runs := wait_for_growth(&shared.worker_rounds, before, 2)
	system.log(.Info, "debugged: a breakpoint of one thread: that thread stops, and another thread of the child runs through the same procedure", verdict(attached == .Ok && held == .Ok && written == .Ok && resumed == .Ok && came && record.thread == 0 && record.error_code == 1 && other_runs))
	if !came {
		return
	}
	none: op.Thread_Breakpoints
	system.thread_breakpoints_write(child, 0, none)
	system.debug_fault_answer(child, record)

	// 21. The child stops its second thread itself; the debugger stops it
	// too, and detaches. The stop of the child stays: its own Resume finds
	// it, and gives the count 0.
	intrinsics.atomic_store(&shared.command, 1)
	own_stop := wait_until_at_least(&shared.answered, 1) && intrinsics.atomic_load(&shared.status) == u32(system.Status.Ok)
	count, debugger_stop := system.thread_control_stop(child, worker)
	detached := system.debug_detach(child)
	intrinsics.atomic_store(&shared.command, 2)
	own_resume := wait_until_at_least(&shared.answered, 2)
	resume_status := intrinsics.atomic_load(&shared.status) // The word that the child wrote: it is compared, never read as a status.
	resume_count := intrinsics.atomic_load(&shared.count)
	system.log(.Info, "debugged: detail: the stop of the debugger gave the count ", count, "; the Resume of the child gave the status ", u64(resume_status), " and the count ", u64(resume_count))
	system.log(.Info, "debugged: a stop of the child on its own thread, then a stop and a detach of the debugger: the thread is still held by the stop of the child", verdict(own_stop && debugger_stop == .Ok && count == 2 && detached == .Ok && own_resume && resume_status == u32(system.Status.Ok) && resume_count == 0))
}

// cases_of_the_kernel_copy runs the cases 22 and 23: data breakpoints of
// the child on memory that the kernel reads for it.
cases_of_the_kernel_copy :: proc "contextless" () {
	started, made := child_with_page(.Child, u64(Child_Mode.Kernel_Copy), true)
	if !made {
		return
	}
	defer child_end(started)
	child, shared := started.process, started.shared
	own := system.thread_record()
	attached := system.debug_attach(child)
	_, held := system.thread_control_stop(child, 0)
	breakpoints: op.Thread_Breakpoints
	breakpoints.breakpoints[0] = {address = shared.text, kind = .Read_Or_Write, length = 8}
	breakpoints.breakpoints[1] = {address = shared.selector, kind = .Read_Or_Write, length = 2}
	written := system.thread_breakpoints_write(child, 0, breakpoints)
	_, resumed := system.thread_control_resume(child, 0)
	if attached != .Ok || held != .Ok || written != .Ok || resumed != .Ok {
		system.log(.Info, "debugged: the data breakpoints were not set: the statuses ", u64(attached), " ", u64(held), " ", u64(written), " ", u64(resumed))
		return
	}

	// 22. The kernel copies the watched buffer for the operation Log: the
	// operation gives Ok, the machine goes on, and the debugger gets no
	// record: the kernel drops a debug exception of its own copy.
	intrinsics.atomic_store(&shared.go, 1)
	copied := wait_until_at_least(&shared.stage, 1)
	no_record := intrinsics.atomic_load(&own.fault_written) == 0
	logged := intrinsics.atomic_load(&shared.status) // The word that the child wrote: it is compared, never read as a status.

	// 23. The load of the stack selector reads the watched word, and the
	// next instruction is a syscall. The trap comes to the debugger, or
	// the processor holds it until the first instruction of the kernel,
	// which drops it: the line of detail says which. The kernel entry
	// returns in both.
	intrinsics.atomic_store(&shared.go, 2)
	came_to_the_debugger := false
	entered := false
	for deadline := hang_bound(); system.time() < deadline; {
		if record, came := system.fault_record_next(system.time() + 1); came {
			came_to_the_debugger = record.kind == u64(op.Fault_Kind.Debug) && record.error_code & 2 != 0
			system.debug_fault_answer(child, record)
		}
		if intrinsics.atomic_load(&shared.stage) >= 2 {
			entered = true
			break
		}
	}

	// The read of the buffer by the child itself: the breakpoint was on
	// during the copy of the kernel.
	intrinsics.atomic_store(&shared.go, 3)
	read, read_came := system.fault_record_next(hang_bound())
	if read_came {
		system.debug_fault_answer(child, read)
	}
	clean := wait_for_stop(child, "the child")
	system.log(.Info, "debugged: detail: Log gave the status ", u64(logged), "; the record of the read of the child: status ", system.Hex(read.error_code))
	system.log(.Info, "debugged: a data breakpoint on a buffer that the kernel copies: the operation succeeded, no record came for the copy, and the read of the child came", verdict(copied && logged == u32(system.Status.Ok) && no_record && read_came && read.kind == u64(op.Fault_Kind.Debug) && read.error_code & 1 != 0 && clean))
	system.log(.Info, "debugged: detail: the trap of the load of the stack selector ", came_to_the_debugger ? string("came to the debugger before the syscall") : string("was held until the kernel entry, and the kernel dropped it"))
	system.log(.Info, "debugged: a data breakpoint that a load of the stack selector holds before a syscall: the kernel entry returned", verdict(entered && clean))
}

// case_of_the_full_ring runs the case 24. The debugger answers each
// record and never says that it read one: after
// op.FAULT_RECORD_CAPACITY records its ring is full. The thread of the
// child then goes on through its breakpoint with no record; when the
// debugger says that it read the records, the next one comes.
case_of_the_full_ring :: proc "contextless" () {
	started, made := child_with_page(.Child, u64(Child_Mode.Forever), true)
	if !made {
		return
	}
	defer child_end(started)
	child, shared := started.process, started.shared
	own := system.thread_record()
	attached := system.debug_attach(child)
	_, held := system.thread_control_stop(child, 0)
	breakpoints: op.Thread_Breakpoints
	breakpoints.breakpoints[0] = {address = shared.target, kind = .Execute}
	written := system.thread_breakpoints_write(child, 0, breakpoints)
	_, resumed := system.thread_control_resume(child, 0)
	filled := attached == .Ok && held == .Ok && written == .Ok && resumed == .Ok
	for index in 0 ..< u32(op.FAULT_RECORD_CAPACITY) {
		if !filled || !wait_until_at_least(&own.fault_written, index + 1) {
			filled = false
			break
		}
		// The record is read in place, and fault_read stays 0.
		record := own.fault_records[index]
		filled = record.kind == u64(op.Fault_Kind.Debug) && system.debug_fault_answer(child, record) == .Ok
	}
	// The ring is full: the child counts its rounds, and no record comes.
	before := intrinsics.atomic_load(&shared.rounds)
	goes_on := filled && wait_for_growth(&shared.rounds, before, 2)
	lost := wait_until_at_least(&own.fault_full, 1)
	no_record := intrinsics.atomic_load(&own.fault_written) == op.FAULT_RECORD_CAPACITY
	// The debugger read each record: the ring has room again.
	intrinsics.atomic_store(&own.fault_read, op.FAULT_RECORD_CAPACITY)
	comes_again := wait_until_at_least(&own.fault_written, op.FAULT_RECORD_CAPACITY + 1)
	detached := system.debug_detach(child)
	system.log(.Info, "debugged: detail: the faults that found the ring full: ", u64(intrinsics.atomic_load(&own.fault_full)))
	system.log(.Info, "debugged: a full ring of the debugger: the breakpoint is lost for the debugger, the child goes on, and a record comes again when the ring has room", verdict(goes_on && lost && no_record && comes_again && detached == .Ok))
}

// The entry of debugged. The context value `VALUE_ROLE` chooses the role:
//
// - `Child`: the process that is debugged (`child_run`).
// - `Second_Debugger`: a debugger whose debugging ends while its process
//   waits at a breakpoint (`second_debugger`).
// - `Parent` (0, as the root service starts it): it takes its random
//   generator and maps the boot image (no seed stops it with `Refused`, no
//   image with `Failed`), runs the cases, writes the result on the log, and
//   then waits for ever.
//
// A role or a mode word that names no member stops it with `Refused`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	role, role_ok := enum_word.member_of_word(Role, ctx.values[VALUE_ROLE])
	if !role_ok {
		system.log(.Info, "debugged: the context names the role ", ctx.values[VALUE_ROLE], ", which names no role")
		system.stop(.Refused)
	}
	switch role {
	case .Child:
		child_run(ctx)
	case .Second_Debugger:
		second_debugger(ctx)
	case .Parent:
	}
	if !random.generator_from_context(&process_generator, ctx) {
		system.log(.Info, "debugged: no random seed in the context")
		system.stop(.Refused)
	}
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		system.log(.Info, "debugged: no boot image")
		system.stop(.Failed)
	}
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	log_handle = ctx.handles[op.CONTEXT_LOG]
	cases_of_one_child()
	cases_of_the_end()
	case_of_the_step_then_the_end()
	cases_of_two_threads()
	cases_of_the_kernel_copy()
	case_of_the_full_ring()
	if right_count == CASE_COUNT {
		system.log(.Info, "debugged: ok, ", u64(CASE_COUNT), " cases: a debugger holds, reads and steps one process, and its end gives the process back")
	} else {
		system.log(.Info, "debugged: failed: ", u64(CASE_COUNT - right_count), " cases of ", u64(CASE_COUNT))
	}
	for {
		system.sleep(system.time() + 1000)
	}
}
