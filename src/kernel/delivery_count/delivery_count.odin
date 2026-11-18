// The rule of the line of a count of faults of delivery: the bytes that the
// serial port did not take, the interrupts that the controller did not
// send. A path that counts can hold any lock, so the tick writes the line,
// each time the count reaches a new power of two: a part that stays broken
// writes about one line for each doubling, not one line at each tick. The
// design is src/md/features/missing_hardware.md. The kernel holds the
// counts and their atomic operations; this package holds the rule, with
// host tests.
//
// This package allocates no memory and calls no kernel operation.
package delivery_count

// highest_power_of_two_at_most gives the largest power of two that is not
// above value, and 0 for 0.
highest_power_of_two_at_most :: proc "contextless" (value: u64) -> u64 {
	power := u64(1) << 63
	for power > value {
		power >>= 1
	}
	return power
}

// line_is_due says if a count `now` has a power of two above the count
// `written` of the last line. A count that did not grow, or went back,
// gives no line.
line_is_due :: proc "contextless" (written: u64, now: u64) -> bool {
	return highest_power_of_two_at_most(now) > written
}
