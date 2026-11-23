// The process `linux`: a shell of Linux in a terminal window
// (src/md/features/linux_shell.md).
//
// It reads a Linux kernel and an initial archive from its private store,
// boots the kernel in a guest with the machine of modus:contract/guest_os,
// and joins the serial port of the guest to its terminal: the lines of the
// guest are the lines of the terminal, and the keys of the terminal are the
// bytes that the guest reads. An idle guest waits for a key, or for the
// next tick of its timer in the time of the machine.
//
// **Start**: from the start menu, or `start("linux")` in the console. The
// root service starts its terminal with it.
//
// **Grants**: **Terminal**, the console of the guest; **Store**, the private
// store `linux` with the objects `kernel` and `initial_archive`.
//
// **What a reader sees**: a terminal window with the messages of Linux, then
// a shell. On the log: "linux: boots the kernel of ...", one line
// "linux: guest: <line>" for each line of the guest, and at the end
// "linux: the guest halted after N exits: the process ends" when the guest
// runs `poweroff`.
package linux_shell

import "modus:contract/errors"
import "modus:contract/guest_os"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:guest_regions"
import "modus:storage"
import "modus:system"
import terminal "modus:terminal"

// The memory of the guest: a kernel of a distribution unpacks into about
// 56 MiB, and the initial archive and the copy of the image wait above it.
GUEST_MEMORY_PAGES :: u64(32_768) // 128 MiB.
GUEST_MEMORY_BYTES :: GUEST_MEMORY_PAGES * system.PAGE_SIZE
// The memory of the guest, the nested page table of the guest and the
// buffers of this process; this process and its guest process, and one
// thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 34_816, processes = 2, threads = 1}
#assert(34_816 >= GUEST_MEMORY_PAGES + 1024)

GUEST_PROCESS_NAME :: "linux guest"
KERNEL_OBJECT :: "kernel"
INITIAL_ARCHIVE_OBJECT :: "initial_archive"

// The bytes that one look at the serial port takes.
OUTPUT_BYTES_AT_ONCE :: 512

machine: guest_os.Linux_Machine
console: guest_os.Console_Line
output: terminal.Terminal
guest_ram: guest_regions.Owned_Memory
guest: system.Handle
exits: u64
runs: u64 // Each Guest_Run: the exits of the guest and the exits Interrupted.

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

// keys_forward gives each key that waits to the serial port of the guest.
keys_forward :: proc "contextless" () {
	for {
		pressed, has_key := terminal.key(&output)
		if !has_key {
			return
		}
		bytes, count := key_bytes(pressed)
		_ = guest_os.linux_machine_serial_input(&machine, bytes[:count])
	}
}

// console_drain gives the bytes that the guest wrote to the terminal: each
// line that ended, then the line that the guest writes now as the edit line.
console_drain :: proc "contextless" () {
	buffer: [OUTPUT_BYTES_AT_ONCE]u8
	changed := false
	for {
		count := guest_os.serial_output_take(&machine.serial, buffer[:])
		if count == 0 {
			break
		}
		for value in buffer[:count] {
			switch guest_os.console_line_put(&console, value) {
			case .None:
			case .Changed:
				changed = true
			case .Ended:
				text, _ := guest_os.console_line_text(&console)
				terminal.line(&output, {text = string(text)})
				system.log_fact(.Info, Guest_Line{text = value_kinds.text_field(string(text), 128)})
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
	keys_forward()
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

// fail ends the guest after a failure and stops.
fail :: proc "contextless" (text: string) -> ! {
	console_drain()
	terminal.line(&output, {text = text, style = {tone = u8(terminal.Tone.Bad)}})
	system.stop(.Failed)
}

// step_failed logs a kernel operation that failed, and stops.
step_failed :: proc "contextless" (status: system.Status, step: string) -> ! {
	system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(status), step = value_kinds.text_field(step, 40)})
	fail("the guest cannot run: a kernel operation failed")
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
		refuse("no store: the guest image is in the private store of linux")
	}

	status: system.Status
	if guest_ram, status = guest_regions.owned_memory_make(GUEST_MEMORY_BYTES); status != .Ok {
		step_failed(status, "Memory_Create of the guest memory")
	}
	ram := guest_ram.bytes[:GUEST_MEMORY_BYTES]

	// The kernel goes to the top of the memory, below its page-aligned
	// size, and loads below it; the archive goes below the copy.
	kernel_size, size_status := storage.size(&client, storage.ROOT, KERNEL_OBJECT)
	if size_status != .Ok || kernel_size <= 0 {
		system.log_fact(.Info, Object_Missing{status = u64(size_status), name = value_kinds.text_field(KERNEL_OBJECT, 16)})
		refuse("the store linux holds no kernel")
	}
	staging_bytes, staging_fits := guest_regions.kernel_staging_bytes(u64(kernel_size), GUEST_MEMORY_BYTES)
	if !staging_fits {
		system.log_fact(.Info, Object_Too_Large{bytes = u64(kernel_size), most = GUEST_MEMORY_BYTES - system.PAGE_SIZE, name = value_kinds.text_field(KERNEL_OBJECT, 16)})
		refuse("the kernel of the store linux does not fit the memory of the guest")
	}
	staging := GUEST_MEMORY_BYTES - staging_bytes
	kernel_count, kernel_read := object_read(&client, KERNEL_OBJECT, ram[staging:])
	if !kernel_read {
		refuse("the kernel of the store linux cannot be read")
	}
	kernel := ram[staging:][:kernel_count]
	parsed, parse_refusal := guest_os.linux_image_parse(kernel, GUEST_MEMORY_BYTES)
	if parse_refusal == .None && parsed.load_end > staging {
		parse_refusal = .Memory_Too_Small
	}
	if parse_refusal != .None {
		system.log_fact(.Info, Kernel_Refused{refusal = u64(parse_refusal)})
		refuse("the kernel of the store linux is refused by the Linux boot protocol")
	}
	archive_size, archive_status := storage.size(&client, storage.ROOT, INITIAL_ARCHIVE_OBJECT)
	if archive_status != .Ok || archive_size <= 0 {
		system.log_fact(.Info, Object_Missing{status = u64(archive_status), name = value_kinds.text_field(INITIAL_ARCHIVE_OBJECT, 16)})
		refuse("the store linux holds no initial archive")
	}
	archive_place, place_refusal := guest_os.linux_initial_archive_place(parsed, u64(archive_size), staging)
	if place_refusal != .None {
		system.log_fact(.Info, Object_Too_Large{bytes = u64(archive_size), most = staging - parsed.load_end, name = value_kinds.text_field(INITIAL_ARCHIVE_OBJECT, 16)})
		refuse("the initial archive of the store linux does not fit the memory of the guest")
	}
	archive_count, archive_read := object_read(&client, INITIAL_ARCHIVE_OBJECT, ram[archive_place:staging])
	if !archive_read {
		refuse("the initial archive of the store linux cannot be read")
	}
	archive := ram[archive_place:][:archive_count]

	guest_memory := guest_os.Guest_Memory{ram}
	guest_os.linux_machine_start(&machine, guest_memory, nil, nil)
	machine.waits_for_input = true
	places := guest_os.linux_machine_places()
	registers, boot_refusal := guest_os.linux_boot_prepare(guest_memory, kernel, parsed, places[:], nil, archive, staging)
	if boot_refusal != .None {
		system.log_fact(.Info, Kernel_Refused{refusal = u64(boot_refusal)})
		refuse("the kernel of the store linux is refused by the Linux boot protocol")
	}
	// The copy of the image leaves the memory of the guest.
	for &value in ram[staging:] {
		value = 0
	}
	system.log_fact(.Info, Guest_Boots{kernel_bytes = kernel_count, archive_bytes = archive_count, memory_pages = GUEST_MEMORY_PAGES})

	name := GUEST_PROCESS_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	if create_status != .Ok {
		step_failed(create_status, "Process_Create of the guest")
	}
	guest = system.Handle(created[0])
	if map_status, step := guest_regions.map_memory(guest, guest_ram.handle, GUEST_MEMORY_BYTES); map_status != .Ok {
		step_failed(map_status, step)
	}

	for {
		keys_forward()
		run_error: errors.Error_Record
		exit, run_status := system.guest_run(guest, &registers, &run_error)
		if run_status == .Bad_Operation && run_error.kind == i64(errors.Kind.Unsupported) {
			system.log_fact(.Info, Guests_Unsupported{})
			refuse("no guest runs on this machine: its processors have no virtualization support that the kernel uses")
		}
		if run_status != .Ok {
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
			terminal.line(&output, {text = "the guest halted", style = {tone = u8(terminal.Tone.Good)}})
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
	fail("the guest stopped: the machine does not answer what it did")
}
