// A developer tool: the memory and the execution of one process, live
// (docs/TOOLS.md).
//
// **What it is for.** A reader who wants to see how one process runs: where
// its memory is, which modules it holds, what its threads do now, and
// where it stopped if it faulted. It shows that a
// [developer tool](term:developer-tool) needs no special access: it reads
// the reports of the kernel with a [grant](term:grant), the same reports
// that any holder of the machine with **Inspect** can ask for, and it
// changes nothing.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("inspect")` in the console. The window has a list of the processes
// at the left. The input chooses one: Up and Down, a click, or letters that
// filter the list. The window then shows, for that process:
//
// - its address space, as one band scaled by address and as a table: each
//   mapping, its kind (module code, module data, thread area, device,
//   shared memory...), its pages and the pages that have a page frame;
// - its modules: the name in the boot image, the hash, the base, the size;
// - its threads, with the state of the scheduler: the processor, the
//   weight, the virtual time, the lag, the word wait;
// - the [stop report](term:stop-report) of a process that stopped on a
//   fault, each frame as its procedure and its source line when the
//   [debug image](term:debug-image) names it, else as `module + offset`.
//
// A sample of the reports comes each 250 ms; a value that changed is drawn
// in the color of the boot program for one sample. Space freezes the
// sample. Tab shows the bytes of the memory of this process itself
// (`hex.odin`). The log gets `inspect: ok, <count> processes; ...` at the
// start.
//
// **Its grants**: **Inspect** (the machine handle that reads the reports),
// **Image** (the names of the modules and their exports), **Debug_Image**
// (the names of the procedures and the source lines), and **Serve** (its
// exports). Nothing more: it reads reports, it changes nothing, and it reads
// no byte of another process.
//
// **Its exports** (`exports.odin`) give the same facts as tables, to a
// caller that [acts for the principal](term:acts-for-the-principal):
// `mappings`, `threads` and `modules`, each for one process by its name.
//
// ```
// connect("inspect")
// inspect.threads("console")
// ```
//
// **What it does not show.** The bytes of another process: no report gives
// them, and the system has no right that reads them. A process is chosen by
// its slot and its serial, not by its name, in the window; the exports
// take a name, and of two processes with one name they give the one in the
// lowest slot. The
// design is in docs/TOOLS.md, "The process `inspect`", and "What `inspect`
// does not read: the bytes of another process".
package inspect

import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "internal:inspect/addresses"
import "modus:display"
import "modus:graphics"
import "modus:layout"
import "modus:system"

SAMPLE_INTERVAL :: 250 // Milliseconds.
KEY_TAB :: 0x0F
FILTER_CAPACITY :: 24
PROCESS_SLOTS :: 64 // The process slots of the kernel (System_Report.process_slots).

Entry :: struct {
	slot:           u64,
	process_serial: u64, // The process in the slot: a new process in the slot has another serial.
	name:           [32]u8,
	state:          op.Process_State,
}

// One sample: the reports of the kernel at one time.
Sample :: struct {
	slot:         u64, // The process of the sample. 0: none.
	process:      op.Process_Report,
	mappings:     op.Process_Mapping_Report,
	modules:      op.Module_Report,
	threads:      op.Thread_Table_Report,
	stop:         op.Stop_Report,
	nanoseconds:  u64, // The time of the sample.
	entries:      u64, // Its kernel entries.
	time:         u64, // When it was taken, in milliseconds.
}

machine: system.Handle
image: []u8
debug_names: system.Debug_Names // The debug image and the verdicts of its objects. With no image, the frames are "module + offset".
entries: [PROCESS_SLOTS]Entry
entry_count: int
shown: [PROCESS_SLOTS]int // The indexes in entries that the filter keeps.
shown_count: int
filter: [FILTER_CAPACITY]u8
filter_count: int
// The chosen process: its slot and its serial, not its name (two processes
// can have one name). When it ends, nothing is chosen.
selected_slot: u64
selected_process_serial: u64
fresh: Sample // The reports of a sample before the check of their serials.
dropped_samples: u64 // Samples whose reports came from two processes of one slot.
current, previous: Sample
frozen: bool
hex_view: bool
samples: u64
logged_slot: u64 // The process whose counts the log has: its slot and its serial.
logged_process_serial: u64

inspect_call :: proc "contextless" (kind: op.Inspect_Kind, index: u64, record: rawptr, size: int) -> bool {
	_, status := system.call(.Inspect, u64(machine), u64(kind), index, u64(uintptr(record)), u64(size))
	return status == .Ok
}

// slot_of gives the slot of the process with a name, or 0.
slot_of :: proc "contextless" (name: string) -> u64 {
	for slot in 1 ..< u64(PROCESS_SLOTS) {
		report: op.Process_Report
		if inspect_call(.Process, slot, &report, size_of(report)) && report.state != .None && system.name_of(report.name[:]) == name {
			return slot
		}
	}
	return 0
}

// list_read reads the processes of the machine, and keeps the ones that the
// filter keeps.
list_read :: proc "contextless" () {
	entry_count = 0
	for slot in 1 ..< u64(PROCESS_SLOTS) {
		report: op.Process_Report
		if !inspect_call(.Process, slot, &report, size_of(report)) || report.state == .None {
			continue
		}
		entries[entry_count] = {slot = slot, process_serial = report.process_serial, name = report.name, state = report.state}
		entry_count += 1
	}
	shown_count = 0
	typed := string(filter[:filter_count])
	for &entry, index in entries[:entry_count] {
		if contains(system.name_of(entry.name[:]), typed) {
			shown[shown_count] = index
			shown_count += 1
		}
	}
	list_rows_update()
}

contains :: proc "contextless" (text, part: string) -> bool {
	if len(part) == 0 {
		return true
	}
	for start in 0 ..= len(text) - min(len(part), len(text)) {
		if len(text) - start >= len(part) && text[start:][:len(part)] == part {
			return true
		}
	}
	return false
}

// sample_take reads each report of the chosen process.
sample_take :: proc "contextless" () {
	start := system.nanoseconds()
	before := system.kernel_entries()
	list_read()
	slot := u64(0)
	for &entry in entries[:entry_count] {
		if entry.slot == selected_slot && entry.process_serial == selected_process_serial {
			slot = entry.slot
		}
	}
	fresh = {slot = slot}
	if slot != 0 {
		inspect_call(.Process, slot, &fresh.process, size_of(fresh.process))
		inspect_call(.Process_Mappings, slot, &fresh.mappings, size_of(fresh.mappings))
		inspect_call(.Modules, slot, &fresh.modules, size_of(fresh.modules))
		inspect_call(.Threads, slot, &fresh.threads, size_of(fresh.threads))
		inspect_call(.Stop, slot, &fresh.stop, size_of(fresh.stop))
		// A new process in the slot between two reports: the sample mixes two
		// processes, and the window keeps the sample before.
		serial := selected_process_serial
		if fresh.process.process_serial != serial || fresh.mappings.process_serial != serial || fresh.modules.process_serial != serial || fresh.threads.process_serial != serial || fresh.stop.process_serial != serial {
			dropped_samples += 1
			if dropped_samples <= 4 {
				system.log_fact(.Info, Sample_Mixed{slot = slot, dropped = dropped_samples})
			}
			current.time = system.time()
			return
		}
	}
	previous = current
	current = fresh
	current.nanoseconds = system.nanoseconds() - start
	current.entries = system.kernel_entries() - before
	current.time = system.time()
	samples += 1
	frame_names_update()
	if slot != 0 && (slot != logged_slot || selected_process_serial != logged_process_serial) {
		logged_slot, logged_process_serial = slot, selected_process_serial
		sample_log()
	}
}

// sample_log writes the counts of the chosen process on the log, one time
// for each choice: the test compares them with the reports of monitor.
sample_log :: proc "contextless" () {
	present: u64
	pages: u64
	for &mapping in current.mappings.mappings[:current.mappings.count] {
		pages += mapping.page_count
		present += mapping.present
	}
	system.log_fact(.Info, Process_Counts{mappings = current.mappings.count, mapped_pages = pages, present_pages = present, threads = current.threads.count, modules = current.modules.count, kernel_mapped_pages = current.process.mapped_pages, kernel_threads = current.process.thread_count, sampled_process = process_field(current.process.name[:])})
	system.log_fact(.Info, Sample_Cost{elapsed = value_kinds.Time_In_Microseconds(current.nanoseconds / 1000), kernel_entries = current.entries, sampled_process = process_field(current.process.name[:])})
	if current.stop.cause != 0 {
		stop_log(&current.stop)
	}
}

// address_write writes an address as "module + offset" when a module record
// of the chosen process holds it, else as a number.
address_write :: proc "contextless" (writer: ^system.Writer, address: u64, near := false) {
	modules := current.modules.modules[:min(current.modules.count, op.PROCESS_MODULE_CAPACITY)]
	index, offset := addresses.module_of(address, modules)
	if index < 0 {
		system.write_number(writer, address)
		return
	}
	record := &modules[index]
	file := module_file(record.hash)
	if entry := system.image_entry_of(image, record.hash); entry != nil {
		system.write_part(writer, system.name_of(entry.name[:]))
	} else {
		system.write_hash(writer, record.hash)
	}
	system.write_part(writer, " + ")
	system.write_number(writer, offset)
	if near && file != nil {
		if name, distance, ok := addresses.near_export(file, record.base, address); ok {
			system.write_part(writer, ", near ")
			system.write_part(writer, name)
			if distance != 0 {
				system.write_part(writer, " + ")
				system.write_number(writer, distance)
			}
		}
	}
}

// module_file gives the file of a module of the boot image, by its hash.
module_file :: proc "contextless" (hash: [32]u8) -> []u8 {
	entry := system.image_entry_of(image, hash)
	if entry == nil || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
		return nil
	}
	return image[entry.offset:][:entry.size]
}

// The names of the frames of the stop report of the sample, from the
// debug image. They are made when the stop report changes, not at each
// picture: a name costs the check of a debug object.
//
// The size of a name is the longest text that system.place_write gives for
// the sources of the system: the procedure with its package, its offset,
// the module, the path of the file and the line. A name of a module from
// another repository can be longer: the writer then ends it with the cut
// mark, and the window shows the mark.
FRAME_PROCEDURE_BYTES :: 104 // "package::procedure": the longest name of a procedure of the sources has 73 bytes, a package 24.
FRAME_OFFSET_BYTES :: len(" + 0x") + 16
FRAME_MODULE_BYTES :: len(" in ") + 31 // The name of a module of the boot image.
FRAME_PATH_BYTES :: len(" (") + 80 + len(":") + 8 + len(")") // The longest path of the sources has 80 bytes; a line has at most 8 digits.
FRAME_NAME_CAPACITY :: 256
#assert(FRAME_NAME_CAPACITY >= FRAME_PROCEDURE_BYTES + FRAME_OFFSET_BYTES + FRAME_MODULE_BYTES + FRAME_PATH_BYTES)
Frame_Names :: struct {
	report: op.Stop_Report, // The stop report of these names.
	texts:  [op.STOP_FRAME_CAPACITY][FRAME_NAME_CAPACITY]u8,
	counts: [op.STOP_FRAME_CAPACITY]int, // 0: the frame has no name.
}
frame_names: Frame_Names

frame_names_update :: proc "contextless" () {
	if debug_names.image == nil || current.stop == frame_names.report {
		return
	}
	frame_names.report = current.stop
	frame_names.counts = {}
	stop := &frame_names.report
	for &frame, number in stop.frames[:min(stop.frame_count, op.STOP_FRAME_CAPACITY)] {
		entry := system.image_entry_of(image, frame.hash)
		if frame.base == 0 || entry == nil {
			continue
		}
		writer := system.Writer{buffer = frame_names.texts[number][:]}
		if system.place_write(&writer, system.debug_object_of(&debug_names, frame.hash), frame.address - frame.base, system.name_of(entry.name[:]), number > 0) {
			frame_names.counts[number] = len(system.written(&writer))
		}
	}
}

// frame_name gives the name of a frame of the stop report of the sample:
// "fault::three + 0x8 in fault (src/modules/demonstrations/fault/main.odin:15)", or "".
frame_name :: proc "contextless" (number: int) -> string {
	if number < 0 || number >= op.STOP_FRAME_CAPACITY || current.stop != frame_names.report {
		return ""
	}
	return string(frame_names.texts[number][:frame_names.counts[number]])
}

// stop_log writes a stop report on the log: the fault and its address,
// then one fact for each frame of the stack, then the values that the
// kernel hid. A frame is its place as the window names it: the name of its
// procedure and its line from the debug image, or a module and an offset,
// or "not code".
stop_log :: proc "contextless" (stop: ^op.Stop_Report) {
	sampled_process := process_field(current.process.name[:])
	if stop.vector == 14 {
		system.log_fact(.Info, Stopped_On_Page_Fault{address = value_kinds.Hexadecimal_No_Leading_Zero(stop.address), sampled_process = sampled_process})
	} else {
		system.log_fact(.Info, Stopped_On_Fault{address = value_kinds.Hexadecimal_No_Leading_Zero(stop.address), sampled_process = sampled_process})
	}
	for &frame, number in stop.frames[:min(stop.frame_count, op.STOP_FRAME_CAPACITY)] {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		if frame.address == 0 {
			system.write_part(&writer, "not code")
		} else if name := frame_name(number); name != "" {
			system.write_part(&writer, name)
		} else {
			address_write(&writer, frame.address, true)
		}
		system.log_fact(.Info, Stack_Frame{frame = u64(number), sampled_process = sampled_process}, system.written(&writer))
	}
	if stop.hidden_value_count != 0 {
		system.log_fact(.Info, Values_Hidden{hidden_values = u64(stop.hidden_value_count), sampled_process = sampled_process})
	}
}

choose :: proc "contextless" (position: int) {
	if position < 0 || position >= shown_count {
		return
	}
	selected_slot = entries[shown[position]].slot
	selected_process_serial = entries[shown[position]].process_serial
	frozen = false
	sample_take()
}

position_of_selected :: proc "contextless" () -> int {
	for position in 0 ..< shown_count {
		if entries[shown[position]].slot == selected_slot && entries[shown[position]].process_serial == selected_process_serial {
			return position
		}
	}
	return -1
}

key :: proc "contextless" (event: display.Event) {
	switch {
	case event.code == display.KEY_UP:
		choose(max(position_of_selected() - 1, 0))
	case event.code == display.KEY_DOWN:
		choose(min(position_of_selected() + 1, shown_count - 1))
	case event.code == KEY_TAB:
		hex_view = !hex_view
		if hex_view {
			system.log_fact(.Info, Own_Memory_Shown{})
		} else {
			system.log_fact(.Info, Reports_Shown{sampled_process = process_field(current.process.name[:])})
		}
	case event.character == ' ':
		frozen = !frozen
		system.log_fact(.Info, Sample_State_Changed{sample_state = value_kinds.text_field(frozen ? "frozen" : "live", SAMPLE_STATE_FIELD_BYTES)})
	case event.code == display.KEY_BACKSPACE:
		had := filter_count
		filter_count = max(filter_count - 1, 0)
		list_read()
		if had == 1 {
			system.log_fact(.Info, Filter_Emptied{processes = u64(shown_count)})
		}
	case event.code == display.KEY_ENTER:
		choose(0)
	case event.character >= 'a' && event.character <= 'z' || event.character == '_' || event.character >= '0' && event.character <= '9':
		if filter_count < FILTER_CAPACITY {
			filter[filter_count] = u8(event.character) // A letter, a digit or "_": one byte.
			filter_count += 1
		}
		list_read()
		if position_of_selected() < 0 {
			choose(0)
		}
	}
}

// entry opens the window of `inspect` and runs its loop: one sample of the
// reports each 250 ms, until the process is stopped.
//
// **What it sets up**: a window of `WIDTH` by `HEIGHT` pixels; the machine
// handle with **Inspect**; the boot image and the debug image, read-only;
// the service ring of its exports; the hex view of its own memory. The first
// process that it shows is `inspect` itself. It writes
// `inspect: ok, <count> processes; up, down, letters: choose; ...` on the
// log.
//
// **The loop.** It draws the window, then waits for an event of the window
// or a call until the time of the next sample. A key or a click in the
// list changes the chosen process and draws again at once. A call runs
// between two samples. At the time of the sample it takes a new sample, or,
// when Space froze the sample, it only reads the list of the processes
// again.
//
// **The stop**: with no window, it stops with `Failed`. Else it never
// returns: `stop("inspect")`, or the close button of its window, ends it.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "inspect")
	if !ok {
		system.stop(.Failed)
	}
	// The list counts the lines of its names in the column of the names, so
	// the places come before the first read of the list. A window of its
	// own size always takes its tree.
	element_tokens, _ = layout.tokens_for(graphics.appearance, .Standard)
	places, _ = inspect_layout(window.width, window.height, element_tokens)
	machine = ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	debug_names = system.debug_names_of(ctx)
	service, _ = system.service_open(ctx)
	hex_start()
	// The first process: this one, until the input chooses.
	list_read()
	for &item in entries[:entry_count] {
		if system.name_of(item.name[:]) == "inspect" {
			selected_slot, selected_process_serial = item.slot, item.process_serial
		}
	}
	sample_take()
	system.log_fact(.Info, Window_Ready{processes = u64(entry_count)})
	for {
		draw(&window)
		next := current.time + SAMPLE_INTERVAL
		for {
			wait: system.Wait
			display.wait_events(&wait, &window)
			system.service_wait(&wait, &service)
			now := system.wait_end(&wait, next)
			system.service_run(&service)
			changed := false
			for event in display.next_event(&window) {
				// The keys and the pointer of the window are the process's own:
				// the interface package draws, and takes no input here.
				if event.kind == .Key && event.pressed {
					key(event)
					changed = true
				} else if event.kind == .Pointer && event.buttons & display.BUTTON_LEFT != 0 {
					if position, inside := list_place(event.x, event.y); inside {
						choose(position)
						changed = true
					}
				}
			}
			if changed {
				draw(&window)
			}
			if now >= next {
				break
			}
		}
		if !frozen {
			sample_take()
		} else {
			list_read()
			current.time = system.time()
		}
	}
}
