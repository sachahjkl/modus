package edit

import "modus:contract/errors"
import "modus:contract/value_kinds"

// The context gives no private store: the text is not kept.
@(log_fact = "edit: no store: the text is not kept")
No_Store :: struct {}

// The text in the store is damaged: the next change writes a new one.
@(log_fact = "edit: the text in the store is damaged: the editor starts empty, and the next change writes a new text")
Stored_Text_Damaged :: struct {}

// A group of changes ended, and the store took the whole text as a new
// version.
@(log_fact = "edit: kept a text of {length} in the generation {generation}")
Text_Kept :: struct {
	length:     value_kinds.Size_In_Bytes,
	generation: u64,
}

// The store holds no text yet.
@(log_fact = "edit: a new store: an empty text")
New_Store :: struct {}

// A move that extends the selection left it empty.
@(log_fact = "edit: nothing is selected")
Nothing_Selected :: struct {}

// An undo with a text that is not kept: it has no version.
@(log_fact = "edit: undo: the text is not kept: it has no version")
Undo_Without_Version :: struct {}

// A redo with a text that is not kept: it has no version.
@(log_fact = "edit: redo: the text is not kept: it has no version")
Redo_Without_Version :: struct {}

// The first picture of the editor is presented.
@(log_fact = "edit: ok, the first picture is presented")
Window_Ready :: struct {}

// The call of the storage service that failed: each one is a fact type of
// its own, with the error record of the service or with no answer.
Storage_Step :: enum {
	Read_Text,
	Write_Text,
	List_Versions,
	Read_Version,
	Restore_Version,
}

// The storage service refused the read of the text: the text is not kept.
@(log_fact = "edit: the text cannot be read, and it is not kept: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Text_Read_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused the text: the changes after it are not kept.
@(log_fact = "edit: the storage service refused the text, and the changes after it are not kept: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Text_Write_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused the list of the versions.
@(log_fact = "edit: the versions cannot be listed: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Versions_List_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused the read of a version.
@(log_fact = "edit: the version cannot be read: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Version_Read_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused the restore of a version.
@(log_fact = "edit: the version cannot be restored: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Version_Restore_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service did not answer the read of the text.
@(log_fact = "edit: the text cannot be read: the storage service did not answer the call: the text is not kept")
Text_Read_Unanswered :: struct {}

// The storage service did not answer the write of the text.
@(log_fact = "edit: the storage service refused the text: the storage service did not answer the call: the changes after it are not kept")
Text_Write_Unanswered :: struct {}

// The storage service did not answer the list of the versions.
@(log_fact = "edit: the versions cannot be listed: the storage service did not answer the call")
Versions_List_Unanswered :: struct {}

// The storage service did not answer the read of a version.
@(log_fact = "edit: the version cannot be read: the storage service did not answer the call")
Version_Read_Unanswered :: struct {}

// The storage service did not answer the restore of a version.
@(log_fact = "edit: the version cannot be restored: the storage service did not answer the call")
Version_Restore_Unanswered :: struct {}

// The log facts of the editor (src/md/features/log_facts.md, "The
// migration"): each line, as a record of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. A Text field
// comes last and holds its longest text and a zero byte: the serial line of
// a fact stops at its last byte that is not zero.

// The bytes of the Text field of an action of the versions: "undo" or
// "redo", and a zero byte.
ACTION_FIELD_BYTES :: 8
// The bytes of the Text field of the words after a restored version: empty,
// or the words of replaced sequences, and a zero byte.
REPLACED_WORDS_FIELD_BYTES :: 40
// The words of a restored version whose invalid sequences were replaced.
REPLACED_WORDS :: ", with invalid sequences replaced"
#assert(len(REPLACED_WORDS) < REPLACED_WORDS_FIELD_BYTES)
// The bytes of the Text field of a problem of the walk of the versions:
// the longest text of text_model.walk_problem_texts, and a zero byte.
WALK_PROBLEM_FIELD_BYTES :: 48

// The text in the store has more bytes than a text of the editor.
@(log_fact = "edit: the text in the store has more than {text_capacity}: the editor starts empty and keeps nothing")
Stored_Text_Too_Long :: struct {
	text_capacity: value_kinds.Size_In_Bytes,
}

// The text in the store passes the bytes of a text of the editor once its
// invalid sequences are replaced.
@(log_fact = "edit: the text in the store passes {text_capacity} with its replacement characters: the editor starts empty and keeps nothing")
Cleaned_Text_Too_Long :: struct {
	text_capacity: value_kinds.Size_In_Bytes,
}

// The text of the last run is restored, with no sequence to replace.
@(log_fact = "edit: restored a text of {length}, {lines} lines")
Text_Restored :: struct {
	length: value_kinds.Size_In_Bytes,
	lines:  u64,
}

// The text of the last run is restored, with its invalid sequences
// replaced.
@(log_fact = "edit: restored a text of {length}, {lines} lines, with {replaced} invalid sequences replaced by the replacement character")
Text_Restored_With_Replacements :: struct {
	length:   value_kinds.Size_In_Bytes,
	lines:    u64,
	replaced: u64,
}

// The selection after a move that extends it.
@(log_fact = "edit: the selection has {selected}, from byte {first} to byte {last}, over {lines} lines")
Selection_Made :: struct {
	selected: value_kinds.Size_In_Bytes,
	first:    u64,
	last:     u64,
	lines:    u64,
}

// The text has more versions than the editor lists: the undo or the redo
// does nothing.
@(log_fact = "edit: {action}: the text has {versions} versions, more than the {listed_versions} that the editor lists")
Too_Many_Versions :: struct {
	versions:        i64,
	listed_versions: u64,
	action:          [8]u8,
}

// A version is too long for the editor: the undo or the redo does nothing.
@(log_fact = "edit: {action}: the version of generation {generation} is too long for the editor")
Version_Too_Long :: struct {
	generation: i64,
	action:     [8]u8,
}

// An undo or a redo made a version the current text.
@(log_fact = "edit: {action}: the text has {length}, the caret at byte {caret}, the version of generation {generation}{replaced_words}")
Version_Restored :: struct {
	length:         value_kinds.Size_In_Bytes,
	caret:          u64,
	generation:     i64,
	action:         [8]u8,
	replaced_words: [40]u8,
}

// The walk of the versions has no step for an undo or a redo.
@(log_fact = "edit: {action}: {walk_problem}")
Walk_Refused :: struct {
	action:       [8]u8,
	walk_problem: [48]u8,
}

// The target page passed to edit(store, name) is not valid.
@(log_fact = "edit: the target object is not valid: the editor starts empty and keeps nothing")
Target_Invalid :: struct {}

// A selection was cut to the clipboard.
@(log_fact = "edit: cut {length} to the clipboard")
Selection_Cut :: struct {
	length: value_kinds.Size_In_Bytes,
}

// The bytes of the Text field of the cause of a window that stays fixed:
// the longest sentence of display.SIZE_LIMITS_PROBLEM_SENTENCES, and a zero
// byte.
STAYS_FIXED_CAUSE_FIELD_BYTES :: 64

// The window cannot be resized: the limits that this process gave were
// refused, or the command ring of the window was full.
@(log_fact = "edit: the window stays fixed: {cause}")
Window_Stays_Fixed :: struct {
	cause: [64]u8,
}

// A text was pasted from the clipboard.
@(log_fact = "edit: pasted {length} from the clipboard")
Text_Pasted :: struct {
	length: value_kinds.Size_In_Bytes,
}
