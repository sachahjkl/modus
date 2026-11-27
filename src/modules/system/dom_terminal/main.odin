// The terminal of the console for a page that draws it with the document
// of a browser (src/md/features/console_renderers.md, "Variant C:
// dom_terminal").
//
// Reads the records of the terminal ring through the renderer intake of
// modus:terminal, and writes one JSON line for each step on the second
// serial port, COM2 (internal:dom_terminal/dom_protocol). The page keeps
// the scrollback, the edit line, the hint, the status bar and the
// completion list as elements of its document, with classes for each tone
// and each kind of code. The keys come back as VT100 sequences and UTF-8,
// through the UART driver and key decoder of modus:terminal, the ones of
// serial_terminal. COM1 stays the log of the kernel. Requires no
// compositor, no drawing module, no font and no framebuffer.
package dom_terminal

import "internal:dom_terminal/dom_protocol"
import "modus:system"
import terminal_records "modus:terminal"

line_buffer: [dom_protocol.LINE_LIMIT]u8
intake: terminal_records.Renderer_Intake
serial_port: terminal_records.Serial_Port

@(private = "file")
serial_write_bytes :: proc "contextless" (bytes: []u8) {
	if !terminal_records.serial_port_write(&serial_port, bytes) {
		system.log(.Warning, "dom_terminal: the UART at COM2 takes no byte: the console writes nowhere")
	}
}

@(export)
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_handle := ctx.handles[terminal_records.GRANT_RING]
	text_handle := ctx.handles[terminal_records.GRANT_TEXT]
	if ring_handle == 0 || text_handle == 0 {
		system.log(.Error, "dom_terminal: missing terminal ring or text grant")
		system.stop(.Failed)
	}
	terminal_ring, ring_status := system.ring_open(ring_handle)
	text_address, map_status := system.memory_map(text_handle, {})
	if ring_status != .Succeeded || map_status != .Succeeded {
		system.log(.Error, "dom_terminal: cannot map terminal ring or text region")
		system.stop(.Failed)
	}
	intake = terminal_records.renderer_intake_make(([^]u8)(text_address)[:terminal_records.TEXT_SIZE])

	if terminal_records.serial_port_open(&serial_port) {
		system.log(.Info, "dom_terminal: ready on COM2")
	} else {
		// The console still runs: its records are read and dropped, so it
		// never waits for a full ring.
		system.log(.Warning, "dom_terminal: no UART at COM2: the console writes nowhere")
	}
	// A page that opens after the first lines starts from a clear screen.
	line := dom_protocol.line_make(line_buffer[:])
	dom_protocol.write_clear(&line)
	serial_write_bytes(dom_protocol.line_written(&line))

	lines_refused: u64
	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		poll := terminal_records.serial_port_poll(&serial_port, &terminal_ring)
		for record in system.receive(&terminal_ring.commands) {
			event := terminal_records.renderer_intake_take(&intake, record)
			line = dom_protocol.line_make(line_buffer[:])
			written := dom_protocol.write_step(&line, event.step, &intake, event.style)
			if line.overflow {
				// LINE_LIMIT holds the largest step: a line that does not
				// fit is a fault of this module, said once.
				if lines_refused == 0 {
					system.log(.Warning, "dom_terminal: a line did not fit its buffer and was not written")
				}
				lines_refused += 1
				continue
			}
			if len(written) > 0 {
				serial_write_bytes(written)
			}
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &terminal_ring.commands)
		if poll.ring_full {
			system.wait_room_for(&wait, &terminal_ring.completions, poll.room_needed)
		} else if poll.more_input {
			wait.full = true
		}
		_ = system.wait_end(&wait, system.time() + 20)
	}
}
