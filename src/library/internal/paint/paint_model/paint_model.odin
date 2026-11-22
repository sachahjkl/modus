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

HISTORY_BYTES :: 4 * 1024 * 1024 // The arena of the compressed rectangles.
HISTORY_STEPS_LIMIT :: 64 // The changes that the history keeps.

// One change of the picture: its box, and the pixels of the box before and
// after it, each an LZ4 block in the arena.
History_Step :: struct {
	box:          Box,
	offset:       int, // The first byte of the step in the arena: the block before, then the block after.
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

// The memory that a step needs on its way into and out of the arena, which
// the caller keeps: the pixels of a box as one block, and its compressed
// form. The compressed form has room for a picture file too, so a caller
// reads and writes a file there with no array of its own.
History_Scratch :: struct {
	pixels:     [PICTURE_PIXELS]graphics.Color,
	compressed: [FILE_BYTES_LIMIT]u8,
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

// history_drop_oldest removes the oldest step and moves the bytes of the
// others to the start of the arena. It gives the bytes that it freed.
@(private)
history_drop_oldest :: proc "contextless" (history: ^History) -> (freed: int) {
	if history.count == 0 {
		return 0
	}
	first := history.steps[0]
	freed = first.before_bytes + first.after_bytes
	intrinsics.mem_copy(raw_data(history.arena), &history.arena[freed], history.used - freed)
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
	before_bytes, refused := lz4.compress_block(box_pack(before, box, scratch.pixels[:]), scratch.compressed[:], &scratch.hash_table)
	if refused != .None || before_bytes > len(history.arena) {
		history_clear(history)
		return .Too_Large
	}
	for history.count > 0 && (history.used + before_bytes > len(history.arena) || history.count >= HISTORY_STEPS_LIMIT) {
		history_drop_oldest(history)
	}
	if history.used + before_bytes > len(history.arena) {
		history_clear(history)
		return .Too_Large
	}
	// The block before waits in the arena past the bytes in use: the
	// scratch then takes the block after.
	offset := history.used
	intrinsics.mem_copy_non_overlapping(&history.arena[offset], raw_data(scratch.compressed[:]), before_bytes)
	after_bytes: int
	after_bytes, refused = lz4.compress_block(box_pack(after, box, scratch.pixels[:]), scratch.compressed[:], &scratch.hash_table)
	for refused == .None && history.count > 0 && offset + before_bytes + after_bytes > len(history.arena) {
		// The drop moves the bytes in use; the block before moves with
		// the room that it freed.
		freed := history_drop_oldest(history)
		intrinsics.mem_copy(&history.arena[offset - freed], &history.arena[offset], before_bytes)
		offset -= freed
	}
	if refused != .None || offset + before_bytes + after_bytes > len(history.arena) {
		history_clear(history)
		return .Too_Large
	}
	intrinsics.mem_copy_non_overlapping(&history.arena[offset + before_bytes], raw_data(scratch.compressed[:]), after_bytes)
	history.steps[history.count] = {box = box, offset = offset, before_bytes = before_bytes, after_bytes = after_bytes}
	history.count += 1
	history.done = history.count
	history.used = offset + before_bytes + after_bytes
	return .Kept
}

// history_step_apply writes one block of a step into the picture. false:
// the block does not give the pixels of its box, and the picture does not
// change.
@(private)
history_step_apply :: proc "contextless" (picture: ^Picture, step: History_Step, block: []u8, scratch: ^History_Scratch) -> bool {
	box := step.box
	if box_empty(box) || box.left < 0 || box.top < 0 || box.right > PICTURE_WIDTH_LIMIT || box.bottom > PICTURE_HEIGHT_LIMIT {
		return false
	}
	wanted := (box.right - box.left) * (box.bottom - box.top) * size_of(graphics.Color)
	written, refused := lz4.decompress_block(block, ([^]u8)(raw_data(scratch.pixels[:]))[:PICTURE_BYTES])
	if refused != .None || written != wanted {
		return false
	}
	box_unpack(picture.pixels, box, scratch.pixels[:])
	// The extent never shrinks while the history lives, so the box is in
	// it; grow it in each case, so the pixels that the step wrote show.
	picture_extend(picture, box.right, box.bottom)
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
	if !history_step_apply(picture, step, history.arena[step.offset:][:step.before_bytes], scratch) {
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
	if !history_step_apply(picture, step, history.arena[step.offset + step.before_bytes:][:step.after_bytes], scratch) {
		return false
	}
	history.done += 1
	return true
}

// The picture file: a header of FILE_HEADER_BYTES, then the LZ4 block of
// the pixels of the extent, row after row, 4 bytes each (0x00RRGGBB, little
// endian).
//
//   offset  size  field
//        0     4  the magic "MPIC"
//        4     4  the version, 1
//        8     4  the width: 1 to PICTURE_WIDTH_LIMIT
//       12     4  the height: 1 to PICTURE_HEIGHT_LIMIT
//       16     4  the bytes of the block: the rest of the file
FILE_MAGIC :: "MPIC"
FILE_VERSION :: u32(1)
FILE_HEADER_BYTES :: 20
FILE_BYTES_LIMIT :: FILE_HEADER_BYTES + PICTURE_BYTES + PICTURE_BYTES / 255 + 16

File_Problem :: enum u8 {
	None        = 0, // The file is read.
	Too_Short   = 1, // The file is shorter than its header.
	Bad_Magic   = 2, // The first 4 bytes are not "MPIC".
	Bad_Version = 3, // The version is not FILE_VERSION.
	Bad_Size    = 4, // The width or the height is 0 or past the largest picture.
	Bad_Length  = 5, // The bytes of the block are not the rest of the file.
	Bad_Block   = 6, // The block is not LZ4, or does not give width x height pixels.
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

// picture_encode writes the file of the extent of a picture into a buffer
// of at least FILE_BYTES_LIMIT bytes, and gives its bytes. ok is false for
// a picture with an empty extent or a buffer too small.
picture_encode :: proc "contextless" (picture: ^Picture, file: []u8, scratch: ^History_Scratch) -> (bytes: []u8, ok: bool) {
	if picture.width <= 0 || picture.height <= 0 || len(file) < FILE_BYTES_LIMIT {
		return nil, false
	}
	block := box_pack(picture.pixels, {0, 0, picture.width, picture.height}, scratch.pixels[:])
	written, refused := lz4.compress_block(block, file[FILE_HEADER_BYTES:], &scratch.hash_table)
	if refused != .None {
		return nil, false
	}
	copy(file[:4], FILE_MAGIC)
	word_write(file, 4, FILE_VERSION)
	word_write(file, 8, u32(picture.width))
	word_write(file, 12, u32(picture.height))
	word_write(file, 16, u32(written))
	return file[:FILE_HEADER_BYTES + written], true
}

// picture_decode reads a file into a picture. The fields are checked
// before any pixel changes: on a problem, the picture is as before. On
// success the extent is the size of the file, and the pixels outside it
// are paper.
picture_decode :: proc "contextless" (file: []u8, picture: ^Picture, scratch: ^History_Scratch) -> File_Problem {
	if len(file) < FILE_HEADER_BYTES {
		return .Too_Short
	}
	if string(file[:4]) != FILE_MAGIC {
		return .Bad_Magic
	}
	if word_read(file, 4) != FILE_VERSION {
		return .Bad_Version
	}
	width, height := int(word_read(file, 8)), int(word_read(file, 12))
	if width < 1 || width > PICTURE_WIDTH_LIMIT || height < 1 || height > PICTURE_HEIGHT_LIMIT {
		return .Bad_Size
	}
	block_bytes := int(word_read(file, 16))
	if block_bytes != len(file) - FILE_HEADER_BYTES {
		return .Bad_Length
	}
	wanted := width * height * size_of(graphics.Color)
	written, refused := lz4.decompress_block(file[FILE_HEADER_BYTES:], ([^]u8)(raw_data(scratch.pixels[:]))[:PICTURE_BYTES])
	if refused != .None || written != wanted {
		return .Bad_Block
	}
	for &pixel in picture.pixels[:PICTURE_PIXELS] {
		pixel = COLOR_PAPER
	}
	box_unpack(picture.pixels, {0, 0, width, height}, scratch.pixels[:])
	picture.width, picture.height = width, height
	picture_changed(picture)
	return .None
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
