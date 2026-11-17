// The interface package (docs/INTERFACE.md): a program describes its window
// again at each frame, and each call appends draw records to a draw table
// in the memory of the program. The package finds the damage by a
// comparison with the table of the frame before, and draws the records into
// the surface of the program. It never allocates. The core files (the draw
// table, its execution, the difference, the layout, the text, the input,
// the elements) make no kernel call; window_drawing.odin does: it reads the
// events of a window and presents its surface.
//
// Who uses it: each program with a window (the console, the bar, the
// developer tools, the settings). The parts:
//
// - `Draw_Table`, `Draw_Record`, `Draw_Kind`: the frame as records
//   (`draw_rectangle`, `draw_text` and the other `draw_` procedures).
// - `Damage`, `records_equal` (`difference.odin`): what changed since the
//   frame before.
// - `execute`, `execute_in_rectangles` (`execute.odin`): the records drawn
//   into a canvas.
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

import "modus:contract/glyph_cache"
import "modus:support/display"
import "modus:support/graphics"

// The version of the draw records: a new kind of record, or a new field,
// is a new version. The drawing module and the window agree on it.
DRAW_RECORD_VERSION :: 10

// What one draw record draws. The fields of `Draw_Record` that each kind
// reads are in the comment of the member.
Draw_Kind :: enum u8 {
	None                = 0, // Nothing: a record of this kind is not drawn.
	Rectangle           = 1, // One color.
	Vertical_Gradient   = 2, // first_color at the top line, second_color at the bottom line.
	Horizontal_Gradient = 3, // first_color at the left column, second_color at the right column.
	Text                = 4, // The bytes text_start ..< text_start + text_count of the text table, in first_color.
	Clip                = 5, // The next records are cut to this rectangle. Width 0: no cut.
	Point_Grid          = 6, // The grid of points of the background (docs/DESIGN.md, section 3), in first_color.
	// A part with no measure on this scale: the track with two lines at an
	// angle in first_color, the one meaning of such lines (docs/DESIGN.md,
	// section 2).
	Folded_Gap          = 7,
	// The pixels of a picture of the caller, width x height at (x, y):
	// kind_detail is the number of its picture memory in
	// Draw_Table.picture_memories, text_start the index of its first pixel
	// in that memory, second_color its stride (the pixels from one line to
	// the next), text_count its generation (a new number when its pixels
	// change). Each is a value, so the record means the same in each
	// address space (docs/INTERFACE.md, section 2.1).
	Picture             = 8,
	// A grid of text cells: the cells are a copy in the text table, row
	// after row, from the byte text_start, text_count bytes; second_color is
	// the columns. Each is a value, so the drawing module reads the cells
	// in the text table that it already has. The cells are drawn on the
	// background that the frame paints. The difference compares the cells
	// one by one: a changed cell damages only its row span
	// (docs/INTERFACE.md, section 2.4).
	Text_Grid           = 9,
	// A straight line in first_color: from (x, y) to (x + width, y + height),
	// so width and height can be negative here; kind_detail (the thickness) is the side
	// of the square drawn at each point of the path (docs/INTERFACE.md,
	// section 2.5).
	Line                = 10,
	// A text in the interface font (docs/FONTS.md, section 12): the bytes
	// text_start ..< text_start + text_count, in first_color. The rectangle
	// of the record holds every pixel that the text draws: the box of its
	// measure, grown by its ink margin on each side. second_color is the ink
	// margin in pixels; the origin of the text is at x + margin, plus
	// text_origin_thirds thirds of a pixel; kind_detail is the weight
	// (docs/INTERFACE.md, section 2.1).
	Interface_Text      = 11,
}

// is_text_kind says if a record is a text whose bytes are in the text table.
is_text_kind :: proc "contextless" (kind: Draw_Kind) -> bool {
	return kind == .Text || kind == .Interface_Text
}

// The largest thickness of a line: past it, the squares of a long line
// cost too much to draw again in each damage rectangle.
LINE_THICKNESS_LIMIT :: 32

// The ends of a line stay inside this distance of the corner of the
// surface: the drawing walks each point of the path, so a line of a
// billion points would stop the program. A surface is far smaller.
LINE_COORDINATE_LIMIT :: 1 << 15

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

// One thing to draw: 40 bytes, little-endian (docs/INTERFACE.md, section 2.1).
//
// A `draw_` procedure appends it to the table of the frame; the difference
// compares it with the records of the frame before; the execution draws
// it. Example: `draw_rectangle(table, 0, 0, 100, 24, graphics.colors.card_top)`
// appends `{kind = .Rectangle, x = 0, y = 0, width = 100, height = 24,
// first_color = <the color>}`.
Draw_Record :: struct {
	kind:            Draw_Kind, // What the record draws.
	text_scale:      u8, // Text: 1, 2 or 3.
	text_origin_thirds: u8, // Interface_Text: the origin after x + margin, in thirds of a pixel: 0, 1 or 2. 0 for the other kinds.
	kind_detail:     u8, // Line: the thickness, 1 to LINE_THICKNESS_LIMIT pixels. Text: the weight (Font_Weight: 0 regular, 1 bold). Picture: its picture memory. 0 for the other kinds.
	x, y:            i32, // The top left corner, in pixels of the surface.
	width, height:   i32, // The size, in pixels; a Line: the vector to its end.
	first_color:     u32, // The main color: see `Draw_Kind`.
	second_color:    u32, // A gradient: its end color. Interface_Text: the ink margin. Picture: its stride, in pixels. Text_Grid: its columns.
	text_start:      u32, // A text, a grid: its first byte in the text table. A picture: its first pixel in its picture memory.
	text_count:      u32, // A text, a grid: its bytes. A picture: its generation.
	element:         u32, // The low 32 bits of the identity of the element that wrote the record.
}

#assert(size_of(Draw_Record) == 40)

// The draw records of one frame and the bytes of their texts, in the memory
// of the program. full: a record, a text or the cells of a grid did not
// fit, and is not drawn: the table is not the frame, so the next frame is
// drawn whole. refused: a record that the caller asked for could not be
// made (a picture outside each picture memory of the table, a grid whose
// cells are fewer than its size). That record is missing, and each other
// record is in the table, so the difference with the next frame stays
// exact.
Draw_Table :: struct {
	records:      []Draw_Record, // The memory of the records, from the caller.
	record_count: int, // The records of the frame so far.
	// The memory of the text table, from the caller: the bytes of the texts
	// and the cells of the grids. A table with a grid starts at an address
	// that is a multiple of 4, as the colors of a cell.
	text:         []u8,
	text_count:   int, // The bytes of the text table in use.
	full:         bool, // A record, a text or the cells of a grid did not fit.
	refused:      bool, // A record that the caller asked for was not made.
	// The picture memories of the caller: each Picture record names its
	// pixels in one of them. A call of the drawing module takes one: the
	// compositor gives each part of its screen its own list of one.
	picture_memories: [][]graphics.Color,
	// The interface font that measures and draws the Interface_Text records
	// of the table: the caches that the program validated (display). nil:
	// the program has none, and a text in the interface font is a text in
	// the font of the cells.
	interface_font: ^display.Interface_Font,
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
// table is full.
record_append :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> ^Draw_Record {
	if table.record_count >= len(table.records) {
		table.full = true
		return nil
	}
	table.records[table.record_count] = record
	table.record_count += 1
	return &table.records[table.record_count - 1]
}

// draw_rectangle appends a rectangle of one color.
draw_rectangle :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, color: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Rectangle, first_color = color, element = element}, x, y, width, height))
}

// draw_vertical_gradient appends the block of the rules: from top, on the
// first line, to bottom, on the last line.
draw_vertical_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, top, bottom: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Vertical_Gradient, first_color = top, second_color = bottom, element = element}, x, y, width, height))
}

// draw_horizontal_gradient appends a rectangle whose color goes from left,
// on its first column, to right, on its last column.
draw_horizontal_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, left, right: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Horizontal_Gradient, first_color = left, second_color = right, element = element}, x, y, width, height))
}

// draw_point_grid appends the grid of points of the background.
draw_point_grid :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	record_append(table, with_place({kind = .Point_Grid, first_color = graphics.colors.point}, x, y, width, height))
}

// draw_folded_gap appends a part with no measure on this scale.
draw_folded_gap :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Folded_Gap, first_color = graphics.colors.dim, second_color = graphics.colors.track, element = element}, x, y, width, height))
}

// draw_picture appends the pixels of a picture of the program at (x, y).
// Each pixel of the picture must be inside one picture memory of the table:
// the record names the first such memory, the index of the first pixel in
// it, and the stride. generation is a new number each time its pixels
// change: the difference sees the change. A picture with no pixel, or with
// a pixel outside each picture memory, is refused.
draw_picture :: proc "contextless" (table: ^Draw_Table, x, y: int, picture: graphics.Canvas, generation: u32, element: u32 = 0) {
	memory, first, found := picture_place(table, picture)
	if !found {
		table.refused = true
		return
	}
	record_append(table, with_place({kind = .Picture, kind_detail = u8(memory), second_color = u32(picture.stride), text_start = u32(first), text_count = generation, element = element}, x, y, picture.width, picture.height))
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
// false when the record names a memory that the table does not have, a
// picture with no pixel, a stride below its width, or a pixel past its
// memory. A record that a caller wrote by hand can have any bytes, and
// the check is in integers that cannot wrap: each factor is below 2^32.
picture_of :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> (picture: graphics.Canvas, ok: bool) {
	number := int(record.kind_detail)
	if number >= len(table.picture_memories) || record.width <= 0 || record.height <= 0 {
		return {}, false
	}
	pixels := table.picture_memories[number]
	first, stride := u64(record.text_start), u64(record.second_color)
	width, height := u64(record.width), u64(record.height)
	if stride < width || first + (height - 1) * stride + width > u64(len(pixels)) {
		return {}, false
	}
	return {pixels = raw_data(pixels[first:]), width = int(width), height = int(height), stride = int(stride)}, true
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
	record_append(table, with_place({kind = .Text_Grid, second_color = u32(grid.columns), text_start = u32(start), text_count = u32(size), element = element}, x, y, grid.columns * graphics.CELL_WIDTH, grid.rows * graphics.CELL_HEIGHT))
}

// grid_of gives the cells that a Text_Grid record names in the text table
// of its table, or false when the record names no column, bytes that are
// not a whole count of rows, a range past the text table, or a place whose
// address is not a multiple of 4. A record that a caller wrote by hand can
// have any bytes: the sums are in 64 bits from values below 2^32, so no
// range wraps. A grid of no row is valid, and draws nothing.
grid_of :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> (grid: Text_Grid, ok: bool) {
	start, count, columns := u64(record.text_start), u64(record.text_count), u64(record.second_color)
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

// draw_line appends a straight line from one point to another, with a
// thickness in pixels. The record always goes from the left end (the top
// end when the two ends have one x), so a line and its reverse are one
// record and draw the same pixels. A thickness of 0 or less draws nothing;
// a thickness past LINE_THICKNESS_LIMIT is cut to it. A line with an end
// past LINE_COORDINATE_LIMIT is refused: no record. A line of length 0 is
// one square of its thickness.
draw_line :: proc "contextless" (table: ^Draw_Table, from_x, from_y, to_x, to_y: int, thickness: int, color: graphics.Color, element: u32 = 0) {
	if thickness <= 0 {
		return
	}
	if !inside_line_limit(from_x) || !inside_line_limit(from_y) || !inside_line_limit(to_x) || !inside_line_limit(to_y) {
		return
	}
	start_x, start_y, end_x, end_y := line_ends_in_order(from_x, from_y, to_x, to_y)
	record_append(table, {kind = .Line, kind_detail = u8(min(thickness, LINE_THICKNESS_LIMIT)), x = i32(start_x), y = i32(start_y), width = i32(end_x - start_x), height = i32(end_y - start_y), first_color = color, element = element})
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
	return value >= -LINE_COORDINATE_LIMIT && value <= LINE_COORDINATE_LIMIT
}

// line_ends_in_order gives the two ends of a line with the left end first,
// or the top end first when the two ends have one x. The path of the line
// depends on its first end: one order gives one path in both directions.
line_ends_in_order :: proc "contextless" (from_x, from_y, to_x, to_y: int) -> (start_x, start_y, end_x, end_y: int) {
	if to_x < from_x || to_x == from_x && to_y < from_y {
		return to_x, to_y, from_x, from_y
	}
	return from_x, from_y, to_x, to_y
}

// line_record_valid says if the execution draws a line record: a record
// written by a caller with no draw_line can have any bytes.
line_record_valid :: proc "contextless" (record: Draw_Record) -> bool {
	thickness := int(record.kind_detail)
	if thickness < 1 || thickness > LINE_THICKNESS_LIMIT {
		return false
	}
	start_x, start_y := int(record.x), int(record.y)
	end_x, end_y := start_x + int(record.width), start_y + int(record.height)
	return inside_line_limit(start_x) && inside_line_limit(start_y) && inside_line_limit(end_x) && inside_line_limit(end_y)
}

// line_rectangle gives the rectangle that holds each pixel of a line: the
// path stays between the x and the y of its two ends, and the square of
// each point starts half a thickness before the point. The rectangle is
// the damage of the line. Pieces of the path would be tighter, but the
// damage list joins rectangles that touch, and the pieces of one line
// touch. A line that the execution refuses covers nothing.
line_rectangle :: proc "contextless" (record: Draw_Record) -> Rectangle {
	if !line_record_valid(record) {
		return {}
	}
	thickness := int(record.kind_detail)
	before := thickness / 2
	start_x, start_y := int(record.x), int(record.y)
	end_x, end_y := start_x + int(record.width), start_y + int(record.height)
	return {min(start_x, end_x) - before, min(start_y, end_y) - before, max(start_x, end_x) - before + thickness, max(start_y, end_y) - before + thickness}
}

// draw_clip appends a clip: the next records are cut to the rectangle. A
// width of 0 ends the cut.
draw_clip :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	record_append(table, with_place({kind = .Clip}, x, y, width, height))
}

// draw_text appends a run of text at (x, y), the top left corner of its
// first character, and gives the x after its last character. A text in the
// interface font is an Interface_Text record when the table has the font
// (font_in_use), else a text of the font of the cells.
draw_text :: proc "contextless" (table: ^Draw_Table, x, y: int, text: string, color: graphics.Color, font: Font = {}, element: u32 = 0) -> int {
	used := font_in_use(table, font, len(text))
	if used.kind == .Interface {
		return interface_text_append(table, i64(x) * 64, y, text, color, used, element)
	}
	width := text_width(used, text)
	if len(text) == 0 {
		return x
	}
	if table.text_count + len(text) > len(table.text) {
		table.full = true
		return x + width
	}
	start := table.text_count
	copy(table.text[start:], text)
	table.text_count += len(text)
	scale := font_scale(used)
	record_append(table, with_place({kind = .Text, text_scale = u8(scale), kind_detail = u8(used.weight), first_color = color, text_start = u32(start), text_count = u32(len(text)), element = element}, x, y, width, graphics.CELL_HEIGHT * scale))
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
// measured box, rounded up. The rectangle of the record is the box grown by
// the ink margin of the font on each side (graphics.PROPORTIONAL_INK_MARGIN
// times the scale), so the damage of the record holds each pixel of its ink.
@(private)
interface_text_append :: proc "contextless" (table: ^Draw_Table, place: i64, y: int, text: string, color: graphics.Color, font: Font, element: u32) -> int {
	width := interface_width_subpixels(table.interface_font, font, text)
	pixel, third := glyph_cache.position_of(place, 3)
	origin := pixel * 64 + i64(third) * 64 / 3
	end := int((origin + width + 63) / 64)
	if len(text) == 0 {
		return end
	}
	if table.text_count + len(text) > len(table.text) {
		table.full = true
		return end
	}
	start := table.text_count
	copy(table.text[start:], text)
	table.text_count += len(text)
	scale := font_scale(font)
	margin := graphics.PROPORTIONAL_INK_MARGIN * scale
	left := int(pixel) - margin
	record_append(table, with_place({kind = .Interface_Text, text_scale = u8(scale), text_origin_thirds = u8(third), kind_detail = u8(font.weight), first_color = color, second_color = u32(margin), text_start = u32(start), text_count = u32(len(text)), element = element}, left, y, end + margin - left, graphics.CELL_HEIGHT * scale))
	return end
}

// The places of a record stay inside this distance of the corner of the
// surface. Inside it, a size is the difference of two places and fits the
// i32 of a record. A surface is far smaller.
COORDINATE_LIMIT :: 1 << 30

// with_place gives a record with the place and the size of a rectangle,
// cut to COORDINATE_LIMIT. Each edge is cut, then the size is the
// difference of the two edges: a cut place with its own cut size would move
// the other edge, so a rectangle that covers the surface could draw
// nothing.
@(private)
with_place :: proc "contextless" (record: Draw_Record, x, y, width, height: int) -> Draw_Record {
	placed := record
	left, right := cut_edges(x, width)
	top, bottom := cut_edges(y, height)
	placed.x, placed.width = i32(left), i32(right - left)
	placed.y, placed.height = i32(top), i32(bottom - top)
	return placed
}

// cut_edges gives the two edges of a place and a size, each cut to
// COORDINATE_LIMIT. The sum of the two numbers cannot pass the int.
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
	start = clamp(place, -COORDINATE_LIMIT, COORDINATE_LIMIT - 1)
	end = clamp(end, -COORDINATE_LIMIT, COORDINATE_LIMIT - 1)
	return
}

// record_rectangle gives the rectangle that a record covers.
record_rectangle :: proc "contextless" (record: Draw_Record) -> Rectangle {
	if record.kind == .Line {
		return line_rectangle(record)
	}
	return {int(record.x), int(record.y), int(record.x) + int(record.width), int(record.y) + int(record.height)}
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
