// Host unit tests for the RAM-bounded parallel VM concurrency calculator and
// `/proc/meminfo` parser (parallel_ram_bound.odin).
package machine

import "core:testing"

@(test)
compute_parallel_vm_limit_handles_edges_and_overflow :: proc(t: ^testing.T) {
	GIB :: u64(1024 * 1024 * 1024)

	// Invalid bounds: zero per-VM cost or non-positive CPU ceiling return 0.
	testing.expect_value(t, compute_parallel_vm_limit(16 * GIB, 0, 4 * GIB, 4), 0)
	testing.expect_value(t, compute_parallel_vm_limit(16 * GIB, GIB, 4 * GIB, 0), 0)
	testing.expect_value(t, compute_parallel_vm_limit(16 * GIB, GIB, 4 * GIB, -2), 0)

	// Zero available memory and under-reserve memory degrade safely to 1 VM.
	testing.expect_value(t, compute_parallel_vm_limit(0, GIB, 4 * GIB, 4), 1)
	testing.expect_value(t, compute_parallel_vm_limit(2 * GIB, GIB, 4 * GIB, 4), 1)
	testing.expect_value(t, compute_parallel_vm_limit(4 * GIB, GIB, 4 * GIB, 4), 1)
	testing.expect_value(t, compute_parallel_vm_limit(4 * GIB + 512 * 1024 * 1024, GIB, 4 * GIB, 4), 1)

	// Exact-1 and multi-VM RAM limits.
	testing.expect_value(t, compute_parallel_vm_limit(5 * GIB, GIB, 4 * GIB, 8), 1)
	testing.expect_value(t, compute_parallel_vm_limit(7 * GIB, GIB, 4 * GIB, 8), 3)
	testing.expect_value(t, compute_parallel_vm_limit(10 * GIB, 2 * GIB, 4 * GIB, 8), 3)

	// CPU ceiling caps RAM abundance.
	testing.expect_value(t, compute_parallel_vm_limit(64 * GIB, GIB, 4 * GIB, 4), 4)

	// u64 overflow safety: max(u64) available bytes with 1-byte per-VM cost clamps cleanly to max_cpus.
	testing.expect_value(t, compute_parallel_vm_limit(max(u64), 1, 0, 16), 16)
	testing.expect_value(t, compute_parallel_vm_limit(max(u64), max(u64), 0, 16), 1)
	testing.expect_value(t, compute_parallel_vm_limit(10 * GIB, GIB, max(u64), 8), 1)
}

@(test)
meminfo_parse_available_bytes_handles_valid_and_malformed :: proc(t: ^testing.T) {
	// Malformed inputs are refused.
	for bad in ([]string{
		"",
		"MemTotal:       16384000 kB\n",
		"MemAvailable:\n",
		"MemAvailable:   abc kB\n",
		"MemAvailable:   -1024 kB\n",
		"MemAvailable:   12x kB\n",
		"MemAvailable:   18446744073709551615 kB\n",
		"MemAvailable:   99999999999999999999999 kB\n",
	}) {
		_, ok := meminfo_parse_available_bytes(bad)
		testing.expectf(t, !ok, "malformed meminfo %q must be refused", bad)
	}

	// Valid Linux /proc/meminfo text converts kB to exact bytes.
	sample := "MemTotal:       32768000 kB\nMemFree:         2048000 kB\nMemAvailable:   16384000 kB\nBuffers:          512000 kB\n"
	bytes, ok := meminfo_parse_available_bytes(sample)
	testing.expect(t, ok, "valid /proc/meminfo parses cleanly")
	testing.expect_value(t, bytes, u64(16384000) * 1024)
}
