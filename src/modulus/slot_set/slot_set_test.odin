#+build !freestanding
package slot_set

import "core:testing"

// The refusals first: a slot at the capacity and past it, and the largest
// slot, change nothing and are never in the set.
@(test)
a_slot_past_the_capacity_is_refused_and_changes_nothing :: proc(t: ^testing.T) {
	set: Slot_Set(256)
	for slot in ([?]u32{256, 257, 1 << 16, max(u32)}) {
		testing.expect(t, !add(&set, slot))
		testing.expect(t, !has(&set, slot))
		remove(&set, slot)
		testing.expect(t, empty(&set))
	}
	// A capacity that is not a multiple of 64: the bits past it in the last
	// word are still refused.
	odd: Slot_Set(65)
	testing.expect_value(t, len(odd.words), 2)
	testing.expect(t, !add(&odd, 65))
	testing.expect(t, !add(&odd, 127))
	testing.expect(t, empty(&odd))
}

// The empty set: no first slot, nothing to take.
@(test)
the_zero_set_is_empty :: proc(t: ^testing.T) {
	set: Slot_Set(256)
	testing.expect(t, empty(&set))
	_, found := first(&set)
	testing.expect(t, !found)
	_, found = take(&set)
	testing.expect(t, !found)
}

// The edges of each word: 0, 63, 64, the last slot. take gives them in
// order, and the set is empty after the last.
@(test)
the_slots_at_the_edges_of_the_words_come_back_in_order :: proc(t: ^testing.T) {
	set: Slot_Set(256)
	slots := [?]u32{255, 64, 63, 0, 128, 191}
	for slot in slots {
		testing.expect(t, add(&set, slot))
		testing.expect(t, has(&set, slot))
	}
	testing.expect(t, !has(&set, 1))
	testing.expect(t, !has(&set, 65))
	order := [?]u32{0, 63, 64, 128, 191, 255}
	for expected in order {
		slot, found := take(&set)
		testing.expect(t, found)
		testing.expect_value(t, slot, expected)
	}
	testing.expect(t, empty(&set))
}

// A remove takes only its own slot.
@(test)
a_remove_takes_only_its_slot :: proc(t: ^testing.T) {
	set: Slot_Set(128)
	testing.expect(t, add(&set, 5))
	testing.expect(t, add(&set, 70))
	remove(&set, 5)
	remove(&set, 6)
	testing.expect(t, !has(&set, 5))
	testing.expect(t, has(&set, 70))
	slot, found := first(&set)
	testing.expect(t, found && slot == 70)
}

// The atomic forms refuse the same slots, and a copy holds what was added.
@(test)
the_atomic_forms_keep_the_rules :: proc(t: ^testing.T) {
	set: Slot_Set(1024)
	testing.expect(t, !add_atomic(&set, 1024))
	testing.expect(t, !add_atomic(&set, max(u32)))
	testing.expect(t, empty(&set))
	testing.expect(t, add_atomic(&set, 1023))
	testing.expect(t, add_atomic(&set, 1))
	copied := copy_atomic(&set)
	slot, found := take(&copied)
	testing.expect(t, found && slot == 1)
	slot, found = take(&copied)
	testing.expect(t, found && slot == 1023)
	testing.expect(t, empty(&copied))
	testing.expect(t, has(&set, 1) && has(&set, 1023))
	remove_atomic(&set, 1024)
	remove_atomic(&set, 1)
	testing.expect(t, !has(&set, 1) && has(&set, 1023))
}
