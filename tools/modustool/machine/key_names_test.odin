package machine

import "core:strings"
import "core:testing"

// Each character that a typed step of the main scenario presses has a key:
// a character with no key stops the machine test at its step, after minutes
// of the run, where this test finds it on the host. A placeholder that the
// tool replaces before it types ({record}, {viewer key}, {generation+4}) is
// left out: it holds only letters, digits, spaces, `+` and `_`.
@(test)
each_typed_character_of_the_main_scenario_has_a_key :: proc(t: ^testing.T) {
	for step, index in scenario {
		if step.kind != .Type && step.kind != .Keys {
			continue
		}
		text := placeholders_removed(step.text)
		_, unknown := key_names_of_a_text(text)
		testing.expectf(t, unknown < 0, "step %d: no key for the character %d of %q", index + 1, unknown, text)
	}
}

// The braces of a C source are typed with Shift on the keys of the square
// brackets; the brackets themselves need no Shift.
@(test)
the_braces_and_the_brackets_have_their_keys :: proc(t: ^testing.T) {
	testing.expect_value(t, key_name('{'), "shift-bracket_left")
	testing.expect_value(t, key_name('}'), "shift-bracket_right")
	testing.expect_value(t, key_name('['), "bracket_left")
	testing.expect_value(t, key_name(']'), "bracket_right")
}

// placeholders_removed gives a text with each placeholder of the tool left
// out, in the temporary memory.
@(private = "file")
placeholders_removed :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	place := 0
	for place < len(text) {
		if text[place] == '{' {
			end := strings.index_byte(text[place:], '}')
			if end > 1 && is_placeholder(text[place + 1:place + end]) {
				place += end + 1
				continue
			}
		}
		strings.write_byte(&builder, text[place])
		place += 1
	}
	return strings.to_string(builder)
}

@(private = "file")
is_placeholder :: proc(inside: string) -> bool {
	for character in transmute([]u8)inside {
		switch character {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', ' ', '+', '_':
		case:
			return false
		}
	}
	return true
}
