// The exit of the software processor as the event that a processor of
// x86-64 gives for the same instruction: the kernel entry of syscall, an
// exception with its vector and its error code, or the end of a slice,
// where the processor loop reads the clock for the deadline of the timer
// and the interrupts that wait. The processor loop of a browser machine
// builds the frame of the kernel from it
// (src/md/features/browser_machine.md, "The processor loop"). The kernel
// holds the frame and the vectors of its own interrupts; this package holds
// the rule, with host tests.
//
// This package allocates no memory and calls no kernel operation.
package software_exit

import software "modus:contract/software_machine"

// The vectors of x86-64 that the software processor can give.
Exception_Vector :: enum u8 {
	Divide_Error       = 0,
	Breakpoint         = 3,
	Invalid_Opcode     = 6,
	General_Protection = 13,
	Page_Fault         = 14,
}

Exit_Kind :: enum u8 {
	Kernel_Enter = 0, // syscall: rcx holds the return address and r11 the flags.
	Exception    = 1,
	Slice_End    = 2, // The step budget ran out: no event of the thread, a point where an interrupt can come.
}

Exit :: struct {
	kind:          Exit_Kind,
	vector:        Exception_Vector, // With Exception only.
	error_code:    u64, // The error code of a page fault or of a protection fault; 0 for the others.
	fault_address: u64, // With Page_Fault only: the address that cr2 gives.
}

// exit_of gives the exit of a run that stopped with outcome. Running is not
// an exit: the software processor never stops with it, and a caller that
// gives it gets a refusal.
exit_of :: proc "contextless" (cpu: ^software.Processor_State, outcome: software.Step_Outcome) -> (exit: Exit, ok: bool) {
	switch outcome {
	case .Running:
		return {}, false
	case .Syscall:
		return {kind = .Kernel_Enter}, true
	case .Step_Budget_Exhausted:
		return {kind = .Slice_End}, true
	case .Page_Fault:
		return {kind = .Exception, vector = .Page_Fault, error_code = cpu.fault_error_code, fault_address = cpu.fault_address}, true
	case .General_Protection:
		return {kind = .Exception, vector = .General_Protection, error_code = cpu.fault_error_code}, true
	case .Halted:
		// hlt is a privileged instruction: a process that runs it gets a
		// protection fault with the error code 0.
		return {kind = .Exception, vector = .General_Protection}, true
	case .Invalid_Opcode:
		return {kind = .Exception, vector = .Invalid_Opcode}, true
	case .Breakpoint:
		return {kind = .Exception, vector = .Breakpoint}, true
	case .Divide_Error:
		return {kind = .Exception, vector = .Divide_Error}, true
	}
	unreachable()
}
