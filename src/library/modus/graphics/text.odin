package graphics

import "modus:contract/font_characters"
import "modus:contract/text_encoding"
import "modus:text_rendering"

// The text of the system (docs/FONTS.md). Two fonts draw on one grid of
// cells: a cell is half the text size wide, a half up, and two widths high
// (text_rendering.cell_columns): 8 x 16 pixels at the size of the body, 16
// x 32 and 24 x 48 at the large and the largest size. The vector font draws
// its glyphs from the font outlines into the private glyph cache of the
// process (src/library/modus/text_rendering), at any size; Spleen 8x16
// (font.odin), the fallback and the other value of the setting, draws at a
// whole scale in the middle of its cell. A process calls text, character
// and text_sized; it does not know which font draws.
//
// The state is in this package, one for the process, and changes only
// through text_faces_use and text_choice_set (src/library/modus/display
// calls them at the start of a window and at a change of the setting,
// between two frames). The zero state draws with Spleen: no face yet.

// The fonts of the setting "font". Zero is the default (ZII): the vector font.
Text_Font :: enum u8 {
	Vector, // The vector font of the system, from the font outlines.
	Spleen, // Spleen 8x16, a bitmap font in the library itself.
}

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
	// The face of the bold weight of the cells, for emphasis: the titles of
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

// text_bold draws characters at the size of the body in the bold weight of
// the vector font: the titles of the cards. With Spleen, or with no bold
// face, it is the regular weight. It gives the x after the last character.
// alpha is the alpha of the color, as in text_sized.
text_bold :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, alpha: u32 = OPAQUE) -> int {
	return text_sized(canvas, x, y, characters, color, text_rendering.TEXT_SIZE_OF_SCALE_ONE, true, alpha)
}

// character_of_face draws a character in the cell at (x, y) from a face of
// cells at a text size (text_rendering: the private glyph cache of the
// process), and gives true; false when no font of the chain of the face
// draws it, and for the face None: the caller draws the replacement glyph.
// A glyph of a face of cells stays in its cell.
@(private)
character_of_face :: proc "contextless" (face: text_rendering.Face, canvas: Canvas, x, y: int, character: rune, color: Color, size: int, alpha: u32 = OPAQUE) -> bool {
	return face_glyph_draw(face, character, size, 0, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, x, y, color, alpha)
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
	case .Missing, .Busy:
		return false
	case .Private_Cache, .Not_Kept:
		glyph_words_draw(entry, words, square_root, tables, order, canvas, x, y, color, alpha)
		return true
	case .Banded:
		job, started := text_rendering.glyph_bands(face, character, size, position)
		if !started {
			return false
		}
		glyph_bands_draw(&job, square_root, tables, order, canvas, x, y, color, alpha)
		return true
	}
	return false
}

// glyph_bands_draw draws the bands of a glyph that text_rendering started
// (glyph_bands, glyph_bands_in), each band blended as it is drawn.
@(private)
glyph_bands_draw :: proc "contextless" (job: ^text_rendering.Raster_Job, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, color: Color, alpha: u32) {
	for {
		first_row, row_count, band_words := text_rendering.band_next(job)
		if row_count == 0 {
			break
		}
		band := text_rendering.Glyph_Entry{first_row = u16(first_row), row_count = u16(row_count), left = i16(-job.origin_column), width = u16(job.columns)}
		glyph_words_draw(band, band_words, square_root, tables, order, canvas, x, y, color, alpha)
	}
}

// character_of_set draws a character of a face of a set of fonts that the
// caller opened (text_rendering.font_file_open) in the cell at (x, y), at
// a text size, with the blend and the order of the stripes of the text
// state, and gives true; false when the set has no glyph for it. The glyph
// is drawn band by band at each call: the private glyph cache keys no set.
// The candidate fonts of the demonstration vector_glyphs and of the picture
// of the tool draw with it, through the rasterizer of each face.
character_of_set :: proc "contextless" (set: ^text_rendering.Font_Set, face: text_rendering.Face, canvas: Canvas, x, y: int, character: rune, color: Color, size: int) -> bool {
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
	job, started := text_rendering.glyph_bands_in(set, face, character, size, 0)
	if !started {
		return false
	}
	glyph_bands_draw(&job, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, x, y, color, OPAQUE)
	return true
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
// at the size of the body. It gives the x after the last character.
text :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color) -> int {
	return text_sized(canvas, x, y, characters, color, text_rendering.TEXT_SIZE_OF_SCALE_ONE)
}

// cell_font_draws says if Spleen has a glyph for a character: ASCII 32 to
// 126, the Latin-1 Supplement and the added characters
// (font_characters.character_index), the characters of each font of the
// system.
cell_font_draws :: #force_inline proc "contextless" (character: rune) -> bool {
	_, found := font_characters.character_index(character)
	return found
}

// character_replacement draws the replacement glyph in the cell at (x, y)
// at a whole scale of the cell of the body: the boot display draws it so,
// in Spleen. It is character_replacement_sized at the size of the scale.
character_replacement :: proc "contextless" (canvas: Canvas, x, y: int, color: Color, scale: int, alpha: u32 = OPAQUE, square_root: ^[4096]u8 = nil) {
	character_replacement_sized(canvas, x, y, color, text_rendering.size_of_scale(scale), alpha, square_root)
}

// character_replacement_sized draws the replacement glyph in the cell at
// (x, y) of a text size: the outline of a box from the top of a capital
// letter to the baseline, in each font and at each size. A reader draws it
// for a character that the font lacks and for each invalid sequence of a
// text, so that a byte is never drawn as a glyph and a reader sees that a
// character is there. The box is a part of the cell of 8 by 16 at the body
// (1, 3, 6 and 9 of it, its bars 1 thick), grown with the cell and rounded:
// at a whole scale of the body each number is that scale times the one of
// the body. The two sides stop at the top and the bottom bars, so no pixel
// is painted twice: a color with alpha blends once in each pixel. A size
// that text_rendering.size_check refuses draws nothing.
character_replacement_sized :: proc "contextless" (canvas: Canvas, x, y: int, color: Color, size: int, alpha: u32 = OPAQUE, square_root: ^[4096]u8 = nil) {
	if alpha == 0 || text_rendering.size_check(size) != .None {
		return
	}
	cell := text_rendering.cell_columns(size)
	line := 2 * cell
	bar := max(1, line / CELL_HEIGHT)
	left, top := x + (cell + CELL_WIDTH / 2) / CELL_WIDTH, y + 3 * line / CELL_HEIGHT
	width, height := 6 * cell / CELL_WIDTH, 9 * line / CELL_HEIGHT
	paint(canvas, left, top, width, bar, color, alpha, square_root)
	paint(canvas, left, top + height - bar, width, bar, color, alpha, square_root)
	paint(canvas, left, top + bar, bar, height - 2 * bar, color, alpha, square_root)
	paint(canvas, left + width - bar, top + bar, bar, height - 2 * bar, color, alpha, square_root)
}

// character draws one character in the cell at (x, y), at the size of the
// body: from the face of the cells with the vector font, else from Spleen.
// A character that no font of the chain has, and with Spleen a character
// that Spleen lacks, draws the replacement glyph.
character :: proc "contextless" (canvas: Canvas, x, y: int, value: rune, color: Color) {
	switch {
	case text_vector_drawn():
		if !character_of_face(text_state.cell_face, canvas, x, y, value, color, text_rendering.TEXT_SIZE_OF_SCALE_ONE) {
			character_replacement(canvas, x, y, color, 1)
		}
	case cell_font_draws(value):
		character_spleen(canvas, x, y, value, color)
	case:
		character_replacement(canvas, x, y, color, 1)
	}
}

// text_scaled draws characters at a whole scale of the body: the text size
// of the scale (text_rendering.size_of_scale), with text_sized. A scale
// whose size text_rendering.size_check refuses draws nothing.
text_scaled :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, scale: int, alpha: u32 = OPAQUE) -> int {
	return text_sized(canvas, x, y, characters, color, text_rendering.size_of_scale(scale), false, alpha)
}

// spleen_scale_of gives the scale at which Spleen 8x16 draws a text size:
// the largest whole scale whose line is not above the line of the cell, and
// 1 under it. Spleen is the fallback, so under the body a glyph of it is
// one row or one column larger than its cell, which the box of its record
// cuts; its last column and its first row are empty in most glyphs.
@(private)
spleen_scale_of :: proc "contextless" (size: int) -> int {
	return max(1, 2 * text_rendering.cell_columns(size) / CELL_HEIGHT)
}

// text_sized draws characters in the cells of a text size in 1/64 pixel
// (text_rendering.cell_columns: half the size wide, a half up, two widths
// high), from (x, y), the top left corner of the first cell (docs/DESIGN.md,
// "5. Text"). The vector font draws each character from the face of the
// cells at the size, in the bold weight when bold is true and the process
// opened a bold face; Spleen draws each of its pixels as a square of its
// scale (spleen_scale_of), in the middle of the cell. A character that no
// font of the chain has, and with Spleen a character that Spleen lacks,
// draws the replacement glyph. It gives the x after the last character. A
// size that text_rendering.size_check refuses draws nothing and gives x.
//
// alpha is the alpha of the color: 255 draws the color opaque, a lower
// alpha scales the cover of each pixel of ink, in each font: the coverage
// of a glyph, and each pixel of Spleen and of the replacement box. Alpha 0
// draws nothing.
text_sized :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, size: int, bold := false, alpha: u32 = OPAQUE) -> int {
	if text_rendering.size_check(size) != .None {
		return x
	}
	advance := text_rendering.cell_columns(size)
	if alpha == 0 {
		return x + text_encoding.character_count(transmute([]u8)characters) * advance
	}
	vector := text_vector_drawn()
	face := text_state.cell_face
	if bold && text_state.bold_face != .None {
		face = text_state.bold_face
	}
	spleen_scale := spleen_scale_of(size)
	spleen_x := (advance - CELL_WIDTH * spleen_scale) / 2
	spleen_y := (2 * advance - CELL_HEIGHT * spleen_scale) / 2
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
				if !character_of_face(face, canvas, at, y, character, color, size, alpha) {
					character_replacement_sized(canvas, at, y, color, size, alpha)
				}
			case !cell_font_draws(character):
				character_replacement_sized(canvas, at, y, color, size, alpha)
			case spleen_scale == 1 && spleen_x == 0 && spleen_y == 0:
				character_spleen(canvas, at, y, character, color, alpha)
			case:
				character_spleen_enlarged(canvas, at + spleen_x, y + spleen_y, character, color, spleen_scale, alpha)
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

// glyph_words_draw draws one glyph from its first word with the fast
// blend, its origin at the whole pixel x, the top of its line at y, cut to
// the canvas: an entry of the private glyph cache, which this process
// wrote, or a band of a glyph drawn band by band. Its words are row_count
// rows of width words. The text of cells and the text of a proportional
// font both draw through it, so both have the same blend.
@(private)
glyph_words_draw :: proc "contextless" (entry: text_rendering.Glyph_Entry, words: [^]u32, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, color: Color, alpha: u32 = OPAQUE) #no_bounds_check {
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

// character_spleen draws one character of Spleen 8x16 at its native size.
// With an alpha below 255, each pixel of the glyph blends once.
character_spleen :: proc "contextless" (canvas: Canvas, x, y: int, value: rune, color: Color, alpha: u32 = OPAQUE, square_root: ^[4096]u8 = nil) {
	index, found := font_characters.character_index(value)
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
	index, found := font_characters.character_index(value)
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
// many pixels at a line of 16 pixels: a glyph that starts left of its
// origin (B612: at most 126 units, 0.84 pixel), the spread of the filter
// (two thirds of a pixel), and the rounding to a third of a pixel (one
// sixth). A caller that damages the place of a text widens the measured box
// by it, grown with the size and rounded up (docs/FONTS.md, section 12.5).
PROPORTIONAL_INK_MARGIN :: 2

// text_proportional draws the placed glyphs of a text of a proportional
// face (text_rendering.shape) at a text size in 1/64 pixel, the size of its
// shape: place is the x of the origin of the text in 1/64 of a pixel, y the
// top of its line.
// Each glyph is drawn from the private glyph cache of the process
// (text_rendering.glyph) at the nearest third of a pixel, through the
// blend of the text of cells, cut to the canvas. The state of the process
// gives the order of the stripes and the blend tables. A glyph that no
// font of the chain draws is the replacement glyph, at the advance that
// the shaper gave it.
text_proportional :: proc "contextless" (canvas: Canvas, place: i64, y: int, placed: []text_rendering.Placed_Glyph, face: text_rendering.Face, size: int, color: Color, alpha: u32 = OPAQUE) {
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
	text_proportional_with(face, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, place, y, placed, size, color, alpha)
}

// text_proportional_with is text_proportional with its state given: the
// tests draw with it, each with its own tables. alpha is the alpha of the
// color, as in text_sized. A size that text_rendering.size_check refuses,
// a face that is not proportional, and a glyph past the character indices
// that is neither a fallback glyph nor the replacement glyph draw nothing.
text_proportional_with :: proc "contextless" (face: text_rendering.Face, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, place: i64, y: int, placed: []text_rendering.Placed_Glyph, size: int, color: Color, alpha: u32 = OPAQUE) {
	if text_rendering.size_check(size) != .None || alpha == 0 || !text_rendering.face_forms[face].proportional {
		return
	}
	position_count := text_rendering.positions_of(face)
	for glyph in placed {
		replacement := glyph.glyph == text_rendering.REPLACEMENT_GLYPH
		character: rune
		switch {
		case replacement:
		case glyph.glyph >= text_rendering.FALLBACK_GLYPH_FIRST:
			character = rune(glyph.glyph - text_rendering.FALLBACK_GLYPH_FIRST)
		case:
			indexed, found := font_characters.character_of_index(int(glyph.glyph))
			if !found {
				continue
			}
			character = indexed
		}
		pixel, position := text_rendering.position_of(place + i64(glyph.x), position_count)
		// A glyph far outside the canvas: its pixel does not fit an int of
		// the canvas, and it draws nothing. No glyph is wider than the
		// widest work row of the rasterizer.
		if pixel < -i64(text_rendering.WORK_COLUMN_LIMIT) || pixel > i64(canvas.width) {
			continue
		}
		if replacement || !face_glyph_draw(face, character, size, position, square_root, tables, order, canvas, int(pixel), y, color, alpha) {
			character_replacement_sized(canvas, int(pixel), y, color, size, alpha)
		}
	}
}
