#+build !freestanding
package iommu

import "core:testing"

// The refusals first: the window 0, a window past the count, a window that
// is free, then the table full at WINDOW_COUNT - 1 windows; the last case is
// a window given back and taken again.
@(test)
the_windows_are_taken_given_back_and_taken_again :: proc(t: ^testing.T) {
	table: Window_Table
	testing.expect(t, !window_give(&table, 0))
	testing.expect(t, !window_give(&table, u32(WINDOW_COUNT)))
	testing.expect(t, !window_give(&table, max(u32)))
	testing.expect(t, !window_give(&table, 5))
	for expected in u32(1) ..< u32(WINDOW_COUNT) {
		window, ok := window_take(&table)
		testing.expect(t, ok)
		testing.expect_value(t, window, expected)
	}
	testing.expect_value(t, WINDOW_COUNT - 1, 2047)
	_, full := window_take(&table)
	testing.expect(t, !full, "a window past the 2047 is given")
	testing.expect(t, window_table_full(&table))
	testing.expect(t, window_give(&table, 5))
	testing.expect(t, !window_table_full(&table))
	testing.expect(t, !window_give(&table, 5), "a window is given back twice")
	again, ok := window_take(&table)
	testing.expect(t, ok)
	testing.expect_value(t, again, u32(5))
	_, full = window_take(&table)
	testing.expect(t, !full)
	// Each window ends where a domain of 39 bits ends.
	testing.expect_value(t, window_address(u32(WINDOW_COUNT - 1)) + WINDOW_SIZE, u64(1) << 39)
}
