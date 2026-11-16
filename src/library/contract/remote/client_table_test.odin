#+build !freestanding
package remote

import "core:testing"

// What client_table_write writes, client_table_read reads; client_find
// finds a key in its row, and no key in a free row; client_grant_holds
// holds for the serial of the row only, and not while the session of its
// principal is locked.
@(test)
client_table_round_trip :: proc(t: ^testing.T) {
	table := new(Client_Table, context.temp_allocator)
	first := Client{key = {0 = 0x11, 31 = 0x22}, principal = 0, serial = 1}
	second := Client{key = {0 = 0x33}, principal = 1, serial = 2}
	client_table_write(table, 0, first)
	client_table_write(table, CLIENT_CAPACITY - 1, second)
	testing.expect_value(t, table.version & 1, 0)
	testing.expect_value(t, table.version, 4)
	copied: [CLIENT_CAPACITY]Client
	client_table_read(table, &copied)
	testing.expect(t, copied[0] == first)
	testing.expect(t, copied[CLIENT_CAPACITY - 1] == second)
	testing.expect_value(t, client_find(&copied, first.key), 0)
	testing.expect_value(t, client_find(&copied, second.key), CLIENT_CAPACITY - 1)
	testing.expect_value(t, client_find(&copied, [32]u8{0 = 0x44}), -1)
	// A key of zeros names no row, though each free row has zeros.
	testing.expect_value(t, client_find(&copied, [32]u8{}), -1)
	testing.expect(t, client_grant_holds(&copied, 0, first.serial))
	testing.expect(t, !client_grant_holds(&copied, 0, first.serial + 1), "another serial is another grant")
	testing.expect(t, !client_grant_holds(&copied, 1, 0), "a free row holds no grant")
	testing.expect(t, !client_grant_holds(&copied, -1, first.serial))
	testing.expect(t, !client_grant_holds(&copied, CLIENT_CAPACITY, first.serial))
	// The session of principal 1 locked: its row holds no grant, and its
	// key is still found, so the refusal names the principal.
	locked := second
	locked.session_locked = 1
	client_table_write(table, CLIENT_CAPACITY - 1, locked)
	client_table_read(table, &copied)
	testing.expect(t, !client_grant_holds(&copied, CLIENT_CAPACITY - 1, second.serial))
	testing.expect_value(t, client_find(&copied, second.key), CLIENT_CAPACITY - 1)
	// A revocation frees the row.
	client_table_write(table, 0, {})
	client_table_read(table, &copied)
	testing.expect_value(t, client_find(&copied, first.key), -1)
	testing.expect(t, !client_grant_holds(&copied, 0, first.serial))
	// A place out of the table changes nothing.
	version := table.version
	client_table_write(table, CLIENT_CAPACITY, first)
	testing.expect_value(t, table.version, version)
}

// A key of the disk grant table of a principal: its own row holds; a free
// row takes it; a row of another principal becomes contested, and holds no
// grant for either; a contested row stays so; a full table is said.
@(test)
client_restore_decides_one_key_for_one_principal :: proc(t: ^testing.T) {
	clients: [CLIENT_CAPACITY]Client
	own := [32]u8{0 = 0x11}
	other := [32]u8{0 = 0x22}
	fresh := [32]u8{0 = 0x33}
	clients[1] = {key = own, principal = 1, serial = 5}
	clients[2] = {key = other, principal = 0, serial = 6}
	action, place := client_restore_decision(&clients, own, 1)
	testing.expect(t, action == .Holds && place == 1)
	action, place = client_restore_decision(&clients, fresh, 1)
	testing.expect(t, action == .Take_Row && place == 0)
	// The key that principal 0 allowed in this run, and that the table of
	// principal 1 holds: contested.
	action, place = client_restore_decision(&clients, other, 1)
	testing.expect(t, action == .Contest && place == 2)
	clients[2].contested = 1 + 1
	clients[2].serial = 7
	testing.expect(t, !client_grant_holds(&clients, 2, 7), "a contested row holds no grant")
	action, place = client_restore_decision(&clients, other, 1)
	testing.expect(t, action == .Contested && place == 2)
	// The holder too finds its row contested: its own row, with no grant.
	action, place = client_restore_decision(&clients, other, 0)
	testing.expect(t, action == .Holds && place == 2)
	for &client, index in clients {
		if client.serial == 0 {
			client = {key = [32]u8{0 = 0x40, 1 = u8(index)}, principal = 0, serial = u64(10 + index)}
		}
	}
	action, place = client_restore_decision(&clients, fresh, 1)
	testing.expect(t, action == .No_Free_Row && place == -1)
}

// The code of the end of a connection whose grant ended has its name.
@(test)
revoked_has_its_name :: proc(t: ^testing.T) {
	testing.expect_value(t, stream_error_name(u64(Stream_Error.Revoked)), "Revoked")
	testing.expect_value(t, stream_error_name(u64(Stream_Error.Revoked) + 1), "")
}
