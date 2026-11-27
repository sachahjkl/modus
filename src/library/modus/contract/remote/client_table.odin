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

// The handle of the context of the remote service: the client table,
// CLIENT_TABLE_PAGES pages, with the right Read.
GRANT_CLIENT_TABLE :: 12

// The rows of the table: the keys that the principals of one machine
// allowed at one time (laptops, phones, agents, build keys). Remote_Client
// refuses one more with Full.
CLIENT_CAPACITY :: 64
// The rows of one principal at most: one principal that allows many keys
// leaves rows to the others across PRINCIPAL_CAPACITY (8) principals.
// Remote_Client refuses one more with Full.
CLIENT_ROWS_OF_ONE_PRINCIPAL :: CLIENT_CAPACITY / 8
// The places that a read of the client keys of one principal names
// (Root_Command.Remote_Client): the rows of the client table.
CLIENT_READ_PLACES :: CLIENT_CAPACITY

// One row of the client table, keyed by (principal_identifier, key).
// A row with a serial of 0 is free.
Client :: struct {
	key:                  [32]u8, // The Ed25519 public key that the client proves in the handshake.
	principal_identifier: [32]u8, // Persistent 256-bit principal identifier (all zero for principal 0).
	principal:            u64, // The slot of the principal that allowed the key: each call of the client acts for it.
	serial:               u64, // The grant: a new value at each allow, lock and unlock. 0: the row is free.
	session_locked:       u64, // 1 while the session of the principal is locked: the key opens no connection, and an open one ends.
	// The word of the uses of the key (Client_Uses): a reader takes it
	// through client_uses_of_word only.
	uses:                 u64,
	// 1 while the session in front is the session of another principal
	// (client_display_paused): the row holds no View and no Input, as
	// principal 0 cannot see the screen of a named session.
	not_in_front:         u64,
	// The serial of the wide grant that the key holds, from the collector;
	// 0: none. `remote` writes an act record before each call of a key whose
	// row holds one (src/md/features/wide_grants.md, "The path of a grant,
	// end to end").
	wide_grant:           u64,
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

// The client table, in the memory of CLIENT_TABLE_PAGES pages that the
// root service writes.
Client_Table :: struct {
	version: u32, // Odd while the root service writes; one more at each start and each end of a write.
	_:       u32,
	clients: [CLIENT_CAPACITY]Client,
}

// The pages of the memory of the client table: the root service makes it
// with this size, and each reader maps it whole.
CLIENT_TABLE_PAGES :: (size_of(Client_Table) + 4095) / 4096

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

// client_find_for_principal gives the place of the row of (principal, key) in
// a copy of the table, or -1. Two principals may enroll the same public key
// independently in separate rows.
client_find_for_principal :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, principal: u64, key: [32]u8) -> int {
	if key == ([32]u8{}) {
		return -1
	}
	for client, place in clients^ {
		if client.serial != 0 && client.principal == principal && client.key == key {
			return place
		}
	}
	return -1
}

// client_find_for_pair gives the place of the row matching
// (principal_identifier, principal, key), or -1.
client_find_for_pair :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, principal_identifier: [32]u8, principal: u64, key: [32]u8) -> int {
	if key == ([32]u8{}) {
		return -1
	}
	for client, place in clients^ {
		if client.serial != 0 && client.principal == principal && client.principal_identifier == principal_identifier && client.key == key {
			return place
		}
	}
	return -1
}

// client_count_holding counts how many occupied rows for `key` currently hold
// a grant for `use`.
client_count_holding :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, key: [32]u8, use: Client_Use) -> int {
	if key == ([32]u8{}) {
		return 0
	}
	count := 0
	for client, place in clients^ {
		if client.serial == 0 || client.key != key {
			continue
		}
		if client_grant_holds(clients, place, client.serial, use) {
			count += 1
		}
	}
	return count
}

// client_find_holding finds the unique row for `key` whose grant currently
// holds for `use`. Refuses ambiguous lookups (more than one holding row for
// the same key and use) by returning -1 so no call can silently bind to an
// unintended principal when two unlocked principals enrolled the same key.
client_find_holding :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, key: [32]u8, use: Client_Use) -> int {
	if key == ([32]u8{}) {
		return -1
	}
	matched := -1
	for client, place in clients^ {
		if client.serial == 0 || client.key != key {
			continue
		}
		if !client_grant_holds(clients, place, client.serial, use) {
			continue
		}
		if matched >= 0 {
			return -1
		}
		matched = place
	}
	return matched
}

// client_find_any finds any active row for `key` (for refusal diagnostics
// when no row currently holds the requested use), preferring the session in
// front.
client_find_any :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, key: [32]u8) -> int {
	if key == ([32]u8{}) {
		return -1
	}
	fallback := -1
	for client, place in clients^ {
		if client.serial == 0 || client.key != key {
			continue
		}
		if client.not_in_front == 0 {
			return place
		}
		if fallback < 0 {
			fallback = place
		}
	}
	return fallback
}

// client_grant_holds says if the row at place of a copy of the table still
// carries the grant with this serial for a use: the same row, not freed and
// not given again, a session of its principal that is not locked, a word of
// uses that holds the use, and, for View and Input, the session of its
// principal in front.
client_grant_holds :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, place: int, serial: u64, use: Client_Use) -> bool {
	if place < 0 || place >= CLIENT_CAPACITY || serial == 0 {
		return false
	}
	uses, uses_ok := client_uses_of_word(clients[place].uses)
	in_front := use == .Calls || clients[place].not_in_front == 0
	return clients[place].serial == serial && clients[place].session_locked == 0 && uses_ok && use in uses && in_front
}

// What the root service does with a client key of the disk grant table of
// a principal, after the read of that table: the result of
// client_restore_decision.
Client_Restore :: enum u8 {
	Holds, // The principal already holds a row for this key.
	Take_Row, // This principal has no row for this key yet: take the free row at place.
	No_Free_Row, // This principal has no row for this key, and no row is free.
}

// client_restore_decision decides for one key of the disk grant table of
// principal. Rows are keyed by (principal_identifier, public_key), so another
// principal enrolling the same public key never conflicts or contests.
client_restore_decision :: proc "contextless" (clients: ^[CLIENT_CAPACITY]Client, key: [32]u8, principal: u64) -> (action: Client_Restore, place: int) {
	holder := client_find_for_principal(clients, principal, key)
	if holder >= 0 {
		return .Holds, holder
	}
	for client, free in clients^ {
		if client.serial == 0 {
			return .Take_Row, free
		}
	}
	return .No_Free_Row, -1
}
