// The process `linux`: a shell of Linux in a terminal window
// (src/md/features/linux_shell.md).
//
// It reads a Linux kernel and an initial archive from its private store,
// boots the kernel in a guest with the machine of modus:contract/guest_os,
// and joins the virtio console of the guest, the terminal hvc0 of Linux
// where its shell runs, to its terminal: the lines of hvc0 are the lines of
// the terminal, and the keys of the terminal are the bytes that hvc0
// reads. The serial port of the guest carries the log of the kernel: its
// lines go to the log of the system only. An idle guest waits for a key, or
// for the next tick of its timer in the time of the machine. A paste waits
// here until the guest has room for it, and a resize of the window gives
// the guest its new size: the width of the console line, and the size of
// the virtio console, which Linux gives the shell as SIGWINCH.
//
// **Start**: from the start menu, or `start("linux")` in the console. The
// root service starts its terminal with it.
//
// **Grants**: **Terminal**, the console of the guest; **Store**, the private
// store `linux` with the objects `kernel` and `initial_archive`.
//
// **What a reader sees**: a terminal window with the status line "Linux
// starts", then a shell. On the log: "linux: boots the kernel of ...", one
// line "linux: guest: <line>" for each line of the kernel log, one line
// "linux: shell: <line>" for each line of the shell, and at the end
// "linux: the guest halted after N exits: the process ends" when the guest
// runs `poweroff`.
package linux_shell

import "modus:contract/call_outcome"
import "modus:contract/errors"
import gb "modus:contract/guest_builder"
import "modus:contract/guest_os"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:guest_regions"
import "modus:storage"
import "modus:system"
import terminal "modus:terminal"

// The memory of the guest comes from the budget that the starter granted
// (src/md/features/linux_shell.md, "The machine"): the pages that the
// budget has left at the start, less the nested page table of the guest
// and the reserve of this process. Below the least, the guest does not
// start: a kernel of a distribution unpacks into about 56 MiB above its
// place at 16 MiB, and the initial archive and the copy of the image wait
// above it.
GUEST_MEMORY_PAGES_LEAST :: u64(32_768) // 128 MiB.
// The pages that this process keeps for itself: its buffers, and the
// records that the kernel makes for the guest process.
PROCESS_RESERVE_PAGES :: u64(1_920)
// The least free pages after ready that start a 128 MiB Linux guest: the guest
// RAM, its nested page table and the reserve of this process.
LEAST_GUEST_BUDGET_PAGES :: GUEST_MEMORY_PAGES_LEAST + GUEST_MEMORY_PAGES_LEAST / 512 + 64 + PROCESS_RESERVE_PAGES
// The tool counts the module, its load, this process with its guest process,
// and one thread. Guest memory allocates after ready from linux's default plan
// budget row (one quarter of the machine's pages); a larger grant gives a
// larger guest.
MODULE_BUDGET :: system.Stated_Budget{processes = 2, threads = 1}

// guest_memory_pages_of gives the pages of guest memory that a budget with
// free_pages left pays: the guest, one page of its nested page table for
// each 2 MiB of it and 64 above them, and the reserve, rounded down to
// whole MiB. 0 below the least. The contract bounds the most.
guest_memory_pages_of :: proc "contextless" (free_pages: u64) -> u64 {
	if free_pages <= PROCESS_RESERVE_PAGES + 64 {
		return 0
	}
	room := free_pages - PROCESS_RESERVE_PAGES - 64
	pages := room - room / 513
	for pages + pages / 512 > room {
		pages -= 1
	}
	pages = min(pages, gb.MAX_GUEST_MEMORY_PAGES) &~ 255
	return pages >= GUEST_MEMORY_PAGES_LEAST ? pages : 0
}

GUEST_PROCESS_NAME :: "linux guest"
KERNEL_OBJECT :: "kernel"
INITIAL_ARCHIVE_OBJECT :: "initial_archive"

// The bytes that one look at a console of the guest takes.
OUTPUT_BYTES_AT_ONCE :: 512

machine: guest_os.Linux_Machine
console: guest_os.Console_Line // The lines of hvc0, the shell: the window shows them.
kernel_log: guest_os.Console_Line // The lines of the serial port, the log of the kernel: the log of the system takes them.
guest_memory_pages: u64
guest_memory_bytes: u64
output: terminal.Terminal
guest_ram: guest_regions.Owned_Memory
guest: system.Handle
exits: u64
runs: u64 // Each Guest_Run: the exits of the guest and the exits Interrupted.
pending: Pending_Input // The keys and the pastes that wait for room in the virtio console.
started: bool // The shell wrote its first byte on hvc0: the status line left.

// The most bytes of one key (key_bytes).
KEY_BYTES_MOST :: 4

// key_bytes gives the bytes that a key sends to the serial port of the
// guest (src/md/features/linux_shell.md, "The keys"): at most 4.
key_bytes :: proc "contextless" (pressed: terminal.Key) -> (bytes: [4]u8, count: int) {
	ESCAPE :: u8(0x1B)
	switch pressed.code {
	case display.KEY_ENTER:
		return {'\r', 0, 0, 0}, 1
	case display.KEY_BACKSPACE:
		return {0x7F, 0, 0, 0}, 1
	case display.KEY_TAB:
		return {'\t', 0, 0, 0}, 1
	case display.KEY_ESCAPE:
		return {ESCAPE, 0, 0, 0}, 1
	case display.KEY_UP:
		return {ESCAPE, '[', 'A', 0}, 3
	case display.KEY_DOWN:
		return {ESCAPE, '[', 'B', 0}, 3
	case display.KEY_RIGHT:
		return {ESCAPE, '[', 'C', 0}, 3
	case display.KEY_LEFT:
		return {ESCAPE, '[', 'D', 0}, 3
	case display.KEY_HOME:
		return {ESCAPE, '[', 'H', 0}, 3
	case display.KEY_END:
		return {ESCAPE, '[', 'F', 0}, 3
	case display.KEY_DELETE:
		return {ESCAPE, '[', '3', '~'}, 4
	}
	character := pressed.character
	if pressed.modifiers & display.MODIFIER_CONTROL != 0 {
		switch character {
		case 'a' ..= 'z':
			return {u8(character - 'a' + 1), 0, 0, 0}, 1
		case 'A' ..= 'Z':
			return {u8(character - 'A' + 1), 0, 0, 0}, 1
		}
		return {}, 0
	}
	switch character {
	case 0x20 ..= 0x7E:
		return {u8(character), 0, 0, 0}, 1
	case 0x80 ..= 0x7FF:
		return {u8(0xC0 | character >> 6), u8(0x80 | character & 0x3F), 0, 0}, 2
	case 0x800 ..= 0xD7FF, 0xE000 ..= 0xFFFF:
		return {u8(0xE0 | character >> 12), u8(0x80 | character >> 6 & 0x3F), u8(0x80 | character & 0x3F), 0}, 3
	case 0x10000 ..= 0x10FFFF:
		return {u8(0xF0 | character >> 18), u8(0x80 | character >> 12 & 0x3F), u8(0x80 | character >> 6 & 0x3F), u8(0x80 | character & 0x3F)}, 4
	}
	return {}, 0
}

// input_forward takes the input of the terminal while the queue of the
// waiting bytes has room for a key, and gives the virtio console of the
// guest what its buffers hold. A key that does not fit stays in the
// terminal ring until the guest reads: no character of a paste is lost.
input_forward :: proc "contextless" () {
	pending_feed(&pending, &machine)
	for pending_room(&pending) >= KEY_BYTES_MOST {
		given := terminal.input(&output) or_break
		switch given.kind {
		case .None, .List_First:
		case .Key:
			bytes, count := key_bytes(given.key)
			_ = pending_push(&pending, bytes[:count])
		case .Resized:
			window_resize(given.columns, given.rows)
		}
	}
	pending_feed(&pending, &machine)
}

// window_resize gives the guest the size of the window: the console line
// ends at its width, and the virtio console takes its size, which Linux
// gives the shell on hvc0 as SIGWINCH. The fact says what the machine
// took: the width of the line and the size of the device; the shell's
// answer is the line of the shell that it writes.
window_resize :: proc "contextless" (columns, rows: int) {
	wraps := guest_os.console_line_set_columns(&console, min(columns, guest_os.CONSOLE_LINE_BYTES))
	sized := guest_os.linux_machine_console_resize(&machine, columns, rows)
	system.log_fact(.Info, Window_Resized{columns = u64(columns), rows = u64(rows), taken = wraps && sized ? 1 : 0})
}

// console_drain gives the lines of the guest to their places: the lines of
// hvc0 to the terminal, each line that ended then the line that the shell
// writes now as the edit line, and to the log; the lines of the serial
// port, the log of the kernel, to the log only.
console_drain :: proc "contextless" () {
	buffer: [OUTPUT_BYTES_AT_ONCE]u8
	for {
		count := guest_os.serial_output_take(&machine.serial, buffer[:])
		if count == 0 {
			break
		}
		for value in buffer[:count] {
			if guest_os.console_line_put(&kernel_log, value) == .Ended {
				text, _ := guest_os.console_line_text(&kernel_log)
				system.log_fact(.Info, Guest_Line{text = value_kinds.text_field(string(text), 128)})
				guest_os.console_line_next(&kernel_log)
			}
		}
	}
	changed := false
	for {
		count := guest_os.linux_machine_console_output_take(&machine, buffer[:])
		if count == 0 {
			break
		}
		if !started {
			started = true
			terminal.status(&output, "", 0, 0)
		}
		for value in buffer[:count] {
			switch guest_os.console_line_put(&console, value) {
			case .None:
			case .Changed:
				changed = true
			case .Ended:
				text, _ := guest_os.console_line_text(&console)
				terminal.line(&output, {text = string(text)})
				system.log_fact(.Info, Shell_Line{text = value_kinds.text_field(string(text), 128)})
				guest_os.console_line_next(&console)
				changed = true
			}
		}
	}
	if changed {
		text, cursor := guest_os.console_line_text(&console)
		terminal.edit(&output, string(text), u64(cursor))
	}
}

// ticks_as_milliseconds gives the milliseconds of a count of ticks of the
// timer of the guest, rounded up, so a wait never ends before the tick.
ticks_as_milliseconds :: proc "contextless" (ticks: u64) -> u64 {
	bounded := min(ticks, u64(1) << 40)
	return (bounded * 1000 + guest_os.TIMER_TICKS_PER_SECOND - 1) / guest_os.TIMER_TICKS_PER_SECOND
}

// nanoseconds_as_ticks gives the ticks of the timer of the guest in a time
// of the machine.
nanoseconds_as_ticks :: proc "contextless" (nanoseconds: u64) -> u64 {
	bounded := min(nanoseconds, u64(1) << 40)
	return bounded * guest_os.TIMER_TICKS_PER_SECOND / 1_000_000_000
}

// guest_wait waits for a key, or for the next tick of the timer of the
// guest in the time of the machine, then gives the guest the time that
// passed and the keys.
guest_wait :: proc "contextless" (registers: ^op.Guest_Registers) {
	ticks, bounded := guest_os.linux_machine_wait_ticks(&machine)
	start := system.nanoseconds()
	deadline := u64(system.WAIT_FOREVER)
	if bounded {
		deadline = system.time() + max(ticks_as_milliseconds(ticks), 1)
	}
	wait := system.wait_begin()
	system.wait_records(&wait, &output.ring.completions)
	system.wait_end(&wait, deadline)
	input_forward()
	guest_os.linux_machine_resume(&machine, registers, nanoseconds_as_ticks(system.nanoseconds() - start))
}

// object_read reads an object of the private store into bytes, whole: false
// when the store gives no such object, or one larger than bytes.
object_read :: proc "contextless" (client: ^storage.Client, name: string, bytes: []u8) -> (count: u64, ok: bool) {
	name_field := value_kinds.text_field(name, 16)
	size, status := storage.size(client, storage.ROOT, name)
	if status != .Ok || size <= 0 {
		system.log_fact(.Info, Object_Missing{status = u64(status), name = name_field})
		return 0, false
	}
	if u64(size) > u64(len(bytes)) {
		system.log_fact(.Info, Object_Too_Large{bytes = u64(size), most = u64(len(bytes)), name = name_field})
		return 0, false
	}
	for count < u64(size) {
		read, read_status := storage.read_range(client, storage.ROOT, name, count, bytes[count:size])
		if read_status != .Ok || len(read) == 0 {
			system.log_fact(.Info, Object_Missing{status = u64(read_status), name = name_field})
			return 0, false
		}
		count += u64(len(read))
	}
	return count, true
}

// refuse writes the cause of a refusal on the terminal and stops.
refuse :: proc "contextless" (text: string) -> ! {
	terminal.line(&output, {text = text, style = {tone = u8(terminal.Tone.Bad)}})
	system.stop(.Refused)
}

// fail ends the guest after a failure and stops. The lines that the
// guest wrote before come first, and the line of the kernel that it wrote
// last, which the window does not show, goes to the log.
fail :: proc "contextless" (text: string) -> ! {
	console_drain()
	if line, _ := guest_os.console_line_text(&kernel_log); len(line) > 0 {
		system.log_fact(.Info, Guest_Line{text = value_kinds.text_field(string(line), 128)})
	}
	terminal.line(&output, {text = text, style = {tone = u8(terminal.Tone.Bad)}})
	system.stop(.Failed)
}

// step_failed logs a kernel operation that failed, and stops.
step_failed :: proc "contextless" (status: call_outcome.Call_Outcome, step: string) -> ! {
	system.log_fact(.Error, Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field(step, 40)})
	buffer: [160]u8
	fail(system.format(buffer[:], "The guest cannot run: the kernel refused ", step, "."))
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	opened: bool
	if output, opened = terminal.open(ctx); !opened {
		system.log_fact(.Info, No_Terminal{})
		system.stop(.Refused)
	}
	client, store_opened := storage.open(ctx)
	if !store_opened {
		system.log_fact(.Info, No_Store{})
		refuse("The guest did not start: this window has no private store, which holds the kernel and the initial archive of the guest.")
	}
	// Wait for root to read the startup peak before allocating guest memory
	// that grows into the granted headroom beyond the minimum floor.
	system.ready_at_end()
	// The pages that the granted budget holds before this process makes the
	// guest: the reserve pays the terminal, the store client and the guest
	// process, and the rest is the memory of the guest.
	own, _ := system.budget_read()

	guest_memory_pages = guest_memory_pages_of(own.pages)
	if guest_memory_pages == 0 {
		system.log_fact(.Info, Guest_Memory_Too_Small{pages = own.pages, least = GUEST_MEMORY_PAGES_LEAST + GUEST_MEMORY_PAGES_LEAST / 512 + 64 + PROCESS_RESERVE_PAGES})
		refuse("The guest did not start: the budget of this window holds less memory than a Linux guest needs. Give the process linux a larger budget in the plan.")
	}
	guest_memory_bytes = guest_memory_pages * system.PAGE_SIZE
	status: call_outcome.Call_Outcome
	if guest_ram, status = guest_regions.owned_memory_make(guest_memory_bytes); status != .Succeeded {
		step_failed(status, "Memory_Create of the guest memory")
	}
	ram := guest_ram.bytes[:guest_memory_bytes]

	// The kernel goes to the top of the memory, below its page-aligned
	// size, and loads below it; the archive goes below the copy.
	kernel_size, size_status := storage.size(&client, storage.ROOT, KERNEL_OBJECT)
	if size_status != .Ok || kernel_size <= 0 {
		system.log_fact(.Info, Object_Missing{status = u64(size_status), name = value_kinds.text_field(KERNEL_OBJECT, 16)})
		refuse("The guest did not start: the store linux holds no object kernel. Put a kernel of Linux there under that name.")
	}
	staging_bytes, staging_fits := guest_regions.kernel_staging_bytes(u64(kernel_size), guest_memory_bytes)
	if !staging_fits {
		system.log_fact(.Info, Object_Too_Large{bytes = u64(kernel_size), most = guest_memory_bytes - system.PAGE_SIZE, name = value_kinds.text_field(KERNEL_OBJECT, 16)})
		refuse("The guest did not start: the kernel of the store linux is larger than the memory of the guest.")
	}
	staging := guest_memory_bytes - staging_bytes
	kernel_count, kernel_read := object_read(&client, KERNEL_OBJECT, ram[staging:])
	if !kernel_read {
		refuse("The guest did not start: the store linux did not give the object kernel whole.")
	}
	kernel := ram[staging:][:kernel_count]
	parsed, parse_refusal := guest_os.linux_image_parse(kernel, guest_memory_bytes)
	if parse_refusal == .None && parsed.load_end > staging {
		parse_refusal = .Memory_Too_Small
	}
	if parse_refusal != .None {
		system.log_fact(.Info, Kernel_Refused{refusal = u64(parse_refusal)})
		refuse("The guest did not start: the object kernel of the store linux is not a kernel that the boot protocol of Linux loads.")
	}
	archive_size, archive_status := storage.size(&client, storage.ROOT, INITIAL_ARCHIVE_OBJECT)
	if archive_status != .Ok || archive_size <= 0 {
		system.log_fact(.Info, Object_Missing{status = u64(archive_status), name = value_kinds.text_field(INITIAL_ARCHIVE_OBJECT, 16)})
		refuse("The guest did not start: the store linux holds no object initial_archive. Put a cpio archive of the form newc there under that name.")
	}
	archive_place, place_refusal := guest_os.linux_initial_archive_place(parsed, u64(archive_size), staging)
	if place_refusal != .None {
		system.log_fact(.Info, Object_Too_Large{bytes = u64(archive_size), most = staging - parsed.load_end, name = value_kinds.text_field(INITIAL_ARCHIVE_OBJECT, 16)})
		refuse("The guest did not start: the initial archive of the store linux does not fit the memory of the guest beside the kernel.")
	}
	archive_count, archive_read := object_read(&client, INITIAL_ARCHIVE_OBJECT, ram[archive_place:staging])
	if !archive_read {
		refuse("The guest did not start: the store linux did not give the object initial_archive whole.")
	}
	archive := ram[archive_place:][:archive_count]

	guest_memory := guest_os.Guest_Memory{ram}
	guest_os.linux_machine_start(&machine, guest_memory, nil, nil)
	machine.waits_for_input = true
	places := guest_os.linux_machine_places()
	registers, boot_refusal := guest_os.linux_boot_prepare(guest_memory, kernel, parsed, places[:], nil, archive, staging)
	if boot_refusal != .None {
		system.log_fact(.Info, Kernel_Refused{refusal = u64(boot_refusal)})
		refuse("The guest did not start: the object kernel of the store linux is not a kernel that the boot protocol of Linux loads.")
	}
	// The copy of the image leaves the memory of the guest.
	for &value in ram[staging:] {
		value = 0
	}
	system.log_fact(.Info, Guest_Boots{kernel_bytes = kernel_count, archive_bytes = archive_count, memory_pages = guest_memory_pages})

	name := GUEST_PROCESS_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	if create_status != .Succeeded {
		step_failed(create_status, "Process_Create of the guest")
	}
	guest = system.Handle(created[0])
	if map_status, step := guest_regions.map_memory(guest, guest_ram.handle, guest_memory_bytes); map_status != .Succeeded {
		step_failed(map_status, step)
	}

	// The status line says what a principal waits for, until the guest
	// waits for its first key.
	terminal.status(&output, "Linux starts", 0, 1)
	for {
		input_forward()
		run_error: errors.Error_Record
		exit, run_status := system.guest_run(guest, &registers, &run_error)
		if run_status == .Operation_Unsupported && run_error.kind == i64(errors.Kind.Unsupported) {
			system.log_fact(.Info, Guests_Unsupported{})
			refuse("The guest did not start: the processors of this machine have no virtualization support that modus uses.")
		}
		if run_status != .Succeeded {
			step_failed(run_status, "Guest_Run")
		}
		if exit.kind != .Interrupted {
			exits += 1
		}
		runs += 1
		if runs & (runs - 1) == 0 {
			system.log_fact(.Debug, Guest_Progress{runs = runs, exits = exits, exit_kind = u64(exit.kind), exit_code = value_kinds.Hexadecimal_Sixteen_Digits(exit.code), address = value_kinds.Hexadecimal_Sixteen_Digits(registers.rip)})
		}
		machine_exit := guest_os.Machine_Exit{kind = exit.kind, a = exit.a, b = exit.b, c = exit.c, next = exit.next, code = exit.code, information = exit.information}
		step := guest_os.linux_machine_handle_exit(&machine, &registers, machine_exit)
		console_drain()
		switch step {
		case .Continue:
		case .Not_Handled:
			if !unclaimed_port_answer(&registers, exit) {
				guest_failed(registers, exit.code)
			}
		case .Waiting:
			guest_wait(&registers)
		case .Halted:
			system.log_fact(.Info, Guest_Halted{exits = exits, own_page_writes = machine.own_page_writes})
			if started {
				terminal.line(&output, {text = "Linux halted. The guest ended.", style = {tone = u8(terminal.Tone.Good)}})
			} else {
				// The shell never wrote on hvc0: the log of the kernel, on
				// the serial port, says why.
				terminal.line(&output, {text = "Linux halted before its shell started. The log of the system holds the messages of the kernel.", style = {tone = u8(terminal.Tone.Bad)}})
			}
			_ = system.process_stop(guest)
			system.stop(.Done)
		case .Failed:
			if machine.failure == .Writes_Own_Page {
				system.log_fact(.Error, Guest_Writes_Own_Page{address = value_kinds.Hexadecimal_Sixteen_Digits(registers.rip), page = value_kinds.Hexadecimal_Sixteen_Digits(exit.a)})
			}
			guest_failed(registers, exit.code)
		}
	}
}

// unclaimed_port_answer answers a port that no device of the machine has:
// a read gives all ones, a write does nothing. false for an exit that is
// not a port.
unclaimed_port_answer :: proc "contextless" (registers: ^op.Guest_Registers, exit: system.Guest_Exit) -> bool {
	if exit.kind != .Port_Read && exit.kind != .Port_Write {
		return false
	}
	if exit.kind == .Port_Read {
		size := exit.b
		mask := size >= 4 ? u64(0xFFFF_FFFF) : u64(1) << (size * 8) - 1
		registers.rax = size >= 4 ? mask : registers.rax | mask
	}
	registers.rip = exit.next
	return true
}

// guest_failed logs the failure of the machine and stops.
guest_failed :: proc "contextless" (registers: op.Guest_Registers, exit_code: u64) -> ! {
	system.log_fact(.Error, Guest_Failed{failure = u64(machine.failure), address = value_kinds.Hexadecimal_Sixteen_Digits(registers.rip), exits = exits, exit_code = value_kinds.Hexadecimal_Sixteen_Digits(exit_code)})
	_ = system.process_stop(guest)
	fail("The guest stopped: it did something that the machine of modus does not answer. The log names the address.")
}
