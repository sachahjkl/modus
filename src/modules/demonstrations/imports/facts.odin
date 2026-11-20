package imports

import "modus:contract/value_kinds"

// The log facts of imports (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// Four lines stay text: the line with no value, the wrong answer of a case,
// whose answer is a free text of the case, and the two measures of a call
// and of a bind, which write nanoseconds with one decimal.

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
