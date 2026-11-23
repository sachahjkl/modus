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
// principal keeps its keys across a restart (modus:disk_process),
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
	// The word of the uses of the key (Client_Uses): a reader takes it
	// through client_uses_of_word only.
	uses:           u64,
	// 1 while the session in front is the session of another principal
	// (client_display_paused): the row holds no View and no Input, as
	// principal 0 cannot see the screen of a named session.
	not_in_front:   u64,
	// The serial of the wide grant that the key holds, from the collector;
	// 0: none. `remote` writes an act record before each call of a key whose
	// row holds one (src/md/features/wide_grants.md, "The path of a grant,
	// end to end").
	wide_grant:     u64,
}

// client_display_paused says if a row of a principal holds no View and no
// Input while the session of another principal is in front: the screen of
// a session shows its data to its principal only.
client_display_paused :: proc "contextless" (row_principal: u64, principal_in_front: u64) -> bool {
	return row_principal != principal_in_front
}

// What a client key may do with its row (src/md/features/remote_display.md,
// "The authority"). The bit of each use is its value.
Client_Use :: enum u64 {
	Calls = 0, // The calls of `remote`, which act for the principal of the row.
	View  = 1, // The view of the screen through `remote_display`.
	Input = 2, // The keys and the pointer through `remote_display`. Never without View.
}
Client_Uses :: bit_set[Client_Use; u64]

// client_uses_word gives the word of a set of uses, as a row and a command
// carry it.
client_uses_word :: proc "contextless" (uses: Client_Uses) -> u64 {
	return transmute(u64)uses
}

// client_uses_of_word is the one border of the word of the uses: it refuses
// a bit that names no use, an empty set, and Input without View.
client_uses_of_word :: proc "contextless" (word: u64) -> (uses: Client_Uses, ok: bool) {
	known := client_uses_word({.Calls, .View, .Input})
	if word == 0 || word & ~known != 0 {
		return {}, false
	}
	uses = transmute(Client_Uses)word
	if .Input in uses && .View not_in uses {
		return {}, false
	}
	return uses, true
}

// The client table, in one page that the root service writes.
Client_Table :: struct {
	version: u32, // Odd while the root service writes; one more at each start and each end of a write.
	_:       u32,
	clients: [CLIENT_CAPACITY]Client,
}
#assert(size_of(Client_Table) <= 4096)

// client_table_read copies the rows of a client table that another process
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

// second_connection_ends_grant says if a connection of key that binds now
// ends the wide grant of its row: the row holds a grant, and another
// connection bound to the same key is open (src/md/features/wide_grants.md,
// "An agent key stolen from the host"). other_keys are the keys of the
// other connections that are bound to a row now.
second_connection_ends_grant :: proc "contextless" (row: Client, key: [32]u8, other_keys: [][32]u8) -> bool {
	if row.wide_grant == 0 || row.key != key || key == ([32]u8{}) {
		return false
	}
	for other in other_keys {
		if other == key {
			return true
		}
	}
	return false
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
// carries the grant with this serial for a use: the same row, not freed and
// not given again, a session of its principal that is not locked, a key
// that no other principal holds, a word of uses that holds the use, and,
// for View and Input, the session of its principal in front.
client_grant_holds :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, place: int, serial: u64, use: Client_Use) -> bool {
	if place < 0 || place >= CLIENT_CAPACITY || serial == 0 {
		return false
	}
	uses, uses_ok := client_uses_of_word(clients[place].uses)
	in_front := use == .Calls || clients[place].not_in_front == 0
	return clients[place].serial == serial && clients[place].session_locked == 0 && clients[place].contested == 0 && uses_ok && use in uses && in_front
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
