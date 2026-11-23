#+build !freestanding
package mapping_order

import "core:testing"

Item :: struct {
	address:    u64,
	page_count: u64,
}

// An order of 0 items, then of the room whole: an insert past the room
// changes nothing, and a remove of a place that is not in the order changes
// nothing.
@(test)
the_refusals_change_nothing :: proc(t: ^testing.T) {
	items := [4]Item{{0x10000, 1}, {0x20000, 1}, {0x30000, 1}, {0x40000, 1}}
	order: [3]u16
	count := 0
	_, found := containing(order[:count], items[:], 0x10000)
	testing.expect(t, !found)
	testing.expect(t, !overlaps(order[:count], items[:], 0, max(u64) / 2))
	testing.expect(t, !remove(order[:], &count, items[:], 0))
	for place in u16(0) ..< 3 {
		testing.expect(t, insert(order[:], &count, items[:], place))
	}
	testing.expect(t, !insert(order[:], &count, items[:], 3))
	testing.expect_value(t, count, 3)
	testing.expect_value(t, order, [3]u16{0, 1, 2})
	testing.expect(t, !remove(order[:], &count, items[:], 3))
	testing.expect_value(t, count, 3)
}

// Items inserted in any order come out by address; a lookup finds the item
// at its first byte and at its last, and nothing in a gap or past the end.
@(test)
the_order_follows_the_addresses :: proc(t: ^testing.T) {
	items := [5]Item{{0x50000, 2}, {0x10000, 1}, {0x30000, 4}, {0x90000, 1}, {0x70000, 1}}
	order: [5]u16
	count := 0
	for place in u16(0) ..< 5 {
		testing.expect(t, insert(order[:], &count, items[:], place))
	}
	testing.expect_value(t, order, [5]u16{1, 2, 0, 4, 3})
	place, found := containing(order[:count], items[:], 0x30000)
	testing.expect(t, found && place == 2)
	place, found = containing(order[:count], items[:], 0x33FFF)
	testing.expect(t, found && place == 2)
	_, found = containing(order[:count], items[:], 0x34000)
	testing.expect(t, !found)
	_, found = containing(order[:count], items[:], 0x9_1000)
	testing.expect(t, !found)
	_, found = containing(order[:count], items[:], 0)
	testing.expect(t, !found)
	testing.expect(t, overlaps(order[:count], items[:], 0x2F000, 0x1001))
	testing.expect(t, !overlaps(order[:count], items[:], 0x2F000, 0x1000))
	testing.expect(t, remove(order[:], &count, items[:], 2))
	testing.expect(t, count == 4 && order[0] == 1 && order[1] == 0 && order[2] == 4 && order[3] == 3)
	testing.expect(t, remove(order[:], &count, items[:], 3))
	testing.expect(t, remove(order[:], &count, items[:], 1))
	testing.expect(t, count == 2 && order[0] == 0 && order[1] == 4)
}

// A free range keeps one guard page before and after it, takes the first
// gap that holds it, and skips a gap that is one page too small.
@(test)
a_free_range_takes_the_first_gap_that_holds_it :: proc(t: ^testing.T) {
	G :: PAGE_SIZE
	items := [3]Item{{0x10000, 1}, {0x13000, 1}, {0x20000, 2}}
	order: [3]u16
	count := 0
	for place in u16(0) ..< 3 {
		insert(order[:], &count, items[:], place)
	}
	// Nothing at all: the start itself.
	testing.expect_value(t, free_range(order[:0], items[:], 0x10000, G, G, G), u64(0x10000))
	// From the first item: the gap between 0x11000 and 0x13000 holds one
	// page with its two guards only from 0x12000, which meets the guard of
	// the second item: refused. The next gap is after the second item.
	testing.expect_value(t, free_range(order[:count], items[:], 0x10000, G, G, G), u64(0x15000))
	// A range of 0xA pages fits exactly between the guards of 0x15000 and
	// 0x20000; one page more goes past the third item.
	testing.expect_value(t, free_range(order[:count], items[:], 0x10000, 0xA * G, G, G), u64(0x15000))
	testing.expect_value(t, free_range(order[:count], items[:], 0x10000, 0xB * G, G, G), u64(0x23000))
	// An alignment of 64 KiB.
	testing.expect_value(t, free_range(order[:count], items[:], 0x10000, G, 0x10000, G), u64(0x30000))
	// A start far past each item.
	testing.expect_value(t, free_range(order[:count], items[:], 0x100000, G, G, G), u64(0x100000))
}

// A table at its room: 1024 items, inserted from the last address to the
// first; each lookup finds its own, and a free range after a full run of
// items is after the last one.
@(test)
a_full_table_stays_in_order :: proc(t: ^testing.T) {
	items: [1024]Item
	order: [1024]u16
	count := 0
	for index in 0 ..< 1024 {
		items[index] = {u64(0x1000_0000 + index * 0x2000), 1}
	}
	for index := 1023; index >= 0; index -= 1 {
		testing.expect(t, insert(order[:], &count, items[:], u16(index)))
	}
	for index in 0 ..< 1024 {
		testing.expect_value(t, order[index], u16(index))
		place, found := containing(order[:count], items[:], items[index].address)
		testing.expect(t, found && place == u16(index))
	}
	testing.expect_value(t, free_range(order[:count], items[:], 0x1000_0000, PAGE_SIZE, PAGE_SIZE, PAGE_SIZE), u64(0x1000_0000 + 1024 * 0x2000))
}
