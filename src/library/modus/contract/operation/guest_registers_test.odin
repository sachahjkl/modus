#+build !freestanding
package operation

import "core:testing"

// Each bit of the flags register that no processor defines is refused,
// alone and with every defined bit: the processor faults on a reserved bit
// set at the entry of a guest. Bit 1, which is always 1, is defined: the
// record can hold it clear or set.
@(test)
guest_registers_with_a_reserved_flag_are_refused :: proc(t: ^testing.T) {
	// The reserved bits of the flags register, from the manual of the
	// processor: 3, 5, 15, then 22 to 63.
	reserved_bits := [?]u64{3, 5, 15, 22, 31, 32, 63}
	for bit in reserved_bits {
		alone := Guest_Registers{rflags = u64(1) << bit}
		testing.expectf(t, guest_registers_refusal(alone), "the reserved bit %v is refused", bit)
		with_defined := Guest_Registers{rflags = GUEST_FLAGS_DEFINED | u64(1) << bit}
		testing.expectf(t, guest_registers_refusal(with_defined), "the reserved bit %v is refused beside the defined bits", bit)
	}
	for bit: u64 = 0; bit < 64; bit += 1 {
		registers := Guest_Registers{rflags = u64(1) << bit}
		defined := GUEST_FLAGS_DEFINED & (u64(1) << bit) != 0
		testing.expectf(t, guest_registers_refusal(registers) == !defined, "the bit %v: defined %v", bit, defined)
	}
	testing.expect(t, guest_registers_refusal({rflags = ~GUEST_FLAGS_DEFINED}))
	testing.expect(t, guest_registers_refusal({rflags = max(u64)}))
	// The successful cases last: no flag, each defined flag, bit 1 clear,
	// and the other registers at their largest values, which the kernel
	// does not refuse.
	testing.expect(t, !guest_registers_refusal({}))
	testing.expect(t, !guest_registers_refusal({rflags = GUEST_FLAGS_DEFINED}))
	testing.expect(t, !guest_registers_refusal({rflags = GUEST_FLAGS_DEFINED &~ 0b10}))
	testing.expect(t, !guest_registers_refusal({rflags = 0b10}))
	largest := Guest_Registers {
		rax = max(u64),
		rbx = max(u64),
		rcx = max(u64),
		rdx = max(u64),
		rsi = max(u64),
		rdi = max(u64),
		rbp = max(u64),
		rsp = max(u64),
		r8  = max(u64),
		r9  = max(u64),
		r10 = max(u64),
		r11 = max(u64),
		r12 = max(u64),
		r13 = max(u64),
		r14 = max(u64),
		r15 = max(u64),
		rip = max(u64),
	}
	testing.expect(t, !guest_registers_refusal(largest))
}
