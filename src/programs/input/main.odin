// The input service: the device service of the PS/2 keyboard and mouse
// (docs/ARCHITECTURE.md, U4). It has the ports of the controller and its two
// interrupts, and nothing else. It sends input records to the compositor.
//
// **What it is for.** It shows that a driver is a program, not a part of
// the kernel. This program is a [device service](term:device-service): the
// root service gives it the five I/O ports of the PS/2 controller (0x60 to 0x64) and its two interrupts (1, the keyboard; 12,
// the mouse). The kernel turns each interrupt into an event of the
// program; it never reads a key itself.
//
// **What a reader sees.** No window: the line `input: ok, the mouse has a
// wheel` (or `no wheel`, for a mouse with no wheel) on the log, once the
// controller is set up. Each key, each move of
// the mouse and each turn of its wheel then reaches the compositor as one
// record of its input ring, and the compositor sends a key to the window
// in front.
//
// **The records** that it writes (`display.Input`):
//
// - `Key`: the scan code (with `display.KEY_EXTENDED` after the prefix
//   0xE0), the character in the layout of the settings, 1 for a press or 0
//   for a release, and the modifiers (Shift, Control).
// - `Pointer`: the motion in x and in y, in pixels of the mouse (y grows
//   down, as on the screen), the three buttons, and the notches of the
//   wheel (`display.WHEEL_TOWARD_THE_END` for each notch toward the
//   principal).
//
// **The wheel.** A PS/2 mouse sends packets of 3 bytes and no wheel until
// it is asked for the IntelliMouse protocol: the sample rates 200, 100 and
// 80 in this order, then its identity (key_path.Mouse_Protocol). A mouse
// that answers MOUSE_IDENTITY_WHEEL sends packets of 4 bytes; the fourth
// byte is the notches, signed. A mouse that answers
// MOUSE_IDENTITY_WHEEL_AND_BUTTONS was left in the Explorer protocol by
// its firmware, which the default settings do not always leave: it sends
// packets of 4 bytes too, with the notches in the low 4 bits. The service
// reads both, with no reset of the mouse: a reset waits for a self test of
// the mouse, and the decoder needs only the identity. A mouse that answers
// another identity keeps packets of 3 bytes, and the system has no wheel.
//
// **How it starts.** The root service starts it at each boot, before the
// compositor, with a context of its own: handle 0 is the input ring, which
// it shares with the compositor; handles 1 to 3 are the ports and the two
// interrupts. It has no grant of `grants_of`, no connection, and no
// service: it cannot reach another program.
//
// **What it does not prove.** It works with the PS/2 controller that QEMU
// emulates, with two keyboard layouts. It has no USB, and no character
// outside ASCII.
package input

import "modus:support/display"
import "modus:support/key_path"
import "modus:contract/fixed_addresses"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:support/system"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module and its thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 181, programs = 1, threads = 1}

// The context of this service.
GRANT_RING :: 0
GRANT_PORTS :: 1
GRANT_KEYBOARD_INTERRUPT :: 2
GRANT_MOUSE_INTERRUPT :: 3

PORT_DATA :: 0x60
PORT_STATUS :: 0x64
STATUS_OUTPUT_FULL :: 1 << 0
STATUS_INPUT_FULL :: 1 << 1
STATUS_MOUSE :: 1 << 5

// Scan code set 1, United States layout: the character of each key, without
// and with shift.
@(rodata)
characters := [2][0x3A]u8 {
	{0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8, '\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' '},
	{0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8, '\t', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0, 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' '},
}

// Scan code set 1, layout of France (AZERTY): the character of each key,
// without and with shift. A character of the system is one byte of ASCII:
// a key whose character is outside ASCII (é, è, ç, à, ù, ², °, ¨, £, µ, §)
// gives no character, and a program still gets its key code.
@(rodata)
characters_french := [2][0x3A]u8 {
	{0, 0, '&', 0, '"', '\'', '(', '-', 0, '_', 0, 0, ')', '=', 8, '\t', 'a', 'z', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '^', '$', '\n', 0, 'q', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm', 0, 0, 0, '*', 'w', 'x', 'c', 'v', 'b', 'n', ',', ';', ':', '!', 0, '*', 0, ' '},
	{0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 0, '+', 8, '\t', 'A', 'Z', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 0, 0, '\n', 0, 'Q', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'M', '%', 0, 0, 0, 'W', 'X', 'C', 'V', 'B', 'N', '?', '.', '/', 0, 0, '*', 0, ' '},
}

// The settings page, when the root service mapped it: the layout of the
// keyboard is read there at each key, so a change of the setting holds from
// the next key. nil: the layout of the United States.
settings_page: ^settings.Page

// layout_now gives the table of the layout that the settings name now.
layout_now :: proc "contextless" () -> ^[2][0x3A]u8 {
	if settings_page == nil {
		return &characters
	}
	switch settings.Keyboard_Layout(settings.read(settings_page).values[.Keyboard_Layout]) {
	case .United_States:
	case .French:
		return &characters_french
	}
	return &characters
}

SCAN_LEFT_SHIFT :: 0x2A
SCAN_RIGHT_SHIFT :: 0x36
SCAN_CONTROL :: 0x1D
SCAN_EXTENDED :: 0xE0

// The commands of the mouse. The identities that it answers are in
// key_path (MOUSE_IDENTITY_WHEEL, MOUSE_IDENTITY_WHEEL_AND_BUTTONS).
MOUSE_SET_SAMPLE_RATE :: 0xF3
MOUSE_GET_IDENTITY :: 0xF2
MOUSE_SET_DEFAULTS :: 0xF6
MOUSE_ENABLE_REPORTING :: 0xF4
// The sample rates that ask a mouse for the IntelliMouse protocol: a mouse
// with a wheel knows this order and answers MOUSE_IDENTITY_WHEEL after it.
@(rodata)
mouse_wheel_rates := [3]u8{200, 100, 80}
// The reads of the status port before a wait for the controller ends: a
// bound on a device that does not answer, not a time.
CONTROLLER_POLLS :: 100000

output: ring.Ring
output_memory: system.Handle
modifiers: u32
extended: bool
// The packets of the mouse, in the protocol that its identity gave.
mouse_decoder: key_path.Mouse_Decoder
// The bytes of the keyboard that came while the service waited for an
// answer of the mouse at its start: a key pressed during the start. They
// are dropped, and their count is on the log.
keyboard_bytes_dropped_at_start: u64
// The packets of the mouse that found the input ring full: they go to the
// ring, in order, before any newer record.
pointer_backlog: key_path.Pointer_Backlog
// The records that this service lost. The back pressure of entry keeps
// both at 0: a number above 0 is a fault of this program.
key_records_refused: u64
pointer_records_refused: u64

controller_wait_write :: proc "contextless" () {
	for _ in 0 ..< CONTROLLER_POLLS {
		if system.port_read_8(PORT_STATUS) & STATUS_INPUT_FULL == 0 {
			return
		}
	}
}

controller_read :: proc "contextless" () -> u8 {
	for _ in 0 ..< CONTROLLER_POLLS {
		if system.port_read_8(PORT_STATUS) & STATUS_OUTPUT_FULL != 0 {
			break
		}
	}
	return system.port_read_8(PORT_DATA)
}

controller_command :: proc "contextless" (command: u8) {
	controller_wait_write()
	system.port_write_8(PORT_STATUS, command)
}

controller_data :: proc "contextless" (value: u8) {
	controller_wait_write()
	system.port_write_8(PORT_DATA, value)
}

// mouse_answer_read reads the next byte of the mouse. A byte of the
// keyboard that comes before it is dropped and counted: else a key pressed
// at the start is read as the answer of the mouse, and the answer stays in
// the controller. ok is false when the mouse did not answer.
mouse_answer_read :: proc "contextless" () -> (value: u8, ok: bool) {
	for _ in 0 ..< CONTROLLER_POLLS {
		state := system.port_read_8(PORT_STATUS)
		if state & STATUS_OUTPUT_FULL == 0 {
			continue
		}
		byte_read := system.port_read_8(PORT_DATA)
		if state & STATUS_MOUSE != 0 {
			return byte_read, true
		}
		keyboard_bytes_dropped_at_start += 1
	}
	return 0, false
}

mouse_command :: proc "contextless" (command: u8) {
	controller_command(0xD4) // The next data byte goes to the mouse.
	controller_data(command)
	mouse_answer_read() // The mouse answers 0xFA.
}

// entry sets up the PS/2 controller and then turns each byte of the
// controller into a record of the input ring, until the machine stops.
//
// **What it sets up**: it opens the input ring (handle 0), drops the bytes
// that wait in the controller, enables the mouse port, turns on both
// interrupts and the clock of the mouse, gives the mouse its default
// settings, asks it for the wheel, and asks it to send its moves. It then
// writes `input: ok, the mouse has a wheel` (or `no wheel`).
//
// **The loop.** It waits for an interrupt. It then reads each byte while
// the status port says that one waits: a byte of the mouse goes to
// `mouse_byte`, a byte of the keyboard to `keyboard_byte`.
//
// **A full input ring.** The service never drops a record. It does not
// take a byte of the keyboard from the controller while the input ring has
// no room for its record: the byte stays in the controller, the keyboard
// holds the bytes after it, and the service waits until the compositor
// read half of the ring (docs/ARCHITECTURE.md, "The path of a key"). The
// moves of the mouse that find the ring full become one move; a change of
// a button waits in order, and when 8 of them wait the bytes of the mouse
// stay in the controller too. The log has
// `input: the input ring is full: the keyboard controller keeps its bytes`
// when a wait begins, and `input: the input ring has room again` when it
// ends.
//
// **The stop**: with no ring, it writes `input: no ring` and stops with the
// code 1. Else it never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	output_memory = ctx.handles[GRANT_RING]
	status: system.Status
	if output, status = system.ring_open(output_memory); status != .Ok {
		system.log("input: no ring")
		system.stop(1)
	}

	// The settings page, when the root service mapped it for this service.
	if .Settings_Page in fixed_addresses.ranges_mapped(&ctx.values) {
		settings_page = (^settings.Page)(uintptr(settings.PAGE_ADDRESS))
	}

	for system.port_read_8(PORT_STATUS) & STATUS_OUTPUT_FULL != 0 {
		system.port_read_8(PORT_DATA)
	}
	controller_command(0xA8) // Enable the mouse port.
	controller_command(0x20) // Read the configuration.
	configuration := controller_read()
	configuration |= 0x03 // Both interrupts on.
	configuration &~= 0x20 // The mouse clock on.
	controller_command(0x60)
	controller_data(configuration)
	mouse_command(MOUSE_SET_DEFAULTS)
	for rate in mouse_wheel_rates {
		mouse_command(MOUSE_SET_SAMPLE_RATE)
		mouse_command(rate)
	}
	mouse_command(MOUSE_GET_IDENTITY)
	if identity, answered := mouse_answer_read(); answered {
		mouse_decoder.protocol = key_path.mouse_protocol_of_identity(identity)
	}
	mouse_command(MOUSE_ENABLE_REPORTING)
	if keyboard_bytes_dropped_at_start > 0 {
		system.log("input: ", keyboard_bytes_dropped_at_start, " bytes of the keyboard came during the start of the mouse and are lost")
	}
	system.log("input: ok, the mouse has ", mouse_decoder.protocol == .Standard ? "no wheel" : "a wheel")

	held_before := false // The turn before left a byte in the controller.
	for {
		// An interrupt of this program is an event.
		wait := system.wait_begin()
		held := false
		for {
			pointer_backlog_send()
			state := system.port_read_8(PORT_STATUS)
			if state & STATUS_OUTPUT_FULL == 0 {
				break
			}
			from_mouse := state & STATUS_MOUSE != 0
			has_room := ring.count(&output.commands) < ring.capacity(&output.commands)
			if !key_path.input_byte_can_be_read(from_mouse, has_room, pointer_backlog.count) {
				// No place for the record of this byte: the byte stays in
				// the controller, and the device holds the ones after it.
				held = true
				break
			}
			value := system.port_read_8(PORT_DATA)
			if from_mouse {
				mouse_byte(value)
			} else {
				keyboard_byte(value)
			}
		}
		if held != held_before {
			held_before = held
			if held {
				system.log("input: the input ring is full: the keyboard controller keeps its bytes")
			} else {
				system.log("input: the input ring has room again")
			}
		}
		if held || pointer_backlog.count > 0 {
			// The compositor wakes this thread when half of the ring is
			// free, or before it waits itself. If the ring already has
			// room, the wait ends at once.
			system.wait_room(&wait, &output.commands)
		}
		system.wait_end(&wait)
	}
}

// pointer_backlog_send writes in the input ring the packets of the mouse
// that wait, the oldest first, while the ring has room.
pointer_backlog_send :: proc "contextless" () {
	for {
		waiting := key_path.pointer_backlog_first(&pointer_backlog) or_break
		if !system.send(&output.commands, pointer_record(waiting)) {
			break
		}
		key_path.pointer_backlog_remove_first(&pointer_backlog)
	}
}

pointer_record :: proc "contextless" (pointer: key_path.Pointer_Packet) -> ring.Record {
	return {kind = u32(display.Input.Pointer), values = {0 = u64(pointer.motion_x), 1 = u64(pointer.motion_y), 2 = pointer.buttons, 3 = u64(pointer.wheel)}}
}

// keyboard_byte turns one byte of the keyboard into a record `Key`. The
// prefix 0xE0 marks the next byte as an extended key; Shift and Control
// change the modifiers; bit 7 is the release.
keyboard_byte :: proc "contextless" (value: u8) {
	if value == SCAN_EXTENDED {
		extended = true
		return
	}
	pressed := value & 0x80 == 0
	scan := value & 0x7F
	code := u32(scan)
	if extended {
		code |= display.KEY_EXTENDED
		extended = false
	}
	bit: u32
	switch code {
	case SCAN_LEFT_SHIFT, SCAN_RIGHT_SHIFT:
		bit = display.MODIFIER_SHIFT
	case SCAN_CONTROL, SCAN_CONTROL | display.KEY_EXTENDED:
		bit = display.MODIFIER_CONTROL
	}
	if bit != 0 {
		if pressed {
			modifiers |= bit
		} else {
			modifiers &~= bit
		}
	}
	character: u8
	if code < len(characters[0]) {
		character = layout_now()[modifiers & display.MODIFIER_SHIFT][code]
	}
	// The loop of entry read this byte only when the ring had room, and
	// this thread is the one writer of the ring: the record has a place.
	if !system.send(&output.commands, ring.Record{kind = u32(display.Input.Key), values = {0 = u64(code), 1 = u64(character), 2 = u64(pressed), 3 = u64(modifiers)}}) {
		key_records_refused += 1
		system.log("input: the input ring refused a key record that had a place: ", key_records_refused, " key records are lost")
	}
}

// mouse_byte gives one byte of the mouse to the decoder of its packets
// (key_path.mouse_decoder_byte: the start of a packet, the check of the
// fourth byte, the overflow), and sends a record `Pointer` when a packet
// is whole.
mouse_byte :: proc "contextless" (value: u8) {
	moved, whole := key_path.mouse_decoder_byte(&mouse_decoder, value)
	if !whole {
		return
	}
	// The decoder counts the notches toward the principal.
	moved.wheel *= display.WHEEL_TOWARD_THE_END
	// A packet that waits goes first. With none, the ring takes this one,
	// or it is the first one that waits.
	if pointer_backlog.count == 0 && system.send(&output.commands, pointer_record(moved)) {
		return
	}
	if !key_path.pointer_backlog_add(&pointer_backlog, moved) {
		// The loop of entry reads a byte of the mouse only while an entry
		// is free: this is a fault of this program, and it is in the log.
		pointer_records_refused += 1
		system.log("input: no entry for a change of a button of the pointer: ", pointer_records_refused, " pointer records are lost")
	}
}
