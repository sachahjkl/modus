// Serial ANSI 24-bit TrueColor terminal renderer for modus:terminal
// (src/md/features/console_renderers.md, "Variant A: serial_terminal").
//
// Reads typed terminal records from console on the shared terminal ring
// through the renderer intake of modus:terminal, renders 24-bit TrueColor
// ANSI escape sequences (including Lex syntax highlighting and interactive
// completion popups) over the second serial port, COM2, and decodes
// VT100/UTF-8 input bytes back into typed terminal_records.Input keys. COM1
// stays the log of the kernel: the text of the terminal never mixes with
// its lines. Requires no compositor, no drawing module, no TrueType font,
// and no framebuffer.
package serial_terminal

import "internal:serial_terminal/ansi_terminal"
import "modus:contract/ring"
import "modus:system"
import terminal_records "modus:terminal"

// Working memory for the terminal ring mapping, text region, ANSI staging
// buffer and the intake with its completion list, and one service thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 32, threads = 1}

// The registers of the 16550 UART of COM2, from its first port.
SERIAL_DATA :: u16(terminal_records.SERIAL_PORT_FIRST + 0)
SERIAL_INTERRUPT_ENABLE :: u16(terminal_records.SERIAL_PORT_FIRST + 1)
SERIAL_FIFO_CONTROL :: u16(terminal_records.SERIAL_PORT_FIRST + 2)
SERIAL_LINE_CONTROL :: u16(terminal_records.SERIAL_PORT_FIRST + 3)
SERIAL_MODEM_CONTROL :: u16(terminal_records.SERIAL_PORT_FIRST + 4)
SERIAL_LINE_STATUS :: u16(terminal_records.SERIAL_PORT_FIRST + 5)
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

// The size of the screen when the context gives none in the bounds.
DEFAULT_COLUMNS :: 80
DEFAULT_ROWS :: 24

ansi_output_buffer: [16384]u8
intake: terminal_records.Renderer_Intake
vt_decoder: ansi_terminal.Vt_Decoder
serial_present: bool
// The time of the system when the decoder took an Escape that no byte
// followed yet; 0: none waits.
escape_since: u64

// serial_open sets the UART to 115200 baud, 8 bits, no parity, one stop
// bit, its FIFO on and its interrupts off: the loop polls it. A port that
// reads all ones has no UART, and the renderer then writes nothing.
@(private = "file")
serial_open :: proc "contextless" () -> bool {
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
	return true
}

@(private = "file")
serial_write_bytes :: proc "contextless" (bytes: []u8) {
	if !serial_present {
		return
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
			serial_present = false
			system.log(.Warning, "serial_terminal: the UART at COM2 takes no byte: the console writes nowhere")
			return
		}
		system.port_write_8(SERIAL_DATA, b)
	}
}

@(private = "file")
key_send :: proc "contextless" (terminal_ring: ^ring.Ring, key: terminal_records.Key) {
	_ = system.send(&terminal_ring.completions, ring.Record {
		kind   = u32(terminal_records.Input.Key),
		tag    = key.code,
		values = {0 = u64(key.character), 1 = u64(key.modifiers), 2 = key.serial},
	})
}

// serial_poll_input reads the bytes that came, and sends each key. An
// Escape alone, with no byte after it for ESCAPE_ALONE_NANOSECONDS by the
// clock of the system, is the key Escape: a sequence whose bytes come in
// two passes stays one key.
@(private = "file")
serial_poll_input :: proc "contextless" (terminal_ring: ^ring.Ring) {
	if !serial_present {
		return
	}
	read := 0
	for read < SERIAL_READ_LIMIT {
		if (system.port_read_8(SERIAL_LINE_STATUS) & SERIAL_DATA_READY) == 0 {
			break
		}
		raw := system.port_read_8(SERIAL_DATA)
		read += 1
		if key, ready := ansi_terminal.vt_decode_byte(&vt_decoder, raw); ready {
			key_send(terminal_ring, key)
		}
	}
	if vt_decoder.state != .Escape {
		escape_since = 0
		return
	}
	now := system.nanoseconds()
	// The Escape that waits is the last byte read: each byte read starts
	// its wait again.
	if read > 0 {
		escape_since = now
		return
	}
	if escape_since != 0 && now - escape_since >= ESCAPE_ALONE_NANOSECONDS {
		escape_since = 0
		if key, ready := ansi_terminal.vt_flush_escape(&vt_decoder); ready {
			key_send(terminal_ring, key)
		}
	}
}

@(export)
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_handle := ctx.handles[terminal_records.GRANT_RING]
	text_handle := ctx.handles[terminal_records.GRANT_TEXT]
	if ring_handle == 0 || text_handle == 0 {
		system.log(.Error, "serial_terminal: missing terminal ring or text grant")
		system.stop(.Failed)
	}
	terminal_ring, ring_status := system.ring_open(ring_handle)
	text_address, map_status := system.memory_map(text_handle, {})
	if ring_status != .Ok || map_status != .Ok {
		system.log(.Error, "serial_terminal: cannot map terminal ring or text region")
		system.stop(.Failed)
	}
	intake = terminal_records.renderer_intake_make(([^]u8)(text_address)[:terminal_records.TEXT_SIZE])
	columns := DEFAULT_COLUMNS
	rows := DEFAULT_ROWS
	if value := ctx.values[terminal_records.VALUE_COLUMNS]; value >= 20 && value <= terminal_records.COLUMNS_LIMIT {
		columns = int(value)
	}
	if value := ctx.values[terminal_records.VALUE_ROWS]; value >= 8 && value <= terminal_records.ROWS_LIMIT {
		rows = int(value)
	}
	// The last row is the edit line; the rows above it are the output.
	edit_row := rows
	edit_column := 1

	serial_present = serial_open()
	if serial_present {
		system.log(.Info, "serial_terminal: ready on COM2")
	} else {
		// The console still runs: its records are read and dropped, so it
		// never waits for a full ring.
		system.log(.Warning, "serial_terminal: no UART at COM2: the console writes nowhere")
	}
	sink := ansi_terminal.sink_make(ansi_output_buffer[:])
	ansi_terminal.emit_layout(&sink, rows, .Dark)
	serial_write_bytes(ansi_terminal.sink_written(&sink))

	for {
		serial_poll_input(&terminal_ring)
		for record in system.receive(&terminal_ring.commands) {
			event := terminal_records.renderer_intake_take(&intake, record)
			out := ansi_terminal.sink_make(ansi_output_buffer[:])
			switch event.step {
			case .None:
			case .Text:
				ansi_terminal.emit_output_text(&out, intake.text[:intake.text_length], event.style, edit_row, edit_column, .Dark)
			case .Clear:
				ansi_terminal.emit_layout(&out, rows, .Dark)
				edit_column = 1
			case .Edit:
				edit := &intake.edit
				cursor := edit.has_cursor ? u64(edit.cursor) : terminal_records.NO_CURSOR
				ansi_terminal.emit_edit_line(&out, edit_row, edit.text[:edit.length], &edit.code, cursor, .Dark)
				edit_column = ansi_terminal.edit_column_of(edit.has_cursor ? u64(edit.cursor) : u64(edit.length), edit.length)
			case .List:
				ansi_terminal.emit_completion_popup(&out, &intake.list.shown, edit_row, columns, rows, .Dark)
				ansi_terminal.emit_cursor_move(&out, edit_row, edit_column)
			}
			if written := ansi_terminal.sink_written(&out); len(written) > 0 {
				serial_write_bytes(written)
			}
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &terminal_ring.commands)
		_ = system.wait_end(&wait, system.time() + 20)
	}
}
