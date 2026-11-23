package bar

// The fit of a window into the work area at a new scale
// (src/md/features/window_resize.md, "The fit at a new scale"). A window keeps its logical size across a rescale, so a window
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

// The order of the fit and of the new scale for one window.
Fit_Order :: enum u8 {
	Fit_First, // The fit asks a size no larger: the window takes it at its old scale, then rescales.
	Scale_First, // The fit asks a larger size: the window rescales at its old size first, then takes it.
}

// fit_order chooses the order for a window of a size whose fit gives the
// fitted size. A surface at the old scale of a larger size can pass the
// screen in pixels when the old scale is the larger one (a maximized
// window when the scale goes down from 2): its budget does not pay it. A
// smaller size is paid at each scale, and the window rescales smaller. So
// a fit that grows on either axis comes after the rescale, and each other
// fit before it.
fit_order :: proc "contextless" (width, height, fitted_width, fitted_height: int) -> Fit_Order {
	if fitted_width > width || fitted_height > height {
		return .Scale_First
	}
	return .Fit_First
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
