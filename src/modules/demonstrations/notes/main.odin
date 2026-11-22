// A process that keeps its state when it stops and when the machine stops: a note and a count, in its private store.
//
// Each change goes to the storage service when it happens: the process has no save action. The note is the object "note". The count is the object "count": three blocks that each hold the count in each of their 512 numbers, so that a part of one commit with a part of another would show.
//
// Keys: a character adds to the note, Backspace removes the last one, Enter writes the note on the log. Tab counts 1000 more, one commit for each step.
//
// Versions: each key is one commit, and the storage service keeps the state before it as a version, so the process has undo to any earlier version with no code of its own to keep them. Up shows the version before the one shown, Down the one after; Enter restores the version shown (a new commit: nothing is lost); Escape goes back to the current note. The bar under the note has one mark for each version.
//
// **What it is for.** It is the smallest process that shows persistence as a property of the system and not of
// the process: no file, no path, no save action, and undo with no code of its own. The test of a loss of power
// stops the machine during the run of Tab, then checks at the next start that the three blocks of the count agree.
//
// **Start**: `start("notes")` in the console, or the bar of the desktop. The note holds 60 characters at most.
//
// **Grants**, as the root service gives them:
//
// - **Store**: its private store in the storage service, with a limit of 4500 blocks: the versions of a run of
//   1000 commits of the count, then thinning at the limit. The root service starts the storage service first.
//
// **What a reader sees**: the note, the count, the generation of the last commit and a bar with one mark for each
// version. The log has, at the start, one of:
//
// - `notes: a new store: no note, the count 0`;
// - `notes: restored the note "..." and the count N, its 3 blocks agree`;
// - `notes: WRONG: ...` when an object is damaged or the 3 blocks do not agree;
// - `notes: no store` when the process has no store: it then keeps nothing.
//
// **What it does not prove**: one writer only. Two processes never share the note: each private store belongs to
// one process.
//
// The design: (docs/STORAGE.md, "Versions, thinning and the limit") and (docs/STORAGE.md, "A loss of power").
package notes

import "modus:contract/errors"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:calendar"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:storage"
import "modus:system"

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

NOTE_CAPACITY :: 60
MARGIN :: 12
VERSION_LABEL :: "version  "
// The window starts with the width of its widest line: an older version
// of the note at its full length, after its label. Each other line of the
// window is a text of this process, placed in the width of its box with
// interface.draw_text_wrapped: a line that the window cannot hold goes on
// two lines, it is never cut at the edge.
TEXT_ROOM :: (len(VERSION_LABEL) + NOTE_CAPACITY) * graphics.CELL_WIDTH
// Literals, so the tool reads the window of the budget; the assertions
// keep them the sizes of the layout at the start. Each place in the window
// comes from its layout tree (notes_layout), from the size that the window
// has now.
WIDTH :: 576
#assert(WIDTH == 2 * MARGIN + TEXT_ROOM)
// The action bar wraps: the window is narrow, and its reader learns the
// keys there, so each one shows at once on two rows.
ACTION_BAR_HEIGHT :: interface.ACTION_BAR_WRAP_ROWS * interface.ACTION_BAR_ROW_HEIGHT
HEIGHT :: 324
#assert(HEIGHT == BODY_HEIGHT + ACTION_BAR_HEIGHT)
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (365 pages): its module, its
// stack, its tables and its glyph memory. The tool counts the window at
// the window bound (docs/MODULE_CONTRACT.md, "The budget that a module
// asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1683, window_width = WIDTH, window_height = HEIGHT}

// The keys of the window, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"). A printable character writes the note: the caret after
// the note says it.
// A procedure, not a global array: an item is made by a call, and a
// freestanding process runs no call before its entry.
bar_items :: proc "contextless" () -> [5]interface.Action_Bar_Item {
	return {
		interface.action_bar_item("older version", 4, "Up"),
		interface.action_bar_item("newer version", 3, "Down"),
		interface.action_bar_item("restore the version shown", 4, "Enter"),
		interface.action_bar_item("the current note", 2, "Esc"),
		interface.action_bar_item("count 1000", 1, "Tab"),
	}
}
bar: interface.Action_Bar_State
HISTORY_CAPACITY :: 512 // The versions of the note that the window shows.
COUNT_BLOCKS :: 3
COUNT_WORDS :: COUNT_BLOCKS * 512
RUN_STEPS :: 1000

client: storage.Client
note: [NOTE_CAPACITY]u8
note_count: int
count: u64
generation: i64
words: [COUNT_WORDS]u64 // The object "count".
restored: string // What the start found in the store.
restored_good: bool
gone: bool // The grant of the store ended.

// The versions of the note, the oldest first, the current version last.
history: [HISTORY_CAPACITY]storage.Version
history_total: i64 // All the states: more than history can hold when the note has more versions.
shown: int = -1 // The place in history of the version that the window shows; -1: the current note.
shown_text: [NOTE_CAPACITY]u8
shown_count: int

// The measures: the commits of the note (one key each) and the restores.
commit_time_total, commit_count: u64 // In microseconds.
restore_time_last: u64

history_read :: proc "contextless" () {
	rows, total, status := storage.versions(&client, storage.ROOT, "note", history[:])
	if status == .Ok {
		history_total = total
		shown_count = 0
		_ = rows
	}
}

history_count :: proc "contextless" () -> int {
	return int(min(history_total, HISTORY_CAPACITY))
}

// show reads the version at a place of history.
show :: proc "contextless" (place: int) {
	if place < 0 || place >= history_count() - 1 {
		shown = -1
		return
	}
	shown = place
	bytes, status := storage.version(&client, storage.ROOT, "note", history[place].generation, shown_text[:])
	shown_count = status == .Ok ? len(bytes) : 0
	date_text: [DATE_FIELD_BYTES]u8
	if history[place].date != 0 {
		system.log_fact(.Info, Version_Shown{version = u64(place + 1), versions = u64(history_count()), generation = history[place].generation, date = value_kinds.text_field(calendar.iso_text(date_text[:], history[place].date), DATE_FIELD_BYTES), note_text = note_field(shown_text[:shown_count])})
	} else {
		system.log_fact(.Info, Version_Shown_Without_Date{version = u64(place + 1), versions = u64(history_count()), generation = history[place].generation, note_text = note_field(shown_text[:shown_count])})
	}
}

// keep writes one object. It gives false when the store is gone or refuses.
keep :: proc "contextless" (name: string, data: []u8) -> bool {
	error: errors.Error_Record
	started := system.nanoseconds()
	result, status := storage.write(&client, storage.ROOT, name, data, &error)
	if name == "note" {
		commit_time_total += (system.nanoseconds() - started) / 1000
		commit_count += 1
	}
	if status != .Ok || result < 0 {
		gone = status == .Gone || result == -1
		// The objects are two: the template of a refusal ends with the
		// fields of its error record, so each object has its fact type.
		if !gone && name == "note" {
			system.log_fact(.Info, Note_Write_Refused(errors.error_record_fact_fields(error)))
		} else if !gone {
			system.log_fact(.Info, Count_Write_Refused(errors.error_record_fact_fields(error)))
		}
		return false
	}
	generation = result
	return true
}

keep_count :: proc "contextless" () -> bool {
	for &word in words {
		word = count
	}
	return keep("count", ([^]u8)(&words)[:size_of(words)])
}

count_versions: [1200]storage.Version // The measure of a list of versions of the count.

// restore reads the note and the count, and checks that the three blocks
// of the count hold one count. An object that the storage service has and
// cannot give is not an empty object: the window says it.
restore :: proc "contextless" () {
	text, found, status := storage.read(&client, storage.ROOT, "note", note[:])
	note_damaged := status == .Damaged
	if status != .Ok && !note_damaged {
		restored, gone = "no store: the process keeps nothing", true
		system.log_fact(.Info, No_Store{})
		return
	}
	if found {
		note_count = len(text)
	}
	bytes, has_count, count_status := storage.read(&client, storage.ROOT, "count", ([^]u8)(&words)[:size_of(words)])
	if !found && !has_count && !note_damaged && count_status == .Ok {
		restored, restored_good = "a new store: no note, the count 0", true
		system.log_fact(.Info, New_Store{})
		return
	}
	agree := has_count && len(bytes) == size_of(words)
	if agree {
		count = words[0]
		for word in words {
			if word != count {
				agree = false
			}
		}
	}
	restored_good = agree && !note_damaged
	switch {
	case count_status == .Damaged:
		restored = "WRONG: the count is damaged on the disk: tab writes a new count"
		system.log_fact(.Info, Count_Damaged{})
	case !agree:
		restored = "WRONG: the 3 blocks of the count do not agree"
		system.log_fact(.Info, Count_Blocks_Differ{})
	case note_damaged:
		restored = "WRONG: the note is damaged on the disk: a key writes a new note"
		system.log_fact(.Info, Note_Damaged{count = count})
	case:
		restored = "restored at the start: the note and the count, 3 blocks agree"
		if count % RUN_STEPS != 0 {
			system.log_fact(.Info, Note_Restored_After_Stopped_Run{count = count, note_text = note_field(note[:note_count])})
		} else {
			system.log_fact(.Info, Note_Restored{count = count, note_text = note_field(note[:note_count])})
		}
	}
}

// The lengths of the layout of the window, in logical pixels.
LINE :: graphics.CELL_HEIGHT // One line of text.
SECTION_GAP :: 12 // Between the note, the count and the drawing.
CELL_COLUMNS :: 50 // The drawing: one cell for each step of the count, 400 cells.
CELL_ROWS :: 8
CELL_PITCH :: 10
CELL_SIZE :: 8
STATUS_GAP :: 8
STATUS_ROOM :: 40 // The status of the start takes two lines and a half at least, so the lines under it keep their place.
TRACK_GAP :: 4
TRACK_HEIGHT :: 16 // A lit mark of the bar of the versions; the bar itself is 4 high in its middle.
VERSION_GAP :: 6
BAR_GAP :: 6
BODY_HEIGHT :: MARGIN + LINE + SECTION_GAP + LINE + SECTION_GAP + CELL_ROWS * CELL_PITCH + STATUS_GAP + STATUS_ROOM + LINE + LINE + TRACK_GAP + TRACK_HEIGHT + VERSION_GAP + LINE + BAR_GAP

// The places of the window that the draw reads after the solve.
Notes_Places :: struct {
	note_line:     interface.Area,
	count_line:    interface.Area,
	cells:         interface.Area,
	status:        interface.Area,
	versions_line: interface.Area,
	shown_line:    interface.Area,
	track:         interface.Area,
	version_text:  interface.Area,
	action_bar:    interface.Area,
}

// The layout tree of a frame. A global: the tree is too large for the stack.
layout_tree: layout.Box_Tree

// The status of the start, then, when the store is gone, what that means
// for the keys.
GONE_TEXT :: "the grant of the store ended: the process keeps nothing"

area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// A line across the width of the body.
line_box :: proc "contextless" (height: i32) -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = layout.px(height)}}
}

// notes_layout builds and solves the layout tree of the window at a size:
// the body with its lines in their order, and the action bar at the
// bottom. The status wraps in the width that a first solve gives, so the
// tree is solved again with its height. ok false: the tree refused a box,
// and the frame draws only its action bar.
notes_layout :: proc "contextless" (table: ^interface.Draw_Table, width, height: int) -> (places: Notes_Places, ok: bool) {
	tree := &layout_tree
	if width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y}) != .Done {
		return {}, false
	}
	status: layout.Box_Status
	add :: proc "contextless" (tree: ^layout.Box_Tree, status: ^layout.Box_Status, description: layout.Box_Description) -> layout.Box_Index {
		index, added := layout.box_add(tree, description)
		if status^ == .Done {
			status^ = added
		}
		return index
	}
	_, status = layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y, padding = {.X = MARGIN, .Y = 0}})
	add(tree, &status, line_box(MARGIN))
	note_line := add(tree, &status, line_box(LINE))
	add(tree, &status, line_box(SECTION_GAP))
	count_line := add(tree, &status, line_box(LINE))
	add(tree, &status, line_box(SECTION_GAP))
	cells := add(tree, &status, line_box(CELL_ROWS * CELL_PITCH))
	add(tree, &status, line_box(STATUS_GAP))
	status_box := add(tree, &status, line_box(STATUS_ROOM))
	versions_line := add(tree, &status, line_box(LINE))
	shown_line := add(tree, &status, line_box(LINE))
	add(tree, &status, line_box(TRACK_GAP))
	track := add(tree, &status, line_box(TRACK_HEIGHT))
	add(tree, &status, line_box(VERSION_GAP))
	version_text := add(tree, &status, line_box(LINE))
	// The room left, over the action bar. The lines before it keep their
	// heights: a fill box shares a lack of room with each sibling that is
	// not strict.
	add(tree, &status, {size = {.X = layout.fill(), .Y = layout.fill()}})
	if closed := layout.box_close(tree); status == .Done {
		status = closed
	}
	action_bar := add(tree, &status, line_box(ACTION_BAR_HEIGHT))
	if status != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	// The status takes the lines that it needs in the width that the first
	// solve gave it.
	room := int(tree.boxes[status_box].rect.width)
	lines := interface.text_wrapped_line_count(table, {}, restored, room)
	if gone {
		lines += interface.text_wrapped_line_count(table, {}, GONE_TEXT, room)
	}
	tree.boxes[status_box].size[.Y] = layout.px(max(i32(lines * graphics.CELL_HEIGHT), STATUS_ROOM))
	if layout.solve(tree) != .Done {
		return {}, false
	}
	return {
			note_line = area_of(tree, note_line),
			count_line = area_of(tree, count_line),
			cells = area_of(tree, cells),
			status = area_of(tree, status_box),
			versions_line = area_of(tree, versions_line),
			shown_line = area_of(tree, shown_line),
			track = area_of(tree, track),
			version_text = area_of(tree, version_text),
			action_bar = area_of(tree, action_bar),
		},
		true
}

draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	frame := interface.window_frame_start(&window_memory, window)
	interface.action_bar_input_take(&frame, &bar)
	table := frame.table
	// graphics holds only members of the appearance: the tokens of the
	// standard contrast are the colors that the window drew with before.
	tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
	places, laid_out := notes_layout(table, window.width, window.height)
	if !laid_out {
		// A size that the tree refuses still shows the keys.
		places.action_bar = {0, max(window.height - ACTION_BAR_HEIGHT, 0), window.width, ACTION_BAR_HEIGHT}
	} else {
		draw_body(table, &places, tokens)
	}
	items := bar_items()
	bar_result := interface.action_bar(&frame, places.action_bar, items[:], &bar, {overflow = .Wrap})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	return bar_result
}

// draw_body draws the lines of the window in the places that its layout
// tree gave.
draw_body :: proc "contextless" (table: ^interface.Draw_Table, places: ^Notes_Places, tokens: layout.Element_Tokens) {
	buffer: [32]u8
	line := places.note_line
	x := interface.draw_text(table, line.x, line.y, "note  ", tokens.text_dim)
	x = interface.draw_text(table, x, line.y, string(note[:note_count]), tokens.text)
	// The caret of a text input (docs/DESIGN.md, "10. Elements").
	interface.draw_rectangle(table, x + 1, line.y, 2, LINE, graphics.colors.title)
	// The count is a number, and the generations are versions: each in the
	// color of its value kind (docs/DESIGN.md, "The colors of values"),
	// which is the token of its accent in both appearances.
	line = places.count_line
	x = interface.draw_text(table, line.x, line.y, "count ", tokens.text_dim)
	x = interface.draw_text(table, x, line.y, system.format(buffer[:], count), graphics.colors.memory)
	if generation > 0 { // The generation of the last commit of this process, after its first change.
		x = interface.draw_text(table, x + 24, line.y, "generation ", tokens.text_dim)
		interface.draw_text(table, x, line.y, system.format(buffer[:], generation), tokens.text)
	}
	// The drawing: one cell for each step of the count, 400 cells.
	cells := places.cells
	for cell in 0 ..< CELL_COLUMNS * CELL_ROWS {
		cell_x := cells.x + cell % CELL_COLUMNS * CELL_PITCH
		cell_y := cells.y + cell / CELL_COLUMNS * CELL_PITCH
		interface.draw_rectangle(table, cell_x, cell_y, CELL_SIZE, CELL_SIZE, u64(cell) < count % (CELL_COLUMNS * CELL_ROWS) ? graphics.colors.memory : tokens.surface_track)
	}
	// The status of the start, then, when the store is gone, what that
	// means for the keys: each in the width of its box.
	status := places.status
	status_y := status.y + graphics.CELL_HEIGHT * interface.draw_text_wrapped(table, status.x, status.y, status.width, restored, restored_good ? tokens.expected : tokens.failed)
	if gone {
		interface.draw_text_wrapped(table, status.x, status_y, status.width, GONE_TEXT, tokens.failed)
	}
	// The versions of the note: one mark for each state, the shown one lit.
	// The count is on one line; the generation and the date of the version
	// that the window shows are on the line under it, so the two never meet.
	count := history_count()
	line = places.versions_line
	x = interface.draw_text(table, line.x, line.y, "versions of the note ", tokens.text_dim)
	interface.draw_text(table, x, line.y, system.format(buffer[:], max(history_total - 1, 0)), tokens.text)
	if shown >= 0 {
		line = places.shown_line
		x = interface.draw_text(table, line.x, line.y, "showing generation ", tokens.text_dim)
		x = interface.draw_text(table, x, line.y, system.format(buffer[:], history[shown].generation), graphics.colors.boot_program)
		if history[shown].date != 0 {
			interface.draw_text(table, x + 16, line.y, calendar.iso_text(buffer[:], history[shown].date), tokens.text)
		}
	}
	track := places.track
	interface.draw_rectangle(table, track.x, track.y + 6, track.width, 4, tokens.surface_track)
	if count > 0 {
		for place in 0 ..< count {
			mark_x := track.x + (count == 1 ? track.width - 4 : place * (track.width - 4) / (count - 1))
			lit := place == shown || shown < 0 && place == count - 1
			interface.draw_rectangle(table, mark_x, lit ? track.y : track.y + 2, lit ? 4 : 2, lit ? TRACK_HEIGHT : 12, lit ? graphics.colors.boot_program : tokens.text_dim)
		}
	}
	if shown >= 0 {
		line = places.version_text
		x = interface.draw_text(table, line.x, line.y, VERSION_LABEL, tokens.text_dim)
		interface.draw_text(table, x, line.y, string(shown_text[:shown_count]), tokens.text)
	}
}

// The entry of notes: it restores the note and the count from its store, then commits each key until the
// principal closes the window.
//
// With no window it stops with `Failed`. With no store it runs, and keeps nothing. With a store it reads the
// note, the count and the list of the versions of the note (`restore`, `history_read`), and writes the line of
// the start on the log.
//
// Then one loop waits for keys and draws after each one:
//
// - a printable character or Backspace: one commit of the object "note";
// - Tab: 1000 commits of the object "count", one for each step, with a log line every 100 steps, then the time
//   of the run and the time to list the versions of the count;
// - Enter: the note, its generation, its count of versions and the mean time of one commit, on the log;
// - Up, Down: show an older or a newer version of the note; Enter then restores it in one commit, and Escape
//   goes back to the current note.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "notes")
	if !ok {
		system.stop(.Failed)
	}
	if client, ok = storage.open(ctx); !ok {
		restored, gone = "no store: the process keeps nothing", true
		system.log_fact(.Info, No_Store{})
	} else {
		restore()
		history_read()
	}
	first_picture := true
	for {
		bar_result := draw(&window)
		// The window is open before the store is read: a reader of the log
		// knows from this line that the window shows the note.
		if first_picture {
			first_picture = false
			system.log_fact(.Info, First_Picture_Presented{})
		}
		// A press on an item of the action bar runs its key, as the key
		// does; the next turn draws what it changed.
		if bar_result.ran {
			key_run(&window, bar_result.run)
			continue
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_end(&wait)
		for event in display.next_event(&window) {
			switch event.kind {
			case .Pointer:
				// The pointer reaches the action bar only: the next turn
				// draws a frame with it.
				interface.input_add(&window_memory.drawing.input, event)
			case .Key:
				if !event.pressed {
					continue
				}
				// The open list of the action bar takes its keys first.
				press := interface.Key_Press{code = event.code, character = event.character, modifiers = event.modifiers}
				outcome := interface.action_bar_key(&bar, press)
				if outcome.ran {
					key_run(&window, outcome.run)
				}
				if !outcome.taken {
					key_run(&window, press)
				}
			case .None, .Settings_Changed, .Go_To, .Resized, .Copy_Asked, .Pasted, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Surface_Answer:
				// next_event never gives None, and this window does nothing for the other events.
			}
		}
	}
}

// key_run runs one key: a typed key, or the key of an item of the action
// bar that a press ran.
key_run :: proc "contextless" (window: ^display.Window, press: interface.Key_Press) {
	switch press.code {
	case display.KEY_UP:
		if shown < 0 {
			history_read()
			show(history_count() - 2)
		} else if shown > 0 {
			show(shown - 1)
		}
		return
	case display.KEY_DOWN:
		if shown >= 0 {
			show(shown + 1)
		}
		return
	case display.KEY_ESCAPE:
		shown = -1
		return
	}
	if shown >= 0 && press.character == '\n' {
		// Restore the version shown: one commit, and the note before it
		// becomes a version.
		generation_shown := history[shown].generation
		started := system.nanoseconds()
		commit, status := storage.restore(&client, storage.ROOT, "note", generation_shown)
		restore_time_last = (system.nanoseconds() - started) / 1000
		if status == .Ok && commit > 0 {
			generation = commit
			note_count = copy(note[:], shown_text[:shown_count])
			system.log_fact(.Info, Version_Restored{generation = generation_shown, commit = commit, restore = value_kinds.Time_In_Microseconds(restore_time_last), note_text = note_field(note[:note_count])})
		}
		shown = -1
		history_read()
		return
	}
	shown = -1
	switch press.character {
	case '\t':
		started := system.time()
		for step in 1 ..= RUN_STEPS {
			count += 1
			if !keep_count() {
				break
			}
			if step == RUN_STEPS {
				system.log_fact(.Info, Count_Run_Stopped{count = count, commits = u64(RUN_STEPS), elapsed = value_kinds.Time_In_Milliseconds(system.time() - started)})
				measure_started := system.nanoseconds()
				_, total, status := storage.versions(&client, storage.ROOT, "count", count_versions[:])
				if status == .Ok {
					system.log_fact(.Info, Count_Versions_Listed{rows = total, elapsed = value_kinds.Time_In_Microseconds((system.nanoseconds() - measure_started) / 1000)})
				}
			} else if step % 100 == 0 {
				system.log_fact(.Info, Count_Stepped{count = count})
				draw(window)
			}
		}
	case '\n':
		history_read()
		system.log_fact(.Info, Note_Shown{generation = generation, versions = u64(max(history_total - 1, 0)), commit_mean = value_kinds.Time_In_Microseconds(commit_time_total / max(commit_count, 1)), commits = commit_count, note_text = note_field(note[:note_count])})
	case 8:
		// The note is UTF-8: Backspace removes its last whole
		// character.
		if note_count > 0 {
			note_count = text_encoding.complete_characters(note[:note_count - 1])
			keep("note", note[:note_count])
			history_read()
		}
	case:
		// A character whose bytes do not fit is not typed.
		if length := text_encoding.character_encode(press.character, note[note_count:NOTE_CAPACITY]); length > 0 {
			note_count += length
			keep("note", note[:note_count])
			history_read()
		}
	}
}
