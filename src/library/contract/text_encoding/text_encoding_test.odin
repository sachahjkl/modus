#+build !freestanding
package text_encoding

import "core:testing"

@(private = "file")
bytes_of :: proc(text: string) -> []u8 {
	return transmute([]u8)text
}

// Each text here is valid: the first and the last character of each
// length, the first character after the controls, and a text of several.
@(test)
valid_texts_pass :: proc(t: ^testing.T) {
	texts := [?]string {
		"",
		" ",
		"~",
		"café",
		" ", // C2 A0: the first code point after the controls of C1.
		"߿",
		"ࠀ",
		"퟿", // ED 9F BF: the last code point before the surrogates.
		"",
		"�",
		"￿",
		"\U00010000",
		"\U0001d11e",
		"\U0010ffff", // F4 8F BF BF: the last code point.
		"éèçàù € 中",
	}
	for text in texts {
		testing.expectf(t, text_valid(bytes_of(text)), "the text %q must be valid", text)
	}
}

// Each text here has its first invalid sequence at the place given: overlong forms,
// surrogates, code points above U+10FFFF, lone continuation bytes,
// sequences cut short, a bad continuation, and the controls.
@(test)
hostile_texts_are_refused_at_their_first_invalid_sequence :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		place: int,
	}
	cases := [?]Case {
		{"\xc0\xaf", 0}, // An overlong "/".
		{"\xc1\xbf", 0},
		{"ab\xe0\x80\xaf", 2},
		{"\xe0\x9f\xbf", 0}, // An overlong U+07FF.
		{"\xf0\x80\x80\xaf", 0},
		{"\xf0\x8f\xbf\xbf", 0}, // An overlong U+FFFF.
		{"\xed\xa0\x80", 0}, // U+D800, a surrogate.
		{"x\xed\xbf\xbf", 1}, // U+DFFF.
		{"\xf4\x90\x80\x80", 0}, // U+110000.
		{"\xf5\x80\x80\x80", 0},
		{"\xf8\x88\x80\x80\x80", 0},
		{"\xfe", 0},
		{"\xff", 0},
		{"\x80", 0}, // A continuation with no lead.
		{"a\xbf", 1},
		{"\xc3", 0}, // Cut short.
		{"ok\xe2\x82", 2},
		{"\xf0\x9f\x98", 0},
		{"\xc3\x28", 0}, // A lead, then no continuation.
		{"\xe2\x28\xa1", 0},
		{"\x00", 0}, // The controls of C0, DEL and C1.
		{"a\x09", 1},
		{"a\x0a", 1},
		{"a\x0d", 1},
		{"\x1b[2J", 0},
		{"\x1f", 0},
		{"\x7f", 0},
		{"\xc2\x80", 0}, // U+0080.
		{"\xc2\x85", 0}, // U+0085, the next line of C1.
		{"café\xc2\x9b", 5}, // U+009B, the CSI of C1.
	}
	for one in cases {
		place, found := invalid_sequence_find(bytes_of(one.text))
		testing.expectf(t, found && place == one.place, "the text %q must have its invalid sequence at %d, not %d (found %v)", one.text, one.place, place, found)
		testing.expect(t, !text_valid(bytes_of(one.text)))
	}
}

// A decode gives the code point and its length, and an invalid sequence of one byte.
@(test)
decode_gives_the_character :: proc(t: ^testing.T) {
	text := bytes_of("aé€\U0001d11e\xff")
	character, length, valid := character_decode(text, 1)
	testing.expect(t, character == 0xE9 && length == 2 && valid)
	character, length, valid = character_decode(text, 3)
	testing.expect(t, character == 0x20AC && length == 3 && valid)
	character, length, valid = character_decode(text, 6)
	testing.expect(t, character == 0x1D11E && length == 4 && valid)
	character, length, valid = character_decode(text, 10)
	testing.expect(t, character == REPLACEMENT_CHARACTER && length == 1 && !valid)
	// The middle of a character is an invalid sequence of one byte.
	character, length, valid = character_decode(text, 2)
	testing.expect(t, character == REPLACEMENT_CHARACTER && length == 1 && !valid)
	// A control of C1 is well formed: it takes its two bytes.
	_, length, valid = character_decode(bytes_of("\xc2\x85"), 0)
	testing.expect(t, length == 2 && !valid)
	// Outside the bytes.
	_, length, _ = character_decode(text, len(text))
	testing.expect_value(t, length, 0)
	_, length, _ = character_decode(text, -1)
	testing.expect_value(t, length, 0)
}

// The replacement keeps the length and leaves a valid text.
@(test)
invalid_sequences_are_replaced_in_place :: proc(t: ^testing.T) {
	text := [?]u8{'a', 0xC3, '(', 0xC2, 0x85, 'z', 0x0D, 0xC3, 0xA9, 0xED, 0xA0, 0x80, 0xE2, 0x82}
	invalid_sequences_replace(text[:])
	testing.expect_value(t, string(text[:]), "a?(??z?é?????")
	testing.expect(t, text_valid(text[:]))
}

// A cut never ends inside a character, and keeps a text with invalid sequences whole.
@(test)
a_cut_ends_after_a_whole_character :: proc(t: ^testing.T) {
	testing.expect_value(t, complete_characters(nil), 0)
	testing.expect_value(t, complete_characters(bytes_of("abc")), 3)
	testing.expect_value(t, complete_characters(bytes_of("a\xc3")), 1)
	testing.expect_value(t, complete_characters(bytes_of("aé")), 3)
	testing.expect_value(t, complete_characters(bytes_of("\xe2\x82")), 0)
	testing.expect_value(t, complete_characters(bytes_of("x\xf0\x9f\x98")), 1)
	testing.expect_value(t, complete_characters(bytes_of("x\U0001d11e")), 5)
	testing.expect_value(t, complete_characters(bytes_of("\x80\x80\x80\x80")), 4)
	// Each cut of a valid text is a valid text.
	text := bytes_of("été €\U0001d11e!")
	for limit in 0 ..= len(text) {
		testing.expectf(t, text_valid(text[:complete_characters(text[:limit])]), "the cut at %d must be valid", limit)
	}
}

// An identifier is visible ASCII; words of identifiers may hold spaces.
@(test)
identifiers_are_ascii :: proc(t: ^testing.T) {
	testing.expect(t, identifier_valid(bytes_of("settings.set:font")))
	testing.expect(t, !identifier_valid(nil))
	testing.expect(t, !identifier_valid(bytes_of("a b")))
	testing.expect(t, !identifier_valid(bytes_of("caf\xc3\xa9")))
	testing.expect(t, !identifier_valid(bytes_of("a\x7f")))
	testing.expect(t, !identifier_valid(bytes_of("\x1b[2J")))
	testing.expect(t, identifier_words_valid(bytes_of("set font to spleen")))
	testing.expect(t, identifier_words_valid(nil))
	testing.expect(t, !identifier_words_valid(bytes_of("subpixel\torder")))
	testing.expect(t, !identifier_words_valid(bytes_of("caf\xc3\xa9")))
}

// The count of the cells of a text: one for each character and each invalid sequence.
@(test)
characters_are_counted :: proc(t: ^testing.T) {
	testing.expect_value(t, character_count(bytes_of("café")), 4)
	testing.expect_value(t, character_count(bytes_of("€\U0001d11e")), 2)
	testing.expect_value(t, character_count(bytes_of("\xff\xfe")), 2)
	testing.expect_value(t, character_count(bytes_of("\xe2\x82")), 2)
}

// An encode writes the sequence that a decode reads, and refuses each code
// point that is no character of a text.
@(test)
encode_is_the_reverse_of_decode :: proc(t: ^testing.T) {
	buffer: [CHARACTER_BYTES_LIMIT]u8
	for character in ([]rune{' ', 0xE9, 0xA0, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFD, 0x10000, 0x1D11E, 0x10FFFF}) {
		length := character_encode(character, buffer[:])
		decoded, decoded_length, valid := character_decode(buffer[:length], 0)
		testing.expectf(t, length > 0 && decoded == character && decoded_length == length && valid, "the character %x must round trip", character)
	}
	testing.expect_value(t, character_encode(0xE9, buffer[:]), 2)
	testing.expect_value(t, string(buffer[:2]), "é")
	for refused in ([]rune{0, 0x0A, 0x1F, 0x7F, 0x80, 0x9F, 0xD800, 0xDFFF, 0x110000, -1}) {
		testing.expectf(t, character_encode(refused, buffer[:]) == 0, "the code point %x must be refused", refused)
	}
	testing.expect_value(t, character_encode(0x20AC, buffer[:2]), 0)
}
