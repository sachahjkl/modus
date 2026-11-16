#+build !freestanding
package keyboard_layout

import "core:strings"
import "core:testing"
import "modus:contract/glyph_cache"
import "modus:contract/settings"

// The scan codes that the tests press.
@(private = "file")
SCAN_2 :: 0x03 // The key of 2: é in the layout of France.
@(private = "file")
SCAN_E :: 0x12
@(private = "file")
SCAN_I :: 0x17
@(private = "file")
SCAN_Z :: 0x11 // z in the layout of France.
@(private = "file")
SCAN_Y :: 0x15
@(private = "file")
SCAN_Q :: 0x10 // a in the layout of France.
@(private = "file")
SCAN_N :: 0x31
@(private = "file")
SCAN_3 :: 0x04 // The key of 3: " in the layout of France.
@(private = "file")
SCAN_SEMICOLON :: 0x27 // m in the layout of France.
@(private = "file")
SCAN_SPACE :: 0x39
@(private = "file")
SCAN_ENTER :: 0x1C
@(private = "file")
SCAN_BACKSPACE :: 0x0E
@(private = "file")
SCAN_LEFT_SHIFT :: 0x2A
@(private = "file")
SCAN_U_GRAVE :: 0x28 // ù in the layout of France.
@(private = "file")
SCAN_DOLLAR :: 0x1B // $ in the layout of France: the key right of the dead keys.
@(private = "file")
KEY_EXTENDED_PREFIX :: 0x100 // display.KEY_EXTENDED: the code of a key after the prefix 0xE0.
@(private = "file")
SCAN_RIGHT_ALT :: KEY_EXTENDED_PREFIX | 0x38 // AltGr.

// The letters of the layout of France are code points of the Latin-1
// Supplement; the same keys give digits with Shift, and ASCII in the
// layout of the United States.
@(test)
the_letters_of_the_layout_of_france :: proc(t: ^testing.T) {
	testing.expect_value(t, key_character(.French, {}, SCAN_2), 'é')
	testing.expect_value(t, key_character(.French, {.Shift}, SCAN_2), '2')
	testing.expect_value(t, key_character(.French, {}, 0x08), 'è')
	testing.expect_value(t, key_character(.French, {}, 0x0A), 'ç')
	testing.expect_value(t, key_character(.French, {}, 0x0B), 'à')
	testing.expect_value(t, key_character(.French, {}, SCAN_U_GRAVE), 'ù')
	testing.expect_value(t, key_character(.French, {}, KEY_LESS_GREATER), '<')
	testing.expect_value(t, key_character(.French, {.Shift}, KEY_LESS_GREATER), '>')
	testing.expect_value(t, key_character(.United_States, {}, SCAN_2), '2')
	testing.expect_value(t, key_character(.French, {}, KEY_DEAD_ACCENTS), 0)
	testing.expect_value(t, key_character(.French, {}, TABLE_KEY_COUNT), 0)
	testing.expect_value(t, key_character(.French, {}, KEY_EXTENDED_PREFIX | SCAN_ENTER), 0)
	// Each character of each layout, on each level, is a control character
	// that a key acts with (Enter, Tab, Backspace) or a character that the
	// fonts draw: it has a character index.
	for layout in settings.Keyboard_Layout {
		for held in ([4]Level_Keys{{}, {.Shift}, {.Alt_Graph}, {.Shift, .Alt_Graph}}) {
			for code in u32(0) ..< TABLE_KEY_COUNT {
				character := key_character(layout, held, code)
				_, drawn := glyph_cache.character_index(character)
				testing.expectf(t, character < ' ' || drawn, "%v %v %x: %x", layout, held, code, character)
			}
		}
	}
}

// One key of the third level and the character that it gives with AltGr.
@(private = "file")
Third_Level_Key :: struct {
	code:      u32,
	character: rune,
}

// AltGr gives the third level of the layout of France: the characters that
// an AZERTY keyboard prints on the right side of the keys of the digits.
@(test)
the_third_level_of_the_layout_of_france :: proc(t: ^testing.T) {
	keys := [?]Third_Level_Key {
		{SCAN_3, '#'},
		{0x05, '{'},
		{0x06, '['},
		{0x07, '|'},
		{0x09, '\\'},
		{0x0A, '^'},
		{0x0B, '@'},
		{0x0C, ']'},
		{0x0D, '}'},
		{SCAN_DOLLAR, '¤'},
		{SCAN_E, glyph_cache.EURO_SIGN},
	}
	for key in keys {
		testing.expectf(t, key_character(.French, {.Alt_Graph}, key.code) == key.character, "AltGr %x: %v, expected %v", key.code, key_character(.French, {.Alt_Graph}, key.code), key.character)
		// The third level ignores Shift.
		testing.expectf(t, key_character(.French, {.Shift, .Alt_Graph}, key.code) == key.character, "Shift AltGr %x: %v", key.code, key_character(.French, {.Shift, .Alt_Graph}, key.code))
		testing.expectf(t, dead_accent_of(.French, {.Alt_Graph}, key.code) == 0, "AltGr %x is not a dead key", key.code)
	}
	// The keys of 2 and 7 are dead keys with AltGr: no character.
	testing.expect_value(t, key_character(.French, {.Alt_Graph}, KEY_DEAD_TILDE), 0)
	testing.expect_value(t, key_character(.French, {.Alt_Graph}, KEY_DEAD_GRAVE), 0)
	testing.expect_value(t, dead_accent_of(.French, {.Alt_Graph}, KEY_DEAD_TILDE), ACCENT_TILDE)
	testing.expect_value(t, dead_accent_of(.French, {.Alt_Graph}, KEY_DEAD_GRAVE), ACCENT_GRAVE)
	// The key right of P is no dead key with AltGr.
	testing.expect_value(t, dead_accent_of(.French, {.Alt_Graph}, KEY_DEAD_ACCENTS), 0)
	// A letter other than e has no third level: no character.
	testing.expect_value(t, key_character(.French, {.Alt_Graph}, SCAN_SEMICOLON), 0)
	testing.expect_value(t, key_character(.French, {.Alt_Graph}, KEY_LESS_GREATER), 0)
	// The euro sign is a key with a character, so it does not combine with
	// a waiting accent: ^ then AltGr e gives ^ and €.
	state: Dead_Key_State
	_, _ = key_press(&state, .French, {}, KEY_DEAD_ACCENTS, false)
	accent_alone, euro := key_press(&state, .French, {.Alt_Graph}, SCAN_E, false)
	testing.expect_value(t, accent_alone, ACCENT_CIRCUMFLEX)
	testing.expect_value(t, euro, glyph_cache.EURO_SIGN)
	// Space, Enter and Backspace act as themselves.
	testing.expect_value(t, key_character(.French, {.Alt_Graph}, SCAN_SPACE), ' ')
	testing.expect_value(t, key_character(.French, {.Alt_Graph}, SCAN_ENTER), '\n')
	testing.expect_value(t, key_character(.French, {.Alt_Graph}, SCAN_BACKSPACE), 8)
	// The layout of the United States has no third level.
	testing.expect_value(t, key_character(.United_States, {.Alt_Graph}, SCAN_2), '2')
	testing.expect_value(t, key_character(.United_States, {.Shift, .Alt_Graph}, SCAN_2), '@')
	testing.expect_value(t, dead_accent_of(.United_States, {.Alt_Graph}, KEY_DEAD_TILDE), 0)
}

// One key that a case presses.
@(private = "file")
Pressed_Key :: struct {
	code: u32,
	held: Level_Keys,
}

// One case of the dead keys: the keys, the text of their key records, and
// the accent that waits after them.
@(private = "file")
Dead_Key_Case :: struct {
	keys:     []Pressed_Key,
	expected: string,
	waiting:  rune,
}

// The rules of a dead key, each with its case
// (src/md/features/keyboard_layout.md, "The chosen form").
@(test)
the_dead_keys_of_the_layout_of_france :: proc(t: ^testing.T) {
	cases := [?]Dead_Key_Case {
		{{{KEY_DEAD_ACCENTS, {}}, {SCAN_E, {}}}, "ê", 0},
		{{{KEY_DEAD_ACCENTS, {.Shift}}, {SCAN_I, {}}}, "ï", 0},
		// Shift keeps the accent: a capital with its accent.
		{{{KEY_DEAD_ACCENTS, {}}, {SCAN_LEFT_SHIFT, {.Shift}}, {SCAN_E, {.Shift}}}, "Ê", 0},
		// Rule 1: a dead key while an accent waits.
		{{{KEY_DEAD_ACCENTS, {}}, {KEY_DEAD_ACCENTS, {}}}, "^", 0},
		{{{KEY_DEAD_ACCENTS, {}}, {KEY_DEAD_ACCENTS, {.Shift}}}, "^", 0},
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}, {KEY_DEAD_GRAVE, {.Alt_Graph}}}, "~", 0},
		// Rule 2: a space gives the accent alone.
		{{{KEY_DEAD_ACCENTS, {.Shift}}, {SCAN_SPACE, {}}}, "¨", 0},
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}, {SCAN_SPACE, {}}}, "~", 0},
		{{{KEY_DEAD_GRAVE, {.Alt_Graph}}, {SCAN_SPACE, {}}}, "`", 0},
		// Rule 3 and rule 4: a letter with no accented form gives both.
		{{{KEY_DEAD_ACCENTS, {}}, {SCAN_Z, {}}}, "^z", 0},
		{{{KEY_DEAD_ACCENTS, {.Shift}}, {SCAN_Y, {.Shift}}}, "¨Y", 0},
		{{{KEY_DEAD_ACCENTS, {.Shift}}, {SCAN_Y, {}}}, "ÿ", 0},
		{{{KEY_DEAD_ACCENTS, {}}, {SCAN_2, {}}}, "^é", 0},
		// The dead keys of the third level: the tilde and the grave accent.
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}, {SCAN_N, {}}}, "ñ", 0},
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}, {SCAN_Q, {.Shift}}}, "Ã", 0},
		{{{KEY_DEAD_GRAVE, {.Alt_Graph}}, {SCAN_LEFT_SHIFT, {.Shift}}, {SCAN_Q, {.Shift}}}, "À", 0},
		{{{KEY_DEAD_GRAVE, {.Alt_Graph}}, {SCAN_E, {}}}, "è", 0},
		{{{KEY_DEAD_GRAVE, {.Alt_Graph}}, {SCAN_Z, {}}}, "`z", 0},
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}, {SCAN_3, {}}}, "~\"", 0},
		// Rule 6: AltGr keeps the accent, and a character of the third
		// level after a dead key gives both.
		{{{KEY_DEAD_ACCENTS, {}}, {SCAN_RIGHT_ALT, {.Alt_Graph}}, {0x05, {.Alt_Graph}}}, "^{", 0},
		// Rule 5: a control character drops the accent.
		{{{KEY_DEAD_ACCENTS, {}}, {SCAN_ENTER, {}}}, "\n", 0},
		// A key with no character on the third level drops the accent.
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}, {SCAN_Q, {.Alt_Graph}}}, "", 0},
		// The euro sign takes no accent: the accent, then the sign.
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}, {SCAN_E, {.Alt_Graph}}}, "~€", 0},
		// A dead key alone: nothing yet, the accent waits.
		{{{KEY_DEAD_ACCENTS, {}}}, "", ACCENT_CIRCUMFLEX},
		{{{KEY_DEAD_TILDE, {.Alt_Graph}}}, "", ACCENT_TILDE},
	}
	for item, number in cases {
		state: Dead_Key_State
		builder := strings.builder_make(context.temp_allocator)
		for key in item.keys {
			modifier_key := key.code == SCAN_LEFT_SHIFT || key.code == SCAN_RIGHT_ALT
			accent_alone, character := key_press(&state, .French, key.held, key.code, modifier_key)
			if accent_alone != 0 {
				strings.write_rune(&builder, accent_alone)
			}
			if character != 0 {
				strings.write_rune(&builder, character)
			}
		}
		text := strings.to_string(builder)
		testing.expectf(t, text == item.expected, "case %v: %q, expected %q", number, text, item.expected)
		testing.expectf(t, state.accent == item.waiting, "case %v: the accent that waits is %v", number, state.accent)
		testing.expect_value(t, key_records_needed(&state), item.waiting != 0 ? 2 : 1)
	}
	// The layout of the United States has no dead key.
	state: Dead_Key_State
	_, character := key_press(&state, .United_States, {}, KEY_DEAD_ACCENTS, false)
	testing.expect_value(t, character, '[')
	testing.expect_value(t, state.accent, 0)
	_, character = key_press(&state, .United_States, {.Alt_Graph}, KEY_DEAD_TILDE, false)
	testing.expect_value(t, character, '2')
	testing.expect_value(t, state.accent, 0)
}
