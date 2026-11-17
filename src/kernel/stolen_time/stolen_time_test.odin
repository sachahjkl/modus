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

// The highest leaf that the base of KVM gives: below the base plus the
// offset of the features, the leaf of the features does not exist and the
// machine has no steal time, whatever the features say; 0 (an old KVM) and
// the leaf of the features itself are accepted.
@(test)
the_highest_leaf_of_kvm :: proc(t: ^testing.T) {
	base := HYPERVISOR_LEAF_FIRST
	refused := [?]u32{1, base - 1, base, base + KVM_FEATURES_LEAF_OFFSET - 1}
	for highest_leaf in refused {
		testing.expectf(t, !features_leaf_present(base, highest_leaf), "the highest leaf %x was taken", highest_leaf)
		identification := Identification{hypervisor_present = true, kvm_leaves_found = true, kvm_base = base, kvm_highest_leaf = highest_leaf, kvm_features = KVM_FEATURE_STEAL_TIME_BIT}
		testing.expect_value(t, absence_of_identification(identification), Absence.No_Kvm_Features_Leaf)
	}
	// A later base: a highest leaf of the first base is below it.
	later := HYPERVISOR_LEAF_FIRST + HYPERVISOR_LEAF_STEP
	testing.expect(t, !features_leaf_present(later, base + KVM_FEATURES_LEAF_OFFSET))
	// A base at the largest value of the type does not wrap.
	testing.expect(t, !features_leaf_present(max(u32), max(u32)))
	accepted := [?]u32{0, base + KVM_FEATURES_LEAF_OFFSET, base + KVM_FEATURES_LEAF_OFFSET + 1, max(u32)}
	for highest_leaf in accepted {
		testing.expectf(t, features_leaf_present(base, highest_leaf), "the highest leaf %x was refused", highest_leaf)
		identification := Identification{hypervisor_present = true, kvm_leaves_found = true, kvm_base = base, kvm_highest_leaf = highest_leaf, kvm_features = KVM_FEATURE_STEAL_TIME_BIT}
		testing.expect_value(t, absence_of_identification(identification), Absence.None)
	}
	testing.expect(t, features_leaf_present(later, later + KVM_FEATURES_LEAF_OFFSET))
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
	// The third guard: the most whole seconds, then the largest rest. The
	// seconds alone fit, the rest alone fits, and their sum is past 64 bits:
	// max(u64) - seconds * FREQUENCY is below the cycles of the rest.
	largest_rest := NANOSECONDS_PER_SECOND - 1
	testing.expect(t, max(u64) - seconds * FREQUENCY < largest_rest * FREQUENCY / NANOSECONDS_PER_SECOND)
	testing.expect_value(t, cycles_of_nanoseconds(seconds * NANOSECONDS_PER_SECOND + largest_rest, FREQUENCY), max(u64))
	// The frequency 1 with a rest: the rest gives less than one cycle.
	testing.expect_value(t, cycles_of_nanoseconds(NANOSECONDS_PER_SECOND + largest_rest, 1), u64(1))
	testing.expect_value(t, cycles_of_nanoseconds(largest_rest, 1), u64(0))
	testing.expect_value(t, cycles_of_nanoseconds(3 * NANOSECONDS_PER_SECOND + NANOSECONDS_PER_SECOND / 2, 1), u64(3))
	// The second guard at its edge: the frequency max / rest still
	// converts, one above it gives the largest value.
	edge := max(u64) / largest_rest
	testing.expect_value(t, cycles_of_nanoseconds(largest_rest, edge), largest_rest * edge / NANOSECONDS_PER_SECOND)
	testing.expect_value(t, cycles_of_nanoseconds(largest_rest, edge + 1), max(u64))
	small_rest := u64(7)
	small_edge := max(u64) / small_rest
	testing.expect_value(t, cycles_of_nanoseconds(small_rest, small_edge), small_rest * small_edge / NANOSECONDS_PER_SECOND)
	testing.expect_value(t, cycles_of_nanoseconds(small_rest, small_edge + 1), max(u64))
}

// The records of the tests of read_steal: one series of loads, played in
// order, the version and the counter as the record gives them.
@(private = "file")
Played_Loads :: struct {
	versions:      []u64, // The versions, in the order of their loads; the last one repeats.
	steal:         u64,
	version_loads: int,
	steal_loads:   int,
}

@(private = "file")
played_load :: proc "contextless" (source: rawptr, field: Record_Field) -> u64 {
	played := (^Played_Loads)(source)
	switch field {
	case .Version:
		at := min(played.version_loads, len(played.versions) - 1)
		played.version_loads += 1
		return played.versions[at]
	case .Steal:
		played.steal_loads += 1
		return played.steal
	}
	return 0
}

// A version that never becomes even, and versions that differ at each
// attempt, give no counter after READ_ATTEMPT_LIMIT attempts and never
// more; the loads stop there.
@(test)
a_read_that_never_holds :: proc(t: ^testing.T) {
	odd := [?]u64{1}
	played := Played_Loads{versions = odd[:], steal = 1234}
	steal, whole := read_steal(&played, played_load)
	testing.expect(t, !whole)
	testing.expect_value(t, steal, u64(0))
	testing.expect_value(t, played.version_loads, 2 * READ_ATTEMPT_LIMIT)
	testing.expect_value(t, played.steal_loads, READ_ATTEMPT_LIMIT)
	// Even versions that move by 2 between each two loads: never equal.
	moving: [2 * READ_ATTEMPT_LIMIT + 1]u64
	for &version, index in moving {
		version = u64(2 * index)
	}
	played = Played_Loads{versions = moving[:], steal = 1234}
	steal, whole = read_steal(&played, played_load)
	testing.expect(t, !whole)
	testing.expect_value(t, steal, u64(0))
	// The host ends its write at the last attempt: the read holds there.
	last: [2 * READ_ATTEMPT_LIMIT]u64
	for &version, index in last {
		version = index < 2 * (READ_ATTEMPT_LIMIT - 1) ? 3 : 4
	}
	played = Played_Loads{versions = last[:], steal = 1234}
	steal, whole = read_steal(&played, played_load)
	testing.expect(t, whole)
	testing.expect_value(t, steal, u64(1234))
	testing.expect_value(t, played.steal_loads, READ_ATTEMPT_LIMIT)
	// One attempt past the bound is not made: the write ends one load too late.
	late: [2 * READ_ATTEMPT_LIMIT + 1]u64
	for &version, index in late {
		version = index < 2 * READ_ATTEMPT_LIMIT ? 3 : 4
	}
	played = Played_Loads{versions = late[:], steal = 1234}
	_, whole = read_steal(&played, played_load)
	testing.expect(t, !whole)
	// The successful case, last: an even version on the first attempt.
	even := [?]u64{6}
	played = Played_Loads{versions = even[:], steal = max(u64)}
	steal, whole = read_steal(&played, played_load)
	testing.expect(t, whole)
	testing.expect_value(t, steal, max(u64))
	testing.expect_value(t, played.version_loads, 2)
	testing.expect_value(t, played.steal_loads, 1)
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

// A host that reports false steal time. The kernel sets no cap on it: the
// host can stop the machine or change its memory anyway, and a cap would
// refuse the true steal time of a loaded host. One false jump costs at most
// one run, because the excess is not carried; a host that raises the
// counter by at least the run at each charge makes each charge 0, with no
// bound. This test states the chosen behaviour.
@(test)
a_host_that_reports_false_steal_time :: proc(t: ^testing.T) {
	run := FREQUENCY / 1000 // 1 ms.
	RUNS :: 100
	// One jump of the counter by far more than any run, at the fourth charge.
	counted, steal, total := u64(0), u64(0), u64(0)
	for index in 0 ..< RUNS {
		if index == 3 {
			steal += max(u64) / 2
		}
		charged: u64
		charged, counted, _ = charge_without_stolen(run, counted, steal, FREQUENCY)
		total += charged
	}
	testing.expect_value(t, total, (RUNS - 1) * run)
	// A counter raised by exactly one run at each charge: each charge is 0.
	counted, steal, total = 0, 0, 0
	for _ in 0 ..< RUNS {
		steal += NANOSECONDS_PER_SECOND / 1000
		charged: u64
		charged, counted, _ = charge_without_stolen(run, counted, steal, FREQUENCY)
		total += charged
	}
	testing.expect_value(t, total, u64(0))
}

// A fixed pseudo-random series of runs and moves of the counter, from a
// seed written here: no charge is above its run, the sum of the charges is
// at most the sum of the runs, and it is equal to it when the counter does
// not move.
@(test)
a_series_of_charges :: proc(t: ^testing.T) {
	SEED :: u64(0x9E37_79B9_7F4A_7C15)
	CHARGES :: 1000
	state := SEED
	// xorshift64: a fixed series, the same at each run of the test.
	next :: proc(series: ^u64) -> u64 {
		series^ ~= series^ << 13
		series^ ~= series^ >> 7
		series^ ~= series^ << 17
		return series^
	}
	counted, steal := u64(0), u64(0)
	runs_sum, charged_sum, moves := u64(0), u64(0), 0
	for _ in 0 ..< CHARGES {
		run := next(&state) % (u64(1) << 32)
		if next(&state) % 4 != 0 {
			steal += next(&state) % (2 * NANOSECONDS_PER_SECOND / 1000)
			moves += 1
		}
		charged: u64
		charged, counted, _ = charge_without_stolen(run, counted, steal, FREQUENCY)
		testing.expectf(t, charged <= run, "a charge of %d for a run of %d", charged, run)
		runs_sum += run
		charged_sum += charged
	}
	testing.expect(t, moves > 0)
	testing.expect(t, charged_sum <= runs_sum)
	testing.expect(t, charged_sum < runs_sum) // The series moves the counter: something was subtracted.
	// The same runs with a counter that never moves: each run is charged.
	state = SEED
	counted, steal = 12345, 12345
	runs_sum, charged_sum = 0, 0
	for _ in 0 ..< CHARGES {
		run := next(&state) % (u64(1) << 32)
		if next(&state) % 4 != 0 {
			_ = next(&state)
		}
		charged: u64
		charged, counted, _ = charge_without_stolen(run, counted, steal, FREQUENCY)
		runs_sum += run
		charged_sum += charged
	}
	testing.expect_value(t, charged_sum, runs_sum)
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
