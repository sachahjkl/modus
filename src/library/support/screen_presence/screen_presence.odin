// The one test of a screen at the start: the root service and the
// compositor both call it on the framebuffer that the kernel gave, so they
// never disagree on whether the machine has a screen
// (src/md/features/missing_hardware.md).
package screen_presence

import op "modus:contract/operation"

// screen_present says if the framebuffer of the firmware is a screen: its
// memory mapped, and a width and a height that are not 0. A machine with
// no display device gives no framebuffer handle, so its map is refused.
screen_present :: proc "contextless" (map_status: op.Status, width, height: u64) -> bool {
	return map_status == .Ok && width != 0 && height != 0
}
