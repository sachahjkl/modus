// The reference screen: the size of the screen for which the desktop is
// laid out and on which the test machines take their pictures
// (src/md/features/desktop_to_browser.md, "The reference screen"). The boot
// program asks the firmware for this mode, the measure of a frame on the
// processor draws at this size, and the tool checks the pictures of the
// screen and the video memory of its machines against it, so the three
// agree on one size.
//
// The compositor does not read it: it takes the size of its screen from
// the framebuffer of the firmware, which is this size only when the
// firmware offers the mode.
//
// See [reference screen](term:reference-screen).
package reference_screen

WIDTH :: 1920 // In pixels of the screen.
HEIGHT :: 1080

// A mode that the firmware offers, as the boot program read it.
Screen_Mode :: struct {
	number:   u32, // The number of the mode for the firmware.
	width:    u32,
	height:   u32,
	// 32 bits for each pixel, with red, green and blue in one of the two
	// orders that the system draws. The boot program decides it from the
	// format word of the firmware, which it reads through its one border.
	drawable: bool,
}

// What mode_choose found.
Mode_Choice :: enum {
	Exact, // A drawable mode of the reference screen.
	Smaller, // No such mode: the largest drawable mode whose width and height do not pass the reference screen.
	None, // No drawable mode fits inside the reference screen: the firmware keeps the mode that it set.
}

// mode_choose gives the mode that the boot program sets. A mode larger
// than the reference screen in either side is never chosen: the
// compositor pays for its frame and its background at the size of the
// screen, and its budget is counted at the reference screen. Among the
// smaller modes the one with the most pixels wins, the first one of the
// list on a tie. A mode with a side of 0 is not a screen.
mode_choose :: proc "contextless" (modes: []Screen_Mode) -> (chosen: Screen_Mode, choice: Mode_Choice) {
	choice = .None
	for mode in modes {
		if !mode.drawable || mode.width == 0 || mode.height == 0 {
			continue
		}
		if mode.width == WIDTH && mode.height == HEIGHT {
			return mode, .Exact
		}
		if mode.width > WIDTH || mode.height > HEIGHT {
			continue
		}
		if choice == .None || u64(mode.width) * u64(mode.height) > u64(chosen.width) * u64(chosen.height) {
			chosen, choice = mode, .Smaller
		}
	}
	if choice == .None {
		return {}, .None
	}
	return
}
