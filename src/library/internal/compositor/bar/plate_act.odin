package bar

// The act of a press on a plate of the bar: on the group of windows of one
// name, as a principal knows it from other systems. The window of the
// group in front minimizes; a group with a window shown and not in front
// brings its last used window to the front; a group of minimized windows
// restores its last used window. The menu of the window acts are on the
// right button.
Plate_Act :: enum u8 {
	Raise    = 0, // Bring the last used window of the group to the front.
	Minimize = 1, // Minimize the window of the group that is in front.
	Restore  = 2, // Restore the last used minimized window of the group, and bring it to the front.
}

// plate_act gives the act of a press on the plate of a group. in_front:
// the window in front is of the group and is shown. any_shown: a window of
// the group is not minimized.
plate_act :: proc "contextless" (in_front, any_shown: bool) -> Plate_Act {
	switch {
	case in_front:
		return .Minimize
	case any_shown:
		return .Raise
	}
	return .Restore
}

// One window of the order of the compositor, from the back to the front:
// the name of its plate and whether it is minimized.
Plate_Window :: struct {
	name:      string,
	minimized: bool,
}

// plate_press gives the act of a press on the plate of a name and the
// place in windows of the window that it acts on: the window of the name
// used last among the shown ones, or among the minimized ones for a
// restore. ok is false when no window has the name.
plate_press :: proc "contextless" (windows: []Plate_Window, name: string) -> (act: Plate_Act, position: int, ok: bool) {
	shown, minimized := -1, -1
	for place := len(windows) - 1; place >= 0; place -= 1 {
		if windows[place].name != name {
			continue
		}
		if windows[place].minimized {
			if minimized < 0 {
				minimized = place
			}
		} else if shown < 0 {
			shown = place
		}
	}
	if shown < 0 && minimized < 0 {
		return .Raise, -1, false
	}
	act = plate_act(shown >= 0 && shown == len(windows) - 1, shown >= 0)
	switch act {
	case .Minimize, .Raise:
		return act, shown, true
	case .Restore:
		return act, minimized, true
	}
	return act, -1, false
}
