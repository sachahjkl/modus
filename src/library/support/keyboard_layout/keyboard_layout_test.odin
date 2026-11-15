#+build !freestanding
package keyboard_layout

import "core:strings"
import "core:testing"
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
SCAN_SPACE :: 0x39
@(private = "file")
SCAN_ENTER :: 0x1C
@(private = "file")
SCAN_LEFT_SHIFT :: 0x2A
@(private = "file")
SCAN_U_GRAVE :: 0x28 // ù in the layout of France.

// The letters of the layout of France are code points of the Latin-1
// Supplement; the same keys give digits with Shift, and ASCII in the
// layout of the United States.
@(test)
the_letters_of_the_layout_of_france :: proc(t: ^testing.T) {
	testing.expect_value(t, key_character(.French, false, SCAN_2), 'é')
	testing.expect_value(t, key_character(.French, true, SCAN_2), '2')
	testing.expect_value(t, key_character(.French, false, 0x08), 'è')
	testing.expect_value(t, key_character(.French, false, 0x0A), 'ç')
	testing.expect_value(t, key_character(.French, false, 0x0B), 'à')
	testing.expect_value(t, key_character(.French, false, SCAN_U_GRAVE), 'ù')
	testing.expect_value(t, key_character(.French, false, KEY_LESS_GREATER), '<')
	testing.expect_value(t, key_character(.French, true, KEY_LESS_GREATER), '>')
	testing.expect_value(t, key_character(.United_States, false, SCAN_2), '2')
	testing.expect_value(t, key_character(.French, false, KEY_DEAD_ACCENTS), 0)
	testing.expect_value(t, key_character(.French, false, TABLE_KEY_COUNT), 0)
	testing.expect_value(t, key_character(.French, false, 0x100 | SCAN_ENTER), 0)
	// Each character of each layout is ASCII or a character of the
	// Latin-1 Supplement past its control characters.
	for layout in settings.Keyboard_Layout {
		for shift in ([2]bool{false, true}) {
			for code in u32(0) ..< TABLE_KEY_COUNT {
				character := key_character(layout, shift, code)
				testing.expectf(t, character < 0x80 || character >= 0xA0 && character <= 0xFF, "%v %v %x: %x", layout, shift, code, character)
			}
		}
	}
}

// One key that a case presses.
@(private = "file")
Pressed_Key :: struct {
	code:  u32,
	shift: bool,
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
		{{{KEY_DEAD_ACCENTS, false}, {SCAN_E, false}}, "ê", 0},
		{{{KEY_DEAD_ACCENTS, true}, {SCAN_I, false}}, "ï", 0},
		// Shift keeps the accent: a capital with its accent.
		{{{KEY_DEAD_ACCENTS, false}, {SCAN_LEFT_SHIFT, true}, {SCAN_E, true}}, "Ê", 0},
		// Rule 1: a dead key while an accent waits.
		{{{KEY_DEAD_ACCENTS, false}, {KEY_DEAD_ACCENTS, false}}, "^", 0},
		{{{KEY_DEAD_ACCENTS, false}, {KEY_DEAD_ACCENTS, true}}, "^", 0},
		// Rule 2: a space gives the accent alone.
		{{{KEY_DEAD_ACCENTS, true}, {SCAN_SPACE, false}}, "¨", 0},
		// Rule 3 and rule 4: a letter with no accented form gives both.
		{{{KEY_DEAD_ACCENTS, false}, {SCAN_Z, false}}, "^z", 0},
		{{{KEY_DEAD_ACCENTS, true}, {SCAN_Y, true}}, "¨Y", 0},
		{{{KEY_DEAD_ACCENTS, true}, {SCAN_Y, false}}, "ÿ", 0},
		{{{KEY_DEAD_ACCENTS, false}, {SCAN_2, false}}, "^é", 0},
		// Rule 5: a control character drops the accent.
		{{{KEY_DEAD_ACCENTS, false}, {SCAN_ENTER, false}}, "\n", 0},
		// A dead key alone: nothing yet, the accent waits.
		{{{KEY_DEAD_ACCENTS, false}}, "", ACCENT_CIRCUMFLEX},
	}
	for item, number in cases {
		state: Dead_Key_State
		builder := strings.builder_make(context.temp_allocator)
		for key in item.keys {
			accent_alone, character := key_press(&state, .French, key.shift, key.code, key.code == SCAN_LEFT_SHIFT)
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
	_, character := key_press(&state, .United_States, false, KEY_DEAD_ACCENTS, false)
	testing.expect_value(t, character, '[')
	testing.expect_value(t, state.accent, 0)
}
