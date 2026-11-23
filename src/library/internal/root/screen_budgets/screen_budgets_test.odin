#+build !freestanding
package screen_budgets

import "modus:contract/memory_screen"
import "core:testing"

// A growth with a handle of 0, or one handle for both processes, is
// refused and changes nothing; a second growth is taken during a
// replacement; a third before a place drains is refused and changes
// nothing, as is a handle that the table holds already.
@(test)
a_third_growth_waits_for_a_place :: proc(t: ^testing.T) {
	table: Table
	testing.expect_value(t, grow_take(&table, 0, 10, 7, 10, 1000), 0)
	testing.expect_value(t, grow_take(&table, 5, 10, 0, 10, 1000), 0)
	testing.expect_value(t, grow_take(&table, 5, 10, 5, 10, 1000), 0)
	testing.expect(t, table == {})
	first := grow_take(&table, 5, 7200, 7, 10801, 1000)
	testing.expect(t, first == 1 && table.last_growth_at == 1000)
	before := table
	testing.expect_value(t, grow_take(&table, 5, 1, 11, 1, 3000), 0)
	testing.expect_value(t, grow_take(&table, 9, 1, 7, 1, 3000), 0)
	testing.expect(t, table == before, "a growth with a handle held already changed the table")
	second := grow_take(&table, 9, 16200, 11, 24301, 3000)
	testing.expect_value(t, second, 2)
	count, pages := held(&table, .Compositor)
	testing.expect(t, count == 2 && pages == 7200 + 16200)
	before = table
	testing.expect_value(t, grow_take(&table, 13, 1, 15, 1, 5000), 0)
	testing.expect(t, table == before, "a third growth changed the table")
}

// A release does not prove that the process closed its handle and its
// objects: the released extra budget keeps its place and its pages until
// it drains. So a loop of growths and releases that never drains fills the
// places, keeps its pages counted against the share, and the next growth
// is refused.
@(test)
a_release_counts_until_the_budget_drains :: proc(t: ^testing.T) {
	table: Table
	first := grow_take(&table, 5, 7200, 7, 10801, 1000)
	handle, ok := release(&table, .Compositor, first)
	testing.expect(t, ok && handle == 5)
	_, again := release(&table, .Compositor, first)
	testing.expect(t, !again, "a second release of one growth was taken")
	count, pages := held(&table, .Compositor)
	testing.expect(t, count == 1 && pages == 7200, "a released extra budget that did not drain stopped to count")
	testing.expect(t, draining(&table))
	// The budget still pays an object: one page short of its pages.
	testing.expect(t, !drained(&table, 5, 7199))
	count, pages = held(&table, .Compositor)
	testing.expect(t, count == 1 && pages == 7200)
	// The loop goes on: a second growth takes the last place, its release
	// does not drain, and a third growth is refused.
	second := grow_take(&table, 9, 7200, 11, 10801, 3000)
	release(&table, .Compositor, second)
	testing.expect_value(t, grow_take(&table, 13, 7200, 15, 10801, 5000), 0)
	count, pages = held(&table, .Compositor)
	testing.expect(t, count == 2 && pages == 14400)
	// A share that pays one extra budget beside the start budget refuses
	// the pages that the undrained ones hold.
	facts := memory_screen.Grow_Facts{from_service = true, screen_of_memory = true, width = 2560, height = 1440, compositor_extras = 1, compositor_paid = 23820 + 7200, service_paid = 6800, share = 23820 + 7200}
	refusal, _, _ := memory_screen.screen_budget_grow_decide(facts)
	testing.expect_value(t, refusal, memory_screen.Grow_Refusal.Past_Compositor_Share)
	// All the pages back: the place frees, and a handle that is not
	// draining, or 0, does not drain.
	testing.expect(t, !drained(&table, 7, 10801), "a held extra budget drained")
	testing.expect(t, !drained(&table, 0, max(u64)))
	testing.expect(t, drained(&table, 5, 7200))
	testing.expect(t, !drained(&table, 5, 7200), "one budget drained twice")
	count, pages = held(&table, .Compositor)
	testing.expect(t, count == 1 && pages == 7200)
}

// A release names its growth: 0, a number never given, and a number of
// the other process only are refused and change nothing; the newest is
// released before the oldest when the size of the newest was never taken.
@(test)
a_release_names_its_growth :: proc(t: ^testing.T) {
	table: Table
	first := grow_take(&table, 5, 10, 7, 10, 1000)
	second := grow_take(&table, 9, 20, 11, 20, 3000)
	release(&table, .Service, first)
	before := table
	for growth in ([?]u64{0, second + 1, max(u64)}) {
		_, ok := release(&table, .Compositor, growth)
		testing.expectf(t, !ok, "the release of growth %d was taken", growth)
	}
	testing.expect(t, table == before)
	handle, ok := release(&table, .Compositor, second)
	testing.expect(t, ok && handle == 9)
	handle, ok = release(&table, .Compositor, first)
	testing.expect(t, ok && handle == 5)
}

// The stop of either process gives each of its handles to close, draining
// or not, also in the middle of a replacement, and leaves the other
// process; a stop with none gives no handle.
@(test)
a_stop_in_the_middle_of_a_replacement_gives_both_handles :: proc(t: ^testing.T) {
	table: Table
	testing.expect(t, stop(&table, .Service) == {})
	first := grow_take(&table, 5, 7200, 7, 10801, 1000)
	grow_take(&table, 9, 16200, 11, 24301, 3000)
	release(&table, .Service, first)
	handles := stop(&table, .Service)
	testing.expect(t, handles == {7, 11}, "the stop of the service in a replacement did not give both handles")
	count, _ := held(&table, .Service)
	testing.expect_value(t, count, 0)
	count, _ = held(&table, .Compositor)
	testing.expect_value(t, count, 2)
	testing.expect(t, stop(&table, .Compositor) == {5, 9})
}

// A growth that did not reach the compositor is taken back from both
// processes; a released one is not, and an unknown number changes nothing.
@(test)
a_growth_that_did_not_reach_the_compositor_is_undone :: proc(t: ^testing.T) {
	table: Table
	first := grow_take(&table, 5, 10, 7, 10, 1000)
	second := grow_take(&table, 9, 20, 11, 20, 3000)
	release(&table, .Service, first)
	before := table
	testing.expect(t, !grow_undo(&table, 0))
	testing.expect(t, !grow_undo(&table, second + 1))
	testing.expect(t, table == before)
	testing.expect(t, grow_undo(&table, second))
	count, _ := held(&table, .Compositor)
	testing.expect_value(t, count, 1)
	testing.expect(t, grow_undo(&table, first), "the compositor half of the first growth stayed")
	count, _ = held(&table, .Service)
	testing.expect_value(t, count, 1) // The released half drains, and stays counted.
}

// The number of a growth never wraps to 0: past the last number, a growth
// is refused.
@(test)
the_number_of_a_growth_never_wraps :: proc(t: ^testing.T) {
	table := Table{last_growth = max(u64) - 1}
	testing.expect_value(t, grow_take(&table, 5, 1, 7, 1, 1000), max(u64))
	before := table
	testing.expect_value(t, grow_take(&table, 9, 1, 11, 1, 3000), 0)
	testing.expect(t, table == before)
}

// The gives of a growth: the sender first. A refused give of the sender
// gives the compositor nothing; a refused give of the compositor takes
// back the handle of the sender; both pass with nothing taken back.
Give_Trial :: struct {
	refused:    Side,
	refuses:    bool,
	given:            [2]Side,
	given_count:      int,
	taken_back:       [2]Side,
	taken_back_count: int,
}
give_trial: ^Give_Trial

@(test)
the_sender_is_given_first_and_taken_back_on_a_refusal :: proc(t: ^testing.T) {
	give :: proc "contextless" (side: Side) -> bool {
		if give_trial.refuses && give_trial.refused == side {
			return false
		}
		give_trial.given[give_trial.given_count] = side
		give_trial.given_count += 1
		return true
	}
	take_back :: proc "contextless" (side: Side) {
		give_trial.taken_back[give_trial.taken_back_count] = side
		give_trial.taken_back_count += 1
	}
	trial: Give_Trial
	give_trial = &trial
	trial.refuses, trial.refused = true, .Service
	testing.expect(t, !give_both(give, take_back))
	testing.expect(t, trial.given_count == 0 && trial.taken_back_count == 0, "the compositor was given a handle after the sender was refused")
	trial.refused = .Compositor
	testing.expect(t, !give_both(give, take_back))
	testing.expect(t, trial.given_count == 1 && trial.given[0] == .Service)
	testing.expect(t, trial.taken_back_count == 1 && trial.taken_back[0] == .Service, "the handle of the sender stayed after the compositor was refused")
	trial = {}
	testing.expect(t, give_both(give, take_back))
	testing.expect(t, trial.given_count == 2 && trial.given[0] == .Service && trial.given[1] == .Compositor && trial.taken_back_count == 0)
}

// The lines of refused commands: at most REFUSED_LINES_PER_SECOND in one
// second, again in the next second, and a clock that goes back starts a
// new count.
@(test)
the_refused_lines_are_bounded_each_second :: proc(t: ^testing.T) {
	bound: Line_Bound
	for _ in 0 ..< REFUSED_LINES_PER_SECOND {
		testing.expect(t, line_allowed(&bound, 5000))
	}
	testing.expect(t, !line_allowed(&bound, 5999), "a line past the bound of the second was written")
	testing.expect(t, line_allowed(&bound, 6000))
	testing.expect(t, line_allowed(&bound, 0))
	testing.expect(t, line_allowed(&bound, max(u64)))
}
