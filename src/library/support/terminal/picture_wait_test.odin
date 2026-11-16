#+build !freestanding
package terminal_records

import "core:testing"

// The decision gives a due picture for each change that waits, and the
// wait that fits it. The case that made the rule: a record came while the
// terminal drew its last picture, and the terminal then waits for its next
// frame. That picture is due: else each program waits, no window says that
// a picture is due, and the machine test takes the picture before the
// record. The loop of the program `terminal`, which sends the decision
// before each wait, is outside this test.
@(test)
the_decision_gives_a_due_picture_for_each_change_that_waits :: proc(t: ^testing.T) {
	Case :: struct {
		measure, changed_with_no_record: bool,
		activity_seen, activity_drawn:   u32,
		compositor_holds_canvas:         bool,
		wait:                            Picture_Wait,
		due:                             bool,
	}
	drawn: u32 = 7
	cases := [?]Case {
		{false, false, drawn, drawn, false, .Nothing_To_Draw, false}, // No change: the terminal waits with nothing to draw.
		{false, false, drawn + 1, drawn, false, .Next_Frame, true}, // A record during the last picture: due before the wait for the next frame.
		{false, true, drawn, drawn, false, .Next_Frame, true}, // A key changed the view.
		{false, false, drawn + 1, drawn, true, .Compositor, true}, // A change, and the compositor still reads the canvas.
		{false, false, drawn, drawn, true, .Nothing_To_Draw, false}, // No change: the canvas does not matter.
		{false, false, 0, max(u32), false, .Next_Frame, true}, // The count passes its largest value: still a change.
		{true, false, drawn, drawn, false, .Next_Frame, false}, // The rates draw at each frame, with no change of the text.
		{true, false, drawn, drawn, true, .Compositor, false},
		{true, false, drawn + 1, drawn, false, .Next_Frame, true},
	}
	for item, index in cases {
		wait, due := picture_wait_choose(item.measure, item.changed_with_no_record, item.activity_seen, item.activity_drawn, item.compositor_holds_canvas)
		testing.expectf(t, wait == item.wait && due == item.due, "case %d: %v with due %v, not %v with due %v", index, wait, due, item.wait, item.due)
	}
}
