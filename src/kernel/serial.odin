package kernel

import "base:intrinsics"
import "modus:contract/cut_mark"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// The serial port is the log of the kernel. It is the only device that the
// kernel has code for, apart from the processor and its interrupt controller.

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

log_bytes :: proc "contextless" (bytes: []u8) {
	for b in bytes {
		for port_read_8(SERIAL_PORT + 5) & 0x20 == 0 {}
		port_write_8(SERIAL_PORT, b)
	}
}

// The log (operation.Log_Record). Each record goes to two places: the
// serial port, as one line of text, and the memory object of the log,
// that programs with the grant read. The record also keeps the kind of each
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
// A record keeps the slot of its program and of its thread in one byte
// each, so that it has room for the program serial and the own number in
// its 256 bytes.
#assert(PROGRAM_CAPACITY <= 1 << 8)
#assert(THREAD_TABLE_CAPACITY <= 1 << 8)
log_serial_only: bool // The kernel reports its own fault: it takes no lock, and writes the serial port only.
// The log lock protects the records of the log and their counter, and the
// own log ring of each program with its count and its frames
// (docs/ARCHITECTURE.md, "Locks of the kernel"). It does not protect the
// serial port: a Log that waited for the serial port under it would learn
// how much the other programs wrote (src/md/features/log_side_channels.md).
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
// The bytes that the drain of a tick wrote, and the cycles that it took,
// for the one line of its measure.
serial_measured_bytes: u64
serial_measured_cycles: u64
// 0: the measure is not ready; 1: ready, the next tick writes it; 2: written.
serial_measure_state: u32
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
// program, and a read through it would be a second fault, with no end.
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
		machine_stop(2)
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
// one record with that count, inside the bound. So the records of the
// kernel and of the machine in two seconds back to back fit the whole log
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

// serial_drain writes on the serial port the records of the whole log from
// serial_next up to the record before `until`, in their order, and gives
// the bytes that it wrote. The caller is the serial writer. It reads the
// log as a reader of the whole log does, with no log lock, so no Log waits
// for the serial port (serial_line_next).
//
// With a processor (a tick, a long wait for a lock), it writes only while
// the device takes bytes: SERIAL_QUEUE_BYTES when the transmit register is
// empty, and it leaves when it is not, or after
// SERIAL_MICROSECONDS_OF_A_TICK, so it never spins with interrupts off;
// between two writes it answers processor_sync, and it leaves when the
// machine stops, for the flush. With no processor (the flush, a report, the
// start), it waits for the device and has no bound: those end the machine
// or run alone.
@(private = "file")
serial_drain :: proc "contextless" (until: u64, cpu: ^Processor) -> (bytes: int) {
	if log_head == nil {
		return 0
	}
	// Before the timer is measured the frequency is 0: one burst.
	deadline := cycles_now() + cycle_frequency / 1_000_000 * SERIAL_MICROSECONDS_OF_A_TICK
	for {
		if serial_line_written == serial_line_count && !serial_line_next(until) {
			return bytes
		}
		if cpu == nil {
			for port_read_8(SERIAL_LINE_STATUS) & SERIAL_TRANSMIT_EMPTY == 0 {
				intrinsics.cpu_relax()
			}
		} else {
			if cycles_now() >= deadline || intrinsics.atomic_load(&machine_stopping) {
				return bytes
			}
			sync_acknowledge(cpu)
			if port_read_8(SERIAL_LINE_STATUS) & SERIAL_TRANSMIT_EMPTY == 0 {
				return bytes
			}
		}
		// The queue of the device is empty: up to SERIAL_QUEUE_BYTES go with
		// no look at the line status. The drain of a processor looks at the
		// time before each byte, so it ends within one port write of its
		// bound; the byte that it did not write waits in serial_line.
		burst := min(SERIAL_QUEUE_BYTES, serial_line_count - serial_line_written)
		for _ in 0 ..< burst {
			if cpu != nil && cycles_now() >= deadline {
				break
			}
			port_write_8(SERIAL_PORT, serial_line[serial_line_written])
			serial_line_written += 1
			bytes += 1
		}
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
		_ = serial_drain(intrinsics.atomic_load(&log_head.written), nil)
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
		started := cycles_now()
		written := serial_drain(intrinsics.atomic_load(&log_head.written), cpu)
		// The measure counts only the drains that wrote: the rate that the
		// drain keeps while it has lines.
		if written > 0 && intrinsics.atomic_load(&serial_measure_state) == 0 {
			intrinsics.atomic_add(&serial_measured_cycles, cycles_now() - started)
			if intrinsics.atomic_add(&serial_measured_bytes, u64(written)) + u64(written) >= SERIAL_MEASURE_BYTES {
				intrinsics.atomic_store(&serial_measure_state, 1)
			}
		}
	}
	serial_writer_free()
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
	if _, ready := intrinsics.atomic_compare_exchange_strong(&serial_measure_state, 1, 2); ready {
		bytes := intrinsics.atomic_load(&serial_measured_bytes)
		cycles := max(intrinsics.atomic_load(&serial_measured_cycles), 1)
		frequency := max(cycle_frequency, 1)
		rate := bytes * frequency / cycles
		// What one processor keeps when it writes SERIAL_MICROSECONDS_OF_A_TICK at each tick.
		at_the_ticks := rate * SERIAL_MICROSECONDS_OF_A_TICK * TICKS_PER_SECOND / 1_000_000
		log("kernel: the drain of the serial port wrote ", Size{bytes, .Bytes}, " in ", Duration{cycles * 1_000_000 / frequency, .Microseconds}, " of writing: ", rate, " bytes each second while it writes, ", at_the_ticks, " at 100 us of each tick of one processor")
	}
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
	serial_writer_free()
}

// own_log_ring_take takes the frames of the own log ring of a new program,
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

// own_log_ring_end frees the own log ring of a program, if it has one, and
// its pages return to its budget. The frames are cleared under the log
// lock, so no Log_Read copies the ring after its pages leave; the frame
// lock comes after the log lock is free. No thread of the program runs:
// the caller is the first run of a guest, under the program lock, or the
// free of the slot, under the control lock, with at most program locks.
own_log_ring_end :: proc "contextless" (owner: ^Program) {
	log_taken := log_take()
	ring_frames := owner.log_ring_frames
	owner.log_ring_frames = {}
	log_free(log_taken)
	own_log_ring_give_back(ring_frames, &owner.budget)
}

// own_log_ring_copy copies, under the log lock, the records of the own log
// ring of a program from the own number `after` on into a buffer: at most
// `count`, in the order of their own numbers (op.own_log_window). found is
// false when the slot holds no program with this serial and a ring. The
// frames, the serial and the count of the owner change only under the log
// lock while a ring exists: program_create sets the frames after the
// serial, and the end of the ring clears them first.
own_log_ring_copy :: proc "contextless" (owner: ^Program, serial: u64, after: u32, count: u64, buffer: ^[op.OWN_LOG_RECORD_CAPACITY]op.Log_Record) -> (copied: u64, lost: u64, total: u64, found: bool) {
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
// the own log ring of a program, through the direct map. The caller holds
// the log lock, and the program has a ring.
own_log_record :: proc "contextless" (owner: ^Program, number: u64) -> ^op.Log_Record {
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
// The program slot and the program serial together name the program: the
// log service gives a reader the records of its own program by the two
// (src/md/features/log_reader_scope.md). `owner` is that program, nil for a
// record of the kernel. Its count of records takes one for each record,
// under the log lock: each record takes the next own number, so a reader
// of its own records numbers them with no count of the records of other
// programs. Each record of a program also goes to its own log ring, which
// only its own records fill: a reader of its own records reads them there,
// and the records of the others never push them out
// (src/md/features/own_log_ring.md).
log_record :: proc "contextless" (program: u32, program_serial: u32, owner: ^Program, thread: u32, name: []u8, channel: []u8, level: op.Log_Level, text: []u8, runs: []value_kinds.Value_Run_In_Call) {
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
			program        = u8(program),
			thread         = u8(thread),
			program_serial = program_serial,
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

// machine_stop ends the machine under QEMU, or halts the processor.
machine_stop :: proc "contextless" (code: u8) -> ! {
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
