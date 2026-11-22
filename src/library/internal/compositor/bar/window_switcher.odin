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

// The card of the switcher: one line for each window, under a padding.
SWITCHER_LINE_HEIGHT :: 28
SWITCHER_WIDTH :: 360
SWITCHER_PADDING :: 8
// The lines that the card shows at most: the window chosen stays among
// them.
SWITCHER_LINES_SHOWN :: 12

Window_Switcher :: struct {
	open:     bool,
	chosen:   int, // A place in the order from the front: 0 is the window in front.
	tab_held: bool, // A Tab that the switcher took is down: its release goes to no window.
}

Switcher_Outcome :: struct {
	taken:   bool, // The key goes to no window.
	changed: bool, // The card opened, closed or chose another window: draw it again.
	finish:  bool, // Bring the window at chosen to the front.
	chosen:  int,
}

// switcher_key takes one key record. window_count is the count of windows
// now: a window that closed while the card is open moves the chosen place
// back inside the list.
switcher_key :: proc "contextless" (switcher: ^Window_Switcher, code: u32, pressed: bool, modifiers: u32, window_count: int) -> (outcome: Switcher_Outcome) {
	alt := modifiers & display.MODIFIER_ALT != 0
	control := modifiers & display.MODIFIER_CONTROL != 0
	backward := modifiers & display.MODIFIER_SHIFT != 0
	is_tab := code == display.KEY_TAB
	if !switcher.open {
		if is_tab && !pressed && switcher.tab_held {
			// The Tab of a switch that Alt ended before it.
			switcher.tab_held = false
			return {taken = true}
		}
		if !(is_tab && pressed && alt && !control) || window_count <= 0 {
			return {}
		}
		switcher.open = true
		switcher.tab_held = true
		switch {
		case backward:
			switcher.chosen = window_count - 1
		case window_count > 1:
			switcher.chosen = 1
		case:
			switcher.chosen = 0
		}
		return {taken = true, changed = true, chosen = switcher.chosen}
	}
	switcher.chosen = clamp(switcher.chosen, 0, max(window_count - 1, 0))
	switch {
	case window_count <= 0:
		// Each window closed: nothing to choose.
		switcher.open = false
		return {taken = true, changed = true}
	case code == SWITCHER_ALT_KEY && !pressed, !alt && pressed:
		// The release of Alt, or a press with no Alt: a release that the
		// switcher missed. The chosen window comes to the front.
		switcher.open = false
		return {taken = true, changed = true, finish = true, chosen = switcher.chosen}
	case is_tab && pressed:
		switcher.tab_held = true
		step := backward ? window_count - 1 : 1
		switcher.chosen = (switcher.chosen + step) % window_count
		return {taken = true, changed = true, chosen = switcher.chosen}
	case is_tab:
		switcher.tab_held = false
		return {taken = true, chosen = switcher.chosen}
	case code == display.KEY_ESCAPE && pressed:
		switcher.open = false
		return {taken = true, changed = true}
	}
	// Each other key while the card is open goes to no window.
	return {taken = true, chosen = switcher.chosen}
}

// switcher_cancel closes the card with no change: a press of the pointer.
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
