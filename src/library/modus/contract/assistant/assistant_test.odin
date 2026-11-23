#+build !freestanding
package assistant

import "core:strings"
import "core:testing"

// The words of a kind and of a state: 0, one past the last member, the
// largest and a negative word are refused; each member passes.
@(test)
the_words_of_a_kind_and_a_state_name_a_member :: proc(t: ^testing.T) {
	for word in ([]i64{0, -1, 2, max(i64), min(i64)}) {
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
	for name in ([]string{"", "Eval_Lex", "eval_lex ", "evallex", "read_screen"}) {
		_, ok := act_kind_of_name(name)
		testing.expectf(t, !ok, "the name %q", name)
	}
}

// The runner never writes a decision of the principal, and an act takes one
// outcome and one decision, in that order, never two.
@(test)
the_states_of_an_act_change_once_in_their_order :: proc(t: ^testing.T) {
	testing.expect(t, !act_state_from_runner(.Allowed_By_Principal))
	testing.expect(t, !act_state_from_runner(.Refused_By_Principal))
	testing.expect(t, !act_state_from_runner(.Proposed))
	testing.expect(t, !act_state_from_runner(.Not_Shown))
	for from in Act_State {
		for to in Act_State {
			allowed := (from == .Proposed && (to == .Done || to == .Refused || to == .Awaiting_Principal)) || (from == .Awaiting_Principal && (to == .Allowed_By_Principal || to == .Refused_By_Principal || to == .Not_Shown))
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
