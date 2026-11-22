// The port of the trusted display of the plans service: it shows the
// difference of a plan and gives the decision of the principal
// (src/md/features/declarations.md, "Apply, the difference and the
// rollback"). The port of the private store is modus:storage_port.
package plans_service

import "internal:plans/plans_core"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:system"

// The name of the holder of the Display role that the root service connects.
DISPLAY_SERVICE_NAME :: "compositor"

// The connection to the trusted display, made at the first apply.
Display_Connection :: struct {
	tried:       bool, // The context has what a connection needs: a ring to the root service and the boot image.
	requests:    ring.Ring,
	connected:   bool,
	connection:  system.Call_Connection,
	file:        []u8, // The module file of the display: the descriptions of its exports.
	ask_export:  u32,
	poll_export: u32,
	next_tag:    u32,
}

display_connection: Display_Connection
display_requests_handle: system.Handle
display_image: []u8

// display_port_bind keeps what the connection to the trusted display needs:
// the ring to the root service and the boot image, which holds the module
// file of the display, and gives the port. With neither, the port has no
// procedure, and an apply is refused with Consent_Required: no plan commits
// without the decision of the principal.
display_port_bind :: proc "contextless" (ctx: ^system.Context) -> (port: plans_core.Trusted_Display_Port) {
	display_requests_handle = ctx.handles[system.GRANT_ROOT]
	image_handle := ctx.handles[system.GRANT_IMAGE]
	if display_requests_handle == 0 || image_handle == 0 {
		return {}
	}
	address, status := system.memory_map(image_handle, {})
	if status != .Ok {
		return {}
	}
	display_image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	return {ask = display_ask, poll = display_poll}
}

// display_connect makes the connection at the first use, and again after a
// call that failed: a display that started again has a new connection.
@(private = "file")
display_connect :: proc "contextless" () -> bool {
	if display_connection.connected {
		return true
	}
	if display_requests_handle == 0 || len(display_image) == 0 {
		return false
	}
	if !display_connection.tried {
		requests, status := system.ring_open(display_requests_handle, receive_handles = true)
		if status != .Ok {
			return false
		}
		display_connection.requests = requests
		display_connection.tried = true
	}
	file := system.image_find(display_image, DISPLAY_SERVICE_NAME)
	if file == nil {
		return false
	}
	ask := module.export_find(file, "plan_diff_ask")
	poll := module.export_find(file, "plan_diff_poll")
	if ask == 0 || poll == 0 {
		return false
	}
	display_connection.next_tag += 1
	connection, status := system.service_connection(&display_connection.requests, display_connection.next_tag, DISPLAY_SERVICE_NAME)
	if status != .Ok {
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

// display_ask calls plan_diff_ask of the trusted display.
display_ask :: proc "contextless" (user: rawptr, plan_name: string, added: string, removed: string) -> (serial: u64, ok: bool) {
	if !display_connect() {
		return 0, false
	}
	arguments := [3]isolated.Argument{{text = transmute([]u8)plan_name}, {text = transmute([]u8)added}, {text = transmute([]u8)removed}}
	error: errors.Error_Record
	result, status := system.call_isolated(&display_connection.connection, display_connection.file, display_connection.ask_export, arguments[:], &error)
	if status != .Ok || result <= 0 {
		if status != .Ok && status != .Failed {
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
	result, status := system.call_isolated(&display_connection.connection, display_connection.file, display_connection.poll_export, arguments[:], &error)
	if status != .Ok {
		if status != .Failed {
			display_disconnect()
		}
		return .Unknown, false
	}
	return pr.plan_display_decision_of_word(result)
}