package bar

// The checks of the compositor for the surface of a window at a scale
// (src/md/features/window_resize.md, "The rescale: one state machine on
// each side"), and the screen geometry of the frame of a window, as pure
// procedures: a host test gives them each refused case, and each corner.

import "modus:contract/scale_factor"

// The largest logical width and height of a window: the limit of
// display.SURFACE_LIMIT, which this package does not import.
WINDOW_LOGICAL_LIMIT :: 8192

// The side in pixels of the screen that a surface can always have, on any
// screen: a window of 2048 logical pixels at the largest scale. On a
// larger screen the side is twice the longest side of the screen, so a
// window of the whole screen fits at each scale and the mapping of one
// surface stays a multiple of the screen that the budget of the compositor
// pays (src/md/features/window_resize.md, "The size of a surface").
SURFACE_SCREEN_SIDE_FLOOR :: 4096

// surface_screen_side_limit gives the largest side in pixels of the screen
// of one surface on a screen of a size.
surface_screen_side_limit :: proc "contextless" (screen_width, screen_height: int) -> u64 {
	longest := u64(max(screen_width, screen_height, 0))
	return max(SURFACE_SCREEN_SIDE_FLOOR, 2 * longest)
}

// scale_after_read gives the scale of the desktop after a read of the
// settings page: the scale of the page when the read took it, else the
// scale in force. A page that the read refuses, a writer left in its
// change among them, gives its defaults; the scale is the one setting that
// does not take its default, since each window holds a surface of the
// scale in force.
scale_after_read :: proc "contextless" (in_force, read: scale_factor.Scale, read_ok: bool) -> scale_factor.Scale {
	return read_ok ? read : in_force
}

// What the compositor knows when a window creates its surface: the words of
// the record Surface_Create and the facts of the handle.
Surface_Create_Facts :: struct {
	is_memory:     bool,
	readable:      bool,
	memory_bytes:  u64, // 0 when the kernel refused to give the size.
	scale_word:    u64, // The bits of the first word above its handle.
	width, height: u64, // The logical size: the words of the record.
	screen_side_limit: u64, // surface_screen_side_limit of the screen in force.
}

// The rule that a Surface_Create breaks. None: the compositor takes it.
Surface_Create_Refusal :: enum {
	None,
	Not_Memory,
	No_Read,
	No_Scale, // The word names no scale of the range.
	Size_Out_Of_Range, // A logical side of 0, or past WINDOW_LOGICAL_LIMIT.
	Past_Screen, // A side in pixels of the screen past screen_side_limit.
	Too_Small, // The memory does not hold two pictures of its pixels of the screen.
}

// surface_create_refusal decides a Surface_Create, and gives the pixels of
// the screen of its surface: the logical size at the scale of the record,
// by the rule of each edge. The words are read as words.
surface_create_refusal :: proc "contextless" (facts: Surface_Create_Facts) -> (refusal: Surface_Create_Refusal, scale: scale_factor.Scale, screen_width, screen_height: u64) {
	switch {
	case !facts.is_memory:
		return .Not_Memory, {}, 0, 0
	case !facts.readable:
		return .No_Read, {}, 0, 0
	case facts.width == 0 || facts.height == 0 || facts.width > WINDOW_LOGICAL_LIMIT || facts.height > WINDOW_LOGICAL_LIMIT:
		return .Size_Out_Of_Range, {}, 0, 0
	}
	problem: scale_factor.Scale_Problem
	scale, problem = scale_factor.scale_of_word(facts.scale_word)
	if problem != .None {
		return .No_Scale, {}, 0, 0
	}
	screen_width = u64(scale_factor.screen_pixel_of_logical_pixel(i32(facts.width), scale))
	screen_height = u64(scale_factor.screen_pixel_of_logical_pixel(i32(facts.height), scale))
	if screen_width > facts.screen_side_limit || screen_height > facts.screen_side_limit {
		return .Past_Screen, {}, 0, 0
	}
	if facts.memory_bytes / SURFACE_BYTES_FOR_EACH_PIXEL / screen_width < screen_height {
		return .Too_Small, {}, 0, 0
	}
	return .None, scale, screen_width, screen_height
}

// What the compositor knows when a window offers its surface at a new
// scale: the words of the record Surface_Rescale, the facts of the handle,
// and the state of the window and of the compositor.
Surface_Rescale_Facts :: struct {
	gift:          bool, // The handle is a gift of this process through its ring.
	is_memory:     bool,
	readable:      bool,
	memory_bytes:  u64,
	width, height: u64, // Pixels of the screen: words of the record.
	scale_word:    u64,
	serial:        u64,
	created:       bool, // The window made its surface with Surface_Create.
	released:      bool, // The compositor shows no surface of the window: the window released it.
	pending:       bool, // A surface of a resize or of a rescale waits for its Present.
	asked:         bool, // A request of the principal waits for its answer.
	released_serial: u64, // The serial of the surface that the window released.
	scale:         scale_factor.Scale, // The scale of the compositor.
	window_width, window_height: int, // The logical size of the window.
	screen_side_limit: u64, // surface_screen_side_limit of the screen in force.
}

// What a Surface_Release does to the request of the size that waits
// (src/md/features/window_resize.md, "The clamp of a fixed window").
Release_End :: enum u8 {
	No_Request, // No request waited.
	Request_Ended, // A request that is no clamp (a size of the principal): it ends with no new size.
	Clamp_Answered, // A fixed window holds the asked size as its view: the release answers its clamp, and the window offers that size next.
	Clamp_Ended, // A clamp that the release does not answer: it ends with no new size, and the fit waits for the surface of the scale in force.
}

// release_end_of decides what a Surface_Release does to the request that
// waits, from the record (the view that the window holds, words of the
// ring) and the request. A fixed window answers its clamp by a release
// that names the asked size as its view, so it holds one surface at a time.
// A release that names another view was sent for a rescale before the
// window read the clamp, which it then declines: taken as the answer, the
// compositor would wait for a size that the window never offers. A clamp of
// a resizable window, a window with a pending surface, and a size of 0 are
// never answered by a release.
release_end_of :: proc "contextless" (asked, clamp, resizable, pending: bool, held_width, held_height: u64, asked_width, asked_height: int) -> Release_End {
	switch {
	case !asked:
		return .No_Request
	case !clamp:
		return .Request_Ended
	case resizable || pending || asked_width < 1 || asked_height < 1:
		return .Clamp_Ended
	case held_width != u64(asked_width) || held_height != u64(asked_height):
		return .Clamp_Ended
	}
	return .Clamp_Answered
}

// fit_first_waits says if a fit that comes before the scale waits for the
// surface of the scale in force: a window that is released, or that has a
// surface pending, takes no request, so the fit asked now would ask
// nothing and be lost.
fit_first_waits :: proc "contextless" (released, pending: bool) -> bool {
	return released || pending
}

// serial_after_refused_offer gives the serial that the compositor holds as
// released after it refused a Surface_Rescale. The window counts each offer:
// after Rescale_Refused it waits in Released with the serial of the offer,
// and its next offer names the serial after it. So a refused offer of the
// next serial, from a released window with no pending surface, moves the
// serial released to it; with no move, each later offer named a serial
// past the one expected, and the window never showed a surface again. Any
// other refused record (another serial, a window that is not released)
// moves nothing.
serial_after_refused_offer :: proc "contextless" (released, pending: bool, released_serial, offered_serial: u64) -> u64 {
	if released && !pending && released_serial != max(u64) && offered_serial == released_serial + 1 {
		return offered_serial
	}
	return released_serial
}

// The rule that a Surface_Rescale breaks. None: the compositor takes it.
Surface_Rescale_Refusal :: enum {
	None,
	Not_A_Gift, // The handle is no gift of this process: neither used nor closed.
	Not_Memory,
	No_Read,
	No_Window, // No Surface_Create came before.
	Not_Released, // The compositor still shows a surface of the window.
	Pending, // A surface waits for its Present.
	Asked, // A request of the principal waits.
	Other_Serial, // Not the serial one past the released one.
	Other_Scale, // Not the scale of the compositor.
	Other_Size, // Not the logical size of the window at that scale, to the pixel.
	Past_Screen, // A side in pixels of the screen past screen_side_limit.
	Too_Small, // The memory does not hold two pictures of the size.
}

// The facts of a Surface_Declined: the window could not pay its surface at
// the scale of the compositor, after its release.
Surface_Declined_Facts :: struct {
	scale_word:      u64,
	serial:          u64,
	created:         bool, // The window made its surface with Surface_Create.
	released:        bool, // The compositor shows no surface of the window.
	pending:         bool, // A surface of a resize or of a rescale waits for its Present.
	released_serial: u64, // The serial of the surface that the window released.
	scale:           scale_factor.Scale, // The scale of the compositor.
}

// The rule that a Surface_Declined breaks. None: the compositor counts the
// window as one that declined the scale in force.
Surface_Declined_Refusal :: enum {
	None,
	No_Window, // No Surface_Create came before.
	Pending, // A surface waits for its Present.
	Not_Released, // The compositor still shows a surface of the window.
	Other_Serial, // Not the serial one past the released one: the window offered nothing in its place.
	Other_Scale, // Not the scale of the compositor: the window declines no scale that is not in force.
}

// surface_declined_refusal decides a Surface_Declined from its facts. It
// takes only the decline of the offer that the window owes in place of a
// Surface_Rescale: a window cannot hide its surface by a decline while the
// compositor shows it, nor be counted for a scale that is not in force.
surface_declined_refusal :: proc "contextless" (facts: Surface_Declined_Facts) -> Surface_Declined_Refusal {
	switch {
	case !facts.created:
		return .No_Window
	case facts.pending:
		return .Pending
	case !facts.released:
		return .Not_Released
	case facts.serial != facts.released_serial + 1:
		return .Other_Serial
	}
	scale, problem := scale_factor.scale_of_word(facts.scale_word)
	if problem != .None || scale != facts.scale {
		return .Other_Scale
	}
	return .None
}

// surface_decline_is_news says whether a taken Surface_Declined changes
// what the compositor knows of the window: a window that declined the
// scale in force and declines it again, at the next serial, changes
// nothing, so it writes no fact and tells no window. Without this rule a
// window fills the log with one warning per record.
surface_decline_is_news :: proc "contextless" (was_declined: bool, declined_scale: scale_factor.Scale, scale: scale_factor.Scale) -> bool {
	return !was_declined || declined_scale != scale
}

// surface_rescale_refusal decides a Surface_Rescale from its facts. A size
// 1 pixel off on either axis is another size: the surface must be exactly
// the logical size of the window at the scale, so the logical size that
// the compositor keeps is the size of the window.
surface_rescale_refusal :: proc "contextless" (facts: Surface_Rescale_Facts) -> Surface_Rescale_Refusal {
	switch {
	case !facts.gift:
		return .Not_A_Gift
	case !facts.is_memory:
		return .Not_Memory
	case !facts.readable:
		return .No_Read
	case !facts.created:
		return .No_Window
	case facts.pending:
		return .Pending
	case !facts.released:
		return .Not_Released
	case facts.asked:
		return .Asked
	case facts.serial != facts.released_serial + 1:
		return .Other_Serial
	}
	scale, problem := scale_factor.scale_of_word(facts.scale_word)
	if problem != .None || scale != facts.scale {
		return .Other_Scale
	}
	if facts.window_width <= 0 || facts.window_height <= 0 || facts.window_width > WINDOW_LOGICAL_LIMIT || facts.window_height > WINDOW_LOGICAL_LIMIT {
		return .Other_Size
	}
	wanted_width := u64(scale_factor.screen_pixel_of_logical_pixel(i32(facts.window_width), scale))
	wanted_height := u64(scale_factor.screen_pixel_of_logical_pixel(i32(facts.window_height), scale))
	if facts.width != wanted_width || facts.height != wanted_height {
		return .Other_Size
	}
	if wanted_width > facts.screen_side_limit || wanted_height > facts.screen_side_limit {
		return .Past_Screen
	}
	if facts.memory_bytes / SURFACE_BYTES_FOR_EACH_PIXEL / wanted_width < wanted_height {
		return .Too_Small
	}
	return .None
}

// A rectangle of the screen or of the layout: right and bottom are not in
// it.
Screen_Box :: struct {
	left, top, right, bottom: int,
}

// The logical parts of the frame of a window whose corner is at (x, y), of
// a logical size, as the compositor draws them: the title, the bottom
// border, the left and the right border. Each border reaches one logical
// pixel under the interior, which the surface covers: the corner of the
// surface rounds on its own, and no pixel of the background shows between
// the frame and the surface.
frame_parts :: proc "contextless" (x, y, width, height, border, title_height: int) -> [4]Screen_Box {
	outer_width := width + 2 * border
	outer_height := height + title_height + border
	return {
		{x, y, x + outer_width, y + title_height + 1},
		{x, y + outer_height - border - 1, x + outer_width, y + outer_height},
		{x, y + title_height, x + border + 1, y + outer_height - border},
		{x + outer_width - border - 1, y + title_height, x + outer_width, y + outer_height - border},
	}
}

// screen_box_of gives the box of the screen of a logical box at a scale,
// each edge by the rule of the drawing module.
screen_box_of :: proc "contextless" (box: Screen_Box, scale: scale_factor.Scale) -> Screen_Box {
	edge :: proc "contextless" (place: int, scale: scale_factor.Scale) -> int {
		return int(scale_factor.screen_pixel_of_logical_pixel(i32(clamp(place, -(1 << 22), 1 << 22)), scale))
	}
	return {edge(box.left, scale), edge(box.top, scale), edge(box.right, scale), edge(box.bottom, scale)}
}

// surface_clip gives the part of the screen where the compositor copies a
// surface: the surface at its corner, cut to the box of the screen of the
// logical interior of the window. A surface of another scale, larger than
// the interior, never draws over the frame or another window.
surface_clip :: proc "contextless" (corner_x, corner_y, screen_width, screen_height: int, interior: Screen_Box) -> Screen_Box {
	return {max(corner_x, interior.left), max(corner_y, interior.top), min(corner_x + screen_width, interior.right), min(corner_y + screen_height, interior.bottom)}
}
