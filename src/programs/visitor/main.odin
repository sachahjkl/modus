// A program that is not in the boot image: the test of a disk program
// (docs/MODULE_CONTRACT.md, "A program from a disk").
//
// **What it is for.** The root service starts a program from a module file
// that the storage service holds, when the hash of the bytes is the hash
// that the principal named. Such a program has no row in the tables of the
// root service, so it receives no grant. This program says what it
// received.
//
// **Start**: `start_from_disk("visitor", hash)` in the console, on a
// machine whose data disk holds the store `programs` with its file. The
// kernel tool writes that disk for the test part `disk_programs`, and
// prints the hash. `start("visitor")` is refused: the boot image has no
// such module.
//
// **Grants**: none. It is not named in `grants_of`.
//
// **What a reader sees.** Three lines on the log: "visitor: ok", the
// handles of its context, and the refusal of a ring to the root service. It
// opens no window.
package visitor

import op "modus:contract/operation"
import "modus:support/system"

// The entry of visitor: it writes what its context holds, then sleeps
// until it is stopped.
//
// 1. It counts the handles of its context that are not the ring to the
//    compositor, the log or its budget: each one would be a grant. The
//    count must be 0.
// 2. It opens the handle of the root ring. The handle is 0, so the open
//    gives `Bad_Handle`: the program can ask the root service for nothing.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log("visitor: ok, a program that the boot image does not hold")
	granted := 0
	for handle, index in ctx.handles {
		if handle != 0 && index != system.GRANT_DISPLAY && index != op.CONTEXT_LOG && index != op.CONTEXT_BUDGET {
			granted += 1
		}
	}
	if granted == 0 && ctx.handles[system.GRANT_DISPLAY] != 0 && ctx.handles[op.CONTEXT_BUDGET] != 0 {
		system.log("visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must")
	} else {
		system.log("visitor: the context holds ", u64(granted), " handles of a grant: WRONG")
	}
	_, status := system.ring_open(ctx.handles[system.GRANT_ROOT])
	if ctx.handles[system.GRANT_ROOT] == 0 && status == .Bad_Handle {
		system.log("visitor: no ring to the root service: the open of its handle is refused: as it must")
	} else {
		system.log("visitor: a ring to the root service opens with status ", status, ": WRONG")
	}
	for {
		system.sleep(system.WAIT_FOREVER)
	}
}
