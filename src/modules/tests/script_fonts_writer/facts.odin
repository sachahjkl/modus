package script_fonts_writer

import "modus:contract/value_kinds"

// The log facts of the test module script_fonts_writer
// (src/md/features/log_facts.md).

// The process writes to the first byte of the script font set.
@(log_fact = "script_fonts_writer: writes the byte at {address}, the first of the script font set that this process maps read-only")
Writes :: struct {
	address: value_kinds.Hexadecimal_Sixteen_Digits,
}

// No set is mapped: the case needs a machine whose set is mapped.
@(log_fact = "script_fonts_writer: WRONG: no script font set is mapped in this process")
Not_Mapped :: struct {}

// The write passed: the set is not read-only in this process.
@(log_fact = "script_fonts_writer: WRONG: the write to the script font set did not stop the process")
Write_Did_Not_Stop :: struct {}
