// The picture of the paint application with no window and no store: its
// pixels and its extent, the tools that change it, the fill, the history of
// undo and redo, the picture file, the names of the pictures and the
// colors. Each procedure works in the memory of the caller, so a host test
// drives each one on a picture of its own
// (src/md/features/paint_application.md).
package paint_model

import "base:intrinsics"
import "modus:contract/lz4"
import "modus:contract/store"
import "modus:graphics"
import "modus:text_rendering"

// The bounds of a picture. They are bounds of cost of one memory object,
// not a size: the memory of a picture is the caller's, which its budget
// pays, and a picture is as large as that memory
// (src/md/features/paint_application.md, "The memory of a picture").
// - PICTURE_PIXELS_LIMIT: the pixels of one memory object of the largest
//   size (1 GiB of 4 bytes a pixel), so one mapping holds a picture.
// - PICTURE_SIDE_LIMIT: a side, so that a strip of the history holds one
//   row and a product of two sides stays far inside an int.
PICTURE_PIXELS_LIMIT :: 1 << 28
PICTURE_SIDE_LIMIT :: 1 << 16

COLOR_PAPER :: graphics.Color(0xF4F1EA) // The color of a clean picture, and of the eraser.

// A picture: its extent, and its pixels, row after row, width pixels to a
// row. pixels is the memory of the caller: its length is the room, at least
// width x height pixels. The extent never shrinks.
Picture :: struct {
	pixels:     []graphics.Color,
	width:      int, // The extent: 0 to PICTURE_SIDE_LIMIT.
	height:     int, // 0 to PICTURE_SIDE_LIMIT.
	generation: u32, // Changes at each change of the pixels: the Picture record draws again.
	// The copy before the change that runs, or nil: each tool that writes
	// pixels gives it the box that it writes first (picture_touch).
	before:     ^Copy_Before,
}

// The copy before a change, tile by tile (src/md/features/paint_application.md,
// "The copy before a change"): the first write of a change in a tile of
// COPY_TILE_SIDE pixels copies that tile, and a mark says it is copied. The
// marks are reset at the end of the change. So a change copies the tiles
// that it writes, never the whole picture, and a tile that it did not write
// is still the state before it in the picture.
COPY_TILE_SIDE :: 64
// The tiles of the largest picture: a tile for each 64 x 64 pixels, and a
// part tile at the end of each row and column.
COPY_TILE_LIMIT :: PICTURE_PIXELS_LIMIT / (COPY_TILE_SIDE * COPY_TILE_SIDE) + 2 * (PICTURE_SIDE_LIMIT / COPY_TILE_SIDE) + 1

Copy_Before :: struct {
	pixels: []graphics.Color, // The copy: the memory of the caller, of the stride of the picture.
	tiles:  [(COPY_TILE_LIMIT + 63) / 64]u64, // Bit n: tile n is copied for this change.
	first:  int, // The marked tiles are in first to last: the reset clears them.
	last:   int,
	copied: int, // The tiles that the change copied: a measure.
}

// copy_before_touch copies each tile of a box of the picture that the copy
// does not hold yet, and marks it.
copy_before_touch :: proc "contextless" (copy_before: ^Copy_Before, picture: ^Picture, box: Box) {
	cut := box_cut(picture, box)
	width := picture.width
	if box_empty(cut) || picture.height * width > len(copy_before.pixels) {
		return
	}
	if copy_before.copied == 0 {
		copy_before.first, copy_before.last = max(int), -1
	}
	tiles_across := (width + COPY_TILE_SIDE - 1) / COPY_TILE_SIDE
	for tile_row in cut.top / COPY_TILE_SIDE ..= (cut.bottom - 1) / COPY_TILE_SIDE {
		for tile_column in cut.left / COPY_TILE_SIDE ..= (cut.right - 1) / COPY_TILE_SIDE {
			index := tile_row * tiles_across + tile_column
			bit := u64(1) << u64(index % 64)
			if copy_before.tiles[index / 64] & bit != 0 {
				continue
			}
			copy_before.tiles[index / 64] |= bit
			copy_before.first, copy_before.last = min(copy_before.first, index), max(copy_before.last, index)
			copy_before.copied += 1
			picture_copy_box(copy_before.pixels, picture.pixels, width, tile_box(picture, tile_row, tile_column))
		}
	}
}

@(private)
tile_box :: proc "contextless" (picture: ^Picture, tile_row, tile_column: int) -> Box {
	left, top := tile_column * COPY_TILE_SIDE, tile_row * COPY_TILE_SIDE
	return {left, top, min(left + COPY_TILE_SIDE, picture.width), min(top + COPY_TILE_SIDE, picture.height)}
}

// copy_before_restore puts back the part of a box in each tile that the
// copy holds: a change that stops gives back the picture before it. A tile
// that the change did not copy, it did not write.
copy_before_restore :: proc "contextless" (copy_before: ^Copy_Before, picture: ^Picture, box: Box) {
	cut := box_cut(picture, box)
	width := picture.width
	if box_empty(cut) || copy_before.copied == 0 || picture.height * width > len(copy_before.pixels) {
		return
	}
	tiles_across := (width + COPY_TILE_SIDE - 1) / COPY_TILE_SIDE
	for tile_row in cut.top / COPY_TILE_SIDE ..= (cut.bottom - 1) / COPY_TILE_SIDE {
		for tile_column in cut.left / COPY_TILE_SIDE ..= (cut.right - 1) / COPY_TILE_SIDE {
			index := tile_row * tiles_across + tile_column
			if copy_before.tiles[index / 64] & (u64(1) << u64(index % 64)) == 0 {
				continue
			}
			tile := tile_box(picture, tile_row, tile_column)
			part := Box{max(tile.left, cut.left), max(tile.top, cut.top), min(tile.right, cut.right), min(tile.bottom, cut.bottom)}
			picture_copy_box(picture.pixels, copy_before.pixels, width, part)
		}
	}
}

// copy_before_reset clears the marks of the change that ended: the next
// change copies its own tiles.
copy_before_reset :: proc "contextless" (copy_before: ^Copy_Before) {
	if copy_before.copied > 0 {
		for &word in copy_before.tiles[copy_before.first / 64:copy_before.last / 64 + 1] {
			word = 0
		}
	}
	copy_before.copied = 0
}

// picture_touch gives the copy before the change that runs the box that a
// tool writes next.
picture_touch :: #force_inline proc "contextless" (picture: ^Picture, box: Box) {
	if picture.before != nil {
		copy_before_touch(picture.before, picture, box)
	}
}

// picture_pixels_for gives the pixels of a picture of a size, or false for
// a side below 1 or past PICTURE_SIDE_LIMIT, or past PICTURE_PIXELS_LIMIT
// pixels. The sides are checked before the product, so it cannot wrap.
picture_pixels_for :: proc "contextless" (width, height: int) -> (pixels: int, ok: bool) {
	if width < 1 || height < 1 || width > PICTURE_SIDE_LIMIT || height > PICTURE_SIDE_LIMIT {
		return 0, false
	}
	pixels = width * height
	return pixels, pixels <= PICTURE_PIXELS_LIMIT
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
	return {pixels = raw_data(picture.pixels), width = picture.width, height = picture.height, stride = picture.width}
}

// picture_changed marks a change of the pixels.
picture_changed :: proc "contextless" (picture: ^Picture) {
	picture.generation += 1
}

// picture_clear paints the extent with the paper.
picture_clear :: proc "contextless" (picture: ^Picture) {
	picture_clear_band(picture, 0, picture.height)
}

// picture_clear_band paints the rows top to bottom with the paper, through
// the copy before the change that runs: a long clear goes band by band, so
// a cancel stops it between two bands.
picture_clear_band :: proc "contextless" (picture: ^Picture, top, bottom: int) {
	box := box_cut(picture, {0, top, picture.width, bottom})
	if !box_empty(box) {
		picture_touch(picture, box)
		for &pixel in picture.pixels[box.top * picture.width:box.bottom * picture.width] {
			pixel = COLOR_PAPER
		}
	}
	picture_changed(picture)
}

// What picture_extend did.
Extend_Outcome :: enum u8 {
	Unchanged = 0, // The extent holds the size already: a smaller size never shrinks it.
	Grown     = 1, // The extent grew; the pixels that joined it are paper.
	Too_Large = 2, // The size is past the bounds of a picture: nothing changed.
	No_Room   = 3, // The memory of the picture is too small for the size: nothing changed.
}

// picture_extent_for gives the extent that holds the extent of a picture
// and a size: each side the larger of the two.
picture_extent_for :: proc "contextless" (picture: ^Picture, width, height: int) -> (new_width, new_height: int) {
	return max(width, picture.width), max(height, picture.height)
}

// picture_extend grows the extent to hold a width and a height. It never
// makes the extent smaller: the pixels outside a smaller window stay. A
// wider extent moves the rows to the new width, the last row first, so a
// row never covers one that is not moved yet; the pixels that join the
// extent are paper. The caller grows the memory first: picture_pixels_for
// of picture_extent_for gives the room that it needs.
picture_extend :: proc "contextless" (picture: ^Picture, width, height: int) -> Extend_Outcome {
	new_width, new_height := picture_extent_for(picture, width, height)
	if new_width == picture.width && new_height == picture.height {
		return .Unchanged
	}
	pixels, ok := picture_pixels_for(new_width, new_height)
	if !ok {
		return .Too_Large
	}
	if len(picture.pixels) < pixels {
		return .No_Room
	}
	old_width, old_height := picture.width, picture.height
	if new_width != old_width {
		for row := old_height - 1; row >= 0; row -= 1 {
			if row > 0 && old_width > 0 {
				intrinsics.mem_copy(&picture.pixels[row * new_width], &picture.pixels[row * old_width], old_width * size_of(graphics.Color))
			}
			for &pixel in picture.pixels[row * new_width + old_width:][:new_width - old_width] {
				pixel = COLOR_PAPER
			}
		}
	}
	for &pixel in picture.pixels[old_height * new_width:][:(new_height - old_height) * new_width] {
		pixel = COLOR_PAPER
	}
	picture.width, picture.height = new_width, new_height
	picture_changed(picture)
	return .Grown
}

// picture_copy_box copies the pixels of a box from one picture memory to
// another of the same width: the backup of a change, and its undo.
picture_copy_box :: proc "contextless" (to, from: []graphics.Color, width: int, box: Box) {
	if box_empty(box) {
		return
	}
	for row in box.top ..< box.bottom {
		start := row * width + box.left
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
	.Brush     = "Brush",
	.Eraser    = "Eraser",
	.Line      = "Line",
	.Rectangle = "Rectangle",
	.Ellipse   = "Ellipse",
	.Fill      = "Fill",
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

// The ends of a segment are cut to this distance from the corner of the
// picture: the cost of a line grows with its length, and past twice the
// largest side the visible part does not change.
COORDINATE_LIMIT :: 2 * PICTURE_SIDE_LIMIT

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
	if picture.before != nil {
		segment_touch(picture, x0, y0, x1, y1, thickness)
	}
	graphics.line(picture_canvas(picture), x0, y0, x1, y1, thickness, color)
	picture_changed(picture)
	return box
}

// segment_touch gives the copy before the change the tiles that a segment
// writes: it walks the path of graphics.line, step for step, and gathers
// the box of the square of each step; when the box reaches a tile side, it
// gives it, and starts again. So each pixel that the line writes is in a
// box given, and a long diagonal gives the tiles along it, not its box. A
// path computed apart (pieces cut at a division) can round to another row
// than the line, and leave a written tile uncopied.
@(private)
segment_touch :: proc "contextless" (picture: ^Picture, x0, y0, x1, y1, thickness: int) {
	x, y := x0, y0
	distance_x, distance_y := abs(x1 - x0), -abs(y1 - y0)
	step_x := x0 < x1 ? 1 : -1
	step_y := y0 < y1 ? 1 : -1
	error := distance_x + distance_y
	half := thickness / 2
	gathered: Box
	for {
		gathered = box_union(gathered, {x - half, y - half, x - half + thickness, y - half + thickness})
		if gathered.right - gathered.left >= COPY_TILE_SIDE || gathered.bottom - gathered.top >= COPY_TILE_SIDE {
			picture_touch(picture, gathered)
			gathered = {}
		}
		if x == x1 && y == y1 {
			break
		}
		twice := 2 * error
		if twice >= distance_y {
			error += distance_y
			x += step_x
		}
		if twice <= distance_x {
			error += distance_x
			y += step_y
		}
	}
	picture_touch(picture, gathered)
}

// text_draw draws a text of the font of the system, its top left corner at
// a place, and gives the box that it changed, cut to the picture: the
// advance of its characters on its line, with a margin of one line on each
// side, as a glyph can pass its cell. The copy before the change that runs
// takes that box first, as for each tool: a call of the console during a
// stroke writes through the copy.
text_draw :: proc "contextless" (picture: ^Picture, x, y: int, text: string, color: graphics.Color) -> Box {
	canvas := picture_canvas(picture)
	// An alpha of 0 draws nothing and gives the end of the text.
	end := graphics.text_sized(canvas, x, y, text, color, text_rendering.TEXT_SIZE_OF_SCALE_ONE, alpha = 0)
	margin := graphics.LINE_HEIGHT
	box := box_cut(picture, {x - margin, y - margin, end + margin, y + 2 * margin})
	if box_empty(box) {
		return {}
	}
	picture_touch(picture, box)
	graphics.text(canvas, x, y, text, color)
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
	border := clamp(thickness, 1, max(min(width, height), 1))
	// The copy takes the four borders, not the inside.
	picture_touch(picture, {shape.left, shape.top, shape.right, shape.top + border})
	picture_touch(picture, {shape.left, shape.bottom - border, shape.right, shape.bottom})
	picture_touch(picture, {shape.left, shape.top, shape.left + border, shape.bottom})
	picture_touch(picture, {shape.right - border, shape.top, shape.right, shape.bottom})
	graphics.outline(picture_canvas(picture), shape.left, shape.top, width, height, border, color)
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
			picture_touch(picture, {left, row, right, row + 1})
			graphics.fill(canvas, left, row, right - left, 1, color)
			continue
		}
		inner_half := inner_x * intrinsics.sqrt(max(1 - (across / inner_y) * (across / inner_y), 0))
		inner_left := int(center_x - inner_half + 0.5)
		inner_right := int(center_x + inner_half + 0.5)
		// A border is at least one pixel on each side.
		picture_touch(picture, {left, row, left + max(inner_left - left, 1), row + 1})
		picture_touch(picture, {min(inner_right, right - 1), row, min(inner_right, right - 1) + max(right - inner_right, 1), row + 1})
		graphics.fill(canvas, left, row, max(inner_left - left, 1), 1, color)
		graphics.fill(canvas, min(inner_right, right - 1), row, max(right - inner_right, 1), 1, color)
	}
	picture_changed(picture)
	return box
}

// The fill (src/md/features/paint_application.md, "The fill"): a scanline
// fill of spans. Each span of the stack is a run of a row that the fill
// painted, with the row next to it to read; a pop reads that row under the
// run, paints each run of the region that it finds in one pass, and pushes
// it. A painted pixel has the new color, so it is never painted twice, and
// no bitmap of the reached pixels is needed. The stack is in the memory of
// the caller, which grows.

// A run of the row of a span: columns left to right of the row next to
// row in the direction (1 down, -1 up) are the ones to read.
Fill_Span :: struct {
	left:      i32,
	right:     i32,
	row:       i32,
	direction: i32,
}

// Fill_Grow makes the stack of a fill hold at least wanted spans: it sets
// spans to a longer slice that keeps the spans before it. false: the memory
// cannot grow.
Fill_Grow :: #type proc "contextless" (memory: ^Fill_Memory, wanted: int) -> bool

// The memory of a fill, which the caller keeps. painted and cancel are read
// and written by two threads: the fill runs on a worker, and the window
// reads the progress and asks to cancel (atomic loads and stores).
Fill_Memory :: struct {
	spans:     []Fill_Span,
	grow:      Fill_Grow, // nil: the stack is fixed.
	grow_data: rawptr,
	count:     int, // The spans that wait.
	peak:      int, // The most spans that waited in the last fill: a measure of its memory.
	painted:   int, // The pixels that the last fill painted so far.
	cancel:    bool, // Set by the window: the fill stops at its next span.
}

Fill_Outcome :: enum u8 {
	Done      = 0, // The region is painted whole.
	Cancelled = 1, // The window asked to stop: the box is the part painted.
	No_Memory = 2, // The stack cannot grow: the box is the part painted.
}

// span_push pushes the run left to right of a row, to read the row next to
// it in a direction, when that row is in the picture. false: the stack
// cannot grow.
@(private)
span_push :: proc "contextless" (memory: ^Fill_Memory, left, right, row, direction, height: int) -> bool {
	next := row + direction
	if next < 0 || next >= height {
		return true
	}
	if memory.count >= len(memory.spans) && (memory.grow == nil || !memory.grow(memory, memory.count + 1) || memory.count >= len(memory.spans)) {
		return false
	}
	memory.spans[memory.count] = {i32(left), i32(right), i32(row), i32(direction)}
	memory.count += 1
	memory.peak = max(memory.peak, memory.count)
	return true
}

// fill_region paints the 4-connected region of one color that holds a
// point with another color, and gives the box that changed. A point
// outside the picture, and a region that has the color already, change
// nothing: the box is empty. A fill that is cancelled, or whose stack
// cannot grow, stops: its box is the part that it painted, which the
// caller puts back from its copy. The fill does not change the generation
// of the picture: it can run on a worker, and the window raises it
// (picture_changed) when it takes the result.
fill_region :: proc "contextless" (picture: ^Picture, x, y: int, color: graphics.Color, memory: ^Fill_Memory) -> (changed: Box, outcome: Fill_Outcome) {
	memory.count, memory.peak = 0, 0
	intrinsics.atomic_store(&memory.painted, 0)
	if x < 0 || y < 0 || x >= picture.width || y >= picture.height {
		return {}, .Done
	}
	pixels := picture.pixels
	width, height := picture.width, picture.height
	target := pixels[y * width + x]
	if target == color {
		return {}, .Done
	}
	painted := 0
	// paint_run paints one run of a row, and adds it to the box.
	paint_run :: #force_inline proc "contextless" (picture: ^Picture, pixels: []graphics.Color, base, left, right, row: int, color: graphics.Color, changed: ^Box, painted: ^int) {
		picture_touch(picture, {left, row, right + 1, row + 1})
		for &pixel in pixels[base + left:base + right + 1] {
			pixel = color
		}
		changed^ = box_union(changed^, {left, row, right + 1, row + 1})
		painted^ += right - left + 1
	}
	// The row under the seed first, then the seed row through its parent row
	// below it.
	if !span_push(memory, x, x, y, 1, height) || !span_push(memory, x, x, y + 1, -1, height) {
		return {}, .No_Memory
	}
	for memory.count > 0 {
		if intrinsics.atomic_load(&memory.cancel) {
			return changed, .Cancelled
		}
		memory.count -= 1
		span := memory.spans[memory.count]
		direction := int(span.direction)
		row := int(span.row) + direction
		left, right := int(span.left), int(span.right)
		base := row * width
		column := left
		if pixels[base + column] == target {
			// The run that holds the left end of the parent may pass it on the
			// left: that part leaks into the row of the parent too.
			run_left := column
			for run_left > 0 && pixels[base + run_left - 1] == target {
				run_left -= 1
			}
			run_right := column
			for run_right + 1 < width && pixels[base + run_right + 1] == target {
				run_right += 1
			}
			paint_run(picture, pixels, base, run_left, run_right, row, color, &changed, &painted)
			ok := span_push(memory, run_left, run_right, row, direction, height)
			if run_left < left {
				ok &&= span_push(memory, run_left, left - 1, row, -direction, height)
			}
			if run_right > right {
				ok &&= span_push(memory, right + 1, run_right, row, -direction, height)
			}
			if !ok {
				return changed, .No_Memory
			}
			column = run_right + 2
		} else {
			column += 1
		}
		// The other runs under the parent start inside it, so only their
		// right end can leak.
		for column <= right {
			for column <= right && pixels[base + column] != target {
				column += 1
			}
			if column > right {
				break
			}
			run_right := column
			for run_right + 1 < width && pixels[base + run_right + 1] == target {
				run_right += 1
			}
			paint_run(picture, pixels, base, column, run_right, row, color, &changed, &painted)
			ok := span_push(memory, column, run_right, row, direction, height)
			if run_right > right {
				ok &&= span_push(memory, right + 1, run_right, row, -direction, height)
			}
			if !ok {
				return changed, .No_Memory
			}
			column = run_right + 2
		}
		intrinsics.atomic_store(&memory.painted, painted)
	}
	return changed, .Done
}

// The history of undo and redo (src/md/features/paint_application.md,
// "The memory of the history"): a ring of steps in the memory of the
// caller, bounded by one copy of the picture, and the one step that a
// change larger than that bound keeps in the copy before the stroke.

// The pixels that one LZ4 block holds: a step is a list of blocks of strips
// of whole rows of its box, so the scratch of a step is one strip, never a
// whole picture. A strip has as many rows of the box as fit these pixels,
// and at least one: a row of a box is at most PICTURE_SIDE_LIMIT pixels.
HISTORY_STRIP_PIXELS :: 1 << 16
#assert(HISTORY_STRIP_PIXELS >= PICTURE_SIDE_LIMIT)
HISTORY_STRIP_BYTES :: HISTORY_STRIP_PIXELS * size_of(graphics.Color)
// The bytes before each block in the ring: its length, a little-endian u32.
HISTORY_BLOCK_HEAD_BYTES :: 4

// The head of a step in the ring, before its two parts: the blocks before,
// then the blocks after. The heads link the steps, so the history has no
// table of steps.
@(private)
History_Head :: struct {
	box:          Box,
	before_bytes: int,
	after_bytes:  int,
	previous:     int, // The place of the step before, or NO_STEP.
	next:         int, // The place of the step after, or NO_STEP.
}

// A place of a step is a multiple of this, so its head is aligned.
@(private)
HISTORY_STEP_ALIGNMENT :: 8
@(private)
NO_STEP :: -1

// History_Grow makes the ring of a history hold at least wanted bytes: it
// sets ring to a longer slice that keeps the bytes before it in place.
// false: the memory cannot grow, and the ring holds what it held.
History_Grow :: #type proc "contextless" (history: ^History, wanted: int) -> bool

// The history. The steps are in the ring, the oldest first in their order;
// the first done steps are applied, so undo takes the last of them and redo
// the next. The places of the oldest, the newest and the last applied step
// have a meaning only while count, and done, are above 0. A history of
// zero bytes is empty.
History :: struct {
	ring:        []u8, // The memory that the history holds now; the caller's.
	grow:        History_Grow, // nil: the ring is fixed.
	grow_data:   rawptr,
	oldest:      int,
	newest:      int,
	applied:     int,
	count:       int,
	done:        int,
	// The one step that the copy before the stroke holds: its box, in that
	// copy and in the picture, of the same stride. Undo and redo exchange
	// the box between them.
	in_copy:     bool,
	copy_box:    Box,
	copy_pixels: []graphics.Color,
	copy_stride: int,
}

// The memory that a strip needs on its way into and out of the ring,
// which the caller keeps: the pixels of one strip, and its compressed form.
// strips_done and cancel are read and written by two threads: a record can
// run on a worker, and the window reads its progress and asks to cancel
// (atomic loads and stores).
History_Scratch :: struct {
	pixels:      [HISTORY_STRIP_PIXELS]graphics.Color,
	compressed:  [HISTORY_STRIP_BYTES + HISTORY_STRIP_BYTES / 255 + 16]u8,
	hash_table:  lz4.Hash_Table,
	strips_done: int, // The strips that the last record compressed so far, of history_record_strips.
	cancel:      bool, // Set by the window: the record stops at its next strip.
}

// history_record_strips gives the strips that a record of a box compresses
// at most: each part measured, then written. A part past the bound stops
// sooner.
history_record_strips :: proc "contextless" (box: Box) -> int {
	if box_empty(box) {
		return 0
	}
	rows := strip_rows(box)
	return 4 * ((box.bottom - box.top + rows - 1) / rows)
}

Record_Outcome :: enum u8 {
	Kept      = 0, // The change can be undone.
	Empty     = 1, // The box is empty: no change to keep.
	Refused   = 2, // The box is outside the memory of the picture: the history is cleared.
	Cancelled = 3, // The window asked to stop: the step is not kept; the steps before it stay, but those that went for its room.
}

// history_clear forgets each step, and keeps the ring and its growth.
history_clear :: proc "contextless" (history: ^History) {
	history^ = {ring = history.ring, grow = history.grow, grow_data = history.grow_data}
}

// history_copy_reused drops the step that the copy before the stroke holds:
// the caller writes that copy again (a stroke, a wider picture, a read).
history_copy_reused :: proc "contextless" (history: ^History) {
	if history.in_copy {
		history_clear(history)
	}
}

history_can_undo :: proc "contextless" (history: ^History) -> bool {
	return history.done > 0
}

history_can_redo :: proc "contextless" (history: ^History) -> bool {
	return history.done < history.count
}

@(private)
history_head :: proc "contextless" (history: ^History, place: int) -> ^History_Head {
	return (^History_Head)(&history.ring[place])
}

// step_bytes gives the bytes of a step in the ring: its head and its parts,
// to the next place of a step.
@(private)
step_bytes :: proc "contextless" (before_bytes, after_bytes: int) -> int {
	bytes := size_of(History_Head) + before_bytes + after_bytes
	return (bytes + HISTORY_STEP_ALIGNMENT - 1) / HISTORY_STEP_ALIGNMENT * HISTORY_STEP_ALIGNMENT
}
// box_pack copies the pixels of a box of a picture memory, of a width of
// rows (its stride), into one block, row after row, and gives its bytes.
@(private)
box_pack :: proc "contextless" (pixels: []graphics.Color, stride: int, box: Box, block: []graphics.Color) -> []u8 {
	width := box.right - box.left
	for row in box.top ..< box.bottom {
		intrinsics.mem_copy_non_overlapping(&block[(row - box.top) * width], &pixels[row * stride + box.left], width * size_of(graphics.Color))
	}
	count := width * (box.bottom - box.top)
	return ([^]u8)(raw_data(block))[:count * size_of(graphics.Color)]
}

// box_unpack copies one block into the pixels of a box of a picture memory.
@(private)
box_unpack :: proc "contextless" (pixels: []graphics.Color, stride: int, box: Box, block: []graphics.Color) {
	width := box.right - box.left
	for row in box.top ..< box.bottom {
		intrinsics.mem_copy_non_overlapping(&pixels[row * stride + box.left], &block[(row - box.top) * width], width * size_of(graphics.Color))
	}
}

// strip_rows gives the rows of a strip of a box: the rows whose pixels fit
// HISTORY_STRIP_PIXELS, at least one. The box alone decides it, so the
// write and the read of a step cut the same strips whatever the width of
// the picture between them.
@(private)
strip_rows :: proc "contextless" (box: Box) -> int {
	return max(HISTORY_STRIP_PIXELS / max(box.right - box.left, 1), 1)
}

// strip_of gives the strip of a box from its row top: strip_rows rows, or
// the rows left.
@(private)
strip_of :: proc "contextless" (box: Box, top: int) -> Box {
	return {box.left, top, box.right, min(top + strip_rows(box), box.bottom)}
}

// history_part_write writes the pixels of a box as the blocks of its strips
// at a place of the ring, and gives their bytes. ok is false when a block
// does not fit in the ring past that place.
@(private)
history_part_write :: proc "contextless" (history: ^History, pixels: []graphics.Color, stride: int, box: Box, offset: int, scratch: ^History_Scratch) -> (bytes: int, ok: bool) {
	at := offset
	for top := box.top; top < box.bottom; top += strip_rows(box) {
		if intrinsics.atomic_load(&scratch.cancel) {
			return 0, false
		}
		written, refused := lz4.compress_block(box_pack(pixels, stride, strip_of(box, top), scratch.pixels[:]), scratch.compressed[:], &scratch.hash_table)
		intrinsics.atomic_add(&scratch.strips_done, 1)
		if refused != .None || at + HISTORY_BLOCK_HEAD_BYTES + written > len(history.ring) {
			return 0, false
		}
		word_write(history.ring, at, u32(written))
		intrinsics.mem_copy_non_overlapping(&history.ring[at + HISTORY_BLOCK_HEAD_BYTES], raw_data(scratch.compressed[:]), written)
		at += HISTORY_BLOCK_HEAD_BYTES + written
	}
	return at - offset, true
}

// history_drop_oldest forgets the oldest step. No byte moves: its bytes are
// free for the next steps of the ring.
@(private)
history_drop_oldest :: proc "contextless" (history: ^History) {
	if history.count <= 1 {
		history_clear(history)
		return
	}
	history.oldest = history_head(history, history.oldest).next
	history_head(history, history.oldest).previous = NO_STEP
	history.count -= 1
	history.done = max(history.done - 1, 0)
}

// history_part_measure gives the bytes that the blocks of the strips of a
// box take in the ring, with no write. ok is false when a strip does not
// compress, or when the bytes pass ceiling: the measure stops there, so a
// change past the bound costs no compression of the rest of it.
@(private)
history_part_measure :: proc "contextless" (pixels: []graphics.Color, stride: int, box: Box, ceiling: int, scratch: ^History_Scratch) -> (bytes: int, ok: bool) {
	for top := box.top; top < box.bottom; top += strip_rows(box) {
		if intrinsics.atomic_load(&scratch.cancel) {
			return 0, false
		}
		written, refused := lz4.compress_block(box_pack(pixels, stride, strip_of(box, top), scratch.pixels[:]), scratch.compressed[:], &scratch.hash_table)
		intrinsics.atomic_add(&scratch.strips_done, 1)
		if refused != .None {
			return 0, false
		}
		bytes += HISTORY_BLOCK_HEAD_BYTES + written
		if bytes > ceiling {
			return 0, false
		}
	}
	return bytes, true
}

// history_holds says if the ring holds the bytes up to end, under the
// bound: it grows the ring when it can.
@(private)
history_holds :: proc "contextless" (history: ^History, end, bound: int) -> bool {
	if end > bound {
		return false
	}
	if end > len(history.ring) && history.grow != nil {
		history.grow(history, end)
	}
	return end <= len(history.ring)
}

// history_place gives the place of a new step of a size: after the newest,
// or at the start of the ring when the end of the bound is reached, the
// oldest steps going until it has its room. false: the ring alone does not
// hold it; the history is then empty.
@(private)
history_place :: proc "contextless" (history: ^History, bytes, bound: int) -> (place: int, ok: bool) {
	for {
		if history.count == 0 {
			return 0, history_holds(history, bytes, bound)
		}
		newest := history_head(history, history.newest)
		tail := history.newest + step_bytes(newest.before_bytes, newest.after_bytes)
		if history.newest >= history.oldest {
			// The steps are one run from the oldest to the newest: the room is
			// after the newest, else before the oldest.
			if history_holds(history, tail + bytes, bound) {
				return tail, true
			}
			if bytes <= history.oldest {
				return 0, true
			}
		} else if tail + bytes <= history.oldest {
			// The ring wrapped: the room is between the newest and the oldest.
			return tail, true
		}
		history_drop_oldest(history)
	}
}

// history_record keeps a change of the picture: the pixels of a box before
// it, from a copy of the picture made before the change, and after it,
// from the picture; both have rows of stride pixels, and hold the box. The
// bound is the bytes that the ring may hold: one copy of the picture. The
// steps that redo would give are removed first. The step is measured once;
// the oldest steps go until it fits; then it is written. A step that does
// not fit in the ring alone is kept in the copy (before), the one step of
// the history, until history_copy_reused.
history_record :: proc "contextless" (history: ^History, before, after: []graphics.Color, stride: int, box: Box, bound: int, scratch: ^History_Scratch) -> Record_Outcome {
	if box_empty(box) {
		return .Empty
	}
	if box.left < 0 || box.top < 0 || box.right > stride || box.bottom * stride > min(len(before), len(after)) {
		history_clear(history)
		return .Refused
	}
	if history.in_copy {
		history_clear(history)
	}
	// The steps after the last applied one are what redo would give.
	if history.done == 0 {
		history_clear(history)
	} else if history.count > history.done {
		history.newest = history.applied
		history_head(history, history.newest).next = NO_STEP
		history.count = history.done
	}
	intrinsics.atomic_store(&scratch.strips_done, 0)
	room := bound - size_of(History_Head)
	before_bytes, before_ok := history_part_measure(before, stride, box, room, scratch)
	after_bytes, after_ok := history_part_measure(after, stride, box, room - before_bytes, scratch)
	// A cancel stops the measure: the step is not kept, and the history is
	// the one before it, less the steps that redo would give.
	if intrinsics.atomic_load(&scratch.cancel) {
		return .Cancelled
	}
	place := 0
	placed := false
	if before_ok && after_ok {
		place, placed = history_place(history, step_bytes(before_bytes, after_bytes), bound)
	}
	if !placed {
		history_clear(history)
		history.in_copy, history.copy_box, history.copy_pixels, history.copy_stride = true, box, before, stride
		history.count, history.done = 1, 1
		return .Kept
	}
	written_before, wrote_before := history_part_write(history, before, stride, box, place + size_of(History_Head), scratch)
	written_after, wrote_after := history_part_write(history, after, stride, box, place + size_of(History_Head) + before_bytes, scratch)
	// A cancel during the write leaves the step unlinked: the ring keeps
	// the steps before it, but those that went for its room.
	if intrinsics.atomic_load(&scratch.cancel) {
		return .Cancelled
	}
	// The compression gives the same bytes for the same pixels: a write
	// that differs from its measure is a fault of the ring, and the history
	// keeps nothing of it.
	if !wrote_before || !wrote_after || written_before != before_bytes || written_after != after_bytes {
		history_clear(history)
		return .Refused
	}
	head := history_head(history, place)
	head^ = {box = box, before_bytes = before_bytes, after_bytes = after_bytes, previous = NO_STEP, next = NO_STEP}
	if history.count == 0 {
		history.oldest = place
	} else {
		head.previous = history.newest
		history_head(history, history.newest).next = place
	}
	history.newest, history.applied = place, place
	history.count += 1
	history.done = history.count
	return .Kept
}
// history_part_apply writes the blocks of one part of a step into the
// picture. Each block is checked first: a block that does not give the
// pixels of its strip refuses the whole part, and the picture does not
// change. The extent never shrinks while the history lives, so the box of
// a step is in it; a box outside it is a damaged step, refused. The extent
// can be wider than at the record: the box names rows and columns, not
// places in memory, so the step writes the same pixels. A cancel (in the
// scratch) stops it at a strip: in the check, nothing is written; in the
// write, each strip is first saved into saved (memory of the stride of the
// picture), and the saved strips are put back, so the picture is as
// before. With no saved memory, a cancel stops the check only.
@(private)
history_part_apply :: proc "contextless" (picture: ^Picture, box: Box, part: []u8, scratch: ^History_Scratch, saved: []graphics.Color) -> bool {
	if box_empty(box) || box.left < 0 || box.top < 0 || box.right > picture.width || box.bottom > picture.height {
		return false
	}
	can_save := box.bottom * picture.width <= len(saved)
	strip_bytes := ([^]u8)(raw_data(scratch.pixels[:]))[:HISTORY_STRIP_BYTES]
	for pass in 0 ..< 2 {
		at := 0
		for top := box.top; top < box.bottom; top += strip_rows(box) {
			if intrinsics.atomic_load(&scratch.cancel) && (pass == 0 || can_save) {
				if pass == 1 {
					picture_copy_box(picture.pixels, saved, picture.width, {box.left, box.top, box.right, top})
				}
				return false
			}
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
				if can_save {
					picture_copy_box(saved, picture.pixels, picture.width, strip)
				}
				box_unpack(picture.pixels, picture.width, strip, scratch.pixels[:])
			}
			intrinsics.atomic_add(&scratch.strips_done, 1)
		}
		if at != len(part) {
			return false
		}
	}
	picture_changed(picture)
	return true
}

// history_apply_strips gives the strips that an undo or a redo of a box
// reads: each strip checked, then written.
history_apply_strips :: proc "contextless" (box: Box) -> int {
	if box_empty(box) {
		return 0
	}
	rows := strip_rows(box)
	return 2 * ((box.bottom - box.top + rows - 1) / rows)
}

// history_copy_exchange exchanges the box of the step in the copy between
// the picture and the copy, row by row through the scratch, a strip of
// rows at a time. false: the picture has another stride, or a memory does
// not hold the box, or a cancel stopped it; an exchange is its own
// inverse, so a cancel exchanges back the rows that it did, and nothing
// changed.
@(private)
history_copy_exchange :: proc "contextless" (history: ^History, picture: ^Picture, scratch: ^History_Scratch) -> bool {
	box := history.copy_box
	stride := history.copy_stride
	if picture.width != stride || box_empty(box) || box.left < 0 || box.top < 0 || box.right > stride || box.bottom > picture.height ||
	   box.bottom * stride > min(len(picture.pixels), len(history.copy_pixels)) {
		return false
	}
	row_bytes := (box.right - box.left) * size_of(graphics.Color)
	exchange_rows :: proc "contextless" (history: ^History, picture: ^Picture, scratch: ^History_Scratch, top, bottom, row_bytes: int) {
		for row in top ..< bottom {
			start := row * history.copy_stride + history.copy_box.left
			intrinsics.mem_copy_non_overlapping(&scratch.pixels[0], &picture.pixels[start], row_bytes)
			intrinsics.mem_copy_non_overlapping(&picture.pixels[start], &history.copy_pixels[start], row_bytes)
			intrinsics.mem_copy_non_overlapping(&history.copy_pixels[start], &scratch.pixels[0], row_bytes)
		}
	}
	for top := box.top; top < box.bottom; top += strip_rows(box) {
		if intrinsics.atomic_load(&scratch.cancel) {
			exchange_rows(history, picture, scratch, box.top, top, row_bytes)
			return false
		}
		exchange_rows(history, picture, scratch, top, min(top + strip_rows(box), box.bottom), row_bytes)
		intrinsics.atomic_add(&scratch.strips_done, 2)
	}
	picture_changed(picture)
	return true
}

// history_undo_box gives the box of the change that undo puts back.
history_undo_box :: proc "contextless" (history: ^History) -> (box: Box, ok: bool) {
	switch {
	case history.done == 0:
		return {}, false
	case history.in_copy:
		return history.copy_box, true
	}
	return history_head(history, history.applied).box, true
}

// history_redo_box gives the box of the change that redo applies again.
history_redo_box :: proc "contextless" (history: ^History) -> (box: Box, ok: bool) {
	switch {
	case history.done >= history.count:
		return {}, false
	case history.in_copy:
		return history.copy_box, true
	}
	place := history.done == 0 ? history.oldest : history_head(history, history.applied).next
	return history_head(history, place).box, true
}

// history_undo puts back the pixels before the last applied change, and
// gives its box. false: no change to undo, a damaged step, or a cancel
// (in the scratch); nothing changed. saved: memory of the stride of the
// picture that a cancel during the write uses (history_part_apply).
history_undo :: proc "contextless" (history: ^History, picture: ^Picture, scratch: ^History_Scratch, saved: []graphics.Color = nil) -> (box: Box, ok: bool) {
	intrinsics.atomic_store(&scratch.strips_done, 0)
	if history.done == 0 {
		return {}, false
	}
	if history.in_copy {
		if !history_copy_exchange(history, picture, scratch) {
			return {}, false
		}
		history.done = 0
		return history.copy_box, true
	}
	head := history_head(history, history.applied)
	if !history_part_apply(picture, head.box, history.ring[history.applied + size_of(History_Head):][:head.before_bytes], scratch, saved) {
		return {}, false
	}
	history.applied = head.previous
	history.done -= 1
	return head.box, true
}

// history_redo applies again the first undone change, and gives its box.
// false: no change to redo, a damaged step, or a cancel; nothing changed.
history_redo :: proc "contextless" (history: ^History, picture: ^Picture, scratch: ^History_Scratch, saved: []graphics.Color = nil) -> (box: Box, ok: bool) {
	intrinsics.atomic_store(&scratch.strips_done, 0)
	if history.done >= history.count {
		return {}, false
	}
	if history.in_copy {
		if !history_copy_exchange(history, picture, scratch) {
			return {}, false
		}
		history.done = 1
		return history.copy_box, true
	}
	place := history.done == 0 ? history.oldest : history_head(history, history.applied).next
	head := history_head(history, place)
	if !history_part_apply(picture, head.box, history.ring[place + size_of(History_Head) + head.before_bytes:][:head.after_bytes], scratch, saved) {
		return {}, false
	}
	history.applied = place
	history.done += 1
	return head.box, true
}

// The picture file: a header of FILE_HEADER_BYTES, then rows of the width
// of the picture, 4 bytes for a pixel (0x00RRGGBB, little endian), at the
// place that the header names. A row is at one place of the rows whatever
// changes in the others: a keep writes the rows that changed, and the store
// keeps the other blocks. A keep that cannot be one commit (a large band,
// or a wider picture, whose rows all move) writes the whole picture at a
// place that the rows of the header do not cover, then the header that
// names that place, so each commit holds one whole picture
// (src/md/features/paint_application.md, "Each committed state is one
// whole picture").
//
//   offset  size  field
//        0     4  the magic "MPIC"
//        4     4  the version, 4
//        8     4  the width: 1 to PICTURE_SIDE_LIMIT
//       12     4  the height: 1 to PICTURE_SIDE_LIMIT
//       16     8  the place of the rows in the file: FILE_HEADER_BYTES to FILE_ROWS_OFFSET_LIMIT, a multiple of 4
FILE_MAGIC :: "MPIC"
FILE_VERSION :: u32(4)
FILE_HEADER_BYTES :: 24
// The farthest place of the rows: a keep writes the rows after the rows of
// the header only when they do not fit before them, so the rows start at
// most two pictures of the largest size past the header.
FILE_ROWS_OFFSET_LIMIT :: FILE_HEADER_BYTES + 2 * PICTURE_PIXELS_LIMIT * size_of(graphics.Color)

File_Problem :: enum u8 {
	None        = 0, // The file is read.
	Too_Short   = 1, // The file is shorter than its header.
	Bad_Magic   = 2, // The first 4 bytes are not "MPIC".
	Bad_Version = 3, // The version is not FILE_VERSION.
	Bad_Size    = 4, // The width or the height is 0, or past the bounds of a picture (picture_pixels_for).
	Bad_Offset  = 5, // The place of the rows is in the header, past FILE_ROWS_OFFSET_LIMIT, or not a multiple of 4.
	Bad_Length  = 6, // The file is too short for its rows, or the rows given are not those rows.
	Bad_Pixel   = 7, // A pixel has a top byte that is not 0.
	Too_Large   = 8, // The memory of the picture does not hold the pixels of the file.
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

// file_row_bytes gives the bytes of a row of a picture of a width.
file_row_bytes :: proc "contextless" (width: int) -> int {
	return width * size_of(graphics.Color)
}

// file_rows_offset_valid says if the rows can start at a place.
@(private)
file_rows_offset_valid :: proc "contextless" (offset: int) -> bool {
	return offset >= FILE_HEADER_BYTES && offset <= FILE_ROWS_OFFSET_LIMIT && offset % size_of(graphics.Color) == 0
}

// file_header_write writes the header of a picture of a size whose rows
// start at a place into the first FILE_HEADER_BYTES of a buffer. ok is
// false for a size past the bounds of a picture, a place that
// file_rows_offset_valid refuses, or a buffer too small.
file_header_write :: proc "contextless" (width, height, rows_offset: int, bytes: []u8) -> (header: []u8, ok: bool) {
	if _, size_ok := picture_pixels_for(width, height); !size_ok || !file_rows_offset_valid(rows_offset) || len(bytes) < FILE_HEADER_BYTES {
		return nil, false
	}
	copy(bytes[:4], FILE_MAGIC)
	word_write(bytes, 4, FILE_VERSION)
	word_write(bytes, 8, u32(width))
	word_write(bytes, 12, u32(height))
	word_write(bytes, 16, u32(rows_offset))
	word_write(bytes, 20, u32(u64(rows_offset) >> 32))
	return bytes[:FILE_HEADER_BYTES], true
}

// file_rows_copy copies the rows top ..< bottom of a picture into a buffer,
// as the file holds them, and gives their bytes. ok is false for rows
// outside the extent or a buffer too small.
file_rows_copy :: proc "contextless" (picture: ^Picture, top, bottom: int, bytes: []u8) -> (rows: []u8, ok: bool) {
	row_bytes := file_row_bytes(picture.width)
	if top < 0 || bottom > picture.height || top >= bottom || len(bytes) < (bottom - top) * row_bytes {
		return nil, false
	}
	count := (bottom - top) * row_bytes
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), &picture.pixels[top * picture.width], count)
	return bytes[:count], true
}

// picture_encode writes the whole file of a picture: the header, and each
// row of its extent just after it. A host test and a store in memory start
// from it.
picture_encode :: proc "contextless" (picture: ^Picture, file: []u8) -> (bytes: []u8, ok: bool) {
	if _, header_ok := file_header_write(picture.width, picture.height, FILE_HEADER_BYTES, file); !header_ok {
		return nil, false
	}
	if _, rows_ok := file_rows_copy(picture, 0, picture.height, file[FILE_HEADER_BYTES:]); !rows_ok {
		return nil, false
	}
	return file[:FILE_HEADER_BYTES + picture.height * file_row_bytes(picture.width)], true
}

// File_Rows: the picture of a header, and where its rows are in its file.
File_Rows :: struct {
	width:  int,
	height: int,
	offset: int,
	bytes:  int,
}

// file_rows_of_header checks a header and gives the picture that it names
// and the place of its rows. A reader reads these rows only.
file_rows_of_header :: proc "contextless" (header: []u8) -> (rows: File_Rows, problem: File_Problem) {
	if len(header) < FILE_HEADER_BYTES {
		return {}, .Too_Short
	}
	if string(header[:4]) != FILE_MAGIC {
		return {}, .Bad_Magic
	}
	if word_read(header, 4) != FILE_VERSION {
		return {}, .Bad_Version
	}
	width, height := int(word_read(header, 8)), int(word_read(header, 12))
	pixels, size_ok := picture_pixels_for(width, height)
	if !size_ok {
		return {}, .Bad_Size
	}
	// The high word first: a place past 32 bits is past the limit, and
	// never reads as a small one.
	if word_read(header, 20) != 0 {
		return {}, .Bad_Offset
	}
	offset := int(word_read(header, 16))
	if !file_rows_offset_valid(offset) {
		return {}, .Bad_Offset
	}
	return {width = width, height = height, offset = offset, bytes = pixels * size_of(graphics.Color)}, .None
}

// picture_decode reads a whole file into a picture: the header, then its
// rows. Each field and each pixel is checked before any pixel changes: on a
// problem, the picture is as before. On success the extent is the size of
// the header.
picture_decode :: proc "contextless" (file: []u8, picture: ^Picture) -> File_Problem {
	if len(file) < FILE_HEADER_BYTES {
		return .Too_Short
	}
	place, problem := file_rows_of_header(file[:FILE_HEADER_BYTES])
	if problem != .None {
		return problem
	}
	if len(file) < place.offset + place.bytes {
		return .Bad_Length
	}
	return picture_decode_parts(file[:FILE_HEADER_BYTES], file[place.offset:][:place.bytes], picture)
}

// picture_decode_parts reads a file whose header and rows are in two
// buffers: a read puts the rows in memory of its own, and the header
// apart. The rows may be in the pixels of another picture, never in the
// pixels of this one. The memory of the picture must hold the pixels of
// the file: the caller grows it first, from the size of the header.
picture_decode_parts :: proc "contextless" (header, rows: []u8, picture: ^Picture) -> File_Problem {
	place, problem := file_rows_of_header(header)
	if problem != .None {
		return problem
	}
	if len(header) != FILE_HEADER_BYTES || len(rows) != place.bytes {
		return .Bad_Length
	}
	if len(picture.pixels) * size_of(graphics.Color) < place.bytes {
		return .Too_Large
	}
	// The top byte of each pixel, little endian: the fourth byte of each
	// four. A pixel of the screen has none.
	for at := 3; at < len(rows); at += 4 {
		if rows[at] != 0 {
			return .Bad_Pixel
		}
	}
	intrinsics.mem_copy_non_overlapping(raw_data(picture.pixels), raw_data(rows), len(rows))
	picture.width, picture.height = place.width, place.height
	picture_changed(picture)
	return .None
}

// The keep of the changed rows.

KEEP_PAUSE_MILLISECONDS :: 1000 // The pause of the changes after which the picture is kept.
KEEP_LONGEST_WAIT_MILLISECONDS :: 5000 // The longest wait of a change for its keep, whatever the pauses.

// The rows of the picture that changed since the last keep, and when.
Changed_Rows :: struct {
	top, bottom:  int, // The band of changed rows: top included, bottom excluded. Empty when bottom <= top.
	changed:      bool, // A change waits for a keep.
	whole:        bool, // The object has none of the rows yet: the keep writes all of them.
	first_change: u64, // The time of the system of the first change that waits, in milliseconds.
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
	changed_rows_mark(rows, now)
}

// changed_rows_mark marks a change: of the header alone (a wider extent
// changes no byte of a row of the file, only its width), or of the rows that
// changed_rows_add added.
changed_rows_mark :: proc "contextless" (rows: ^Changed_Rows, now: u64) {
	if !rows.changed {
		rows.first_change = now
	}
	rows.changed = true
	rows.last_change = now
}

// keep_due says if the changes wait for a keep at a time of the system: a
// pause of KEEP_PAUSE_MILLISECONDS since the last one, or
// KEEP_LONGEST_WAIT_MILLISECONDS since the first one. A time before a
// change is no wait.
keep_due :: proc "contextless" (rows: ^Changed_Rows, now: u64) -> bool {
	if !rows.changed {
		return false
	}
	paused := now >= rows.last_change && now - rows.last_change >= KEEP_PAUSE_MILLISECONDS
	waited := now >= rows.first_change && now - rows.first_change >= KEEP_LONGEST_WAIT_MILLISECONDS
	return paused || waited
}

// keep_due_time gives the time of the system at which the changes are due.
keep_due_time :: proc "contextless" (rows: ^Changed_Rows) -> u64 {
	return min(rows.last_change + KEEP_PAUSE_MILLISECONDS, rows.first_change + KEEP_LONGEST_WAIT_MILLISECONDS)
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
	rows^ = {}
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

// How a keep reaches the store, so that each commit holds one whole
// picture.
Keep_Form :: enum u8 {
	One_Commit  = 0, // The band fits one commit, and the width did not change: its rows in place and the header, then one commit.
	Other_Place = 1, // The whole picture at a place that the rows of the header do not cover, a commit after each KEEP_COMMIT_BYTES, then the header that names it.
	New_Object = 2, // A new picture too large for one commit: a temporary object, then a rename to the picture.
}

// The object that a piece of a keep writes.
Keep_Object :: enum u8 {
	Picture = 0, // The object <name>.picture.
	Partial = 1, // The object <name>.partial, which the list ignores.
}

Keep_State :: struct {
	store_open:  bool, // The store is open, and listed.
	started:     bool, // The first open is taken: before it, the picture does not change.
	named:       bool, // The open picture has a name: it can be kept.
	written:     bool, // The store holds the object of the open picture.
	// The picture that the header of that object names: the place of its
	// rows, its width and its height.
	rows_offset: int,
	kept_width:  int,
	kept_height: int,
	reading:     bool, // A read of a picture runs, or its result waits: the picture must not change.
	rows:        Changed_Rows,
	pending:     Store_Pending,
	retry_at:    u64, // After a refused keep: no keep before this time of the system.
	// A keep runs as a series of jobs of one piece each: its form, the place
	// of the rows and the size of the picture that it writes, its band, and
	// the bytes of the band written so far.
	keeping:       bool,
	form:          Keep_Form,
	target_offset: int,
	keep_width:  int,
	keep_height: int,
	keep_top:    int,
	keep_bottom: int,
	keep_done:   int,
}

// The bytes of one piece of a keep: a call of the store carries 64 KiB at
// most, with its arguments.
KEEP_PIECE_BYTES :: 32 * 1024
// The bytes of rows that one commit holds at most: the store holds 4 MiB of
// pending changes for all its connections.
KEEP_COMMIT_BYTES :: 1024 * 1024

// A piece of a keep: what the job writes, and in which order: the rows,
// then the header and the size when it is the last piece, then the commit,
// then the rename.
Keep_Piece :: struct {
	object: Keep_Object,
	offset: int, // The place of the rows of the piece in the object.
	bytes:  int, // The bytes of rows of the piece, 0 for a band with no row.
	row:    int, // The first byte of the piece in the rows of the picture: row offset in the array.
	header: bool, // The job writes the header and sets the size after the rows.
	size:   int, // That size.
	commit: bool, // The job commits after the piece.
	rename: bool, // After the commit, the job renames the temporary object to the picture.
	last:   bool, // The last piece of the keep.
}

// keep_begin starts a keep of the band of changed rows of a picture of a
// size, chooses its form, and empties the band: a change from now on goes
// to the next keep.
keep_begin :: proc "contextless" (state: ^Keep_State, width, height: int) {
	if !state.written {
		state.rows.whole = true
	}
	// The rows of a wider picture all move: the keep writes them all.
	if state.written && width != state.kept_width {
		state.rows.whole = true
	}
	top, bottom := keep_band(&state.rows, height)
	bottom = max(bottom, top)
	state.keep_width, state.keep_height = width, height
	row_bytes := file_row_bytes(width)
	switch {
	case state.written && width == state.kept_width && (bottom - top) * row_bytes <= KEEP_COMMIT_BYTES:
		state.form = .One_Commit
		state.target_offset = state.rows_offset
	case state.written:
		// The new rows go before the rows of the header when they fit
		// there, else just after them: never over them, so each commit
		// before the header holds the old picture. Before them, the size of
		// the object at the header drops the old rows.
		state.form = .Other_Place
		new_bytes := height * row_bytes
		if new_bytes <= state.rows_offset - FILE_HEADER_BYTES {
			state.target_offset = FILE_HEADER_BYTES
		} else {
			state.target_offset = state.rows_offset + state.kept_height * file_row_bytes(state.kept_width)
		}
		top, bottom = 0, height
	case (bottom - top) * row_bytes <= KEEP_COMMIT_BYTES:
		state.form = .One_Commit
		state.target_offset = FILE_HEADER_BYTES
	case:
		state.form = .New_Object
		state.target_offset = FILE_HEADER_BYTES
		top, bottom = 0, height
	}
	state.keep_top, state.keep_bottom = top, bottom
	state.keep_done = 0
	state.keeping = true
	keep_taken(&state.rows)
}

// keep_piece gives the next piece of the keep that runs.
keep_piece :: proc "contextless" (state: ^Keep_State) -> Keep_Piece {
	row_bytes := file_row_bytes(state.keep_width)
	band := (state.keep_bottom - state.keep_top) * row_bytes
	bytes := clamp(band - state.keep_done, 0, KEEP_PIECE_BYTES)
	after := state.keep_done + bytes
	last := after >= band
	crossing := after / KEEP_COMMIT_BYTES != state.keep_done / KEEP_COMMIT_BYTES
	return {
		object = state.form == .New_Object ? .Partial : .Picture,
		offset = state.target_offset + state.keep_top * row_bytes + state.keep_done,
		bytes  = bytes,
		row    = state.keep_top * row_bytes + state.keep_done,
		header = last,
		size   = state.target_offset + state.keep_height * row_bytes,
		commit = last || state.form != .One_Commit && crossing,
		rename = last && state.form == .New_Object,
		last   = last,
	}
}

// keep_piece_written takes a piece that the store wrote: true when the
// keep is whole, and the header of the object names the picture of the
// keep.
keep_piece_written :: proc "contextless" (state: ^Keep_State, piece: Keep_Piece) -> (whole: bool) {
	state.keep_done += piece.bytes
	if !piece.last {
		return false
	}
	state.keeping = false
	keep_object_read(state, state.target_offset, state.keep_width, state.keep_height)
	return true
}

// keep_object_read records that the object of the open picture holds a
// picture of a size whose rows start at a place: after a keep, and after a
// read of the object.
keep_object_read :: proc "contextless" (state: ^Keep_State, rows_offset, width, height: int) {
	state.written = true
	state.rows_offset, state.kept_width, state.kept_height = rows_offset, width, height
}

// What the window asks of the store in a turn.
Keep_Step :: enum u8 {
	Nothing = 0, // No job: none is due, or one runs, or the act waits.
	Keep    = 1, // Write the next piece of the keep of the open picture.
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
	if !state.store_open || job_running {
		return 0, false
	}
	if state.keeping {
		return 1, true // The next piece is due at once: a time in the past.
	}
	if !state.named || !state.rows.changed {
		return 0, false
	}
	return max(keep_due_time(&state.rows), state.retry_at), true
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

// change_allowed says if the picture may change now: not before the first
// open is taken, and not while a read of another picture runs, whose result
// would replace the change.
change_allowed :: proc "contextless" (state: ^Keep_State) -> bool {
	return state.started && !state.reading
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
// change again. The window records the object that it read
// (keep_object_read).
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

OBJECT_SUFFIX :: ".picture" // The object of a picture in the private store is its name and this.
// The bytes of the longest name: the longest name of an object of the
// store, less the suffix. A name follows the names of the store.
NAME_LIMIT :: store.ENTRY_NAME_CAPACITY - len(OBJECT_SUFFIX)
#assert(NAME_LIMIT >= 1)
// The temporary object of a large first keep is the name and this; the list
// shows no picture of it, and the open of the store removes it.
PARTIAL_SUFFIX :: ".partial"
#assert(len(PARTIAL_SUFFIX) <= len(OBJECT_SUFFIX))

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

// partial_object_name gives the temporary object of a picture name, or
// false for a text that is not a name.
partial_object_name :: proc "contextless" (room: ^Object_Name, name: string) -> (object: string, ok: bool) {
	if name_check(name) != .None {
		return "", false
	}
	copy(room.bytes[:], name)
	copy(room.bytes[len(name):], PARTIAL_SUFFIX)
	room.count = len(name) + len(PARTIAL_SUFFIX)
	return string(room.bytes[:room.count]), true
}

@(private)
name_of_object_with_suffix :: proc "contextless" (object, suffix: string) -> (name: string, ok: bool) {
	if len(object) <= len(suffix) || object[len(object) - len(suffix):] != suffix {
		return "", false
	}
	name = object[:len(object) - len(suffix)]
	if name_check(name) != .None {
		return "", false
	}
	return name, true
}

// picture_name_of_object gives the name of a picture from the name of an
// object of the store, or false for an object that is not a picture.
picture_name_of_object :: proc "contextless" (object: string) -> (name: string, ok: bool) {
	return name_of_object_with_suffix(object, OBJECT_SUFFIX)
}

// partial_name_of_object gives the name of a picture from the name of its
// temporary object, or false for an object that is not one: the open of the
// store removes only these.
partial_name_of_object :: proc "contextless" (object: string) -> (name: string, ok: bool) {
	return name_of_object_with_suffix(object, PARTIAL_SUFFIX)
}

// The numbers of the names picture-1, picture-2, ... that the store holds,
// which the open of the store marks as it reads each page: the small ones
// one bit each, and the largest of all. No count of pictures bounds it: past
// the small numbers, the next name is the one after the largest.
PICTURE_NUMBERS_SMALL :: 1024
Picture_Numbers :: struct {
	small:   [PICTURE_NUMBERS_SMALL / 64]u64, // Bit n: picture-n is taken, for n from 1.
	largest: int,
}

// PICTURE_NUMBER_DIGITS: the digits of a number that the names take, so a
// number stays far inside an int.
@(private)
PICTURE_NUMBER_DIGITS :: 15
@(private)
PICTURE_NAME_PREFIX :: "picture-"

// picture_number_mark marks the number of a name picture-N, N from 1 with no
// zero first; another name marks nothing.
picture_number_mark :: proc "contextless" (numbers: ^Picture_Numbers, name: string) {
	if len(name) <= len(PICTURE_NAME_PREFIX) || name[:len(PICTURE_NAME_PREFIX)] != PICTURE_NAME_PREFIX {
		return
	}
	digits := name[len(PICTURE_NAME_PREFIX):]
	if len(digits) > PICTURE_NUMBER_DIGITS || digits[0] == '0' {
		return
	}
	number := 0
	for digit in transmute([]u8)digits {
		if digit < '0' || digit > '9' {
			return
		}
		number = number * 10 + int(digit - '0')
	}
	if number < PICTURE_NUMBERS_SMALL {
		numbers.small[number / 64] |= 1 << u64(number % 64)
	}
	numbers.largest = max(numbers.largest, number)
}

// first_free_name gives the first name picture-1, picture-2, ... whose
// number is not marked, written into a room; past the small numbers, the
// name after the largest. ok is false only when that name has more digits
// than a name takes.
first_free_name :: proc "contextless" (numbers: ^Picture_Numbers, room: ^[NAME_LIMIT]u8) -> (name: string, ok: bool) {
	number := numbers.largest + 1
	for small in 1 ..< PICTURE_NUMBERS_SMALL {
		if numbers.small[small / 64] & (1 << u64(small % 64)) == 0 {
			number = small
			break
		}
	}
	digits: [PICTURE_NUMBER_DIGITS + 1]u8
	digit_count := 0
	for rest := number; rest > 0 && digit_count < len(digits); rest /= 10 {
		digits[len(digits) - 1 - digit_count] = u8('0' + rest % 10)
		digit_count += 1
	}
	if digit_count > PICTURE_NUMBER_DIGITS || len(PICTURE_NAME_PREFIX) + digit_count > NAME_LIMIT {
		return "", false
	}
	count := copy(room[:], PICTURE_NAME_PREFIX)
	count += copy(room[count:], digits[len(digits) - digit_count:])
	return string(room[:count]), true
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
