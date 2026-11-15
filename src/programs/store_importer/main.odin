// A disk program that imports a library module of the store `programs`:
// the test of the import scan (docs/MODULE_CONTRACT.md, "A program from a
// disk").
//
// **What it is for.** Its import names the hash of the module
// `store_library`, which no boot image holds. The root service finds that
// file in the store `programs` of the principal by the hash of its bytes,
// and the loader binds the import slot to it. This program calls the
// export and writes the result. It is also the disk program of the test
// that has a window: the menu of the windows and the monitor show it by its
// nickname, with the hash prefix of its file.
//
// **Start**: `start_from_disk("store_importer", hash)` in the console, on a
// machine whose data disk holds the store `programs` with this file and the
// file of `store_library`. The modus tool writes that disk for the test
// part `disk_programs`, and prints the hashes.
//
// **Grants**: none by its name, as each disk program.
//
// **What a reader sees.** One line on the log: the result of `triple(14)`
// from the module of the store. A window with the same result. The window
// asks for the title `console`: the compositor names it `store_importer`,
// the nickname that the root service gave, so the window of a disk program
// cannot have the title of a program of the system. Its budget holds one
// program, so it starts no child under such a name either.
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
// The title that the program asks for. The compositor does not take it.
TITLE_ASKED :: "console"

records_now, records_before: [8]interface.Draw_Record
text_now, text_before: [256]u8
drawing: interface.Window_Drawing

// The entry of store_importer: it calls the import one time, writes the
// line, shows the result in its window, then reads the events of its
// window until it is stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	result := triple(14)
	if result == 42 {
		system.log("store_importer: triple(14) of the module store_library of the store programs gives 42: as it must")
	} else {
		system.log("store_importer: triple(14) gives ", u64(result), ", and 42 is the answer: WRONG")
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, TITLE_ASKED)
	if !ok {
		for {
			system.sleep(system.WAIT_FOREVER)
		}
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	for {
		frame := interface.window_frame_begin(&drawing, &window)
		interface.draw_rectangle(frame.table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
		x := interface.draw_text(frame.table, 16, 16, "triple(14) = ", graphics.COLOR_DIM)
		interface.draw_unsigned(frame.table, x, 16, u64(result), graphics.COLOR_TEXT)
		interface.window_frame_end(&drawing, &frame, &window)
		// The window is drawn again after each event, as a change of the
		// settings changes the font; another event gives the same picture.
		display.wait(&window)
		for _ in display.next_event(&window) {}
	}
}
