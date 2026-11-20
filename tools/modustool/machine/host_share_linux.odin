package machine

import "core:fmt"
import "core:os"

// The reads of the files of the host for the share of the host of a
// machine and for the bound by memory of the parts (host_share.odin holds
// their pure parse).

HOST_PRESSURE_OF_MEMORY :: "/proc/pressure/memory"
HOST_MEMORY_INFORMATION :: "/proc/meminfo"

// host_share_sample reads the counters of the threads of one QEMU and the
// memory stall of the host. A thread that ends between the list and its
// read makes its counter unknown for this sample: the sum would fall.
host_share_sample :: proc(process_identifier: int) -> (sample: Host_Share_Sample) {
	tasks := fmt.tprintf("/proc/%d/task", process_identifier)
	entries, list_error := os.read_all_directory_by_path(tasks, context.temp_allocator)
	if list_error != nil || len(entries) == 0 {
		sample.processor_fault, sample.run_delay_fault = .Unreadable, .Unreadable
	}
	for entry in entries {
		if sample.processor_fault == .None {
			stat, stat_error := os.read_entire_file(fmt.tprintf("%s/%s/stat", tasks, entry.name), context.temp_allocator)
			ticks, fault := thread_stat_processor_ticks(string(stat))
			if stat_error != nil {
				fault = .Unreadable
			}
			if fault == .None {
				sample.processor_ticks, fault = counter_sum(sample.processor_ticks, ticks)
			}
			sample.processor_fault = fault
		}
		if sample.run_delay_fault == .None {
			schedstat, schedstat_error := os.read_entire_file(fmt.tprintf("%s/%s/schedstat", tasks, entry.name), context.temp_allocator)
			delay, fault := thread_schedstat_run_delay(string(schedstat))
			if schedstat_error != nil {
				fault = .Unreadable
			}
			if fault == .None {
				sample.run_delay_nanoseconds, fault = counter_sum(sample.run_delay_nanoseconds, delay)
			}
			sample.run_delay_fault = fault
		}
	}
	pressure, pressure_error := os.read_entire_file(HOST_PRESSURE_OF_MEMORY, context.temp_allocator)
	if pressure_error != nil {
		sample.memory_fault = .Unreadable
	} else {
		sample.memory_full_microseconds, sample.memory_fault = pressure_full_total(string(pressure))
	}
	return sample
}

// host_memory_available_mib gives MemAvailable of the host, in MiB.
host_memory_available_mib :: proc() -> (mib: u64, known: bool) {
	text, read_error := os.read_entire_file(HOST_MEMORY_INFORMATION, context.temp_allocator)
	if read_error != nil {
		return 0, false
	}
	kib, fault := meminfo_available_kib(string(text))
	if fault != .None {
		return 0, false
	}
	return kib / 1024, true
}
