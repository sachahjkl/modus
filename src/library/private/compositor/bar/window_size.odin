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
// press on it moves the window; the band above it is the top edge, and its
// left and right columns are the left and right edges. A place far from
// the frame, or inside it, gives no edge.
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

// One window for the hit test of the edges, as the compositor sees it.
Window_Hit :: struct {
	outer:     Outer_Rectangle, // Its frame on the screen.
	resizable: bool, // The process declared it resizable, and no resize of it waits for its process.
}

// resize_target gives the window whose edges a press at a place takes,
// from a list of windows in their order from the front, and the edges.
// A place inside the frame of a window belongs to the first such window:
// its border when it is resizable, else no edge. The band outside a frame
// takes a place only where no window lies: a band never takes a press from
// a window behind it. place is -1 and edges empty when no edge is there.
resize_target :: proc "contextless" (windows: []Window_Hit, border, pointer_x, pointer_y: int) -> (place: int, edges: Resize_Edges) {
	for window, index in windows {
		outer := window.outer
		if pointer_x < outer.x || pointer_y < outer.y || pointer_x >= outer.x + outer.width || pointer_y >= outer.y + outer.height {
			continue
		}
		if window.resizable {
			if found := resize_edges_at(outer, border, pointer_x, pointer_y); found != {} {
				return index, found
			}
		}
		return -1, {}
	}
	for window, index in windows {
		if window.resizable {
			if found := resize_edges_at(window.outer, border, pointer_x, pointer_y); found != {} {
				return index, found
			}
		}
	}
	return -1, {}
}

// The bytes of a surface for each pixel: two pictures of 4 bytes. The
// compositor asserts that this is the rule of the display package.
SURFACE_BYTES_FOR_EACH_PIXEL :: 8

// What the compositor knows when a window gives a surface of a new size
// (the record Surface_Resize): the facts of the handle, the words of the
// record, and the state of the window.
Surface_Resize_Facts :: struct {
	is_memory:    bool, // The handle names a memory object.
	readable:     bool, // The handle has the right Read.
	memory_bytes: u64, // The size of the memory object. 0 when the kernel refused to give it.
	width, height: u64, // The words of the record.
	resizable:    bool, // The window is resizable.
	limits:       Size_Range, // Its limits.
	asked:        bool, // The compositor sent Resized, and no answer came since.
	asked_width, asked_height: int, // The size that it asked.
}

// The rule that a Surface_Resize breaks. None: the compositor takes it.
Surface_Resize_Refusal :: enum {
	None,
	Not_Memory, // The handle names no memory object.
	No_Read, // The handle has no right Read.
	Not_Resizable, // The window is fixed.
	Not_Asked, // No Resized waits for an answer: the principal did not ask for a size, or the answer came.
	Other_Size, // The size is not the asked one.
	Outside_Limits, // The size is outside the limits of the window: a Resizable narrowed them after the request.
	Too_Small, // The memory does not hold two pictures of the size.
}

// surface_resize_refusal decides a Surface_Resize from its facts. It reads
// the words as words, so a word past the limits never reads as a negative
// size. It reads and changes no state, so a host test gives it each
// refused case.
surface_resize_refusal :: proc "contextless" (facts: Surface_Resize_Facts) -> Surface_Resize_Refusal {
	switch {
	case !facts.is_memory:
		return .Not_Memory
	case !facts.readable:
		return .No_Read
	case !facts.resizable:
		return .Not_Resizable
	case !facts.asked:
		return .Not_Asked
	case facts.asked_width < 0 || facts.asked_height < 0 || facts.width != u64(facts.asked_width) || facts.height != u64(facts.asked_height):
		return .Other_Size
	case facts.limits.least_width < 0 || facts.limits.least_height < 0 || facts.width < u64(facts.limits.least_width) || facts.height < u64(facts.limits.least_height) || facts.width > u64(max(facts.limits.largest_width, 0)) || facts.height > u64(max(facts.limits.largest_height, 0)):
		return .Outside_Limits
	}
	// The size is now inside the limits, which a surface bounds: the
	// product cannot overflow.
	if facts.memory_bytes < facts.width * facts.height * SURFACE_BYTES_FOR_EACH_PIXEL {
		return .Too_Small
	}
	return .None
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
