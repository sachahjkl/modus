// Serial ANSI 24-bit TrueColor terminal renderer for modus:terminal
// (src/md/features/console_renderers.md, "Variant A: serial_terminal").
//
// Reads typed terminal records from console on the shared terminal ring,
// renders 24-bit TrueColor ANSI escape sequences (including Lex syntax
// highlighting and interactive completion popups) over COM1, and decodes
// VT100/UTF-8 input bytes back into typed terminal_records.Input keys.
// Requires no compositor, no drawing module, no TrueType font, and no framebuffer.
package serial_terminal

import "internal:serial_terminal/ansi_terminal"
import "modus:contract/enum_word"
import "modus:contract/ring"
import "modus:system"
import terminal_records "modus:terminal"

// Working memory for the terminal ring mapping, text region, ANSI staging
// buffer and completion list; zero child processes and one service thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 32, processes = 0, threads = 1}

// COM1 serial port addresses and line-status flags.
COM1_DATA :: u16(0x3F8)
COM1_LINE_STATUS :: u16(0x3FD)
COM1_DATA_READY :: u8(0x01)
COM1_TRANSMIT_EMPTY :: u8(0x20)

ansi_output_buffer: [16384]u8
edit_line_buffer: [terminal_records.RUN_LIMIT]u8
edit_runs: terminal_records.Code_Runs
pending_edit_runs: terminal_records.Code_Runs
has_pending_edit_runs: bool
list_keeping: terminal_records.List_Keeping
vt_decoder: ansi_terminal.Vt_Decoder

@(private = "file")
serial_write_bytes :: proc "contextless" (bytes: []u8) {
	for b in bytes {
		for _ in 0 ..< 10000 {
			if (system.port_read_8(COM1_LINE_STATUS) & COM1_TRANSMIT_EMPTY) != 0 {
				break
			}
		}
		system.port_write_8(COM1_DATA, b)
	}
}

@(private = "file")
serial_poll_input :: proc "contextless" (terminal_ring: ^ring.Ring) {
	for _ in 0 ..< 32 {
		if (system.port_read_8(COM1_LINE_STATUS) & COM1_DATA_READY) == 0 {
			break
		}
		raw := system.port_read_8(COM1_DATA)
		if key, ready := ansi_terminal.vt_decode_byte(&vt_decoder, raw); ready {
			_ = system.send(&terminal_ring.completions, ring.Record{
				kind   = u32(terminal_records.Input.Key),
				tag    = key.code,
				values = {0 = u64(key.character), 1 = u64(key.modifiers), 2 = key.serial},
			})
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
	text_address, map_status := system.memory_map(text_handle)
	if ring_status != .Ok || map_status != .Ok {
		system.log(.Error, "serial_terminal: cannot map terminal ring or text region")
		system.stop(.Failed)
	}
	text_region := ([^]u8)(text_address)[:terminal_records.TEXT_SIZE]
	read_offset: u64 = 0
	edit_row := 24
	columns := 80
	if col_val := int(ctx.values[terminal_records.VALUE_COLUMNS]); col_val >= 20 && col_val <= terminal_records.COLUMNS_LIMIT {
		columns = col_val
	}
	if row_val := int(ctx.values[terminal_records.VALUE_ROWS]); row_val >= 8 && row_val <= terminal_records.ROWS_LIMIT {
		edit_row = row_val - 1
	}

	sink := ansi_terminal.sink_make(ansi_output_buffer[:])
	ansi_terminal.emit_clear_screen(&sink, .Dark)
	serial_write_bytes(ansi_terminal.sink_written(&sink))
	system.log(.Info, "serial_terminal: ready")

	for {
		serial_poll_input(&terminal_ring)
		for record in system.receive(&terminal_ring.commands) {
			kind, known := enum_word.member_of_word(terminal_records.Kind, u64(record.kind))
			if !known {
				continue
			}
			count := int(min(u64(record.tag), terminal_records.RUN_LIMIT))
			text_slice: [terminal_records.RUN_LIMIT]u8
			if count > 0 {
				for i in 0 ..< count {
					text_slice[i] = text_region[(read_offset + u64(i)) & (terminal_records.TEXT_SIZE - 1)]
				}
				read_offset += u64(count)
			}
			out := ansi_terminal.sink_make(ansi_output_buffer[:])
			switch kind {
			case .None, .Status, .Hint:
			case .Text:
				style := transmute(terminal_records.Style)record.values[0]
				ansi_terminal.emit_styled_text(&out, text_slice[:count], style, .Dark)
			case .Clear:
				ansi_terminal.emit_clear_screen(&out, .Dark)
			case .Code_Runs:
				if record.values[0] == u64(terminal_records.Kind.Edit) {
					run_count := min(count / size_of(terminal_records.Code_Run), terminal_records.CODE_RUN_LIMIT)
					pending_edit_runs.count = run_count
					for i in 0 ..< run_count {
						base := i * 4
						pending_edit_runs.runs[i] = {
							start  = text_slice[base + 0],
							length = text_slice[base + 1],
							kind   = text_slice[base + 2],
						}
					}
					has_pending_edit_runs = true
				}
			case .Edit:
				copy(edit_line_buffer[:count], text_slice[:count])
				if has_pending_edit_runs {
					edit_runs = pending_edit_runs
					has_pending_edit_runs = false
				} else {
					edit_runs = {}
				}
				ansi_terminal.emit_edit_line(&out, edit_row, edit_line_buffer[:count], &edit_runs, record.values[1], .Dark)
			case .List_Row:
				row_index := int(record.values[0])
				if row_index >= 0 && row_index < terminal_records.LIST_ROWS {
					row := &list_keeping.next[row_index]
					copy(row.text[:count], text_slice[:count])
					row.length = count
					row.name_length = min(int(record.values[1]), count)
				}
			case .List:
				rows := min(int(record.values[0]), terminal_records.LIST_ROWS)
				list_keeping.shown.row_count = rows
				list_keeping.shown.chosen = record.values[1] == terminal_records.NO_CHOICE ? -1 : int(record.values[1])
				list_keeping.shown.anchor = int(record.values[4])
				for i in 0 ..< rows {
					list_keeping.shown.rows[i] = list_keeping.next[i]
				}
				ansi_terminal.emit_completion_popup(&out, &list_keeping.shown, edit_row, columns, .Dark)
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
