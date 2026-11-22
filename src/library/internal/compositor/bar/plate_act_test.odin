#+build !freestanding
package bar

import "core:testing"

@(test)
a_press_minimizes_the_group_in_front_raises_one_behind_and_restores_one_minimized :: proc(t: ^testing.T) {
	testing.expect_value(t, plate_act(true, true), Plate_Act.Minimize)
	testing.expect_value(t, plate_act(false, true), Plate_Act.Raise)
	testing.expect_value(t, plate_act(false, false), Plate_Act.Restore)
}
