// The editor of a text: one text object of the private store of this
// process, in a window, with the keys that most principals know from other
// systems and no modes (src/md/features/editor.md).
//
// The text has no save action. The editor commits a group of changes when
// the group ends: after a space, a tab or a line end, before a change of
// another kind (a deletion after typed characters), when the caret moves
// to another line, and before an undo or a redo. Each commit is a version
// of the object, so Ctrl+Z restores the version before the one shown, also
// after a restart; Ctrl+Y goes forward again along the restores that
// Ctrl+Z made. A stop of the process loses only the group in progress.
//
// **What it is for.** It edits the text that a principal writes in modus,
// and shows that undo needs no code of its own to keep the states: the
// store keeps each one.
//
// **Start**: `start("edit")` in the console. Keys: a character goes in at
// the caret, in place of the selection; the arrows, Home, End, Page Up and
// Page Down move the caret, and Control with Home or End goes to the start
// or the end of the text; with Shift each of them selects. Backspace and
// Delete remove the selection or one character. Escape ends the selection.
// Ctrl+Z is undo, Ctrl+Y is redo. A press of the pointer places the caret,
// a drag selects, and the wheel scrolls.
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
import "modus:private/edit/text_model"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/storage"
import "modus:support/system"

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
WIDTH :: TEXT_LEFT + TEXT_WIDTH + MARGIN
HEIGHT :: KEYS_Y + interface.ACTION_BAR_ROW_HEIGHT
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
	None     = 0,
	No_Store = 1, // No store, or the text cannot be read: nothing is kept.
	Damaged  = 2, // The object is damaged: the next change writes a new text.
	Too_Long = 3, // The object is longer than a text of the editor: nothing is kept.
	Not_Kept = 4, // The store refused a commit: the changes after it are not kept.
	Full     = 5, // The text has TEXT_CAPACITY bytes: a key that adds one is refused.
}

// The text of each problem. Each fits on one line of the status.
@(rodata)
window_problem_texts := [Window_Problem]string {
	.None     = "",
	.No_Store = "no store: the text is not kept",
	.Damaged  = "the text in the store is damaged: the next change writes a new text",
	.Too_Long = "the text in the store is too long for the editor: nothing is kept",
	.Not_Kept = "the store refused the text: the changes are not kept",
	.Full     = "the text is full: a key that adds a byte is refused",
}

// The keys of the window, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"). A procedure, not a global array: an item is made by a
// call, and a freestanding process runs no call before its entry.
bar_items :: proc "contextless" () -> [2]interface.Action_Bar_Item {
	return {interface.action_bar_item("undo", 2, "Ctrl", "Z"), interface.action_bar_item("redo", 1, "Ctrl", "Y")}
}
bar: interface.Action_Bar_State

text: text_model.Text
layout: text_model.Layout // Computed after each change of the text, never in a frame.
walk: text_model.Version_Walk
waiting_kind: text_model.Change_Kind // The kind of the changes that wait for a commit.
top_row: int // The first display row in the window.

client: storage.Client
keeping: bool // The store takes the changes.
problem_shown: Window_Problem

pointer_buttons_before: u32
pointer_dragging: bool // The left button went down in the text, and is still down.

// The bytes from the store: one byte more than a text can have, so a
// larger object shows as one.
read_buffer: [text_model.TEXT_CAPACITY + 1]u8
clean_buffer: [text_model.TEXT_CAPACITY]u8
version_rows: [VERSION_ROWS_CAPACITY]storage.Version
version_generations: [VERSION_ROWS_CAPACITY]i64

// store_open reads the text of the last run. A store that cannot give it
// whole is never written: the editor starts empty and keeps nothing, so
// a text that it could not read is not lost.
store_open :: proc "contextless" (ctx: ^system.Context) {
	opened: bool
	if client, opened = storage.open(ctx); !opened {
		problem_shown = .No_Store
		system.log(.Info, "edit: no store: the text is not kept")
		return
	}
	error: errors.Error_Record
	bytes, found, read_status := storage.read(&client, storage.ROOT, OBJECT_NAME, read_buffer[:], &error)
	switch {
	case read_status == .Damaged:
		// The versions of the object are still in the store: a change
		// writes a new text, and the damaged one stays a version.
		keeping, problem_shown = true, .Damaged
		system.log(.Info, "edit: the text in the store is damaged: the editor starts empty, and the next change writes a new text")
	case read_status != .Ok:
		problem_shown = .No_Store
		log_storage_failure("edit: the text cannot be read: ", read_status, &error, ": the text is not kept")
	case !found:
		keeping = true
		system.log(.Info, "edit: a new store: an empty text")
	case len(bytes) > text_model.TEXT_CAPACITY:
		problem_shown = .Too_Long
		system.log(.Info, "edit: the text in the store has more than ", u64(text_model.TEXT_CAPACITY), " bytes: the editor starts empty and keeps nothing")
	case:
		count, replaced, problem := text_model.text_clean(bytes, clean_buffer[:])
		if problem != .None {
			problem_shown = .Too_Long
			system.log(.Info, "edit: the text in the store passes ", u64(text_model.TEXT_CAPACITY), " bytes with its replacement characters: the editor starts empty and keeps nothing")
			return
		}
		text_model.text_replace_whole(&text, clean_buffer[:count])
		text_model.selection_set(&text, 0, 0)
		keeping = true
		text_model.layout_compute(&layout, &text)
		if replaced > 0 {
			system.log(.Info, "edit: restored a text of ", u64(count), " bytes, ", u64(layout.line_count), " lines, with ", u64(replaced), " invalid sequences replaced by the replacement character")
		} else {
			system.log(.Info, "edit: restored a text of ", u64(count), " bytes, ", u64(layout.line_count), " lines")
		}
	}
}

// log_storage_failure writes one line with the error record of a call, or
// the status when the service gave no record.
log_storage_failure :: proc "contextless" (before: string, call_status: storage.Status, error: ^errors.Error_Record, after: string) {
	buffer: [256]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	if call_status == .Failed {
		storage.error_text(&writer, &client, error)
	} else {
		system.write_part(&writer, "the storage service did not answer the call")
	}
	system.log(.Info, before, system.written(&writer), after)
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
	generation, write_status := storage.write(&client, storage.ROOT, OBJECT_NAME, text_model.text_bytes(&text), &error)
	if write_status != .Ok || generation < 0 {
		keeping, problem_shown = false, .Not_Kept
		log_storage_failure("edit: the storage service refused the text: ", write_status, &error, ": the changes after it are not kept")
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
	if problem_shown == .Full {
		problem_shown = .None
	}
	layout_refresh()
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
		system.log(.Info, "edit: nothing is selected")
		return
	}
	first_line := layout.rows[text_model.row_of(&layout, first)].line
	last_line := layout.rows[text_model.row_of(&layout, last)].line
	system.log(.Info, "edit: the selection has ", u64(last - first), " bytes, from byte ", u64(first), " to byte ", u64(last), ", over ", u64(last_line - first_line + 1), " lines")
}

// versions_list gives the generations of the versions of the text, the
// oldest first and the current one last.
versions_list :: proc "contextless" (action: string) -> (generations: []i64, ok: bool) {
	error: errors.Error_Record
	rows, total, list_status := storage.versions(&client, storage.ROOT, OBJECT_NAME, version_rows[:], &error)
	if list_status != .Ok {
		log_storage_failure("edit: the versions cannot be listed: ", list_status, &error, "")
		return nil, false
	}
	if total > i64(len(rows)) {
		system.log(.Info, "edit: ", action, ": the text has ", total, " versions, more than the ", u64(VERSION_ROWS_CAPACITY), " that the editor lists")
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
	bytes, read_status := storage.version(&client, storage.ROOT, OBJECT_NAME, generation, read_buffer[:], &error)
	if read_status != .Ok {
		log_storage_failure("edit: the version cannot be read: ", read_status, &error, "")
		return false
	}
	count, replaced, problem := text_model.text_clean(bytes, clean_buffer[:])
	if problem != .None {
		system.log(.Info, "edit: ", action, ": the version of generation ", generation, " is too long for the editor")
		return false
	}
	commit, restore_status := storage.restore(&client, storage.ROOT, OBJECT_NAME, generation, &error)
	if restore_status != .Ok || commit < 0 {
		log_storage_failure("edit: the version cannot be restored: ", restore_status, &error, "")
		return false
	}
	text_model.text_replace_whole(&text, clean_buffer[:count])
	layout_refresh()
	system.log(.Info, "edit: ", action, ": the text has ", u64(count), " bytes, the caret at byte ", u64(text.caret), ", the version of generation ", generation, replaced > 0 ? ", with invalid sequences replaced" : "")
	return true
}

undo :: proc "contextless" () {
	group_commit()
	if !keeping {
		system.log(.Info, "edit: undo: the text is not kept: it has no version")
		return
	}
	generations, listed := versions_list("undo")
	if !listed {
		return
	}
	step, problem := text_model.walk_back(&walk, generations)
	if problem != .None {
		system.log(.Info, "edit: undo: ", text_model.walk_problem_texts[problem])
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
		system.log(.Info, "edit: redo: ", text_model.walk_problem_texts[problem])
		return
	}
	if !keeping {
		system.log(.Info, "edit: redo: the text is not kept: it has no version")
		return
	}
	if version_restore(step.to, "redo") {
		text_model.walk_went_forward(&walk, step)
	}
}

// key_run runs one key: a typed key, or the key of an item of the action
// bar that a press ran.
key_run :: proc "contextless" (press: interface.Key_Press) {
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

// row_draw draws the text of one display row, and the selection under
// it: the selected characters in white on the chosen blue, in runs, so
// each run is one text record.
row_draw :: proc "contextless" (table: ^interface.Draw_Table, row: int, y: int, first, last: int) {
	start := int(layout.rows[row].start)
	end := text_model.row_bytes_end(&layout, &text, row)
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
	run_selected := false
	place := start
	for place < end {
		selected := place >= first && place < last
		if selected != run_selected && count > 0 {
			run_draw(table, run_column, y, string(buffer[:count]), run_selected)
			count = 0
		}
		if count == 0 {
			run_column, run_selected = column, selected
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
		run_draw(table, run_column, y, string(buffer[:count]), run_selected)
	}
}

run_draw :: proc "contextless" (table: ^interface.Draw_Table, column: int, y: int, run: string, selected: bool) {
	color := selected ? graphics.COLOR_WHITE : graphics.colors.text
	interface.draw_text(table, TEXT_LEFT + column * graphics.CELL_WIDTH, y, run, color)
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
	caret_row := text_model.row_of(&layout, text.caret)
	if caret_row >= top_row && caret_row < end_row {
		column := text_model.column_of(&layout, &text, caret_row, text.caret)
		interface.draw_rectangle(table, TEXT_LEFT + column * graphics.CELL_WIDTH, TEXT_TOP + (caret_row - top_row) * graphics.CELL_HEIGHT, CARET_WIDTH, graphics.CELL_HEIGHT, graphics.colors.text_strong)
	}
	if problem_shown != .None {
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
// the wheel. The editor does not take part in the clipboard yet: it
// declines a copy and refuses a paste, so no key of the clipboard waits
// for it.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "edit")
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
			system.log(.Info, "edit: ok, the first picture is presented")
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
				display.copy_decline(&window)
			case .Pasted:
				display.paste_refuse(&window, event)
			case .None, .Settings_Changed, .Go_To, .Resized, .Capture_Size, .Capture_Frame:
			// next_event never gives None, and this window does nothing for the other events.
			}
		}
	}
}
