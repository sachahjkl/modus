#+build !freestanding
package bar

import "core:testing"

// Each way that closes the card first: Escape, a press outside it, a change
// of the windows, the pointer that leaves the plate and the card; then a
// closed card stays closed under a still pointer, and shows again after the
// pointer left its plate.
@(test)
the_preview_closes_on_escape_a_press_a_change_and_a_leave :: proc(t: ^testing.T) {
	preview: Taskbar_Preview
	testing.expect(t, !taskbar_preview_close(&preview))
	testing.expect(t, !taskbar_preview_press(&preview, false))
	testing.expect(t, taskbar_preview_pointer(&preview, 2, false))
	testing.expect(t, preview.shown)

	// Escape and a change of the windows: taskbar_preview_close.
	testing.expect(t, taskbar_preview_close(&preview))
	testing.expect(t, !preview.shown)
	testing.expect(t, !taskbar_preview_close(&preview))
	// The pointer moves on the same plate: the card stays closed.
	testing.expect(t, !taskbar_preview_pointer(&preview, 2, false))
	testing.expect(t, !preview.shown)
	// A move onto the card does not open a closed card.
	taskbar_preview_pointer(&preview, -1, true)
	testing.expect(t, !preview.shown)
	// The pointer leaves, and comes back: the card shows again.
	taskbar_preview_pointer(&preview, -1, false)
	testing.expect(t, taskbar_preview_pointer(&preview, 2, false))
	testing.expect(t, preview.shown)

	// A press outside the card closes it; a press on the card does not.
	testing.expect(t, !taskbar_preview_press(&preview, true))
	testing.expect(t, preview.shown)
	testing.expect(t, taskbar_preview_press(&preview, false))
	testing.expect(t, !preview.shown)

	// The pointer leaves the plate and the card: no card.
	taskbar_preview_pointer(&preview, -1, false)
	taskbar_preview_pointer(&preview, 3, false)
	testing.expect(t, preview.shown)
	testing.expect(t, taskbar_preview_pointer(&preview, -1, false))
	testing.expect(t, !preview.shown)
	testing.expect_value(t, taskbar_preview_slot(&preview), -1)
}

// The card stays while the pointer goes from the plate onto the card, and
// closes when it leaves the card; a closed card of one plate does not close
// the card of another plate.
@(test)
the_preview_stays_while_the_pointer_reads_it :: proc(t: ^testing.T) {
	preview: Taskbar_Preview
	taskbar_preview_pointer(&preview, 1, false)
	testing.expect(t, !taskbar_preview_pointer(&preview, -1, true))
	testing.expect(t, preview.shown)
	testing.expect_value(t, taskbar_preview_slot(&preview), 1)
	testing.expect(t, taskbar_preview_pointer(&preview, -1, false))
	testing.expect(t, !preview.shown)

	taskbar_preview_pointer(&preview, 1, false)
	taskbar_preview_close(&preview)
	testing.expect(t, taskbar_preview_pointer(&preview, 4, false))
	testing.expect(t, preview.shown)
	testing.expect_value(t, taskbar_preview_slot(&preview), 4)
	testing.expect_value(t, preview.closed_plate, 0)
}
