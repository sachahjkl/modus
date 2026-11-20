// The characters that each font of the system draws, and their character
// index (docs/glossary/text.md, "Character index"): the numbers that key
// each table of a font. The Spleen data, the shaper, the subsets of the
// tool and the measures of the fonts key by them.
//
// The characters are fixed: the printable characters of ASCII, 32 to 126,
// the Latin-1 Supplement, U+00A0 to U+00FF, and the added characters
// (added_characters): the euro sign. Their character index is 0 to 94,
// then 95 to 190, then 191 for the euro sign. Another character has no
// character index: it takes the fallback chain of its face, or the
// replacement glyph (src/md/data/text_encoding.md).
package font_characters

// The two ranges of the characters.
ASCII_FIRST :: 32 // The space.
ASCII_LAST :: 126 // The tilde.
LATIN_FIRST :: 0xA0 // The first character of the Latin-1 Supplement: the space with no break.
LATIN_LAST :: 0xFF // The last one: y with a diaeresis.
ASCII_COUNT :: ASCII_LAST - ASCII_FIRST + 1 // 95: the character index of LATIN_FIRST.
ADDED_FIRST_INDEX :: ASCII_COUNT + LATIN_LAST - LATIN_FIRST + 1 // 191: the character index of the first added character.
// The added characters: the characters past the Latin-1 Supplement that
// each font draws. Each one is chosen, not a range: the characters that a
// language of the layouts needs past Latin-1 are far apart in Unicode, and
// a range would hold thousands that the fonts of the system do not draw.
// The list is in the order of the code points: the character map of a
// subset needs its segments in that order, and a reader can search the
// list by halves. A character added to the list moves the index of each
// character after it.
EURO_SIGN :: 0x20AC
ADDED_COUNT :: 1
@(rodata)
added_characters := [ADDED_COUNT]rune{EURO_SIGN}
CHARACTER_COUNT :: ADDED_FIRST_INDEX + ADDED_COUNT // 192: the characters of each font.

// character_index gives the character index of a character: 0 to 94 for
// 32 to 126, then 95 to 190 for U+00A0 to U+00FF, then the added
// characters from ADDED_FIRST_INDEX, in the order of their list. found is
// false for each other character: a control character, and each character
// past U+00FF that the list does not name.
character_index :: #force_inline proc "contextless" (character: rune) -> (index: int, found: bool) {
	switch character {
	case ASCII_FIRST ..= ASCII_LAST:
		return int(character) - ASCII_FIRST, true
	case LATIN_FIRST ..= LATIN_LAST:
		return int(character) - LATIN_FIRST + ASCII_COUNT, true
	}
	if character > LATIN_LAST {
		for added, offset in added_characters {
			if added == character {
				return ADDED_FIRST_INDEX + offset, true
			}
		}
	}
	return 0, false
}

// character_of_index gives the character of a character index; found is
// false for an index past the last character, and for a negative index.
character_of_index :: proc "contextless" (index: int) -> (character: rune, found: bool) {
	switch {
	case index >= 0 && index < ASCII_COUNT:
		return rune(index + ASCII_FIRST), true
	case index >= ASCII_COUNT && index < ADDED_FIRST_INDEX:
		return rune(index - ASCII_COUNT + LATIN_FIRST), true
	case index >= ADDED_FIRST_INDEX && index < CHARACTER_COUNT:
		return added_characters[index - ADDED_FIRST_INDEX], true
	}
	return 0, false
}
