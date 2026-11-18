// The reader of the boot display: it fills a bootscreen.Data with the
// records of the kernel. The process needs the machine with the right
// Inspect.
package collect

import "modus:support/bootscreen"
import op "modus:contract/operation"
import "modus:support/system"

// data fills a Data with the boot report, the system report, the report of
// each processor, the report of each process, and the name of the
// processor. A report that the kernel refuses stays zero: its card shows
// that the fact is not known.
data :: proc "contextless" (result: ^bootscreen.Data, machine: system.Handle) {
	inspect :: proc "contextless" (machine: system.Handle, kind: op.Inspect_Kind, index: u64, report: ^$T) {
		system.call(.Inspect, u64(machine), u64(kind), index, u64(uintptr(report)), size_of(T))
	}
	inspect(machine, .Boot, 0, &result.boot)
	inspect(machine, .System, 0, &result.machine)
	for &processor, index in result.processors[:min(result.machine.processors, bootscreen.PROCESSOR_ROWS)] {
		inspect(machine, .Processor, u64(index), &processor)
	}
	result.process_count = 0
	result.process_total = 0
	for slot in 1 ..< result.machine.process_slots {
		report: op.Process_Report
		inspect(machine, .Process, slot, &report)
		if report.state == .None {
			continue
		}
		result.process_total += 1
		if result.process_count < bootscreen.PROCESS_ROWS {
			result.processes[result.process_count] = {slot = slot, report = report}
			result.process_count += 1
		}
	}
	if result.processor_name[0] == 0 {
		result.processor_name = bootscreen.processor_name()
	}
}
