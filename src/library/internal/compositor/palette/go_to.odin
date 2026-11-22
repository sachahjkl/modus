package palette

import "modus:display"

// Go to: an entry whose act name an open window names offers to go there
// (src/md/features/palette.md, "The form of an entry, from its descriptions"). Each window gives the set of its act names as hashes, in one
// record of its ring (display.Command.Act_Names); the owner of the panel
// keeps one set for each window and drops it with the window. These
// procedures are the part with no state: the check of a record and the
// match of an entry, so a host test runs them.

// The act names of one window, as hashes (display.act_name_hash).
Act_Name_Set :: struct {
	count:  int, // The hashes in use: 0 to display.ACT_NAME_SET_CAPACITY.
	hashes: [display.ACT_NAME_SET_CAPACITY]u32,
}

// act_name_set_of_record checks the values of a record Act_Names from a
// window and gives its set. The values are those of another process: the
// border of the record (display.act_names_of_values) refuses a count over
// display.ACT_NAME_SET_CAPACITY, a hash of 0 in the count and a hash that
// is not 0 after it, and ok is false.
act_name_set_of_record :: proc "contextless" (values: [7]u64) -> (set: Act_Name_Set, ok: bool) {
	set.hashes, set.count, ok = display.act_names_of_values(values)
	if !ok {
		return {}, false
	}
	return set, true
}

// act_name_set_has says if a set holds the hash of an act name. A hash of 0
// is no act name, and no set holds it.
act_name_set_has :: proc "contextless" (set: ^Act_Name_Set, hash: u32) -> bool {
	if hash == 0 {
		return false
	}
	for held in set.hashes[:clamp(set.count, 0, display.ACT_NAME_SET_CAPACITY)] {
		if held == hash {
			return true
		}
	}
	return false
}

// act_name_front gives the first set of a list that holds the hash of an
// act name, or NO_ROW. The owner gives the sets of its windows, the front
// window first: two windows that name one act, as two windows of one
// process, give the one in front.
act_name_front :: proc "contextless" (sets: []^Act_Name_Set, hash: u32) -> int {
	for set, index in sets {
		if set != nil && act_name_set_has(set, hash) {
			return index
		}
	}
	return NO_ROW
}
