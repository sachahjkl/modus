#+build !freestanding
package paint_model

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "modus:contract/store"
import "modus:graphics"

// picture_make gives a picture of a size in memory of room pixels, at
// least its own.
@(private = "file")
picture_make :: proc(width, height: int, room := 0) -> Picture {
	picture := Picture{pixels = make([]graphics.Color, max(width * height, room))}
	picture_extend(&picture, width, height)
	return picture
}

@(private = "file")
pixel_at :: proc(picture: ^Picture, x, y: int) -> graphics.Color {
	return picture.pixels[y * picture.width + x]
}

// The bounds of a picture are of one memory object, not of a screen: each
// side below 1 and past PICTURE_SIDE_LIMIT is refused, and a product past
// PICTURE_PIXELS_LIMIT; a photo of 24 MP, a picture of 4096 x 4096 and a
// panorama of the largest side are taken.
@(test)
the_bounds_of_a_picture :: proc(t: ^testing.T) {
	for size in ([][2]int{{0, 1}, {1, 0}, {-1, 1}, {min(int), min(int)}, {PICTURE_SIDE_LIMIT + 1, 1}, {1, PICTURE_SIDE_LIMIT + 1}, {PICTURE_SIDE_LIMIT, PICTURE_SIDE_LIMIT}, {PICTURE_SIDE_LIMIT, PICTURE_PIXELS_LIMIT / PICTURE_SIDE_LIMIT + 1}, {max(int), max(int)}}) {
		_, ok := picture_pixels_for(size[0], size[1])
		testing.expectf(t, !ok, "the size %v is refused", size)
	}
	for size in ([][2]int{{1, 1}, {6000, 4000}, {4096, 4096}, {PICTURE_SIDE_LIMIT, 64}, {PICTURE_SIDE_LIMIT, PICTURE_PIXELS_LIMIT / PICTURE_SIDE_LIMIT}}) {
		pixels, ok := picture_pixels_for(size[0], size[1])
		testing.expectf(t, ok && pixels == size[0] * size[1], "the size %v is taken", size)
	}
}

// The extent grows in the memory that the caller gives and never shrinks.
// A size that does not shrink it changes nothing; a size past the bounds,
// or past the memory, is refused and changes nothing. A wider extent moves
// the rows to the new width: the pixels in the extent stay at their row
// and column, and the pixels that join it are paper.
@(test)
the_extent_grows_and_never_shrinks :: proc(t: ^testing.T) {
	picture := picture_make(10, 10, room = 30 * 12)
	defer delete(picture.pixels)
	picture.pixels[5 * 10 + 5] = 0x123456
	picture.pixels[9 * 10 + 9] = 0x654321
	for size in ([][2]int{{0, 0}, {-1, -1}, {5, 5}, {min(int), min(int)}, {10, 10}}) {
		testing.expectf(t, picture_extend(&picture, size[0], size[1]) == .Unchanged, "the size %v does not shrink the extent", size)
		testing.expect(t, picture.width == 10 && picture.height == 10)
	}
	generation := picture.generation
	testing.expect_value(t, picture_extend(&picture, 31, 12), Extend_Outcome.No_Room)
	testing.expect_value(t, picture_extend(&picture, PICTURE_SIDE_LIMIT + 1, 1), Extend_Outcome.Too_Large)
	testing.expect_value(t, picture_extend(&picture, max(int), max(int)), Extend_Outcome.Too_Large)
	testing.expect(t, picture.generation == generation && picture.width == 10 && pixel_at(&picture, 5, 5) == 0x123456)
	testing.expect_value(t, picture_extend(&picture, 30, 12), Extend_Outcome.Grown)
	testing.expect(t, picture.generation != generation && picture.width == 30 && picture.height == 12)
	testing.expect_value(t, pixel_at(&picture, 5, 5), graphics.Color(0x123456))
	testing.expect_value(t, pixel_at(&picture, 9, 9), graphics.Color(0x654321))
	for place in ([][2]int{{10, 0}, {29, 5}, {0, 10}, {29, 11}}) {
		testing.expectf(t, pixel_at(&picture, place[0], place[1]) == COLOR_PAPER, "the pixel %v that joined the extent is paper", place)
	}
}

// The one large case: a photo of 6000 x 4000 grows from its first rows in
// memory of its size, 96 MB, which a fixed picture of the module could not
// hold.
@(test)
a_picture_holds_a_photo_of_24_megapixels :: proc(t: ^testing.T) {
	picture := picture_make(6000, 2, room = 6000 * 4000)
	defer delete(picture.pixels)
	segment_draw(&picture, 0, 0, 5999, 0, 1, 0x112233)
	testing.expect_value(t, picture_extend(&picture, 6000, 4000), Extend_Outcome.Grown)
	testing.expect_value(t, pixel_at(&picture, 5999, 0), graphics.Color(0x112233))
	testing.expect_value(t, pixel_at(&picture, 5999, 3999), COLOR_PAPER)
	box := segment_draw(&picture, 5990, 3990, 5999, 3999, 1, 0x445566)
	testing.expect_value(t, box, Box{5990, 3990, 6000, 4000})
	testing.expect_value(t, pixel_at(&picture, 5999, 3999), graphics.Color(0x445566))
}

// A segment, a rectangle and an ellipse outside the extent change nothing:
// the box is empty and the generation stays. A coordinate past the limit is
// cut, and the box is in the extent.
@(test)
a_shape_outside_the_picture_changes_nothing :: proc(t: ^testing.T) {
	picture := picture_make(100, 80)
	defer delete(picture.pixels)
	generation := picture.generation
	testing.expect(t, box_empty(segment_draw(&picture, -50, -50, -10, -10, 3, 0)))
	testing.expect(t, box_empty(segment_draw(&picture, 200, 0, 300, 79, 3, 0)))
	testing.expect(t, box_empty(rectangle_draw(&picture, 100, 80, 140, 120, 2, 0)))
	testing.expect(t, box_empty(ellipse_draw(&picture, -40, -40, -1, -1, 2, 0)))
	testing.expect_value(t, picture.generation, generation)
	box := segment_draw(&picture, min(int), 40, max(int), 40, 1, 0)
	testing.expect_value(t, box, Box{0, 40, 100, 41})
	testing.expect_value(t, pixel_at(&picture, 0, 40), graphics.Color(0))
	testing.expect_value(t, pixel_at(&picture, 99, 40), graphics.Color(0))
	testing.expect_value(t, pixel_at(&picture, 50, 39), COLOR_PAPER)
	// A click with no move draws one square of the size.
	box = segment_draw(&picture, 10, 10, 10, 10, 3, 0x00FF00)
	testing.expect_value(t, box, Box{9, 9, 12, 12})
	testing.expect_value(t, pixel_at(&picture, 9, 9), graphics.Color(0x00FF00))
	testing.expect_value(t, pixel_at(&picture, 12, 12), COLOR_PAPER)
}

// The border of a rectangle and of an ellipse: inside their box, the
// middle left as it was, and a thickness larger than the box fills it.
@(test)
the_borders_of_a_rectangle_and_an_ellipse :: proc(t: ^testing.T) {
	picture := picture_make(100, 100)
	defer delete(picture.pixels)
	box := rectangle_draw(&picture, 50, 50, 10, 10, 2, 0xFF0000)
	testing.expect_value(t, box, Box{10, 10, 51, 51})
	testing.expect_value(t, pixel_at(&picture, 10, 10), graphics.Color(0xFF0000))
	testing.expect_value(t, pixel_at(&picture, 50, 50), graphics.Color(0xFF0000))
	testing.expect_value(t, pixel_at(&picture, 11, 30), graphics.Color(0xFF0000))
	testing.expect_value(t, pixel_at(&picture, 12, 30), COLOR_PAPER)
	testing.expect_value(t, pixel_at(&picture, 30, 30), COLOR_PAPER)
	testing.expect_value(t, pixel_at(&picture, 51, 51), COLOR_PAPER)
	picture_clear(&picture)
	box = ellipse_draw(&picture, 10, 10, 89, 49, 3, 0x0000FF)
	testing.expect_value(t, box, Box{10, 10, 90, 50})
	testing.expect_value(t, pixel_at(&picture, 50, 30), COLOR_PAPER) // The middle.
	testing.expect_value(t, pixel_at(&picture, 10, 10), COLOR_PAPER) // A corner of the box is outside the ellipse.
	testing.expect_value(t, pixel_at(&picture, 50, 10), graphics.Color(0x0000FF)) // The top.
	testing.expect_value(t, pixel_at(&picture, 50, 49), graphics.Color(0x0000FF)) // The bottom.
	testing.expect_value(t, pixel_at(&picture, 10, 30), graphics.Color(0x0000FF)) // The left.
	testing.expect_value(t, pixel_at(&picture, 89, 30), graphics.Color(0x0000FF)) // The right.
	for row in 0 ..< 100 {
		for column in 0 ..< 100 {
			inside := column >= 10 && column < 90 && row >= 10 && row < 50
			testing.expectf(t, inside || pixel_at(&picture, column, row) == COLOR_PAPER, "the ellipse drew outside its box at %d, %d", column, row)
		}
	}
	// A thickness past the half of the box fills the ellipse; a box of one
	// pixel is one pixel.
	picture_clear(&picture)
	ellipse_draw(&picture, 0, 0, 20, 20, max(int), 0x00FF00)
	testing.expect_value(t, pixel_at(&picture, 10, 10), graphics.Color(0x00FF00))
	picture_clear(&picture)
	box = ellipse_draw(&picture, 5, 5, 5, 5, 1, 0x00FF00)
	testing.expect_value(t, box, Box{5, 5, 6, 6})
	testing.expect_value(t, pixel_at(&picture, 5, 5), graphics.Color(0x00FF00))
}

@(private = "file")
fill_test_grow :: proc "contextless" (memory: ^Fill_Memory, wanted: int) -> bool {
	context = runtime.default_context()
	spans := make([]Fill_Span, max(2 * wanted, 16), runtime.heap_allocator())
	copy(spans, memory.spans)
	delete(memory.spans, runtime.heap_allocator())
	memory.spans = spans
	return true
}

// fill_test_memory gives a fill a stack that grows from the heap.
@(private = "file")
fill_test_memory :: proc() -> ^Fill_Memory {
	memory := new(Fill_Memory)
	memory.grow = fill_test_grow
	return memory
}

@(private = "file")
fill_test_memory_free :: proc(memory: ^Fill_Memory) {
	delete(memory.spans, runtime.heap_allocator())
	free(memory)
}

// flood_reference paints a region pixel by pixel, with a queue of every
// pixel: slow and plain, the answer that the span fill must give.
@(private = "file")
flood_reference :: proc(picture: ^Picture, x, y: int, color: graphics.Color) {
	target := pixel_at(picture, x, y)
	if target == color {
		return
	}
	queue := make([dynamic][2]int)
	defer delete(queue)
	append(&queue, [2]int{x, y})
	picture.pixels[y * picture.width + x] = color
	for head := 0; head < len(queue); head += 1 {
		point := queue[head]
		for step in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			next := [2]int{point[0] + step[0], point[1] + step[1]}
			if next[0] < 0 || next[1] < 0 || next[0] >= picture.width || next[1] >= picture.height || pixel_at(picture, next[0], next[1]) != target {
				continue
			}
			picture.pixels[next[1] * picture.width + next[0]] = color
			append(&queue, next)
		}
	}
}

// A fill outside the picture, and a fill of a region that has the color,
// change nothing; a fill stops at the edges of its region, and leaves the
// generation of the picture to its caller.
@(test)
a_fill_stays_in_its_region :: proc(t: ^testing.T) {
	picture := picture_make(64, 64)
	defer delete(picture.pixels)
	memory := fill_test_memory()
	defer fill_test_memory_free(memory)
	generation := picture.generation
	for point in ([][2]int{{-1, 0}, {0, -1}, {64, 0}, {0, 64}, {max(int), 0}, {min(int), min(int)}}) {
		box, outcome := fill_region(&picture, point[0], point[1], 0, memory)
		testing.expectf(t, box_empty(box) && outcome == .Done, "the point %v is refused", point)
	}
	box, outcome := fill_region(&picture, 3, 3, COLOR_PAPER, memory)
	testing.expect(t, box_empty(box) && outcome == .Done)
	rectangle_draw(&picture, 10, 10, 30, 30, 1, 0x000000)
	generation = picture.generation
	box, outcome = fill_region(&picture, 20, 20, 0xFF0000, memory)
	testing.expect_value(t, outcome, Fill_Outcome.Done)
	testing.expect_value(t, box, Box{11, 11, 30, 30})
	testing.expect_value(t, memory.painted, 19 * 19)
	testing.expect_value(t, picture.generation, generation)
	testing.expect_value(t, pixel_at(&picture, 11, 11), graphics.Color(0xFF0000))
	testing.expect_value(t, pixel_at(&picture, 10, 10), graphics.Color(0x000000))
	testing.expect_value(t, pixel_at(&picture, 5, 5), COLOR_PAPER)
	// A picture of one pixel, and a region of one pixel at each corner.
	one := picture_make(1, 1)
	defer delete(one.pixels)
	box, outcome = fill_region(&one, 0, 0, 0x123456, memory)
	testing.expect(t, box == Box{0, 0, 1, 1} && outcome == .Done && pixel_at(&one, 0, 0) == 0x123456)
}

// The span fill paints what a plain flood of each pixel paints, on random
// pictures of three colors, from each kind of seed: the runs that leak
// past their parent on the left and on the right, the edges, the holes.
@(test)
a_fill_paints_the_region_of_a_flood :: proc(t: ^testing.T) {
	WIDTH :: 61
	HEIGHT :: 47
	memory := fill_test_memory()
	defer fill_test_memory_free(memory)
	picture := picture_make(WIDTH, HEIGHT)
	defer delete(picture.pixels)
	expected := picture_make(WIDTH, HEIGHT)
	defer delete(expected.pixels)
	state := u32(12345)
	for round in 0 ..< 200 {
		// Fewer walls in some rounds: large regions with many leaks.
		walls := u32(round % 4 + 1)
		for &pixel in picture.pixels {
			state = state * 1_664_525 + 1_013_904_223
			pixel = (state >> 16) % 8 < walls ? graphics.Color((state >> 8) % 2 + 1) : COLOR_PAPER
		}
		copy(expected.pixels, picture.pixels)
		state = state * 1_664_525 + 1_013_904_223
		x, y := int(state >> 8) % WIDTH, int(state >> 20) % HEIGHT
		flood_reference(&expected, x, y, 0xABCDEF)
		_, outcome := fill_region(&picture, x, y, 0xABCDEF, memory)
		testing.expect_value(t, outcome, Fill_Outcome.Done)
		same := string(transmute([]u8)picture.pixels) == string(transmute([]u8)expected.pixels)
		testing.expectf(t, same, "round %d from (%d, %d): the fill differs from the flood", round, x, y)
		if !same {
			break
		}
	}
}

// A maze of walls at each odd pixel of each odd row is filled whole: its
// stack grows past the 16384 seeds of the fixed stack of before.
@(test)
a_fill_of_a_maze_grows_its_stack :: proc(t: ^testing.T) {
	WIDTH :: 512
	HEIGHT :: 512
	picture := picture_make(WIDTH, HEIGHT)
	defer delete(picture.pixels)
	memory := fill_test_memory()
	defer fill_test_memory_free(memory)
	WALL :: graphics.Color(0x000000)
	for row := 1; row < HEIGHT; row += 2 {
		for column := 1; column < WIDTH; column += 2 {
			picture.pixels[row * WIDTH + column] = WALL
		}
	}
	box, outcome := fill_region(&picture, 0, 0, 0xFF0000, memory)
	testing.expect_value(t, outcome, Fill_Outcome.Done)
	testing.expect_value(t, box, Box{0, 0, WIDTH, HEIGHT})
	left := 0
	for row in 0 ..< HEIGHT {
		for column in 0 ..< WIDTH {
			wall := row % 2 == 1 && column % 2 == 1
			left += !wall && pixel_at(&picture, column, row) != 0xFF0000 ? 1 : 0
		}
	}
	testing.expect_value(t, left, 0)
	testing.expect_value(t, memory.painted, WIDTH * HEIGHT - (WIDTH / 2) * (HEIGHT / 2))
}

// A stack that cannot grow stops the fill with No_Memory, and the box of
// what it painted; that box from the copy gives the picture back.
@(test)
a_fill_whose_stack_cannot_grow_stops :: proc(t: ^testing.T) {
	WIDTH :: 64
	picture := picture_make(WIDTH, WIDTH)
	defer delete(picture.pixels)
	for row := 1; row < WIDTH; row += 2 {
		for column := 1; column < WIDTH; column += 2 {
			picture.pixels[row * WIDTH + column] = 0
		}
	}
	before := make([]graphics.Color, WIDTH * WIDTH)
	defer delete(before)
	copy(before, picture.pixels)
	spans: [3]Fill_Span
	memory := Fill_Memory{spans = spans[:]}
	box, outcome := fill_region(&picture, 0, 0, 0xFF0000, &memory)
	testing.expect_value(t, outcome, Fill_Outcome.No_Memory)
	testing.expect(t, !box_empty(box), "a part was painted")
	picture_box_restore(&picture, before, box)
	testing.expect(t, string(transmute([]u8)picture.pixels) == string(transmute([]u8)before), "the box from the copy gives the picture back")
	// No room for the two first spans: nothing is painted.
	none := Fill_Memory{}
	box, outcome = fill_region(&picture, 0, 0, 0xFF0000, &none)
	testing.expect(t, box_empty(box) && outcome == .No_Memory)
	// A box past the picture is cut to it.
	picture_box_restore(&picture, before, {-5, -5, WIDTH + 5, WIDTH + 5})
}

@(private = "file")
cancelling_grow :: proc "contextless" (memory: ^Fill_Memory, wanted: int) -> bool {
	// The window asks to cancel while the fill runs: here, at the first
	// growth past the first 16 spans.
	if wanted > 16 {
		intrinsics.atomic_store(&memory.cancel, true)
	}
	return fill_test_grow(memory, wanted)
}

// A cancel stops the fill at its next span; the box from the copy gives
// the picture back. A record that is cancelled keeps no step, and the
// steps before it stay.
@(test)
a_cancel_stops_a_fill_and_a_record :: proc(t: ^testing.T) {
	WIDTH :: 64
	picture := picture_make(WIDTH, WIDTH)
	defer delete(picture.pixels)
	// A maze, so the stack grows while the fill runs.
	for row := 1; row < WIDTH; row += 2 {
		for column := 1; column < WIDTH; column += 2 {
			picture.pixels[row * WIDTH + column] = 0
		}
	}
	before := make([]graphics.Color, WIDTH * WIDTH)
	defer delete(before)
	copy(before, picture.pixels)
	memory := new(Fill_Memory)
	defer fill_test_memory_free(memory)
	memory.grow = cancelling_grow
	box, outcome := fill_region(&picture, 30, 30, 0xFF0000, memory)
	testing.expect_value(t, outcome, Fill_Outcome.Cancelled)
	testing.expect(t, !box_empty(box) && memory.painted < WIDTH * WIDTH, "a part was painted")
	picture_box_restore(&picture, before, box)
	testing.expect(t, string(transmute([]u8)picture.pixels) == string(transmute([]u8)before))
	// A cancel asked before the fill paints nothing.
	box, outcome = fill_region(&picture, 30, 30, 0xFF0000, memory)
	testing.expect(t, box_empty(box) && outcome == .Cancelled)
	memory.cancel = false

	bound := WIDTH * WIDTH * size_of(graphics.Color)
	history := History{ring = make([]u8, bound)}
	defer delete(history.ring)
	scratch := new(History_Scratch)
	defer free(scratch)
	copy(before, picture.pixels)
	first := segment_draw(&picture, 5, 0, 5, 63, 1, 0x00FF00)
	testing.expect_value(t, history_record(&history, before, picture.pixels, WIDTH, first, bound, scratch), Record_Outcome.Kept)
	testing.expect_value(t, scratch.strips_done, history_record_strips(first))
	copy(before, picture.pixels)
	second := segment_draw(&picture, 9, 0, 9, 63, 1, 0x0000FF)
	scratch.cancel = true
	testing.expect_value(t, history_record(&history, before, picture.pixels, WIDTH, second, bound, scratch), Record_Outcome.Cancelled)
	scratch.cancel = false
	testing.expect_value(t, history.count, 1)
	picture_box_restore(&picture, before, second)
	undone_box, undone := history_undo(&history, &picture, scratch)
	testing.expect(t, undone && undone_box == first, "the step before the cancel undoes")
	testing.expect_value(t, pixel_at(&picture, 5, 10), COLOR_PAPER)
	testing.expect_value(t, pixel_at(&picture, 9, 10), COLOR_PAPER)
}

@(private = "file")
History_Test :: struct {
	picture: Picture,
	before:  []graphics.Color,
	history: History,
	bound:   int, // The bytes that the ring may hold.
	scratch: ^History_Scratch,
}

// history_test_make gives a picture of 200 x 100 and a fixed ring of bound
// bytes: by default one copy of the picture, the bound of the window.
@(private = "file")
history_test_make :: proc(bound := 200 * 100 * 4) -> History_Test {
	test := History_Test{picture = picture_make(200, 100, room = 300 * 120), before = make([]graphics.Color, 300 * 120), bound = bound, scratch = new(History_Scratch)}
	test.history.ring = make([]u8, bound)
	copy(test.before, test.picture.pixels)
	return test
}

@(private = "file")
history_test_free :: proc(test: ^History_Test) {
	delete(test.picture.pixels)
	delete(test.before)
	delete(test.history.ring)
	free(test.scratch)
}

// history_test_change draws a segment as the window does: a copy before,
// the change, then the record of its box.
@(private = "file")
history_test_change :: proc(test: ^History_Test, x: int, color: graphics.Color) -> Record_Outcome {
	copy(test.before, test.picture.pixels)
	box := segment_draw(&test.picture, x, 0, x, 99, 1, color)
	return history_record(&test.history, test.before, test.picture.pixels, test.picture.width, box, test.bound, test.scratch)
}

@(private = "file")
undo :: proc(test: ^History_Test) -> bool {
	_, ok := history_undo(&test.history, &test.picture, test.scratch)
	return ok
}

@(private = "file")
redo :: proc(test: ^History_Test) -> bool {
	_, ok := history_redo(&test.history, &test.picture, test.scratch)
	return ok
}

// noise_fill writes pixels that LZ4 does not compress into a box.
@(private = "file")
noise_fill :: proc(picture: ^Picture, box: Box, seed: u32) {
	state := seed
	for row in box.top ..< box.bottom {
		for column in box.left ..< box.right {
			state = state * 1_664_525 + 1_013_904_223
			picture.pixels[row * picture.width + column] = state >> 8
		}
	}
}

// With no step, undo and redo are refused and change nothing; an empty
// box is not kept. With one step, undo puts back the pixels before and
// gives the box, redo the pixels after; a new change removes what redo
// would give.
@(test)
undo_and_redo_put_back_the_pixels :: proc(t: ^testing.T) {
	test := history_test_make()
	defer history_test_free(&test)
	generation := test.picture.generation
	testing.expect(t, !undo(&test) && !redo(&test), "no step: nothing to undo or redo")
	testing.expect_value(t, test.picture.generation, generation)
	testing.expect_value(t, history_record(&test.history, test.before, test.picture.pixels, test.picture.width, {}, test.bound, test.scratch), Record_Outcome.Empty)
	testing.expect_value(t, test.history.count, 0)
	// One step.
	testing.expect_value(t, history_test_change(&test, 10, 0xFF0000), Record_Outcome.Kept)
	testing.expect_value(t, test.history.count, 1)
	testing.expect(t, !redo(&test), "one applied step: nothing to redo")
	box, undone := history_undo(&test.history, &test.picture, test.scratch)
	testing.expect(t, undone && box == Box{10, 0, 11, 100}, "undo gives the box of its step")
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), COLOR_PAPER)
	testing.expect(t, !undo(&test), "one step undone: nothing to undo")
	testing.expect(t, redo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
	testing.expect(t, undo(&test) && redo(&test), "the one step undoes again")
	// Two steps.
	testing.expect_value(t, history_test_change(&test, 20, 0x00FF00), Record_Outcome.Kept)
	testing.expect(t, undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 20, 50), COLOR_PAPER)
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
	testing.expect(t, undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), COLOR_PAPER)
	testing.expect(t, !undo(&test))
	testing.expect(t, redo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
	testing.expect(t, history_can_redo(&test.history))
	testing.expect_value(t, history_test_change(&test, 30, 0x0000FF), Record_Outcome.Kept)
	testing.expect(t, !history_can_redo(&test.history), "a new change removes what redo would give")
	testing.expect_value(t, test.history.count, 2)
	// A new change after each step is undone removes them all.
	testing.expect(t, undo(&test) && undo(&test) && !undo(&test))
	testing.expect_value(t, history_test_change(&test, 40, 0x0000FF), Record_Outcome.Kept)
	testing.expect_value(t, test.history.count, 1)
	testing.expect(t, undo(&test) && !undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 40, 50), COLOR_PAPER)
}

// No count of steps: in one copy of the picture, 300 small steps are each
// kept, past the 64 of before.
@(test)
the_history_has_no_count_of_steps :: proc(t: ^testing.T) {
	test := history_test_make()
	defer history_test_free(&test)
	for index in 0 ..< 300 {
		testing.expect_value(t, history_test_change(&test, index % 200, graphics.Color(index + 1)), Record_Outcome.Kept)
	}
	testing.expect_value(t, test.history.count, 300)
	undone := 0
	for undo(&test) {
		undone += 1
	}
	testing.expect_value(t, undone, 300)
	for row in ([?]int{0, 50, 99}) {
		for column in 0 ..< 200 {
			testing.expect_value(t, pixel_at(&test.picture, column, row), COLOR_PAPER)
		}
	}
}

// At the bound, the oldest steps go and the others undo in their order,
// across the end of the ring many times: after the steps that undo gives,
// the picture is the one after the step before them. The ring never
// passes the bound.
@(test)
the_oldest_steps_drop_at_the_bound :: proc(t: ^testing.T) {
	STEPS :: 150
	test := history_test_make(bound = 2048)
	defer history_test_free(&test)
	snapshots := make([][]graphics.Color, STEPS + 1)
	defer {
		for snapshot in snapshots {
			delete(snapshot)
		}
		delete(snapshots)
	}
	snapshots[0] = make([]graphics.Color, 200 * 100)
	copy(snapshots[0], test.picture.pixels[:200 * 100])
	wraps := 0
	for index in 0 ..< STEPS {
		// Steps of several sizes: a column, or a band of noise.
		outcome: Record_Outcome
		if index % 7 == 3 {
			copy(test.before, test.picture.pixels)
			box := Box{(index * 13) % 190, 10, (index * 13) % 190 + 6, 13}
			noise_fill(&test.picture, box, u32(index))
			outcome = history_record(&test.history, test.before, test.picture.pixels, test.picture.width, box, test.bound, test.scratch)
		} else {
			outcome = history_test_change(&test, (index * 7) % 200, graphics.Color(index + 1))
		}
		testing.expect_value(t, outcome, Record_Outcome.Kept)
		testing.expect(t, !test.history.in_copy, "each step fits the ring")
		testing.expect_value(t, len(test.history.ring), 2048)
		if test.history.newest == 0 && test.history.count > 1 {
			wraps += 1
		}
		snapshots[index + 1] = make([]graphics.Color, 200 * 100)
		copy(snapshots[index + 1], test.picture.pixels[:200 * 100])
	}
	kept := test.history.count
	testing.expect(t, kept > 1 && kept < STEPS, "the oldest steps went for the room")
	testing.expect(t, wraps > 3, "the steps went across the end of the ring several times")
	for undone in 1 ..= kept {
		testing.expect(t, undo(&test))
		testing.expectf(t, string(transmute([]u8)test.picture.pixels[:200 * 100]) == string(transmute([]u8)snapshots[STEPS - undone]), "after %d undos", undone)
	}
	testing.expect(t, !undo(&test), "the steps that went do not undo")
	for redone in 1 ..= kept {
		testing.expect(t, redo(&test))
		testing.expectf(t, string(transmute([]u8)test.picture.pixels[:200 * 100]) == string(transmute([]u8)snapshots[STEPS - kept + redone]), "after %d redos", redone)
	}
	testing.expect(t, !redo(&test))
}

// A change larger than the bound is the one step of the history, in the
// copy before it: undo and redo exchange its box; a small step after it
// takes the ring again; a reuse of the copy drops it.
@(test)
a_change_larger_than_the_bound_is_kept_in_the_copy :: proc(t: ^testing.T) {
	test := history_test_make(bound = 4096)
	defer history_test_free(&test)
	testing.expect_value(t, history_test_change(&test, 10, 0xFF0000), Record_Outcome.Kept)
	copy(test.before, test.picture.pixels)
	whole := Box{0, 0, 200, 100}
	noise_fill(&test.picture, whole, 1)
	after := make([]graphics.Color, 200 * 100)
	defer delete(after)
	copy(after, test.picture.pixels[:200 * 100])
	testing.expect_value(t, history_record(&test.history, test.before, test.picture.pixels, test.picture.width, whole, test.bound, test.scratch), Record_Outcome.Kept)
	testing.expect(t, test.history.in_copy && test.history.count == 1, "the one step, in the copy")
	box, undone := history_undo(&test.history, &test.picture, test.scratch)
	testing.expect(t, undone && box == whole)
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
	testing.expect_value(t, pixel_at(&test.picture, 11, 50), COLOR_PAPER)
	testing.expect(t, !undo(&test), "the step before it went")
	testing.expect(t, redo(&test))
	testing.expect(t, string(transmute([]u8)test.picture.pixels[:200 * 100]) == string(transmute([]u8)after), "redo gives the change whole")
	testing.expect(t, undo(&test) && redo(&test), "it undoes again")
	// A picture of another width refuses the exchange.
	test.picture.width = 199
	testing.expect(t, !undo(&test))
	test.picture.width = 200
	// A small step after it is kept in the ring.
	testing.expect_value(t, history_test_change(&test, 20, 0x00FF00), Record_Outcome.Kept)
	testing.expect(t, !test.history.in_copy && test.history.count == 1)
	// The copy serves again: the step in it goes.
	copy(test.before, test.picture.pixels)
	noise_fill(&test.picture, whole, 2)
	testing.expect_value(t, history_record(&test.history, test.before, test.picture.pixels, test.picture.width, whole, test.bound, test.scratch), Record_Outcome.Kept)
	history_copy_reused(&test.history)
	testing.expect(t, !history_can_undo(&test.history) && !history_can_redo(&test.history))
	// A box outside the memory is refused, and clears the history.
	testing.expect_value(t, history_test_change(&test, 30, 0x0000FF), Record_Outcome.Kept)
	testing.expect_value(t, history_record(&test.history, test.before, test.picture.pixels, test.picture.width, {0, 0, 201, 1}, test.bound, test.scratch), Record_Outcome.Refused)
	testing.expect(t, !history_can_undo(&test.history))
	// A history history_copy_reused with no step in the copy keeps its steps.
	testing.expect_value(t, history_test_change(&test, 40, 0x0000FF), Record_Outcome.Kept)
	history_copy_reused(&test.history)
	testing.expect(t, history_can_undo(&test.history))
}

@(private = "file")
refused_grow :: proc "contextless" (history: ^History, wanted: int) -> bool {
	return false
}

// A budget that does not pay the growth of the ring bounds it at what it
// holds: with no byte, each change is the one step in the copy, and still
// undoes.
@(test)
a_ring_that_cannot_grow_keeps_the_step_in_the_copy :: proc(t: ^testing.T) {
	test := history_test_make(bound = 0)
	defer history_test_free(&test)
	test.bound = 200 * 100 * 4
	test.history.grow = refused_grow
	testing.expect_value(t, history_test_change(&test, 10, 0xFF0000), Record_Outcome.Kept)
	testing.expect(t, test.history.in_copy)
	testing.expect(t, undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), COLOR_PAPER)
}

// A damaged block is refused, and the picture and the history stay.
@(test)
a_damaged_step_changes_nothing :: proc(t: ^testing.T) {
	test := history_test_make()
	defer history_test_free(&test)
	history_test_change(&test, 10, 0xFF0000)
	head := history_head(&test.history, test.history.applied)
	step := head^
	// A block of the wrong size: the box asks for more pixels.
	head.box.bottom += 1
	generation := test.picture.generation
	testing.expect(t, !undo(&test))
	testing.expect_value(t, test.picture.generation, generation)
	testing.expect_value(t, test.history.done, 1)
	// A box outside the extent.
	head^ = step
	head.box.right = test.picture.width + 1
	testing.expect(t, !undo(&test))
	// Bytes that are no LZ4 block: a literal length past the block.
	head^ = step
	blocks := test.history.applied + size_of(History_Head) + HISTORY_BLOCK_HEAD_BYTES
	test.history.ring[blocks] = 0xF0
	test.history.ring[blocks + 1] = 0xFF
	testing.expect(t, !undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
}

// A file of a picture reads back as the same picture; each damaged field
// is refused with its problem, and the picture stays as it was.
@(test)
the_picture_file_refuses_each_damaged_field :: proc(t: ^testing.T) {
	picture := picture_make(40, 30)
	defer delete(picture.pixels)
	ROW :: 40 * 4
	file := make([]u8, FILE_HEADER_BYTES + 31 * ROW)
	defer delete(file)
	_, refused := picture_encode(&picture, file[:FILE_HEADER_BYTES + 30 * ROW - 1])
	testing.expect(t, !refused, "a buffer too small is refused")
	empty := Picture{pixels = picture.pixels}
	_, refused = picture_encode(&empty, file)
	testing.expect(t, !refused, "an empty extent is refused")
	segment_draw(&picture, 0, 0, 39, 29, 2, 0x336699)
	encoded, ok := picture_encode(&picture, file)
	testing.expect(t, ok)
	testing.expect_value(t, len(encoded), FILE_HEADER_BYTES + 30 * ROW)
	// The good file, apart from the buffer that each case damages.
	bytes := make([]u8, len(encoded))
	defer delete(bytes)
	copy(bytes, encoded)
	other := picture_make(10, 10, room = 40 * 30)
	defer delete(other.pixels)
	other.pixels[0] = 0xABCDEF
	cases := []struct {
		offset:  int,
		value:   u8,
		length:  int,
		problem: File_Problem,
	} {
		{-1, 0, 0, .Too_Short},
		{-1, 0, FILE_HEADER_BYTES - 1, .Too_Short},
		{0, 'X', -1, .Bad_Magic},
		{4, 0, -1, .Bad_Version},
		{4, 3, -1, .Bad_Version}, // The two slots of rows of one width of before.
		{4, 5, -1, .Bad_Version},
		{7, 0xFF, -1, .Bad_Version},
		{8, 0, -1, .Bad_Size}, // The width 0: the low byte of 40 is 40, and the others are 0.
		{10, 0x01, -1, .Bad_Size}, // A width of 40 + 65536, past the largest side.
		{11, 0xFF, -1, .Bad_Size},
		{12, 0, -1, .Bad_Size}, // The height 0.
		{16, 0, -1, .Bad_Offset}, // The rows in the header.
		{16, 25, -1, .Bad_Offset}, // A place that is not a multiple of 4.
		{19, 0xFF, -1, .Bad_Offset}, // A place past FILE_ROWS_OFFSET_LIMIT.
		{20, 1, -1, .Bad_Offset}, // A place past 32 bits.
		{23, 0x80, -1, .Bad_Offset},
		{16, 28, -1, .Bad_Length}, // Rows 4 bytes later end past the file.
		{12, 31, -1, .Bad_Length}, // The height 31 with the rows of 30.
		{-1, 0, len(bytes) - 1, .Bad_Length},
		{FILE_HEADER_BYTES + 3, 0x01, -1, .Bad_Pixel}, // The top byte of the first pixel.
		{len(bytes) - 1, 0xFF, -1, .Bad_Pixel}, // The top byte of the last pixel.
	}
	for test_case in cases {
		copy(file, bytes)
		damaged := file[:len(bytes)]
		if test_case.offset >= 0 {
			damaged[test_case.offset] = test_case.value
		}
		if test_case.length >= 0 {
			damaged = damaged[:test_case.length]
		}
		generation := other.generation
		testing.expectf(t, picture_decode(damaged, &other) == test_case.problem, "the case %v", test_case)
		testing.expect(t, other.generation == generation && other.width == 10 && other.pixels[0] == 0xABCDEF)
	}
	// A memory of the picture one pixel short of the file.
	small := picture_make(10, 10, room = 40 * 30 - 1)
	defer delete(small.pixels)
	testing.expect_value(t, picture_decode(bytes, &small), File_Problem.Too_Large)
	testing.expect(t, small.width == 10 && small.height == 10)
	testing.expect_value(t, picture_decode(bytes, &other), File_Problem.None)
	testing.expect(t, other.width == 40 && other.height == 30)
	for row in 0 ..< 30 {
		for column in 0 ..< 40 {
			testing.expect_value(t, pixel_at(&other, column, row), pixel_at(&picture, column, row))
		}
	}
	// The rows at another place of the file: the header names it.
	moved := make([]u8, FILE_HEADER_BYTES + 32 + 30 * ROW)
	defer delete(moved)
	header, header_ok := file_header_write(40, 30, FILE_HEADER_BYTES + 32, moved)
	testing.expect(t, header_ok && len(header) == FILE_HEADER_BYTES)
	copy(moved[FILE_HEADER_BYTES + 32:], bytes[FILE_HEADER_BYTES:])
	testing.expect_value(t, picture_decode(moved, &other), File_Problem.None)
	testing.expect_value(t, pixel_at(&other, 39, 29), pixel_at(&picture, 39, 29))
	// A file longer than its rows: a height 29 reads 29 rows.
	copy(file, bytes)
	file[12] = 29
	testing.expect_value(t, picture_decode(file[:len(bytes) + 1], &other), File_Problem.None)
	testing.expect(t, other.width == 40 && other.height == 29)
	// A picture wider than 4096, past each side of a screen, reads back.
	wide := picture_make(6000, 2)
	defer delete(wide.pixels)
	segment_draw(&wide, 5999, 1, 5999, 1, 1, 0x010203)
	wide_file := make([]u8, FILE_HEADER_BYTES + 6000 * 2 * 4)
	defer delete(wide_file)
	whole, whole_ok := picture_encode(&wide, wide_file)
	testing.expect(t, whole_ok)
	back := picture_make(1, 1, room = 6000 * 2)
	defer delete(back.pixels)
	testing.expect_value(t, picture_decode(whole, &back), File_Problem.None)
	testing.expect(t, back.width == 6000 && back.height == 2)
	testing.expect_value(t, pixel_at(&back, 5999, 1), graphics.Color(0x010203))
}

// The rows of a keep are at one place of the file: the band that a keep
// writes reads back into the file as a whole encode gives it.
@(test)
the_rows_of_a_keep_are_the_rows_of_the_file :: proc(t: ^testing.T) {
	picture := picture_make(100, 50)
	defer delete(picture.pixels)
	ROW :: 100 * 4
	file := make([]u8, FILE_HEADER_BYTES + 50 * ROW)
	defer delete(file)
	band := make([]u8, 50 * ROW)
	defer delete(band)
	for refused in ([][2]int{{-1, 3}, {0, 0}, {5, 4}, {0, 51}, {50, 51}}) {
		_, ok := file_rows_copy(&picture, refused[0], refused[1], band)
		testing.expectf(t, !ok, "the rows %v are refused", refused)
	}
	_, small := file_rows_copy(&picture, 0, 2, band[:2 * ROW - 1])
	testing.expect(t, !small, "a buffer too small is refused")
	box := segment_draw(&picture, 10, 20, 90, 24, 3, 0x112233)
	rows, ok := file_rows_copy(&picture, box.top, box.bottom, band)
	testing.expect(t, ok)
	whole, _ := picture_encode(&picture, file)
	testing.expect(t, string(whole[FILE_HEADER_BYTES + box.top * ROW:][:len(rows)]) == string(rows))
	testing.expect_value(t, file_row_bytes(100), ROW)
	for refused in ([][3]int{{0, 0, FILE_HEADER_BYTES}, {10, 0, FILE_HEADER_BYTES}, {10, 10, 0}, {10, 10, FILE_HEADER_BYTES - 4}, {10, 10, FILE_HEADER_BYTES + 1}, {10, 10, FILE_ROWS_OFFSET_LIMIT + 4}, {PICTURE_SIDE_LIMIT + 1, 10, FILE_HEADER_BYTES}}) {
		_, header_ok := file_header_write(refused[0], refused[1], refused[2], file)
		testing.expectf(t, !header_ok, "the header %v is refused", refused)
	}
	_, edge_ok := file_header_write(PICTURE_SIDE_LIMIT, 1, FILE_ROWS_OFFSET_LIMIT, file)
	testing.expect(t, edge_ok, "the largest side and the farthest place are taken")
}

// The band of changed rows: an empty box adds nothing, a keep is due only
// after the pause, a time before the last change is no pause, and the
// first keep of a new object writes all its rows.
@(test)
the_band_of_changed_rows_and_the_pause :: proc(t: ^testing.T) {
	rows: Changed_Rows
	changed_rows_add(&rows, {}, 100)
	testing.expect(t, !rows.changed && !keep_due(&rows, max(u64)))
	changed_rows_add(&rows, {0, 10, 5, 12}, 1000)
	changed_rows_add(&rows, {0, 3, 5, 4}, 1500)
	testing.expect(t, rows.top == 3 && rows.bottom == 12)
	testing.expect(t, !keep_due(&rows, 1500 + KEEP_PAUSE_MILLISECONDS - 1))
	testing.expect(t, !keep_due(&rows, 0), "a time before the last change is no pause")
	testing.expect(t, keep_due(&rows, 1500 + KEEP_PAUSE_MILLISECONDS))
	top, bottom := keep_band(&rows, 8)
	testing.expect(t, top == 3 && bottom == 8, "the band is cut to the height")
	rows.whole = true
	top, bottom = keep_band(&rows, 40)
	testing.expect(t, top == 0 && bottom == 40)
	keep_taken(&rows)
	testing.expect(t, !rows.changed && !rows.whole && !keep_due(&rows, max(u64)))
	// A change of the header alone: a keep with no rows.
	changed_rows_mark(&rows, 5000)
	top, bottom = keep_band(&rows, 40)
	testing.expect(t, keep_due(&rows, 5000 + KEEP_PAUSE_MILLISECONDS) && top == bottom)
}

// The picture cannot be replaced, undone or cleared during a drag.
@(test)
no_replace_of_the_picture_during_a_drag :: proc(t: ^testing.T) {
	drag: Drag
	testing.expect(t, picture_replace_allowed(&drag))
	drag = {active = true}
	testing.expect(t, !picture_replace_allowed(&drag), "a read taken during a drag would undo old pixels into the new picture")
	drag.active = false
	testing.expect(t, picture_replace_allowed(&drag))
}

// A step that fills the ring exactly is kept, and the next one drops it
// with no read past the ring; one byte less keeps it in the copy.
@(test)
a_step_that_fills_the_ring_exactly :: proc(t: ^testing.T) {
	measure := history_test_make()
	testing.expect_value(t, history_test_change(&measure, 10, 0xFF0000), Record_Outcome.Kept)
	head := history_head(&measure.history, measure.history.newest)
	exact := step_bytes(head.before_bytes, head.after_bytes)
	history_test_free(&measure)
	test := history_test_make(bound = exact)
	defer history_test_free(&test)
	testing.expect_value(t, history_test_change(&test, 10, 0xFF0000), Record_Outcome.Kept)
	testing.expect(t, !test.history.in_copy)
	testing.expect_value(t, history_test_change(&test, 10, 0x00FF00), Record_Outcome.Kept)
	testing.expect_value(t, test.history.count, 1)
	testing.expect(t, !test.history.in_copy)
	testing.expect(t, undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
	short := history_test_make(bound = exact - 1)
	defer history_test_free(&short)
	testing.expect_value(t, history_test_change(&short, 10, 0xFF0000), Record_Outcome.Kept)
	testing.expect(t, short.history.in_copy, "a step one byte past the bound is kept in the copy")
}

// An undo after the extent grew wider writes the pixels of its box at their
// row and column, in the rows of the new width; a step whose box is past
// the extent is damaged, and is refused.
@(test)
an_undo_after_a_wider_extent_keeps_its_pixels :: proc(t: ^testing.T) {
	test := history_test_make()
	defer history_test_free(&test)
	testing.expect_value(t, history_test_change(&test, 150, 0xFF0000), Record_Outcome.Kept)
	testing.expect_value(t, history_test_change(&test, 150, 0x00FF00), Record_Outcome.Kept)
	testing.expect_value(t, picture_extend(&test.picture, 300, 120), Extend_Outcome.Grown)
	testing.expect(t, undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 150, 50), graphics.Color(0xFF0000))
	testing.expect_value(t, pixel_at(&test.picture, 151, 50), COLOR_PAPER)
	testing.expect(t, undo(&test))
	testing.expect_value(t, pixel_at(&test.picture, 150, 50), COLOR_PAPER)
	testing.expect(t, redo(&test))
	// A box past the extent: the step is refused, and nothing changes.
	test.picture.height = 50
	generation := test.picture.generation
	testing.expect(t, !redo(&test))
	testing.expect_value(t, test.picture.generation, generation)
}

// The first free name skips the numbers that the store holds: the small
// ones one by one, then the one after the largest. A name that is not
// picture-N, or N with a zero first, marks nothing.
@(test)
the_first_free_name_of_a_picture :: proc(t: ^testing.T) {
	room: [NAME_LIMIT]u8
	numbers: Picture_Numbers
	name, ok := first_free_name(&numbers, &room)
	testing.expect(t, ok && name == "picture-1", "an empty store")
	for taken in ([?]string{"picture-1", "picture-3", "sky", "picture-02", "picture-", "picture-x", "picture-1000000000000000"}) {
		picture_number_mark(&numbers, taken)
	}
	name, ok = first_free_name(&numbers, &room)
	testing.expect(t, ok && name == "picture-2", "the first number not taken")
	testing.expect_value(t, numbers.largest, 3)
	// Each small number taken: the name after the largest, past the 1000
	// names that were the bound before.
	for number in 1 ..< PICTURE_NUMBERS_SMALL {
		picture_number_mark(&numbers, fmt.tprintf("picture-%d", number))
	}
	picture_number_mark(&numbers, "picture-5000")
	name, ok = first_free_name(&numbers, &room)
	testing.expect(t, ok && name == "picture-5001", name)
	testing.expect_value(t, name_check(name), Name_Problem.None)
	// The largest number of digits: the next has one more, which is refused.
	picture_number_mark(&numbers, "picture-999999999999999")
	_, ok = first_free_name(&numbers, &room)
	testing.expect(t, !ok, "a name past the digits of a number")
}

// A name is 1 to NAME_LIMIT bytes of lowercase letters, digits, "-" and
// "_"; an object is a picture only with a valid name and the suffix.
@(test)
the_names_of_the_pictures :: proc(t: ^testing.T) {
	// The longest name of the store, less the suffix: a name follows the
	// names of the store.
	testing.expect_value(t, NAME_LIMIT + len(OBJECT_SUFFIX), store.ENTRY_NAME_CAPACITY)
	long := strings.repeat("a", NAME_LIMIT, context.temp_allocator)
	testing.expect_value(t, name_check(""), Name_Problem.Empty)
	testing.expect_value(t, name_check(strings.repeat("a", NAME_LIMIT + 1, context.temp_allocator)), Name_Problem.Too_Long)
	for name in ([]string{"A", "a b", "a/b", ".", "a.picture", "é", "a\x00"}) {
		testing.expectf(t, name_check(name) == .Bad_Character, "%q is refused", name)
	}
	testing.expect_value(t, name_check(long), Name_Problem.None)
	testing.expect_value(t, name_check("my-picture_2"), Name_Problem.None)
	room: Object_Name
	_, ok := object_name(&room, "Bad")
	testing.expect(t, !ok)
	object: string
	object, ok = object_name(&room, long)
	testing.expect(t, ok && object == strings.concatenate({long, ".picture"}, context.temp_allocator))
	testing.expect_value(t, len(object), store.ENTRY_NAME_CAPACITY)
	too_long := strings.concatenate({long, "a.picture"}, context.temp_allocator)
	for refused in ([]string{"", ".picture", "x.pic", "A.picture", "a b.picture", "picture", too_long}) {
		_, found := picture_name_of_object(refused)
		testing.expectf(t, !found, "%q is no picture", refused)
	}
	name, found := picture_name_of_object("sky.picture")
	testing.expect(t, found && name == "sky")
}

// A color text is "#RRGGBB" or "RRGGBB"; each other text is refused. A
// channel stops at 0 and 255, and a size at the ends of its list.
@(test)
the_colors_and_the_sizes :: proc(t: ^testing.T) {
	for text in ([]string{"", "#", "#12345", "#1234567", "1234567", "#GG0000", "12345g", "##12345", " 123456"}) {
		_, ok := color_of_text(text)
		testing.expectf(t, !ok, "%q is refused", text)
	}
	color, ok := color_of_text("#a0B1c2")
	testing.expect(t, ok && color == 0xA0B1C2)
	color, ok = color_of_text("FFFFFF")
	testing.expect(t, ok && color == 0xFFFFFF)
	room: Color_Text
	testing.expect_value(t, color_text(&room, 0x0A0B0C), "#0A0B0C")
	testing.expect_value(t, color_text(&room, 0), "#000000")
	testing.expect_value(t, channel_step(0x102030, .Red, max(int)), graphics.Color(0xFF2030))
	testing.expect_value(t, channel_step(0x102030, .Green, min(int)), graphics.Color(0x100030))
	testing.expect_value(t, channel_step(0x102030, .Blue, 16), graphics.Color(0x102040))
	testing.expect_value(t, channel_set(0xFFFFFF, .Green, 0), graphics.Color(0xFF00FF))
	testing.expect_value(t, channel_value(0x123456, .Red), u8(0x12))
	testing.expect_value(t, size_index_step(0, -1), 0)
	testing.expect_value(t, size_index_step(0, min(int)), 0)
	testing.expect_value(t, size_index_step(len(BRUSH_SIZES) - 1, 1), len(BRUSH_SIZES) - 1)
	testing.expect_value(t, size_index_step(len(BRUSH_SIZES) - 1, max(int)), len(BRUSH_SIZES) - 1)
	testing.expect_value(t, size_index_step(max(int), 0), len(BRUSH_SIZES) - 1)
	testing.expect_value(t, size_index_step(2, 1), 3)
	testing.expect_value(t, len(PALETTE), len(PALETTE_NAMES))
}

// A keep waits for the store, for a name, and for the job that runs; the
// loop wakes for it only when a turn can then ask for it.
@(test)
a_keep_waits_for_the_store_a_name_and_the_job :: proc(t: ^testing.T) {
	state: Keep_State
	changed_rows_add(&state.rows, {0, 0, 10, 10}, 1000)
	due := u64(1000 + KEEP_PAUSE_MILLISECONDS)
	testing.expect_value(t, keep_step(&state, due, false, false), Keep_Step.Nothing)
	_, wake := keep_wake(&state, false)
	testing.expect(t, !wake, "no store: the loop does not wake for a keep")
	state.store_open = true
	testing.expect_value(t, keep_step(&state, due, false, false), Keep_Step.Nothing)
	_, wake = keep_wake(&state, false)
	testing.expect(t, !wake, "no name: the loop does not wake for a keep")
	state.named = true
	testing.expect_value(t, keep_step(&state, due - 1, false, false), Keep_Step.Nothing)
	testing.expect_value(t, keep_step(&state, due, true, false), Keep_Step.Nothing)
	_, wake = keep_wake(&state, true)
	testing.expect(t, !wake, "a job runs: its end wakes the loop")
	time: u64
	time, wake = keep_wake(&state, false)
	testing.expect(t, wake && time == due)
	testing.expect_value(t, keep_step(&state, due, false, false), Keep_Step.Keep)
	testing.expect_value(t, keep_step(&state, max(u64), false, false), Keep_Step.Keep)
}

// A refused keep drops the act that waits for it and waits before the
// next try: no keep at once, and no loop of tries.
@(test)
a_refused_keep_drops_its_act_and_waits :: proc(t: ^testing.T) {
	state := Keep_State{store_open = true, named = true}
	changed_rows_add(&state.rows, {0, 4, 10, 6}, 1000)
	testing.expect(t, pending_ask(&state, .Read))
	testing.expect(t, !pending_ask(&state, .New), "one act at a time")
	testing.expect_value(t, keep_step(&state, 1001, false, false), Keep_Step.Keep)
	keep_taken(&state.rows)
	dropped := keep_refused(&state, 1200, 50)
	testing.expect_value(t, dropped, Store_Pending.Read)
	testing.expect_value(t, state.pending, Store_Pending.None)
	state.started = true
	testing.expect(t, change_allowed(&state), "a dropped read lets the picture change again")
	testing.expect(t, state.rows.whole && state.rows.changed)
	testing.expect_value(t, keep_step(&state, 1200 + KEEP_PAUSE_MILLISECONDS, false, false), Keep_Step.Nothing)
	time, wake := keep_wake(&state, false)
	testing.expect(t, wake && time == 1200 + KEEP_RETRY_MILLISECONDS)
	testing.expect_value(t, keep_step(&state, 1200 + KEEP_RETRY_MILLISECONDS, false, false), Keep_Step.Keep)
}

// A delete does not wait for the keep: the store can be full, and the
// delete is what makes room.
@(test)
a_delete_waits_for_no_keep :: proc(t: ^testing.T) {
	state := Keep_State{store_open = true, named = true, retry_at = max(u64)}
	changed_rows_add(&state.rows, {0, 0, 10, 10}, 1000)
	testing.expect(t, pending_ask(&state, .Delete))
	testing.expect_value(t, keep_step(&state, 1001, false, false), Keep_Step.Pending)
	testing.expect_value(t, keep_step(&state, 1001, true, false), Keep_Step.Nothing)
}

// A new picture waits for the end of a stroke and for the keep; a read and
// a rename wait for the keep.
@(test)
a_new_picture_waits_for_the_stroke_and_the_keep :: proc(t: ^testing.T) {
	state := Keep_State{store_open = true, named = true}
	testing.expect(t, pending_ask(&state, .New))
	testing.expect_value(t, keep_step(&state, 0, false, true), Keep_Step.Nothing)
	testing.expect_value(t, keep_step(&state, 0, false, false), Keep_Step.Pending)
	changed_rows_add(&state.rows, {0, 0, 10, 10}, 1000)
	testing.expect_value(t, keep_step(&state, 1000, false, false), Keep_Step.Keep)
	keep_taken(&state.rows)
	testing.expect_value(t, keep_step(&state, 1000, false, true), Keep_Step.Nothing)
	testing.expect_value(t, keep_step(&state, 1000, false, false), Keep_Step.Pending)
	for act in ([]Store_Pending{.Read, .Rename}) {
		other := Keep_State{store_open = true, named = true}
		changed_rows_add(&other.rows, {0, 0, 10, 10}, 1000)
		testing.expect(t, pending_ask(&other, act))
		testing.expect_value(t, keep_step(&other, 1000, false, true), Keep_Step.Keep)
		keep_taken(&other.rows)
		testing.expect_value(t, keep_step(&other, 1000, false, false), Keep_Step.Pending)
	}
	closed: Keep_State
	testing.expect(t, !pending_ask(&closed, .Read), "no store: no act")
	testing.expect(t, !pending_ask(&state, .None))
}

// A picture with no name is never kept, and the loop never wakes for it;
// no change is allowed while a read runs.
@(test)
a_picture_with_no_name_and_a_read_in_flight :: proc(t: ^testing.T) {
	state := Keep_State{store_open = true}
	changed_rows_add(&state.rows, {0, 0, 10, 10}, 0)
	for now in ([]u64{0, KEEP_PAUSE_MILLISECONDS, max(u64)}) {
		testing.expect_value(t, keep_step(&state, now, false, false), Keep_Step.Nothing)
	}
	testing.expect(t, !change_allowed(&state), "before the first open is taken, a stroke would be replaced")
	state.started = true
	testing.expect(t, change_allowed(&state))
	testing.expect(t, pending_ask(&state, .Read))
	testing.expect(t, !change_allowed(&state), "a stroke from the ask of a read to its take would be lost")
	pending_started(&state)
	testing.expect(t, !change_allowed(&state), "the read runs")
	read_taken(&state)
	testing.expect(t, change_allowed(&state))
}

// A store in memory for the host tests of the keep: committed objects, the
// pending changes of the one connection, and the calls of the storage
// service that a keep makes.
@(private = "file")
Memory_Object :: struct {
	committed: [dynamic]u8,
	pending:   [dynamic]u8,
	changed:   bool, // The object has pending changes.
	exists:    bool, // A commit made it.
}

@(private = "file")
Memory_Store :: struct {
	objects: map[string]^Memory_Object,
}

@(private = "file")
memory_object :: proc(store: ^Memory_Store, name: string) -> ^Memory_Object {
	if object, found := store.objects[name]; found {
		return object
	}
	object := new(Memory_Object)
	store.objects[name] = object
	return object
}

@(private = "file")
memory_pending :: proc(object: ^Memory_Object) {
	if !object.changed {
		clear(&object.pending)
		append(&object.pending, ..object.committed[:])
		object.changed = true
	}
}

@(private = "file")
memory_write :: proc(store: ^Memory_Store, name: string, offset: int, data: []u8) {
	object := memory_object(store, name)
	memory_pending(object)
	if len(object.pending) < offset + len(data) {
		resize(&object.pending, offset + len(data))
	}
	copy(object.pending[offset:], data)
}

@(private = "file")
memory_set_size :: proc(store: ^Memory_Store, name: string, size: int) {
	object := memory_object(store, name)
	memory_pending(object)
	resize(&object.pending, size)
}

@(private = "file")
memory_commit :: proc(store: ^Memory_Store, name: string) {
	object := memory_object(store, name)
	if object.changed {
		clear(&object.committed)
		append(&object.committed, ..object.pending[:])
		object.changed = false
	}
	object.exists = true
}

@(private = "file")
memory_rename :: proc(store: ^Memory_Store, from, to: string) -> bool {
	if target, found := store.objects[to]; found && target.exists {
		return false // The storage service refuses a name that exists.
	}
	object := store.objects[from]
	delete_key(&store.objects, from)
	store.objects[to] = object
	return true
}

@(private = "file")
memory_store_free :: proc(store: ^Memory_Store) {
	for _, object in store.objects {
		delete(object.committed)
		delete(object.pending)
		free(object)
	}
	delete(store.objects)
}

// What a stop after a commit leaves: the picture that a reader opens.
@(private = "file")
Read_Outcome :: enum {
	Absent, // No object of the picture.
	Old,
	New,
	Other, // A whole valid picture that is neither: a stroke came during the keep.
	Damaged, // What a document never is (docs/PROPERTIES.md, "Persistence: no save action, and versions for all processes").
}

@(private = "file")
memory_remove :: proc(store: ^Memory_Store, name: string) {
	if object, found := store.objects[name]; found {
		delete(object.committed)
		delete(object.pending)
		free(object)
		delete_key(&store.objects, name)
	}
}

// memory_open does what the open of the store does to its objects: it
// removes each temporary object of a keep.
@(private = "file")
memory_open :: proc(store: ^Memory_Store) {
	partials: [dynamic]string
	defer delete(partials)
	for name in store.objects {
		if _, is_partial := partial_name_of_object(name); is_partial {
			append(&partials, name)
		}
	}
	for name in partials {
		memory_remove(store, name)
	}
}

@(private = "file")
memory_read :: proc(store: ^Memory_Store, old, new: ^Picture, scratch: ^Picture) -> Read_Outcome {
	object, found := store.objects["sky.picture"]
	if !found || !object.exists {
		return .Absent
	}
	if picture_decode(object.committed[:], scratch) != .None {
		return .Damaged
	}
	same :: proc(first, second: ^Picture) -> bool {
		if first.width != second.width || first.height != second.height {
			return false
		}
		count := first.width * first.height * 4
		return string(([^]u8)(raw_data(first.pixels))[:count]) == string(([^]u8)(raw_data(second.pixels))[:count])
	}
	if same(scratch, new) {
		return .New
	}
	if old != nil && same(scratch, old) {
		return .Old
	}
	return .Other
}

// memory_keep runs a whole keep of a picture on a store in memory, piece by
// piece as the job does, and reads the picture after each commit. It gives
// the outcomes, in their order. stroke_after_piece: after that piece, a
// stroke changes the picture, as a principal who draws while a keep runs.
// stop_after_commit: the process stops after that commit, with the keep
// unfinished.
@(private = "file")
memory_keep :: proc(t: ^testing.T, store: ^Memory_Store, state: ^Keep_State, picture, old: ^Picture, scratch: ^Picture, stroke_after_piece := -1, stop_after_commit := -1) -> (outcomes: [dynamic]Read_Outcome) {
	buffer := make([]u8, FILE_HEADER_BYTES + KEEP_PIECE_BYTES, context.temp_allocator)
	pixels := ([^]u8)(raw_data(picture.pixels))[:picture.width * picture.height * 4]
	keep_begin(state, picture.width, picture.height)
	for piece_index := 0; state.keeping; piece_index += 1 {
		piece := keep_piece(state)
		name := piece.object == .Partial ? "sky.partial" : "sky.picture"
		if piece.bytes > 0 {
			copy(buffer[FILE_HEADER_BYTES:], pixels[piece.row:][:piece.bytes])
			memory_write(store, name, piece.offset, buffer[FILE_HEADER_BYTES:][:piece.bytes])
		}
		if piece.header {
			header, ok := file_header_write(state.keep_width, state.keep_height, state.target_offset, buffer)
			testing.expect(t, ok)
			memory_write(store, name, 0, header)
			memory_set_size(store, name, piece.size)
		}
		if piece.commit {
			memory_commit(store, name)
			append(&outcomes, memory_read(store, old, picture, scratch))
			if len(outcomes) - 1 == stop_after_commit {
				return outcomes
			}
		}
		if piece.rename {
			testing.expect(t, memory_rename(store, "sky.partial", "sky.picture"))
			append(&outcomes, memory_read(store, old, picture, scratch))
		}
		keep_piece_written(state, piece)
		if piece_index == stroke_after_piece {
			// A stroke down the whole height: its top rows are written
			// already, its bottom rows not yet.
			segment_draw(picture, 7, 0, 7, picture.height - 1, 3, 0xFF0000)
			changed_rows_add(&state.rows, {5, 0, 10, picture.height}, 1000)
		}
	}
	return outcomes
}

// The pictures of the keep tests: a picture of 640 x 480 is 1.2 MB, past
// one commit, so a whole keep of it takes several commits.
@(private = "file")
KEEP_TEST_WIDTH :: 640
@(private = "file")
KEEP_TEST_HEIGHT :: 480
#assert(KEEP_TEST_WIDTH * KEEP_TEST_HEIGHT * 4 > KEEP_COMMIT_BYTES)

// Each commit of a keep holds one whole picture: a stop after any commit
// leaves the old picture or the new one, never a mix. The orders: the first
// keep of a large new picture (a temporary object and its rename), a large
// keep of the whole picture (the other slot, then the header), a keep of a
// few rows (one commit), and a second large keep that comes back to the
// first slot.
@(test)
each_commit_of_a_keep_holds_one_whole_picture :: proc(t: ^testing.T) {
	store: Memory_Store
	defer memory_store_free(&store)
	first := picture_make(KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT)
	defer delete(first.pixels)
	second := picture_make(KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT)
	defer delete(second.pixels)
	scratch := picture_make(1, 1, room = 2 * KEEP_TEST_WIDTH * KEEP_TEST_HEIGHT)
	defer delete(scratch.pixels)
	for row in 0 ..< KEEP_TEST_HEIGHT {
		segment_draw(&first, 0, row, KEEP_TEST_WIDTH - 1, row, 1, graphics.Color(row))
	}
	state := Keep_State{store_open = true, started = true, named = true}
	ROWS :: KEEP_TEST_WIDTH * KEEP_TEST_HEIGHT * 4

	// A new picture too large for one commit: no picture until the rename.
	outcomes := memory_keep(t, &store, &state, &first, nil, &scratch)
	testing.expect_value(t, state.form, Keep_Form.New_Object)
	testing.expect(t, len(outcomes) > 2, "a large keep takes several commits")
	for outcome, index in outcomes {
		wanted := index == len(outcomes) - 1 ? Read_Outcome.New : Read_Outcome.Absent
		testing.expectf(t, outcome == wanted, "the new picture, after the commit %d: %v", index, outcome)
	}
	testing.expect(t, state.written && state.rows_offset == FILE_HEADER_BYTES)

	// A change of each row: the whole picture after the rows of the header.
	copy(second.pixels, first.pixels)
	for row in 0 ..< KEEP_TEST_HEIGHT {
		segment_draw(&second, 0, row, KEEP_TEST_WIDTH - 1, row, 1, graphics.Color(0x010000 + row))
	}
	changed_rows_add(&state.rows, {0, 0, KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT}, 100)
	delete(outcomes)
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch)
	testing.expect_value(t, state.form, Keep_Form.Other_Place)
	for outcome, index in outcomes {
		wanted := index == len(outcomes) - 1 ? Read_Outcome.New : Read_Outcome.Old
		testing.expectf(t, outcome == wanted, "the other place, after the commit %d: %v", index, outcome)
	}
	testing.expect_value(t, state.rows_offset, FILE_HEADER_BYTES + ROWS)

	// A few rows: one commit, in place.
	copy(first.pixels, second.pixels)
	segment_draw(&second, 10, 40, 300, 44, 3, 0xABCDEF)
	changed_rows_add(&state.rows, {0, 38, KEEP_TEST_WIDTH, 46}, 200)
	delete(outcomes)
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch)
	testing.expect_value(t, state.form, Keep_Form.One_Commit)
	testing.expect_value(t, len(outcomes), 1)
	testing.expect_value(t, outcomes[0], Read_Outcome.New)
	testing.expect_value(t, state.rows_offset, FILE_HEADER_BYTES + ROWS)

	// A large keep again: back before them, the old picture until the
	// header names it; the size at the header drops the old rows.
	copy(first.pixels, second.pixels)
	for row in 0 ..< KEEP_TEST_HEIGHT {
		segment_draw(&second, 0, row, 99, row, 1, 0x00FF00)
	}
	changed_rows_add(&state.rows, {0, 0, 100, KEEP_TEST_HEIGHT}, 300)
	delete(outcomes)
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch)
	testing.expect_value(t, state.form, Keep_Form.Other_Place)
	for outcome, index in outcomes {
		wanted := index == len(outcomes) - 1 ? Read_Outcome.New : Read_Outcome.Old
		testing.expectf(t, outcome == wanted, "back before the rows, after the commit %d: %v", index, outcome)
	}
	testing.expect_value(t, state.rows_offset, FILE_HEADER_BYTES)
	testing.expect_value(t, len(store.objects["sky.picture"].committed), FILE_HEADER_BYTES + ROWS)
	delete(outcomes)

	// A wider picture: each row moves, so even a band of one row is a whole
	// keep at another place.
	copy(first.pixels, second.pixels)
	wider := picture_make(KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT, room = (KEEP_TEST_WIDTH + 8) * KEEP_TEST_HEIGHT)
	defer delete(wider.pixels)
	copy(wider.pixels, second.pixels[:KEEP_TEST_WIDTH * KEEP_TEST_HEIGHT])
	testing.expect_value(t, picture_extend(&wider, KEEP_TEST_WIDTH + 8, KEEP_TEST_HEIGHT), Extend_Outcome.Grown)
	changed_rows_add(&state.rows, {0, 0, KEEP_TEST_WIDTH + 8, 1}, 400)
	outcomes = memory_keep(t, &store, &state, &wider, &first, &scratch)
	testing.expect_value(t, state.form, Keep_Form.Other_Place)
	for outcome, index in outcomes {
		wanted := index == len(outcomes) - 1 ? Read_Outcome.New : Read_Outcome.Old
		testing.expectf(t, outcome == wanted, "the wider picture, after the commit %d: %v", index, outcome)
	}
	testing.expect(t, state.kept_width == KEEP_TEST_WIDTH + 8 && state.rows_offset == FILE_HEADER_BYTES + ROWS)
	delete(outcomes)
}

// A stroke between two pieces of a large keep is committed in part: each
// commit still holds a whole valid picture, and the next keep makes the
// store equal to the window.
@(test)
a_stroke_during_a_large_keep_is_completed_by_the_next_keep :: proc(t: ^testing.T) {
	store: Memory_Store
	defer memory_store_free(&store)
	first := picture_make(KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT)
	defer delete(first.pixels)
	second := picture_make(KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT)
	defer delete(second.pixels)
	scratch := picture_make(1, 1, room = 2 * KEEP_TEST_WIDTH * KEEP_TEST_HEIGHT)
	defer delete(scratch.pixels)
	state := Keep_State{store_open = true, started = true, named = true}
	outcomes := memory_keep(t, &store, &state, &first, nil, &scratch)
	delete(outcomes)
	copy(second.pixels, first.pixels)
	for row in 0 ..< KEEP_TEST_HEIGHT {
		segment_draw(&second, 0, row, KEEP_TEST_WIDTH - 1, row, 1, graphics.Color(0x020000 + row))
	}
	changed_rows_add(&state.rows, {0, 0, KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT}, 100)
	// Past the first commit: the stroke reaches the later pieces only.
	pieces_of_a_commit := KEEP_COMMIT_BYTES / KEEP_PIECE_BYTES
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch, stroke_after_piece = pieces_of_a_commit + 2)
	testing.expect_value(t, state.form, Keep_Form.Other_Place)
	for outcome, index in outcomes[:len(outcomes) - 1] {
		testing.expectf(t, outcome == .Old, "before the header, after the commit %d: %v", index, outcome)
	}
	testing.expect_value(t, outcomes[len(outcomes) - 1], Read_Outcome.Other)
	testing.expect(t, state.rows.changed, "the rows of the stroke wait for the next keep")
	delete(outcomes)
	// The next keep, due at most 5 s after the stroke.
	testing.expect_value(t, keep_due_time(&state.rows), u64(1000 + KEEP_PAUSE_MILLISECONDS))
	outcomes = memory_keep(t, &store, &state, &second, nil, &scratch)
	for outcome in outcomes {
		testing.expect(t, outcome != .Damaged)
	}
	testing.expect_value(t, outcomes[len(outcomes) - 1], Read_Outcome.New)
	delete(outcomes)
}

// A stop before the rename of a large first keep leaves a temporary object
// and no picture; the open removes it, and only it; the next first keep of
// the same name makes the picture.
@(test)
the_open_removes_the_temporary_object_of_a_stopped_keep :: proc(t: ^testing.T) {
	// The names: only a name of a picture with the suffix.
	for refused in ([]string{"", ".partial", "sky.picture", "sky.partialx", "Sky.partial", "a b.partial", "sky.partial.partial"}) {
		_, ok := partial_name_of_object(refused)
		testing.expectf(t, !ok, "%q is no temporary object", refused)
	}
	room: Object_Name
	_, room_ok := partial_object_name(&room, "")
	testing.expect(t, !room_ok)
	object, ok := partial_object_name(&room, "sky")
	testing.expect(t, ok && object == "sky.partial")
	name, _ := partial_name_of_object(object)
	testing.expect_value(t, name, "sky")
	_, is_picture := picture_name_of_object(object)
	testing.expect(t, !is_picture, "the list shows no picture of a temporary object")

	store: Memory_Store
	defer memory_store_free(&store)
	picture := picture_make(KEEP_TEST_WIDTH, KEEP_TEST_HEIGHT)
	defer delete(picture.pixels)
	scratch := picture_make(1, 1, room = 2 * KEEP_TEST_WIDTH * KEEP_TEST_HEIGHT)
	defer delete(scratch.pixels)
	for row in 0 ..< KEEP_TEST_HEIGHT {
		segment_draw(&picture, 0, row, KEEP_TEST_WIDTH - 1, row, 1, graphics.Color(row))
	}
	memory_write(&store, "other.picture", 0, {1})
	memory_commit(&store, "other.picture")
	memory_write(&store, "a b.partial", 0, {1})
	memory_commit(&store, "a b.partial")
	state := Keep_State{store_open = true, started = true, named = true}
	outcomes := memory_keep(t, &store, &state, &picture, nil, &scratch, stop_after_commit = 1)
	testing.expect_value(t, len(outcomes), 2)
	testing.expect_value(t, outcomes[1], Read_Outcome.Absent)
	delete(outcomes)
	_, has_partial := store.objects["sky.partial"]
	testing.expect(t, has_partial, "the stop left the temporary object")

	memory_open(&store)
	_, has_partial = store.objects["sky.partial"]
	testing.expect(t, !has_partial, "the open removed it")
	_, has_other := store.objects["other.picture"]
	_, has_foreign := store.objects["a b.partial"]
	testing.expect(t, has_other && has_foreign, "the open removes nothing else")

	fresh := Keep_State{store_open = true, started = true, named = true}
	outcomes = memory_keep(t, &store, &fresh, &picture, nil, &scratch)
	testing.expect_value(t, fresh.form, Keep_Form.New_Object)
	testing.expect_value(t, outcomes[len(outcomes) - 1], Read_Outcome.New)
	delete(outcomes)
}

// A keep runs in pieces that fit a call; the pieces cover the band once;
// the header and the size come with the last piece; a wider picture is a
// whole keep at another place; a refused piece ends the keep.
@(test)
a_keep_runs_in_pieces_that_fit_a_call :: proc(t: ^testing.T) {
	PLACE :: FILE_HEADER_BYTES + 4096
	ROW :: 100 * 4
	state := Keep_State{store_open = true, named = true, written = true, rows_offset = PLACE, kept_width = 100, kept_height = 60}
	changed_rows_add(&state.rows, {0, 10, 10, 50}, 0)
	keep_begin(&state, 100, 60)
	testing.expect(t, state.keeping && !state.rows.changed, "the band moved to the keep")
	testing.expect(t, state.form == .One_Commit && state.target_offset == PLACE)
	band := 40 * ROW
	covered, commits := 0, 0
	for state.keeping {
		piece := keep_piece(&state)
		testing.expect(t, piece.bytes > 0 && piece.bytes <= KEEP_PIECE_BYTES)
		testing.expect_value(t, piece.offset, PLACE + 10 * ROW + covered)
		testing.expect_value(t, piece.row, 10 * ROW + covered)
		testing.expect_value(t, piece.header, piece.last)
		testing.expect_value(t, piece.commit, piece.last)
		testing.expect_value(t, piece.size, PLACE + 60 * ROW)
		testing.expect(t, !piece.rename && piece.object == .Picture)
		commits += piece.commit ? 1 : 0
		covered += piece.bytes
		testing.expect_value(t, keep_piece_written(&state, piece), piece.last)
	}
	testing.expect(t, covered == band && commits == 1)
	testing.expect(t, state.rows_offset == PLACE && state.kept_width == 100 && state.kept_height == 60)
	// A wider extent with no changed row: all the rows move, so the keep
	// writes them all, before the rows of the header since they fit there.
	changed_rows_mark(&state.rows, 10)
	keep_begin(&state, 101, 10)
	testing.expect(t, state.form == .Other_Place && state.target_offset == FILE_HEADER_BYTES)
	testing.expect(t, state.keep_top == 0 && state.keep_bottom == 10)
	// A refused piece ends the keep, and its rows wait for the next one.
	keep_refused(&state, 30, 10)
	testing.expect(t, !state.keeping && state.rows.whole && state.rows.changed)
	testing.expect_value(t, keep_step(&state, 30 + KEEP_RETRY_MILLISECONDS, false, false), Keep_Step.Keep)
	// Rows that do not fit before the rows of the header go after them.
	keep_begin(&state, 101, 60)
	testing.expect(t, state.form == .Other_Place && state.target_offset == PLACE + 60 * ROW)
}

// A keep is due at a pause of a second, or 5 seconds after the first change
// that it holds: changes less than a second apart do not hold it back.
@(test)
a_keep_is_due_at_most_5_seconds_after_its_first_change :: proc(t: ^testing.T) {
	rows: Changed_Rows
	now := u64(1000)
	changed_rows_add(&rows, {0, 0, 10, 10}, now)
	for now < 1000 + KEEP_LONGEST_WAIT_MILLISECONDS - 500 {
		now += 500
		changed_rows_add(&rows, {0, 0, 10, 10}, now)
		testing.expectf(t, !keep_due(&rows, now), "at %d: no pause, and under 5 s", now)
	}
	testing.expect(t, keep_due(&rows, 1000 + KEEP_LONGEST_WAIT_MILLISECONDS), "5 s after the first change")
	testing.expect_value(t, keep_due_time(&rows), u64(1000 + KEEP_LONGEST_WAIT_MILLISECONDS))
	testing.expect(t, !keep_due(&rows, 999), "a time before the first change is no wait")
	keep_taken(&rows)
	changed_rows_add(&rows, {0, 0, 10, 10}, 10_000)
	testing.expect_value(t, rows.first_change, u64(10_000))
	testing.expect_value(t, keep_due_time(&rows), u64(10_000 + KEEP_PAUSE_MILLISECONDS))
}

// A read waits for the end of a stroke: it takes the copy that the stroke
// holds for its undo as the memory of its rows. A keep that runs goes on
// before the act.
@(test)
a_read_waits_for_the_end_of_a_stroke :: proc(t: ^testing.T) {
	state := Keep_State{store_open = true, named = true}
	testing.expect(t, pending_ask(&state, .Read))
	testing.expect_value(t, keep_step(&state, 0, false, true), Keep_Step.Nothing)
	testing.expect_value(t, keep_step(&state, 0, false, false), Keep_Step.Pending)
	state.keeping = true
	testing.expect_value(t, keep_step(&state, 0, false, false), Keep_Step.Keep)
	testing.expect_value(t, keep_step(&state, 0, true, false), Keep_Step.Nothing)
}

@(private = "file")
heap_ring_grow :: proc "contextless" (history: ^History, wanted: int) -> bool {
	context = runtime.default_context()
	bound := int(uintptr(history.grow_data))
	if wanted > bound {
		return false
	}
	ring := make([]u8, min(max(2 * wanted, 1 << 16), bound), runtime.heap_allocator())
	copy(ring, history.ring)
	delete(history.ring, runtime.heap_allocator())
	history.ring = ring
	return true
}

// A fill on a photo of 6000 x 4000 (24 MP): rows of detail at the top, a
// sky of one color, and a frame of one pixel around it, which the fill
// paints. The box of the fill is the whole photo, which is what the history
// keeps; the frame keeps the cost of the fill itself small. The ring grows
// to the step, under the bound of one copy of the photo; undo gives the
// photo back, and redo the fill.
@(test)
a_fill_on_a_photo_undoes :: proc(t: ^testing.T) {
	WIDTH :: 6000
	HEIGHT :: 4000
	SKY :: graphics.Color(0x87CEEB)
	photo := picture_make(WIDTH, HEIGHT)
	defer delete(photo.pixels)
	noise_fill(&photo, {0, 0, WIDTH, 200}, 7)
	for &pixel in photo.pixels[200 * WIDTH:] {
		pixel = SKY
	}
	FRAME :: graphics.Color(0x101010)
	for column in 0 ..< WIDTH {
		photo.pixels[column], photo.pixels[(HEIGHT - 1) * WIDTH + column] = FRAME, FRAME
	}
	for row in 0 ..< HEIGHT {
		photo.pixels[row * WIDTH], photo.pixels[row * WIDTH + WIDTH - 1] = FRAME, FRAME
	}
	before := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(before)
	copy(before, photo.pixels)
	memory := Fill_Memory{grow = fill_test_grow}
	defer delete(memory.spans, runtime.heap_allocator())
	box, filled := fill_region(&photo, 0, 0, 0x228B22, &memory)
	testing.expect_value(t, filled, Fill_Outcome.Done)
	testing.expect_value(t, box, Box{0, 0, WIDTH, HEIGHT})
	bound := WIDTH * HEIGHT * size_of(graphics.Color)
	history := History{grow = heap_ring_grow, grow_data = rawptr(uintptr(bound))}
	// The grow procedure makes the ring with the heap of the process.
	defer delete(history.ring, runtime.heap_allocator())
	scratch := new(History_Scratch)
	defer free(scratch)
	testing.expect_value(t, history_record(&history, before, photo.pixels, WIDTH, box, bound, scratch), Record_Outcome.Kept)
	testing.expect(t, !history.in_copy && len(history.ring) <= bound, "the fill is a step of the ring, under its bound")
	_, undone := history_undo(&history, &photo, scratch)
	testing.expect(t, undone)
	testing.expect(t, string(transmute([]u8)photo.pixels) == string(transmute([]u8)before), "undo gives the photo back")
	_, redone := history_redo(&history, &photo, scratch)
	testing.expect(t, redone)
	testing.expect_value(t, photo.pixels[HEIGHT * WIDTH - 1], graphics.Color(0x228B22))
	testing.expect_value(t, photo.pixels[199 * WIDTH + 1], before[199 * WIDTH + 1])
	testing.expect_value(t, photo.pixels[3000 * WIDTH + 3000], SKY)
}

