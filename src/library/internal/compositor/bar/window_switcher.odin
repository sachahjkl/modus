package bar

import "modus:display"

// The window switcher (src/md/features/window_switcher.md): Alt+Tab opens
// a card that lists the windows from the one in front, the most recently
// used first, and chooses the next one; each Tab while Alt is down chooses
// the next, Shift+Tab the one before; the release of Alt brings the chosen
// window to the front, and Escape closes the card with no change. The
// rules are pure here; the compositor keeps the state and does the effects.

// The scan code of the left Alt key: its release ends the switch. The right
// Alt key is AltGr, with the extended bit.
SWITCHER_ALT_KEY :: 0x38

// The windows that the card lists at most: the clients of the compositor.
SWITCHER_WINDOW_CAPACITY :: 64

// The card of the switcher: one line for each window, under a padding.
SWITCHER_LINE_HEIGHT :: 28
SWITCHER_WIDTH :: 360
SWITCHER_PADDING :: 8
// The lines that the card shows at most: the window chosen stays among
// them.
SWITCHER_LINES_SHOWN :: 12

// The switcher keeps the windows of the card as they were at its open: a
// client index for each line, from the front. A window that opens or
// closes while the card is open closes the card (switcher_windows_changed),
// so a line never names another window than the one that it shows.
Window_Switcher :: struct {
	open:         bool,
	chosen:       int, // A line of the card: 0 is the window that was in front.
	tab_held:     bool, // A Tab that the switcher took is down: its release goes to no window.
	windows:      [SWITCHER_WINDOW_CAPACITY]int,
	window_count: int,
}

Switcher_Outcome :: struct {
	taken:   bool, // The key goes to no window.
	changed: bool, // The card opened, closed or chose another window: draw it again.
	finish:  bool, // Bring the window of the client index window to the front.
	window:  int,
}

// switcher_key takes one key record. front_to_back holds the client index
// of each window from the one in front; the switcher copies it at the open
// only.
switcher_key :: proc "contextless" (switcher: ^Window_Switcher, code: u32, pressed: bool, modifiers: u32, front_to_back: []int) -> (outcome: Switcher_Outcome) {
	alt := modifiers & display.MODIFIER_ALT != 0
	control := modifiers & display.MODIFIER_CONTROL != 0
	backward := modifiers & display.MODIFIER_SHIFT != 0
	is_tab := code == display.KEY_TAB
	if !switcher.open {
		if is_tab && !pressed && switcher.tab_held {
			// The Tab of a switch that Alt ended before it.
			switcher.tab_held = false
			return {taken = true, window = -1}
		}
		count := min(len(front_to_back), SWITCHER_WINDOW_CAPACITY)
		if !(is_tab && pressed && alt && !control) || count <= 0 {
			return {window = -1}
		}
		copy(switcher.windows[:], front_to_back[:count])
		switcher.window_count = count
		switcher.open = true
		switcher.tab_held = true
		switch {
		case backward:
			switcher.chosen = count - 1
		case count > 1:
			switcher.chosen = 1
		case:
			switcher.chosen = 0
		}
		return {taken = true, changed = true, window = -1}
	}
	count := switcher.window_count
	if count <= 0 || count > SWITCHER_WINDOW_CAPACITY || switcher.chosen < 0 || switcher.chosen >= count {
		// A state that no key makes: the card closes with no change.
		switcher.open = false
		return {taken = true, changed = true, window = -1}
	}
	switch {
	case code == SWITCHER_ALT_KEY && !pressed, !alt && pressed:
		// The release of Alt, or a press with no Alt: a release that the
		// switcher missed. The chosen window comes to the front.
		switcher.open = false
		return {taken = true, changed = true, finish = true, window = switcher.windows[switcher.chosen]}
	case is_tab && pressed:
		switcher.tab_held = true
		step := backward ? count - 1 : 1
		switcher.chosen = (switcher.chosen + step) % count
		return {taken = true, changed = true, window = -1}
	case is_tab:
		switcher.tab_held = false
		return {taken = true, window = -1}
	case code == display.KEY_ESCAPE && pressed:
		switcher.open = false
		return {taken = true, changed = true, window = -1}
	}
	// Each other key while the card is open goes to no window.
	return {taken = true, window = -1}
}

// switcher_cancel closes the card with no change: a press of the pointer, a
// dialog that takes the keys, or a window that opens or closes.
switcher_cancel :: proc "contextless" (switcher: ^Window_Switcher) -> (changed: bool) {
	changed = switcher.open
	switcher.open = false
	return
}

// switcher_card gives the place of the card of count windows, in the
// middle of a screen.
switcher_card :: proc "contextless" (count, screen_width, screen_height: int) -> (x, y, width, height: int) {
	lines := clamp(count, 1, SWITCHER_LINES_SHOWN)
	width = min(SWITCHER_WIDTH, max(screen_width, 0))
	height = min(lines * SWITCHER_LINE_HEIGHT + 2 * SWITCHER_PADDING + 2 * BORDER, max(screen_height, 0))
	return max((screen_width - width) / 2, 0), max((screen_height - height) / 2, 0), width, height
}

// switcher_first_line gives the first window that the card shows, so that
// the chosen one is among the lines.
switcher_first_line :: proc "contextless" (chosen, count: int) -> int {
	if count <= SWITCHER_LINES_SHOWN || chosen < SWITCHER_LINES_SHOWN {
		return 0
	}
	return min(chosen - SWITCHER_LINES_SHOWN + 1, count - SWITCHER_LINES_SHOWN)
}
