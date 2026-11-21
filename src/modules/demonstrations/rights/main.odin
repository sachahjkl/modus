// A demonstration of rights on handles: a process holds only the handles
// that it was given, and only with the rights that it was given.
//
// The root service gives this process two handles, each with a part of its
// rights: the machine with Inspect, the boot image with Read. The process
// asks the kernel for nine operations. The window shows each answer of the
// kernel: the kernel refuses each operation that needs another right.
//
// **What it is for.** It shows that a right is part of a handle, and that
// the kernel checks it on each operation: holding the machine is not
// holding all of it. A handle that the process creates itself has each
// right, so the process is not crippled for its own work.
//
// **The nine operations**, with the answer that the kernel must give:
//
// - read the report of the machine (Inspect): allowed;
// - create a handle to the ports of the keyboard: `No_Right`;
// - stop the machine: `No_Right`;
// - map the boot image to read it: allowed;
// - map it to write in it, or to execute it: `No_Right`;
// - give the boot image to the compositor: `No_Right`, because the handle
//   has no right Give;
// - create memory and write in it: allowed;
// - start a thread and read its state: allowed.
//
// **Start**: `start("rights")` in the console, or the bar of the desktop.
//
// **Grants**, as the root service gives them:
//
// - **Inspect**: the machine, with the right Inspect only.
// - **Image**: the boot image, with the right Read only.
//
// **What a reader sees**: the two handles, then one row for each operation
// with the answer of the kernel; an unexpected answer is in another color.
// The log has "rights: ok, 4 allowed, 5 refused", or "rights: wrong answer:
// ..." for each unexpected answer.
package rights

import "modus:display"
import "modus:graphics"
import "modus:interface"
import op "modus:contract/operation"
import "modus:system"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module, its threads and its
// window: 1554 pages. And the glyph memory of the copy of the text
// rendering of the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 1554 + 354 = 1908.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1908, processes = 1, threads = 2, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

LINE :: 22
ANSWER_X :: 384
WIDTH :: 544
ATTEMPT_CAPACITY :: 9
// A literal, because the tool counts the pictures of the window from it;
// the assertion keeps it equal to its layout.
HEIGHT :: 332
#assert(HEIGHT == 12 + 5 * LINE + ATTEMPT_CAPACITY * LINE + 12)


// One operation that the process asked, and the answer of the kernel.
Attempt :: struct {
	text:     string,
	expected: system.Status,
	status:   system.Status,
}

attempts: [ATTEMPT_CAPACITY]Attempt
attempt_count: int

note :: proc "contextless" (text: string, expected: system.Status, status: system.Status) {
	attempts[attempt_count] = {text, expected, status}
	attempt_count += 1
}

answer :: proc "contextless" (status: system.Status) -> string {
	switch status {
	case .Ok:
		return "done"
	case .No_Right:
		return "refused: no right"
	case .Bad_Operation:
		return "bad operation"
	case .Bad_Handle:
		return "bad handle"
	case .Bad_Address:
		return "bad address"
	case .No_Memory:
		return "no memory"
	case .No_Slot:
		return "no slot"
	case .Bad_State:
		return "bad state"
	case .No_Budget:
		return "no budget"
	}
	return "?"
}

// The entry of a thread that ends at once.
idle :: proc "c" (parameter: rawptr) -> ! {
	system.thread_stop()
}

// The entry of rights: it asks the kernel for the nine operations once,
// writes the result, then shows the table until the principal closes the
// window.
//
// With no window it stops with `Failed`. Each operation is noted with
// the status that the kernel gave and the status that it must give.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "rights")
	if !ok {
		system.stop(.Failed)
	}
	machine := ctx.handles[system.GRANT_MACHINE]
	image := ctx.handles[system.GRANT_IMAGE]
	status: system.Status

	report: op.System_Report
	_, status = system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	note("read the report of the machine", .Ok, status)
	_, status = system.call(.Device_Create, u64(machine), u64(op.Device_Kind.Ports), 0x60, 5)
	note("create a handle to the ports of the keyboard", .No_Right, status)
	_, status = system.call(.Machine_Stop, u64(machine), 0)
	note("stop the machine", .No_Right, status)

	_, status = system.memory_map(image, {})
	note("map the boot image to read it", .Ok, status)
	_, status = system.memory_map(image, {.Write})
	note("map the boot image to write in it", .No_Right, status)
	_, status = system.memory_map(image, {.Execute})
	note("map the boot image to execute it", .No_Right, status)
	_, status = system.give(window.ring_memory, image, {.Read})
	note("give the boot image to the compositor", .No_Right, status)

	// The handle of an object that the process creates has each right.
	memory: system.Handle
	memory, status = system.memory_create(1)
	if status == .Ok {
		address: rawptr
		address, status = system.memory_map(memory)
		if status == .Ok {
			(^u64)(address)^ = 1
		}
	}
	note("create memory and write in it", .Ok, status)
	thread: system.Thread
	thread, status = system.thread_start(idle, nil)
	if status == .Ok {
		_, status = system.call(.Thread_State, u64(thread.handle))
		system.thread_wait(thread)
	}
	note("start a thread and read its state", .Ok, status)

	allowed, refused, wrong: u64
	for attempt in attempts[:attempt_count] {
		if attempt.status != attempt.expected {
			wrong += 1
			system.log_fact(.Info, Attempt_Wrong{status = attempt.status, attempt = attempt_field(attempt.text)})
		} else if attempt.status == .Ok {
			allowed += 1
		} else {
			refused += 1
		}
	}
	if wrong == 0 {
		system.log_fact(.Info, Attempts_Passed{allowed = allowed, refused = refused})
	}

	for {
		frame := interface.window_frame_start(&window_memory, &window)
		// Each line is a line of a table: its text 3 pixels under its top.
		column := interface.column_of({12, 9, WIDTH - 24, HEIGHT - 9})
		interface.cell_text(&frame, interface.column_take(&column, LINE), "this process holds two handles from the root service:", graphics.colors.dim)
		// A handle: its object, then its right in the color of a right that
		// the process holds.
		handles := [2][2]string{{"the machine, with the right ", "Inspect"}, {"the boot image, with the right ", "Read"}}
		for handle in handles {
			line := interface.column_take(&column, LINE)
			text_y := line.y + (line.height - interface.line_height({})) / 2
			x := interface.draw_text(frame.table, line.x + 16, text_y, handle[0], graphics.colors.text)
			interface.cell_text(&frame, {x, line.y, line.x + line.width - x, line.height}, handle[1], graphics.colors.process)
		}
		interface.column_take(&column, LINE / 2)
		sizes := [2]interface.Size{interface.pixels(ANSWER_X - 12), interface.share()}
		cells: [2]interface.Area
		interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:])
		interface.cell_text(&frame, cells[0], "the process asks", graphics.colors.dim)
		interface.cell_text(&frame, cells[1], "the kernel answers", graphics.colors.dim)
		for attempt, index in attempts[:attempt_count] {
			row := interface.column_take(&column, LINE)
			interface.table_band(&frame, {row.x - 6, row.y, row.width + 12, row.height}, index)
			interface.row_split(row, sizes[:], cells[:])
			interface.cell_text(&frame, cells[0], attempt.text, graphics.colors.text)
			// The expected answer, a refusal too, is the expected answer of
			// the rules; another answer is a check that did not pass. The
			// words of the answer say whether it is a refusal.
			color := attempt.status == attempt.expected ? graphics.colors.process : graphics.colors.failed
			interface.cell_text(&frame, cells[1], answer(attempt.status), color)
		}
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
