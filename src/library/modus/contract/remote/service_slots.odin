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

// The places of the connection table of the root service that the
// connections for the rows of the client table take at most: half of it
// (connection_place_open), so a local caller always finds a place.
ROOT_PLACES_FOR_CLIENT_ROWS :: 128

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
