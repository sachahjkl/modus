#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

@(test)
grants_room_short_refuses_a_ring_with_less_room_than_its_grants :: proc(t: ^testing.T) {
	Case :: struct {
		changed: []u32,
		room:    []u32,
		ring:    int,
	}
	cases := [?]Case {
		// A full ring.
		{{1}, {0}, 0},
		// Room for one less than the grants of the ring.
		{{3}, {2}, 0},
		// The second ring is short, the first has room.
		{{2, 4}, {2, 3}, 1},
		// A ring with grants and no room given.
		{{0, 1}, {5}, 1},
	}
	for item in cases {
		short, ring := grants_room_short(item.changed, item.room)
		testing.expectf(t, short, "the grants %v with the room %v are short", item.changed, item.room)
		testing.expect_value(t, ring, item.ring)
	}
	// The exact room, and no grant, last.
	short, _ := grants_room_short({3, 0}, {3, 0})
	testing.expect(t, !short, "the exact room is room")
	short, _ = grants_room_short(nil, nil)
	testing.expect(t, !short, "no grant needs no room")
}

@(private = "file")
name_of_other_plans :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> (name: string, found: bool) {
	return "other_plans", hash[0] == 7
}

@(private = "file")
fills_each :: proc "contextless" (user: rawptr, role: role_contract.Role, module_name: string) -> bool {
	return true
}

@(test)
holder_overrides_restore_gives_back_the_names_and_the_serial :: proc(t: ^testing.T) {
	names: Holder_Names
	names.defaults[.Plans] = "plans"
	kept: Override_Names
	saved := kept
	set := rd.Plan_Roles_Set{generation = 1, expected_serial = 0, override_count = 1}
	set.overrides[0] = {role_word = u64(role_contract.Role.Plans), module_hash = {0 = 7}}
	refusal, _ := holder_overrides_replace(&names, &kept, &set, .Apply, {name_of_hash = name_of_other_plans, fills = fills_each})
	testing.expect_value(t, refusal, rd.Plan_Roles_Refusal.None)
	testing.expect_value(t, holder_name(&names, .Plans), "other_plans")
	testing.expect_value(t, kept.serial, u64(1))
	// The change is refused after it: the names and the serial are those of
	// before.
	holder_overrides_restore(&names, &kept, &saved)
	testing.expect_value(t, holder_name(&names, .Plans), "plans")
	testing.expect_value(t, names.overrides[.Plans], "")
	testing.expect_value(t, kept.serial, u64(0))
	testing.expect_value(t, kept.generation, u64(0))
	testing.expect_value(t, kept, saved)
}
