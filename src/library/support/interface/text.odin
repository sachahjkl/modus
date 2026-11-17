package interface

import "modus:contract/draw_record"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/text_shaping"

// The fonts that the package can measure (docs/FONTS.md, section 12.6).
// Cells_8x16: the grid of the font of the cells, 8 x 16 pixels at scale 1;
// the vector font of the system and Spleen 8x16 both draw on it, as the
// setting `font` chooses. Interface: the proportional font of the
// names, titles, labels, buttons and lists (B612), when the program has it
// (Draw_Table.interface_font) and the setting is the vector font; else a
// text of this kind is measured and drawn in the font of the cells. A text
// is always measured in the font that will draw it.
Font_Kind :: enum u8 {
	Cells_8x16, // The font of the cells: each character is one cell wide.
	Interface, // The proportional interface font.
}

// A font and a size. scale: 1, 2 or 3 times the native size (docs/DESIGN.md,
// section 5); 0 means 1.
Font :: struct {
	kind:   Font_Kind, // Which font.
	scale:  u8, // 1, 2 or 3; 0 is 1.
	weight: Font_Weight, // Regular or bold.
}

// The weight of a text, a field of a text record: Regular or Bold. Bold
// draws at scale 1 only (the titles of the cards); at another scale, and
// with Spleen 8x16, it is the regular weight. In the font of the cells the
// width does not change: the cells are the same. In the interface font the
// bold weight has its own advances.
Font_Weight :: draw_record.Font_Weight

FONT_BOLD :: Font{weight = .Bold} // The font of the cells, bold.

FONT_LARGE :: Font{scale = 3} // The one number of a card.
FONT_MEDIUM :: Font{scale = 2} // The font of the cells at twice its size.

// The interface font: the names, the labels, the buttons, the lists, the
// captions; its bold weight: the titles of the cards.
FONT_INTERFACE :: Font{kind = .Interface}
FONT_INTERFACE_BOLD :: Font{kind = .Interface, weight = .Bold}

// The most bytes of one text in the interface font: the execution places
// its glyphs on its stack. A longer text is drawn in the font of the cells.
INTERFACE_TEXT_LIMIT :: draw_record.INTERFACE_TEXT_LIMIT
// The largest ink margin of a record, in pixels: the margin of the font at
// scale 3 is far smaller.
INK_MARGIN_LIMIT :: draw_record.INK_MARGIN_LIMIT

// font_scale gives the scale of a font, from 1 to 3: 0 is 1, and a scale
// above 3 is 3.
font_scale :: proc "contextless" (font: Font) -> int {
	return clamp(int(font.scale), 1, 3)
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

// interface_cache_of gives the cache of the interface font that draws a
// weight at a scale: the bold weight has scale 1 only; at another scale it
// is the regular weight, as in the font of the cells.
interface_cache_of :: proc "contextless" (caches: ^display.Interface_Font, font: Font) -> ^glyph_cache.Cache {
	if font.weight == .Bold && font_scale(font) == 1 {
		return &caches.bold
	}
	return &caches.regular
}

// interface_width_subpixels gives the width of a text in the interface
// font, in 1/64 of a pixel: the sum of the advances of its placed glyphs.
// 0 for a cache that does not have the scale.
interface_width_subpixels :: proc "contextless" (caches: ^display.Interface_Font, font: Font, text: string) -> i64 {
	spacing, ok := text_shaping.spacing_of(interface_cache_of(caches, font), font_scale(font))
	if !ok {
		return 0
	}
	width, _ := text_shaping.text_width(&spacing, transmute([]u8)text)
	return width
}

// text_width gives the width of a text in pixels, in the font of the cells:
// one cell for each character of the UTF-8 text, and one for each invalid sequence.
text_width :: proc "contextless" (font: Font, text: string) -> int {
	return text_encoding.character_count(transmute([]u8)text) * graphics.CELL_WIDTH * font_scale(font)
}

// text_measured_width gives the width of a text in pixels, in the font that the
// table draws it in: in the interface font, the measure rounded up to a
// whole pixel. measured_size is its form for a layout.
text_measured_width :: proc "contextless" (table: ^Draw_Table, font: Font, text: string) -> int {
	used := font_in_use(table, font, len(text))
	if used.kind == .Interface {
		return int((interface_width_subpixels(table.interface_font, used, text) + 63) / 64)
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
	spacing, ok := text_shaping.spacing_of(interface_cache_of(table.interface_font, used), font_scale(used))
	for index in 0 ..< count {
		if !ok || len(texts[index]) > INTERFACE_TEXT_LIMIT {
			widths[index] = text_width({scale = used.scale}, texts[index])
			continue
		}
		width, _ := text_shaping.text_width(&spacing, transmute([]u8)texts[index])
		widths[index] = int((width + 63) / 64)
	}
}

// measured_size gives the width of a text in the font that the table draws it
// in, rounded up to the grid of 8 pixels: the size of a column of a row
// (row_split) that holds the text.
measured_size :: proc "contextless" (table: ^Draw_Table, font: Font, text: string) -> Size {
	return pixels((text_measured_width(table, font, text) + 7) / 8 * 8)
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

// is_path_break says if a line can end after a character of a word: the
// separators of a path, of a place in a source and of a name of the system.
@(private)
is_path_break :: proc "contextless" (character: u8) -> bool {
	return character == '/' || character == ':' || character == '_'
}

// text_wrap_line gives the first line of a text in a box of `room` pixels,
// and the text after it. The line ends at the last space that fits, and the
// spaces at the break are in neither part. A word that is wider than the
// box starts on the line of the word before it, and ends a line after its
// last `/`, `:` or `_` that fits; with none, at its last character that
// fits. A line has at least one character, also in a box narrower than a
// character: the rest is always shorter than the text, so a loop over the
// lines ends. The text is measured in the font that the table draws it in
// (font_in_use).
text_wrap_line :: proc "contextless" (table: ^Draw_Table, font: Font, text: string, room: int) -> (line: string, rest: string) {
	count := len(text_fit(table, font, text, room))
	if count == len(text) {
		return text, text[len(text):]
	}
	at_space := 0 // The bytes of the line that ends at the last space; 0: none.
	if text[count] == ' ' {
		at_space = count
	}
	for index := count - 1; at_space == 0 && index > 0; index -= 1 {
		if text[index] == ' ' {
			at_space = index
		}
	}
	in_word := 0 // The bytes of the line that ends after the last separator; 0: none.
	for index := count - 1; in_word == 0 && index >= at_space && index >= 0; index -= 1 {
		if is_path_break(text[index]) {
			in_word = index + 1
		}
	}
	end := at_space
	if at_space != 0 && in_word > at_space {
		// The last word of the line has a separator. If the whole word has
		// room on a line of its own, it goes there; else it is broken here,
		// so that the line of the word before it is not left short.
		word := text[at_space:]
		for len(word) > 0 && word[0] == ' ' {
			word = word[1:]
		}
		for index in 0 ..< len(word) {
			if word[index] == ' ' {
				word = word[:index]
				break
			}
		}
		if text_measured_width(table, font, word) > room {
			end = in_word
		}
	}
	if end == 0 {
		// At least the first character, whole.
		_, first_length, _ := text_encoding.character_decode(transmute([]u8)text, 0)
		end = in_word != 0 ? in_word : max(count, first_length)
	}
	line, rest = text[:end], text[end:]
	for len(line) > 1 && line[len(line) - 1] == ' ' {
		line = line[:len(line) - 1]
	}
	for len(rest) > 0 && rest[0] == ' ' {
		rest = rest[1:]
	}
	return line, rest
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

// line_height gives the height of a line of a font, in pixels: both fonts
// draw in the line of the grid.
line_height :: proc "contextless" (font: Font) -> int {
	return graphics.CELL_HEIGHT * font_scale(font)
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
