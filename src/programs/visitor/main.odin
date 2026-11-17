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
// **Grants**: none by its name. It has no row in `program_roles`. After
// `allow("visitor", "store")`, its next start has the store of its
// nickname, `disk-visitor`.
//
// **What a reader sees.** Three lines on the log: "visitor: ok", the
// handles of its context, and the refusal of a ring to the root service.
// With a store, one line more: the count of its starts with that store,
// which it keeps there. It opens no window. The copy that the test builds
// with FAULTS_AFTER_THE_START writes one line more, then stops on a page
// fault: `stop_report("outsider_fault")` names its frames.
package visitor

import "base:intrinsics"
import op "modus:contract/operation"
import "modus:support/storage"
import "modus:support/system"

// The object of the store that holds the count of the starts.
VISITS_OBJECT :: "visits"

// True in the copy that the test builds outside the sources of the system
// (its module build file defines it): the copy is then another module, with
// another hash, which the debug image of the machine does not describe.
BUILT_OUTSIDE :: #config(BUILT_OUTSIDE, false)
// True in a second copy that the test builds outside the sources: after its
// first lines it writes to the address 0, three calls deep, so that the
// root service keeps its stop report and the debugger names its frames.
FAULTS_AFTER_THE_START :: #config(FAULTS_AFTER_THE_START, false)

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
// 4. In the copy built with FAULTS_AFTER_THE_START: it writes to the
//    address 0, three calls deep (fault_one).
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log("visitor: ok, a program that the boot image does not hold")
	when BUILT_OUTSIDE {
		system.log("visitor: built outside the sources of the system")
	}
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
	when FAULTS_AFTER_THE_START {
		fault_one(ctx)
	}
	sleep_for_ever()
}

// sleep_for_ever sleeps until the program is stopped. It and sleep_once are
// never inlined, so the entry keeps a frame at its call of sleep_for_ever,
// in the source of this program: the test of the debug object of a disk
// program waits for that frame of the entry, with its line.
sleep_for_ever :: #force_no_inline proc "contextless" () -> ! {
	for {
		sleep_once()
	}
}

sleep_once :: #force_no_inline proc "contextless" () {
	system.sleep(system.WAIT_FOREVER)
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

// The depth that each procedure of the fault writes after its call: no
// call is then the last instruction of a procedure, so each call keeps its
// frame and its return address, and the stop report has every level.
fault_depth: u64

// fault_one writes a line, then writes to the address 0 three calls deep.
// The address comes from a value of the context that no starter writes, so
// the compiler cannot prove that it is 0 and drop the write. A write that
// does not stop the program is a fault of the kernel: the line after it
// says so.
fault_one :: #force_no_inline proc "contextless" (ctx: ^system.Context) {
	system.log("visitor: writes to the address 0, three calls deep: its stop report names the frames of its source")
	fault_two(uintptr(ctx.values[14]))
	intrinsics.volatile_store(&fault_depth, 1)
	system.log("visitor: the write did not stop the program: WRONG")
}

fault_two :: #force_no_inline proc "contextless" (address: uintptr) {
	fault_three(address)
	intrinsics.volatile_store(&fault_depth, 2)
}

fault_three :: #force_no_inline proc "contextless" (address: uintptr) {
	intrinsics.volatile_store((^u64)(address), 1)
	intrinsics.volatile_store(&fault_depth, 3)
}
