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
	outcome := switcher_key(&switcher, display.KEY_TAB, true, ALT, 3)
	testing.expect(t, outcome.taken && outcome.changed && switcher.open)
	testing.expect_value(t, outcome.chosen, 1)
	outcome = switcher_key(&switcher, display.KEY_TAB, false, ALT, 3)
	testing.expect(t, outcome.taken && !outcome.changed)
	outcome = switcher_key(&switcher, display.KEY_TAB, true, ALT, 3)
	testing.expect_value(t, outcome.chosen, 2)
	// Past the last window, the first again.
	outcome = switcher_key(&switcher, display.KEY_TAB, true, ALT, 3)
	testing.expect_value(t, outcome.chosen, 0)
	outcome = switcher_key(&switcher, display.KEY_TAB, true, ALT | SHIFT, 3)
	testing.expect_value(t, outcome.chosen, 2)
	switcher_key(&switcher, display.KEY_TAB, false, ALT, 3)
	outcome = switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, 3)
	testing.expect(t, outcome.taken && outcome.finish && !switcher.open)
	testing.expect_value(t, outcome.chosen, 2)
}

@(test)
alt_shift_tab_starts_at_the_last_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	outcome := switcher_key(&switcher, display.KEY_TAB, true, ALT | SHIFT, 4)
	testing.expect_value(t, outcome.chosen, 3)
}

@(test)
a_tab_with_no_alt_with_control_or_with_no_window_goes_to_the_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	cases := [?]struct {
		code:      u32,
		pressed:   bool,
		modifiers: u32,
		windows:   int,
	} {
		{display.KEY_TAB, true, 0, 3},
		{display.KEY_TAB, true, SHIFT, 3},
		{display.KEY_TAB, true, ALT | CONTROL, 3},
		{display.KEY_TAB, false, ALT, 3},
		{display.KEY_TAB, true, ALT, 0},
		{display.KEY_TAB, true, ALT, -1},
		{SWITCHER_ALT_KEY, true, ALT, 3},
		{SWITCHER_ALT_KEY, false, 0, 3},
		{display.KEY_ESCAPE, true, ALT, 3},
		{'a', true, ALT, 3},
	}
	for item in cases {
		outcome := switcher_key(&switcher, item.code, item.pressed, item.modifiers, item.windows)
		testing.expectf(t, outcome == Switcher_Outcome{}, "%v is not a key of the switcher", item)
		testing.expect(t, !switcher.open)
	}
}

@(test)
one_window_is_chosen_alone :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	outcome := switcher_key(&switcher, display.KEY_TAB, true, ALT, 1)
	testing.expect_value(t, outcome.chosen, 0)
	outcome = switcher_key(&switcher, display.KEY_TAB, true, ALT, 1)
	testing.expect_value(t, outcome.chosen, 0)
	outcome = switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, 1)
	testing.expect(t, outcome.finish)
	testing.expect_value(t, outcome.chosen, 0)
}

@(test)
escape_closes_with_no_change_and_other_keys_go_to_no_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	switcher_key(&switcher, display.KEY_TAB, true, ALT, 3)
	outcome := switcher_key(&switcher, 'q', true, ALT, 3)
	testing.expect(t, outcome.taken && !outcome.finish && switcher.open)
	outcome = switcher_key(&switcher, display.KEY_ESCAPE, true, ALT, 3)
	testing.expect(t, outcome.taken && outcome.changed && !outcome.finish && !switcher.open)
	// The release of Alt after Escape is the window's again.
	outcome = switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, 3)
	testing.expect(t, !outcome.taken)
}

@(test)
a_press_with_no_alt_ends_a_switch_whose_alt_release_was_lost :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	switcher_key(&switcher, display.KEY_TAB, true, ALT, 3)
	outcome := switcher_key(&switcher, 'x', true, 0, 3)
	testing.expect(t, outcome.taken && outcome.finish && !switcher.open)
	testing.expect_value(t, outcome.chosen, 1)
}

@(test)
the_tab_released_after_alt_goes_to_no_window :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	switcher_key(&switcher, display.KEY_TAB, true, ALT, 2)
	outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, 2)
	testing.expect(t, outcome.finish)
	outcome = switcher_key(&switcher, display.KEY_TAB, false, 0, 2)
	testing.expect(t, outcome.taken)
	// Only that one release.
	outcome = switcher_key(&switcher, display.KEY_TAB, false, 0, 2)
	testing.expect(t, !outcome.taken)
}

@(test)
a_window_that_closes_while_the_card_is_open_keeps_the_choice_in_the_list :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	switcher_key(&switcher, display.KEY_TAB, true, ALT | SHIFT, 5)
	testing.expect_value(t, switcher.chosen, 4)
	outcome := switcher_key(&switcher, SWITCHER_ALT_KEY, false, 0, 2)
	testing.expect(t, outcome.finish)
	testing.expect_value(t, outcome.chosen, 1)
	switcher_key(&switcher, display.KEY_TAB, true, ALT, 3)
	outcome = switcher_key(&switcher, display.KEY_TAB, true, ALT, 0)
	testing.expect(t, outcome.taken && !outcome.finish && !switcher.open)
}

@(test)
a_press_of_the_pointer_cancels_an_open_card_only :: proc(t: ^testing.T) {
	switcher: Window_Switcher
	testing.expect(t, !switcher_cancel(&switcher))
	switcher_key(&switcher, display.KEY_TAB, true, ALT, 2)
	testing.expect(t, switcher_cancel(&switcher))
	testing.expect(t, !switcher.open)
}

@(test)
the_card_stays_on_the_screen_and_shows_the_chosen_line :: proc(t: ^testing.T) {
	x, y, width, height := switcher_card(3, 1920, 1080)
	testing.expect_value(t, width, SWITCHER_WIDTH)
	testing.expect_value(t, x, (1920 - SWITCHER_WIDTH) / 2)
	testing.expect(t, y > 0 && y + height < 1080)
	// A screen smaller than the card, an empty list, a negative size.
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
