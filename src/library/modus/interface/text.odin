package interface

import "modus:contract/draw_record"
import "modus:contract/scale_factor"
import "modus:contract/text_encoding"
import "modus:graphics"
import "modus:text_rendering"

// The fonts that the package can measure (docs/FONTS.md, section 12.6).
// Cells_8x16: the grid of the font of the cells, 8 x 16 pixels at scale 1;
// the vector font of the system and Spleen 8x16 both draw on it, as the
// setting `font` chooses. Interface: the proportional font of the
// names, titles, labels, buttons and lists (B612), when the process has it
// (Draw_Table.interface_font) and the setting is the vector font; else a
// text of this kind is measured and drawn in the font of the cells. A text
// is always measured in the font that will draw it. The font is a field of
// a text record: the type is the one of the contract.
Font_Kind :: draw_record.Font_Kind

// A font and a text size (docs/DESIGN.md, "5. Text").
Font :: struct {
	kind:   Font_Kind, // Which font.
	size:   u16, // The text size in 1/64 pixel, a text size token times TEXT_SIZE_UNITS; 0 is the size of the body, graphics.TEXT_BODY.
	weight: Font_Weight, // Regular or bold.
}

// The weight of a text, a field of a text record: Regular or Bold, at each
// size. With Spleen 8x16 it is the regular weight. In the font of the cells
// the width does not change: the cells are the same. In the interface font
// the bold weight has its own advances.
Font_Weight :: draw_record.Font_Weight

// The units of a text size in one logical pixel: a text size token times it
// is the size of a Font.
TEXT_SIZE_UNITS :: draw_record.UNITS_PER_PIXEL

FONT_BOLD :: Font{weight = .Bold} // The font of the cells, bold.

// The fonts of the text size tokens (docs/DESIGN.md, "5. Text"). A number
// is a value: it is in the font of the cells.
FONT_LARGE :: Font{size = graphics.TEXT_LARGE * TEXT_SIZE_UNITS} // The one number of a card.
FONT_LARGEST :: Font{size = graphics.TEXT_LARGEST * TEXT_SIZE_UNITS} // The one number that a whole window or panel is about.

// The interface font: the names, the labels, the buttons, the lists; its
// bold weight: the titles of the cards.
FONT_INTERFACE :: Font{kind = .Interface}
FONT_INTERFACE_BOLD :: Font{kind = .Interface, weight = .Bold}

// A caption: the caption of a card, a label under a value, the help line
// under an element. FONT_CAPTION_CELLS is a value at the caption size: the
// hash prefix after a nickname.
FONT_CAPTION :: Font{kind = .Interface, size = graphics.TEXT_CAPTION * TEXT_SIZE_UNITS}
FONT_CAPTION_CELLS :: Font{size = graphics.TEXT_CAPTION * TEXT_SIZE_UNITS}

// A heading: the title of a page.
FONT_HEADING :: Font{kind = .Interface, size = graphics.TEXT_HEADING * TEXT_SIZE_UNITS}

// The most bytes of one text in the interface font: the execution places
// its glyphs on its stack. A longer text is drawn in the font of the cells.
INTERFACE_TEXT_LIMIT :: draw_record.INTERFACE_TEXT_LIMIT
// The largest ink margin of a record at a line of 16 pixels or less, in
// pixels; past it the bound is one line (draw_record.origin_valid).
INK_MARGIN_LIMIT :: draw_record.INK_MARGIN_LIMIT

// font_text_size gives the text size of a font, in 1/64 pixel: the size of
// the body for 0. A size out of the bounds of the record is given as it is:
// no text of it is written (font_size_valid), never a text of another size.
font_text_size :: proc "contextless" (font: Font) -> int {
	if font.size == 0 {
		return graphics.TEXT_BODY * TEXT_SIZE_UNITS
	}
	return int(font.size)
}

// The border of the record takes the logical sizes whose size on the screen
// the rasterizer draws at each scale: its largest size is the largest of
// the rasterizer at the largest scale, 2. The least size is the same.
#assert(text_rendering.TEXT_SIZE_MINIMUM == draw_record.TEXT_SIZE_MINIMUM)
#assert(draw_record.TEXT_SIZE_LIMIT * int(scale_factor.Scale.Sixteen_Eighths) / scale_factor.EIGHTHS_OF_ONE == text_rendering.TEXT_SIZE_LIMIT)

// font_size_valid says if the text size of a font is one that a record
// holds: from draw_record.TEXT_SIZE_MINIMUM to draw_record.TEXT_SIZE_LIMIT.
// The writer refuses what the border refuses, also a size that the measure
// would take.
font_size_valid :: proc "contextless" (font: Font) -> bool {
	size := font_text_size(font)
	return size <= draw_record.TEXT_SIZE_LIMIT && text_rendering.size_check(size) == .None
}

// text_size_of_scale gives the text size of a whole scale of the body: 2 is
// a line of 32 pixels. A caller that sizes its text by a count of the body
// gives it here; a scale whose size passes the u16 of a record gives the
// largest u16, which no record holds.
text_size_of_scale :: proc "contextless" (scale: int) -> u16 {
	size := scale * graphics.TEXT_BODY * TEXT_SIZE_UNITS
	if size < 0 || size > int(max(u16)) {
		return max(u16)
	}
	return u16(size)
}

// cell_width_of gives the width of one cell of the font of the cells at the
// text size of a font, in pixels: half the line, a half up
// (text_rendering.cell_columns). The cells of a text grid have it too.
cell_width_of :: proc "contextless" (font: Font) -> int {
	return text_rendering.cell_columns(font_text_size(font))
}

// ink_margin_of gives the ink margin of a text of the interface font at the
// text size of a font, in pixels: graphics.PROPORTIONAL_INK_MARGIN at a line
// of 16 pixels, grown with the size and rounded up. It stays inside the
// bound of the origin of the record: at most one line past 16 pixels.
ink_margin_of :: proc "contextless" (font: Font) -> int {
	LINE_OF_THE_MARGIN :: text_rendering.TEXT_SIZE_OF_SCALE_ONE
	return (graphics.PROPORTIONAL_INK_MARGIN * font_text_size(font) + LINE_OF_THE_MARGIN - 1) / LINE_OF_THE_MARGIN
}

// font_in_use gives the font that draws a text of a table: an Interface
// text is in the font of the cells when the table has no interface font,
// when the setting of the owner is Spleen 8x16, or when the text is longer
// than INTERFACE_TEXT_LIMIT.
font_in_use :: proc "contextless" (table: ^Draw_Table, font: Font, text_length: int) -> Font {
	used := font
	if used.kind == .Interface && (table == nil || table.interface_font == nil || graphics.text_state.font != .Vector || text_length > INTERFACE_TEXT_LIMIT) {
		used.kind = .Cells_8x16
	}
	return used
}

// interface_face_of gives the face of the interface font that draws a
// weight, at each size.
interface_face_of :: proc "contextless" (font: Font) -> text_rendering.Face {
	if font.weight == .Bold {
		return .Interface_Bold
	}
	return .Interface
}

// interface_spacing_of gives the spacing of the interface font of a weight
// at the text size of a font, measured from its font file. ok is false
// when this process has not opened that face, and for a size that
// text_rendering.size_check refuses.
interface_spacing_of :: proc "contextless" (font: Font) -> (spacing: text_rendering.Spacing, ok: bool) {
	return text_rendering.spacing_of(interface_face_of(font), font_text_size(font))
}

// interface_width_subpixels gives the width of a text in the interface
// font, in 1/64 of a pixel: the sum of the advances of its placed glyphs.
// 0 when the process has not opened the face.
interface_width_subpixels :: proc "contextless" (font: Font, text: string) -> i64 {
	spacing, ok := interface_spacing_of(font)
	if !ok {
		return 0
	}
	width, _ := text_rendering.text_width(&spacing, transmute([]u8)text)
	return width
}

// text_width gives the width of a text in pixels, in the font of the cells:
// one cell for each character of the UTF-8 text, and one for each invalid sequence.
text_width :: proc "contextless" (font: Font, text: string) -> int {
	return text_encoding.character_count(transmute([]u8)text) * cell_width_of(font)
}

// text_measured_width gives the width of a text in pixels, in the font that the
// table draws it in: in the interface font, the measure rounded up to a
// whole pixel. measured_size is its form for a layout.
text_measured_width :: proc "contextless" (table: ^Draw_Table, font: Font, text: string) -> int {
	used := font_in_use(table, font, len(text))
	if used.kind == .Interface {
		return int((interface_width_subpixels(used, text) + 63) / 64)
	}
	return text_width(used, text)
}

// texts_measure gives the width of each text of a list, in one call: the
// spacing of the font is found once (the rows of a list).
texts_measure :: proc "contextless" (table: ^Draw_Table, font: Font, texts: []string, widths: []int) {
	count := min(len(texts), len(widths))
	used := font_in_use(table, font, 0)
	if used.kind != .Interface {
		for index in 0 ..< count {
			widths[index] = text_width(used, texts[index])
		}
		return
	}
	spacing, ok := interface_spacing_of(used)
	for index in 0 ..< count {
		if !ok || len(texts[index]) > INTERFACE_TEXT_LIMIT {
			widths[index] = text_width({size = used.size}, texts[index])
			continue
		}
		width, _ := text_rendering.text_width(&spacing, transmute([]u8)texts[index])
		widths[index] = int((width + 63) / 64)
	}
}

// measured_size gives the width of a text in the font that the table draws it
// in: the size of a column of a row (row_split) that holds the text. A
// column is as wide as its text, with no round up.
measured_size :: proc "contextless" (table: ^Draw_Table, font: Font, text: string) -> Size {
	return pixels(text_measured_width(table, font, text))
}

// text_fit gives the longest start of a text whose width, in the font that
// the table draws it in, is at most room: an element cuts a text to its
// box, so no text passes it in either font. A search over the length, each
// candidate measured; the start that it gives is measured, so it fits.
text_fit :: proc "contextless" (table: ^Draw_Table, font: Font, text: string, room: int) -> string {
	if room <= 0 {
		return text[:0]
	}
	if text_measured_width(table, font, text) <= room {
		return text
	}
	low, high := 0, len(text) // text[:low] fits; text[:high] does not.
	for high - low > 1 {
		middle := low + (high - low) / 2
		if text_measured_width(table, font, text[:middle]) <= room {
			low = middle
		} else {
			high = middle
		}
	}
	// The start ends after a whole character: a cut inside one would draw
	// an invalid sequence.
	return text[:text_encoding.complete_characters(transmute([]u8)text[:low])]
}

// The rule of a text that is longer than its box (docs/INTERFACE.md, "The
// text in a box"): the text goes on more lines inside the width of the box,
// and the caller gives the box the height of its lines, or scrolls. No
// procedure below drops a byte: the lines of a text, joined, are the text
// without the spaces at a break. text_fit, above, is for a name whose whole
// form the reader has at another place.

// text_wrap_line gives the first line of a text in a box of `room` pixels,
// and the text after it, by the rule of text_rendering.line_break: the line
// ends at the last space that fits, a word wider than the box ends a line
// after its last `/`, `:` or `_` that fits, and a line has at least one
// whole character. The text is measured in the font that the table draws
// it in (font_in_use); a line longer than INTERFACE_TEXT_LIMIT is drawn in
// the font of the cells, so it is measured in it.
text_wrap_line :: proc "contextless" (table: ^Draw_Table, font: Font, text: string, room: int) -> (line: string, rest: string) {
	used := font_in_use(table, font, 0)
	cells := text_rendering.cell_spacing(cell_width_of(used))
	spacing := cells
	if used.kind == .Interface {
		if interface_spacing, ok := interface_spacing_of(used); ok {
			spacing = interface_spacing
		}
	}
	bytes := transmute([]u8)text
	room_subpixels := i64(room) * text_rendering.SUBPIXEL
	end, start := text_rendering.line_break(&spacing, bytes, room_subpixels)
	if used.kind == .Interface && end > INTERFACE_TEXT_LIMIT {
		end, start = text_rendering.line_break(&cells, bytes, room_subpixels)
	}
	return text[:end], text[start:]
}

// text_wrapped_line_count gives the count of lines of a text in a box of
// `room` pixels, by the rule of text_wrap_line: 0 for an empty text. The
// height of the box of the text is this count times line_height.
text_wrapped_line_count :: proc "contextless" (table: ^Draw_Table, font: Font, text: string, room: int) -> (count: int) {
	rest := text
	for len(rest) > 0 {
		_, rest = text_wrap_line(table, font, rest, room)
		count += 1
	}
	return count
}

// draw_text_wrapped appends a text in a box of `room` pixels whose top left
// corner is (x, y): each line of text_wrap_line, one line_height under the
// line before. It gives the count of lines, which is the count of
// text_wrapped_line_count for the same text, font and room: the caller
// places what follows under them.
draw_text_wrapped :: proc "contextless" (table: ^Draw_Table, x, y, room: int, text: string, color: graphics.Color, font: Font = {}, element: u32 = 0) -> (count: int) {
	rest := text
	for len(rest) > 0 {
		line: string
		line, rest = text_wrap_line(table, font, rest, room)
		draw_text(table, x, y + count * line_height(font), line, color, font, element)
		count += 1
	}
	return count
}

// line_height gives the height of a line of a font, in pixels: two widths
// of a cell at its text size, so both fonts draw in one line, a whole count
// of pixels that holds the line of the size. At an even count of pixels it
// is the size: 16 for the body.
line_height :: proc "contextless" (font: Font) -> int {
	return 2 * cell_width_of(font)
}

// baseline_of_font gives the row of the baseline of a text of a font, from
// the top of its line, in the font that the table draws it in
// (font_in_use): the row of the face of the vector font that draws it.
// With Spleen, or with no face open, it is three quarters of the line, the
// baseline of Spleen 8x16 at the body (row 12 of 16).
baseline_of_font :: proc "contextless" (table: ^Draw_Table, font: Font) -> int {
	used := font_in_use(table, font, 0)
	face := text_rendering.Face.None
	if graphics.text_state.font == .Vector {
		switch used.kind {
		case .Interface:
			face = interface_face_of(used)
		case .Cells_8x16:
			face = graphics.text_state.cell_face
			if used.weight == .Bold && graphics.text_state.bold_face != .None {
				face = graphics.text_state.bold_face
			}
		}
	}
	if row, ok := text_rendering.baseline_row(face, font_text_size(used)); ok {
		return row
	}
	return 3 * line_height(used) / 4
}

// text_top_on_baseline gives the top of the line of a text of a font whose
// baseline is the baseline of a line of line_font with its top at
// line_top: two text sizes on one line, as the title of a card and its
// caption. The baseline is a row of whole pixels at each size, so the two
// texts share it exactly.
text_top_on_baseline :: proc "contextless" (table: ^Draw_Table, line_font: Font, line_top: int, font: Font) -> int {
	return line_top + baseline_of_font(table, line_font) - baseline_of_font(table, font)
}

// A short text that a caller builds from parts, in its own memory.
//
// ```odin
// builder: interface.Text_Builder
// interface.text_put(&builder, "pages: ")
// interface.text_put_number(&builder, pages)
// interface.draw_text(frame.table, x, y, interface.text_of(&builder), color)
// ```
Text_Builder :: struct {
	bytes: [128]u8, // The text.
	count: int, // The bytes in use.
}

// text_put adds a text to a builder. The characters that do not fit in its
// 128 bytes are dropped, never a part of one.
text_put :: proc "contextless" (builder: ^Text_Builder, part: string) {
	count := min(len(part), len(builder.bytes) - builder.count)
	if count < len(part) {
		count = text_encoding.complete_characters(transmute([]u8)part[:count])
	}
	copy(builder.bytes[builder.count:], part[:count])
	builder.count += count
}

// text_put_number adds a number in decimal, with at least minimum_digits digits.
text_put_number :: proc "contextless" (builder: ^Text_Builder, value: u64, minimum_digits := 1) {
	digits: [20]u8
	count := 0
	least := min(minimum_digits, len(digits)) // A u64 has 20 digits at most.
	for rest := value; rest != 0 || count < least; rest /= 10 {
		digits[len(digits) - 1 - count] = u8('0' + rest % 10)
		count += 1
	}
	text_put(builder, string(digits[len(digits) - count:]))
}

// text_of gives the text of a builder. It is valid while the builder is.
text_of :: proc "contextless" (builder: ^Text_Builder) -> string {
	return string(builder.bytes[:builder.count])
}

// number_text writes a number into a builder that the caller gives, and
// gives the text.
number_text :: proc "contextless" (builder: ^Text_Builder, value: u64, minimum_digits := 1) -> string {
	builder.count = 0
	text_put_number(builder, value, minimum_digits)
	return text_of(builder)
}
