package graphics

import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"
import "modus:support/text_rendering"

// The text of the system (docs/FONTS.md). Two fonts draw on one grid of
// cells of 8 x 16 pixels at scale 1 (16 x 32, 24 x 48 at the scales 2 and
// 3): the vector font, from a glyph cache that the root service maps for
// the process, and Spleen 8x16 (font.odin), the fallback and the other
// value of the setting. A process calls text, character and text_scaled;
// it does not know which font draws.
//
// The state is in this package, one for the process, and changes only
// through text_cache_set and text_choice_set (src/library/support/display calls them
// at the start of a window and at a change of the setting, between two
// frames). The zero state draws with Spleen: no cache yet.

// The fonts of the setting "font". Zero is the default (ZII): the vector font.
Text_Font :: enum u8 {
	Vector, // The vector font of the system, from the glyph cache.
	Spleen, // Spleen 8x16, a bitmap font in the library itself.
}

// The order of the color stripes of the pixels of the screen: the setting
// "subpixel_order". None draws the vector font in grayscale.
Subpixel_Order :: enum u8 {
	Red_Green_Blue, // Red on the left of each pixel: most screens.
	Blue_Green_Red, // Blue on the left.
	None, // No subpixels: grayscale.
}

// The text state of a process: the setting of the font, the caches, and
// the tables of the blend. One for the process, in `text_state`.
Text_State :: struct {
	font:        Text_Font, // The setting "font".
	order:       Subpixel_Order, // The setting "subpixel_order".
	has_cache:   bool, // A glyph cache was accepted: the vector font can draw.
	cache:       glyph_cache.Cache, // The glyph cache of the regular weight.
	// The blend in linear light: square_root[i] is the 8-bit value whose
	// square is nearest to (4096 i + 2048) / 255 (docs/FONTS.md, "The blend in linear light").
	square_root: [4096]u8,
	// The bold weight at scale 1, for emphasis: the titles of the cards.
	has_bold_cache: bool, // A bold cache was accepted.
	bold_cache:     glyph_cache.Cache, // The glyph cache of the bold weight.
	// The blend tables of text over a flat color (blend.odin), 24 KiB.
	blend_tables: Blend_Tables,
}

// The text state of this process. `text_cache_set` and `text_choice_set`
// change it, between two frames.
text_state: Text_State

// text_cache_set validates a glyph cache once and makes it the cache of the
// vector font. A refused cache leaves the process with Spleen; the problem
// is a value for the log of the caller.
text_cache_set :: proc "contextless" (bytes: []u8) -> glyph_cache.Problem {
	cache, problem := glyph_cache.validate(bytes)
	if problem.kind != .None {
		text_state.has_cache = false
		return problem
	}
	return text_cache_use(cache)
}

// cell_cache_problem says if a valid cache can draw the cells of the grid:
// a cache of a proportional font cannot. Its glyphs are boxes of ink that
// pass their cells, so the damage of a grid of text cells, which depends
// on a glyph that stays in its cell, would leave stale pixels. A
// proportional cache is drawn by text_proportional only.
cell_cache_problem :: proc "contextless" (cache: ^glyph_cache.Cache) -> glyph_cache.Problem {
	if cache.header.flags & glyph_cache.FLAG_PROPORTIONAL != 0 {
		return {kind = .Proportional, value = u64(cache.header.flags)}
	}
	return {}
}

// text_cache_use makes a cache that glyph_cache.validate accepted the cache
// of the vector font: a change of the setting "grid_fit" between two
// caches that the process validated once. A cache of a proportional font
// is refused: the process draws with Spleen, as for any refused cache.
text_cache_use :: proc "contextless" (cache: glyph_cache.Cache) -> glyph_cache.Problem {
	cache := cache
	if problem := cell_cache_problem(&cache); problem.kind != .None {
		text_state.has_cache = false
		return problem
	}
	text_state.cache = cache
	text_state.has_cache = true
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
	return {}
}

// text_bold_cache_use makes a cache that glyph_cache.validate accepted the
// cache of the bold weight. A cache of a proportional font is refused: the
// titles are the regular weight.
text_bold_cache_use :: proc "contextless" (cache: glyph_cache.Cache) -> glyph_cache.Problem {
	cache := cache
	if problem := cell_cache_problem(&cache); problem.kind != .None {
		text_state.has_bold_cache = false
		return problem
	}
	text_state.bold_cache = cache
	text_state.has_bold_cache = true
	return {}
}

// text_bold draws characters at scale 1 in the bold weight of the vector
// font: the titles of the cards. With Spleen, or with no bold cache, it is
// text. It gives the x after the last character. alpha is the alpha of the
// color, as in text_scaled.
text_bold :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, alpha: u32 = OPAQUE) -> int {
	if !text_vector_drawn() || !text_state.has_bold_cache {
		return text_scaled(canvas, x, y, characters, color, 1, alpha)
	}
	bytes := transmute([]u8)characters
	at, place := x, 0
	// The face of the bold cache, found at the first character
	// past it.
	face, face_found := text_rendering.Face.None, false
	for place < len(bytes) {
		character, length, _ := text_encoding.character_decode(bytes, place)
		place += length
		if at < canvas.width && at + CELL_WIDTH > 0 {
			if cell_font_draws(character) {
				character_vector_with(&text_state.bold_cache, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, at, y, character, color, 1, alpha)
			} else {
				if !face_found {
					face, face_found = text_rendering.face_of_cache(&text_state.bold_cache), true
				}
				if !character_fallback(face, canvas, at, y, character, color, 1, alpha) {
					character_replacement(canvas, at, y, color, 1, alpha)
				}
			}
		}
		at += CELL_WIDTH
	}
	return at
}

// character_fallback draws a character past the glyph cache in the cell at
// (x, y) from the face of the cache of cells (text_rendering: the demand
// cache or the private glyph cache), and gives true; false when no font of
// the chain draws it: the caller draws the replacement glyph. A glyph of a
// face of cells stays in its cell.
@(private)
character_fallback :: proc "contextless" (face: text_rendering.Face, canvas: Canvas, x, y: int, character: rune, color: Color, scale: int, alpha: u32 = OPAQUE) -> bool {
	return face_glyph_draw(face, character, text_rendering.size_of_scale(scale), 0, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, x, y, color, alpha)
}

// face_glyph_draw draws the glyph of a character of a face at a text size
// and a position across a pixel (text_rendering.glyph), its origin at the
// whole pixel x and the top of its line at y, and gives true; false when
// the face has no glyph for it. A glyph that is too large to be kept is
// drawn band by band, each band blended as it is drawn.
@(private)
face_glyph_draw :: proc "contextless" (face: text_rendering.Face, character: rune, size, position: int, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, color: Color, alpha: u32) -> bool {
	entry, words, source := text_rendering.glyph(face, character, size, position)
	switch source {
	case .Missing:
		return false
	case .Demand_Cache, .Private_Cache, .Not_Kept:
		glyph_words_draw(entry, words, square_root, tables, order, canvas, x, y, color, alpha)
		return true
	case .Too_Large:
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

// cell_face gives the face of the glyph cache of cells of the
// process now: None with Spleen, where a cell past the glyph cache draws
// the replacement glyph.
cell_face :: proc "contextless" () -> text_rendering.Face {
	if !text_vector_drawn() {
		return .None
	}
	return text_rendering.face_of_cache(&text_state.cache)
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
	return text_state.font == .Vector && text_state.has_cache
}

// text draws characters from (x, y), the top left corner of the first cell,
// at scale 1. It gives the x after the last character.
text :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color) -> int {
	return text_scaled(canvas, x, y, characters, color, 1)
}

// cell_font_draws says if the fonts of the cells have a glyph for a
// character: Spleen and each glyph cache hold the same characters, ASCII
// 32 to 126, the Latin-1 Supplement and the added characters
// (glyph_cache.character_index).
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

// character draws one character in the cell at (x, y), at scale 1.
// A character that the glyph caches lack draws from the fallback chain
// with the vector font, or the replacement glyph.
character :: proc "contextless" (canvas: Canvas, x, y: int, value: rune, color: Color) {
	if !cell_font_draws(value) {
		if !character_fallback(cell_face(), canvas, x, y, value, color, 1) {
			character_replacement(canvas, x, y, color, 1)
		}
		return
	}
	if text_vector_drawn() {
		character_vector(canvas, x, y, value, color, 1)
	} else {
		character_spleen(canvas, x, y, value, color)
	}
}

// text_scaled draws characters in cells of scale times the size of a cell:
// 1, 2 or 3 (docs/DESIGN.md, section 5). The vector font draws each size
// from its outline; Spleen draws each of its pixels as a square of scale
// pixels. A character past the glyph cache draws from the fallback chain
// with the vector font, and the replacement glyph when no font of the
// chain has it or with Spleen. It gives the x after the last character.
//
// alpha is the alpha of the color: 255 draws the color opaque, a lower
// alpha scales the cover of each pixel of ink, in each font: the coverage
// of a glyph of a cache, and each pixel of Spleen and of the replacement
// box. Alpha 0 draws nothing.
text_scaled :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color, scale_asked: int, alpha: u32 = OPAQUE) -> int {
	scale := clamp(scale_asked, 1, 3)
	advance := CELL_WIDTH * scale
	if alpha == 0 {
		return x + text_encoding.character_count(transmute([]u8)characters) * advance
	}
	vector := text_vector_drawn()
	// The face, found at the first character past the cache.
	face, face_found := text_rendering.Face.None, false
	// The text is UTF-8: one cell for each character, and one for each
	// invalid sequence, which draws the replacement glyph.
	bytes := transmute([]u8)characters
	at, place := x, 0
	for place < len(bytes) {
		character, length, _ := text_encoding.character_decode(bytes, place)
		place += length
		if at < canvas.width && at + advance > 0 {
			switch {
			case !cell_font_draws(character):
				if !face_found {
					face, face_found = cell_face(), true
				}
				if !character_fallback(face, canvas, at, y, character, color, scale, alpha) {
					character_replacement(canvas, at, y, color, scale, alpha)
				}
			case vector:
				character_vector(canvas, at, y, character, color, scale, alpha)
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

// character_vector draws one character of the glyph cache: each word of the
// glyph blends the color over the pixel of the canvas, one coverage for
// each channel.
character_vector :: #force_inline proc "contextless" (canvas: Canvas, x, y: int, value: rune, color: Color, scale: int, alpha: u32 = OPAQUE) {
	character_vector_with(&text_state.cache, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, x, y, value, color, scale, alpha)
}

// character_vector_with draws one character with the fast blend: the same
// pixels as character_vector_reference.
character_vector_with :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, value: rune, color: Color, scale: int, alpha: u32 = OPAQUE) {
	_, entry, found := glyph_cache.glyph(cache, value, scale)
	if !found || entry.row_count == 0 {
		return
	}
	glyph_entry_draw(cache, entry, square_root, tables, order, canvas, x, y, color, alpha)
}

// glyph_entry_draw draws one glyph entry of a valid cache with the fast
// blend, its origin at the whole pixel x, the top of its line at y, cut to
// the canvas. The text of cells and the text of a proportional font both
// draw through it, so both have the same blend.
@(private)
glyph_entry_draw :: proc "contextless" (cache: ^glyph_cache.Cache, entry: glyph_cache.Glyph_Entry, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, x, y: int, color: Color, alpha: u32 = OPAQUE) #no_bounds_check {
	if entry.row_count == 0 {
		return
	}
	// The words of a row start at the column left of the origin: 0, and
	// the width of the cell, in the cache of a monospace font.
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
	blend_glyph_rows(canvas.pixels[(y + int(entry.first_row)) * canvas.stride + column_x:], canvas.stride, words, width, first_row, last_row, first_column, last_column, color, order, square_root, tables, alpha)
}

// glyph_words_draw draws one glyph past the glyph cache from its first
// word (text_rendering.glyph): an entry of the demand cache, copied and
// checked against its contract, or of the private glyph cache, which this
// process wrote. Its words are row_count rows of width words; the draw is
// the draw of a glyph of a glyph cache.
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
// glyph_cache.validate accepted: each entry and each word is inside the
// file, so the loop has no bounds check (the rows and the columns are cut
// to the canvas here).
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
// font (text_rendering.shape) from a cache of that font: place is the x of
// the origin of the text in 1/64 of a pixel, y the top of its line. Each
// glyph is drawn at the nearest of the positions of its scale, through the
// blend of the text of cells, cut to the canvas. The state of the process
// gives the order of the stripes and the blend tables. A fallback glyph
// (text_rendering.FALLBACK_GLYPH_FIRST and past) is drawn from the fallback
// face of the cache (text_rendering.glyph): the demand cache or the
// private glyph cache of the process. A glyph that no font of the chain
// draws is the replacement glyph, at the advance that the shaper gave it.
text_proportional :: proc "contextless" (canvas: Canvas, place: i64, y: int, placed: []text_rendering.Placed_Glyph, cache: ^glyph_cache.Cache, scale: int, color: Color, alpha: u32 = OPAQUE) {
	if text_state.square_root[4095] == 0 {
		square_root_table_fill(&text_state.square_root)
	}
	text_proportional_with(cache, &text_state.square_root, &text_state.blend_tables, text_state.order, canvas, place, y, placed, scale, color, alpha)
}

// text_proportional_with is text_proportional with its state given: the
// tests draw with it, each with its own tables. alpha is the alpha of the
// color, as in text_scaled.
text_proportional_with :: proc "contextless" (cache: ^glyph_cache.Cache, square_root: ^[4096]u8, tables: ^Blend_Tables, order: Subpixel_Order, canvas: Canvas, place: i64, y: int, placed: []text_rendering.Placed_Glyph, scale: int, color: Color, alpha: u32 = OPAQUE) {
	if scale < 1 || scale > len(cache.sizes) || alpha == 0 {
		return
	}
	position_count := int(cache.sizes[scale - 1].position_count)
	// The face of the cache, found at the first fallback glyph.
	face, face_found := text_rendering.Face.None, false
	for glyph in placed {
		replacement := glyph.glyph == text_rendering.REPLACEMENT_GLYPH
		fallback := !replacement && glyph.glyph >= text_rendering.FALLBACK_GLYPH_FIRST
		if glyph.glyph >= cache.header.character_count && !replacement && !fallback {
			continue
		}
		pixel, position := glyph_cache.position_of(place + i64(glyph.x), position_count)
		// A glyph far outside the canvas: its pixel does not fit an int of
		// the canvas, and it draws nothing.
		if pixel < -i64(glyph_cache.GLYPH_WIDTH_LIMIT) || pixel > i64(canvas.width) {
			continue
		}
		if replacement {
			character_replacement(canvas, int(pixel), y, color, scale, alpha)
			continue
		}
		if fallback {
			if !face_found {
				face, face_found = text_rendering.face_of_cache(cache), true
			}
			if !face_glyph_draw(face, rune(glyph.glyph - text_rendering.FALLBACK_GLYPH_FIRST), text_rendering.size_of_scale(scale), position, square_root, tables, order, canvas, int(pixel), y, color, alpha) {
				character_replacement(canvas, int(pixel), y, color, scale, alpha)
			}
			continue
		}
		_, entry, found := glyph_cache.glyph_of_index(cache, int(glyph.glyph), scale, position)
		if !found {
			continue
		}
		glyph_entry_draw(cache, entry, square_root, tables, order, canvas, int(pixel), y, color, alpha)
	}
}
