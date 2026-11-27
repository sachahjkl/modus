// The stranger of the machine test of the store picker
// (src/md/features/powerbox.md, "The picker ring"). It does not act for
// its principal. After the principal picked a store for store_asker, it
// asks the trusted display for the grants of the windows and for a store
// picker of its own: the display refuses both with No_Grant, so it learns
// neither the store that the principal picked nor the list.
//
// **Start**: `start("store_stranger")` in the console of principal 0.
// **What a reader sees**: no window; one line "store_stranger: ...", or
// a line "store_stranger: WRONG: ...". It stops itself with Done, or
// Failed after a WRONG line.
package store_stranger

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:system"

// Page tables for mapping the boot image plus the display call connection.
BOOT_IMAGE_AND_CONNECTION_PAGES :: 32
// Boot image page tables and display call connection mapped before exit.
MODULE_START_OBJECTS :: [?]system.Start_Object{BOOT_IMAGE_AND_CONNECTION_PAGES}

// The bytes for the rows of window_grants: an answer would fill them.
rows: [4096]u8

@(private = "file")
refused_with_no_grant :: proc "contextless" (what: string, result: i64, status: call_outcome.Call_Outcome, error: ^errors.Error_Record) {
	if status != .Grant_Or_Right_Missing || result != 0 || error.kind != i64(errors.Kind.No_Grant) || error.unit != i64(errors.Unit.Acts_For_Principal) {
		system.log_fact(.Error, Wrong_Answer{status = u64(status), result = result, error_kind = error.kind, error_unit = error.unit}, what)
		system.stop(.Failed)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	connection, file := display_connect(ctx)
	grants := module.export_find(file, "window_grants")
	pick := module.export_find(file, "powerbox_pick_store")
	if grants == 0 || pick == 0 {
		wrong("the holder of Display lacks window_grants or powerbox_pick_store", 0)
	}
	error: errors.Error_Record
	result, status := system.call_isolated(&connection, file, grants, nil, &error, rows = rows[:])
	refused_with_no_grant("window_grants", result, status, &error)
	// The rows stay as they were: no byte of a grant came.
	for value in rows {
		if value != 0 {
			wrong("window_grants wrote into the rows of a stranger a byte", u64(value))
		}
	}
	name := "store_stranger"
	mode := "read"
	arguments := [2]isolated.Argument{{text = transmute([]u8)name}, {text = transmute([]u8)mode}}
	error = {}
	result, status = system.call_isolated(&connection, file, pick, arguments[:], &error)
	refused_with_no_grant("powerbox_pick_store", result, status, &error)
	system.call_connection_end(&connection)
	system.log_fact(.Info, Saw_Nothing{})
	system.stop(.Done)
}

@(private = "file")
display_connect :: proc "contextless" (ctx: ^system.Context) -> (connection: system.Call_Connection, file: []u8) {
	requests_memory := ctx.handles[system.GRANT_ROOT]
	requests, ring_status := system.ring_open(requests_memory, receive_handles = true)
	if ring_status != .Succeeded {
		wrong("no root ring; the status", u64(ring_status))
	}
	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Succeeded {
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
