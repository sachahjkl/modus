package kernel

import "modulus:frame_runs"

// Architecture-specific frame-run support on x86-64
// (src/md/features/frames_of_a_process.md, "The other machines").

// CPUID leaf 0x8000_0001 EDX bit 26 reports hardware 1 GiB page support (pdpe1gb).
CPUID_EXTENDED_FEATURES_LEAF :: u32(0x8000_0001)
CPUID_PDPE1GB_BIT :: u32(1) << 26

// frame_runs_arch_supports_1g queries CPUID for 1 GiB page support (pdpe1gb).
frame_runs_arch_supports_1g :: proc "contextless" () -> bool {
	max_ext, _, _, _ := processor_identification_read(0x8000_0000, 0)
	if max_ext < CPUID_EXTENDED_FEATURES_LEAF {
		return false
	}
	_, _, _, edx := processor_identification_read(CPUID_EXTENDED_FEATURES_LEAF, 0)
	return edx & CPUID_PDPE1GB_BIT != 0
}

// frame_runs_arch_enabled says whether aligned 2 MiB / 1 GiB runs are active
// on this target.
frame_runs_arch_enabled :: proc "contextless" () -> bool {
	return true
}

// frame_runs_report_counts reads the current free run and fallback counts
// under the frame lock.
frame_runs_report_counts :: proc "contextless" (table: ^frame_runs.Table) -> (free_2m, free_1g, fallback_2m, fallback_1g: u64) {
	return table.free_runs_2m, table.supports_1g ? table.free_runs_1g : 0, table.fallback_2m, table.fallback_1g
}
