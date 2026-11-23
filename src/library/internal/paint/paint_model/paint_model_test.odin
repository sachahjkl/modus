#+build !freestanding
package paint_model

import "core:testing"
import "modus:graphics"

@(private = "file")
picture_make :: proc(width, height: int) -> Picture {
	picture := Picture{pixels = make([]graphics.Color, PICTURE_PIXELS)}
	picture_clear(&picture)
	picture_extend(&picture, width, height)
	return picture
}

@(private = "file")
pixel_at :: proc(picture: ^Picture, x, y: int) -> graphics.Color {
	return picture.pixels[y * PICTURE_WIDTH_LIMIT + x]
}

// The extent grows to the largest picture and never shrinks; the pixels
// that join it are paper, the pixels in it stay.
@(test)
the_extent_grows_and_never_shrinks :: proc(t: ^testing.T) {
	picture := picture_make(10, 10)
	defer delete(picture.pixels)
	picture.pixels[5 * PICTURE_WIDTH_LIMIT + 5] = 0x123456
	picture.pixels[20] = 0x654321 // Outside the extent: paper when the extent grows over it.
	for size in ([][2]int{{0, 0}, {-1, -1}, {5, 5}, {min(int), min(int)}}) {
		testing.expectf(t, !picture_extend(&picture, size[0], size[1]), "the size %v does not shrink the extent", size)
		testing.expect(t, picture.width == 10 && picture.height == 10)
	}
	generation := picture.generation
	testing.expect(t, picture_extend(&picture, 30, 12))
	testing.expect(t, picture.generation != generation)
	testing.expect_value(t, pixel_at(&picture, 5, 5), graphics.Color(0x123456))
	testing.expect_value(t, pixel_at(&picture, 20, 0), COLOR_PAPER)
	testing.expect(t, picture_extend(&picture, max(int), max(int)))
	testing.expect(t, picture.width == PICTURE_WIDTH_LIMIT && picture.height == PICTURE_HEIGHT_LIMIT)
	testing.expect(t, !picture_extend(&picture, PICTURE_WIDTH_LIMIT + 1, PICTURE_HEIGHT_LIMIT + 1))
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

// A fill outside the picture, and a fill of a region that has the color,
// change nothing; a fill stops at the edges of its region.
@(test)
a_fill_stays_in_its_region :: proc(t: ^testing.T) {
	picture := picture_make(64, 64)
	defer delete(picture.pixels)
	memory := new(Fill_Memory)
	defer free(memory)
	generation := picture.generation
	for point in ([][2]int{{-1, 0}, {0, -1}, {64, 0}, {0, 64}, {max(int), 0}, {min(int), min(int)}}) {
		testing.expectf(t, box_empty(fill_region(&picture, point[0], point[1], 0, memory)), "the point %v is refused", point)
	}
	testing.expect(t, box_empty(fill_region(&picture, 3, 3, COLOR_PAPER, memory)))
	testing.expect_value(t, picture.generation, generation)
	rectangle_draw(&picture, 10, 10, 30, 30, 1, 0x000000)
	box := fill_region(&picture, 20, 20, 0xFF0000, memory)
	testing.expect_value(t, box, Box{11, 11, 30, 30})
	testing.expect_value(t, pixel_at(&picture, 11, 11), graphics.Color(0xFF0000))
	testing.expect_value(t, pixel_at(&picture, 10, 10), graphics.Color(0x000000))
	testing.expect_value(t, pixel_at(&picture, 5, 5), COLOR_PAPER)
	testing.expect_value(t, memory.scans, 0)
}

// A region whose seeds pass the capacity of the stack is filled whole: the
// scan of the reached pixels finds the seeds that found no room.
@(test)
a_fill_past_the_capacity_of_its_stack_fills_the_whole_region :: proc(t: ^testing.T) {
	picture := picture_make(PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT)
	defer delete(picture.pixels)
	memory := new(Fill_Memory)
	defer free(memory)
	WALL :: graphics.Color(0x000000)
	// Each odd row has a wall at each odd column: each even row pushes a
	// seed for each pixel of the rows around it.
	for row := 1; row < PICTURE_HEIGHT_LIMIT; row += 2 {
		for column := 1; column < PICTURE_WIDTH_LIMIT; column += 2 {
			picture.pixels[row * PICTURE_WIDTH_LIMIT + column] = WALL
		}
	}
	box := fill_region(&picture, 0, 0, 0xFF0000, memory)
	testing.expect_value(t, box, Box{0, 0, PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT})
	testing.expect(t, memory.scans >= 1, "the stack overflowed and a scan ran")
	left := 0
	for row in 0 ..< PICTURE_HEIGHT_LIMIT {
		for column in 0 ..< PICTURE_WIDTH_LIMIT {
			wall := row % 2 == 1 && column % 2 == 1
			left += !wall && pixel_at(&picture, column, row) != 0xFF0000 ? 1 : 0
		}
	}
	testing.expect_value(t, left, 0)
}

@(private = "file")
History_Test :: struct {
	picture: Picture,
	before:  []graphics.Color,
	history: History,
	scratch: ^History_Scratch,
}

@(private = "file")
history_test_make :: proc(arena_bytes: int) -> History_Test {
	test := History_Test{picture = picture_make(200, 100), before = make([]graphics.Color, PICTURE_PIXELS), scratch = new(History_Scratch)}
	test.history.arena = make([]u8, arena_bytes)
	copy(test.before, test.picture.pixels)
	return test
}

@(private = "file")
history_test_free :: proc(test: ^History_Test) {
	delete(test.picture.pixels)
	delete(test.before)
	delete(test.history.arena)
	free(test.scratch)
}

// history_test_change draws a segment as the window does: a copy before,
// the change, then the record of its box.
@(private = "file")
history_test_change :: proc(test: ^History_Test, x: int, color: graphics.Color) -> Record_Outcome {
	copy(test.before, test.picture.pixels)
	box := segment_draw(&test.picture, x, 0, x, 99, 1, color)
	return history_record(&test.history, test.before, test.picture.pixels, box, test.scratch)
}

// With no change, undo and redo are refused; an empty box is not kept.
// Undo puts back the pixels before, redo the pixels after, and a new
// change removes what redo would give.
@(test)
undo_and_redo_put_back_the_pixels :: proc(t: ^testing.T) {
	test := history_test_make(HISTORY_BYTES)
	defer history_test_free(&test)
	testing.expect(t, !history_undo(&test.history, &test.picture, test.scratch))
	testing.expect(t, !history_redo(&test.history, &test.picture, test.scratch))
	testing.expect_value(t, history_record(&test.history, test.before, test.picture.pixels, {}, test.scratch), Record_Outcome.Empty)
	testing.expect_value(t, history_test_change(&test, 10, 0xFF0000), Record_Outcome.Kept)
	testing.expect_value(t, history_test_change(&test, 20, 0x00FF00), Record_Outcome.Kept)
	testing.expect(t, history_undo(&test.history, &test.picture, test.scratch))
	testing.expect_value(t, pixel_at(&test.picture, 20, 50), COLOR_PAPER)
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
	testing.expect(t, history_undo(&test.history, &test.picture, test.scratch))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), COLOR_PAPER)
	testing.expect(t, !history_undo(&test.history, &test.picture, test.scratch))
	testing.expect(t, history_redo(&test.history, &test.picture, test.scratch))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
	testing.expect(t, history_can_redo(&test.history))
	testing.expect_value(t, history_test_change(&test, 30, 0x0000FF), Record_Outcome.Kept)
	testing.expect(t, !history_can_redo(&test.history), "a new change removes what redo would give")
	testing.expect_value(t, test.history.count, 2)
}

// The history keeps HISTORY_STEPS_LIMIT changes: the oldest goes, and the
// others still undo in their order.
@(test)
the_history_keeps_its_limit_of_steps :: proc(t: ^testing.T) {
	test := history_test_make(HISTORY_BYTES)
	defer history_test_free(&test)
	for index in 0 ..< HISTORY_STEPS_LIMIT + 3 {
		testing.expect_value(t, history_test_change(&test, index, graphics.Color(index + 1)), Record_Outcome.Kept)
	}
	testing.expect_value(t, test.history.count, HISTORY_STEPS_LIMIT)
	undone := 0
	for history_undo(&test.history, &test.picture, test.scratch) {
		undone += 1
	}
	testing.expect_value(t, undone, HISTORY_STEPS_LIMIT)
	// The three oldest changes are not undone.
	testing.expect_value(t, pixel_at(&test.picture, 2, 50), graphics.Color(3))
	testing.expect_value(t, pixel_at(&test.picture, 3, 50), COLOR_PAPER)
}

// A change that does not fit in the arena alone clears the history; a
// change that needs the room of older ones drops them.
@(test)
a_change_larger_than_the_arena_clears_the_history :: proc(t: ^testing.T) {
	test := history_test_make(160)
	defer history_test_free(&test)
	testing.expect_value(t, history_test_change(&test, 10, 0xFF0000), Record_Outcome.Kept)
	kept := test.history.used
	testing.expect(t, kept > 0 && kept <= 160)
	for index in 0 ..< 8 {
		testing.expect_value(t, history_test_change(&test, 20 + index, 0x00FF00), Record_Outcome.Kept)
		testing.expect(t, test.history.used <= 160)
	}
	testing.expect(t, test.history.count < 9, "older changes went for the room")
	// Noise does not compress: its two blocks pass the arena.
	copy(test.before, test.picture.pixels)
	state := u32(1)
	for row in 0 ..< 100 {
		for column in 0 ..< 200 {
			state = state * 1_664_525 + 1_013_904_223
			test.picture.pixels[row * PICTURE_WIDTH_LIMIT + column] = state >> 8
		}
	}
	testing.expect_value(t, history_record(&test.history, test.before, test.picture.pixels, {0, 0, 200, 100}, test.scratch), Record_Outcome.Too_Large)
	testing.expect(t, !history_can_undo(&test.history) && !history_can_redo(&test.history))
}

// A damaged block is refused, and the picture and the history stay.
@(test)
a_damaged_step_changes_nothing :: proc(t: ^testing.T) {
	test := history_test_make(HISTORY_BYTES)
	defer history_test_free(&test)
	history_test_change(&test, 10, 0xFF0000)
	step := test.history.steps[0]
	// A block of the wrong size: the box asks for more pixels.
	test.history.steps[0].box.bottom += 1
	generation := test.picture.generation
	testing.expect(t, !history_undo(&test.history, &test.picture, test.scratch))
	testing.expect_value(t, test.picture.generation, generation)
	testing.expect_value(t, test.history.done, 1)
	// A box outside the largest picture.
	test.history.steps[0] = step
	test.history.steps[0].box.right = PICTURE_WIDTH_LIMIT + 1
	testing.expect(t, !history_undo(&test.history, &test.picture, test.scratch))
	// Bytes that are no LZ4 block: a literal length past the block.
	test.history.steps[0] = step
	test.history.arena[step.offset] = 0xF0
	test.history.arena[step.offset + 1] = 0xFF
	testing.expect(t, !history_undo(&test.history, &test.picture, test.scratch))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
}

// A file of a picture reads back as the same picture; each damaged field
// is refused with its problem, and the picture stays as it was.
@(test)
the_picture_file_refuses_each_damaged_field :: proc(t: ^testing.T) {
	picture := picture_make(40, 30)
	defer delete(picture.pixels)
	file := make([]u8, FILE_BYTES_LIMIT + FILE_ROW_BYTES)
	defer delete(file)
	_, refused := picture_encode(&picture, file[:file_size_of_slot(0, 30) - 1])
	testing.expect(t, !refused, "a buffer too small is refused")
	empty := Picture{pixels = picture.pixels}
	_, refused = picture_encode(&empty, file)
	testing.expect(t, !refused, "an empty extent is refused")
	segment_draw(&picture, 0, 0, 39, 29, 2, 0x336699)
	encoded, ok := picture_encode(&picture, file)
	testing.expect(t, ok)
	testing.expect_value(t, len(encoded), FILE_HEADER_BYTES + 30 * FILE_ROW_BYTES)
	// The good file, apart from the buffer that each case damages.
	bytes := make([]u8, len(encoded))
	defer delete(bytes)
	copy(bytes, encoded)
	other := picture_make(10, 10)
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
		{4, 1, -1, .Bad_Version}, // The compressed form of before.
		{4, 2, -1, .Bad_Version}, // The rows of one slot of before.
		{4, 4, -1, .Bad_Version},
		{7, 0xFF, -1, .Bad_Version},
		{8, 0, -1, .Bad_Size}, // The width 0: the low byte of 40 is 40, and the others are 0.
		{11, 0xFF, -1, .Bad_Size}, // A width past the largest.
		{13, 0x05, -1, .Bad_Size}, // A height of 30 + 1280 past 1080.
		{12, 0, -1, .Bad_Size}, // The height 0.
		{16, 1, -1, .Bad_Row}, // 1793 pixels: the low byte of 1920 (0x780) is 0x80.
		{17, 0x06, -1, .Bad_Row}, // 1664 pixels.
		{12, 31, -1, .Bad_Length}, // The height 31 with the rows of 30.
		{20, 2, -1, .Bad_Slot},
		{23, 0x80, -1, .Bad_Slot}, // The largest slot words name no slot.
		{20, 1, -1, .Bad_Length}, // The slot 1, which this file does not hold.
		{-1, 0, len(bytes) - 1, .Bad_Length},
		{FILE_HEADER_BYTES + 3, 0x01, -1, .Bad_Pixel}, // The top byte of the first pixel.
		{len(bytes) - 1, 0xFF, -1, .Bad_Pixel}, // The top byte of the last pixel.
		{FILE_HEADER_BYTES + 40 * 4, 0, -1, .Bad_Margin}, // The first pixel past the width is not paper.
		{len(bytes) - 4, 0, -1, .Bad_Margin}, // The last pixel of the last row is not paper.
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
	testing.expect_value(t, picture_decode(bytes, &other), File_Problem.None)
	testing.expect(t, other.width == 40 && other.height == 30)
	for row in 0 ..< 30 {
		for column in 0 ..< 40 {
			testing.expect_value(t, pixel_at(&other, column, row), pixel_at(&picture, column, row))
		}
	}
	testing.expect_value(t, pixel_at(&other, 40, 0), COLOR_PAPER)
	testing.expect_value(t, pixel_at(&other, 0, 30), COLOR_PAPER)
	// A file longer than its slot holds a slot after it: the picture is the
	// rows of its height, and a height 29 reads 29 rows.
	copy(file, bytes)
	file[12] = 29
	testing.expect_value(t, picture_decode(file[:len(bytes) + 1], &other), File_Problem.None)
	testing.expect(t, other.width == 40 && other.height == 29)
	// The largest picture, at the exact limits, is read whole.
	largest := picture_make(PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT)
	defer delete(largest.pixels)
	segment_draw(&largest, PICTURE_WIDTH_LIMIT - 1, PICTURE_HEIGHT_LIMIT - 1, PICTURE_WIDTH_LIMIT - 1, PICTURE_HEIGHT_LIMIT - 1, 1, 0x010203)
	whole, whole_ok := picture_encode(&largest, file)
	testing.expect(t, whole_ok && len(whole) == file_size_of_slot(0, PICTURE_HEIGHT_LIMIT))
	testing.expect_value(t, picture_decode(whole, &other), File_Problem.None)
	testing.expect(t, other.width == PICTURE_WIDTH_LIMIT && other.height == PICTURE_HEIGHT_LIMIT)
	testing.expect_value(t, pixel_at(&other, PICTURE_WIDTH_LIMIT - 1, PICTURE_HEIGHT_LIMIT - 1), graphics.Color(0x010203))
}

// The rows of a keep are at one place of the file: the band that a keep
// writes reads back into the file as a whole encode gives it.
@(test)
the_rows_of_a_keep_are_the_rows_of_the_file :: proc(t: ^testing.T) {
	picture := picture_make(100, 50)
	defer delete(picture.pixels)
	file := make([]u8, FILE_BYTES_LIMIT)
	defer delete(file)
	band := make([]u8, FILE_BYTES_LIMIT)
	defer delete(band)
	for refused in ([][2]int{{-1, 3}, {0, 0}, {5, 4}, {0, 51}, {50, 51}}) {
		_, ok := file_rows_copy(&picture, refused[0], refused[1], band)
		testing.expectf(t, !ok, "the rows %v are refused", refused)
	}
	_, small := file_rows_copy(&picture, 0, 2, band[:2 * FILE_ROW_BYTES - 1])
	testing.expect(t, !small, "a buffer too small is refused")
	box := segment_draw(&picture, 10, 20, 90, 24, 3, 0x112233)
	rows, ok := file_rows_copy(&picture, box.top, box.bottom, band)
	testing.expect(t, ok)
	whole, _ := picture_encode(&picture, file)
	testing.expect(t, string(whole[file_rows_offset(0, box.top):][:len(rows)]) == string(rows))
	testing.expect_value(t, file_rows_offset(0, 0), FILE_HEADER_BYTES)
	testing.expect_value(t, file_rows_offset(1, 0), FILE_HEADER_BYTES + FILE_SLOT_BYTES)
	testing.expect_value(t, file_rows_offset(max(int), 0), FILE_HEADER_BYTES + FILE_SLOT_BYTES)
	testing.expect_value(t, file_size_of_slot(0, PICTURE_HEIGHT_LIMIT + 1), FILE_HEADER_BYTES + FILE_SLOT_BYTES)
	testing.expect_value(t, file_size_of_slot(1, PICTURE_HEIGHT_LIMIT), FILE_BYTES_LIMIT)
	testing.expect_value(t, file_size_of_slot(0, -1), FILE_HEADER_BYTES)
	for refused in ([][3]int{{0, 0, 0}, {41, 10, 0}, {10, 0, 0}, {10, 10, 2}, {10, 10, -1}, {PICTURE_WIDTH_LIMIT + 1, 10, 0}}) {
		_, header_ok := file_header_write(refused[0], refused[1], refused[2], file)
		testing.expectf(t, !header_ok || refused[0] == 41, "the header %v is refused", refused)
	}
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

// A step that fills the arena exactly is kept, and the next one drops it
// with no read past the arena.
@(test)
a_step_that_fills_the_arena_exactly :: proc(t: ^testing.T) {
	measure := history_test_make(HISTORY_BYTES)
	testing.expect_value(t, history_test_change(&measure, 10, 0xFF0000), Record_Outcome.Kept)
	exact := measure.history.used
	history_test_free(&measure)
	test := history_test_make(exact)
	defer history_test_free(&test)
	testing.expect_value(t, history_test_change(&test, 10, 0xFF0000), Record_Outcome.Kept)
	testing.expect_value(t, test.history.used, len(test.history.arena))
	testing.expect_value(t, history_test_change(&test, 10, 0x00FF00), Record_Outcome.Kept)
	testing.expect_value(t, test.history.count, 1)
	testing.expect(t, history_undo(&test.history, &test.picture, test.scratch))
	testing.expect_value(t, pixel_at(&test.picture, 10, 50), graphics.Color(0xFF0000))
}

// An undo whose box is past the extent grows the extent first: the paper
// of the growth does not cover the pixels of the step.
@(test)
an_undo_past_the_extent_keeps_its_pixels :: proc(t: ^testing.T) {
	test := history_test_make(HISTORY_BYTES)
	defer history_test_free(&test)
	testing.expect_value(t, history_test_change(&test, 150, 0xFF0000), Record_Outcome.Kept)
	testing.expect_value(t, history_test_change(&test, 150, 0x00FF00), Record_Outcome.Kept)
	// A smaller extent than the box of the steps.
	test.picture.width = 100
	testing.expect(t, history_undo(&test.history, &test.picture, test.scratch))
	testing.expect(t, test.picture.width >= 151)
	testing.expect_value(t, pixel_at(&test.picture, 150, 50), graphics.Color(0xFF0000))
}

// The first free name skips the names that the store holds.
@(test)
the_first_free_name_of_a_picture :: proc(t: ^testing.T) {
	room: [NAME_LIMIT]u8
	name, ok := first_free_name(nil, &room)
	testing.expect(t, ok && name == "picture-1")
	name, ok = first_free_name([]string{"picture-1", "picture-3", "sky"}, &room)
	testing.expect(t, ok && name == "picture-2")
	taken := make([]string, PICTURE_NAMES_TRIED)
	defer delete(taken)
	rooms := make([][NAME_LIMIT]u8, PICTURE_NAMES_TRIED)
	defer delete(rooms)
	for index in 0 ..< PICTURE_NAMES_TRIED {
		taken[index], _ = first_free_name(taken[:index], &rooms[index])
	}
	testing.expect_value(t, taken[PICTURE_NAMES_TRIED - 1], "picture-1000")
	_, ok = first_free_name(taken, &room)
	testing.expect(t, !ok, "each name tried is taken")
	testing.expect_value(t, name_check("picture-1000"), Name_Problem.None)
}

// A name is 1 to NAME_LIMIT bytes of lowercase letters, digits, "-" and
// "_"; an object is a picture only with a valid name and the suffix.
@(test)
the_names_of_the_pictures :: proc(t: ^testing.T) {
	long := "abcdefghijklmnopqrstuvwxyz012345"
	testing.expect_value(t, name_check(""), Name_Problem.Empty)
	testing.expect_value(t, name_check("abcdefghijklmnopqrstuvwxyz0123456"), Name_Problem.Too_Long)
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
	testing.expect(t, ok && object == "abcdefghijklmnopqrstuvwxyz012345.picture")
	for refused in ([]string{"", ".picture", "x.pic", "A.picture", "a b.picture", "picture", "abcdefghijklmnopqrstuvwxyz0123456.picture"}) {
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
		for row in 0 ..< first.height {
			start := row * PICTURE_WIDTH_LIMIT
			if string(([^]u8)(&first.pixels[start])[:first.width * 4]) != string(([^]u8)(&second.pixels[start])[:first.width * 4]) {
				return false
			}
		}
		return true
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
	pixels := ([^]u8)(raw_data(picture.pixels))[:PICTURE_BYTES]
	keep_begin(state, picture.width, picture.height)
	for piece_index := 0; state.keeping; piece_index += 1 {
		piece := keep_piece(state)
		name := piece.object == .Partial ? "sky.partial" : "sky.picture"
		if piece.bytes > 0 {
			copy(buffer[FILE_HEADER_BYTES:], pixels[piece.row:][:piece.bytes])
			memory_write(store, name, piece.offset, buffer[FILE_HEADER_BYTES:][:piece.bytes])
		}
		if piece.header {
			header, ok := file_header_write(state.keep_width, state.keep_height, state.target_slot, buffer)
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
	first := picture_make(PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT)
	defer delete(first.pixels)
	second := picture_make(PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT)
	defer delete(second.pixels)
	scratch := picture_make(1, 1)
	defer delete(scratch.pixels)
	for row in 0 ..< PICTURE_HEIGHT_LIMIT {
		segment_draw(&first, 0, row, PICTURE_WIDTH_LIMIT - 1, row, 1, graphics.Color(row))
	}
	state := Keep_State{store_open = true, started = true, named = true}

	// A new picture too large for one commit: no picture until the rename.
	outcomes := memory_keep(t, &store, &state, &first, nil, &scratch)
	testing.expect_value(t, state.form, Keep_Form.New_Object)
	testing.expect(t, len(outcomes) > 2, "a large keep takes several commits")
	for outcome, index in outcomes {
		wanted := index == len(outcomes) - 1 ? Read_Outcome.New : Read_Outcome.Absent
		testing.expectf(t, outcome == wanted, "the new picture, after the commit %d: %v", index, outcome)
	}
	testing.expect(t, state.written && state.slot == 0)

	// A change of each row: the whole picture into the other slot.
	copy(second.pixels, first.pixels)
	for row in 0 ..< PICTURE_HEIGHT_LIMIT {
		segment_draw(&second, 0, row, PICTURE_WIDTH_LIMIT - 1, row, 1, graphics.Color(0x010000 + row))
	}
	changed_rows_add(&state.rows, {0, 0, PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT}, 100)
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch)
	testing.expect_value(t, state.form, Keep_Form.Other_Slot)
	for outcome, index in outcomes {
		wanted := index == len(outcomes) - 1 ? Read_Outcome.New : Read_Outcome.Old
		testing.expectf(t, outcome == wanted, "the other slot, after the commit %d: %v", index, outcome)
	}
	testing.expect(t, state.slot == 1)

	// A few rows: one commit, in the current slot.
	copy(first.pixels, second.pixels)
	segment_draw(&second, 10, 40, 300, 44, 3, 0xABCDEF)
	changed_rows_add(&state.rows, {0, 38, PICTURE_WIDTH_LIMIT, 46}, 200)
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch)
	testing.expect_value(t, state.form, Keep_Form.One_Commit)
	testing.expect_value(t, len(outcomes), 1)
	testing.expect_value(t, outcomes[0], Read_Outcome.New)
	testing.expect(t, state.slot == 1)

	// A large keep again: back to the slot 0, the old picture until the
	// header names it.
	copy(first.pixels, second.pixels)
	for row in 0 ..< PICTURE_HEIGHT_LIMIT {
		segment_draw(&second, 0, row, 99, row, 1, 0x00FF00)
	}
	changed_rows_add(&state.rows, {0, 0, 100, PICTURE_HEIGHT_LIMIT}, 300)
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch)
	testing.expect_value(t, state.form, Keep_Form.Other_Slot)
	for outcome, index in outcomes {
		wanted := index == len(outcomes) - 1 ? Read_Outcome.New : Read_Outcome.Old
		testing.expectf(t, outcome == wanted, "back to the slot 0, after the commit %d: %v", index, outcome)
	}
	testing.expect(t, state.slot == 0)
	delete(outcomes)
}

// A stroke between two pieces of a large keep is committed in part: each
// commit still holds a whole valid picture, and the next keep makes the
// store equal to the window.
@(test)
a_stroke_during_a_large_keep_is_completed_by_the_next_keep :: proc(t: ^testing.T) {
	store: Memory_Store
	defer memory_store_free(&store)
	first := picture_make(PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT)
	defer delete(first.pixels)
	second := picture_make(PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT)
	defer delete(second.pixels)
	scratch := picture_make(1, 1)
	defer delete(scratch.pixels)
	state := Keep_State{store_open = true, started = true, named = true}
	outcomes := memory_keep(t, &store, &state, &first, nil, &scratch)
	delete(outcomes)
	copy(second.pixels, first.pixels)
	for row in 0 ..< PICTURE_HEIGHT_LIMIT {
		segment_draw(&second, 0, row, PICTURE_WIDTH_LIMIT - 1, row, 1, graphics.Color(0x020000 + row))
	}
	changed_rows_add(&state.rows, {0, 0, PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT}, 100)
	// Past the first commit: the stroke reaches the later pieces only.
	pieces_of_a_commit := KEEP_COMMIT_BYTES / KEEP_PIECE_BYTES
	outcomes = memory_keep(t, &store, &state, &second, &first, &scratch, stroke_after_piece = pieces_of_a_commit + 2)
	testing.expect_value(t, state.form, Keep_Form.Other_Slot)
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
	picture := picture_make(PICTURE_WIDTH_LIMIT, PICTURE_HEIGHT_LIMIT)
	defer delete(picture.pixels)
	scratch := picture_make(1, 1)
	defer delete(scratch.pixels)
	for row in 0 ..< PICTURE_HEIGHT_LIMIT {
		segment_draw(&picture, 0, row, PICTURE_WIDTH_LIMIT - 1, row, 1, graphics.Color(row))
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
// the header and the size come with the last piece; a keep of the header
// alone is one piece; a refused piece ends the keep.
@(test)
a_keep_runs_in_pieces_that_fit_a_call :: proc(t: ^testing.T) {
	state := Keep_State{store_open = true, named = true, written = true, slot = 1}
	changed_rows_add(&state.rows, {0, 10, 10, 50}, 0)
	keep_begin(&state, 100, 60)
	testing.expect(t, state.keeping && !state.rows.changed, "the band moved to the keep")
	testing.expect(t, state.form == .One_Commit && state.target_slot == 1)
	band := 40 * FILE_ROW_BYTES
	covered, commits := 0, 0
	for state.keeping {
		piece := keep_piece(&state)
		testing.expect(t, piece.bytes > 0 && piece.bytes <= KEEP_PIECE_BYTES)
		testing.expect_value(t, piece.offset, file_rows_offset(1, 10) + covered)
		testing.expect_value(t, piece.row, 10 * FILE_ROW_BYTES + covered)
		testing.expect_value(t, piece.header, piece.last)
		testing.expect_value(t, piece.commit, piece.last)
		testing.expect(t, !piece.rename && piece.object == .Picture)
		commits += piece.commit ? 1 : 0
		covered += piece.bytes
		testing.expect_value(t, keep_piece_written(&state, piece), piece.last)
	}
	testing.expect(t, covered == band && commits == 1)
	// A keep of the header alone: a wider extent.
	changed_rows_mark(&state.rows, 10)
	keep_begin(&state, 40, 60)
	piece := keep_piece(&state)
	testing.expect(t, piece.bytes == 0 && piece.header && piece.commit && piece.last)
	testing.expect_value(t, piece.size, file_size_of_slot(1, 60))
	testing.expect(t, keep_piece_written(&state, piece))
	// A refused piece ends the keep, and its rows wait for the next one.
	changed_rows_add(&state.rows, {0, 2, 10, 8}, 20)
	keep_begin(&state, 40, 40)
	keep_refused(&state, 30, 40)
	testing.expect(t, !state.keeping && state.rows.whole && state.rows.changed)
	testing.expect_value(t, keep_step(&state, 30 + KEEP_RETRY_MILLISECONDS, false, false), Keep_Step.Keep)
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