#+build !freestanding
package glyph_cache

import "core:testing"

// The character index has no hole and covers the two ranges: each index
// gives a character whose index is that index, and the characters at the
// borders of the two ranges are in or out as the contract says.
@(test)
the_character_index_covers_two_ranges :: proc(t: ^testing.T) {
	for index in 0 ..< CHARACTER_COUNT {
		character, found := character_of_index(index)
		testing.expect(t, found)
		back, in_cache := character_index(character)
		testing.expect(t, in_cache)
		testing.expect_value(t, back, index)
	}
	_, past := character_of_index(CHARACTER_COUNT)
	testing.expect(t, !past)
	_, before := character_of_index(-1)
	testing.expect(t, !before)
	first_latin, _ := character_index(LATIN_FIRST)
	testing.expect_value(t, first_latin, ASCII_COUNT)
	e_acute, _ := character_index('é')
	testing.expect_value(t, e_acute, ASCII_COUNT + 'é' - LATIN_FIRST)
	outside := [?]rune{0, ASCII_FIRST - 1, ASCII_LAST + 1, LATIN_FIRST - 1, LATIN_LAST + 1, 0xFFFD, -1}
	for character in outside {
		_, found := character_index(character)
		testing.expectf(t, !found, "%v is not a character of a cache", character)
	}
}
