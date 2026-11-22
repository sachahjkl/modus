package notes

import "modus:contract/errors"

// The log facts of notes (src/md/features/log_facts.md). A machine test
// waits on these sentences: the title of a note is its first line, so a
// test that types a line knows the title. The Text fields are the last
// fields: the serial line of a fact stops at its last byte that is not
// zero. A refusal of the storage service writes the fields of its error
// record.

// The bytes of the Text field of a title: at most TITLE_BYTES bytes, and a
// zero byte.
TITLE_FIELD_BYTES :: 64
// The bytes of the Text field of the date of a version: "2026-11-20
// 10:20:30" has 19 bytes.
DATE_FIELD_BYTES :: 24

#assert(TITLE_FIELD_BYTES > TITLE_BYTES)

// The process has no store: the notes live until it stops.
@(log_fact = "notes: no store: the notes are not kept")
No_Store :: struct {}

// The store holds no note.
@(log_fact = "notes: a new store: no note")
New_Store :: struct {}

// The notes of the store, read at the start, and the note that the window
// shows: the one changed last.
@(log_fact = "notes: restored {notes} notes; the note shown is \"{title}\"")
Notes_Restored :: struct {
	notes: u64,
	title: [64]u8,
}

// The window presented its first picture.
@(log_fact = "notes: ok, the first picture is presented")
First_Picture_Presented :: struct {}

// A commit of the note that the window shows: after a pause of the keys,
// or before another note is shown. The bytes come before the generation,
// so a test reads the generation of the commit of a whole text.
@(log_fact = "notes: the note is \"{title}\", {bytes} bytes, generation {generation}")
Note_Kept :: struct {
	generation: i64,
	bytes:      u64,
	title:      [64]u8,
}

// A new empty note, shown. The store holds it from its first commit.
@(log_fact = "notes: a new note; {notes} notes")
Note_Created :: struct {
	notes: u64,
}

// The window shows another note.
@(log_fact = "notes: the note \"{title}\" is shown")
Note_Shown :: struct {
	title: [64]u8,
}

// The question before a deletion.
@(log_fact = "notes: delete the note \"{title}\"? Enter deletes it, Escape keeps it")
Delete_Asked :: struct {
	title: [64]u8,
}

// A note and its versions, removed from the store.
@(log_fact = "notes: deleted the note \"{title}\"; {notes} notes")
Note_Deleted :: struct {
	notes: u64,
	title: [64]u8,
}

// A version of the note that the window shows, with the date of its
// commit. The version 1 is the newest.
@(log_fact = "notes: the version {version} of {versions}, generation {generation}, {date}: \"{title}\"")
Version_Shown :: struct {
	version:    u64,
	versions:   u64,
	generation: i64,
	date:       [24]u8,
	title:      [64]u8,
}

// A version made the current note, in a new commit: the note before it
// stays a version.
@(log_fact = "notes: restored the version of generation {generation} as the note \"{title}\", in the commit of generation {commit}")
Version_Restored :: struct {
	generation: i64,
	commit:     i64,
	title:      [64]u8,
}

// The note has more versions than the window lists: the oldest are not
// shown.
@(log_fact = "notes: the note has {versions} versions; the window lists the newest {listed}")
Versions_Cut :: struct {
	versions: i64,
	listed:   u64,
}

// The notes of the store do not fit in the list: the others are not shown.
@(log_fact = "notes: the store has more than {listed} notes; the others are not shown")
Notes_Cut :: struct {
	listed: u64,
}

// A note of the store whose bytes are not a text: each invalid sequence is
// shown as the replacement character, and the next commit writes the clean
// text.
@(log_fact = "notes: the note \"{title}\" had {replaced} invalid sequences: each is shown as U+FFFD")
Note_Cleaned :: struct {
	replaced: u64,
	title:    [64]u8,
}

// A note of the store that is longer than a text of the window: it is not
// shown, and never written over.
@(log_fact = "notes: a note of {bytes} bytes is longer than the limit of {limit} bytes: it is not shown")
Note_Too_Long :: struct {
	bytes: i64,
	limit: u64,
}

// The storage service gave no answer: the notes are not kept from now on.
@(log_fact = "notes: the storage service did not answer: the notes are not kept")
Storage_Unanswered :: struct {}

// The storage service refused a write of a note: the fields of its error
// record.
@(log_fact = "notes: the storage service refused a write of the note: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Note_Write_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused a read of a note or of a version.
@(log_fact = "notes: the storage service refused a read of the note: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Note_Read_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused the list of the notes or of the versions.
@(log_fact = "notes: the storage service refused a list: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
List_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused the removal of a note.
@(log_fact = "notes: the storage service refused the removal of the note: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Note_Remove_Refused :: distinct errors.Error_Record_Fact_Fields

// The storage service refused the restore of a version.
@(log_fact = "notes: the storage service refused the restore of the version: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Version_Restore_Refused :: distinct errors.Error_Record_Fact_Fields

#assert(size_of(Note_Shown) == TITLE_FIELD_BYTES)
#assert(size_of(Version_Shown) == 24 + DATE_FIELD_BYTES + TITLE_FIELD_BYTES)
