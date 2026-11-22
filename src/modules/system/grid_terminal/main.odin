// Full-screen direct framebuffer monospace grid terminal for modus:terminal
// (src/md/features/console_renderers.md, "Variant B: grid_terminal").
//
// Reads typed terminal records from console on the shared terminal ring
// through the renderer intake of modus:terminal, and blits a Spleen 8x16
// monospace grid with Modus 24-bit colors, Lex syntax highlighting, cursor,
// and interactive completion popup directly onto the framebuffer. It reads
// the keys of the input service from the input ring, in place of the
// compositor, and sends each press to its process: it is the one process
// that writes the screen. Zero compositor, zero window chrome, zero
// TrueType.
package grid_terminal

import "internal:grid_terminal/grid_renderer"
import "modus:contract/ring"
import "modus:graphics"
import "modus:system"
import terminal_records "modus:terminal"

// Working memory for the terminal ring mapping, text region, cell grid and
// the intake with its completion list, and one thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 64, threads = 1}

// The size of the grid when the context gives none in the bounds.
DEFAULT_COLUMNS :: 80
DEFAULT_ROWS :: 25

// The largest side of a framebuffer, in pixels: a value past it is no
// screen, and a product of two such values stays far from the bound of an
// int.
SCREEN_SIDE_LIMIT :: 16384

screen: grid_renderer.Grid_Screen
intake: terminal_records.Renderer_Intake
output: grid_renderer.Grid_Output

// framebuffer_open maps the framebuffer of the context, and gives a canvas
// of its size, or a canvas with no pixels when it is absent or its size is
// not one that a screen has.
@(private = "file")
framebuffer_open :: proc "contextless" (ctx: ^system.Context) -> graphics.Canvas {
	handle := ctx.handles[terminal_records.GRANT_DEVICE]
	width := ctx.values[terminal_records.VALUE_SCREEN_WIDTH]
	height := ctx.values[terminal_records.VALUE_SCREEN_HEIGHT]
	pixels_per_line := ctx.values[terminal_records.VALUE_SCREEN_PIXELS_PER_LINE]
	if handle == 0 || width == 0 || height == 0 || pixels_per_line < width || width > SCREEN_SIDE_LIMIT || height > SCREEN_SIDE_LIMIT || pixels_per_line > SCREEN_SIDE_LIMIT {
		return {}
	}
	address, status := system.memory_map(handle, {.Write})
	if status != .Ok {
		return {}
	}
	return {pixels = ([^]graphics.Color)(address), width = int(width), height = int(height), stride = int(pixels_per_line)}
}

@(export)
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_handle := ctx.handles[terminal_records.GRANT_RING]
	text_handle := ctx.handles[terminal_records.GRANT_TEXT]
	if ring_handle == 0 || text_handle == 0 {
		system.log(.Error, "grid_terminal: missing terminal ring or text grant")
		system.stop(.Failed)
	}
	terminal_ring, ring_status := system.ring_open(ring_handle)
	text_address, map_status := system.memory_map(text_handle, {})
	if ring_status != .Ok || map_status != .Ok {
		system.log(.Error, "grid_terminal: cannot map terminal ring or text region")
		system.stop(.Failed)
	}
	intake = terminal_records.renderer_intake_make(([^]u8)(text_address)[:terminal_records.TEXT_SIZE])
	canvas := framebuffer_open(ctx)
	if canvas.pixels == nil {
		system.log(.Error, "grid_terminal: no framebuffer of a size that a screen has")
		system.stop(.Failed)
	}
	// The input ring of the input service; with none, the grid shows the
	// console and no key reaches it.
	input_ring: ring.Ring
	has_input := false
	if input_handle := ctx.handles[terminal_records.GRANT_INPUT]; input_handle != 0 {
		opened, input_status := system.ring_open(input_handle)
		if input_status == .Ok {
			input_ring, has_input = opened, true
		}
	}
	// The grid of the process, cut to the cells that the screen holds.
	columns := DEFAULT_COLUMNS
	rows := DEFAULT_ROWS
	if value := ctx.values[terminal_records.VALUE_COLUMNS]; value >= 20 && value <= grid_renderer.GRID_COLUMNS_LIMIT {
		columns = int(value)
	}
	if value := ctx.values[terminal_records.VALUE_ROWS]; value >= 8 && value <= grid_renderer.GRID_ROWS_LIMIT {
		rows = int(value)
	}
	columns = max(min(columns, canvas.width / graphics.CELL_WIDTH), 1)
	rows = max(min(rows, canvas.height / graphics.CELL_HEIGHT), 2)
	grid_renderer.grid_init(&screen, columns, rows, .Dark)
	palette := graphics.colors_for_contrast_mode(.Standard, true)
	// The screen outside the grid: the background, once.
	graphics.fill(canvas, 0, 0, canvas.width, canvas.height, palette.background)
	// The last row is the edit line; the rows above it are the output.
	edit_row := rows - 1
	system.log(.Info, "grid_terminal: ready")

	for {
		if has_input {
			for record in system.receive(&input_ring.commands) {
				if key, ok := grid_renderer.key_of_input_record(record); ok {
					_ = system.send(&terminal_ring.completions, ring.Record{kind = u32(terminal_records.Input.Key), tag = key.code, values = {0 = u64(key.character), 1 = u64(key.modifiers), 2 = key.serial}})
				}
			}
		}
		for record in system.receive(&terminal_ring.commands) {
			event := terminal_records.renderer_intake_take(&intake, record)
			switch event.step {
			case .None, .Status, .Hint:
			// The grid keeps no status line and no hint line.
			case .List:
				grid_renderer.grid_list_changed(&screen)
			case .Clear:
				grid_renderer.grid_init(&screen, columns, rows, .Dark)
				output = {}
			case .Text:
				style := event.style
				tone, ok := terminal_records.tone_of_byte(style.tone)
				foreground := grid_renderer.grid_tone_color(ok ? tone : .Default, .Dark)
				if .Color in style.flags {
					foreground = graphics.Color(style.color & 0x00FF_FFFF)
				}
				background := palette.background
				if .Reverse in style.flags {
					foreground, background = background, foreground
				}
				grid_renderer.grid_write_output(&screen, &output, intake.text[:intake.text_length], foreground, background, .End_Line in style.flags, edit_row, .Dark)
			case .Edit:
				edit := &intake.edit
				cursor := edit.has_cursor ? u64(edit.cursor) : terminal_records.NO_CURSOR
				grid_renderer.grid_write_edit_line(&screen, edit_row, edit.text[:edit.length], &edit.code, cursor, .Dark)
			}
		}
		_ = grid_renderer.grid_present_dirty(&screen, canvas, &intake.list.shown, edit_row, .Dark)
		// The grid has no blinking cursor: it waits for a record of one of
		// its two rings, with no deadline.
		wait := system.wait_begin()
		system.wait_records(&wait, &terminal_ring.commands)
		if has_input {
			system.wait_records(&wait, &input_ring.commands)
		}
		_ = system.wait_end(&wait)
	}
}
