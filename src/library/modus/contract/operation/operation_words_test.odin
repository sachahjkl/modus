#+build !freestanding
package operation

import "modus:contract/enum_word"
import "core:testing"

// An enumeration with a hole in its numbering and no member at 0: a test of
// the range would let the word of the hole pass.
@(private = "file")
Enumeration_With_A_Hole :: enum u64 {
	First = 1,
	Third = 3,
}

// The words of no member are refused first: 0 where 0 names nothing, the
// hole, one past the last member, and the largest word.
@(test)
a_word_of_no_member_is_refused :: proc(t: ^testing.T) {
	words := [?]u64{u64(Enumeration_With_A_Hole.First) - 1, u64(Enumeration_With_A_Hole.First) + 1, u64(Enumeration_With_A_Hole.Third) + 1, max(u64)}
	for word in words {
		_, ok := enum_word.member_of_word(Enumeration_With_A_Hole, word)
		testing.expect(t, !ok, "a word of no member is refused")
	}
	_, operation_ok := enum_word.member_of_word(Operation, u64(max(Operation)) + 1)
	testing.expect(t, !operation_ok)
	_, device_ok := enum_word.member_of_word(Device_Kind, u64(max(Device_Kind)) + 1)
	testing.expect(t, !device_ok)
	_, inspect_ok := enum_word.member_of_word(Inspect_Kind, u64(max(Inspect_Kind)) + 1)
	testing.expect(t, !inspect_ok)
	_, answer_ok := enum_word.member_of_word(Fault_Answer_Kind, u64(max(Fault_Answer_Kind)) + 1)
	testing.expect(t, !answer_ok)
	_, action_ok := enum_word.member_of_word(Fault_Handler_Action, u64(max(Fault_Handler_Action)) + 1)
	testing.expect(t, !action_ok)
	_, command_ok := enum_word.member_of_word(Thread_Control_Command, u64(max(Thread_Control_Command)) + 1)
	testing.expect(t, !command_ok)
	_, largest_ok := enum_word.member_of_word(Thread_Control_Command, max(u64))
	testing.expect(t, !largest_ok)
}

// A word past the width of the enumeration is refused: a cast to the width
// would cut its high bits and give a member (256 would be the level Info, and
// 2^32 + 1 the strategy Round_Robin).
@(test)
a_word_past_the_width_of_the_enumeration_is_refused :: proc(t: ^testing.T) {
	_, level_ok := enum_word.member_of_word(Log_Level, u64(max(u8)) + 1)
	testing.expect(t, !level_ok)
	_, level_largest_ok := enum_word.member_of_word(Log_Level, max(u64))
	testing.expect(t, !level_largest_ok)
	_, strategy_ok := enum_word.member_of_word(Strategy, u64(max(u32)) + 1 + u64(Strategy.Round_Robin))
	testing.expect(t, !strategy_ok)
	_, operation_ok := enum_word.member_of_word(Operation, u64(max(u32)) + 1 + u64(Operation.Log))
	testing.expect(t, !operation_ok)
}

// Each member reads back from its word, the last case.
@(test)
each_member_reads_back_from_its_word :: proc(t: ^testing.T) {
	for member in Enumeration_With_A_Hole {
		read, ok := enum_word.member_of_word(Enumeration_With_A_Hole, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Log_Level {
		read, ok := enum_word.member_of_word(Log_Level, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Fault_Handler_Action {
		read, ok := enum_word.member_of_word(Fault_Handler_Action, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Device_Kind {
		read, ok := enum_word.member_of_word(Device_Kind, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// Event_Rule.kind is a u32 word: 0 (None), one past max(Event_Kind), and
// max(u32) are refused, along with unknown flags, non-zero reserved words,
// disallowed detail/duration combinations, and out-of-range limits.
@(test)
event_rule_check_fields_refuses_bad_words_and_fields :: proc(t: ^testing.T) {
	bad_kinds := [?]u32{0, u32(max(Event_Kind)) + 1, max(u32)}
	for word in bad_kinds {
		kind, ok := event_rule_check_fields(Event_Rule{kind = word})
		testing.expectf(t, !ok, "event rule kind %d must be refused", word)
		testing.expect_value(t, kind, Event_Kind.None)
	}
	bad_rules := [?]Event_Rule {
		{kind = u32(Event_Kind.Operation), flags = transmute(Event_Rule_Flags)u32(0x2)},
		{kind = u32(Event_Kind.Operation), reserved = {1, 0, 0}},
		{kind = u32(Event_Kind.Operation), reserved = {0, 1, 0}},
		{kind = u32(Event_Kind.Operation), reserved = {0, 0, 1}},
		{kind = u32(Event_Kind.Operation), least_nanoseconds = EVENT_LEAST_NANOSECONDS_MOST + 1},
		{kind = u32(Event_Kind.Operation), one_in = EVENT_ONE_IN_MOST + 1},
		{kind = u32(Event_Kind.Switch), flags = {.Match_Detail}},
		{kind = u32(Event_Kind.Switch), least_nanoseconds = 1},
		{kind = u32(Event_Kind.Fault), least_nanoseconds = 1},
	}
	for rule, index in bad_rules {
		_, ok := event_rule_check_fields(rule)
		testing.expectf(t, !ok, "bad event rule %d must be refused", index)
	}
	valid_rules := [?]struct {
		rule: Event_Rule,
		kind: Event_Kind,
	} {
		{{kind = u32(Event_Kind.Operation), flags = {.Match_Detail}, detail = u64(Operation.Log), least_nanoseconds = EVENT_LEAST_NANOSECONDS_MOST, one_in = EVENT_ONE_IN_MOST}, .Operation},
		{{kind = u32(Event_Kind.Switch), one_in = 1}, .Switch},
		{{kind = u32(Event_Kind.Fault), flags = {.Match_Detail}, detail = 14}, .Fault},
		{{kind = u32(Event_Kind.Lock_Wait), least_nanoseconds = 100}, .Lock_Wait},
	}
	for item in valid_rules {
		kind, ok := event_rule_check_fields(item.rule)
		testing.expect(t, ok)
		testing.expect_value(t, kind, item.kind)
	}
}
