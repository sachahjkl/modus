package edit

import "modus:contract/value_kinds"

// The log facts of the editor (src/md/features/log_facts.md, "The
// migration"): each line that has a value, as a record of fields. Each fact
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
