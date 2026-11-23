#+build !freestanding
package interface

import "core:testing"

// The view of a layout: a layout that fits on both axes scrolls on none;
// one unit past the view on one axis scrolls on it, and its bar can make
// the other axis pass too. The settings window at 2, 560 x 688 in a view
// of 560 x 482, scrolls down only when its width fits beside the bar.
@(test)
the_view_of_a_layout_scrolls_on_each_axis_that_passes :: proc(t: ^testing.T) {
	T :: SCROLL_BAR_THICKNESS
	fits := window_scroll_view_of(560, 482, 560, 482)
	testing.expect(t, !fits.scrolls_x && !fits.scrolls_y && fits.most_x == 0 && fits.most_y == 0 && fits.inner_width == 560 && fits.inner_height == 482)
	down := window_scroll_view_of(500, 688, 560, 482)
	testing.expect(t, !down.scrolls_x && down.scrolls_y && down.inner_width == 560 - T && down.most_y == 688 - 482)
	// One unit past the height: the bar takes 17 columns, and a layout of
	// the whole width then passes the view less the bar.
	both := window_scroll_view_of(560, 483, 560, 482)
	testing.expect(t, both.scrolls_x && both.scrolls_y && both.inner_width == 560 - T && both.inner_height == 482 - T)
	testing.expect(t, both.most_x == T && both.most_y == 483 - (482 - T))
	// A view smaller than the bars: no room, and the whole layout to scroll.
	tiny := window_scroll_view_of(100, 100, 5, 5)
	testing.expect(t, tiny.inner_width == 0 && tiny.inner_height == 0 && tiny.most_x == 100 && tiny.most_y == 100)
	// A layout of 0: nothing scrolls.
	empty := window_scroll_view_of(0, 0, 560, 482)
	testing.expect(t, !empty.scrolls_x && !empty.scrolls_y)
}

// The clamp keeps a scroll inside 0 to most, the edges and past them, and
// a most below 0 keeps 0.
@(test)
a_scroll_stays_inside_its_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, window_scroll_clamp(-1, 100), 0)
	testing.expect_value(t, window_scroll_clamp(min(int), 100), 0)
	testing.expect_value(t, window_scroll_clamp(0, 100), 0)
	testing.expect_value(t, window_scroll_clamp(100, 100), 100)
	testing.expect_value(t, window_scroll_clamp(101, 100), 100)
	testing.expect_value(t, window_scroll_clamp(max(int), 100), 100)
	testing.expect_value(t, window_scroll_clamp(5, -3), 0)
}

// The focus into view: a part in the view keeps the scroll, at each edge
// exactly; one unit past an edge moves the view by the part and the gap; a
// part longer than the view shows its start; a negative gap is no gap.
@(test)
a_part_comes_into_the_view_with_its_gap :: proc(t: ^testing.T) {
	testing.expect_value(t, window_scroll_to_show(100, 400, 100, 24, 8), 100)
	testing.expect_value(t, window_scroll_to_show(100, 400, 476, 24, 8), 100)
	testing.expect_value(t, window_scroll_to_show(100, 400, 477, 24, 8), 109)
	testing.expect_value(t, window_scroll_to_show(100, 400, 99, 24, 8), 91)
	testing.expect_value(t, window_scroll_to_show(100, 400, 0, 500, 8), -8)
	testing.expect_value(t, window_scroll_to_show(100, 400, 99, 24, -5), 99)
	// A gap larger than a quarter of the view is cut to it.
	testing.expect_value(t, window_scroll_to_show(0, 40, 50, 10, 100), 30)
}

// A page is the view less one line, at least one line, in each direction.
@(test)
a_page_keeps_one_line_in_sight :: proc(t: ^testing.T) {
	testing.expect_value(t, window_scroll_page(0, 482, 16, true), 466)
	testing.expect_value(t, window_scroll_page(466, 482, 16, false), 0)
	testing.expect_value(t, window_scroll_page(0, 10, 16, true), 16)
	testing.expect_value(t, window_scroll_page(0, 0, 0, true), 1)
}
