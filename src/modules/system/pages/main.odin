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
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:system"

// Format property: window edge margin and single text line height in logical pixels.
MARGIN :: 12
LINE :: 16
HEADER_HEIGHT :: 2 * LINE
// Format property: the four security rules shown between the two halves.
RULE_COUNT :: 4

// The columns of a run, each as wide as its longest text, so that no text
// meets the next column or the edge of the window: the 8x8 mark and its
// 8-pixel gap; the address (16 characters) and the size (two spaces and 9
// characters); then the rights, at most " read write execute, 2 MiB pages"
// (32 characters) and one space; then the part of the kernel half, at most
// "double fault stack of processor " and a number of three digits (35
// characters).
// Format property: column widths sized from the longest formatted fields.
MARK_COLUMN_WIDTH :: 16
RANGE_COLUMN_WIDTH :: (16 + 2 + 9) * graphics.CELL_WIDTH
RIGHTS_COLUMN_WIDTH :: (32 + 1) * graphics.CELL_WIDTH
PART_COLUMN_WIDTH :: 35 * graphics.CELL_WIDTH

// Computed: literal window dimensions so the tool reads the window budget;
// the assertion keeps the width equal to the margins and the four columns.
WIDTH :: 800
#assert(WIDTH == 2 * MARGIN + MARK_COLUMN_WIDTH + RANGE_COLUMN_WIDTH + RIGHTS_COLUMN_WIDTH + PART_COLUMN_WIDTH)
HEIGHT :: 668
// The tool counts the module, its stack, and its window at the largest scale.
MODULE_BUDGET :: system.Stated_Budget{window_width = WIDTH, window_height = HEIGHT}

// Inline capacity: 512 draw records and 8 KiB of text hold 22 kernel runs,
// 4 rules, 10 process runs, and scroll bars without filling the table.
WINDOW_RECORDS_CAPACITY :: 512
WINDOW_TEXT_CAPACITY :: 8192
window_memory: interface.Window_Memory(WINDOW_RECORDS_CAPACITY, WINDOW_TEXT_CAPACITY)
// The layout tree of one frame. A global: the tree is too large for the stack.
pages_layout_tree: layout.Box_Tree

// Plan value: default displayed run limits and 500 ms refresh interval.
KERNEL_ROWS :: 22
PROCESS_ROWS :: 10
INTERVAL :: 500

// The three protections of a run are a series: three things of one kind
// that no concept of the rules tells apart. The words of each run say its
// protection too.
Protection :: enum u8 {
	Execute = 0,
	Write   = 1,
	Read    = 2,
}

// The four columns of a mapping run row.
Run_Column :: enum u8 {
	Mark   = 0,
	Range  = 1,
	Rights = 2,
	Part   = 3,
}

@(rodata)
run_column_widths := [Run_Column]layout.Table_Column {
	.Mark   = {width = MARK_COLUMN_WIDTH},
	.Range  = {width = RANGE_COLUMN_WIDTH},
	.Rights = {width = RIGHTS_COLUMN_WIDTH},
	.Part   = {weight = 1, least = PART_COLUMN_WIDTH},
}

// The places of the window that draw reads after layout.solve, in logical pixels.
Pages_Places :: struct {
	kernel_section:  interface.Area,
	kernel_header:   interface.Area,
	kernel_runs:     interface.Area,
	rules_section:   interface.Area,
	rule_rows:       [RULE_COUNT]interface.Area,
	process_section: interface.Area,
	process_header:  interface.Area,
	process_runs:    interface.Area,
	columns:         [Run_Column]layout.Table_Column_Place,
}

kernel_half: op.Mapping_Report
process_half: op.Mapping_Report

@(private)
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil || box.clipped_rect.width <= 0 || box.clipped_rect.height <= 0 {
		return {}
	}
	return {int(box.clipped_rect.x), int(box.clipped_rect.y), int(box.clipped_rect.width), int(box.clipped_rect.height)}
}

// pages_layout builds and solves the layout tree of the pages window: the
// kernel half, the four security rules, the process half, and the four
// columns of a run row.
pages_layout :: proc "contextless" (tree: ^layout.Box_Tree, width, height: int, kernel_run_lines := KERNEL_ROWS, process_run_lines := PROCESS_ROWS) -> (places: Pages_Places, ok: bool) {
	if tree == nil || width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	inner_height := max(height - 2 * MARGIN, 0)
	section_gap := i32(inner_height >= 2 * LINE ? LINE : 0)
	room := max(inner_height - 2 * int(section_gap), 0)
	rules_height := RULE_COUNT * LINE
	// Keep the four rule lines intact whenever the window holds them; on
	// shorter windows let all three sections shrink together inside the root.
	rules_strictness := i32(room >= rules_height ? layout.RATIO_WHOLE : 0)
	k_lines := clamp(kernel_run_lines, 0, op.MAPPING_RUN_CAPACITY + 1)
	p_lines := clamp(process_run_lines, 0, op.MAPPING_RUN_CAPACITY + 1)
	kernel_desired := i32(HEADER_HEIGHT + k_lines * LINE)
	process_desired := i32(HEADER_HEIGHT + p_lines * LINE)

	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = MARGIN, .Y = MARGIN}, gap = section_gap, overflow = {.X = .Clip, .Y = .Clip}}) != .Done {
		return {}, false
	}

	kernel_sec, s0 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(kernel_desired, 0)}, child_axis = .Y, overflow = {.X = .Clip, .Y = .Clip}})
	kernel_hdr, s1 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(HEADER_HEIGHT)}})
	kernel_runs, s2 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, overflow = {.X = .Clip, .Y = .Clip}})
	s3 := layout.box_close(tree)
	if s0 != .Done || s1 != .Done || s2 != .Done || s3 != .Done {
		return {}, false
	}

	rules_sec, sr0 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(i32(rules_height), rules_strictness)}, child_axis = .Y, overflow = {.X = .Clip, .Y = .Clip}})
	if sr0 != .Done {
		return {}, false
	}
	rule_boxes: [RULE_COUNT]layout.Box_Index
	for i in 0 ..< RULE_COUNT {
		st: layout.Box_Status
		rule_boxes[i], st = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
		if st != .Done {
			return {}, false
		}
	}
	if layout.box_close(tree) != .Done {
		return {}, false
	}

	process_sec, sp0 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(process_desired, 0)}, child_axis = .Y, overflow = {.X = .Clip, .Y = .Clip}})
	process_hdr, sp1 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(HEADER_HEIGHT)}})
	process_runs, sp2 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, overflow = {.X = .Clip, .Y = .Clip}})
	sp3 := layout.box_close(tree)
	if sp0 != .Done || sp1 != .Done || sp2 != .Done || sp3 != .Done || layout.solve(tree) != .Done {
		return {}, false
	}

	places.kernel_section = area_of(tree, kernel_sec)
	places.kernel_header = area_of(tree, kernel_hdr)
	places.kernel_runs = area_of(tree, kernel_runs)
	places.rules_section = area_of(tree, rules_sec)
	for i in 0 ..< RULE_COUNT {
		places.rule_rows[i] = area_of(tree, rule_boxes[i])
	}
	places.process_section = area_of(tree, process_sec)
	places.process_header = area_of(tree, process_hdr)
	places.process_runs = area_of(tree, process_runs)

	widths := run_column_widths
	kernel_box := layout.box_of(tree, kernel_sec)
	if kernel_box == nil {
		return {}, false
	}
	if layout.table_columns(([^]layout.Table_Column)(&widths)[:len(widths)], ([^]layout.Table_Column_Place)(&places.columns)[:len(places.columns)], kernel_box.clipped_rect, 0) != .Done {
		return {}, false
	}
	return places, true
}

text_put_hex :: proc "contextless" (text: ^interface.Text_Builder, value: u64) {
	characters := "0123456789abcdef"
	for index := 15; index >= 0; index -= 1 {
		interface.text_put(text, characters[value >> (uint(index) * 4) & 15:][:1])
	}
}

// text_put_size adds a count of pages as a size, in 9 characters.
text_put_size :: proc "contextless" (text: ^interface.Text_Builder, page_count: u64) {
	start := text.count
	kib := page_count * 4
	switch {
	case kib < 1024:
		interface.text_put_number(text, kib)
		interface.text_put(text, " KiB")
	case kib < 1024 * 1024:
		interface.text_put_number(text, kib >> 10)
		interface.text_put(text, ".")
		interface.text_put_number(text, (kib & 1023) * 10 >> 10)
		interface.text_put(text, " MiB")
	case:
		interface.text_put_number(text, kib >> 20)
		interface.text_put(text, ".")
		interface.text_put_number(text, (kib & (1 << 20 - 1)) * 10 >> 20)
		interface.text_put(text, " GiB")
	}
	for text.count < start + 9 {
		interface.text_put(text, " ")
	}
}

show :: proc "contextless" (table: ^interface.Draw_Table, x, y: int, text: ^interface.Text_Builder, color: graphics.Color) -> int {
	after := interface.draw_text(table, x, y, interface.text_of(text), color)
	text.count = 0
	return after
}

// part says which part of the kernel half holds an address.
part :: proc "contextless" (text: ^interface.Text_Builder, address: u64) {
	slot_size :: u64(op.KERNEL_STACK_SLOT_PAGES * info.PAGE_SIZE)
	switch {
	case address >= u64(info.KERNEL_BASE):
		interface.text_put(text, "kernel module")
	case address >= op.KERNEL_STACK_BASE:
		page := (address - op.KERNEL_STACK_BASE) % slot_size / info.PAGE_SIZE
		switch page {
		case 1:
			interface.text_put(text, "stack of processor ")
		case 2 + op.KERNEL_STACK_PAGES:
			interface.text_put(text, "double fault stack of processor ")
		case:
			interface.text_put(text, "interrupt stack of processor ")
		}
		interface.text_put_number(text, (address - op.KERNEL_STACK_BASE) / slot_size)
	case address >= u64(info.DIRECT_MAP_BASE):
		interface.text_put(text, "direct map")
	}
}

// desired_lines gives the number of lines a half wants for its runs and an
// optional summary line when more runs exist than row_limit.
desired_lines :: proc "contextless" (run_count: u64, row_limit: int) -> int {
	shown := min(int(run_count), row_limit, op.MAPPING_RUN_CAPACITY)
	if int(run_count) > shown {
		return shown + 1
	}
	return shown
}

// half draws the header and runs of one mapping report inside its layout areas.
half :: proc "contextless" (table: ^interface.Draw_Table, header, runs_area: interface.Area, columns: ^[Run_Column]layout.Table_Column_Place, title: string, report: ^op.Mapping_Report, rows: int, kernel: bool, tokens: layout.Element_Tokens) {
	text: interface.Text_Builder
	// The title of a half in the color of its concept: the kernel or a
	// process.
	accent := kernel ? graphics.colors.kernel : tokens.expected
	if header.height >= 2 && header.width > 0 {
		interface.draw_rectangle(table, header.x, header.y, header.width, 2, accent)
	}
	if header.height >= 6 + LINE {
		x := interface.draw_text(table, header.x, header.y + 6, title, accent)
		interface.text_put(&text, "  ")
		interface.text_put_number(&text, report.pages)
		interface.text_put(&text, " pages, ")
		interface.text_put_number(&text, report.execute_pages)
		interface.text_put(&text, " of code, ")
		interface.text_put_number(&text, report.run_count)
		interface.text_put(&text, " runs")
		show(table, x, header.y + 6, &text, tokens.text_dim)
	}

	row_slots := runs_area.height / LINE
	if row_slots <= 0 {
		return
	}
	shown: int
	if int(report.run_count) <= min(rows, row_slots, op.MAPPING_RUN_CAPACITY) {
		shown = int(report.run_count)
	} else {
		shown = min(rows, max(row_slots - 1, 0), op.MAPPING_RUN_CAPACITY)
	}

	mark_x := int(columns[.Mark].x)
	range_x := int(columns[.Range].x)
	rights_x := int(columns[.Rights].x)
	part_x := int(columns[.Part].x)

	for run, index in report.runs[:shown] {
		y := runs_area.y + index * LINE
		protection := Protection.Read
		switch {
		case .Execute in run.flags:
			protection = .Execute
		case .Write in run.flags:
			protection = .Write
		}
		color := graphics.colors.series[int(protection)]
		// A place with no page before a kernel stack is a guard: an access
		// there fails, so its mark has the color of a failure.
		if kernel && run.start >= op.KERNEL_STACK_BASE && run.start < u64(info.KERNEL_BASE) {
			interface.draw_rectangle(table, mark_x, y, 8, 3, tokens.failed)
			if index + 1 == shown || report.runs[index + 1].start >= u64(info.KERNEL_BASE) {
				interface.draw_rectangle(table, mark_x, y + LINE - 3, 8, 3, tokens.failed)
			}
		}
		interface.draw_rectangle(table, mark_x, y + 4, 8, 8, color)
		text_put_hex(&text, run.start)
		interface.text_put(&text, "  ")
		text_put_size(&text, run.page_count)
		show(table, range_x, y, &text, tokens.text)
		interface.text_put(&text, " read")
		if .Write in run.flags {
			interface.text_put(&text, " write")
		}
		if .Execute in run.flags {
			interface.text_put(&text, " execute")
		}
		if .Large in run.flags {
			interface.text_put(&text, ", 2 MiB pages")
		}
		show(table, rights_x, y, &text, color)
		if kernel {
			part(&text, run.start)
			show(table, part_x, y, &text, tokens.text_dim)
		}
	}
	if int(report.run_count) > shown && shown < row_slots {
		interface.text_put(&text, "and ")
		interface.text_put_number(&text, report.run_count - u64(shown))
		interface.text_put(&text, " more runs")
		show(table, range_x, runs_area.y + shown * LINE, &text, tokens.text_dim)
	}
}

rule :: proc "contextless" (table: ^interface.Draw_Table, row: interface.Area, columns: ^[Run_Column]layout.Table_Column_Place, kept: bool, text: ^interface.Text_Builder, tokens: layout.Element_Tokens) {
	if row.height < LINE {
		text.count = 0
		return
	}
	interface.draw_rectangle(table, int(columns[.Mark].x), row.y + 4, 8, 8, kept ? tokens.expected : tokens.failed)
	show(table, int(columns[.Range].x), row.y, text, kept ? tokens.text : tokens.failed)
}

draw :: proc "contextless" (frame: ^interface.Frame, width, height: int) {
	tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
	interface.background(frame, {0, 0, width, height})
	places, layout_ok := pages_layout(&pages_layout_tree, width, height, desired_lines(kernel_half.run_count, KERNEL_ROWS), desired_lines(process_half.run_count, PROCESS_ROWS))
	if !layout_ok {
		return
	}
	table := frame.table
	half(table, places.kernel_header, places.kernel_runs, &places.columns, "the kernel half", &kernel_half, KERNEL_ROWS, true, tokens)

	text: interface.Text_Builder
	interface.text_put(&text, "write and execute: ")
	interface.text_put_number(&text, kernel_half.write_execute_pages + process_half.write_execute_pages)
	interface.text_put(&text, " pages")
	rule(table, places.rule_rows[0], &places.columns, kernel_half.write_execute_pages + process_half.write_execute_pages == 0, &text, tokens)

	interface.text_put(&text, "guard pages around the kernel stacks: ")
	interface.text_put_number(&text, kernel_half.guard_pages)
	interface.text_put(&text, " of ")
	interface.text_put_number(&text, kernel_half.guards_expected)
	rule(table, places.rule_rows[1], &places.columns, kernel_half.guard_pages == kernel_half.guards_expected, &text, tokens)

	interface.text_put(&text, kernel_half.kernel_no_execute != 0 ? "the kernel cannot execute memory of processes" : "the kernel can execute memory of processes: the processor has no guard")
	rule(table, places.rule_rows[2], &places.columns, kernel_half.kernel_no_execute != 0, &text, tokens)

	interface.text_put(&text, kernel_half.kernel_guard != 0 ? "the kernel cannot use memory of processes outside a copy" : "the kernel can use memory of processes: the processor has no guard")
	rule(table, places.rule_rows[3], &places.columns, kernel_half.kernel_guard != 0, &text, tokens)

	half(table, places.process_header, places.process_runs, &places.columns, "the half of this process", &process_half, PROCESS_ROWS, false, tokens)
}

// The entry of pages: every 500 ms it reads the two mapping reports and
// draws them, and the first time it writes the result on the log.
//
// With no window it stops with `Failed`. It never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "pages")
	if !ok {
		system.stop(.Failed)
	}
	machine := ctx.handles[system.GRANT_MACHINE]
	logged := false
	for {
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Mappings), 0, u64(uintptr(&kernel_half)), size_of(op.Mapping_Report))
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Mappings), 1, u64(uintptr(&process_half)), size_of(op.Mapping_Report))
		frame := interface.window_frame_start(&window_memory, &window)
		draw(&frame, window.width, window.height)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
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
		// The wait reads the events: presentation changes and the scroll of a
		// window that does not fit the work area redraw at once.
		next := system.time() + INTERVAL
		for system.time() < next {
			redraw := window_memory.drawing.late && display.canvas_free(&window)
			for event in interface.window_next_event(&window_memory.drawing, &window) {
				if event.kind == .Presentation || event.kind == .Surface_Answer {
					redraw = true
				}
			}
			if interface.window_scroll_frame_take(&window_memory.drawing) {
				redraw = true
			}
			if redraw {
				break
			}
			_ = display.wait(&window, next)
		}
	}
}
