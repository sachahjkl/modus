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
	Idle            = 0, // Nothing to run: the worker waits for a message or a deadline.
	Kernel_Returned = 1, // The kernel path of an exit returned: call again.
	Budget_Refused  = 2, // A step budget of 0, or past STEP_BUDGET_LIMIT.
	Slice_Ended     = 3, // The slice ended and no interrupt waits: call again, the thread goes on.
}

// The most instructions of one call of the loop. The loop reads the clock
// at the end of each slice, so a longer slice delays the tick of the timer
// and each message of the page.
STEP_BUDGET_LIMIT :: u64(1_000_000)

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
// process at its own addresses (user_copy_from_process walks the table).
// The labels exist only for the comparisons of the fault path: no
// instruction of WebAssembly is at them.
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

@(private = "file")
idle_reenter_schedule :: proc "c" () -> ! {
	schedule()
}

// The idle wait sleeps on the word of this processor until the deadline
// of its timer, at most one tick, in the place of sti and hlt, and returns
// after it delivered at least one interrupt, as hlt returns after one. A
// build with no atomics has no shared memory and one processor: its idle
// wait is an import that suspends the worker, so the worker gives the
// browser its events while it waits (browser_machine.md, "Several
// processors as workers").
idle_wait :: proc "c" () {
	word := &pending_vector_words[apic_id()]
	for {
		// The word is cleared before the vectors are read: a sender sets
		// its vector first, so a vector that comes after the read wakes
		// the next wait.
		intrinsics.atomic_store(word, 0)
		if interrupts_deliver_in_kernel() {
			return
		}
		bound := interrupt_wait_bound(u64(IDLE_WAIT_BOUND_NANOSECONDS))
		if bound == 0 {
			continue
		}
		when intrinsics.has_target_feature("atomics") {
			_ = intrinsics.wasm_memory_atomic_wait32(word, 0, i64(bound))
		} else {
			// Prepare a clean re-entry into schedule() so a browser worker can
			// unwind out of page_idle_wait without spinning or blocking its
			// event loop. If page_idle_wait returns synchronously (e.g. Node),
			// restore the idle state and continue waiting.
			cpu := processor_self()
			intrinsics.atomic_store(&cpu.idle, false)
			processor_loop_entry = idle_reenter_schedule
			processor_loop_next = .Call_Entry
			page_idle_wait(i64(bound))
			processor_loop_next = .None
			intrinsics.atomic_store(&cpu.idle, true)
		}
	}
}

// The window of interrupts of the kernel: each interrupt that waits comes
// here, with no thread and no lock held, as between sti and cli. Outside a
// window, an interrupt waits for the next exit of the software processor:
// the kernel runs each entry to its end, as with interrupts off.
interrupt_window :: proc "c" () {
	_ = interrupts_deliver_in_kernel()
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
// software processor holds the SSE registers and MXCSR only, so each form
// moves the same bytes.
EXTENDED_STATE_CONTROL_WORD_OFFSET :: software.FXSAVE_CONTROL_WORD_OFFSET
EXTENDED_STATE_MXCSR_OFFSET :: software.FXSAVE_MXCSR_OFFSET
EXTENDED_STATE_XMM_OFFSET :: software.FXSAVE_XMM_OFFSET

extended_state_save :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) {
	(^u32le)(&area.bytes[EXTENDED_STATE_MXCSR_OFFSET])^ = u32le(software_processor.mxcsr)
	for index in 0 ..< len(software_processor.xmm) {
		start := EXTENDED_STATE_XMM_OFFSET + index * 16
		copy(area.bytes[start:start + 16], software_processor.xmm[index][:])
	}
}

// The kernel checks each area against the bits of MXCSR that the processor
// takes before it restores it (extended_state_refusal), as fxrstor would
// fault on any other bit.
extended_state_restore :: proc "c" (area: ^Extended_State_Area, form: Extended_State_Form) {
	software_processor.mxcsr = u32((^u32le)(&area.bytes[EXTENDED_STATE_MXCSR_OFFSET])^)
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

// A register that the kernel never wrote is a register that this processor
// lacks: the trial refuses it, as the processor refuses it with a
// protection fault.
model_specific_register_trial_read :: proc "c" (index: u32, value: ^u64) -> bool {
	if !model_specific_register_is_known(index) {
		return false
	}
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
	cpu.timestamp_disable = processor_self().tsd_loaded
	cpu.cycle_counter_read = software_processor_cycle_counter_read
	cpu.blocks = &software_processor_blocks
	when !intrinsics.has_target_feature("atomics") {
		software_processor_blocks.trust_write_tracking = true
	}
	// The map of the task state of this processor: ports_switch opened
	// in it the ports of the process of the thread, as for the processor.
	cpu.ports = {
		permission_map = processor_self().task_state.ports[:],
		read           = software_processor_port_read,
		write          = software_processor_port_write,
	}
}

// The devices of the page have registers of one byte, so an access of 2
// or 4 bytes is that many accesses of one byte, the lowest port first, as
// a bus of 8 bits splits it.
@(private = "file")
software_processor_port_read :: proc "contextless" (port: u16, width: software.Operand_Width) -> (value: u32) {
	for offset in 0 ..< u32(width) {
		value |= u32(port_read_8(port + u16(offset))) << (8 * offset)
	}
	return value
}

@(private = "file")
software_processor_port_write :: proc "contextless" (port: u16, width: software.Operand_Width, value: u32) {
	for offset in 0 ..< u32(width) {
		port_write_8(port + u16(offset), u8(value >> (8 * offset)))
	}
}

// rdtsc of a process reads the cycle counter of the kernel: the clock of
// the page, at 1 GHz.
@(private = "file")
software_processor_cycle_counter_read :: proc "contextless" () -> u64 {
	return cycles_now()
}

@(private = "file")
software_processor_to_frame :: proc "contextless" (frame: ^Frame) {
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
}

// process_interrupt gives the kernel the frame of the thread with an
// event: an exit of the software processor or an interrupt. A path of the
// kernel that runs a thread throws, so a return means that nothing runs
// on this processor until the kernel gives it a frame or an entry.
@(private = "file")
process_interrupt :: proc "contextless" (frame: ^Frame) -> Processor_Loop_Result {
	processor_loop_next = .None
	kernel_interrupt(frame)
	return .Kernel_Returned
}

// interrupt_to_process interrupts the thread of processor_loop_frame with
// the highest interrupt that waits, as the processor does between two
// instructions. false: none waits.
@(private = "file")
interrupt_to_process :: proc "contextless" () -> (result: Processor_Loop_Result, interrupted: bool) {
	vector, taken := interrupt_take_for_process()
	if !taken {
		return .Slice_Ended, false
	}
	frame := processor_loop_frame
	frame.vector = u64(vector)
	frame.error = 0
	return process_interrupt(&frame), true
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
	if step_budget == 0 || step_budget > STEP_BUDGET_LIMIT {
		return .Budget_Refused
	}
	// An interrupt that waits comes before the next instruction.
	if result, interrupted := interrupt_to_process(); interrupted {
		return result
	}
	frame_to_software_processor(&processor_loop_frame)
	outcome := software.processor_run(&software_processor, linear_memory(), step_budget)
	exit, is_exit := software_exit.exit_of(&software_processor, outcome)
	if !is_exit {
		// The software processor stopped with no exit: a fault of the
		// kernel, as an unknown vector is on hardware.
		processor_stop()
	}
	software_processor_to_frame(&processor_loop_frame)
	exit_frame := processor_loop_frame
	switch exit.kind {
	case .Slice_End:
		// The end of a slice is no event of the thread: the deadline of
		// the timer and the vectors that wait decide whether the kernel
		// runs.
		result, _ := interrupt_to_process()
		return result
	case .Kernel_Enter:
		exit_frame.vector = VECTOR_KERNEL_ENTER
		exit_frame.error = 0
	case .Exception:
		exit_frame.vector = u64(exit.vector)
		exit_frame.error = exit.error_code
		if exit.vector == .Page_Fault {
			software_processor_registers.control_register_2 = exit.fault_address
		}
	}
	return process_interrupt(&exit_frame)
}

