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
		state, cause, outcome, ok := stop_of_words(u64(Process_State.Stopped), word, u64(Stop_Outcome.Done))
		testing.expectf(t, !ok, "the cause word %x is refused with the state Stopped", word)
		testing.expect_value(t, state, Process_State.None)
		testing.expect_value(t, cause, Stop_Cause.None)
		testing.expect_value(t, outcome, Stop_Outcome.None)
	}
}

// An outcome word that names no member is refused, alone and in the triple
// of a stop of the process itself, which takes every member but None.
@(test)
an_outcome_word_of_no_member_is_refused :: proc(t: ^testing.T) {
	words := [?]u64{u64(max(Stop_Outcome)) + 1, u64(max(u32)), u64(max(u32)) + 1 + u64(Stop_Outcome.Done), max(u64)}
	for word in words {
		_, outcome_ok := stop_outcome_of_word(word)
		testing.expectf(t, !outcome_ok, "the outcome word %x is refused", word)
		state, cause, outcome, ok := stop_of_words(u64(Process_State.Stopped), u64(Stop_Cause.Itself), word)
		testing.expectf(t, !ok, "the outcome word %x is refused with the cause Itself", word)
		testing.expect_value(t, state, Process_State.None)
		testing.expect_value(t, cause, Stop_Cause.None)
		testing.expect_value(t, outcome, Stop_Outcome.None)
	}
}

// A state word that names no member is refused, with each cause: the
// refusal does not depend on the other words.
@(test)
a_state_word_of_no_member_is_refused :: proc(t: ^testing.T) {
	words := [?]u64{u64(max(Process_State)) + 1, u64(max(u32)) + 1 + u64(Process_State.Stopped), max(u64)}
	for word in words {
		for cause in Stop_Cause {
			for outcome in Stop_Outcome {
				_, _, _, ok := stop_of_words(word, u64(cause), u64(outcome))
				testing.expectf(t, !ok, "the state word %x is refused with the cause %v and the outcome %v", word, cause, outcome)
			}
		}
	}
}

// A stopped process with no cause is a fault of the kernel: every stop
// records its cause.
@(test)
a_stop_with_no_cause_is_refused :: proc(t: ^testing.T) {
	for outcome in Stop_Outcome {
		_, _, _, ok := stop_of_words(u64(Process_State.Stopped), u64(Stop_Cause.None), u64(outcome))
		testing.expectf(t, !ok, "the state Stopped with no cause and the outcome %v is refused", outcome)
	}
}

// A cause or an outcome with a state that is not Stopped is refused: a
// process that runs, that was only created, or a slot with no process has
// not stopped.
@(test)
a_stop_fact_of_a_process_that_did_not_stop_is_refused :: proc(t: ^testing.T) {
	for state in Process_State {
		if state == .Stopped {
			continue
		}
		for cause in Stop_Cause {
			for outcome in Stop_Outcome {
				if cause == .None && outcome == .None {
					continue
				}
				_, _, _, ok := stop_of_words(u64(state), u64(cause), u64(outcome))
				testing.expectf(t, !ok, "the state %v with the cause %v and the outcome %v is refused", state, cause, outcome)
			}
		}
	}
}

// A stop of the process itself with no outcome is refused: the kernel
// refuses that stop, so the words can only come from a fault of the kernel.
@(test)
a_stop_of_itself_with_no_outcome_is_refused :: proc(t: ^testing.T) {
	_, _, _, ok := stop_of_words(u64(Process_State.Stopped), u64(Stop_Cause.Itself), u64(Stop_Outcome.None))
	testing.expect(t, !ok)
}

// An outcome with a cause other than Itself is refused: a holder, a fault
// or the end of the last thread never chooses an outcome, so a reader that
// checks `outcome == .Done` has also checked the cause.
@(test)
an_outcome_of_another_cause_is_refused :: proc(t: ^testing.T) {
	for cause in Stop_Cause {
		if cause == .Itself || cause == .None {
			continue
		}
		for outcome in Stop_Outcome {
			if outcome == .None {
				continue
			}
			_, _, _, ok := stop_of_words(u64(Process_State.Stopped), u64(cause), u64(outcome))
			testing.expectf(t, !ok, "the cause %v with the outcome %v is refused", cause, outcome)
		}
	}
}

// The word of Process_Stop for a stop of the process itself: None, one
// past the last member, the largest word of 32 bits, a word past 32 bits
// whose low bits name a member, and the largest word are refused, with the
// largest member as the limit.
@(test)
an_operation_word_of_a_stop_of_itself_names_an_outcome :: proc(t: ^testing.T) {
	words := [?]u64{u64(Stop_Outcome.None), u64(max(Stop_Outcome)) + 1, u64(max(u32)), u64(max(u32)) + 1 + u64(Stop_Outcome.Done), max(u64)}
	for word in words {
		outcome, limit, ok := stop_outcome_of_operation_word(word, true)
		testing.expectf(t, !ok, "the word %x of a stop of itself is refused", word)
		testing.expect_value(t, outcome, Stop_Outcome.None)
		testing.expect_value(t, limit, u64(max(Stop_Outcome)))
	}
}

// The word of Process_Stop for a stop of another process: each word but 0
// is refused, with the limit 0, because a holder cannot claim the work of
// another process. The word 1 << 32 has no low bit: a border that read 32
// bits of it would take it for 0.
@(test)
an_operation_word_of_a_holder_is_zero :: proc(t: ^testing.T) {
	words := [?]u64{u64(Stop_Outcome.Done), u64(Stop_Outcome.Failed), u64(Stop_Outcome.Refused), u64(Stop_Outcome.Stopped_On_Request), u64(max(Stop_Outcome)) + 1, u64(1) << 32, max(u64)}
	for word in words {
		outcome, limit, ok := stop_outcome_of_operation_word(word, false)
		testing.expectf(t, !ok, "the word %x of a holder is refused", word)
		testing.expect_value(t, outcome, Stop_Outcome.None)
		testing.expect_value(t, limit, u64(0))
	}
	outcome, _, ok := stop_outcome_of_operation_word(0, false)
	testing.expect(t, ok)
	testing.expect_value(t, outcome, Stop_Outcome.None)
}

// Each text is a text of its own: two causes or two outcomes with one text
// would tell a reader one stop for another.
@(test)
each_cause_and_each_outcome_has_a_text_of_its_own :: proc(t: ^testing.T) {
	for first in Stop_Cause {
		testing.expectf(t, len(STOP_CAUSE_TEXTS[first]) > 0, "the cause %v has a text", first)
		for second in Stop_Cause {
			if first != second {
				testing.expectf(t, STOP_CAUSE_TEXTS[first] != STOP_CAUSE_TEXTS[second], "the causes %v and %v have one text", first, second)
			}
		}
	}
	for first in Stop_Outcome {
		testing.expectf(t, len(STOP_OUTCOME_TEXTS[first]) > 0, "the outcome %v has a text", first)
		for second in Stop_Outcome {
			if first != second {
				testing.expectf(t, STOP_OUTCOME_TEXTS[first] != STOP_OUTCOME_TEXTS[second], "the outcomes %v and %v have one text", first, second)
			}
		}
	}
}

// The values of the contract: they cross the border of the kernel, so a
// change of one is a change of the contract.
@(test)
the_words_are_the_words_of_the_contract :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(Stop_Cause.None), 0)
	testing.expect_value(t, u32(Stop_Cause.Itself), 1)
	testing.expect_value(t, u32(Stop_Cause.Holder), 2)
	testing.expect_value(t, u32(Stop_Cause.Last_Thread_Ended), 3)
	testing.expect_value(t, u32(Stop_Cause.Handles_Closed), 4)
	testing.expect_value(t, u32(Stop_Cause.Fault), 5)
	testing.expect_value(t, u32(Stop_Cause.Not_Committed), 6)
	testing.expect_value(t, u32(Stop_Cause.Cannot_Return), 7)
	testing.expect_value(t, u32(Stop_Cause.Fault_Unanswered), 8)
	testing.expect_value(t, u32(Stop_Outcome.None), 0)
	testing.expect_value(t, u32(Stop_Outcome.Done), 1)
	testing.expect_value(t, u32(Stop_Outcome.Failed), 2)
	testing.expect_value(t, u32(Stop_Outcome.Refused), 3)
	testing.expect_value(t, u32(Stop_Outcome.Stopped_On_Request), 4)
}

// The accepted triples, the last case: each outcome of a stop of itself,
// each other cause with no outcome, and the cause None with each other
// state; and each word of Process_Stop that names an outcome.
@(test)
each_possible_triple_reads_back :: proc(t: ^testing.T) {
	for cause in Stop_Cause {
		if cause == .None {
			continue
		}
		for outcome in Stop_Outcome {
			if (cause == .Itself) != (outcome != .None) {
				continue
			}
			state, read_cause, read_outcome, ok := stop_of_words(u64(Process_State.Stopped), u64(cause), u64(outcome))
			testing.expect(t, ok)
			testing.expect_value(t, state, Process_State.Stopped)
			testing.expect_value(t, read_cause, cause)
			testing.expect_value(t, read_outcome, outcome)
		}
		alone, alone_ok := stop_cause_of_word(u64(cause))
		testing.expect(t, alone_ok)
		testing.expect_value(t, alone, cause)
	}
	for state in Process_State {
		if state == .Stopped {
			continue
		}
		read_state, read_cause, read_outcome, ok := stop_of_words(u64(state), u64(Stop_Cause.None), u64(Stop_Outcome.None))
		testing.expect(t, ok)
		testing.expect_value(t, read_state, state)
		testing.expect_value(t, read_cause, Stop_Cause.None)
		testing.expect_value(t, read_outcome, Stop_Outcome.None)
	}
	for outcome in Stop_Outcome {
		alone, alone_ok := stop_outcome_of_word(u64(outcome))
		testing.expect(t, alone_ok)
		testing.expect_value(t, alone, outcome)
		if outcome == .None {
			continue
		}
		read, limit, ok := stop_outcome_of_operation_word(u64(outcome), true)
		testing.expect(t, ok)
		testing.expect_value(t, read, outcome)
		testing.expect_value(t, limit, u64(max(Stop_Outcome)))
	}
}
