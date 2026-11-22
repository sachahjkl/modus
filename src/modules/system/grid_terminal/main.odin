// Full-screen direct framebuffer monospace grid terminal for modus:terminal
// (src/md/features/console_renderers.md, "Variant B: grid_terminal").
//
// Reads typed terminal records from console on the shared terminal ring and
// blits a Spleen 8x16 monospace grid with Modus 24-bit colors, Lex syntax
// highlighting, cursor, and interactive completion popup directly onto a
// linear framebuffer — zero compositor, zero window chrome, zero TrueType.
package grid_terminal

import "internal:grid_terminal/grid_renderer"
import "modus:contract/enum_word"
import "modus:graphics"
import "modus:system"
import terminal_records "modus:terminal"

// Working memory for the terminal ring mapping, text region, cell grid and
// optional direct framebuffer mapping; zero child processes and one thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 64, processes = 0, threads = 1}

screen: grid_renderer.Grid_Screen
edit_runs: terminal_records.Code_Runs
pending_edit_runs: terminal_records.Code_Runs
has_pending_edit_runs: bool
list_keeping: terminal_records.List_Keeping
output_row: int

@(export)
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_handle := ctx.handles[terminal_records.GRANT_RING]
	text_handle := ctx.handles[terminal_records.GRANT_TEXT]
	if ring_handle == 0 || text_handle == 0 {
		system.log(.Error, "grid_terminal: missing terminal ring or text grant")
		system.stop(.Failed)
	}
	terminal_ring, ring_status := system.ring_open(ring_handle)
	text_address, map_status := system.memory_map(text_handle)
	if ring_status != .Ok || map_status != .Ok {
		system.log(.Error, "grid_terminal: cannot map terminal ring or text region")
		system.stop(.Failed)
	}
	text_region := ([^]u8)(text_address)[:terminal_records.TEXT_SIZE]
	columns := 80
	rows := 25
	if col_val := int(ctx.values[terminal_records.VALUE_COLUMNS]); col_val >= 20 && col_val <= grid_renderer.GRID_COLUMNS_LIMIT {
		columns = col_val
	}
	if row_val := int(ctx.values[terminal_records.VALUE_ROWS]); row_val >= 8 && row_val <= grid_renderer.GRID_ROWS_LIMIT {
		rows = row_val
	}
	grid_renderer.grid_init(&screen, columns, rows, .Dark)
	// Direct framebuffer surface when provided in the display slot.
	canvas: graphics.Canvas
	if fb_handle := ctx.handles[system.GRANT_DISPLAY]; fb_handle != 0 {
		if fb_addr, fb_status := system.memory_map(fb_handle, {.Write}); fb_status == .Ok {
			fb_w := columns * graphics.CELL_WIDTH
			fb_h := rows * graphics.CELL_HEIGHT
			canvas = {pixels = ([^]graphics.Color)(fb_addr), width = fb_w, height = fb_h, stride = fb_w}
		}
	}

	read_offset: u64 = 0
	edit_row := rows - 1
	system.log(.Info, "grid_terminal: ready")

	for {
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
			switch kind {
			case .None, .Status, .Hint:
			case .Clear:
				grid_renderer.grid_init(&screen, columns, rows, .Dark)
				output_row = 0
			case .Text:
				style := transmute(terminal_records.Style)record.values[0]
				tone, ok := terminal_records.tone_of_byte(style.tone)
				fg := grid_renderer.grid_tone_color(ok ? tone : .Default, .Dark)
				bg := graphics.colors_for_contrast_mode(.Standard, true).background
				if .Reverse in style.flags {
					fg, bg = bg, fg
				}
				for i in 0 ..< min(count, screen.columns) {
					grid_renderer.grid_cell_set(&screen, output_row, i, rune(text_slice[i]), fg, bg)
				}
				if .End_Line in style.flags {
					output_row = (output_row + 1) % max(edit_row, 1)
				}
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
				if has_pending_edit_runs {
					edit_runs = pending_edit_runs
					has_pending_edit_runs = false
				} else {
					edit_runs = {}
				}
				grid_renderer.grid_write_edit_line(&screen, edit_row, text_slice[:count], &edit_runs, record.values[1], .Dark)
			case .List_Row:
				row_index := int(record.values[0])
				if row_index >= 0 && row_index < terminal_records.LIST_ROWS {
					row := &list_keeping.next[row_index]
					copy(row.text[:count], text_slice[:count])
					row.length = count
					row.name_length = min(int(record.values[1]), count)
				}
			case .List:
				n := min(int(record.values[0]), terminal_records.LIST_ROWS)
				list_keeping.shown.row_count = n
				list_keeping.shown.chosen = record.values[1] == terminal_records.NO_CHOICE ? -1 : int(record.values[1])
				list_keeping.shown.anchor = int(record.values[4])
				for i in 0 ..< n {
					list_keeping.shown.rows[i] = list_keeping.next[i]
				}
			}
		}
		if canvas.pixels != nil {
			_ = grid_renderer.grid_present_dirty(&screen, canvas, &list_keeping.shown, edit_row, .Dark)
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &terminal_ring.commands)
		_ = system.wait_end(&wait, system.time() + 16)
	}
}
