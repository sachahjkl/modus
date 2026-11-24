package root

// The client keys of the remote service (docs/PRINCIPALS.md, "The client
// keys of remote"; src/md/features/remote_client_keys.md).
//
// A principal allows the Ed25519 public key of a client of `remote` from a
// console that acts for it (Root_Command.Remote_Client). This service keeps
// each such grant as a row of the client table, a page that it writes and
// that `remote` maps with the right Read only. `remote` refuses in the
// handshake each key with no row, and makes each connection to a service
// for one row: this service gives that connection the principal of the row,
// so a call of the client acts for the principal that allowed it, and for
// no other.
//
// The serial of a row names one grant. A revocation frees the row; a lock
// of the session of its principal, and the unlock after it, give it a new
// serial. Each time the grant of a row ends, this service ends each
// connection that it made for that row, and `remote`, which reads the
// table at each pass of its loop, ends the open connection of the client.
//
// Each row holds the uses of its key (remote.Client_Uses): Calls for
// `remote`, View and Input for `remote_display`, which reads the same table
// (src/md/features/remote_display.md). Each client key and its uses
// (Calls, View, Input) are kept in the disk grant table of its principal
// (persisted_grant_table.odin), so allowed viewers and remote clients hold
// their grants again across a restart where that table lasts. The client
// table is the form of the keys while the machine runs: after the read of a
// table, each of its keys gets a row again with its persisted uses and a
// new serial. A key that another principal allowed too is contested: it
// acts for neither until one of them revokes it.

import "modus:contract/call_outcome"
import "modus:contract/isolated"
import "modus:contract/remote"
import "modus:contract/ring"
import "modus:disk_process"
import "modus:principals"
import "modus:contract/root_ring"
import "modus:system"

// The rows of every principal fit in the client table, so a key of a disk
// grant table always gets a row, or is contested when another principal
// holds the same key.
#assert(remote.CLIENT_ROWS_OF_ONE_PRINCIPAL * principals.PRINCIPAL_CAPACITY <= remote.CLIENT_CAPACITY)

// The client table, which this service writes; `remote` maps it read-only.
client_table_memory: system.Handle
client_table: ^remote.Client_Table
// The last serial that a row received. Each grant gets the next one, so a
// serial is never given two times in a run.
client_serial_last: u64

// The grant of one row of the client table that a connection carries.
// place is the row + 1: 0 is a connection that carries no row.
Client_Grant :: struct {
	place:     int,
	serial:    u64,
	principal: u64,
	key:       [32]u8,
}

// remote_clients_create makes the client table, empty.
remote_clients_create :: proc "contextless" () {
	status: call_outcome.Call_Outcome
	client_table_memory, status = system.memory_create(remote.CLIENT_TABLE_PAGES)
	table: rawptr
	if status == .Succeeded {
		table, status = system.memory_map(client_table_memory)
	}
	if status != .Succeeded {
		fail("cannot create the client table of remote", status)
	}
	client_table = (^remote.Client_Table)(table)
}

// client_row_write writes one row of the client table, then wakes `remote`,
// which waits on the version of the table: a revocation ends the
// connection of the client at once, not at the next deadline of its QUIC.
client_row_write :: proc "contextless" (place: int, client: remote.Client) {
	written := client
	// The wide grant of a key stays through each other change of its row:
	// only the path of the grant writes it (wide_grant_row_set), so a call
	// of `remote` under a grant never finds its row without it.
	if place >= 0 && place < remote.CLIENT_CAPACITY && client_table.clients[place].key == client.key && client.serial != 0 {
		written.wide_grant = client_table.clients[place].wide_grant
	}
	remote.client_table_write(client_table, place, written)
	system.word_wake(&client_table.version, system.WAKE_ALL)
}

// key_head_text writes the first 8 bytes of a key as 16 hexadecimal
// digits: the part of a key that a reader compares on the log.
key_head_text :: proc "contextless" (buffer: ^[16]u8, key: [32]u8) -> string {
	digits := "0123456789abcdef"
	for index in 0 ..< 8 {
		buffer[2 * index] = digits[key[index] >> 4]
		buffer[2 * index + 1] = digits[key[index] & 0x0F]
	}
	return string(buffer[:])
}

// remote_client_command serves Root_Command.Remote_Client: the allow, the
// revocation and the read of a row of the client table, for the principal
// of the caller. A refusal writes its own error record in values: the
// values of the command hold a key where a name would be.
remote_client_command :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Remote_Client)
	// The principal gives a grant: only a process that acts for it may ask,
	// and the grant is of that principal only.
	if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1)
	}
	principal := caller.principal
	table := disk_grant_table_of(principal)
	if table == nil {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Principals, 0)
	}
	action, action_outcome, action_refusal := root_ring.member_of_word(root_ring.Remote_Client_Action, record.values[4], .Remote_Client, REMOTE_CLIENT_ACTION_ARGUMENT)
	if action_outcome != .Succeeded {
		values^ = action_refusal
		return action_outcome
	}
	if action == .Read {
		place := record.values[5]
		if place >= remote.CLIENT_READ_PLACES {
			return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 2, i64(min(place, 1 << 62)), remote.CLIENT_READ_PLACES - 1)
		}
		// A caller reads the keys of its own principal: the keys that
		// another principal allowed are facts of that principal.
		values^ = {}
		if place < remote.CLIENT_CAPACITY {
			row := client_table.clients[place]
			if row.serial != 0 && row.principal == principal {
				key := transmute([4]u64)row.key
				state := root_ring.Remote_Client_State.Holds
				if row.contested != 0 {
					state = .Contested
				} else if row.session_locked != 0 {
					state = .Locked
				}
				values^ = {key[0], key[1], key[2], key[3], row.principal, row.uses, u64(state)}
			}
			return .Succeeded
		}
		// A key of the disk grant table of the principal whose row is a
		// row of another principal: the key is contested.
		index := int(place - remote.CLIENT_CAPACITY)
		if index < table.client_key_count {
			contested := table.client_keys[index]
			holder := remote.client_find(&client_table.clients, contested.key)
			if holder >= 0 && client_table.clients[holder].principal != principal {
				key := transmute([4]u64)contested.key
				values^ = {key[0], key[1], key[2], key[3], principal, remote.client_uses_word(contested.uses), u64(root_ring.Remote_Client_State.Contested)}
			}
		}
		return .Succeeded
	}
	key := transmute([32]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	if key == ([32]u8{}) {
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 1)
	}
	place := remote.client_find(&client_table.clients, key)
	head: [16]u8
	switch action {
	case .Read:
		// Served above, before the check of the key: this arm is reached
		// only if that block moves, and then it refuses, never answers Ok
		// with values that it did not write.
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, REMOTE_CLIENT_ACTION_ARGUMENT, i64(min(record.values[4], 1 << 62)), i64(max(root_ring.Remote_Client_Action)))
	case .Allow:
		// The uses are a word of the caller: the border refuses a bit that
		// names no use, no use, and Input without View.
		asked, asked_known := remote.client_uses_of_word(record.values[5])
		if !asked_known {
			return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, REMOTE_CLIENT_USES_ARGUMENT, i64(min(record.values[5], 1 << 62)), i64(remote.client_uses_word({.Calls, .View, .Input})))
		}
		if place >= 0 {
			if client_table.clients[place].principal != principal {
				// One key acts for one principal: else a call of the client
				// would not say for whom it acts.
				return root_ring.refuse(values, .Name_Already_Taken, kind, .Exists, .Grants, 1)
			}
			// The row of the principal: the uses grow, and the serial
			// stays, so no connection of the key ends.
			held, _ := remote.client_uses_of_word(client_table.clients[place].uses)
			if asked <= held {
				return .Succeeded
			}
			if persisted_table_refusal(principal) {
				return root_ring.refuse(values, .Wrong_State, kind, .State)
			}
			combined := held + asked
			_ = disk_process.table_client_key_add(table, key, combined)
			persisted_table_changed(principal)
			changed := client_table.clients[place]
			changed.uses = remote.client_uses_word(combined)
			client_row_write(place, changed)
			system.log_fact(.Info, Client_Key_Uses_Added{principal = principal, client_key = text_field(key_head_text(&head, key), 24), uses = text_field(client_uses_text(combined), 24)})
			return .Succeeded
		}
		// Every allowed client key and its uses (Calls, View, Input) go into
		// the disk grant table of the principal: a change that the table
		// refuses now would be lost at its read, or would not reach the disk.
		if persisted_table_refusal(principal) {
			return root_ring.refuse(values, .Wrong_State, kind, .State)
		}
		// One principal holds part of the table only: else it would leave
		// no row to the other principals of the machine. A contested key of
		// its disk grant table, whose row is a row of another principal,
		// counts too.
		rows_of_the_principal := 0
		for row in client_table.clients {
			if row.serial != 0 && row.principal == principal {
				rows_of_the_principal += 1
			}
		}
		rows_of_the_principal = max(rows_of_the_principal, table.client_key_count)
		if rows_of_the_principal >= remote.CLIENT_ROWS_OF_ONE_PRINCIPAL {
			return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, kind, .Full, .Grants, 0, i64(rows_of_the_principal), remote.CLIENT_ROWS_OF_ONE_PRINCIPAL)
		}
		// A new row takes the state of the session of its principal: no
		// key opens a connection for a principal whose session is locked,
		// whichever process asked.
		locked: u64 = principal_records[principal].state == .Locked ? 1 : 0
		for &row, free in client_table.clients {
			if row.serial != 0 {
				continue
			}
			client_serial_last += 1
			client_row_write(free, {key = key, principal = principal, serial = client_serial_last, session_locked = locked, uses = remote.client_uses_word(asked), not_in_front = client_not_in_front(principal)})
			// It fits: the count of the keys of the table is under the
			// bound of one principal, the key is not zero bytes, and asked
			// passed client_uses_of_word.
			_ = disk_process.table_client_key_add(table, key, asked)
			if .Calls not_in asked {
				system.log_fact(.Info, Client_Key_Allowed_For_Display{principal = principal, client_key = text_field(key_head_text(&head, key), 24), uses = text_field(client_uses_text(asked), 24)})
			} else {
				client_key_allowed_log(principal, key)
			}
			persisted_table_changed(principal)
			principals_client_key_tell(principal, .Allow, key, asked)
			return .Succeeded
		}
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, kind, .Full, .Grants, 0, 0, remote.CLIENT_CAPACITY)
	case .Revoke:
		if place < 0 || client_table.clients[place].principal != principal {
			// A contested key of the disk grant table of the caller, whose
			// row is a row of another principal: the revocation takes it
			// out of the table, and the key holds again for the other.
			if disk_process.table_client_key_remove(table, key) == .None {
				values[0] = 0
				system.log_fact(.Info, Client_Key_Revoked_Contested{principal = principal, client_key = text_field(key_head_text(&head, key), 24)})
				values[1] = persisted_table_revocation(principal, key) ? root_ring.REMOTE_CLIENT_KEY_CAN_COME_BACK : 0
				client_contest_end(principal, key)
				return .Succeeded
			}
			return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
		}
		revoked_uses, _ := remote.client_uses_of_word(client_table.clients[place].uses)
		client_row_write(place, {})
		principals_client_key_tell(principal, .Revoke, key, {})
		count := client_connections_end(place)
		values^ = {}
		values[0] = count
		system.log_fact(.Info, Client_Key_Revoked{principal = principal, connections_ended = count, client_key = text_field(key_head_text(&head, key), 24), uses = text_field(client_uses_text(revoked_uses), 24)})
		// Every allowed key and its uses live in the disk grant table:
		// revocation clears the row and writes the table.
		if disk_process.table_client_key_remove(table, key) == .None || revoked_uses != {} {
			values[1] = persisted_table_revocation(principal, key) ? root_ring.REMOTE_CLIENT_KEY_CAN_COME_BACK : 0
		}
		// The key has no row now: a principal whose disk grant table holds
		// it too, for which it was contested, takes it.
		client_keys_restore()
		return .Succeeded
	}
	// Each arm returns: only an action that skipped the border reaches here.
	return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, REMOTE_CLIENT_ACTION_ARGUMENT, i64(min(record.values[4], 1 << 62)), i64(max(root_ring.Remote_Client_Action)))
}

// The argument of the error record of a refused action: the place of the
// action among the values of the command.
REMOTE_CLIENT_ACTION_ARGUMENT :: 2
// The argument of the error record of refused uses.
REMOTE_CLIENT_USES_ARGUMENT :: 3

// client_uses_text gives the uses of a key in words, for a line of the log.
client_uses_text :: proc "contextless" (uses: remote.Client_Uses) -> string {
	switch {
	case uses >= {.Calls, .View, .Input}:
		return "calls, view and input"
	case uses >= {.Calls, .View}:
		return "calls and view"
	case uses >= {.View, .Input}:
		return "view and input"
	case .View in uses:
		return "view"
	case .Calls in uses:
		return "calls"
	}
	return "no use"
}

// client_connections_end ends each connection to a service that this
// service made for a row of the client table, and gives their count.
client_connections_end :: proc "contextless" (place: int) -> (count: u64) {
	for &connection in connections {
		if connection.caller != nil && connection.client.place == place + 1 {
			disconnect(&connection)
			count += 1
		}
	}
	return count
}

// client_key_allowed_log writes the line of an allow of a client key of
// Calls, with how long the key lasts, as its disk grant table says: one
// fact type for each case, as a fact template has no condition.
client_key_allowed_log :: proc "contextless" (principal: u64, key: [32]u8) {
	head: [16]u8
	client_key := text_field(key_head_text(&head, key), 24)
	switch {
	case principal == principals.MACHINE && persisted_tables[principals.MACHINE].state == .No_Passphrase:
		system.log_fact(.Info, Client_Key_Allowed_Until_Stop{principal = principal, client_key = client_key})
	case disk_grant_tables[principal].forget_by_default:
		system.log_fact(.Info, Client_Key_Allowed_Until_Stop_Forgotten{principal = principal, client_key = client_key})
	case:
		system.log_fact(.Info, Client_Key_Allowed_Kept{principal = principal, client_key = client_key})
	}
}

// client_keys_restore gives a row of the client table to each key of a disk
// grant table that has none, with a new serial and the state of the
// session of its principal (remote.client_restore_decision). A key that
// another principal allowed too holds for neither: the row of the other
// principal becomes contested, its connections end, and one line names
// both principals. A call of either client would else act for a principal
// that its device was not given to.
client_keys_restore :: proc "contextless" () {
	if client_table == nil {
		return
	}
	head: [16]u8
	for principal in 0 ..< u64(principals.PRINCIPAL_CAPACITY) {
		table := &disk_grant_tables[principal]
		for index in 0 ..< clamp(table.client_key_count, 0, disk_process.CLIENT_KEY_CAPACITY) {
			entry := table.client_keys[index]
			key := entry.key
			uses_word := remote.client_uses_word(entry.uses)
			action, place := remote.client_restore_decision(&client_table.clients, key, principal)
			switch action {
			case .Holds:
				if client_table.clients[place].uses != uses_word {
					changed := client_table.clients[place]
					held, _ := remote.client_uses_of_word(changed.uses)
					if !(held <= entry.uses) {
						client_serial_last += 1
						changed.serial = client_serial_last
						changed.uses = uses_word
						client_row_write(place, changed)
						_ = client_connections_end(place)
					} else {
						changed.uses = uses_word
						client_row_write(place, changed)
					}
				}
			case .Contested:
			case .Take_Row:
				locked: u64 = principal_records[principal].state == .Locked ? 1 : 0
				client_serial_last += 1
				client_row_write(place, {key = key, principal = principal, serial = client_serial_last, session_locked = locked, uses = uses_word, not_in_front = client_not_in_front(principal)})
				if .Calls in entry.uses {
					system.log_fact(.Info, Client_Key_Restored{principal = principal, client_key = text_field(key_head_text(&head, key), 24)})
				} else {
					system.log_fact(.Info, Client_Key_Restored_For_Display{principal = principal, client_key = text_field(key_head_text(&head, key), 24), uses = text_field(client_uses_text(entry.uses), 24)})
				}
			case .Contest:
				changed := client_table.clients[place]
				client_serial_last += 1
				changed.serial = client_serial_last
				changed.contested = principal + 1
				client_row_write(place, changed)
				count := client_connections_end(place)
				system.log_fact(.Warning, Client_Key_Contested{principal = changed.principal, other_principal = principal, connections_ended = count, client_key = text_field(key_head_text(&head, key), 24)})
			case .No_Free_Row:
				// The rows of every principal fit (the assertion at the top
				// of this file), so this is a fault; it is said, not hidden.
				system.log_fact(.Warning, Client_Table_Full{principal = principal, client_key = text_field(key_head_text(&head, key), 24)})
			}
		}
	}
}

// client_contest_end gives the row of a contested key back to its holder
// when the other principal revoked the key: the key is in one disk grant
// table now. The row gets a new serial.
client_contest_end :: proc "contextless" (revoking_principal: u64, key: [32]u8) {
	place := remote.client_find(&client_table.clients, key)
	if place < 0 || client_table.clients[place].contested != revoking_principal + 1 {
		return
	}
	changed := client_table.clients[place]
	client_serial_last += 1
	changed.serial = client_serial_last
	changed.contested = 0
	client_row_write(place, changed)
	head: [16]u8
	system.log_fact(.Info, Client_Key_Contest_Ended{principal = changed.principal, revoking_principal = revoking_principal, client_key = text_field(key_head_text(&head, key), 24)})
}

// client_keys_after_read makes the client table hold the keys of the disk
// grant table of a principal that its read took. The read replaces each
// grant made before the key of the table came: a row of the principal whose
// key the table does not hold ends, with its connections. Then each key of
// the table gets a row.
client_keys_after_read :: proc "contextless" (principal: u64) {
	if client_table == nil || principal >= principals.PRINCIPAL_CAPACITY {
		return
	}
	table := &disk_grant_tables[principal]
	head: [16]u8
	for row, place in client_table.clients {
		if row.serial == 0 || row.principal != principal || disk_process.table_client_key_find(table, row.key) >= 0 {
			continue
		}
		client_row_write(place, {})
		count := client_connections_end(place)
		system.log_fact(.Warning, Client_Key_Not_In_Table{principal = principal, connections_ended = count, client_key = text_field(key_head_text(&head, row.key), 24)})
	}
	client_keys_restore()
}

// remote_clients_session_changed gives each row of a principal a new
// serial when its session is locked or unlocked. While it is locked a row
// holds no grant: the key opens no connection of `remote`, and each
// connection to a service for the row ends. principal 0 has no session to
// lock.
remote_clients_session_changed :: proc "contextless" (principal: u64, locked: bool) {
	if client_table == nil {
		return
	}
	for row, place in client_table.clients {
		if row.serial == 0 || row.principal != principal {
			continue
		}
		changed := row
		client_serial_last += 1
		changed.serial = client_serial_last
		changed.session_locked = locked ? 1 : 0
		client_row_write(place, changed)
		if locked {
			client_connections_end(place)
		}
	}
	// The session in front changed: the rows of the other principals lose
	// the screen, and the rows of the principal in front get it back.
	remote_clients_front_follow()
}

// client_not_in_front gives the flag not_in_front of a new row of a
// principal: the session in front now is desktop_principal().
client_not_in_front :: proc "contextless" (principal: u64) -> u64 {
	return remote.client_display_paused(principal, desktop_principal()) ? 1 : 0
}

// remote_clients_front_follow writes the flag not_in_front of each row for
// the session in front: a row of another principal holds no View and no
// Input (src/md/features/remote_display.md, "The authority"). A row with
// View whose flag changes gets a new serial, as a lock does, so a session
// of remote_display open through it ends, and no pass of that service can
// miss the change; its connections to services end with the old serial.
remote_clients_front_follow :: proc "contextless" () {
	if client_table == nil {
		return
	}
	in_front := desktop_principal()
	head: [16]u8
	for row, place in client_table.clients {
		if row.serial == 0 {
			continue
		}
		flag: u64 = remote.client_display_paused(row.principal, in_front) ? 1 : 0
		if flag == row.not_in_front {
			continue
		}
		changed := row
		changed.not_in_front = flag
		uses, known := remote.client_uses_of_word(row.uses)
		if known && .View in uses {
			client_serial_last += 1
			changed.serial = client_serial_last
			client_row_write(place, changed)
			count := client_connections_end(place)
			if flag == 1 {
				system.log_fact(.Info, Client_Key_View_Paused{principal = row.principal, front_principal = in_front, connections_ended = count, client_key = text_field(key_head_text(&head, row.key), 24)})
			} else {
				system.log_fact(.Info, Client_Key_View_Back{principal = row.principal, client_key = text_field(key_head_text(&head, row.key), 24)})
			}
			continue
		}
		client_row_write(place, changed)
	}
}

// client_grant_of checks the row that a Connect of `remote` names: the row
// values[4] - 1 with the serial values[5], whose grant holds. A refusal
// writes its own error record in values.
client_grant_of :: proc "contextless" (caller: ^Started, row_number: u64, serial: u64, values: ^[7]u64) -> (client: Client_Grant, outcome: call_outcome.Call_Outcome) {
	kind := u32(root_ring.Root_Command.Connect)
	if .Remote_Clients not_in caller.start_grant_set.grants || row_number == 0 {
		// Only the process of the client table connects for a row, and it
		// connects for a row only: a call from another machine acts for a
		// principal that allowed its client, and never for the session of
		// that process.
		return {}, root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Connection, 2)
	}
	if row_number > remote.CLIENT_CAPACITY {
		return {}, root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 2, i64(min(row_number, 1 << 62)), remote.CLIENT_CAPACITY)
	}
	place := int(row_number - 1)
	row := client_table.clients[place]
	if row.serial == 0 || row.serial != serial {
		return {}, root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 2)
	}
	// The session of the principal of the row is locked: the row exists,
	// and the call applies once the session is unlocked.
	if row.session_locked != 0 {
		return {}, root_ring.refuse(values, .Wrong_State, kind, .State, .Principals, 2, i64(row.principal))
	}
	// A key of the view alone makes no call: remote refuses it in its
	// handshake, and this service does not trust remote with that rule.
	if uses, known := remote.client_uses_of_word(row.uses); !known || .Calls not_in uses {
		return {}, root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Grants, 2)
	}
	if row.contested != 0 {
		// A contest gives the row a new serial, and remote binds no client
		// to a contested row; the check holds the rule here too, as this
		// service does not trust remote with it.
		head: [16]u8
		system.log_fact(.Warning, Remote_Connection_Refused_Contested{principal = row.principal, other_principal = row.contested - 1, client_key = text_field(key_head_text(&head, row.key), 24)})
		return {}, root_ring.refuse(values, .Wrong_State, kind, .State, .Grants, 2)
	}
	return {place = place + 1, serial = row.serial, principal = row.principal, key = row.key}, .Succeeded
}

// connection_principal gives the principal that the caller of a connection
// is for: the principal of the row of the client table for a connection of
// `remote`, else the principal of the session of the caller. Each rule that
// compares a principal with the caller of a connection reads it here.
connection_principal :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.client.place != 0 {
		return connection.client.principal
	}
	return connection.caller.principal
}

// client_connection_grant gives what the caller of a connection for a row
// receives in its service: the principal of the row, and the flag to act
// for it while the caller holds the grant to act for a principal. No store:
// the process of the client table has none.
client_connection_grant :: proc "contextless" (caller: ^Started, client: Client_Grant) -> u64 {
	acts := .Acts_For_Principal in caller.start_grant_set.grants && .Acts_For_Principal not_in caller.revoked
	return isolated.caller_grant_make(0, client.principal, acts)
}
