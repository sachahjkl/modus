package c_compiler

import "modus:contract/value_kinds"

// The log facts of the C compiler (src/md/features/log_facts.md): the word
// of the C entry that names no result, and the text that it wrote, as
// records of fields. Each fact template is the sentence that the line
// wrote before it was a fact, so a wait of a machine test on that sentence
// reads it as before. No field has the name of a column of the head of
// facts(): number, time, process, level.

// The C entry gave a word that names no result: the word of another party
// keeps its number, as the line wrote it.
@(log_fact = "c_compiler: the C entry gave the word {word}, which names no result")
Entry_Word_Refused :: struct {
	word: i64,
}

// The compiler wrote its text.
@(log_fact = "c_compiler: a text of {size}")
Text_Written :: struct {
	size: value_kinds.Size_In_Bytes,
}
