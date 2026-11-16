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
// Each allowed key is also a client key of the disk grant table of its
// principal (persisted_grant_table.odin), so the grant lasts across a
// restart where that table lasts. The client table is the form of the keys
// while the machine runs: after the read of a table, each of its keys gets
// a row again, with a new serial. A key that another principal allowed too
// is contested: it acts for neither until one of them revokes it.

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/remote"
import "modus:contract/ring"
import "modus:support/disk_program"
import "modus:support/principals"
import "modus:support/system"

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
	status: system.Status
	client_table_memory, status = system.memory_create(1)
	table: rawptr
	if status == .Ok {
		table, status = system.memory_map(client_table_memory)
	}
	if status != .Ok {
		fail("cannot create the client table of remote", status)
	}
	client_table = (^remote.Client_Table)(table)
}

// client_row_write writes one row of the client table, then wakes `remote`,
// which waits on the version of the table: a revocation ends the
// connection of the client at once, not at the next deadline of its QUIC.
client_row_write :: proc "contextless" (place: int, client: remote.Client) {
	remote.client_table_write(client_table, place, client)
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
remote_client_command :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(system.Root_Command.Remote_Client)
	// The principal gives a grant: only a program that acts for it may ask,
	// and the grant is of that principal only.
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right
	}
	principal := caller.principal
	table := disk_grant_table_of(principal)
	if table == nil {
		values^ = errors.ring_fail(kind, .Absent, .Principals, 0)
		return .Bad_State
	}
	action, action_status, action_refusal := system.ring_member_of_word(system.Remote_Client_Action, record.values[4], .Remote_Client, REMOTE_CLIENT_ACTION_ARGUMENT)
	if action_status != .Ok {
		values^ = action_refusal
		return action_status
	}
	if action == .Read {
		place := record.values[5]
		if place >= remote.CLIENT_READ_PLACES {
			values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(place, 1 << 62)), remote.CLIENT_READ_PLACES - 1)
			return .Bad_Operation
		}
		// A caller reads the keys of its own principal: the keys that
		// another principal allowed are facts of that principal.
		values^ = {}
		if place < remote.CLIENT_CAPACITY {
			row := client_table.clients[place]
			if row.serial != 0 && row.principal == principal {
				key := transmute([4]u64)row.key
				state := system.Remote_Client_State.Holds
				if row.contested != 0 {
					state = .Contested
				} else if row.session_locked != 0 {
					state = .Locked
				}
				values^ = {key[0], key[1], key[2], key[3], row.principal, 1, u64(state)}
			}
			return .Ok
		}
		// A key of the disk grant table of the principal whose row is a
		// row of another principal: the key is contested.
		index := int(place - remote.CLIENT_CAPACITY)
		if index < table.client_key_count {
			contested := table.client_keys[index]
			holder := remote.client_find(&client_table.clients, contested)
			if holder >= 0 && client_table.clients[holder].principal != principal {
				key := transmute([4]u64)contested
				values^ = {key[0], key[1], key[2], key[3], principal, 1, u64(system.Remote_Client_State.Contested)}
			}
		}
		return .Ok
	}
	key := transmute([32]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	if key == ([32]u8{}) {
		values^ = errors.ring_fail(kind, .Bad_Value, .None, 1)
		return .Bad_Operation
	}
	place := remote.client_find(&client_table.clients, key)
	head: [16]u8
	switch action {
	case .Read:
		// Served above, before the check of the key: this arm is reached
		// only if that block moves, and then it refuses, never answers Ok
		// with values that it did not write.
		values^ = errors.ring_fail(kind, .Bad_Value, .None, REMOTE_CLIENT_ACTION_ARGUMENT, i64(min(record.values[4], 1 << 62)), i64(max(system.Remote_Client_Action)))
		return .Bad_Operation
	case .Allow:
		if place >= 0 {
			if client_table.clients[place].principal != principal {
				// One key acts for one principal: else a call of the client
				// would not say for whom it acts.
				values^ = errors.ring_fail(kind, .Exists, .Grants, 1)
				return .Bad_State
			}
			return .Ok
		}
		// The key goes into the disk grant table of the principal: a change
		// that the table refuses now would be lost at its read, or would
		// not reach the disk.
		if persisted_table_refusal(principal) {
			values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
			return .Bad_State
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
			values^ = errors.ring_fail(kind, .Full, .Grants, 0, i64(rows_of_the_principal), remote.CLIENT_ROWS_OF_ONE_PRINCIPAL)
			return .No_Slot
		}
		// A new row takes the state of the session of its principal: no
		// key opens a connection for a principal whose session is locked,
		// whichever program asked.
		locked: u64 = principal_records[principal].state == .Locked ? 1 : 0
		for &row, free in client_table.clients {
			if row.serial != 0 {
				continue
			}
			client_serial_last += 1
			client_row_write(free, {key = key, principal = principal, serial = client_serial_last, session_locked = locked})
			// It fits: the count of the keys of the table is under the
			// bound of one principal, and the key is not zero bytes.
			_ = disk_program.table_client_key_add(table, key)
			system.log_in("calls", .Info, "root: principal ", principal, " allowed the client key ", key_head_text(&head, key), " of remote: each call of that client acts for it", client_key_lasts(principal))
			persisted_table_changed(principal)
			return .Ok
		}
		values^ = errors.ring_fail(kind, .Full, .Grants, 0, 0, remote.CLIENT_CAPACITY)
		return .No_Slot
	case .Revoke:
		if place < 0 || client_table.clients[place].principal != principal {
			// A contested key of the disk grant table of the caller, whose
			// row is a row of another principal: the revocation takes it
			// out of the table, and the key holds again for the other.
			if disk_program.table_client_key_remove(table, key) == .None {
				values[0] = 0
				system.log_in("calls", .Info, "root: principal ", principal, " revoked the client key ", key_head_text(&head, key), " of remote, which was contested: connections to services ended: 0")
				values[1] = persisted_table_revocation(principal, key) ? system.REMOTE_CLIENT_KEY_CAN_COME_BACK : 0
				client_contest_end(principal, key)
				return .Ok
			}
			values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
			return .Bad_Handle
		}
		client_row_write(place, {})
		count := client_connections_end(place)
		values[0] = count
		system.log_in("calls", .Info, "root: principal ", principal, " revoked the client key ", key_head_text(&head, key), " of remote: connections to services ended: ", count)
		_ = disk_program.table_client_key_remove(table, key)
		values[1] = persisted_table_revocation(principal, key) ? system.REMOTE_CLIENT_KEY_CAN_COME_BACK : 0
		// The key has no row now: a principal whose disk grant table holds
		// it too, for which it was contested, takes it.
		client_keys_restore()
		return .Ok
	}
	// Each arm returns: only an action that skipped the border reaches here.
	values^ = errors.ring_fail(kind, .Bad_Value, .None, REMOTE_CLIENT_ACTION_ARGUMENT, i64(min(record.values[4], 1 << 62)), i64(max(system.Remote_Client_Action)))
	return .Bad_Operation
}

// The argument of the error record of a refused action: the place of the
// action among the values of the command.
REMOTE_CLIENT_ACTION_ARGUMENT :: 2

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

// client_key_lasts gives the end of the line of an allow: how long the key
// lasts, as its disk grant table says.
client_key_lasts :: proc "contextless" (principal: u64) -> string {
	if principal == principals.MACHINE && persisted_tables[principals.MACHINE].state == .No_Passphrase {
		return "; principal 0 has no passphrase, so the key lasts until the machine stops"
	}
	if disk_grant_tables[principal].forget_by_default {
		return "; the disk grant table of the principal keeps nothing across a restart (disk_persistence), so the key lasts until the machine stops"
	}
	return "; the disk grant table of the principal keeps the key across a restart"
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
		for index in 0 ..< clamp(table.client_key_count, 0, disk_program.CLIENT_KEY_CAPACITY) {
			key := table.client_keys[index]
			action, place := remote.client_restore_decision(&client_table.clients, key, principal)
			switch action {
			case .Holds, .Contested:
			case .Take_Row:
				locked: u64 = principal_records[principal].state == .Locked ? 1 : 0
				client_serial_last += 1
				client_row_write(place, {key = key, principal = principal, serial = client_serial_last, session_locked = locked})
				system.log_in("calls", .Info, "root: the client key ", key_head_text(&head, key), " of remote holds again for principal ", principal, ", from its disk grant table: each call of that client acts for it")
			case .Contest:
				changed := client_table.clients[place]
				client_serial_last += 1
				changed.serial = client_serial_last
				changed.contested = principal + 1
				client_row_write(place, changed)
				count := client_connections_end(place)
				system.log_in("calls", .Warning, "root: the client key ", key_head_text(&head, key), " of remote is contested: principal ", changed.principal, " allowed it since the machine started, and the disk grant table of principal ", principal, " holds it; it acts for neither until one of them revokes it; connections to services ended: ", count)
			case .No_Free_Row:
				// The rows of every principal fit (the assertion at the top
				// of this file), so this is a fault; it is said, not hidden.
				system.log_in("calls", .Warning, "root: the client table of remote has no free row for the client key ", key_head_text(&head, key), " of principal ", principal, ": the key holds for no principal")
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
	system.log_in("calls", .Info, "root: the client key ", key_head_text(&head, key), " of remote holds again for principal ", changed.principal, ": principal ", revoking_principal, " revoked it, so it is no longer contested")
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
		if row.serial == 0 || row.principal != principal || disk_program.table_client_key_find(table, row.key) >= 0 {
			continue
		}
		client_row_write(place, {})
		count := client_connections_end(place)
		system.log_in("calls", .Warning, "root: the client key ", key_head_text(&head, row.key), " of remote, which principal ", principal, " allowed before its disk grant table was read, is not in that table: its grant ends; connections to services ended: ", count)
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
}

// client_grant_of checks the row that a Connect of `remote` names: the row
// values[4] - 1 with the serial values[5], whose grant holds. A refusal
// writes its own error record in values.
client_grant_of :: proc "contextless" (caller: ^Started, row_number: u64, serial: u64, values: ^[7]u64) -> (client: Client_Grant, status: system.Status) {
	kind := u32(system.Root_Command.Connect)
	if .Remote_Clients not_in caller.role || row_number == 0 {
		// Only the program of the client table connects for a row, and it
		// connects for a row only: a call from another machine acts for a
		// principal that allowed its client, and never for the session of
		// that program.
		values^ = errors.ring_fail(kind, .No_Grant, .Connection, 2)
		return {}, .No_Right
	}
	if row_number > remote.CLIENT_CAPACITY {
		values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(row_number, 1 << 62)), remote.CLIENT_CAPACITY)
		return {}, .Bad_Operation
	}
	place := int(row_number - 1)
	row := client_table.clients[place]
	if row.serial == 0 || row.serial != serial {
		values^ = errors.ring_fail(kind, .Absent, .Grants, 2)
		return {}, .Bad_State
	}
	if row.session_locked != 0 {
		values^ = errors.ring_fail(kind, .Absent, .Principals, 2, i64(row.principal))
		return {}, .Bad_State
	}
	if row.contested != 0 {
		// A contest gives the row a new serial, and remote binds no client
		// to a contested row; the check holds the rule here too, as this
		// service does not trust remote with it.
		head: [16]u8
		system.log_in("calls", .Warning, "root: refused a connection of remote for the client key ", key_head_text(&head, row.key), ": it is contested between principal ", row.principal, " and principal ", row.contested - 1, ", and acts for neither")
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return {}, .Bad_State
	}
	return {place = place + 1, serial = row.serial, principal = row.principal, key = row.key}, .Ok
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
// the program of the client table has none.
client_connection_grant :: proc "contextless" (caller: ^Started, client: Client_Grant) -> u64 {
	acts := .Acts_For_Principal in caller.role && .Acts_For_Principal not_in caller.revoked
	return isolated.caller_grant_make(0, client.principal, acts)
}
