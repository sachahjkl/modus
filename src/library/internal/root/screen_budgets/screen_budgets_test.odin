#+build !freestanding
package screen_budgets

import "core:testing"

// A second growth before the first ends is refused, for each process that
// still holds its extra budget, and changes nothing; a growth with a handle
// of 0, or one handle for both, is refused; a release of a process with no
// extra budget is refused; after both releases, a growth is taken again.
@(test)
a_second_growth_waits_for_both_releases :: proc(t: ^testing.T) {
	table: Table
	testing.expect(t, !grow_take(&table, {0, 10}, {7, 10}))
	testing.expect(t, !grow_take(&table, {5, 10}, {0, 10}))
	testing.expect(t, !grow_take(&table, {5, 10}, {5, 10}), "one handle for both processes was taken")
	testing.expect(t, table == {})
	testing.expect(t, grow_take(&table, {5, 7200}, {7, 10801}))
	before := table
	testing.expect(t, !grow_take(&table, {9, 1}, {11, 1}), "a second growth was taken")
	testing.expect(t, table == before)
	handle, ok := release(&table, .Compositor)
	testing.expect(t, ok && handle == 5)
	_, again := release(&table, .Compositor)
	testing.expect(t, !again, "a second release of the compositor was taken")
	testing.expect(t, !grow_take(&table, {9, 1}, {11, 1}), "a growth was taken while the service holds its extra budget")
	handle, ok = release(&table, .Service)
	testing.expect(t, ok && handle == 7)
	testing.expect(t, table == {})
	testing.expect(t, grow_take(&table, {9, 1}, {11, 1}))
}

// The stop of either process with its extra budget open gives its handle to
// close, so the pages return, and leaves the other one; a stop with none
// gives 0.
@(test)
a_stop_with_an_extra_budget_open_gives_its_handle :: proc(t: ^testing.T) {
	table: Table
	testing.expect_value(t, stop(&table, .Service), 0)
	testing.expect(t, grow_take(&table, {5, 7200}, {7, 10801}))
	testing.expect_value(t, stop(&table, .Service), 7)
	testing.expect(t, open(&table, .Compositor) && !open(&table, .Service))
	testing.expect_value(t, stop(&table, .Service), 0)
	testing.expect_value(t, stop(&table, .Compositor), 5)
	testing.expect(t, table == {})
}
