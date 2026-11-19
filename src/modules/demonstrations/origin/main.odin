// A demonstration of the origin of a handle and of Handle_Revoke: a
// process holds only the handles that it was given, and each grant can be
// revoked with all that came from it.
//
// The kernel keeps, for each handle and each mapping, the handle that it
// came from. A process takes back what came from a handle of its own: the
// copies, the handles that other processes received, and their mappings.
// The window shows each case and the answer of the kernel.
//
// **What it is for.** It shows that each access in the system can be taken
// back. A process lends a handle for one call, then revokes it: the kernel
// ends each copy and each mapping that came from it, in this process and in
// the processes that received it. No process needs the cooperation of the
// receiver to take back what it gave.
//
// **The cases**, in order:
//
// - a copy with the right Read, then a copy of the copy that asks for Write:
//   the kernel gives Read only, because a copy never has more rights;
// - the count of what came from a handle, before and after a close;
// - a revocation: the copies end, the mapping of the process stays;
// - a mapping in another process, then its revocation;
// - a revocation in one other process only, with `Handle_Revoke` and the
//   handle of that process;
// - a revocation of a handle that the process does not have: `Bad_Handle`.
//
// **Start**: `start("origin")` in the console, or the bar of the desktop.
// Its row of `process_roles` has no grant: everything that it uses, it makes. Its
// budget has room for two processes: itself and the process "held", which
// never runs and only receives.
//
// **What a reader sees**: the table of the cases and the answers of the
// kernel. The log has "origin: ok, 12 cases", or "origin: wrong answer: ..."
// for each case that failed, then the cost of a lent handle: "origin: lend a
// handle and take it back: N ns with 4 kernel entries; copy and close: M ns
// with 2".
package origin

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import op "modus:contract/operation"
import "modus:support/system"

// Itself and one process that only receives: 1372 pages. And the glyph
// memory of the copy of the text rendering of the drawing module, which
// draws its text: 354 pages (display.TEXT_MEMORY_PAGES). 1372 + 354 =
// 1726.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1726, processes = 2, threads = 1, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

LINE :: 22
ANSWER_X :: 424
WIDTH :: 640
CASE_CAPACITY :: 12
// A literal, because the tool counts the pictures of the window from it;
// the assertion keeps it equal to its layout.
HEIGHT :: 442
#assert(HEIGHT == 12 + 4 * LINE + CASE_CAPACITY * LINE + 3 * LINE + 12)


// One case: what the process did, and what the kernel answered.
Case :: struct {
	text:   string,
	answer: string,
	right:  bool,
}

cases: [CASE_CAPACITY]Case
case_count: int

note :: proc "contextless" (text: string, answer: string, right: bool) {
	cases[case_count] = {text, answer, right}
	case_count += 1
}

// The measure: the cost of one handle that a process lends for a call and
// takes back, against the two kernel entries of a copy that it closes.
CYCLES :: 20000
lend_time, copy_time: u64 // Nanoseconds for one cycle.

// Where the process maps its memory object in the other process.
OTHER_ADDRESS :: 0x0000_0000_0100_0000

live :: proc "contextless" (handle: system.Handle) -> bool {
	kind, _, _ := system.handle_state(handle)
	return kind != .None
}

// The entry of origin: it runs the cases of the origin of a handle once,
// measures a lent handle, then shows the result until the principal closes
// the window.
//
// With no window it stops with the code 1. It creates one memory object and
// one process "held" from its own budget, runs the cases (each one compares
// the answer of the kernel with the expected answer), writes the result on
// the log, and measures 20000 cycles of "lend and take back" and 20000 of
// "copy and close". Then it draws the table and waits for events for ever.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "origin")
	if !ok {
		system.stop(1)
	}
	// One memory object, mapped here, and one other process that never
	// runs: it only receives.
	memory, _ := system.memory_create(1)
	bytes, _ := system.memory_map(memory)
	(^u64)(bytes)^ = 7
	name := "held"
	created, _ := system.call(.Process_Create, u64(ctx.handles[op.CONTEXT_BUDGET]), u64(uintptr(raw_data(name))), u64(len(name)))
	other := system.Handle(created[0])
	count: u64

	first, _ := system.give(0, memory, {.Read})
	_, rights, _ := system.handle_state(first)
	note("copy the handle, with the right Read", "a handle with Read", rights == {.Read})
	second, _ := system.give(0, first, {.Read, .Write})
	_, rights, _ = system.handle_state(second)
	note("copy the copy, and ask for Write", "a handle with Read", rights == {.Read})
	note("count what came from the handle", "3: a mapping, 2 copies", system.handle_holdings(memory) == 3)
	system.close(first)
	note("close the first copy", "2: the second stays", system.handle_holdings(memory) == 2 && live(second))
	count, _ = system.handle_revoke(memory)
	note("revoke the handle", "the second copy ended", count == 1 && !live(second))
	note("read the memory of this process", "the mapping stays", (^u64)(bytes)^ == 7 && system.handle_holdings(memory) == 1)

	// A mapping in the other process, made with a copy that closes.
	first, _ = system.give(0, memory, {.Read})
	_, status := system.memory_map(first, {}, other, OTHER_ADDRESS)
	system.close(first)
	_, again := system.memory_map(memory, {}, other, OTHER_ADDRESS)
	note("map the memory in another process", "mapped", status == .Ok && again == .Bad_Address)
	count, _ = system.handle_revoke(memory)
	_, again = system.memory_map(memory, {}, other, OTHER_ADDRESS)
	note("revoke the handle", "the mapping ended", count == 1 && again == .Ok)

	// Now the other process has a mapping. It receives a handle too.
	given, _ := system.give(other, memory, {.Read})
	first, _ = system.give(0, memory, {.Read})
	note("give the handle to the other process", "4 came from the handle", given != 0 && system.handle_holdings(memory) == 4)
	count, _ = system.handle_revoke(memory, other)
	note("revoke in the other process only", "2 ended, the copy stays", count == 2 && live(first) && system.handle_holdings(memory) == 2)
	count, _ = system.handle_revoke(first)
	note("revoke the copy", "0 ended, the handle stays", count == 0 && live(memory))
	_, status = system.handle_revoke(system.Handle(0xFFFF))
	note("revoke a handle that the process does not have", "refused: bad handle", status == .Bad_Handle)

	wrong: u64
	for item in cases[:case_count] {
		if !item.right {
			wrong += 1
			system.log(.Info, "origin: wrong answer: ", item.text)
		}
	}
	if wrong == 0 {
		system.log(.Info, "origin: ok, ", u64(case_count), " cases")
	}

	// The measure. One cycle of a lent handle is four kernel entries: a
	// copy, a handle for the other process, the revocation, the close.
	start := system.time()
	for _ in 0 ..< CYCLES {
		copy, _ := system.give(0, memory, {.Read, .Give})
		system.give(other, copy, {.Read})
		system.handle_revoke(copy)
		system.close(copy)
	}
	lend_time = (system.time() - start) * 1_000_000 / CYCLES
	start = system.time()
	for _ in 0 ..< CYCLES {
		copy, _ := system.give(0, memory, {.Read, .Give})
		system.close(copy)
	}
	copy_time = (system.time() - start) * 1_000_000 / CYCLES
	system.log(.Info, "origin: lend a handle and take it back: ", lend_time, " ns with 4 kernel entries; copy and close: ", copy_time, " ns with 2")

	for {
		frame := interface.window_frame_start(&window_memory, &window)
		// Each line is a line of a table: its text 3 pixels under its top.
		column := interface.column_of({12, 9, WIDTH - 24, HEIGHT - 9})
		interface.cell_text(&frame, interface.column_take(&column, LINE), "the kernel keeps the origin of each handle and of each mapping.", graphics.colors.dim)
		interface.cell_text(&frame, interface.column_take(&column, LINE), "a process takes back what came from a handle that it holds.", graphics.colors.dim)
		interface.column_take(&column, LINE / 2)
		sizes := [2]interface.Size{interface.pixels(ANSWER_X - 12), interface.share()}
		cells: [2]interface.Area
		interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:])
		interface.cell_text(&frame, cells[0], "the process does", graphics.colors.dim)
		interface.cell_text(&frame, cells[1], "the kernel answers", graphics.colors.dim)
		for item, index in cases[:case_count] {
			row := interface.column_take(&column, LINE)
			interface.table_band(&frame, {row.x - 6, row.y, row.width + 12, row.height}, index)
			interface.row_split(row, sizes[:], cells[:])
			interface.cell_text(&frame, cells[0], item.text, graphics.colors.text)
			interface.cell_text(&frame, cells[1], item.right ? item.answer : "another answer", item.right ? graphics.colors.process : graphics.colors.failed)
		}
		interface.column_take(&column, LINE / 2)
		line: [96]u8
		interface.cell_text(&frame, interface.column_take(&column, LINE), system.format(line[:], "lend a handle for a call, then take it back: ", lend_time, " ns, 4 kernel entries"), graphics.colors.dim)
		interface.cell_text(&frame, interface.column_take(&column, LINE), system.format(line[:], "copy a handle, then close the copy: ", copy_time, " ns, 2 kernel entries"), graphics.colors.dim)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
