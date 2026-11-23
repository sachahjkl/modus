#+build !freestanding
package paint_model

import "core:fmt"
import "core:testing"
import "core:time"
import "modus:graphics"

// The measures of time of this package run only with -define:MEASURE=true:
// a test that measures time is opt-in, and a normal run prints no time.
MEASURE :: #config(MEASURE, false)

// The work of a fill of the sky of a photo of 6000 x 4000 on the thread
// that runs it: the copy before the change, the fill, the record of its
// undo step and the undo. It prints each time; it asserts none.
@(test)
the_measures_of_a_fill_on_a_photo :: proc(t: ^testing.T) {
	when !MEASURE {
		return
	}
	WIDTH :: 6000
	HEIGHT :: 4000
	photo := Picture{pixels = make([]graphics.Color, WIDTH * HEIGHT)}
	defer delete(photo.pixels)
	picture_extend(&photo, WIDTH, HEIGHT)
	state := u32(7)
	for &pixel in photo.pixels[:200 * WIDTH] {
		state = state * 1_664_525 + 1_013_904_223
		pixel = state >> 8
	}
	for &pixel in photo.pixels[200 * WIDTH:] {
		pixel = 0x87CEEB
	}
	before := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(before)
	start := time.tick_now()
	copy(before, photo.pixels)
	copied := time.tick_since(start)
	spans := make([]Fill_Span, 1 << 16)
	defer delete(spans)
	memory := Fill_Memory{spans = spans}
	start = time.tick_now()
	box, fill_outcome := fill_region(&photo, 3000, 3000, 0x228B22, &memory)
	filled := time.tick_since(start)
	bound := WIDTH * HEIGHT * size_of(graphics.Color)
	history := History{ring = make([]u8, bound)}
	defer delete(history.ring)
	scratch := new(History_Scratch)
	defer free(scratch)
	start = time.tick_now()
	outcome := history_record(&history, before, photo.pixels, WIDTH, box, bound, scratch)
	recorded := time.tick_since(start)
	start = time.tick_now()
	_, undone := history_undo(&history, &photo, scratch)
	undo_time := time.tick_since(start)
	testing.expect(t, fill_outcome == .Done && outcome == .Kept && undone)
	pixels := (box.right - box.left) * (box.bottom - box.top)
	fmt.printfln("measure: a fill of %d pixels of a photo of 6000 x 4000: copy before %v, fill %v (%d spans at most), record %v, undo %v", pixels, copied, filled, memory.peak, recorded, undo_time)
}

// A fill of a maze of 6000 x 4000, walls at each odd pixel of each odd
// row: the worst case of the stack of spans that a picture can make. It
// prints the time and the most spans that waited; it asserts none.
@(test)
the_measures_of_a_fill_of_a_maze :: proc(t: ^testing.T) {
	when !MEASURE {
		return
	}
	WIDTH :: 6000
	HEIGHT :: 4000
	maze := Picture{pixels = make([]graphics.Color, WIDTH * HEIGHT)}
	defer delete(maze.pixels)
	picture_extend(&maze, WIDTH, HEIGHT)
	for row := 1; row < HEIGHT; row += 2 {
		for column := 1; column < WIDTH; column += 2 {
			maze.pixels[row * WIDTH + column] = 0
		}
	}
	spans := make([]Fill_Span, WIDTH * HEIGHT / 2)
	defer delete(spans)
	memory := Fill_Memory{spans = spans}
	start := time.tick_now()
	_, outcome := fill_region(&maze, 0, 0, 0x228B22, &memory)
	filled := time.tick_since(start)
	testing.expect_value(t, outcome, Fill_Outcome.Done)
	fmt.printfln("measure: a fill of a maze of 6000 x 4000: %v, %d spans at most (%d bytes)", filled, memory.peak, memory.peak * size_of(Fill_Span))
}


// The work of the window at the start of a stroke on a photo of 6000 x
// 4000: before, the copy of the whole picture, then the first segment;
// after, the first segment, which copies the tiles that it writes. It
// prints each time; it asserts none.
@(test)
the_measures_of_a_stroke_start :: proc(t: ^testing.T) {
	when !MEASURE {
		return
	}
	WIDTH :: 6000
	HEIGHT :: 4000
	photo := Picture{pixels = make([]graphics.Color, WIDTH * HEIGHT)}
	defer delete(photo.pixels)
	picture_extend(&photo, WIDTH, HEIGHT)
	copy_pixels := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(copy_pixels)
	// The copy is touched once first, so neither way pays its first pages.
	copy(copy_pixels, photo.pixels)
	start := time.tick_now()
	copy(copy_pixels, photo.pixels)
	segment_draw(&photo, 3000, 2000, 3001, 2000, 21, 0xFF0000)
	whole := time.tick_since(start)
	copy_before := new(Copy_Before)
	defer free(copy_before)
	copy_before.pixels = copy_pixels
	start = time.tick_now()
	photo.before = copy_before
	segment_draw(&photo, 3100, 2100, 3101, 2100, 21, 0x00FF00)
	tiles := time.tick_since(start)
	fmt.printfln("measure: the start of a stroke of 21 pixels on a photo of 6000 x 4000: %v with the copy of the picture, %v with the copy of %d tiles", whole, tiles, copy_before.copied)
}

