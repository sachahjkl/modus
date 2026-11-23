package remote

// Reclamation of Refused service connection slots in the remote service
// (src/md/api/call_ring_ready.md): a slot stays Refused only while its
// client grant holds and at least one live waiting call still asks for its
// (name, row, serial). When the client disconnects, resets its stream or
// loses its grant while Connecting or Readying, nobody consumes the Refused
// slot and it is reclaimed immediately.

// What becomes of a connection of the remote service to a service at a pass
// (service_connection_end_of). Each place that it holds is a place of the
// root service and of the service, so it ends when no client can use it.
Service_Connection_End :: enum u8 {
	Keep        = 0, // A client of its row is connected, and used it in the bound.
	Grant_Ended = 1, // The grant of its row ended: the root service ended its side.
	No_Client   = 2, // No QUIC connection of its row is open.
	Idle        = 3, // No call went through it for SERVICE_CONNECTION_IDLE_MILLISECONDS.
}

// The time with no call after which a connection to a service ends: a
// client of the row that calls again connects again, in one round trip to
// the root service.
SERVICE_CONNECTION_IDLE_MILLISECONDS :: 60_000

// The services that remote calls: the callable list of its start grant
// set in the root service (assistant, compositor, date, debugger, inspect,
// log, manual, monitor, settings, storage).
CALLABLE_SERVICES :: 10

// The connections to services that remote holds at most: one for each of
// its clients and each service that it calls.
SERVICE_CONNECTIONS :: CONNECTION_CAPACITY * CALLABLE_SERVICES

// root_places_for_client_rows gives the places of a connection table of
// the root service of table_capacity places that the connections for the
// rows of the client table take at most: half of it
// (isolated.connection_place_open), so a local caller always finds a place.
// The root service sizes its table; with 256 places, the clients of remote
// take 128 connections at most, fewer than SERVICE_CONNECTIONS, and a
// Connect past them is refused with Full.
root_places_for_client_rows :: proc "contextless" (table_capacity: int) -> int {
	return table_capacity / 2
}

// service_connection_end_of decides for one Ready connection: its grant
// first, then a call that waits for it, then a client of its row, then its
// idle time.
service_connection_end_of :: proc "contextless" (grant_holds, call_waits, row_has_client: bool, idle_milliseconds: u64) -> Service_Connection_End {
	switch {
	case !grant_holds:
		return .Grant_Ended
	case call_waits:
		return .Keep
	case !row_has_client:
		return .No_Client
	case idle_milliseconds >= SERVICE_CONNECTION_IDLE_MILLISECONDS:
		return .Idle
	}
	return .Keep
}

// Service_Slot_Key names one service connection slot by the service name,
// the row of the client table and the serial of its grant.
Service_Slot_Key :: struct {
	name:   [32]u8,
	row:    int,
	serial: u64,
}

// refused_slot_reclaimable reports whether a Refused slot can be freed:
// either its client grant ended, or no live waiting call matches its
// (name, row, serial).
refused_slot_reclaimable :: proc "contextless" (slot: Service_Slot_Key, grant_holds: bool, waiting: []Service_Slot_Key) -> bool {
	if !grant_holds {
		return true
	}
	slot := slot
	slot_name := name_text(&slot.name)
	for &call in waiting {
		if call.row == slot.row && call.serial == slot.serial && name_text(&call.name) == slot_name {
			return false
		}
	}
	return true
}

// disconnects_owed_send sends the Disconnect of each of count places that
// owes one, in the order of the places, until the root ring takes no more:
// the places after it wait for the next pass. A pass can end more
// connections than the ring holds, so a Disconnect is never sent and
// forgotten: owes says if a place still owes one, and send gives true when
// the ring took it (the place then owes nothing). sent: the Disconnect
// records that went in this pass.
disconnects_owed_send :: proc "contextless" (count: int, owes: proc "contextless" (place: int) -> bool, send: proc "contextless" (place: int) -> bool) -> (sent: int) {
	for place in 0 ..< count {
		if !owes(place) {
			continue
		}
		if !send(place) {
			return
		}
		sent += 1
	}
	return
}
