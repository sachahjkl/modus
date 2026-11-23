// A system tool: the memory of the machine and the processes that run, as a
// picture that changes twice per second. It needs the grant to inspect the machine.
//
// It is also a service: processes(), counts() and count() give the same
// facts as tables of records (exports.odin).
//
// **What it is for.** It shows what the machine does now, from the reports
// of the kernel and not from a process that counts for itself. Three metric
// cards at the top: the memory in use, of all and reserved; the processor
// time of all the processes, the processes and the processors; the kernel
// entries, the interrupts and the waits of the locks of the kernel. Under
// them, three graph cards of the last minute (the memory in use, the
// processor time of all the processes, the kernel entries in one second),
// each with its value now and its peak. Last, the table of the processes:
// one row for each process with its pages and its share of the processor in
// the last half second. A gauge takes the color of its intensity step: the
// color of what it measures, the warning color from 60 %, and the color of
// a measure near its limit from 85 %. A disk process shows its nickname,
// with the hash prefix of its file faded under it, from the
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
// A frame draws about 260 records: the seven cards, the texts and gauges of
// the metric cards, the plots, and about eight records for each row.
window_memory: interface.Window_Memory(512, 16384)

// The size of the window at its start. Each place in it comes from its
// layout tree (monitor_layout), from the size that the window has now.
WIDTH :: 520
// The metric cards, the graph cards, and the table of the processes with
// about eleven rows and one last line that counts the processes whose rows
// do not fit. With its title bar the window stays inside a screen of 1080
// lines at y = 408, where a machine test puts it.
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
// The room between the edge of the window and the cards, and between two
// cards: the gap token, so the cards line up with the other windows.
EDGE :: graphics.GAP
// The accent rail at the left of each card, in the color of its concept.
CARD_RAIL :: 3
// From the left or right edge of a card to its content: the rail and room.
CARD_INSET :: CARD_RAIL + 10
// The top edge of a card: a white line at this alpha, a bevel on the dark
// surface. On the light card, white on near white, it shows nothing.
CARD_BEVEL_ALPHA :: 28
// The column of the name holds a nickname of a disk process on one line; a
// longer name of a process goes on more lines inside it.
NAME_ROOM :: process_page.NICKNAME_LIMIT * graphics.CELL_WIDTH
// The column of the resident pages: a count of pages of six digits and its
// gap, or its title and its gap when the title is wider. The title is the
// name of the field of the record Process that the column shows, so the
// window and monitor.processes() name one value with one word.
RESIDENT_NUMBER_ROOM :: 68
RESIDENT_TITLE :: "resident"
// The least bar of the share of a process: a bar shorter than it shows no
// step of a share that a reader can tell apart.
BAR_LEAST :: 100
// The share at the right of its bar: "100%" in the font of the cells.
SHARE_COLUMN :: 4 * graphics.CELL_WIDTH
// The height of the bar of a process, in the middle of its row.
ROW_BAR_HEIGHT :: 6
// The gauge of a metric card, cut into equal segments by thin lines of the
// card, so a reader counts tenths.
GAUGE_HEIGHT :: 6
GAUGE_SEGMENTS :: 10
// The light line on the top edge of the full part of a gauge.
GAUGE_HIGHLIGHT_ALPHA :: 70
// A zebra band of the table: the recess at this alpha, on every second row.
ZEBRA_ALPHA :: 150

PROCESS_SLOTS :: 64

// The title of a card, and the one number of a metric card.
FONT_CARD_TITLE :: interface.Font{kind = .Interface, size = graphics.TEXT_CAPTION * interface.TEXT_SIZE_UNITS, weight = .Bold}
FONT_METRIC :: interface.Font{size = graphics.TEXT_LARGE * interface.TEXT_SIZE_UNITS, weight = .Bold}

// The metric cards at the top, from the left.
Metric :: enum u8 {
	Memory    = 0, // The memory in use, of all, and reserved.
	Processor = 1, // The processor time of all the processes, the processes, the processors.
	Kernel    = 2, // The kernel entries, the interrupts, the waits of the locks of the kernel.
}

// The lines of a metric card, from the top.
Metric_Line :: enum u8 {
	Title         = 0, // The name of the measure, in its color.
	Value         = 1, // The one number of the card.
	Detail        = 2, // The fact that gives the number its scale.
	Second_Detail = 3, // A second fact, fainter.
	Gauge         = 4, // The segmented gauge.
}
METRIC_PADDING :: 8
METRIC_LINE_GAP :: 2

// metric_line_height gives the height of a line of a metric card: the line
// of its font, or the gauge.
metric_line_height :: proc "contextless" (line: Metric_Line) -> i32 {
	switch line {
	case .Title, .Detail, .Second_Detail:
		return graphics.TEXT_CAPTION
	case .Value:
		return graphics.TEXT_LARGE
	case .Gauge:
	}
	return GAUGE_HEIGHT
}

@(rodata)
metric_titles := [Metric]string {
	.Memory    = "MEMORY",
	.Processor = "PROCESSOR",
	.Kernel    = "KERNEL",
}

// The graphs of the last minute (src/md/features/monitor_window.md, "The
// sample graphs").
Graph :: enum u8 {
	Memory         = 0, // The pages in use, from 0 to all the pages.
	Processor_Time = 1, // The processor time of all the processes, from 0 to 100 % of every processor.
	Kernel_Entries = 2, // The kernel entries in one second, from 0 to a rounded top.
}
GRAPH_COUNT :: int(max(Graph)) + 1

// A graph card: a header line with the name, the scale, the value now and
// the peak, then the plot.
GRAPH_HEADER_HEIGHT :: 20
GRAPH_HEIGHT :: 2 * LINE
GRAPH_CARD_PADDING :: 4
// The plot has a line at each quarter of its height.
GRAPH_GRID_PARTS :: 4
GRAPH_GRID_ALPHA :: 150

// The table card: its title line, the band of the column titles, the rows.
TABLE_TITLE_HEIGHT :: 22
TABLE_CARD_PADDING :: 4

// The columns of the table of the processes, from the left.
Process_Column :: enum u8 {
	Name          = 0, // The name, or the nickname of a disk process with its hash prefix under it.
	Resident      = 1, // The resident pages of the process: its mapped pages that have a page frame.
	Processor_Bar = 2, // The bar of its share of the processor: the column that takes the room left.
	Share         = 3, // The share, in percent.
}

// The places of the parts of the window, from its layout tree.
Monitor_Places :: struct {
	metric_cards:  [Metric]interface.Area,
	metric_lines:  [Metric][Metric_Line]interface.Area,
	graph_cards:   [Graph]interface.Area,
	graph_headers: [Graph]interface.Area, // The name, the scale, the value now and the peak of a graph.
	graph_boxes:   [Graph]sample_history.Graph_Box,
	table_card:    interface.Area,
	table_title:   interface.Area,
	table_header:  interface.Area,
	table_rows:    interface.Area, // The rows of the processes, and the last line that counts the rows that do not fit.
	columns:       [Process_Column]layout.Table_Column_Place,
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

// monitor_layout gives the places of the window at a size: the row of the
// three metric cards, the three graph cards, then the table card, which
// takes the height left. The column of the bar of the processor takes the
// width left. ok false: the tree refused a box, and the places of the
// frame before stay.
monitor_layout :: proc "contextless" (width, height: int, tokens: layout.Element_Tokens) -> (result: Monitor_Places, ok: bool) {
	tree := &layout_tree
	if width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = EDGE, .Y = EDGE}, gap = EDGE}) != .Done {
		return {}, false
	}
	builder := Layout_Builder{tree = tree}
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .X, gap = EDGE})
	metric_cards: [Metric]layout.Box_Index
	metric_lines: [Metric][Metric_Line]layout.Box_Index
	for metric in Metric {
		metric_cards[metric] = builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, padding = {.X = CARD_INSET, .Y = METRIC_PADDING}, gap = METRIC_LINE_GAP})
		for line in Metric_Line {
			metric_lines[metric][line] = builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(metric_line_height(line))}})
		}
		builder_close(&builder)
	}
	builder_close(&builder)
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, gap = EDGE})
	graph_cards, graph_headers, graph_places: [Graph]layout.Box_Index
	for graph in Graph {
		graph_cards[graph] = builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, padding = {.X = CARD_INSET, .Y = GRAPH_CARD_PADDING}})
		graph_headers[graph] = builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(GRAPH_HEADER_HEIGHT)}})
		graph_places[graph] = builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(GRAPH_HEIGHT)}})
		builder_close(&builder)
	}
	builder_close(&builder)
	table_card := builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y, padding = {.X = CARD_INSET, .Y = TABLE_CARD_PADDING}})
	title := builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(TABLE_TITLE_HEIGHT)}})
	header := builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	rows := builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}})
	builder_close(&builder)
	if builder.status != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	for metric in Metric {
		result.metric_cards[metric] = area_of(tree, metric_cards[metric])
		for line in Metric_Line {
			result.metric_lines[metric][line] = area_of(tree, metric_lines[metric][line])
		}
	}
	for graph in Graph {
		result.graph_cards[graph] = area_of(tree, graph_cards[graph])
		result.graph_headers[graph] = area_of(tree, graph_headers[graph])
		place := area_of(tree, graph_places[graph])
		result.graph_boxes[graph] = {left = place.x, top = place.y, width = place.width, height = place.height}
	}
	result.table_card = area_of(tree, table_card)
	result.table_title = area_of(tree, title)
	result.table_header = area_of(tree, header)
	result.table_rows = area_of(tree, rows)
	// Each column but the name and the bar ends with the gap to the next
	// one; the share ends at the edge of the content.
	columns := [Process_Column]layout.Table_Column {
		.Name          = {width = NAME_ROOM + tokens.gap},
		.Resident      = {width = max(RESIDENT_NUMBER_ROOM, i32(interface.text_width(interface.FONT_CAPTION, RESIDENT_TITLE)) + tokens.gap)},
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
// under it.
GRAPH_STROKE_WIDTH :: 2 * draw_record.UNITS_PER_PIXEL
GRAPH_AREA_ALPHA :: 64

// The title of each graph card: in capital letters, as the title of each
// card (docs/DESIGN.md, "5. Text").
@(rodata)
graph_titles := [Graph]string {
	.Memory         = "MEMORY IN USE",
	.Processor_Time = "PROCESSOR TIME",
	.Kernel_Entries = "KERNEL ENTRIES",
}

// The sample history of each graph. The points of each curve are computed
// at each sample, never in a frame.
graphs: [Graph]sample_history.Sample_History
// The largest value of each sample history, found at each push: a frame
// reads it and computes nothing over the samples.
graph_peaks: [Graph]u64
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

// metric_color gives the color of the concept of a metric card.
metric_color :: proc "contextless" (metric: Metric) -> graphics.Color {
	switch metric {
	case .Memory:
	case .Processor:
		return graphics.colors.process
	case .Kernel:
		return graphics.colors.kernel
	}
	return graphics.colors.memory
}

// graph_push adds the value of a sample to the history of a graph, then
// finds its peak: one pass over the kept values, once for each sample.
graph_push :: proc "contextless" (graph: Graph, value, fixed_top: u64) {
	history := &graphs[graph]
	if !sample_history.sample_history_push(history, value, fixed_top) {
		return
	}
	peak: u64
	for index in 0 ..< history.count {
		peak = max(peak, sample_history.value_at(history, index))
	}
	graph_peaks[graph] = peak
}

// value_text_of writes a value of a graph in the unit of its scale: MiB
// for the memory, percent for the processor time, a compact number for a
// rate.
value_text_of :: proc "contextless" (builder: ^interface.Text_Builder, graph: Graph, value: u64) {
	switch graph {
	case .Memory:
		interface.text_put_number(builder, value * system.PAGE_SIZE >> 20)
		interface.text_put(builder, " MiB")
	case .Processor_Time:
		interface.text_put_number(builder, value)
		interface.text_put(builder, "%")
	case .Kernel_Entries:
		buffer: [sample_history.COMPACT_TEXT_SIZE]u8
		interface.text_put(builder, sample_history.compact_number_text(&buffer, value))
	}
}

// card_draw draws the surface of a card: the border of 1 pixel in its
// accent, darker at the bottom (docs/DESIGN.md, "3. Surfaces"), the
// gradient of the card, a light top edge, and the accent rail at its left.
// The rail takes the place of the bar before the title of a card: a card
// of a measure shows its concept along its whole height.
card_draw :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area, accent: graphics.Color) {
	if area.width <= 2 * CARD_RAIL || area.height <= 2 {
		return
	}
	border_top, border_bottom := graphics.card_border_colors(accent, graphics.appearance)
	interface.draw_vertical_gradient(table, area.x, area.y, area.width, area.height, border_top, border_bottom)
	interface.draw_vertical_gradient(table, area.x + 1, area.y + 1, area.width - 2, area.height - 2, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_rectangle_with_alpha(table, area.x + CARD_RAIL, area.y + 1, area.width - CARD_RAIL - 1, 1, draw_record.with_alpha(graphics.COLOR_WHITE, CARD_BEVEL_ALPHA))
	interface.draw_rectangle(table, area.x, area.y, CARD_RAIL, area.height, accent)
}

// gauge_draw draws a value against a maximum on the track, in the color of
// its intensity step, with a light line on the top edge of the full part.
// A segmented gauge is cut in tenths by lines of the card.
gauge_draw :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area, value, maximum: u64, concept: graphics.Color, tokens: layout.Element_Tokens, segmented: bool) {
	if area.width <= 0 || area.height <= 0 {
		return
	}
	interface.draw_rectangle(table, area.x, area.y, area.width, area.height, tokens.surface_track)
	// The product of a value and a width must not wrap: a value and its
	// maximum lose their low bits together until the maximum fits in 32
	// bits, and a width is under 2^20 pixels.
	most := max(maximum, 1)
	shown := min(value, most)
	for most >= 1 << 32 {
		shown, most = shown >> 1, most >> 1
	}
	width := clamp(area.width, 0, 1 << 20)
	full := int(shown * u64(width) / most)
	color := graphics.intensity_color(graphics.intensity_of(shown * 100 / most), concept, graphics.colors)
	if full > 0 {
		interface.draw_rectangle(table, area.x, area.y, full, area.height, color)
		interface.draw_rectangle_with_alpha(table, area.x, area.y, full, 1, draw_record.with_alpha(graphics.COLOR_WHITE, GAUGE_HIGHLIGHT_ALPHA))
	}
	if segmented {
		for segment in 1 ..< GAUGE_SEGMENTS {
			interface.draw_rectangle(table, area.x + width * segment / GAUGE_SEGMENTS, area.y, 1, area.height, tokens.surface_card)
		}
	}
}

// text_choice_draw draws the first text of a list that fits the width of
// an area: the longest form first, then shorter ones. A text is never cut;
// when none fits, nothing is drawn.
text_choice_draw :: proc "contextless" (table: ^interface.Draw_Table, area: interface.Area, texts: []string, color: graphics.Color, font: interface.Font) {
	for text in texts {
		if text != "" && interface.text_measured_width(table, font, text) <= area.width {
			interface.draw_text(table, area.x, area.y, text, color, font)
			return
		}
	}
}

// The forms of the second detail of a metric card, the longest first.
SECOND_DETAIL_FORMS :: 3

// The texts of one metric card for one frame.
Metric_Texts :: struct {
	value:          interface.Text_Builder,
	detail:         interface.Text_Builder,
	second_details: [SECOND_DETAIL_FORMS]interface.Text_Builder,
}

// metric_card_draw draws the content of a metric card: its title in the
// color of its concept, its number, its two details and its gauge.
metric_card_draw :: proc "contextless" (table: ^interface.Draw_Table, metric: Metric, texts: ^Metric_Texts, gauge_value, gauge_maximum: u64, tokens: layout.Element_Tokens) {
	lines := &places.metric_lines[metric]
	color := metric_color(metric)
	text_choice_draw(table, lines[.Title], {metric_titles[metric]}, color, FONT_CARD_TITLE)
	text_choice_draw(table, lines[.Value], {interface.text_of(&texts.value)}, tokens.text_strong, FONT_METRIC)
	text_choice_draw(table, lines[.Detail], {interface.text_of(&texts.detail)}, tokens.text, interface.FONT_CAPTION)
	forms: [SECOND_DETAIL_FORMS]string
	for &form, index in forms {
		form = interface.text_of(&texts.second_details[index])
	}
	text_choice_draw(table, lines[.Second_Detail], forms[:], tokens.text_dim, interface.FONT_CAPTION)
	gauge_draw(table, lines[.Gauge], gauge_value, gauge_maximum, color, tokens, true)
}

// graph_draw draws the content of a graph card. In its header: the name,
// the text of its scale, its value now in the color of its concept and its
// peak. In its plot: the recess, a line at each quarter, the area under
// its curve and its curve. The points come from its sample history, as the
// last sample left them.
graph_draw :: proc "contextless" (table: ^interface.Draw_Table, graph: Graph, header: interface.Area, tokens: layout.Element_Tokens) {
	history := &graphs[graph]
	box := history.box
	color := graph_color(graph)
	text_y := header.y + (GRAPH_HEADER_HEIGHT - graphics.LINE_HEIGHT) / 2
	caption_y := interface.text_top_on_baseline(table, interface.FONT_BOLD, text_y, interface.FONT_CAPTION)
	left_end := interface.draw_text(table, header.x, caption_y, graph_titles[graph], color, FONT_CARD_TITLE)
	scale: interface.Text_Builder
	interface.text_put(&scale, "0 to ")
	value_text_of(&scale, graph, history.top)
	if graph == .Kernel_Entries {
		interface.text_put(&scale, " a second")
	}
	scale_text := interface.text_of(&scale)
	scale_x := left_end + graphics.GAP
	if scale_x + interface.text_measured_width(table, interface.FONT_CAPTION, scale_text) <= header.x + header.width {
		left_end = interface.draw_text(table, scale_x, caption_y, scale_text, tokens.text_dim, interface.FONT_CAPTION)
	}
	// The value now and the peak, from the right: each is drawn only when
	// it stays clear of the texts at the left.
	if history.count > 0 {
		now: interface.Text_Builder
		value_text_of(&now, graph, sample_history.value_at(history, history.count - 1))
		now_text := interface.text_of(&now)
		right := header.x + header.width
		now_width := interface.text_measured_width(table, interface.FONT_BOLD, now_text)
		if right - now_width >= left_end + graphics.GAP {
			interface.draw_text_right(table, right, text_y, now_text, color, interface.FONT_BOLD)
			peak: interface.Text_Builder
			interface.text_put(&peak, "peak ")
			value_text_of(&peak, graph, graph_peaks[graph])
			peak_text := interface.text_of(&peak)
			peak_right := right - now_width - 2 * graphics.GAP
			if peak_right - interface.text_measured_width(table, interface.FONT_CAPTION, peak_text) >= left_end + graphics.GAP {
				interface.draw_text_right(table, peak_right, caption_y, peak_text, tokens.text_dim, interface.FONT_CAPTION)
			}
		}
	}
	interface.draw_rectangle(table, box.left, box.top, box.width, box.height, tokens.surface_recess)
	for part in 1 ..< GRAPH_GRID_PARTS {
		interface.draw_rectangle_with_alpha(table, box.left + 1, box.top + box.height * part / GRAPH_GRID_PARTS, box.width - 2, 1, draw_record.with_alpha(tokens.divider, GRAPH_GRID_ALPHA))
	}
	if history.area_count > 0 {
		interface.draw_path(table, history.area[:history.area_count], draw_record.with_alpha(color, GRAPH_AREA_ALPHA), 0, 0)
	}
	interface.draw_outline(table, box.left, box.top, box.width, box.height, 1, tokens.surface_track)
	if history.stroke_count > 0 {
		interface.draw_path(table, history.stroke[:history.stroke_count], 0, draw_record.opaque(color), GRAPH_STROKE_WIDTH)
	}
}

// table_chrome_draw draws the title of the table card and the band of the
// titles of its columns: a name at the left of its column, a number at its
// right.
table_chrome_draw :: proc "contextless" (table: ^interface.Draw_Table, tokens: layout.Element_Tokens) {
	title := places.table_title
	text_choice_draw(table, {title.x, title.y + (TABLE_TITLE_HEIGHT - graphics.TEXT_CAPTION) / 2, title.width, graphics.TEXT_CAPTION}, {"PROCESSES"}, graphics.colors.process, FONT_CARD_TITLE)
	card := places.table_card
	header := places.table_header
	interface.draw_rectangle(table, card.x + CARD_RAIL, header.y, card.width - CARD_RAIL - 1, header.height, tokens.surface_recess)
	columns := &places.columns
	y := header.y + (LINE - graphics.TEXT_CAPTION) / 2
	gap := int(tokens.gap)
	interface.draw_text(table, int(columns[.Name].x), y, "process", tokens.text_dim, interface.FONT_CAPTION)
	interface.draw_text_right(table, int(columns[.Resident].x + columns[.Resident].width) - gap, y, RESIDENT_TITLE, tokens.text_dim, interface.FONT_CAPTION)
	interface.draw_text(table, int(columns[.Processor_Bar].x), y, "processor", tokens.text_dim, interface.FONT_CAPTION)
	interface.draw_text_right(table, int(columns[.Share].x + columns[.Share].width), y, "share", tokens.text_dim, interface.FONT_CAPTION)
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

// The processor time of the last sample, in percent of every processor:
// the number of the processor card.
processor_percent: u64

// The entry of the monitor: it opens its window and its service, then draws
// a picture of the machine every 500 ms and runs the calls between two
// pictures.
//
// With no window it stops with `Failed`. Each turn of the loop:
//
// 1. asks the kernel for the system report, then the report of each
//    process slot that is in use;
// 2. draws the surfaces of the cards and one row for each process, adds
//    the values of the sample to the sample history of each graph, then
//    draws the metric cards and the graphs; the first picture writes
//    "monitor: ok";
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
		// The surfaces first: each text, gauge and row lies over its card.
		for metric in Metric {
			card_draw(table, places.metric_cards[metric], metric_color(metric))
		}
		for graph in Graph {
			card_draw(table, places.graph_cards[graph], graph_color(graph))
		}
		card_draw(table, places.table_card, graphics.colors.process)
		table_chrome_draw(table, tokens)
		if status != .Ok {
			rows := places.table_rows
			interface.draw_text(table, rows.x, rows.y + 2, "no grant to inspect the machine", tokens.text)
			if !lost {
				system.log_fact(.Info, No_Inspect_Grant{})
				lost = true
			}
		} else {
			elapsed := max(report.time - previous_time, 1)
			previous_time = report.time
			used := report.page_count - report.free_pages

			columns := &places.columns
			name_room := max(int(columns[.Name].width) - int(tokens.gap), 1)
			bar_width := max(int(columns[.Processor_Bar].width) - int(tokens.gap), 0)
			card := places.table_card
			band_x := card.x + CARD_RAIL
			band_width := card.width - CARD_RAIL - 1
			rows := places.table_rows
			y := rows.y

			text_line := interface.line_height({})
			hidden: u64 // The processes whose rows do not fit in the window.
			shown: int // The rows drawn: every second one has a zebra band.
			process_count: u64
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
				process_count += 1
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
				if shown % 2 == 1 {
					interface.draw_rectangle_with_alpha(table, band_x, y, band_width, row_height, draw_record.with_alpha(tokens.surface_recess, ZEBRA_ALPHA))
				}
				shown += 1
				text_y := y + (LINE - graphics.LINE_HEIGHT) / 2
				name_x := int(columns[.Name].x)
				name_lines := interface.draw_text_wrapped(table, name_x, text_y, name_room, name, tokens.text)
				if from_disk {
					// A value under the name, faded: the caption size in the
					// font of the cells.
					prefix: [process_page.HASH_PREFIX_DIGITS]u8
					process_page.hash_prefix_write(&prefix, row.hash[0])
					interface.draw_text(table, name_x, text_y + name_lines * text_line, string(prefix[:]), tokens.text_dim, interface.FONT_CAPTION_CELLS)
				}
				pages: interface.Text_Builder
				interface.draw_text_right(table, int(columns[.Resident].x + columns[.Resident].width) - int(tokens.gap), text_y, interface.number_text(&pages, process.present_pages), tokens.text)
				// The share of the processor that a process took: a measure
				// of a process, in the color of its intensity step.
				gauge_draw(table, {int(columns[.Processor_Bar].x), y + (LINE - ROW_BAR_HEIGHT) / 2, bar_width, ROW_BAR_HEIGHT}, share, 100, graphics.colors.process, tokens, false)
				share_text: interface.Text_Builder
				interface.text_put_number(&share_text, share)
				interface.text_put(&share_text, "%")
				interface.draw_text_right(table, int(columns[.Share].x + columns[.Share].width), text_y, interface.text_of(&share_text), tokens.text)
				y += row_height
			}
			if hidden > 0 {
				x := interface.draw_unsigned(table, rows.x, y + 2, hidden, tokens.text)
				interface.draw_text(table, x, y + 2, " more processes: monitor.processes() gives them", tokens.text_dim)
			}

			// The sample goes into the sample history of each graph, which
			// computes the points of its curve now, once for each sample.
			entries := report.entries - min(previous_entries, report.entries)
			previous_entries = report.entries
			graph_push(.Memory, used, report.page_count)
			if percent, percent_ok := sample_history.processor_time_percent(run_time_total, elapsed, report.processors); percent_ok {
				processor_percent = percent
				graph_push(.Processor_Time, percent, 100)
			}
			if rate, rate_ok := sample_history.rate_per_second(entries, elapsed); rate_ok {
				graph_push(.Kernel_Entries, rate, 0)
			}

			// The memory card: the share in use, the MiB in use of all the
			// MiB, and the reserved memory.
			memory_texts: Metric_Texts
			interface.text_put_number(&memory_texts.value, used * 100 / max(report.page_count, 1))
			interface.text_put(&memory_texts.value, "%")
			interface.text_put_number(&memory_texts.detail, used * system.PAGE_SIZE >> 20)
			interface.text_put(&memory_texts.detail, " / ")
			interface.text_put_number(&memory_texts.detail, report.page_count * system.PAGE_SIZE >> 20)
			interface.text_put(&memory_texts.detail, " MiB")
			interface.text_put_number(&memory_texts.second_details[0], report.reserved_pages * system.PAGE_SIZE >> 20)
			interface.text_put(&memory_texts.second_details[0], " MiB reserved")
			metric_card_draw(table, .Memory, &memory_texts, used, report.page_count, tokens)
			// The processor card: the processor time of the last sample,
			// the processes, the processors.
			processor_texts: Metric_Texts
			interface.text_put_number(&processor_texts.value, processor_percent)
			interface.text_put(&processor_texts.value, "%")
			interface.text_put_number(&processor_texts.detail, process_count)
			interface.text_put(&processor_texts.detail, " processes")
			interface.text_put_number(&processor_texts.second_details[0], report.processors)
			interface.text_put(&processor_texts.second_details[0], " processors")
			metric_card_draw(table, .Processor, &processor_texts, processor_percent, 100, tokens)
			// The kernel card: its entries and its interrupts since the
			// start, and the waits of its locks of all kinds, with the kind
			// that waited most. The gauge is the share of the takes that
			// waited.
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
			kernel_texts: Metric_Texts
			compact: [sample_history.COMPACT_TEXT_SIZE]u8
			interface.text_put(&kernel_texts.value, sample_history.compact_number_text(&compact, report.entries))
			interface.text_put(&kernel_texts.detail, sample_history.compact_number_text(&compact, report.interrupts))
			interface.text_put(&kernel_texts.detail, " interrupts")
			// The longest form names the kind that waited most; the shortest
			// keeps only the waits.
			for &form, index in kernel_texts.second_details {
				if index == SECOND_DETAIL_FORMS - 1 {
					interface.text_put_number(&form, waits)
					interface.text_put(&form, " lock waits")
					continue
				}
				interface.text_put(&form, "lock waits ")
				interface.text_put_number(&form, waits)
				interface.text_put(&form, " of ")
				interface.text_put(&form, sample_history.compact_number_text(&compact, takes))
				if index == 0 && most != 0 {
					interface.text_put(&form, ", most: ")
					interface.text_put(&form, op.LOCK_KIND_NAMES[most_kind])
				}
			}
			metric_card_draw(table, .Kernel, &kernel_texts, waits, takes, tokens)
			for graph in Graph {
				graph_draw(table, graph, places.graph_headers[graph], tokens)
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
