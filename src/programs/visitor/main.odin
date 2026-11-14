// A program that is not in the boot image: the test of a disk program
// (docs/MODULE_CONTRACT.md, "A program from a disk").
//
// **What it is for.** The root service starts a program from a module file
// that the storage service holds, when the hash of the bytes is the hash
// that the principal named. Such a program has no row in the tables by name
// of the root service, so it receives no grant but the grants of its
// nickname in the disk grant table. This program says what it received, and
// uses the store of its nickname when it has one.
//
// **Start**: `start_from_disk("visitor", hash)` in the console, on a
// machine whose data disk holds the store `programs` with its file. The
// modus tool writes that disk for the test part `disk_programs`, and
// prints the hash. `start("visitor")` is refused: the boot image has no
// such module.
//
// **Grants**: none by its name. It is not named in `grants_of`. After
// `allow("visitor", "store")`, its next start has the store of its
// nickname, `disk-visitor`.
//
// **What a reader sees.** Three lines on the log: "visitor: ok", the
// handles of its context, and the refusal of a ring to the root service.
// With a store, one line more: the count of its starts with that store,
// which it keeps there. It opens no window.
package visitor

import op "modus:contract/operation"
import "modus:support/storage"
import "modus:support/system"

// The object of the store that holds the count of the starts.
VISITS_OBJECT :: "visits"

// The entry of visitor: it writes what its context holds, then sleeps
// until it is stopped.
//
// 1. It counts the handles of its context that are not the ring to the
//    compositor, the log, its budget or a store: each one would be a grant
//    that no command gives. The count must be 0.
// 2. It opens the handle of the root ring. The handle is 0, so the open
//    gives `Bad_Handle`: the program can ask the root service for nothing.
// 3. With a store: it reads the count of its starts, adds one, writes it,
//    and reads it again.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log("visitor: ok, a program that the boot image does not hold")
	client, has_store := storage.open(ctx)
	granted := 0
	for handle, index in ctx.handles {
		of_the_store := index == storage.GRANT_RING || index == storage.GRANT_REGION || index == storage.GRANT_SERVICE
		if handle != 0 && index != system.GRANT_DISPLAY && index != op.CONTEXT_LOG && index != op.CONTEXT_BUDGET && !(has_store && of_the_store) {
			granted += 1
		}
	}
	if granted == 0 && ctx.handles[system.GRANT_DISPLAY] != 0 && ctx.handles[op.CONTEXT_BUDGET] != 0 {
		if has_store {
			system.log("visitor: the context holds the log, a window, the budget and a store, and no other handle of a grant: as it must")
		} else {
			system.log("visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must")
		}
	} else {
		system.log("visitor: the context holds ", u64(granted), " handles of a grant: WRONG")
	}
	_, status := system.ring_open(ctx.handles[system.GRANT_ROOT])
	if ctx.handles[system.GRANT_ROOT] == 0 && status == .Bad_Handle {
		system.log("visitor: no ring to the root service: the open of its handle is refused: as it must")
	} else {
		system.log("visitor: a ring to the root service opens with status ", status, ": WRONG")
	}
	if has_store {
		visits_count(&client)
	}
	for {
		system.sleep(system.WAIT_FOREVER)
	}
}

// visits_count reads the count of the starts from the store, writes one
// more, and reads it again: the store of the nickname keeps it across a
// stop, a move of the nickname and a restart of the machine.
visits_count :: proc "contextless" (client: ^storage.Client) {
	buffer: [16]u8
	bytes, found, status := storage.read(client, storage.ROOT, VISITS_OBJECT, buffer[:])
	if status != .Ok {
		system.log("visitor: the store did not give the count: status ", u64(status), ": WRONG")
		return
	}
	before: u64
	if found {
		if len(bytes) != 8 {
			system.log("visitor: the count in the store has ", u64(len(bytes)), " bytes, not 8: WRONG")
			return
		}
		before = transmute(u64)[8]u8{bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]}
	}
	now := before + 1
	written := transmute([8]u8)now
	if _, write_status := storage.write(client, storage.ROOT, VISITS_OBJECT, written[:]); write_status != .Ok {
		system.log("visitor: the store did not keep the count: status ", u64(write_status), ": WRONG")
		return
	}
	again, found_again, read_status := storage.read(client, storage.ROOT, VISITS_OBJECT, buffer[:])
	read_back: u64
	if len(again) == 8 {
		read_back = transmute(u64)[8]u8{again[0], again[1], again[2], again[3], again[4], again[5], again[6], again[7]}
	}
	if read_status != .Ok || !found_again || len(again) != 8 || read_back != now {
		system.log("visitor: the count read again is not the count written: WRONG")
		return
	}
	system.log("visitor: the store of its nickname holds the visit ", now, ", read again: as it must")
}
