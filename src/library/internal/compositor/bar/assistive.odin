// The holders of the assistive role that the compositor serves, the marks
// that the bar shows for them, and the check of a request to magnify. The
// compositor keeps the table and draws the marks; the rules are here, so a
// host test reads the same table and the same places as the screen
// (src/md/features/accessibility.md, "2. The assistive role").
package bar

import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// A magnifier and a screen reader run together, with room for a switch
// input and an on-screen keyboard: past this, a new holder is refused.
ASSISTIVE_HOLDER_LIMIT :: 4
// The nickname of a holder: a process nickname, 31 bytes at most, so it
// fills a Module_Name_Field of a log fact with its zero byte.
ASSISTIVE_NICKNAME_BYTES :: 31
// The word before the nickname in a mark.
ASSISTIVE_MARK_WORD :: "assistive"
// The mark with no text, when the bar has no room for the words.
ASSISTIVE_MARK_SQUARE :: 16
// Between two marks, and between a mark and the item at its right.
ASSISTIVE_MARK_GAP :: 4
// The longest text of a mark: the word, a space and the nickname.
ASSISTIVE_MARK_TEXT_BYTES :: len(ASSISTIVE_MARK_WORD) + 1 + ASSISTIVE_NICKNAME_BYTES

// What a holder of the assistive role does for the principal.
Assistive_Holder_Kind :: enum u8 {
	None          = 0, // No holder: the word of an empty slot, refused by attach.
	Screen_Reader = 1, // Reads the trees aloud and moves the focus.
	Magnifier     = 2, // Tells the compositor which part of the screen to draw larger.
	Switch_Input  = 3, // Moves the focus and acts through the switch keys.
}

// assistive_holder_kind_of_word is the one border of the word of a kind.
// It refuses each word that names no member; None is a member, which
// attach refuses on its own.
assistive_holder_kind_of_word :: proc "contextless" (word: u64) -> (kind: Assistive_Holder_Kind, ok: bool) {
	return enum_word.member_of_word(Assistive_Holder_Kind, word)
}

// A holder of the assistive role that reads the trees now.
Assistive_Holder :: struct {
	id:              u64, // Never 0, never given twice in one run.
	nickname:        [ASSISTIVE_NICKNAME_BYTES]u8,
	nickname_length: int,
	kind:            Assistive_Holder_Kind,
	active:          bool,
}

// The holders, in slots that keep their place: a mark keeps its place in
// the bar while another holder comes or goes.
Assistive_Registry :: struct {
	holders: [ASSISTIVE_HOLDER_LIMIT]Assistive_Holder,
	count:   int, // The active holders.
	last_id: u64, // The number of the last holder attached; 0 before the first.
}

// Why a holder is not attached.
Assistive_Attach_Refusal :: enum u8 {
	None,
	Kind_None, // The kind is None: a holder does something.
	Empty_Nickname, // The mark would name nobody.
	Nickname_Too_Long, // Past ASSISTIVE_NICKNAME_BYTES: a cut name could name another process.
	Nickname_Invalid, // Not valid UTF-8, or holds a control byte: the mark would lie.
	Full, // ASSISTIVE_HOLDER_LIMIT holders read the trees.
}

// assistive_attach records a holder and gives its number, or 0 with the
// refusal. A refusal changes nothing in the registry.
assistive_attach :: proc "contextless" (registry: ^Assistive_Registry, nickname: string, kind: Assistive_Holder_Kind) -> (id: u64, refusal: Assistive_Attach_Refusal) {
	switch {
	case kind == .None:
		return 0, .Kind_None
	case len(nickname) == 0:
		return 0, .Empty_Nickname
	case len(nickname) > ASSISTIVE_NICKNAME_BYTES:
		return 0, .Nickname_Too_Long
	case !nickname_valid(nickname):
		return 0, .Nickname_Invalid
	case registry.count >= ASSISTIVE_HOLDER_LIMIT:
		return 0, .Full
	}
	for &holder in registry.holders {
		if holder.active {
			continue
		}
		registry.last_id += 1
		holder = {id = registry.last_id, nickname_length = len(nickname), kind = kind, active = true}
		copy(holder.nickname[:], nickname)
		registry.count += 1
		return holder.id, .None
	}
	return 0, .Full
}

// A byte under 0x20 or 0x7F would let a nickname draw a line break or
// nothing in the bar, so the mark would not name its holder.
@(private = "file")
nickname_valid :: proc "contextless" (nickname: string) -> bool {
	bytes := transmute([]u8)nickname
	if !text_encoding.text_valid(bytes) {
		return false
	}
	for byte in bytes {
		if byte < 0x20 || byte == 0x7F {
			return false
		}
	}
	return true
}

// assistive_find gives the slot of the active holder of a number, or -1.
assistive_find :: proc "contextless" (registry: ^Assistive_Registry, id: u64) -> int {
	if id == 0 {
		return -1
	}
	for &holder, slot in registry.holders {
		if holder.active && holder.id == id {
			return slot
		}
	}
	return -1
}

// assistive_detach ends a holder by its number and gives a copy of it. ok
// is false for a number that names no active holder: 0, never given, or
// already detached.
assistive_detach :: proc "contextless" (registry: ^Assistive_Registry, id: u64) -> (detached: Assistive_Holder, ok: bool) {
	slot := assistive_find(registry, id)
	if slot < 0 {
		return {}, false
	}
	detached = registry.holders[slot]
	registry.holders[slot] = {}
	registry.count -= 1
	return detached, true
}

// assistive_holder_nickname gives the nickname of a holder.
assistive_holder_nickname :: proc "contextless" (holder: ^Assistive_Holder) -> string {
	return string(holder.nickname[:clamp(holder.nickname_length, 0, ASSISTIVE_NICKNAME_BYTES)])
}

// assistive_mark_shown says if the bar shows a mark: while one holder or
// more reads the trees, since reading each window is a capture of the
// screen in text.
assistive_mark_shown :: proc "contextless" (registry: ^Assistive_Registry) -> bool {
	return registry.count > 0
}

// assistive_mark_text writes the text of the mark of a holder: the word
// and the nickname.
assistive_mark_text :: proc "contextless" (holder: ^Assistive_Holder, buffer: ^[ASSISTIVE_MARK_TEXT_BYTES]u8) -> string {
	nickname := assistive_holder_nickname(holder)
	copy(buffer[:], ASSISTIVE_MARK_WORD)
	buffer[len(ASSISTIVE_MARK_WORD)] = ' '
	copy(buffer[len(ASSISTIVE_MARK_WORD) + 1:], nickname)
	return string(buffer[:len(ASSISTIVE_MARK_WORD) + 1 + len(nickname)])
}

// The mark of one holder in the bar.
Assistive_Mark :: struct {
	slot:   int, // The slot of its holder in the registry.
	x:      int,
	width:  int,
	square: bool, // No room for the words: the square alone.
}

// The marks of the holders, from the right to the left.
Assistive_Mark_Layout :: struct {
	marks: [ASSISTIVE_HOLDER_LIMIT]Assistive_Mark,
	count: int,
	left:  int, // The first column of the leftmost mark; right when there is no mark.
}

// assistive_marks_place places one mark for each active holder, in the
// order of the slots, from the right to the left. text_widths holds the
// width of the text of the mark of each slot, as the font of the bar
// measures it. A mark shows its words when they fit after least_left, else
// the square alone, which is never left out: a holder always shows that it
// reads.
assistive_marks_place :: proc "contextless" (registry: ^Assistive_Registry, text_widths: [ASSISTIVE_HOLDER_LIMIT]int, right, least_left: int) -> (layout: Assistive_Mark_Layout) {
	x := right
	for &holder, slot in registry.holders {
		if !holder.active {
			continue
		}
		width := max(text_widths[slot], 0) + 2 * PADDING
		square := x - width < least_left
		if square {
			width = ASSISTIVE_MARK_SQUARE
		}
		x -= width
		layout.marks[layout.count] = {slot = slot, x = x, width = width, square = square}
		layout.count += 1
		x -= ASSISTIVE_MARK_GAP
	}
	layout.left = layout.count > 0 ? layout.marks[layout.count - 1].x : right
	return layout
}

// The least and the largest factor of magnification, in eighths: 1.5 and 8
// times, the bounds of the magnifier of the screen reader package.
ASSISTIVE_MAGNIFY_FACTOR_LEAST :: 12
ASSISTIVE_MAGNIFY_FACTOR_MOST :: 64

// Why a request to magnify is refused.
Assistive_Magnify_Refusal :: enum u8 {
	None,
	No_Holder, // No holder reads the trees: magnification is a part of the assistive face.
	Factor_Out_Of_Range, // Under 12 or past 64 eighths.
	Empty_Rectangle, // A width or a height under 1.
	Outside_Screen, // A part of the rectangle is off the screen.
}

// assistive_magnify_check checks a request to draw a rectangle of the
// screen larger. The rectangle is whole on the screen, so the compositor
// never reads a pixel outside its frame.
assistive_magnify_check :: proc "contextless" (registry: ^Assistive_Registry, left, top, width, height, factor_eighths, screen_width, screen_height: i64) -> Assistive_Magnify_Refusal {
	switch {
	case registry.count <= 0:
		return .No_Holder
	case factor_eighths < ASSISTIVE_MAGNIFY_FACTOR_LEAST || factor_eighths > ASSISTIVE_MAGNIFY_FACTOR_MOST:
		return .Factor_Out_Of_Range
	case width < 1 || height < 1:
		return .Empty_Rectangle
	// Each bound subtracts from the screen and never adds to a value of the
	// caller, so a value near the largest i64 cannot wrap past a bound.
	case left < 0 || top < 0 || width > screen_width || height > screen_height || left > screen_width - width || top > screen_height - height:
		return .Outside_Screen
	}
	return .None
}
