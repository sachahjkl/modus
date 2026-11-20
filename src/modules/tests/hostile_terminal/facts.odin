package hostile_terminal

import "modus:contract/value_kinds"

// The log facts of the hostile terminal client
// (src/md/features/log_facts.md): each line, as a record of fields. Each fact template is the sentence that the line wrote before it
// was a fact, so the wait of the machine test reads it as before.

// The context holds no terminal.
@(log_fact = "hostile_terminal: no terminal")
No_Terminal :: struct {}

// The terminal read the three records whose kind word names no record,
// and the line after them. A kind word keeps its number: it names no
// member of an enum.
@(log_fact = "hostile_terminal: the terminal read the kind words {first_word}, {second_word} and {third_word}, and the line after them: as it must")
Kind_Words_Read :: struct {
	first_word:  u64,
	second_word: u64,
	third_word:  u64,
}

// The terminal did not read the records within the hang bound.
@(log_fact = "hostile_terminal: WRONG: the terminal did not read its records in {bound}")
Wrong_Records_Not_Read :: struct {
	bound: value_kinds.Time_In_Milliseconds,
}
