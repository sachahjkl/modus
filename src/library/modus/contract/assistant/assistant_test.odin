#+build !freestanding
#+build !modus
package assistant

import "core:strings"
import "core:testing"

// The words of a kind and of a state: 0, one past the last member, the
// largest and a negative word are refused; each member passes.
@(test)
the_words_of_a_kind_and_a_state_name_a_member :: proc(t: ^testing.T) {
	for word in ([]i64{0, -1, 7, max(i64), min(i64)}) {
		_, ok := act_kind_of_word(word)
		testing.expectf(t, !ok, "the kind word %d", word)
	}
	for word in ([]i64{0, -1, 8, 255, max(i64)}) {
		_, ok := act_state_of_word(word)
		testing.expectf(t, !ok, "the state word %d", word)
	}
	for kind in Act_Kind {
		got, ok := act_kind_of_word(i64(kind))
		testing.expect(t, ok && got == kind)
		named, named_ok := act_kind_of_name(ACT_KIND_NAMES[kind])
		testing.expect(t, named_ok && named == kind)
	}
	for state in Act_State {
		got, ok := act_state_of_word(i64(state))
		testing.expect(t, ok && got == state)
	}
	for word in ([]i64{0, -1, 8, 255, max(i64), min(i64)}) {
		_, ok := agent_loop_end_of_word(word)
		testing.expectf(t, !ok, "the loop end word %d", word)
	}
	for cause in Agent_Loop_End {
		got, ok := agent_loop_end_of_word(i64(cause))
		testing.expect(t, ok && got == cause)
	}
	for name in ([]string{"", "Eval_Lex", "eval_lex ", "evallex", "unknown_act"}) {
		_, ok := act_kind_of_name(name)
		testing.expectf(t, !ok, "the name %q", name)
	}
}

// The runner never writes a decision of the principal, and an act takes one
// outcome and one decision, in that order; an act allowed by the principal
// finishes once as Done or Refused after verified execution.
@(test)
the_states_of_an_act_change_once_in_their_order :: proc(t: ^testing.T) {
	testing.expect(t, !act_state_from_runner(.Allowed_By_Principal))
	testing.expect(t, !act_state_from_runner(.Refused_By_Principal))
	testing.expect(t, !act_state_from_runner(.Proposed))
	testing.expect(t, !act_state_from_runner(.Not_Shown))
	for from in Act_State {
		for to in Act_State {
			allowed := (from == .Proposed && (to == .Done || to == .Refused || to == .Awaiting_Principal)) ||
				(from == .Awaiting_Principal && (to == .Allowed_By_Principal || to == .Refused_By_Principal || to == .Not_Shown)) ||
				(from == .Allowed_By_Principal && (to == .Done || to == .Refused))
			testing.expectf(t, act_state_changes(from, to) == allowed, "%v to %v", from, to)
		}
	}
}

// A text at its edges: none, one byte, the bound, one past it, a line end,
// a control byte, and a cut character.
@(test)
a_text_crosses_with_its_bound_and_no_control :: proc(t: ^testing.T) {
	testing.expect_value(t, text_check("", 10), Text_Refusal.Empty)
	testing.expect_value(t, text_check("a", 10), Text_Refusal.None)
	testing.expect_value(t, text_check(strings.repeat("a", REQUEST_TEXT_BYTES, context.temp_allocator), REQUEST_TEXT_BYTES), Text_Refusal.None)
	testing.expect_value(t, text_check(strings.repeat("a", REQUEST_TEXT_BYTES + 1, context.temp_allocator), REQUEST_TEXT_BYTES), Text_Refusal.Too_Long)
	testing.expect_value(t, text_check("a\nb", 10), Text_Refusal.Not_Text)
	testing.expect_value(t, text_check("a\x01", 10), Text_Refusal.Not_Text)
	testing.expect_value(t, text_check("\xc3", 10), Text_Refusal.Not_Text)
	testing.expect_value(t, text_check("été", 10), Text_Refusal.None)
}

// A name of an act: none, an upper case letter, a digit first, a period, a
// space, an argument, one past the bound; the bound itself passes.
@(test)
an_act_name_is_one_identifier_within_its_bound :: proc(t: ^testing.T) {
	for name in ([]string{"", "Plans", "1plans", "plans.apply", "plans apply", "apply(1)", "_x", strings.repeat("a", ACT_NAME_BYTES + 1, context.temp_allocator)}) {
		testing.expectf(t, !act_name_valid(name), "the name %q", name)
	}
	testing.expect(t, act_name_valid("a"))
	testing.expect(t, act_name_valid("plan_diff_ask2"))
	testing.expect(t, act_name_valid(strings.repeat("a", ACT_NAME_BYTES, context.temp_allocator)))
}

// The word of a shape and the text of a fixed field: 0, one past the last
// member and the largest word name no shape; a byte after the zero, a
// control byte and a cut character are no text; an empty field, a field
// full to its last byte and a text with its zeros pass.
@(test)
a_shape_and_a_fixed_text_cross_their_border :: proc(t: ^testing.T) {
	for word in ([]i64{0, -1, 3, max(i64), min(i64)}) {
		_, ok := act_table_shape_of_word(word)
		testing.expectf(t, !ok, "the shape word %d", word)
	}
	for shape in Act_Table_Shape {
		got, ok := act_table_shape_of_word(i64(shape))
		testing.expect(t, ok && got == shape)
	}
	refused := [?][4]u8{{'a', 0, 'b', 0}, {'a', '\n', 0, 0}, {0xC3, 0, 0, 0}, {0, 0, 0, 1}, {0x7F, 0, 0, 0}}
	for field in refused {
		field := field
		_, ok := fixed_text(field[:])
		testing.expectf(t, !ok, "the field %v", field)
	}
	empty := [4]u8{}
	text, ok := fixed_text(empty[:])
	testing.expect(t, ok && text == "")
	full := [4]u8{'a', 'b', 'c', 'd'}
	text, ok = fixed_text(full[:])
	testing.expect(t, ok && text == "abcd")
	short := [4]u8{'h', 'i', 0, 0}
	text, ok = fixed_text(short[:])
	testing.expect(t, ok && text == "hi")
}
