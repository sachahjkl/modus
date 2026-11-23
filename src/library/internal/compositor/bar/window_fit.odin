package bar

// The fit of a window into the work area (src/md/features/window_scroll.md,
// "The compositor clamps"; window_resize.md, "The fit at a new scale"). A
// surface larger than the work area would hold more pixels than the screen,
// which the budget of the window does not pay, and a part of it would be
// out of reach: each window gets at most the work area, and a window whose
// layout is larger scrolls it.

// A window by the corner of its frame and the size that it wants for its
// surface (the size that it opened with, or that the principal asked last),
// in logical pixels, with the columns and the lines of its frame around the
// surface: 0 for a window that draws its own frame.
Fit_Window :: struct {
	x, y:                        int,
	width, height:               int,
	chrome_width, chrome_height: int,
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

// window_fit gives the place and the size of a window in the work area: the
// wanted size, cut to the room under the frame on each axis, and never
// below 1. It has no floor at the least size and none for a fixed window:
// the window scrolls its layout in the smaller surface. The place is moved
// so that the whole window is in the work area; on a work area smaller than
// the frame, the corner stays at its top left, so the title and the close
// button stay on the screen.
window_fit :: proc "contextless" (window: Fit_Window, work: Work_Box) -> (x, y, width, height: int) {
	width = clamp(window.width, 1, max(work.width - window.chrome_width, 1))
	height = clamp(window.height, 1, max(work.height - window.chrome_height, 1))
	outer_width := width + window.chrome_width
	outer_height := height + window.chrome_height
	// The right and the bottom edge first: the left and the top win when the
	// window is still larger than the work area.
	x = max(min(window.x, work.left + work.width - outer_width), work.left)
	y = max(min(window.y, work.top + work.height - outer_height), work.top)
	return
}
