#+build !freestanding
#+build !modus
package module

import "core:testing"

// The test of range_holds at its edges: the values of a hostile file reach
// it, so no case may wrap.
@(test)
a_range_holds_only_the_bytes_inside_it :: proc(t: ^testing.T) {
	Case :: struct {
		start, size, offset, count: u64,
		holds:                      bool,
	}
	cases := [?]Case {
		{start = 0, size = 16, offset = 0, count = 8, holds = true},
		{start = 0, size = 16, offset = 8, count = 8, holds = true},
		{start = 0, size = 16, offset = 9, count = 8, holds = false},
		{start = 0, size = 16, offset = 16, count = 0, holds = true},
		{start = 0, size = 16, offset = 17, count = 0, holds = false},
		{start = 4096, size = 16, offset = 4095, count = 8, holds = false},
		// The case that a sum wraps: a location 8 bytes below 2^64 and a
		// segment that starts at 0. offset - start + 8 is 0, which a sum
		// would take as inside.
		{start = 0, size = 4096, offset = max(u64) - 7, count = 8, holds = false},
		// A range of max(u64) bytes from 0 ends at the byte max(u64) - 1.
		{start = 0, size = max(u64), offset = max(u64) - 8, count = 8, holds = true},
		{start = 0, size = max(u64), offset = max(u64) - 7, count = 8, holds = false},
	}
	for item in cases {
		testing.expectf(t, range_holds(item.start, item.size, item.offset, item.count) == item.holds, "range_holds(%x, %x, %x, %d) is not %v", item.start, item.size, item.offset, item.count, item.holds)
	}
}
