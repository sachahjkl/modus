// The editor of a text: a text object of its private store, or of any
// granted store opened with `edit(store, name)`, in a window, with the
// keys that most principals know from other systems and no modes
// (src/md/features/editor.md).
//
// The text has no save action. The editor commits a group of changes when
// the group ends: after a space, a tab or a line end, before a change of
// another kind (a deletion after typed characters), when the caret moves
// to another line, after a cut or a paste, and before an undo, a redo or
// a search. Each commit is a version of the object, so Ctrl+Z restores
// the version before the one shown, also after a restart; Ctrl+Y goes
// forward again along the restores that Ctrl+Z made. A stop of the
// process loses only the group in progress.
//
// **What it is for.** It edits the text that a principal writes in modus,
// and shows that undo needs no code of its own to keep the states: the
// store keeps each one.
//
// **Start**: `start("edit")` or `edit(store, name)` in the console. Keys:
// a character goes in at the caret, in place of the selection; the
// arrows, Home, End, Page Up and Page Down move the caret, and Control
// with Home or End goes to the start or the end of the text; with Shift
// each of them selects; Ctrl+A selects all. Backspace and Delete remove
// the selection or one character. Escape ends the selection or closes
// search. Ctrl+C copies, Ctrl+X cuts, Ctrl+V pastes multi-line UTF-8 text
// through the compositor clipboard. Ctrl+F opens incremental search;
// Enter or F3 finds next, Shift+Enter or Shift+F3 finds previous,
// wrapping around the text. Ctrl+Z is undo, Ctrl+Y is redo. A press of
// the pointer places the caret, a drag selects, and the wheel scrolls.
//
// **Grants**, as the root service gives them:
//
// - **Store**: its private store, which holds the object "text" and its
//   versions.
//
// **What a reader sees**: the text in the font of the cells, a line that is
// longer than the window on more rows, the number of each line in a gutter
// at the left, the caret, and the selection with its text in white on the
// chosen blue. The log has, at the start, one of:
//
// - `edit: a new store: an empty text`;
// - `edit: restored a text of N bytes, L lines` (with the count of the
//   invalid sequences that it replaced, when there are some);
// - `edit: no store: the text is not kept`;
// - `edit: the text in the store is damaged: ...`.
//
// Then `edit: undo: the text has N bytes, the caret at byte C, ...` and the
// same for redo, and `edit: the selection has N bytes, from byte A to byte
// B, over L lines` after a selection with Shift or the pointer.
package edit

import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/root_ring"
import "modus:contract/storage_status"
import store_contract "modus:contract/store"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "internal:edit/text_model"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:storage"
import "modus:system"

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(1024, 16384)

OBJECT_NAME :: "text" // The object of the private store that the editor edits.

MARGIN :: 8
// The line numbers end one cell before the text. A text has at most
// TEXT_CAPACITY + 1 lines: 5 digits.
GUTTER_COLUMNS :: 6
GUTTER_WIDTH :: GUTTER_COLUMNS * graphics.CELL_WIDTH
TEXT_LEFT :: MARGIN + GUTTER_WIDTH
TEXT_TOP :: MARGIN
VISIBLE_ROWS :: 28
// One cell more than a row: the caret after a full row stays inside the
// window.
TEXT_WIDTH :: (text_model.COLUMNS + 1) * graphics.CELL_WIDTH
TEXT_HEIGHT :: VISIBLE_ROWS * graphics.CELL_HEIGHT
// The status: a problem of the store or of a key, on at most two lines.
STATUS_Y :: TEXT_TOP + TEXT_HEIGHT + MARGIN
STATUS_LINES :: 2
STATUS_WIDTH :: WIDTH - 2 * MARGIN
KEYS_Y :: STATUS_Y + STATUS_LINES * graphics.CELL_HEIGHT + MARGIN // The action bar, at the bottom.
// Literals, so the tool reads the window of the budget; the assertions
// keep them the sizes of the layout.
WIDTH :: 712
#assert(WIDTH == TEXT_LEFT + TEXT_WIDTH + MARGIN)
HEIGHT :: 528
#assert(HEIGHT == KEYS_Y + interface.ACTION_BAR_ROW_HEIGHT)
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (735 pages): its module, its
// stack, its text, its tables and its glyph memory. The tool counts the
// window at the window bound (docs/MODULE_CONTRACT.md, "The budget that a
// module asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1313, window_width = WIDTH, window_height = HEIGHT}
CARET_WIDTH :: 2
WHEEL_ROWS :: 3 // The rows that one notch of the wheel scrolls.
// The bytes of one display row as the frame draws it: each cell is one
// character of at most 4 bytes, or a space of a tab.
ROW_BUFFER_SIZE :: 4 * text_model.COLUMNS
// The versions that one undo lists. An object with more is refused by the
// undo, with one line of the log: the list of the store gives the oldest
// first.
VERSION_ROWS_CAPACITY :: 1024

// The problem that the status line shows.
Window_Problem :: enum u8 {
	None               = 0,
	No_Store           = 1, // No store, or the text cannot be read: nothing is kept.
	Damaged            = 2, // The object is damaged: the next change writes a new text.
	Too_Long           = 3, // The object is longer than a text of the editor: nothing is kept.
	Not_Kept           = 4, // The store refused a commit: the changes after it are not kept.
	Full               = 5, // The text has TEXT_CAPACITY bytes: a key or paste that adds one is refused.
	Selection_Too_Long = 6, // The selection is longer than CLIPBOARD_TEXT_LIMIT: copy or cut is refused.
	Invalid_Target     = 7, // The target store or object path is invalid: nothing is kept.
}

// The text of each problem. Each fits on one line of the status.
@(rodata)
window_problem_texts := [Window_Problem]string {
	.None               = "",
	.No_Store           = "no store: the text is not kept",
	.Damaged            = "the text in the store is damaged: the next change writes a new text",
	.Too_Long           = "the text in the store is too long for the editor: nothing is kept",
	.Not_Kept           = "the store refused the text: the changes are not kept",
	.Full               = "the text is full: a key that adds a byte is refused",
	.Selection_Too_Long = "the selection is longer than the clipboard limit of 4096 bytes",
	.Invalid_Target     = "the target object is not valid: nothing is kept",
}

// The keys of the window, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"). A procedure, not a global array: an item is made by a
// call, and a freestanding process runs no call before its entry.
bar_items :: proc "contextless" () -> [3]interface.Action_Bar_Item {
	return {
		interface.action_bar_item("find", 3, "Ctrl", "F"),
		interface.action_bar_item("undo", 2, "Ctrl", "Z"),
		interface.action_bar_item("redo", 1, "Ctrl", "Y"),
	}
}
bar: interface.Action_Bar_State

text: text_model.Text
layout: text_model.Layout // Computed after each change of the text, never in a frame.
walk: text_model.Version_Walk
search: text_model.Search
waiting_kind: text_model.Change_Kind // The kind of the changes that wait for a commit.
top_row: int // The first display row in the window.

client: storage.Client
keeping: bool // The store takes the changes.
problem_shown: Window_Problem

target_place: storage.Place = storage.ROOT
target_object_bytes: [store_contract.ENTRY_NAME_CAPACITY]u8
target_object_length: int
target_path_bytes: [root_ring.EDIT_TARGET_PATH_LIMIT]u8
target_path_length: int
target_title_bytes: [31]u8
target_title_length: int
target_has_custom: bool
target_invalid: bool

pointer_buttons_before: u32
pointer_dragging: bool // The left button went down in the text, and is still down.

// The bytes from the store: one byte more than a text can have, so a
// larger object shows as one.
read_buffer: [text_model.TEXT_CAPACITY + 1]u8
clean_buffer: [text_model.TEXT_CAPACITY]u8
clipboard_buffer: [display.CLIPBOARD_TEXT_LIMIT]u8
version_rows: [VERSION_ROWS_CAPACITY]storage.Version
version_generations: [VERSION_ROWS_CAPACITY]i64

target_object_name :: proc "contextless" () -> string {
	return string(target_object_bytes[:target_object_length])
}

// target_read reads an optional Edit_Target page mapped by the root
// service for edit(store, name), and returns the window title.
target_read :: proc "contextless" (ctx: ^system.Context) -> string {
	if .Edit_Target_Page not_in fixed_addresses.ranges_mapped(&ctx.values) {
		copy(target_object_bytes[:], OBJECT_NAME)
		target_object_length = len(OBJECT_NAME)
		return "edit"
	}
	page := (^root_ring.Edit_Target)(uintptr(fixed_addresses.EDIT_TARGET_PAGE_ADDRESS))
	_, path, ok := root_ring.edit_target_read(page)
	if !ok {
		target_invalid = true
		return "edit"
	}
	copy(target_path_bytes[:len(path)], path)
	target_path_length = len(path)
	target_has_custom = true
	writer := system.Writer{buffer = target_title_bytes[:]}
	system.write_part(&writer, "edit: ")
	room := len(target_title_bytes) - writer.count
	shown := path
	if len(shown) > room {
		shown = shown[:text_encoding.complete_characters(transmute([]u8)shown[:room])]
	}
	system.write_part(&writer, shown)
	target_title_length = writer.count
	return string(target_title_bytes[:target_title_length])
}

// store_open reads the text of the last run. A store that cannot give it
// whole is never written: the editor starts empty and keeps nothing, so
// a text that it could not read is not lost.
store_open :: proc "contextless" (ctx: ^system.Context) {
	if target_invalid {
		problem_shown = .Invalid_Target
		system.log_fact(.Info, Target_Invalid{})
		return
	}
	opened: bool
	if client, opened = storage.open(ctx); !opened {
		problem_shown = .No_Store
		system.log_fact(.Info, No_Store{})
		return
	}
	error: errors.Error_Record
	target_place = storage.ROOT
	if target_has_custom {
		path := string(target_path_bytes[:target_path_length])
		cursor := 0
		for {
			segment, next, is_last := root_ring.edit_path_next_segment(path, cursor)
			if is_last {
				copy(target_object_bytes[:len(segment)], segment)
				target_object_length = len(segment)
				break
			}
			next_place, open_status := storage.open_tree(&client, target_place, segment, &error)
			if open_status != .Ok {
				if target_place != storage.ROOT {
					_ = storage.close_tree(&client, target_place)
					target_place = storage.ROOT
				}
				problem_shown = .No_Store
				log_storage_failure(.Read_Text, open_status, &error)
				return
			}
			if target_place != storage.ROOT {
				_ = storage.close_tree(&client, target_place)
			}
			target_place = next_place
			cursor = next
		}
	}
	bytes, found, read_status := storage.read(&client, target_place, target_object_name(), read_buffer[:], &error)
	switch {
	case read_status == .Damaged:
		// The versions of the object are still in the store: a change
		// writes a new text, and the damaged one stays a version.
		keeping, problem_shown = true, .Damaged
		system.log_fact(.Info, Stored_Text_Damaged{})
	case read_status != .Ok:
		problem_shown = .No_Store
		log_storage_failure(.Read_Text, read_status, &error)
	case !found:
		keeping = true
		system.log_fact(.Info, New_Store{})
	case len(bytes) > text_model.TEXT_CAPACITY:
		problem_shown = .Too_Long
		system.log_fact(.Info, Stored_Text_Too_Long{text_capacity = value_kinds.Size_In_Bytes(text_model.TEXT_CAPACITY)})
	case:
		count, replaced, problem := text_model.text_clean(bytes, clean_buffer[:])
		if problem != .None {
			problem_shown = .Too_Long
			system.log_fact(.Info, Cleaned_Text_Too_Long{text_capacity = value_kinds.Size_In_Bytes(text_model.TEXT_CAPACITY)})
			return
		}
		text_model.text_replace_whole(&text, clean_buffer[:count])
		text_model.selection_set(&text, 0, 0)
		keeping = true
		text_model.layout_compute(&layout, &text)
		if replaced > 0 {
			system.log_fact(.Info, Text_Restored_With_Replacements{length = value_kinds.Size_In_Bytes(count), lines = u64(layout.line_count), replaced = u64(replaced)})
		} else {
			system.log_fact(.Info, Text_Restored{length = value_kinds.Size_In_Bytes(count), lines = u64(layout.line_count)})
		}
	}
}

// log_storage_failure writes one fact of a call of the storage service that
// failed: its error record, or that the service gave no answer.
log_storage_failure :: proc "contextless" (step: Storage_Step, call_status: storage_status.Status, error: ^errors.Error_Record) {
	if call_status == .Failed {
		fields := errors.error_record_fact_fields(error^)
		switch step {
		case .Read_Text:
			system.log_fact(.Info, Text_Read_Refused(fields))
		case .Write_Text:
			system.log_fact(.Info, Text_Write_Refused(fields))
		case .List_Versions:
			system.log_fact(.Info, Versions_List_Refused(fields))
		case .Read_Version:
			system.log_fact(.Info, Version_Read_Refused(fields))
		case .Restore_Version:
			system.log_fact(.Info, Version_Restore_Refused(fields))
		}
		return
	}
	switch step {
	case .Read_Text:
		system.log_fact(.Info, Text_Read_Unanswered{})
	case .Write_Text:
		system.log_fact(.Info, Text_Write_Unanswered{})
	case .List_Versions:
		system.log_fact(.Info, Versions_List_Unanswered{})
	case .Read_Version:
		system.log_fact(.Info, Version_Read_Unanswered{})
	case .Restore_Version:
		system.log_fact(.Info, Version_Restore_Unanswered{})
	}
}

// group_commit writes the text in one commit, when changes wait for one.
// A refusal of the store ends the keeping: each later commit would be
// refused too, and the status says that the changes are not kept.
group_commit :: proc "contextless" () {
	if waiting_kind == .None {
		return
	}
	waiting_kind = .None
	if !keeping {
		return
	}
	error: errors.Error_Record
	generation, write_status := storage.write(&client, target_place, target_object_name(), text_model.text_bytes(&text), &error)
	if write_status != .Ok || generation < 0 {
		keeping, problem_shown = false, .Not_Kept
		log_storage_failure(.Write_Text, write_status, &error)
	}
}

// line_of_caret gives the line that holds the caret.
line_of_caret :: proc "contextless" () -> i32 {
	return layout.rows[text_model.row_of(&layout, text.caret)].line
}

// scroll_to_caret moves the window over the rows so that the row of the
// caret is in it, and keeps the first row inside the text.
scroll_to_caret :: proc "contextless" () {
	row := text_model.row_of(&layout, text.caret)
	if row < top_row {
		top_row = row
	}
	if row >= top_row + VISIBLE_ROWS {
		top_row = row - VISIBLE_ROWS + 1
	}
	top_row = clamp(top_row, 0, max(layout.row_count - VISIBLE_ROWS, 0))
}

// layout_refresh computes the rows of the text after it changed.
layout_refresh :: proc "contextless" () {
	text_model.layout_compute(&layout, &text)
	scroll_to_caret()
}

// change_begin commits the group in progress when a change of another
// kind comes.
change_begin :: proc "contextless" (kind: text_model.Change_Kind) {
	if text_model.group_ends_before(waiting_kind, kind) {
		group_commit()
	}
}

// change_end records a change that the text took: it waits for its
// commit, and the next undo goes back from the current version.
change_end :: proc "contextless" (kind: text_model.Change_Kind) {
	waiting_kind = kind
	text_model.walk_changed(&walk)
	if problem_shown == .Full || problem_shown == .Selection_Too_Long {
		problem_shown = .None
	}
	layout_refresh()
	if search.query_count > 0 {
		text_model.search_recompute(&search, &text, text.caret, false)
	}
}

insert_typed :: proc "contextless" (character: rune) {
	change_begin(.Insert)
	switch text_model.text_insert_character(&text, character) {
	case .None:
	case .Too_Long:
		problem_shown = .Full
		return
	case .Empty, .Not_Text:
		// A key with no character of a text: a control key that the
		// editor has no action for.
		return
	}
	change_end(.Insert)
	if text_model.character_ends_group(character) {
		group_commit()
	}
}

delete_key :: proc "contextless" (after: bool) {
	change_begin(.Delete)
	removed: bool
	if after {
		removed = text_model.text_delete_after(&text)
	} else {
		removed = text_model.text_delete_before(&text)
	}
	if removed {
		change_end(.Delete)
	}
}

// move moves the caret. A move to another line ends the group.
move :: proc "contextless" (motion: text_model.Motion, extend: bool) {
	line_before := line_of_caret()
	text_model.caret_move(&text, &layout, motion, extend, VISIBLE_ROWS)
	if line_of_caret() != line_before {
		group_commit()
	}
	scroll_to_caret()
	if extend {
		selection_log()
	}
}

selection_log :: proc "contextless" () {
	first, last := text_model.selection(&text)
	if first == last {
		system.log_fact(.Info, Nothing_Selected{})
		return
	}
	first_line := layout.rows[text_model.row_of(&layout, first)].line
	last_line := layout.rows[text_model.row_of(&layout, last)].line
	system.log_fact(.Info, Selection_Made{selected = value_kinds.Size_In_Bytes(last - first), first = u64(first), last = u64(last), lines = u64(last_line - first_line + 1)})
}

// versions_list gives the generations of the versions of the text, the
// oldest first and the current one last.
versions_list :: proc "contextless" (action: string) -> (generations: []i64, ok: bool) {
	error: errors.Error_Record
	rows, total, list_status := storage.versions(&client, target_place, target_object_name(), version_rows[:], &error)
	if list_status != .Ok {
		log_storage_failure(.List_Versions, list_status, &error)
		return nil, false
	}
	if total > i64(len(rows)) {
		system.log_fact(.Info, Too_Many_Versions{versions = total, listed_versions = u64(VERSION_ROWS_CAPACITY), action = value_kinds.text_field(action, ACTION_FIELD_BYTES)})
		return nil, false
	}
	for row, index in rows {
		version_generations[index] = row.generation
	}
	return version_generations[:len(rows)], true
}

// version_restore makes a version the current text: the store makes it
// its current version in one commit, then the window shows it. false: the
// store refused, and nothing changed.
version_restore :: proc "contextless" (generation: i64, action: string) -> bool {
	error: errors.Error_Record
	bytes, read_status := storage.version(&client, target_place, target_object_name(), generation, read_buffer[:], &error)
	if read_status != .Ok {
		log_storage_failure(.Read_Version, read_status, &error)
		return false
	}
	count, replaced, problem := text_model.text_clean(bytes, clean_buffer[:])
	if problem != .None {
		system.log_fact(.Info, Version_Too_Long{generation = generation, action = value_kinds.text_field(action, ACTION_FIELD_BYTES)})
		return false
	}
	commit, restore_status := storage.restore(&client, target_place, target_object_name(), generation, &error)
	if restore_status != .Ok || commit < 0 {
		log_storage_failure(.Restore_Version, restore_status, &error)
		return false
	}
	text_model.text_replace_whole(&text, clean_buffer[:count])
	layout_refresh()
	if search.query_count > 0 {
		text_model.search_recompute(&search, &text, text.caret, false)
	}
	system.log_fact(.Info, Version_Restored{length = value_kinds.Size_In_Bytes(count), caret = u64(text.caret), generation = generation, action = value_kinds.text_field(action, ACTION_FIELD_BYTES), replaced_words = value_kinds.text_field(replaced > 0 ? REPLACED_WORDS : "", REPLACED_WORDS_FIELD_BYTES)})
	return true
}

undo :: proc "contextless" () {
	group_commit()
	if !keeping {
		system.log_fact(.Info, Undo_Without_Version{})
		return
	}
	generations, listed := versions_list("undo")
	if !listed {
		return
	}
	step, problem := text_model.walk_back(&walk, generations)
	if problem != .None {
		system.log_fact(.Info, Walk_Refused{action = value_kinds.text_field("undo", ACTION_FIELD_BYTES), walk_problem = value_kinds.text_field(text_model.walk_problem_texts[problem], WALK_PROBLEM_FIELD_BYTES)})
		return
	}
	if version_restore(step.to, "undo") {
		text_model.walk_went_back(&walk, step)
	}
}

redo :: proc "contextless" () {
	group_commit()
	step, problem := text_model.walk_forward(&walk)
	if problem != .None {
		system.log_fact(.Info, Walk_Refused{action = value_kinds.text_field("redo", ACTION_FIELD_BYTES), walk_problem = value_kinds.text_field(text_model.walk_problem_texts[problem], WALK_PROBLEM_FIELD_BYTES)})
		return
	}
	if !keeping {
		system.log_fact(.Info, Redo_Without_Version{})
		return
	}
	if version_restore(step.to, "redo") {
		text_model.walk_went_forward(&walk, step)
	}
}

// search_key_run handles one key while the search bar is active.
search_key_run :: proc "contextless" (press: interface.Key_Press) {
	shift := press.modifiers & display.MODIFIER_SHIFT != 0
	if press.modifiers & display.MODIFIER_CONTROL != 0 {
		switch press.character {
		case 'f', 'F':
			// Already in search mode.
		}
		return
	}
	switch press.code {
	case display.KEY_ESCAPE:
		text_model.search_close(&search)
	case display.KEY_ENTER, display.KEY_F3:
		moved := shift ? text_model.search_previous(&search, &text) : text_model.search_next(&search, &text)
		if moved {
			scroll_to_caret()
		}
	case display.KEY_BACKSPACE:
		if text_model.search_query_delete_before(&search, &text) {
			scroll_to_caret()
		}
	case display.KEY_DELETE:
		if text_model.search_query_delete_after(&search, &text) {
			scroll_to_caret()
		}
	case display.KEY_LEFT:
		text_model.search_query_move(&search, .Left)
	case display.KEY_RIGHT:
		text_model.search_query_move(&search, .Right)
	case display.KEY_HOME:
		text_model.search_query_move(&search, .Start)
	case display.KEY_END:
		text_model.search_query_move(&search, .End)
	case:
		if press.character != 0 && text_model.search_query_insert_character(&search, &text, press.character) == .None {
			scroll_to_caret()
		}
	}
}

// key_run runs one key: a typed key, or the key of an item of the action
// bar that a press ran.
key_run :: proc "contextless" (press: interface.Key_Press) {
	if search.active {
		search_key_run(press)
		return
	}
	shift := press.modifiers & display.MODIFIER_SHIFT != 0
	if press.modifiers & display.MODIFIER_CONTROL != 0 {
		switch press.code {
		case display.KEY_HOME:
			move(.Text_Start, shift)
			return
		case display.KEY_END:
			move(.Text_End, shift)
			return
		}
		// The character of a letter depends on the layout of the
		// keyboard: the editor compares the character, not the code.
		switch press.character {
		case 'a', 'A':
			text_model.text_select_all(&text)
			scroll_to_caret()
			selection_log()
		case 'f', 'F':
			group_commit()
			text_model.search_open(&search, &text)
		case 'z', 'Z':
			undo()
		case 'y', 'Y':
			redo()
		}
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
	case display.KEY_F3:
		moved := shift ? text_model.search_previous(&search, &text) : text_model.search_next(&search, &text)
		if moved {
			scroll_to_caret()
		}
	case display.KEY_BACKSPACE:
		delete_key(false)
	case display.KEY_DELETE:
		delete_key(true)
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

// copy_event answers Copy_Asked (Ctrl+C or Ctrl+X) from the compositor.
// On Cut, the selection is deleted and committed only after copy_send
// succeeds, so a refused copy never loses text.
copy_event :: proc "contextless" (window: ^display.Window, action: display.Copy_Action) {
	if search.active {
		if search.query_count == 0 {
			display.copy_decline(window)
			return
		}
		problem, _ := display.copy_send(window, text_model.search_query_bytes(&search))
		if action == .Cut && problem == .None {
			_ = text_model.search_query_set(&search, &text, nil)
		}
		return
	}
	count, copy_problem := text_model.selection_copy(&text, clipboard_buffer[:])
	switch copy_problem {
	case .Empty, .Not_Text:
		display.copy_decline(window)
		return
	case .Too_Long:
		display.copy_decline(window)
		problem_shown = .Selection_Too_Long
		return
	case .None:
	}
	send_problem, _ := display.copy_send(window, clipboard_buffer[:count])
	if send_problem != .None {
		return
	}
	if problem_shown == .Selection_Too_Long {
		problem_shown = .None
	}
	if action == .Cut {
		group_commit()
		if text_model.selection_delete(&text) {
			change_end(.Delete)
			group_commit()
			system.log_fact(.Info, Selection_Cut{length = value_kinds.Size_In_Bytes(count)})
		}
	}
}

// paste_event answers Pasted (Ctrl+V) from the compositor. In search mode
// only single-line text is taken; in the document multi-line text (LF and
// tab) is taken and committed atomically.
paste_event :: proc "contextless" (window: ^display.Window, event: display.Event) {
	if search.active {
		pasted, paste_problem := display.paste_read(window, event, clipboard_buffer[:], .Single_Line)
		if paste_problem != .None {
			return
		}
		if text_model.search_query_insert(&search, &text, clipboard_buffer[:pasted]) == .None {
			scroll_to_caret()
		}
		return
	}
	pasted, paste_problem := display.paste_read(window, event, clipboard_buffer[:], .Multi_Line)
	if paste_problem != .None {
		return
	}
	group_commit()
	switch text_model.text_insert(&text, clipboard_buffer[:pasted]) {
	case .None:
		change_end(.Insert)
		group_commit()
		system.log_fact(.Info, Text_Pasted{length = value_kinds.Size_In_Bytes(pasted)})
	case .Too_Long:
		problem_shown = .Full
	case .Empty, .Not_Text:
	}
}

// place_of_pointer gives the place of the text nearest to a point of the
// surface: the boundary between two cells nearest to it, on the row under
// it. A point above or below the rows in the window gives the row next to
// them, so a drag past an edge scrolls.
place_of_pointer :: proc "contextless" (x, y: int) -> int {
	row_in_window := y < TEXT_TOP ? -1 : (y - TEXT_TOP) / graphics.CELL_HEIGHT
	row := clamp(top_row + row_in_window, 0, layout.row_count - 1)
	column := x < TEXT_LEFT ? 0 : (x - TEXT_LEFT + graphics.CELL_WIDTH / 2) / graphics.CELL_WIDTH
	return text_model.place_at_column(&layout, &text, row, column)
}

inside_text :: proc "contextless" (x, y: int) -> bool {
	return x >= MARGIN && x < TEXT_LEFT + TEXT_WIDTH && y >= TEXT_TOP && y < TEXT_TOP + TEXT_HEIGHT
}

pointer_event :: proc "contextless" (event: display.Event) {
	left := event.buttons & display.BUTTON_LEFT != 0
	pressed := left && pointer_buttons_before & display.BUTTON_LEFT == 0
	pointer_buttons_before = event.buttons
	if event.wheel != 0 && inside_text(event.x, event.y) {
		top_row = clamp(top_row + event.wheel * display.WHEEL_TOWARD_THE_END * WHEEL_ROWS, 0, max(layout.row_count - VISIBLE_ROWS, 0))
	}
	switch {
	// A press that the action bar takes (its list is open, or the press is
	// on it) is not a press in the text.
	case pressed && inside_text(event.x, event.y) && !interface.action_bar_takes_pointer(&bar, event.x, event.y):
		if search.active {
			text_model.search_close(&search)
		}
		pointer_dragging = true
		place := place_of_pointer(event.x, event.y)
		line_before := line_of_caret()
		text_model.selection_set(&text, place, place)
		if line_of_caret() != line_before {
			group_commit()
		}
	case left && pointer_dragging:
		line_before := line_of_caret()
		text_model.selection_set(&text, text.anchor, place_of_pointer(event.x, event.y))
		if line_of_caret() != line_before {
			group_commit()
		}
		scroll_to_caret()
	case !left && pointer_dragging:
		pointer_dragging = false
		if text_model.selection_count(&text) > 0 {
			selection_log()
		}
	}
}

// The visual style of one text run inside a display row.
Run_Style :: enum u8 {
	Normal   = 0,
	Selected = 1, // Active selection or active search match: white on chosen blue.
	Match    = 2, // Other visible search match: strong text on track with warning underline.
}

// row_draw draws the text of one display row, and any selection or search
// match highlights under it: O(log match_count) lookup per visible row,
// never scanning the full text in a frame.
row_draw :: proc "contextless" (table: ^interface.Draw_Table, row: int, y: int, first, last: int) {
	start := int(layout.rows[row].start)
	end := text_model.row_bytes_end(&layout, &text, row)
	// Search match rectangles on this row (when search bar is open).
	match_first := search.match_count
	if search.active && search.match_count > 0 && search.query_count > 0 {
		match_first = text_model.search_first_match_overlapping(&search, start)
		for index := match_first; index < search.match_count; index += 1 {
			m_start := int(search.matches[index])
			if m_start >= end {
				break
			}
			m_end := m_start + search.query_count
			hl_from, hl_to := max(m_start, start), min(m_end, end)
			if hl_from < hl_to {
				left := TEXT_LEFT + text_model.column_of(&layout, &text, row, hl_from) * graphics.CELL_WIDTH
				right := TEXT_LEFT + text_model.column_of(&layout, &text, row, hl_to) * graphics.CELL_WIDTH
				if index == search.active_match {
					interface.draw_rectangle(table, left, y, right - left, graphics.CELL_HEIGHT, graphics.colors.chosen)
				} else {
					interface.draw_rectangle(table, left, y, right - left, graphics.CELL_HEIGHT, graphics.colors.track)
					interface.draw_rectangle(table, left, y + graphics.CELL_HEIGHT - 2, right - left, 2, graphics.colors.warning)
				}
			}
		}
	}
	from, to := max(first, start), min(last, end)
	if from < to {
		left := TEXT_LEFT + text_model.column_of(&layout, &text, row, from) * graphics.CELL_WIDTH
		right := TEXT_LEFT + text_model.column_of(&layout, &text, row, to) * graphics.CELL_WIDTH
		interface.draw_rectangle(table, left, y, right - left, graphics.CELL_HEIGHT, graphics.colors.chosen)
	}
	// A selected line end: one cell after the text of its row.
	if end < text_model.text_length(&text) && text_model.byte_at(&text, end) == text_model.LINE_END && first <= end && last > end {
		left := TEXT_LEFT + text_model.column_of(&layout, &text, row, end) * graphics.CELL_WIDTH
		interface.draw_rectangle(table, left, y, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, graphics.colors.chosen)
	}
	buffer: [ROW_BUFFER_SIZE]u8
	count, column, run_column := 0, 0, 0
	run_style := Run_Style.Normal
	match_cursor := match_first
	place := start
	for place < end {
		style := Run_Style.Normal
		if place >= first && place < last {
			style = .Selected
		} else if search.active && search.query_count > 0 {
			for match_cursor < search.match_count && int(search.matches[match_cursor]) + search.query_count <= place {
				match_cursor += 1
			}
			if match_cursor < search.match_count {
				m_start := int(search.matches[match_cursor])
				if place >= m_start && place < m_start + search.query_count {
					style = match_cursor == search.active_match ? .Selected : .Match
				}
			}
		}
		if style != run_style && count > 0 {
			run_draw(table, run_column, y, string(buffer[:count]), run_style)
			count = 0
		}
		if count == 0 {
			run_column, run_style = column, style
		}
		value := text_model.byte_at(&text, place)
		if value == text_model.TAB {
			width := text_model.TAB_WIDTH - column % text_model.TAB_WIDTH
			for _ in 0 ..< width {
				buffer[count] = ' '
				count += 1
			}
			column += width
			place += 1
		} else {
			length := text_model.character_length(&text, place)
			for offset in 0 ..< length {
				buffer[count] = text_model.byte_at(&text, place + offset)
				count += 1
			}
			column += 1
			place += length
		}
	}
	if count > 0 {
		run_draw(table, run_column, y, string(buffer[:count]), run_style)
	}
}

run_draw :: proc "contextless" (table: ^interface.Draw_Table, column: int, y: int, run: string, style: Run_Style) {
	color: graphics.Color
	switch style {
	case .Normal:
		color = graphics.colors.text
	case .Selected:
		color = graphics.COLOR_WHITE
	case .Match:
		color = graphics.colors.text_strong
	}
	interface.draw_text(table, TEXT_LEFT + column * graphics.CELL_WIDTH, y, run, color)
}

SEARCH_BAR_HEIGHT :: 28

// search_bar_draw draws the incremental search bar in the status band:
// query with caret on the left, match index and count ("2 of 5" or "no
// match") right-aligned on the right, with guaranteed separation.
search_bar_draw :: proc "contextless" (table: ^interface.Draw_Table) {
	interface.draw_rectangle(table, MARGIN, STATUS_Y, STATUS_WIDTH, SEARCH_BAR_HEIGHT, graphics.colors.track)
	interface.draw_rectangle(table, MARGIN, STATUS_Y + SEARCH_BAR_HEIGHT - 2, STATUS_WIDTH, 2, graphics.colors.title)
	text_y := STATUS_Y + (SEARCH_BAR_HEIGHT - graphics.CELL_HEIGHT) / 2
	// Match status at the right: only shown when a query is typed.
	count_buffer: [32]u8
	count_text := ""
	count_color := graphics.colors.dim
	if search.query_count > 0 {
		if search.match_count == 0 {
			count_text = "no match"
			count_color = graphics.colors.failed
		} else {
			writer := system.Writer{buffer = count_buffer[:]}
			system.write_number(&writer, u64(search.active_match + 1))
			system.write_part(&writer, " of ")
			system.write_number(&writer, u64(search.match_count))
			count_text = system.written(&writer)
		}
		interface.draw_text_right(table, MARGIN + STATUS_WIDTH - 8, text_y, count_text, count_color)
	}
	query_left := MARGIN + 8
	right_reserve := len(count_text) > 0 ? len(count_text) * graphics.CELL_WIDTH + 24 : 16
	visible_cells := max((STATUS_WIDTH - 8 - right_reserve) / graphics.CELL_WIDTH, 1)
	if search.query_count == 0 {
		interface.draw_rectangle(table, query_left, text_y, CARET_WIDTH, graphics.CELL_HEIGHT, graphics.colors.title)
		interface.draw_text(table, query_left + 8, text_y, "find", graphics.colors.dim)
		return
	}
	// Scroll the visible slice of the query so the caret stays in view and
	// never passes the right reserve.
	query := text_model.search_query_bytes(&search)
	caret_cells := text_encoding.character_count(query[:search.query_caret])
	skip_cells := caret_cells >= visible_cells ? caret_cells - visible_cells + 1 : 0
	byte_start := 0
	for skipped := 0; skipped < skip_cells && byte_start < len(query); skipped += 1 {
		_, length, _ := text_encoding.character_decode(query, byte_start)
		byte_start += max(length, 1)
	}
	byte_end := byte_start
	shown_cells := 0
	for byte_end < len(query) && shown_cells < visible_cells {
		_, length, _ := text_encoding.character_decode(query, byte_end)
		byte_end += max(length, 1)
		shown_cells += 1
	}
	interface.draw_text(table, query_left, text_y, string(query[byte_start:byte_end]), graphics.colors.text_strong)
	caret_x := query_left + (caret_cells - skip_cells) * graphics.CELL_WIDTH
	interface.draw_rectangle(table, caret_x, text_y, CARET_WIDTH, graphics.CELL_HEIGHT, graphics.colors.title)
}

// draw builds one frame: the rows in the window only, from the layout that
// the last change computed.
draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	frame := interface.window_frame_start(&window_memory, window)
	interface.action_bar_input_take(&frame, &bar)
	table := frame.table
	first, last := text_model.selection(&text)
	end_row := min(top_row + VISIBLE_ROWS, layout.row_count)
	for row in top_row ..< end_row {
		y := TEXT_TOP + (row - top_row) * graphics.CELL_HEIGHT
		if text_model.row_first_of_line(&layout, row) {
			number: [12]u8
			interface.draw_text_right(table, TEXT_LEFT - graphics.CELL_WIDTH, y, system.format(number[:], u64(layout.rows[row].line) + 1), graphics.colors.dim)
		}
		row_draw(table, row, y, first, last)
	}
	if !search.active {
		caret_row := text_model.row_of(&layout, text.caret)
		if caret_row >= top_row && caret_row < end_row {
			column := text_model.column_of(&layout, &text, caret_row, text.caret)
			interface.draw_rectangle(table, TEXT_LEFT + column * graphics.CELL_WIDTH, TEXT_TOP + (caret_row - top_row) * graphics.CELL_HEIGHT, CARET_WIDTH, graphics.CELL_HEIGHT, graphics.colors.text_strong)
		}
	}
	if search.active {
		search_bar_draw(table)
	} else if problem_shown != .None {
		interface.draw_text_wrapped(table, MARGIN, STATUS_Y, STATUS_WIDTH, window_problem_texts[problem_shown], graphics.colors.failed)
	}
	items := bar_items()
	bar_result := interface.action_bar(&frame, {0, KEYS_Y, WIDTH, HEIGHT - KEYS_Y}, items[:], &bar, {})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result
}

// The entry of edit: it reads the text of its store, then edits it until
// the principal closes the window.
//
// With no window it stops with `Failed`. With no store it runs, and keeps
// nothing. Then one loop waits for the events of the window and draws
// after each of them: a key, a press of the pointer, a drag, a turn of
// the wheel, and the clipboard events Copy_Asked (Ctrl+C, Ctrl+X) and
// Pasted (Ctrl+V).
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	title := target_read(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, title)
	if !ok {
		system.stop(.Failed)
	}
	store_open(ctx)
	layout_refresh()
	first_picture := true
	for {
		bar_result := draw(&window)
		if first_picture {
			first_picture = false
			system.log_fact(.Info, Window_Ready{})
		}
		// A press on an item of the action bar runs its key, as the key
		// does; the next turn draws what it changed.
		if bar_result.ran {
			key_run(bar_result.run)
			continue
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_end(&wait)
		for event in display.next_event(&window) {
			switch event.kind {
			case .Pointer:
				interface.input_add(&window_memory.drawing.input, event)
				pointer_event(event)
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
			case .None, .Settings_Changed, .Go_To, .Resized, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Surface_Answer:
			// next_event never gives None, and this window does nothing for the other events.
			}
		}
	}
}
