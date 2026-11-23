#+build !freestanding
package bar

import "core:testing"

@(private = "file")
WORK :: Box{0, HEIGHT, 1536, 832}
@(private = "file")
TITLE :: 30

@(private = "file")
covers :: proc(place: Box, shown: []Box) -> bool {
	for box in shown {
		width := min(place.x + place.width, box.x + box.width) - max(place.x, box.x)
		height := min(place.y + place.height, box.y + box.height) - max(place.y, box.y)
		if width > 0 && height > 0 {
			return true
		}
	}
	return false
}

@(private = "file")
inside_work :: proc(place: Box) -> bool {
	return place.x >= WORK.x && place.y >= WORK.y && place.x + place.width <= WORK.x + WORK.width && place.y + place.height <= WORK.y + WORK.height
}

// The edges first: a size of 0, a window that fills the work area with its
// gaps exactly, one pixel more in each way, and no window shown.
@(test)
a_new_window_at_the_edges_of_the_work_area :: proc(t: ^testing.T) {
	_, _, found := new_window_free_place(WORK, nil, 0, 100, TITLE)
	testing.expect(t, !found)
	_, _, found = new_window_free_place(WORK, nil, 100, 0, TITLE)
	testing.expect(t, !found)
	whole_width := WORK.width - 2 * PLACE_GAP
	whole_height := WORK.height - 2 * PLACE_GAP
	x, y, whole_found := new_window_free_place(WORK, nil, whole_width, whole_height, TITLE)
	testing.expect(t, whole_found)
	testing.expect_value(t, x, WORK.x + PLACE_GAP)
	testing.expect_value(t, y, WORK.y + PLACE_GAP)
	_, _, found = new_window_free_place(WORK, nil, whole_width + 1, whole_height, TITLE)
	testing.expect(t, !found)
	_, _, found = new_window_free_place(WORK, nil, whole_width, whole_height + 1, TITLE)
	testing.expect(t, !found)
	x, y, found = new_window_free_place(WORK, nil, 560, 420, TITLE)
	testing.expect(t, found)
	testing.expect_value(t, x, WORK.x + PLACE_GAP)
	testing.expect_value(t, y, WORK.y + PLACE_GAP)
}

// Windows that leave no free place: the first cascade place whose window
// covers no title; with every title covered, the least cover, in the work
// area; and more windows than the capacity are read up to it.
@(test)
a_new_window_in_a_full_work_area_covers_no_title :: proc(t: ^testing.T) {
	// One window that fills the work area but a band at its top for titles.
	full := []Box{{0, WORK.y + 200, WORK.width, WORK.height - 200}}
	x, y, found := new_window_free_place(WORK, full, 400, 300, TITLE)
	testing.expect(t, found)
	place := Box{x, y, 400, 300}
	testing.expect(t, inside_work(place))
	title := Box{full[0].x, full[0].y, full[0].width, TITLE}
	testing.expect(t, !covers(place, []Box{title}))
	// A cascade of eight windows whose titles cover each cascade place.
	cascade: [CASCADE_COUNT + 2]Box
	cascade[0] = {0, WORK.y, WORK.width, WORK.height}
	for step in 0 ..< CASCADE_COUNT {
		cascade[step + 1] = {WORK.x + CASCADE_X + step * CASCADE_STEP_X, WORK.y + CASCADE_Y - HEIGHT + step * CASCADE_STEP_Y, 400, 300}
	}
	x, y, found = new_window_free_place(WORK, cascade[:CASCADE_COUNT + 1], 400, 300, TITLE)
	testing.expect(t, found)
	testing.expect(t, inside_work({x, y, 400, 300}))
	// The arrangement of the main machine test: a large window that fits
	// nowhere free covers no title when a place under the titles exists,
	// and covers the least title when none does.
	desk := []Box{{8, 40, 803, 486}, {24, 408, 482, 352}, {568, 40, 522, 672}, {520, 408, 482, 352}, {232, 144, 322, 232}}
	x, y, found = new_window_free_place(WORK, desk, 978, 742, TITLE)
	testing.expect(t, found)
	big := Box{x, y, 978, 742}
	testing.expect(t, inside_work(big))
	monitor_title := Box{568, 40, 522, TITLE}
	testing.expectf(t, !covers(big, []Box{monitor_title}), "%v covers the title of the window at 568,40", big)
	many: [100]Box
	for &box, index in many {
		box = {index * 15, WORK.y, 10, 10}
	}
	_, _, found = new_window_free_place(WORK, many[:], 100, 100, TITLE)
	testing.expect(t, found)
}

// The free cases, last: a second window covers no part of the first when
// the work area has room for both; a third one neither; a window that
// fits only below the others goes there; the place stays in the work area,
// a bar at the bottom too. The cascade by count put the second window at
// 40 pixels from the first, over its title.
@(test)
a_new_window_covers_no_shown_window_when_there_is_room :: proc(t: ^testing.T) {
	shown: [dynamic]Box
	defer delete(shown)
	sizes := [?][2]int{{560, 420}, {520, 640}, {480, 320}}
	for size in sizes {
		x, y, found := new_window_free_place(WORK, shown[:], size[0], size[1], TITLE)
		testing.expect(t, found)
		place := Box{x, y, size[0], size[1]}
		testing.expectf(t, !covers(place, shown[:]), "%v covers a window of %v", place, shown)
		testing.expect(t, inside_work(place))
		append(&shown, place)
	}
	// A bar at the bottom: the work area starts at 0.
	bottom_work := Box{0, 0, 1536, 832}
	x, y, found := new_window_free_place(bottom_work, nil, 560, 420, TITLE)
	testing.expect(t, found)
	testing.expect_value(t, x, PLACE_GAP)
	testing.expect_value(t, y, PLACE_GAP)
	// A wide window on the left: the new one goes under it, where it fits.
	wide := []Box{{PLACE_GAP, WORK.y + PLACE_GAP, 1200, 300}}
	x, y, found = new_window_free_place(WORK, wide, 600, 300, TITLE)
	testing.expect(t, found)
	testing.expect(t, !covers({x, y, 600, 300}, wide))
	testing.expect_value(t, y, WORK.y + PLACE_GAP + 300 + PLACE_GAP)
}
