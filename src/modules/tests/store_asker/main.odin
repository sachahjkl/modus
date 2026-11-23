// The asker of the machine test of the store picker
// (src/md/features/powerbox.md, "The picker ring"). It acts for its
// principal, and asks the trusted display for a store with
// powerbox_pick_store. It receives the number of the request and never
// the list: the principal picks on the trusted display, and the console
// reads the grant that holds. It then waits, so its grant holds, until the
// scenario stops it; at the hang bound it stops with a WRONG line.
//
// **Start**: `start("store_asker")` in the console of principal 0. **What
// a reader sees**: no window; one line "store_asker: ..." with the number
// of its request, or a line "store_asker: WRONG: ...".
package store_asker

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:system"

// A connection, a call and a wait: no table of its own.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 64}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	connection, file := display_connect(ctx)
	pick := module.export_find(file, "powerbox_pick_store")
	if pick == 0 {
		wrong("the holder of Display has no export powerbox_pick_store", 0)
	}
	name := "store_asker"
	mode := "read"
	arguments := [2]isolated.Argument{{text = transmute([]u8)name}, {text = transmute([]u8)mode}}
	error: errors.Error_Record
	result, outcome := system.call_isolated(&connection, file, pick, arguments[:], &error)
	if outcome != .Succeeded || result <= 0 {
		wrong("the trusted display opened no store picker; the result", u64(result))
	}
	system.log_fact(.Info, Picker_Asked{request = u64(result)})
	// The grant holds while this process runs: the scenario stops it.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		wait := system.wait_begin()
		system.wait_end(&wait, deadline)
	}
	wrong("the scenario did not stop this process within the hang bound; the milliseconds", system.TEST_HANG_BOUND_MILLISECONDS)
}

@(private = "file")
display_connect :: proc "contextless" (ctx: ^system.Context) -> (connection: system.Call_Connection, file: []u8) {
	requests_memory := ctx.handles[system.GRANT_ROOT]
	requests, ring_status := system.ring_open(requests_memory, receive_handles = true)
	if ring_status != .Ok {
		wrong("no root ring; the status", u64(ring_status))
	}
	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Ok {
		wrong("the boot image does not map; the status word", u64(map_status))
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	connected: call_outcome.Call_Outcome
	connection, connected = system.service_connection(&requests, 1, "display")
	if connected != .Succeeded {
		wrong("the root service gave no connection to the holder of Display; the call outcome", u64(connected))
	}
	entry := system.image_entry_of(image, connection.module_hash)
	if entry == nil {
		wrong("the holder of Display is no module of the boot image", 0)
	}
	file = image[entry.offset:][:entry.size]
	if blake3.hash(file) != connection.module_hash {
		wrong("the file of the holder of Display has not its hash", 0)
	}
	return connection, file
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}
