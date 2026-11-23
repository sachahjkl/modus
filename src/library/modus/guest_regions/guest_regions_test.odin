#+build !freestanding
package guest_regions

import "core:testing"

// The region of a mapping of the memory of the guest: 2 MiB, and more past
// REGIONS_MOST regions, so that the mappings of a guest stay under the
// capacity of a process.
@(test)
region_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, region_bytes(0), REGION_BYTES_LEAST)
	testing.expect_value(t, region_bytes(64 * 1024 * 1024), REGION_BYTES_LEAST)
	testing.expect_value(t, region_bytes(REGIONS_MOST * REGION_BYTES_LEAST), REGION_BYTES_LEAST)
	testing.expect_value(t, region_bytes(REGIONS_MOST * REGION_BYTES_LEAST + 1), 2 * REGION_BYTES_LEAST)
	for pages in ([?]u64{16, 16_384, 32_768, 65_535, 65_536}) {
		bytes := pages * 4096
		region := region_bytes(bytes)
		testing.expect(t, region % REGION_BYTES_LEAST == 0)
		testing.expectf(t, (bytes + region - 1) / region <= REGIONS_MOST, "%v pages make at most %v regions", pages, REGIONS_MOST)
	}
}

// A kernel count past the memory of the guest is refused before the
// rounding to a page, so no count wraps the size of the copy to 0.
@(test)
kernel_staging_refuses_counts_past_memory :: proc(t: ^testing.T) {
	memory := u64(64 * 1024 * 1024)
	for count in ([?]u64{0, max(u64), max(u64) - 10, max(u64) - 4095, memory, memory - 1, memory + 1}) {
		staging, fits := kernel_staging_bytes(count, memory)
		testing.expectf(t, !fits && staging == 0, "the count %v is refused", count)
	}
	_, empty_fits := kernel_staging_bytes(1, 0)
	testing.expect(t, !empty_fits)
	staging, fits := kernel_staging_bytes(1, memory)
	testing.expect(t, fits && staging == 4096)
	staging, fits = kernel_staging_bytes(memory - 4096, memory)
	testing.expect(t, fits && staging == memory - 4096)
}
