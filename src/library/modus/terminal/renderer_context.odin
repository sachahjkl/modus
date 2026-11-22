package terminal_records

import op "modus:contract/operation"
import "modus:system"

// The context of a terminal that draws no window: serial_terminal and
// grid_terminal (src/md/features/console_renderers.md, "The context of a
// renderer"). The root service writes it with renderer_context_of, and each
// renderer reads its slots by these names.

// The handle of the device that the renderer draws on: the ports of the
// second serial port, or the framebuffer.
GRANT_DEVICE :: system.GRANT_TERMINAL_DEVICE
// grid_terminal: the input ring of the input service.
GRANT_INPUT :: system.GRANT_TERMINAL_INPUT

// grid_terminal: the framebuffer, in pixels.
VALUE_SCREEN_WIDTH :: system.GRANT_VALUE_TERMINAL_SCREEN_WIDTH
VALUE_SCREEN_HEIGHT :: system.GRANT_VALUE_TERMINAL_SCREEN_HEIGHT
VALUE_SCREEN_PIXELS_PER_LINE :: system.GRANT_VALUE_TERMINAL_SCREEN_PIXELS_PER_LINE

// The ports of the second serial port (COM2), which serial_terminal drives.
// The first serial port (COM1, 0x3F8) is the log of the kernel: the text of
// a terminal never mixes with the lines of the log.
SERIAL_PORT_FIRST :: 0x2F8
SERIAL_PORT_COUNT :: 8

// The handles that a renderer receives from the root service.
Renderer_Handles :: struct {
	device: system.Grant, // The ports of the serial port, with no right; or the framebuffer, with Read and Write.
	input:  system.Grant, // grid_terminal: the input ring, with Read and Write. Handle 0: none.
	ring:   system.Handle, // The terminal ring.
	text:   system.Handle, // The text region.
	writer: system.Handle, // The process that writes in it.
	log:    system.Grant, // The log, with the rights that the starter chose.
}

// The framebuffer of grid_terminal. Zero: serial_terminal, which has none.
Renderer_Screen :: struct {
	width:           u64,
	height:          u64,
	pixels_per_line: u64,
}

// renderer_context_of writes the context of a renderer through the
// checked writes of the context: the device, the input ring when there is
// one, the terminal ring, the text region with Read only, the process that
// writes, the log, the name of the process, the size of the text grid, and
// the framebuffer when there is one. A slot or a value that the caller wrote
// already is refused, and its refusal stays in the record.
renderer_context_of :: proc "contextless" (grants: ^system.Context_Grants, values: ^system.Context_Values, handles: Renderer_Handles, name: [4]u64, columns, rows: u64, screen: Renderer_Screen) {
	system.grant_put(grants, GRANT_DEVICE, handles.device)
	if handles.input.handle != 0 {
		system.grant_put(grants, GRANT_INPUT, handles.input)
	}
	system.grant_put(grants, GRANT_RING, {handles.ring, {.Read, .Write}})
	system.grant_put(grants, GRANT_TEXT, {handles.text, {.Read}})
	system.grant_put(grants, GRANT_PROCESS, {handles.writer, {.Read}})
	system.grant_put(grants, op.CONTEXT_LOG, handles.log)
	words := name
	system.values_put(values, VALUE_NAME, words[:])
	system.value_put(values, VALUE_COLUMNS, columns)
	system.value_put(values, VALUE_ROWS, rows)
	if screen != {} {
		system.value_put(values, VALUE_SCREEN_WIDTH, screen.width)
		system.value_put(values, VALUE_SCREEN_HEIGHT, screen.height)
		system.value_put(values, VALUE_SCREEN_PIXELS_PER_LINE, screen.pixels_per_line)
	}
}
