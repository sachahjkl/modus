package notes

import "modus:contract/value_kinds"

// The log facts of notes (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence, the generation that a test reads in it,
// and the measure of the commits read it as before. A line whose sentence
// differs by its case is one fact type for each case: the template has no
// condition. The Text fields are the last fields: the serial line of a fact
// stops at its last byte that is not zero.
//
// Lines stay text: the lines with no value, and the refusal of the storage
// service, whose sentence of an error record of up to 256 bytes passes the
// values of one fact.

// The bytes of the Text field of a note: at most NOTE_CAPACITY bytes, and a
// zero byte.
NOTE_FIELD_BYTES :: 64
// The bytes of the Text field of the date of a version: "2026-11-20
// 10:20:30" has 19 bytes.
DATE_FIELD_BYTES :: 24

// A version of the note that the window shows, with the date of its
// commit.
@(log_fact = "notes: the version {version} of {versions}, generation {generation}, {date}: \"{note_text}\"")
Version_Shown :: struct {
	version:    u64,
	versions:   u64,
	generation: i64,
	date:       [24]u8,
	note_text:  [64]u8,
}

// A version of the note that the window shows, whose commit has no date.
@(log_fact = "notes: the version {version} of {versions}, generation {generation}: \"{note_text}\"")
Version_Shown_Without_Date :: struct {
	version:    u64,
	versions:   u64,
	generation: i64,
	note_text:  [64]u8,
}

// The storage service cannot give the note at the start; the count is
// whole.
@(log_fact = "notes: WRONG: the storage service cannot give the note: the object is damaged; restored the count {count}, its 3 blocks agree")
Note_Damaged :: struct {
	count: u64,
}

// The note and the count, restored at the start.
@(log_fact = "notes: restored the note \"{note_text}\" and the count {count}, its 3 blocks agree")
Note_Restored :: struct {
	count:     u64,
	note_text: [64]u8,
}

// The note and the count, restored at the start, after a run of the count
// that stopped before its end.
@(log_fact = "notes: restored the note \"{note_text}\" and the count {count}, its 3 blocks agree, the last run stopped before its end")
Note_Restored_After_Stopped_Run :: struct {
	count:     u64,
	note_text: [64]u8,
}

// A version of the note restored as the note, in a new commit.
@(log_fact = "notes: restored the version of generation {generation}: \"{note_text}\", in the commit of generation {commit} in {restore}; the note before it is a version")
Version_Restored :: struct {
	generation: i64,
	commit:     i64,
	restore:    value_kinds.Time_In_Microseconds,
	note_text:  [64]u8,
}

// A run of the count ended: its commits and their time.
@(log_fact = "notes: count {count}, stopped: {commits} commits in {elapsed}")
Count_Run_Stopped :: struct {
	count:   u64,
	commits: u64,
	elapsed: value_kinds.Time_In_Milliseconds,
}

// The list of the versions of the count, and its time.
@(log_fact = "notes: the versions of the count: {rows} rows in {elapsed}")
Count_Versions_Listed :: struct {
	rows:    i64,
	elapsed: value_kinds.Time_In_Microseconds,
}

// A step of a run of the count.
@(log_fact = "notes: count {count}")
Count_Stepped :: struct {
	count: u64,
}

// The note, its generation, its versions, and the mean time of one commit
// of the note.
@(log_fact = "notes: the note is \"{note_text}\", generation {generation}, {versions} versions; one commit of the note: {commit_mean} in the mean of {commits}")
Note_Shown :: struct {
	generation:  i64,
	versions:    u64,
	commit_mean: value_kinds.Time_In_Microseconds,
	commits:     u64,
	note_text:   [64]u8,
}

#assert(NOTE_FIELD_BYTES > NOTE_CAPACITY)
#assert(size_of(Version_Shown) == 24 + DATE_FIELD_BYTES + NOTE_FIELD_BYTES)

// note_field gives the Text field of the text of a note.
note_field :: proc "contextless" (text: []u8) -> [NOTE_FIELD_BYTES]u8 {
	return value_kinds.text_field(string(text), NOTE_FIELD_BYTES)
}
