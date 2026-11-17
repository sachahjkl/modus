package root

// The root ring in this service: the dispatch of each command that a
// program writes on its root ring (modus:contract/root_ring;
// src/md/api/root_ring.md).
//
// Each record goes through three steps, in this order, and a step that
// refuses ends it with its own error record:
//
// 1. The border: command_of_word reads the kind. A word that names no
//    command, and None, get `Unsupported`, and nothing runs.
// 2. The sender: the table root_ring.ROOT_COMMAND_SENDERS, with the start
//    grants that the program received at its start (Started.role), and for
//    a Connect the services of its role. A refusal gets `No_Grant`, before
//    any other check, so a program learns nothing of a command that it
//    cannot send.
// 3. The command: one case of a whole switch. The table
//    ROOT_COMMAND_REFUSAL_WRITERS says who writes the error record of its
//    refusal: this dispatch, from the name and the word of the record, or
//    the procedure of the command.

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:contract/root_ring"
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
}

// Who writes the error record of a refused command.
Refusal_Writer :: enum u8 {
	// This dispatch, with root_command_refusal: the values of the command
	// hold a name in values[0..4] and a word in values[4].
	Dispatch,
	// The procedure of the command: its values hold a hash, a nickname or
	// a key where a name would be, or its cause is a fact that only it
	// knows (the grant that refuses a debug access, a refused signature).
	Command,
}

// The writer of the error record of each command. The table is whole: a
// new command does not compile until its row says who writes the record,
// so no record of a command is written over.
@(rodata)
ROOT_COMMAND_REFUSAL_WRITERS := [root_ring.Root_Command]Refusal_Writer {
	.None                   = .Dispatch,
	.Start                  = .Dispatch,
	.Stop                   = .Dispatch,
	.Connect                = .Command,
	.Disconnect             = .Dispatch,
	.Grants                 = .Dispatch,
	.Revoke                 = .Dispatch,
	.Replace                = .Command,
	.Connect_History        = .Dispatch,
	.Principal_Create       = .Dispatch,
	.Principal_Lock         = .Dispatch,
	.Principals             = .Dispatch,
	.Principal_Record       = .Dispatch,
	.Principal_Unlock       = .Command,
	.Debug                  = .Command,
	.Palette_Provide        = .Dispatch,
	.Start_From_Disk        = .Command,
	.Disk_Grant             = .Command,
	.Nickname_Move          = .Command,
	.Machine_Passphrase     = .Dispatch,
	.Machine_Key            = .Command,
	.Disk_Grant_Persistence = .Command,
	.Debug_Store            = .Command,
	.Machine_Seal           = .Dispatch,
	.Principal_Change       = .Command,
	.Principal_Change_End   = .Command,
	.Remote_Client          = .Command,
}

// root_ring_serve answers each command that a program wrote on its root
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

// root_command_answer runs the three steps of one record: the border, the
// sender, the command.
root_command_answer :: proc "contextless" (item: ^Started, record: ring.Record) -> (answer: Command_Answer) {
	command, known := root_ring.command_of_word(record.kind)
	if !known {
		return {status = .Bad_Operation, values = root_ring.command_refusal(record.kind)}
	}
	name_bytes := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
	name := system.name_of(name_bytes[:])
	if !root_command_sender_allowed(item, command, name) {
		return {status = .No_Right, values = root_ring.sender_refusal(command)}
	}
	answer = root_command_run(item, command, record, name)
	if answer.status != .Ok && !answer.held && ROOT_COMMAND_REFUSAL_WRITERS[command] == .Dispatch {
		answer.values = root_command_refusal(command, name, record.values[4], answer.status)
	}
	return answer
}

// root_command_sender_allowed applies the table of the senders to the role
// that the program received at its start, never to its name: a disk
// program has the nickname that it chose. A Connect with the grant Connect
// and not Root_Ring names a service of the role.
root_command_sender_allowed :: proc "contextless" (item: ^Started, command: root_ring.Root_Command, service: string) -> bool {
	if !root_ring.sender_allowed(command, item.role.grants) {
		return false
	}
	if command == .Connect {
		return role_may_connect(&item.role, service)
	}
	return true
}

// root_command_run runs one command that its sender can send. name is the
// name of values[0..4], for the commands that carry one.
root_command_run :: proc "contextless" (item: ^Started, command: root_ring.Root_Command, record: ring.Record, name: string) -> (answer: Command_Answer) {
	answer.status = .Bad_Operation
	switch command {
	case .None:
		// The border refuses it; the case keeps the switch whole.
	case .Start:
		// A program that a program starts belongs to the session of the
		// program that asks.
		answer.status = start(name, item.principal)
	case .Stop:
		answer.status = .Bad_Handle
		for &other in started {
			// The compositor is not a program that the console stops.
			if other.program != 0 && other.program != compositor && !other.is_terminal && system.name_of(other.name[:]) == name {
				system.call(.Program_Stop, u64(other.program), 0)
				answer.status = .Ok
				break
			}
		}
	case .Connect:
		answer.status = root_connect(item, record, name, &answer.values)
	case .Disconnect:
		// The connection of the history is not ended by the name of its
		// service: the program keeps its history when it ends its calls to
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
	}
	return answer
}

// root_connect runs Connect. The program of the client table connects for
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
// caller, and no fact of another program that the status does not give.
root_command_refusal :: proc "contextless" (command: root_ring.Root_Command, name: string, value: u64, status: system.Status) -> [7]u64 {
	kind := u32(command)
	of_the_system := name_is_a_system_part(name)
	switch command {
	case .None, .Replace, .Principal_Unlock, .Debug, .Start_From_Disk, .Disk_Grant, .Nickname_Move, .Machine_Key, .Disk_Grant_Persistence, .Debug_Store, .Principal_Change, .Principal_Change_End, .Remote_Client:
		// No cause that the state shows: the record Refused, with the status.
	case .Connect_History, .Palette_Provide:
		// A grant of the role that the command needs, and that the program
		// lacks or lost by a revocation.
		if status == .No_Right {
			return root_ring.sender_refusal(command)
		}
	case .Start:
		if status == .Bad_Operation && of_the_system {
			return errors.ring_fail(kind, .Reserved, .None, 1)
		}
		if status == .Bad_Operation && len(system.image_find(image, name)) == 0 {
			return errors.ring_fail(kind, .Absent, .Modules, 1)
		}
	case .Stop:
		if status == .Bad_Handle && (name == "compositor" || name == "terminal") {
			return errors.ring_fail(kind, .Reserved, .None, 1)
		}
		if status == .Bad_Handle && find(name) == nil {
			return errors.ring_fail(kind, .Absent, .Programs, 1)
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
			return errors.ring_fail(kind, .Absent, .Programs, 1)
		}
	case .Revoke:
		switch {
		case status == .Bad_Handle && find(name) == nil:
			return errors.ring_fail(kind, .Absent, .Programs, 1)
		case status == .Bad_Operation:
			return errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(value, 1 << 62)), i64(max(system.Root_Grant)))
		case status == .Bad_State:
			return errors.ring_fail(kind, .Absent, .Grants, 2)
		}
	case .Principal_Create:
		#partial switch status {
		case .Bad_Operation:
			return errors.ring_fail(kind, .Bad_Value, .None, 1)
		case .Bad_State:
			// One named principal: several are not built.
			return errors.ring_fail(kind, .Full, .Principals, 0, 0, principals.PRINCIPAL_CAPACITY - 1)
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
		#partial switch status {
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
