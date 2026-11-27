// Serial ANSI 24-bit TrueColor terminal renderer for modus:terminal
// (src/md/features/console_renderers.md, "Variant A: serial_terminal").
//
// Reads typed terminal records from console on the shared terminal ring
// through the renderer intake of modus:terminal, renders 24-bit TrueColor
// ANSI escape sequences (including Lex syntax highlighting and interactive
// completion popups) over the second serial port, COM2, and decodes
// VT100/UTF-8 input bytes back into typed terminal_records.Input keys
// through the UART driver and key decoder of modus:terminal. COM1 stays the
// log of the kernel: the text of the terminal never mixes with its lines.
// Requires no compositor, no drawing module, no TrueType font, and no
// framebuffer.
package serial_terminal

import "internal:serial_terminal/ansi_terminal"
import "modus:system"
import terminal_records "modus:terminal"

// The size of the screen when the context gives none in the bounds.
DEFAULT_COLUMNS :: 80
DEFAULT_ROWS :: 24

ansi_output_buffer: [16384]u8
intake: terminal_records.Renderer_Intake
serial_port: terminal_records.Serial_Port

@(private = "file")
serial_write_bytes :: proc "contextless" (bytes: []u8) {
	if !terminal_records.serial_port_write(&serial_port, bytes) {
		system.log(.Warning, "serial_terminal: the UART at COM2 takes no byte: the console writes nowhere")
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
	if ring_status != .Succeeded || map_status != .Succeeded {
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

	if terminal_records.serial_port_open(&serial_port) {
		system.log(.Info, "serial_terminal: ready on COM2")
	} else {
		// The console still runs: its records are read and dropped, so it
		// never waits for a full ring.
		system.log(.Warning, "serial_terminal: no UART at COM2: the console writes nowhere")
	}
	sink := ansi_terminal.sink_make(ansi_output_buffer[:])
	ansi_terminal.emit_layout(&sink, rows, .Dark)
	serial_write_bytes(ansi_terminal.sink_written(&sink))

	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		poll := terminal_records.serial_port_poll(&serial_port, &terminal_ring)
		for record in system.receive(&terminal_ring.commands) {
			event := terminal_records.renderer_intake_take(&intake, record)
			out := ansi_terminal.sink_make(ansi_output_buffer[:])
			switch event.step {
			case .None, .Status, .Hint:
			// The serial screen keeps no status line and no hint line.
			case .Text:
				ansi_terminal.emit_output_text(&out, intake.text[:intake.text_length], event.style, edit_row, edit_column, .Dark)
			case .Clear:
				ansi_terminal.emit_layout(&out, rows, .Dark)
				edit_column = 1
			case .Edit:
				edit := &intake.edit
				cursor := edit.has_cursor ? u64(edit.cursor) : terminal_records.NO_CURSOR
				ansi_terminal.emit_edit_line(&out, edit_row, edit.text[:edit.length], edit.code.runs[:clamp(edit.code.count, 0, len(edit.code.runs))], cursor, .Dark)
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
		if poll.ring_full {
			system.wait_room_for(&wait, &terminal_ring.completions, poll.room_needed)
		} else if poll.more_input {
			wait.full = true
		}
		_ = system.wait_end(&wait, system.time() + 20)
	}
}
