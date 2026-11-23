// The picture of the paint application with no window and no store: its
// pixels and its extent, the tools that change it, the fill, the history of
// undo and redo, the picture file, the names of the pictures and the
// colors. Each procedure works in the memory of the caller, so a host test
// drives each one on a picture of its own
// (src/md/features/paint_application.md).
package paint_model

import "base:intrinsics"
import "modus:contract/lz4"
import "modus:graphics"

// The largest picture: the logical screen of the reference screen. The
// pixels of a picture are one array of this size; the extent is the part in
// use, so a resize never moves a pixel.
PICTURE_WIDTH_LIMIT :: 1536
PICTURE_HEIGHT_LIMIT :: 864
PICTURE_PIXELS :: PICTURE_WIDTH_LIMIT * PICTURE_HEIGHT_LIMIT
PICTURE_BYTES :: PICTURE_PIXELS * size_of(graphics.Color)

COLOR_PAPER :: graphics.Color(0xF4F1EA) // The color of a clean picture, and of the eraser.

// A picture: its pixels, PICTURE_WIDTH_LIMIT to a row, and its extent.
Picture :: struct {
	pixels:     []graphics.Color, // PICTURE_PIXELS pixels, in the memory of the caller.
	width:      int, // The extent: 0 to PICTURE_WIDTH_LIMIT.
	height:     int, // 0 to PICTURE_HEIGHT_LIMIT.
	generation: u32, // Changes at each change of the pixels: the Picture record draws again.
}

// A rectangle of the picture: left and top included, right and bottom
// excluded. An empty box has right <= left or bottom <= top.
Box :: struct {
	left, top, right, bottom: int,
}

box_empty :: proc "contextless" (box: Box) -> bool {
	return box.right <= box.left || box.bottom <= box.top
}

// box_union gives the smallest box that holds two boxes; an empty box adds
// nothing.
box_union :: proc "contextless" (first, second: Box) -> Box {
	if box_empty(first) {
		return second
	}
	if box_empty(second) {
		return first
	}
	return {min(first.left, second.left), min(first.top, second.top), max(first.right, second.right), max(first.bottom, second.bottom)}
}

// box_cut gives the part of a box inside the extent of a picture.
box_cut :: proc "contextless" (picture: ^Picture, box: Box) -> Box {
	cut := Box{max(box.left, 0), max(box.top, 0), min(box.right, picture.width), min(box.bottom, picture.height)}
	if box_empty(cut) {
		return {}
	}
	return cut
}

// picture_canvas gives the extent of a picture as a canvas of the graphics
// package: each procedure of that package cuts what it draws to it.
picture_canvas :: proc "contextless" (picture: ^Picture) -> graphics.Canvas {
	return {pixels = raw_data(picture.pixels), width = picture.width, height = picture.height, stride = PICTURE_WIDTH_LIMIT}
}

// picture_changed marks a change of the pixels.
picture_changed :: proc "contextless" (picture: ^Picture) {
	picture.generation += 1
}

// picture_valid says if the memory of a picture holds the largest picture.
picture_valid :: proc "contextless" (picture: ^Picture) -> bool {
	return len(picture.pixels) >= PICTURE_PIXELS
}

// picture_clear paints the whole array with the paper and keeps the
// extent.
picture_clear :: proc "contextless" (picture: ^Picture) {
	for &pixel in picture.pixels[:PICTURE_PIXELS] {
		pixel = COLOR_PAPER
	}
	picture_changed(picture)
}

// picture_extend grows the extent to hold a width and a height, cut to the
// largest picture. It never makes the extent smaller: the pixels outside a
// smaller window stay. The pixels that join the extent are paper. It gives
// true when the extent grew.
picture_extend :: proc "contextless" (picture: ^Picture, width, height: int) -> bool {
	new_width := clamp(width, picture.width, PICTURE_WIDTH_LIMIT)
	new_height := clamp(height, picture.height, PICTURE_HEIGHT_LIMIT)
	if new_width == picture.width && new_height == picture.height {
		return false
	}
	whole := graphics.Canvas{pixels = raw_data(picture.pixels), width = PICTURE_WIDTH_LIMIT, height = PICTURE_HEIGHT_LIMIT, stride = PICTURE_WIDTH_LIMIT}
	// The new columns of the rows of before, then the new rows.
	graphics.fill(whole, picture.width, 0, new_width - picture.width, picture.height, COLOR_PAPER)
	graphics.fill(whole, 0, picture.height, new_width, new_height - picture.height, COLOR_PAPER)
	picture.width, picture.height = new_width, new_height
	picture_changed(picture)
	return true
}

// picture_copy copies the pixels of a box from one picture array to
// another: the backup of a change, and its undo.
picture_copy_box :: proc "contextless" (to, from: []graphics.Color, box: Box) {
	if box_empty(box) {
		return
	}
	for row in box.top ..< box.bottom {
		start := row * PICTURE_WIDTH_LIMIT + box.left
		intrinsics.mem_copy_non_overlapping(&to[start], &from[start], (box.right - box.left) * size_of(graphics.Color))
	}
}

// The tools.

Tool :: enum u8 {
	Brush     = 0,
	Eraser    = 1,
	Line      = 2,
	Rectangle = 3,
	Ellipse   = 4,
	Fill      = 5,
}

@(rodata)
TOOL_NAMES := [Tool]string {
	.Brush     = "brush",
	.Eraser    = "eraser",
	.Line      = "line",
	.Rectangle = "rectangle",
	.Ellipse   = "ellipse",
	.Fill      = "fill",
}

// The sizes of a brush, in pixels: each step is visible, and the list is
// short.
@(rodata)
BRUSH_SIZES := [8]int{1, 2, 3, 5, 8, 13, 21, 34}

// size_index_step moves the index of a size by a step and stops at the two
// ends.
size_index_step :: proc "contextless" (index, step: int) -> int {
	// Each part is cut first: a sum with the largest int would wrap.
	return clamp(clamp(index, 0, len(BRUSH_SIZES) - 1) + clamp(step, -len(BRUSH_SIZES), len(BRUSH_SIZES)), 0, len(BRUSH_SIZES) - 1)
}

// stroke_box gives the box that a square brush of a size covers along a
// segment, before the cut to the picture.
stroke_box :: proc "contextless" (from_x, from_y, to_x, to_y, size: int) -> Box {
	half := size / 2
	return {min(from_x, to_x) - half, min(from_y, to_y) - half, max(from_x, to_x) - half + size, max(from_y, to_y) - half + size}
}

// The ends of a segment are cut to this distance outside the picture: the
// cost of a line grows with its length, and the visible part does not
// change.
COORDINATE_LIMIT :: 4096

// segment_draw draws a segment with a square brush of a size and gives the
// box that changed, inside the picture.
segment_draw :: proc "contextless" (picture: ^Picture, from_x, from_y, to_x, to_y, size: int, color: graphics.Color) -> Box {
	limit :: COORDINATE_LIMIT
	x0, y0 := clamp(from_x, -limit, limit), clamp(from_y, -limit, limit)
	x1, y1 := clamp(to_x, -limit, limit), clamp(to_y, -limit, limit)
	thickness := max(size, 1)
	box := box_cut(picture, stroke_box(x0, y0, x1, y1, thickness))
	if box_empty(box) {
		return {}
	}
	graphics.line(picture_canvas(picture), x0, y0, x1, y1, thickness, color)
	picture_changed(picture)
	return box
}

// shape_box gives the box of a shape between two corners that the pointer
// gave in any order, both corners included.
shape_box :: proc "contextless" (from_x, from_y, to_x, to_y: int) -> Box {
	return {min(from_x, to_x), min(from_y, to_y), max(from_x, to_x) + 1, max(from_y, to_y) + 1}
}

// rectangle_draw draws the border of a rectangle between two corners, its
// thickness inside the rectangle, and gives the box that changed.
rectangle_draw :: proc "contextless" (picture: ^Picture, from_x, from_y, to_x, to_y, thickness: int, color: graphics.Color) -> Box {
	shape := shape_box(from_x, from_y, to_x, to_y)
	box := box_cut(picture, shape)
	if box_empty(box) {
		return {}
	}
	width, height := shape.right - shape.left, shape.bottom - shape.top
	graphics.outline(picture_canvas(picture), shape.left, shape.top, width, height, clamp(thickness, 1, max(min(width, height), 1)), color)
	picture_changed(picture)
	return box
}

// ellipse_draw draws the border of the ellipse inside the box of two
// corners, its thickness inside the box, row by row: each row fills the
// columns between the inner and the outer ellipse. It gives the box that
// changed.
ellipse_draw :: proc "contextless" (picture: ^Picture, from_x, from_y, to_x, to_y, thickness: int, color: graphics.Color) -> Box {
	shape := shape_box(from_x, from_y, to_x, to_y)
	box := box_cut(picture, shape)
	if box_empty(box) {
		return {}
	}
	canvas := picture_canvas(picture)
	center_x := f64(shape.left + shape.right) / 2
	center_y := f64(shape.top + shape.bottom) / 2
	outer_x := f64(shape.right - shape.left) / 2
	outer_y := f64(shape.bottom - shape.top) / 2
	inner_x := outer_x - f64(max(thickness, 1))
	inner_y := outer_y - f64(max(thickness, 1))
	for row in box.top ..< box.bottom {
		across := f64(row) + 0.5 - center_y
		if abs(across) > outer_y {
			continue
		}
		outer_half := outer_x * intrinsics.sqrt(max(1 - (across / outer_y) * (across / outer_y), 0))
		left := int(center_x - outer_half + 0.5)
		right := int(center_x + outer_half + 0.5)
		if inner_x <= 0 || inner_y <= 0 || abs(across) >= inner_y {
			graphics.fill(canvas, left, row, right - left, 1, color)
			continue
		}
		inner_half := inner_x * intrinsics.sqrt(max(1 - (across / inner_y) * (across / inner_y), 0))
		inner_left := int(center_x - inner_half + 0.5)
		inner_right := int(center_x + inner_half + 0.5)
		// A border is at least one pixel on each side.
		graphics.fill(canvas, left, row, max(inner_left - left, 1), 1, color)
		graphics.fill(canvas, min(inner_right, right - 1), row, max(right - inner_right, 1), 1, color)
	}
	picture_changed(picture)
	return box
}

// The fill.

FILL_STACK_CAPACITY :: 16384 // The seeds that the fill keeps at once; past it, a scan of the visited pixels finds the rest.
VISITED_WORDS :: (PICTURE_PIXELS + 63) / 64

// The memory of a fill, which the caller keeps: the bitmap of the pixels
// that the fill reached, and the stack of its seeds.
Fill_Memory :: struct {
	visited:      [VISITED_WORDS]u64,
	stack:        [FILL_STACK_CAPACITY][2]i32,
	stack_count:  int,
	overflowed:   bool, // A seed found no room: a scan of the visited pixels must follow.
	scans:        int, // The scans of the visited pixels of the last fill: a measure of the cost.
}

@(private)
visited_get :: #force_inline proc "contextless" (memory: ^Fill_Memory, index: int) -> bool {
	return memory.visited[index >> 6] & (u64(1) << uint(index & 63)) != 0
}

@(private)
visited_set :: #force_inline proc "contextless" (memory: ^Fill_Memory, index: int) {
	memory.visited[index >> 6] |= u64(1) << uint(index & 63)
}

@(private)
seed_push :: proc "contextless" (memory: ^Fill_Memory, x, y: int) {
	if memory.stack_count >= FILL_STACK_CAPACITY {
		memory.overflowed = true
		return
	}
	memory.stack[memory.stack_count] = {i32(x), i32(y)}
	memory.stack_count += 1
}

// fill_region paints the 4-connected region of one color that holds a
// point with another color, and gives the box that changed. A point
// outside the picture, and a region that has the color already, change
// nothing: the box is empty.
fill_region :: proc "contextless" (picture: ^Picture, x, y: int, color: graphics.Color, memory: ^Fill_Memory) -> Box {
	if x < 0 || y < 0 || x >= picture.width || y >= picture.height {
		return {}
	}
	pixels := picture.pixels
	target := pixels[y * PICTURE_WIDTH_LIMIT + x]
	if target == color {
		return {}
	}
	memory.visited = {}
	memory.stack_count, memory.overflowed, memory.scans = 0, false, 0
	changed: Box
	seed_push(memory, x, y)
	// The pixel at index is in the region and not reached yet.
	open :: #force_inline proc "contextless" (pixels: []graphics.Color, memory: ^Fill_Memory, index: int, target: graphics.Color) -> bool {
		return pixels[index] == target && !visited_get(memory, index)
	}
	for {
		for memory.stack_count > 0 {
			memory.stack_count -= 1
			seed := memory.stack[memory.stack_count]
			seed_x, seed_y := int(seed[0]), int(seed[1])
			row := seed_y * PICTURE_WIDTH_LIMIT
			if !open(pixels, memory, row + seed_x, target) {
				continue
			}
			left, right := seed_x, seed_x
			for left > 0 && open(pixels, memory, row + left - 1, target) {
				left -= 1
			}
			for right + 1 < picture.width && open(pixels, memory, row + right + 1, target) {
				right += 1
			}
			for column in left ..= right {
				visited_set(memory, row + column)
				pixels[row + column] = color
			}
			changed = box_union(changed, {left, seed_y, right + 1, seed_y + 1})
			// One seed for each run of the region in the rows above and
			// below the span.
			for next_y in ([2]int{seed_y - 1, seed_y + 1}) {
				if next_y < 0 || next_y >= picture.height {
					continue
				}
				next_row := next_y * PICTURE_WIDTH_LIMIT
				in_run := false
				for column in left ..= right {
					if open(pixels, memory, next_row + column, target) {
						if !in_run {
							seed_push(memory, column, next_y)
						}
						in_run = true
					} else {
						in_run = false
					}
				}
			}
		}
		if !memory.overflowed {
			break
		}
		// The stack was full: a seed was lost. Each pixel of the region
		// that was not reached touches a reached one, so a scan of the
		// reached pixels finds a seed of each part that is left.
		memory.overflowed = false
		memory.scans += 1
		for row_index in changed.top ..< changed.bottom {
			for column in changed.left ..< changed.right {
				index := row_index * PICTURE_WIDTH_LIMIT + column
				if !visited_get(memory, index) {
					continue
				}
				if column > 0 && open(pixels, memory, index - 1, target) {
					seed_push(memory, column - 1, row_index)
				}
				if column + 1 < picture.width && open(pixels, memory, index + 1, target) {
					seed_push(memory, column + 1, row_index)
				}
				if row_index > 0 && open(pixels, memory, index - PICTURE_WIDTH_LIMIT, target) {
					seed_push(memory, column, row_index - 1)
				}
				if row_index + 1 < picture.height && open(pixels, memory, index + PICTURE_WIDTH_LIMIT, target) {
					seed_push(memory, column, row_index + 1)
				}
			}
		}
		if memory.stack_count == 0 {
			break
		}
	}
	picture_changed(picture)
	return changed
}
// The history of undo and redo.

HISTORY_BYTES :: 1024 * 1024 // The arena of the compressed rectangles.
HISTORY_STEPS_LIMIT :: 64 // The changes that the history keeps.
// The rows of a box that one LZ4 block holds: a step is a list of blocks of
// strips, so the scratch of a step is one strip, never a whole picture.
HISTORY_STRIP_ROWS :: 32
HISTORY_STRIP_PIXELS :: HISTORY_STRIP_ROWS * PICTURE_WIDTH_LIMIT
HISTORY_STRIP_BYTES :: HISTORY_STRIP_PIXELS * size_of(graphics.Color)
// The bytes before each block in the arena: its length, a little-endian u32.
HISTORY_BLOCK_HEAD_BYTES :: 4

// One change of the picture: its box, and the pixels of the box before and
// after it, each a list of LZ4 blocks of strips in the arena.
History_Step :: struct {
	box:          Box,
	offset:       int, // The first byte of the step in the arena: the blocks before, then the blocks after.
	before_bytes: int,
	after_bytes:  int,
}

// The history: the steps in their order, the oldest first. The steps
// before the place done are applied, and undo takes the last of them; the
// steps from done are undone, and redo takes the first of them. The arena
// is in the memory of the caller; the bytes of the steps follow each other
// from its start.
History :: struct {
	arena: []u8, // HISTORY_BYTES bytes.
	steps: [HISTORY_STEPS_LIMIT]History_Step,
	count: int,
	done:  int,
	used:  int, // The bytes of the arena in use.
}

// The memory that a strip needs on its way into and out of the arena,
// which the caller keeps: the pixels of one strip, and its compressed form.
History_Scratch :: struct {
	pixels:     [HISTORY_STRIP_PIXELS]graphics.Color,
	compressed: [HISTORY_STRIP_BYTES + HISTORY_STRIP_BYTES / 255 + 16]u8,
	hash_table: lz4.Hash_Table,
}

Record_Outcome :: enum u8 {
	Kept      = 0, // The change can be undone.
	Empty     = 1, // The box is empty: no change to keep.
	Too_Large = 2, // The change does not fit in the arena alone: the history is cleared, and the change cannot be undone.
}

history_clear :: proc "contextless" (history: ^History) {
	history.count, history.done, history.used = 0, 0, 0
}

history_can_undo :: proc "contextless" (history: ^History) -> bool {
	return history.done > 0
}

history_can_redo :: proc "contextless" (history: ^History) -> bool {
	return history.done < history.count
}

// box_pack copies the pixels of a box of a picture array into one block,
// row after row, and gives its bytes.
@(private)
box_pack :: proc "contextless" (pixels: []graphics.Color, box: Box, block: []graphics.Color) -> []u8 {
	width := box.right - box.left
	for row in box.top ..< box.bottom {
		intrinsics.mem_copy_non_overlapping(&block[(row - box.top) * width], &pixels[row * PICTURE_WIDTH_LIMIT + box.left], width * size_of(graphics.Color))
	}
	count := width * (box.bottom - box.top)
	return ([^]u8)(raw_data(block))[:count * size_of(graphics.Color)]
}

// box_unpack copies one block into the pixels of a box of a picture array.
@(private)
box_unpack :: proc "contextless" (pixels: []graphics.Color, box: Box, block: []graphics.Color) {
	width := box.right - box.left
	for row in box.top ..< box.bottom {
		intrinsics.mem_copy_non_overlapping(&pixels[row * PICTURE_WIDTH_LIMIT + box.left], &block[(row - box.top) * width], width * size_of(graphics.Color))
	}
}

// strip_of gives the strip of a box from its row top: HISTORY_STRIP_ROWS
// rows, or the rows left.
@(private)
strip_of :: proc "contextless" (box: Box, top: int) -> Box {
	return {box.left, top, box.right, min(top + HISTORY_STRIP_ROWS, box.bottom)}
}

// history_part_write writes the pixels of a box as the blocks of its strips
// at a place of the arena, and gives their bytes. ok is false when a block
// does not fit in the arena past that place.
@(private)
history_part_write :: proc "contextless" (history: ^History, pixels: []graphics.Color, box: Box, offset: int, scratch: ^History_Scratch) -> (bytes: int, ok: bool) {
	at := offset
	for top := box.top; top < box.bottom; top += HISTORY_STRIP_ROWS {
		written, refused := lz4.compress_block(box_pack(pixels, strip_of(box, top), scratch.pixels[:]), scratch.compressed[:], &scratch.hash_table)
		if refused != .None || at + HISTORY_BLOCK_HEAD_BYTES + written > len(history.arena) {
			return 0, false
		}
		word_write(history.arena, at, u32(written))
		intrinsics.mem_copy_non_overlapping(&history.arena[at + HISTORY_BLOCK_HEAD_BYTES], raw_data(scratch.compressed[:]), written)
		at += HISTORY_BLOCK_HEAD_BYTES + written
	}
	return at - offset, true
}

// history_drop_oldest removes the oldest step and moves the bytes of the
// others to the start of the arena. It gives the bytes that it freed.
@(private)
history_drop_oldest :: proc "contextless" (history: ^History) -> (freed: int) {
	if history.count == 0 {
		return 0
	}
	first := history.steps[0]
	freed = first.before_bytes + first.after_bytes
	// One step can fill the arena exactly: then nothing follows it, and
	// the place after it is past the arena.
	if history.used > freed {
		intrinsics.mem_copy(raw_data(history.arena), &history.arena[freed], history.used - freed)
	}
	history.used -= freed
	for index in 1 ..< history.count {
		step := history.steps[index]
		step.offset -= freed
		history.steps[index - 1] = step
	}
	history.count -= 1
	history.done = max(history.done - 1, 0)
	return freed
}

// history_record keeps a change of the picture: the pixels of a box before
// it, from a copy of the picture made before the change, and after it,
// from the picture. The steps that redo would give are removed first; the
// oldest steps go when the new one needs their room.
history_record :: proc "contextless" (history: ^History, before, after: []graphics.Color, box: Box, scratch: ^History_Scratch) -> Record_Outcome {
	if box_empty(box) {
		return .Empty
	}
	history.count = history.done
	history.used = 0
	if history.count > 0 {
		last := history.steps[history.count - 1]
		history.used = last.offset + last.before_bytes + last.after_bytes
	}
	for history.count >= HISTORY_STEPS_LIMIT {
		history_drop_oldest(history)
	}
	// The blocks go past the bytes in use; when they do not fit, the
	// oldest step goes and the blocks are written again at the new end.
	for {
		offset := history.used
		before_bytes, before_ok := history_part_write(history, before, box, offset, scratch)
		if before_ok {
			after_bytes, after_ok := history_part_write(history, after, box, offset + before_bytes, scratch)
			if after_ok {
				history.steps[history.count] = {box = box, offset = offset, before_bytes = before_bytes, after_bytes = after_bytes}
				history.count += 1
				history.done = history.count
				history.used = offset + before_bytes + after_bytes
				return .Kept
			}
		}
		if history.count == 0 {
			history_clear(history)
			return .Too_Large
		}
		history_drop_oldest(history)
	}
}

// history_part_apply writes the blocks of one part of a step into the
// picture. Each block is checked first: a block that does not give the
// pixels of its strip refuses the whole part, and the picture does not
// change.
@(private)
history_part_apply :: proc "contextless" (picture: ^Picture, box: Box, part: []u8, scratch: ^History_Scratch) -> bool {
	if box_empty(box) || box.left < 0 || box.top < 0 || box.right > PICTURE_WIDTH_LIMIT || box.bottom > PICTURE_HEIGHT_LIMIT {
		return false
	}
	strip_bytes := ([^]u8)(raw_data(scratch.pixels[:]))[:HISTORY_STRIP_BYTES]
	for pass in 0 ..< 2 {
		at := 0
		for top := box.top; top < box.bottom; top += HISTORY_STRIP_ROWS {
			strip := strip_of(box, top)
			if at + HISTORY_BLOCK_HEAD_BYTES > len(part) {
				return false
			}
			length := int(word_read(part, at))
			at += HISTORY_BLOCK_HEAD_BYTES
			if length > len(part) - at {
				return false
			}
			wanted := (strip.right - strip.left) * (strip.bottom - strip.top) * size_of(graphics.Color)
			written, refused := lz4.decompress_block(part[at:][:length], strip_bytes)
			if refused != .None || written != wanted {
				return false
			}
			at += length
			if pass == 1 {
				box_unpack(picture.pixels, strip, scratch.pixels[:])
			}
		}
		if at != len(part) {
			return false
		}
		if pass == 0 {
			// The extent never shrinks while the history lives, so the box
			// is in it; grow it first in each case: a growth paints paper,
			// which must not cover the pixels that the step writes.
			picture_extend(picture, box.right, box.bottom)
		}
	}
	picture_changed(picture)
	return true
}

// history_undo puts back the pixels before the last applied change. false:
// no change to undo, or a damaged block; nothing changed.
history_undo :: proc "contextless" (history: ^History, picture: ^Picture, scratch: ^History_Scratch) -> bool {
	if history.done == 0 {
		return false
	}
	step := history.steps[history.done - 1]
	if !history_part_apply(picture, step.box, history.arena[step.offset:][:step.before_bytes], scratch) {
		return false
	}
	history.done -= 1
	return true
}

// history_redo applies again the first undone change. false: no change to
// redo, or a damaged block; nothing changed.
history_redo :: proc "contextless" (history: ^History, picture: ^Picture, scratch: ^History_Scratch) -> bool {
	if history.done >= history.count {
		return false
	}
	step := history.steps[history.done]
	if !history_part_apply(picture, step.box, history.arena[step.offset + step.before_bytes:][:step.after_bytes], scratch) {
		return false
	}
	history.done += 1
	return true
}

// The picture file: a header of FILE_HEADER_BYTES, then the rows of the
// picture, FILE_ROW_PIXELS pixels each, 4 bytes for a pixel (0x00RRGGBB,
// little endian), from row 0 to the height. A row of the picture is at one
// place of the file whatever the extent: a keep writes the rows that
// changed, and the store keeps the other blocks (src/md/features/
// paint_application.md, "The keep writes the changed rows").
//
//   offset  size  field
//        0     4  the magic "MPIC"
//        4     4  the version, 2
//        8     4  the width: 1 to PICTURE_WIDTH_LIMIT
//       12     4  the height: 1 to PICTURE_HEIGHT_LIMIT
//       16     4  the pixels of a row of the file: FILE_ROW_PIXELS
FILE_MAGIC :: "MPIC"
FILE_VERSION :: u32(2)
FILE_HEADER_BYTES :: 20
FILE_ROW_PIXELS :: PICTURE_WIDTH_LIMIT
FILE_ROW_BYTES :: FILE_ROW_PIXELS * size_of(graphics.Color)
FILE_BYTES_LIMIT :: FILE_HEADER_BYTES + PICTURE_HEIGHT_LIMIT * FILE_ROW_BYTES

File_Problem :: enum u8 {
	None        = 0, // The file is read.
	Too_Short   = 1, // The file is shorter than its header.
	Bad_Magic   = 2, // The first 4 bytes are not "MPIC".
	Bad_Version = 3, // The version is not FILE_VERSION.
	Bad_Size    = 4, // The width or the height is 0 or past the largest picture.
	Bad_Row     = 5, // A row of the file is not FILE_ROW_PIXELS pixels.
	Bad_Length  = 6, // The file is not the header and the rows of its height.
	Bad_Pixel   = 7, // A pixel has a top byte that is not 0.
	Bad_Margin  = 8, // A pixel past the width is not paper: a row of the file holds only paper past the width.
}

@(private)
word_read :: proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset]) | u32(bytes[offset + 1]) << 8 | u32(bytes[offset + 2]) << 16 | u32(bytes[offset + 3]) << 24
}

@(private)
word_write :: proc "contextless" (bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value)
	bytes[offset + 1] = u8(value >> 8)
	bytes[offset + 2] = u8(value >> 16)
	bytes[offset + 3] = u8(value >> 24)
}

// file_size gives the bytes of the file of a picture of a height.
file_size :: proc "contextless" (height: int) -> int {
	return FILE_HEADER_BYTES + clamp(height, 0, PICTURE_HEIGHT_LIMIT) * FILE_ROW_BYTES
}

// file_row_offset gives the place of a row in the file.
file_row_offset :: proc "contextless" (row: int) -> int {
	return FILE_HEADER_BYTES + row * FILE_ROW_BYTES
}

// file_header_write writes the header of a picture into the first
// FILE_HEADER_BYTES of a buffer. ok is false for an empty extent or a
// buffer too small.
file_header_write :: proc "contextless" (picture: ^Picture, bytes: []u8) -> (header: []u8, ok: bool) {
	if picture.width <= 0 || picture.height <= 0 || len(bytes) < FILE_HEADER_BYTES {
		return nil, false
	}
	copy(bytes[:4], FILE_MAGIC)
	word_write(bytes, 4, FILE_VERSION)
	word_write(bytes, 8, u32(picture.width))
	word_write(bytes, 12, u32(picture.height))
	word_write(bytes, 16, u32(FILE_ROW_PIXELS))
	return bytes[:FILE_HEADER_BYTES], true
}

// file_rows_copy copies the rows top ..< bottom of a picture into a buffer,
// as the file holds them, and gives their bytes. ok is false for rows
// outside the extent or a buffer too small.
file_rows_copy :: proc "contextless" (picture: ^Picture, top, bottom: int, bytes: []u8) -> (rows: []u8, ok: bool) {
	if top < 0 || bottom > picture.height || top >= bottom || len(bytes) < (bottom - top) * FILE_ROW_BYTES {
		return nil, false
	}
	count := (bottom - top) * FILE_ROW_BYTES
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), &picture.pixels[top * PICTURE_WIDTH_LIMIT], count)
	return bytes[:count], true
}

// picture_encode writes the whole file of a picture: the header and each
// row of its extent. The first keep of a new picture writes it.
picture_encode :: proc "contextless" (picture: ^Picture, file: []u8) -> (bytes: []u8, ok: bool) {
	if _, header_ok := file_header_write(picture, file); !header_ok {
		return nil, false
	}
	if _, rows_ok := file_rows_copy(picture, 0, picture.height, file[FILE_HEADER_BYTES:]); !rows_ok {
		return nil, false
	}
	return file[:file_size(picture.height)], true
}

// picture_decode reads a file into a picture. Each field and each pixel is
// checked before any pixel changes: on a problem, the picture is as before.
// On success the extent is the size of the file, and the pixels outside it
// are paper.
picture_decode :: proc "contextless" (file: []u8, picture: ^Picture) -> File_Problem {
	if len(file) < FILE_HEADER_BYTES {
		return .Too_Short
	}
	return picture_decode_parts(file[:FILE_HEADER_BYTES], file[FILE_HEADER_BYTES:], picture)
}

// picture_decode_parts reads a file whose header and rows are in two
// buffers: a read puts the rows in memory of the size of a picture, and
// the header apart. The rows may be in the pixels of another picture, never
// in the pixels of this one.
picture_decode_parts :: proc "contextless" (header, rows: []u8, picture: ^Picture) -> File_Problem {
	if len(header) < FILE_HEADER_BYTES {
		return .Too_Short
	}
	if string(header[:4]) != FILE_MAGIC {
		return .Bad_Magic
	}
	if word_read(header, 4) != FILE_VERSION {
		return .Bad_Version
	}
	width, height := int(word_read(header, 8)), int(word_read(header, 12))
	if width < 1 || width > PICTURE_WIDTH_LIMIT || height < 1 || height > PICTURE_HEIGHT_LIMIT {
		return .Bad_Size
	}
	if word_read(header, 16) != u32(FILE_ROW_PIXELS) {
		return .Bad_Row
	}
	if len(header) != FILE_HEADER_BYTES || len(rows) != height * FILE_ROW_BYTES {
		return .Bad_Length
	}
	// The top byte of each pixel, little endian: the fourth byte of each
	// four. A pixel of the screen has none.
	for place := 3; place < len(rows); place += 4 {
		if rows[place] != 0 {
			return .Bad_Pixel
		}
	}
	// Past the width, a row holds paper: a keep writes the whole row, and
	// the window paints paper there.
	for row in 0 ..< height {
		for column in width ..< FILE_ROW_PIXELS {
			if graphics.Color(word_read(rows, (row * FILE_ROW_PIXELS + column) * 4)) != COLOR_PAPER {
				return .Bad_Margin
			}
		}
	}
	for &pixel in picture.pixels[:PICTURE_PIXELS] {
		pixel = COLOR_PAPER
	}
	intrinsics.mem_copy_non_overlapping(raw_data(picture.pixels), raw_data(rows), len(rows))
	picture.width, picture.height = width, height
	picture_changed(picture)
	return .None
}

// The keep of the changed rows.

KEEP_PAUSE_MILLISECONDS :: 1000 // The pause of the changes after which the picture is kept.

// The rows of the picture that changed since the last keep, and when.
Changed_Rows :: struct {
	top, bottom:  int, // The band of changed rows: top included, bottom excluded. Empty when bottom <= top.
	changed:      bool, // A change waits for a keep.
	whole:        bool, // The object has none of the rows yet: the keep writes all of them.
	last_change:  u64, // The time of the system of the last change, in milliseconds.
}

// changed_rows_add adds the rows of a box to the band, at a time of the
// system. An empty box changes nothing.
changed_rows_add :: proc "contextless" (rows: ^Changed_Rows, box: Box, now: u64) {
	if box_empty(box) {
		return
	}
	if rows.bottom <= rows.top {
		rows.top, rows.bottom = box.top, box.bottom
	} else {
		rows.top, rows.bottom = min(rows.top, box.top), max(rows.bottom, box.bottom)
	}
	rows.changed = true
	rows.last_change = now
}

// changed_rows_mark marks a change of the header alone: a wider extent
// changes no byte of a row of the file, only its width.
changed_rows_mark :: proc "contextless" (rows: ^Changed_Rows, now: u64) {
	rows.changed = true
	rows.last_change = now
}

// keep_due says if the changes wait for a keep at a time of the system: a
// pause of KEEP_PAUSE_MILLISECONDS since the last one. A time before the
// last change is no pause.
keep_due :: proc "contextless" (rows: ^Changed_Rows, now: u64) -> bool {
	return rows.changed && now >= rows.last_change && now - rows.last_change >= KEEP_PAUSE_MILLISECONDS
}

// keep_band gives the rows that a keep writes, cut to the height of the
// picture: all of them for an object that has none yet.
keep_band :: proc "contextless" (rows: ^Changed_Rows, height: int) -> (top, bottom: int) {
	if rows.whole {
		return 0, height
	}
	return clamp(rows.top, 0, height), clamp(rows.bottom, 0, height)
}

// keep_taken empties the band when a keep took it.
keep_taken :: proc "contextless" (rows: ^Changed_Rows) {
	rows.top, rows.bottom, rows.changed, rows.whole = 0, 0, false, false
}

// The keep of the open picture as a state machine with no store and no
// clock: the window gives it the facts of a turn of its loop, and it says
// which job to ask, when the loop must wake, and whether the picture may
// change (src/md/features/paint_application.md, "The keep is coalesced").

KEEP_RETRY_MILLISECONDS :: 5000 // The wait after a keep that the store refused, before the next try.

// An act of the panel, or of the start: it waits for the keep of the open
// picture before it, except a delete, which keeps nothing.
Store_Pending :: enum u8 {
	None   = 0,
	Read   = 1, // Open a picture of the store.
	New    = 2, // Start a new picture with a name.
	Rename = 3, // Give the open picture a new name.
	Delete = 4, // Remove a picture that is not open.
}

Keep_State :: struct {
	store_open:  bool, // The store is open, and listed.
	named:       bool, // The open picture has a name: it can be kept.
	reading:     bool, // A read of a picture runs, or its result waits: the picture must not change.
	rows:        Changed_Rows,
	pending:     Store_Pending,
	retry_at:    u64, // After a refused keep: no keep before this time of the system.
	// A keep runs as a series of jobs of one piece each: the band that it
	// writes, and the bytes of the band written so far.
	keeping:     bool,
	keep_top:    int,
	keep_bottom: int,
	keep_done:   int,
}

// The bytes of one piece of a keep: a call of the store carries 64 KiB at
// most, with its arguments.
KEEP_PIECE_BYTES :: 32 * 1024
// The bytes of rows between two commits of a keep: the store holds 4 MiB of
// pending changes for all its connections.
KEEP_COMMIT_BYTES :: 1024 * 1024

// A piece of a keep: what the job writes, and whether it commits after.
Keep_Piece :: struct {
	first:  bool, // The first piece: the job writes the header and the size first.
	offset: int, // The place of the piece in the object.
	bytes:  int, // The bytes of rows of the piece, 0 for a band with no row.
	row:    int, // The first byte of the piece in the rows of the picture: row offset in the array.
	commit: bool, // The job commits after the piece.
	last:   bool, // The last piece of the keep.
}

// keep_begin starts a keep of the band of changed rows of a picture of a
// height, and empties the band: a change from now on goes to the next keep.
keep_begin :: proc "contextless" (state: ^Keep_State, height: int) {
	state.keep_top, state.keep_bottom = keep_band(&state.rows, height)
	state.keep_bottom = max(state.keep_bottom, state.keep_top)
	state.keep_done = 0
	state.keeping = true
	keep_taken(&state.rows)
}

// keep_piece gives the next piece of the keep that runs.
keep_piece :: proc "contextless" (state: ^Keep_State) -> Keep_Piece {
	band := (state.keep_bottom - state.keep_top) * FILE_ROW_BYTES
	bytes := clamp(band - state.keep_done, 0, KEEP_PIECE_BYTES)
	after := state.keep_done + bytes
	return {
		first  = state.keep_done == 0,
		offset = file_row_offset(state.keep_top) + state.keep_done,
		bytes  = bytes,
		row    = state.keep_top * FILE_ROW_BYTES + state.keep_done,
		commit = after >= band || after / KEEP_COMMIT_BYTES != state.keep_done / KEEP_COMMIT_BYTES,
		last   = after >= band,
	}
}

// keep_piece_written takes a piece that the store wrote: true when the
// keep is whole.
keep_piece_written :: proc "contextless" (state: ^Keep_State, piece: Keep_Piece) -> (whole: bool) {
	state.keep_done += piece.bytes
	if state.keep_done >= (state.keep_bottom - state.keep_top) * FILE_ROW_BYTES {
		state.keeping = false
		return true
	}
	return false
}

// What the window asks of the store in a turn.
Keep_Step :: enum u8 {
	Nothing = 0, // No job: none is due, or one runs, or the act waits.
	Keep    = 1, // Write the changed rows of the open picture.
	Pending = 2, // Run the act that waits: its keep is done, or it needs none.
}

// keep_step says which job to ask in a turn of the loop. job_running: a job
// of the store runs or waits to be taken. drag_active: the principal is in
// a stroke.
keep_step :: proc "contextless" (state: ^Keep_State, now: u64, job_running, drag_active: bool) -> Keep_Step {
	if !state.store_open || job_running {
		return .Nothing
	}
	// A keep that runs goes on with its next piece before any other act.
	if state.keeping {
		return .Keep
	}
	// A delete removes a picture that is not open: it waits for no keep.
	if state.pending == .Delete {
		return .Pending
	}
	keep_waits := state.named && state.rows.changed
	if keep_waits && now >= state.retry_at && (keep_due(&state.rows, now) || state.pending != .None) {
		return .Keep
	}
	switch state.pending {
	case .None, .Delete:
		return .Nothing
	case .Rename:
		return keep_waits ? .Nothing : .Pending
	case .Read, .New:
		// A read and a new picture replace the picture of a stroke: they
		// wait for its end. A read also takes the copy that a stroke holds
		// for its undo, as the memory of its rows.
		return keep_waits || drag_active ? .Nothing : .Pending
	}
	return .Nothing
}

// keep_wake gives the time at which the loop must wake for the keep, when a
// turn can then ask for it: never while a job runs (its end wakes the loop),
// with no store, or for a picture with no name.
keep_wake :: proc "contextless" (state: ^Keep_State, job_running: bool) -> (time: u64, due: bool) {
	if state.keeping && state.store_open && !job_running {
		return 1, true // The next piece is due at once: a time in the past.
	}
	if !state.store_open || job_running || !state.named || !state.rows.changed {
		return 0, false
	}
	return max(state.rows.last_change + KEEP_PAUSE_MILLISECONDS, state.retry_at), true
}

// keep_refused takes a keep that the store refused: its rows go back to the
// band, the next try waits KEEP_RETRY_MILLISECONDS, and the act that waited
// for it is dropped, which the window says. It gives that act.
keep_refused :: proc "contextless" (state: ^Keep_State, now: u64, height: int) -> (dropped: Store_Pending) {
	state.rows.whole = true
	changed_rows_add(&state.rows, {0, 0, 1, max(height, 1)}, now)
	state.keeping = false
	state.retry_at = now + KEEP_RETRY_MILLISECONDS
	dropped = state.pending
	state.pending = .None
	state.reading = false
	return dropped
}

// change_allowed says if the picture may change now: not while a read of
// another picture runs, whose result would replace the change.
change_allowed :: proc "contextless" (state: ^Keep_State) -> bool {
	return !state.reading
}

// pending_ask asks for an act. false: another act waits already, or the
// store is not open; nothing changes. From the ask of a read to its take,
// the picture must not change: the read replaces it.
pending_ask :: proc "contextless" (state: ^Keep_State, act: Store_Pending) -> bool {
	if !state.store_open || state.pending != .None || act == .None {
		return false
	}
	state.pending = act
	state.reading = act == .Read
	return true
}

// pending_started says that the act that waited is asked of the store (or
// done by the window): a read stays a read until its take.
pending_started :: proc "contextless" (state: ^Keep_State) {
	state.pending = .None
}

// read_taken says that the result of a read is taken: the picture may
// change again.
read_taken :: proc "contextless" (state: ^Keep_State) {
	state.reading = false
}

// The drag of the pointer.

// A change of the picture from the press to the release: it holds a copy
// of the picture before it, for its step of undo.
Drag :: struct {
	active:  bool,
	paper:   bool, // The right button: the color is the paper.
	from_x:  int, // Where the press was, on the picture.
	from_y:  int,
	last_x:  int, // Where the pointer is now, on the picture.
	last_y:  int,
	changed: Box, // The pixels that the change touched so far.
}

// picture_replace_allowed says if the window can replace its picture, or
// change it by an undo, a redo or a clear: never during a drag, whose copy
// of before belongs to the picture that it changes.
picture_replace_allowed :: proc "contextless" (drag: ^Drag) -> bool {
	return !drag.active
}

// The names of the pictures.

NAME_LIMIT :: 32 // The bytes of the longest name.
OBJECT_SUFFIX :: ".picture" // The object of a picture in the private store is its name and this.

Name_Problem :: enum u8 {
	None          = 0,
	Empty         = 1,
	Too_Long      = 2, // More than NAME_LIMIT bytes.
	Bad_Character = 3, // A byte that is not a lowercase letter, a digit, "-" or "_".
}

// name_check says if a text is the name of a picture.
name_check :: proc "contextless" (name: string) -> Name_Problem {
	if len(name) == 0 {
		return .Empty
	}
	if len(name) > NAME_LIMIT {
		return .Too_Long
	}
	for byte in transmute([]u8)name {
		switch byte {
		case 'a' ..= 'z', '0' ..= '9', '-', '_':
		case:
			return .Bad_Character
		}
	}
	return .None
}

// Room for the name of an object: a name and the suffix.
Object_Name :: struct {
	bytes: [NAME_LIMIT + len(OBJECT_SUFFIX)]u8,
	count: int,
}

// object_name gives the object of a picture name, or false for a text that
// is not a name.
object_name :: proc "contextless" (room: ^Object_Name, name: string) -> (object: string, ok: bool) {
	if name_check(name) != .None {
		return "", false
	}
	copy(room.bytes[:], name)
	copy(room.bytes[len(name):], OBJECT_SUFFIX)
	room.count = len(name) + len(OBJECT_SUFFIX)
	return string(room.bytes[:room.count]), true
}

// picture_name_of_object gives the name of a picture from the name of an
// object of the store, or false for an object that is not a picture.
picture_name_of_object :: proc "contextless" (object: string) -> (name: string, ok: bool) {
	if len(object) <= len(OBJECT_SUFFIX) || object[len(object) - len(OBJECT_SUFFIX):] != OBJECT_SUFFIX {
		return "", false
	}
	name = object[:len(object) - len(OBJECT_SUFFIX)]
	if name_check(name) != .None {
		return "", false
	}
	return name, true
}

// first_free_name gives the first name picture-1, picture-2, ... that a
// list of names does not hold, written into a room. ok is false when each
// of the first PICTURE_NAMES_TRIED names is taken.
PICTURE_NAMES_TRIED :: 1000
first_free_name :: proc "contextless" (taken: []string, room: ^[NAME_LIMIT]u8) -> (name: string, ok: bool) {
	for number in 1 ..= PICTURE_NAMES_TRIED {
		count := copy(room[:], "picture-")
		digits: [8]u8
		digit_count := 0
		for rest := number; rest > 0; rest /= 10 {
			digits[len(digits) - 1 - digit_count] = u8('0' + rest % 10)
			digit_count += 1
		}
		count += copy(room[count:], digits[len(digits) - digit_count:])
		candidate := string(room[:count])
		free := true
		for other in taken {
			free &&= other != candidate
		}
		if free {
			return candidate, true
		}
	}
	return "", false
}

// The colors.

PALETTE_COUNT :: 16

// The palette: dark, white, two grays, the hues of the rainbow, two earth
// colors, navy and the paper. The exports name a color by its place here.
@(rodata)
PALETTE := [PALETTE_COUNT]graphics.Color {
	0x202428, 0xFFFFFF, 0x808890, 0xC8CCD0,
	0xD03838, 0xF08030, 0xE0C020, 0x2E9E4A,
	0x30B8A0, 0x2F6FD0, 0x6040C0, 0xC050B0,
	0x8A5A2E, 0xE8B890, 0x0E3A6E, 0xF4F1EA,
}

// The element names of the colors of the palette: a machine test presses
// "red".
@(rodata)
PALETTE_NAMES := [PALETTE_COUNT]string {
	"dark", "white", "gray", "light gray",
	"red", "orange", "yellow", "green",
	"teal", "blue", "violet", "pink",
	"brown", "sand", "navy", "paper",
}

Channel :: enum u8 {
	Red   = 0,
	Green = 1,
	Blue  = 2,
}

@(rodata)
CHANNEL_SHIFTS := [Channel]uint{.Red = 16, .Green = 8, .Blue = 0}

channel_value :: proc "contextless" (color: graphics.Color, channel: Channel) -> u8 {
	return u8(color >> CHANNEL_SHIFTS[channel])
}

channel_set :: proc "contextless" (color: graphics.Color, channel: Channel, value: u8) -> graphics.Color {
	shift := CHANNEL_SHIFTS[channel]
	return color &~ (0xFF << shift) | graphics.Color(value) << shift
}

// channel_step adds a signed step to a channel and stops at 0 and 255.
channel_step :: proc "contextless" (color: graphics.Color, channel: Channel, step: int) -> graphics.Color {
	// The step is cut first: a sum with the largest int would wrap.
	return channel_set(color, channel, u8(clamp(int(channel_value(color, channel)) + clamp(step, -255, 255), 0, 255)))
}

// Room for "#RRGGBB".
Color_Text :: struct {
	bytes: [7]u8,
}

// color_text writes a color as "#RRGGBB", with uppercase digits.
color_text :: proc "contextless" (room: ^Color_Text, color: graphics.Color) -> string {
	digits := "0123456789ABCDEF"
	room.bytes[0] = '#'
	for place in 0 ..< 6 {
		room.bytes[1 + place] = digits[(color >> uint(20 - 4 * place)) & 0xF]
	}
	return string(room.bytes[:])
}

// color_of_text reads "#RRGGBB" or "RRGGBB", with digits of either case. ok
// is false for each other text.
color_of_text :: proc "contextless" (text: string) -> (color: graphics.Color, ok: bool) {
	digits := text
	if len(digits) > 0 && digits[0] == '#' {
		digits = digits[1:]
	}
	if len(digits) != 6 {
		return 0, false
	}
	for byte in transmute([]u8)digits {
		value: graphics.Color
		switch byte {
		case '0' ..= '9':
			value = graphics.Color(byte - '0')
		case 'a' ..= 'f':
			value = graphics.Color(byte - 'a' + 10)
		case 'A' ..= 'F':
			value = graphics.Color(byte - 'A' + 10)
		case:
			return 0, false
		}
		color = color << 4 | value
	}
	return color, true
}