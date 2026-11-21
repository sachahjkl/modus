#+build !freestanding
package ps2_controller

import "core:testing"

// The status of a port with no device stops the drain at once, whatever
// the count, and before the bit of a waiting byte is read: that bit is set
// in it.
@(test)
a_status_of_all_ones_is_no_controller :: proc(t: ^testing.T) {
	counts := [?]u64{0, 1, CONTROLLER_POLLS - 1, CONTROLLER_POLLS, max(u64)}
	for count in counts {
		testing.expect_value(t, drain_step(STATUS_NO_CONTROLLER, count), Drain_Step.No_Controller)
	}
	testing.expect(t, STATUS_NO_CONTROLLER & STATUS_OUTPUT_FULL != 0, "the status of no controller has the bit of a waiting byte: the test of all ones must come first")
}

// A controller that gives bytes with no end is absent too: the bound, one
// past it and the largest count stop the drain, with a byte waiting or not.
@(test)
the_bound_of_the_bytes_ends_the_drain :: proc(t: ^testing.T) {
	statuses := [?]u8{STATUS_OUTPUT_FULL, STATUS_OUTPUT_FULL | STATUS_MOUSE, 0, STATUS_NO_CONTROLLER - 1}
	counts := [?]u64{CONTROLLER_POLLS, CONTROLLER_POLLS + 1, max(u64)}
	for status in statuses {
		for count in counts {
			testing.expect_value(t, drain_step(status, count), Drain_Step.No_Controller)
		}
	}
}

// A status of all ones less one bit is a controller: the drain goes on to
// the bit of a waiting byte.
@(test)
one_bit_less_than_all_ones_is_a_controller :: proc(t: ^testing.T) {
	testing.expect_value(t, drain_step(STATUS_NO_CONTROLLER - STATUS_OUTPUT_FULL, 0), Drain_Step.Done)
	testing.expect_value(t, drain_step(STATUS_NO_CONTROLLER &~ STATUS_MOUSE, 0), Drain_Step.Read_Byte)
}

// The successful cases come last: an empty controller ends the drain, and a
// waiting byte of the keyboard or of the mouse is read, up to the last
// count under the bound.
@(test)
a_controller_is_drained :: proc(t: ^testing.T) {
	testing.expect_value(t, drain_step(0, 0), Drain_Step.Done)
	testing.expect_value(t, drain_step(STATUS_INPUT_FULL, 0), Drain_Step.Done)
	testing.expect_value(t, drain_step(STATUS_MOUSE, CONTROLLER_POLLS - 1), Drain_Step.Done)
	testing.expect_value(t, drain_step(STATUS_OUTPUT_FULL, 0), Drain_Step.Read_Byte)
	testing.expect_value(t, drain_step(STATUS_OUTPUT_FULL, 1), Drain_Step.Read_Byte)
	testing.expect_value(t, drain_step(STATUS_OUTPUT_FULL | STATUS_MOUSE, CONTROLLER_POLLS - 1), Drain_Step.Read_Byte)
}
