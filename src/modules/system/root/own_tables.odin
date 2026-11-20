package root

// The tables of this service: its mappings and its handles, 128 places of
// each, as each process (op.MAPPING_REPORT_CAPACITY,
// op.HANDLE_TABLE_CAPACITY). This service holds handles for each process
// that it starts, each service of the system and each part of the table of
// prepared modules (src/md/features/module_outputs.md, "The budget"). The
// table of prepared modules is a cache: before each start and each list
// page, this service frees the handles that the work needs by closing the
// prepared parts used least recently (handles_room_make). A start that a
// full table refuses still says the count of each table.

import "modus:contract/output"
import op "modus:contract/operation"
import "modus:support/system"

// The report of the mappings of this service: 8 KiB, so not on the stack.
// Read only for a line.
own_mappings_report: op.Process_Mapping_Report

// The process slot of this service, found once by its name; 0 until then.
own_slot: u64

// The handles that one start takes in this service while it runs, past
// the parts of its modules: the handles of the role that the start closes
// at its end (8: the ring of a device, the ring and the region of a store,
// the ring and the region of an endpoint, the clock ports, two shared
// objects), the process, its budget and the copy kept for a sender of Wire,
// its stack and its context record, its root ring, its service ring or the
// control ring of the network, and its wiring ring.
START_HANDLES_MOST :: 16

// The handles that the loader takes for one module that the table does not
// hold: its part Code and its part Fixed, kept, and one object that it
// writes and closes at a time (the object of a part before the copy that
// the table keeps, or a writable segment before its map). The margin
// counts three modules: the module of the child and two imports. The
// imports that each start finds are the parts used most recently, so the
// order of use keeps them; a module of the system that no running process
// started for a while is the one to prepare again.
MODULE_HANDLES_MOST :: 3
MODULES_OF_A_START_PREPARED_MOST :: 3

// The handles of one row of a wiring list while the start or the Wire
// makes it: its ring, its end page, its description file and its terms;
// and the wiring page of the asker, once.
WIRING_ROW_HANDLES_MOST :: 4
WIRING_PAGE_HANDLES :: 1

// The handles of a List_Page: the list page and the wiring ring of an
// asker that has none.
LIST_PAGE_HANDLES :: 2

// start_handles_needed gives the free handles that one start needs: a
// start with no list 25, a start with the full list of an asker
// (output.WIRINGS_OF_AN_ASKER_MOST rows) 58.
start_handles_needed :: proc "contextless" (rows: int) -> int {
	needed := START_HANDLES_MOST + MODULES_OF_A_START_PREPARED_MOST * MODULE_HANDLES_MOST
	if rows > 0 {
		needed += min(rows, output.WIRINGS_OF_AN_ASKER_MOST) * WIRING_ROW_HANDLES_MOST + WIRING_PAGE_HANDLES
	}
	return needed
}

// own_slot_find finds the process slot of this service by its name, once.
@(private = "file")
own_slot_find :: proc "contextless" () -> bool {
	if own_slot != 0 {
		return true
	}
	report: op.Process_Report
	for index in u64(1) ..< op.PROCESS_SLOTS_OF_THE_MACHINE {
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), index, u64(uintptr(&report)), size_of(report)); status != .Ok {
			continue
		}
		if system.name_of(report.name[:]) == "root" && report.state != .None && report.state != .Stopped {
			own_slot = index
			return true
		}
	}
	return false
}

// own_handle_count gives the handles that this service holds now: one
// report of the kernel, one kernel entry. ok is false when the kernel
// gives none.
own_handle_count :: proc "contextless" () -> (handles: u64, ok: bool) {
	if !own_slot_find() {
		return 0, false
	}
	report: op.Process_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), own_slot, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return 0, false
	}
	return report.handle_count, true
}

// handles_room_make frees needed handles of this service for the work that
// comes, by closing prepared parts used least recently, when fewer are
// free. A table that cannot give enough gives what it can: the work then
// runs, and a refusal names the full table. It gives the parts that it
// closed.
handles_room_make :: proc "contextless" (needed: int) -> (closed: int) {
	handles, ok := own_handle_count()
	if !ok {
		return 0
	}
	free := int(op.HANDLE_TABLE_CAPACITY - 1) - int(handles)
	return system.prepared_yield(&prepared, free, needed)
}

// own_tables gives the mappings and the handles that this service holds
// now, from the reports of the kernel. ok is false when the kernel gives
// none: the line then says nothing of them.
own_tables :: proc "contextless" () -> (mappings, handles: u64, ok: bool) {
	handles = own_handle_count() or_return
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process_Mappings), own_slot, u64(uintptr(&own_mappings_report)), size_of(own_mappings_report)); status != .Ok {
		return 0, 0, false
	}
	return own_mappings_report.count, handles, true
}

// The start of the line of own_tables_measure: the measure record reads it
// (tools/modustool/checks/measure_record.odin).
OWN_TABLES_MEASURE_LINE :: "root: the tables of this service after the stop of "

// own_tables_measure writes the tables of this service after the stop of
// a process that can ask for wirings: its wirings, its list page and its
// budget handle ended with it, so each run shows the margin of the handle
// table of this service at a known point of the main test, and the parts
// of the table of prepared modules that it holds.
own_tables_measure :: proc "contextless" (name: string) {
	mappings, handles, ok := own_tables()
	if !ok {
		return
	}
	system.log(.Info, OWN_TABLES_MEASURE_LINE, system.Module_Name{name}, ": ", handles, " handles, ", u64(system.prepared_held(&prepared)), " of them prepared parts, and ", mappings, " mappings, of ", u64(op.MAPPING_REPORT_CAPACITY), " each")
}

// own_tables_log writes the line of the tables of this service after a
// start that a table refused.
own_tables_log :: proc "contextless" (name: string) {
	mappings, handles, ok := own_tables()
	if !ok {
		system.log(.Warning, "root: the start of ", system.Module_Name{name}, " found a table full; the kernel gives no report of the tables of this service")
		return
	}
	system.log(.Warning, "root: the start of ", system.Module_Name{name}, " found a table full: this service holds ", mappings, " mappings and ", handles, " handles, ", u64(system.prepared_held(&prepared)), " of them prepared parts, of ", u64(op.MAPPING_REPORT_CAPACITY), " each")
}
