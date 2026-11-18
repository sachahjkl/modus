// A system tool: the memory of the machine and the processes that run, as a
// picture that changes twice per second. It needs the grant to inspect the machine.
//
// It is also a service: processes(), counts() and count() give the same
// facts as tables of records (exports.odin).
//
// **What it is for.** It shows what the machine does now, from the reports
// of the kernel and not from a process that counts for itself: the memory
// in use and reserved, the kernel entries, the interrupts, the waits of the
// locks of the kernel, and one row for each process with its pages and its
// share of the processor in the last half second. A disk process shows its
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
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import op "modus:contract/operation"
import "modus:support/system"

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(512, 8192)

WIDTH :: 520
// The rows of about 20 processes, and one last line that counts the processes
// whose rows do not fit.
HEIGHT :: 560
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
	system.log("monitor: the disk process ", nickname, ", hash prefix ", string(prefix[:]), ", the file ", system.Hash{hash[:]}, ", from the root service")
}

// The entry of the monitor: it opens its window and its service, then draws
// a picture of the machine every 500 ms and runs the calls between two
// pictures.
//
// With no window it stops with the code 1. Each turn of the loop:
//
// 1. asks the kernel for the system report, then the report of each
//    process slot that is in use;
// 2. draws the memory bar, the counters, the locks and one row for each
//    process; the first picture writes "monitor: ok";
// 3. waits until the next picture, and runs each call of a caller as it
//    comes: a caller never waits for a picture.
//
// The monitor never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "monitor")
	if !ok {
		system.stop(1)
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
				system.log("monitor: no grant to inspect the machine")
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
			// The pages in use are memory.
			interface.draw_rectangle(table, 10, y, int(u64(WIDTH - 20) * used / max(report.page_count, 1)), 10, graphics.colors.memory)
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
			y += LINE + 6
			interface.draw_text(table, 10, y, "process", graphics.colors.dim)
			interface.draw_text(table, PAGES_X, y, "pages", graphics.colors.dim)
			interface.draw_text(table, BAR_X, y, "processor", graphics.colors.dim)
			y += LINE

			text_line := interface.line_height({})
			hidden: u64 // The processes whose rows do not fit in the window.
			for slot in 1 ..< min(report.process_slots, PROCESS_SLOTS) {
				process: op.Process_Report
				system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process))
				if process.state == .None {
					previous_run_time[slot] = 0
					continue
				}
				share := min((process.run_time - min(previous_run_time[slot], process.run_time)) * 100 / elapsed, 100)
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
				// text; each more line of text adds its height. A row that
				// does not fit above the last line is counted, not cut.
				lines := max(interface.text_wrapped_line_count(table, {}, name, NAME_ROOM), 1) + (from_disk ? 1 : 0)
				row_height := LINE + (lines - 1) * text_line
				if y + row_height > HEIGHT - LINE {
					hidden += 1
					continue
				}
				name_lines := interface.draw_text_wrapped(table, 10, y, NAME_ROOM, name, graphics.colors.text)
				if from_disk {
					prefix: [process_page.HASH_PREFIX_DIGITS]u8
					process_page.hash_prefix_write(&prefix, row.hash[0])
					interface.draw_text(table, 10, y + name_lines * text_line, string(prefix[:]), graphics.colors.dim)
					disk_process_log(slot, process.process_serial, name, row)
				}
				interface.draw_unsigned(table, PAGES_X, y, process.present_pages, graphics.colors.text)
				interface.draw_rectangle(table, BAR_X, y + 2, BAR_WIDTH, 10, graphics.colors.track)
				// The share of the processor that a process took: a measure
				// of a process.
				interface.draw_rectangle(table, BAR_X, y + 2, int(share) * BAR_WIDTH / 100, 10, graphics.colors.process)
				x = interface.draw_unsigned(table, BAR_X + BAR_WIDTH + 8, y, share, graphics.colors.text)
				interface.draw_text(table, x, y, "%", graphics.colors.text)
				y += row_height
			}
			if hidden > 0 {
				x = interface.draw_unsigned(table, 10, y, hidden, graphics.colors.text)
				interface.draw_text(table, x, y, " more processes: monitor.processes() gives them", graphics.colors.dim)
			}
		}
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		pictures += 1
		if !logged {
			system.log("monitor: ok")
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
