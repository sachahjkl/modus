package machine

import "core:fmt"
import "core:strings"

// The share of the host that a machine got while a step waited for it
// (src/md/infrastructure/machine_test_parts.md, "The chosen form").
// A step that ends at its bound says only that a line did not come: the
// system can hang, or the host can give the machine no processor for
// minutes. The tool reads the counters of the host at the start of each
// Wait and at its failure, and the failure line says which one it was.
// The procedures of this file are pure: the readers of the files of the
// host are in host_share_linux.odin.

// The clock ticks of utime and stime in /proc/<pid>/task/<tid>/stat: the
// USER_HZ of the Linux interface, 100 on x86-64 whatever the tick of the
// kernel of the host.
LINUX_CLOCK_TICKS_PER_SECOND :: 100

// The places of utime and stime among the fields that follow the name of
// the thread in stat: the field 3 of proc(5) is the first after the name.
STAT_USER_TIME_AFTER_NAME :: 14 - 3
STAT_SYSTEM_TIME_AFTER_NAME :: 15 - 3
// The place of run_delay, the time that the thread was ready and waited for
// a processor, in schedstat: its second field.
SCHEDSTAT_RUN_DELAY_FIELD :: 1

// The machine got almost no processor time when it ran at most this
// fraction of the wait (one part in HOST_SHARE_SMALL_DIVISOR).
HOST_SHARE_SMALL_DIVISOR :: 10
// The host starved the machine when its threads waited for a processor, and
// the host stalled on memory, for at least this fraction of the wait in all
// (one part in HOST_SHARE_STALL_DIVISOR). A system that waits for an event
// that never comes leaves its processors halted: its threads then wait for
// no processor, and the host has memory.
HOST_SHARE_STALL_DIVISOR :: 2

// Why a counter of the host has no value.
Host_Read_Fault :: enum u8 {
	None,
	Unreadable, // The file does not exist or cannot be read: another host, a thread that ended, no pressure stall information.
	No_Name_End, // A stat line with no ")" after the name of its thread.
	Missing_Field, // The line or the field is not there.
	Not_A_Number, // A field that is not a decimal number.
	Too_Large, // A number, or a sum, past the largest value of 64 bits.
	Wrong_Unit, // A line of meminfo whose unit is not kB.
	Went_Backwards, // The counter at the end of the wait is below the one at its start.
}

@(rodata)
host_read_fault_sentences := [Host_Read_Fault]string {
	.None           = "no fault",
	.Unreadable     = "the file of the host cannot be read",
	.No_Name_End    = "a line of stat has no end of the name of its thread",
	.Missing_Field  = "a field is missing",
	.Not_A_Number   = "a field is not a decimal number",
	.Too_Large      = "a number is past the largest value of 64 bits",
	.Wrong_Unit     = "the unit is not kB",
	.Went_Backwards = "the counter went backwards over the wait",
}

// decimal_field reads a field of a file of the host: decimal digits only,
// with no sign and no separator.
decimal_field :: proc(text: string) -> (value: u64, fault: Host_Read_Fault) {
	if text == "" {
		return 0, .Missing_Field
	}
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return 0, .Not_A_Number
		}
		digit := u64(character - '0')
		if value > (max(u64) - digit) / 10 {
			return 0, .Too_Large
		}
		value = value * 10 + digit
	}
	return value, .None
}

// counter_sum adds two counters, and refuses a sum past 64 bits.
counter_sum :: proc(first, second: u64) -> (sum: u64, fault: Host_Read_Fault) {
	if first > max(u64) - second {
		return 0, .Too_Large
	}
	return first + second, .None
}

// counter_difference gives what a counter grew over a wait. A counter of
// the host only grows; a sum over threads falls when a thread ends, and
// that difference is refused, never taken as a small one.
counter_difference :: proc(before, after: u64) -> (difference: u64, fault: Host_Read_Fault) {
	if after < before {
		return 0, .Went_Backwards
	}
	return after - before, .None
}

// thread_stat_processor_ticks gives utime plus stime of one line of
// /proc/<pid>/task/<tid>/stat, in clock ticks. The name of the thread is
// between "(" and the last ")", and can hold spaces and ")".
thread_stat_processor_ticks :: proc(line: string) -> (ticks: u64, fault: Host_Read_Fault) {
	name_end := strings.last_index_byte(line, ')')
	if name_end < 0 {
		return 0, .No_Name_End
	}
	fields := strings.fields(line[name_end + 1:], context.temp_allocator)
	if len(fields) <= max(STAT_USER_TIME_AFTER_NAME, STAT_SYSTEM_TIME_AFTER_NAME) {
		return 0, .Missing_Field
	}
	user, user_fault := decimal_field(fields[STAT_USER_TIME_AFTER_NAME])
	if user_fault != .None {
		return 0, user_fault
	}
	system, system_fault := decimal_field(fields[STAT_SYSTEM_TIME_AFTER_NAME])
	if system_fault != .None {
		return 0, system_fault
	}
	return counter_sum(user, system)
}

// thread_schedstat_run_delay gives run_delay of the line of
// /proc/<pid>/task/<tid>/schedstat, in nanoseconds.
thread_schedstat_run_delay :: proc(line: string) -> (nanoseconds: u64, fault: Host_Read_Fault) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) <= SCHEDSTAT_RUN_DELAY_FIELD {
		return 0, .Missing_Field
	}
	return decimal_field(fields[SCHEDSTAT_RUN_DELAY_FIELD])
}

// pressure_full_total gives the field total= of the line "full" of
// /proc/pressure/memory: the microseconds in which every task of the host
// that was not idle waited for memory at the same time.
pressure_full_total :: proc(text: string) -> (microseconds: u64, fault: Host_Read_Fault) {
	lines := strings.split_lines(text, context.temp_allocator)
	for line in lines {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 || fields[0] != "full" {
			continue
		}
		for field in fields[1:] {
			if strings.has_prefix(field, "total=") {
				return decimal_field(field[len("total="):])
			}
		}
		return 0, .Missing_Field
	}
	return 0, .Missing_Field
}

// meminfo_available_kib gives the line MemAvailable of /proc/meminfo, in
// KiB: what the host can give to new programs with no swap.
meminfo_available_kib :: proc(text: string) -> (kib: u64, fault: Host_Read_Fault) {
	lines := strings.split_lines(text, context.temp_allocator)
	for line in lines {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 || fields[0] != "MemAvailable:" {
			continue
		}
		if len(fields) < 3 {
			return 0, .Missing_Field
		}
		if fields[2] != "kB" {
			return 0, .Wrong_Unit
		}
		return decimal_field(fields[1])
	}
	return 0, .Missing_Field
}

// One read of the counters of the host for one machine: the sums over the
// threads of its QEMU, and the memory stall of the whole host. Each counter
// has its fault: a counter that cannot be read keeps the others.
Host_Share_Sample :: struct {
	processor_ticks:          u64, // utime + stime of every thread of QEMU.
	processor_fault:          Host_Read_Fault,
	run_delay_nanoseconds:    u64, // run_delay of every thread of QEMU.
	run_delay_fault:          Host_Read_Fault,
	memory_full_microseconds: u64, // The total of the line "full" of /proc/pressure/memory.
	memory_fault:             Host_Read_Fault,
}

// sample_difference_milliseconds gives what one counter of two samples grew, in
// milliseconds, with the fault of either sample first.
@(private = "file")
sample_difference_milliseconds :: proc(before, after: u64, before_fault, after_fault: Host_Read_Fault, units_in_a_millisecond: u64) -> (milliseconds: u64, fault: Host_Read_Fault) {
	if before_fault != .None {
		return 0, before_fault
	}
	if after_fault != .None {
		return 0, after_fault
	}
	difference, difference_fault := counter_difference(before, after)
	if difference_fault != .None {
		return 0, difference_fault
	}
	return difference / units_in_a_millisecond, .None
}

// host_share_sentence says what the host gave the machine over a wait of
// waited_milliseconds: the processor time of QEMU, the time that its
// threads waited for a processor, and the memory stall of the host. When
// the machine ran almost not at all, it says whether the host starved it
// or the machine was idle, so that a reader knows at once whether the
// failure is a fault of the system.
host_share_sentence :: proc(before, after: Host_Share_Sample, waited_milliseconds: u64) -> string {
	builder := strings.builder_make(context.temp_allocator)
	waited_seconds := f64(waited_milliseconds) / 1000
	// With a unit of 1, the difference stays in clock ticks.
	ran_ticks, ran_fault := sample_difference_milliseconds(before.processor_ticks, after.processor_ticks, before.processor_fault, after.processor_fault, 1)
	ran_milliseconds: u64
	if ran_fault == .None {
		if ran_ticks > max(u64) / 1000 {
			ran_fault = .Too_Large
		} else {
			ran_milliseconds = ran_ticks * 1000 / LINUX_CLOCK_TICKS_PER_SECOND
		}
	}
	if ran_fault == .None {
		fmt.sbprintf(&builder, "the host ran the machine for %d ms of the %.1f s of the wait", ran_milliseconds, waited_seconds)
	} else {
		fmt.sbprintf(&builder, "the processor time of the machine over the %.1f s of the wait is unknown: %s", waited_seconds, host_read_fault_sentences[ran_fault])
	}
	delay_milliseconds, delay_fault := sample_difference_milliseconds(before.run_delay_nanoseconds, after.run_delay_nanoseconds, before.run_delay_fault, after.run_delay_fault, 1_000_000)
	if delay_fault == .None {
		fmt.sbprintf(&builder, "; its threads waited %d ms in all for a processor", delay_milliseconds)
	} else {
		fmt.sbprintf(&builder, "; the wait of its threads for a processor is unknown: %s", host_read_fault_sentences[delay_fault])
	}
	stall_milliseconds, stall_fault := sample_difference_milliseconds(before.memory_full_microseconds, after.memory_full_microseconds, before.memory_fault, after.memory_fault, 1000)
	if stall_fault == .None {
		fmt.sbprintf(&builder, "; every task of the host waited for memory for %d ms", stall_milliseconds)
	} else {
		fmt.sbprintf(&builder, "; the memory stall of the host is unknown: %s", host_read_fault_sentences[stall_fault])
	}
	if ran_fault != .None {
		return strings.to_string(builder)
	}
	if ran_milliseconds * HOST_SHARE_SMALL_DIVISOR > waited_milliseconds {
		strings.write_string(&builder, ": the machine had the processor, so the line did not come from the system")
		return strings.to_string(builder)
	}
	if delay_fault != .None || stall_fault != .None {
		return strings.to_string(builder)
	}
	// A stall past 64 bits is a stall of the whole wait.
	stalled, stalled_fault := counter_sum(delay_milliseconds, stall_milliseconds)
	if stalled_fault != .None || stalled >= waited_milliseconds / HOST_SHARE_STALL_DIVISOR {
		strings.write_string(&builder, ": the host starved the machine, which is no hang of the system")
	} else {
		strings.write_string(&builder, ": the machine was idle: its processors waited for an event that did not come")
	}
	return strings.to_string(builder)
}
