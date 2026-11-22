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
import "modus:contract/value_kinds"
import op "modus:contract/operation"
import "internal:monitor/sample_history"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:system"

// The window is built with the interface package (docs/INTERFACE.md). The
// text table holds the points of the three graphs too: 2 916 bytes each.
window_memory: interface.Window_Memory(512, 16384)

// The size of the window at its start. Each place in it comes from its
// layout tree (monitor_layout), from the size that the window has now.
WIDTH :: 520
// The graphs, the rows of about 16 processes, and one last line that counts
// the processes whose rows do not fit. With its title bar the window stays
// inside a screen of 1080 lines at y = 408, where a machine test puts it.
HEIGHT :: 640
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (650 pages): its module, its
// stack, its tables and its glyph memory. The tool counts the window at
// the window bound (docs/MODULE_CONTRACT.md, "The budget that a module
// asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1398, window_width = WIDTH, window_height = HEIGHT}
// The sample period: one sample and one picture each 500 ms. The sample
// history of a graph then holds the last minute.
INTERVAL :: 500
LINE :: 20
// The room between the edge of the window and its content.
EDGE :: 10
// The column of the name holds a nickname of a disk process on one line; a
// longer name of a process goes on more lines inside it.
NAME_ROOM :: process_page.NICKNAME_LIMIT * graphics.CELL_WIDTH
// The column of the pages: a count of pages of six digits and its gap.
PAGES_COLUMN :: 68
// The least bar of the share of a process: a bar shorter than it shows no
// step of a share that a reader can tell apart.
BAR_LEAST :: 100
// The share at the right of its bar: "100%" in the font of the cells.
SHARE_COLUMN :: 4 * graphics.CELL_WIDTH
// The height of the memory bar and of the bar of a process.
BAR_HEIGHT :: 10

PROCESS_SLOTS :: 64

// The graphs of the last minute (src/md/features/monitor_window.md, "The
// sample graphs").
Graph :: enum u8 {
	Memory         = 0, // The pages in use, from 0 to all the pages.
	Processor_Time = 1, // The processor time of all the processes, from 0 to 100 % of every processor.
	Kernel_Entries = 2, // The kernel entries in one second, from 0 to a rounded top.
}
GRAPH_COUNT :: int(max(Graph)) + 1

// Each graph is a box on the grid of points: its left, right and top edges
// on multiples of the step of the points, so its points are half a step
// inside each edge. Its name and its scale are two lines in the column of
// the names, at its left. The graph takes the width that the column leaves.
GRAPH_HEIGHT :: 2 * LINE
GRAPH_PITCH :: 2 * graphics.POINT_STEP
#assert(GRAPH_HEIGHT < GRAPH_PITCH)
// The lines of the summary over the graphs, and the edge of the window
// over them, end on the grid of points: the first graph starts on it.
#assert((SUMMARY_LINE_COUNT * LINE + 2 * EDGE) % graphics.POINT_STEP == 0)

// The lines of the summary at the top of the window, from the top.
Summary_Line :: enum u8 {
	Memory         = 0, // The memory in use, of all, and reserved.
	Memory_Bar     = 1, // The bar of the memory in use.
	Kernel_Entries = 2,
	Interrupts     = 3,
	Kernel_Locks   = 4, // The waits of the locks of the kernel.
}
SUMMARY_LINE_COUNT :: int(max(Summary_Line)) + 1

// The columns of the table of the processes, from the left.
Process_Column :: enum u8 {
	Name          = 0, // The name, or the nickname of a disk process with its hash prefix under it.
	Pages         = 1, // The pages of the process.
	Processor_Bar = 2, // The bar of its share of the processor: the column that takes the room left.
	Share         = 3, // The share, in percent.
}

// The places of the parts of the window, from its layout tree.
Monitor_Places :: struct {
	summary:      [Summary_Line]interface.Area,
	graph_names:  [Graph]interface.Area, // The name and the scale of a graph.
	graph_boxes:  [Graph]sample_history.Graph_Box,
	table_header: interface.Area,
	table_rows:   interface.Area, // The rows of the processes, and the last line that counts the rows that do not fit.
	columns:      [Process_Column]layout.Table_Column_Place,
}

// The layout tree of a frame. A global: the tree is too large for the stack.
layout_tree: layout.Box_Tree

// Layout_Builder adds boxes to a tree and keeps the first refusal, so that
// one check after the last box says whether the whole tree was built.
Layout_Builder :: struct {
	tree:   ^layout.Box_Tree,
	status: layout.Box_Status,
}

builder_open :: proc "contextless" (builder: ^Layout_Builder, description: layout.Box_Description) -> layout.Box_Index {
	index, status := layout.box_open(builder.tree, description)
	if builder.status == .Done {
		builder.status = status
	}
	return index
}

builder_add :: proc "contextless" (builder: ^Layout_Builder, description: layout.Box_Description) -> layout.Box_Index {
	index, status := layout.box_add(builder.tree, description)
	if builder.status == .Done {
		builder.status = status
	}
	return index
}

builder_close :: proc "contextless" (builder: ^Layout_Builder) {
	status := layout.box_close(builder.tree)
	if builder.status == .Done {
		builder.status = status
	}
}

// area_of gives the area of the interface package of a box that the
// solver placed.
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// graph_box_of gives the box of a graph inside the place that the layout
// gave it: its left and top edges go up to the next point of the grid, its
// right edge down to the point before, so its points stay on the grid.
graph_box_of :: proc "contextless" (place: interface.Area) -> sample_history.Graph_Box {
	step := graphics.POINT_STEP
	left := (max(place.x, 0) + step - 1) / step * step
	top := (max(place.y, 0) + step - 1) / step * step
	right := max(place.x + place.width, 0) / step * step
	return {left = left, top = top, width = right - left, height = GRAPH_HEIGHT}
}

// monitor_layout gives the places of the window at a size: the summary
// with its lines, the graphs, each with the column of its name, then the
// table of the processes, which takes the height left. The column of the
// bar of the processor takes the width left. ok false: the tree refused a
// box, and the places of the frame before stay.
monitor_layout :: proc "contextless" (width, height: int, tokens: layout.Element_Tokens) -> (result: Monitor_Places, ok: bool) {
	tree := &layout_tree
	if width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = EDGE, .Y = 0}}) != .Done {
		return {}, false
	}
	builder := Layout_Builder{tree = tree}
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, padding = {.X = 0, .Y = EDGE}})
	summary: [Summary_Line]layout.Box_Index
	for line in Summary_Line {
		summary[line] = builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	}
	builder_close(&builder)
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y})
	graph_names, graph_places: [Graph]layout.Box_Index
	for graph in Graph {
		builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.px(GRAPH_PITCH)}, child_axis = .X, gap = tokens.gap})
		graph_names[graph] = builder_add(&builder, {size = {.X = layout.px(NAME_ROOM), .Y = layout.px(2 * LINE)}})
		graph_places[graph] = builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(GRAPH_HEIGHT)}})
		builder_close(&builder)
	}
	builder_close(&builder)
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y})
	header := builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	rows := builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}})
	builder_close(&builder)
	if builder.status != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	for line in Summary_Line {
		result.summary[line] = area_of(tree, summary[line])
	}
	for graph in Graph {
		result.graph_names[graph] = area_of(tree, graph_names[graph])
		result.graph_boxes[graph] = graph_box_of(area_of(tree, graph_places[graph]))
	}
	result.table_header = area_of(tree, header)
	result.table_rows = area_of(tree, rows)
	// Each column but the name and the bar ends with the gap to the next
	// one; the share ends at the edge of the content.
	columns := [Process_Column]layout.Table_Column {
		.Name          = {width = NAME_ROOM + tokens.gap},
		.Pages         = {width = PAGES_COLUMN},
		.Processor_Bar = {weight = 1, least = BAR_LEAST + tokens.gap},
		.Share         = {width = SHARE_COLUMN},
	}
	// The columns in the order of their enum, as the slices that
	// table_columns takes.
	column_count := len(Process_Column)
	column_list := ([^]layout.Table_Column)(&columns)[:column_count]
	column_places := ([^]layout.Table_Column_Place)(&result.columns)[:column_count]
	if layout.table_columns(column_list, column_places, layout.box_of(tree, rows).rect, 0) != .Done {
		return {}, false
	}
	return result, true
}

// The places of the last frame whose layout the tree took.
places: Monitor_Places
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
graph_draw :: proc "contextless" (table: ^interface.Draw_Table, graph: Graph, name_place: interface.Area, tokens: layout.Element_Tokens) {
	history := &graphs[graph]
	box := history.box
	interface.draw_text(table, name_place.x, box.top, graph_names[graph], tokens.text_dim)
	scale_y := box.top + LINE
	x := interface.draw_text(table, name_place.x, scale_y, "0 to ", tokens.text_dim)
	switch graph {
	case .Memory:
		x = interface.draw_unsigned(table, x, scale_y, history.top * system.PAGE_SIZE >> 20, tokens.text_dim)
		interface.draw_text(table, x, scale_y, " MiB", tokens.text_dim)
	case .Processor_Time:
		x = interface.draw_unsigned(table, x, scale_y, history.top, tokens.text_dim)
		interface.draw_text(table, x, scale_y, "%", tokens.text_dim)
	case .Kernel_Entries:
		buffer: [sample_history.COMPACT_TEXT_SIZE]u8
		x = interface.draw_text(table, x, scale_y, sample_history.compact_number_text(&buffer, history.top), tokens.text_dim)
		interface.draw_text(table, x, scale_y, " a second", tokens.text_dim)
	}
	interface.draw_point_grid(table, box.left, box.top, box.width, box.height)
	color := graph_color(graph)
	if history.area_count > 0 {
		interface.draw_path(table, history.area[:history.area_count], draw_record.with_alpha(color, GRAPH_AREA_ALPHA), 0, 0)
	}
	interface.draw_outline(table, box.left, box.top, box.width, box.height, 1, tokens.surface_track)
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
	system.log_fact(.Info, Disk_Process_Shown{file_hash = value_kinds.Hash_Field(hash), hash_prefix = value_kinds.text_field(string(prefix[:]), HASH_PREFIX_FIELD_BYTES), nickname = value_kinds.text_field(nickname, NICKNAME_FIELD_BYTES)})
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
	// A window of its own size always takes its tree: a refusal here
	// leaves the places at zero, and the graphs start at the next frame.
	start_tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
	places, _ = monitor_layout(window.width, window.height, start_tokens)
	for graph in Graph {
		sample_history.sample_history_start(&graphs[graph], graph_scale(graph), places.graph_boxes[graph])
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
		// graphics holds only members of the appearance: the tokens of the
		// standard contrast are the colors that the window drew with before.
		tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
		// The size of the window now: a resize or a new scale moves each
		// place. A box of a graph that is too small for a graph keeps the
		// box before.
		if laid_out, laid_out_ok := monitor_layout(window.width, window.height, tokens); laid_out_ok {
			places = laid_out
		}
		for graph in Graph {
			if !graphs[graph].started {
				sample_history.sample_history_start(&graphs[graph], graph_scale(graph), places.graph_boxes[graph])
			}
			sample_history.sample_history_box_set(&graphs[graph], places.graph_boxes[graph])
		}
		if status != .Ok {
			line := places.summary[.Memory]
			interface.draw_text(table, line.x, line.y, "no grant to inspect the machine", tokens.text)
			if !lost {
				system.log_fact(.Info, No_Inspect_Grant{})
				lost = true
			}
		} else {
			elapsed := max(report.time - previous_time, 1)
			previous_time = report.time
			used := report.page_count - report.free_pages

			line := places.summary[.Memory]
			x := interface.draw_text(table, line.x, line.y, "memory ", tokens.text_dim)
			x = interface.draw_unsigned(table, x, line.y, used * system.PAGE_SIZE >> 20, tokens.text)
			x = interface.draw_text(table, x, line.y, " / ", tokens.text)
			x = interface.draw_unsigned(table, x, line.y, report.page_count * system.PAGE_SIZE >> 20, tokens.text)
			x = interface.draw_text(table, x, line.y, " MiB, reserved ", tokens.text)
			x = interface.draw_unsigned(table, x, line.y, report.reserved_pages * system.PAGE_SIZE >> 20, tokens.text)
			interface.draw_text(table, x, line.y, " MiB", tokens.text)
			bar := places.summary[.Memory_Bar]
			interface.draw_rectangle(table, bar.x, bar.y, bar.width, BAR_HEIGHT, tokens.surface_track)
			// The pages in use are memory, in the color of their intensity
			// step.
			memory_step := graphics.intensity_of(used * 100 / max(report.page_count, 1))
			interface.draw_rectangle(table, bar.x, bar.y, int(u64(bar.width) * used / max(report.page_count, 1)), BAR_HEIGHT, graphics.intensity_color(memory_step, graphics.colors.memory, graphics.colors))
			line = places.summary[.Kernel_Entries]
			x = interface.draw_text(table, line.x, line.y, "kernel entries ", tokens.text_dim)
			interface.draw_unsigned(table, x, line.y, report.entries, tokens.text)
			line = places.summary[.Interrupts]
			x = interface.draw_text(table, line.x, line.y, "interrupts ", tokens.text_dim)
			interface.draw_unsigned(table, x, line.y, report.interrupts, tokens.text)
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
			line = places.summary[.Kernel_Locks]
			x = interface.draw_text(table, line.x, line.y, "kernel locks ", tokens.text_dim)
			x = interface.draw_unsigned(table, x, line.y, waits, tokens.text)
			x = interface.draw_text(table, x, line.y, " waits of ", tokens.text_dim)
			x = interface.draw_unsigned(table, x, line.y, takes, tokens.text)
			if most != 0 {
				x = interface.draw_text(table, x, line.y, ", most: ", tokens.text_dim)
				interface.draw_text(table, x, line.y, op.LOCK_KIND_NAMES[most_kind], tokens.text)
			}
			// The graphs are drawn after the rows, when the sample is whole;
			// the layout puts the table of the rows under them.
			columns := &places.columns
			name_room := max(int(columns[.Name].width) - int(tokens.gap), 1)
			bar_width := max(int(columns[.Processor_Bar].width) - int(tokens.gap), 0)
			header := places.table_header
			interface.draw_text(table, int(columns[.Name].x), header.y, "process", tokens.text_dim)
			interface.draw_text(table, int(columns[.Pages].x), header.y, "pages", tokens.text_dim)
			interface.draw_text(table, int(columns[.Processor_Bar].x), header.y, "processor", tokens.text_dim)
			rows := places.table_rows
			y := rows.y

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
					disk_process_log(slot, process.process_serial, name, row)
				}
				// One line of the grid of the rows for a row with one line of
				// text; each more line of text adds its height, and the hash
				// prefix of a disk process adds the line of a caption. A row
				// that does not fit above the last line of the table is
				// counted, not cut.
				lines := max(interface.text_wrapped_line_count(table, {}, name, name_room), 1)
				row_height := LINE + (lines - 1) * text_line + (from_disk ? interface.line_height(interface.FONT_CAPTION_CELLS) : 0)
				if y + row_height > rows.y + rows.height - LINE {
					hidden += 1
					continue
				}
				name_x := int(columns[.Name].x)
				name_lines := interface.draw_text_wrapped(table, name_x, y, name_room, name, tokens.text)
				if from_disk {
					// A value under the name, faded: the caption size in the
					// font of the cells.
					prefix: [process_page.HASH_PREFIX_DIGITS]u8
					process_page.hash_prefix_write(&prefix, row.hash[0])
					interface.draw_text(table, name_x, y + name_lines * text_line, string(prefix[:]), tokens.text_dim, interface.FONT_CAPTION_CELLS)
				}
				interface.draw_unsigned(table, int(columns[.Pages].x), y, process.present_pages, tokens.text)
				bar_x := int(columns[.Processor_Bar].x)
				interface.draw_rectangle(table, bar_x, y + 2, bar_width, BAR_HEIGHT, tokens.surface_track)
				// The share of the processor that a process took: a measure
				// of a process, in the color of its intensity step.
				share_color := graphics.intensity_color(graphics.intensity_of(share), graphics.colors.process, graphics.colors)
				interface.draw_rectangle(table, bar_x, y + 2, int(share) * bar_width / 100, BAR_HEIGHT, share_color)
				x = interface.draw_unsigned(table, int(columns[.Share].x), y, share, tokens.text)
				interface.draw_text(table, x, y, "%", tokens.text)
				y += row_height
			}
			if hidden > 0 {
				x = interface.draw_unsigned(table, rows.x, y, hidden, tokens.text)
				interface.draw_text(table, x, y, " more processes: monitor.processes() gives them", tokens.text_dim)
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
				graph_draw(table, graph, places.graph_names[graph], tokens)
			}
		}
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		pictures += 1
		if !logged {
			system.log_fact(.Info, Window_Ready{})
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
