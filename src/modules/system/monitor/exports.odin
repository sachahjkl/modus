package monitor

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/value_kinds"
import process_page "modus:contract/disk_process_page"
import op "modus:contract/operation"
import "modus:disk_process"
import "modus:system"

// The monitor is also a service: its exports give what its window shows, as
// tables of records, not text. The console calls them through a
// connection, and the host through the remote service.
//
// The facts are the facts of the machine: each process and the counts of
// the kernel. The monitor reads them with its grant, the machine with the
// right Inspect, and gives them only to a caller that acts for the principal
// (a process sees no other process).

// One row for each process that runs: processes().
//
// A field that counts a size or a time has a type of the contract: the
// console shows it in the color of its kind, with its unit.
Process :: struct {
	slot:     i64, // The place of the process in the kernel.
	name:     [32]u8,
	state:    [8]u8, // created, ready, waiting or stopped.
	cause:    [40]u8, // The stop cause of a stopped process, as op.STOP_CAUSE_TEXTS words it; empty while it runs.
	outcome:  [24]u8, // The stop outcome of a process that stopped itself, as op.STOP_OUTCOME_TEXTS words it; empty for each other process.
	resident:      value_kinds.Size_In_Pages, // The mapped pages that have a page frame.
	mapped:        value_kinds.Size_In_Pages, // The mapped pages.
	handles:       i64, // Handles currently held by the process.
	handles_peak:  i64, // Largest count of handles held at once since start.
	mappings:      i64, // Mappings currently held by the process.
	mappings_peak: i64, // Largest count of mappings held at once since start.
	threads:       i64,
	time:          value_kinds.Time_In_Milliseconds, // Processor time.
	entries:       i64, // Kernel entries.
	started:       value_kinds.Time_In_Microseconds, // The time of the start, after the start of the machine.
	// A disk process: the BLAKE3 hash of its module file, in hexadecimal,
	// as the root service checked it. Empty: the root service did not start
	// this process from a disk.
	hash:          [64]u8,
}
// The field holds the 64 digits that hash_write gives, with no zero byte
// after them: a Text field ends at its end too.
#assert(size_of(Process) == 256)
#assert(size_of(Process) - offset_of(Process, hash) == disk_process.HASH_DIGITS)

// The name of one count: a row of the table of counts_named().
Count_Name :: struct {
	name: [24]u8,
}

// One row for each count of the machine: counts().
Count :: struct {
	name:  [24]u8,
	value: i64,
	unit:  [16]u8,
}

// What the monitor did as a service: served().
Served :: struct {
	calls:    i64, // The calls that it executed.
	callers:  i64, // The connections that it has now.
	pictures: i64, // The pictures of its window.
}

ERROR_ACTS_FOR_PRINCIPAL :: -1
ERROR_REFUSED :: -2
ERROR_ABSENT :: -3

@(rodata)
state_names := [op.Process_State]string {
	.None    = "",
	.Created = "created",
	.Ready   = "ready",
	.Waiting = "waiting",
	.Stopped = "stopped",
}

machine: system.Handle
service: system.Service
pictures: u64

// acts_for_principal says if the caller of the export that runs acts for the principal.
// A call of the monitor itself has no caller: it acts for the principal.
@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// processes gives one row for each process that runs, from the reports of the kernel: its slot, its name, its state, the stop cause of a stopped process and the stop outcome of a process that stopped itself, its resident pages (the mapped pages with a page frame) and its mapped pages, its handles, threads, processor time in milliseconds, kernel entries, the time of its start in microseconds, and the hash of the file of a disk process.
//
// The monitor asks the kernel for the report of each process slot, and skips a slot with no process. A stopped
// process that its parent has not closed yet has a row, with the state `stopped`.
//
// A process that the root service started from a disk has its nickname as its name, and the whole hash of its
// module file in `hash`: 64 hexadecimal digits, from the [disk process page](term:disk-process-page) that the root
// service writes, as the window of the monitor shows them. Each other process has an empty `hash`, also a process
// with the name of a disk process.
//
// - **result**: a table of `Process` rows that the call fills. A table shorter than the count gets the first rows
//   only; the result still counts every process.
//
// The result is the count of processes, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal. A process sees no other process, so only the
//   console and the host through the remote service get rows.
// - `Refused` (-2): the kernel refused the system report to the monitor; the record holds its status. This comes
//   when the grant **Inspect** of the monitor was revoked.
//
// Example, in the console after `connect("monitor")`: `monitor.processes()`, or
// `where(monitor.processes(), threads = 2)` to keep the rows of a column value, or
// `where(monitor.processes(), cause = "a fault")` for the processes that a fault stopped, or
// `where(monitor.processes(), outcome = "failed")` for the processes that stopped and said that their work failed, or
// `columns(where(monitor.processes(), name = "visitor"), name, hash)` for the file of a disk process.
@(export, link_name = "processes")
processes :: proc "c" (result: ^[]Process, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	total := 0
	for slot in 1 ..< report.process_slots {
		process: op.Process_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process)); status != .Ok || process.state == .None {
			continue
		}
		if total < len(result^) {
			row := &result[total]
			row^ = {
				slot          = i64(slot),
				resident      = value_kinds.Size_In_Pages(process.present_pages),
				mapped        = value_kinds.Size_In_Pages(process.mapped_pages),
				handles       = i64(process.handle_count),
				handles_peak  = i64(process.handles_peak),
				mappings      = i64(process.mapping_count),
				mappings_peak = i64(process.mappings_peak),
				threads       = i64(process.thread_count),
				time          = value_kinds.Time_In_Milliseconds(process.run_time),
				entries       = i64(process.entries),
				started       = value_kinds.Time_In_Microseconds(process.start_time),
			}
			// A disk process: the nickname and the hash that the root
			// service checked, matched as the window matches them, by the
			// slot and the serial that the kernel reports.
			if page_row, from_disk := process_page.row_find(disk_processes, slot, process.process_serial); from_disk {
				nickname := process_page.nickname_of(page_row.nickname)
				copy(row.name[:len(row.name) - 1], process_page.nickname_text(&nickname))
				disk_process.hash_write(&row.hash, transmute([disk_process.HASH_SIZE]u8)page_row.hash)
			} else {
				copy(row.name[:len(row.name) - 1], system.name_of(process.name[:]))
			}
			if process.state <= max(op.Process_State) {
				copy(row.state[:], state_names[process.state])
			}
			// The state, the cause and the outcome cross the border of the
			// kernel together: a triple that the border refuses leaves the
			// cells empty, never a stop that did not happen.
			if _, cause, outcome, known := op.stop_of_words(u64(process.state), u64(process.stop_cause), u64(process.stop_outcome)); known && cause != .None {
				copy(row.cause[:], op.STOP_CAUSE_TEXTS[cause])
				if outcome != .None {
					copy(row.outcome[:], op.STOP_OUTCOME_TEXTS[outcome])
				}
			}
		}
		total += 1
	}
	return i64(total)
}

// counts gives one row for each count of the machine that the kernel reports: the time, the pages, the free pages, the reserved pages, the memory objects, the processes, the processors, the kernel entries, the interrupts, the page faults of a first use, and the takes and the waits of the locks of the kernel, the scheduling strategy (its number, and its name as the unit) and its changes.
//
// Each row is a `Count`: a name, a value and a unit ("free pages", 12345, "pages"). The names are the names that
// [count](monitor.count) and [counts_named](monitor.counts_named) take. The counts of the locks add the takes and
// the waits of every kind of lock. The count "processes" counts the slots in use, stopped processes included.
//
// - **result**: a table of `Count` rows; the call fills at most its length.
//
// The result is the count of rows, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Refused` (-2): the kernel refused the system report; the record holds its status.
@(export, link_name = "counts")
counts :: proc "c" (result: ^[]Count, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	rows: [COUNT_CAPACITY]Count
	total, status := counts_read(&rows)
	if status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	copy(result^, rows[:total])
	return i64(total)
}

// count gives one count of the machine by its name, as counts() names it: count("free pages").
//
// It reads all the counts, as [counts](monitor.counts) does, and gives the value of one of them: a caller that needs
// one number needs no table.
//
// - **name**: the name of a count, as the first column of `counts()` gives it, 23 bytes at most. The match is exact.
//
// The result is the value of the count, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Refused` (-2): the kernel refused the system report.
// - `Absent` (-3): no count has this name, or the name is longer than 23 bytes.
//
// Example: `monitor.count("kernel entries")`.
@(export, link_name = "count")
count :: proc "c" (name: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	// One copy: the caller can change the call region during the call.
	wanted: [24]u8
	if len(name^) >= len(wanted) {
		return errors.fail(error, ERROR_ABSENT, .Absent, .None, 1)
	}
	copied := copy(wanted[:], name^)
	rows: [COUNT_CAPACITY]Count
	total, status := counts_read(&rows)
	if status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	for &row in rows[:total] {
		if system.name_of(row.name[:]) == string(wanted[:copied]) {
			return row.value
		}
	}
	return errors.fail(error, ERROR_ABSENT, .Absent, .None, 1)
}

// counts_named gives the counts of the machine that a table of names names, in the order of the table: many counts in one call.
//
// It is the form of [count](monitor.count) for several names: one call, one read of the reports, and the values
// of one moment.
//
// - **names**: a table of `Count_Name` rows, each a name as `counts()` gives it.
// - **details**: a table of error details, or none. With a table, the call checks every row and appends one
//   `Absent` detail for each row that names no count, in the order of the rows. With no table, it stops at the
//   first such row.
// - **result**: a table of `Count` rows, in the order of the names; row n answers name n.
//
// The result is the count of names, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Refused` (-2): the kernel refused the system report.
// - `Absent` (-3): a name names no count. The value *found* of the record is the number of its row, from 1; with
//   a table of details, the record is the first of them.
@(export, link_name = "counts_named")
counts_named :: proc "c" (names: ^system.Table_To_Read(Count_Name), details: ^system.Table_To_Append(errors.Error_Record), result: ^[]Count, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	rows: [COUNT_CAPACITY]Count
	total, status := counts_read(&rows)
	if status != .Ok {
		return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
	}
	first_absent: errors.Error_Record
	absent_count := 0
	for number in 0 ..< names.count {
		// One copy of the record: the caller can change the call region
		// during the call (docs/MODULE_CONTRACT.md: an export copies a
		// record before it checks it).
		wanted := intrinsics.volatile_load(&names.records[number])
		found := -1
		for &row, index in rows[:total] {
			if system.name_of(row.name[:]) == system.name_of(wanted.name[:]) {
				found = index
			}
		}
		if found < 0 {
			absent := errors.error_make(.Absent, .None, 1, 0, 0, i64(number + 1))
			if absent_count == 0 {
				first_absent = absent
			}
			absent_count += 1
			// With no table of error details the first row is the whole
			// answer: stop, as a call with no table always did.
			if details == nil {
				break
			}
			system.error_detail_append(details, absent)
			continue
		}
		if number < u64(len(result^)) {
			result[number] = rows[found]
		}
	}
	if absent_count > 0 {
		if error != nil {
			error^ = first_absent
		}
		return ERROR_ABSENT
	}
	return i64(names.count)
}

COUNT_CAPACITY :: 16

// counts_read fills the counts of the machine from the system report.
counts_read :: proc "contextless" (rows: ^[COUNT_CAPACITY]Count) -> (total: int, status: system.Status) {
	report: op.System_Report
	if _, status = system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return 0, status
	}
	running: u64
	for slot in 1 ..< report.process_slots {
		process: op.Process_Report
		if _, process_status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process)); process_status == .Ok && process.state != .None {
			running += 1
		}
	}
	takes, waits: u64
	for kind in op.Lock_Kind {
		takes += report.locks[kind].takes
		waits += report.locks[kind].waits
	}
	Item :: struct {
		name:  string,
		value: u64,
		unit:  string,
	}
	items := [?]Item {
		{"time", report.time, "milliseconds"},
		{"pages", report.page_count, "pages"},
		{"free pages", report.free_pages, "pages"},
		{"reserved pages", report.reserved_pages, "pages"},
		{"budget pages", report.budget_pages, "pages"},
		{"memory objects", report.region_count, "objects"},
		{"processes", running, "processes"},
		{"processors", report.processors, "processors"},
		{"kernel entries", report.entries, "entries"},
		{"interrupts", report.interrupts, "interrupts"},
		{"first use faults", report.first_use_faults, "faults"},
		{"lock takes", takes, "takes"},
		{"lock waits", waits, "waits"},
		// The value is the number of the strategy; the unit names it.
		{"strategy", u64(report.strategy), report.strategy <= max(op.Strategy) ? op.STRATEGY_NAMES[report.strategy] : "unknown"},
		{"strategy changes", u64(report.strategy_changes), "changes"},
	}
	#assert(len(items) <= COUNT_CAPACITY)
	for item, index in items {
		rows[index] = {value = i64(item.value)}
		copy(rows[index].name[:len(rows[index].name) - 1], item.name)
		copy(rows[index].unit[:len(rows[index].unit) - 1], item.unit)
	}
	return len(items), .Ok
}

// served gives what the monitor did as a service: the calls that it executed, the connections that it has now, and the pictures of its window.
//
// These are facts of the monitor itself, not of other processes: each caller sees them, with no grant to act for
// the principal. The test of the calls from the host reads `calls` before and after a call over a link that loses
// datagrams: the count grows by one, so the call ran one time.
//
// - **result**: one `Served` record: `calls`, `callers`, `pictures`.
//
// It never fails.
@(export, link_name = "served")
served :: proc "c" (result: ^Served) {
	result^ = {calls = i64(service.calls), callers = i64(service.connected), pictures = i64(pictures)}
}
