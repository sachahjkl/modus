#+build !freestanding
package interface

import "modus:contract/draw_record"
import "modus:support/graphics"

// What a test of the package reads of a draw record, through the border:
// its kind, its rectangle in pixels, and the fields of its kind under one
// name each. A field that the kind does not have is 0.
Record_View :: struct {
	kind:                           Draw_Kind,
	read:                           bool, // The border read the record: false for a record that it refuses.
	x, y, width, height:            int, // The box, in pixels.
	color:                          graphics.Color, // The channels of the color of a rectangle, a text, a line; of the top or left color of a gradient.
	second_color:                   graphics.Color, // The channels of the bottom or right color of a gradient.
	alpha, second_alpha:            u8, // The alpha of each color.
	format:                         Picture_Format, // A picture.
	repetition:                     draw_record.Repetition, // The pattern of a rectangle; zero for one rectangle.
	first, count:                   int, // The range of a text or of a grid in the text table; the first pixel of a picture.
	scale:                          int, // A text.
	weight:                         Font_Weight, // A text.
	origin_x:                       i32, // A text, in 1/64 pixel.
	font:                           Font_Kind, // A text.
	columns:                        int, // A grid.
	memory, stride, generation:     int, // A picture.
	start_x, start_y, end_x, end_y: int, // A line, in pixels.
	thickness:                      int, // A line.
}

// record_view reads one record for a test.
record_view :: proc(record: Draw_Record) -> Record_View {
	view: Record_View
	place := record_rectangle(record)
	view.x, view.y, view.width, view.height = place.left, place.top, place.right - place.left, place.bottom - place.top
	primitive, problem := draw_record.read(record)
	if problem != .None {
		return view
	}
	view.read = true
	switch fields in primitive {
	case draw_record.Draw_Nothing:
		view.kind = .None
	case draw_record.Draw_Clip:
		view.kind = .Clip
	case draw_record.Draw_Rectangle:
		view.kind, view.repetition = .Rectangle, fields.repetition
		view.color, view.alpha = draw_record.channels_of(fields.color), draw_record.alpha_of(fields.color)
	case draw_record.Draw_Vertical_Gradient:
		view.kind = .Vertical_Gradient
		view.color, view.alpha = draw_record.channels_of(fields.top_color), draw_record.alpha_of(fields.top_color)
		view.second_color, view.second_alpha = draw_record.channels_of(fields.bottom_color), draw_record.alpha_of(fields.bottom_color)
	case draw_record.Draw_Horizontal_Gradient:
		view.kind = .Horizontal_Gradient
		view.color, view.alpha = draw_record.channels_of(fields.left_color), draw_record.alpha_of(fields.left_color)
		view.second_color, view.second_alpha = draw_record.channels_of(fields.right_color), draw_record.alpha_of(fields.right_color)
	case draw_record.Draw_Text:
		view.kind, view.font = .Text, fields.font
		view.color, view.alpha = draw_record.channels_of(fields.color), draw_record.alpha_of(fields.color)
		view.first, view.count, view.scale, view.weight, view.origin_x = int(fields.first), int(fields.count), int(fields.scale), fields.weight, fields.origin_x
	case draw_record.Draw_Picture:
		view.kind, view.format = .Picture, fields.format
		view.memory, view.first, view.stride, view.generation = int(fields.memory), int(fields.first), int(fields.stride), int(fields.generation)
	case draw_record.Draw_Text_Grid:
		view.kind = .Text_Grid
		view.first, view.count, view.columns = int(fields.first), int(fields.count), int(fields.columns)
	case draw_record.Draw_Line:
		view.kind, view.thickness = .Line, int(fields.thickness)
		view.color, view.alpha = draw_record.channels_of(fields.color), draw_record.alpha_of(fields.color)
		view.start_x, view.start_y = draw_record.pixels_floor(fields.start_x), draw_record.pixels_floor(fields.start_y)
		view.end_x, view.end_y = draw_record.pixels_floor(fields.end_x), draw_record.pixels_floor(fields.end_y)
	}
	return view
}

// is_solid_rectangle says if a record is a Rectangle that fills its box:
// a Rectangle with a pattern, such as the grid of points, is not one.
is_solid_rectangle :: proc(view: Record_View) -> bool {
	return view.kind == .Rectangle && view.repetition == (draw_record.Repetition{})
}

// is_pattern says if a record is a Rectangle with a pattern.
is_pattern :: proc(view: Record_View) -> bool {
	return view.kind == .Rectangle && view.repetition != (draw_record.Repetition{})
}

// is_text_record says if a record is a text that the border reads, in the
// font of the cells or in the interface font.
is_text_record :: proc(record: Draw_Record) -> bool {
	return record_view(record).kind == .Text
}

// is_interface_text says if a record is a text in the interface font.
is_interface_text :: proc(record: Draw_Record) -> bool {
	view := record_view(record)
	return view.kind == .Text && view.font == .Interface
}

// is_cells_text says if a record is a text in the font of the cells.
is_cells_text :: proc(record: Draw_Record) -> bool {
	view := record_view(record)
	return view.kind == .Text && view.font == .Cells_8x16
}
