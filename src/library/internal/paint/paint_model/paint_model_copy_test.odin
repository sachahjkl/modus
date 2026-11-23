#+build !freestanding
package paint_model

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:testing"
import "core:thread"
import "modus:graphics"
import "modus:system"

// The tests of the copy before a change, tile by tile, and of the cancel
// of an undo.

@(private = "file")
same_pixels :: proc(first, second: []graphics.Color) -> bool {
	return slice.equal(first, second)
}

// A stroke on the largest picture (16384 x 16384, 2^28 pixels) copies the
// tiles that it writes, a few, and no other: a tile far from it keeps
// nothing of the picture in the copy. The memory of the picture and of the
// copy is zero pages of the heap: only what the test writes is touched.
@(test)
a_stroke_on_the_largest_picture_copies_its_tiles :: proc(t: ^testing.T) {
	SIDE :: 16384
	#assert(SIDE * SIDE == PICTURE_PIXELS_LIMIT)
	bytes := SIDE * SIDE * size_of(graphics.Color)
	picture_memory := runtime.heap_alloc(bytes, zero_memory = true)
	copy_memory := runtime.heap_alloc(bytes, zero_memory = true)
	defer runtime.heap_free(picture_memory)
	defer runtime.heap_free(copy_memory)
	testing.expect(t, picture_memory != nil && copy_memory != nil)
	picture := Picture{pixels = ([^]graphics.Color)(picture_memory)[:SIDE * SIDE], width = SIDE, height = SIDE}
	copy_before := new(Copy_Before)
	defer free(copy_before)
	copy_before.pixels = ([^]graphics.Color)(copy_memory)[:SIDE * SIDE]
	// A mark far from the stroke, written before it.
	picture.pixels[10000 * SIDE + 10000] = 0x111111
	picture.pixels[100 * SIDE + 100] = 0x222222
	picture.before = copy_before
	box := segment_draw(&picture, 100, 100, 300, 120, 8, 0xFF0000)
	// The box covers rows 96 to 124 and columns 96 to 304: tiles 1 to 4 of
	// the tile row 1.
	testing.expect_value(t, box, Box{96, 96, 304, 124})
	testing.expect_value(t, copy_before.copied, 4)
	testing.expect_value(t, copy_before.pixels[100 * SIDE + 100], graphics.Color(0x222222))
	testing.expect_value(t, copy_before.pixels[10000 * SIDE + 10000], graphics.Color(0))
	testing.expect_value(t, picture.pixels[100 * SIDE + 100], graphics.Color(0xFF0000))
	// A second segment in the same tiles copies nothing more.
	segment_draw(&picture, 110, 110, 250, 100, 8, 0x00FF00)
	testing.expect_value(t, copy_before.copied, 4)
	// A long diagonal copies the tiles along it, not its box: 256 tiles of
	// 4096 x 4096 would be 4096.
	segment_draw(&picture, 0, 4096, 4095, 8191, 1, 0x0000FF)
	testing.expect(t, copy_before.copied < 4 + 3 * 64, "the tiles along the diagonal")
	// The restore puts back the copied tiles of a box: the picture before.
	copy_before_restore(copy_before, &picture, {0, 0, SIDE, 8192})
	testing.expect_value(t, picture.pixels[100 * SIDE + 100], graphics.Color(0x222222))
	testing.expect_value(t, picture.pixels[110 * SIDE + 200], graphics.Color(0))
	testing.expect_value(t, picture.pixels[10000 * SIDE + 10000], graphics.Color(0x111111))
	// The reset clears the marks: the next change copies again.
	copy_before_reset(copy_before)
	testing.expect_value(t, copy_before.copied, 0)
	for word in copy_before.tiles {
		testing.expect_value(t, word, 0)
	}
	segment_draw(&picture, 100, 100, 101, 100, 1, 0xFF00FF)
	testing.expect_value(t, copy_before.copied, 1)
}

// A change whose record is cancelled is put back from the copy exactly;
// the undo after it gives the picture before the step before, and the
// redo the step again, exactly. The copy holds only the tiles that the
// changes wrote, and the record takes the other tiles of its box from the
// picture, whose pixels they still are.
@(test)
an_undo_after_a_cancel_restores_exactly :: proc(t: ^testing.T) {
	WIDTH :: 300
	HEIGHT :: 200
	picture := Picture{pixels = make([]graphics.Color, WIDTH * HEIGHT)}
	defer delete(picture.pixels)
	picture_extend(&picture, WIDTH, HEIGHT)
	state := u32(3)
	for &pixel in picture.pixels {
		state = state * 1_664_525 + 1_013_904_223
		pixel = state >> 8
	}
	initial := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(initial)
	copy(initial, picture.pixels)
	copy_before := new(Copy_Before)
	defer free(copy_before)
	copy_before.pixels = make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(copy_before.pixels)
	// Room for the steps of noise in the ring, so no step is kept in the copy.
	bound := 4 * WIDTH * HEIGHT * size_of(graphics.Color)
	history := History{ring = make([]u8, bound)}
	defer delete(history.ring)
	scratch := new(History_Scratch)
	defer free(scratch)

	// The first change: two segments far apart, so its box holds tiles
	// that it did not write.
	picture.before = copy_before
	first := box_union(segment_draw(&picture, 10, 10, 40, 12, 5, 0xFF0000), segment_draw(&picture, 250, 180, 280, 190, 5, 0xFF0000))
	copy_before_touch(copy_before, &picture, first)
	testing.expect_value(t, history_record(&history, copy_before.pixels, picture.pixels, WIDTH, first, bound, scratch), Record_Outcome.Kept)
	picture.before = nil
	copy_before_reset(copy_before)
	after_first := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(after_first)
	copy(after_first, picture.pixels)

	// The second change: its record is cancelled, and its box comes back.
	// The window drops a step in the copy before a change writes the copy.
	testing.expect(t, !history.in_copy)
	history_copy_reused(&history)
	picture.before = copy_before
	second := rectangle_draw(&picture, 5, 5, 290, 190, 3, 0x00FF00)
	copy_before_touch(copy_before, &picture, second)
	intrinsics.atomic_store(&scratch.cancel, true)
	testing.expect_value(t, history_record(&history, copy_before.pixels, picture.pixels, WIDTH, second, bound, scratch), Record_Outcome.Cancelled)
	intrinsics.atomic_store(&scratch.cancel, false)
	copy_before_restore(copy_before, &picture, second)
	picture.before = nil
	copy_before_reset(copy_before)
	testing.expect(t, same_pixels(picture.pixels, after_first), "the cancelled change is put back exactly")

	_, undone := history_undo(&history, &picture, scratch, copy_before.pixels)
	testing.expect(t, undone)
	testing.expect(t, same_pixels(picture.pixels, initial), "the undo after the cancel gives the picture before exactly")
	_, redone := history_redo(&history, &picture, scratch, copy_before.pixels)
	testing.expect(t, redone)
	testing.expect(t, same_pixels(picture.pixels, after_first), "the redo gives the step again exactly")

	// An undo cancelled before it writes changes nothing, and stays to do.
	intrinsics.atomic_store(&scratch.cancel, true)
	_, undone = history_undo(&history, &picture, scratch, copy_before.pixels)
	testing.expect(t, !undone && history.done == 1)
	_, redone = history_redo(&history, &picture, scratch, copy_before.pixels)
	testing.expect(t, !redone, "nothing to redo")
	intrinsics.atomic_store(&scratch.cancel, false)
	testing.expect(t, same_pixels(picture.pixels, after_first))
	// A step in the copy: an exchange cancelled before it starts changes
	// nothing; done, it undoes exactly.
	history_copy_reused(&history)
	picture.before = copy_before
	whole := Box{0, 0, WIDTH, HEIGHT}
	copy_before_touch(copy_before, &picture, whole)
	picture_clear(&picture)
	testing.expect_value(t, history_record(&history, copy_before.pixels, picture.pixels, WIDTH, whole, 64, scratch), Record_Outcome.Kept)
	testing.expect(t, history.in_copy)
	picture.before = nil
	copy_before_reset(copy_before)
	intrinsics.atomic_store(&scratch.cancel, true)
	_, undone = history_undo(&history, &picture, scratch)
	intrinsics.atomic_store(&scratch.cancel, false)
	testing.expect(t, !undone && history.done == 1)
	_, undone = history_undo(&history, &picture, scratch)
	testing.expect(t, undone && same_pixels(picture.pixels, after_first), "the step in the copy undoes exactly")
}

@(private = "file")
Cancel_Watch :: struct {
	scratch: ^History_Scratch,
	at:      int, // The strip after which the watch cancels.
	ended:   bool, // The undo ended: the watch stops.
}

@(private = "file")
cancel_watch_run :: proc(watch: ^Cancel_Watch) {
	// A bound ends the wait if the undo never reaches the strip.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for !intrinsics.atomic_load(&watch.ended) && system.time() < deadline {
		if intrinsics.atomic_load(&watch.scratch.strips_done) >= watch.at {
			intrinsics.atomic_store(&watch.scratch.cancel, true)
			return
		}
	}
}

// An undo that another thread cancels while it writes puts back the strips
// that it wrote: the picture is the one before, exactly, and the step stays
// to undo. The cancel comes after the check of each strip, in the write;
// an undo that ends before the cancel reaches it is whole. Either way the
// picture is one of the two, never a mix.
@(test)
an_undo_cancelled_while_it_writes_puts_back_its_strips :: proc(t: ^testing.T) {
	WIDTH :: 2048
	HEIGHT :: 2048
	picture := Picture{pixels = make([]graphics.Color, WIDTH * HEIGHT)}
	defer delete(picture.pixels)
	picture_extend(&picture, WIDTH, HEIGHT)
	before := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(before)
	copy(before, picture.pixels)
	state := u32(9)
	for &pixel in picture.pixels {
		state = state * 1_664_525 + 1_013_904_223
		pixel = state >> 8
	}
	after := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(after)
	copy(after, picture.pixels)
	whole := Box{0, 0, WIDTH, HEIGHT}
	bound := 4 * WIDTH * HEIGHT * size_of(graphics.Color)
	history := History{ring = make([]u8, bound)}
	defer delete(history.ring)
	scratch := new(History_Scratch)
	defer free(scratch)
	testing.expect_value(t, history_record(&history, before, picture.pixels, WIDTH, whole, bound, scratch), Record_Outcome.Kept)
	testing.expect(t, !history.in_copy)
	saved := make([]graphics.Color, WIDTH * HEIGHT)
	defer delete(saved)
	strips := history_apply_strips(whole)
	watch := Cancel_Watch{scratch = scratch, at = strips / 2 + strips / 4}
	watcher := thread.create_and_start_with_poly_data(&watch, cancel_watch_run)
	_, undone := history_undo(&history, &picture, scratch, saved)
	intrinsics.atomic_store(&watch.ended, true)
	thread.join(watcher)
	thread.destroy(watcher)
	if undone {
		testing.expect(t, same_pixels(picture.pixels, before), "a whole undo")
		testing.expect_value(t, history.done, 0)
	} else {
		testing.expect(t, intrinsics.atomic_load(&scratch.cancel), "only a cancel stops this undo")
		testing.expect(t, same_pixels(picture.pixels, after), "the strips written are put back exactly")
		testing.expect_value(t, history.done, 1)
	}
}

@(private = "file")
Copy_Test :: struct {
	picture:     Picture,
	original:    []graphics.Color,
	copy_before: ^Copy_Before,
}

// copy_test_make gives a picture of noise, its original, and a copy before
// a change that the picture points to.
@(private = "file")
copy_test_make :: proc(width, height: int) -> Copy_Test {
	test := Copy_Test{picture = Picture{pixels = make([]graphics.Color, width * height)}, original = make([]graphics.Color, width * height), copy_before = new(Copy_Before)}
	picture_extend(&test.picture, width, height)
	state := u32(width * 31 + height)
	for &pixel in test.picture.pixels {
		state = state * 1_664_525 + 1_013_904_223
		pixel = state >> 8
	}
	copy(test.original, test.picture.pixels)
	test.copy_before.pixels = make([]graphics.Color, width * height)
	test.picture.before = test.copy_before
	return test
}

@(private = "file")
copy_test_free :: proc(test: ^Copy_Test) {
	delete(test.picture.pixels)
	delete(test.original)
	delete(test.copy_before.pixels)
	free(test.copy_before)
}

// A shallow segment that crosses a row of tiles, and a steep one that
// crosses a column: each tile that the line writes is in the copy, so the
// cancel puts the picture back exactly, and so does the undo of its step.
@(test)
a_segment_across_a_tile_edge_writes_through_the_copy :: proc(t: ^testing.T) {
	Case :: struct {
		width, height:  int,
		x0, y0, x1, y1: int,
	}
	cases := [?]Case{{700, 200, 0, 63, 630, 64}, {200, 700, 63, 0, 64, 630}, {700, 200, 630, 64, 0, 63}, {700, 700, 5, 600, 690, 7}}
	for item in cases {
		for thickness in ([?]int{1, 2, 34}) {
			test := copy_test_make(item.width, item.height)
			defer copy_test_free(&test)
			box := segment_draw(&test.picture, item.x0, item.y0, item.x1, item.y1, thickness, 0)
			// The cancel: the copied tiles of the box.
			after := make([]graphics.Color, item.width * item.height, context.temp_allocator)
			copy(after, test.picture.pixels)
			copy_before_restore(test.copy_before, &test.picture, box)
			testing.expectf(t, same_pixels(test.picture.pixels, test.original), "%v, %d: the cancel gives the picture back", item, thickness)
			// The undo: the record reads the copy, the tiles not written taken
			// from the picture.
			copy(test.picture.pixels, after)
			copy_before_touch(test.copy_before, &test.picture, box)
			bound := 4 * item.width * item.height * size_of(graphics.Color)
			history := History{ring = make([]u8, bound, context.temp_allocator)}
			scratch := new(History_Scratch, context.temp_allocator)
			testing.expect_value(t, history_record(&history, test.copy_before.pixels, test.picture.pixels, item.width, box, bound, scratch), Record_Outcome.Kept)
			test.picture.before = nil
			_, undone := history_undo(&history, &test.picture, scratch)
			testing.expectf(t, undone && same_pixels(test.picture.pixels, test.original), "%v, %d: the undo gives the picture back", item, thickness)
		}
	}
}

// Segments of each size in each direction, from edge to edge and past it:
// the cancel of each gives the picture back exactly.
@(test)
each_segment_writes_through_the_copy :: proc(t: ^testing.T) {
	test := copy_test_make(300, 250)
	defer copy_test_free(&test)
	state := u32(77)
	next :: proc(state: ^u32, below: int) -> int {
		state^ = state^ * 1_664_525 + 1_013_904_223
		return int(state^ >> 8) % below
	}
	for round in 0 ..< 300 {
		x0, y0 := next(&state, 340) - 20, next(&state, 290) - 20
		x1, y1 := next(&state, 340) - 20, next(&state, 290) - 20
		thickness := BRUSH_SIZES[round % len(BRUSH_SIZES)]
		box := segment_draw(&test.picture, x0, y0, x1, y1, thickness, graphics.Color(round))
		copy_before_restore(test.copy_before, &test.picture, box)
		copy_before_reset(test.copy_before)
		if !same_pixels(test.picture.pixels, test.original) {
			testing.expectf(t, false, "round %d: (%d, %d) to (%d, %d), size %d wrote past the copy", round, x0, y0, x1, y1, thickness)
			break
		}
	}
}

// A text that a call writes during a stroke goes through the copy: its
// cancel gives the picture back exactly.
@(test)
a_text_writes_through_the_copy :: proc(t: ^testing.T) {
	// The table of the blend of the text, which a process fills at its start.
	graphics.text_state_start()
	test := copy_test_make(400, 200)
	defer copy_test_free(&test)
	box := text_draw(&test.picture, 70, 60, "hello, wide W and g", 0)
	testing.expect(t, !box_empty(box))
	testing.expect(t, !same_pixels(test.picture.pixels, test.original), "the text is drawn")
	copy_before_restore(test.copy_before, &test.picture, box)
	testing.expect(t, same_pixels(test.picture.pixels, test.original), "the cancel gives the picture back")
	// At the edges, and past them.
	for place in ([?][2]int{{0, 0}, {390, 190}, {-30, -10}, {399, 199}}) {
		edge := text_draw(&test.picture, place[0], place[1], "edge", 0)
		copy_before_restore(test.copy_before, &test.picture, edge)
		testing.expectf(t, same_pixels(test.picture.pixels, test.original), "%v: the cancel gives the picture back", place)
	}
}

// A clear stopped after two bands is put back exactly by the copy.
@(test)
a_clear_stopped_between_bands_is_put_back :: proc(t: ^testing.T) {
	test := copy_test_make(300, 300)
	defer copy_test_free(&test)
	for top := 0; top < 2 * COPY_TILE_SIDE; top += COPY_TILE_SIDE {
		picture_clear_band(&test.picture, top, top + COPY_TILE_SIDE)
	}
	testing.expect_value(t, test.picture.pixels[0], COLOR_PAPER)
	testing.expect_value(t, test.picture.pixels[2 * COPY_TILE_SIDE * 300], test.original[2 * COPY_TILE_SIDE * 300])
	copy_before_restore(test.copy_before, &test.picture, {0, 0, 300, 300})
	testing.expect(t, same_pixels(test.picture.pixels, test.original))
}

