package kernel

import info "modus:contract/boot_info"

// A browser machine starts each other processor as a worker of the page on
// the same shared memory (src/md/features/browser_machine.md, "Several
// processors as workers"). Until the page starts workers, the machine runs
// one processor.
processors_start :: proc "contextless" (boot: ^info.Boot_Info) {
	direct_map_size = boot.direct_map_size
	log("kernel: one processor: the page starts no other worker")
}
