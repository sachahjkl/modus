package interface

// The execution of a draw table at a scale factor
// (src/md/features/desktop_to_browser.md, "The reference screen"). The
// border reads each record in logical pixels, as at no scale; then the
// record goes to the screen here, and is drawn by the code of each kind in
// pixels of the screen. So no process computes a screen pixel, and each
// place rounds by the one rule of scale_factor:
//
// - each edge of a box goes to the nearest pixel of the screen, a half up,
//   so two boxes that share an edge share it on the screen;
// - a point of a path, a point of a gradient and the origin of a text go to
//   the nearest unit, so they keep their part of a pixel;
// - a text keeps the places of its measure: the glyphs are shaped at the
//   size of the record, each x goes to the screen, and each glyph is drawn
//   at the size of the record times the scale;
// - a picture keeps its own pixels: each pixel of the screen takes the
//   pixel of the logical pixel that holds it.

import "modus:contract/draw_record"
import "modus:contract/scale_factor"
import "modus:graphics"
import "modus:text_rendering"

// rectangle_at_scale gives the box of a record on the screen: each edge by
// scale_factor.screen_edge.
rectangle_at_scale :: proc "contextless" (record: Draw_Record, scale: scale_factor.Scale) -> Rectangle {
	box := scale_factor.screen_box(record.left, record.top, record.right, record.bottom, scale)
	return {int(box.left), int(box.top), int(box.right), int(box.bottom)}
}

// damage_at_scale turns the rectangles of a damage, found by difference in
// logical pixels, into rectangles of the screen: each edge by
// scale_factor.screen_pixel_of_logical_pixel, so each holds the box on the
// screen of each record that it held. Two rectangles that do not touch in
// logical pixels do not overlap on the screen: the rule grows with the
// place.
damage_at_scale :: proc "contextless" (damage: ^Damage, scale: scale_factor.Scale) {
	for &rectangle in damage.rectangles[:clamp(damage.count, 0, DAMAGE_CAPACITY)] {
		screen := scale_factor.screen_rectangle_of_logical_rectangle(logical_edge_of(rectangle.left), logical_edge_of(rectangle.top), logical_edge_of(rectangle.right), logical_edge_of(rectangle.bottom), scale)
		rectangle = {int(screen.left), int(screen.top), int(screen.right), int(screen.bottom)}
	}
}

// logical_edge_of keeps an edge of a damage inside COORDINATE_LIMIT, the
// bound of each box that the difference reads, so it fits an i32.
@(private)
logical_edge_of :: proc "contextless" (pixel: int) -> i32 {
	return i32(clamp(pixel, -COORDINATE_LIMIT, COORDINATE_LIMIT))
}

// record_with_box gives a record with the box of the screen in its edges,
// in units: whole pixels. The code of a kind that reads the box of its
// record (the spans of a gradient) then reads the box of the screen.
@(private)
record_with_box :: proc "contextless" (record: Draw_Record, box: Rectangle) -> Draw_Record {
	moved := record
	moved.left, moved.top = draw_record.units_of_pixels(box.left), draw_record.units_of_pixels(box.top)
	moved.right, moved.bottom = draw_record.units_of_pixels(box.right), draw_record.units_of_pixels(box.bottom)
	return moved
}

// record_at_scale_draw draws one record that the border read, at a scale,
// cut to cut, a rectangle of the screen. The canvas, the cut and the
// origin are in pixels of the screen, as at no scale.
@(private)
record_at_scale_draw :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, cut: Rectangle, origin_x, origin_y: int, record: Draw_Record, primitive: draw_record.Draw_Primitive, scale: scale_factor.Scale) {
	place := rectangle_at_scale(record, scale)
	area := intersection(cut, place)
	if empty(area) {
		return
	}
	view := graphics.view(canvas, area.left + origin_x, area.top + origin_y, area.right - area.left, area.bottom - area.top)
	x, y := place.left - area.left, place.top - area.top
	width, height := place.right - place.left, place.bottom - place.top
	switch fields in primitive {
	case draw_record.Draw_Nothing, draw_record.Draw_Clip_Push, draw_record.Draw_Clip_Pop, draw_record.Draw_Element_Push, draw_record.Draw_Element_Pop:
	case draw_record.Draw_Rectangle:
		// The box on the screen is on whole pixels: no pixel is covered
		// in part.
		if fields.repetition != (draw_record.Repetition{}) {
			pattern_at_scale_draw(view, area, fields.repetition, fields.color, scale)
		} else {
			graphics.blend_fill(view, x, y, width, height, u32(fields.color), &graphics.text_state.square_root)
		}
	case draw_record.Draw_Gradient:
		gradient := fields
		gradient.start_x = i32(scale_factor.screen_place(fields.start_x, scale))
		gradient.start_y = i32(scale_factor.screen_place(fields.start_y, scale))
		gradient.end_x = i32(scale_factor.screen_place(fields.end_x, scale))
		gradient.end_y = i32(scale_factor.screen_place(fields.end_y, scale))
		gradient_draw(view, area, record_with_box(record, place), gradient)
	case draw_record.Draw_Text:
		color, alpha := draw_record.channels_of(fields.color), u32(draw_record.alpha_of(fields.color))
		if alpha == 0 {
			return
		}
		switch fields.font {
		case .Cells_8x16:
			// The origin is a whole logical pixel, the left edge of the
			// box: it goes to the edge of the box on the screen.
			start, count := u64(fields.first), u64(fields.count)
			if start + count <= u64(table.text_count) {
				text_draw(view, int(scale_factor.screen_edge(fields.origin_x, scale)) - area.left, y, string(table.text[start:][:count]), color, scale_factor.screen_text_size(fields.size, scale), fields.weight, alpha)
			}
		case .Interface:
			interface_text_at_scale_draw(table, fields, view, area.left, y, scale)
		}
	case draw_record.Draw_Picture:
		// The pixels of a picture are its own: its size is its box in
		// logical pixels.
		logical := record_rectangle(record)
		if picture, ok := picture_pixels(table, logical, fields); ok {
			picture_at_scale_draw(view, area, logical, picture, fields.format, scale)
		}
	case draw_record.Draw_Text_Grid:
		if grid, ok := grid_cells(table, fields); ok {
			// Each cell is the cell of the size on the screen: whole
			// pixels, so a grid can be up to half a pixel for each column
			// off its box on the screen, which cuts it.
			grid.size = u16(min(scale_factor.screen_text_size(fields.size, scale), int(max(u16))))
			text_grid_draw(view, x, y, grid)
		}
	case draw_record.Draw_Path:
		// path_draw takes the scale of the table: its points go to the
		// screen after the border of the points.
		path_draw(table, view, area, fields)
	}
}

// pattern_at_scale_draw draws the cells of the pattern of a Rectangle that
// meet the area, a rectangle of the screen that the view shows from its top
// left corner. A step of the pattern is not a whole count of pixels of the
// screen at each scale, so each cell takes its own edges on the screen, by
// the rule of each edge: the cells never overlap there either, and each
// pixel blends at most once.
@(private)
pattern_at_scale_draw :: proc "contextless" (view: graphics.Canvas, area: Rectangle, pattern: draw_record.Repetition, draw_color: draw_record.Draw_Color, scale: scale_factor.Scale) {
	color := u32(draw_color)
	square_root := &graphics.text_state.square_root
	cell_x, cell_y := draw_record.pixels_floor(pattern.cell_x), draw_record.pixels_floor(pattern.cell_y)
	cell_width, cell_height := int(pattern.cell_width) >> draw_record.UNIT_SHIFT, int(pattern.cell_height) >> draw_record.UNIT_SHIFT
	step_x, step_y := int(pattern.step_x) >> draw_record.UNIT_SHIFT, int(pattern.step_y) >> draw_record.UNIT_SHIFT
	if cell_width == step_x && cell_height == step_y {
		graphics.blend_fill(view, 0, 0, area.right - area.left, area.bottom - area.top, color, square_root)
		return
	}
	// The logical pixels that hold the pixels of the area.
	logical_left := int(scale_factor.logical_pixel_of_screen_pixel(i32(area.left), scale))
	logical_top := int(scale_factor.logical_pixel_of_screen_pixel(i32(area.top), scale))
	logical_right := int(scale_factor.logical_pixel_of_screen_pixel(i32(area.right - 1), scale)) + 1
	logical_bottom := int(scale_factor.logical_pixel_of_screen_pixel(i32(area.bottom - 1), scale)) + 1
	first_x := cell_x + (divide_down(logical_left - cell_x - cell_width, step_x) + 1) * step_x
	first_y := cell_y + (divide_down(logical_top - cell_y - cell_height, step_y) + 1) * step_y
	for top := first_y; top < logical_bottom; top += step_y {
		screen_top := int(scale_factor.screen_pixel_of_logical_pixel(i32(top), scale))
		screen_bottom := int(scale_factor.screen_pixel_of_logical_pixel(i32(top + cell_height), scale))
		for left := first_x; left < logical_right; left += step_x {
			screen_left := int(scale_factor.screen_pixel_of_logical_pixel(i32(left), scale))
			screen_right := int(scale_factor.screen_pixel_of_logical_pixel(i32(left + cell_width), scale))
			cell := intersection(area, {screen_left, screen_top, screen_right, screen_bottom})
			if !empty(cell) {
				graphics.blend_fill(view, cell.left - area.left, cell.top - area.top, cell.right - cell.left, cell.bottom - cell.top, color, square_root)
			}
		}
	}
}

// picture_at_scale_draw draws the part of a picture that the area shows, a
// rectangle of the screen. logical is the box of the picture in logical
// pixels. Each pixel of the screen takes the pixel of the logical pixel
// that holds it (scale_factor.logical_pixel_of_screen_pixel), so a picture
// keeps its pixels whole, and two areas of one picture give the pixels of
// one draw. A row of the screen is made one part at a time, then copied or
// blended by the rule of its format.
@(private)
picture_at_scale_draw :: proc "contextless" (view: graphics.Canvas, area: Rectangle, logical: Rectangle, picture: graphics.Canvas, format: draw_record.Picture_Format, scale: scale_factor.Scale) {
	row: [512]graphics.Color
	for line in 0 ..< view.height {
		source_line := int(scale_factor.logical_pixel_of_screen_pixel(i32(area.top + line), scale)) - logical.top
		source_line = clamp(source_line, 0, picture.height - 1)
		for part := 0; part < view.width; part += len(row) {
			count := min(len(row), view.width - part)
			for &pixel, index in row[:count] {
				column := int(scale_factor.logical_pixel_of_screen_pixel(i32(area.left + part + index), scale)) - logical.left
				pixel = picture.pixels[source_line * picture.stride + clamp(column, 0, picture.width - 1)]
			}
			source := graphics.Canvas{pixels = raw_data(row[:]), width = count, height = 1, stride = count}
			switch format {
			case .Opaque:
				graphics.copy(view, part, line, source)
			case .Straight_Alpha:
				graphics.blend_copy(view, part, line, source, &graphics.text_state.square_root)
			}
		}
	}
}

// interface_text_at_scale_draw draws a Text record in the interface font
// at a scale. The glyphs are shaped at the size of the record, as the
// writer measured them; the origin and the x of each glyph go to the
// screen, each to the nearest unit; each glyph is drawn at the size of the
// record times the scale. The advances of the font at the size of the
// screen are not used: they round in another way, and a text would then be
// wider or narrower than its measure. view starts at the column view_left
// of the screen, and y is the top of the box on the screen in the view.
@(private)
interface_text_at_scale_draw :: proc "contextless" (table: ^Draw_Table, fields: draw_record.Draw_Text, view: graphics.Canvas, view_left, y: int, scale: scale_factor.Scale) {
	start, count := u64(fields.first), u64(fields.count)
	if start + count > u64(table.text_count) {
		return
	}
	text := table.text[start:][:count]
	font := Font{kind = .Interface, size = fields.size, weight = fields.weight}
	screen_size := scale_factor.screen_text_size(fields.size, scale)
	screen_origin := scale_factor.screen_place(fields.origin_x, scale)
	origin := screen_origin - i64(view_left) * draw_record.UNITS_PER_PIXEL
	color, alpha := draw_record.channels_of(fields.color), u32(draw_record.alpha_of(fields.color))
	if table.interface_font == nil {
		text_draw(view, int(origin >> draw_record.UNIT_SHIFT), y, string(text), color, screen_size, font.weight, alpha)
		return
	}
	face := interface_face_of(font)
	spacing, ok := interface_spacing_of(font)
	if !ok {
		return
	}
	placed: [INTERFACE_TEXT_LIMIT]text_rendering.Placed_Glyph
	placed_count, _, _ := text_rendering.shape(&spacing, text, placed[:])
	shown := placed[:min(placed_count, len(placed))]
	// The x of a glyph is from the origin: the place of the glyph on the
	// screen less the origin on the screen, so the rounding of each glyph
	// is the rounding of its own place, and no error adds up along a text.
	for &glyph in shown {
		glyph.x = i32(scale_factor.screen_place(fields.origin_x + glyph.x, scale) - screen_origin)
		glyph.advance = i32(scale_factor.screen_place(glyph.advance, scale))
	}
	graphics.text_proportional(view, origin, y, shown, face, screen_size, color, alpha)
}
