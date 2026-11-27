// A check and a measure of one ring: the ring is the base interface of the
// kernel and the one way that processes communicate.
//
// One thread writes records in a ring as fast as it can. A second thread
// reads them. No queue operation enters the kernel: a thread enters the
// kernel only to wait, and to wake the other thread. The check sends a
// fixed count of records and counts the records that did not arrive in
// order. In a [measure run](term:measure-run) the threads go on for one
// second, and the process writes the records in one second. In the two
// runs it asks the kernel how many times the process entered it.
//
// It runs four rings: two capacities, and two ways to wait. A thread
// that waits at once enters the kernel each time the queue is full or
// empty. A thread that first reads the counters for a short time
// (system.wait_spin) finds most of the time that the other thread
// continued.
//
// **What it is for.** It shows that a [ring](term:ring) is a
// non-blocking queue in shared memory: the records move with no kernel
// entry, and the count of kernel entries for one million records shows
// how rarely a thread must wait.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("flow")` in the console. The window shows the four rings: the
// records read in order, and the kernel entries for one million records.
// The log gets one line for each ring (`flow: capacity 32, wait at once:
// 200000 records read in order, 0 lost, ...`), then `flow: ok, 4 rings, 0
// records lost`, or `flow: wrong: ...`. In a measure run (`modustool
// measure flow`) the window and the lines have the records in one second.
//
// **Its grant**: **Inspect**: the machine handle reads the kernel entries
// of this process, which the measure counts.
//
// **What it does not prove.** The rates are measures of the host of the
// run, printed and never compared to a bound.
package flow

import "modus:display"
import "modus:graphics"
import "modus:interface"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:system"
import "base:intrinsics"

// The tool counts the module, its load, its stacks and 3 threads, its window at the largest scale.
MODULE_BUDGET :: system.Stated_Budget{threads = 3, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

DURATION :: 1000 // Milliseconds of one measure, in a measure run.
RECORDS_CHECKED :: 200_000 // The records that the writer sends in the check.
RECORD :: 1
END :: 2

LINE :: 24
BAR_WIDTH :: 220
RATE_X :: 232
ENTRIES_X :: RATE_X + BAR_WIDTH + 110
// The size is two literals, because the tool counts the pictures of the
// window from them; each assertion keeps a literal equal to its layout.
WIDTH :: 878
#assert(WIDTH == ENTRIES_X + BAR_WIDTH + 96)
HEIGHT :: 240
#assert(HEIGHT == 12 + 3 * LINE + len(measures) * LINE + 2 * LINE + 12)

Measure :: struct {
	capacity: u32,
	spin:     bool,
	done:     bool,
	received: u64, // The records that the reader read.
	rate:     u64, // Records in one second: a measure run only.
	entries:  u64, // Kernel entries of the process for one million records.
	lost:     u64, // Records that did not arrive in order.
}

measures: [4]Measure

// The ring of the measure that runs, and what its two threads share.
queue: ring.Ring
spin: bool
stop: u32 // 1: the writer writes its last record.
records_wanted: u64 // The records that the writer sends before its last one; 0: it goes on until stop.
received: u64
lost: u64

machine: system.Handle
slot: u64 // The slot of this process in the kernel.

// wait waits for a queue: for room if this thread writes it, for a record
// if this thread reads it.
wait :: proc "contextless" (side: ^ring.Queue, for_room: bool) {
	list: system.Wait
	if for_room {
		system.wait_room(&list, side)
	} else {
		system.wait_records(&list, side)
	}
	if spin && system.wait_spin(&list) {
		return
	}
	system.wait_end(&list)
}

write_records :: proc "c" (parameter: rawptr) -> ! {
	side := &queue.commands
	sequence: u64
	for intrinsics.atomic_load_explicit(&stop, .Relaxed) == 0 && (records_wanted == 0 || sequence < records_wanted) {
		if system.send(side, ring.Record{kind = RECORD, values = {0 = sequence}}) {
			sequence += 1
		} else {
			wait(side, true)
		}
	}
	for !system.send(side, ring.Record{kind = END}) {
		wait(side, true)
	}
	system.thread_stop()
}

read_records :: proc "c" (parameter: rawptr) -> ! {
	side := &queue.commands
	count, wrong: u64
	for {
		record, ok := system.receive(side)
		if !ok {
			wait(side, false)
			continue
		}
		if record.kind == END {
			break
		}
		if record.values[0] != count {
			wrong += 1
		}
		count += 1
	}
	received, lost = count, wrong
	system.thread_stop()
}

// entries gives the times that this process entered the kernel.
entries :: proc "contextless" () -> u64 {
	report: op.Process_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&report)), size_of(report))
	return report.entries
}

// run sends records through one ring. The check ends when the writer
// sent RECORDS_CHECKED records and the reader read the last one; a measure
// run stops the writer after DURATION, and has the rate.
run :: proc "contextless" (measure: ^Measure) -> bool {
	measured := system.measure_run()
	memory, mapped, status := system.ring_create(measure.capacity)
	if status != .Succeeded {
		return false
	}
	defer system.close(memory)
	queue, spin, stop, received, lost = mapped, measure.spin, 0, 0, 0
	records_wanted = measured ? 0 : RECORDS_CHECKED
	defer system.ring_close(&queue)
	before := entries()
	start := system.time()
	reader, reader_status := system.thread_start(read_records, nil)
	writer, writer_status := system.thread_start(write_records, nil)
	if reader_status != .Succeeded || writer_status != .Succeeded {
		return false
	}
	end := start
	if measured {
		end = system.sleep(start + DURATION)
		intrinsics.atomic_store(&stop, 1)
	}
	system.thread_wait(writer)
	system.thread_wait(reader)
	after := entries()
	measure.received = received
	measure.entries = (after - before) * 1_000_000 / max(received, 1)
	measure.lost = lost
	measure.done = true
	waiting := value_kinds.text_field(measure.spin ? "read the counters then wait" : "wait at once", 32)
	if measured {
		measure.rate = received * 1000 / max(end - start, 1)
		system.log_fact(.Info, Ring_Measured{capacity = u64(measure.capacity), records_in_one_second = measure.rate, kernel_entries = measure.entries, lost_records = lost, waiting = waiting})
		return received != 0
	}
	system.log_fact(.Info, Ring_Checked{capacity = u64(measure.capacity), read_records = received, lost_records = lost, kernel_entries = measure.entries, waiting = waiting})
	return received == RECORDS_CHECKED
}

// The columns of the table, from the left margin: the capacity, what the
// reader does before a wait, the rate and the kernel entries.
COLUMN_SIZES :: [4]interface.Size{{.Pixels, 80}, {.Pixels, RATE_X - 92}, {.Pixels, ENTRIES_X - RATE_X}, {.Share, 1}}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	measured := system.measure_run()
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measured ? measure.rate : measure.received), max(most_entries, measure.entries)
	}
	// Each line is a line of a table: its text 4 pixels under its top.
	column := interface.column_of({12, 8, WIDTH - 24, HEIGHT - 8})
	interface.cell_text(&frame, interface.column_take(&column, LINE), measured ? "one thread writes records in a ring, one thread reads them, for one second." : "one thread writes 200000 records in a ring, one thread reads them.", graphics.colors.dim)
	interface.cell_text(&frame, interface.column_take(&column, LINE), "a queue operation does not enter the kernel. a wait does.", graphics.colors.dim)
	interface.column_take(&column, LINE / 2)
	sizes := COLUMN_SIZES
	cells: [len(COLUMN_SIZES)]interface.Area
	interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:])
	titles := [len(COLUMN_SIZES)]string{"capacity", "before a wait", measured ? "records in one second" : "records read in order", "kernel entries, one million records"}
	for title, index in titles {
		interface.cell_text(&frame, cells[index], title, graphics.colors.dim)
	}
	number: interface.Text_Builder
	for measure, index in measures {
		row := interface.column_take(&column, LINE)
		interface.table_band(&frame, {row.x - 6, row.y, row.width + 12, row.height}, index)
		interface.row_split(row, sizes[:], cells[:])
		interface.cell_text(&frame, cells[0], interface.number_text(&number, u64(measure.capacity)), graphics.colors.text)
		interface.cell_text(&frame, cells[1], measure.spin ? "read counters" : "nothing", graphics.colors.text)
		if measure.done {
			interface.bar_with_value(&frame, cells[2], BAR_WIDTH, measured ? measure.rate : measure.received - measure.lost, most_rate, measure.lost == 0 ? graphics.colors.process : graphics.colors.failed)
			interface.bar_with_value(&frame, cells[3], BAR_WIDTH, measure.entries, most_entries, graphics.colors.kernel)
		} else {
			interface.cell_text(&frame, cells[2], "...", graphics.colors.dim)
		}
	}
	if !measured {
		interface.column_take(&column, LINE / 2)
		interface.cell_text(&frame, interface.column_take(&column, LINE), "the records in one second are a measure: run `modustool measure flow`.", graphics.colors.dim)
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// entry finds its own slot with the machine handle, runs the four rings
// (`run`), and writes the summary line. A ring is wrong when a record is
// lost, when the check did not read each record, or when the process found
// no slot. The process then keeps its
// window open until it is stopped; with no window, it stops with the code
// 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "flow")
	if !ok {
		system.stop(.Failed)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	for index in 1 ..< report.process_slots {
		process: op.Process_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), index, u64(uintptr(&process)), size_of(process))
		if process.state != .None && process.state != .Stopped && system.name_of(process.name[:]) == "flow" {
			slot = index
		}
	}
	measures = {{capacity = 32}, {capacity = 32, spin = true}, {capacity = 1024}, {capacity = 1024, spin = true}}
	draw(&window)
	wrong := slot == 0
	total_lost: u64
	for &measure in measures {
		if !run(&measure) {
			wrong = true
		}
		total_lost += measure.lost
		draw(&window)
	}
	if wrong || total_lost != 0 {
		system.log_fact(.Info, Flow_Wrong{lost_records = total_lost})
	} else {
		system.log_fact(.Info, Flow_Held{rings = u64(len(measures))})
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in interface.window_next_event(&window_memory.drawing, &window) {
		}
	}
}
