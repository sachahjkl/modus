// The input service: the device service of the PS/2 keyboard and mouse
// (docs/ARCHITECTURE.md, U4). It has the ports of the controller and its two
// interrupts, and nothing else. It sends input records to the compositor.
//
// **What it is for.** It shows that a driver is a process, not a part of
// the kernel. This process is a [device service](term:device-service): the
// root service gives it the five I/O ports of the PS/2 controller (0x60 to 0x64) and its two interrupts (1, the keyboard; 12,
// the mouse). The kernel turns each interrupt into an event of the
// process; it never reads a key itself.
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
//   0xE0), the character in the layout of the settings as a code point, 1
//   for a press or 0 for a release, and the modifiers (Shift, Control).
//   After a dead key of the layout of France, one press can give two
//   records: the accent alone, then the character of the key.
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
// interrupts. Its row of `start_grant_sets` has the grant System_Part only:
// no connection, and no service, so it cannot reach another process. The
// root service names these slots INPUT_GRANT_ too.
//
// **What it does not prove.** It works with the PS/2 controller that QEMU
// emulates, with two keyboard layouts (src/library/private/input/keyboard_layout);
// AltGr, the right Alt key, gives the third level of the layout of France.
// It has no USB.
package input

import "modus:support/display"
import "modus:support/key_path"
import "modus:private/input/keyboard_layout"
import "modus:private/input/ps2_controller"
import "modus:contract/fixed_addresses"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:support/system"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module and its thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 181, processes = 1, threads = 1}

// The context of this service.
GRANT_RING :: 0
GRANT_PORTS :: 1
GRANT_KEYBOARD_INTERRUPT :: 2
GRANT_MOUSE_INTERRUPT :: 3

PORT_DATA :: 0x60
PORT_STATUS :: 0x64 // Its bits are in src/library/private/input/ps2_controller.

// The settings page, when the root service mapped it: the layout of the
// keyboard is read there at each key, so a change of the setting holds from
// the next key. nil: the layout of the United States.
settings_page: ^settings.Page

// The accent of a dead key that waits for the next key.
dead_key: keyboard_layout.Dead_Key_State

// layout_now gives the layout that the settings name now. A refused page
// gives the defaults: the layout of the United States, as with no page.
layout_now :: proc "contextless" () -> settings.Keyboard_Layout {
	if settings_page == nil {
		return .United_States
	}
	choice, _ := settings.read(settings_page)
	return choice.keyboard_layout
}

SCAN_LEFT_SHIFT :: 0x2A
SCAN_RIGHT_SHIFT :: 0x36
SCAN_CONTROL :: 0x1D
SCAN_ALT :: 0x38 // The left Alt key; after the prefix 0xE0, the right Alt key: AltGr.
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

output: ring.Ring
output_memory: system.Handle
modifiers: u32
// AltGr is down. It is not a bit of the modifiers of a key record: the
// character of the record already holds the third level that it gives.
alt_graph_held: bool
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
// both at 0: a number above 0 is a fault of this process.
key_records_refused: u64
pointer_records_refused: u64

controller_wait_write :: proc "contextless" () {
	for _ in 0 ..< ps2_controller.CONTROLLER_POLLS {
		if system.port_read_8(PORT_STATUS) & ps2_controller.STATUS_INPUT_FULL == 0 {
			return
		}
	}
}

controller_read :: proc "contextless" () -> u8 {
	for _ in 0 ..< ps2_controller.CONTROLLER_POLLS {
		if system.port_read_8(PORT_STATUS) & ps2_controller.STATUS_OUTPUT_FULL != 0 {
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
	for _ in 0 ..< ps2_controller.CONTROLLER_POLLS {
		state := system.port_read_8(PORT_STATUS)
		if state & ps2_controller.STATUS_OUTPUT_FULL == 0 {
			continue
		}
		byte_read := system.port_read_8(PORT_DATA)
		if state & ps2_controller.STATUS_MOUSE != 0 {
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
// **The stop**: with no ring, it writes `input: no ring` and stops with
// `Failed`. With no PS/2 controller (a status port that reads all ones, or a
// drain that does not end), it writes `input: no PS/2 controller: no
// keyboard and no mouse` and stops with `Failed`; the compositor runs
// with no input. Else it never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	output_memory = ctx.handles[GRANT_RING]
	status: system.Status
	if output, status = system.ring_open(output_memory); status != .Ok {
		system.log_fact(.Info, No_Ring{})
		system.stop(.Failed)
	}

	// The settings page, when the root service mapped it for this service.
	if .Settings_Page in fixed_addresses.ranges_mapped(&ctx.values) {
		settings_page = (^settings.Page)(uintptr(settings.PAGE_ADDRESS))
	}

	// The drain of the bytes that wait finds a controller that is absent:
	// its status port reads all ones, so a byte would seem to wait for
	// ever, and this loop would hold one processor for ever.
	bytes_drained: u64
	drain: for {
		switch ps2_controller.drain_step(system.port_read_8(PORT_STATUS), bytes_drained) {
		case .Done:
			break drain
		case .Read_Byte:
			system.port_read_8(PORT_DATA)
			bytes_drained += 1
		case .No_Controller:
			system.log_fact(.Info, No_Controller{})
			system.stop(.Failed)
		}
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
		system.log_fact(.Info, Keyboard_Bytes_Lost_At_Start{keyboard_bytes = keyboard_bytes_dropped_at_start})
	}
	if mouse_decoder.protocol == .Standard {
		system.log_fact(.Info, Ready_Mouse_Without_Wheel{})
	} else {
		system.log_fact(.Info, Ready_Mouse_With_Wheel{})
	}

	held_before := false // The turn before left a byte in the controller.
	for {
		// An interrupt of this process is an event.
		wait := system.wait_begin()
		held := false
		for {
			pointer_backlog_send()
			state := system.port_read_8(PORT_STATUS)
			if state & ps2_controller.STATUS_OUTPUT_FULL == 0 {
				break
			}
			from_mouse := state & ps2_controller.STATUS_MOUSE != 0
			// A byte of the keyboard needs room for two records while an
			// accent waits: the accent alone and the character.
			records_needed := from_mouse ? 1 : keyboard_layout.key_records_needed(&dead_key)
			has_room := int(ring.count(&output.commands)) + records_needed <= int(ring.capacity(&output.commands))
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
				system.log_fact(.Info, Input_Ring_Full{})
			} else {
				system.log_fact(.Info, Input_Ring_Room_Again{})
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
// change the modifiers, and AltGr the level of the layout; bit 7 is the
// release.
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
	// Only the right Alt key is AltGr: the left Alt key changes no
	// character.
	alt_graph_key := code == (SCAN_ALT | display.KEY_EXTENDED)
	if alt_graph_key {
		alt_graph_held = pressed
	}
	layout := layout_now()
	held: keyboard_layout.Level_Keys
	if modifiers & display.MODIFIER_SHIFT != 0 {
		held += {.Shift}
	}
	if alt_graph_held {
		held += {.Alt_Graph}
	}
	accent_alone, character: rune
	if pressed {
		accent_alone, character = keyboard_layout.key_press(&dead_key, layout, held, code, bit != 0 || alt_graph_key)
	} else {
		character = keyboard_layout.key_character(layout, held, code)
	}
	if accent_alone != 0 {
		key_record_send(code, accent_alone, true)
	}
	key_record_send(code, character, pressed)
}

// key_record_send writes one record `Key`. The loop of entry read the byte
// of the key only when the ring had room for each record of the byte, and
// this thread is the one writer of the ring: the record has a place. The
// record holds the time of the system at the read of the byte, the start
// of the measure of a key to the screen
// (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
key_record_send :: proc "contextless" (code: u32, character: rune, pressed: bool) {
	if !system.send(&output.commands, ring.Record{kind = u32(display.Input.Key), values = {0 = u64(code), 1 = u64(character), 2 = u64(pressed), 3 = u64(modifiers), display.INPUT_KEY_READ_AT = system.nanoseconds()}}) {
		key_records_refused += 1
		system.log_fact(.Info, Key_Records_Lost{key_records = key_records_refused})
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
		// is free: this is a fault of this process, and it is in the log.
		pointer_records_refused += 1
		system.log_fact(.Info, Pointer_Records_Lost{pointer_records = pointer_records_refused})
	}
}
