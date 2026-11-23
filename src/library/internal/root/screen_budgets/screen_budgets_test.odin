#+build !freestanding
package screen_budgets

import "core:testing"

// A growth with a handle of 0, or one handle for both processes, is
// refused and changes nothing; a second growth is taken during a
// replacement; a third before a release is refused and changes nothing,
// as is a handle that the table holds already.
@(test)
a_third_growth_waits_for_a_release :: proc(t: ^testing.T) {
	table: Table
	testing.expect_value(t, grow_take(&table, 0, 10, 7, 10), 0)
	testing.expect_value(t, grow_take(&table, 5, 10, 0, 10), 0)
	testing.expect_value(t, grow_take(&table, 5, 10, 5, 10), 0)
	testing.expect(t, table == {})
	first := grow_take(&table, 5, 7200, 7, 10801)
	testing.expect_value(t, first, 1)
	before := table
	testing.expect_value(t, grow_take(&table, 5, 1, 11, 1), 0)
	testing.expect_value(t, grow_take(&table, 9, 1, 7, 1), 0)
	testing.expect(t, table == before, "a growth with a handle held already changed the table")
	second := grow_take(&table, 9, 16200, 11, 24301)
	testing.expect_value(t, second, 2)
	count, pages := held(&table, .Compositor)
	testing.expect(t, count == 2 && pages == 7200 + 16200)
	count, pages = held(&table, .Service)
	testing.expect(t, count == 2 && pages == 10801 + 24301)
	before = table
	testing.expect_value(t, grow_take(&table, 13, 1, 15, 1), 0)
	testing.expect(t, table == before, "a third growth changed the table")
	// The compositor alone gives back its old one: the service still holds
	// two, so a growth still waits.
	handle, ok := release(&table, .Compositor, first)
	testing.expect(t, ok && handle == 5)
	testing.expect_value(t, grow_take(&table, 13, 1, 15, 1), 0)
	handle, ok = release(&table, .Service, first)
	testing.expect(t, ok && handle == 7)
	third := grow_take(&table, 13, 1, 15, 1)
	testing.expect_value(t, third, 3)
}

// A release names its growth: 0, a number never given, a number of the
// other process only, and a second release of one number are refused and
// change nothing; the newest is released before the oldest when the size of
// the newest was never taken.
@(test)
a_release_names_its_growth :: proc(t: ^testing.T) {
	table: Table
	first := grow_take(&table, 5, 10, 7, 10)
	second := grow_take(&table, 9, 20, 11, 20)
	before := table
	for growth in ([?]u64{0, second + 1, max(u64)}) {
		_, ok := release(&table, .Compositor, growth)
		testing.expectf(t, !ok, "the release of growth %d was taken", growth)
	}
	testing.expect(t, table == before)
	handle, ok := release(&table, .Compositor, second)
	testing.expect(t, ok && handle == 9)
	_, again := release(&table, .Compositor, second)
	testing.expect(t, !again, "a second release of one growth was taken")
	count, pages := held(&table, .Compositor)
	testing.expect(t, count == 1 && pages == 10)
	handle, ok = release(&table, .Compositor, first)
	testing.expect(t, ok && handle == 5)
	handle, ok = release(&table, .Service, second)
	testing.expect(t, ok && handle == 11)
}

// The stop of either process gives each of its handles to close, also in
// the middle of a replacement, and leaves the other process; a stop with
// none gives no handle.
@(test)
a_stop_in_the_middle_of_a_replacement_gives_both_handles :: proc(t: ^testing.T) {
	table: Table
	testing.expect(t, stop(&table, .Service) == {})
	grow_take(&table, 5, 7200, 7, 10801)
	grow_take(&table, 9, 16200, 11, 24301)
	handles := stop(&table, .Service)
	testing.expect(t, handles == {7, 11}, "the stop of the service in a replacement did not give both handles")
	count, _ := held(&table, .Service)
	testing.expect_value(t, count, 0)
	count, _ = held(&table, .Compositor)
	testing.expect_value(t, count, 2)
	testing.expect(t, stop(&table, .Service) == {})
	testing.expect(t, stop(&table, .Compositor) == {5, 9})
	count, _ = held(&table, .Compositor)
	testing.expect_value(t, count, 0)
}

// The number of a growth never wraps to 0: past the last number, a growth
// is refused.
@(test)
the_number_of_a_growth_never_wraps :: proc(t: ^testing.T) {
	table := Table{last_growth = max(u64) - 1}
	testing.expect_value(t, grow_take(&table, 5, 1, 7, 1), max(u64))
	before := table
	testing.expect_value(t, grow_take(&table, 9, 1, 11, 1), 0)
	testing.expect(t, table == before)
}
