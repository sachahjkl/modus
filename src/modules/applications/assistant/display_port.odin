package assistant_window

import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:contract/role_contract"
import "modus:system"

// The port of the act dialog: a connection to the holder of the role
// Display, the trusted display, made at the first act that waits for the
// principal, by the role name, so it reaches the holder in force. The
// module file that describes the exports is the entry of the boot image
// with the hash that the root service gives with the connection, checked
// against the bytes: a holder with no act_ask and act_poll is no trusted
// display, and an act that waits stays waiting.

Display_Port :: struct {
	root_handle:   system.Handle,
	root_opened:   bool,
	root:          ring.Ring,
	next_tag:      u32,
	image:         []u8,
	connected:     bool,
	connection:    system.Call_Connection,
	file:          []u8,
	ask_export:    u32,
	poll_export:   u32,
}

display_port: Display_Port

// The decision of the principal on an act, from the word of act_poll.
Act_Decision :: enum u8 {
	Pending,
	Allowed,
	Refused,
}

// display_port_bind keeps the ring to the root service and maps the boot
// image, once, at the start.
display_port_bind :: proc "contextless" (ctx: ^system.Context) {
	display_port.root_handle = ctx.handles[system.GRANT_ROOT]
	image_handle := ctx.handles[system.GRANT_IMAGE]
	if image_handle == 0 {
		return
	}
	if address, status := system.memory_map(image_handle, {}); status == .Ok {
		display_port.image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
}

@(private = "file")
display_connect :: proc "contextless" () -> (cause: string) {
	if display_port.connected {
		return ""
	}
	if display_port.root_handle == 0 || len(display_port.image) == 0 {
		return "the assistant has no ring to the root service or no boot image"
	}
	if !display_port.root_opened {
		requests, status := system.ring_open(display_port.root_handle, receive_handles = true)
		if status != .Ok {
			return "the ring to the root service does not open"
		}
		display_port.root, display_port.root_opened = requests, true
	}
	display_port.next_tag = display_port.next_tag == max(u32) ? 1 : display_port.next_tag + 1
	connection, status := system.service_connection(&display_port.root, display_port.next_tag, role_contract.role_properties(.Display).name)
	if status != .Ok {
		return "the root service gives no connection to the trusted display"
	}
	entry := system.image_entry_of(display_port.image, connection.module_hash)
	file := entry != nil ? display_port.image[entry.offset:][:entry.size] : nil
	if entry == nil || blake3.hash(file) != connection.module_hash {
		system.call_connection_end(&connection)
		return "the trusted display is no module of the boot image"
	}
	ask := module.export_find(file, "act_ask")
	poll := module.export_find(file, "act_poll")
	if ask == 0 || poll == 0 {
		system.call_connection_end(&connection)
		return "the trusted display has no act dialog"
	}
	display_port.connection, display_port.file = connection, file
	display_port.ask_export, display_port.poll_export = ask, poll
	display_port.connected = true
	return ""
}

@(private = "file")
display_disconnect :: proc "contextless" () {
	if display_port.connected {
		system.call_connection_end(&display_port.connection)
		display_port.connected = false
	}
}

// display_act_ask shows the act dialog for an act, and gives its serial.
// 0 with no cause: another dialog of the trusted display shows, and the
// act asks again later. 0 with a cause: no dialog can show.
display_act_ask :: proc "contextless" (act: string) -> (serial: u64, cause: string) {
	if cause = display_connect(); cause != "" {
		return 0, cause
	}
	arguments := [1]isolated.Argument{{text = transmute([]u8)act}}
	error: errors.Error_Record
	result, status := system.call_isolated(&display_port.connection, display_port.file, display_port.ask_export, arguments[:], &error)
	if status != .Ok && status != .Failed {
		display_disconnect()
		return 0, "the call of act_ask did not end"
	}
	if result > 0 {
		return u64(result), ""
	}
	kind, _ := errors.kind_of_word(error.kind)
	if kind == .Busy {
		return 0, ""
	}
	return 0, errors.KIND_NAMES[kind]
}

// display_act_poll gives the decision on the act dialog with a serial.
// known is false when the trusted display does not answer, or no longer
// knows the dialog: the caller then asks again.
display_act_poll :: proc "contextless" (serial: u64) -> (decision: Act_Decision, known: bool) {
	if display_connect() != "" || serial > u64(max(i64)) {
		return .Pending, false
	}
	arguments := [1]isolated.Argument{{integer = serial}}
	error: errors.Error_Record
	result, status := system.call_isolated(&display_port.connection, display_port.file, display_port.poll_export, arguments[:], &error)
	if status != .Ok {
		if status != .Failed {
			display_disconnect()
		}
		return .Pending, false
	}
	word, word_ok := pr.plan_display_decision_of_word(result)
	if !word_ok {
		return .Pending, false
	}
	switch word {
	case .Pending:
		return .Pending, true
	case .Accepted:
		return .Allowed, true
	case .Refused:
		return .Refused, true
	case .Unknown:
	}
	return .Pending, false
}
