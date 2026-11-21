// The draw record: one thing to draw in the draw table of a frame
// (src/md/api/draw_table.md). The interface package writes the records, and
// the drawing module and the compositor read them, so the form is a
// contract: bytes at stated offsets, with no type of one language in them.
//
// A record is 48 bytes: a header of 24 bytes (the word of the kind, three
// reserved bytes, the element identity and the box), then 24 bytes that
// belong to its kind. Each byte that its kind does not name is 0, so two
// records with the same bytes draw the same thing, and the damage by
// difference compares bytes. Two records with other bytes can still draw
// the same pixels (`read` names the cases): their damage is then too
// large, never too small.
//
// One border reads a record: `read` takes one copy and gives a
// `Draw_Primitive`, a union with one record type for each kind, or the
// problem that refuses it. The union is the view of the reader past the
// border; the bytes are the contract. `record_of` writes a record from a
// primitive, so the kind of a record always matches its fields.
//
// Places are in units of 1/64 pixel. A rectangle with no pattern and a
// gradient draw inside a pixel: the part of an edge pixel that the box
// covers scales the alpha of that pixel. A path draws inside a pixel too:
// its points are places in units, and its box, on whole pixels, cuts it.
// The other kinds draw on whole pixels, so the border refuses their box off
// whole pixels; the origin of a text in the interface font is on a third of
// a pixel.
//
// A path names its points in the text table of its frame, as a text names
// its bytes there. `read` checks the record; `path_points_read` is the
// border of the points, which the reader calls on its one copy of them.
//
// A color is a Draw_Color, 0xAARRGGBB with straight alpha: alpha 255 is
// opaque, and a color of 0 is transparent. A record blends its color over
// the pixels by one rule, in linear light (graphics.blend_fill).
//
// A Clip_Push cuts the records after it to its box and to the cut before
// it, until its Clip_Pop. The order of the clips is a fact of the table,
// not of one record: clip_order_check is its border.
//
// See [draw record](term:draw-record), [draw table](term:draw-table) and
// [clip stack](term:clip-stack).
package draw_record

import "base:intrinsics"
import "modus:contract/enum_word"

// The version of the form of the record. A change of a kind, of a field,
// of a bound that changes what a record draws, or of a rule of the
// execution is a new version, and the names of the exports of the drawing
// module carry it.
VERSION :: 20

RECORD_SIZE :: 48 // The bytes of one record.
HEADER_SIZE :: 24 // The bytes of the header: the kind, the reserved bytes, the element and the box.
FIELDS_SIZE :: 24 // The bytes that belong to the kind of a record.

UNITS_PER_PIXEL :: 64 // The units of a place in one pixel: the unit of the measure of a text.
UNIT_SHIFT :: 6 // log2 of UNITS_PER_PIXEL: a place in units to pixels is a shift.

// The places of a record stay inside this distance of the corner of the
// surface, in pixels. In units, an edge is then inside 2^29, so the
// difference of two edges (at most 2^30) and the sum of an edge and an ink
// margin fit an i32. A surface is far smaller.
COORDINATE_LIMIT :: 1 << 23
COORDINATE_UNIT_LIMIT :: COORDINATE_LIMIT * UNITS_PER_PIXEL // The same limit in units.

// The most points of one path. The execution copies the points once onto
// its stack (12 KiB) and walks each segment once for each band of rows, so
// the bound is a bound of its memory and of its work.
PATH_POINT_LIMIT :: 1024

// The bytes of one point of a path in the text table: Path_Point_Record.
PATH_POINT_SIZE :: 12

// The widest stroke, in pixels: a stroke grows the box of its path by half
// its width, and each pixel of that band is drawn again in each damage
// rectangle that the box meets.
STROKE_WIDTH_LIMIT :: 64
STROKE_WIDTH_UNIT_LIMIT :: STROKE_WIDTH_LIMIT * UNITS_PER_PIXEL // The same limit in units.

// The most line segments of one quadratic curve. The execution cuts a
// curve into the fewest segments, 1 to this count, whose distance from the
// curve is at most CURVE_TOLERANCE_UNITS; a curve whose bend needs more is
// cut into this count, and its distance from the curve is then at most its
// bend over 4 * CURVE_SEGMENT_LIMIT^2 (curve_segment_count).
CURVE_SEGMENT_LIMIT :: 16

// The largest distance of the segments of a curve from the curve, in units:
// 1/8 pixel, the tolerance of the glyphs.
CURVE_TOLERANCE_UNITS :: 8

// The largest distance between the two points of a gradient on each axis,
// in pixels. The execution multiplies the distance of a pixel from the
// first point (at most 2^30 units) by this span in units (2^21) and by
// 255: with it, each product and their sum fit an i64.
GRADIENT_SPAN_LIMIT :: 1 << 15

// The text size of a Text and of a Text_Grid is the height of its line, in
// 1/64 pixel: a line of 16 pixels is 1 024. The border refuses a size out
// of this range, and never clamps it. Under 4 pixels a glyph has no form
// that a reader can read; the largest size is a bound of cost: the worst
// record is 256 glyphs of that size over one place. A larger text is a path.
// The size is in logical pixels: at the largest scale, 2, a text of 128
// logical pixels is drawn at 256 pixels of the screen, the largest size
// that the rasterizer draws (text_rendering.TEXT_SIZE_LIMIT). So each text
// that the border takes has its glyphs at each scale.
TEXT_SIZE_MINIMUM :: 4 * UNITS_PER_PIXEL
TEXT_SIZE_LIMIT :: 128 * UNITS_PER_PIXEL
#assert(TEXT_SIZE_LIMIT <= int(max(u16)))

// The most bytes of one text in the interface font: the execution places
// its glyphs on its stack. A longer text is drawn in the font of the cells.
INTERFACE_TEXT_LIMIT :: 256

// The largest ink margin of a text in the interface font, in pixels, at a
// line of 16 pixels or less: the distance from the left edge of its box to
// its origin. The margin grows with the size, so at a larger size the bound
// is one line (origin_valid).
INK_MARGIN_LIMIT :: 16

// The most clips that are open at one time. A reader keeps one rectangle
// for each depth on its stack, with no allocator, so the bound is a bound
// of its memory; a push and a pop cost the same at each depth.
CLIP_DEPTH_LIMIT :: 16

// What one draw record draws. The values cross the border of the drawing
// module, so they are stated. The format holds primitives only: the look
// of the system (the grid of points, the folded gap) is elements of the
// interface package, drawn with them. A text run is one kind for each font:
// its font is a field, a gradient is one kind along any line, a line is
// the stroke of a path, and a clip is pushed and popped. The values 2, 3,
// 5, 6, 7, 10 and 11 name no kind: each named a kind that left the format,
// and a new kind takes a new value, so that a record of an older form is
// refused and never read with other fields.
Draw_Kind :: enum u8 {
	None         = 0,  // Nothing.
	Rectangle    = 1,  // The box in one color, or a pattern of cells of that color that repeats, cut to the box.
	Text         = 4,  // A text run in a font, from its origin at the top of the box.
	Picture      = 8,  // The pixels of a picture of the caller, by values in a picture memory.
	Text_Grid    = 9,  // A grid of text cells, copied into the text table.
	Gradient     = 12, // The box in a color that goes from a color at one point to a color at another, along the line of the two points.
	Path         = 13, // Lines and quadratic curves, from points in the text table: filled, then stroked, with antialiased edges, cut to the box.
	Clip_Push    = 14, // The records after it, until its Clip_Pop, are cut to the box and to the cut before it. The box is on whole pixels.
	Clip_Pop     = 15, // Gives back the cut before the last Clip_Push that is open. The box is 0.
	Element_Push = 16, // Draws nothing: opens a semantic element node whose records follow until its Element_Pop. The box is on whole pixels.
	Element_Pop  = 17, // Draws nothing: closes the last Element_Push that is open. The box is 0.
}

// Why the border of the order of the clips refuses a table.
Clip_Order_Problem :: enum u8 {
	None                  = 0, // Each push has its pop, and no push is past CLIP_DEPTH_LIMIT.
	Pop_Without_Push      = 1, // A Clip_Pop with no Clip_Push open.
	Push_Past_Depth_Limit = 2, // A Clip_Push with CLIP_DEPTH_LIMIT pushes open already.
	Push_Without_Pop      = 3, // The table ends with a Clip_Push open.
}

// The command of one point of a path. The values cross the border of the
// drawing module in the text table, so they are stated; 0 names no
// command, so a range of zeros is no path.
Path_Command :: enum u32 {
	Move          = 1, // Starts a subpath at the point.
	Line          = 2, // A line segment from the point before to the point; also the end of a curve.
	Curve_Control = 3, // The control point of a quadratic curve. The next point is a Line: the end of the curve.
	Close         = 4, // Closes the subpath with a segment to its Move; its x and y are 0.
}

// Why the border of the points of a path refuses them.
Path_Problem :: enum u8 {
	None                        = 0, // The points are read.
	Count_Out_Of_Range          = 1, // The bytes are not a whole count of points, or the points are fewer than 2 or more than PATH_POINT_LIMIT.
	Unknown_Command             = 2, // The word of a command names no member of Path_Command.
	Not_Started_By_Move         = 3, // The first point is not a Move.
	Empty_Subpath               = 4, // A Move is followed by a Move, or is the last point: a subpath with no segment.
	Curve_Without_End           = 5, // A Curve_Control is not followed by a Line.
	Close_Out_Of_Place          = 6, // A Close does not follow a Line, or is followed by a point that is not a Move.
	Close_Point_Not_Zero        = 7, // The x or the y of a Close is not 0.
	Point_Past_Coordinate_Limit = 8, // A point is past COORDINATE_LIMIT.
}

// The weight of a text, at each size. With Spleen 8x16 it is the regular
// weight.
Font_Weight :: enum u8 {
	Regular = 0, // The normal weight.
	Bold    = 1, // The bold weight.
}

// A color of a record: 0xAARRGGBB, with straight alpha in the high byte.
// Alpha 255 is opaque; a color of 0 is transparent, so a record of zeros
// draws nothing. A distinct type, so that a color of a canvas, 0x00RRGGBB,
// never passes for one: opaque gives the draw color of such a color.
Draw_Color :: distinct u32

ALPHA_SHIFT :: 24 // The place of the alpha in a Draw_Color.
OPAQUE_ALPHA :: 255 // The alpha of an opaque color.
CHANNELS_MASK :: 0x00FF_FFFF // The red, the green and the blue of a Draw_Color.

// The form of the pixels of a Picture.
Picture_Format :: enum u8 {
	Opaque         = 0, // Each pixel is 0x00RRGGBB, copied as it is.
	Straight_Alpha = 1, // Each pixel is 0xAARRGGBB with straight alpha, blended by the rule of the colors.
}

// The font of a text run (docs/FONTS.md, "12.6 Which text stays monospace").
// Zero is the font of the cells, the font that needs no cache.
Font_Kind :: enum u8 {
	Cells_8x16 = 0, // The font of the cells: each character is one cell wide, its origin on a whole pixel.
	Interface  = 1, // The proportional interface font, its origin on a third of a pixel.
}

// Why the border refuses a record.
Problem :: enum u8 {
	None                      = 0, // The record is read.
	Unknown_Kind              = 1, // The word of the kind names no member of Draw_Kind.
	Reserved_Not_Zero         = 2, // A reserved byte of the header, or a byte that the kind does not name, is not 0.
	Box_Inverted              = 3, // The right edge of the box is left of its left edge, or its bottom above its top.
	Box_Past_Coordinate_Limit = 4, // An edge of the box is past COORDINATE_LIMIT.
	Box_Not_On_Whole_Pixels   = 5, // An edge of the box is not a whole pixel, in a kind whose box is on whole pixels: each kind but a rectangle with no pattern and a gradient.
	Field_Past_Bound          = 6, // A field of the kind is out of its range: a color that is not canonical, a format, a text size, a weight, the two points of a gradient, a count, an origin, the first byte of a path, the width of a stroke.
}

// One draw record, 48 bytes, little-endian. A record holds values only:
// no address, so it means the same in each address space, and a GPU can
// read it.
//
// Example: `record_of(Draw_Rectangle{color = 0xFF102030}, 0, 0, 0, 640, 1536)`
// is an opaque rectangle of 10 by 24 pixels at the corner of the surface.
Draw_Record :: struct {
	kind:     u8, // The word of the kind: draw_kind_of_word gives its Draw_Kind. A Clip_Push and a Clip_Pop have no field; the order of the clips is the order of these words.
	reserved: [3]u8, // 0.
	element:  u32, // The low 32 bits of the identity of the element that wrote the record, 0 for none: a tool can say which element changed.
	left:     i32, // The left edge of the box, in 1/64 pixel. The record draws no pixel outside its box.
	top:      i32, // The top edge of the box, in 1/64 pixel.
	right:    i32, // The right edge of the box, in 1/64 pixel: the column at this edge is not in the box.
	bottom:   i32, // The bottom edge of the box, in 1/64 pixel: the line at this edge is not in the box.
	fields:   [24]u8, // The fields of the kind: one of the *_Fields layouts below, and 0 in each byte that the kind does not name.
}

#assert(size_of(Draw_Record) == RECORD_SIZE)
#assert(offset_of(Draw_Record, fields) == HEADER_SIZE)

// The layouts of the fields of each kind, in the 24 bytes at the offset 24
// of a record. A kind with no field (None, Clip_Push, Clip_Pop) has 24
// bytes of 0.

// The fields of a Rectangle. With both steps at 0, the rectangle is its
// box, and the other fields of the repetition are 0. With both steps above
// 0, it is a pattern: a cell of cell_width by cell_height at
// (cell_x + n * step_x, cell_y + m * step_y) of the surface for each
// integers n and m, cut to the box. The pattern is placed on the surface,
// not on the box, so two boxes of one surface show one pattern, and an
// element that draws a part of it needs no clip.
Rectangle_Fields :: struct {
	color:       u32, // A Draw_Color, canonical: a color with alpha 0 is 0.
	cell_x:      i32, // The left edge of one cell of the pattern, in 1/64 pixel of the surface: a whole pixel inside COORDINATE_LIMIT.
	cell_y:      i32, // The top edge of that cell, in 1/64 pixel.
	cell_width:  u16, // In 1/64 pixel: a whole pixel, at least 1, at most step_x.
	cell_height: u16, // In 1/64 pixel: a whole pixel, at least 1, at most step_y.
	step_x:      u16, // In 1/64 pixel, from one cell to the next across: a whole pixel, at least 1.
	step_y:      u16, // In 1/64 pixel, from one cell to the next down: a whole pixel, at least 1.
	reserved:    [4]u8, // 0.
}

// The fields of a Gradient. The color of a pixel comes from the projection
// of its center on the line of the two points, cut to the two ends, in
// steps of 1/255: the level is 255 times the projection over the length,
// rounded down. The two colors mix at that level in their encoded values,
// alpha too, so the red, the green and the blue of an end with alpha 0
// still color the pixels between: a fade to a transparent red stays red.
// Two ends with alpha 0 draw nothing, and are both 0. The two points
// differ, and are at most GRADIENT_SPAN_LIMIT pixels apart on each axis.
Gradient_Fields :: struct {
	start_x:     i32, // The first point, in 1/64 pixel of the surface, inside COORDINATE_LIMIT.
	start_y:     i32,
	end_x:       i32, // The second point, in 1/64 pixel of the surface.
	end_y:       i32,
	start_color: u32, // A Draw_Color: the color at the first point and before it.
	end_color:   u32, // A Draw_Color: the color at the second point and past it.
}

// The fields of a Text: a run of text in one font. The box holds every
// pixel of its ink: for the interface font, the box of its measure grown by
// its ink margin on each side; for the font of the cells, its cells. The top
// of the box is the top of the line. The range stays the first field: the
// difference masks the word that holds it (src/library/modus/interface,
// difference.odin).
Text_Fields :: struct {
	first:    u32, // The first byte of the text in the text table.
	count:    u32, // The bytes of the text; in the interface font, at most INTERFACE_TEXT_LIMIT.
	color:    u32, // A Draw_Color, canonical: a color with alpha 0 is 0. The alpha scales the coverage of each glyph.
	origin_x: i32, // The origin of the text, in 1/64 pixel, right of the left edge of the box by at most the larger of INK_MARGIN_LIMIT pixels and one line: on a whole pixel in the font of the cells, on a third of a pixel in the interface font.
	font:     u8, // The word of a Font_Kind.
	weight:   u8, // The word of a Font_Weight.
	size:     u16, // The text size in 1/64 pixel: TEXT_SIZE_MINIMUM to TEXT_SIZE_LIMIT.
	reserved: [4]u8, // 0.
}

// The fields of a Picture. Its size is the size of the box.
Picture_Fields :: struct {
	memory:          u8, // The number of its picture memory in the list of the draw table.
	format:          u8, // The word of a Picture_Format.
	memory_reserved: [2]u8, // 0.
	first:           u32, // The index of its first pixel in that memory.
	stride:          u32, // The pixels from one line to the next.
	generation:      u32, // A new number when its pixels change: the difference sees the change.
	reserved:        [8]u8, // 0.
}

// The fields of a Text_Grid. The cells are in the text table, 16 bytes each.
// A cell is half the text size wide, rounded to a whole pixel with a half
// up, and two widths high, so a cell is whole pixels at each size.
Text_Grid_Fields :: struct {
	first:    u32, // The first byte of the cells in the text table, a multiple of 4.
	count:    u32, // The bytes of the cells: rows times columns times 16.
	columns:  u32, // The cells of one row.
	size:     u16, // The text size in 1/64 pixel: TEXT_SIZE_MINIMUM to TEXT_SIZE_LIMIT.
	reserved: [10]u8, // 0.
}

// The fields of a Path. Its points are in the text table: count bytes from
// the byte first, PATH_POINT_SIZE bytes each (Path_Point_Record). The fill
// covers the inside of the subpaths by the nonzero rule, each subpath
// closed for the fill; then the stroke covers a band of stroke_width along
// each segment, with butt ends and bevel joins. A color of 0 is no fill or
// no stroke; a stroke color of 0 has a width of 0, and a width of 0 has a
// stroke color of 0, so that no stroke has one form. The range stays the
// first field, as in a Text: the difference masks it.
Path_Fields :: struct {
	first:        u32, // The first byte of the points in the text table, a multiple of 4.
	count:        u32, // The bytes of the points: 2 to PATH_POINT_LIMIT times PATH_POINT_SIZE.
	fill_color:   u32, // A Draw_Color, canonical: 0 is no fill.
	stroke_color: u32, // A Draw_Color, canonical: 0 is no stroke.
	stroke_width: u32, // In 1/64 pixel: 1 to STROKE_WIDTH_UNIT_LIMIT with a stroke color, 0 without.
	reserved:     [4]u8, // 0.
}

// One point of a path, 12 bytes in the text table, little-endian. A Close
// has the x and the y 0.
Path_Point_Record :: struct {
	command: u32, // The word of a Path_Command.
	x:       i32, // In 1/64 pixel of the surface, inside COORDINATE_LIMIT.
	y:       i32,
}

#assert(size_of(Rectangle_Fields) == FIELDS_SIZE)
#assert(size_of(Gradient_Fields) == FIELDS_SIZE)
#assert(size_of(Text_Fields) == FIELDS_SIZE)
#assert(size_of(Picture_Fields) == FIELDS_SIZE)
#assert(size_of(Text_Grid_Fields) == FIELDS_SIZE)
#assert(size_of(Path_Fields) == FIELDS_SIZE)
#assert(size_of(Path_Point_Record) == PATH_POINT_SIZE)

// The primitives: what a record draws, as the reader sees it past the
// border. Each has the fields of its kind only, with the words of the
// record as their enums. The box stays in the record.
Draw_Nothing :: struct {}
Draw_Rectangle :: struct {
	color:      Draw_Color,
	repetition: Repetition, // Zero: the rectangle is its box.
}
// The pattern of a Rectangle: the place of one cell, its size and the steps,
// in 1/64 pixel (Rectangle_Fields).
Repetition :: struct {
	cell_x, cell_y:                              i32,
	cell_width, cell_height, step_x, step_y: u16,
}
Draw_Gradient :: struct {
	start_x, start_y, end_x, end_y: i32, // In 1/64 pixel of the surface.
	start_color, end_color:         Draw_Color,
}
Draw_Text :: struct {
	first, count:        u32,
	color:               Draw_Color,
	origin_x:            i32, // In 1/64 pixel.
	font:                Font_Kind,
	weight:              Font_Weight,
	size:                u16, // The text size in 1/64 pixel.
}
// A push of a clip: its box is the clip. A pop of a clip: its box is 0.
// Both have no field.
Draw_Clip_Push :: struct {}
Draw_Clip_Pop :: struct {}
Draw_Picture :: struct {
	memory:                    u8,
	format:                    Picture_Format,
	first, stride, generation: u32,
}
Draw_Text_Grid :: struct {
	first, count, columns: u32,
	size:                  u16, // The text size in 1/64 pixel.
}
Draw_Path :: struct {
	first, count:             u32, // The range of the points in the text table, in bytes.
	fill_color, stroke_color: Draw_Color,
	stroke_width:             u32, // In 1/64 pixel; 0 with no stroke.
}

// One point of a path past the border of the points.
Path_Point :: struct {
	command: Path_Command,
	x, y:    i32, // In 1/64 pixel of the surface.
}

// One primitive of each kind. A record that `read` accepts is never nil:
// a record of the kind None is a Draw_Nothing.
Draw_Primitive :: union {
	Draw_Nothing,
	Draw_Rectangle,
	Draw_Gradient,
	Draw_Text,
	Draw_Clip_Push,
	Draw_Clip_Pop,
	Draw_Element_Push,
	Draw_Element_Pop,
	Draw_Picture,
	Draw_Text_Grid,
	Draw_Path,
}

// draw_kind_of_word reads the word of the kind of a record. A word that
// names no member is refused, never taken for a member.
draw_kind_of_word :: proc "contextless" (word: u8) -> (kind: Draw_Kind, ok: bool) {
	return enum_word.member_of_word(Draw_Kind, u64(word))
}

// font_weight_of_word reads the word of the weight of a text.
font_weight_of_word :: proc "contextless" (word: u8) -> (weight: Font_Weight, ok: bool) {
	return enum_word.member_of_word(Font_Weight, u64(word))
}

// font_kind_of_word reads the word of the font of a text.
font_kind_of_word :: proc "contextless" (word: u8) -> (font: Font_Kind, ok: bool) {
	return enum_word.member_of_word(Font_Kind, u64(word))
}

// picture_format_of_word reads the word of the format of a picture.
picture_format_of_word :: proc "contextless" (word: u8) -> (format: Picture_Format, ok: bool) {
	return enum_word.member_of_word(Picture_Format, u64(word))
}

// path_command_of_word reads the word of the command of a point of a path.
path_command_of_word :: proc "contextless" (word: u32) -> (command: Path_Command, ok: bool) {
	return enum_word.member_of_word(Path_Command, u64(word))
}

// opaque gives the opaque draw color of a color of a canvas, 0x00RRGGBB:
// its high byte is not read.
opaque :: #force_inline proc "contextless" (color: u32) -> Draw_Color {
	return Draw_Color(color & CHANNELS_MASK | OPAQUE_ALPHA << ALPHA_SHIFT)
}

// with_alpha gives the draw color of a color of a canvas with an alpha, in
// its canonical form: with alpha 0 it is 0, the one transparent color.
with_alpha :: #force_inline proc "contextless" (color: u32, alpha: u8) -> Draw_Color {
	if alpha == 0 {
		return 0
	}
	return Draw_Color(color & CHANNELS_MASK | u32(alpha) << ALPHA_SHIFT)
}

// alpha_of gives the alpha of a draw color.
alpha_of :: #force_inline proc "contextless" (color: Draw_Color) -> u8 {
	return u8(u32(color) >> ALPHA_SHIFT)
}

// channels_of gives the red, the green and the blue of a draw color, as a
// color of a canvas: 0x00RRGGBB.
channels_of :: #force_inline proc "contextless" (color: Draw_Color) -> u32 {
	return u32(color) & CHANNELS_MASK
}

// The record as words of 64 bits: the unit of the one copy.
RECORD_WORDS :: RECORD_SIZE / size_of(u64)

#assert(RECORD_SIZE % size_of(u64) == 0)

// copy_once takes the one copy of a record that a reader then checks: a
// table can be in memory that another process writes during the read, so
// each byte is loaded once and never again. The copy is six loads of 64
// bits: a volatile load of the whole struct is compiled field by field and
// byte by byte for the arrays, which made the difference of two frames
// twice as slow.
copy_once :: #force_inline proc "contextless" (record: ^Draw_Record) -> Draw_Record {
	return transmute(Draw_Record)intrinsics.volatile_load((^[RECORD_WORDS]u64)(record))
}

// read is the border of a draw record. It takes the one copy of a record
// that the caller read, and gives the primitive that it draws, or the
// problem that refuses it: a word of a kind that names no member, a
// reserved byte or a byte that the kind does not name that is not 0, a box
// whose right is left of its left or whose bottom is above its top, an
// edge past COORDINATE_LIMIT, an edge not on a whole pixel in a kind that
// draws on whole pixels, and a field of the kind out of its range: a color
// that is not canonical, two points of a gradient that are equal, past the
// limit or too far apart, and a path whose range is not a whole count of
// 2 to PATH_POINT_LIMIT points from a multiple of 4, or whose stroke has a
// width of 0, a width past STROKE_WIDTH_LIMIT, or a width with no color,
// too; and a Clip_Pop whose box is not 0, as bytes that the kind does not
// name. A refused record draws nothing. The order of the clips is checked
// on the table (clip_order_check), not here.
// The checks run in that order, so a record with two faults gives the
// problem of the first check.
//
// A record that the border reads is canonical: each byte that the kind does
// not name is 0, and a color with alpha 0 that draws nothing is 0. So two
// records with the same bytes draw the same thing. Two records with other
// bytes, but the first byte of a range in the text table, can still draw
// the same pixels: a gradient of one line whose second end, with alpha 0,
// is never drawn, two rectangles of the color 0 with other patterns, and a
// rectangle of the color 0 against a None. The difference damages their
// boxes: too large, never too small.
//
// The checks are on the record alone. What a record names in the tables of
// its frame (a range of the text table, the pixels of a picture memory, the
// points of a path) is checked where the table is: the record does not hold
// it. path_points_read is the border of the points.
read :: proc "contextless" (record: Draw_Record) -> (primitive: Draw_Primitive, problem: Problem) {
	kind, known := draw_kind_of_word(record.kind)
	if !known {
		return nil, .Unknown_Kind
	}
	if !all_zero(record.reserved) {
		return nil, .Reserved_Not_Zero
	}
	if !inside_coordinate_limit(record.left) || !inside_coordinate_limit(record.top) || !inside_coordinate_limit(record.right) || !inside_coordinate_limit(record.bottom) {
		return nil, .Box_Past_Coordinate_Limit
	}
	if record.right < record.left || record.bottom < record.top {
		return nil, .Box_Inverted
	}
	// A rectangle and a gradient take a box inside a pixel; each other kind,
	// and a rectangle with a pattern (below), has a box on whole pixels. The
	// points of a path are not its box: they lie inside a pixel.
	whole := on_whole_pixel(record.left) && on_whole_pixel(record.top) && on_whole_pixel(record.right) && on_whole_pixel(record.bottom)
	if !whole && kind != .Rectangle && kind != .Gradient {
		return nil, .Box_Not_On_Whole_Pixels
	}
	switch kind {
	case .None:
		if !all_zero(record.fields) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Nothing{}, .None
	case .Clip_Push:
		if !all_zero(record.fields) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Clip_Push{}, .None
	case .Clip_Pop:
		// A pop names no byte of its box: the cut that it gives back is
		// the cut before its push.
		if !all_zero(record.fields) || record.left != 0 || record.top != 0 || record.right != 0 || record.bottom != 0 {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Clip_Pop{}, .None
	case .Element_Push:
		fields := transmute(Element_Push_Fields)record.fields
		if fields.name_reserved != 0 || fields.detail_reserved != 0 {
			return nil, .Reserved_Not_Zero
		}
		if record.element == 0 {
			return nil, .Field_Past_Bound
		}
		role, role_ok := element_role_of_word(fields.role)
		live, live_ok := live_mode_of_word(fields.live)
		toggle, toggle_ok := toggle_state_of_word(fields.toggle)
		expanded, expanded_ok := expanded_state_of_word(fields.expanded)
		states, states_ok := element_states_of_word(fields.states)
		if !role_ok || !live_ok || !toggle_ok || !expanded_ok || !states_ok {
			return nil, .Field_Past_Bound
		}
		if fields.name_count > ELEMENT_NAME_LIMIT || fields.detail_count > ELEMENT_DETAIL_LIMIT {
			return nil, .Field_Past_Bound
		}
		if (fields.name_count == 0 && fields.name_first != 0) || (fields.detail_count == 0 && fields.detail_first != 0) {
			return nil, .Field_Past_Bound
		}
		if fields.detail_count > 0 && fields.detail_first % 4 != 0 {
			return nil, .Field_Past_Bound
		}
		return Draw_Element_Push{
			role         = role,
			live         = live,
			toggle       = toggle,
			expanded     = expanded,
			states       = states,
			name_first   = fields.name_first,
			name_count   = fields.name_count,
			detail_first = fields.detail_first,
			detail_count = fields.detail_count,
		}, .None
	case .Element_Pop:
		// A pop names no byte of its box and has no fields.
		if !all_zero(record.fields) || record.left != 0 || record.top != 0 || record.right != 0 || record.bottom != 0 {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Element_Pop{}, .None
	case .Rectangle:
		fields := transmute(Rectangle_Fields)record.fields
		if !all_zero(fields.reserved) {
			return nil, .Reserved_Not_Zero
		}
		repetition := Repetition{cell_x = fields.cell_x, cell_y = fields.cell_y, cell_width = fields.cell_width, cell_height = fields.cell_height, step_x = fields.step_x, step_y = fields.step_y}
		// The cells of a pattern are whole pixels, and its box cuts them:
		// a box inside a pixel would cut a cell inside a pixel.
		if !whole && repetition != (Repetition{}) {
			return nil, .Box_Not_On_Whole_Pixels
		}
		if !color_canonical(Draw_Color(fields.color)) || !repetition_valid(repetition) {
			return nil, .Field_Past_Bound
		}
		return Draw_Rectangle{color = Draw_Color(fields.color), repetition = repetition}, .None
	case .Gradient:
		fields := transmute(Gradient_Fields)record.fields
		gradient := Draw_Gradient{start_x = fields.start_x, start_y = fields.start_y, end_x = fields.end_x, end_y = fields.end_y, start_color = Draw_Color(fields.start_color), end_color = Draw_Color(fields.end_color)}
		if !gradient_line_valid(gradient) || !gradient_colors_canonical(gradient.start_color, gradient.end_color) {
			return nil, .Field_Past_Bound
		}
		return gradient, .None
	case .Text:
		fields := transmute(Text_Fields)record.fields
		if !all_zero(fields.reserved) {
			return nil, .Reserved_Not_Zero
		}
		font, font_ok := font_kind_of_word(fields.font)
		weight, weight_ok := font_weight_of_word(fields.weight)
		if !font_ok || !weight_ok || !text_size_valid(fields.size) || !color_canonical(Draw_Color(fields.color)) || !origin_valid(fields.origin_x, record.left, fields.size) {
			return nil, .Field_Past_Bound
		}
		// The font of the cells draws from a whole pixel and has no bound of
		// bytes; the interface font draws from a third of a pixel, and places
		// at most INTERFACE_TEXT_LIMIT glyphs on its stack.
		switch font {
		case .Cells_8x16:
			if !on_whole_pixel(fields.origin_x) {
				return nil, .Field_Past_Bound
			}
		case .Interface:
			if fields.count > INTERFACE_TEXT_LIMIT {
				return nil, .Field_Past_Bound
			}
		}
		return Draw_Text{first = fields.first, count = fields.count, color = Draw_Color(fields.color), origin_x = fields.origin_x, font = font, weight = weight, size = fields.size}, .None
	case .Picture:
		fields := transmute(Picture_Fields)record.fields
		if !all_zero(fields.memory_reserved) || !all_zero(fields.reserved) {
			return nil, .Reserved_Not_Zero
		}
		format, format_ok := picture_format_of_word(fields.format)
		if !format_ok {
			return nil, .Field_Past_Bound
		}
		return Draw_Picture{memory = fields.memory, format = format, first = fields.first, stride = fields.stride, generation = fields.generation}, .None
	case .Text_Grid:
		fields := transmute(Text_Grid_Fields)record.fields
		if !all_zero(fields.reserved) {
			return nil, .Reserved_Not_Zero
		}
		if !text_size_valid(fields.size) {
			return nil, .Field_Past_Bound
		}
		return Draw_Text_Grid{first = fields.first, count = fields.count, columns = fields.columns, size = fields.size}, .None
	case .Path:
		fields := transmute(Path_Fields)record.fields
		if !all_zero(fields.reserved) {
			return nil, .Reserved_Not_Zero
		}
		path := Draw_Path{first = fields.first, count = fields.count, fill_color = Draw_Color(fields.fill_color), stroke_color = Draw_Color(fields.stroke_color), stroke_width = fields.stroke_width}
		if !path_fields_valid(path) {
			return nil, .Field_Past_Bound
		}
		return path, .None
	}
	// The switch above is whole, and each case returns.
	return nil, .Unknown_Kind
}

// record_of writes the record of a primitive in a box, in 1/64 pixel. The
// kind comes from the primitive, so a record never holds the fields of
// another kind, and each byte that the kind does not name is 0. A nil
// primitive is a record of the kind None. The box of a Clip_Pop is the
// box that the caller gives: the border reads one of 0 only.
record_of :: proc "contextless" (primitive: Draw_Primitive, element: u32, left, top, right, bottom: i32) -> Draw_Record {
	record := Draw_Record{element = element, left = left, top = top, right = right, bottom = bottom}
	switch value in primitive {
	case Draw_Nothing:
		record.kind = u8(Draw_Kind.None)
	case Draw_Clip_Push:
		record.kind = u8(Draw_Kind.Clip_Push)
	case Draw_Clip_Pop:
		record.kind = u8(Draw_Kind.Clip_Pop)
	case Draw_Element_Push:
		record.kind = u8(Draw_Kind.Element_Push)
		record.fields = transmute([FIELDS_SIZE]u8)Element_Push_Fields{
			role         = u8(value.role),
			live         = u8(value.live),
			toggle       = u8(value.toggle),
			expanded     = u8(value.expanded),
			states       = transmute(u32)value.states,
			name_first   = value.name_first,
			name_count   = value.name_count,
			detail_first = value.detail_first,
			detail_count = value.detail_count,
		}
	case Draw_Element_Pop:
		record.kind = u8(Draw_Kind.Element_Pop)
	case Draw_Rectangle:
		record.kind = u8(Draw_Kind.Rectangle)
		pattern := value.repetition
		record.fields = transmute([FIELDS_SIZE]u8)Rectangle_Fields{color = u32(value.color), cell_x = pattern.cell_x, cell_y = pattern.cell_y, cell_width = pattern.cell_width, cell_height = pattern.cell_height, step_x = pattern.step_x, step_y = pattern.step_y}
	case Draw_Gradient:
		record.kind = u8(Draw_Kind.Gradient)
		record.fields = transmute([FIELDS_SIZE]u8)Gradient_Fields{start_x = value.start_x, start_y = value.start_y, end_x = value.end_x, end_y = value.end_y, start_color = u32(value.start_color), end_color = u32(value.end_color)}
	case Draw_Text:
		record.kind = u8(Draw_Kind.Text)
		record.fields = transmute([FIELDS_SIZE]u8)Text_Fields{first = value.first, count = value.count, color = u32(value.color), origin_x = value.origin_x, font = u8(value.font), weight = u8(value.weight), size = value.size}
	case Draw_Picture:
		record.kind = u8(Draw_Kind.Picture)
		record.fields = transmute([FIELDS_SIZE]u8)Picture_Fields{memory = value.memory, format = u8(value.format), first = value.first, stride = value.stride, generation = value.generation}
	case Draw_Text_Grid:
		record.kind = u8(Draw_Kind.Text_Grid)
		record.fields = transmute([FIELDS_SIZE]u8)Text_Grid_Fields{first = value.first, count = value.count, columns = value.columns, size = value.size}
	case Draw_Path:
		record.kind = u8(Draw_Kind.Path)
		record.fields = transmute([FIELDS_SIZE]u8)Path_Fields{first = value.first, count = value.count, fill_color = u32(value.fill_color), stroke_color = u32(value.stroke_color), stroke_width = value.stroke_width}
	}
	return record
}

// byte_range_of gives the range of the text table that a primitive names:
// the bytes of a text, the cells of a grid and the points of a path.
// has_range is false for a primitive that names none.
byte_range_of :: proc "contextless" (primitive: Draw_Primitive) -> (first, count: u32, has_range: bool) {
	switch value in primitive {
	case Draw_Text:
		return value.first, value.count, true
	case Draw_Text_Grid:
		return value.first, value.count, true
	case Draw_Path:
		return value.first, value.count, true
	case Draw_Nothing, Draw_Clip_Push, Draw_Clip_Pop, Draw_Element_Push, Draw_Element_Pop, Draw_Rectangle, Draw_Gradient, Draw_Picture:
	}
	return 0, 0, false
}

// with_byte_place gives the primitive with another first byte of its
// range: the difference compares two records with no place in the text
// table, and a caller that appends the text of a frame to another table
// moves each range. A primitive that names no range is the same.
with_byte_place :: proc "contextless" (primitive: Draw_Primitive, first: u32) -> Draw_Primitive {
	switch value in primitive {
	case Draw_Text:
		moved := value
		moved.first = first
		return moved
	case Draw_Text_Grid:
		moved := value
		moved.first = first
		return moved
	case Draw_Path:
		moved := value
		moved.first = first
		return moved
	case Draw_Nothing, Draw_Clip_Push, Draw_Clip_Pop, Draw_Element_Push, Draw_Element_Pop, Draw_Rectangle, Draw_Gradient, Draw_Picture:
	}
	return primitive
}

// pixels_floor gives the whole pixel at or before a place in units.
pixels_floor :: proc "contextless" (place: i32) -> int {
	return int(place) >> UNIT_SHIFT
}

// pixels_ceiling gives the whole pixel at or after a place in units.
pixels_ceiling :: proc "contextless" (place: i32) -> int {
	return (int(place) + UNITS_PER_PIXEL - 1) >> UNIT_SHIFT
}

// units_of_pixels gives a place in pixels in units. The caller keeps the
// place inside COORDINATE_LIMIT, so the product fits an i32.
units_of_pixels :: proc "contextless" (pixels: int) -> i32 {
	return i32(pixels * UNITS_PER_PIXEL)
}

// inside_coordinate_limit says if an edge of a box is inside the limit. A
// comparison, not abs: abs of the smallest i32 is still negative.
inside_coordinate_limit :: proc "contextless" (place: i32) -> bool {
	return place >= -COORDINATE_UNIT_LIMIT && place <= COORDINATE_UNIT_LIMIT
}

// on_whole_pixel says if a place in units is a whole pixel.
on_whole_pixel :: proc "contextless" (place: i32) -> bool {
	return place & (UNITS_PER_PIXEL - 1) == 0
}

// repetition_valid says if the pattern of a Rectangle is in its bounds:
// with both steps at 0, every field of it is 0 (one rectangle, and one form
// of its bytes); else both steps, the cell and its place are whole pixels,
// the cell is at least 1 pixel and at most a step on each axis, and its
// place is inside COORDINATE_LIMIT. So the cells never overlap, and a
// pattern reaches each pixel of its box at most once: its cost is bounded by
// the pixels of its box.
repetition_valid :: proc "contextless" (pattern: Repetition) -> bool {
	if pattern.step_x == 0 && pattern.step_y == 0 {
		return pattern == Repetition{}
	}
	sizes := [4]u16{pattern.cell_width, pattern.cell_height, pattern.step_x, pattern.step_y}
	for size in sizes {
		if size < UNITS_PER_PIXEL || !on_whole_pixel(i32(size)) {
			return false
		}
	}
	if pattern.cell_width > pattern.step_x || pattern.cell_height > pattern.step_y {
		return false
	}
	return inside_coordinate_limit(pattern.cell_x) && inside_coordinate_limit(pattern.cell_y) && on_whole_pixel(pattern.cell_x) && on_whole_pixel(pattern.cell_y)
}

// gradient_line_valid says if the two points of a gradient are in their
// bounds: each inside COORDINATE_LIMIT, not equal, and at most
// GRADIENT_SPAN_LIMIT pixels apart on each axis. In 64 bits: two points at
// the two ends of the limit are 2^30 units apart.
gradient_line_valid :: proc "contextless" (gradient: Draw_Gradient) -> bool {
	points := [4]i32{gradient.start_x, gradient.start_y, gradient.end_x, gradient.end_y}
	for place in points {
		if !inside_coordinate_limit(place) {
			return false
		}
	}
	span_x := abs(i64(gradient.end_x) - i64(gradient.start_x))
	span_y := abs(i64(gradient.end_y) - i64(gradient.start_y))
	if span_x == 0 && span_y == 0 {
		return false
	}
	return span_x <= GRADIENT_SPAN_LIMIT * UNITS_PER_PIXEL && span_y <= GRADIENT_SPAN_LIMIT * UNITS_PER_PIXEL
}

// GRADIENT_LEVELS is the count of steps from the first color of a gradient
// to the second.
GRADIENT_LEVELS :: 255

// gradient_level gives the level of a place of the surface, in units, on
// the line of a gradient that the border read: 0 at the first point and
// before it, GRADIENT_LEVELS at the second point and past it, and between
// them GRADIENT_LEVELS times the projection over the length, rounded down.
// On an axis, with the points at the centers of the first and the last
// pixel, it gives the level of the line r of h: r * 255 / (h - 1). The
// bounds of the border keep each product inside an i64: a distance of at
// most 2^30 + 2^29 units times a span of at most 2^21, two such terms, and
// GRADIENT_LEVELS.
gradient_level :: proc "contextless" (gradient: Draw_Gradient, x, y: i64) -> u32 {
	direction_x := i64(gradient.end_x) - i64(gradient.start_x)
	direction_y := i64(gradient.end_y) - i64(gradient.start_y)
	along := (x - i64(gradient.start_x)) * direction_x + (y - i64(gradient.start_y)) * direction_y
	length := direction_x * direction_x + direction_y * direction_y
	if along <= 0 {
		return 0
	}
	if along >= length {
		return GRADIENT_LEVELS
	}
	return u32(along * GRADIENT_LEVELS / length)
}

// path_fields_valid says if the fields of a path are in their bounds: a
// range from a multiple of 4 of a whole count of 2 to PATH_POINT_LIMIT
// points, two canonical colors, and a stroke width of 1 unit to
// STROKE_WIDTH_UNIT_LIMIT with a stroke color, 0 without. A path of one
// point draws nothing whatever it holds: it has no segment.
path_fields_valid :: proc "contextless" (path: Draw_Path) -> bool {
	if path.first % 4 != 0 || path.count % PATH_POINT_SIZE != 0 {
		return false
	}
	points := path.count / PATH_POINT_SIZE
	if points < 2 || points > PATH_POINT_LIMIT {
		return false
	}
	if !color_canonical(path.fill_color) || !color_canonical(path.stroke_color) {
		return false
	}
	if (path.stroke_color == 0) != (path.stroke_width == 0) {
		return false
	}
	return path.stroke_width <= STROKE_WIDTH_UNIT_LIMIT
}

// path_points_read is the border of the points of a path. records are the
// points in the text table, which another process can write during the
// call: each is loaded once, and every check reads the copy in points,
// which the caller then draws. It gives the count of points, or the
// problem of the first point that is wrong, in the order of the points:
// a command word that names no member, a point past COORDINATE_LIMIT, a
// Close whose x or y is not 0, a first point that is not a Move, a Move
// with no segment after it, a Curve_Control with no Line after it, and a
// Close that does not follow a Line or that a point other than a Move
// follows. The count comes first: fewer than 2 points, more than
// PATH_POINT_LIMIT, or more than points holds.
//
// So a path that is read starts with a Move, each subpath has a segment,
// each curve has its end, and a Close is the last point of its subpath.
path_points_read :: proc "contextless" (records: []Path_Point_Record, points: []Path_Point) -> (count: int, problem: Path_Problem) {
	if len(points) < len(records) {
		return 0, .Count_Out_Of_Range
	}
	return path_points_walk(records, points)
}

// path_points_check is the border of the points with no copy: a writer
// checks the points that it wrote into its own text table.
path_points_check :: proc "contextless" (records: []Path_Point_Record) -> Path_Problem {
	_, problem := path_points_walk(records, nil)
	return problem
}

// path_points_walk loads each point once and checks it, and writes it into
// points when points holds it.
@(private)
path_points_walk :: proc "contextless" (records: []Path_Point_Record, points: []Path_Point) -> (count: int, problem: Path_Problem) {
	if len(records) < 2 || len(records) > PATH_POINT_LIMIT {
		return 0, .Count_Out_Of_Range
	}
	previous: Path_Command
	for index in 0 ..< len(records) {
		words := intrinsics.volatile_load((^[3]u32)(&records[index]))
		command, known := path_command_of_word(words[0])
		if !known {
			return 0, .Unknown_Command
		}
		x, y := i32(words[1]), i32(words[2])
		if !inside_coordinate_limit(x) || !inside_coordinate_limit(y) {
			return 0, .Point_Past_Coordinate_Limit
		}
		if command == .Close && (x != 0 || y != 0) {
			return 0, .Close_Point_Not_Zero
		}
		if index == 0 {
			if command != .Move {
				return 0, .Not_Started_By_Move
			}
		} else {
			order := path_command_after(previous, command)
			if order != .None {
				return 0, order
			}
		}
		if index < len(points) {
			points[index] = {command = command, x = x, y = y}
		}
		previous = command
	}
	// The last point ends its subpath: a Move and a Curve_Control there have
	// no segment and no end.
	switch previous {
	case .Move:
		return 0, .Empty_Subpath
	case .Curve_Control:
		return 0, .Curve_Without_End
	case .Line, .Close:
	}
	return len(records), .None
}

// path_command_after says if a command can follow another one in a path.
@(private)
path_command_after :: proc "contextless" (previous, command: Path_Command) -> Path_Problem {
	switch previous {
	case .Move:
		if command != .Line && command != .Curve_Control {
			return .Empty_Subpath
		}
	case .Curve_Control:
		if command != .Line {
			return .Curve_Without_End
		}
	case .Close:
		if command != .Move {
			return .Close_Out_Of_Place
		}
	case .Line:
		// After a Line, each command can come; a Close only there.
	}
	if command == .Close && previous != .Line {
		return .Close_Out_Of_Place
	}
	return .None
}

// curve_segment_count gives the count of line segments of a quadratic curve
// from (start_x, start_y) by the control point to (end_x, end_y), in units:
// the fewest, from 1 to CURVE_SEGMENT_LIMIT, whose distance from the curve
// is at most CURVE_TOLERANCE_UNITS. With n segments of equal steps of the
// parameter, that distance is at most |start - 2 * control + end| / (4 * n * n),
// and the sum of the two axes bounds the length of that vector. So a curve
// whose bend (that sum) is at most 4 * CURVE_TOLERANCE_UNITS * 256 units,
// 128 pixels, is within the tolerance; past it, the 16 segments are at most
// bend / 1024 units from the curve. Each place is inside COORDINATE_LIMIT,
// so the bend is below 2^33 and each product fits an i64.
curve_segment_count :: proc "contextless" (start_x, start_y, control_x, control_y, end_x, end_y: i32) -> int {
	bend := abs(i64(start_x) - 2 * i64(control_x) + i64(end_x)) + abs(i64(start_y) - 2 * i64(control_y) + i64(end_y))
	count: i64 = 1
	for count < CURVE_SEGMENT_LIMIT && bend > 4 * CURVE_TOLERANCE_UNITS * count * count {
		count += 1
	}
	return int(count)
}

// curve_point gives the point step of count of a quadratic curve, in units,
// each axis rounded to the nearest unit: step 0 is the start, step count the
// end. Each point comes from the three points of the curve, so no error adds
// up along it, and the points stay inside the box of the three points.
curve_point :: proc "contextless" (start_x, start_y, control_x, control_y, end_x, end_y: i32, step, count: int) -> (x, y: i32) {
	before, after, square := i64(count - step), i64(step), i64(count * count)
	x = i32(divide_rounded(before * before * i64(start_x) + 2 * after * before * i64(control_x) + after * after * i64(end_x), square))
	y = i32(divide_rounded(before * before * i64(start_y) + 2 * after * before * i64(control_y) + after * after * i64(end_y), square))
	return
}

// divide_rounded gives numerator / denominator rounded to the nearest
// integer, a half up, for a denominator above 0 and a numerator of any
// sign: the division rounds toward minus infinity.
divide_rounded :: proc "contextless" (numerator, denominator: i64) -> i64 {
	twice := 2 * numerator + denominator
	quotient := twice / (2 * denominator)
	if twice % (2 * denominator) < 0 {
		quotient -= 1
	}
	return quotient
}

// The parts of a pixel where the origin of a text in the interface font
// can be: the three positions of the glyph cache, a third of a pixel apart,
// as `third * 64 / 3` writes them.
ORIGIN_THIRDS :: [3]i32{0, UNITS_PER_PIXEL / 3, UNITS_PER_PIXEL * 2 / 3}

// text_size_valid says if a text size is from TEXT_SIZE_MINIMUM to
// TEXT_SIZE_LIMIT. The size 0 is refused too: a record has one form for
// each size, so no size has a default word.
text_size_valid :: proc "contextless" (size: u16) -> bool {
	return int(size) >= TEXT_SIZE_MINIMUM && int(size) <= TEXT_SIZE_LIMIT
}

// origin_valid says if the origin of a text is on a third of a pixel, and
// at most the larger of INK_MARGIN_LIMIT pixels and one line of its size,
// and two thirds of a pixel, right of the left edge of its box: the ink
// margin grows with the size. A whole pixel is a third too; the font of
// the cells asks for one. In 64 bits: the edge and the origin can be at
// the two ends of an i32.
origin_valid :: proc "contextless" (origin_x, left: i32, size: u16) -> bool {
	margin := i64(origin_x) - i64(left)
	bound := max(i64(INK_MARGIN_LIMIT) * UNITS_PER_PIXEL, i64(size) & ~i64(UNITS_PER_PIXEL - 1))
	if margin < 0 || margin >= bound + UNITS_PER_PIXEL {
		return false
	}
	part := origin_x & (UNITS_PER_PIXEL - 1)
	thirds := ORIGIN_THIRDS
	for third in thirds {
		if part == third {
			return true
		}
	}
	return false
}

// all_zero says if each byte is 0.
@(private)
all_zero :: proc "contextless" (bytes: [$COUNT]u8) -> bool {
	for value in bytes {
		if value != 0 {
			return false
		}
	}
	return true
}

// color_canonical says if a color of one color is in its one form: a color
// with alpha 0 draws nothing whatever its channels, so it must be 0, and
// two rectangles of alpha 0 with the same pattern keep the same bytes.
color_canonical :: proc "contextless" (color: Draw_Color) -> bool {
	return alpha_of(color) != 0 || color == 0
}

// gradient_colors_canonical says if the two colors of a gradient are in
// their one form. The channels of one end with alpha 0 color the mix with
// the other end, so they stay; two ends with alpha 0 draw nothing, and must
// both be 0.
gradient_colors_canonical :: proc "contextless" (first, second: Draw_Color) -> bool {
	return alpha_of(first) != 0 || alpha_of(second) != 0 || (first == 0 && second == 0)
}

// The order of the clips of a table, as a reader walks its records. The
// pushes past the bound are counted and not held: the records under them
// draw nothing, and each pop ends one of them first. So a reader holds at
// most CLIP_DEPTH_LIMIT clips, and a table that a hostile caller wrote
// never makes a clip wider than the clips that it pushed.
Clip_Order :: struct {
	depth:  int, // The pushes open that a reader holds: 0 to CLIP_DEPTH_LIMIT.
	excess: int, // The pushes open past CLIP_DEPTH_LIMIT, under the deepest one held.
}

// clip_order_push takes a Clip_Push: one depth more, or, at the bound, one
// push more past it, which it refuses.
clip_order_push :: proc "contextless" (order: ^Clip_Order) -> Clip_Order_Problem {
	if order.depth >= CLIP_DEPTH_LIMIT {
		order.excess += 1
		return .Push_Past_Depth_Limit
	}
	order.depth += 1
	return .None
}

// clip_order_pop takes a Clip_Pop: it ends the last push open, a push past
// the bound first. A pop with no push open is refused, and changes nothing.
clip_order_pop :: proc "contextless" (order: ^Clip_Order) -> Clip_Order_Problem {
	switch {
	case order.excess > 0:
		order.excess -= 1
	case order.depth > 0:
		order.depth -= 1
	case:
		return .Pop_Without_Push
	}
	return .None
}

// clip_order_end says if a table that ends in this order leaves a push
// open.
clip_order_end :: proc "contextless" (order: Clip_Order) -> Clip_Order_Problem {
	if order.depth != 0 || order.excess != 0 {
		return .Push_Without_Pop
	}
	return .None
}

// clip_order_check is the border of the order of the clips of a table. It
// loads the kind word of each record once, and gives the first problem in
// the order of the records, with the index of the record: a pop with no
// push open, a push past CLIP_DEPTH_LIMIT, and, for a table that ends with
// a push open, the outermost push open. With no problem the index is 0.
//
// The kind word alone decides: a record whose word is a Clip_Push is a
// push, also when the border of the record refuses its box, so each reader
// of a table walks one order. A word that names no kind is no clip.
clip_order_check :: proc "contextless" (records: []Draw_Record) -> (problem: Clip_Order_Problem, index: int) {
	order: Clip_Order
	outermost := 0
	for place in 0 ..< len(records) {
		kind, known := draw_kind_of_word(intrinsics.volatile_load(&records[place].kind))
		if !known {
			continue
		}
		switch kind {
		case .Clip_Push:
			if order.depth == 0 {
				outermost = place
			}
			if step := clip_order_push(&order); step != .None {
				return step, place
			}
		case .Clip_Pop:
			if step := clip_order_pop(&order); step != .None {
				return step, place
			}
		case .None, .Rectangle, .Text, .Picture, .Text_Grid, .Gradient, .Path, .Element_Push, .Element_Pop:
		}
	}
	if end := clip_order_end(order); end != .None {
		return end, outermost
	}
	return .None, 0
}

