package compositor

import "modus:contract/pointer_pictures"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:contract/value_kinds"
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
	if !client.created {
		// A window with no surface yet has no size that the limits can hold.
		return
	}
	// The limits are logical pixels, as the size of the window and the
	// logical size of a surface that waits for its Present.
	width, height := client.width, client.height
	if client.resize_pictures != nil {
		width, height = client.resize_logical_width, client.resize_logical_height
	}
	limits, problem := display.size_limits_of_words({record.values[0], record.values[1], record.values[2], record.values[3]}, width, height)
	if problem != .None {
		if !client.resizable_refusal_logged {
			client.resizable_refusal_logged = true
			system.log_fact(.Warning, Resizable_Refused{limits_problem = value_kinds.text_field(display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], LIMITS_PROBLEM_FIELD_BYTES), window = window_field(client.title[:])})
		}
		return
	}
	client.resizable, client.size_limits = true, limits
	system.log_fact(.Info, Window_Resizable{least_width = u64(limits.least_width), least_height = u64(limits.least_height), largest_width = u64(limits.largest_width), largest_height = u64(limits.largest_height), window = window_field(client.title[:])})
}

// surface_resize_take takes the record Surface_Resize of a window: the
// memory of a surface of a new size, the answer to the last Resized. The
// checks are bar.surface_resize_refusal: a gift of this process with Read
// that holds two pictures of the size, a resizable window, and the size
// that the request asked, once. Each record gets its answer with its
// serial: Resize_Taken, or Resize_Refused, after which the window draws
// the surface that the compositor shows again. A refusal ends the request,
// so a later drag asks again, and is counted. A taken record ends the
// request too; the compositor maps the memory and keeps it until the first
// Present of its serial, which shows it.
surface_resize_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	serial := record.values[3]
	refused :: proc "contextless" (client: ^Client, serial: u64) {
		client.resizes_refused += 1
		client.resize_asked, client.resize_edges = false, {}
		send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Resize_Refused), 1 = serial})
	}
	// The process wrote the number of the handle: it can name any handle of
	// the compositor. A number with no proof of this process is neither used
	// nor closed (surface_create).
	memory := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	if !through {
		refused(client, serial)
		return
	}
	defer system.close(memory)
	// The surface of a resize has the next serial, and the scale of the
	// surface shown: the process made it at its own scale, which a change
	// of the scale that it did not read yet leaves behind the compositor.
	// The rescale that follows corrects it.
	if client.released || client.resize_pictures != nil || serial != client.surface_serial + 1 {
		refused(client, serial)
		return
	}
	// The record holds pixels of the screen; the request and the limits
	// are logical pixels. The check compares pixels of the screen: each
	// logical size at the scale of the surface, by the rule of each edge,
	// so a size that no logical size gives is refused.
	surface_scale := client.surface_scale
	at_scale :: proc "contextless" (place: int, surface_scale: scale_factor.Scale) -> int {
		return int(scale_factor.screen_pixel_of_logical_pixel(i32(clamp(place, 0, display.SURFACE_LIMIT)), surface_scale))
	}
	limits := size_range_of(client)
	facts := bar.Surface_Resize_Facts {
		is_memory    = kind == .Memory,
		readable     = .Read in rights,
		width        = record.values[1],
		height       = record.values[2],
		resizable    = client.resizable && client.created,
		limits       = {least_width = at_scale(limits.least_width, surface_scale), least_height = at_scale(limits.least_height, surface_scale), largest_width = at_scale(limits.largest_width, surface_scale), largest_height = at_scale(limits.largest_height, surface_scale)},
		asked        = client.resize_asked,
		asked_width  = at_scale(client.resize_asked_width, surface_scale),
		asked_height = at_scale(client.resize_asked_height, surface_scale),
	}
	if facts.is_memory {
		// A refused size reads as 0 bytes: the check refuses it.
		if pages, size_status := system.memory_size(memory); size_status == .Ok {
			facts.memory_bytes = pages * system.PAGE_SIZE
		}
	}
	if refusal := bar.surface_resize_refusal(facts); refusal != .None {
		refused(client, serial)
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	if status != .Ok {
		// The budget of the compositor counts this mapping, so only a fault
		// of the system refuses it.
		system.log_fact(.Warning, Surface_Not_Mapped{width = facts.width, height = facts.height, window = window_field(client.title[:])})
		refused(client, serial)
		return
	}
	// The answer ends the request. No surface is pending: the check above
	// refused the record then.
	client.resize_pictures = ([^]graphics.Color)(address)
	client.resize_width, client.resize_height = int(facts.width), int(facts.height)
	client.resize_logical_width, client.resize_logical_height = client.resize_asked_width, client.resize_asked_height
	client.resize_scale, client.resize_serial = surface_scale, serial
	client.resize_pending_edges = client.resize_edges
	client.resize_asked, client.resize_edges = false, {}
	send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Resize_Taken), 1 = serial})
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
	system.log_fact(.Info, Window_Keeps_Size{width = u64(client.width), height = u64(client.height), window = window_field(client.title[:])})
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
	// The old surface, at the place where the last frame drew it: the
	// frame and the background take its pixels when the new one is smaller.
	surface_screen_damage(client)
	old_width, old_height := client.width, client.height
	if client.pictures != nil {
		system.memory_unmap(client.pictures)
	}
	client.pictures = client.resize_pictures
	client.resize_pictures = nil
	// The logical size and the scale that the compositor checked when it
	// took the surface: nothing is computed again from its pixels.
	width, height := client.resize_logical_width, client.resize_logical_height
	client.surface_scale, client.surface_serial, client.released = client.resize_scale, client.resize_serial, false
	if .Left in client.resize_pending_edges {
		client.x += old_width - width
	}
	if .Top in client.resize_pending_edges {
		client.y += old_height - height
	}
	client.resize_pending_edges = {}
	client.surface = {pixels = client.pictures, width = client.resize_width, height = client.resize_height, stride = client.resize_width}
	client.width, client.height = width, height
	client.x, client.y = bar.window_place_kept(client.x, client.y, window_frame_of(client), desktop_width, desktop_height)
	damage_window(client)
	// The line of a new surface, as surface_create writes it: a reader of
	// the log finds the size and the place of the window in the last one.
	// A surface at a new scale keeps the size of the window: no resize.
	system.log_fact(.Info, Surface_Made{window = window_field(client.title[:]), width = u64(client.width), height = u64(client.height), x = u64(max(client.x, 0)), y = u64(max(client.y, 0))})
	// The line that a reader waits for: the window draws again, in the
	// surface that it gave. A window that froze between two surfaces never
	// writes it.
	system.log_fact(.Info, Surface_Shown{serial = client.surface_serial, width = u64(client.surface.width), height = u64(client.surface.height), scale = u64(client.surface_scale), window = window_field(client.title[:])})
	if width != old_width || height != old_height {
		system.log_fact(.Info, Window_Resized{old_width = u64(old_width), old_height = u64(old_height), width = u64(client.width), height = u64(client.height), window = window_field(client.title[:])})
	}
}

// surface_release_take takes the record Surface_Release of a window
// (src/md/features/window_resize.md, "The rescale"): the compositor unmaps
// each surface of the window, shown or pending, ends a request of the
// principal, and draws the frame of the window with the background until a
// surface of the next serial comes. It answers Released with the serial of
// the record, always: the window waits for that answer before it makes its
// next surface, and an answer of another serial changes nothing there.
surface_release_take :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	serial := record.values[0]
	if !client.created || serial == 0 {
		client.resizes_refused += 1
		return
	}
	// A drag of the edges of this window ends here, with no Resized: the
	// window has no surface that a resize could replace, and a request
	// would wait for an answer that the window cannot give.
	if bar.drag_ended_by_release(resizing, index) {
		resize_outline_damage()
		resizing = -1
	}
	damage_window(client)
	surface_screen_damage(client)
	if client.pictures != nil {
		system.memory_unmap(client.pictures)
	}
	if client.resize_pictures != nil {
		system.memory_unmap(client.resize_pictures)
	}
	client.pictures, client.resize_pictures = nil, nil
	client.surface = {}
	client.resize_pending_edges = {}
	client.resize_asked, client.resize_edges = false, {}
	client.released, client.surface_serial = true, serial
	send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Released), 1 = serial})
}

// surface_rescale_take takes the record Surface_Rescale of a window: the
// memory of its surface at the scale of the compositor, after the release
// of the old one. The checks are bar.surface_rescale_refusal. Each record
// gets its answer, Rescale_Taken or Rescale_Refused, with its serial: the
// window then knows which surface the compositor holds. A refused record
// changes nothing else, and is counted with the refused resizes: a process
// cannot change the size of its window with it. A taken one waits for the
// first Present of its serial, which shows it.
surface_rescale_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	serial := record.values[4]
	refused :: proc "contextless" (client: ^Client, serial: u64) {
		client.resizes_refused += 1
		send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Rescale_Refused), 1 = serial})
	}
	memory := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	facts := bar.Surface_Rescale_Facts {
		gift            = through,
		is_memory       = kind == .Memory,
		readable        = .Read in rights,
		width           = record.values[1],
		height          = record.values[2],
		scale_word      = record.values[3],
		serial          = serial,
		created         = client.created,
		released        = client.released,
		pending         = client.resize_pictures != nil,
		asked           = client.resize_asked,
		released_serial = client.surface_serial,
		scale           = scale,
		window_width    = client.width,
		window_height   = client.height,
	}
	if !through {
		// A number with no proof of this process is neither used nor closed.
		refused(client, serial)
		return
	}
	defer system.close(memory)
	if facts.is_memory {
		if pages, size_status := system.memory_size(memory); size_status == .Ok {
			facts.memory_bytes = pages * system.PAGE_SIZE
		}
	}
	if bar.surface_rescale_refusal(facts) != .None {
		refused(client, serial)
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	if status != .Ok {
		system.log_fact(.Warning, Surface_Not_Mapped{width = facts.width, height = facts.height, window = window_field(client.title[:])})
		refused(client, serial)
		return
	}
	client.resize_pictures = ([^]graphics.Color)(address)
	client.resize_width, client.resize_height = int(facts.width), int(facts.height)
	client.resize_logical_width, client.resize_logical_height = client.width, client.height
	client.resize_scale, client.resize_serial = scale, serial
	client.resize_pending_edges = {}
	send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Rescale_Taken), 1 = serial})
}

// surface_screen_damage records the part of the screen that the surface of
// a window covers, at the place where the last frame drew it.
surface_screen_damage :: proc "contextless" (client: ^Client) {
	if client.surface.pixels == nil {
		return
	}
	box := surface_screen_box(client)
	damage_screen_add(box.left, box.top, box.right - box.left, box.bottom - box.top)
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
		hits[row] = {outer = outer_rectangle_of(client), resizable = client.resizable && !client.resize_asked && client.resize_pictures == nil && !client.released}
	}
	row, found := bar.resize_target(hits[:order_count], BORDER, pointer_x, pointer_y)
	if row < 0 {
		return -1, {}
	}
	return order[order_count - 1 - row], found
}

// outer_rectangle_of gives the frame of a window on the screen.
outer_rectangle_of :: proc "contextless" (client: ^Client) -> bar.Outer_Rectangle {
	return {client.x, client.y, client.width + 2 * BORDER, client.height + TITLE_HEIGHT + BORDER}
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
	resize_start = {edges = edges, pointer_x = pointer_x, pointer_y = pointer_y, x = client.x, y = client.y, width = client.width, height = client.height}
	resize_outline = {client.x, client.y, client.x + client.width + 2 * BORDER, client.y + client.height + TITLE_HEIGHT + BORDER}
	resize_outline_damage()
}

// resize_pointer_moved follows the pointer while it holds the edges of a
// window. While the button is down, the outline moves. At the release the
// outline goes, and the process gets the event Resized when the size
// differs: no surface is made during the drag. The compositor keeps the
// asked size until the answer.
resize_pointer_moved :: proc "contextless" (held: bool) {
	client := &clients[resizing]
	x, y, width, height := bar.resize_drag(resize_start, pointer_x, pointer_y, size_range_of(client), 2 * BORDER, TITLE_HEIGHT + BORDER, desktop_width, desktop_height)
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
	if !bar.drag_asks_size(client.released, client.resize_pictures != nil, width == client.width && height == client.height) {
		return
	}
	client.resize_asked = true
	client.resize_asked_width, client.resize_asked_height = width, height
	client.resize_edges = resize_start.edges
	send(client, .Resized, {0 = u64(width), 1 = u64(height)})
	system.log_fact(.Info, Draw_Size_Asked{width = u64(width), height = u64(height), window = window_field(client.title[:])})
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
