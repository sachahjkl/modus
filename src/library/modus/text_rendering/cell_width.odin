package text_rendering

import "modus:contract/text_encoding"

// The cells of a character in a grid of cells: a terminal gives each
// character the cells of its East Asian Width (Unicode Standard Annex 11).
// A wide or fullwidth character (an ideograph, a kana, a syllable of
// Hangul, a fullwidth form) takes two columns, a combining mark or a
// character of no width takes none, and each other character takes one.
//
// The table holds the ranges that a terminal meets, not each assignment of
// the annex: a character out of the table takes one cell, as an ambiguous
// character does in a terminal of the West. A character that no font of
// the chain has is drawn as the replacement glyph in its cells, two for an
// ideograph: the columns of a line stay the columns of the text.

// The cells that one character takes in a grid of cells.
Cell_Width :: enum u8 {
	Zero = 0, // A combining mark, a joiner, a variation selector: no cell; it belongs to the character before it.
	One  = 1, // Each character out of the table.
	Two  = 2, // A wide or fullwidth character.
}

// One range of characters and its cells: first and last are in the range.
Cell_Width_Range :: struct {
	first, last: rune,
	width:       Cell_Width,
}

// The ranges, in order and apart: the search halves them. Zero for the
// combining marks; Two for East Asian Wide (W) and Fullwidth (F).
@(rodata)
cell_width_ranges := [?]Cell_Width_Range {
	{0x0300, 0x036F, .Zero}, // Combining Diacritical Marks.
	{0x1100, 0x115F, .Two}, // The leading consonants of Hangul Jamo.
	{0x1AB0, 0x1AFF, .Zero}, // Combining Diacritical Marks Extended.
	{0x1DC0, 0x1DFF, .Zero}, // Combining Diacritical Marks Supplement.
	{0x200B, 0x200F, .Zero}, // The zero width space, joiners and marks of direction.
	{0x20D0, 0x20FF, .Zero}, // Combining Diacritical Marks for Symbols.
	{0x2E80, 0x303E, .Two}, // CJK Radicals, Kangxi Radicals, CJK Symbols and Punctuation.
	{0x3040, 0x30FF, .Two}, // Hiragana and Katakana.
	{0x3100, 0x33FF, .Two}, // Bopomofo, Hangul Compatibility Jamo, Kanbun, CJK Strokes, Enclosed CJK, CJK Compatibility.
	{0x3400, 0x4DBF, .Two}, // CJK Unified Ideographs Extension A.
	{0x4E00, 0x9FFF, .Two}, // CJK Unified Ideographs.
	{0xA000, 0xA4CF, .Two}, // Yi Syllables and Yi Radicals.
	{0xAC00, 0xD7A3, .Two}, // Hangul Syllables.
	{0xF900, 0xFAFF, .Two}, // CJK Compatibility Ideographs.
	{0xFE00, 0xFE0F, .Zero}, // Variation Selectors.
	{0xFE20, 0xFE2F, .Zero}, // Combining Half Marks.
	{0xFE30, 0xFE4F, .Two}, // CJK Compatibility Forms.
	{0xFF01, 0xFF60, .Two}, // Fullwidth Forms.
	{0xFFE0, 0xFFE6, .Two}, // Fullwidth Signs.
	{0x1F300, 0x1F64F, .Two}, // Pictographs and Emoticons.
	{0x1F900, 0x1F9FF, .Two}, // Supplemental Symbols and Pictographs.
	{0x20000, 0x2FFFD, .Two}, // The Supplementary Ideographic Plane.
	{0x30000, 0x3FFFD, .Two}, // The Tertiary Ideographic Plane.
}

// cell_width_of gives the cells of one character. A value that is no code
// point (negative, a surrogate, past U+10FFFF) takes one cell: a terminal
// draws it as the replacement character.
cell_width_of :: proc "contextless" (character: rune) -> Cell_Width {
	if is_mark(character) {
		return .Zero // Each mark of Unicode, of each script (unicode_tables.odin).
	}
	low, high := 0, len(cell_width_ranges)
	for low < high {
		middle := (low + high) / 2
		range := cell_width_ranges[middle]
		switch {
		case character < range.first:
			high = middle
		case character > range.last:
			low = middle + 1
		case:
			return range.width
		}
	}
	return .One
}

// cell_part gives the start of a text of UTF-8 that fits in room cells: its
// bytes and its cells. It ends after a whole character; a wide character
// that finds one cell left is not in it, so a writer that cuts a line into
// rows starts the next row with it. bytes is 0 when the first character
// does not fit; a character of no width after the part goes with it.
cell_part :: proc "contextless" (text: []u8, room: int) -> (bytes: int, cells: int) {
	for bytes < len(text) {
		character, length, _ := text_encoding.character_decode(text, bytes)
		width := int(cell_width_of(character))
		if cells + width > room {
			break
		}
		bytes += max(length, 1)
		cells += width
	}
	return
}

// cell_count gives the cells of a text of UTF-8: the sum of the cells of
// its characters. An invalid sequence is one cell of the replacement
// character.
cell_count :: proc "contextless" (text: []u8) -> int {
	cells := 0
	has_base := false
	for place := 0; place < len(text); {
		character, length, valid := text_encoding.character_decode(text, place)
		width := int(cell_width_of(character))
		// A mark with no base stands on a dotted circle, which takes one
		// cell (cluster_read).
		if width == 0 && !has_base {
			width = 1
		}
		has_base = width > 0 && valid && !is_cluster_break(character) || width == 0
		cells += width
		place += max(length, 1)
	}
	return cells
}
