#+build !freestanding
package bar

import "core:testing"
import "modus:contract/reference_screen"

// The frame of the compositor: borders of 2, a close button of 24, a title
// of 24.
@(private = "file")
frame_of :: proc(surface_width: int) -> Window_Frame {
	return {outer_width = surface_width + 4, border = 2, close_size = 24, title_height = 24}
}

// title_width_of gives the width of the title, without the close button.
@(private = "file")
title_width_of :: proc(frame: Window_Frame) -> int {
	return frame.outer_width - frame.border - frame.close_size
}

// kept_on_screen says if TITLE_KEPT pixels of the title are on the screen,
// under the bar.
@(private = "file")
kept_on_screen :: proc(x, y: int, frame: Window_Frame, screen_width, screen_height: int) -> bool {
	title_left, title_right := x, x + title_width_of(frame)
	visible := min(title_right, screen_width) - max(title_left, 0)
	return visible >= TITLE_KEPT && y >= HEIGHT && y + TITLE_KEPT <= screen_height
}

// The pointer at each edge, the window held at each pixel of its title:
// the place keeps a part of the title on the screen, and a place that moved
// from the point under the pointer is at a bound. The widths 1280 and 1366
// (not a multiple of 8), the heights 768 and 765, and the reference screen.
@(test)
dragged_window_stays_on_screen :: proc(t: ^testing.T) {
	sizes := [?][2]int{{1280, 768}, {1366, 765}, {1024, 768}, {reference_screen.WIDTH, reference_screen.HEIGHT}}
	for size in sizes {
		screen_width, screen_height := size[0], size[1]
		surface_widths := [?]int{100, 480, screen_width - 4, screen_width + 300}
		for surface_width in surface_widths {
			frame := frame_of(surface_width)
			for held_x := 0; held_x < frame.outer_width - frame.border; held_x += 1 {
				for held_y in 0 ..< 24 {
					pointers := [?][2]int{{0, 0}, {screen_width - 1, 0}, {0, screen_height - 1}, {screen_width - 1, screen_height - 1}, {screen_width / 2, screen_height / 2}}
					for pointer in pointers {
						x, y := dragged_window_place(pointer[0], pointer[1], held_x, held_y, frame, screen_width, screen_height)
						if !kept_on_screen(x, y, frame, screen_width, screen_height) {
							testing.expectf(t, false, "screen %dx%d, surface %d, held at %d,%d, pointer %d,%d: the place %d,%d leaves too little of the title", screen_width, screen_height, surface_width, held_x, held_y, pointer[0], pointer[1], x, y)
							return
						}
						wanted_x, wanted_y := pointer[0] - held_x, pointer[1] - held_y
						at_bound_x := x + title_width_of(frame) == TITLE_KEPT || x == screen_width - TITLE_KEPT
						at_bound_y := y == HEIGHT || y == screen_height - TITLE_KEPT
						if (x != wanted_x && !at_bound_x) || (y != wanted_y && !at_bound_y) {
							testing.expectf(t, false, "screen %dx%d, surface %d, held at %d,%d, pointer %d,%d: the place %d,%d moved from %d,%d and is at no bound", screen_width, screen_height, surface_width, held_x, held_y, pointer[0], pointer[1], x, y, wanted_x, wanted_y)
							return
						}
					}
				}
			}
		}
	}
}

// A drop past each edge stops at the bound of that edge: the bound itself is
// kept, and one pixel past it, far past it and the largest place of the type
// give the bound.
@(test)
dropped_window_past_each_edge :: proc(t: ^testing.T) {
	SCREEN_WIDTH :: 1366 // Not a multiple of 8.
	SCREEN_HEIGHT :: 765
	frame := frame_of(480)
	left_bound := TITLE_KEPT - title_width_of(frame)
	right_bound := SCREEN_WIDTH - TITLE_KEPT
	bottom_bound := SCREEN_HEIGHT - TITLE_KEPT
	FAR :: 1 << 40

	// The right edge.
	for past in ([]int{right_bound, right_bound + 1, SCREEN_WIDTH, FAR, max(int)}) {
		x, _ := window_place_kept(past, 300, frame, SCREEN_WIDTH, SCREEN_HEIGHT)
		testing.expectf(t, x == right_bound, "the place %d at the right gives %d", past, x)
	}
	// The left edge: the end of the title stays at TITLE_KEPT, so the close
	// button is on the screen.
	for past in ([]int{left_bound, left_bound - 1, -FAR, min(int)}) {
		x, _ := window_place_kept(past, 300, frame, SCREEN_WIDTH, SCREEN_HEIGHT)
		testing.expectf(t, x == left_bound, "the place %d at the left gives %d", past, x)
		testing.expect(t, x + title_width_of(frame) == TITLE_KEPT, "the end of the title is on the screen")
	}
	// The top: never over the bar.
	for past in ([]int{HEIGHT, HEIGHT - 1, 0, -1, -FAR, min(int)}) {
		_, y := window_place_kept(300, past, frame, SCREEN_WIDTH, SCREEN_HEIGHT)
		testing.expectf(t, y == HEIGHT, "the place %d at the top gives %d", past, y)
	}
	// The bottom: TITLE_KEPT lines of the title stay on the screen.
	for past in ([]int{bottom_bound, bottom_bound + 1, SCREEN_HEIGHT, FAR, max(int)}) {
		_, y := window_place_kept(300, past, frame, SCREEN_WIDTH, SCREEN_HEIGHT)
		testing.expectf(t, y == bottom_bound, "the place %d at the bottom gives %d", past, y)
	}
	// The pointer at the right edge, held in the first columns of the title.
	for held_x in 0 ..< 4 {
		x, _ := dragged_window_place(1279, 300, held_x, 10, frame, 1280, 768)
		testing.expect_value(t, x, 1280 - TITLE_KEPT)
		x, _ = dragged_window_place(SCREEN_WIDTH - 1, 300, held_x, 10, frame, SCREEN_WIDTH, SCREEN_HEIGHT)
		testing.expect_value(t, x, right_bound)
	}
	// The pointer at the left edge, held next to the close button.
	x, _ := dragged_window_place(0, 300, title_width_of(frame) - 1, 10, frame, SCREEN_WIDTH, SCREEN_HEIGHT)
	testing.expect_value(t, x, left_bound)
	// The pointer at the top.
	_, y := dragged_window_place(300, 0, 100, 20, frame, SCREEN_WIDTH, SCREEN_HEIGHT)
	testing.expect_value(t, y, HEIGHT)
}

// A frame of no width has no title to keep: its place stays TITLE_KEPT
// from the left edge. A screen too small for two bounds keeps the bound of
// the left and of the top.
@(test)
window_place_of_no_size :: proc(t: ^testing.T) {
	empty := Window_Frame{}
	x, y := window_place_kept(-5, -5, empty, 1280, 768)
	testing.expect_value(t, x, TITLE_KEPT)
	testing.expect_value(t, y, HEIGHT)
	x, y = window_place_kept(0, HEIGHT, empty, 1280, 768)
	testing.expect_value(t, x, TITLE_KEPT)
	testing.expect_value(t, y, HEIGHT)
	// A frame narrower than its border and its close button: no title.
	narrow := Window_Frame{outer_width = 1, border = 2, close_size = 24, title_height = 24}
	x, _ = window_place_kept(0, 300, narrow, 1280, 768)
	testing.expect_value(t, x, TITLE_KEPT)
	// A screen of no size.
	frame := frame_of(480)
	x, y = window_place_kept(100, 100, frame, 0, 0)
	testing.expect_value(t, x, -TITLE_KEPT)
	testing.expect_value(t, y, HEIGHT)
	// A new window of no surface goes where the compositor puts it.
	x, y = new_window_place(64, 56, frame_of(0), 0, 1024, 768)
	testing.expect_value(t, x, 64)
	testing.expect_value(t, y, 56)
}

// Inside the screen, a window goes where the pointer puts it, to the pixel:
// a drag of one pixel moves it by one pixel, and a negative place that
// keeps the title on the screen is kept.
@(test)
dragged_window_goes_to_the_pixel :: proc(t: ^testing.T) {
	frame := frame_of(480)
	x, y := dragged_window_place(503, 205, 100, 12, frame, 1280, 768)
	testing.expect_value(t, x, 403)
	testing.expect_value(t, y, 193)
	x, y = dragged_window_place(504, 205, 100, 12, frame, 1280, 768)
	testing.expect_value(t, x, 404)
	testing.expect_value(t, y, 193)
	x, y = dragged_window_place(503, 206, 100, 12, frame, 1280, 768)
	testing.expect_value(t, x, 403)
	testing.expect_value(t, y, 194)
	x, y = dragged_window_place(502, 204, 100, 12, frame, 1280, 768)
	testing.expect_value(t, x, 402)
	testing.expect_value(t, y, 192)
	// A drag of no pixel: the place under the pointer, the same each time.
	x, y = dragged_window_place(100, 12 + HEIGHT, 100, 12, frame, 1280, 768)
	testing.expect_value(t, x, 0)
	testing.expect_value(t, y, HEIGHT)
	// A negative place: the window is partly past the left edge, and its
	// title stays on the screen.
	x, _ = window_place_kept(-1, 300, frame, 1280, 768)
	testing.expect_value(t, x, -1)
	x, _ = window_place_kept(-301, 300, frame, 1280, 768)
	testing.expect_value(t, x, -301)
}

// A new window that fits keeps the place that the compositor chose; a
// window wider than the screen shows its close button; a window higher
// than the screen starts under the bar.
@(test)
new_window_places :: proc(t: ^testing.T) {
	frame := frame_of(480)
	x, y := new_window_place(64, 56, frame, 320, 1024, 768)
	testing.expect_value(t, x, 64)
	testing.expect_value(t, y, 56)
	// Near the right and the bottom: up and left until it fits, to the pixel.
	x, y = new_window_place(800, 600, frame, 320, 1024, 768)
	testing.expect_value(t, x, 1024 - frame.outer_width)
	testing.expect_value(t, y, 768 - (320 + frame.title_height + frame.border))
	// A negative place: the whole window on the screen.
	x, y = new_window_place(-1, -1, frame, 320, 1024, 768)
	testing.expect_value(t, x, 0)
	testing.expect_value(t, y, HEIGHT)
	wide := frame_of(1500)
	x, y = new_window_place(64, 56, wide, 320, 1366, 768)
	close_right := x + wide.outer_width - wide.border
	testing.expect(t, close_right <= 1366 && close_right - wide.close_size >= 0, "the close button is on the screen")
	testing.expect_value(t, x, 1366 - wide.outer_width)
	tall := frame_of(480)
	_, y = new_window_place(64, 56, tall, 900, 1024, 768)
	testing.expect_value(t, y, HEIGHT)
}

// The reference screen: a window wider and higher than the screen, with
// the largest surface that display.open makes, shows its close button and
// starts under the bar; the place where only the title bar shows, at the
// bottom, is kept, and a place below it stops where TITLE_KEPT lines of
// the title stay on the screen. A window of the window bound placed where
// a screen of 1024 by 768 puts it keeps its place.
@(test)
new_window_places_on_the_reference_screen :: proc(t: ^testing.T) {
	WIDTH_OF_SCREEN :: reference_screen.WIDTH
	HEIGHT_OF_SCREEN :: reference_screen.HEIGHT
	LARGEST_SURFACE :: 2048
	largest := frame_of(LARGEST_SURFACE)
	x, y := new_window_place(64, 56, largest, LARGEST_SURFACE, WIDTH_OF_SCREEN, HEIGHT_OF_SCREEN)
	close_right := x + largest.outer_width - largest.border
	testing.expectf(t, close_right <= WIDTH_OF_SCREEN && close_right - largest.close_size >= 0, "the close button of a window wider than the screen ends at %d", close_right)
	testing.expect_value(t, x, WIDTH_OF_SCREEN - largest.outer_width)
	testing.expect_value(t, y, HEIGHT)

	bound := frame_of(1000)
	title_only := HEIGHT_OF_SCREEN - bound.title_height
	_, kept_y := window_place_kept(64, title_only, bound, WIDTH_OF_SCREEN, HEIGHT_OF_SCREEN)
	testing.expect_value(t, kept_y, title_only)
	for below in ([]int{HEIGHT_OF_SCREEN - TITLE_KEPT, HEIGHT_OF_SCREEN - TITLE_KEPT + 1, HEIGHT_OF_SCREEN - 1, HEIGHT_OF_SCREEN, HEIGHT_OF_SCREEN + 1, max(int) / 2}) {
		_, below_y := window_place_kept(64, below, bound, WIDTH_OF_SCREEN, HEIGHT_OF_SCREEN)
		testing.expectf(t, below_y == HEIGHT_OF_SCREEN - TITLE_KEPT, "the place %d below the screen gives %d", below, below_y)
	}

	x, y = new_window_place(64, 56, bound, 708, WIDTH_OF_SCREEN, HEIGHT_OF_SCREEN)
	testing.expect_value(t, x, 64)
	testing.expect_value(t, y, 56)
}
