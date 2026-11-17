// The stolen time of a processor under KVM: the time in which the host ran
// no code of that processor. The kernel subtracts it from the processor time
// that it charges to a thread, so a loaded host does not make a budget pay
// for time that no thread used. The design is
// src/md/features/stolen_time.md.
//
// The formats are those of the Linux documentation,
// Documentation/virt/kvm/x86/msr.rst ("MSR_KVM_STEAL_TIME") and
// Documentation/virt/kvm/x86/cpuid.rst ("KVM_FEATURE_STEAL_TIME"). The
// kernel reads CPUID, writes the register and loads the record; this
// package holds the record, the decision from CPUID, the check of the
// version protocol and the arithmetic of a charge, as pure procedures with
// host tests.
//
// This package allocates no memory and calls no kernel operation.
package stolen_time

// The hypervisor bit: ECX of CPUID leaf 1 has it on a guest of any
// hypervisor.
HYPERVISOR_PRESENT_BIT :: u32(1) << 31

// The leaves of a hypervisor. The KVM leaves start at the first base, or,
// behind the interface of another hypervisor, at a later base: Linux
// searches each multiple of the step below the end.
HYPERVISOR_LEAF_FIRST :: u32(0x4000_0000)
HYPERVISOR_LEAF_END :: u32(0x4001_0000)
HYPERVISOR_LEAF_STEP :: u32(0x100)

// The signature of KVM in EBX, ECX and EDX of its base: "KVMKVMKVM\0\0\0".
KVM_SIGNATURE_B :: u32(0x4B4D_564B) // "KVMK"
KVM_SIGNATURE_C :: u32(0x564B_4D56) // "VMKV"
KVM_SIGNATURE_D :: u32(0x0000_004D) // "M\0\0\0"

// The features of KVM are in EAX of the base plus this offset.
KVM_FEATURES_LEAF_OFFSET :: u32(1)
// The steal time in the features of KVM.
KVM_FEATURE_STEAL_TIME_BIT :: u32(1) << 5

// The register that takes the physical address of the record of a
// processor, with the enable bit.
MSR_KVM_STEAL_TIME :: u32(0x4B56_4D03)
REGISTRATION_ENABLE :: u64(1)

// The record that KVM fills for one processor. The guest zeroes it before
// it writes its address. `steal` counts nanoseconds; the time in which the
// processor waited idle is not in it.
Record :: struct #align (64) {
	steal:     u64,
	version:   u32, // A sequence counter: odd while the host writes the record.
	flags:     u32, // Always 0.
	preempted: u8, // Not 0: the processor is out now. The kernel does not read it.
	padding:   [3]u8,
	reserved:  [11]u32,
}
#assert(size_of(Record) == 64)
#assert(align_of(Record) == 64)
#assert(offset_of(Record, steal) == 0)
#assert(offset_of(Record, version) == 8)
#assert(offset_of(Record, flags) == 12)
#assert(offset_of(Record, preempted) == 16)

// The attempts of one read of the record. The host writes the record of a
// processor only when that processor enters the guest again, so the
// processor that reads its own record does not see a write in progress:
// the bound only closes a hang.
READ_ATTEMPT_LIMIT :: 8

NANOSECONDS_PER_SECOND :: u64(1_000_000_000)

// Why the machine has no steal time.
Absence :: enum u8 {
	None             = 0, // The machine offers steal time.
	No_Hypervisor    = 1,
	No_Kvm_Leaves    = 2,
	No_Steal_Feature = 3,
}

@(rodata)
ABSENCE_TEXTS := [Absence]string {
	.None             = "",
	.No_Hypervisor    = "CPUID names no hypervisor: a real machine, where nothing is stolen",
	.No_Kvm_Leaves    = "the hypervisor has no KVM leaves",
	.No_Steal_Feature = "KVM does not offer the steal time",
}

// What the kernel read of CPUID: the hypervisor bit, whether a base of the
// leaves of a hypervisor had the signature of KVM, and the features of
// KVM at that base.
Identification :: struct {
	hypervisor_present: bool,
	kvm_leaves_found:   bool,
	kvm_features:       u32,
}

// is_kvm_signature says if the three registers of a base of the leaves of
// a hypervisor name KVM.
is_kvm_signature :: proc "contextless" (b, c, d: u32) -> bool {
	return b == KVM_SIGNATURE_B && c == KVM_SIGNATURE_C && d == KVM_SIGNATURE_D
}

// absence_of_identification decides if the machine offers steal time.
absence_of_identification :: proc "contextless" (identification: Identification) -> Absence {
	if !identification.hypervisor_present {
		return .No_Hypervisor
	}
	if !identification.kvm_leaves_found {
		return .No_Kvm_Leaves
	}
	if identification.kvm_features & KVM_FEATURE_STEAL_TIME_BIT == 0 {
		return .No_Steal_Feature
	}
	return .None
}

// registration_value gives the word of the register for a record at this
// physical address. false: the address is not aligned on 64 bytes, or is
// 0, and the register must not take it.
registration_value :: proc "contextless" (physical_address: u64) -> (value: u64, ok: bool) {
	if physical_address == 0 || physical_address % size_of(Record) != 0 {
		return 0, false
	}
	return physical_address | REGISTRATION_ENABLE, true
}

// read_is_whole says if one read of the record holds a value of the host:
// the version before and after the load of `steal` are equal and even.
read_is_whole :: proc "contextless" (version_before, version_after: u32) -> bool {
	return version_before & 1 == 0 && version_before == version_after
}

// cycles_of_nanoseconds gives the cycles of a time in nanoseconds at the
// frequency of the cycle counter. Seconds and the rest are converted apart,
// so no product of a rest overflows; a time past 64 bits of cycles gives
// the largest value. A frequency of 0 (not measured yet) gives 0.
cycles_of_nanoseconds :: proc "contextless" (nanoseconds: u64, cycle_frequency: u64) -> u64 {
	if cycle_frequency == 0 {
		return 0
	}
	seconds := nanoseconds / NANOSECONDS_PER_SECOND
	rest := nanoseconds % NANOSECONDS_PER_SECOND
	if seconds > max(u64) / cycle_frequency {
		return max(u64)
	}
	whole := seconds * cycle_frequency
	// rest is below 10^9: the product is below 2^64 for each frequency
	// below 18 GHz, so the guard keeps the largest value past that.
	if rest != 0 && cycle_frequency > max(u64) / rest {
		return max(u64)
	}
	part := rest * cycle_frequency / NANOSECONDS_PER_SECOND
	if whole > max(u64) - part {
		return max(u64)
	}
	return whole + part
}

// What one charge did with the steal counter.
Charge_Outcome :: enum u8 {
	Subtracted        = 0, // The stolen cycles since the last charge, at most the run, left the charge.
	Counter_Went_Back = 1, // The counter was below the last value: refused, the whole run is charged.
}

// charge_without_stolen gives the cycles to charge for a run of
// `run_cycles`, when the steal counter was `counted` at the last charge and
// is `steal` now, both in nanoseconds. The charge is never below 0 and
// never above the run. `next_counted` is the counter that the next charge
// starts from: the counter now, also after a refusal, so that the next
// charges are right.
charge_without_stolen :: proc "contextless" (run_cycles: u64, counted: u64, steal: u64, cycle_frequency: u64) -> (charged: u64, next_counted: u64, outcome: Charge_Outcome) {
	if steal < counted {
		return run_cycles, steal, .Counter_Went_Back
	}
	stolen := min(cycles_of_nanoseconds(steal - counted, cycle_frequency), run_cycles)
	return run_cycles - stolen, steal, .Subtracted
}
