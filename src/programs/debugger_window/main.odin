// The window of the debugger: the threads, the stack, the variables, the
// source lines and the memory of a program, with no line to type in the
// console (docs/TOOLS.md, "The window of the debugger").
//
// **What it is for.** The service `debugger` holds the debug access to one
// program and serves its exports. The console reaches them by commands.
// This program reaches the same exports through a connection of its own,
// and shows their rows in one window: a developer follows a thread with a
// key or a click for each act.
//
// **Start**: the menu of the programs, or `start("debugger_window")`. Type
// the name of a program and press Enter: the window attaches to it.
//
// **Grants**: Connect, for a connection to the service `debugger` and to
// no other service; Image, to read the description of the exports of that
// service in the boot image; Acts_For_Principal, because the service
// debugs a program only for a caller that acts for the principal. It holds
// no right over a program: the service does, and the root service decides
// which program a caller can debug.
//
// **What a reader sees.** At the left the program, with the debug place
// field and its threads, and under it the breakpoints. At the right the
// source line of the chosen frame, the memory view, the stack of the chosen
// thread and the variables of the chosen frame. The action bar at the
// bottom names the keys; a press on an item does what its key does, and
// the items that do not fit are behind its button "more".
//
// **Keys**, with a program attached and no focus in the field:
//
// - up, down: the thread. page up, page down: the frame.
// - h: hold the thread. r: let it run. c: let each thread run.
// - s: one instruction. l: one line. o: one line, over each call.
// - b: a breakpoint at the source line of the chosen frame. 0 to 3: remove
//   the breakpoint with that number.
// - g: the registers of the chosen thread, or its variables again.
// - d: detach. escape: the keys leave the debug place field.
//
// **The debug place field**: break at, watch and memory take its text, as
// `break_at`, `watch` and `memory` take it in the console. A click on a row
// does what a key does: a thread or a frame is chosen, a source line gets a
// breakpoint, a breakpoint is removed.
package debugger_window

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/ring"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The draw tables of the interface, and the tables of the rows.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2536, programs = 1, threads = 1, window_width = WIDTH, window_height = HEIGHT}

WIDTH :: 1000
HEIGHT :: 704
LINE :: graphics.LINE_HEIGHT
ROW_HEIGHT :: interface.TABLE_LINE // A text field and a button.
MARGIN :: 8
LEFT_WIDTH :: 328
RIGHT_X :: MARGIN + LEFT_WIDTH + MARGIN
RIGHT_WIDTH :: WIDTH - RIGHT_X - MARGIN
KEYS_HEIGHT :: interface.ACTION_BAR_ROW_HEIGHT // The action bar.
CARDS_HEIGHT :: HEIGHT - 2 * MARGIN - KEYS_HEIGHT
// The left column: the program above, the breakpoints below. The card of
// the breakpoints has a fixed place, so its first row has one.
BREAKS_HEIGHT :: 168
PROGRAM_HEIGHT :: CARDS_HEIGHT - BREAKS_HEIGHT - MARGIN
BREAKS_Y :: MARGIN + PROGRAM_HEIGHT + MARGIN
// The right column: the source, the memory, then the stack and the
// variables side by side.
SOURCE_HEIGHT :: 144
MEMORY_Y :: MARGIN + SOURCE_HEIGHT + MARGIN
MEMORY_HEIGHT :: 184
LOW_Y :: MEMORY_Y + MEMORY_HEIGHT + MARGIN
LOW_HEIGHT :: MARGIN + CARDS_HEIGHT - LOW_Y
STACK_WIDTH :: 296
VARIABLES_X :: RIGHT_X + STACK_WIDTH + MARGIN
VARIABLES_WIDTH :: WIDTH - VARIABLES_X - MARGIN
// The debug place field and its three buttons, from the top of the inside
// of the card of the program: under the line of the attached program.
PLACE_FIELD_Y :: LINE + 8
BUTTONS_Y :: PLACE_FIELD_Y + ROW_HEIGHT + 8
BUTTON_GAP :: 8
BUTTON_WIDTH :: (LEFT_WIDTH - 2 * graphics.CARD_MARGIN - 2 * BUTTON_GAP) / 3

REFRESH_MILLISECONDS :: 500 // The threads are read again: a stop of a thread that ran shows then.
NAME_LIMIT :: 31 // The bytes of the name of a program, as the service takes it.
PLACE_LIMIT :: 160 // The bytes of a debug place, as the service takes a text.
THREAD_ROWS :: 32
FRAME_ROWS :: 16
VARIABLE_ROWS :: 16
SOURCE_ROWS :: 16
EVENT_ROWS :: 8
BREAK_ROWS :: 4 // The breakpoints of a program: the debug address registers of a thread.
REGISTER_ROWS :: 24
WATCH_LENGTH :: 8 // The bytes of a watch whose place names no length.

// The memory view: eight rows of 16 bytes, the height of its card.
MEMORY_ROWS :: 8
MEMORY_ROW_BYTES :: 16
MEMORY_BYTES :: MEMORY_ROWS * MEMORY_ROW_BYTES
// An address of a program is below the end of the user half, so it has 12
// hexadecimal digits at most with no leading zero. A row is that address,
// 16 bytes of two digits with a space between two of them, and their 16
// characters, in the font of the cells, with a gap of 8 pixels between two
// columns: it has the width of the card.
MEMORY_ADDRESS_DIGITS :: 12
MEMORY_GAP :: 8
MEMORY_BYTES_X :: MEMORY_ADDRESS_DIGITS * graphics.CELL_WIDTH + MEMORY_GAP
MEMORY_TEXT_X :: MEMORY_BYTES_X + (3 * MEMORY_ROW_BYTES - 1) * graphics.CELL_WIDTH + MEMORY_GAP
MEMORY_ROW_WIDTH :: MEMORY_TEXT_X + MEMORY_ROW_BYTES * graphics.CELL_WIDTH
#assert(MEMORY_ROW_WIDTH <= RIGHT_WIDTH - 2 * graphics.CARD_MARGIN)
#assert(MEMORY_ROWS * LINE <= MEMORY_HEIGHT - graphics.CARD_TITLE - 8)

// The records of the exports of the service, as its description has them
// (src/programs/debugger/exports.odin). The program checks at its start
// that the description of each one has the size of its record here, and
// attaches to nothing when one differs: it never reads a row by a layout
// that the service does not have.
Attached :: struct {
	program:   [32]u8,
	slot:      i64,
	threads:   i64,
	modules:   i64,
	described: i64,
}

Detached :: struct {
	program:     [32]u8,
	breakpoints: i64,
	threads:     i64,
}

Thread_Row :: struct {
	thread:      i64,
	state:       [12]u8,
	instruction: [20]u8,
	module:      [32]u8,
	procedure:   [80]u8,
	offset:      i64,
	file:        [80]u8,
	line:        i64,
	pending:     i64,
}

Frame_Row :: struct {
	frame:          i64,
	module:         [32]u8,
	procedure:      [80]u8,
	offset:         i64,
	file:           [80]u8,
	line:           i64,
	frame_pointer:  [20]u8,
	return_address: [20]u8,
}

Variable_Row :: struct {
	name:     [48]u8,
	role:     [12]u8,
	type:     [48]u8,
	value:    [96]u8,
	location: [28]u8,
}

Source_Row :: struct {
	line: i64,
	mark: [4]u8,
	text: [80]u8,
	path: [80]u8,
	hash: [68]u8,
}

Event_Row :: struct {
	thread:      i64,
	kind:        [20]u8,
	instruction: [20]u8,
	module:      [32]u8,
	procedure:   [80]u8,
	offset:      i64,
	file:        [80]u8,
	line:        i64,
}

Break_Row :: struct {
	number:  i64,
	kind:    [12]u8,
	address: [20]u8,
	length:  i64,
	place:   [160]u8,
}

Register_Row :: struct {
	name:  [8]u8,
	value: [20]u8,
	about: [128]u8,
}

Memory_Row :: struct {
	address: [20]u8,
	bytes:   [48]u8,
	text:    [20]u8,
}

// One export of the service that the window calls, and the size of the
// record of its rows here.
Export :: enum {
	Attach,
	Detach,
	Threads,
	Hold,
	Release,
	Continue_All,
	Stack,
	Locals,
	Source,
	Step,
	Step_Line,
	Step_Over,
	Events,
	Break_At,
	Watch,
	Breaks,
	Break_Remove,
	Registers,
	Memory,
}

@(rodata)
export_names := [Export]string {
	.Attach       = "attach",
	.Detach       = "detach",
	.Threads      = "threads",
	.Hold         = "hold",
	.Release      = "release",
	.Continue_All = "continue_all",
	.Stack        = "stack",
	.Locals       = "locals",
	.Source       = "source",
	.Step         = "step",
	.Step_Line    = "step_line",
	.Step_Over    = "step_over",
	.Events       = "events",
	.Break_At     = "break_at",
	.Watch        = "watch",
	.Breaks       = "breaks",
	.Break_Remove = "break_remove",
	.Registers    = "registers",
	.Memory       = "memory",
}

@(rodata)
export_row_sizes := [Export]u32 {
	.Attach       = size_of(Attached),
	.Detach       = size_of(Detached),
	.Threads      = size_of(Thread_Row),
	.Hold         = size_of(Thread_Row),
	.Release      = size_of(Thread_Row),
	.Continue_All = size_of(Thread_Row),
	.Stack        = size_of(Frame_Row),
	.Locals       = size_of(Variable_Row),
	.Source       = size_of(Source_Row),
	.Step         = size_of(Thread_Row),
	.Step_Line    = size_of(Thread_Row),
	.Step_Over    = size_of(Thread_Row),
	.Events       = size_of(Event_Row),
	.Break_At     = size_of(Break_Row),
	.Watch        = size_of(Break_Row),
	.Breaks       = size_of(Break_Row),
	.Break_Remove = size_of(Break_Row),
	.Registers    = size_of(Register_Row),
	.Memory       = size_of(Memory_Row),
}

// What an element of a frame asks the window to do. The window does it
// after the frame, then draws the frame again: the act changes the rows
// that the frame drew.
Element_Act :: enum u8 {
	None,
	Attach, // Enter in the name field.
	Break_At_Place, // The button break at, or Enter in the debug place field.
	Watch_Place, // The button watch.
	Memory_Place, // The button memory.
	Choose_Thread, // A click on a row of the threads.
	Choose_Frame, // A click on a row of the stack.
	Break_At_Source_Row, // A click on a row of the source.
	Remove_Breakpoint, // A click on a row of the breakpoints.
}

// The acts of one frame: the one act of an element (one press, or one
// Enter, in a frame), and the keys that no element took.
Frame_Acts :: struct {
	act:       Element_Act,
	index:     int, // The row of the act: the place in its table, or the number of a breakpoint.
	keys:      [interface.KEY_CAPACITY]interface.Key_Press,
	key_count: int,
	// A press on an item of the action bar put its key in the input of the
	// next frame: that frame runs it.
	bar_key_given: bool,
}

// The keys of the window, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"). The keys 0 to 3 remove a breakpoint by its number: a key
// with an argument is no item, and a press on a row of the breakpoints
// does the same. Detach has the lowest priority: it is the first item to
// go into the list, and the rarest act.
attached_items := [?]interface.Action_Bar_Item {
	{faces = {"Up"}, name = "thread before", priority = 6},
	{faces = {"Down"}, name = "thread after", priority = 6},
	{faces = {"Page Up"}, name = "frame before", priority = 5},
	{faces = {"Page Down"}, name = "frame after", priority = 5},
	{faces = {"h"}, name = "hold", priority = 8},
	{faces = {"r"}, name = "let run", priority = 8},
	{faces = {"c"}, name = "let each run", priority = 4},
	{faces = {"s"}, name = "one instruction", priority = 7},
	{faces = {"l"}, name = "one line", priority = 7},
	{faces = {"o"}, name = "one line, over each call", priority = 5},
	{faces = {"b"}, name = "breakpoint at the line", priority = 3},
	{faces = {"g"}, name = "registers or variables", priority = 2},
	{faces = {"Esc"}, name = "keys leave the field", priority = 1},
	{faces = {"d"}, name = "detach", priority = 0},
}
detached_items := [?]interface.Action_Bar_Item {
	{faces = {"Enter"}, name = "attach", priority = 2},
	{faces = {"Backspace"}, name = "remove a character", priority = 1},
}
bar: interface.Action_Bar_State

image: []u8
service_file: []u8 // The file of the service `debugger` in the boot image: the description of its exports.
export_indexes: [Export]u32
requests: ring.Ring
has_requests: bool
connection: system.Call_Connection
connected: bool
ready: bool // The connection is open and each record has the size of its description.

name: [NAME_LIMIT]u8 // The name that the name field holds.
name_count: int
attached: bool
attached_row: Attached
// The last thing that the window did, in words, and whether it failed.
status_text: [160]u8
status_count: int
status_failed: bool
// The text of the debug place field.
place_text: [PLACE_LIMIT]u8
place_count: int

thread_rows: [THREAD_ROWS]Thread_Row
thread_count: int
thread_chosen: int // The place of the chosen thread in thread_rows.
frame_rows: [FRAME_ROWS]Frame_Row
frame_count: int
frame_chosen: int
variable_rows: [VARIABLE_ROWS]Variable_Row
variable_count: int
source_rows: [SOURCE_ROWS]Source_Row
source_count: int
event_rows: [EVENT_ROWS]Event_Row
break_rows: [BREAK_ROWS]Break_Row
break_count: int
register_rows: [REGISTER_ROWS]Register_Row
register_count: int
registers_shown: bool // The card of the variables shows the registers of the chosen thread.
scratch_rows: [THREAD_ROWS]Thread_Row // The rows of an export whose rows the window reads again.
// The memory view: the place that the button memory took, and its rows.
memory_place: [PLACE_LIMIT]u8
memory_place_count: int
memory_rows: [MEMORY_ROWS]Memory_Row
memory_count: int

records_now, records_before: [2048]interface.Draw_Record
text_now, text_before: [32768]u8
drawing: interface.Window_Drawing
frame_table: ^interface.Draw_Table
frame_acts: Frame_Acts // The acts of the frame that draw builds now.

status_set :: proc "contextless" (failed: bool, parts: ..system.Part) {
	writer := system.Writer{buffer = status_text[:]}
	for part in parts {
		system.write_part(&writer, part)
	}
	status_count = len(system.written(&writer))
	status_failed = failed
}

// A status line kept across a read that can fail: a read again of the
// tables must not hide what the last act of the developer did.
Status_Kept :: struct {
	text:   [160]u8,
	count:  int,
	failed: bool,
}

status_keep :: proc "contextless" () -> (kept: Status_Kept) {
	copy(kept.text[:], status_text[:])
	kept.count, kept.failed = status_count, status_failed
	return
}

status_restore :: proc "contextless" (kept: ^Status_Kept) {
	copy(status_text[:], kept.text[:])
	status_count, status_failed = kept.count, kept.failed
}

// bytes_of gives the memory of a table of rows, for a call.
bytes_of :: proc "contextless" (rows: []$T) -> []u8 {
	return ([^]u8)(raw_data(rows))[:len(rows) * size_of(T)]
}

// call runs one export of the service, and copies the rows of its result.
// It gives the count of the rows. false: the service refused, or the call
// did not come back; the status line says which, with the code that the
// export gave.
call :: proc "contextless" (export: Export, arguments: []isolated.Argument, rows: []u8) -> (count: int, ok: bool) {
	if !ready {
		return 0, false
	}
	error: errors.Error_Record
	result, status := system.call_isolated(&connection, service_file, export_indexes[export], arguments, &error, false, rows)
	if status != .Ok {
		if status == .Failed || status == .Failed_With_Wrong_Details {
			status_set(true, "debugger.", export_names[export], " failed with the code ", result, ": the console gives its sentence")
		} else {
			status_set(true, "the call of debugger.", export_names[export], " did not come back from the service")
		}
		return 0, false
	}
	return int(result), true
}

thread_number :: proc "contextless" () -> i64 {
	if thread_chosen < thread_count {
		return thread_rows[thread_chosen].thread
	}
	return -1
}

// thread_can_be_read says if the chosen thread is held or stopped: its
// stack, its variables and its source line exist only then.
thread_can_be_read :: proc "contextless" () -> bool {
	if thread_chosen >= thread_count {
		return false
	}
	state := system.name_of(thread_rows[thread_chosen].state[:])
	return state == "held" || state == "stopped"
}

// tables_read reads the threads again, then the stack, the variables and
// the source line of the chosen thread and frame, and the memory view. A
// thread that runs has none of the three first; the memory of a program
// is read with no held thread.
tables_read :: proc "contextless" () {
	frame_count, variable_count, source_count = 0, 0, 0
	if !attached {
		thread_count, break_count, register_count, memory_count = 0, 0, 0, 0
		return
	}
	// The stops since the last read: the service keeps them until a
	// caller takes them, and the rows of the threads show their result.
	call(.Events, nil, bytes_of(event_rows[:]))
	count, ok := call(.Threads, nil, bytes_of(thread_rows[:]))
	if !ok {
		thread_count = 0
		return
	}
	thread_count = min(count, THREAD_ROWS)
	thread_chosen = min(thread_chosen, max(thread_count - 1, 0))
	break_count, register_count = 0, 0
	if breaks, read := call(.Breaks, nil, bytes_of(break_rows[:])); read {
		break_count = min(breaks, BREAK_ROWS)
	}
	kept := status_keep()
	memory_read()
	status_restore(&kept)
	if !thread_can_be_read() {
		return
	}
	if registers_shown {
		of_thread := [1]isolated.Argument{{integer = u64(thread_number())}}
		if registers, read := call(.Registers, of_thread[:], bytes_of(register_rows[:])); read {
			register_count = min(registers, REGISTER_ROWS)
		}
	}
	thread := [1]isolated.Argument{{integer = u64(thread_number())}}
	if frames, read := call(.Stack, thread[:], bytes_of(frame_rows[:])); read {
		frame_count = min(frames, FRAME_ROWS)
	}
	frame_chosen = min(frame_chosen, max(frame_count - 1, 0))
	place := [2]isolated.Argument{{integer = u64(thread_number())}, {integer = u64(frame_chosen)}}
	// A frame with no debug object has no variable and no line: the two
	// exports fail, and the cards say that they have nothing.
	kept = status_keep()
	if variables, read := call(.Locals, place[:], bytes_of(variable_rows[:])); read {
		variable_count = min(variables, VARIABLE_ROWS)
	}
	place = {{integer = u64(thread_number())}, {integer = u64(frame_chosen)}}
	if lines, read := call(.Source, place[:], bytes_of(source_rows[:])); read {
		source_count = min(lines, SOURCE_ROWS)
	}
	status_restore(&kept)
}

// memory_read reads the rows of the memory view at its place. A view with
// no place reads nothing.
memory_read :: proc "contextless" () -> bool {
	memory_count = 0
	if !attached || memory_place_count == 0 {
		return false
	}
	place := string(memory_place[:memory_place_count])
	arguments := [2]isolated.Argument{{text = transmute([]u8)place}, {integer = MEMORY_BYTES}}
	count, ok := call(.Memory, arguments[:], bytes_of(memory_rows[:]))
	if !ok {
		return false
	}
	memory_count = clamp(count, 0, MEMORY_ROWS)
	return true
}

attach :: proc "contextless" () {
	if name_count == 0 {
		return
	}
	rows: [1]Attached
	arguments := [1]isolated.Argument{{text = name[:name_count]}}
	count, ok := call(.Attach, arguments[:], bytes_of(rows[:]))
	if !ok || count != 1 {
		return
	}
	attached, attached_row = true, rows[0]
	thread_chosen, frame_chosen = 0, 0
	place_count, memory_place_count = 0, 0
	status_set(false, "attached to ", system.name_of(attached_row.program[:]), ": ", attached_row.threads, " threads, ", attached_row.described, " of ", attached_row.modules, " modules with a debug object")
	system.log("debugger_window: attached to ", system.name_of(attached_row.program[:]))
	tables_read()
}

detach :: proc "contextless" () {
	rows: [1]Detached
	if _, ok := call(.Detach, nil, bytes_of(rows[:])); ok {
		status_set(false, "detached from ", system.name_of(rows[0].program[:]))
		system.log("debugger_window: detached from ", system.name_of(rows[0].program[:]))
	}
	attached = false
	memory_place_count = 0
	tables_read()
}

// act runs one export on the chosen thread, then reads the tables again.
act :: proc "contextless" (export: Export, words: string) {
	if thread_count == 0 {
		return
	}
	number := thread_number()
	arguments := [1]isolated.Argument{{integer = u64(number)}}
	count, ok := call(export, export == .Continue_All ? nil : arguments[:], bytes_of(scratch_rows[:]))
	if ok {
		pending: string = count > 0 && scratch_rows[0].pending != 0 ? ": it runs, and its stop comes later" : ""
		if export == .Continue_All {
			status_set(false, words)
			system.log("debugger_window: ", words)
		} else {
			status_set(false, words, " the thread ", number, pending)
			system.log("debugger_window: ", words, " the thread ", number, pending)
		}
	}
	tables_read()
}

// thread_choose chooses a thread by its place in the rows: a click on its
// row, as up and down do.
thread_choose :: proc "contextless" (index: int) {
	if index < 0 || index >= thread_count {
		return
	}
	thread_chosen, frame_chosen = index, 0
	tables_read()
	system.log("debugger_window: chose the thread ", thread_number())
}

// frame_choose chooses a frame of the chosen thread: a click on its row,
// or page up and page down. One line of the log: a reader knows which
// frame the cards show.
frame_choose :: proc "contextless" (index: int) {
	frame_chosen = clamp(index, 0, max(frame_count - 1, 0))
	tables_read()
	if frame_chosen < frame_count {
		system.log("debugger_window: the frame ", frame_rows[frame_chosen].frame, " of the thread ", thread_number(), ": ", system.name_of(frame_rows[frame_chosen].procedure[:]), ", ", u64(variable_count), " variables, ", u64(source_count), " source lines")
	}
}

// break_at_place puts a breakpoint at a debug place, as `break_at` takes
// it: a procedure name, or a file and a line. The service parses it; the
// window computes no address. It gives false when the service refused.
break_at_place :: proc "contextless" (place: string) -> bool {
	rows: [BREAK_ROWS]Break_Row
	arguments := [1]isolated.Argument{{text = transmute([]u8)place}}
	_, ok := call(.Break_At, arguments[:], bytes_of(rows[:]))
	if ok {
		status_set(false, "a breakpoint at ", place)
		system.log("debugger_window: a breakpoint at ", place)
	}
	tables_read()
	return ok
}

// break_at_line puts a breakpoint at a source line: the place is the path
// of its file and its line.
break_at_line :: proc "contextless" (file: string, line: i64) {
	buffer: [PLACE_LIMIT]u8
	place := system.format(buffer[:], file, ":", line)
	break_at_place(place)
}

// break_at_the_line puts a breakpoint at the source line of the chosen
// frame. A frame with no line has no such place.
break_at_the_line :: proc "contextless" () {
	if frame_chosen >= frame_count || frame_rows[frame_chosen].line == 0 {
		status_set(true, "the chosen frame has no source line: choose a frame with one (page up, page down)")
		return
	}
	break_at_line(system.name_of(frame_rows[frame_chosen].file[:]), frame_rows[frame_chosen].line)
}

// break_at_source_row puts a breakpoint at the line of a row of the source.
break_at_source_row :: proc "contextless" (index: int) {
	if index < 0 || index >= source_count || source_rows[index].line == 0 {
		return
	}
	break_at_line(system.name_of(source_rows[index].path[:]), source_rows[index].line)
}

// break_remove removes the breakpoint with a number.
break_remove :: proc "contextless" (number: i64) {
	rows: [BREAK_ROWS]Break_Row
	arguments := [1]isolated.Argument{{integer = u64(number)}}
	if _, ok := call(.Break_Remove, arguments[:], bytes_of(rows[:])); ok {
		status_set(false, "removed the breakpoint ", number)
		system.log("debugger_window: removed the breakpoint ", number)
	}
	tables_read()
}

// text_trimmed gives a text with no space at its start or at its end.
text_trimmed :: proc "contextless" (text: string) -> string {
	first, end := 0, len(text)
	for first < end && text[first] == ' ' {
		first += 1
	}
	for end > first && text[end - 1] == ' ' {
		end -= 1
	}
	return text[first:end]
}

// watch_place_and_length splits the text of a watch: a last word 1, 2, 4
// or 8, after a space, is the length of the watch. An address and a value
// path hold no space, so that word is never a part of the place.
watch_place_and_length :: proc "contextless" (text: string) -> (place: string, length: i64) {
	place, length = text, WATCH_LENGTH
	count := len(text)
	if count >= 3 && text[count - 2] == ' ' {
		switch text[count - 1] {
		case '1', '2', '4', '8':
			place, length = text_trimmed(text[:count - 2]), i64(text[count - 1] - '0')
		}
	}
	return
}

// place_typed gives the text of the debug place field, or says on the
// status line that it is empty.
place_typed :: proc "contextless" (what: string) -> (place: string, typed: bool) {
	place = text_trimmed(string(place_text[:place_count]))
	if place == "" {
		status_set(true, "type a debug place first: ", what)
		return "", false
	}
	return place, true
}

// place_break_at puts a breakpoint at the debug place. A breakpoint that
// the service took empties the field: its text is in the card of the
// breakpoints now.
place_break_at :: proc "contextless" () {
	place, typed := place_typed("a procedure, or a file and a line")
	if typed && break_at_place(place) {
		place_count = 0
	}
}

// place_watch puts a watch at the debug place.
place_watch :: proc "contextless" () {
	text, typed := place_typed("an address or a global")
	if !typed {
		return
	}
	place, length := watch_place_and_length(text)
	rows: [BREAK_ROWS]Break_Row
	arguments := [2]isolated.Argument{{text = transmute([]u8)place}, {integer = u64(length)}}
	if _, ok := call(.Watch, arguments[:], bytes_of(rows[:])); ok {
		status_set(false, "a watch of ", length, " bytes at ", place)
		system.log("debugger_window: a watch of ", length, " bytes at ", place)
		place_count = 0
	}
	tables_read()
}

// place_memory shows the memory at the debug place. The field keeps its
// text: the developer reads near it with one edit.
place_memory :: proc "contextless" () {
	place, typed := place_typed("an address or a global")
	if !typed {
		return
	}
	memory_place_count = copy(memory_place[:], place)
	if memory_read() {
		shown := string(memory_place[:memory_place_count])
		status_set(false, "the memory at ", shown, ": ", u64(memory_count), " rows of 16 bytes")
		system.log("debugger_window: the memory at ", shown, ": ", u64(memory_count), " rows of 16 bytes")
	}
}

// key_act runs a key that no element of the frame took.
key_act :: proc "contextless" (press: interface.Key_Press) {
	if press.code == display.KEY_ESCAPE {
		// The letters act again: no element has the focus.
		drawing.state.focus = 0
		return
	}
	if !attached {
		return
	}
	switch {
	case press.code == display.KEY_UP:
		thread_chosen = max(thread_chosen - 1, 0)
		frame_chosen = 0
		tables_read()
	case press.code == display.KEY_DOWN:
		thread_chosen = min(thread_chosen + 1, max(thread_count - 1, 0))
		frame_chosen = 0
		tables_read()
	case press.code == display.KEY_PAGE_UP:
		frame_choose(frame_chosen - 1)
	case press.code == display.KEY_PAGE_DOWN:
		frame_choose(frame_chosen + 1)
	case press.character == 'h':
		act(.Hold, "held")
	case press.character == 'r':
		act(.Release, "let run")
	case press.character == 'c':
		act(.Continue_All, "let each thread run")
	case press.character == 's':
		act(.Step, "one instruction of")
	case press.character == 'l':
		act(.Step_Line, "one line of")
	case press.character == 'o':
		act(.Step_Over, "one line, over each call, of")
	case press.character == 'd':
		detach()
	case press.character == 'b':
		break_at_the_line()
	case press.character >= '0' && press.character < '0' + BREAK_ROWS:
		break_remove(i64(press.character - '0'))
	case press.character == 'g':
		registers_shown = !registers_shown
		tables_read()
		system.log("debugger_window: the card of the variables shows ", registers_shown ? "the registers" : "the variables", ": ", u64(registers_shown ? register_count : variable_count), " rows")
	}
}

// acts_run runs the act of the element of a frame, then the keys that no
// element took, in their order. It gives true when there was one.
acts_run :: proc "contextless" (acts: ^Frame_Acts) -> bool {
	switch acts.act {
	case .None:
	case .Attach:
		attach()
	case .Break_At_Place:
		place_break_at()
	case .Watch_Place:
		place_watch()
	case .Memory_Place:
		place_memory()
	case .Choose_Thread:
		thread_choose(acts.index)
	case .Choose_Frame:
		frame_choose(acts.index)
	case .Break_At_Source_Row:
		break_at_source_row(acts.index)
	case .Remove_Breakpoint:
		break_remove(i64(acts.index))
	}
	for press in acts.keys[:acts.key_count] {
		key_act(press)
	}
	return acts.act != .None || acts.key_count > 0
}

write :: proc "contextless" (area: interface.Area, x, y: int, characters: string, color: graphics.Color) -> int {
	return interface.draw_text(frame_table, area.x + x, area.y + y, characters, color) - area.x
}

// lines draws a text in a box of an area, on the lines that it needs, and
// gives the y after it.
lines :: proc "contextless" (area: interface.Area, x, y, width: int, characters: string, color: graphics.Color) -> int {
	count := interface.draw_text_wrapped(frame_table, area.x + x, area.y + y, width, characters, color)
	return y + max(count, 1) * LINE
}

// rest_line says how many rows a card does not show.
rest_line :: proc "contextless" (area: interface.Area, y: int, shown, total: int, what: string) {
	if shown < total {
		buffer: [64]u8
		write(area, 0, y, system.format(buffer[:], "and ", u64(total - shown), " more ", what), graphics.colors.dim)
	}
}

// row_element makes a row of a card an element of the frame: a press and a
// release on it activate it, with the focus, Tab and Enter of each other
// element. The row is lit while the pointer is over it, under its text.
// The name of the row and its number are its element name: "frame 0".
row_element :: proc "contextless" (frame: ^interface.Frame, element: interface.Element_Identity, area: interface.Area, chosen: bool, row_name: string, row_number: u64) -> bool {
	result := interface.element_interact(frame, element, area, .Button)
	name_buffer: [interface.ELEMENT_NAME_CAPACITY]u8
	interface.element_name(frame, area, system.format(name_buffer[:], row_name, " ", row_number))
	switch {
	case chosen:
		interface.draw_rectangle(frame_table, area.x, area.y, area.width, area.height, graphics.colors.chosen)
	case result.under_pointer || result.focused:
		interface.draw_rectangle(frame_table, area.x, area.y, area.width, area.height, graphics.colors.track)
	}
	return result.activated
}

// act_ask records the act of an element for the end of the frame.
act_ask :: proc "contextless" (act: Element_Act, index: int = 0) {
	frame_acts.act, frame_acts.index = act, index
}

state_color :: proc "contextless" (state: string) -> graphics.Color {
	switch state {
	case "stopped":
		return graphics.colors.failed
	case "held":
		return graphics.colors.boot_program
	}
	return graphics.colors.program
}

draw_program :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {MARGIN, MARGIN, LEFT_WIDTH, PROGRAM_HEIGHT}, "PROGRAM", "debugger.attach", graphics.colors.program)
	y := 0
	if !attached {
		// With no program, the name field is the one element: it keeps the
		// focus, so the keys type the name.
		name_field := interface.identity("debugger_window name field")
		frame.state.focus = name_field
		if interface.text_input(frame, {inside.x, inside.y, inside.width, ROW_HEIGHT}, name_field, name[:], &name_count, "the name of a program").activated {
			act_ask(.Attach)
		}
		y = lines(inside, 0, ROW_HEIGHT + 8, inside.width, ready ? "type the name of a program that runs, then Enter" : "the service debugger is not reachable: this window can attach to nothing", graphics.colors.dim)
	} else {
		x := write(inside, 0, y, "attached to ", graphics.colors.dim)
		write(inside, x, y, system.name_of(attached_row.program[:]), graphics.colors.text)
		place_field := interface.identity("debugger_window debug place field")
		if interface.text_input(frame, {inside.x, inside.y + PLACE_FIELD_Y, inside.width, ROW_HEIGHT}, place_field, place_text[:], &place_count, "the debug place").activated {
			act_ask(.Break_At_Place)
		}
		labels := [3]string{"break at", "watch", "memory"}
		acts := [3]Element_Act{.Break_At_Place, .Watch_Place, .Memory_Place}
		for label, index in labels {
			area := interface.Area{inside.x + index * (BUTTON_WIDTH + BUTTON_GAP), inside.y + BUTTONS_Y, BUTTON_WIDTH, ROW_HEIGHT}
			if interface.button(frame, area, interface.identity_in(place_field, label), label).activated {
				act_ask(acts[index])
			}
		}
		y = lines(inside, 0, BUTTONS_Y + ROW_HEIGHT + 8, inside.width, "break at: a procedure, or file:line. watch, memory: an address or a global; a last word 1, 2, 4 or 8 is the bytes of a watch", graphics.colors.dim)
	}
	if status_count > 0 {
		y = lines(inside, 0, y + 4, inside.width, string(status_text[:status_count]), status_failed ? graphics.colors.failed : graphics.colors.dim)
	}
	if !attached {
		return
	}
	y += 8
	if y + 2 * LINE > inside.height {
		return
	}
	write(inside, 0, y, "THREADS", graphics.colors.dim)
	y += LINE + 4
	shown := 0
	thread_row := interface.identity("debugger_window thread row")
	for &row, index in thread_rows[:thread_count] {
		buffer: [200]u8
		state := system.name_of(row.state[:])
		procedure := system.name_of(row.procedure[:])
		text := row.line != 0 ? system.format(buffer[:], procedure, ":", row.line) : procedure != "" ? system.format(buffer[:], procedure) : system.format(buffer[:], system.name_of(row.instruction[:]))
		text_x := 96
		height := max(interface.text_wrapped_line_count(frame_table, {}, text, inside.width - text_x), 1) * LINE
		if y + height > inside.height - LINE {
			break
		}
		chosen := index == thread_chosen
		if row_element(frame, interface.identity_with(thread_row, index), {inside.x - 4, inside.y + y - 2, inside.width + 8, height + 2}, chosen, "thread", u64(max(row.thread, 0))) {
			act_ask(.Choose_Thread, index)
		}
		number: [24]u8
		write(inside, 0, y, system.format(number[:], row.thread), chosen ? graphics.COLOR_WHITE : graphics.colors.text)
		write(inside, 24, y, state, chosen ? graphics.COLOR_WHITE : state_color(state))
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, chosen ? graphics.COLOR_WHITE : graphics.colors.text)
		y += height + 2
		shown += 1
	}
	rest_line(inside, y, shown, thread_count, "threads")
}

// draw_breakpoints draws the breakpoints and the watches: the number that
// removes each one, its kind, the bytes of a watch and the place that named
// it. A click on a row removes it.
draw_breakpoints :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {MARGIN, BREAKS_Y, LEFT_WIDTH, BREAKS_HEIGHT}, "BREAKPOINTS", "debugger.breaks", graphics.colors.boot_program)
	if !attached {
		lines(inside, 0, 0, inside.width, "no program is attached", graphics.colors.dim)
		return
	}
	if break_count == 0 {
		lines(inside, 0, 0, inside.width, "none: b, a click on a source line, or break at and watch with a debug place", graphics.colors.dim)
		return
	}
	y := 0
	shown := 0
	break_row := interface.identity("debugger_window breakpoint row")
	for &row in break_rows[:break_count] {
		buffer: [220]u8
		kind := system.name_of(row.kind[:])
		place := system.name_of(row.place[:])
		text := row.length != 0 ? system.format(buffer[:], kind, " ", u64(row.length), " bytes ", place) : system.format(buffer[:], kind, " ", place)
		text_x := 24
		height := max(interface.text_wrapped_line_count(frame_table, {}, text, inside.width - text_x), 1) * LINE
		if y + height > inside.height - LINE {
			break
		}
		if row_element(frame, interface.identity_with(break_row, int(row.number)), {inside.x - 4, inside.y + y - 2, inside.width + 8, height + 2}, false, "breakpoint", u64(max(row.number, 0))) {
			act_ask(.Remove_Breakpoint, int(row.number))
		}
		number: [24]u8
		write(inside, 0, y, system.format(number[:], row.number), graphics.colors.boot_program)
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, graphics.colors.text)
		y += height + 2
		shown += 1
	}
	rest_line(inside, y, shown, break_count, "breakpoints")
}

draw_source :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {RIGHT_X, MARGIN, RIGHT_WIDTH, SOURCE_HEIGHT}, "SOURCE", "debugger.source", graphics.colors.resource)
	if source_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : thread_can_be_read() ? "the frame has no source line: its module has no debug object, or the service does not have the file" : "the thread runs: hold it (h) to read its line", graphics.colors.dim)
		return
	}
	y := lines(inside, 0, 0, inside.width, system.name_of(source_rows[0].path[:]), graphics.colors.dim) + 4
	shown := 0
	source_row := interface.identity("debugger_window source row")
	for &row, index in source_rows[:source_count] {
		text := system.name_of(row.text[:])
		text_x := 80
		height := max(interface.text_wrapped_line_count(frame_table, {}, text, inside.width - text_x), 1) * LINE
		if y + height > inside.height - LINE {
			break
		}
		// A row with a line takes a click: a breakpoint at that line.
		if row.line != 0 && row_element(frame, interface.identity_with(source_row, index), {inside.x - 4, inside.y + y - 2, inside.width + 8, height + 2}, false, "source row", u64(index)) {
			act_ask(.Break_At_Source_Row, index)
		}
		marked := system.name_of(row.mark[:]) != ""
		number: [24]u8
		write(inside, 0, y, system.name_of(row.mark[:]), graphics.colors.boot_program)
		write(inside, 24, y, system.format(number[:], row.line), graphics.colors.dim)
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, marked ? graphics.colors.text : graphics.colors.dim)
		y += height + 2
		shown += 1
	}
	rest_line(inside, y, shown, source_count, "lines")
}

// draw_memory draws the memory view: for each row its address with no
// leading zero, its 16 bytes and their printable characters, each column at
// a fixed place in the font of the cells.
draw_memory :: proc "contextless" (frame: ^interface.Frame) {
	count_buffer: [32]u8
	count := memory_place_count > 0 && memory_count > 0 ? system.format(count_buffer[:], u64(memory_count), " rows") : ""
	inside := interface.card(frame, {RIGHT_X, MEMORY_Y, RIGHT_WIDTH, MEMORY_HEIGHT}, "MEMORY", "debugger.memory", graphics.colors.memory, count)
	if !attached {
		lines(inside, 0, 0, inside.width, "no program is attached", graphics.colors.dim)
		return
	}
	if memory_place_count == 0 {
		lines(inside, 0, 0, inside.width, "type an address or a global in the debug place field, then memory", graphics.colors.dim)
		return
	}
	if memory_count == 0 {
		buffer: [PLACE_LIMIT + 64]u8
		lines(inside, 0, 0, inside.width, system.format(buffer[:], "the service read no byte at ", string(memory_place[:memory_place_count])), graphics.colors.dim)
		return
	}
	shown := 0
	for &row in memory_rows[:memory_count] {
		address := value_short(system.name_of(row.address[:]))
		// The kernel reads only below the end of the user half; a longer
		// address would pass the column of the bytes.
		if len(address) > MEMORY_ADDRESS_DIGITS {
			continue
		}
		y := shown * LINE
		write(inside, 0, y, address, graphics.colors.dim)
		write(inside, MEMORY_BYTES_X, y, system.name_of(row.bytes[:]), graphics.colors.text)
		write(inside, MEMORY_TEXT_X, y, system.name_of(row.text[:]), graphics.colors.memory)
		shown += 1
	}
	rest_line(inside, shown * LINE, shown, memory_count, "rows")
}

draw_stack :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {RIGHT_X, LOW_Y, STACK_WIDTH, LOW_HEIGHT}, "STACK", "debugger.stack", graphics.colors.kernel)
	if frame_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : "the thread runs: it has no stack to read", graphics.colors.dim)
		return
	}
	y := 0
	shown := 0
	frame_row := interface.identity("debugger_window frame row")
	for &row, index in frame_rows[:frame_count] {
		buffer: [200]u8
		procedure := system.name_of(row.procedure[:])
		text := procedure == "" ? system.format(buffer[:], system.name_of(row.module[:]), " + ", row.offset) : row.line != 0 ? system.format(buffer[:], procedure, ":", row.line) : system.format(buffer[:], procedure)
		text_x := 24
		height := max(interface.text_wrapped_line_count(frame_table, {}, text, inside.width - text_x), 1) * LINE
		if y + height > inside.height - LINE {
			break
		}
		chosen := index == frame_chosen
		if row_element(frame, interface.identity_with(frame_row, index), {inside.x - 4, inside.y + y - 2, inside.width + 8, height + 2}, chosen, "frame", u64(index)) {
			act_ask(.Choose_Frame, index)
		}
		number: [24]u8
		write(inside, 0, y, system.format(number[:], row.frame), chosen ? graphics.COLOR_WHITE : graphics.colors.dim)
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, chosen ? graphics.COLOR_WHITE : graphics.colors.text)
		y += height + 2
		shown += 1
	}
	rest_line(inside, y, shown, frame_count, "frames")
}

draw_registers :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {VARIABLES_X, LOW_Y, VARIABLES_WIDTH, LOW_HEIGHT}, "REGISTERS", "debugger.registers", graphics.colors.machine)
	if register_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : "the thread runs: hold it (h) to read its registers", graphics.colors.dim)
		return
	}
	// A column holds a name and a value of up to 16 digits after its "0x".
	// A second column only when the card is wide enough for two: else the
	// values of the first column run into the names of the second.
	REGISTER_COLUMN_WIDTH :: 72 + 16 * 8 + 8
	columns := inside.width >= 2 * REGISTER_COLUMN_WIDTH ? 2 : 1
	column_width := inside.width / columns
	rows_of_a_column := (inside.height - LINE) / LINE
	shown := 0
	for &row, index in register_rows[:register_count] {
		column, line := index / max(rows_of_a_column, 1), index % max(rows_of_a_column, 1)
		if column >= columns {
			break
		}
		write(inside, column * column_width, line * LINE, system.name_of(row.name[:]), graphics.colors.dim)
		// The value without its leading zeros keeps its column narrow. Its
		// "0x" stays, dim: a reader knows that the digits are hexadecimal.
		write(inside, column * column_width + 56, line * LINE, "0x", graphics.colors.dim)
		write(inside, column * column_width + 72, line * LINE, value_short(system.name_of(row.value[:])), graphics.colors.text)
		shown += 1
	}
	rest_line(inside, inside.height - LINE, shown, register_count, "registers")
}

// value_short gives a hexadecimal value with no zero before its first
// digit that counts, and no "0x": "0x0000000000403ea2" is "403ea2".
value_short :: proc "contextless" (value: string) -> string {
	if len(value) < 3 || value[:2] != "0x" {
		return value
	}
	first := 2
	for first < len(value) - 1 && value[first] == '0' {
		first += 1
	}
	return value[first:]
}

draw_variables :: proc "contextless" (frame: ^interface.Frame) {
	if registers_shown {
		draw_registers(frame)
		return
	}
	inside := interface.card(frame, {VARIABLES_X, LOW_Y, VARIABLES_WIDTH, LOW_HEIGHT}, "VARIABLES", "debugger.locals", graphics.colors.machine)
	if variable_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : thread_can_be_read() ? "the frame has no variable that the debug object describes" : "the thread runs: it has no variable to read", graphics.colors.dim)
		return
	}
	y := 0
	shown := 0
	for &row in variable_rows[:variable_count] {
		buffer: [200]u8
		label := system.format(buffer[:], system.name_of(row.name[:]), ": ", system.name_of(row.type[:]))
		value := system.name_of(row.value[:])
		height := (max(interface.text_wrapped_line_count(frame_table, {}, label, inside.width), 1) + max(interface.text_wrapped_line_count(frame_table, {}, value, inside.width - 16), 1)) * LINE
		if y + height > inside.height - LINE {
			break
		}
		y = lines(inside, 0, y, inside.width, label, graphics.colors.dim)
		y = lines(inside, 16, y, inside.width - 16, value, graphics.colors.text) + 2
		shown += 1
	}
	rest_line(inside, y, shown, variable_count, "variables")
}

// draw builds one frame from the input of the window, and gives what its
// elements asked and the keys that no element took.
draw :: proc "contextless" (window: ^display.Window) -> Frame_Acts {
	frame_acts = {}
	frame := interface.window_frame_begin(&drawing, window)
	frame_table = frame.table
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	// The keys of the open list of the action bar, and a press on it, go
	// to the bar before any element of the window.
	interface.action_bar_input_take(&frame, &bar)
	draw_program(&frame)
	draw_breakpoints(&frame)
	draw_source(&frame)
	draw_memory(&frame)
	draw_stack(&frame)
	draw_variables(&frame)
	// The bar comes last: its list opens over the cards.
	bar_area := interface.Area{0, HEIGHT - KEYS_HEIGHT, WIDTH, KEYS_HEIGHT}
	bar_result := interface.action_bar(&frame, bar_area, attached ? attached_items[:] : detached_items[:], &bar)
	// The input is cleared at the end of the frame: the keys that no
	// element took are kept first.
	for press in frame.input.keys[:frame.input.key_count] {
		if !press.taken && frame_acts.key_count < len(frame_acts.keys) {
			frame_acts.keys[frame_acts.key_count] = press
			frame_acts.key_count += 1
		}
	}
	interface.window_frame_end(&drawing, &frame, window)
	if bar_result.ran {
		// A press on an item acts as its key. With a program attached the
		// letters are acts, so the debug place field gives up the focus:
		// else `h` would type in the field and not hold the thread. With
		// none, the name field keeps it, and Enter attaches.
		if attached {
			drawing.state.focus = 0
		}
		frame_acts.bar_key_given = interface.input_key_add(&drawing.input, bar_result.run)
	}
	return frame_acts
}

// The frames that one event can build: the frame of the event, the frame
// that runs the key of an item of the action bar, and the frame that shows
// what an act changed.
FRAME_ROUNDS :: 3

// frame_build draws a frame, runs what it asked, and draws again while an
// act changed the rows or the action bar gave a key to the next frame.
frame_build :: proc "contextless" (window: ^display.Window) {
	acts := draw(window)
	for _ in 1 ..< FRAME_ROUNDS {
		ran := acts_run(&acts)
		if !ran && !acts.bar_key_given {
			return
		}
		acts = draw(window)
	}
}

// service_reach opens the connection to the service, finds each export
// that the window calls, and compares the size of each record of its rows
// with the description of the service. It gives the reason of a failure.
service_reach :: proc "contextless" (ctx: ^system.Context) -> (problem: string) {
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	service_file = system.image_find(image, "debugger")
	if service_file == nil {
		return "the boot image has no module debugger"
	}
	for export in Export {
		index := module.export_find(service_file, export_names[export])
		function, described := module.function(service_file, index)
		if index == 0 || !described {
			return "the service debugger has no export that this window calls"
		}
		record, has_record := module.record_type(service_file, function.result_detail)
		if !has_record || record.size != export_row_sizes[export] {
			return "a record of the service debugger has another size than in this window"
		}
		export_indexes[export] = index
	}
	if ctx.handles[system.GRANT_ROOT] == 0 {
		return "this program has no ring to the root service"
	}
	status: system.Status
	requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT])
	if status != .Ok {
		return "the ring to the root service does not open"
	}
	has_requests = true
	connection, status = system.service_connection(&requests, 1, "debugger")
	if status != .Ok {
		return "the root service gave no connection to the service debugger"
	}
	connected = true
	return ""
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "debugger_window")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	if problem := service_reach(ctx); problem != "" {
		status_set(true, problem)
		system.log("debugger_window: ", problem)
	} else {
		ready = true
		system.log("debugger_window: ok, connected to the service debugger; ", u64(len(Export)), " exports, each record with the size of its description")
	}
	for {
		frame_build(&window)
		next := system.time() + REFRESH_MILLISECONDS
		for {
			wait: system.Wait
			display.wait_events(&wait, &window)
			now := system.wait_end(&wait, next)
			if interface.window_events(&drawing, &window) {
				frame_build(&window)
			}
			if now >= next {
				break
			}
		}
		// A thread that ran can be stopped now: the rows are read again.
		if attached {
			tables_read()
		}
	}
}
