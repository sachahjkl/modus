#+build !freestanding
package delivery_count

import "core:testing"

// No count, a count that did not grow and a count that went back give no
// line, whatever the last line was.
@(test)
a_count_that_did_not_grow_gives_no_line :: proc(t: ^testing.T) {
	testing.expect(t, !line_is_due(0, 0), "0 after no line")
	for written in ([]u64{1, 2, 3, 4, 1000, max(u64) - 1, max(u64)}) {
		testing.expectf(t, !line_is_due(written, written), "%d after %d", written, written)
		testing.expectf(t, !line_is_due(written, written - 1), "%d after %d", written - 1, written)
		testing.expectf(t, !line_is_due(written, 0), "0 after %d", written)
	}
}

// A count that grows inside its power of two gives no line.
@(test)
a_count_inside_its_power_of_two_gives_no_line :: proc(t: ^testing.T) {
	testing.expect(t, !line_is_due(2, 3), "3 after 2")
	testing.expect(t, !line_is_due(4, 7), "7 after 4")
	testing.expect(t, !line_is_due(5, 7), "7 after 5")
	// The largest power of two, then the largest value: no new power.
	testing.expect(t, !line_is_due(u64(1) << 63, max(u64)), "the largest value after 2^63")
}

// The first count, and each new power of two, give a line, also when the
// count jumps past several.
@(test)
a_count_that_reaches_a_new_power_of_two_gives_a_line :: proc(t: ^testing.T) {
	testing.expect(t, line_is_due(0, 1), "1 after no line")
	testing.expect(t, line_is_due(1, 2), "2 after 1")
	testing.expect(t, line_is_due(3, 4), "4 after 3")
	testing.expect(t, line_is_due(5, 8), "8 after 5")
	testing.expect(t, line_is_due(1, 1000), "1000 after 1")
	testing.expect(t, line_is_due(0, max(u64)), "the largest value after no line")
	testing.expect(t, line_is_due((u64(1) << 63) - 1, max(u64)), "the largest value after 2^63 - 1")
}

@(test)
the_highest_power_of_two :: proc(t: ^testing.T) {
	testing.expect_value(t, highest_power_of_two_at_most(0), u64(0))
	testing.expect_value(t, highest_power_of_two_at_most(1), u64(1))
	testing.expect_value(t, highest_power_of_two_at_most(2), u64(2))
	testing.expect_value(t, highest_power_of_two_at_most(3), u64(2))
	testing.expect_value(t, highest_power_of_two_at_most(4), u64(4))
	testing.expect_value(t, highest_power_of_two_at_most(max(u64)), u64(1) << 63)
}
