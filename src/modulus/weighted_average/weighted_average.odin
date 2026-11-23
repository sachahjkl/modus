// The weighted average of the keys of a run queue, for EEVDF
// (docs/SCHEDULING.md, "Integer arithmetic and the overflow argument").
//
// One product of a weight and a key fits in 64 bits, but the sum of the
// products of every thread of the machine does not: a weight is at most
// op.WEIGHT_FULL (2^13), a key at most KEY_LIMIT (2^44), and a queue can
// hold each of the 4096 threads of the largest table. The sum is kept in
// two words, and the mean is a division of that wide sum by the sum of the
// weights, in 64-bit steps: no 128-bit type, whose division is a call of
// the runtime on each target and the slow path of a pick.
//
// This package allocates no memory and calls no kernel operation.
package weighted_average

import op "modus:contract/operation"
import "modulus:table_sizes"

// The largest distance of a key to the queue clock, in weighted cycles.
KEY_LIMIT :: i64(1) << 44
// The most threads of one queue: each thread of the largest table.
THREADS_MOST :: table_sizes.THREADS_MOST
// The sum of the weights of one queue fits in 32 bits, which keeps the
// steps of the division in 64 bits.
WEIGHTS_MOST :: u64(THREADS_MOST) * u64(op.WEIGHT_FULL)
#assert(WEIGHTS_MOST < u64(1) << 32)
// One product fits in 63 bits with its sign.
#assert(u64(op.WEIGHT_FULL) * u64(KEY_LIMIT) < u64(1) << 62)

// A sum of products of a weight and a key: high * 2^32 + low, with low
// below 2^32 after each add. weights is the sum of the weights.
Weighted_Sum :: struct {
	high:    i64,
	low:     u64,
	weights: u64,
}

// add adds one thread: its weight, and its key clamped to KEY_LIMIT on
// each side. A weight of 0 adds nothing.
add :: #force_inline proc "contextless" (sum: ^Weighted_Sum, weight: u32, key: i64) {
	product := i64(weight) * clamp(key, -KEY_LIMIT, KEY_LIMIT)
	// The shift keeps the sign in the high part; the low part is the 32
	// bits under it, from 0 to 2^32 - 1, so the two give back the product.
	sum.high += product >> 32
	sum.low += u64(product) & 0xFFFF_FFFF
	sum.high += i64(sum.low >> 32)
	sum.low &= 0xFFFF_FFFF
	sum.weights += u64(weight)
}

// mean gives the sum of the products divided by the sum of the weights,
// rounded down, and 0 when no weight was added. The mean of clamped keys
// is within KEY_LIMIT of 0.
//
// Example: the keys 10 and -20 with the weights 1 and 3 give
// (10 - 60) / 4 = -12.5, so -13.
mean :: proc "contextless" (sum: Weighted_Sum) -> i64 {
	if sum.weights == 0 {
		return 0
	}
	divisor := i64(sum.weights)
	// The high part rounded down, with a remainder from 0 to divisor - 1.
	quotient_high := sum.high / divisor
	remainder := sum.high - quotient_high * divisor
	if remainder < 0 {
		quotient_high -= 1
		remainder += divisor
	}
	// remainder * 2^32 + low is below 2^58: one division of 64 bits.
	rest := (u64(remainder) << 32) | sum.low
	return quotient_high * (i64(1) << 32) + i64(rest / u64(divisor))
}
