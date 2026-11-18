// A disk process that imports a library module of the store `module_files`:
// the test of the import scan (docs/MODULE_CONTRACT.md, "A process from a
// disk").
//
// **What it is for.** Its import names the hash of the module
// `store_library`, which no boot image holds. The root service finds that
// file in the store `module_files` of the principal by the hash of its bytes,
// and the loader binds the import slot to it. This process calls the
// export and writes the result. It is also the disk process of the test
// that has a window: the menu of the windows and the monitor show it by its
// nickname, with the hash prefix of its file.
//
// **Start**: `start_from_disk("store_importer", hash)` in the console, on a
// machine whose data disk holds the store `module_files` with this file and the
// file of `store_library`. The modus tool writes that disk for the test
// part `disk_processes`, and prints the hashes.
//
// **Grants**: none by its name, as each disk process.
//
// **What a reader sees.** One line on the log: the result of `triple(14)`
// from the module of the store. A window with the same result. The window
// asks for the title `console`: the compositor names it `store_importer`,
// the nickname that the root service gave, so the window of a disk process
// cannot have the title of a process of the system. Its budget holds one
// process, so it starts no child under such a name either.
package store_importer

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

foreign _ {
	triple :: proc "c" (value: i64) -> i64 ---
}

WIDTH :: 320
HEIGHT :: 48
// The title that the process asks for. The compositor does not take it.
TITLE_ASKED :: "console"

window_memory: interface.Window_Memory(8, 256)

// The entry of store_importer: it calls the import one time, writes the
// line, shows the result in its window, then reads the events of its
// window until it is stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	result := triple(14)
	if result == 42 {
		system.log("store_importer: triple(14) of the module store_library of the store module_files gives 42: as it must")
	} else {
		system.log("store_importer: triple(14) gives ", u64(result), ", and 42 is the answer: WRONG")
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, TITLE_ASKED)
	if !ok {
		for {
			system.sleep(system.WAIT_FOREVER)
		}
	}
	for {
		frame := interface.window_frame_start(&window_memory, &window)
		x := interface.draw_text(frame.table, 16, 16, "triple(14) = ", graphics.colors.dim)
		interface.draw_unsigned(frame.table, x, 16, u64(result), graphics.colors.text)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		// The window is drawn again after each event, as a change of the
		// settings changes the font; another event gives the same picture.
		display.wait(&window)
		for _ in display.next_event(&window) {}
	}
}
