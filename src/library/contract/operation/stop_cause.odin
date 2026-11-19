package operation

import "modus:contract/enum_word"

// Why a process stopped: the kernel records it at every stop, and no
// process chooses or forges it (src/md/api/process_stop.md). `Process_State`
// gives its word as the second result, `Stop_Report.cause` and
// `Process_Report.stop_cause` hold it too. A reader takes the word through
// `stop_of_words` or `stop_cause_of_word`, never through a cast.
//
// The vector of a fault is not in the cause: the stop report holds it in
// `vector`, so the cause stays a closed set.
//
// Example: a null pointer read gives the state `Stopped`, the cause
// `Fault`, and `Stop_Report.vector == u32(Fault_Kind.Page_Fault)`.
Stop_Cause :: enum u32 {
	None              = 0, // The process has not stopped.
	Itself            = 1, // It called `Process_Stop` on itself. Its `Stop_Outcome` says why.
	Holder            = 2, // Another process stopped it with a process handle with **Control**.
	Last_Thread_Ended = 3, // Its last thread ended with `Thread_Stop`. It chose no stop outcome.
	Handles_Closed    = 4, // The last handle to it closed.
	Fault             = 5, // A processor exception that no fault handler took, or that a handler answered with a stop. The vector is in the stop report.
	Not_Committed     = 6, // A page fault on a page of an Uncommitted object that is not committed.
	Cannot_Return     = 7, // The processor refused the return of the kernel to one of its threads: its instruction or stack address (docs/ARCHITECTURE.md, "The return to a process"). The stop report has the address.
	Fault_Unanswered  = 8, // Its fault ring ended while one of its threads waited for an answer there: the handler thread ended, or `Fault_Handler_Set` named another handler or ended the delivery.
}

// The words of a reader for each stop cause: a cell of a table, a part of a
// line. A reader compares the enum, never the text. The array is whole, so
// the compiler refuses a member with no text.
STOP_CAUSE_TEXTS := [Stop_Cause]string {
	.None              = "not stopped",
	.Itself            = "itself",
	.Holder            = "a holder",
	.Last_Thread_Ended = "its last thread ended",
	.Handles_Closed    = "its last handle closed",
	.Fault             = "a fault",
	.Not_Committed     = "a page that is not committed",
	.Cannot_Return     = "the kernel cannot return to its thread",
	.Fault_Unanswered  = "a fault that no thread can answer",
}

// stop_cause_of_word is the border of the word of a stop cause in a record
// of the kernel (`Stop_Report.cause`, `Process_Report.stop_cause`): the
// member, or false for a word that names no cause.
stop_cause_of_word :: proc "contextless" (word: u64) -> (cause: Stop_Cause, ok: bool) {
	return enum_word.member_of_word(Stop_Cause, word)
}

// stop_of_words is the one border of the first three results of
// `Process_State`: the state, the stop cause and the stop outcome. It
// refuses a word that names no member, the state `Stopped` with no cause, a
// cause or an outcome with a state other than `Stopped`, the cause `Itself`
// with no outcome, and an outcome with a cause other than `Itself`. Each
// refusal is a fault of the kernel: a reader stops on it, and never takes
// the words for a stop that did not happen.
//
// Example: `stop_of_words(u64(Process_State.Stopped), u64(Stop_Cause.Itself),
// u64(Stop_Outcome.Done))` is `.Stopped, .Itself, .Done, true`;
// `stop_of_words(u64(Process_State.Stopped), u64(Stop_Cause.Holder),
// u64(Stop_Outcome.Done))` is refused.
stop_of_words :: proc "contextless" (state_word: u64, cause_word: u64, outcome_word: u64) -> (state: Process_State, cause: Stop_Cause, outcome: Stop_Outcome, ok: bool) {
	state_known, cause_known, outcome_known: bool
	state, state_known = enum_word.member_of_word(Process_State, state_word)
	cause, cause_known = enum_word.member_of_word(Stop_Cause, cause_word)
	outcome, outcome_known = enum_word.member_of_word(Stop_Outcome, outcome_word)
	if !state_known || !cause_known || !outcome_known {
		return {}, {}, {}, false
	}
	// A stopped process always has its cause, and a process that runs or a
	// slot with no process has none.
	if (state == .Stopped) != (cause != .None) {
		return {}, {}, {}, false
	}
	// Only a process that stopped itself chose an outcome, and it always
	// chose one: the kernel refuses its stop with none.
	if (cause == .Itself) != (outcome != .None) {
		return {}, {}, {}, false
	}
	return state, cause, outcome, true
}
