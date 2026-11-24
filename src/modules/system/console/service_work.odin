package console

import op "modus:contract/operation"
import "modus:contract/work_budget"
import "modus:system"

// work(process) gives the work that services did for a process, one row
// for each of its connections (src/md/features/work_accounting.md, "What
// the report of a process shows"). The console knows the connections of
// its own process only: the root service does not report the connections
// of another process yet. And no service charges a work budget yet, so
// each row is unaccounted: the service paid the work itself, and the row
// says so in place of showing numbers that no one measured.

// process_slot_named gives the slot of the process that runs with a name,
// or 0.
process_slot_named :: proc "contextless" (report: op.System_Report, name: string) -> u64 {
	for slot in u64(1) ..< report.process_slots {
		process: op.Process_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process)); status != .Succeeded {
			continue
		}
		if process.state != .None && system.name_of(process.name[:]) == name {
			return slot
		}
	}
	return 0
}

work_command :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	if name == "" {
		return fail("work: the name of a process has no byte: work(\"console\")")
	}
	if len(name) > op.PROCESS_NAME_BYTES_MOST {
		return fail("work: the name of a process has ", i64(op.PROCESS_NAME_BYTES_MOST), " bytes at most, not ", i64(len(name)))
	}
	report, ok := system_report()
	if !ok {
		return {}
	}
	slot := process_slot_named(report, name)
	if slot == 0 {
		return fail("work: no process that runs has the name ", name)
	}
	if i64(slot) != console_own_process_slot() {
		return fail("work: the console knows the connections of its own process only, and the root service does not report the connections of ", name, " yet")
	}
	columns := [6]Column {
		text_column("service", 32),
		text_column("state", 16),
		size_column("pages", .Pages),
		size_column("pages_limit", .Pages),
		time_column("processor", .Microseconds),
		time_column("step_debt", .Microseconds),
	}
	table, made := made_table("Service_Work", columns[:])
	if !made {
		return fail("work: the line has no room for the description")
	}
	for &sandbox in sandboxes {
		// A service with no process handle has no connection now: the
		// next call makes one.
		if sandbox.name == "" || !sandbox.service || sandbox.process == 0 {
			continue
		}
		work := work_budget.work_row_unaccounted()
		row := made_row(&table)
		made_text(&table, row, 0, sandbox.name)
		made_text(&table, row, 1, work_budget.work_row_state_text(work))
		made_integer(&table, row, 2, i64(work.pages_charged))
		made_integer(&table, row, 3, i64(work.pages_limit))
		made_integer(&table, row, 4, i64(work.processor_microseconds))
		made_integer(&table, row, 5, i64(work.step_debt_microseconds))
	}
	return made_value(&table, "work")
}
