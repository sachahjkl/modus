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
	first := Client{key = {0 = 0x11, 31 = 0x22}, principal = 0, serial = 1, uses = client_uses_word({.Calls})}
	second := Client{key = {0 = 0x33}, principal = 1, serial = 2, uses = client_uses_word({.Calls})}
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
	testing.expect(t, client_grant_holds(&copied, 0, first.serial, .Calls))
	testing.expect(t, !client_grant_holds(&copied, 0, first.serial + 1, .Calls), "another serial is another grant")
	testing.expect(t, !client_grant_holds(&copied, 1, 0, .Calls), "a free row holds no grant")
	testing.expect(t, !client_grant_holds(&copied, -1, first.serial, .Calls))
	testing.expect(t, !client_grant_holds(&copied, CLIENT_CAPACITY, first.serial, .Calls))
	// The session of principal 1 locked: its row holds no grant, and its
	// key is still found, so the refusal names the principal.
	locked := second
	locked.session_locked = 1
	client_table_write(table, CLIENT_CAPACITY - 1, locked)
	client_table_read(table, &copied)
	testing.expect(t, !client_grant_holds(&copied, CLIENT_CAPACITY - 1, second.serial, .Calls))
	testing.expect_value(t, client_find(&copied, second.key), CLIENT_CAPACITY - 1)
	// A revocation frees the row.
	client_table_write(table, 0, {})
	client_table_read(table, &copied)
	testing.expect_value(t, client_find(&copied, first.key), -1)
	testing.expect(t, !client_grant_holds(&copied, 0, first.serial, .Calls))
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
	clients[2] = {key = other, principal = 0, serial = 6, uses = client_uses_word({.Calls})}
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
	testing.expect(t, !client_grant_holds(&clients, 2, 7, .Calls), "a contested row holds no grant")
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

// The word of the uses: a bit that names no use, no use at all, and Input
// without View are refused; a row holds a grant only for a use of its word,
// and for no use when its word is refused.
@(test)
client_uses_refuse_each_word_that_names_no_set :: proc(t: ^testing.T) {
	refused := [?]u64{0, 1 << 3, 1 << 63, max(u64), client_uses_word({.Input}), client_uses_word({.Calls, .Input})}
	for word in refused {
		_, ok := client_uses_of_word(word)
		testing.expectf(t, !ok, "the word of uses %x is taken", word)
	}
	clients: [CLIENT_CAPACITY]Client
	clients[0] = {key = {0 = 1}, principal = 0, serial = 3, uses = client_uses_word({.View})}
	testing.expect(t, !client_grant_holds(&clients, 0, 3, .Calls), "a key of the view makes no call")
	testing.expect(t, !client_grant_holds(&clients, 0, 3, .Input), "a key of the view sends no input")
	clients[0].uses = client_uses_word({.Input}) | 1 << 9
	testing.expect(t, !client_grant_holds(&clients, 0, 3, .Input), "a refused word holds no use")
	clients[0].uses = 0
	testing.expect(t, !client_grant_holds(&clients, 0, 3, .View), "a row with no use holds nothing")
	// The sets that hold come last.
	accepted := [?]Client_Uses{{.Calls}, {.View}, {.View, .Input}, {.Calls, .View, .Input}}
	for uses in accepted {
		taken, ok := client_uses_of_word(client_uses_word(uses))
		testing.expectf(t, ok && taken == uses, "the uses %v were refused", uses)
	}
	clients[0].uses = client_uses_word({.View, .Input})
	testing.expect(t, client_grant_holds(&clients, 0, 3, .View) && client_grant_holds(&clients, 0, 3, .Input))
}

// The session in front: a row of another principal than the principal in
// front holds no View and no Input, and keeps Calls; principal 0 sees
// nothing while a named session is in front, and a named principal sees
// nothing while principal 0 is in front.
@(test)
a_row_out_of_front_holds_no_view_and_no_input :: proc(t: ^testing.T) {
	MACHINE :: u64(0)
	ALICE :: u64(1)
	testing.expect(t, client_display_paused(MACHINE, ALICE), "principal 0 sees the session of alice")
	testing.expect(t, client_display_paused(ALICE, MACHINE), "alice sees the session of principal 0")
	testing.expect(t, client_display_paused(ALICE, ALICE + 1))
	testing.expect(t, client_display_paused(max(u64), MACHINE))
	clients: [CLIENT_CAPACITY]Client
	clients[0] = {key = {0 = 7}, principal = MACHINE, serial = 4, uses = client_uses_word({.Calls, .View, .Input}), not_in_front = 1}
	testing.expect(t, !client_grant_holds(&clients, 0, 4, .View), "a row out of front holds View")
	testing.expect(t, !client_grant_holds(&clients, 0, 4, .Input), "a row out of front holds Input")
	testing.expect(t, client_grant_holds(&clients, 0, 4, .Calls), "a row out of front loses Calls")
	// The cases that hold come last.
	testing.expect(t, !client_display_paused(MACHINE, MACHINE))
	testing.expect(t, !client_display_paused(ALICE, ALICE))
	clients[0].not_in_front = 0
	testing.expect(t, client_grant_holds(&clients, 0, 4, .View) && client_grant_holds(&clients, 0, 4, .Input))
}

// The table holds more keys than the clients of one person: the ninth key,
// the thirty-third key and each key up to the last row take a free row and
// hold their grant; the key past the last row finds no free row. The table
// fits the pages that the root service makes for it, and one principal
// holds half of the rows, so two principals fill it together.
@(test)
client_table_holds_many_clients_and_refuses_one_past_the_last_row :: proc(t: ^testing.T) {
	testing.expect(t, CLIENT_CAPACITY >= 64, "the client table holds fewer than 64 keys")
	testing.expect(t, CLIENT_ROWS_OF_ONE_PRINCIPAL >= 8, "one principal holds fewer than 8 keys")
	testing.expect_value(t, CLIENT_ROWS_OF_ONE_PRINCIPAL * 2, CLIENT_CAPACITY)
	testing.expect(t, size_of(Client_Table) <= CLIENT_TABLE_PAGES * 4096)
	testing.expect(t, size_of(Client_Table) > (CLIENT_TABLE_PAGES - 1) * 4096, "the client table has a page that it does not use")
	testing.expect(t, CONNECTION_CAPACITY >= 32, "the remote service holds fewer than 32 connections")
	clients: [CLIENT_CAPACITY]Client
	for index in 0 ..< CLIENT_CAPACITY {
		key := [32]u8{0 = 0x50, 1 = u8(index), 2 = u8(index >> 8)}
		action, place := client_restore_decision(&clients, key, 0)
		testing.expectf(t, action == .Take_Row && place == index, "key %d: %v at %d", index + 1, action, place)
		clients[place] = {key = key, principal = 0, serial = u64(index + 1), uses = client_uses_word({.Calls})}
		testing.expectf(t, client_grant_holds(&clients, place, u64(index + 1), .Calls), "key %d holds no grant", index + 1)
	}
	for edge in ([?]int{8, 32, CLIENT_CAPACITY - 1}) {
		testing.expect_value(t, client_find(&clients, clients[edge].key), edge)
	}
	action, place := client_restore_decision(&clients, [32]u8{0 = 0x60}, 0)
	testing.expect(t, action == .No_Free_Row && place == -1)
	testing.expect(t, !client_grant_holds(&clients, CLIENT_CAPACITY, 1, .Calls))
}

// The code of the end of a connection whose grant ended has its name.
@(test)
revoked_has_its_name :: proc(t: ^testing.T) {
	testing.expect_value(t, stream_error_name(u64(Stream_Error.Revoked)), "Revoked")
	testing.expect_value(t, stream_error_name(u64(Stream_Error.Revoked) + 1), "")
}
