#+build !freestanding
package manual_navigation

import "core:testing"

@(test)
back_gives_the_pages_in_the_reverse_order :: proc(t: ^testing.T) {
	history: History
	_, ok := history_back(&history)
	testing.expect(t, !ok)
	history_push(&history, {kind = .Module, index = 3, first_line = 0})
	history_push(&history, {kind = .Link_Page, index = 7, first_line = 12})
	history_push(&history, {kind = .Overview})
	place: Page_Place
	place, ok = history_back(&history)
	testing.expect(t, ok)
	testing.expect_value(t, place.kind, Page_Kind.Overview)
	place, ok = history_back(&history)
	testing.expect(t, ok)
	testing.expect_value(t, place, Page_Place{kind = .Link_Page, index = 7, first_line = 12})
	place, ok = history_back(&history)
	testing.expect(t, ok)
	testing.expect_value(t, place, Page_Place{kind = .Module, index = 3, first_line = 0})
	_, ok = history_back(&history)
	testing.expect(t, !ok)
	testing.expect_value(t, history.forgotten, 0)
}

@(test)
a_full_history_forgets_its_oldest_place :: proc(t: ^testing.T) {
	history: History
	for index in 0 ..< HISTORY_CAPACITY + 3 {
		history_push(&history, {kind = .Module, index = i32(index)})
	}
	testing.expect_value(t, history.count, HISTORY_CAPACITY)
	testing.expect_value(t, history.forgotten, 3)
	// The newest place first, and the oldest kept is the fourth pushed.
	place, ok := history_back(&history)
	testing.expect(t, ok)
	testing.expect_value(t, place.index, i32(HISTORY_CAPACITY + 2))
	last: Page_Place
	for {
		next, more := history_back(&history)
		if !more {
			break
		}
		last = next
	}
	testing.expect_value(t, last.index, i32(3))
}

@(test)
tab_follows_the_order_of_the_text_and_goes_round :: proc(t: ^testing.T) {
	// No link: no focus.
	testing.expect_value(t, focus_step(0, -1, 0, false), -1)
	testing.expect_value(t, focus_step(0, -1, 0, true), -1)
	// No focus: the first link in the view, or the one before it.
	testing.expect_value(t, focus_step(5, -1, 2, false), 2)
	testing.expect_value(t, focus_step(5, -1, 2, true), 1)
	testing.expect_value(t, focus_step(5, -1, 0, true), 4)
	// No link at or under the top of the view: the first link of the page,
	// or the last one.
	testing.expect_value(t, focus_step(5, -1, 5, false), 0)
	testing.expect_value(t, focus_step(5, -1, 5, true), 4)
	// A focus: the next one, round at each end.
	testing.expect_value(t, focus_step(5, 2, 0, false), 3)
	testing.expect_value(t, focus_step(5, 4, 0, false), 0)
	testing.expect_value(t, focus_step(5, 0, 0, true), 4)
	testing.expect_value(t, focus_step(1, 0, 0, false), 0)
	// A focus that the page no longer has counts as no focus.
	testing.expect_value(t, focus_step(3, 9, 1, false), 1)
	// Each link once in a full turn.
	seen: [7]bool
	focused := -1
	for _ in 0 ..< 7 {
		focused = focus_step(7, focused, 3, false)
		seen[focused] = true
	}
	for item in seen {
		testing.expect(t, item)
	}
}
