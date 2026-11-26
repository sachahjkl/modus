// Triggers a runtime panic on target modus to verify panic logging and stop reports.
package core_probe_panic

import "modus:system"

// Plan value: minimal working memory for runtime startup and panic output on one thread.
MODULE_BUDGET :: system.Stated_Budget {
	working_memory_pages = 256,
	processes            = 1,
	threads              = 1,
}

@(optimization_mode = "none")
trigger_panic :: proc() {
	panic("core_probe_panic: deliberate panic")
}

main :: proc() {
	#force_no_inline trigger_panic()
}
