package terminal_process

import "modus:contract/value_kinds"

// The log facts of the terminal (src/md/features/log_facts.md, "The
// migration"): each line that has a value, as a record of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.
//
// The field shown_process is the name of the process whose text the
// terminal shows, a system.Name of 31 bytes at most: a Module_Name_Field,
// the last field. The serial line of a fact stops at its last byte that is
// not zero, so the zeros after a short name cost no byte. Each other Text
// field comes before it and after the integers.

// The bytes of the Text field of the act of the pointer on a scroll bar:
// "a press on" or "a drag of", and a zero byte.
SCROLL_ACT_FIELD_BYTES :: 16
// The bytes of the Text field of a part of a scroll bar: the longest words
// of scroll_part_words, "the track above the thumb", and a zero byte.
SCROLL_PART_FIELD_BYTES :: 32
// The bytes of the Text field of the name of a font of the fallback chain:
// the longest, "paper_mono_semibold", and a zero byte.
FONT_NAME_FIELD_BYTES :: 24

// The drawer slept to its deadline after a change of the view, and no wake
// came: a lost wake, said once.
@(log_fact = "terminal: {shown_process}: the drawer slept to its deadline after a change of the view, and no wake came")
Drawer_Wake_Lost :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// The reader waits while its ring holds records that it did not read since
// the last look: a lost wake, said once.
@(log_fact = "terminal: {shown_process}: the reader waits with {records} records in its ring, and read none since the last look")
Reader_Stuck :: struct {
	records:       u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The first record whose kind names no record: the next ones are counted.
@(log_fact = "terminal: {shown_process} sent a record of the kind {kind_word}, which names no record: it is refused")
Record_Kind_Refused :: struct {
	kind_word:     u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The first key serial past the keys that the terminal forwarded: the next
// ones are counted.
@(log_fact = "terminal: {shown_process} named a key serial past the keys that it got: it is refused, and the next ones are counted")
Key_Serial_Refused :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// The process sent runs of code that do not fit their row: the row is
// drawn plain.
@(log_fact = "terminal: {shown_process} sent runs of code that do not fit their row: the row is drawn plain, its text whole")
Code_Runs_Refused :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// The process sent a row of a completion list whose icon names no icon.
@(log_fact = "terminal: {shown_process} sent a row of a completion list whose icon names no icon: the row is refused")
List_Row_Refused :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// The interface text of the process is drawn in the interface font.
@(log_fact = "terminal: {shown_process} draws its interface text in the interface font")
Interface_Text_In_Interface_Font :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// The interface text of the process is drawn in the font of the cells.
@(log_fact = "terminal: {shown_process} draws its interface text in the font of the cells")
Interface_Text_In_Cell_Font :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// A move of the view left the last lines: the view stays at its line while
// the process writes on.
@(log_fact = "terminal: the view stays at line {line}, {shown_process} continues")
View_Stays :: struct {
	line:          u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The terminal is ready: the ring in which the process writes its records.
@(log_fact = "terminal: ok, {shown_process} writes in a ring of {ring_records} records")
Window_Ready :: struct {
	ring_records:  u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The first key that the terminal forwarded to the process.
@(log_fact = "terminal: the first key goes to {shown_process}")
First_Key_Sent :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// The process reads its keys again after a loss: the count of the keys
// lost.
@(log_fact = "terminal: {shown_process} reads its keys again: {lost_keys} keys were lost")
Keys_Read_Again :: struct {
	lost_keys:     u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The queue of the keys of the process is full: a key is lost, and the
// loss begins.
@(log_fact = "terminal: {shown_process} does not read its keys: its queue of {queue_keys} keys is full, and a new key is lost")
Keys_Not_Read :: struct {
	queue_keys:    u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The process stopped while its keys were lost: the count of the keys
// lost.
@(log_fact = "terminal: {shown_process} stopped and did not read its keys: {lost_keys} keys were lost")
Stopped_With_Lost_Keys :: struct {
	lost_keys:     u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The process stopped after records whose kind names no record.
@(log_fact = "terminal: {shown_process} stopped after {refused} records whose kind names no record")
Stopped_After_Refused_Records :: struct {
	refused:       u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The measure of the first whole second of a measure run: the lines and
// the records of the process, its kernel entries, and the pictures of the
// terminal.
@(log_fact = "terminal: {shown_process} wrote {lines_per_second} lines in one second, {records_per_second} records, with {kernel_entries_per_million} kernel entries for one million records; the terminal drew {pictures_per_second} pictures")
Second_Measured :: struct {
	lines_per_second:          u64,
	records_per_second:        u64,
	kernel_entries_per_million: u64,
	pictures_per_second:       u64,
	shown_process:             value_kinds.Module_Name_Field,
}

// A press on a part of the scroll bar of the completion list asked the
// process for its rows from a first row.
@(log_fact = "terminal: a press on {scroll_part} of the scroll bar of the completion list of {shown_process}: the rows from {first_row} of {rows}")
List_Scroll_Pressed :: struct {
	first_row:     u64,
	rows:          u64,
	scroll_part:   [32]u8,
	shown_process: value_kinds.Module_Name_Field,
}

// The wheel asked the process for the rows of its completion list from a
// first row.
@(log_fact = "terminal: the wheel moves the completion list of {shown_process}: the rows from {first_row} of {rows}")
List_Wheel_Moved :: struct {
	first_row:     u64,
	rows:          u64,
	shown_process: value_kinds.Module_Name_Field,
}

// A drag of the thumb of the scroll bar of the completion list ended.
@(log_fact = "terminal: a drag of the thumb of the scroll bar of the completion list of {shown_process}: the rows from {first_row} of {rows}")
List_Thumb_Dragged :: struct {
	first_row:     u64,
	rows:          u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The first cell of a font of the fallback chain that this process drew.
@(log_fact = "terminal: {shown_process} shows the character {character} in its cells, drawn by this process from the font {fallback_font} of its fallback chain")
Cell_From_Fallback_Font :: struct {
	character:     u64,
	fallback_font: [24]u8,
	shown_process: value_kinds.Module_Name_Field,
}

// The first cell that no font of the fallback chain has.
@(log_fact = "terminal: {shown_process} shows the character {character} in its cells as the replacement glyph: no font of its fallback chain has it")
Cell_Replacement_Glyph :: struct {
	character:     u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The wheel moved the view of the lines to the last lines.
@(log_fact = "terminal: the wheel moves the view of {shown_process}: the view follows the last lines")
Wheel_Follows :: struct {
	shown_process: value_kinds.Module_Name_Field,
}

// The wheel moved the view of the lines to a line.
@(log_fact = "terminal: the wheel moves the view of {shown_process}: the view starts at line {line} of {lines}")
Wheel_At_Line :: struct {
	line:          u64,
	lines:         u64,
	shown_process: value_kinds.Module_Name_Field,
}

// The pointer moved the view of the lines to the last lines, by the scroll
// bar.
@(log_fact = "terminal: {scroll_act} {scroll_part} of the scroll bar of {shown_process}: the view follows the last lines")
Scroll_Follows :: struct {
	scroll_act:    [16]u8,
	scroll_part:   [32]u8,
	shown_process: value_kinds.Module_Name_Field,
}

// The pointer moved the view of the lines to a line, by the scroll bar.
@(log_fact = "terminal: {scroll_act} {scroll_part} of the scroll bar of {shown_process}: the view starts at line {line} of {lines}")
Scroll_At_Line :: struct {
	line:          u64,
	lines:         u64,
	scroll_act:    [16]u8,
	scroll_part:   [32]u8,
	shown_process: value_kinds.Module_Name_Field,
}

// A paste came with no process to type it.
@(log_fact = "terminal: a paste of {characters} characters, and no process to type them")
Paste_Without_Process :: struct {
	characters: u64,
}

// A paste is larger than the room of the queue of the keys: nothing is
// typed.
@(log_fact = "terminal: the paste of {characters} characters is larger than the room of {room} keys of {shown_process}: nothing is typed")
Paste_Too_Large :: struct {
	characters:    u64,
	room:          u64,
	shown_process: value_kinds.Module_Name_Field,
}

// A paste went to the process as keys.
@(log_fact = "terminal: a paste of {characters} characters goes to {shown_process}")
Paste_Sent :: struct {
	characters:    u64,
	shown_process: value_kinds.Module_Name_Field,
}

// shown_process_field gives the field of the name of the process that the
// terminal shows.
shown_process_field :: proc "contextless" () -> value_kinds.Module_Name_Field {
	return value_kinds.module_name_field(process_name)
}

// scroll_part_field gives the Text field of the words of a part of a
// scroll bar.
scroll_part_field :: proc "contextless" (words: string) -> [SCROLL_PART_FIELD_BYTES]u8 {
	return value_kinds.text_field(words, SCROLL_PART_FIELD_BYTES)
}
