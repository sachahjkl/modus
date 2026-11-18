package interface

import "modus:contract/draw_record"
import "modus:contract/text_encoding"
import "modus:support/graphics"
import "modus:support/text_shaping"

// execute draws each record of a table into a canvas, in order. The records
// are in the coordinates of the surface; (origin_x, origin_y) is where the
// point (0, 0) of the surface is in the canvas. The canvas cuts each record.
execute :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, origin_x: int = 0, origin_y: int = 0) {
	execute_in_rectangle(table, canvas, {-origin_x, -origin_y, canvas.width - origin_x, canvas.height - origin_y}, origin_x, origin_y)
}

// draw_damage_on_surface draws the damage of a frame on the surface of a
// program: each damage rectangle is painted with the background first, so a
// record that the frame no longer has leaves no pixel, then the records
// that touch it are drawn again. The compositor draws a panel over other
// windows: it calls execute_in_rectangle, which paints only the records.
draw_damage_on_surface :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle) {
	for rectangle in rectangles {
		area := intersection(rectangle, {0, 0, canvas.width, canvas.height})
		if !empty(area) {
			graphics.fill(canvas, area.left, area.top, area.right - area.left, area.bottom - area.top, graphics.colors.background)
		}
		execute_in_rectangle(table, canvas, rectangle)
	}
}

// execute_in_rectangles draws again, in each rectangle, the records that
// touch it, cut to it. The rectangles are in the coordinates of the surface.
execute_in_rectangles :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle, origin_x: int = 0, origin_y: int = 0) {
	for rectangle in rectangles {
		execute_in_rectangle(table, canvas, rectangle, origin_x, origin_y)
	}
}

// execute_in_rectangle draws the records that touch one rectangle of the
// surface, cut to it.
execute_in_rectangle :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, rectangle: Rectangle, origin_x: int = 0, origin_y: int = 0) {
	limit := intersection(rectangle, {-origin_x, -origin_y, canvas.width - origin_x, canvas.height - origin_y})
	if empty(limit) {
		return
	}
	cut := limit
	for index in 0 ..< table.record_count {
		// One copy of each record, read through the border: a table can be
		// in memory that another program writes during the call, and each
		// check and each draw reads this copy.
		record := draw_record.copy_once(&table.records[index])
		primitive, problem := draw_record.read(record)
		if problem != .None {
			continue
		}
		place := record_rectangle(record)
		if _, is_clip := primitive.(draw_record.Draw_Clip); is_clip {
			cut = place.right == place.left ? limit : intersection(limit, place)
			continue
		}
		area := intersection(cut, place)
		if empty(area) {
			continue
		}
		// The part of the canvas where this record can draw: the record draws
		// in its own coordinates, and the view cuts it.
		view := graphics.view(canvas, area.left + origin_x, area.top + origin_y, area.right - area.left, area.bottom - area.top)
		x, y := place.left - area.left, place.top - area.top
		width, height := place.right - place.left, place.bottom - place.top
		switch fields in primitive {
		case draw_record.Draw_Nothing, draw_record.Draw_Clip:
		case draw_record.Draw_Rectangle:
			if fields.repetition == (draw_record.Repetition{}) {
				graphics.fill(view, x, y, width, height, fields.color)
			} else {
				pattern_draw(view, area, fields.repetition, fields.color)
			}
		case draw_record.Draw_Vertical_Gradient:
			// One mix for each line: only the lines in the view.
			first := max(0, -y)
			last := min(height, view.height - y)
			for row in first ..< last {
				graphics.fill(view, x, y + row, width, 1, graphics.mix(fields.top_color, fields.bottom_color, u32(row * 255 / max(height - 1, 1))))
			}
		case draw_record.Draw_Horizontal_Gradient:
			// One row of colors for the columns in the view, in parts of
			// 512 pixels, then a copy of the row to each line.
			row: [512]graphics.Color
			last := min(width, view.width - x)
			for part := max(0, -x); part < last; part += len(row) {
				count := min(len(row), last - part)
				graphics.gradient(row[:count], fields.left_color, fields.right_color, width, part)
				graphics.copy(view, x + part, y, {pixels = raw_data(row[:]), width = count, height = height})
			}
		case draw_record.Draw_Text:
			switch fields.font {
			case .Cells_8x16:
				// The origin of a text in the font of the cells is a whole
				// pixel: the writer makes it the left edge of the box.
				start, count := u64(fields.first), u64(fields.count)
				if start + count <= u64(table.text_count) {
					text_draw(view, draw_record.pixels_floor(fields.origin_x) - area.left, y, string(table.text[start:][:count]), fields.color, int(fields.scale), fields.weight)
				}
			case .Interface:
				interface_text_draw(table, fields, view, area.left, y)
			}
		case draw_record.Draw_Picture:
			if picture, ok := picture_pixels(table, place, fields); ok {
				graphics.copy(view, x, y, picture)
			}
		case draw_record.Draw_Text_Grid:
			if grid, ok := grid_cells(table, fields); ok {
				text_grid_draw(view, x, y, grid)
			}
		case draw_record.Draw_Line:
			// The ends in the view; the path is the one of graphics.line from
			// the end that line_ends_in_order puts first.
			start_x, start_y, end_x, end_y := line_ends_in_order(draw_record.pixels_floor(fields.start_x) - area.left, draw_record.pixels_floor(fields.start_y) - area.top, draw_record.pixels_floor(fields.end_x) - area.left, draw_record.pixels_floor(fields.end_y) - area.top)
			graphics.line(view, start_x, start_y, end_x, end_y, int(fields.thickness), fields.color)
		}
	}
}

// pattern_draw draws the cells of the pattern of a Rectangle that meet the
// area, a rectangle of the surface that the view shows from its top left
// corner. The cells are placed on the surface, so that two areas of one
// surface show one pattern: the first cell is the first whose right edge
// passes the left edge of the area, and a cell that starts before the area
// reaches into it, cut by the view. The border keeps each size a whole
// pixel of at least 1 and each cell inside its step, so the loop draws each
// pixel of the area at most once.
//
// Cells that touch are one fill: a cell as wide as its step makes each row
// of cells one span across the area, a cell as high as its step makes each
// column of cells one span down it, and both make the area one fill. So a
// dense pattern costs what a solid rectangle costs, and the most calls come
// from a cell of 1 pixel and a step of 2 on each axis: one call for each
// cell, a quarter of the pixels of the area. The pixel writes are never
// more than the pixels of the area.
@(private)
pattern_draw :: proc "contextless" (view: graphics.Canvas, area: Rectangle, pattern: draw_record.Repetition, color: graphics.Color) {
	cell_x, cell_y := draw_record.pixels_floor(pattern.cell_x), draw_record.pixels_floor(pattern.cell_y)
	cell_width, cell_height := int(pattern.cell_width) >> draw_record.UNIT_SHIFT, int(pattern.cell_height) >> draw_record.UNIT_SHIFT
	step_x, step_y := int(pattern.step_x) >> draw_record.UNIT_SHIFT, int(pattern.step_y) >> draw_record.UNIT_SHIFT
	width, height := area.right - area.left, area.bottom - area.top
	rows_touch := cell_width == step_x
	columns_touch := cell_height == step_y
	if rows_touch && columns_touch {
		graphics.fill(view, 0, 0, width, height, color)
		return
	}
	first_x := cell_x + (divide_down(area.left - cell_x - cell_width, step_x) + 1) * step_x
	first_y := cell_y + (divide_down(area.top - cell_y - cell_height, step_y) + 1) * step_y
	if rows_touch {
		// Each row of cells is one span across the area.
		for top := first_y; top < area.bottom; top += step_y {
			graphics.fill(view, 0, top - area.top, width, cell_height, color)
		}
		return
	}
	if columns_touch {
		// Each column of cells is one span down the area.
		for left := first_x; left < area.right; left += step_x {
			graphics.fill(view, left - area.left, 0, cell_width, height, color)
		}
		return
	}
	for top := first_y; top < area.bottom; top += step_y {
		for left := first_x; left < area.right; left += step_x {
			graphics.fill(view, left - area.left, top - area.top, cell_width, cell_height, color)
		}
	}
}

// divide_down gives the quotient of a division rounded toward minus
// infinity, for a divisor above 0: the index of a cell of a pattern on the
// left of the origin of its steps is negative.
@(private)
divide_down :: proc "contextless" (dividend, divisor: int) -> int {
	quotient := dividend / divisor
	if dividend % divisor != 0 && dividend < 0 {
		quotient -= 1
	}
	return quotient
}

// text_grid_draw draws the cells of a grid that the view shows, with its
// first cell at (x, y). The cells of one color that follow each other are
// one text: the font draws each text once.
text_grid_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, grid: Text_Grid) {
	if !grid_valid(grid) {
		return
	}
	first_row := max(0, -y / graphics.CELL_HEIGHT)
	last_row := min(grid.rows, (canvas.height - y + graphics.CELL_HEIGHT - 1) / graphics.CELL_HEIGHT)
	first_column := max(0, -x / graphics.CELL_WIDTH)
	last_column := min(grid.columns, (canvas.width - x + graphics.CELL_WIDTH - 1) / graphics.CELL_WIDTH)
	// The text of a run of cells, as UTF-8: the font draws one cell for
	// each character.
	RUN_CHARACTERS :: 256
	run: [RUN_CHARACTERS * text_encoding.CHARACTER_BYTES_LIMIT]u8
	for row in first_row ..< last_row {
		cells := grid.cells[row * grid.stride:][:grid.columns]
		top := y + row * graphics.CELL_HEIGHT
		column := first_column
		for column < last_column {
			cell := cells[column]
			left := x + column * graphics.CELL_WIDTH
			if cell.reverse {
				graphics.fill(canvas, left, top, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, cell.color)
				bytes := cell_character_put(run[:], 0, max(cell.character, ' '))
				text_draw(canvas, left, top, string(run[:bytes]), graphics.colors.background, 1)
				column += 1
				continue
			}
			if cell.filled {
				// A run of filled cells of one color and one background:
				// one fill, then one text. An empty cell is a space.
				count, bytes := 0, 0
				for column + count < last_column && count < RUN_CHARACTERS {
					next := cells[column + count]
					if next.reverse || !next.filled || next.color != cell.color || next.background != cell.background {
						break
					}
					bytes = cell_character_put(run[:], bytes, max(next.character, ' '))
					count += 1
				}
				graphics.fill(canvas, left, top, count * graphics.CELL_WIDTH, graphics.CELL_HEIGHT, cell.background)
				text_draw(canvas, left, top, string(run[:bytes]), cell.color, 1)
				column += count
				continue
			}
			if cell.character <= ' ' {
				column += 1
				continue
			}
			// A run: the cells of this color, spaces too, up to a reverse
			// cell, a filled cell, an empty cell or the end of the room.
			count, bytes := 0, 0
			for column + count < last_column && count < RUN_CHARACTERS {
				next := cells[column + count]
				if next.reverse || next.filled || next.character < ' ' || next.color != cell.color {
					break
				}
				bytes = cell_character_put(run[:], bytes, next.character)
				count += 1
			}
			text_draw(canvas, left, top, string(run[:bytes]), cell.color, 1)
			column += count
		}
	}
}

// cell_character_put writes the UTF-8 of the character of a cell at place,
// and gives the place after it. A code point that is no character of a text
// (a control, a surrogate, a number past U+10FFFF) is the replacement
// character: each cell still takes one cell of the run.
@(private)
cell_character_put :: proc "contextless" (run: []u8, place: int, character: rune) -> int {
	length := text_encoding.character_encode(character, run[place:])
	if length == 0 {
		length = text_encoding.character_encode(text_encoding.REPLACEMENT_CHARACTER, run[place:])
	}
	return place + length
}

// interface_text_draw draws a Text record in the interface font that the
// border read: its origin, its count, its scale and its weight are in their
// bounds. view starts at the column view_left of the surface, and y is the
// top of the record in the view. A record with a range outside the text
// table draws nothing. With no interface font, the text is drawn in the
// font of the cells at the pixel of its origin, cut to its box as each
// record.
@(private)
interface_text_draw :: proc "contextless" (table: ^Draw_Table, fields: draw_record.Draw_Text, view: graphics.Canvas, view_left, y: int) {
	start := u64(fields.first)
	count := u64(fields.count)
	scale := int(fields.scale)
	if start + count > u64(table.text_count) {
		return
	}
	text := table.text[start:][:count]
	font := Font{kind = .Interface, scale = u8(scale), weight = fields.weight}
	// The origin in 1/64 pixel from the left of the view; the border keeps
	// it on a third of a pixel and inside the box.
	origin := i64(fields.origin_x) - i64(view_left) * draw_record.UNITS_PER_PIXEL
	if table.interface_font == nil {
		text_draw(view, int(origin >> draw_record.UNIT_SHIFT), y, string(text), fields.color, scale, font.weight)
		return
	}
	cache := interface_cache_of(table.interface_font, font)
	spacing, ok := text_shaping.spacing_of(cache, scale)
	if !ok {
		return
	}
	placed: [INTERFACE_TEXT_LIMIT]text_shaping.Placed_Glyph
	placed_count, _, _ := text_shaping.shape(&spacing, text, placed[:])
	graphics.text_proportional(view, origin, y, placed[:min(placed_count, len(placed))], cache, scale, fields.color)
}

// text_draw draws characters of the font of the system, each pixel of the
// font as a square of scale pixels.
text_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color, scale: int, weight: Font_Weight = .Regular) {
	if weight == .Bold && scale <= 1 {
		graphics.text_bold(canvas, x, y, text, color)
		return
	}
	graphics.text_scaled(canvas, x, y, text, color, scale)
}

// intersection gives the part that two rectangles share. It is empty
// (`empty`) when they do not meet.
intersection :: proc "contextless" (first, second: Rectangle) -> Rectangle {
	return {max(first.left, second.left), max(first.top, second.top), min(first.right, second.right), min(first.bottom, second.bottom)}
}

// empty says if a rectangle holds no pixel.
empty :: proc "contextless" (rectangle: Rectangle) -> bool {
	return rectangle.left >= rectangle.right || rectangle.top >= rectangle.bottom
}
