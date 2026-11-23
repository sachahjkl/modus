package bar

// The preview of a group of windows under its plate: when it shows, and
// when it closes (src/md/features/desktop_shell_look.md, "The preview
// closes as a hover card does"). The compositor gives it the plate under
// the pointer, whether the pointer is on the card, Escape, the presses and
// each change of the windows; it draws the card while shown is true.
//
// The zero value is the state with no plate under the pointer: a process
// with no call before its entry keeps it as a global. A plate is kept as
// its slot plus 1, so 0 is none.
Taskbar_Preview :: struct {
	plate:        int, // The slot of the plate under the pointer plus 1, or 0.
	shown:        bool, // The card of that plate shows.
	closed_plate: int, // The slot plus 1 of the plate whose card Escape, a press or a change closed, or 0: it stays closed while the pointer stays on it.
}

// taskbar_preview_slot gives the plate under the pointer, or -1.
taskbar_preview_slot :: proc "contextless" (preview: ^Taskbar_Preview) -> int {
	return preview.plate - 1
}

// taskbar_preview_pointer gives the place of the pointer: the plate under
// it (-1: none), and whether it is on the card, the gap above it included.
// The card stays while the pointer is on it, so the pointer can read it. It
// says whether the card or the lit plate changed, so the caller draws them
// again.
taskbar_preview_pointer :: proc "contextless" (preview: ^Taskbar_Preview, plate_slot: int, on_card: bool) -> (changed: bool) {
	if plate_slot < 0 && on_card && preview.shown {
		return false
	}
	plate := max(plate_slot, -1) + 1
	if plate != preview.closed_plate {
		preview.closed_plate = 0
	}
	shown := plate != 0 && plate != preview.closed_plate
	changed = plate != preview.plate || shown != preview.shown
	preview.plate, preview.shown = plate, shown
	return changed
}

// taskbar_preview_close closes the card that shows: Escape, a press outside
// the card, a change of the windows. The card stays closed while the
// pointer stays on its plate. It says whether a card closed.
taskbar_preview_close :: proc "contextless" (preview: ^Taskbar_Preview) -> (closed: bool) {
	if !preview.shown {
		return false
	}
	preview.shown = false
	preview.closed_plate = preview.plate
	return true
}

// taskbar_preview_press gives a press of any button: outside the card it
// closes the card; on the card it changes nothing. It says whether a card
// closed.
taskbar_preview_press :: proc "contextless" (preview: ^Taskbar_Preview, on_card: bool) -> (closed: bool) {
	if on_card {
		return false
	}
	return taskbar_preview_close(preview)
}
