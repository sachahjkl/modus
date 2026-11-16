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

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/remote"
import "modus:contract/ring"
import "modus:support/system"

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
	action := record.values[4]
	if action == system.REMOTE_CLIENT_READ {
		place := record.values[5]
		if place >= remote.CLIENT_CAPACITY {
			values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(place, 1 << 62)), remote.CLIENT_CAPACITY - 1)
			return .Bad_Operation
		}
		row := client_table.clients[place]
		// A caller reads the rows of its own principal: the keys that
		// another principal allowed are facts of that principal.
		values^ = {}
		if row.serial != 0 && row.principal == principal {
			key := transmute([4]u64)row.key
			values^ = {key[0], key[1], key[2], key[3], row.principal, 1, 0}
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
	case system.REMOTE_CLIENT_ALLOW:
		if place >= 0 {
			if client_table.clients[place].principal != principal {
				// One key acts for one principal: else a call of the client
				// would not say for whom it acts.
				values^ = errors.ring_fail(kind, .Exists, .Grants, 1)
				return .Bad_State
			}
			return .Ok
		}
		// One principal holds part of the table only: else it would leave
		// no row to the other principals of the machine.
		rows_of_the_principal := 0
		for row in client_table.clients {
			if row.serial != 0 && row.principal == principal {
				rows_of_the_principal += 1
			}
		}
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
			system.log_in("calls", .Info, "root: principal ", principal, " allowed the client key ", key_head_text(&head, key), " of remote: each call of that client acts for it")
			return .Ok
		}
		values^ = errors.ring_fail(kind, .Full, .Grants, 0, 0, remote.CLIENT_CAPACITY)
		return .No_Slot
	case system.REMOTE_CLIENT_REVOKE:
		if place < 0 || client_table.clients[place].principal != principal {
			values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
			return .Bad_Handle
		}
		client_row_write(place, {})
		count := client_connections_end(place)
		values[0] = count
		system.log_in("calls", .Info, "root: principal ", principal, " revoked the client key ", key_head_text(&head, key), " of remote: connections to services ended: ", count)
		return .Ok
	}
	values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(action, 1 << 62)), system.REMOTE_CLIENT_READ)
	return .Bad_Operation
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
