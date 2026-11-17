// The draw record: one thing to draw in the draw table of a frame
// (src/md/api/draw_table.md). The interface package writes the records, and
// the drawing module and the compositor read them, so the form is a
// contract: bytes at stated offsets, with no type of one language in them.
//
// A record is 48 bytes: a header of 24 bytes (the word of the kind, three
// reserved bytes, the element identity and the box), then 24 bytes that
// belong to its kind. Each byte that its kind does not name is 0, so two
// records that draw the same thing have the same bytes, and the damage by
// difference compares bytes.
//
// One border reads a record: `read` takes one copy and gives a
// `Draw_Primitive`, a union with one record type for each kind, or the
// problem that refuses it. The union is the view of the reader past the
// border; the bytes are the contract. `record_of` writes a record from a
// primitive, so the kind of a record always matches its fields.
//
// Places are in units of 1/64 pixel. The kinds of this version draw on
// whole pixels, so the border refuses a box whose edges are not whole
// pixels; the origin of a text in the interface font is the one place
// inside a pixel, on a third of a pixel.
//
// See [draw record](term:draw-record) and [draw table](term:draw-table).
package draw_record

import "modus:contract/enum_word"

// The version of the form of the record. A change of a kind, of a field,
// of a bound that changes what a record draws, or of a rule of the
// execution is a new version, and the names of the exports of the drawing
// module carry it.
VERSION :: 11

RECORD_SIZE :: 48 // The bytes of one record.
HEADER_SIZE :: 24 // The bytes of the header: the kind, the reserved bytes, the element and the box.
FIELDS_SIZE :: 24 // The bytes that belong to the kind of a record.

UNITS_PER_PIXEL :: 64 // The units of a place in one pixel: the unit of the measure of a text.
UNIT_SHIFT :: 6 // log2 of UNITS_PER_PIXEL: a place in units to pixels is a shift.

// The places of a record stay inside this distance of the corner of the
// surface, in pixels. In units, an edge is then inside 2^30, so the
// difference of two edges and the sum of an edge and an ink margin fit an
// i32. A surface is far smaller.
COORDINATE_LIMIT :: 1 << 24
COORDINATE_UNIT_LIMIT :: COORDINATE_LIMIT * UNITS_PER_PIXEL // The same limit in units.

// The largest thickness of a line, in pixels: past it, the squares of a
// long line cost too much to draw again in each damage rectangle.
LINE_THICKNESS_LIMIT :: 32

// The ends of a line stay inside this distance of the corner of the
// surface, in pixels: the drawing walks each point of the path, so a line
// of a billion points would stop the program.
LINE_COORDINATE_LIMIT :: 1 << 15

TEXT_SCALE_LIMIT :: 3 // The largest scale of a text: 1, 2 or 3 times the size of the font.

// The most bytes of one text in the interface font: the execution places
// its glyphs on its stack. A longer text is drawn in the font of the cells.
INTERFACE_TEXT_LIMIT :: 256

// The largest ink margin of a text in the interface font, in pixels: the
// distance from the left edge of its box to its origin. The margin of the
// font at scale 3 is far smaller.
INK_MARGIN_LIMIT :: 16

// What one draw record draws. The values cross the border of the drawing
// module, so they are stated.
Draw_Kind :: enum u8 {
	None                = 0, // Nothing.
	Rectangle           = 1, // The box in one color.
	Vertical_Gradient   = 2, // The box from a color on its top line to a color on its bottom line.
	Horizontal_Gradient = 3, // The box from a color on its left column to a color on its right column.
	Text                = 4, // A text in the font of the cells, at the top left corner of the box.
	Clip                = 5, // The next records are cut to the box; a box of no width ends the cut.
	Point_Grid          = 6, // The grid of points of the background (docs/DESIGN.md, "3. Surfaces").
	Folded_Gap          = 7, // A part with no measure on its scale: a track with two lines at an angle.
	Picture             = 8, // The pixels of a picture of the caller, by values in a picture memory.
	Text_Grid           = 9, // A grid of text cells, copied into the text table.
	Line                = 10, // A straight line between two whole pixels, with a thickness.
	Interface_Text      = 11, // A text in the interface font, with its origin on a third of a pixel.
}

// The weight of a text. Bold draws at scale 1 only (the titles of the
// cards); at another scale, and with Spleen 8x16, it is the regular weight.
Font_Weight :: enum u8 {
	Regular = 0, // The normal weight.
	Bold    = 1, // The bold weight: at scale 1 only.
}

// Why the border refuses a record.
Problem :: enum u8 {
	None                      = 0, // The record is read.
	Unknown_Kind              = 1, // The word of the kind names no member of Draw_Kind.
	Reserved_Not_Zero         = 2, // A reserved byte of the header, or a byte that the kind does not name, is not 0.
	Box_Inverted              = 3, // The right edge of the box is left of its left edge, or its bottom above its top.
	Box_Past_Coordinate_Limit = 4, // An edge of the box is past COORDINATE_LIMIT.
	Box_Not_On_Whole_Pixels   = 5, // An edge of the box is not a whole pixel: no kind of this version draws inside a pixel.
	Field_Past_Bound          = 6, // A field of the kind is out of its range: a scale, a weight, a thickness, an end of a line, a count, an origin.
}

// One draw record, 48 bytes, little-endian. A record holds values only:
// no address, so it means the same in each address space, and a GPU can
// read it.
//
// Example: `record_of(Draw_Rectangle{color = 0x00102030}, 0, 0, 0, 640, 1536)`
// is a rectangle of 10 by 24 pixels at the corner of the surface.
Draw_Record :: struct {
	kind:     u8, // The word of the kind: draw_kind_of_word gives its Draw_Kind.
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
// of a record. A kind with no field (None, Clip) has 24 bytes of 0.

// The fields of a Rectangle.
Rectangle_Fields :: struct {
	color:    u32, // 0x00RRGGBB.
	reserved: [20]u8, // 0.
}

// The fields of a Vertical_Gradient.
Vertical_Gradient_Fields :: struct {
	top_color:    u32, // 0x00RRGGBB: the color of the top line.
	bottom_color: u32, // 0x00RRGGBB: the color of the bottom line.
	reserved:     [16]u8, // 0.
}

// The fields of a Horizontal_Gradient.
Horizontal_Gradient_Fields :: struct {
	left_color:  u32, // 0x00RRGGBB: the color of the left column.
	right_color: u32, // 0x00RRGGBB: the color of the right column.
	reserved:    [16]u8, // 0.
}

// The fields of a Text in the font of the cells.
Text_Fields :: struct {
	first:    u32, // The first byte of the text in the text table.
	count:    u32, // The bytes of the text.
	color:    u32, // 0x00RRGGBB.
	scale:    u8, // 1 to TEXT_SCALE_LIMIT.
	weight:   u8, // The word of a Font_Weight.
	reserved: [10]u8, // 0.
}

// The fields of a Point_Grid.
Point_Grid_Fields :: struct {
	color:    u32, // 0x00RRGGBB: the color of the points.
	reserved: [20]u8, // 0.
}

// The fields of a Folded_Gap.
Folded_Gap_Fields :: struct {
	line_color:  u32, // 0x00RRGGBB: the color of the two lines at an angle.
	track_color: u32, // 0x00RRGGBB: the color of the track under them.
	reserved:    [16]u8, // 0.
}

// The fields of a Picture. Its size is the size of the box.
Picture_Fields :: struct {
	memory:          u8, // The number of its picture memory in the list of the draw table.
	memory_reserved: [3]u8, // 0.
	first:           u32, // The index of its first pixel in that memory.
	stride:          u32, // The pixels from one line to the next.
	generation:      u32, // A new number when its pixels change: the difference sees the change.
	reserved:        [8]u8, // 0.
}

// The fields of a Text_Grid. The cells are in the text table, 16 bytes each.
Text_Grid_Fields :: struct {
	first:    u32, // The first byte of the cells in the text table, a multiple of 4.
	count:    u32, // The bytes of the cells: rows times columns times 16.
	columns:  u32, // The cells of one row.
	reserved: [12]u8, // 0.
}

// The fields of a Line. The box holds each square of its path.
Line_Fields :: struct {
	start_x:   i32, // The first end, in 1/64 pixel: a whole pixel.
	start_y:   i32,
	end_x:     i32, // The second end, in 1/64 pixel: a whole pixel.
	end_y:     i32,
	color:     u32, // 0x00RRGGBB.
	thickness: u8, // The side of the square drawn at each point of the path, 1 to LINE_THICKNESS_LIMIT pixels.
	reserved:  [3]u8, // 0.
}

// The fields of an Interface_Text. The box holds every pixel of its ink:
// the box of its measure grown by its ink margin on each side.
Interface_Text_Fields :: struct {
	first:    u32, // The first byte of the text in the text table.
	count:    u32, // The bytes of the text: at most INTERFACE_TEXT_LIMIT.
	color:    u32, // 0x00RRGGBB.
	origin_x: i32, // The origin of the text, in 1/64 pixel: on a third of a pixel, at most INK_MARGIN_LIMIT pixels right of the left edge of the box.
	scale:    u8, // 1 to TEXT_SCALE_LIMIT.
	weight:   u8, // The word of a Font_Weight.
	reserved: [6]u8, // 0.
}

#assert(size_of(Rectangle_Fields) == FIELDS_SIZE)
#assert(size_of(Vertical_Gradient_Fields) == FIELDS_SIZE)
#assert(size_of(Horizontal_Gradient_Fields) == FIELDS_SIZE)
#assert(size_of(Text_Fields) == FIELDS_SIZE)
#assert(size_of(Point_Grid_Fields) == FIELDS_SIZE)
#assert(size_of(Folded_Gap_Fields) == FIELDS_SIZE)
#assert(size_of(Picture_Fields) == FIELDS_SIZE)
#assert(size_of(Text_Grid_Fields) == FIELDS_SIZE)
#assert(size_of(Line_Fields) == FIELDS_SIZE)
#assert(size_of(Interface_Text_Fields) == FIELDS_SIZE)

// The primitives: what a record draws, as the reader sees it past the
// border. Each has the fields of its kind only, with the words of the
// record as their enums. The box stays in the record.
Draw_Nothing :: struct {}
Draw_Rectangle :: struct {
	color: u32,
}
Draw_Vertical_Gradient :: struct {
	top_color, bottom_color: u32,
}
Draw_Horizontal_Gradient :: struct {
	left_color, right_color: u32,
}
Draw_Text :: struct {
	first, count, color: u32,
	scale:               u8,
	weight:              Font_Weight,
}
Draw_Clip :: struct {}
Draw_Point_Grid :: struct {
	color: u32,
}
Draw_Folded_Gap :: struct {
	line_color, track_color: u32,
}
Draw_Picture :: struct {
	memory:                    u8,
	first, stride, generation: u32,
}
Draw_Text_Grid :: struct {
	first, count, columns: u32,
}
Draw_Line :: struct {
	start_x, start_y, end_x, end_y: i32, // In 1/64 pixel.
	color:                          u32,
	thickness:                      u8,
}
Draw_Interface_Text :: struct {
	first, count, color: u32,
	origin_x:            i32, // In 1/64 pixel.
	scale:               u8,
	weight:              Font_Weight,
}

// One primitive of each kind. A record that `read` accepts is never nil:
// a record of the kind None is a Draw_Nothing.
Draw_Primitive :: union {
	Draw_Nothing,
	Draw_Rectangle,
	Draw_Vertical_Gradient,
	Draw_Horizontal_Gradient,
	Draw_Text,
	Draw_Clip,
	Draw_Point_Grid,
	Draw_Folded_Gap,
	Draw_Picture,
	Draw_Text_Grid,
	Draw_Line,
	Draw_Interface_Text,
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

// read is the border of a draw record. It takes the one copy of a record
// that the caller read, and gives the primitive that it draws, or the
// problem that refuses it: a word of a kind that names no member, a
// reserved byte or a byte that the kind does not name that is not 0, a box
// whose right is left of its left or whose bottom is above its top, an
// edge past COORDINATE_LIMIT or not on a whole pixel, and a field of the
// kind out of its range. A refused record draws nothing.
//
// The checks are on the record alone. What a record names in the tables of
// its frame (a range of the text table, the pixels of a picture memory) is
// checked where the table is: the record does not hold it.
read :: proc "contextless" (record: Draw_Record) -> (primitive: Draw_Primitive, problem: Problem) {
	copied := record
	kind, known := draw_kind_of_word(copied.kind)
	if !known {
		return nil, .Unknown_Kind
	}
	if !all_zero(copied.reserved[:]) {
		return nil, .Reserved_Not_Zero
	}
	if !inside_coordinate_limit(copied.left) || !inside_coordinate_limit(copied.top) || !inside_coordinate_limit(copied.right) || !inside_coordinate_limit(copied.bottom) {
		return nil, .Box_Past_Coordinate_Limit
	}
	if copied.right < copied.left || copied.bottom < copied.top {
		return nil, .Box_Inverted
	}
	if !on_whole_pixel(copied.left) || !on_whole_pixel(copied.top) || !on_whole_pixel(copied.right) || !on_whole_pixel(copied.bottom) {
		return nil, .Box_Not_On_Whole_Pixels
	}
	switch kind {
	case .None:
		if !all_zero(copied.fields[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Nothing{}, .None
	case .Clip:
		if !all_zero(copied.fields[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Clip{}, .None
	case .Rectangle:
		fields := transmute(Rectangle_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Rectangle{color = fields.color}, .None
	case .Vertical_Gradient:
		fields := transmute(Vertical_Gradient_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Vertical_Gradient{top_color = fields.top_color, bottom_color = fields.bottom_color}, .None
	case .Horizontal_Gradient:
		fields := transmute(Horizontal_Gradient_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Horizontal_Gradient{left_color = fields.left_color, right_color = fields.right_color}, .None
	case .Point_Grid:
		fields := transmute(Point_Grid_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Point_Grid{color = fields.color}, .None
	case .Folded_Gap:
		fields := transmute(Folded_Gap_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Folded_Gap{line_color = fields.line_color, track_color = fields.track_color}, .None
	case .Text:
		fields := transmute(Text_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		weight, weight_ok := font_weight_of_word(fields.weight)
		if !weight_ok || fields.scale < 1 || fields.scale > TEXT_SCALE_LIMIT {
			return nil, .Field_Past_Bound
		}
		return Draw_Text{first = fields.first, count = fields.count, color = fields.color, scale = fields.scale, weight = weight}, .None
	case .Picture:
		fields := transmute(Picture_Fields)copied.fields
		if !all_zero(fields.memory_reserved[:]) || !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Picture{memory = fields.memory, first = fields.first, stride = fields.stride, generation = fields.generation}, .None
	case .Text_Grid:
		fields := transmute(Text_Grid_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		return Draw_Text_Grid{first = fields.first, count = fields.count, columns = fields.columns}, .None
	case .Line:
		fields := transmute(Line_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		if fields.thickness < 1 || fields.thickness > LINE_THICKNESS_LIMIT || !line_end_valid(fields.start_x) || !line_end_valid(fields.start_y) || !line_end_valid(fields.end_x) || !line_end_valid(fields.end_y) {
			return nil, .Field_Past_Bound
		}
		return Draw_Line{start_x = fields.start_x, start_y = fields.start_y, end_x = fields.end_x, end_y = fields.end_y, color = fields.color, thickness = fields.thickness}, .None
	case .Interface_Text:
		fields := transmute(Interface_Text_Fields)copied.fields
		if !all_zero(fields.reserved[:]) {
			return nil, .Reserved_Not_Zero
		}
		weight, weight_ok := font_weight_of_word(fields.weight)
		if !weight_ok || fields.scale < 1 || fields.scale > TEXT_SCALE_LIMIT || fields.count > INTERFACE_TEXT_LIMIT || !origin_valid(fields.origin_x, copied.left) {
			return nil, .Field_Past_Bound
		}
		return Draw_Interface_Text{first = fields.first, count = fields.count, color = fields.color, origin_x = fields.origin_x, scale = fields.scale, weight = weight}, .None
	}
	// The switch above is whole, and each case returns.
	return nil, .Unknown_Kind
}

// record_of writes the record of a primitive in a box, in 1/64 pixel. The
// kind comes from the primitive, so a record never holds the fields of
// another kind, and each byte that the kind does not name is 0. A nil
// primitive is a record of the kind None.
record_of :: proc "contextless" (primitive: Draw_Primitive, element: u32, left, top, right, bottom: i32) -> Draw_Record {
	record := Draw_Record{element = element, left = left, top = top, right = right, bottom = bottom}
	switch value in primitive {
	case Draw_Nothing:
		record.kind = u8(Draw_Kind.None)
	case Draw_Clip:
		record.kind = u8(Draw_Kind.Clip)
	case Draw_Rectangle:
		record.kind = u8(Draw_Kind.Rectangle)
		record.fields = transmute([FIELDS_SIZE]u8)Rectangle_Fields{color = value.color}
	case Draw_Vertical_Gradient:
		record.kind = u8(Draw_Kind.Vertical_Gradient)
		record.fields = transmute([FIELDS_SIZE]u8)Vertical_Gradient_Fields{top_color = value.top_color, bottom_color = value.bottom_color}
	case Draw_Horizontal_Gradient:
		record.kind = u8(Draw_Kind.Horizontal_Gradient)
		record.fields = transmute([FIELDS_SIZE]u8)Horizontal_Gradient_Fields{left_color = value.left_color, right_color = value.right_color}
	case Draw_Point_Grid:
		record.kind = u8(Draw_Kind.Point_Grid)
		record.fields = transmute([FIELDS_SIZE]u8)Point_Grid_Fields{color = value.color}
	case Draw_Folded_Gap:
		record.kind = u8(Draw_Kind.Folded_Gap)
		record.fields = transmute([FIELDS_SIZE]u8)Folded_Gap_Fields{line_color = value.line_color, track_color = value.track_color}
	case Draw_Text:
		record.kind = u8(Draw_Kind.Text)
		record.fields = transmute([FIELDS_SIZE]u8)Text_Fields{first = value.first, count = value.count, color = value.color, scale = value.scale, weight = u8(value.weight)}
	case Draw_Picture:
		record.kind = u8(Draw_Kind.Picture)
		record.fields = transmute([FIELDS_SIZE]u8)Picture_Fields{memory = value.memory, first = value.first, stride = value.stride, generation = value.generation}
	case Draw_Text_Grid:
		record.kind = u8(Draw_Kind.Text_Grid)
		record.fields = transmute([FIELDS_SIZE]u8)Text_Grid_Fields{first = value.first, count = value.count, columns = value.columns}
	case Draw_Line:
		record.kind = u8(Draw_Kind.Line)
		record.fields = transmute([FIELDS_SIZE]u8)Line_Fields{start_x = value.start_x, start_y = value.start_y, end_x = value.end_x, end_y = value.end_y, color = value.color, thickness = value.thickness}
	case Draw_Interface_Text:
		record.kind = u8(Draw_Kind.Interface_Text)
		record.fields = transmute([FIELDS_SIZE]u8)Interface_Text_Fields{first = value.first, count = value.count, color = value.color, origin_x = value.origin_x, scale = value.scale, weight = u8(value.weight)}
	}
	return record
}

// byte_range_of gives the range of the text table that a primitive names:
// the bytes of a text and the cells of a grid. has_range is false for a
// primitive that names none.
byte_range_of :: proc "contextless" (primitive: Draw_Primitive) -> (first, count: u32, has_range: bool) {
	switch value in primitive {
	case Draw_Text:
		return value.first, value.count, true
	case Draw_Interface_Text:
		return value.first, value.count, true
	case Draw_Text_Grid:
		return value.first, value.count, true
	case Draw_Nothing, Draw_Clip, Draw_Rectangle, Draw_Vertical_Gradient, Draw_Horizontal_Gradient, Draw_Point_Grid, Draw_Folded_Gap, Draw_Picture, Draw_Line:
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
	case Draw_Interface_Text:
		moved := value
		moved.first = first
		return moved
	case Draw_Text_Grid:
		moved := value
		moved.first = first
		return moved
	case Draw_Nothing, Draw_Clip, Draw_Rectangle, Draw_Vertical_Gradient, Draw_Horizontal_Gradient, Draw_Point_Grid, Draw_Folded_Gap, Draw_Picture, Draw_Line:
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

// line_end_valid says if a coordinate can be an end of a line: a whole
// pixel inside LINE_COORDINATE_LIMIT.
line_end_valid :: proc "contextless" (place: i32) -> bool {
	return on_whole_pixel(place) && place >= -LINE_COORDINATE_LIMIT * UNITS_PER_PIXEL && place <= LINE_COORDINATE_LIMIT * UNITS_PER_PIXEL
}

// The parts of a pixel where the origin of a text in the interface font
// can be: the three positions of the glyph cache, a third of a pixel apart,
// as `third * 64 / 3` writes them.
ORIGIN_THIRDS :: [3]i32{0, UNITS_PER_PIXEL / 3, UNITS_PER_PIXEL * 2 / 3}

// origin_valid says if the origin of a text in the interface font is on a
// third of a pixel, and at most INK_MARGIN_LIMIT pixels and two thirds
// right of the left edge of its box. In 64 bits: the edge and the origin
// can be at the two ends of an i32.
origin_valid :: proc "contextless" (origin_x, left: i32) -> bool {
	margin := i64(origin_x) - i64(left)
	if margin < 0 || margin >= i64(INK_MARGIN_LIMIT + 1) * UNITS_PER_PIXEL {
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
all_zero :: proc "contextless" (bytes: []u8) -> bool {
	for value in bytes {
		if value != 0 {
			return false
		}
	}
	return true
}
