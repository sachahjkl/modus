// The layouts of the keyboard (src/md/features/keyboard_layout.md): the
// character of each key as a code point, and the dead keys of the layout
// of France. The input service is the one user: it reads the setting
// `keyboard_layout` at each key, and keeps the accent that waits in a
// `Dead_Key_State`.
//
// The package has no state of its own and makes no kernel call, so a host
// test presses each key of each layout.
package keyboard_layout

import "modus:contract/settings"

// The keys of scan code set 1 that the tables hold: 0x01 to 0x39, the main
// block of the keyboard. A key past them gives no character, but the key
// between the left Shift and Z of a keyboard of 102 keys.
TABLE_KEY_COUNT :: 0x3A
KEY_LESS_GREATER :: 0x56 // The key between the left Shift and Z (or W) of a keyboard of 102 keys.
KEY_DEAD_ACCENTS :: 0x1A // The key right of P: the dead keys of the layout of France.

// The characters of the keys, without Shift and with Shift.
Key_Characters :: [2][TABLE_KEY_COUNT]rune

// Scan code set 1, layout of the United States: the character of each key,
// without and with Shift.
@(rodata)
characters_united_states := Key_Characters {
	{0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8, '\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' '},
	{0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8, '\t', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0, 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' '},
}

// Scan code set 1, layout of France (AZERTY): the character of each key,
// without and with Shift. The key right of P is a dead key in both: its
// entry is 0, and dead_accent_of gives its accent.
@(rodata)
characters_french := Key_Characters {
	{0, 0, '&', 'é', '"', '\'', '(', '-', 'è', '_', 'ç', 'à', ')', '=', 8, '\t', 'a', 'z', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', 0, '$', '\n', 0, 'q', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm', 'ù', '²', 0, '*', 'w', 'x', 'c', 'v', 'b', 'n', ',', ';', ':', '!', 0, '*', 0, ' '},
	{0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '°', '+', 8, '\t', 'A', 'Z', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 0, '£', '\n', 0, 'Q', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'M', '%', 0, 0, 'µ', 'W', 'X', 'C', 'V', 'B', 'N', '?', '.', '/', '§', 0, '*', 0, ' '},
}

// The accents of the dead keys, as the character that the accent alone
// gives: the circumflex and the diaeresis.
ACCENT_CIRCUMFLEX :: '^'
ACCENT_DIAERESIS :: '¨'

// One letter with an accent: the letter, then the letter that the accent
// makes of it.
@(private)
Accented_Letter :: struct {
	letter, accented: rune,
}

// The letters that each accent of a dead key makes. A capital Y with a
// diaeresis is outside the Latin-1 Supplement, which the fonts draw: it is
// not here, so the dead key then gives the accent and the letter.
@(rodata)
@(private)
circumflex_letters := [?]Accented_Letter{{'a', 'â'}, {'e', 'ê'}, {'i', 'î'}, {'o', 'ô'}, {'u', 'û'}, {'A', 'Â'}, {'E', 'Ê'}, {'I', 'Î'}, {'O', 'Ô'}, {'U', 'Û'}}
@(rodata)
@(private)
diaeresis_letters := [?]Accented_Letter{{'a', 'ä'}, {'e', 'ë'}, {'i', 'ï'}, {'o', 'ö'}, {'u', 'ü'}, {'y', 'ÿ'}, {'A', 'Ä'}, {'E', 'Ë'}, {'I', 'Ï'}, {'O', 'Ö'}, {'U', 'Ü'}}

// key_character gives the character of a key in a layout, as a code point,
// or 0: a key with no character, a dead key, a key past the tables. code is
// the scan code, with display.KEY_EXTENDED for an extended key.
key_character :: proc "contextless" (layout: settings.Keyboard_Layout, shift: bool, code: u32) -> rune {
	row := shift ? 1 : 0
	if code == KEY_LESS_GREATER {
		switch layout {
		case .United_States:
			return shift ? '|' : '\\'
		case .French:
			return shift ? '>' : '<'
		}
		return 0
	}
	if code >= TABLE_KEY_COUNT {
		return 0
	}
	switch layout {
	case .United_States:
		return characters_united_states[row][code]
	case .French:
		return characters_french[row][code]
	}
	return 0
}

// dead_accent_of gives the accent of a dead key, or 0 for a key that is not
// a dead key in this layout.
dead_accent_of :: proc "contextless" (layout: settings.Keyboard_Layout, shift: bool, code: u32) -> rune {
	if layout == .French && code == KEY_DEAD_ACCENTS {
		return shift ? ACCENT_DIAERESIS : ACCENT_CIRCUMFLEX
	}
	return 0
}

// accented_letter gives the letter that an accent makes of a letter. found
// is false when the accent has no such letter.
accented_letter :: proc "contextless" (accent, letter: rune) -> (accented: rune, found: bool) {
	letters: []Accented_Letter
	switch accent {
	case ACCENT_CIRCUMFLEX:
		letters = circumflex_letters[:]
	case ACCENT_DIAERESIS:
		letters = diaeresis_letters[:]
	}
	for item in letters {
		if item.letter == letter {
			return item.accented, true
		}
	}
	return 0, false
}

// The accent of a dead key that waits for the next key. The zero state
// has no accent that waits.
Dead_Key_State :: struct {
	accent: rune, // The accent alone, or 0.
}

// key_press gives the characters of the press of a key, and changes the
// accent that waits. character is the character of the key record of the
// press, or 0. accent_alone, when it is not 0, is the character of a key
// record that goes before it: the accent that a key could not combine with.
// modifier_key: the key is Shift or Control, which keeps the accent
// waiting. The rules are in src/md/features/keyboard_layout.md, "The
// chosen form".
key_press :: proc "contextless" (state: ^Dead_Key_State, layout: settings.Keyboard_Layout, shift: bool, code: u32, modifier_key: bool) -> (accent_alone: rune, character: rune) {
	waiting := state.accent
	if accent := dead_accent_of(layout, shift, code); accent != 0 {
		if waiting != 0 {
			// A dead key while an accent waits: the waiting accent alone.
			state.accent = 0
			return 0, waiting
		}
		state.accent = accent
		return 0, 0
	}
	typed := key_character(layout, shift, code)
	if waiting == 0 {
		return 0, typed
	}
	switch {
	case typed == 0 && modifier_key:
		// Shift and Control keep the accent: Shift then a letter gives a
		// capital with its accent.
		return 0, 0
	case typed < ' ':
		// A key with no character or a control character drops the accent.
		state.accent = 0
		return 0, typed
	case typed == ' ':
		state.accent = 0
		return 0, waiting
	}
	state.accent = 0
	if accented, found := accented_letter(waiting, typed); found {
		return 0, accented
	}
	return waiting, typed
}

// key_records_needed gives the records of the input ring that the next
// press can need: two while an accent waits (the accent alone and the
// character), else one.
key_records_needed :: proc "contextless" (state: ^Dead_Key_State) -> int {
	return state.accent != 0 ? 2 : 1
}
