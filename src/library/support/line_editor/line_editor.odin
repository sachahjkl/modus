// The line that the input edits in a text program: the bytes, the caret
// inside them, and the keys that change them. The package also finds the
// name at the caret that a completion can replace, and the call that the
// caret is in (line_context.odin), keeps the history of the lines
// (history.odin), and orders the names that match what the input typed
// (fuzzy_match.odin).
//
// The package has no state of its own and makes no kernel call: each
// procedure takes a record in the memory of the caller. So the host tests
// run each key, and a program can keep several lines.
//
// The caller can write in each record: each procedure first brings the
// counts back inside their arrays, and never writes past an array.
//
// The text of a line is UTF-8 (src/md/data/text_encoding.md, "The chosen
// form"). The caret is a place in bytes, before a whole
// character; each key moves it, removes or inserts a whole character.
package line_editor

import "modus:contract/text_encoding"

// The bytes of one line. A text program can show a line of this length
// after a prompt of a few characters, in one terminal record.
LINE_CAPACITY :: 200

// One line that the input edits, in the memory of the caller.
Line :: struct {
	bytes:  [LINE_CAPACITY]u8, // The bytes of the line: UTF-8.
	count:  int, // The bytes of the line.
	caret: int, // The place of the caret in bytes: 0 is before the first character, count after the last.
}

// The keys that edit a line. The caller translates the codes of its keys:
// the package does not depend on a keyboard.
Edit_Key :: enum u8 {
	None      = 0, // No key: nothing changes.
	Left      = 1, // The caret goes one character to the left.
	Right     = 2, // The caret goes one character to the right.
	Home      = 3, // The caret goes before the first character.
	End       = 4, // The caret goes after the last character.
	Backspace = 5, // The character before the caret goes.
	Delete    = 6, // The character after the caret goes.
	Character = 7, // A printable character goes in at the caret.
}

// line_repair brings the count and the caret of a line inside its bytes,
// and the caret to the start of a character.
line_repair :: proc "contextless" (line: ^Line) {
	line.count = clamp(line.count, 0, LINE_CAPACITY)
	line.caret = clamp(line.caret, 0, line.count)
	line.caret = character_start_before(line.bytes[:line.count], line.caret)
}

// line_text gives the bytes of the line. The text changes with the line.
line_text :: proc "contextless" (line: ^Line) -> string {
	line_repair(line)
	return string(line.bytes[:line.count])
}

// line_caret_column gives the cell of the caret: the count of the
// characters before it. A reader that draws the line in cells places its
// cursor there, not at the count of the bytes.
line_caret_column :: proc "contextless" (line: ^Line) -> int {
	line_repair(line)
	return text_encoding.character_count(line.bytes[:line.caret])
}

// printable says if a code point is a character that a line holds: a
// character of a text, with no control character. A character that no font
// draws is printable: the drawing shows the replacement glyph for it.
printable :: proc "contextless" (character: rune) -> bool {
	return text_encoding.character_in_text(character)
}

// character_length gives the bytes of the UTF-8 of a character that a line
// holds, or 0 for one that it does not hold.
character_length :: proc "contextless" (character: rune) -> int {
	if !printable(character) {
		return 0
	}
	buffer: [text_encoding.CHARACTER_BYTES_LIMIT]u8
	return text_encoding.character_encode(character, buffer[:])
}

// character_start_before gives the start of the character that holds the
// byte at place, or place itself when a character starts there: each
// character of the text is decoded from the start, so an invalid sequence
// is cut as the drawing cuts it.
@(private)
character_start_before :: proc "contextless" (bytes: []u8, place: int) -> int {
	start := 0
	for start < place {
		_, length, _ := text_encoding.character_decode(bytes, start)
		if length == 0 || start + length > place {
			return start
		}
		start += length
	}
	return start
}

// character_end_after gives the end of the character that starts at place.
@(private)
character_end_after :: proc "contextless" (bytes: []u8, place: int) -> int {
	_, length, _ := text_encoding.character_decode(bytes, place)
	return place + max(length, 1)
}

// line_key applies one key to a line. changed is false when the key
// changes nothing: a caret at an end, a full line, a code point that is
// not printable.
line_key :: proc "contextless" (line: ^Line, key: Edit_Key, character: rune = 0) -> (changed: bool) {
	line_repair(line)
	text := line.bytes[:line.count]
	switch key {
	case .None:
		return false
	case .Left:
		if line.caret == 0 {
			return false
		}
		line.caret = character_start_before(text, line.caret - 1)
	case .Right:
		if line.caret == line.count {
			return false
		}
		line.caret = min(character_end_after(text, line.caret), line.count)
	case .Home:
		if line.caret == 0 {
			return false
		}
		line.caret = 0
	case .End:
		if line.caret == line.count {
			return false
		}
		line.caret = line.count
	case .Backspace:
		if line.caret == 0 {
			return false
		}
		start := character_start_before(text, line.caret - 1)
		copy(line.bytes[start:line.count], line.bytes[line.caret:line.count])
		line.count -= line.caret - start
		line.caret = start
	case .Delete:
		if line.caret == line.count {
			return false
		}
		end := min(character_end_after(text, line.caret), line.count)
		copy(line.bytes[line.caret:line.count], line.bytes[end:line.count])
		line.count -= end - line.caret
	case .Character:
		encoded: [text_encoding.CHARACTER_BYTES_LIMIT]u8
		length := printable(character) ? text_encoding.character_encode(character, encoded[:]) : 0
		if length == 0 || line.count + length > LINE_CAPACITY {
			return false
		}
		// The bytes after the caret move to the right; copy moves bytes
		// that overlap correctly.
		copy(line.bytes[line.caret + length:line.count + length], line.bytes[line.caret:line.count])
		copy(line.bytes[line.caret:line.caret + length], encoded[:length])
		line.caret += length
		line.count += length
	}
	return true
}

// line_set gives the line a new text, and puts the caret after it. A text
// longer than the line is cut after a whole character; each byte of an
// invalid sequence becomes '?'.
line_set :: proc "contextless" (line: ^Line, text: string) {
	line.count = min(len(text), LINE_CAPACITY)
	copy(line.bytes[:line.count], text[:line.count])
	line.count = text_encoding.complete_characters(line.bytes[:line.count])
	text_encoding.invalid_sequences_replace(line.bytes[:line.count])
	line.caret = line.count
}

// line_clear empties the line.
line_clear :: proc "contextless" (line: ^Line) {
	line.count = 0
	line.caret = 0
}

// line_replace puts text in the place of the bytes from start to end, and
// the caret after it. ok is false, and the line does not change, when the
// result does not fit or text is not valid UTF-8 (text_encoding.text_valid).
// start and end are places of whole characters: the caller found them in
// the line.
line_replace :: proc "contextless" (line: ^Line, start, end: int, text: string) -> (ok: bool) {
	line_repair(line)
	first := clamp(start, 0, line.count)
	last := clamp(end, first, line.count)
	if line.count - (last - first) + len(text) > LINE_CAPACITY {
		return false
	}
	if !text_encoding.text_valid(transmute([]u8)text) {
		return false
	}
	rest := line.count - last
	new_end := first + len(text)
	copy(line.bytes[new_end:new_end + rest], line.bytes[last:line.count])
	copy(line.bytes[first:new_end], text)
	line.count = new_end + rest
	line.caret = new_end
	return true
}
