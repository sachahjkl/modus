package terminal_records

// The wait of one turn of the loop of the process `terminal`, in the thread
// that draws its window (src/md/features/terminal_due_picture.md).
Picture_Wait :: enum u8 {
	Nothing_To_Draw, // Wait for a record, a key, or the next look at the process. No picture is due.
	Compositor, // Wait until the compositor took the last picture: the canvas is not free.
	Draw_Now, // Draw immediately on the display cadence without an artificial frame timer.
}

// picture_wait_choose gives the wait of one turn of the terminal, and
// whether a picture is due: a change waits for the next picture. The
// terminal sends the due state to the compositor before it waits, so that
// a wait with a change never looks like a wait with nothing to draw
// (docs/TOOLS.md, "When the tool takes a picture").
//
// - measure: the window shows live rate samples and wakes on the sample interval when idle.
// - changed_with_no_record: a key, a press, a new font changed the view.
// - activity_seen: the count of the groups of records that the reader took,
//   read once in this turn. A wait with nothing to draw waits on this value.
// - activity_drawn: that count at the last picture.
// - compositor_holds_canvas: the compositor did not take the last picture.
//
// A record that came while the terminal drew is a change: activity_seen is
// then not activity_drawn, and the picture is due.
picture_wait_choose :: proc "contextless" (measure, changed_with_no_record: bool, activity_seen, activity_drawn: u32, compositor_holds_canvas: bool) -> (wait: Picture_Wait, due: bool) {
	due = changed_with_no_record || activity_seen != activity_drawn
	switch {
	case !due && !measure:
		return .Nothing_To_Draw, false
	case compositor_holds_canvas:
		return .Compositor, due
	case !due && measure:
		return .Nothing_To_Draw, false
	}
	return .Draw_Now, due
}
