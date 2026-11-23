package guest_os

// The legacy devices of a personal computer that a Linux guest of 64 bits
// uses with no firmware table: the serial port 8250 (its console), the
// pair of interrupt controllers 8259, and the interval timer 8254 (its
// tick). The time of the guest is a virtual clock in ticks of the timer
// (1 193 182 Hz) that the process moves forward: never the clock of the
// machine.

// --- The serial port 8250 at 0x3F8, the line 4 ---

SERIAL_PORT_BASE :: u16(0x3F8)
SERIAL_INTERRUPT_LINE :: u8(4)
SERIAL_CAPTURE_BYTES :: 4096
// The bytes that wait for the guest to read them: the keys of a principal
// that the guest did not take yet.
SERIAL_RECEIVE_BYTES :: 256

SERIAL_LINE_STATUS_DATA_READY :: u8(0x01)
SERIAL_LINE_STATUS_TRANSMIT_EMPTY :: u8(0x60) // The holding register and the shift register are empty.
SERIAL_INTERRUPT_NONE :: u8(0x01) // The identification register: no interrupt waits.
SERIAL_INTERRUPT_TRANSMIT :: u8(0x02) // The holding register is empty.
SERIAL_INTERRUPT_RECEIVED :: u8(0x04) // Received data waits: it comes before the holding register.
SERIAL_ENABLE_RECEIVED :: u8(0x01)
SERIAL_ENABLE_TRANSMIT :: u8(0x02)
SERIAL_LINE_DIVISOR_LATCH :: u8(0x80)
SERIAL_MODEM_LOOP :: u8(0x10)

Serial_Port :: struct {
	interrupt_enable:  u8,
	line_control:      u8,
	modem_control:     u8,
	scratch:           u8,
	divisor:           u16,
	transmit_pending:  bool, // The interrupt "holding register empty" waits.
	capture:           [SERIAL_CAPTURE_BYTES]u8,
	captured:          u32,
	dropped:           u64,
	receive:           [SERIAL_RECEIVE_BYTES]u8, // A queue: receive_count bytes from receive_first, around the end.
	receive_first:     u32,
	receive_count:     u32,
	receive_dropped:   u64, // The bytes that found the queue full.
}

// serial_receive_put puts bytes in the receive queue of the port, as the
// line of a terminal brings them, and gives how many it took: a byte that
// finds the queue full is dropped and counted.
serial_receive_put :: proc "contextless" (port: ^Serial_Port, bytes: []u8) -> (taken: int) {
	for value in bytes {
		if port.receive_count == SERIAL_RECEIVE_BYTES {
			port.receive_dropped += u64(len(bytes) - taken)
			return taken
		}
		port.receive[(port.receive_first + port.receive_count) % SERIAL_RECEIVE_BYTES] = value
		port.receive_count += 1
		taken += 1
	}
	return taken
}

// serial_output_take gives the bytes that the guest wrote since the last
// call, at most len(out), and takes them out of the capture. The bytes
// that came while the capture was full are counted in dropped.
serial_output_take :: proc "contextless" (port: ^Serial_Port, out: []u8) -> (count: int) {
	count = min(int(port.captured), len(out))
	copy(out[:count], port.capture[:count])
	copy(port.capture[:], port.capture[count:port.captured])
	port.captured -= u32(count)
	return count
}

// serial_read gives the value of a read of the register at offset (0 to 7).
serial_read :: proc "contextless" (port: ^Serial_Port, offset: u16) -> u8 {
	latch := port.line_control & SERIAL_LINE_DIVISOR_LATCH != 0
	switch offset {
	case 0:
		if latch {
			return u8(port.divisor)
		}
		// The receive register: the first byte of the queue, or 0 when the
		// queue is empty.
		if port.receive_count == 0 {
			return 0
		}
		value := port.receive[port.receive_first]
		port.receive_first = (port.receive_first + 1) % SERIAL_RECEIVE_BYTES
		port.receive_count -= 1
		return value
	case 1:
		if latch {
			return u8(port.divisor >> 8)
		}
		return port.interrupt_enable
	case 2:
		// Received data comes first, and stays until the queue is empty.
		// A read of the identification clears the interrupt of the holding
		// register that it names.
		if port.receive_count != 0 && port.interrupt_enable & SERIAL_ENABLE_RECEIVED != 0 {
			return SERIAL_INTERRUPT_RECEIVED
		}
		if port.transmit_pending && port.interrupt_enable & SERIAL_ENABLE_TRANSMIT != 0 {
			port.transmit_pending = false
			return SERIAL_INTERRUPT_TRANSMIT
		}
		return SERIAL_INTERRUPT_NONE
	case 3:
		return port.line_control
	case 4:
		return port.modem_control
	case 5:
		return SERIAL_LINE_STATUS_TRANSMIT_EMPTY | (port.receive_count != 0 ? SERIAL_LINE_STATUS_DATA_READY : 0)
	case 6:
		// In loop mode, the modem status echoes the modem control: the probe
		// of Linux checks it. Else carrier, data set ready and clear to send.
		if port.modem_control & SERIAL_MODEM_LOOP != 0 {
			control := port.modem_control
			return (control & 0x2) << 3 | (control & 0x1) << 5 | (control & 0x4) << 4 | (control & 0x8) << 4
		}
		return 0xB0
	case 7:
		return port.scratch
	}
	return 0xFF
}

// serial_write applies a write of the register at offset (0 to 7).
serial_write :: proc "contextless" (port: ^Serial_Port, offset: u16, value: u8) {
	latch := port.line_control & SERIAL_LINE_DIVISOR_LATCH != 0
	switch offset {
	case 0:
		if latch {
			port.divisor = port.divisor & 0xFF00 | u16(value)
			return
		}
		if port.modem_control & SERIAL_MODEM_LOOP == 0 {
			if port.captured < SERIAL_CAPTURE_BYTES {
				port.capture[port.captured] = value
				port.captured += 1
			} else {
				port.dropped += 1
			}
		}
		// The byte leaves at once: the holding register is empty again.
		port.transmit_pending = true
	case 1:
		if latch {
			port.divisor = port.divisor & 0x00FF | u16(value) << 8
			return
		}
		// Enabling the interrupt of an empty holding register raises it.
		if value & SERIAL_ENABLE_TRANSMIT != 0 && port.interrupt_enable & SERIAL_ENABLE_TRANSMIT == 0 {
			port.transmit_pending = true
		}
		port.interrupt_enable = value & 0x0F
	case 2:
		// The control of the queues: this port has none.
	case 3:
		port.line_control = value
	case 4:
		port.modem_control = value & 0x1F
	case 7:
		port.scratch = value
	}
}

// serial_interrupt says if the port asserts its line.
serial_interrupt :: proc "contextless" (port: ^Serial_Port) -> bool {
	received := port.receive_count != 0 && port.interrupt_enable & SERIAL_ENABLE_RECEIVED != 0
	return received || port.transmit_pending && port.interrupt_enable & SERIAL_ENABLE_TRANSMIT != 0
}

// --- The interrupt controllers 8259 at 0x20 and 0xA0 ---

INTERRUPT_PRIMARY_PORT :: u16(0x20)
INTERRUPT_SECONDARY_PORT :: u16(0xA0)
INTERRUPT_CASCADE_LINE :: u8(2)
INTERRUPT_LINES :: 16

Interrupt_Chip :: struct {
	mask:            u8,
	request:         u8,
	service:         u8,
	vector_base:     u8,
	initialisation:  u8, // The next word of initialisation: 0 none, 2 to 4.
	fourth_word:     bool,
	automatic_end:   bool,
	read_service:    bool,
	level:           u8, // The lines whose request follows the level of the device.
}

Interrupt_Controllers :: struct {
	primary:   Interrupt_Chip,
	secondary: Interrupt_Chip,
}

interrupt_chip_read :: proc "contextless" (chip: ^Interrupt_Chip, odd: bool) -> u8 {
	if odd {
		return chip.mask
	}
	return chip.read_service ? chip.service : chip.request
}

interrupt_chip_write :: proc "contextless" (chip: ^Interrupt_Chip, odd: bool, value: u8) {
	if !odd && value & 0x10 != 0 {
		// The first word of initialisation: the mask and the requests clear.
		chip^ = {initialisation = 2, fourth_word = value & 0x1 != 0, level = chip.level}
		return
	}
	if odd {
		switch chip.initialisation {
		case 2:
			chip.vector_base = value & 0xF8
			chip.initialisation = 3
		case 3:
			chip.initialisation = chip.fourth_word ? 4 : 0
		case 4:
			chip.automatic_end = value & 0x2 != 0
			chip.initialisation = 0
		case:
			chip.mask = value
		}
		return
	}
	if value & 0x08 != 0 {
		// The third word of operation: which register an even read gives.
		if value & 0x2 != 0 {
			chip.read_service = value & 0x1 != 0
		}
		return
	}
	// The second word of operation: the end of an interrupt.
	switch value >> 5 & 0x7 {
	case 1:
		// Not specific: the line of the highest priority in service.
		for line in u8(0) ..< 8 {
			if chip.service & (1 << line) != 0 {
				chip.service &~= 1 << line
				break
			}
		}
	case 3:
		chip.service &~= 1 << (value & 0x7)
	}
}

// interrupt_line_set sets the level of a line from a device. An edge line
// (the timer) requests at each rise; a level line (a virtio device, the
// serial port) requests while its level is high.
interrupt_line_set :: proc "contextless" (controllers: ^Interrupt_Controllers, line: u8, high: bool) {
	if line >= INTERRUPT_LINES {
		return
	}
	chip := line < 8 ? &controllers.primary : &controllers.secondary
	bit := u8(1) << (line & 7)
	if high {
		chip.request |= bit
	} else if chip.level & bit != 0 {
		chip.request &~= bit
	}
}

// interrupt_chip_next gives the line of the highest priority that waits,
// unmasked and above each line in service.
interrupt_chip_next :: proc "contextless" (chip: ^Interrupt_Chip, extra: u8) -> (line: u8, ok: bool) {
	waiting := (chip.request | extra) &~ chip.mask
	for candidate in u8(0) ..< 8 {
		bit := u8(1) << candidate
		if chip.service & bit != 0 {
			return 0, false
		}
		if waiting & bit != 0 {
			return candidate, true
		}
	}
	return 0, false
}

// interrupt_waiting_vector gives the vector that interrupt_acknowledge
// would give now, and changes nothing: no line goes into service.
interrupt_waiting_vector :: proc "contextless" (controllers: ^Interrupt_Controllers) -> (vector: u8, ok: bool) {
	secondary_line, secondary_waits := interrupt_chip_next(&controllers.secondary, 0)
	cascade := secondary_waits ? u8(1) << INTERRUPT_CASCADE_LINE : 0
	line := interrupt_chip_next(&controllers.primary, cascade) or_return
	if line == INTERRUPT_CASCADE_LINE && secondary_waits {
		return controllers.secondary.vector_base + secondary_line, true
	}
	return controllers.primary.vector_base + line, true
}

// interrupt_acknowledge gives the vector of the interrupt that the guest
// takes now, and moves its line into service, as the acknowledge cycle of
// the processor does; false when none waits.
interrupt_acknowledge :: proc "contextless" (controllers: ^Interrupt_Controllers) -> (vector: u8, ok: bool) {
	secondary_line, secondary_waits := interrupt_chip_next(&controllers.secondary, 0)
	cascade := secondary_waits ? u8(1) << INTERRUPT_CASCADE_LINE : 0
	line := interrupt_chip_next(&controllers.primary, cascade) or_return
	primary := &controllers.primary
	bit := u8(1) << line
	if line == INTERRUPT_CASCADE_LINE && secondary_waits {
		secondary := &controllers.secondary
		secondary_bit := u8(1) << secondary_line
		if secondary.level & secondary_bit == 0 {
			secondary.request &~= secondary_bit
		}
		if !secondary.automatic_end {
			secondary.service |= secondary_bit
		}
		if !primary.automatic_end {
			primary.service |= bit
		}
		return secondary.vector_base + secondary_line, true
	}
	if primary.level & bit == 0 {
		primary.request &~= bit
	}
	if !primary.automatic_end {
		primary.service |= bit
	}
	return primary.vector_base + line, true
}

// --- The interval timer 8254 at 0x40, the line 0 ---

TIMER_PORT_BASE :: u16(0x40)
TIMER_CONTROL_PORT :: u16(0x43)
TIMER_GATE_PORT :: u16(0x61)
TIMER_INTERRUPT_LINE :: u8(0)
TIMER_TICKS_PER_SECOND :: u64(1_193_182)
TIMER_CHANNELS :: 3

Timer_Channel :: struct {
	mode:          u8, // 0 to 5.
	access:        u8, // 1 the low byte, 2 the high byte, 3 both.
	reload:        u16, // 0 means 65 536.
	start:         u64, // The tick of the last load.
	loaded:        bool,
	latched:       bool,
	latch:         u16,
	read_high:     bool, // The next read of an access of both bytes gives the high byte.
	write_high:    bool,
	fired:         u64, // The periods of the line 0 that raised it.
}

Interval_Timer :: struct {
	channels: [TIMER_CHANNELS]Timer_Channel,
	gate:     u8, // Port 0x61: bit 0 the gate of the channel 2, bit 1 the speaker.
}

timer_period :: proc "contextless" (channel: ^Timer_Channel) -> u64 {
	return channel.reload == 0 ? 65536 : u64(channel.reload)
}

// timer_count gives the count of a channel at a tick: modes 2 and 3 count
// down and reload, the other modes count down once and wrap.
timer_count :: proc "contextless" (channel: ^Timer_Channel, now: u64) -> u16 {
	if !channel.loaded {
		return 0
	}
	period := timer_period(channel)
	elapsed := now - channel.start
	if channel.mode == 2 || channel.mode == 3 {
		return u16(period - elapsed % period)
	}
	return u16((period - elapsed % 65536) & 0xFFFF)
}

// timer_output gives the output of a channel at a tick, which port 0x61
// shows for the channel 2: in mode 0, high once the count reached 0.
timer_output :: proc "contextless" (channel: ^Timer_Channel, now: u64) -> bool {
	if !channel.loaded {
		return false
	}
	period := timer_period(channel)
	elapsed := now - channel.start
	switch channel.mode {
	case 0, 1:
		return elapsed >= period
	case 3:
		return elapsed % period < period / 2
	}
	return true
}

timer_read :: proc "contextless" (timer: ^Interval_Timer, port: u16, now: u64) -> u8 {
	if port == TIMER_GATE_PORT {
		output := timer_output(&timer.channels[2], now) ? u8(0x20) : 0
		return timer.gate & 0x3 | output
	}
	if port < TIMER_PORT_BASE || port >= TIMER_PORT_BASE + TIMER_CHANNELS {
		return 0xFF
	}
	channel := &timer.channels[port - TIMER_PORT_BASE]
	value := channel.latched ? channel.latch : timer_count(channel, now)
	high := channel.access == 2 || channel.access == 3 && channel.read_high
	if channel.access == 3 {
		channel.read_high = !channel.read_high
	}
	if channel.latched && (channel.access != 3 || !channel.read_high) {
		channel.latched = false
	}
	return high ? u8(value >> 8) : u8(value)
}

timer_write :: proc "contextless" (timer: ^Interval_Timer, port: u16, value: u8, now: u64) {
	if port == TIMER_GATE_PORT {
		timer.gate = value & 0x3
		return
	}
	if port == TIMER_CONTROL_PORT {
		select := value >> 6
		if select == 3 {
			// Read back: latch the count of each channel named by bits 1 to 3.
			if value & 0x20 == 0 {
				for index in 0 ..< TIMER_CHANNELS {
					if value & (u8(2) << u8(index)) != 0 {
						channel := &timer.channels[index]
						channel.latch = timer_count(channel, now)
						channel.latched = true
						channel.read_high = false
					}
				}
			}
			return
		}
		channel := &timer.channels[select]
		access := value >> 4 & 0x3
		if access == 0 {
			channel.latch = timer_count(channel, now)
			channel.latched = true
			channel.read_high = false
			return
		}
		channel^ = {mode = value >> 1 & 0x7, access = access}
		if channel.mode > 5 {
			channel.mode -= 4 // Modes 6 and 7 are modes 2 and 3.
		}
		return
	}
	if port < TIMER_PORT_BASE || port >= TIMER_PORT_BASE + TIMER_CHANNELS {
		return
	}
	channel := &timer.channels[port - TIMER_PORT_BASE]
	switch channel.access {
	case 1:
		channel.reload = u16(value)
	case 2:
		channel.reload = u16(value) << 8
	case 3:
		if !channel.write_high {
			channel.reload = channel.reload & 0xFF00 | u16(value)
			channel.write_high = true
			return
		}
		channel.reload = channel.reload & 0x00FF | u16(value) << 8
		channel.write_high = false
	case:
		return
	}
	channel.start = now
	channel.loaded = true
	channel.fired = 0
}

// timer_deadline gives the tick of the next interrupt of the channel 0, or
// false when it raises no more.
timer_deadline :: proc "contextless" (timer: ^Interval_Timer) -> (tick: u64, ok: bool) {
	channel := &timer.channels[0]
	if !channel.loaded {
		return 0, false
	}
	period := timer_period(channel)
	if channel.mode == 2 || channel.mode == 3 {
		return channel.start + (channel.fired + 1) * period, true
	}
	// Mode 0 raises the line at the end of its count; mode 4, the strobe
	// that Linux uses for a one-shot tick, raises it there too: its output
	// falls for one tick and rises again, and the line takes the rise. Each
	// fires once for each load of the count.
	if (channel.mode == 0 || channel.mode == 4) && channel.fired == 0 {
		return channel.start + period, true
	}
	return 0, false
}

// timer_advance gives the interrupts of the channel 0 up to a tick: true
// when at least one deadline passed. The line is an edge: several periods
// that passed between two exits raise it once.
timer_advance :: proc "contextless" (timer: ^Interval_Timer, now: u64) -> (raised: bool) {
	for {
		deadline, waiting := timer_deadline(timer)
		if !waiting || deadline > now {
			return raised
		}
		timer.channels[0].fired += 1
		raised = true
		// A guest that missed many periods catches up in one step.
		channel := &timer.channels[0]
		if channel.mode == 2 || channel.mode == 3 {
			period := timer_period(channel)
			channel.fired = max(channel.fired, (now - channel.start) / period)
		}
	}
}
