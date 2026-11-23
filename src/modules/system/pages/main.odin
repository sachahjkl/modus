// A system tool: what the page tables give, as the kernel reads it from
// the tables themselves.
//
// The top part is the kernel half of the addresses: the direct map, the
// kernel module, and the kernel stacks between their guard pages. The
// bottom part is the half of this process. Each line is a run of pages
// with one protection. No page is both writable and executable.
//
// The process needs the grant to inspect the machine.
//
// **What it is for.** It shows two rules of the memory of the system as the
// processor sees them, not as a document claims them: no page is both
// writable and executable, and each kernel stack has a guard page on each
// side. It also shows whether the processor keeps the kernel out of the
// memory of processes (no execution of it, and no access outside a copy).
//
// **Start**: `start("pages")` in the console, or the bar of the desktop.
//
// **Grants**, as the root service gives them:
//
// - **Inspect**: the machine with the right Inspect, for the report
//   `Inspect_Kind.Mappings` of the kernel half and of the half of this
//   process. The kernel walks the page tables themselves to make it.
//
// **What a reader sees**: the two halves as runs of pages, each with its
// protection, and the rules with a mark each. The log has, once:
//
// - the pages, the runs, the pages that are write and execute, and the
//   guard pages of the kernel half;
// - the same counts for this process;
// - "pages: ok, the page tables keep the rules", or "pages: failed, ...";
// - whether the processor refuses the memory of processes to the kernel.
//
// **What it does not prove**: it reads the tables of one process, its own.
// It shows the state at one moment, every 500 ms; it does not watch each
// change of a mapping.
package pages

import info "modus:contract/boot_info"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

MARGIN :: 12
// The columns of a run, each as wide as its longest text, so that no text
// meets the next column or the edge of the window: the address (16
// characters) and the size (two spaces and 9 characters) after the mark;
// then the rights, at most " read write execute, 2 MiB pages" (32
// characters); then the part of the kernel half, at most "double fault
// stack of processor " and a number of three digits (35 characters).
RIGHTS_X :: MARGIN + 16 + (16 + 2 + 9) * graphics.CELL_WIDTH
PART_X :: RIGHTS_X + (32 + 1) * graphics.CELL_WIDTH
// A literal, so the tool reads the window of the budget; the assertion
// keeps it the width of the layout.
WIDTH :: 800
#assert(WIDTH == PART_X + 35 * graphics.CELL_WIDTH + MARGIN)
HEIGHT :: 668
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (1044 pages): its module, its
// stack, its tables and its glyph memory. And the picture of the logical
// size in which it draws by hand (interface.Hand_Picture): 800 x 668
// pixels of 4 bytes, 522 pages. 1004 + 522 = 1526. The tool counts the
// window at the largest scale (docs/MODULE_CONTRACT.md, "The budget that a
// module asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1526, window_width = WIDTH, window_height = HEIGHT}

// The picture of the window, in its logical pixels: the window draws by
// hand, and the drawing module puts the picture on the screen at the scale
// (interface.Hand_Picture).
hand_picture: interface.Hand_Picture
LINE :: 16
KERNEL_ROWS :: 22
PROCESS_ROWS :: 10
INTERVAL :: 500

// The three protections of a run are a series: three things of one kind
// that no concept of the rules tells apart. The words of each run say its
// protection too.
PROTECTION_EXECUTE :: 0
PROTECTION_WRITE :: 1
PROTECTION_READ :: 2

kernel_half: op.Mapping_Report
process_half: op.Mapping_Report

Text :: struct {
	bytes: [96]u8,
	count: int,
}

put :: proc "contextless" (text: ^Text, part: string) {
	for index in 0 ..< len(part) {
		if text.count < len(text.bytes) {
			text.bytes[text.count] = part[index]
			text.count += 1
		}
	}
}

put_number :: proc "contextless" (text: ^Text, value: u64) {
	digits: [20]u8
	count := 0
	for rest := value; rest != 0 || count == 0; rest /= 10 {
		digits[count] = '0' + u8(rest % 10)
		count += 1
	}
	for count > 0 {
		count -= 1
		put(text, string(digits[count:][:1]))
	}
}

put_hex :: proc "contextless" (text: ^Text, value: u64) {
	characters := "0123456789abcdef"
	for index := 15; index >= 0; index -= 1 {
		put(text, characters[value >> (uint(index) * 4) & 15:][:1])
	}
}

// put_size adds a count of pages as a size, in 9 characters.
put_size :: proc "contextless" (text: ^Text, page_count: u64) {
	start := text.count
	kib := page_count * 4
	switch {
	case kib < 1024:
		put_number(text, kib)
		put(text, " KiB")
	case kib < 1024 * 1024:
		put_number(text, kib >> 10)
		put(text, ".")
		put_number(text, (kib & 1023) * 10 >> 10)
		put(text, " MiB")
	case:
		put_number(text, kib >> 20)
		put(text, ".")
		put_number(text, (kib & (1 << 20 - 1)) * 10 >> 20)
		put(text, " GiB")
	}
	for text.count < start + 9 {
		put(text, " ")
	}
}

show :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: ^Text, color: graphics.Color) -> int {
	after := graphics.text(canvas, x, y, string(text.bytes[:text.count]), color)
	text.count = 0
	return after
}

// part says which part of the kernel half holds an address.
part :: proc "contextless" (text: ^Text, address: u64) {
	slot_size :: u64(op.KERNEL_STACK_SLOT_PAGES * info.PAGE_SIZE)
	switch {
	case address >= u64(info.KERNEL_BASE):
		put(text, "kernel module")
	case address >= op.KERNEL_STACK_BASE:
		page := (address - op.KERNEL_STACK_BASE) % slot_size / info.PAGE_SIZE
		switch page {
		case 1:
			put(text, "stack of processor ")
		case 2 + op.KERNEL_STACK_PAGES:
			put(text, "double fault stack of processor ")
		case:
			put(text, "interrupt stack of processor ")
		}
		put_number(text, (address - op.KERNEL_STACK_BASE) / slot_size)
	case address >= u64(info.DIRECT_MAP_BASE):
		put(text, "direct map")
	}
}

// half draws the runs of one report from line `line`, and gives the next line.
half :: proc "contextless" (canvas: graphics.Canvas, line: int, title: string, report: ^op.Mapping_Report, rows: int, kernel: bool) -> int {
	line := line
	text: Text
	y := MARGIN + line * LINE
	// The title of a half in the color of its concept: the kernel or a
	// process.
	accent := kernel ? graphics.colors.kernel : graphics.colors.process
	graphics.fill(canvas, MARGIN, y, WIDTH - 2 * MARGIN, 2, accent)
	x := graphics.text(canvas, MARGIN, y + 6, title, accent)
	put(&text, "  ")
	put_number(&text, report.pages)
	put(&text, " pages, ")
	put_number(&text, report.execute_pages)
	put(&text, " of code, ")
	put_number(&text, report.run_count)
	put(&text, " runs")
	show(canvas, x, y + 6, &text, graphics.colors.dim)
	line += 2
	shown := min(int(report.run_count), rows, op.MAPPING_RUN_CAPACITY)
	for run, index in report.runs[:shown] {
		y = MARGIN + line * LINE
		color := graphics.colors.series[PROTECTION_READ]
		switch {
		case .Execute in run.flags:
			color = graphics.colors.series[PROTECTION_EXECUTE]
		case .Write in run.flags:
			color = graphics.colors.series[PROTECTION_WRITE]
		}
		// A place with no page before a kernel stack is a guard: an access
		// there fails, so its mark has the color of a failure.
		if kernel && run.start >= op.KERNEL_STACK_BASE && run.start < u64(info.KERNEL_BASE) {
			graphics.fill(canvas, MARGIN, y, 8, 3, graphics.colors.failed)
			if index + 1 == shown || report.runs[index + 1].start >= u64(info.KERNEL_BASE) {
				graphics.fill(canvas, MARGIN, y + LINE - 3, 8, 3, graphics.colors.failed)
			}
		}
		graphics.fill(canvas, MARGIN, y + 4, 8, 8, color)
		put_hex(&text, run.start)
		put(&text, "  ")
		put_size(&text, run.page_count)
		x = show(canvas, MARGIN + 16, y, &text, graphics.colors.text)
		put(&text, " read")
		if .Write in run.flags {
			put(&text, " write")
		}
		if .Execute in run.flags {
			put(&text, " execute")
		}
		if .Large in run.flags {
			put(&text, ", 2 MiB pages")
		}
		show(canvas, x, y, &text, color)
		if kernel {
			part(&text, run.start)
			show(canvas, PART_X, y, &text, graphics.colors.dim)
		}
		line += 1
	}
	if int(report.run_count) > shown {
		put(&text, "and ")
		put_number(&text, report.run_count - u64(shown))
		put(&text, " more runs")
		show(canvas, MARGIN + 16, MARGIN + line * LINE, &text, graphics.colors.dim)
		line += 1
	}
	return line
}

rule :: proc "contextless" (canvas: graphics.Canvas, line: int, kept: bool, text: ^Text) {
	y := MARGIN + line * LINE
	graphics.fill(canvas, MARGIN, y + 4, 8, 8, kept ? graphics.colors.process : graphics.colors.failed)
	show(canvas, MARGIN + 16, y, text, kept ? graphics.colors.text : graphics.colors.failed)
}

draw :: proc "contextless" (canvas: graphics.Canvas) {
	graphics.clear(canvas, graphics.colors.background)
	text: Text
	line := half(canvas, 0, "the kernel half", &kernel_half, KERNEL_ROWS, true)
	line += 1
	put(&text, "write and execute: ")
	put_number(&text, kernel_half.write_execute_pages + process_half.write_execute_pages)
	put(&text, " pages")
	rule(canvas, line, kernel_half.write_execute_pages + process_half.write_execute_pages == 0, &text)
	put(&text, "guard pages around the kernel stacks: ")
	put_number(&text, kernel_half.guard_pages)
	put(&text, " of ")
	put_number(&text, kernel_half.guards_expected)
	rule(canvas, line + 1, kernel_half.guard_pages == kernel_half.guards_expected, &text)
	put(&text, kernel_half.kernel_no_execute != 0 ? "the kernel cannot execute memory of processes" : "the kernel can execute memory of processes: the processor has no guard")
	rule(canvas, line + 2, kernel_half.kernel_no_execute != 0, &text)
	put(&text, kernel_half.kernel_guard != 0 ? "the kernel cannot use memory of processes outside a copy" : "the kernel can use memory of processes: the processor has no guard")
	rule(canvas, line + 3, kernel_half.kernel_guard != 0, &text)
	half(canvas, line + 5, "the half of this process", &process_half, PROCESS_ROWS, false)
}

// The entry of pages: every 500 ms it reads the two mapping reports and
// draws them, and the first time it writes the result on the log.
//
// With no window it stops with `Failed`. It never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "pages")
	if !ok || interface.hand_picture_open(&hand_picture, &window) != .Ok {
		system.stop(.Failed)
	}
	machine := ctx.handles[system.GRANT_MACHINE]
	logged := false
	for {
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Mappings), 0, u64(uintptr(&kernel_half)), size_of(op.Mapping_Report))
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Mappings), 1, u64(uintptr(&process_half)), size_of(op.Mapping_Report))
		// The canvas is the picture that the compositor does not read,
		// after it took the picture before: the whole canvas is drawn.
		if display.canvas_wait(&window) {
			draw(hand_picture.canvas)
			interface.hand_picture_show(&hand_picture, &window)
		}
		if !logged {
			logged = true
			system.log_fact(.Info, Kernel_Half_Read{mapped = value_kinds.Size_In_Pages(kernel_half.pages), runs = u64(kernel_half.run_count), write_execute_pages = u64(kernel_half.write_execute_pages), guard_pages = u64(kernel_half.guard_pages), guards_expected = u64(kernel_half.guards_expected)})
			system.log_fact(.Info, Process_Half_Read{mapped = value_kinds.Size_In_Pages(process_half.pages), runs = u64(process_half.run_count), write_execute_pages = u64(process_half.write_execute_pages)})
			kept := kernel_half.pages != 0 && process_half.pages != 0 && kernel_half.write_execute_pages == 0 && process_half.write_execute_pages == 0 && kernel_half.guard_pages == kernel_half.guards_expected && kernel_half.guards_expected != 0
			guards := kernel_half.kernel_no_execute != 0 && kernel_half.kernel_guard != 0
			// Each verdict is two sentences: each one is a fact type.
			if kept {
				system.log_fact(.Info, Rules_Kept{})
			} else {
				system.log_fact(.Info, Rules_Not_Kept{})
			}
			if guards {
				system.log_fact(.Info, Kernel_Guard_Present{})
			} else {
				system.log_fact(.Info, Kernel_Guard_Absent{})
			}
		}
		for _ in display.next_event(&window) {}
		system.sleep(system.time() + INTERVAL)
	}
}
