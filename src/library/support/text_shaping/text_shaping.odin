// Text shaping (docs/FONTS.md, section 12.3): the characters of a text
// become placed glyphs, with the advance of each character and the pair
// adjustment of each pair of characters that follow each other. The text
// is UTF-8 (src/library/contract/text_encoding). No ligature and no other
// script: one placed glyph for each character, and one for each invalid sequence.
//
// A program that links this package calls it directly, over the spacing of
// a glyph cache that it validated (spacing_of). The module text_shaping
// gives the same functions as exports over tables of the caller.
//
// The spacing can be in memory that another thread changes during a call:
// in an isolated call the tables are in the call region. So no value is
// checked once and trusted later: each advance and each pair is read once,
// and kept in its limits at that read. A changed table gives other numbers,
// never a read out of the tables and never a sum that wraps.
package text_shaping

import "base:intrinsics"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"

FIRST_CHARACTER :: 32 // The first character of a glyph cache: the space.
CHARACTER_COUNT :: glyph_cache.CHARACTER_LIMIT // The characters of a glyph cache: 32 to 126.
// The glyph of a character that the cache does not hold, and of each invalid sequence
// of the text: the reader draws the replacement glyph in its place
// (graphics.character_replacement), so that a reader sees that a character
// is there that the font does not draw. It has the advance of
// REPLACEMENT_ADVANCE_CHARACTER, and no pair.
REPLACEMENT_GLYPH :: max(u32)
REPLACEMENT_ADVANCE_CHARACTER :: '0'
// The most bytes of one text. With an advance and a pair adjustment of at
// most glyph_cache.ADVANCE_LIMIT each, the place of the last glyph stays
// in an i32 of 1/64 of a pixel.
TEXT_LIMIT :: 1 << 16
#assert(TEXT_LIMIT * 2 * glyph_cache.ADVANCE_LIMIT < 1 << 31)

// Placed_Glyph: one character of a text, placed. x is from the origin of
// the text; advance includes the pair adjustment with the next character;
// so the x of a glyph is the sum of the advances before it.
Placed_Glyph :: struct {
	glyph:   u32, // The index of the character in the glyph cache: character - 32. REPLACEMENT_GLYPH: a character outside the cache.
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

// Character_Advance: one advance, as the record of a table.
Character_Advance :: struct {
	advance: i32, // In 1/64 of a pixel.
}

// Spacing: the advances of the characters 32 to 126 and the pairs of one
// font at one scale, sorted by left then right.
Spacing :: struct {
	advances: []i32, // CHARACTER_COUNT of them.
	pairs:    []glyph_cache.Pair_Entry, // The pair adjustments, sorted by left then right character.
}

// spacing_of gives the spacing of one scale of a valid glyph cache. ok is
// false for a cache of other characters than 32 to 126, or a scale that it
// does not have.
spacing_of :: proc "contextless" (cache: ^glyph_cache.Cache, scale: int) -> (spacing: Spacing, ok: bool) {
	if cache.header.first_character != FIRST_CHARACTER || cache.header.character_count != CHARACTER_COUNT {
		return {}, false
	}
	advances := glyph_cache.advances_of(cache, scale)
	if len(advances) != CHARACTER_COUNT {
		return {}, false
	}
	return {advances = advances, pairs = glyph_cache.pairs_of(cache, scale)}, true
}

// glyph_of gives the glyph of a character: its index in the cache, or
// REPLACEMENT_GLYPH.
glyph_of :: #force_inline proc "contextless" (character: rune) -> u32 {
	if character < FIRST_CHARACTER || character >= FIRST_CHARACTER + CHARACTER_COUNT {
		return REPLACEMENT_GLYPH
	}
	return u32(character - FIRST_CHARACTER)
}

// advance_of gives the advance of a glyph, read once, from 0 to
// glyph_cache.ADVANCE_LIMIT.
@(private)
advance_of :: #force_inline proc "contextless" (spacing: ^Spacing, glyph_given: u32) -> i32 {
	glyph := glyph_given == REPLACEMENT_GLYPH ? u32(REPLACEMENT_ADVANCE_CHARACTER - FIRST_CHARACTER) : glyph_given
	if int(glyph) >= len(spacing.advances) {
		return 0
	}
	return clamp(intrinsics.volatile_load(&spacing.advances[glyph]), 0, glyph_cache.ADVANCE_LIMIT)
}

// pair_of gives the adjustment of the pair of two glyphs, from
// -glyph_cache.ADVANCE_LIMIT to glyph_cache.ADVANCE_LIMIT: a binary search
// in the sorted pairs, each pair read once. Pairs out of order give a
// wrong adjustment, never a read out of the table.
@(private)
pair_of :: proc "contextless" (spacing: ^Spacing, left, right: u32) -> i32 {
	if left >= CHARACTER_COUNT || right >= CHARACTER_COUNT {
		return 0 // The replacement glyph has no pair.
	}
	key := (left + FIRST_CHARACTER) << 8 | (right + FIRST_CHARACTER)
	low, high := 0, len(spacing.pairs)
	for low < high {
		middle := low + (high - low) / 2
		pair := intrinsics.volatile_load(&spacing.pairs[middle])
		pair_key := u32(pair.left) << 8 | u32(pair.right)
		switch {
		case pair_key == key:
			return clamp(pair.adjustment, -glyph_cache.ADVANCE_LIMIT, glyph_cache.ADVANCE_LIMIT)
		case pair_key < key:
			low = middle + 1
		case:
			high = middle
		}
	}
	return 0
}

// shape places the characters of a text: it writes the placed glyphs that
// fit from the start of placed, and gives the count of the full answer
// (one for each character, and one for each invalid sequence) and the width of the
// text, the sum of the advances. ok is false for a text of more than
// TEXT_LIMIT bytes: nothing is written. Each character of the text is
// decoded once: a text that another thread changes during the call gives
// other glyphs, each one a glyph of the cache or REPLACEMENT_GLYPH, and
// never a place past the text.
shape :: proc "contextless" (spacing: ^Spacing, text: []u8, placed: []Placed_Glyph) -> (count: int, width: i64, ok: bool) {
	if len(text) > TEXT_LIMIT {
		return 0, 0, false
	}
	x: i64
	place := 0
	character, length, _ := text_encoding.character_decode(text, place)
	glyph := glyph_of(character)
	for length > 0 {
		next_place := place + length
		next_character, next_length, _ := text_encoding.character_decode(text, next_place)
		advance := advance_of(spacing, glyph)
		next: u32
		if next_length > 0 {
			next = glyph_of(next_character)
			advance += pair_of(spacing, glyph, next)
		}
		if count < len(placed) {
			placed[count] = {glyph = glyph, x = i32(x), advance = advance, cluster = u32(place)}
		}
		count += 1
		x += i64(advance)
		glyph, place, length = next, next_place, next_length
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
