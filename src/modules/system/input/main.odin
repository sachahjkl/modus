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
// emulates, with two keyboard layouts (src/library/internal/input/keyboard_layout);
// AltGr, the right Alt key, gives the third level of the layout of France.
// It has no USB.
package input

import "base:intrinsics"
import "modus:display"
import "modus:key_path"
import "modus:pci"
import "modus:virtio"
import "internal:input/keyboard_layout"
import "internal:input/ps2_controller"
import "internal:input/tablet"
import "modus:contract/fixed_addresses"
import "modus:contract/input_context"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:contract/virtio_input"
import "modus:system"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module and its thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 181, processes = 1, threads = 1}

// The context of this service is the layout of modus:contract/input_context,
// which the root service writes. modus:virtio reads the BARs of the tablet
// at the slots of package pci: the contract puts them there.
#assert(input_context.GRANT_TABLET_CONFIGURATION == pci.GRANT_CONFIGURATION && input_context.GRANT_TABLET_FIRST_BAR == pci.GRANT_BAR)

// Virtio tablet event buffers in page virtio.QUEUE_PAGES of the queue memory.
TABLET_BUFFER_PAGE :: virtio.QUEUE_PAGES
TABLET_EVENT_BUFFER_COUNT :: 64
TABLET_COORDINATE_EXTENT :: u32(virtio_input.ABSOLUTE_AXIS_DEFAULT_MAXIMUM) + 1
#assert(TABLET_BUFFER_PAGE < pci.QUEUE_PAGES)
#assert(TABLET_EVENT_BUFFER_COUNT * virtio_input.EVENT_SIZE <= system.PAGE_SIZE)

PORT_DATA :: 0x60
PORT_STATUS :: 0x64 // Its bits are in src/library/internal/input/ps2_controller.

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
// The optional virtio-tablet-pci device state, active when granted in ctx.
tablet_active: bool
tablet_device: virtio.Device
tablet_queue: virtio.Queue
tablet_buffers: [^]virtio_input.Raw_Event
tablet_buffers_physical: u64
tablet_buffer_count: u32
tablet_state: tablet.Tablet_State
tablet_backlog: tablet.Tablet_Backlog
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
	output_memory = ctx.handles[input_context.GRANT_RING]
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
	// A machine with no controller and a tablet still has a pointer: the
	// service goes on with the tablet alone.
	controller_present := true
	bytes_drained: u64
	drain: for {
		switch ps2_controller.drain_step(system.port_read_8(PORT_STATUS), bytes_drained) {
		case .Done:
			break drain
		case .Read_Byte:
			system.port_read_8(PORT_DATA)
			bytes_drained += 1
		case .No_Controller:
			controller_present = false
			break drain
		}
	}
	if controller_present {
		controller_start()
	}
	tablet_device_open(ctx)
	if !controller_present {
		if !tablet_active {
			// No controller and no tablet: the stop is a refusal, which no
			// start policy restarts, since neither comes back.
			system.log_fact(.Info, No_Controller{})
			system.stop(.Refused)
		}
		system.log_fact(.Info, No_Controller_Tablet_Only{})
	}

	held_before := false // The turn before left a byte in the controller.
	for {
		// An interrupt of this process is an event.
		wait := system.wait_begin()
		held := false
		room_needed: u32 = 1 // The records that the next record or byte needs: a byte of the keyboard with an accent waiting needs two.
		for {
			pointer_backlog_send()
			tablet_backlog_send()
			tablet_poll()
			// An absent controller reads all ones: no byte waits there.
			if !controller_present {
				break
			}
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
				room_needed = u32(records_needed)
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
		if tablet_active && virtio.used_ready(&tablet_queue) && tablet_backlog.count < tablet.TABLET_BACKLOG_CAPACITY {
			continue
		}
		if held || pointer_backlog.count > 0 || tablet_backlog.count > 0 {
			// The compositor wakes this thread when half of the ring is
			// free, or before it waits itself. If the ring already has
			// room for what waits, the wait ends at once. A byte that
			// needs two records and finds one place waits for a read of
			// the compositor: with wait_room, it found the ring not full
			// and turned with no wait until the compositor read.
			system.wait_room_for(&wait, &output.commands, room_needed)
		}
		system.wait_end(&wait)
	}
}

// controller_start turns the two ports of the PS/2 controller on with their
// interrupts, and asks the mouse for its wheel.
controller_start :: proc "contextless" () {
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

// tablet_axis_range_read queries Config_Select.Abs_Info for one absolute axis
// from the virtio-input configuration space, falling back to the standard
// QEMU range [0..32767] if the device reports no valid range.
tablet_axis_range_read :: proc "contextless" (axis: virtio_input.Abs_Axis) -> virtio_input.Axis_Range {
	fallback := virtio_input.Axis_Range{virtio_input.ABSOLUTE_AXIS_DEFAULT_MINIMUM, virtio_input.ABSOLUTE_AXIS_DEFAULT_MAXIMUM}
	if tablet_device.device_config == 0 || tablet_device.device_config_length < virtio_input.CONFIG_TOTAL_SIZE {
		return fallback
	}
	base := tablet_device.device_config
	intrinsics.volatile_store((^u8)(base + virtio_input.CONFIG_OFFSET_SELECT), u8(virtio_input.Config_Select.Abs_Info))
	intrinsics.volatile_store((^u8)(base + virtio_input.CONFIG_OFFSET_SUBSEL), u8(axis))
	size := virtio.load_8(base + virtio_input.CONFIG_OFFSET_SIZE)
	result := fallback
	if int(size) >= virtio_input.ABS_INFO_SIZE {
		raw: [virtio_input.ABS_INFO_SIZE]u8
		for index in 0 ..< virtio_input.ABS_INFO_SIZE {
			raw[index] = virtio.load_8(base + virtio_input.CONFIG_OFFSET_DATA + uintptr(index))
		}
		if info, ok := virtio_input.abs_info_from_bytes(raw[:]); ok {
			candidate := virtio_input.Axis_Range{minimum = info.minimum, maximum = info.maximum}
			if virtio_input.axis_range_valid(candidate) {
				result = candidate
			}
		}
	}
	intrinsics.volatile_store((^u8)(base + virtio_input.CONFIG_OFFSET_SELECT), u8(virtio_input.Config_Select.Unset))
	return result
}

// tablet_device_open initializes an optional virtio-tablet-pci device when
// the root service granted its configuration, BARs, queue memory, and
// machine handle. If absent or unusable, PS/2 remains active without error.
tablet_device_open :: proc "contextless" (ctx: ^system.Context) {
	config_handle := ctx.handles[input_context.GRANT_TABLET_CONFIGURATION]
	queues_handle := ctx.handles[input_context.GRANT_TABLET_QUEUES]
	machine_handle := ctx.handles[input_context.GRANT_TABLET_MACHINE]
	if config_handle == 0 || queues_handle == 0 || machine_handle == 0 {
		return
	}
	config_address, config_status := system.memory_map(config_handle, {})
	if config_status != .Ok {
		return
	}
	device, found := virtio.find(ctx, ([^]u8)(config_address)[:pci.CONFIGURATION_SIZE])
	if !found {
		return
	}
	if _, start_error := virtio.start(&device, 0); start_error != .None {
		return
	}
	queue_pages, pages_status := system.memory_size(queues_handle)
	if pages_status != .Ok || queue_pages < pci.QUEUE_PAGES {
		return
	}
	queue_address, map_status := system.memory_map(queues_handle, {.Write})
	queue_physical, phys_status := system.memory_physical(machine_handle, queues_handle)
	if map_status != .Ok || phys_status != .Ok {
		return
	}
	queue, queue_error := virtio.queue_start(&device, virtio_input.EVENT_QUEUE_INDEX, uintptr(queue_address), queue_physical, 1, 0)
	if queue_error != .None {
		return
	}
	tablet_device = device
	tablet_queue = queue
	x_range := tablet_axis_range_read(.X)
	y_range := tablet_axis_range_read(.Y)
	state, init_problem := tablet.tablet_state_init(x_range, y_range, TABLET_COORDINATE_EXTENT, TABLET_COORDINATE_EXTENT)
	if init_problem != .None {
		return
	}
	tablet_state = state
	tablet_buffers = ([^]virtio_input.Raw_Event)(uintptr(queue_address) + TABLET_BUFFER_PAGE * system.PAGE_SIZE)
	tablet_buffers_physical = queue_physical + TABLET_BUFFER_PAGE * system.PAGE_SIZE
	tablet_buffer_count = min(tablet_queue.size, TABLET_EVENT_BUFFER_COUNT)
	for slot in u32(0) ..< tablet_buffer_count {
		tablet_queue.descriptors[slot] = {
			address = tablet_buffers_physical + u64(slot) * virtio_input.EVENT_SIZE,
			length  = virtio_input.EVENT_SIZE,
			flags   = virtio.DESCRIPTOR_DEVICE_WRITES,
		}
		virtio.give(&tablet_queue, u16(slot))
	}
	virtio.ready(&tablet_device)
	virtio.notify(&tablet_queue)
	tablet_active = true
	system.log_fact(.Info, Tablet_Ready{queue_size = u64(tablet_queue.size)})
}

tablet_record :: proc "contextless" (event: tablet.Tablet_Event) -> ring.Record {
	// Linux evdev REL_WHEEL is positive away from the user; display wheel is
	// WHEEL_TOWARD_THE_END toward the user.
	wheel := -i64(event.wheel) * display.WHEEL_TOWARD_THE_END
	return {
		kind = u32(display.Input.Pointer_Absolute),
		values = {
			0 = u64(event.x),
			1 = u64(event.y),
			2 = u64(event.buttons & (display.BUTTON_LEFT | display.BUTTON_RIGHT)),
			3 = u64(wheel),
			4 = u64(TABLET_COORDINATE_EXTENT),
			5 = u64(TABLET_COORDINATE_EXTENT),
		},
	}
}

// tablet_backlog_send writes in the input ring the tablet events that wait,
// the oldest first, while the ring has room.
tablet_backlog_send :: proc "contextless" () {
	send_record :: proc "contextless" (_: rawptr, event: tablet.Tablet_Event) -> bool {
		return system.send(&output.commands, tablet_record(event))
	}
	_ = tablet.tablet_backlog_drain(&tablet_backlog, nil, send_record)
}

tablet_poll :: proc "contextless" () {
	if !tablet_active {
		return
	}
	reposted := false
	for tablet_backlog.count < tablet.TABLET_BACKLOG_CAPACITY {
		used := virtio.used(&tablet_queue) or_break
		slot := used.id
		if slot < tablet_buffer_count {
			raw := tablet_buffers[slot]
			// Re-post the buffer immediately so the device never starves.
			tablet_queue.descriptors[slot] = {
				address = tablet_buffers_physical + u64(slot) * virtio_input.EVENT_SIZE,
				length  = virtio_input.EVENT_SIZE,
				flags   = virtio.DESCRIPTOR_DEVICE_WRITES,
			}
			virtio.give(&tablet_queue, u16(slot))
			reposted = true
			if used.length >= virtio_input.EVENT_SIZE {
				if event, ready, _ := tablet.tablet_state_feed(&tablet_state, raw); ready {
					if tablet_backlog.count == 0 && system.send(&output.commands, tablet_record(event)) {
						continue
					}
					if !tablet.tablet_backlog_add(&tablet_backlog, event) {
						pointer_records_refused += 1
						system.log_fact(.Info, Pointer_Records_Lost{pointer_records = pointer_records_refused})
					}
				}
			}
		}
	}
	if reposted {
		virtio.notify(&tablet_queue)
	}
}
