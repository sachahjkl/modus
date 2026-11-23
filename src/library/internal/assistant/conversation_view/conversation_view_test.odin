#+build !freestanding
package conversation_view

import "core:testing"

// places_of gives the places of entries of heights, numbered from first.
@(private = "file")
places_of :: proc(heights: []int, first_number: u64 = 1) -> ^Places {
	places := new(Places, context.temp_allocator)
	places.count = len(heights)
	y := 0
	for height, index in heights {
		places.tops[index] = y
		places.numbers[index] = first_number + u64(index)
		y += height
	}
	places.tops[len(heights)] = y
	return places
}

// No entry, a view of no height, a pixel above and past the content: no
// place is read past the entries.
@(test)
an_empty_or_odd_view_reads_no_place_past_the_entries :: proc(t: ^testing.T) {
	empty := places_of({})
	testing.expect_value(t, entry_at(empty, 0), -1)
	start, end := visible(empty, 0, 100)
	testing.expect(t, start == 0 && end == 0)
	scroll := scroll_start()
	settle(&scroll, empty, 100)
	testing.expect(t, scroll.first == 0 && scroll.following)
	scroll_set(&scroll, empty, 100, max(int))
	testing.expect(t, scroll.first == 0 && scroll.following)
	places := places_of({10, 20, 30})
	testing.expect_value(t, entry_at(places, -5), 0)
	testing.expect_value(t, entry_at(places, 1000), 2)
	start, end = visible(places, 0, 0)
	testing.expect(t, start == 0 && end == 0)
	start, end = visible(places, 0, -3)
	testing.expect(t, start == 0 && end == 0)
	_, found := index_of_number(places, 0)
	testing.expect(t, !found)
	_, found = index_of_number(places, 4)
	testing.expect(t, !found)
	index, found_two := index_of_number(places, 2)
	testing.expect(t, found_two && index == 1)
}

// A move past each end is cut to the content; a content shorter than the
// view never scrolls; the end of the content follows again.
@(test)
a_move_is_cut_to_the_content :: proc(t: ^testing.T) {
	places := places_of({100, 100, 100})
	scroll := scroll_start()
	for first in ([]int{min(int), -1, 0}) {
		scroll_set(&scroll, places, 120, first)
		testing.expect_value(t, scroll.first, 0)
		testing.expect(t, !scroll.following)
	}
	for first in ([]int{180, 181, max(int)}) {
		scroll_set(&scroll, places, 120, first)
		testing.expect_value(t, scroll.first, 180)
		testing.expect(t, scroll.following)
	}
	short := places_of({10, 10})
	scroll_set(&scroll, short, 120, 5)
	testing.expect(t, scroll.first == 0 && scroll.following)
}

// The view follows the newest entry by default: a new entry moves it to
// the new end.
@(test)
a_following_view_shows_the_newest_entry :: proc(t: ^testing.T) {
	scroll := scroll_start()
	settle(&scroll, places_of({100, 100}), 150)
	testing.expect_value(t, scroll.first, 50)
	settle(&scroll, places_of({100, 100, 300}), 150)
	testing.expect(t, scroll.first == 350 && scroll.following)
}

// A view that the principal moved up keeps its entry and its pixel when
// entries are added under it, when the oldest entries leave the ring above
// it, and when an entry above it changes its height; the end follows again.
@(test)
a_view_moved_up_keeps_its_place :: proc(t: ^testing.T) {
	places := places_of({100, 100, 100, 100})
	scroll := scroll_start()
	scroll_set(&scroll, places, 100, 130)
	testing.expect(t, !scroll.following && scroll.anchor_number == 2 && scroll.anchor_offset == 30)
	// An entry under it.
	settle(&scroll, places_of({100, 100, 100, 100, 400}), 100)
	testing.expect(t, scroll.first == 130 && !scroll.following)
	// The oldest entry leaves the ring: the same pixel of entry 2.
	settle(&scroll, places_of({100, 100, 100, 400}, 2), 100)
	testing.expect_value(t, scroll.first, 30)
	// Entry 2 grows: the view keeps its pixel of entry 2.
	settle(&scroll, places_of({300, 100, 400}, 2), 100)
	testing.expect_value(t, scroll.first, 30)
	// Entry 2 shrinks under the offset: the view keeps its last pixel.
	settle(&scroll, places_of({10, 100, 400}, 2), 100)
	testing.expect_value(t, scroll.first, 9)
	// Entry 2 leaves: the view shows the oldest entry.
	settle(&scroll, places_of({100, 400}, 3), 100)
	testing.expect(t, scroll.first == 0 && !scroll.following && scroll.anchor_number == 3)
	// The content shrinks under the view: it follows again.
	settle(&scroll, places_of({50}, 9), 100)
	testing.expect(t, scroll.first == 0 && scroll.following)
}

// The visible entries are each entry that the view meets, whole or in
// part, and no other.
@(test)
the_visible_entries_are_those_that_the_view_meets :: proc(t: ^testing.T) {
	places := places_of({100, 100, 100, 100})
	start, end := visible(places, 150, 100)
	testing.expect(t, start == 1 && end == 3)
	start, end = visible(places, 100, 100)
	testing.expect(t, start == 1 && end == 2)
	start, end = visible(places, 0, 1000)
	testing.expect(t, start == 0 && end == 4)
}

// The lines of a text: no line, a negative count, the room, one past it,
// the capacity and past it, with and without every line asked for.
@(test)
the_lines_of_a_long_text_are_bounded :: proc(t: ^testing.T) {
	shown, hidden := lines_bound(0, 10, false)
	testing.expect(t, shown == 0 && hidden == 0)
	shown, hidden = lines_bound(-4, 10, false)
	testing.expect(t, shown == 0 && hidden == 0)
	shown, hidden = lines_bound(10, 10, false)
	testing.expect(t, shown == 10 && hidden == 0)
	shown, hidden = lines_bound(11, 10, false)
	testing.expect(t, shown == 10 && hidden == 1)
	shown, hidden = lines_bound(11, 0, false)
	testing.expect(t, shown == 1 && hidden == 10)
	shown, hidden = lines_bound(11, -5, false)
	testing.expect(t, shown == 1 && hidden == 10)
	shown, hidden = lines_bound(11, 10, true)
	testing.expect(t, shown == 11 && hidden == 0)
	shown, hidden = lines_bound(WORD_LINE_CAPACITY + 7, 10, true)
	testing.expect(t, shown == WORD_LINE_CAPACITY && hidden == 7)
	shown, hidden = lines_bound(max(int), 10, true)
	testing.expect(t, shown == WORD_LINE_CAPACITY && hidden == max(int) - WORD_LINE_CAPACITY)
	shown, hidden = lines_bound(5, 10, false, 3)
	testing.expect(t, shown == 3 && hidden == 2)
}
