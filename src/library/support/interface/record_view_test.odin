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
	color:                          graphics.Color, // A rectangle, a text, a line; the top or left color of a gradient.
	second_color:                   graphics.Color, // The bottom or right color of a gradient.
	repetition:                     draw_record.Repetition, // The pattern of a rectangle; zero for one rectangle.
	first, count:                   int, // The range of a text or of a grid in the text table; the first pixel of a picture.
	scale:                          int, // A text.
	weight:                         Font_Weight, // A text.
	origin_x:                       i32, // An interface text, in 1/64 pixel.
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
		view.kind, view.color, view.repetition = .Rectangle, fields.color, fields.repetition
	case draw_record.Draw_Vertical_Gradient:
		view.kind, view.color, view.second_color = .Vertical_Gradient, fields.top_color, fields.bottom_color
	case draw_record.Draw_Horizontal_Gradient:
		view.kind, view.color, view.second_color = .Horizontal_Gradient, fields.left_color, fields.right_color
	case draw_record.Draw_Text:
		view.kind, view.color = .Text, fields.color
		view.first, view.count, view.scale, view.weight = int(fields.first), int(fields.count), int(fields.scale), fields.weight
	case draw_record.Draw_Interface_Text:
		view.kind, view.color = .Interface_Text, fields.color
		view.first, view.count, view.scale, view.weight, view.origin_x = int(fields.first), int(fields.count), int(fields.scale), fields.weight, fields.origin_x
	case draw_record.Draw_Picture:
		view.kind = .Picture
		view.memory, view.first, view.stride, view.generation = int(fields.memory), int(fields.first), int(fields.stride), int(fields.generation)
	case draw_record.Draw_Text_Grid:
		view.kind = .Text_Grid
		view.first, view.count, view.columns = int(fields.first), int(fields.count), int(fields.columns)
	case draw_record.Draw_Line:
		view.kind, view.color, view.thickness = .Line, fields.color, int(fields.thickness)
		view.start_x, view.start_y = draw_record.pixels_floor(fields.start_x), draw_record.pixels_floor(fields.start_y)
		view.end_x, view.end_y = draw_record.pixels_floor(fields.end_x), draw_record.pixels_floor(fields.end_y)
	}
	return view
}

// is_text_record says if a record is a text that the border reads, in the
// font of the cells or in the interface font.
is_text_record :: proc(record: Draw_Record) -> bool {
	view := record_view(record)
	return view.kind == .Text || view.kind == .Interface_Text
}
