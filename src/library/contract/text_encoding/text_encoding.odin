// The text encoding: the one form of a text in every contract of the system
// (src/md/data/text_encoding.md). A text is UTF-8. Its length is a count of
// bytes. A party that takes a text from another party checks it with
// `text_valid` or `invalid_sequence_find` before its use, and a party that cuts a text
// cuts it with `complete_characters`, never inside a character.
//
// **The rule of a character of a text.** A character is one well-formed
// UTF-8 sequence, as RFC 3629 defines it:
//
//   00..7F
//   C2..DF  80..BF
//   E0      A0..BF  80..BF
//   E1..EC  80..BF  80..BF
//   ED      80..9F  80..BF
//   EE..EF  80..BF  80..BF
//   F0      90..BF  80..BF  80..BF
//   F1..F3  80..BF  80..BF  80..BF
//   F4      80..8F  80..BF  80..BF
//
// An invalid sequence is bytes that are no character of a text: an
// overlong form (C0, C1, E0 80..9F, F0 80..8F), a surrogate (ED A0..BF), a
// code point above U+10FFFF (F4 90.., F5..FF), a lone continuation byte, a
// sequence cut short, and a control character: U+0000 to U+001F, U+007F
// and U+0080 to U+009F. So a text holds no line feed
// and no tab: a line is a record, and its end is a record or a field, never
// a byte. Each other code point is a character of a text, whether a font
// draws it or not.
//
// The kernel and the processes share this package: the kernel checks the
// text of a line of the log with it, and the palette table, the store and
// the cut mark use it.
package text_encoding

// The character that a reader draws for an invalid sequence, and for a character that
// the font lacks: one replacement glyph (src/md/data/text_encoding.md).
REPLACEMENT_CHARACTER :: rune(0xFFFD)

// The most bytes of one character.
CHARACTER_BYTES_LIMIT :: 4

// The last code point of Unicode.
CODE_POINT_LAST :: 0x10FFFF

// character_in_text says if a code point is a character of a text: no
// control character, no surrogate, nothing above U+10FFFF.
character_in_text :: proc "contextless" (character: rune) -> bool {
	control := character < 0x20 || character >= 0x7F && character <= 0x9F
	surrogate := character >= 0xD800 && character <= 0xDFFF
	return !control && !surrogate && character <= CODE_POINT_LAST
}

// character_decode reads the character that starts at place. A
// well-formed sequence gives its code point and its length; valid is false
// when it is a control character, and the character is then
// REPLACEMENT_CHARACTER with the length of the sequence. A byte that starts
// no well-formed sequence is an invalid sequence of one byte: REPLACEMENT_CHARACTER,
// length 1, valid false. A place outside the bytes gives length 0. Each
// byte is read once: the bytes can be in memory that another party writes,
// and a second read could see another byte.
character_decode :: proc "contextless" (bytes: []u8, place: int) -> (character: rune, length: int, valid: bool) {
	if place < 0 || place >= len(bytes) {
		return REPLACEMENT_CHARACTER, 0, false
	}
	rest := len(bytes) - place
	lead := bytes[place]
	switch {
	case lead < 0x80:
		character, length = rune(lead), 1
	case lead >= 0xC2 && lead <= 0xDF:
		if rest < 2 {
			return REPLACEMENT_CHARACTER, 1, false
		}
		second := bytes[place + 1]
		if second & 0xC0 != 0x80 {
			return REPLACEMENT_CHARACTER, 1, false
		}
		character, length = rune(lead & 0x1F) << 6 | rune(second & 0x3F), 2
	case lead >= 0xE0 && lead <= 0xEF:
		if rest < 3 {
			return REPLACEMENT_CHARACTER, 1, false
		}
		second, third := bytes[place + 1], bytes[place + 2]
		// E0 starts no overlong form, and ED no surrogate.
		low, high := u8(0x80), u8(0xBF)
		if lead == 0xE0 {
			low = 0xA0
		} else if lead == 0xED {
			high = 0x9F
		}
		if second < low || second > high || third & 0xC0 != 0x80 {
			return REPLACEMENT_CHARACTER, 1, false
		}
		character, length = rune(lead & 0x0F) << 12 | rune(second & 0x3F) << 6 | rune(third & 0x3F), 3
	case lead >= 0xF0 && lead <= 0xF4:
		if rest < 4 {
			return REPLACEMENT_CHARACTER, 1, false
		}
		second, third, fourth := bytes[place + 1], bytes[place + 2], bytes[place + 3]
		// F0 starts no overlong form, and F4 nothing above U+10FFFF.
		low, high := u8(0x80), u8(0xBF)
		if lead == 0xF0 {
			low = 0x90
		} else if lead == 0xF4 {
			high = 0x8F
		}
		if second < low || second > high || third & 0xC0 != 0x80 || fourth & 0xC0 != 0x80 {
			return REPLACEMENT_CHARACTER, 1, false
		}
		character, length = rune(lead & 0x07) << 18 | rune(second & 0x3F) << 12 | rune(third & 0x3F) << 6 | rune(fourth & 0x3F), 4
	case:
		// 80..BF: a continuation with no lead; C0, C1: only overlong
		// forms; F5..FF: above U+10FFFF or no UTF-8 at all.
		return REPLACEMENT_CHARACTER, 1, false
	}
	if !character_in_text(character) {
		return REPLACEMENT_CHARACTER, length, false
	}
	return character, length, true
}

// invalid_sequence_find gives the place of the first byte of the first invalid sequence of a
// text: a byte that starts no well-formed sequence, or a control
// character. found is false for a text with no invalid sequence.
invalid_sequence_find :: proc "contextless" (bytes: []u8) -> (place: int, found: bool) {
	for place < len(bytes) {
		_, length, valid := character_decode(bytes, place)
		if !valid {
			return place, true
		}
		place += length
	}
	return 0, false
}

// text_valid says if a text has no invalid sequence: the check of a text at a border.
text_valid :: proc "contextless" (bytes: []u8) -> bool {
	_, found := invalid_sequence_find(bytes)
	return !found
}

// invalid_sequences_replace writes "?" in place of each byte of each invalid sequence of a
// text, so that it becomes valid with the same length: a writer that must
// keep each offset (the value runs of a line of the log) cleans a text so.
// A reader that draws uses the replacement glyph instead.
invalid_sequences_replace :: proc "contextless" (bytes: []u8) {
	place := 0
	for place < len(bytes) {
		_, length, valid := character_decode(bytes, place)
		if !valid {
			for &value in bytes[place:][:length] {
				value = '?'
			}
		}
		place += length
	}
}

// complete_characters gives the length of the longest start of bytes that
// ends after a whole character: a character whose first byte is in bytes
// and whose last byte is not is left out. The one way to cut a text: a
// writer that has room for limit bytes keeps complete_characters(text[:limit])
// bytes. An invalid sequence is not a character that started: a text with invalid sequences is
// kept as it is, and its check refuses it elsewhere.
complete_characters :: proc "contextless" (bytes: []u8) -> int {
	count := len(bytes)
	if count == 0 {
		return 0
	}
	start := count - 1
	for start > 0 && count - start < CHARACTER_BYTES_LIMIT && bytes[start] & 0xC0 == 0x80 {
		start -= 1
	}
	lead := bytes[start]
	length := 1
	switch {
	case lead & 0xE0 == 0xC0:
		length = 2
	case lead & 0xF0 == 0xE0:
		length = 3
	case lead & 0xF8 == 0xF0:
		length = 4
	}
	if start + length > count {
		return start
	}
	return count
}

// identifier_valid says if a name is an identifier of the system: one or
// more visible characters of ASCII, 33 to 126. An identifier (a module, a
// process, a setting, a value of a setting, an act name) is matched byte
// for byte against what a principal types in each layout, so it has one
// form only: é is one code point or an e with a combining accent, two
// forms of one name (src/md/data/text_encoding.md, "The chosen form").
identifier_valid :: proc "contextless" (bytes: []u8) -> bool {
	for value in bytes {
		if value <= ' ' || value > '~' {
			return false
		}
	}
	return len(bytes) > 0
}

// identifier_words_valid says if a name is identifiers joined by spaces:
// printable characters of ASCII, 32 to 126. The title of a setting
// ("subpixel order") and the name of a palette entry ("set font to
// spleen") are such names.
identifier_words_valid :: proc "contextless" (bytes: []u8) -> bool {
	for value in bytes {
		if value < ' ' || value > '~' {
			return false
		}
	}
	return true
}

// character_count gives the characters of a text as a reader draws them:
// one cell for each character, and one for each invalid sequence.
character_count :: proc "contextless" (bytes: []u8) -> int {
	count, place := 0, 0
	for place < len(bytes) {
		_, length, _ := character_decode(bytes, place)
		place += length
		count += 1
	}
	return count
}

// character_encode writes the UTF-8 sequence of a character at the start
// of buffer and gives its length: 0 for a code point that is no character
// of a text (character_in_text), or a buffer too small.
character_encode :: proc "contextless" (character: rune, buffer: []u8) -> int {
	if !character_in_text(character) {
		return 0
	}
	value := u32(character)
	switch {
	case value < 0x80:
		if len(buffer) < 1 {
			return 0
		}
		buffer[0] = u8(value)
		return 1
	case value < 0x800:
		if len(buffer) < 2 {
			return 0
		}
		buffer[0] = u8(0xC0 | value >> 6)
		buffer[1] = u8(0x80 | value & 0x3F)
		return 2
	case value < 0x10000:
		if len(buffer) < 3 {
			return 0
		}
		buffer[0] = u8(0xE0 | value >> 12)
		buffer[1] = u8(0x80 | value >> 6 & 0x3F)
		buffer[2] = u8(0x80 | value & 0x3F)
		return 3
	}
	if len(buffer) < 4 {
		return 0
	}
	buffer[0] = u8(0xF0 | value >> 18)
	buffer[1] = u8(0x80 | value >> 12 & 0x3F)
	buffer[2] = u8(0x80 | value >> 6 & 0x3F)
	buffer[3] = u8(0x80 | value & 0x3F)
	return 4
}
