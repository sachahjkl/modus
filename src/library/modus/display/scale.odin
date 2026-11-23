package display

// The scale factor of a window (src/md/features/desktop_to_browser.md, "The
// reference screen"; the rescale: src/md/features/window_resize.md, "The
// rescale: one state machine on each side"). A process states its size and
// its places in logical pixels. Its surface is in pixels of the screen, at
// the scale that the compositor named: the drawing module draws the logical
// records into it at that scale. The process never computes a screen pixel.
//
// The words between the window and the compositor: a size of a surface and
// the rectangle of a Present are pixels of the screen; a place of the
// pointer, a size that Resized asks for and the size limits are logical
// pixels, which mean the same at each scale.

import "modus:contract/enum_word"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "modus:graphics"
import "modus:system"

// The largest width and height of a surface in pixels of the screen that
// the words of a window can name: a window of SURFACE_LIMIT logical pixels
// at the largest scale that the setting takes. The compositor bounds each
// surface by its screen in force too (bar.surface_screen_side_limit).
SURFACE_SCREEN_LIMIT :: (SURFACE_LIMIT * int(scale_factor.LARGEST) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE

// The place of the surface serial in a Present.
PRESENT_SURFACE_SERIAL :: 6

// The bits of the first word of Surface_Create: the handle in the low 32
// bits, the word of the scale of the surface above them.
SURFACE_CREATE_SCALE_SHIFT :: 32

// The bytes of the Text field of the title of a window in a fact of
// display: the title (32 bytes), its zero byte, up to a multiple of 8.
WINDOW_FACT_TEXT_BYTES :: 40

// The answers of the compositor in the event Surface_Answer. The values
// cross the ring, so they are stated.
Surface_Answer_Kind :: enum u64 {
	Released        = 1, // The compositor maps nothing of the serial any more.
	Rescale_Taken   = 2, // The compositor holds the offered surface; its next Present shows it.
	Rescale_Refused = 3, // The compositor holds nothing of the offered surface.
	Resize_Taken    = 4, // The compositor holds the surface of the new size; its next Present shows it.
	Resize_Refused  = 5, // The compositor holds nothing of the surface of the new size, and shows the surface before it.
	Create_Taken    = 6, // The compositor made the first surface of the window (serial 1); open maps it.
	Create_Refused  = 7, // The compositor made no first surface: the budget that the window gave failed its border, or paid no surface.
}

// surface_answer_gives_surface says if an answer names the copy of a
// surface that the compositor made for the window: values[2] of the
// record, which is 0 in each other answer.
surface_answer_gives_surface :: proc "contextless" (kind: Surface_Answer_Kind) -> bool {
	switch kind {
	case .Rescale_Taken, .Resize_Taken, .Create_Taken:
		return true
	case .Released, .Rescale_Refused, .Resize_Refused, .Create_Refused:
	}
	return false
}

// The phases of the surface of a window: its rescale and its resize
// (window_resize.md, the table of the window).
Rescale_Phase :: enum u8 {
	Steady, // The compositor shows or holds the surface of the window; the window draws it.
	Releasing, // The window asked the compositor to let its surface go, and draws nothing.
	Released, // The compositor holds no surface of the window; the window draws nothing and waits for a scale.
	Offered, // The window offered a surface of a new scale and draws it; no answer came yet.
	Resizing, // The window gave a surface of a new size and draws it; it keeps the surface before it until the answer.
}

// Rescale_Machine: the state of the rescale of a window.
Rescale_Machine :: struct {
	phase:  Rescale_Phase,
	scale:  scale_factor.Scale, // The scale of the surface of the window: the one that it draws, or that it offered.
	wanted: scale_factor.Scale, // The scale of the newest Presentation.
	serial: u64, // The surface serial of that surface.
	// In Released: the budget of the window did not pay its surface at
	// scale. A Scale_Named of that scale offers nothing: the budget would
	// fail the same way, and the compositor counts the window as declined.
	declined: bool,
}

// What the window does after a step.
Rescale_Action :: enum u8 {
	None,
	Release, // Send Surface_Release with the serial of the machine and the view of the window.
	Offer, // Let the old surface go, make a surface of the scale of the machine with its serial, and send Surface_Rescale.
}

// The inputs of the machine.
Rescale_Input_Kind :: enum u8 {
	Scale_Named, // A Presentation with its scale.
	Released, // The answer Released of a serial.
	Taken, // The answer Rescale_Taken of a serial.
	Refused, // The answer Rescale_Refused of a serial.
	Resize_Offered, // The window sent Surface_Resize with the next serial (surface_resize).
	Resize_Taken, // The answer Resize_Taken of a serial.
	Resize_Refused, // The answer Resize_Refused of a serial.
	Clamp_Asked, // A fixed window takes the clamp of the compositor: it releases its surface, then offers the surface of the clamped size.
}

Rescale_Input :: struct {
	kind:   Rescale_Input_Kind,
	scale:  scale_factor.Scale, // Scale_Named: the scale of the compositor.
	serial: u64, // The answers: the serial that they name.
	memory: system.Handle, // Taken and Resize_Taken: the copy of the surface that the compositor made, as this process names it.
}

// What the end of a resize does to the two surfaces that the window holds.
Resize_End :: enum u8 {
	None,
	Keep_New, // The compositor took the new surface: the window lets the one before it go.
	Back_To_Shown, // The compositor refused it: the window lets the new one go and draws the one before it again.
}

// rescale_step takes one input into the machine, and gives what the window
// does, and refused: the input was the refusal of the offered surface or of
// the surface of a resize, of which the window writes its fact. An answer
// of another serial than the one of the machine is the answer of an older
// request: it changes nothing. It reads and changes nothing else, so a host
// test drives each sequence.
rescale_step :: proc "contextless" (machine: ^Rescale_Machine, input: Rescale_Input) -> (action: Rescale_Action, refused: bool) {
	switch input.kind {
	case .Scale_Named:
		machine.wanted = input.scale
		switch machine.phase {
		case .Steady:
			if machine.wanted != machine.scale {
				machine.phase = .Releasing
				return .Release, false
			}
		case .Released:
			if machine.declined && machine.wanted == machine.scale {
				return .None, false
			}
			return rescale_offer(machine), false
		case .Releasing, .Offered, .Resizing:
			// The answer of the request comes first: one request at a time.
		}
	case .Clamp_Asked:
		// The view is the clamped size already: the offer after the release
		// makes the surface of it, at the scale wanted.
		if machine.phase == .Steady {
			machine.phase = .Releasing
			return .Release, false
		}
	case .Resize_Offered:
		if machine.phase == .Steady {
			machine.phase = .Resizing
			machine.serial += 1
		}
	case .Resize_Taken, .Resize_Refused:
		if machine.phase != .Resizing || input.serial != machine.serial {
			return .None, false
		}
		machine.phase = .Steady
		refused = input.kind == .Resize_Refused
		if refused {
			// The compositor shows the surface before the resize.
			machine.serial -= 1
		}
		if machine.wanted != machine.scale {
			machine.phase = .Releasing
			return .Release, refused
		}
		return .None, refused
	case .Released:
		if machine.phase == .Releasing && input.serial == machine.serial {
			return rescale_offer(machine), false
		}
	case .Taken:
		if machine.phase == .Offered && input.serial == machine.serial {
			machine.phase = .Steady
			if machine.wanted != machine.scale {
				machine.phase = .Releasing
				return .Release, false
			}
		}
	case .Refused:
		if machine.phase == .Offered && input.serial == machine.serial {
			machine.phase = .Released
			if machine.wanted != machine.scale {
				return rescale_offer(machine), true
			}
			return .None, true
		}
	}
	return .None, false
}

// rescale_offer moves the machine to the offer of a surface of the scale
// wanted, of the next serial.
@(private)
rescale_offer :: proc "contextless" (machine: ^Rescale_Machine) -> Rescale_Action {
	machine.phase = .Offered
	machine.scale = machine.wanted
	machine.serial += 1
	machine.declined = false
	return .Offer
}

// resize_end_of gives what the end of a resize does to the surfaces of the
// window, from the machine before an input and the input: only the answer
// of the serial of the resize in Resizing ends it.
resize_end_of :: proc "contextless" (before: Rescale_Machine, input: Rescale_Input) -> Resize_End {
	if before.phase != .Resizing || input.serial != before.serial {
		return .None
	}
	switch input.kind {
	case .Resize_Taken:
		return .Keep_New
	case .Resize_Refused:
		return .Back_To_Shown
	case .Scale_Named, .Released, .Taken, .Refused, .Resize_Offered, .Clamp_Asked:
	}
	return .None
}

// clamp_refused says if a fixed window declines a clamp of the compositor:
// a size of 0, or larger than the window opened with on an axis, is no
// clamp; and a window between two surfaces, or in a resize, has no surface
// to release, so it takes a clamp in Steady only. The compositor asks it
// again when the request ends.
clamp_refused :: proc "contextless" (machine: Rescale_Machine, width, height, opened_width, opened_height: int) -> bool {
	return width < 1 || height < 1 || width > opened_width || height > opened_height || machine.phase != .Steady
}

// clamp_take answers the clamp of a fixed window to the work area: the
// window takes the size as its view, with no choice of the process, and
// releases its surface; at Released it offers the surface of the view at
// the scale wanted, as a rescale (src/md/features/window_resize.md, "The
// clamp of a fixed window"). So it holds one surface at a time, which its
// budget pays. A clamp that clamp_refused refuses is declined.
@(private)
clamp_take :: proc "contextless" (window: ^Window, width, height: int) {
	if clamp_refused(window.rescale, width, height, window.opened_width, window.opened_height) {
		// A full ring keeps the request: the next present declines it.
		_ = resize_decline(window)
		return
	}
	// The release answers the request: no decline goes before it.
	window.resize_asked = false
	window.view_width, window.view_height = width, height
	window.resized_picture_due = true
	rescale_take(window, {kind = .Clamp_Asked})
}

// picture_owed_of says if a window owes the compositor a picture: it holds
// a surface that it may draw, and no Present named its serial yet. Until
// that Present, the compositor shows the frame of the window with the
// background, or the surface before a resize, and a change of the scale
// does not settle. A process that draws only when its own state changes
// draws while this holds (picture_owed).
picture_owed_of :: proc "contextless" (machine: Rescale_Machine, presented_serial: u64) -> bool {
	phase_machine := machine
	return rescale_draws(&phase_machine) && presented_serial != machine.serial
}

// picture_owed is picture_owed_of for a window: a process that draws on a
// change of its own state asks it at each turn, and draws when it holds.
picture_owed :: proc "contextless" (window: ^Window) -> bool {
	return picture_owed_of(window.rescale, window.presented_serial)
}

// rescale_draws says if the window draws in its phase: in Steady only. In
// Releasing and Released the compositor holds no surface that a Present of
// the window could name; in Offered and Resizing the window asked the
// compositor for a surface, and has none of it until the answer.
rescale_draws :: proc "contextless" (machine: ^Rescale_Machine) -> bool {
	return machine.phase == .Steady
}

// surface_answer_of_word is the border of the kind of a Surface_Answer: a
// word that names no member is refused.
surface_answer_of_word :: proc "contextless" (word: u64) -> (kind: Surface_Answer_Kind, ok: bool) {
	return enum_word.member_of_word(Surface_Answer_Kind, word)
}

// The budget of the window cannot pay its surface at the new scale: a
// process whose starter limited its budget, or a window grown past its
// stated size. The window declines the scale: it draws nothing, the
// compositor draws its frame with the background, and the window offers a
// surface again at the next scale that the compositor names. The desktop
// and the other windows go on.
@(log_fact = "display: {window}: its budget does not pay a surface of {width}x{height} at {scale} eighths, status {status}: the window declines the scale and shows its frame until another scale")
Surface_Not_Made :: struct {
	width:  u64,
	height: u64,
	scale:  u64,
	status: op.Status_Word,
	window: [40]u8,
}

// The compositor refused the offered surface: the window draws nothing
// until the next scale that the compositor names.
@(log_fact = "display: {window}: the holder of the display refused the surface {serial} at {scale} eighths; the window waits for the next scale")
Surface_Refused :: struct {
	serial: u64,
	scale:  u64,
	window: [40]u8,
}

// The compositor refused the surface of a resize: the window draws the
// surface before it again, which the compositor still shows.
@(log_fact = "display: {window}: the holder of the display refused the surface of {width}x{height}; the window keeps {kept_width}x{kept_height}")
Resize_Refused :: struct {
	width:       u64,
	height:      u64,
	kept_width:  u64,
	kept_height: u64,
	window:      [40]u8,
}

// The surface that a window asked the compositor to make, until the
// answer: its pixels of the screen, and for a resize the view and the
// layout that the window takes with it. The window draws nothing until
// then: the compositor shows the surface before it.
Asked_Surface :: struct {
	screen_width, screen_height: int,
	view_width, view_height:     int, // A resize: the logical size of the new surface.
	layout_width, layout_height: int, // A resize: the layout of the window with it.
}

// The compositor gave a surface that the window cannot map: a handle that
// is no gift through the ring of the window, no memory with Read and
// Write, or smaller than the surface that the window asked for. The
// window lets it go: it releases the serial, and offers a surface again.
@(log_fact = "display: {window}: the surface {serial} that the holder of the display gave does not map: the window releases it")
Surface_Not_Mapped :: struct {
	serial: u64,
	window: [40]u8,
}

// The compositor took the surface of the window at a new scale: from the
// next Present it shows it.
@(log_fact = "display: {window}: the surface of {width}x{height} at {scale} eighths")
Surface_Rescaled :: struct {
	width:  u64,
	height: u64,
	scale:  u64,
	window: [40]u8,
}

// scale_in_force gives the scale of the settings page, for the surface of
// a new window. With no page, or a page that read refuses, the default: the
// compositor names its own scale to a window whose surface has another,
// and the window rescales to it.
scale_in_force :: proc "contextless" () -> scale_factor.Scale {
	if settings_page == nil {
		return scale_factor.DEFAULT
	}
	choice, _ := settings.read(settings_page)
	return choice.scale
}

// surface_size_of gives the size in pixels of the screen of a surface of a
// logical size at a scale. The caller keeps the size inside SURFACE_LIMIT.
surface_size_of :: proc "contextless" (width, height: int, scale: scale_factor.Scale) -> (screen_width, screen_height: int) {
	return int(scale_factor.screen_pixel_of_logical_pixel(i32(width), scale)), int(scale_factor.screen_pixel_of_logical_pixel(i32(height), scale))
}

// rescale_take gives one input to the machine of a window and does what it
// asks. A record that the full command ring does not take waits as the due
// action, which rescale_due_run sends at the next read of the events.
@(private)
rescale_take :: proc "contextless" (window: ^Window, input: Rescale_Input) {
	offered := window.rescale
	resize_end := resize_end_of(offered, input)
	action, refused := rescale_step(&window.rescale, input)
	if refused && input.kind == .Refused {
		system.log_fact(.Warning, Surface_Refused{serial = input.serial, scale = u64(offered.scale), window = window_fact_title(window)})
	}
	asked := window.asked_surface
	// A Taken of another serial, or in another phase, answers an older
	// request: the copy of the surface that it names is closed.
	taken_now := resize_end == .Keep_New || input.kind == .Taken && offered.phase == .Offered && input.serial == offered.serial
	if !taken_now {
		surface_answer_close(window, input.memory)
	}
	switch resize_end {
	case .None:
	case .Keep_New:
		// The compositor made the surface of the new size: the window maps
		// it, lets the one before it go, and draws the new size.
		if surface_answer_map(window, input.memory, asked.screen_width, asked.screen_height) {
			window.view_width, window.view_height = asked.view_width, asked.view_height
			window.width, window.height = asked.layout_width, asked.layout_height
			window.resized_picture_due = true
		} else {
			action = surface_not_mapped(window, input.serial)
		}
	case .Back_To_Shown:
		// The compositor shows the surface before the resize, which the
		// window still holds and draws.
		system.log_fact(.Warning, Resize_Refused{width = u64(asked.view_width), height = u64(asked.view_height), kept_width = u64(window.view_width), kept_height = u64(window.view_height), window = window_fact_title(window)})
	}
	// The compositor made the offered surface: the window maps it and
	// presents it. The line that a reader of the log waits for after a
	// change of the scale.
	if input.kind == .Taken && offered.phase == .Offered && input.serial == offered.serial {
		if surface_answer_map(window, input.memory, asked.screen_width, asked.screen_height) {
			rescale_first_picture(window)
			system.log_fact(.Info, Surface_Rescaled{width = u64(window.canvas.width), height = u64(window.canvas.height), scale = u64(offered.scale), window = window_fact_title(window)})
		} else {
			action = surface_not_mapped(window, input.serial)
		}
	}
	// A due Release or Offer waits for no answer that could give a new
	// action, so a new action never takes the place of one. A due decline
	// has its own place (decline_due) and goes first.
	if action != .None {
		window.rescale_due = action
	}
	rescale_due_run(window)
}

// rescale_due_run sends the due decline, then the record of the due
// action, when the command ring has room. The decline goes first: the
// compositor takes the offer after it only with the serial after the
// declined one.
@(private)
rescale_due_run :: proc "contextless" (window: ^Window) {
	if window.decline_due {
		if ring.count(&window.ring.commands) == ring.capacity(&window.ring.commands) {
			return
		}
		if !system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Declined), values = {0 = window.decline_serial, 1 = u64(window.decline_scale)}}) {
			return
		}
		window.decline_due = false
	}
	if window.rescale_due == .None || ring.count(&window.ring.commands) == ring.capacity(&window.ring.commands) {
		return
	}
	switch window.rescale_due {
	case .None:
	case .Release:
		// A request of the principal that waits is answered first: the
		// compositor ends it at the release too.
		if window.resize_asked && !resize_decline(window) {
			return
		}
		// The view names the surface that the window offers next: the
		// compositor takes a clamp only when it is the asked size
		// (window_resize.md, "The clamp of a fixed window").
		if !system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Release), values = {0 = window.rescale.serial, 1 = u64(max(window.view_width, 0)), 2 = u64(max(window.view_height, 0))}}) {
			return
		}
	case .Offer:
		if !rescale_offer_send(window) {
			// The budget did not pay: rescale_decline made the decline due,
			// so the change of the scale settles even if the ring is full now.
			window.rescale_due = .None
			rescale_due_run(window)
			return
		}
	}
	window.rescale_due = .None
}

// rescale_offer_send lets the old surface go, which the compositor no
// longer maps, gives the compositor the budget of the surface of the
// logical size of the window at the scale of the machine, and sends
// Surface_Rescale; the answer Rescale_Taken names the surface that the
// compositor made. A budget of the process that cannot give that budget
// declines the scale (rescale_decline), and gives false.
@(private)
rescale_offer_send :: proc "contextless" (window: ^Window) -> (sent: bool) {
	if window.surface != 0 {
		system.memory_unmap(rawptr(window.pictures[0].pixels))
		system.close(window.surface)
		window.surface = 0
	}
	window.pictures, window.canvas = {}, {}
	scale := window.rescale.scale
	screen_width, screen_height := surface_size_of(window.view_width, window.view_height, scale)
	granted, status := surface_budget_give(window, screen_width, screen_height)
	if status != .Ok {
		system.log_fact(.Warning, Surface_Not_Made{width = u64(screen_width), height = u64(screen_height), scale = u64(scale), status = op.Status_Word(status), window = window_fact_title(window)})
		rescale_decline(window)
		return false
	}
	window.asked_surface = {screen_width = screen_width, screen_height = screen_height}
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Rescale), values = {0 = u64(granted), 1 = u64(screen_width), 2 = u64(screen_height), 3 = u64(scale), 4 = window.rescale.serial}})
	return true
}

// rescale_decline ends an offer that the budget could not pay: the machine
// goes to Released with the serial of the offer, so the next scale offers
// the serial after it, and the window holds no picture that a process
// could draw into. The decline is due with the serial and the scale of the
// offer: Surface_Declined tells the compositor, which counts the window as
// one that declined the scale in force. A full ring keeps it due until it
// has room, and a later offer waits behind it.
@(private)
rescale_decline :: proc "contextless" (window: ^Window) {
	rescale_declined_step(&window.rescale)
	window.decline_due, window.decline_serial, window.decline_scale = true, window.rescale.serial, window.rescale.scale
	window.pictures = {}
	window.canvas = {}
}

// rescale_declined_step moves a machine in Offered to Released, declined:
// the offer was never sent, and a Scale_Named of the same scale offers
// nothing. It changes nothing in another phase. A host test drives
// it with rescale_step.
rescale_declined_step :: proc "contextless" (machine: ^Rescale_Machine) {
	if machine.phase == .Offered {
		machine.phase = .Released
		machine.declined = true
	}
}

// rescale_first_picture presents the offered surface at once, filled with
// the background: the compositor takes the offer and shows this picture,
// in the order of the ring, so a change of the scale ends for each window
// whose process reads its events, also one that draws only when its own
// state changes, or never. The process draws its content after it; the
// picture stays owed to it (picture_owed), since this Present is no
// drawing of the process. A full ring skips it: the next Present of the
// process shows the surface.
@(private)
rescale_first_picture :: proc "contextless" (window: ^Window) {
	if ring.count(&window.ring.commands) == ring.capacity(&window.ring.commands) {
		return
	}
	graphics.fill(window.canvas, 0, 0, window.canvas.width, window.canvas.height, graphics.colors.background)
	drawn_serial := window.presented_serial
	_ = present_rectangle(window, 0, 0, 0, 0)
	window.presented_serial = drawn_serial
}

@(private)
window_fact_title :: proc "contextless" (window: ^Window) -> [WINDOW_FACT_TEXT_BYTES]u8 {
	return value_kinds.text_field(string(window.title[:window.title_count]), WINDOW_FACT_TEXT_BYTES)
}

// surface_budget_give makes a budget of the budget of this process that
// pays the surface of a size in pixels of the screen, and nothing more
// (surface_budget_pages), and gives the compositor a copy of it with
// Spend and Read through the ring of the window; it closes its own
// handle. The compositor makes the surface with it, so it never maps a
// memory object that this process made (window_resize.md, "The
// compositor makes each surface"). It gives the number of the copy.
@(private)
surface_budget_give :: proc "contextless" (window: ^Window, screen_width, screen_height: int, error: ^errors.Error_Record = nil) -> (granted: system.Handle, status: system.Status) {
	pages := surface_budget_pages(u64(max(screen_width, 0)), u64(max(screen_height, 0)))
	if pages == 0 {
		errors.fail(error, 0, .Out_Of_Range, .None, 2, i64(screen_width), i64(SURFACE_SCREEN_LIMIT), i64(screen_height))
		return 0, .Bad_Operation
	}
	budget: system.Handle
	budget, status = system.budget_create({pages = pages}, error = error)
	if status != .Ok {
		return 0, status
	}
	// The copy of the compositor holds the budget until it made the surface.
	defer system.close(budget)
	return system.give(window.ring_memory, budget, {.Spend, .Read}, error)
}

// surface_answer_map maps the surface that the compositor made, which an
// answer names: a gift through the ring of the window, a memory object
// with Read and Write that holds the two pictures of the size that the
// window asked for. It then makes it the surface of the window. A handle
// that fails is closed when it came through the ring; a number that did
// not is no handle of the window to close.
@(private)
surface_answer_map :: proc "contextless" (window: ^Window, memory: system.Handle, screen_width, screen_height: int) -> (mapped: bool) {
	if memory == 0 {
		return false
	}
	kind, rights, through := system.handle_state(memory, window.ring_memory)
	if !through {
		return false
	}
	defer if !mapped {
		system.close(memory)
	}
	needed := (u64(max(screen_width, 0) * max(screen_height, 0) * size_of(graphics.Color) * PICTURE_COUNT) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	if kind != .Memory || rights & {.Read, .Write} != {.Read, .Write} || needed == 0 {
		return false
	}
	if pages, size_status := system.memory_size(memory); size_status != .Ok || pages < needed {
		return false
	}
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		return false
	}
	surface_take(window, memory, address, screen_width, screen_height)
	return true
}

// surface_not_mapped answers a surface that the window cannot map: it
// writes one fact and releases the serial, so the compositor lets the
// surface go and the window offers a surface again at Released.
@(private)
surface_not_mapped :: proc "contextless" (window: ^Window, serial: u64) -> Rescale_Action {
	system.log_fact(.Warning, Surface_Not_Mapped{serial = serial, window = window_fact_title(window)})
	window.pictures, window.canvas = {}, {}
	window.rescale.phase = .Releasing
	return .Release
}

// surface_take makes a new surface the surface of the window: an old one
// that the window still maps is unmapped and closed (the compositor can
// still map it until the next Present), and the next frame draws the
// first picture, whole.
@(private)
surface_take :: proc "contextless" (window: ^Window, memory: system.Handle, address: rawptr, screen_width, screen_height: int) {
	if window.surface != 0 {
		system.memory_unmap(rawptr(window.pictures[0].pixels))
		system.close(window.surface)
	}
	window.surface = memory
	for &picture, index in window.pictures {
		picture = {pixels = ([^]graphics.Color)(address)[index * screen_width * screen_height:], width = screen_width, height = screen_height, stride = screen_width}
	}
	window.picture = 0
	window.canvas = window.pictures[0]
}
