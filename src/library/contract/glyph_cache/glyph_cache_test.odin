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
	euro, euro_found := character_index('€')
	testing.expect(t, euro_found)
	testing.expect_value(t, euro, ADDED_FIRST_INDEX)
	testing.expect_value(t, CHARACTER_COUNT, ADDED_FIRST_INDEX + len(added_characters))
	outside := [?]rune{0, ASCII_FIRST - 1, ASCII_LAST + 1, LATIN_FIRST - 1, LATIN_LAST + 1, EURO_SIGN - 1, EURO_SIGN + 1, 0xFFFD, -1}
	for character in outside {
		_, found := character_index(character)
		testing.expectf(t, !found, "%v is not a character of a cache", character)
	}
}

// The list of the added characters keeps its rules: each one past the
// Latin-1 Supplement, in the order of the code points with no repeat, and
// in the basic plane, which the character map of a subset (format 4)
// holds.
@(test)
the_added_characters_are_in_order :: proc(t: ^testing.T) {
	previous := rune(LATIN_LAST)
	for character in added_characters {
		testing.expectf(t, character > previous, "U+%04X comes after U+%04X", int(character), int(previous))
		testing.expectf(t, character < 0xFFFF && (character < 0xD800 || character > 0xDFFF), "U+%04X is a character of the basic plane", int(character))
		previous = character
	}
}
