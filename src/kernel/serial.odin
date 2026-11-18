package kernel

import "base:intrinsics"
import "kernel:delivery_count"
import "kernel:time_base"
import "modus:contract/cut_mark"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// The log of the kernel: its records, the own log ring of each process, the
// serial writer that writes their lines on the serial port, and the stop of
// the machine. The serial port is the only device that the kernel has code
// for, apart from the processor and its interrupt controller.

SERIAL_PORT :: 0x3F8
DEBUG_EXIT_PORT :: 0xF4 // The isa-debug-exit device of QEMU: a write ends the machine.

foreign _ {
	// cli, then hlt in a loop. It stays in processor.asm: the compiler
	// takes hlt as the end of the flow of a template, and a hlt continues
	// after an NMI.
	processor_stop :: proc "c" () -> ! ---
}

serial_start :: proc "contextless" () {
	port_write_8(SERIAL_PORT + 1, 0x00) // no interrupts
	port_write_8(SERIAL_PORT + 3, 0x80) // set the divisor
	port_write_8(SERIAL_PORT + 0, 0x01) // 115200 baud
	port_write_8(SERIAL_PORT + 1, 0x00)
	port_write_8(SERIAL_PORT + 3, 0x03) // 8 bits, no parity, one stop bit
	port_write_8(SERIAL_PORT + 2, 0xC7) // queues on
}

// How long a writer waits for the transmit register. A byte takes 87 us at
// 115200 baud, and a full queue of the device SERIAL_QUEUE_BYTES of them: a
// device that takes no byte in a hundred times that does not drain.
SERIAL_TRANSMIT_BOUND_MICROSECONDS :: 10_000
// The serial port took no byte in its bound: each writer drops its bytes
// with no wait until a read of the line status finds the register empty.
// Without it each byte of a silent port would wait the whole bound, and a
// start that drains each line at once would take minutes.
serial_port_silent: bool
// The bytes that the serial port did not take. Only the copy of the serial
// port is lost: the log keeps each record. A writer can hold any lock, so
// the tick writes the count (delivery_faults_log).
serial_bytes_dropped: u64

// serial_transmit_ready says if the transmit register takes a byte now. It
// waits at most SERIAL_TRANSMIT_BOUND_MICROSECONDS, and not at all while
// the port is silent. Before the calibration the frequency is 0, and the
// bound takes the highest frequency that the kernel accepts: it is then
// longer, never shorter.
serial_transmit_ready :: proc "contextless" () -> bool {
	if port_read_8(SERIAL_LINE_STATUS) & SERIAL_TRANSMIT_EMPTY != 0 {
		if intrinsics.atomic_load(&serial_port_silent) {
			intrinsics.atomic_store(&serial_port_silent, false)
		}
		return true
	}
	if intrinsics.atomic_load(&serial_port_silent) {
		return false
	}
	end := time_base.deadline(cycles_now(), SERIAL_TRANSMIT_BOUND_MICROSECONDS, cycle_frequency)
	for port_read_8(SERIAL_LINE_STATUS) & SERIAL_TRANSMIT_EMPTY == 0 {
		if cycles_now() >= end {
			intrinsics.atomic_store(&serial_port_silent, true)
			return false
		}
		intrinsics.cpu_relax()
	}
	return true
}

log_bytes :: proc "contextless" (bytes: []u8) {
	for b in bytes {
		if !serial_transmit_ready() {
			intrinsics.atomic_add(&serial_bytes_dropped, 1)
			continue
		}
		port_write_8(SERIAL_PORT, b)
	}
}

// The log (operation.Log_Record). Each record goes to two places: the
// serial port, as one line of text, and the memory object of the log,
// that processes with the grant read. The record also keeps the kind of each
// typed part of its text (modus:contract/value_kinds); the serial port has the
// text only.
Hex :: distinct u64
Size :: value_kinds.Size
Duration :: value_kinds.Duration
Hash :: value_kinds.Hash
Module_Name :: value_kinds.Module_Name

// A part of a line of the log. A string is plain text; each other part is a
// value with a kind: an integer and a Hex are numbers, a Size a size, a
// Duration a time, a Hash a version, a Module_Name a module.
Log_Part :: union {
	string,
	u64,
	Hex,
	Size,
	Duration,
	Hash,
	Module_Name,
}

// The value runs of one line that the kernel writes for itself. The stack of
// the kernel is small: a line with more typed parts keeps its first runs,
// and the rest of its text is plain.
KERNEL_LOG_RUN_LIMIT :: 12

log_head: ^op.Log_Head // nil before log_start.
log_records: [^]op.Log_Record
// The memory object of the log, which the root service receives. A handle
// of it with Read is the authority of Log_Read: its holder reads each
// record already. 0: no log.
log_region: u32
// A record keeps the slot of its process and of its thread in one byte
// each, so that it has room for the process serial and the own number in
// its 256 bytes.
#assert(PROCESS_CAPACITY <= 1 << 8)
#assert(THREAD_TABLE_CAPACITY <= 1 << 8)
log_serial_only: bool // The kernel reports its own fault: it takes no lock, and writes the serial port only.
// The log lock protects the records of the log and their counter, and the
// own log ring of each process with its count and its frames
// (docs/ARCHITECTURE.md, "Locks of the kernel"). It does not protect the
// serial port: a Log that waited for the serial port under it would learn
// how much the other processes wrote (src/md/features/log_side_channels.md).
log_lock: Lock

// The serial port has one writer at a time: the drain at the tick of any
// processor or in a long wait for a lock, the flush before the machine
// stops, or the report of a fault of the kernel. 0: no writer; else the
// identifier of the local interrupt controller of the writer, plus one. It
// is not a lock of the lock order: the tick does not wait for it, the flush
// and the report wait a bounded time, and its holder takes no lock.
serial_writer: u32
// Only the serial writer reads and writes the globals below, so a line that
// one processor begins another one ends, in the order of the records.
serial_next: u64 // The number of the next record of the whole log for the serial port.
serial_line_open: bool // The last line in serial_line continues in the next record.
serial_copy: op.Log_Record // The copy of a record that the drain checks before it writes it.
// The bytes of the line of one record, or of the line of a count of lost
// records, that wait for the device: serial_line[serial_line_written:serial_line_count].
serial_line: [op.LOG_SERIAL_LINE_BYTES_MOST]u8
serial_line_count: int
serial_line_written: int
// For the one line of the measure of the drain: the bytes that the drains
// of the ticks and of the idle loop wrote, and the cycles of their port
// writes alone, so the rate is the rate of the port.
serial_measured_bytes: u64
serial_measured_cycles: u64
serial_measured_tick_bytes: u64
serial_measured_idle_bytes: u64
serial_measure_state: Serial_Measure_State
// Where the measure of the serial port is. Atomic: each writer of a byte
// notes it, and the tick of the first processor writes it once.
Serial_Measure_State :: enum u32 {
	Measuring, // The measure is not ready: the drain counts each byte.
	Ready, // The bytes are counted: the next tick writes the line.
	Written, // The line is on the log.
}
// A tick drains the log from the first tick on. Before it, each writer of a
// record drains at once: the timer does not run yet, and a hang of the
// start must still show its lines.
serial_tick_drains: bool

// The time that one drain of a tick or of a wait for a lock writes at most,
// by the cycle counter, whatever bytes it wrote: interrupts are off for no
// longer than that, a tenth of a tick, so a device interrupt and the thread
// that the tick interrupts wait at most that. A bound in bytes bounds no
// time: a port write that exits to QEMU costs 2 to 10 us. The line of the
// measure says what the device of the machine keeps; a flood of more lines
// loses some, and the serial port says how many (serial_lost_line).
SERIAL_MICROSECONDS_OF_A_TICK :: 100
// The queue of the device: the bytes that the drain writes when the line
// status says that the transmit register is empty.
SERIAL_QUEUE_BYTES :: 16
// The line status register and its bit "the transmit register is empty".
SERIAL_LINE_STATUS :: SERIAL_PORT + 5
SERIAL_TRANSMIT_EMPTY :: 0x20
// The bytes after which the drain writes its measured rate once.
SERIAL_MEASURE_BYTES :: 64 * 1024

// The processor that reports a fault of the kernel: its identifier plus one,
// or 0 when no processor reports.
log_fault_reporter: u32

// FAULT_REPORT_WAIT_MILLISECONDS: how long the reporter waits for a line
// that another processor writes. The longest line is a Log operation of
// 4096 bytes, about 360 ms at 115200 baud.
FAULT_REPORT_WAIT_MILLISECONDS :: 1000

// The count of the reports that began: 1 is a report; 2 or more is a fault
// inside the report of a fault.
log_fault_report_depth: u32

// fault_report_begin makes this processor the only writer of the serial
// port, before the kernel reports its own fault. The report takes no lock,
// because the processor can hold any lock, and it reads nothing through
// the gs register: a fault of the kernel can arrive with the gs of a
// process, and a read through it would be a second fault, with no end.
// Without this procedure, the report and a line that another processor
// writes arrive as mixed bytes, and nobody can read the fault.
//   - A second processor that has a fault of its own stops: one report.
//   - A processor that starts a record after this stops in log_take.
//   - The drain of the log ends its record: the reporter waits for the
//     serial writer, a bounded time, and keeps it. It then writes the
//     records that the log holds and the serial port does not have yet:
//     the lines before a fault are often its cause. When the reporter is
//     the serial writer itself, when the wait ends by its bound, or when
//     the last record continues in one that no processor wrote, the
//     report starts on a new line and says so.
//   - A fault inside the report: one fixed line, and the machine stops.
fault_report_begin :: proc "contextless" () {
	if !lock_ready {
		// One processor, with no record yet: nobody else writes.
		intrinsics.atomic_store(&log_serial_only, true)
		return
	}
	identifier := apic_id()
	self := identifier + 1
	if _, first := intrinsics.atomic_compare_exchange_strong(&log_fault_reporter, 0, self); !first {
		if intrinsics.atomic_load(&log_fault_reporter) != self {
			processor_stop()
		}
	}
	intrinsics.atomic_store(&log_serial_only, true)
	if intrinsics.atomic_add(&log_fault_report_depth, 1) != 0 {
		log_bytes(transmute([]u8)string("\r\nkernel: a fault inside the report of a fault of the kernel\r\n"))
		machine_stop(.Fault)
	}
	line_is_whole := false
	if intrinsics.atomic_load(&serial_writer) != self && serial_writer_take(self, FAULT_REPORT_WAIT_MILLISECONDS) {
		// The reporter keeps the serial writer: no drain writes after this.
		serial_drain_all()
		line_is_whole = !serial_line_open
	}
	if !line_is_whole {
		log_bytes(transmute([]u8)string("\r\nkernel: the line above is cut: the report of a fault of the kernel starts here\r\n"))
	}
}

// log_take takes the log lock, except before the first processor has its
// record, and when the kernel reports its own fault: then only the reporter
// writes, and each other processor stops here.
log_take :: proc "contextless" () -> bool {
	if intrinsics.atomic_load(&log_serial_only) {
		if lock_ready && intrinsics.atomic_load(&log_fault_reporter) != apic_id() + 1 {
			processor_stop()
		}
		return false
	}
	lock_take(&log_lock, .Log)
	if intrinsics.atomic_load(&log_serial_only) {
		// A report began between the look above and the take. The reporter
		// writes now, or waits for this lock: free it, so that it does not
		// wait for a processor that stops.
		lock_free(&log_lock, .Log)
		processor_stop()
	}
	return true
}

log_free :: proc "contextless" (taken: bool) {
	if taken {
		lock_free(&log_lock, .Log)
	}
}

@(private = "file")
HEX_DIGITS :: [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

@(rodata)
KERNEL_NAME := [6]u8{'k', 'e', 'r', 'n', 'e', 'l'}

// log_start makes the memory object of the log.
log_start :: proc "contextless" () {
	physical := frames_allocate(op.LOG_PAGES)
	if physical == 0 {
		return
	}
	intrinsics.mem_zero(direct(physical, u8), op.LOG_PAGES * PAGE_SIZE)
	head := direct(physical, op.Log_Head)
	head.capacity = op.LOG_RECORD_CAPACITY
	log_records = ([^]op.Log_Record)(direct(physical + size_of(op.Log_Head), op.Log_Record))
	log_head = head
}

// log writes one record of the kernel with no channel.
log :: proc "contextless" (parts: ..Log_Part) {
	log_in("", .Info, ..parts)
}

// log_in writes one record of the kernel. A part is a string, or a value
// with a kind (Log_Part): the record keeps where each value is in the text.
//
// The text of one record of the kernel has at most 352 bytes: the stack of
// the kernel is small. A longer text ends with the cut mark and the count
// of the missing bytes (modus:contract/cut_mark): never cut in silence.
log_in :: proc "contextless" (channel: string, level: op.Log_Level, parts: ..Log_Part) {
	buffer: [352]u8
	count := 0
	dropped := 0
	runs: [KERNEL_LOG_RUN_LIMIT]value_kinds.Value_Run_In_Call
	run_count := 0
	put :: proc "contextless" (buffer: []u8, count: ^int, dropped: ^int, bytes: []u8) {
		taken := copy(buffer[count^:], bytes)
		count^ += taken
		dropped^ += len(bytes) - taken
	}
	put_decimal :: proc "contextless" (buffer: []u8, count: ^int, dropped: ^int, value: u64) {
		digits: [20]u8
		digit_count := 0
		rest := value
		for {
			digits[len(digits) - 1 - digit_count] = u8('0' + rest % 10)
			digit_count += 1
			rest /= 10
			if rest == 0 {break}
		}
		put(buffer, count, dropped, digits[len(digits) - digit_count:])
	}
	for part in parts {
		start := count
		kind := value_kinds.Value_Kind.None
		switch value in part {
		case string:
			put(buffer[:], &count, &dropped, transmute([]u8)value)
		case u64:
			put_decimal(buffer[:], &count, &dropped, value)
			kind = .Number
		case Hex:
			digits: [16]u8
			alphabet := HEX_DIGITS
			for i in 0 ..< 16 {
				digits[i] = alphabet[(u64(value) >> uint(60 - 4 * i)) & 0xF]
			}
			put(buffer[:], &count, &dropped, digits[:])
			kind = .Number
		case Size:
			put_decimal(buffer[:], &count, &dropped, value.value)
			put(buffer[:], &count, &dropped, transmute([]u8)value_kinds.size_unit_text(value.unit))
			kind = .Size
		case Duration:
			put_decimal(buffer[:], &count, &dropped, value.value)
			put(buffer[:], &count, &dropped, transmute([]u8)value_kinds.duration_unit_text(value.unit))
			kind = .Time
		case Hash:
			alphabet := HEX_DIGITS
			for byte_value in value.bytes {
				put(buffer[:], &count, &dropped, {alphabet[byte_value >> 4], alphabet[byte_value & 0xF]})
			}
			kind = .Version
		case Module_Name:
			put(buffer[:], &count, &dropped, transmute([]u8)value.name)
			kind = .Module
		}
		value_kinds.value_run_add(runs[:], &run_count, start, count, kind)
	}
	mark_start: int
	count, mark_start, _ = cut_mark.apply(buffer[:], count, dropped)
	if dropped > 0 {
		run_count = value_kinds.value_runs_cut(runs[:], run_count, mark_start)
	}
	taken := log_take()
	if taken && log_head != nil {
		name := KERNEL_NAME
		if kernel_log_fits(log_records_of_text(buffer[:count])) {
			log_record(0, 0, nil, 0, name[:], transmute([]u8)channel, level, buffer[:count], runs[:run_count])
		}
		log_free(taken)
		serial_drain_before_the_tick()
		return
	}
	// No memory of the log yet, or the report of a fault: the serial port
	// only, at once.
	log_bytes(buffer[:count])
	log_bytes({'\r', '\n'})
	log_free(taken)
}

// The records that the kernel wrote for itself in this second: the second
// in the high 32 bits, the count in the low 32 bits, as Budget.logged. And
// the lines of the kernel that were over its bound since the last note.
// The log lock protects both.
kernel_logged: u64
kernel_log_lines_over: u64

// kernel_log_fits says if a line of the kernel of `records` records fits
// op.LOG_RECORDS_OF_THE_KERNEL in this second, and counts it. Before the
// first tick, each writer drains its record at once and no bound is needed.
// A line past the bound is counted; the next line that fits is preceded by
// one record with that count, inside the bound. So a process that faults
// in a loop cannot make the kernel flood the log
// (src/md/features/log_side_channels.md). The caller holds the log lock.
@(private = "file")
kernel_log_fits :: proc "contextless" (records: u64) -> bool {
	if !intrinsics.atomic_load(&serial_tick_drains) {
		return true
	}
	second := intrinsics.atomic_load(&time_milliseconds) / LOG_PERIOD
	count := kernel_logged >> 32 == second ? kernel_logged & 0xFFFF_FFFF : 0
	note: u64 = kernel_log_lines_over > 0 ? 1 : 0
	if count + note + records > op.LOG_RECORDS_OF_THE_KERNEL {
		kernel_log_lines_over += 1
		return false
	}
	if note != 0 {
		text: [96]u8
		digits: [20]u8
		text_count := copy(text[:], "kernel: ")
		text_count += copy(text[text_count:], decimal_digits(&digits, kernel_log_lines_over))
		text_count += copy(text[text_count:], " lines of the kernel were over its limit of 64 records in each second")
		name := KERNEL_NAME
		log_record(0, 0, nil, 0, name[:], nil, .Warning, text[:text_count], nil)
		kernel_log_lines_over = 0
	}
	kernel_logged = second << 32 | (count + note + records)
	return true
}

// decimal_digits writes a number in decimal at the end of `digits`, and
// gives the digits that it wrote.
@(private = "file")
decimal_digits :: proc "contextless" (digits: ^[20]u8, value: u64) -> []u8 {
	digit_count := 0
	rest := value
	for {
		digits^[len(digits^) - 1 - digit_count] = u8('0' + rest % 10)
		digit_count += 1
		rest /= 10
		if rest == 0 {break}
	}
	return digits^[len(digits^) - digit_count:]
}

#assert(op.LOG_RECORDS_OF_THE_KERNEL == 64) // The text of the note says it.

// serial_writer_take makes this processor the serial writer. self is the
// identifier of its local interrupt controller plus one. It waits at most
// wait_milliseconds for another writer; 0: it does not wait. Before the
// first processor has its record, one processor runs, and it takes nothing.
serial_writer_take :: proc "contextless" (self: u32, wait_milliseconds: u64) -> bool {
	if !lock_ready {
		return true
	}
	// Before the timer is measured the frequency is 0: no wait.
	limit := cycles_now() + cycle_frequency / 1000 * wait_milliseconds
	for {
		if _, taken := intrinsics.atomic_compare_exchange_strong(&serial_writer, 0, self); taken {
			return true
		}
		if cycles_now() >= limit {
			return false
		}
		intrinsics.cpu_relax()
	}
}

serial_writer_free :: proc "contextless" () {
	intrinsics.atomic_store(&serial_writer, 0)
}

// How a drain may use its processor.
Serial_Drain_Mode :: enum u8 {
	// The flush, a report, the start: it waits for the device, those end
	// the machine or run alone. A device that takes no byte in
	// SERIAL_TRANSMIT_BOUND_MICROSECONDS loses the line, which is counted.
	Wait,
	// A tick or a long wait for a lock: SERIAL_MICROSECONDS_OF_A_TICK at
	// most, with interrupts off.
	Tick,
	// The idle loop: no bound in time, a window for interrupts after each
	// byte, and it leaves at once when a queue receives a thread.
	Idle,
}

// serial_drain writes on the serial port the records of the whole log from
// serial_next up to the record before `until`, in their order, and gives
// the bytes that it wrote. The caller is the serial writer. It reads the
// log as a reader of the whole log does, with no log lock, so no Log waits
// for the serial port (serial_line_next). An idle drain writes up to the
// newest record, also the records that come while it writes.
//
// A drain of a processor (.Tick, .Idle) writes only while the device takes
// bytes: SERIAL_QUEUE_BYTES when the transmit register is empty. A tick
// leaves when the register is not empty, or after its bound, so it never
// spins with interrupts off. The idle drain opens interrupt_window after
// each byte and while the register is not empty, with the serial writer
// free (serial_idle_window), and leaves when a queue received a thread, an
// interrupt came, or a report began (serial_idle_drain_ends).
// Between two writes, both answer processor_sync, and leave when the
// machine stops, for the flush.
@(private = "file")
serial_drain :: proc "contextless" (until: u64, cpu: ^Processor, mode: Serial_Drain_Mode, idle: ^Serial_Idle_Drain = nil) -> (bytes: int) {
	if log_head == nil {
		return 0
	}
	// Before the timer is measured the frequency is 0: one burst.
	deadline := cycles_now() + cycle_frequency / 1_000_000 * SERIAL_MICROSECONDS_OF_A_TICK
	for {
		if serial_line_written == serial_line_count {
			last := mode == .Idle ? intrinsics.atomic_load(&log_head.written) : until
			if !serial_line_next(last) {
				return bytes
			}
		}
		switch mode {
		case .Wait:
			if !serial_transmit_ready() {
				// The rest of the line is dropped at once: one read of the
				// line status for each line, not for each byte.
				intrinsics.atomic_add(&serial_bytes_dropped, u64(serial_line_count - serial_line_written))
				serial_line_written = serial_line_count
				continue
			}
		case .Tick:
			if cycles_now() >= deadline || intrinsics.atomic_load(&machine_stopping) {
				return bytes
			}
			sync_acknowledge(cpu)
			if port_read_8(SERIAL_LINE_STATUS) & SERIAL_TRANSMIT_EMPTY == 0 {
				return bytes
			}
		case .Idle:
			for {
				if serial_idle_drain_ends(cpu, idle) {
					return bytes
				}
				sync_acknowledge(cpu)
				if port_read_8(SERIAL_LINE_STATUS) & SERIAL_TRANSMIT_EMPTY != 0 {
					break
				}
				if !serial_idle_window(cpu, idle) {
					return bytes
				}
			}
		}
		// The queue of the device is empty: up to SERIAL_QUEUE_BYTES go with
		// no look at the line status. A tick looks at the time before each
		// byte, so it ends within one port write of its bound; the idle
		// drain opens a window after each byte, so an interrupt waits one
		// port write at most. A byte that is not written waits in
		// serial_line.
		burst := min(SERIAL_QUEUE_BYTES, serial_line_count - serial_line_written)
		for _ in 0 ..< burst {
			if mode == .Tick && cycles_now() >= deadline {
				break
			}
			if mode == .Idle && serial_idle_drain_ends(cpu, idle) {
				return bytes
			}
			started := cycles_now()
			port_write_8(SERIAL_PORT, serial_line[serial_line_written])
			if mode != .Wait {
				serial_measure_note(cycles_now() - started, mode)
			}
			serial_line_written += 1
			bytes += 1
			if serial_line_written == serial_line_count {
				serial_lag_note()
			}
			if mode == .Idle && !serial_idle_window(cpu, idle) {
				return bytes
			}
		}
	}
}

// The state of one idle drain, which belongs to its call.
Serial_Idle_Drain :: struct {
	pushes:            u32, // queue_pushes when the processor found no thread.
	interrupts_before: u64, // cpu.idle_interrupts when the drain began.
	writer_lost:       bool, // Another processor took the serial writer in a window.
}

// serial_idle_drain_ends says if the idle drain must leave: a queue
// received a thread, an interrupt came in a window (as idle_wait returns
// after one interrupt, so the processor looks at the queues again: a wake
// of kick_all pushes no thread), the machine stops, or a report of a fault
// began.
@(private = "file")
serial_idle_drain_ends :: proc "contextless" (cpu: ^Processor, idle: ^Serial_Idle_Drain) -> bool {
	return queue_pushes() != idle.pushes || intrinsics.atomic_load(&cpu.idle_interrupts) != idle.interrupts_before || intrinsics.atomic_load(&machine_stopping) || intrinsics.atomic_load(&log_serial_only)
}

// serial_idle_window frees the serial writer, opens interrupt_window, and
// takes the writer again with no wait. The state of the serial port is
// whole between two bytes, so a handler in the window can drain (its
// tick), report a fault, or stop the machine with the writer free, and a
// handler that hangs holds no writer. false: another processor took the
// writer, and the idle drain leaves without it.
@(private = "file")
serial_idle_window :: proc "contextless" (cpu: ^Processor, idle: ^Serial_Idle_Drain) -> bool {
	serial_writer_free()
	interrupt_window()
	if !serial_writer_take(cpu.apic_id + 1, 0) {
		idle.writer_lost = true
		return false
	}
	return true
}

// The time of the record of the line in serial_line, in microseconds since
// the start of the machine; 0 for the line of a count of lost records. And
// the largest time between the time of a record and the write of the end
// of its line on the port. Only the serial writer reads and writes them.
serial_line_time: u64
serial_largest_lag: u64

// serial_lag_note counts the lag of the line that the drain just ended.
@(private = "file")
serial_lag_note :: proc "contextless" () {
	if serial_line_time == 0 {
		return
	}
	now := microseconds(cycles_now())
	if now > serial_line_time && now - serial_line_time > serial_largest_lag {
		serial_largest_lag = now - serial_line_time
	}
}

// serial_measure_note counts one byte of a drain of a processor and the
// cycles of its port write, until the measure is ready.
@(private = "file")
serial_measure_note :: proc "contextless" (cycles: u64, mode: Serial_Drain_Mode) {
	if intrinsics.atomic_load(&serial_measure_state) != .Measuring {
		return
	}
	intrinsics.atomic_add(&serial_measured_cycles, cycles)
	if mode == .Idle {
		intrinsics.atomic_add(&serial_measured_idle_bytes, 1)
	} else {
		intrinsics.atomic_add(&serial_measured_tick_bytes, 1)
	}
	if intrinsics.atomic_add(&serial_measured_bytes, 1) + 1 >= SERIAL_MEASURE_BYTES {
		intrinsics.atomic_store(&serial_measure_state, Serial_Measure_State.Ready)
	}
}

// serial_line_next puts the line of the next record before `until` in
// serial_line, or the line of the count of the records that the log wrote
// over before the drain reached them. false: no record is left. It copies a
// record, and keeps the copy only if the kernel did not start to write over
// it (op.log_first_kept, op.log_copy_kept): a torn copy shows as a loss on
// the next turn, never as a line.
@(private = "file")
serial_line_next :: proc "contextless" (until: u64) -> bool {
	for serial_next < until {
		next, lost := op.log_first_kept(serial_next, intrinsics.atomic_load(&log_head.written))
		if lost != 0 {
			serial_lost_line(lost)
			serial_next = next
			return true
		}
		serial_copy = log_records[serial_next % op.LOG_RECORD_CAPACITY]
		// The second load of `written` comes after the copy.
		intrinsics.atomic_thread_fence(.Acquire)
		if !op.log_copy_kept(serial_next, intrinsics.atomic_load(&log_head.written)) {
			continue
		}
		serial_record_line(&serial_copy)
		serial_next += 1
		return true
	}
	return false
}

// serial_line_put adds bytes to serial_line.
@(private = "file")
serial_line_put :: proc "contextless" (bytes: []u8) {
	serial_line_count += copy(serial_line[serial_line_count:], bytes)
}

// serial_record_line puts in serial_line the part of a line that one record
// holds. The text of a record is UTF-8 with no control character, a name
// and a channel are checked when the kernel takes them: a record cannot
// forge or hide a line of the serial port.
@(private = "file")
serial_record_line :: proc "contextless" (record: ^op.Log_Record) {
	head: [op.LOG_LINE_HEAD_CAPACITY]u8
	head_count := op.log_line_head(record, serial_line_open, &head)
	text_count := min(int(record.text_count), op.LOG_TEXT_CAPACITY)
	serial_line_count, serial_line_written = 0, 0
	serial_line_time = max(record.time, 1)
	serial_line_put(head[:head_count])
	serial_line_put(record.text[:text_count])
	serial_line_open = record.more != 0
	if !serial_line_open {
		serial_line_put({'\r', '\n'})
	}
}

// serial_lost_line puts in serial_line the line of the records that the log
// wrote over before the drain reached them. It ends the line that one of
// them began. Each scenario of the tool fails on this line.
@(private = "file")
serial_lost_line :: proc "contextless" (lost: u64) {
	serial_line_count, serial_line_written = 0, 0
	serial_line_time = 0
	if serial_line_open {
		serial_line_put({'\r', '\n'})
		serial_line_open = false
	}
	digits: [20]u8
	digit_count := 0
	rest := lost
	for {
		digits[len(digits) - 1 - digit_count] = u8('0' + rest % 10)
		digit_count += 1
		rest /= 10
		if rest == 0 {break}
	}
	serial_line_put(transmute([]u8)string("kernel: "))
	serial_line_put(digits[len(digits) - digit_count:])
	serial_line_put(transmute([]u8)string(" records of the log did not reach the serial port\r\n"))
}

// serial_drain_all writes each record that the log holds now and the serial
// port does not have yet, and waits for the device. The caller is the
// serial writer: the flush, a report, or a writer before the first tick.
serial_drain_all :: proc "contextless" () {
	if log_head != nil {
		_ = serial_drain(intrinsics.atomic_load(&log_head.written), nil, .Wait)
	}
}

// serial_drain_of_a_processor is the drain of a tick of any processor, and
// of a wait for a lock past LOCK_WAIT_BEFORE_DRAIN_MILLISECONDS. It does not
// wait for the serial writer: when another drain, the flush or a report
// holds it, that one writes. So a hang of one processor does not silence
// the lines of the others.
serial_drain_of_a_processor :: proc "contextless" (cpu: ^Processor) {
	if log_head == nil || intrinsics.atomic_load(&log_serial_only) || !serial_writer_take(cpu.apic_id + 1, 0) {
		return
	}
	// A report that began after the look above keeps its writer, and this
	// drain gives it back at once.
	if !intrinsics.atomic_load(&log_serial_only) {
		_ = serial_drain(intrinsics.atomic_load(&log_head.written), cpu, .Tick)
	}
	serial_writer_free()
}

// serial_drain_while_idle is the drain of a processor that has nothing to
// run: before its idle wait, for as long as no queue receives a thread
// since `pushes` and no interrupt comes. So on a machine with an idle
// processor the serial port lags the log only by the rate of the port. It
// takes no lock, and an interrupt comes only in interrupt_window, between
// two bytes, with the serial writer free (serial_idle_window). The caller
// set cpu.idle: a waker sends it an interrupt, which the next window takes.
// interrupted: an interrupt came, as after idle_wait, so the caller looks
// at its queues and sets its idle flag again before it waits: a wake of
// kick_all, which pushes no thread and clears the flag, is not lost.
serial_drain_while_idle :: proc "contextless" (cpu: ^Processor, pushes: u32) -> (interrupted: bool) {
	if log_head == nil || intrinsics.atomic_load(&log_serial_only) || !serial_writer_take(cpu.apic_id + 1, 0) {
		return false
	}
	idle := Serial_Idle_Drain {
		pushes            = pushes,
		interrupts_before = intrinsics.atomic_load(&cpu.idle_interrupts),
	}
	if !intrinsics.atomic_load(&log_serial_only) {
		_ = serial_drain(intrinsics.atomic_load(&log_head.written), cpu, .Idle, &idle)
	}
	if !idle.writer_lost {
		serial_writer_free()
	}
	return intrinsics.atomic_load(&cpu.idle_interrupts) != idle.interrupts_before
}

// serial_tick is the drain of the tick of a processor, then the one line of
// the measure of the drain, after the serial writer is free: that line is a
// record of the log, written under the log lock, which no holder of the
// serial writer takes.
serial_tick :: proc "contextless" (cpu: ^Processor) {
	// A load first: each Log reads this word, and a store at each tick of
	// each processor would take its line of the cache from them.
	if !intrinsics.atomic_load(&serial_tick_drains) {
		intrinsics.atomic_store(&serial_tick_drains, true)
	}
	serial_drain_of_a_processor(cpu)
	if _, ready := intrinsics.atomic_compare_exchange_strong(&serial_measure_state, Serial_Measure_State.Ready, Serial_Measure_State.Written); ready {
		bytes := intrinsics.atomic_load(&serial_measured_bytes)
		cycles := max(intrinsics.atomic_load(&serial_measured_cycles), 1)
		frequency := max(cycle_frequency, 1)
		// The rate of the port: the bytes over the cycles of their writes.
		// An idle processor drains at that rate.
		rate := bytes * frequency / cycles
		// What one busy processor keeps when it writes SERIAL_MICROSECONDS_OF_A_TICK at each tick.
		at_the_ticks := rate * SERIAL_MICROSECONDS_OF_A_TICK * TICKS_PER_SECOND / 1_000_000
		log("kernel: the drain of the serial port wrote ", Size{bytes, .Bytes}, " in ", Duration{cycles * 1_000_000 / frequency, .Microseconds}, " of port writes: ", rate, " bytes each second while it writes; ", intrinsics.atomic_load(&serial_measured_idle_bytes), " bytes in the idle loop, at that rate, and ", intrinsics.atomic_load(&serial_measured_tick_bytes), " at the ticks, at most ", at_the_ticks, " each second for one busy processor")
	}
	delivery_faults_log()
}

// The count in the last line of each fault of delivery.
serial_bytes_dropped_written: u64
apic_sends_not_sent_written: u64

// delivery_faults_log writes the count of the bytes that the serial port
// did not take and of the interrupts that the controller did not send,
// each time a count reaches a new power of two: a device that stays broken
// writes about one line for each doubling, not one line at each tick. The
// writers of the counts can hold any lock, the tick holds none. The line is
// a record of the log, so the serial port shows it when it takes bytes
// again, and the log shows it when the port never does.
@(private = "file")
delivery_faults_log :: proc "contextless" () {
	if count, reached := count_reached_a_power_of_two(&serial_bytes_dropped, &serial_bytes_dropped_written); reached {
		log("kernel: the serial port did not take ", count, " bytes in their bound: the log keeps each record, and the serial port lacks their lines")
	}
	if count, reached := count_reached_a_power_of_two(&apic_sends_not_sent, &apic_sends_not_sent_written); reached {
		log("kernel: the interrupt controller did not send ", count, " interrupts to another processor in their bound: a processor that one of them would wake waits for its next interrupt, and a synchronization waits for the next tick of its target")
	}
}

// count_reached_a_power_of_two says if `count` has a higher power of two
// than the count of the last line (delivery_count.line_is_due), and takes
// it as that count: one tick alone writes the line.
@(private = "file")
count_reached_a_power_of_two :: proc "contextless" (count: ^u64, written: ^u64) -> (now: u64, reached: bool) {
	now = intrinsics.atomic_load(count)
	before := intrinsics.atomic_load(written)
	if !delivery_count.line_is_due(before, now) {
		return now, false
	}
	_, reached = intrinsics.atomic_compare_exchange_strong(written, before, now)
	return now, reached
}

#assert(SERIAL_MICROSECONDS_OF_A_TICK == 100) // The line of the measure says it.

// serial_drain_before_the_tick drains the log at once until a tick does
// it. The caller holds no log lock.
serial_drain_before_the_tick :: proc "contextless" () {
	if intrinsics.atomic_load(&serial_tick_drains) {
		return
	}
	self: u32 = 0
	if lock_ready {
		self = apic_id() + 1
	}
	if !serial_writer_take(self, 0) {
		return
	}
	if !intrinsics.atomic_load(&log_serial_only) {
		serial_drain_all()
	}
	serial_writer_free()
}

// serial_flush writes each record that the serial port does not have yet,
// before the machine stops: the last line of a test reaches the host. The
// report of a fault drained the log already, and writes no record after. It
// waits at most FAULT_REPORT_WAIT_MILLISECONDS for another writer: a drain
// of a processor gives the writer back within a tick, so a writer that
// keeps it longer stopped with the machine, and the flush takes it. It
// writes at most the whole log, LOG_RECORD_CAPACITY lines.
serial_flush :: proc "contextless" () {
	if log_head == nil || intrinsics.atomic_load(&log_serial_only) {
		return
	}
	self: u32 = 0
	if lock_ready {
		self = apic_id() + 1
	}
	if !serial_writer_take(self, FAULT_REPORT_WAIT_MILLISECONDS) {
		intrinsics.atomic_store(&serial_writer, self)
	}
	serial_drain_all()
	// The measure of the lag of a line, once, on the serial port only: the
	// machine stops, and a record written now would not reach the port.
	digits: [20]u8
	log_bytes(transmute([]u8)string("kernel: the largest lag of a line of the log on the serial port: "))
	log_bytes(decimal_digits(&digits, serial_largest_lag))
	log_bytes(transmute([]u8)string(" us\r\n"))
	serial_writer_free()
}

// own_log_ring_take takes the frames of the own log ring of a new process,
// zero, and the budget pays each one. false: the budget has too few pages,
// and none is taken.
own_log_ring_take :: proc "contextless" (budget: ^u32) -> (frames: [op.OWN_LOG_PAGES]u64, ok: bool) {
	for &frame in frames {
		frame = frame_paid(budget)
		if frame == 0 {
			own_log_ring_give_back(frames, budget)
			return {}, false
		}
	}
	return frames, true
}

// own_log_ring_give_back frees the frames of an own log ring, and the
// budget gets their pages back. A frame of 0 was never taken. The caller
// does not hold the log lock: the frame lock comes before it.
own_log_ring_give_back :: proc "contextless" (frames: [op.OWN_LOG_PAGES]u64, budget: ^u32) {
	lock_take(&frame_lock, .Frame)
	for frame in frames {
		if frame != 0 {
			frames_free_held(frame, 1)
			budgets[budget^].amounts.pages += 1
		}
	}
	lock_free(&frame_lock, .Frame)
}

// own_log_ring_end frees the own log ring of a process, if it has one, and
// its pages return to its budget. The frames are cleared under the log
// lock, so no Log_Read copies the ring after its pages leave; the frame
// lock comes after the log lock is free. No thread of the process runs:
// the caller is the first run of a guest, under the process lock, or the
// free of the slot, under the control lock, with at most process locks.
own_log_ring_end :: proc "contextless" (owner: ^Process) {
	log_taken := log_take()
	ring_frames := owner.log_ring_frames
	owner.log_ring_frames = {}
	log_free(log_taken)
	own_log_ring_give_back(ring_frames, &owner.budget)
}

// own_log_ring_copy copies, under the log lock, the records of the own log
// ring of a process from the own number `after` on into a buffer: at most
// `count`, in the order of their own numbers (op.own_log_window). found is
// false when the slot holds no process with this serial and a ring. The
// frames, the serial and the count of the owner change only under the log
// lock while a ring exists: process_create sets the frames after the
// serial, and the end of the ring clears them first.
own_log_ring_copy :: proc "contextless" (owner: ^Process, serial: u64, after: u32, count: u64, buffer: ^[op.OWN_LOG_RECORD_CAPACITY]op.Log_Record) -> (copied: u64, lost: u64, total: u64, found: bool) {
	taken := log_take()
	defer log_free(taken)
	if owner.log_ring_frames[0] == 0 || u64(intrinsics.atomic_load(&owner.serial)) != serial {
		return 0, 0, 0, false
	}
	first: u64
	first, lost, total = op.own_log_window(owner.log_records_written, after)
	copied = min(total, count, u64(op.OWN_LOG_RECORD_CAPACITY))
	for number in 0 ..< copied {
		buffer[number] = own_log_record(owner, first + number)^
	}
	return copied, lost, total, true
}

// own_log_record gives the place of the record with the count `number` in
// the own log ring of a process, through the direct map. The caller holds
// the log lock, and the process has a ring.
own_log_record :: proc "contextless" (owner: ^Process, number: u64) -> ^op.Log_Record {
	page, offset := op.own_log_place(number)
	return direct(owner.log_ring_frames[page] + offset, op.Log_Record)
}

// log_records_of_text gives the records that log_record writes for a text:
// it cuts the text as log_record does, after a whole character, and an
// empty text is one record. Log spends this many records of its budget.
log_records_of_text :: proc "contextless" (text: []u8) -> u64 {
	records: u64 = 0
	rest := text
	for {
		part := rest[:min(len(rest), op.LOG_TEXT_CAPACITY)]
		if len(part) < len(rest) {
			if whole := text_encoding.complete_characters(part); whole > 0 {
				part = part[:whole]
			}
		}
		rest = rest[len(part):]
		records += 1
		if len(rest) == 0 {
			return records
		}
	}
}

// log_record adds a text to the memory object of the log: one record, or
// more if the text is long. Each record keeps the part of the value runs
// that falls in its text; the runs are in order and inside the text
// (value_kinds.value_runs_check). The caller holds the log lock.
//
// The process slot and the process serial together name the process: the
// log service gives a reader the records of its own process by the two
// (src/md/features/log_reader_scope.md). `owner` is that process, nil for a
// record of the kernel. Its count of records takes one for each record,
// under the log lock: each record takes the next own number, so a reader
// of its own records numbers them with no count of the records of other
// processes. Each record of a process also goes to its own log ring, which
// only its own records fill: a reader of its own records reads them there,
// and the records of the others never push them out
// (src/md/features/own_log_ring.md).
log_record :: proc "contextless" (process: u32, process_serial: u32, owner: ^Process, thread: u32, name: []u8, channel: []u8, level: op.Log_Level, text: []u8, runs: []value_kinds.Value_Run_In_Call) {
	if log_head == nil || log_serial_only {
		return
	}
	rest := text
	offset := 0
	for {
		part := rest[:min(len(rest), op.LOG_TEXT_CAPACITY)]
		// A record ends after a whole character, so that the text of each
		// record is UTF-8 on its own.
		if len(part) < len(rest) {
			if whole := text_encoding.complete_characters(part); whole > 0 {
				part = part[:whole]
			}
		}
		rest = rest[len(part):]
		written := log_head.written
		// The store of `written` for the record before must come before any
		// store of this record: a reader that sees a byte of this record then
		// sees the new `written`, and drops its copy (op.log_copy_kept).
		// Between two calls the log lock orders them; inside one long text
		// only this fence does. On x86 it only stops the compiler.
		intrinsics.atomic_thread_fence(.Release)
		own_count: u64
		if owner != nil {
			own_count = owner.log_records_written
			owner.log_records_written += 1
		}
		record := &log_records[written % op.LOG_RECORD_CAPACITY]
		record^ = {
			sequence       = written,
			time           = microseconds(cycles_now()),
			process        = u8(process),
			thread         = u8(thread),
			process_serial = process_serial,
			own_number     = u32(own_count), // The low bits: a reader names a record by its distance to the count (op.own_log_window).
			level          = level,
			more           = u8(len(rest) != 0),
			text_count     = u16(len(part)),
		}
		copy(record.name[:len(record.name) - 1], name)
		copy(record.channel[:], channel)
		copy(record.text[:], part)
		record.run_count = u8(value_kinds.value_runs_of_record(runs, offset, len(part), record.runs[:]))
		offset += len(part)
		// The same bytes in the own log ring. No reader maps that ring: a
		// copy comes only from Log_Read, under the log lock, so no fence.
		if owner != nil && owner.log_ring_frames[0] != 0 {
			own_log_record(owner, own_count)^ = record^
		}
		// The record is complete before a reader can see it.
		intrinsics.atomic_store(&log_head.written, written + 1)
		if len(rest) == 0 {
			break
		}
	}
	word_wake(physical_of(&log_head.written), max(u64))
}

// machine_stop ends the machine under QEMU, or halts the processor. It is
// inlined, so each caller calls machine_stop_with_code: the measure of the
// kernel stack names that one edge.
machine_stop :: #force_inline proc "contextless" (reason: Machine_Stop_Reason) -> ! {
	machine_stop_with_code(u8(reason))
}

// Why the kernel stops the machine: the code that the host receives. The
// tool reads the code, so each value is explicit. The operation
// Machine_Stop gives its own code (machine_stop_with_code).
Machine_Stop_Reason :: enum u8 {
	Normal_End       = 0, // No process is left, or a self test of the start ended as it must.
	Start_Failed     = 1, // The kernel cannot start: a record, a table or a part of the processor is missing or wrong.
	Fault            = 2, // A fault of the kernel or of the machine: an exception in the kernel, a machine check.
	Invariant_Broken = 3, // A check of the kernel found a broken rule: the lock order, a count, a lock that an operation asked for while it held it.
}

// machine_stop_with_code stops the machine with a code for the host: a
// reason of the kernel, or the code of Machine_Stop.
machine_stop_with_code :: proc "contextless" (code: u8) -> ! {
	// Each other processor stops at its next kernel entry.
	if processor_count > 1 {
		intrinsics.atomic_store(&machine_stopping, true)
		self := apic_id()
		for cpu in processors[:processor_count] {
			if cpu.apic_id != self {
				apic_send(cpu.apic_id, VECTOR_SYNC)
			}
		}
	}
	// The tick no longer drains the log after this: the records that the
	// serial port does not have yet go now, the last line of a test too.
	serial_flush()
	port_write_8(DEBUG_EXIT_PORT, code)
	processor_stop()
}
