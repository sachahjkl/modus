package graphics

import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"
import "modus:support/text_rendering"

// The text of the system (docs/FONTS.md). Two fonts draw on one grid of
// cells of 8 x 16 pixels at scale 1 (16 x 32, 24 x 48 at the scales 2 and
// 3): the vector font, whose glyphs the process draws from the font
// outlines into its private glyph cache (src/library/support/text_rendering),
// and Spleen 8x16 (font.odin), the fallback and the other value of the
// setting. A process calls text, character and text_scaled; it does not
// know which font draws.
//
// The state is in this package, one for the process, and changes only
// through text_faces_use and text_choice_set (src/library/support/display
// calls them at the start of a window and at a change of the setting,
// between two frames). The zero state draws with Spleen: no face yet.

// The fonts of the setting "font". Zero is the default (ZII): the vector font.
Text_Font :: enum u8 {
	Vector, // The vector font of the system, from the font outlines.
	Spleen, // Spleen 8x16, a bitmap font in the library itself.
}

// The most scale of a text of cells, and of a text of the interface font
// that a draw record names.
TEXT_SCALE_LIMIT :: 3

// The order of the color stripes of the pixels of the screen: the setting
// "subpixel_order". None draws the vector font in grayscale.
Subpixel_Order :: enum u8 {
	Red_Green_Blue, // Red on the left of each pixel: most screens.
	Blue_Green_Red, // Blue on the left.
	None, // No subpixels: grayscale.
}

// The text state of a process: the setting of the font, the faces of the
// cells, and the tables of the blend. One for the process, in
// `text_state`.
Text_State :: struct {
	font:        Text_Font, // The setting "font".
	order:       Subpixel_Order, // The setting "subpixel_order".
	// The face of the cells of the setting "grid_fit", which the process
	// opened: Cells or Cells_Without_Grid_Fit. None: the vector font cannot
	// draw, and the text is Spleen.
	cell_face:   text_rendering.Face,
	// The face of the bold weight at scale 1, for emphasis: the titles of
	// the cards. None: the titles are the regular weight.
	bold_face:   text_rendering.Face,
	// The blend in linear light: square_root[i] is the 8-bit value whose
	// square is nearest to (4096 i + 2048) / 255 (docs/FONTS.md, "The blend in linear light").
	square_root: [4096]u8,
	// The blend tables of text over a flat color (blend.odin), 24 KiB.
	blend_tables: Blend_Tables,
}

// The text state of this process. `text_faces_use` and `text_choice_set`
// change it, between two frames.
text_state: Text_State

// text_faces_use makes two faces the faces of the cells and of the bold
// weight. A face that this copy of text_rendering has not opened
// (text_rendering.face_opened), and a proportional face, are not taken:
// a glyph of a proportional face passes its cell, and the damage of a grid
// of text cells depends on a glyph that stays in its cell. With no face of
// the cells the text is Spleen; with no bold face the titles are the
// regular weight.
text_faces_use :: proc "contextless" (cells, bold: text_rendering.Face) {
	cell_face_of :: proc "contextless" (face: text_rendering.Face) -> text_rendering.Face {
		if !text_rendering.face_opened(face) || text_rendering.face_forms[face].proportional {
			return .None
		}
		return face
	}
	text_state.cell_face = cell_face_of(cells)
	text_state.bold_face = cell_face_of(bold)
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
}

// text_bold draws characters at scale 1 in the bold weight of the vector
// font: the titles of the cards. With Spleen, or with no bold face, it is
// text. It gives the x after the last character. alpha is the alpha of the
// color, as in text_scaled.
text_bold :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, alpha: u32 = OPAQUE) -> int {
	if !text_vector_drawn() || text_state.bold_face == .None {
		return text_scaled(canvas, x, y, characters, color, 1, alpha)
	}
	if alpha == 0 {
		return x + text_encoding.character_count(transmute([]u8)characters) * CELL_WIDTH
	}
	bytes := transmute([]u8)characters
	at, place := x, 0
	for place < len(bytes) {
		character, length, _ := text_encoding.character_decode(bytes, place)
		place += length
		if at < canvas.width && at + CELL_WIDTH > 0 {
			if !character_of_face(text_state.bold_face, canvas, at, y, character, color, 1, alpha) {
				character_replacement(canvas, at, y, color, 1, alpha)
			}
		}
		at += CELL_WIDTH
	}
	return at
}

// character_of_face draws a character in the cell at (x, y) from a face of
// cells at the text size of a scale (text_rendering: the private glyph
// cache of the process), and gives true; false when no font of the chain
// of the face draws it, and for the face None: the caller draws the
// replacement glyph. A glyph of a face of cells stays in its cell.
@(private)
character_of_face :: proc "contextless" (face: text_rendering.Face, canvas: Canvas, x, y: int, character: rune, color: Color, scale: int, alpha: u32 = OPAQUE) -> bool {
	return face_glyph_draw(face, character, text_rendering.size_of_scale(scale), 0, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, x, y, color, alpha)
}

// face_glyph_draw draws the glyph of a character of a face at a text size
// and a position across a pixel (text_rendering.glyph), its origin at the
// whole pixel x and the top of its line at y, and gives true; false when
// the face has no glyph for it. A glyph that is too large to be kept is
// drawn band by band, each band blended as it is drawn.
//
// It is never inlined. Inlined into text_scaled, its band loop raised the
// pressure on the registers so far that the register allocator of LLVM 18
// spilled in another way when debug instructions stood in the function: the
// module differed with and without debug information
// (src/md/infrastructure/debug_information_and_code.md).
@(private)
face_glyph_draw :: #force_no_inline proc "contextless" (face: text_rendering.Face, character: rune, size, position: int, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, color: Color, alpha: u32) -> bool {
	entry, words, source := text_rendering.glyph(face, character, size, position)
	switch source {
	case .Missing:
		return false
	case .Private_Cache, .Not_Kept:
		glyph_words_draw(entry, words, square_root, tables, order, canvas, x, y, color, alpha)
		return true
	case .Banded:
		job, started := text_rendering.glyph_bands(face, character, size, position)
		if !started {
			return false
		}
		for {
			first_row, row_count, band_words := text_rendering.band_next(&job)
			if row_count == 0 {
				break
			}
			band := glyph_cache.Glyph_Entry{first_row = u16(first_row), row_count = u16(row_count), left = i16(-job.origin_column), width = u16(job.columns)}
			glyph_words_draw(band, band_words, square_root, tables, order, canvas, x, y, color, alpha)
		}
		return true
	}
	return false
}

// paint fills a rectangle of a glyph drawn by its pixels (Spleen, the
// replacement box) in a color with an alpha: fill when it is opaque, else
// the blend of the draw records, with the table given, or the table of the
// text state for nil. The rectangles of one glyph never overlap, so each
// pixel blends once.
@(private)
paint :: #force_inline proc "contextless" (canvas: Canvas, x, y, width, height: int, color: Color, alpha: u32, square_root: ^[4096]u8) {
	if alpha == OPAQUE {
		fill(canvas, x, y, width, height, color)
		return
	}
	table := square_root != nil ? square_root : &text_state.square_root
	blend_fill(canvas, x, y, width, height, alpha << 24 | color & 0x00FFFFFF, table)
}

// cell_face gives the face of the cells of the process now: None with
// Spleen, where a cell past the characters of Spleen draws the
// replacement glyph.
cell_face :: proc "contextless" () -> text_rendering.Face {
	if !text_vector_drawn() {
		return .None
	}
	return text_state.cell_face
}

// square_root_table_fill makes the table of the blend in linear light:
// entry i is the 8-bit value whose square is nearest to the middle of the
// sums d * d * (255 - a) + c * c * a that shift to i: (4096 i + 2048) / 255.
// In units of 1/255 to stay in integers: the square of r times 255 against
// 4096 i + 2048.
square_root_table_fill :: proc "contextless" (table: ^[4096]u8) {
	root := 0
	for &value, index in table {
		target := 4096 * index + 2048
		for root < 255 && (root + 1) * (root + 1) * 255 <= target {
			root += 1
		}
		below := target - root * root * 255
		above := (root + 1) * (root + 1) * 255 - target
		value = u8(min(below > above ? root + 1 : root, 255))
	}
}

// text_state_start fills the table of the blend in linear light of the
// text state. A process calls it once at its start, before any thread
// draws (display.text_settings_load does), so no blend fills it on first
// use while another reads it: the draw records with alpha blend with it.
text_state_start :: proc "contextless" () {
	square_root_table_fill(&text_state.square_root)
}

// text_choice_set sets the font and the order of the stripes.
text_choice_set :: proc "contextless" (font: Text_Font, order: Subpixel_Order) {
	text_state.font = font
	text_state.order = order
}

// text_vector_drawn says if text is drawn with the vector font now.
text_vector_drawn :: #force_inline proc "contextless" () -> bool {
	return text_state.font == .Vector && text_state.cell_face != .None
}

// text draws characters from (x, y), the top left corner of the first cell,
// at scale 1. It gives the x after the last character.
text :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color) -> int {
	return text_scaled(canvas, x, y, characters, color, 1)
}

// cell_font_draws says if Spleen has a glyph for a character: ASCII 32 to
// 126, the Latin-1 Supplement and the added characters
// (glyph_cache.character_index), the characters of each font of the
// system.
cell_font_draws :: #force_inline proc "contextless" (character: rune) -> bool {
	_, found := glyph_cache.character_index(character)
	return found
}

// character_replacement draws the replacement glyph in the cell at (x, y):
// the outline of a box from the top of a capital letter to the baseline,
// in each font and at each scale. A reader draws it for a character that
// the font lacks and for each invalid sequence of a text, so that a byte is never
// drawn as a glyph and a reader sees that a character is there. The two
// sides stop at the top and the bottom bars, so no pixel is painted twice:
// a color with alpha blends once in each pixel.
character_replacement :: proc "contextless" (canvas: Canvas, x, y: int, color: Color, scale: int, alpha: u32 = OPAQUE, square_root: ^[4096]u8 = nil) {
	BOX_LEFT :: 1
	BOX_TOP :: 3
	BOX_WIDTH :: 6
	BOX_HEIGHT :: 9
	if alpha == 0 {
		return
	}
	left, top := x + BOX_LEFT * scale, y + BOX_TOP * scale
	width, height := BOX_WIDTH * scale, BOX_HEIGHT * scale
	paint(canvas, left, top, width, scale, color, alpha, square_root)
	paint(canvas, left, top + height - scale, width, scale, color, alpha, square_root)
	paint(canvas, left, top + scale, scale, height - 2 * scale, color, alpha, square_root)
	paint(canvas, left + width - scale, top + scale, scale, height - 2 * scale, color, alpha, square_root)
}

// character draws one character in the cell at (x, y), at scale 1: from
// the face of the cells with the vector font, else from Spleen. A
// character that no font of the chain has, and with Spleen a character
// that Spleen lacks, draws the replacement glyph.
character :: proc "contextless" (canvas: Canvas, x, y: int, value: rune, color: Color) {
	switch {
	case text_vector_drawn():
		if !character_of_face(text_state.cell_face, canvas, x, y, value, color, 1) {
			character_replacement(canvas, x, y, color, 1)
		}
	case cell_font_draws(value):
		character_spleen(canvas, x, y, value, color)
	case:
		character_replacement(canvas, x, y, color, 1)
	}
}

// text_scaled draws characters in cells of scale times the size of a cell:
// 1, 2 or 3 (docs/DESIGN.md, section 5). The vector font draws each
// character from the face of the cells at the text size of the scale;
// Spleen draws each of its pixels as a square of scale pixels. A character
// that no font of the chain has, and with Spleen a character that Spleen
// lacks, draws the replacement glyph. It gives the x after the last
// character.
//
// alpha is the alpha of the color: 255 draws the color opaque, a lower
// alpha scales the cover of each pixel of ink, in each font: the coverage
// of a glyph, and each pixel of Spleen and of the replacement box. Alpha 0
// draws nothing.
text_scaled :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, scale_asked: int, alpha: u32 = OPAQUE) -> int {
	scale := clamp(scale_asked, 1, TEXT_SCALE_LIMIT)
	advance := CELL_WIDTH * scale
	if alpha == 0 {
		return x + text_encoding.character_count(transmute([]u8)characters) * advance
	}
	vector := text_vector_drawn()
	// The text is UTF-8: one cell for each character, and one for each
	// invalid sequence, which draws the replacement glyph.
	bytes := transmute([]u8)characters
	at, place := x, 0
	for place < len(bytes) {
		character, length, _ := text_encoding.character_decode(bytes, place)
		place += length
		if at < canvas.width && at + advance > 0 {
			switch {
			case vector:
				if !character_of_face(text_state.cell_face, canvas, at, y, character, color, scale, alpha) {
					character_replacement(canvas, at, y, color, scale, alpha)
				}
			case !cell_font_draws(character):
				character_replacement(canvas, at, y, color, scale, alpha)
			case scale == 1:
				character_spleen(canvas, at, y, character, color, alpha)
			case:
				character_spleen_enlarged(canvas, at, y, character, color, scale, alpha)
			}
		}
		at += advance
	}
	return at
}

// text_width gives the width of a text in the font of the cells at scale 1,
// in pixels: 8 pixels for each character of the UTF-8 text, and for each
// invalid sequence. Both fonts of the cells have that width.
text_width :: proc "contextless" (characters: string) -> int {
	return text_encoding.character_count(transmute([]u8)characters) * CELL_WIDTH
}

// character_vector_with draws one character of a glyph cache file that
// the caller drew and validated, with the fast blend: the same pixels as
// character_vector_reference. The text of the system never reads such a
// file; the demonstration vector_glyphs draws its candidate fonts with it,
// and the tests of the blend take their glyphs from it.
character_vector_with :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, value: rune, color: Color, scale: int, alpha: u32 = OPAQUE) {
	_, entry, found := glyph_cache.glyph(cache, value, scale)
	if !found || entry.row_count == 0 {
		return
	}
	glyph_words_draw(entry, raw_data(cache.words[entry.word_offset:]), square_root, tables, order, canvas, x, y, color, alpha)
}

// glyph_words_draw draws one glyph from its first word with the fast
// blend, its origin at the whole pixel x, the top of its line at y, cut to
// the canvas: an entry of the private glyph cache, which this process
// wrote, or a band of a glyph drawn band by band. Its words are row_count
// rows of width words. The text of cells and the text of a proportional
// font both draw through it, so both have the same blend.
@(private)
glyph_words_draw :: proc "contextless" (entry: glyph_cache.Glyph_Entry, words: [^]u32, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, color: Color, alpha: u32 = OPAQUE) #no_bounds_check {
	if entry.row_count == 0 {
		return
	}
	column_x := x + int(entry.left)
	width := int(entry.width)
	first_column := max(0, -column_x)
	last_column := min(width, canvas.width - column_x)
	first_row := max(0, -(y + int(entry.first_row)))
	last_row := min(int(entry.row_count), canvas.height - y - int(entry.first_row))
	if first_column >= last_column || first_row >= last_row {
		return
	}
	if words == nil {
		return
	}
	blend_glyph_rows(canvas.pixels[(y + int(entry.first_row)) * canvas.stride + column_x:], canvas.stride, words, width, first_row, last_row, first_column, last_column, color, order, square_root, tables, alpha)
}

// character_vector_reference draws one character of a glyph cache that
// glyph_cache.validate accepted, with the blend of one row at a time: the
// reference of the fast blend in the tests. Each entry and each word is
// inside the file, so the loop has no bounds check (the rows and the
// columns are cut to the canvas here).
character_vector_reference :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, order: Subpixel_Order, canvas: Canvas, x, y: int, value: rune, color: Color, scale: int, alpha: u32 = OPAQUE) #no_bounds_check {
	_, entry, found := glyph_cache.glyph(cache, value, scale)
	if !found || entry.row_count == 0 {
		return
	}
	// The words of a row start at the column left of the cell: 0, and the
	// width of the cell, in the cache of a monospace font.
	column_x := x + int(entry.left)
	width := int(entry.width)
	first_column := max(0, -column_x)
	last_column := min(width, canvas.width - column_x)
	first_row := max(0, -(y + int(entry.first_row)))
	last_row := min(int(entry.row_count), canvas.height - y - int(entry.first_row))
	if first_column >= last_column || first_row >= last_row {
		return
	}
	words := raw_data(cache.words[entry.word_offset:])
	for row in first_row ..< last_row {
		line := canvas.pixels[(y + int(entry.first_row) + row) * canvas.stride + column_x:]
		blend_coverage_row(line, words[row * width:], first_column, last_column, color, order, square_root, alpha)
	}
}

// character_spleen draws one character of Spleen 8x16 at its native size.
// With an alpha below 255, each pixel of the glyph blends once.
character_spleen :: proc "contextless" (canvas: Canvas, x, y: int, value: rune, color: Color, alpha: u32 = OPAQUE, square_root: ^[4096]u8 = nil) {
	index, found := glyph_cache.character_index(value)
	if !found {
		return
	}
	glyph := font[index]
	if alpha != OPAQUE {
		for bits, row in glyph {
			for column in 0 ..< CELL_WIDTH {
				if bits << uint(column) & 0x80 != 0 {
					paint(canvas, x + column, y + row, 1, 1, color, alpha, square_root)
				}
			}
		}
		return
	}
	if x >= 0 && y >= 0 && x + CELL_WIDTH <= canvas.width && y + CELL_HEIGHT <= canvas.height {
		// The whole glyph is inside the canvas: no test for each pixel.
		for bits, row in glyph {
			line := canvas.pixels[(y + row) * canvas.stride + x:]
			for column in 0 ..< CELL_WIDTH {
				if bits << uint(column) & 0x80 != 0 {
					line[column] = color
				}
			}
		}
		return
	}
	for bits, row in glyph {
		for column in 0 ..< CELL_WIDTH {
			if bits << uint(column) & 0x80 != 0 {
				pixel(canvas, x + column, y + row, color)
			}
		}
	}
}

// character_spleen_enlarged draws one character of Spleen with each pixel
// as a square of scale pixels: the large sizes when the setting is Spleen.
character_spleen_enlarged :: proc "contextless" (canvas: Canvas, x, y: int, value: rune, color: Color, scale: int, alpha: u32 = OPAQUE, square_root: ^[4096]u8 = nil) {
	index, found := glyph_cache.character_index(value)
	if !found {
		return
	}
	for bits, row in font[index] {
		for column in 0 ..< CELL_WIDTH {
			if bits << uint(column) & 0x80 != 0 {
				paint(canvas, x + column * scale, y + row * scale, scale, scale, color, alpha, square_root)
			}
		}
	}
}

// The ink of a text of a proportional font can pass the box that its
// measure gives (text_rendering.text_width), on each side, by at most this
// many pixels at scale 1: a glyph that starts left of its origin (B612: at
// most 126 units, 0.84 pixel), the spread of the filter (two thirds of a
// pixel), and the rounding to a third of a pixel (one sixth). A caller that
// damages the place of a text widens the measured box by it, times the
// scale (docs/FONTS.md, section 12.5).
PROPORTIONAL_INK_MARGIN :: 2

// text_proportional draws the placed glyphs of a text of a proportional
// face (text_rendering.shape) at the text size of a scale: place is the x
// of the origin of the text in 1/64 of a pixel, y the top of its line.
// Each glyph is drawn from the private glyph cache of the process
// (text_rendering.glyph) at the nearest third of a pixel, through the
// blend of the text of cells, cut to the canvas. The state of the process
// gives the order of the stripes and the blend tables. A glyph that no
// font of the chain draws is the replacement glyph, at the advance that
// the shaper gave it.
text_proportional :: proc "contextless" (canvas: Canvas, place: i64, y: int, placed: []text_rendering.Placed_Glyph, face: text_rendering.Face, scale: int, color: Color, alpha: u32 = OPAQUE) {
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
	text_proportional_with(face, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, place, y, placed, scale, color, alpha)
}

// text_proportional_with is text_proportional with its state given: the
// tests draw with it, each with its own tables. alpha is the alpha of the
// color, as in text_scaled. A scale out of 1 to TEXT_SCALE_LIMIT, a face
// that is not proportional, and a glyph past the character indices that
// is neither a fallback glyph nor the replacement glyph draw nothing.
text_proportional_with :: proc "contextless" (face: text_rendering.Face, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, place: i64, y: int, placed: []text_rendering.Placed_Glyph, scale: int, color: Color, alpha: u32 = OPAQUE) {
	if scale < 1 || scale > TEXT_SCALE_LIMIT || alpha == 0 || !text_rendering.face_forms[face].proportional {
		return
	}
	size := text_rendering.size_of_scale(scale)
	position_count := text_rendering.positions_of(face)
	for glyph in placed {
		replacement := glyph.glyph == text_rendering.REPLACEMENT_GLYPH
		character: rune
		switch {
		case replacement:
		case glyph.glyph >= text_rendering.FALLBACK_GLYPH_FIRST:
			character = rune(glyph.glyph - text_rendering.FALLBACK_GLYPH_FIRST)
		case:
			indexed, found := glyph_cache.character_of_index(int(glyph.glyph))
			if !found {
				continue
			}
			character = indexed
		}
		pixel, position := glyph_cache.position_of(place + i64(glyph.x), position_count)
		// A glyph far outside the canvas: its pixel does not fit an int of
		// the canvas, and it draws nothing.
		if pixel < -i64(glyph_cache.GLYPH_WIDTH_LIMIT) || pixel > i64(canvas.width) {
			continue
		}
		if replacement || !face_glyph_draw(face, character, size, position, square_root, tables, order, canvas, int(pixel), y, color, alpha) {
			character_replacement(canvas, int(pixel), y, color, scale, alpha)
		}
	}
}
