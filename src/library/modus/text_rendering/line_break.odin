package text_rendering

import "modus:contract/text_encoding"

// The breaks of the lines of a text in a box (docs/INTERFACE.md, "The text
// in a box"; src/md/features/text_box.md): the text goes on more lines
// inside the width of the box. The lines of a text, joined, are the text
// without the spaces at a break: no break drops a byte. A break is always
// between two whole characters: the bytes that the rule searches (a space,
// `/`, `:`, `_`) are each a whole character of UTF-8, and the fit gives
// whole characters.

// is_path_break says if a line can end after a byte of a word: the
// separators of a path, of a place in a source and of a name of the system.
is_path_break :: proc "contextless" (character: u8) -> bool {
	return character == '/' || character == ':' || character == '_'
}

// line_break gives the end of the first line of a text in a box of room
// (1/64 of a pixel), with no space at its end, and the start of the rest,
// after the spaces of the break. The line ends at the last space that
// fits. A word that is wider than the box starts on the line of the word
// before it, and ends a line after its last `/`, `:` or `_` that fits;
// with none, at its last character that fits. A line has at least one
// character, also in a box narrower than a character: the rest is always
// shorter than the text, so a loop over the lines ends.
line_break :: proc "contextless" (spacing: ^Spacing, text: []u8, room: i64) -> (line_end, rest_start: int) {
	if len(text) == 0 {
		return 0, 0
	}
	count := text_fit(spacing, text, room)
	if count == len(text) {
		return len(text), len(text)
	}
	at_space := 0 // The bytes of the line that ends at the last space; 0: none.
	if text[count] == ' ' {
		at_space = count
	}
	for index := count - 1; at_space == 0 && index > 0; index -= 1 {
		if text[index] == ' ' {
			at_space = index
		}
	}
	in_word := 0 // The bytes of the line that ends after the last separator; 0: none.
	for index := count - 1; in_word == 0 && index >= at_space && index >= 0; index -= 1 {
		if is_path_break(text[index]) {
			in_word = index + 1
		}
	}
	end := at_space
	if at_space != 0 && in_word > at_space {
		// The last word of the line has a separator. If the whole word has
		// room on a line of its own, it goes there; else it is broken here,
		// so that the line of the word before it is not left short.
		word_start := at_space
		for word_start < len(text) && text[word_start] == ' ' {
			word_start += 1
		}
		word_end := word_start
		for word_end < len(text) && text[word_end] != ' ' {
			word_end += 1
		}
		if width, _ := text_width(spacing, text[word_start:word_end]); width > room {
			end = in_word
		}
	}
	if end == 0 {
		// At least the first character, whole.
		_, first_length, _ := text_encoding.character_decode(text, 0)
		end = in_word != 0 ? in_word : max(count, first_length)
	}
	line_end, rest_start = end, end
	for line_end > 1 && text[line_end - 1] == ' ' {
		line_end -= 1
	}
	for rest_start < len(text) && text[rest_start] == ' ' {
		rest_start += 1
	}
	return line_end, rest_start
}
