// The answer of cpuid on a browser machine (src/md/features/browser_machine.md,
// "The other instructions"): the baseline of x86-64 with SSE2. It names no
// APIC, no xsave, no virtualization, no processor counters and no
// hypervisor, so the kernel takes the paths of a machine that lacks them,
// and a process sees the same answer as the kernel.
package software_machine

IDENTIFICATION_HIGHEST_BASIC_LEAF :: 1
IDENTIFICATION_HIGHEST_EXTENDED_LEAF :: 0x8000_0001
IDENTIFICATION_BASIC_FEATURES_EDX :: u32(1 << 0 | 1 << 4 | 1 << 5 | 1 << 8 | 1 << 15 | 1 << 24 | 1 << 25 | 1 << 26) // x87, rdtsc, rdmsr, cmpxchg8b, cmov, fxsave, SSE, SSE2.
IDENTIFICATION_EXTENDED_FEATURES_EDX :: u32(1 << 11 | 1 << 20 | 1 << 29) // syscall, no-execute, long mode.

identification_read :: proc "contextless" (leaf, subleaf: u32) -> (eax, ebx, ecx, edx: u32) {
	switch leaf {
	case 0:
		return IDENTIFICATION_HIGHEST_BASIC_LEAF, 0, 0, 0
	case 1:
		return 0, 0, 0, IDENTIFICATION_BASIC_FEATURES_EDX
	case 0x8000_0000:
		return IDENTIFICATION_HIGHEST_EXTENDED_LEAF, 0, 0, 0
	case 0x8000_0001:
		return 0, 0, 0, IDENTIFICATION_EXTENDED_FEATURES_EDX
	}
	return 0, 0, 0, 0
}
