#+build !freestanding
package interface

import "modus:contract/draw_record"
import "modus:graphics"

// What a test of the package reads of a draw record, through the border:
// its kind, its rectangle in pixels, and the fields of its kind under one
// name each. A field that the kind does not have is 0.
Record_View :: struct {
	kind:                           Draw_Kind,
	read:                           bool, // The border read the record: false for a record that it refuses.
	x, y, width, height:            int, // The box, in pixels.
	color:                          graphics.Color, // The channels of the color of a rectangle, a text, the stroke of a path; of the first color of a gradient.
	second_color:                   graphics.Color, // The channels of the second color of a gradient.
	axis:                           Gradient_Axis, // The line of a gradient.
	gradient:                       draw_record.Draw_Gradient, // A gradient, with its points in 1/64 pixel.
	alpha, second_alpha:            u8, // The alpha of each color.
	format:                         Picture_Format, // A picture.
	repetition:                     draw_record.Repetition, // The pattern of a rectangle; zero for one rectangle.
	first, count:                   int, // The range of a text, of a grid or of the points of a path in the text table; the first pixel of a picture.
	size:                           int, // A text and a grid: the text size in 1/64 pixel.
	weight:                         Font_Weight, // A text.
	origin_x:                       i32, // A text, in 1/64 pixel.
	font:                           Font_Kind, // A text.
	columns:                        int, // A grid.
	memory, stride, generation:     int, // A picture.
	fill_color:                     graphics.Color, // The channels of the fill of a path.
	fill_alpha:                     u8, // The alpha of the fill of a path.
	stroke_width:                   int, // The stroke of a path, in 1/64 pixel.
}

// The text size of the body, in 1/64 pixel: the size of a record that a
// test writes by hand.
BODY_TEXT_SIZE :: graphics.TEXT_BODY * TEXT_SIZE_UNITS

// The line of a gradient in a view: the writers of the package write a
// gradient down or across.
Gradient_Axis :: enum u8 {
	None, // Not a gradient.
	Down, // The two points on one x: one color for each line.
	Across, // The two points on one y: one color for each column.
	Slanted, // Another line.
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
	case draw_record.Draw_Clip_Push:
		view.kind = .Clip_Push
	case draw_record.Draw_Clip_Pop:
		view.kind = .Clip_Pop
	case draw_record.Draw_Element_Push:
		view.kind = .Element_Push
	case draw_record.Draw_Element_Pop:
		view.kind = .Element_Pop
	case draw_record.Draw_Rectangle:
		view.kind, view.repetition = .Rectangle, fields.repetition
		view.color, view.alpha = draw_record.channels_of(fields.color), draw_record.alpha_of(fields.color)
	case draw_record.Draw_Gradient:
		view.kind, view.gradient = .Gradient, fields
		view.color, view.alpha = draw_record.channels_of(fields.start_color), draw_record.alpha_of(fields.start_color)
		view.second_color, view.second_alpha = draw_record.channels_of(fields.end_color), draw_record.alpha_of(fields.end_color)
		switch {
		case fields.start_x == fields.end_x:
			view.axis = .Down
		case fields.start_y == fields.end_y:
			view.axis = .Across
		case:
			view.axis = .Slanted
		}
	case draw_record.Draw_Text:
		view.kind, view.font = .Text, fields.font
		view.color, view.alpha = draw_record.channels_of(fields.color), draw_record.alpha_of(fields.color)
		view.first, view.count, view.size, view.weight, view.origin_x = int(fields.first), int(fields.count), int(fields.size), fields.weight, fields.origin_x
	case draw_record.Draw_Picture:
		view.kind, view.format = .Picture, fields.format
		view.memory, view.first, view.stride, view.generation = int(fields.memory), int(fields.first), int(fields.stride), int(fields.generation)
	case draw_record.Draw_Text_Grid:
		view.kind = .Text_Grid
		view.first, view.count, view.columns, view.size = int(fields.first), int(fields.count), int(fields.columns), int(fields.size)
	case draw_record.Draw_Path:
		view.kind, view.stroke_width = .Path, int(fields.stroke_width)
		view.first, view.count = int(fields.first), int(fields.count)
		view.color, view.alpha = draw_record.channels_of(fields.stroke_color), draw_record.alpha_of(fields.stroke_color)
		view.fill_color, view.fill_alpha = draw_record.channels_of(fields.fill_color), draw_record.alpha_of(fields.fill_color)
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
