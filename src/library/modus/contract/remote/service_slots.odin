package remote

import "modus:contract/isolated"

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

// The places of the connection table of the root service that the
// connections for the rows of the client table take at most: half of it
// (isolated.connection_place_open), so a local caller always finds a place.
ROOT_PLACES_FOR_CLIENT_ROWS :: isolated.ROOT_CONNECTION_CAPACITY / 2

// The connections to services that remote holds at most: one for each of
// its clients and each service that it calls, within the share that the
// root service gives the rows of the client table. With a root table of
// 256 places, the share of 128 bounds the 320 that the clients could ask
// for, and a Connect past it is refused with Full; remote pays no page
// table for a place that it can never fill.
SERVICE_CONNECTIONS :: min(CONNECTION_CAPACITY * CALLABLE_SERVICES, ROOT_PLACES_FOR_CLIENT_ROWS)

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

// Where a place of the table of connections of remote to services is. The
// waits for the root service and for the ready completion of the service
// are states of the loop of remote, not waits of it
// (src/md/api/call_ring_ready.md).
Service_Place_State :: enum u8 {
	Free       = 0, // The place is free.
	Connecting = 1, // Connect is sent; the answer of the root service has not come.
	Readying   = 2, // The connection is mapped; the ready completion of the service has not come.
	Ready      = 3, // Calls go through it.
	Refused    = 4, // It did not become ready: its refusal waits for the first call that asks for it.
	Giving_Up  = 5, // Connect had no answer within the hang bound: Disconnect is sent, and a late answer of Connect has its handles closed.
	// The connection ended, and its Disconnect waits for room in the root
	// ring: the place stays taken until the root service frees its side.
	Ending     = 6,
}

// service_place_owes_disconnect says if a place owes the root service a
// Disconnect: an Ending place always; a Giving_Up or a Refused place when
// the root ring did not take the one that it sent (owed).
service_place_owes_disconnect :: proc "contextless" (state: Service_Place_State, owed: bool) -> bool {
	switch state {
	case .Ending:
		return true
	case .Giving_Up, .Refused:
		return owed
	case .Free, .Connecting, .Readying, .Ready:
	}
	return false
}

// service_place_after_refusal gives the state and the owed flag of a place
// that did not become ready: Refused, which keeps a Disconnect that the
// end of its connection could not send.
service_place_after_refusal :: proc "contextless" (state_after_end: Service_Place_State) -> (state: Service_Place_State, owed: bool) {
	return .Refused, state_after_end == .Ending
}

// What a place gives a call that asks for a connection to a service for
// a row of the client table.
Service_Place_Lookup :: enum u8 {
	Skip     = 0, // The place is not for this call.
	Use      = 1, // The connection is ready.
	Pending  = 2, // The call waits: the connection moves on, or the Disconnect of an earlier one of this service and this row waits.
	Refusal  = 3, // The call gets the refusal of the place, which is freed.
	Given_Up = 4, // The call gets the refusal of the Connect given up.
}

// service_place_lookup decides a place for a call: same_service_and_row
// says if the place is for the service and the row of the call,
// same_serial if it carries the serial of that row. An Ending place of the
// service and the row waits whatever its serial: the root service still
// holds that connection, and a new Connect of the row would be refused
// until its Disconnect goes.
service_place_lookup :: proc "contextless" (state: Service_Place_State, same_service_and_row, same_serial: bool) -> Service_Place_Lookup {
	if state == .Free || !same_service_and_row {
		return .Skip
	}
	if state == .Ending {
		return .Pending
	}
	if !same_serial {
		return .Skip
	}
	switch state {
	case .Ready:
		return .Use
	case .Connecting, .Readying:
		return .Pending
	case .Refused:
		return .Refusal
	case .Giving_Up:
		return .Given_Up
	case .Free, .Ending:
	}
	return .Skip
}
