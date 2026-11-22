// Live cross-thread hardware-counter profiler and W^X external pager integrated
// into the debugger service.
package debugger

import "modus:contract/processor_profiler"

debugger_profiler: processor_profiler.Profiler_Session
debugger_external_pager: processor_profiler.External_Pager

debugger_profiler_reset :: proc "contextless" () {
	processor_profiler.profiler_init(&debugger_profiler)
	processor_profiler.pager_init(&debugger_external_pager)
}

debugger_profiler_ingest :: proc "contextless" (sample: processor_profiler.Counter_Sample) -> (delta: processor_profiler.Counter_Delta, ok: bool) {
	d, r := processor_profiler.profiler_record_sample(&debugger_profiler, sample)
	return d, r == .None
}
