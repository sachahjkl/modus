package assistant_window

import "internal:assistant/conversation"
import assistant_contract "modus:contract/assistant"
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
// against the bytes: a holder with no act_ask, act_poll and act_cancel is
// no trusted display, and an act that waits takes the state Not_Shown.

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
	cancel_export: u32,
}

display_port: Display_Port

// The port of the act dialog that the loop of the window uses.
display_act_dialog_port :: proc "contextless" () -> conversation.Act_Dialog_Port {
	return {ask = display_act_ask, poll = display_act_poll, cancel = display_act_cancel}
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
	connection, outcome := system.service_connection(&display_port.root, display_port.next_tag, role_contract.role_properties(.Display).name)
	if outcome != .Succeeded {
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
	cancel := module.export_find(file, "act_cancel")
	if ask == 0 || poll == 0 || cancel == 0 {
		system.call_connection_end(&connection)
		return "the trusted display has no act dialog"
	}
	display_port.connection, display_port.file = connection, file
	display_port.ask_export, display_port.poll_export, display_port.cancel_export = ask, poll, cancel
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

// display_act_ask shows the act dialog for an act, named by the service
// and the export of its one call, as the runner gave them, and gives its
// serial. Busy: another dialog of the trusted display shows, and the act
// asks again later. Refused, with its cause: no dialog can show.
display_act_ask :: proc "contextless" (service, export: string) -> (serial: u64, outcome: conversation.Act_Ask_Outcome, cause: string) {
	if cause = display_connect(); cause != "" {
		return 0, .Refused, cause
	}
	name_buffer: [2 * assistant_contract.ACT_NAME_BYTES + 1]u8
	count := copy(name_buffer[:], service)
	name_buffer[count] = '.'
	count += 1
	count += copy(name_buffer[count:], export)
	arguments := [1]isolated.Argument{{text = name_buffer[:count]}}
	error: errors.Error_Record
	result, ended := system.call_isolated(&display_port.connection, display_port.file, display_port.ask_export, arguments[:], &error)
	if system.connection_to_renew(ended) {
		display_disconnect()
		return 0, .Refused, "the call of act_ask did not end"
	}
	if ended == .Succeeded && result > 0 {
		return u64(result), .Shown, ""
	}
	if ended == .Callee_Busy {
		return 0, .Busy, ""
	}
	kind, _ := errors.kind_of_word(error.kind)
	return 0, .Refused, errors.KIND_NAMES[kind]
}

// display_act_cancel closes the act dialog with a serial, when it still
// shows: the act left the conversation of the window. A failure changes
// nothing that the window keeps: the trusted display closes the dialog
// when the connection of its asker ends.
display_act_cancel :: proc "contextless" (serial: u64) {
	if serial == 0 || serial > u64(max(i64)) || display_connect() != "" {
		return
	}
	arguments := [1]isolated.Argument{{integer = serial}}
	error: errors.Error_Record
	if _, ended := system.call_isolated(&display_port.connection, display_port.file, display_port.cancel_export, arguments[:], &error); system.connection_to_renew(ended) {
		display_disconnect()
	}
}

// display_act_poll gives the decision on the act dialog with a serial.
// known is false when the trusted display does not answer, or no longer
// knows the dialog: the caller then asks again.
display_act_poll :: proc "contextless" (serial: u64) -> (decision: conversation.Act_Decision, known: bool) {
	if display_connect() != "" || serial > u64(max(i64)) {
		return .Pending, false
	}
	arguments := [1]isolated.Argument{{integer = serial}}
	error: errors.Error_Record
	result, ended := system.call_isolated(&display_port.connection, display_port.file, display_port.poll_export, arguments[:], &error)
	if ended != .Succeeded {
		if system.connection_to_renew(ended) {
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
