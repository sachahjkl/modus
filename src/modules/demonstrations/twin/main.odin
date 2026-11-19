// A module that the process `frames` starts several times, to show the
// shared code of a module and a page that two processes share (package
// modus:support/twins). The value MODE of its context says what it does.
//
// **What it is for.** Two facts of the memory of the system need a second
// process to show them: the code pages of one module are shared between
// the processes that run it, and they cannot be written; and one page that
// two processes map is one frame. `frames` reads its own page table and the
// counts of the kernel while its twins run.
//
// **Start**: only `frames` starts it, from the boot image. Its row of
// `process_roles` has no grant. It has no window and writes nothing on the
// log.
package twin

import "base:intrinsics"
import "modus:support/system"
import "modus:support/twins"

// The entry of twin: it does what its mode says, then sleeps until
// `frames` stops it.
//
// - `Twin_Mode.Write_Page`: it maps the shared page, writes the agreed
//   word in it, and wakes `frames`, which waits on that word. A page that
//   does not map stops it with `Failed`.
// - `Twin_Mode.Write_Code`: it writes one byte in its own code. The page
//   has no right Write, so the kernel stops the process as its own fault:
//   the expected result.
// - `Twin_Mode.Wait`: it only sleeps, as one more process that shares the
//   code of the module.
// - a word that names no mode: it writes a line and stops with `Refused`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	mode, mode_ok := twins.twin_mode_of_word(ctx.values[twins.VALUE_MODE])
	if !mode_ok {
		system.log(.Info, "twin: the mode ", ctx.values[twins.VALUE_MODE], " names no mode of a twin: nothing is done")
		system.stop(.Refused)
	}
	switch mode {
	case .Wait:
	case .Write_Page:
		// The first use of the page in this process: the page has the frame
		// that the process `frames` took, or it takes it now.
		address, status := system.memory_map(ctx.handles[twins.GRANT_PAGE])
		if status != .Ok {
			system.stop(.Failed)
		}
		word := (^u32)(address)
		intrinsics.volatile_store(word, twins.WORD)
		system.word_wake(word)
	case .Write_Code:
		// The code of this process is the shared code of the module: the
		// page has no Write, and the kernel stops this process.
		intrinsics.volatile_store((^u8)(rawptr(entry)), 0xC3)
	}
	for {
		system.sleep(system.WAIT_FOREVER)
	}
}
