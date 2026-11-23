// The line that the input edits in a text process: the bytes, the caret
// inside them, and the keys that change them. The package also finds the
// name at the caret that a completion can replace, and the call that the
// caret is in (line_context.odin), keeps the history of the lines
// (history.odin), and orders the names that match what the input typed
// (fuzzy_match.odin).
//
// The package has no state of its own and makes no kernel call: each
// procedure takes a record in the memory of the caller. So the host tests
// run each key, and a process can keep several lines.
//
// The caller can write in each record: each procedure first brings the
// counts back inside their arrays, and never writes past an array.
//
// The text of a line is UTF-8 (src/md/data/text_encoding.md, "The chosen
// form"). The caret is a place in bytes, before a whole
// character; each key moves it, removes or inserts a whole character.
package line_editor

import "modus:contract/text_encoding"

// The bytes of one line: a pipeline of several stages, a pasted hash with
// a long call, a record literal of many fields. A text process shows a
// part of a longer line around the caret (line_view), so the line does not
// need to fit one terminal record.
LINE_CAPACITY :: 4096

// One line that the input edits, in the memory of the caller.
Line :: struct {
	bytes:            [LINE_CAPACITY]u8, // The bytes of the line: UTF-8.
	count:            int, // The bytes of the line.
	caret:            int, // The place of the caret in bytes: 0 is before the first character, count after the last.
	selection_anchor: int, // Byte offset of the selection anchor (start of a character) while has_selection is true.
	has_selection:    bool, // True when bytes between selection_anchor and caret are selected.
}

// The keys that edit a line. The caller translates the codes of its keys:
// the package does not depend on a keyboard.
Edit_Key :: enum u8 {
	None         = 0, // No key: nothing changes.
	Left         = 1, // The caret goes one character to the left, or collapses selection to its start.
	Right        = 2, // The caret goes one character to the right, or collapses selection to its end.
	Home         = 3, // The caret goes before the first character and clears selection.
	End          = 4, // The caret goes after the last character and clears selection.
	Backspace    = 5, // Deletes the selection, or the character before the caret.
	Delete       = 6, // Deletes the selection, or the character after the caret.
	Character    = 7, // A printable character goes in at the caret, replacing any selection.
	Select_Left  = 8, // Extends or shrinks selection one character to the left.
	Select_Right = 9, // Extends or shrinks selection one character to the right.
	Select_Home  = 10, // Extends selection to the start of the line.
	Select_End   = 11, // Extends selection to the end of the line.
	Select_All   = 12, // Selects the whole line.
}

// line_repair brings the count, caret, and selection anchor of a line inside
// its bytes, snapped to character starts. An empty selection clears itself.
line_repair :: proc "contextless" (line: ^Line) {
	line.count = clamp(line.count, 0, LINE_CAPACITY)
	line.caret = clamp(line.caret, 0, line.count)
	line.caret = character_start_before(line.bytes[:line.count], line.caret)
	if line.has_selection {
		line.selection_anchor = clamp(line.selection_anchor, 0, line.count)
		line.selection_anchor = character_start_before(line.bytes[:line.count], line.selection_anchor)
		if line.selection_anchor == line.caret {
			line.has_selection = false
		}
	} else {
		line.selection_anchor = line.caret
	}
}

// line_selection_range gives the ordered byte range [start, end) of the active
// selection. When no selection is active, start and end both equal caret and
// active is false.
line_selection_range :: proc "contextless" (line: ^Line) -> (start, end: int, active: bool) {
	line_repair(line)
	if !line.has_selection {
		return line.caret, line.caret, false
	}
	return min(line.selection_anchor, line.caret), max(line.selection_anchor, line.caret), true
}

// line_selected_text gives the selected slice of bytes when a selection is
// active, or "" and false when no selection is active.
line_selected_text :: proc "contextless" (line: ^Line) -> (text: string, active: bool) {
	start, end, ok := line_selection_range(line)
	if !ok {
		return "", false
	}
	return string(line.bytes[start:end]), true
}

// line_selection_clear clears any active selection and anchors it at the caret.
// Returns true when an active selection was cleared.
line_selection_clear :: proc "contextless" (line: ^Line) -> bool {
	line_repair(line)
	was := line.has_selection
	line.has_selection = false
	line.selection_anchor = line.caret
	return was
}

// line_select_all selects every byte of a non-empty line, placing the anchor at
// 0 and the caret at count. Returns false on an empty line or when already
// selected from 0 to count.
line_select_all :: proc "contextless" (line: ^Line) -> bool {
	line_repair(line)
	if line.count == 0 {
		line.has_selection = false
		line.selection_anchor = 0
		return false
	}
	changed := !line.has_selection || line.selection_anchor != 0 || line.caret != line.count
	line.selection_anchor = 0
	line.caret = line.count
	line.has_selection = true
	return changed
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

@(private = "file")
delete_selection :: proc "contextless" (line: ^Line) -> bool {
	if !line.has_selection {
		return false
	}
	start := min(line.selection_anchor, line.caret)
	end := max(line.selection_anchor, line.caret)
	copy(line.bytes[start:line.count], line.bytes[end:line.count])
	line.count -= end - start
	line.caret = start
	line.selection_anchor = start
	line.has_selection = false
	return true
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
		if line.has_selection {
			line.caret = min(line.selection_anchor, line.caret)
			line.selection_anchor = line.caret
			line.has_selection = false
			return true
		}
		if line.caret == 0 {
			return false
		}
		line.caret = character_start_before(text, line.caret - 1)
		line.selection_anchor = line.caret
	case .Right:
		if line.has_selection {
			line.caret = max(line.selection_anchor, line.caret)
			line.selection_anchor = line.caret
			line.has_selection = false
			return true
		}
		if line.caret == line.count {
			return false
		}
		line.caret = min(character_end_after(text, line.caret), line.count)
		line.selection_anchor = line.caret
	case .Home:
		if line.caret == 0 && !line.has_selection {
			return false
		}
		line.caret = 0
		line.selection_anchor = 0
		line.has_selection = false
	case .End:
		if line.caret == line.count && !line.has_selection {
			return false
		}
		line.caret = line.count
		line.selection_anchor = line.count
		line.has_selection = false
	case .Backspace:
		if delete_selection(line) {
			return true
		}
		if line.caret == 0 {
			return false
		}
		start := character_start_before(text, line.caret - 1)
		copy(line.bytes[start:line.count], line.bytes[line.caret:line.count])
		line.count -= line.caret - start
		line.caret = start
		line.selection_anchor = start
	case .Delete:
		if delete_selection(line) {
			return true
		}
		if line.caret == line.count {
			return false
		}
		end := min(character_end_after(text, line.caret), line.count)
		copy(line.bytes[line.caret:line.count], line.bytes[end:line.count])
		line.count -= end - line.caret
		line.selection_anchor = line.caret
	case .Character:
		encoded: [text_encoding.CHARACTER_BYTES_LIMIT]u8
		length := printable(character) ? text_encoding.character_encode(character, encoded[:]) : 0
		if length == 0 {
			return false
		}
		start, end := line.caret, line.caret
		if line.has_selection {
			start = min(line.selection_anchor, line.caret)
			end = max(line.selection_anchor, line.caret)
		}
		if line.count - (end - start) + length > LINE_CAPACITY {
			return false
		}
		rest := line.count - end
		new_end := start + length
		// The bytes after the selection move to their new place; copy moves
		// overlapping slices safely.
		copy(line.bytes[new_end:new_end + rest], line.bytes[end:line.count])
		copy(line.bytes[start:new_end], encoded[:length])
		line.caret = new_end
		line.count = new_end + rest
		line.selection_anchor = new_end
		line.has_selection = false
	case .Select_Left:
		if line.caret == 0 {
			return false
		}
		if !line.has_selection {
			line.selection_anchor = line.caret
		}
		line.caret = character_start_before(text, line.caret - 1)
		line.has_selection = line.caret != line.selection_anchor
	case .Select_Right:
		if line.caret == line.count {
			return false
		}
		if !line.has_selection {
			line.selection_anchor = line.caret
		}
		line.caret = min(character_end_after(text, line.caret), line.count)
		line.has_selection = line.caret != line.selection_anchor
	case .Select_Home:
		if line.caret == 0 {
			return false
		}
		if !line.has_selection {
			line.selection_anchor = line.caret
		}
		line.caret = 0
		line.has_selection = line.caret != line.selection_anchor
	case .Select_End:
		if line.caret == line.count {
			return false
		}
		if !line.has_selection {
			line.selection_anchor = line.caret
		}
		line.caret = line.count
		line.has_selection = line.caret != line.selection_anchor
	case .Select_All:
		return line_select_all(line)
	}
	return true
}

// line_copy copies the active selection into out. Returns (0, false) when no
// selection is active or when out is smaller than the selected bytes.
line_copy :: proc "contextless" (line: ^Line, out: []u8) -> (copied: int, ok: bool) {
	start, end, active := line_selection_range(line)
	if !active || end - start > len(out) {
		return 0, false
	}
	copied = copy(out, line.bytes[start:end])
	return copied, true
}

// line_cut copies the active selection into out and removes it from the line.
// On an empty selection or when out is too small, returns (0, false) and leaves
// the line unchanged.
line_cut :: proc "contextless" (line: ^Line, out: []u8) -> (copied: int, ok: bool) {
	start, end, active := line_selection_range(line)
	if !active || end - start > len(out) {
		return 0, false
	}
	copied = copy(out, line.bytes[start:end])
	copy(line.bytes[start:line.count], line.bytes[end:line.count])
	line.count -= end - start
	line.caret = start
	line.selection_anchor = start
	line.has_selection = false
	return copied, true
}

// line_paste inserts valid single-line UTF-8 text at the caret, replacing any
// active selection. Refuses empty text, invalid UTF-8 or control characters,
// and any result exceeding capacity_limit (clamped to LINE_CAPACITY) whole
// without modifying the line.
line_paste :: proc "contextless" (line: ^Line, text: string, capacity_limit: int = LINE_CAPACITY) -> (ok: bool) {
	line_repair(line)
	limit := clamp(capacity_limit, 0, LINE_CAPACITY)
	if len(text) == 0 || !text_encoding.text_valid(transmute([]u8)text) {
		return false
	}
	start, end := line.caret, line.caret
	if line.has_selection {
		start = min(line.selection_anchor, line.caret)
		end = max(line.selection_anchor, line.caret)
	}
	if line.count - (end - start) + len(text) > limit {
		return false
	}
	rest := line.count - end
	new_end := start + len(text)
	copy(line.bytes[new_end:new_end + rest], line.bytes[end:line.count])
	copy(line.bytes[start:new_end], text)
	line.count = new_end + rest
	line.caret = new_end
	line.selection_anchor = new_end
	line.has_selection = false
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
	line.selection_anchor = line.caret
	line.has_selection = false
}

// line_view gives the part of a text that a place of room bytes shows, with
// the caret in it: the whole text when it fits; else a part that ends at a
// whole character and starts at one, with the caret three quarters of the
// way along, so the reader sees what it typed and some of what follows.
// The caller shows text[start:end] and the caret at caret - start.
line_view :: proc "contextless" (text: string, caret_given: int, room: int) -> (start, end: int) {
	if room <= 0 {
		return 0, 0
	}
	if len(text) <= room {
		return 0, len(text)
	}
	bytes := transmute([]u8)text
	caret := clamp(caret_given, 0, len(text))
	start = character_start_before(bytes, max(caret - room * 3 / 4, 0))
	// A text that ends before the room is full shows its end whole.
	if len(text) - start < room {
		start = len(text) - room
		for start < len(text) && bytes[start] & 0xC0 == 0x80 {
			start += 1
		}
	}
	end = start + text_encoding.complete_characters(bytes[start:min(start + room, len(text))])
	return start, end
}

// line_clear empties the line.
line_clear :: proc "contextless" (line: ^Line) {
	line.count = 0
	line.caret = 0
	line.selection_anchor = 0
	line.has_selection = false
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
	line.selection_anchor = new_end
	line.has_selection = false
	return true
}
