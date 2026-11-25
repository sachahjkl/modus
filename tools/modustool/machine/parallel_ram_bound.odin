// RAM-budget concurrency calculator and `/proc/meminfo` reader for bounding
// parallel QEMU workers in `modustool test` and `nix flake check`
// (src/md/infrastructure/fast_build.md, src/md/infrastructure/full_check.md).
package machine

import "core:os"
import "core:strings"

// Format property: Linux `/proc/meminfo` reports MemAvailable in kibibytes.
MEMINFO_KIB_TO_BYTES :: u64(1024)

// compute_parallel_vm_limit returns the safe concurrent VM worker count given
// available host memory, per-VM memory cost, reserved host memory margin, and
// CPU worker ceiling.
//
// Refuses invalid bounds (per_vm_bytes == 0 or max_cpus <= 0) by returning 0.
// When available_bytes is at or below reserve_bytes (or fits under one VM),
// degrades safely to 1 sequential worker so single-VM testing still runs.
// Caps against max_cpus before narrowing to int so u64 overflow cannot occur.
compute_parallel_vm_limit :: proc(available_bytes: u64, per_vm_bytes: u64, reserve_bytes: u64, max_cpus: int) -> int {
	if per_vm_bytes == 0 || max_cpus <= 0 {
		return 0
	}
	if available_bytes <= reserve_bytes {
		return 1
	}
	usable := available_bytes - reserve_bytes
	by_ram := usable / per_vm_bytes
	if by_ram <= 1 {
		return 1
	}
	if by_ram >= u64(max_cpus) {
		return max_cpus
	}
	return int(by_ram)
}

// meminfo_parse_available_bytes extracts `MemAvailable:` from `/proc/meminfo`
// content and returns available host memory in bytes. Refuses absent entries,
// malformed numbers, and u64 multiplication overflow.
meminfo_parse_available_bytes :: proc(text: string) -> (bytes: u64, ok: bool) {
	PREFIX :: "MemAvailable:"
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, PREFIX) {
			continue
		}
		tail := strings.trim_left_space(line[len(PREFIX):])
		if len(tail) == 0 {
			return 0, false
		}
		value: u64 = 0
		digits := 0
		for i in 0 ..< len(tail) {
			ch := tail[i]
			if ch < '0' || ch > '9' {
				if ch != ' ' && ch != '\t' {
					return 0, false
				}
				break
			}
			digit := u64(ch - '0')
			if value > (max(u64) - digit) / 10 {
				return 0, false
			}
			value = value * 10 + digit
			digits += 1
		}
		if digits == 0 || value > max(u64) / MEMINFO_KIB_TO_BYTES {
			return 0, false
		}
		return value * MEMINFO_KIB_TO_BYTES, true
	}
	return 0, false
}

// host_available_memory_bytes reads `/proc/meminfo` on Linux hosts and returns
// `MemAvailable` in bytes.
host_available_memory_bytes :: proc() -> (bytes: u64, ok: bool) {
	raw, read_err := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	if read_err != nil {
		return 0, false
	}
	return meminfo_parse_available_bytes(string(raw))
}
