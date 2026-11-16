package remote

import "base:intrinsics"

// The client table: the keys of the clients of the remote service that a
// principal allowed, each with that principal (docs/PRINCIPALS.md, "The
// client keys of remote"; src/md/features/remote_client_keys.md).
//
// The root service is its one writer: a console that acts for its principal
// sends Remote_Client to allow or to revoke a key, and the root service
// changes the row. The remote service maps the table with the right Read
// only (GRANT_CLIENT_TABLE). It reads it at each handshake, to allow or to
// refuse the proven key of a client, and at each pass of its loop, to end
// the connection of a client whose row changed.
//
// A row is a grant of one principal to one key. Its serial names that
// grant: the root service gives each new row, each lock and each unlock of
// the session of its principal a new serial. A connection of the remote
// service to a service is made for one row and one serial (Root_Command.
// Connect); when the serial of the row is no longer that one, the grant
// that the connection carried ended.
//
// The table lasts until the machine stops. The disk grant table of each
// principal keeps its keys across a restart (modus:support/disk_program),
// and the root service gives each of them a row again, with a new serial,
// after the read of that table.

// The handle of the context of the remote service: the client table, one
// page, with the right Read.
GRANT_CLIENT_TABLE :: 12

// The rows of the table: the keys that the principals of one machine
// allowed at one time. Remote_Client refuses one more with Full.
CLIENT_CAPACITY :: 8
// The rows of one principal at most: one principal that allows many keys
// leaves rows to the others. Remote_Client refuses one more with Full.
CLIENT_ROWS_OF_ONE_PRINCIPAL :: CLIENT_CAPACITY / 2
// The places that a read of the client keys of one principal names
// (Root_Command.Remote_Client): the rows of the client table, then the keys
// of the disk grant table of the principal, which keeps
// CLIENT_ROWS_OF_ONE_PRINCIPAL keys at most.
CLIENT_READ_PLACES :: CLIENT_CAPACITY + CLIENT_ROWS_OF_ONE_PRINCIPAL

// One row of the client table. A row with a serial of 0 is free.
Client :: struct {
	key:            [32]u8, // The Ed25519 public key that the client proves in the handshake.
	principal:      u64, // The principal that allowed the key: each call of the client acts for it.
	serial:         u64, // The grant: a new value at each allow, lock and unlock. 0: the row is free.
	session_locked: u64, // 1 while the session of the principal is locked: the key opens no connection, and an open one ends.
	// The other principal whose disk grant table also holds the key, plus
	// one; 0: none. A contested row holds no grant for either principal,
	// until one of them revokes the key.
	contested:      u64,
}

// The client table, in one page that the root service writes.
Client_Table :: struct {
	version: u32, // Odd while the root service writes; one more at each start and each end of a write.
	_:       u32,
	clients: [CLIENT_CAPACITY]Client,
}
#assert(size_of(Client_Table) <= 4096)

// client_table_read copies the rows of a client table that another program
// writes. It reads again while the table changes, so the copy is one state
// of the table.
client_table_read :: proc "contextless" (table: ^Client_Table, clients: ^[CLIENT_CAPACITY]Client) {
	if table == nil {
		clients^ = {}
		return
	}
	for {
		version := intrinsics.atomic_load_explicit(&table.version, .Acquire)
		if version & 1 != 0 {
			continue
		}
		intrinsics.mem_copy_non_overlapping(clients, &table.clients, size_of(table.clients))
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&table.version, .Relaxed) == version {
			return
		}
	}
}

// client_table_write writes one row of a client table: a new grant, or a
// row of zeros that frees the place. The one writer is the root service.
client_table_write :: proc "contextless" (table: ^Client_Table, place: int, client: Client) {
	if place < 0 || place >= CLIENT_CAPACITY {
		return
	}
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
	intrinsics.atomic_thread_fence(.Release)
	table.clients[place] = client
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
}

// client_find gives the place of the row of a key in a copy of the table,
// or -1. A free row has no key.
client_find :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, key: [32]u8) -> int {
	if key == ([32]u8{}) {
		return -1
	}
	for client, place in clients^ {
		if client.serial != 0 && client.key == key {
			return place
		}
	}
	return -1
}

// client_grant_holds says if the row at place of a copy of the table still
// carries the grant with this serial: the same row, not freed and not
// given again, a session of its principal that is not locked, and a key
// that no other principal holds.
client_grant_holds :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, place: int, serial: u64) -> bool {
	if place < 0 || place >= CLIENT_CAPACITY || serial == 0 {
		return false
	}
	return clients[place].serial == serial && clients[place].session_locked == 0 && clients[place].contested == 0
}

// What the root service does with a client key of the disk grant table of
// a principal, after the read of that table or the end of a grant: the
// result of client_restore_decision.
Client_Restore :: enum u8 {
	Holds, // The principal has the row of the key already.
	Take_Row, // No row has the key: the principal takes the free row at place.
	Contest, // Another principal has the row at place: the key holds for neither, and the row becomes contested.
	Contested, // The row at place is contested already.
	No_Free_Row, // No row has the key, and no row is free.
}

// client_restore_decision decides for one key of the disk grant table of
// principal. One key acts for one principal: when another principal allowed
// the same key, the key holds for neither of them, as a call would else act
// for a principal that the device of the client was not given to.
client_restore_decision :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, key: [32]u8, principal: u64) -> (action: Client_Restore, place: int) {
	holder := client_find(clients, key)
	if holder >= 0 {
		if clients[holder].principal == principal {
			return .Holds, holder
		}
		if clients[holder].contested == 0 {
			return .Contest, holder
		}
		return .Contested, holder
	}
	for client, free in clients^ {
		if client.serial == 0 {
			return .Take_Row, free
		}
	}
	return .No_Free_Row, -1
}
