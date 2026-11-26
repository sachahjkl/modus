#+build !freestanding
#+build !modus
package remote

import "core:testing"

@(private = "file")
slot_key :: proc(name: string, row: int, serial: u64) -> (key: Service_Slot_Key) {
	copy(key.name[:len(key.name) - 1], name)
	key.row = row
	key.serial = serial
	return key
}

// A Refused slot is reclaimed when its grant ends, when no call waits, or
// when waiting calls differ in name, row or serial; it is kept only while
// its grant holds and a matching call waits to consume the refusal.
@(test)
refused_slot_reclaimable_checks_grant_and_waiting_calls :: proc(t: ^testing.T) {
	target := slot_key("storage", 2, 10)
	// No waiting call: reclaim even when the grant holds.
	testing.expect(t, refused_slot_reclaimable(target, true, nil))
	// Grant ended: reclaim even when a matching call is listed.
	matching := [1]Service_Slot_Key{target}
	testing.expect(t, refused_slot_reclaimable(target, false, matching[:]))
	// Waiting calls that differ in one field each: still reclaim.
	others := [3]Service_Slot_Key {
		slot_key("monitor", 2, 10),
		slot_key("storage", 3, 10),
		slot_key("storage", 2, 11),
	}
	testing.expect(t, refused_slot_reclaimable(target, true, others[:]))
	// Grant holds and one waiting call matches all three fields: keep.
	mixed := [2]Service_Slot_Key{others[0], target}
	testing.expect(t, !refused_slot_reclaimable(target, true, mixed[:]))
}
