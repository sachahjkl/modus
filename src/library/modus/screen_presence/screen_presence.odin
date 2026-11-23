// The one test of a screen at the start: the root service and the
// compositor both call it on the framebuffer that the kernel gave, so they
// never disagree on whether the machine has a screen
// (src/md/features/missing_hardware.md).
package screen_presence

import "modus:contract/memory_screen"
import op "modus:contract/operation"

// screen_present says if the framebuffer of the firmware is a screen: its
// memory mapped, and a width and a height that are not 0. A machine with
// no display device gives no framebuffer handle, so its map is refused.
screen_present :: proc "contextless" (map_status: op.Status, width, height: u64) -> bool {
	return map_status == .Ok && width != 0 && height != 0
}

// The form of the screen of the compositor (src/md/features/screen_of_memory.md).
Screen_Form :: enum u8 {
	None   = 0, // No screen: the compositor stops with its line.
	Device = 1, // The framebuffer of the firmware, or the screen pages of the display: it maps, with a size.
	Memory = 2, // No framebuffer, and a size of a screen of memory that the root service gave.
}

// screen_form gives the form of the screen from a context: a framebuffer
// that maps with a size is a screen of a device; a framebuffer that does
// not map, with a size inside the bounds of the contract memory_screen, is
// a screen of memory; anything else is no screen.
screen_form :: proc "contextless" (map_status: op.Status, width, height: u64) -> Screen_Form {
	if screen_present(map_status, width, height) {
		return .Device
	}
	if map_status != .Ok && memory_screen.size_in_bounds(width, height) {
		return .Memory
	}
	return .None
}
