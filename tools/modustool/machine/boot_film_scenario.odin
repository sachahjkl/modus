package machine

// The film of the boot, the command `modustool film boot`
// (docs/TOOLS.md, "The film").
//
// The machine of a film has a display with no window, so QEMU draws the text
// console of the boot program: the lines of its check of the system
// description, before the first picture of the system. That text stays on
// the screen for the few milliseconds of the check, and the boot display
// itself for a fraction of a second. So the machine waits for the scenario,
// and the scenario freezes it at each state that a viewer must read.
//
// After the second freeze, the root service draws the boot display again at
// each stage, the compositor takes the screen, and the desktop appears. The
// scenario then opens the window of the boot display, which draws the same
// record again each 500 ms with the records of the kernel of that time.
//
// The scenario has no key: it shows the start alone. It waits for its lines
// and holds the states for its viewer, so the film never shows a state that
// the machine did not reach.
@(rodata)
scenario_boot_film := [?]Step {
	// The machine starts when the tool is ready to freeze it: a line of the
	// start passes before the tool could see it otherwise.
	{kind = .Monitor, text = "cont"},
	// The last line of the check, before the boot program loads the kernel
	// and draws the boot display: the screen shows the whole check.
	{kind = .Wait, text = "boot program: the firmware has no TPM protocol"},
	{kind = .Monitor, text = "stop"},
	{kind = .Film_Start, text = "boot"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ + FILM_HOLD_GLANCE},
	{kind = .Monitor, text = "cont"},
	// The boot program drew the boot display and has not jumped to the
	// kernel yet: the still is the display of the stages of the start.
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Monitor, text = "stop"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ + FILM_HOLD_LOOK},
	{kind = .Monitor, text = "cont"},
	// The root service draws the display again, then the compositor has
	// the screen: the desktop replaced the boot display.
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	// The window of the boot display: the same record, one sample each
	// 500 ms.
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Film_Hold, milliseconds = 2 * FILM_HOLD_READ},
	{kind = .Film_Stop},
	{kind = .Quit},
}
