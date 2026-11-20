// The return to a process, with hostile threads (docs/ARCHITECTURE.md, "The
// return to a process").
//
// The kernel returns to a thread with iretq. A thread whose saved state the
// processor refuses there made the processor fault in the kernel, and one
// process stopped the machine. Each case of this process starts a child
// process (this module, with a role) that gives the kernel such a thread.
// The kernel must stop that child as its own fault, or return to it with a
// state that a process may have; the machine goes on, and the next case
// runs.
//
//   1. A syscall in the last two bytes below the half of a process: its
//      return address is 2^47, which is not canonical. The thread holds
//      values in the high halves of its ymm registers when the kernel stops
//      it, so a switch saves them.
//   2. A stack address that is not canonical, held in rsp while the thread
//      waits for the timer.
//   3. The flag nested task, set with popfq before a syscall: the kernel
//      clears it for itself, and the process gets its flags back without it.
//   4. The trap flag, set with popfq right before a syscall: the kernel
//      clears it for itself, takes no trap, and gives it back; the trap then
//      comes in the process, after its first instruction: its own fault.
//   5. A stack address that is not canonical, held at a syscall: the entry
//      saves it without a use of it, and the return refuses it.
//
// **What it is for.** It is the regression test of a fault of the kernel
// that let one process stop the machine. Each case is a hostile
// state that the return of the kernel once trusted; the machine must go on
// after each one.
//
// **Start**: `start("return_fault")` in the console, or the bar of the
// desktop. The parent starts each child from the boot image, one at a time:
// its budget has room for two processes.
//
// **Grants**, as the root service gives them:
//
// - **Image**: the boot image, read-only, to start the children from it.
//
// **What a reader sees**: one row for each case, with the stop cause and
// the stop report of the child. The log has "return_fault: ok, 5 cases: each
// child stopped as its own fault or returned with the flags of a process,
// and the machine goes on", or "return_fault: failed: N cases of 5".
//
// The design: (docs/ARCHITECTURE.md, "The return to a process").
package return_fault

import "modus:contract/enum_word"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:support/display"
import "modus:support/graphics"
import sets "modus:support/instruction_sets"
import "modus:support/interface"
import "modus:support/random"
import "modus:support/system"

// One child at a time, with one thread: 1353 pages. And the glyph memory
// of the copy of the text rendering of the drawing module, which draws its
// text: 354 pages (display.TEXT_MEMORY_PAGES). 1353 + 354 = 1707.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1707, processes = 2, threads = 2, window_width = WIDTH, window_height = HEIGHT}

LINE :: interface.TABLE_LINE
WIDTH :: 896
HEIGHT :: 320

// The value of the context that gives the role of a child. Not the value 0:
// the root service writes there the size of the boot image of the grant
// Image, which the parent holds, so a role there would read a size.
VALUE_ROLE :: 7
VALUE_WITH_AVX :: 1 // 1: the child of the instruction address holds ymm values.

// The last page below the half of a process, and the address of its last
// two bytes.
LAST_PAGE :: u64(op.USER_END) - system.PAGE_SIZE
LAST_INSTRUCTION :: u64(op.USER_END) - 2

Role :: enum u64 {
	Parent              = 0,
	Instruction_Address = 1,
	Stack_Address       = 2,
	Nested_Task         = 3,
	Trap_Flag           = 4,
	Stack_At_A_Syscall  = 5,
}

foreign _ {
	jump_to_the_last_instruction :: proc "c" (address: rawptr, with_avx: bool) -> ! ---
	spin_with_a_stack_that_is_not_canonical :: proc "c" () -> ! ---
	syscall_with_nested_task :: proc "c" (before: ^u64) -> u64 ---
	syscall_with_the_trap_flag :: proc "c" () -> u64 ---
	syscall_with_a_stack_that_is_not_canonical :: proc "c" () -> ! ---
}

// One case: what the child gave, and if it is what the kernel must give.
Case :: struct {
	name:      string,
	role:      Role,
	ran:       bool,
	right:     bool,
	cause:     op.Stop_Cause, // The stop cause of the child.
	outcome:   op.Stop_Outcome, // Its stop outcome, when it stopped itself.
	vector:    u32, // The vector of its stop report.
	address:   u64, // The address of its stop report.
}

cases := [5]Case {
	{name = "the instruction address after the last page", role = .Instruction_Address},
	{name = "a stack address that is not canonical", role = .Stack_Address},
	{name = "the flag nested task at a syscall", role = .Nested_Task},
	{name = "the trap flag at a syscall", role = .Trap_Flag},
	{name = "a stack address that is not canonical at a syscall", role = .Stack_At_A_Syscall},
}

process_generator: random.Generator
image: []u8
with_avx: bool

window_memory: interface.Window_Memory(256, 4096)

// child_instruction_address writes a syscall in the last two bytes of an
// object, maps the object with Execute at the last page below the half of a
// process, and jumps there.
child_instruction_address :: proc "contextless" (holds_ymm: bool) -> ! {
	memory, created := system.memory_create(1)
	if created != .Ok {
		system.log_fact(.Info, Instruction_Page_Not_Made{status = created})
		system.stop(.Failed)
	}
	address, mapped := system.memory_map(memory, {.Write})
	if mapped != .Ok {
		system.log_fact(.Info, Instruction_Page_Not_Mapped_To_Write{status = mapped})
		system.stop(.Failed)
	}
	page := ([^]u8)(address)
	page[system.PAGE_SIZE - 2] = 0x0F // syscall
	page[system.PAGE_SIZE - 1] = 0x05
	system.memory_unmap(address)
	if _, at_the_end := system.memory_map(memory, {.Execute}, 0, LAST_PAGE); at_the_end != .Ok {
		system.log_fact(.Info, Instruction_Page_Not_Mapped_At_End{status = at_the_end})
		system.stop(.Failed)
	}
	jump_to_the_last_instruction(rawptr(uintptr(LAST_INSTRUCTION)), holds_ymm)
}

// child_nested_task stops with Done when the flag was set before the entry
// and clear after it. Else it writes what it saw, and stops with Failed:
// the stop says only right or wrong, the line says why.
child_nested_task :: proc "contextless" () -> ! {
	NESTED_TASK :: u64(1) << 14
	before: u64
	after := syscall_with_nested_task(&before)
	switch {
	case before & NESTED_TASK == 0:
		system.log(.Info, "return_fault: the child of the nested task: popfq did not set the flag, so the case did not run")
		system.stop(.Failed)
	case after & NESTED_TASK != 0:
		system.log(.Info, "return_fault: the child of the nested task: the flag came back after the entry")
		system.stop(.Failed)
	}
	system.stop(.Done)
}

// case_run starts the child of a case, waits for its stop, and reads its
// stop cause, its stop outcome and its stop report.
case_run :: proc "contextless" (item: ^Case) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = u64(item.role)
	values[VALUE_WITH_AVX] = with_avx ? 1 : 0
	error: module.Load_Error
	process, status := system.process_start(system.image_find(image, "return_fault"), "return_fault child", grants, random.values_with_seed(&process_generator, values), {pages = 256, processes = 1, threads = 1, processor = 200_000, log_records = 10}, nil, nil, {image = image}, &error)
	if status != .Ok {
		system.log_fact(.Info, Child_Not_Started{case_name = case_field(item.name)})
		return
	}
	defer system.close(process)
	// The bound only ends a hang.
	cause, outcome, _ := system.process_stop_wait(process, system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	report := system.process_stop_report(process)
	item.ran = true
	item.cause = cause
	item.outcome = outcome
	item.vector = report.vector
	item.address = report.address
	switch item.role {
	case .Instruction_Address:
		item.right = cause == .Cannot_Return && report.address == u64(op.USER_END)
	case .Stack_Address:
		item.right = cause == .Cannot_Return && report.address == 0x8000_0000_0000_0000
	case .Nested_Task:
		item.right = outcome == .Done
	case .Trap_Flag:
		// A debug exception of the process stops it as its own fault.
		item.right = cause == .Fault && report.vector == u32(op.Fault_Kind.Debug)
	case .Stack_At_A_Syscall:
		item.right = cause == .Cannot_Return && report.address == 0x8000_0000_0000_0000
	case .Parent:
	}
	verdict := item.right ? string(": as it must") : string(": WRONG")
	switch cause {
	case .Itself:
		system.log(.Info, "return_fault: ", item.name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], ", the address ", system.Hex(item.address), verdict)
	case .Fault:
		system.log(.Info, "return_fault: ", item.name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", vector ", u64(report.vector), ", the address ", system.Hex(item.address), verdict)
	case .None, .Holder, .Last_Thread_Ended, .Handles_Closed, .Not_Committed, .Cannot_Return, .Fault_Unanswered:
		system.log(.Info, "return_fault: ", item.name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", the address ", system.Hex(item.address), verdict)
	}
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE RETURN TO A PROCESS", "each child gives the kernel a thread that the processor would refuse at iretq", graphics.colors.kernel)
	column := interface.column_of(content)
	builder: interface.Text_Builder
	for &item in cases {
		builder.count = 0
		color: graphics.Color = graphics.colors.dim
		if !item.ran {
			interface.text_put(&builder, "not run yet")
		} else {
			interface.text_put(&builder, item.right ? "stopped as its own fault, or returned clean; the machine goes on" : "WRONG: see the log")
			color = item.right ? graphics.colors.process : graphics.colors.failed
		}
		// The answer is a sentence, wider than its box: it has the lines
		// that it needs, and the next case starts under them.
		interface.label_value_lines(&frame, &column, item.name, interface.text_of(&builder), 400, color, LINE)
	}
	interface.column_take(&column, 8)
	interface.cell_text(&frame, interface.column_take(&column, LINE), with_avx ? "the child of the instruction address holds values in the high halves of ymm0 to ymm15" : "no AVX here: the child of the instruction address holds no ymm values", graphics.colors.dim)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// The entry of return_fault: a child runs its one hostile case; the parent
// runs the five cases and shows them.
//
// The context value `VALUE_ROLE` chooses the role:
//
// - a role of a case: the child makes its hostile state at once. It never
//   comes back here: the kernel stops it as its own fault, or it stops
//   itself. The child of the trap flag writes a line and stops with
//   `Failed` when no trap came.
// - `Parent` (0, as the root service starts it): it takes its random
//   generator, opens its window and maps the boot image (no seed stops it
//   with `Refused`, a window or an image that fails with `Failed`), runs
//   each case with `case_run`, writes the result on the log, and then
//   draws its window for ever.
//
// A role word that names no role stops it with `Refused`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	role, role_ok := enum_word.member_of_word(Role, ctx.values[VALUE_ROLE])
	if !role_ok {
		system.log_fact(.Info, Role_Word_Unknown{role = ctx.values[VALUE_ROLE]})
		system.stop(.Refused)
	}
	switch role {
	case .Instruction_Address:
		child_instruction_address(ctx.values[VALUE_WITH_AVX] != 0)
	case .Stack_Address:
		spin_with_a_stack_that_is_not_canonical()
	case .Nested_Task:
		child_nested_task()
	case .Trap_Flag:
		syscall_with_the_trap_flag()
		system.log(.Info, "return_fault: the child of the trap flag: no trap came")
		system.stop(.Failed)
	case .Stack_At_A_Syscall:
		syscall_with_a_stack_that_is_not_canonical()
	case .Parent:
	}
	if !random.generator_from_context(&process_generator, ctx) {
		system.log(.Info, "return_fault: no random seed in the context")
		system.stop(.Refused)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "return_fault")
	if !ok {
		system.stop(.Failed)
	}
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		system.log(.Info, "return_fault: no boot image")
		system.stop(.Failed)
	}
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	with_avx = .Avx in sets.usable_instruction_sets()
	draw(&window)
	right := 0
	for &item in cases {
		case_run(&item)
		if item.right {
			right += 1
		}
		draw(&window)
	}
	if right == len(cases) {
		system.log_fact(.Info, Cases_Passed{cases = u64(len(cases))})
	} else {
		system.log_fact(.Info, Cases_Failed{failed = u64(len(cases) - right), cases = u64(len(cases))})
	}
	for {
		draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&window_memory.drawing, &window)
	}
}
