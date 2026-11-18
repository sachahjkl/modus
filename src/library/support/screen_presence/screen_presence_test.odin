#+build !freestanding
package screen_presence

import "core:testing"
import op "modus:contract/operation"

// A refused map is no screen, whatever the size: each status that is not Ok.
@(test)
a_refused_map_is_no_screen :: proc(t: ^testing.T) {
	for status in op.Status {
		if status == .Ok {
			continue
		}
		testing.expect(t, !screen_present(status, 1024, 768), "a refused map with a size is no screen")
		testing.expect(t, !screen_present(status, 0, 0), "a refused map with no size is no screen")
	}
}

// A size of 0 on one side is no screen, with a map that passed: the width,
// the height, and both.
@(test)
a_size_of_zero_is_no_screen :: proc(t: ^testing.T) {
	testing.expect(t, !screen_present(.Ok, 0, 768), "a width of 0 is no screen")
	testing.expect(t, !screen_present(.Ok, 1024, 0), "a height of 0 is no screen")
	testing.expect(t, !screen_present(.Ok, 0, 0), "no size is no screen")
	testing.expect(t, !screen_present(.Ok, 0, max(u64)), "a width of 0 with the largest height is no screen")
	testing.expect(t, !screen_present(.Ok, max(u64), 0), "a height of 0 with the largest width is no screen")
}

// The successful cases come last: a map that passed and a size of at least
// 1 on each side.
@(test)
a_mapped_framebuffer_with_a_size_is_a_screen :: proc(t: ^testing.T) {
	testing.expect(t, screen_present(.Ok, 1, 1), "1 by 1 is a screen")
	testing.expect(t, screen_present(.Ok, 1024, 768), "the screen of the test machine is a screen")
	testing.expect(t, screen_present(.Ok, max(u64), max(u64)), "the largest size is a screen")
}
