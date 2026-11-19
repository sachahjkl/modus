package root

// The tables of this service that a refusal of No_Slot can name: its
// mappings and its handles, 128 of each, as each process
// (op.MAPPING_REPORT_CAPACITY). A start that fails at the map of a module
// says the count of each, so a line tells which table was full: the loader
// maps in this service to prepare a module and makes a memory object for
// each writable segment, and each of these takes a place of a table of
// this service (src/md/features/module_outputs.md, "The budget").

import op "modus:contract/operation"
import "modus:support/system"

// The report of the mappings of this service: 8 KiB, so not on the stack.
// Read only for a line.
own_mappings_report: op.Process_Mapping_Report

// The process slot of this service, found once by its name; 0 until then.
own_slot: u64

// own_tables gives the mappings and the handles that this service holds
// now, from the reports of the kernel. ok is false when the kernel gives
// none: the line then says nothing of them.
own_tables :: proc "contextless" () -> (mappings, handles: u64, ok: bool) {
	report: op.Process_Report
	if own_slot == 0 {
		for index in u64(1) ..< op.PROCESS_SLOTS_OF_THE_MACHINE {
			if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), index, u64(uintptr(&report)), size_of(report)); status != .Ok {
				continue
			}
			if system.name_of(report.name[:]) == "root" && report.state != .None && report.state != .Stopped {
				own_slot = index
				break
			}
		}
		if own_slot == 0 {
			return 0, 0, false
		}
	}
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), own_slot, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return 0, 0, false
	}
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process_Mappings), own_slot, u64(uintptr(&own_mappings_report)), size_of(own_mappings_report)); status != .Ok {
		return 0, 0, false
	}
	return own_mappings_report.count, report.handle_count, true
}

// own_tables_log writes the line of the tables of this service after a
// start that a table refused.
own_tables_log :: proc "contextless" (name: string) {
	mappings, handles, ok := own_tables()
	if !ok {
		system.log(.Warning, "root: the start of ", system.Module_Name{name}, " found a table full; the kernel gives no report of the tables of this service")
		return
	}
	system.log(.Warning, "root: the start of ", system.Module_Name{name}, " found a table full: this service holds ", mappings, " mappings and ", handles, " handles, of ", u64(op.MAPPING_REPORT_CAPACITY), " each")
}
