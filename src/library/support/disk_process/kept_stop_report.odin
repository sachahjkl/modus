package disk_process

import op "modus:contract/operation"

// The stop reports of the disk processes that stopped on a fault
// (src/md/features/debug_object_of_a_disk_process.md). The root service
// holds the only handle of a disk process and closes it at the reap, so
// the stop report would leave the kernel with it. The root service keeps a
// copy here, and gives it to the debugger service, which names its frames
// with the debug object of the store `module_files`.

// The reports that the root service keeps. A new fault of a nickname
// replaces the report of that nickname. Else a principal that holds
// KEPT_STOP_REPORTS_OF_ONE_PRINCIPAL places gives its own oldest place;
// else a new report takes a free place, or the place of the oldest.
KEPT_STOP_REPORT_CAPACITY :: 8
// The places that one principal holds at most: the faults of the processes
// of one principal never take the reports of another principal past the
// other half of the table.
KEPT_STOP_REPORTS_OF_ONE_PRINCIPAL :: 4
#assert(KEPT_STOP_REPORTS_OF_ONE_PRINCIPAL <= KEPT_STOP_REPORT_CAPACITY)

// What the root service gives the debugger service, in one page that the
// service can read only.
Kept_Stop_Report :: struct {
	module_hash: [HASH_SIZE]u8, // The hash of the module file of the process: its debug object is the object of the store with this hash as its name.
	report:      op.Stop_Report, // As stop_report_hide left it.
}

// One place of the table.
Kept_Stop_Report_Place :: struct {
	sequence:   u64, // The order of the keeps: the lowest is the oldest. 0: the place is free.
	principal:  u64, // The principal whose session ran the process.
	name:       [NAME_LIMIT]u8, // The nickname of the process.
	name_count: int,
	kept:       Kept_Stop_Report,
}

Kept_Stop_Reports :: struct {
	places:        [KEPT_STOP_REPORT_CAPACITY]Kept_Stop_Report_Place,
	last_sequence: u64,
}

// The first page of the addresses of a process: the kernel maps nothing
// there, so an address in it is no word of the memory of the process. A
// null pointer read gives an address in it.
FIRST_PAGE_BYTES :: 4096

// stop_report_hide takes out of a whole stop report, as Process_State gives
// it to the holder of the process handle, each value that can be a word of
// the memory of the process, and counts them in `hidden_value_count`. It
// keeps what Inspect gives to a holder of the machine: a frame that a
// module record holds (its base is not 0), the instruction when a module
// record holds it, and the address of a page fault in the first page or
// in the module of the instruction. The kernel also keeps the address of a
// page fault in another module of the process; the report holds no other
// module with its size, so here such an address is hidden.
stop_report_hide :: proc "contextless" (report: ^op.Stop_Report) {
	report.process_serial = 0
	module := report.module
	in_module :: proc "contextless" (module: op.Module_Record, address: u64) -> bool {
		return module.size != 0 && address >= module.base && address - module.base < module.size
	}
	if report.address >= FIRST_PAGE_BYTES && !in_module(module, report.address) {
		report.address = 0
		report.hidden_value_count += 1
	}
	if report.instruction != 0 && !in_module(module, report.instruction) {
		report.instruction = 0
		report.hidden_value_count += 1
	}
	if report.frame_count > op.STOP_FRAME_CAPACITY {
		report.frame_count = op.STOP_FRAME_CAPACITY
	}
	for &frame in report.frames[:report.frame_count] {
		if frame.base == 0 || frame.address < frame.base {
			if frame.address != 0 {
				report.hidden_value_count += 1
			}
			frame = {}
		}
	}
	for &frame in report.frames[report.frame_count:] {
		frame = {}
	}
}

// kept_stop_report_keep keeps the report of a disk process that stopped on
// a fault. The caller hid the report first (stop_report_hide). A name that
// is no name of a disk process keeps nothing.
kept_stop_report_keep :: proc "contextless" (table: ^Kept_Stop_Reports, principal: u64, name: string, module_hash: [HASH_SIZE]u8, report: ^op.Stop_Report) -> bool {
	if len(name) == 0 || len(name) > NAME_LIMIT {
		return false
	}
	place := kept_stop_report_place(table, principal, name)
	if place == nil {
		// The oldest place of this principal, and how many it holds.
		held := 0
		oldest_held: ^Kept_Stop_Report_Place
		for &candidate in table.places {
			if candidate.sequence != 0 && candidate.principal == principal {
				held += 1
				if oldest_held == nil || candidate.sequence < oldest_held.sequence {
					oldest_held = &candidate
				}
			}
		}
		if held >= KEPT_STOP_REPORTS_OF_ONE_PRINCIPAL {
			place = oldest_held
		}
	}
	if place == nil {
		for &candidate in table.places {
			if place == nil || candidate.sequence < place.sequence {
				place = &candidate
			}
		}
	}
	table.last_sequence += 1
	place^ = {sequence = table.last_sequence, principal = principal, name_count = len(name)}
	copy(place.name[:], name)
	place.kept = {module_hash = module_hash, report = report^}
	return true
}

// kept_stop_report_find gives the kept report of the process of a
// principal with a name, or nil.
kept_stop_report_find :: proc "contextless" (table: ^Kept_Stop_Reports, principal: u64, name: string) -> ^Kept_Stop_Report {
	if place := kept_stop_report_place(table, principal, name); place != nil {
		return &place.kept
	}
	return nil
}

// kept_stop_report_forget frees the place of the process of a principal
// with a name: the last run of that nickname ended with no fault, and an
// older fault no longer tells how it ended.
kept_stop_report_forget :: proc "contextless" (table: ^Kept_Stop_Reports, principal: u64, name: string) {
	if place := kept_stop_report_place(table, principal, name); place != nil {
		place^ = {}
	}
}

@(private = "file")
kept_stop_report_place :: proc "contextless" (table: ^Kept_Stop_Reports, principal: u64, name: string) -> ^Kept_Stop_Report_Place {
	for &place in table.places {
		if place.sequence != 0 && place.principal == principal && string(place.name[:place.name_count]) == name {
			return &place
		}
	}
	return nil
}
