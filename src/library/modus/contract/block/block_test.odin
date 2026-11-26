#+build !freestanding
#+build !modus
package block

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "core:testing"

// A completion says that the device did not answer only with the outcome
// of a failed device, the kind No_Answer and the device as what did not
// answer; each word comes from the block service. Refused first, each
// giving false: an outcome word that names no member (one past the last
// outcome, the largest word), another outcome with the record No_Answer, a
// failure with a kind word that names no kind, a failure of another kind, No_Answer with another member of Unanswered, and an
// Unanswered word that names no member. The record that the block service
// writes is taken, last, for each command.
@(test)
device_did_not_answer_takes_only_its_record :: proc(t: ^testing.T) {
	answer := no_answer_values(.Read)
	for word in ([?]u32{u32(max(call_outcome.Call_Outcome)) + 1, max(u32)}) {
		testing.expectf(t, !device_did_not_answer(word, answer), "the outcome word %d names no outcome, and it is taken", word)
	}
	for outcome in call_outcome.Call_Outcome {
		if outcome != .Callee_Unavailable && outcome != .Stopped_After_A_Partial_Change {
			testing.expectf(t, !device_did_not_answer(u32(outcome), answer), "the outcome %v is taken as no answer", outcome)
		}
	}
	with_record :: proc(record: errors.Error_Record) -> [7]u64 {
		return errors.completion_values(record)
	}
	base := errors.completion_record(answer)
	unknown_kind := base
	unknown_kind.kind = i64(max(errors.Kind)) + 1
	testing.expect(t, !device_did_not_answer(u32(call_outcome.Call_Outcome.Callee_Unavailable), with_record(unknown_kind)))
	unknown_kind.kind = max(i64)
	testing.expect(t, !device_did_not_answer(u32(call_outcome.Call_Outcome.Callee_Unavailable), with_record(unknown_kind)))
	other_kind := base
	other_kind.kind = i64(errors.Kind.Device)
	testing.expect(t, !device_did_not_answer(u32(call_outcome.Call_Outcome.Callee_Unavailable), with_record(other_kind)))
	for unanswered in errors.Unanswered {
		if unanswered == .Device {
			continue
		}
		other := base
		other.found = i64(unanswered)
		testing.expectf(t, !device_did_not_answer(u32(call_outcome.Call_Outcome.Callee_Unavailable), with_record(other)), "the record No_Answer of %v is taken as the device", unanswered)
	}
	for word in ([?]i64{-1, i64(max(errors.Unanswered)) + 1, max(i64), min(i64)}) {
		unknown := base
		unknown.found = word
		testing.expectf(t, !device_did_not_answer(u32(call_outcome.Call_Outcome.Callee_Unavailable), with_record(unknown)), "the Unanswered word %d names no member, and it is taken", word)
	}
	for command in Command {
		testing.expect(t, device_did_not_answer(u32(device_failure_outcome(command)), no_answer_values(command)))
	}
	testing.expect_value(t, device_failure_outcome(.Write), call_outcome.Call_Outcome.Stopped_After_A_Partial_Change)
	testing.expect_value(t, device_failure_outcome(.Flush), call_outcome.Call_Outcome.Stopped_After_A_Partial_Change)
	testing.expect_value(t, device_failure_outcome(.Read), call_outcome.Call_Outcome.Callee_Unavailable)
	testing.expect_value(t, base.limit, i64(NO_ANSWER_BOUND_MILLISECONDS))
	testing.expect_value(t, base.operation, i64(Command.Read))
}

// The kind of a command record comes from a client of the block service:
// None, one past the last command and the largest word are refused, and
// give no command. Then each command but None comes back from its word.
@(test)
command_of_ring_word_refuses_a_word_that_names_no_command :: proc(t: ^testing.T) {
	refused := [?]u32{u32(Command.None), u32(max(Command)) + 1, max(u32)}
	for word in refused {
		read, ok := command_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, read, Command.None)
	}
	for member in Command {
		if member == .None {
			continue
		}
		read, ok := command_of_ring_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// The command of an error record comes from the block service. A word that
// names no command gives no name of a command and no name of a value:
// -1, one past the last command, the largest and the smallest word. A
// value past the names of its command has no name. Then each command
// names itself.
@(test)
a_command_that_names_no_member_has_no_name :: proc(t: ^testing.T) {
	refused := [?]i64{-1, i64(max(Command)) + 1, max(i64), min(i64)}
	for word in refused {
		_, ok := command_of_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, command_name(word), "an unknown command")
		testing.expect_value(t, argument_name(word, 1), "")
	}
	arguments := [?]i64{0, -1, i64(len(ARGUMENT_NAMES[.Read])) + 1, 8, max(i64)}
	for argument in arguments {
		testing.expect_value(t, argument_name(i64(Command.Read), argument), "")
	}
	for member in Command {
		read, ok := command_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
		testing.expect_value(t, command_name(i64(member)), COMMAND_NAMES[member])
	}
	testing.expect_value(t, argument_name(i64(Command.Read), 3), "place")
	testing.expect_value(t, argument_name(i64(Command.Attach), 1), "region")
}
