package console

import "modus:contract/errors"
import "modus:contract/palette_table"
import "modus:contract/value_kinds"

// The log facts that the console writes (src/md/features/log_facts.md,
// "The migration"): each line, as a record of fields. The
// facts that the console reads are in facts.odin. Each fact template is
// the sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A Text field comes
// last and holds its longest text and a zero byte: the serial line of a
// fact stops at its last byte that is not zero.
//
// A line of the console and a query of the completion have no bound below
// the values of one record: they are text views, the last fields of their
// facts. An error record is written by its fields.

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

// The root service did not answer the request of the store of the history.
@(log_fact = "console: the line history stays in memory: the root service did not answer")
History_Root_Silent :: struct {}

// The root service refused the store of the history: its error record.
@(log_fact = "console: the line history stays in memory: the root service refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
History_Root_Refused :: distinct errors.Error_Record_Fact_Fields

// The boot image has no valid file of the storage service for the store of
// the history.
@(log_fact = "console: the line history stays in memory: the boot image has no valid file of the storage service")
History_Storage_File_Missing :: struct {}

// The call ring or the call region of the store of the history does not
// map.
@(log_fact = "console: the line history stays in memory: the call ring or the call region does not map")
History_Region_Not_Mapped :: struct {}

// The history in its store is damaged: the history starts empty.
@(log_fact = "console: the line history is damaged in its store: the history starts empty")
History_Damaged :: struct {}

// The storage service refused the read of the history: its error record.
@(log_fact = "console: the line history cannot be read, and the history starts empty: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
History_Read_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service did not answer the read of the history.
@(log_fact = "console: the line history cannot be read: the storage service did not answer the read: the history starts empty")
History_Read_Unanswered :: struct {}

// The store holds no history yet.
@(log_fact = "console: no line history kept: the history starts empty")
No_History_Kept :: struct {}

// The storage service refused the save of the history: its error record.
// The line comes one time in a run.
@(log_fact = "console: the line history is not kept: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
History_Save_Refused :: distinct errors.Error_Record_Fact_Fields

// The store of the history did not answer the save.
@(log_fact = "console: the line history is not kept: the store of the history is not reachable")
History_Store_Unreachable :: struct {}

// The context of the console gives no random seed.
@(log_fact = "console: no random seed in the context")
No_Random_Seed :: struct {}

// The context of the console gives no terminal.
@(log_fact = "console: no terminal")
No_Terminal :: struct {}

// The second thread of the console does not start.
@(log_fact = "console: cannot start a thread")
Thread_Not_Started :: struct {}

// The console is ready for its first line.
@(log_fact = "console: ready")
Ready :: struct {}

// The edit line is empty again after a paste.
@(log_fact = "console: the line is empty again after a paste")
Line_Empty_After_Paste :: struct {}

// The root service refused the console as the palette provider.
@(log_fact = "console: the console is not the palette provider: the root service refused")
Provider_Refused :: struct {}

// The context gives no entry table of the palette.
@(log_fact = "console: the console is not the palette provider: no entry table")
Provider_Without_Table :: struct {}

// The entry table of the palette cannot be mapped.
@(log_fact = "console: the console is not the palette provider: the entry table cannot be mapped")
Provider_Table_Not_Mapped :: struct {}

// The context gives no ring of the palette.
@(log_fact = "console: the console is not the palette provider: no ring")
Provider_Without_Ring :: struct {}

// The manual shows the page that the palette asked for.
@(log_fact = "console: the manual shows the page that the palette asked for")
Manual_Page_Shown :: struct {}

// The console stopped being the palette provider.
@(log_fact = "console: the console is no more the palette provider")
Provider_Ended :: struct {}

// The console refused a choice of the palette: the sentence that the panel
// shows, one of the closed set of the callers of palette_refuse.
@(log_fact = "console: the palette choice is refused: {refusal}")
Palette_Choice_Refused :: struct {
	refusal: [88]u8,
}

// The lines of the console are text views: a line has up to
// line_editor.LINE_CAPACITY bytes (src/md/features/log_facts.md, "Text
// views").

// The input entered a line: the prompt, then the line.
@(log_fact = "> {line}")
Line_Entered :: struct {
	line: value_kinds.Text_View,
}

// The completion gave the line of the edit line.
@(log_fact = "console: the completion gave the line {line}")
Completion_Gave_Line :: struct {
	line: value_kinds.Text_View,
}

// The search of the history gave the line of the edit line.
@(log_fact = "console: the history search gave the line {line}")
History_Search_Gave_Line :: struct {
	line: value_kinds.Text_View,
}

// The edit line after a paste.
@(log_fact = "console: the line shows \"{line}\" after a paste")
Line_After_Paste :: struct {
	line: value_kinds.Text_View,
}

// The palette runs a line that the console built for it.
@(log_fact = "console: the palette runs {line}")
Palette_Runs_Line :: struct {
	line: value_kinds.Text_View,
}

// The completion list opens by Tab: its counts, the query and the first
// name, the longest ranking, and the runs of code of its first row.
@(log_fact = "console: the completion list opens by Tab: {matched_names} names of {names} match \"{query}\", the first is {first_name}; one ranking takes {longest_ranking} at most, over {rankings} keys; its first row has {code_runs} runs of code")
Completion_List_Opened :: struct {
	matched_names:   u64,
	names:           u64,
	longest_ranking: value_kinds.Time_In_Microseconds,
	rankings:        u64,
	code_runs:       u64,
	query:           value_kinds.Text_View,
	first_name:      value_kinds.Text_View,
}

// The palette opened a command in the edit line, with the caret between
// its parentheses.
@(log_fact = "console: the palette opens {entry_name}() in the edit line")
Palette_Opens_In_Edit_Line :: struct {
	entry_name: [72]u8,
}

// The bytes of the Text field of a refusal of a choice of the palette: the
// longest sentence, 81 bytes, and a zero byte, on 8 bytes.
CHOICE_REFUSAL_FIELD_BYTES :: 88

// The least time of one key with the completion list, by its parts, over
// the names of a set that the measure names.
@(log_fact = "console: one key with the completion list: the collect {collect}, the rank {rank}, the rows {rows_time}, the colors {colors}, over {names} names ({name_set}, the least of {batches} batches of {keys})")
Completion_Key_Measured :: struct {
	collect:   value_kinds.Nanoseconds_As_Microseconds,
	rank:      value_kinds.Nanoseconds_As_Microseconds,
	rows_time: value_kinds.Nanoseconds_As_Microseconds,
	colors:    value_kinds.Nanoseconds_As_Microseconds,
	names:     u64,
	batches:   u64,
	keys:      u64,
	name_set:  [32]u8,
}

// The bytes of the Text field of the set of names of the measure: the
// longest, "the names of this console", and a zero byte, on 8 bytes.
NAME_SET_FIELD_BYTES :: 32

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

// The getter of a row of buttons gave another member than the one that the
// row marked: the table that the console wrote marks the new one. A test
// waits for it before a picture of the mark.
@(log_fact = "console: the palette marks .{member} for {command} {parameter}")
Palette_Mark_Moved :: struct {
	member:    [32]u8,
	command:   [72]u8,
	parameter: [32]u8,
}
#assert(size_of(Palette_Mark_Moved{}.member) == MARK_MEMBER_FIELD_BYTES && size_of(Palette_Mark_Moved{}.command) == MARK_COMMAND_FIELD_BYTES && size_of(Palette_Mark_Moved{}.parameter) == MARK_PARAMETER_FIELD_BYTES)

// The bytes of the Text fields of a moved mark: the longest name of a
// member (31), of a command of a row (64) and of a row (24), and a zero
// byte, on 8 bytes.
MARK_MEMBER_FIELD_BYTES :: 32
MARK_COMMAND_FIELD_BYTES :: 72
MARK_PARAMETER_FIELD_BYTES :: 32

// A refresh of the marks of the palette ended: the getters that it sent to
// a service or an isolated process, and the getters of modules in the
// process of the console, which no refresh calls.
@(log_fact = "console: the palette refreshed its marks: {sent} getters sent, {in_the_console} getters in the process of the console not called")
Palette_Marks_Refreshed :: struct {
	sent:           u64,
	in_the_console: u64,
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
