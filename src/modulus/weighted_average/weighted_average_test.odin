#+build !freestanding
package weighted_average

import op "modus:contract/operation"
import "core:testing"

// reference gives the mean of the same clamped keys with a 128-bit sum,
// rounded down, on the host.
reference :: proc(weights: []u32, keys: []i64) -> i64 {
	sum: i128
	total: i128
	for weight, index in weights {
		sum += i128(weight) * i128(clamp(keys[index], -KEY_LIMIT, KEY_LIMIT))
		total += i128(weight)
	}
	if total == 0 {
		return 0
	}
	quotient := sum / total
	if sum % total != 0 && sum < 0 {
		quotient -= 1
	}
	return i64(quotient)
}

mean_of :: proc(weights: []u32, keys: []i64) -> i64 {
	sum: Weighted_Sum
	for weight, index in weights {
		add(&sum, weight, keys[index])
	}
	return mean(sum)
}

// The edges first: no thread, a weight of 0, one thread at each clamp,
// keys past the clamp, the largest table at the full weight and the
// largest key of each sign, where a sum of 64 bits overflows.
@(test)
the_mean_holds_at_the_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, mean(Weighted_Sum{}), 0)
	testing.expect_value(t, mean_of({0}, {KEY_LIMIT}), 0)
	testing.expect_value(t, mean_of({1}, {KEY_LIMIT}), KEY_LIMIT)
	testing.expect_value(t, mean_of({1}, {-KEY_LIMIT}), -KEY_LIMIT)
	testing.expect_value(t, mean_of({op.WEIGHT_FULL}, {max(i64)}), KEY_LIMIT)
	testing.expect_value(t, mean_of({op.WEIGHT_FULL}, {min(i64)}), -KEY_LIMIT)
	testing.expect_value(t, mean_of({1, 3}, {10, -20}), -13)
	testing.expect_value(t, mean_of({1, 1}, {-1, 0}), -1)

	weights := make([]u32, THREADS_MOST)
	keys := make([]i64, THREADS_MOST)
	defer delete(weights)
	defer delete(keys)
	for sign in ([?]i64{1, -1}) {
		for index in 0 ..< THREADS_MOST {
			weights[index] = op.WEIGHT_FULL
			keys[index] = sign * KEY_LIMIT
		}
		testing.expect_value(t, mean_of(weights, keys), sign * KEY_LIMIT)
		testing.expect_value(t, mean_of(weights, keys), reference(weights, keys))
	}
	// Half of each side, and one thread of weight 1 far behind.
	for index in 0 ..< THREADS_MOST {
		keys[index] = index % 2 == 0 ? KEY_LIMIT : -KEY_LIMIT + 1
		weights[index] = index == 0 ? 1 : op.WEIGHT_FULL
	}
	testing.expect_value(t, mean_of(weights, keys), reference(weights, keys))
}

// Mixed weights and keys, against the 128-bit sum.
@(test)
the_mean_matches_a_wide_sum :: proc(t: ^testing.T) {
	weights: [97]u32
	keys: [97]i64
	state := u64(0x9E37_79B9_7F4A_7C15)
	for round in 0 ..< 200 {
		count := 1 + round % len(weights)
		for index in 0 ..< count {
			state = state * 6364136223846793005 + 1442695040888963407
			weights[index] = u32(state >> 40) % (op.WEIGHT_FULL + 1)
			keys[index] = i64(state) >> u64(round % 20)
		}
		testing.expect_value(t, mean_of(weights[:count], keys[:count]), reference(weights[:count], keys[:count]))
	}
}
