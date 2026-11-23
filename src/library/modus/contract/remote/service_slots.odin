package remote

// Reclamation of Refused service connection slots in the remote service
// (src/md/api/call_ring_ready.md): a slot stays Refused only while its
// client grant holds and at least one live waiting call still asks for its
// (name, row, serial). When the client disconnects, resets its stream or
// loses its grant while Connecting or Readying, nobody consumes the Refused
// slot and it is reclaimed immediately.

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
