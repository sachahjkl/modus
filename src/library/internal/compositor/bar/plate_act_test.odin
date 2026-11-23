#+build !freestanding
package bar

import "core:testing"

@(test)
a_press_minimizes_the_group_in_front_raises_one_behind_and_restores_one_minimized :: proc(t: ^testing.T) {
	testing.expect_value(t, plate_act(true, true), Plate_Act.Minimize)
	testing.expect_value(t, plate_act(false, true), Plate_Act.Raise)
	testing.expect_value(t, plate_act(false, false), Plate_Act.Restore)
}

@(test)
a_press_acts_on_the_window_of_the_group_used_last :: proc(t: ^testing.T) {
	// From the back: console, notes, console, edit (in front).
	windows := [?]Plate_Window{{"console", false}, {"notes", false}, {"console", false}, {"edit", false}}
	act, position, ok := plate_press(windows[:], "edit")
	testing.expect(t, ok)
	testing.expect_value(t, act, Plate_Act.Minimize)
	testing.expect_value(t, position, 3)
	// Two consoles behind: the one used last, nearer the front.
	act, position, ok = plate_press(windows[:], "console")
	testing.expect_value(t, act, Plate_Act.Raise)
	testing.expect_value(t, position, 2)
	act, position, _ = plate_press(windows[:], "notes")
	testing.expect_value(t, act, Plate_Act.Raise)
	testing.expect_value(t, position, 1)
}

@(test)
a_group_with_a_shown_window_raises_it_before_a_minimized_one :: proc(t: ^testing.T) {
	// A minimized console nearer the front, a shown one behind it.
	windows := [?]Plate_Window{{"console", false}, {"edit", false}, {"console", true}}
	act, position, ok := plate_press(windows[:], "console")
	testing.expect(t, ok)
	testing.expect_value(t, act, Plate_Act.Raise)
	testing.expect_value(t, position, 0)
}

@(test)
a_group_of_minimized_windows_restores_the_one_used_last :: proc(t: ^testing.T) {
	windows := [?]Plate_Window{{"notes", true}, {"edit", false}, {"notes", true}}
	act, position, ok := plate_press(windows[:], "notes")
	testing.expect(t, ok)
	testing.expect_value(t, act, Plate_Act.Restore)
	testing.expect_value(t, position, 2)
	// Every window minimized: the one in front of the order is minimized,
	// and is not "in front": the press restores it.
	all := [?]Plate_Window{{"edit", true}}
	act, position, ok = plate_press(all[:], "edit")
	testing.expect_value(t, act, Plate_Act.Restore)
	testing.expect_value(t, position, 0)
}

@(test)
a_name_with_no_window_and_an_empty_order_act_on_nothing :: proc(t: ^testing.T) {
	windows := [?]Plate_Window{{"console", false}}
	_, position, ok := plate_press(windows[:], "notes")
	testing.expect(t, !ok)
	testing.expect_value(t, position, -1)
	_, position, ok = plate_press(nil, "console")
	testing.expect(t, !ok)
	_, _, ok = plate_press(windows[:], "")
	testing.expect(t, !ok)
}
