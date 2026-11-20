package debugger_window

import "modus:contract/value_kinds"
import "modus:support/system"

// The log facts of the window of the debugger (src/md/features/log_facts.md,
// "The migration"): each line that has a value, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so a wait of a machine test on that sentence reads it as before. A Text
// field comes last and holds its longest text and a zero byte: the serial
// line of a fact stops at its last byte that is not zero.
//
// A debug place has up to PLACE_LIMIT bytes, more than the values of one
// record hold: the lines of a breakpoint, of a watch and of the memory at a
// place stay text.

// The bytes of the Text field of the words of an act on one thread: the
// longest, "one line, over each call, of", and a zero byte.
ACT_WORDS_FIELD_BYTES :: 32
// The bytes of the Text field of what follows the thread: empty, or the
// words of a thread that runs and stops later, and a zero byte.
PENDING_WORDS_FIELD_BYTES :: 40
// The words of a thread that runs, and whose stop comes later.
PENDING_WORDS :: ": it runs, and its stop comes later"
#assert(len(PENDING_WORDS) < PENDING_WORDS_FIELD_BYTES)
// The bytes of the Text field of the name of a procedure: the field of the
// rows of the service, whose last byte is zero.
PROCEDURE_FIELD_BYTES :: 80
// The bytes of the Text field of the card of the variables: "the
// registers" or "the variables", and a zero byte.
CARD_WORDS_FIELD_BYTES :: 16

// The window attached to a process.
@(log_fact = "debugger_window: attached to {debugged_process}")
Attached_To :: struct {
	debugged_process: value_kinds.Module_Name_Field,
}

// The window detached from a process.
@(log_fact = "debugger_window: detached from {debugged_process}")
Detached_From :: struct {
	debugged_process: value_kinds.Module_Name_Field,
}

// An act on each thread of the attached process.
@(log_fact = "debugger_window: {act}")
Act_On_Each_Thread :: struct {
	act: [32]u8,
}

// An act on one thread: held, let run, or one step; a step that the
// service could not end at once says that the stop comes later.
@(log_fact = "debugger_window: {act} the thread {thread}{pending}")
Act_On_Thread :: struct {
	thread:  i64,
	act:     [32]u8,
	pending: [40]u8,
}

// A click or a key chose a thread.
@(log_fact = "debugger_window: chose the thread {thread}")
Thread_Chosen :: struct {
	thread: i64,
}

// A frame of the chosen thread is chosen: its procedure, and the rows of
// the cards of its variables and of its source.
@(log_fact = "debugger_window: the frame {frame} of the thread {thread}: {procedure}, {variables} variables, {source_lines} source lines")
Frame_Chosen :: struct {
	frame:        i64,
	thread:       i64,
	variables:    u64,
	source_lines: u64,
	procedure:    [80]u8,
}

// A breakpoint is removed.
@(log_fact = "debugger_window: removed the breakpoint {breakpoint}")
Breakpoint_Removed :: struct {
	breakpoint: i64,
}

// The card of the variables shows the registers or the variables.
@(log_fact = "debugger_window: the card of the variables shows {card}: {rows} rows")
Variables_Card_Shown :: struct {
	rows: u64,
	card: [16]u8,
}

// The window reached the service debugger: its exports.
@(log_fact = "debugger_window: ok, connected to the service debugger; {exports} exports, each record with the size of its description")
Window_Ready :: struct {
	exports: u64,
}

// process_field gives the field of the name of a process in a row of the
// service: its text before the first zero byte.
process_field :: proc "contextless" (name: []u8) -> value_kinds.Module_Name_Field {
	return value_kinds.module_name_field(system.name_of(name))
}
