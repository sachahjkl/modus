package assistant_window

// The log facts of the assistant (src/md/features/log_facts.md). A machine
// test waits on these sentences. The Text fields are the last fields: the
// serial line of a fact stops at its last byte that is not zero.

// The bytes of a Text field of a fact: a request, a line, a result, cut.
// The fields below write the number itself: the tool reads a fact type
// from its source, and takes a number there, not a constant.
FACT_TEXT_BYTES :: 96
// The bytes of a Text field of a name: a state, a kind of an error.
FACT_NAME_BYTES :: 32

// The window is open and draws.
@(log_fact = "assistant: ok")
Running :: struct {}

// The principal pressed Enter on a request: the window keeps it with its
// serial until a runner takes it.
@(log_fact = "assistant: request {serial} is kept: {text}")
Request_Kept :: struct {
	serial: u64,
	text:   [96]u8,
}

// A runner took a request: no other runner gets it.
@(log_fact = "assistant: request {serial} is taken")
Request_Taken :: struct {
	serial: u64,
}

// The reply of the model to a request shows.
@(log_fact = "assistant: the reply to request {serial} shows, {bytes} bytes: {text}")
Reply_Shown :: struct {
	serial: u64,
	bytes:  u64,
	text:   [96]u8,
}

// The runner refused the reply of the model at its border: the words of
// its error record show, and no act of it runs.
@(log_fact = "assistant: the reply to request {serial} was refused at the border: {kind}, unit {unit}, argument {argument}, value {value}, limit {limit}")
Reply_Refused_Shown :: struct {
	serial:   u64,
	argument: i64,
	value:    i64,
	limit:    i64,
	kind:     [32]u8,
	unit:     [32]u8,
}

// An act of a reply shows, before the bridge answers.
@(log_fact = "assistant: act {act} of request {serial} is proposed: {line}")
Act_Proposed :: struct {
	act:    u64,
	serial: u64,
	line:   [96]u8,
}

// The bridge answered an act: it ran, it refused it, or it stopped it for
// the principal.
@(log_fact = "assistant: act {act} is {state}: {text}")
Act_Outcome :: struct {
	act:   u64,
	state: [32]u8,
	text:  [96]u8,
}

// An act that the bridge stopped shows on the trusted display.
@(log_fact = "assistant: act {act} waits for the principal in the act dialog {dialog}")
Act_Dialog_Shown :: struct {
	act:    u64,
	dialog: u64,
}

// The trusted display refused to show the act dialog, or the assistant has
// no connection to it: the act waits, and runs nothing.
@(log_fact = "assistant: act {act} cannot show its act dialog: {cause}")
Act_Dialog_Refused :: struct {
	act:   u64,
	cause: [96]u8,
}

// The principal decided an act on the trusted display. Nothing runs: an
// allowed act runs only in an agent console of a wide grant.
@(log_fact = "assistant: act {act} is {state}; nothing ran")
Act_Decided :: struct {
	act:   u64,
	state: [32]u8,
}
