package compositor

import "modus:contract/call_outcome"
import op "modus:contract/operation"
import "modus:contract/pointer_pictures"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:contract/value_kinds"
import "internal:compositor/bar"
import "modus:display"
import "modus:graphics"
import "modus:system"

// The windows that the principal resizes (src/md/features/window_resize.md).
//
// A process declares its window resizable with Resizable. During an edge or
// corner drag, the compositor sends Resized live (at most one request in flight
// per window, coalescing intermediate moves) and draws the guide outline only
// while the window lags behind the dragged target. The process answers once:
// Surface_Resize with a surface of that size, made with its own budget, or
// Resize_Declined. The window keeps its old surface until the first Present
// after a Surface_Resize: the loop of the compositor never waits for the
// process, and the screen never shows a size that the process did not draw. A
// process cannot change the size of its window when the principal did not ask
// for it.


// resizable_take takes the record Resizable of a window: its size limits,
// checked at the border against the size that the window wants, which its
// layout has: the size that it opened with, or the last size of the
// principal that it took. A clamp to the work area leaves the surface below
// the limits and the layout at that size (display.layout_size_of). A
// refusal keeps the window as it was, with one line for the life of the
// window.
resizable_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	if !client.created {
		// A window with no surface yet has no size that the limits can hold.
		return
	}
	// The limits are logical pixels, as the wanted size of the window.
	limits, problem := display.size_limits_of_words({record.values[0], record.values[1], record.values[2], record.values[3]}, client.wanted_width, client.wanted_height)
	if problem != .None {
		if !client.resizable_refusal_logged {
			client.resizable_refusal_logged = true
			system.log_fact(.Warning, Resizable_Refused{limits_problem = value_kinds.text_field(display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], LIMITS_PROBLEM_FIELD_BYTES), window = window_field(client.title[:])})
		}
		return
	}
	client.resizable, client.size_limits = true, limits
	palette_entries_refresh() // The palette offers the resize of the window in front by keys.
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
		was_asked := client.resize_asked
		was_clamp := was_asked && client.resize_asked_clamp
		declined_w, declined_h := client.resize_asked_width, client.resize_asked_height
		client.resizes_refused += 1
		client.resize_asked, client.resize_edges = false, {}
		if was_asked {
			bar.live_resize_declined(&client.live_resize, declined_w, declined_h)
		}
		send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Resize_Refused), 1 = serial})
		desktop_restore_size_after_answer(client) // desktop_features.odin
		_ = window_scale_step(client) // scale.odin: the end of a fit request
		clamp_ask_again(client, was_clamp)
		if was_asked {
			live_resize_follow_up(client)
		}
	}
	// The process wrote the number of the handle: it can name any handle of
	// the compositor. A number with no proof of this process is neither used
	// nor closed (surface_create).
	budget := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(budget, client.ring_memory)
	if !through {
		refused(client, serial)
		return
	}
	defer system.close(budget)
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
		width        = record.values[1],
		height       = record.values[2],
		resizable    = client.resizable && client.created,
		limits       = {least_width = at_scale(limits.least_width, surface_scale), least_height = at_scale(limits.least_height, surface_scale), largest_width = at_scale(limits.largest_width, surface_scale), largest_height = at_scale(limits.largest_height, surface_scale)},
		asked        = client.resize_asked,
		asked_width  = at_scale(client.resize_asked_width, surface_scale),
		asked_height = at_scale(client.resize_asked_height, surface_scale),
		clamp        = client.resize_asked_clamp,
		screen_side_limit = bar.surface_screen_side_limit(screen.width, screen.height),
	}
	facts.is_budget, facts.can_spend, facts.budget_pages = surface_budget_facts(budget, kind, rights)
	if refusal := bar.surface_resize_refusal(facts); refusal != .None {
		refused(client, serial)
		return
	}
	pictures, memory, given, made := surface_make(client, budget, facts.width, facts.height)
	if !made {
		system.log_fact(.Warning, Surface_Not_Mapped{width = facts.width, height = facts.height, window = window_field(client.title[:])})
		refused(client, serial)
		return
	}
	// The answer ends the request. No surface is pending: the check above
	// refused the record then.
	client.resize_pictures, client.resize_memory = pictures, memory
	client.resize_width, client.resize_height = int(facts.width), int(facts.height)
	client.resize_logical_width, client.resize_logical_height = client.resize_asked_width, client.resize_asked_height
	client.resize_scale, client.resize_serial = surface_scale, serial
	client.resize_pending_edges = client.resize_edges
	// The size before the cut to the work area is the size that the window
	// wants from now on: it gets it back when the work area grows.
	client.wanted_width, client.wanted_height = client.resize_asked_wanted_width, client.resize_asked_wanted_height
	client.clamp_asks = 0
	client.resize_asked, client.resize_edges = false, {}
	send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Resize_Taken), 1 = serial, 2 = u64(given)})
	// The scale after the answer: the window rescales its new surface.
	_ = window_scale_step(client) // scale.odin
}

// surface_budget_facts gives the facts of the budget of a surface that the
// bar checks: a budget, with Spend and Read, and the pages that it can
// still pay (0 when the kernel refused to read them, which the check
// refuses). The window gave it through its ring for that surface alone.
surface_budget_facts :: proc "contextless" (budget: system.Handle, kind: op.Object_Kind, rights: system.Rights) -> (is_budget, can_spend: bool, budget_pages: u64) {
	is_budget = kind == .Budget
	can_spend = rights & {.Spend, .Read} == {.Spend, .Read}
	if is_budget && can_spend {
		if amounts, status := system.budget_read(budget); status == .Succeeded {
			budget_pages = amounts.pages
		}
	}
	return
}

// surface_make makes the surface of a window with the budget that it gave:
// a memory object of two pictures of a size in pixels of the screen, which
// the budget pays. The compositor maps it read-only and gives the window a
// copy with Read and Write through its ring. It never maps a memory object
// that a window made, so no window can stop it with a revocation, an
// Uncommitted object or a decommit: this process is the origin of the copy
// of the window, and the object is in two processes, so no decommit of the
// window reaches it. It gives the pictures, the handle of the object, which
// the compositor keeps until it unmaps them (surface_memory_end), and the
// number of the copy of the window. A budget that does not pay, or a copy
// that the window revoked, gives made false and holds nothing.
surface_make :: proc "contextless" (client: ^Client, budget: system.Handle, screen_width, screen_height: u64) -> (pictures: [^]graphics.Color, memory, given: system.Handle, made: bool) {
	pages := (screen_width * screen_height * u64(size_of(graphics.Color) * display.PICTURE_COUNT) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	status: call_outcome.Call_Outcome
	memory, status = system.memory_create(pages, budget)
	if status != .Succeeded {
		return nil, 0, 0, false
	}
	address, map_status := system.memory_map(memory, {}) // Read only.
	if map_status != .Succeeded {
		system.close(memory)
		return nil, 0, 0, false
	}
	give_status: call_outcome.Call_Outcome
	given, give_status = system.give(client.ring_memory, memory, {.Read, .Write})
	if give_status != .Succeeded {
		system.memory_unmap(address)
		system.close(memory)
		return nil, 0, 0, false
	}
	return ([^]graphics.Color)(address), memory, given, true
}

// surface_memory_end unmaps the pictures of a surface and closes the handle
// of its object: the copy of the window keeps the object until the window
// closes it.
surface_memory_end :: proc "contextless" (pictures: ^[^]graphics.Color, memory: ^system.Handle) {
	if pictures^ != nil {
		system.memory_unmap(pictures^)
	}
	if memory^ != 0 {
		system.close(memory^)
	}
	pictures^, memory^ = nil, 0
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
	was_clamp := client.resize_asked_clamp
	declined_w, declined_h := client.resize_asked_width, client.resize_asked_height
	client.resize_asked, client.resize_edges = false, {}
	bar.live_resize_declined(&client.live_resize, declined_w, declined_h)
	system.log_fact(.Info, Window_Keeps_Size{width = u64(client.width), height = u64(client.height), window = window_field(client.title[:])})
	desktop_restore_size_after_answer(client) // desktop_features.odin
	_ = window_scale_step(client) // scale.odin: the end of a fit request
	clamp_ask_again(client, was_clamp)
	live_resize_follow_up(client)
}

// CLAMP_ASKS_MOST bounds the asks of a clamp that end with no new surface,
// in a row. A window declines a request while it is between two surfaces,
// so one decline is no answer of the process; a process that declines each
// clamp, as one that never takes Resized, keeps its larger surface after
// the last ask, and the compositor never asks it without end.
CLAMP_ASKS_MOST :: 3

// clamp_ask_again asks a clamp again at the end of a request that gave the
// window no new surface (a refusal or a decline): the fit to the work area,
// at once when the window shows a surface of the scale in force, or else
// when it shows one (window_fit_after_scale).
clamp_ask_again :: proc "contextless" (client: ^Client, was_clamp: bool) {
	if !was_clamp || client.clamp_asks >= CLAMP_ASKS_MOST {
		return
	}
	client.clamp_asks += 1
	client.fit_after_scale = true
	window_fit_after_scale(client) // scale.odin
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
// always take it and its close button. The old surface is unmapped and its
// handle closed: the window let its copy go at Resize_Taken, so the old
// memory ends here.
resize_surface_take :: proc "contextless" (client: ^Client) {
	damage_window(client)
	// The old surface, at the place where the last frame drew it: the
	// frame and the background take its pixels when the new one is smaller.
	surface_screen_damage(client)
	old_width, old_height := client.width, client.height
	surface_memory_end(&client.pictures, &client.pictures_memory)
	client.pictures, client.pictures_memory = client.resize_pictures, client.resize_memory
	client.resize_pictures, client.resize_memory = nil, 0
	// The logical size and the scale that the compositor checked when it
	// took the surface: nothing is computed again from its pixels.
	width, height := client.resize_logical_width, client.resize_logical_height
	client.surface_scale, client.surface_serial, client.released = client.resize_scale, client.resize_serial, false
	if .Left in client.resize_pending_edges {
		// Anchor from the drag start across live and post-release commits so
		// an intermediate window_place_kept clamp never shifts the right edge.
		if client.live_resize.anchor_valid {
			client.x = client.live_resize.anchor_right - width
		} else {
			client.x += old_width - width
		}
	}
	if .Top in client.resize_pending_edges {
		if client.live_resize.anchor_valid {
			client.y = client.live_resize.anchor_bottom - height
		} else {
			client.y += old_height - height
		}
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
	desktop_restore_size_after_answer(client) // desktop_features.odin
	// A fit that grows the window waits for this surface at the new scale.
	window_fit_after_scale(client) // scale.odin
	// Continue an active live resize drag or apply a final size queued at release.
	live_resize_follow_up(client)
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
	// The release of the first surface before its first Present: an open
	// that failed (display.open). The window ends, as if no Surface_Create
	// came, so no window stays behind and the next open makes one.
	if serial == 1 && client.surface_serial == 1 && client.presents == 0 && client.resize_pictures == nil {
		window_unmade(index) // main.odin
		send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Released), 1 = serial})
		return
	}
	// A drag of the edges of this window ends here, with no Resized: the
	// window has no surface that a resize could replace, and a request
	// would wait for an answer that the window cannot give.
	if bar.drag_ended_by_release(resizing, index) {
		resize_outline_damage()
		resizing = -1
	}
	bar.live_resize_cancel(&client.live_resize)
	// A resize by keys ends the same way: the size that it shows has no
	// surface to replace.
	if keyboard_window_mode == .Resize {
		keyboard_window_gone(index) // keyboard_desktop.odin
	}
	// The release of a fixed window can answer its clamp: it then offers
	// the surface of the clamped size, and holds one surface at a time
	// (src/md/features/window_resize.md, "The clamp of a fixed window").
	release_end := bar.release_end_of(client.resize_asked, client.resize_asked_clamp, client.resizable, client.resize_pictures != nil, record.values[1], record.values[2], client.resize_asked_width, client.resize_asked_height)
	damage_window(client)
	surface_screen_damage(client)
	surface_memory_end(&client.pictures, &client.pictures_memory)
	switch release_end {
	case .No_Request, .Request_Ended:
	case .Clamp_Ended:
		// The window offers the size that it holds; the fit is asked again
		// once it shows its surface of the scale in force.
		client.fit_after_scale = true
	case .Clamp_Answered:
		// The offer after the release must have the clamped size
		// (bar.surface_rescale_refusal reads the logical size); the frame
		// of that size shows the background until it comes.
		old_width, old_height := client.width, client.height
		client.width, client.height = client.resize_asked_width, client.resize_asked_height
		client.wanted_width, client.wanted_height = client.resize_asked_wanted_width, client.resize_asked_wanted_height
		client.clamp_asks = 0
		client.x, client.y = bar.window_place_kept(client.x, client.y, window_frame_of(client), desktop_width, desktop_height)
		damage_window(client)
		if client.width != old_width || client.height != old_height {
			system.log_fact(.Info, Window_Resized{old_width = u64(old_width), old_height = u64(old_height), width = u64(client.width), height = u64(client.height), window = window_field(client.title[:])})
		}
	}
	if client.resize_pictures != nil {
		surface_memory_end(&client.resize_pictures, &client.resize_memory)
		// The compositor took that resize, so the window holds its size: the
		// surface that the window offers after the release has it.
		client.width, client.height = client.resize_logical_width, client.resize_logical_height
	}
	client.surface = {}
	client.resize_pending_edges = {}
	client.resize_asked, client.resize_edges = false, {}
	client.released, client.surface_serial = true, serial
	// The release ended a request of the size: a scale that waited for it
	// goes now, before the answer, so the window reads the scale while it
	// releases and offers its next surface at it. Named after the answer,
	// the window offered at its old scale, which the compositor refuses.
	_ = window_scale_step(client) // scale.odin
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
		// The window counts the refused offer: its next one names the serial
		// after it (bar.serial_after_refused_offer).
		client.surface_serial = bar.serial_after_refused_offer(client.released, client.resize_pictures != nil, client.surface_serial, serial)
		send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Rescale_Refused), 1 = serial})
	}
	budget := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(budget, client.ring_memory)
	facts := bar.Surface_Rescale_Facts {
		gift            = through,
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
		screen_side_limit = bar.surface_screen_side_limit(screen.width, screen.height),
	}
	if !through {
		// A number with no proof of this process is neither used nor closed.
		refused(client, serial)
		return
	}
	defer system.close(budget)
	facts.is_budget, facts.can_spend, facts.budget_pages = surface_budget_facts(budget, kind, rights)
	if bar.surface_rescale_refusal(facts) != .None {
		refused(client, serial)
		return
	}
	pictures, memory, given, made := surface_make(client, budget, facts.width, facts.height)
	if !made {
		system.log_fact(.Warning, Surface_Not_Mapped{width = facts.width, height = facts.height, window = window_field(client.title[:])})
		refused(client, serial)
		return
	}
	client.resize_pictures, client.resize_memory = pictures, memory
	client.resize_width, client.resize_height = int(facts.width), int(facts.height)
	client.resize_logical_width, client.resize_logical_height = client.width, client.height
	client.resize_scale, client.resize_serial = scale, serial
	client.resize_pending_edges = {}
	send(client, .Surface_Answer, {0 = u64(display.Surface_Answer_Kind.Rescale_Taken), 1 = serial, 2 = u64(given)})
	if client.declined {
		client.declined = false
		windows_declined_tell() // scale.odin
	}
}

// surface_declined_take takes the record Surface_Declined of a window: its
// budget could not pay its surface at the scale in force, after its
// release. The checks are bar.surface_declined_refusal. A taken record
// moves the serial released to the serial of the offer, so the next
// Surface_Rescale of the window names the serial after it; the frame of
// the window keeps the background; the count of the windows that declined
// the scale goes to each window. A second decline of the same scale is no
// news (bar.surface_decline_is_news): no fact, no count. A refused record changes nothing, and is
// counted with the refused resizes.
surface_declined_take :: proc "contextless" (client: ^Client, record: ring.Record) {
	serial := record.values[0]
	facts := bar.Surface_Declined_Facts {
		scale_word      = record.values[1],
		serial          = serial,
		created         = client.created,
		released        = client.released,
		pending         = client.resize_pictures != nil,
		released_serial = client.surface_serial,
		scale           = scale,
	}
	if bar.surface_declined_refusal(facts) != .None {
		client.resizes_refused += 1
		return
	}
	client.surface_serial = serial
	if !bar.surface_decline_is_news(client.declined, client.declined_scale, scale) {
		return
	}
	client.declined, client.declined_scale = true, scale
	system.log_fact(.Warning, Window_Declined_Scale{scale = u64(scale), window = window_field(client.title[:])})
	windows_declined_tell() // scale.odin
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
	return resize_edges_at(pointer_x, pointer_y)
}

// resize_edges_at gives the window whose edges are at the logical place
// (x, y), and the edges, as resize_edges_under_pointer: the pointer of a
// viewer of a wide grant is not the local pointer.
resize_edges_at :: proc "contextless" (x, y: int) -> (index: int, edges: bar.Resize_Edges) {
	hits: [CLIENT_CAPACITY]bar.Window_Hit
	for row in 0 ..< order_count {
		client := &clients[order[order_count - 1 - row]]
		hits[row] = {outer = outer_rectangle_of(client), resizable = client.resizable && !client.resize_asked && client.resize_pictures == nil && !client.released}
	}
	row, found := bar.resize_target(hits[:order_count], BORDER, x, y)
	if row < 0 {
		return -1, {}
	}
	return order[order_count - 1 - row], found
}

// outer_rectangle_of gives the frame of a window on the screen.
outer_rectangle_of :: proc "contextless" (client: ^Client) -> bar.Outer_Rectangle {
	return {client.x, client.y, client.width + 2 * BORDER, client.height + TITLE_HEIGHT + BORDER}
}

// client_resize_busy reports whether a window already has a resize request,
// pending surface, or surface release in flight.
client_resize_busy :: proc "contextless" (client: ^Client) -> bool {
	return client.resize_asked || client.resize_pictures != nil || client.released
}

// live_resize_follow_up sends the newest coalesced live drag target or queued
// post-release final target as soon as an in-flight resize surface is shown.
live_resize_follow_up :: proc "contextless" (client: ^Client) {
	if resizing >= 0 && &clients[resizing] == client {
		resize_outline_damage()
	}
	ask := bar.live_resize_settled(&client.live_resize, client.width, client.height, client_resize_busy(client))
	if ask.ask && window_size_ask(client, ask.width, ask.height, ask.edges) {
		window_unmaximize_on_resize(client)
	}
}

// resize_begin starts a live drag of the edges of a window: it comes to the
// front and begins tracking coalesced live resize targets.
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
	bar.live_resize_begin(&client.live_resize, edges, client.x, client.y, client.width, client.height)
}

// window_unmaximize_on_resize clears the maximized state once a resize drag or
// keyboard resize actually asks for a new size, keeping saved restore geometry
// intact when a border click or canceled drag asks for no resize.
window_unmaximize_on_resize :: proc "contextless" (client: ^Client) {
	if !client.maximized {
		return
	}
	client.maximized = false
	system.log_fact(.Info, Window_Restored{window = window_field(client.title[:])})
	palette_entries_refresh()
	damage_window(client)
}

// resize_pointer_moved follows the pointer while it holds the edges of a
// window. While held, it asks the process live (at most one request in flight,
// coalescing intermediate moves) and draws the guide outline only while the
// window lags behind the dragged target. At release, any remaining final target
// is sent immediately or queued until the in-flight surface lands.
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
		ask := bar.live_resize_move(&client.live_resize, width, height, client.width, client.height, client_resize_busy(client))
		if ask.ask && window_size_ask(client, ask.width, ask.height, ask.edges) {
			window_unmaximize_on_resize(client)
		}
		return
	}
	resize_outline_damage()
	resizing = -1
	ask := bar.live_resize_release(&client.live_resize, width, height, client.width, client.height, client_resize_busy(client))
	if ask.ask && window_size_ask(client, ask.width, ask.height, ask.edges) {
		window_unmaximize_on_resize(client)
	}
}

// window_size_ask asks the process of a window for a size with the one
// event Resized, as at the release of a drag of its edges. width and height
// are the size that the window wants, never a size that a work area cut:
// the window keeps it as wanted (bar.size_request_of). The compositor
// cuts the size to the room of the work area under the frame, so no surface
// passes the work area; a cut size, a size below the least size, or any
// size of a fixed window is a clamp, which the window scrolls its layout in
// (src/md/features/window_scroll.md). One request at a time: a request that
// waits for its answer is never crossed by a second. It gives true when it
// sent the request.
window_size_ask :: proc "contextless" (client: ^Client, width, height: int, edges: bar.Resize_Edges) -> (asked: bool) {
	chrome_width, chrome_height := window_chrome_of(client)
	top := desktop_work_top()
	request := bar.size_request_of(width, height, chrome_width, chrome_height, {left = 0, top = top, width = desktop_width, height = desktop_work_bottom() - top})
	asked_width, asked_height := request.asked_width, request.asked_height
	limits := size_range_of(client)
	clamp := !client.resizable || request.cut || asked_width < limits.least_width || asked_height < limits.least_height
	if client.resize_asked || !bar.drag_asks_size(client.released, client.resize_pictures != nil, asked_width == client.width && asked_height == client.height) {
		return false
	}
	client.resize_asked, client.resize_asked_clamp = true, clamp
	client.resize_asked_width, client.resize_asked_height = asked_width, asked_height
	client.resize_asked_wanted_width, client.resize_asked_wanted_height = request.wanted_width, request.wanted_height
	client.resize_edges = edges
	send(client, .Resized, {0 = u64(asked_width), 1 = u64(asked_height)})
	system.log_fact(.Info, Draw_Size_Asked{width = u64(asked_width), height = u64(asked_height), window = window_field(client.title[:])})
	return true
}

// window_chrome_of gives the columns and the lines of the frame of a window
// around its surface: none for a window that draws its own frame.
window_chrome_of :: proc "contextless" (client: ^Client) -> (chrome_width, chrome_height: int) {
	if client.decoration == .Client {
		return 0, 0
	}
	return 2 * BORDER, TITLE_HEIGHT + BORDER
}

// window_frame_take puts a window into a frame of the screen: its place,
// and the size of its surface that fills the outer size of the frame.
window_frame_take :: proc "contextless" (client: ^Client, x, y, outer_width, outer_height: int) {
	width, height := outer_width - 2 * BORDER, outer_height - TITLE_HEIGHT - BORDER
	if client.decoration == .Client {
		// The process draws its own frame inside its surface.
		width, height = outer_width, outer_height
	}
	window_place_and_size_take(client, x, y, width, height)
}

// window_place_and_size_take moves a window and asks its process for a new
// size (window_size_ask). The size stays within the limits that the process
// declared; a fixed window is asked its wanted size, which the work area
// can cut. The top left corner stays where it is when the new surface
// comes, so the window fills the frame that it asked.
window_place_and_size_take :: proc "contextless" (client: ^Client, x, y, width, height: int) {
	// An explicit maximize, restore, snap, or scale fit supersedes any queued
	// post-drag live resize target.
	bar.live_resize_cancel(&client.live_resize)
	damage_window(client)
	client.x, client.y = x, y
	damage_window(client)
	asked_width, asked_height := client.wanted_width, client.wanted_height
	if client.resizable {
		limits := size_range_of(client)
		asked_width = clamp(width, limits.least_width, limits.largest_width)
		asked_height = clamp(height, limits.least_height, limits.largest_height)
	}
	_ = window_size_ask(client, asked_width, asked_height, {.Right, .Bottom})
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
