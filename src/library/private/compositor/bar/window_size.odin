package bar

// The edges of a window and the size that a drag of them gives
// (src/md/features/window_resize.md). The compositor resizes the windows;
// these procedures hold no state, so a host test checks each edge.

// The pixels outside the frame of a window that are still its edge: the
// border is 2 pixels, too thin to take with the pointer.
RESIZE_REACH :: 6

// One edge of the frame of a window.
Resize_Edge :: enum {
	Left,
	Right,
	Top,
	Bottom,
}

// The edges that a drag holds: one edge, or two at a corner. Empty: no edge.
Resize_Edges :: bit_set[Resize_Edge]

// The frame of a window on the screen: its title bar and its borders
// around the surface. x and y are its top left corner.
Outer_Rectangle :: struct {
	x, y, width, height: int,
}

// The sizes between which a drag keeps the surface of a window.
Size_Range :: struct {
	least_width, least_height:     int,
	largest_width, largest_height: int,
}

// The window at the press that started a drag of its edges.
Resize_Start :: struct {
	edges:                Resize_Edges,
	pointer_x, pointer_y: int, // The place of the press.
	x, y:                 int, // The top left corner of the frame.
	width, height:        int, // The surface.
}

// resize_edges_at gives the edges of a frame at a place of the pointer:
// the border at the left, the right and the bottom, and the band of
// RESIZE_REACH pixels around the frame. The title bar is not an edge: a
// press on it moves the window; the band above it is the top edge. A
// place far from the frame, or inside it, gives no edge.
resize_edges_at :: proc "contextless" (outer: Outer_Rectangle, border, pointer_x, pointer_y: int) -> (edges: Resize_Edges) {
	left, top := outer.x, outer.y
	right, bottom := outer.x + outer.width, outer.y + outer.height
	if pointer_x < left - RESIZE_REACH || pointer_x >= right + RESIZE_REACH || pointer_y < top - RESIZE_REACH || pointer_y >= bottom + RESIZE_REACH {
		return {}
	}
	if pointer_x < left + border {
		edges += {.Left}
	} else if pointer_x >= right - border {
		edges += {.Right}
	}
	if pointer_y < top {
		edges += {.Top}
	} else if pointer_y >= bottom - border {
		edges += {.Bottom}
	}
	return edges
}

// resize_drag gives the place of the frame and the size of the surface
// while the pointer drags the edges of start. Each edge moves with the
// pointer by steps of GRID; the size stays inside sizes; an edge never
// goes past the screen: not left of 0, not right of screen_width, not over
// the bar, not below screen_height. A window that is already partly off
// the screen is not made larger in that direction, and the screen alone
// never makes it smaller. The edges opposite to the dragged ones stay in
// place. frame_width and frame_height are the frame around the surface:
// the two borders, and the title bar with the bottom border.
//
// sizes must hold the size of start (the compositor checks both); when
// they do not, the size is cut to them.
resize_drag :: proc "contextless" (start: Resize_Start, pointer_x, pointer_y: int, sizes: Size_Range, frame_width, frame_height, screen_width, screen_height: int) -> (x, y, width, height: int) {
	x, y, width, height = start.x, start.y, start.width, start.height
	step_x := grid_floor(pointer_x - start.pointer_x + GRID / 2)
	step_y := grid_floor(pointer_y - start.pointer_y + GRID / 2)
	right := start.x + frame_width + start.width
	bottom := start.y + frame_height + start.height
	if .Right in start.edges {
		room := max(screen_width - start.x - frame_width, start.width)
		width = clamp(start.width + step_x, sizes.least_width, min(sizes.largest_width, room))
	} else if .Left in start.edges {
		room := max(right - frame_width, start.width)
		width = clamp(start.width - step_x, sizes.least_width, min(sizes.largest_width, room))
		x = right - frame_width - width
	}
	if .Bottom in start.edges {
		room := max(screen_height - start.y - frame_height, start.height)
		height = clamp(start.height + step_y, sizes.least_height, min(sizes.largest_height, room))
	} else if .Top in start.edges {
		room := max(bottom - frame_height - HEIGHT, start.height)
		height = clamp(start.height - step_y, sizes.least_height, min(sizes.largest_height, room))
		y = bottom - frame_height - height
	}
	return
}
