package compositor

import "modus:contract/pointer_pictures"
import "modus:contract/ring"
import "modus:private/compositor/bar"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/system"

// The windows that the principal resizes (src/md/features/window_resize.md).
//
// A program declares its window resizable with Resizable. The principal
// drags an edge or a corner; the compositor draws the outline of the new
// frame, and at the release sends the event Resized. The program makes the
// surface of the new size with its own budget and gives it with
// Surface_Resize. The window keeps its old surface until the first Present
// after that record: the loop of the compositor never waits for the
// program, and the screen never shows a size that the program did not draw.

// resizable_take takes the record Resizable of a window: its size limits,
// checked at the border against the surface that it has. A refusal keeps
// the window as it was, with one line for the life of the window.
resizable_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	if client.surface.pixels == nil {
		// A window with no surface yet has no size that the limits can hold.
		return
	}
	limits, problem := display.size_limits_of_words({record.values[0], record.values[1], record.values[2], record.values[3]}, client.surface.width, client.surface.height)
	if problem != .None {
		if !client.resizable_refusal_logged {
			client.resizable_refusal_logged = true
			system.log_in("surfaces", .Warning, "compositor: window ", system.name_of(client.title[:]), " asks to be resizable with limits that it cannot have: ", display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], "; it stays as it was. A window writes this line one time")
		}
		return
	}
	client.resizable, client.size_limits = true, limits
	system.log_in("surfaces", .Info, "compositor: window ", system.name_of(client.title[:]), " is resizable from ", u64(limits.least_width), "x", u64(limits.least_height), " to ", u64(limits.largest_width), "x", u64(limits.largest_height))
}

// surface_resize_take takes the record Surface_Resize of a window: the
// memory of a surface of a new size. The compositor maps it and keeps it
// until the next Present of the window, which shows it. The checks are those
// of a new surface: the handle is a gift of this program, with Read, and
// holds two pictures of the size; the size is inside the limits of the
// window. A refused record changes nothing, and is counted.
surface_resize_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	// The program wrote the number of the handle: it can name any handle of
	// the compositor. A number with no proof of this program is neither used
	// nor closed (surface_create).
	memory := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	if !through {
		client.resizes_refused += 1
		return
	}
	defer system.close(memory)
	width, height := record.values[1], record.values[2]
	// The words first, then the ints: a word past the limit is never a
	// negative size.
	if kind != .Memory || .Read not_in rights || client.surface.pixels == nil || !client.resizable || width > display.SURFACE_LIMIT || height > display.SURFACE_LIMIT || !display.size_inside(client.size_limits, int(width), int(height)) {
		client.resizes_refused += 1
		return
	}
	pages, size_status := system.memory_size(memory)
	if size_status != .Ok || pages * system.PAGE_SIZE < display.PICTURE_COUNT * width * height * size_of(graphics.Color) {
		client.resizes_refused += 1
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	if status != .Ok {
		client.resizes_refused += 1
		return
	}
	// A second surface before a Present replaces the first one.
	if client.resize_pictures != nil {
		system.memory_unmap(client.resize_pictures)
	}
	client.resize_pictures = ([^]graphics.Color)(address)
	client.resize_width, client.resize_height = int(width), int(height)
}

// resize_surface_take makes the surface of the new size the surface of the
// window, at the first Present after Surface_Resize. The edges opposite to
// the ones that the drag held stay in place. The old surface is unmapped:
// the program closed its own handle before, so the old memory ends here.
resize_surface_take :: proc "contextless" (client: ^Client) {
	damage_window(client)
	old_width, old_height := client.surface.width, client.surface.height
	system.memory_unmap(client.pictures)
	client.pictures = client.resize_pictures
	client.resize_pictures = nil
	if .Left in client.resize_edges {
		client.x += old_width - client.resize_width
	}
	if .Top in client.resize_edges {
		client.y += old_height - client.resize_height
	}
	client.surface = {pixels = client.pictures, width = client.resize_width, height = client.resize_height, stride = client.resize_width}
	damage_window(client)
	// The line of a new surface, as surface_create writes it: a reader of
	// the log finds the size and the place of the window in the last one.
	system.log_in("surfaces", .Info, "compositor: surface ", system.name_of(client.title[:]), " ", u64(client.surface.width), "x", u64(client.surface.height), " at ", u64(max(client.x, 0)), ",", u64(client.y))
	system.log_in("surfaces", .Info, "compositor: window ", system.name_of(client.title[:]), " resized from ", u64(old_width), "x", u64(old_height), " to ", u64(client.surface.width), "x", u64(client.surface.height))
}

// outer_rectangle_of gives the frame of a window on the screen.
outer_rectangle_of :: proc "contextless" (client: ^Client) -> bar.Outer_Rectangle {
	return {client.x, client.y, client.surface.width + 2 * BORDER, client.surface.height + TITLE_HEIGHT + BORDER}
}

// resize_edges_under_pointer gives the window whose edges are under the
// pointer, and the edges: the window in front at that place. A window that
// covers the place, resizable or not, hides the edges of the windows
// behind it. edges is empty when no edge is there.
resize_edges_under_pointer :: proc "contextless" () -> (index: int, edges: bar.Resize_Edges) {
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		outer := outer_rectangle_of(client)
		if client.resizable {
			if found := bar.resize_edges_at(outer, BORDER, pointer_x, pointer_y); found != {} {
				return order[position], found
			}
		}
		if inside(pointer_x, pointer_y, outer.x, outer.y, outer.width, outer.height) {
			return -1, {}
		}
	}
	return -1, {}
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
// outline goes, and the program gets the event Resized when the size
// differs: no surface is made during the drag.
resize_pointer_moved :: proc "contextless" (held: bool) {
	client := &clients[resizing]
	sizes := bar.Size_Range{least_width = client.size_limits.least_width, least_height = client.size_limits.least_height, largest_width = client.size_limits.largest_width, largest_height = client.size_limits.largest_height}
	x, y, width, height := bar.resize_drag(resize_start, pointer_x, pointer_y, sizes, 2 * BORDER, TITLE_HEIGHT + BORDER, screen.width, screen.height)
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
	client.resize_edges = resize_start.edges
	send(client, .Resized, {0 = u64(width), 1 = u64(height)})
	system.log_in("surfaces", .Info, "compositor: window ", system.name_of(client.title[:]), " asked to draw at ", u64(width), "x", u64(height))
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
