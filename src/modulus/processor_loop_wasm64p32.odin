package kernel

// The processor loop of a browser machine (src/md/features/browser_machine.md,
// "The processor loop"), and the names that processor.asm defines on x86-64
// (processor_assembly_amd64.odin).
//
// On hardware, resume ends in iretq and stack_switch moves to the top of the
// kernel stack: neither returns. WebAssembly has no instruction that drops
// the frames of its stack, so each one writes what the worker runs next and
// calls an import of the page that throws. The worker catches it, sets the
// shadow stack pointer back to the top of the stack of its processor, and
// calls modus_processor_loop_run again.

import "base:intrinsics"
import software "modus:contract/software_machine"
import "modulus:software_exit"

#assert(!KERNEL_EDGE_COUNTERS, "the counted kernel counts the edges of the build for x86-64 only")

foreign import page_loop "modus_page"

@(default_calling_convention = "contextless")
foreign page_loop {
	// Throws to the worker: the end of each path that does not return.
	page_processor_loop_unwind :: proc() -> ! ---
	// Ends the worker of this processor for good: the machine stopped.
	page_processor_stop :: proc() -> ! ---
	// Suspends the worker until a message of the page or the bound.
	page_idle_wait :: proc(bound_nanoseconds: i64) ---
}

// What the worker runs at its next call of modus_processor_loop_run.
Processor_Loop_Next :: enum u32 {
	None       = 0, // Nothing: the processor has no thread and no entry.
	Run_Frame  = 1, // Run the software processor from processor_loop_frame.
	Call_Entry = 2, // Call processor_loop_entry on a fresh stack.
}

// What modus_processor_loop_run gives the worker. The values cross to the
// page, so they are fixed.
Processor_Loop_Result :: enum u32 {
	Idle              = 0, // Nothing to run: the worker waits for a message or a deadline.
	Kernel_Returned   = 1, // The kernel path of an exit returned: call again.
	Budget_Refused    = 2, // A step budget of 0, or past the bound of the software processor.
}

// The bound of one idle wait: one tick of the kernel, in nanoseconds. A
// wake of another processor ends the wait earlier.
IDLE_WAIT_BOUND_NANOSECONDS :: i64(1_000_000_000 / TICKS_PER_SECOND)

// One word for each processor, in the shared memory: another worker or a
// device model writes it and notifies, and the idle wait waits on it.
pending_vector_words: [PROCESSOR_CAPACITY]u32

@(thread_local)
processor_loop_next: Processor_Loop_Next
@(thread_local)
processor_loop_frame: Frame
@(thread_local)
processor_loop_entry: proc "c" () -> !

// The names of processor.asm that the kernel reads as data. user_access_guard
// stays 0: the kernel of a browser machine never reaches the memory of a
// process at its own addresses (user_copy). The labels exist only for the
// comparisons of the fault path: no instruction of WebAssembly is at them.
user_access_guard: u8
interrupt_stubs: [STUB_COUNT]u64
resume_return: u8
model_specific_register_trial_read_instruction: u8
model_specific_register_trial_write_instruction: u8
model_specific_register_trial_refused: u8

// resume runs the process of the frame at the next call of the loop.
resume :: proc "c" (frame: ^Frame) -> ! {
	processor_loop_frame = frame^
	processor_loop_next = .Run_Frame
	page_processor_loop_unwind()
}

// stack_switch calls the entry at the next call of the loop, on the fresh
// shadow stack that the worker sets: the top of the kernel stack is not a
// stack of WebAssembly.
stack_switch :: proc "c" (top: u64, entry: rawptr) -> ! {
	processor_loop_entry = (proc "c" () -> !)(entry)
	processor_loop_next = .Call_Entry
	page_processor_loop_unwind()
}

processor_stop :: proc "c" () -> ! {
	page_processor_stop()
}

// The idle wait sleeps on the word of this processor, bounded by one tick,
// in the place of sti and hlt. A build with no atomics has no shared
// memory and one processor: its idle wait is an import that suspends the
// worker, so the worker gives the browser its events while it waits
// (browser_machine.md, "Several processors as workers").
idle_wait :: proc "c" () {
	when intrinsics.has_target_feature("atomics") {
		word := &pending_vector_words[processor_self().index]
		_ = intrinsics.wasm_memory_atomic_wait32(word, 0, IDLE_WAIT_BOUND_NANOSECONDS)
	} else {
		page_idle_wait(IDLE_WAIT_BOUND_NANOSECONDS)
	}
}

// An interrupt waits for the next exit of the software processor: the
// kernel runs each entry to its end, as with interrupts off.
interrupt_window :: proc "c" () {
}

// WebAssembly has no segments: the table that the kernel builds stays in
// memory, and nothing loads it.
gdt_load :: proc "c" (descriptor: rawptr) {
}

// The address that the kernel writes to MSR_LSTAR. The software processor
// exits on syscall; it never jumps there.
kernel_enter :: proc "c" () {
	intrinsics.trap()
}

// The extended state of a thread, in the legacy area of fxsave: the x87
// control word at offset 0, MXCSR at 24 and xmm0 to xmm15 from 160. The
// software processor holds the SSE registers only, so each form moves the
// same bytes.
EXTENDED_STATE_CONTROL_WORD_OFFSET :: 0
EXTENDED_STATE_MXCSR_OFFSET :: 24
EXTENDED_STATE_XMM_OFFSET :: 160

extended_state_save :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) {
	for index in 0 ..< len(software_processor.xmm) {
		start := EXTENDED_STATE_XMM_OFFSET + index * 16
		copy(area.bytes[start:start + 16], software_processor.xmm[index][:])
	}
}

extended_state_restore :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) {
	for &register, index in software_processor.xmm {
		start := EXTENDED_STATE_XMM_OFFSET + index * 16
		copy(register[:], area.bytes[start:start + 16])
	}
}

// The restore, then the read of the x87 control word, MXCSR and the low 8
// bytes of xmm0. The software processor has no AVX, so the fourth word is 0.
extended_state_restore_and_read :: proc "c" (area: ^Extended_State_Area, read: ^[4]u64, with_avx: bool, form: Extended_State_Form) {
	extended_state_restore(area, form)
	control_word := (^u16le)(&area.bytes[EXTENDED_STATE_CONTROL_WORD_OFFSET])^
	mxcsr := (^u32le)(&area.bytes[EXTENDED_STATE_MXCSR_OFFSET])^
	xmm0_low := (^u64le)(&software_processor.xmm[0][0])^
	read^ = {u64(control_word), u64(mxcsr), u64(xmm0_low), 0}
}

// No path reaches it: the answer of cpuid names no SVM, so the support of
// guests refuses each Guest_Run with Unsupported (guest.odin).
guest_enter :: proc "c" (control_block: u64, general: ^Guest_General_Registers, host_area: u64) {
	intrinsics.trap()
}

// A register trial on a browser machine: the register file refuses what
// the processor refuses with a protection fault. An address that is not
// canonical in a base register is the one refusal that the kernel tries.
@(private = "file")
model_specific_register_is_base :: proc "contextless" (index: u32) -> bool {
	MSR_FS_BASE :: 0xC000_0100
	return index == MSR_FS_BASE || index == MSR_GS_BASE || index == MSR_KERNEL_GS_BASE
}

model_specific_register_trial_read :: proc "c" (index: u32, value: ^u64) -> bool {
	value^ = model_specific_register_read(index)
	return true
}

model_specific_register_trial_write :: proc "c" (index: u32, value: u64) -> bool {
	if model_specific_register_is_base(index) && !software.is_canonical_virtual_address(value) {
		return false
	}
	model_specific_register_write(index, value)
	return true
}

// The vector of the frame of the kernel for each exit: the vector of the
// processor for an exception, the vector of the kernel entry for syscall,
// and the vector of the timer for the end of a slice.
@(private = "file")
exit_vector :: proc "contextless" (exit: software_exit.Exit) -> u64 {
	switch exit.kind {
	case .Kernel_Enter:
		return VECTOR_KERNEL_ENTER
	case .Slice_End:
		return VECTOR_TIMER
	case .Exception:
		return u64(exit.vector)
	}
	unreachable()
}

@(private = "file")
frame_to_software_processor :: proc "contextless" (frame: ^Frame) {
	cpu := &software_processor
	cpu.registers = {
		frame.rax, frame.rcx, frame.rdx, frame.rbx, frame.rsp, frame.rbp, frame.rsi, frame.rdi,
		frame.r8, frame.r9, frame.r10, frame.r11, frame.r12, frame.r13, frame.r14, frame.r15,
	}
	cpu.rip = frame.rip
	cpu.rflags = frame.rflags
	cpu.outcome = .Running
}

@(private = "file")
software_processor_to_frame :: proc "contextless" (frame: ^Frame, exit: software_exit.Exit) {
	cpu := &software_processor
	r := &cpu.registers
	frame.rax, frame.rcx, frame.rdx, frame.rbx = r[0], r[1], r[2], r[3]
	frame.rsp, frame.rbp, frame.rsi, frame.rdi = r[4], r[5], r[6], r[7]
	frame.r8, frame.r9, frame.r10, frame.r11 = r[8], r[9], r[10], r[11]
	frame.r12, frame.r13, frame.r14, frame.r15 = r[12], r[13], r[14], r[15]
	frame.rip = cpu.rip
	frame.rflags = cpu.rflags
	frame.cs = SELECTOR_USER_CODE
	frame.ss = SELECTOR_USER_DATA
	frame.vector = exit_vector(exit)
	frame.error = exit.error_code
}

// modus_processor_loop_run is the one export that a worker calls in its
// loop. A path of the kernel that does not return throws through it; the
// worker then calls it again.
@(export)
modus_processor_loop_run :: proc "c" (step_budget: u64) -> Processor_Loop_Result {
	switch processor_loop_next {
	case .None:
		return .Idle
	case .Call_Entry:
		processor_loop_next = .None
		processor_loop_entry()
	case .Run_Frame:
	}
	if step_budget == 0 || step_budget > u64(software.VM_MAX_STEP_BUDGET) {
		return .Budget_Refused
	}
	frame_to_software_processor(&processor_loop_frame)
	memory_bytes := u64(intrinsics.wasm_memory_size(0)) * WEBASSEMBLY_PAGE_SIZE
	// The physical memory of the machine is the whole linear memory, from
	// offset 0 (boot_info.DIRECT_MAP_POINTER_BASE).
	memory_start: [^]u8
	physical_memory := memory_start[:memory_bytes]
	outcome := software.processor_run(&software_processor, physical_memory, step_budget)
	exit, is_exit := software_exit.exit_of(&software_processor, outcome)
	if !is_exit {
		// The software processor stopped with no exit: a fault of the
		// kernel, as an unknown vector is on hardware.
		processor_stop()
	}
	if exit.kind == .Exception && exit.vector == .Page_Fault {
		software_processor_registers.control_register_2 = exit.fault_address
	}
	exit_frame: Frame
	software_processor_to_frame(&exit_frame, exit)
	kernel_interrupt(&exit_frame)
	return .Kernel_Returned
}

WEBASSEMBLY_PAGE_SIZE :: u64(65536)
