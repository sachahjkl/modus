package bar

// The edges of a window and the size that a drag of them gives
// (src/md/features/window_resize.md). The compositor resizes the windows;
// these procedures hold no state, so a host test checks each edge.

// The pixels outside the frame of a window that are still its edge: the
// border is 2 pixels, too thin to take with the pointer.
RESIZE_REACH :: 6
// The pixels along each edge from a corner of the frame that take the edge
// beside it too, so a corner is a target as large as a grip. At the bottom
// right corner the square of that size inside the frame is the corner too:
// it holds the grip that the compositor draws there.
CORNER_REACH :: 14
// The side of the grip that the compositor draws in the bottom right corner
// of a resizable window, inside its border.
GRIP_SIZE :: 11

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
// left and right columns are the left and right edges. Within CORNER_REACH
// of a corner, an edge takes the edge beside it too, and the square of
// CORNER_REACH inside the bottom right corner is that corner: the grip. A place far from
// the frame, or inside it elsewhere, gives no edge.
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
	near_left, near_right := pointer_x < left + CORNER_REACH, pointer_x >= right - CORNER_REACH
	near_top, near_bottom := pointer_y < top + CORNER_REACH, pointer_y >= bottom - CORNER_REACH
	if (.Left in edges || .Right in edges) && .Top not_in edges && .Bottom not_in edges {
		if near_top {
			edges += {.Top}
		} else if near_bottom {
			edges += {.Bottom}
		}
	}
	if (.Top in edges || .Bottom in edges) && .Left not_in edges && .Right not_in edges {
		if near_left {
			edges += {.Left}
		} else if near_right {
			edges += {.Right}
		}
	}
	// The grip: the square of the bottom right corner inside the frame. No
	// other corner has one: the buttons of the title bar are at the top,
	// and the surface of the process at the bottom left keeps its pixels.
	if edges == {} && near_bottom && near_right {
		edges = {.Right, .Bottom}
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
	// The ask was a clamp to the work area (window_fit): the compositor
	// chose the size, below the least size of a resizable window, and the
	// window scrolls its layout in it (src/md/features/window_scroll.md).
	clamp:        bool,
	screen_side_limit: u64, // surface_screen_side_limit of the screen in force.
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
	Past_Screen, // A side past screen_side_limit: the limits of a window are logical, and a scale makes them larger.
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
		// A fixed window answers its clamp by a release and an offer
		// (release_answers_clamp), never by a resize.
		return .Not_Resizable
	case !facts.asked:
		return .Not_Asked
	case facts.asked_width < 0 || facts.asked_height < 0 || facts.width != u64(facts.asked_width) || facts.height != u64(facts.asked_height):
		return .Other_Size
	case facts.clamp && (facts.width > u64(max(i32)) || facts.height > u64(max(i32))):
		// The compositor asks a clamp of at most the work area: a larger
		// size is no clamp, and the product below must not overflow.
		return .Outside_Limits
	case !facts.clamp && (facts.limits.least_width < 0 || facts.limits.least_height < 0 || facts.width < u64(facts.limits.least_width) || facts.height < u64(facts.limits.least_height) || facts.width > u64(max(facts.limits.largest_width, 0)) || facts.height > u64(max(facts.limits.largest_height, 0))):
		return .Outside_Limits
	case facts.width > facts.screen_side_limit || facts.height > facts.screen_side_limit:
		return .Past_Screen
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
// pointer, to the pixel; the size stays inside sizes; an edge never
// goes past the screen: not left of 0, not right of screen_width, not over
// the bar, not below screen_height. A window that is already partly off
// the screen is not made larger in that direction, and the screen alone
// never makes it smaller. The edges opposite to the dragged ones stay in
// place. frame_width and frame_height are the frame around the surface:
// the two borders, and the title bar with the bottom border.
//
// sizes must hold the size of start (the compositor checks both); when
// they do not, the size is cut to them. Each size is also cut to the work
// area less the frame, as the clamp of the compositor (window_fit): a
// window partly off the screen would else grow past the screen, by the
// room of the edge that it holds, which counts from a place off the screen.
resize_drag :: proc "contextless" (start: Resize_Start, pointer_x, pointer_y: int, sizes: Size_Range, frame_width, frame_height, screen_width, screen_height: int) -> (x, y, width, height: int) {
	x, y, width, height = start.x, start.y, start.width, start.height
	work_width := max(screen_width - frame_width, 0)
	work_height := max(screen_height - HEIGHT - frame_height, 0)
	step_x := pointer_x - start.pointer_x
	step_y := pointer_y - start.pointer_y
	right := start.x + frame_width + start.width
	bottom := start.y + frame_height + start.height
	if .Right in start.edges {
		room := min(max(screen_width - start.x - frame_width, start.width), work_width)
		width = clamp(start.width + step_x, sizes.least_width, min(sizes.largest_width, room))
	} else if .Left in start.edges {
		room := min(max(right - frame_width, start.width), work_width)
		width = clamp(start.width - step_x, sizes.least_width, min(sizes.largest_width, room))
		x = right - frame_width - width
	}
	if .Bottom in start.edges {
		room := min(max(screen_height - start.y - frame_height, start.height), work_height)
		height = clamp(start.height + step_y, sizes.least_height, min(sizes.largest_height, room))
	} else if .Top in start.edges {
		room := min(max(bottom - frame_height - HEIGHT, start.height), work_height)
		height = clamp(start.height - step_y, sizes.least_height, min(sizes.largest_height, room))
		y = bottom - frame_height - height
	}
	return
}
