package compositor

import "modus:contract/pointer_pictures"
import "modus:contract/ring"
import "modus:private/compositor/bar"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/system"

// The windows that the principal resizes (src/md/features/window_resize.md).
//
// A process declares its window resizable with Resizable. The principal
// drags an edge or a corner; the compositor draws the outline of the new
// frame, and at the release sends the event Resized and keeps the size that
// it asked. The process answers once: Surface_Resize with a surface of that
// size, made with its own budget, or Resize_Declined. The window keeps its
// old surface until the first Present after a Surface_Resize: the loop of
// the compositor never waits for the process, and the screen never shows a
// size that the process did not draw. A process cannot change the size of
// its window when the principal did not ask for it.

// The rule of the display package that the pure check of a surface reads.
#assert(bar.SURFACE_BYTES_FOR_EACH_PIXEL == display.PICTURE_COUNT * size_of(graphics.Color))

// resizable_take takes the record Resizable of a window: its size limits,
// checked at the border against the size of the surface that the process
// has: the surface of a Surface_Resize that waits for its Present, or else
// the surface on the screen. A refusal keeps the window as it was, with one
// line for the life of the window.
resizable_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	if client.surface.pixels == nil {
		// A window with no surface yet has no size that the limits can hold.
		return
	}
	width, height := client.surface.width, client.surface.height
	if client.resize_pictures != nil {
		width, height = client.resize_width, client.resize_height
	}
	limits, problem := display.size_limits_of_words({record.values[0], record.values[1], record.values[2], record.values[3]}, width, height)
	if problem != .None {
		if !client.resizable_refusal_logged {
			client.resizable_refusal_logged = true
			system.log(.Warning, "compositor: window ", system.name_of(client.title[:]), " asks to be resizable with limits that it cannot have: ", display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], "; it stays as it was. A window writes this line one time")
		}
		return
	}
	client.resizable, client.size_limits = true, limits
	system.log(.Info, "compositor: window ", system.name_of(client.title[:]), " is resizable from ", u64(limits.least_width), "x", u64(limits.least_height), " to ", u64(limits.largest_width), "x", u64(limits.largest_height))
}

// surface_resize_take takes the record Surface_Resize of a window: the
// memory of a surface of a new size, the answer to the last Resized. The
// checks are bar.surface_resize_refusal: a gift of this process with Read
// that holds two pictures of the size, a resizable window, and the size
// that the request asked, once. A refused record changes nothing, and is
// counted. A taken one ends the request; the compositor maps the memory and
// keeps it until the next Present of the window, which shows it.
surface_resize_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	// The process wrote the number of the handle: it can name any handle of
	// the compositor. A number with no proof of this process is neither used
	// nor closed (surface_create).
	memory := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	if !through {
		client.resizes_refused += 1
		return
	}
	defer system.close(memory)
	facts := bar.Surface_Resize_Facts {
		is_memory    = kind == .Memory,
		readable     = .Read in rights,
		width        = record.values[1],
		height       = record.values[2],
		resizable    = client.resizable && client.surface.pixels != nil,
		limits       = size_range_of(client),
		asked        = client.resize_asked,
		asked_width  = client.resize_asked_width,
		asked_height = client.resize_asked_height,
	}
	if facts.is_memory {
		// A refused size reads as 0 bytes: the check refuses it.
		if pages, size_status := system.memory_size(memory); size_status == .Ok {
			facts.memory_bytes = pages * system.PAGE_SIZE
		}
	}
	if refusal := bar.surface_resize_refusal(facts); refusal != .None {
		client.resizes_refused += 1
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	if status != .Ok {
		// The budget of the compositor counts this mapping, so only a fault
		// of the system refuses it. The request ends, so that a later drag
		// can ask again; until then the process draws into a surface that
		// the screen does not show, and the window keeps its old picture.
		client.resizes_refused += 1
		client.resize_asked, client.resize_edges = false, {}
		system.log(.Warning, "compositor: window ", system.name_of(client.title[:]), ": the surface of ", facts.width, "x", facts.height, " cannot be mapped; the window keeps its size")
		return
	}
	// The answer ends the request. A surface that waits for its Present
	// from an earlier answer cannot exist: no request waits while one does.
	if client.resize_pictures != nil {
		system.memory_unmap(client.resize_pictures)
	}
	client.resize_pictures = ([^]graphics.Color)(address)
	client.resize_width, client.resize_height = int(facts.width), int(facts.height)
	client.resize_pending_edges = client.resize_edges
	client.resize_asked, client.resize_edges = false, {}
}

// resize_declined_take takes the record Resize_Declined: the process keeps
// its size, after a refused budget or because it does not take Resized. The
// request ends, and the edges of the window take a drag again. With no
// request, the record is refused and counted.
resize_declined_take :: proc "contextless" (client: ^Client) {
	if !client.resize_asked {
		client.resizes_refused += 1
		return
	}
	client.resize_asked, client.resize_edges = false, {}
	system.log(.Info, "compositor: window ", system.name_of(client.title[:]), " keeps its size ", u64(client.surface.width), "x", u64(client.surface.height))
}

// size_range_of gives the limits of a window as the pure procedures of the
// places read them.
size_range_of :: proc "contextless" (client: ^Client) -> bar.Size_Range {
	return {least_width = client.size_limits.least_width, least_height = client.size_limits.least_height, largest_width = client.size_limits.largest_width, largest_height = client.size_limits.largest_height}
}

// resize_surface_take makes the surface of the new size the surface of the
// window, at the first Present after Surface_Resize. The edges opposite to
// the ones that the drag held stay in place; then the rule of the places
// keeps the title on the screen, under the bar, so that the principal can
// always take it and its close button. The old surface is unmapped: the
// process closed its own handle before, so the old memory ends here.
resize_surface_take :: proc "contextless" (client: ^Client) {
	damage_window(client)
	old_width, old_height := client.surface.width, client.surface.height
	system.memory_unmap(client.pictures)
	client.pictures = client.resize_pictures
	client.resize_pictures = nil
	if .Left in client.resize_pending_edges {
		client.x += old_width - client.resize_width
	}
	if .Top in client.resize_pending_edges {
		client.y += old_height - client.resize_height
	}
	client.resize_pending_edges = {}
	client.surface = {pixels = client.pictures, width = client.resize_width, height = client.resize_height, stride = client.resize_width}
	client.x, client.y = bar.window_place_kept(client.x, client.y, window_frame_of(client), screen.width, screen.height)
	damage_window(client)
	// The line of a new surface, as surface_create writes it: a reader of
	// the log finds the size and the place of the window in the last one.
	system.log_fact(.Info, Surface_Made{window = window_field(client.title[:]), width = u64(client.surface.width), height = u64(client.surface.height), x = u64(max(client.x, 0)), y = u64(max(client.y, 0))})
	system.log(.Info, "compositor: window ", system.name_of(client.title[:]), " resized from ", u64(old_width), "x", u64(old_height), " to ", u64(client.surface.width), "x", u64(client.surface.height))
}

// resize_edges_under_pointer gives the window whose edges are under the
// pointer, and the edges (bar.resize_target): a window in front hides the
// edges of the windows behind it, and the band outside a frame takes the
// pointer only where no window lies. A window whose request or new surface
// waits for its process has no edge: a new drag of it waits for the answer.
// edges is empty when no edge is there.
resize_edges_under_pointer :: proc "contextless" () -> (index: int, edges: bar.Resize_Edges) {
	hits: [CLIENT_CAPACITY]bar.Window_Hit
	for row in 0 ..< order_count {
		client := &clients[order[order_count - 1 - row]]
		hits[row] = {outer = outer_rectangle_of(client), resizable = client.resizable && !client.resize_asked && client.resize_pictures == nil}
	}
	row, found := bar.resize_target(hits[:order_count], BORDER, pointer_x, pointer_y)
	if row < 0 {
		return -1, {}
	}
	return order[order_count - 1 - row], found
}

// outer_rectangle_of gives the frame of a window on the screen.
outer_rectangle_of :: proc "contextless" (client: ^Client) -> bar.Outer_Rectangle {
	return {client.x, client.y, client.surface.width + 2 * BORDER, client.surface.height + TITLE_HEIGHT + BORDER}
}

// resize_begin starts a drag of the edges of a window: it comes to the
// front, and the outline of its frame shows.
resize_begin :: proc "contextless" (index: int, edges: bar.Resize_Edges) {
	for position in 0 ..< order_count {
		if order[position] == index {
			raise(position)
			break
		}
	}
	client := &clients[index]
	resizing = index
	resize_start = {edges = edges, pointer_x = pointer_x, pointer_y = pointer_y, x = client.x, y = client.y, width = client.surface.width, height = client.surface.height}
	resize_outline = {client.x, client.y, client.x + client.surface.width + 2 * BORDER, client.y + client.surface.height + TITLE_HEIGHT + BORDER}
	resize_outline_damage()
}

// resize_pointer_moved follows the pointer while it holds the edges of a
// window. While the button is down, the outline moves. At the release the
// outline goes, and the process gets the event Resized when the size
// differs: no surface is made during the drag. The compositor keeps the
// asked size until the answer.
resize_pointer_moved :: proc "contextless" (held: bool) {
	client := &clients[resizing]
	x, y, width, height := bar.resize_drag(resize_start, pointer_x, pointer_y, size_range_of(client), 2 * BORDER, TITLE_HEIGHT + BORDER, screen.width, screen.height)
	if held {
		outline := Rectangle{x, y, x + width + 2 * BORDER, y + height + TITLE_HEIGHT + BORDER}
		if outline != resize_outline {
			resize_outline_damage()
			resize_outline = outline
			resize_outline_damage()
		}
		return
	}
	resize_outline_damage()
	resizing = -1
	if width == client.surface.width && height == client.surface.height {
		return
	}
	client.resize_asked = true
	client.resize_asked_width, client.resize_asked_height = width, height
	client.resize_edges = resize_start.edges
	send(client, .Resized, {0 = u64(width), 1 = u64(height)})
	system.log(.Info, "compositor: window ", system.name_of(client.title[:]), " asked to draw at ", u64(width), "x", u64(height))
}

// resize_outline_damage records the rectangle of the outline.
resize_outline_damage :: proc "contextless" () {
	damage_add(resize_outline.left, resize_outline.top, resize_outline.right - resize_outline.left, resize_outline.bottom - resize_outline.top)
}

// resize_shape_of gives the pointer shape of the edges of a window: a
// corner gives a diagonal, a side its axis.
resize_shape_of :: proc "contextless" (edges: bar.Resize_Edges) -> pointer_pictures.Pointer_Shape {
	switch {
	case edges == {.Left, .Top} || edges == {.Right, .Bottom}:
		return .Resize_Top_Left_Bottom_Right
	case edges == {.Right, .Top} || edges == {.Left, .Bottom}:
		return .Resize_Top_Right_Bottom_Left
	case .Left in edges || .Right in edges:
		return .Resize_Left_Right
	}
	return .Resize_Up_Down
}
