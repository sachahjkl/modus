// A demonstration of the limits of a budget: processor time and log
// records. A process cannot take all the processor time or fill the log:
// each resource has a limit.
//
// The process makes three budgets with a limit of processor time, and one
// thread on each budget. Each thread computes with no end. A fourth thread
// is on the budget of the process. The window shows the processor time
// that each budget used in the last second, against its limit. The budget
// of the process has a limit too, and what the three budgets use counts in
// it. Then the process writes 100 records on the log at once: its budget
// has 40 records for each second.
//
// **What it is for.** It shows that a [limit](term:limit) of a budget holds
// against a process that tries to take more: a thread that never waits
// gets no more than the processor time of its budget in each
// [period](term:period), and a burst of log records past the limit is
// refused with `No_Budget`, so no process fills the log of the others.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("limits")` in the console. The window has one bar for each of the
// four budgets: the processor time that it used in the last second,
// against its limit. The log gets a line of the times used, then
// `limits: ok, 4 budgets within their processor time, <count> log records
// written and <count> refused with <limit> for each second`, or
// `limits: wrong: ...`. The burst writes its records at the level debug.
//
// **Its grants**: none. Its budget from the root service holds 2048 pages,
// 1 process and 5 threads, with a limit of processor time and of log
// records.
//
// **What it does not prove.** The bars are measures: a loaded host gives a
// thread less time than its limit, and the check reads only that no budget
// used more than its limit. Under KVM the kernel does not charge the
// [stolen time](term:stolen-time), so a loaded host does not raise a bar
// past its limit.
package limits

import "base:intrinsics"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import op "modus:contract/operation"
import "modus:system"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module, its threads and its window.
// Its small limits of processor time and of log records are an exception
// of the root service: a request holds no limit in time. 1406 pages, and
// the glyph memory of the copy of the text rendering of the drawing
// module, which draws its text: 354 pages (display.TEXT_MEMORY_PAGES).
// 1406 + 354 = 1760.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1760, processes = 1, threads = 5, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

LINE :: 22
WIDTH :: 640
BAR_X :: 232
BAR_WIDTH :: 380 // Two processors.
BAR_FULL :: 2_000_000
ROW_COUNT :: 4
// Each row has a series color of its own: four threads of one kind.
#assert(ROW_COUNT <= graphics.SERIES_COLOR_COUNT)
// A literal, because the tool counts the pictures of the window from it;
// the assertion keeps it equal to its layout.
HEIGHT :: 354
#assert(HEIGHT == 12 + 3 * LINE + ROW_COUNT * 2 * LINE + 4 * LINE + 12)
INTERVAL :: 1000
BURST :: 100


// One budget: its limit, and what it used in the last interval, for one second.
Row :: struct {
	name:   string,
	budget: system.Handle, // 0: the budget of the process.
	limit:  u64, // Microseconds of processor time in each second.
	before: u64,
	used:   u64,
}

rows := [ROW_COUNT]Row {
	{name = "a thread, 5 %", limit = 50_000},
	{name = "a thread, 20 %", limit = 200_000},
	{name = "a thread, 60 %", limit = 600_000},
	{name = "the process: all"},
}

sink: [ROW_COUNT]u64

compute :: proc "c" (parameter: rawptr) -> ! {
	place := (^u64)(parameter)
	for {
		intrinsics.volatile_store(place, intrinsics.volatile_load(place) + 1)
	}
}

// within says if a budget used no more than its limit. The interval is not
// a whole number of periods of the kernel: one more part of a period can be
// in it.
within :: proc "contextless" (row: Row) -> bool {
	return row.used <= row.limit + row.limit / 5 + 3000
}

// entry writes the burst of 100 log records first and counts the accepted
// and the refused ones; it then makes the three budgets with a limit of
// processor time, starts one thread that computes with no end on each, and
// one on its own budget. Each second it reads the processor time of each
// budget, draws the bars, and writes the summary on the log once. It never
// returns; with no window, it stops with `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "limits")
	if !ok {
		system.stop(.Failed)
	}
	own, _ := system.budget_read()
	rows[ROW_COUNT - 1].limit = own.processor
	log_limit := own.log_records

	// The log: 100 records at once.
	accepted, refused: u64
	text := "limits: one record of the 100"
	for _ in 0 ..< BURST {
		_, status := system.call(.Log, u64(ctx.handles[op.CONTEXT_LOG]), u64(uintptr(raw_data(text))), u64(len(text)), u64(op.Log_Level.Debug), 0)
		if status == .Ok {
			accepted += 1
		} else if status == .No_Budget {
			refused += 1
		}
	}
	_, counted := system.budget_used()
	// The 100 records can be in two seconds of the kernel.
	log_right := accepted + refused == BURST && accepted >= 1 && accepted <= 2 * log_limit && counted == refused

	started := true
	for &row, index in rows {
		if index < ROW_COUNT - 1 {
			status: system.Status
			row.budget, status = system.budget_create({pages = 64, threads = 1, processor = row.limit})
			started &&= status == .Ok
		}
		_, status := system.thread_start(compute, &sink[index], budget = row.budget)
		started &&= status == .Ok
	}
	// A budget cannot have more than the budget that it came from.
	_, above := system.budget_create({processor = own.processor + 1})
	_, zero := system.budget_create({log_records = log_limit + 1})
	rule_right := above == .No_Budget && zero == .No_Budget

	sample := 0
	reported := false
	// The kernel counts processor time with the cycle counter, so the
	// interval is measured with it too. The milliseconds of the time page
	// count ticks, and a tick can come late: the two do not compare.
	per_millisecond := max(system.cycle_frequency() / 1000, 1)
	last := system.cycles()
	for {
		now := system.cycles()
		elapsed := max((now - last) / per_millisecond, 1)
		last = now
		for &row in rows {
			used, _ := system.budget_used(row.budget)
			row.used = (used - row.before) * 1000 / elapsed
			row.before = used
		}
		sample += 1
		// The first sample has no interval. The first interval has the start
		// of the threads: the check, which is an upper limit, counts it, or
		// the first later one where each thread ran. A measure run waits for
		// the next interval, where each thread computes from its start: its
		// line is the time that a budget uses. A loaded host can give a
		// thread no time in one interval; the samples only end a hang.
		each_ran := true
		for row in rows {
			each_ran &&= row.used > 0
		}
		first_counted := system.measure_run() ? 3 : 2
		if !reported && sample >= first_counted && (each_ran || sample >= first_counted + system.TEST_HANG_BOUND_MILLISECONDS / INTERVAL) {
			reported = true
			right := started && log_right && rule_right && each_ran
			for row in rows {
				right &&= within(row)
			}
			system.log_fact(.Info, Processor_Time_Used{first_used = rows[0].used, first_limit = rows[0].limit, second_used = rows[1].used, second_limit = rows[1].limit, third_used = rows[2].used, third_limit = rows[2].limit, process_used = rows[3].used, process_limit = rows[3].limit})
			if right {
				system.log_fact(.Info, Budgets_Within_Limits{accepted = accepted, refused = refused, log_limit = log_limit})
			} else {
				system.log_fact(.Info, Checks_Wrong{threads_started = u64(started), log_right = u64(log_right), rule_right = u64(rule_right)})
			}
		}

		frame := interface.window_frame_start(&window_memory, &window)
		table := frame.table
		y := 12
		interface.draw_text(table, 12, y, "a budget has a limit of processor time for each second.", graphics.colors.dim)
		y += LINE
		interface.draw_text(table, 12, y, "each thread computes with no end: the kernel stops it at the limit.", graphics.colors.dim)
		y += LINE + LINE / 2
		for row, index in rows {
			interface.draw_rectangle(table, 6, y - 4, WIDTH - 12, 2 * LINE - 2, graphics.colors.card_top)
			interface.draw_text(table, 12, y, row.name, graphics.colors.text)
			x := interface.draw_unsigned(table, BAR_X, y, row.used / 1000, sample > 1 && !within(row) ? graphics.colors.failed : graphics.colors.text)
			x = interface.draw_text(table, x, y, " ms used of ", graphics.colors.dim)
			x = interface.draw_unsigned(table, x, y, row.limit / 1000, graphics.colors.text)
			interface.draw_text(table, x, y, " ms in one second", graphics.colors.dim)
			y += LINE
			interface.draw_rectangle(table, BAR_X, y, BAR_WIDTH, 10, graphics.colors.background)
			interface.draw_rectangle(table, BAR_X, y, int(min(row.used, BAR_FULL) * BAR_WIDTH / BAR_FULL), 10, graphics.colors.series[index])
			// The mark of the limit says the number of the limit: the
			// color of that number, the text.
			interface.draw_rectangle(table, BAR_X + int(min(row.limit, BAR_FULL) * BAR_WIDTH / BAR_FULL), y - 3, 2, 16, graphics.colors.text)
			y += LINE
		}
		y += LINE / 2
		interface.draw_text(table, 12, y, "what the three budgets use counts in the budget of the process.", graphics.colors.dim)
		y += LINE
		interface.draw_text(table, 12, y, "a new budget with a higher limit than the process:", graphics.colors.dim)
		interface.draw_text(table, 424, y, rule_right ? "refused: no budget" : "another answer", rule_right ? graphics.colors.process : graphics.colors.failed)
		y += LINE
		line: [96]u8
		interface.draw_text(table, 12, y, system.format(line[:], "100 log records at once, ", log_limit, " for each second:"), graphics.colors.dim)
		interface.draw_text(table, 424, y, system.format(line[:], accepted, " written, ", refused, " refused"), log_right ? graphics.colors.process : graphics.colors.failed)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		// The wait reads the events: the bars, the wheel and the page keys
		// of a window that scrolls draw at once.
		next := system.time() + INTERVAL
		for system.time() < next {
			for _ in interface.window_next_event(&window_memory.drawing, &window) {}
			if interface.window_scroll_frame_take(&window_memory.drawing) {
				break
			}
			_ = display.wait(&window, next)
		}
	}
}
