#+build !freestanding
package operation

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
		_, ok := member_of_word(Enumeration_With_A_Hole, word)
		testing.expect(t, !ok, "a word of no member is refused")
	}
	_, operation_ok := member_of_word(Operation, u64(max(Operation)) + 1)
	testing.expect(t, !operation_ok)
	_, device_ok := member_of_word(Device_Kind, u64(max(Device_Kind)) + 1)
	testing.expect(t, !device_ok)
	_, inspect_ok := member_of_word(Inspect_Kind, u64(max(Inspect_Kind)) + 1)
	testing.expect(t, !inspect_ok)
	_, answer_ok := member_of_word(Fault_Answer_Kind, u64(max(Fault_Answer_Kind)) + 1)
	testing.expect(t, !answer_ok)
	_, action_ok := member_of_word(Fault_Handler_Action, u64(max(Fault_Handler_Action)) + 1)
	testing.expect(t, !action_ok)
	_, command_ok := member_of_word(Thread_Control_Command, u64(max(Thread_Control_Command)) + 1)
	testing.expect(t, !command_ok)
	_, largest_ok := member_of_word(Thread_Control_Command, max(u64))
	testing.expect(t, !largest_ok)
}

// A word past the width of the enumeration is refused: a cast to the width
// would cut its high bits and give a member (256 would be the level Info, and
// 2^32 + 1 the strategy Round_Robin).
@(test)
a_word_past_the_width_of_the_enumeration_is_refused :: proc(t: ^testing.T) {
	_, level_ok := member_of_word(Log_Level, u64(max(u8)) + 1)
	testing.expect(t, !level_ok)
	_, level_largest_ok := member_of_word(Log_Level, max(u64))
	testing.expect(t, !level_largest_ok)
	_, strategy_ok := member_of_word(Strategy, u64(max(u32)) + 1 + u64(Strategy.Round_Robin))
	testing.expect(t, !strategy_ok)
	_, operation_ok := member_of_word(Operation, u64(max(u32)) + 1 + u64(Operation.Log))
	testing.expect(t, !operation_ok)
}

// Each member reads back from its word, the last case.
@(test)
each_member_reads_back_from_its_word :: proc(t: ^testing.T) {
	for member in Enumeration_With_A_Hole {
		read, ok := member_of_word(Enumeration_With_A_Hole, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Log_Level {
		read, ok := member_of_word(Log_Level, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Fault_Handler_Action {
		read, ok := member_of_word(Fault_Handler_Action, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Device_Kind {
		read, ok := member_of_word(Device_Kind, u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}
