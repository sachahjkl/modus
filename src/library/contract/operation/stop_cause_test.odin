#+build !freestanding
package operation

import "core:testing"

// A cause word that names no member is refused: one past the last member,
// the largest word of 32 bits, a word past 32 bits whose low bits name a
// member, and the largest word.
@(test)
a_cause_word_of_no_member_is_refused :: proc(t: ^testing.T) {
	words := [?]u64{u64(max(Stop_Cause)) + 1, u64(max(u32)), u64(max(u32)) + 1 + u64(Stop_Cause.Itself), max(u64)}
	for word in words {
		_, cause_ok := stop_cause_of_word(word)
		testing.expectf(t, !cause_ok, "the cause word %x is refused", word)
		state, cause, ok := stop_of_words(u64(Process_State.Stopped), word)
		testing.expectf(t, !ok, "the cause word %x is refused with the state Stopped", word)
		testing.expect_value(t, state, Process_State.None)
		testing.expect_value(t, cause, Stop_Cause.None)
	}
}

// A state word that names no member is refused, with each cause: the
// refusal does not depend on the second word.
@(test)
a_state_word_of_no_member_is_refused :: proc(t: ^testing.T) {
	words := [?]u64{u64(max(Process_State)) + 1, u64(max(u32)) + 1 + u64(Process_State.Stopped), max(u64)}
	for word in words {
		for cause in Stop_Cause {
			_, _, ok := stop_of_words(word, u64(cause))
			testing.expectf(t, !ok, "the state word %x is refused with the cause %v", word, cause)
		}
	}
}

// A stopped process with no cause is a fault of the kernel: every stop
// records its cause.
@(test)
a_stop_with_no_cause_is_refused :: proc(t: ^testing.T) {
	_, _, ok := stop_of_words(u64(Process_State.Stopped), u64(Stop_Cause.None))
	testing.expect(t, !ok)
}

// A cause with a state that is not Stopped is refused: a process that runs,
// that was only created, or a slot with no process has not stopped.
@(test)
a_cause_of_a_process_that_did_not_stop_is_refused :: proc(t: ^testing.T) {
	for state in Process_State {
		if state == .Stopped {
			continue
		}
		for cause in Stop_Cause {
			if cause == .None {
				continue
			}
			_, _, ok := stop_of_words(u64(state), u64(cause))
			testing.expectf(t, !ok, "the state %v with the cause %v is refused", state, cause)
		}
	}
}

// Each text is a text of its own: two causes with one text would tell a
// reader one stop for another.
@(test)
each_cause_has_a_text_of_its_own :: proc(t: ^testing.T) {
	for first in Stop_Cause {
		testing.expectf(t, len(STOP_CAUSE_TEXTS[first]) > 0, "the cause %v has a text", first)
		for second in Stop_Cause {
			if first != second {
				testing.expectf(t, STOP_CAUSE_TEXTS[first] != STOP_CAUSE_TEXTS[second], "the causes %v and %v have one text", first, second)
			}
		}
	}
}

// The values of the contract: they cross the border of the kernel, so a
// change of one is a change of the contract.
@(test)
the_cause_words_are_the_words_of_the_contract :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(Stop_Cause.None), 0)
	testing.expect_value(t, u32(Stop_Cause.Itself), 1)
	testing.expect_value(t, u32(Stop_Cause.Holder), 2)
	testing.expect_value(t, u32(Stop_Cause.Last_Thread_Ended), 3)
	testing.expect_value(t, u32(Stop_Cause.Handles_Closed), 4)
	testing.expect_value(t, u32(Stop_Cause.Fault), 5)
	testing.expect_value(t, u32(Stop_Cause.Not_Committed), 6)
	testing.expect_value(t, u32(Stop_Cause.Cannot_Return), 7)
	testing.expect_value(t, u32(Stop_Cause.Fault_Unanswered), 8)
}

// The accepted pairs, the last case: each cause with the state Stopped, and
// the cause None with each other state.
@(test)
each_possible_pair_reads_back :: proc(t: ^testing.T) {
	for cause in Stop_Cause {
		if cause == .None {
			continue
		}
		state, read, ok := stop_of_words(u64(Process_State.Stopped), u64(cause))
		testing.expect(t, ok)
		testing.expect_value(t, state, Process_State.Stopped)
		testing.expect_value(t, read, cause)
		alone, alone_ok := stop_cause_of_word(u64(cause))
		testing.expect(t, alone_ok)
		testing.expect_value(t, alone, cause)
	}
	for state in Process_State {
		if state == .Stopped {
			continue
		}
		read_state, read, ok := stop_of_words(u64(state), u64(Stop_Cause.None))
		testing.expect(t, ok)
		testing.expect_value(t, read_state, state)
		testing.expect_value(t, read, Stop_Cause.None)
	}
}
