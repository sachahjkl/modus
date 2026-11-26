package kernel

import info "modus:contract/boot_info"
import "modulus:frame_runs"

// Architecture-specific frame-run support on a browser machine (wasm64p32)
// (src/md/features/frames_of_a_process.md, "The other machines"): large-run
// allocation is off and all run counts report 0.

frame_runs_arch_supports_1g :: proc "contextless" () -> bool {
	return false
}

frame_runs_arch_enabled :: proc "contextless" () -> bool {
	return false
}

frame_runs_report_counts :: proc "contextless" (table: ^frame_runs.Table) -> (free_2m, free_1g, fallback_2m, fallback_1g: u64) {
	return 0, 0, 0, 0
}

// framebuffer_device_pages includes the browser machine's full live-resize
// backing framebuffer and trailing MODVRES1 control page when present.
framebuffer_device_pages :: proc "contextless" (fb: info.Framebuffer, direct_map_size: u64) -> u64 {
	pixel_pages := (u64(fb.pixels_per_line) * u64(fb.height) * 4 + PAGE_SIZE - 1) / PAGE_SIZE
	control_address := fb.address + info.BROWSER_RESIZE_MAX_BYTES
	if control_address >= fb.address &&
		(control_address & 7) == 0 &&
		direct_map_size >= PAGE_SIZE &&
		control_address <= direct_map_size - PAGE_SIZE {
		if direct(control_address, u64)^ == info.BROWSER_RESIZE_MAGIC {
			return max(pixel_pages, info.BROWSER_RESIZE_TOTAL_PAGES)
		}
	}
	return pixel_pages
}
