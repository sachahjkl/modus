// The text that the editor `edit` changes, as pure procedures with no call
// of the system, so that a host test gives them each edge
// (src/md/features/editor.md).
//
// The text is UTF-8 with no control character but the line end and the
// tab. Each procedure that takes bytes from outside checks them first, and
// a refused input changes nothing. The caret and the anchor are places in
// bytes, always before a whole character; the selection is the bytes
// between them.
//
// The bytes are a gap buffer: the text before the gap at the start of one
// array, the text after it at the end. A typed key moves the gap to the
// caret, then writes into it, so a run of keys at one place copies no byte
// of the rest of the text.
package text_model

import "modus:contract/text_encoding"

// The most bytes of a text. A whole write of the text to the storage
// service goes through one call region, which has room for it and its
// name (src/md/features/editor.md, "The text model").
TEXT_CAPACITY :: 32768

LINE_END :: '\n'
TAB :: '\t'

// The bytes of the replacement character, U+FFFD, in UTF-8: what the
// editor writes in place of each invalid sequence of a text that it reads.
REPLACEMENT_BYTES :: [3]u8{0xEF, 0xBF, 0xBD}

// The text of the editor. The zero value is an empty text with the caret
// at 0.
Text :: struct {
	bytes:        [TEXT_CAPACITY]u8,
	before_count: int, // bytes[:before_count] is the text before the gap.
	after_count:  int, // bytes[TEXT_CAPACITY - after_count:] is the text after the gap.
	caret:        int, // Where the keys act.
	anchor:       int, // The other end of the selection; equal to the caret when nothing is selected.
	// The cell column that a run of Up, Down, Page Up and Page Down keeps,
	// so that a short line on the way does not move the caret to the left
	// for the lines after it.
	goal_column:  int,
	has_goal:     bool,
}

// Why an edit is refused. A refused edit changes nothing.
Edit_Problem :: enum u8 {
	None     = 0,
	Empty    = 1, // An insert of no byte.
	Not_Text = 2, // An invalid sequence, or a control character other than the line end and the tab.
	Too_Long = 3, // The text would pass TEXT_CAPACITY.
}

// text_length gives the bytes of the text.
text_length :: proc "contextless" (text: ^Text) -> int {
	return text.before_count + text.after_count
}

// byte_at gives the byte at a place of the text, 0 <= place < text_length.
byte_at :: proc "contextless" (text: ^Text, place: int) -> u8 {
	if place < text.before_count {
		return text.bytes[place]
	}
	return text.bytes[TEXT_CAPACITY - text.after_count + place - text.before_count]
}

// gap_move puts the gap at a place of the text, 0 <= place <= text_length.
// The copy can overlap its source: copy moves the bytes as memmove does.
@(private)
gap_move :: proc "contextless" (text: ^Text, place: int) {
	if place < text.before_count {
		count := text.before_count - place
		after_start := TEXT_CAPACITY - text.after_count
		copy(text.bytes[after_start - count:after_start], text.bytes[place:text.before_count])
		text.after_count += count
		text.before_count = place
	} else if place > text.before_count {
		count := place - text.before_count
		after_start := TEXT_CAPACITY - text.after_count
		copy(text.bytes[text.before_count:place], text.bytes[after_start:after_start + count])
		text.before_count = place
		text.after_count -= count
	}
}

// text_bytes gives the whole text as one slice: it moves the gap to the
// end. The slice is valid until the next edit.
text_bytes :: proc "contextless" (text: ^Text) -> []u8 {
	gap_move(text, text_length(text))
	return text.bytes[:text.before_count]
}

// text_valid says if bytes are a text of the editor: UTF-8 with no control
// character but the line end and the tab.
text_valid :: proc "contextless" (bytes: []u8) -> bool {
	place := 0
	for place < len(bytes) {
		if bytes[place] == LINE_END || bytes[place] == TAB {
			place += 1
			continue
		}
		_, length, valid := text_encoding.character_decode(bytes, place)
		if !valid {
			return false
		}
		place += length
	}
	return true
}

// text_clean copies bytes from outside (an object of a store) into target,
// with the three bytes of the replacement character in place of each
// invalid sequence and each control character but the line end and the
// tab: a reader that draws uses the replacement glyph
// (src/md/data/text_encoding.md). Too_Long when target cannot hold the
// result: count is then 0, and the caller keeps no part of it.
text_clean :: proc "contextless" (source: []u8, target: []u8) -> (count: int, replaced: int, problem: Edit_Problem) {
	place := 0
	for place < len(source) {
		value := source[place]
		if value == LINE_END || value == TAB {
			if count >= len(target) {
				return 0, 0, .Too_Long
			}
			target[count] = value
			count += 1
			place += 1
			continue
		}
		_, length, valid := text_encoding.character_decode(source, place)
		if valid {
			if count + length > len(target) {
				return 0, 0, .Too_Long
			}
			copy(target[count:count + length], source[place:place + length])
			count += length
		} else {
			replacement := REPLACEMENT_BYTES
			if count + len(replacement) > len(target) {
				return 0, 0, .Too_Long
			}
			copy(target[count:count + len(replacement)], replacement[:])
			count += len(replacement)
			replaced += 1
		}
		place += length
	}
	return count, replaced, .None
}

// text_replace_whole makes the text the bytes given, which text_clean or a
// check made: a version that Ctrl+Z or Ctrl+Y restores, or the text read at
// the start. The caret goes to the end of the part that differs, so a
// principal sees where the text changed; nothing is selected.
text_replace_whole :: proc "contextless" (text: ^Text, bytes: []u8) -> Edit_Problem {
	if len(bytes) > TEXT_CAPACITY {
		return .Too_Long
	}
	if !text_valid(bytes) {
		return .Not_Text
	}
	old := text_bytes(text)
	shorter := min(len(old), len(bytes))
	prefix := 0
	for prefix < shorter && old[prefix] == bytes[prefix] {
		prefix += 1
	}
	suffix := 0
	for suffix < shorter - prefix && old[len(old) - 1 - suffix] == bytes[len(bytes) - 1 - suffix] {
		suffix += 1
	}
	// The two texts can overlap in memory only if a caller passes the
	// slice of text_bytes: copy moves the bytes as memmove does.
	copy(text.bytes[:len(bytes)], bytes)
	text.before_count, text.after_count = len(bytes), 0
	caret := len(bytes) - suffix
	// A byte compare can stop inside a character: é and è share their
	// first byte.
	for caret > 0 && caret < len(bytes) && bytes[caret] & 0xC0 == 0x80 {
		caret -= 1
	}
	text.caret, text.anchor, text.has_goal = caret, caret, false
	return .None
}

// selection gives the first and the last place of the selection.
selection :: proc "contextless" (text: ^Text) -> (first, last: int) {
	return min(text.caret, text.anchor), max(text.caret, text.anchor)
}

// selection_count gives the bytes of the selection.
selection_count :: proc "contextless" (text: ^Text) -> int {
	first, last := selection(text)
	return last - first
}

// text_select_all selects the whole text: anchor at 0, caret at the end.
text_select_all :: proc "contextless" (text: ^Text) {
	text.anchor = 0
	text.caret = text_length(text)
	text.has_goal = false
}

// selection_copy copies the selected bytes into target without changing
// the text or moving the gap. Empty when nothing is selected; Too_Long
// when target cannot hold the selection.
selection_copy :: proc "contextless" (text: ^Text, target: []u8) -> (count: int, problem: Edit_Problem) {
	first, last := selection(text)
	selected := last - first
	if selected == 0 {
		return 0, .Empty
	}
	if selected > len(target) {
		return 0, .Too_Long
	}
	switch {
	case last <= text.before_count:
		copy(target[:selected], text.bytes[first:last])
	case first >= text.before_count:
		after_start := TEXT_CAPACITY - text.after_count + (first - text.before_count)
		copy(target[:selected], text.bytes[after_start:after_start + selected])
	case:
		left := text.before_count - first
		copy(target[:left], text.bytes[first:text.before_count])
		after_start := TEXT_CAPACITY - text.after_count
		copy(target[left:selected], text.bytes[after_start:after_start + (selected - left)])
	}
	return selected, .None
}

// selection_delete removes the selected bytes and puts the caret at the
// start of the selection. false when nothing is selected.
selection_delete :: proc "contextless" (text: ^Text) -> bool {
	if selection_count(text) == 0 {
		return false
	}
	first, last := selection(text)
	range_remove(text, first, last)
	return true
}

// selection_cut copies the selected bytes into target and removes them
// from the text. A refused copy (Empty or Too_Long) leaves the text and
// the selection unchanged.
selection_cut :: proc "contextless" (text: ^Text, target: []u8) -> (count: int, problem: Edit_Problem) {
	count, problem = selection_copy(text, target)
	if problem != .None {
		return 0, problem
	}
	selection_delete(text)
	return count, .None
}

// range_remove removes the bytes from first to last, and puts the caret
// at first with nothing selected.
@(private)
range_remove :: proc "contextless" (text: ^Text, first, last: int) {
	gap_move(text, last)
	text.before_count -= last - first
	text.caret, text.anchor, text.has_goal = first, first, false
}

// text_insert puts bytes at the caret, in place of the selection. The
// bytes are checked first: a refused insert changes nothing, the
// selection too.
text_insert :: proc "contextless" (text: ^Text, bytes: []u8) -> Edit_Problem {
	if len(bytes) == 0 {
		return .Empty
	}
	if !text_valid(bytes) {
		return .Not_Text
	}
	if text_length(text) - selection_count(text) + len(bytes) > TEXT_CAPACITY {
		return .Too_Long
	}
	if selection_count(text) > 0 {
		first, last := selection(text)
		range_remove(text, first, last)
	}
	gap_move(text, text.caret)
	copy(text.bytes[text.before_count:text.before_count + len(bytes)], bytes)
	text.before_count += len(bytes)
	text.caret, text.anchor, text.has_goal = text.before_count, text.before_count, false
	return .None
}

// text_insert_character puts one typed character at the caret. A code
// point that is no character of a text, and no line end or tab, is
// refused.
text_insert_character :: proc "contextless" (text: ^Text, character: rune) -> Edit_Problem {
	buffer: [text_encoding.CHARACTER_BYTES_LIMIT]u8
	if character == LINE_END || character == TAB {
		buffer[0] = u8(character)
		return text_insert(text, buffer[:1])
	}
	length := text_encoding.character_encode(character, buffer[:])
	if length == 0 {
		return .Not_Text
	}
	return text_insert(text, buffer[:length])
}

// character_length gives the bytes of the character that starts at a
// place: the text is valid, so the lead byte says it.
character_length :: proc "contextless" (text: ^Text, place: int) -> int {
	lead := byte_at(text, place)
	switch {
	case lead & 0xE0 == 0xC0:
		return 2
	case lead & 0xF0 == 0xE0:
		return 3
	case lead & 0xF8 == 0xF0:
		return 4
	}
	return 1
}

// previous_character_start gives the start of the character before a
// place, place > 0.
previous_character_start :: proc "contextless" (text: ^Text, place: int) -> int {
	start := place - 1
	for start > 0 && place - start < text_encoding.CHARACTER_BYTES_LIMIT && byte_at(text, start) & 0xC0 == 0x80 {
		start -= 1
	}
	return start
}

// text_delete_before is Backspace: it removes the selection, or the
// character before the caret. false: nothing to remove.
text_delete_before :: proc "contextless" (text: ^Text) -> bool {
	if selection_count(text) > 0 {
		first, last := selection(text)
		range_remove(text, first, last)
		return true
	}
	if text.caret == 0 {
		return false
	}
	range_remove(text, previous_character_start(text, text.caret), text.caret)
	return true
}

// text_delete_after is Delete: it removes the selection, or the character
// after the caret. false: nothing to remove.
text_delete_after :: proc "contextless" (text: ^Text) -> bool {
	if selection_count(text) > 0 {
		first, last := selection(text)
		range_remove(text, first, last)
		return true
	}
	if text.caret >= text_length(text) {
		return false
	}
	range_remove(text, text.caret, text.caret + character_length(text, text.caret))
	return true
}

// selection_set places the anchor and the caret, each clamped to the text
// and moved back to the start of its character. A place from outside the
// model (a press of the pointer) goes through it.
selection_set :: proc "contextless" (text: ^Text, anchor, caret: int) {
	text.anchor = character_start_at_or_before(text, anchor)
	text.caret = character_start_at_or_before(text, caret)
	text.has_goal = false
}

// character_start_at_or_before clamps a place to the text, and moves it
// back to the start of the character that holds it.
character_start_at_or_before :: proc "contextless" (text: ^Text, place: int) -> int {
	clamped := clamp(place, 0, text_length(text))
	for clamped > 0 && clamped < text_length(text) && byte_at(text, clamped) & 0xC0 == 0x80 {
		clamped -= 1
	}
	return clamped
}

// The kinds of the changes that a commit groups: a change of another kind
// ends the group before it (src/md/features/editor.md, "The groups of
// changes").
Change_Kind :: enum u8 {
	None   = 0, // No change waits for a commit.
	Insert = 1, // Typed characters, and a selection that typed characters replace.
	Delete = 2, // Backspace and Delete.
}

// group_ends_before says if the changes that wait must be committed
// before a change of the kind next.
group_ends_before :: proc "contextless" (waiting: Change_Kind, next: Change_Kind) -> bool {
	return waiting != .None && waiting != next
}

// character_ends_group says if a typed character ends a word: the group
// is committed after it.
character_ends_group :: proc "contextless" (character: rune) -> bool {
	return character == ' ' || character == TAB || character == LINE_END
}
