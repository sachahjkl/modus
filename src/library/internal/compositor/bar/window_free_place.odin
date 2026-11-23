package bar

import "modus:graphics"

// The place of a new window (src/md/features/window_placement.md): a free
// place of the work area with the most room, then the first cascade place
// that covers no title of a shown window, then the place of least cover.
// The procedure holds no state: a host test gives it each arrangement.

// A rectangle of the desktop, in pixels: the outer box of a window, or the
// work area.
Box :: struct {
	x, y, width, height: int,
}

// The cascade places, when no place is free: the first at (CASCADE_X,
// CASCADE_Y) of the desktop, each next one lower and to the right. Each is
// a sum of spacing tokens, so the windows line up with each other
// (docs/DESIGN.md, "6. Spacing").
CASCADE_X :: 64
CASCADE_Y :: 56
CASCADE_STEP_X :: 40
CASCADE_STEP_Y :: 32
CASCADE_COUNT :: 8

// The gap between two windows: it counts as a part of the room of a window.
PLACE_GAP :: graphics.GAP

// The candidates at most: the two edges of the work area and the two
// sides of each window give the starts of a free rectangle.
@(private = "file")
PLACE_WINDOW_CAPACITY :: WINDOW_CAPACITY

@(private = "file")
overlap :: proc "contextless" (a, b: Box) -> int {
	width := min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
	height := min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
	if width <= 0 || height <= 0 {
		return 0
	}
	return width * height
}

// grown gives a box with the gap around it: two boxes closer than the gap
// cover each other.
@(private = "file")
grown :: proc "contextless" (box: Box) -> Box {
	return {box.x - PLACE_GAP, box.y - PLACE_GAP, box.width + 2 * PLACE_GAP, box.height + 2 * PLACE_GAP}
}

@(private = "file")
cover_of :: proc "contextless" (place: Box, shown: []Box) -> (cover: int) {
	for box in shown {
		cover += overlap(place, grown(box))
	}
	return cover
}

// room_of gives the free room of a free place: the width from its left to
// the nearest window or edge on its right, over the rows of the window,
// times the height from its top to the nearest window or edge under it,
// over its columns.
@(private = "file")
room_of :: proc "contextless" (place: Box, work: Box, shown: []Box) -> int {
	right := work.x + work.width
	bottom := work.y + work.height
	for box in shown {
		near := grown(box)
		rows_meet := near.y < place.y + place.height && near.y + near.height > place.y
		columns_meet := near.x < place.x + place.width && near.x + near.width > place.x
		if rows_meet && near.x >= place.x + place.width {
			right = min(right, near.x)
		}
		if columns_meet && near.y >= place.y + place.height {
			bottom = min(bottom, near.y)
		}
	}
	return (right - place.x) * (bottom - place.y)
}

// title_cover gives the pixels of the title bars of the shown windows that
// a place covers.
@(private = "file")
title_cover :: proc "contextless" (place: Box, shown: []Box, title_height: int) -> (cover: int) {
	for box in shown {
		cover += overlap(place, {box.x, box.y, box.width, title_height})
	}
	return cover
}

// The weight of a pixel of a title in the cost of a place that covers
// windows: more than the pixels of any window, so the place that covers no
// title, or the least of them, comes first whatever it covers of the
// bodies. The principal reaches each window by its title.
@(private = "file")
TITLE_WEIGHT :: 1 << 24

// cost_of gives the cost of a place that covers windows: the pixels of the
// titles that it covers, weighted, then the pixels of the windows.
@(private = "file")
cost_of :: proc "contextless" (place: Box, shown: []Box, title_height: int) -> int {
	return title_cover(place, shown, title_height) * TITLE_WEIGHT + cover_of(place, shown)
}

// fits says if a place is in the work area with the gap at each edge.
@(private = "file")
fits :: proc "contextless" (place: Box, work: Box) -> bool {
	return place.x >= work.x + PLACE_GAP && place.y >= work.y + PLACE_GAP && place.x + place.width <= work.x + work.width - PLACE_GAP && place.y + place.height <= work.y + work.height - PLACE_GAP
}

// new_window_free_place gives the place of the top left corner of a new
// window of an outer width and height, in the work area with the gap at
// each edge, from the outer boxes of the windows that show. found is false
// when the window does not fit there: the caller then takes
// new_window_place. Of the
// shown boxes, the first PLACE_WINDOW_CAPACITY count.
new_window_free_place :: proc "contextless" (work: Box, shown_boxes: []Box, outer_width, outer_height, title_height: int) -> (x, y: int, found: bool) {
	if outer_width + 2 * PLACE_GAP > work.width || outer_height + 2 * PLACE_GAP > work.height || outer_width <= 0 || outer_height <= 0 {
		return 0, 0, false
	}
	shown := shown_boxes[:min(len(shown_boxes), PLACE_WINDOW_CAPACITY)]
	// The starts of the candidates: the edges of the work area, right of
	// and under each window with the gap, and under the title of each
	// window, where a window that must cover one covers no title.
	xs: [PLACE_WINDOW_CAPACITY + 1]int
	ys: [2 * PLACE_WINDOW_CAPACITY + 1]int
	xs[0], ys[0] = work.x + PLACE_GAP, work.y + PLACE_GAP
	for box, index in shown {
		xs[index + 1] = box.x + box.width + PLACE_GAP
		ys[2 * index + 1] = box.y + box.height + PLACE_GAP
		ys[2 * index + 2] = box.y + title_height + PLACE_GAP
	}
	columns := len(shown) + 1
	rows := 2 * len(shown) + 1
	best_room := -1
	least_cost := max(int)
	least_x, least_y := work.x + PLACE_GAP, work.y + PLACE_GAP
	keep_least :: proc "contextless" (place: Box, cost: int, least_cost: ^int, least_x, least_y: ^int) {
		if cost < least_cost^ || cost == least_cost^ && (place.y < least_y^ || place.y == least_y^ && place.x < least_x^) {
			least_cost^, least_x^, least_y^ = cost, place.x, place.y
		}
	}
	for row in 0 ..< rows {
		for column in 0 ..< columns {
			place := Box{xs[column], ys[row], outer_width, outer_height}
			if !fits(place, work) {
				continue
			}
			if cover_of(place, shown) == 0 {
				room := room_of(place, work, shown)
				// The most room; equal rooms take the top, then the left.
				if room > best_room || room == best_room && (place.y < y || place.y == y && place.x < x) {
					best_room, x, y = room, place.x, place.y
				}
			} else {
				keep_least(place, cost_of(place, shown, title_height), &least_cost, &least_x, &least_y)
			}
		}
	}
	if best_room >= 0 {
		return x, y, true
	}
	for step in 0 ..< CASCADE_COUNT {
		place := Box{work.x + CASCADE_X + step * CASCADE_STEP_X, work.y + CASCADE_Y - HEIGHT + step * CASCADE_STEP_Y, outer_width, outer_height}
		if !fits(place, work) {
			continue
		}
		if title_cover(place, shown, title_height) == 0 {
			return place.x, place.y, true
		}
		keep_least(place, cost_of(place, shown, title_height), &least_cost, &least_x, &least_y)
	}
	return least_x, least_y, true
}
