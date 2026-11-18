// The time base of the kernel at its start: the choice between the 8254
// and the frequency of the cycle counter that the processor states, and
// the bound of a wait for a register before and after the kernel knows
// that frequency. The design is src/md/features/missing_hardware.md.
//
// The leaves are those of the Intel SDM, volume 2, "CPUID": leaf 0x15
// ("Time Stamp Counter and Nominal Core Crystal Clock Information Leaf")
// and leaf 0x16 ("Processor Frequency Information Leaf"). The rule that
// takes the base frequency of leaf 0x16 when leaf 0x15 has no crystal is
// the rule of native_calibrate_tsc of Linux. The kernel reads CPUID; this
// package holds the decision and the arithmetic, as pure procedures with
// host tests.
//
// This package allocates no memory and calls no kernel operation.
package time_base

// The leaves that state the frequency of the cycle counter.
FREQUENCY_RATIO_LEAF :: u32(0x15)
BASE_FREQUENCY_LEAF :: u32(0x16)

// Leaf 0x16 gives the base frequency in megahertz in bits 0 to 15 of EAX.
BASE_FREQUENCY_MASK :: u32(0xFFFF)
HERTZ_IN_A_MEGAHERTZ :: u64(1_000_000)

// The frequencies of a cycle counter that the kernel takes. Below the
// least, a microsecond holds no whole cycle, and each wait of the kernel
// that counts cycles in microseconds is 0. Above the most, the bound of a
// wait before the kernel knows the frequency is shorter than the wait.
FREQUENCY_LEAST :: u64(1_000_000)
FREQUENCY_MOST :: u64(10_000_000_000)

MICROSECONDS_IN_A_SECOND :: u64(1_000_000)

// The vendor of Intel in EBX, EDX and ECX of leaf 0: "GenuineIntel". AMD
// documents the leaves 0x15 and 0x16 as reserved, and Linux reads them on
// Intel only: on another vendor their words state nothing.
INTEL_SIGNATURE_B :: u32(0x756E_6547) // "Genu"
INTEL_SIGNATURE_D :: u32(0x4965_6E69) // "ineI"
INTEL_SIGNATURE_C :: u32(0x6C65_746E) // "ntel"

// is_intel_signature says if EBX, ECX and EDX of leaf 0 name Intel.
is_intel_signature :: proc "contextless" (ebx: u32, ecx: u32, edx: u32) -> bool {
	return ebx == INTEL_SIGNATURE_B && edx == INTEL_SIGNATURE_D && ecx == INTEL_SIGNATURE_C
}

// What the kernel reads of CPUID, with no change.
Identification :: struct {
	vendor_is_intel:   bool, // is_intel_signature of leaf 0.
	highest_leaf:      u32, // EAX of leaf 0.
	ratio_denominator: u32, // EAX of leaf 0x15.
	ratio_numerator:   u32, // EBX of leaf 0x15.
	crystal_hertz:     u32, // ECX of leaf 0x15: 0 when the processor does not state it.
	base_frequency:    u32, // EAX of leaf 0x16.
}

// Why the processor states no frequency of its cycle counter.
Absence :: enum u8 {
	None,
	Not_Intel, // The leaves 0x15 and 0x16 are those of Intel only.
	No_Ratio_Leaf, // The highest leaf is below leaf 0x15.
	No_Ratio, // Leaf 0x15 gives 0 as the numerator or the denominator.
	No_Crystal, // Leaf 0x15 gives no crystal, and leaf 0x16 is absent or gives 0.
	Out_Of_Range, // The frequency is below FREQUENCY_LEAST or above FREQUENCY_MOST.
}

// The words of each absence in the line of the kernel.
@(rodata)
ABSENCE_TEXTS := [Absence]string {
	.None          = "",
	.Not_Intel     = "the processor is not of Intel, the one vendor that defines CPUID leaves 0x15 and 0x16",
	.No_Ratio_Leaf = "CPUID has no leaf 0x15",
	.No_Ratio      = "CPUID leaf 0x15 gives no ratio of the cycle counter to the crystal",
	.No_Crystal    = "CPUID gives no frequency of the crystal and no base frequency",
	.Out_Of_Range  = "CPUID states a frequency below 1 MHz or above 10 GHz",
}

// stated_frequency gives the frequency of the cycle counter in hertz that
// the processor states, or why it states none. The frequency is the
// crystal times the ratio of leaf 0x15; with no crystal, the base
// frequency of leaf 0x16, which Linux takes only with the ratio too.
stated_frequency :: proc "contextless" (identification: Identification) -> (hertz: u64, absence: Absence) {
	if !identification.vendor_is_intel {
		return 0, .Not_Intel
	}
	if identification.highest_leaf < FREQUENCY_RATIO_LEAF {
		return 0, .No_Ratio_Leaf
	}
	if identification.ratio_denominator == 0 || identification.ratio_numerator == 0 {
		return 0, .No_Ratio
	}
	if identification.crystal_hertz != 0 {
		// Two words of 32 bits: the product fits in 64 bits.
		hertz = u64(identification.crystal_hertz) * u64(identification.ratio_numerator) / u64(identification.ratio_denominator)
	} else if identification.highest_leaf >= BASE_FREQUENCY_LEAF && identification.base_frequency & BASE_FREQUENCY_MASK != 0 {
		hertz = u64(identification.base_frequency & BASE_FREQUENCY_MASK) * HERTZ_IN_A_MEGAHERTZ
	} else {
		return 0, .No_Crystal
	}
	if hertz < FREQUENCY_LEAST || hertz > FREQUENCY_MOST {
		return 0, .Out_Of_Range
	}
	return hertz, .None
}

// bound_cycles gives the cycles of the cycle counter in a wait of
// `microseconds`. With a frequency of 0, the kernel does not know it yet,
// and the bound takes FREQUENCY_MOST: the wait then lasts at least that
// time on each processor that the kernel takes. A product past 64 bits
// gives the largest value. Seconds and the rest are converted apart, so a
// long wait does not overflow before the division.
bound_cycles :: proc "contextless" (microseconds: u64, cycle_frequency: u64) -> u64 {
	frequency := cycle_frequency == 0 ? FREQUENCY_MOST : cycle_frequency
	seconds := microseconds / MICROSECONDS_IN_A_SECOND
	rest := microseconds % MICROSECONDS_IN_A_SECOND
	if seconds > max(u64) / frequency {
		return max(u64)
	}
	whole := seconds * frequency
	if rest != 0 && frequency > max(u64) / rest {
		return max(u64)
	}
	part := rest * frequency / MICROSECONDS_IN_A_SECOND
	if whole > max(u64) - part {
		return max(u64)
	}
	return whole + part
}

// deadline gives the value of the cycle counter at which a wait of
// `microseconds` from `now` ends. A sum past 64 bits gives the largest
// value, not a sum that wraps: a deadline below now would end the wait at
// once, and the kernel would call a part absent that is there.
deadline :: proc "contextless" (now: u64, microseconds: u64, cycle_frequency: u64) -> u64 {
	cycles := bound_cycles(microseconds, cycle_frequency)
	if now > max(u64) - cycles {
		return max(u64)
	}
	return now + cycles
}
