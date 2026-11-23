#+build !freestanding
package bar

import "modus:display"
import "core:testing"

@(private = "file")
ALT :: u32(display.MODIFIER_ALT)
@(private = "file")
SHIFT :: u32(display.MODIFIER_SHIFT)
@(private = "file")
CONTROL :: u32(display.MODIFIER_CONTROL)

@(test)
alt_tab_chooses_the_window_behind_the_one_in_front_and_alt_up_brings_it :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	windows := [?]int{7, 2, 5}
	outcome := switcher_key(&switcher, display.KEY_TAB, true, ALT, windows[:])
	testing.expect(t, outcome.taken && outcome.changed && switcher.open)
	testing.expect_value(t, switcher.chosen, 1)
	outcome = switcher_key(&switcher, display.KEY_TAB, false, ALT, windows[:])
	testing.expect(t, outcome.taken && !outcome.changed)
	switcher_key(&switcher, display.KEY_TAB, true, ALT, windows[:])
	testing.expect_value(t, switcher.chosen, 2)
	// Past the last window, the first again.
	switcher_key(&switcher, display.KEY_TAB, true, ALT, windows[:])
	testing.expect_value(t, switcher.chosen, 0)
	switcher_key(&switcher, display.KEY_TAB, true, ALT | SHIFT, windows[:])
	testing.expect_value(t, switcher.chosen, 2)
	switcher_key(&switcher, display.KEY_TAB, false, ALT, windows[:])
	outcome = switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, windows[:])
	testing.expect(t, outcome.taken && outcome.finish && !switcher.open)
	testing.expect_value(t, outcome.window, 5)
}

@(test)
the_card_keeps_the_windows_of_its_open_when_the_order_changes :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	at_open := [?]int{3, 9, 4}
	switcher_key(&switcher, display.KEY_TAB, true, ALT, at_open[:])
	// The order of the compositor moved after the open: the line chosen
	// still names the window that it showed.
	moved := [?]int{9, 4}
	outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, moved[:])
	testing.expect(t, outcome.finish)
	testing.expect_value(t, outcome.window, 9)
}

@(test)
a_window_that_opens_or_closes_closes_the_card_with_no_choice :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	windows := [?]int{1, 2, 3}
	testing.expect(t, !switcher_cancel(&switcher))
	switcher_key(&switcher, display.KEY_TAB, true, ALT, windows[:])
	testing.expect(t, switcher_cancel(&switcher))
	testing.expect(t, !switcher.open)
	// The release of Alt after it goes to the window, and brings nothing.
	outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, windows[:])
	testing.expect(t, !outcome.taken && !outcome.finish)
	// The Tab that the switcher took keeps its release.
	outcome = switcher_key(&switcher, display.KEY_TAB, false, 0, windows[:])
	testing.expect(t, outcome.taken && !outcome.finish)
}

@(test)
alt_shift_tab_starts_at_the_last_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	windows := [?]int{0, 1, 2, 3}
	switcher_key(&switcher, display.KEY_TAB, true, ALT | SHIFT, windows[:])
	testing.expect_value(t, switcher.chosen, 3)
}

@(test)
a_tab_with_no_alt_with_control_or_with_no_window_goes_to_the_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	three := [?]int{0, 1, 2}
	cases := [?]struct {
		code:      u32,
		pressed:   bool,
		modifiers: u32,
		windows:   []int,
	} {
		{display.KEY_TAB, true, 0, three[:]},
		{display.KEY_TAB, true, SHIFT, three[:]},
		{display.KEY_TAB, true, ALT | CONTROL, three[:]},
		{display.KEY_TAB, false, ALT, three[:]},
		{display.KEY_TAB, true, ALT, nil},
		{SWITCHER_ALT_KEY, true, ALT, three[:]},
		{SWITCHER_ALT_KEY, false, 0, three[:]},
		{display.KEY_ESCAPE, true, ALT, three[:]},
		{'a', true, ALT, three[:]},
	}
	for item in cases {
		outcome := switcher_key(&switcher, item.code, item.pressed, item.modifiers, item.windows)
		testing.expectf(t, !outcome.taken && !outcome.finish && !outcome.changed, "%v is not a key of the switcher", item)
		testing.expect(t, !switcher.open)
	}
}

@(test)
more_windows_than_the_capacity_list_the_first_ones :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	many: [SWITCHER_WINDOW_CAPACITY + 5]int
	for &window, index in many {
		window = index
	}
	switcher_key(&switcher, display.KEY_TAB, true, ALT | SHIFT, many[:])
	testing.expect_value(t, switcher.window_count, SWITCHER_WINDOW_CAPACITY)
	testing.expect_value(t, switcher.chosen, SWITCHER_WINDOW_CAPACITY - 1)
	outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, many[:])
	testing.expect_value(t, outcome.window, SWITCHER_WINDOW_CAPACITY - 1)
}

@(test)
a_damaged_state_closes_the_card_with_no_choice :: proc(t: ^testing.T) {
	windows := [?]int{1, 2}
	for bad in ([?][2]int{{0, 0}, {-1, 0}, {SWITCHER_WINDOW_CAPACITY + 1, 0}, {2, -1}, {2, 2}, {2, max(int)}}) {
		switcher := Window_Switcher{open = true, window_count = bad[0], chosen = bad[1]}
		outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, windows[:])
		testing.expectf(t, outcome.taken && !outcome.finish && !switcher.open, "the state %v closes with no choice", bad)
	}
}

@(test)
one_window_is_chosen_alone :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	one := [?]int{4}
	switcher_key(&switcher, display.KEY_TAB, true, ALT, one[:])
	testing.expect_value(t, switcher.chosen, 0)
	switcher_key(&switcher, display.KEY_TAB, true, ALT, one[:])
	testing.expect_value(t, switcher.chosen, 0)
	outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, one[:])
	testing.expect(t, outcome.finish)
	testing.expect_value(t, outcome.window, 4)
}

@(test)
escape_closes_with_no_change_and_other_keys_go_to_no_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	windows := [?]int{0, 1, 2}
	switcher_key(&switcher, display.KEY_TAB, true, ALT, windows[:])
	outcome := switcher_key(&switcher, 'q', true, ALT, windows[:])
	testing.expect(t, outcome.taken && !outcome.finish && switcher.open)
	outcome = switcher_key(&switcher, display.KEY_ESCAPE, true, ALT, windows[:])
	testing.expect(t, outcome.taken && outcome.changed && !outcome.finish && !switcher.open)
	outcome = switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, windows[:])
	testing.expect(t, !outcome.taken)
}

@(test)
a_press_with_no_alt_ends_a_switch_whose_alt_release_was_lost :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	windows := [?]int{0, 6, 2}
	switcher_key(&switcher, display.KEY_TAB, true, ALT, windows[:])
	outcome := switcher_key(&switcher, 'x', true, 0, windows[:])
	testing.expect(t, outcome.taken && outcome.finish && !switcher.open)
	testing.expect_value(t, outcome.window, 6)
}

@(test)
the_tab_released_after_alt_goes_to_no_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	windows := [?]int{0, 1}
	switcher_key(&switcher, display.KEY_TAB, true, ALT, windows[:])
	outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, windows[:])
	testing.expect(t, outcome.finish)
	outcome = switcher_key(&switcher, display.KEY_TAB, false, 0, windows[:])
	testing.expect(t, outcome.taken)
	outcome = switcher_key(&switcher, display.KEY_TAB, false, 0, windows[:])
	testing.expect(t, !outcome.taken)
}

@(test)
the_card_stays_on_the_screen_and_shows_the_chosen_line :: proc(t: ^testing.T) {
	x, y, width, height := switcher_card(3, 1920, 1080)
	testing.expect_value(t, width, SWITCHER_WIDTH)
	testing.expect_value(t, x, (1920 - SWITCHER_WIDTH) / 2)
	testing.expect(t, y > 0 && y + height < 1080)
	x, y, width, height = switcher_card(100, 200, 100)
	testing.expect(t, x == 0 && y == 0 && width == 200 && height == 100)
	_, _, _, height = switcher_card(0, 1920, 1080)
	testing.expect_value(t, height, SWITCHER_LINE_HEIGHT + 2 * SWITCHER_PADDING + 2 * BORDER)
	x, y, width, height = switcher_card(3, -5, -5)
	testing.expect(t, x == 0 && y == 0 && width == 0 && height == 0)
	testing.expect_value(t, switcher_first_line(0, 40), 0)
	testing.expect_value(t, switcher_first_line(SWITCHER_LINES_SHOWN - 1, 40), 0)
	testing.expect_value(t, switcher_first_line(SWITCHER_LINES_SHOWN, 40), 1)
	testing.expect_value(t, switcher_first_line(39, 40), 40 - SWITCHER_LINES_SHOWN)
	testing.expect_value(t, switcher_first_line(5, 3), 0)
}
