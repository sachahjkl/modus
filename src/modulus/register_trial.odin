package kernel

// A register trial (docs/glossary/running_code.md, "Register trial"): one access of the
// kernel to a model-specific register that the processor can refuse with a
// protection fault. A hypervisor can list a register in CPUID and refuse
// each access to it, and a protection fault of the kernel stops the
// machine. The kernel then tries the register once, at the start of a
// processor, and goes on after a refusal (thread_counters.odin; the design
// is src/md/features/processor_counters.md).
//
// The two procedures are in processor.asm, each with one rdmsr or wrmsr at
// a label. kernel_interrupt asks register_trial_refusal_address for the
// address of a protection fault of the kernel: at one of the two labels,
// the fault goes on at the refusal label, which gives false. At any other
// address it stops the machine, as before: no other fault of the kernel is
// hidden.

// register_trial_refusal_address gives where the kernel goes on after a
// protection fault at this instruction address: the refusal label when the
// address is the instruction of a register trial, else 0.
register_trial_refusal_address :: proc "contextless" (instruction: u64) -> u64 {
	if instruction == u64(uintptr(&model_specific_register_trial_read_instruction)) || instruction == u64(uintptr(&model_specific_register_trial_write_instruction)) {
		return u64(uintptr(&model_specific_register_trial_refused))
	}
	return 0
}

// An address that is not canonical with 4 or with 5 levels of page tables:
// bit 63 alone. Intel and AMD refuse it in the gs base of a process with a
// protection fault, and KVM refuses it too.
SELF_TEST_ADDRESS_NOT_CANONICAL :: u64(1) << 63

// register_trial_self_test proves the way back from a refusal on a machine:
// no test machine lists counters and refuses them. It writes an address
// that is not canonical to the gs base of a process through a register
// trial. The kernel goes on after the refusal, writes its line and stops the
// machine with the code 0. A processor that takes the write gets its old
// value back, and the caller then stops the machine with the code 1.
register_trial_self_test :: proc "contextless" () {
	log("kernel: self test: write an address that is not canonical to a register in a register trial")
	before := model_specific_register_read(MSR_KERNEL_GS_BASE)
	if !model_specific_register_trial_write(MSR_KERNEL_GS_BASE, SELF_TEST_ADDRESS_NOT_CANONICAL) {
		log("kernel: self test: the processor refused the write to the register ", Hex(MSR_KERNEL_GS_BASE), " in a register trial, and the kernel went on after it: as it must")
		machine_stop(.Normal_End)
	}
	model_specific_register_write(MSR_KERNEL_GS_BASE, before)
}
