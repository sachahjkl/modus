// A check and a measure of the time page.
//
// The kernel writes the time in one page. Each process has this page and
// can only read it: a process reads the time with one load from memory.
// This process reads the time in the two ways: from the time page, and
// with a kernel entry. It counts the kernel entries of each way. The check
// reads a fixed count of times. In a [measure run](term:measure-run) it
// reads as often as it can for one second, and writes the reads in one
// second.
//
// It checks that the time never goes back, that the two ways give the same
// time, that the milliseconds of the page follow the cycle counter (the
// kernel writes them from it at each tick: a late tick loses no time), and
// that the kernel refuses to remove the time page.
//
// **What it is for.** It shows that the kernel is off the path of a read
// of the time: the [time page](term:time-page) gives the time with one
// load from memory, and one million reads make 0 kernel entries. The read
// with a kernel entry is measured too, for comparison.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("time_page")` in the console. The window shows the two ways: the
// reads of the check and their kernel entries. The log gets one line for
// each way (`time_page: the check of the time page: 1000000 reads, 0
// kernel entries`), the comparison with the cycle counter, then
// `time_page: ok, the time never went back, ...`, or `time_page: wrong:
// ...`. In a measure run (`modustool measure time_page`) the window and the
// log have the reads in one second (`time_page: the time page: <rate> reads
// in one second, 0 kernel
// entries for one million reads`).
//
// **Its grant**: **Inspect**: the machine handle reads the kernel entries
// of this process (its process report), which the measure counts.
//
// **What it does not prove.** The rates are measures of the host of the
// run: no test compares them to a bound.
package time_page

import "modus:display"
import "modus:graphics"
import "modus:interface"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

DURATION :: 1000 // Milliseconds of one measure, in a measure run.
// The reads of the check of each way. A read with a kernel entry costs
// much more than a load from memory, so its count is smaller.
PAGE_READS_CHECKED :: 1_000_000
ENTERED_READS_CHECKED :: 100_000
// The changes of the time page that the check compares with the cycle
// counter: the page is behind by less than one tick just after each one.
PAGE_CHANGES_COMPARED :: 16

LINE :: interface.TABLE_LINE
// The size of the window at its start, and its least size: each text of
// the window fits in this width. The principal can make it larger, up to
// LARGEST_WIDTH by LARGEST_HEIGHT (src/md/features/window_resize.md).
// A literal, because the tool counts the pictures of the window from it;
// the assertion keeps it equal to its layout.
WIDTH :: 816
HEIGHT :: 336
#assert(HEIGHT == 312 + LINE)
LARGEST_WIDTH :: 1216
LARGEST_HEIGHT :: 640

// The tool counts the module, the thread stack and the two pictures of the
// window at its largest size (measured peak at ready 1044 pages for a floor
// of 4481 pages); glyph memory fits inside the floor and a resize draws from
// the growth factor.
MODULE_BUDGET :: system.Stated_Budget{processes = 1, threads = 1, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, window_least_width = WIDTH, window_least_height = HEIGHT}

Measure :: struct {
	name:    string,
	done:    bool,
	reads:   u64, // The reads of the run.
	rate:    u64, // Reads in one second: a measure run only.
	entries: u64, // Kernel entries for one million reads.
}

measures := [2]Measure{{name = "time page"}, {name = "kernel entry"}}
went_back: u64 // The reads that gave a time before the time of the last read.
outside: u64 // The kernel entries whose time was not between two reads of the page around them.
apart_most: u64 // The most milliseconds between those two reads: a measure.
// The milliseconds of the page against system.nanoseconds(), which reads
// the cycle counter: the most that the page was behind, and ahead.
behind, ahead, compared: u64
// The least that the page was behind: just after a tick it is behind by
// less than one tick, however late the ticks come. More is time that the
// page lost. The most that it was behind is only how late a tick came: on
// a machine under another system that is the load of that system.
least: u64 = max(u64)
LEAST_LIMIT :: 1
AHEAD_LIMIT :: 1 // The cycle counters of two processors can differ a little.
refused: bool // The kernel refused to remove the time page.
checked: bool

machine: system.Handle
slot: u64 // The slot of this process in the kernel.

// entries gives the times that this process entered the kernel.
entries :: proc "contextless" () -> u64 {
	report: op.Process_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&report)), size_of(report))
	return report.entries
}

// run reads the time in one way and counts the kernel entries. The check
// ends after reads_checked reads; a measure run reads for DURATION, and
// has the rate.
run :: proc "contextless" (measure: ^Measure, entered: bool, reads_checked: u64) {
	measured := system.measure_run()
	before := entries()
	begin := system.time()
	last := begin
	reads: u64
	for (measured ? last < begin + DURATION : reads < reads_checked) {
		now := entered ? system.time_entered() : system.time()
		if now < last {
			went_back += 1
		}
		last = now
		reads += 1
	}
	// The count of one Inspect call is in the difference: the call of
	// `before` ends before the kernel counts it.
	after := entries() - 1
	measure.reads = reads
	if measured {
		measure.rate = reads * 1000 / max(last - begin, 1)
	}
	measure.entries = (after - before) * 1_000_000 / reads
	measure.done = true
}

// The memory of the interface package for the window (docs/INTERFACE.md).
window_memory: interface.Window_Memory(256, 4096)

// clock_text writes a time since boot as hours:minutes:seconds.milliseconds.
clock_text :: proc "contextless" (builder: ^interface.Text_Builder, milliseconds: u64) -> string {
	builder.count = 0
	seconds := milliseconds / 1000
	interface.text_put_number(builder, seconds / 3600, 2)
	interface.text_put(builder, ":")
	interface.text_put_number(builder, seconds / 60 % 60, 2)
	interface.text_put(builder, ":")
	interface.text_put_number(builder, seconds % 60, 2)
	interface.text_put(builder, ".")
	interface.text_put_number(builder, milliseconds % 1000, 3)
	return interface.text_of(builder)
}

// Part: one part of a sentence, with its color.
Part :: struct {
	text:  string,
	color: graphics.Color,
}

// sentence draws the parts of a sentence one after the other.
sentence :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, parts: ..Part) {
	x := area.x
	for part in parts {
		x = interface.draw_text(frame.table, x, area.y + (area.height - interface.LINE) / 2, part.text, part.color)
	}
}

// draw builds the window with the interface package: a card, the time since
// boot, a table of the two ways with their bars, the checks. The card fills
// the surface, whose size the principal can change: the share column of
// the table takes the width that the window gains.
draw :: proc "contextless" (window: ^display.Window) {
	width, height := window.width, window.height
	frame := interface.window_frame_start(&window_memory, window)
	interface.background(&frame, {0, 0, width, height})
	content := interface.card(&frame, {8, 8, width - 16, height - 16}, "THE TIME PAGE", "Time_Record: one page that each process reads", graphics.colors.kernel)
	column := interface.column_of(content)
	interface.cell_text(&frame, interface.column_take(&column, LINE), "the kernel writes the time in one page. each process reads it: no kernel entry.", graphics.colors.dim)
	builder: interface.Text_Builder
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "since boot", clock_text(&builder, system.time()), graphics.colors.text, 120)
	interface.column_take(&column, 8)

	// The table: the way, its reads, its kernel entries. A measure run
	// has the reads in one second, as a bar and a number; else the number
	// is the count of the reads of the check.
	measured := system.measure_run()
	cells: [4]interface.Area
	sizes := [4]interface.Size{interface.pixels(120), interface.share(), interface.characters(12), interface.characters(20)}
	interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:], 16)
	interface.table_header(&frame, cells[:], {"way", measured ? "reads of the time in one second" : "reads of the time in the check", "", "kernel entries"}, {.Left, .Left, .Right, .Right})
	most: u64
	for measure in measures {
		most = max(most, measure.rate)
	}
	for measure, index in measures {
		line := interface.column_take(&column, LINE)
		interface.table_band(&frame, {line.x - 8, line.y, line.width + 16, line.height}, index)
		interface.row_split(line, sizes[:], cells[:], 16)
		// The time page is memory that the kernel shares; the other way is
		// a kernel entry.
		color := index == 0 ? graphics.colors.memory : graphics.colors.kernel
		interface.cell_text(&frame, cells[0], measure.name, color)
		if !measure.done {
			interface.cell_text(&frame, cells[1], "...", graphics.colors.dim)
			continue
		}
		if measured {
			interface.bar(&frame, {cells[1].x, cells[1].y + 8, cells[1].width, 8}, measure.rate, most, color)
		}
		interface.cell_text(&frame, cells[2], interface.number_text(&builder, measured ? measure.rate : measure.reads), graphics.colors.text, .Right)
		interface.cell_text(&frame, cells[3], interface.number_text(&builder, measure.entries), graphics.colors.text, .Right)
	}
	interface.cell_text(&frame, interface.column_take(&column, LINE), measured ? "kernel entries: for one million reads." : "the reads in one second are a measure: run `modustool measure time_page`.", graphics.colors.dim)
	interface.column_take(&column, 8)
	if checked {
		numbers: [5]interface.Text_Builder
		sentence(&frame, interface.column_take(&column, LINE),
			{"the time went back ", graphics.colors.dim},
			{interface.number_text(&numbers[0], went_back), went_back == 0 ? graphics.colors.text : graphics.colors.failed},
			{" times. a kernel entry was outside two reads of the page ", graphics.colors.dim},
			{interface.number_text(&numbers[1], outside), outside == 0 ? graphics.colors.text : graphics.colors.failed},
			{" times.", graphics.colors.dim})
		sentence(&frame, interface.column_take(&column, LINE),
			{"against the cycle counter, the page was ", graphics.colors.dim},
			{interface.number_text(&numbers[2], least), least <= LEAST_LIMIT ? graphics.colors.text : graphics.colors.failed},
			{" to ", graphics.colors.dim},
			{interface.number_text(&numbers[3], behind), graphics.colors.text},
			{" ms behind and ", graphics.colors.dim},
			{interface.number_text(&numbers[4], ahead), ahead <= AHEAD_LIMIT ? graphics.colors.text : graphics.colors.failed},
			{" ms ahead.", graphics.colors.dim})
		sentence(&frame, interface.column_take(&column, LINE), {refused ? "the kernel refuses to remove the time page of this process." : "the kernel removed the time page.", refused ? graphics.colors.dim : graphics.colors.failed})
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// entry finds its own slot with the machine handle, reads the time in the
// two ways (`run`), compares the two ways and the cycle counter,
// tries to remove the time page, and writes the summary line. It then
// draws the window at each event, and measures the time of a draw. It
// never returns; with no window, it stops with `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "time_page")
	if !ok {
		system.stop(.Failed)
	}
	// The limits are constants of this process that size_limits_of_words
	// takes: a refusal is a fault of this source, which the line says.
	// The ring holds the one record of the surface: a full ring is a fault
	// of the compositor, which the line says too.
	if problem, sent := display.resizable_set(&window, {least_width = WIDTH, least_height = HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT}); problem != .None {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field(display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], 64)})
	} else if !sent {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field("the command ring of the window is full", 64)})
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	for index in 1 ..< report.process_slots {
		process: op.Process_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), index, u64(uintptr(&process)), size_of(process))
		if process.state != .None && process.state != .Stopped && system.name_of(process.name[:]) == "time_page" {
			slot = index
		}
	}
	measured := system.measure_run()
	draw(&window)
	run(&measures[0], false, PAGE_READS_CHECKED)
	draw(&window)
	run(&measures[1], true, ENTERED_READS_CHECKED)
	if measured {
		system.log_fact(.Info, Time_Page_Measured{reads_in_one_second = measures[0].rate, kernel_entries = measures[0].entries})
		system.log_fact(.Info, Kernel_Entry_Measured{reads_in_one_second = measures[1].rate, kernel_entries = measures[1].entries})
	} else {
		// The entries of the check are for its own count of reads.
		system.log_fact(.Info, Time_Page_Checked{reads = measures[0].reads, kernel_entries = measures[0].entries * measures[0].reads / 1_000_000})
		system.log_fact(.Info, Kernel_Entry_Checked{reads = measures[1].reads, kernel_entries = measures[1].entries * measures[1].reads / 1_000_000})
	}

	// The two ways give the same time: a kernel entry between two reads
	// of the page gives a time that is not before the first read and not
	// after the second one. The thread can leave its processor between
	// the reads, for any time: the condition holds then too, so it checks
	// the two ways and not the schedule. The kernel stores its own time
	// just before it stores the page, on the first processor: an entry on
	// another processor between the two stores is ahead of the page, so
	// the second read is repeated until the page caught up. The bound of
	// that wait is on the cycle counter, not on the page, and only ends a
	// hang.
	for _ in 0 ..< 1000 {
		page_before := system.time()
		entered := system.time_entered()
		page_after := system.time()
		for give_up := system.nanoseconds() + system.TEST_HANG_BOUND_MILLISECONDS * 1_000_000; page_after < entered && system.nanoseconds() < give_up; {
			page_after = system.time()
		}
		if entered < page_before || entered > page_after {
			outside += 1
		}
		apart_most = max(apart_most, page_after - page_before)
	}
	system.log_fact(.Info, Page_And_Kernel_Entry{outside = outside, apart_most = apart_most})
	// The page follows the cycle counter: each read of the page is
	// compared with the time that the cycle counter gives now, until the
	// page changed PAGE_CHANGES_COMPARED times. A measure run compares for
	// half a second: how far behind the page was at most is a measure of
	// how late a tick came. The bound is on the cycle counter and only
	// ends a hang: a page that stands still never changes.
	page_changes: u64
	page_last := system.time()
	compare_give_up := system.nanoseconds() + system.TEST_HANG_BOUND_MILLISECONDS * 1_000_000
	for begin := page_last; (measured ? system.time() < begin + DURATION / 2 : page_changes < PAGE_CHANGES_COMPARED) && system.nanoseconds() < compare_give_up; {
		page := system.time()
		if page != page_last {
			page_last = page
			page_changes += 1
		}
		fine := system.nanoseconds() / 1_000_000
		behind = max(behind, fine > page ? fine - page : 0)
		least = min(least, fine > page ? fine - page : 0)
		ahead = max(ahead, page > fine ? page - fine : 0)
		compared += 1
	}
	system.log_fact(.Info, Page_And_Cycle_Counter{compared = compared, least_behind = least, most_behind = behind, most_ahead = ahead})
	refused = system.memory_unmap(rawptr(uintptr(op.TIME_ADDRESS))) != .Succeeded && system.time() != 0
	checked = true
	if slot != 0 && went_back == 0 && outside == 0 && page_changes >= PAGE_CHANGES_COMPARED && least <= LEAST_LIMIT && ahead <= AHEAD_LIMIT && refused && measures[0].entries == 0 {
		system.log_fact(.Info, Clock_Held{})
	} else {
		system.log_fact(.Info, Time_Wrong{went_back = went_back, outside = outside, page_changes = page_changes, least_behind = least, most_ahead = ahead, removal = value_kinds.text_field(refused ? "refuses" : "does not refuse", 24)})
	}
	deadline := system.time()
	// The time of one picture: the mean of ten pictures after the checks
	// (docs/DESIGN.md, section 7).
	drawn, drawn_time: u64
	for {
		start := system.nanoseconds()
		draw(&window)
		if drawn < 10 {
			drawn_time += system.nanoseconds() - start
			drawn += 1
			if drawn == 10 {
				system.log_fact(.Info, Picture_Measured{picture_time = value_kinds.Nanoseconds_As_Microseconds(drawn_time / 10)})
				// One frame where one number changed: the time since boot.
				system.log_fact(.Info, Interface_Measured{records = u64(window_memory.drawing.now.record_count), damage_rectangles = u64(window_memory.drawing.damage.count), build_time = value_kinds.Nanoseconds_As_Microseconds(window_memory.drawing.build_time), difference_time = value_kinds.Nanoseconds_As_Microseconds(window_memory.drawing.difference_time), draw_time = value_kinds.Nanoseconds_As_Microseconds(window_memory.drawing.draw_time)})
			}
		}
		deadline += 100
		display.wait(&window, deadline)
		interface.window_events(&window_memory.drawing, &window)
	}
}
