// The window of the debugger: the threads, the stack, the variables and
// the source lines of a program, with no line to type (docs/TOOLS.md, "The
// window of the debugger").
//
// **What it is for.** The service `debugger` holds the debug access to one
// program and serves its exports. The console reaches them by commands.
// This program reaches the same exports through a connection of its own,
// and shows their rows in one window: a developer follows a thread with a
// key for each step.
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
// **What a reader sees.** Four cards: the program and its threads, the
// source lines of the chosen frame, the stack of the chosen thread, the
// variables of the chosen frame. The line at the bottom names the keys.
//
// **Keys**, with a program attached:
//
// - up, down: the thread. page up, page down: the frame.
// - h: hold the thread. r: let it run. c: let each thread run.
// - s: one instruction. l: one line. o: one line, over each call.
// - b: a breakpoint at the source line of the chosen frame. 0 to 3: remove
//   the breakpoint with that number.
// - g: the registers of the chosen thread, or its variables again.
// - d: detach.
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
MARGIN :: 8
LEFT_WIDTH :: 328
RIGHT_X :: MARGIN + LEFT_WIDTH + MARGIN
RIGHT_WIDTH :: WIDTH - RIGHT_X - MARGIN
KEYS_HEIGHT :: 3 * LINE + 8
CARDS_HEIGHT :: HEIGHT - 2 * MARGIN - KEYS_HEIGHT
SOURCE_HEIGHT :: 264
LOW_Y :: MARGIN + SOURCE_HEIGHT + MARGIN
LOW_HEIGHT :: CARDS_HEIGHT - SOURCE_HEIGHT - MARGIN
STACK_WIDTH :: 296
VARIABLES_X :: RIGHT_X + STACK_WIDTH + MARGIN
VARIABLES_WIDTH :: WIDTH - VARIABLES_X - MARGIN

REFRESH_MILLISECONDS :: 500 // The threads are read again: a stop of a thread that ran shows then.
NAME_LIMIT :: 31 // The bytes of the name of a program, as the service takes it.
THREAD_ROWS :: 32
FRAME_ROWS :: 16
VARIABLE_ROWS :: 16
SOURCE_ROWS :: 16
EVENT_ROWS :: 8
BREAK_ROWS :: 4 // The breakpoints of a program: the debug address registers of a thread.
REGISTER_ROWS :: 24

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
	Breaks,
	Break_Remove,
	Registers,
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
	.Breaks       = "breaks",
	.Break_Remove = "break_remove",
	.Registers    = "registers",
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
	.Breaks       = size_of(Break_Row),
	.Break_Remove = size_of(Break_Row),
	.Registers    = size_of(Register_Row),
}

image: []u8
service_file: []u8 // The file of the service `debugger` in the boot image: the description of its exports.
export_indexes: [Export]u32
requests: ring.Ring
has_requests: bool
connection: system.Call_Connection
connected: bool
ready: bool // The connection is open and each record has the size of its description.

name: [NAME_LIMIT]u8 // The name that the keys type.
name_count: int
attached: bool
attached_row: Attached
// The last thing that the window did, in words, and whether it failed.
status_text: [160]u8
status_count: int
status_failed: bool

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

records_now, records_before: [2048]interface.Draw_Record
text_now, text_before: [32768]u8
drawing: interface.Window_Drawing
frame_table: ^interface.Draw_Table

status_set :: proc "contextless" (failed: bool, parts: ..system.Part) {
	writer := system.Writer{buffer = status_text[:]}
	for part in parts {
		system.write_part(&writer, part)
	}
	status_count = len(system.written(&writer))
	status_failed = failed
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
// the source line of the chosen thread and frame. A thread that runs has
// none of the three.
tables_read :: proc "contextless" () {
	frame_count, variable_count, source_count = 0, 0, 0
	if !attached {
		thread_count = 0
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
	thread_count = count
	thread_chosen = min(thread_chosen, max(thread_count - 1, 0))
	break_count, register_count = 0, 0
	if breaks, read := call(.Breaks, nil, bytes_of(break_rows[:])); read {
		break_count = breaks
	}
	if !thread_can_be_read() {
		return
	}
	if registers_shown {
		of_thread := [1]isolated.Argument{{integer = u64(thread_number())}}
		if registers, read := call(.Registers, of_thread[:], bytes_of(register_rows[:])); read {
			register_count = registers
		}
	}
	thread := [1]isolated.Argument{{integer = u64(thread_number())}}
	if frames, read := call(.Stack, thread[:], bytes_of(frame_rows[:])); read {
		frame_count = frames
	}
	frame_chosen = min(frame_chosen, max(frame_count - 1, 0))
	place := [2]isolated.Argument{{integer = u64(thread_number())}, {integer = u64(frame_chosen)}}
	// A frame with no debug object has no variable and no line: the two
	// exports fail, and the cards say that they have nothing.
	failed, count_before := status_failed, status_count
	text_before: [160]u8
	copy(text_before[:], status_text[:])
	if variables, read := call(.Locals, place[:], bytes_of(variable_rows[:])); read {
		variable_count = variables
	}
	place = {{integer = u64(thread_number())}, {integer = u64(frame_chosen)}}
	if lines, read := call(.Source, place[:], bytes_of(source_rows[:])); read {
		source_count = lines
	}
	status_failed, status_count = failed, count_before
	copy(status_text[:], text_before[:])
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

// break_at_the_line puts a breakpoint at the source line of the chosen
// frame: the place is the path of its file and its line, as `break_at`
// takes it. A frame with no line has no such place.
break_at_the_line :: proc "contextless" () {
	if frame_chosen >= frame_count || frame_rows[frame_chosen].line == 0 {
		status_set(true, "the chosen frame has no source line: choose a frame with one (page up, page down)")
		return
	}
	buffer: [128]u8
	place := system.format(buffer[:], system.name_of(frame_rows[frame_chosen].file[:]), ":", frame_rows[frame_chosen].line)
	rows: [BREAK_ROWS]Break_Row
	arguments := [1]isolated.Argument{{text = transmute([]u8)place}}
	if _, ok := call(.Break_At, arguments[:], bytes_of(rows[:])); ok {
		status_set(false, "a breakpoint at ", place)
		system.log("debugger_window: a breakpoint at ", place)
	}
	tables_read()
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

key :: proc "contextless" (event: display.Event) {
	if !attached {
		switch {
		case event.code == display.KEY_ENTER:
			attach()
		case event.code == display.KEY_BACKSPACE:
			name_count = max(name_count - 1, 0)
		case event.character >= 'a' && event.character <= 'z' || event.character == '_' || event.character >= '0' && event.character <= '9':
			if name_count < NAME_LIMIT {
				name[name_count] = event.character
				name_count += 1
			}
		}
		return
	}
	switch {
	case event.code == display.KEY_UP:
		thread_chosen = max(thread_chosen - 1, 0)
		frame_chosen = 0
		tables_read()
	case event.code == display.KEY_DOWN:
		thread_chosen = min(thread_chosen + 1, max(thread_count - 1, 0))
		frame_chosen = 0
		tables_read()
	case event.code == display.KEY_PAGE_UP || event.code == display.KEY_PAGE_DOWN:
		frame_chosen = event.code == display.KEY_PAGE_UP ? max(frame_chosen - 1, 0) : min(frame_chosen + 1, max(frame_count - 1, 0))
		tables_read()
		// One line of the log: a reader knows which frame the cards show.
		if frame_chosen < frame_count {
			system.log("debugger_window: the frame ", frame_rows[frame_chosen].frame, " of the thread ", thread_number(), ": ", system.name_of(frame_rows[frame_chosen].procedure[:]), ", ", u64(variable_count), " variables, ", u64(source_count), " source lines")
		}
	case event.character == 'h':
		act(.Hold, "held")
	case event.character == 'r':
		act(.Release, "let run")
	case event.character == 'c':
		act(.Continue_All, "let each thread run")
	case event.character == 's':
		act(.Step, "one instruction of")
	case event.character == 'l':
		act(.Step_Line, "one line of")
	case event.character == 'o':
		act(.Step_Over, "one line, over each call, of")
	case event.character == 'd':
		detach()
	case event.character == 'b':
		break_at_the_line()
	case event.character >= '0' && event.character < '0' + BREAK_ROWS:
		break_remove(i64(event.character - '0'))
	case event.character == 'g':
		registers_shown = !registers_shown
		tables_read()
		system.log("debugger_window: the card of the variables shows ", registers_shown ? "the registers" : "the variables", ": ", u64(registers_shown ? register_count : variable_count), " rows")
	}
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
		write(area, 0, y, system.format(buffer[:], "and ", u64(total - shown), " more ", what), graphics.COLOR_DIM)
	}
}

state_color :: proc "contextless" (state: string) -> graphics.Color {
	switch state {
	case "stopped":
		return graphics.COLOR_FAILED
	case "held":
		return graphics.COLOR_BOOT_PROGRAM
	}
	return graphics.COLOR_PROGRAM
}

draw_program :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {MARGIN, MARGIN, LEFT_WIDTH, CARDS_HEIGHT}, "PROGRAM", "debugger.attach", graphics.COLOR_PROGRAM)
	y := 0
	if !attached {
		x := write(inside, 0, y, "name ", graphics.COLOR_DIM)
		x = write(inside, x, y, string(name[:name_count]), graphics.COLOR_TEXT)
		interface.draw_rectangle(frame_table, inside.x + x, inside.y + y, 8, 16, graphics.COLOR_TRACK)
		y += LINE + 4
		y = lines(inside, 0, y, inside.width, ready ? "type the name of a program that runs, then Enter" : "the service debugger is not reachable: this window can attach to nothing", graphics.COLOR_DIM)
	} else {
		x := write(inside, 0, y, "attached to ", graphics.COLOR_DIM)
		write(inside, x, y, system.name_of(attached_row.program[:]), graphics.COLOR_TEXT)
		y += LINE + 4
	}
	if status_count > 0 {
		y = lines(inside, 0, y + 4, inside.width, string(status_text[:status_count]), status_failed ? graphics.COLOR_FAILED : graphics.COLOR_DIM)
	}
	if !attached {
		return
	}
	y += 8
	write(inside, 0, y, "THREADS", graphics.COLOR_DIM)
	y += LINE + 4
	shown := 0
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
		if index == thread_chosen {
			interface.draw_rectangle(frame_table, inside.x - 4, inside.y + y - 2, inside.width + 8, height + 2, graphics.COLOR_CHOSEN)
		}
		number: [24]u8
		write(inside, 0, y, system.format(number[:], row.thread), index == thread_chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		write(inside, 24, y, state, index == thread_chosen ? graphics.COLOR_WHITE : state_color(state))
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, index == thread_chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		y += height + 2
		shown += 1
	}
	rest_line(inside, y, shown, thread_count, "threads")
	if shown < thread_count {
		y += LINE
	}
	// The breakpoints, under the threads: the number that removes each one,
	// its kind and the place that named it.
	y += 8
	if y + 2 * LINE > inside.height {
		return
	}
	write(inside, 0, y, "BREAKPOINTS", graphics.COLOR_DIM)
	y += LINE + 4
	if break_count == 0 {
		lines(inside, 0, y, inside.width, "none: b puts one at the line of the chosen frame", graphics.COLOR_DIM)
		return
	}
	breaks_shown := 0
	for &row in break_rows[:break_count] {
		buffer: [200]u8
		text := system.format(buffer[:], system.name_of(row.kind[:]), " ", system.name_of(row.place[:]))
		text_x := 24
		height := max(interface.text_wrapped_line_count(frame_table, {}, text, inside.width - text_x), 1) * LINE
		if y + height > inside.height - LINE {
			break
		}
		number: [24]u8
		write(inside, 0, y, system.format(number[:], row.number), graphics.COLOR_BOOT_PROGRAM)
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, graphics.COLOR_TEXT)
		y += height + 2
		breaks_shown += 1
	}
	rest_line(inside, y, breaks_shown, break_count, "breakpoints")
}

draw_source :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {RIGHT_X, MARGIN, RIGHT_WIDTH, SOURCE_HEIGHT}, "SOURCE", "debugger.source", graphics.COLOR_MEMORY)
	if source_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : thread_can_be_read() ? "the frame has no source line: its module has no debug object, or the service does not have the file" : "the thread runs: hold it (h) to read its line", graphics.COLOR_DIM)
		return
	}
	y := lines(inside, 0, 0, inside.width, system.name_of(source_rows[0].path[:]), graphics.COLOR_DIM) + 4
	shown := 0
	for &row in source_rows[:source_count] {
		text := system.name_of(row.text[:])
		text_x := 80
		height := max(interface.text_wrapped_line_count(frame_table, {}, text, inside.width - text_x), 1) * LINE
		if y + height > inside.height - LINE {
			break
		}
		marked := system.name_of(row.mark[:]) != ""
		number: [24]u8
		write(inside, 0, y, system.name_of(row.mark[:]), graphics.COLOR_BOOT_PROGRAM)
		write(inside, 24, y, system.format(number[:], row.line), graphics.COLOR_DIM)
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, marked ? graphics.COLOR_TEXT : graphics.COLOR_DIM)
		y += height
		shown += 1
	}
	rest_line(inside, y, shown, source_count, "lines")
}

draw_stack :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {RIGHT_X, LOW_Y, STACK_WIDTH, LOW_HEIGHT}, "STACK", "debugger.stack", graphics.COLOR_KERNEL)
	if frame_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : "the thread runs: it has no stack to read", graphics.COLOR_DIM)
		return
	}
	y := 0
	shown := 0
	for &row, index in frame_rows[:frame_count] {
		buffer: [200]u8
		procedure := system.name_of(row.procedure[:])
		text := procedure == "" ? system.format(buffer[:], system.name_of(row.module[:]), " + ", row.offset) : row.line != 0 ? system.format(buffer[:], procedure, ":", row.line) : system.format(buffer[:], procedure)
		text_x := 24
		height := max(interface.text_wrapped_line_count(frame_table, {}, text, inside.width - text_x), 1) * LINE
		if y + height > inside.height - LINE {
			break
		}
		if index == frame_chosen {
			interface.draw_rectangle(frame_table, inside.x - 4, inside.y + y - 2, inside.width + 8, height + 2, graphics.COLOR_CHOSEN)
		}
		number: [24]u8
		write(inside, 0, y, system.format(number[:], row.frame), index == frame_chosen ? graphics.COLOR_WHITE : graphics.COLOR_DIM)
		interface.draw_text_wrapped(frame_table, inside.x + text_x, inside.y + y, inside.width - text_x, text, index == frame_chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		y += height + 2
		shown += 1
	}
	rest_line(inside, y, shown, frame_count, "frames")
}

draw_registers :: proc "contextless" (frame: ^interface.Frame) {
	inside := interface.card(frame, {VARIABLES_X, LOW_Y, VARIABLES_WIDTH, LOW_HEIGHT}, "REGISTERS", "debugger.registers", graphics.COLOR_MACHINE)
	if register_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : "the thread runs: hold it (h) to read its registers", graphics.COLOR_DIM)
		return
	}
	// Two columns of a name and a value: the registers are many, and each
	// value has 18 characters.
	column_width := inside.width / 2
	rows_of_a_column := (inside.height - LINE) / LINE
	shown := 0
	for &row, index in register_rows[:register_count] {
		column, line := index / max(rows_of_a_column, 1), index % max(rows_of_a_column, 1)
		if column > 1 {
			break
		}
		write(inside, column * column_width, line * LINE, system.name_of(row.name[:]), graphics.COLOR_DIM)
		// The value without its leading zeros keeps its column narrow. Its
		// "0x" stays, dim: a reader knows that the digits are hexadecimal.
		write(inside, column * column_width + 56, line * LINE, "0x", graphics.COLOR_DIM)
		write(inside, column * column_width + 72, line * LINE, value_short(system.name_of(row.value[:])), graphics.COLOR_TEXT)
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
	inside := interface.card(frame, {VARIABLES_X, LOW_Y, VARIABLES_WIDTH, LOW_HEIGHT}, "VARIABLES", "debugger.locals", graphics.COLOR_MACHINE)
	if variable_count == 0 {
		lines(inside, 0, 0, inside.width, !attached ? "no program is attached" : thread_can_be_read() ? "the frame has no variable that the debug object describes" : "the thread runs: it has no variable to read", graphics.COLOR_DIM)
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
		y = lines(inside, 0, y, inside.width, label, graphics.COLOR_DIM)
		y = lines(inside, 16, y, inside.width - 16, value, graphics.COLOR_TEXT) + 2
		shown += 1
	}
	rest_line(inside, y, shown, variable_count, "variables")
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	frame_table = frame.table
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	draw_program(&frame)
	draw_source(&frame)
	draw_stack(&frame)
	draw_variables(&frame)
	keys := interface.Area{MARGIN + 8, HEIGHT - MARGIN - KEYS_HEIGHT + 8, WIDTH - 2 * MARGIN - 16, KEYS_HEIGHT}
	lines(keys, 0, 0, keys.width, attached ? "up, down: thread   page up, page down: frame   h: hold   r: let run   c: let each run   s: one instruction   l: one line   o: one line, over each call   b: a breakpoint at the line of the frame   0 to 3: remove a breakpoint   g: the registers or the variables   d: detach" : "letters, digits and _: the name   backspace: remove a character   enter: attach", graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
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
	if problem := service_reach(ctx); problem != "" {
		status_set(true, problem)
		system.log("debugger_window: ", problem)
	} else {
		ready = true
		system.log("debugger_window: ok, connected to the service debugger; ", u64(len(Export)), " exports, each record with the size of its description")
	}
	for {
		draw(&window)
		next := system.time() + REFRESH_MILLISECONDS
		for {
			wait: system.Wait
			display.wait_events(&wait, &window)
			now := system.wait_end(&wait, next)
			changed := false
			for event in display.next_event(&window) {
				if event.kind == .Key && event.pressed {
					key(event)
					changed = true
				}
			}
			if changed {
				draw(&window)
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
