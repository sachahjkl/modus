package root

// The root ring in this service: the dispatch of each command that a
// process writes on its root ring (modus:contract/root_ring;
// src/md/api/root_ring.md).
//
// Each record goes through three steps, in this order, and a step that
// refuses ends it with its own error record. The first two are the pure
// decision root_ring.dispatch_decide, which a host test and a fuzz target
// of the tool call:
//
// 1. The border: command_of_word reads the kind. A word that names no
//    command, and None, get `Unsupported`, and nothing runs.
// 2. The sender: the table root_ring.ROOT_COMMAND_SENDERS, with the start
//    grants that the process received at its start (Started.role), and for
//    a Connect the services of its role. A refusal gets `No_Grant`, before
//    any other check, so a process learns nothing of a command that it
//    cannot send.
// 3. The command: one case of a whole switch. The table
//    root_ring.ROOT_COMMAND_REFUSAL_WRITERS says who writes the error
//    record of its refusal: this dispatch, from the name and the word of
//    the record, or the procedure of the command.

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:private/root/start_policy_rules"
import "modus:support/principals"
import "modus:support/system"

// The answer of a command of the root ring: the completion that the sender
// receives, or none yet.
Command_Answer :: struct {
	status: system.Status,
	values: [7]u64, // The values of the completion; for a refusal, its error record.
	// The completion comes when the work ends (a load from the disk, a
	// change of a passphrase): the loop goes on meanwhile, and the work
	// sends it.
	held:   bool,
	// The procedure of the command wrote the error record of its refusal,
	// for a command whose table says that the dispatch writes it: the
	// refusals of a start policy (start_policy_rules).
	written: bool,
}

// root_ring_serve answers each command that a process wrote on its root
// ring since the last pass.
root_ring_serve :: proc "contextless" (item: ^Started) {
	for record in system.receive(&item.requests.commands) {
		answer := root_command_answer(item, record)
		if answer.held {
			continue
		}
		system.send(&item.requests.completions, ring.Record{kind = u32(answer.status), tag = record.tag, values = answer.values})
	}
}

// root_command_answer runs the three steps of one record: the border and
// the sender, which root_ring.dispatch_decide decides from the role that
// the process received at its start and never from its name (a disk
// process has the nickname that it chose), then the command.
root_command_answer :: proc "contextless" (item: ^Started, record: ring.Record) -> (answer: Command_Answer) {
	name_bytes := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
	name := system.name_of(name_bytes[:])
	decision := root_ring.dispatch_decide(record.kind, item.role.grants, role_may_connect(&item.role, name))
	switch decision.step {
	case .Border, .Sender:
		return {status = decision.status, values = decision.refusal}
	case .Command:
	}
	command := decision.command
	answer = root_command_run(item, command, record, name)
	if answer.status != .Ok && !answer.held && !answer.written && root_ring.ROOT_COMMAND_REFUSAL_WRITERS[command] == .Dispatch {
		answer.values = root_command_refusal(command, name, record.values[4], answer.status)
	}
	return answer
}

// root_command_run runs one command that its sender can send. name is the
// name of values[0..4], for the commands that carry one.
root_command_run :: proc "contextless" (item: ^Started, command: root_ring.Root_Command, record: ring.Record, name: string) -> (answer: Command_Answer) {
	answer.status = .Bad_Operation
	switch command {
	case .None:
		// The border refuses it; the case keeps the switch whole.
	case .Start:
		// The start policy starts the parts of the system too, and gets a
		// handle of each process (start_policy.odin). A process that a
		// process starts belongs to the session of the process that asks.
		answer.status = start_command(item, record, name, &answer.values, &answer.written)
	case .Stop:
		answer.status = .Bad_Handle
		for &other in started {
			// The compositor is not a process that the console stops, and
			// the start policy stops only a process that it asked for.
			if .Start_Policy in item.role.grants && !other.asked_by_start_policy {
				continue
			}
			if other.process != 0 && other.process != compositor && !other.is_terminal && system.name_of(other.name[:]) == name {
				system.call(.Process_Stop, u64(other.process), 0)
				answer.status = .Ok
				break
			}
		}
		// A start policy learns nothing of a process that it did not ask
		// for: each refusal is the one record Absent.
		if answer.status != .Ok && .Start_Policy in item.role.grants {
			answer.values = start_policy_rules.stop_record()
			answer.written = true
		}
	case .Connect:
		answer.status = root_connect(item, record, name, &answer.values)
	case .Disconnect:
		// The connection of the history is not ended by the name of its
		// service: the process keeps its history when it ends its calls to
		// the storage service.
		answer.status = .Bad_Handle
		for &connection in connections {
			// values[4]: the row of the client table that the connection is
			// for, as Connect named it; 0 for none.
			if connection.caller == item && !connection.history && connection.client.place == int(min(record.values[4], u64(max(int)))) && system.name_of(connection.service.name[:]) == name {
				disconnect(&connection)
				answer.status = .Ok
			}
		}
	case .Grants:
		answer.status = .Bad_Handle
		if other := find(name); other != nil {
			packed := system.name_pack(principal_name(other.principal))
			answer.values = {transmute(u64)other.granted, transmute(u64)other.revoked, other.principal, packed[0], packed[1], packed[2], packed[3]}
			answer.status = .Ok
		}
	case .Revoke:
		answer.status = revoke(name, record.values[4], &answer.values)
	case .Replace:
		answer.status = replace(item, name, record.values[4], &answer.values)
	case .Connect_History:
		answer.status = .No_Right
		if .History_Store in item.role.grants && .History not_in item.revoked && name == "storage" {
			answer.status = connect(item, "storage", &answer.values, history = true)
		}
	case .Principal_Create:
		answer.status = principal_create(name)
	case .Principal_Lock:
		answer.status = principal_lock(&answer.values)
	case .Principals:
		answer.status = principal_read(record.values[4], &answer.values)
	case .Principal_Record:
		answer.status = principal_record(record.values, &answer.values)
	case .Principal_Unlock:
		answer.status = principal_unlock(record.values, &answer.values)
		key_ring_erase(&item.requests.commands)
	case .Debug:
		answer.status = debug(item, name, record.values[4], record.values[5] != 0, &answer.values)
	case .Palette_Provide:
		answer.status = palette_provide(item, &answer.values)
	case .Start_From_Disk:
		// The completion of a load from the disk comes when the load ends.
		answer.status, answer.held = disk_start_begin(item, record, &answer.values)
	case .Disk_Grant:
		answer.status = disk_grant_change(item, record, &answer.values)
	case .Nickname_Move:
		answer.status = nickname_move(item, record, &answer.values)
	case .Machine_Passphrase:
		answer.status = machine_passphrase_ask()
	case .Machine_Key:
		// Its values hold a key where a name would be: the record of a
		// refusal names the status only.
		answer.status = machine_key_take(record.values)
		key_ring_erase(&item.requests.commands)
		if answer.status != .Ok {
			answer.values = errors.ring_fail(u32(command), .Refused, .None, 0, 0, 0, i64(answer.status))
		}
	case .Disk_Grant_Persistence:
		answer.status = disk_grant_persistence(item, record, &answer.values)
	case .Debug_Store:
		answer.status = debug_store_open(item, name, record.values[4], record.values[5] != 0, record.values[6] != 0, &answer.values)
	case .Machine_Seal:
		answer.status = machine_seal_ask()
	case .Principal_Change:
		// The completion comes when the change ends.
		answer.status, answer.held = principal_change(item, record.tag, record.values[4], &answer.values)
	case .Principal_Change_End:
		answer.status = principal_change_end(record.values, &answer.values)
	case .Remote_Client:
		answer.status = remote_client_command(item, record, &answer.values)
	case .Machine_Usable:
		answer.status = start_policy_usable(item, &answer.values)
	case .Start_Policy_Choice:
		answer.status = start_policy_choice_command(item, record, &answer.values)
	case .Wire:
		answer.status = wire(item, record, &answer.values)
	}
	return answer
}

// start_command runs Start: the border of values[4..6], the start with its
// wiring list, and the answer that values[5] asks for. The start policy
// starts the parts of the system too, and gets a handle of each process
// (start_policy.odin); its start list wires no row before the step that
// builds it, so its Start with a list is refused with Unsupported.
start_command :: proc "contextless" (item: ^Started, record: ring.Record, name: string, values: ^[7]u64, written: ^bool) -> system.Status {
	command := root_ring.Root_Command.Start
	list, list_ok := root_ring.start_wiring_list_of_word(record.values[4])
	answer, answer_ok := root_ring.start_answer_of_word(record.values[5])
	refusal: [7]u64
	switch {
	case !list_ok:
		refusal = root_ring.word_refusal(command, 2, record.values[4], u64(max(root_ring.Start_Wiring_List)))
	case !answer_ok:
		refusal = root_ring.word_refusal(command, 3, record.values[5], u64(max(root_ring.Start_Answer)))
	case record.values[6] != 0:
		refusal = root_ring.word_refusal(command, 4, record.values[6], 0)
	case .Start_Policy in item.role.grants && list != .None:
		// The start list of a start policy wires no row before the step
		// that builds it.
		refusal = errors.ring_fail(u32(command), .Unsupported, .Wiring_Rows, 2)
	}
	if refusal != ([7]u64{}) {
		// A refused Start keeps none of the handles that its list lent.
		lent_handles_close(item)
		values^ = refusal
		written^ = true
		return .Bad_Operation
	}
	if .Start_Policy in item.role.grants {
		return start_policy_start(item, name, values, written)
	}
	// A process that a process starts belongs to the session of the
	// process that asks, and the asker of its start is that process.
	started_place: ^Started
	switch list {
	case .None:
		status := start(name, item.principal, item, nil, &started_place)
		if status == .Ok && answer == .Process_Handle && started_place != nil {
			values[0], _ = start_process_handle_give(item, started_place)
		}
		return status
	case .In_The_List_Page:
	}
	work := &wire_work
	work^ = {asker = item, command = command, form = .Start}
	if status := wiring_list_take(work); status != .Ok {
		values^ = work.refusal
		written^ = true
		return status
	}
	status := start(name, item.principal, item, work, &started_place)
	if status != .Ok {
		// A refusal of the list has its record; another refusal of the
		// start has the record of the dispatch.
		if work.refusal != ([7]u64{}) {
			values^ = work.refusal
			written^ = true
		}
		return status
	}
	// The number of each row whose reader is the sender, in the order of
	// the rows: its end comes in the wiring ring of the sender with this
	// tag. A row that ended keeps its place, with 0.
	asker_place := 1
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.row.reader_end != .Asker {
			continue
		}
		values[asker_place] = plan.kept != nil ? u64(plan.number) : 0
		asker_place += 1
	}
	if answer == .Process_Handle && started_place != nil {
		values[0], _ = start_process_handle_give(item, started_place)
	}
	return .Ok
}

// start_process_handle_give gives the asker of a start the handle of the
// process with the right Read only, through its root ring: the handle that
// a Wire names, and whose stop ends a wait of the asker.
start_process_handle_give :: proc "contextless" (asker: ^Started, process: ^Started) -> (u64, system.Status) {
	given, status := system.give(asker.requests_memory, process.process, {.Read})
	if status != .Ok {
		return 0, status
	}
	return u64(given), .Ok
}

// root_connect runs Connect. The process of the client table connects for
// one of its rows, and for no other principal; its check writes the record
// of its refusal, and a connection that fails after it gets the record of
// root_command_refusal.
root_connect :: proc "contextless" (item: ^Started, record: ring.Record, name: string, values: ^[7]u64) -> (status: system.Status) {
	if .Remote_Clients in item.role.grants || record.values[4] != 0 {
		client: Client_Grant
		client, status = client_grant_of(item, record.values[4], record.values[5], values)
		if status != .Ok {
			return status
		}
		status = connect(item, name, values, client = client)
	} else {
		status = connect(item, name, values)
	}
	if status != .Ok {
		values^ = root_command_refusal(.Connect, name, record.values[4], status)
	}
	return status
}

// root_command_refusal gives the error record of a command of the root
// ring that this service refused, in the values of its completion. As the
// kernel does (src/kernel/diagnose.odin), it reads the state again after
// the refusal, and names a cause only when the state shows it now: else the
// record is Refused, with the status. The record names the argument of the
// caller, and no fact of another process that the status does not give.
root_command_refusal :: proc "contextless" (command: root_ring.Root_Command, name: string, value: u64, status: system.Status) -> [7]u64 {
	kind := u32(command)
	// The start policy is no part of the system, and only this service
	// starts it: a Start of its name is refused as one.
	of_the_system := name_is_a_system_part(name) || .Start_Policy in role_of(name).grants
	switch command {
	case .None, .Principal_Unlock, .Debug, .Start_From_Disk, .Disk_Grant, .Nickname_Move, .Machine_Key, .Disk_Grant_Persistence, .Debug_Store, .Principal_Change, .Principal_Change_End, .Remote_Client, .Machine_Usable, .Start_Policy_Choice, .Wire:
		// No cause that the state shows: the record Refused, with the status.
	case .Connect_History, .Palette_Provide:
		// A grant of the role that the command needs, and that the process
		// lacks or lost by a revocation.
		if status == .No_Right {
			return root_ring.sender_refusal(command)
		}
	case .Replace:
		// replace calls this for each refusal that is not a refusal of a
		// signed row.
		if record, named := root_ring.replace_refusal(status, value, u64(len(system.image_entries(image))), len(system.image_find(image, name)) != 0, system.REPLACEMENT_CAPACITY); named {
			return record
		}
	case .Start:
		if status == .Bad_Operation && of_the_system {
			return errors.ring_fail(kind, .Reserved, .None, 1)
		}
		if status == .Bad_Operation && len(system.image_find(image, name)) == 0 {
			return errors.ring_fail(kind, .Absent, .Modules, 1)
		}
		// A start of the start policy for a name that runs.
		if status == .Bad_State && find_running(name) != nil {
			return errors.ring_fail(kind, .Exists, .Processes, 1)
		}
	case .Stop:
		if status == .Bad_Handle && (name == "compositor" || name == "terminal") {
			return errors.ring_fail(kind, .Reserved, .None, 1)
		}
		if status == .Bad_Handle && find(name) == nil {
			return errors.ring_fail(kind, .Absent, .Processes, 1)
		}
	case .Connect:
		if status == .Bad_Handle {
			return errors.ring_fail(kind, .Absent, .Services, 1)
		}
		if status == .No_Slot {
			return errors.ring_fail(kind, .Full, .Connections, 0, 0, isolated.SERVICE_CONNECTION_CAPACITY)
		}
	case .Disconnect:
		if status == .Bad_Handle {
			return errors.ring_fail(kind, .Absent, .Connections, 1)
		}
	case .Grants:
		if status == .Bad_Handle && find(name) == nil {
			return errors.ring_fail(kind, .Absent, .Processes, 1)
		}
	case .Revoke:
		switch {
		case status == .Bad_Handle && find(name) == nil:
			return errors.ring_fail(kind, .Absent, .Processes, 1)
		case status == .Bad_Operation:
			return errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(value, 1 << 62)), i64(max(system.Root_Grant)))
		case status == .Bad_State:
			return errors.ring_fail(kind, .Absent, .Grants, 2)
		}
	case .Principal_Create:
		switch status {
		case .Bad_Operation:
			return errors.ring_fail(kind, .Bad_Value, .None, 1)
		case .Bad_State:
			// One named principal: several are not built.
			return errors.ring_fail(kind, .Full, .Principals, 0, 0, principals.PRINCIPAL_CAPACITY - 1)
		case .Ok, .Bad_Handle, .Bad_Address, .No_Memory, .No_Slot, .No_Right, .No_Budget:
			// The general record of the status follows.
		}
	case .Principal_Lock:
		if status == .Bad_State {
			return errors.ring_fail(kind, .Absent, .Principals)
		}
	case .Principals:
		if status == .Bad_Handle {
			return errors.ring_fail(kind, .Absent, .Principals, 2, i64(min(value, 1 << 62)))
		}
	case .Principal_Record:
		if status == .No_Slot {
			return errors.ring_fail(kind, .Full, .Principals, 0, 0, principals.PRINCIPAL_CAPACITY - 1)
		}
	case .Machine_Passphrase, .Machine_Seal:
		switch status {
		case .Ok, .Bad_Operation, .Bad_Address, .No_Memory, .No_Budget:
			// The general record of the status follows.
		case .Bad_State:
			// The machine has a record of its machine key: a change is not
			// built.
			return errors.ring_fail(kind, .Exists, .Principals)
		case .Bad_Handle:
			// No TPM service: the system is not measured into a TPM.
			return errors.ring_fail(kind, .Unsupported, .Principals)
		case .No_Right:
			// Secure Boot is off: no seal trusts a boot program that
			// nothing verified.
			return errors.ring_fail(kind, .Refused, .Principals)
		case .No_Slot:
			// unlock runs: one window of unlock at a time.
			return errors.ring_fail(kind, .Busy, .Requests, 0, 1, 1)
		}
	}
	return errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
}
