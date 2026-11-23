package role_policy

// The grants of the connections after a change of the roles
// (src/md/features/declarations.md, "The trusted display of a plan"). The
// grant of a connection follows the roles of its two sides: the amount of
// a connection to the holder of Storage or of Display. A change of the
// roles writes again each grant that it changed, and only when each
// service ring has room for those grants: else nothing changes, so no
// connection keeps a trust that its caller lost.

import "modus:contract/role_contract"

// grants_room_short says if a service ring has no room for the grants that
// a change of the roles writes on it: changed[n] grants for the ring of
// room[n] free records. ring is the first such ring.
grants_room_short :: proc "contextless" (changed: []u32, room: []u32) -> (short: bool, ring: int) {
	for count, place in changed {
		free := place < len(room) ? room[place] : 0
		if count > free {
			return true, place
		}
	}
	return false, 0
}

// holder_overrides_restore puts back the overrides that saved holds, and
// the names of names with them, after a change that was refused once it
// replaced them.
holder_overrides_restore :: proc "contextless" (names: ^Holder_Names, kept: ^Override_Names, saved: ^Override_Names) {
	kept^ = saved^
	for role in role_contract.Role {
		length := kept.lengths[role]
		names.overrides[role] = length == 0 ? "" : string(kept.bytes[role][:length])
	}
}
