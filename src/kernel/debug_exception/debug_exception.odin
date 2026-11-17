// The decision of the kernel on a debug exception of a program that a
// hypervisor gave again: an int1 whose delivery was cut, given as a fault
// before the int1 ran. It is a kernel part: the kernel alone compiles it
// in, and it reads what the processor that the hypervisor shows gives. The
// procedure is pure: it takes the bytes that
// the kernel read, so the host tests try each edge with no machine. The
// kernel calls it from debug_exception_is_dropped
// (src/kernel/breakpoints.odin), which reads each byte by itself, also
// across the border of two pages; the guide is docs/ARCHITECTURE.md, "The
// fault ring".
//
// This package allocates no memory and calls no kernel operation.
package debug_exception

// INT1_OPCODE is the one byte of the instruction int1 (icebp).
INT1_OPCODE :: 0xF1

// A byte of a program, as the kernel read it. readable false: the program
// cannot read it now (no mapping, no frame, no access, device memory), or
// it has no address (the byte before the address 0).
Program_Byte :: struct {
	value:    u8,
	readable: bool,
}

// int1_given_again says if a debug exception of a program, with the debug
// status `status` (the bits of the contract: the breakpoints and the single
// step), is an int1 that the hypervisor gave again before it ran. `at` is
// the byte at the instruction address of the exception, `before` the byte
// before it. true: the kernel drops the exception, and the thread runs the
// int1 again, which gives its one true trap.
//
// int1 is a trap: the processor gives it after the instruction, at the
// address of the next one, with no status bit. KVM with SVM before Linux 7.3
// does not intercept int1. When it leaves the processor during the
// delivery, for example on a nested page fault while the processor writes
// the frame on the interrupt stack of the debug exception, it gets the
// event back as the exception 1 and gives it again as a fault: at the
// address of the int1 itself, with no status. The form depends on the model
// of the processor: it is seen on some AMD processors (Zen 3), and not on
// others. Linux 7.3 intercepts int1 and gives its trap at the right address
// (the KVM commit ec9a16c6aeba), and this test can then go.
//
// On a processor, a debug exception of a program with no status bit comes
// only from int1, after it: the byte before its address is F1. So an
// address that holds F1 with a byte before it that is not F1 is no true
// trap, and nothing true is dropped. The rule keeps every exception whose
// byte before is F1: the trap of an int1, and also a cut int1 after any
// instruction whose last byte is F1 (`89 F1`, mov ecx, esi): that one gives
// its record two times. A cut int1 with a prefix (`66 F1`) is given again at
// the prefix, which is not F1: it gives its record two times too. A byte
// before that the program cannot read is no int1 that ended there: the
// exception is dropped.
int1_given_again :: proc "contextless" (status: u64, at: Program_Byte, before: Program_Byte) -> bool {
	switch {
	case status != 0:
		return false // A breakpoint or a single step: their bit names them.
	case !at.readable || at.value != INT1_OPCODE:
		return false
	case before.readable && before.value == INT1_OPCODE:
		return false
	}
	return true
}
