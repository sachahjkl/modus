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
