package console

import "modus:contract/palette_table"
import "modus:contract/value_kinds"

// The log facts that the console writes (src/md/features/log_facts.md,
// "The migration"): each line that has a value, as a record of fields. The
// facts that the console reads are in facts.odin. Each fact template is
// the sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A Text field comes
// last and holds its longest text and a zero byte: the serial line of a
// fact stops at its last byte that is not zero.
//
// A line that holds a line of the console, a query of the completion or a
// sentence of an error has no bound below the values of one record: it
// stays text.

// The bytes of the Text field of a search of the history: SEARCH_CAPACITY,
// a zero byte, and the bytes that end the record on 8 bytes.
SEARCH_FIELD_BYTES :: 72
#assert(SEARCH_FIELD_BYTES > SEARCH_CAPACITY)
// The bytes of the Text field of a problem of the file of the history: the
// longest text of line_editor.history_file_problem_texts, and a zero byte.
HISTORY_PROBLEM_FIELD_BYTES :: 48
// The bytes of the Text field of the name of a palette entry:
// palette_table.NAME_CAPACITY, a zero byte, and the bytes that end the
// record on 8 bytes.
ENTRY_NAME_FIELD_BYTES :: 72
#assert(ENTRY_NAME_FIELD_BYTES > palette_table.NAME_CAPACITY)
// The bytes of the Text field of the kind of a result of the palette: the
// longest name of kind_names, or "an error", and a zero byte.
RESULT_KIND_FIELD_BYTES :: 16

// A module record of a process whose writer word names no writer: the
// cell of its writer stays empty.
@(log_fact = "console: process_modules: the module record at {base} of the process slot {slot} has the writer word {writer_word}, which names no writer")
Module_Writer_Refused :: struct {
	base:        u64,
	slot:        u64,
	writer_word: u64,
}

// A module from memory, which a call host runs in a sandboxed process.
@(log_fact = "console: {module_name} is a module from memory: {size}, the hash {module_hash}")
Module_From_Memory :: struct {
	size:        value_kinds.Size_In_Bytes,
	module_hash: value_kinds.Hash_Field,
	module_name: value_kinds.Module_Name_Field,
}

// The search of the history chose a row: a machine test takes the picture
// of the list after this line.
@(log_fact = "console: the history search \"{search}\" chooses the row {row} of {rows}")
History_Search_Chose :: struct {
	row:    u64,
	rows:   u64,
	search: [72]u8,
}

// The file of the history has more bytes than a history holds.
@(log_fact = "console: the line history has more than {limit}: the history starts empty")
History_Too_Long :: struct {
	limit: value_kinds.Size_In_Bytes,
}

// The file of the history breaks a rule of its form.
@(log_fact = "console: the line history is refused, {history_problem}: the history starts empty")
History_Refused :: struct {
	history_problem: [48]u8,
}

// The history of the run before is read.
@(log_fact = "console: the line history: {lines} lines kept from before the stop")
History_Restored :: struct {
	lines: u64,
}

// Escape stops the line that runs in a call: the time since its start,
// and the keys that wait for its end.
@(log_fact = "console: Escape stops the line after {line_time}; keys that wait: {waiting_keys}")
Escape_Stops_Line :: struct {
	line_time:    value_kinds.Time_In_Milliseconds,
	waiting_keys: u64,
}

// The keys that wait for the end of a line fill their place: a key is
// lost, and the loss begins.
@(log_fact = "console: {capacity} keys wait for the end of the line, and the console reads on to find an Escape: a new key is lost")
Waiting_Keys_Full :: struct {
	capacity: u64,
}

// A line ended after keys were lost while it ran.
@(log_fact = "console: the line ended: {lost_keys} keys were lost while it ran")
Line_Ended_With_Lost_Keys :: struct {
	lost_keys: u64,
}

// The console wrote the table of the palette.
@(log_fact = "console: the palette table has {entries} entries, generation {table_generation}")
Palette_Table_Written :: struct {
	entries:          u64,
	table_generation: u64,
}

// The compositor sent a word that names no command of the palette.
@(log_fact = "console: the palette sent the command word {command_word}, which names no command: it is refused")
Palette_Command_Refused :: struct {
	command_word: u64,
}

// The console gave the palette the candidates of a parameter of an entry.
@(log_fact = "console: the palette gets {candidates} candidates for the parameter {parameter} of {entry_name}")
Palette_Candidates_Given :: struct {
	candidates: u64,
	parameter:  u64,
	entry_name: [72]u8,
}

// The result of a choice of the palette has no drawer in the panel: the
// console shows it.
@(log_fact = "console: the result of the palette choice is in the console: {result_kind}")
Palette_Result_In_Console :: struct {
	result_kind: [16]u8,
}

// The palette shows the result of a choice: its kind, or an error, and its
// lines.
@(log_fact = "console: the palette gets {result_kind}, {result_lines} lines")
Palette_Result_Given :: struct {
	result_lines: u64,
	result_kind: [16]u8,
}
