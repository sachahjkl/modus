package interface

import "modus:contract/draw_record"
import "modus:contract/text_encoding"
import "modus:support/graphics"
import "modus:support/text_rendering"

// execute draws each record of a table into a canvas, in order. The records
// are in the coordinates of the surface; (origin_x, origin_y) is where the
// point (0, 0) of the surface is in the canvas. The canvas cuts each record.
execute :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, origin_x: int = 0, origin_y: int = 0) {
	execute_in_rectangle(table, canvas, {-origin_x, -origin_y, canvas.width - origin_x, canvas.height - origin_y}, origin_x, origin_y)
}

// draw_damage_on_surface draws the damage of a frame on the surface of a
// process: each damage rectangle is painted with the background first, so a
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
// surface, cut to it. A color with alpha blends with the table of the text
// state of the graphics package, which the process fills once at its start
// (graphics.text_state_start; display.text_settings_load calls it).
//
// The clips are a stack of cuts: the cut at a depth is the rectangle cut by
// the box of each push open, so it depends on the records only, and each
// rectangle of a damage gives the pixels of one draw. The order is the
// order of the kind words, walked again here whatever a check before found,
// since the table can change during the call: a push that the border
// refuses is an empty clip, a push past CLIP_DEPTH_LIMIT hides each record
// until its pop, and a pop with no push changes nothing. So a table draws
// less than it asks, never outside a clip that it pushed.
execute_in_rectangle :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, rectangle: Rectangle, origin_x: int = 0, origin_y: int = 0) {
	limit := intersection(rectangle, {-origin_x, -origin_y, canvas.width - origin_x, canvas.height - origin_y})
	if empty(limit) {
		return
	}
	// One cut for each depth of the clips, on the stack: 544 bytes.
	cuts: [draw_record.CLIP_DEPTH_LIMIT + 1]Rectangle
	cuts[0] = limit
	order: draw_record.Clip_Order
	for index in 0 ..< table.record_count {
		// One copy of each record, read through the border: a table can be
		// in memory that another process writes during the call, and each
		// check and each draw reads this copy.
		record := draw_record.copy_once(&table.records[index])
		primitive, problem := draw_record.read(record)
		if kind, known := draw_record.draw_kind_of_word(record.kind); known && (kind == .Clip_Push || kind == .Clip_Pop) {
			clip_step(&cuts, &order, kind == .Clip_Push, problem == .None ? record_rectangle(record) : Rectangle{})
			continue
		}
		if problem != .None || order.excess > 0 {
			continue
		}
		place := record_rectangle(record)
		area := intersection(cuts[order.depth], place)
		if empty(area) {
			continue
		}
		// The part of the canvas where this record can draw: the record draws
		// in its own coordinates, and the view cuts it.
		view := graphics.view(canvas, area.left + origin_x, area.top + origin_y, area.right - area.left, area.bottom - area.top)
		x, y := place.left - area.left, place.top - area.top
		width, height := place.right - place.left, place.bottom - place.top
		switch fields in primitive {
		case draw_record.Draw_Nothing, draw_record.Draw_Clip_Push, draw_record.Draw_Clip_Pop:
		case draw_record.Draw_Rectangle:
			switch {
			case fields.repetition != (draw_record.Repetition{}):
				pattern_draw(view, area, fields.repetition, fields.color)
			case record_on_whole_pixels(record):
				graphics.blend_fill(view, x, y, width, height, u32(fields.color), &graphics.text_state.square_root)
			case:
				rectangle_inside_pixels_draw(view, area, record, fields.color)
			}
		case draw_record.Draw_Gradient:
			gradient_draw(view, area, record, fields)
		case draw_record.Draw_Text:
			// A color of alpha 0 is the color 0, which draws nothing.
			color, alpha := draw_record.channels_of(fields.color), u32(draw_record.alpha_of(fields.color))
			if alpha == 0 {
				continue
			}
			switch fields.font {
			case .Cells_8x16:
				// The origin of a text in the font of the cells is a whole
				// pixel: the writer makes it the left edge of the box.
				start, count := u64(fields.first), u64(fields.count)
				if start + count <= u64(table.text_count) {
					text_draw(view, draw_record.pixels_floor(fields.origin_x) - area.left, y, string(table.text[start:][:count]), color, int(fields.scale), fields.weight, alpha)
				}
			case .Interface:
				interface_text_draw(table, fields, view, area.left, y)
			}
		case draw_record.Draw_Picture:
			if picture, ok := picture_pixels(table, place, fields); ok {
				switch fields.format {
				case .Opaque:
					graphics.copy(view, x, y, picture)
				case .Straight_Alpha:
					graphics.blend_copy(view, x, y, picture, &graphics.text_state.square_root)
				}
			}
		case draw_record.Draw_Text_Grid:
			if grid, ok := grid_cells(table, fields); ok {
				text_grid_draw(view, x, y, grid)
			}
		case draw_record.Draw_Path:
			path_draw(table, view, area, fields)
		}
	}
}

// clip_step takes one push or one pop of a clip into the cuts of the stack.
// A push holds the cut before it, cut by box; at the bound it is counted
// and not held (draw_record.clip_order_push). box is the box of the push in
// pixels, or an empty rectangle for a push that the border refuses: each of
// its edges is 0, so its intersection with any cut holds no pixel.
@(private)
clip_step :: proc "contextless" (cuts: ^[draw_record.CLIP_DEPTH_LIMIT + 1]Rectangle, order: ^draw_record.Clip_Order, push: bool, box: Rectangle) {
	if !push {
		draw_record.clip_order_pop(order)
		return
	}
	outer := cuts[order.depth]
	if draw_record.clip_order_push(order) == .None {
		cuts[order.depth] = intersection(outer, box)
	}
}

// record_on_whole_pixels says if each edge of the box of a record is a
// whole pixel.
@(private)
record_on_whole_pixels :: proc "contextless" (record: Draw_Record) -> bool {
	return draw_record.on_whole_pixel(record.left) && draw_record.on_whole_pixel(record.top) && draw_record.on_whole_pixel(record.right) && draw_record.on_whole_pixel(record.bottom)
}

// Edge_Span is a run of whole pixels on one axis of a box, each covered by
// the same part of the box: covered units of UNITS_PER_PIXEL.
@(private)
Edge_Span :: struct {
	first, count: int, // The first pixel of the surface and the count of pixels.
	covered:      int, // The units of each pixel inside the box: 1 to UNITS_PER_PIXEL.
}

// edge_spans cuts the two edges of a box on one axis, in units, into the
// runs of pixels of one coverage: the first pixel when the box covers a
// part of it, the whole pixels, and the last pixel when the box covers a
// part of it. A box inside one pixel is one span. An edge on a whole pixel
// makes no span of its own, so a box on whole pixels is one span.
@(private)
edge_spans :: proc "contextless" (start, end: i32) -> (spans: [3]Edge_Span, count: int) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	if end <= start {
		return
	}
	first := draw_record.pixels_floor(start)
	last := draw_record.pixels_ceiling(end) // One past the last pixel.
	if last - first == 1 {
		spans[0] = {first = first, count = 1, covered = int(end) - int(start)}
		return spans, 1
	}
	head := (first + 1) * UNITS - int(start)
	tail := int(end) - (last - 1) * UNITS
	whole_first, whole_last := first + 1, last - 1
	if head == UNITS {
		whole_first = first
	} else {
		spans[count] = {first = first, count = 1, covered = head}
		count += 1
	}
	if tail == UNITS {
		whole_last = last
	}
	if whole_last > whole_first {
		spans[count] = {first = whole_first, count = whole_last - whole_first, covered = UNITS}
		count += 1
	}
	if tail != UNITS {
		spans[count] = {first = last - 1, count = 1, covered = tail}
		count += 1
	}
	return spans, count
}

// covered_alpha gives the alpha of a pixel that a box covers in part: the
// alpha of the color times the part of the pixel inside the box, the
// product of the parts on each axis, rounded to the nearest. A pixel
// covered whole keeps the alpha: 255 * 64 * 64 + 2048 >> 12 is 255.
@(private)
covered_alpha :: proc "contextless" (alpha: u32, covered_x, covered_y: int) -> u32 {
	return (alpha * u32(covered_x) * u32(covered_y) + 2048) >> 12
}

#assert(draw_record.UNITS_PER_PIXEL * draw_record.UNITS_PER_PIXEL == 1 << 12)

// rectangle_inside_pixels_draw draws a Rectangle with no pattern whose box
// is not on whole pixels: its coverage is the same on each of its parts,
// at most nine (the corners, the four sides and the inside), so each part
// is one blend_fill of the color with the covered alpha, through the SSE2
// form of the blend, with no coverage computed for each pixel. view shows
// area of the surface from its top left corner.
@(private)
rectangle_inside_pixels_draw :: proc "contextless" (view: graphics.Canvas, area: Rectangle, record: Draw_Record, color: draw_record.Draw_Color) {
	columns, column_count := edge_spans(record.left, record.right)
	rows, row_count := edge_spans(record.top, record.bottom)
	alpha, channels := u32(draw_record.alpha_of(color)), draw_record.channels_of(color)
	for row in rows[:row_count] {
		for column in columns[:column_count] {
			part_alpha := covered_alpha(alpha, column.covered, row.covered)
			if part_alpha == 0 {
				continue
			}
			graphics.blend_fill(view, column.first - area.left, row.first - area.top, column.count, row.count, part_alpha << 24 | channels, &graphics.text_state.square_root)
		}
	}
}

// gradient_draw draws a Gradient in the part of the surface that the view
// shows (area). The level of a pixel is draw_record.gradient_level at its
// center; its color is the mix of the two colors at that level, alpha too;
// a pixel that the box covers in part takes the covered alpha. The pixels
// of a row blend through the SSE2 form of the blend.
//
// Three forms, by the line of the gradient: a line down (the two points on
// one x) gives one color to each row, which is one blend_fill for each
// span of columns, a fill when it is opaque; a line across (on one y) gives
// one row of colors for the columns of the view and each span of rows, the
// level and the mix of each column one time, then copied into each line of
// the span when it is opaque and covered whole, else blended; another line
// computes the level of each pixel, one division each.
@(private)
gradient_draw :: proc "contextless" (view: graphics.Canvas, area: Rectangle, record: Draw_Record, gradient: draw_record.Draw_Gradient) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	HALF :: UNITS / 2
	columns, column_count := edge_spans(record.left, record.right)
	rows, row_count := edge_spans(record.top, record.bottom)
	// A box of no width or no height covers no pixel, also when its edges
	// lie inside one.
	if column_count == 0 || row_count == 0 {
		return
	}
	start, end := u32(gradient.start_color), u32(gradient.end_color)
	square_root := &graphics.text_state.square_root
	if gradient.start_x == gradient.end_x {
		for span in rows[:row_count] {
			for y in max(span.first, area.top) ..< min(span.first + span.count, area.bottom) {
				color := graphics.mix_with_alpha(start, end, draw_record.gradient_level(gradient, i64(gradient.start_x), i64(y) * UNITS + HALF))
				for column in columns[:column_count] {
					part_alpha := covered_alpha(color >> 24, column.covered, span.covered)
					if part_alpha != 0 {
						graphics.blend_fill(view, column.first - area.left, y - area.top, column.count, 1, part_alpha << 24 | color & 0x00FFFFFF, square_root)
					}
				}
			}
		}
		return
	}
	// The colors of the pixels of one row, a part of the view at a time.
	row: [512]u32
	across := gradient.start_y == gradient.end_y
	first_x, last_x := max(area.left, columns[0].first), min(area.right, columns[column_count - 1].first + columns[column_count - 1].count)
	// Two opaque ends: each mixed color is opaque. With columns covered
	// whole too, a row covered whole needs no blend: it is copied into
	// each line, with the high byte 0, as the horizontal gradient of
	// before was (the title bars, the scroll bar).
	opaque_ends := draw_record.alpha_of(gradient.start_color) == draw_record.OPAQUE_ALPHA && draw_record.alpha_of(gradient.end_color) == draw_record.OPAQUE_ALPHA
	columns_whole := column_count == 1 && columns[0].covered == UNITS
	for span in rows[:row_count] {
		first_y, last_y := max(span.first, area.top), min(span.first + span.count, area.bottom)
		if first_y >= last_y {
			continue
		}
		for part := first_x; part < last_x; part += len(row) {
			count := min(len(row), last_x - part)
			if across {
				// One row of colors for each span of rows: the level does
				// not change down the box.
				gradient_row(row[:count], gradient, part, i64(gradient.start_y), columns[:column_count], span.covered)
				source := graphics.Canvas{pixels = raw_data(row[:]), width = count, height = last_y - first_y}
				if opaque_ends && columns_whole && span.covered == UNITS {
					for &color in row[:count] {
						color &= 0x00FFFFFF
					}
					graphics.copy(view, part - area.left, first_y - area.top, source)
				} else {
					graphics.blend_copy(view, part - area.left, first_y - area.top, source, square_root)
				}
				continue
			}
			for y in first_y ..< last_y {
				gradient_row(row[:count], gradient, part, i64(y) * UNITS + HALF, columns[:column_count], span.covered)
				graphics.blend_copy(view, part - area.left, y - area.top, {pixels = raw_data(row[:]), width = count, height = 1}, square_root)
			}
		}
	}
}

// gradient_row puts in row the colors with alpha of the pixels from the
// column first of the surface, on the place y of the line of their centers,
// each with the covered alpha of its span of columns and of the span of
// rows (covered_y).
@(private)
gradient_row :: proc "contextless" (row: []u32, gradient: draw_record.Draw_Gradient, first: int, y: i64, columns: []Edge_Span, covered_y: int) {
	UNITS :: draw_record.UNITS_PER_PIXEL
	HALF :: UNITS / 2
	start, end := u32(gradient.start_color), u32(gradient.end_color)
	span := 0
	for &color, index in row {
		x := first + index
		for span < len(columns) - 1 && x >= columns[span].first + columns[span].count {
			span += 1
		}
		mixed := graphics.mix_with_alpha(start, end, draw_record.gradient_level(gradient, i64(x) * UNITS + HALF, y))
		color = covered_alpha(mixed >> 24, columns[span].covered, covered_y) << 24 | mixed & 0x00FFFFFF
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
pattern_draw :: proc "contextless" (view: graphics.Canvas, area: Rectangle, pattern: draw_record.Repetition, draw_color: draw_record.Draw_Color) {
	// Each cell blends by the rule of the colors: the cells never overlap,
	// so each pixel blends at most once.
	color := u32(draw_color)
	cell_x, cell_y := draw_record.pixels_floor(pattern.cell_x), draw_record.pixels_floor(pattern.cell_y)
	cell_width, cell_height := int(pattern.cell_width) >> draw_record.UNIT_SHIFT, int(pattern.cell_height) >> draw_record.UNIT_SHIFT
	step_x, step_y := int(pattern.step_x) >> draw_record.UNIT_SHIFT, int(pattern.step_y) >> draw_record.UNIT_SHIFT
	width, height := area.right - area.left, area.bottom - area.top
	rows_touch := cell_width == step_x
	columns_touch := cell_height == step_y
	if rows_touch && columns_touch {
		graphics.blend_fill(view, 0, 0, width, height, color, &graphics.text_state.square_root)
		return
	}
	first_x := cell_x + (divide_down(area.left - cell_x - cell_width, step_x) + 1) * step_x
	first_y := cell_y + (divide_down(area.top - cell_y - cell_height, step_y) + 1) * step_y
	if rows_touch {
		// Each row of cells is one span across the area.
		for top := first_y; top < area.bottom; top += step_y {
			graphics.blend_fill(view, 0, top - area.top, width, cell_height, color, &graphics.text_state.square_root)
		}
		return
	}
	if columns_touch {
		// Each column of cells is one span down the area.
		for left := first_x; left < area.right; left += step_x {
			graphics.blend_fill(view, left - area.left, 0, cell_width, height, color, &graphics.text_state.square_root)
		}
		return
	}
	for top := first_y; top < area.bottom; top += step_y {
		for left := first_x; left < area.right; left += step_x {
			graphics.blend_fill(view, left - area.left, top - area.top, cell_width, cell_height, color, &graphics.text_state.square_root)
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
	color, alpha := draw_record.channels_of(fields.color), u32(draw_record.alpha_of(fields.color))
	if table.interface_font == nil {
		text_draw(view, int(origin >> draw_record.UNIT_SHIFT), y, string(text), color, scale, font.weight, alpha)
		return
	}
	cache := interface_cache_of(table.interface_font, font)
	spacing, ok := text_rendering.spacing_of(cache, scale)
	if !ok {
		return
	}
	placed: [INTERFACE_TEXT_LIMIT]text_rendering.Placed_Glyph
	placed_count, _, _ := text_rendering.shape(&spacing, text, placed[:])
	graphics.text_proportional(view, origin, y, placed[:min(placed_count, len(placed))], cache, scale, color, alpha)
}

// text_draw draws characters of the font of the system, each pixel of the
// font as a square of scale pixels. alpha is the alpha of the color: below
// 255 each pixel of ink blends (graphics.text_scaled).
text_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color, scale: int, weight: Font_Weight = .Regular, alpha: u32 = graphics.OPAQUE) {
	if weight == .Bold && scale <= 1 {
		graphics.text_bold(canvas, x, y, text, color, alpha)
		return
	}
	graphics.text_scaled(canvas, x, y, text, color, scale, alpha)
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
