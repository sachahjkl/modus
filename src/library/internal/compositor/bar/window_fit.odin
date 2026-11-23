package bar

// The fit of a window into the work area before the compositor names a new
// scale to it (src/md/features/window_resize.md, "The fit before a new
// scale"). A window keeps its logical size across a rescale, so a window
// larger than the work area of a larger scale would hold more pixels than
// the screen, which its budget does not pay.

// A window by the corner of its frame and the size of its surface, in
// logical pixels, with the columns and the lines of its frame around the
// surface: 0 for a window that draws its own frame.
Fit_Window :: struct {
	x, y:                        int,
	width, height:               int,
	chrome_width, chrome_height: int,
	limits:                      Size_Range,
	resizable:                   bool,
}

// The work area of the new scale, in logical pixels.
Work_Box :: struct {
	left, top, width, height: int,
}

// window_fit gives the place and the size of a window in the work area: a
// resizable window larger than the work area gets the size that fits, and
// never less than its least size; a smaller window, or one that is not
// resizable, keeps its size. The place is moved so that the whole window is
// in the work area; a window still larger keeps its corner at the top left
// of the work area, so its title and its close button stay on the screen.
window_fit :: proc "contextless" (window: Fit_Window, work: Work_Box) -> (x, y, width, height: int) {
	width, height = window.width, window.height
	if window.resizable {
		room_width := work.width - window.chrome_width
		room_height := work.height - window.chrome_height
		if width > room_width {
			width = max(room_width, window.limits.least_width)
		}
		if height > room_height {
			height = max(room_height, window.limits.least_height)
		}
	}
	outer_width := width + window.chrome_width
	outer_height := height + window.chrome_height
	// The right and the bottom edge first: the left and the top win when the
	// window is still larger than the work area.
	x = max(min(window.x, work.left + work.width - outer_width), work.left)
	y = max(min(window.y, work.top + work.height - outer_height), work.top)
	return
}
