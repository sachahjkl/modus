#+build !freestanding
#+build !modus
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
	second := Client{key = {0 = 0x33}, principal_identifier = {0 = 0xA1}, principal = 1, serial = 2, uses = client_uses_word({.Calls})}
	client_table_write(table, 0, first)
	client_table_write(table, CLIENT_CAPACITY - 1, second)
	testing.expect_value(t, table.version & 1, 0)
	testing.expect_value(t, table.version, 4)
	copied: [CLIENT_CAPACITY]Client
	client_table_read(table, &copied)
	testing.expect(t, copied[0] == first)
	testing.expect(t, copied[CLIENT_CAPACITY - 1] == second)
	testing.expect_value(t, client_find_for_principal(&copied, 0, first.key), 0)
	testing.expect_value(t, client_find_for_principal(&copied, 1, first.key), -1)
	testing.expect_value(t, client_find_for_pair(&copied, second.principal_identifier, 1, second.key), CLIENT_CAPACITY - 1)
	testing.expect_value(t, client_find_for_pair(&copied, [32]u8{0 = 0xFF}, 1, second.key), -1)
	testing.expect_value(t, client_find_for_principal(&copied, 1, second.key), CLIENT_CAPACITY - 1)
	testing.expect_value(t, client_find_for_principal(&copied, 0, [32]u8{0 = 0x44}), -1)
	// A key of zeros names no row, though each free row has zeros.
	testing.expect_value(t, client_find_for_principal(&copied, 0, [32]u8{}), -1)
	testing.expect_value(t, client_find_holding(&copied, first.key, .Calls), 0)
	testing.expect(t, client_grant_holds(&copied, 0, first.serial, .Calls))
	testing.expect(t, !client_grant_holds(&copied, 0, first.serial + 1, .Calls), "another serial is another grant")
	testing.expect(t, !client_grant_holds(&copied, 1, 0, .Calls), "a free row holds no grant")
	testing.expect(t, !client_grant_holds(&copied, -1, first.serial, .Calls))
	testing.expect(t, !client_grant_holds(&copied, CLIENT_CAPACITY, first.serial, .Calls))
	// The session of principal 1 locked: its row holds no grant, and its
	// key is still found for its principal.
	locked := second
	locked.session_locked = 1
	client_table_write(table, CLIENT_CAPACITY - 1, locked)
	client_table_read(table, &copied)
	testing.expect(t, !client_grant_holds(&copied, CLIENT_CAPACITY - 1, second.serial, .Calls))
	testing.expect_value(t, client_find_for_principal(&copied, 1, second.key), CLIENT_CAPACITY - 1)
	testing.expect_value(t, client_find_holding(&copied, second.key, .Calls), -1)
	// A revocation frees the row.
	client_table_write(table, 0, {})
	client_table_read(table, &copied)
	testing.expect_value(t, client_find_for_principal(&copied, 0, first.key), -1)
	testing.expect(t, !client_grant_holds(&copied, 0, first.serial, .Calls))
	// A place out of the table changes nothing.
	version := table.version
	client_table_write(table, CLIENT_CAPACITY, first)
	testing.expect_value(t, table.version, version)
}

// Two principals may enroll the same public key independently under
// (principal_identifier, public_key) with no Exists refusal and no Contested
// state. Locking or revoking one principal's row leaves the other intact,
// and client_find_holding prefers the session in front.
@(test)
client_restore_and_lookup_key_by_principal_and_key :: proc(t: ^testing.T) {
	clients: [CLIENT_CAPACITY]Client
	own := [32]u8{0 = 0x11}
	shared := [32]u8{0 = 0x22}
	fresh := [32]u8{0 = 0x33}
	id_one := [32]u8{0 = 0xA1}
	clients[1] = {key = own, principal_identifier = id_one, principal = 1, serial = 5, uses = client_uses_word({.Calls})}
	clients[2] = {key = shared, principal = 0, serial = 6, uses = client_uses_word({.Calls, .View}), not_in_front = 1}

	action, place := client_restore_decision(&clients, own, 1)
	testing.expect(t, action == .Holds && place == 1)
	action, place = client_restore_decision(&clients, fresh, 1)
	testing.expect(t, action == .Take_Row && place == 0)

	// Principal 1 restores the same public key that principal 0 holds: gets its
	// own free row (0), never Contested or Exists.
	action, place = client_restore_decision(&clients, shared, 1)
	testing.expect(t, action == .Take_Row && place == 0)
	clients[0] = {key = shared, principal_identifier = id_one, principal = 1, serial = 7, uses = client_uses_word({.Calls, .View}), not_in_front = 0}

	// Both rows resolve independently by principal. While both principals hold
	// .Calls for the same public key, client_find_holding refuses ambiguous
	// .Calls lookup (-1) so no connection silently picks a principal; .View is
	// unambiguous because only the front session holds .View.
	testing.expect_value(t, client_find_for_principal(&clients, 0, shared), 2)
	testing.expect_value(t, client_find_for_principal(&clients, 1, shared), 0)
	testing.expect_value(t, client_count_holding(&clients, shared, .Calls), 2)
	testing.expect_value(t, client_find_holding(&clients, shared, .Calls), -1)
	testing.expect_value(t, client_find_holding(&clients, shared, .View), 0)

	// Locking principal 1 leaves only principal 0 holding .Calls, which now
	// resolves unambiguously to row 2.
	clients[0].session_locked = 1
	testing.expect(t, !client_grant_holds(&clients, 0, 7, .Calls))
	testing.expect(t, client_grant_holds(&clients, 2, 6, .Calls))
	testing.expect_value(t, client_count_holding(&clients, shared, .Calls), 1)
	testing.expect_value(t, client_find_holding(&clients, shared, .Calls), 2)
	testing.expect_value(t, client_find_holding(&clients, shared, .View), -1) // principal 0 not_in_front == 1

	// Filling the table refuses any further key with No_Free_Row.
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
		testing.expect_value(t, client_find_for_principal(&clients, 0, clients[edge].key), edge)
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

// A connection to a service ends when its grant ends, when no QUIC
// connection of its row is open, and when it had no call for the idle
// bound; a call that waits keeps it, and the grant comes first.
@(test)
a_service_connection_ends_with_its_last_client_or_its_idle_bound :: proc(t: ^testing.T) {
	testing.expect_value(t, service_connection_end_of(false, true, true, 0), Service_Connection_End.Grant_Ended)
	testing.expect_value(t, service_connection_end_of(true, false, false, 0), Service_Connection_End.No_Client)
	testing.expect_value(t, service_connection_end_of(true, false, true, SERVICE_CONNECTION_IDLE_MILLISECONDS), Service_Connection_End.Idle)
	testing.expect_value(t, service_connection_end_of(true, false, true, max(u64)), Service_Connection_End.Idle)
	testing.expect_value(t, service_connection_end_of(true, true, false, max(u64)), Service_Connection_End.Keep)
	testing.expect_value(t, service_connection_end_of(true, false, true, SERVICE_CONNECTION_IDLE_MILLISECONDS - 1), Service_Connection_End.Keep)
	testing.expect_value(t, service_connection_end_of(true, false, true, 0), Service_Connection_End.Keep)
}

// A pass that ends SERVICE_CONNECTIONS connections, with a root
// ring of 32 records that the root service empties between two passes:
// the first pass sends 32 Disconnect records and the rest wait; the
// passes after it send the rest; each place sends exactly one, and none is
// lost. A ring with no room sends nothing.
@(private = "file")
test_owed: [SERVICE_CONNECTIONS]bool
@(private = "file")
test_sends: [SERVICE_CONNECTIONS]int
@(private = "file")
test_ring_room: int

@(test)
disconnects_past_the_room_of_the_ring_wait_for_the_next_pass :: proc(t: ^testing.T) {
	RING :: 32
	owes :: proc "contextless" (place: int) -> bool {return test_owed[place]}
	send :: proc "contextless" (place: int) -> bool {
		if test_ring_room == 0 {
			return false
		}
		test_ring_room -= 1
		test_owed[place] = false
		test_sends[place] += 1
		return true
	}
	for &owed in test_owed {
		owed = true
	}
	test_sends = {}
	test_ring_room = 0
	testing.expect_value(t, disconnects_owed_send(len(test_owed), owes, send), 0)
	passes := 0
	total := 0
	for total < len(test_owed) && passes < 10 {
		test_ring_room = RING // The root service read the ring.
		sent := disconnects_owed_send(len(test_owed), owes, send)
		testing.expect(t, sent <= RING)
		total += sent
		passes += 1
	}
	testing.expect_value(t, passes, (SERVICE_CONNECTIONS + RING - 1) / RING)
	for count, place in test_sends {
		testing.expectf(t, count == 1 && !test_owed[place], "the place %d sent %d Disconnect records", place, count)
	}
	test_ring_room = RING
	testing.expect_value(t, disconnects_owed_send(len(test_owed), owes, send), 0)
}

// A refusal of a connection whose end found the root ring full keeps its
// Disconnect: a full ring sends nothing and the place still owes it, then
// a ring with room sends it once. Each state owes a Disconnect only as
// service_place_owes_disconnect says.
@(private = "file")
refused_places: [4]struct {
	state: Service_Place_State,
	owed:  bool,
}
@(private = "file")
refused_ring_room: int

@(test)
a_refused_place_keeps_its_owed_disconnect :: proc(t: ^testing.T) {
	for &place in refused_places {
		// The end of the connection found the ring full: the place was Ending.
		place.state, place.owed = service_place_after_refusal(.Ending)
	}
	state, owed := service_place_after_refusal(.Free)
	testing.expect(t, state == .Refused && !owed, "a refusal whose Disconnect went owes one")
	owes :: proc "contextless" (place: int) -> bool {return service_place_owes_disconnect(refused_places[place].state, refused_places[place].owed)}
	send :: proc "contextless" (place: int) -> bool {
		if refused_ring_room == 0 {
			return false
		}
		refused_ring_room -= 1
		refused_places[place].owed = false
		return true
	}
	refused_ring_room = 0
	testing.expect_value(t, disconnects_owed_send(len(refused_places), owes, send), 0)
	for place in refused_places {
		testing.expect(t, place.state == .Refused && place.owed, "a full ring lost the Disconnect of a Refused place")
	}
	refused_ring_room = 2
	testing.expect_value(t, disconnects_owed_send(len(refused_places), owes, send), 2)
	refused_ring_room = 8
	testing.expect_value(t, disconnects_owed_send(len(refused_places), owes, send), 2)
	testing.expect_value(t, disconnects_owed_send(len(refused_places), owes, send), 0)
	for member in Service_Place_State {
		testing.expect_value(t, service_place_owes_disconnect(member, false), member == .Ending)
		testing.expect_value(t, service_place_owes_disconnect(member, true), member == .Ending || member == .Giving_Up || member == .Refused)
	}
}

// A call for a service and a row whose earlier connection is Ending waits,
// whatever the serial, so no second Connect of the row goes before its
// Disconnect; a place of another service or row is skipped; each other
// state gives its answer for the same serial only.
@(test)
a_call_waits_for_an_ending_place_of_its_service_and_row :: proc(t: ^testing.T) {
	testing.expect_value(t, service_place_lookup(.Ending, true, false), Service_Place_Lookup.Pending)
	testing.expect_value(t, service_place_lookup(.Ending, true, true), Service_Place_Lookup.Pending)
	testing.expect_value(t, service_place_lookup(.Ending, false, true), Service_Place_Lookup.Skip)
	for member in Service_Place_State {
		testing.expect_value(t, service_place_lookup(member, false, true), Service_Place_Lookup.Skip)
		if member != .Ending {
			testing.expect_value(t, service_place_lookup(member, true, false), Service_Place_Lookup.Skip)
		}
	}
	testing.expect_value(t, service_place_lookup(.Free, true, true), Service_Place_Lookup.Skip)
	testing.expect_value(t, service_place_lookup(.Ready, true, true), Service_Place_Lookup.Use)
	testing.expect_value(t, service_place_lookup(.Connecting, true, true), Service_Place_Lookup.Pending)
	testing.expect_value(t, service_place_lookup(.Readying, true, true), Service_Place_Lookup.Pending)
	testing.expect_value(t, service_place_lookup(.Refused, true, true), Service_Place_Lookup.Refusal)
	testing.expect_value(t, service_place_lookup(.Giving_Up, true, true), Service_Place_Lookup.Given_Up)
}

// A second connection of a key ends the wide grant of its row only when
// the row holds one and another connection of that very key is bound: no
// grant, another key, the zero key, a row of another key and no other
// connection each keep it; the key that comes twice ends it.
@(test)
a_second_connection_ends_the_wide_grant_of_its_key :: proc(t: ^testing.T) {
	key := [32]u8{0 = 3, 31 = 4}
	other := [32]u8{0 = 5}
	row := Client{key = key, serial = 1, principal = 1, uses = client_uses_word({.Calls}), wide_grant = 9}
	no_grant := row
	no_grant.wide_grant = 0
	testing.expect(t, !second_connection_ends_grant(no_grant, key, {key}))
	testing.expect(t, !second_connection_ends_grant(row, key, {other}))
	testing.expect(t, !second_connection_ends_grant(row, key, {}))
	testing.expect(t, !second_connection_ends_grant(row, other, {other}))
	zero_row := row
	zero_row.key = {}
	testing.expect(t, !second_connection_ends_grant(zero_row, {}, {{}}))
	testing.expect(t, second_connection_ends_grant(row, key, {other, key}))
}
