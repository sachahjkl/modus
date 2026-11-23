// A count that its callers add to. This module shows that one file has each role: the system has no difference between a command line program, a library and a dynamic library.
//
// The same file, with the same hash, is used in four ways:
//   start("tally")     a process, with a window that shows the count
//   connect("tally")   a service: the calls go to the process that runs
//   load("tally")      a library: the calls are direct, in the memory of the caller
//   isolate("tally")   a sandboxed process: the calls go through a ring
//
// The data of a module belongs to the process that runs it. The four uses give three counts: the process and the service have one count, the caller that loads the module has its own, and the sandboxed process has its own.
//
// An export needs nothing from the entry: it reads and writes the data of the module only. That is the one rule for a module that has each role.
//
// **Grants**, as the root service gives them: **Serve**, so that `connect("tally")` reaches the process that runs.
// `load` and `isolate` need no grant of tally: the console maps the file from the boot image.
//
// **What a reader sees**, as a process: the count, the number of adds, the last 8 notes with the newest first, and
// the callers and the calls. The key Space adds 1, with the note "a key of the process". The log has "tally: ok"
// when the window opens.
//
// **Example**, in the console:
//
// ```
// load("tally")
// add(2, "two")       the count of the console: 2
// connect("tally")
// tally.add(5, "five")  the count of the process: 5
// ```
//
// The design: (docs/MODULE_CONTRACT.md, "3. Static is dynamic").
package tally

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

WIDTH :: 400
HEIGHT :: 214
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (168 pages): its module, its
// stack, its tables and its glyph memory. The tool counts the window at
// the largest scale (docs/MODULE_CONTRACT.md, "The budget that a module
// asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1880, window_width = WIDTH, window_height = HEIGHT}
NOTE_CAPACITY :: 8
NOTE_SIZE :: 36

Note :: struct {
	amount: i64,
	text:   [NOTE_SIZE]u8,
	count:  int,
}

count: i64
calls: i64 // The calls of add.
notes: [NOTE_CAPACITY]Note // notes[(calls - 1) % NOTE_CAPACITY] is the last.

// add adds an amount to the count, with a note that says why.
//
// The count and the notes are data of the module, in the process that runs it: the four ways of tally give three
// counts. The module keeps the last 8 notes.
//
// - **amount**: the amount, positive or negative.
// - **note**: why, 36 bytes at most.
//
// The result is the new count, never negative. It fails with its call outcome and an error record, and the count does not
// change:
//
// - `Too_Long`: the note has more than 36 bytes;
// - `Too_Small`: the amount takes the count below 0; the record holds the least amount that is allowed;
// - `Bad_Value`: the count passes the largest integer.
//
// Example: `tally.add(-3, "a refund")`.
@(export, link_name = "add")
add :: proc "c" (amount: i64, note: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if len(note) > NOTE_SIZE {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 2, i64(len(note)), NOTE_SIZE)
	}
	if amount < -count {
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .None, 1, amount, -count)
	}
	if amount > max(i64) - count {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, amount, max(i64) - count)
	}
	item := &notes[u64(calls) % NOTE_CAPACITY]
	item.amount = amount
	item.count = min(len(note), NOTE_SIZE)
	for i in 0 ..< item.count {
		item.text[i] = note[i]
	}
	calls += 1
	count += amount
	return .Succeeded, count
}

// total gives the count.
//
// The count of the process that runs the module: after `load("tally")` it is the count of the caller itself. It
// never fails.
@(export, link_name = "total")
total :: proc "c" () -> i64 {
	return count
}

// adds gives the number of calls of add after the start, or after the last reset.
//
// A refused add does not count. A test compares it with the calls that it made: a call over a ring that ran two
// times shows here.
@(export, link_name = "adds")
adds :: proc "c" () -> i64 {
	return calls
}

// last gives the note of the last add. The text is empty before the first add.
//
// The result is the length of the note, 36 at most; a text shorter than the note gets its first bytes.
@(export, link_name = "last")
last :: proc "c" (result: ^[]u8) -> i64 {
	if calls == 0 {
		return 0
	}
	item := &notes[u64(calls - 1) % NOTE_CAPACITY]
	for i in 0 ..< min(item.count, len(result)) {
		result[i] = item.text[i]
	}
	return i64(item.count)
}

// reset puts the count at 0 and removes the notes. The result is the count before.
//
// It also sets the count of [adds](tally.adds) to 0. It never fails.
@(export, link_name = "reset")
reset :: proc "c" () -> i64 {
	before := count
	count, calls, notes = 0, 0, {}
	return before
}

// draw builds a frame of the window with the interface package.
draw :: proc "contextless" (window: ^display.Window, service: ^system.Service) {
	frame := interface.window_frame_start(&window_memory, window)
	interface.action_bar_input_take(&frame, &bar)
	facts_end := draw_records(frame.table, service)
	// The key of the window, in its action bar (docs/INTERFACE.md, "4.4
	// The action bar"), at the right of the counts of the service. Its item
	// stands from the right edge: the counts change, the item keeps its
	// place.
	bar_y := HEIGHT - interface.ACTION_BAR_ROW_HEIGHT
	bar_left := facts_end + 16
	items := bar_items()
	bar_result := interface.action_bar(&frame, {bar_left, bar_y, WIDTH - bar_left, interface.ACTION_BAR_ROW_HEIGHT}, items[:], &bar, {alignment = .Right})
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	if bar_result.ran {
		key_run(bar_result.run)
		bar_acted = true
	}
}

// bar_items gives the item of the action bar. A procedure, not a global
// array: an item is made by a call, and a freestanding process runs no
// call before its entry.
bar_items :: proc "contextless" () -> [1]interface.Action_Bar_Item {
	return {interface.action_bar_item("Add 1", 1, "Space")}
}
bar: interface.Action_Bar_State
bar_acted: bool // A press on the item ran its key: the next turn draws the new count.

// key_run runs one key: a typed key, or the key of the item of the action
// bar that a press ran. Space is one add of 1.
key_run :: proc "contextless" (press: interface.Key_Press) {
	if press.character == ' ' {
		note := "a key of the process"
		add(1, &note, nil)
	}
}

// draw_records draws the window under its action bar, and gives the x
// after the counts of the service, on the line of the bar.
draw_records :: proc "contextless" (table: ^interface.Draw_Table, service: ^system.Service) -> (facts_end: int) {
	buffer: [24]u8
	x := interface.draw_text(table, 12, 10, "count ", graphics.colors.dim)
	// The count is the data of the module, in the memory of the process
	// that runs it: the color of memory.
	x = interface.draw_text(table, x, 10, system.format(buffer[:], count), graphics.colors.memory)
	x = interface.draw_text(table, x + 24, 10, "adds ", graphics.colors.dim)
	interface.draw_text(table, x, 10, system.format(buffer[:], calls), graphics.colors.text)
	interface.draw_rectangle(table, 12, 32, WIDTH - 24, 1, graphics.colors.track)
	// The notes, the last one first.
	for row in 0 ..< min(calls, NOTE_CAPACITY) {
		item := &notes[u64(calls - 1 - row) % NOTE_CAPACITY]
		y := 40 + int(row) * 18
		amount := system.format(buffer[:], item.amount)
		// An amount is a value: the text color. Its sign says whether it
		// adds or takes away.
		if item.amount >= 0 {
			interface.draw_text(table, 12, y, "+", graphics.colors.text)
		}
		interface.draw_text(table, item.amount >= 0 ? 20 : 12, y, amount, graphics.colors.text)
		interface.draw_text(table, 92, y, string(item.text[:item.count]), row == 0 ? graphics.colors.text : graphics.colors.dim)
	}
	// The band of the action bar, from edge to edge, with the counts of the
	// service at its left.
	bar_y := HEIGHT - interface.ACTION_BAR_ROW_HEIGHT
	text_y := bar_y + (interface.ACTION_BAR_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2
	interface.draw_rectangle(table, 0, bar_y, WIDTH, interface.ACTION_BAR_ROW_HEIGHT, graphics.colors.card_bottom)
	interface.draw_rectangle(table, 0, bar_y, WIDTH, 1, graphics.colors.track)
	x = interface.draw_text(table, 12, text_y, "callers ", graphics.colors.dim)
	x = interface.draw_text(table, x, text_y, system.format(buffer[:], u64(service.connected)), graphics.colors.text)
	x = interface.draw_text(table, x + 16, text_y, "calls ", graphics.colors.dim)
	return interface.draw_text(table, x, text_y, system.format(buffer[:], service.calls), graphics.colors.text)
}

// The entry of tally: it runs only when tally is a process (`start` or
// `connect`), never after `load`. It opens the service and the window, then
// runs the calls and the key Space in one loop until the principal closes
// the window.
//
// With no window it stops with `Failed`. It writes "tally: ok". Each turn
// draws the window, waits for an event or a call, runs the calls, then the
// keys: Space is one add of 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "tally")
	if !ok {
		system.stop(.Failed)
	}
	system.log_fact(.Info, Running{})
	for {
		draw(&window, &service)
		// A press on the item of the action bar added: the next turn
		// draws the new count, with no wait.
		if bar_acted {
			bar_acted = false
			continue
		}

		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		for event in interface.window_next_event(&window_memory.drawing, &window, .Every_Event) {
			switch event.kind {
			case .Pointer:
				// The pointer reaches the action bar only: the window layer
				// gave it to the input of the next frame.
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
			case .None, .Settings_Changed, .Go_To, .Resized, .Copy_Asked, .Pasted, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Surface_Answer, .Work_Area:
				// next_event never gives None, and this window does nothing for the other events.
			}
		}
	}
}
