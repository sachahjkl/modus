#+build !freestanding
package share_order

import "core:testing"

// Zero inputs, equal ratios, inverted ratios, and max(u64) boundaries.
@(test)
ratio_decreased_edges_and_ordering :: proc(t: ^testing.T) {
	// Any zero input is refused.
	testing.expect(t, !ratio_decreased(0, 0, 0, 0))
	testing.expect(t, !ratio_decreased(0, 800, 100, 100))
	testing.expect(t, !ratio_decreased(100, 0, 100, 100))
	testing.expect(t, !ratio_decreased(100, 800, 0, 100))
	testing.expect(t, !ratio_decreased(100, 800, 100, 0))

	// Equal ratios are not strictly smaller.
	testing.expect(t, !ratio_decreased(1, 1, 1, 1))
	testing.expect(t, !ratio_decreased(100, 800, 200, 1600))
	testing.expect(t, !ratio_decreased(max(u64), max(u64), max(u64), max(u64)))

	// Larger ratio under policy is refused.
	testing.expect(t, !ratio_decreased(100, 200, 100, 300))

	// Smaller ratio under policy is accepted, including at u64 extremes.
	testing.expect(t, ratio_decreased(100, 800, 100, 100))
	testing.expect(t, ratio_decreased(1, max(u64), 2, max(u64)))
	testing.expect(t, ratio_decreased(max(u64) - 1, max(u64), max(u64), max(u64)))
}

// scale_part_u64 handles 0, 1, part == total, part > total, and max(u64)
// without overflow.
@(test)
scale_part_u64_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, scale_part_u64(0, 0, SHARE_SCALE), u64(0))
	testing.expect_value(t, scale_part_u64(10, 0, SHARE_SCALE), u64(0))
	testing.expect_value(t, scale_part_u64(0, 10, SHARE_SCALE), u64(0))
	testing.expect_value(t, scale_part_u64(5, 10, 0), u64(0))
	testing.expect_value(t, scale_part_u64(1, 2, SHARE_SCALE), SHARE_SCALE / 2)
	testing.expect_value(t, scale_part_u64(10, 10, SHARE_SCALE), SHARE_SCALE)
	testing.expect_value(t, scale_part_u64(25, 10, SHARE_SCALE), SHARE_SCALE)
	// Extreme values near max(u64) must not overflow.
	half := scale_part_u64(max(u64) / 2, max(u64), SHARE_SCALE)
	testing.expect(t, half >= SHARE_SCALE / 2 - 2 && half <= SHARE_SCALE / 2 + 2)
	testing.expect_value(t, scale_part_u64(max(u64), max(u64), SHARE_SCALE), SHARE_SCALE)
}

// processors_ran_enough refuses zero counts, negative/zero processor counts,
// idle inputs, and any active processor below minimum_ticks.
@(test)
processors_ran_enough_edges :: proc(t: ^testing.T) {
	on_cpu: [PROCESS_CAPACITY][PROCESSOR_CAPACITY]u64
	busy: [PROCESSOR_CAPACITY]u64

	testing.expect(t, !processors_ran_enough(on_cpu, busy, 0, 30))
	testing.expect(t, !processors_ran_enough(on_cpu, busy, -1, 30))
	testing.expect(t, !processors_ran_enough(on_cpu, busy, 4, 0))
	testing.expect(t, !processors_ran_enough(on_cpu, busy, 4, 30))

	// CPU 0 active at bound - 1 fails; at bound succeeds; inactive CPU 1 is ignored.
	on_cpu[0][0] = 10
	busy[0] = 29
	testing.expect(t, !processors_ran_enough(on_cpu, busy, 4, 30))
	busy[0] = 30
	testing.expect(t, processors_ran_enough(on_cpu, busy, 4, 30))

	// Second active CPU below bound fails until it reaches bound.
	on_cpu[3][2] = 5
	busy[2] = 29
	testing.expect(t, !processors_ran_enough(on_cpu, busy, 4, 30))
	busy[2] = 30
	testing.expect(t, processors_ran_enough(on_cpu, busy, 4, 30))

	// Processor count past PROCESSOR_CAPACITY clamps cleanly without panic.
	testing.expect(t, processors_ran_enough(on_cpu, busy, PROCESSOR_CAPACITY + 10, 30))
}

// Host core skew: in the "without" interval the single-thread process sits on
// a fast core (1000 ticks) while the other 3 cores are starved (40 ticks); in
// the "with" interval the single-thread process sits on a starved core (40
// ticks) while the other 3 cores are fast (1000 ticks). Raw totals invert the
// ordering and fail, while per-processor normalization recovers the true
// kernel ordering.
@(test)
host_core_skew_does_not_invert_normalized_order :: proc(t: ^testing.T) {
	// Without policy: spinner_1 (process 0) gets 25% of CPU 3; spinner_8
	// (process 3) gets 50% of each of CPUs 0..3.
	without_cpu: [PROCESS_CAPACITY][PROCESSOR_CAPACITY]u64
	without_busy: [PROCESSOR_CAPACITY]u64
	without_busy[0], without_busy[1], without_busy[2], without_busy[3] = 40, 40, 40, 1000
	without_cpu[0][3] = 250
	without_cpu[3][0], without_cpu[3][1], without_cpu[3][2], without_cpu[3][3] = 20, 20, 20, 500

	// With policy: spinner_1 gets 67.5% of starved CPU 3 (27 of 40 ticks);
	// spinner_8 gets 17.5% of CPU 3 (7 of 40) and 35% of fast CPUs 0..2 (350 each).
	with_cpu: [PROCESS_CAPACITY][PROCESSOR_CAPACITY]u64
	with_busy: [PROCESSOR_CAPACITY]u64
	with_busy[0], with_busy[1], with_busy[2], with_busy[3] = 1000, 1000, 1000, 40
	with_cpu[0][3] = 27
	with_cpu[3][0], with_cpu[3][1], with_cpu[3][2], with_cpu[3][3] = 350, 350, 350, 7

	// Confirm raw totals would have falsely failed under this host skew.
	raw_without_0 := without_cpu[0][3]
	raw_without_3 := without_cpu[3][0] + without_cpu[3][1] + without_cpu[3][2] + without_cpu[3][3]
	raw_with_0 := with_cpu[0][3]
	raw_with_3 := with_cpu[3][0] + with_cpu[3][1] + with_cpu[3][2] + with_cpu[3][3]
	testing.expect(t, !ratio_decreased(raw_without_0, raw_without_3, raw_with_0, raw_with_3))

	// Normalized per-processor shares recover the exact kernel ordering.
	without_norm := normalized_process_shares(without_cpu, without_busy, 4)
	with_norm := normalized_process_shares(with_cpu, with_busy, 4)
	testing.expect(t, ratio_decreased(without_norm[0], without_norm[3], with_norm[0], with_norm[3]))
}
