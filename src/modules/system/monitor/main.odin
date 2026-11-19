// A system tool: the memory of the machine and the processes that run, as a
// picture that changes twice per second. It needs the grant to inspect the machine.
//
// It is also a service: processes(), counts() and count() give the same
// facts as tables of records (exports.odin).
//
// **What it is for.** It shows what the machine does now, from the reports
// of the kernel and not from a process that counts for itself: the memory
// in use and reserved, the kernel entries, the interrupts, the waits of the
// locks of the kernel, three graphs of the last minute (the memory in use,
// the processor time of all the processes, the kernel entries in one
// second), and one row for each process with its pages and its share of the
// processor in the last half second. A bar takes the color of its intensity
// step: the color of what it measures, the warning color from 60 %, and the
// color of a measure near its limit from 85 %. A disk process shows its
// nickname, with the hash prefix of its file faded under it, from the
// [disk process page](term:disk-process-page) of the root service; the log
// has one line for each one: "monitor: the disk process visitor, hash
// prefix 5f0c…, the file 5f0c…, from the root service". The export
// processes() gives the whole hash of the file in the field `hash`.
//
// **Start**: the bar of the desktop, or `start("monitor")` in the console.
// The log has "monitor: ok" after the first picture. From the console,
// `connect("monitor")`, then `monitor.processes()` or
// `monitor.count("free pages")`.
//
// **Grants**, as the root service gives them:
//
// - **Inspect**: the machine with the right Inspect, for the system report
//   and the report of each process. With no such grant, the window says
//   "no grant to inspect the machine" and the log has the same line.
// - **Serve**: its exports, for the console and for the host through the
//   remote service.
//
// With the right Inspect the root service also maps the disk process page,
// read-only: no handle and no right to act.
//
// **What it does not prove**: the share of a process is its processor time
// over the elapsed time of one processor, so a process with several
// threads on several processors shows 100% at most.
package monitor

import process_page "modus:contract/disk_process_page"
import "modus:contract/draw_record"
import op "modus:contract/operation"
import "modus:private/monitor/sample_history"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The window is built with the interface package (docs/INTERFACE.md). The
// text table holds the points of the three graphs too: 2 916 bytes each.
window_memory: interface.Window_Memory(512, 16384)

WIDTH :: 520
// The graphs, the rows of about 16 processes, and one last line that counts
// the processes whose rows do not fit. With its title bar the window stays
// inside a screen of 1080 lines at y = 408, where a machine test puts it.
HEIGHT :: 640
// The sample period: one sample and one picture each 500 ms. The sample
// history of a graph then holds the last minute.
INTERVAL :: 500
LINE :: 20
// The column of the name holds a nickname of a disk process on one line; a
// longer name of a process goes on more lines inside it.
NAME_ROOM :: process_page.NICKNAME_LIMIT * graphics.CELL_WIDTH
PAGES_X :: 10 + NAME_ROOM + 8
BAR_X :: PAGES_X + 68
BAR_WIDTH :: 190
// The share at the right of its bar: "100%" in the font of the cells.
#assert(BAR_X + BAR_WIDTH + 8 + 4 * graphics.CELL_WIDTH <= WIDTH)

PROCESS_SLOTS :: 64

// The graphs of the last minute (src/md/features/monitor_window.md, "The
// sample graphs").
Graph :: enum u8 {
	Memory         = 0, // The pages in use, from 0 to all the pages.
	Processor_Time = 1, // The processor time of all the processes, from 0 to 100 % of every processor.
	Kernel_Entries = 2, // The kernel entries in one second, from 0 to a rounded top.
}
GRAPH_COUNT :: int(max(Graph)) + 1

// Each graph is a box on the grid of points: its edges on multiples of the
// step of the points, so its points are half a step inside each edge. Its
// name and its scale are two lines in the column of the names, at its left.
GRAPH_X :: 9 * graphics.POINT_STEP
GRAPH_WIDTH :: 12 * graphics.POINT_STEP
GRAPH_TOP :: 5 * graphics.POINT_STEP
GRAPH_HEIGHT :: 2 * LINE
GRAPH_PITCH :: 2 * graphics.POINT_STEP
GRAPHS_BOTTOM :: GRAPH_TOP + (GRAPH_COUNT - 1) * GRAPH_PITCH + GRAPH_HEIGHT
#assert(10 + NAME_ROOM <= GRAPH_X && GRAPH_X + GRAPH_WIDTH <= WIDTH - 10)
#assert(GRAPH_HEIGHT < GRAPH_PITCH)
// The stroke of a curve, 2 pixels in units, and the alpha of the area
// under it: the points of the grid show through the area.
GRAPH_STROKE_WIDTH :: 2 * draw_record.UNITS_PER_PIXEL
GRAPH_AREA_ALPHA :: 64

@(rodata)
graph_names := [Graph]string {
	.Memory         = "memory in use",
	.Processor_Time = "processor time",
	.Kernel_Entries = "kernel entries",
}

// The sample history of each graph. The points of each curve are computed
// at each sample, never in a frame.
graphs: [Graph]sample_history.Sample_History
previous_entries: u64

// graph_scale gives the scale of the vertical axis of a graph.
graph_scale :: proc "contextless" (graph: Graph) -> sample_history.Scale {
	switch graph {
	case .Memory, .Processor_Time:
	case .Kernel_Entries:
		return .Rounded_Up
	}
	return .Fixed
}

// graph_color gives the color of the concept of a graph.
graph_color :: proc "contextless" (graph: Graph) -> graphics.Color {
	switch graph {
	case .Memory:
	case .Processor_Time:
		// The share of the processor that processes took: a measure of a
		// process.
		return graphics.colors.process
	case .Kernel_Entries:
		return graphics.colors.kernel
	}
	return graphics.colors.memory
}

// graph_draw draws one graph: its name and the text of its scale in the
// column of the names, the grid of points in its box, its outline, the area
// under its curve and its curve. The points come from its sample history,
// as the last sample left them.
graph_draw :: proc "contextless" (table: ^interface.Draw_Table, graph: Graph) {
	history := &graphs[graph]
	box := history.box
	interface.draw_text(table, 10, box.top, graph_names[graph], graphics.colors.dim)
	scale_y := box.top + LINE
	x := interface.draw_text(table, 10, scale_y, "0 to ", graphics.colors.dim)
	switch graph {
	case .Memory:
		x = interface.draw_unsigned(table, x, scale_y, history.top * system.PAGE_SIZE >> 20, graphics.colors.dim)
		interface.draw_text(table, x, scale_y, " MiB", graphics.colors.dim)
	case .Processor_Time:
		x = interface.draw_unsigned(table, x, scale_y, history.top, graphics.colors.dim)
		interface.draw_text(table, x, scale_y, "%", graphics.colors.dim)
	case .Kernel_Entries:
		buffer: [sample_history.COMPACT_TEXT_SIZE]u8
		x = interface.draw_text(table, x, scale_y, sample_history.compact_number_text(&buffer, history.top), graphics.colors.dim)
		interface.draw_text(table, x, scale_y, " a second", graphics.colors.dim)
	}
	interface.draw_point_grid(table, box.left, box.top, box.width, box.height)
	color := graph_color(graph)
	if history.area_count > 0 {
		interface.draw_path(table, history.area[:history.area_count], draw_record.with_alpha(color, GRAPH_AREA_ALPHA), 0, 0)
	}
	interface.draw_outline(table, box.left, box.top, box.width, box.height, 1, graphics.colors.track)
	if history.stroke_count > 0 {
		interface.draw_path(table, history.stroke[:history.stroke_count], 0, draw_record.opaque(color), GRAPH_STROKE_WIDTH)
	}
}

previous_run_time: [PROCESS_SLOTS]u64
// The process serial, plus one, of the disk process of each slot whose line
// the log has: one line for each disk process, not one at each picture.
logged_disk_process: [PROCESS_SLOTS]u64
disk_processes: ^process_page.Page

// disk_process_log writes one line for each disk process that the monitor
// shows: its nickname, its hash prefix and the whole hash of its file, as
// the root service wrote them in the disk process page. A process that
// stops and starts again in the same slot has another process serial, and
// another line.
disk_process_log :: proc "contextless" (slot: u64, process_serial: u64, nickname: string, row: process_page.Row) {
	// The serial plus one: a slot with no line holds 0, also for a serial 0.
	if slot >= PROCESS_SLOTS || logged_disk_process[slot] == process_serial + 1 {
		return
	}
	logged_disk_process[slot] = process_serial + 1
	prefix: [process_page.HASH_PREFIX_DIGITS]u8
	process_page.hash_prefix_write(&prefix, row.hash[0])
	hash := transmute([process_page.HASH_SIZE]u8)row.hash
	system.log(.Info, "monitor: the disk process ", nickname, ", hash prefix ", string(prefix[:]), ", the file ", system.Hash{hash[:]}, ", from the root service")
}

// The entry of the monitor: it opens its window and its service, then draws
// a picture of the machine every 500 ms and runs the calls between two
// pictures.
//
// With no window it stops with `Failed`. Each turn of the loop:
//
// 1. asks the kernel for the system report, then the report of each
//    process slot that is in use;
// 2. draws the memory bar, the counters, the locks and one row for each
//    process, adds the values of the sample to the sample history of each
//    graph, and draws the graphs; the first picture writes "monitor: ok";
// 3. waits until the next picture, and runs each call of a caller as it
//    comes: a caller never waits for a picture.
//
// The monitor never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "monitor")
	if !ok {
		system.stop(.Failed)
	}
	for graph in Graph {
		// The boxes are constants inside the window: the start refuses none.
		sample_history.sample_history_start(&graphs[graph], graph_scale(graph), {GRAPH_X, GRAPH_TOP + int(graph) * GRAPH_PITCH, GRAPH_WIDTH, GRAPH_HEIGHT})
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	disk_processes = process_page.page_of(ctx)
	service, _ = system.service_open(ctx)
	previous_time: u64
	logged := false
	lost := false
	for {
		report: op.System_Report
		_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
		frame := interface.window_frame_start(&window_memory, &window)
		table := frame.table
		if status != .Ok {
			interface.draw_text(table, 10, 10, "no grant to inspect the machine", graphics.colors.text)
			if !lost {
				system.log(.Info, "monitor: no grant to inspect the machine")
				lost = true
			}
		} else {
			elapsed := max(report.time - previous_time, 1)
			previous_time = report.time
			used := report.page_count - report.free_pages

			y := 10
			x := interface.draw_text(table, 10, y, "memory ", graphics.colors.dim)
			x = interface.draw_unsigned(table, x, y, used * system.PAGE_SIZE >> 20, graphics.colors.text)
			x = interface.draw_text(table, x, y, " / ", graphics.colors.text)
			x = interface.draw_unsigned(table, x, y, report.page_count * system.PAGE_SIZE >> 20, graphics.colors.text)
			x = interface.draw_text(table, x, y, " MiB, reserved ", graphics.colors.text)
			x = interface.draw_unsigned(table, x, y, report.reserved_pages * system.PAGE_SIZE >> 20, graphics.colors.text)
			interface.draw_text(table, x, y, " MiB", graphics.colors.text)
			y += LINE
			interface.draw_rectangle(table, 10, y, WIDTH - 20, 10, graphics.colors.track)
			// The pages in use are memory, in the color of their intensity
			// step.
			memory_step := graphics.intensity_of(used * 100 / max(report.page_count, 1))
			interface.draw_rectangle(table, 10, y, int(u64(WIDTH - 20) * used / max(report.page_count, 1)), 10, graphics.intensity_color(memory_step, graphics.colors.memory, graphics.colors))
			y += LINE
			x = interface.draw_text(table, 10, y, "kernel entries ", graphics.colors.dim)
			interface.draw_unsigned(table, x, y, report.entries, graphics.colors.text)
			y += LINE
			x = interface.draw_text(table, 10, y, "interrupts ", graphics.colors.dim)
			interface.draw_unsigned(table, x, y, report.interrupts, graphics.colors.text)
			y += LINE
			// The locks of the kernel: the waits of all kinds, and the kind
			// that waited most.
			takes, waits, most: u64
			most_kind: op.Lock_Kind
			for kind in op.Lock_Kind {
				count := report.locks[kind]
				takes += count.takes
				waits += count.waits
				if count.waits > most {
					most, most_kind = count.waits, kind
				}
			}
			x = interface.draw_text(table, 10, y, "kernel locks ", graphics.colors.dim)
			x = interface.draw_unsigned(table, x, y, waits, graphics.colors.text)
			x = interface.draw_text(table, x, y, " waits of ", graphics.colors.dim)
			x = interface.draw_unsigned(table, x, y, takes, graphics.colors.text)
			if most != 0 {
				x = interface.draw_text(table, x, y, ", most: ", graphics.colors.dim)
				interface.draw_text(table, x, y, op.LOCK_KIND_NAMES[most_kind], graphics.colors.text)
			}
			// The line of the locks ends above the first graph; the graphs
			// are drawn after the rows, when the sample is whole, and the
			// rows start under them.
			#assert(4 * LINE + 10 + graphics.CELL_HEIGHT <= GRAPH_TOP)
			y = GRAPHS_BOTTOM + 8
			interface.draw_text(table, 10, y, "process", graphics.colors.dim)
			interface.draw_text(table, PAGES_X, y, "pages", graphics.colors.dim)
			interface.draw_text(table, BAR_X, y, "processor", graphics.colors.dim)
			y += LINE

			text_line := interface.line_height({})
			hidden: u64 // The processes whose rows do not fit in the window.
			// The processor time of all the processes since the sample
			// before, for the graph: the processes whose rows do not fit too.
			run_time_total: u64
			for slot in 1 ..< min(report.process_slots, PROCESS_SLOTS) {
				process: op.Process_Report
				system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process))
				if process.state == .None {
					previous_run_time[slot] = 0
					continue
				}
				run_time := process.run_time - min(previous_run_time[slot], process.run_time)
				run_time_total += run_time
				share := min(run_time * 100 / elapsed, 100)
				previous_run_time[slot] = process.run_time
				// A disk process: the nickname and the hash that the root
				// service checked, from its page, by the slot and the serial
				// that the kernel reports. Another process that took the
				// name of a disk process has no row.
				name := system.name_of(process.name[:])
				row, from_disk := process_page.row_find(disk_processes, slot, process.process_serial)
				nickname: process_page.Nickname
				if from_disk {
					nickname = process_page.nickname_of(row.nickname)
					name = process_page.nickname_text(&nickname)
				}
				// One line of the grid of the rows for a row with one line of
				// text; each more line of text adds its height, and the hash
				// prefix of a disk process adds the line of a caption. A row
				// that does not fit above the last line is counted, not cut.
				lines := max(interface.text_wrapped_line_count(table, {}, name, NAME_ROOM), 1)
				row_height := LINE + (lines - 1) * text_line + (from_disk ? interface.line_height(interface.FONT_CAPTION_CELLS) : 0)
				if y + row_height > HEIGHT - LINE {
					hidden += 1
					continue
				}
				name_lines := interface.draw_text_wrapped(table, 10, y, NAME_ROOM, name, graphics.colors.text)
				if from_disk {
					// A value under the name, faded: the caption size in the
					// font of the cells.
					prefix: [process_page.HASH_PREFIX_DIGITS]u8
					process_page.hash_prefix_write(&prefix, row.hash[0])
					interface.draw_text(table, 10, y + name_lines * text_line, string(prefix[:]), graphics.colors.dim, interface.FONT_CAPTION_CELLS)
					disk_process_log(slot, process.process_serial, name, row)
				}
				interface.draw_unsigned(table, PAGES_X, y, process.present_pages, graphics.colors.text)
				interface.draw_rectangle(table, BAR_X, y + 2, BAR_WIDTH, 10, graphics.colors.track)
				// The share of the processor that a process took: a measure
				// of a process, in the color of its intensity step.
				share_color := graphics.intensity_color(graphics.intensity_of(share), graphics.colors.process, graphics.colors)
				interface.draw_rectangle(table, BAR_X, y + 2, int(share) * BAR_WIDTH / 100, 10, share_color)
				x = interface.draw_unsigned(table, BAR_X + BAR_WIDTH + 8, y, share, graphics.colors.text)
				interface.draw_text(table, x, y, "%", graphics.colors.text)
				y += row_height
			}
			if hidden > 0 {
				x = interface.draw_unsigned(table, 10, y, hidden, graphics.colors.text)
				interface.draw_text(table, x, y, " more processes: monitor.processes() gives them", graphics.colors.dim)
			}

			// The sample goes into the sample history of each graph, which
			// computes the points of its curve now, once for each sample.
			entries := report.entries - min(previous_entries, report.entries)
			previous_entries = report.entries
			sample_history.sample_history_push(&graphs[.Memory], used, report.page_count)
			if percent, percent_ok := sample_history.processor_time_percent(run_time_total, elapsed, report.processors); percent_ok {
				sample_history.sample_history_push(&graphs[.Processor_Time], percent, 100)
			}
			if rate, rate_ok := sample_history.rate_per_second(entries, elapsed); rate_ok {
				sample_history.sample_history_push(&graphs[.Kernel_Entries], rate, 0)
			}
			for graph in Graph {
				graph_draw(table, graph)
			}
		}
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		pictures += 1
		if !logged {
			system.log(.Info, "monitor: ok")
			logged = true
		}
		for _ in display.next_event(&window) {}
		// The calls run while the monitor waits for its next picture.
		next := system.time() + INTERVAL
		for {
			wait: system.Wait
			display.wait_events(&wait, &window)
			system.service_wait(&wait, &service)
			now := system.wait_end(&wait, next)
			system.service_run(&service)
			for _ in display.next_event(&window) {}
			if now >= next {
				break
			}
		}
	}
}
