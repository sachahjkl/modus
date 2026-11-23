// The port of the trusted display of the plans service: it shows the
// difference of a plan and gives the decision of the principal
// (src/md/features/declarations.md, "Apply, the difference and the
// rollback"). The port of the private store is modus:storage_port.
package plans_service

import "internal:plans/plans_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import description "modus:contract/plan_value_description"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:contract/role_contract"
import "modus:system"

// The ring to the root service: Connect to the display, and Plan_Roles.
// Both wait for their own completion by its tag, one at a time: the service
// runs one export at a time.
Root_Requests :: struct {
	opened:   bool,
	ring:     ring.Ring,
	next_tag: u32,
}

root_requests: Root_Requests
root_requests_handle: system.Handle

// root_requests_bind keeps the handle of the ring to the root service. The
// ring opens at its first use.
root_requests_bind :: proc "contextless" (ctx: ^system.Context) {
	root_requests_handle = ctx.handles[system.GRANT_ROOT]
}

// root_requests_open opens the ring to the root service, once.
root_requests_open :: proc "contextless" () -> bool {
	if root_requests.opened {
		return true
	}
	if root_requests_handle == 0 {
		return false
	}
	requests, status := system.ring_open(root_requests_handle, receive_handles = true)
	if status != .Ok {
		return false
	}
	root_requests.ring = requests
	root_requests.opened = true
	return true
}

// root_requests_tag_next gives the tag of the next command on the ring to
// the root service.
root_requests_tag_next :: proc "contextless" () -> u32 {
	root_requests.next_tag = root_requests.next_tag == max(u32) ? 1 : root_requests.next_tag + 1
	return root_requests.next_tag
}

// The connection to the trusted display, made at the first apply.
Display_Connection :: struct {
	connected:   bool,
	connection:  system.Call_Connection,
	file:        []u8, // The module file of the display: the descriptions of its exports.
	ask_export:  u32,
	poll_export: u32,
}

display_connection: Display_Connection
display_image: []u8

// display_port_bind keeps what the connection to the trusted display needs:
// the ring to the root service and the boot image, which holds the module
// file of the display, and gives the port. With neither, the port has no
// procedure, and an apply is refused with Consent_Required: no plan commits
// without the decision of the principal.
display_port_bind :: proc "contextless" (ctx: ^system.Context) -> (port: plans_core.Trusted_Display_Port) {
	image_handle := ctx.handles[system.GRANT_IMAGE]
	if root_requests_handle == 0 || image_handle == 0 {
		return {}
	}
	address, status := system.memory_map(image_handle, {})
	if status != .Ok {
		return {}
	}
	display_image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	return {ask = display_ask, poll = display_poll}
}

// plans_image gives the boot image to the description of the values of a
// plan (exports.odin, plan_of_table). With no image, no owner is found,
// and a plan with a value is refused.
plans_image :: proc "contextless" () -> description.Image {
	of_name :: proc "contextless" (user: rawptr, name: string) -> []u8 {
		return system.image_find(display_image, name)
	}
	of_hash :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> []u8 {
		entry := system.image_entry_of(display_image, hash)
		if entry == nil {
			return nil
		}
		return display_image[entry.offset:][:entry.size]
	}
	return {module_of_name = of_name, module_of_hash = of_hash}
}

// display_connect makes the connection at the first use, and again after a
// call that failed: a display that started again has a new connection.
//
// It connects by the role name, so the root service reaches the holder of
// Display in force, whichever module a plan gave it to. The
// module file that describes the exports is the entry of the boot image
// with the hash that the root service gives with the connection, checked
// against the bytes: a holder that does not have plan_diff_ask and
// plan_diff_poll is no trusted display, and the apply is refused.
@(private = "file")
display_connect :: proc "contextless" () -> bool {
	if display_connection.connected {
		return true
	}
	if len(display_image) == 0 || !root_requests_open() {
		return false
	}
	connection, outcome := system.service_connection(&root_requests.ring, root_requests_tag_next(), role_contract.role_properties(.Display).name)
	if outcome != .Succeeded {
		return false
	}
	entry := system.image_entry_of(display_image, connection.module_hash)
	if entry == nil {
		system.call_connection_end(&connection)
		return false
	}
	file := display_image[entry.offset:][:entry.size]
	if blake3.hash(file) != connection.module_hash {
		system.call_connection_end(&connection)
		return false
	}
	ask := module.export_find(file, "plan_diff_ask")
	poll := module.export_find(file, "plan_diff_poll")
	if ask == 0 || poll == 0 {
		system.call_connection_end(&connection)
		return false
	}
	display_connection.connection = connection
	display_connection.file = file
	display_connection.ask_export = ask
	display_connection.poll_export = poll
	display_connection.connected = true
	return true
}

@(private = "file")
display_disconnect :: proc "contextless" () {
	if display_connection.connected {
		system.call_connection_end(&display_connection.connection)
		display_connection.connected = false
	}
}

// display_ask calls plan_diff_ask of the trusted display. The two sides
// go in one memory object of this service, added then removed, which the
// display keeps past the call: this service gives it a copy of the
// handle with Read only through the call ring of the connection, and
// passes the number of that copy. The display reads it on a worker and
// closes it; a call that the display did not take revokes the copy.
display_ask :: proc "contextless" (user: rawptr, plan_name: string, added: string, removed: string) -> (serial: u64, ok: bool) {
	total := len(added) + len(removed)
	if total == 0 || !display_connect() {
		return 0, false
	}
	pages := (u64(total) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory, status := system.memory_create(pages)
	if status != .Ok {
		return 0, false
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		return 0, false
	}
	bytes := ([^]u8)(address)[:total]
	copy(bytes, added)
	copy(bytes[len(added):], removed)
	system.memory_unmap(address)
	connection := &display_connection.connection
	given, give_status := system.give(connection.ring_memory, memory, {.Read})
	if give_status != .Ok {
		return 0, false
	}
	arguments := [4]isolated.Argument{{text = transmute([]u8)plan_name}, {integer = u64(given)}, {integer = u64(len(added))}, {integer = u64(len(removed))}}
	error: errors.Error_Record
	result, outcome := system.call_isolated(connection, display_connection.file, display_connection.ask_export, arguments[:], &error)
	if outcome != .Succeeded || result <= 0 {
		// The display closes the copy of a call that it refused; a call
		// that did not reach it leaves the copy there, which this revokes.
		// The copy is the one holding that came from memory. The display
		// reads the object by system.memory_read, so a revocation during a
		// reading is a status there, never a fault.
		system.handle_revoke(memory)
		if system.connection_to_renew(outcome) {
			display_disconnect()
		}
		return 0, false
	}
	return u64(result), true
}

// display_poll calls plan_diff_poll of the trusted display, and takes its
// word at the border of Plan_Display_Decision.
display_poll :: proc "contextless" (user: rawptr, serial: u64) -> (decision: pr.Plan_Display_Decision, ok: bool) {
	if !display_connect() || serial > u64(max(i64)) {
		return .Unknown, false
	}
	arguments := [1]isolated.Argument{{integer = serial}}
	error: errors.Error_Record
	result, outcome := system.call_isolated(&display_connection.connection, display_connection.file, display_connection.poll_export, arguments[:], &error)
	if outcome != .Succeeded {
		if system.connection_to_renew(outcome) {
			display_disconnect()
		}
		return .Unknown, false
	}
	return pr.plan_display_decision_of_word(result)
}
