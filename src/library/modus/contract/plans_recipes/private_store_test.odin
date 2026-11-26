#+build !freestanding
#+build !modus
package plans_recipes

import "core:testing"
import "modus:contract/blake3"

@(test)
a_decision_word_that_names_no_member_is_refused :: proc(t: ^testing.T) {
	for word in ([?]i64{-1, 4, 5, max(i64), min(i64)}) {
		_, ok := plan_display_decision_of_word(word)
		testing.expectf(t, !ok, "word %v names no decision", word)
	}
	for member in Plan_Display_Decision {
		decision, ok := plan_display_decision_of_word(i64(member))
		testing.expect(t, ok && decision == member)
	}
}

@(test)
the_names_of_the_objects_fit_an_entry_of_a_store :: proc(t: ^testing.T) {
	largest := plan_object_name(max(u64), max(u64), false)
	testing.expect_value(t, private_object_name_text(&largest), "plan_18446744073709551615_18446744073709551615")
	current := plan_object_name(0, 0, true)
	testing.expect_value(t, private_object_name_text(&current), "plan_0_current")
	recipe := blake3.hash(transmute([]u8)string("recipe"))
	realisation := realisation_object_name(recipe)
	testing.expect_value(t, realisation.length, 64)
	long_name := [MAX_ENTRY_NAME_BYTES]u8{}
	for &value in long_name {
		value = 'a'
	}
	project := project_object_name(max(u64), long_name[:])
	testing.expect(t, project.length <= 64, "a project name fits")
	other := project_object_name(max(u64), long_name[:MAX_ENTRY_NAME_BYTES - 1])
	testing.expect(t, private_object_name_text(&project) != private_object_name_text(&other), "two names give two objects")
}

@(test)
a_project_object_refuses_another_name_and_each_bad_length :: proc(t: ^testing.T) {
	buffer: [256]u8
	name := transmute([]u8)string("kernel")
	written, ok := encode_project_object(name, transmute([]u8)string("eval"), transmute([]u8)string("pins"), buffer[:])
	testing.expect(t, ok)
	evaluation, pins, decoded := decode_project_object(buffer[:written], name)
	testing.expect(t, decoded && string(evaluation) == "eval" && string(pins) == "pins")
	_, _, other := decode_project_object(buffer[:written], transmute([]u8)string("kernel2"))
	testing.expect(t, !other, "another name is refused")
	_, _, short := decode_project_object(buffer[:written - 1], name)
	testing.expect(t, !short, "a missing byte is refused")
	_, too_small := encode_project_object(name, nil, nil, buffer[:20])
	testing.expect(t, !too_small, "a buffer under the head is refused")
	_, empty_name := encode_project_object(nil, nil, nil, buffer[:])
	testing.expect(t, !empty_name, "an empty name is refused")
}
