package machine

import "core:fmt"
import "core:strings"
import "core:testing"

// The reads of the files of the host for the share of a machine and for the
// bound by memory (host_share.odin): each damaged input first, then the
// largest value, then the plain case.

// A line of /proc/<pid>/task/<tid>/stat with its utime and stime, for a
// thread of QEMU whose name holds a space and a "/", as the threads of the
// processors of a machine do.
@(private = "file")
stat_line :: proc(user, system: string) -> string {
	return fmt.tprintf("4242 (CPU 0/KVM) S 1 4242 4242 0 -1 4194624 1000 0 0 0 %s %s 0 0 20 0 9 0 12345 1000000 5000", user, system)
}

@(test)
decimal_field_refuses_what_is_not_a_counter :: proc(t: ^testing.T) {
	_, fault := decimal_field("")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	for text in ([]string{"-1", "+1", "1_000", "1 2", "0x10", "12a", " 1", "1.5"}) {
		_, fault = decimal_field(text)
		testing.expectf(t, fault == .Not_A_Number, "%q is refused as no decimal number", text)
	}
	// One past the largest value of 64 bits, and far past it.
	_, fault = decimal_field("18446744073709551616")
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	_, fault = decimal_field("99999999999999999999999")
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	value: u64
	value, fault = decimal_field("18446744073709551615")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, value, max(u64))
	value, fault = decimal_field("0")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, value, 0)
}

@(test)
counters_refuse_a_sum_past_64_bits_and_a_counter_that_goes_backwards :: proc(t: ^testing.T) {
	_, fault := counter_sum(max(u64), 1)
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	_, fault = counter_difference(1, 0)
	testing.expect_value(t, fault, Host_Read_Fault.Went_Backwards)
	_, fault = counter_difference(max(u64), 0)
	testing.expect_value(t, fault, Host_Read_Fault.Went_Backwards)
	value: u64
	value, fault = counter_sum(max(u64), 0)
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, value, max(u64))
	value, fault = counter_difference(0, max(u64))
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, value, max(u64))
	value, fault = counter_difference(7, 7)
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, value, 0)
}

@(test)
thread_stat_refuses_a_damaged_line :: proc(t: ^testing.T) {
	_, fault := thread_stat_processor_ticks("")
	testing.expect_value(t, fault, Host_Read_Fault.No_Name_End)
	_, fault = thread_stat_processor_ticks("4242 (qemu S 1 2 3 4 5 6 7 8 9 10 11 12 13")
	testing.expect_value(t, fault, Host_Read_Fault.No_Name_End)
	// The line ends at utime: stime is missing.
	_, fault = thread_stat_processor_ticks("4242 (qemu) S 1 4242 4242 0 -1 4194624 1000 0 0 0 1500")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = thread_stat_processor_ticks("4242 (qemu)")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = thread_stat_processor_ticks(stat_line("-5", "250"))
	testing.expect_value(t, fault, Host_Read_Fault.Not_A_Number)
	_, fault = thread_stat_processor_ticks(stat_line("1500", "x"))
	testing.expect_value(t, fault, Host_Read_Fault.Not_A_Number)
	_, fault = thread_stat_processor_ticks(stat_line("18446744073709551616", "0"))
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	// Each field fits, and their sum does not.
	_, fault = thread_stat_processor_ticks(stat_line("18446744073709551615", "1"))
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	ticks: u64
	ticks, fault = thread_stat_processor_ticks(stat_line("18446744073709551615", "0"))
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, ticks, max(u64))
	// A name with ")" and spaces: the last ")" ends it.
	ticks, fault = thread_stat_processor_ticks("4242 (a) S 1 (b) S 1 4242 4242 0 -1 4194624 1000 0 0 0 7 3 0 0 20 0 9 0 1 2 3")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, ticks, 10)
	ticks, fault = thread_stat_processor_ticks(stat_line("1500", "250"))
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, ticks, 1750)
}

@(test)
thread_schedstat_refuses_a_damaged_line :: proc(t: ^testing.T) {
	_, fault := thread_schedstat_run_delay("")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = thread_schedstat_run_delay("123456789\n")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = thread_schedstat_run_delay("123456789 -4 12\n")
	testing.expect_value(t, fault, Host_Read_Fault.Not_A_Number)
	_, fault = thread_schedstat_run_delay("1 18446744073709551616 12\n")
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	delay: u64
	delay, fault = thread_schedstat_run_delay("1 18446744073709551615 12\n")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, delay, max(u64))
	delay, fault = thread_schedstat_run_delay("98765432 1234567 40\n")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, delay, 1234567)
}

@(test)
pressure_refuses_a_damaged_text :: proc(t: ^testing.T) {
	_, fault := pressure_full_total("")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	// A kernel that gives the line "some" only.
	_, fault = pressure_full_total("some avg10=0.06 avg60=1.26 avg300=0.56 total=595222883\n")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = pressure_full_total("some avg10=0.06 total=1\nfull avg10=0.01 avg60=0.24 avg300=0.10\n")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = pressure_full_total("full avg10=0.01 total=\n")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = pressure_full_total("full avg10=0.01 total=27a\n")
	testing.expect_value(t, fault, Host_Read_Fault.Not_A_Number)
	_, fault = pressure_full_total("full total=18446744073709551616\n")
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	// The line "fullness" is not the line "full".
	_, fault = pressure_full_total("fullness total=5\n")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	microseconds: u64
	microseconds, fault = pressure_full_total("full total=18446744073709551615\n")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, microseconds, max(u64))
	microseconds, fault = pressure_full_total("some avg10=0.06 avg60=1.26 avg300=0.56 total=595222883\nfull avg10=0.01 avg60=0.24 avg300=0.10 total=276535455\n")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, microseconds, 276535455)
}

@(test)
meminfo_refuses_a_damaged_text :: proc(t: ^testing.T) {
	_, fault := meminfo_available_kib("")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = meminfo_available_kib("MemTotal:       32771264 kB\nMemFree:  1000 kB\n")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = meminfo_available_kib("MemAvailable:   21000000\n")
	testing.expect_value(t, fault, Host_Read_Fault.Missing_Field)
	_, fault = meminfo_available_kib("MemAvailable:   21000000 MB\n")
	testing.expect_value(t, fault, Host_Read_Fault.Wrong_Unit)
	_, fault = meminfo_available_kib("MemAvailable:   lots kB\n")
	testing.expect_value(t, fault, Host_Read_Fault.Not_A_Number)
	_, fault = meminfo_available_kib("MemAvailable:   18446744073709551616 kB\n")
	testing.expect_value(t, fault, Host_Read_Fault.Too_Large)
	kib: u64
	kib, fault = meminfo_available_kib("MemAvailable:   18446744073709551615 kB\n")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, kib, max(u64))
	kib, fault = meminfo_available_kib("MemTotal:       32771264 kB\nMemFree:          524288 kB\nMemAvailable:   21495808 kB\n")
	testing.expect_value(t, fault, Host_Read_Fault.None)
	testing.expect_value(t, kib, 21495808)
}

// The sentence of a failed wait of 120 s. A tick of utime is 10 ms.
@(test)
host_share_sentence_says_which_side_stalled :: proc(t: ^testing.T) {
	WAIT :: u64(120_000)
	before := Host_Share_Sample {
		processor_ticks          = 1000,
		run_delay_nanoseconds    = 5_000_000,
		memory_full_microseconds = 7_000,
	}
	// A counter that cannot be read, or that went backwards: unknown, and
	// no verdict.
	unreadable := before
	unreadable.processor_fault = .Unreadable
	sentence := host_share_sentence(before, unreadable, WAIT)
	testing.expectf(t, strings.contains(sentence, "the processor time of the machine over the 120.0 s of the wait is unknown: the file of the host cannot be read"), "the sentence of an unreadable counter: %s", sentence)
	testing.expectf(t, !strings.contains(sentence, ": the host") && !strings.contains(sentence, ": the machine"), "no verdict with no processor time: %s", sentence)
	backwards := before
	backwards.processor_ticks = before.processor_ticks - 1
	sentence = host_share_sentence(before, backwards, WAIT)
	testing.expectf(t, strings.contains(sentence, "unknown: the counter went backwards over the wait"), "the sentence of a counter that went backwards: %s", sentence)
	// The largest growth: its milliseconds pass 64 bits.
	largest := Host_Share_Sample{processor_ticks = max(u64)}
	sentence = host_share_sentence({}, largest, WAIT)
	testing.expectf(t, strings.contains(sentence, "unknown: a number is past the largest value of 64 bits"), "the sentence of the largest counter: %s", sentence)
	// Almost no processor time, and no read of the memory stall: the facts
	// that it has, and no verdict.
	no_stall := before
	no_stall.processor_ticks += 40
	no_stall.memory_fault = .Unreadable
	sentence = host_share_sentence(before, no_stall, WAIT)
	testing.expectf(t, strings.contains(sentence, "the memory stall of the host is unknown") && !strings.contains(sentence, "starved") && !strings.contains(sentence, "idle"), "no verdict with no memory stall: %s", sentence)
	// The edge of almost no processor time: a tenth of the wait is small,
	// one tick more is not.
	at_tenth := before
	at_tenth.processor_ticks += 1200
	sentence = host_share_sentence(before, at_tenth, WAIT)
	testing.expectf(t, strings.contains(sentence, "the host ran the machine for 12000 ms of the 120.0 s of the wait") && !strings.contains(sentence, "had the processor"), "a tenth of the wait is almost no time: %s", sentence)
	past_tenth := before
	past_tenth.processor_ticks += 1201
	sentence = host_share_sentence(before, past_tenth, WAIT)
	testing.expectf(t, strings.contains(sentence, ": the machine had the processor, so the line did not come from the system"), "past a tenth of the wait the machine ran: %s", sentence)
	// The edge of the stall: half of the wait is a starvation, one
	// millisecond less is an idle machine.
	idle := before
	idle.processor_ticks += 40
	idle.run_delay_nanoseconds += 40_000 * 1_000_000
	idle.memory_full_microseconds += (20_000 - 1) * 1000
	sentence = host_share_sentence(before, idle, WAIT)
	testing.expectf(t, strings.contains(sentence, ": the machine was idle: its processors waited for an event that did not come"), "under half of the wait in stalls the machine was idle: %s", sentence)
	starved := idle
	starved.memory_full_microseconds += 1000
	sentence = host_share_sentence(before, starved, WAIT)
	testing.expectf(t, strings.contains(sentence, ": the host starved the machine, which is no hang of the system"), "half of the wait in stalls is a starvation: %s", sentence)
	// The failure of the incident: 400 ms of 120 s, its processor thread
	// ready the whole time.
	incident := before
	incident.processor_ticks += 40
	incident.run_delay_nanoseconds += 118_000 * 1_000_000
	incident.memory_full_microseconds += 3_000_000
	sentence = host_share_sentence(before, incident, WAIT)
	testing.expect_value(t, sentence, "the host ran the machine for 400 ms of the 120.0 s of the wait; its threads waited 118000 ms in all for a processor; every task of the host waited for memory for 3000 ms: the host starved the machine, which is no hang of the system")
}
