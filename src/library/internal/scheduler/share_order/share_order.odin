// Per-processor tick normalization and share-order comparison for the
// share-policy check of scheduler (src/md/features/stolen_time.md).
//
// Normalizing each process's ticks on a processor by that processor's total
// busy ticks removes host core-scheduling skew: a processor that the host
// runs less gets fewer ticks, but the share of that processor's ticks given
// to each process still reflects the kernel scheduler's weights alone.
//
// This package allocates no memory and calls no kernel operation.
package share_order

PROCESSOR_CAPACITY :: 64
PROCESS_CAPACITY :: 4

// One full processor equals SHARE_SCALE parts per million in fixed point.
SHARE_SCALE :: u64(1_000_000)

// saturating_add_u64 adds two u64 values and clamps at max(u64) on overflow.
saturating_add_u64 :: #force_inline proc "contextless" (a, b: u64) -> u64 {
	if a > max(u64) - b {
		return max(u64)
	}
	return a + b
}

// scale_part_u64 computes floor(min(part, total) * scale / total) using u64
// arithmetic only, with no overflow for any u64 inputs up to max(u64).
scale_part_u64 :: proc "contextless" (part, total, scale: u64) -> u64 {
	if total == 0 || part == 0 || scale == 0 {
		return 0
	}
	if part >= total {
		return scale
	}
	if part <= max(u64) / scale {
		return (part * scale) / total
	}
	// Shift both operands right until part * scale fits in u64. Because
	// part < total and part > max(u64) / scale, total stays non-zero.
	scaled_part := part
	scaled_total := total
	limit := max(u64) / scale
	for scaled_part > limit {
		scaled_part >>= 1
		scaled_total >>= 1
	}
	if scaled_total == 0 {
		return scale
	}
	return (scaled_part * scale) / scaled_total
}

// normalized_process_shares sums each process's share of every active
// processor's busy ticks, scaled by SHARE_SCALE per processor. When the sum
// of attributed process ticks on a processor exceeds the processor's sampled
// busy ticks (due to non-atomic report reads), the larger sum is used as the
// denominator so a process never exceeds 100% of one processor.
normalized_process_shares :: proc "contextless" (
	process_on_cpu: [PROCESS_CAPACITY][PROCESSOR_CAPACITY]u64,
	processor_ticks: [PROCESSOR_CAPACITY]u64,
	processor_count: int,
) -> (shares: [PROCESS_CAPACITY]u64) {
	count := min(max(processor_count, 0), PROCESSOR_CAPACITY)
	for cpu in 0 ..< count {
		attributed_sum: u64
		for process in 0 ..< PROCESS_CAPACITY {
			attributed_sum = saturating_add_u64(attributed_sum, process_on_cpu[process][cpu])
		}
		denom := max(processor_ticks[cpu], attributed_sum)
		if denom == 0 {
			continue
		}
		for process in 0 ..< PROCESS_CAPACITY {
			shares[process] = saturating_add_u64(shares[process], scale_part_u64(process_on_cpu[process][cpu], denom, SHARE_SCALE))
		}
	}
	return shares
}

// processors_ran_enough reports whether at least one processor that ran any
// checked thread reached minimum_ticks busy ticks, and every processor that
// ran any checked thread reached minimum_ticks busy ticks.
processors_ran_enough :: proc "contextless" (
	process_on_cpu: [PROCESS_CAPACITY][PROCESSOR_CAPACITY]u64,
	processor_ticks: [PROCESSOR_CAPACITY]u64,
	processor_count: int,
	minimum_ticks: u64,
) -> bool {
	if minimum_ticks == 0 {
		return false
	}
	count := min(max(processor_count, 0), PROCESSOR_CAPACITY)
	if count == 0 {
		return false
	}
	active_processors := 0
	for cpu in 0 ..< count {
		ran_here := false
		for process in 0 ..< PROCESS_CAPACITY {
			if process_on_cpu[process][cpu] > 0 {
				ran_here = true
				break
			}
		}
		if !ran_here {
			continue
		}
		active_processors += 1
		if processor_ticks[cpu] < minimum_ticks {
			return false
		}
	}
	return active_processors > 0
}

// ratio_decreased reports whether (with_large / with_small) is strictly less
// than (without_large / without_small). Any zero value is refused (false).
ratio_decreased :: proc "contextless" (without_small, without_large, with_small, with_large: u64) -> bool {
	if without_small == 0 || without_large == 0 || with_small == 0 || with_large == 0 {
		return false
	}
	return u128(with_large) * u128(without_small) < u128(without_large) * u128(with_small)
}
