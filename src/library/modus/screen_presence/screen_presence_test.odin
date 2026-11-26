#+build !freestanding
#+build !modus
package screen_presence

import "core:testing"
import "modus:contract/call_outcome"

// A refused map is no screen, whatever the size: each outcome that is not
// Succeeded.
@(test)
a_refused_map_is_no_screen :: proc(t: ^testing.T) {
	for status in call_outcome.Call_Outcome {
		if status == .Succeeded {
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
	testing.expect(t, !screen_present(.Succeeded, 0, 768), "a width of 0 is no screen")
	testing.expect(t, !screen_present(.Succeeded, 1024, 0), "a height of 0 is no screen")
	testing.expect(t, !screen_present(.Succeeded, 0, 0), "no size is no screen")
	testing.expect(t, !screen_present(.Succeeded, 0, max(u64)), "a width of 0 with the largest height is no screen")
	testing.expect(t, !screen_present(.Succeeded, max(u64), 0), "a height of 0 with the largest width is no screen")
}

// The successful cases come last: a map that passed and a size of at least
// 1 on each side.
@(test)
a_mapped_framebuffer_with_a_size_is_a_screen :: proc(t: ^testing.T) {
	testing.expect(t, screen_present(.Succeeded, 1, 1), "1 by 1 is a screen")
	testing.expect(t, screen_present(.Succeeded, 1024, 768), "the screen of the test machine is a screen")
	testing.expect(t, screen_present(.Succeeded, max(u64), max(u64)), "the largest size is a screen")
}

// The form of a screen: a refused map with no size, or with a size past
// the bounds of a screen of memory, is no screen; a refused map with a
// size inside them is a screen of memory, at each bound; a map that passed
// with a size is a screen of a device, whatever the size.
@(test)
the_form_of_a_screen_at_its_edges :: proc(t: ^testing.T) {
	testing.expect_value(t, screen_form(.Argument_Refused, 0, 0), Screen_Form.None)
	testing.expect_value(t, screen_form(.Argument_Refused, 319, 240), Screen_Form.None)
	testing.expect_value(t, screen_form(.Argument_Refused, 320, 239), Screen_Form.None)
	testing.expect_value(t, screen_form(.Argument_Refused, 7681, 4320), Screen_Form.None)
	testing.expect_value(t, screen_form(.Argument_Refused, 7680, 4321), Screen_Form.None)
	testing.expect_value(t, screen_form(.Argument_Refused, max(u64), max(u64)), Screen_Form.None)
	testing.expect_value(t, screen_form(.Succeeded, 0, 1080), Screen_Form.None)
	testing.expect_value(t, screen_form(.Argument_Refused, 320, 240), Screen_Form.Memory)
	testing.expect_value(t, screen_form(.Argument_Refused, 7680, 4320), Screen_Form.Memory)
	testing.expect_value(t, screen_form(.Argument_Refused, 1920, 1080), Screen_Form.Memory)
	testing.expect_value(t, screen_form(.Succeeded, 1, 1), Screen_Form.Device)
	testing.expect_value(t, screen_form(.Succeeded, 1920, 1080), Screen_Form.Device)
}
