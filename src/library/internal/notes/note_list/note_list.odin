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

// Inline capacity: fast tier for typical note collections (observed <= 256
// notes). Past this count, a list configured with list_init_overflow moves to
// its caller-supplied backing slice or arena without refusing new notes.
NOTE_CAPACITY :: 256
// Format property: matches the 255-byte STORAGE7 object name limit so a note
// title is never cut artificially at 60 bytes; a cut title still ends after a
// whole UTF-8 character.
TITLE_BYTES :: store.ENTRY_NAME_CAPACITY
NAME_BYTES :: store.ENTRY_NAME_CAPACITY // Format property: bytes of a STORAGE7 object name.
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
	name:          [NAME_BYTES]u8,
	name_count:    int, // 0: the store does not hold the note yet; its first commit names it.
	title:         [TITLE_BYTES]u8,
	title_count:   int,
	generation:    i64, // The last commit of the note; 0: none.
	write_refused: bool, // The last write of this note was refused: the store does not hold its text.
}

// Caller-supplied growth callback for the slower note list tier. Returns a
// slice of at least minimum_notes entries, or false when the budget refuses.
Note_Grow :: #type proc "contextless" (user_data: rawptr, current: []Note, minimum_notes: int) -> (grown: []Note, ok: bool)

Note_List :: struct {
	notes:          [NOTE_CAPACITY]Note, // Inline capacity: fast tier for typical note lists.
	external_notes: []Note, // Slower tier: caller-supplied backing slice or arena-grown buffer.
	grow:           Note_Grow,
	grow_data:      rawptr,
	using_overflow: bool, // True when active entries live in external_notes.
	count:          int,
	next_serial:    u64, // The serial of the next new note. 0: none is left.
	overflow_moves: u64, // Count of moves to or growths of the slower tier, visible as a measure.
}

// Why a change of the list is refused. A refused change changes nothing.
List_Problem :: enum u8 {
	None         = 0,
	Full         = 1, // The list reached its inline capacity with no overflow tier, or growth was refused.
	No_Place     = 2, // The index names no note.
	Name_Invalid = 3, // An empty name, or one longer than NAME_BYTES.
	No_Serial    = 4, // Each serial is taken.
}

// list_init_overflow attaches a caller-supplied backing slice and optional
// growth callback for lists past NOTE_CAPACITY notes.
list_init_overflow :: proc "contextless" (list: ^Note_List, backing: []Note, grow: Note_Grow = nil, grow_data: rawptr = nil) {
	if list == nil {
		return
	}
	list.external_notes = backing
	list.grow = grow
	list.grow_data = grow_data
	if list.count == 0 {
		list.using_overflow = false
	}
}

@(private)
list_storage :: #force_inline proc "contextless" (list: ^Note_List) -> []Note {
	if list.using_overflow {
		return list.external_notes
	}
	return list.notes[:]
}

// list_notes returns the active notes slice.
list_notes :: proc "contextless" (list: ^Note_List) -> []Note {
	if list == nil || list.count <= 0 {
		return nil
	}
	storage := list_storage(list)
	return storage[:min(list.count, len(storage))]
}

// note_at returns the note at index, or nil if index names no note.
note_at :: proc "contextless" (list: ^Note_List, index: int) -> ^Note {
	if list == nil || index < 0 || index >= list.count {
		return nil
	}
	storage := list_storage(list)
	if index >= len(storage) {
		return nil
	}
	return &storage[index]
}

// list_on_overflow reports whether the list moved past its inline tier.
list_on_overflow :: proc "contextless" (list: ^Note_List) -> bool {
	return list != nil && list.using_overflow
}

// list_capacity returns the current note capacity without another tier growth.
list_capacity :: proc "contextless" (list: ^Note_List) -> int {
	if list == nil {
		return 0
	}
	return len(list_storage(list))
}

@(private)
list_ensure_room :: proc "contextless" (list: ^Note_List, needed: int) -> bool {
	if needed < 0 {
		return false
	}
	if !list.using_overflow {
		if needed <= len(list.notes) {
			return true
		}
		target := list.external_notes
		if len(target) < needed {
			if list.grow == nil {
				return false
			}
			grown, ok := list.grow(list.grow_data, target, needed)
			if !ok || len(grown) < needed || raw_data(grown) == nil {
				return false
			}
			target = grown
		}
		copy(target[:list.count], list.notes[:list.count])
		list.external_notes = target
		list.using_overflow = true
		list.overflow_moves += 1
		return true
	}
	if needed <= len(list.external_notes) {
		return true
	}
	if list.grow == nil {
		return false
	}
	grown, ok := list.grow(list.grow_data, list.external_notes, needed)
	if !ok || len(grown) < needed || raw_data(grown) == nil {
		return false
	}
	if raw_data(grown) != raw_data(list.external_notes) {
		copy(grown[:list.count], list.external_notes[:list.count])
	}
	list.external_notes = grown
	list.overflow_moves += 1
	return true
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

// list_reset empties the list on its fast inline tier: the next new note gets
// the serial 1. Configured overflow backing and overflow_moves persist.
list_reset :: proc "contextless" (list: ^Note_List) {
	list.count = 0
	list.next_serial = 1
	list.using_overflow = false
}

// list_copy_from replaces the entries and next_serial of dst with a copy of
// src, growing dst into its overflow tier when needed. A refusal leaves dst
// unchanged.
list_copy_from :: proc "contextless" (dst: ^Note_List, src: ^Note_List) -> List_Problem {
	if dst == nil || src == nil {
		return .No_Place
	}
	src_notes := list_notes(src)
	if len(src_notes) <= NOTE_CAPACITY {
		dst.using_overflow = false
		copy(dst.notes[:len(src_notes)], src_notes)
		dst.count = len(src_notes)
		dst.next_serial = src.next_serial
		return .None
	}
	// Ensure room before overwriting dst.count so a refusal keeps dst intact.
	saved_count := dst.count
	saved_overflow := dst.using_overflow
	if !list_ensure_room(dst, len(src_notes)) {
		dst.count = saved_count
		dst.using_overflow = saved_overflow
		return .Full
	}
	storage := list_storage(dst)
	copy(storage[:len(src_notes)], src_notes)
	dst.count = len(src_notes)
	dst.next_serial = src.next_serial
	return .None
}

// list_add_stored adds a note that the store holds, after the others: the
// store lists its objects in the order of their names. A name with a
// serial moves the serial of the next new note past it.
list_add_stored :: proc "contextless" (list: ^Note_List, name: string, first_bytes: []u8, generation: i64) -> (index: int, problem: List_Problem) {
	if len(name) == 0 || len(name) > NAME_BYTES {
		return -1, .Name_Invalid
	}
	if !list_ensure_room(list, list.count + 1) {
		return -1, .Full
	}
	storage := list_storage(list)
	note := &storage[list.count]
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
	if !list_ensure_room(list, list.count + 1) {
		return -1, .Full
	}
	storage := list_storage(list)
	storage[list.count] = {}
	list.count += 1
	return list.count - 1, .None
}

// note_name_take gives a note with no object the name of the next serial,
// before its first commit.
note_name_take :: proc "contextless" (list: ^Note_List, index: int) -> List_Problem {
	note := note_at(list, index)
	if note == nil {
		return .No_Place
	}
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
	storage := list_storage(list)
	copy(storage[index:list.count - 1], storage[index + 1:list.count])
	list.count -= 1
	storage[list.count] = {}
	if list.count == 0 {
		return -1, .None
	}
	return min(index, list.count - 1), .None
}

// note_find gives the index of the note with an object name, or -1:
// a result names its note, and the list can change before it comes.
note_find :: proc "contextless" (list: ^Note_List, name: string) -> int {
	if len(name) == 0 {
		return -1
	}
	storage := list_storage(list)
	for index in 0 ..< list.count {
		if note_name(&storage[index]) == name {
			return index
		}
	}
	return -1
}

// note_write_done records the result of a write for the note with an object
// name: a refused write marks only that note, and a write that succeeded
// clears it and records its commit generation. Nothing changes when the name
// is absent.
note_write_done :: proc "contextless" (list: ^Note_List, name: string, kept: bool, generation: i64) -> (index: int, found: bool) {
	index = note_find(list, name)
	if index < 0 {
		return -1, false
	}
	note := note_at(list, index)
	note.write_refused = !kept
	if kept {
		note.generation = generation
	}
	return index, true
}

// note_is_write_refused says if the last write of the note at index was
// refused. false for an index that names no note.
note_is_write_refused :: proc "contextless" (list: ^Note_List, index: int) -> bool {
	note := note_at(list, index)
	if note == nil {
		return false
	}
	return note.write_refused
}

// list_newest gives the note with the latest commit, or -1 for an empty
// list. Of two with the same commit, the first.
list_newest :: proc "contextless" (list: ^Note_List) -> int {
	storage := list_storage(list)
	newest := -1
	for index in 0 ..< list.count {
		if newest < 0 || storage[index].generation > storage[newest].generation {
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
