package text_rendering

import "base:intrinsics"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"

// Text shaping (docs/FONTS.md, "12.3 The text shaping module"): the characters of a
// text become placed glyphs, with the advance of each character and the
// pair adjustment of each pair of characters that follow each other. The
// text is UTF-8 (src/library/contract/text_encoding). No ligature and no
// other script: one placed glyph for each character, and one for each
// invalid sequence.
//
// Each number comes from the font file of the face, at the text size of
// the spacing: the advance of the table hmtx, and the pair of the table
// kern when two glyphs of one font follow each other. Each is rounded once
// to 1/64 of a pixel, and the x of a glyph is the sum of the integers
// before it. No number depends on a cache, on the grid fit or on the order
// of the stripes, so the measure and the draw of a frame agree.
//
// A process measures over the fonts that it opened (spacing_of). The
// library module text_rendering opens a set of fonts from the bytes of its
// caller for one call (spacing_in): those bytes can be in a call region
// that another thread changes. The parser checks each read of a font file
// against its bytes, so a changed byte gives other numbers, never a read
// out of the file; each advance and each pair is kept in its bound at its
// read, so no sum wraps.

CHARACTER_COUNT :: glyph_cache.CHARACTER_COUNT // The characters of a glyph cache: ASCII 32 to 126, the Latin-1 Supplement and the added characters.
// The glyph of a character that no font of the chain has, and of each
// invalid sequence of the text: the reader draws the replacement glyph in
// its place (graphics.character_replacement), so that a reader sees that a
// character is there that the font does not draw. It has the advance of
// REPLACEMENT_ADVANCE_CHARACTER, and no pair.
REPLACEMENT_GLYPH :: max(u32)
REPLACEMENT_ADVANCE_CHARACTER :: '0'
// The glyph of a character past the glyph cache that the fallback chain
// has is FALLBACK_GLYPH_FIRST plus its code point: past each character
// index, and below REPLACEMENT_GLYPH.
FALLBACK_GLYPH_FIRST :: u32(1) << 24
#assert(FALLBACK_GLYPH_FIRST > CHARACTER_COUNT && u64(FALLBACK_GLYPH_FIRST) + text_encoding.CODE_POINT_LAST < u64(REPLACEMENT_GLYPH))
// The most bytes of one text.
TEXT_LIMIT :: 1 << 16
// The widest cell of a grid of cells, in 1/64 of a pixel: the cell of the
// largest text size is half of it.
CELL_ADVANCE_LIMIT :: TEXT_SIZE_LIMIT
// An advance is at most one line and a pair at most half a line, at any
// size (advance_limit_of_size, pair_limit_of_size): the place of the last
// glyph of the longest text at the largest size stays in an i32 of 1/64 of
// a pixel.
#assert(TEXT_LIMIT * (TEXT_SIZE_LIMIT + TEXT_SIZE_LIMIT / 2) < 1 << 31)
#assert(TEXT_LIMIT * CELL_ADVANCE_LIMIT < 1 << 31)

// Placed_Glyph: one character of a text, placed. x is from the origin of
// the text; advance includes the pair adjustment with the next character;
// so the x of a glyph is the sum of the advances before it.
Placed_Glyph :: struct {
	glyph:   u32, // The character index of the character (glyph_cache.character_index); FALLBACK_GLYPH_FIRST plus the code point: a character past them that the fallback chain has; REPLACEMENT_GLYPH: a character that no font of the chain has.
	x:       i32, // In 1/64 of a pixel.
	advance: i32, // In 1/64 of a pixel.
	cluster: u32, // The first byte of the character in the text.
}
#assert(size_of(Placed_Glyph) == 16)

// Text_Range: one text of a table of bytes, and its width, which the
// measure writes.
Text_Range :: struct {
	start: u32, // The first byte, in the table of bytes.
	count: u32, // Its bytes: at most TEXT_LIMIT.
	width: i64, // In 1/64 of a pixel.
}
#assert(size_of(Text_Range) == 16)

// Spacing: what places the characters of a text. A face at a text size,
// over a set of fonts; or one advance for every character: a grid of cells.
Spacing :: struct {
	// The fonts: nil is the set that this copy of the package opened (open).
	fonts:         ^Font_Set,
	face:          Face,
	size:          int, // The text size, in 1/64 of a pixel.
	cell_advance:  i32, // Above 0: each character, the replacement glyph too, has this advance and no pair: the cells of a grid.
	without_pairs: bool, // No pair adjustment: the text as its advances alone place it.
}

// spacing_of gives the spacing of a face at a text size over the fonts
// that this copy opened. ok is false for the face None, for a size that
// size_check refuses, and before open or when the outlines lack the first
// font of the face: then no character of the face has a measure.
spacing_of :: proc "contextless" (face: Face, size: int) -> (spacing: Spacing, ok: bool) {
	return spacing_in(&state.font_set, face, size)
}

// spacing_in is spacing_of over a set of fonts.
spacing_in :: proc "contextless" (set: ^Font_Set, face: Face, size: int) -> (spacing: Spacing, ok: bool) {
	if face == .None || size_check(size) != .None || !set.opened || !set.fonts[face_forms[face].primary].opened {
		return {}, false
	}
	return {fonts = set, face = face, size = size}, true
}

// cell_spacing gives the spacing of a grid of cells of a width in pixels:
// each character is one cell. The width is kept from 1 pixel to
// CELL_ADVANCE_LIMIT.
cell_spacing :: proc "contextless" (cell_width: int) -> Spacing {
	return {cell_advance = i32(clamp(cell_width, 1, CELL_ADVANCE_LIMIT / SUBPIXEL)) * SUBPIXEL}
}

// glyph_of gives the glyph of a character in a grid of cells: its
// character index, or REPLACEMENT_GLYPH.
glyph_of :: #force_inline proc "contextless" (character: rune) -> u32 {
	index, found := glyph_cache.character_index(character)
	if !found {
		return REPLACEMENT_GLYPH
	}
	return u32(index)
}

// Resolved: one character of a text, found once in the fonts: its placed
// glyph, the font and the glyph of that font that measure it, and its
// advance with no pair.
@(private)
Resolved :: struct {
	glyph:   u32, // As Placed_Glyph.glyph.
	font:    Outline_Font, // None: a cell, or the replacement glyph; neither has a pair.
	index:   int, // The glyph index in that font.
	advance: i32, // From 0 to its bound.
}

// resolve finds a decoded character in the spacing: an invalid sequence,
// and a character that no font of the chain has, is the replacement glyph
// with the advance of REPLACEMENT_ADVANCE_CHARACTER.
@(private)
resolve :: proc "contextless" (spacing: ^Spacing, character: rune, valid: bool) -> (resolved: Resolved) {
	if spacing.cell_advance > 0 {
		resolved.glyph = valid ? glyph_of(character) : REPLACEMENT_GLYPH
		resolved.advance = clamp(spacing.cell_advance, 0, CELL_ADVANCE_LIMIT)
		return resolved
	}
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	font: Outline_Font
	index: int
	if valid {
		font, index = font_glyph_in(set, spacing.face, character)
	}
	if font == .None {
		resolved.glyph = REPLACEMENT_GLYPH
		zero_font, zero_index := font_glyph_in(set, spacing.face, REPLACEMENT_ADVANCE_CHARACTER)
		resolved.advance, _ = glyph_advance_in(set, spacing.face, zero_font, zero_index, spacing.size)
		return resolved
	}
	if character_index, in_cache := glyph_cache.character_index(character); in_cache {
		resolved.glyph = u32(character_index)
	} else {
		resolved.glyph = FALLBACK_GLYPH_FIRST + u32(character)
	}
	resolved.font, resolved.index = font, index
	resolved.advance, _ = glyph_advance_in(set, spacing.face, font, index, spacing.size)
	return resolved
}

// pair_of gives the adjustment of the pair of two resolved characters: the
// pair of their font when both come from one font, else 0.
@(private)
pair_of :: proc "contextless" (spacing: ^Spacing, left, right: Resolved) -> i32 {
	if spacing.cell_advance > 0 || spacing.without_pairs || left.font == .None || left.font != right.font {
		return 0
	}
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	return glyph_pair_in(set, spacing.face, left.font, left.index, right.index, spacing.size)
}

// shape places the characters of a text: it writes the placed glyphs that
// fit from the start of placed, and gives the count of the full answer
// (one for each character, and one for each invalid sequence) and the
// width of the text, the sum of the advances. ok is false for a text of
// more than TEXT_LIMIT bytes: nothing is written. Each character of the
// text is decoded once: a text that another thread changes during the call
// gives other glyphs, and never a place past the text.
shape :: proc "contextless" (spacing: ^Spacing, text: []u8, placed: []Placed_Glyph) -> (count: int, width: i64, ok: bool) {
	if len(text) > TEXT_LIMIT {
		return 0, 0, false
	}
	x: i64
	place := 0
	character, length, valid := text_encoding.character_decode(text, place)
	if length == 0 {
		return 0, 0, true
	}
	current := resolve(spacing, character, valid)
	for length > 0 {
		next_place := place + length
		next_character, next_length, next_valid := text_encoding.character_decode(text, next_place)
		glyph_advance := current.advance
		next: Resolved
		if next_length > 0 {
			next = resolve(spacing, next_character, next_valid)
			glyph_advance += pair_of(spacing, current, next)
		}
		if count < len(placed) {
			placed[count] = {glyph = current.glyph, x = i32(x), advance = glyph_advance, cluster = u32(place)}
		}
		count += 1
		x += i64(glyph_advance)
		current, place, length = next, next_place, next_length
	}
	return count, x, true
}

// text_width gives the width of a text in 1/64 of a pixel: the sum of the
// advances that shape gives, with no placed glyph written. ok is false for
// a text of more than TEXT_LIMIT bytes.
text_width :: proc "contextless" (spacing: ^Spacing, text: []u8) -> (width: i64, ok: bool) {
	_, width, ok = shape(spacing, text, nil)
	return
}

// Range_Problem: why measure_ranges stopped.
Range_Problem :: enum u8 {
	None, // Each range was measured.
	Past_The_Text, // A range names bytes after the end of the text.
	Too_Long, // A range has more than TEXT_LIMIT bytes.
}

// measure_ranges writes the width of each range of a table of bytes, in
// one call: a window measures all its labels at once. Each range record is
// read once. It stops at the first range that names bytes past the text,
// or has more than TEXT_LIMIT bytes, and gives its index and its end.
measure_ranges :: proc "contextless" (spacing: ^Spacing, text: []u8, ranges: []Text_Range) -> (problem: Range_Problem, index: int, end: u64) {
	for &range, number in ranges {
		copied := intrinsics.volatile_load(&range)
		end = u64(copied.start) + u64(copied.count)
		if end > u64(len(text)) {
			return .Past_The_Text, number, end
		}
		if copied.count > TEXT_LIMIT {
			return .Too_Long, number, u64(copied.count)
		}
		width, _ := text_width(spacing, text[copied.start:end])
		range.width = width
	}
	return .None, len(ranges), 0
}

// text_fit gives the bytes of the longest start of a text whose width is
// at most room, in 1/64 of a pixel: whole characters, so a cut never
// splits one. 0 for a room below the first advance.
text_fit :: proc "contextless" (spacing: ^Spacing, text: []u8, room: i64) -> (count: int) {
	if len(text) > TEXT_LIMIT {
		return 0
	}
	x: i64
	place := 0
	character, length, valid := text_encoding.character_decode(text, place)
	if length == 0 {
		return 0
	}
	current := resolve(spacing, character, valid)
	for length > 0 {
		next_place := place + length
		next_character, next_length, next_valid := text_encoding.character_decode(text, next_place)
		glyph_advance := current.advance
		next: Resolved
		if next_length > 0 {
			next = resolve(spacing, next_character, next_valid)
		}
		// The pair with the next character moves the next glyph, not the
		// end of this one: a start that ends here has no pair after it.
		if x + i64(glyph_advance) > room {
			return place
		}
		if next_length > 0 {
			glyph_advance += pair_of(spacing, current, next)
		}
		x += i64(glyph_advance)
		current, place, length = next, next_place, next_length
	}
	return place
}
