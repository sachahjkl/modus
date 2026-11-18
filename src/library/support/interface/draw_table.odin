// The interface package (docs/INTERFACE.md): a process describes its window
// again at each frame, and each call appends draw records to a draw table
// in the memory of the process. The package finds the damage by a
// comparison with the table of the frame before, and draws the records into
// the surface of the process. It never allocates. The core files (the draw
// table, its execution, the difference, the layout, the text, the input,
// the elements) make no kernel call; window_drawing.odin does: it reads the
// events of a window and presents its surface.
//
// Who uses it: each process with a window (the console, the bar, the
// developer tools, the settings). The parts:
//
// - `Draw_Table`, `Draw_Record`, `Draw_Kind`: the frame as records
//   (`draw_rectangle`, `draw_text` and the other `draw_` procedures). The
//   form of a record and its border are the contract package
//   `draw_record`.
// - `Damage`, `records_equal` (`difference.odin`): what changed since the
//   frame before.
// - `execute`, `execute_in_rectangles` (`execute.odin`): the records drawn
//   into a canvas; a path by the exact area of each pixel (`path.odin`).
// - `draw_path`, `draw_line`: a path of points, and a line as its stroke.
// - `Area`, `Column`, `Size`, `row_split` (`layout.odin`): where each element
//   goes.
// - `Font`, `Text_Builder`, `text_width` (`text.odin`): the measure of a text.
// - `text_wrap_line`, `text_wrapped_line_count`, `draw_text_wrapped`
//   (`text.odin`): a text longer than its box, on more lines.
// - `Frame`, `Input`, `Interface_State`, `Element_Identity` (`input.odin`):
//   the input and the focus.
// - The elements (`elements.odin`): buttons, cards, lists, text inputs.
// - `Window_Drawing` (`window_drawing.odin`): one window from its events to
//   its surface.
//
// See [interface package](term:interface-package),
// [draw record](term:draw-record) and
// [damage by difference](term:damage-by-difference).
package interface

import "modus:contract/draw_record"
import "modus:contract/glyph_cache"
import "modus:support/display"
import "modus:support/graphics"

// The names of the contract that the package and its callers use. One
// concept keeps one name: these are the names of the contract.
DRAW_RECORD_VERSION :: draw_record.VERSION
Draw_Kind :: draw_record.Draw_Kind
Draw_Record :: draw_record.Draw_Record
Draw_Color :: draw_record.Draw_Color
Picture_Format :: draw_record.Picture_Format
COORDINATE_LIMIT :: draw_record.COORDINATE_LIMIT
STROKE_WIDTH_LIMIT :: draw_record.STROKE_WIDTH_LIMIT
Path_Point :: draw_record.Path_Point

// The ends of a line stay inside this distance of the corner of the
// surface, in pixels: the ends of its stroke, which lie half its width past
// them, then stay inside COORDINATE_LIMIT.
LINE_END_LIMIT :: COORDINATE_LIMIT - STROKE_WIDTH_LIMIT

// One cell of a text grid: a character of the font of the system, in its
// color; or, reverse, in the color of the background on a cell of its
// color; or, filled, in its color on a cell of the color background (a
// list drawn over the text, a row that is chosen). A filled cell costs 4
// bytes more than a cell with no background: 16 bytes for each cell.
//
// The cell holds a code point, not the bytes of UTF-8: one cell is one
// character, so a reader that fills a grid decodes the text once, and the
// grid compares and draws cells with no decode. A code point that the font
// lacks draws the replacement glyph (src/md/data/text_encoding.md).
Text_Grid_Cell :: struct {
	character:  rune, // A code point. 0 to 32: no character.
	reverse:    bool, // The character in the color of the background, on a cell of `color`.
	filled:     bool, // The character in `color`, on a cell of `background`.
	reserved:   [2]u8, // 0: the cell crosses the border of the drawing module, so it has no hidden byte.
	color:      graphics.Color, // The color of the character.
	background: graphics.Color, // For a filled cell.
}

#assert(size_of(Text_Grid_Cell) == 16)
#assert(align_of(Text_Grid_Cell) == 4)

// A grid of text cells: rows lines of columns cells, a line each stride
// cells. The cells of a caller that draw_text_grid copies into the text
// table; and the cells that grid_of finds there, with a stride of the
// columns.
Text_Grid :: struct {
	cells:                  []Text_Grid_Cell, // At least `rows * stride` cells.
	columns, rows, stride: int, // The cells of a line, the lines, and the cells from one line to the next.
}

// The draw records of one frame and the bytes of their texts, in the memory
// of the process. full: a record, a text or the cells of a grid did not
// fit, and is not drawn: the table is not the frame, so the next frame is
// drawn whole. refused: a record that the caller asked for could not be
// made (a picture outside each picture memory of the table, a grid whose
// cells are fewer than its size). That record is missing, and each other
// record is in the table, so the difference with the next frame stays
// exact.
Draw_Table :: struct {
	records:      []Draw_Record, // The memory of the records, from the caller.
	record_count: int, // The records of the frame so far.
	// The memory of the text table, from the caller: the bytes of the texts,
	// the cells of the grids and the points of the paths. A table with a
	// grid or a path starts at an address that is a multiple of 4, as the
	// colors of a cell and the words of a point.
	text:         []u8,
	text_count:   int, // The bytes of the text table in use.
	full:         bool, // A record, a text or the cells of a grid did not fit.
	refused:      bool, // A record that the caller asked for was not made.
	// The picture memories of the caller: each Picture record names its
	// pixels in one of them. A call of the drawing module takes one: the
	// compositor gives each part of its screen its own list of one.
	picture_memories: [][]graphics.Color,
	// The interface font that measures and draws the Text records of the
	// table in that font: the caches that the process validated (display). nil:
	// the process has none, and a text in the interface font is a text in
	// the font of the cells.
	interface_font: ^display.Interface_Font,
	// The clips of the frame that are pushed and not popped yet: each
	// record that the table takes keeps room for their pops.
	clip_depth:              int,
	// The pushes that the table did not take (past CLIP_DEPTH_LIMIT, or
	// with no room) and that are not popped yet: their pops are not
	// written either, so no pop ends a clip that the table holds.
	clip_pushes_not_written: int,
}

// A rectangle of the surface. right and bottom are not in it.
Rectangle :: struct {
	left, top, right, bottom: int, // In pixels of the surface.
}

// draw_table_clear empties a table for a new frame: no record and no text.
// The memory of the caller stays.
draw_table_clear :: proc "contextless" (table: ^Draw_Table) {
	table.record_count = 0
	table.text_count = 0
	table.full = false
	table.refused = false
	table.clip_depth = 0
	table.clip_pushes_not_written = 0
}

// draw_table_copy makes target a copy of source: the table of the frame
// before, for the next comparison. The cells of the grids are in the text
// table, so the copy of the text is the copy of the cells. It gives false
// if target is too small.
draw_table_copy :: proc "contextless" (target, source: ^Draw_Table) -> bool {
	if len(target.records) < source.record_count || len(target.text) < source.text_count {
		return false
	}
	copy(target.records[:source.record_count], source.records[:source.record_count])
	copy(target.text[:source.text_count], source.text[:source.text_count])
	target.record_count = source.record_count
	target.text_count = source.text_count
	target.full = source.full
	target.refused = source.refused
	target.picture_memories = source.picture_memories
	target.interface_font = source.interface_font
	target.clip_depth = source.clip_depth
	target.clip_pushes_not_written = source.clip_pushes_not_written
	return true
}

// grid_valid says if the cells of a grid hold each of its rows. The
// numbers come from the caller: the check divides, so a large count of
// rows or a large stride cannot wrap the product and pass.
grid_valid :: proc "contextless" (grid: Text_Grid) -> bool {
	if grid.rows < 0 || grid.columns < 0 || grid.stride < 0 {
		return false
	}
	if grid.rows == 0 || grid.columns == 0 {
		return true
	}
	if grid.stride < grid.columns || grid.columns > len(grid.cells) {
		return false
	}
	// (rows - 1) * stride + columns <= len(cells), with no product.
	return grid.rows - 1 <= (len(grid.cells) - grid.columns) / grid.stride
}

// grid_size gives the count of cells from the first cell of a grid to its
// last one, or 0 for a grid that grid_valid refuses.
grid_size :: proc "contextless" (grid: Text_Grid) -> int {
	if !grid_valid(grid) || grid.rows == 0 || grid.columns == 0 {
		return 0
	}
	return (grid.rows - 1) * grid.stride + grid.columns
}

// record_append appends one record and gives its address, or nil when the
// table is full. The room of the pops of the clips open is not taken: a
// table always ends with each push popped.
record_append :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> ^Draw_Record {
	if table.record_count >= len(table.records) - table.clip_depth {
		table.full = true
		return nil
	}
	table.records[table.record_count] = record
	table.record_count += 1
	return &table.records[table.record_count - 1]
}

// draw_rectangle appends a rectangle of one opaque color.
draw_rectangle :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, color: graphics.Color, element: u32 = 0) {
	draw_rectangle_with_alpha(table, x, y, width, height, draw_record.opaque(color), element)
}

// draw_rectangle_with_alpha appends a rectangle of one color with alpha,
// which blends over what is drawn before it: a shadow, a translucent
// panel. draw_record.with_alpha gives such a color from a token.
draw_rectangle_with_alpha :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, color: Draw_Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, placed_record(draw_record.Draw_Rectangle{color = canonical_color(color)}, element, x, y, width, height))
}

// draw_vertical_gradient appends the block of the rules: from top, on the
// first line, to bottom, on the last line, both opaque.
draw_vertical_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, top, bottom: graphics.Color, element: u32 = 0) {
	draw_vertical_gradient_with_alpha(table, x, y, width, height, draw_record.opaque(top), draw_record.opaque(bottom), element)
}

// draw_vertical_gradient_with_alpha appends a vertical gradient between two
// colors with alpha, which mix in their encoded values, alpha too: a fade
// to the same color with alpha 0 keeps the color. It is a Gradient whose
// points are the centers of the first and the last line, so line r of h
// has the level r * 255 / (h - 1). A box of one line is a rectangle of the
// top color, the color of its one line.
//
// A gradient whose first and last lines are more than GRADIENT_SPAN_LIMIT
// pixels apart, after the cut of its box to COORDINATE_LIMIT, is not
// written, and sets refused. Its points cannot be cut: the table knows the
// limit and not the surface, and the limit is far past the span, so a cut
// keeps the span; and two records of a part each would round the level of
// each part again, so the colors at the edge of a part would move. A box
// that the cut leaves empty draws nothing, and needs no record.
draw_vertical_gradient_with_alpha :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, top, bottom: Draw_Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	left, right := cut_edges(x, width)
	first, last := cut_edges(y, height)
	if last - first == 1 {
		record_append(table, record_of_pixels(draw_record.Draw_Rectangle{color = canonical_color(top)}, element, left, first, right, last))
		return
	}
	if last - first <= 0 {
		return
	}
	if last - first - 1 > draw_record.GRADIENT_SPAN_LIMIT {
		table.refused = true
		return
	}
	top_color, bottom_color := canonical_gradient_colors(top, bottom)
	HALF :: draw_record.UNITS_PER_PIXEL / 2
	gradient := draw_record.Draw_Gradient{start_x = draw_record.units_of_pixels(left), start_y = draw_record.units_of_pixels(first) + HALF, end_x = draw_record.units_of_pixels(left), end_y = draw_record.units_of_pixels(last - 1) + HALF, start_color = top_color, end_color = bottom_color}
	record_append(table, record_of_pixels(gradient, element, left, first, right, last))
}

// draw_horizontal_gradient appends a rectangle whose color goes from left,
// on its first column, to right, on its last column, both opaque.
draw_horizontal_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, left, right: graphics.Color, element: u32 = 0) {
	draw_horizontal_gradient_with_alpha(table, x, y, width, height, draw_record.opaque(left), draw_record.opaque(right), element)
}

// draw_horizontal_gradient_with_alpha appends a horizontal gradient between
// two colors with alpha, as draw_vertical_gradient_with_alpha, with the
// points at the centers of the first and the last column; a span past
// GRADIENT_SPAN_LIMIT sets refused in the same way.
draw_horizontal_gradient_with_alpha :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, left, right: Draw_Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	first, last := cut_edges(x, width)
	top, bottom := cut_edges(y, height)
	if last - first == 1 {
		record_append(table, record_of_pixels(draw_record.Draw_Rectangle{color = canonical_color(left)}, element, first, top, last, bottom))
		return
	}
	if last - first <= 0 {
		return
	}
	if last - first - 1 > draw_record.GRADIENT_SPAN_LIMIT {
		table.refused = true
		return
	}
	left_color, right_color := canonical_gradient_colors(left, right)
	HALF :: draw_record.UNITS_PER_PIXEL / 2
	gradient := draw_record.Draw_Gradient{start_x = draw_record.units_of_pixels(first) + HALF, start_y = draw_record.units_of_pixels(top), end_x = draw_record.units_of_pixels(last - 1) + HALF, end_y = draw_record.units_of_pixels(top), start_color = left_color, end_color = right_color}
	record_append(table, record_of_pixels(gradient, element, first, top, last, bottom))
}

// draw_gradient appends a gradient along any line, in a box: the two
// points and the four edges of the box are in units of 1/64 pixel of the
// surface (draw_record.UNITS_PER_PIXEL), so the box can start and end
// inside a pixel, whose part inside the box scales its alpha. A box or a
// line that the border refuses is not written, and sets refused: two equal
// points, a point or an edge past COORDINATE_LIMIT, points further apart
// than GRADIENT_SPAN_LIMIT.
draw_gradient :: proc "contextless" (table: ^Draw_Table, left, top, right, bottom: i32, start_x, start_y, end_x, end_y: i32, start, end: Draw_Color, element: u32 = 0) {
	if right <= left || bottom <= top {
		return
	}
	start_color, end_color := canonical_gradient_colors(start, end)
	gradient := draw_record.Draw_Gradient{start_x = start_x, start_y = start_y, end_x = end_x, end_y = end_y, start_color = start_color, end_color = end_color}
	record := draw_record.record_of(gradient, element, left, top, right, bottom)
	if _, problem := draw_record.read(record); problem != .None {
		table.refused = true
		return
	}
	record_append(table, record)
}

// draw_rectangle_in_units appends a rectangle of one color with alpha whose
// edges are in units of 1/64 pixel of the surface: a pixel that the box
// covers in part blends with the alpha of the color times that part, so an
// edge can lie between two pixels. A box that the border refuses (an edge
// past COORDINATE_LIMIT) is not written, and sets refused.
draw_rectangle_in_units :: proc "contextless" (table: ^Draw_Table, left, top, right, bottom: i32, color: Draw_Color, element: u32 = 0) {
	if right <= left || bottom <= top {
		return
	}
	record := draw_record.record_of(draw_record.Draw_Rectangle{color = canonical_color(color)}, element, left, top, right, bottom)
	if _, problem := draw_record.read(record); problem != .None {
		table.refused = true
		return
	}
	record_append(table, record)
}

// canonical_color gives the one form of a color of one color: a color with
// alpha 0 draws nothing, whatever its channels, and is 0, so the border
// reads the record and two such records have the same bytes.
@(private)
canonical_color :: proc "contextless" (color: Draw_Color) -> Draw_Color {
	return draw_record.alpha_of(color) == 0 ? 0 : color
}

// canonical_gradient_colors gives the one form of the two colors of a
// gradient: the channels of one end with alpha 0 color the mix, so they
// stay, and two ends with alpha 0 are both 0.
@(private)
canonical_gradient_colors :: proc "contextless" (first, second: Draw_Color) -> (Draw_Color, Draw_Color) {
	if draw_record.alpha_of(first) == 0 && draw_record.alpha_of(second) == 0 {
		return 0, 0
	}
	return first, second
}

// The grid of points of the background (docs/DESIGN.md, "3. Surfaces") as
// the pattern of a Rectangle: a point of POINT_SIZE pixels at
// POINT_STEP / 2 + n * POINT_STEP of the surface on each axis. The pattern
// is placed on the surface, so two areas of one surface show one grid.
POINT_GRID_PATTERN :: draw_record.Repetition {
	cell_x      = graphics.POINT_STEP / 2 * draw_record.UNITS_PER_PIXEL,
	cell_y      = graphics.POINT_STEP / 2 * draw_record.UNITS_PER_PIXEL,
	cell_width  = graphics.POINT_SIZE * draw_record.UNITS_PER_PIXEL,
	cell_height = graphics.POINT_SIZE * draw_record.UNITS_PER_PIXEL,
	step_x      = graphics.POINT_STEP * draw_record.UNITS_PER_PIXEL,
	step_y      = graphics.POINT_STEP * draw_record.UNITS_PER_PIXEL,
}

// draw_point_grid appends the grid of points of the background: one
// Rectangle whose pattern is the grid, cut to the area.
draw_point_grid :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	record_append(table, placed_record(draw_record.Draw_Rectangle{color = draw_record.opaque(graphics.colors.point), repetition = POINT_GRID_PATTERN}, 0, x, y, width, height))
}

// draw_folded_gap appends a part with no measure on this scale: the track,
// then two lines at an angle, from the bottom left up to the right
// (docs/DESIGN.md, "2. Forms"). Two records, each with the box of the gap:
// the track, and one Path of two subpaths, the two lines stroked 1 pixel
// wide as draw_line strokes them. The lines are cut to the gap, as the
// pixels of the gap always were, so their ends can lie on its right edge.
// A line with an end past LINE_END_LIMIT is left out: no surface reaches
// it.
draw_folded_gap :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	draw_rectangle(table, x, y, width, height, graphics.colors.track, element)
	lines := [2][4]int{{x + 2, y + height - 4, x + width - 4, y + 4}, {x + 6, y + height - 4, x + width, y + 8}}
	points: [4]Path_Point
	count := 0
	for line in lines {
		if !inside_line_limit(line[0]) || !inside_line_limit(line[1]) || !inside_line_limit(line[2]) || !inside_line_limit(line[3]) {
			continue
		}
		start_x, start_y, end_x, end_y := line_ends_in_order(line[0], line[1], line[2], line[3])
		ends := line_points(start_x, start_y, end_x, end_y, 1)
		points[count], points[count + 1] = ends[0], ends[1]
		count += 2
	}
	if count == 0 {
		return
	}
	left, right := cut_edges(x, width)
	top, bottom := cut_edges(y, height)
	path_append(table, points[:count], 0, draw_record.opaque(graphics.colors.dim), draw_record.UNITS_PER_PIXEL, element, {left, top, right, bottom})
}

// draw_picture appends the pixels of a picture of the process at (x, y).
// Each pixel of the picture must be inside one picture memory of the table:
// the record names the first such memory, the index of the first pixel in
// it, and the stride. generation is a new number each time its pixels
// change: the difference sees the change. A picture with no pixel, or with
// a pixel outside each picture memory, is refused. Each pixel is
// 0x00RRGGBB, copied as it is.
draw_picture :: proc "contextless" (table: ^Draw_Table, x, y: int, picture: graphics.Canvas, generation: u32, element: u32 = 0) {
	picture_append(table, x, y, picture, generation, .Opaque, element)
}

// draw_picture_with_alpha appends a picture as draw_picture does, whose
// pixels are 0xAARRGGBB with straight alpha: each blends over what is drawn
// before it, by the rule of the colors.
draw_picture_with_alpha :: proc "contextless" (table: ^Draw_Table, x, y: int, picture: graphics.Canvas, generation: u32, element: u32 = 0) {
	picture_append(table, x, y, picture, generation, .Straight_Alpha, element)
}

// picture_append appends the record of a picture in a format.
@(private)
picture_append :: proc "contextless" (table: ^Draw_Table, x, y: int, picture: graphics.Canvas, generation: u32, format: Picture_Format, element: u32) {
	memory, first, found := picture_place(table, picture)
	if !found {
		table.refused = true
		return
	}
	record_append(table, placed_record(draw_record.Draw_Picture{memory = u8(memory), format = format, first = u32(first), stride = u32(picture.stride), generation = generation}, element, x, y, picture.width, picture.height))
}

// picture_place finds the picture memory that holds each pixel of a
// picture, and the index of its first pixel there. The numbers fit the
// fields of a record: at most 256 memories, a first pixel and a stride
// below 2^32, a size that an i32 holds; so the sum below cannot wrap.
@(private)
picture_place :: proc "contextless" (table: ^Draw_Table, picture: graphics.Canvas) -> (memory, first: int, found: bool) {
	if picture.width <= 0 || picture.height <= 0 || picture.width > int(max(i32)) || picture.height > int(max(i32)) || picture.stride < picture.width || u64(picture.stride) > u64(max(u32)) {
		return 0, 0, false
	}
	address := uintptr(picture.pixels)
	for pixels, number in table.picture_memories[:min(len(table.picture_memories), 256)] {
		start := uintptr(raw_data(pixels))
		if address < start || (address - start) % size_of(graphics.Color) != 0 {
			continue
		}
		index := u64(address - start) / size_of(graphics.Color)
		if index > u64(max(u32)) {
			continue
		}
		if index + u64(picture.height - 1) * u64(picture.stride) + u64(picture.width) <= u64(len(pixels)) {
			return number, int(index), true
		}
	}
	return 0, 0, false
}

// picture_of gives the pixels that a Picture record names, as a canvas, or
// false when the record is not a Picture that the border reads, or names a
// memory that the table does not have, a picture with no pixel, a stride
// below its width, or a pixel past its memory.
picture_of :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> (picture: graphics.Canvas, ok: bool) {
	primitive, problem := draw_record.read(record)
	fields, is_picture := primitive.(draw_record.Draw_Picture)
	if problem != .None || !is_picture {
		return {}, false
	}
	return picture_pixels(table, record_rectangle(record), fields)
}

// picture_pixels gives the pixels of a picture that the border read, in
// its rectangle. A record that a caller wrote by hand can have any bytes,
// and the check is in integers that cannot wrap: each factor is below 2^32.
@(private)
picture_pixels :: proc "contextless" (table: ^Draw_Table, place: Rectangle, fields: draw_record.Draw_Picture) -> (picture: graphics.Canvas, ok: bool) {
	number := int(fields.memory)
	width, height := place.right - place.left, place.bottom - place.top
	if number >= len(table.picture_memories) || width <= 0 || height <= 0 || width > int(max(u32)) || height > int(max(u32)) {
		return {}, false
	}
	pixels := table.picture_memories[number]
	first, stride := u64(fields.first), u64(fields.stride)
	if stride < u64(width) || first + u64(height - 1) * stride + u64(width) > u64(len(pixels)) {
		return {}, false
	}
	return {pixels = raw_data(pixels[first:]), width = width, height = height, stride = int(stride)}, true
}

// The most cells of one grid: the bytes of its cells fit the u32 of a
// record, and a record of a grid fits the i32 of its size.
GRID_CELL_LIMIT :: 1 << 24

// draw_text_grid appends a grid of cells of the caller at (x, y): one cell
// of the font of the system for each cell of the grid. The cells are
// copied into the text table, row after row with no gap, at a place that
// is a multiple of 4 bytes: the record holds values only, and the drawing
// module reads the cells in the text table (src/md/api/text_grid.md). A
// grid whose cells are fewer than its rows, of more than GRID_CELL_LIMIT
// cells, or in a table whose text does not start at a multiple of 4, is
// refused. A grid that does not fit the text table makes the table full.
draw_text_grid :: proc "contextless" (table: ^Draw_Table, x, y: int, grid: Text_Grid, element: u32 = 0) {
	if !grid_valid(grid) || grid.columns > GRID_CELL_LIMIT || grid.rows > GRID_CELL_LIMIT / max(grid.columns, 1) || uintptr(raw_data(table.text)) % align_of(Text_Grid_Cell) != 0 {
		table.refused = true
		return
	}
	cell_count := grid.columns * grid.rows
	start := (table.text_count + align_of(Text_Grid_Cell) - 1) / align_of(Text_Grid_Cell) * align_of(Text_Grid_Cell)
	size := cell_count * size_of(Text_Grid_Cell)
	if start + size > len(table.text) || table.record_count >= len(table.records) {
		table.full = true
		return
	}
	if cell_count > 0 {
		cells := ([^]Text_Grid_Cell)(&table.text[start])[:cell_count]
		for row in 0 ..< grid.rows {
			copy(cells[row * grid.columns:][:grid.columns], grid.cells[row * grid.stride:][:grid.columns])
		}
	}
	table.text_count = start + size
	record_append(table, placed_record(draw_record.Draw_Text_Grid{first = u32(start), count = u32(size), columns = u32(grid.columns)}, element, x, y, grid.columns * graphics.CELL_WIDTH, grid.rows * graphics.CELL_HEIGHT))
}

// grid_of gives the cells that a Text_Grid record names in the text table
// of its table, or false when the record is not a Text_Grid that the
// border reads.
grid_of :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> (grid: Text_Grid, ok: bool) {
	primitive, problem := draw_record.read(record)
	fields, is_grid := primitive.(draw_record.Draw_Text_Grid)
	if problem != .None || !is_grid {
		return {}, false
	}
	return grid_cells(table, fields)
}

// grid_cells gives the cells of a grid that the border read, or false when
// it names no column, bytes that are not a whole count of rows, a range
// past the text table, or a place whose address is not a multiple of 4. A
// record that a caller wrote by hand can have any bytes: the sums are in 64
// bits from values below 2^32, so no range wraps. A grid of no row is
// valid, and draws nothing.
@(private)
grid_cells :: proc "contextless" (table: ^Draw_Table, fields: draw_record.Draw_Text_Grid) -> (grid: Text_Grid, ok: bool) {
	start, count, columns := u64(fields.first), u64(fields.count), u64(fields.columns)
	row_bytes := columns * size_of(Text_Grid_Cell)
	if columns == 0 || count % row_bytes != 0 || start + count > u64(table.text_count) || start + count > u64(len(table.text)) {
		return {}, false
	}
	if count == 0 {
		return {columns = int(columns), stride = int(columns)}, true
	}
	if (uintptr(raw_data(table.text)) + uintptr(start)) % align_of(Text_Grid_Cell) != 0 {
		return {}, false
	}
	cells := ([^]Text_Grid_Cell)(&table.text[start])[:count / size_of(Text_Grid_Cell)]
	return {cells = cells, columns = int(columns), rows = int(count / row_bytes), stride = int(columns)}, true
}

// text_of_record gives the text of a Text record, in either font, with its
// scale, or false for another record, a record that the border refuses, or
// a range outside the text table. A tool and a test find a text of a frame
// with it.
text_of_record :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> (text: string, scale: int, ok: bool) {
	primitive, problem := draw_record.read(record)
	if problem != .None {
		return "", 0, false
	}
	first, count: u32
	switch fields in primitive {
	case draw_record.Draw_Text:
		first, count, scale = fields.first, fields.count, int(fields.scale)
	case draw_record.Draw_Nothing, draw_record.Draw_Clip_Push, draw_record.Draw_Clip_Pop, draw_record.Draw_Rectangle, draw_record.Draw_Gradient, draw_record.Draw_Picture, draw_record.Draw_Text_Grid, draw_record.Draw_Path:
		return "", 0, false
	}
	if u64(first) + u64(count) > u64(table.text_count) || u64(first) + u64(count) > u64(len(table.text)) {
		return "", 0, false
	}
	return string(table.text[first:][:count]), scale, true
}

// draw_line appends a straight line from one pixel to another, with a
// thickness in pixels: a Path of one segment, stroked, whose two ends go
// half the thickness past the two pixels. The line runs through the
// centers of the squares that the line of before drew at its two ends, so
// a line across or down covers whole pixels, those of before; a line at an
// angle has antialiased edges. The path always goes from the left end (the
// top end when the two ends have one x), so a line and its reverse are one
// record and draw the same pixels. A thickness of 0 or less draws nothing;
// a thickness past STROKE_WIDTH_LIMIT is cut to it. A line with an end past
// LINE_END_LIMIT is refused: no record. A line of length 0 is one square of
// its thickness.
draw_line :: proc "contextless" (table: ^Draw_Table, from_x, from_y, to_x, to_y: int, thickness: int, color: graphics.Color, element: u32 = 0) {
	if thickness <= 0 {
		return
	}
	if !inside_line_limit(from_x) || !inside_line_limit(from_y) || !inside_line_limit(to_x) || !inside_line_limit(to_y) {
		return
	}
	side := min(thickness, STROKE_WIDTH_LIMIT)
	start_x, start_y, end_x, end_y := line_ends_in_order(from_x, from_y, to_x, to_y)
	ends := line_points(start_x, start_y, end_x, end_y, side)
	// The box of the four corners of the band, which the execution computes
	// from the same two points: a line across or down has the box of its
	// squares, its damage before.
	width := i64(side) * draw_record.UNITS_PER_PIXEL
	normal_x, normal_y := segment_normal(i64(ends[1].x) - i64(ends[0].x), i64(ends[1].y) - i64(ends[0].y), width)
	reach_x, reach_y := abs(normal_x), abs(normal_y)
	left := min(i64(ends[0].x), i64(ends[1].x)) - reach_x
	top := min(i64(ends[0].y), i64(ends[1].y)) - reach_y
	right := max(i64(ends[0].x), i64(ends[1].x)) + reach_x
	bottom := max(i64(ends[0].y), i64(ends[1].y)) + reach_y
	box := units_box_rounded_out(left, top, right, bottom)
	path_append(table, ends[:], 0, draw_record.opaque(color), i32(width), element, box)
}

// units_box_rounded_out gives the box of whole pixels that holds a box in
// units, each edge cut to COORDINATE_LIMIT. Each edge is at most an i32
// and a reach of a stroke, so the pixels fit an int.
@(private)
units_box_rounded_out :: proc "contextless" (left, top, right, bottom: i64) -> Rectangle {
	UNITS :: draw_record.UNITS_PER_PIXEL
	return {cut_place(int(left >> draw_record.UNIT_SHIFT)), cut_place(int(top >> draw_record.UNIT_SHIFT)), cut_place(int((right + UNITS - 1) >> draw_record.UNIT_SHIFT)), cut_place(int((bottom + UNITS - 1) >> draw_record.UNIT_SHIFT))}
}

// line_points gives the two points of the stroke of a line between two
// pixels, side pixels wide, in units: the center of the square of side
// pixels that starts side / 2 pixels before each pixel, then half the side
// further along the line at each end, so the stroke covers those squares
// at the two ends. A line of length 0 goes across its one square. The ends
// are inside LINE_END_LIMIT, so each place fits an i32.
@(private)
line_points :: proc "contextless" (start_x, start_y, end_x, end_y, side: int) -> [2]Path_Point {
	UNITS :: draw_record.UNITS_PER_PIXEL
	center :: proc "contextless" (place, side: int) -> i64 {
		return i64(place - side / 2) * UNITS + i64(side) * UNITS / 2
	}
	half := i64(side) * UNITS / 2
	first_x, first_y := center(start_x, side), center(start_y, side)
	last_x, last_y := center(end_x, side), center(end_y, side)
	along_x, along_y := half, i64(0)
	if first_x != last_x || first_y != last_y {
		// A quarter turn back of the normal is the direction, half the side
		// long.
		along_x, along_y = segment_normal(last_y - first_y, first_x - last_x, 2 * half)
	}
	return {{command = .Move, x = i32(first_x - along_x), y = i32(first_y - along_y)}, {command = .Line, x = i32(last_x + along_x), y = i32(last_y + along_y)}}
}

// draw_path appends a path. Its points are places in units of 1/64 pixel
// of the surface (draw_record.UNITS_PER_PIXEL): they go into the text
// table at a multiple of 4 bytes, and the record gets the box that holds
// each pixel that it draws: the box of its points, control points too,
// grown by half the width of its stroke, rounded out to whole pixels and
// cut to COORDINATE_LIMIT. fill and stroke are colors with alpha, 0 for no
// fill or no stroke; a stroke_width in units of 0 or below is no stroke. A
// stroke color of alpha 0 is no stroke whatever the width, also a width past
// STROKE_WIDTH_LIMIT: the record has the stroke color 0 and the width 0.
// Points that the border of the points refuses (draw_record.path_points_read),
// a stroke wider than STROKE_WIDTH_LIMIT pixels, and a table whose text does
// not start at a multiple of 4 are refused: no record, and refused is set.
// Points that do not fit the text table make the table full.
draw_path :: proc "contextless" (table: ^Draw_Table, points: []Path_Point, fill, stroke: Draw_Color, stroke_width: i32, element: u32 = 0) {
	if len(points) == 0 {
		table.refused = true
		return
	}
	left, top := i64(max(i64)), i64(max(i64))
	right, bottom := i64(min(i64)), i64(min(i64))
	for point in points {
		if point.command == .Close {
			continue
		}
		left, top = min(left, i64(point.x)), min(top, i64(point.y))
		right, bottom = max(right, i64(point.x)), max(bottom, i64(point.y))
	}
	if left > right {
		table.refused = true
		return
	}
	if stroke_width > 0 && draw_record.alpha_of(stroke) != 0 {
		reach := (i64(stroke_width) + 1) / 2
		left, top, right, bottom = left - reach, top - reach, right + reach, bottom + reach
	}
	path_append(table, points, fill, stroke, stroke_width, element, units_box_rounded_out(left, top, right, bottom))
}

// path_append appends a path in a box of whole pixels inside
// COORDINATE_LIMIT, which cuts it. The colors and the width take their
// canonical form: a color with alpha 0 is 0, and no stroke has the color 0
// and the width 0.
@(private)
path_append :: proc "contextless" (table: ^Draw_Table, points: []Path_Point, fill, stroke: Draw_Color, stroke_width: i32, element: u32, box: Rectangle) {
	fill_color, stroke_color := canonical_color(fill), canonical_color(stroke)
	width := stroke_width
	if stroke_color == 0 || width <= 0 {
		stroke_color, width = 0, 0
	}
	if width > draw_record.STROKE_WIDTH_UNIT_LIMIT || len(points) < 2 || len(points) > draw_record.PATH_POINT_LIMIT || uintptr(raw_data(table.text)) % align_of(draw_record.Path_Point_Record) != 0 {
		table.refused = true
		return
	}
	start := (table.text_count + align_of(draw_record.Path_Point_Record) - 1) / align_of(draw_record.Path_Point_Record) * align_of(draw_record.Path_Point_Record)
	size := len(points) * draw_record.PATH_POINT_SIZE
	if start + size > len(table.text) || table.record_count >= len(table.records) {
		table.full = true
		return
	}
	records := ([^]draw_record.Path_Point_Record)(&table.text[start])[:len(points)]
	for point, index in points {
		records[index] = {command = u32(point.command), x = point.x, y = point.y}
	}
	// The border of the points, on the bytes that the reader reads: a
	// command that a caller made from a number is checked too.
	if draw_record.path_points_check(records) != .None {
		table.refused = true
		return
	}
	table.text_count = start + size
	path := draw_record.Draw_Path{first = u32(start), count = u32(size), fill_color = fill_color, stroke_color = stroke_color, stroke_width = u32(width)}
	record_append(table, record_of_pixels(path, element, box.left, box.top, box.right, box.bottom))
}

// path_of gives the points that a Path record names in the text table of
// its table, through the border of the points, into points: false when
// the record is not a Path that the border reads, or names points that the
// table does not hold or that the border of the points refuses. A test and
// a tool read the points of a frame with it.
path_of :: proc "contextless" (table: ^Draw_Table, record: Draw_Record, points: []Path_Point) -> (count: int, ok: bool) {
	primitive, problem := draw_record.read(record)
	fields, is_path := primitive.(draw_record.Draw_Path)
	if problem != .None || !is_path {
		return 0, false
	}
	start, size := u64(fields.first), u64(fields.count)
	if start + size > u64(table.text_count) || start + size > u64(len(table.text)) || (uintptr(raw_data(table.text)) + uintptr(start)) % align_of(draw_record.Path_Point_Record) != 0 {
		return 0, false
	}
	records := ([^]draw_record.Path_Point_Record)(&table.text[start])[:int(size / draw_record.PATH_POINT_SIZE)]
	read_count, points_problem := draw_record.path_points_read(records, points)
	return read_count, points_problem == .None
}

// draw_outline appends the border of a rectangle, thickness pixels wide
// inside it, as four rectangles.
draw_outline :: proc "contextless" (table: ^Draw_Table, x, y, width, height, thickness: int, color: graphics.Color, element: u32 = 0) {
	side := min(thickness, width / 2, height / 2)
	if side <= 0 {
		return
	}
	draw_rectangle(table, x, y, width, side, color, element)
	draw_rectangle(table, x, y + height - side, width, side, color, element)
	draw_rectangle(table, x, y + side, side, height - 2 * side, color, element)
	draw_rectangle(table, x + width - side, y + side, side, height - 2 * side, color, element)
}

// inside_line_limit says if a place can be an end of a line. A comparison,
// not abs: abs of the smallest int is still negative.
inside_line_limit :: proc "contextless" (value: int) -> bool {
	return value >= -LINE_END_LIMIT && value <= LINE_END_LIMIT
}

// line_ends_in_order gives the two ends of a line with the left end first,
// or the top end first when the two ends have one x: one order gives one
// path, so a line and its reverse are one record.
line_ends_in_order :: proc "contextless" (from_x, from_y, to_x, to_y: int) -> (start_x, start_y, end_x, end_y: int) {
	if to_x < from_x || to_x == from_x && to_y < from_y {
		return to_x, to_y, from_x, from_y
	}
	return from_x, from_y, to_x, to_y
}

// draw_clip_push appends a push of a clip: the records after it, until its
// draw_clip_pop, are cut to the rectangle and to each clip open before it.
// A width or a height below 1 is an empty clip: the records under it draw
// nothing. The table writes no order of clips that the border of the order
// refuses (src/md/api/draw_table.md, "The kinds"): a push past
// CLIP_DEPTH_LIMIT is not written and sets refused, a push with no room for
// itself and its pop sets full, and the pop of a push that is not written
// is not written. The records under a push that is not written are cut by
// the clips that the table holds.
draw_clip_push :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	if table.clip_depth >= draw_record.CLIP_DEPTH_LIMIT {
		table.refused = true
	}
	if table.clip_pushes_not_written > 0 || table.clip_depth >= draw_record.CLIP_DEPTH_LIMIT {
		table.clip_pushes_not_written += 1
		return
	}
	// Room for the push, its pop and the pops of the clips open.
	if table.record_count + table.clip_depth + 2 > len(table.records) {
		table.full = true
		table.clip_pushes_not_written += 1
		return
	}
	table.records[table.record_count] = placed_record(draw_record.Draw_Clip_Push{}, 0, x, y, max(width, 0), max(height, 0))
	table.record_count += 1
	table.clip_depth += 1
}

// draw_clip_pop appends the pop of the last clip open: the records after it
// are cut as before its push. A pop with no push open is not written and
// sets refused. Its room was kept when its push was written.
draw_clip_pop :: proc "contextless" (table: ^Draw_Table) {
	if table.clip_pushes_not_written > 0 {
		table.clip_pushes_not_written -= 1
		return
	}
	if table.clip_depth == 0 {
		table.refused = true
		return
	}
	// The room is kept, unless a caller gave the table other records
	// while a clip was open.
	if table.record_count >= len(table.records) {
		table.full = true
		table.clip_depth -= 1
		return
	}
	table.records[table.record_count] = draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0)
	table.record_count += 1
	table.clip_depth -= 1
}

// draw_clips_close pops each clip that the frame left open, and sets
// refused when one was: a push with no pop is a fault of the writer, and a
// table with one is refused by the border of the order.
draw_clips_close :: proc "contextless" (table: ^Draw_Table) {
	if table.clip_depth == 0 && table.clip_pushes_not_written == 0 {
		return
	}
	table.refused = true
	for table.clip_depth > 0 || table.clip_pushes_not_written > 0 {
		draw_clip_pop(table)
	}
}

// draw_text appends a run of text at (x, y), the top left corner of its
// first character, and gives the x after its last character. The record is
// a Text in the interface font when the table has the font (font_in_use),
// else a Text in the font of the cells, whose origin is the left edge of
// its box. A text in the font of the cells that starts past
// COORDINATE_LIMIT has no record: no surface reaches it, and its origin
// would leave its box.
draw_text :: proc "contextless" (table: ^Draw_Table, x, y: int, text: string, color: graphics.Color, font: Font = {}, element: u32 = 0) -> int {
	return draw_text_with_alpha(table, x, y, text, draw_record.opaque(color), font, element)
}

// draw_text_with_alpha appends a run of text as draw_text does, in a color
// with alpha: the alpha scales the cover of each pixel of its ink, in each
// font. draw_record.with_alpha gives such a color from a token.
draw_text_with_alpha :: proc "contextless" (table: ^Draw_Table, x, y: int, text: string, draw_color: Draw_Color, font: Font = {}, element: u32 = 0) -> int {
	color := draw_record.channels_of(draw_color)
	alpha := draw_record.alpha_of(draw_color)
	used := font_in_use(table, font, len(text))
	if used.kind == .Interface {
		return interface_text_append(table, i64(x) * 64, y, text, color, used, element, alpha)
	}
	width := text_width(used, text)
	if len(text) == 0 {
		return x
	}
	if x < -COORDINATE_LIMIT || x > COORDINATE_LIMIT - 1 {
		return x + width
	}
	if table.text_count + len(text) > len(table.text) {
		table.full = true
		return x + width
	}
	start := table.text_count
	copy(table.text[start:], text)
	table.text_count += len(text)
	scale := font_scale(used)
	fields := draw_record.Draw_Text{first = u32(start), count = u32(len(text)), color = draw_record.with_alpha(color, alpha), origin_x = draw_record.units_of_pixels(x), font = .Cells_8x16, scale = u8(scale), weight = used.weight}
	record_append(table, placed_record(fields, element, x, y, width, graphics.CELL_HEIGHT * scale))
	return x + width
}

// draw_text_right appends a run of text that ends at right. In the
// interface font the origin is at a third of a pixel, so the end is at
// right or at most a third of a pixel before it.
draw_text_right :: proc "contextless" (table: ^Draw_Table, right, y: int, text: string, color: graphics.Color, font: Font = {}, element: u32 = 0) {
	used := font_in_use(table, font, len(text))
	if used.kind == .Interface {
		// The origin goes to the nearest third of a pixel, which can be up to
		// 10.7 / 64 of a pixel to the right: 11 / 64 less makes it the third
		// at or before the exact place, so the text never passes right.
		interface_text_append(table, i64(right) * 64 - interface_width_subpixels(table.interface_font, used, text) - 11, y, text, color, used, element)
		return
	}
	draw_text(table, right - text_width(used, text), y, text, color, used, element)
}

// interface_text_append appends a text in the interface font whose origin
// is at place, in 1/64 of a pixel, rounded to the nearest third of a pixel
// (the positions of the glyph cache), and gives the x of the end of its
// measured box, rounded up. The box of the record is the measured box grown
// by the ink margin of the font on each side (graphics.PROPORTIONAL_INK_MARGIN
// times the scale), so the damage of the record holds each pixel of its ink.
// A text whose box would start past COORDINATE_LIMIT has no record: no
// surface reaches it, and its origin would leave its box. alpha is the
// alpha of the color.
@(private)
interface_text_append :: proc "contextless" (table: ^Draw_Table, place: i64, y: int, text: string, color: graphics.Color, font: Font, element: u32, alpha: u8 = draw_record.OPAQUE_ALPHA) -> int {
	width := interface_width_subpixels(table.interface_font, font, text)
	pixel, third := glyph_cache.position_of(place, 3)
	origin := pixel * 64 + i64(third) * 64 / 3
	end := int((origin + width + 63) / 64)
	if len(text) == 0 {
		return end
	}
	scale := font_scale(font)
	margin := graphics.PROPORTIONAL_INK_MARGIN * scale
	left := int(pixel) - margin
	if left < -COORDINATE_LIMIT || left > COORDINATE_LIMIT - 1 {
		return end
	}
	if table.text_count + len(text) > len(table.text) {
		table.full = true
		return end
	}
	start := table.text_count
	copy(table.text[start:], text)
	table.text_count += len(text)
	fields := draw_record.Draw_Text{first = u32(start), count = u32(len(text)), color = draw_record.with_alpha(color, alpha), origin_x = i32(origin), font = .Interface, scale = u8(scale), weight = font.weight}
	// The top and the bottom by the rule of each writer: the edges of a
	// place and a size, each cut to the limit, so no sum passes the int.
	top, bottom := cut_edges(y, graphics.CELL_HEIGHT * scale)
	record_append(table, record_of_pixels(fields, element, left, top, cut_place(end + margin), bottom))
	return end
}

// placed_record gives the record of a primitive in the rectangle of a
// place and a size, in pixels, cut to COORDINATE_LIMIT.
@(private)
placed_record :: proc "contextless" (primitive: draw_record.Draw_Primitive, element: u32, x, y, width, height: int) -> Draw_Record {
	left, right := cut_edges(x, width)
	top, bottom := cut_edges(y, height)
	return record_of_pixels(primitive, element, left, top, right, bottom)
}

// record_of_pixels gives the record of a primitive in a box of edges in
// pixels that are inside COORDINATE_LIMIT.
@(private)
record_of_pixels :: proc "contextless" (primitive: draw_record.Draw_Primitive, element: u32, left, top, right, bottom: int) -> Draw_Record {
	return draw_record.record_of(primitive, element, draw_record.units_of_pixels(left), draw_record.units_of_pixels(top), draw_record.units_of_pixels(right), draw_record.units_of_pixels(bottom))
}

// cut_edges gives the two edges of a place and a size, each cut to
// COORDINATE_LIMIT. Each edge is cut, then the size is the difference of
// the two edges: a cut place with its own cut size would move the other
// edge, so a rectangle that covers the surface could draw nothing. The sum
// of the two numbers cannot pass the int.
@(private)
cut_edges :: proc "contextless" (place, size: int) -> (start, end: int) {
	switch {
	case size >= 0 && place > max(int) - size:
		end = max(int)
	case size < 0 && place < min(int) - size:
		end = min(int)
	case:
		end = place + size
	}
	return cut_place(place), cut_place(end)
}

// cut_place cuts one edge to COORDINATE_LIMIT.
@(private)
cut_place :: proc "contextless" (place: int) -> int {
	return clamp(place, -COORDINATE_LIMIT, COORDINATE_LIMIT - 1)
}

// record_rectangle gives the rectangle of the box of a record, in whole
// pixels: the damage of the record. A box that is not on whole pixels
// grows to the pixels that it touches, and a box whose right is left of its
// left is empty. It reads the box of a record that the border refuses too:
// such a record draws nothing, and its box is still the damage of a change.
record_rectangle :: proc "contextless" (record: Draw_Record) -> Rectangle {
	return {draw_record.pixels_floor(record.left), draw_record.pixels_floor(record.top), draw_record.pixels_ceiling(record.right), draw_record.pixels_ceiling(record.bottom)}
}

// draw_unsigned appends a number in decimal, with at least minimum_digits
// digits, and gives the x after it.
draw_unsigned :: proc "contextless" (table: ^Draw_Table, x, y: int, value: u64, color: graphics.Color, minimum_digits := 1) -> int {
	builder: Text_Builder
	return draw_text(table, x, y, number_text(&builder, value, minimum_digits), color)
}

// draw_character appends one character, and gives the x after it.
draw_character :: proc "contextless" (table: ^Draw_Table, x, y: int, character: u8, color: graphics.Color) -> int {
	one := [1]u8{character}
	return draw_text(table, x, y, string(one[:]), color)
}
