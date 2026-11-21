package operation

import "modus:contract/enum_word"
import "modus:contract/errors"

// What a process says about its work when it stops itself
// (src/md/api/process_stop.md). The process passes it to `Process_Stop`
// when the target is the process itself; a holder that stops another
// process passes `None`, so no holder can forge the end of a process.
// `Process_State` gives its word as the third result, and
// `Process_Report.stop_outcome` holds it too. A reader takes the word
// through `stop_of_words` or `stop_outcome_of_word`, never through a cast.
//
// The outcome is `None` for each stop cause but `Itself`: a reader that
// checks `outcome == .Done` has also checked that the process stopped
// itself.
//
// Example: `system.stop(.Done)` at the end of the work gives the cause
// `Itself` and the outcome `Done`.
Stop_Outcome :: enum u32 {
	None               = 0, // No outcome: the process did not stop itself, or it runs.
	Done               = 1, // The work is finished. Not 0: a zeroed word or a forgotten argument must not claim a finished work.
	Failed             = 2, // The work could not be done. The cause is in its log.
	Refused            = 3, // Its input, its arguments or its context were refused: no fault of the process.
	Stopped_On_Request = 4, // A call or an event asked it to stop, and it stopped cleanly.
}

// The words of a reader for each stop outcome: a cell of a table, a part
// of a line. A reader compares the enum, never the text. The array is
// whole, so the compiler refuses a member with no text.
STOP_OUTCOME_TEXTS := [Stop_Outcome]string {
	.None               = "no outcome",
	.Done               = "done",
	.Failed             = "failed",
	.Refused            = "refused",
	.Stopped_On_Request = "stopped on request",
}

// stop_outcome_of_word is the border of the word of a stop outcome in a
// record of the kernel (`Process_Report.stop_outcome`): the member, or
// false for a word that names no outcome.
stop_outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Stop_Outcome, ok: bool) {
	return enum_word.member_of_word(Stop_Outcome, word)
}

// stop_outcome_of_operation_word is the border of the second argument of
// `Process_Stop`, which the kernel calls once, at its dispatch. A stop of
// the process itself must name an outcome other than `None`; a stop of
// another process must pass the word 0, because an outcome is the claim of
// a process about its own work. `limit` is the largest word that the
// target takes, for the error record of a refusal.
//
// Example: `stop_outcome_of_operation_word(u64(Stop_Outcome.Done), true)`
// is `.Done, 4, true`; the same word with `itself = false` is refused with
// the limit 0.
stop_outcome_of_operation_word :: proc "contextless" (word: u64, itself: bool) -> (outcome: Stop_Outcome, limit: u64, ok: bool) {
	if !itself {
		return .None, 0, word == 0
	}
	limit = u64(max(Stop_Outcome))
	known: bool
	outcome, known = stop_outcome_of_word(word)
	if !known || outcome == .None {
		return .None, limit, false
	}
	return outcome, limit, true
}

// stop_outcome_takes_error reports whether a self-stop with outcome may attach
// a typed errors.Error_Record (src/md/api/process_stop.md). Only Failed and
// Refused may attach an error record; Done, Stopped_On_Request and None cannot.
stop_outcome_takes_error :: proc "contextless" (outcome: Stop_Outcome) -> bool {
	switch outcome {
	case .Failed, .Refused:
		return true
	case .None, .Done, .Stopped_On_Request:
		return false
	}
	return false
}

// stop_error_address_allowed checks the third argument of Process_Stop at the
// kernel border: a non-zero error address is allowed only when a process stops
// itself with Failed or Refused. Done, Stopped_On_Request, None, and any stop
// by another holder must pass address 0.
stop_error_address_allowed :: proc "contextless" (itself: bool, outcome: Stop_Outcome, error_address: u64) -> bool {
	if error_address == 0 {
		return true
	}
	if !itself {
		return false
	}
	return stop_outcome_takes_error(outcome)
}

// stop_error_record_valid validates a copied errors.Error_Record attached to a
// Failed or Refused self-stop: its kind must name a known member other than
// None, and its unit must name a known errors.Unit member.
stop_error_record_valid :: proc "contextless" (record: errors.Error_Record) -> bool {
	kind, kind_ok := errors.kind_of_word(record.kind)
	if !kind_ok || kind == .None {
		return false
	}
	if _, unit_ok := errors.unit_of_word(record.unit); !unit_ok {
		return false
	}
	return true
}

// stop_error_of_operation is the combined pure border for the optional error
// record of Process_Stop. On refusal, accepted is always zero and ok is false.
// When error_address is 0 and allowed, accepted is always zero and ok is true.
stop_error_of_operation :: proc "contextless" (itself: bool, outcome: Stop_Outcome, error_address: u64, record: errors.Error_Record) -> (accepted: errors.Error_Record, ok: bool) {
	if !stop_error_address_allowed(itself, outcome, error_address) {
		return {}, false
	}
	if error_address == 0 {
		return {}, true
	}
	if !stop_error_record_valid(record) {
		return {}, false
	}
	return record, true
}
