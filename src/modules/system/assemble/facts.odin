package assemble

import "modus:contract/value_kinds"

// The log facts of the assembler (src/md/features/log_facts.md): the
// module file that it wrote, as a record of fields. The fact template is
// the sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. No field has the name
// of a column of the head of facts(): number, time, process, level.

// A module file written whole.
@(log_fact = "assemble: a module file of {size} with {exports} exports")
Module_File_Written :: struct {
	size:    value_kinds.Size_In_Bytes,
	exports: u64,
}
