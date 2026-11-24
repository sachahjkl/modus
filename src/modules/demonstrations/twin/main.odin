// A module that the process `frames` starts several times, to show the
// shared code of a module and a page that two processes share (package
// modus:twins). The value MODE of its context says what it does.
//
// **What it is for.** Two facts of the memory of the system need a second
// process to show them: the code pages of one module are shared between
// the processes that run it, and they cannot be written; and one page that
// two processes map is one frame. `frames` reads its own page table and the
// counts of the kernel while its twins run.
//
// **Start**: only `frames` starts it, from the boot image. Its row of
// `start_grant_sets` has no grant. It has no window and writes nothing on the
// log.
package twin

import "base:intrinsics"
import "modus:system"
import "modus:twins"

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
		system.log_fact(.Info, Mode_Word_Unknown{mode_word = ctx.values[twins.VALUE_MODE]})
		system.stop(.Refused)
	}
	switch mode {
	case .Wait:
	case .Write_Page:
		// The first use of the page in this process: the page has the frame
		// that the process `frames` took, or it takes it now.
		address, status := system.memory_map(ctx.handles[twins.GRANT_PAGE])
		if status != .Succeeded {
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
	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		system.sleep(system.WAIT_FOREVER)
	}
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}
