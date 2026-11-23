// A demonstration: an animation that the processor computes for each frame.
//
// **What it is for.** It is a load that never ends and never waits for an
// input: one thread computes each pixel of a picture of 320 by 200, about
// 30 times in one second, with integers only. It shows the share of the
// processor of a busy process in `monitor`, and the cost of a full picture
// for the compositor.
//
// **Start**: `start("plasma")` in the console, or the bar of the desktop.
// The log has "plasma: ok" after the first picture. Its row of
// `start_grant_sets` has no grant: a window is all that it needs.
//
// **How it computes**: a table of the sine in 256 steps of a turn, from
// `trigonometry.sine` once at the start, and a palette of 256 colors from
// three sines a third of a turn apart. Each pixel is the sum of four sines
// of its place and of the frame number, in integers.
package plasma

import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"
import "modus:trigonometry"

WIDTH :: 320
HEIGHT :: 200
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (125 pages): its module, its
// stack and its tables. The tool counts the window at the largest scale
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1923, window_width = WIDTH, window_height = HEIGHT}
FRAME_INTERVAL :: 33

sine: [256]i32 // One period, from -127 to 127: the index is the angle in 256ths of a turn.
palette: [256]graphics.Color
// The window is one picture of this process, shown with the interface
// package (a Picture record): the animation draws into it.
picture_pixels: [WIDTH * HEIGHT]graphics.Color
picture: graphics.Canvas
// The one picture memory of the draw table: the drawing module reads the
// picture there.
picture_memories: [1][]graphics.Color
records_now, records_before: [2]interface.Draw_Record
drawing: interface.Window_Drawing

// The entry of plasma: it builds the sine table and the palette, then
// computes and shows one picture every 33 ms for ever.
//
// With no window it stops with `Failed`. The time of each picture is
// fixed from the first one: after a slow picture, the next pictures follow
// with no sleep until the process is on time again.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "plasma")
	if !ok {
		system.stop(.Failed)
	}
	// The first half turn, rounded to the nearest whole number; the second
	// half is its negative, so the table is exactly antisymmetric.
	for i in 0 ..< 128 {
		value := i32(trigonometry.sine(f64(i) / 256) * 127 + 0.5)
		sine[i] = value
		sine[i + 128] = -value
	}
	for i in 0 ..< 256 {
		red := u32(128 + sine[i])
		green := u32(128 + sine[(i + 85) & 255])
		blue := u32(128 + sine[(i + 170) & 255])
		palette[i] = graphics.rgb(red, green, blue)
	}

	picture = {pixels = raw_data(picture_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	picture_memories[0] = picture_pixels[:]
	drawing = interface.window_drawing_of_picture(records_now[:], records_before[:], picture_memories[:])
	frame: u64
	next := system.time()
	for {
		t := int(frame)
		for y in 0 ..< HEIGHT {
			row := picture_pixels[y * WIDTH:]
			a := sine[(y * 2 + t) & 255]
			for x in 0 ..< WIDTH {
				value := a + sine[(x + t * 2) & 255] + sine[(x + y + t) & 255] + sine[((x * x + y * y) >> 7 + t * 3) & 255]
				row[x] = palette[(int(value) >> 1 + t) & 255]
			}
		}
		interface.show_picture(&drawing, &window, picture, u32(frame) + 1)
		if frame == 0 {
			system.log_fact(.Info, Running{})
		}
		frame += 1
		for _ in interface.window_next_event(&drawing, &window) {}
		next += FRAME_INTERVAL
		system.sleep(next)
	}
}
