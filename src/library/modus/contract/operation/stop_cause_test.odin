#+build !freestanding
#+build !modus
package operation

import "core:testing"
import "modus:contract/errors"

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

// Only Failed and Refused self-stops may attach an error record; Done,
// Stopped_On_Request, None, and every holder stop refuse any non-zero error
// address at edges (1, page-aligned, max(u32), 1 << 32, max(u64)).
@(test)
a_disallowed_stop_error_address_is_refused :: proc(t: ^testing.T) {
	addresses := [?]u64{1, 0x1000, u64(max(u32)), u64(1) << 32, max(u64)}
	valid_record := errors.error_make(.Bad_Value, .Bytes, 1, 7, 4)

	// Any holder stop with a non-zero error address is refused across all outcomes.
	for outcome in Stop_Outcome {
		testing.expect(t, stop_error_address_allowed(false, outcome, 0))
		accepted, ok0 := stop_error_of_operation(false, outcome, 0, valid_record)
		testing.expect(t, ok0)
		testing.expect_value(t, accepted, errors.Error_Record{})

		for address in addresses {
			testing.expectf(t, !stop_error_address_allowed(false, outcome, address), "holder stop must refuse error address %x with outcome %v", address, outcome)
			got, ok := stop_error_of_operation(false, outcome, address, valid_record)
			testing.expectf(t, !ok, "holder stop_error_of_operation must refuse address %x with outcome %v", address, outcome)
			testing.expect_value(t, got, errors.Error_Record{})
		}
	}

	// Self-stops with None, Done, or Stopped_On_Request must refuse every non-zero address.
	disallowed_self := [?]Stop_Outcome{.None, .Done, .Stopped_On_Request}
	for outcome in disallowed_self {
		testing.expect(t, !stop_outcome_takes_error(outcome))
		testing.expect(t, stop_error_address_allowed(true, outcome, 0))
		accepted, ok0 := stop_error_of_operation(true, outcome, 0, valid_record)
		testing.expect(t, ok0)
		testing.expect_value(t, accepted, errors.Error_Record{})

		for address in addresses {
			testing.expectf(t, !stop_error_address_allowed(true, outcome, address), "self-stop %v must refuse error address %x", outcome, address)
			got, ok := stop_error_of_operation(true, outcome, address, valid_record)
			testing.expectf(t, !ok, "self-stop %v must refuse record at address %x", outcome, address)
			testing.expect_value(t, got, errors.Error_Record{})
		}
	}
}

// A non-zero error record attached to Failed or Refused must carry a known
// non-None errors.Kind and a known errors.Unit; zero, negative, out-of-range,
// and extreme values are refused with zero accepted record.
@(test)
an_invalid_stop_error_record_is_refused :: proc(t: ^testing.T) {
	bad_kinds := [?]i64{
		i64(errors.Kind.None),
		-1,
		min(i64),
		i64(max(errors.Kind)) + 1,
		i64(max(u32)) + 1 + i64(errors.Kind.Bad_Value),
		max(i64),
	}
	bad_units := [?]i64{
		-1,
		min(i64),
		i64(max(errors.Unit)) + 1,
		i64(max(u32)) + 1 + i64(errors.Unit.Bytes),
		max(i64),
	}
	allowed_outcomes := [?]Stop_Outcome{.Failed, .Refused}

	for bad_kind in bad_kinds {
		rec := errors.Error_Record{kind = bad_kind, unit = i64(errors.Unit.None)}
		testing.expectf(t, !stop_error_record_valid(rec), "bad kind %d must be refused", bad_kind)
		for outcome in allowed_outcomes {
			got, ok := stop_error_of_operation(true, outcome, 0x4000, rec)
			testing.expectf(t, !ok, "outcome %v must refuse bad kind %d", outcome, bad_kind)
			testing.expect_value(t, got, errors.Error_Record{})
		}
	}

	for bad_unit in bad_units {
		rec := errors.Error_Record{kind = i64(errors.Kind.Bad_Value), unit = bad_unit}
		testing.expectf(t, !stop_error_record_valid(rec), "bad unit %d must be refused", bad_unit)
		for outcome in allowed_outcomes {
			got, ok := stop_error_of_operation(true, outcome, 0x4000, rec)
			testing.expectf(t, !ok, "outcome %v must refuse bad unit %d", outcome, bad_unit)
			testing.expect_value(t, got, errors.Error_Record{})
		}
	}
}

// Accepted cases for Failed and Refused self-stops: address 0 yields a zero
// record, and any valid non-None Kind with any valid Unit round-trips intact.
@(test)
a_valid_failed_or_refused_stop_error_record_is_accepted :: proc(t: ^testing.T) {
	allowed_outcomes := [?]Stop_Outcome{.Failed, .Refused}
	for outcome in allowed_outcomes {
		testing.expect(t, stop_outcome_takes_error(outcome))
		testing.expect(t, stop_error_address_allowed(true, outcome, 0))
		testing.expect(t, stop_error_address_allowed(true, outcome, 0x1000))

		// Address 0 produces zero record even if a non-zero scratch value is passed.
		zeroed, ok_zero := stop_error_of_operation(true, outcome, 0, errors.error_make(.Bad_Value, .Bytes))
		testing.expect(t, ok_zero)
		testing.expect_value(t, zeroed, errors.Error_Record{})

		for kind in errors.Kind {
			if kind == .None {
				continue
			}
			rec := errors.error_make(kind, .Pages, 2, 99, 64, 12)
			rec.operation = 5
			testing.expect(t, stop_error_record_valid(rec))
			accepted, ok := stop_error_of_operation(true, outcome, 0x8000, rec)
			testing.expect(t, ok)
			testing.expect_value(t, accepted, rec)
		}

		for unit in errors.Unit {
			rec := errors.error_make(.Refused, unit, 0, -1, 0, 3)
			testing.expect(t, stop_error_record_valid(rec))
			accepted, ok := stop_error_of_operation(true, outcome, 0x8000, rec)
			testing.expect(t, ok)
			testing.expect_value(t, accepted, rec)
		}
	}

	// Verify Process_Stop form and Stop_Report / Process_Report layouts.
	testing.expect_value(t, OPERATIONS[.Process_Stop].parameters[2].name, "error")
	testing.expect_value(t, OPERATIONS[.Process_Stop].parameters[2].form, Form.Address)
	stop_report: Stop_Report
	testing.expect_value(t, size_of(stop_report.error), size_of(errors.Error_Record))
	process_report: Process_Report
	testing.expect_value(t, size_of(process_report.handle_count), size_of(u64))
	testing.expect_value(t, size_of(process_report.handles_peak), size_of(u64))
	testing.expect_value(t, size_of(process_report.mapping_count), size_of(u64))
	testing.expect_value(t, size_of(process_report.mappings_peak), size_of(u64))
}
