// A demonstration of several processors.
//
// First, the process asks the kernel what each processor runs, while four
// of its threads compute: the kernel answers that all the processors run
// threads of this one process at the same time.
//
// Then 1, 2 and 4 threads compute the same picture, one row at a time.
// Each row has the tint of the thread that computed it. The panel shows
// the time of each picture, and the load of each processor.
//
// The process needs the grant to inspect the machine.
//
// **What it is for.** It shows that the kernel runs the threads of one
// process on several processors at one time, and what that gives on a job
// that divides well. A lock guards the next row to compute: the panel
// counts its waits, so a reader sees the cost of the shared state.
//
// **Start**: `start("processors")` in the console, or the bar of the
// desktop. Its budget has room for 9 threads: the main thread, the 4
// threads that compute, and the threads of the first part.
//
// **Grants**, as the root service gives them:
//
// - **Inspect**: the machine with the right Inspect, for the processor
//   reports (what each processor runs) and the system report (how many
//   processors exist). With no such grant it writes "processors: no grant
//   to inspect the machine" and stops with `Refused`.
//
// **What a reader sees**: the picture in the tints of the threads, the time
// of each of the three pictures, the load of each processor and the waits
// of the lock. The log has "processors: ok, N processors ran the process at
// the same time" (or "at most N of M"), then once "processors: the picture
// took A ms with 1 thread, B ms with 2 threads, C ms with 4 threads".
//
// **What it does not prove**: the times depend on the machine and on QEMU;
// the process prints them as measures and asserts no speed-up.
package processors

import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"
import "base:intrinsics"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module, its threads and its
// window: 1112 pages. And the glyph memory of the copy of the text
// rendering of the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 1112 + 354 = 1466.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1466, processes = 1, threads = 9, window_width = WIDTH, window_height = HEIGHT}

PICTURE_WIDTH :: 448
PICTURE_HEIGHT :: 320
MARGIN :: 12
HEADER :: 28
PANEL :: 264
// The size is two literals, because the tool counts the pictures of the
// window from them; each assertion keeps a literal equal to its layout.
WIDTH :: 748
#assert(WIDTH == PICTURE_WIDTH + PANEL + 3 * MARGIN)
HEIGHT :: 372
#assert(HEIGHT == HEADER + PICTURE_HEIGHT + 2 * MARGIN)
FRAME_TIME :: 33
PICTURE_PAUSE :: 500 // Milliseconds between two pictures.
LOAD_INTERVAL :: 250 // Milliseconds between two measures of the load.
WORKER_COUNT :: 4
PROCESSOR_ROWS :: 8 // The panel shows at most this number of processors.
ITERATIONS :: 4000
LINE :: 18
#assert(PANEL >= 2 * graphics.GAP + 240)
#assert(PICTURE_HEIGHT >= 2 * graphics.GAP + 20 + (4 + 1 + 3 + 1 + WORKER_COUNT + 1) * LINE + 2 * 6 + 4)

processors_layout_tree: layout.Box_Tree

Processors_Places :: struct {
	header:          interface.Area,
	picture:         interface.Area,
	panel:           interface.Area,
	summary:         interface.Area,
	processor_rows:  [PROCESSOR_ROWS]interface.Area,
	times_header:    interface.Area,
	time_rows:       [3]interface.Area,
	workers_header:  interface.Area,
	worker_rows:     [WORKER_COUNT]interface.Area,
	lock_waits:      interface.Area,
}

@(private)
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// processors_window_layout computes the header, picture, and statistics panel
// rows with modus:layout.
processors_window_layout :: proc "contextless" (tree: ^layout.Box_Tree, width, height: int, shown_processors: int, tokens: layout.Element_Tokens) -> (places: Processors_Places, ok: bool) {
	if tree == nil || width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = MARGIN, .Y = MARGIN}}) != .Done {
		return {}, false
	}
	hdr_box, s0 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(HEADER)}})
	_, s1 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .X, gap = MARGIN})
	pic_box, s2 := layout.box_add(tree, {size = {.X = layout.px(PICTURE_WIDTH), .Y = layout.px(PICTURE_HEIGHT)}})
	panel_box, s3 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.px(PICTURE_HEIGHT)}, child_axis = .Y, padding = {.X = tokens.gap, .Y = tokens.gap}, overflow = {.X = .Clip, .Y = .Clip}})
	sum_box, s4 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(20)}})
	if s0 != .Done || s1 != .Done || s2 != .Done || s3 != .Done || s4 != .Done {
		return {}, false
	}
	proc_count := clamp(shown_processors, 0, PROCESSOR_ROWS)
	proc_boxes: [PROCESSOR_ROWS]layout.Box_Index
	for i in 0 ..< proc_count {
		st: layout.Box_Status
		proc_boxes[i], st = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
		if st != .Done {
			return {}, false
		}
	}
	_, sp1 := layout.box_add(tree, {size = {.X = layout.px(0), .Y = layout.px(6)}})
	th_box, sth := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	if sp1 != .Done || sth != .Done {
		return {}, false
	}
	time_boxes: [3]layout.Box_Index
	for i in 0 ..< 3 {
		st: layout.Box_Status
		time_boxes[i], st = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
		if st != .Done {
			return {}, false
		}
	}
	_, sp2 := layout.box_add(tree, {size = {.X = layout.px(0), .Y = layout.px(6)}})
	wh_box, swh := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	if sp2 != .Done || swh != .Done {
		return {}, false
	}
	worker_boxes: [WORKER_COUNT]layout.Box_Index
	for i in 0 ..< WORKER_COUNT {
		st: layout.Box_Status
		worker_boxes[i], st = layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
		if st != .Done {
			return {}, false
		}
	}
	_, sp3 := layout.box_add(tree, {size = {.X = layout.px(0), .Y = layout.px(4)}})
	lock_box, slk := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(LINE)}})
	sc1 := layout.box_close(tree)
	sc2 := layout.box_close(tree)
	if sp3 != .Done || slk != .Done || sc1 != .Done || sc2 != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	places.header = area_of(tree, hdr_box)
	places.picture = area_of(tree, pic_box)
	places.panel = area_of(tree, panel_box)
	places.summary = area_of(tree, sum_box)
	for i in 0 ..< proc_count {
		places.processor_rows[i] = area_of(tree, proc_boxes[i])
	}
	places.times_header = area_of(tree, th_box)
	for i in 0 ..< 3 {
		places.time_rows[i] = area_of(tree, time_boxes[i])
	}
	places.workers_header = area_of(tree, wh_box)
	for i in 0 ..< WORKER_COUNT {
		places.worker_rows[i] = area_of(tree, worker_boxes[i])
	}
	places.lock_waits = area_of(tree, lock_box)
	return places, true
}

// One picture to compute: the threads share it, the lock keeps it correct.
Job :: struct {
	lock:    system.Lock,
	number:  u32, // The number of the picture. A thread with no work waits on this word.
	threads: u32, // The threads that compute this picture: the workers 0 to threads - 1.
	next:    u32, // The first row that no thread took.
	done:    u32, // The rows that are complete.
	finish:  u64, // The time when the last row was complete.
}

Worker :: struct {
	number: int,
	rows:   u32, // The rows of this picture that the thread computed.
}

// What the kernel says of one processor.
Processor :: struct {
	name:      [32]u8, // The process that the processor runs.
	busy_time: u64,
	load:      u64, // Percent.
}

@(rodata)
thread_counts := [?]u32{1, 2, 4}

job: Job
workers: [WORKER_COUNT]Worker
picture: graphics.Canvas // The picture that the threads compute, in the memory that they share.
picture_pixels: [PICTURE_WIDTH * PICTURE_HEIGHT]graphics.Color
// The one picture memory of the draw tables: the drawing module reads the
// picture there.
picture_memories: [1][]graphics.Color
window_memory: interface.Window_Memory(128, 1024)
machine: system.Handle
processor_count: u64
processors: [PROCESSOR_ROWS]Processor
together: u64 // The most processors that ran this process at one time.
spin_stop: u32
times: [len(thread_counts)]u64 // The milliseconds of the last picture with thread_counts[n] threads.

// The picture is in the series color of each thread in the dark appearance:
// a picture keeps its pixels in both appearances. The legend of a thread
// takes its series color of the appearance in force: the same hue.
#assert(WORKER_COUNT <= graphics.SERIES_COLOR_COUNT)
@(rodata)
picture_series := graphics.DARK_SERIES

// tint_color gives the color of a pixel of the picture: the series color of
// the thread, at the level 0 (black) to 255 (the color itself).
tint_color :: proc "contextless" (number: int, level: u32) -> graphics.Color {
	tint := picture_series[number]
	return graphics.rgb((tint >> 16 & 0xFF) * level / 255, (tint >> 8 & 0xFF) * level / 255, (tint & 0xFF) * level / 255)
}

// spin is the entry of the threads of the first test: they compute until
// the first thread says stop.
spin :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&spin_stop) == 0 {
		intrinsics.cpu_relax()
	}
	system.thread_stop()
}

// processors_same asks the kernel how many processors run a thread of
// this process now. The thread that asks is on one of them.
processors_same :: proc "contextless" () -> (count: u64) {
	for index in 0 ..< processor_count {
		report: op.Processor_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), index, u64(uintptr(&report)), size_of(report))
		count += report.same
	}
	return count
}

// run_together runs one thread per processor, and waits until the kernel
// sees them all at one time.
run_together :: proc "contextless" () {
	threads: [WORKER_COUNT]system.Thread
	for &thread in threads {
		status: system.Status
		thread, status = system.thread_start(spin, nil)
		if status != .Ok {
			system.log_fact(.Info, Thread_Not_Started{})
			system.stop(.Failed)
		}
	}
	// This thread is the fifth: with the four others, it can fill 5 processors.
	target := min(processor_count, WORKER_COUNT + 1)
	// The bound only ends a hang: a loaded host can take long to run every
	// virtual processor at one time.
	start := system.time()
	for together < target && system.time() < start + system.TEST_HANG_BOUND_MILLISECONDS {
		together = max(together, processors_same())
	}
	intrinsics.atomic_store(&spin_stop, 1)
	for thread in threads {
		system.thread_wait(thread)
	}
}

// compute is the entry of the four threads that take rows.
compute :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	for {
		system.lock(&job.lock)
		if u32(worker.number) >= job.threads || job.next == PICTURE_HEIGHT {
			number := job.number
			system.unlock(&job.lock)
			system.word_wait(&job.number, number)
			continue
		}
		y := int(job.next)
		job.next += 1
		system.unlock(&job.lock)

		row := picture.pixels[y * picture.stride:]
		for x in 0 ..< PICTURE_WIDTH {
			cx := -0.62 + (f64(x) - PICTURE_WIDTH / 2) * (2.6 / PICTURE_WIDTH)
			cy := (f64(y) - PICTURE_HEIGHT / 2) * (2.6 / PICTURE_WIDTH)
			zx, zy: f64
			count: u32
			for count < ITERATIONS && zx * zx + zy * zy < 4 {
				zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
				count += 1
			}
			row[x] = count == ITERATIONS ? tint_color(worker.number, 48) : tint_color(worker.number, 80 + (count * 12) % 176)
		}

		system.lock(&job.lock)
		job.done += 1
		worker.rows += 1
		if job.done == PICTURE_HEIGHT {
			job.finish = system.time()
		}
		system.unlock(&job.lock)
	}
}

// load_measure reads what each processor runs, and its load since the
// last measure.
load_measure :: proc "contextless" (elapsed: u64) {
	for &processor, index in processors[:min(processor_count, PROCESSOR_ROWS)] {
		report: op.Processor_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), u64(index), u64(uintptr(&report)), size_of(report))
		processor.load = min((report.busy_time - processor.busy_time) * 100 / max(elapsed, 1), 100)
		processor.busy_time = report.busy_time
		processor.name = {}
		if report.process != 0 {
			process: op.Process_Report
			system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), report.process, u64(uintptr(&process)), size_of(process))
			processor.name = process.name
		}
	}
}

// The entry of processors: the test of the processors at one time, then the
// pictures with 1, 2 and 4 threads in a loop for ever.
//
// With no window, it stops with `Failed`; with no grant to inspect the
// machine, with `Refused`. It runs `run_together` once and writes its result. Then it
// starts 4 threads that compute rows, and the main thread gives them the
// same picture with 1, then 2, then 4 of them at work, and starts again.
// The main thread draws the panel at the rate of the screen.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "processors")
	if !ok {
		system.stop(.Failed)
	}
	// The window shows the picture with a picture record: until the first
	// rows, the picture is the background.
	picture = {pixels = raw_data(picture_pixels[:]), width = PICTURE_WIDTH, height = PICTURE_HEIGHT, stride = PICTURE_WIDTH}
	graphics.clear(picture, graphics.colors.background)
	picture_memories[0] = picture_pixels[:]
	window_memory.drawing.now.picture_memories = picture_memories[:]
	window_memory.drawing.before.picture_memories = picture_memories[:]
	{
		frame := interface.window_frame_start(&window_memory, &window)
		interface.draw_text(frame.table, MARGIN, 8, "One picture, computed by 1, 2 and 4 threads.", graphics.colors.text)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
	}

	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		system.log_fact(.Info, No_Inspect_Grant{})
		system.stop(.Refused)
	}
	processor_count = report.processors

	run_together()
	if together == min(processor_count, WORKER_COUNT + 1) {
		system.log_fact(.Info, Processors_Together{together = together})
	} else {
		system.log_fact(.Info, Processors_Together_At_Most{together = together, processors = processor_count})
	}

	job.next = PICTURE_HEIGHT
	job.done = PICTURE_HEIGHT
	for &worker, index in workers {
		worker.number = index
		if _, status := system.thread_start(compute, &worker); status != .Ok {
			system.log_fact(.Info, Thread_Not_Started{})
			system.stop(.Failed)
		}
	}

	phase := -1 // The index in thread_counts of the picture that the threads compute.
	started_at: u64
	complete_at: u64
	measured_at := system.time()
	logged := false
	for {
		now := system.time()
		system.lock(&job.lock)
		done := job.done
		if done == PICTURE_HEIGHT && complete_at == 0 {
			complete_at = now
			if phase >= 0 {
				times[phase] = job.finish - started_at
			}
			if phase == len(thread_counts) - 1 && !logged {
				logged = true
				system.log_fact(.Info, Picture_Timed{one_thread = value_kinds.Time_In_Milliseconds(times[0]), two_threads = value_kinds.Time_In_Milliseconds(times[1]), four_threads = value_kinds.Time_In_Milliseconds(times[2])})
			}
		}
		// The pause between two pictures is for a reader. The first three
		// pictures have none: the line of their times comes after a count
		// of work, not after a time.
		if done == PICTURE_HEIGHT && now >= complete_at + (logged ? PICTURE_PAUSE : 0) {
			// A new picture: all the rows are free again.
			phase = (phase + 1) % len(thread_counts)
			graphics.clear(picture, graphics.colors.card_top)
			for &worker in workers {
				worker.rows = 0
			}
			job.threads = thread_counts[phase]
			job.next = 0
			job.done = 0
			job.number += 1
			complete_at = 0
			done = 0
			started_at = system.time()
			system.unlock(&job.lock)
			system.word_wake(&job.number, WORKER_COUNT)
		} else {
			system.unlock(&job.lock)
		}
		if now >= measured_at + LOAD_INTERVAL {
			load_measure(now - measured_at)
			measured_at = now
		}

		frame := interface.window_frame_start(&window_memory, &window)
		table := frame.table
		tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
		shown_procs := int(min(processor_count, PROCESSOR_ROWS))
		if places, layout_ok := processors_window_layout(&processors_layout_tree, window.width, window.height, shown_procs, tokens); layout_ok {
			interface.draw_text(table, places.header.x, places.header.y, "One picture, computed by 1, 2 and 4 threads.", tokens.text)
			// The pixels change when a row is complete, and when a new picture
			// clears them: the number of the picture and its complete rows are
			// the generation.
			interface.draw_picture(table, places.picture.x, places.picture.y, picture, job.number * 1024 + done)
			interface.draw_rectangle(table, places.panel.x, places.panel.y, places.panel.width, places.panel.height, tokens.surface_card)
			after := interface.draw_unsigned(table, places.summary.x, places.summary.y, processor_count, tokens.text)
			after = interface.draw_text(table, after, places.summary.y, " processors, at one time ", tokens.text)
			interface.draw_unsigned(table, after, places.summary.y, together, tokens.expected)
			for &processor, index in processors[:shown_procs] {
				row_area := places.processor_rows[index]
				interface.draw_unsigned(table, row_area.x, row_area.y, u64(index), tokens.text_dim)
				interface.draw_rectangle(table, row_area.x + 20, row_area.y + 3, 80, 10, tokens.surface_track)
				// A processor is a device of the machine.
				interface.draw_rectangle(table, row_area.x + 20, row_area.y + 3, int(processor.load) * 80 / 100, 10, graphics.colors.machine)
				interface.draw_text(table, row_area.x + 108, row_area.y, system.name_of(processor.name[:]), tokens.text)
			}
			interface.draw_text(table, places.times_header.x, places.times_header.y, "threads  time of the picture", tokens.text_dim)
			for count, index in thread_counts {
				row_area := places.time_rows[index]
				color := index == phase ? tokens.text : tokens.text_dim
				interface.draw_unsigned(table, row_area.x, row_area.y, u64(count), color)
				if times[index] != 0 {
					after = interface.draw_unsigned(table, row_area.x + 72, row_area.y, times[index], color)
					interface.draw_text(table, after, row_area.y, " ms", color)
					// The time that the process took for one picture.
					interface.draw_rectangle(table, row_area.x + 152, row_area.y + 3, int(times[index] * 88 / max(times[0], times[index])), 10, tokens.expected)
				}
			}
			interface.draw_text(table, places.workers_header.x, places.workers_header.y, "thread   rows of this picture", tokens.text_dim)
			for &worker, index in workers {
				row_area := places.worker_rows[index]
				interface.draw_unsigned(table, row_area.x, row_area.y, u64(index + 1), graphics.colors.series[index])
				interface.draw_unsigned(table, row_area.x + 72, row_area.y, u64(worker.rows), tokens.text)
				interface.draw_rectangle(table, row_area.x + 112, row_area.y + 3, int(worker.rows) * 128 / PICTURE_HEIGHT, 10, graphics.colors.series[index])
			}
			// A wait of the lock is a wait in the kernel.
			after = interface.draw_text(table, places.lock_waits.x, places.lock_waits.y, "lock waits ", graphics.colors.kernel)
			interface.draw_unsigned(table, after, places.lock_waits.y, u64(job.lock.waits), graphics.colors.kernel)
		}
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		for _ in interface.window_next_event(&window_memory.drawing, &window) {}
		display.wait(&window, now + FRAME_TIME)
	}
}
