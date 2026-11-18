#+build !freestanding
package time_base

import "core:testing"

// A crystal of 25 MHz and a ratio of 152 / 2: a cycle counter of 1.9 GHz,
// as a processor of the tests states it.
@(private = "file")
CRYSTAL :: u32(25_000_000)
@(private = "file")
NUMERATOR :: u32(152)
@(private = "file")
DENOMINATOR :: u32(2)

@(private = "file")
with_crystal :: proc() -> Identification {
	return {vendor_is_intel = true, highest_leaf = BASE_FREQUENCY_LEAF, ratio_denominator = DENOMINATOR, ratio_numerator = NUMERATOR, crystal_hertz = CRYSTAL}
}

// The vendor is the three registers in their order: another order, a
// change of one byte, the vendor of AMD and no vendor are refused.
@(test)
the_signature_of_intel :: proc(t: ^testing.T) {
	testing.expect(t, !is_intel_signature(0, 0, 0))
	testing.expect(t, !is_intel_signature(max(u32), max(u32), max(u32)))
	// The text is in EBX, EDX, ECX; the words in the order of the text, as
	// EBX, ECX, EDX, are refused.
	testing.expect(t, !is_intel_signature(INTEL_SIGNATURE_B, INTEL_SIGNATURE_D, INTEL_SIGNATURE_C))
	testing.expect(t, !is_intel_signature(INTEL_SIGNATURE_B ~ 1, INTEL_SIGNATURE_C, INTEL_SIGNATURE_D))
	testing.expect(t, !is_intel_signature(INTEL_SIGNATURE_B, INTEL_SIGNATURE_C, INTEL_SIGNATURE_D ~ 1 << 24))
	// "AuthenticAMD": EBX "Auth", EDX "enti", ECX "cAMD".
	testing.expect(t, !is_intel_signature(0x6874_7541, 0x444D_4163, 0x6974_6E65))
	// The bytes of "GenuineIntel" in the order of the registers.
	word_of :: proc(four: string) -> u32 {
		return u32(four[0]) | u32(four[1]) << 8 | u32(four[2]) << 16 | u32(four[3]) << 24
	}
	testing.expect(t, is_intel_signature(word_of("Genu"), word_of("ntel"), word_of("ineI")))
}

// A processor of another vendor states nothing, whatever its leaves say:
// the vendor decides first.
@(test)
a_processor_of_another_vendor :: proc(t: ^testing.T) {
	other := with_crystal()
	other.vendor_is_intel = false
	hertz, absence := stated_frequency(other)
	testing.expect_value(t, absence, Absence.Not_Intel)
	testing.expect_value(t, hertz, u64(0))
	hertz, absence = stated_frequency({})
	testing.expect_value(t, absence, Absence.Not_Intel)
	testing.expect_value(t, hertz, u64(0))
}

// Each step that lacks gives its absence and no frequency, and the first
// that lacks decides.
@(test)
a_processor_that_states_no_frequency :: proc(t: ^testing.T) {
	expect_absence :: proc(t: ^testing.T, identification: Identification, expected: Absence) {
		hertz, absence := stated_frequency(identification)
		testing.expect_value(t, absence, expected)
		testing.expect_value(t, hertz, u64(0))
	}
	expect_absence(t, {vendor_is_intel = true}, .No_Ratio_Leaf)
	// One leaf below: whatever the other words say, the leaf does not exist.
	below := with_crystal()
	below.highest_leaf = FREQUENCY_RATIO_LEAF - 1
	expect_absence(t, below, .No_Ratio_Leaf)
	no_denominator := with_crystal()
	no_denominator.ratio_denominator = 0
	expect_absence(t, no_denominator, .No_Ratio)
	no_numerator := with_crystal()
	no_numerator.ratio_numerator = 0
	expect_absence(t, no_numerator, .No_Ratio)
	// No crystal, and leaf 0x16 absent, or present with 0 in its low bits.
	no_crystal := with_crystal()
	no_crystal.crystal_hertz = 0
	no_crystal.highest_leaf = FREQUENCY_RATIO_LEAF
	no_crystal.base_frequency = 2000
	expect_absence(t, no_crystal, .No_Crystal)
	no_crystal.highest_leaf = BASE_FREQUENCY_LEAF
	no_crystal.base_frequency = 0
	expect_absence(t, no_crystal, .No_Crystal)
	// The high bits of EAX of leaf 0x16 are reserved: they state nothing.
	no_crystal.base_frequency = ~BASE_FREQUENCY_MASK
	expect_absence(t, no_crystal, .No_Crystal)
	// Each absence has a text for the line of the kernel; None alone has none.
	for absence in Absence {
		testing.expectf(t, (ABSENCE_TEXTS[absence] == "") == (absence == .None), "the text of %v", absence)
	}
}

// A frequency below the least or above the most is refused, at one past
// each bound; the largest product of two words of 32 bits does not wrap.
@(test)
a_frequency_out_of_its_range :: proc(t: ^testing.T) {
	expect_out_of_range :: proc(t: ^testing.T, crystal: u32, numerator: u32, denominator: u32) {
		hertz, absence := stated_frequency({vendor_is_intel = true, highest_leaf = FREQUENCY_RATIO_LEAF, ratio_denominator = denominator, ratio_numerator = numerator, crystal_hertz = crystal})
		testing.expect_value(t, absence, Absence.Out_Of_Range)
		testing.expect_value(t, hertz, u64(0))
	}
	// 1 Hz, and one below the least.
	expect_out_of_range(t, 1, 1, 1)
	expect_out_of_range(t, u32(FREQUENCY_LEAST - 1), 1, 1)
	// A ratio below 1 that takes the frequency below the least.
	expect_out_of_range(t, u32(FREQUENCY_LEAST), 1, 2)
	// The largest crystal times the largest numerator over 1: far above the
	// most, and the product of the two words is exact.
	expect_out_of_range(t, max(u32), max(u32), 1)
	// The most does not fit a crystal of 32 bits: one step of the numerator
	// past the most, (10 GHz / 4 + 1) × 4.
	expect_out_of_range(t, u32(FREQUENCY_MOST / 4 + 1), 4, 1)
	// The base frequency of leaf 0x16 passes the same check: 65535 MHz.
	hertz, absence := stated_frequency({vendor_is_intel = true, highest_leaf = BASE_FREQUENCY_LEAF, ratio_denominator = 1, ratio_numerator = 1, base_frequency = BASE_FREQUENCY_MASK})
	testing.expect_value(t, absence, Absence.Out_Of_Range)
	testing.expect_value(t, hertz, u64(0))
}

// The bounds themselves are taken; then a crystal with its ratio, and the
// base frequency when the crystal is 0.
@(test)
a_processor_that_states_its_frequency :: proc(t: ^testing.T) {
	expect_frequency :: proc(t: ^testing.T, identification: Identification, expected: u64) {
		hertz, absence := stated_frequency(identification)
		testing.expect_value(t, absence, Absence.None)
		testing.expect_value(t, hertz, expected)
	}
	expect_frequency(t, {vendor_is_intel = true, highest_leaf = FREQUENCY_RATIO_LEAF, ratio_denominator = 1, ratio_numerator = 1, crystal_hertz = u32(FREQUENCY_LEAST)}, FREQUENCY_LEAST)
	expect_frequency(t, {vendor_is_intel = true, highest_leaf = FREQUENCY_RATIO_LEAF, ratio_denominator = 1, ratio_numerator = 4, crystal_hertz = u32(FREQUENCY_MOST / 4)}, FREQUENCY_MOST)
	expect_frequency(t, with_crystal(), u64(CRYSTAL) * u64(NUMERATOR) / u64(DENOMINATOR))
	// A crystal wins over the base frequency, which is only an estimate.
	both := with_crystal()
	both.base_frequency = 3000
	expect_frequency(t, both, u64(CRYSTAL) * u64(NUMERATOR) / u64(DENOMINATOR))
	base := with_crystal()
	base.crystal_hertz = 0
	base.base_frequency = 2100
	expect_frequency(t, base, 2100 * HERTZ_IN_A_MEGAHERTZ)
	// The reserved high bits of EAX do not change the base frequency.
	base.base_frequency = 2100 | ~BASE_FREQUENCY_MASK
	expect_frequency(t, base, 2100 * HERTZ_IN_A_MEGAHERTZ)
}

// The bound of a wait: 0 microseconds is 0 cycles, an unknown frequency
// takes the most, and a product or a sum past 64 bits gives the largest
// value, never a value that wrapped.
@(test)
the_bound_of_a_wait :: proc(t: ^testing.T) {
	testing.expect_value(t, bound_cycles(0, 0), u64(0))
	testing.expect_value(t, bound_cycles(0, max(u64)), u64(0))
	testing.expect_value(t, bound_cycles(1, 0), FREQUENCY_MOST / MICROSECONDS_IN_A_SECOND)
	testing.expect_value(t, bound_cycles(MICROSECONDS_IN_A_SECOND, 0), FREQUENCY_MOST)
	// A frequency of 1 Hz: no whole cycle in one microsecond, one in a second.
	testing.expect_value(t, bound_cycles(1, 1), u64(0))
	testing.expect_value(t, bound_cycles(MICROSECONDS_IN_A_SECOND, 1), u64(1))
	// The largest frequency: one second is the largest value exactly, one
	// microsecond more passes 64 bits.
	testing.expect_value(t, bound_cycles(MICROSECONDS_IN_A_SECOND, max(u64)), max(u64))
	testing.expect_value(t, bound_cycles(MICROSECONDS_IN_A_SECOND + 1, max(u64)), max(u64))
	testing.expect_value(t, bound_cycles(1, max(u64)), max(u64) / MICROSECONDS_IN_A_SECOND)
	// The largest wait at the most: the seconds alone pass 64 bits.
	testing.expect_value(t, bound_cycles(max(u64), 0), max(u64))
	// The seconds fit and the rest makes the sum pass 64 bits.
	seconds := max(u64) / FREQUENCY_MOST
	testing.expect_value(t, bound_cycles(seconds * MICROSECONDS_IN_A_SECOND + MICROSECONDS_IN_A_SECOND - 1, FREQUENCY_MOST), max(u64))
	testing.expect_value(t, bound_cycles(seconds * MICROSECONDS_IN_A_SECOND, FREQUENCY_MOST), seconds * FREQUENCY_MOST)
	// An unknown frequency gives a bound that is never shorter than the
	// bound of a frequency that the kernel takes.
	for frequency in ([]u64{FREQUENCY_LEAST, 3_800_000_000, FREQUENCY_MOST}) {
		testing.expectf(t, bound_cycles(10_000, 0) >= bound_cycles(10_000, frequency), "the bound at %d Hz", frequency)
	}
}

@(test)
the_deadline_of_a_wait :: proc(t: ^testing.T) {
	// A sum past 64 bits gives the largest value, not a deadline below now.
	testing.expect_value(t, deadline(max(u64), 1, 0), max(u64))
	testing.expect_value(t, deadline(max(u64) - 1, 1, 0), max(u64))
	testing.expect_value(t, deadline(1, max(u64), max(u64)), max(u64))
	testing.expect_value(t, deadline(max(u64) - FREQUENCY_MOST, MICROSECONDS_IN_A_SECOND, 0), max(u64))
	// No wait: the deadline is now.
	testing.expect_value(t, deadline(0, 0, 0), u64(0))
	testing.expect_value(t, deadline(12345, 0, FREQUENCY_LEAST), u64(12345))
	testing.expect_value(t, deadline(1000, 10, FREQUENCY_LEAST), u64(1010))
}
