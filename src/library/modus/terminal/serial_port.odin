package terminal_records

import "modus:contract/ring"
import "modus:system"

// The UART of the second serial port, COM2, as serial_terminal and
// dom_terminal drive it (src/md/features/console_renderers.md, "One key
// decoder"): one driver, so the two renderers cannot differ on how they
// open the port, how long they wait for room, or when an Escape alone is
// the key Escape. The renderer holds the ports as a Ports handle from the
// root service; COM1 stays the log of the kernel.

// The registers of the 16550 UART of COM2, from its first port.
SERIAL_DATA :: u16(SERIAL_PORT_FIRST + 0)
SERIAL_INTERRUPT_ENABLE :: u16(SERIAL_PORT_FIRST + 1)
SERIAL_FIFO_CONTROL :: u16(SERIAL_PORT_FIRST + 2)
SERIAL_LINE_CONTROL :: u16(SERIAL_PORT_FIRST + 3)
SERIAL_MODEM_CONTROL :: u16(SERIAL_PORT_FIRST + 4)
SERIAL_LINE_STATUS :: u16(SERIAL_PORT_FIRST + 5)
SERIAL_DATA_READY :: u8(0x01)
SERIAL_TRANSMIT_EMPTY :: u8(0x20)
// A port with no device reads all ones: a line status of 0xFF is no UART.
SERIAL_ABSENT_STATUS :: u8(0xFF)
// The bound of the wait for room in the transmit register, for one byte.
// A UART that does not take a byte within it is taken as absent: the
// renderer writes no more, so a stalled UART costs this bound once, never
// once for each byte.
SERIAL_TRANSMIT_TRIES :: 10000
// An Escape with no byte after it for this long is the key Escape; the
// bytes of a sequence of a terminal come closer together.
ESCAPE_ALONE_NANOSECONDS :: 20_000_000
// The bytes read at most in one pass: the loop goes back to the ring.
SERIAL_READ_LIMIT :: 32

// The state of the UART of a renderer.
Serial_Port :: struct {
	present:      bool,
	decoder:      Vt_Decoder,
	// The time of the system when the decoder took an Escape that no byte
	// followed yet; 0: none waits.
	escape_since: u64,
}

// serial_port_open sets the UART to 115200 baud, 8 bits, no parity, one
// stop bit, its FIFO on and its interrupts off: the renderer polls it. A
// port that reads all ones has no UART, and the renderer then writes
// nothing.
serial_port_open :: proc "contextless" (port: ^Serial_Port) -> bool {
	port^ = {}
	if system.port_read_8(SERIAL_LINE_STATUS) == SERIAL_ABSENT_STATUS {
		return false
	}
	system.port_write_8(SERIAL_INTERRUPT_ENABLE, 0x00)
	system.port_write_8(SERIAL_LINE_CONTROL, 0x80) // The divisor latch.
	system.port_write_8(SERIAL_DATA, 0x01) // The divisor 1: 115200 baud.
	system.port_write_8(SERIAL_INTERRUPT_ENABLE, 0x00)
	system.port_write_8(SERIAL_LINE_CONTROL, 0x03) // 8 bits, no parity, one stop bit.
	system.port_write_8(SERIAL_FIFO_CONTROL, 0xC7)
	system.port_write_8(SERIAL_MODEM_CONTROL, 0x03)
	port.present = true
	return true
}

// serial_port_write writes bytes. It gives false when the UART took no
// byte within the bound of its wait: from then on the port is absent, and
// the renderer says so once.
serial_port_write :: proc "contextless" (port: ^Serial_Port, bytes: []u8) -> bool {
	if !port.present {
		return true
	}
	for b in bytes {
		room := false
		for _ in 0 ..< SERIAL_TRANSMIT_TRIES {
			if (system.port_read_8(SERIAL_LINE_STATUS) & SERIAL_TRANSMIT_EMPTY) != 0 {
				room = true
				break
			}
		}
		if !room {
			port.present = false
			return false
		}
		system.port_write_8(SERIAL_DATA, b)
	}
	return true
}

@(private = "file")
serial_key_send :: proc "contextless" (terminal_ring: ^ring.Ring, key: Key) {
	_ = system.send(&terminal_ring.completions, ring.Record {
		kind   = u32(Input.Key),
		tag    = key.code,
		values = {0 = u64(key.character), 1 = u64(key.modifiers), 2 = key.serial},
	})
}

// serial_port_poll reads the bytes that came, and sends each key on the
// terminal ring. An Escape alone, with no byte after it for
// ESCAPE_ALONE_NANOSECONDS by the clock of the system, is the key Escape:
// a sequence whose bytes come in two passes stays one key.
serial_port_poll :: proc "contextless" (port: ^Serial_Port, terminal_ring: ^ring.Ring) {
	if !port.present {
		return
	}
	read := 0
	for read < SERIAL_READ_LIMIT {
		if (system.port_read_8(SERIAL_LINE_STATUS) & SERIAL_DATA_READY) == 0 {
			break
		}
		raw := system.port_read_8(SERIAL_DATA)
		read += 1
		if key, ready := vt_decode_byte(&port.decoder, raw); ready {
			serial_key_send(terminal_ring, key)
		}
	}
	if port.decoder.state != .Escape {
		port.escape_since = 0
		return
	}
	now := system.nanoseconds()
	// The Escape that waits is the last byte read: each byte read starts
	// its wait again.
	if read > 0 {
		port.escape_since = now
		return
	}
	if port.escape_since != 0 && now - port.escape_since >= ESCAPE_ALONE_NANOSECONDS {
		port.escape_since = 0
		if key, ready := vt_flush_escape(&port.decoder); ready {
			serial_key_send(terminal_ring, key)
		}
	}
}
