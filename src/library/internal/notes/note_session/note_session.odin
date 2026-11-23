// The rules of the window of notes over the store thread, as pure
// procedures with host tests (src/md/features/notes.md, "The store
// thread"): which keys act while the store works, how much room of the
// queue an act needs before it starts, and which result the window takes.
// The window keeps a Session and asks it before each act and each result.
package note_session

import "internal:notes/store_work"

// What the left pane shows, and what the keys do.
Mode :: enum u8 {
	Notes    = 0, // The list of the notes; the keys edit the text.
	Versions = 1, // The versions of the note; the text pane shows the version chosen.
	Delete   = 2, // The question before a deletion: Enter deletes, Escape keeps.
}

Session :: struct {
	listed:          bool, // The result of the request List came: before it, no key changes a note or the list.
	keeping:         bool, // The store takes the changes.
	mode:            Mode,
	loading:         bool, // The text waits for the result of a Load.
	locked:          bool, // The note shown could not be read whole: no key changes it, and no commit writes it.
	versions_asked:  bool, // A request Versions waits: the keys wait for its result.
	restore_asked:   bool, // A request Restore waits: the keys wait for its result.
	version_ready:   bool, // The preview holds the bytes of the version chosen: its Version result was Done.
	write_refused:   bool, // The last write that came back was refused: the store does not hold the text that the window shows.
	load_serial:     u64,
	versions_serial: u64,
	version_serial:  u64,
	restore_serial:  u64,
}

// text_keys_act says if a key can change the text of the note shown.
text_keys_act :: proc "contextless" (session: ^Session) -> bool {
	return session.listed && session.mode == .Notes && !session.loading && !session.locked && !session.versions_asked && !session.restore_asked
}

// cut_allowed says if a cut can remove the selection: a cut changes the
// text, as a typed key does. A copy changes nothing, and needs no gate.
cut_allowed :: proc "contextless" (session: ^Session) -> bool {
	return text_keys_act(session)
}

// write_done records the result of a write: a refused one leaves the
// window with a text that the store does not hold, until a write is done.
write_done :: proc "contextless" (session: ^Session, status: store_work.Result_Status) {
	session.write_refused = status != .Done
}

// list_keys_act says if a key can change the list or show another note:
// a new note, a deletion, another note, the versions.
list_keys_act :: proc "contextless" (session: ^Session) -> bool {
	return session.listed && session.mode == .Notes && !session.versions_asked && !session.restore_asked
}

// versions_keys_act says if a key can choose or restore a version.
versions_keys_act :: proc "contextless" (session: ^Session) -> bool {
	return session.mode == .Versions && !session.restore_asked
}

// commit_allowed says if a change of the note shown can be written: never
// before the list, while the text waits for its bytes, or for a note that
// could not be read.
commit_allowed :: proc "contextless" (session: ^Session) -> bool {
	return session.listed && session.keeping && !session.loading && !session.locked
}

// show_room gives the places of the queue that showing a note needs: the
// commit of the change that waits, and the load of a note that the store
// holds.
show_room :: proc "contextless" (session: ^Session, change_waits, target_stored: bool) -> int {
	room := 0
	if change_waits && commit_allowed(session) {
		room += 1
	}
	if target_stored && session.keeping {
		room += 1
	}
	return room
}

// delete_room gives the places of the queue that a deletion needs before
// it starts: the removal of a stored note, and the load of the note shown
// after it. A deletion that the queue cannot take whole does not start.
delete_room :: proc "contextless" (session: ^Session, deleted_stored, next_stored: bool) -> int {
	room := 0
	if deleted_stored && session.keeping {
		room += 1
	}
	if next_stored && session.keeping {
		room += 1
	}
	return room
}

// result_taken says if the window takes a result: a result of an older
// request of the same kind, or one that comes after the window left what
// asked for it, is dropped.
result_taken :: proc "contextless" (session: ^Session, kind: store_work.Request_Kind, serial: u64) -> bool {
	switch kind {
	case .List:
		return !session.listed
	case .Load:
		return session.loading && serial == session.load_serial
	case .Versions:
		return session.versions_asked && serial == session.versions_serial
	case .Version:
		return session.mode == .Versions && serial == session.version_serial
	case .Restore:
		return session.restore_asked && serial == session.restore_serial
	case .Write, .Remove:
		return true
	}
	return false
}

// listed_now records the result of the request List.
listed_now :: proc "contextless" (session: ^Session, status: store_work.Result_Status) {
	session.listed = true
	session.keeping = status == .Done
}

// load_asked records a request Load of the note shown.
load_asked :: proc "contextless" (session: ^Session, serial: u64) {
	session.loading, session.load_serial, session.locked = true, serial, false
}

// note_shown_new records a note with no object: nothing to load.
note_shown_new :: proc "contextless" (session: ^Session) {
	session.loading, session.locked = false, false
}

// Load_Outcome: what the window does with the result of a Load.
Load_Outcome :: enum u8 {
	Text       = 0, // The bytes are the text.
	Empty      = 1, // The note has no bytes to show and the next change writes it: absent, or damaged with its versions kept.
	Unreadable = 2, // The note cannot be read whole: it is shown empty and locked, and never written.
}

// load_done records the result of a Load that the window takes.
load_done :: proc "contextless" (session: ^Session, status: store_work.Result_Status) -> Load_Outcome {
	session.loading = false
	switch status {
	case .Done:
		return .Text
	case .Absent, .Damaged:
		return .Empty
	case .Too_Long, .Refused, .Unanswered, .No_Store:
	}
	session.locked = true
	return .Unreadable
}

// delete_asked opens the question of a deletion.
delete_asked :: proc "contextless" (session: ^Session) -> bool {
	if !list_keys_act(session) {
		return false
	}
	session.mode = .Delete
	return true
}

// delete_closed closes the question: answered or kept.
delete_closed :: proc "contextless" (session: ^Session) {
	if session.mode == .Delete {
		session.mode = .Notes
	}
}

// versions_asked_now records a request Versions.
versions_asked_now :: proc "contextless" (session: ^Session, serial: u64) {
	session.versions_asked, session.versions_serial = true, serial
}

// versions_done records the result of a Versions that the window takes.
// opened: the pane of the versions opens.
versions_done :: proc "contextless" (session: ^Session, status: store_work.Result_Status, count: int) -> (opened: bool) {
	session.versions_asked = false
	if status != .Done || count <= 0 || session.mode != .Notes {
		return false
	}
	session.mode = .Versions
	session.version_ready = false
	return true
}

// version_asked records a request Version of the version chosen.
version_asked :: proc "contextless" (session: ^Session, serial: u64) {
	session.version_serial, session.version_ready = serial, false
}

// version_done records the result of a Version that the window takes.
version_done :: proc "contextless" (session: ^Session, status: store_work.Result_Status) {
	session.version_ready = status == .Done
}

// restore_allowed says if Enter restores the version chosen: its bytes
// came, it is not the current one, and no restore waits.
restore_allowed :: proc "contextless" (session: ^Session, chosen_is_current: bool) -> bool {
	return versions_keys_act(session) && session.version_ready && !chosen_is_current
}

// restore_asked_now records a request Restore.
restore_asked_now :: proc "contextless" (session: ^Session, serial: u64) {
	session.restore_asked, session.restore_serial = true, serial
}

// restore_done records the result of a Restore that the window takes.
// reload: the store made the version current; the pane closes, and the
// window loads the note from the store, never from its preview.
restore_done :: proc "contextless" (session: ^Session, status: store_work.Result_Status) -> (reload: bool) {
	session.restore_asked = false
	if status != .Done {
		return false
	}
	session.mode = .Notes
	return true
}

// versions_closed goes back to the note.
versions_closed :: proc "contextless" (session: ^Session) {
	if session.mode == .Versions && !session.restore_asked {
		session.mode = .Notes
	}
}

// unanswered records a call with no answer: the notes are not kept from
// now on. Only Unanswered ends the keeping.
unanswered :: proc "contextless" (session: ^Session, status: store_work.Result_Status) {
	if status == .Unanswered {
		session.keeping = false
	}
}
