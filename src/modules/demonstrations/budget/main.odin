// A demonstration of budgets: a program holds only what it was given, and
// each resource has a limit.
//
// No operation creates an object from nothing: a budget pays for each
// memory object, each program and each thread. The root service gave this
// program a budget. The program creates objects until the kernel refuses,
// then frees them: each page returns. Then it takes a part of its budget
// for a new budget, and closes it: what the new budget held returns, and
// this budget pays for the objects that live.
//
// **What it is for.** It shows that memory is supplied by the caller: a
// [budget](term:budget) is a handle that pays for each page, each program
// and each thread, and the kernel refuses with `No_Budget`, never with a
// hidden allocation, when it cannot pay. It also shows that a program can
// split its budget, and that a closed budget gives back what it held.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("budget")` in the console. The window has one row for each step,
// with its answer: the pages of the budget from the root service; memory
// objects of 64 pages until `No_Budget`, then all of them closed; threads
// until `No_Budget`; a part of the budget given to a new budget, then that
// budget closed. The log gets `budget: ok, <count> memory objects then no
// budget, <count> threads then no budget, each page returned`, or
// `budget: wrong answer: ...` for a step that gave another answer.
//
// **Its grants**: none. Its budget from the root service holds 1280 pages,
// 1 program and 4 threads: the limits that the steps reach.
package budget

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import op "modus:contract/operation"
import "modus:support/system"

// The pages that its cases spend.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 598, programs = 1, threads = 4, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

LINE :: 22
ANSWER_X :: 336
BAR_X :: 560
BAR_WIDTH :: 150
// The size of the window is two literals, because the tool counts its
// pictures from them; each assertion keeps a literal equal to its layout.
WIDTH :: 774
#assert(WIDTH == BAR_X + BAR_WIDTH + 64)
ROW_CAPACITY :: 11
HEIGHT :: 332
#assert(HEIGHT == 12 + 3 * LINE + ROW_CAPACITY * LINE + 12)

OBJECT_PAGES :: 64
OBJECT_CAPACITY :: 64
THREAD_CAPACITY :: 8
PART_PAGES :: 256
FIRST_PAGES :: 200
SECOND_PAGES :: 100


// One step of the program: what it asked, the answer of the kernel, and
// the pages that the budget holds after the step.
Row :: struct {
	text:    string,
	buffer:  [40]u8,
	count:   int, // The bytes of the answer in buffer.
	refused: bool, // The answer ends with a refusal of the kernel.
	correct: bool, // The answer and the pages are what the rules give.
	pages:   u64,
}

rows: [ROW_CAPACITY]Row
row_count: int
release: u32 // The threads of the test wait while this word is 0.

pages_left :: proc "contextless" () -> u64 {
	amounts, _ := system.budget_read()
	return amounts.pages
}

note :: proc "contextless" (text: string, refused: bool, correct: bool, parts: ..system.Part) {
	row := &rows[row_count]
	row_count += 1
	row.text = text
	row.count = len(system.format(row.buffer[:], ..parts))
	row.refused = refused
	row.correct = correct
	row.pages = pages_left()
}

// wait_release is the entry of a thread that waits, then ends.
wait_release :: proc "c" (parameter: rawptr) -> ! {
	for release == 0 {
		system.word_wait(&release, 0)
	}
	system.thread_stop()
}

// entry runs each step of the demonstration once, writes the summary line,
// then keeps the window open until the program is stopped. Each step checks
// its answer against the budget that it read before (`system.budget_read`):
// the count of objects that the pages pay for, the pages left, and each
// page back after the close. With no window, it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "budget")
	if !ok {
		system.stop(1)
	}
	start, _ := system.budget_read()
	note("the budget from the root service", false, start.pages != 0, start.pages, " pages")

	// Memory objects, until the budget cannot pay.
	objects: [OBJECT_CAPACITY]system.Handle
	object_count: u64
	status := system.Status.Ok
	for object_count < OBJECT_CAPACITY {
		objects[object_count], status = system.memory_create(OBJECT_PAGES)
		if status != .Ok {
			break
		}
		object_count += 1
	}
	// An object also pays for its frame list (operation.memory_cost).
	cost := op.memory_cost(OBJECT_PAGES)
	note("create memory objects of 64 pages", true, status == .No_Budget && object_count == start.pages / cost && pages_left() == start.pages % cost, object_count, " done, then no budget")
	for object in objects[:object_count] {
		system.close(object)
	}
	note("close these memory objects", false, pages_left() == start.pages, "each page returns")

	// Threads, until the budget cannot pay.
	threads: [THREAD_CAPACITY]system.Thread
	thread_count: u64
	for thread_count < THREAD_CAPACITY {
		threads[thread_count], status = system.thread_start(wait_release, nil)
		if status != .Ok {
			break
		}
		thread_count += 1
	}
	note("start threads", true, status == .No_Budget && thread_count == start.threads, thread_count, " done, then no budget")
	release = 1
	system.word_wake(&release, THREAD_CAPACITY)
	for thread in threads[:thread_count] {
		system.thread_wait(thread)
	}
	after_threads, _ := system.budget_read()
	note("end these threads", false, after_threads == start, "each page returns")

	// A part of the budget becomes a new budget.
	part, part_status := system.budget_create({pages = PART_PAGES})
	note("take 256 pages for a new budget", false, part_status == .Ok && pages_left() == start.pages - PART_PAGES, "done")
	first, first_status := system.memory_create(FIRST_PAGES, part)
	note("create 200 pages with the new budget", false, first_status == .Ok && pages_left() == start.pages - PART_PAGES, "done")
	_, second_status := system.memory_create(SECOND_PAGES, part)
	note("create 100 pages more with it", true, second_status == .No_Budget, "no budget")
	system.close(part)
	note("close the new budget, keep the memory", false, pages_left() == start.pages - op.memory_cost(FIRST_PAGES), "this budget pays for it")
	system.close(first)
	note("close the memory", false, pages_left() == start.pages, "each page returns")

	// The budget paid for one program: this one.
	_, status = system.call(.Program_Create, u64(system.own_budget()), 0, 0)
	note("create a program", true, status == .No_Budget, "no budget")

	wrong: u64
	for &row in rows[:row_count] {
		if !row.correct {
			wrong += 1
			system.log("budget: wrong answer: ", row.text, ": ", string(row.buffer[:row.count]), ", ", row.pages, " pages")
		}
	}
	if wrong == 0 {
		system.log("budget: ok, ", object_count, " memory objects then no budget, ", thread_count, " threads then no budget, each page returned")
	}

	for {
		frame := interface.window_frame_start(&window_memory, &window)
		// Each line is a line of a table: its text 3 pixels under its top.
		column := interface.column_of({12, 9, WIDTH - 24, HEIGHT - 9})
		interface.cell_text(&frame, interface.column_take(&column, LINE), "no object comes from nothing: a budget pays for each page,", graphics.colors.dim)
		interface.cell_text(&frame, interface.column_take(&column, LINE), "each program and each thread. what ends returns to its budget.", graphics.colors.dim)
		interface.column_take(&column, LINE / 2)
		sizes := [3]interface.Size{interface.pixels(ANSWER_X - 12), interface.pixels(BAR_X - ANSWER_X), interface.share()}
		cells: [3]interface.Area
		interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:])
		interface.cell_text(&frame, cells[0], "the program asks", graphics.colors.dim)
		interface.cell_text(&frame, cells[1], "the kernel answers", graphics.colors.dim)
		interface.cell_text(&frame, cells[2], "pages of the budget", graphics.colors.dim)
		for &row, index in rows[:row_count] {
			line := interface.column_take(&column, LINE)
			interface.table_band(&frame, {line.x - 6, line.y, line.width + 12, line.height}, index)
			interface.row_split(line, sizes[:], cells[:])
			interface.cell_text(&frame, cells[0], row.text, graphics.colors.text)
			// The expected answer, a refusal too, is the expected answer of
			// the rules; another answer is a check that did not pass. The
			// words of the answer say whether it is a refusal.
			color := row.correct ? graphics.colors.program : graphics.colors.failed
			interface.cell_text(&frame, cells[1], string(row.buffer[:row.count]), color)
			// The pages of a budget are memory.
			interface.bar_with_value(&frame, cells[2], BAR_WIDTH, row.pages, start.pages, graphics.colors.memory)
		}
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
