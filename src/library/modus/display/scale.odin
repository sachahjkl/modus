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
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "modus:graphics"
import "modus:system"

// The largest width and height of a surface in pixels of the screen: a
// window of SURFACE_LIMIT logical pixels at the largest scale that the
// setting takes. The compositor refuses a larger surface.
SURFACE_SCREEN_LIMIT :: (SURFACE_LIMIT * int(scale_factor.WINDOW_BOUND) + scale_factor.EIGHTHS_OF_ONE / 2) / scale_factor.EIGHTHS_OF_ONE

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
	wanted: scale_factor.Scale, // The scale of the newest Settings_Changed.
	serial: u64, // The surface serial of that surface.
}

// What the window does after a step.
Rescale_Action :: enum u8 {
	None,
	Release, // Send Surface_Release with the serial of the machine.
	Offer, // Let the old surface go, make a surface of the scale of the machine with its serial, and send Surface_Rescale.
}

// The inputs of the machine.
Rescale_Input_Kind :: enum u8 {
	Scale_Named, // A Settings_Changed with its scale.
	Released, // The answer Released of a serial.
	Taken, // The answer Rescale_Taken of a serial.
	Refused, // The answer Rescale_Refused of a serial.
	Resize_Offered, // The window sent Surface_Resize with the next serial (surface_resize).
	Resize_Taken, // The answer Resize_Taken of a serial.
	Resize_Refused, // The answer Resize_Refused of a serial.
}

Rescale_Input :: struct {
	kind:   Rescale_Input_Kind,
	scale:  scale_factor.Scale, // Scale_Named: the scale of the compositor.
	serial: u64, // The answers: the serial that they name.
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
			return rescale_offer(machine), false
		case .Releasing, .Offered, .Resizing:
			// The answer of the request comes first: one request at a time.
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
	case .Scale_Named, .Released, .Taken, .Refused, .Resize_Offered:
	}
	return .None
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

// rescale_draws says if the window draws in its phase: in Steady, Offered
// and Resizing. In Releasing and Released the compositor holds no surface
// that a Present of the window could name.
rescale_draws :: proc "contextless" (machine: ^Rescale_Machine) -> bool {
	return machine.phase == .Steady || machine.phase == .Offered || machine.phase == .Resizing
}

// surface_answer_of_word is the border of the kind of a Surface_Answer: a
// word that names no member is refused.
surface_answer_of_word :: proc "contextless" (word: u64) -> (kind: Surface_Answer_Kind, ok: bool) {
	return enum_word.member_of_word(Surface_Answer_Kind, word)
}

// The window could not make its surface at the new scale: a fault of the
// system, as its budget counts its pictures at the window bound. The
// process stops, and the compositor closes its window.
@(log_fact = "display: {window}: no surface of {width}x{height} at {scale} eighths, status {status}: the window stops")
Surface_Not_Made :: struct {
	width:  u64,
	height: u64,
	scale:  u64,
	status: op.Status_Word,
	window: [40]u8,
}

// The compositor refused the offered surface: the window draws nothing
// until the next scale that the compositor names.
@(log_fact = "display: {window}: the compositor refused the surface {serial} at {scale} eighths; the window waits for the next scale")
Surface_Refused :: struct {
	serial: u64,
	scale:  u64,
	window: [40]u8,
}

// The compositor refused the surface of a resize: the window draws the
// surface before it again, which the compositor still shows.
@(log_fact = "display: {window}: the compositor refused the surface of {width}x{height}; the window keeps {kept_width}x{kept_height}")
Resize_Refused :: struct {
	width:       u64,
	height:      u64,
	kept_width:  u64,
	kept_height: u64,
	window:      [40]u8,
}

// The surface that a window keeps during a resize, until the answer of the
// compositor: the compositor shows it until the first Present of the new
// one, and shows it again when it refuses the new one.
Kept_Surface :: struct {
	memory:        system.Handle, // 0: no surface is kept.
	pictures:      [PICTURE_COUNT]graphics.Canvas,
	width, height: int, // The logical size of the window with it.
}

// kept_surface_close lets a kept surface go.
@(private)
kept_surface_close :: proc "contextless" (kept: ^Kept_Surface) {
	if kept.memory != 0 {
		system.memory_unmap(rawptr(kept.pictures[0].pixels))
		system.close(kept.memory)
	}
	kept^ = {}
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
	switch resize_end {
	case .None:
	case .Keep_New:
		kept_surface_close(&window.before_resize)
	case .Back_To_Shown:
		// The compositor shows the surface before the resize: the window
		// draws it again, at its size, and the new one goes.
		refused_width, refused_height := window.width, window.height
		if window.surface != 0 {
			system.memory_unmap(rawptr(window.pictures[0].pixels))
			system.close(window.surface)
		}
		kept := window.before_resize
		window.before_resize = {}
		window.surface, window.pictures = kept.memory, kept.pictures
		window.width, window.height = kept.width, kept.height
		window.picture = 0
		window.canvas = window.pictures[0]
		window.resized_picture_due = true
		system.log_fact(.Warning, Resize_Refused{width = u64(refused_width), height = u64(refused_height), kept_width = u64(kept.width), kept_height = u64(kept.height), window = window_fact_title(window)})
	}
	// The compositor holds the offered surface: the line that a reader of
	// the log waits for after a change of the scale.
	if input.kind == .Taken && offered.phase == .Offered && input.serial == offered.serial {
		system.log_fact(.Info, Surface_Rescaled{width = u64(window.canvas.width), height = u64(window.canvas.height), scale = u64(offered.scale), window = window_fact_title(window)})
	}
	if action != .None {
		window.rescale_due = action
	}
	rescale_due_run(window)
}

// rescale_due_run sends the record of the due action, when the command
// ring has room.
@(private)
rescale_due_run :: proc "contextless" (window: ^Window) {
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
		if !system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Release), values = {0 = window.rescale.serial}}) {
			return
		}
	case .Offer:
		rescale_offer_send(window)
	}
	window.rescale_due = .None
}

// rescale_offer_send lets the old surface go, which the compositor no
// longer maps, makes the surface of the logical size of the window at the
// scale of the machine, from the budget of the window, gives it to the
// compositor with Read and sends Surface_Rescale. A surface that the budget
// cannot pay is a fault: the process writes its fact and stops.
@(private)
rescale_offer_send :: proc "contextless" (window: ^Window) {
	if window.surface != 0 {
		system.memory_unmap(rawptr(window.pictures[0].pixels))
		system.close(window.surface)
		window.surface = 0
	}
	scale := window.rescale.scale
	screen_width, screen_height := surface_size_of(window.width, window.height, scale)
	memory, address, granted, status := surface_make(window, screen_width, screen_height)
	if status != .Ok {
		system.log_fact(.Error, Surface_Not_Made{width = u64(screen_width), height = u64(screen_height), scale = u64(scale), status = op.Status_Word(status), window = window_fact_title(window)})
		system.stop(.Failed)
	}
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Surface_Rescale), values = {0 = u64(granted), 1 = u64(screen_width), 2 = u64(screen_height), 3 = u64(scale), 4 = window.rescale.serial}})
	surface_take(window, memory, address, screen_width, screen_height)
	rescale_first_picture(window)
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

// surface_make creates the memory of a surface of two pictures of a size in
// pixels of the screen, maps it and gives it to the compositor with Read.
// On a status other than Ok it holds nothing: each handle that it made is
// closed again.
@(private)
surface_make :: proc "contextless" (window: ^Window, screen_width, screen_height: int) -> (memory: system.Handle, address: rawptr, granted: system.Handle, status: system.Status) {
	pages := (u64(screen_width * screen_height * size_of(graphics.Color) * PICTURE_COUNT) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory, status = system.memory_create(pages)
	if status != .Ok {
		return
	}
	address, status = system.memory_map(memory)
	if status != .Ok {
		system.close(memory)
		return
	}
	granted, status = system.give(window.ring_memory, memory, {.Read})
	if status != .Ok {
		system.memory_unmap(address)
		system.close(memory)
	}
	return
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
