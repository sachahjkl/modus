#+build !freestanding
package stolen_time

import "core:testing"

// A frequency of the cycle counter of the hosts of the tests: 3.8 GHz.
@(private = "file")
FREQUENCY :: u64(3_800_000_000)

// The machine of the tests under KVM: the hypervisor bit, the KVM leaves,
// and the steal time with each other feature of KVM.
@(private = "file")
kvm_with_steal_time :: proc() -> Identification {
	return {hypervisor_present = true, kvm_leaves_found = true, kvm_features = max(u32)}
}

// The signature is the three registers in their order: any other order, a
// change of one byte, and the registers of no hypervisor are refused.
@(test)
the_signature_of_kvm :: proc(t: ^testing.T) {
	testing.expect(t, !is_kvm_signature(0, 0, 0))
	testing.expect(t, !is_kvm_signature(KVM_SIGNATURE_C, KVM_SIGNATURE_B, KVM_SIGNATURE_D))
	testing.expect(t, !is_kvm_signature(KVM_SIGNATURE_B, KVM_SIGNATURE_C, KVM_SIGNATURE_D + 1))
	testing.expect(t, !is_kvm_signature(KVM_SIGNATURE_B ~ 1 << 24, KVM_SIGNATURE_C, KVM_SIGNATURE_D))
	testing.expect(t, !is_kvm_signature(max(u32), max(u32), max(u32)))
	// "Microsoft Hv", the signature of another hypervisor at the first base.
	testing.expect(t, !is_kvm_signature(0x7263_694D, 0x666F_736F, 0x7648_2074))
	// The bytes of "KVMKVMKVM\0\0\0" in the order of the registers.
	signature := "KVMKVMKVM\x00\x00\x00"
	bytes := transmute([]u8)signature
	word_of :: proc(four: []u8) -> u32 {
		return u32(four[0]) | u32(four[1]) << 8 | u32(four[2]) << 16 | u32(four[3]) << 24
	}
	testing.expect(t, is_kvm_signature(word_of(bytes[0:4]), word_of(bytes[4:8]), word_of(bytes[8:12])))
}

// Each step of the decision that lacks gives its absence, and the first
// that lacks decides; the steal bit alone decides among the features.
@(test)
the_decision_from_cpuid :: proc(t: ^testing.T) {
	testing.expect_value(t, absence_of_identification({}), Absence.No_Hypervisor)
	// KVM leaves with no hypervisor bit: a real machine, whatever the leaves say.
	testing.expect_value(t, absence_of_identification({kvm_leaves_found = true, kvm_features = max(u32)}), Absence.No_Hypervisor)
	testing.expect_value(t, absence_of_identification({hypervisor_present = true}), Absence.No_Kvm_Leaves)
	// Features read with no KVM leaves come from another hypervisor.
	testing.expect_value(t, absence_of_identification({hypervisor_present = true, kvm_features = KVM_FEATURE_STEAL_TIME_BIT}), Absence.No_Kvm_Leaves)
	testing.expect_value(t, absence_of_identification({hypervisor_present = true, kvm_leaves_found = true}), Absence.No_Steal_Feature)
	testing.expect_value(t, absence_of_identification({hypervisor_present = true, kvm_leaves_found = true, kvm_features = max(u32) &~ KVM_FEATURE_STEAL_TIME_BIT}), Absence.No_Steal_Feature)
	testing.expect_value(t, absence_of_identification(kvm_with_steal_time()), Absence.None)
	testing.expect_value(t, absence_of_identification({hypervisor_present = true, kvm_leaves_found = true, kvm_features = KVM_FEATURE_STEAL_TIME_BIT}), Absence.None)
	// Each absence has a text for the boot line; None alone has none.
	for absence in Absence {
		testing.expectf(t, (ABSENCE_TEXTS[absence] == "") == (absence == .None), "the text of %v", absence)
	}
}

// The register takes an address aligned on the size of the record, never
// 0, and gets the enable bit; each address that is not aligned is refused.
@(test)
the_word_of_the_register :: proc(t: ^testing.T) {
	refused := [?]u64{0, 1, size_of(Record) - 1, size_of(Record) + 1, size_of(Record) / 2, 4096 + 8, max(u64), max(u64) &~ 1}
	for address in refused {
		value, ok := registration_value(address)
		testing.expectf(t, !ok && value == 0, "the address %x was taken", address)
	}
	value, ok := registration_value(size_of(Record))
	testing.expect(t, ok)
	testing.expect_value(t, value, u64(size_of(Record)) | REGISTRATION_ENABLE)
	value, ok = registration_value(0x1234_5000 + 3 * size_of(Record))
	testing.expect(t, ok)
	testing.expect_value(t, value & REGISTRATION_ENABLE, REGISTRATION_ENABLE)
	testing.expect_value(t, value &~ REGISTRATION_ENABLE, u64(0x1234_5000 + 3 * size_of(Record)))
}

// The version protocol: an odd version before, an odd version after, and
// two versions that differ are each a retry, at the edges of the type too.
@(test)
the_version_protocol :: proc(t: ^testing.T) {
	retries := [?][2]u32{{1, 1}, {1, 2}, {0, 2}, {2, 0}, {2, 3}, {3, 3}, {max(u32), max(u32)}, {max(u32) - 1, max(u32)}, {max(u32) - 1, 0}}
	for pair in retries {
		testing.expectf(t, !read_is_whole(pair[0], pair[1]), "the versions %d and %d were taken", pair[0], pair[1])
	}
	testing.expect(t, read_is_whole(0, 0))
	testing.expect(t, read_is_whole(2, 2))
	testing.expect(t, read_is_whole(max(u32) - 1, max(u32) - 1))
}

// The conversion: 0, one nanosecond, one second, the edge of a second,
// the frequency 0, and a time past 64 bits of cycles, which gives the
// largest value and never wraps.
@(test)
nanoseconds_become_cycles :: proc(t: ^testing.T) {
	testing.expect_value(t, cycles_of_nanoseconds(0, FREQUENCY), u64(0))
	testing.expect_value(t, cycles_of_nanoseconds(max(u64), 0), u64(0))
	testing.expect_value(t, cycles_of_nanoseconds(1, FREQUENCY), FREQUENCY / NANOSECONDS_PER_SECOND)
	testing.expect_value(t, cycles_of_nanoseconds(NANOSECONDS_PER_SECOND, FREQUENCY), FREQUENCY)
	testing.expect_value(t, cycles_of_nanoseconds(NANOSECONDS_PER_SECOND - 1, FREQUENCY), (NANOSECONDS_PER_SECOND - 1) * FREQUENCY / NANOSECONDS_PER_SECOND)
	testing.expect_value(t, cycles_of_nanoseconds(NANOSECONDS_PER_SECOND + 1, FREQUENCY), FREQUENCY + FREQUENCY / NANOSECONDS_PER_SECOND)
	testing.expect_value(t, cycles_of_nanoseconds(1_000_000, FREQUENCY), FREQUENCY / 1000)
	// A frequency whose product with a rest is past 64 bits.
	testing.expect_value(t, cycles_of_nanoseconds(NANOSECONDS_PER_SECOND - 1, max(u64)), max(u64))
	testing.expect_value(t, cycles_of_nanoseconds(max(u64), FREQUENCY), max(u64))
	testing.expect_value(t, cycles_of_nanoseconds(max(u64), 1), max(u64) / NANOSECONDS_PER_SECOND)
	// The largest whole time below the largest value.
	seconds := max(u64) / FREQUENCY
	testing.expect_value(t, cycles_of_nanoseconds(seconds * NANOSECONDS_PER_SECOND, FREQUENCY), seconds * FREQUENCY)
}

// A counter that goes back is refused: the whole run is charged, never
// more, never a negative charge, and the counter now is the start of the
// next charge, which is then right.
@(test)
a_counter_that_goes_back :: proc(t: ^testing.T) {
	runs := [?]u64{0, 1, FREQUENCY, max(u64)}
	for run in runs {
		charged, next_counted, outcome := charge_without_stolen(run, 1000, 999, FREQUENCY)
		testing.expect_value(t, outcome, Charge_Outcome.Counter_Went_Back)
		testing.expect_value(t, charged, run)
		testing.expect_value(t, next_counted, u64(999))
		charged, next_counted, outcome = charge_without_stolen(run, max(u64), 0, FREQUENCY)
		testing.expect_value(t, outcome, Charge_Outcome.Counter_Went_Back)
		testing.expect_value(t, charged, run)
		testing.expect_value(t, next_counted, u64(0))
	}
	// After the refusal, 1 ms stolen from a run of 2 ms leaves 1 ms.
	_, next_counted, _ := charge_without_stolen(FREQUENCY / 500, 5_000_000, 0, FREQUENCY)
	charged, _, outcome := charge_without_stolen(FREQUENCY / 500, next_counted, 1_000_000, FREQUENCY)
	testing.expect_value(t, outcome, Charge_Outcome.Subtracted)
	testing.expect_value(t, charged, FREQUENCY / 1000)
}

// The stolen time is at most the run: a counter that moved more than the
// run, by any amount up to the largest value, charges 0 and never wraps.
@(test)
the_stolen_time_is_at_most_the_run :: proc(t: ^testing.T) {
	run := FREQUENCY / 1000 // 1 ms.
	moves := [?]u64{1_000_000, 1_000_001, NANOSECONDS_PER_SECOND, max(u64)}
	for move in moves {
		charged, next_counted, outcome := charge_without_stolen(run, 0, move, FREQUENCY)
		testing.expect_value(t, outcome, Charge_Outcome.Subtracted)
		testing.expectf(t, charged == 0, "a move of %d ns charged %d cycles", move, charged)
		testing.expect_value(t, next_counted, move)
	}
	// A run of 0, the pick of a thread: nothing charged, the counter moves.
	charged, next_counted, _ := charge_without_stolen(0, 10, 20, FREQUENCY)
	testing.expect_value(t, charged, u64(0))
	testing.expect_value(t, next_counted, u64(20))
	// The frequency is not measured yet: nothing is subtracted.
	charged, _, _ = charge_without_stolen(run, 0, NANOSECONDS_PER_SECOND, 0)
	testing.expect_value(t, charged, run)
}

// The successful cases, last: no stolen time charges the whole run, also
// the largest run; a part stolen leaves the rest.
@(test)
a_charge_without_the_stolen_time :: proc(t: ^testing.T) {
	charged, next_counted, outcome := charge_without_stolen(FREQUENCY, 77, 77, FREQUENCY)
	testing.expect_value(t, outcome, Charge_Outcome.Subtracted)
	testing.expect_value(t, charged, FREQUENCY)
	testing.expect_value(t, next_counted, u64(77))
	charged, _, _ = charge_without_stolen(max(u64), max(u64), max(u64), FREQUENCY)
	testing.expect_value(t, charged, max(u64))
	// The fault of the full check: 327 ms charged in one second, of which
	// the budget ran 50 ms; 277 ms stolen leave the 50 ms.
	charged, _, _ = charge_without_stolen(FREQUENCY * 327 / 1000, 0, 277_000_000, FREQUENCY)
	testing.expect_value(t, charged, FREQUENCY * 50 / 1000)
	// One nanosecond stolen from one tick.
	charged, _, _ = charge_without_stolen(FREQUENCY / 1000, 1000, 1001, FREQUENCY)
	testing.expect_value(t, charged, FREQUENCY / 1000 - FREQUENCY / NANOSECONDS_PER_SECOND)
}
