// A check and a measure of the shared queue and of the event.
//
// Several threads write records in one queue as fast as they can, and
// several threads read them. The shared queue has no lock: a thread takes
// its place with one compare-and-exchange. The last run uses a queue with
// one lock, for comparison. In the check, each writer writes a fixed count
// of records. In a [measure run](term:measure-run) the writers go on for
// one second, and the process writes the records in one second.
//
// The threads of each run wait on one event. The first thread wakes
// the event one time: all of them start together.
//
// Each record has the number of its writer and a count. A reader checks
// that the counts of each writer increase. At the end, the records that
// the readers took are the records that the writers wrote: no record is
// lost, and no record arrives two times.
//
// **What it is for.** It shows the [shared queue](term:shared-queue) and
// the [event](term:event): several writers and several readers on one
// queue with no lock and no kernel entry for a record, and one wake that
// starts many threads at once. The queue with one lock gives the measure
// to compare.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("crowd")` in the console. The window has one row for each run:
// the writers, the readers, the records that were read. The log gets one
// line for each run (`crowd: shared queue, 2 writers, 2 readers: ...`),
// then `crowd: ok, <count> runs, each record written is read one time,
// each event started all the threads`, or `crowd: wrong: ...`. In a
// measure run (`modustool measure crowd`) the window and the lines have
// the records in one second.
//
// **Its grant**: **Inspect**: the machine handle reads the kernel entries
// of this process, which the measure counts.
//
// **What it does not prove.** The rates are measures of the host of the
// run. The check is of order and of count, not of speed.
package crowd

import "modus:display"
import "modus:graphics"
import "modus:interface"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:system"
import "base:intrinsics"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module, its threads and its
// window: 1390 pages. And the glyph memory of the copy of the text
// rendering of the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 1390 + 354 = 1744.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1744, processes = 1, threads = 5, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

DURATION :: 1000 // Milliseconds of one measure, in a measure run.
RECORDS_CHECKED :: 50_000 // The records that each writer writes in the check.
CAPACITY :: 1024
THREAD_LIMIT :: 4 // The writers and the readers of one measure.
RECORD :: 1
END :: 2

LINE :: 24
BAR_WIDTH :: 200
RATE_X :: 284
ENTRIES_X :: RATE_X + BAR_WIDTH + 110
ENTRIES_HEADER :: "kernel entries, one million records"
// The widest text at the right is the header of the entries: the window
// ends 12 pixels after it, the same margin as at the left.
// The size is two literals, because the tool counts the pictures of the
// window from them; each assertion keeps a literal equal to its layout.
WIDTH :: 886
#assert(WIDTH == ENTRIES_X + len(ENTRIES_HEADER) * graphics.CELL_WIDTH + 12)
HEIGHT :: 264
#assert(HEIGHT == 12 + 3 * LINE + len(measures) * LINE + 2 * LINE + 12)

Measure :: struct {
	writers:   int,
	readers:   int,
	with_lock: bool,
	done:      bool,
	read:      u64, // The records that the readers read.
	rate:      u64, // Records in one second: a measure run only.
	entries:   u64, // Kernel entries of the process for one million records.
	wrong:     u64, // Records that are lost, that arrived two times, or that arrived before an older record of the same writer.
	together:  u64, // The threads that the event started.
}

measures: [5]Measure

// What one thread of a measure counts. Each thread has its own line of
// the cache.
Member :: struct #align (64) {
	number:   int,
	count:    u64, // The records that it wrote or read.
	disorder: u64,
	from:     [THREAD_LIMIT]u64, // A reader: the records of each writer.
}

// The queue of the measure that runs.
shared: ring.Shared // Several writers, several readers, no lock.
locked: ring.Ring // The same work with one lock: only the queue of commands.
queue_lock: system.Lock
records_event: system.Event // The queue with a lock: a record arrived.
room_event: system.Event // The queue with a lock: a record left.
with_lock: bool

start: system.Event // All the threads of a measure wait on it.
running: u32
started: u32
stop: u32 // 1: the writers end.
records_wanted: u64 // The records that each writer writes; 0: it goes on until stop.
members: [THREAD_LIMIT]Member

machine: system.Handle
slot: u64 // The slot of this process in the kernel.

// put writes a record. If the queue is full, the thread waits.
put :: proc "contextless" (record: ring.Record) {
	if with_lock {
		for {
			seen := system.event_count(&room_event)
			system.lock(&queue_lock)
			ok := ring.push(&locked.commands, record)
			system.unlock(&queue_lock)
			if ok {
				system.event_wake(&records_event)
				return
			}
			list: system.Wait
			system.wait_event(&list, &room_event, seen)
			if !system.wait_spin(&list) {
				system.wait_end(&list)
			}
		}
	}
	for !system.shared_send(&shared, record) {
		list: system.Wait
		system.wait_shared_room(&list, &shared)
		if !system.wait_spin(&list) {
			system.wait_end(&list)
		}
	}
}

// take reads a record. If the queue is empty, the thread waits.
take :: proc "contextless" () -> ring.Record {
	if with_lock {
		for {
			seen := system.event_count(&records_event)
			system.lock(&queue_lock)
			record, ok := ring.pop(&locked.commands)
			system.unlock(&queue_lock)
			if ok {
				system.event_wake(&room_event)
				return record
			}
			list: system.Wait
			system.wait_event(&list, &records_event, seen)
			if !system.wait_spin(&list) {
				system.wait_end(&list)
			}
		}
	}
	for {
		if record, ok := system.shared_receive(&shared); ok {
			return record
		}
		list: system.Wait
		system.wait_shared_records(&list, &shared)
		if !system.wait_spin(&list) {
			system.wait_end(&list)
		}
	}
}

// wait_start stops the thread until the first thread wakes the event.
wait_start :: proc "contextless" () {
	for {
		seen := system.event_count(&start)
		if intrinsics.atomic_load(&running) != 0 {
			break
		}
		system.event_wait(&start, seen)
	}
	intrinsics.atomic_add(&started, 1)
}

write_records :: proc "c" (parameter: rawptr) -> ! {
	member := (^Member)(parameter)
	wait_start()
	for intrinsics.atomic_load_explicit(&stop, .Relaxed) == 0 && (records_wanted == 0 || member.count < records_wanted) {
		put({kind = RECORD, values = {0 = u64(member.number), 1 = member.count}})
		member.count += 1
	}
	system.thread_stop()
}

read_records :: proc "c" (parameter: rawptr) -> ! {
	member := (^Member)(parameter)
	next: [THREAD_LIMIT]u64 // The least count that each writer can give now.
	wait_start()
	for {
		record := take()
		if record.kind == END {
			break
		}
		writer := record.values[0] % THREAD_LIMIT
		if record.values[1] < next[writer] {
			member.disorder += 1
		}
		next[writer] = record.values[1] + 1
		member.from[writer] += 1
		member.count += 1
	}
	system.thread_stop()
}

// entries gives the times that this process entered the kernel.
entries :: proc "contextless" () -> u64 {
	report: op.Process_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&report)), size_of(report))
	return report.entries
}

// run starts the writers and the readers of one queue. In the check each
// writer ends after RECORDS_CHECKED records; a measure run stops the
// writers after DURATION, and has the rate.
run :: proc "contextless" (measure: ^Measure) -> bool {
	measured := system.measure_run()
	memory: system.Handle
	status: system.Status
	if measure.with_lock {
		memory, locked, status = system.ring_create(CAPACITY)
	} else {
		memory, shared, status = system.shared_create(CAPACITY)
	}
	if status != .Ok {
		return false
	}
	defer {
		system.close(memory)
		system.ring_close(&locked)
		system.shared_close(&shared)
	}
	with_lock, stop, running, started = measure.with_lock, 0, 0, 0
	records_wanted = measured ? 0 : RECORDS_CHECKED
	members = {}
	threads: [THREAD_LIMIT]system.Thread
	count := measure.writers + measure.readers
	for index in 0 ..< count {
		is_writer := index < measure.writers
		members[index].number = is_writer ? index : index - measure.writers
		threads[index], status = system.thread_start(is_writer ? write_records : read_records, &members[index])
		if status != .Ok {
			return false
		}
	}
	// One wake of the event starts all the threads.
	before := entries()
	begin := system.time()
	intrinsics.atomic_store(&running, 1)
	system.event_wake(&start)
	end := begin
	if measured {
		end = system.sleep(begin + DURATION)
		intrinsics.atomic_store(&stop, 1)
	}
	for thread in threads[:measure.writers] {
		system.thread_wait(thread)
	}
	// The records of the writers are all in the queue: one last record for
	// each reader.
	for _ in 0 ..< measure.readers {
		put({kind = END})
	}
	for thread in threads[measure.writers:count] {
		system.thread_wait(thread)
	}
	after := entries()

	written, read: u64
	measure.wrong = 0
	for writer in 0 ..< measure.writers {
		written += members[writer].count
		taken: u64
		for reader in members[measure.writers:count] {
			taken += reader.from[writer]
		}
		// More: a record arrived two times. Fewer: a record is lost.
		measure.wrong += max(taken, members[writer].count) - min(taken, members[writer].count)
	}
	for reader in members[measure.writers:count] {
		read += reader.count
		measure.wrong += reader.disorder
	}
	measure.read = read
	measure.entries = (after - before) * 1_000_000 / max(read, 1)
	measure.together = u64(started)
	measure.done = true
	if measured {
		measure.rate = read * 1000 / max(end - begin, 1)
		system.log_fact(.Info, Run_Measured{writers = u64(measure.writers), readers = u64(measure.readers), records_in_one_second = measure.rate, kernel_entries = measure.entries, written_records = written, read_records = read, wrong_records = measure.wrong, queue = value_kinds.text_field(measure.with_lock ? "queue with a lock" : "shared queue", 24)})
		return read != 0 && written == read && measure.together == u64(count)
	}
	system.log_fact(.Info, Run_Checked{writers = u64(measure.writers), readers = u64(measure.readers), written_records = written, read_records = read, wrong_records = measure.wrong, kernel_entries = measure.entries, queue = value_kinds.text_field(measure.with_lock ? "queue with a lock" : "shared queue", 24)})
	return written == u64(measure.writers) * RECORDS_CHECKED && written == read && measure.together == u64(count)
}

// The columns of the table, from the left margin: the queue, the writers,
// the readers, the wrong records, the rate and the kernel entries.
COLUMN_SIZES :: [6]interface.Size{{.Pixels, 72}, {.Pixels, 72}, {.Pixels, 72}, {.Pixels, RATE_X - 228}, {.Pixels, ENTRIES_X - RATE_X}, {.Share, 1}}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	measured := system.measure_run()
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measured ? measure.rate : measure.read), max(most_entries, measure.entries)
	}
	// Each line is a line of a table: its text 4 pixels under its top.
	column := interface.column_of({12, 8, WIDTH - 24, HEIGHT - 8})
	interface.cell_text(&frame, interface.column_take(&column, LINE), measured ? "several threads write records in one queue, several threads read them, for one second." : "several threads write 50000 records each in one queue, several threads read them.", graphics.colors.dim)
	interface.cell_text(&frame, interface.column_take(&column, LINE), "one event starts the threads of a run. no record is lost, none arrives two times.", graphics.colors.dim)
	interface.column_take(&column, LINE / 2)
	sizes := COLUMN_SIZES
	cells: [len(COLUMN_SIZES)]interface.Area
	interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:])
	titles := [len(COLUMN_SIZES)]string{"queue", "writers", "readers", "wrong", measured ? "records in one second" : "records read", ENTRIES_HEADER}
	for title, index in titles {
		interface.cell_text(&frame, cells[index], title, graphics.colors.dim)
	}
	number: interface.Text_Builder
	for measure, index in measures {
		row := interface.column_take(&column, LINE)
		interface.table_band(&frame, {row.x - 6, row.y, row.width + 12, row.height}, index)
		interface.row_split(row, sizes[:], cells[:])
		interface.cell_text(&frame, cells[0], measure.with_lock ? "lock" : "shared", graphics.colors.text)
		interface.cell_text(&frame, cells[1], interface.number_text(&number, u64(measure.writers)), graphics.colors.text)
		interface.cell_text(&frame, cells[2], interface.number_text(&number, u64(measure.readers)), graphics.colors.text)
		if measure.done {
			interface.cell_text(&frame, cells[3], interface.number_text(&number, measure.wrong), measure.wrong == 0 ? graphics.colors.dim : graphics.colors.failed)
			// The records that the process moves, in its color; the run
			// with one lock is the comparison, of less weight: the dim
			// color. The kernel entries in the color of the kernel.
			interface.bar_with_value(&frame, cells[4], BAR_WIDTH, measured ? measure.rate : measure.read, most_rate, measure.wrong != 0 ? graphics.colors.failed : measure.with_lock ? graphics.colors.dim : graphics.colors.process)
			interface.bar_with_value(&frame, cells[5], BAR_WIDTH, measure.entries, most_entries, graphics.colors.kernel)
		} else {
			interface.cell_text(&frame, cells[4], "...", graphics.colors.dim)
		}
	}
	if !measured {
		interface.column_take(&column, LINE / 2)
		interface.cell_text(&frame, interface.column_take(&column, LINE), "the records in one second are a measure: run `modustool measure crowd`.", graphics.colors.dim)
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// entry finds its own slot with the machine handle, runs each queue
// (`run`), and writes the summary line: it is wrong when a record is lost,
// read two times, or out of the order of its writer. The process then keeps
// its window open until it is stopped; with no window, it stops with
// `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "crowd")
	if !ok {
		system.stop(.Failed)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	for index in 1 ..< report.process_slots {
		process: op.Process_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), index, u64(uintptr(&process)), size_of(process))
		if process.state != .None && process.state != .Stopped && system.name_of(process.name[:]) == "crowd" {
			slot = index
		}
	}
	measures = {{writers = 1, readers = 1}, {writers = 2, readers = 2}, {writers = 3, readers = 1}, {writers = 1, readers = 3}, {writers = 2, readers = 2, with_lock = true}}
	draw(&window)
	wrong := slot == 0
	total_wrong: u64
	for &measure in measures {
		if !run(&measure) {
			wrong = true
		}
		total_wrong += measure.wrong
		draw(&window)
	}
	if wrong || total_wrong != 0 {
		system.log_fact(.Info, Crowd_Wrong{wrong_records = total_wrong})
	} else {
		system.log_fact(.Info, Crowd_Held{runs = u64(len(measures))})
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
