package imports

import "modus:contract/value_kinds"

// The log facts of imports (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// The measures of a call and of a bind write nanoseconds with two decimals,
// a field of hundredths: the lines wrote one decimal, which no field kind
// writes for a time in nanoseconds.

// A call through an import slot, to calendar and to its replacement: the
// least of the runs, in nanoseconds.
@(log_fact = "imports: a call through an import slot: {call} ns to calendar, {replaced_call} ns to calendar_fixed in its place, the least of {runs} runs of {calls} calls")
Import_Call_Measured :: struct {
	call:          value_kinds.Hundredths,
	replaced_call: value_kinds.Hundredths,
	runs:          u64,
	calls:         u64,
}

// The bind of agenda, with and with no check of a replacement, and its
// load.
@(log_fact = "imports: the bind of agenda: {bind} ns, and {checked_bind} ns with the check of the replacement; the load of agenda and its import: {load}, and {replaced_load}")
Import_Bind_Measured :: struct {
	bind:          value_kinds.Hundredths,
	checked_bind:  value_kinds.Hundredths,
	load:          value_kinds.Time_In_Microseconds,
	replaced_load: value_kinds.Time_In_Microseconds,
}

// The bytes of the Text fields of a wrong answer: the name of a case has at
// most 52 bytes, and the answer that note writes at most 87 when each count
// in it has at most 10 digits (the longest is the answer of the shared
// code, 34 bytes of words and three counts).
CASE_FIELD_BYTES :: 56
ANSWER_FIELD_BYTES :: 88

// The context of the process holds no random seed.
@(log_fact = "imports: no random seed in the context")
No_Random_Seed :: struct {}

// A case of the loader gave another answer than the one it must give.
@(log_fact = "imports: wrong answer: {case_text}: {answer}")
Answer_Wrong :: struct {
	case_text: [56]u8,
	answer:    [88]u8,
}

// The bytes of the Text field of the word of a module writer: the longest,
// "not found", has 9 bytes.
WRITER_FIELD_BYTES :: 16

// A module record of this process holds a word of its writer that names no
// writer: the case of the module records then fails.
@(log_fact = "imports: the module record at {base} has the writer word {writer_word}, which names no writer")
Module_Writer_Unknown :: struct {
	base:        u64,
	writer_word: u64,
}

// The module records that the root service wrote for this process, and the
// record of calendar that this process loaded.
@(log_fact = "imports: the module record of the root service: {refused} of {changes} changes refused with Starter_Module, writer {process_writer}; calendar, loaded by this process: writer {own_writer}")
Root_Service_Module_Record :: struct {
	refused:        u64,
	changes:        u64,
	process_writer: [16]u8,
	own_writer:     [16]u8,
}

// Each case of the loader gave its answer.
@(log_fact = "imports: ok, {cases} cases")
Cases_Passed :: struct {
	cases: u64,
}

// Two processes import calendar at two places, and share one copy of its
// code.
@(log_fact = "imports: two processes import calendar at two places: one copy of its code, {pages}, mapped {mappings} times")
Calendar_Code_Shared :: struct {
	pages:    value_kinds.Size_In_Pages,
	mappings: u64,
}

#assert(size_of(Root_Service_Module_Record) == 16 + 2 * WRITER_FIELD_BYTES)

// writer_field gives the Text field of the word of a module writer, or
// "not found".
writer_field :: proc "contextless" (word: string) -> [WRITER_FIELD_BYTES]u8 {
	return value_kinds.text_field(word, WRITER_FIELD_BYTES)
}
