// A demonstration of paging as a tool of the system (paging, second part).
//
// Pages on first use: a memory object takes no page frame until a process
// uses a page; the budget pays at creation, so an access never fails. The
// shared code of a module: processes that run one module map one memory
// object for its code; a write to it is a page fault. The window shows each
// case and the answer of the kernel, and the measures.
//
// The process needs the grant to inspect the machine (it reads the page
// table of its own half), and the boot image (it starts the process `twin`).
//
// **What it is for.** It shows two uses of paging that the system relies
// on. A [page on first use](term:page-on-first-use) costs its frame only
// when a process touches it, and the budget pays at creation, so no access
// fails for lack of memory. [Shared code](term:shared-code) lets several
// processes that run one module map one memory object for its code, read
// only: the code is in memory once, and a process that writes to it faults
// alone.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("frames")` in the console. The window has one row for each case,
// with the answer of the kernel, then the measures. Its lines in the log:
// the time to create and map 8192 pages with each frame now and with
// pages on first use; the time of the first use of a page; the time to
// start a `twin` with its own copy of the module and with the shared code;
// and the pages that 4 twins cost each way (`frames: 4 twins: ...`).
//
// **Its grants**: **Inspect**, to read the page table of its own half, and
// **Image**, to start the process `twin` from the boot image. Its budget
// holds 12288 pages: 8192 pages at a time, and 5 twins.
//
// **What it does not prove.** The times are measures of the host of the
// run; no case checks a speed.
package frames

import "base:intrinsics"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import op "modus:contract/operation"
import "modus:support/random"
import "modus:support/system"
import "modus:support/twins"

// 8192 pages at a time, and five twins: 11446 pages. And the glyph memory
// of the copy of the text rendering of the drawing module, which draws its
// text: 354 pages (display.TEXT_MEMORY_PAGES). 11446 + 354 = 11800.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 11800, processes = 6, threads = 6, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

LINE :: 22
ANSWER_X :: 384
WIDTH :: 760
CASE_CAPACITY :: 10
MEASURE_LINES :: 3
// A literal, because the tool counts the pictures of the window from it;
// the assertion keeps it equal to its layout.
HEIGHT :: 409
#assert(HEIGHT == 12 + 4 * LINE + CASE_CAPACITY * LINE + LINE / 2 + MEASURE_LINES * LINE + 12)

LARGE_PAGES :: 8192
SMALL_BUDGET :: 100 // The pages of a budget that this process makes for one case.
TWIN_COUNT :: 4
TWIN_AMOUNTS :: system.Budget_Amounts{pages = 256, processes = 1, threads = 1, processor = 100_000, log_records = 10}


// One case: what the process did, and what the kernel answered.
Case :: struct {
	text:   string,
	buffer: [48]u8,
	answer: string,
	right:  bool,
}

cases: [CASE_CAPACITY]Case
case_count: int

note :: proc "contextless" (text: string, right: bool, parts: ..system.Part) {
	item := &cases[case_count]
	case_count += 1
	item.text = text
	item.answer = system.format(item.buffer[:], ..parts)
	item.right = right
}

machine: system.Handle
image: []u8
boot: op.Boot_Report
half: op.Mapping_Report
prepared: system.Prepared_Modules // The shared code of the twins.

// The measures, in microseconds and nanoseconds.
create_now, create_first_use: u64
first_use, write_present: u64
start_own, start_shared: u64

nanoseconds :: proc "contextless" (cycles: u64) -> u64 {
	return cycles * 1000 / max(boot.cycle_frequency / 1_000_000, 1)
}

// present_in gives the pages of a range of this process that have a page
// frame, as the kernel reads them in the page table.
present_in :: proc "contextless" (address: rawptr, pages: u64) -> (count: u64) {
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Mappings), 1, u64(uintptr(&half)), size_of(half))
	start := u64(uintptr(address))
	end := start + pages * system.PAGE_SIZE
	for run in half.runs[:min(half.run_count, op.MAPPING_RUN_CAPACITY)] {
		low := max(run.start, start)
		high := min(run.start + run.page_count * system.PAGE_SIZE, end)
		if low < high {
			count += (high - low) / system.PAGE_SIZE
		}
	}
	return count
}

// report_of gives the report of the process that runs with this name.
report_of :: proc "contextless" (name: string) -> (report: op.Process_Report, found: bool) {
	for slot in 1 ..< u64(64) {
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&report)), size_of(report))
		if report.state != .None && report.state != .Stopped && system.name_of(report.name[:]) == name {
			return report, true
		}
	}
	return {}, false
}

twin_start :: proc "contextless" (name: string, mode: twins.Twin_Mode, table: ^system.Prepared_Modules, page: system.Handle = 0) -> (system.Handle, system.Status) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[twins.VALUE_MODE] = u64(mode)
	if page != 0 {
		grants[twins.GRANT_PAGE] = {page, {.Read, .Write}}
	}
	return system.process_start(system.image_find(image, "twin"), name, grants, random.values_with_seed(&process_generator, values), TWIN_AMOUNTS, nil, table)
}

TWIN_NAMES := [TWIN_COUNT]string{"twin 1", "twin 2", "twin 3", "twin 4"}

// twins_start starts TWIN_COUNT twins that wait. paid is the pages that
// their budgets paid; cycles is the time of one start.
twins_start :: proc "contextless" (processes: ^[TWIN_COUNT]system.Handle, table: ^system.Prepared_Modules) -> (paid: u64, cycles: u64, ok: bool) {
	start := intrinsics.read_cycle_counter()
	for &process, index in processes {
		status: system.Status
		if process, status = twin_start(TWIN_NAMES[index], .Wait, table); status != .Ok {
			system.log(.Info, "frames: cannot start a twin: status ", u64(status))
			return 0, 0, false
		}
	}
	cycles = u64(intrinsics.read_cycle_counter() - start) / TWIN_COUNT
	for name in TWIN_NAMES {
		report, found := report_of(name)
		if !found {
			return 0, 0, false
		}
		paid += TWIN_AMOUNTS.pages - report.budget.pages
	}
	return paid, cycles, true
}

first_use_cases :: proc "contextless" () {
	// The same object, with each frame at creation, then with pages on
	// first use: create, then map.
	start := intrinsics.read_cycle_counter()
	memory, _ := system.memory_create(LARGE_PAGES, 0, {.Frames_Now})
	address, _ := system.memory_map(memory)
	create_now = nanoseconds(u64(intrinsics.read_cycle_counter() - start)) / 1000
	system.memory_unmap(address)
	system.close(memory)

	start = intrinsics.read_cycle_counter()
	memory, _ = system.memory_create(LARGE_PAGES)
	address, _ = system.memory_map(memory)
	create_first_use = nanoseconds(u64(intrinsics.read_cycle_counter() - start)) / 1000
	note("create 8192 pages and map them", present_in(address, LARGE_PAGES) == 0, "no page frame")

	pages := ([^][system.PAGE_SIZE]u8)(address)[:LARGE_PAGES]
	value := intrinsics.volatile_load(&pages[0][100])
	note("read one of them", value == 0 && present_in(address, LARGE_PAGES) == 1, "zero, 1 page frame")

	zero := true
	start = intrinsics.read_cycle_counter()
	for &page in pages[1:] {
		zero &= intrinsics.volatile_load(&page[8]) == 0
		intrinsics.volatile_store(&page[8], 1)
	}
	first_use = nanoseconds(u64(intrinsics.read_cycle_counter() - start)) / (LARGE_PAGES - 1)
	start = intrinsics.read_cycle_counter()
	for &page in pages[1:] {
		intrinsics.volatile_store(&page[16], 2)
	}
	write_present = nanoseconds(u64(intrinsics.read_cycle_counter() - start)) / (LARGE_PAGES - 1)
	note("write each page", zero && present_in(address, LARGE_PAGES) == LARGE_PAGES, u64(LARGE_PAGES), " page frames, zero before")
	system.memory_unmap(address)
	system.close(memory)

	// The budget refuses at creation, never at an access.
	budget, _ := system.budget_create({pages = SMALL_BUDGET})
	_, refused := system.memory_create(2 * SMALL_BUDGET, budget)
	note("create 200 pages with a budget of 100", refused == .No_Budget, "refused at creation")
	count := SMALL_BUDGET - op.memory_list_pages(SMALL_BUDGET)
	memory, _ = system.memory_create(count, budget)
	left, _ := system.budget_read(budget)
	address, _ = system.memory_map(memory) // This process pays for the page tables.
	if address != nil {
		for &page in ([^][system.PAGE_SIZE]u8)(address)[:count] {
			intrinsics.volatile_store(&page[0], 3)
		}
	}
	note("use 99 pages of it, 0 left in it", memory != 0 && left.pages == 0 && present_in(address, count) == count, "each access served")
	system.close(budget) // This budget pays for the memory now.
	system.memory_unmap(address)
	system.close(memory)

	// One page that two processes use: neither touched it before.
	page, _ := system.memory_create(1)
	address, _ = system.memory_map(page)
	word := (^u32)(address)
	twin, status := twin_start("twin", .Write_Page, &prepared, page)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for status == .Ok && intrinsics.volatile_load(word) == 0 && system.time() < deadline {
		system.word_wait(word, 0, deadline)
	}
	note("a twin writes a page that no one used", intrinsics.volatile_load(word) == twins.WORD, "this process reads it")
	system.close(twin)
	system.memory_unmap(address)
	system.close(page)
}

shared_code_cases :: proc "contextless" () {
	processes: [TWIN_COUNT]system.Handle
	// Each twin with its own copy of the module: its budget pays for it.
	own_paid, own_cycles, own_ok := twins_start(&processes, nil)
	for process in processes {
		system.close(process)
	}
	note("4 twins, each with a copy of the module", own_ok, own_paid, " pages")

	// The twins with the shared code: this process pays for it, one time.
	shared_paid, shared_cycles, shared_ok := twins_start(&processes, &prepared)
	// A prepared module has two parts: its code, and its part that is
	// fixed after the load. Each part is a memory object.
	shared_pages: u64
	for item in prepared.modules {
		if item.memory != 0 {
			shared_pages += item.pages
			shared_paid += op.memory_cost(item.pages)
		}
	}
	note("4 twins with the shared code", shared_ok && shared_paid < own_paid, shared_paid, " pages, ", shared_pages, " of them shared")
	start_own, start_shared = nanoseconds(own_cycles) / 1000, nanoseconds(shared_cycles) / 1000

	// A write to the shared code: the kernel stops the twin that writes.
	writer, _ := twin_start("twin 5", .Write_Code, &prepared)
	cause, _, stopped := system.process_stop_wait(writer, system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	// The kernel forgets the stop report with the last handle: read it first.
	vector := system.process_stop_report(writer).vector
	system.close(writer)
	note("a twin writes to its shared code", stopped && cause == .Fault && vector == u32(op.Fault_Kind.Page_Fault), "stopped: page fault")
	running := 0
	for process in processes {
		if state, _, _ := system.process_state(process); state != .Stopped && state != .None {
			running += 1
		}
	}
	note("the 4 other twins", running == TWIN_COUNT, "they still run")
	for process in processes {
		system.close(process)
	}
	system.log(.Info, "frames: 4 twins: ", own_paid, " pages with a copy of the module each, ", shared_paid, " pages with the shared code (", shared_pages, " pages of the module, once)")
}

// The random generator of this process (src/library/support/random).
process_generator: random.Generator

// entry runs each case and each measure once, writes the lines of the
// measures, then keeps the window open until the process is stopped. With
// no random seed (it gives the seed of each twin), it stops with `Refused`;
// with no window, with `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The random generator of this process, from the seed that its starter
	// gave: it gives the seed of each process that this one starts.
	if !random.generator_from_context(&process_generator, ctx) {
		system.log(.Info, "frames: no random seed in the context")
		system.stop(.Refused)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "frames")
	if !ok {
		system.stop(.Failed)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Boot), 0, u64(uintptr(&boot)), size_of(boot))

	first_use_cases()
	shared_code_cases()
	system.log(.Info, "frames: create and map 8192 pages: ", create_now, " us with each frame now, ", create_first_use, " us with pages on first use")
	system.log(.Info, "frames: the first use of a page: ", first_use, " ns; a write to a page that has its frame: ", write_present, " ns")
	system.log(.Info, "frames: start a twin: ", start_own, " us with its own copy of the module, ", start_shared, " us with the shared code")
	wrong: u64
	for item in cases[:case_count] {
		if !item.right {
			wrong += 1
			system.log(.Info, "frames: wrong answer: ", item.text, ": ", item.answer)
		}
	}
	if wrong == 0 {
		system.log(.Info, "frames: ok, ", u64(case_count), " cases")
	}

	for {
		frame := interface.window_frame_start(&window_memory, &window)
		// Each line is a line of a table: its text 3 pixels under its top.
		column := interface.column_of({12, 9, WIDTH - 24, HEIGHT - 9})
		interface.cell_text(&frame, interface.column_take(&column, LINE), "a page gets its frame at its first use; the budget paid at creation.", graphics.colors.dim)
		interface.cell_text(&frame, interface.column_take(&column, LINE), "processes of one module map one memory object for its code.", graphics.colors.dim)
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
		interface.cell_text(&frame, interface.column_take(&column, LINE), system.format(line[:], "create and map 8192 pages: ", create_now, " us with the frames, ", create_first_use, " us without"), graphics.colors.dim)
		interface.cell_text(&frame, interface.column_take(&column, LINE), system.format(line[:], "first use of a page: ", first_use, " ns; a write to a page with its frame: ", write_present, " ns"), graphics.colors.dim)
		interface.cell_text(&frame, interface.column_take(&column, LINE), system.format(line[:], "start a twin: ", start_own, " us with a copy of the module, ", start_shared, " us with the shared code"), graphics.colors.dim)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
