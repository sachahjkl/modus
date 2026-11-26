#+build !freestanding
#+build !modus
package system

import "core:testing"

// The edges of the choice of the parts to close: no part prepared, every
// part held by a start in progress, the margin already free (a need of 0
// and less), and room for fewer choices than the need. None of them closes
// a part that it may not.
@(test)
the_choice_closes_nothing_that_it_may_not :: proc(t: ^testing.T) {
	chosen: [PREPARED_CAPACITY]int
	empty: [PREPARED_CAPACITY]Prepared_Use
	testing.expect_value(t, prepared_drop_choose(empty[:], 5, chosen[:]), 0)
	testing.expect_value(t, prepared_drop_choose(nil, 5, chosen[:]), 0)

	held := [3]Prepared_Use{{held = true, last_use = 3, in_use = true}, {held = true, last_use = 1, in_use = true}, {held = true, last_use = 2, in_use = true}}
	testing.expect_value(t, prepared_drop_choose(held[:], 3, chosen[:]), 0)

	free := [3]Prepared_Use{{held = true, last_use = 3}, {held = true, last_use = 1}, {held = true, last_use = 2}}
	for needed in ([?]int{0, -1, min(int)}) {
		testing.expectf(t, prepared_drop_choose(free[:], needed, chosen[:]) == 0, "a need of %d closes a part", needed)
	}
	// Room for one choice: the one used least recently.
	testing.expect_value(t, prepared_drop_choose(free[:], 3, chosen[:1]), 1)
	testing.expect_value(t, chosen[0], 1)
}

// One part short: the part used least recently is closed, never one that
// a start holds, nor a free place, even when it holds an older stamp.
@(test)
one_part_short_closes_the_one_used_least_recently :: proc(t: ^testing.T) {
	uses := [5]Prepared_Use {
		{held = true, last_use = 9},
		{held = false, last_use = 0},
		{held = true, last_use = 1, in_use = true},
		{held = true, last_use = 4},
		{held = true, last_use = 7},
	}
	chosen: [PREPARED_CAPACITY]int
	testing.expect_value(t, prepared_drop_choose(uses[:], 1, chosen[:]), 1)
	testing.expect_value(t, chosen[0], 3)
}

// Each part needed, and more: every part that it may close is chosen once,
// in the order of their last use, and the count says that the table had
// no more; a full table of PREPARED_CAPACITY parts gives each place.
@(test)
every_part_needed_closes_each_one_in_the_order_of_use :: proc(t: ^testing.T) {
	uses := [4]Prepared_Use {
		{held = true, last_use = 30},
		{held = true, last_use = 10, in_use = true},
		{held = true, last_use = 20},
		{held = true, last_use = 5},
	}
	chosen: [PREPARED_CAPACITY]int
	count := prepared_drop_choose(uses[:], 100, chosen[:])
	testing.expect_value(t, count, 3)
	testing.expect_value(t, chosen[0], 3)
	testing.expect_value(t, chosen[1], 2)
	testing.expect_value(t, chosen[2], 0)

	full: [PREPARED_CAPACITY]Prepared_Use
	for &item, place in full {
		item = {held = true, last_use = u64(PREPARED_CAPACITY - place)}
	}
	count = prepared_drop_choose(full[:], PREPARED_CAPACITY, chosen[:])
	testing.expect_value(t, count, PREPARED_CAPACITY)
	for place in 0 ..< PREPARED_CAPACITY {
		testing.expect_value(t, chosen[place], PREPARED_CAPACITY - 1 - place)
	}
}
