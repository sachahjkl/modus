// The notes of the principal: a list of notes, the text of one note, and
// the versions of that note, in a window that the principal resizes
// (src/md/features/notes.md).
//
// Each note is one object of the private store. The process has no save
// action: a change waits until the keys pause for one second, or until
// another note is shown, and then is one commit. Each commit is a version,
// so the pane of the versions steps back through the states of a note and
// restores one in a new commit: nothing is lost.
//
// **Start**: `start("notes")` in the console, or the start menu.
//
// **Keys**, with no modes but the pane of the versions and the question of
// a deletion: a character goes in at the caret, in place of the
// selection; Enter starts a new line, Tab writes a tab; the arrows, Home,
// End, Page Up and Page Down move the caret, Control with Home or End goes
// to the start or the end of the note, and with Shift each of them
// selects; Ctrl+A selects all; Backspace and Delete remove the selection
// or one character; Ctrl+C, Ctrl+X and Ctrl+V copy, cut and paste through
// the clipboard of the compositor. Ctrl+N makes a new note, Ctrl+D asks
// to delete the note shown (Enter deletes it, Escape keeps it), Ctrl+Page
// Up and Ctrl+Page Down show the note before and after it in the list,
// Ctrl+H shows the versions of the note: Down for an older one, Up for a
// newer one, Enter restores the one shown, Escape goes back to the note. A
// press on a note of the list shows it, a press in the text places the
// caret, a drag selects, and the wheel or the scroll bar scrolls.
//
// **Grants**, as the root service gives them:
//
// - **Store**: its private store, which holds one object for each note and
//   the versions of each.
//
// **What a reader sees**: at the left the list of the notes, each by its
// first line, the one shown on the chosen color; with Ctrl+H, the versions
// of the note in its place. At the right the text, wrapped by word at the
// width of the window, with its scroll bar. At the bottom a status band: a
// problem of the store or the question of a deletion at the left, the
// line, the column and whether the store keeps the text at the right;
// then the action bar. The log has, at the start, one of:
//
// - `notes: a new store: no note`;
// - `notes: restored N notes; the note shown is "..."`;
// - `notes: no store: the notes are not kept`.
//
// Then `notes: the note is "...", B bytes, generation G` after each
// commit.
package notes

import "modus:calendar"
import "modus:contract/value_kinds"
import "internal:notes/note_list"
import "internal:notes/note_session"
import "internal:notes/store_work"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import box_layout "modus:layout"
import "modus:storage"
import "modus:system"
import "modus:text_model"

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(1024, 16384)

TITLE_BYTES :: note_list.TITLE_BYTES

// The pane at the left: the list of the notes, or the versions of the note
// shown. Its width holds a title of 22 cells and its padding.
PANE_WIDTH :: 208
PANE_ROW_HEIGHT :: graphics.CELL_HEIGHT + 8
PANE_HEADING_HEIGHT :: 28
PANE_PADDING :: 8
DIVIDER_WIDTH :: 1
// The padding of the text, on each side, and the room of the caret after
// the last cell of a full row.
TEXT_PADDING :: 8
CARET_WIDTH :: 2
STATUS_HEIGHT :: 24
// Literals, so the tool reads the window of the budget. The window opens
// at WIDTH by HEIGHT, and the principal resizes it from LEAST_WIDTH by
// LEAST_HEIGHT up to LARGEST_WIDTH by LARGEST_HEIGHT
// (src/md/features/window_resize.md).
WIDTH :: 800
HEIGHT :: 540
LEAST_WIDTH :: 480
LEAST_HEIGHT :: 320
LARGEST_WIDTH :: 1280
LARGEST_HEIGHT :: 960
#assert(LEAST_WIDTH > PANE_WIDTH + DIVIDER_WIDTH + 2 * TEXT_PADDING + interface.SCROLL_BAR_THICKNESS + (text_model.COLUMNS_LEAST + 1) * graphics.CELL_WIDTH)
#assert(LEAST_HEIGHT >= PANE_HEADING_HEIGHT + 4 * PANE_ROW_HEIGHT + STATUS_HEIGHT + interface.ACTION_BAR_ROW_HEIGHT)
// The least budget of the module, with its text, the rows of the text, its
// layout tree, the queues of the store thread with their records, and the
// stack of that thread; two threads: the window and the store. The tool
// counts the window at the largest scale, 2, at its largest size
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1700, processes = 1, threads = 2, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT}
// The bytes of one display row as the frame draws it: each cell is one
// character of at most 4 bytes, or a space of a tab.
ROW_BUFFER_SIZE :: 4 * text_model.COLUMNS_LIMIT
// The versions of a note that the pane lists: the newest.
VERSION_ROWS_CAPACITY :: 512
// The stack of the store thread: the calls of the storage service and
// their records.
STORE_THREAD_STACK_PAGES :: 16
// The first bytes of a note that its title is read from: a title and one
// character more.
TITLE_READ_BYTES :: TITLE_BYTES + 4

// The problem that the status band shows.
Window_Problem :: enum u8 {
	None      = 0,
	No_Store  = 1, // No store: the notes live until the process stops.
	Not_Kept  = 2, // The store refused a commit or gave no answer: the changes after it are not kept.
	Full      = 3, // The budget cannot hold one more byte of the note: a key or a paste that adds one is refused.
	Too_Long  = 4, // A note of the store is longer than a text: it is not shown.
	List_Full = 5, // The list holds NOTE_CAPACITY notes: no new note.
	Selection = 6, // The selection is longer than the buffer of a copy.
	Busy      = 7, // The queue of the store thread is full: the act did not start.
	Unreadable = 8, // The note shown could not be read whole: it is shown empty, and never written.
	Version_Unreadable = 9, // The version chosen could not be read: it is not restored.
}

@(rodata)
window_problem_texts := [Window_Problem]string {
	.None               = "",
	.No_Store           = "No store: the notes are not kept.",
	.Not_Kept           = "The store refused the note: the changes are not kept.",
	.Full               = "The note is full: a key that adds a byte is refused.",
	.Too_Long           = "The note in the store is too long to show: it is not written over.",
	.List_Full          = "The list is full: delete a note to make a new one.",
	.Selection          = "The selection is longer than a note can be.",
	.Busy               = "The store is busy: the act did not start. Try again.",
	.Unreadable         = "The note cannot be read: it is not shown and not written over.",
	.Version_Unreadable = "This version cannot be read: it cannot be restored.",
}

// The keys of each mode, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"). The procedure makes them at each frame: an item is made by
// a call, and a freestanding process runs no call before its entry.
bar_items :: proc "contextless" (items: ^[5]interface.Action_Bar_Item) -> int {
	switch session.mode {
	case .Notes:
		items^ = {
			interface.action_bar_item("New note", 4, "Ctrl", "N"),
			interface.action_bar_item("Delete", 2, "Ctrl", "D"),
			interface.action_bar_item("Versions", 3, "Ctrl", "H"),
			interface.action_bar_item("Previous", 1, "Ctrl", "Page Up"),
			interface.action_bar_item("Next", 0, "Ctrl", "Page Down"),
		}
		return 5
	case .Versions:
		items[0] = interface.action_bar_item("Older", 3, "Down")
		items[1] = interface.action_bar_item("Newer", 2, "Up")
		items[2] = interface.action_bar_item("Restore", 4, "Enter")
		items[3] = interface.action_bar_item("Back", 1, "Esc")
		return 4
	case .Delete:
		items[0] = interface.action_bar_item("Delete", 1, "Enter")
		items[1] = interface.action_bar_item("Keep", 0, "Esc")
		return 2
	}
	return 0
}
bar: interface.Action_Bar_State

// The state of the window over the store thread: the gates of the keys,
// and the requests whose results it waits for (internal:notes/note_session).
session: note_session.Session
notes: note_list.Note_List
shown: int = -1 // The note of the text pane: an index of notes.

text: text_model.Text // The note shown.
// The version that the pane of the versions chose: the text pane shows it,
// and no key changes it.
preview: text_model.Text
layout: text_model.Layout // The rows of the text that the pane shows: computed after each change, never in a frame.
columns := text_model.COLUMNS_LEAST // The cells of a row: from the width of the window.
top_row: int
visible_rows := 1
change_wait: note_list.Change_Wait // A change of the text that waits for its commit, and when.

problem_shown: Window_Problem
request_serial: u64 // The serial of the last request.
restore_generation: i64 // The version that the last request Restore makes current.

// The versions of the note shown, the oldest first, as the store gives
// them; the pane lists them the newest first.
version_rows: [VERSION_ROWS_CAPACITY]storage.Version
version_count: int
version_chosen: int // An index of version_rows; the pane starts at the newest.

// The places of the last frame that the pointer reads between two frames:
// the input acts on what the principal saw.
text_left, text_top: int
text_view: interface.Area
pane_rows_area: interface.Area
pane_first_row: int // The first row of the pane in the last frame.
pointer_buttons_before: u32
pointer_dragging: bool

// The layout tree of each frame. It is large: it lives in the memory of
// the module, never on the stack (src/md/features/box_layout.md).
box_tree: box_layout.Box_Tree
tokens: box_layout.Element_Tokens

// The records that the window thread passes to the store thread and takes
// back from it (store_thread.odin).
window_request: store_work.Request
window_result: store_work.Result
write_gate: store_work.Write_Gate // The one Write in flight, which owns the write memory.

// The arenas of the window (src/md/features/memory_without_a_bound.md):
// each holds one buffer that grows in place, paid by the budget of this
// process, so a note has the size that the budget holds. A reservation
// costs its frame list only; the budget refuses a commit past it, and the
// status band says that the note is full.
TEXT_RESERVE_PAGES :: 4096 // The bytes of a note: 16 MiB.
ROWS_RESERVE_PAGES :: 4096 // The display rows: 2 Mi rows of 8 bytes.
// A text from the store and its clean copy, a selection to copy, a paste.
TRANSFER_RESERVE_PAGES :: 8192
// The read memory and the write memory of the store thread: one note each.
STORE_RESERVE_PAGES :: TEXT_RESERVE_PAGES

text_arena: system.Arena
preview_arena: system.Arena
rows_arena: system.Arena
transfer_arena: system.Arena

// arenas_start reserves the arenas and gives them to the text model and to
// the store thread. A reservation that the budget refuses leaves its zero
// arena, which refuses each growth: the texts then keep the buffers inside
// the model.
arenas_start :: proc "contextless" () {
	text_arena, _ = system.arena_create(TEXT_RESERVE_PAGES)
	preview_arena, _ = system.arena_create(TEXT_RESERVE_PAGES)
	rows_arena, _ = system.arena_create(ROWS_RESERVE_PAGES)
	transfer_arena, _ = system.arena_create(TRANSFER_RESERVE_PAGES)
	read_arena, _ = system.arena_create(STORE_RESERVE_PAGES)
	write_arena, _ = system.arena_create(STORE_RESERVE_PAGES)
	text_model.text_init_buffer(&text, nil, system.arena_grow, &text_arena)
	text_model.text_init_buffer(&preview, nil, system.arena_grow, &preview_arena)
	text_model.layout_init_buffer(&layout, nil, system.arena_grow, &rows_arena)
}

// transfer_bytes gives count bytes of the transfer arena after its first
// `after` bytes, which stay. nil: the budget cannot pay them.
transfer_bytes :: proc "contextless" (after, count: int) -> []u8 {
	whole, status := system.arena_extend_to(&transfer_arena, u64(after + count))
	if status != .Ok {
		return nil
	}
	return whole[after:][:count]
}

title_field :: proc "contextless" (title: string) -> [TITLE_FIELD_BYTES]u8 {
	return value_kinds.text_field(title, TITLE_FIELD_BYTES)
}

shown_title :: proc "contextless" () -> string {
	if shown < 0 {
		return ""
	}
	return note_list.note_title(&notes.notes[shown])
}

// request_of_note puts a request about a note in the queue of the store
// thread. false: the queue is full, or the note has no object.
//
// byte_count: Write, the bytes of the text in the write memory; Version,
// the bytes of the version, from its row.
request_of_note :: proc "contextless" (kind: store_work.Request_Kind, note: ^note_list.Note, generation: i64 = 0, byte_count: int = 0) -> (serial: u64, put: bool) {
	request := &window_request
	request.kind, request.generation, request.byte_count = kind, generation, byte_count
	if !store_work.name_set(note_list.note_name(note), &request.name, &request.name_count) {
		return 0, false
	}
	request_serial += 1
	request.serial = request_serial
	if !request_put(request) {
		return 0, false
	}
	return request_serial, true
}

// shown_note_problem gives the problem of the note shown now: no store
// stays, an unanswered store stays not kept, and a note whose last write
// was refused shows not kept until a write of it succeeds.
shown_note_problem :: proc "contextless" () -> Window_Problem {
	if problem_shown == .No_Store {
		return .No_Store
	}
	if !session.keeping || note_list.note_is_write_refused(&notes, shown) {
		return .Not_Kept
	}
	return .None
}

// shown_text gives the text that the text pane shows: the version chosen
// in the pane of the versions, or the note.
shown_text :: proc "contextless" () -> ^text_model.Text {
	return session.mode == .Versions ? &preview : &text
}

// columns_of_width gives the cells of a row of the text in a window of a
// width: what the pane, the divider, the padding, the scroll bar and the
// caret after a full row leave.
columns_of_width :: proc "contextless" (window_width: int) -> int {
	room := window_width - PANE_WIDTH - DIVIDER_WIDTH - 2 * TEXT_PADDING - interface.SCROLL_BAR_THICKNESS - CARET_WIDTH
	return clamp(room / graphics.CELL_WIDTH, text_model.COLUMNS_LEAST, text_model.COLUMNS_LIMIT)
}

// layout_refresh computes the rows of the text shown, after a change of
// the text or of the width. Its cost is one pass over the text: at a key or
// a resize, never in a frame.
layout_refresh :: proc "contextless" () {
	text_model.layout_compute(&layout, shown_text(), columns, .Word)
	scroll_to_caret()
}

scroll_to_caret :: proc "contextless" () {
	row := text_model.row_of(&layout, shown_text().caret)
	if row < top_row {
		top_row = row
	}
	if row >= top_row + visible_rows {
		top_row = row - visible_rows + 1
	}
	top_row = clamp(top_row, 0, max(layout.row_count - visible_rows, 0))
}

// title_refresh renames the note shown by its first line, at each change.
title_refresh :: proc "contextless" () {
	if shown < 0 {
		return
	}
	first: [TITLE_READ_BYTES]u8
	count := min(text_model.text_length(&text), len(first))
	for place in 0 ..< count {
		first[place] = text_model.byte_at(&text, place)
	}
	note_list.title_set(&notes.notes[shown], first[:count])
}

// commit puts the note shown in the queue of the store thread, when a
// change waits. A note that is not loaded or that could not be read is
// never written. The first commit of a new note gives it its object. A
// full queue keeps the change waiting for one more pause.
commit :: proc "contextless" () {
	if !change_wait.waiting {
		return
	}
	if !note_session.commit_allowed(&session) || shown < 0 {
		change_wait.waiting = false
		return
	}
	note := &notes.notes[shown]
	if note_list.note_name_take(&notes, shown) != .None {
		note.write_refused = true
		problem_shown, change_wait.waiting = .Not_Kept, false
		return
	}
	// One Write in flight owns the write memory: a change while it runs
	// waits for one more pause (store_work.Write_Gate).
	if !store_work.write_gate_take(&write_gate) {
		note_list.change_wait_again(&change_wait, system.time())
		return
	}
	bytes := text_model.text_bytes(&text)
	snapshot, room_ok := write_memory(len(bytes))
	if !room_ok {
		store_work.write_gate_done(&write_gate)
		problem_shown, change_wait.waiting = .Not_Kept, false
		return
	}
	copy(snapshot, bytes)
	if _, put := request_of_note(.Write, note, 0, len(bytes)); !put {
		store_work.write_gate_done(&write_gate)
		note_list.change_wait_again(&change_wait, system.time())
		return
	}
	change_wait.waiting = false
}

// change_end records a change of the text: it waits for the pause.
change_end :: proc "contextless" () {
	note_list.change_wait_mark(&change_wait, system.time())
	if problem_shown == .Full || problem_shown == .Selection || problem_shown == .Busy {
		problem_shown = .None
	}
	title_refresh()
	layout_refresh()
}

// text_take writes bytes from the store into a text: each invalid sequence
// becomes the replacement character. ok is false for bytes that the budget
// cannot hold, and the text is then empty.
text_take :: proc "contextless" (into: ^text_model.Text, bytes: []u8) -> (replaced: int, ok: bool) {
	defer system.arena_reset(&transfer_arena)
	clean := transfer_bytes(0, text_model.text_clean_length(bytes))
	count, replaced_count := 0, 0
	problem := text_model.Edit_Problem.Too_Long
	if clean != nil || len(bytes) == 0 {
		count, replaced_count, problem = text_model.text_clean(bytes, clean)
	}
	if problem != .None || text_model.text_replace_whole(into, clean[:count]) != .None {
		text_model.text_replace_whole(into, nil)
		text_model.selection_set(into, 0, 0)
		return 0, false
	}
	text_model.selection_set(into, 0, 0)
	return replaced_count, true
}

// room_for says if the queue takes the requests of an act; else the status
// band says that the store is busy, and the act does not start.
room_for :: proc "contextless" (needed: int) -> bool {
	if requests_room() < needed {
		problem_shown = .Busy
		return false
	}
	return true
}

// note_load_ask asks for the bytes of the note shown. The room was counted
// before the act started.
note_load_ask :: proc "contextless" () {
	text_model.text_replace_whole(&text, nil)
	text_model.selection_set(&text, 0, 0)
	note := &notes.notes[shown]
	if note.name_count == 0 || !session.keeping {
		note_session.note_shown_new(&session)
		return
	}
	serial, put := request_of_note(.Load, note)
	note_session.load_asked(&session, serial)
	if !put {
		// The note is not loaded: it stays locked, never written.
		note_session.load_done(&session, .Refused)
		problem_shown = .Busy
	}
}

// note_show shows a note: the change of the note before it goes to the
// store first, and an empty new note that the store does not hold leaves
// the list. The text pane waits for the bytes of a note that the store
// holds; the window draws meanwhile. With no room in the queue for the
// commit and the load, the note shown stays.
note_show :: proc "contextless" (index: int) {
	if index < 0 || index >= notes.count || index == shown {
		return
	}
	if !room_for(note_session.show_room(&session, change_wait.waiting, notes.notes[index].name_count > 0)) {
		return
	}
	commit()
	wanted := index
	if shown >= 0 && notes.notes[shown].name_count == 0 && text_model.text_length(&text) == 0 {
		note_list.list_remove(&notes, shown)
		if wanted > shown {
			wanted -= 1
		}
	}
	shown = wanted
	top_row = 0
	problem_shown = shown_note_problem()
	note_load_ask()
	layout_refresh()
	system.log_fact(.Info, Note_Shown{title = title_field(shown_title())})
}

// note_new makes an empty note at the end of the list and shows it.
note_new :: proc "contextless" () {
	if !room_for(note_session.show_room(&session, change_wait.waiting, false)) {
		return
	}
	commit()
	if shown >= 0 && notes.notes[shown].name_count == 0 && text_model.text_length(&text) == 0 && !session.loading && !session.locked {
		// The note shown is new and empty already.
		return
	}
	index, problem := note_list.list_add_new(&notes)
	if problem != .None {
		problem_shown = .List_Full
		return
	}
	shown = index
	note_session.note_shown_new(&session)
	problem_shown = shown_note_problem()
	text_model.text_replace_whole(&text, nil)
	text_model.selection_set(&text, 0, 0)
	top_row = 0
	layout_refresh()
	system.log_fact(.Info, Note_Created{notes = u64(notes.count)})
}

// note_delete removes the note shown from the list, and asks the store
// thread to remove its object and its versions. It starts only when the
// queue takes the removal and the load of the note shown after it.
note_delete :: proc "contextless" () {
	note_session.delete_closed(&session)
	bar = {}
	if shown < 0 {
		return
	}
	note := &notes.notes[shown]
	next := shown + 1 < notes.count ? shown + 1 : shown - 1
	next_stored := next >= 0 && notes.notes[next].name_count > 0
	deleted_stored := note.name_count > 0
	if !room_for(note_session.delete_room(&session, deleted_stored, next_stored)) {
		return
	}
	if deleted_stored && session.keeping {
		if _, put := request_of_note(.Remove, note); !put {
			problem_shown = .Busy
			return
		}
	}
	title_buffer: [TITLE_BYTES]u8
	title := string(title_buffer[:copy(title_buffer[:], note_list.note_title(note))])
	change_wait.waiting = false
	after, _ := note_list.list_remove(&notes, shown)
	shown = -1
	system.log_fact(.Info, Note_Deleted{notes = u64(notes.count), title = title_field(title)})
	if after < 0 {
		note_new()
		return
	}
	note_show(after)
}

// versions_open asks for the versions of the note shown. A change that
// waits goes first, so it is a version too; the pane opens with the result,
// and the keys wait for it.
versions_open :: proc "contextless" () {
	if shown < 0 || session.loading || session.locked || !session.keeping {
		return
	}
	commit_room := change_wait.waiting && note_session.commit_allowed(&session) ? 1 : 0
	if !room_for(commit_room + 1) {
		return
	}
	commit()
	note := &notes.notes[shown]
	if note.name_count == 0 {
		return
	}
	if serial, put := request_of_note(.Versions, note); put {
		note_session.versions_asked_now(&session, serial)
	}
}

// version_choose asks for the bytes of a version; the text pane shows it
// when they come, and Enter restores it only then.
version_choose :: proc "contextless" (index: int) {
	if index < 0 || index >= version_count || shown < 0 || !note_session.versions_keys_act(&session) {
		return
	}
	serial, put := request_of_note(.Version, &notes.notes[shown], version_rows[index].generation, int(max(version_rows[index].bytes, 0)))
	if !put {
		problem_shown = .Busy
		return
	}
	version_chosen = index
	note_session.version_asked(&session, serial)
	if problem_shown == .Version_Unreadable {
		problem_shown = shown_note_problem()
	}
	text_model.text_replace_whole(&preview, nil)
	text_model.selection_set(&preview, 0, 0)
	top_row = 0
	layout_refresh()
}

// versions_close goes back to the note.
versions_close :: proc "contextless" () {
	note_session.versions_closed(&session)
	if session.mode == .Notes {
		if problem_shown == .Version_Unreadable {
			problem_shown = shown_note_problem()
		}
		bar = {}
		top_row = 0
		layout_refresh()
	}
}

// version_restore asks the store thread to make the version chosen the
// current note, in one commit: the note before it stays a version. Only a
// version whose bytes came is restored, and the keys wait for the result;
// then the window loads the note from the store.
version_restore :: proc "contextless" () {
	if version_chosen < 0 || version_chosen >= version_count || shown < 0 {
		return
	}
	row := &version_rows[version_chosen]
	if row.current == 1 && note_session.versions_keys_act(&session) {
		versions_close()
		return
	}
	if !note_session.restore_allowed(&session, row.current == 1) || !room_for(2) {
		return
	}
	serial, put := request_of_note(.Restore, &notes.notes[shown], row.generation)
	if !put {
		problem_shown = .Busy
		return
	}
	note_session.restore_asked_now(&session, serial)
	restore_generation = row.generation
}

// result_apply applies one result of the store thread to the window: a
// result that the session does not take is dropped
// (note_session.result_taken).
result_apply :: proc "contextless" (result: ^store_work.Result) {
	// The result of a Write ends the Write in flight, taken or dropped.
	if result.kind == .Write {
		store_work.write_gate_done(&write_gate)
	}
	note_session.unanswered(&session, result.status)
	if result.status == .Unanswered {
		problem_shown = .Not_Kept
	}
	if !note_session.result_taken(&session, result.kind, result.serial) {
		return
	}
	name := string(result.name[:result.name_count])
	switch result.kind {
	case .List:
		note_session.listed_now(&session, result.status)
		if result.status == .No_Store {
			problem_shown = .No_Store
			system.log_fact(.Info, No_Store{})
			note_new()
			return
		}
		if result.status != .Done {
			problem_shown = .Not_Kept
		}
		// The store thread wrote the list before this result, and writes it
		// for no other request.
		notes = store_listed
		newest := note_list.list_newest(&notes)
		if newest < 0 {
			if session.keeping {
				system.log_fact(.Info, New_Store{})
			}
			note_new()
			return
		}
		note_show(newest)
		system.log_fact(.Info, Notes_Restored{notes = u64(notes.count), title = title_field(shown_title())})
	case .Load:
		switch note_session.load_done(&session, result.status) {
		case .Text:
			replaced, _ := text_take(&text, read_memory()[:result.byte_count])
			title_refresh()
			if replaced > 0 {
				system.log_fact(.Info, Note_Cleaned{replaced = u64(replaced), title = title_field(shown_title())})
			}
		case .Empty:
		// The versions of a damaged object are in the store still: the next
		// change writes a new text, and the damaged one stays a version.
		case .Unreadable:
			// A note that cannot be read whole is never written: it stays
			// locked until another note is shown.
			problem_shown = .Unreadable
			if result.status == .Too_Long {
				problem_shown = .Too_Long
				system.log_fact(.Info, Note_Too_Long{bytes = i64(result.byte_count), limit = STORE_RESERVE_PAGES * system.PAGE_SIZE})
			}
		}
		layout_refresh()
	case .Write:
		kept := result.status == .Done
		_, _ = note_list.note_write_done(&notes, name, kept, result.generation)
		if !kept {
			problem_shown = .Not_Kept
			return
		}
		if problem_shown == .Not_Kept && session.keeping && !note_list.note_is_write_refused(&notes, shown) {
			problem_shown = .None
		}
	case .Versions:
		count := result.status == .Done ? min(result.byte_count / size_of(storage.Version), VERSION_ROWS_CAPACITY) : 0
		if !note_session.versions_done(&session, result.status, count) {
			return
		}
		copy(([^]u8)(&version_rows)[:count * size_of(storage.Version)], read_memory()[:count * size_of(storage.Version)])
		version_count = count
		bar = {}
		version_choose(version_count - 1)
	case .Version:
		note_session.version_done(&session, result.status)
		if result.status != .Done {
			// The version cannot be read: Enter does not restore it, and
			// the status band says why.
			if result.status != .Unanswered {
				problem_shown = .Version_Unreadable
			}
			layout_refresh()
			return
		}
		if problem_shown == .Version_Unreadable {
			problem_shown = shown_note_problem()
		}
		text_take(&preview, read_memory()[:result.byte_count])
		layout_refresh()
		row := &version_rows[version_chosen]
		date_buffer: [DATE_FIELD_BYTES]u8
		date := row.date != 0 ? calendar.iso_text(date_buffer[:], row.date) : "no date"
		system.log_fact(.Info, Version_Shown{version = u64(version_count - version_chosen), versions = u64(version_count), generation = row.generation, date = value_kinds.text_field(date, DATE_FIELD_BYTES), title = title_field(text_title(&preview))})
	case .Restore:
		if !note_session.restore_done(&session, result.status) {
			problem_shown = .Not_Kept
			return
		}
		notes.notes[shown].generation = result.generation
		notes.notes[shown].write_refused = false
		if problem_shown == .Version_Unreadable || problem_shown == .Not_Kept {
			problem_shown = shown_note_problem()
		}
		system.log_fact(.Info, Version_Restored{generation = restore_generation, commit = result.generation, title = title_field(text_title(&preview))})
		bar = {}
		top_row = 0
		change_wait.waiting = false
		// The note is what the store made current: the window loads it,
		// and never takes its preview for it.
		note_load_ask()
		layout_refresh()
	case .Remove:
		if result.status != .Done {
			problem_shown = .Not_Kept
		}
	}
}

// text_title gives the title of a text: its first line.
text_title_buffer: [TITLE_BYTES]u8
text_title :: proc "contextless" (source: ^text_model.Text) -> string {
	first: [TITLE_READ_BYTES]u8
	count := min(text_model.text_length(source), len(first))
	for place in 0 ..< count {
		first[place] = text_model.byte_at(source, place)
	}
	title, title_count := note_list.title_of(first[:count])
	text_title_buffer = title
	return string(text_title_buffer[:title_count])
}

insert_typed :: proc "contextless" (character: rune) {
	switch text_model.text_insert_character(&text, character) {
	case .None:
		change_end()
	case .Too_Long:
		problem_shown = .Full
	case .Empty, .Not_Text:
	// A key with no character of a text: a control key with no action.
	}
}

move :: proc "contextless" (motion: text_model.Motion, extend: bool) {
	text_model.caret_move(shown_text(), &layout, motion, extend, visible_rows)
	scroll_to_caret()
}

// key_run runs one key: a typed key, or the key of an item of the action
// bar that a press ran. The session says which keys act while the store
// works (internal:notes/note_session).
key_run :: proc "contextless" (press: interface.Key_Press) {
	control := press.modifiers & display.MODIFIER_CONTROL != 0
	shift := press.modifiers & display.MODIFIER_SHIFT != 0
	switch session.mode {
	case .Delete:
		switch press.code {
		case display.KEY_ENTER:
			note_delete()
		case display.KEY_ESCAPE:
			note_session.delete_closed(&session)
			bar = {}
		}
		return
	case .Versions:
		if !note_session.versions_keys_act(&session) {
			return
		}
		switch press.code {
		case display.KEY_DOWN:
			version_choose(version_chosen - 1)
		case display.KEY_UP:
			version_choose(version_chosen + 1)
		case display.KEY_ENTER:
			version_restore()
		case display.KEY_ESCAPE:
			versions_close()
		case display.KEY_PAGE_UP, display.KEY_PAGE_DOWN:
			move(press.code == display.KEY_PAGE_UP ? .Page_Up : .Page_Down, false)
		}
		return
	case .Notes:
	}
	text_keys := note_session.text_keys_act(&session)
	list_keys := note_session.list_keys_act(&session)
	if control {
		switch press.code {
		case display.KEY_HOME:
			if text_keys {
				move(.Text_Start, shift)
			}
			return
		case display.KEY_END:
			if text_keys {
				move(.Text_End, shift)
			}
			return
		case display.KEY_PAGE_UP:
			if list_keys {
				note_show(shown - 1)
			}
			return
		case display.KEY_PAGE_DOWN:
			if list_keys {
				note_show(shown + 1)
			}
			return
		}
		// The character of a letter depends on the layout of the keyboard:
		// the window compares the character, not the code.
		switch press.character {
		case 'a', 'A':
			if text_keys {
				text_model.text_select_all(&text)
				scroll_to_caret()
			}
		case 'n', 'N':
			if list_keys {
				note_new()
			}
		case 'd', 'D':
			if shown >= 0 && note_session.delete_asked(&session) {
				bar = {}
				system.log_fact(.Info, Delete_Asked{title = title_field(shown_title())})
			}
		case 'h', 'H':
			if list_keys {
				versions_open()
			}
		}
		return
	}
	// The text that the store has not given, or could not give, takes no key.
	if !text_keys {
		return
	}
	switch press.code {
	case display.KEY_LEFT:
		move(.Left, shift)
	case display.KEY_RIGHT:
		move(.Right, shift)
	case display.KEY_UP:
		move(.Up, shift)
	case display.KEY_DOWN:
		move(.Down, shift)
	case display.KEY_HOME:
		move(.Line_Start, shift)
	case display.KEY_END:
		move(.Line_End, shift)
	case display.KEY_PAGE_UP:
		move(.Page_Up, shift)
	case display.KEY_PAGE_DOWN:
		move(.Page_Down, shift)
	case display.KEY_BACKSPACE:
		if text_model.text_delete_before(&text) {
			change_end()
		}
	case display.KEY_DELETE:
		if text_model.text_delete_after(&text) {
			change_end()
		}
	case display.KEY_ENTER:
		insert_typed(text_model.LINE_END)
	case display.KEY_TAB:
		insert_typed(text_model.TAB)
	case display.KEY_ESCAPE:
		text.anchor = text.caret
	case:
		if press.character != 0 {
			insert_typed(press.character)
		}
	}
}

// copy_event answers Copy_Asked (Ctrl+C or Ctrl+X) from the compositor. A
// cut deletes the selection only after the copy is sent, so a refused copy
// never loses text.
copy_event :: proc "contextless" (window: ^display.Window, action: display.Copy_Action) {
	if session.mode != .Notes || session.loading {
		display.copy_decline(window)
		return
	}
	copied := transfer_bytes(0, text_model.selection_count(&text))
	defer system.arena_reset(&transfer_arena)
	count, copy_problem := text_model.selection_copy(&text, copied)
	if copied == nil && text_model.selection_count(&text) > 0 {
		copy_problem = .Too_Long
	}
	switch copy_problem {
	case .Empty, .Not_Text:
		display.copy_decline(window)
		return
	case .Too_Long:
		display.copy_decline(window)
		problem_shown = .Selection
		return
	case .None:
	}
	// A cut changes the text: it waits as a typed key does
	// (note_session.cut_allowed). A copy changes nothing.
	if action == .Cut && !note_session.cut_allowed(&session) {
		display.copy_decline(window)
		return
	}
	if send_problem, _ := display.copy_send(window, copied[:count]); send_problem != .None {
		return
	}
	if action == .Cut && text_model.selection_delete(&text) {
		change_end()
	}
}

// paste_event answers Pasted (Ctrl+V): a text of several lines, with tabs.
paste_event :: proc "contextless" (window: ^display.Window, event: display.Event) {
	// The room of a paste is the bytes of its content, in the transfer
	// arena; a budget that cannot hold them refuses the paste whole.
	room := transfer_bytes(0, max(event.byte_count, 0))
	defer system.arena_reset(&transfer_arena)
	pasted, paste_problem := display.paste_read(window, event, room, .Multi_Line)
	if paste_problem == .Too_Large && note_session.text_keys_act(&session) {
		problem_shown = .Full
	}
	if paste_problem != .None || !note_session.text_keys_act(&session) {
		return
	}
	switch text_model.text_insert(&text, room[:pasted]) {
	case .None:
		change_end()
	case .Too_Long:
		problem_shown = .Full
	case .Empty, .Not_Text:
	}
}

place_of_pointer :: proc "contextless" (x, y: int) -> int {
	row_in_window := y < text_top ? -1 : (y - text_top) / graphics.CELL_HEIGHT
	row := clamp(top_row + row_in_window, 0, layout.row_count - 1)
	column := x < text_left ? 0 : (x - text_left + graphics.CELL_WIDTH / 2) / graphics.CELL_WIDTH
	return text_model.place_at_column(&layout, shown_text(), row, column)
}

inside :: proc "contextless" (area: interface.Area, x, y: int) -> bool {
	return x >= area.x && x < area.x + area.width && y >= area.y && y < area.y + area.height
}

// pointer_event: a press on a row of the pane shows its note or its
// version; a press in the text places the caret, and a drag selects.
pointer_event :: proc "contextless" (event: display.Event) {
	left := event.buttons & display.BUTTON_LEFT != 0
	pressed := left && pointer_buttons_before & display.BUTTON_LEFT == 0
	pointer_buttons_before = event.buttons
	if pressed && interface.action_bar_takes_pointer(&bar, event.x, event.y) {
		return
	}
	switch {
	case pressed && inside(pane_rows_area, event.x, event.y):
		row := pane_first_row + (event.y - pane_rows_area.y) / PANE_ROW_HEIGHT
		switch session.mode {
		case .Notes:
			if note_session.list_keys_act(&session) {
				note_show(row)
			}
		case .Versions:
			version_choose(version_count - 1 - row)
		case .Delete:
		}
	case pressed && inside(text_view, event.x, event.y) && note_session.text_keys_act(&session):
		pointer_dragging = true
		place := place_of_pointer(event.x, event.y)
		text_model.selection_set(&text, place, place)
	case left && pointer_dragging:
		text_model.selection_set(&text, text.anchor, place_of_pointer(event.x, event.y))
		scroll_to_caret()
	case !left:
		pointer_dragging = false
	}
}

// row_draw draws the text of one display row, and the selection under it.
row_draw :: proc "contextless" (table: ^interface.Draw_Table, source: ^text_model.Text, row: int, y: int, first, last: int) {
	start := int(layout.rows[row].start)
	end := text_model.row_bytes_end(&layout, source, row)
	from, to := max(first, start), min(last, end)
	if from < to {
		left := text_left + text_model.column_of(&layout, source, row, from) * graphics.CELL_WIDTH
		right := text_left + text_model.column_of(&layout, source, row, to) * graphics.CELL_WIDTH
		interface.draw_rectangle(table, left, y, right - left, graphics.CELL_HEIGHT, tokens.surface_chosen)
	}
	buffer: [ROW_BUFFER_SIZE]u8
	count, column, run_column := 0, 0, 0
	run_selected := false
	place := start
	for place < end && count + 4 <= len(buffer) {
		selected := place >= first && place < last
		if selected != run_selected && count > 0 {
			interface.draw_text(table, text_left + run_column * graphics.CELL_WIDTH, y, string(buffer[:count]), run_selected ? tokens.text_on_chosen : tokens.text)
			count = 0
		}
		if count == 0 {
			run_column, run_selected = column, selected
		}
		value := text_model.byte_at(source, place)
		if value == text_model.TAB {
			width := text_model.TAB_WIDTH - column % text_model.TAB_WIDTH
			for _ in 0 ..< width {
				buffer[count] = ' '
				count += 1
			}
			column += width
			place += 1
		} else {
			length := text_model.character_length(source, place)
			for offset in 0 ..< length {
				buffer[count] = text_model.byte_at(source, place + offset)
				count += 1
			}
			column += 1
			place += length
		}
	}
	if count > 0 {
		interface.draw_text(table, text_left + run_column * graphics.CELL_WIDTH, y, string(buffer[:count]), run_selected ? tokens.text_on_chosen : tokens.text)
	}
}

// The boxes of the window whose rectangles a frame reads after the solve.
Window_Boxes :: struct {
	pane, divider, text_area, scroll_bar, status, status_left, status_right, action_bar: box_layout.Box_Index,
}

area_of :: proc "contextless" (index: box_layout.Box_Index) -> interface.Area {
	box := box_layout.box_of(&box_tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// layout_build makes the layout tree of the window at its size: the pane,
// a divider and the text over the status band and the action bar.
layout_build :: proc "contextless" (window: ^display.Window, table: ^interface.Draw_Table, right_words: string) -> (boxes: Window_Boxes) {
	width := i32(clamp(window.width, 0, box_layout.LENGTH_LIMIT))
	height := i32(clamp(window.height, 0, box_layout.LENGTH_LIMIT))
	_ = box_layout.tree_begin(&box_tree, width, height, {label = "notes", child_axis = .Y})
	_, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}, child_axis = .X, overflow = {.X = .Clip, .Y = .Clip}})
	boxes.pane, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(PANE_WIDTH), .Y = box_layout.fill()}})
	boxes.divider, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(DIVIDER_WIDTH), .Y = box_layout.fill()}})
	boxes.text_area, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.fill()}})
	boxes.scroll_bar, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.px(interface.SCROLL_BAR_THICKNESS), .Y = box_layout.fill()}})
	_ = box_layout.box_close(&box_tree)
	right_width := i32(interface.text_measured_width(table, {}, right_words))
	boxes.status, _ = box_layout.box_open(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(STATUS_HEIGHT)}, child_axis = .X, cross_align = .Center, padding = {.X = tokens.gap, .Y = 0}, gap = 2 * tokens.gap})
	boxes.status_left, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(graphics.CELL_HEIGHT)}})
	boxes.status_right, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.text_size(), .Y = box_layout.px(graphics.CELL_HEIGHT)}, text_width = right_width})
	_ = box_layout.box_close(&box_tree)
	boxes.action_bar, _ = box_layout.box_add(&box_tree, {size = {.X = box_layout.fill(), .Y = box_layout.px(interface.ACTION_BAR_ROW_HEIGHT)}})
	_ = box_layout.solve(&box_tree)
	return
}

// pane_draw draws the list of the notes, or the versions of the note
// shown, the row of the note or the version shown on the chosen color.
pane_draw :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area) {
	interface.draw_rectangle(table, area.x, area.y, area.width, area.height, tokens.surface_card)
	interface.draw_clip_push(table, area.x, area.y, area.width, area.height)
	defer interface.draw_clip_pop(table)
	left := area.x + PANE_PADDING
	room := area.width - 2 * PANE_PADDING
	heading := session.mode == .Versions ? "VERSIONS" : "NOTES"
	interface.draw_text(table, left, area.y + (PANE_HEADING_HEIGHT - graphics.CELL_HEIGHT) / 2, heading, tokens.text_dim, interface.FONT_INTERFACE_BOLD)
	pane_rows_area = {area.x, area.y + PANE_HEADING_HEIGHT, area.width, max(area.height - PANE_HEADING_HEIGHT, 0)}
	row_room := max(pane_rows_area.height / PANE_ROW_HEIGHT, 1)
	total := session.mode == .Versions ? version_count : notes.count
	chosen := session.mode == .Versions ? version_count - 1 - version_chosen : shown
	// The row chosen stays in view: the first row moves only when it leaves.
	if chosen < pane_first_row {
		pane_first_row = max(chosen, 0)
	}
	if chosen >= pane_first_row + row_room {
		pane_first_row = chosen - row_room + 1
	}
	pane_first_row = clamp(pane_first_row, 0, max(total - row_room, 0))
	for row in pane_first_row ..< min(total, pane_first_row + row_room) {
		y := pane_rows_area.y + (row - pane_first_row) * PANE_ROW_HEIGHT
		is_chosen := row == chosen
		if is_chosen {
			interface.draw_rectangle(table, area.x, y, area.width, PANE_ROW_HEIGHT, tokens.surface_chosen)
		}
		text_y := y + (PANE_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2
		color := is_chosen ? tokens.text_on_chosen : tokens.text
		label: string
		label_buffer: [48]u8
		if session.mode == .Versions {
			version := &version_rows[version_count - 1 - row]
			label = version.date != 0 ? calendar.iso_text(label_buffer[:], version.date) : system.format(label_buffer[:], "generation ", version.generation)
		} else {
			label = note_list.note_title(&notes.notes[row])
			if label == "" {
				label = "empty note"
				color = is_chosen ? tokens.text_on_chosen : tokens.text_dim
			}
		}
		interface.draw_text(table, left, text_y, interface.text_fit(table, {}, label, room), color)
	}
}

draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	frame := interface.window_frame_start(&window_memory, window)
	interface.action_bar_input_take(&frame, &bar)
	table := frame.table
	tokens, _ = box_layout.tokens_for(graphics.appearance, .Standard)
	source := shown_text()
	caret_row := text_model.row_of(&layout, source.caret)
	right_buffer: [96]u8
	right_words := ""
	if session.mode != .Versions {
		state := "kept"
		switch {
		case session.loading:
			state = "loading"
		case !session.keeping, note_list.note_is_write_refused(&notes, shown):
			state = "not kept"
		case change_wait.waiting:
			state = "a change waits"
		}
		// A note that could not be read has its problem at the left, which
		// says that it is not written: no state at the right.
		if session.locked {
			right_words = system.format(right_buffer[:], "line ", u64(layout.rows[caret_row].line) + 1, ", ", u64(text_model.text_length(&text)), " bytes")
		} else {
			right_words = system.format(right_buffer[:], "line ", u64(layout.rows[caret_row].line) + 1, ", ", u64(text_model.text_length(&text)), " bytes, ", state)
		}
	}
	boxes := layout_build(window, table, right_words)

	interface.draw_rectangle(table, 0, 0, window.width, window.height, tokens.surface_background)
	pane_draw(table, area_of(boxes.pane))
	divider := area_of(boxes.divider)
	interface.draw_rectangle(table, divider.x, divider.y, divider.width, divider.height, tokens.divider)

	text_area := area_of(boxes.text_area)
	text_view = text_area
	text_left, text_top = text_area.x + TEXT_PADDING, text_area.y + TEXT_PADDING
	rows_now := max((text_area.height - 2 * TEXT_PADDING) / graphics.CELL_HEIGHT, 1)
	if rows_now != visible_rows {
		visible_rows = rows_now
		scroll_to_caret()
	}
	top_row = clamp(top_row, 0, max(layout.row_count - visible_rows, 0))
	scrolled := interface.scroll_bar(&frame, area_of(boxes.scroll_bar), interface.identity("notes scroll bar"), .Vertical, {total = layout.row_count, visible = visible_rows, first = top_row}, {}, "", text_area)
	if scrolled.changed {
		top_row = scrolled.first
	}
	interface.draw_clip_push(table, text_area.x, text_area.y, text_area.width, text_area.height)
	first, last := text_model.selection(source)
	end_row := min(top_row + visible_rows, layout.row_count)
	for row in top_row ..< end_row {
		row_draw(table, source, row, text_top + (row - top_row) * graphics.CELL_HEIGHT, first, last)
	}
	if session.mode != .Versions && caret_row >= top_row && caret_row < end_row {
		caret_column := text_model.column_of(&layout, source, caret_row, source.caret)
		interface.draw_rectangle(table, text_left + caret_column * graphics.CELL_WIDTH, text_top + (caret_row - top_row) * graphics.CELL_HEIGHT, CARET_WIDTH, graphics.CELL_HEIGHT, tokens.text_strong)
	}
	interface.draw_clip_pop(table)

	status := area_of(boxes.status)
	interface.draw_rectangle(table, status.x, status.y, status.width, status.height, tokens.surface_card)
	interface.draw_rectangle(table, status.x, status.y, status.width, 1, tokens.divider)
	status_left := area_of(boxes.status_left)
	left_words := window_problem_texts[problem_shown]
	if session.mode == .Versions && session.version_unreadable && problem_shown == .None {
		left_words = window_problem_texts[.Version_Unreadable]
	}
	left_color := tokens.failed
	question_buffer: [TITLE_BYTES + 32]u8
	if session.mode == .Delete {
		title := shown_title()
		if title == "" {
			title = "empty note"
		}
		left_words = system.format(question_buffer[:], "Delete \"", title, "\"?")
		left_color = tokens.warning
	}
	if left_words != "" {
		interface.draw_text(table, status_left.x, status_left.y, interface.text_fit(table, {}, left_words, status_left.width), left_color)
	}
	if right_words != "" {
		status_right := area_of(boxes.status_right)
		interface.draw_text(table, status_right.x, status_right.y, right_words, tokens.text_dim)
	}

	items: [5]interface.Action_Bar_Item
	count := bar_items(&items)
	bar_result := interface.action_bar(&frame, area_of(boxes.action_bar), items[:count], &bar, {})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result
}

// The entry of notes: it reads the list of the notes of its store and
// shows the one changed last, then edits until the principal closes the
// window. A change waits for a pause of the keys, then is a commit.
//
// With no window it stops with `Failed`. With no store it runs, and keeps
// nothing. Then one loop waits for the events of the window, or for the
// end of the pause of a change that waits, and draws after each turn.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "notes")
	if !ok {
		system.stop(.Failed)
	}
	// The limits are constants of this process: a refusal is a fault of
	// this source, and the window then keeps its size.
	_, _ = display.resizable_set(&window, {least_width = LEAST_WIDTH, least_height = LEAST_HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT})
	columns = columns_of_width(window.width)
	// Before the store thread starts: it reads and writes the memory of the
	// notes in the arenas.
	arenas_start()
	// Each call of the storage service runs on the store thread: this
	// thread draws while the store works.
	if _, status := system.thread_start(store_thread_entry, ctx, STORE_THREAD_STACK_PAGES); status != .Ok {
		system.stop(.Failed)
	}
	list_request := store_work.Request{kind = .List, serial = 1}
	request_serial = 1
	request_put(&list_request)
	first_picture := true
	for {
		// The count of the event before the results: a result put after
		// the last take ends the wait below.
		results_seen := system.event_count(&results_event)
		for result_take(&window_result) {
			result_apply(&window_result)
			// The window took the bytes of the result, or dropped it: the
			// store thread can fill the read memory again.
			if window_result.holds_read {
				store_work.read_hold_release(&read_hold)
				system.event_wake(&read_released_event)
			}
		}
		if note_list.change_wait_due(&change_wait, system.time()) {
			commit()
		}
		bar_result := draw(&window)
		if first_picture {
			first_picture = false
			system.log_fact(.Info, First_Picture_Presented{})
		}
		// A press on an item of the action bar runs its key, as the key
		// does; the next turn draws what it changed.
		if bar_result.ran {
			key_run(bar_result.run)
			continue
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_event(&wait, &results_event, results_seen)
		deadline, has_deadline := note_list.change_wait_deadline(&change_wait)
		system.wait_end(&wait, has_deadline ? deadline : system.WAIT_FOREVER)
		for event in display.next_event(&window) {
			switch event.kind {
			case .Pointer:
				// The places of the text are in the coordinates of the
				// layout, which the window scrolls when it does not fit.
				// An event over a bar with no drag of the text is the bar's.
				place, in_layout, _ := interface.window_scroll_event(&window_memory.drawing, &window, event, .Every_Event)
				if in_layout {
					pointer_event(place)
				} else {
					pointer_buttons_before = event.buttons
				}
			case .Key:
				if !event.pressed {
					continue
				}
				// The open list of the action bar takes its keys first.
				press := interface.Key_Press{code = event.code, character = event.character, modifiers = event.modifiers}
				outcome := interface.action_bar_key(&bar, press)
				if outcome.ran {
					key_run(outcome.run)
				}
				if !outcome.taken {
					key_run(press)
				}
			case .Copy_Asked:
				copy_event(&window, event.copy_action)
			case .Pasted:
				paste_event(&window, event)
			case .Resized:
				// The rows follow the width of the window: computed once at
				// the resize, not in each frame.
				if display.surface_resize(&window, event.width, event.height) == .Ok {
					interface.draw_whole_window_next(&window_memory.drawing)
					if width_columns := columns_of_width(window.width); width_columns != columns {
						columns = width_columns
						layout_refresh()
					}
				}
			case .Settings_Changed, .Surface_Answer:
				interface.draw_whole_window_next(&window_memory.drawing)
			case .None, .Go_To, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Capture_Opened, .Work_Area:
			// next_event never gives None, and this window does nothing for the other events.
			}
		}
	}
}
