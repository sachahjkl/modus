// A system tool: how the machine started, at any time. It draws the boot
// display (package bootscreen) in a window, with the records that the
// kernel has now. It needs the grant to inspect the machine, and the boot
// image.
//
// **What it is for.** The [boot display](term:boot-display) is on the
// screen only while the machine starts; the compositor then takes the
// screen. This process shows the same picture again, in a window, at any
// time: the [stages](term:stage) of the start with their times, the memory
// ranges of the firmware, the processors, the files of the
// [boot image](term:boot-image) and the check of their hashes, and the
// processes that run. A reader who looks for the cause of a slow or odd
// start reads it here, after the start.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("boot")` in the console. The window is the boot display at its
// base size (`bootscreen.WIDTH` by `bootscreen.HEIGHT` logical pixels), as a picture at the scale of the desktop, with the message
// "the desktop runs". It draws again each 500 ms, with the records of the
// kernel of that time. At its first draw it writes `boot: ok, <count>
// stages, <count> memory ranges, <count> processes` on the log.
//
// **Its grants**: **Inspect**, the machine handle that reads the
// [boot record](term:boot-record) and the other reports of the kernel
// (`src/library/support/bootscreen/collect`), and **Image**, the boot image, read-only,
// for the names and the kinds of its files. It changes nothing.
//
// **What it shows of the design.** One picture, three parts of the system
// that draw it: the boot program, the root service and this process draw the same record
// (`bootscreen.Data`) with the same package; the kernel draws nothing. The
// rules of the picture are in docs/DESIGN.md.
package boot

import "modus:support/bootscreen"
import "modus:support/bootscreen/collect"
import "modus:support/display"
import "modus:support/interface"
import "modus:support/system"

INTERVAL :: 500

// The size of the panel, as literals of this package, so the tool reads
// the window of the budget; the assertions keep them the panel.
WIDTH :: 976
#assert(WIDTH == bootscreen.WIDTH)
HEIGHT :: 708
#assert(HEIGHT == bootscreen.HEIGHT)
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (1350 pages): its module, its
// stack, its records of the kernel and its glyph memory. And the picture
// of the logical size in which it draws by hand (interface.Hand_Picture):
// 976 x 708 pixels of 4 bytes, 675 pages. 698 + 675 = 1373. The tool
// counts the window at the window bound (docs/MODULE_CONTRACT.md, "The
// budget that a module asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1373, window_width = WIDTH, window_height = HEIGHT}

data: bootscreen.Data

// The picture of the window: the boot display at its base size, in
// logical pixels, which the drawing module puts on the screen at the scale
// of the desktop (interface.Hand_Picture).
hand_picture: interface.Hand_Picture

// entry opens the window of the boot display and draws it again each
// 500 ms, until the process is stopped.
//
// It maps the boot image when the grant gives it. Each turn reads the records of
// the kernel (`collect.data`), draws the display into the window, and
// presents it. The first turn writes `boot: ok, ...` on the log. The
// events of the window are read and dropped: the window takes no input.
// With no window, the process stops with `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "boot")
	if !ok || interface.hand_picture_open(&hand_picture, &window) != .Ok {
		system.stop(.Failed)
	}
	machine := ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		data.image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	data.message = "the desktop runs"
	data.state = .Ready
	logged := false
	for {
		collect.data(&data, machine)
		// The canvas is the picture that the compositor does not read,
		// after it took the picture before: the whole canvas is drawn.
		if display.canvas_wait(&window) {
			// The procedure of the screen: a canvas of the base size
			// takes scale 1, as the other drawers find for that size.
			bootscreen.draw_screen(hand_picture.canvas, &data)
			interface.hand_picture_show(&hand_picture, &window)
		}
		if !logged {
			logged = true
			system.log_fact(.Info, Boot_Shown{stages = u64(data.boot.stage_count), memory_ranges = u64(data.boot.range_count), processes = u64(data.process_total)})
		}
		for _ in display.next_event(&window) {}
		system.sleep(system.time() + INTERVAL)
	}
}
