// The list of the notes of the process notes, as pure procedures with no
// call of the system, so that a host test gives them each edge
// (src/md/features/notes.md).
//
// A note is one object of the private store of notes. A new note gets the
// object name "note_" and a serial of SERIAL_DIGITS digits, the next after
// the largest serial of the store, so the order of the names is the order
// of creation. An object of the store with another name is a note too,
// under its own name. The title of a note is its first line: a change of
// the first line renames the note, with no rename of its object.
package note_list

import "modus:contract/store"
import "modus:contract/text_encoding"

NOTE_CAPACITY :: 256 // The notes that the list holds.
TITLE_BYTES :: 60 // The bytes of a title: a cut title ends after a whole character.
NAME_BYTES :: store.ENTRY_NAME_CAPACITY // The bytes of the name of an object.
OBJECT_NAME_PREFIX :: "note_"
SERIAL_DIGITS :: 6
SERIAL_LIMIT :: 999_999 // The largest serial of SERIAL_DIGITS digits.
// The pause of the keys after which the change of a note is a commit, in
// milliseconds of the clock of the system.
PAUSE_MILLISECONDS :: 1000
// The longest wait of a change for its commit, from the first change that
// waits, whatever the pauses: a principal who never pauses would else keep
// it waiting with no end.
LONGEST_WAIT_MILLISECONDS :: 5000

Note :: struct {
	name:        [NAME_BYTES]u8,
	name_count:  int, // 0: the store does not hold the note yet; its first commit names it.
	title:       [TITLE_BYTES]u8,
	title_count: int,
	generation:  i64, // The last commit of the note; 0: none.
}

Note_List :: struct {
	notes:       [NOTE_CAPACITY]Note,
	count:       int,
	next_serial: u64, // The serial of the next new note. 0: none is left.
}

// Why a change of the list is refused. A refused change changes nothing.
List_Problem :: enum u8 {
	None         = 0,
	Full         = 1, // The list holds NOTE_CAPACITY notes.
	No_Place     = 2, // The index names no note.
	Name_Invalid = 3, // An empty name, or one longer than NAME_BYTES.
	No_Serial    = 4, // Each serial is taken.
}

note_name :: proc "contextless" (note: ^Note) -> string {
	return string(note.name[:note.name_count])
}

note_title :: proc "contextless" (note: ^Note) -> string {
	return string(note.title[:note.title_count])
}

// title_of gives the title of a text from its first bytes: its first line,
// with each tab as a space, cut after the last whole character that fits in
// TITLE_BYTES. It stops at the first byte that is not text: the first bytes
// of an object can end inside a character.
title_of :: proc "contextless" (first_bytes: []u8) -> (title: [TITLE_BYTES]u8, count: int) {
	place := 0
	for place < len(first_bytes) {
		value := first_bytes[place]
		if value == '\n' {
			break
		}
		if value == '\t' {
			if count + 1 > TITLE_BYTES {
				break
			}
			title[count] = ' '
			count += 1
			place += 1
			continue
		}
		character, length, valid := text_encoding.character_decode(first_bytes, place)
		if !valid || length <= 0 || !text_encoding.character_in_text(character) || count + length > TITLE_BYTES {
			break
		}
		copy(title[count:], first_bytes[place:place + length])
		count += length
		place += length
	}
	return
}

// title_set writes the title of a note from the first bytes of its text.
title_set :: proc "contextless" (note: ^Note, first_bytes: []u8) {
	note.title, note.title_count = title_of(first_bytes)
}

// serial_of_name gives the serial of an object name that a new note got:
// "note_" and exactly SERIAL_DIGITS digits, not all zero. ok is false for
// each other name.
serial_of_name :: proc "contextless" (name: string) -> (serial: u64, ok: bool) {
	if len(name) != len(OBJECT_NAME_PREFIX) + SERIAL_DIGITS || name[:len(OBJECT_NAME_PREFIX)] != OBJECT_NAME_PREFIX {
		return 0, false
	}
	for value in transmute([]u8)name[len(OBJECT_NAME_PREFIX):] {
		if value < '0' || value > '9' {
			return 0, false
		}
		serial = serial * 10 + u64(value - '0')
	}
	return serial, serial != 0
}

// name_of_serial writes the object name of a serial into a buffer of
// NAME_BYTES. ok is false for 0 and for a serial past SERIAL_LIMIT.
name_of_serial :: proc "contextless" (serial: u64, buffer: ^[NAME_BYTES]u8) -> (count: int, ok: bool) {
	if serial == 0 || serial > SERIAL_LIMIT {
		return 0, false
	}
	copy(buffer[:], OBJECT_NAME_PREFIX)
	rest := serial
	for index := SERIAL_DIGITS - 1; index >= 0; index -= 1 {
		buffer[len(OBJECT_NAME_PREFIX) + index] = u8('0' + rest % 10)
		rest /= 10
	}
	return len(OBJECT_NAME_PREFIX) + SERIAL_DIGITS, true
}

// list_reset empties the list: the next new note gets the serial 1.
list_reset :: proc "contextless" (list: ^Note_List) {
	list.count = 0
	list.next_serial = 1
}

// list_add_stored adds a note that the store holds, after the others: the
// store lists its objects in the order of their names. A name with a
// serial moves the serial of the next new note past it.
list_add_stored :: proc "contextless" (list: ^Note_List, name: string, first_bytes: []u8, generation: i64) -> (index: int, problem: List_Problem) {
	if len(name) == 0 || len(name) > NAME_BYTES {
		return -1, .Name_Invalid
	}
	if list.count >= NOTE_CAPACITY {
		return -1, .Full
	}
	note := &list.notes[list.count]
	note^ = {}
	note.name_count = copy(note.name[:], name)
	title_set(note, first_bytes)
	note.generation = generation
	if serial, has_serial := serial_of_name(name); has_serial && list.next_serial != 0 && serial >= list.next_serial {
		list.next_serial = serial < SERIAL_LIMIT ? serial + 1 : 0
	}
	list.count += 1
	return list.count - 1, .None
}

// list_add_new adds an empty note at the end, with no object yet.
list_add_new :: proc "contextless" (list: ^Note_List) -> (index: int, problem: List_Problem) {
	if list.count >= NOTE_CAPACITY {
		return -1, .Full
	}
	list.notes[list.count] = {}
	list.count += 1
	return list.count - 1, .None
}

// note_name_take gives a note with no object the name of the next serial,
// before its first commit.
note_name_take :: proc "contextless" (list: ^Note_List, index: int) -> List_Problem {
	if index < 0 || index >= list.count {
		return .No_Place
	}
	note := &list.notes[index]
	if note.name_count > 0 {
		return .None
	}
	count, ok := name_of_serial(list.next_serial, &note.name)
	if !ok {
		return .No_Serial
	}
	note.name_count = count
	list.next_serial = list.next_serial < SERIAL_LIMIT ? list.next_serial + 1 : 0
	return .None
}

// list_remove removes a note, and gives the note to show after it: the
// next one, or the one before it when it was the last; -1 when the list is
// empty.
list_remove :: proc "contextless" (list: ^Note_List, index: int) -> (shown: int, problem: List_Problem) {
	if index < 0 || index >= list.count {
		return -1, .No_Place
	}
	copy(list.notes[index:list.count - 1], list.notes[index + 1:list.count])
	list.count -= 1
	list.notes[list.count] = {}
	if list.count == 0 {
		return -1, .None
	}
	return min(index, list.count - 1), .None
}

// list_newest gives the note with the latest commit, or -1 for an empty
// list. Of two with the same commit, the first.
list_newest :: proc "contextless" (list: ^Note_List) -> int {
	newest := -1
	for index in 0 ..< list.count {
		if newest < 0 || list.notes[index].generation > list.notes[newest].generation {
			newest = index
		}
	}
	return newest
}

// A change of the text that waits for its commit, and when: times of the
// clock of the system, in milliseconds.
Change_Wait :: struct {
	waiting:      bool,
	first_change: u64, // The first change that waits.
	last_change:  u64,
}

// change_wait_mark records a change at a time: the first one that waits
// starts the longest wait.
change_wait_mark :: proc "contextless" (wait: ^Change_Wait, now: u64) {
	if !wait.waiting {
		wait.first_change = now
	}
	wait.waiting = true
	wait.last_change = now
}

// change_wait_again starts the wait again at a time, for a change whose
// commit the queue refused: both ends count from the refusal, so the loop
// does not try again at once.
change_wait_again :: proc "contextless" (wait: ^Change_Wait, now: u64) {
	wait^ = {waiting = true, first_change = now, last_change = now}
}

// change_wait_due says if the change that waits is due for its commit: a
// pause of PAUSE_MILLISECONDS with no key, or LONGEST_WAIT_MILLISECONDS
// since the first change. A clock that went back makes nothing due.
change_wait_due :: proc "contextless" (wait: ^Change_Wait, now: u64) -> bool {
	if !wait.waiting {
		return false
	}
	paused := now >= wait.last_change && now - wait.last_change >= PAUSE_MILLISECONDS
	waited := now >= wait.first_change && now - wait.first_change >= LONGEST_WAIT_MILLISECONDS
	return paused || waited
}

// change_wait_deadline gives the time at which the change that waits is
// due: the nearer end. has_deadline is false when no change waits.
change_wait_deadline :: proc "contextless" (wait: ^Change_Wait) -> (deadline: u64, has_deadline: bool) {
	if !wait.waiting {
		return 0, false
	}
	pause_end := wait.last_change > max(u64) - PAUSE_MILLISECONDS ? max(u64) : wait.last_change + PAUSE_MILLISECONDS
	longest_end := wait.first_change > max(u64) - LONGEST_WAIT_MILLISECONDS ? max(u64) : wait.first_change + LONGEST_WAIT_MILLISECONDS
	return min(pause_end, longest_end), true
}
