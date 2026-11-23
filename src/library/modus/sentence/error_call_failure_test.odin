#+build !freestanding
package sentence

import "core:strings"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/supervision"

// Callee_Stopped decodes op.Stop_Cause and op.Stop_Outcome into words and
// never prints raw numbers for known or unknown words.
@(test)
callee_stopped_decodes_words_without_raw_numbers :: proc(t: ^testing.T) {
	buffer: [256]u8
	render :: proc(buffer: []u8, record: ^errors.Error_Record) -> string {
		writer := Writer{buffer = buffer}
		error_text(&writer, record, "storage.read", "")
		return written(&writer)
	}

	// Known causes other than Itself.
	fault := errors.error_make(.Callee_Stopped, .None, 0, i64(op.Stop_Cause.Fault))
	testing.expect_value(t, render(buffer[:], &fault), "storage.read: the process that ran the call stopped: a fault")

	holder := errors.error_make(.Callee_Stopped, .None, 0, i64(op.Stop_Cause.Holder))
	testing.expect_value(t, render(buffer[:], &holder), "storage.read: the process that ran the call stopped: a holder")

	// Itself with a known stop outcome.
	itself_failed := errors.error_make(.Callee_Stopped, .None, 0, i64(op.Stop_Cause.Itself), 0, i64(op.Stop_Outcome.Failed))
	testing.expect_value(t, render(buffer[:], &itself_failed), "storage.read: the process that ran the call stopped: failed")

	// Itself with zero outcome or unknown outcome: no raw number.
	itself_none := errors.error_make(.Callee_Stopped, .None, 0, i64(op.Stop_Cause.Itself), 0, 0)
	testing.expect_value(t, render(buffer[:], &itself_none), "storage.read: the process that ran the call stopped itself")

	itself_unknown := errors.error_make(.Callee_Stopped, .None, 0, i64(op.Stop_Cause.Itself), 0, 99)
	testing.expect_value(t, render(buffer[:], &itself_unknown), "storage.read: the process that ran the call stopped itself, with an unknown stop outcome")

	// Zero cause, unknown cause, negative cause: no raw number.
	no_cause := errors.error_make(.Callee_Stopped)
	testing.expect_value(t, render(buffer[:], &no_cause), "storage.read: the process that ran the call stopped")

	bad_cause := errors.error_make(.Callee_Stopped, .None, 0, 77)
	testing.expect_value(t, render(buffer[:], &bad_cause), "storage.read: the process that ran the call stopped, with an unknown stop cause")

	neg_cause := errors.error_make(.Callee_Stopped, .None, 0, -1)
	testing.expect_value(t, render(buffer[:], &neg_cause), "storage.read: the process that ran the call stopped, with an unknown stop cause")
}

// Connection_Ended decodes supervision.Connection_State into words and
// never prints raw numbers for known or unknown states.
@(test)
connection_ended_decodes_words_without_raw_numbers :: proc(t: ^testing.T) {
	buffer: [256]u8
	render :: proc(buffer: []u8, found: i64) -> string {
		record := errors.error_make(.Connection_Ended, .None, 0, 0, 0, found)
		writer := Writer{buffer = buffer}
		error_text(&writer, &record, "storage.read", "")
		return written(&writer)
	}

	testing.expect_value(t, render(buffer[:], 0), "storage.read: the connection of the call ended")
	testing.expect_value(t, render(buffer[:], i64(supervision.Connection_State.Connected)), "storage.read: the connection of the call ended while connected")
	testing.expect_value(t, render(buffer[:], i64(supervision.Connection_State.Holder_Stopped)), "storage.read: the connection of the call ended because its holder stopped")
	testing.expect_value(t, render(buffer[:], i64(supervision.Connection_State.Reconnecting)), "storage.read: the connection of the call ended while reconnecting")
	testing.expect_value(t, render(buffer[:], i64(supervision.Connection_State.Closed)), "storage.read: the connection of the call was closed")
	testing.expect_value(t, render(buffer[:], 99), "storage.read: the connection of the call ended in an unknown state")
	testing.expect_value(t, render(buffer[:], -1), "storage.read: the connection of the call ended in an unknown state")
}

// call_failure_text writes no PascalCase outcome identifier on the headline,
// and gives outcome_of_word's Answer_Unreadable a clear sentence stating
// the answer named an unknown call outcome.
@(test)
call_failure_text_headline_and_unreadable_outcome :: proc(t: ^testing.T) {
	buffer: [256]u8
	// Normal refusal: headline has export and sentence only.
	record := errors.error_make(.Too_Long, .Bytes, 2, 40, 36)
	writer := Writer{buffer = buffer[:]}
	call_failure_text(&writer, .Argument_Refused, &record, "add", "note")
	line := written(&writer)
	testing.expect_value(t, line, "add: the argument note has 40 bytes; it can have at most 36 bytes")
	testing.expect(t, !strings.contains(line, "Argument_Refused"))

	// Unknown outcome word from outcome_of_word: clear sentence, no raw word.
	outcome, unreadable := call_outcome.outcome_of_word(99)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Answer_Unreadable)
	writer = Writer{buffer = buffer[:]}
	call_failure_text(&writer, outcome, &unreadable, "storage.read", "")
	testing.expect_value(t, written(&writer), "storage.read: the answer named an unknown call outcome")
}
