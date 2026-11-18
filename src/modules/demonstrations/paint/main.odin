// A demonstration: drawing with the pointer.
//   left button: draw    right button: erase    click a color at the top    c: clear
//
// This program is also a service: it serves its exports while it runs.
// Another program draws on the paper with isolated calls. The calls execute
// in the one thread of this program, between two input events.
//
// **What it is for.** It is the smallest program that is both an
// application and a service: the same window takes the pointer and the
// calls of the console, with one thread and no lock, because a call runs
// between two events. The top line counts the callers and the calls.
//
// **Start**: `start("paint")` in the console, or the bar of the desktop.
// Then, from the console: `connect("paint")`, `paint.line(0, 0, 479, 295,
// 1)`, `paint.write(20, 20, "hello", 3)`. The log has "paint: ok" when the
// window opens.
//
// **Grants**, as the root service gives them:
//
// - **Serve**: its exports, for the console.
//
// **The paper**: 480 by 296 pixels under a palette of 24 pixels. The
// colors of the palette are numbered 0 to 5: black, red, green, blue,
// yellow, violet. The paper is not kept: a new start gives a clean paper.
package paint

import "modus:contract/errors"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

WIDTH :: 480
HEIGHT :: 320
PALETTE_HEIGHT :: 24
PALETTE_CELL :: 40
COLOR_PAPER :: 0xF4F1EA

@(rodata)
colors := [?]graphics.Color{0x202428, 0xD03838, 0x2E9E4A, 0x2F6FD0, 0xE0A020, 0x9040C0}

drawn: i64 // The lines that calls drew.

// The paper is a picture of this program (a Picture record of the interface
// package). paper_generation changes with each change of its pixels. The
// palette and the top line are records.
PAPER_HEIGHT :: HEIGHT - PALETTE_HEIGHT
paper_pixels: [WIDTH * PAPER_HEIGHT]graphics.Color
paper_generation: u32
// The one picture memory of the draw tables: the drawing module reads the
// paper there.
picture_memories: [1][]graphics.Color
window_memory: interface.Window_Memory(64, 256)

// The key of the window, in its action bar.
// A procedure, not a global array: an item is made by a call, and a
// freestanding program runs no call before its entry.
bar_items :: proc "contextless" () -> [1]interface.Action_Bar_Item {
	return {interface.action_bar_item("clear", 1, "c")}
}
bar: interface.Action_Bar_State

// key_run runs one key: a typed key, or the key of the item of the action
// bar that a press ran.
key_run :: proc "contextless" (press: interface.Key_Press) {
	if press.character == 'c' {
		clear()
	}
}

paper :: proc "contextless" () -> graphics.Canvas {
	paper_generation += 1
	return {pixels = raw_data(paper_pixels[:]), width = WIDTH, height = PAPER_HEIGHT, stride = WIDTH}
}

// line draws a line on the paper, with a color of the palette (0 to 5). A point off the paper is fine: the paper shows the part of the line on it.
//
// The line is 3 pixels wide. A coordinate beyond 4096 in either direction is taken as 4096: the paper is far
// smaller, so the visible part does not change.
//
// - **from_x**, **from_y**: the first point, in pixels of the paper (0, 0 is its top left corner).
// - **to_x**, **to_y**: the last point.
// - **color**: the number of a color of the palette, 0 to 5.
//
// The result is the count of lines that calls drew since the last clear. It fails with -1 and an error record:
// `Bad_Value` when the color is not 0 to 5; the record names the fifth argument.
//
// Example: `paint.line(0, 0, 479, 295, 1)` draws a red diagonal.
@(export, link_name = "line")
line :: proc "c" (from_x, from_y, to_x, to_y, color: i64, error: ^errors.Error_Record) -> i64 {
	if color < 0 || color >= i64(len(colors)) {
		return errors.fail(error, -1, .Bad_Value, .None, 5, color, i64(len(colors) - 1))
	}
	limit :: 4096
	graphics.line(paper(), int(clamp(from_x, -limit, limit)), int(clamp(from_y, -limit, limit)), int(clamp(to_x, -limit, limit)), int(clamp(to_y, -limit, limit)), 3, colors[color])
	drawn += 1
	return drawn
}

// write draws a text on the paper, with a color of the palette (0 to 5).
//
// The text is drawn with the font of the system, from its top left corner. A text that passes the edge of the
// paper is cut there.
//
// - **x**: 0 to 479, the left of the text.
// - **y**: 0 to 295, the top of the text: the paper has 296 rows.
// - **text**: the bytes of the text.
// - **color**: the number of a color of the palette, 0 to 5.
//
// The result is the count of bytes of the text. It fails with -1 and an error record: `Bad_Value` when x is not 0
// to 479, when y is not 0 to 295, or when the color is not 0 to 5; the record names the argument.
@(export, link_name = "write")
write :: proc "c" (x, y: i64, text: ^string, color: i64, error: ^errors.Error_Record) -> i64 {
	switch {
	case x < 0 || x >= WIDTH:
		return errors.fail(error, -1, .Bad_Value, .None, 1, x, WIDTH - 1)
	case y < 0 || y >= PAPER_HEIGHT:
		return errors.fail(error, -1, .Bad_Value, .None, 2, y, PAPER_HEIGHT - 1)
	case color < 0 || color >= i64(len(colors)):
		return errors.fail(error, -1, .Bad_Value, .None, 4, color, i64(len(colors) - 1))
	}
	graphics.text(paper(), int(x), int(y), text^, colors[color])
	return i64(len(text))
}

// clear erases the paper.
//
// It also sets the count of lines that [lines](paint.lines) gives back to 0. The key c in the window does the
// same. It has no parameter, no result, and never fails.
@(export, link_name = "clear")
clear :: proc "c" () {
	graphics.clear(paper(), COLOR_PAPER)
	drawn = 0
}

// lines gives the count of lines that calls drew since the last clear.
//
// Only the calls of [line](paint.line) count: the lines that the pointer draws do not. A test draws through
// calls, then reads this count to check that each call ran one time.
@(export, link_name = "lines")
lines :: proc "c" () -> i64 {
	return drawn
}

// The entry of paint: it opens its service and its window, then runs the
// calls and the events of the pointer in one loop until the principal
// closes the window.
//
// With no window it stops with the code 1. Each turn draws the palette, the
// counts of the callers and the paper, then waits for an event or a call.
// The calls run first, then the events: the left button draws, the right
// button erases with a wide line, a click on the palette chooses a color,
// and the key c clears the paper.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "paint")
	if !ok {
		system.stop(1)
	}
	paper_picture := paper()
	graphics.clear(paper_picture, COLOR_PAPER)
	picture_memories[0] = paper_pixels[:]
	window_memory.drawing.now.picture_memories = picture_memories[:]
	window_memory.drawing.before.picture_memories = picture_memories[:]
	color := colors[0]
	last_x, last_y := 0, 0
	drawing := false
	system.log("paint: ok")
	for {
		frame := interface.window_frame_start(&window_memory, &window)
		interface.action_bar_input_take(&frame, &bar)
		table := frame.table
		// The element name of the cell of each color: a machine test
		// presses "red".
		color_names := [len(colors)]string{"dark", "red", "green", "blue", "yellow", "violet"}
		for index in 0 ..< len(colors) {
			interface.draw_rectangle(table, index * PALETTE_CELL, 0, PALETTE_CELL, PALETTE_HEIGHT, colors[index])
			interface.element_name(&frame, {index * PALETTE_CELL, 0, PALETTE_CELL, PALETTE_HEIGHT}, color_names[index])
			if colors[index] == color {
				// The chosen color: a white border of 3 pixels.
				left := index * PALETTE_CELL
				interface.draw_rectangle(table, left, 0, PALETTE_CELL, 3, 0xFFFFFF)
				interface.draw_rectangle(table, left, PALETTE_HEIGHT - 3, PALETTE_CELL, 3, 0xFFFFFF)
				interface.draw_rectangle(table, left, 3, 3, PALETTE_HEIGHT - 6, 0xFFFFFF)
				interface.draw_rectangle(table, left + PALETTE_CELL - 3, 3, 3, PALETTE_HEIGHT - 6, 0xFFFFFF)
			}
		}
		// The rest of the top line: the calls that this program served, and
		// the action bar of its key (docs/INTERFACE.md, "4.4 The action
		// bar"), whose item stands from the right edge.
		x := len(colors) * PALETTE_CELL
		interface.draw_rectangle(table, x, 0, WIDTH - x, PALETTE_HEIGHT, COLOR_PAPER)
		if service.connected != 0 || service.calls != 0 {
			x = interface.draw_text(table, x + 10, 4, "callers ", 0x606468)
			x = interface.draw_unsigned(table, x, 4, u64(service.connected), 0x2F6FD0)
			x = interface.draw_text(table, x + 8, 4, "calls ", 0x606468)
			x = interface.draw_unsigned(table, x, 4, service.calls, 0x2F6FD0)
		}
		interface.draw_picture(table, 0, PALETTE_HEIGHT, paper_picture, paper_generation)
		bar_left := x + 16
		items := bar_items()
		bar_result := interface.action_bar(&frame, {bar_left, 0, WIDTH - bar_left, PALETTE_HEIGHT}, items[:], &bar, {alignment = .Right})
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		if bar_result.ran {
			key_run(bar_result.run)
			continue
		}

		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		for event in display.next_event(&window) {
			switch event.kind {
			case .Key:
				if !event.pressed {
					continue
				}
				// The open list of the action bar takes its keys first.
				press := interface.Key_Press{code = event.code, character = event.character, modifiers = event.modifiers}
				outcome := interface.action_bar_key(&bar, press)
				if outcome.ran {
					key_run(outcome.run)
				}
				if !outcome.taken {
					key_run(press)
				}
			case .Pointer:
				// The action bar takes the pointer from the input of the
				// next frame; a press on it does not paint.
				interface.input_add(&window_memory.drawing.input, event)
				if !drawing && interface.action_bar_takes_pointer(&bar, event.x, event.y) {
					continue
				}
				if event.buttons == 0 {
					drawing = false
					continue
				}
				if event.y < PALETTE_HEIGHT && !drawing {
					if event.x >= 0 && event.x / PALETTE_CELL < len(colors) {
						color = colors[event.x / PALETTE_CELL]
					}
					continue
				}
				erase := event.buttons & display.BUTTON_RIGHT != 0
				y := max(event.y, PALETTE_HEIGHT + 2)
				if drawing {
					graphics.line(paper(), last_x, last_y - PALETTE_HEIGHT, event.x, y - PALETTE_HEIGHT, erase ? 12 : 3, erase ? COLOR_PAPER : color)
				}
				last_x, last_y, drawing = event.x, y, true
			case .None, .Settings_Changed, .Go_To, .Resized, .Copy_Asked, .Pasted:
				// next_event never gives None, and this window does nothing for the other events.
			}
		}
	}
}
