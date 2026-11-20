#+build !freestanding
package bar

import "core:testing"
import "modus:contract/ring"
import "modus:contract/scale_factor"

// The release of a surface ends the drag of that window only: no drag (-1)
// is ended by nothing, a drag of another window goes on, and the first and
// the last client of the table are windows like the others.
@(test)
a_release_ends_the_drag_of_its_window :: proc(t: ^testing.T) {
	testing.expect(t, !drag_ended_by_release(-1, 0))
	testing.expect(t, !drag_ended_by_release(-1, -1))
	testing.expect(t, !drag_ended_by_release(3, 4))
	testing.expect(t, !drag_ended_by_release(4, 3))
	testing.expect(t, !drag_ended_by_release(0, 31))
	testing.expect(t, drag_ended_by_release(0, 0))
	testing.expect(t, drag_ended_by_release(31, 31))
}

// The end of a drag asks for a size only for a window that shows its
// surface with none pending, and for another size: each other case of the
// eight asks for nothing.
@(test)
the_end_of_a_drag_asks_only_a_steady_window :: proc(t: ^testing.T) {
	for released in ([2]bool{false, true}) {
		for pending in ([2]bool{false, true}) {
			for same_size in ([2]bool{false, true}) {
				asks := drag_asks_size(released, pending, same_size)
				testing.expectf(t, asks == (!released && !pending && !same_size), "released %v, pending %v, same size %v: asks %v", released, pending, same_size, asks)
			}
		}
	}
}

// The slot of an answer: empty, it sends nothing; a kept answer waits
// while the ring has no room; a second answer does not replace it; the
// kept answer is sent first when the ring has room, once, and the slot is
// empty after it.
@(test)
the_slot_keeps_one_answer :: proc(t: ^testing.T) {
	slot: Answer_Slot
	_, send := answer_slot_send(&slot, true)
	testing.expect(t, !send)
	first := ring.Record{kind = 10, values = {0 = 1, 1 = 4}}
	second := ring.Record{kind = 10, values = {0 = 2, 1 = 5}}
	testing.expect(t, answer_slot_keep(&slot, first))
	_, send = answer_slot_send(&slot, false)
	testing.expect(t, !send)
	testing.expect(t, slot.due)
	testing.expect(t, !answer_slot_keep(&slot, second))
	testing.expect(t, slot.record == first)
	record: ring.Record
	record, send = answer_slot_send(&slot, true)
	testing.expect(t, send && record == first)
	testing.expect(t, !slot.due)
	_, send = answer_slot_send(&slot, true)
	testing.expect(t, !send)
	testing.expect(t, answer_slot_keep(&slot, second))
}

// The grid of the background test: a window of up to 64 logical pixels at
// a corner up to 13, at 1.375, is inside 160 pixels.
@(private = "file")
COUNT_GRID_SIDE :: 160
@(private = "file")
Count_Grid :: [COUNT_GRID_SIDE][COUNT_GRID_SIDE]u8

@(private = "file")
count_grid_paint :: proc(grid: ^Count_Grid, box: Screen_Box) {
	for row in max(box.top, 0) ..< min(box.bottom, COUNT_GRID_SIDE) {
		for column in max(box.left, 0) ..< min(box.right, COUNT_GRID_SIDE) {
			grid[row][column] += 1
		}
	}
}

// The background of a window: at each scale and odd corners, with a
// surface of the scale in force and one of the other scale, the strips,
// the surface and the frame cover the frame on the screen, and no pixel of
// a strip is under the frame or the surface: no pixel is written twice. A
// surface of the scale in force leaves no strip.
@(test)
the_background_fills_only_what_the_surface_leaves :: proc(t: ^testing.T) {
	BORDER :: 2
	TITLE :: 24
	scales := [2]scale_factor.Scale{.Ten_Eighths, .Eleven_Eighths}
	for scale, scale_index in scales {
		other := scales[1 - scale_index]
		for corner in ([?][2]int{{0, 0}, {3, 7}, {5, 13}, {11, 1}}) {
			for size in ([?][2]int{{7, 3}, {13, 29}, {64, 63}}) {
				x, y, width, height := corner[0], corner[1], size[0], size[1]
				outer := screen_box_of({x, y, x + width + 2 * BORDER, y + height + TITLE + BORDER}, scale)
				interior := screen_box_of({x + BORDER, y + TITLE, x + BORDER + width, y + TITLE + height}, scale)
				logical_parts := frame_parts(x, y, width, height, BORDER, TITLE)
				parts: [4]Screen_Box
				for part, index in logical_parts {
					parts[index] = screen_box_of(part, scale)
				}
				for surface_scale in ([2]scale_factor.Scale{scale, other}) {
					surface := surface_clip(interior.left, interior.top, int(scale_factor.screen_pixel_of_logical_pixel(i32(width), surface_scale)), int(scale_factor.screen_pixel_of_logical_pixel(i32(height), surface_scale)), interior)
					strips := background_strips(surface, frame_inner(parts))
					if surface_scale == scale {
						testing.expectf(t, strips == [2]Screen_Box{}, "a surface of the scale in force leaves the strips %v", strips)
					}
					covered: Count_Grid
					in_frame: Count_Grid
					for part in parts {
						count_grid_paint(&in_frame, part)
					}
					count_grid_paint(&in_frame, surface)
					for strip in strips {
						count_grid_paint(&covered, strip)
					}
					for row in 0 ..< COUNT_GRID_SIDE {
						for column in 0 ..< COUNT_GRID_SIDE {
							inside := column >= outer.left && column < outer.right && row >= outer.top && row < outer.bottom
							strip_count := covered[row][column]
							if strip_count > 0 && (in_frame[row][column] > 0 || strip_count > 1 || !inside) {
								testing.expectf(t, false, "at %v, a surface at %v, the window %v at %v: the pixel %d,%d of a strip is written twice or outside", scale, surface_scale, size, corner, column, row)
								return
							}
							if inside && strip_count == 0 && in_frame[row][column] == 0 {
								testing.expectf(t, false, "at %v, a surface at %v, the window %v at %v: the pixel %d,%d is a gap", scale, surface_scale, size, corner, column, row)
								return
							}
						}
					}
				}
			}
		}
	}
}
